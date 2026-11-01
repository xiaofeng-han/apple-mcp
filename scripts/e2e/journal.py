"""End-to-end check of the MCP server over stdio, against the real Journal store.

Writes are confined by the write guard to entries titled "agent test…" and journals named "agent
test…", all in a throwaway journal "agent test e2e"; the script removes leftovers of an interrupted
run first and deletes everything it made for good at the end (Journal uploads each change, so the
user's other devices see the entries come and go). Journal keeps a streak record for each entry
deleted for good, so its Insights count the day of a run as a day journaled. The choice of tools is read from a throwaway
tools.json, so the user's own choice neither hides tools from the checks nor changes. Usage:

    /usr/bin/python3 -I scripts/e2e.py journal [path to the AppleJournalMCP executable]

The app needs Full Disk Access (run it with `setup` once).
"""
import json, os, shutil, struct, subprocess, sys, tempfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves this folder off the path
import harness
from harness import call, check, cli, finish

APP, env, TOOLS_FILE = harness.start("AppleJournalMCP", "APPLE_JOURNAL_MCP", "agent test")
def obj(text):
    i = text.find("{"); return json.loads(text[i:])


tools = harness.initialize("apple-journal-mcp", 11)
READING = ["find_entries", "overview", "read_attachment", "read_entry"]
harness.choosing_tools(tools, READING, off=("delete_entry", {"id": "x", "version": "x"}), runs=("overview", {}),
                       writes=("create_entry", {"title": "E2E 不该写入", "body": "x"}))
harness.stateless(tools, "delete_entry")

# Everything below reads and writes Journal: without Full Disk Access (a bare build has only what
# the app that started it has, usually the terminal), stop here rather than fail at every step.
st, t = call("overview")
harness.stop_unless(st == "OK", "Journal access", t, "journal", "AppleJournalMCP")


def entries(**filters):
    st, t = call("find_entries", limit=500, **filters)
    return obj(t)["entries"] if st == "OK" else []


def remove(entry_id):
    """Deletes an entry for good, through Recently Deleted."""
    st, t = call("read_entry", id=entry_id)
    if st != "OK": return
    e = obj(t)
    if "deleted" not in e:
        st, t = call("delete_entry", id=entry_id, version=e["version"])
        e = obj(call("read_entry", id=entry_id)[1])
    print("cleanup:", call("delete_entry", id=entry_id, version=e["version"], permanently=True))


# Leftovers from an interrupted run.
for e in entries() + entries(deleted=True):
    if e.get("title", "").startswith("agent test e2e"): remove(e["id"])
for j in obj(call("overview")[1])["journals"]:
    if j["name"].startswith("agent test e2e"): print("cleanup:", call("manage_journal", action="delete", journal=j["id"]))
st, t = call("overview"); O = obj(t)
check("overview", st == "OK" and "insights" in O and "time_zone" in O, t[:300])
baseline_entries, baseline_journals = O["all_entries"], len(O["journals"])

st, t = call("manage_journal", action="create", journal="agent test e2e", color="teal", icon="📓")
J = obj(t); check("create journal", st == "OK" and J["name"] == "agent test e2e" and J.get("icon") == "📓" and J.get("uploaded") is not False, t)
st, t = call("manage_journal", action="create", journal="Not allowed"); check("guard blocks other journal names", st == "ERR" and "WRITE_GUARD" in t, t)

BODY = "We walked to the **lighthouse** and *back*, <u>slowly</u>, ~~quickly~~.\n* first\n  * nested\n- dashed\n1. one\n2. two\n> 一句引用"
st, t = call("create_entry", title="agent test e2e 日记", body=BODY, journal="agent test e2e", date="2026-10-30T08:15", bookmarked=True)
A = obj(t); check("create entry", st == "OK" and A["journal"] == "agent test e2e" and A.get("bookmarked") and A["date"] == "2026-10-30T08:15", t)
check("Journal uploads it", A.get("uploaded") is True, t)
st, t = call("read_entry", id=A["id"]); R = obj(t)
check("Markdown reads back as written", st == "OK" and R["body"] == BODY and R["title"] == "agent test e2e 日记" and R["version"] == A["version"], R)
st, t = call("create_entry", title="Not guarded", body="x"); check("guard blocks other titles", st == "ERR" and "WRITE_GUARD" in t, t)
st, t = call("create_entry", title="agent test e2e table", body="| a | b |\n|---|---|\n| 1 | 2 |"); check("tables are refused", st == "ERR" and "tables" in t, t)
st, t = call("create_entry", title="agent test e2e bad", body="x", date="明天"); check("a bad date is invalid params", st == "RPCERR", t)

st, t = call("find_entries", query="lighthouse 引用", journal="agent test e2e"); check("find by words and journal", st == "OK" and [e["id"] for e in obj(t)["entries"]] == [A["id"]], t)
st, t = call("find_entries", after="2026-10-30", before="2026-10-31", bookmarked=True)
check("find by date and bookmark", st == "OK" and A["id"] in [e["id"] for e in obj(t)["entries"]], t[:300])
st, t = call("find_entries", attachments=["photo"], query="lighthouse"); check("find by attachment kind", st == "OK" and obj(t)["total"] == 0, t)

