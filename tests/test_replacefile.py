"""Offline test of a construction's edit into another file (0.6.13).

An edit sent by a window replaces a construction through the engine (createProposalReplaceConstruction(old, params)) on
every game. Advanced Station Configuration Tool widens a station into another file, Simply Relocate turns a building into
its stand-in: the replay gave the old file with the new settings, the station was not widened and Simply Relocate's move
stopped halfway. The new file now goes as the third argument when it differs from the construction's own.

G.replaceNewFile is taken from the real bridge file and run through lupa (Lua 5.2) with a mocked engine. Cases: the same
file: nil (the call as before); another file: that file; the same file written with a mod prefix or a leading slash: nil;
MPFEVER_REPLACEFILE=0: nil; a construction the engine does not know: nil. The edit's replay passes it on (read in the
bridge's source).
Run: python tests/test_replacefile.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
G = {}
CONS = { [10] = { fileName = "station/rail/modular_station/modular_station.con" } }
api = { engine = { getComponent = function(e) return CONS[e] end }, type = { ComponentType = { CONSTRUCTION = 1 } } }
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^G\.replaceNewFile = function\(old, newFile\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: G.replaceNewFile not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0))
    ev = L.eval("function(code) local f = assert(load(code)) return f() end")
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    got = ev("return G.replaceNewFile(10, 'station/rail/modular_station/modular_station.con')")
    check("the same file: no third argument (as before)", got is None, got)
    got = ev("return G.replaceNewFile(10, 'station/rail/modular_station_wide/modular_station_wide.con')")
    check("another file (a widened station): that file", got == "station/rail/modular_station_wide/modular_station_wide.con", got)
    got = ev("return G.replaceNewFile(10, 'base::/station/rail/modular_station/modular_station.con')")
    check("the same file with a prefix: no third argument", got is None, got)
    got = ev("return G.replaceNewFile(10, '/station/rail/modular_station/modular_station.con')")
    check("the same file with a leading slash: no third argument", got is None, got)
    got = ev("return G.replaceNewFile(99, 'x.con')")
    check("a construction the engine does not know: no third argument", got is None, got)
    got = ev("ENV = { MPFEVER_REPLACEFILE = '0' } return G.replaceNewFile(10, 'other.con')")
    check("MPFEVER_REPLACEFILE=0: as before", got is None, got)
    call = re.search(r"local newFile = G\.replaceNewFile\(e1\.toRemove\[1\], e1\.toAdd\[1\]\.fileName\).*?createProposalReplaceConstruction\(e1\.toRemove\[1\], C\.plain\(e1\.toAdd\[1\]\.params\), newFile\)", src, re.S)
    check("the window edit's replay passes the new file to the engine", call is not None)

    print("PASS" if not fails else f"FAIL ({len(fails)})")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
