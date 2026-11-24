# Apple Contacts MCP

[English](contacts.md) | **简体中文**

属于 [apple-mcp](../README.zh-CN.md)，这个仓库里还有 [Apple Notes MCP](notes.zh-CN.md)、[Apple Reminders MCP](reminders.zh-CN.md) 和 [Apple Journal MCP](journal.zh-CN.md)。

一个 MCP 服务器，让 AI agent（Claude Code、Codex、Grok Build、OpenCode、Gemini CLI、pi 等）在 Mac 上读写苹果的「通讯录」。每个工具也是一条命令行命令，所以 agent 也可以用技能而不用服务器。它的设置窗口会找到 Mac 上的 agent，一键按其中一种方式配置好。

它走「通讯录」自己的框架：Contacts.framework，以及 Contacts.app 至今仍在用的老框架 AddressBook；macOS 不让别的 App 碰的那一样东西——备注——走「通讯录」的 AppleScript。agent 写进去的是普通的通讯录数据，由「通讯录」经 iCloud（或 Google、Exchange、CardDAV）同步到所有设备：
- 个人和公司的全部字段：姓名（含拼音、娘家姓和姓名顺序）、公司、部门、职位、备注、电话、电子邮件、网址、地址、生日和另一种历法的生日、其他日期、关联人、社交资料、即时通讯账号、头像及其裁剪、电话铃声和短信提示音、紧急绕过，以及屏幕使用时间「停用时间」里能否联系到用户；
- 链接的卡片（同一个人在几个账户里各有一张卡）：链接、取消链接、由哪张卡提供姓名和头像；合并重复的卡片；
- 分组、嵌套分组和它们的分发列表；带规则的智能分组；
- 我的名片、账户（新联系人进哪个账户、立即同步）、「通讯录」的设置、变更历史、vCard 导入和导出；
- 删除的每个联系人都留一份副本，保留 30 天，因为「通讯录」没有「最近删除」。

需要两项权限：通讯录，以及「自动化 → 通讯录」（用来读写备注）。

需要 Apple 芯片和 macOS 26 或更新；在 macOS 27.2、「通讯录」14.0 上测试过。所有代码都为这个项目而写，没有第三方依赖。

## 能做什么

