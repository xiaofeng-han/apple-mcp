"""Writes the linker stubs for Apple Journal MCP's calls into Journal's private frameworks.

JournalComponent calls JournalShared and Coherence through Swift interfaces written by hand
(Interfaces/Journal/*.swiftinterface). The linker reads Interfaces/Journal/*.tbd in their place: a
list of the symbols the component uses, all of which the frameworks on this Mac export. The
component also checks, as it starts, that each one is there (Sources/JournalComponent/Store/
Symbols.swift), so a macOS that changed them is reported instead of crashing. Run this after
changing an interface or the calls into it, on a Mac with the macOS the app is meant for:

    /usr/bin/python3 -I scripts/journal-stubs.py

It compiles JournalComponent (without linking), reads the symbols its objects need, and keeps the
ones the two frameworks export. A symbol used but not exported is printed, and nothing is written:
the interface is wrong there.
"""
import glob, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMEWORKS = {
    "JournalShared": ("/System/Library/PrivateFrameworks/JournalShared.framework/Versions/A/JournalShared", 113),
    "Coherence": ("/System/Library/PrivateFrameworks/Coherence.framework/Versions/A/Coherence", 1),
}


def exports(path):
    out = subprocess.run(["dyld_info", "-exports", path], capture_output=True, text=True, check=True).stdout
    return {line.split()[-1] for line in out.splitlines() if line.strip().startswith("0x")}


def needed():
    subprocess.run(["swift", "build", "--target", "JournalComponent"], cwd=ROOT, check=True)
    # Where the objects are depends on SwiftPM's build system.
    objects = glob.glob(os.path.join(ROOT, ".build", "debug", "JournalComponent.build", "*.o")) + glob.glob(
        os.path.join(ROOT, ".build", "out", "Intermediates.noindex", "*", "Debug", "JournalComponent-*.build", "Objects-normal", "*", "*.o"))
    if not objects:
        sys.exit("No objects of JournalComponent found under .build")
    def symbols(*flags):
        out = subprocess.run(["nm", *flags, "-j", *objects], capture_output=True, text=True, check=True).stdout
        return {line.strip() for line in out.splitlines() if line.strip().startswith("_$s")}
    # One object's calls into another of the component are not the frameworks'.
    return symbols("-u") - symbols("-U")


def tbd(name, path, version, symbols):
    quoted = ",\n".join(f"                       '{symbol}'" for symbol in sorted(symbols))
    return f"""--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-macos, arm64e-macos ]
install-name:    '{path}'
current-version: {version}
swift-abi-version: 7
exports:
  - targets:         [ arm64-macos, arm64e-macos ]
    symbols:         [
{quoted} ]
...
"""


def main():
    used = needed()
    found = {name: exports(path) & used for name, (path, _) in FRAMEWORKS.items()}
    own = set().union(*found.values())
    missing = sorted(symbol for symbol in used if symbol not in own and ("JournalShared" in symbol or "Coherence" in symbol))
    if missing:
        print("Used but not exported by JournalShared or Coherence (check the interface):", *missing, sep="\n  ")
        sys.exit(1)
    for name, (path, version) in FRAMEWORKS.items():
        with open(os.path.join(ROOT, "Interfaces", "Journal", name + ".tbd"), "w") as f:
            f.write(tbd(name, path, version, found[name]))
    names = sorted(symbol[1:] for symbol in own)  # without the leading underscore, as dlsym takes them
    lines = "\n".join(f'        "{symbol}",' for symbol in names)
    with open(os.path.join(ROOT, "Sources", "JournalComponent", "Store", "Symbols.swift"), "w") as f:
        f.write(f"""// Written by scripts/journal-stubs.py; do not edit.

/// Every symbol of JournalShared and Coherence that Apple Journal MCP calls. They are weakly
/// linked, so where macOS no longer has one of them the app still starts, and JournalStore reports
/// it instead of calling it.
enum JournalSymbols {{
    static let all = [
{lines}
    ]
}}
""")
    print(f"{len(found['JournalShared'])} JournalShared and {len(found['Coherence'])} Coherence symbols")


main()
