"""End-to-end check of the MCP server over stdio, against the real Contacts store.

Writes are confined by the write guard to contacts, groups and smart lists whose name starts with
"agent test e2e", all made in the default account (iCloud here, so the user's other devices see
them come and go). The script removes leftovers of an interrupted run first, matching that prefix
only, and deletes everything it made at the end; this app's 30-day copies of the deleted test cards
are removed too. The choice of tools is read from a throwaway tools.json, so the user's own choice
neither hides tools from the checks nor changes. Usage:

    /usr/bin/python3 -I scripts/e2e.py contacts [path to the AppleContactsMCP executable]

The app needs the Contacts permission and Automation → Contacts (run it with `setup` once).
"""
import glob, json, os, struct, sys, tempfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves this folder off the path
import harness
from harness import call, check, cli, finish

PREFIX = "agent test e2e"
APP, env, TOOLS_FILE = harness.start("AppleContactsMCP", "APPLE_CONTACTS_MCP", PREFIX)


def obj(text):
    i = text.find("{")
    return json.loads(text[i:]) if i >= 0 else {}


tools = harness.initialize("apple-contacts-mcp", 20)
READING = ["contact_changes", "find_contacts", "find_duplicates", "list_groups", "overview", "read_contact", "read_photo"]
harness.choosing_tools(tools, READING, off=("delete_contact", {"id": "x", "version": "x"}), runs=("overview", {}),
                       writes=("create_contact", {"first_name": "E2E 不该写入"}))
harness.stateless(tools, "delete_contact")

# Everything below reads and writes Contacts: without access (a bare build has only what the app
# that started it has, usually the terminal), stop here rather than fail at every step.
st, t = call("overview")
harness.stop_unless(st == "OK", "Contacts access", t, "contacts", "AppleContactsMCP")


def ours(rows):
    return [r for r in rows if r.get("name", "").lower().startswith(PREFIX)]


def version(contact_id):
    st, t = call("read_contact", id=contact_id)
    return obj(t).get("version") if st == "OK" else None


# Leftovers from an interrupted run: only names that start with the prefix.
st, t = call("find_contacts", query=PREFIX, limit=500)
for c in ours(obj(t).get("contacts", [])):
    print("cleanup:", call("delete_contact", id=c["id"], version=version(c["id"]) or "x")[0])
st, t = call("list_groups")
for account in obj(t).get("accounts", []):
    stack = list(account["groups"])
    while stack:
        g = stack.pop()
        stack += g.get("groups", [])
        if g["name"].lower().startswith(PREFIX): print("cleanup:", call("manage_group", action="delete", group=g["id"])[0])
for s in obj(t).get("smart_lists", []):
    if s["name"].lower().startswith(PREFIX): print("cleanup:", call("manage_smart_list", action="delete", smart_list=s["id"])[0])

st, t = call("overview"); O = obj(t)
check("overview", st == "OK" and O.get("contacts", 0) > 0 and any(a.get("default") for a in O["accounts"]), t[:300])
baseline = O["contacts"]
token = obj(call("contact_changes")[1]).get("token")
check("contact_changes gives a token", bool(token))

photo = os.path.join(tempfile.mkdtemp(), "e2e.png")
rows = b"".join(b"\x00" + b"".join(bytes([x * 4 % 256, y * 4 % 256, 120]) for x in range(64)) for y in range(64))
chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
with open(photo, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))

# Create: most kinds of field, Emergency Bypass, a note (through Contacts' AppleScript) and a photo.
st, t = call("create_contact", first_name=PREFIX, last_name="甲", organization="e2e测试公司", job_title="工程师",
             suffix="e2e9", maiden_name="e2e9 旧姓", phonetic_first_name="e2e9 jia", name_order="given_first",
             urls=[{"label": "homepage", "value": "https://e2e9.example.com"}], emergency_bypass="calls",
             phones=[{"label": "mobile", "value": "+1 555 010 0901"}, {"label": "home fax", "value": "+1 555 010 0902"}],
             emails=[{"label": "work", "value": "e2e.one@example.com"}],
             addresses=[{"label": "home", "street": "1 Infinite Loop", "sub_locality": "Downtown", "city": "Cupertino", "state": "CA", "country_code": "us"}],
             dates=[{"label": "anniversary", "value": "2015-06-01"}], related_names=[{"label": "brother in law", "value": "e2e9 Kin"}],
             social_profiles=[{"service": "Twitter", "username": "e2e9tw"}], instant_messages=[{"service": "Skype", "username": "e2e9im"}],
             birthday="05-17", other_birthday={"calendar": "chinese", "month": 4, "day": 23}, note="第一行\n第二行 e2e9 ✓", photo=photo)