st, t = call("edit_entry", id=A["id"], version=R["version"], replace=[{"old": "**lighthouse**", "new": "*old lighthouse*"}], append="Added at the end.", bookmarked=False)
E = obj(t); check("edit: replace, append, bookmark", st == "OK" and not E.get("bookmarked") and E["version"] != R["version"] and E.get("uploaded") is True, t)
st, t = call("read_entry", id=A["id"]); R2 = obj(t)
check("edit wrote only what changed", R2["body"] == BODY.replace("**lighthouse**", "*old lighthouse*") + "\nAdded at the end.", R2["body"])
st, t = call("edit_entry", id=A["id"], version=R["version"], title="agent test e2e stale"); check("a stale version is refused", st == "ERR" and "changed since" in t, t)
st, t = call("edit_entry", id=A["id"], version=R2["version"], title="Not guarded"); check("guard blocks renaming out of it", st == "ERR" and "WRITE_GUARD" in t, t)
st, t = call("edit_entry", id=A["id"], version=R2["version"], date="2026-10-29", journal=""); E = obj(t)
check("edit: date and out of its journal", st == "OK" and E["date"] == "2026-10-29T12:00" and "journal" not in E, t)

# Attachments made here: a photo, a recording, and a video when ffmpeg can make one.
media = tempfile.mkdtemp()
photo_path, audio_path, video_path = (os.path.join(media, name) for name in ("photo.png", "recording.m4a", "video.mov"))
def png(width, height):
    """A gradient, as an RGB PNG."""
    raw =b"".join(b"\0" + b"".join(bytes((x * 255 // width, y * 255 // height, 160)) for x in range(width)) for y in range(height))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
with open(photo_path, "wb") as f: f.write(png(320, 240))
subprocess.run(["/usr/bin/say", "-o", audio_path, "--file-format=m4af", "--data-format=aac", "agent test recording"], check=True)
ffmpeg = shutil.which("ffmpeg")
if ffmpeg:
    subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", video_path], check=True)
files = [photo_path, audio_path] + ([video_path] if ffmpeg else [])
kinds = ["photo", "audio"] + (["video"] if ffmpeg else [])
st, t = call("edit_entry", id=A["id"], version=E["version"], attach=files); X = obj(t)
check("attach a photo, a recording" + (" and a video" if ffmpeg else ""), st == "OK" and [a["kind"] for a in X.get("attached", [])] == kinds and X.get("uploaded") is True, t)
st, t = call("read_entry", id=A["id"]); R3 = obj(t); shown = {a["id"]: a for a in R3.get("attachments", [])}
check("read_entry lists them", st == "OK" and all(a["id"] in shown for a in X.get("attached", [])), t[:500])
recording = next((a for a in X.get("attached", []) if a["kind"] == "audio"), {"id": "x"})
check("the recording has its length", shown.get(recording["id"], {}).get("duration_seconds") in (1, 2, 3), shown.get(recording["id"]))
r = harness.rpc("tools/call", {"name": "read_attachment", "arguments": {"id": X["attached"][0]["id"]}})
check("the attached photo reads back as an image", any(c["type"] == "image" for c in r["result"]["content"]), str(r)[:300])
st, t = call("edit_entry", id=A["id"], version=R3["version"], attach=["photo.png"]); check("attach needs an absolute path", st == "ERR" and "absolute path" in t, t)
text_path = os.path.join(media, "notes.txt")
with open(text_path, "w") as f: f.write("not media")
st, t = call("edit_entry", id=A["id"], version=R3["version"], attach=[text_path]); check("attach refuses other files", st == "ERR" and "not a photo" in t, t)
st, t = call("edit_entry", id=A["id"], version=R3["version"], detach=[recording["id"]]); D = obj(t)
check("detach the recording", st == "OK" and "audio" not in D.get("attachments", {}) and D.get("uploaded") is True, t)
st, t = call("edit_entry", id=A["id"], version=D["version"], detach=[recording["id"]]); check("a detached attachment is gone", st == "ERR" and "Not found" in t, t)
E = D

st, t = call("duplicate_entry", id=A["id"]); C = obj(t); check("duplicate", st == "OK" and C["id"] != A["id"] and C["title"] == "agent test e2e 日记", t)
st, t = call("delete_entry", id=C["id"], version=C["version"]); check("delete to Recently Deleted", st == "OK" and "Recently Deleted" in t, t)
check("listed in Recently Deleted", C["id"] in [e["id"] for e in entries(deleted=True)])
check("not listed with the others", C["id"] not in [e["id"] for e in entries()])
st, t = call("restore_entry", id=C["id"]); check("restore", st == "OK" and "deleted" not in obj(t), t)
st, t = call("delete_entry", id=C["id"], version=obj(t)["version"], permanently=True); check("permanently needs Recently Deleted first", st == "ERR" and "Recently Deleted" in t, t)

st, t = call("manage_journal", action="update", journal="agent test e2e", new_name="agent test e2e 2", color="#336699", icon="book.closed")
check("update journal", st == "OK" and obj(t)["name"] == "agent test e2e 2" and obj(t).get("color") == "#336699" and obj(t).get("icon") == "book.closed", t)
for entry in (A, C):
    st, t = call("edit_entry", id=entry["id"], version=obj(call("read_entry", id=entry["id"])[1])["version"], journal="agent test e2e 2")
    check("move into a journal", st == "OK" and obj(t)["journal"] == "agent test e2e 2", t)
st, t = call("manage_journal", action="delete", journal="agent test e2e 2", delete_entries=True, expected_entries=5)
check("delete with entries checks the count", st == "ERR" and "holds 2" in t, t)

folder = os.path.join(tempfile.mkdtemp(), "export")
st, t = call("export_entries", to=folder, journal="agent test e2e 2")
check("export", st == "OK" and obj(t)["entries"] == 2 and len([f for f in os.listdir(folder) if f.endswith(".md")]) == 2, t)

st, t = call("read_attachment", id="00000000-0000-0000-0000-000000000000"); check("an unknown attachment is not found", st == "ERR" and "Not found" in t, t)
photo = next((e for e in entries(attachments=["photo"])), None)
if photo:
    st, t = call("read_entry", id=photo["id"]); asset = next(a for a in obj(t)["attachments"] if a["kind"] == "photo")
    r = harness.rpc("tools/call", {"name": "read_attachment", "arguments": {"id": asset["id"]}})
    content = r["result"]["content"]
    check("read_attachment gives a photo as JPEG", content[0]["type"] == "text" and any(c["type"] == "image" and c["mimeType"] == "image/jpeg" for c in content), str(content)[:300])

# The command line, as the skill uses it.
code, out, err = cli("entries", "search", "lighthouse", "--journal", "agent test e2e 2")
check("cli: entries search QUERY --journal", code == 0 and obj(out)["total"] == 2, (code, out, err))
code, out, err = cli("entries", "create", "-", "--title", "agent test e2e cli", "--journal", "agent test e2e 2", stdin="Line one\n* item\n")
K = obj(out) if code == 0 else {}; check("cli: entries create - (stdin)", code == 0 and K.get("journal") == "agent test e2e 2", (code, out, err))
code, out, err = cli("entries", "read", K.get("id", "x")); check("cli: entries read", code == 0 and obj(out)["body"] == "Line one\n* item", (code, out, err))
code, out, err = cli("entries", "edit", K.get("id", "x"), "--version", K.get("version", "x"), "--attach", photo_path)
check("cli: entries edit --attach", code == 0 and [a["kind"] for a in obj(out).get("attached", [])] == ["photo"], (code, out, err))
code, out, err = cli("entries", "edit", K.get("id", "x"), "--version", "stale", "--bookmarked")
check("cli: a stale version exits 1, naming commands", code == 1 and "changed since" in err and "entries read" in err and out == "", (code, out, err))
code, out, err = cli("entries", "list", "--bogus"); check("cli: an unknown flag exits 2", code == 2 and "--bogus" in err and out == "", (code, out, err))
code, out, err = cli("journals", "create", "Not allowed"); check("cli: a guarded write exits 1", code == 1 and "WRITE_GUARD" in err, (code, out, err))
code, out, err = cli("journals", "list"); check("cli: journals list", code == 0 and any(j["name"] == "agent test e2e 2" for j in obj(out)["journals"]), (code, out, err))
harness.skill_names_this_copy("apple-journal")
# The choice of tools holds on the command line too, which the skill uses.
with open(TOOLS_FILE + ".new", "w") as f: json.dump({"tools": {name: name != "export_entries" for name in tools}}, f)
os.replace(TOOLS_FILE + ".new", TOOLS_FILE)
code, out, err = cli("entries", "export", "/tmp/never"); check("cli: a turned-off tool exits 1", code == 1 and "turned off" in err and out == "", (code, out, err))
os.remove(TOOLS_FILE)

# Everything made here goes, for good: the journal with its entries, then the entries.
st, t = call("manage_journal", action="delete", journal="agent test e2e 2", delete_entries=True, expected_entries=3)
check("delete journal with its entries", st == "OK" and obj(t)["entries"] == 3, t)
for e in entries(deleted=True):
    if e.get("title", "").startswith("agent test e2e"):
        st, t = call("delete_entry", id=e["id"], version=e["version"], permanently=True)
        check(f"delete for good: {e['title']}", st == "OK" and obj(t).get("uploaded") is not False, t)
st, t = call("overview"); O = obj(t)
check("entries and journals back to baseline", O["all_entries"] == baseline_entries and len(O["journals"]) == baseline_journals, t[:300])

print("stderr:", harness.stop()[:500])
finish()
