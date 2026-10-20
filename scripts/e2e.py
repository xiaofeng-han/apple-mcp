"""End-to-end check of the MCP server over stdio, against the real Reminders store.

Writes are confined by the write guard to three throwaway lists ("agent test", "agent test 2",
"agent test 3"); the script removes leftovers of an interrupted run first and deletes the lists
at the end, so only Recently Deleted keeps traces. Usage:

    /usr/bin/python3 -I scripts/e2e.py [path to the AppleRemindersMCP executable]

The app needs the Reminders permission (run it with `setup` once).
"""
import json, os, struct, subprocess, sys, tempfile, zlib, datetime

APP = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP")
env = dict(os.environ, APPLE_REMINDERS_MCP_WRITE_GUARD="agent test,agent test 2,agent test 3,agent test 4,agent test group,agent test smart e2e,agent test template")
proc = subprocess.Popen([APP, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
seq = 0
def rpc(method, params=None):
    global seq; seq += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq, "method": method, "params": params or {}}) + "\n"); proc.stdin.flush()
    return json.loads(proc.stdout.readline())
def call(name, **args):
    r = rpc("tools/call", {"name": name, "arguments": args})
    if "error" in r: return ("RPCERR", r["error"]["message"])
    res = r["result"]; text = res["content"][0]["text"]
    return ("ERR" if res["isError"] else "OK", text)
def obj(text):
    i = text.find("{"); return json.loads(text[i:])
fails = []
def check(label, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + label + ("" if cond else f"  -> {detail}"))
    if not cond: fails.append(label)

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
check("initialize", init["result"]["serverInfo"]["name"] == "apple-reminders-mcp", init)
tools = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
check("16 tools", len(tools) == 16, tools)

# Leftovers from an interrupted run: empty and delete the test lists.
st, t = call("list_lists")
for l in obj(t)["lists"]:
    if l["name"] in ("agent test", "agent test 2", "agent test 3", "agent test 4"):
        st2, t2 = call("find_reminders", list=l["id"], include_completed=True)
        for r in obj(t2)["reminders"]:
            if "parent_id" not in r:
                st3, t3 = call("get_reminder", id=r["id"])
                if st3 == "OK": call("delete_reminder", id=r["id"], version=obj(t3)["version"])
        st2, t2 = call("find_reminders", list=l["id"], include_completed=True)
        for r in obj(t2)["reminders"]:
            st3, t3 = call("get_reminder", id=r["id"])
            if st3 == "OK": call("delete_reminder", id=r["id"], version=obj(t3)["version"])
        print("cleanup:", call("manage_list", action="delete", list=l["id"]))
st, t = call("list_lists")
for g in obj(t).get("groups", []):
    if g["name"] == "agent test group":
        for name in g["lists"]: call("manage_list", action="update", list=name, group=None)
        print("cleanup:", call("manage_group", action="delete", group=g["id"]))
for tp in obj(t).get("templates", []):
    if tp["name"] == "agent test template": print("cleanup:", call("manage_template", action="delete", template=tp["id"]))
for sl in obj(t).get("smart_lists", []):
    if sl["name"] == "agent test smart e2e": print("cleanup:", call("manage_smart_list", action="delete", smart_list=sl["id"]))
st, t = call("list_lists"); lists = obj(t)["lists"]
check("list_lists", st == "OK" and any(l.get("default") for l in lists), t[:300])
baseline_lists = len(lists)
st, t = call("find_reminders", limit=500); baseline_open = obj(t)["count"]; check("find_reminders", st == "OK", t[:200])

st, t = call("manage_list", action="create", list="agent test"); check("create list", st == "OK", t)
st, t = call("manage_list", action="create", list="agent test 2"); check("create list 2", st == "OK", t)
st, t = call("manage_list", action="create", list="Not allowed"); check("guard blocks other list name", st == "ERR" and "limited" in t, t)

