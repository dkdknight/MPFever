"""Offline test: no refund booked with a mod that makes building free (0.6.7, session of 2026-11-01 02:17).

With the game's "No costs" mod (urbangames_no_costs_1) nothing is charged, but the proposal data still say what a build would
cost: the difference between the builder's and the replay's price was booked on the other games at every build, and their
money moved. REFUND.noCostMod reads the savegame's mods (host_mods.txt / session_mods.txt: "id|name|source|...;;...").

Run: python tests/test_nocostrefund.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
MAINFORM = os.path.join(HERE, "..", "launcher", "MainForm.cs")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


src = open(BRIDGE, encoding="utf-8").read()
m = re.search(r"^REFUND\.NOCOST = .*?^function REFUND\.noCostMod\(text\)\n.*?^end\n", src, re.S | re.M)
check("REFUND.noCostMod found", m is not None)
check("REFUND.book asks REFUND.freeBuilds", "if REFUND.freeBuilds() then st.rcost = nil; return true end" in src)
check("MPFever.exe writes session_mods.txt", '"session_mods.txt"' in open(MAINFORM, encoding="utf-8").read())
if m:
    L = lupa.LuaRuntime()
    L.execute("ENV = {} os.getenv = function(k) return ENV[k] end REFUND = {}")
    L.execute(m.group(0))
    f = L.eval("function(t) return REFUND.noCostMod(t) end")
    check("the game's No costs mod found", f("urbangames_no_costs_1|No costs|BuiltIn|;;sncb_i11_1|SNCB I11|StagingArea|") == "urbangames_no_costs_1")
    check("found in the launcher's longer form too", f("x_1|X|Workshop|123|sim|ok|ok||;;urbangames_no_costs_1|No costs|BuiltIn||load|ok|ok||") == "urbangames_no_costs_1")
    check("other mods: none", f("sncb_i11_1|SNCB I11|StagingArea|;;devers_1|Real Track Cant|Workshop|1") is None)
    check("no mods: none", f("") is None)
    L.execute('ENV.MPFEVER_NOCOSTREFUND = "1"')
    check("MPFEVER_NOCOSTREFUND=1: booked as before", f("urbangames_no_costs_1|No costs|BuiltIn|") is None)
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
