"""Offline test (0.8.17, #388): no shared maintenance table from a load's first copy until the loaded game's own iteration.

Andy joined a dedicated server's session: his game began to load the save while the script of the game he had before still ran;
it gave its table just after the load was counted (DropAtLoad), the table was taken as the new game's, in use from its first
iteration and never given again; the other games used none until their new game's script gave it, ~50 steps later. Checks:
  - ReplDetour calls MaintAtLoad(src, dst) at a load's first copy, whether or not DropAtLoad runs (MPFEVER_LOADKEEPLOCAL);
  - MaintAtLoad (MPFEVER_MTLOADBLOCK not 0) keeps the two states of that copy, drops the table in use and the one waiting, and
    blocks; MPFEVER_MTSTALETEST=1 gives the table in use again (refused while blocked, taken for the load otherwise);
  - while blocked: the script's ask returns nothing (so the game before's script sends nothing), a table given is refused
    ("wait", not stored), and the engine's depot lists use no table;
  - PreIterDetour calls MaintIterGs before MaintIterStart; an iteration of one of the two states ends the block, else after
    600 iterations it ends with a WARNING;
  - the first table given after a load says how many depot lists were opened since the load (0 with the fix);
  - the fix is named "maintload" in the native fixes list; the mod's E.maintSync does not report "wait" as a refusal.
A small Python model of the table's life then plays Andy's case with and without the block.
Run: python tests/test_maintload0817.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read()
eco = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_eco.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def block(head):
    m = re.search(r"^" + re.escape(head) + r"\n\{\n.*?^\}\n", src, re.S | re.M)
    return m.group(0) if m else ""


repl = block('extern "C" u64 ReplDetour(void* src, void* dst, u64 flag)')
pre = block('extern "C" u64 PreIterDetour(void* a)')
atload = block("static void MaintAtLoad(void* src, void* dst)")
itergs = block("static void MaintIterGs(void* gs)")
getenvf = block("static char* MaintGetenv(const char* s)")
cand = block("static void MaintCandidates(SavedRegs* r)")
inst = block("static void InstallSharedMaint()")
check(all([repl, pre, atload, itergs, getenvf, cand, inst]), "ReplDetour, PreIterDetour, MaintAtLoad, MaintIterGs, MaintGetenv, MaintCandidates found")

i_drop = repl.find("if (!LoadKeepLocal()) DropAtLoad();")
i_ml = repl.find("MaintAtLoad(src, dst);")
check(0 < i_drop < i_ml and "before == 0xFFFFFFFFu" in repl[:i_ml], "MaintAtLoad at a load's first copy, after DropAtLoad, not under LoadKeepLocal")
check(pre.find("MaintIterGs(a ? *(void**)((u8*)a + 8) : 0);") >= 0 and pre.find("MaintIterGs(") < pre.find("MaintIterStart();"),
      "PreIterDetour: MaintIterGs on the iteration's state, before MaintIterStart")
check('GetEnvironmentVariableA("MPFEVER_MTLOADBLOCK"' in src and "bool block = MtLoadBlockOn() != 0;" in atload, "MPFEVER_MTLOADBLOCK=0: as before")
check("g_mtNewGs[0] = src; g_mtNewGs[1] = dst;" in atload and "g_mtPend = 0; g_mtHave = 0;" in atload and "g_mtBlock = 1;" in atload,
      "at the load: both states kept, the tables dropped, blocked")
check('"MPFEVER_MTSTALETEST"' in atload and "nx.loads = g_ctlLoads;" in atload and ": refused" in atload and ": taken" in atload,
      "MPFEVER_MTSTALETEST: the table of the game before given again (refused when blocked, taken otherwise)")
t_part = getenvf[getenvf.find("s[0] == 'T'"):getenvf.find("s[0] == 'S'")]
d_part = getenvf[getenvf.find("s[0] == 'D'"):]
check("if (g_mtBlock) return 0;" in t_part and t_part.find("if (g_mtBlock) return 0;") < t_part.find("_InterlockedIncrement(&g_mtAsks)"),
      "while blocked, the script's ask returns nothing")
check(d_part.find("if (g_mtBlock)") >= 0 and d_part.find('return (char*)"wait";') < d_part.find("MaintTable& t = g_mt[next];"),
      "while blocked, a table given is refused before it is stored")
check("if (!r->r12 || !g_mtHave || g_mtBlock) return;" in cand, "while blocked, the engine's depot lists use no table")
check("gs == g_mtNewGs[0] || gs == g_mtNewGs[1]" in itergs and "g_mtBlock = 0;" in itergs and "== 600" in itergs and "WARNING" in itergs,
      "an iteration of the loaded game ends the block; else 600 iterations, with a WARNING")
check("the first table of this load given at step" in getenvf and "g_mtLet - g_mtLetLoad" in getenvf, "the first table after a load says the lists opened since")
check('Fx("maintload")' in inst, 'named "maintload" in the native fixes')
check('ans ~= "ok" and ans ~= "wait"' in eco, 'E.maintSync: "wait" is not reported as a refusal')


# A model of the table's life on two games through a join (Andy's case)
def run(blocking, stale_after_drop):
    g = {"have": False, "pend": None, "cur": None, "block": False, "loads": 0, "new": set(), "used": []}

    def give(tab, loads_now):
        if blocking and g["block"]:
            return "wait"
        g["pend"] = (tab, loads_now)
        return "ok"

    def iter_start(gs, step):
        if blocking and g["block"] and gs in g["new"]:
            g["block"] = False
        if g["pend"]:
            g["cur"], g["pend"], g["have"] = g["pend"], None, True

    def maintenance(step):
        ok = g["have"] and not (blocking and g["block"]) and g["cur"][1] == g["loads"]
        if step % 20 == 0:
            g["used"].append((step, ok))

    # the game before, with its table in use
    give("T", 0); iter_start("old", 1)
    # the load's first copy: DropAtLoad counts it
    g["loads"] += 1
    if blocking:
        g["have"], g["pend"], g["block"], g["new"] = False, None, True, {"A", "B"}
    if stale_after_drop:
        give("T", g["loads"])       # the game before's script, one moment later
        iter_start("old", 2)        # its last iteration
    # the loaded game: steps 263000.. ; its script gives at its first call, step 263018 (same on every game)
    for step in range(263000, 263060):
        iter_start("A" if step % 2 else "B", step)
        if step == 263018:
            # the script asks: "same" only if a table of this load was given
            same = g["pend"] is not None or (g["have"] and g["cur"][1] == g["loads"])
            if not same:
                give("T", g["loads"])
        maintenance(step)
    return [u for u in g["used"]]


host = run(blocking=False, stale_after_drop=False)
andy_old = run(blocking=False, stale_after_drop=True)
andy_new = run(blocking=True, stale_after_drop=True)
host_new = run(blocking=True, stale_after_drop=False)
check(host != andy_old, "model: without the block, Andy's game used the table before the others (the #388 drift)")
check(andy_new == host_new, "model: with the block, Andy's and the host's games use it at the same steps")
check(host_new == host, "model: with the block, a game without the late table behaves as before")

print("ALL OK" if not fails else "%d FAILED" % len(fails))
sys.exit(1 if fails else 0)
