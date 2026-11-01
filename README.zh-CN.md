# Apple MCP

[English](README.md) | **简体中文**

三个 Mac App，让 AI agent（Claude Code、Codex、Grok Build、OpenCode、Gemini CLI、pi 等）经 MCP 服务器或命令行，以原生方式读写苹果自带的 App：

| App | 能操作什么 | 安装 | 文档 |
|---|---|---|---|
| **Apple Notes MCP** | 备忘录：保留原生格式，原地修改，经 iCloud 同步 | `brew install --cask xiaofeng-han/tap/apple-notes-mcp` | [English](docs/notes.md) · [简体中文](docs/notes.zh-CN.md) |
| **Apple Reminders MCP** | 提醒事项：「提醒事项」App 能做的都能做（标签、子任务、分区、智能清单等），走它自己的框架 | `brew install --cask xiaofeng-han/tap/apple-reminders-mcp` | [English](docs/reminders.md) · [简体中文](docs/reminders.zh-CN.md) |
| **Apple Journal MCP** | 手记：带格式的手记、手记本、最近删除、附件详情和分析，走「手记」自己的框架，由「手记」经 iCloud 同步 | `brew install --cask xiaofeng-han/tap/apple-journal-mcp`（从第一个发布版起） | [English](docs/journal.md) · [简体中文](docs/journal.zh-CN.md) |

每个 App 各自独立：名字、命令（`apple-notes-mcp`、`apple-reminders-mcp`、`apple-journal-mcp`）、服务器（`apple-notes`、`apple-reminders`、`apple-journal`）、工具、权限、设置窗口和版本号都是各自的，所以只装想要的那个，agent 也只看到它的工具。都需要 Apple 芯片：Notes 和 Reminders 需要 macOS 26 或更新，Apple Journal MCP 需要「手记」3.0（macOS 27.2）。各自的文档写了它能做什么、怎么安装、怎么配置 agent、需要哪些权限。

## 一个仓库，三个 App

本仓库原名 `apple-reminders-mcp`（旧链接会自动跳转到这里）。Apple Notes MCP 连同历史从 [apple-notes-mcp](https://github.com/xiaofeng-han/apple-notes-mcp) 搬了进来，两个 App 现在共用一套底座：MCP 服务器、命令行、设置窗口和 agent 配置只写一份。对用户没有变化：cask、命令、权限、设置和已配置的 agent 都和以前一样。

Apple Journal MCP 后来也加在同一套底座上。各 App 都从这里发版，每次发一个，tag 是 `notes-v<版本>`、`reminders-v<版本>` 或 `journal-v<版本>`。Apple Notes MCP 0.1.0 到 0.3.0 是在 [apple-notes-mcp](https://github.com/xiaofeng-han/apple-notes-mcp/releases)（已归档）发的，Apple Reminders MCP 0.3.0 及以前在这里以 `v<版本>` 发。各自的更新记录在 [CHANGELOG-notes.md](CHANGELOG-notes.md)、[CHANGELOG-reminders.md](CHANGELOG-reminders.md) 和 [CHANGELOG-journal.md](CHANGELOG-journal.md)。

## 目录

- `Sources/Wire`、`Launcher`、`Agents`、`AppCore`：共用底座。经 stdio 的 MCP 和工具开关；让 App 自己持有隐私权限；查找、安装和配置 AI 助手；以及每个 App 都在用的模式分发、命令行、技能和设置窗口。
- `Sources/NotesComponent`（加上 `NoteModel`、`NotesShim`）、`Sources/RemindersComponent`（加上 `ReminderKitShim`）和 `Sources/JournalComponent`（加上 `JournalModel`、`NoteModel`，以及 `Interfaces/Journal` 里手写的「手记」框架接口）：各 App 自己的代码，即数据和工具。`Sources/AppleNotesMCP`、`Sources/AppleRemindersMCP`、`Sources/AppleJournalMCP` 是各自的可执行文件，各只有一行。
- `Resources/Notes`、`Resources/Reminders`、`Resources/Journal`：各 App 的 Info.plist（版本号在这里）、entitlements、图标和安装包里的文字。
- `scripts/`：构建、打包、发版和检查，都带 `notes`、`reminders` 或 `journal` 参数。
- `docs/`：各 App 的文档、[前两个 App 搬到一起的方案](docs/MERGE-PLAN.md)，以及 [Notes](docs/RE-FINDINGS.md) 和 [Journal](docs/RE-FINDINGS-journal.md) 起步时的逆向笔记。

## 构建与测试

```bash
swift build                                  # 所有 App：.build/debug/AppleNotesMCP、AppleRemindersMCP、AppleJournalMCP
swift test                                   # 共用底座和各 App 的单元测试
./scripts/build-app.sh notes                 # 签好名的 dist/AppleNotesMCP.app（或 reminders、journal）
/usr/bin/python3 -I scripts/e2e.py notes     # 端到端检查，针对你真实的备忘录（或 reminders、journal）
scripts/release.sh --dry-run notes <版本>    # 演练发版：做到打包，然后撤销
```

每个 pull request 和每次推送到 `main`，都会在 GitHub 托管的 Mac 上构建所有 App，对照 `Tests/Golden` 检查用户和 agent 看到的东西（help、命令、技能、MCP 工具列表、agent 配置）没有变（`scripts/golden.py`），再跑单元测试。端到端检查要真实数据和 App 的权限，所以在发版前在 Mac 上跑。签名、打包、发版和测试覆盖范围的细节见各 App 的文档。
