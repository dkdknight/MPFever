"""Offline test of #168's order fix (0.7.13, MPFEVER_PTPULL; mod/mpfever_1/content/mpfever_bridge.script.lua: SIM.pullable,
SIM.ptPull, SIM.unqueue, the simulation's queue events, queueLocal, G.pullNote / pullPrune / pullNeeded / pullHold / pullApplied,
runPausedActions).

lukas' game, 2026-11-08 22:26: Philipp coloured 8 vehicles (Philipp#1:109-116), stamped t=38916200, two steps after the pause
point lukas had just asked for (t=38914200): they waited in every game's queue while the games stood. Philipp then sold the 8 in
the pause (Philipp#1:117, a paused action, turn 11): it was applied at once in its turn, lukas' paused builds took the freed ids,
and after the pause the colours went on track segments: the engine asserted HasComponent(Color) and the game stopped. Now a paused
action first applies its player's earlier actions still waiting in the queue, in the queue's order, in its own turn and at its time,
on every game; nothing changes for a paused action whose player has nothing waiting (the fast path: the same commands in the same
frames as with MPFEVER_PTPULL=0).

The real functions are taken from the bridge file and run through lupa (Lua 5.2), two games at once, each with its own mocked
simulation: the interface's commands go to the simulation in a list applied at its "swap" (every SW frames, a phase of its own), the
interface sees the simulation's state LAG frames after that. Cases: the #168 replay (both games: the colours, then the sale, then
lukas' action; out of the queue; known as applied); MPFEVER_PTPULL=0 (the #168 inversion, logged); the fast path (identical to
MPFEVER_PTPULL=0, frame for frame); a copy of the state 5 frames late; a game whose queue came from a savegame; the issue order (an
action made after the paused one stays, one of an earlier load or without a load goes); checkpoints during and before a pull;
purchases taken out of the queue (one at a time, their creation keys with their own stamps); an earlier action due at the pause
point, late, queued in the same command list as the question (the simulation's own update applies it, by simApplyDue's own rule
taken from the bridge: never pulled too, once on both games; a purchase held back by the one-purchase-per-step rule still pulled);
a simulation that never answers; a paused action of another player while a pull is under way, without turns (no deadlock); a
session resumed during a pull (the game held); paused builds (the diagnostic only); the source; and a port of the design's random
model (two games, random swaps, lags and message times, a savegame, PTPULL off and always asked).
Run: python tests/test_ptpull0713.py
"""
import os
import random
import re
import sys
import time

try:
    import lupa.lua52 as lupa
except ImportError:
    print("FAIL: lupa is not installed (pip install lupa)")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
SRC = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def grab(pattern, what):
    m = re.search(pattern, SRC, re.S | re.M)
    if not m:
        print(f"FAIL: {what} not found in the bridge")
        sys.exit(1)
    return m.group(0)


def globalise(code, name):
    return code.replace(f"local function {name}(", f"function {name}(", 1)


SIM_EVENTS = grab(r'^\t\tif name == "queue" then\n.*?(?=^\t\telseif name == "resume" then\n)', "the simulation's queue events")
GUI_COPY = grab(r"^\tG\.simQ, G\.simPulled = st\.q, st\.pulled\n\tpcall\(G\.pullPrune, st\)\n", "guiUpdate's copy of the queue")
# (simApplyDue's choice of the due actions, one purchase per step included: the mocked simulation's update applies those)
SIM_DUE = grab(r"^\t\tlocal due, keep, bought = \{\}, \{\}, false\n.*?^\t\tst\.q = keep\n", "simApplyDue's due actions")
CODE = "\n".join([
    globalise(grab(r"^local function before\(x, y\)\n.*?^end\n", "before"), "before"),
    globalise(grab(r"^local function doneKey\(a\)\n.*?^end\n", "doneKey"), "doneKey"),
    globalise(grab(r"^local function toSim\(name, param\)\n.*?^end\n", "toSim"), "toSim"),
    grab(r"^SIM\.pullable = function\(a, p\)\n.*?^SIM\.unqueue = function\(st, p, now\)\n.*?^end\n", "SIM.pullable .. SIM.unqueue"),
    "function simEvent(st, name, param)\n" + SIM_EVENTS + "\t\tend\nend\n",
    globalise(grab(r"^local function queueLocal\(a\)\n.*?^end\n", "queueLocal"), "queueLocal"),
    grab(r"^G\.pt = \{ next = 1.*?(?=^H\.nat_ticket = )", "the paused turns (G.pt)"),
    grab(r"^G\.actTurns = .*?^G\.actTurn = function\(a\)\n.*?^end\n", "G.actTurn"),
    grab(r"^G\.ptPullOn = .*?(?=^local function runPausedActions\(\)\n)", "G.ptPullOn .. G.pullBuildLog"),
    globalise(grab(r"^local function runPausedActions\(\)\n.*?^end\n", "runPausedActions"), "runPausedActions"),
    "function guiCopy(st)\n" + GUI_COPY + "end\n",
    "function simApply(st, now)\n\tlocal q = st.q or {}\n\tif #q == 0 then return end\n\ttable.sort(q, before)\n" + SIM_DUE
    + "\tst.doneUid = st.doneUid or {}\n\tfor _, a in ipairs(due) do\n\t\tlocal dk = doneKey(a)\n"
    + "\t\tif dk and st.doneUid[dk] then SIMSKIP[#SIMSKIP + 1] = a.uid\n"
    + "\t\telse if dk then st.doneUid[dk] = now end; simApplied(a) end\n\tend\nend\n",
])

