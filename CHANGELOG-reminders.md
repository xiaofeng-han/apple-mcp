# Apple Reminders MCP changelog

Each `## <version>` section is that version's release note, exactly as `scripts/release.sh reminders <version>` publishes it: the English part, a line `---`, then the Chinese part. The script puts the requirements and the install commands for that version between the two, so they are not written here. Write the section before running the script; it stops if there is none.

From 0.4.0 on, Apple Reminders MCP is released with tags `reminders-v<version>`. Earlier releases, up to 0.3.0, are tagged `v<version>` on this repository's [Releases](https://github.com/xiaofeng-han/apple-mcp/releases); the note of 0.3.0 is kept below.

## 0.4.1

**What's new**

- **Homebrew no longer asks for an administrator password.** The cask now installs the app from a zip on the release instead of from the installer package, which Homebrew can only run with `sudo`. From now on `brew install`, `brew upgrade` and `brew uninstall` need no password. The app, its place in `/Applications`, its signature and its permissions stay the same. Upgrading from 0.4.0 or earlier asks for the password one last time, to remove the copy the package installed. The package is still on the release, for installing without Homebrew.

The app works as 0.4.0 did: the MCP tools, the commands and the skill are unchanged, so agents set up for it stay set up. A Reminders permission granted to 0.4.0 still applies after upgrading.

---

**更新**：Homebrew 不再要管理员密码。cask 改为从 release 上的 zip 安装 App，不再用安装包（Homebrew 装安装包只能用 `sudo`），以后 `brew install`、`brew upgrade`、`brew uninstall` 都不用输密码。App、它在 `/Applications` 的位置、签名和权限都不变。从 0.4.0 或更早的版本升级时还会最后要一次密码，用来删掉安装包装的那一份。不用 Homebrew 的话，release 上仍有安装包。App 用起来和 0.4.0 一样：MCP 工具、命令和技能都没变，已配置的 agent 不用重新配置，升级后已有的权限仍然有效。需要 macOS 26 或更新、Apple 芯片。详见[文档（中文）](https://github.com/xiaofeng-han/apple-mcp/blob/reminders-v0.4.1/docs/reminders.zh-CN.md)。

## 0.4.0

**What's new**

- **A new home.** This repository is now [apple-mcp](https://github.com/xiaofeng-han/apple-mcp) (old links redirect), where Apple Reminders MCP is developed and released together with Apple Notes MCP, on one shared base: the server, the command line, the settings window and setting up agents are written once for both. The app itself stays as it was: the same command, cask, server name, tools, permissions and settings, and agents set up for 0.3.0 stay set up. Releases are now tagged `reminders-v<version>`; `brew upgrade` follows by itself.
- **Setting up and installing agents** no longer risks waiting forever on a program that has already finished, which could happen when several ran at once.

The MCP tools and commands are unchanged from 0.3.0. A Reminders permission granted to 0.3.0 still applies after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：本仓库改名为 [apple-mcp](https://github.com/xiaofeng-han/apple-mcp)（旧链接会自动跳转），Apple Reminders MCP 和 Apple Notes MCP 在这里一起开发和发布，共用一套底座（服务器、命令行、设置窗口和 agent 配置只写一份）。App 本身不变：命令、cask、服务器名、工具、权限和设置都和以前一样，为 0.3.0 配置好的 agent 不用重新配置。发版的 tag 改为 `reminders-v<版本>`，`brew upgrade` 会自动跟上。配置和安装 agent 时，不会再因为同时跑了几个程序而一直等一个早已结束的程序。MCP 工具和命令与 0.3.0 相同，升级后已有的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见[文档（中文）](https://github.com/xiaofeng-han/apple-mcp/blob/reminders-v0.4.0/docs/reminders.zh-CN.md)。

## 0.3.0

**What's new**

- **A command line for every tool.** Each MCP tool is now a noun-verb command (`reminders find`, `lists create`, `tags rename`, …), with flags taken from the tool's input fields, so the command line and the server accept the same things. `apple-reminders-mcp help` prints the whole tree, and `call TOOL JSON` runs any tool. Commands print the tool's answer and exit 1 when it failed, 2 for a wrong command or flag.
- **Set agents up with a skill instead of the server.** `apple-reminders-mcp skill` prints a SKILL.md that teaches an agent the command line. The **AI Assistants** tab can now set each agent up as **MCP Server** or **Skill**, for every project or for one project folder, and `agents list/set-up/install` take `--skill` and `--folder DIR`. The agent reads the skill only when reminders come up, so no tool list sits in its context. Inside a sandbox (Codex runs commands in one) macOS hides the Reminders permission; the command now says so and asks to be run outside the sandbox.
- **Choose which tools AI assistants see.** A new **Tools** tab lists the 16 tools, each labeled Read-only, Writes or Can delete. Untick a tool and assistants no longer see it: calling it anyway, through the server or its command, is refused with a message saying where to turn it back on. All, None, Invert and Read-Only change them all at once. The choice is kept in `~/Library/Application Support/AppleRemindersMCP/tools.json`, so updates and reinstalls keep it, and running assistants are told of a change at once.

The MCP tools themselves are unchanged from 0.2.4. A Reminders permission granted to 0.2.4 still applies after upgrading. Assistants started before the upgrade keep running the old server, so restart them once.

---

**更新**：每个工具都有了对应的命令行命令（`reminders find`、`lists create`、`tags rename` 等），参数来自工具的输入字段，`help` 列出全部命令，`call` 可直接调用任意工具。新增「技能」配置方式：`skill` 输出教 agent 用命令行的 SKILL.md，「AI 助手」标签页可选「MCP 服务器」或「技能」，全局或指定项目文件夹，`agents` 命令加了 `--skill` 和 `--folder`；在沙盒里 macOS 会藏起提醒事项权限，命令会提示到沙盒外重跑。新增「工具」标签页：勾选开放给 AI 助手的工具（16 个，标明只读、写入或可删除），关掉的工具不出现在工具列表里，经服务器或命令行调用都会被拒绝；选择保存在 `~/Library/Application Support/AppleRemindersMCP/tools.json`，更新后保留，正在运行的助手会立即收到通知。MCP 工具本身与 0.2.4 相同，升级后已有的权限仍然有效；升级前启动的助手要重启一次。需要 macOS 26 或更新、Apple 芯片。详见 [README（中文）](https://github.com/xiaofeng-han/apple-reminders-mcp/blob/v0.3.0/README.zh-CN.md)。
