# Apple MCP：把 Apple Notes MCP 与 Apple Reminders MCP 合并为一个 App

调查与方案，2026-10-21。基于 `apple-notes-mcp` main（`198dc7b`：0.1.0 之后合入 PR #1，补上了命令行、技能和工具标签页）与 `apple-reminders-mcp` main（`1f4a0f8`：0.2.4 之后的同样三项），以及 `homebrew-tap` 当时的两个 cask。两边的这三项都还没发版。

> 更新（2026-10-21 晚）：初稿基于 Notes 0.1.0（`36b01b5`）。Notes 合入 PR #1 后重新扫描了两个仓库，改了 1.1–1.3、2.1–2.5、3.1、3.3、5、6、8–10 节：Notes 现在也有命令行、技能和工具开关，共享代码除产品字串外已逐字相同，原先「Notes 暂不提供命令行与技能」的安排作废。

## 结论

可以合并，而且现在是代价最低的时候：两个仓库是同一骨架的两份拷贝，共享部分（`Wire`、`Launcher`、`Agents`，约 3,200 行）除产品字串外逐字相同，设置窗口与命令行的机制也已对齐；两个项目都在今天刚发版，命令行等新功能都还没发出去，受影响的用户最少。再拖下去，两边会再次分叉：Reminders 今天加的三项功能，Notes 要专门补一轮才跟上。

方案一句话：**一个仓库、一个 Swift package、一个 App（`AppleMCP.app`，bundle id `com.xiaofeng.apple-mcp`）、一个设置窗口，但 agent 里注册的仍是按组件分开的 MCP 服务器**——`apple-notes` 只给备忘录的工具，`apple-reminders` 只给提醒事项的工具。权限授给这一个 App，所有组件共用。每个组件是一个独立 target，实现一个 `Component` 协议；以后加 Calendar、Contacts 就是再加一个 target、在注册表里加一行。

已定决策：

| 事项 | 决定 |
|---|---|
| 身份 | 新 bundle id `com.xiaofeng.apple-mcp`，产品名 Apple MCP，App `AppleMCP.app`，命令 `apple-mcp`，cask `apple-mcp` |
| 仓库 | GitHub 上把 `apple-reminders-mcp` 改名为 `apple-mcp`（旧地址自动重定向，stars/issues/releases 保留），把 `apple-notes-mcp` 的历史并进去；`apple-notes-mcp` 归档，README 指向新仓库 |
| 服务器 | 仍按组件分开注册：`apple-notes`、`apple-reminders`（以后 `apple-calendar`、`apple-contacts`）；合并成一个服务器只作为以后的可选项 |
| 命令名 | 旧命令 `apple-notes-mcp`、`apple-reminders-mcp` 在 Homebrew 里保留为包装脚本，现有 agent 配置一字不改继续有效 |

## 1. 现状调查

### 1.1 两个仓库的异同

| 目录 | Notes | Reminders | 关系 |
|---|---|---|---|
| `Sources/Wire` | `JSON`、`Schema`、`Service`、`Exposure`（工具开关）、`FileWatch`、`Flags`（命令行参数解析） | 同 | `JSON`、`Schema`、`FileWatch`、`Flags` 字节相同；`Exposure` 只差注释里的示例工具名；`Service` 只差 Notes 多出的 `Content.audio`、`.file` 两个 case、日志变量名、stderr 前缀和一行注释 |
| `Sources/Launcher` | `launcher_become_responsible`、`launcher_spawn_disclaimed`、`launcher_is_sandboxed` | 同 | `.c` 字节相同；`.h` 只差注释里的权限名 |
| `Sources/Agents` | 13 个文件（含 `Skills.swift`） | 同 | `ConfigValue`、`Installer`、`JSONText`、`Presence`、`RunningApp`、`TOMLText` 字节相同；`Agent`、`ConfigFile`、`Installation`、`Registration`、`Shell`、`Skills` 只差产品字串（每个 4–14 行） |
| `App/` | `SettingsPanel`、`AgentsPanel`（含技能模式）、`AgentsCommand`、`ToolsPanel`；三个标签页 | 同 | `AgentsPanel`、`AgentsCommand` 只差产品字串（14 行）；`ToolsPanel` 只差中文工具名和一句文案；`SettingsPanel` 的「通用」页按各自的权限与设置不同（Notes：完全磁盘访问 + 自动化→备忘录；Reminders：提醒事项 + 可选的完全磁盘访问 + 重复提醒开关） |
| `CLI/` | `Commands.swift`（名词/动词命令树）、`Skill.swift`（生成 SKILL.md） | 同 | 机制相同，路由表和技能正文不同。两边的 `Route` 各有对方没有的东西，见 2.2 末尾 |
| 产品本体 | `NotesShim`（ObjC 500 行）、`NoteModel`（~1,200）、`Store/`（~2,000）、`Tools/`（~900） | `ReminderKitShim`（ObjC 1,300）、`Store/`（~1,200）、`Tools/`（~700）、`SmartFilter` | 完全不同，互不依赖 |
| 测试 | `AgentsTests`（+ `SkillTests`）、`WireTests`、`NoteModelTests` | `AgentsTests`（+ `SkillTests`）、`WireTests` | `AgentsTests`、`WireTests` 只差产品字串 |
| 脚本/资源 | `build-app.sh`、`build-pkg.sh`、`update-cask.sh`、`e2e.py`（93 项：经 stdio 的工具、命令行 20 项、工具开关与通知 24 项）、图标脚本、Info.plist、entitlements、InfoPlist.strings、conclusion.html | 同（`e2e.py` 167 项） | 只差产品字串和权限文案；两个 `e2e.py` 的工具开关、通知和无状态协议部分几乎逐行相同 |

Notes 有 5 个提交（0.1.0 一个 squash 提交，加 PR #1 的三个提交和合并提交），Reminders 22 个；两边的历史互不相干，合并没有包袱（见附录）。

两边的 `main.swift` 都有进程级全局变量（`version`、`words`、`writeGuard`、`store`、`tools`），被 `CLI/Commands.swift`、`CLI/Skill.swift`、`App/AgentsCommand.swift` 直接读取；合并时它们要变成参数。Notes 因为 `NotesStore` 是 `@MainActor`，在顶层用 `MainActor.assumeIsolated` 构造 `store` 和 `tools`。

两个组件的工具名不冲突：Notes 10 个（`overview`、`search`、`read_note`、`read_attachment`、`describe_note`、`create_note`、`edit_note`、`move_note`、`delete_note`、`manage_folder`），Reminders 16 个（`find_reminders`、`get_reminder`、`list_lists`、`list_tags`、`list_deleted`、`create_reminder`、`update_reminder`、`delete_reminder`、`restore_reminder`、`manage_list`、`manage_group`、`manage_section`、`manage_smart_list`、`manage_tag`、`manage_template`、`read_image`）。

### 1.2 产品身份写死在哪里

合并要把这些地方全部参数化（行号以 Reminders 仓库为准，Notes 对应位置相同或相近）：