tomorrow = (datetime.date.today() + datetime.timedelta(days=1)).isoformat()
day_after = (datetime.date.today() + datetime.timedelta(days=2)).isoformat()
st, t = call("create_reminder", title="E2E 父任务", list="agent test", due=tomorrow, priority="high", tags=["#agenttest", "测试"], flagged=True, notes="第一行\n第二行")
check("create parent", st == "OK", t); A = obj(t)
check("parent fields", A.get("due") == tomorrow and A.get("priority") == "high" and A.get("flagged") and sorted(A.get("tags", [])) == sorted(["agenttest", "测试"]) and A.get("notes") == "第一行\n第二行", A)
st, t = call("create_reminder", title="E2E 子任务", parent_id=A["id"]); check("create subtask (list from parent)", st == "OK" and obj(t).get("parent_id") == A["id"] and obj(t)["list"] == "agent test", t); B = obj(t)
st, t = call("create_reminder", title="E2E 紧急", list="agent test", due=f"{tomorrow}T09:00", urgent=True); check("create urgent", st == "OK" and obj(t).get("urgent") and obj(t)["due"] == f"{tomorrow}T09:00", t); U = obj(t)
st, t = call("create_reminder", title="E2E 紧急无时间", list="agent test", due=tomorrow, urgent=True); check("urgent needs a time", st == "ERR" and "needs a due date with a time" in t, t)
st, t = call("create_reminder", title="E2E 不该写入", list="Reminders"); check("guard blocks real list", st == "ERR" and "limited" in t, t)
st, t = call("create_reminder", title="E2E 孙任务", parent_id=B["id"]); check("no second subtask level", st == "ERR" and "one level" in t, t)
st, t = call("create_reminder", title="E2E 坏日期", list="agent test", due="明天"); check("bad due is invalid params", st == "RPCERR", t)

st, t = call("get_reminder", id=A["id"]); G = obj(t)
check("get shows subtask; all-day due has no alarm object", st == "OK" and [s["id"] for s in G.get("subtasks", [])] == [B["id"]] and "alarms" not in G, G)
check("adding a subtask keeps the parent's version", G["version"] == A["version"], G)
A = dict(A, version=G["version"])
st, t = call("get_reminder", id=U["id"]); GU = obj(t); check("urgent has alarm at due", GU.get("alarms") == [f"{tomorrow}T09:00"], GU)

st, t = call("update_reminder", id=A["id"], version="stale", title="x"); check("stale version rejected", st == "ERR" and "changed since" in t, t)
st, t = call("update_reminder", id=A["id"], version=A["version"], title="E2E 父任务（改）", due=f"{tomorrow}T10:30", tags=["改过"], priority="low", flagged=False)
check("update fields", st == "OK", t); A2 = obj(t)
check("updated values", A2["title"] == "E2E 父任务（改）" and A2["due"] == f"{tomorrow}T10:30" and A2.get("tags") == ["改过"] and A2.get("priority") == "low" and not A2.get("flagged") and A2["version"] != A["version"], A2)
st, t = call("get_reminder", id=A["id"]); check("alarm moved with due", obj(t).get("alarms") == [f"{tomorrow}T10:30"], t)
st, t = call("update_reminder", id=A["id"], version=A2["version"], due=None); A3 = obj(t)
check("clear due", st == "OK" and "due" not in A3, t)
st, t = call("get_reminder", id=A["id"]); check("clearing due removes alarm", "alarms" not in obj(t), t)
st, t = call("update_reminder", id=A["id"], version=A3["version"], notes=""); A4 = obj(t); check("clear notes", st == "OK" and "notes" not in A4, t)

st, t = call("update_reminder", id=U["id"], version=U["version"], due=tomorrow); U2 = obj(t)
check("date-only due turns urgent off", st == "OK" and not U2.get("urgent") and U2["due"] == tomorrow, t)
st, t = call("update_reminder", id=U["id"], version=U2["version"], urgent=True); check("urgent on all-day rejected", st == "ERR", t)

st, t = call("update_reminder", id=B["id"], version=B["version"], parent_id=None); B2 = obj(t); check("promote subtask", st == "OK" and "parent_id" not in B2, t)
st, t = call("update_reminder", id=B["id"], version=B2["version"], parent_id=A["id"]); B3 = obj(t); check("re-parent", st == "OK" and B3.get("parent_id") == A["id"], t)
st, t = call("update_reminder", id=A["id"], version=A4["version"], list="agent test 2"); check("move with subtasks rejected", st == "ERR" and "subtasks" in t, t)
st, t = call("update_reminder", id=B["id"], version=B3["version"], list="agent test 2"); B4 = obj(t)
check("move subtask to other list -> top level there", st == "OK" and B4["list"] == "agent test 2" and "parent_id" not in B4, t)
st, t = call("update_reminder", id=B["id"], version=B4["version"], list="Reminders"); check("guard blocks move to real list", st == "ERR" and "limited" in t, t)