MOCK = r'''
STEP = 200
os.getenv = function(k) return ENV[k] end
function deepcopy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[deepcopy(k)] = deepcopy(x) end
  return o
end
function gameTime() return NOW end
function gameSpeed() return 0 end
function nativeHoldAt() return nil end
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function send(kind, p) SENT[#SENT + 1] = kind .. ":" .. tostring(p.n); SEQ[#SEQ + 1] = "hash:" .. tostring(p.n); SENTFRAME[#SENTFRAME + 1] = G.frames end
function authValues() return {} end
function simHash() return {} end
function coIsLoanEvent() return false end
function PL() return nil end
function withActor(_, fn, ...) return fn(...) end
BS, NL = "\\", "\n"
-- (the engine: the command goes in the list, its answer comes at the simulation's swap; the creation key as executeActionOnce's)
function executeAction(a, sendCommand, useCallback, bind, done)
  local key = nil
  if a.fn == "makeVehicleBuyCmd" or a.fn == "makeLineCreateCmd" then key = (a.fn == "makeLineCreateCmd" and "L" or "V") .. tostring(a.uid) .. "@" .. tostring(a.at or "") end
  APPLIED[#APPLIED + 1] = a.uid
  APPFRAME[a.uid] = G.frames
  SEQ[#SEQ + 1] = "act:" .. tostring(a.uid)
  sendCommand({ name = "cmd", p = { uid = a.uid, fn = a.fn } }, function()
    ANSWERED[a.uid] = G.frames
    done({ uid = a.uid, fn = a.fn, success = true, created = key and { key = key, e = 900000 + #APPLIED } or nil })
  end)
  return { returned = true }
end
function boot(cfg)
  ENV = cfg.env or {}
  NOW = cfg.now
  LOGS, APPLIED, APPFRAME, ANSWERED, CREATED, SENT, SENTFRAME, SEQ, BATCHES, TRACE = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
  SIMAPPLIED, SIMSKIP = {}, {}
  FIFO, COPIES, ARR, TK, EVT = {}, {}, {}, {}, {}
  SW, PHASE, LAG, NOANSWER, VIOL = cfg.sw or 1, cfg.phase or 0, cfg.lag or 0, cfg.noanswer, 0
  ST = deepcopy(cfg.st or { q = {}, doneUid = {} })
  VIS = deepcopy(ST)
  SIM = {}
  C = { ROLE = "client", DIR = "D", copy = deepcopy, makesProposal = function() return false end, appendFile = function() end,
    line = function() return "" end }
  O = { event = function(a, b, name, p) return { name = name, p = p } end,
    sendCommand = function(cmd, cb)
      FIFO[#FIFO + 1] = { name = cmd.name, p = cmd.p, cb = cb }
      local p = cmd.p or {}
      TRACE[#TRACE + 1] = G.frames .. " " .. tostring(cmd.name) .. " " .. tostring(p.uid or p.dk or p.tok or p.at)
    end }
  K = { nameSyncOn = function() return false end }
  SDUMP, R, H = {}, {}, { auth = function() end }
  G = { frames = 1000, pendingPaused = {}, nativeQueue = {}, session = { pauseAt = cfg.pauseAt or NOW, speed = 2 }, resultsSeen = {},
    me = cfg.me or "host", epoch = cfg.epoch or 5000, qLedger = {}, pulledDk = {}, pullAdd = {}, bind = {}, peers = {},
    nstopOk = function() return false end, isWorldAct = function() return false end, reportResult = function() end,
    rebind = function(key, e) CREATED[#CREATED + 1] = key end }
  assert(load(CODE, "=bridge"))()
  if cfg.watch then
    local real = G.pullNeeded
    G.pullNeeded = function(p)
      local r = real(p)
      if not r and trueNeeded(p) then VIOL = VIOL + 1 end
      return r
    end
  end
end
-- (what the simulation's queue really holds once the commands sent are applied: the fast path may never miss one)
function trueNeeded(p)
  local q, done = deepcopy(ST.q or {}), ST.doneUid or {}
  for _, e in ipairs(FIFO) do
    if e.name == "queue" then
      local k = doneKey(e.p)
      local dup = k and done[k]
      for _, x in ipairs(q) do if k and doneKey(x) == k then dup = true end end
      if not dup then q[#q + 1] = e.p end
    elseif e.name == "unqueue" then
      local keep = {}
      for _, x in ipairs(q) do if doneKey(x) ~= e.p.dk then keep[#keep + 1] = x end end
      q = keep
    end
  end
  for _, x in ipairs(q) do if SIM.pullable(x, p) then return true end end
  return false
end
-- (an action the simulation's update applies: applied too, by the simulation)
function simApplied(a)
  APPLIED[#APPLIED + 1] = a.uid
  SIMAPPLIED[#SIMAPPLIED + 1] = a.uid
  SEQ[#SEQ + 1] = "sim:" .. tostring(a.uid)
end
function pump()
  local fifo = FIFO
  FIFO = {}
  BATCHES[#BATCHES + 1] = fifo
  for _, e in ipairs(fifo) do
    if e.name ~= "cmd" and not (NOANSWER and e.name == "pt_pull") then simEvent(ST, e.name, deepcopy(e.p)) end
    if e.cb then e.cb() end
  end
  -- (then the simulation's update, the game standing at NOW: its due actions, see simApplyDue)
  simApply(ST, NOW)
  COPIES[#COPIES + 1] = { at = G.frames + LAG, st = deepcopy(ST) }
end
function deliver(m)
  local a = deepcopy(m)
  if a.kind == "hash" then
    G.pendingPaused[#G.pendingPaused + 1] = { kind = "hash", n = a.n, at = a.at, origin = "", oseq = -1 }
  else
    queueLocal(a)
  end
end
function frame()
  G.frames = G.frames + 1
  local f = G.frames
  for _, fn in ipairs(EVT[f] or {}) do fn() end
  for _, m in ipairs(ARR[f] or {}) do deliver(m) end
  for _, t in ipairs(TK[f] or {}) do G.ptTicket(t.origin, t.id, t.seq) end
  while COPIES[1] and COPIES[1].at <= f do VIS = table.remove(COPIES, 1).st end
  guiCopy(VIS)
  runPausedActions()
  if (f + PHASE) % SW == 0 then pump() end
end
function runFrames(n) for _ = 1, n do frame() end end
function arrive(f, list) ARR[f] = ARR[f] or {}; for _, m in ipairs(list) do table.insert(ARR[f], m) end end
function ticket(f, a, seq) TK[f] = TK[f] or {}; table.insert(TK[f], { origin = a.origin, id = G.actTurnId(a), seq = seq }) end
function at(f, fn) EVT[f] = EVT[f] or {}; table.insert(EVT[f], fn) end
function has(list, pat) for _, s in ipairs(list) do if tostring(s):find(pat, 1, true) then return true end end return false end
function count(list, pat) local n = 0; for _, s in ipairs(list) do if tostring(s):find(pat, 1, true) then n = n + 1 end end return n end
function inQ(uid) for _, x in ipairs(ST.q or {}) do if x.uid == uid then return true end end return false end
function join(t) local o = {}; for i, x in ipairs(t) do o[i] = tostring(x) end; return table.concat(o, ",") end
-- (the batch and place of a command: an action taken out of the queue leaves it in the same list as its command, before it)
function where(name, key)
  for b, fifo in ipairs(BATCHES) do
    for i, e in ipairs(fifo) do
      if e.name == name and e.p and (e.p.uid == key or e.p.dk == key) then return b, i end
    end
  end
  return nil
end
'''