| 类别 | 位置 |
|---|---|
| bundle id、pkg id、cask 名、App 路径 | `Sources/Agents/Installation.swift:14-16`（三个常量）、`:45`、`:53`（`/Applications/X.app`、`~/Applications/X.app`）；`main.swift` 的 bundle id 门控（`launcher_become_responsible` 只在 App bundle 里调用）；`Resources/Info.plist`；`scripts/build-app.sh:14`、`build-pkg.sh:22`、`update-cask.sh:13-18`；`e2e.py` |
| 服务器名 `apple-notes` / `apple-reminders` | `Sources/Agents/Registration.swift:20`（`Registration.serverName`，其余 10 余处引用它）；`Agent.swift:104`；`AgentsPanel` 页脚文案 |
| `serverInfo.name` | `main.swift`：`Service(name: "apple-reminders-mcp", …)`；`e2e.py` 检查它 |
| 备份后缀 `.bak-<日期>-apple-*-mcp` | `Sources/Agents/ConfigFile.swift:63` |
| 登录环境探测标记、`*_RELAUNCHED` 剔除 | `Sources/Agents/Shell.swift:51`、`:95` |
| 技能名与 marker | `Sources/Agents/Skills.swift:21`（`apple-reminders/SKILL.md`；Notes 是 `apple-notes/SKILL.md`）、`:23`（`generated-by: apple-reminders-mcp`；Notes 是 `generated-by: apple-notes-mcp`） |
| 环境变量 | `APPLE_NOTES_MCP_{RELAUNCHED,WIRE_LOG,WRITE_GUARD,TOOLS_FILE}`、`APPLE_REMINDERS_MCP_{RELAUNCHED,WIRE_LOG,WRITE_GUARD,TOOLS_FILE}` |
| 支持目录 | `Store/Settings.swift`：`~/Library/Application Support/AppleNotesMCP/{backups/,descriptions.json,tools.json}`、`…/AppleRemindersMCP/{tools.json,deleted.json}`；两边的 `Settings.exposure` 和 `toolsFileOverride` 写法相同 |
| defaults 域与键 | `UserDefaults.standard`（随 bundle id）：`InterfaceLanguage`（两边）、`AllowCompletingRecurringReminders`（Reminders） |
| 命令名 | `CLI/Commands.swift`（`program`；临时文件前缀 `apple-reminders-` / `apple-notes-`）；`CLI/Skill.swift` 文案；`AgentsCommand` usage；`Wire/Service.swift` stderr 前缀 |
| 显示名与权限文案 | `SettingsPanel`（窗口标题、菜单）、`AgentsPanel` 段头与技能说明、`ToolsPanel`（「AI 助手就完全用不了备忘录 / 提醒事项」）、`Store/System.swift`（Notes 的 `fullDiskHelp`/`automationHelp`/`sandboxHelp`）、`RemindersStore.swift:25-34`（`permissionHelp`/`sandboxHelp`）、`Tools/Output.swift`、`Info.plist` 的 usage string、`InfoPlist.strings`、`conclusion.html` |

`Sources/Agents` 里只有 `Installation`、`Registration`、`ConfigFile`、`Shell`、`Skills`、`Agent`（grok-bot 的说明文字）六处带产品身份，其余都是中性的。`Launcher` 不带产品名（marker 是参数）。`Wire` 只在 `Service` 的日志变量名和 stderr 前缀里带。

### 1.3 现有用户手里有什么

| 安装方式 | agent 配置里的命令 | 其他 |
|---|---|---|
| Homebrew | `/opt/homebrew/bin/apple-notes-mcp --stdio`、`/opt/homebrew/bin/apple-reminders-mcp --stdio`（`command_wrapper` 生成的脚本，`exec` App 可执行文件） | cask 名、Caskroom 目录、pkg 收据 `com.xiaofeng.apple-*-mcp.pkg` |
| pkg | `~/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP --stdio`（或 `/Applications/…`） | pkg 收据 |
| 两者 | 服务器名 `apple-notes`、`apple-reminders`；TCC 授权记在 bundle id + 签名要求上（Notes：完全磁盘访问 + 自动化→备忘录；Reminders：提醒事项，完全磁盘访问可选）；支持目录与 defaults（见 1.2） | |

命令行、技能和工具开关在两边都还没发版：装着 0.1.0 / 0.2.4 的用户没有 `apple-notes/SKILL.md`、`apple-reminders/SKILL.md` 或 `tools.json`。从 main 自己构建的人（目前是作者本机）可能都有，技能 frontmatter 的 `command:` 指向旧可执行文件。若合并版之前不再单独发版（见第 10 节），迁移这些只是为了这些人，但代码一样要写。

### 1.4 已查证的外部事实

- **Homebrew `command_wrapper`** 支持 `args:`，生成的脚本是 `exec "<executable>" <args> "$@"`（`Pathname#write_env_script`）：固定参数在前，调用时的参数透传在后。今天的 `apple-notes-mcp --stdio` 能工作就是靠这个透传。
- **Homebrew cask 改名**：tap 根目录放 `cask_renames.json`（`{"旧 token": "新 token"}`，新 token 必须在同一 tap）。`Cask::Migrator` 在 `brew upgrade`、`reinstall`、`brew migrate --cask` 时运行；对一个新 cask 的多个旧 token逐个迁移；新 cask 尚未以自己的目录安装时，把旧 Caskroom 目录复制成新目录并把旧目录换成符号链接；新 cask 已装时，把多余的旧 cask 卸载并留符号链接。所以两个旧 cask 都装着的用户也能迁到一个新 cask。
- **GitHub 仓库改名**：git、网页和 API 地址自动重定向到新名（GitHub Actions 的 `uses:` 和 Pages 除外），只要不再用旧名新建仓库；release 下载链接在网页路径下，预期一同重定向——发布前用旧地址实际下载一次验证。
- **macOS 隐私权限**（TCC）按 bundle id + 代码签名的 designated requirement 记录。换 bundle id 后旧授权不继承，必须重授一次；两个 App 的签名证书相同（`Xiaofeng Local Code Signing`）不改变这一点。

## 2. 目标架构

### 2.1 Package 与 target

```
Wire ──────────────┐
Launcher ─► Agents ┼─► AppCore ─► NotesComponent ────┐
                   │             └► RemindersComponent ┼─► Registry ─► AppleMCP（可执行文件）
NoteModel, NotesShim ─► NotesComponent               │
ReminderKitShim ─► RemindersComponent ───────────────┘

测试：AgentsTests(Agents)  WireTests(Wire)  NoteModelTests(NoteModel)  AppCoreTests(AppCore)  RegistryTests(Registry)
```

- `Agents` 不依赖 `AppCore`，继续可以单独测试；它只增加几个小的值类型（`Product`、`ComponentSpec`、`ServerSpec`、`SkillSpec`），由 `AppCore` 填值。
- `AppCore` 放所有与具体组件无关的东西：`Component` 协议、`Permission`（权限探测与申请只实现一次）、`Product` 常量、`Settings`（新 defaults 域 + 旧域回退）、`Env`（新旧环境变量名）、`Migration`（首次运行迁移）、`SettingsWindow.openOnce()`（Notes 现有的「缺权限时打开设置窗口一次」搬进来，Reminders 也获得）、通用命令行机制（`Route`/`Commands`/`Skill`，取两边的并集，见 2.2 末尾；路由数据留在组件里）、`Invocation.parse`（命令行分发，纯函数）。
- 每个组件是独立 module，两边同名的内部类型（`Input`、`Output`、`Settings`、`readTools`、`writeTools`、`withStore`/`withNotes`、`StoreError`/`NotesError`）互不干扰；每个组件只导出一个 `Component` 值。
- `Registry` 是一个文件一个 target：`Component.all`。可执行文件和 `RegistryTests` 看到同一份列表。**加一个组件 = 新 target + `Package.swift` 一行 + `Registry.swift` 一行。**

