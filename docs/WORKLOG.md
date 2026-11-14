# apple-mcp 工作日志：问题与解决

从逆向「通讯录」、做 Apple Contacts MCP 起，遇到的每个问题、原因、最终解法和验证方式。按时间排列，每条有编号（P01…），用编号或关键词搜就能找到。

- **范围：** 2026-11-13 08:30 开始。之前三个 App（Notes、Reminders、Journal）的经过在各自的 RE-FINDINGS 和 CHANGELOG 里，不补记。
- **时间：** 一律是太平洋时间（America/Los_Angeles）。
- **依据：** 对话记录、`git log`、命令的原始输出。
- **相关文档：** [docs/contacts.md](contacts.md)、[docs/RE-FINDINGS-contacts.md](RE-FINDINGS-contacts.md)、[CHANGELOG-contacts.md](../CHANGELOG-contacts.md)

## 时间线

| 时间 | 事件 | 提交 | 测试 |
| --- | --- | --- | --- |
| 11-13 08:30 | 开始逆向「通讯录」：探针 App（同 bundle id 和签名）+ 8 个方向的调研 | — | — |
| 11-13 08:40 | 探针发现带备注的卡片保存失败 134092（P01） | — | 探针输出 |
| 11-13 09:33 | 发现 `removeMember:fromGroup:` 静默无效（P02） | — | 探针输出 |
| 11-13 11:21 | 审查另一个会话在主 checkout 里写的 Contacts MCP（未提交） | — | 现有测试 48 项通过 |
| 11-13 11:30 | 删掉那份代码里的 CNDuplication 文件，等审查结果 | — | — |
| 11-13 11:49 | 决定在本 worktree 重做，备注走 AppleScript | — | — |
| 11-13 12:29 | 新代码单元测试 | — | `ContactsModelTests` 24 项通过 |
| 11-13 12:30 | 录 Contacts 的 golden（79 个输出） | — | — |
| 11-13 12:35–12:50 | e2e 逐步修：64/70 → 60/70 → 66/70（P03–P06） | — | e2e |
| 11-13 12:53 | e2e 全过 | — | `70 passed, 0 failed` |
| 11-13 12:54 | 四个 App 的 golden 和全部单元测试 | — | 各 `0 differ` |
| 11-13 13:03 | 文档、逆向笔记、更新记录、README | — | — |
| 11-13 13:05 | 独立审查：5 个方向各一个审查者，各配一个反驳者核实 | — | — |
| 11-13 13:25 | 审查报告：47 条确认（去重约 36 条），3 条高危 | — | — |
| 11-13 13:40 | 修完后第一次 e2e：新加的「停用时间」测试卡片引出 P09 | — | `67 passed, 9 failed` |
| 11-13 13:47 | 复现 P09：「通讯录」重启后普通备注能存，写一次停用时间卡片的备注后又全部存不进去 | — | 全文搜索对照 |
| 11-13 13:51 | 修 P09 后 e2e 全过 | — | `79 passed, 0 failed` |
| 11-13 13:54 | 四个 App 的 golden、全部单元测试 | — | 各 `0 differ`；见 P10 |
| 11-13 13:56 | 第二轮独立核查：逐条核对第一轮的问题，并找修复带来的新问题 | — | — |
| 11-13 14:09 | 核查报告（13:56 起 770 秒）：41 条已修好，22 条经反驳者确认（去重约 16 条），见 P11 | — | — |
| 11-13 14:14 | 修完后 e2e（加了链接联系人清空备注的检查） | — | `80 passed, 0 failed` |
| 11-13 14:15 | 四个 App 的 golden、全部单元测试 | — | 各 `0 differ`；P10 又偶发一次 |
| 11-13 16:26 | 提交前重跑构建、四个 App 的 golden、全部单元测试 | — | 各 `0 differ`；`swift test` 退出码 0 |
| 11-13 16:27–16:40 | 发布前审计：隐私（两部分）、卫生和一致性、CI，各配一个核实者 | — | 隐私和 CI 无问题；确认 5 条小问题 |
| 11-13 16:29 | 删测试数据时 `contacts read` 卡住 600 秒（P12） | — | 采样和日志 |
| 11-13 16:46 | 修 P12 和审计的 5 条，重录 Contacts golden（8 个文件只改了关系数） | — | — |
| 11-13 16:47 | 关掉 Contacts 后读带备注的卡片，连做 8 次 | — | 8/8，每次约 1.1 秒 |
| 11-13 16:47–16:48 | 冷启动 e2e；四个 App 的 golden；全部单元测试 | — | `80 passed, 0 failed`；各 `0 differ`；8 组 197 项全过 |
| 11-13 16:49–16:51 | 删掉测试数据：74 个联系人（12 个是链接的）、14 个分组、1 个智能分组 | — | 之后搜 `agent test` 为 0 |
| 11-13 16:52 | 提交，推送分支，开 PR #19 | `8d8c1b8` | — |
| 11-13 16:53 | PR #19 的 CI 构建失败：CI 的 Swift 6.3.3 报两处名字遮蔽（P13） | `8d8c1b8` | `build-and-test` 失败 |
| 11-13 16:56–16:58 | 修 P13；构建、四个 App 的 golden、单元测试、e2e | 本提交 | 各 `0 differ`；8 组 197 项全过；`80 passed, 0 failed` |