def lua(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(lua(x) for x in v) + "}"
    return "{" + ", ".join(f"[{lua(k)}] = {lua(x)}" for k, x in v.items()) + "}"


class Game:
    def __init__(self):
        self.L = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(MOCK)
        self.L.globals().CODE = CODE

    def boot(self, **cfg):
        self.L.execute("boot(" + lua(cfg) + ")")
        return self

    def run(self, code):
        try:
            return self.L.execute(code)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]

    def ev(self, expr):
        try:
            return self.L.eval(expr)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]

    def arrive(self, f, *msgs):
        self.run(f"arrive({f}, {lua(list(msgs))})")

    def ticket(self, f, a, seq):
        self.run(f"ticket({f}, {lua(a)}, {seq})")

    def frames(self, n):
        r = self.run(f"runFrames({n})")
        if isinstance(r, str) and r.startswith("LUA ERROR"):
            check("no Lua error", False, r)

    def applied(self):
        return list(self.L.eval("APPLIED").values())

    def logs(self):
        return list(self.L.eval("LOGS").values())


T = 38914200
STEP = 200
S = T + 10 * STEP
E = 1762636000
X = "Philipp#1"
COLOURS = [{"uid": f"{X}:{109 + i}", "origin": X, "oseq": 109 + i, "ep": E, "at": S, "fn": "makeEntitySetColorCmd",
            "args": {"n": 2, 1: {"__ref": True, "key": f"V{X}:{93 + i}@38900000"}, 2: {"x": 1, "y": 0, "z": 0}}} for i in range(8)]
SALE = {"uid": f"{X}:117", "origin": X, "oseq": 117, "ep": E, "at": T, "paused": True, "fn": "makeVehicleSellCmd", "args": {"n": 1, 1: [1, 2]}}
LUKAS = {"uid": "lukas:50", "origin": "lukas", "oseq": 50, "ep": 77, "at": T, "paused": True, "fn": "makeLineUpdateCmd", "args": {"n": 2}}
CUIDS = [c["uid"] for c in COLOURS]
GA, GB = Game(), Game()


def replay168(g, env=None, lag=0, sw=1, phase=0, colours=COLOURS):
    g.boot(now=T, env=env or {}, lag=lag, sw=sw, phase=phase, me="lukas")
    if colours:
        g.arrive(1001, *colours)
    g.arrive(1002, SALE)
    g.arrive(1003, LUKAS)
    g.ticket(1004, SALE, 11)
    g.ticket(1005, LUKAS, 12)
    g.frames(150)
    return g


def case_168():
    print("-- #168 replayed: the colours waiting for t=38916200, then the paused sale (turn 11), then lukas' paused action (turn 12)")
    a = replay168(GA)
    b = replay168(GB, lag=4, sw=3, phase=1)
    want = CUIDS + [SALE["uid"], LUKAS["uid"]]
    check("game A: the colours, then the sale, then lukas' action", a.applied() == want, a.applied())
    check("game B (another swap phase, its copy 4 frames late): the same order", b.applied() == a.applied(), b.applied())
    for g, n in ((a, "A"), (b, "B")):
        check(f"game {n}: no colour of Philipp left in the simulation's queue", not any(g.ev(f'inQ("{u}")') for u in CUIDS))
        check(f"game {n}: each colour known as applied under its own key (uid@38916200: the simulation would skip it)",
              all(g.ev(f'ST.doneUid["{u}@{S}"] == {T}') for u in CUIDS))
        check(f"game {n}: each one out of the queue in the same command list as its command, before it",
              all(g.ev(f'(function() local b1, i1 = where("unqueue", "{u}@{S}"); local b2, i2 = where("cmd", "{u}"); return b1 ~= nil and b1 == b2 and i1 < i2 end)()')
                  for u in CUIDS))
        logs = g.logs()
        check(f"game {n}: mod.log says so ('ORDER: paused action {SALE['uid']} ... 8 earlier action(s) ... go first')",
              any(f"ORDER: paused action {SALE['uid']} of {X}: its 8 earlier action(s)" in s for s in logs))
        oks = [s for s in logs if s.startswith("paused action ") and s.endswith("-> OK")]
        check(f"game {n}: 'paused action ... at t={T} -> OK' for the 8 colours before the sale's",
              [s.split(" ")[2] for s in oks] == want and all(f"at t={T}" in s for s in oks), oks)
        check(f"game {n}: asked once, nothing left over (no pull under way, nothing pending, the game no longer held)",
              g.ev('count(TRACE, " pt_pull ")') == 1 and g.ev("G.pull == nil and #G.pendingPaused == 0 and G.holdAt == nil and #G.pullAdd == 0"))
        check(f"game {n}: the simulation's answer cleared (pt_pull_done)", g.ev("ST.pulled == nil"))


def case_off():
    print("-- MPFEVER_PTPULL=0: as in 0.7.12 (the #168 inversion)")
    a = replay168(GA, env={"MPFEVER_PTPULL": "0"})
    check("the sale and lukas' action at once in their turns, the colours not", a.applied() == [SALE["uid"], LUKAS["uid"]], a.applied())
    check("the colours still wait in the queue for t=38916200 (after the pause, on the freed ids)", all(a.ev(f'inQ("{u}")') for u in CUIDS))
    check("logged: 'ORDER: paused action ... goes before earlier action(s) ... (MPFEVER_PTPULL=0)'",
          any("ORDER: paused action Philipp#1:117 goes before earlier action(s) of Philipp#1" in s and "(MPFEVER_PTPULL=0)" in s for s in a.logs()))
    check("nothing asked of the simulation", a.ev('count(TRACE, " pt_pull ") + count(TRACE, " unqueue ")') == 0)