### 2.2 `Component` 协议

```swift
public typealias LocalizedText = (english: String, chinese: String)

/// 组件的三个名字。定义在 Agents 里（Agents 需要它写配置），AppCore 再导出。
public struct ComponentSpec: Sendable, Hashable {
    public let id: String          // "notes"：命令行里的词、支持子目录名、环境变量中缀（大写）
    public let serverName: String  // "apple-notes"：agent 里注册的服务器名；技能文件夹名
    public let commandName: String // "apple-notes-mcp"：Homebrew 包装命令；serverInfo.name；技能 marker
}

/// 合并前的身份，用于迁移。
public struct LegacyIdentity: Sendable {
    public let productName: String        // "Apple Notes MCP"
    public let bundleID: String           // "com.xiaofeng.apple-notes-mcp"（旧 defaults 域）
    public let appName: String            // "AppleNotesMCP"（旧 App 名、旧支持目录名）
    public let environmentPrefix: String  // "APPLE_NOTES_MCP"
}

public enum Permission: Hashable, Sendable {
    case fullDiskAccess
    case automation(bundleID: String, appName: LocalizedText)   // 按 bundleID 判等
    case reminders        // EKEntityType.reminder
    case calendars        // EKEntityType.event
    case contacts
}
public struct PermissionNeed: Sendable { public let permission: Permission; public let required: Bool }
public enum PermissionState: Equatable { case granted, denied, notAsked, unknown }

/// 组件自己的一个布尔设置，由「通用」标签页统一渲染。
public struct ComponentSetting: Sendable {
    public let key: String          // UserDefaults 键，如 "AllowCompletingRecurringReminders"
    public let defaultValue: Bool
    public let title: LocalizedText
    public let footer: LocalizedText
}

/// main 交给组件的东西。
public struct ComponentContext: Sendable {
    public let supportDirectory: URL   // ~/Library/Application Support/AppleMCP/<id>
    public let writeGuard: String?     // APPLE_MCP_<ID>_WRITE_GUARD 的原文（或旧名），由组件自己解析
    public let exposure: ToolExposure  // <supportDirectory>/tools.json（或 APPLE_MCP_<ID>_TOOLS_FILE）
    public let version: String
}

public protocol Component: Sendable {
    var spec: ComponentSpec { get }
    var displayName: LocalizedText { get }
    var legacy: LegacyIdentity? { get }                   // 新组件为 nil
    var permissions: [PermissionNeed] { get }
    var instructions: String { get }                       // MCP initialize 的 instructions
    var chineseToolTitles: [String: String] { get }        // 工具标签页
    var settings: [ComponentSetting] { get }               // 没有则 []
    var routes: [Route] { get }                            // 没有命令行则 []
    var defaultVerbs: [String: String] { get }
    var rewordings: [(String, String)] { get }             // 工具文案 → 命令行参数名的改写
    /// 技能正文（frontmatter 的 description + 规则）；nil 表示没有技能。
    func skillText(run: String, reference: String) -> String?
    /// 同一组 Tool 既给 MCP 也给命令行。主 actor：Notes 的 store 绑定主线程。
    @MainActor func makeTools(_ context: ComponentContext) -> [Tool]
    /// `setup`：在终端里申请/引导本组件的权限，返回退出码。
    @MainActor func setup(_ context: ComponentContext) async -> Int32
    /// `--self-check` 在产品标题后打印的行。
    @MainActor func selfCheck(_ context: ComponentContext) async -> [String]
}
extension Component {  // 默认：settings = [], routes = [], defaultVerbs = [:], rewordings = [], skillText = nil, legacy = nil
    public var hasSkill: Bool { !routes.isEmpty && skillText(run: "", reference: "") != nil }
}
```

权限的探测与申请在 `AppCore/Permission.swift` 实现一次，组件只声明需要什么：

- `.fullDiskAccess`：读一个受 FDA 保护、总是存在的文件的开头（候选 `~/Library/Application Support/com.apple.TCC/TCC.db`；或沿用 Notes 现在读 `NoteStore.sqlite` 的做法，待定）；申请 = 打开 `Privacy_AllFiles` 并在访达里选中 App（Notes `main.swift` 现有逻辑）。
- `.automation(bundleID:)`：Notes 的 `Permissions.automation(ask:)` + `startNotesHidden()` 推广到任意 bundle id（`Store/System.swift:42-64`），含 20 × 250 ms 的重试。
- `.reminders` / `.calendars`：`EKEventStore.authorizationStatus(for:)` + `requestFullAccessToReminders()` / `requestFullAccessToEvents()`；`.contacts`：`CNContactStore`。
- 每个权限带 `name`（中英）、`settingsURL`（现有的 `x-apple.systempreferences:` 地址）、`help(product:)` 文案（Notes 的 `fullDiskHelp`/`automationHelp`、Reminders 的 `permissionHelp`，产品名换成 Apple MCP）。
- 沙盒：两边都用 `launcher_is_sandboxed()` 把缺权限改报成「到沙盒外再跑一次」（Notes 在 `Tools/Output.swift` 的 `explain`，Reminders 在 `RemindersStore.ensureAccess`）。合并后放在 `Permission` 的检查里一处，文案取 Apple MCP 的通用版本。

`AppCore/CLI` 的通用机制取两边现有代码的并集，两边的路由表原样搬进各自组件：

| 项目 | Notes 有 | Reminders 有 | 合并后 |
|---|---|---|---|
| `Route` 字段 | `stdin`（值为 `-` 的字段从标准输入读，给多行 Markdown）、`fallback`（一个筛选都没给时补字段：`notes list` 默认按修改时间列笔记） | `clears`（创建时不给 `--no-` 清空）、描述里「 for create; 」的拆分 | 全部保留，都是可选字段，默认值让另一边的行为不变 |
| 回答里的非文本内容 | 图片、音频、文件都存到 `--output-dir`（默认临时目录），每个打印一行 `Saved to` | `read_image` 把一张图片存到 `--output` 指定的文件 | 由 route 声明保存方式（文件或文件夹），`execute` 一处实现 |
| 错误文案改写 | 名字带 `_` 且只对应一条 route 的工具名换成命令，外加几条固定替换（`allow_shared: true` → `--allow-shared` 等） | `fixed` 为空的 route 的工具名换成命令（默认动词换成名词），外加两条固定替换 | 规则合一：名字带 `_`、只对应一条 `fixed` 为空的 route 的工具名换成命令（是默认动词时换成名词）；两边的固定替换留在各自组件的 `rewordings` |
| 技能的命令参考 | 列出每条命令的可选参数 | 另外让 `update` 只列 `create` 没有的参数，并列出可清空的字段 | 保留 Reminders 的逻辑，对没有 `update` 的组件不起作用 |

