"""Golden outputs: everything a user or an agent sees that does not depend on the Mac it runs on.

While the two apps move onto a shared base (docs/MERGE-PLAN.md), none of this may change: an agent
whose config or skill reads differently is told to set itself up again. This records, for one app's
executable:

    version.txt                 --version
    help.txt, help/NOUN.txt     the command tree, whole and per noun
    commands/NOUN-VERB.txt      each command's --help
    call.txt, tools/TOOL.txt    `call` (the tool list) and each tool's `call TOOL --help`
    skill.md                    `skill`
    mcp/*.json                  initialize and tools/list (session protocol), server/discover and
                                tools/list (stateless protocol)
    agents/*                    `agents list` (the rows of the agents below), what `agents set-up`
                                prints and writes for fake Codex CLI, Grok Build and Antigravity CLI
                                commands, and the skill `agents set-up codex --skill` writes

Everything runs with a throwaway HOME, a fixed time zone and locale, and a tools.json that does not
exist (so every tool is offered); the executable's path and the throwaway HOME are written as
<EXECUTABLE> and <HOME>. Nothing needs the app's permissions, so a bare build works (swift build).
Left out because they differ from Mac to Mac: --self-check, and agents that are apps or that may be
installed for real.

    /usr/bin/python3 -I scripts/golden.py record notes|reminders EXECUTABLE DIR
    /usr/bin/python3 -I scripts/golden.py check  notes|reminders EXECUTABLE DIR

`check` records into a temporary folder and compares it with DIR, printing every difference (exit
status 1). When DIR does not exist yet, it prints the recording as a base64 .tar.gz between
"BEGIN GOLDEN" and "END GOLDEN" lines instead, to be committed as DIR (exit status 0).
"""
import base64, difflib, io, json, os, re, shutil, stat, subprocess, sys, tarfile, tempfile

PREFIX = {"notes": "APPLE_NOTES_MCP", "reminders": "APPLE_REMINDERS_MCP"}
FAKE_AGENTS = {  # path under HOME → what it prints for any arguments (Grok is identified by --help)
    ".local/bin/codex": "codex-cli 0.50.0",
    ".local/bin/grok": "Grok Build 1.0.0",
    ".local/bin/agy": "agy 1.0.0",
}
AGENT_FILES = [".codex/config.toml", ".grok/config.toml", ".gemini/config/mcp_config.json"]


