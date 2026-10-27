# 共用底座：一个仓库出 Apple Notes MCP 与 Apple Reminders MCP 两个 App

调查与方案，2026-10-21 写成；2026-10-27 按两边当时的 `main` 校对过：`apple-notes-mcp`（`4b279db`，0.3.0 已发）、`apple-reminders-mcp`（`8038474`，0.3.0 已发）、`homebrew-tap`（`48ddcf7`，两个 cask 都在 0.3.0）。两个仓库都是公开的。

> 校对说明（2026-10-27）：原定「先从两个旧仓库各发一次再搬家」已经做完——Notes 0.2.0（10-21）、0.3.0（10-22），Reminders 0.3.0（10-21）。Notes 0.3.0 另外加了 `manage_tag` 工具、`--copy-note` 和 `--check-markdown` 两个私有模式、`scripts/release.sh`（一条命令发版）、`CHANGELOG.md` 和 GitHub Actions 的 `check.yml`；Reminders 自 0.2.4 以来只有版本号变了。这些已反映到下文（1.1、2.2、3、7、8、9、11 节）；方案本身不变。

> 改写说明（2026-10-21）：初稿是把两个 App 合成一个 Apple MCP（`AppleMCP.app`、`com.xiaofeng.apple-mcp`）。讨论后改成「表面分开、底下共用底座」：一个仓库出两个 App，各自保留 bundle id、cask、命令名和版本号，只把重复的代码收成共用的 target。初稿和当天定下的决定在新方案里还适不适用，逐条见第 11 节；初稿全文在本文件的 git 历史里（`cf9f09a`）。

## 结论

不合成一个 App，只合并代码。真正的问题是两个仓库是同一骨架的两份拷贝，同一个改动要做两遍：Reminders 10-21 加的命令行、技能和工具标签页，Notes 当天又专门补了一轮。共用底座就解决了这个问题。把两个产品也合成一个，换来的「装一次、一个窗口」抵不过它的代价：

| | 合成一个 App（初稿） | 两个 App、共用底座（本方案） |
|---|---|---|
| 权限 | 一个 App 同时拿完全磁盘访问、控制备忘录、提醒事项，以后还有日历和通讯录；哪个部分出问题都碰得到全部 | 每个 App 只拿自己要的 |
| 已授的权限 | 新 bundle id，全部重授一次 | 不变 |
| 迁移 | cask 二合一、支持目录、defaults、清理旧 App | 没有，用户升级就是普通升级 |
| 命名 | `apple-mcp notes notes search`；「Apple MCP」听起来像苹果官方产品 | 和今天一样 |
| 只用其中一个的人 | 也会装上另一个 | 只装自己要的 |
| 两个都用的人 | 一个窗口配好所有助手 | 每个 App 各配一次 |
| 重复代码 | 消失 | 消失 |

这也是一扇双向门：共用底座正是初稿的阶段 1–2。以后 App 多了、真想合成一个，在底座上再做；单向的那一步（新 bundle id、重授权限、cask 改名）留到那时再决定。

已定决策：

| 事项 | 决定 |
|---|---|
| 产品 | 两个 App 照旧。Apple Notes MCP：`AppleNotesMCP.app`、`com.xiaofeng.apple-notes-mcp`、命令与 cask `apple-notes-mcp`、服务器 `apple-notes`。Apple Reminders MCP：`AppleRemindersMCP.app`、`com.xiaofeng.apple-reminders-mcp`、`apple-reminders-mcp`、`apple-reminders`。命令名、服务器名、支持目录、defaults、权限、图标都不变 |
| 仓库 | 一个仓库出两个 App，底座也在这个仓库里，不单独成仓库（理由见 2.6）。GitHub 上把 `apple-reminders-mcp` 改名为 `apple-mcp`，并入 `apple-notes-mcp` 的历史；`apple-notes-mcp` 在新仓库第一次发 Notes 之后清空到只剩一个 `README.md`（指向新仓库地址，2026-10-27 定），然后归档；它的 tag 和 release 原样保留。`apple-mcp` 只是仓库名，不是产品名 |
| 版本与发版 | 各自的版本号和节奏，接着现在的往下走。搬家前先从两个旧仓库各发一次的决定（2026-10-21 定）已经执行：Notes 0.2.0、0.3.0（`v0.2.0`、`v0.3.0`，`apple-notes-mcp`）、Reminders 0.3.0（`v0.3.0`，`apple-reminders-mcp`）。搬进新仓库后的版本 tag 带前缀（如 `notes-v0.4.0`、`reminders-v0.4.0`），用 Notes 现有的 `scripts/release.sh` 发（第 7 节）。只改了一个 App 就只发那一个 |
| 用户看到的变化 | 没有：两个 App 的命令、`help`、技能文本、写进 agent 的配置、`serverInfo`、设置窗口都与重构前逐字相同，用黄金输出检查（第 8 节） |

## 1. 现状调查

### 1.1 两个仓库的异同

| 目录 | Notes | Reminders | 关系 |
|---|---|---|---|
| `Sources/Wire` | `JSON`、`Schema`、`Service`、`Exposure`（工具开关）、`FileWatch`、`Flags`（命令行参数解析） | 同 | `JSON`、`Schema`、`FileWatch`、`Flags` 字节相同；`Exposure` 只差注释里的示例工具名；`Service` 只差 Notes 多出的 `Content.audio`、`.file` 两个 case、日志变量名、stderr 前缀和一行注释 |
| `Sources/Launcher` | `launcher_become_responsible`、`launcher_spawn_disclaimed`、`launcher_is_sandboxed` | 同 | `.c` 字节相同；`.h` 只差注释里的权限名 |
| `Sources/Agents` | 12 个文件（含 `Skills.swift`） | 同 | `ConfigValue`、`Installer`、`JSONText`、`Presence`、`RunningApp`、`TOMLText` 字节相同；`Agent`、`ConfigFile`、`Installation`、`Registration`、`Shell`、`Skills` 只差产品字串（每个 4–14 行） |
| `App/` | `SettingsPanel`、`AgentsPanel`（含技能模式）、`AgentsCommand`、`ToolsPanel`；三个标签页 | 同 | `AgentsPanel`、`AgentsCommand` 只差产品字串（14 行）；`ToolsPanel` 只差中文工具名和一句文案；`SettingsPanel` 的「通用」页按各自的权限与设置不同（Notes：完全磁盘访问 + 自动化→备忘录；Reminders：提醒事项 + 可选的完全磁盘访问 + 重复提醒开关） |
| `CLI/` | `Commands.swift`（名词/动词命令树）、`Skill.swift`（生成 SKILL.md） | 同 | 机制相同，路由表和技能正文不同。两边的 `Route` 各有对方没有的东西，见第 3 节 |
| 产品本体 | `NotesShim`（ObjC ~960 行）、`NoteModel`（~1,400，0.3.0 加了 `Checklist.swift`）、`Store/`（~3,200，加了 `Filters.swift`）、`Tools/`（~1,250） | `ReminderKitShim`（ObjC ~1,450）、`Store/`（~1,200）、`Tools/`（~900）、`SmartFilter`（~250） | 完全不同，互不依赖 |
| 测试 | `AgentsTests`（+ `SkillTests`）、`WireTests`、`NoteModelTests` | `AgentsTests`（+ `SkillTests`）、`WireTests` | `AgentsTests`、`WireTests` 只差产品字串 |
| 脚本/资源 | `build-app.sh`、`build-pkg.sh`、`update-cask.sh`、`e2e.py`（145 项：经 stdio 的工具、主要的命令行命令、工具开关与通知）、图标脚本（`build-icon.sh`、`compose-icon.swift`、`pbshape.py`）、Info.plist、entitlements、InfoPlist.strings、conclusion.html。**只有 Notes 有**：`scripts/release.sh`（一条命令发版：改版本号、`swift test`、打包、提交、tag、GitHub release、更新 cask）、`CHANGELOG.md`（release 说明的来源，目前只有 `## 0.2.0` 一节）、`.github/workflows/check.yml`（PR 和 main 上在 `macos-26` runner 跑 `swift build`、`swift test`） | 同（`e2e.py` 167 项；图标脚本是 `flatten-icon.swift`）；没有 `release.sh`、`CHANGELOG.md` 和 CI | 只差产品字串和权限文案；两个 `e2e.py` 的工具开关、通知和无状态协议部分几乎逐行相同 |

共享部分（`Wire`、`Launcher`、`Agents`）约 3,200 行；加上同样几乎逐字相同的 `App/`（~1,140）和 `CLI/` 的机制部分，两边各有一份的代码约 5,000 行。Notes 有 15 个提交，Reminders 23 个；两边的历史互不相干，合并没有包袱（见附录）。

两边的 `main.swift` 都有进程级全局变量（`version`、`words`、`writeGuard`、`store`、`tools`），被 `CLI/Commands.swift`、`CLI/Skill.swift`、`App/AgentsCommand.swift` 直接读取；进底座时它们要变成参数。Notes 因为 `NotesStore` 是 `@MainActor`，在顶层用 `MainActor.assumeIsolated` 构造 `store` 和 `tools`。

