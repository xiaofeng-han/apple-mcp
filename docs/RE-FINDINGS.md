# Apple 备忘录（Notes.app）逆向结论

2026-10-19，MacBook（macOS 27.0.1 / 26A434），用 REA 6.7.0 加命令行工具完成。
目标：做一个让 agent 能读、改、新建备忘录的 CLI 和 MCP，并判断是"桥接真 Notes"还是"整个复刻"。

标记：**[观测]** 直接看到的；**[推断]** 由观测推出的；**[未知]** 还没查。

## 1. 数据存在哪

- **[观测]** 数据库：`~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`（CoreData，WAL 模式，旁边有 `com.apple.notes.databaseopen.lock`）。
  本次用 `sqlite3 ... ".backup"` 做了只读快照再分析，没碰原库。
  REA Evidence：`ev_991ae31734bfc056ae42acec98648116de6b419a3928540ee0e2833578dec09e`（全库表/索引清单）。
- **[观测]** 单表继承：几乎所有对象都在 `ZICCLOUDSYNCINGOBJECT`（215 列），用 `Z_ENT` 区分类型。
  `Z_PRIMARYKEY` 的映射（`ev_33c9d8527fbf4aa71dff9f5bfe7c6a72616d9f0d8cab76fa5a0e35cad58438b0`）：

  | Z_ENT | 实体 | 本机数量 |
  |---|---|---|
  | 12 | ICNote | 386 |
  | 15 | ICFolder | 15 |
  | 14 | ICAccount | 1 |
  | 5 | ICAttachment | 166 |
  | 6 | ICAttachmentPreviewImage | 268 |
  | 11 | ICMedia | 66 |
  | 8 | ICHashtag（标签） | 4 |
  | 9 | ICInlineAttachment（行内的 #标签、@提及、笔记链接） | 3 |
  | 10 | ICLegacyTombstone | 19 |

  关键列：`ZTITLE1`（笔记标题）、`ZSNIPPET`、`ZFOLDER`、`ZNOTEDATA`、`ZISPINNED`、`ZMARKEDFORDELETION`、
  `ZCREATIONDATE*`/`ZMODIFICATIONDATE*`（Core Data 时间，从 2001-01-01 起算）、`ZIDENTIFIER`（UUID）、
  `ZTITLE2`（文件夹名）、`ZPARENT`（父文件夹）、`ZSMARTFOLDERQUERYJSON`（智能文件夹）。
  [推断] 列名后的数字（`ZTITLE1`/`ZTITLE2`、`ZCREATIONDATE1..3`）是 CoreData 给不同子实体的同名属性分配的，
  要按 `Z_ENT` 选列；实现时用 `Z_ENT` 加列名的映射表，不要写死。
- **[观测]** 正文在 `ZICNOTEDATA.ZDATA`（`ev_e831ea38471c127008f9b98ea60c8f1c4a146b252ad8841fc043b991a886c85e`），
  gzip（魔数 `1f8b`）压缩的 protobuf。用 `scripts/pbshape.py` 解出的结构（只打字段号，不打内容）：

  ```
  1: varint
  2: Document
     2: varint (version)
     3: Note
        2: bytes             ← note_text：纯文本
        3: repeated Substring  {1:{1,2} 字符 ID(replica, clock), 2: 长度, 3:{1,2}, 5: varint}  ← CRDT
        4: VersionVector     {1: repeated {1: 16 字节 replica UUID, 2: clock...}}
        5: repeated AttributeRun {1: 长度, 2: ParagraphStyle{1: 样式, 9:...}, 13: ...}  ← 格式/清单/附件位置
  ```

  这和社区逆向的 `notestore.proto`（[apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser)）一致：
  `NoteStoreProto.document.note.note_text` 是纯文本，`attribute_run` 描述标题/列表/清单（含是否勾选）/附件占位。