st, t = call("update_reminder", id=A["id"], version=A4["version"], completed=True); A5 = obj(t); check("complete", st == "OK" and A5.get("completed") and "completed_at" in A5, t)
st, t = call("find_reminders", list="agent test"); check("completed hidden by default", st == "OK" and A["id"] not in [r["id"] for r in obj(t)["reminders"]], t)
st, t = call("find_reminders", list="agent test", include_completed=True, query="父任务"); check("query + include_completed", st == "OK" and [r["id"] for r in obj(t)["reminders"]] == [A["id"]], t)
st, t = call("find_reminders", tag="改过", include_completed=True); check("tag filter", st == "OK" and [r["id"] for r in obj(t)["reminders"]] == [A["id"]], t)
st, t = call("find_reminders", list="agent test", due_before=day_after, due_after=tomorrow); check("due window", st == "OK" and [r["id"] for r in obj(t)["reminders"]] == [U["id"]], t)

st, t = call("manage_list", action="update", list="agent test 2", new_name="agent test 3", color="orange", icon="🧪"); L3 = obj(t)
check("update list name/color/icon", st == "OK" and L3["name"] == "agent test 3" and L3.get("color") == "orange" and L3.get("icon") == "🧪", t)
st, t = call("manage_list", action="update", list="agent test 3", color="#12AB34", icon=""); L3 = obj(t)
check("custom color, default icon", st == "OK" and L3.get("color") == "#12AB34" and "icon" not in L3, t)
st, t = call("manage_list", action="update", list="agent test 3", color="teal"); check("bad color is invalid params", st == "RPCERR", t)
st, t = call("manage_group", action="create", group="agent test group"); check("create group", st == "OK", t)
st, t = call("manage_list", action="update", list="agent test 3", group="agent test group"); check("move list into group", st == "OK" and obj(t).get("group") == "agent test group", t)
st, t = call("list_lists"); G1 = [g for g in obj(t).get("groups", []) if g["name"] == "agent test group"]
check("list_lists shows group", G1 and G1[0]["lists"] == ["agent test 3"], t)
st, t = call("manage_group", action="delete", group="agent test group"); check("delete non-empty group rejected", st == "ERR" and "still has" in t, t)
st, t = call("manage_group", action="rename", group="agent test group", new_name="Not allowed"); check("guard blocks group rename", st == "ERR" and "limited" in t, t)
st, t = call("manage_list", action="update", list="agent test 3", group=None); check("move list out of group", st == "OK" and "group" not in obj(t), t)
st, t = call("manage_group", action="delete", group="agent test group"); check("delete empty group", st == "OK", t)

# Sections
st, t = call("manage_section", action="create", list="agent test 3", section="分区甲"); check("create section", st == "OK", t)
st, t = call("create_reminder", title="E2E 分区里", list="agent test 3", section="分区甲"); S1 = obj(t); check("create in section", st == "OK" and S1.get("section") == "分区甲", t)
st, t = call("find_reminders", list="agent test 3", section="分区甲"); check("find by section", st == "OK" and [r["id"] for r in obj(t)["reminders"]] == [S1["id"]], t)
st, t = call("manage_section", action="rename", list="agent test 3", section="分区甲", new_name="分区乙"); check("rename section", st == "OK", t)
st, t = call("get_reminder", id=S1["id"]); S1 = obj(t); check("reminder follows renamed section", S1.get("section") == "分区乙", t)
st, t = call("update_reminder", id=S1["id"], version=S1["version"], section=None); S2 = obj(t); check("take out of section", st == "OK" and "section" not in S2, t)
st, t = call("update_reminder", id=S1["id"], version=S2["version"], section="分区乙"); S3 = obj(t); check("put back in section", st == "OK" and S3.get("section") == "分区乙", t)
st, t = call("manage_section", action="delete", list="agent test 3", section="分区乙"); check("delete section", st == "OK", t)
st, t = call("get_reminder", id=S1["id"]); check("reminder stays after section delete", st == "OK" and "section" not in obj(t), t)

