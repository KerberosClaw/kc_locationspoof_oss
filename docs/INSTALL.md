# Install

> **English summary:** Setup guide covering iPhone first-pair + Developer Mode (required for both deliverables) and Mac app build/install.

兩種使用方式擇一即可。iPhone 端準備（first-pair + Developer Mode）兩條都需要。

---

## Prerequisites（兩條共用）

- macOS 13 (Ventura) 以上
- iPhone 接 USB-C / Lightning 線到 Mac
- Apple ID（free Personal Team 可，paid Apple Developer Program 更佳）

### iPhone first-pair + Developer Mode

第一次在某 Mac 上跑此工具的 iPhone 必須走完這份。已配對過可跳過。

#### 1. Trust pairing

1. iPhone USB 接 Mac
2. iPhone 跳「信任這台電腦？」→ 點 **信任** → 輸入密碼
3. 首次也會在 Mac Finder 側欄看到裝置

驗證（Mac terminal）：

```bash
host/bin/pymobiledevice3 usbmux list
```

應該看到該裝置的 JSON。沒看到 → 重插 USB 重新跳對話框。

#### 2. Developer Mode（iOS 16+ 強制）

iPhone 上：

1. **設定 → 隱私與安全性 → 開發者模式**（拉到最下面）
2. 切 **開** → 跳警告 → 確認
3. **iPhone 重開機**
4. 開機後同位置再進 → 跳「啟用開發者模式？」→ 確認 + 輸密碼

> 此步 Mac 端**無法**自動化，Apple 設計上必須手動操作 iPhone。

驗證：iPhone 重開機後，設定 → 隱私與安全性 → 開發者模式 顯示 **開**。

---

## 路徑 A：CLI daemon（host/）

純 Python stdlib，不用 pip install。

```bash
sudo python3 host/start.py
```

第一次會問 Mac admin 密碼（RSD tunnel 要 raw socket）。看到：

```
[tunnel] up at fdcc:9f08:2f6b::1:55906
[dvt] stream ready
[http] listening on http://0.0.0.0:8765
```

就 OK。瀏覽器開：

- Mac：<http://127.0.0.1:8765/>
- 同 Wi-Fi 其他裝置：`http://<Mac-LAN-IP>:8765/`（`ipconfig getifaddr en0` 查 IP）

地圖右鍵任意處 → 確認 → iPhone 立刻跳到該座標。Ctrl-C 停 daemon。

---

## 路徑 B：Mac app

SwiftUI 選單列 app + privileged LaunchDaemon helper。

### 第一次 build

1. **Xcode 開 `kc_locationspoof.xcodeproj`**
2. Settings → Accounts 加自己 Apple ID
3. `locspoof` target → **Signing & Capabilities** → Team 改成自己的
4. `locspoof-helper` target → 同樣 Team 改自己
5. cmd+B

### 安裝 + 啟用 helper

從 Xcode **Product → Show Build Folder in Finder → Products** 找到 `locspoof.app`，拖到 `/Applications/`，雙擊開啟。


選單列 popover 顯示 **「尚未安裝」** + **安裝 Helper** 按鈕：

1. 點 **安裝 Helper** → 系統跳 admin 密碼
2. 輸完 → 狀態變 **「已啟用」** → 自動起 tunnel + dvt
3. 接 iPhone → popover 變 **「就緒」**


### 使用

- **popover**：看狀態、停止注入、結束 GUI
- **「開啟地圖…」**：開主視窗 → 單擊地圖任意處 = 注入
- **結束 GUI ≠ 停 daemon**：daemon 是 launchd 託管的常駐 root process。完全停 daemon 要去 系統設定 → 登入項目 → 把 helper toggle 關掉

---

## 給其他 Mac 用

直接拷 `.app` **不行**：簽名綁開發機 + iPhone pair 綁 Mac。三條：

1. **推薦**：對方裝 Xcode + 加自己 Apple ID + clone repo + Team 改自己 → cmd+B → install.sh
   - free Personal Team 可，但 cert 7 天過期
   - paid Apple Dev Program $99/yr 永久
2. 你 Developer ID Application + notarize 後 ship binary（要 paid Dev + 額外 setup）
3. 對方走 host/ CLI（不用 Xcode）

iPhone first-pair + Developer Mode 一定要在那台 Mac 上做。

---

## 常見錯

| 症狀 | 原因 | 解 |
|---|---|---|
| `usbmux list` 空 | trust pairing 沒完成 | 重插 USB |
| `tunnel did not return HOST PORT` | Developer Mode 沒開 | 上面第 2 步 |
| `dvt stream did not signal READY` | DeveloperDiskImage 沒 mount | `host/bin/pymobiledevice3 mounter auto-mount` |
| `Operation not permitted` | 沒 sudo | 加 sudo |
| iPhone 一直問配對 | pair 紀錄 stale | `sudo host/bin/pymobiledevice3 lockdown unpair` 後重配 |
| Mac app popover 顯示「Helper 離線」 | helper crash 中或 iPhone 沒接 | 確認 iPhone 接著 + 解鎖；看 `/Library/Logs/locspoof-helper.err.log` |
| Mac app `.notFound` / 找不到 Bundle | app 沒在 `/Applications/` | `./install.sh` 重 cp |
