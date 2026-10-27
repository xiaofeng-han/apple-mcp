"""End-to-end check of the MCP server over stdio, and of the command line, against the real Notes data.

Writes are confined by the write guard to notes titled, and folders named, "agent test…". The
script first removes what an interrupted run left behind and at the end deletes the folder it
made, so only Recently Deleted keeps its notes. The choice of tools is read from a throwaway
tools.json, so the user's own choice neither hides tools from the checks nor changes. Usage:

    /usr/bin/python3 -I scripts/e2e.py notes [path to the AppleNotesMCP executable]

The app needs Full Disk Access and Automation → Notes (run it with `setup` once).
"""
import json, os, re, subprocess, sys, tempfile, time, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves this folder off the path
import harness
from harness import check, cli, finish, rpc

APP, env, TOOLS_FILE = harness.start("AppleNotesMCP", "APPLE_NOTES_MCP", "agent test")
writes = []  # answers of successful writes, newest last


def call(tool, **args):
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if "error" in r:
        return ("RPCERR", r["error"]["message"], [])
    res = r["result"]
    if not res["isError"] and tool in ("create_note", "edit_note", "move_note"):
        writes.append(res["content"][0]["text"])
    return ("ERR" if res["isError"] else "OK", res["content"][0]["text"], res["content"][1:])


def _last_write():
    return writes[-1] if writes else ""


def listed_line(text, nid):
    """The line of a note in an overview or search answer: id | version | title | …"""
    return next((line for line in text.splitlines() if line.startswith(nid + " | ")), None)


def field(text, name):
    m = re.search(name + r": ([0-9A-Fa-f]+)", text)
    return m.group(1) if m else None


def body(text):
    return text.split("\n---\n", 1)[1]


def notes_in(folder):
    st, t, _ = call("overview", folder=folder, limit=500)
    return [line.split(" | ")[0] for line in t.splitlines() if re.match(r"^[0-9A-F]{8} \| ", line)] if st == "OK" else []


tools = harness.initialize("apple-notes-mcp", 11)
READING = ["overview", "read_attachment", "read_note", "search"]
harness.choosing_tools(tools, READING, off=("delete_note", {"id": "x"}), runs=("overview", {}),
                       writes=("create_note", {"markdown": "# agent test 不该写入", "folder": "agent test"}))
harness.stateless(tools, "delete_note")

# Everything below reads and writes notes: without Full Disk Access (a bare build has only what
# the app that started it has, usually the terminal), stop here rather than fail at every step.
st, t, _ = call("overview")
harness.stop_unless(st == "OK", "access to Notes", t, "notes", "AppleNotesMCP")

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

