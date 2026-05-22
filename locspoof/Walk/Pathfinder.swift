import Foundation

/// 路徑插值演算法。
/// haversine 算距離 → 用速度算 step 數 → 線性插值產生每秒 1 個 (lat, lon)。
enum Pathfinder {
    static let earthRadiusM: Double = 6_378_137.0
    static let tickSeconds: Double = 1.0

    /// 兩個 (lat, lon) 之間的大圓距離（公尺）。
    static func haversineMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    /// 從 start 走到 end、速度 speedKmh，吐每 tick (1s) 一個 (lat, lon)。
    /// 最後一個強制 snap 成 end，避免浮點 drift。空陣列 = 速度 0 或距離 0。
    static func buildPath(from start: Coordinate, to end: Coordinate, speedKmh: Double) -> [Coordinate] {
        guard speedKmh > 0 else { return [] }
        let dist = haversineMeters(start, end)
        guard dist >= 0.01 else { return [] }
        let speedMs = speedKmh * 1000 / 3600
        let nSteps = max(1, Int(ceil(dist / (speedMs * tickSeconds))))
        var path: [Coordinate] = []
        path.reserveCapacity(nSteps)
        for i in 1...nSteps {
            let t = Double(i) / Double(nSteps)
            let lat = start.lat + (end.lat - start.lat) * t
            let lon = start.lon + (end.lon - start.lon) * t
            path.append(Coordinate(lat: lat, lon: lon))
        }
        // snap 最後一格到精準 end
        path[path.count - 1] = end
        return path
    }
}