---

## 一、逆向「通讯录」（11-13 08:30–10:41）

结论都在 [RE-FINDINGS-contacts.md](RE-FINDINGS-contacts.md)。三条路：Contacts.framework（公开 + 私有方法）、进程内 AddressBook.framework、「通讯录」的 AppleScript。

### P01 带备注的卡片，任何保存都失败

- **现象：** `executeSaveRequest:` 报 `Unhandled error occurred during faulting: Error Domain=NSCocoaErrorDomain Code=134092`；`updateContact:`、`addMember:toGroup:`、新建带备注的卡片都一样，AddressBook 的 `saveAndReturnError:` 也一样。读 `.note` 抛 `CNPropertyNotFetchedException`（Objective-C 异常，Swift 接不住，进程崩）。
- **怎么查的：** 探针分别对有备注、无备注的卡片做同样的保存；lldb 看到 `+[CNCDContactFetcher inaccessibleKeys]` 含 `note`、`addressingGrammars`。
- **原因：** 没有 `com.apple.developer.contacts.notes` 授权的进程拿不到备注；保存时框架要为搜索索引加载备注行，被拒绝。
- **解决：** 备注读写走 AppleScript（`note of person id …`）。保存带备注的卡片时把备注放到一边：写进 `notes-aside.json` → AppleScript `set note to missing value`（删掉备注行）→ 框架保存 → AppleScript 放回。App 中途停掉的话，下次调用从文件放回。
- **验证：** e2e「create contact」（带多行中文备注和头像）、「update a card with a note」「no note is left set aside」「merge two cards」「export with notes」都通过（12:53 `70 passed, 0 failed`）。

### P02 Contacts.framework 说移除成功，成员没变

- **现象：** `-[CNSaveRequest removeMember:fromGroup:]` 返回成功、分组的修改时间也变了，成员还在；`removeSubgroup:fromGroup:` 同样。
- **解决：** 移除成员走 AppleScript `remove person … from group …`，取消嵌套走 AddressBook `removeSubgroup:`；之后都经 CN 读回核对。
- **验证：** e2e「remove a member that has a note」「unnest」通过。

---

## 二、审查另一个会话的实现（11-13 11:21–11:47）

主 checkout（`~/workspace/src/apple-mcp`）里另一个会话写了一版未提交的 Contacts MCP。审查报告在 `artifacts/contacts-mcp-review.md`（gitignore，不提交），确认 70 个问题，主要是：读 `.note` 直接崩（P01 没处理）、带备注的卡片 update/delete/加成员全失败、导出缺 vCard 需要的键、P02 的静默无效、文档说智能分组/我的名片/链接做不到（其实能做）、e2e 跑不起来。那份代码没有动，在本 worktree 重写。

---

## 三、在 worktree 里重做（11-13 11:49–12:54）