# Edits in place. Every change names the version it was made against; each write answers with the new one.
st, t, _ = call("edit_note", id=N, insert="x"); check("an edit without a version refused", st != "OK" and "version" in t, t)
st, t, _ = call("edit_note", id=N, version="000000000000", insert="x"); check("an insert on a stale version refused", st == "ERR" and "changed after" in t, t)
st, t, _ = call("edit_note", id=N, version=v, replace=[{"old": "- [ ] todo one", "new": "- [x] todo one"}]); check("tick a checkbox", st == "OK", t)
v = field(t, "version")
st, t, _ = call("edit_note", id=N, version=v, insert="- [ ] todo three", at="Section A"); check("insert under heading", st == "OK", t)
st, t, _ = call("read_note", id=N)
check("checkbox ticked and item joins the list", "- [x] todo one\n- [x] todo done\n- [ ] todo three\n* bullet" in body(t), body(t))
check("a write answers with the version read_note gives", field(t, "version") == field(_last_write(), "version"), t[:120])
v = field(t, "version")
st, t, _ = call("edit_note", id=N, version=v, insert="intro line", at="start"); check("insert at start", st == "OK", t)
v = field(t, "version")
st, t, _ = call("read_note", id=N); check("start is below the title", body(t).startswith("# agent test rich 文本\nintro line\n## Section A"), body(t)[:80])
st, t, _ = call("edit_note", id=N, version=v, replace=[{"old": "| a | b<br>c |", "new": "| a2 | b<br>c |\n| new | row |"}]); check("edit table in place", st == "OK", t)
v = field(t, "version")
st, t, _ = call("read_note", id=N); check("table changed", "| a2 | b<br>c |\n| new | row |" in body(t), body(t))
st, t, _ = call("edit_note", id=N, version=v, replace=[{"old": "Plain **bold**", "new": "Plain **bold** and new"}, {"old": "end with", "new": "ends with"}])
check("two replacements in one call", st == "OK", t)
v = field(t, "version")
st, t, _ = call("read_note", id=N); check("both applied", "Plain **bold** and new *italic*" in body(t) and "ends with 中文" in body(t), body(t))
st, t, _ = call("edit_note", id=N, version=v, replace=[{"old": "no such text", "new": "x"}]); check("missing text refused", st == "ERR" and "Not found" in t, t)
st, t, _ = call("edit_note", id=N, version=v, replace=[{"old": "todo", "new": "task"}]); check("ambiguous text refused", st == "ERR" and "appears" in t, t)
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
vm = field(t, "version")
st, t, _ = call("search", query="zebra quokka"); check("search", st == "OK" and M in t, t)
line = listed_line(t, M); check("search lines give the version", line and line.split(" | ")[1] == vm, t)
st, t, _ = call("search", query="zebra nothingmatches"); check("search all words", st == "OK" and "No notes match" in t, t)
st, t, _ = call("search", query="zebra nothingmatches", match="any"); check("search any word", st == "OK" and M in t, t)
st, t, _ = call("describe_note", descriptions=[{"id": M, "description": "A test note about zebras"}]); check("describe", st == "OK", t)
st, t, _ = call("overview", folder="agent test"); check("overview lists notes and description", st == "OK" and "A test note about zebras" in t and N in t, t)
st, t, _ = call("move_note", id=M, folder="agent test", version="000000000000"); check("a move on a stale version refused", st == "ERR" and "changed after" in t, t)
st, t, _ = call("move_note", id=M, folder="agent test", version=vm); check("move note", st == "OK" and "Moved" in t and field(t, "version") == vm, t)
st, t, _ = call("delete_note", id=M, version="000000000000"); check("a delete on a stale version refused", st == "ERR" and "changed after" in t, t)
st, t, _ = call("delete_note", id=M, version=vm); check("delete note", st == "OK", t)
st, t, _ = call("read_note", id=M); check("deleted note is in Recently Deleted", st == "OK" and "Recently Deleted" in t, t[:200])
st, t, _ = call("delete_note", id=M, version=vm); check("no second delete", st == "ERR", t)
st, t, _ = call("overview"); check("the folder list counts Recently Deleted", st == "OK" and re.search(r"^Recently Deleted \(\d+\)", t, re.M), t[-300:])
st, t, _ = call("overview", folder="Recently Deleted", limit=500)
line = listed_line(t, M)
check("Recently Deleted lists the note, its version and days left", st == "OK" and line and line.split(" | ")[1] == vm and "30 days left" in line, t[:400])
st, t, _ = call("search", query="zebra quokka", folder="Recently Deleted"); check("search in Recently Deleted", st == "OK" and M in t, t)
st, t, _ = call("search", query="zebra quokka"); check("search elsewhere leaves deleted notes out", st == "OK" and M not in t, t)
st, t, _ = call("move_note", id=M, folder="agent test", version=vm); check("restore", st == "OK" and "Restored" in t, t)
st, t, _ = call("overview", folder="Recently Deleted", limit=500); check("a restored note leaves Recently Deleted", st == "OK" and listed_line(t, M) is None, t[:300])