### 2.3 两个组件怎么实现，以后的组件怎么加

`NotesComponent`：

```swift
public struct NotesComponent: Component {
    public let spec = ComponentSpec(id: "notes", serverName: "apple-notes", commandName: "apple-notes-mcp")
    public let displayName: LocalizedText = ("Notes", "备忘录")
    public let legacy = LegacyIdentity(productName: "Apple Notes MCP", bundleID: "com.xiaofeng.apple-notes-mcp",
                                       appName: "AppleNotesMCP", environmentPrefix: "APPLE_NOTES_MCP")
    public let permissions = [PermissionNeed(permission: .fullDiskAccess, required: true),
                              PermissionNeed(permission: .automation(bundleID: "com.apple.Notes", appName: ("Notes", "备忘录")), required: true)]
    public let instructions = "…"            // 原 main.swift 的文字
    public let chineseToolTitles = [/* 10 条，取自现有 ToolsPanel */]
    public let routes = notesRoutes          // 取自现有 CLI/Commands.swift
    public let defaultVerbs = ["notes": "list", "folders": "list"]
    @MainActor public func makeTools(_ c: ComponentContext) -> [Tool] {
        let store = NotesStore(writeGuard: c.writeGuard.flatMap { $0.isEmpty ? nil : $0 }, supportDirectory: c.supportDirectory)
        let descriptions = Descriptions(file: c.supportDirectory.appendingPathComponent("descriptions.json"))
        return readTools(store, descriptions) + attachmentTools(store) + writeTools(store)
    }
    @MainActor public func setup(_ c: ComponentContext) async -> Int32 { /* 原 main.swift 的 setup，改用 Permission.* */ }
    @MainActor public func selfCheck(_ c: ComponentContext) async -> [String] { /* 原 --self-check 的几行 */ }
}
```

Store 的改动：`NotesStore.init(writeGuard:supportDirectory:)`，`Writing.swift` 的 `backups/<id>/` 用注入的目录；`Descriptions(file:)` 本来就接收 URL。`routes`、`rewordings` 取自现有 `CLI/Commands.swift`，`skillText` 取自 `CLI/Skill.swift`（Markdown 写法、先读后改、`--allow-shared` 等规则），和 Reminders 对称。

`RemindersComponent`：`spec = ("reminders", "apple-reminders", "apple-reminders-mcp")`，`legacy = ("Apple Reminders MCP", "com.xiaofeng.apple-reminders-mcp", "AppleRemindersMCP", "APPLE_REMINDERS_MCP")`，`permissions = [.reminders 必需, .fullDiskAccess 可选]`，`settings = [AllowCompletingRecurringReminders]`（文案取自现有 `SettingsPanel`），`routes`/`defaultVerbs`/`rewordings` 取自现有 `Commands.swift`，`skillText` 取自现有 `Skill.swift`，`chineseToolTitles` 取自现有 `ToolsPanel`。`makeTools` 里 `RemindersStore(writeGuard: 解析后的集合, deletionLog: DeletionLog(url: c.supportDirectory/deleted.json))`；`RemindersStore.swift:267` 读设置改为 `AppCore.Settings.bool("AllowCompletingRecurringReminders", default: true)`。`selfCheck` 保留现有的沙盒、可选 FDA、重复提醒设置、工具开放数几行。

以后加 **Calendar**：`spec = ("calendar", "apple-calendar", "apple-calendar-mcp")`，`legacy = nil`，`permissions = [.calendars 必需]`，自己的 `CalendarStore` 和工具（`find_events`、`create_event`…，名字与现有工具不重），routes `events list/create/update/delete`，技能文案，中文标题。需要动的地方：新 target + `Package.swift` 一行；`Registry.swift` 一行；cask 多一个 `command_wrapper "apple-calendar-mcp", …, args: ["calendar"]`；`scripts/e2e/calendar.py`；`docs/calendar.md`。Info.plist 的 `NSCalendarsFullAccessUsageDescription` 和 entitlement `com.apple.security.personal-information.calendars` 提前放好。`Agents`、`Wire`、`AppCore`、`main.swift`、三个面板都不用改。**Contacts** 同理，另加 `NSContactsUsageDescription` 与 entitlement `com.apple.security.personal-information.addressbook`。

### 2.4 主线程模型

保留 Notes 的 `runThenExit`（`RunLoop.main` 版），弃用 Reminders 的 `dispatchMain()`：Notes 的 Core Data context 是主队列 context，`dispatchMain()` 会让主线程退出、主队列由别的线程服务，保存时死锁（Notes `main.swift` 里的注释）。EventKit/ReminderKit 在 RunLoop 下预期没有问题（`requestFullAccessToReminders` 本来就需要跑着的 run loop），但要在真机上用 `e2e.py reminders` 确认（风险 R4）。

### 2.5 文件映射（`git mv`）

| 新位置 | 来自 |
|---|---|
| `Sources/Wire/{JSON,Schema,Service,Exposure,FileWatch,Flags}.swift` | Notes（它的 `Service.swift` 已含 `Content.audio`、`.file`，其余与 Reminders 相同） |
| `Sources/Launcher/*` | 任一边（只差注释），注释改成组件无关 |
| `Sources/Agents/*` | Reminders，然后按第 4 节参数化 |
| `Sources/NoteModel/*`、`Sources/NotesShim/*` | Notes |
| `Sources/ReminderKitShim/*` | Reminders |
| `Sources/NotesComponent/Store/*` | Notes `Sources/AppleNotesMCP/Store/*`，去掉 `Settings.swift`；`System.swift` 保留 `NotesError`、`AppleScript`、`waitFor` 和权限文案，权限探测移到 AppCore |
| `Sources/NotesComponent/Tools/*` | Notes `Sources/AppleNotesMCP/Tools/*`（`Output.explain` 里打开设置窗口的部分移到 AppCore） |
| `Sources/NotesComponent/Routes.swift` | Notes `CLI/Commands.swift` 里的 `routes`、`nouns`、`defaultVerbs`、`reword` 数据 |
| `Sources/NotesComponent/SkillText.swift` | Notes `CLI/Skill.swift` 的正文部分 |
| `Sources/NotesComponent/NotesComponent.swift` | 新写 |
| `Sources/RemindersComponent/{Store/*,Tools/*,SmartFilter.swift}` | Reminders `Sources/AppleRemindersMCP/…`，去掉 `Store/Settings.swift` |
| `Sources/RemindersComponent/Routes.swift` | Reminders `CLI/Commands.swift` 里的 `routes`、`nouns`、`defaultVerbs`、`reword` 数据 |
| `Sources/RemindersComponent/SkillText.swift` | Reminders `CLI/Skill.swift` 的正文部分 |
| `Sources/RemindersComponent/RemindersComponent.swift` | 新写 |
| `Sources/AppCore/CLI/{Route,Commands,Skill}.swift` | 两边 `CLI/*` 的通用机制，取并集（2.2 末尾） |
| `Sources/AppCore/{Component,Permission,Product,Settings,Env,Migration,SettingsWindow,Invocation}.swift` | 新写 |
| `Sources/Registry/Registry.swift` | 新写 |
| `Sources/AppleMCP/main.swift` | 由两个 `main.swift` 合成（`runThenExit` 取 Notes 版） |
| `Sources/AppleMCP/App/{SettingsPanel,AgentsPanel,ToolsPanel,AgentsCommand}.swift` | 两边只差产品字串，以 Reminders 为底，按第 5 节泛化 |
| `Tests/AgentsTests/*`、`Tests/WireTests/*` | 两边只差产品字串，取 Reminders |
| `Tests/NoteModelTests/*` | Notes |
| `Tests/AppCoreTests/*`、`Tests/RegistryTests/*` | 新写 |
| `Resources/Info.plist`、`Resources/AppleMCP.entitlements`、`Resources/{en,zh-Hans}.lproj/InfoPlist.strings`、`Resources/Installer/conclusion.html` | Reminders，按第 7 节改 |
| `Resources/AppIcon.icon`、`AppIcon-compiled` | 新图标 |
| `scripts/{build-app,build-pkg,update-cask,build-icon}.sh`、`flatten-icon.swift`、`compose-icon.swift` | Reminders（+ Notes 的 `compose-icon.swift`） |
| `scripts/e2e.py`、`scripts/e2e/{harness,notes,reminders}.py` | 两个 `e2e.py` 拆分（第 8 节） |
| `docs/notes.md`、`docs/reminders.md`（+ `.zh-CN`）、`docs/RE-FINDINGS.md` | 两个 README 的组件章节；Notes 的 `docs/RE-FINDINGS.md` |

