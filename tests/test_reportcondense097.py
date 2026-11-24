"""Offline test (0.9.7, #473): a report over the report service's limit loses the clock lines of its in.log / out.log before it
loses the start of any log (launcher/Reporter.cs: ShrinkText, Condense; the launcher's self-test runs the real code).

JS's report of #473 (2026-11-22) held only the end of its logs: the start of out.log was cut to fit, and with it the mod's builds
refused during the pause 40 minutes earlier (their content, which mod sent them). In the reports of 2026-11-23, more than half of
in.log / out.log is clocks, speeds and tools' previews (#487: out.log 3.9 MB of 7.1 MB, in.log 3.1 MB of 7.2 MB).
  - CutLargest calls ShrinkText for the entry it cuts, in the zip and in a player's report.zip inside it;
  - ShrinkText condenses an in.log / out.log not condensed yet (Condense: the "clock", "peerclock", "perf" and "preview" lines left
    out, said on its first line), else keeps the last half (HalfTail) as before; MPFEVER_REPORTCONDENSE=0: the last half, as before;
  - the self-test RunTrim0717 checks it on a made-up out.log (first and last actions kept), twice, a mod.log, and the switch.
Run: python tests/test_reportcondense097.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def main():
    rep = open(os.path.join(HERE, "..", "launcher", "Reporter.cs"), encoding="utf-8-sig").read()
    st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
    i = rep.find("static string CutLargest(ref byte[] zipBytes)")
    j = rep.find("internal static byte[] ShrinkText(string name, byte[] data, out string how)")
    cut = rep[i:j]
    check(i > 0 and "data = ShrinkText(best, data, out string how);" in cut, "CutLargest: the entry of the zip through ShrinkText")
    check("var kept = ShrinkText(bestInner, ReadEntry(ie), out innerHow);" in cut, "CutLargest: a player's report.zip inside too")
    check("HalfTail(" not in cut, "  (no direct HalfTail left there)")
    body = rep[j:rep.find("internal static byte[] HalfTail(byte[] data)")]
    check('(file == "in.log" || file == "out.log")' in body and 'Environment.GetEnvironmentVariable("MPFEVER_REPORTCONDENSE") != "0"' in body,
          "ShrinkText: in.log / out.log only, MPFEVER_REPORTCONDENSE=0 switches it off")
    check('internal static readonly string[] Chatter = { "clock", "peerclock", "perf", "preview" };' in rep, "the chatter kinds: clock, peerclock, perf, preview")
    check('== "[MPFever:") return null;' in body and "data.Length * 0.9) return null;" in body, "Condense: never twice, nor for less than a tenth")
    check("(0.9.7, #473) a session's in.log / out.log loses its clocks first" in st and 'Reporter.ShrinkText("players/JS/session/JS-1/out.log"' in st,
          "the self-test runs the real code (RunTrim0717)")
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