### P03 链接卡片在长时间运行的服务器里失败 134040

- **现象：** e2e 里 `link_contacts` 报 `Contacts: Save operation could not be completed. (NSCocoaErrorDomain 134040)`；单独跑一次性命令却能成功。
- **怎么查的：** 同一进程里先写卡片（同步守护进程随后改了它），再 `linkContact:toContact:`，必现；换新的 `CNContactStore` 也一样。
- **原因：** Contacts.framework 的 Core Data 栈是进程级共享的，缓存的旧版本和库里被同步改过的对不上。
- **解决：** 链接、取消链接、选姓名/头像卡片改走 AddressBook（`linkPerson:toPerson:` 等），每次新建 `[ABAddressBook addressBook]`，同样包在备注放一边里。
- **验证：** e2e「link two cards」「prefer a card's name」「unlink a card」通过。

### P04 写完总说没上传

- **现象：** 每次写都回 `"uploaded": false`。
- **怎么查的：** 原先直接读 `~/Library/Application Support/AddressBook` 的库看同步状态，得到 `open rc=23 msg=authorization denied`。
- **原因：** 即使有「通讯录」权限，App 进程也不能直接开这些 SQLite，只有框架能。
- **解决：** 改看 Contacts.framework 的私有键 `externalModificationTag`（CardDAV ETag），服务器接受卡片后它会变；变了再等卡片 3 秒不变（P05）。上限 45 秒，带头像 90 秒。
- **验证：** e2e「create waits for the upload」通过，回答里 `uploaded: true`。

### P05 刚写完的卡片，下一次写因版本变了被拒

- **现象：** 带头像或即时通讯的卡片，上传后再读版本变了；即时通讯的 `Skype` 读回来是 `SkypeInstant`。
- **原因：** iCloud 收到后把头像另存，约 8 秒后把卡片再送回来，还会改写个别服务名。
- **解决：** 等上传后再等卡片稳定（修改时间 3 秒不变）才回答；文档提醒改前重新读。
- **验证：** e2e「update a card with a note」紧接创建之后通过。

### P06 新建或刚恢复的卡片加不进分组

- **现象：** AppleScript `add person … to group …` 不报错，成员没加上。
- **原因：** Contacts.app 自己持有的 ABAddressBook 副本里，别的进程刚新建或恢复的卡片还是旧的。
- **解决：** 新卡片在放回备注之前（那时卡片没有备注，CN 能保存）先经 Contacts.framework 加进分组；之后都经 CN 核对，最多重试 8 次，每次隔 400 ms。
- **验证：** e2e「create a group with members」「restore it with its id and group」通过。

### P07 分组变化也让版本变了

- **现象：** 只是把联系人加进分组，之前读到的版本就失效。
- **解决：** 版本不含 `groups`（以及 `created`、`modified`），分组变化不算改了卡片。
- **验证：** `VersionTests.timestampsAndGroupsDoNot` 通过。

### P08 arm64 上调私有方法传错参数

- **现象：** 用变参的 `objc_msgSend` 调 `setCropRect:`、`initWithSound:vibration:ignoreMute:` 等，参数错位。
- **原因：** arm64 上变参和定参的调用约定不同。
- **解决：** `ContactsShim` 里给每个签名写强转后的调用。

---

## 四、独立审查和修复（11-13 13:05–13:54）

审查报告在会话的临时目录（未入库）。确认的问题按文件修完：备注放一边的恢复和锁、create/restore/delete 中途失败、链接联系人的列表和单值字段、导入导出、分组成员和写入保护、shim 的异常和 ARC、文档和工具说明。被反驳掉的几条（备注长度按字形算、merge 删带备注的卡片、smart list 自引用等）没有改。下面只记不显然的几条。

### P09 一张「停用时间」卡片让「通讯录」之后的改动全部存不进去

