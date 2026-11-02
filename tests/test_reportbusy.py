"""Offline test of the "Report a problem" button while a report is being made, and of the windows' inner margin (0.6.8).

A report takes some 20 s: nothing said it was being made, a player clicked three times and got three zips (2026-11-01), and
the answer of the last report (report.txt) came back at once as if the new one were ready. Issue #114: the in-game windows'
content touched the left border.

The report functions of mpfever_ui.script.lua run through lupa (Lua 5.2) with mocks. Cases:
  - a click asks a report and the button says it is being made; a second click asks nothing;
  - the old answer in report.txt is not taken for the new one; a new answer is shown and the button is free again;
  - after 120 s without an answer the button is free again; MPFEVER_REPORTBUSY=0: every click asks a report, as before;
  - MPFever.exe makes one report at a time (MainForm.cs) and writes the answer to every game's report.txt;
  - K.padded gives the Session, Hub and Chat windows a margin; MPFEVER_WINPAD=0: none.
Run: python tests/test_reportbusy.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
FORM = os.path.join(HERE, "..", "launcher", "MainForm.cs")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
NOW = 1000
os.time = function() return NOW end
FILE = nil
ASKED = 0
C = { DIR = "d", BS = "/", IO = { open = function(path, mode)
  if mode == "rb" then
    if not FILE then return nil end
    local done = false
    return { read = function() if done then return nil end done = true return FILE end, close = function() end }
  end
end } }
function T(fr, en) return en end
function log() end
U = { menuRequest = function(cmd) ASKED = ASKED + 1 return true end }
'''

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(UI, encoding="utf-8").read()
    m = re.search(r"^function U\.reportLine\(\)\n.*?^local function pollReport\(\)\n.*?^end\n", src, re.S | re.M)
    if not m:
        print("FAIL: the report functions not found in the interface script")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m.group(0) + "\nREQ = requestReport\nPOLL = pollReport\n")
    run = L.eval("function(code) return assert(load(code))() end")

    run("FILE = '1\\tReport ready: old.zip.'")
    run("REQ()")
    check("a click asks a report", run("return ASKED") == 1)
    check("the button says the report is being made", run("return U.reportLabel()") == "Making the report…", run("return U.reportLabel()"))
    run("REQ()")
    check("a second click while it is being made asks nothing", run("return ASKED") == 1, run("return ASKED"))
    run("NOW = 1005; POLL()")
    check("the old answer is not taken for the new one", "old.zip" not in str(run("return U.reportMsg")), run("return U.reportMsg"))
    check("and the button still says it is being made", run("return U.reportBusy()") is True)
    run("NOW = 1020; FILE = '2\\tReport ready: new.zip.'; POLL()")
    check("the new answer is shown", run("return U.reportMsg") == "Report ready: new.zip.", run("return U.reportMsg"))
    check("and the button is free again", run("return U.reportBusy()") is False and run("return U.reportLabel()") == "Report a problem (logs)")
    run("REQ()")
    check("a click after the answer asks a new report", run("return ASKED") == 2)
    run("NOW = NOW + 130; POLL()")
    check("no answer within 120 s: the button is free again", run("return U.reportBusy()") is False)
    run("ENV.MPFEVER_REPORTBUSY = '0'; REQ(); REQ()")
    check("MPFEVER_REPORTBUSY=0: every click asks a report, as before", run("return ASKED") == 4, run("return ASKED"))
    run("ENV.MPFEVER_REPORTBUSY = nil")

    cs = open(FORM, encoding="utf-8").read()
    check("MPFever.exe makes one report at a time", "CompareExchange(ref reportBusy, 1, 0)" in cs and "Interlocked.Exchange(ref reportBusy, 0)" in cs)
    check("MPFever.exe writes the answer to every game's report.txt", cs.count("ReportAnswer(F(") == 2 and "games.Select(g => g.Dir)" in cs)

    mp = re.search(r"^\tfunction K\.padded\(content\)\n.*?^\tend\n", src, re.S | re.M)
    check("#114: K.padded found", mp is not None)
    if mp:
        L.execute("K = { style = function(t) return t end, col = function(c) return { col = c } end }\nbuiltin = { Component = function(t) return t end }\n"
                  + mp.group(0).replace("\tfunction K.padded", "function K.padded", 1))
        got = run("local c = K.padded('x'); return c.meta.styleSheet.padding[4] .. '/' .. c.meta.styleSheet.padding[3] .. '/' .. c.layout.col[1]")
        check("#114: a margin on the left (12) and at the bottom (10) around the content", got == "12/10/x", got)
        run("ENV.MPFEVER_WINPAD = '0'")
        check("MPFEVER_WINPAD=0: the content as it is, as before", run("return K.padded('x')") == "x")
        run("ENV.MPFEVER_WINPAD = nil")
    check("#114: the Session and Hub windows use it", src.count("content = K.padded(content),") == 2)
    check("#114: the Chat window too", "(U.kit and U.kit.padded or function(c) return c end)(" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
