"""Offline test of the names part with the simulation's two copies of its script (0.7.0; the test nd1 of 2026-11-05, names_dump.txt:
the same entities on both games, but a station "seen at the previous check" on one game and not on the other, every other check).

The simulation's script runs in two copies that take the steps in turn, each with its own copy of mpfever_refs.lua: the module
variable R.namesSeen held, on every other check, what the check before the last one saw. Two games not on the same copy at the
same check then differed by what was made between those checks. What was seen is now kept in the game script's state
(R.namesStore, which the bridge sets to the simulation's state for the check), shared by both copies.
Cases: two games, each with two copies of the module taking the checks in turn, not in the same phase, a station built between two
checks: with the state, every check equal; MPFEVER_NAMESSTATE=0 (the module variable, as before): a check differs.
Run: python tests/test_namesstate.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_namefresh import MOCK, CHECK, REFS  # noqa: E402

WORLD = r'''
KIND = { [10] = "STATION_GROUP", [20] = "LINE", [30] = "TRANSPORT_VEHICLE" }
NAMES = { [10] = "Halle", [20] = "Linie 1", [30] = "Bus 1" }
'''


def game(src, env):
    """one game: its world, its script state ST, and two copies of the refs module (A and B)"""
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    for k, v in env.items():
        L.execute(f'ENV.{k} = "{v}"')
    L.execute(WORLD)
    g = L.globals()
    g.RA = L.execute(src)
    g.RB = L.execute(src)
    L.execute("ST = {}")
    run = L.eval("function(code) local f = assert(load(code)) return f() end")

    def check_with(copy):
        return run(f"R = {copy}; R.namesStore = ST; local r = (function() {CHECK} end)(); R.namesStore = nil; return r")

    run("R = RA; R.namesStore = ST; R.nameSeed(true); R.namesStore = nil")
    run("R = RB; R.namesStore = ST; R.nameSeed(true); R.namesStore = nil")
    return run, check_with


def session(env):
    src = open(REFS, encoding="utf-8").read()
    h_run, h_check = game(src, env)
    o_run, o_check = game(src, env)
    out = []
    for k in range(6):
        if k == 2:
            for r in (h_run, o_run):
                r('KIND[11] = "STATION_GROUP"; NAMES[11] = "Halle Nord"')
        # (which copy takes a check follows the steps: on the host A, B, A, B..., on the other game A, A, B, B...)
        hc = "RA" if k % 2 == 0 else "RB"
        oc = "RA" if (k // 2) % 2 == 0 else "RB"
        out.append((h_check(hc), o_check(oc)))
    return out


def main():
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
        if not cond:
            fails.append(name)

    res = session({})
    check("with the state: every check equal on both games", all(a == b for a, b in res), res)
    check("and the new station counted from the check after the one that first saw it", res[2][0].startswith("3/") and res[3][0].startswith("4/"), res)
    res0 = session({"MPFEVER_NAMESSTATE": "0"})
    check("MPFEVER_NAMESSTATE=0 (the module variable, as before): a check differs", any(a != b for a, b in res0), res0)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