# Repeat
st, t = call("create_reminder", title="E2E 无日期重复", list="agent test 3", repeat={"frequency": "daily"}); check("repeat needs a due date", st == "ERR" and "due date" in t, t)
until = (datetime.date.today() + datetime.timedelta(days=60)).isoformat()
st, t = call("create_reminder", title="E2E 每周一三", list="agent test 3", due=f"{tomorrow}T08:00", repeat={"frequency": "weekly", "days_of_week": ["mon", "wed"], "until": until}); W = obj(t)
check("create weekly repeat", st == "OK" and W.get("repeat", {}).get("frequency") == "weekly" and W["repeat"].get("days_of_week") == ["mon", "wed"] and W["repeat"].get("until") == until, t)
st, t = call("update_reminder", id=W["id"], version=W["version"], repeat={"frequency": "monthly", "interval": 2, "days_of_month": [1, -1], "count": 6}); W2 = obj(t)
check("update to monthly", st == "OK" and W2["repeat"] == {"frequency": "monthly", "interval": 2, "days_of_month": [1, -1], "count": 6}, t)
st, t = call("update_reminder", id=W["id"], version=W2["version"], repeat={"frequency": "monthly", "days_of_week": ["-1fri"]}); W3 = obj(t)
check("last friday of the month", st == "OK" and W3["repeat"].get("days_of_week") == ["-1fri"], t)
st, t = call("find_reminders", list="agent test 3", repeating=True); check("find repeating", st == "OK" and [r["id"] for r in obj(t)["reminders"]] == [W["id"]], t)
st, t = call("update_reminder", id=W["id"], version=W3["version"], repeat=None); W4 = obj(t); check("stop repeating", st == "OK" and "repeat" not in W4, t)

# Completing a repeating reminder, and the setting that turns it off
st, t = call("create_reminder", title="E2E 每天", list="agent test 3", due=f"{tomorrow}T07:00", repeat={"frequency": "daily"}); D = obj(t)
subprocess.run(["defaults", "write", "com.xiaofeng.apple-reminders-mcp", "AllowCompletingRecurringReminders", "-bool", "NO"], check=True)
st, t = call("update_reminder", id=D["id"], version=D["version"], completed=True); check("setting off blocks completing repeating", st == "ERR" and "settings" in t, t)
subprocess.run(["defaults", "delete", "com.xiaofeng.apple-reminders-mcp", "AllowCompletingRecurringReminders"], check=True)
st, t = call("update_reminder", id=D["id"], version=D["version"], completed=True); D2 = obj(t)
check("complete repeating moves to next date", st == "OK" and "next date" in t and not D2.get("completed") and D2["due"] == f"{day_after}T07:00" and D2.get("repeat"), t)
st, t = call("find_reminders", list="agent test 3", include_completed=True, query="E2E 每天"); copies = [r for r in obj(t)["reminders"] if r.get("completed")]
check("completed copy kept", len(copies) == 1 and copies[0]["due"] == f"{tomorrow}T07:00" and "repeat" not in copies[0], t)

# 0.3: start, early alerts, place and car alerts, when messaging, url, images, position
def png(path, w=3, h=2):
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
image_path = os.path.join(tempfile.mkdtemp(), "e2e.png"); png(image_path)
st, t = call("create_reminder", title="E2E 全字段", list="agent test 3", due=f"{tomorrow}T10:00", start=tomorrow,
             early_alerts=[{"before": 15, "unit": "minutes"}, {"before": 1, "unit": "days"}],
             location={"title": "Apple Park", "latitude": 37.3349, "longitude": -122.009, "radius": 150, "when": "leaving"},
             when_messaging={"phones": ["+1 555 0100"], "emails": ["e2e@example.com"]}, url="https://example.com/e2e", add_images=[image_path])
