# Apple 通讯录（Contacts.app）逆向结论

2026-11-13，MacBook（macOS 27.2.1，「通讯录」14.0，build 2768.200.91；Contacts.framework 3846.200.91）。
用 SDK 头文件、`otool`/`nm`、lldb 跟踪 Contacts.app、`defaults`、`Contacts.sdef`，以及一个和本 App 同
bundle id、同签名的探针 App（它拿到的权限和本 App 一样）。所有写入都只用名字以 `agent test` 开头的测试数据。
目标：让 agent 能读写「通讯录」的全部功能，做不到的说明原因。

标记：**[观测]** 直接看到的；**[推断]** 由观测推出的；**[未知]** 没查清的。

## 1. 数据在哪，谁能读

- **[观测]** 数据在 `~/Library/Application Support/AddressBook/`：一个总库 `AddressBook-v22.abcddb`，
  每个账户在 `Sources/<UUID>/` 下各有一个库（Core Data / SQLite，由私有的 ContactsPersistence 管）。
- **[观测]** 即使有「通讯录」权限，本 App 进程直接打开这些 SQLite 也会得到 `authorization denied`；
  Contacts.framework 在同一进程里却能读写。**[推断]** 框架经 contactsd 拿到访问权，App 自己不行，所以一切
  都要经框架（或 AppleScript）走，不能像「手记」那样直接开库。
- **[观测]** Contacts.app 链接公开的 Contacts.framework、私有的 ContactsFoundation / ContactsPersistence /
  vCard，以及老的 AddressBook.framework（版本和 App 相同）。智能分组、分发列表、合并、打印这些功能在
  AddressBook 和 Contacts.app 可执行文件里，不在 Contacts.framework 里。

## 2. 三条路，各管一块

| 路 | 管什么 | 为什么 |
|---|---|---|
| Contacts.framework（公开 API + 少量私有方法，经 `ContactsShim`） | 卡片的全部字段、分组、账户、我的名片、变更历史、vCard、搜索 | 公开、稳定，是 Contacts.app 自己的数据层 |
| AddressBook.framework（进程内，每次新建 `[ABAddressBook addressBook]`） | 智能分组、分发列表、链接/取消链接、默认账户、立即同步、取消嵌套 | Contacts.framework 没有这些，或者做了也不生效（见 §4） |
| 「通讯录」的 AppleScript（自动化权限） | 备注、分组成员 | macOS 不给没有苹果备注授权的 App 碰备注（见 §3） |

- **[观测]** 私有方法用 `NSSelectorFromString` + 按签名强转的 `objc_msgSend` 调用（arm64 上变参版本会传错
  参数，必须强转成具体签名）。用到的有：`CNSaveRequest` 的 `setMeCardIdentifier:`、`linkContact:toContact:`、
  `unlinkContact:`、`setIgnoresGuardianRestrictions:`；`CNMutableContact` 的 `setDisplayNameOrder:`、
  `setCropRect:`、`setThumbnailImageData:`、`setDowntimeWhitelist:`、`setSnapshot:`；`CNActivityAlert` 的
  `initWithSound:vibration:ignoreMute:`；`+[CNContact predicateForContactsMatchingFullTextSearch:containerIdentifiers:groupIdentifiers:]`、
  `predicateForMeContact`；`+[CNGroup predicateForGroupsWithMemberContact:includeAllParentGroups:]`；
  `CNFoundationUserDefaults`；vCard.framework 的 `CNVCardWritingOptions`、`CNVCardEncoding`。
- **[观测]** 私有的读取键：`linkIdentifier`、`preferredForName`、`preferredForImage`、`displayNameOrder`、
  `downtimeWhitelist`、`callAlert`、`textAlert`、`cropRect`、`wallpaperURI`、`watchWallpaperImageData`、
  `externalModificationTag`、`creationDate`、`modificationDate`，都能用 `CNContactFetchRequest` 取到。

## 3. 备注：这次最大的坑

- **[观测]** `+[CNCDContactFetcher inaccessibleKeys]` = `note`、`addressingGrammars`（代词）等。没有苹果授权
  （`com.apple.developer.contacts.notes`）的进程，`CNContactNoteKey` 会被悄悄从 `keysToFetch` 里去掉；
  之后读 `.note` 抛 `CNPropertyNotFetchedException`——这是 Objective-C 异常，Swift 接不住，进程直接崩。