def record(app, executable, out):
    executable = os.path.abspath(executable)
    home = tempfile.mkdtemp(prefix="golden-home-")
    try:
        _record(app, executable, out, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _record(app, executable, out, home):
    for path, text in FAKE_AGENTS.items():
        full = os.path.join(home, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(f"#!/bin/sh\necho '{text}'\n")
        os.chmod(full, os.stat(full).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    env = {
        "HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh", "TERM": "dumb",
        "USER": os.environ.get("USER", "runner"), "TZ": "UTC", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        PREFIX[app] + "_TOOLS_FILE": os.path.join(home, "no-tools.json"),
    }
    names = {executable: "<EXECUTABLE>", os.path.realpath(executable): "<EXECUTABLE>", home: "<HOME>", os.path.realpath(home): "<HOME>"}

    def clean(text):
        for real, placeholder in sorted(names.items(), key=lambda item: -len(item[0])):
            text = text.replace(real, placeholder)
        return text

    def run(*args, stdin=None):
        result = subprocess.run([executable, *args], env=env, input=stdin, capture_output=True, text=True, timeout=120)
        text = result.stdout
        if result.stderr:
            text += "--- stderr ---\n" + result.stderr
        if result.returncode != 0:
            text += f"--- exit status {result.returncode} ---\n"
        return clean(text)

    def save(name, text):
        path = os.path.join(out, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    save("version.txt", run("--version"))
    tree = run("help")
    save("help.txt", tree)

    # The command tree: "├── notes" opens a noun, "│   ├── search QUERY …" is one of its verbs.
    commands, noun = [], None
    for line in tree.splitlines():
        top = re.match(r"^[├└]── (\S+)$", line)
        if top:
            noun = top.group(1)
            continue
        if re.match(r"^[├└]── ", line):
            noun = None
            continue
        verb = re.match(r"^(?:│   |    )[├└]── (\S+)", line)
        if verb and noun and noun != "agents":
            commands.append((noun, verb.group(1)))
    if not commands:
        raise SystemExit(f"golden.py: found no commands in the help tree:\n{tree}")
    for noun in dict.fromkeys(n for n, _ in commands):
        save(f"help/{noun}.txt", run("help", noun))
    for noun, verb in commands:
        save(f"commands/{noun}-{verb}.txt", run(noun, verb, "--help"))

    save("call.txt", run("call"))
    save("skill.md", run("skill"))

    def serve(messages):
        text = run("--stdio", stdin="".join(json.dumps(m) + "\n" for m in messages))
        replies = []
        for line in text.splitlines():
            if line.startswith("{"):
                replies.append(json.loads(line))
            elif line.strip():
                raise SystemExit(f"golden.py: the server printed something that is not JSON-RPC:\n{text}")
        return replies

    def pretty(message):
        return json.dumps(message, indent=2, ensure_ascii=False) + "\n"

    session = serve([
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "golden", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ])
    meta = {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}
    stateless = serve([
        {"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": meta},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": meta},
    ])
    replies = {r["id"]: r for r in session}, {r["id"]: r for r in stateless}
    for name, (protocol, id) in {"initialize": (0, 1), "tools-list": (0, 2), "stateless-discover": (1, 1), "stateless-tools-list": (1, 2)}.items():
        if id not in replies[protocol]:
            raise SystemExit(f"golden.py: no reply to {name}")
        save(f"mcp/{name}.json", pretty(replies[protocol][id]))

    tools = [tool["name"] for tool in replies[0][2]["result"]["tools"]]
    for tool in tools:
        save(f"tools/{tool}.txt", run("call", tool, "--help"))

    fakes = {"codex", "grok", "agy"}
    listing = run("agents", "list")
    ids = {"claude-code", "claude", "codex", "chatgpt", "grok", "grok-bot", "opencode", "opencode-desktop", "gemini",
           "gemini-app", "antigravity", "agy"}
    kept = [line for line in listing.splitlines() if not line.split() or line.split()[0] not in ids or line.split()[0] in fakes]
    save("agents/list.txt", "\n".join(kept) + "\n")
    save("agents/set-up.txt", run("agents", "set-up", "codex", "grok", "agy"))
    save("agents/set-up-again.txt", run("agents", "set-up", "codex", "grok", "agy"))
    save("agents/set-up-skill.txt", run("agents", "set-up", "codex", "--skill"))
    for path in AGENT_FILES + [f".agents/skills/{name}/SKILL.md" for name in ("apple-notes", "apple-reminders")]:
        full = os.path.join(home, path)
        if os.path.exists(full):
            with open(full) as f:
                save("agents/files/" + path.lstrip(".").replace("/", "_"), clean(f.read()))
    # Backups of config files (none are expected: the files were new), with the date taken out.
    leftovers = sorted(re.sub(r"\d{8}", "<DATE>", name) for name in os.listdir(os.path.join(home, ".codex")) if name != "config.toml")
    save("agents/codex-folder.txt", "\n".join(leftovers) + "\n")


def files(root):
    return sorted(os.path.relpath(os.path.join(folder, name), root) for folder, _, names in os.walk(root) for name in names)


def check(app, executable, golden):
    fresh = tempfile.mkdtemp(prefix="golden-")
    try:
        record(app, executable, fresh)
        if not os.path.isdir(golden):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                for name in files(fresh):
                    archive.add(os.path.join(fresh, name), arcname=name)
            encoded = base64.b64encode(buffer.getvalue()).decode()
            print(f"::warning::{golden} does not exist yet; the recording is printed below, to be committed there.")
            print(f"BEGIN GOLDEN {app} ({len(files(fresh))} files)")
            for start in range(0, len(encoded), 100):
                print(encoded[start:start + 100])
            print(f"END GOLDEN {app}")
            return 0
        differences = 0
        for name in sorted(set(files(fresh)) | set(files(golden))):
            old, new = os.path.join(golden, name), os.path.join(fresh, name)
            if not os.path.exists(old) or not os.path.exists(new):
                print(f"{'only now' if os.path.exists(new) else 'missing now'}: {name}")
                differences += 1
                continue
            with open(old) as f:
                before = f.read().splitlines(keepends=True)
            with open(new) as f:
                after = f.read().splitlines(keepends=True)
            if before != after:
                sys.stdout.writelines(difflib.unified_diff(before, after, "golden/" + name, "now/" + name))
                differences += 1
        print(f"{app}: {len(files(fresh))} outputs, {differences} differ from {golden}")
        return 1 if differences else 0
    finally:
        shutil.rmtree(fresh, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 5 or sys.argv[1] not in ("record", "check") or sys.argv[2] not in PREFIX:
        raise SystemExit(__doc__)
    _, action, app, executable, folder = sys.argv
    if action == "record":
        if os.path.exists(folder):
            shutil.rmtree(folder)
        record(app, executable, folder)
        print(f"{app}: {len(files(folder))} outputs recorded in {folder}")
    else:
        sys.exit(check(app, executable, folder))
