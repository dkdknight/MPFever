"""Offline test: the drift diagnostic (0.8.2, MPFEVER_DRIFTDIAG; native/mpfever_native.cpp, mpfever_bridge.script.lua,
tools/drift_diff.py).

The people drift of #150 starts with one entity made or removed on one game only, minutes before the people differ; the
players' reports did not hold it (test C of 2026-11-11 needed a 90 MB/hour log). Now, at the cost of counters:
  - the native module keeps, in memory only, the last 131072 entity operations of the simulation's engine (step, id, the engine
    system whose update made it, by its class name) and a digest of each of the last 16384 steps (free-id queue, the step's
    additions and removals);
  - the mod, at the first forced check after a difference (the same check on every game), keeps its dump apart
    (sdump_drift_<0..2>.txt) and asks for the rings (native_drift.txt); the native module copies them on the simulation's thread
    and writes drift_<check>_steps.txt / _ops.txt from a thread of its own (the last 3 checks kept);
  - tools/drift_diff.py finds the first step whose operations differ, those of one game only and their systems;
  - read only: nothing the simulation decides changes; MPFEVER_DRIFTDIAG=0 / MPFEVER_DRIFTKEEP=0: off.
Run: python tests/test_driftdiag082.py
"""
import os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import drift_diff  # noqa: E402

nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8-sig").read().replace("\r\n", "\n")
br = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def body(src, start, end="\n}\n"):
    b = src[src.index(start):]
    return b[:b.index(end)]


inst = body(nat, "static void InstallDriftDiag()")
check('MPFEVER_DRIFTDIAG' in inst and "v[0] == '0'" in inst, "native: on by default, MPFEVER_DRIFTDIAG=0 off")
check('"48 8B 0F 48 8B D6 C5 F8 28 DE 4C 8B C0 4C 8B 09 41 FF 51 58 48 83 C7 08 49 3B FE"' in inst
      and "Splice(mem, loop, 6, DiagSystem)" in inst and "Splice(mem, loop + 29, 5, DiagSystemsDone)" in inst
      and "0x75, 0x8C, 0x48, 0x8B, 0x5C, 0x24, 0x68" in inst, "  the engine's system loop found by its bytes, its end checked before splicing")
check("g_entDetours = true;" in inst and "if (!g_entDetours) {" in nat, "  the entity hooks shared with MPFEVER_ENTWATCH (never twice)")
ae = body(nat, 'extern "C" int* AddEntityDetour(')
re_ = body(nat, 'extern "C" void RemoveEntityDetour(')
check("if (g_driftOn && r && e == 0 && k == 1) DriftOp(*r, true, _ReturnAddress());" in ae
      and "if (g_driftOn && e == 0 && k == 1) DriftOp(entity, false, _ReturnAddress());" in re_, "native: the simulation's engine on its thread only goes in the ring")
op = body(nat, "static void DriftOp(int entity, bool add, void* ret)\n{")
check("& (DIAG_OPS - 1)" in op and "WriteFile" not in op and "LogLine" not in op, "  the ring in memory, nothing written while the game runs")
ds = body(nat, "static void DiagSystem(")
check("SysIndex(*(u64*)sys)" in ds and "g_simTid" in ds, "  the system known from the loop's slot, on the simulation's thread")
check("*(u32*)col != 1" in body(nat, "static void SysClassName(") and "td + 16" in nat, "  by its class name (RTTI), the same on every store's copy")
st = body(nat, "static void DriftStep(")
check("QueueDigest(" in st and "*(void**)(gs + 0x18) != engine" in st, "native: each step's digest of the simulation's engine only")
check("if (g_driftOn) DriftStep(engine);" in nat and "if (!snapTest && !freeq && !g_driftOn) return;" in nat, "  from the steps' wrapper, installed for it")
pl = body(nat, "static void DriftPoll()\n{")
check("(++g_driftPoll & 31)" in pl and "memcpy(d->ops, g_dOps" in pl and "CreateThread(0, 0, DriftWriter" in pl, "native: the request polled every 32 iterations, rings copied, written by a thread")
check("DeleteFileA(path)" in pl and "g_driftKept[2] = v;" in pl, "  the last 3 checks kept")
check("DriftPoll();" in body(nat, 'extern "C" u64 PreIterDetour('), "  polled on the simulation's thread")
check('SDUMP.driftN = (pAfter and type(checkN) == "number" and os.getenv("MPFEVER_DRIFTKEEP") ~= "0") and checkN or nil' in br,
      "mod: the first forced check of a run (every game alike), MPFEVER_DRIFTKEEP=0 off")
kd = br[br.index("function SDUMP.keepDrift("):]
kd = kd[:kd.index("\nend\n")]
check('"sdump_drift_" .. tostring(slot)' in kd and "SDUMP.keptN % 3" in kd and '"native_drift.txt"' in kd, "  its dump kept in 3 slots by turn, the native rings asked for")

# the tool on two games' files: one entity removed at step 101 on B only, by the aircraft system
d = tempfile.mkdtemp()
try:
    for g, extra in (("A", []), ("B", ["101 -555 ecs.AircraftMoveSystem 8f160"])):
        os.makedirs(os.path.join(d, g))
        with open(os.path.join(d, g, "drift_7_steps.txt"), "w") as f:
            f.write("drift diagnostic of check 7\nstep <s> ...\n")
            for s in range(95, 110):
                q = (3, 900, 11) if (g == "A" or s < 102) else (4, 1455, 12)
                o = (2, 1, 5) if (g == "A" or s != 101) else (2, 2, 9)
                f.write("step %d queue %d %d %d adds %d rems %d set %d\n" % (s, q[0], q[1], q[2], o[0], o[1], o[2]))
        with open(os.path.join(d, g, "drift_7_ops.txt"), "w") as f:
            f.write("drift diagnostic of check 7\n<step> ...\n")
            for s in range(95, 110):
                f.write("%d +%d ecs.LandVehicleMoveSystem ac91da\n%d +%d ecs.LandVehicleMoveSystem ac91da\n%d -%d ecs.AnimalMoveSystem a96267\n" % (s, 1000 + s, s, 2000 + s, s, 3000 + s))
            for l in extra:
                f.write(l + "\n")
    lines = []
    r = drift_diff.compare(os.path.join(d, "A"), os.path.join(d, "B"), out=lines.append)
    check(r and r["first_ops_step"] == 101 and r["only_b"] == [("-555", "ecs.AircraftMoveSystem")] and r["only_a"] == [], "tool: the first step, the entity of one game only and its system")
    check(r and r["first_queue_step"] == 102, "  then the first step whose free-id queue differs")
    check(any("systems involved: ecs.AircraftMoveSystem (1)" in l for l in lines), "  the system named in its report")
    # (the autotest of 2026-11-11: each game decides its own forced check, host 13/15/16, client 14/15/17) the latest check both
    # wrote, else the latest of each: the steps are numbered alike on every game
    for n in ("drift_7_steps.txt", "drift_7_ops.txt"):
        os.rename(os.path.join(d, "B", n), os.path.join(d, "B", n.replace("_7_", "_8_")))
    r = drift_diff.compare(os.path.join(d, "A"), os.path.join(d, "B"), out=lambda *_: None)
    check(r and r["check"] == 7 and r["check_b"] == 8 and r["first_ops_step"] == 101, "tool: two games' checks of other numbers compared by their steps")
finally:
    shutil.rmtree(d, ignore_errors=True)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