# Attachments: a placeholder must stay, and an attachment can be read.
check("unknown attachment refused", call("edit_note", id=N, version=v, insert="![image](attachment:FFFFFFFF)")[0] == "ERR")
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

# Search looks in the text Notes recognized in images: a word of it that the note's own text lacks.
word = None
for nid in re.findall(r"^([0-9A-F]{8}) \| .*image", call("overview", limit=500, sort="modified")[1], re.M)[:40]:
    own = body(call("read_note", id=nid)[1])
    for aid in re.findall(r"!\[image\]\(attachment:([0-9A-F]{8})\)", own):
        st, t, _ = call("read_attachment", id=aid, text_only=True)
        recognized = t.split("Text Notes recognized (may be wrong):\n", 1)[1].split("\n\n", 1)[0] if "Text Notes recognized" in t else ""
        word = next((w for w in re.findall(r"[A-Za-z]{6,}", recognized) if w.lower() not in own.lower()), None)
        if word:
            break
    if word:
        break
if word:
    st, t, _ = call("search", query=word, limit=100); check("search finds text in an image", st == "OK" and f"in the text of image {aid}" in t, (word, t[:600]))
else:
    print("SKIP search finds text in an image (no image with recognized text)")

# A recording made in Notes is read with its transcript.
recording = None
for nid in re.findall(r"^([0-9A-F]{8}) \| .*audio", call("overview", limit=500, sort="modified")[1], re.M)[:20]:
    for aid in re.findall(r"!\[audio[^\]]*\]\(attachment:([0-9A-F]{8})\)", call("read_note", id=nid)[1]):
        st, t, _ = call("read_attachment", id=aid, text_only=True)
        if "Transcript Notes made" in t:
            recording = aid
            break
    if recording:
        break
if recording:
    check("read a recording's transcript", True)
    first = re.search(r"Transcript Notes made[^\n]*:\n(?:\S+\n)?(\S+ \S+)", t)
    if first:
        st, t, _ = call("search", query=first.group(1), limit=100); check("search finds words of a transcript", st == "OK" and "in the transcript of audio" in t, t[:400])
else:
    print("SKIP read a recording's transcript (no recording with a transcript)")

# Tags, links, divider lines, highlight colors, files and link cards, written as Markdown.
attach_dir = tempfile.mkdtemp()
with open(os.path.join(attach_dir, "agent test file.txt"), "w") as f:
    f.write("attached by e2e\n")
