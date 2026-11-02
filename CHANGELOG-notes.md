# Apple Notes MCP changelog

Each `## <version>` section is that version's release note, exactly as `scripts/release.sh notes <version>` publishes it: the English part, a line `---`, then the Chinese part. The script puts the requirements and the install commands for that version between the two, so they are not written here. Write the section before running the script; it stops if there is none.

From 0.4.0 on, Apple Notes MCP is released from this repository, tagged `notes-v<version>`. Releases 0.1.0 to 0.3.0 are on the [Releases of apple-notes-mcp](https://github.com/xiaofeng-han/apple-notes-mcp/releases) (archived), tagged `v<version>`; their notes (from 0.2.0) are kept below.

## 0.5.0

**What's new**

For scripts that keep Apple Notes in step with another store, such as a knowledge base kept in Notion:

- **`--list-json` gives each note's version and description.** Every row now has the `version` that `read_note` gives (`?` for a note that cannot be read) and, when one is saved, the `description` written with `describe_note`. Reading the versions means reading every listed note, so the list is a little slower than before.
- **Answers as JSON.** Every command, and `call`, takes `--format json` and then prints one JSON object: `notes list`, `folders list`, `notes search` and `notes read` give whole ids, versions, ISO 8601 dates and the Markdown; `notes create`, `copy`, `edit`, `move`, `delete` and `describe` give what they changed, whether it was uploaded, and what failed. Other commands give `{"text": …}`, and a failure is `{"error": …}` on stderr. MCP answers stay text.
- **A folder guard.** `APPLE_NOTES_MCP_WRITE_FOLDERS=KB/Wiki,KB/Inbox` limits every change to those folders and the folders inside them: notes outside them are not edited, created, moved or deleted, folders change only inside them, and smart folders not at all. Reading is not limited. It works alongside `APPLE_NOTES_MCP_WRITE_GUARD`, and `--self-check` shows it.
- **Section edits.** `edit_note` takes `replace_section` (`--replace-section '{"heading":"…","markdown":"…"}'`), which replaces what is under a heading and keeps the heading, and `replace_before`, which replaces everything between the title and a heading. They go with `replace`, `insert` and the checklist changes in one call.
- **`wait: false` for batches.** `create_note`, `edit_note` and `move_note` take `wait: false` (`--no-wait`): the change is saved and its upload requested, and the answer comes at once instead of after iCloud confirms it. iCloud still syncs, only not confirmed per call.
- **A key of your own.** A script can keep its own key for a note, such as `notion:<page id>`, as the note's description with `describe_note`: it shows in `--list-json` and `notes list --format json`, and lives in this app's own file, never in the note.

The MCP tool list gained optional fields (`wait` on three tools, `replace_section` and `replace_before` on `edit_note`); nothing an agent sends today changes meaning, and agents see the new fields in their next session without being set up again. Agents set up with the skill get the new flags when its text is updated (the AI Assistants tab offers **Update**). Permissions granted to 0.4.2 still apply after upgrading.

---

**更新**：给让「备忘录」与其他存储（比如放在 Notion 里的知识库）保持同步的脚本用。`--list-json` 每行多了 `read_note` 给的 `version`（读不了的笔记是 `?`），以及用 `describe_note` 保存的 `description`（有才出现）；因为要读每条笔记来算版本号，会比以前稍慢。所有命令和 `call` 都支持 `--format json`，打印一个 JSON 对象：`notes list`、`folders list`、`notes search` 和 `notes read` 给出完整 id、版本号、ISO 8601 日期和 Markdown；`notes create`、`copy`、`edit`、`move`、`delete`、`describe` 给出改了什么、是否已上传、哪些失败；其他命令给 `{"text": …}`，失败时在 stderr 打印 `{"error": …}`；MCP 的回答仍是文本。新增按文件夹的写保护：`APPLE_NOTES_MCP_WRITE_FOLDERS=KB/Wiki,KB/Inbox` 把所有修改限制在这些文件夹及其中的文件夹里，读取不受限，可以和 `APPLE_NOTES_MCP_WRITE_GUARD` 同时使用，`--self-check` 会显示。`edit_note` 新增 `replace_section`（`--replace-section '{"heading":"…","markdown":"…"}'`，替换某个小标题下的内容，保留小标题）和 `replace_before`（替换标题和某个小标题之间的内容），可以和 `replace`、`insert`、清单修改在一次调用里一起用。`create_note`、`edit_note`、`move_note` 支持 `wait: false`（`--no-wait`）：保存并请求上传后立刻返回，不等 iCloud 确认，适合批量写入；iCloud 照样同步。脚本可以用 `describe_note` 把自己的标识（比如 `notion:<页面 id>`）存成笔记的简介，它会出现在 `--list-json` 和 `notes list --format json` 里，只存在本 App 自己的文件中，不碰笔记。MCP 工具只多了可选字段，现有调用的含义不变，agent 下次会话就能看到，不用重新配置；用技能配置的 agent 在技能文字更新后（「AI 助手」标签页会显示「更新」）得到新参数。已授予 0.4.2 的权限仍然有效。需要 macOS 26 或更新、Apple 芯片。详见[文档（中文）](https://github.com/xiaofeng-han/apple-mcp/blob/notes-v0.5.0/docs/notes.zh-CN.md)。

## 0.4.2

**What's new**

- **Homebrew no longer asks for an administrator password.** The cask now installs the app from a zip on the release instead of from the installer package, which Homebrew can only run with `sudo`. From now on `brew install`, `brew upgrade` and `brew uninstall` need no password. The app, its place in `/Applications`, its signature and its permissions stay the same. Upgrading from 0.4.1 or earlier asks for the password one last time, to remove the copy the package installed. The package is still on the release, for installing without Homebrew.

The app works as 0.4.1 did: the MCP tools, the commands and the skill are unchanged, so agents set up for it stay set up. Permissions granted to 0.4.1 still apply after upgrading.

---

**更新**：Homebrew 不再要管理员密码。cask 改为从 release 上的 zip 安装 App，不再用安装包（Homebrew 装安装包只能用 `sudo`），以后 `brew install`、`brew upgrade`、`brew uninstall` 都不用输密码。App、它在 `/Applications` 的位置、签名和权限都不变。从 0.4.1 或更早的版本升级时还会最后要一次密码，用来删掉安装包装的那一份。不用 Homebrew 的话，release 上仍有安装包。App 用起来和 0.4.1 一样：MCP 工具、命令和技能都没变，已配置的 agent 不用重新配置，已授予的权限仍然有效。需要 macOS 26 或更新、Apple 芯片。详见[文档（中文）](https://github.com/xiaofeng-han/apple-mcp/blob/notes-v0.4.2/docs/notes.zh-CN.md)。

## 0.4.1

**What's new**

- **A note list for editors and scripts.** `apple-notes-mcp --list-json [QUERY]` prints one JSON object per line, with each note's full `id`, `title`, `folder` and `modified`. Without a query it lists every note that is not locked, newest first. With one, it lists the search results, best match first and at most 100, each with a `snippet`. The text lists cut titles and shorten ids, but these values are whole, and a row stays on one line even when its title or snippet has a line break. Contributed by @DisturbedOcean for a Neovim picker ([apple-notes-mcp#5](https://github.com/xiaofeng-han/apple-notes-mcp/pull/5)).

The MCP tools, the other commands and the skill are the same as in 0.4.0, so agents set up for it stay set up. Permissions granted to 0.4.0 still apply after upgrading.

---

**更新**：新增 `apple-notes-mcp --list-json [查询]`，给编辑器和脚本用。每行一个 JSON 对象，含笔记完整的 `id`、`title`、`folder` 和 `modified`。不带查询时列出所有没上锁的笔记，最新的在前；带查询时是搜索结果，最匹配的在前（最多 100 条），每条多一个 `snippet`。标题或摘要里有换行时，一条仍只占一行。由 @DisturbedOcean 为 Neovim 的选择器贡献（[apple-notes-mcp#5](https://github.com/xiaofeng-han/apple-notes-mcp/pull/5)）。MCP 工具、其他命令和技能与 0.4.0 相同，已配置的 agent 不用重新配置，已授予的权限仍然有效。需要 macOS 26 或更新、Apple 芯片。详见[文档（中文）](https://github.com/xiaofeng-han/apple-mcp/blob/notes-v0.4.1/docs/notes.zh-CN.md)。

## 0.4.0

**What's new**

- **A new home.** Apple Notes MCP is now developed and released in [apple-mcp](https://github.com/xiaofeng-han/apple-mcp), together with Apple Reminders MCP, on one shared base: the server, the command line, the settings window and setting up agents are written once for both. The app itself stays as it was: the same command, cask, server name, tools, permissions and settings, and agents set up for 0.3.0 stay set up. `brew upgrade` moves to the releases there by itself.
- **The Tools tab** shows `manage_tag` with its Chinese title, which it lacked.
- **Setting up and installing agents** no longer risks waiting forever on a program that has already finished, which could happen when several ran at once.

The MCP tools and commands are unchanged from 0.3.0. Permissions granted to 0.3.0 still apply after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：Apple Notes MCP 搬到了 [apple-mcp](https://github.com/xiaofeng-han/apple-mcp)，和 Apple Reminders MCP 一起开发和发布，共用一套底座（服务器、命令行、设置窗口和 agent 配置只写一份）。App 本身不变：命令、cask、服务器名、工具、权限和设置都和以前一样，为 0.3.0 配置好的 agent 不用重新配置，`brew upgrade` 会自动改从新仓库下载。「工具」标签页补上了 `manage_tag` 的中文标题。配置和安装 agent 时，不会再因为同时跑了几个程序而一直等一个早已结束的程序。MCP 工具和命令与 0.3.0 相同，已授予的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见[文档（中文）](https://github.com/xiaofeng-han/apple-mcp/blob/notes-v0.4.0/docs/notes.zh-CN.md)。

## 0.3.0

**What's new**

- **More to read and find.** `read_attachment` gives a recording's transcript and summaries, as Notes made them. `search` also finds the text Notes recognized in images, scans and handwriting, and in recording transcripts, and says where a hit is. `overview` lists Recently Deleted (with the days each note has left), the smart folders and the tags, and narrows notes by tags, groups (pinned, shared, locked, Quick Notes, Math Notes, call recordings, checklists, unticked items, mentions…) and attachment kinds, or sorts them by when they were last opened. `read_note` says whether a note is pinned and which notes link to it.
- **New Markdown.** `#tag` is a real Notes tag, `[text](note:ID)` a link to a note, `---` a divider line, and `<mark class="pink">` (also orange, mint, blue) keeps a highlight's color. `![name](/path/to/file)` attaches a file and `![](https://…)` adds a link card. Literal text that would read as one of these is written `\#word` or `\---`.
- **More to change.** `edit_note` pins and unpins, ticks and unticks checklist items by their text, and ticks all, unticks all, moves ticked items to the bottom or deletes them. `create_note` copies a note with everything in it (`copy_of`). `move_note` and `delete_note` take several notes at once. `manage_folder` moves a folder into another or to the top level, and makes, renames and deletes smart folders from tags. The new `manage_tag` renames a tag in every note or takes it out of every note.
- **Every change names the version it was made against.** Like Apple Reminders MCP, `edit_note`, `move_note` and `delete_note` now need the `version` that `read_note`, `overview` or `search` gave (every line of a list has it), and refuse a note changed elsewhere since. Calls without a version are refused, so prompts or scripts written for 0.2.0 need it added.

There are 11 tools now; `manage_tag` starts on unless you turned off another tool labeled Can delete. Permissions granted to 0.2.0 still apply after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：读录音的文字稿和摘要；搜索也搜图片、扫描件、手写里识别出的字和录音文字稿；`overview` 列出「最近删除」、智能文件夹和标签，可按标签、分组（置顶、共享、加锁、快速备忘录、数学笔记、通话录音、清单、未勾选、提及等）和附件类型筛选，按最近打开排序；`read_note` 显示是否置顶和反向链接。Markdown 新增 `#标签`、`[文字](note:ID)` 笔记链接、`---` 分割线、`<mark class="pink">` 等高亮颜色、`![名字](/路径)` 加文件、`![](https://…)` 加链接卡片。`edit_note` 可置顶、按文字勾选清单项、全部勾选或取消、已勾选的移到底部或删掉；`create_note` 可复制整条笔记；`move_note`、`delete_note` 可一次处理多条；`manage_folder` 可移动文件夹、按标签建智能文件夹；新工具 `manage_tag` 全局改名或删除标签。**改、移、删都必须带 `version`**（照 Apple Reminders MCP），不带的调用会被拒绝。共 11 个工具，已授予的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见 [README（中文）](https://github.com/xiaofeng-han/apple-notes-mcp/blob/v0.3.0/README.zh-CN.md)。

## 0.2.0

**What's new**

- **A command line for every tool.** Each MCP tool is now a noun-verb command (`notes search`, `notes edit`, `folders export`, …), with flags taken from the tool's input fields, so the command line and the server accept the same things. `apple-notes-mcp help` prints the whole tree, `call TOOL JSON` runs any tool, and `-` as the Markdown of `notes create`, `--insert` or `--rewrite` reads it from stdin. `attachments read` saves images, audio and files to `--output-dir` and prints where.
- **Set agents up with a skill instead of the server.** `apple-notes-mcp skill` prints a SKILL.md that teaches an agent the command line. The **AI Assistants** tab can now set each agent up as **MCP Server** or **Skill**, for every project or for one project folder, and `agents list/set-up/install` take `--skill` and `--folder DIR`. The agent reads the skill only when notes come up, so no tool list sits in its context. Inside a sandbox (Codex runs commands in one) a missing permission is reported as such, and the agent is asked to run the command outside the sandbox.
- **Choose which tools AI assistants see.** A new **Tools** tab lists the 10 tools, each labeled Read-only, Writes or Can delete. Untick a tool and assistants no longer see it: calling it anyway, through the server or its command, is refused with a message saying where to turn it back on. All, None, Invert and Read-Only change them all at once. The choice is kept in `~/Library/Application Support/AppleNotesMCP/tools.json`, so updates and reinstalls keep it, and running assistants are told of a change at once.

The MCP tools themselves are unchanged from 0.1.0. Permissions granted to 0.1.0 still apply after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：每个工具都有了对应的命令行命令（`notes search`、`notes edit`、`folders export` 等），参数来自工具的输入字段，`help` 列出全部命令，`call` 可直接调用任意工具，Markdown 参数写 `-` 从标准输入读。新增「技能」配置方式：`skill` 输出教 agent 用命令行的 SKILL.md，「AI 助手」标签页可选「MCP 服务器」或「技能」，全局或指定项目文件夹，`agents` 命令加了 `--skill` 和 `--folder`；在沙盒里缺权限时会提示到沙盒外重跑。新增「工具」标签页：勾选开放给 AI 助手的工具（10 个，标明只读、写入或可删除），关掉的工具不出现在工具列表里，经服务器或命令行调用都会被拒绝；选择保存在 `~/Library/Application Support/AppleNotesMCP/tools.json`，更新后保留，正在运行的助手会立即收到通知。MCP 工具本身与 0.1.0 相同，已授予的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见 [README（中文）](https://github.com/xiaofeng-han/apple-notes-mcp/blob/v0.2.0/README.zh-CN.md)。
