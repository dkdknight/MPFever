"""Offline test: the other companies' lines at this company's stations, on demand (0.8.3, Zoey's suggestion, MPFEVER_OTHERLINES).

"A stop's window showing the other players' lines that use it", the owner's choice: seen when the player wants (a button), never
in normal play, one company per player only. This company's sheet (the Company tab) has a section with a "Show" button, closed by
default; open, it lists for each of this company's stations the lines of other companies that stop there (company, vehicles,
a button that takes the camera to the station). Read in the interface only: nothing any game computes changes.
U.otherLinesAtMine is taken from the real interface script and run through lupa (Lua 5.2) with a mocked engine.
Run: python tests/test_otherlines083.py
"""
import os
import re
import sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(UI, encoding="utf-8").read().replace("\r\n", "\n")
m = re.search(r"^U\.otherLinesAtMine = function\(companies, label\)\n.*?^end\n", src, re.S | re.M)
if not m:
    print("FAIL: U.otherLinesAtMine not found")
    sys.exit(1)
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
CLOCK = 0
os.clock = function() return CLOCK end
U = { myCo = 1 }
NAMES = { [10] = "Hbf", [11] = "Markt", [12] = "Other's station", [401] = "My bus", [501] = "Their bus", [502] = "Their tram", [503] = "Their truck" }
OWNER = { [10] = 100, [11] = 100, [12] = 200 }
LINES = { [100] = { 401 }, [200] = { 501, 502, 503 } }
STOPS = { [10] = { { 401, 0 }, { 501, 2 }, { 501, 3 } }, [11] = { { 503, 1 } }, [12] = { { 502, 0 } } }
R = { entitiesWith = function(k) return { 10, 11, 12 } end, ownerOf = function(e) return OWNER[e] end }
api = { type = { ComponentType = { NAME = "name" } },
  engine = { getComponent = function(e, ct) return { name = NAMES[e] } end,
    system = { lineSystem = { getLinesForPlayer = function(p) return LINES[p] or {} end, getLineStops = function(sg) return STOPS[sg] or {} end },
      transportVehicleSystem = { getLineVehicles = function(l) return l == 501 and { 1, 2, 3 } or {} end } } } }
""" + m.group(0))
run = L.eval("function(code) return assert(load(code))() end")
rows = run("""local r = U.otherLinesAtMine({ { id = 1, ent = 100, name = "Mine" }, { id = 2, ent = 200, name = "Theirs" } },
  function(c) return c.name end)
local out = {} for _, x in ipairs(r) do out[#out + 1] = x.sgName .. "|" .. x.lineName .. "|" .. x.co .. "|" .. x.nv end return table.concat(out, ";")""")
check("this company's stations: the other company's lines stopping there, once each, by station",
      rows == "Hbf|Their bus|Theirs|3;Markt|Their truck|Theirs|0", rows)
check("  not this company's own lines, nor the other company's stations", "My bus" not in rows and "Their tram" not in rows)
run("STOPS[10][#STOPS[10] + 1] = { 502, 1 }")
check("read again only after 5 s (cached)", run("return #U.otherLinesAtMine({ { id = 1, ent = 100 }, { id = 2, ent = 200 } })") == 2)
run("CLOCK = 6")
check("  then again", run("return #U.otherLinesAtMine({ { id = 1, ent = 100 }, { id = 2, ent = 200 } })") == 3)

sec = src[src.index("-- (0.8.3) the other companies' lines at this company's stations, on demand"):]
sec = sec[:sec.index("local nPl = #names")]
check("the section: one company per player only (another company in the list), MPFEVER_OTHERLINES=0 none",
      'if os.getenv("MPFEVER_OTHERLINES") ~= "0" and #list > 1 then' in sec)
check("  closed by default: the lines read only once opened (normal play shows nothing)",
      "if U.otherLinesOpen then" in sec and sec.index("if U.otherLinesOpen then") < sec.index("pcall(U.otherLinesAtMine, list, label)"))
check("  a Show / Hide button", 'U.otherLinesOpen and T("Masquer", "Hide") or T("Voir", "Show")' in sec)
check("  in this company's own sheet only (elseif isMine)", src.count("-- (0.8.3) the other companies' lines at this company's stations, on demand") == 1
      and "\t\telseif isMine then\n\t\t\t-- (0.8.3) the other companies' lines" in src)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
