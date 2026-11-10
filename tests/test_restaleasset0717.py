"""Offline test: a held build of trees, plants or rocks is never replayed from the tool's copy by RESTALE (0.7.17, issue #191;
G.restaleBody in mpfever_bridge.script.lua).

#191 (liber, 20:47): the bulldozer on a part of a group of trees (liber#13:46) went the RESTALE way ("RESTALE native build 95
shipped as liber#13:46 and replayed here as the others replay it"): its copy put the trees kept back as one construction without
a file, which no script command can make; every form failed on both games (13 engine assertions on the host), a resync. 0.7.16
kept such copies from being shipped at the click (#181, PRESHIPASSET) but not from this way.
  - G.restaleBody, run through lupa: a copy adding a construction without a file returns false (applied and captured the usual
    way), logged, before anything is shipped; a copy with a file goes on as before; MPFEVER_RESTALEASSET=1: as before.
Needs lupa (pip install lupa). Run: python tests/test_restaleasset0717.py
"""
import os, sys

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


src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = src.index("G.restaleBody = function(r, at)")
b = src.index("\nend\n", a) + 5
refs = open(os.path.join(CONTENT, "mpfever_refs.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = refs.index("local function isAssetFile(f)")
asset = refs[i:refs.index("\nend\n", i) + 5]
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
function log(t) LOGS[#LOGS + 1] = t end
SENT = 0
function send() SENT = SENT + 1 end
function nativeCtl() end
G = { restaleV2 = function() return false end, restaleOn = true, cmode = "shared", restaleWhy = function() return "WHY" end,
      restaleNeed = function() return "WHY" end, failidOn = function() return false end, pt = { of = {} }, ptKey = function() return "k" end }
R = {}
''' + asset + "\nR.isAssetFile = isAssetFile\n" + src[a:b])
reached = L.eval('''function(fileName)
  LOGS = {} SENT = 0
  G.restaleWhy = function() WHYASKED = true return nil end
  WHYASKED = false
  local r = { id = 95, copy = { toAdd = { { fileName = fileName } }, toRemove = { 15699 } } }
  local res = G.restaleBody(r, 100)
  return tostring(res) .. ":" .. tostring(WHYASKED) .. ":" .. SENT .. ":" .. tostring(LOGS[#LOGS])
end''')
r = reached("")
check(r.startswith("false:false:0:") and "trees, plants or rocks" in r, "trees (no file): false before anything, logged", r)
r = reached("::/stations/street/x.con")
check(r.startswith("false:true:0"), "a construction with a file: on as before (its change looked at)", r)
L.execute('ENV.MPFEVER_RESTALEASSET = "1"')
r = reached("")
check(r.startswith("false:true:0"), "MPFEVER_RESTALEASSET=1: as before", r)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