F = obj(t)
check("create with every field", st == "OK" and F.get("start") == tomorrow and F.get("url") == "https://example.com/e2e" and F.get("images") == 1
      and F.get("location", {}).get("when") == "leaving" and F.get("when_messaging", {}).get("emails") == ["e2e@example.com"], t)
st, t = call("get_reminder", id=F["id"]); FD = obj(t)
check("detail shows early alerts and image", st == "OK" and sorted((a["before"], a["unit"]) for a in FD.get("early_alerts", [])) == [(1, "days"), (15, "minutes")]
      and FD["images"][0]["width"] == 3 and FD["images"][0]["height"] == 2, t)
st, t = call("read_image", reminder_id=F["id"], image_id=FD["images"][0]["id"])
check("read_image without Full Disk Access explains", (st == "ERR" and "Full Disk Access" in t) or (st == "OK" and "3×2" in t), t)
st, t = call("update_reminder", id=F["id"], version=F["version"], early_alerts=[{"before": 2, "unit": "hours"}], location="getting-in-car",
             when_messaging=None, url=None, remove_images=[FD["images"][0]["id"]], start=None)
F2 = obj(t)
check("update replaces and clears", st == "OK" and F2.get("location") == "getting-in-car" and "when_messaging" not in F2 and "url" not in F2 and "images" not in F2 and "start" not in F2, t)
st, t = call("get_reminder", id=F["id"]); check("early alerts replaced", [(a["before"], a["unit"]) for a in obj(t).get("early_alerts", [])] == [(2, "hours")], t)
st, t = call("update_reminder", id=F["id"], version=obj(t)["version"], location="getting-out-of-car", early_alerts=None)
check("car out, alerts cleared", st == "OK" and obj(t).get("location") == "getting-out-of-car", t)
st, t = call("get_reminder", id=F["id"]); check("no early alerts left", "early_alerts" not in obj(t), t); Fv = obj(t)["version"]
st, t = call("update_reminder", id=F["id"], version=Fv, location=None); check("location removed", st == "OK" and "location" not in obj(t), t)
st, t = call("create_reminder", title="E2E 无日期提前", list="agent test 3", early_alerts=[{"before": 5}]); check("early alerts need a due date", st == "ERR" and "due date" in t, t)
st, t = call("create_reminder", title="E2E 指派", list="agent test 3", assigned_to="me"); check("assigning needs a shared list", st == "ERR" and "not shared" in t, t)
st, t = call("create_reminder", title="E2E 坏链接", list="agent test 3", url="not a url"); check("bad url is invalid params", st == "RPCERR", t)
st, t = call("find_reminders", list="agent test 3", has_location=True); check("find by location", st == "OK" and obj(t)["count"] == 0, t)
P1 = obj(call("create_reminder", title="E2E 顺序一", list="agent test 3")[1]); P2 = obj(call("create_reminder", title="E2E 顺序二", list="agent test 3")[1])
st, t = call("update_reminder", id=P2["id"], version=P2["version"], position={"before": P1["id"]}); check("move a reminder before another", st == "OK", t)
st, t = call("update_reminder", id=P2["id"], version=obj(t)["version"], position={"after": F["id"]}); check("move after another", st == "OK", t)

