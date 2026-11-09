"""Offline test of the persons' digest of the checks and of the persons in the dump after a difference (0.7.13, issues #150/#166:
R.personsDigest and the part "personsDigest" in mod/mpfever_1/content/mpfever_refs.lua, R.hashCheckN and extendedParts in
mpfever_bridge.script.lua, DiagnosticParts / NeverLocalParts in launcher/MainForm.cs).

#150 and #166 drifted with no action, one to six game minutes after a load: the money (fares) first, then the passengers on
board and the stocks, then the towns' happiness (script:towns, which the engine computes from the persons), then a vehicle. The
check's part "persons" is their number alone, and the dump had the persons only with a test switch (MPFEVER_SDUMP_PERSONS=1):
no report showed which person went otherwise first. Now:
  - the part "personsDigest": one person in eight, those whose id leaves the check number's remainder (R.hashCheckN, given by
    simHash), each by its id, where it is (in a vehicle with its line and stops, at a terminal, moving, in a building, idle, as
    the dump's ~person lines read it) and where it goes (targetOrAtEntity, lastDestinationUpdate), summed in any order;
    mpfever_refs.lua is run through lupa (Lua 5.2) with a mocked world of eight persons:
      - the same value whatever order the engine lists them in, and on two games with the same world;
      - a sampled person in another place, going elsewhere, on another stop or in another vehicle: another value; an
        unsampled one: the same value, until a check whose remainder is its own;
      - a person with two places (a vehicle and a building) read as the dump reads it (the vehicle);
      - the texts hashed are exactly the expected ones (the same hash computed here in Python);
      - through R.contentHash with R.hashCheckN, the same value; without a number, the remainder 0;
      - MPFEVER_PERSONDIGEST=0: "off"; MPFEVER_HASHOFF=personsDigest: not measured, as any part it names;
  - the launcher: a diagnostic part (logged, never a reason to reload, no whole dump asked for it), never "a local measure"
    after a reload, and when a game does not measure it ("off", an older version) no advice about the native module;
  - the bridge: simHash gives the check's number to R.contentHash and takes it back after; the hello says the test switches of
    the persons and the vehicles in one piece only when they are set;
  - extendedParts (run through lupa with a mocked world): the dump the launcher asks for after a difference (SDUMP.forceWorld)
    has the ~person and ~townbuilding lines; MPFEVER_SDUMPPERSONSAFTER=0: not; an ordinary world dump: not, as before;
    MPFEVER_SDUMP_PERSONS=1: in every world dump, as before.
Run: python tests/test_persondigest0713.py
"""
import os
import random
import re
import sys

import lupa.lua52 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
REFS = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_refs.lua")
BRIDGE = os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
MAINFORM = os.path.join(ROOT, "launcher", "MainForm.cs")

fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def read(path):
    return open(path, encoding="utf-8-sig").read().replace("\r\n", "\n")


# the world: COMPS[entity][component] = its fields; ORDER: the order the engine lists the persons in
MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
COMPS, ORDER = {}, {}
api = {
  type = { ComponentType = setmetatable({}, { __index = function(_, k) return k end }) },
  engine = {
    entityExists = function(e) return COMPS[e] ~= nil end,
    getComponent = function(e, ct)
      local c = COMPS[e]
      if ct == nil then error("no such component type") end
      return c and c[ct] or nil
    end,
    forEachEntityWithComponent = function(fn, ct)
      if ct == "SIM_PERSON" then for _, e in ipairs(ORDER) do if COMPS[e] and COMPS[e].SIM_PERSON then fn(e) end end end
    end,
    system = { streetSystem = { getEdgeObject2EdgeMap = function() return {} end }, lineSystem = { getLines = function() return {} end } },
  },
}
function log(s) end
-- the test's hash: the same in Python (h * 31 + byte, mod 2^32, from the seed)
function HS(seed, s) local h = seed for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end return h end
function person(id, target, upd) COMPS[id] = COMPS[id] or {}; COMPS[id].SIM_PERSON = { targetOrAtEntity = target, lastDestinationUpdate = upd, happiness = 0.5 } end
function setWorld()
  COMPS = {}
  -- (remainder 0: 8 16 24 32 40 48 56; remainder 1: 9 and 17)
  person(8, 900, 1000); COMPS[8].SIM_ENTITY_AT_VEHICLE = { vehicle = 501, line = 77, lineStop0 = 1, lineStop1 = 2 }
  person(16, 901, 1100); COMPS[16].SIM_ENTITY_AT_TERMINAL = { line = 77, lineStop0 = 2, lineStop1 = 3, arrivalTime = 5 }
  person(24, 902, 1200); COMPS[24].SIM_ENTITY_MOVING = { line = 78, lineStop0 = 0, lineStop1 = 1, partialPath = false }
  person(32, 903, 1300); COMPS[32].SIM_ENTITY_AT_BUILDING = {}
  person(40, 904, 1400); COMPS[40].SIM_ENTITY_IDLE = {}
  person(48, -1, 0)
  person(56, 905, 1500); COMPS[56].SIM_ENTITY_AT_VEHICLE = { vehicle = 502, line = 79, lineStop0 = 4, lineStop1 = 0 }; COMPS[56].SIM_ENTITY_AT_BUILDING = {}
  person(9, 906, 1600); COMPS[9].SIM_ENTITY_AT_BUILDING = {}
  person(17, 907, 1700); COMPS[17].SIM_ENTITY_AT_TERMINAL = { line = 80, lineStop0 = 1, lineStop1 = 2 }
  COMPS[100] = { TOWN_BUILDING = {} }   -- (not a person)
  ORDER = { 8, 9, 16, 17, 24, 32, 40, 48, 56, 100 }