def fast_run(g, env, extra_st=None, lukas_q=False, hash_too=False):
    g.boot(now=T, env=env, lag=2, sw=3, phase=2, me="lukas", st=extra_st)
    msgs = []
    if lukas_q:
        msgs = [{"uid": f"Anna:{40 + i}", "origin": "Anna", "oseq": 40 + i, "ep": 77, "at": S, "fn": "makeLineUpdateCmd"} for i in range(3)]
        g.arrive(1001, *msgs)
    g.arrive(1002, SALE)
    g.arrive(1003, LUKAS)
    if hash_too:
        g.arrive(1006, {"kind": "hash", "n": 7, "at": T})
    g.ticket(1004, SALE, 11)
    g.ticket(1005, LUKAS, 12)
    g.frames(60)
    return (g.ev("join(TRACE)"), g.ev("join(APPLIED)"), g.ev("APPFRAME[\"" + SALE["uid"] + "\"]"), g.ev("join(SENT)"), g.ev("join(SENTFRAME)"))


def case_fast():
    print("-- the fast path: nothing of the player waiting, every paused action as with MPFEVER_PTPULL=0, frame for frame")
    for label, kw in (("nothing queued", {}), ("only the actions of a player with no paused action queued", {"lukas_q": True}),
                      ("the player's earlier action already applied (known as such by the simulation)",
                       {"extra_st": {"q": [], "doneUid": {f"{X}:100@{T}": T}}}),
                      ("with a checkpoint", {"hash_too": True, "lukas_q": True})):
        on = fast_run(GA, {}, **kw)
        off = fast_run(GB, {"MPFEVER_PTPULL": "0"}, **kw)
        check(f"{label}: the same commands in the same frames, the same actions in the same frames", on == off, f"{on} / {off}")
        check(f"{label}: no question to the simulation", " pt_pull " not in on[0] and " unqueue " not in on[0])
        check(f"{label}: the sale and lukas' action applied", on[1] == f"{SALE['uid']},{LUKAS['uid']}", on[1])
    on = fast_run(GA, {"MPFEVER_PTPULLFAST": "0"})
    check("MPFEVER_PTPULLFAST=0 (diagnostic): asked every time, the answer empty, the same actions",
          " pt_pull " in on[0] and on[1] == f"{SALE['uid']},{LUKAS['uid']}", on)


def case_lag():
    print("-- the colours, the sale and its turn in one frame, game B's copy of the state 5 frames late")
    res = []
    for g, lag, sw in ((GA, 0, 1), (GB, 5, 2)):
        g.boot(now=T, lag=lag, sw=sw, phase=1, me="host")
        g.arrive(1001, *COLOURS, SALE, LUKAS)
        g.ticket(1001, SALE, 11)
        g.ticket(1001, LUKAS, 12)
        g.frames(100)
        res.append(g.applied())
    want = CUIDS + [SALE["uid"], LUKAS["uid"]]
    check("the queue events not seen in the copy yet are noted: the pull is asked on both games", res[0] == want and res[1] == want, res)


def case_resync():
    print("-- a game whose queue came from a savegame (a resynchronisation): the same order")
    a = replay168(GA)
    sale2 = dict(SALE, uid=f"{X}:3", oseq=3, ep=E + 100)
    GB.boot(now=T, lag=3, sw=4, phase=0, me="host", epoch=E + 200, st={"q": COLOURS, "doneUid": {}})
    check("the reloaded game notes nothing: its queue is the savegame's, in its copy from the start", GB.ev("next(G.qLedger) == nil and #VIS.q == 8"))
    GB.arrive(1002, sale2)
    GB.arrive(1003, LUKAS)
    GB.ticket(1004, sale2, 11)
    GB.ticket(1005, LUKAS, 12)
    GB.frames(120)
    check("after the load (new load, number 3): the colours of the earlier load first, then the sale, then lukas'",
          GB.applied() == CUIDS + [sale2["uid"], LUKAS["uid"]], GB.applied())
    check("the same order as on the game that never reloaded", [u for u in GB.applied() if u != sale2["uid"]] == [u for u in a.applied() if u != SALE["uid"]])


def case_issue_order():
    print("-- the issue order: by load, then by number")
    old = {"uid": f"{X}:500", "origin": X, "oseq": 500, "ep": E - 100, "at": S - 5 * STEP, "fn": "makeVehicleSetLineCmd"}
    noep = {"uid": f"{X}:900", "origin": X, "oseq": 900, "at": S, "fn": "makeEntitySetNameCmd"}
    after = {"uid": f"{X}:118", "origin": X, "oseq": 118, "ep": E, "at": S + STEP, "fn": "makeEntitySetNameCmd"}
    g = GA.boot(now=T, lag=1, sw=2, phase=0, me="host", st={"q": [old, noep], "doneUid": {}})
    g.arrive(1001, *COLOURS)
    g.arrive(1002, SALE)
    g.arrive(1003, after)
    g.ticket(1010, SALE, 11)
    g.frames(100)
    check("an earlier load's action (its number 500) and one without a load go, in the queue's order; the one made after the sale stays",
          g.applied() == [old["uid"]] + CUIDS + [noep["uid"], SALE["uid"]] and g.ev(f'inQ("{after["uid"]}")'), g.applied())
    pull = lambda a, p: GA.ev(f"SIM.pullable({lua(a)}, {lua(p)})")
    P = {"origin": X, "ep": E, "oseq": 117}
    check("SIM.pullable: same player, same load, smaller number: yes", pull({"origin": X, "ep": E, "oseq": 116}, P) is True)
    check("  a bigger number: no", pull({"origin": X, "ep": E, "oseq": 118}, P) is False)
    check("  an earlier load, a bigger number: yes; a later load: no",
          pull({"origin": X, "ep": E - 1, "oseq": 999}, P) is True and pull({"origin": X, "ep": E + 1, "oseq": 1}, P) is False)
    check("  no load (a queue older than 0.7.13): earlier", pull({"origin": X, "oseq": 999}, P) is True)
    check("  another player: no", pull({"origin": "lukas", "ep": E, "oseq": 1}, P) is False)
    check("  a checkpoint, a company join, a build: no",
          pull({"origin": X, "ep": E, "oseq": 1, "kind": "hash"}, P) is False and pull({"origin": X, "ep": E, "oseq": 1, "fn": "mpfCoJoin"}, P) is False
          and pull({"origin": X, "ep": E, "oseq": 1, "native": True}, P) is False)
    check("  a rank taken (applyLevel, no paused form): no; another script event: yes",
          pull({"origin": X, "ep": E, "oseq": 1, "fn": "makeScriptingSendEventCmd", "args": ["", "Companies", "applyLevel", {}]}, P) is False
          and pull({"origin": X, "ep": E, "oseq": 1, "fn": "makeScriptingSendEventCmd", "args": ["", "Loan", "Obtain", {}]}, P) is True)


