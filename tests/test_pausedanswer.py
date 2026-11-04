"""Offline test of the paused checkpoints that wait for the engine's answer (0.6.13).

In a pause the engine applies a command at its next swap of the command list (every 200 ms). A line renamed just before a
checkpoint (by a player, or by Auto Line Namer's renames that only the host's game sends) was already renamed in one game's
hash and not yet in the other's: a "lines" difference that healed by itself at the next check (the 20:37 replay of
2026-11-04, twice). A paused checkpoint now waits until every paused action this game handed to the engine before it was
answered (at most 600 frames).

runPausedActions is taken from the real bridge file and run through lupa (Lua 5.2) with a mocked game. Cases: a rename and
a checkpoint due in the same frame: the checkpoint waits, and goes once the engine answered; an action after the waiting
checkpoint waits with it; MPFEVER_PAUSEDANSWER=0: the checkpoint goes in the same frame, as before; an answer that never
comes holds the checkpoint 600 frames at most.
Run: python tests/test_pausedanswer.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
NOW = 100000
LOGS, SENT, APPLIED, CBS = {}, {}, {}, {}
BS, NL = "\\", "\n"
function gameTime() return NOW end
function gameSpeed() return 0 end
function nativeHoldAt() return nil end
function log(s) LOGS[#LOGS + 1] = s end
function toSim() end
function send(kind, p) SENT[#SENT + 1] = kind .. ":" .. tostring(p.n) end
function authValues() return {} end
function simHash() return {} end
function coIsLoanEvent() return false end
function PL(a) return nil end
function before(x, y) return x.at < y.at or (x.at == y.at and x.seq < y.seq) end
function withActor(_, fn, ...) return fn(...) end
function executeAction(a, sendCommand, useCallback, bind, done)
  APPLIED[#APPLIED + 1] = a.uid
  CBS[#CBS + 1] = function() done({ uid = a.uid, fn = a.fn, success = true }) end
  return {}
end
O = { sendCommand = function() end }
K = { nameSyncOn = function() return false end }
C = { makesProposal = function() return false end, appendFile = function() end, line = function() return "" end, DIR = "x" }
G = { frames = 1000, pendingPaused = {}, nativeQueue = {}, session = {}, resultsSeen = {},
  actTurn = function() return nil end, nstopOk = function() return false end, isWorldAct = function() return false end,
  reportResult = function() end, rebind = function() end, me = "host" }
function reset()
  LOGS, SENT, APPLIED, CBS = {}, {}, {}, {}
  G.pausedOut, G.pausedCreating, G.ansHashWaitLogged = nil, nil, nil
end
function frame(n) for _ = 1, (n or 1) do G.frames = G.frames + 1; runPausedActions() end end
function answerAll() local c = CBS; CBS = {}; for _, f in ipairs(c) do f() end end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m_fn = re.search(r"^local function runPausedActions\(\)\n.*?^end\n", src, re.S | re.M)
    if not m_fn:
        print("FAIL: runPausedActions not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    L.execute(m_fn.group(0).replace("local function runPausedActions", "function runPausedActions", 1))
    lua_run = L.eval("function(code) local f = assert(load(code)) return f() end")

    def run(code):
        try:
            return lua_run(code)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]

    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    queue = r'''
reset()
G.pendingPaused = {
  { uid = "mod:1", fn = "makeEntitySetNameCmd", at = NOW, seq = 1, origin = "host" },
  { kind = "hash", n = 7, at = NOW, seq = 2 },
  { uid = "p:2", fn = "makeEntitySetColorCmd", at = NOW, seq = 3, origin = "host" },
}
'''
    run("ENV = {}\n" + queue + "frame()")
    got = run("return #SENT .. ' ' .. table.concat(APPLIED, ',')")
    check("rename then checkpoint in one frame: the rename goes, the checkpoint waits", got == "0 mod:1", got)
    check("and the action after the checkpoint waits with it", run("return #G.pendingPaused") == 2, run("return #G.pendingPaused"))
    check("the wait is logged", any("waits for the engine's answer" in str(s) for s in L.globals().LOGS.values()))
    run("frame(3)")
    check("no answer yet: still waiting", run("return #SENT") == 0, run("return #SENT"))
    run("answerAll(); frame()")
    got = run("return table.concat(SENT, ',') .. ' ' .. table.concat(APPLIED, ',')")
    check("answered: the checkpoint goes, then the action after it", got == "sync_hash:7 mod:1,p:2", got)

    run("ENV = { MPFEVER_PAUSEDANSWER = '0' }\n" + queue + "frame()")
    got = run("return table.concat(SENT, ',') .. ' ' .. table.concat(APPLIED, ',')")
    check("MPFEVER_PAUSEDANSWER=0: the checkpoint goes in the same frame, as before", got == "sync_hash:7 mod:1,p:2", got)

    run("ENV = {}\n" + queue + "frame(); frame(598)")
    check("an answer that never comes: still waiting at 599 frames", run("return #SENT") == 0, run("return #SENT"))
    run("frame(2)")
    check("and the checkpoint goes after 600 frames", run("return SENT[1]") == "sync_hash:7", run("return SENT[1]"))

    run("ENV = {}\nreset()\nG.pendingPaused = { { kind = 'hash', n = 9, at = NOW, seq = 1 } }\nframe()")
    check("a checkpoint with nothing before it goes at once", run("return SENT[1]") == "sync_hash:9", run("return SENT[1]"))

    print("PASS" if not fails else f"FAIL ({len(fails)})")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
