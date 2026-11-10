"""Offline test of what a company paid to each other company, and of the chat line that says it (0.6.8, issue #115).

One company per player: "there is no tracking about the toll charge some can enable, you don't see that you are giving
this to someone". The company window showed totals only. What a company pays to another one is now kept by kind (station
fees, track tolls, depot tolls), shown in the company window's "Earnings and fees", and said once in the chat the first
time in a session a company pays another one.

E.notePaid (mpfever_eco.lua), U.paidBy and U.paidNotice (mpfever_ui.script.lua) run through lupa (Lua 5.2). Cases:
  - the amounts kept per payer, payee and kind, summed; nothing kept for nothing paid; MPFEVER_PAIDTO=0: nothing kept;
  - the three bookings call it (stations' fees, tracks' tolls, depots' tolls) and eco.txt carries "paid" lines;
  - U.paidBy gives this company's payments by payee and kind, not the others';
  - U.paidNotice: nothing said at the first reading (what was paid before the load), one line when a payee is paid more,
    never twice for the same payee; MPFEVER_PAIDNOTICE=0: no line;
  - the company window lists them.
Run: python tests/test_paidto.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")

fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    eco = open(os.path.join(CONTENT, "mpfever_eco.lua"), encoding="utf-8").read()
    ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read()
    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
    m = re.search(r"^function E\.notePaid\(reg, from, to, kind, fee\)\n.*?^end\n", eco, re.S | re.M)
    check("E.notePaid found", m is not None)
    if not m:
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nE = {}\n" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    run("REG = {}; E.notePaid(REG, 2, 1, 's', 300); E.notePaid(REG, 2, 1, 's', 200); E.notePaid(REG, 2, 1, 't', 1000); E.notePaid(REG, 2, 3, 'd', 50); E.notePaid(REG, 2, 1, 's', 0)")
    check("summed per payer, payee and kind", run("return REG.paidTo['2>1:s'] .. '/' .. REG.paidTo['2>1:t'] .. '/' .. REG.paidTo['2>3:d']") == "500/1000/50",
          run("return tostring(REG.paidTo['2>1:s'])"))
    run("ENV.MPFEVER_PAIDTO = '0'; R2 = {}; E.notePaid(R2, 2, 1, 's', 300); ENV.MPFEVER_PAIDTO = nil")
    check("MPFEVER_PAIDTO=0: nothing kept", run("return R2.paidTo == nil"))
    check("the tracks' tolls call it", 'E.notePaid(reg, o.from.id, o.to, "t", o.fee)' in eco)
    check("the stations' fees call it", 'eco.notePaid(reg, o.from, o.to, "s", o.fee)' in bridge)
    check("the depots' tolls call it", 'eco.notePaid(R.CO, a.co, toll.to, "d", toll.fee)' in bridge)
    check("eco.txt carries the paid lines", 'L[#L + 1] = "paid\\t" .. f' in bridge)

    mb = re.search(r"^U\.paidBy = function\(eco, my\)\n.*?^end\n", ui, re.S | re.M)
    mn = re.search(r"^U\.paidNotice = function\(eco\)\n.*?^end\n", ui, re.S | re.M)
    check("U.paidBy and U.paidNotice found", mb is not None and mn is not None)
    if mb and mn:
        # (0.8.1) no global T: the interface script declares "local T" below U.paidNotice, so a global T here hid that the
        # notice called a nil T (see tests/test_localorder081.py)
        run("U = { myCo = 2, aiCoName = function(id) return 'Company ' .. id end }\nC = { Tf = function(fr, en, ...) return string.format(en, ...) end, T = function(fr, en) return en end }")
        L.execute(mb.group(0) + mn.group(0))
        run("ECO = { paid = { { from = 2, to = 1, kind = 's', amount = 500 }, { from = 2, to = 1, kind = 't', amount = 1000 }, { from = 1, to = 2, kind = 's', amount = 9 } } }")
        check("U.paidBy: this company's payments by payee and kind", run("local b = U.paidBy(ECO, 2); return b[1].s .. '/' .. b[1].t .. '/' .. b[1].d .. '/' .. tostring(b[2])") == "500/1000/0/nil")
        run("U.paidNotice(ECO)")
        check("the first reading says nothing (paid before the load)", run("return U.chat == nil"))
        run("ECO.paid[1].amount = 800; U.paidNotice(ECO)")
        got = run("return U.chat and #U.chat .. ' ' .. U.chat[1].text or 'none'")
        check("a payee paid more: one line, who and what", got.startswith("1 ") and "Company 1" in got and "its stations, its tracks" in got, got)
        run("ECO.paid[1].amount = 900; U.paidNotice(ECO)")
        check("never twice for the same payee", run("return #U.chat") == 1)
        run("ECO.paid[#ECO.paid + 1] = { from = 2, to = 3, kind = 'd', amount = 40 }; U.paidNotice(ECO)")
        check("a new payee: its own line", run("return #U.chat") == 2 and "its depots" in run("return U.chat[2].text"))
        run("U.chat = nil; U.paidSeen = nil; U.paidTold = nil; ENV.MPFEVER_PAIDNOTICE = '0'; U.paidNotice(ECO); ECO.paid[1].amount = 2000; U.paidNotice(ECO); ENV.MPFEVER_PAIDNOTICE = nil")
        check("MPFEVER_PAIDNOTICE=0: no line", run("return U.chat == nil"))
    check("the company window lists them", 'C.Tf("Payé à %s : gares %s, voies %s, dépôts %s"' in ui and "local by = U.paidBy(eco, my)" in ui)
    check("the window's file reading calls the notice", "pcall(U.paidNotice, e)" in ui)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
