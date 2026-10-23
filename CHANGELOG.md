# Changelog

Each `## <version>` section is that version's release note, exactly as `scripts/release.sh <version>` publishes it: the English part, a line `---`, then the Chinese part. The script puts the requirements and the install commands for that version between the two, so they are not written here. Write the section before running the script; it stops if there is none.

Releases before 0.2.0 are on [GitHub Releases](https://github.com/xiaofeng-han/apple-notes-mcp/releases).

## 0.2.0

**What's new**

- **A command line for every tool.** Each MCP tool is now a noun-verb command (`notes search`, `notes edit`, `folders export`, …), with flags taken from the tool's input fields, so the command line and the server accept the same things. `apple-notes-mcp help` prints the whole tree, `call TOOL JSON` runs any tool, and `-` as the Markdown of `notes create`, `--insert` or `--rewrite` reads it from stdin. `attachments read` saves images, audio and files to `--output-dir` and prints where.
- **Set agents up with a skill instead of the server.** `apple-notes-mcp skill` prints a SKILL.md that teaches an agent the command line. The **AI Assistants** tab can now set each agent up as **MCP Server** or **Skill**, for every project or for one project folder, and `agents list/set-up/install` take `--skill` and `--folder DIR`. The agent reads the skill only when notes come up, so no tool list sits in its context. Inside a sandbox (Codex runs commands in one) a missing permission is reported as such, and the agent is asked to run the command outside the sandbox.
- **Choose which tools AI assistants see.** A new **Tools** tab lists the 10 tools, each labeled Read-only, Writes or Can delete. Untick a tool and assistants no longer see it: calling it anyway, through the server or its command, is refused with a message saying where to turn it back on. All, None, Invert and Read-Only change them all at once. The choice is kept in `~/Library/Application Support/AppleNotesMCP/tools.json`, so updates and reinstalls keep it, and running assistants are told of a change at once.

The MCP tools themselves are unchanged from 0.1.0. Permissions granted to 0.1.0 still apply after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：每个工具都有了对应的命令行命令（`notes search`、`notes edit`、`folders export` 等），参数来自工具的输入字段，`help` 列出全部命令，`call` 可直接调用任意工具，Markdown 参数写 `-` 从标准输入读。新增「技能」配置方式：`skill` 输出教 agent 用命令行的 SKILL.md，「AI 助手」标签页可选「MCP 服务器」或「技能」，全局或指定项目文件夹，`agents` 命令加了 `--skill` 和 `--folder`；在沙盒里缺权限时会提示到沙盒外重跑。新增「工具」标签页：勾选开放给 AI 助手的工具（10 个，标明只读、写入或可删除），关掉的工具不出现在工具列表里，经服务器或命令行调用都会被拒绝；选择保存在 `~/Library/Application Support/AppleNotesMCP/tools.json`，更新后保留，正在运行的助手会立即收到通知。MCP 工具本身与 0.1.0 相同，已授予的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见 [README（中文）](https://github.com/xiaofeng-han/apple-notes-mcp/blob/v0.2.0/README.zh-CN.md)。
