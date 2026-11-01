# Apple Journal MCP changelog

Each `## <version>` section is that version's release note, exactly as `scripts/release.sh journal <version>` publishes it: the English part, a line `---`, then the Chinese part. The script puts the requirements and the install commands for that version between the two, so they are not written here. Write the section before running the script; it stops if there is none.

Apple Journal MCP is released with tags `journal-v<version>`.

## 0.1.0

**First release**

- **Read and write Apple's Journal app.** Entries with their title, text and formatting (as Markdown), date, bookmark and journal; journals with their name, color and icon; Recently Deleted; duplicates; and the details of every kind of attachment: photos, videos, recordings with their transcripts, places, State of Mind, workouts, music, books, contacts, links, reflections and drawings. Plus Journal's insights (days journaled, streaks) and an export to Markdown with the attachments.
- **Native, and synced by Journal.** Changes go through Journal's own data model, only where they differ, so the rest of an entry keeps its formatting and merges with edits from other devices; Journal uploads each change to iCloud, and the answer says when it has.
- **Safe to use from agents.** Every change checks the version that was read, so nothing changed meanwhile is overwritten; deleting goes to Recently Deleted first; deleting a journal with its entries needs their number.
- Needs Full Disk Access and Journal 3.0 (macOS 27.2). Adding photos, recordings or drawings to entries, Journaling Suggestions and generated prompts are not possible; see the documentation.

---

**首个版本**：读写苹果的「手记」App。手记的标题、正文和格式（Markdown）、日期、书签和所属手记本；手记本的名称、颜色和图标；最近删除；复制；以及各种附件的详情：照片、视频、录音及其转写、地点、心理状态、体能训练、音乐、图书、联系人、链接、回顾和涂鸦。还有「手记」的分析（写手记的天数、连续纪录）和带附件的 Markdown 导出。改动走「手记」自己的数据模型，只写有差别的部分，其余部分保留格式，并能与其他设备上的修改合并；「手记」把每次改动上传到 iCloud，回答里会说明是否已上传。每次修改都核对读到的版本，不会覆盖期间的改动；删除先进「最近删除」；连同手记删除手记本需要给出手记数量。需要完全磁盘访问和「手记」3.0（macOS 27.2）。往手记里添加照片、录音或涂鸦，手记建议和生成的提示做不到，详见文档。