## 3. 命令行形态与向后兼容

### 3.1 语法

```
apple-mcp [<component>] [<mode>…]
```

第一个词若是某个组件的 id（`notes`、`reminders`…）就选中该组件，其余的词按现有规则解释：`--stdio`、`setup`/`authorize`、`--self-check`、`agents …`、`skill`、`--version`、`--settings`、`help`，其他词是命令行命令，没有词时看 stdin 是不是管道（是则服务，否则开设置窗口）。`Invocation.parse(words, components:, stdinIsPipe:)` 是纯函数，返回 `(component: String?, mode)`，可以单测。

| 输入 | 含义 |
|---|---|
| `apple-mcp notes --stdio` | 备忘录服务器 |
| `apple-mcp reminders reminders find --list X` | 提醒事项的命令行（组件、名词、动词） |
| `apple-mcp notes notes search "报税"`、`apple-mcp notes folders list` | 备忘录的命令行 |
| `apple-mcp reminders skill` | 打印提醒事项的技能 |
| `apple-mcp setup` / `--self-check` / `agents set-up --all` | 对所有已启用的组件 |
| `apple-mcp notes agents set-up --all` | 只注册 `apple-notes` |
| `apple-mcp --settings`、双击 | 设置窗口（也可 `apple-mcp notes --settings` 预选组件） |
| `apple-mcp --stdio` | 先拒绝，提示 `apple-mcp notes --stdio`。「合并服务器」需要能同时看几个 `tools.json` 的复合 `ToolExposure`，列为以后的可选项（R6） |
| `apple-mcp help` | 产品级帮助：组件列表、全局模式、「`apple-mcp <component> help` 看它的命令」 |

两个组件都有一个和组件同名的名词，所以写全是 `notes notes search`、`reminders reminders find`。经包装命令就是 `apple-notes-mcp notes search`，和今天一样。直接用 `apple-mcp` 时能不能省掉名词，列在第 10 节待定。

### 3.2 `main.swift` 的顺序

1. 读版本；若 `Bundle.main.bundleIdentifier == Product.bundleID` 则 `launcher_become_responsible("APPLE_MCP_RELAUNCHED")`（argv 原样传给副本，组件词不丢）；`setvbuf`。
2. `ConfigFile.backupSuffix = Product.command`；`Shell.relaunchVariables = ["APPLE_MCP_RELAUNCHED"] + 旧名`。
3. `Migration.run(Registry.components)`（幂等，做过一次后几乎零成本；第 6 节）。
4. `Invocation.parse`；选中的组件 = 指定的那个，或 `Registry.components.filter(Settings.isEnabled)`。
5. 为每个组件构造 `ComponentContext`（支持目录、写保护变量、`tools.json`、版本）。
6. `runThenExit`（RunLoop 版）里按模式分发：
   - `.serve`：`Service(name: c.spec.commandName, version:, instructions: c.instructions, tools: c.makeTools(ctx), exposure: ctx.exposure)`，`StdioServer.run`，日志变量 `APPLE_MCP_WIRE_LOG`（回退旧名）。`serverInfo.name` 仍是 `apple-notes-mcp` / `apple-reminders-mcp`，客户端和 e2e 看不出变化。
   - `.setup`：每个组件打印 `== Notes ==` 再 `c.setup(ctx)`；任一失败则退出码 1。顶部横幅（当有组件带 `legacy` 时）：「授予 Apple Notes MCP / Apple Reminders MCP 的权限不会转到 Apple MCP，请再授一次。」
   - `.check`：`Apple MCP <版本> (<bundle id>)`，然后每个组件一段 `c.selfCheck(ctx)`；关掉的组件打印 `Contacts: off (General tab)`。
   - `.agents`：`AgentsCommand.run(args, components: 选中的, installation:)`。
   - `.skill`：`Skill.text(component:installation:)`，组件没有技能则报错。
   - `.command`：`Commands.run(words, component:, tools:, exposure:, program: c.spec.commandName)`。
   - `.settings`：`SettingsPanel.show(components: Registry.components, preselect:)`。

### 3.3 Homebrew 保留旧命令名

新 cask 装三个包装脚本：

```ruby
command_wrapper "apple-mcp",           executable: "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP"
command_wrapper "apple-notes-mcp",     executable: "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP", args: ["notes"]
command_wrapper "apple-reminders-mcp", executable: "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP", args: ["reminders"]
```

生成的 `apple-notes-mcp` 是 `exec "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP" notes "$@"`。于是现有配置里的 `apple-notes-mcp --stdio`、`apple-reminders-mcp agents set-up --all`、`apple-notes-mcp notes search …`、`apple-reminders-mcp reminders find …`、`apple-notes-mcp skill`、`apple-reminders-mcp skill` 一字不改继续有效。

### 3.4 每个组件的注册命令：`Installation.server(for:)`

```swift
public struct ServerSpec: Sendable, Hashable { public let name: String; public let command: String; public let arguments: [String] }

extension Installation {
    /// agent 应该为这个组件启动什么。
    public func server(for component: ComponentSpec) -> ServerSpec {
        if let prefix = homebrewPrefix, Self.wrapperRuns(executable, at: "\(prefix)/bin/\(component.commandName)") {
            return ServerSpec(name: component.serverName, command: "\(prefix)/bin/\(component.commandName)", arguments: ["--stdio"])
        }
        return ServerSpec(name: component.serverName, command: executable, arguments: [component.id, "--stdio"])
    }
    /// 读包装脚本，确认它 exec 的是本可执行文件（而不是还装着的旧 cask 的旧 App）。
    static func wrapperRuns(_ executable: String, at wrapper: String) -> Bool
}
```

