# Apple 手记（Journal.app）逆向结论

2026-11-01，MacBook（macOS 27.2 / 26B123，「手记」3.0，build 113），用 REA 6.7.0、dyld_info、otool、lldb 和自写的小程序完成。
目标：做一个让 agent 能读写「手记」的 CLI 和 MCP，复用本仓库的底座，覆盖「手记」的全部功能，做不到的说明原因。

标记：**[观测]** 直接看到或实测的；**[推断]** 由观测推出的；**[未知]** 没查清的。
写入实验只在名为「agent test」的手记本和标题以「agent test」开头的手记上做（用户同意），做完永久删除。动手前用
`sqlite3 ".backup"` 给真实库做了快照。

## 1. 数据存在哪

- **[观测]** 库：`~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite`（Core Data，WAL），
  附件文件在旁边的 `Attachments/<手记 id>/<附件 id>/<文件>`（如 `…_resized.heic`），缩略图在 `Caches/Images-v4`。
  「手记」内部叫 moments。App 组 `group.com.apple.Journal` 里几乎是空的。读写这个容器要完全磁盘访问。
- **[观测]** 模型在 `JournalShared.framework/Resources/moments.momd`，当前版本 `JournalData_27`（还有 22、23 和最早的 moments）。
  7 个实体：`JournalEntryMO`（手记）、`JournalMO`（手记本）、`JournalEntryAssetMO`（附件）、`JournalEntryAssetFileAttachmentMO`
  （附件的文件）、`JournalEntryAssetAttachmentMO`（附件的数据块）、`AppStorageMO`（侧栏等设置）、`SyncDataMO`（同步状态）。
  手记和手记本是多对多（`Z_5JOURNALS`）。库开着持久化历史（`ATRANSACTION`/`ACHANGE`）和 Core Spotlight 索引。
- **[观测]** 3.0 之前写的手记：正文 `ZTEXT`、标题 `ZTITLE`、写作提示 `ZPROMPT` 都是 RTF；附件顺序 `ZASSETORDERING` 是附件 id 的 JSON 数组。
- **[观测]** 3.0 的手记：`ZMERGEABLEATTRIBUTES` 是 `MergeableEntryAttributes`（标题、正文、附件排布、所属手记本 id 集合），
  手记本的 `MergeableJournalAttributes`（名称、颜色、图标）也是。序列化格式以 `crdt` 魔数开头，后面是 Coherence 的 protobuf。
  它们经命名值转换器（`MergeableEntryAttributesTransformer` 等）存取，转换器在读 `NSManagedObjectModel.shared` 时才注册。
- **[观测]** 附件元数据 `ZASSETMETADATA` 是 JSON，键就是 Swift 属性名（日期是自 2001 年起的秒数，Data 是 base64）；库文件里它前面的
  `0x01` 是 Core Data「数据存在行内」的标记，经 Core Data 读写时没有这个字节。
  类型（`ZASSETTYPE`）：photo、livePhoto、video、audio、visit、genericMap、multiPinMap、stateOfMind、workoutIcon、workoutRoute、
  motionActivity、music、podcast、book、thirdPartyMedia、contact、link、reflection、drawing、confetti、streakEvent、placeholder。
  录音的转写在 `transcriptSegments[].text`；心理状态的 `labels`/`domains`/`valenceClassification` 是 HealthKit 的
  HKStateOfMind 枚举（从 1 起，按 SDK 头文件的顺序）。

## 2. 「手记」开放的接口

- **[观测]** 没有 AppleScript（无 sdef）。App Intents（`Metadata.appintents`）只有 4 个：`CreateEntryIntent`（message、title、
  locationName、mediaItems、location、entryBookmark、entryDate，可后台跑）、`SearchEntriesIntent`、`OpenEntryEntityIntent`、
  `CreateEntryAudioIntent`（后三个要打开 App）。没有修改、删除、手记本相关的 intent。