Notes 0.3.0 的 `main.swift` 多了两个只有它有的模式：`--copy-note NOTE [FOLDER]`（`create_note` 的 `copy_of` 由服务器用 `Bundle.main.executablePath` 再启动自己来跑，因为 Notes 复制笔记的代码会改变本进程之后保存编辑的方式）和 `--check-markdown`（把每条笔记读出、写成 Markdown 再解析回来做对照，只读）。Reminders 没有私有模式，只多一个 `setup` 的别名 `authorize`。底座的 `AppMain` 要让组件声明这类模式（2.2 节）。再启动自己的那条路径不受本方案影响：每个 App 仍是自己的可执行文件。

Notes 0.3.0 还加了第 11 个工具 `manage_tag`，与 Reminders 的 `manage_tag` 同名。两个 App 各自注册服务器，这没有影响；只有以后真要合成一个 App 时才要处理（第 11 节、R5）。

### 1.2 产品身份写死在哪里

底座要把这些地方做成参数，由每个 App 的 `Product`（2.2）填值；填进去的值就是今天写死的字串，所以对用户没有变化（行号以 Reminders 仓库为准，Notes 对应位置相同或相近）：

| 类别 | 位置 |
|---|---|
| bundle id、pkg id、cask 名、App 路径 | `Sources/Agents/Installation.swift:14-16`（三个常量）、`:45`、`:53`（`/Applications/X.app`、`~/Applications/X.app`）；`main.swift` 的 bundle id 门控（`launcher_become_responsible` 只在 App bundle 里调用）；`Resources/Info.plist`；`scripts/build-app.sh:14`、`build-pkg.sh:22`、`update-cask.sh:13-18`、`release.sh:22-25`（Notes；`APP`、`TITLE`、`REPO`、`CASK`）；`e2e.py` |
| 服务器名 `apple-notes` / `apple-reminders` | `Sources/Agents/Registration.swift:20`（`Registration.serverName`，其余 10 余处引用它）；`Agent.swift:104`；`AgentsPanel` 页脚文案 |
| `serverInfo.name` | `main.swift`：`Service(name: "apple-reminders-mcp", …)`；`e2e.py` 检查它 |
| 备份后缀 `.bak-<日期>-apple-*-mcp` | `Sources/Agents/ConfigFile.swift:63` |
| 登录环境探测标记、`*_RELAUNCHED` 剔除 | `Sources/Agents/Shell.swift:51`、`:95` |
| 技能名与 marker | `Sources/Agents/Skills.swift:21`（`apple-reminders/SKILL.md`；Notes 是 `apple-notes/SKILL.md`）、`:23`（`generated-by: apple-reminders-mcp`；Notes 是 `generated-by: apple-notes-mcp`） |
| 环境变量 | `APPLE_NOTES_MCP_{RELAUNCHED,WIRE_LOG,WRITE_GUARD,TOOLS_FILE}`、`APPLE_REMINDERS_MCP_{RELAUNCHED,WIRE_LOG,WRITE_GUARD,TOOLS_FILE}` |
| 支持目录 | `Store/Settings.swift`：`~/Library/Application Support/AppleNotesMCP/{backups/,descriptions.json,tools.json}`、`…/AppleRemindersMCP/{tools.json,deleted.json}`；两边的 `Settings.exposure` 和 `toolsFileOverride` 写法相同 |
| defaults 域与键 | `UserDefaults.standard`（随 bundle id，每个 App 自然各用各的）：`InterfaceLanguage`（两边）、`AllowCompletingRecurringReminders`（Reminders） |
| 命令名 | `CLI/Commands.swift`（`program`；临时文件前缀 `apple-reminders-` / `apple-notes-`）；`CLI/Skill.swift` 文案；`AgentsCommand` usage；`Wire/Service.swift` stderr 前缀 |
| 显示名与权限文案 | `SettingsPanel`（窗口标题、菜单）、`AgentsPanel` 段头与技能说明、`ToolsPanel`（「AI 助手就完全用不了备忘录 / 提醒事项」）、`Store/System.swift`（Notes 的 `fullDiskHelp`/`automationHelp`/`sandboxHelp`）、`RemindersStore.swift:25-34`（`permissionHelp`/`sandboxHelp`）、`Tools/Output.swift`、`Info.plist` 的 usage string、`InfoPlist.strings`、`conclusion.html` |

`Sources/Agents` 里只有 `Installation`、`Registration`、`ConfigFile`、`Shell`、`Skills`、`Agent`（grok-bot 的说明文字）六处带产品身份，其余都是中性的。`Launcher` 不带产品名（marker 是参数）。`Wire` 只在 `Service` 的日志变量名和 stderr 前缀里带。

### 1.3 已查证的外部事实

- **GitHub 仓库改名**：git、网页和 API 地址自动重定向到新名（GitHub Actions 的 `uses:` 和 Pages 除外），只要不再用旧名新建仓库；release 下载链接在网页路径下，预期一同重定向——改名后用旧地址实际下载一次验证。归档的仓库只读，但它的 release 仍能下载；把工作树里的文件删光也不影响 tag 和 release，历史仍在，`git checkout v0.3.0` 照样能拿到当时的全部代码。
- **macOS 隐私权限**（TCC）按 bundle id + 代码签名的 designated requirement 记录。本方案不换 bundle id、签名证书也不变（`Xiaofeng Local Code Signing`），所以已授的权限全部保留——这是不合成一个 App 的主要好处之一。
- **一个仓库发两个产品**：GitHub 的「Latest release」整个仓库只有一个，会在两个 App 之间来回跳；两个 cask 现在的 `livecheck` 是 `strategy :github_latest`，要改成按 tag 前缀找（`strategy :github_releases` 加 `regex`，第 7 节），发布前用 `brew livecheck --cask` 验证。

## 2. 目标架构

### 2.1 Package 与 target

```
Wire ─────────────────┐
Launcher ─► Agents ───┼─► AppCore ─┬─► NotesComponent ◄── NoteModel、NotesShim
                      │            │      └─► AppleNotesMCP（可执行文件，只有 main.swift）
                      │            └─► RemindersComponent ◄── ReminderKitShim
                      │                   └─► AppleRemindersMCP（可执行文件，只有 main.swift）

测试：AgentsTests(Agents)  WireTests(Wire)  NoteModelTests(NoteModel)  AppCoreTests(AppCore)
      NotesComponentTests  RemindersComponentTests
```

- `Agents` 不依赖 `AppCore`，继续可以单独测试；它只增加一个值类型 `Product`，由各 App 填值。
- `AppCore` 放两个 App 共用、与具体产品无关的东西：`Component` 协议、`AppMain`（按第一个词分发模式、relaunch、RunLoop 版 `runThenExit`）、`Permission`（共用的探测与申请：完全磁盘访问、自动化、沙盒判断）、`Settings`（支持目录、`tools.json`、语言）、通用命令行（`Route`/`Commands`/`Skill`，取两边的并集，第 3 节）、设置窗口（窗口与菜单、AI 助手标签页、工具标签页、「通用」页的语言部分）、`AgentsCommand`。
- 每个 App 的产品代码是一个库 target（`NotesComponent`、`RemindersComponent`），只导出一个 `Component` 值；两边同名的内部类型（`Input`、`Output`、`readTools`、`writeTools`、`withNotes`/`withStore`、`NotesError`/`StoreError`）各在自己的 module 里，互不干扰。
- 可执行文件只剩一行：`AppMain.run(NotesComponent())`。以后加一个 App（日历、通讯录）= 新组件 target + 新可执行文件 + 自己的 `Resources/<app>/` + 一个 cask。

### 2.2 `Product` 与 `Component`

