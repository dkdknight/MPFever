"""Offline test: MPFever unpacked inside the game's folder moves the old copies of its mod out of the game (0.9.1, #427,
MPFEVER_OLDCOPIESOUT).

Report #427 (2026-11-18): the player had unpacked MPFever into Transport Fever 3\\mods\\MPFever. The launcher moves another copy of
its mod found in the game's mods folder into old-mod-copies, next to MPFever.exe (0.7.9, #136): there, that folder was itself in
the game's mods folder, so at every start the launcher found the copies it had moved there and moved them again, and the game, which
looks into the mods folder's subfolders (#136: "mods/release/MPFever/mod/mpfever_1/ has been selected"), could take one of them.
The fix: when MPFever's folder is inside the game's, the copies go to the user's own MPFever folder
(%LOCALAPPDATA%\\MPFever\\old-mod-copies), and the launcher says once at the start that MPFever should be in a folder of its own.
Part 1 replays the launcher's search (ModCopies.Stale: mpfever_1 folders under the game's mods folder, five levels down, a mod's
own content not looked into) on a model of the player's folders, with the old and the new place; part 2 checks the launcher's
wiring and that its self-test (SelfTest.RunOldCopiesOut091, run by run_all with MPFever.exe --selftest) runs the real code.
Run: python tests/test_oldcopies427.py
"""
import os, sys, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def mod(d, bridge):
    os.makedirs(os.path.join(d, "content"), exist_ok=True)
    open(os.path.join(d, "mod.json"), "w").write('{"modId": "mpfever_1"}')
    open(os.path.join(d, "content", "mpfever_bridge.script.lua"), "w").write(bridge)


def stale(game, src):
    """ModCopies.Stale's search (the mods folder only): the mpfever_1 folders that are not this MPFever's own and differ."""
    found = []

    def walk(d, depth):
        if depth > 5:
            return
        try:
            subs = [os.path.join(d, x) for x in os.listdir(d) if os.path.isdir(os.path.join(d, x))]
        except OSError:
            return
        for s in subs:
            if os.path.basename(s).lower() == "mpfever_1" and os.path.isfile(os.path.join(s, "mod.json")):
                found.append(s)
                continue
            if os.path.isfile(os.path.join(s, "mod.json")) or os.path.isfile(os.path.join(s, "mod.lua")):
                continue
            walk(s, depth + 1)
    walk(os.path.join(game, "mods"), 0)
    mine = os.path.normcase(os.path.abspath(src))
    same = lambda d: open(os.path.join(d, "content", "mpfever_bridge.script.lua")).read() == open(os.path.join(src, "content", "mpfever_bridge.script.lua")).read()
    return [d for d in found if os.path.normcase(os.path.abspath(d)) != mine and not same(d)]


def inside(d, game):
    n = lambda p: os.path.normcase(os.path.abspath(p)).rstrip("\\/") + os.sep
    return n(d).startswith(n(game))


def old_copies_dir(base, game, outside, fixed):
    return os.path.join(outside, "old-mod-copies") if fixed and inside(base, game) else os.path.join(base, "old-mod-copies")


def move_aside(copy, into, k):
    dst = os.path.join(into, "20261118-1930", str(k), "mpfever_1")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.move(copy, dst)
    return dst


def model():
    for fixed in (False, True):
        root = tempfile.mkdtemp(prefix="mpf427-")
        try:
            game = os.path.join(root, "Transport Fever 3")
            mp = os.path.join(game, "mods", "MPFever")
            src = os.path.join(mp, "mod", "mpfever_1")
            mod(src, "-- bridge 0.9.1")
            mod(os.path.join(game, "mods", "release", "mpfever_1"), "-- bridge 0.8.17")
            outside = os.path.join(root, "LocalAppData", "MPFever")
            moves = 0
            for start in range(3):             # three starts of MPFever
                for k, c in enumerate(stale(game, src)):
                    move_aside(c, old_copies_dir(mp, game, outside, fixed), start * 10 + k)
                    moves += 1
            left = stale(game, src)
            if not fixed:
                check("before (the report): the copy moved again at every start (3 starts, 3 moves), still in the game's mods folder",
                      moves == 3 and len(left) == 1 and inside(left[0], game), (moves, left))
            else:
                check("after: moved once, out of the game; none found at the next starts", moves == 1 and not left, (moves, left))
                check("  where the user keeps MPFever's own files", os.path.isdir(os.path.join(outside, "old-mod-copies")))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    check("a folder whose name only begins like the game's is not inside it",
          not inside(r"C:\Games\Transport Fever 3 copy\MPFever", r"C:\Games\Transport Fever 3") and inside(r"C:\Games\Transport Fever 3\mods\MPFever", r"C:\Games\Transport Fever 3"))


def wiring():
    mc = open(os.path.join(ROOT, "launcher", "ModCopies.cs"), encoding="utf-8-sig").read()
    check("ModCopies.OldCopiesDir: out of the game when MPFever is inside it, next to MPFever.exe otherwise, MPFEVER_OLDCOPIESOUT=0: as before",
          "public static string OldCopiesDir(string baseDir, string gameDir, string outsideRoot = null)" in mc
          and 'GetEnvironmentVariable("MPFEVER_OLDCOPIESOUT") == "0" || !InsideGame(baseDir, gameDir)) return here;' in mc
          and "Environment.SpecialFolder.LocalApplicationData" in mc)
    check("the copies are moved there (OfferStaleMods)",
          "ModCopies.MoveAside(c, ModCopies.OldCopiesDir(AppDomain.CurrentDomain.BaseDirectory, gameDir));" in mc
          and 'Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "old-mod-copies")' not in mc)
    check("said once at the start, in both languages (FindStaleMods)",
          "MPFever est installé dans le dossier du jeu" in mc and "MPFever is installed inside the game's folder" in mc)
    st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
    check("the launcher's self-test runs the real code on the player's folders (the bug with the switch, then the fix)",
          "ok &= RunOldCopiesOut091();" in st and "static bool RunOldCopiesOut091()" in st and 'SetEnvironmentVariable("MPFEVER_OLDCOPIESOUT", "0")' in st)


def main():
    model()
    wiring()
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
