"""Offline test: a new industry with fields is replayed with exactly the fields its builder's tool chose (issue #279;
C.newFieldIndustry and C.rebuildProposal's keepFields in mod/mpfever_1/content/mpfever_common.lua, replayNativeConstruction
in the bridge, switch MPFEVER_FIELDSKEEP).

#279 (Erik's session, 0.8.5): ErikHoffmann#1:134 built a farm; the tool made it with 12 fields, every other game's replay with 20
("modules tool {12} converted {20} seed 5/5"), then TOWN STATS DIFFER and a resynchronisation. Measured in game (autotest
farmdraw, 2026-11-13): a farm's fields are slots the engine fills itself (autofill) at slots of its own choosing on top of the
modules it is given; ConstructionEntity.autoFillSlots = false keeps the given fields exactly (10 seeds of 10: the tool's set).
  - C.newFieldIndustry: an industry with fields (only those have the "industrySize" parameter), with its fields as modules,
    added as a new one: a construction removed or replaced (an edit) never;
  - C.rebuildProposal with keepFields: such an industry's ConstructionEntity gets autoFillSlots = false, its modules kept;
    everything else unchanged; counted in C.keptFields;
  - replayNativeConstruction asks for it on both conversions (the collision pair), not for an industry edit, switch
    MPFEVER_FIELDSKEEP=0 (as before), and says it in the log.
Needs lupa (pip install lupa). Run: python tests/test_fieldskeep086.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
newf = re.search(r"^function C\.newFieldIndustry\(.*?^end\n", common, re.S | re.M).group(0)
rebuild = re.search(r"^function C\.rebuildProposal\(.*?^end\n", common, re.S | re.M).group(0)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
C = {}
local function plainf(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = plainf(v) end return o end
plain = plainf
function entityList(l) local o = {} for i, v in ipairs(l or {}) do o[i] = v end return o end
function baseName(f) return tostring(f) end
function C.newOf(kind) return { kind = kind } end
api = { engine = { util = { getPlayer = function() return 7 end } } }
''' + newf + rebuild)
L.execute('''
FARM = { fileName = "::/industries/farm/farm.con", params = { seed = 5, industrySize = 0, modules = { [2] = {}, [3] = {} } }, transf = {} }
FACTORY = { fileName = "::/industries/saw_mill/saw_mill.con", params = { seed = 2, modules = { [1] = {} } }, transf = {} }
STATION = { fileName = "::/stations/rail/modular_station/modular_station.con", params = { seed = 1, modules = { [3400005] = {} } }, transf = {} }
''')
f = L.eval("C.newFieldIndustry")
check(f(L.eval("FARM.fileName"), L.eval("FARM.params"), L.eval("{ toAdd = { FARM } }")) is True, "a new farm with its fields as modules: kept")
check(f(L.eval("FACTORY.fileName"), L.eval("FACTORY.params"), L.eval("{}")) is False, "an industry without fields (no industrySize): never")
check(f(L.eval("STATION.fileName"), L.eval("{ seed = 1, industrySize = 0, modules = { [1] = {} } }"), L.eval("{}")) is False, "outside industries/: never")
check(f(L.eval("FARM.fileName"), L.eval("FARM.params"), L.eval("{ toRemove = { 12345 } }")) is False, "a construction removed (an edit): never")
check(f(L.eval("FARM.fileName"), L.eval("FARM.params"), L.eval("{ old2newByRank = { [0] = 0 } }")) is False, "a construction replaced (a road through a farm): never")
check(f(L.eval("FARM.fileName"), L.eval("{ seed = 5, industrySize = 0, modules = {} }"), L.eval("{}")) is False, "no field given: autofill left to the engine")

L.execute('''
M = { toAdd = { FARM, STATION }, proposal = {} }
C.keptFields = 0
SP = C.rebuildProposal(M, { noStreet = true, seed = 7919, keepFields = true })
K1 = C.keptFields
SP0 = C.rebuildProposal(M, { noStreet = true, seed = 7919 })
''')
check(L.eval("SP.constructionsToAdd[1].autoFillSlots") is False, "keepFields: the new farm's autofill off")
check(L.eval("SP.constructionsToAdd[1].params.modules[2] ~= nil and SP.constructionsToAdd[1].params.modules[3] ~= nil") is True, "  its fields kept as modules")
check(L.eval("SP.constructionsToAdd[1].params.seed") == 5, "  its seed kept")
check(L.eval("SP.constructionsToAdd[2].autoFillSlots") is None, "  the station beside it untouched")
check(L.eval("K1") == 1, "  counted (C.keptFields)")
check(L.eval("SP0.constructionsToAdd[1].autoFillSlots") is None, "without keepFields: the engine's autofill, as before")

r = bridge[bridge.index("local function replayNativeConstruction(a)"):]
r = r[:r.index("\nlocal function ", 10)]
check('local keepFields = os.getenv("MPFEVER_FIELDSKEEP") ~= "0" and not a.industryEdit' in r, "replayNativeConstruction: switch MPFEVER_FIELDSKEEP=0, never for an industry edit")
check(r.count("keepFields = keepFields }") == 2, "  both conversions of the collision pair")
check("keeps the tool's fields (autofill off, #279)" in r, "  said in the log")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
