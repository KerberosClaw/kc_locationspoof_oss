import Foundation
import Combine
import SwiftUI

/// 走路任務協調者。
/// 負責：
///   - 啟動 / 取消 cruise background Task
///   - 1Hz tick 下發 GPS via DaemonClient
///   - 抵達目標時 pause、等 user 按繼續
///   - latest-wins target switch (FR6.2)
///   - Null Island 防呆：refuse start 若 daemon last_loc 是 nil
@MainActor
final class WalkController: ObservableObject {
    enum WalkError: LocalizedError {
        case noStartPosition
        case daemonUnreachable
        case empty

        var errorDescription: String? {
            switch self {
            case .noStartPosition: return "無法 teleport 到 waypoint #1 — daemon 沒回應或拒絕 inject"
            case .daemonUnreachable: return "daemon 沒回應"
            case .empty: return "佇列空"
            }
        }
    }

    @Published private(set) var queue = WalkQueue()
    @Published var mode: MapMode = .teleport

    /// 使用者上次選的速度、開 App 自動還原。
    @AppStorage("walk_speed_kmh") var savedSpeedKmh: Double = 4.0

    private let client: DaemonClient
    private weak var status: StatusModel?
    private var worker: Task<Void, Never>?
    private var queueObserver: AnyCancellable?

