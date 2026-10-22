# Apple Notes MCP

[English](README.md) | **简体中文**

让 AI agent（Claude Code、Codex、Grok Build、OpenCode、Gemini CLI、pi……）读写 macOS「备忘录」的 MCP 服务器，格式都是原生的。每个工具也是一条命令行命令，所以 agent 也可以不用服务器，改用技能。它的设置窗口会找出 Mac 上的 agent，用任一种方式一键配好每一个，没装的也能直接安装。

- **读**：经「备忘录」自己的数据模型，以只读方式打开它的数据库：标题、小标题、列表、清单（含勾选状态）、表格、链接、高亮（含颜色）、标签、笔记链接、分割线和附件都转成 Markdown。搜索还能找到「备忘录」从图片、扫描件和手写里识别出的文字，以及录音的文字稿。
- **改**：经私有框架 NotesShared 原地修改，和「备忘录」自己改的方式一样：只写变化的部分，逐字修改，所以 Markdown 表达不了的东西（颜色、字体、对齐）保持原样，其他设备上的修改也能合并。每次修改先在副本上演练一遍，写完再读回来核对。
- **同步**：这样写入的改动「备忘录」不会自己上传，所以每次修改后服务器会通过 AppleScript 让「备忘录」保存并上传这条笔记，并等到 iCloud 收到为止。「备忘录」不会跳到前台。

需要 Apple 芯片、macOS 26 或更新版本，在 macOS 27.0.1 上开发和验证。代码全部是本项目自己写的，不依赖第三方库。需要的权限是完全磁盘访问（读备忘录数据库）和自动化 → 备忘录（上传、移动、删除）。

## 工具

| 工具 | 作用 |
|---|---|
| `overview` | 文件夹和笔记数、智能文件夹、标签；或者按行列出某个文件夹、智能文件夹或「最近删除」里的笔记（id、版本、标题、日期、大小、附件、描述），可按日期、标签、分组（`only`：pinned 置顶、shared 共享、locked 加锁、quick-notes 快速备忘录、math-notes 数学笔记、calls 通话录音、checklists 有清单、unchecked 有未勾选项、tagged/untagged 有无标签、mentions 有提及）和附件类型筛选，按修改、创建、最近打开时间或标题排序。`undescribed: true` 列出还没有描述的笔记和它们的开头 |
| `search` | 全文搜索标题、正文和「备忘录」从附件里得到的文字（图片和扫描件里识别的字、手写、录音文字稿），最相关的在前，附上匹配处的上下文；筛选方式同 `overview` |
| `read_note` | 以 Markdown 读一条笔记，附带版本号：按 id、多个 id 或完整标题；可以只读一节，或先看大纲（各节大小）。开头一行会写明是否置顶、共享，以及哪些笔记链接到它 |
| `read_attachment` | 打开 `![…](attachment:id)` 占位符对应的附件：图片（缩放后）、扫描件的各页、手绘、PDF（文字和文件）、音频（录音附带「备忘录」的文字稿和摘要）、视频的一帧、表格、链接和文件，以及「备忘录」识别出的文字 |
| `describe_note` | 保存一句话描述（`overview` 会显示），一次可写很多条 |
| `create_note` | 用 Markdown 新建笔记，可放进任一文件夹，可附文件和链接卡片；或连同全部内容复制一条笔记（`copy_of`） |
| `edit_note` | 一次调用里做多处修改：精确替换、在开头/末尾/某个小标题下插入 Markdown（列表项会并入该节的列表），或整篇重写；按文字勾选或取消清单项、全部勾选或取消、已勾选的移到底部或删掉；置顶 |
| `move_note` | 把一条或多条笔记移到同一账户的其他文件夹，或从「最近删除」移回来 |
| `delete_note` | 把一条或多条笔记移到「最近删除」 |
| `manage_folder` | 新建、改名、移动（放进另一个文件夹或移到最上层）、删除文件夹（空文件夹；或加 `recursive` 和 `expected_notes` 连同其中所有内容）；按标签新建、改名、删除智能文件夹；把文件夹及其子文件夹导出成 Markdown 加原始附件，存到新文件夹或 `.zip` |
| `manage_tag` | 在所有用到某个标签的笔记里给它改名，或把它从所有笔记里去掉（要传 `expected_notes`） |

