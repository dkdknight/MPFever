"""Offline test of the lobby's warning for a savegame played with one company per player, hosted with one company for
everybody (0.6.8, issue #115).

A host started such a savegame with one company for everybody: the other player found "my company is gone", its company
tab locked and its unlocked buildings unusable; they needed 50 minutes to find out why. MPFever.exe now tells it from the
savegame (the companies' registry, mode = "separate", see mpfever_co.lua) and says so in its log and in the lobby.

Cases:
  - the bytes SaveInfo.cs looks for are the game's serialization of the registry's mode = "separate" entry;
  - they are found in a decompressed state with that entry, not in one with mode = "shared" or none;
  - MainForm.cs reads it with the savegame's options in the "one company for everybody" lobby, says it in its log and
    sends saveSeparate to the menu (never in the other mode); MPFEVER_SAVEMODE=0 switches it off;
  - the menu shows the warning in the host's lobby.
Run: python tests/test_savemode.py
"""
import os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
SAVEINFO = os.path.join(ROOT, "launcher", "SaveInfo.cs")
FORM = os.path.join(ROOT, "launcher", "MainForm.cs")
MENU = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_menu.lua")

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def lua_str(s):
    # the game's serialization of a string value: its type (3), its length, its bytes
    b = s.encode("utf-8")
    return struct.pack("<ii", 3, len(b)) + b


def main():
    src = open(SAVEINFO, encoding="utf-8").read()
    m = re.search(r"SeparateEntry = \{(.*?)\};", src, re.S)
    check("SaveInfo.cs has the registry's mode entry", m is not None)
    if not m:
        return 1
    items = [x.strip() for x in m.group(1).replace("\n", " ").split(",") if x.strip()]
    entry = bytes(ord(x[-2]) if x.startswith("(byte)'") else int(x) for x in items)
    check("the bytes are the serialization of mode = \"separate\"", entry == lua_str("mode") + lua_str("separate"), entry)

    state = b"\x04\x00\x00\x00" + lua_str("canon") + struct.pack("<id", 2, 31434.0) + lua_str("mode") + lua_str("separate") + lua_str("start")
    check("found in a state with the entry", state.find(entry) >= 0)
    check("not in one with mode = \"shared\"", (lua_str("mode") + lua_str("shared")).find(entry) < 0)
    check("SeparateOf is what the lobby reads", "Separate = SeparateOf(d)" in src)

    form = open(FORM, encoding="utf-8").read()
    check("the lobby of one company for everybody reads it with the savegame's options", "if (optsHere && (!SaveOptsOff || modeCheck))" in form)
    check("MPFEVER_SAVEMODE=0 switches it off", 'GetEnvironmentVariable("MPFEVER_SAVEMODE") != "0"' in form)
    check("the host is told in the log", "This savegame was played with one company per player" in form)
    check("the menu is told, in that mode only", '["saveSeparate"] = lobbyOpen && lobbySaveSeparate && companyMode != "separate"' in form)
    check("a new lobby starts without it", "lobbyStarting = false; lobbySaveSeparate = false;" in form)

    menu = open(MENU, encoding="utf-8").read()
    check("the menu shows the warning in the host's lobby", 'if isHost and st.saveSeparate == "1" then' in menu)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
