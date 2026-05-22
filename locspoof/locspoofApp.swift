import SwiftUI
import AppKit
import ServiceManagement

@main
struct locspoofApp: App {
    @StateObject private var status = StatusModel()
    @StateObject private var helper = HelperService()

    init() {
        // install.sh passes --reinstall after replacing the .app bundle.
        // Cycle BTM: unregister clears the stale code-signature pin from the
        // old build, register re-pins against the current binary. Without
        // this, kickstart-style updates trip EX_CONFIG (78) and launchd never
        // spawns the new helper.
        if CommandLine.arguments.contains("--reinstall") {
            let svc = SMAppService.daemon(plistName: HelperService.plistName)
            try? svc.unregister()
            Thread.sleep(forTimeInterval: 0.3)
            try? svc.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(status: status, helper: helper)
        } label: {
            Image(systemName: status.iconSystemName)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MapWindowController {
    static let shared = MapWindowController()

    private var window: NSWindow?

    func show(status: StatusModel) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }
        let host = NSHostingController(
            rootView: ContentView().environmentObject(status)
        )
        let w = NSWindow(contentViewController: host)
        w.title = "位置注入器"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false

        // 首次啟動預設 frame：top-left (132, 116)、1270×803。
        // NSWindow 用 bottom-left 座標、從 System Events top-left 換算。
        // setFrameAutosaveName 之後跑會自動還原 user 拉動過的位置。
        w.setContentSize(NSSize(width: 1270, height: 803))
        if let screen = NSScreen.main {
            let topLeftY: CGFloat = 116
            let yBottomLeft = screen.frame.height - topLeftY - 803
            w.setFrameOrigin(NSPoint(x: 132, y: yBottomLeft))
        }
        w.setFrameAutosaveName("locspoofMainWindow")

        w.makeKeyAndOrderFront(nil)
        activateApp()
        self.window = w
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