`detect` 改看 `/Applications/AppleMCP.app`、`~/Applications/AppleMCP.app`、`Caskroom/apple-mcp`、`pkgutil … com.xiaofeng.apple-mcp.pkg`。`wrapperRuns` 是新加的关键检查：过渡期旧 cask 可能还装着，`/opt/homebrew/bin/apple-notes-mcp` 指向旧 App，不能把那样的注册误判为 `.current`。

### 3.5 现有注册在新 App 里的判定

`Registration.judge(command:arguments:enabled:for spec:)` 逻辑不变，只是拿 `ServerSpec` 比：

| 用户现状 | 新 App 期望 | 判定 | 界面 |
|---|---|---|---|
| Homebrew，已升到 `apple-mcp` cask，配置 `/opt/homebrew/bin/apple-notes-mcp --stdio` | 同一条 | `.current` | 已配置，什么都不用做 |
| Homebrew，旧 cask 还在（包装脚本指向旧 App） | `…/AppleMCP notes --stdio` | `.different` | 更新 |
| pkg，配置 `~/Applications/AppleNotesMCP.app/…/AppleNotesMCP --stdio`，旧 App 还在 | `…/AppleMCP notes --stdio` | `.different` | 更新 |
| pkg，旧 App 已删 | 同上 | `.broken` | 修复 |
| 手写的 TOML inline table | — | `.notEditable` | 已手动配置 |

`agents set-up --all` 一次修好全部。服务器名、工具名、schema 都不变，agent 的会话与技能不受影响。可选润色：`AgentsPanel` 里命令含旧 `legacy.appName` 时，提示文字说「旧的 Apple Notes MCP」。

## 4. Agents 库参数化

| 文件 | 改动 |
|---|---|
| `Installation.swift` | 去掉 `bundleID`/`packageID`/`caskName` 三个静态常量和两个 App 路径字面量；加 `Product {bundleID, packageID, caskName, appName}`、`ComponentSpec`、`ServerSpec`、`detect(product:…)`、`server(for:)`、`launch(for:)`（给技能用，不带 `--stdio`）、`wrapperRuns` |
| `Registration.swift` | 删 `serverName`；`judge(… for spec:)`；`ConfigTarget.tomlTable(spec)`、`jsonPaths(spec)`、`entry(for:at:)`、`registration(for spec:home:)`、`geminiSwitchedOff(spec:home:)`、`register(spec:versions:home:)`；所有 `Registration.serverName` → `spec.name` |
| `Agent.swift` | `setUp(spec:presence:mayQuit:home:)`、`register(spec:…)`（`name = spec.name`，`entry["command"] = spec.command`，`entry["args"] = spec.arguments`）；grok-bot 的说明改成组件无关（「…没法启动这台 Mac 上的服务器」） |
| `ConfigFile.swift` | `public static var backupSuffix = "apple-mcp"`，`backUp` 用它拼 `.bak-<yyyyMMdd>-<suffix>` |
| `Shell.swift` | 探测标记 `__apple_mcp_environment__`；`public static var relaunchVariables = ["APPLE_MCP_RELAUNCHED"]`，`environment` 全部剔除（含旧名） |
| `Skills.swift` | `SkillSpec {name, marker}`；`file(spec:project:home:)`、`registration(of:spec:project:home:)`、`install(_:spec:project:home:)` |

技能 marker 保持 `generated-by: <commandName>`：对 Reminders 就是今天的 `generated-by: apple-reminders-mcp`，字节相同，Homebrew 用户已装的技能保持 `.current`，不需要为旧 marker 写兼容代码。

测试夹具：`RegistrationTests` 的 `Sandbox` 增加 `spec = ServerSpec(name: "apple-reminders", command: <bin/apple-reminders-mcp>, arguments: ["--stdio"])`，备份后缀过滤改 `-apple-mcp`（套件里设 `ConfigFile.backupSuffix`）；新增 `server(for:)` 两种结果、`wrapperRuns`、旧 App 路径 → `.broken` 的测试；`SkillTests` 的 helper 从 `SkillSpec` 取 marker；`ConfigTextTests` 不变。

## 5. 设置窗口

仍用普通 `ObservableObject` 与 `Binding`（Command Line Tools 没有 SwiftUI 宏插件）。`SettingsPanel.show(components:preselect:)`，标题与菜单 Apple MCP。

- **PanelState**：`components`、`enabled: Set<String>`（绑定 `Settings.enabledComponents`）、`permissionStates: [Permission: PermissionState]`——每秒轮询的是已启用组件权限的**并集**（按 `Permission` 分组；任一组件必需即必需；页脚列出需要它的组件）、Notes 那套 `asking` 标志、语言、各组件 `ComponentSetting` 的绑定。
- **AI 助手**：`rows` 的每行带 `registrations: [组件 id: Registration]` 与 `skills: [组件 id: Registration]`；`readConfigs()` 遍历「已启用组件 × 助手」，每个 `(ConfigTarget, spec)` 只读一次。列表上方加一个**组件分段选择**（只启用一个组件时隐藏），决定每行显示哪个组件的状态与按钮；「配置方式：MCP 服务器 / 技能」保留（两个组件都有技能；以后没有技能的组件禁用技能项）。**全部配置**对每个已启用组件 × 每个已安装助手各写一条，页脚说明。「命令」行显示所选组件的 `ServerSpec`。页脚文案用 `spec.serverName` 和 `.bak-<日期>-apple-mcp`。（备选布局：每组件一列，两个组件时可行，四个会挤。）
- **工具**：每个已启用组件一个 Section（段头：显示名 + 它自己的 全选/全不选/反选/只读 + 「已开放 n / m」），各自的 `ToolExposure`（`Settings.exposure(for:)`）与 `FileWatch`；`ToolRow` 的中文标题取自 `component.chineseToolTitles`。工具在窗口打开时在主 actor 上 `makeTools` 一次。两个组件今天各有一个工具标签页，合并只是把它们放进同一页。
- **通用**：权限按并集渲染（可申请的给「允许…」，FDA 给「系统设置…」「在访达中显示」，不必需的加「（可选）」）；语言；每个已启用组件的 `ComponentSetting` 开关；**组件**一节：每个组件一个开关（至少留一个开着），页脚：「关掉的组件在这里隐藏，全部配置、`apple-mcp setup`、`--self-check` 跳过它；已经注册的服务器仍能工作。」

## 6. 数据、设置与环境变量的迁移

`AppCore/Migration.run(components:)` 在 `main.swift` 最早调用，幂等，用 `<supportRoot>/migrated.json` 记录复制了什么、从哪来（`--self-check` 打印）。

