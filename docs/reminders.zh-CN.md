# Apple Reminders MCP

[English](reminders.md) | **简体中文**

属于 [apple-mcp](../README.zh-CN.md) 仓库，同一仓库里还有 [Apple Notes MCP](notes.zh-CN.md)。

让 AI agent（Claude Code、Codex、Grok Build、OpenCode、Gemini CLI、pi……）完整地读写 macOS 上的「提醒事项」的 MCP 服务器。每个工具也是一条命令行命令，所以 agent 也可以不用服务器，改用技能。它的设置窗口会找出 Mac 上的 agent，用任一种方式一键配好每一个，没装的也能直接安装。

写入走苹果的私有框架 ReminderKit，和 Reminders.app 自己用的是同一条路。所以下面这些功能都是原生的，iPhone 上也显示正常：
- 提醒本身：旗标、真标签、子任务、Urgent（像闹钟一样响）、重复、提前提醒、地点和上车/下车提醒、"给某人发消息时"、链接、图片、共享清单里的指派、排列顺序；
- 清单：分区、分组、颜色和图标、置顶、购物清单、排序方式、模板、智能清单。

保存后由系统的 remindd 自动同步到 iCloud。只需要「提醒事项」这一项隐私权限。完全磁盘访问是可选的，只用来读：列出「最近删除」里的全部提醒，以及读取提醒上的图片。

需要 macOS 26 或更新版本，在 macOS 27.0.1 上开发和验证。代码全部是本项目自己写的，不依赖第三方库。

## 同类工具对比

2026-10-20 对照各项目源码和苹果官方文档逐项核实，星标数为当天数据。✅ 已核实支持 · 🟡 部分支持或变通 · ❌ 不支持 · ❓ 未核实 · — 不适用