```swift
public typealias LocalizedText = (english: String, chinese: String)

/// 一个 App 的身份。定义在 Agents 里（Agents 写 agent 配置要用），AppCore 再导出。
/// 值与今天写死的字串相同，所以重构后用户看到的一切不变。
public struct Product: Sendable {
    public let name: String              // "Apple Notes MCP"：窗口标题、菜单、--self-check
    public let bundleID: String          // "com.xiaofeng.apple-notes-mcp"：只有它才 relaunch 取得自己的权限
    public let appName: String           // "AppleNotesMCP"：App、可执行文件、pkg、支持目录
    public let command: String           // "apple-notes-mcp"：命令、cask、serverInfo.name、技能 marker、备份后缀
    public let serverName: String        // "apple-notes"：agent 里注册的名字、技能文件夹名
    public let environmentPrefix: String // "APPLE_NOTES_MCP"：_RELAUNCHED、_WIRE_LOG、_WRITE_GUARD、_TOOLS_FILE
}

/// 组件自己的一个布尔设置，由它的「通用」页渲染。
public struct ComponentSetting: Sendable {
    public let key: String               // UserDefaults 键，如 "AllowCompletingRecurringReminders"
    public let defaultValue: Bool
    public let title: LocalizedText
    public let footer: LocalizedText
}

/// AppMain 交给组件的东西。
public struct ComponentContext: Sendable {
    public let supportDirectory: URL     // ~/Library/Application Support/<appName>
    public let writeGuard: String?       // <PREFIX>_WRITE_GUARD 的原文，由组件自己解析
    public let exposure: ToolExposure    // <supportDirectory>/tools.json，或 <PREFIX>_TOOLS_FILE
    public let version: String
}

public protocol Component: Sendable {
    var product: Product { get }
    var instructions: String { get }                       // MCP initialize 的 instructions
    var chineseToolTitles: [String: String] { get }        // 工具标签页
    var settings: [ComponentSetting] { get }               // 没有则 []
    var routes: [Route] { get }
    var defaultVerbs: [String: String] { get }
    var rewordings: [(String, String)] { get }             // 工具文案 → 命令行参数名的固定替换
    /// 缺权限时服务器打开设置窗口一次（Notes 今天有；Reminders 今天没有，默认 false 以保持原样）。
    var opensSettingsOnMissingPermission: Bool { get }
    /// 只有这个 App 才有的模式，按第一个词认：Notes 的 --copy-note、--check-markdown，Reminders 的
    /// setup 别名 authorize。AppMain 先认共用的模式，再问这里，最后才当作命令。默认 [:]。
    var privateModes: [String: @Sendable (_ words: [String], _ context: ComponentContext) -> @MainActor () async -> Int32] { get }
    /// 技能正文（frontmatter 的 description + 规则）；命令参考由底座按 routes 生成。
    func skillText(run: String, reference: String) -> String
    /// 同一组 Tool 既给 MCP 也给命令行。主 actor：Notes 的 store 绑定主线程。
    @MainActor func makeTools(_ context: ComponentContext) -> [Tool]
    /// `setup`：在终端里申请或引导本 App 的权限，返回退出码。
    @MainActor func setup(_ context: ComponentContext) async -> Int32
    /// `--self-check` 在产品标题后打印的行。
    @MainActor func selfCheck(_ context: ComponentContext) async -> [String]
    /// 「通用」页里语言选择以外的部分：权限与设置。两个 App 这部分本来就不同，由组件给出视图。
    @MainActor func generalSection(_ panel: PanelState) -> AnyView
}
```

`Permission` 只放两边都用得上的探测与申请代码，组件在自己的 `setup`、`selfCheck`、`generalSection` 里调用：

- **完全磁盘访问**：读 `~/Library/Application Support/com.apple.TCC/TCC.db` 的开头。它受 FDA 保护，每台 Mac 都有，和用户用不用备忘录无关（2026-10-21 定）。Notes 打不开自己的数据库时（比如从没开过备忘录）仍报它自己的错误，不算缺权限。申请 = 打开 `Privacy_AllFiles` 并在访达里选中 App（Notes 现有逻辑）。
- **自动化**：Notes 的 `Permissions.automation(ask:)` + `startNotesHidden()` 推广到任意 bundle id，含 20 × 250 ms 的重试。
- **沙盒**：两边都用 `launcher_is_sandboxed()` 把缺权限改报成「到沙盒外再跑一次」（Notes 在 `Tools/Output.swift` 的 `explain`，Reminders 在 `RemindersStore.ensureAccess`）。判断放进 `Permission` 一处，文案仍由各 App 给，字句不变。
- 提醒事项权限（EventKit）只有 Reminders 用，留在 `RemindersComponent`；以后日历、通讯录也各自放在自己的组件里。

### 2.3 底座与各 App 的分工

| 底座（`Wire`、`Launcher`、`Agents`、`AppCore`） | 每个 App（组件 target + 可执行文件 + 资源） |
|---|---|
| MCP 服务（stdio、会话与无状态协议、`list_changed`） | 数据层与工具（`NotesStore`/`RemindersStore`、`Tools/`） |
| 命令行机制、`help` 树、技能的命令参考 | 路由表、默认动词、固定替换、技能正文 |
| 工具开关：`tools.json` 的读写、监视、拒绝 | 工具的中文标题 |
| agent 的发现、安装、注册、技能安装（`Agents`、`AgentsCommand`） | `Product` 的值 |
| 设置窗口：窗口与菜单、AI 助手页、工具页、语言 | 「通用」页的权限与设置部分 |
| 模式分发、relaunch、RunLoop、写保护与工具文件的环境变量 | `setup`、`--self-check` 的内容、权限文案、`instructions` |
| 完全磁盘访问、自动化、沙盒的探测 | EventKit 等自己独有的权限 |
| e2e 的公共部分（`scripts/e2e/harness.py`） | e2e 的产品部分（`notes.py`、`reminders.py`） |
| 构建、打包、发版脚本（带 App 参数） | `Resources/<app>/`：Info.plist、entitlements、图标、InfoPlist.strings、conclusion.html |

### 2.4 主线程模型

底座的 `runThenExit` 用 Notes 的 RunLoop 版，弃用 Reminders 的 `dispatchMain()`：Notes 的 Core Data context 是主队列 context，`dispatchMain()` 会让主线程退出、主队列由别的线程服务，保存时死锁（Notes `main.swift` 里的注释）。Notes 的服务器和命令行都已在 RunLoop 版下跑过 e2e；Reminders 两者都只在 `dispatchMain()` 下验证过。EventKit/ReminderKit 在 RunLoop 下预期没有问题（`requestFullAccessToReminders` 本来就需要跑着的 run loop），但要在真机上用 `e2e.py reminders` 确认（风险 R2）。

### 2.5 文件映射（`git mv`）

| 新位置 | 来自 |
|---|---|
| `Sources/Wire/*` | Notes（它的 `Service.swift` 已含 `Content.audio`、`.file`，其余与 Reminders 相同） |
| `Sources/Launcher/*` | 任一边（只差注释），注释改成与产品无关 |
| `Sources/Agents/*` | Reminders，按第 4 节参数化 |
| `Sources/AppCore/CLI/{Route,Commands,Skill}.swift` | 两边 `CLI/*` 的通用机制，取并集（第 3 节） |
| `Sources/AppCore/SettingsWindow/{SettingsPanel,AgentsPanel,ToolsPanel}.swift` | 两边 `App/*`（只差产品字串），以 Reminders 为底泛化 |
| `Sources/AppCore/{AgentsCommand,AppMain,Component,Permission,Settings}.swift` | 两边的 `AgentsCommand`、`main.swift`、`Store/Settings.swift`，加新写的协议 |
| `Sources/NoteModel/*`、`Sources/NotesShim/*` | Notes |
| `Sources/NotesComponent/{Store,Tools}/*` | Notes `Sources/AppleNotesMCP/{Store,Tools}/*`，去掉 `Settings.swift`；`System.swift` 保留 `NotesError`、`AppleScript`、`waitFor` 和权限文案，探测代码移到 `AppCore/Permission` |
| `Sources/NotesComponent/{Routes,SkillText,GeneralSection,NotesComponent}.swift` | Notes `CLI/Commands.swift` 的路由数据、`CLI/Skill.swift` 的正文、`SettingsPanel` 的「通用」页，加新写的组件值 |
| `Sources/AppleNotesMCP/main.swift` | 新写，一行 |
| `Sources/ReminderKitShim/*` | Reminders |
| `Sources/RemindersComponent/{Store,Tools}/*`、`SmartFilter.swift` | Reminders `Sources/AppleRemindersMCP/…`，去掉 `Store/Settings.swift` |
| `Sources/RemindersComponent/{Routes,SkillText,GeneralSection,RemindersComponent}.swift` | 同 Notes |
| `Sources/AppleRemindersMCP/main.swift` | 新写，一行 |
| `Tests/AgentsTests/*`、`Tests/WireTests/*` | 两边只差产品字串，取 Reminders，夹具用一个测试用 `Product` |
| `Tests/NoteModelTests/*` | Notes |
| `Tests/AppCoreTests/*`、`Tests/NotesComponentTests/*`、`Tests/RemindersComponentTests/*` | 新写 |
| `Tests/Golden/{notes,reminders}/*`、`scripts/golden.py` | 阶段 0 录下的黄金输出与录制脚本（第 8 节） |
| `Resources/Notes/*`、`Resources/Reminders/*` | 两边各自的 `Resources/*` 原样搬过去 |
| `scripts/{build-app,build-pkg,update-cask,release}.sh` | 合成一份，第一个参数是 `notes` 或 `reminders`（第 7 节）；`release.sh` 来自 Notes |
| `CHANGELOG-notes.md`、`CHANGELOG-reminders.md` | Notes 现有的 `CHANGELOG.md`（先补上 0.3.0 一节）；Reminders 的新建，以前的 release 说明留在 GitHub Releases 上 |
| `.github/workflows/check.yml` | Notes；一个 package，一次 `swift build`、`swift test` 就覆盖两个 App |
| `scripts/{build-icon.sh,compose-icon.swift,flatten-icon.swift}` | 两边的图标脚本 |
| `scripts/e2e.py`、`scripts/e2e/{harness,notes,reminders}.py` | 两个 `e2e.py` 拆分（第 8 节） |
| `README.md`、`README.zh-CN.md` | 新写：仓库总览，两个 App 各一段（是什么、怎么装），链到各自的文档 |
| `docs/notes.md`、`docs/reminders.md`（+ `.zh-CN`） | 两个 README 现在的全文，安装与构建命令改成新仓库的写法 |
| `docs/RE-FINDINGS.md` | Notes |

