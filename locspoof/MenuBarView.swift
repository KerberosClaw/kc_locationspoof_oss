import SwiftUI
import AppKit
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var status: StatusModel
    @ObservedObject var helper: HelperService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Show runningView only when SMAppService thinks daemon is enabled
            // AND we can actually reach it. The "enabled but unreachable" case
            // typically means BTM has a stale signature pin from a previous
            // build, so falling through to setupView lets the user re-register.
            if helper.status == .enabled && status.reachable {
                runningView
            } else {
                setupView
            }
            Divider()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("結束", systemImage: "power")
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { helper.refresh() }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRows
            Divider()
            actions
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.iconSystemName)
                .font(.title2)
                .foregroundStyle(status.iconColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline).font(.headline)
                if let coord = status.coordinateText {
                    Text(coord)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let hint = status.troubleshootHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(label: "iPhone", value: status.snapshot.dvtAlive ? "已連線" : "—")
            row(label: "通道", value: status.snapshot.tunnel ?? "—")
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                MapWindowController.shared.show(status: status)
            } label: {
                Label("開啟地圖…", systemImage: "map")
            }
            .keyboardShortcut("o")
            .buttonStyle(.borderless)

            Button {
                Task { await status.stopSpoof() }
            } label: {
                Label("停止注入", systemImage: "stop.circle")
            }
            .keyboardShortcut(".")
            .buttonStyle(.borderless)
            .disabled(!status.isSpoofing)
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: setupIcon)
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(helper.statusText).font(.headline)
                    Text(setupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Divider()
            setupButton
            if let err = helper.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var setupIcon: String {
        switch helper.status {
        case .notRegistered: return "arrow.down.circle"
        case .requiresApproval: return "exclamationmark.triangle"
        case .notFound: return "xmark.octagon"
        case .enabled: return "arrow.triangle.2.circlepath"  // registered but unreachable
        default: return "questionmark.circle"
        }
    }

    private var setupHint: String {
        if !isInApplications {
            return "App 必須放在 /Applications/ 下才能註冊 Helper daemon。" +
                   "目前位置：\(Bundle.main.bundleURL.deletingLastPathComponent().path)"
        }
        switch helper.status {
        case .notRegistered, .notFound:
            return "首次需安裝 Helper daemon，macOS 會要求管理員密碼。"
        case .requiresApproval:
            return "前往 系統設定 → 登入項目，允許 locspoof helper。"
        case .enabled:
            // We're in setupView with .enabled because daemon is unreachable.
            // BTM stores the daemon's code-signature digest at register() time;
            // every adhoc rebuild changes that digest, so launchd refuses to
            // spawn the new binary (EX_CONFIG 78). Calling register() again
            // refreshes BTM with the current signature.
            return "Helper 已註冊但無法連線。可能是 build 後簽名變更，BTM 還記著舊簽名。重新註冊一次即可。"
        default:
            return ""
        }
    }

    private var isInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    @ViewBuilder
    private var setupButton: some View {
        if !isInApplications {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            } label: {
                Label("在 Finder 顯示", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        } else {
            switch helper.status {
            case .notRegistered, .notFound:
                Button {
                    helper.install()
                } label: {
                    Label("安裝 Helper", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            case .requiresApproval:
                Button {
                    helper.openSystemSettings()
                } label: {
                    Label("前往系統設定", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
            case .enabled:
                // 已註冊但無法連線 → BTM 卡舊簽名、跑 unregister + register cycle
                Button {
                    helper.reinstall()
                } label: {
                    Label("重新註冊 Helper", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
        }
    }
}