| 项目 | 旧 | 新 | 做法 |
|---|---|---|---|
| 支持目录 | `~/Library/Application Support/AppleNotesMCP/`（`backups/`、`descriptions.json`、`tools.json`）、`…/AppleRemindersMCP/`（`tools.json`、`deleted.json`） | `…/AppleMCP/notes/`、`…/AppleMCP/reminders/` | 新目录不存在且旧目录存在时**整目录复制**。复制而不是移动：旧 App 可能还装着在用；旧 cask 的 `zap` 以后清理旧目录。文档说明复制之后两边各自演化 |
| defaults | 域 `com.xiaofeng.apple-notes-mcp`、`com.xiaofeng.apple-reminders-mcp` | 域 `com.xiaofeng.apple-mcp` | `Settings.bool/string(key, legacyDomains:)`：新域没有该键时用 `CFPreferencesCopyAppValue(key, 旧域)` 读，读到就写入新域一次。键：`InterfaceLanguage`（两边都有时 Reminders 优先）、`AllowCompletingRecurringReminders`；新键 `EnabledComponents`（缺省 = 全部） |
| `tools.json` | 两边各一份 | 每组件一份：`AppleMCP/<id>/tools.json`；覆盖变量 `APPLE_MCP_<ID>_TOOLS_FILE` | 随目录复制；没有文件 = 全部工具 |
| 环境变量 | `APPLE_NOTES_MCP_*`、`APPLE_REMINDERS_MCP_*` | `APPLE_MCP_RELAUNCHED`、`APPLE_MCP_WIRE_LOG`、`APPLE_MCP_<ID>_WRITE_GUARD`、`APPLE_MCP_<ID>_TOOLS_FILE` | `Env.scoped/global` 新名优先、旧名回退，1.x 内保留，文档写明移除版本 |
| 技能文件 | `apple-notes/SKILL.md`、`apple-reminders/SKILL.md`，`command:` 指向旧可执行文件 | 同名同 marker | Homebrew 用户：包装路径不变 → `.current`；pkg 用户：命令路径变了 → 显示「更新」一次。frontmatter 只在有参数时加 `args: ["notes"]` / `args: ["reminders"]`。两个技能都还没发版（1.3） |
| 权限 | 授给两个旧 bundle id | 授给 `com.xiaofeng.apple-mcp` | 必须重授一次：`apple-mcp setup` 横幅说明并一次走完所有组件；通用标签页显示未授项；服务器第一次被拒时打开设置窗口一次（`SettingsWindow.openOnce()`，两个组件都有）。文档给出可选的清理：`tccutil reset All com.xiaofeng.apple-notes-mcp`、`tccutil reset All com.xiaofeng.apple-reminders-mcp` |
| 旧 App | `/Applications`、`~/Applications` 下的 `AppleNotesMCP.app`、`AppleRemindersMCP.app` | — | 设置窗口检测到就提供「移到废纸篓并 `pkgutil --forget`」；Homebrew 用户由 cask 迁移自动卸载 |

## 7. 构建、发布、Homebrew 与文档

- 脚本：`build-app.sh` 的 `BUNDLE_ID=com.xiaofeng.apple-mcp`、`APP=dist/AppleMCP.app`、`--product AppleMCP`、entitlements `Resources/AppleMCP.entitlements`；`build-pkg.sh` 的 `PKG_ID=com.xiaofeng.apple-mcp.pkg`、`OUT=dist/AppleMCP-$VERSION.pkg`、标题 Apple MCP；`update-cask.sh` 的 `CASK=Casks/apple-mcp.rb`、`PKG=AppleMCP-$VERSION.pkg`、`-R xiaofeng-han/apple-mcp`。
- `Info.plist`：名字、可执行文件、bundle id、版本 1.0.0；usage string 放全：`NSAppleEventsUsageDescription`、`NSRemindersFullAccessUsageDescription`、`NSRemindersUsageDescription`，并提前放 `NSCalendarsFullAccessUsageDescription`、`NSContactsUsageDescription`（多出的字串无害，以后加组件不用再碰 plist）。`InfoPlist.strings` 中英各五条。`AppleMCP.entitlements`：`com.apple.security.automation.apple-events` + `com.apple.security.personal-information.calendars`。`conclusion.html` 改文案（命令 `AppleMCP.app/Contents/MacOS/AppleMCP <component> --stdio`）。新图标；保留 `build-icon.sh`、`flatten-icon.swift`、`compose-icon.swift`。
- **tap**（`homebrew-tap`）：

  ```ruby
  cask "apple-mcp" do
    version "1.0.0"
    sha256 "…"
    url "https://github.com/xiaofeng-han/apple-mcp/releases/download/v#{version}/AppleMCP-#{version}.pkg"
    name "Apple MCP"
    desc "MCP servers that give AI agents native access to Notes and Reminders"
    homepage "https://github.com/xiaofeng-han/apple-mcp"
    livecheck do
      url :url
      strategy :github_latest
    end
    depends_on arch: :arm64
    depends_on macos: :tahoe
    pkg "AppleMCP-#{version}.pkg"
    command_wrapper "apple-mcp",           executable: "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP"
    command_wrapper "apple-notes-mcp",     executable: "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP", args: ["notes"]
    command_wrapper "apple-reminders-mcp", executable: "/Applications/AppleMCP.app/Contents/MacOS/AppleMCP", args: ["reminders"]
    uninstall pkgutil: "com.xiaofeng.apple-mcp.pkg"
    zap trash: [
      "~/Library/Application Support/AppleMCP",
      "~/Library/Preferences/com.xiaofeng.apple-mcp.plist",
    ]
    caveats <<~EOS
      Grant the permissions once (they do not carry over from Apple Notes MCP or Apple Reminders MCP):
        apple-mcp setup
      Then register the servers with your agents:
        apple-mcp agents set-up --all
    EOS
  end
  ```

  tap 根目录加 `cask_renames.json`：`{"apple-notes-mcp": "apple-mcp", "apple-reminders-mcp": "apple-mcp"}`（`Cask::Migrator` 支持两个旧 token 迁到一个新 token，见 1.4）。发布前先把 tap 以本地目录 `brew tap` 进来，在「只装一个旧 cask」「两个都装」两种情况下演练 `brew upgrade`。若 rename 路径有问题，备选：只 rename `apple-reminders-mcp`，`apple-notes-mcp.rb` 发最后一版 `disable! date: …, because: "merged into apple-mcp", replacement_cask: "apple-mcp"`。不做「薄包装 cask」（旧 cask 只装包装脚本、`depends_on cask: "apple-mcp"`）：它会和 `apple-mcp` 争同一批 `/opt/homebrew/bin/*` 链接。
- **仓库**：改名后用旧 release 下载地址实际下载一次验证重定向；`update-cask.sh` 和 README 里的仓库名改掉。
- **文档**：一份 `README.md`/`README.zh-CN.md` 讲产品（安装、从两个旧 App 升级、设置窗口、命令行语法与包装命令、按服务器名注册客户端、签名、构建发布、测试）；`docs/notes.md`、`docs/reminders.md`（+ `.zh-CN`）承载各组件的工具表、Markdown 对应表、规则、命令树、对比表、限制（即两个 README 现在的组件章节）。

## 8. 测试