### 2.6 为什么底座不单独成一个仓库

底座和两个 App 放在同一个仓库里，不拆成「底座仓库 + 两个 App 仓库」：

- **底座正在频繁变化**：10-21 的三项功能（命令行、技能、工具开关）全部是底座改动。同一个仓库时，一个提交同时改底座和用到它的两个 App，两套 e2e 在同一个提交上跑完再合入。
- **拆开的代价**：改底座要先在底座仓库合入、打版本，再到两个 App 仓库各升级一次依赖、各开一个 PR；中间两个 App 跑着不同版本的底座；本地同时改底座和 App 要用 `swift package edit` 或本地路径覆盖；issue 和 CI 分散在三个仓库。一个人维护，这些全是额外工作。
- **什么时候值得拆**：底座稳定下来很少改；有别的项目想单独用它（比如别的 MCP App）；或者两个 App 换人维护。到那时可以用 `git subtree split --prefix=Sources/AppCore`（连同 `Wire`、`Launcher`、`Agents`）把底座连历史拆出去，所以现在不拆也随时能拆。

## 3. 命令行

对用户没有变化：两个 App 各自保留命令和语法（`apple-notes-mcp notes search …`、`apple-reminders-mcp reminders find …`、`skill`、`agents …`、`--self-check`），没有新的总命令。按第一个词分发模式的逻辑两边今天一样，搬进 `AppMain`；各 App 多出来的词（Reminders 的 `setup` 别名 `authorize`，Notes 0.3.0 的 `--copy-note`、`--check-markdown`）由组件的 `privateModes` 声明，拼法和行为不变。

`AppCore/CLI` 的通用机制取两边现有代码的并集，两边的路由表原样搬进各自组件：

| 项目 | Notes 有 | Reminders 有 | 合并后 |
|---|---|---|---|
| `Route` 字段 | `stdin`（值为 `-` 的字段从标准输入读，给多行 Markdown）、`fallback`（一个筛选都没给时补字段：`notes list` 默认按修改时间列笔记） | `clears`（创建时不给 `--no-` 清空）、描述里「 for create; 」的拆分 | 全部保留，都是可选字段，默认值让另一边的行为不变 |
| 回答里的非文本内容 | 图片、音频、文件都存到 `--output-dir`（默认临时目录），每个打印一行 `Saved to` | `read_image` 把一张图片存到 `--output` 指定的文件 | 由 route 声明保存方式（文件或文件夹），`execute` 一处实现 |
| 错误文案改写 | 名字带 `_` 且只对应一条 route 的工具名换成命令，外加几条固定替换（`allow_shared: true` → `--allow-shared` 等） | `fixed` 为空的 route 的工具名换成命令（默认动词换成名词），外加两条固定替换 | 规则合一：名字带 `_`、只对应一条 `fixed` 为空的 route 的工具名换成命令（是默认动词时换成名词）；两边的固定替换留在各自组件的 `rewordings` |
| 技能的命令参考 | 列出每条命令的可选参数 | 另外让 `update` 只列 `create` 没有的参数，并列出可清空的字段 | 保留 Reminders 的逻辑，对没有 `update` 的组件不起作用 |

合一后的改写规则和并集后的 `Route` 都要让两个 App 的 `help`、各命令的 `--help`、`skill` 输出与重构前逐字相同，用黄金输出检查。

## 4. Agents 库参数化

| 文件 | 改动 |
|---|---|
| `Installation.swift` | 去掉 `bundleID`/`packageID`/`caskName` 三个静态常量和两个 App 路径字面量，改由 `Product` 推出；`detect(product:)` |
| `Registration.swift` | `serverName` 改由 `Product.serverName` 给；`ConfigTarget` 的读写函数多一个 `product` 参数 |
| `Agent.swift` | `setUp`、`register` 多一个 `product` 参数；grok-bot 的说明改成与产品无关（「…没法启动这台 Mac 上的服务器」） |
| `ConfigFile.swift` | `public static var backupSuffix`，`AppMain` 启动时设成 `product.command`，`.bak-<yyyyMMdd>-<suffix>` 与今天相同 |
| `Shell.swift` | 登录环境探测标记和 `relaunchVariables` 由 `product.environmentPrefix` 推出 |
| `Skills.swift` | 技能名 = `product.serverName`，marker = `generated-by: <product.command>`，与今天字节相同 |

因为填进去的值都和今天一样，用户已有的 agent 注册和技能在新版本里仍显示「已配置」，不需要任何兼容代码。测试夹具（`RegistrationTests`、`SkillTests`、`ConfigTextTests`）改用一个测试用 `Product`，两份几乎相同的测试只留一份。

**阶段 1 实际的做法（2026-10-27）**：不是给每个函数加 `product` 参数，而是 `Agents` 里一个 `Product.current`（`Sources/Agents/Product.swift`，用 `Mutex` 保护），每个 App 在 `main.swift` 第一行设好，测试在每个 suite 的 `init()` 里设成测试用的值。上表里的常量（`Installation.bundleID`、`Registration.serverName`、`SkillTarget.name`/`marker` 等）都改成读它的计算属性，所以 `Agents` 的公开接口和两个 App 的代码几乎不用改；两个 App 的代码阶段 2 才进 `AppCore`，那时再按上表改成参数也不迟。`Product` 还多了 `subject`/`chineseSubject`（「Notes」/「备忘录」），让 grok-bot 的说明文字与今天逐字相同，而不是改成与产品无关的说法。

## 5. 设置窗口

两个 App 仍各有自己的窗口，样子与今天相同：三个标签页，AI 助手、工具、通用。

- 窗口、菜单（含「退出」）、语言、AI 助手页、工具页进 `AppCore`，标题与文案里的产品名来自 `Product`，工具的中文标题来自 `chineseToolTitles`。
- 「通用」页：语言选择由底座渲染，权限与设置部分是组件的 `generalSection`——Notes 是完全磁盘访问与自动化，Reminders 是提醒事项、可选的完全磁盘访问和重复提醒开关，代码从两边现在的 `SettingsPanel` 原样搬过去。
- 仍用普通 `ObservableObject` 与 `Binding`（Command Line Tools 没有 SwiftUI 宏插件）。
- 验证：两个 App、中英两种语言、三个标签页，重构前后各截一张图对比（阶段 2）。

## 6. 迁移

用户这边没有迁移：bundle id、支持目录、defaults、`tools.json`、技能、agent 配置、cask 名和命令都不变，升级就是普通的 `brew upgrade` 或重装 pkg。

只有仓库搬家要处理：

- 两个 cask 的 `url`、`homepage`、`livecheck` 改到新仓库与带前缀的 tag（第 7 节）；Reminders 的旧下载地址靠改名重定向，Notes 的旧 release 留在归档的 `apple-notes-mcp` 里照常可下载。
- `release.sh`、`update-cask.sh` 里的仓库名与 tag 改掉；两个 README 里的 `gh release download` 示例改成新仓库和新 tag。
- `apple-notes-mcp` 仓库：在新仓库第一次发 Notes 之后，一个提交删掉所有文件（源码、`docs/`、`scripts/`、`Resources/`、`CHANGELOG.md`、`.github/`、两个 README），只留一个新的 `README.md`，然后归档（2026-10-27 定）。这个 README 中英各一段，说清：代码、历史和之后的版本都在 `github.com/xiaofeng-han/apple-mcp`，文档在那里的 `docs/notes.md`；安装方式不变（`brew install --cask xiaofeng-han/tap/apple-notes-mcp`，cask 会自动指到新仓库的包）；0.1.0 到 0.3.0 的包仍在本仓库的 Releases 里，tag 也在；想看旧代码用 `git checkout v0.3.0`。tag 和 release 不删。

## 7. 构建、发布与 Homebrew

