# locspoof — 騙你的 iPhone 它人在別處

[English](README.md)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13+-blue.svg)](https://www.apple.com/macos/)
[![Swift 5+](https://img.shields.io/badge/Swift-5+-orange.svg)](https://swift.org)

從 Mac 把假座標推進 iPhone，整個系統都吃這個位置 — 蘋果地圖、Google 地圖、尋找、你常用的交友程式，全部一視同仁。**不用越獄**，不用搞側載那套，純粹拿蘋果自家給開發者的 DVT 通道做這件事。

<img src="docs/images/main-window.png" alt="locspoof 主視窗" width="640">

兩種用法可選，底層走的都是同一個機制，挑哪條看你習慣：

| | `host/` 命令列版 | `locspoof/` Mac 程式 |
|---|---|---|
| 怎麼跑 | `sudo python3 host/start.py` | 點選單列 icon，點地圖 |
| 要打 sudo 密碼 | 每次都要 | 第一次安裝完就再也不用 |
| 介面 | 瀏覽器開 Leaflet 地圖 | 原生選單列 + 蘋果地圖 |
| 適合 | 開發者、寫腳本、活在終端機的人 | 想點個 icon 就用的人 |

## 快速上手

不管走哪條路，iPhone 都要先做一次配對握手 + 打開「開發者模式」。蘋果官方文件散在 2018 年的論壇裡，我們自己寫了一份比較乾淨的：[docs/INSTALL.md](docs/INSTALL.md)。

**命令列：**

```bash
sudo python3 host/start.py
# 然後瀏覽器開 http://127.0.0.1:8765/
```

**Mac 程式：**

```text
1. Xcode 開 kc_locationspoof.xcodeproj
2. Signing & Capabilities → Team 改成你自己的（兩個 target 都要）
3. cmd+B
4. 把 locspoof.app 拖到 /Applications/
5. 點選單列 icon → 按一次「安裝 Helper」→ 完成
```

## 文件

- [INSTALL.md](docs/INSTALL.md) — 完整安裝流程，包含 iPhone 配對的細節
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — 內部架構，也記了我們替你踩過的 code signing 地雷
- [USAGE.md](docs/USAGE.md) — 操作手冊：四個地圖點擊模式（傳送 / 走路 / 巡迴 / 畫圖）+ 巡迴幾何 + 走路時連動步數更新 + 反作弊參考
- [SECURITY.md](docs/SECURITY.md) — 我們夾帶了哪些第三方執行檔、怎麼審的、想自己從原始碼重編怎麼做

## 安全性聲明

我們夾兩個第三方 PyInstaller 打包的執行檔（`pymobiledevice3` 來自 [doronz88](https://github.com/doronz88/pymobiledevice3)，`dvt-location-stream` 來自 [O.Paperclip](https://github.com/agocia/O.paperclip)），而且是用 root LaunchDaemon 跑，這對上游給了相當大的信任。兩者原始碼都公開可審，我們審過了，沒鬼。**真的要保險點，自己從上游原始碼重編一份**，步驟在 [docs/SECURITY.md](docs/SECURITY.md)。

發現安全問題？走 [GitHub Security Advisories](../../security/advisories/new) 私下提報，別開公開議題。

## 授權

GPL-3.0。我們夾的 `pymobiledevice3` 是 GPL-3.0，整個專案就只能跟著走 GPL，全文在 [LICENSE](LICENSE)。

站在這些工具的肩膀上：

- [doronz88/pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — iOS DVT 真正幹活的底層（GPL-3.0）
- [agocia/O.paperclip](https://github.com/agocia/O.paperclip) — `dvt-location-stream` 包裝 + PyInstaller 配方（MIT）

**請用在正當用途。** 開發測試、保護自己位置隱私、讓「尋找」以為你在家但其實在咖啡廳 — 都好。但別拿來詐騙、位置型遊戲作弊、或任何會讓蘋果條款團隊發火的事。他們也是有情緒的。