def case_checkpoints():
    print("-- checkpoints")
    g = GB.boot(now=T, lag=2, sw=4, phase=0, me="host")
    g.arrive(1001, *COLOURS)
    g.arrive(1002, SALE)
    g.ticket(1003, SALE, 11)
    g.arrive(1004, {"kind": "hash", "n": 7, "at": T})
    g.frames(80)
    seq = list(g.L.eval("SEQ").values())
    check("a checkpoint due while the pull is under way waits until the sale is applied (and answered): it never reads half of it",
          seq == ["act:" + u for u in CUIDS + [SALE["uid"]]] + ["hash:7"], seq)
    check("  logged: 'checkpoint 7 waits for the actions applied before a paused action'",
          any("checkpoint 7 waits for the actions applied before a paused action" in s for s in g.logs()))
    res = []
    for env in ({}, {"MPFEVER_PTPULL": "0"}):
        g = GA.boot(now=T, env=env, lag=0, sw=2, phase=1, me="host")
        g.arrive(1001, *COLOURS)
        g.arrive(1002, SALE)
        g.arrive(1003, {"kind": "hash", "n": 8, "at": T})
        g.ticket(1003, SALE, 11)
        g.frames(80)
        res.append((list(g.L.eval("SEQ").values()), g.ev("SENTFRAME[1]")))
    check("a checkpoint due in the frame the pull starts, before it: it goes first, in the same frame as with MPFEVER_PTPULL=0",
          res[0][0][0] == "hash:8" and res[1][0][0] == "hash:8" and res[0][1] == res[1][1] and res[0][0][1:] == ["act:" + u for u in CUIDS + [SALE["uid"]]],
          res)


def case_buys():
    print("-- purchases taken out of the queue")
    buys = [{"uid": f"{X}:{120 + i}", "origin": X, "oseq": 120 + i, "ep": E, "at": S, "fn": "makeVehicleBuyCmd", "args": {"n": 3}} for i in range(3)]
    sale = dict(SALE, uid=f"{X}:130", oseq=130)
    g = GA.boot(now=T, lag=1, sw=3, phase=0, me="host")
    g.arrive(1001, *buys)
    g.arrive(1002, sale)
    g.ticket(1003, sale, 11)
    g.frames(120)
    fr = {u: g.ev(f'APPFRAME["{u}"]') for u in [b["uid"] for b in buys] + [sale["uid"]]}
    an = {u: g.ev(f'ANSWERED["{u}"]') for u in [b["uid"] for b in buys]}
    check("the three purchases, then the sale", g.applied() == [b["uid"] for b in buys] + [sale["uid"]], g.applied())
    check("one at a time: each purchase after the engine's answer to the one before, the sale after the last answer",
          fr[buys[1]["uid"]] >= an[buys[0]["uid"]] and fr[buys[2]["uid"]] >= an[buys[1]["uid"]] and fr[sale["uid"]] >= an[buys[2]["uid"]]
          and fr[buys[0]["uid"]] < fr[buys[1]["uid"]] < fr[buys[2]["uid"]], (fr, an))
    created = list(g.L.eval("CREATED").values())
    check("their creation keys keep their own stamps: V<uid>@38916200, as without the pull",
          created == [f"V{b['uid']}@{S}" for b in buys], created)
    ck = 'local ckey = createdKey and (createdKey .. tostring(a.uid) .. "@" .. tostring(a.at or ""))'
    check("(the bridge's creation key is made that way: V/L<uid>@<the action's stamp>)", ck in SRC)


def pulled_uids(g, q, now):
    # (SIM.ptPull alone on a queue q; now None: no time given)
    code = (f"(function() local st = {{ q = {lua(q)}, buyAt = {T} }}; SIM.ptPull(st, {lua(SALE)}, {lua(now)}); local o = {{}}; "
            "for _, x in ipairs(st.pulled.list) do o[#o + 1] = x.uid end; return join(o) end)()")
    return g.ev(code)