- **脚本**：`scripts/build-app.sh notes|reminders`、`build-pkg.sh`、`update-cask.sh` 同样带 App 参数，按它选 `Resources/<app>/`、bundle id、可执行文件、entitlements、pkg id、cask 文件。版本号仍在各自的 `Resources/<app>/Info.plist`（`CFBundleShortVersionString`）。
- **发版**：用 Notes 现有的 `scripts/release.sh`，加 App 参数：`scripts/release.sh notes 0.4.0`（先 `--dry-run`）。它今天写死的 `APP`、`TITLE`、`REPO`、`CASK` 四个常量按 App 选；tag 从 `v<版本>` 改成 `notes-v<版本>` / `reminders-v<版本>`（检查 tag 是否已存在、`gh release create --verify-tag`、`update-cask.sh` 里 `gh release view` 的 tag 一起改）；`REPO` 改成 `xiaofeng-han/apple-mcp`；它用 `sed` 改安装命令里版本号的文件从 README 改成 `docs/<app>.md`（+ `.zh-CN`），模式按新 tag 写；release 说明取自 `CHANGELOG-<app>.md` 的 `## <版本>` 一节（没有这一节脚本就停下，所以 Notes 的 `CHANGELOG` 要先补上 0.3.0），说明模板里的权限和安装命令那段按 App 选。标题仍是「Apple Notes MCP 0.4.0」这样。只改了一个 App 就只发它；改了底座的提交，两套 e2e 都要过，发版仍按需要逐个发。
- **CI**：Notes 的 `.github/workflows/check.yml` 搬到新仓库，不用改：一个 package，`swift build` 和 `swift test` 一次覆盖两个 App 和所有共用测试。它不跑 e2e（要真实数据和权限），所以阶段 1、2 的编译与单测由 CI 把关，e2e 和黄金输出在本机跑。
- **cask**（`homebrew-tap`，token 不变）：

  ```ruby
  cask "apple-notes-mcp" do
    version "0.4.0"
    sha256 "…"
    url "https://github.com/xiaofeng-han/apple-mcp/releases/download/notes-v#{version}/AppleNotesMCP-#{version}.pkg"
    homepage "https://github.com/xiaofeng-han/apple-mcp/blob/main/docs/notes.md"
    livecheck do
      url "https://github.com/xiaofeng-han/apple-mcp"
      regex(/^notes-v?(\d+(?:\.\d+)+)$/i)
      strategy :github_releases
    end
    # 其余（name、desc、depends_on、pkg、command_wrapper、uninstall、zap、caveats）不变
  end
  ```

  Reminders 的 cask 同理，前缀 `reminders-v`。发布前把 tap 以本地目录 `brew tap` 进来，跑 `brew audit --cask --strict`、`brew style`、`brew livecheck --cask apple-notes-mcp apple-reminders-mcp`，再装一遍两个 cask。
- **文档**：根目录 `README.md`/`README.zh-CN.md` 讲仓库与两个 App 的关系和安装；`docs/notes.md`、`docs/reminders.md`（+ `.zh-CN`）是两个 App 现在 README 的全文。README 里的 release 链接指向按前缀筛选的 tag 列表，不指向「Latest」。

## 8. 测试

- **`swift test`**：
  - `AgentsTests`、`WireTests`、`NoteModelTests`：现有测试，夹具改用测试用 `Product`。
  - `AppCoreTests`：模式分发（只看第一个词，含组件的 `privateModes`）；`Route` 的 `stdin`、`fallback`、`clears`；合一后的改写规则；`Commands.tree/help` 用注入的路由表；`Skill.text` 的命令参考（含 `update` 的那段逻辑）；`Settings` 在临时 `HOME` 下的路径与环境变量覆盖。
  - `NotesComponentTests`、`RemindersComponentTests`（`@MainActor`，用临时 `ComponentContext` 调 `makeTools`）：每条 route 和每个中文标题都指向真实存在的工具；工具名唯一；`Service` 的 `tools/list` 恰好是这个 App 的工具。
- **黄金输出**：阶段 0 在两个旧仓库最后发版的提交上（Notes `v0.3.0` = `4e2c38e`、Reminders `v0.3.0` = `8038474`）录下每个 App 的 `help`、每条命令的 `--help`、`skill`（固定的可执行文件路径）、`agents list` 与 `agents set-up --all` 写出的配置（临时 `HOME`）、`--self-check`（去掉随机器变的行）、`initialize` 与 `tools/list` 的 JSON。之后每个阶段重跑，必须逐字相同；这是「用户看不到变化」的证据。
- **e2e**：`scripts/e2e.py notes|reminders [可执行文件]` 分发到 `scripts/e2e/{harness,notes,reminders}.py`。harness 启动 `[APP, "--stdio"]`，设 `<PREFIX>_WRITE_GUARD` 与 `_TOOLS_FILE`，提供 `rpc/notify/call/check`、`cli(…)`，以及 `tools.json` 变更通知检查和无状态协议检查（两个 `e2e.py` 现在各有一份几乎逐行相同的，合并后只写一份，参数是 App 的工具表和只读工具名）。`notes.py` 是 Notes 现在的检查（145 项），`reminders.py` 是 Reminders 现在的检查（167 项）；去掉共用部分后两边的项数会少一些，总数按实跑结果写进文档。

## 9. 分阶段实施

搬家前的两次发版已经做完（Notes 0.3.0、Reminders 0.3.0，见「已定决策」）。每一阶段都能独立验证；每个阶段以 PR 合入，`check.yml` 在 CI 上跑 `swift build`、`swift test`，e2e 与黄金输出在本机跑。阶段 4 之前不从新仓库发版。

| 阶段 | 内容 | 验证 |
|---|---|---|
| 0 仓库与基准 | GitHub 改名 `apple-reminders-mcp` → `apple-mcp`；并入 Notes 历史，文件先放在 `incoming/notes/`，仍能单独构建（见附录）；在 Notes `v0.3.0`（`4e2c38e`）、Reminders `v0.3.0`（`8038474`）上录下黄金输出；`check.yml` 随 Notes 一起进来 | 两边仍能各自 `swift build`、跑 e2e；旧地址重定向；CI 跑起来 |
| 1 共享 target | 一个 `Package.swift`：`Wire`（取 Notes 版）、`Launcher`、`Agents`（按第 4 节参数化）共用；两个可执行文件暂时各自保留自己的 `App/`、`CLI/`，传入自己的 `Product` | `swift test`；两套 e2e；黄金输出逐字相同 |
| 2 AppCore 与组件 | 命令行机制取并集、设置窗口、`AgentsCommand`、`AppMain`（RunLoop）、`Permission` 进 `AppCore`；产品代码变成 `NotesComponent`、`RemindersComponent`；`main.swift` 只剩一行 | `AppCoreTests` 与两个组件测试；两套 e2e（Reminders 第一次在 RunLoop 下跑）；黄金输出逐字相同；两个设置窗口中英文截图与重构前对比 |
| 3 构建与发布 | 脚本带 App 参数（`release.sh` 也是，tag 带前缀）、两份 CHANGELOG、`Resources/<app>/`、cask 的 `url`/`homepage`/`livecheck`、README 拆分 | 两个 pkg 都能建；`release.sh --dry-run` 两个 App 都过；本地 tap 装两个 cask；`brew audit --cask --strict`、`brew livecheck`；现有 agent 配置仍显示「已配置」 |
| 4 发版 | 从新仓库用 `release.sh` 分别发 Notes、Reminders 0.3.0 之后的下一个版本（`notes-v0.4.0`、`reminders-v0.4.0`），它顺带更新两个 cask；`apple-notes-mcp` 清空到只剩一个指向新仓库的 `README.md`，然后归档 | 两个 cask 都能 `brew upgrade`；旧 release 链接仍能下载；旧仓库首页只剩那一页说明 |

### 阶段 0 的进度（2026-10-27，改名后更新）

| 步骤 | 状态 |
|---|---|
| 并入 Notes 历史 | **已做**，在 `apple-mcp`（原 `apple-reminders-mcp`）的分支 `claude/merge-notes-reminders-mcp-bc72bx` 上，还没合入 `main`。并入的是 `apple-notes-mcp` 里放这份方案的分支（`340668f`），它包含 Notes `main` 的全部提交（`4b279db`，0.3.0），所以方案文件连同历史一起进来了。合并后 `incoming/notes/` 与那个分支逐字节相同，`incoming/` 以外的文件除下面三项外没动 |
| 方案与 CI 移到仓库根目录 | **已做**：`docs/MERGE-PLAN.md`（本文件）；`.github/workflows/check.yml` 改成矩阵，在 macOS runner 上分别对根目录（Reminders）和 `incoming/notes`（Notes）跑 `swift build`、`swift test` 和黄金输出比对。它只在 PR 和 `main` 的推送上跑 |
| README 说明 | **已做**：两个 README 开头加了一段，说明仓库正在变成 `apple-mcp`、Notes 暂在 `incoming/notes/`、对用户没有变化 |
| GitHub 上改名为 `apple-mcp` | **已做**（仓库主人在网页上改的）。已验证：旧的 git 地址、仓库页面和 release 下载地址（`…/apple-reminders-mcp/releases/download/v0.3.0/AppleRemindersMCP-0.3.0.pkg`）都 301 到 `apple-mcp`，下载得到完整的包。两个 cask 的 `url` 暂时靠这个重定向，阶段 3 改成新地址 |
| 录黄金输出 | **已做，由 CI 录**：`scripts/golden.py` 录下第 8 节列的输出里与机器无关的部分（`help`、每条命令的 `--help`、`call` 与每个工具的 `call TOOL --help`、`skill`、两种协议下的 `initialize`/`server/discover`/`tools/list`、`agents list` 与 `agents set-up` 对假的 Codex CLI、Grok Build、Antigravity CLI 命令写出的配置和技能）。它用临时 HOME、固定时区和语言、不存在的 `tools.json`，不需要权限，裸构建就能跑。`--self-check` 和真实 agent 因机器而异，没录。分支上的代码与 Notes `v0.3.0`、Reminders `v0.3.0` 逐字相同（已核对），所以在分支上录的就是这两个版本的输出。CI 第一次跑时把录到的内容打进日志，提交到 `Tests/Golden/<app>/`；之后每个 PR 都逐字比对 |
| 两边各自构建、跑 e2e | CI 在 macOS runner 上对两个包分别跑 `swift build`、`swift test` 和黄金输出比对。e2e 要真实数据和权限，**仍要在 Mac 上手动跑一次**：`python3 -I scripts/e2e.py .build/debug/AppleRemindersMCP`，以及在 `incoming/notes/` 里 `python3 -I scripts/e2e.py .build/debug/AppleNotesMCP` |

