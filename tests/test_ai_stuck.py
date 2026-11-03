"""Offline test of the computer companies' vehicles that never take their line (0.6.11, issue #122).

Issue #122 (one company per player, two computer companies, a new map): no garage of their own could be built, and the
companies bought their buses in the host's garage, 3 km away. None of them ever took its line ("vehicle 2825 still without a
line", sent again and again), and as a line's fleet counts the vehicles on it, each look bought one more: 8 buses each in
7 minutes, the companies' money spent on buses standing in a depot. Now:
  - no bus or truck is bought while one of the company's vehicles waits for its line in a depot that reaches the streets;
  - a vehicle sent to its line 3 times that never took it is sold, and that depot is no longer used for that line's purchases
    (in the test on #122's map, a company's own garage could not reach one of its lines, between two other towns: its other
    lines still get their vehicles there);
  - MPFEVER_AISTUCK=0: as before.
mpfever_ai.lua through lupa with the mocked game of ai_mock.py.
Run: python tests/test_ai_stuck.py
"""
import os, re, sys

try:
    import lupa  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ai_mock import load, checker  # noqa: E402


def main():
    check, failures = checker()
    L, M = load()
    run = L.eval("function(code) return assert(load(code))() end")
    run("""
      MONEY[CO1.ent] = 5000000
      addGarage(800, 900, 0, 0)
      G.AI = {}
    """)
    co = L.eval("CO1")

    # a vehicle of the company waiting for its line in depot 900 (the mock's depot of every vehicle)
    run("VEH[#VEH + 1] = 51; OWN[51] = CO1.ent; VLINE[51] = -1")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is False and L.eval("acts('makeVehicleBuyCmd')") == 0, "no bus bought while a vehicle waits for its line")
    check(L.eval("logHas('no bus bought while vehicle 51 waits for its line')"), "and it says so")
    run("LOG = {}")
    M.f.buyBus(L.eval("E"), co, 900)
    check(not L.eval("logHas('waits for its line')"), "said once for the same vehicle")

    # the vehicle took its line: the next purchase goes
    run("VLINE[51] = 77")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is True and L.eval("acts('makeVehicleBuyCmd')") == 1, "bought once no vehicle waits")

    # a vehicle without a line in a depot that does not reach the streets does not hold the purchases (never sent to a line)
    run("G.AI = {}; VLINE[51] = -1; setComp(900, 'VEHICLE_DEPOT', { outNodes = {} })")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is True and L.eval("acts('makeVehicleBuyCmd')") == 2, "a vehicle in a depot cut off from the streets does not hold them")
    run("setComp(900, 'VEHICLE_DEPOT', { outNodes = { 1 } })")

    # MPFEVER_AISTUCK=0: bought, as before
    run("G.AI = {}; ENV.MPFEVER_AISTUCK = '0'")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is True and L.eval("acts('makeVehicleBuyCmd')") == 3, "MPFEVER_AISTUCK=0: bought while a vehicle waits, as before")
    run("ENV.MPFEVER_AISTUCK = nil")

    # a depot whose vehicle never took a line: no purchase there for that line, the others still bought there
    run("G.AI = { badDepot = { ['900:77'] = true }, forLine = 77 }; VLINE[51] = 66; LOG = {}")
    n0 = L.eval("acts('makeVehicleBuyCmd')")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is False and L.eval("acts('makeVehicleBuyCmd')") == n0, "no bus bought at that depot for that line")
    check(L.eval("logHas('no bus bought at depot 900 for line 77')"), "and it says so")
    run("G.AI.forLine = 66")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is True and L.eval("acts('makeVehicleBuyCmd')") == n0 + 1, "bought there for another line")
    run("G.AI = { badDepot = { ['900:77'] = true }, forLine = 77 }; ENV.MPFEVER_AISTUCK = '0'")
    r = M.f.buyBus(L.eval("E"), co, 900)
    check(r is True and L.eval("acts('makeVehicleBuyCmd')") == n0 + 2, "MPFEVER_AISTUCK=0: bought there, as before")
    run("ENV.MPFEVER_AISTUCK = nil")
    run("G.AI = {}; G.AIT = {}")
    got = L.eval("#M.f.garagesNear(E, CO1.ent, { x = 10, y = 10 }, 5000)")
    check(got == 1, f"the garage near is still offered ({got})")

    # the vehicles' loop of step: sold after 3 sends, its depot left
    src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ai.lua"), encoding="utf-8").read()
    m = re.search(r'if os\.getenv\("MPFEVER_AISTUCK"\) ~= "0" and \(A\.lineTries\[v\.e\] or 0\) >= 3 then\n(.*?)\n\t+end\n\t+A\.lineTries\[v\.e\] = \(A\.lineTries\[v\.e\] or 0\) \+ 1', src, re.S)
    check(m is not None, "the vehicles' loop counts each send to the line")
    body = m.group(1) if m else ""
    check('A.badDepot[tostring(vdepot) .. ":" .. tostring(tl)] = true' in body and "sellVehicle(E, co, v.e," in body, "after 3 sends: sold, that depot left for that line")
    check("A.lineTarget[v.e] = target" in src, "each send remembers its line")
    check("getFailedPathReason" in body, "and the engine's reason logged")
    check("if type(A.lineTries) == \"table\" then for k in pairs(A.lineTries) do if not liveV[k] then A.lineTries[k] = nil end end end" in src,
          "the count of a vehicle gone is dropped (a new vehicle may take its id)")

    print("\nPASS" if not failures else f"\nFAIL ({len(failures)})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