A = obj(t)
check("create contact", st == "OK" and A.get("name", "").startswith(PREFIX + " 甲") and A.get("note") == "第一行\n第二行 e2e9 ✓" and A.get("photo") is True
      and A.get("phones", [{}])[1].get("label") == "home fax" and A.get("related_names", [{}])[0].get("label") == "brother in law"
      and A.get("birthday") == "05-17" and A.get("other_birthday", {}).get("calendar") == "chinese"
      and A.get("addresses", [{}])[0].get("sub_locality") == "Downtown" and A.get("suffix") == "e2e9" and A.get("maiden_name") == "e2e9 旧姓"
      and A.get("phonetic_first_name") == "e2e9 jia" and A.get("name_order") == "given_first"
      and A.get("urls", [{}])[0].get("label") == "homepage" and A.get("ringtone", {}).get("ignore_mute") is True, t[:900])
check("create waits for the upload", A.get("uploaded") in (True, None), A.get("upload_note", ""))
st, t = call("create_contact", type="company", organization=PREFIX + " 公司", phones=[{"value": "+1 555 010 0903"}], wait=False)
B = obj(t)
check("create company", st == "OK" and B.get("type") == "company" and B.get("name") == PREFIX + " 公司", t[:300])
st, t = call("create_contact", first_name="E2E 不该写入")
check("the write guard refuses other names", st == "ERR" and "write guard" in t, t)
st, t = call("create_contact", first_name=PREFIX, birthday="2025-02-29")
check("an impossible day is refused", st == "RPCERR" and "real day" in t, t)

# Read and search.
st, t = call("read_contact", id=A["id"]); R = obj(t)
check("read_contact", st == "OK" and R.get("version") == A.get("version") and R.get("cards", [{}])[0].get("id") == A["id"], t[:400])
st, t = call("find_contacts", query="第二行 e2e9")
check("search finds words in the note", st == "OK" and [c["id"] for c in obj(t).get("contacts", [])] == [A["id"]], t[:300])
st, t = call("find_contacts", phone="(555) 010-0901")
check("search by phone number", st == "OK" and A["id"] in [c["id"] for c in obj(t).get("contacts", [])], t[:300])
st, t = call("find_contacts", query=PREFIX, type="company")
check("search companies", st == "OK" and [c["id"] for c in obj(t).get("contacts", [])] == [B["id"]], t[:300])
st, t = call("read_photo", id=A["id"])
check("read_photo", st == "OK" and "photo" in t, t[:200])
st, t = call("find_duplicates")
check("find_duplicates", st == "OK" and "sets" in obj(t), t[:200])
st, t = call("settings")
check("settings are read", st == "OK" and obj(t).get("sort_by") in ("first_name", "last_name"), t[:200])

# Update: a card with a note (set aside around the save), lists, a value written differently, a
# clear, a stale version.
st, t = call("update_contact", id=A["id"], version="stale", job_title="x")
check("a stale version is refused", st == "ERR" and "changed since" in t, t)
st, t = call("update_contact", id=A["id"], version=R["version"], job_title="总监", birthday=None,
             phones=[{"label": "iPhone", "value": "+1 555 010 0901"}, {"label": "work", "value": "+1 555 010 0904"}],
             emails=[{"label": "work", "value": "E2E.One@Example.com"}], note="改过的备注")
U = obj(t)
check("update a card with a note", st == "OK" and U.get("job_title") == "总监" and "birthday" not in U and U.get("note") == "改过的备注"
      and [p["label"] for p in U.get("phones", [])] == ["iPhone", "work"] and U.get("version") != R["version"], t[:500])
check("a value written differently takes the new form", U.get("emails", [{}])[0].get("value") == "E2E.One@Example.com", U.get("emails"))

# Screen Time: Contacts.framework treats a card allowed during Downtime as read-only, and Contacts'
# AppleScript cannot save one at all, so its note is refused before anything changes.
st, t = call("create_contact", first_name=PREFIX, last_name="停用时间", downtime_allowed=True, wait=False); E = obj(t)
check("create a card allowed during Downtime", st == "OK" and E.get("downtime_allowed") is True, t[:300])
st, t = call("update_contact", id=E.get("id", "x"), version=E.get("version", "x"), job_title="e2e9 允许", wait=False)
check("update a card allowed during Downtime", st == "OK" and obj(t).get("job_title") == "e2e9 允许", t[:300])
st, t = call("update_contact", id=E.get("id", "x"), version=obj(t).get("version", "x"), note="e2e9 不该写入", wait=False)
check("its note is refused before anything changes", st == "ERR" and "Downtime" in t, t[:300])
check("no note is left set aside", not os.path.exists(os.path.expanduser("~/Library/Application Support/AppleContactsMCP/notes-aside.json")))