- **[观测]** 更糟的是：**只要卡片有备注（库里有 ZABCDNOTE 行），任何 Contacts.framework 或 AddressBook 的保存都会失败**，
  `NSCocoaErrorDomain 134092`（保存时为搜索索引加载备注，被拒绝）。`updateContact:`、`addMember:toGroup:`、
  `removeMember:fromGroup:`、新建带备注的卡片，全都一样。
- **[观测]** AppleScript 的 `note of person id "<CN id>"` 能读写备注；`set note … to missing value` 再 `save`
  会删掉 ZABCDNOTE 行，之后 Contacts.framework 的保存就恢复正常（设成 `""` 不删行，没用）。
- **采用的做法**：读写备注都走 AppleScript；保存带备注的卡片时，先把备注放到一边（写进
  `notes-aside.json` 留作恢复）→ AppleScript 去掉备注 → 框架保存 → AppleScript 放回备注。
  **[观测]** 三次写在几秒内完成，「通讯录」合并成一次上传。
- **[观测]** AppleScript 的调用方式：`NSAppleScript` 编译一次，用 `'ascr'/'psbr'` Apple 事件调用 handler
  （`keyASSubroutineName` 必须小写），参数用带类型的描述符；`missing value` 返回的是 typeType `'msng'`。
  「通讯录」没在运行时，用 `NSWorkspace` 隐藏启动（不激活），刚启动时会回 `-1728`（找不到对象），重试即可。
- **[观测]** Contacts.app 自己持有一个共享的 ABAddressBook 副本；另一个进程刚新建或恢复的卡片，在这个副本
  里是旧的，`add person to group` 会**静默不生效**。**[推断]** 所以新卡片先经 Contacts.framework 加进分组
  （在放回备注之前，那时卡片还没有备注），之后再经 CN 核对，必要时重试。

### 3a. 屏幕使用时间：「停用时间」里允许的卡片

- **[观测]** 对别的 App，Contacts.framework 把 `downtimeWhitelist` 为 `true` 的卡片当成只读：普通保存报
  `CNErrorDomain 206 "Record is read-only"`；保存请求加私有的 `setIgnoresGuardianRestrictions:YES` 就能存
  （Contacts.app 自己的保存就是这样）。本机所有账户的 `isGuardianRestricted` 都是 NO。**[推断]** 这个开关本来是
  给监护人管理（孩子的屏幕使用时间）用的，所以本 App 只在保存这种卡片（或改 Downtime 本身）时打开它，
  并且账户 `isGuardianRestricted` 为 YES（或读不到）时不打开，让家长的限制照样有效。
- **[观测]** 「通讯录」的 AppleScript 写这种卡片（实测是 `set note … ; save`）时保存失败，而且不报错；
  之后 Contacts.app 把这次改动和**之后所有改动**都留在内存里不存：别的普通卡片的备注、分组成员，读回来
  （AppleScript 读的是 Contacts.app 内存）看着都对，全文搜索（读的是库）却找不到，Contacts.app 一退出就全丢。
  退出 Contacts.app 后恢复正常。可以用 `unsaved` 属性看出来：保存失败后它仍是 true。
- **采用的做法**：从不经 AppleScript 写这种卡片——拒绝改它的备注（它有备注时什么都不能改，因为放备注
  本身要 AppleScript）；加入分组改走 CN 的 `addMember`（卡片没备注时）；拒绝移出分组。每个会保存的
  AppleScript handler 在 `save` 后返回 `unsaved`，为 true 就报错，让用户退出「通讯录」。
- **[未知]** AddressBook 保存这种卡片（链接）失败时返回 `ABAddressBookErrorDomain 0`，没有更多信息；
  因为每次都用新的 ABAddressBook，失败不会拖累之后的调用。

## 4. Contacts.framework 说成功却没做的事

- **[观测]** `-[CNSaveRequest removeMember:fromGroup:]`、`removeSubgroup:fromGroup:` 静默无效（不报错，
  成员关系没变）。移除成员走 AppleScript `remove person … from group …`，取消嵌套走 AddressBook
  `[parent removeSubgroup:child]`。
