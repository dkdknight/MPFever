"""Offline test of which released build a captured one is shipped as (0.6.10, the shipping of G.natShipIds in the bridge).

Test dt1 of 2026-11-03 (one company per player, two computer companies): the host's test road (100004) and a computer company's
stop (100005) were released for the same time. The engine refused the road; the stop was captured and paired with the first
entry of that time, the road's: it was shipped as the host's company's build, its cost and refund booked on company 1 on the
other game (money apart, then the rest). The capture now names the company the build is for (o.oco, from its owner
references), and the entry of that company is taken; the other entries of that time wait for their own capture. The block is
taken from the real bridge and run through lupa (Lua 5.2) with mocks. Cases:
  - the road (the player's, company 1) then the stop (computer company 5) for one time, the stop's capture: shipped as 100005,
    for company 5; the road's entry kept (it expires by itself), not cancelled;
  - a capture without a company named, MPFEVER_SHIPCO=0: the first entry, the others before it cancelled, as before;
  - entries of an earlier time: cancelled ("refused before a later build"), as before;
  - the capture records the company named (oco).
Run: python tests/test_shipco.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"\n(\t+local k = nil\n\t+-- \(0\.6\.10\) several released for this time.*?\n\t+G\.natShipIds = rest\n)", src, re.S)
    if not m:
        print("FAIL: the shipping block not found in the bridge")
        return 1
    block = m.group(1)
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
CANCELLED = {}
cancelNativeBuild = function(e, why) CANCELLED[#CANCELLED + 1] = e.id end
STEP = 200
function SHIP(o, ids, aiNatCo, myCo)
  G = { natShipIds = ids, aiNatCo = aiNatCo, myCo = myCo, pt = { of = {} }, ptKey = function() return 1 end, leadStats = { shipped = 0 }, frames = 0, me = "Host" }
  local a = { co = myCo }
  CANCELLED = {}
""" + block + """
  return a
end
""")
    run = L.eval("function(code) return assert(load(code))() end")

    run("A = SHIP({ at = 25732400, oco = 5 }, { { id = 100004, at = 25732400, frame = 0 }, { id = 100005, at = 25732400, frame = 0 } }, { [100005] = 5 }, 1)")
    check("the computer company's stop: shipped as its own entry (100005)", run("return A.natId") == 100005)
    check("for company 5", run("return A.co") == 5)
    check("the road's entry of the same time kept, not cancelled", run("return #CANCELLED") == 0 and run("return #G.natShipIds") == 1
          and run("return G.natShipIds[1].id") == 100004)

    run("A = SHIP({ at = 25732400, oco = 1 }, { { id = 100004, at = 25732400, frame = 0 }, { id = 100005, at = 25732400, frame = 0 } }, { [100005] = 5 }, 1)")
    check("the player's own build: its entry, the computer company's kept",
          run("return A.natId") == 100004 and run("return A.co") == 1 and run("return G.natShipIds[1].id") == 100005)

    run("A = SHIP({ at = 25732400 }, { { id = 100004, at = 25732400, frame = 0 }, { id = 100005, at = 25732400, frame = 0 } }, { [100005] = 5 }, 1)")
    check("no company named: the first entry, as before", run("return A.natId") == 100004)
    run("ENV.MPFEVER_SHIPCO = '0'; A = SHIP({ at = 25732400, oco = 5 }, { { id = 100004, at = 25732400, frame = 0 }, { id = 100005, at = 25732400, frame = 0 } }, { [100005] = 5 }, 1); ENV.MPFEVER_SHIPCO = nil")
    check("MPFEVER_SHIPCO=0: the first entry, as before", run("return A.natId") == 100004 and run("return A.co") == 1)

    run("A = SHIP({ at = 25732400, oco = 5 }, { { id = 100002, at = 25728800, frame = 0 }, { id = 100005, at = 25732400, frame = 0 } }, { [100005] = 5 }, 1)")
    check("an entry of an earlier time: cancelled, as before", run("return A.natId") == 100005 and run("return CANCELLED[1]") == 100002
          and run("return #G.natShipIds") == 0)

    check("the capture records the company named", "ts = tstats, oco = ownerCo }" in src and "if #parts == 1 then ownerCo = next(tally) end" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
