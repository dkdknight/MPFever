"""Offline test of the depot tolls kept in the saved registry (0.6.11, issue #122).

Issue #122 (one company per player, two computer companies buying their buses in the host's garage, its depots at a toll of
$10 000): "it doesn't count, seems the option doesn't work". The toll was booked, but noted (E.notePaid) in the copy of the
registry the action was applied with; the simulation then read its state again (state:get() makes a copy) and saved that one:
the window showed no "Paid to ..." line and its "Tolls: earned, paid" counted the track tolls only. The owner guard now hands the
toll to its caller in the action's result (result.toll), and SIM.noteDepotToll keeps it in the registry that is saved: after
the state is read again (simApplyDue), or in the simulation's event "depot_toll" for an action applied in a pause (the
interface's executeAction).

SIM.noteDepotToll and E.notePaid run through lupa (Lua 5.2). Cases:
  - a toll kept in the payer's "paid to" (kind d) and in both companies' toll totals, summed;
  - nothing kept for no fee, a wrong registry or toll;
  - the owner guard puts the toll in its result, notes it no more in R.CO (unless MPFEVER_DEPOTTOLLNOTE=0);
  - simApplyDue keeps it after reading its state again, and saves the state;
  - the pause's path sends it to the simulation, whose event keeps it.
Run: python tests/test_depottoll.py
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
    bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
    mp = re.search(r"^function E\.notePaid\(reg, from, to, kind, fee\)\n.*?^end\n", eco, re.S | re.M)
    mn = re.search(r"^SIM\.noteDepotToll = function\(reg, t\)\n.*?^end\n", bridge, re.S | re.M)
    check("E.notePaid and SIM.noteDepotToll found", mp is not None and mn is not None)
    if not (mp and mn):
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nE = {}\nSIM = {}\nC = { eco = function() return E end }\n"
              + mp.group(0) + mn.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    run("REG = {}; A = SIM.noteDepotToll(REG, { from = 2, to = 1, fee = 10000 }); SIM.noteDepotToll(REG, { from = 3, to = 1, fee = 10000 }); SIM.noteDepotToll(REG, { from = 2, to = 1, fee = 10000 })")
    check("kept: what company 2 paid to company 1 for its depots", run("return REG.paidTo['2>1:d']") == 20000, run("return tostring(REG.paidTo['2>1:d'])"))
    check("kept: company 3's too", run("return REG.paidTo['3>1:d']") == 10000)
    check("the depot's company earned all three", run("return REG.tollIncome['1']") == 30000, run("return tostring(REG.tollIncome['1'])"))
    check("each payer's toll total", run("return REG.tollExpense['2'] .. '/' .. REG.tollExpense['3']") == "20000/10000")
    check("it says it kept one", run("return A") is True)
    check("no fee: nothing kept", run("local r = {}; local k = SIM.noteDepotToll(r, { from = 2, to = 1, fee = 0 }); return (not k) and r.paidTo == nil and r.tollIncome == nil") is True)
    check("no registry or no toll: nothing, no error", run("return (not SIM.noteDepotToll(nil, { from = 2, to = 1, fee = 5 })) and (not SIM.noteDepotToll({}, nil))") is True)

    # the owner guard: the toll in its result, no longer noted in the registry copy
    check("the owner guard puts the toll in its result",
          "if from and to then result.toll = { from = a.co, to = toll.to, fee = toll.fee } end" in bridge)
    check("MPFEVER_DEPOTTOLLNOTE=0 notes it in R.CO as before",
          'os.getenv("MPFEVER_DEPOTTOLLNOTE") ~= "0"' in bridge and 'eco.notePaid(R.CO, a.co, toll.to, "d", toll.fee)' in bridge)
    # simApplyDue: after reading the state again, kept and saved
    check("simApplyDue keeps it after reading its state again",
          re.search(r"st = state:get\(\) or st\n\t+if r\.toll and SIM\.noteDepotToll\(st\.co, r\.toll\) then changed = true end", bridge) is not None)
    check("simApplyDue saves a changed state", "if changed then state:set(st) end" in bridge)
    # the pause: sent to the simulation, kept by its event
    check("a toll paid in a pause goes to the simulation", 'if r.toll then toSim("depot_toll", r.toll) end' in bridge)
    check("the simulation's event keeps it", re.search(r'elseif name == "depot_toll" then\n\t+SIM\.noteDepotToll\(st\.co, param\)', bridge) is not None)
    # the window's totals read these counters
    check("eco.txt's fees line carries the toll totals", "num(reg.tollIncome, co.id) .. \"\\t\" .. num(reg.tollExpense, co.id)" in bridge)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