- **[观测]** `linkContact:toContact:` 在刚启动的进程里能用，但在长时间运行的进程（MCP 服务器）里，
  一旦卡片被同步守护进程改过，就失败 `134040`（Core Data 合并冲突）。新建 `CNContactStore` 也不行。
  **[推断]** Core Data 栈是进程级共享的，缓存的旧版本对不上。改用 AddressBook 的
  `linkPerson:toPerson:` / `unlinkPerson:` / `setPersonWithPreferredName:forLinkedPeople:` /
  `setPersonWithPreferredPhoto:forLinkedPeople:`，每次新建 `[ABAddressBook addressBook]`，没有这个问题。
- **[观测]** 链接后，统一联系人的 id 是共享的 `linkIdentifier`（裸 UUID，没有 `:ABPerson` 后缀），各张卡片
  的 id 是 `<UUID>:ABPerson`。
- **[观测]** `-[CNContactStore usedLabelsForPropertyWithKey:error:]` 返回空数组（不报错），不能用。标准标签用
  `+[CNContactStore standardLabelsForPropertyWithKey:options:]`（关系有 217 个）。

## 5. 上传：怎么知道 iCloud 收到了

- **[观测]** 每张卡片有 CardDAV ETag（私有键 `externalModificationTag`）；服务器接受卡片后会给一个新的 ETag，
  框架能读到。所以写完后轮询 ETag 变化，就知道上传了，不用直接读库。
- **[观测]** 一般 10–15 秒。带头像时 iCloud 会把头像另存，约 8 秒后把卡片再送回来（又改一次），还会把一些
  服务名改写（例如即时通讯的 Skype 变成 `SkypeInstant`）。**[推断]** 所以 ETag 变了之后再等卡片 3 秒没变化
  才算稳定，否则下一次写入会因为版本变了被拒。上限定为 45 秒，带头像 90 秒。
- **[观测]** `+[ABAddressBook _remotelySyncSourcesWithIdentifiers:]` 经 CFMessagePort 让 AddressBookSourceSync
  立即同步，等于 Contacts.app 的「刷新账户」。

## 6. 智能分组、分发列表、账户、设置

- **[观测]** 智能分组是 AddressBook 的 `ABSmartGroup`，Contacts.app 的「新建智能分组」就是
  `[[ABSmartGroup alloc] initWithAddressBook:ab account:<本地账户>]` + `setSearchElement:` +
  `setTracksModification:`（高亮）。只能建在「我的 Mac 上」账户，不同步。
- **[观测]** 规则是 `ABSearchElement` 树：`+[ABPerson searchElementForProperty:label:key:value:comparison:]`，
  `+[ABSearchElement searchElementForConjunction:children:]`。读回来没有公开的 getter，靠私有 ivar
  `_searchProperty`、`_label`、`_key`、`_value`、`_comparison`、`_children`、`_conjunction` 解出来。
  「是/不是某分组成员」是属性 `ABParentGroups`、比较 25/26，值是 AB 的分组记录。
- **[观测]** `[ab removeRecord:smartGroup]` 返回 NO，但其实删掉了；要重新读一遍确认。
- **[观测]** 分发列表：`-[ABGroup distributionIdentifierForProperty:person:]` /
  `setDistributionIdentifier:forProperty:person:`（邮件、电话、地址各一个）。**[推断]** 存在本机库里，
  CardDAV 不同步它。
- **[观测]** 账户：`[ABAccountRepository sharedRepository]` 的 `defaultableAccounts`、`setDefaultAccount:`
  （写 `com.apple.AddressBook` 的 `ABDefaultSourceID`）。添加、移除、启用账户在 ACAccountStore，需要授权，做不到。
- **[观测]** 设置：`com.apple.AddressBook` 域的 `ABNameSortingFormat`（排序）、`ABDefaultAddressCountryCode`
  （地址格式）、`ABUsevCard21Format`、`ABIncludeNotesInVCard`、`ABIncludePhotosInVCard`、
  `ABPrivateVCardFieldsEnabled`；姓名顺序、简称、优先昵称在全局域（`NSPersonNameDefault*`），用
  `CNFoundationUserDefaults` 读；Siri 建议看 `com.apple.suggestions` 的 `AppCanShowSiriSuggestionsBlacklist`。
  改设置会写 `com.apple.AddressBook`，Contacts.app 下次读取时生效。