| 通讯录 | 这里 |
|---|---|
| 卡片：全部字段，包括备注和头像；个人和公司 | ✅ `create_contact`、`update_contact`、`read_contact` |
| 搜索（每个词出现在卡片任意位置，同「通讯录」的搜索栏），按电话、邮件、分组、智能分组、账户、类型；把智能分组的规则当搜索条件 | ✅ `find_contacts` |
| 删除；找回（「通讯录」自己做不到） | ✅ `delete_contact`、`restore_contact`（30 天内） |
| 链接的卡片：链接、取消链接、由哪张卡提供姓名或头像 | ✅ `link_contacts` |
| 查找重复项、合并所选卡片 | ✅ `find_duplicates`、`merge_contacts` |
| 分组：新建、改名、删除、成员、嵌套、分发列表 | ✅ `list_groups`、`manage_group` |
| 智能分组：新建、改规则或高亮、删除 | ✅ `manage_smart_list`；在 `list_groups` 里读 |
| 设为我的名片 | ✅ `set_my_card` |
| 账户：数量、默认账户、刷新账户 | ✅ `overview`、`manage_accounts` |
| 导入导出 vCard（带备注和头像）、共享我的名片 | ✅ `import_contacts`、`export_contacts` |
| 设置：排序、地址格式、vCard 选项、我的名片隐私 | ✅ `settings` |
| 上次之后在任一设备上改了什么 | ✅ `contact_changes` |
| 头像、原图和海报图片 | ✅ `read_photo` 读取；头像和裁剪由 `create_contact`、`update_contact` 写 |
| 代词、个人收藏、阻止、紧急联系人、联系人海报、名字和照片共享 | ❌ 见[做不到的](#做不到的) |
| 家庭成员（孩子）的账户 | ❌ |
| 添加或移除账户、为某个账户开关通讯录同步 | ❌ 在「系统设置 → 互联网账户」里 |
| 打印（列表、信封、标签）、导入 CSV 和 LDIF | ❌ |

## 工具

| 工具 | 做什么 |
|---|---|
| `overview` | 各账户（iCloud、Google、我的 Mac 上等）各有多少张卡片、新联系人进哪个账户；一共多少联系人（跨账户链接的卡片算一个）；分组和智能分组；我的名片 |
| `find_contacts` | 按「通讯录」的排序列出联系人，每个带 id 和版本：`query` 的每个词出现在卡片任意位置（不分大小写和重音）、`phone` 或 `email`（整个号码或地址，任何格式）、`group`（含嵌套分组）、`smart_list`、`account`、`type`，或 `criteria`（智能分组规则）；用 `limit` 和 `offset` 翻页 |
| `read_contact` | 最多 20 个联系人的全部内容：所有字段、备注、所在分组、有没有头像或海报、提示音，以及各张卡片（在哪个账户、哪张提供姓名和头像、各自的备注），带版本 |
| `read_photo` | 「通讯录」显示的头像、裁剪前的原图，或海报的图片 |
| `list_groups` | 按账户、照「通讯录」侧边栏的嵌套列出分组及其数量，以及智能分组和规则；给出 `group` 时列它的成员（`nested` 连同嵌套分组的成员）和分发列表 |
| `find_duplicates` | 看起来是同一个人的卡片：同一账户里同名，或（`by: email_or_phone`）共用一个邮件地址或电话号码 |
| `contact_changes` | 从「通讯录」变更历史的某个令牌以来，任一设备上新增、修改、链接或删除的联系人和分组；不给 `since` 就只给令牌，下次传回来。默认不含这个 App 经 Contacts.framework 做的保存，`include_own` 可包括；它经「通讯录」本身或 AddressBook 改的备注、分组成员、链接和智能分组，和其他改动一样列出 |
| `create_contact` | 用任意字段新建个人或公司，放进某个账户（默认是「通讯录」的默认账户）和分组 |
| `update_contact` | 只改给出的字段；`null` 清空一个字段（在每张链接的卡片上），列表会整个替换。链接的联系人，每个值留在它所在的卡片上，两张卡共有的值两张都留；新值和改动的字段写到提供姓名的卡片，或 `card` 指定的卡片。写法不同（大小写、空格、标点）的同一个值改用新写法 |
| `delete_contact` | 从所有设备上删除一个联系人（它的所有卡片，或只删 `card`），留副本 30 天 |
| `restore_contact` | 列出留着的副本，或把其中一个带着 id、字段、备注、头像和分组放回原账户 |
| `manage_group` | 新建分组（在某个账户、某个分组里、带成员），改名或删除（联系人保留），添加或移除成员，嵌套或取消嵌套，以及选定某个成员在这个分组里用哪个邮件、电话或地址（`distribution`） |
| `manage_smart_list` | 新建、修改（名称、规则、高亮）或删除智能分组 |
| `link_contacts` | 把几张卡片链接成一个联系人，取消链接一张卡或一个联系人的所有卡，或让某张卡提供联系人的姓名（`prefer_name`）或头像（`prefer_photo`） |
| `merge_contacts` | 照「合并所选卡片」把几张卡合进第一张：每个值都保留、空字段补上、备注连起来、头像保留、分组加上，其余卡片删除（并留副本 30 天）。在其他账户的卡片改为链接 |
| `set_my_card` | 把一个联系人设为我的名片，Safari 自动填充、信息等 App 会用它 |
| `manage_accounts` | 设定新联系人进哪个账户，或让「通讯录」立即同步账户 |
| `import_contacts` | 把 `.vcf` 文件（带备注和头像）导入某个账户和分组；和那里已有卡片同名的，默认跳过并列出，也可以合并进去（`update`）、照样添加（`keep_both`）或取而代之（`replace`：新卡片加入旧卡片的分组，删掉旧的并保留 30 天，然后把新卡片链接到旧卡片的其他卡片，旧的是我的名片就设新的为我的名片；后面这两步失败时以警告说明）。中途出错时，错误里会说之前导入了什么 |
| `export_contacts` | 写一个新的 `.vcf` 文件：选定的联系人、某个分组或智能分组的、匹配搜索的、我的名片，或全部；vCard 3.0 或 2.1，默认带备注和头像 |
| `settings` | 「通讯录」的设置：排序、姓名显示和简称、地址格式、vCard 导出选项、我的名片隐私、Siri 建议；可改排序、地址格式、vCard 选项和我的名片隐私 |

每次修改联系人都要传回 `read_contact` 或 `find_contacts` 给的 `version`；在那之后（在「通讯录」里、在其他设备上）改过的联系人会被拒绝，所以 agent 不会覆盖它没读过的内容。版本涵盖显示出来的所有字段，包括备注，但不包括分组。

`create_contact` 和 `update_contact` 在「通讯录」把改动上传到 iCloud（或账户的服务器）之后回答，带 `"uploaded": true`，通常 10 到 15 秒，最多 45 秒（带头像 90 秒）；`wait: false` 在这台 Mac 上保存好就回答。其他写操作在这台 Mac 上保存好就回答，「通讯录」在后台上传。iCloud 有时在上传后马上把卡片稍作改动再送回来（头像另存、个别服务名按它的写法，例如 Skype 变成 `SkypeInstant`），所以下次修改前要重新读一遍。

### 联系人字段

| 字段 | 格式 |
|---|---|
| `type` | `person` 或 `company`（标记为公司：卡片显示公司名） |
| 姓名 | `prefix`、`first_name`、`middle_name`、`last_name`、`maiden_name`、`suffix`、`nickname`、`phonetic_first_name`、`phonetic_middle_name`、`phonetic_last_name`；`name_order`：`default`、`given_first` 或 `family_first` |
| 工作 | `organization`、`phonetic_organization`、`department`、`job_title` |
| `note` | 纯文本，最多约 150,000 个字符（iCloud 的上限） |
| `phones`、`emails`、`urls` | `{label, value}` 的列表 |
| `addresses` | `{label, street, sub_locality, city, sub_administrative_area, state, postal_code, country, country_code}` 的列表；街道的多行用 `\n` 分开；`country_code` 决定地址格式 |
| `birthday` | `1990-05-17`，不知道年份时 `05-17` |
| `other_birthday` | 另一种历法的生日（「通讯录」的农历生日）：`{calendar, year, month, day, leap_month}`，历法有 `chinese`、`hebrew`、`islamic` 以及「通讯录」提供的其他历法 |
| `dates` | `{label, value}` 的列表，`2015-06-01` 或 `06-01` |
| `related_names` | `{label, value}` 的列表：关系和对方的名字 |
| `social_profiles` | `{label, service, username, user_id, url}` 的列表 |
| `instant_messages` | `{label, service, username}` 的列表 |
| `photo` | JPEG、PNG 或 HEIC 文件的绝对路径（不超过 20 MB）；`null` 去掉头像。`photo_crop` 和 `photo` 一起给：`[x, y, width, height]`，以图片左上角为原点的像素（命令行上 `--photo-crop` 写四次），默认居中的正方形 |
| `ringtone`、`text_tone` | 提示音 id（`system:Opening`、`texttone:Note` 等）、`<default>` 或 `<none>` |
| `emergency_bypass` | `off`、`calls`、`texts` 或 `both`：静音或专注模式下，对方的来电或短信照样响 |
| `downtime_allowed` | 屏幕使用时间：「停用时间」里对方仍能联系到用户（见[工作原理](#工作原理)） |
| `account`、`groups` | 新建时：账户（名称或 id）和分组（在该账户里） |

标签用英文词：电话 `mobile`、`iPhone`、`home`、`work`、`school`、`main`、`home fax`、`work fax`、`pager`、`Apple Watch`、`other`；邮件 `home`、`work`、`school`、`iCloud`；网址 `homepage`；日期 `anniversary`；关联人可用「通讯录」200 多种关系中的任何一种（`mother`、`spouse`、`brother in law`、`grandfather fathers father` 等）。其他文字就是自定义标签。读出来时也是这样写。

### 备注

macOS 只把联系人的备注给苹果授权过的 App（「通讯录」「电话」「信息」），所以 Contacts.framework 对这个 App 隐藏备注，也拒绝保存带备注的卡片。这个 App 通过「通讯录」的 AppleScript 读写备注，第一次会请求「自动化 → 通讯录」权限；「通讯录」没在运行时会隐藏启动。要保存带备注卡片的其他改动，会先把备注放到一边：存进 `~/Library/Application Support/AppleContactsMCP/notes-aside.json`，用 AppleScript 去掉，保存卡片，再放回备注（或写入新备注）。「通讯录」把结果当一次改动上传。同一时间只有一个进程在放备注（文件旁边有一把锁），所以两个 agent、或者 agent 和命令行，不会互相撤销。如果 App 在中途停掉，或者「通讯录」没有马上接受备注，下一次调用会从那个文件放回；「通讯录」还在启动时，App 会等它，而不会把卡片当成不存在。

### 链接的卡片

一个联系人可以是几张链接在一起的卡片，通常每个账户一张；「通讯录」把它们显示成一个。`read_contact` 列出各张卡片：在哪个账户、哪张提供姓名和头像、每张卡的备注。`id` 可以是联系人的，也可以是其中某张卡片的。`update_contact` 在值所在的卡片上改它，新值加到提供姓名的卡片（或 `card`）；删除链接的联系人会删掉每张卡，除非 `card` 指定了一张。链接走 AddressBook，因为在长时间运行的进程里，卡片被别的进程改过之后，Contacts.framework 的链接会失败。

### 分组和智能分组

分组属于一个账户，只装这个账户的卡片，所以新建时的 `groups` 和 `members` 要求联系人在那里有卡片。成员通过「通讯录」的 AppleScript 添加和移除（Contacts.framework 对某些移除只答应不照做），之后再核对。嵌套分组和分发列表（给分组发信时，每个成员用哪个邮件、电话或地址）是「通讯录」自己的功能；分发列表的选择只留在这台 Mac 上。

智能分组装着所有符合规则的联系人，同「文件 > 新建智能分组」：

```json
{"match": "all", "rules": [
  {"field": "organization", "op": "contains", "value": "Acme"},
  {"field": "birthday", "op": "next_days", "value": 30},
  {"match": "any", "rules": [{"field": "group", "op": "member_of", "value": "Family"},
                             {"field": "email", "op": "ends_with", "value": "@acme.com"}]}]}
```

字段：`any`（卡片上任何文字；`contains`、`not_contains`）；`name`、`first_name`、`last_name`、`middle_name`、`nickname`、`organization`、`department`、`job_title`、`note`、`phone`、`email`、`url`、`instant_message`、`street`、`city`、`state`、`zip`、`country`（用 `contains`、`not_contains`、`is`、`is_not`、`is_set`、`is_not_set`；电话、邮件、网址和即时通讯还可用 `starts_with`、`ends_with`）；`address`（`contains`、`not_contains`、`is_set`、`is_not_set`）；`birthday`、`anniversary`、`date`（`next_days`、`within_days`、`not_within_days` 加天数；`is_set`、`is_not_set`）；`modified`（`changed_within_days`、`not_changed_within_days`；`after` 某个日期）；`group`（`member_of`、`not_member_of` 某个分组或智能分组）。`find_contacts` 也接受同样的 `criteria`，可以先看看智能分组会装哪些人再建。「通讯录」把智能分组放在这台 Mac 上（我的 Mac 上），不同步。

### 删除和找回

「通讯录」删除卡片会立刻从所有设备上删掉，也没有「最近删除」。`delete_contact` 或 `merge_contacts` 删卡片之前，这个 App 先留一份副本（所有字段、备注、头像、分组、账户），放在 `~/Library/Application Support/AppleContactsMCP/Deleted/`，保留 30 天。`restore_contact` 不给 id 时列出它们；给了 id 就用原来的 id 放回去，所以指向它的链接（在「信息」「日历」、关联人里）照样有效，然后放回分组和备注。如果中途停下（比如还没允许自动化），再调用一次就把剩下的做完。删除本身失败时，副本会再被删掉。

## 命令行

每个工具都是一条命令：`apple-contacts-mcp help` 打印命令树，任何命令都能加 `--help`。

```bash
apple-contacts-mcp accounts list                                       # 账户、数量、分组、我的名片
apple-contacts-mcp contacts search "jane acme"                          # 每个词出现在卡片任意位置
apple-contacts-mcp contacts search --phone "+1 555 0100"
apple-contacts-mcp contacts list --group Family --type person
apple-contacts-mcp contacts read ID
apple-contacts-mcp contacts create --first-name Jane --last-name Doe --organization Acme \
    --phones '[{"label":"mobile","value":"+1 555 0100"}]' --birthday 05-17 --group Family
apple-contacts-mcp contacts update ID --version VERSION --job-title Designer --note "Met at WWDC"
apple-contacts-mcp contacts update ID --version VERSION --photo ~/Pictures/jane.heic
apple-contacts-mcp contacts update ID --version VERSION --no-nickname        # 清空一个字段
apple-contacts-mcp contacts delete ID --version VERSION                      # 副本保留 30 天
apple-contacts-mcp contacts deleted
apple-contacts-mcp contacts restore ID
apple-contacts-mcp contacts duplicates
apple-contacts-mcp contacts merge --id A --version VA --id B --version VB
apple-contacts-mcp contacts link --id CARD1 --id CARD2
apple-contacts-mcp contacts photo ID --which full --output ~/Desktop/jane.jpg
apple-contacts-mcp contacts changes --since TOKEN
apple-contacts-mcp contacts export ~/Desktop/family.vcf --group Family
apple-contacts-mcp contacts import ~/Downloads/cards.vcf --group Imported --duplicates update
apple-contacts-mcp groups create "Book club" --member ID --member ID
apple-contacts-mcp groups nest "Book club" --parent Friends
apple-contacts-mcp groups distribution "Book club" --member ID --email jane@work.example
apple-contacts-mcp smart-lists create "Birthdays soon" --criteria '{"rules":[{"field":"birthday","op":"next_days","value":14}]}'
apple-contacts-mcp settings set --sort-by first_name
```

命令打印工具的 JSON 回答，有时前面有一句简短的说明，例如 `Created.`。退出码 1 表示请求失败（找不到、读过之后被改过、不允许），原因在 stderr；2 表示命令或参数写错。每条命令都接受 `--json '{...}'`（或 `--json -` 从 stdin 读），字段用 snake_case 名。`--note -` 从 stdin 读备注。

## 安装

发布版为 Apple 芯片构建。默认用 Homebrew 安装和配置：

```bash
brew install --cask xiaofeng-han/tap/apple-contacts-mcp
apple-contacts-mcp setup                  # 请求通讯录和「自动化 → 通讯录」权限
apple-contacts-mcp agents set-up --all    # 把服务器注册到这台 Mac 上的 agent
```

要给 agent 装技能而不是服务器，在最后一条命令后加 `--skill`。也可以不跑后两条命令，而是在「应用程序」里打开 Apple Contacts MCP：在「AI 助手」标签页配置 agent，在「通用」里给两项权限。

不用 Homebrew 的话，从 [Releases](https://github.com/xiaofeng-han/apple-mcp/releases) 下载 `AppleContactsMCP-<版本>.pkg` 打开，或在终端里安装：

```bash
gh release download contacts-v0.0.0 -R xiaofeng-han/apple-mcp -p '*.pkg'
installer -pkg AppleContactsMCP-0.0.0.pkg -target CurrentUserHomeDirectory
```

只为自己安装会放到 `~/Applications`，不需要管理员密码。App 和安装包没有 Developer ID 签名；cask 会去掉隔离属性，浏览器下载的安装包要在「系统设置 → 隐私与安全性」里允许。

### 装好之后

`setup`（或窗口里的「通用」）会请求两项权限，macOS 弹出它自己的提示。如果拒绝过，到「系统设置 → 隐私与安全性 → 通讯录」打开，以及「→ 自动化 → Apple Contacts MCP → 通讯录」。检查一下：

```bash
apple-contacts-mcp --self-check
```

它打印两项权限、各账户及其数量、分组和智能分组，以及留着多少个删除的联系人。

窗口的「AI 助手」标签页、「配置方式」（服务器或技能）和「工具」标签页和其他 App 一样；见[配置 AI 助手](reminders.zh-CN.md#配置-ai-助手)、[服务器还是技能](reminders.zh-CN.md#服务器还是技能)和[选择开放的工具](reminders.zh-CN.md#选择开放的工具)，把其中的名字换成 `apple-contacts-mcp`、服务器名 `apple-contacts`、技能 `apple-contacts/SKILL.md` 和 `~/Library/Application Support/AppleContactsMCP/tools.json`。手动配置时，命令是 `/opt/homebrew/bin/apple-contacts-mcp --stdio`（或 App 的可执行文件 `AppleContactsMCP.app/Contents/MacOS/AppleContactsMCP`）；例如 `claude mcp add -s user apple-contacts -- /opt/homebrew/bin/apple-contacts-mcp --stdio`。

在沙盒里运行命令的 agent（Codex 就是）从沙盒里碰不到「通讯录」；技能会告诉它们到沙盒外运行，这可能需要你批准。

### 从源码构建

```bash
./scripts/build-app.sh contacts
ditto dist/AppleContactsMCP.app ~/Applications/AppleContactsMCP.app
```

`./scripts/build-pkg.sh contacts` 构建发布用的安装包，`scripts/release.sh contacts <版本>` 发版，和 [Apple Reminders MCP](reminders.zh-CN.md#从源码构建) 里写的一样，发布说明取自 [`CHANGELOG-contacts.md`](../CHANGELOG-contacts.md)，tag 是 `contacts-v<版本>`。图标是 `Resources/Contacts/AppIcon.icon`：`swift scripts/compose-icon.swift Resources/Reminders/AppIcon.icon/Assets/artwork.png Resources/Contacts/AppIcon.icon/Assets/artwork.png contacts`，然后 `./scripts/build-icon.sh contacts`。

### 为什么权限记在这个 App 名下

和其他 App 一样，它放弃 macOS 记在启动者名下的责任，以自己的身份重新启动，所以通讯录和自动化权限只授予一次，给「Apple Contacts MCP」，不管是哪个 agent 启动它。要通过真实路径或 `exec` 它的脚本启动，不要通过符号链接。

## 工作原理

- **卡片、分组和账户**走 Contacts.framework（`CNContactStore`、`CNSaveRequest`），卡片逐张读（不合并），所以每个值都留在它原来的卡片上。一个小的 Objective-C target `ContactsShim` 调用 Contacts.app 用到的框架私有部分：提示音、停用时间、姓名顺序、头像裁剪、链接偏好、全文搜索、带备注的 vCard 导出、用原 id 恢复卡片，以及姓名设置。保存时把这个 App 标为作者，所以 `contact_changes` 能把它们排除。
- **屏幕使用时间。**对别的 App，Contacts.framework 把「停用时间」里允许的卡片当成只读（CNErrorDomain 206）。这个 App 像 Contacts.app 一样保存这种卡片，让框架忽略监护限制，但只对这些卡片，而且不在由监护人管理的账户里（孩子的屏幕使用时间），那里的拒绝照样有效。「通讯录」的 AppleScript 根本存不了这种卡片：保存失败后，「通讯录」会把这次和之后的所有改动都留着不存，直到它退出。所以这个 App 从不经 AppleScript 写这种卡片：拒绝修改停用时间里允许的联系人的备注（以及它有备注时的任何改动），加入分组走框架，拒绝把它移出分组；有备注的联系人不能从这里设为停用时间里允许，带备注恢复的这种联系人回来时不再被允许。每次 AppleScript 写入也都核对「通讯录」是否存好了，卡住时会如实说明。
- **智能分组、分发列表、链接、默认账户和同步**走 AddressBook.framework，Contacts.app 至今仍用它做这些。它的智能分组规则（`ABSearchElement`）和上面的 `criteria` 互相转换。
- **备注和分组成员**走「通讯录」的 AppleScript，只编译一次，用 Apple 事件调用；见[备注](#备注)。分组成员这样加，是因为别的进程刚保存的卡片还不在 Contacts.app 自己的副本里，所以新卡片先经 Contacts.framework 加进分组。
- **上传。**「通讯录」自己的守护进程上传每次改动。这个 App 看每张卡片的 CardDAV ETag（Contacts.framework 的 `externalModificationTag`），服务器接受卡片时会换一个新的，然后再等卡片稳定下来，因为 iCloud 可能把它改过再送回来。
- **版本**是 `read_contact` 所显示联系人的哈希，不含分组和时间。
- **不需要「通讯录」的部分**在单独的 target `ContactsModel` 里：agent 看到的工具、命令、日期、标签、智能分组规则、修改链接联系人列表字段的方案、版本和写入保护。`ContactsComponent` 实现每个工具。单元测试（`ContactsModelTests`）只依赖 `ContactsModel`。
- 逆向笔记在 [RE-FINDINGS-contacts.md](RE-FINDINGS-contacts.md)。

## 测试

```bash
/usr/bin/python3 -I scripts/e2e.py contacts                                # 已安装的 App，针对你真实的通讯录
/usr/bin/python3 -I scripts/e2e.py contacts dist/AppleContactsMCP.app/Contents/MacOS/AppleContactsMCP
```

检查经 stdio 跑工具和主要命令，共 80 项，写入保护（`APPLE_CONTACTS_MCP_WRITE_GUARD=agent test e2e`）把写操作限制在名字以 `agent test e2e` 开头的联系人、分组和智能分组上。它们在默认账户（iCloud，所以你的其他设备会看到它们出现又消失）里建临时联系人，带大部分字段、备注、头像、紧急绕过和停用时间、链接，还有一个分组和一个智能分组；检查上传、版本、搜索、链接的联系人、合并、删除和找回、导入（包括 replace）和导出；读一遍 `find_duplicates` 和 `settings`；最后把这些和留下的副本全部删掉。`set_my_card`、`manage_accounts` 和修改 `settings` 不在其中，因为它们会改你自己的设置。要用签过名的构建（`build-app.sh`）跑，权限在它名下；裸的 `swift build` 可执行文件两项权限都没有。`swift test` 检查日期、标签、链接联系人的修改方案、版本、写入保护、智能分组规则，以及命令和工具是否对得上。

## 做不到的

- **代词。**「通讯录」把它加密存放，只有苹果授权的 App 能读。
- **个人收藏、阻止、紧急联系人、「通讯录」里的 Siri 建议。**它们属于「电话」、阻止列表和「健康」，各有这个 App 拿不到的授权。（卡片上的字段「紧急绕过」是支持的。）
- **联系人海报、名字和照片共享。**能读海报的图片；做海报和共享由「电话」和「信息」完成。
- **家庭成员的账户。**家人共享在家长 Mac 上显示的孩子联系人来自一个只对苹果 App 开放的服务（FamilyCircle）。
- **添加或移除账户、为某个账户开关通讯录。**在「系统设置 → 互联网账户」里。
- **打印**（列表、信封、标签、袖珍通讯录）、**导入 CSV 和 LDIF**，以及导入时「通讯录」的**重复项检查界面**。它们在 Contacts.app 本身里，不在它的框架里；`import_contacts` 有自己的重复处理。
- **会同步的智能分组，以及在其他设备上的分发列表选择。**「通讯录」把两者都只放在这台 Mac 上。
- **停用时间里允许的联系人的备注**、它有备注时的任何改动、把它移出分组，以及把有备注的联系人设为停用时间里允许。「通讯录」的 AppleScript 存不了这种卡片，框架又不给备注；这些请在「通讯录」里改。
