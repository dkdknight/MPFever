"""The drift rings note each command the simulation applies, with its kind (0.9.1, #150 diagnostic, MPFEVER_DRIFTCMDS), offline.

Report #431 (2026-11-18, 0.9.0, mnach and P0WeRZz, a drift 20 minutes after a resync): both games made exactly the same batches on
the same states, and the first difference was in the animals' moves of step 132164. The steps' ring said that the client had
applied one command of the loop in that batch ("B s0k1 cmds 1") and the host none, but not which: a command of that game only (its
speed, its own events to the simulation) or one that should have been on both. Nothing in the files could tell (1590 of the 8189
steps of that ring had other counts on the two games, without a drift).
Now each command the simulation applies is noted in drift_<check>_ops.txt among the entities, "<step> c<kind> loop|script -", and
tools/drift_diff.py shows the commands of both games just before the first step that differs, marking those that are not the same.
The steps' counts and hashes are left as they were (a command of one game only must not show as a difference of the entities).
Part 1 checks the native module; part 2 runs drift_diff on rings written as 0.9.0 wrote them (no command: nothing to tell, the
report's case) and as 0.9.1 writes them (the command of one game only found).
Run: python tests/test_driftcmds091.py
"""
import importlib.util
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []


def check(what, cond, got=""):
    print(("PASS " if cond else "FAIL ") + what + (" -- " + str(got) if got != "" and not cond else ""), flush=True)
    if not cond:
        fails.append(what)


src = (ROOT / "native" / "mpfever_native.cpp").read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
ad = src[src.index('extern "C" u64 ApplyDetour(void* a, void* b)'):]
ad = ad[:ad.index("\n}\n")]
call = "if (sim && (inLoop || script)) { u8* pay = b ? *(u8**)b : 0; DriftCmd(pay ? *(u8*)(pay + 0x9b8) : 255, inLoop); }"
check("ApplyDetour notes the simulation's loop and script commands (kind at +0x9b8), before the command is applied",
      call in ad and ad.index(call) < ad.index("u64 r = ApplyBody(a, b, inLoop);"))
dc = src[src.index("static void DriftCmd(u32 kind, bool loop)\n{"):]
dc = dc[:dc.index("\n}\n")]
check("DriftCmd: a mark in the operations ring, the steps' counts and hash untouched",
      "o.add = loop ? 2 : 3; o.caller = kind;" in dc and "g_stepAdds" not in dc and "g_stepRems" not in dc and "g_stepSet" not in dc)
check("written \"<step> c<kind> loop|script -\"", '.str(" c").dec((i64)o.caller).str(o.add == 2 ? " loop -" : " script -")' in src)
check("MPFEVER_DRIFTCMDS=0: not noted", 'GetEnvironmentVariableA("MPFEVER_DRIFTCMDS", dc, 3) == 1 && dc[0] == \'0\') g_driftCmds = false;' in src
      and "if (!g_dOps || !g_driftCmds) return;" in dc)

spec = importlib.util.spec_from_file_location("drift_diff", ROOT / "tools" / "drift_diff.py")
dd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dd)


def rings(t, with_cmds):
    """Two games alike up to step 1030, where game B removes one animal more; B applied a command of kind 17 after step 1029
    (before step 1030) and A did not; both applied a script event (27) after step 1020."""
    a, b = pathlib.Path(t, "A%d" % int(with_cmds)), pathlib.Path(t, "B%d" % int(with_cmds))
    a.mkdir(); b.mkdir()
    for d in (a, b):
        steps = ["drift diagnostic of check 9: the last 40 steps\r\n", "step <s> ...\r\n"]
        ops = ["drift diagnostic of check 9: the last entities\r\n", "<step> ...\r\n"]
        for s in range(1000, 1040):
            extra = 1 if (d == b and s == 1030) else 0
            steps.append("step %d queue 5 10 99 adds 1 rems %d set %d batch s0k1 cmds 0\r\n" % (s, extra, 7 + extra))
            ops.append("%d +%d AnimalMoveSystem.ecs 2bc0239\r\n" % (s, 500000 + s))
            if extra:
                ops.append("%d -%d AnimalMoveSystem.ecs 2bc400a\r\n" % (s, 601991))
            if with_cmds and s == 1020:
                ops.append("%d c27 loop -\r\n" % s)
            if with_cmds and s == 1029 and d == b:
                ops.append("%d c17 loop -\r\n" % s)
        (d / "drift_9_steps.txt").write_text("".join(steps), encoding="utf-8")
        (d / "drift_9_ops.txt").write_text("".join(ops), encoding="utf-8")
    return str(a), str(b)


with tempfile.TemporaryDirectory() as t:
    out = []
    res = dd.compare(*rings(t, False), out=out.append)
    text = "\n".join(out)
    check("before (rings as 0.9.0 wrote them): the first difference found (1030), but no word on the commands",
          res and res["first_ops_step"] == 1030 and "commands applied" not in text and "commands" not in res, text)
    out = []
    res = dd.compare(*rings(t, True), out=out.append)
    text = "\n".join(out)
    check("after: the same first difference (the marks are not entities: no difference of their own)",
          res and res["first_ops_step"] == 1030 and res["only_b"] == [("-601991", "AnimalMoveSystem.ecs")], res and res.get("only_b"))
    rows = {x: (la, lb) for x, la, lb in (res or {}).get("commands", [])}
    check("  the command applied by one game only just before it is shown and marked",
          rows.get(1029) == ([], ["17 loop"]) and "commands applied after step 1029: A - | B 17 loop   <- NOT THE SAME" in text, text)
    check("  the steps before it shown too (1027 .. 1030), alike there", sorted(rows) == [1027, 1028, 1029, 1030] and rows[1027] == ([], []))
    check("  a command both games applied is read (the script event after step 1020)", dd.cmds(str(pathlib.Path(t, "A1", "drift_9_ops.txt")))[1020] == ["27 loop"])
    check("  the entity lines are read as before", len(dd.ops(str(pathlib.Path(t, "B1", "drift_9_ops.txt")))[1030]) == 2)

print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