## 7. 导入导出、删除、变更历史

- **[观测]** 导出：`CNContactVCardSerialization` 加私有的 `CNVCardWritingOptions`（`setOutputVersion:`、
  `setIncludeNotes:`、`setIncludePhotos:`、2.1 的编码）。只设 `includeNotes` 不够：写 NOTE 要求联系人对象
  上 note 键可用，所以导出前在内存里做一个带备注（AppleScript 读来的）的副本；头像要求取了缩略图键。
- **[观测]** 导入：`contactsWithData:` 解析，去掉备注后经框架新建，再经 AppleScript 写备注。Contacts.app 的
  导入重复检查界面（保留旧的/新的/两者/更新）在它的可执行文件里，本 App 按同一账户同名判重，自己处理。
- **[观测]** 「通讯录」没有「最近删除」。变更历史的 DeleteContactEvent 只有 id 和 ETag，删了就找不回。
  Contacts.app 的撤销是 `mutableCopy` + `setSnapshot:nil` 再 `addContact:`，能保留原 id。本 App 删除前用
  `NSKeyedArchiver` 存整张卡片（加备注、分组、账户），恢复时照这个办法，id 不变。
- **[观测]** 变更历史：`CNChangeHistoryFetchRequest` + `currentHistoryToken`；写入时设
  `transactionAuthor`，读取时 `excludedTransactionAuthors` 就能排除自己的改动。
- **[观测]** Contacts.app 的搜索栏用的是全文索引：私有的
  `predicateForContactsMatchingFullTextSearch:containerIdentifiers:groupIdentifiers:`，覆盖备注、地址、
  电话、邮件、网址、社交资料、关联人。

## 8. 做不到的，和能做但没做的

做不到（都是授权问题，不是没找到接口）：

- **[观测] 代词**：`addressingGrammars` 在 inaccessibleKeys 里；加密副本要钥匙串里的
  `com.apple.contacts.keys.pronouns`。私有 setter 存在，但保存时被丢掉。
- **[观测] 个人收藏**：`CNFavorites` 经 XPC 找 contactsd，读能部分读到，改要授权。
- **[观测] 阻止 / 取消阻止**：`CMFBlockList` 写入要授权；读取的接口还会给出错误的「未阻止」。
- **[观测] 紧急联系人**：在 HealthKit 的 Medical ID 里，要「健康」权限和授权。
- **[观测] Siri 建议的确认/忽略、我的共享名字和照片、设置联系人海报**：各自的服务只认苹果的 App。
- **[观测] 家庭成员的联系人**：`+[CNContactStore storeForFamilyMember:]` 要 FamilyCircle 授权。
- **[观测] 恢复 .abbu 归档**：Contacts.app 的做法是删掉所有账户的库再整个换上归档里的，还要完全磁盘访问和
  重启 contactsd；破坏性太大，不提供。
- **[观测] 袖珍通讯录打印**：代码还在可执行文件里，但它的 nib 已经从 App 里删掉了，等于产品里没有这个功能。

能做但没做（第一版）：

- **[观测] 打印列表、导出 PDF、信封、邮寄标签，以及导入 CSV、LDIF**：代码在 Contacts.app 可执行文件里，
  可以 `dlopen` 进本进程（要先建 `NSApplication`，还要替换 Contacts.app 读备注的那个方法，否则撞上 §3 的
  备注限制直接崩）。**[推断]** 这等于把另一个 App 的内部代码当库用，每次 Contacts.app 更新都可能坏，而且
  调用的类和方法都没有任何接口约定，所以第一版没有做。

## 附：复现

```bash
sw_vers                                                                       # 27.2.1
defaults read /System/Applications/Contacts.app/Contents/Info.plist CFBundleVersion    # 2768.200.91
otool -L /System/Applications/Contacts.app/Contents/MacOS/Contacts | grep -i -E 'contact|addressbook|vcard'
# 框架二进制在 dyld 共享缓存里，私有方法用 lldb 挂上 Contacts.app，或在探针 App 里用 class_copyMethodList 列出
sdef /System/Applications/Contacts.app                                        # AppleScript 面
defaults read com.apple.AddressBook                                           # 设置
```
