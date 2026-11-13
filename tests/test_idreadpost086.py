"""Offline test: a build's ids ("build ids", check part buildIds) are read as soon as the engine has applied that build (0.8.6;
SIM.idResolve and the onPostBuildProposal handler in mod/mpfever_1/content/mpfever_bridge.script.lua).

#274 (Peter and Jakob, 2026-11-12 21:49:43): with Responsive builds, Peter's next build landed two steps after his build at
t=29110400 and split one of its segments before the read "two steps after": Peter's game read "-1", Jakob's the segment 130828.
"buildIds" then told a difference that was none, 49 minutes before the real drift, on every check of the session.
  - the "post" read takes the builds of this step only, at once (no waiting two steps);
  - a build of an earlier step is not read by the "post" read (it was read at its own step);
  - the old reads are unchanged: two steps after, or before the next captured build (force);
  - the onPostBuildProposal handler calls the "post" read; MPFEVER_IDREADPOST=0: it does not (as before);
  - the "build ids" line itself is unchanged (the games' logs are compared line by line).
Needs lupa (pip install lupa). Run: python tests/test_idreadpost086.py
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


src = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
a = src.index("SIM.idReadPost = function()")
b = src.index("local function captureNativeBuild(state, param)")
code = src[a:b]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
STEP = 200
NOW = 0
gameTime = function() return NOW end
LOGS = {}
log = function(s) LOGS[#LOGS + 1] = s end
SEGS = {}
R = { idsAt = function(segs, nodes) local t = {} for i, s in ipairs(segs) do t[i] = SEGS[s] or -1 end return t, {} end, nameOf = function() return "" end }
api = { type = { ComponentType = {} }, engine = { getComponent = function() return nil end } }
C = { hashStr = function(h, s) return #s end }
STATE = {}
state = { get = function() return STATE end, set = function(self, v) STATE = v end }
setmetatable(state, { __index = function(t, k) if k == "get" then return function() return STATE end end end })
state.get = function() return STATE end
state.set = function(_, v) STATE = v end
SIM = {}
''' + code)


def run(lua):
    L.execute("LOGS = {}")
    L.execute(lua)
    return [L.eval("LOGS[%d]" % i) for i in range(1, int(L.eval("#LOGS")) + 1)]


# a build at t=29110400 with 4 segments, the 4th split away later
L.execute('SEGS = { a = 105735, b = 130822, c = 130826, d = 130828 }')
L.execute('NOW = 29110400; SIM.idChecks = { { at = 29110400, segs = { "a", "b", "c", "d" }, nodes = {}, ticks = 0 } }')
logs = run('SIM.idResolve(state, "post")')
line = next((l for l in logs if l.startswith("build ids t=29110400")), "")
check("130828" in line and "-1" not in line, "the post read takes this step's build at once, before anything changes", line)
check(L.eval("SIM.idChecks") is None, "read once: the build leaves the list")

L.execute('NOW = 29110800; SIM.idChecks = { { at = 29110400, segs = { "a" }, nodes = {}, ticks = 0 } }')
logs = run('SIM.idResolve(state, "post")')
check(not any(l.startswith("build ids") for l in logs), "the post read leaves a build of an earlier step alone")
logs = run('SIM.idResolve(state, false)')
check(any(l.startswith("build ids t=29110400") for l in logs), "the old read two steps after is unchanged")

L.execute('NOW = 29110600; SIM.idChecks = { { at = 29110400, segs = { "a" }, nodes = {}, ticks = 0 } }')
logs = run('SIM.idResolve(state, false)')
check(not any(l.startswith("build ids") for l in logs), "the old read waits two steps")
logs = run('SIM.idResolve(state, true)')
check(any(l.startswith("build ids t=29110400") for l in logs), "the old forced read (before the next build) is unchanged")

check(L.eval("SIM.idReadPost()") is True, "on by default")
L.execute('ENV.MPFEVER_IDREADPOST = "0"')
check(L.eval("SIM.idReadPost()") is False, "MPFEVER_IDREADPOST=0: off")

h = src.index('if id == "apply_command" and name == "onPostBuildProposal" then')
check('if SIM.idChecks and SIM.idReadPost() then pcall(SIM.idResolve, state, "post") end' in src[h:h + 1200],
      "the onPostBuildProposal handler calls the post read")
check('log("build ids t=" .. ck.at .. ": segments " .. table.concat(si, ",") .. " nodes " .. table.concat(ni, ",") .. " (node configurations " .. cfg .. ")" .. nms)' in code,
      "the build ids line itself is unchanged")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