- `swift test` 一个 package：`AgentsTests`（新夹具 + 新测试）、`WireTests`、`NoteModelTests`。
- 新 `AppCoreTests`：`Invocation.parse` 的表（组件前缀、包装命令传来的形式、不带组件时的错误、管道与设置窗口）；`Env` 新名优先于旧名；`Settings.supportDirectory(for:)` 在临时 `HOME` 下的路径；`Migration.run` 只复制一次、defaults 只迁一次（临时 `HOME` + `UserDefaults(suiteName:)`）；`Commands.tree/help` 用注入的路由表；`Skill.text` 只在有参数时带 `args:`。
- 新 `RegistryTests`（`@MainActor`，用临时 `ComponentContext` 调 `makeTools`）：所有组件的工具名全局唯一；`spec` 三个字段各自唯一；每条 route 和每个中文标题都指向该组件真实存在的工具；每个组件的 `Service` 回答 `tools/list` 时恰好只有自己的工具；每个组件至少声明一个权限。
- `scripts/e2e.py <notes|reminders> [可执行文件]` 分发到 `scripts/e2e/{harness,notes,reminders}.py`：harness 启动 `[APP, component, "--stdio"]`，设 `APPLE_MCP_<ID>_WRITE_GUARD` 与 `_TOOLS_FILE`，提供 `rpc/notify/call/check`、`cli(component, …)`，以及 `tools.json` 变更通知检查和无状态协议检查（两个 `e2e.py` 现在各有一份几乎逐行相同的，合并后只写一份，参数是组件的工具表和只读工具名）；`notes.py` 是 Notes 现在的检查（93 项，`serverInfo.name == "apple-notes-mcp"`、10 个工具，命令行部分调 `[APP, "notes", 名词, 动词…]`）；`reminders.py` 是 Reminders 现在的检查（167 项，16 个工具，命令行部分调 `[APP, "reminders", 名词, 动词…]`）。去掉共用部分后两边的项数会少一些，总数按实跑结果写进 README。

## 9. 分阶段实施

每一阶段都能独立验证；前两阶段不发版。

| 阶段 | 内容 | 验证 |
|---|---|---|
| 0 仓库 | GitHub 改名 `apple-reminders-mcp` → `apple-mcp`；并入 Notes 历史（见附录）；按 2.5 的映射把两边文件放进一棵树 | 仓库能 clone，旧地址重定向 |
| 1 共享 target | `Wire` 取 Notes 版（已是并集）、`Launcher` 取任一边、`Agents` 按第 4 节参数化；两个旧可执行文件 `AppleNotesMCP`、`AppleRemindersMCP` 保留，各自传旧的 `Product`/`ServerSpec`/`SkillSpec`/旧 bundle id，行为不变 | `swift build`；`swift test`（三套）；两个旧 `e2e.py` 分别打 `.build/debug/<可执行文件>`（开发构建用父进程的权限） |
| 2 单一可执行文件 | `AppCore`、`NotesComponent`、`RemindersComponent`、`Registry`、新 `main.swift`（RunLoop 版）、通用 CLI 与 `AgentsCommand`；删掉两个旧可执行文件；设置窗口先用 Reminders 现有的指向一个组件也可 | `swift test` 含 `RegistryTests`；`e2e.py notes`、`e2e.py reminders` 打 `.build/debug/AppleMCP`；`--self-check`、`agents list`、`agents set-up --all`（临时 `HOME`）；`apple-mcp reminders reminders find`、`apple-mcp reminders help`、`apple-mcp notes notes search`、`apple-mcp notes help`、两个 `skill` 的输出与从前一致 |
| 3 设置窗口 | 第 5 节 | 手工：只开 Reminders 时 Notes 处处隐藏；全部配置给每个助手写两条；工具标签改对文件，运行中的服务器收到 `list_changed` |
| 4 迁移、tap、文档 | 第 6、7 节；`HARDENED=1` 构建 | 与旧 App 并存安装：数据已复制、defaults 带过来、旧注册显示更新/修复、Homebrew 包装的注册显示已配置、权限引导出现；本地 tap 演练两种升级；`brew audit --cask --strict`、`brew style` |
| 5 发布 | `gh release create v1.0.0`、`update-cask.sh`、tap 的 `cask_renames.json`；两个旧仓库各发一条「已合并到 apple-mcp」的 release 说明；归档 `apple-notes-mcp` | 从旧 cask 名 `brew upgrade` 成功；旧 release 链接仍可下载 |

## 10. 风险与待定

- **R1 重新授权**不可避免（新 bundle id、新 designated requirement）。缓解：`setup` 横幅、通用标签页、服务器被拒时打开设置窗口一次。现在用户最少，越早做代价越小。
- **R2 Homebrew 两→一迁移**要在本地 tap 演练；旧 pkg 收据会残留（文档写 `pkgutil --forget`）。
- **R3 两个旧 App 并存**：注册显示「更新」而不是「已配置」；支持目录复制后两边分叉；`wrapperRuns` 防止把指向旧 App 的包装脚本误判为 `.current`。
- **R4 RunLoop 取代 `dispatchMain()`** 对 EventKit/ReminderKit 路径要在真机确认（阶段 2 的 `e2e.py reminders`）。Notes 的服务器和命令行都已在 RunLoop 版 `runThenExit` 下跑过 e2e；Reminders 两者都只在 `dispatchMain()` 下验证过。
- **R5 技能文本变化**让已装技能显示「更新」：Homebrew 用户因 marker 与命令路径都不变而不受影响，pkg 用户显示一次。两个组件的技能都一样处理。
- **R6 合并服务器**（`apple-mcp --stdio`）需要复合 `ToolExposure`（几份 `tools.json`、各一个 `FileWatch`）；先拒绝并提示，以后再做。
- 待定：
  - FDA 探测文件（通用的 `TCC.db` 还是各组件自己的数据文件）。
  - AI 助手标签的布局（分段选择还是每组件一列）。
  - 图标。
  - 版本号从 1.0.0 开始。
  - 合并前要不要先单独发 Notes 0.2.0 / Reminders 0.3.0，把命令行、技能和工具开关发出去。先发：用户早一点用上，但多一次升级，迁移要真正处理已装的技能和 `tools.json`。不发：合并版 1.0.0 一次带上，迁移只照顾从 main 构建的人。倾向不发，理由同「结论」。
  - `apple-mcp` 直接调用时能否省掉与组件同名的名词：组件词后面若不是该组件的名词，而是同名名词的动词，就当省略了名词（`apple-mcp notes search` = `apple-mcp notes notes search`）。`Invocation.parse` 里加一条规则，有单测。省略后若与某个全局模式同名（`setup`、`skill`、`help`），仍按全局模式。
- 已定（原待定）：Notes 也提供命令行与技能——PR #1 已实现，路由与技能正文直接搬进 `NotesComponent`。

## 附录：仓库操作

```sh
# 1. GitHub 上把 apple-reminders-mcp 改名为 apple-mcp（Settings → General → Repository name）。
git clone git@github.com:xiaofeng-han/apple-mcp.git && cd apple-mcp

# 2. 把 apple-notes-mcp 的历史并进来，文件先落在 incoming/notes/ 下，避免同名文件冲突。
git remote add notes git@github.com:xiaofeng-han/apple-notes-mcp.git
git fetch notes
git merge --allow-unrelated-histories -s ours --no-commit notes/main
git read-tree --prefix=incoming/notes -u notes/main
git commit -m "Merge the history of apple-notes-mcp"

# 3. 按 2.5 的映射表 git mv incoming/notes/… 到位，再按阶段 1 泛化。

# 4. 验证旧地址重定向（改名后）。
curl -sIL https://github.com/xiaofeng-han/apple-reminders-mcp/releases/download/v0.2.4/AppleRemindersMCP-0.2.4.pkg | grep -i '^location'

# 5. apple-notes-mcp：README 换成指向 apple-mcp 的说明，发一条 release 说明，然后在 GitHub 上归档（Settings → Archive）。
```