### Markdown 对照

笔记的一个段落就是 Markdown 的一行，模型改一行不会牵动其他地方。

| 备忘录 | Markdown |
|---|---|
| 标题、小标题、副标题 | `# `、`## `、`### ` |
| 圆点、短横线、编号列表 | `* `、`- `、`1. `（每级缩进两个空格） |
| 清单 | `- [ ] ` / `- [x] ` |
| 引用 | 每级一个 `> ` |
| 等宽 | ```` ``` ```` 之间的行 |
| 粗体、斜体、删除线 | `**…**`、`*…*`、`~~…~~` |
| 下划线、高亮 | `<u>…</u>`、`<mark>…</mark>`（紫色）；粉、橙、薄荷绿、蓝色写 `<mark class="pink">…</mark>` 等 |
| 链接 | `[文字](网址)` |
| 标签 | `#名字`（真正的「备忘录」标签；会被读成标签的普通文字写成 `\#名字`） |
| 链接到笔记 | `[文字](note:1A2B3C4D)`；文字为空时用那条笔记的标题 |
| 分割线 | 单独一行 `---` |
| 表格 | `\| a \| b \|` 的行；单元格里换行写 `<br>` |
| 附件 | `![image](attachment:1A2B3C4D)`（占位符，原样保留） |
| 新附件、新链接卡片 | `![名字](/路径/文件)`（也可以 `~/…` 或 `file://…`）；`![](https://…)` |

### 规则