end
'''


def game():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("R = (function() " + open(REFS, encoding="utf-8").read() + " end)()")
    L.execute("setWorld()")
    return L


def digest(L, n="0"):
    return L.eval("R.personsDigest(HS, " + n + ")")


def hs(seed, s):
    h = seed
    for b in s.encode("utf-8"):
        h = (h * 31 + b) % 4294967296
    return h


def main():
    refs = read(REFS)
    check("function R.personsDigest(hashStr, checkN)" in refs, "R.personsDigest is there")
    check('part("personsDigest", function() return R.personsDigest(hashStr, R.hashCheckN) end)' in refs
          and refs.index('part("persons", function() return count("SIM_PERSON") end)') < refs.index('part("personsDigest"'),
          "  a part of the checks, right after the persons' count")
    check('if os.getenv("MPFEVER_PERSONDIGEST") == "0" then return "off" end' in refs, "  MPFEVER_PERSONDIGEST=0: off")

    A, B = game(), game()
    d0 = digest(A)
    check(re.fullmatch(r"7/\d+", str(d0)) is not None, "the persons of the check's eighth are read (7 of 9)", d0)
    expect = [
        "8 vehicle 501 77/1>2 at 900 upd 1000",
        "16 terminal 77/2>3 at 901 upd 1100",
        "24 moving 78/0>1 at 902 upd 1200",
        "32 building at 903 upd 1300",
        "40 idle at 904 upd 1400",
        "48 - at -1 upd 0",
        "56 vehicle 502 79/4>0 at 905 upd 1500",
    ]
    want = sum(hs(0, t) for t in expect) % 4294967296
    check(str(d0) == f"7/{want}", "  each person's text: its id, where it is, its line and stops, where it goes (the dump's reading)", f"{d0} against 7/{want}")
    check(digest(B) == d0, "two games with the same world: the same value")
    for k in range(5):
        order = [8, 9, 16, 17, 24, 32, 40, 48, 56, 100]
        random.Random(k).shuffle(order)
        B.execute("ORDER = {" + ",".join(map(str, order)) + "}")
        if digest(B) != d0:
            break
    check(digest(B) == d0, "the same value whatever order the engine lists the persons in")
    B.execute("setWorld()")

    for change, what in [
        ("COMPS[16].SIM_ENTITY_AT_TERMINAL = nil; COMPS[16].SIM_ENTITY_MOVING = { line = 77, lineStop0 = 2, lineStop1 = 3 }", "a sampled person moving instead of waiting"),
        ("COMPS[24].SIM_PERSON.targetOrAtEntity = 999", "  going elsewhere"),
        ("COMPS[32].SIM_PERSON.lastDestinationUpdate = 1301", "  its destination chosen at another time"),
        ("COMPS[8].SIM_ENTITY_AT_VEHICLE.lineStop1 = 3", "  in its vehicle to another stop"),
        ("COMPS[8].SIM_ENTITY_AT_VEHICLE.vehicle = 503", "  in another vehicle"),
        ("COMPS[40].SIM_ENTITY_IDLE = nil; COMPS[40].SIM_ENTITY_AT_BUILDING = {}", "  in a building instead of idle"),
        ("COMPS[48] = nil", "  gone"),
        ("person(64, 1, 2); ORDER[#ORDER + 1] = 64", "  one more"),
    ]:
        B.execute(change)
        check(digest(B) != d0, what + ": another value")
        B.execute("setWorld()")
    check(digest(B) == d0, "  (back as it was: the same value again)")
    B.execute("COMPS[9].SIM_ENTITY_AT_BUILDING = nil; COMPS[9].SIM_ENTITY_IDLE = {}; COMPS[17].SIM_PERSON.targetOrAtEntity = 5")
    check(digest(B) == d0, "an unsampled person changed: the same value at this check")
    check(digest(B, "1") != digest(A, "1"), "  another value at a check of its own remainder")
    check(digest(A, "9") == digest(A, "1") and digest(A, "8") == d0, "the remainder is the check's number's by 8")
    check(re.fullmatch(r"2/\d+", str(digest(A, "1"))) is not None, "  (remainder 1: its two persons)", digest(A, "1"))
    B.execute("setWorld()")
    B.execute("COMPS[56].SIM_ENTITY_AT_BUILDING = nil")
    check(digest(B) == d0, "a person in a vehicle and a building is read as in the vehicle (as the dump reads it)")
    B.execute("setWorld()")

    # through the checks
    B.execute("R.hashSkip = setmetatable({}, { __index = function(_, k) return k ~= 'personsDigest' and k ~= 'persons' end })")
    p0 = B.eval("(function() R.hashCheckN = 16; local p = R.contentHash(HS, tostring); R.hashCheckN = nil; return p.personsDigest end)()")
    check(p0 == d0, "R.contentHash gives it as part personsDigest with the check's number (16: remainder 0)", p0)
    p1 = B.eval("(function() R.hashCheckN = 17; local p = R.contentHash(HS, tostring); R.hashCheckN = nil; return p.personsDigest end)()")
    check(p1 == digest(A, "1"), "  (17: remainder 1)", p1)
    pn = B.eval("(function() local p = R.contentHash(HS, tostring); return p.personsDigest end)()")
    check(pn == d0, "  without a number (the determinism run): remainder 0", pn)
    pc = B.eval("(function() local p = R.contentHash(HS, tostring); return p.persons end)()")
    check(str(pc).startswith("9/"), "  the persons' count as before", pc)
    B.execute("ENV.MPFEVER_PERSONDIGEST = '0'")
    check(digest(B) == "off", "MPFEVER_PERSONDIGEST=0: off")
    check(B.eval("(function() local p = R.contentHash(HS, tostring); return p.personsDigest end)()") == "off", "  in the checks too")
    B.execute("ENV.MPFEVER_PERSONDIGEST = nil; ENV.MPFEVER_HASHOFF = 'personsDigest'")
    check(B.eval("(function() local p = R.contentHash(HS, tostring); return tostring(p.personsDigest) end)()") == "nil",
          "MPFEVER_HASHOFF=personsDigest: not measured, as any part the switch names")
    B.execute("ENV.MPFEVER_HASHOFF = 'persons'")
    check(B.eval("(function() local p = R.contentHash(HS, tostring); return tostring(p.personsDigest) .. ' ' .. tostring(p.persons) end)()") == d0 + " nil",
          "  MPFEVER_HASHOFF=persons: the count off, the digest measured")
    B.execute("ENV.MPFEVER_HASHOFF = nil; R.hashSkip = nil")
    B.execute("api.engine.forEachEntityWithComponent = function() error('no') end; api.engine.getEntitiesWithComponent = function() error('no') end")
    check(str(digest(B)).startswith("cannot list"), "the persons not listed: said, as the count says it", digest(B))

    # the launcher
    mf = read(MAINFORM)
    check('static readonly HashSet<string> DiagnosticParts = new HashSet<string> { "buildIds", "personsDigest" };' in mf,
          "the launcher: a diagnostic part (logged only, never a reason to reload)")
    nl = mf[mf.index("static readonly HashSet<string> NeverLocalParts"):][:300]
    check('"buildIds"' in nl and '"personsDigest"' in nl.split(";")[0], "  never a local measure after a reload (still logged)")
    w = mf[mf.index("internal static bool WantsWorldDump(string part)"):][:300]
    check("!DiagnosticParts.Contains(part)" in w, "  no whole dump asked for it")
    check("if (unmeasuredParts.Add(k) && !DiagnosticParts.Contains(k))" in mf, "  not measured on a game: left out, without the advice about the native module")
    o = mf[mf.index("void OnSyncHash(Msg m)"):]
    o = o[:o.index("\n        }\n")]
    i_diag = o.index("var diag = diffs.Where(d => DiagnosticParts.Contains(DiffKey(d))).ToList();")
    check(o.index("diffs = diffs.Where(d => !ignoredParts.Contains(DiffKey(d))).ToList();") < i_diag
          < o.index("diffs = diffs.Where(d => !DiagnosticParts.Contains(DiffKey(d))).ToList();") < o.index("CheckResync(pending, n);"),
          "  logged as '(diagnostic)', then out of the differences, before any reload is decided")

    # the bridge
    br = read(BRIDGE)
    sh = br[br.index("local function simHash(terrainSig, reg, n, buildIds, at)"):]
    check("\tR.hashCheckN = n\n\tlocal parts = R.contentHash(C.hashStr, C.dump)\n\tR.hashCheckN = nil\n" in sh[:6000],
          "simHash gives the check's number to the checks' parts, and takes it back after")
    check(br.count("R.hashCheckN") == 2, "  set nowhere else")
    check('personserial = os.getenv("MPFEVER_PERSONSERIAL") == "1" or nil, vehserial = os.getenv("MPFEVER_VEHSERIAL") == "1" or nil })' in br,
          "the hello says the test switches of the persons and the vehicles in one piece, only when set")

    # extendedParts: the persons in the dump after a difference
    i = br.index("local function extendedParts(parts, checkN)")
    ext = br[i:br.index("\nend\n", i) + 5]
    check('if SDUMP.persons or (forced and os.getenv("MPFEVER_SDUMPPERSONSAFTER") ~= "0") then' in ext,
          "the dump's persons: with MPFEVER_SDUMP_PERSONS=1, or in the dump asked after a difference")
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute("setWorld()")
    L.execute(r'''