# Groups: members through AppleScript, nesting.
st, t = call("manage_group", action="create", group=PREFIX + " 分组", members=[A["id"], B["id"]])
G = obj(t)
check("create a group with members", st == "OK" and G.get("count") == 2, t[:300])
st, t = call("manage_group", action="create", group=PREFIX + " 子分组", parent=PREFIX + " 分组")
check("create a nested group", st == "OK", t[:200])
st, t = call("list_groups", group=PREFIX + " 分组", nested=True)
check("members with nested groups", st == "OK" and obj(t).get("groups"), t[:300])
st, t = call("manage_group", action="remove_members", group=PREFIX + " 分组", members=[A["id"]])
check("remove a member that has a note", st == "OK" and [c["id"] for c in obj(t).get("contacts", [])] == [B["id"]], t[:300])
st, t = call("manage_group", action="unnest", group=PREFIX + " 子分组", parent=PREFIX + " 分组")
check("unnest", st == "OK" and obj(t).get("nested") is False, t)
st, t = call("manage_group", action="nest", group=PREFIX + " 分组", parent=PREFIX + " 分组")
check("a group cannot hold itself", st == "ERR", t)
st, t = call("manage_group", action="rename", group=PREFIX + " 子分组", new_name="改名")
check("the write guard covers group names", st == "ERR" and "write guard" in t, t)

# Smart lists.
st, t = call("manage_smart_list", action="create", smart_list=PREFIX + " 智能", criteria={"rules": [{"field": "organization", "op": "contains", "value": "e2e测试公司"}]})
check("create a smart list", st == "OK" and obj(t).get("cards") == 1, t[:300])
st, t = call("find_contacts", smart_list=PREFIX + " 智能")
check("find by smart list", st == "OK" and [c["id"] for c in obj(t).get("contacts", [])] == [A["id"]], t[:300])
st, t = call("find_contacts", criteria={"rules": [{"field": "birthday", "op": "contains", "value": "x"}]})
check("bad criteria are refused", st == "RPCERR", t)
st, t = call("manage_smart_list", action="delete", smart_list=PREFIX + " 智能")
check("delete a smart list", st == "OK", t)

# Link, prefer, unlink; merge.
st, t = call("create_contact", first_name=PREFIX, last_name="乙", emails=[{"label": "home", "value": "e2e.two@example.com"}],
             phones=[{"label": "mobile", "value": "+1 555 010 0901"}], job_title="e2e9 职位", note="e2e9 乙的备注", wait=False)
C = obj(t)
st, t = call("link_contacts", action="link", ids=[A["id"], C["id"]])
L = obj(t)
check("link two cards", st == "OK" and len(L.get("cards", [])) == 2 and sum(1 for c in L["cards"] if c.get("gives_name")) == 1, t[:400])
# A linked contact: a cleared field and note go from both cards; a number both cards have stays on both.
st, t = call("update_contact", id=A["id"], version=version(A["id"]), job_title=None, note=None, wait=False,
             phones=[{"label": "iPhone", "value": "+1 555 010 0901"}, {"label": "work", "value": "+1 555 010 0904"}, {"label": "home", "value": "+1 555 010 0906"}])
check("a linked contact: a cleared field goes from every card", st == "OK" and "job_title" not in obj(t) and "note" not in obj(t), t[:400])
st, t = call("link_contacts", action="prefer_name", id=C["id"])
check("prefer a card's name", st == "OK" and obj(t).get("name") == PREFIX + " 乙", t[:300])
st, t = call("link_contacts", action="unlink", id=C["id"])
check("unlink a card", st == "OK" and len(obj(t).get("contacts", [])) == 2, t[:300])
st, t = call("read_contact", id=C["id"])
digits = ["".join(ch for ch in p["value"] if ch.isdigit()) for p in obj(t).get("phones", [])]
check("a number both linked cards had stays on both", st == "OK" and "15550100901" in digits and "job_title" not in obj(t) and "note" not in obj(t), t[:400])
st, t = call("update_contact", id=A["id"], version=version(A["id"]), note="改过的备注", wait=False)
check("a note goes back on an unlinked card", st == "OK" and obj(t).get("note") == "改过的备注", t[:300])
st, t = call("merge_contacts", ids=[A["id"], C["id"]], versions=[version(A["id"]), version(C["id"])])
M = obj(t)
check("merge two cards", st == "OK" and {e["value"].lower() for e in M.get("emails", [])} == {"e2e.one@example.com", "e2e.two@example.com"}
      and M.get("merged") == [C["id"]], t[:500])

