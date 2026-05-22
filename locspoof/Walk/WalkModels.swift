import Foundation
import CoreLocation
import Combine

/// 主視窗點地圖時的行為模式。
enum MapMode: String, Sendable {
    case teleport       // 傳送：點地圖 → 立即傳送
    case walk           // 走路：點地圖 → 加入路徑佇列
    case squareCruise   // 方形巡迴：點地圖 A → 自動生 ABCD 4 點環路、邊長依速度算
    case freeDraw       // 畫圖：地圖上滑鼠拖一筆任意形狀 → 下採樣成 waypoint 佇列
}

/// 已收藏的常用位置。
struct SavedLocation: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var coordinate: Coordinate

    init(id: UUID = UUID(), name: String, coordinate: Coordinate) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}

extension Coordinate: Codable {
    enum CodingKeys: String, CodingKey { case lat, lon }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lat = try c.decode(Double.self, forKey: .lat)
        self.lon = try c.decode(Double.self, forKey: .lon)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
    }
}

/// 一個路徑目標（一朵花）。
final class WalkTarget: Identifiable, ObservableObject {
    enum Status: String, Sendable {
        case pending       // 還沒走到
        case walking       // 正在前往
        case waitingUser   // 抵達、等 user 採集完按繼續
        case done          // 採集完成
    }

    let id = UUID()
    let coordinate: Coordinate
    @Published var label: String
    @Published var status: Status = .pending

    init(coordinate: Coordinate, label: String) {
        self.coordinate = coordinate
        self.label = label
    }
}

/// 整個 cruise 任務的狀態快照。
@MainActor
final class WalkQueue: ObservableObject {
    @Published var targets: [WalkTarget] = []
    @Published var speedKmh: Double = 4.0
    @Published var currentIndex: Int = 0
    @Published var paused: Bool = false
    @Published var running: Bool = false

    /// 環路連續走：走完最後一點 → 重置 status 回 pending → 從第一點重來。
    /// 同時 cruise worker 抵達每點不會 pause、user 不用按繼續。
    @Published var isLoop: Bool = true

    /// 重新對齊 label 為 #1 #2 ...（drag reorder 或 delete 後呼叫）
    func renumberLabels() {
        for (i, t) in targets.enumerated() {
            t.label = "#\(i + 1)"
        }
    }

    func reset() {
        targets.removeAll()
        currentIndex = 0
        paused = false
        running = false
    }
}