- **[观测]** JournalShared 的 Objective-C 面很小：只有各个 `*MO` 类和 `WrappedMergeable*`。业务逻辑都在 Swift 里，但 Swift
  符号是导出的（`dyld_info -exports` 有 3,224 个），其中有完整的领域 API，例如
  `JournalMO.create(context:title:color:icon:id:)`、`JournalMO.delete(_:moveEntriesToJournalID:context:)`、
  `JournalMO.delete(_:shouldDeleteEntries:)`、`JournalEntryMO.create(type:context:uuid:)`、`add(to:)`/`remove(from:)`、
  `markAsRecentlyDeleted()`/`recoverRecentlyDeleted()`/`markAsPermanentlyDeleted()`、`deepCopy()`、
  `mergeableAttributedText`/`mergeableAttributedTitle`、`updateSortingColumns()`、`computeAndSetAggregateMinimumVersion()`。
- **[观测]** SDK 里有 JournalShared 和 Coherence 的 `.tbd`，但带 `allowable-clients` 限制（只许「手记」自己的各个部件链接），
  也没有 `.swiftinterface`。
- **[观测]** 共享扩展（`JournalShareExtension.appex`）链接 JournalShared、Coherence 和 Core Data，自己在另一个进程里直接写库。
  **[推断]** 所以「手记」本来就要处理别的进程写进来的改动。

## 3. 怎么从外部调用 Swift 私有框架

- **[观测]** 手写 `JournalShared.swiftinterface` 和 `Coherence.swiftinterface`（`-enable-library-evolution`），只声明用到的部分，
  编译器生成的符号名和框架导出的一致就能直接调用；类型都是 resilient 的，不依赖内存布局。链接用自己生成的 `.tbd`（只列用到的
  符号，没有 allowable-clients），并且弱链接，这样缺符号时 App 仍能启动。`scripts/journal-stubs.py` 生成 `.tbd` 和运行时检查用的
  符号表，目前 JournalShared 129 个、Coherence 13 个。
- **[观测] 坑**：
  - 方法写在 extension 里才会直接调用；写在类体里编译器会走 dispatch thunk（`Tj`），而框架没导出它，链接失败。`value` 这类
    final 的属性要声明成 `final`。
  - 协议要写对是否 class-bound：`RecordEditing` 声明成普通协议时，`self` 按间接方式传，调用即崩（SIGBUS）。
  - 属性的类型种类（struct / enum）要写对：`MergeableTextAttributeScope.FontAttribute` 等是 enum。
  - CF 类型写成 `CGColor`，编译器会自动按 `So10CGColorRefa` 改编名字；写 `CGColorRef` 反而编译不过。
  - 关联类型（如 `CRAttributeStringKey.Value`）在接口里必须给出具体类型；不知道时用运行时查：
    `swift_conformsToProtocol` 拿 witness table，`swift_getAssociatedTypeWitness` 拿关联类型，`swift_getTypeName` 打印。
    结果：font→`MergeableFont`、underline/strikethrough→`Int`、textLists→`MergeableTextLists`、blockQuote→`Bool`、
    alignment/writingDirection/anchorAlignment→`CRExtensible<…>`、assetAttachment→`MergeableAssetTextAttachment`、
    adaptiveImageGlyph→`MergeableAdaptiveImageGlyph`、followUpPromptAttachment→`MergeableFollowUpPromptAttachment`。
  - Swift 6.4 编译器在 typed throws 函数里遇到 `catch let error as NSError` 会断言崩溃（SILGen `createInitExistentialRef`），
    改成 `catch` 再转换即可。
- **[观测]** 读枚举值的名字（如手记本的调色板颜色 `AssetCatalogColor.sage`）可以靠 Swift 反射：`String(describing:)` 能打出
  框架里的 case 名，不必再声明 `CRExtensible`。

## 4. 同步：外部写入会不会被上传

- **[观测]** 同步用 CKSyncEngine（`JournalSyncEngineDelegate`）。各实体有 `objectsToSavePredicate`/`objectsToDeletePredicate`：
  - 手记：`isUploadedToCloud == 0 AND isTip 非真 AND isDraft 非真 AND isRemovedFromCloud == 0` 上传；`isRemovedFromCloud == 1` 删除。
  - 手记本：`isUploadedToCloud == 0 AND mergeableAttributes != nil AND userDeleted == 0` 上传；
    `userDeleted == 1 AND (isUploadedToCloud == 0 OR mergeableAttributes != nil)` 删除。
- **[观测]** 实测：本进程用「手记」的模型和类、带 `NSPersistentHistoryTrackingKey` 和
  `NSPersistentStoreRemoteChangeNotificationPostOptionKey` 打开库写入，正在运行的「手记」在约 4–10 秒内把改动上传
  （`isUploadedToCloud` 变 1，`recordSystemFields` 出现、变化）。新建手记本、新建手记、改正文、加书签、改日期、删除、恢复、
  复制、永久删除（行随后被「手记」删掉）、删除手记本（移走或连同手记）都验证过。