搬家期间要知道的两件事：

- **Notes 仍从 `apple-notes-mcp` 发版，直到阶段 4。** `incoming/notes/scripts/release.sh` 在新仓库里跑不通：它默认的 tap 路径（`../homebrew-tap`）会落到 `incoming/homebrew-tap`，它把 tag 推到当前仓库、却在 `REPO=xiaofeng-han/apple-notes-mcp` 上建 release，`--verify-tag` 会失败。阶段 3 改脚本时一并解决。Reminders 一直照常从本仓库发版（它没有 `release.sh`，按 README 的步骤）。
- **看 Notes 文件的历史**：`git blame incoming/notes/…` 能追到原来的 Notes 提交；`git log --follow` 追不过合并处的路径前缀。要看某个 Notes 文件在合并前的提交，用合并提交的第二个父提交和原路径：`git log <合并提交>^2 -- Sources/NoteModel/Markdown.swift`。这是保留原提交 ID 的代价（方案里引用了 Notes 的提交 ID，比如 `cf9f09a`），没有改写历史。

### 阶段 1 的进度（2026-10-27）

| 步骤 | 状态 |
|---|---|
| 一个 `Package.swift` | **已做**：根目录的 package（名为 `AppleMCP`）出两个可执行文件 `AppleNotesMCP`、`AppleRemindersMCP`；`incoming/notes/Package.swift` 删除，Notes 的 `Sources/{AppleNotesMCP,NoteModel,NotesShim}` 和 `Tests/NoteModelTests` 移到根目录 |
| 共用 `Wire`、`Launcher` | **已做**：`Wire` 取 Notes 版（多 `Content.audio`、`.file`），Reminders 的命令行补上这两种内容（它的工具从不返回）；`StdioServer.run` 改为由 App 传入日志变量名（`APPLE_NOTES_MCP_WIRE_LOG` 等），stderr 前缀取服务名；`Launcher.h` 的注释改成与产品无关 |
| `Agents` 参数化 | **已做**，见第 4 节末尾 |
| 共享测试只留一份 | **已做**：`AgentsTests`、`WireTests` 只留一份，`TestProduct.swift` 提供测试用的 `Product` |
| CI | **已做**：一个 job 构建一次，比对两个 App 的黄金输出，再并行跑全部测试（限时 10 分钟，输出边跑边显示） |
| 并行测试卡死 | **已修**：阶段 0 发现在 3 核的 CI 机器上并行跑测试会卡死（旧 `apple-notes-mcp` 的 CI 也因此从没跑完过）。用诊断 job 逐步缩小：`NoteModelTests`、`WireTests` 并行都过，`AgentsTests` 卡住；去掉改 `HOME` 的测试仍卡，去掉 `stopsWhatRunsTooLong`、`runsWithoutATerminal` 两个启动进程的测试就全过。原因在 `Shell.runSync`：它阻塞调用方的线程等程序结束，而等程序结束（`waitpid`）的那段放在全局队列上；调用方都在协作线程池的少数几个线程上（`Shell.run`、测试），这些线程被占满时那段永远轮不到线程，调用方就一直等一个早已结束的程序。App 里设置窗口安装 agent 时也是这样调用的。改为给 `waitpid` 单开一个线程后，CI 上 `AgentsTests` 并行连跑 3 次、全部测试并行连跑 2 次都通过（95 个测试约 7 秒，逐个跑要 23 秒），于是 CI 改回并行，诊断 job 删掉 |
| Notes 的构建脚本 | `incoming/notes/scripts/build-app.sh` 改成从根目录的 package 构建；资源、其他脚本和文档阶段 3 再搬 |
| e2e | **待做，要在 Mac 上跑**：`python3 -I scripts/e2e.py .build/debug/AppleRemindersMCP`，`python3 -I incoming/notes/scripts/e2e.py .build/debug/AppleNotesMCP`（都在仓库根目录 `swift build` 之后） |

本地（Linux 容器）只能用 `swiftc -parse` 做语法检查，编译和测试靠 CI。

### 阶段 2 的进度（2026-10-27）

| 步骤 | 状态 |
|---|---|
| `AppCore` | **已做**：`AppMain`（按第一个词分发模式、relaunch、RunLoop 版 `runThenExit`、`--self-check` 与 `--version` 的共用部分）、`Component` 协议、`AppSettings`（支持目录、`tools.json`、语言；不叫 `Settings`，因为 SwiftUI 也有一个）、命令行（`Route`、`CLI`、`Commands`、`Skill`）、设置窗口（窗口与菜单、AI 助手页、工具页、语言）、`AgentsCommand` |
| 命令行取并集 | **已做**：`Route` 有了 `stdin`、`fallback`、`clears` 和 `output`（保存到哪里的那个 flag）。各 App 的措辞放在 `CLI` 里：`setup` 那一行、`--no-NAME` 是否也清空字段、「answer」还是「JSON answer」、「Every … command」里的名词、保存方式（Notes 把图片、音频、文件都存进一个文件夹，Reminders 只把图片存成一个文件）。还有一处方案没写到：技能里是否列出必填的 flag（Notes 不列，Reminders 列并标 `(required)`），由 `skillListsRequired` 决定。改写规则合一（第 3 节），对两边的路由表，结果和原来一样 |
| 两个组件 | **已做**：`NotesComponent`、`RemindersComponent` 是库 target，各自的 `Store`、`Tools`、路由表、技能正文、「通用」页的权限与设置都在里面；两个 `main.swift` 都只剩 `AppMain.run(…Component.self)` |
| 与第 2.2 节的差异 | ① `AppMain.run` 接收组件的类型，而不是值，这样在组件建 store 之前 `Product.current` 已经设好；`ComponentContext` 只剩 `version` 和 `writeGuard`，支持目录和 `tools.json` 由 `AppSettings` 按 `Product.current` 给出。② `Permission` 没有抽进 `AppCore`：完全磁盘访问的探测和自动化只有 Notes 在用；Reminders 的「可选完全磁盘访问」看的是能不能读它自己的数据库。两者都留在各自的组件里，等第三个 App 需要时再抽。改 Notes 的探测方式会改变它的行为，而阶段 2 不改行为。③ 去掉了 `opensSettingsOnMissingPermission`：两个 App 的服务器今天都不会打开设置窗口。④ 组件的静态部分（`product`、`cli`、中文标题、技能正文）是 `nonisolated` 的，技能文本在哪个线程都能生成，所以 `agents` 命令仍和以前一样不在主线程上跑 |
| 用户看得到的变化 | 只有一处：Notes 工具页里的 `manage_tag` 以前没有中文标题，中文界面显示的是英文，现在补上「重命名或删除标签」，新测试保证每个工具都有中文标题。其余（`help`、技能、MCP、`agents` 的输出）由黄金输出逐字比对 |
| Reminders 改在 RunLoop 下跑 | **已改**（R2）：服务器、命令行和 `--self-check` 都经过 `runThenExit`；要在 Mac 上跑 e2e 确认 |
| 测试 | **已加**。`AppCoreTests`：模式分发、改写规则、`clears`、命令树的措辞、技能的 frontmatter、正文和必填 flag。`NotesComponentTests`、`RemindersComponentTests`：工具名不重复；每条命令都指向真实的工具，而且只用它的字段；每个工具都有中文标题；默认动词都有对应的命令；身份字串正确 |
| 设置窗口截图对比 | **待做，要在 Mac 上**：两个 App、中英文、三个标签页 |
| e2e | **待做，要在 Mac 上**（命令同阶段 1） |
| 阶段 2 合入 | **已合入**（PR #6，2026-10-27）。CI 修了三轮，都是测试：新测试里两处 `#expect` 写法编译不过，一处断言写错（技能文本一直以一个换行结尾）；原有的 `FileWatchTests.letsASaveInPlaceSettle` 在更多测试并行时，测试里 3 ms 的 `Task.sleep` 被拖过了文件监视的 50 ms，改成 `usleep` |

### 阶段 3 的进度（2026-10-27）

