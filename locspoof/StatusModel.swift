import Foundation
import SwiftUI
import Combine

@MainActor
final class StatusModel: ObservableObject {
    /// UI-level state. Maps from helper's `phase` plus reachability + lastLoc.
    /// `helperDown` is GUI-only (helper unreachable); the rest mirror helper.
    enum State {
        case helperDown        // /api/status didn't answer → helper process gone
        case waitingForDevice  // helper alive, no iPhone visible
        case reconnecting      // helper retry loop is mid-attempt
        case ready             // tunnel + dvt up, no active spoof
        case spoofing          // tunnel + dvt up, lastLoc set
    }

    @Published private(set) var snapshot: DaemonStatus = .empty
    @Published private(set) var reachable: Bool = false

    /// User-staged location not yet sent to helper. Cleared on successful
    /// inject. Independent from `snapshot.lastLoc` (which mirrors what the
    /// helper is actively spoofing).
    @Published var previewCoord: Coordinate?

    private let client = DaemonClient()
    private var pollTask: Task<Void, Never>?

    init() {
        startPolling()
    }

    var state: State {
        guard reachable else { return .helperDown }
        // Prefer helper's phase when present (new helper). Older helper binary
        // won't include `state` in /api/status — fall back to dvt_alive.
        if let phase = snapshot.phase {
            switch phase {
            case .ready:
                return snapshot.lastLoc == nil ? .ready : .spoofing
            case .connecting, .restarting:
                return .reconnecting
            case .waitingForDevice:
                return .waitingForDevice
            }
        }
        guard snapshot.dvtAlive else { return .waitingForDevice }
        return snapshot.lastLoc == nil ? .ready : .spoofing
    }

    var iconSystemName: String {
        switch state {
        case .helperDown:        return "location.slash"
        case .waitingForDevice:  return "iphone.slash"
        case .reconnecting:      return "arrow.triangle.2.circlepath"
        case .ready:             return "location"
        case .spoofing:          return "location.fill"
        }
    }

    var iconColor: Color {
        switch state {
        case .helperDown:        return .secondary
        case .waitingForDevice:  return .orange
        case .reconnecting:      return .orange
        case .ready:             return .blue
        case .spoofing:          return .green
        }
    }

    var headline: String {
        switch state {
        case .helperDown:        return "Helper 離線"
        case .waitingForDevice:  return "等待 iPhone"
        case .reconnecting:      return "重新連線中…"
        case .ready:             return "就緒"
        case .spoofing:          return "注入中"
        }
    }

    /// What the user can actually do in this state. nil when no action is
    /// needed (the retry loop will recover on its own, or we're already up).
    var troubleshootHint: String? {
        switch state {
        case .helperDown:
            return "Helper daemon 沒回應。試重新開啟 locspoof 應用程式，或執行 `sudo launchctl kickstart -k system/org.locspoof.app.helper`。仍無法恢復請查看 `/Library/Logs/locspoof-helper.err.log`。"
        case .waitingForDevice:
            return "未偵測到 iPhone。檢查：USB 線是否為資料線、iPhone 已解鎖、若彈出「信任此電腦」請點允許。"
        case .reconnecting:
            return "正在重試連線。若超過 30 秒仍卡住，檢查：iPhone 上「信任此電腦」彈窗、Developer Mode 是否開啟。仍無法恢復請查看 `/Library/Logs/locspoof-helper.err.log`。"
        case .ready, .spoofing:
            return nil
        }
    }

    var coordinateText: String? {
        guard let c = snapshot.lastLoc else { return nil }
        return String(format: "%.4f, %.4f", c.lat, c.lon)
    }

    var isSpoofing: Bool { state == .spoofing }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        do {
            let snap = try await client.status()
            snapshot = snap
            reachable = true
        } catch {
            reachable = false
            snapshot = .empty
        }
    }

    func setPreview(lat: Double, lon: Double) {
        previewCoord = Coordinate(lat: lat, lon: lon)
    }

    func clearPreview() {
        previewCoord = nil
    }

    func inject(lat: Double, lon: Double) async {
        try? await client.inject(lat: lat, lon: lon)
        previewCoord = nil
        await refresh()
    }

    func stopSpoof() async {
        try? await client.clear()
        await refresh()
    }
}