- **现象：** e2e 新加了一张 `downtime_allowed: true` 的测试卡片，之后分组成员加不上、链接报 `ABAddressBookErrorDomain error 0`、备注搜索不到；读回来的备注却是对的。另一张普通卡片的分组也加不上。
- **怎么查的：** 采样 Contacts.app，主线程空闲，没有卡在对话框。退出 Contacts.app 后，新建普通卡片 Three 的备注能被全文搜索找到（13:47）；再新建停用时间卡片 Four 写备注，之后普通卡片 Five 的备注又搜不到。改版后的 App 对 Three 改备注直接报出 `Contacts did not save the change`（`unsaved` 为 true）。
- **原因：** Contacts.framework 把停用时间卡片当只读（`CNErrorDomain 206`），保存请求加 `setIgnoresGuardianRestrictions:` 才能存；「通讯录」AppleScript 的保存没有这个开关，失败后把这次和之后所有改动都留在内存里，读回来（读的是内存）看着都对，库里没有，退出就丢。
- **解决：** 从不经 AppleScript 写停用时间卡片：拒绝改它的备注（它有备注时什么都不能改）；加入分组走 CN `addMember`；拒绝移出分组；恢复带备注的这种卡片时去掉停用时间允许并说明。所有会保存的 AppleScript handler 在 `save` 后返回 `unsaved`，为 true 就报错让用户退出「通讯录」。CN 的 `ignoresGuardianRestrictions` 只对这种卡片打开，监护人管理的账户里不打开。
- **验证：** e2e「create a card allowed during Downtime」「update a card allowed during Downtime」「its note is refused before anything changes」通过，之后所有备注和分组检查照常通过（13:51 `79 passed, 0 failed`）。

### P10 共用底座里起 `/bin/sh` 的测试偶尔失败

- **现象：** 整套 `swift test` 偶尔报 `cannot start /bin/sh: No such file or directory`，出现在 `stopsWhatRunsTooLong`，也出现在 `runsWithoutATerminal`。
- **怎么查的：** `swift test --filter AgentsTests` 单独跑 9 次全过；只在整套并行跑时偶发。这次没有改 `Sources/Agents` 或 `Tests/AgentsTests`。
- **原因：** 未查清，和 Contacts 无关。

### P11 第二轮核查找到的：修复留下的缺口

- **现象：** 修复本身留下了几处缺口：给有备注的联系人打开 `downtime_allowed` 时，保存后备注经 AppleScript 写回已是停用时间的卡片，又会让「通讯录」卡住（P09 的漏网情况）；恢复中途 `.missingCard` 时备份被删、备注丢失；`notesAside` 删掉了别的调用留下的恢复条目；merge 保存成功、只是备注没写回时却删了备份；import replace 会把同一文件里后面的同名条目匹配到刚导入的卡片；链接联系人清空备注和提示音只清了一张卡；分组名和智能分组名重名时有歧义没报出来；导入时匹配到的已有卡片没过写入保护。
- **解决：** 有备注（或要写新备注）时拒绝打开停用时间允许；恢复时 `.missingCard` 就报「稍后再试」并保留备份；只删本次调用决定了的恢复条目；`ContactsError.afterSave` 区分「已保存、备注待写」和保存失败，merge 和 import 据此保留备份、给警告；导入的新卡不参与后续匹配；清空备注和提示音覆盖每张卡；`listing()` 一次比对分组和智能分组，重名就列出所有 id，criteria 也走它；导入匹配和重新链接都过写入保护。共用的技能生成器写明 update 没有 create 的哪些参数（只改变了 Contacts 的技能文字，其他三个 App 的 golden 不变）。
- **验证：** e2e「a linked contact: a cleared field goes from every card」（含备注）「a note goes back on an unlinked card」等通过（14:14 `80 passed, 0 failed`）；四个 App 的 golden 都 `0 differ`。

---

## 五、提交前的检查和 CI（11-13 16:24–16:58）