inline = f"""# agent test inline
tagged #agenttesttag and a link to [](note:{N}) here
---
<mark class="pink">pink</mark> and <mark>purple</mark>
![e2e file]({os.path.join(attach_dir, "agent test file.txt")})
![](https://www.apple.com/notes/)"""
st, t, _ = call("create_note", markdown=inline, folder="agent test"); check("create with a tag, link, divider, file and link card", st == "OK" and "Warning" not in t, t)
I = field(t, "id")
st, t, _ = call("read_note", id=I)
b = body(t) if st == "OK" else ""
check("tag and note link read back", "tagged #agenttesttag and a link to [agent test rich 文本](note:" + N + ") here" in b, b)
check("divider and highlight colors read back", "\n---\n<mark class=\"pink\">pink</mark> and <mark>purple</mark>\n" in b, b)
check("file and link card are attachments", re.search(r"!\[file: e2e file\]\(attachment:[0-9A-F]{8}\)", b) and re.search(r"!\[link: https://www.apple.com/notes/\]\(attachment:", b), b)
vi = field(t, "version")
st, t, _ = call("read_note", id=N); check("the linked note lists its backlink", st == "OK" and f"linked from: agent test inline ({I})" in t, t[:300])
st, t, _ = call("create_note", markdown="# agent test bad file\n![](~/Library/Preferences/x.plist)", folder="agent test")
check("a file from ~/Library refused", st == "ERR" and "not in a place" in t, t)
st, t, _ = call("overview"); check("the folder list shows the tag", st == "OK" and re.search(r"Tags: .*#agenttesttag \(1\)", t), t[-300:])
st, t, _ = call("overview", tags=["agenttesttag"]); check("overview by tag", st == "OK" and I in t and N not in t, t)
st, t, _ = call("search", query="pink", tags=["#agenttesttag"]); check("search by tag", st == "OK" and I in t, t)
st, t, _ = call("manage_folder", action="create", folder="agent test smart", tags=["agenttesttag"]); check("create a smart folder", st == "OK" and "1 note now" in t, t)
st, t, _ = call("overview", folder="agent test smart"); check("list a smart folder", st == "OK" and I in t, t)
st, t, _ = call("move_note", id=I, folder="agent test smart", version=vi); check("a smart folder is no destination", st == "ERR" and "smart folder" in t, t)
st, t, _ = call("manage_tag", action="rename", tag="agenttesttag", name="agenttesttag2"); check("rename a tag", st == "OK" and "in 1 note" in t, t)
st, t, _ = call("read_note", id=I); check("the rename shows in the note", "tagged #agenttesttag2 and" in body(t), body(t)[:200])
st, t, _ = call("manage_folder", action="delete", folder="agent test smart"); check("delete a smart folder", st == "OK" and "notes stay" in t, t)
st, t, _ = call("manage_tag", action="delete", tag="agenttesttag2", expected_notes=2); check("deleting a tag needs the right count", st == "ERR", t)
st, t, _ = call("manage_tag", action="delete", tag="agenttesttag2", expected_notes=1); check("delete a tag", st == "OK" and "out of 1 note" in t, t)
st, t, _ = call("read_note", id=I); check("the tag is gone from the text", st == "OK" and "tagged and a link" in body(t), body(t)[:200])
vi = field(t, "version")

# Pinning, checklists, copies.
st, t, _ = call("edit_note", id=I, version=vi, pinned=True); check("pin", st == "OK" and t.startswith("Pinned"), t)
st, t, _ = call("read_note", id=I, outline=True); check("read shows pinned", "| pinned" in t, t[:200])
st, t, _ = call("overview", only=["pinned"]); check("overview of pinned notes", st == "OK" and I in t, t)
st, t, _ = call("edit_note", id=I, version=vi, pinned=False, insert="- [x] one\n- [ ] two\n- [x] three\n- [ ] four"); check("unpin and insert", st == "OK" and "unpinned" in t, t)
vi = field(t, "version")
st, t, _ = call("edit_note", id=I, version=vi, check=["two"], uncheck=["three"], checklist="move_checked_down"); check("tick, untick and sort", st == "OK", t)
vi = field(t, "version")
st, t, _ = call("read_note", id=I); check("checklist sorted", body(t).rstrip().endswith("- [ ] three\n- [ ] four\n- [x] one\n- [x] two"), body(t)[-120:])
st, t, _ = call("edit_note", id=I, version=vi, checklist="delete_checked"); check("delete ticked items", st == "OK", t)
vi = field(t, "version")
st, t, _ = call("read_note", id=I); check("ticked items gone", "- [x]" not in body(t) and "- [ ] four" in body(t), body(t)[-120:])
st, t, _ = call("edit_note", id=I, version=vi, check=["no such item"]); check("an unknown item refused", st == "ERR" and "checklist item" in t, t)
st, t, _ = call("overview", folder="agent test", only=["checklists", "unchecked"], attachments=["file"]); check("filters combine", st == "OK" and I in t and N not in t, t)
st, t, _ = call("overview", only=["quick-notes"], sort="opened", limit=5); check("Quick Notes, by last opened", st == "OK" and "Quick Notes" in t, t[:200])
st, t, _ = call("create_note", copy_of=I, folder="agent test/agent test sub2"); check("copy a note with its attachments", st == "OK" and "copy" in t, t)
K = field(t, "id")
st, t, _ = call("read_note", id=K or "none"); check("the copy has the file", st == "OK" and "![file: e2e file](attachment:" in body(t), t[:300])