| 工具 | 星标 | 实现方式 | 标签 | 子任务 | 分区 | 智能清单 | 位置提醒 | 紧急 | 分组/颜色 | 重复 | 指派 | 恢复删除 | 防覆盖 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **MCP 服务器** | | | | | | | | | | | | | |
| **xiaofeng-han/apple-reminders-mcp**（本项目） | 新 | ReminderKit（「提醒事项」App 自己用的私有框架） | ✅ 原生 | ✅ 原生 | ✅ | ✅ | ✅ 另有上车/下车、「给某人发消息时」 | ✅ | ✅ | ✅ | ✅ | ✅ 回到原清单 | ✅ 版本哈希 |
| [supermemoryai/apple-mcp](https://github.com/supermemoryai/apple-mcp) | 3,120 | AppleScript（`tell application "Reminders"`） | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | 224 | EventKit（Swift 命令行） | 🟡 `[#tag]` 文本写在备注里 | 🟡 备注里的文本块 | ❌ | ❌ | 🟡 只读 | ❌ | 🟡 清单颜色，只读 | 🟡 只读 | ❌ | ❌ | ❌ |
| [omarshahine/apple-pim](https://github.com/omarshahine/apple-pim) | 65 | EventKit（Swift 命令行） | ❌ | ❌ | ❌ | ❌ | ✅ 到达/离开 | ❌ | 🟡 清单颜色，只读 | ✅ | ❌ | ❌ | ❌ |
| [PsychQuant/che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) | 41 | EventKit（Swift） | 🟡 备注里的 hashtag（“MCP 层面”） | ❌ | ❌ | ❌ | ✅ | ❌ | 🟡 清单颜色，可读写 | ✅ | ❌ | 🟡 撤销时重建（是新条目） | 🟡 撤销不会覆盖用户的修改 |
| [shadowfax92/apple-reminders-mcp](https://github.com/shadowfax92/apple-reminders-mcp) | 39 | JXA，经 node-reminders（osascript） | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [dbmcco/apple-reminders-mcp](https://github.com/dbmcco/apple-reminders-mcp) | 29 | AppleScript（osascript） | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **苹果自带** | | | | | | | | | | | | | |
| Siri / Apple Intelligence | — | 系统自带语音 | ❓ | ❌ | ❓ | ❌ | ✅ “到家时提醒我” | ❓ | ❌ | ✅ | ❌ | ❌ | — |
| 快捷指令「新建提醒事项」等（iOS / macOS 27） | — | 系统自带动作 | ❓ | ❓ | 🟡 能建、删分区，不能把提醒放进分区 | ❌ | ❓ | ✅ iOS 27 | 🟡 能建、删分组（iOS 27） | ❓ | ❓ | ❌ | ❌ |

## 工具

| 工具 | 作用 |
|---|---|
| `list_lists` | 清单（未完成数、总数、默认、置顶、类型、分组、颜色、图标、排序、分区、共享清单的成员）、分组、智能清单（含筛选条件）、模板 |
| `find_reminders` | 跨清单查找：清单、智能清单（按「提醒事项」自己的算法得出其中的提醒）、分区、关键词、已完成、旗标、紧急、重复、有地点提醒、指派给谁、标签、到期时间窗口（`due_before` 不含当天）。每条提醒只出现一次，并列出显示它的智能清单 |
| `get_reminder` | 读一条提醒的全部内容：闹钟、提前提醒、图片、子任务 |
| `read_image` | 把提醒上的图片返回给模型（需要完全磁盘访问） |
| `list_tags` | 所有标签和用量 |
| `list_deleted` | 「最近删除」里能恢复的提醒 |
| `create_reminder` | 新建提醒，可设置的字段见下表 |
| `update_reminder` | 只改给出的字段，`null` 清掉；另有 `completed` 勾选、`list` 移到别的清单、`remove_images` |
| `delete_reminder` | 连同子任务移到「最近删除」 |
| `restore_reminder` | 从「最近删除」恢复（连同一起删的子任务），默认回到原清单 |
| `manage_list` | 新建；修改名字、颜色、图标、分组、置顶、类型（普通/购物）、排序方式、侧边栏位置；清除已完成；删除（还有提醒的要 `confirm_delete_reminders: true`，提醒进「最近删除」） |
| `manage_group` | 新建、改名、删除空分组 |
| `manage_section` | 新建、改名、调整顺序、删除分区（删分区不删提醒） |
| `manage_smart_list` | 新建、修改、删除智能清单：匹配所有/任一，筛选标签、日期（含日期范围、相对范围）、时间段、优先级、旗标、清单、地点（含上车/下车） |
| `manage_tag` | 给所有提醒上的某个标签改名（同名则合并），或删除 |
| `manage_template` | 把清单存为模板、用模板建清单、删除模板 |

提醒字段：

| 字段 | 写法 |
|---|---|
| `due` / `start` | `2026-10-21`（全天）或 `2026-10-21T09:00`（本地时间）；带时间的到期会在那时提醒 |
| `repeat` | `{frequency: hourly/daily/weekly/monthly/yearly, interval, days_of_week: [mon, 1mon, -1fri], days_of_month: [1, -1], months: [1..12], until 或 count}` |
| `early_alerts` | `[{before: 15, unit: minutes/hours/days/weeks/months}]` |
| `location` | `{title, latitude, longitude, radius, address, when: arriving/leaving}`，或 `getting-in-car` / `getting-out-of-car` |
| `when_messaging` | `{phones: [...], emails: [...]}` |
| `url`、`add_images` | 链接；本机图片路径 |
| `priority`、`flagged`、`urgent`、`tags`、`notes` | 优先级 none/low/medium/high；标签不带 # |
| `parent_id`、`section`、`position` | 子任务；分区；`{after/before: 提醒 id}` |
| `assigned_to` | 共享清单里成员的名字，或 `me` |

规则：

- 改和删都要带上读到的 `version`。它是可见字段的哈希，用户在别的设备上改过就会拒绝写入，避免覆盖。
- Urgent 需要带具体时间的到期；把到期改成全天或清空时会自动关掉 Urgent。重复和提前提醒需要到期日期。
- 子任务只有一层，必须和父任务在同一个清单；有子任务的提醒不能移动清单。
- 勾完成重复提醒时，和 App 一样留下一条已完成的副本，并把提醒推到下一次；可以在设置里关掉。
- 颜色：red、orange、yellow、green、light-blue、blue、indigo、pink、purple、brown、gray、rose，或 `#RRGGBB`。图标是 emoji 或 Reminders 的图标名（如 `nature2`）。
- 共享清单其他人能看到，agent 改动前应先问用户。
- 任何工具都可以在设置窗口里对所有 AI 助手关掉（见[选择开放的工具](#选择开放的工具)）。

## 命令行

每个工具也是一条命令，所以在终端里、在 agent 的 shell 里都能用，[技能](#服务器还是技能)用的就是它。命令由名词加动词组成。参数来自工具的输入字段，也就是上面表格里的那些字段。`apple-reminders-mcp help` 打印整棵命令树：

```text
apple-reminders-mcp
├── --stdio                     Serve MCP on stdin and stdout (what agents start)
├── --settings                  Open the settings window (also what opening the app does)
├── --self-check                Print a diagnosis
├── --version                   Print the version
├── help [COMMAND…]             This tree, or a command's flags (also --help, -h)
├── setup                       Ask for access to Reminders (alias: authorize)
├── skill                       Print the SKILL.md that teaches an agent this command line
├── agents
│   ├── list                    Which agents are here and set up (the default)
│   │       [--skill] [--folder DIR]
│   ├── set-up (ID… | --all)    Register the server with them, or install the skill
│   │       [--restart] [--skill] [--folder DIR]
│   └── install ID…             Install them, then set them up
│           [--dry-run] [--restart] [--skill] [--folder DIR]
├── reminders
│   ├── find [QUERY]            Find reminders across lists, open ones first by due date; QUERY matches the title or notes
│   │       --assigned-to string --due-after string --due-before string --[no-]flagged --[no-]has-location
│   │       --[no-]include-completed --limit int --list string --[no-]repeating --section string
│   │       --smart-list string --tag string --[no-]urgent
│   ├── get ID                  Read one reminder in full: alarms, early alerts, images, subtasks, and its current version
│   ├── create TITLE            Create a reminder; without --list it goes to the default list (or the parent's list)
│   │       --add-image string… --after string --assigned-to string --before string --due string
│   │       --early-alerts json --[no-]flagged --list string --location json|string --notes string
│   │       --parent-id string --priority none|low|medium|high --repeat json --section string --start string
│   │       --tag string… --[no-]urgent --url string --when-messaging json
│   ├── update ID --version string  Change only the fields given; --no-FIELD clears one
│   │       --add-image string… --after string --assigned-to string --before string --[no-]completed
│   │       --due string --early-alerts json --[no-]flagged --list string --location json|string
│   │       --notes string --parent-id string --priority none|low|medium|high --remove-image string…
│   │       --repeat json --section string --start string --tag string… --title string --[no-]urgent
│   │       --url string --when-messaging json
│   ├── delete ID --version string  Move a reminder and its subtasks to Recently Deleted
│   ├── deleted                 List reminders in Recently Deleted that restore can bring back, newest first
│   ├── restore ID              Bring a reminder back from Recently Deleted, with the subtasks deleted along with it
│   │       --list string
│   └── image REMINDER_ID IMAGE_ID  Save an image on a reminder (ids from get) and print where; needs Full Disk Access
│           --output string
├── lists
│   ├── list                    The lists (with counts, sections and the people on shared ones), groups, smart lists and templates (the default)
│   ├── create NAME             Create a list
│   │       --color string --icon string --group string --[no-]pinned --type standard|groceries --sort string
│   │       --after string --before string
│   ├── update LIST             Change a list's name, color, icon, group, pin, type, sort order or place in the sidebar
│   │       --new-name string --color string --icon string --group string --[no-]pinned
│   │       --type standard|groceries --sort string --after string --before string
│   ├── clear-completed LIST    Move a list's completed reminders to Recently Deleted
│   └── delete LIST             Delete a list; one with reminders needs --confirm-delete-reminders (ask the user first)
│           --[no-]confirm-delete-reminders
├── groups
│   ├── create NAME             Create a group, which holds lists in the sidebar (put lists in it with lists update --group)
│   ├── rename GROUP NEW_NAME   Rename a group
│   └── delete GROUP            Delete an empty group
├── sections
│   ├── create LIST NAME        Create a section in a list (put reminders in it with --section)
│   ├── rename LIST SECTION NEW_NAME  Rename a section
│   ├── move LIST SECTION (--after string | --before string)  Move a section next to another one
│   └── delete LIST SECTION     Delete a section; its reminders stay in the list
├── smart-lists
│   ├── create NAME --filters json  Create a smart list, which shows the reminders matching its filters
│   │       --match all|any --color string --icon string
│   ├── update SMART_LIST       Change a smart list's name, color, icon, match or filters (--filters replaces them all)
│   │       --new-name string --filters json --match all|any --color string --icon string
│   └── delete SMART_LIST       Delete a smart list; no reminders are deleted
├── tags
│   ├── list                    Every tag in use, with how many open and how many reminders in all have it (the default)
│   ├── rename TAG NEW_NAME     Rename a tag on every reminder that has it, merging into a tag of that name if there is one
│   └── delete TAG              Remove a tag from every reminder
├── templates
│   ├── create NAME --list string  Save a list as a template (Reminders copies its reminders in the background)
│   │       --[no-]include-completed
│   ├── use TEMPLATE            Make a new list from a template
│   │       --list string
│   └── delete TEMPLATE         Delete a template
└── call TOOL [JSON | -]        Run any tool on a JSON object of its arguments; call alone lists the tools
```

- **参数名：**字段名里的下划线换成短横线，`due_before` 就是 `--due-before`。
- **是非字段：**`--flagged` 打开，`--no-flagged` 关闭。
- **清空字段：**修改时用 `--no-due` 这类参数清空一个字段（相当于 MCP 里的 `null`）。
- **列表：**取列表的字段用单数形式重复写：`--tag work --tag home`。
- **对象：**对象字段写 JSON：`--repeat '{"frequency":"weekly","days_of_week":["mon"]}'`。`--location` 也可以写 `getting-in-car` 或 `getting-out-of-car`，`--after ID` / `--before ID` 设置 `position`。
- **用 JSON 传字段：**`--json '{…}'` 按 MCP 的字段名传参，`--json -` 从标准输入读；同时给的参数会覆盖它。
- **任意工具：**`call TOOL '{…}'` 用 MCP 参数直接调用任意工具。
- **帮助：**命令后面加 `--help`，列出它的参数和各自的写法。

命令的输出就是工具的回答：JSON，有时前面带一句「Created.」之类的话。
- **退出码 1：**请求失败（找不到、读取后被改过、不允许），原因写在 stderr。
- **退出码 2：**命令或参数写错了。

`reminders image` 把图片存到 `--output`（默认存进临时文件夹），并打印位置。只有第一个词决定做什么，所以提醒可以叫 `setup`。以 `-` 开头的标题前面加 `--`。

```bash
apple-reminders-mcp reminders find --due-before 2026-10-22
apple-reminders-mcp reminders create "买牛奶" --list Groceries --due 2026-10-22T09:00 --tag errands
apple-reminders-mcp reminders update <id> --version <version> --completed
apple-reminders-mcp lists create Trips --color blue
```

## 安装

发布的包只支持 Apple 芯片，需要 macOS 26 或更新。默认用 Homebrew 安装和配置：

```bash
brew install --cask xiaofeng-han/tap/apple-reminders-mcp
apple-reminders-mcp setup                  # 允许访问提醒事项
apple-reminders-mcp agents set-up --all    # 把服务器注册到这台 Mac 上的 agent
```

想给 agent 装技能而不是服务器，在最后一条命令后加 `--skill`（见[服务器还是技能](#服务器还是技能)）。

后两条命令也可以换成打开「应用程序」里的 Apple Reminders MCP：在「AI 助手」标签页配置 agent，在「通用」里允许访问提醒事项。不用 Homebrew 的话，见[用安装包](#用安装包)。

### 用 Homebrew

像上面那样写全名，会自动添加 tap [xiaofeng-han/tap](https://github.com/xiaofeng-han/homebrew-tap)，并且只信任这一个 cask。Homebrew 6 起，第三方 tap 里的内容要先信任才会加载。之后 `brew upgrade` 就能收到新版本。

Homebrew 装的是下面那个安装包里的同一个 App：它从 release 上的 zip 解出 App，自己移到 `/Applications`，所以不要管理员密码。App 没有 Developer ID 签名，所以 cask 会去掉 Homebrew 给下载加的隔离标记，否则 Gatekeeper 不让它启动。它还会添加命令 `apple-reminders-mcp`（`/opt/homebrew/bin/apple-reminders-mcp`），这是一个启动 App 的小脚本，下面的步骤都用它。`brew uninstall --cask apple-reminders-mcp` 卸载 App，加上 `--zap` 还会把它的设置和删除记录移到废纸篓。

如果之前用安装包「仅为我安装」过，删掉那一份，并把各 agent 改成用新命令（见[注册到客户端](#注册到客户端)）。Claude Code 不能重复添加同名服务，要先运行 `claude mcp remove -s user apple-reminders` 再添加；其他客户端改 `command` 即可。两份的签名相同，提醒事项的权限会沿用。

```bash
rm -rf ~/Applications/AppleRemindersMCP.app
pkgutil --volume ~ --forget com.xiaofeng.apple-reminders-mcp.pkg
```

### 用安装包

不用 Homebrew 的话，从 [Releases](https://github.com/xiaofeng-han/apple-mcp/releases) 下载 `AppleRemindersMCP-<版本>.pkg` 打开安装，或者在终端里装：

```bash
gh release download reminders-v0.4.1 -R xiaofeng-han/apple-mcp -p '*.pkg'
installer -pkg AppleRemindersMCP-0.4.1.pkg -target CurrentUserHomeDirectory
```

选「仅为我安装」会装到 `~/Applications`，不需要管理员密码；为所有用户安装则装到 `/Applications`。安装包没有 Developer ID 签名：用浏览器下载后如果 macOS 拒绝打开，到「系统设置 → 隐私与安全性」里允许。

### 装好之后

下面的例子用的是 Homebrew 添加的命令。用安装包装的，把它换成 App 的可执行文件：`~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP`；为所有用户安装的是 `/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP`。

授权访问提醒事项：

```bash
apple-reminders-mcp setup
```

`setup` 会弹出授权窗口（可能被别的窗口挡住），点「允许」。检查状态：

```bash
apple-reminders-mcp --self-check
```

直接双击 App（或用 `--settings` 参数启动）会打开设置窗口。「通用」标签页里能看到两项权限的状态、「允许 AI 助手勾完成重复提醒」开关（默认打开），以及窗口的语言：英文或简体中文，默认跟随系统，也可以自己选。这两项设置也可以用命令改：

```bash
defaults write com.xiaofeng.apple-reminders-mcp AllowCompletingRecurringReminders -bool NO
defaults write com.xiaofeng.apple-reminders-mcp InterfaceLanguage -string zh-Hans   # 或 en；删掉这一项就跟随系统
```

授权弹窗是 macOS 自己的，总是跟随系统语言。

完全磁盘访问要手动添加：系统设置 → 隐私与安全性 → 完全磁盘访问，点 ＋，选 `AppleRemindersMCP.app`。用安装包「仅为我安装」的在 `~/Applications`，其他情况在 `/Applications`。

### 配置 AI 助手

窗口里的「AI 助手」标签页（排在第一个，窗口打开时显示的就是它）负责把服务器注册到各个 agent。窗口打开时，它先判断这份副本是怎么装的（Homebrew、安装包，还是都不是），从而确定 agent 该启动哪个命令；然后找下面这些 agent，读它们的设置文件。每个 agent 旁边有一个按钮：
- 还没注册时是「配置」。agent 启动的是另一份副本时显示「更新」，那份副本已经不在时显示「修复」，服务器被关掉时显示「打开」。
- 没装的 agent 是「安装」。它按这份副本的安装方式来装：用 Homebrew 装的就用 Homebrew，否则用厂商自己的安装脚本或下载包。装好后接着配置。鼠标停在按钮上能看到要运行的命令。

「全部配置」一次配好所有已安装的 agent。

| Agent | 改的设置 | 安装方式（Homebrew 安装时 / 其他情况） |
|---|---|---|
| Claude Code（也是 Claude App 的 Code 标签页） | `~/.claude.json`，通过 `claude mcp add-json -s user` | `brew install --cask claude-code` / `curl -fsSL https://claude.ai/install.sh \| bash` |
| Claude App | `~/Library/Application Support/Claude/claude_desktop_config.json`。Claude 会把内存里的设置写回这个文件，所以添加时会先退出它，之后再打开 | `brew install --cask claude` / 从 Anthropic 的更新源下载 App |
| Codex CLI 和 ChatGPT App（原 Codex App） | `~/.codex/config.toml` | `brew install --cask codex`、`chatgpt` / `curl -fsSL https://chatgpt.com/codex/install.sh \| sh`、App 的磁盘映像 |
| Grok Build | `~/.grok/config.toml` | `brew install --cask grok-build` / `curl -fsSL https://x.ai/cli/install.sh \| bash` |
| OpenCode 和 OpenCode Desktop | `~/.config/opencode/opencode.json`（或 `opencode.jsonc`） | `brew install opencode`、`--cask opencode-desktop` / `curl -fsSL https://opencode.ai/v2/install \| bash`、App 的磁盘映像 |
| Gemini CLI | `~/.gemini/settings.json` | `npm install -g @google/gemini-cli`（Homebrew 的 formula 已弃用） |
| Antigravity App 和 CLI | `~/.gemini/config/mcp_config.json` | `brew install --cask antigravity`、`antigravity-cli` / App 的磁盘映像、`curl -fsSL https://antigravity.google/cli/install.sh \| bash` |

列表里也有 Grok Bot 和 Gemini App，但它们用不了这个服务器：Grok Bot 的 MCP 服务器跑在它的云端电脑上，Gemini App 只接受在 gemini.google.com 添加的远程服务器。

「配置」写入 `apple-reminders` 这一项，并保留你在里面加的东西（环境变量、超时）。如果 agent 把服务器关掉了，「配置」会重新打开它：从 Grok 的 `disabled_mcp_servers`、Gemini CLI 的 `mcp.excluded` 和 `mcp-server-enablement.json` 里去掉它，在你设了 `mcp.allowed` 时把它加进去。文件里其他内容（包括注释和格式）保持原样。用本 App 不改的写法（比如 TOML 内联表）写的条目不会动，显示为「已手动配置」。`CODEX_HOME`、`XDG_CONFIG_HOME` 这类挪动配置目录的变量，只要登录 shell 里设了就会跟着走。每天第一次修改前，旧文件会备份在旁边，名为 `<文件名>.bak-<yyyyMMdd>-apple-reminders-mcp`。

安装程序和 agent 的命令运行时不带本 App 的权限（提醒事项、完全磁盘访问），在独立的会话里，没有终端。下载的 App 必须通过 Gatekeeper；内置了团队号的厂商（除 OpenCode 和 Antigravity 外都有）还必须是该团队签名的，才会安装。没有 npm 时无法从 App 安装 Gemini CLI。

终端里也能做同样的事：

```bash
apple-reminders-mcp agents                     # 哪些 agent 装了、配了
apple-reminders-mcp agents set-up --all        # 或者点名：agents set-up codex grok
apple-reminders-mcp agents install opencode    # 安装后接着配置；加 --dry-run 只显示命令
```

Claude App 开着的时候，`agents set-up` 不会动它，除非加 `--restart`。

### 服务器还是技能

列表上方的「配置方式」决定 agent 怎么用这个 App：
- **MCP 服务器**（默认）：agent 启动 `apple-reminders-mcp --stdio`，16 个工具一直加载着。
- **技能：**「配置」会写入一个技能 `apple-reminders/SKILL.md`，教 agent 使用[命令行](#命令行)。
  - agent 只在涉及提醒事项时才读它，并在自己的 shell 里运行命令，上下文里不会一直挂着工具列表。
  - 技能里写的是这份副本命令的完整路径。
  - App 升级后，如果技能内容有变，按钮会显示「更新」。

不选文件夹时，技能放在每个 agent 自己的技能文件夹里，所有项目都能用。点「选择…」改选一个项目文件夹，技能就只放在那里；点「所有项目」改回来。

| Agent | 所有项目都能用的技能 | 项目文件夹里的技能 |
|---|---|---|
| Claude Code，以及 Claude App 的 Code 标签页 | `~/.claude/skills/`（`$CLAUDE_CONFIG_DIR/skills/`） | `.claude/skills/` |
| Codex CLI 和 ChatGPT App、OpenCode 和 OpenCode Desktop、Gemini CLI | `~/.agents/skills/` | `.agents/skills/` |
| Grok Build | `~/.grok/skills/` | `.agents/skills/` |
| Antigravity App | `~/.gemini/config/skills/` | `.agents/skills/` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/` | `.agents/skills/` |

- **共用文件夹：**读同一个文件夹的 agent 共用一个文件。pi 也读 `~/.agents/skills`。
- **同名技能：**不是本 App 写的同名技能 `apple-reminders` 不会被改动，那一行显示「已有同名技能」。
- **服务器和技能并存：**用一种方式配置，永远不会改动另一种。一个 agent 可以两种都配，那一行会注明。
- **用不了技能的 agent：**Grok Bot 和 Gemini App 不能在这台 Mac 上运行命令。Claude App 的 Code 标签页能用技能，聊天里不能。

有些 agent 在沙盒里运行 shell 命令。Codex 默认就这样，而在它的沙盒里，macOS 不让任何程序碰「提醒事项」。这种情况下：
1. 命令会说明它是在沙盒里运行的。
2. 技能会让 agent 在沙盒外重新运行这条命令。
3. Codex 会请你批准。

启动 MCP 服务器的 agent 没有这个问题。

终端里也能做：

```bash
apple-reminders-mcp agents list --skill                                   # 每个 agent 的技能在哪、是否最新
apple-reminders-mcp agents set-up --all --skill                           # 所有已安装的 agent，所有项目都能用
apple-reminders-mcp agents set-up claude-code codex --folder ~/code/app   # 只放进一个项目（--folder 隐含 --skill）
apple-reminders-mcp skill                                                 # 打印技能，方便手动装到任何地方
```

### 选择开放的工具

窗口的「工具」标签页按名字列出 16 个工具，每个都写明用途并带一个标签：「只读」「修改」或「可删除」。勾上允许 AI 助手使用的工具。「全选」「全不选」「反选」「只读」（只开标着「只读」的工具）一次改动全部。选择立即保存在 `~/Library/Application Support/AppleRemindersMCP/tools.json`，它在 App 之外，所以重启、更新、重装都不会丢：

```json
{
  "tools" : {
    "create_reminder" : true,
    "delete_reminder" : false,
    …
  }
}
```

改动立即生效。关掉的工具不会出现在工具列表里，硬要调用也会被拒绝，并告诉助手你可以在哪里重新打开。它对应的[命令](#命令行)也会被拒绝（退出码 1），所以用技能配置的 agent，以及你自己的终端，同样受这个选择约束。正在运行的助手会收到 `notifications/tools/list_changed`：2026-07-28 协议的客户端（Claude Code、Grok Build）在它们打开的 `subscriptions/listen` 流上收到，旧协议的客户端在初始化之后收到。Claude Code 会重新列出工具，同一个会话里就能看到变化；不理会这个通知的客户端要到新会话才会看到。这个版本之前启动的服务器不读这个文件，所以更新后把这些助手重启一次。

以后版本新增的工具（文件里还没有它的名字）默认打开，除非你关掉了同一标签的其他工具：选过「只读」之后，新增的写入类工具也保持关闭。如果文件读不了（比如手动改坏了），在修好之前不开放任何工具；在标签页里重新选择会替换它，并把坏的那份保留为 `tools.json.bak-<日期>-<时间>`。`apple-reminders-mcp --self-check` 会显示开放了几个工具。没有这个文件时，全部工具都开放。

### 从源码构建

```bash
./scripts/build-app.sh reminders
ditto dist/AppleRemindersMCP.app ~/Applications/AppleRemindersMCP.app
```

`./scripts/build-pkg.sh reminders` 生成发布用的安装包 `dist/AppleRemindersMCP-<版本>.pkg` 和它的 SHA-256 校验文件。发布新版本：先把发布说明写成 [`CHANGELOG-reminders.md`](../CHANGELOG-reminders.md) 里的一节 `## <版本>`，跑一遍 `scripts/e2e.py reminders`（改过共用代码时 `scripts/e2e.py notes` 也要跑），然后在 `main` 上运行：

```bash
scripts/release.sh reminders 0.4.0   # 也可以先演练：scripts/release.sh --dry-run reminders 0.4.0
```

- **它做什么：**设版本号（构建号自动加一），跑 `swift test`。然后打出安装包和 App 的 zip，并检查 App 是用你的证书签名的；接着提交 `Release Apple Reminders MCP <版本>`、打 tag `reminders-v<版本>` 并一起推送。之后用安装包、zip（Homebrew cask 装的就是它）和 `CHANGELOG-reminders.md` 里的说明发布 GitHub release，并自动补上这个版本的安装命令。最后用 `./scripts/update-cask.sh reminders` 把 Homebrew cask 指向新版本，改的是 [homebrew-tap](https://github.com/xiaofeng-han/homebrew-tap) 的本地副本（默认 `../homebrew-tap`，`TAP=<路径>` 可以换）。Apple Notes MCP 有自己的版本号，单独发版。
- **某一步失败时：**它会说明哪些已经做完，以及剩下的怎么手动完成。
- **`--dry-run`：**做到打好安装包为止，然后撤销版本号的改动；不提交、不推送、不发布。

图标的源文件是 Icon Composer 文档 `Resources/Reminders/AppIcon.icon`。改了之后运行 `./scripts/build-icon.sh reminders`（要用 Xcode 里的 `actool`），再提交 `Resources/Reminders/AppIcon-compiled`；平常构建只复制这个目录。图稿要画成铺满的正方形，由 macOS 裁成它的圆角形状：自己画了形状、四周透明的图标，会被缩小放进一个灰色底框里。`swift scripts/flatten-icon.swift <图标.png> Resources/Reminders/AppIcon.icon/Assets/artwork.png` 能把「透明背景上画一个圆角方块」的图标转成这种图稿。

### 权限为什么记在这个 App 名下

macOS 把子进程的隐私权限算在「责任进程」头上。Claude Code 和 Claude Desktop 的 Info.plist 里没有提醒事项的用途说明，由它们直接启动的程序访问提醒事项会被静默拒绝。所以 App 一启动就放弃这层责任关系，以自己的身份再启动一次（`Sources/Launcher`），stdin 和 stdout 原样交给新进程。这样权限只需授予一次「Apple Reminders MCP」，与谁启动它无关。

所以要用真实路径启动它，或者像 Homebrew 的 `apple-reminders-mcp` 那样用脚本 `exec` 它，不要经符号链接启动。经链接启动时 macOS 找不到 App 包，App 就不会以自己的身份重新启动，权限会算到启动它的程序头上。

### 「最近删除」

ReminderKit 能按 id 恢复已删除的提醒，却列不出它们，删除后也查不到提醒原来在哪个清单。所以本工具删除时会在 `~/Library/Application Support/AppleRemindersMCP/deleted.json` 记一笔（id、标题、原清单，保留 31 天）。`restore_reminder` 默认按这份记录恢复回原清单。开了完全磁盘访问后，`list_deleted` 会只读「提醒事项」的数据库，列出全部最近删除，包括在其他设备上删的；恢复仍然走 ReminderKit。

### 签名

`build-app.sh` 默认用登录钥匙串里的自签名证书「Xiaofeng Local Code Signing」签名。签名要求是「bundle id + 证书」，所以重新编译后权限还在；如果用 ad-hoc 签名，每次重新编译都要重新授权。`SIGNING_IDENTITY` 可以换成别的证书。在一台新 Mac 上建这张证书：

```bash
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout key.pem -out cert.pem \
  -subj "/CN=Xiaofeng Local Code Signing" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Xiaofeng Local Code Signing" -out id.p12 -passout pass:temp
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm key.pem id.p12
```

请用系统自带的 `/usr/bin/openssl`。Homebrew 的 OpenSSL 3 默认用新算法导出 p12，`security import` 可能导入失败（这里没试过）。`security find-identity -p codesigning` 显示 `CSSMERR_TP_NOT_TRUSTED` 是正常的，codesign 仍然能用这张证书签名。

## 注册到客户端

App 的「AI 助手」标签页或 `apple-reminders-mcp agents set-up` 会替你做这件事（见[配置 AI 助手](#配置-ai-助手)）。手动注册的话：

用 Homebrew 装的，命令是 `/opt/homebrew/bin/apple-reminders-mcp`；用安装包「仅为我安装」的，是 `~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP`（为所有用户安装的是 `/Applications/…`）。运行时加 `--stdio`。要写完整路径：从程序坞启动的 App 的 `PATH` 里一般没有 `/opt/homebrew/bin`。服务名 `apple-reminders`。服务器支持 MCP 的会话协议（2024-11-05 到 2025-11-25）和无状态的 2026-07-28 协议。

- Claude Code：`claude mcp add -s user apple-reminders -- <命令> --stdio`
- Codex（`~/.codex/config.toml`，Codex App 共用）、Grok Build（`~/.grok/config.toml`，另加 `enabled = true`）：

  ```toml
  [mcp_servers.apple-reminders]
  command = "/opt/homebrew/bin/apple-reminders-mcp"   # 或 "/Users/<you>/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP"
  args = ["--stdio"]
  ```

- Claude App（`~/Library/Application Support/Claude/claude_desktop_config.json`，先退出 Claude）、Gemini CLI（`~/.gemini/settings.json`）、Antigravity（`~/.gemini/config/mcp_config.json`）：`"mcpServers": {"apple-reminders": {"command": "<命令>", "args": ["--stdio"]}}`
- OpenCode（`~/.config/opencode/opencode.json`）：`"mcp": {"servers": {"apple-reminders": {"type": "local", "command": ["<命令>", "--stdio"]}}}`。1.18.24 之前的 OpenCode 1 只读直接写在 `mcp` 下的服务器，并且要 `"enabled": true`。
- pi（`~/.pi/agent/mcp.json` 的 `mcpServers`）：`{"type": "stdio", "command": "<命令>", "args": ["--stdio"]}`

手动装技能：把 `apple-reminders-mcp skill` 的输出存成 agent 技能文件夹里的 `apple-reminders/SKILL.md`（见[服务器还是技能](#服务器还是技能)）。

验证：`claude mcp list`、`grok mcp doctor`、`pi mcp list`。调试时设 `APPLE_REMINDERS_MCP_WIRE_LOG=<文件>` 可以记录收发的每条消息。

## 测试

```bash
/usr/bin/python3 -I scripts/e2e.py reminders                              # 已安装的 App，针对真实的提醒事项
/usr/bin/python3 -I scripts/e2e.py reminders dist/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP   # 当前代码，先跑 scripts/build-app.sh reminders
```

`dist/` 里的构建和正式版签名相同，所以沿用你给已安装 App 的提醒事项权限；裸的 `.build/debug/AppleRemindersMCP` 只有启动它的程序（你的终端）的权限，没有权限时检查会立刻停下。检查通过 stdio 把所有工具和规则走一遍，再跑一遍主要的命令行命令，共 167 项检查。写保护（`APPLE_REMINDERS_MCP_WRITE_GUARD`，用逗号分隔多个名字，清单、分组、智能清单、模板都算）把写入限制在几个临时名字里（`agent test`、`agent test 2`…）。测试开头会清掉上次中断留下的数据，结尾也会删掉自己建的；「最近删除」里会留下测试项。测试会临时改动「勾完成重复提醒」设置，结束时恢复默认。工具选择读的是一个临时文件（`APPLE_REMINDERS_MCP_TOOLS_FILE`），所以既不受你的选择影响，也不会改动它。

`swift test` 检查 agent 配置和命令行，都在临时目录里进行：
- 保持文件其余部分原样的 JSON 和 TOML 编辑；
- 各 agent 设置的读写；
- 各 agent 的技能放在哪里；
- 命令行参数如何按工具的输入 schema 解析；
- 工具选择：文件里没写到的工具按什么规则处理、文件的读写与监视，以及服务器列出、拒绝和通知了什么。

## 做不到的

- 邀请别人共享清单：需要 iCloud 的共享界面，程序没法替用户完成。
- 读取提醒在清单里的手动顺序：能调整顺序，但读出来的结果不带顺序。
- 智能清单里本工具不认识的条件（比如系统以后新增的）：`list_lists` 会把它们原样放在 `filters.other` 里，但不能用工具修改。
