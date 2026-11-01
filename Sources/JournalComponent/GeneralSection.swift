import AppCore
import AppKit
import Combine
import SwiftUI

/// The permission, for the settings window's General tab, looked at again every second.
@MainActor
final class JournalAccessState: ObservableObject {
    @Published private(set) var fullDisk = Permissions.fullDiskAccess
    private var poll: AnyCancellable?

    init() {
        // Permissions change in System Settings, outside this app; look again every second.
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.fullDisk = Permissions.fullDiskAccess }
        }
    }
}

/// The General tab's permission (Full Disk Access) and whether this Mac's Journal is the one the
/// app was made for.
struct JournalGeneralSection: View {
    @ObservedObject var panel: PanelState
    @StateObject private var state = JournalAccessState()

    var body: some View {
        let allowed = Label(panel.text("Allowed", "已允许"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        Section {
            LabeledContent(panel.text("Full Disk Access", "完全磁盘访问")) {
                if state.fullDisk {
                    allowed
                } else if !Permissions.hasData {
                    Text(panel.text("Open Journal once first", "请先打开一次「手记」")).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(panel.text("Show in Finder", "在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        Button(panel.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(Permissions.fullDiskSettings) }
                    }
                }
            }
            LabeledContent(panel.text("Journal", "手记")) {
                if Compatibility.missing.isEmpty {
                    Label(Permissions.journalVersion.map { panel.text("Version \($0), supported", "版本 \($0)，支持") } ?? panel.text("Supported", "支持"),
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label(panel.text("Not supported: update Apple Journal MCP", "不支持：请更新 Apple Journal MCP"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(panel.text("Permissions", "权限"))
        } footer: {
            Text(panel.text(
                "Full Disk Access lets the app read and write your journal, through Journal's own data model; Journal then uploads the changes to iCloud. Add Apple Journal MCP to the list in System Settings (Show in Finder, then drag it in, or click +). The permission belongs to this app and is shared by every AI assistant.",
                "完全磁盘访问用来读写手记（经由「手记」自己的数据模型），之后由「手记」把改动上传到 iCloud。在系统设置的列表里加入 Apple Journal MCP（先「在访达中显示」再拖进去，或点 +）。权限记在这个 App 名下，所有 AI 助手共用。"))
                .foregroundStyle(.secondary)
        }
    }
}