    init(client: DaemonClient = DaemonClient()) {
        self.client = client
        // queue 是 nested ObservableObject，內部 @Published 改動不會自動冒泡到
        // outer WalkController。手動轉發、讓 UI 即時 reflect queue 變動
        // (例如 toggle isLoop 後 checkbox 立即勾、不用等 2s polling re-render)。
        queueObserver = queue.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func attach(status: StatusModel) {
        self.status = status
        // clamp 舊存值到當前 slider 範圍下限（4 km/h、一般步行）
        queue.speedKmh = max(4.0, savedSpeedKmh)
    }

    func setSpeed(_ kmh: Double) {
        queue.speedKmh = kmh
        savedSpeedKmh = kmh
    }

    /// 切換環路模式。如果切到「環路」時 cruise 正卡在 waitingUser pause，
    /// 同步清掉 paused 讓 worker 自己跳出 pause loop 繼續環路。
    func setLoop(_ value: Bool) {
        queue.isLoop = value
        if value && queue.paused {
            queue.paused = false
        }
    }

    // MARK: - Square cruise

    /// 方形邊長（公里）= speed / 48 × 1.2。
    /// speed / 48 是「一圈 = 5 分鐘」的最小邊長、× 1.2 是 margin、實際一圈固定 6 分鐘。
    var squareSideLengthKm: Double {
        queue.speedKmh / 48.0 * 1.2
    }

    /// 方形繞一圈所需分鐘 = 4x / speed × 60。
    var squareLoopMinutes: Double {
        squareSideLengthKm * 4.0 / queue.speedKmh * 60.0
    }

    /// 用 A 座標生成 ABCD 4 點（A 不動、B 西、C 西南、D 南、north up 地理方位）。
    /// 既有 queue 一律覆蓋；跑中先 cancel。
    func spawnSquare(at a: Coordinate) {
        let x = squareSideLengthKm
        let dLat = x / 111.0
        let dLon = x / (111.0 * cos(a.lat * .pi / 180.0))

        cancel()
        queue.targets = [
            WalkTarget(coordinate: a,
                       label: "#1"),
            WalkTarget(coordinate: Coordinate(lat: a.lat,        lon: a.lon - dLon),
                       label: "#2"),
            WalkTarget(coordinate: Coordinate(lat: a.lat - dLat, lon: a.lon - dLon),
                       label: "#3"),
            WalkTarget(coordinate: Coordinate(lat: a.lat - dLat, lon: a.lon),
                       label: "#4"),
        ]
        queue.currentIndex = 0
    }

    /// 抓既有 A（targets[0]）+ 當前 speed 重生 BCD — speed slider 拖動觸發。
    func regenerateSquare() {
        guard queue.targets.count == 4 else { return }
        let a = queue.targets[0].coordinate
        spawnSquare(at: a)
    }

    // MARK: - Queue editing

    func addTarget(at coordinate: Coordinate) {
        let label = "#\(queue.targets.count + 1)"
        queue.targets.append(WalkTarget(coordinate: coordinate, label: label))
    }

    /// 一次塞一整條 path（畫圖 mode 用），清掉舊 queue 再 append。
    func replaceTargets(with coordinates: [Coordinate]) {
        cancel()
        queue.targets.removeAll()
        for (i, c) in coordinates.enumerated() {
            queue.targets.append(WalkTarget(coordinate: c, label: "#\(i + 1)"))
        }
        queue.currentIndex = 0
    }

    func removeTarget(id: UUID) {
        guard let idx = queue.targets.firstIndex(where: { $0.id == id }) else { return }
        let removed = queue.targets.remove(at: idx)
        // 走路中刪 current → 取消、跳下一個（簡單做法：cancel 整段走路、user 自己重啟）
        if queue.running && removed.status == .walking {
            cancel()
            return
        }
        // 對齊 current_index：刪除位置 < current 則 current 跟著前移
        if idx < queue.currentIndex {
            queue.currentIndex = max(0, queue.currentIndex - 1)
        }
        queue.renumberLabels()
    }

    func moveTargets(from source: IndexSet, to destination: Int) {
        queue.targets.move(fromOffsets: source, toOffset: destination)
        queue.renumberLabels()
        // 重新對齊 current_index 到「目前 walking 那筆的新位置」
        if let walkingIdx = queue.targets.firstIndex(where: { $0.status == .walking }) {
            queue.currentIndex = walkingIdx
        }
    }

    func clearQueue() {
        cancel()
        queue.reset()
    }

    // MARK: - Cruise lifecycle

    func startWalk() async throws {
        guard !queue.targets.isEmpty else { throw WalkError.empty }

        let snap: DaemonStatus
        do {
            snap = try await client.status()
        } catch {
            throw WalkError.daemonUnreachable
        }
        // 若 daemon 還沒有任何 spoof 位置 — 自動 teleport 到 waypoint #1 當起點。
        // 涵蓋畫圖模式（user 不會主動 tap 地圖 inject）+ 任何 mode 第一次啟動。
        let last: Coordinate
        if let l = snap.lastLoc {
            last = l
        } else {
            let first = queue.targets[0].coordinate
            do {
                try await client.inject(lat: first.lat, lon: first.lon)
            } catch {
                throw WalkError.noStartPosition
            }
            last = first
        }
        // reset pending status (允許重跑已 done 的 queue)
        for t in queue.targets {
            if t.status != .done { t.status = .pending }
        }
        queue.currentIndex = 0
        queue.paused = false
        queue.running = true

        worker?.cancel()
        worker = Task { [weak self] in
            await self?.runWorker(startGPS: last, speedKmh: self?.queue.speedKmh ?? 4.0)
        }
    }

    func resume() {
        queue.paused = false
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        queue.running = false
        queue.paused = false
        // 把走路中目標標回 pending（讓 UI 看起來乾淨）
        for t in queue.targets where t.status == .walking || t.status == .waitingUser {
            t.status = .pending
        }
    }

    // MARK: - Worker loop

    private func runWorker(startGPS: Coordinate, speedKmh: Double) async {
        var cur = startGPS
        while true {
            if Task.isCancelled { return }
            // queue 走完
            if queue.currentIndex >= queue.targets.count {
                if queue.isLoop && !queue.targets.isEmpty {
                    // 環路：重置 status 全部回 pending、從第一點重來
                    for t in queue.targets { t.status = .pending }
                    queue.currentIndex = 0
                    continue
                }
                break
            }
            let idx = queue.currentIndex
            let target = queue.targets[idx]
            if target.status == .done {
                queue.currentIndex = idx + 1
                continue
            }
            target.status = .walking
            let path = Pathfinder.buildPath(from: cur, to: target.coordinate, speedKmh: speedKmh)
            for step in path {
                if Task.isCancelled { return }
                do {
                    try await client.inject(lat: step.lat, lon: step.lon)
                } catch {
                    cancel()
                    return
                }
                cur = step
                try? await Task.sleep(for: .seconds(Pathfinder.tickSeconds))
            }
            if queue.isLoop {
                // 環路模式：抵達直接 mark done、繼續下一點、不等 user
                target.status = .done
            } else {
                // 單趟模式：抵達 → 等 user 按繼續
                target.status = .waitingUser
                queue.paused = true
                while queue.paused {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                target.status = .done
            }
            queue.currentIndex = idx + 1
        }
        queue.running = false
    }
}
