# Apple Journal MCP

[English](journal.md) | **简体中文**

属于 [apple-mcp](../README.zh-CN.md)：Apple Journal MCP、[Apple Notes MCP](notes.zh-CN.md) 和 [Apple Reminders MCP](reminders.zh-CN.md) 的仓库。

一个 MCP 服务器，让 AI agent（Claude Code、Codex、Grok Build、OpenCode、Gemini CLI、pi 等）在 Mac 上读写苹果的「手记」App。每个工具同时是一条命令行命令，所以 agent 也可以用技能代替服务器。它的设置窗口会找出 Mac 上的 agent，一键按其中一种方式配置好。

「手记」没有 AppleScript，快捷指令也只有几个（新建手记、搜索、打开手记），所以本 App 走「手记」自己的数据模型：私有框架 JournalShared，「手记」本身、它的共享扩展和小组件都用它。读写原地针对这台 Mac 上「手记」的数据，和「手记」共享扩展写手记的方式一样，之后由「手记」自己把改动上传到 iCloud。agent 写下的就是普通的「手记」数据，每台设备上都一样：
- 手记：标题、带「手记」原生格式的正文（粗体、斜体、下划线、删除线、列表、引用）、日期、书签、所属手记本、最近删除、复制；
- 手记本：名称、颜色和图标；删除时手记可移走、保留或一起删除；
- 附件：从文件添加照片、视频和录音，也可以移除附件；各种附件都能读出详情：照片、视频、录音及其转写、地点和到访、心理状态（State of Mind）、体能训练、活动、音乐和播客、图书、联系人、链接、回顾、涂鸦里识别出的手写；
- 「手记」的分析：写手记的天数和连续纪录。

唯一需要的权限是完全磁盘访问，因为「手记」的数据放在 macOS 保护的容器里。