FILES = {}
BS, NL = "\\", "\n"
K = {}
GAME_SCRIPTS = {}
function gameTime() return 4242 end
function valueHash() return 0 end
function flatten() end
function countsHash(c) return #c end
R = { entitiesWith = function(cname)
        local r = {}
        for _, e in ipairs(ORDER) do if COMPS[e] and COMPS[e][cname] then r[#r + 1] = e end end
        return r
      end,
      lineText = function() return "" end, nameOf = function() return "" end, matPos = function() return { x = 1, y = 2 } end }
C = { DIR = "D", dump = tostring, hashStr = HS,
      IO = { open = function(path, mode) local buf = {}; FILES[path] = buf
        return { write = function(self, ...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end, close = function() end } end } }
''')
    run = L.execute(ext + "\nreturn function(n) FILES = {}; local parts = {}; extendedParts(parts, n); local t = {}; for p, buf in pairs(FILES) do t[#t + 1] = p .. '|' .. table.concat(buf) end; return table.concat(t, '#') end")

    def dump(sdump, n, env=""):
        L.execute("SDUMP = " + sdump + "; ENV = {" + env + "}")
        return str(run(n))

    forced = dump("{ on = true, all = false, n = 1, persons = false, forceWorld = true }", 7)
    check("~person 16 = " in forced and "~person 9 = " in forced and "~townbuilding 100 = " in forced,
          "the dump asked after a difference (not a world turn): the persons and the town buildings", forced[:300])
    check("terminal line 77 2>3" in forced and "vehicle 501 line 77 1>2" in forced, "  each as the dump's ~person lines say it")
    off = dump("{ on = true, all = false, n = 1, persons = false, forceWorld = true }", 7, "MPFEVER_SDUMPPERSONSAFTER = '0'")
    check("~person" not in off and "~townbuilding" not in off and off.startswith("D\\sdump_ring_2.txt|t = 4242"),
          "MPFEVER_SDUMPPERSONSAFTER=0: the dump without them, as before", off[:200])
    noforce = dump("{ on = true, all = false, n = 1, persons = false }", 6)
    check("~person" not in noforce and "~townbuilding" not in noforce and noforce.startswith("D\\sdump_ring_2.txt|t = 4242"),
          "an ordinary world dump (one check in six): without them, as before", noforce[:200])
    after0 = dump("{ on = true, all = false, n = 1, persons = false, forceWorld = true }", 7, "MPFEVER_SDUMPAFTER = '0'")
    check("~person" not in after0, "MPFEVER_SDUMPAFTER=0 (no world part asked): without them, as before")
    pers = dump("{ on = true, all = false, n = 1, persons = true }", 6)
    check("~person 16 = " in pers and "~townbuilding 100 = " in pers, "MPFEVER_SDUMP_PERSONS=1: in every world dump, as before")
    pers2 = dump("{ on = true, all = false, n = 1, persons = true }", 7)
    check("~person" not in pers2, "  (not in a dump without its world part, as before)")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
