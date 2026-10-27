"""What the end-to-end checks of both apps share (scripts/e2e/notes.py, scripts/e2e/reminders.py):
the app to check and its server over stdio, the command line, check() and the summary, and the
checks of the shared base, which each app passes alike: choosing the tools through tools.json, and
a stateless (2026-07-28) client.

An app's script calls start() first, then initialize(), choosing_tools() and stateless(), then
its own checks, and finish() last.
"""
import json, os, re, select, subprocess, sys, tempfile, time

APP = None  # the executable checked
env = None  # its environment: the write guard on, and a throwaway tools.json
TOOLS_FILE = None
proc = None  # its server over stdio
seq = 0
notices = []  # notifications from the server, in order
fails = []
passed = 0
CLIENT = {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}


def start(app, prefix, guard):
    """Starts the server of the executable given on the command line, else of the app (AppleNotesMCP,
    say) installed in /Applications or ~/Applications, with <prefix>_WRITE_GUARD set to `guard` and
    <prefix>_TOOLS_FILE to a throwaway file. Returns the executable, its environment and that file."""
    global APP, env, TOOLS_FILE, proc
    installed = [os.path.expanduser(f"{folder}/{app}.app/Contents/MacOS/{app}") for folder in ("/Applications", "~/Applications")]
    APP = sys.argv[1] if len(sys.argv) > 1 else next((p for p in installed if os.path.exists(p)), installed[0])
    TOOLS_FILE = os.path.join(tempfile.mkdtemp(), "tools.json")
    env = dict(os.environ, **{prefix + "_WRITE_GUARD": guard, prefix + "_TOOLS_FILE": TOOLS_FILE})
    proc = subprocess.Popen([APP, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    return APP, env, TOOLS_FILE


def stop():
    """Ends the server; what it wrote on stderr."""
    proc.stdin.close()
    proc.wait(timeout=10)
    return proc.stderr.read().strip()


def rpc(method, params=None):
    global seq
    seq += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    while True:
        message = json.loads(proc.stdout.readline())
        if "id" in message:
            return message
        notices.append(message["method"])


def notify(method):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
    proc.stdin.flush()


def call(tool, **args):
    """("RPCERR", the error) for a call the server refused, else ("OK" or "ERR", the answer's text)."""
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if "error" in r:
        return ("RPCERR", r["error"]["message"])
    res = r["result"]
    return ("ERR" if res["isError"] else "OK", res["content"][0]["text"])


def cli(*args, stdin=None):
    """Runs the command line in the same environment: its exit status, stdout and stderr."""
    r = subprocess.run([APP, *args], input=stdin, capture_output=True, text=True, env=env, timeout=120)
    return r.returncode, r.stdout, r.stderr


def check(label, cond, detail=""):
    global passed
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    if cond:
        passed += 1
    else:
        fails.append(label)


def finish():
    print(f"\n{passed} passed, {len(fails)} failed" + (": " + ", ".join(fails) if fails else ""))
    sys.exit(1 if fails else 0)


def stop_unless(ok, label, detail, app_id, app):
    """The checks after this one read and write the app's data: without its permissions (a bare
    build has only those of the app that started it, usually the terminal), stop here rather than
    fail at every step."""
    if ok:
        return
    check(label, False, detail)
    print(f"Run the checks with the app bundle, which holds its own permissions: scripts/build-app.sh {app_id}, then")
    print(f"    /usr/bin/python3 -I scripts/e2e.py {app_id} dist/{app}.app/Contents/MacOS/{app}")
    finish()


def listed():
    return [t["name"] for t in rpc("tools/list")["result"]["tools"]]


def initialize(server, count):
    """Initializes the session and checks the server's name and its tools, which it returns."""
    init = rpc("initialize", CLIENT)
    check("initialize", init["result"]["serverInfo"]["name"] == server, init)
    notify("notifications/initialized")
    check("tools can change", init["result"]["capabilities"]["tools"]["listChanged"] is True, init)
    tools = listed()
    check(f"{count} tools", len(tools) == count, tools)
    check("tools listed by name", tools == sorted(tools), tools)
    return tools


def changed_since(mark):
    time.sleep(0.5)
    rpc("ping")
    new = notices[mark:]
    return len(new) > 0 and all(n == "notifications/tools/list_changed" for n in new)


def choosing_tools(tools, reading, off, runs, writes):
    """Choosing the tools, as the settings window's Tools tab does: saved atomically, then edited in
    place, then broken, then removed. Each change is announced and applies to the next call.
    `reading` are the read-only tools. `off`, `runs` and `writes` are calls, (tool, arguments): of
    the tool turned off first, of a reading tool, and of a tool that writes."""
    with open(TOOLS_FILE + ".new", "w") as f:
        json.dump({"tools": {name: name != off[0] for name in tools}}, f)
    mark = len(notices)
    os.replace(TOOLS_FILE + ".new", TOOLS_FILE)
    check("atomic save announced", changed_since(mark), notices)
    check("turned-off tool not listed", listed() == [n for n in tools if n != off[0]])
    st, t = call(off[0], **off[1]); check("turned-off tool refused", st == "RPCERR" and "turned off" in t and "Tools tab" in t, t)
    st, t = call(runs[0], **runs[1]); check("other tools still run", st == "OK", t[:200])
    r = rpc("initialize", CLIENT)
    check("instructions say tools may be turned off", "A tool named here that is not in your tool list is turned off there." in r["result"]["instructions"], r)
    mark = len(notices)
    with open(TOOLS_FILE, "w") as f:
        json.dump({"tools": {name: name in reading for name in tools}}, f)
    check("edit in place announced", changed_since(mark), notices)
    check("read-only choice lists the reading tools", listed() == reading)
    st, t = call(writes[0], **writes[1]); check("writing refused when read-only", st == "RPCERR" and "turned off" in t, t)
    mark = len(notices)
    time.sleep(0.5)
    rpc("ping")
    check("no announcement without a change", len(notices) == mark, notices)
    selfcheck = subprocess.run([APP, "--self-check"], env=env, capture_output=True, text=True).stdout
    first_off = next(name for name in tools if name not in reading)
    check("self-check counts the tools", f"Tools offered to AI assistants: {len(reading)} of {len(tools)} (turned off: {first_off}," in selfcheck, selfcheck)
    mark = len(notices)
    with open(TOOLS_FILE, "w") as f:
        f.write("{not json")
    check("broken file announced", changed_since(mark), notices)
    check("broken file offers nothing", listed() == [])
    st, t = call(runs[0], **runs[1]); check("broken file refuses every tool", st == "RPCERR" and "can't be read" in t, t)
    mark = len(notices)
    os.remove(TOOLS_FILE)
    check("removed file announced", changed_since(mark), notices)
    check("no file offers every tool", listed() == tools)


def stateless(tools, off):
    """A stateless (2026-07-28) client, as Claude Code and Grok Build are, is told on the
    subscriptions/listen stream it opens; `off` is a tool to turn off."""
    modern = subprocess.Popen([APP, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientInfo": {"name": "e2e", "version": "1"},
            "io.modelcontextprotocol/clientCapabilities": {}}

    def send(message):
        modern.stdin.write(json.dumps(message) + "\n")
        modern.stdin.flush()

    def receive(wait=5):
        if not select.select([modern.stdout], [], [], wait)[0]:
            return None
        return json.loads(modern.stdout.readline())

    send({"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {"_meta": meta}}); m = receive()
    check("stateless: discover offers tool changes", m and m["result"]["capabilities"]["tools"].get("listChanged") is True, m)
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {"_meta": meta}}); m = receive()
    check("stateless: list has caching hints", m and m["result"].get("ttlMs") == 0 and m["result"].get("cacheScope") == "private" and len(m["result"]["tools"]) == len(tools), m)
    send({"jsonrpc": "2.0", "id": 3, "method": "subscriptions/listen", "params": {"_meta": meta, "notifications": {"toolsListChanged": True}}}); m = receive()
    check("stateless: listen acknowledged", m and m.get("method") == "notifications/subscriptions/acknowledged"
          and m["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 3 and m["params"]["notifications"] == {"toolsListChanged": True}, m)
    with open(TOOLS_FILE + ".new", "w") as f:
        json.dump({"tools": {name: name != off for name in tools}}, f)
    os.replace(TOOLS_FILE + ".new", TOOLS_FILE)
    m = receive()
    check("stateless: change sent on the stream", m and m.get("method") == "notifications/tools/list_changed"
          and m["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 3, m)
    send({"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {"_meta": meta}}); m = receive()
    check("stateless: list follows the change", m and len(m["result"]["tools"]) == len(tools) - 1, m)
    # Requests are handled in order, so the ping's reply shows the cancel has been handled.
    send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 3}})
    send({"jsonrpc": "2.0", "id": 5, "method": "ping", "params": {"_meta": meta}}); m = receive()
    check("stateless: cancel handled", m and m.get("id") == 5, m)
    os.remove(TOOLS_FILE)
    time.sleep(0.5)
    send({"jsonrpc": "2.0", "id": 6, "method": "ping", "params": {"_meta": meta}}); m = receive()
    check("stateless: nothing after cancelling", m and m.get("id") == 6, m)
    modern.stdin.close()
    modern.wait(timeout=10)


def names_this_copy(skill):
    """The skill's command is this copy of the app: its executable, or, installed with Homebrew,
    the cask's wrapper in …/bin, which execs it."""
    m = re.search(r'^  command: (".*")$', skill, re.M)
    if not m:
        return False
    command, app = json.loads(m.group(1)), os.path.realpath(APP)
    if command == app:
        return True
    try:
        with open(command) as f:
            return os.path.basename(os.path.dirname(command)) == "bin" and app in f.read()
    except OSError:
        return False


def skill_names_this_copy(name):
    code, out, err = cli("skill")
    check("cli: skill names this copy's command", code == 0 and out.startswith(f"---\nname: {name}\n") and names_this_copy(out), out[:400])