提交前重跑构建、四个 App 的 golden 和全部单元测试（16:26 全过），并做了一轮发布前审计：4 个审计者（文档里的隐私、golden/资源/代码里的隐私、卫生和一致性、CI 能否通过），各配一个核实者。隐私和 CI 都没有问题：CI 上次成功的运行用 Xcode 26.6、Swift 6.3.3，shim 里的私有类和方法全部在运行时查找，用到的 Contacts、AddressBook 头文件和 Apple 事件常量在 26.5 和 27.2 的 SDK 里一致。确认的 5 条小问题都改了：Notes、Reminders、Journal 的文档列出 Contacts（照 Journal 加入时的 `d22fbdd`）；几个脚本和 `Package.swift` 的头注释写上 Contacts；文档写明首次发版要先在 homebrew-tap 加 cask；「200 种关系」改成「200 多种」（实际 217 种，8 个 golden 随之重录，只有这句变了）；本日志的当前状态随提交更新。

### P12 第一次启动「通讯录」时，读备注卡住 10 分钟以上

- **现象：** 删测试数据时，`contacts read <卡片 id>` 从 16:29:23 起 600 秒没返回，脚本超时退出，一个都没删。
- **怎么查的：** `sample` 这个进程，主线程在 `ensureRunning` → `execute("ready")` → `AESendMessage` 里等；同时采样 Contacts.app，它的主线程空闲在事件循环里。日志里 `AESendMessage(core,cnte …)`（`ready` 里的 `count of people`）在 16:29:23.932、16:31:24、16:33:24 各发一次，每次都等满 AppleScript 默认的 2 分钟。Contacts.app 是 16:29:23.764 由这个进程启动的，发第一个事件时还没启动完（16:29:23.957 还在恢复窗口）。对同一个 Contacts 实例，另起一个进程读带备注的卡片 0.3 秒就返回；关掉 Contacts 再试一次 1.5 秒，没有复现。一个小探针显示 `openApplication` 0.12 秒返回，`isFinishedLaunching` 0.22 秒才变成 true，命令行进程里也看得到这个变化。
- **原因：** `ensureRunning` 在 Contacts 一出现在进程列表里就发 `ready`，那时它可能还没启动完。赶上这个时机，这个进程发给它的 Apple 事件一直没有回答，每次等满 2 分钟，最多重试 40 次（80 分钟），全部失败后也不报错。同一进程里重试为什么也不行没有查清，多半是 AppleScript 或 Apple 事件缓存了启动中的目标。
- **解决：** 等 `isFinishedLaunching` 之后再发第一个事件；`ready` 加 `with timeout of 5 seconds`；超时（-1712）或连接失效（-609、-600）时丢掉编译好的脚本，下次重新编译、重新找 Contacts；30 秒还不回答就报错，让用户退出「通讯录」再试。
- **验证：** 关掉 Contacts 后读带备注的卡片，连做 8 次，8 次都读到备注，每次约 1.1 秒；冷启动跑 e2e `80 passed, 0 failed`（16:47:45–16:48:48）；四个 App 的 golden `0 differ`，`swift test` 8 组 197 项全过。原来的卡死没能再现，所以「同一进程里重新编译能不能救回来」没有验证到，靠 30 秒上限兜底。
- **提交：** `8d8c1b8`

### P13 CI 上编译失败：闭包里的方法调用被同名局部常量遮蔽

- **现象：** PR #19 的 `build-and-test` 在 Build 一步失败：`Groups.swift:205:72: error: cannot call value of non-function type 'CNMutableGroup'`，`Organizing.swift:123:67: error: cannot infer key path type from context; consider explicitly specifying a root type`。本机构建没有警告。
- **怎么查的：** CI 用 Xcode 26.6、Swift 6.3.3，本机是 Swift 6.4.2，没有旧工具链能复现。两处都是在闭包里调用方法（`group(_:)`、`groups(ofCards:)`），而同一个函数里有同名的局部常量：`let group = CNMutableGroup()` 在后面才声明；`let groups = …` 就是那一行本身。CI 编译了 ContactsComponent 的全部 15 个文件，只有这两处错误。
- **原因：** Swift 6.3 在闭包里按名字查找时，会找到外层函数里同名的局部常量（哪怕在后面才声明）；6.4 找到的是方法。
- **解决：** 改成 `self.group(name)`；局部常量改名为 `carried`。
- **验证：** 本机构建，四个 App 的 golden `0 differ`，`swift test` 8 组 197 项全过；e2e `80 passed, 0 failed`，包括「create a nested group」「merge two cards」。CI 的结果看 PR。
- **提交：** 本提交

