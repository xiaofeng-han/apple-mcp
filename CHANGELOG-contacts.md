# Apple Contacts MCP changelog

Each `## <version>` section is that version's release note, exactly as `scripts/release.sh contacts <version>` publishes it: the English part, a line `---`, then the Chinese part. The script puts the requirements and the install commands for that version between the two, so they are not written here. Write the section before running the script; it stops if there is none.

Apple Contacts MCP is released with tags `contacts-v<version>`.

## 0.1.0

**First release**

- **Read and write Apple's Contacts app.** People and companies with every field Contacts has: the names (with phonetic, maiden name and name order), company, department, job title, the note, phones, emails, web addresses, postal addresses, birthday and a birthday in another calendar, other dates, related people, social profiles, instant-message addresses, the photo and its crop, ringtone and text tone, Emergency Bypass and Downtime. Plus linked cards (link, unlink, which card gives the name or photo), Look for Duplicates and Merge, groups with nested groups and distribution lists, smart lists with their rules, the My Card, the default account and syncing now, Contacts' settings, what changed since last time, and vCard import and export with notes and photos.
- **Native, and synced by Contacts.** Changes go through Contacts' own frameworks (Contacts and AddressBook), and notes through Contacts itself, since macOS keeps notes from other apps; Contacts uploads each change to iCloud, and creating or changing a contact answers once it has.
- **Safe to use from agents.** Every change checks the version that was read, so nothing changed meanwhile is overwritten. Contacts has no Recently Deleted, so the app keeps a copy of every contact it deletes or merges away for 30 days and can bring it back with the same id.
- Needs the Contacts and Automation → Contacts permissions, and macOS 26 or later. Pronouns, Favorites, blocking, Emergency Contacts, posters, family members' accounts, adding accounts, printing, CSV import and the notes of contacts allowed during Screen Time's Downtime are not possible; see the documentation.

---

**首个版本**：读写苹果的「通讯录」App。个人和公司的全部字段：姓名（含拼音、娘家姓和姓名顺序）、公司、部门、职位、备注、电话、电子邮件、网址、地址、生日和另一种历法的生日、其他日期、关联人、社交资料、即时通讯账号、头像及其裁剪、电话铃声和短信提示音、紧急绕过和停用时间。还有链接的卡片（链接、取消链接、由哪张卡提供姓名或头像）、查找重复项和合并、带嵌套和分发列表的分组、带规则的智能分组、我的名片、默认账户和立即同步、「通讯录」的设置、上次以来的变更，以及带备注和头像的 vCard 导入导出。改动走「通讯录」自己的框架（Contacts 和 AddressBook），备注经「通讯录」本身读写，因为 macOS 不让别的 App 碰备注；「通讯录」把每次改动上传到 iCloud，新建和修改联系人会等上传完成再回答。每次修改都核对读到的版本，不会覆盖期间的改动。「通讯录」没有「最近删除」，所以这个 App 删除或合并掉的每个联系人都留一份副本 30 天，可以用原来的 id 找回。需要「通讯录」和「自动化 → 通讯录」权限，以及 macOS 26 或更新版本。代词、个人收藏、阻止、紧急联系人、海报、家庭成员的账户、添加账户、打印、导入 CSV，以及屏幕使用时间「停用时间」里允许的联系人的备注做不到，详见文档。