- **[观测] 坑**：
  - `JournalEntryMO.create(type:context:uuid: nil)` 不会给 `id`，没有 id 的手记永远不会上传；要传 UUID。
  - 改正文、标题、书签等 setter 不会自己标记上传。`RecordEditing.markForReupload()`（反汇编看到）只做两件事：
    `updatedDate = 现在`、`isUploadedToCloud = false`，用 KVC 照做即可。
  - 判断是否已上传不能在同一个 context 里重新 fetch（`shouldRefreshRefetchedObjects` 也拿不到新值），要用字典结果的 fetch
    或新 context 读行。
  - `SyncDataMO.acAccountID` 在本机为空，但同步在跑；判断「是否在用 iCloud」看 `statedata` 是否非空。

- **[观测]** 每篇手记被永久删除后，「手记」会建两条没有所属手记的 `streakEvent` 附件（元数据 `{"entryID", "date"}`，
  日期为写下和删除的时间），这样删除不会打断连续纪录。附件的删除条件是 `isRemovedFromCloud == 1`。**[推断]** 所以「手记」的分析
  也算已删除手记的那些天；本 App 的 `overview` 只按现存手记的日期算。

## 5. 正文格式

- **[观测]** `CRAttributedString<Scope>` 的 `init(NSAttributedString)` 只把属性留在内存里，保存后全部丢失。要按 Scope 的类型化
  属性写：`CRAttributedString.Attributes()` 加 `@dynamicMemberLookup` 下标（`\MergeableTextAttributeScope.font` 等），再
  `setAttributes(_:range:)`。保存、重开后读回：粗体（traits 2）、斜体（1）、下划线、删除线、列表（`{disc}`、`{hyphen}`、
  `{decimal}`，嵌套是多个 list）、引用都在。下标和长度按 UTF-16 计。
- **[观测]** 3.0 之前的 RTF 手记，`mergeableAttributedText` 的 setter 在 `mergeableAttributes` 为空时什么也不做；所以这类手记保持
  RTF，修改时写 RTF（引用在 RTF 里没有，写成普通段落）。
- **[推断]** 「手记」自己的 NSAttributedString ↔ CRDT 转换在 JournalUI（`AttributeConverter`、
  `CRAttributedString.replace(with:traitCollection:)`），但 JournalUI 是 iOSSupport（UIKit）框架，不宜加载进 AppKit 进程，所以自己按
  上面的类型化属性做映射，并且只改有差别的那一段（保留其余部分的颜色、对齐和合并历史）。**[未知]** 在「手记」界面里亲眼确认显示效果
  （本次没有取得操作「手记」窗口的许可）；读回的类型化属性与 Scope 定义一致。

## 6. 添加附件（用 Hopper 逆向 Journal.app 得出）

- **[观测]** 「手记」保存附件（`saveAttachments`）：文件写到 `<手记 id>/<附件 id>/<fileNameID>.<扩展名>`（照片先缩到约 600 万像素，
  再用 `UIImageHEICRepresentation` 存成 `<UUID>_resized.heic`；库里已有的照片是 2829×2122，正是 4032×3024 缩到 600 万像素）。
  文件记录 `JournalEntryAssetFileAttachmentMO`：新 `id`、`filePath`（相对 `Attachments/`）、`index`、`name`、`needsProcessing = 1`，
  按 (index, name) 复用已有记录。`name` 按附件内容取 `image` / `video` / `audio` / `other`。
- **[观测]** 视频要在同一个 index 上再有一张 `image` 静帧：缩略图代码按 index 找类型为图片的文件，找不到就记
  "Couldn't generate a thumbnail for video asset"；补上静帧后记 "Thumbnail created for video asset from file"。实况照片同理（image + video）。