def case_due():
    print("-- an earlier action due at the pause point, late: queued in the same command list as the question (the simulation applies it)")
    late = {"uid": f"{X}:116", "origin": X, "oseq": 116, "ep": E, "at": T, "fn": "makeVehicleSetLineCmd", "args": {"n": 2}}
    for label, q in (("a set-line stamped for the pause step itself", late),
                     ("one a step late", dict(late, at=T - STEP)),
                     ("a purchase, no purchase made at this step yet", dict(late, fn="makeVehicleBuyCmd", args={"n": 3}))):
        res = []
        # (game A: it came in time, before the paused sale; game B: late, read in the same frame as the sale, its turn at once, as on
        # the host)
        for g, fq, fp, lag in ((GA, 1001, 1010, 0), (GB, 1001, 1001, 2)):
            g.boot(now=T, lag=lag, sw=1, phase=0, me="host")
            g.arrive(fq, q)
            g.arrive(fp, SALE)
            g.ticket(fp, SALE, 11)
            g.frames(80)
            res.append(g)
        a, b = res
        bq = b.ev(f'(function() local i = where("queue", "{q["uid"]}"); return i end)()')
        bp = b.ev(f'(function() for i, fifo in ipairs(BATCHES) do for _, e in ipairs(fifo) do if e.name == "pt_pull" and e.p.uid == "{SALE["uid"]}" then return i end end end end)()')
        check(f"{label}: on game B the late action's queue event and the question in the same command list (the finding's case)",
              bq is not None and bq == bp, (bq, bp))
        for g, n in ((a, "A"), (b, "B")):
            check(f"{label}: game {n}: applied once, by the simulation, then the sale", g.applied() == [q["uid"], SALE["uid"]]
                  and list(g.L.eval("SIMAPPLIED").values()) == [q["uid"]], g.applied())
            check(f"{label}: game {n}: known as applied at the pause point, out of the queue, nothing pulled or left over",
                  g.ev(f'ST.doneUid["{q["uid"]}@{q["at"]}"] == {T}') and not g.ev(f'inQ("{q["uid"]}")')
                  and g.ev('count(TRACE, " unqueue ")') == 0 and g.ev("G.pull == nil and #G.pendingPaused == 0 and #G.pullAdd == 0"))
        check(f"{label}: game B: mod.log says it is left to the simulation ('... due at t={T} left to the simulation's own update')",
              any(f"ORDER: 1 action(s) of {X} due at t={T} left to the simulation's own update (not pulled), before its paused action {SALE['uid']}" in s
                  for s in b.logs()), b.logs())
    print("-- the one-purchase-per-step rule: a due purchase it holds back is still pulled")
    buy = dict(late, fn="makeVehicleBuyCmd", args={"n": 3})
    buy2 = dict(buy, uid=f"{X}:115", oseq=115)
    for label, qs, st, want_sim in (("a purchase made at this step already", [buy], {"q": [], "doneUid": {}, "buyAt": T}, []),
                                    ("two due purchases: the first by the simulation, the second pulled", [buy2, buy], None, [buy2["uid"]])):
        res = []
        for g, fp in ((GA, 1010), (GB, 1001)):
            g.boot(now=T, lag=1, sw=1, phase=0, me="host", st=st)
            g.arrive(1001, *qs)
            g.arrive(fp, SALE)
            g.ticket(fp, SALE, 11)
            g.frames(100)
            res.append(g)
        for g, n in zip(res, "AB"):
            uids = [x["uid"] for x in qs]
            sim = list(g.L.eval("SIMAPPLIED").values())
            check(f"{label}: game {n}: each once, in their order, then the sale", g.applied() == uids + [SALE["uid"]] and sim == want_sim,
                  (g.applied(), sim))
            check(f"{label}: game {n}: the pulled one out of the queue (unqueue), known as applied; nothing left over",
                  not any(g.ev(f'inQ("{u}")') for u in uids) and g.ev(f'count(TRACE, " unqueue {buy["uid"]}@{T}")') == 1
                  and all(g.ev(f'ST.doneUid["{u}@{T}"] == {T}') for u in uids) and g.ev("G.pull == nil and #G.pendingPaused == 0"))
    # (the rule is simApplyDue's, its old form too; and without a time, as before)
    g = GA.boot(now=T, env={"MPFEVER_OLDBUY": "1"}, me="host")
    r = pulled_uids(g, [buy2, buy], T)
    check("MPFEVER_OLDBUY=1 (one purchase per call): the first due purchase left to the simulation, the second pulled", r == buy["uid"], r)
    g = GA.boot(now=T, me="host")
    r = pulled_uids(g, [buy2, buy], T)
    check("a purchase made at this step already (buyAt): both due purchases pulled", r == f"{buy2['uid']},{buy['uid']}", r)
    r = pulled_uids(g, [COLOURS[0], late], None)
    check("no time given: every one pulled, as before", r == f"{late['uid']},{COLOURS[0]['uid']}", r)


def case_noanswer():
    print("-- a simulation that never answers")
    g = GA.boot(now=T, lag=0, sw=1, phase=0, me="host", noanswer=True)
    g.arrive(1001, *COLOURS)
    g.arrive(1002, SALE)
    g.ticket(1003, SALE, 11)
    g.frames(700)
    asked = g.ev('(function() for _, s in ipairs(TRACE) do if s:find(" pt_pull ", 1, true) then return tonumber(s:match("^(%d+)")) end end end)()')
    check("the sale goes after 600 frames without its player's earlier actions", g.applied() == [SALE["uid"]]
          and g.ev(f'APPFRAME["{SALE["uid"]}"]') - asked > 600, (g.applied(), asked))
    check("  logged as a desync risk", any("no answer of the simulation" in s and "desync risk" in s for s in g.logs()))
    check("  the colours left in the queue, nothing held any more", all(g.ev(f'inQ("{u}")') for u in CUIDS) and g.ev("G.pull == nil"))


def case_other_player():
    print("-- another player's paused action while a pull is under way (without turns: MPFEVER_ACTTURNS=0)")
    anna = {"uid": "Anna:7", "origin": "Anna", "oseq": 7, "ep": 9, "at": T, "paused": True, "fn": "makeLineUpdateCmd"}
    g = GB.boot(now=T, env={"MPFEVER_ACTTURNS": "0"}, lag=2, sw=4, phase=0, me="host")
    g.arrive(1001, *COLOURS)
    g.arrive(1002, SALE)
    g.arrive(1003, anna)
    g.frames(100)
    check("it waits for the pull, the pull goes on (sorted before the sale, it does not hold it): no deadlock",
          g.applied() == CUIDS + [SALE["uid"], anna["uid"]], g.applied())
    check("  nothing left", g.ev("G.pull == nil and #G.pendingPaused == 0"))


def case_resumed():
    print("-- the session resumed during a pull: the game stays at the pause point until the sale is applied")
    g = GB.boot(now=T, lag=3, sw=5, phase=0, me="host", env={"MPFEVER_ACTTURNS": "0"})
    g.arrive(1001, *COLOURS)
    g.arrive(1002, SALE)
    g.run("at(1003, function() G.session.pauseAt = nil end)")
    g.run(f'HELD = {{}}; at(1004, function() HELD[1] = G.holdAt end); at(1006, function() HELD[2] = G.holdAt end)')
    g.frames(80)
    check("held at the sale's time while its player's earlier actions are applied", g.ev(f"HELD[1] == {T} and HELD[2] == {T}"), g.ev("join(HELD)"))
    check("  then let go (resume)", g.ev("G.holdAt == nil") and g.ev('count(TRACE, " resume ")') >= 1 and g.applied() == CUIDS + [SALE["uid"]])
    late = dict(SALE, uid=f"{X}:140", oseq=140)
    g = GA.boot(now=T + 2 * STEP, lag=2, sw=3, phase=0, me="host", env={"MPFEVER_ACTTURNS": "0"})
    g.arrive(1001, *COLOURS)
    g.arrive(1002, late)
    g.frames(60)
    check("a paused action late here (its time passed): the game held at once while its pull is under way",
          g.ev(f'count(TRACE, " pause_at {T}")') >= 1 and g.applied() == CUIDS + [late["uid"]], (g.ev("join(TRACE)"), g.applied()))


