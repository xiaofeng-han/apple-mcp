# Apple Reminders MCP changelog

Each `## <version>` section is that version's release note, exactly as `scripts/release.sh reminders <version>` publishes it: the English part, a line `---`, then the Chinese part. The script puts the requirements and the install commands for that version between the two, so they are not written here. Write the section before running the script; it stops if there is none.

From 0.4.0 on, Apple Reminders MCP is released with tags `reminders-v<version>`. Earlier releases, up to 0.3.0, are tagged `v<version>` on this repository's [Releases](https://github.com/xiaofeng-han/apple-mcp/releases); the note of 0.3.0 is kept below.

## 0.3.0

**What's new**

- **A command line for every tool.** Each MCP tool is now a noun-verb command (`reminders find`, `lists create`, `tags rename`, …), with flags taken from the tool's input fields, so the command line and the server accept the same things. `apple-reminders-mcp help` prints the whole tree, and `call TOOL JSON` runs any tool. Commands print the tool's answer and exit 1 when it failed, 2 for a wrong command or flag.
- **Set agents up with a skill instead of the server.** `apple-reminders-mcp skill` prints a SKILL.md that teaches an agent the command line. The **AI Assistants** tab can now set each agent up as **MCP Server** or **Skill**, for every project or for one project folder, and `agents list/set-up/install` take `--skill` and `--folder DIR`. The agent reads the skill only when reminders come up, so no tool list sits in its context. Inside a sandbox (Codex runs commands in one) macOS hides the Reminders permission; the command now says so and asks to be run outside the sandbox.
- **Choose which tools AI assistants see.** A new **Tools** tab lists the 16 tools, each labeled Read-only, Writes or Can delete. Untick a tool and assistants no longer see it: calling it anyway, through the server or its command, is refused with a message saying where to turn it back on. All, None, Invert and Read-Only change them all at once. The choice is kept in `~/Library/Application Support/AppleRemindersMCP/tools.json`, so updates and reinstalls keep it, and running assistants are told of a change at once.

The MCP tools themselves are unchanged from 0.2.4. A Reminders permission granted to 0.2.4 still applies after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：每个工具都有了对应的命令行命令（`reminders find`、`lists create`、`tags rename` 等），参数来自工具的输入字段，`help` 列出全部命令，`call` 可直接调用任意工具。新增「技能」配置方式：`skill` 输出教 agent 用命令行的 SKILL.md，「AI 助手」标签页可选「MCP 服务器」或「技能」，全局或指定项目文件夹，`agents` 命令加了 `--skill` 和 `--folder`；在沙盒里 macOS 会藏起提醒事项权限，命令会提示到沙盒外重跑。新增「工具」标签页：勾选开放给 AI 助手的工具（16 个，标明只读、写入或可删除），关掉的工具不出现在工具列表里，经服务器或命令行调用都会被拒绝；选择保存在 `~/Library/Application Support/AppleRemindersMCP/tools.json`，更新后保留，正在运行的助手会立即收到通知。MCP 工具本身与 0.2.4 相同，升级后已有的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见 [README（中文）](https://github.com/xiaofeng-han/apple-reminders-mcp/blob/v0.3.0/README.zh-CN.md)。
