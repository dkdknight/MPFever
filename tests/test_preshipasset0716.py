"""Offline test: a build of trees, plants or rocks (a construction without a file) is never shipped at the click (0.7.16, issue
#181; G.preship in mpfever_bridge.script.lua).

#181 (AndeasWurzel and Simon, 2026-11-09 17:47): the host's bulldozer took away part of a group of trees. The tool's copy took
the group away and put the trees kept back as one construction without a file; it went to Simon at the click ("PRESHIP native
build 38 shipped at the click as AndeasWurzel:133"). No script command makes such a construction: Simon's 7 forms of the next
one (:135) failed ("factory Unknown exception"), the engine asserted 12 times there (Engine.h:323 GetComponentDataIndex), and the
host's capture, a tree build (assetBuild, its arguments by name), compared as nothing with the copy ("built here otherwise than
shipped at the click (nil / 0/0/...)"): the host's game was reloaded.
  - G.preship, run through lupa with the code before it: a copy that adds a construction without a file (or MPFever's asset
    construction) goes the usual way (false, logged), whether it also takes one away or not;
  - a station's edit (one construction for another, with files) and a street still go at the click, as in 0.7.15;
  - an entry without a file name (not read) is not taken for trees;
  - MPFEVER_PRESHIPASSET=1: shipped at the click, as in 0.7.15.
Needs lupa (pip install lupa). Run: python tests/test_preshipasset0716.py
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
a = src.index("G.preHasContent = function(m)")
b = src.index("G.preship = function(r)")
b = src.index("\nend\n", b) + 5
code = src[a:b]
refs = open(os.path.join(CONTENT, "mpfever_refs.lua"), encoding="utf-8").read().replace("\r\n", "\n")
i = refs.index("local function isAssetFile(f)")
asset = refs[i:refs.index("\nend\n", i) + 5]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG = {}
function log(t) LOG[#LOG + 1] = t end
SENT = 0
function send(kind, a) SENT = SENT + 1 end
function needsEnrich() return false end
G = { preshipOn = function() return true end, cmode = "shared", oseq = 0, me = "Host", frames = 1,
      preRefsOf = function() return {} end, refSigOf = function() return "sig" end, preStreetSig = function() return "s" end }
C = { copy = function(x) return x end }
R = { translateOut = function() end }
''' + asset + "\nR.isAssetFile = isAssetFile\n" + code)
run = L.eval("function(code) return assert(load(code))() end")


def preship(copy):
    run("SENT = 0; LOG = {}")
    got = run("return G.preship({ id = 38, at = 8979000, copy = " + copy + " })")
    return got, run("return SENT"), run("return LOG[#LOG] or ''")


group = '{ toAdd = { { fileName = "", name = "" } }, toRemove = { 350640 } }'
got, sent, last = preship(group)
check(got is False and sent == 0 and "trees, plants or rocks" in last,
      "#181: part of a group of trees bulldozed (the kept trees put back without a file): shipped the usual way", f"{got} {sent} {last}")
got, sent, last = preship('{ toAdd = { { fileName = "mpfever_asset.con" } } }')
check(got is False and sent == 0, "MPFever's own asset construction: the usual way too")
got, sent, last = preship('{ toAdd = { { fileName = "station/rail/modular_station/modular_station.con" } }, toRemove = { 5 } }')
check(got is True and sent == 1, "a station's edit (one construction for another, with files): still at the click, as in 0.7.15", f"{got} {sent} {last}")
got, sent, last = preship('{ toAdd = { { name = "x" } } }')
check(got is True and sent == 1, "an entry whose file name was not read: not taken for trees")
got, sent, last = preship('{ proposal = { addedSegments = { { entity = -1 } } } }')
check(got is True and sent == 1, "a street: at the click, as before")
run("ENV.MPFEVER_PRESHIPASSET = '1'")
got, sent, last = preship(group)
check(got is True and sent == 1, "MPFEVER_PRESHIPASSET=1: shipped at the click, as in 0.7.15")
run("ENV.MPFEVER_PRESHIPASSET = nil")

order = code.index('#(r.copy.toRemove or {}) > 0 and #(r.copy.toAdd or {}) == 0 and os.getenv("MPFEVER_PRESHIPREMOVE")')
check(order < code.index('os.getenv("MPFEVER_PRESHIPASSET") ~= "1"') < code.index('send("act", a)'),
      "decided before anything is shipped, after the 0.7.14 removal rule")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