def case_builds():
    print("-- paused builds: a measure only (not reordered)")
    g = GA.boot(now=T, lag=50, sw=100, phase=0, me="host")
    g.arrive(1001, *COLOURS)
    g.frames(1)
    g.run('B1 = { id = 5 }; G.pullBuildLog(B1, "Philipp#1", 5, 12); G.pullBuildLog(B1, "Philipp#1", 5, 12); G.pullBuildLog({}, "lukas", 6, 13)')
    logs = [s for s in g.logs() if s.startswith("ORDER: paused build")]
    check("'ORDER: paused build 5 of Philipp#1 turn 12 while Philipp#1 has earlier action(s) waiting ... (not reordered)', once; none for lukas",
          len(logs) == 1 and "ORDER: paused build 5 of Philipp#1 turn 12 while Philipp#1 has earlier action(s) waiting for their step (not reordered)" == logs[0], logs)
    rel = grab(r"^local function runNativeRelease\(\)\n.*?^end\n", "runNativeRelease")
    reps = grab(r"^local function runNativeReplays\(\)\n.*?^end\n", "runNativeReplays")
    check("logged where a paused build goes in its turn (runNativeRelease, runNativeReplays), by pcall",
          "pcall(G.pullBuildLog, r, G.me, r.id, seq)" in rel and "if seq then pcall(G.pullBuildLog, a, a.origin, a.uid, seq) end" in reps)


def case_prune():
    print("-- the ledger: by the simulation's word only")
    g = GB.boot(now=T, lag=4, sw=3, phase=0, me="host")
    g.arrive(1001, COLOURS[0])
    g.frames(1)
    check("a queue event sent: noted", g.ev(f'G.qLedger["{CUIDS[0]}@{S}"] ~= nil'))
    g.run("runFrames(2)")
    check("  still noted while the copy of the state does not show it", g.ev(f'#COPIES > 0 and G.qLedger["{CUIDS[0]}@{S}"] ~= nil'))
    g.frames(10)
    check("  forgotten once the copy shows it queued", g.ev(f'G.qLedger["{CUIDS[0]}@{S}"] == nil and VIS.q[1].uid == "{CUIDS[0]}"'))
    check("checkpoints and company joins: never noted",
          g.ev('(function() G.pullNote({ kind = "hash", n = 1, at = 5, origin = "" }); G.pullNote({ fn = "mpfCoJoin", uid = "x:1", at = 5, origin = "x" }); return next(G.qLedger) == nil end)()'))


def case_source():
    print("-- the source")
    check("MPFEVER_PTPULL=0 and MPFEVER_PTPULLFAST=0", 'os.getenv("MPFEVER_PTPULL") ~= "0"' in SRC and 'os.getenv("MPFEVER_PTPULLFAST") ~= "0"' in SRC)
    save = grab(r"^H\.resync_save = function\(from, p\)\n.*?^end\n", "H.resync_save")
    busy = save[save.index("local function busy()"):save.index("local function save()")]
    check("a resynchronisation's save waits while a pull is under way (busy())", "if G.pull then return true end" in busy)
    co = grab(r"^G\.coEvent = function\(name, param\)\n.*?^end\n", "G.coEvent")
    held = grab(r"^local function stampHeld\(\)\n.*?^end\n", "stampHeld")
    check("its load (ep = G.epoch) on every action this game makes for the queue: G.coEvent, the players' and the host's mod commands",
          co.count("ep = G.epoch") == 1 and held.count("ep = G.epoch") == 2 and re.search(r"^\tepoch = os\.time\(\), qLedger = \{\}", SRC, re.M) is not None)
    q = grab(r"^local function queueLocal\(a\)\n.*?^end\n", "queueLocal")
    check("queueLocal notes both queue paths (pcall: never in the way)", q.count("pcall(G.pullNote, a)") == 2)
    check("the simulation's events pt_pull, unqueue, pt_pull_done", all(f'elseif name == "{n}" then' in SIM_EVENTS for n in ("pt_pull", "unqueue", "pt_pull_done")))
    check("the question answered at the simulation's game time (what its own update applies is left to it)",
          "\t\t\tSIM.ptPull(st, param, gameTime())\n" in SIM_EVENTS)
    fin = grab(r"^local function autoFinish\(\)\n.*?^end\n", "autoFinish")
    check("the autotest scenario H.pauseorder (sale in the pause, the colours' witness, a road, the session resumed)",
          "H.pauseorder = function(from, p)" in SRC and "if AUTO.chain then local f = AUTO.chain; AUTO.chain = nil; return f() end" in fin
          and "kept vehicle's colour in the pause: " in SRC)
    bad = re.findall(r"^local\s+(?:function\s+)?(\w*(?:[pP]ull|[lL]edger|pauseorder|epoch)\w*)", SRC, re.M)
    check("no new main-chunk local for it (the 200-local limit, see test_locals.py)", not bad, bad)