---

## 环境与操作上的坑

不是代码的 bug，但都实际踩过，下次直接避开：

| 坑 | 表现 | 怎么办 |
| --- | --- | --- |
| 裸 `swift build` 的可执行文件没有权限 | `.build/debug/AppleContactsMCP` 报没有「通讯录」权限 | e2e 和手动试都用 `scripts/build-app.sh contacts` 签好名的 `dist/AppleContactsMCP.app` |
| 「通讯录」刚启动时 AppleScript 找不到对象 | `-1728` | 隐藏启动后重试，最多 10 次，每次隔 300 ms |
| zsh 的 `GID` 是只读特殊变量 | 脚本里 `GID=...` 报错 | 换个变量名 |
| 自己的探针数据污染 e2e | 按公司名、用户名搜索多出探针留下的卡片 | e2e 用独有的值（`e2e测试公司`、`e2e9tw` 等），按 id 导出 |
| 本机的 Swift 比 CI 新 | 本机编得过的代码，在 CI（Xcode 26.6、Swift 6.3.3）上报错，比如闭包里调用的方法被同名局部常量遮蔽（P13） | 闭包里调用和局部常量同名的方法时写 `self.`，或者给常量换个名字；推送后看 CI |
| 写入保护按显示名判断 | 带 `prefix` 或姓在前的测试卡片显示名不以 `agent test` 开头，被保护拒绝 | 测试卡片不用称谓，姓名顺序用 `given_first` |
| 从终端直接跑 `osascript` 控制「通讯录」 | 终端没有自动化权限，命令挂住，可能弹出授权框 | 用签过名的 App 本身（或同签名的探针）去调 AppleScript |
| 「通讯录」卡在存不进去的状态（P09） | 改动读回来对，搜索不到，`unsaved` 为 true | 退出「通讯录」；它没存的改动会丢 |

---

## 当前状态（11-13 16:58）

已提交到分支 `claude/apple-contacts-reverse-engineer-c146a0`，开了 PR #19 合入 `main`，**未合并、未发版**。CI 第一次构建失败（P13），修复已推送。构建无警告；单元测试全过（P10 的偶发失败除外）；四个 App 的 golden 都 `0 differ`；Contacts e2e `80 passed, 0 failed`。以前留下的 `agent test` 测试数据已删（这个 App 留的 30 天副本里只有测试数据）。

### 待办与遗留

- **我（用户）：**
  - 审 PR、决定合并。
  - 决定是否做打印/PDF 和 CSV/LDIF 导入（要把 Contacts.app 可执行文件载入进程，见 RE-FINDINGS §8）。
  - 发 0.1.0 前：在 homebrew-tap 加 `Casks/apple-contacts-mcp.rb`，文档里补 `gh release download …` 和 `installer -pkg …` 两行（`release.sh` 要用），照 Journal 的首发准备提交 `64cc7df`。
- **仓库：**
  - 主 checkout 里另一个会话的未提交 Contacts 代码和本 worktree 的重写冲突，合并前要处理（不要直接丢弃别人的改动）。
  - P10：共用底座的计时测试偶发失败，另查。
  - `settings set` 测试时写过一次 `ABNameSortingFormat`，值和原来一样（默认值）。

### 速查（不含任何 secret）

- 备注放一边的恢复文件：`~/Library/Application Support/AppleContactsMCP/notes-aside.json`（锁：同目录 `notes-aside.lock`）
- 删除副本：`~/Library/Application Support/AppleContactsMCP/Deleted/`（30 天）
- 写入保护：`APPLE_CONTACTS_MCP_WRITE_GUARD=agent test e2e`
- e2e：`/usr/bin/python3 -I scripts/e2e.py contacts dist/AppleContactsMCP.app/Contents/MacOS/AppleContactsMCP`
- golden：`/usr/bin/python3 -I scripts/golden.py check contacts "$(swift build --show-bin-path)/AppleContactsMCP" Tests/Golden/contacts`