# 0.3: list options, section order, clear completed, tags, templates
st, t = call("manage_list", action="update", list="agent test 3", pinned=True, type="groceries", sort="priority", color="light-blue")
L = obj(t); check("pin, groceries, sort, light blue", st == "OK" and L.get("pinned") and L.get("type") == "groceries" and L.get("sort") == "priority" and L.get("color") == "light-blue", t)
st, t = call("manage_list", action="update", list="agent test 3", pinned=False, type="standard", sort="manual", color="indigo", position={"after": "agent test"})
L = obj(t); check("unpin, standard, manual, indigo, moved", st == "OK" and not L.get("pinned") and "type" not in L and L.get("sort") == "manual" and L.get("color") == "indigo", t)
for name in ["区一", "区二", "区三"]: call("manage_section", action="create", list="agent test 3", section=name)
st, t = call("manage_section", action="move", list="agent test 3", section="区三", position={"before": "区一"})
check("move a section", st == "OK" and json.loads(t[t.find("["):])[:3] == ["区三", "区一", "区二"], t)
C1 = obj(call("create_reminder", title="E2E 已完成一", list="agent test 3", tags=["e2e旧"])[1])
call("update_reminder", id=C1["id"], version=C1["version"], completed=True)
st, t = call("list_tags"); check("list_tags counts", st == "OK" and any(x["tag"] == "e2e旧" and x["total"] == 1 and x["open"] == 0 for x in json.loads(t)), t[:300])
st, t = call("manage_tag", action="rename", tag="e2e旧", new_name="e2e新"); check("rename tag", st == "OK" and "1 reminders" in t, t)
st, t = call("find_reminders", tag="e2e新", include_completed=True); check("renamed tag found", st == "OK" and obj(t)["count"] == 1, t)
st, t = call("manage_tag", action="delete", tag="e2e新"); check("delete tag", st == "OK", t)
st, t = call("manage_tag", action="delete", tag="e2e新"); check("deleting a missing tag fails", st == "ERR", t)
st, t = call("find_reminders", list="agent test 3", include_completed=True); done = sum(1 for r in obj(t)["reminders"] if r.get("completed"))
st, t = call("manage_list", action="clear_completed", list="agent test 3"); check("clear completed", st == "OK" and done >= 1 and f"Moved {done} " in t, t)
st, t = call("find_reminders", list="agent test 3", include_completed=True); check("no completed left", not any(r.get("completed") for r in obj(t)["reminders"]), t[:200])
st, t = call("manage_template", action="create", template="agent test template", list="agent test 3"); check("save list as template", st == "OK", t)
st, t = call("list_lists"); check("template listed", any(x["name"] == "agent test template" for x in obj(t).get("templates", [])), t[:200])
st, t = call("manage_template", action="use", template="agent test template", list="agent test 4"); check("new list from template", st == "OK" and obj(t)["name"] == "agent test 4", t)
st, t = call("manage_template", action="delete", template="agent test template"); check("delete template", st == "OK", t)
st, t = call("find_reminders", list="agent test 4", include_completed=True)
for r in obj(t)["reminders"] if st == "OK" else []:
    if "parent_id" not in r: call("delete_reminder", id=r["id"], version=r["version"])
st, t = call("manage_list", action="delete", list="agent test 4", confirm_delete_reminders=True); check("delete the templated list", st == "OK", t)

# Smart lists
st, t = call("manage_smart_list", action="create", smart_list="agent test smart e2e", filters={"flagged": True})
check("create smart list", st == "OK" and obj(t)["match"] == "all" and obj(t)["filters"] == {"flagged": True}, t)
st, t = call("manage_smart_list", action="update", smart_list="agent test smart e2e", match="any", color="green", icon="🔎",
             filters={"tags": "untagged", "date": {"before": tomorrow}, "time": "none", "priorities": ["low", "medium"], "lists": {"exclude": ["agent test 3"]}, "location": "none"})
SL = obj(t)
check("update smart list", st == "OK" and SL["match"] == "any" and SL.get("color") == "green" and SL.get("icon") == "🔎"
      and SL["filters"] == {"tags": "untagged", "date": {"before": tomorrow}, "time": "none", "priorities": ["low", "medium"], "lists": {"include": [], "exclude": ["agent test 3"]}, "location": "none"}, t)
st, t = call("manage_smart_list", action="update", smart_list="agent test smart e2e", match="all"); check("change match only", st == "OK" and obj(t)["match"] == "all" and obj(t)["filters"]["tags"] == "untagged", t)
st, t = call("manage_smart_list", action="update", smart_list="agent test smart e2e", filters={"date": {"past": 2, "unit": "week"}}); check("relative past range", st == "OK" and obj(t)["filters"] == {"date": {"past": 2, "unit": "week", "include_past_due": False}}, t)
st, t = call("manage_smart_list", action="update", smart_list="agent test smart e2e", filters={"date": {"from": tomorrow, "until": day_after}, "location": "getting-in-car"})
check("date range and car filter", st == "OK" and obj(t)["filters"] == {"date": {"from": tomorrow, "until": day_after}, "location": "getting-in-car"}, t)
st, t = call("manage_smart_list", action="update", smart_list="agent test smart e2e", filters={"weather": "sunny"}); check("unknown filter is invalid params", st == "RPCERR", t)
st, t = call("manage_smart_list", action="create", smart_list="Not allowed", filters={"flagged": True}); check("guard blocks other smart list", st == "ERR" and "limited" in t, t)
st, t = call("list_lists"); check("list_lists shows smart list", any(x["name"] == "agent test smart e2e" for x in obj(t).get("smart_lists", [])), t[:200])
st, t = call("manage_smart_list", action="delete", smart_list="agent test smart e2e"); check("delete smart list", st == "OK", t)