| 步骤 | 状态 |
|---|---|
| `incoming/notes/` 清空 | **已做**：资源到 `Resources/Notes/`，Reminders 的资源到 `Resources/Reminders/`；`RE-FINDINGS.md` 到 `docs/`；`compose-icon.swift`、`pbshape.py`、`release.sh` 到 `scripts/`；`incoming/` 删除 |
| 脚本带 App 参数 | **已做**：`build-app.sh`、`build-pkg.sh`、`build-icon.sh`、`update-cask.sh` 和 `release.sh` 都多了第一个参数 `notes` 或 `reminders`，两个 App 不同的地方（可执行文件、标题、bundle id、cask、资源目录、tag 前缀、文档、CHANGELOG、权限说明）只写在 `scripts/app.sh` 一处。两边的 `build-*.sh` 原本只差这些，合成一份；生成的 `distribution.xml` 与原来逐字相同（已对比 Reminders 的） |
| `release.sh` | **已改**：`scripts/release.sh [--dry-run] notes\|reminders <版本>`；tag 是 `notes-v<版本>`、`reminders-v<版本>`；release 建在 `xiaofeng-han/apple-mcp`；改版本号的是 `Resources/<App>/Info.plist` 和 `docs/<app>.md`（+ `.zh-CN`）里的安装命令，并把下载命令里的旧 tag 和旧仓库、Releases 链接一起换成新的（在本机用 GNU sed 对四份文档演练过替换结果）；说明取自 `CHANGELOG-<app>.md`；说明模板里的权限、cask、下载命令按 App 填 |
| cask | **`update-cask.sh` 已改，tap 还没动**：除了版本和校验和，它还把 `url` 改到 `apple-mcp` 的 `<前缀>-v#{version}`，`homepage` 改到 `docs/<app>.md`，`livecheck` 改成 `url "https://github.com/xiaofeng-han/apple-mcp"`、`strategy :github_releases` 和只认本 App 前缀的 `regex`（`scripts/cask.awk`，用 tap 里现有的两个 cask 演练过）。tap 现在不能先改：新地址要等阶段 4 发出第一个带前缀的 release 才存在，所以由那次发版的 `update-cask.sh` 一并改掉 |
| 两份 CHANGELOG | **已做**：`CHANGELOG-notes.md`（原 Notes 的，补上了 0.3.0 一节，取自 GitHub release 说明）、`CHANGELOG-reminders.md`（新建，放了 0.3.0 一节） |
| 文档拆分 | **已做**：两个 App 原来的 README 成了 `docs/notes.md`、`docs/reminders.md`（+ `.zh-CN`），开头写明属于本仓库，构建、发版、图标、测试的命令都带上 App 参数，互相引用改成仓库内链接；根目录 `README.md`/`README.zh-CN.md` 改写成仓库总览：两个 App、安装、搬家说明、目录、构建与测试 |
| e2e | `scripts/e2e.py notes\|reminders [可执行文件]` 转给 `scripts/e2e/notes.py`、`scripts/e2e/reminders.py`（两边原来的 `e2e.py`，内容未改）。第 8 节说的把两份共用的 harness 合成一份，**没有做**：它们只能在 Mac 上跑，在这里改了没法验证，留到能在 Mac 上一起验证时 |
| 验证 | **待做，要在 Mac 上**：`scripts/build-pkg.sh notes` 和 `reminders` 都能建；`scripts/release.sh --dry-run notes 0.4.0`、`… reminders 0.4.0` 都能走完（`CHANGELOG` 里还没有 0.4.0 一节，演练会提示，正式发版会停下）；`brew audit --cask --strict`、`brew livecheck` 在阶段 4 改了 cask 之后跑 |

### 阶段 4 的准备（2026-10-27）

阶段 3 已合入（PR #7）。发版要用签名证书、`gh` 和 tap 的本地副本，只能在 Mac 上做；这里能准备的都已备好：

| 准备 | 状态 |
|---|---|
| 0.4.0 的发布说明 | **已写**：`CHANGELOG-notes.md`、`CHANGELOG-reminders.md` 的 `## 0.4.0`。内容是搬家（命令、cask、权限、设置、已配置的 agent 都不变，`brew upgrade` 自动改从新仓库下载）、Notes 工具页补上 `manage_tag` 的中文标题，以及阶段 1 修掉的 `Shell.runSync` 卡死（设置窗口配置、安装 agent 时可能一直等一个早已结束的程序）。在本机用 `release.sh` 自己的 awk 取过这两节，英文、中文两部分都能分开。发版前请再读一遍措辞 |
| tap 的 README | 链接还指向 `apple-reminders-mcp`、`apple-notes-mcp` 和旧 README 的锚点，维护说明还是旧脚本；在 `homebrew-tap` 另开 PR 改 |
| `apple-notes-mcp` 只留说明 | 在 `apple-notes-mcp` 开草稿 PR：删掉其余文件，只留一个中英文的 `README.md`（第 6 节）。**要等 Notes 0.4.0 从新仓库发出后再合并**，然后在 GitHub 上把仓库归档 |

在 Mac 上依次做（每一步都可以停下）：

1. `git pull`，`scripts/build-app.sh notes`、`scripts/build-app.sh reminders`，用 `dist/` 里的 App 包跑两套 e2e：`/usr/bin/python3 -I scripts/e2e.py notes dist/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP`、`… reminders dist/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP`（裸的 `.build/debug` 构建只有终端的权限，2026-10-27 第一次跑时就因此缺了提醒事项权限）；打开两个 App 的设置窗口（`--settings`），中英文看一遍三个标签页。
2. 演练：`scripts/release.sh --dry-run notes 0.4.0`、`scripts/release.sh --dry-run reminders 0.4.0`。看 `dist/release-notes-<app>-0.4.0.md`。
3. 发版：`scripts/release.sh notes 0.4.0`，再 `scripts/release.sh reminders 0.4.0`。每次都会打 tag、发 release，并用 `update-cask.sh` 把 cask 的 `url`、`homepage`、`livecheck` 第一次改到新仓库。
4. 验证 cask：`brew update && brew upgrade --cask apple-notes-mcp apple-reminders-mcp`；`brew audit --cask --strict --online xiaofeng-han/tap/apple-notes-mcp`（reminders 同理）；`brew livecheck --cask xiaofeng-han/tap/apple-notes-mcp xiaofeng-han/tap/apple-reminders-mcp` 应各自只认自己前缀的 tag。现有 agent 的配置在设置窗口里仍显示「已配置」。
5. 合并 `homebrew-tap` 的 README PR 和 `apple-notes-mcp` 的说明 PR，再把 `apple-notes-mcp` 归档（Settings → General → Archive this repository）。
6. 可选：`apple-mcp` 仓库的描述现在还是「MCP server for Apple Reminders on macOS via ReminderKit…」，可以改成两个 App 的说法。

### 阶段 4 的结果（2026-10-27）

在 Mac 上（macOS 27.0.1）做完，阶段 4 完成，搬家结束。

| 步骤 | 结果 |
|---|---|
| 发版前 | 两个设置窗口中英文三个标签页由仓库主人看过；`release.sh --dry-run` 两个 App 都走完；包里 App 的签名要求、entitlements、Info.plist（除版本）与已装的 0.3.0 逐项相同，所以权限保留 |
| Notes 0.4.0 | `notes-v0.4.0`（发版提交 `505a691`，tap `a801b7d`）。`release.sh` 在推送时停下：本地副本的 `origin` 是 HTTPS，git 没有可用的凭据，而 SSH 可用。照脚本的提示手动做完（推送、draft、核对 GitHub 上包的 sha256、发布、`update-cask.sh`），之后 `origin` 改成 SSH |
| Reminders 0.4.0 | `reminders-v0.4.0`（`a4df837`，tap `cd4a816`），`release.sh` 一次走完 |
| Notes 0.4.1 | `notes-v0.4.1`（`338b3b6`，tap `93f3fe2`），带上 `--list-json`：外部贡献 `apple-notes-mcp#5`，移植进 `NotesComponent`（#12，第一个提交保留原作者），补了 `ListJSON` 的单元测试（行、区域、函数覆盖率 100%，15 处变异都能抓到）和 2 项 e2e（Notes e2e 共 147 项）。测试中发现并修掉：备忘录用 U+2028 做段内换行，`JSONEncoder` 不转义它，按它断行的读取方会把一行切成两行，现在 U+2028、U+2029、NEL 都转义；只有空格的查询改为列出全部笔记 |
| `main` 的保护 | 规则里有 update，发版提交和 PR 合并都是仓库主人身份绕过规则（`--admin`） |
| cask | `update-cask.sh` 第一次把两个 cask 的 `url`、`homepage`、`livecheck` 改到 `apple-mcp`。`brew audit --cask --strict --online` 两个都过；`brew livecheck` 各自只匹配到自己前缀的 tag（`--debug` 里 Matched Versions 各一个，旧的 `v0.3.0` 不匹配） |
| 本机升级 | `brew upgrade --cask apple-notes-mcp apple-reminders-mcp`：Notes 0.3.0 → 0.4.1，Reminders 0.3.0 → 0.4.0。签名证书不变，`--self-check` 显示完全磁盘访问、自动化、提醒事项权限都还在；`agents list` 里原来已配置的 agent 仍是「set up」 |
| 旧 release 链接 | `apple-notes-mcp` 与 `apple-reminders-mcp` 的 `v0.3.0` 包地址都还能下载（200） |
| 收尾 | `homebrew-tap#1` 合并；`apple-notes-mcp#5` 留言后合并（内容已在 #12）；`apple-notes-mcp#6` 并入 `main` 后解决冲突（保留删除）再合并，仓库只剩 README，描述改为指向 `apple-mcp`，已归档；`apple-mcp#3`（被 `release.sh` 取代）关闭；`apple-mcp` 的描述改为两个 App 的说法 |
| 本机清理 | 删掉 `~/Applications/AppleRemindersMCP-dev.app`（0.2.4，移到废纸篓）、`~/` 卷上两条已无对应 App 的安装记录、`dist/` 里的构建；OpenCode 的 `apple-reminders` 原本指向已不存在的 `apple-reminders-mcp/dist/…`，用 `apple-reminders-mcp agents set-up opencode` 改回 Homebrew 的命令 |