- **[观测]** 本机 386 条正文都没加密（`ZCRYPTOTAG` 全空）。加锁笔记要用户密码派生密钥，不在支持范围。
- **[推断]** 表格、画图等附件的内容在附件行的 `ZMERGEABLEDATA*` 列里，也是 CRDT protobuf；图片和文件在
  `Accounts/<账号 UUID>/Media` 一类目录。**[未知]** 没有逐一核对。

## 2. 为什么不能直接写数据库

- **[观测]** 正文是 CRDT：每段字符带 (replica, clock) ID，加上版本向量；另有 `ZSERVERRECORDDATA`、`ZCLOUDSTATE`、
  `ZNEEDSTOBEFETCHEDFROMCLOUD` 这些 CloudKit 同步状态列，以及 `ATRANSACTION`/`ACHANGE`（CoreData 持久化历史）。
- **[推断]** 绕过 Notes.app 直接写 SQLite，要自己生成合法的 CRDT 操作、更新同步状态和持久化历史，
  还要和正在运行的 Notes 进程抢锁。写错了会损坏笔记，或者改动不同步到 iCloud。**结论：读可以直接读快照，写必须经过 Notes.app。**

## 3. Notes.app 官方开放的接口

### 3a. AppleScript（`Contents/Resources/Notes.sdef`）

- **[观测]** 类：`account`（default folder、name、id）、`folder`（name、id、shared、container）、
  `note`（name、id、container、**body（HTML）**、**plaintext**、creation/modification date、password protected、shared）、
  `attachment`（name、id、content identifier、URL…）。命令：`show`、`open note location`，以及标准的 make/delete/move。
- 局限（社区经验，未本机复核）：AppleScript 看不到清单勾选状态和标签；用 HTML 整体覆盖 body 会丢掉清单、附件这类结构。

### 3b. App Intents（`Contents/Resources/Metadata.appintents/extract.actionsdata`，工具版本 27A200c）

- **[观测]** 51 个 action，`openAppWhenRun: false`（可以后台跑）。和 agent 相关的：

  | Action | 参数 |
  |---|---|
  | `CreateNoteLinkAction` | name, contents, folder, **interpretAsMarkdown** |
  | `AppendToNoteLinkAction` | operation, entity, text, section, ignoreWhitespace, **interpretAsMarkdown** |
  | `CreateChecklistItemLinkAction` / `SetChecklistItemCheckedLinkActionv2` / `DeleteChecklistItemsLinkAction` | 清单 |
  | `CreateTableLinkAction` | name, **csvString**, note |
  | `AddTagsToNotesLinkAction` / `RemoveTagsFromNotesLinkAction` / `CreateTagLinkAction` | 标签 |
  | `MoveNotesToFolderLinkAction` / `PinNotesLinkAction` / `DeleteNotesLinkAction` | 整理 |
  | `CreateFolderLinkAction` / `RenameFolderLinkAction` / `DeleteFoldersLinkAction` | 文件夹 |
  | `AddFileAttachmentLinkAction` / `AddLinkAttachmentLinkAction` | 附件 |
  | `GetLinkedNotesLinkAction` / `InsertNoteLinkLinkAction` | 笔记互链 |
  | `UpdateNoteIntent` | name, attachments, isPinned, target, folder（**不能改正文**） |

- **[观测]** 实体：`NoteEntity`（name、subtitle、**content**、folder、isPinned、tags、attachments、creationDate、modificationDate）、
  `FolderEntity`、`TagEntity`、`ChecklistItemEntity`（text、checked、note）、`TableEntity`、`AttachmentEntity`（stringContent…）；
  查询有 `VisibleNotesQuery` 等。
- **[推断]** 外部进程没有公开 API 能直接调别的 App 的 Intent，只能通过 Shortcuts：先装好几个快捷指令，
  再 `shortcuts run <名字> --input-path <json>` 调用。

## 4. 系统有没有现成的 MCP

只在 dyld shared cache 的字符串里做了有限搜索：

