import Foundation
import Combine
import SwiftUI

/// 走路時自動 fire 一支 macOS 捷徑（generic trigger 層）。
///
/// 觀察 WalkController.queue.running + paused，在走路期間每 N 秒透過
/// macOS Shortcuts CLI (`shortcuts run <name>`) fire 一次。具體那支捷徑
/// 做什麼由 user 自己在 Mac「捷徑」app 內配（e.g., 觸發專注模式 / iCloud
/// 同步 / iPhone 自動化 / 寫入「健康」app 步數樣本）。
///
/// 預設 disabled、UI checkbox 控制。enabled 狀態 persistent (UserDefaults)。
@MainActor
final class WalkStepTrigger: ObservableObject {
    @AppStorage("walk_step_trigger_enabled") var enabled: Bool = false {
        didSet { reconcile() }
    }

    /// 對應的 Mac 捷徑名稱。user 要先在 Mac「捷徑」app 內建好同名 shortcut。
    static let shortcutName = "FlipStepFocus"

    /// 兩次 fire 之間 sleep 秒數。
    static let sleepSeconds: UInt64 = 20

    private weak var walk: WalkController?
    private weak var status: StatusModel?
    private var loop: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []

    func attach(walk: WalkController, status: StatusModel) {
        self.walk = walk
        self.status = status
        // Observe walk queue state (running/paused) + status changes (spoof state).
        // status.objectWillChange fires on any @Published mutation; reconcile() reads
        // status.isSpoofing fresh each tick.
        Publishers.Merge3(
            walk.queue.$running.map { _ in () }.eraseToAnyPublisher(),
            walk.queue.$paused.map { _ in () }.eraseToAnyPublisher(),
            status.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.reconcile() }
        .store(in: &observers)
    }

    private func reconcile() {
        let running = walk?.queue.running ?? false
        let paused = walk?.queue.paused ?? false
        let spoofing = status?.isSpoofing ?? false
        let shouldRun = enabled && running && !paused && spoofing
        if shouldRun && loop == nil {
            startLoop()
        } else if !shouldRun {
            stopLoop()
        }
    }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fireOnce()
                try? await Task.sleep(nanoseconds: Self.sleepSeconds * 1_000_000_000)
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    private func fireOnce() async {
        let proc = Process()
        proc.launchPath = "/usr/bin/shortcuts"
        proc.arguments = ["run", Self.shortcutName]
        try? proc.run()
        proc.waitUntilExit()
    }
}