留给以后：

- 两份 e2e 共用的 harness 仍各写一份（第 8 节），没合并。
- `Sources/NotesComponent/Store/Organizer.swift:310` 那条多余 `?? 1` 的编译警告还在。
- 一次 e2e 因 U+2028 中途崩掉、没走到清理，留下了「agent test」文件夹；下一次运行开头的清理把它删掉了。中途崩掉的检查不会自己清理，这是现有的设计。

## 10. 风险与待定

- **R1 用户可见文字漂移**：把代码搬进底座时，`help`、技能、写进 agent 的配置只要差一个字，已配置的 agent 和技能就会显示「更新」。缓解：黄金输出逐字比对，每个阶段都跑。
- **R2 Reminders 改在 RunLoop 下跑**：服务器和命令行都要在真机上过一遍 `e2e.py reminders`（阶段 2）。
- **R3 一个仓库发两个产品**：GitHub 的「Latest」在两个 App 之间跳；`livecheck` 要按 tag 前缀；release 列表混在一起。缓解见第 7 节，发布前用本地 tap 验证。
- **R4 改底座要两个 App 一起验证**：每个改到底座的提交都要跑两套 e2e；某个 App 的发版会带上另一个 App 还没发的底座改动，各自从一个提交构建即可。
- **R5 以后若要合成一个 App**：那仍是单向门（新 bundle id、重授权限、cask 改名），初稿里的设计（左栏切换 App、苹果加机器人的图标、`apple-mcp` 命令、1.0.0）留作那时的参考，见第 11 节。那时还要处理两个 App 都有的 `manage_tag`：一个服务器里工具名不能重。
- **待定**：无。
- **已定并已执行（原待定）**：命令行、技能和工具标签页先从两个旧仓库各发一次，再开始搬家（2026-10-21 定）；已发 Notes 0.2.0（10-21）、0.3.0（10-22）和 Reminders 0.3.0（10-21）。原先「不单独发版」是为了避免合并时多一次升级和迁移，本方案没有合并也没有迁移，这个理由不在了；之后的底座重构用户看不出来。

## 11. 初稿与当天决定的适用情况

| 决定 | 出处 | 在本方案里 |
|---|---|---|
| 新身份：产品 Apple MCP、`AppleMCP.app`、`com.xiaofeng.apple-mcp`、命令与 cask `apple-mcp` | 初稿 | **不适用**：两个 App 保留各自的身份 |
| 仓库：`apple-reminders-mcp` 改名 `apple-mcp`，并入 Notes 历史，Notes 仓库归档 | 初稿 | **适用**：改名后的仓库出两个 App；Notes 仓库在新仓库第一次发 Notes 之后清空到只剩一个指向新仓库的 README，再归档（10-27 定） |
| 服务器按组件分开注册：`apple-notes`、`apple-reminders` | 初稿 | **适用**，而且就是今天的样子 |
| 旧命令名靠 Homebrew 包装脚本保留 | 初稿 | **不需要**：没有改名，两个 cask 照旧装自己的命令 |
| `Component` 协议，每个组件一个独立 target | 初稿 | **适用，简化**：每个 App 一个组件；去掉 `Registry`、`LegacyIdentity`、组件开关、`ServerSpec` 的参数与 `wrapperRuns` |
| 主线程用 RunLoop，不用 `dispatchMain()` | 初稿 | **适用**：`AppMain` 统一用 RunLoop；Reminders 要在真机验证（R2） |
| e2e 拆成 harness + 各 App 的检查 | 初稿 | **适用**（第 8 节） |
| 数据、defaults、环境变量迁移；权限重授；旧 App 清理；cask 二合一 | 初稿 | **不适用**：没有迁移（第 6 节） |
| Notes 也提供命令行与技能 | 10-21 | **适用**：PR #1 已实现，路由与技能正文搬进 `NotesComponent` |
| 命令行机制取两边的并集 | 10-21 重扫 | **适用**（第 3 节） |
| 合并前不单独发版，命令行等随 Apple MCP 1.0.0 发 | 10-21 | **不适用**：没有合并版。改为先从两个旧仓库各发一次，已发 Notes 0.2.0、0.3.0 和 Reminders 0.3.0，见「已定决策」 |
| 命令行不省略与组件同名的名词（`apple-mcp notes notes search`） | 10-21 | **不适用**：没有 `apple-mcp` 命令；`apple-notes-mcp notes search` 照旧 |
| 完全磁盘访问的探测读 `TCC.db` | 10-21 | **适用**：底座的 `Permission` 用它；Notes 打不开自己的数据库时照旧报自己的错误 |
| 设置窗口：左栏切换 App，右边显示所选 App 的设置 | 10-21 | **不适用**：每个 App 仍是自己的窗口和三个标签页；若以后合成一个 App，按这个布局做 |
| 新图标：苹果背景，右下角是现在的机器人头像 | 10-21 | **不适用**：两个 App 保留现在的图标；以后合成一个 App 时再用 |
| 版本从 1.0.0 开始 | 10-21 | **不适用**：各自接着自己的版本号（Notes 0.3.0 之后、Reminders 0.3.0 之后） |

## 附录：仓库操作

```sh
# 1. GitHub 上把 apple-reminders-mcp 改名为 apple-mcp（Settings → General → Repository name）。
git clone git@github.com:xiaofeng-han/apple-mcp.git && cd apple-mcp

# 2. 把 apple-notes-mcp 的历史并进来，文件先落在 incoming/notes/ 下，避免同名文件冲突。
git remote add notes git@github.com:xiaofeng-han/apple-notes-mcp.git
git fetch notes
# 实际并入的是放这份方案的分支（它包含 notes/main 的全部提交），见第 9 节「阶段 0 的进度」。
git merge --allow-unrelated-histories -s ours --no-commit notes/claude/merge-notes-reminders-mcp-bc72bx
git read-tree --prefix=incoming/notes -u notes/claude/merge-notes-reminders-mcp-bc72bx
git commit -m "Merge the history of apple-notes-mcp"
git mv incoming/notes/docs/MERGE-PLAN.md docs/MERGE-PLAN.md
git mv incoming/notes/.github/workflows/check.yml .github/workflows/check.yml   # 再改成两个包的矩阵

# 3. 录黄金输出（第 8 节），再按 2.5 的映射表 git mv 到位，按阶段 1、2 抽出底座。

# 4. 验证旧地址重定向（改名后）。
curl -sIL https://github.com/xiaofeng-han/apple-reminders-mcp/releases/download/v0.3.0/AppleRemindersMCP-0.3.0.pkg | grep -i '^location'

# 5. 新仓库第一次发 Notes 之后：apple-notes-mcp 清空到只剩一个 README.md，再归档（Settings → Archive）。
#    tag 和 release 不受影响；历史也都在 apple-mcp 里。
cd apple-notes-mcp && git checkout main && git pull
git rm -r -q .                       # 删掉所有文件（含 docs/、scripts/、Resources/、.github/、CHANGELOG.md、两个 README）
cat > README.md <<'EOF'
# Apple Notes MCP has moved

The code, its history and all releases from 0.4.0 on live in **[xiaofeng-han/apple-mcp](https://github.com/xiaofeng-han/apple-mcp)**, which builds Apple Notes MCP and Apple Reminders MCP from one shared base. Documentation: [docs/notes.md](https://github.com/xiaofeng-han/apple-mcp/blob/main/docs/notes.md).

Installing has not changed: `brew install --cask xiaofeng-han/tap/apple-notes-mcp` (the cask now points at the new repository). Releases 0.1.0 to 0.3.0 stay downloadable under [Releases](https://github.com/xiaofeng-han/apple-notes-mcp/releases); their code is at the tags (`git checkout v0.3.0`).

---

**中文**：Apple Notes MCP 的代码、历史和 0.4.0 起的版本都搬到了 [xiaofeng-han/apple-mcp](https://github.com/xiaofeng-han/apple-mcp)（一个仓库出 Apple Notes MCP 和 Apple Reminders MCP 两个 App），文档见那里的 [docs/notes.zh-CN.md](https://github.com/xiaofeng-han/apple-mcp/blob/main/docs/notes.zh-CN.md)。安装方式不变：`brew install --cask xiaofeng-han/tap/apple-notes-mcp`。0.1.0 到 0.3.0 的安装包仍在本仓库的 Releases 里，代码在对应的 tag 上。
EOF
git add README.md && git commit -m "Move to apple-mcp; keep only a pointer" && git push
# 然后在 GitHub 上：Settings → General → Archive this repository。
```