- 对笔记的每一次修改（`edit_note`、`move_note`、`delete_note`）都要带上 `read_note`、`overview` 或 `search` 给的 `version`（笔记 Markdown 的哈希）。如果读过之后笔记又被改了（在别的设备上、或被别的 agent），修改会被拒绝，不会覆盖那次修改；每次写入都会返回新的版本号。每次编辑前，笔记存储的正文会备份到 `~/Library/Application Support/AppleNotesMCP/backups/<笔记 id>/`（保留最近 20 份）。
- 附件留在原处：会丢掉占位符、或加入笔记里没有的附件的修改都会被拒绝。表格、标签、笔记链接和分割线例外：可以像文字一样新增和删除。新文件和链接卡片用 `![名字](/路径)` 和 `![](https://…)` 加入；文件只从家目录（不含 `~/Library` 和隐藏文件夹）、临时文件夹或外接磁盘里取，因为本 App 能读所有文件。
- 智能文件夹里没有自己的笔记：`overview` 和 `search` 可以用它列出或搜索它的规则选中的笔记，但不能把笔记移进去。
- 加锁的笔记不能读也不能改。共享的笔记可以编辑（与其他人的修改合并），但这里不删除；移进或移出共享文件夹要 `allow_shared`（先问用户）。
- `delete_note` 和递归删除文件夹只把笔记移到「最近删除」；已经在那里的笔记会被拒绝（再删一次就永久删除了）。递归删除要传 `expected_notes`（调用方看到的笔记数），并且在动手之前把所有条件检查完。
- 导出只能写到还不存在的路径，且不能在 `~/Library` 里。
- 任何工具都可以在设置窗口里对所有 AI 助手关掉（见[选择开放的工具](#选择开放的工具)）。

## 命令行

每个工具也是一条命令，所以在终端里、在 agent 的 shell 里都能用，[技能](#服务器还是技能)用的就是它。命令由名词加动词组成。参数来自工具的输入字段，也就是上面那些工具的字段。`apple-notes-mcp help` 打印整棵命令树：

```text
apple-notes-mcp
├── --stdio                     Serve MCP on stdin and stdout (what agents start)
├── --settings                  Open the settings window (also what opening the app does)
├── --self-check                Print a diagnosis
├── --version                   Print the version
├── help [COMMAND…]             This tree, or a command's flags (also --help, -h)
├── setup                       Ask to control Notes, and show where to give Full Disk Access
├── skill                       Print the SKILL.md that teaches an agent this command line
├── agents
│   ├── list                    Which agents are here and set up (the default)
│   │       [--skill] [--folder DIR]
│   ├── set-up (ID… | --all)    Register the server with them, or install the skill
│   │       [--restart] [--skill] [--folder DIR]
│   └── install ID…             Install them, then set them up
│           [--dry-run] [--restart] [--skill] [--folder DIR]
├── notes
│   ├── list                    List notes, newest first, one line each (id | version | title | date | size | description) (the default)
│   │       --folder string --tag string… --only string… --attachment string… --modified-after string
│   │       --modified-before string --created-after string --created-before string
│   │       --sort modified|created|title|opened --[no-]undescribed --limit int
│   ├── search QUERY            Full-text search of titles, text and the text Notes found in attachments, best matches first
│   │       --match all|any --folder string --tag string… --only string… --attachment string…
│   │       --modified-after string --modified-before string --created-after string --created-before string
│   │       --sort modified|created|title|opened --limit int
│   ├── read [ID]               Print notes as Markdown, each with the version that notes edit takes
│   │       --id string… --title string --section string --[no-]outline
│   ├── create MARKDOWN         Create a note from Markdown; its first line is the title
│   │       --folder string
│   ├── copy ID                 Copy a note with everything in it, into its own folder or --folder
│   │       --folder string
│   ├── edit ID --version string  Change a note in one go: --replace pairs, --insert Markdown, or --rewrite the whole note; --[no-]pinned
│   │       --replace json --insert string --at string --rewrite string --check string… --uncheck string…
│   │       --checklist check_all|uncheck_all|move_checked_down|delete_checked --[no-]pinned
│   ├── delete [ID]             Move a note to Recently Deleted (notes move brings it back; notes list --folder "Recently Deleted" lists them)
│   │       --notes json --version string
│   ├── move [ID] FOLDER        Move a note to another folder, or back from Recently Deleted
│   │       --[no-]allow-shared --notes json --version string
│   └── describe --descriptions json  Save one-line descriptions of notes, which notes list shows; many notes at once
├── tags
│   ├── rename TAG NAME         Rename a tag in every note that has it
│   └── delete TAG --expected-notes int  Take a tag out of every note that has it (ask the user first); the notes stay
├── attachments
│   └── read ID                 Open an attachment from a ![…](attachment:ID) placeholder: print its text, save its images, audio and files
│           --[no-]text-only --output-dir string
├── folders
│   ├── list                    The folders, with how many notes each holds (the default)
│   │       --depth int
│   ├── create PATH             Create a folder; a path such as Projects/Ideas makes it inside another
│   │       --tag string… --match any|all
│   ├── rename FOLDER NAME      Rename a folder
│   │       --[no-]allow-shared
│   ├── move FOLDER INTO        Move a folder into another, or to the top level with ""
│   │       --[no-]allow-shared
│   ├── delete FOLDER           Delete an empty folder, or with --recursive --expected-notes N everything in it (ask the user first)
│   │       --[no-]recursive --expected-notes int
│   └── export FOLDER TO        Write a folder and its folders as Markdown with the original attachments, to a new folder or .zip
└── call TOOL [JSON | -]        Run any tool on a JSON object of its arguments; call alone lists the tools
```

- **参数名：**字段名里的下划线换成短横线，`modified_after` 就是 `--modified-after`。
- **是非字段：**`--outline` 打开，`--no-outline` 关闭。
- **列表：**取列表的字段用单数形式重复写：`notes read --id 1A2B3C4D --id 5E6F7A8B`。
- **对象：**对象字段写 JSON：`--replace '[{"old":"- [ ] Milk","new":"- [x] Milk"}]'`。
- **从标准输入读 Markdown：**`notes create` 的 Markdown，或 `--insert`、`--rewrite` 写成 `-`，就从标准输入读，适合多行的笔记。
- **用 JSON 传字段：**`--json '{…}'` 按 MCP 的字段名传参，`--json -` 从标准输入读；同时给的参数会覆盖它。
- **任意工具：**`call TOOL '{…}'` 用 MCP 参数直接调用任意工具。
- **帮助：**命令后面加 `--help`，列出它的参数和各自的写法。

命令的输出就是工具的回答，是文本，常常是 Markdown。
- **退出码 1：**请求失败（找不到、读取后被改过、不允许），原因写在 stderr。
- **退出码 2：**命令或参数写错了。

`notes list` 不加筛选时列出最新的笔记；文件夹树用 `folders list`（也就是不带参数的 `overview`）。`attachments read` 打印附件里能读出的文字，把其中的图片、音频和文件存到 `--output-dir`（默认存进临时文件夹），并打印位置。只有第一个词决定做什么，所以可以搜索 `setup`。以 `-` 开头的词前面加 `--`。

```bash
apple-notes-mcp notes search "报税" --folder Finance
apple-notes-mcp notes read 1A2B3C4D
apple-notes-mcp notes edit 1A2B3C4D --version 3f9a0c12b7e4 --insert "- [ ] 给银行打电话" --at "待办"
apple-notes-mcp notes create - --folder Projects <<'EOF'
# 旅行计划
- [ ] 订火车票
EOF
```

## 安装

发布的包只支持 Apple 芯片，需要 macOS 26 或更新。默认用 Homebrew 安装和配置：

```bash
brew install --cask xiaofeng-han/tap/apple-notes-mcp
apple-notes-mcp setup                  # 允许它控制「备忘录」，并打开完全磁盘访问的设置
apple-notes-mcp agents set-up --all    # 把服务器注册到这台 Mac 上的 agent
```

想给 agent 装技能而不是服务器，在最后一条命令后加 `--skill`（见[服务器还是技能](#服务器还是技能)）。

后两条命令也可以换成打开「应用程序」里的 Apple Notes MCP：在「AI 助手」标签页配置 agent，在「通用」里授予权限。不用 Homebrew 的话，见[用安装包](#用安装包)。

### 用 Homebrew

像上面那样写全名，会自动添加 tap [xiaofeng-han/tap](https://github.com/xiaofeng-han/homebrew-tap)，并且只信任这一个 cask。Homebrew 6 起，第三方 tap 里的内容要先信任才会加载。之后 `brew upgrade` 就能收到新版本。

Homebrew 装的就是下面那个安装包，只是用 macOS 的安装器为所有用户安装，所以会要管理员密码，App 装在 `/Applications`。它还会添加命令 `apple-notes-mcp`（`/opt/homebrew/bin/apple-notes-mcp`），这是一个启动 App 的小脚本，下面的步骤都用它。`brew uninstall --cask apple-notes-mcp` 卸载 App，加上 `--zap` 还会把它的设置、笔记备份和描述移到废纸篓。

如果之前用安装包「仅为我安装」过，删掉那一份，并让各 agent 改用新命令（「AI 助手」标签页里每个 agent 都会显示「更新」）。两份的签名相同，权限会沿用。

```bash
rm -rf ~/Applications/AppleNotesMCP.app
pkgutil --volume ~ --forget com.xiaofeng.apple-notes-mcp.pkg
```

### 用安装包

不用 Homebrew 的话，从 [Releases](https://github.com/xiaofeng-han/apple-notes-mcp/releases) 下载 `AppleNotesMCP-<版本>.pkg` 打开安装，或者在终端里装：

```bash
gh release download v0.3.0 -R xiaofeng-han/apple-notes-mcp -p '*.pkg'
installer -pkg AppleNotesMCP-0.3.0.pkg -target CurrentUserHomeDirectory
```

选「仅为我安装」会装到 `~/Applications`，不需要管理员密码；为所有用户安装则装到 `/Applications`。安装包没有 Developer ID 签名：用浏览器下载后如果 macOS 拒绝打开，到「系统设置 → 隐私与安全性」里允许。

### 装好之后

下面的例子用的是 Homebrew 添加的命令。用安装包装的，把它换成 App 的可执行文件：`~/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP`；为所有用户安装的是 `/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP`。

```bash
apple-notes-mcp setup          # 请求控制「备忘录」（点「好」），需要时打开完全磁盘访问的设置
apple-notes-mcp --self-check   # 显示两项权限，并数一下笔记
```

完全磁盘访问要手动打开：系统设置 → 隐私与安全性 → 完全磁盘访问，打开 Apple Notes MCP；列表里没有就点 ＋ 添加（用安装包「仅为我安装」的在 `~/Applications`，其他情况在 `/Applications`）。

直接双击 App（或用 `--settings` 参数启动）会打开设置窗口。窗口会出现在最前面，停在「**AI 助手**」标签页；「**工具**」标签页选择 AI 助手能用哪些工具；「**通用**」标签页显示两项权限和授权按钮，以及窗口的语言：英文或简体中文，默认跟随系统，也可以自己选（`defaults write com.xiaofeng.apple-notes-mcp InterfaceLanguage -string zh-Hans`，或 `en`；删掉这一项就跟随系统）。agent 调用服务器时如果缺权限，服务器会打开这个窗口一次，并告诉 agent。

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

「配置」写入 `apple-notes` 这一项，并保留你在里面加的东西（环境变量、超时）。如果 agent 把服务器关掉了，「配置」会重新打开它。文件里其他内容（包括注释和格式）保持原样。用本 App 不改的写法（比如 TOML 内联表）写的条目不会动，显示为「已手动配置」。`CODEX_HOME`、`XDG_CONFIG_HOME` 这类挪动配置目录的变量，只要登录 shell 里设了就会跟着走。每天第一次修改前，旧文件会备份在旁边，名为 `<文件名>.bak-<yyyyMMdd>-apple-notes-mcp`。

安装程序和 agent 的命令运行时不带本 App 的权限，在独立的会话里，没有终端。终端里也能做同样的事：

```bash
apple-notes-mcp agents                     # 哪些 agent 装了、配了
apple-notes-mcp agents set-up --all        # 或者点名：agents set-up codex grok
apple-notes-mcp agents install opencode    # 安装后接着配置；加 --dry-run 只显示命令
```

Claude App 开着的时候，`agents set-up` 不会动它，除非加 `--restart`。

### 服务器还是技能

列表上方的「配置方式」决定 agent 怎么用这个 App：
- **MCP 服务器**（默认）：agent 启动 `apple-notes-mcp --stdio`，11 个工具一直加载着。
- **技能：**「配置」会写入一个技能 `apple-notes/SKILL.md`，教 agent 使用[命令行](#命令行)。
  - agent 只在涉及备忘录时才读它，并在自己的 shell 里运行命令，上下文里不会一直挂着工具列表。
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
- **同名技能：**不是本 App 写的同名技能 `apple-notes` 不会被改动，那一行显示「已有同名技能」。
- **服务器和技能并存：**用一种方式配置，永远不会改动另一种。一个 agent 可以两种都配，那一行会注明。
- **用不了技能的 agent：**Grok Bot 和 Gemini App 不能在这台 Mac 上运行命令。Claude App 的 Code 标签页能用技能，聊天里不能。

有些 agent 在沙盒里运行 shell 命令。Codex 默认就这样，而在它的沙盒里，macOS 不让任何程序读「备忘录」的数据库、也不让控制「备忘录」。这种情况下：
1. 命令会说明它是在沙盒里运行的。
2. 技能会让 agent 在沙盒外重新运行这条命令。
3. Codex 会请你批准。

启动 MCP 服务器的 agent 没有这个问题。

终端里也能做：

```bash
apple-notes-mcp agents list --skill                                   # 每个 agent 的技能在哪、是否最新
apple-notes-mcp agents set-up --all --skill                           # 所有已安装的 agent，所有项目都能用
apple-notes-mcp agents set-up claude-code codex --folder ~/code/app   # 只放进一个项目（--folder 隐含 --skill）
apple-notes-mcp skill                                                 # 打印技能，方便手动装到任何地方
```

### 选择开放的工具

窗口的「工具」标签页按名字列出 11 个工具，每个都写明用途并带一个标签：「只读」「修改」或「可删除」。勾上允许 AI 助手使用的工具。「全选」「全不选」「反选」「只读」（只开标着「只读」的工具）一次改动全部。选择立即保存在 `~/Library/Application Support/AppleNotesMCP/tools.json`，它在 App 之外，所以重启、更新、重装都不会丢：

```json
{
  "tools" : {
    "create_note" : true,
    "delete_note" : false,
    …
  }
}
```

改动立即生效。关掉的工具不会出现在工具列表里，硬要调用也会被拒绝，并告诉助手你可以在哪里重新打开。它对应的[命令](#命令行)也会被拒绝（退出码 1），所以用技能配置的 agent，以及你自己的终端，同样受这个选择约束。正在运行的助手会收到 `notifications/tools/list_changed`：2026-07-28 协议的客户端（Claude Code、Grok Build）在它们打开的 `subscriptions/listen` 流上收到，旧协议的客户端在初始化之后收到。Claude Code 会重新列出工具，同一个会话里就能看到变化；不理会这个通知的客户端要到新会话才会看到。这个版本之前启动的服务器不读这个文件，所以更新后把这些助手重启一次。

以后版本新增的工具（文件里还没有它的名字）默认打开，除非你关掉了同一标签的其他工具：选过「只读」之后，新增的写入类工具也保持关闭。如果文件读不了（比如手动改坏了），在修好之前不开放任何工具；在标签页里重新选择会替换它，并把坏的那份保留为 `tools.json.bak-<日期>-<时间>`。`apple-notes-mcp --self-check` 会显示开放了几个工具。没有这个文件时，全部工具都开放。

### 从源码构建

```bash
./scripts/build-app.sh
ditto dist/AppleNotesMCP.app ~/Applications/AppleNotesMCP.app
```

`./scripts/build-pkg.sh` 生成发布用的安装包 `dist/AppleNotesMCP-<版本>.pkg` 和它的 SHA-256 校验文件。发布新版本：
1. 用 `gh release create v<版本> dist/AppleNotesMCP-<版本>.pkg dist/AppleNotesMCP-<版本>.pkg.sha256` 上传安装包。
2. 运行 `./scripts/update-cask.sh`。它先确认 GitHub 上的文件和本地的一致，再把 [homebrew-tap](https://github.com/xiaofeng-han/homebrew-tap) 的本地副本（默认 `../homebrew-tap`，也可以传别的路径）里 Homebrew cask 的版本和校验和改成新的，然后提交并推送。

图标的源文件是 Icon Composer 文档 `Resources/AppIcon.icon`，图稿由 `scripts/compose-icon.swift` 用 Apple Reminders MCP 的图标合成，两个 App 看起来是一对。改了之后运行 `./scripts/build-icon.sh`（要用 Xcode 里的 `actool`），再提交 `Resources/AppIcon-compiled`；平常构建只复制这个目录。

### 权限为什么记在这个 App 名下

macOS 把子进程的隐私权限算在「责任进程」头上：不处理的话，完全磁盘访问和自动化得授予每一个启动服务器的程序（终端、Claude、Codex……）。所以 App 一启动就放弃这层责任关系，以自己的身份再启动一次（`Sources/Launcher`），stdin 和 stdout 原样交给新进程。这样权限只需授予一次「Apple Notes MCP」，与谁启动它无关。

要用真实路径启动它，或者像 Homebrew 的 `apple-notes-mcp` 那样用脚本 `exec` 它，不要经符号链接启动（那样 macOS 找不到 App 包）。

### 签名

`build-app.sh` 默认用登录钥匙串里的自签名证书「Xiaofeng Local Code Signing」签名（`SIGNING_IDENTITY` 可以换）。签名要求是「bundle id + 证书」，所以重新编译后权限还在；用 ad-hoc 签名的话，每次重新编译都要重新授权。在新 Mac 上建这张证书的方法见 [Apple Reminders MCP 的 README](https://github.com/xiaofeng-han/apple-reminders-mcp/blob/main/README.zh-CN.md#签名)。

## 注册到客户端

App 的「AI 助手」标签页或 `apple-notes-mcp agents set-up` 会替你做这件事。手动注册的话：用 Homebrew 装的，命令是 `/opt/homebrew/bin/apple-notes-mcp`；用安装包「仅为我安装」的，是 `~/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP`（为所有用户安装的是 `/Applications/…`），运行时加 `--stdio`，要写完整路径。服务名 `apple-notes`。服务器支持 MCP 的会话协议（2024-11-05 到 2025-11-25）和无状态的 2026-07-28 协议。

- Claude Code：`claude mcp add -s user apple-notes -- <命令> --stdio`
- Codex（`~/.codex/config.toml`，ChatGPT App 共用）、Grok Build（`~/.grok/config.toml`，另加 `enabled = true`）：

  ```toml
  [mcp_servers.apple-notes]
  command = "/opt/homebrew/bin/apple-notes-mcp"
  args = ["--stdio"]
  ```

- Claude App、Gemini CLI、Antigravity：`"mcpServers": {"apple-notes": {"command": "<命令>", "args": ["--stdio"]}}`
- OpenCode（`~/.config/opencode/opencode.json`）：`"mcp": {"servers": {"apple-notes": {"type": "local", "command": ["<命令>", "--stdio"]}}}`
- pi（`~/.pi/agent/mcp.json` 的 `mcpServers`）：`{"type": "stdio", "command": "<命令>", "args": ["--stdio"]}`

手动装技能：把 `apple-notes-mcp skill` 的输出存成 agent 技能文件夹里的 `apple-notes/SKILL.md`（见[服务器还是技能](#服务器还是技能)）。

调试时设 `APPLE_NOTES_MCP_WIRE_LOG=<文件>`，会记下收发的每条消息。

## 测试

```bash
/usr/bin/python3 -I scripts/e2e.py                              # 已安装的 App，针对真实的备忘录
/usr/bin/python3 -I scripts/e2e.py .build/debug/AppleNotesMCP   # 开发版（用启动它的程序的权限）
swift test
apple-notes-mcp --check-markdown                                # 每条笔记写成 Markdown 再读回来是否不变（只读）
```

`e2e.py` 经 stdio 跑遍所有工具，再跑一遍主要的命令行命令，共 145 项检查，开着写保护（`APPLE_NOTES_MCP_WRITE_GUARD=agent test`：只有标题以「agent test」开头的笔记、名字以它开头的文件夹能改）。它在自己建的文件夹「agent test」里操作，最后连同其中内容一起删掉，所以只在「最近删除」里留下它的笔记。为了检查 `read_attachment` 和对识别文字的搜索，它会读你的一张图片；如果有带文字稿的录音，也会读一段。工具选择读的是一个临时文件（`APPLE_NOTES_MCP_TOOLS_FILE`），所以既不受你的选择影响，也不会改动它。`swift test` 检查以下几项，涉及文件的都在临时目录里进行：
- Markdown 转换，包括每种行都能原样读回；
- 修改计划，以及存储正文的解码；
- agent 配置：保持文件其余部分原样的 JSON 和 TOML 编辑、各 agent 设置的读写、各 agent 技能的位置；
- 命令行参数如何从工具的输入 schema 读出；
- 工具选择：文件里没写到的工具按什么规则处理、文件的读写与监视，以及服务器列出、拒绝和通知了什么。

## 做不到的

- 附件只能读，不能添加或删除（表格除外）。
- 不能移动文件夹：「备忘录」AppleScript 的 `move folder` 报告成功，实际却删掉了文件夹，所以从不使用。
- 加锁的笔记读不了（正文用用户的密码加了密）。
- 如果某个表格在当前这次打开的「备忘录」里被手动编辑过，原地修改它不会上传；这时服务器会用相同内容重建它，表格里的格式会丢失。
- 「备忘录」把自己的改动写回数据库有延迟，所以服务器会记住自己删除或改名的笔记和文件夹，直到数据库跟上。

`docs/RE-FINDINGS.md` 是这个项目最初的逆向结论。
