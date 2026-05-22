# Architecture

> **English summary:** Internal layout of locspoof: how the helper LaunchDaemon talks to the GUI, why the app must live in /Applications, code-signing pitfalls with PyInstaller-bundled binaries, and the auto-recovery loop on iPhone disconnect.

---

## 兩條 deliverable

| | `host/` CLI | `locspoof/` Mac app |
|---|---|---|
| 啟動 | `sudo python3 host/start.py` | 點選單列 icon → 點地圖 |
| sudo | 每次跑都要 | 第一次安裝 helper 一次密碼，之後不用 |
| 形態 | 前景 terminal + Leaflet web UI | 選單列 + native MKMapView |

兩條走同一個 DVT `LocationSimulation` service，實作隔離互不引用。

**Invariant**：`host/` 永遠維持「最小 CLI 可運作」，不引用 Mac app build artifact、不依賴 Mac app 在場。Mac app 是獨立 supplementary 整包，bundle 內自帶 `host/bin/*` binary copy。

---

## Mac app 拓樸

```
locspoof.app/
├── Contents/
│   ├── MacOS/
│   │   ├── locspoof              # SwiftUI GUI（普通 user 權限）
│   │   └── locspoof-helper       # LaunchDaemon Swift CLI（root）
│   ├── Library/LaunchDaemons/
│   │   └── org.locspoof.app.helper.plist
│   └── Resources/
│       └── bin/
│           ├── pymobiledevice3       # PyInstaller bundled
│           └── dvt-location-stream
```

**通訊**：

```
GUI (locspoof) ──── HTTP :8765 ────→ helper (locspoof-helper)
                                          │
                                          ├── spawn pmd remote start-tunnel
                                          │     → 拿 RSD HOST PORT
                                          └── spawn dvt-location-stream HOST PORT
                                                → pipe stdin/stdout 注入座標
```

GUI 每 2 秒輪詢 `/api/status`。點地圖 = HTTP `GET /api/loc?lat=&lon=`。

---

## SMAppService 流程

`SMAppService.daemon(plistName:)`（macOS 13+）替代舊的 SMJobBless：

1. App 第一次跑 → popover 顯示「尚未安裝」
2. 點 **安裝 Helper** → `service.register()`
3. macOS 跳系統 admin 密碼框 → 用戶輸入 → BTM (Background Task Management) 把 daemon 註冊起來
4. launchd bootstrap helper at `/Applications/locspoof.app/Contents/MacOS/locspoof-helper`
5. helper 起 RSD tunnel + dvt subprocess + HTTP server :8765
6. GUI 偵測 `dvt_alive=true` → 切成「就緒」

### 為什麼必須 `/Applications/`

`SMAppService.daemon().register()` 拒絕 DerivedData 路徑 → 回 `.notFound`。dev iteration 一定要 cp 到 `/Applications/` 才能驗證。`install.sh` 自動處理。

### BTM 持久性

`launchctl bootout` 只 unload running process，**不卸 BTM 註冊 entry**。因此：

- cp 新 binary 到 `/Applications/` → BTM 看到對得上的 plist → 自動 re-bootstrap 新 daemon
- 完整 unregister 要 app 內呼叫 `service.unregister()` 或 系統設定 → 登入項目 → 關 toggle

---

## Auto-recovery on iPhone disconnect

**問題**：iPhone 拔線 → tunnel + dvt subprocess 死 → helper 內部 stdin/stdout dangling → `inject()` 永遠 fail。

**解法**：subprocess `terminationHandler` exit helper 整個 process → launchd KeepAlive 10 秒後 respawn → 重試 chain（沒裝置就再 exit → 再 respawn 迴圈直到 iPhone 回來）。

```swift
// Helper.swift
proc.terminationHandler = { p in
    log("[tunnel] exited status=\(p.terminationStatus), exiting helper for launchd respawn")
    exit(11)
}
```

`cleanup()` 主動結束時要先 nil terminationHandler，避免 race condition 觸發 exit(11) 跟主程序 exit(0) 競爭。

---

## Code signing 對 PyInstaller bundle 的坑

### 問題

helper 開 hardened runtime + 預設 library validation。**子程序**（pmd, dvt）dlopen 自己 PyInstaller 內部 `Python.framework` 時：

- 兩者都是 adhoc 簽名 → macOS 視為 "different Team IDs" → library validation 擋
- helper 自己有 `disable-library-validation` entitlement **沒用** — 那是 helper 的，不會繼承到子程序

### 解法

`host/bin/*` 自己也要簽 `disable-library-validation` entitlement：

```bash
codesign --force --sign - \
  --entitlements support/locspoof-helper.entitlements \
  --options runtime \
  host/bin/pymobiledevice3 host/bin/dvt-location-stream
```

build 時 Copy Files Phase C **不勾 Code Sign On Copy**，原 signature + entitlements 完整保留進 `.app` bundle。

### 注意

動到 `host/bin/*`（換版本 / 重新 PyInstaller build）後**要重 pre-sign**，否則 helper 起來 pmd dlopen 會炸。詳細 audit + rebuild 流程見 [SECURITY.md](SECURITY.md)。

---

## Helper 路徑解析

launchd 啟動 daemon 時，`CommandLine.arguments[0]` 是相對路徑（`Contents/MacOS/locspoof-helper`），cwd 是 `/`。直接 `URL(fileURLWithPath:)` 會解成 `/Contents/MacOS/locspoof-helper`。

修法：用 `_NSGetExecutablePath` 拿絕對路徑：

```swift
import Darwin
func currentExecutablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    _ = _NSGetExecutablePath(&buf, &size)
    return String(cString: buf)
}
```

從這拿到 `/Applications/locspoof.app/Contents/MacOS/locspoof-helper`，往上走兩層 `..` + `Resources/bin/` 拿 pmd / dvt 路徑。

---

## App Sandbox

主 app `locspoof` target **關 sandbox**（`ENABLE_APP_SANDBOX = NO`）。

理由：sandboxed app call `SMAppService.daemon().register()` 會炸 "Invalid argument"。Mac app 預設用 sandbox 是因為 App Store 規範，但本工具不上 App Store（API 也不允許），所以拿掉。

helper 是 LaunchDaemon CLI tool，本來就不在 sandbox 範圍。

---

## 重要踩坑紀錄

- iOS 26 把 legacy `pymobiledevice3 developer simulate-location set` CLI 用的 service 砍了 → 改用 DVT instruments 的 `LocationSimulation`
- O.Paperclip bundled binary 帶 `com.apple.quarantine` flag，要 `xattr -d` 脫掉
- root user lockdown pair record 跟 user 不共用 — 第一次 helper 起 tunnel 會要求 iPhone 重新信任
- macOS 26 SDK SwiftUI `Map(position:)` overload 歧義 → 改用 `MKMapView` + `NSClickGestureRecognizer` wrap
- Xcode default Run Script Build Phase 開 sandbox → 手動 cp 動作會被擋（`ENABLE_USER_SCRIPT_SANDBOXING = NO`）

---

## 未來路線

- [ ] Notarize 自動化（給沒 Apple Dev 帳號的人）
- [ ] GPX 路線播放 endpoint（動態軌跡，目前只能 fixed point）
- [ ] 收藏常用座標（Recent Locations）
