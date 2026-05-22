# Usage

> **English summary:** User guide for the locspoof Mac app — four map-click modes (teleport / walk / square cruise / freeDraw), cruise geometry & anti-cheat math, and an auto-fire-on-walk Mac shortcut hook you can chain into anything (typical use: iCloud Focus → iPhone automation → HealthKit step sample).

---

主視窗（選單列 icon → 開地圖）所有功能用法塞這一份、不用東翻西找。安裝的事去 [INSTALL.md](INSTALL.md)、想看 app 內部怎麼接的去 [ARCHITECTURE.md](ARCHITECTURE.md)。

---

## 30 秒上手

主視窗左邊的「模式」選項切一下，**點地圖的行為就跟著變**——這是整個 app 的核心介面邏輯。四種模式：傳送 / 走路 / 巡迴 / 畫圖。

切換模式時會自動 `clearQueue()` 把舊路徑清掉。**這是故意的**——我們以前沒清、使用者切了模式還在納悶為什麼舊路徑點在新模式下沒效果，後來補上。

走路類三種模式（走路 / 巡迴 / 畫圖）下面都有一個勾選框「[走路時連動步數更新](#走路時連動步數更新)」，走路期間會自動每 20 秒戳一下你預先建好的 Mac 捷徑。典型搭法是讓 iPhone「健康」app 跟著加步數，但其實你想叫它幹嘛都行——詳見下面那節。

---

## 四個地圖點擊模式

| 模式 | 點地圖行為 | 佇列 | 用途 |
|------|------------|------|------|
| 傳送 (teleport) | 立即注入 GPS 到該座標 | 不用 | 單次跳位 |
| 走路 (walk) | 加路徑點到佇列尾 | 多點 | 手動排路徑、環路採集 |
| 巡迴 (squareCruise) | 該點當 A、自動生 ABCD 4 點正方形 | 固定 4 點 | 自動匀速繞圈、累計距離 |
| 畫圖 (freeDraw) | 拖滑鼠畫任意路徑、自動下採樣成路徑點佇列 | 動態（由筆觸生成）| 不規則路線、規劃既有道路走 |

### 巡迴模式為什麼要自動算邊長

巡迴的設計目標是「畫一個方框、永久繞圈」，但「方框多大」這事不能讓使用者自己拍——拍小了伺服器端的行為模型會看到你在原地打轉、拍大了根本走不完一圈。所以我們做成**邊長吃速度自動算**：

#### 邊長公式

```text
x = speed / 48 × 1.2  km
```

`speed / 48` 是「讓一圈剛好 5 分鐘」的最小邊長（推導在下面）：

```text
4x / speed > 5/60  →  x > speed/48
```

`× 1.2` 是安全餘裕、怕剛好踩在 5 分鐘邊界被抓。實際一圈 `4x / speed = 0.1 h` = **6 分鐘恆等**——這個數字不管怎麼拖速度都一樣，因為 x 跟著速度同比例縮放。

| speed (km/h) | x (m) | 4x (m) | 一圈 |
|--------------|-------|--------|------|
| 4 | 100.0 | 400.0 | 6:00 |
| 7 | 175.0 | 700.0 | 6:00 |
| 20 | 500.0 | 2000.0 | 6:00 |

#### 幾何（north up、地理方位）

```text
       ↑ N
   B ←─x─ A
   │       │
   x       x
   │       │
   C ─x─→ D
```

A 是你點的那一點（紫旗錨點）。B = A 西邊 x、C = B 南邊 x、D = C 東邊 x，路徑 `A → B → C → D → A` 永久循環。

經緯度換算（用局部平面投影、短距離下地球當平的夠用）：

```text
dLat = x / 111
dLon = x / (111 × cos(A.lat))
B = (A.lat,        A.lon - dLon)
C = (A.lat - dLat, A.lon - dLon)
D = (A.lat - dLat, A.lon)
```

#### 操作流程

1. 模式選「巡迴」→ 佇列自動清空
2. 點地圖 A → `spawnSquare()` 生 ABCD、地圖自動縮放到剛好把方形塞進視野（餘白 60%）、藍色虛線把 ABCD 連起來
3. 跳對話框「注入到 A 點？」
   - **確定**：注入 GPS 到 A
   - **取消**：`clearQueue()` 清空、不注入
4. 拖速度滑桿 → 用新速度重算 x、ABCD 跟著重生（A 不動、BCD 同比例縮放）
5. 按「開始走」→ ABCDA 永久循環

#### 防呆機制（理論上不會被觸發、但留著比較安心）

按「開始走」前會檢查 `squareLoopMinutes >= 5.0`，沒過就阻擋 + 跳對話框提示降速或重新點。

事實上步驟 4「拖速度自動重算」讓一圈永遠 = 6 分鐘，這個檢查在現行流程下**永遠不會被觸發**。但我們還是留著——萬一未來加手動覆寫邊長的功能、這條就會回來救命。

---

## 共用 UI

| 元件 | 適用模式 | 說明 |
|------|----------|------|
| 速度滑桿 | 走路 / 巡迴 / 畫圖 | `[4, 20]` km/h、step 0.5；>7 紅字警告 |
| 路徑佇列列表 | 走路 / 巡迴 / 畫圖 | 拖曳排序、x 刪除（跑中也可改、自動處理邊緣狀況）|
| 開始走 | 走路 / 巡迴 / 畫圖 | `isLoop` 寫死 true、走完回 #1 永久環路 |
| 清空 | 走路 / 巡迴 / 畫圖 | `clearQueue()` = 取消 + 重設 |
| 停止 | 全部 | `walk.cancel()` 終止當前走路 |
| 走路時連動步數更新（勾選框）| 走路 / 巡迴 / 畫圖 | 走路期間每 20 秒觸發 `shortcuts run FlipStepFocus`，詳見[下一節](#走路時連動步數更新) |
| 恢復真實 GPS（緊急區）| 全部 | `walk.cancel()` + `status.stopSpoof()` — 一鍵清乾淨（同時關掉連動步數的觸發循環） |

---

## 走路時連動步數更新

走路期間自動戳一支你預先建好的 Mac 捷徑。走路控制下方有個勾選框「走路時連動步數更新」+ 一行說明文字（勾起來之後想戳幾下隨你）。

### 能用來幹嘛

把任何你想跟「走路歷程」連動的動作包成一支 Mac 捷徑、勾起勾選框、走路就會自動每 20 秒觸發一次。我們不假設你要做什麼——常見搭法：

- **最熱門用途**：透過專注模式 → iCloud 同步 → iPhone「捷徑」自動化 → 寫入「健康」app 步數樣本（某些位置型遊戲會抓步數來推進，不是我們說的、是使用者反映的）
- 透過 Mac 端 AppleScript / shell 記錄走路歷程
- 觸發其他 macOS 自動化 / 智慧家庭動作（讓燈跟著閃？沒人攔你）

### 設定（兩步）

#### 1. 在 Mac「捷徑」app 內建立 `FlipStepFocus`

打開 Mac 內建的「捷徑」app、新增一支、命名為 **`FlipStepFocus`**（**一字不差**——我們把名字寫死、就是為了讓你不用每次設）。捷徑內容由你決定。

#### 2. 勾起勾選框、按開始走

- locspoof 切到走路 / 巡迴 / 畫圖任一模式、加路徑點或畫好路徑
- 勾「走路時連動步數更新」
- 按「開始走」
- 勾選框旁邊亮綠點 ● 表示觸發循環正在跑
- 走路期間每 20 秒觸發一次 `shortcuts run FlipStepFocus`

按「停止」、取消勾選、或按「恢復真實 GPS」→ 循環立刻停。設定會記下來（下次開 app 還記得你勾過）。

### 裡面怎麼跑

觸發循環要四個條件同時成立才會觸發（任一條不成立都會立刻停）：

- `enabled`（勾選框是勾起的）
- `walk.queue.running`（走路執行緒在跑）
- `!walk.queue.paused`（單趟模式抵達路徑點等使用者確認時會暫停）
- `status.isSpoofing`（spoof daemon 真的在注入 GPS，不是就緒中 / 重連中 / helper 掛了）

最後那條 spoof 閘門是踩坑補上的：原本只看前三條、結果使用者走到一半按「恢復真實 GPS」、daemon 停了、循環還在繼續戳 Mac 捷徑——iPhone 端就會收到「走路停了但步數還在加」的詭異狀態。

其他細節：

- 環路模式持續走就持續觸發
- Mac 捷徑名稱寫死 `FlipStepFocus`，不開放介面設定（少一個會打錯的地方）
- 觸發間隔 20 秒、`Process()` 子程序、不會卡住主執行緒
- spoof 掉線（daemon 掛掉 / 重連）會自動暫停、回來後自動恢復

### 壞掉的時候

#### 勾選框勾起但沒觸發

```bash
shortcuts list | grep FlipStepFocus
```

沒看到？回「捷徑」app 確認名字**一字不差**（這是最常見的雷區）。

順便看一下選單列 icon 顯示什麼——必須是「注入中」(綠色 location.fill) 循環才會跑。如果顯示「就緒」「重新連線中」之類，觸發被 spoof 閘門攔下來了、不是 bug。

#### 觸發了但 iPhone 端沒反應

`shortcuts run FlipStepFocus` 只負責戳 Mac 捷徑——後面那段鏈路（iCloud 同步 / iPhone 自動化 / 寫健康 app）是你的捷徑內容決定的、跟 locspoof 沒關係。手動跑一次：

```bash
shortcuts run FlipStepFocus
```

看 Mac 端執行結果（有沒有錯誤、有沒有正確叫出後續動作）才知道是 Mac 端死、還是 iPhone 端沒接到。

#### 想立刻停掉循環

按緊急區「恢復真實 GPS」一鍵清乾淨——三件事一起做：

1. 取消走路執行緒（`walk.queue.running` 變 false）
2. 停止 spoof daemon（`status.isSpoofing` 變 false）
3. 觸發循環因為這兩條都掛掉、自動停

**三道防線、不會卡住繼續灌步**——這也是我們踩坑後補的。

---

## 反作弊參考

- 速度 ≤ 7 km/h 介面不警告（一般步行 4-5、快走 5-6、競走 7，超過就不像人類）
- 巡迴模式一圈 ≥ 5 min 是硬性規則——短迴圈在伺服器端的行為模型看起來像「鬼打牆」、會被抓
- 7 km/h 以上會紅字警告、20 是滑桿上限（已經近慢跑、本來就不該用，但留著萬一你真的想試）

---

## 相關程式檔

- `locspoof/ContentView.swift` — 介面（側邊欄、地圖點擊、各模式處理、勾選框）
- `locspoof/Walk/CruiseWorker.swift` — `WalkController` + `spawnSquare(at:)` / `regenerateSquare()`
- `locspoof/Walk/WalkModels.swift` — `MapMode` enum、`WalkQueue`、`WalkTarget`
- `locspoof/Walk/Pathfinder.swift` — 球面插值 + 速度 tick
- `locspoof/Walk/WalkStepTrigger.swift` — 走路時連動步數更新的觸發循環
