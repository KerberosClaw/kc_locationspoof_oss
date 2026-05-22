# Security

> **English summary:** Supply chain audit of the bundled third-party binaries (pymobiledevice3 + dvt-location-stream from O.Paperclip), what was checked, what trust assumptions remain, and how to rebuild from upstream source for a fully self-verified chain.

---

## 第三方 binary

| 檔案 | 來源 | License |
|---|---|---|
| `host/bin/pymobiledevice3` | [doronz88/pymobiledevice3](https://github.com/doronz88/pymobiledevice3)（PyInstaller bundled） | GPL-3.0 |
| `host/bin/dvt-location-stream` | [agocia/O.paperclip](https://github.com/agocia/O.paperclip)（30 行 Python wrapper, PyInstaller bundled） | MIT |

兩者皆以 root LaunchDaemon 形式執行 — **blast radius = 整台 Mac + 你 pair 過的 iPhone**。

審查結論：source 公開可審、邏輯純粹（只動 iPhone DVT location service）、沒外部網路連線、沒檔案 IO out-of-scope。

剩餘信任假設：
- `doronz88/pymobiledevice3` 上游沒被汙染
- O.Paperclip 預編譯的 binary 跟其 source 真的對得上（要消除這條 → [自己 rebuild](#自己-rebuild-from-source)）

---

## 已做的審查

### 1. Source 可見

`dvt-location-stream` 的 source 是 [`scripts/dvt_location_stream.py`](https://github.com/agocia/O.paperclip/blob/main/scripts/dvt_location_stream.py)，30 行：

```python
import asyncio, sys
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import DvtSecureSocketProxyService
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

host = sys.argv[1]; port = int(sys.argv[2])

async def main():
    rsd = RemoteServiceDiscoveryService((host, port))
    await rsd.connect()
    with DvtSecureSocketProxyService(rsd) as dvt:
        sim = LocationSimulation(dvt)
        print("READY", flush=True)
        for raw in sys.stdin:
            line = raw.strip()
            if line == "QUIT": break
            if line == "CLEAR":
                sim.clear(); print("CLEARED", flush=True); continue
            seq, lat, lon = line.split(",", 2)
            sim.set(float(lat), float(lon))
            print(f"OK {seq}", flush=True)
    await rsd.close()
asyncio.run(main())
```

讀 stdin 命令 → 透過 pymobiledevice3 三個 module 動 DVT location simulation。**沒網路外連、沒檔案 IO、沒 out-of-scope 行為**。

### 2. Build process 可見

[`scripts/build-dvt-stream.sh`](https://github.com/agocia/O.paperclip/blob/main/scripts/build-dvt-stream.sh) 是標準 PyInstaller `--onefile` 打包，沒額外步驟。

### 3. 動態連結

```bash
otool -L host/bin/{pymobiledevice3,dvt-location-stream}
# 兩個都只 link libSystem.B.dylib + libz.1.dylib
```

PyInstaller bootloader 預期最小 surface。真正 deps 從 `/tmp/_MEI*/` extract 後 dlopen。

### 4. Trust chain

- O.Paperclip：MIT license、agocia/O.paperclip、source 公開
- pymobiledevice3 上游：[doronz88/pymobiledevice3](https://github.com/doronz88/pymobiledevice3)，well-known iOS dev/security 工具，廣泛 reproduceable

---

## 沒做的（如要徹底 audit）

- ❌ Runtime 網路監控（Little Snitch / lulu / `nettop` 攔看真的只連 iPhone RSD）
- ❌ Hash 比對：我們 host/bin/* 的 SHA256 跟 O.Paperclip GitHub 那份的對得上嗎
- ❌ 我們**沒有**從 doronz88/pymobiledevice3 上游 source 自己 rebuild

---

## 自己 rebuild from source

要 bypass「O.Paperclip 預編譯 binary 是否被汙染」這條信任假設，自己 build：

```bash
# 1. 裝 pymobiledevice3 + PyInstaller
pipx install pymobiledevice3
pipx inject pymobiledevice3 pyinstaller

# 2. clone O.Paperclip
git clone https://github.com/agocia/O.paperclip ~/tmp/o.paperclip
cd ~/tmp/o.paperclip

# 3. build
./scripts/build-dvt-stream.sh
./scripts/build-bundled-pymobiledevice3.sh

# 4. 取代我們 host/bin/*
cp bundled/dvt-location-stream <repo>/host/bin/
cp bundled/pymobiledevice3-bundle/pymobiledevice3 <repo>/host/bin/

# 5. 重 pre-sign 帶 entitlements（必須）
codesign --force --sign - --entitlements <repo>/support/locspoof-helper.entitlements --options runtime <repo>/host/bin/pymobiledevice3
codesign --force --sign - --entitlements <repo>/support/locspoof-helper.entitlements --options runtime <repo>/host/bin/dvt-location-stream
```

之後 trust chain 變成：你自己 build + pymobiledevice3 上游 source（可 audit，廣為使用）。

---

## Code signing 補充

helper 開了 hardened runtime + 預設 library validation。子程序（pmd / dvt）dlopen 自己 PyInstaller 內部 `Python.framework` 時，**子程序自己**要有 `disable-library-validation` entitlement，所以 `host/bin/*` 已 pre-sign 帶 entitlements。

Pre-sign 的 entitlements 在 [`support/locspoof-helper.entitlements`](../support/locspoof-helper.entitlements)，內容：

```xml
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
```

這三個都是執行 PyInstaller bundle 必要的 hardened-runtime exception。

---

## 通報

發現安全問題請開 GitHub issue 標 `[security]`。短期可走 email — 但 repo 預設不公開維護者聯絡，請先看 git log 找 author。