# Recently Deleted
st, t = call("get_reminder", id=B["id"]); Bv = obj(t)["version"]
st, t = call("delete_reminder", id=B["id"], version=Bv); check("delete single", st == "OK", t)
st, t = call("list_deleted"); Dl = obj(t)
check("list_deleted shows it", st == "OK" and any(d["id"] == B["id"] and d.get("from_list") == "agent test 3" for d in Dl["deleted"]), t[:400])
st, t = call("restore_reminder", id=B["id"]); check("restore to original list", st == "OK" and "agent test 3" in t, t)
st, t = call("get_reminder", id=B["id"]); check("restored reminder readable", st == "OK" and obj(t)["list"] == "agent test 3", t)
st, t = call("create_reminder", title="E2E 恢复的子任务", parent_id=B["id"]); Bs = obj(t)
st, t = call("get_reminder", id=B["id"]); Bv = obj(t)["version"]
st, t = call("delete_reminder", id=B["id"], version=Bv); check("delete parent with subtask", st == "OK" and "恢复的子任务" in t, t)
st, t = call("restore_reminder", id=B["id"], list="agent test"); check("restore into another list", st == "OK" and "agent test" in t, t)
st, t = call("get_reminder", id=Bs["id"]); check("subtask restored under its parent", st == "OK" and obj(t).get("parent_id") == B["id"] and obj(t)["list"] == "agent test", t)
st, t = call("restore_reminder", id=B["id"]); check("restore twice fails", st == "ERR", t)

st, t = call("manage_list", action="delete", list="agent test 3"); check("delete non-empty list rejected", st == "ERR" and "confirm_delete_reminders" in t, t)
st, t = call("manage_list", action="delete", list="agent test 3", confirm_delete_reminders=True); check("delete non-empty list with confirm", st == "OK" and "Recently Deleted" in t, t)
st, t = call("list_deleted"); check("its reminders are restorable", st == "OK" and any(d["id"] == S1["id"] for d in obj(t)["deleted"]), t[:300])
st, t = call("restore_reminder", id=S1["id"]); check("restore after list is gone needs a list", st == "ERR" and "limited" in t, t)
st, t = call("restore_reminder", id=S1["id"], list="agent test"); check("restore into a named list", st == "OK", t)

st, t = call("get_reminder", id=S1["id"]); call("delete_reminder", id=S1["id"], version=obj(t)["version"])
st, t = call("get_reminder", id=B["id"]); call("delete_reminder", id=B["id"], version=obj(t)["version"])
st, t = call("create_reminder", title="E2E 第二个子任务", parent_id=A["id"]); C = obj(t)
st, t = call("get_reminder", id=A["id"]); Av = obj(t)["version"]
st, t = call("delete_reminder", id=A["id"], version=Av); check("delete parent takes subtask", st == "OK" and "第二个子任务" in t, t)
st, t = call("get_reminder", id=U["id"]); Uv = obj(t)["version"]
st, t = call("delete_reminder", id=U["id"], version=Uv); check("delete urgent", st == "OK", t)
st, t = call("manage_list", action="delete", list="agent test"); check("delete test list", st == "OK", t)
st, t = call("find_reminders", limit=500); check("open count back to baseline", st == "OK" and obj(t)["count"] == baseline_open, t[:200])
st, t = call("list_lists"); check("list count back to baseline", st == "OK" and len(obj(t)["lists"]) == baseline_lists, t[:200])

proc.stdin.close(); proc.wait(timeout=10)
err = proc.stderr.read().strip()
print("stderr:", err[:500])
print("FAILED:" if fails else "ALL PASSED", fails)