# Several notes at once; a folder moved.
st, t, _ = call("overview", folder="agent test", limit=500)
vk = listed_line(t, K).split(" | ")[1] if K and listed_line(t, K) else "none"
vi = listed_line(t, I).split(" | ")[1] if listed_line(t, I) else "none"
st, t, _ = call("move_note", folder="agent test", notes=[{"id": K, "version": vk}, {"id": I, "version": "000000000000"}])
check("move several notes, each checked", st == "OK" and t.startswith("Moved 1 note to agent test") and "Not moved" in t and "changed after" in t, t)
st, t, _ = call("manage_folder", action="create", folder="agent test/agent test moving"); check("create a folder to move", st == "OK", t)
st, t, _ = call("manage_folder", action="move", folder="agent test/agent test moving", into="agent test/agent test sub2"); check("move a folder", st == "OK" and "agent test sub2/agent test moving" in t, t)
st, t, _ = call("overview", depth=3); check("the moved folder is in its new place", st == "OK" and "    agent test moving (0)" in t, t)
st, t, _ = call("delete_note", notes=[{"id": K, "version": vk}]); check("delete through notes", st == "OK" and "Recently Deleted" in t, t)

# Guard on a real note.
st, t, _ = call("overview", limit=5)
real = re.findall(r"^([0-9A-F]{8}) \| (?!agent test)", t, re.M)
if real:
    check("guard blocks real notes", call("edit_note", id=real[0], version="000000000000", insert="x")[0] == "ERR")

# The command line runs the same tools: apple-notes-mcp <noun> <verb> [flags]. Each command is
# its own process, so this also checks that a write is in the store when one exits.
typed = "# agent test 命令行 setup\nfrom the command line\n- [ ] first"
code, out, err = cli("notes", "create", "-", "--folder", "agent test", stdin=typed)
check("cli: notes create - reads stdin (a title may say setup)", code == 0 and "Created" in out, (code, out, err))
C = field(out, "id")
code, out, err = cli("notes", "read", C or "none"); check("cli: notes read", code == 0 and body(out) == typed + "\n", (code, out, err))
code, out, err = cli("notes", "edit", C or "none", "--insert", "- [ ] second"); check("cli: an edit needs --version", code == 2 and "--version" in err, (code, out, err))
code, out, err = cli("notes", "edit", C or "none", "--insert", "- [ ] second", "--at", "end", "--version", field(out, "version") or field(cli("notes", "read", C or "none")[1], "version") or "none")
check("cli: notes edit --insert", code == 0 and "Updated" in out, (code, out, err))
code, out, err = cli("notes", "read", C or "none"); check("cli: the edit is in the store", code == 0 and body(out).endswith("- [ ] first\n- [ ] second\n"), (code, out, err))
code, out, err = cli("notes", "search", "命令行", "--folder", "agent test"); check("cli: notes search QUERY --folder", code == 0 and C in out, (code, out, err))
# --list-json, for editor pickers: one JSON object per line, with the full id and title.
def list_json(*query):
    code, out, err = cli("--list-json", *query)
    rows = [json.loads(line) for line in out.splitlines()] if code == 0 else []
    return code, rows, next((r for r in rows if r["id"].startswith(C or "none")), None), err
code, rows, row, err = list_json()
check("cli: --list-json lists every note, newest first", code == 0 and row is not None and len(row["id"]) == 36
      and (row["title"], row["folder"], "snippet" in row) == ("agent test 命令行 setup", "agent test", False)
      and [r["modified"] for r in rows] == sorted((r["modified"] for r in rows), reverse=True), (code, row, err))