- **[观测]** MCP **服务端**只看到 Safari WebDriver 那套：`safaridriver --mcp`、`/usr/bin/safarimcp`、`WDMCPService`、`WDMCPAutomationBridge`，用于浏览器自动化。
- **[观测]** `GenerativeAgents.framework` 里有 `MCPClient`、`MCPServersConfig`、`MCPToolSet`，是**客户端**：苹果自己的 agent 去连别人的 MCP server。
- **[观测]** `toolkitd`（XPC `com.apple.toolkitd`、`com.apple.shortcuts.ToolKitIndexingService`）是给 Shortcuts 和 Apple Intelligence 用的工具索引，里面没有 MCP 字符串。
- **结论**：没找到把 App Intents 或 Notes 以 MCP 暴露出来的系统组件。搜索有边界，不代表一定不存在。

## 5. 社区已有的

[sweetrb/apple-notes-mcp](https://github.com/sweetrb/apple-notes-mcp)（AppleScript，工具多）、
[eliotshea/notes-mcp](https://glama.ai/mcp/servers/eliotshea/notes-mcp)（用快捷指令补清单，支持 Markdown 创建）、
[RafalWilinski/mcp-apple-notes](https://glama.ai/mcp/servers/m4g6m0koei)（JXA + 本地向量检索）。
从介绍看，它们主要靠 AppleScript/JXA 读写，有的用快捷指令补清单（未逐个看源码）。
AppleScript 一条条读比较慢，也拿不到清单、标签、表格这些结构。直接读快照加解 protobuf 正好补上这一块。

## 6. 可选方向

| | A. 桥接真 Notes | B. 完整复刻 |
|---|---|---|
| 做什么 | 只做 CLI 和 MCP；读走 SQLite 快照加 protobuf 解码，写走 App Intents（快捷指令），AppleScript 兜底 | 自己写 Notes 风格的 App 和存储，CLI/MCP 原生支持；用 A 的读取器一次性导入旧笔记 |
| iPhone/iCloud 同步 | 保留，不用管 | 丢失，除非自己做 iOS 端和同步 |
| agent 能力 | 读：全量、毫秒级、带结构；写：Markdown 新建/追加、清单、表格、标签、移动、置顶、删除 | 完全由自己定，比如 Markdown 原文、版本历史、git |
| 难点 | 一次性装快捷指令；系统升级可能改 Intent；整篇改写正文没有好接口（AppleScript HTML 会丢结构） | 富文本编辑器、清单、表格、附件、搜索、同步，工作量以月计 |
| 工作量 | 几天 | 几周到几个月 |

建议先做 A，并把 CLI/MCP 写在一个抽象的 `NoteStore` 接口上（后端一：Apple Notes；后端二：将来自己的存储）。
这样以后要做 B，只需要换后端，agent 侧接口不用变。

## 附：复现命令

```bash
sqlite3 "file:$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite?mode=ro" ".backup '/tmp/x/NoteStore.sqlite'"
python3 -I scripts/pbshape.py /tmp/x/NoteStore.sqlite
```

读这个容器需要 macOS 的"App 数据"/完全磁盘访问权限，权限算在启动进程（终端或 agent 宿主）头上。

## 7. 后来采用的做法（2026-10-21，本仓库的实现）

上面第 2、3 节的结论（写必须经过 Notes.app、考虑 App Intents/快捷指令）后来被改掉：快捷指令桥被否决，
改为在本进程里 dlopen 私有的 NotesShared.framework，用「备忘录」自己的对象原地修改，再让 Notes.app 上传。
实现依赖的观测（macOS 27.0.1）：

- **读**：`ICPersistentContainer` 的 `managedObjectModel` + `standardStoreOptions`，加 `NSReadOnlyPersistentStoreOption`
  打开 NoteStore.sqlite；正文是 `note.mergeableString.attributedString`，属性键 `TTStyle`（ICTTParagraphStyle：
  style 0 标题/1 小标题/2 副标题/3 正文/4 等宽/100 圆点/101 短横/102 编号/103 清单，indent，blockQuoteLevel，todo.done）、
  `TTHints`（1 粗、2 斜）、`TTStrikethrough`、`TTUnderline`、`TTEmphasis`（高亮色号）、`NSLink`、`NSAttachment`（ICTTAttachment）。
  表格单元格要先 `+[ICNoteContext startSharedContextWithOptions:]` 才读得到，否则 0×0。
- **搜索**：直接取 `noteData.data` 解码，新笔记是 zlib，老笔记是 gzip，两种都要支持。
- **写**：共享上下文的 viewContext 是主队列上下文，必须在真正的主线程上保存（`dispatchMain()` 会让主队列跑在别的线程上，保存时死锁）。
  `note.document.mergeableString` 的 `insertAttributedString:atIndex:` / `deleteCharactersInRange:` / `setAttributes:range:`，
  每次之后都要 `note edited:range:changeInLength:`；`attributedString` 在 `endEditing` 之前是快照，要自己维护镜像。
  结束时设 `modificationDate`，`endEditing`，`saveNoteData`，再 save 上下文。
- **表格**：`addTableAttachmentWithText:` 要在编辑会话之外调用（在里面调用会让保存的正文被截断），并需要 NotesEditor 的
  `ic_convertParagraphStyleToBodyInRange:`——加载 NotesEditor 本身会让之后的中段修改存出截断的正文，所以自己补这个方法。
  原地改表格：ICTable 的 insert/remove row/column、单元格 mergeable string，最后 `setMergeableDataDirty:YES` + `writeMergeableData`
  + 附件 `updateChangeCountWithReason:`。当前这次 Notes 会话里手动改过的表格，原地改了不会上传，只能重建。
- **同步**：NotesShared 写入后 Notes 不会自己上传；AppleScript 把笔记「移到它当前所在的文件夹」会让 Notes 保存并上传，
  之后轮询 `cloudState` 的 `currentLocalVersion` / `latestVersionSyncedToCloud`。表格是单独的记录。
- **AppleScript 的坑**：`move folder` 报告成功却把文件夹删掉；`exists note id` 对「最近删除」里的笔记也是 true，要看
  「最近删除」文件夹的 `id of notes`；列表结果没有 stringValue，要逐项读；数据库比 Notes.app 落后几分钟，删除/改名后要自己记住。

## 8. 功能补齐时的新发现（2026-10-21，Notes 4.13 / macOS 27.0.1）

方法：Notes.app 的菜单（MainMenu.loctable，183 条）、App Intents（51 个 action）、NotesShared 的 Core Data 模型
（NoteData.mom），以及在本机进程里 dlopen NotesShared 后用 ObjC 运行时列出的类和方法；能只读验证的都在只读库上跑过，
写入只在标题以「agent test」开头的测试笔记上做。

- **录音的文字稿和摘要** [观测]：在附件（`com.apple.m4a-audio`）的 `mergeableData` 里，是 `ICTTAudioDocument`。
  `+registerWithICCRCoder` 后 `+unarchiveFromData:replicaID:`（replica 随便给一个新 UUID）就能读出
  `transcriptAsPlainText`（通话录音带说话人）、`recordingSummaryAsPlainText`、`topLineSummaryAsPlainText`、`isCallRecording`，
  不需要共享上下文。音频本身在子附件里（各段录音）。
- **附件里的文字** [观测]：`ocrSummary`（图片、扫描）、`handwritingSummary`（手绘）、`imageClassificationSummary`、`summary`
  都是附件行的列；Notes 自己的搜索走 Spotlight（`ICSearchQueryParser` 生成查询串），外部进程用不了，所以本仓库自己搜这些列。
- **标签** [观测]：行内附件 `com.apple.notes.inlinetextattachment.hashtag`，`altText` 是 `#name`，`tokenContentIdentifier`
  是大写的标准名；另有 `ICHashtag`（displayText、standardizedContent）。新建用
  `+[ICInlineAttachment newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:]`
  （hashtagText 不带 #）。**坑**：保存后 Notes 会把新 ICHashtag 标成删除（`-[ICAccount deleteUnusedHashtagsWithStandardizedContent:]`
  数用量时还没算上新的那处；也可能是 Notes.app 上传时保存它自己那份旧笔记），所以写完、上传完还要再看一眼，必要时
  `unmarkForDeletion` + `updateChangeCountWithReason:`。写入上下文里的对象可能是旧的，判断要用只读库。
  改名：`+[ICHashtag renameHashtagsWithStandardizedContent:newDisplayText:context:]`（会新建一个 ICHashtag，旧的标删除）。
- **笔记链接 / 分割线** [观测]：`newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:`（token 是
  `applenotes:note/<小写 id>?ownerIdentifier=…`）、`newDividerLineAttachmentWithIdentifier:note:parentAttachment:`
  （类型 `…inlinetextattachment.dividerline`，altText `---`）。反向链接：查 token 里含 `applenotes:note/<id>` 的链接附件。
- **智能文件夹** [观测]：`smartFolderQueryJSON` 不为空的 ICFolder（folderType 2）。`-[ICFolder smartFolderQueryObjC].predicate`
  是一个能直接在只读库上执行的 NSPredicate；`smartFolderDescriptionObjC` 是可读描述（`#oracle, #project`）。新建：
  `ICTagSelection initWithManagedObjectContext:includedObjectIDs:excludedObjectIDs:tagOperator:`（**0 = 任一，1 = 全部**）→
  `+[ICQueryObjC objc_queryForNotesMatchingTagSelection:]` → `+[ICFolder objc_smartFolderWithQuery:account:]`。
  经 NotesShared 写的文件夹改动（新建、改名、移动、删除），Notes 会在半分钟内自己上传，不用 AppleScript 触发。
- **各种分组的定义**（`ICQuery`）[观测]：通话录音 `hostApplicationIdentifier ==[cd] com.apple.mobilephone`；数学笔记
  `com.apple.greyparrot` 或 `com.apple.calculator`；快速备忘录 `isSystemPaper == 1`；共享 = 笔记或任一级父文件夹有
  `serverShareData`，或 `zoneOwnerName` 不是 `__defaultOwner__`（本仓库原来只看 serverShareData，已改）。
  清单用 ICNote 的 `hasChecklist` / `hasChecklistInProgress`；最近打开用 `lastOpenedDate`。
- **置顶** [观测]：AppleScript 没有这个属性；`-[ICNote setIsPinned:]` + `updateChangeCountWithReason:`，再按老办法触发上传。
- **复制笔记** [观测]：`+[ICNote duplicateNote:intoFolder:isPasswordProtected:removeOriginalNote:]` 在 **NotesUI** 里，
  不在 NotesShared。加载 NotesUI 可能像 NotesEditor 一样影响之后的保存 [推断]，所以本仓库另起一个本 App 进程
  （`--copy-note`）做复制。`removeOriginalNote:YES` 应该就是跨账户移动的做法 [推断，未用]。
- **加附件** [观测]：`-[ICNote addAttachmentWithFileURL:]`（复制文件、建 ICMedia）、`-[ICNote addURLAttachmentWithURL:]`
  （链接卡片，预览由 Notes 之后去取）；要在正文编辑会话之外调用，和表格一样。预览图本仓库不生成 [未知：其他设备上是否正常显示]。
- **移动文件夹** [观测]：`setParent:` + `parentModificationDate` + `updateChangeCountWithReason:`，Notes.app 的 AppleScript 视图
  几秒内就看到新位置，iCloud 也收到了。子文件夹的排序（`subFolderOrderMergeableData`）没动 [未知：其他设备上的位置/顺序]。
- **高亮颜色** [推断]：TTEmphasis 1–5，按 App Intents 的 EmphasisColor 顺序对应紫、粉、橙、薄荷绿、蓝；本机只有 1 号在用。
- **新段落样式 Caption** [观测：App Intents 里有；未知：编号]：本机没有用到的笔记；读成正文，改这一行的文字时原样式保留。
- **跨进程通知** [观测，未用]：`ICNotesCrossProcessChangeCoordinator`（`postEditorExtensionDidSaveNotification`）是扩展通知 Notes.app
  合并的通道；`startSharedContextWithOptions:0` 没开它。也许能代替「把笔记移到原文件夹」触发上传，没有实验。
