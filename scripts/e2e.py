"""End-to-end check of the MCP server over stdio, against the real Notes data.

Writes are confined by the write guard to notes titled, and folders named, "agent test…". The
script first removes what an interrupted run left behind and at the end deletes the folder it
made, so only Recently Deleted keeps its notes. Usage:

    /usr/bin/python3 -I scripts/e2e.py [path to the AppleNotesMCP executable]

The app needs Full Disk Access and Automation → Notes (run it with `setup` once).
"""
import json, os, re, subprocess, sys, tempfile, zipfile

INSTALLED = [os.path.expanduser(p + "/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP") for p in ("/Applications", "~/Applications")]
APP = sys.argv[1] if len(sys.argv) > 1 else next((p for p in INSTALLED if os.path.exists(p)), INSTALLED[0])
GUARD = "agent test"
env = dict(os.environ, APPLE_NOTES_MCP_WRITE_GUARD=GUARD)
proc = subprocess.Popen([APP, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
seq = 0


def rpc(method, params=None):
    global seq
    seq += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


def call(tool, **args):
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if "error" in r:
        return ("RPCERR", r["error"]["message"], [])
    res = r["result"]
    return ("ERR" if res["isError"] else "OK", res["content"][0]["text"], res["content"][1:])


fails = []


def check(label, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    if not cond:
        fails.append(label)


def field(text, name):
    m = re.search(name + r": ([0-9A-Fa-f]+)", text)
    return m.group(1) if m else None


def body(text):
    return text.split("\n---\n", 1)[1]


def notes_in(folder):
    st, t, _ = call("overview", folder=folder, limit=500)
    return [line.split(" | ")[0] for line in t.splitlines() if re.match(r"^[0-9A-F]{8} \| ", line)] if st == "OK" else []


init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
check("initialize", init["result"]["serverInfo"]["name"] == "apple-notes-mcp", init)
tools = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
check("10 tools", len(tools) == 10, tools)

# Leftovers of an interrupted run.
st, t, _ = call("overview", depth=3)
if re.search(r"^agent test \(", t, re.M):
    ids = notes_in("agent test")
    print("cleanup:", call("manage_folder", action="delete", folder="agent test", recursive=True, expected_notes=len(ids))[:2])
st, t, _ = call("overview")
check("overview", st == "OK" and "notes in" in t, t[:200])
baseline = int(re.match(r"(\d+) notes", t).group(1))

# Folders.
check("guard blocks other folder", call("manage_folder", action="create", folder="Not allowed")[0] == "ERR")
st, t, _ = call("manage_folder", action="create", folder="agent test"); check("create folder", st == "OK", t)
st, t, _ = call("manage_folder", action="create", folder="agent test"); check("no duplicate folder", st == "ERR" and "already" in t, t)
st, t, _ = call("manage_folder", action="create", folder="agent test/agent test sub"); check("create subfolder", st == "OK", t)
st, t, _ = call("manage_folder", action="rename", folder="agent test/agent test sub", name="agent test sub2"); check("rename folder", st == "OK", t)
st, t, _ = call("manage_folder", action="rename", folder="agent test/agent test sub2", name="Not allowed"); check("guard blocks rename", st == "ERR", t)

# Creating a note with every style.
rich = """# agent test rich 文本
## Section A
Plain **bold** *italic* ~~strike~~ <u>under</u> <mark>hi</mark> [link](https://example.com/a_(b)) and ***both***
- [ ] todo one
- [x] todo done
* bullet
- dash
1. one
2. two
  1. nested
> quoted
```
let x = 1 // code
```
| H1 | H2 |
| --- | --- |
| a | b<br>c |
## Section B
end with 中文 and emoji 😀"""
check("guard blocks other titles", call("create_note", markdown="# Not allowed", folder="agent test")[0] == "ERR")
st, t, _ = call("create_note", markdown=rich, folder="agent test"); check("create rich note", st == "OK" and "Created" in t, t)
print("   ", t)
N = field(t, "id")
st, t, _ = call("read_note", id=N); check("rich note reads back exactly", st == "OK" and body(t) == rich, t)
v = field(t, "version")

# Edits in place.
st, t, _ = call("edit_note", id=N, replace=[{"old": "- [ ] todo one", "new": "- [x] todo one"}]); check("tick a checkbox", st == "OK", t)
st, t, _ = call("edit_note", id=N, insert="- [ ] todo three", at="Section A"); check("insert under heading", st == "OK", t)
st, t, _ = call("read_note", id=N)
check("checkbox ticked and item joins the list", "- [x] todo one\n- [x] todo done\n- [ ] todo three\n* bullet" in body(t), body(t))
st, t, _ = call("edit_note", id=N, insert="intro line", at="start"); check("insert at start", st == "OK", t)
st, t, _ = call("read_note", id=N); check("start is below the title", body(t).startswith("# agent test rich 文本\nintro line\n## Section A"), body(t)[:80])
st, t, _ = call("edit_note", id=N, replace=[{"old": "| a | b<br>c |", "new": "| a2 | b<br>c |\n| new | row |"}]); check("edit table in place", st == "OK", t)
st, t, _ = call("read_note", id=N); check("table changed", "| a2 | b<br>c |\n| new | row |" in body(t), body(t))
st, t, _ = call("edit_note", id=N, replace=[{"old": "Plain **bold**", "new": "Plain **bold** and new"}, {"old": "end with", "new": "ends with"}])
check("two replacements in one call", st == "OK", t)
st, t, _ = call("read_note", id=N); check("both applied", "Plain **bold** and new *italic*" in body(t) and "ends with 中文" in body(t), body(t))
st, t, _ = call("edit_note", id=N, replace=[{"old": "no such text", "new": "x"}]); check("missing text refused", st == "ERR" and "Not found" in t, t)
st, t, _ = call("edit_note", id=N, replace=[{"old": "todo", "new": "task"}]); check("ambiguous text refused", st == "ERR" and "appears" in t, t)
st, t, _ = call("edit_note", id=N, rewrite="# agent test x", version="000000000000"); check("stale version refused", st == "ERR" and "changed after" in t, t)
st, t, _ = call("read_note", id=N, outline=True); check("outline", st == "OK" and "## Section A" in t and "## Section B" in t, t)
st, t, _ = call("read_note", id=N, section="Section B"); check("section", st == "OK" and body(t).startswith("## Section B\nends with"), t)
st, t, _ = call("read_note", title="agent test rich 文本"); check("read by title", st == "OK" and field(t, "id") == N, t[:100])
v = field(t, "version")
rewrite = """# agent test rich 文本
Short now.
| Fruit | Qty |
| --- | --- |
| apple | 3 |
- [ ] one left"""
st, t, _ = call("edit_note", id=N, rewrite=rewrite, version=v); check("rewrite", st == "OK", t)
st, t, _ = call("read_note", id=N); check("rewrite reads back", body(t).startswith(rewrite), body(t))

# A second note: search, describe, move, delete, restore.
st, t, _ = call("create_note", markdown="# agent test zebra quokka\nsecond note body", folder="agent test/agent test sub2")
check("create in subfolder", st == "OK", t)
M = field(t, "id")
st, t, _ = call("search", query="zebra quokka"); check("search", st == "OK" and M in t, t)
st, t, _ = call("search", query="zebra nothingmatches"); check("search all words", st == "OK" and "No notes match" in t, t)
st, t, _ = call("search", query="zebra nothingmatches", match="any"); check("search any word", st == "OK" and M in t, t)
st, t, _ = call("describe_note", descriptions=[{"id": M, "description": "A test note about zebras"}]); check("describe", st == "OK", t)
st, t, _ = call("overview", folder="agent test"); check("overview lists notes and description", st == "OK" and "A test note about zebras" in t and N in t, t)
st, t, _ = call("move_note", id=M, folder="agent test"); check("move note", st == "OK" and "Moved" in t, t)
st, t, _ = call("delete_note", id=M); check("delete note", st == "OK", t)
st, t, _ = call("read_note", id=M); check("deleted note is in Recently Deleted", st == "OK" and "Recently Deleted" in t, t[:200])
st, t, _ = call("delete_note", id=M); check("no second delete", st == "ERR", t)
st, t, _ = call("move_note", id=M, folder="agent test"); check("restore", st == "OK" and "Restored" in t, t)

# Attachments: a placeholder must stay, and an attachment can be read.
check("unknown attachment refused", call("edit_note", id=N, insert="![image](attachment:FFFFFFFF)")[0] == "ERR")
st, t, _ = call("overview", limit=500, sort="modified")
image = None
for nid in re.findall(r"^([0-9A-F]{8}) \| .*image", t, re.M)[:20]:
    st2, t2, _ = call("read_note", id=nid)
    m = re.search(r"!\[image\]\(attachment:([0-9A-F]{8})\)", t2)
    if m:
        image = m.group(1)
        break
if image:
    st, t, extra = call("read_attachment", id=image); check("read an image", st == "OK" and any(c["type"] == "image" for c in extra), t)
else:
    print("SKIP read an image (no image found)")

# Guard on a real note.
st, t, _ = call("overview", limit=5)
real = re.findall(r"^([0-9A-F]{8}) \| (?!agent test)", t, re.M)
if real:
    check("guard blocks real notes", call("edit_note", id=real[0], insert="x")[0] == "ERR")

# Export, then delete everything.
out = os.path.join(tempfile.mkdtemp(), "agent test export.zip")
st, t, _ = call("manage_folder", action="export", folder="agent test", to=out); check("export", st == "OK" and os.path.exists(out), t)
if os.path.exists(out):
    names = zipfile.ZipFile(out).namelist()
    check("export holds the notes and manifest", any(n.endswith("agent test rich 文本.md") for n in names) and any(n.endswith("manifest.md") for n in names), names)
st, t, _ = call("manage_folder", action="delete", folder="agent test"); check("non-empty folder refused", st == "ERR" and "not empty" in t, t)
count = len(notes_in("agent test"))
st, t, _ = call("manage_folder", action="delete", folder="agent test", recursive=True, expected_notes=count + 1); check("wrong count refused", st == "ERR", t)
st, t, _ = call("manage_folder", action="delete", folder="agent test", recursive=True, expected_notes=count); check("delete folder tree", st == "OK", t)
st, t, _ = call("overview")
check("back to the start", int(re.match(r"(\d+) notes", t).group(1)) == baseline and "agent test" not in t, t[:300])

proc.stdin.close()
proc.wait(timeout=10)

# Another server (another agent's) reads only the database, which Notes writes lazily: it must
# see the cleanup too.
import time
for attempt in range(10):
    fresh = subprocess.run([APP, "--stdio"], env=env, capture_output=True, text=True, input="\n".join(json.dumps(m) for m in [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "overview", "arguments": {}}}]) + "\n")
    t = json.loads(fresh.stdout.splitlines()[1])["result"]["content"][0]["text"]
    if int(re.match(r"(\d+) notes", t).group(1)) == baseline and "agent test" not in t:
        break
    time.sleep(2)
check("a new server sees the cleanup", int(re.match(r"(\d+) notes", t).group(1)) == baseline and "agent test" not in t, t[:200])
print(f"\n{len(fails)} failed" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
