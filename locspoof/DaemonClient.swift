import Foundation

struct Coordinate: Sendable, Equatable {
    var lat: Double
    var lon: Double
}

/// Mirrors the helper's HelperState. Optional in DaemonStatus because an
/// older helper binary won't include this field — UI falls back to dvtAlive.
enum HelperPhase: String, Sendable {
    case waitingForDevice = "waiting_for_device"
    case connecting       = "connecting"
    case ready            = "ready"
    case restarting       = "restarting"
}

struct DaemonStatus: Sendable, Equatable {
    var phase: HelperPhase?
    var tunnel: String?
    var dvtAlive: Bool
    var lastSeq: Int
    var lastLoc: Coordinate?

    static let empty = DaemonStatus(
        phase: nil, tunnel: nil, dvtAlive: false, lastSeq: 0, lastLoc: nil
    )
}

actor DaemonClient {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
    }

    private struct StatusJSON: Decodable {
        let state: String?
        let tunnel: String?
        let dvt_alive: Bool
        let last_seq: Int
        let last_loc: [Double]?
    }

    func status() async throws -> DaemonStatus {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        req.timeoutInterval = 1.5
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(StatusJSON.self, from: data)
        let coord = json.last_loc.flatMap { arr -> Coordinate? in
            guard arr.count == 2 else { return nil }
            return Coordinate(lat: arr[0], lon: arr[1])
        }
        return DaemonStatus(
            phase: json.state.flatMap(HelperPhase.init(rawValue:)),
            tunnel: json.tunnel,
            dvtAlive: json.dvt_alive,
            lastSeq: json.last_seq,
            lastLoc: coord
        )
    }

    func inject(lat: Double, lon: Double) async throws {
        var comp = URLComponents(
            url: baseURL.appendingPathComponent("api/loc"),
            resolvingAgainstBaseURL: false
        )!
        comp.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
        ]
        var req = URLRequest(url: comp.url!)
        req.timeoutInterval = 2.0
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    func clear() async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/clear"))
        req.httpMethod = "POST"
        req.timeoutInterval = 2.0
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
