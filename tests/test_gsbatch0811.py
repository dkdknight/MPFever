"""Offline test (0.8.11, #331): a burst of a game script's commands goes as one action ("mpfBatch").

Nitropc's session, 2026-11-15 00:16: the mod A Corporate World (industry_brands) took away 15,800 custom entities in one go, each
a game script command shipped as its own action: the simulation's queue held 15,800 actions at one step and the simulation stood
9 minutes, the resynchronisation failed, the game was closed.
  - G.gsBatchable: "gsmod-" commands only, never a build, never a nested batch, never one waiting for an answer (h.pending);
    MPFEVER_GSBATCH=0: none;
  - stampHeld: a run of at least G.GSBATCH_MIN (16) such commands with the same token goes as one "mpfBatch" of at most
    G.GSBATCH_MAX (2000); fewer: one action each, as before; each command of a batch still meets the resynchronisation's and the
    game options' refusals, once;
  - executeAction: an "mpfBatch" applies each command through executeActionOnce (the same checks as its own action, in order),
    one line in mod.log;
  - autotest scenario gsburst (300 renames in one frame).
Needs lupa for the part that runs G.gsBatchable. Run: python tests/test_gsbatch0811.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check("G.GSBATCH_MIN, G.GSBATCH_MAX = 16, 2000" in src, "batch from 16 commands, at most 2000 per action")
g = src.find("G.gsBatchable = function(p)")
gb = src[g:src.find("\nend\n", g) + 5]
check(g > 0, "G.gsBatchable found")
check('os.getenv("MPFEVER_GSBATCH") == "0"' in gb, "  MPFEVER_GSBATCH=0: none")
check('p.tok:sub(1, 6) ~= "gsmod-"' in gb, "  game scripts' commands only")
check('p.fn == "makeWorldBuildProposalCmd"' in gb, "  never a build")
check("h.pending[p.id] ~= nil then return false" in gb, "  never one waiting for its answer")

h = src.find("local function stampHeld()")
hb = src[h:h + 6000]
check(h > 0, "stampHeld found")
check("if j - i + 1 >= G.GSBATCH_MIN then" in hb, "  a run shorter than the minimum goes as before")
check("entries[j + 1].p.tok == e.p.tok" in hb, "  one token per batch")
check('fn = "mpfBatch", args = { n = 1, list }' in hb, "  one mpfBatch action")
k = hb.find('p.fn == "mpfBatch" then')
check(k > 0 and "G.resyncRefuse(item.fn)" in hb[k:k + 900] and "G.featRefuse({ tok = p.tok, id = item.id" in hb[k:k + 900], "  each command refused as its own action would be")
scan = hb[:hb.find("for _, ent in ipairs(entries) do")]
check("G.featRefuse" not in scan and "G.resyncRefuse" not in scan, "  refusals asked once (not in the scan)")
check('send("act", a)' in hb[k:k + 1600] and "queueLocal(a)" in hb[k:k + 1600], "  shipped and applied here like an action")

x = src.find("local function executeBatch(a, sendCommand, bind)")
xb = src[x:src.find("\nend\n", x)]
check(x > 0, "executeBatch found")
check("pcall(executeActionOnce, sub, sendCommand, false, bind, nil)" in xb, "  each command through executeActionOnce")
check('item.fn ~= "mpfBatch"' in xb, "  no nested batch")
check("batchQuiet = true" in xb, "  one log line per batch")
check('if a.fn == "mpfBatch" then' in src[src.find("executeAction = function(a, sendCommand"):][:300], "executeAction runs batches")
check("if not a.batchQuiet then log(" in src, "executeActionOnce quiet inside a batch")
check("H.gsburst = function(from, p)" in src, "autotest scenario gsburst")

try:
    import lupa.lua52 as lupa
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}; os.getenv = function(k) return ENV[k] end; G = {}; package.loaded.mpfever_gs_hook = { pending = { [7] = true } }")
    L.execute(gb)
    f = L.eval("function(t) return G.gsBatchable(t) end")

    def T(**k):
        return L.table_from(k)

    check(f(T(tok="gsmod-1-a", id=1, fn="makeCustomEntityDestroyCmd")) is True, "run: a game script's destroy is batchable")
    check(f(T(tok="gsmod-1-a", id=7, fn="makeCustomEntityDestroyCmd")) is False, "run: not one waiting for its answer")
    check(f(T(tok="gsmod-1-a", id=2, fn="makeWorldBuildProposalCmd")) is False, "run: not a build")
    check(f(T(tok="ui-1", id=3, fn="makeEntitySetNameCmd")) is False, "run: not a player's command")
    L.execute('ENV.MPFEVER_GSBATCH = "0"')
    check(f(T(tok="gsmod-1-a", id=1, fn="makeCustomEntityDestroyCmd")) is False, "run: MPFEVER_GSBATCH=0")
except ImportError:
    print("lupa is not installed: the run part skipped")

print()
print("all ok" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)
