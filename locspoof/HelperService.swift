import Foundation
import ServiceManagement
import SwiftUI
import Combine
import AppKit

@MainActor
final class HelperService: ObservableObject {
    static let plistName = "org.locspoof.app.helper.plist"

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private let service = SMAppService.daemon(plistName: plistName)

    init() {
        refresh()
    }

    func refresh() {
        status = service.status
    }

    func install() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = "register failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func uninstall() {
        do {
            try service.unregister()
            lastError = nil
        } catch {
            lastError = "unregister failed: \(error.localizedDescription)"
        }
        refresh()
    }

    /// BTM stale-signature recovery — unregister + register cycle。對應
    /// locspoofApp.swift 中 `--reinstall` 旗標的同樣邏輯。
    /// 用於 `.enabled but unreachable` 狀態（clean build / install 後常見）。
    func reinstall() {
        try? service.unregister()
        Thread.sleep(forTimeInterval: 0.3)
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = "重新註冊失敗：\(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusText: String {
        switch status {
        case .notRegistered: return "尚未安裝"
        case .enabled: return "已啟用"
        case .requiresApproval: return "需要授權"
        case .notFound: return "找不到 Bundle"
        @unknown default: return "狀態未知"
        }
    }

    var isEnabled: Bool { status == .enabled }
}
