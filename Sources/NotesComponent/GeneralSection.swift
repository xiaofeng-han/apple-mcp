import AppCore
import AppKit
import Combine
import SwiftUI

/// The two permissions, for the settings window's General tab, looked at again every second.
@MainActor
final class NotesPermissionsState: ObservableObject {
    @Published private(set) var fullDisk = Permissions.fullDiskAccess
    @Published private(set) var automation = Permissions.automation(ask: false)
    @Published private(set) var asking = false
    private var poll: AnyCancellable?

    init() {
        // Permissions change in System Settings, outside this app; look again every second.
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.asking else { return }
                self.fullDisk = Permissions.fullDiskAccess
                let automation = Permissions.automation(ask: false)
                // Without Notes running the answer is "unknown"; keep what was known.
                if automation != .unknown || self.automation == .notAsked { self.automation = automation }
            }
        }
    }

    /// Starts Notes hidden (Automation can only be asked for while it runs), then asks; macOS
    /// shows its prompt if the user has not decided yet.
    func askForAutomation() {
        asking = true
        Permissions.startNotesHidden()
        Task {
            var state = Permissions.State.unknown
            for _ in 0..<20 where state == .unknown {
                state = await Task.detached { Permissions.automation(ask: true) }.value
                if state == .unknown { try? await Task.sleep(for: .milliseconds(250)) }
            }
            automation = state
            asking = false
        }
    }
}

/// The General tab's permissions: Full Disk Access and Automation → Notes.
struct NotesGeneralSection: View {
    @ObservedObject var panel: PanelState
    @StateObject private var state = NotesPermissionsState()

    var body: some View {
        let allowed = Label(panel.text("Allowed", "已允许"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        Section {
            LabeledContent(panel.text("Full Disk Access", "完全磁盘访问")) {
                if state.fullDisk {
                    allowed
                } else {
                    HStack {
                        Button(panel.text("Show in Finder", "在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        Button(panel.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(Permissions.fullDiskSettings) }
                    }
                }
            }
            LabeledContent(panel.text("Automation → Notes", "自动化 → 备忘录")) {
                switch state.automation {
                case .granted: allowed
                case .denied:
                    Button(panel.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(Permissions.automationSettings) }
                case .notAsked, .unknown:
                    if state.asking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(panel.text("Allow…", "允许…")) { state.askForAutomation() }
                    }
                }
            }
        } header: {
            Text(panel.text("Permissions", "权限"))
        } footer: {
            Text(panel.text(
                "Full Disk Access lets the app read your notes; add Apple Notes MCP to the list in System Settings (Show in Finder, then drag it in, or click +). Automation lets it ask Notes to upload changes to iCloud and to move and delete notes and folders. The permissions belong to this app and are shared by every AI assistant.",
                "完全磁盘访问用来读取备忘录：在系统设置的列表里加入 Apple Notes MCP（先「在访达中显示」再拖进去，或点 +）。自动化用来让「备忘录」把改动上传到 iCloud，以及移动、删除笔记和文件夹。权限记在这个 App 名下，所有 AI 助手共用。"))
                .foregroundStyle(.secondary)
        }
    }
}