需要「手记」3.0（随 macOS 27.2 提供）和 Apple 芯片。本 App 通过为这个版本编写的接口调用「手记」的框架；遇到别的版本会明确说明，什么都不改（见[工作原理](#工作原理)）。代码全部为本项目编写，没有第三方依赖。

## 覆盖范围

| 「手记」 | 这里 |
|---|---|
| 写、改、排版手记（标题、正文、日期） | ✅ `create_entry`、`edit_entry`；正文用 Markdown |
| 书签 | ✅ `bookmarked` |
| 手记本：新建、改名、颜色、图标、删除（手记移走、保留或删除）、在手记本之间移动手记 | ✅ `manage_journal`、`edit_entry` 的 `journal` |
| 最近删除：删除、恢复、永久删除 | ✅ `delete_entry`、`restore_entry` |
| 复制手记 | ✅ `duplicate_entry` |
| 搜索，按手记本、书签、日期、附件种类筛选 | ✅ `find_entries` |
| 照片、视频、录音及转写、地点、心情、体能训练、音乐、图书、联系人、链接、回顾、涂鸦 | ✅ 读：`read_entry` 给出详情，`read_attachment` 打开 |
| 往手记里添加照片、视频和录音；移除附件 | ✅ `create_entry` 和 `edit_entry` 的 `attach`；`edit_entry` 的 `detach` |
| 分析：写手记天数、连续纪录 | ✅ `overview` |
| 导出 | ✅ `export_entries` 导出为带附件的 Markdown（「手记」自己的导出是只有「手记」能打开的归档） |
| 添加涂鸦、实况照片、地点、心理状态等其他种类的附件；把附件放进正文 | ❌ 见[做不到的](#做不到的) |
| 手记建议（Journaling Suggestions）、设备上生成的写作提示 | ❌ |
| 锁定手记、写手记计划及其通知、打印 | ❌ |

## 工具

| 工具 | 作用 |
|---|---|
| `overview` | 手记本（颜色、图标、手记数），手记总数、书签数和「最近删除」里的数量，以及分析：写手记的天数、今年的天数和手记数、按天和按周的连续纪录、第一条和最后一条。这些按手记的日期算出，所以可能和「手记」自己的分析不同：后者也算之后删除了的手记那些天 |
| `find_entries` | 查手记，默认最新在前（也可最旧在前或最近修改在前）：按词（标题、正文、写作提示，以及附件里的地点、人、歌曲、转写和手写）、手记本、书签、日期（`after` 含当天，`before` 不含）和附件种类；或查「最近删除」。每条带 id、version、摘要和按种类计数的附件；用 `offset` 翻页 |
| `read_entry` | 读完整手记（最多 20 条）：正文 Markdown、日期、创建和修改时间、手记本、书签、写作提示，以及每个附件的详情 |
| `read_attachment` | 打开一个附件：照片转成 JPEG，视频取一帧，录音作为音频，连同详情 |
| `create_entry` | 新建手记：标题和正文，日期为现在或 `date`，可放进手记本、加书签，可附上照片、视频和录音（`attach`） |
| `edit_entry` | 一次调用改一条：标题、正文（`body` 整篇重写，`replace` 替换 read_entry 里的原样 Markdown，`append` 加在末尾）、日期、书签、手记本（`""` 移出手记本）、附件（`attach` 添加文件，`detach` 按 id 移除附件）。只写改动的部分 |
| `delete_entry` | 把手记移到「最近删除」，「手记」保留 30 天；`permanently` 把已在那里的手记永久删除 |
| `restore_entry` | 从「最近删除」恢复 |
| `duplicate_entry` | 复制手记，连同正文、日期、手记本和附件，和「手记」的「复制」一样 |
| `manage_journal` | 新建手记本，改名称、颜色或图标，或删除：手记移到另一个手记本（`move_entries_to`）、留在「所有手记」，或一起移到「最近删除」（`delete_entries` 加 `expected_entries`，即它里面的手记数） |
| `export_entries` | 把手记导出为 Markdown 文件，每条一个，连同照片、视频和录音，放进一个新文件夹；可按手记本、书签和日期筛选 |

改手记时要传回 `read_entry` 或 `find_entries` 给出的 `version`；手记在那之后被改过（在「手记」里或其他设备上），修改会被拒绝，所以 agent 不会覆盖它没读过的内容。每次写入在「手记」把它上传到 iCloud 后回答 `"uploaded": true`，通常几秒内；「手记」没在运行时，本 App 会在后台隐藏启动它。

日期用本地时间：`2026-10-21T09:30`，或 `2026-10-21`（表示当天中午，这样在任何时区都还在那一天）。

### 手记正文

正文用 Markdown，一行一段，对应「手记」编辑器里有的：

| Markdown | 在「手记」里 |
|---|---|
| `**粗体**`、`*斜体*`、`<u>下划线</u>`、`~~删除线~~` | 相同 |
| `* 项目` 或 `- 项目`，每级缩进两个空格 | 圆点或短横列表，可嵌套 |
| `1. 项目` | 编号列表 |
| `> 文字` | 引用 |
| `# 标题` | 粗体：「手记」没有标题样式 |
| `- [ ] 项目` | 圆点项目：「手记」没有清单 |
| `[文字](网址)` | `文字 (网址)`：「手记」正文不存链接 |
| 表格 | 拒绝：「手记」没有表格 |

修改手记时只写有差别的那一段，写进「手记」自己的可合并文本，所以其余部分保留格式（颜色、对齐等 Markdown 显示不出的东西）和用于与其他设备上的修改合并的历史。放在正文里的照片、Genmoji 和后续提示读成 `![asset](attachment:ID)` 占位符，请原样保留。「手记」3.0 之前写的手记正文是 RTF，修改它们也写成 RTF。

### 附件

`read_entry` 列出手记的附件和「手记」知道的详情；`find_entries` 和 `export_entries` 可按种类筛选：

| 种类 | 详情 |
|---|---|
| `photo`、`video` | 拍摄时间和地点 |
| `audio` | 录制时间、时长、「手记」的转写 |
| `place` | 地点和到访：名称、城市、地点类型、起止时间、坐标 |
| `state_of_mind` | 瞬时情绪或每日心情、感受、描述词、相关方面 |
| `workout`、`activity` | 类型、开始、结束、时长、卡路里、距离；步数 |
| `music`、`podcast`、`book` | 标题、艺人或作者、专辑、App、播放时间 |
| `contact` | 谁、何时、多久 |
| `link`、`reflection`、`drawing`、`event` | 网址；回顾的提示；「手记」在涂鸦里识别出的手写；活动的地点和时间 |

`attach` 接受最多 20 个文件的绝对路径，每个不超过 250 MB，像「手记」的照片选择器那样排在手记正文上方已有附件的后面：

| 文件 | 存成 |
|---|---|
| macOS 能读的图片（JPEG、HEIC、PNG、TIFF、RAW 等） | 照片，和「手记」自己的一样存为不超过 600 万像素的 HEIC，日期和地点取自 Exif |
| macOS 能播放的视频（MOV、MP4、M4V） | 视频，文件原样保存，另存一张静帧供「手记」显示，连同日期和地点 |
| macOS 能播放的音频（M4A、MP3、WAV、AIFF、CAF 等） | 录音，文件原样保存，连同时长和「手记」显示的波形（用「手记」自己的代码算出） |

回答里列出每个新附件的 id。`detach` 按这些 id（来自 `read_entry`）移除附件，之后「手记」会把它们从 iCloud 和这台 Mac 上删掉。放在正文里的附件会被拒绝：只有「手记」能把它从正文里拿出来。

## 命令行

每个工具都是一条命令：`apple-journal-mcp help` 打印命令树，任何命令都可加 `--help`。

```bash
apple-journal-mcp journals list                                   # 手记本、数量和分析
apple-journal-mcp entries search "湖边"                            # 在正文、标题、地点、转写里找
apple-journal-mcp entries list --journal 旅行 --after 2026-10-01 --attachment photo
apple-journal-mcp entries read ID
apple-journal-mcp entries create - --title "美好的一天" --journal 旅行 <<'EOF'
我们走到了**灯塔**。
EOF
apple-journal-mcp entries edit ID --version VERSION --append "- 早饭前游了泳" --bookmarked
apple-journal-mcp entries edit ID --version VERSION --attach ~/Pictures/lake.heic --attach ~/Movies/swim.mov
apple-journal-mcp entries delete ID --version VERSION                # 移到「最近删除」
apple-journal-mcp journals create "感恩" --color pink --icon "🙏"
apple-journal-mcp attachments read ID --output-dir ~/Desktop        # 保存照片和录音
apple-journal-mcp entries export ~/Desktop/journal                  # 带附件的 Markdown
```

命令打印工具的 JSON 回答，有时前面有一句如 `Created.`。退出码 1 表示请求失败（没找到、读过之后被改过、不允许），原因在 stderr；2 表示命令或参数写错。每条命令也接受 `--json '{...}'`（或 `--json -` 从 stdin 读），字段名用 snake_case。

## 安装

发布版为 Apple 芯片构建。从第一个发布版起，默认用 Homebrew 安装和配置：

```bash
brew install --cask xiaofeng-han/tap/apple-journal-mcp
apple-journal-mcp setup                  # 指出在哪里给完全磁盘访问
apple-journal-mcp agents set-up --all    # 把服务器注册到这台 Mac 上的 agent
```

要给 agent 装技能而不是服务器，在最后一条命令后加 `--skill`。也可以不跑后两条命令，而是在「应用程序」里打开 Apple Journal MCP：在「AI 助手」标签页配置 agent，在「通用」里查看完全磁盘访问。不用 Homebrew 的话，从 [Releases](https://github.com/xiaofeng-han/apple-mcp/releases) 下载 `AppleJournalMCP-<版本>.pkg` 打开；只为自己安装会放到 `~/Applications`，不需要管理员密码。App 和安装包没有 Developer ID 签名；cask 会去掉隔离属性，浏览器下载的安装包要在「系统设置 → 隐私与安全性」里允许。

### 安装之后

完全磁盘访问要手动给：「系统设置 → 隐私与安全性 → 完全磁盘访问」，点 +，选 `AppleJournalMCP.app`（`setup` 和「通用」页会帮你打开这两处）。这台 Mac 上要打开过一次「手记」；要看到其他设备上的手记，「手记」在这台 Mac 上要开启 iCloud 同步。检查：

```bash
apple-journal-mcp --self-check
```

它会打印「手记」的版本和是否支持、权限、看到的手记和手记本数量，以及「手记」是否在用 iCloud 同步。

窗口的「AI 助手」标签页、「配置方式」（服务器或技能）和「工具」标签页和其他两个 App 一样，见[配置 agent](reminders.zh-CN.md)，只是命令换成 `apple-journal-mcp`，服务器名 `apple-journal`，技能 `apple-journal/SKILL.md`，工具开关文件 `~/Library/Application Support/AppleJournalMCP/tools.json`。手动注册时命令是 `/opt/homebrew/bin/apple-journal-mcp --stdio`（或 App 的可执行文件 `AppleJournalMCP.app/Contents/MacOS/AppleJournalMCP`），例如 `claude mcp add -s user apple-journal -- /opt/homebrew/bin/apple-journal-mcp --stdio`。

### 从源码构建

```bash
./scripts/build-app.sh journal
ditto dist/AppleJournalMCP.app ~/Applications/AppleJournalMCP.app
```

`./scripts/build-pkg.sh journal` 构建发布用的安装包，`scripts/release.sh journal <版本>` 发版，流程同 [Apple Reminders MCP](reminders.zh-CN.md)，发版说明来自 [`CHANGELOG-journal.md`](../CHANGELOG-journal.md)，tag 是 `journal-v<版本>`。第一次发版还需要在 [homebrew-tap](https://github.com/xiaofeng-han/homebrew-tap) 里照另外两个的样子加上 cask `Casks/apple-journal-mcp.rb`；`update-cask.sh` 只更新已有的 cask。图标源文件是 `Resources/Journal/AppIcon.icon`：先 `swift scripts/compose-icon.swift Resources/Reminders/AppIcon.icon/Assets/artwork.png Resources/Journal/AppIcon.icon/Assets/artwork.png journal`，再 `./scripts/build-icon.sh journal`。

### 为什么权限记在这个 App 名下

和其他两个 App 一样，它一启动就放弃 macOS 记在启动者名下的责任，以自己的身份重新启动自己，所以完全磁盘访问只需给「Apple Journal MCP」一次，不管哪个 agent 启动它。请用真实路径或 `exec` 它的脚本启动，不要经符号链接。

## 工作原理

- **数据。**「手记」把一切放在它的 App 组容器里的 Core Data 库 `~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite`，照片和录音在旁边的 `Attachments/`。本 App 用「手记」自己的模型和类、按「手记」打开它的方式（开启历史记录，这样「手记」能立刻知道每次保存）打开这个库，从不迁移它。
- **文本。**「手记」3.0 把手记的正文和标题、手记本的名称颜色图标存为苹果私有框架 Coherence 的可合并值（CRDT），较早的手记存为 RTF。本 App 通过「手记」自己的代码读取和修改它们。
- **同步。**「手记」的同步引擎会上传所有标记为未上传的对象。写入时像「手记」自己的编辑器那样做这个标记，然后由「手记」上传，通常几秒内完成。
- **附件。**一个附件是一个 asset（种类和用「手记」自己的类型编码的元数据）加上 `Attachments/ENTRY/ASSET/` 里的文件，用「手记」自己的排版代码放进手记的布局，这段代码也会维护「手记」3.0 之前的手记所用的旧排序字段。「手记」把文件随手记一起上传；移除附件就是把它标记为待从 iCloud 删除，之后「手记」再删掉这台 Mac 上的记录和文件。
- **接口。**JournalShared 是没有公开接口的 Swift 框架，所以 `Interfaces/Journal` 里放着为本 App 用到的部分手写的 Swift 接口，以及链接器用来代替框架的桩文件（`scripts/journal-stubs.py` 根据所在 Mac 上的符号生成）。框架是弱链接的。App 启动时检查它调用的每个函数是否都在；缺了哪个（换了 macOS 版本），每个工具都会说明，不读也不改任何东西。`--check-markdown` 读出每个手记、写成 Markdown 再解析回来，看有没有丢东西；系统更新后可以跑一下。
- **不需要「手记」的部分**单独放在 `JournalModel` 里：agent 看到的工具（名称、说明、参数）、命令、正文的 Markdown 形式、分析和附件详情。`JournalComponent` 给每个工具接上具体做法。单元测试（`JournalModelTests`）只依赖 `JournalModel`，所以既不需要手写的接口，也不需要「手记」。
- 逆向笔记见 [RE-FINDINGS-journal.md](RE-FINDINGS-journal.md)。

## 测试

```bash
/usr/bin/python3 -I scripts/e2e.py journal                              # 已安装的 App，针对你真实的手记
/usr/bin/python3 -I scripts/e2e.py journal .build/debug/AppleJournalMCP # 未打包的构建，用终端的完全磁盘访问
```

检查经 stdio 跑遍每个工具和主要命令，共 79 项。写保护（`APPLE_JOURNAL_MCP_WRITE_GUARD=agent test`）把写入限制在标题以 `agent test` 开头的手记和名称以它开头的手记本。它会建一个临时手记本和若干手记，附上它生成的照片和录音（装了 `ffmpeg` 时还有视频），检查每次改动都被「手记」上传，最后把它们全部永久删除，所以概览里的数量恢复原样；你的其他设备会看到这些测试手记出现又消失。「手记」会为每篇永久删除的手记留一条连续纪录（种类为 `streakEvent`、不属于任何手记的附件），这样删除不会打断连续纪录：跑完之后，「手记」自己的分析会把当天算作写过手记的一天。`swift test` 检查 Markdown 对应、修改范围的计算、分析、附件详情，以及命令和工具是否一致。

## 做不到的

- **添加涂鸦、实况照片、地点、心理状态、体能训练等其他种类的附件。**「手记」在自己的编辑器里用 PencilKit、照片图库和系统服务（手记建议、HealthKit）制作它们；只有照片、视频和录音来自普通文件。已有的各种附件都能完整读取。
- **把附件放进正文，或为添加的录音生成转写。**附件添加在正文上方的布局里。「手记」只转写在它自己的录音器里录的录音，不转写从文件添加的。
- **手记建议（Journaling Suggestions）。**它们来自系统服务（momentsd），只回应拥有本 App 拿不到的权限的 App。
- **设备上生成的写作提示和后续提示。**「手记」用 Apple 智能生成它们，需要只有它才有的权限。手记里已有的提示可以读取。
- **把心理状态写入「健康」。**记录心理状态需要 HealthKit 和「手记」自己的授权。手记里已有的可以读取。
- **锁定手记、写手记计划及其通知、打印。**这些是「手记」App 本身的设置和操作，不是它库里的数据。
- **「手记」自己的导出归档和导入。**`export_entries` 改为导出 Markdown。
- **其他版本的「手记」。**接口是为 macOS 27.2 上的「手记」3.0 编写的。