# Delete and restore (with the same id, note and groups).
st, t = call("delete_contact", id=B["id"], version=version(B["id"]))
check("delete a contact", st == "OK" and obj(t).get("deleted") == PREFIX + " 公司", t[:300])
st, t = call("restore_contact")
check("restore_contact lists it", st == "OK" and B["id"] in [d["id"] for d in obj(t).get("deleted", [])], t[:300])
st, t = call("restore_contact", id=B["id"])
check("restore it with its id and group", st == "OK" and obj(t).get("id") == B["id"] and obj(t).get("groups"), t[:300])

# Export and import.
folder = tempfile.mkdtemp()
st, t = call("export_contacts", to=os.path.join(folder, "e2e.vcf"), ids=[A["id"], B["id"]])
check("export with notes", st == "OK" and obj(t).get("contacts") == 2 and "NOTE:" in open(os.path.join(folder, "e2e.vcf")).read(), t[:300])
st, t = call("import_contacts", path=os.path.join(folder, "e2e.vcf"))
check("import skips duplicates", st == "OK" and obj(t).get("added") == 0 and len(obj(t).get("skipped_duplicates", [])) == 2, t[:300])
st, t = call("export_contacts", to=os.path.join(folder, "e2e-b.vcf"), ids=[B["id"]])
st, t = call("import_contacts", path=os.path.join(folder, "e2e-b.vcf"), duplicates="replace"); I = obj(t)
new_b = (I.get("ids") or ["x"])[0]
st2, t2 = call("list_groups", group=PREFIX + " 分组")
check("import replace: a new card in the old one's place and groups", st == "OK" and I.get("replaced") == [B["id"]] and I.get("added") == 1
      and new_b in [c["id"] for c in obj(t2).get("contacts", [])], (t[:300], t2[:300]))
st, t = call("contact_changes", since=token, include_own=True)
check("contact_changes since the token", st == "OK" and (obj(t).get("count", 0) > 0 or "everything" in obj(t)), t[:300])

# The command line.
code, out, err = cli("contacts", "create", "--first-name", PREFIX, "--last-name", "命令行", "--phones", '[{"label":"home","value":"+1 555 010 0905"}]', "--no-wait")
D = obj(out) if code == 0 else {}
check("cli: contacts create", code == 0 and D.get("name") == PREFIX + " 命令行", (code, out, err))
code, out, err = cli("contacts", "search", "命令行 " + PREFIX)
check("cli: contacts search", code == 0 and obj(out).get("total") == 1, (code, out, err))
code, out, err = cli("contacts", "update", D.get("id", "x"), "--version", D.get("version", "x"), "--nickname", "小行", "--no-wait")
check("cli: contacts update", code == 0 and obj(out).get("nickname") == "小行", (code, out, err))
code, out, err = cli("groups", "list", "--format", "json")
check("cli: groups list --format json", code == 0 and "accounts" in obj(out), (code, err))
code, out, err = cli("contacts", "search", "--bogus")
check("cli: an unknown flag exits 2", code == 2 and "--bogus" in err, (code, out, err))
code, out, err = cli("contacts", "create", "--first-name", "E2E 不该写入")
check("cli: a guarded write exits 1", code == 1 and "write guard" in err, (code, out, err))
harness.skill_names_this_copy("apple-contacts")

# Clean up: every test contact, group and smart list, and this app's copies of the deleted ones.
st, t = call("find_contacts", query=PREFIX, limit=500)
for c in ours(obj(t).get("contacts", [])):
    call("delete_contact", id=c["id"], version=version(c["id"]) or "x")
for name in (PREFIX + " 子分组", PREFIX + " 分组"):
    call("manage_group", action="delete", group=name)
for path in glob.glob(os.path.expanduser("~/Library/Application Support/AppleContactsMCP/Deleted/*.json")):
    with open(path) as f:
        if json.load(f).get("name", "").lower().startswith(PREFIX): os.remove(path)
st, t = call("overview")
check("contact count back to baseline", st == "OK" and obj(t).get("contacts") == baseline, t[:200])

print("stderr:", harness.stop()[:500])
finish()