def scenario(seed, resync, late_epoch):
    rnd = random.Random(seed)
    R = [{"uid": f"{X}:{109 + i}", "origin": X, "oseq": 109 + i, "ep": 2, "at": T + 10 * STEP, "fn": "makeEntitySetColorCmd"} for i in range(rnd.randint(0, 8))]
    if late_epoch:
        R.append({"uid": f"{X}:500", "origin": X, "oseq": 500, "ep": 1, "at": T + 5 * STEP, "fn": "makeVehicleSetLineCmd"})
    other = [{"uid": f"lukas:{300 + i}", "origin": "lukas", "oseq": 300 + i, "ep": 7, "at": T + 3 * STEP, "fn": "makeLineUpdateCmd"} for i in range(rnd.randint(0, 3))]
    P = {"uid": f"{X}:117", "origin": X, "oseq": 117, "ep": 2, "at": T, "paused": True, "fn": "makeVehicleSellCmd"}
    after = {"uid": f"{X}:118", "origin": X, "oseq": 118, "ep": 2, "at": T + 11 * STEP, "fn": "makeEntitySetNameCmd"}
    B = {"uid": "lukas:999", "origin": "lukas", "oseq": 999, "ep": 7, "at": T, "paused": True, "fn": "makeLineUpdateCmd"}
    games = []
    for gname in ("host", "client"):
        saved = (R + other) if (resync and gname == "client") else None
        grnd = random.Random(rnd.random())
        sw = grnd.randint(2, 12)
        cfg = {"sw": sw, "phase": grnd.randint(0, sw - 1), "lag": grnd.randint(0, 6), "st": {"q": saved or [], "doneUid": {}}}
        stream = [P, after, B] if saved else R + other + [P, after, B]
        f, arr = 1001, []
        for m in stream:
            f += rnd.randint(0, 3)
            arr.append((f, m))
        fP = next(fr for fr, m in arr if m is P)
        fB = next(fr for fr, m in arr if m is B)
        t11 = fP + rnd.randint(0, 20)
        t12 = max(t11, fB) + rnd.randint(1, 20)
        games.append((cfg, arr, t11, t12))
    # (lukas' own actions waiting go before lukas' paused action, in its turn)
    expected = ([x["uid"] for x in sorted(R, key=lambda x: (x["at"], x["oseq"]))] + [P["uid"]]
                + [x["uid"] for x in sorted(other, key=lambda x: (x["at"], x["oseq"]))] + [B["uid"]])
    return games, expected, [x["uid"] for x in R], P, B


def play(g, cfg, arr, t11, t12, P, B, env):
    g.boot(now=T, env=env, me="lukas", watch=True, **cfg)
    for fr, m in arr:
        g.arrive(fr, m)
    g.ticket(t11, P, 11)
    g.ticket(t12, B, 12)
    g.frames(260)
    return g.applied(), g.ev("VIOL"), g.ev("G.pull == nil and #G.pendingPaused == 0")


def case_model():
    print("-- the design's random model (ptpull168_model.py), ported: two games, random swaps, copy lags and message times")
    t0 = time.time()
    bad, runs, examples = 0, 0, []
    for seed in MODEL_SEEDS[0]:
        for resync in (False, True):
            games, exp, ruids, P, B = scenario(seed, resync, seed % 3 == 0)
            out = [play(g, *spec, P, B, {}) for g, spec in zip((Game(), Game()), games)]
            runs += 1
            if out[0][0] != out[1][0] or out[0][0] != exp or out[0][1] or out[1][1] or not (out[0][2] and out[1][2]):
                bad += 1
                if len(examples) < 3:
                    examples.append((seed, resync, out, exp))
    check(f"pull on: the same order on both games, the player's order, the fast path never wrong ({runs} runs)", bad == 0, examples)
    bad, examples = 0, []
    for seed in MODEL_SEEDS[1]:
        games, exp, ruids, P, B = scenario(1000 + seed, False, seed % 3 == 0)
        out = [play(g, *spec, P, B, {"MPFEVER_PTPULLFAST": "0"}) for g, spec in zip((Game(), Game()), games)]
        if out[0][0] != out[1][0] or out[0][0] != exp:
            bad += 1
            examples.append((seed, out, exp))
    check(f"always asked (MPFEVER_PTPULLFAST=0): the same orders ({len(MODEL_SEEDS[1])} runs)", bad == 0, examples[:2])
    inv = withR = 0
    for seed in MODEL_SEEDS[2]:
        games, exp, ruids, P, B = scenario(2000 + seed, False, False)
        out = [play(g, *spec, P, B, {"MPFEVER_PTPULL": "0"}) for g, spec in zip((Game(), Game()), games)]
        if ruids:
            withR += 1
            if out[0][0][:1] == [P["uid"]] and not set(ruids) & set(out[0][0]):
                inv += 1
    check(f"MPFEVER_PTPULL=0: the #168 inversion in every run with actions waiting ({inv} of {withR})", (withR > 0 or not MODEL_SEEDS[2]) and inv == withR)
    print(f"    ({time.time() - t0:.1f} s)")


MODEL_SEEDS = (range(300), range(150), range(150))


def main():
    global MODEL_SEEDS
    if "--model" in sys.argv:
        a, b = int(sys.argv[-2]), int(sys.argv[-1])
        MODEL_SEEDS = (range(a, min(b, 300)), range(a // 2, min(b // 2, 150)), range(a // 2, min(b // 2, 150)))
        case_model()
        print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
        return 1 if fails else 0
    for case in (case_168, case_off, case_fast, case_lag, case_resync, case_issue_order, case_checkpoints, case_buys, case_due,
                 case_noanswer, case_other_player, case_resumed, case_builds, case_prune, case_source):
        case()
    # (the random model runs about 900 games in lupa. With that many in one process, lupa's own memory was seen corrupted now and
    # then on this PC: "Windows fatal exception 0xc0000374" inside LuaRuntime.execute, or code text damaged before it ran; never a
    # wrong order. The model therefore runs in 6 processes of 50 seeds each, each run once more when it dies without a result. A
    # wrong order, or a process that dies twice, is a failure)
    import subprocess
    for a in range(0, 300, 50):
        for attempt in (1, 2):
            r = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--model", str(a), str(a + 50)], capture_output=True,
                               text=True, encoding="utf-8", errors="replace", timeout=600)
            out = r.stdout.strip().splitlines()
            result = out[-1] if out else ""
            if r.returncode in (0, 1) and result in ("all passed",) or (r.returncode == 1 and result.endswith("failure(s)")):
                for l in out:
                    if l.startswith("ok  ") or l.startswith("FAIL") or l.startswith("    ("):
                        print(l.replace("ok   ", f"ok   [seeds {a}-{a + 49}] ", 1))
                    if l.startswith("FAIL"):
                        fails.append(l[5:])
                break
            print(f"    (the model's process for seeds {a}-{a + 49} ended without a result, code {r.returncode}: run again)")
        else:
            check(f"the random model, seeds {a}-{a + 49}: a result (its process died twice)", False)
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
