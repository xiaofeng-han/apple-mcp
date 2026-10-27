"""End-to-end checks of one app, against the real Notes or Reminders data and with the app's own
permissions. Not run on CI (see .github/workflows/check.yml); run them on a Mac before a release:

    /usr/bin/python3 -I scripts/e2e.py notes [path to the AppleNotesMCP executable]
    /usr/bin/python3 -I scripts/e2e.py reminders [path to the AppleRemindersMCP executable]

Without a path, each checks the installed app. The checks themselves are scripts/e2e/notes.py and
scripts/e2e/reminders.py, which say what they change and how they keep away from the user's data;
what they share, and the checks of the shared base, are in scripts/e2e/harness.py.
"""
import os, sys

APPS = ("notes", "reminders")
if len(sys.argv) < 2 or sys.argv[1] not in APPS:
    sys.exit("usage: scripts/e2e.py notes|reminders [EXECUTABLE]")
script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "e2e", sys.argv[1] + ".py")
os.execv(sys.executable, [sys.executable, "-I", script] + sys.argv[2:])