code, rows, row, err = list_json("命令行", "setup")
check("cli: --list-json QUERY lists search results with snippets", code == 0 and row is not None and row["folder"] == "agent test" and bool(row.get("snippet")), (code, rows[:3], err))
code, out, err = cli("notes", "edit", C or "none", "--rewrite", "# agent test x", "--version", "000000000000")
check("cli: a stale version exits 1", code == 1 and "changed after" in err and out == "", (code, out, err))
code, out, err = cli("notes", "create", "--json", "-", stdin=json.dumps({"markdown": "# agent test JSON 标准输入", "folder": "agent test"}))
check("cli: --json - from stdin", code == 0 and "Created" in out, (code, out, err))
J = field(out, "id")
vj = field(out, "version")
code, out, err = cli("notes", "--folder", "agent test"); check("cli: notes lists by default", code == 0 and C in out and J in out, (code, out, err))
code, out, err = cli("folders"); check("cli: folders lists by default", code == 0 and re.search(r"^agent test \(", out, re.M), (code, out, err))
code, out, err = cli("call", "overview", json.dumps({"folder": "agent test"})); check("cli: call", code == 0 and C in out, (code, out, err))
code, out, err = cli("notes", "delete", J or "none", "--version", vj or "none"); check("cli: notes delete", code == 0 and "Recently Deleted" in out, (code, out, err))
code, out, err = cli("notes", "list", "--folder", "Recently Deleted", "--limit", "500"); check("cli: notes list --folder \"Recently Deleted\"", code == 0 and J in out, (code, out, err))
code, out, err = cli("notes", "move", J or "none", "agent test", "--version", vj or "none"); check("cli: notes move restores", code == 0 and "Restored" in out, (code, out, err))
code, out, err = cli("notes", "list", "--bogus"); check("cli: an unknown flag exits 2", code == 2 and "--bogus" in err and out == "", (code, out, err))
code, out, err = cli("folders", "create", "Not allowed"); check("cli: a guarded write exits 1", code == 1 and "write guard" in err, (code, out, err))
code, out, err = cli("folders", "delete", "agent test", "--recursive")
check("cli: messages name flags", code == 2 and "--recursive needs --expected-notes" in err, (code, out, err))
if image:
    folder = tempfile.mkdtemp()
    code, out, err = cli("attachments", "read", image, "--output-dir", folder)
    saved = re.findall(r"^Saved to (.+)$", out, re.M)
    check("cli: attachments read saves the image", code == 0 and saved and all(os.path.exists(p) for p in saved), (code, out, err))
harness.skill_names_this_copy("apple-notes")
# The choice of tools holds on the command line too, which the skill uses.
with open(TOOLS_FILE + ".new", "w") as f:
    json.dump({"tools": {name: name not in ("read_note", "manage_folder") for name in tools}}, f)
os.replace(TOOLS_FILE + ".new", TOOLS_FILE)
code, out, err = cli("notes", "read", C or "none"); check("cli: a turned-off tool exits 1", code == 1 and "notes read is turned off" in err and "Tools tab" in err and out == "", (code, out, err))
code, out, err = cli("call", "read_note", json.dumps({"id": C})); check("cli: call refuses a turned-off tool", code == 1 and "turned off" in err, (code, out, err))
code, out, err = cli("notes", "search", "命令行", "--folder", "agent test"); check("cli: other tools still run", code == 0 and C in out, (code, out, err))
os.remove(TOOLS_FILE)

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

harness.stop()

# Another server (another agent's) reads only the database, which Notes writes lazily: it must
# see the cleanup too.
for attempt in range(10):
    fresh = subprocess.run([APP, "--stdio"], env=env, capture_output=True, text=True, input="\n".join(json.dumps(m) for m in [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "overview", "arguments": {}}}]) + "\n")
    t = json.loads(fresh.stdout.splitlines()[1])["result"]["content"][0]["text"]
    if int(re.match(r"(\d+) notes", t).group(1)) == baseline and "agent test" not in t:
        break
    time.sleep(2)
check("a new server sees the cleanup", int(re.match(r"(\d+) notes", t).group(1)) == baseline and "agent test" not in t, t[:200])
finish()