- **[观测]** `JournalEntryAssetMO` 由「手记」设 `id`、创建/更新日期、`assetType`、`source`、`isHidden`、`minimumSupportedAppVersion`
  （photo/video/audio 为 0），元数据用 JournalShared 自己的类型编码（`Encodable.asData`）：photo/video/livePhoto 解码为
  `PhotoLibraryAssetMetadata`（`date`、`size`、三种裁切框、`displayAtFullAspectRatio`、可选的地点），audio 为 `AudioAssetMetadata`
  （`duration`、`intensities`、`recordingDate`、`transcriptSegments`）。`parentID` 保存时不会自动填，从 iCloud 下来的记录有，所以自己填
  （附件 → 手记 id，文件 → 附件 id）。
- **[观测]** 排布：`EntryViewModel` 先 `assetPlacement(forAssetID:)` 取旧位置，`addOrMoveAsset(withID:to:from:)`，再
  `MergeableEntryAttributes.merge(assetPlacement:)`、`JournalEntryMO.modifyLegacyAssetOrderingFields(from:)`、`isUploadedToCloud = 0`。
  `JournalEntryMO.mergeableAssetPlacement` 的 setter 做的就是合并；3.0 之前的手记 setter 不起作用、`mergeableAttributes` 仍为空，
  旧的 `assetOrdering`（`[id, 位置, …]` 的 JSON）由 `modifyLegacyAssetOrderingFields` 写。网格最多 `AssetPlacement.Constants.maxGridCount`（53）个。
- **[观测]** `needsProcessing` 的文件不上传（文件的上传条件含 `needsProcessing == 0 OR nil`）。「手记」的
  `AssetPostprocessingOperation` 处理照片、视频、录音时记 "unsupported asset type" 并清掉标记；所以本 App 直接写 0。
- **[观测]** 录音的波形：「手记」用 `AudioIntensityProcessor(computesAverageIntensity: false).readAudioIntensityLevels(from: AVURLAsset)`
  的第一个数组（约每秒 25 个）。它只给自己录音器里正在录的录音（`isBeingEdited` 或 `isHidden`）补算，所以本 App 自己调用这段代码算好再写。
  这个 async 方法是 `nonisolated(nonsending)`：调用方在 x0/x1 传自己的 actor（nil 时为 0、0），然后才是参数；符号名里看不出来，
  接口里不这样声明就会把 AVAsset 传成 nil 而崩溃。**[观测]** 转写只对「手记」录音器的录音做（"No existing audio files to transcribe"）。
- **[观测]** 移除：编辑器里先标 `isUndoablyDeleted`；本 App 像删手记那样标 `isRemovedFromCloud = 1` 并从排布里去掉。「手记」删除 iCloud 记录后
  删掉本机的附件行（级联删除文件记录）和文件夹。「手记」永久删除手记时只标手记本身，附件靠级联。
- **[观测]** 实测：照片、视频（带静帧）、录音（带波形）写入后几秒内全部上传（文件记录有 `recordSystemFields`），「手记」为视频生成了缩略图。
  **[未知]** 在「手记」界面里亲眼确认显示效果（没有操作「手记」窗口的许可）。

## 7. 做不到或没做的

- **添加涂鸦、实况照片、地点、心理状态等其他种类的附件**：来自 PencilKit、照片图库或系统服务，不是普通文件。
- **把附件放进正文（canvas 排布 + 正文里的 `MergeableAssetTextAttachment`）**：没做；正文里的附件也不让移除。
- **手记建议**：来自 momentsd（`com.apple.momentsd`、`MOSuggestion…`），需要 `com.apple.developer.journal.allow` /
  `com.apple.moments.allowSuggestions` 等权限。
- **设备上生成的写作提示 / 后续提示**：「手记」用 FoundationModels / GenerativeModels，带私有 entitlement。已有的提示可读。
- **心理状态写入「健康」**：要 HealthKit 和「手记」的授权。
- **锁定手记、写手记计划和通知、打印、「手记」自带的导出归档和导入**：是 App 自己的设置和动作，不在库里。
- **其他版本**：接口按 27.2 的导出符号写；别的版本缺符号时整个 App 报不支持，不读不写。

## 附：复现

```bash
sqlite3 "file:$HOME/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite?mode=ro" ".backup '/tmp/x/moments.sqlite'"
dyld_info -exports /System/Library/PrivateFrameworks/JournalShared.framework/Versions/A/JournalShared | swift demangle
/usr/bin/python3 -I scripts/journal-stubs.py      # 重新生成 .tbd 和符号表
.build/debug/AppleJournalMCP --check-markdown     # 只读：每条手记 Markdown 往返是否无损
```
