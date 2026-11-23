"""Offline test: a mod's command that another game sends still gets its callback on this game (0.9.4, MPFEVER_GSDROPCB;
G.gsDropAnswer and G.installGsMods in mod/mpfever_1/content/mpfever_bridge.script.lua, the "drop" branch of the interface's
sendCommand in mod/mpfever_1/content/mpfever_ui.script.lua).

The bug (Roadcraft Speed Limits, sessions of 2026-11-19 and 2026-11-20, issues #447/#449 reports): the mod's game script sends
its jobs with api.cmd.sendCommand and waits for the callback. On a client, MPFever's rules (mpfever_modauto.lua) leave such a
command to the host's game ("not sent from this game: the host's game sends it"), or drop it during a resynchronisation: the
command was neither shipped nor applied here, and its callback was never called. The mod then said "Batch journal failed; reload
the save to recover before further edits. Batch command callback did not arrive" and stopped.
The fix: the callback is called on the next frame, a success when another game sends the same command (applied on every game,
this one too), a failure when the resynchronisation drops it.

  part 1, the bug (MPFEVER_GSDROPCB=0): the client's command dropped, frames go by, the callback never comes;
  part 2, the fix: the same command answered on the next frame (not inside sendCommand), with a success, once; during a
  resynchronisation a failure; a mod whose callback fails: logged, nothing breaks; with no frame queue, answered at once;
  a command this game ships is still answered only when it is applied (G.gsAnswer);
  part 3, the interface's own hook: its dropped commands answered the same way, on the next poll.
Needs lupa (pip install lupa). Run: python tests/test_gsdropcb094.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read()
i = bridge.find("G.gsHook = function()")
j = bridge.find("\nend\n", bridge.find("G.gsAnswer = function(r)", i)) + 5
check(i > 0 and j > i, "G.installGsMods found")
code = bridge[i:j]
modauto = open(os.path.join(CONTENT, "mpfever_modauto.lua"), encoding="utf-8").read()

RC = "@roadcraft_speed_limits::/scripts/speed_sign_manager.lua"


def runtime(role="client", env=None, frames=True):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
    ENV = {}
    os.getenv = function(k) return ENV[k] end
    LINES, LOG, NATIVE = {}, {}, {}
    function log(s) LOG[#LOG + 1] = s end
    BS = "/"
    MODAUTO = (function() %s end)()
    function ug_require(p) if p == "mpfever_modauto.lua" then return MODAUTO end error("no " .. p) end
    ORIG = { }
    C = { ROLE = "%s", ACTIVE = true, NAME = "Knight-HD2", DIR = "D",
      FACTORIES = { "makeScriptingSendEventCmd", "makeGameSetSpeedCmd" },
      origCmds = function() return ORIG end,
      marshal = function(v) return v end,
      appendFile = function(path, line) LINES[#LINES + 1] = { path = path, line = line } return true end,
      line = function(kind, p) return { kind = kind, p = p } end }
    R = { CO = { mode = "shared" }, translateOut = function() end, ownerOf = function() return nil end }
    CO = { idOfEntity = function(reg, e) return e end }
    G = { myCo = 1, rev = {}, session = {} }
    local function factory(name) return function(...) return { cmd = name, args = { ... } } end end
    api = { cmd = { makeScriptingSendEventCmd = factory("event"), makeGameSetSpeedCmd = factory("speed") } }
    api.cmd.sendCommand = function(cmd, cb) NATIVE[#NATIVE + 1] = cmd.cmd; if cb then cb("native", true) end end
    ORIG.sendCommand = api.cmd.sendCommand
    STACK = {}
    debug = { getinfo = function(lv, what) local s = STACK[lv - 2] if not s then return nil end return { source = s, what = s == '=[C]' and 'C' or 'Lua' } end }
    ''' % (modauto, role))
    if frames:
        # the bridge's frame queue (G.waits, G.frames, run by G.guiUpdateBody)
        L.execute('''
        G.waits, G.frames = {}, 0
        function FRAME()
          G.frames = G.frames + 1
          local cur = G.waits
          G.waits = {}
          for _, w in ipairs(cur) do if G.frames >= w.at then w.fn() else G.waits[#G.waits + 1] = w end end
        end''')
    for k, v in (env or {}).items():
        L.execute('ENV["%s"] = "%s"' % (k, v))
    L.execute(code)
    L.execute("G.installGsMods()")
    return L


def send(L, cb="function(a, ok) CALLS = (CALLS or 0) + 1; ANSWER = { a = a, ok = ok } end"):
    """Roadcraft's game script sends one of its jobs by itself (no player's action in the last 15 s)."""
    L.execute('STACK = { "%s", "%s" }' % (RC, RC))
    L.execute('package.loaded["mpfever_local_activity"] = os.clock() - 60')
    L.execute("ANSWER, CALLS = nil, 0")
    L.execute('api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("roadcraft_speed_limits::/roadcraft_speed_lifecycle.gs", '
              '"RoadcraftSpeedLifecycle", "batch", {}), %s)' % cb)


# ---- part 1: the bug
L = runtime(env={"MPFEVER_GSDROPCB": "0"})
send(L)
for _ in range(600):
    L.execute("FRAME()")
check(len(L.eval("LINES")) == 0 and len(L.eval("NATIVE")) == 0, "bug: on a client, Roadcraft's job is left to the host's game (neither shipped nor applied here)")
check(L.eval("ANSWER") is None, "bug reproduced (MPFEVER_GSDROPCB=0): 600 frames later its callback has not come (\"Batch command callback did not arrive\")")
check(any("not sent from this game: the host's game sends it" in s for s in L.eval("LOG").values()), "  the log line of the reports")

# ---- part 2: the fix
L = runtime()
send(L)
check(len(L.eval("LINES")) == 0 and len(L.eval("NATIVE")) == 0, "fix: still left to the host's game, nothing applied here twice")
check(L.eval("ANSWER") is None, "  not answered inside sendCommand (the mod may set its state after the call)")
L.execute("FRAME()")
check(L.eval("ANSWER") is not None and L.eval("ANSWER.ok") is True, "  answered on the next frame with a success (the host's copy is applied on every game)")
for _ in range(60):
    L.execute("FRAME()")
check(L.eval("CALLS") == 1, "  answered once", L.eval("CALLS"))
check(len(L.eval("G.waits")) == 0, "  nothing left waiting")

L = runtime(role="host")
L.execute("G.session.resync = true")
send(L)
L.execute("FRAME()")
check(len(L.eval("LINES")) == 0 and L.eval("ANSWER") is not None and L.eval("ANSWER.ok") is False,
      "during a resynchronisation (dropped everywhere): answered with a failure")

L = runtime()
send(L, cb='function() error("mod bug") end')
L.execute("FRAME()")
check(any("failed in the mod: " in s and "mod bug" in s for s in L.eval("LOG").values()), "a mod whose callback fails: logged, nothing breaks")

L = runtime(frames=False)
send(L)
check(L.eval("ANSWER") is not None and L.eval("ANSWER.ok") is True, "no frame queue in this state: answered at once")

L = runtime()
send(L, cb="nil")
L.execute("FRAME()")
check(len(L.eval("G.waits")) == 0, "a command sent with no callback: nothing to answer")

L = runtime(role="host")
send(L)
L.execute("FRAME()")
lines = L.eval("LINES")
check(len(lines) == 1 and lines[1].line.kind == "act_req", "the host's game ships it as before")
check(L.eval("ANSWER") is None, "  and its callback waits for it to be applied, as before")
L.execute('G.gsAnswer({ tok = package.loaded["mpfever_gs_hook"].tok, id = 1, success = true })')
check(L.eval("ANSWER") is not None and L.eval("ANSWER.ok") is True, "  answered when applied (G.gsAnswer)")

# ---- part 3: the interface's own hook
ui = open(os.path.join(CONTENT, "mpfever_ui.script.lua"), encoding="utf-8").read()
k = ui.find('if okA and verdict == "drop" then')
branch = ui[k:ui.find("\t\t\t\treturn", k)]
check(k > 0 and "U.later[#U.later + 1] = function()" in branch and "pcall(cb, nil, true, {})" in branch,
      "the interface's hook: a dropped command's callback queued for the next poll (U.later) with a success")
check('os.getenv("MPFEVER_GSDROPCB") ~= "0"' in branch, "  MPFEVER_GSDROPCB=0 there too")
p = ui.find("local function pollControl()")
check(p > 0 and "U.later" in ui[p:p + 300], "  pollControl runs U.later")
# the branch, run: the callback queued, called on the next poll only
Lu = lupa.LuaRuntime(unpack_returned_tuples=True)
Lu.execute('ENV = {}; os.getenv = function(k) return ENV[k] end; LOG = {}; function log(s) LOG[#LOG + 1] = s end; U = {}')
Lu.execute('function U.autoLog() end')
body = branch[branch.find("\n") + 1:]
Lu.execute("function DROP(tag, cb) local okA, verdict, facts, why = true, 'drop', {}, 'x'\n if true then\n" + body + "\nend end")
Lu.execute("ANSWER = nil; DROP({ name = 'makeScriptingSendEventCmd' }, function(a, ok) ANSWER = ok end)")
check(Lu.eval("ANSWER") is None and Lu.eval("#U.later") == 1, "  run: not answered at once, one answer queued")
Lu.execute("for _, fn in ipairs(U.later) do fn() end")
check(Lu.eval("ANSWER") is True, "  run: answered with a success on the next poll")
Lu.execute('ENV.MPFEVER_GSDROPCB = "0"; U.later = nil; DROP({ name = "x" }, function() end)')
check(Lu.eval("U.later") is None, "  run: MPFEVER_GSDROPCB=0, nothing queued")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
