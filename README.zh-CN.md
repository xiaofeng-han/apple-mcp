# Apple Reminders MCP

[English](README.md) | **简体中文**

让 AI agent（Claude Code、Codex、Grok Build、pi……）完整地读写 macOS 上的「提醒事项」的 MCP 服务器。

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
| `find_reminders` | 跨清单查找：清单、分区、关键词、已完成、旗标、紧急、重复、有地点提醒、指派给谁、标签、到期时间窗口（`due_before` 不含当天） |
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

## 安装

从 [Releases](https://github.com/xiaofeng-han/apple-reminders-mcp/releases) 下载 `AppleRemindersMCP-<版本>.pkg` 打开安装，或者在终端里装：

```bash
gh release download v0.2.0 -R xiaofeng-han/apple-reminders-mcp -p '*.pkg'
installer -pkg AppleRemindersMCP-0.2.0.pkg -target CurrentUserHomeDirectory
```

选「仅为我安装」会装到 `~/Applications`，不需要管理员密码，下面的命令都假定 App 在那里。发布的包只支持 Apple 芯片。安装包没有 Developer ID 签名：用浏览器下载后如果 macOS 拒绝打开，到「系统设置 → 隐私与安全性」里允许。

然后授权访问提醒事项：

```bash
~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP setup
```

`setup` 会弹出授权窗口（可能被别的窗口挡住），点「允许」。检查状态：

```bash
~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP --self-check
```

直接双击 App（或用 `--settings` 参数启动）会打开设置窗口。窗口里能看到两项权限的状态、「允许 AI 助手勾完成重复提醒」开关（默认打开），以及窗口的语言：英文或简体中文，默认跟随系统，也可以自己选。这两项设置也可以用命令改：

```bash
defaults write com.xiaofeng.apple-reminders-mcp AllowCompletingRecurringReminders -bool NO
defaults write com.xiaofeng.apple-reminders-mcp InterfaceLanguage -string zh-Hans   # 或 en；删掉这一项就跟随系统
```

授权弹窗是 macOS 自己的，总是跟随系统语言。

完全磁盘访问要手动添加：系统设置 → 隐私与安全性 → 完全磁盘访问，点 ＋，选 `~/Applications/AppleRemindersMCP.app`。

### 从源码构建

```bash
./scripts/build-app.sh
ditto dist/AppleRemindersMCP.app ~/Applications/AppleRemindersMCP.app
```

`./scripts/build-pkg.sh` 生成发布用的安装包 `dist/AppleRemindersMCP-<版本>.pkg` 和它的 SHA-256 校验文件。

图标的源文件是 Icon Composer 文档 `Resources/AppIcon.icon`。改了之后运行 `./scripts/build-icon.sh`（要用 Xcode 里的 `actool`），再提交 `Resources/AppIcon-compiled`；平常构建只复制这个目录。图稿要画成铺满的正方形，由 macOS 裁成它的圆角形状：自己画了形状、四周透明的图标，会被缩小放进一个灰色底框里。`swift scripts/flatten-icon.swift <图标.png> Resources/AppIcon.icon/Assets/artwork.png` 能把「透明背景上画一个圆角方块」的图标转成这种图稿。

### 权限为什么记在这个 App 名下

macOS 把子进程的隐私权限算在「责任进程」头上。Claude Code 和 Claude Desktop 的 Info.plist 里没有提醒事项的用途说明，由它们直接启动的程序访问提醒事项会被静默拒绝。所以 App 一启动就放弃这层责任关系，以自己的身份再启动一次（`Sources/Launcher`），stdin 和 stdout 原样交给新进程。这样权限只需授予一次「Apple Reminders MCP」，与谁启动它无关。

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

命令都是 `~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP --stdio`，服务名 `apple-reminders`。服务器支持 MCP 的会话协议（2024-11-05 到 2025-11-25）和无状态的 2026-07-28 协议。

- Claude Code：`claude mcp add -s user apple-reminders -- <命令> --stdio`
- Codex（`~/.codex/config.toml`，Codex App 共用）、Grok Build（`~/.grok/config.toml`，另加 `enabled = true`）：

  ```toml
  [mcp_servers.apple-reminders]
  command = "/Users/<you>/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP"
  args = ["--stdio"]
  ```

- pi（`~/.pi/agent/mcp.json` 的 `mcpServers`）：`{"type": "stdio", "command": "<命令>", "args": ["--stdio"]}`

验证：`claude mcp list`、`grok mcp doctor`、`pi mcp list`。调试时设 `APPLE_REMINDERS_MCP_WIRE_LOG=<文件>` 可以记录收发的每条消息。

## 测试

```bash
/usr/bin/python3 -I scripts/e2e.py
```

通过 stdio 把所有工具和规则走一遍，共 121 项检查。写保护（`APPLE_REMINDERS_MCP_WRITE_GUARD`，用逗号分隔多个名字，清单、分组、智能清单、模板都算）把写入限制在几个临时名字里（`agent test`、`agent test 2`…）。测试开头会清掉上次中断留下的数据，结尾也会删掉自己建的；「最近删除」里会留下测试项。测试会临时改动「勾完成重复提醒」设置，结束时恢复默认。

## 做不到的

- 邀请别人共享清单：需要 iCloud 的共享界面，程序没法替用户完成。
- 读取提醒在清单里的手动顺序：能调整顺序，但读出来的结果不带顺序。
- 智能清单里本工具不认识的条件（比如系统以后新增的）：`list_lists` 会把它们原样放在 `filters.other` 里，但不能用工具修改。
