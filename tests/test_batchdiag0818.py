"""The drift rings say which batch each step was made in (0.8.18, #150), offline.

Every step of the drift rings (drift_<check>_steps.txt) now ends with "batch s<state>k<place> cmds <n>": which of the game's two
world states made it (0: the first one seen since the load), its place in the batch (1 = the batch's first step), and the
commands of the simulation loop applied in that batch. tools/drift_diff.py shows the last batches of both games before the first
difference (same place in the batch? same state, relatively?). The native module also counts the batches with no step that
applied commands of the loop ("still batches with commands" in the minute's line; the first ones written): a build landing in a
still batch on one game and in a batch with steps on another.
Run: python tests/test_batchdiag0818.py
"""
import importlib.util
import os
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []


def check(what, cond):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)


src = (ROOT / "native" / "mpfever_native.cpp").read_text(encoding="utf-8", errors="replace")
check("the loop's commands counted in ApplyDetour (simulation thread, the loop only)", "if (inLoop && sim) _InterlockedIncrement(&g_loopCmds);" in src)
sfb = src[src.index('extern "C" u32 StepsForBatch'):]
sfb = sfb[:sfb.index("\nstatic void InstallNativeStop")]
check("each batch's commands taken in StepsForBatch, before its early return", sfb.index("g_batchCmds = c - g_loopCmdsSeen") < sfb.index("if (g_stopSeq < 0 || !g_getUpdRva"))
check("a still batch that applied commands is counted and written", "if (n == 0 && g_batchCmds > 0)" in sfb and "command(s) of the loop applied in a batch with no step" in sfb)
check("counted in the minute's line", '"; still batches with commands "' in src)
ds = src[src.index("static void DriftStep(void* engine)"):]
ds = ds[:ds.index("\n}\n")]
check("DriftStep keeps the batch with the step (state, place, commands), the previous step's as the rest of the entry",
      "d.pad = padPrev;" in ds and "padPrev = padNow;" in ds and "(gs == firstGs ? 0u : 1u)" in ds)
check("the first state seen again after a load", "if (padLoads != g_ctlLoads) { padLoads = g_ctlLoads; firstGs = 0; }" in ds)
check("written in drift_<check>_steps.txt", '.str(" batch s").dec((i64)(s.pad & 1)).str("k")' in src)

# drift_diff reads the new fields and shows the batches before the first difference
spec = importlib.util.spec_from_file_location("drift_diff", ROOT / "tools" / "drift_diff.py")
dd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dd)
with tempfile.TemporaryDirectory() as t:
    a, b = pathlib.Path(t, "A"), pathlib.Path(t, "B")
    a.mkdir(); b.mkdir()
    for d, cut in ((a, 4), (b, 3)):
        lines = ["drift diagnostic of check 7: the last 40 steps\r\n", "step <s> ...\r\n"]
        state, k = 0, 0
        for s in range(1000, 1040):
            k += 1
            if k > cut:
                k, state = 1, 1 - state
            diff = 1 if (d == b and s == 1030) else 0
            lines.append("step %d queue 5 10 99 adds %d rems 0 set %d batch s%dk%d cmds %d\r\n" % (s, 1 + diff, 7 + diff, state, k, 1 if s == 1012 else 0))
        (d / "drift_7_steps.txt").write_text("".join(lines), encoding="utf-8")
        (d / "drift_7_ops.txt").write_text("x\r\n", encoding="utf-8")
    out = []
    res = dd.compare(str(a), str(b), out=out.append)
    text = "\n".join(out)
    check("drift_diff: the first step that differs (1030)", res and res["first_ops_step"] == 1030)
    check("drift_diff: the batches of both games before it", "batches of the last" in text and "A s" in text and "| B s" in text)
    check("drift_diff: batches cut otherwise are seen (not every step at the same place)", res and res["batches_same_cut"] < res["batches_window"])
    old = pathlib.Path(t, "old"); old.mkdir()
    (old / "drift_7_steps.txt").write_text("step 1000 queue 5 10 99 adds 1 rems 0 set 7\r\n", encoding="utf-8")
    check("drift_diff: rings of earlier versions (no batch) still read", dd.steps(str(old / "drift_7_steps.txt"))[1000]["ops"] == (1, 0, 7))

print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
