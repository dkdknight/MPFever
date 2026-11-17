"""Offline test (0.8.17, #390): while the host's save runs, the waits for the engine's answers do not run out, and a paused check
waits for a native replay still in the engine's hands (G.saveBusyOn / G.saveOver / G.saveRefresh / G.saveBusyNow, H.resync_save,
runPausedActions in mpfever_bridge.script.lua, switch MPFEVER_SAVEBUSY).

Kasper's host saved the session's autosave (2026-11-16 17:01 and 17:11); its engine took 12 to 16 s and answered nothing. Eier's
paused line (Eier#1:181) and warehouse (Eier#1:235) were applied on his game at once and handed to the host's engine, which applied
them after the save. The waits of 600 frames (a paused action's answer, a native replay's answer) ran out during the save, and the
host's paused check was taken before its engine had applied them: "lines" 141/140, then "townBuildings", and the host's money
correction moved Eier's money by 1 185 061 and back.
The functions are taken from the real bridge and run through lupa on a model of a 16 s save at 60 frames a second:
  - MPFEVER_SAVEBUSY=0: the line's wait runs out at 600 frames, during the save (the bug, reproduced);
  - now: still waited for at the end of the save; started again once it is over (600 frames from there);
  - a native replay's wait (G.replaySince) the same; a save with no word for 60 s lets the waits run again;
  - the save sets and clears the flag (also when it fails); a paused check waits for the save or a replay in the engine's hands.
Needs lupa. Run: python tests/test_savebusy0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r"^G\.saveBusyOn = function.*?^G\.saveBusyNow = function\(\)\n.*?^end\n", src, re.S | re.M)
check("the save's functions found", m is not None)
if not m:
    sys.exit(1)
rs = src[src.index("H.resync_save = function(from, p)"):]
rs = rs[:rs.index("\nend\n")]
check("the save sets the flag before app.saveGame", rs.index("G.saveBusy = { frame = G.frames, clock = os.clock() }") < rs.index("pcall(app.saveGame"))
check("  and clears it when saved, and when it fails", rs.count("pcall(G.saveOver)") == 2)
rp = src[src.index("local function runPausedActions()"):]
rp = rp[:rp.index("\nend\n")]
check("the paused actions refresh the waits first, before nativeHoldAt", rp.index("G.saveBusyNow()") < rp.index("local natAt = nativeHoldAt()"))
check("a paused check waits for the save or a replay in the engine's hands (3600 frames at most)",
      'if a.kind == "hash" and a.at <= now and not creating and G.saveBusyOn and G.saveBusyOn() and (saving or (G.replayOut or 0) > 0 or G.frames < (G.replayQuiet or 0)) then' in rp
      and "if G.frames - a.engWait < 3600 then" in rp)


def model(off):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\nCLOCK = 100\nos.clock = function() return CLOCK end\nLOGS = {}\nfunction log(s) LOGS[#LOGS + 1] = s end\nG = { frames = 66230 }\n" + m.group(0))
    run = L.eval("function(code) return assert(load(code))() end")
    if off:
        run("ENV.MPFEVER_SAVEBUSY = '0'")
    # the line handed to the engine at frame 66230, the save starting in the same frame (as in H.resync_save)
    run("G.pausedCreating = { uid = 'Eier#1:181', frame = G.frames }; G.replayOut = 1; G.replaySince = G.frames")
    run("if G.saveBusyOn() then G.saveBusy = { frame = G.frames, clock = os.clock() } end")
    expired_at = None
    for f in range(1, 16 * 60 + 1):                     # 16 s of save, a frame each 1/60 s
        run(f"G.frames = G.frames + 1; CLOCK = 100 + {f} / 60; G.saveBusyNow()")
        if expired_at is None and run("return G.frames - G.pausedCreating.frame >= 600"):
            expired_at = f
    run("G.saveOver()")
    after = run("return G.frames - G.pausedCreating.frame")
    rep = run("return G.frames - G.replaySince")
    return expired_at, after, rep, run


exp, after, rep, run = model(True)
check("MPFEVER_SAVEBUSY=0: the line's wait runs out at 600 frames, during the save (the bug)", exp == 600, exp)
exp, after, rep, run = model(False)
check("now: still waited for at the end of a 16 s save", exp is None, exp)
check("  started again once it is over (0 frames old)", after == 0, after)
check("  the native replay's wait too", rep == 0, rep)
run("G.saveBusy = { frame = G.frames, clock = CLOCK - 61 }")
check("a save with no word for 60 s: the waits run again (said)", run("return G.saveBusyNow()") is False and any("60 s" in x for x in run("return LOGS").values()))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
