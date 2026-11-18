"""The sync and pace signs next to each player's name (0.9.0, #418), offline.

Each game sends its pace every 3 s (G.perfTick in mpfever_bridge.script.lua): its frames per second and the simulation's speed it
reaches by itself, in % of the speed asked (the game time it made per second of the time it did not stand waiting for the other
games). The host keeps them ("perf", launcher/MainForm.cs) and adds them to each player's line of mp_status.txt; the in-game
window draws two signs before each name (U.playerSigns in mpfever_ui.script.lua): sync (green / yellow drift / blue resync or
arrival / red out of sync or not answering) and pace (the worst of FPS 45/30/20 and simulation 95/75/50: green, yellow, orange,
red; grey when not known). MPFEVER_PERFSIGN=0: nothing sent, no signs.
Run: python tests/test_perfsign090.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []


def check(what, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + what + (" -- " + str(detail) if detail and not cond else ""), flush=True)
    if not cond:
        fails.append(what)


bridge = (ROOT / "mod" / "mpfever_1" / "content" / "mpfever_bridge.script.lua").read_text(encoding="utf-8", errors="replace")
ui = (ROOT / "mod" / "mpfever_1" / "content" / "mpfever_ui.script.lua").read_text(encoding="utf-8", errors="replace")
mf = (ROOT / "launcher" / "MainForm.cs").read_text(encoding="utf-8", errors="replace")

try:
    import lupa
except ImportError:
    lupa = None
    check("lupa installed (pip install lupa)", False)

# ---------------------------------------------------------------- the game's pace (bridge)
m = re.search(r"^G\.perfOn = .*?\nG\.perfTick = function\(\)\r?\n.*?^end\r?\n", bridge, re.S | re.M)
check("G.perfTick found in the bridge", m is not None)
check("G.perfTick called with the clock's message (every frame of a session)", "pcall(G.perfTick)" in bridge)
if m and lupa:
    def run(stood_per_window, adv_ms, speed=4, paused=False, frames=180, env_off=False):
        L = lupa.LuaRuntime(unpack_returned_tuples=True)
        L.execute("""
            G = { frames = 0, session = { started = true, speed = %d, pauseAt = %s }, standM = { t = 0 } }
            CLOCK, T, SENT = 0, 100000, {}
            os.clock = function() return CLOCK end
            os.getenv = function(k) if k == "MPFEVER_PERFSIGN" then return %s end return nil end
            function gameTime() return T end
            function send(kind, p) SENT[#SENT + 1] = { kind = kind, fps = p.fps, pace = p.pace } end
        """ % (speed, "1000" if paused else "nil", '"0"' if env_off else "nil"))
        L.execute(m.group(0))
        L.execute("G.perfTick()")   # (the first call only takes its marks)
        L.execute("CLOCK = 3.0; G.frames = %d; T = T + %d; G.standM.t = %f; G.perfTick()" % (frames, adv_ms, stood_per_window))
        sent = L.eval("SENT")
        return [dict(sent[i]) for i in range(1, len(sent) + 1)]
    r = run(0.0, 3 * 1000 * 4 * 0.4)
    check("the game everybody waits for (never stands): its pace is the session's (40 %), 60 FPS",
          len(r) == 1 and r[0]["kind"] == "perf" and r[0]["pace"] == 40 and r[0]["fps"] == 60, r)
    r = run(1.5, 3 * 1000 * 4 * 0.4)
    check("a game that stands half the time at the same session pace: its own pace 80 %", r and r[0]["pace"] == 80, r)
    r = run(2.9, 3 * 1000 * 4 * 0.4)
    check("a game that stood almost all the time: 100 % (nothing to measure, not the slow one)", r and r[0]["pace"] == 100, r)
    r = run(0.0, 0, paused=True)
    check("paused: the pace is not known (-1), the FPS still sent", r and r[0]["pace"] == -1 and r[0]["fps"] == 60, r)
    r = run(0.0, 3 * 1000 * 4, env_off=True)
    check("MPFEVER_PERFSIGN=0: nothing sent", r == [], r)

# ---------------------------------------------------------------- the host keeps them (launcher)
cp = mf[mf.index('case "perf":'):] if 'case "perf":' in mf else ""
cp = cp[:cp.index("break;")] if cp else ""
check("the host keeps each game's pace (case perf), not passed on", "perfOf[m.From] = new PerfInfo" in cp)
check("the values bounded (FPS 0-999, pace -1-100)", "Math.Min(999, fd)" in cp and "Math.Min(100, pd)" in cp)
check("each player's line of mp_status.txt ends with its pace fields", ".Append(PerfFields(id))" in mf)
check("unknown or older than 15 s: empty fields", "Now - p.At > 15" in mf)

# ---------------------------------------------------------------- the signs (UI)
check("the window reads the fields 7 and 8 (fps, pace)", "fps = tonumber(f[7] or \"\"), pace = tonumber(f[8] or \"\")" in ui)
check("both lists of players draw the signs", ui.count("U.playerSigns(") >= 2)
check("the colour orange has a value (not among the game's colours)", re.search(r"Orange = \{ 0\.95, 0\.52, 0\.1, 1 \}", ui) is not None)
s = re.search(r"^U\.signsOn = .*?^U\.playerSigns = function", ui, re.S | re.M)
check("the signs' functions found", s is not None)
if s and lupa:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("""
        os.getenv = function() return nil end
        U = {}; C = {}
        function T(fr, en) return en end
        function C.Tf(fr, en, ...) local v = { ... }; local i = 0; return (en:gsub("%%s", function() i = i + 1; return tostring(v[i]) end)) end
    """)
    L.execute(s.group(0)[:-len("U.playerSigns = function")])
    sign = L.eval("function(fps, pace) local c, t = U.perfSign({ fps = fps, pace = pace }); return c .. '|' .. t end")
    syncs = L.eval("function(state, sync) local c = U.syncSign({ state = state }, { sync = sync }); return c end")
    check("pace: 60 FPS, 98 % -> green", sign(60, 98).startswith("Ok|"), sign(60, 98))
    check("pace: 60 FPS, 80 % -> yellow", sign(60, 80).startswith("Warning|"))
    check("pace: 25 FPS, 98 % -> orange (the worst of the two)", sign(25, 98).startswith("Orange|"))
    check("pace: 60 FPS, 40 % -> red", sign(60, 40).startswith("Error|"))
    check("pace: 12 FPS -> red", sign(12, None).startswith("Error|"))
    check("pace: not known -> grey", sign(None, None).startswith("NeutralLight|"))
    check("pace: the tooltip says both figures", "60 FPS" in sign(60, 98) and "98 %" in sign(60, 98))
    check("sync: in sync -> green", syncs("ok", "ok") == "Ok")
    check("sync: slight drift -> yellow", syncs("ok", "drift") == "Warning")
    check("sync: resynchronisation -> blue", syncs("ok", "resync") == "Info" and syncs("loading", "ok") == "Info" and syncs("joining", "ok") == "Info")
    check("sync: out of sync or not answering -> red", syncs("ok", "desync") == "Error" and syncs("noresp", "ok") == "Error" and syncs("away", "ok") == "Error")

print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
