"""Offline test of the 0.6 options "perms" and "plans" (mod/mpfever_1/content/mpfever_feat_perms.lua, idea 08 of 0.6): team
permissions, budgets, approvals and shared plans, against the options host's contract (docs/FEATURES-0.6.md).

Each game is a Lua 5.2 runtime of its own (lupa) holding the module, a mocked env as the contract gives it (simulation half:
env.on, env.param, env.state, env.mode, env.co, env.month, env.book...; interface half: env.isHost, env.me, env.myCo,
env.send, env.chat, env.write, env.realTime...) and its game state. The events a game's interface sends are applied by every
game in the same order, as the lockstep does; the actions every game replays go through M.onAction on each of them.
Cases: options off (no state, no event, no file, no money); co-op (rights, budget, approval, team leads, speed, loans, tools,
vehicle store, line window, months and the new year, plans, the host's decision for a dedicated server's owner); the separate
mode (a company's chief and members, another company and the host have no say, a computer company, a player who leaves, a
bankrupt company, plans seen by one's company only); determinism (two runs give the same state; every game holds the same
state); a savegame reload (the state is plain data and goes on the same); the window's tab; MPFEVER_PERMSVETO=0.
Run: python tests/test_feat_perms.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_feat_perms.lua"), encoding="utf-8").read()

HARNESS = r'''
OPTS = {}
MON = 1950 * 12 + 3          -- a game month (env.month()); the test's calendar (env.date()) reads it as year * 12 + month: March 1950
CLOCK = 0
LOG, SENT, CHAT, FILES, BOOKED, ZONES = {}, {}, {}, {}, {}, {}
FOCUS = nil
ME, ISHOST, MYCO, MODE, OWNER, LANG, PLAYERS = "Host", true, nil, "shared", nil, "en", nil
GAME = { st = {} }

-- a canonical text of a value (sorted keys): two states are the same when their texts are
function ser(v)
  local t = type(v)
  if t == "nil" then return "nil" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("a number that is not finite") end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot write a " .. t)
end
function deser(s) return assert(load("return " .. s))() end

-- what a savegame can hold: no function, no userdata, no metatable, no cycle (nor a table twice), whole keys from 1 or texts
function plainErr(v, seen, path)
  seen = seen or {}
  path = path or "state"
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return path .. " is not finite" end
    return nil
  end
  if t == "string" or t == "boolean" or t == "nil" then return nil end
  if t ~= "table" then return path .. " is a " .. t end
  if seen[v] then return path .. " seen twice (a cycle or a shared table)" end
  seen[v] = true
  if getmetatable(v) ~= nil then return path .. " has a metatable" end
  for k, x in pairs(v) do
    local tk = type(k)
    if tk ~= "string" and not (tk == "number" and k == math.floor(k) and k >= 1) then return path .. " has the key " .. tostring(k) end
    local e = plainErr(x, seen, path .. "." .. tostring(k))
    if e then return e end
  end
  return nil
end

local function defaultParam(id, pid)
  for _, o in ipairs(M.OPTIONS) do
    if o.id == id then for _, p in ipairs(o.params or {}) do if p.id == pid then return p.default end end end
  end
  return nil
end
local function on(id) return OPTS[id] == true end
local function param(id, pid)
  local v = OPTS[id .. "." .. pid]
  if v ~= nil then return v end
  return defaultParam(id, pid)
end

-- the simulation half's env (no send, chat, write: calling them fails the test)
function simEnv(from)
  return {
    log = function(s) LOG[#LOG + 1] = s end, gameTime = function() return 0 end, STEP = 200,
    on = on, param = param,
    state = function(st) st.feat = st.feat or {}; st.feat[M.ID] = st.feat[M.ID] or {}; return st.feat[M.ID] end,
    mode = MODE, co = MODE == "separate" and GAME.st.co or nil,
    companies = function()
      local out = {}
      for _, c in ipairs(GAME.st.co and GAME.st.co.list or {}) do
        out[#out + 1] = { id = c.id, ent = c.ent, name = c.name, ai = c.key:sub(1, 3) == "ai:", members = c.members }
      end
      return out
    end,
    money = function() return 0 end, book = function(ent, amount) BOOKED[#BOOKED + 1] = amount end, R = {},
    every = function() return false end, month = function() return MON end, from = from,
    date = function() if NODATE then return nil end return { year = math.floor((MON - 1) / 12), month = (MON - 1) % 12 + 1, day = 1 } end,
  }
end

-- the interface half's env (no state, no book: calling them fails the test)
function guiEnv()
  return {
    log = function(s) LOG[#LOG + 1] = s end, on = on, param = param, isHost = ISHOST, me = ME, myCo = MYCO,
    send = function(name, p) SENT[#SENT + 1] = { name = name, p = ser(p), from = ME } end,
    chat = function(t) CHAT[#CHAT + 1] = t end,
    write = function(file, lines) FILES[file] = lines end,
    realTime = function() return CLOCK end,
    T = function(fr, en) if LANG == "fr" then return fr end return en end,
    pvPoints = function(p) return p.pts end,
    owner = OWNER, players = PLAYERS,
  }
end

function ev(name, psrc, from) return M.event(GAME.st, name, deser(psrc), simEnv(from)) end
function act(asrc, ok) M.onAction(GAME.st, deser(asrc), ok, simEnv(nil)) end
function month(m) MON = m; M.month(GAME.st, simEnv(nil)) end
function gui() M.gui(GAME.st, guiEnv()) end
function allow(asrc) return M.allow(deser(asrc), GAME.st, guiEnv()) end
function veto(id, name, psrc) return M.guiVeto(id, name, deser(psrc), GAME.st, guiEnv()) end
function request(kind, payload) return M.request(kind, payload, GAME.st, guiEnv()) end
function takeSent() local out = {} for i, s in ipairs(SENT) do out[i] = s end SENT = {} return out end
function takeChat() local out = table.concat(CHAT, "\n") CHAT = {} return out end
function stateSrc() return ser(GAME.st.feat and GAME.st.feat.perms) end
function stateOf() return GAME.st.feat and GAME.st.feat.perms end
function fileText(name) local l = FILES[name] return l and table.concat(l, "\n") or nil end
function zoneCount() local n = 0 for _ in pairs(ZONES) do n = n + 1 end return n end
function vetoText(r)
  if type(r) == "table" then local t = {} for k in pairs(r.errorMessages or {}) do t[#t + 1] = k end return "veto:" .. table.concat(t, "|") .. ":" .. tostring(r.skipRender) end
  return tostring(r)
end
'''

# the module's functions the game gives at run time: the store's prices, the map's zones and camera
STUBS = r'''
PRICES = { [11] = 600000, [12] = 150000, [13] = 50000 }
M.modelPrice = function(id) return PRICES[id] or 0 end
M.draw = {
  circle = function(key, x, y, r, c) ZONES[key] = { x, y, r } end,
  remove = function(key) ZONES[key] = nil end,
  focus = function(x, y, z) FOCUS = { x, y, z } end,
  center = function() return 100.4, 200.6, 5 end,
}
'''

failures = []
QUIET = [False]   # (a scenario run again only to compare its result: its checks print nothing unless they fail)


def check(cond, what):
    if not (cond and QUIET[0]):
        print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        failures.append(what)


def buy(origin, model=11, co=None):
    return ("{ fn = 'makeVehicleBuyCmd', origin = %r, co = %s, args = { 1, 2, { vehicles = { { part = { modelId = %d } } } } } }"
            % (origin, "nil" if co is None else co, model))


class Game:
    def __init__(self, me, is_host, mode="shared", reg=None, my_co=None, opts="{}", lang="en", owner=None):
        self.L = lua52.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(HARNESS)
        self.M = self.L.execute(SRC)
        g = self.L.globals()
        g.M = self.M
        self.L.execute(STUBS)
        g.ME, g.ISHOST, g.MODE, g.LANG = me, is_host, mode, lang
        if my_co is not None:
            g.MYCO = my_co
        if owner is not None:
            g.OWNER = owner
        if reg:
            self.L.execute("GAME.st.co = " + reg)
        self.L.execute("OPTS = " + opts)
        self.name = me

    def run(self, code):
        return self.L.execute(code)

    def g(self):
        return self.L.globals()

    def ev(self, name, psrc, frm):
        return self.g().ev(name, psrc, frm)

    def allow(self, asrc):
        r = self.g().allow(asrc)
        return r if isinstance(r, tuple) else (r, None)

    def veto(self, tool, name, psrc):
        return self.g().vetoText(self.g().veto(tool, name, psrc))

    def request(self, kind, payload=""):
        return self.g().request(kind, payload)

    def state(self):
        return self.g().stateSrc()

    def file(self):
        return self.g().fileText("team")

    def chat(self):
        return self.g().takeChat()


def deliver(games):
    """The events every interface sent, applied by every game in the same order (the lockstep). Returns the results on the
    first game: [(name, applied)]"""
    out = []
    for src in games:
        sent = src.g().takeSent()
        for i in range(1, len(sent) + 1):
            s = sent[i]
            res = [gm.ev(s.name, s.p, s["from"]) for gm in games]
            first = res[0][0] if isinstance(res[0], tuple) else res[0]
            out.append((s.name, first))
    return out


def ev_all(games, name, psrc, frm):
    """An event every game applies (a refused one too: it went through the lockstep). Returns whether the first applied it."""
    res = [gm.ev(name, psrc, frm) for gm in games]
    return res[0][0] if isinstance(res[0], tuple) else res[0]


def every(games, code):
    for gm in games:
        gm.run(code)


def act_all(games, asrc, ok=True):
    for gm in games:
        gm.g().act(asrc, ok)


def month_all(games, m):
    for gm in games:
        gm.g().month(m)


def gui_all(games):
    for gm in games:
        gm.g().gui()


def same_state(games, what):
    states = [gm.state() for gm in games]
    check(all(s == states[0] for s in states), what + " (the same state on every game)")
    return states[0]


# ------------------------------------------------------------------------------------------------------------------ options
def test_declarations():
    print("declarations")
    gm = Game("Host", True)
    L, M = gm.L, gm.M
    ids = [o.id for o in M.OPTIONS.values()]
    check(ids == ["perms", "plans"], "two options: perms, plans")
    for o in M.OPTIONS.values():
        check(o.title[1] and o.title[2] and o.desc[1] and o.desc[2], o.id + ": title and description in French and English")
        check(o.modes == "both", o.id + ": both modes")
    p = M.OPTIONS[1].params[1]
    check(p.id == "budget" and p.default in list(p["values"].values()), "perms: a budget parameter, its default among its values")
    tfr = L.eval("function(fr, en) return fr end")
    ten = L.eval("function(fr, en) return en end")
    check(p.show(0, ten) == "Unlimited" and p.show(0, tfr) == "Illimité", "budget 0 shows Unlimited / Illimité")
    check(p.show(1000000, ten) == "$1,000,000" and p.show(1000000, tfr) == "1 000 000 $", "budget 1000000 shows $1,000,000 / 1 000 000 $")
    check(all(k.startswith("f_perms") for k in M.EVENTS.keys()), "every event starts with f_perms")
    check(M.TAB.title[1] == "Équipe" and M.TAB.title[2] == "Team", "a tab Équipe / Team")
    bad = L.eval(r'''function(M)
      local bad = {}
      for k, t in pairs(M.TEXTS) do
        local _, nf = t[1]:gsub("%%s", "") local _, ne = t[2]:gsub("%%s", "")
        if t[1] == "" or t[2] == "" or nf ~= ne then bad[#bad + 1] = k end
      end
      return table.concat(bad, ",") end''')(M)
    check(bad == "", "every text in French and English, with the same %s" + (": " + bad if bad else ""))
    check(gm.g().api is None, "the module loads without the game's API")


# -------------------------------------------------------------------------------------------------------------- options off
def test_off():
    print("options off")
    for mode, reg, me, host in (("shared", None, "Bob#1", False), ("separate", SEP_REG, "Bob#2", False), ("shared", None, "Host", True)):
        gm = Game(me, host, mode, reg=reg, my_co=2 if reg else None)
        for name, p in (("f_perms_set", "{ key = 'bob', r = 'b' }"), ("f_perms_ask", "{ amount = 5 }"), ("f_perms_lead", "{ key = 'bob', on = true }"),
                        ("f_perms_plan", "{ kind = 'note', pts = '1,2' }"), ("f_perms_answer", "{ n = 1, ok = true }")):
            r = gm.ev(name, p, "Host")
            check((r[0] if isinstance(r, tuple) else r) is False, f"{mode} {me}: {name} refused")
        gm.g().act(buy(me), True)
        gm.g().month(1951 * 12 + 1)
        gm.g().gui()
        check(gm.g().GAME.st.feat is None, f"{mode} {me}: no state")
        check(gm.allow(buy(me))[0] is True and gm.allow("{ fn = 'makeGameSetSpeedCmd', args = { 0 } }")[0] is True, f"{mode} {me}: nothing refused")
        check(gm.veto("bulldozer", "builder.proposalCreate", "{ {}, { costs = 1e9 } }") == "nil", f"{mode} {me}: no tool vetoed")
        check(gm.veto("vehicleStore", "mission.buyVehicle", "{ modelId2quantity = { [11] = 3 } }") == "nil", f"{mode} {me}: the store says nothing")
        for kind, payload in (("ask", "500000"), ("planmode", "1"), ("note", "x\ty"), ("right", "carl\tb")):
            check(gm.request(kind, payload) is False, f"{mode} {me}: request {kind} does nothing")
        check(len(gm.g().takeSent()) == 0 and gm.chat() == "" and gm.file() is None, f"{mode} {me}: no event sent, no chat, no file")
        check(len(gm.g().BOOKED) == 0 and gm.g().zoneCount() == 0, f"{mode} {me}: no money, nothing drawn")


# ------------------------------------------------------------------------------------------------------------------- co-op
COOP_OPTS = "{ perms = true, plans = true, ['perms.budget'] = 1000000 }"


def coop(verbose=True):
    """The co-op scenario; returns the games (host, bob, carl)."""
    say = check if verbose else (lambda cond, what: None)
    QUIET[0] = not verbose
    host = Game("Host", True, opts=COOP_OPTS)
    bob = Game("Bob#1", False, opts=COOP_OPTS)
    carl = Game("Carl#2", False, opts=COOP_OPTS)
    games = [host, bob, carl]
    gui_all(games)
    say("opt\t1\t1\tshared" in host.file() and "\nme\thost\ttop\tbdvlms\t-" in host.file(), "the host is the team's leader, no limit")
    say("\nme\tbob\tmember\tbdvlms\t1000000\t0" in bob.file(), "a new player has every right and the default budget (H2)")
    # a purchase within the budget, counted on every game
    ok, why = bob.allow(buy("Bob#1"))
    say(ok is True, "Bob buys a 600 000 train: allowed")
    act_all(games, buy("Bob#1"))
    st = same_state(games, "the purchase counted")
    say('["spent"]={["bob"]=600000}' in st, "600 000 spent this year")
    ok, why = bob.allow(buy("Bob#1"))
    say(ok is False and "$400,000 left" in (why or ""), "a second one is over the budget: " + str(why))
    bob.g().gui()
    say("\t600000\t" in bob.file(), "the refused amount is kept for the request")
    # the request, the leader's notice, an answer by a member refused, the host's approval
    say(bob.request("ask", "500 000\tnew depot") is True, "Bob asks for 500 000")
    deliver(games)
    same_state(games, "the request")
    host.g().gui()
    say("Bob asks for approval of $500,000: new depot" in host.chat(), "the host is told in its chat")
    bob.g().gui()
    carl.g().gui()
    say(bob.chat() == "" and carl.chat() == "", "the others are not told")
    say(carl.request("answer", "1\t1") is False, "Carl (a member) cannot answer")
    say(ev_all(games, "f_perms_answer", "{ n = 1, ok = true }", "Carl#2") is False, "Carl's answer is refused by the simulation")
    say(host.request("answer", "1\t1") is True, "the host approves")
    deliver(games)
    st = same_state(games, "the approval")
    say('["grant"]={["bob"]={["co"]=0,["left"]=500000,["till"]=%d}}' % (1950 * 12 + 6) in st, "500 000 for 3 months (H4)")
    bob.g().gui()
    say("Approved by Host: you may spend $500,000 more for 3 months." in bob.chat(), "Bob is told")
    ok, _ = bob.allow(buy("Bob#1"))
    say(ok is True, "the train fits now (400 000 + 500 000)")
    act_all(games, buy("Bob#1"))
    st = same_state(games, "beyond the budget, the approval goes down")
    say('["left"]=300000' in st and '["bob"]=1200000' in st, "1 200 000 spent, 300 000 left of the approval")
    ok, why = bob.allow(buy("Bob#1"))
    say(ok is False and "$300,000 left" in why, "a third train is refused")
    say(bob.allow(buy("Bob#1", model=12))[0] is True, "a 150 000 bus fits")
    # (the actions travel two steps: what this game sent and the simulation has not counted yet is spent already)
    say(bob.allow(buy("Bob#1", model=12))[0] is True, "a second one too (300 000 left, 150 000 of it waiting to be counted)")
    say(bob.allow(buy("Bob#1", model=12))[0] is False, "a third one right after them is refused (both still waiting)")
    act_all(games, buy("Bob#1", model=12))
    act_all(games, buy("Bob#1", model=12))
    st = same_state(games, "two buses")
    say('["bob"]=1500000' in st and '["grant"]={}' in st, "the approval used up is gone")
    say(bob.allow(buy("Bob#1", model=12))[0] is False, "nothing left once they are counted")
    bob.g().CLOCK = 30
    say(bob.allow(buy("Bob#1", model=12))[0] is False, "(and nothing waiting any more)")
    # rights (the host's toggles), refused on Bob's game before anything is sent
    say(host.request("right", "bob\tv") is True, "the host takes the vehicles right away")
    deliver(games)
    st = same_state(games, "the rights")
    say('["p"]={["bob"]={["co"]=0,["r"]="bdlms"}}' in st, "Bob: bdlms")
    ok, why = bob.allow(buy("Bob#1", model=13))
    say(ok is False and "You may not buy, replace or sell vehicles" in why, "Bob cannot buy a vehicle")
    say(bob.allow("{ fn = 'makeVehicleSellCmd', args = { { 5 } } }")[0] is False, "nor sell one")
    say(bob.allow("{ fn = 'makeLineCreateCmd', args = {} }")[0] is True, "he may still make a line")
    say(host.allow(buy("Host"))[0] is True, "the host is never refused")
    bob.g().gui()
    c = bob.chat()
    say("Your permissions changed: Build, Bulldoze, Lines, Loans, Speed and pause; budget: $1,000,000." in c, "Bob is told: " + c)
    # speed and pause (H8), loans, MPFever's own events (two clicks before the first one arrives: both count)
    host.request("right", "bob\ts")
    host.request("right", "bob\tm")
    deliver(games)
    st = same_state(games, "two rights taken at once")
    say('["bob"]={["co"]=0,["r"]="bdl"}' in st, "Bob: bdl")
    ok, why = bob.allow("{ fn = 'makeGameSetSpeedCmd', args = { 0 } }")
    say(ok is False and "change the game's speed or pause it" in why, "Bob cannot pause")
    say(host.allow("{ fn = 'makeGameSetSpeedCmd', args = { 4 } }")[0] is True, "the host can")
    ok, why = bob.allow("{ fn = 'makeScriptingSendEventCmd', args = { '', 'Loan', 'Obtain', {} } }")
    say(ok is False and "loan" in why, "Bob cannot take a loan")
    say(bob.allow("{ fn = 'makeScriptingSendEventCmd', args = { 'mpfever', 'mpfever', 'f_perms_ask', {} } }")[0] is True, "MPFever's events are never refused")
    say(bob.allow("{ fn = 'makeWorldBuildProposalCmd', native = true, cost = 1e9 }")[0] is True, "a native build is never refused after the click")
    say(bob.allow("{ fn = 'terrainEdit', args = {} }")[0] is True, "nor a terrain edit")
    # team leads (H3)
    say(carl.request("lead", "bob\t1") is False, "Carl cannot name a lead")
    say(host.request("lead", "carl\t1") is True, "the host names Carl a team lead")
    deliver(games)
    same_state(games, "the lead")
    say(carl.request("right", "bob\td") is True, "Carl (a lead) takes Bob's bulldozer away")
    deliver(games)
    st = same_state(games, "a lead's change")
    say('["bob"]={["co"]=0,["r"]="bl"}' in st, "Bob: bl")
    for name, p, frm, what in (("f_perms_set", "{ key = 'host', r = '' }", "Carl#2", "a lead over the host"),
                               ("f_perms_lead", "{ key = 'bob', on = true }", "Carl#2", "a lead naming a lead"),
                               ("f_perms_set", "{ key = 'carl', r = '' }", "Carl#2", "a lead over itself"),
                               ("f_perms_set", "{ key = 'carl', r = '' }", "Bob#1", "a member over a lead"),
                               ("f_perms_set", "{ key = 'bob', b = 'x' }", "Host", "a budget that is no number")):
        say(ev_all(games, name, p, frm) is False, what + ": refused")
    # (tables where texts are expected: their text is an address, which differs from one game to the other)
    say(ev_all(games, "f_perms_set", "{ key = {}, r = 'b' }", "Host") is False, "a key that is a table: refused")
    say(ev_all(games, "f_perms_set", "{ key = 'bob', add = {}, del = { 'b' } }", "Host") is True, "letters that are tables: nothing given or taken")
    say(ev_all(games, "f_perms_plan", "{ kind = 'note', pts = '5,5', name = {}, text = {} }", "Carl#2") is True, "a note named by a table: no name")
    st = same_state(games, "events with tables in them")
    say('["bob"]={["co"]=0,["r"]="bl"}' in st and '["name"]=""' in st, "Bob still bl, the note without a name")
    say(ev_all(games, "f_perms_plandel", "{ id = 1 }", "Carl#2") is True, "Carl takes his note away")
    # the tools, the store, the line window
    say(bob.veto("bulldozer", "builder.proposalCreate", "{ {}, { costs = 1000 } }") == "veto:You may not bulldoze (your team's rule).:false",
        "the bulldozer is vetoed before the click (the route still shows)")
    say(bob.veto("streetBuilder", "builder.proposalCreate", "{ {}, { costs = 5000000 } }").startswith("veto:Over budget: $0 left"),
        "a street over the budget is vetoed")
    host.request("budget", "bob\t-1")
    deliver(games)
    say(bob.veto("streetBuilder", "builder.proposalCreate", "{ {}, { costs = 5000000 } }") == "nil", "with no limit, it is not")
    say(host.veto("bulldozer", "builder.proposalCreate", "{ {}, { costs = 1000 } }") == "nil", "the host's tools are never vetoed")
    say(bob.veto("vehicleStore", "mission.buyVehicle", "{ modelId2quantity = { [11] = 1 } }") == "You may not buy, replace or sell vehicles (your team's rule).",
        "the store's buy button is off for Bob")
    say(bob.veto("management.line", "delete", "5") == "nil", "Bob may delete a line")
    host.request("right", "bob\tl")
    deliver(games)
    say(bob.veto("management.line", "delete", "5") == "true", "not without the lines right")
    host.request("budget", "carl\t0")
    deliver(games)
    say(carl.veto("vehicleStore", "mission.buyVehicle", "{ modelId2quantity = { [12] = 2 } }").startswith("Over budget: $0 left"),
        "a budget of 0: nothing without an approval")
    say(carl.g().M.GUI.lastRefused is None, "(the store's refusals are not kept for a request: it asks for every row, every frame)")
    host.request("budget", "carl\tdefault")
    deliver(games)
    st = same_state(games, "back to the default")
    say('["carl"]' not in st.split('["p"]=')[1].split('["who"]')[0], "an entry back to everything is taken away")
    # months: the approval ends after 3 months, a request after 3, the year's spending on 1 January (H5)
    bob.request("ask", "100000")
    deliver(games)
    host.request("answer", "2\t1")
    deliver(games)
    carl.request("ask", "200000\tbridge")
    deliver(games)
    month_all(games, 1950 * 12 + 4)
    st = same_state(games, "April")
    say('["left"]=100000' in st and '["amount"]=200000' in st, "in April the approval and Carl's request are there")
    month_all(games, 1950 * 12 + 6)
    st = same_state(games, "June")
    say('["grant"]={}' in st, "the approval ended after 3 months")
    say('["asks"]={}' in st, "the request nobody answered went after 3 months")
    say('["spent"]={["bob"]=1500000' in st, "the spending is kept during the year")
    month_all(games, 1951 * 12 + 1)
    st = same_state(games, "January")
    say('["spent"]' not in st and '["year"]=1951' in st, "1 January: the budgets start again")
    host.request("budget", "bob\tdefault")
    deliver(games)
    bob.g().gui()
    say("\nme\tbob\tmember\tb\t1000000\t0\t" in bob.file(), "Bob's file: 0 spent of 1 000 000")
    # plans (H6, H7): plan mode, keep the route, a note at the centre of the view, seen by everybody in co-op
    say(bob.request("planmode", "1") is True, "Bob switches the plan mode on")
    pts = "{ " + ", ".join("{ %d, 0 }" % (5 * i) for i in range(21)) + ", { 300, 40, 30 } }"
    v = bob.veto("trackBuilder", "builder.proposalCreate", "{ {}, { costs = 1e9 }, pts = %s }" % pts)
    say(v == "veto:Plan mode: nothing is built. Keep the route in the MPFever window, Team tab.:false", "the tool builds nothing in plan mode")
    say(bob.g().M.GUI.route.n == 9, "the route kept: one point every 15 m, the construction's circle and the end (%s)" % bob.g().M.GUI.route.pts)
    say(bob.request("keep", "Main line") is True, "Bob keeps it")
    say(bob.request("keep", "again") is False, "a route is kept once")
    say(bob.request("note", "Depot\tbuild here") is True, "a note at the centre of the view")
    deliver(games)
    st = same_state(games, "the plans")
    say('["kind"]="route"' in st and '["np"]=9' in st and '["pts"]="100,201"' in st and '["text"]="build here"' in st,
        "a route of 9 points and a note at 100,201")
    gui_all(games)
    say(all(gm.g().zoneCount() == 9 + 2 for gm in games), "every game draws them (co-op: seen by everybody)")
    # (plan 1 was Carl's note, taken away above: Bob's route is plan 2, his note 3)
    say("\nplan\t2\tBob\troute\tMain line\t\t0.3 km\t1\t1\t0" in bob.file(), "Bob may delete his route")
    say("\nplan\t2\tBob\troute\tMain line\t\t0.3 km\t1\t1\t0" in carl.file(), "Carl, a lead, may delete a member's route")
    say(carl.request("hide", "2") is True, "Carl hides the route on his game")
    carl.g().gui()
    say(carl.g().zoneCount() == 2 and bob.g().zoneCount() == 11, "on his game only")
    say("\nplan\t2\tBob\troute\tMain line\t\t0.3 km\t0\t1" in carl.file(), "his window says it is hidden")
    say(carl.request("see", "3") is True and list(carl.g().FOCUS.values()) == [100, 201, 5], "the camera goes to the note")
    host.request("note", "HQ\there")
    deliver(games)
    say(ev_all(games, "f_perms_plandel", "{ id = 4 }", "Bob#1") is False, "Bob cannot delete the host's note")
    host.request("plandel", "2")
    bob.request("plandel", "3")
    deliver(games)
    st = same_state(games, "plans deleted")
    say('["id"]=4' in st and '["id"]=2,' not in st and '["id"]=3,' not in st, "the host deleted Bob's route, Bob his note")
    gui_all(games)
    say(all(gm.g().zoneCount() == 2 for gm in games), "every game draws the host's note only")
    for i in range(13):
        bob.request("note", "n%d" % i)
    res = [x[1] for x in deliver(games)]
    say(res == [True] * 12 + [False], "12 plans per player at most")
    for name, p, what in (("f_perms_plan", "{ kind = 'route', pts = '1,2' }", "a route of one point"),
                          ("f_perms_plan", "{ kind = 'note', pts = '1,2;3,4' }", "a note of two points"),
                          ("f_perms_plan", "{ kind = 'route', pts = 'a,b;c,d' }", "points that are no numbers"),
                          ("f_perms_plan", "{ kind = 'route', pts = '0,0;9000000,0' }", "a point off the map"),
                          ("f_perms_plan", "{ kind = 'circle', pts = '1,2' }", "another kind")):
        say(ev_all(games, name, p, "Host") is False, what + ": refused")
    say(bob.request("planmode", "0") is True and bob.veto("trackBuilder", "builder.proposalCreate", "{ {}, { costs = 1 } }") == "nil",
        "plan mode off: the tool builds (Bob has the build right)")
    host.request("right", "bob\tb")
    deliver(games)
    say(bob.veto("trackBuilder", "builder.proposalCreate", "{ {}, { costs = 1 } }") == "veto:You may not build (your team's rule).:false",
        "without it, the tool is vetoed")
    host.request("right", "bob\tb")
    deliver(games)
    say(bob.veto("trackBuilder", "builder.proposalCreate", "{ {}, { costs = 1 } }") == "nil", "with the build right back, it builds")
    same_state(games, "the end of the co-op case")
    QUIET[0] = False
    return games


def test_coop():
    print("co-op")
    games = coop(True)
    host, bob, carl = games
    check(all(len(gm.g().BOOKED) == 0 for gm in games), "no money moved")
    for gm in games:
        err = gm.g().plainErr(gm.g().stateOf())
        check(err is None, gm.name + ": the state is plain data" + (": " + str(err) if err else ""))
    # the interface's half never changes the state
    before = bob.state()
    bob.g().gui()
    bob.allow(buy("Bob#1"))
    bob.veto("bulldozer", "builder.proposalCreate", "{ {}, { costs = 1 } }")
    check(bob.state() == before, "the interface's half leaves the state alone")
    # French
    fr = Game("Bob#1", False, opts=COOP_OPTS, lang="fr")
    fr.run("GAME.st = deser(%r)" % ("{ feat = { perms = " + bob.state() + " } }"))
    ok, why = fr.allow(buy("Bob#1"))
    check(ok is False and why.startswith("Vous n'avez pas le droit d'acheter"), "the refusal in French: " + str(why))
    # determinism: the same scenario run again gives the same state
    again = coop(False)
    check(again[0].state() == host.state(), "the same events in the same order give the same state (a second run)")
    return games


def test_reload(games):
    print("savegame reload")
    host = games[0]
    src = host.state()
    reloaded = Game("Host", True, opts=COOP_OPTS)
    reloaded.run("GAME.st = { feat = { perms = deser(%r) } }" % src)
    # (the game's calendar is in the savegame too)
    reloaded.g().MON = host.g().MON
    check(reloaded.state() == src, "the state read back from its text is the same")
    both = [host, reloaded]
    n = (host.g().stateOf().askSeq or 0) + 1
    steps = [("f_perms_set", "{ key = 'carl', r = 'bd', b = 250000 }", "Host"), ("f_perms_ask", "{ amount = 90000, note = 'x' }", "Carl#2"),
             ("f_perms_answer", "{ n = %d, ok = true }" % n, "Host"),
             ("f_perms_plan", "{ kind = 'route', pts = '0,0;100,0;200,50', name = 'r' }", "Carl#2")]
    res = [ev_all(both, name, p, frm) for name, p, frm in steps]
    check(res == [True, True, True, True], "four events applied after the reload")
    act_all(both, buy("Carl#2", model=13))
    month_all(both, 1951 * 12 + 2)
    check(reloaded.state() == host.state(), "after a reload the game goes on as the one that never stopped")
    check('["carl"]=50000' in host.state() and '["carl"]={["co"]=0,["left"]=90000' in host.state(),
          "Carl's spending counted (50 000, within his budget: the approval untouched)")


def test_server_owner():
    print("the host's decision: a dedicated server's owner")
    srv = Game("MPFever server", True, opts=COOP_OPTS, owner="Olga")
    cli = Game("Olga#1", False, opts=COOP_OPTS, owner="Olga")
    srv.g().gui()
    srv.g().gui()
    cli.g().gui()
    sent_srv = srv.g().takeSent()
    sent_cli = cli.g().takeSent()
    check(len(sent_srv) == 1 and sent_srv[1].name == "f_perms_lead" and sent_srv[1].p == '{["key"]="olga",["on"]=true}',
          "the server's game names its owner a team lead, once")
    check(len(sent_cli) == 0, "a game that is not the host's decides nothing")
    for gm in (srv, cli):
        gm.ev("f_perms_lead", '{["key"]="olga",["on"]=true}', "MPFever server")
    check(srv.state() == cli.state() and '["lead"]={["olga"]=0}' in srv.state(), "applied by every game")
    cli.g().gui()
    check("\nme\tolga\tlead\t" in cli.file(), "Olga is a team lead")
    sep = Game("MPFever server", True, "separate", reg=SEP_REG, opts=COOP_OPTS, owner="Olga")
    sep.g().gui()
    check(len(sep.g().takeSent()) == 0, "not in the separate mode (the owner is the chief of the savegame's company)")


# ---------------------------------------------------------------------------------------------------------------- separate
SEP_REG = r'''{ mode = "separate", canon = 100, start = 2000000, list = {
  { id = 1, key = "host", name = "Host Co", color = 1, ent = 100, members = { { key = "host", sid = "1" } }, chief = "host" },
  { id = 2, key = "alice", name = "Alice Co", color = 2, ent = 200, members = { { key = "alice" }, { key = "bob" } }, chief = "alice" },
  { id = 3, key = "dave", name = "Dave Co", color = 3, ent = 300, members = { { key = "dave" } }, chief = "dave" },
  { id = 4, key = "ai:1", name = "Robot Co", color = 4, ent = 400, members = { { key = "ai:1" } }, chief = "ai:1" },
} }'''
SEP_OPTS = "{ perms = true, plans = true }"


def test_separate():
    print("separate mode")
    host = Game("Host", True, "separate", reg=SEP_REG, my_co=1, opts=SEP_OPTS)
    alice = Game("Alice#1", False, "separate", reg=SEP_REG, my_co=2, opts=SEP_OPTS)
    bob = Game("Bob#2", False, "separate", reg=SEP_REG, my_co=2, opts=SEP_OPTS)
    dave = Game("Dave#3", False, "separate", reg=SEP_REG, my_co=3, opts=SEP_OPTS)
    games = [host, alice, bob, dave]
    gui_all(games)
    check("\nme\talice\ttop\t" in alice.file() and "\nplayer\tbob\tbob\tmember\tbdvlms\tdefault\t0\t0\t0\t1\t1" in alice.file(),
          "Alice is her company's chief and sees Bob")
    check("\nme\tbob\tmember\tbdvlms\t-\t" in bob.file(), "Bob is a member, no limit by default (budget 0 = unlimited)")
    check("\nme\tdave\ttop\t" in dave.file() and "\nplayer\t" not in dave.file(), "Dave, alone, is his company's chief, with nobody to manage")
    check("\nme\thost\ttop\t" in host.file() and "\nplayer\t" not in host.file(), "the host manages nobody of another company")
    check(bob.allow(buy("Bob#2", co=2))[0] is True, "Bob may buy")
    act_all(games, buy("Bob#2", co=2))
    check(alice.request("budget", "bob\t0") is True, "Alice gives Bob a budget of 0")
    check(host.request("budget", "bob\t-1") is False and dave.request("budget", "bob\t-1") is False, "the host and Dave cannot")
    deliver(games)
    for frm in ("Host", "Dave#3"):
        check(ev_all(games, "f_perms_set", "{ key = 'bob', b = -1 }", frm) is False, frm + "'s event over Bob is refused")
    st = same_state(games, "Alice's rule")
    check('["p"]={["bob"]={["b"]=0,["co"]=2,["r"]="bdvlms"}}' in st, "Bob: a budget of 0 in company 2")
    ok, why = bob.allow(buy("Bob#2", co=2))
    check(ok is False and "$0 left" in why, "Bob cannot buy any more")
    check(alice.allow(buy("Alice#1", co=2))[0] is True, "Alice (the chief) is never refused")
    # the request goes to his company's chief only
    bob.request("ask", "1000000\tfreight")
    deliver(games)
    gui_all(games)
    check("Bob asks for approval of $1,000,000: freight" in alice.chat(), "Alice is told")
    check(host.chat() == "" and dave.chat() == "", "the host and Dave are not")
    check(dave.request("answer", "1\t1") is False, "Dave cannot answer it")
    alice.request("answer", "1\t1")
    deliver(games)
    st = same_state(games, "the approval")
    check('["grant"]={["bob"]={["co"]=2,["left"]=1000000' in st, "Bob may spend 1 000 000 for 3 months")
    check(bob.allow(buy("Bob#2", co=2))[0] is True, "Bob buys with the approval")
    act_all(games, buy("Bob#2", co=2))
    # a team lead of a company
    alice.request("lead", "bob\t1")
    deliver(games)
    st = same_state(games, "Bob a lead")
    check('["lead"]={["bob"]=2}' in st, "Bob is a team lead of company 2")
    check(bob.request("right", "alice\tb") is False, "a lead has no say over the chief")
    alice.request("lead", "bob\t0")
    deliver(games)
    # a computer company's builds are nobody's spending; the host's own count for the host
    act_all(games, buy("Host", co=4))
    st = same_state(games, "the computer company's purchase")
    check('["host"]' not in st.split('["spent"]=')[1].split("}")[0], "a computer company's purchase is not counted")
    act_all(games, buy("Host", co=1))
    st = same_state(games, "the host's purchase")
    check('["host"]=600000' in st, "the host's own purchase is counted (it has no limit)")
    check(ev_all(games, "f_perms_set", "{ key = 'ai:1', r = '' }", "Host") is False, "nobody sets a computer company's rights")
    check("ai:1" not in st and "\nplayer\tai" not in host.file(), "a computer company is nowhere in the team's data")
    # plans: seen by the author's company only
    alice.request("note", "Yard\tfor the freight")
    deliver(games)
    gui_all(games)
    check("\nplan\t1\tAlice\tnote\tYard\tfor the freight" in bob.file(), "Bob sees his company's note")
    check("\nplan\t" not in dave.file() and "\nplan\t" not in host.file(), "Dave and the host do not")
    check(bob.g().zoneCount() == 2 and dave.g().zoneCount() == 0 and host.g().zoneCount() == 0, "drawn for company 2 only")
    check(ev_all(games, "f_perms_plandel", "{ id = 1 }", "Bob#2") is False, "Bob cannot delete his chief's note")
    check(ev_all(games, "f_perms_plandel", "{ id = 1 }", "Dave#3") is False, "nor can Dave")
    check(ev_all(games, "f_perms_plandel", "{ id = 1 }", "Host") is False, "nor the host (another company)")
    alice.request("note", "Siding\t")
    deliver(games)
    check(ev_all(games, "f_perms_plandel", "{ id = 2 }", "Alice#1") is True, "Alice deletes her own")
    # Bob leaves: alone in a new company, his chief's rules no longer bind him
    every(games, r'''
      local c2 = GAME.st.co.list[2]
      table.remove(c2.members, 2)
      GAME.st.co.list[5] = { id = 5, key = "bob", name = "Bob Co", color = 5, ent = 500, members = { { key = "bob" } }, chief = "bob" }
    ''')
    bob.g().MYCO = 5
    gui_all(games)
    check("\nme\tbob\ttop\t" in bob.file() and bob.allow(buy("Bob#2", co=5))[0] is True, "Bob, in his own company, may buy again")
    check("\nplan\t" not in bob.file() and bob.g().zoneCount() == 0, "and no longer sees company 2's plans")
    check("\nplayer\tbob\t" not in alice.file(), "Alice no longer lists him")
    check(ev_all(games, "f_perms_set", "{ key = 'bob', r = '' }", "Alice#1") is False, "Alice has no say over him any more")
    st = same_state(games, "Bob left")
    me = ("me\t" + bob.file().split("\nme\t")[1].split("\n")[0]).split("\t")
    check('["grant"]={["bob"]={["co"]=2' in st and me[6] == "0", "his approval of company 2 stays in the data, unused (%s)" % me[6])
    # a bankrupt company: its players have no team until they get a company
    every(games, r'''
      local c2 = GAME.st.co.list[2]
      c2.gone = "bankrupt"; c2.members = {}
    ''')
    gui_all(games)
    check("\nme\talice\tfree\t" in alice.file() and alice.allow(buy("Alice#1"))[0] is True, "Alice, without a company, is refused nothing")
    check(ev_all(games, "f_perms_ask", "{ amount = 5 }", "Alice#1") is False, "and asks for nothing")
    check(ev_all(games, "f_perms_plan", "{ kind = 'note', pts = '1,2' }", "Alice#1") is False, "nor draws a plan")
    check(ev_all(games, "f_perms_plan", "{ kind = 'note', pts = '1,2' }", "Eve#9") is False, "nor does a player no company knows")
    same_state(games, "the end of the separate case")
    for gm in games:
        err = gm.g().plainErr(gm.g().stateOf())
        check(err is None, gm.name + ": the state is plain data" + (": " + str(err) if err else ""))
    check(all(len(gm.g().BOOKED) == 0 for gm in games), "no money moved")


def test_ui():
    print("the window's tab")
    games = coop(False)
    host, bob, carl = games
    bob.request("ask", "250000\tstation")
    deliver(games)
    gui_all(games)
    mk = r'''function(lines, lang)
      local u = { REQ = {}, BTN = {}, TXT = {} }
      u.T = function(fr, en) if lang == "fr" then return fr end return en end
      u.read = function(f) if f == "team" then return lines end return nil end
      u.request = function(k, p) u.REQ[#u.REQ + 1] = k .. "|" .. tostring(p) end
      u.text = function(t) u.TXT[#u.TXT + 1] = t; return { text = t } end
      u.button = function(label, fn, primary, enabled) local b = { label = label, fn = fn, enabled = enabled }; u.BTN[#u.BTN + 1] = b; return b end
      u.row = function(list) return { row = list } end
      return u
    end'''
    for gm in games:
        gm.g().mkU = gm.L.eval(mk)
    hu = host.g().mkU(host.g().FILES["team"], "en")
    rows = host.M.ui(hu)
    texts = "\n".join(hu.TXT.values())
    labels = [b.label for b in hu.BTN.values()]
    check(len(rows) > 5, "the host's tab has rows (%d)" % len(rows))
    check("Role: host, the team's leader" in texts and "Requests to answer" in texts and "Bob: $250,000 station" in texts,
          "the host sees its role and Bob's request")
    check("Accept" in labels and "[x] Build" in labels and "[ ] Vehicles" in labels and "Team lead: no" in labels, "with Accept, the rights toggles and the lead switch")
    for b in hu.BTN.values():
        if b.label == "Accept":
            b.fn()
    n = host.M.model(host.g().FILES["team"]).asks[1].n
    check(list(hu.REQ.values()) == ["answer|%d\t1" % n], "Accept asks for the answer to Bob's request (%d)" % n)
    check(host.request("answer", "%d\t1" % n) is True and deliver(games) == [("f_perms_answer", True)], "which every game applies")
    bu = bob.g().mkU(bob.g().FILES["team"], "fr")
    bob.M.ui(bu)
    texts = "\n".join(bu.TXT.values())
    labels = [b.label for b in bu.BTN.values()]
    check("Rôle : membre" in texts and "Votre demande : 250 000 $, en attente" in texts, "Bob's tab in French: his role and his request")
    check("Retirer ma demande" in labels and "Mode plan : désactivé" in labels, "with Withdraw and the plan mode")
    keep = [b for b in bu.BTN.values() if b.label.startswith("Garder ce tracé")]
    check(len(keep) == 1 and keep[0].enabled is False, "Keep this route is off without a route")
    m = host.M.model(host.g().FILES["team"])
    check(m.opt.perms and m.opt.plans and m.me.role == "top", "the file reads back")
    check(host.M.nextBudget("default") == "-1" and host.M.nextBudget("100000000") == "default", "the budget button goes round")


def test_switch():
    print("MPFEVER_PERMSVETO=0")
    os.environ["MPFEVER_PERMSVETO"] = "0"
    try:
        gm = Game("Bob#1", False, opts=COOP_OPTS)
    finally:
        del os.environ["MPFEVER_PERMSVETO"]
    gm.run("GAME.st = { feat = { perms = { p = { bob = { r = '', b = 0, co = 0 } } } } }")
    check(gm.g().M.VETO_OFF is True, "read at load")
    check(gm.allow(buy("Bob#1"))[0] is True and gm.veto("bulldozer", "builder.proposalCreate", "{ {}, { costs = 1 } }") == "nil",
          "nothing refused on this game")
    plain = Game("Bob#1", False, opts=COOP_OPTS)
    plain.run("GAME.st = { feat = { perms = { p = { bob = { r = '', b = 0, co = 0 } } } } }")
    check(plain.allow(buy("Bob#1"))[0] is False, "without the switch, refused")


# ------------------------------------------------------------------------------------------------- integrated (the real hooks)
# The module through the real options host (mpfever_feat.lua) and the bridge's and the window's real functions, taken from their
# files: the options applied from the host's f_opts, the window's requests through stampHeld, the refusals of a command and of a
# speed request before anything is sent, the answers of guiHandleEvent, a tool's build counted on the builder's game and on the
# replaying one alike (SIM.featNative / SIM.featWho, the session name told by f_me), the year from the calendar, and the tab drawn
# by the window's own U.featU. Everything with the options off first: nothing at all.
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")


def read_content(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return f.read()


def extract(src, pattern, what, local=False):
    import re
    m = re.search(pattern, src, re.S | re.M)
    if not m:
        print("  FAIL  " + what + " not found")
        failures.append(what + " not found")
        return ""
    code = m.group(0)
    # (a local function of the bridge's main chunk becomes a global of the test's runtime)
    return code.replace("local function ", "function ", 1) if local else code


BRIDGE_SRC = read_content("mpfever_bridge.script.lua")
UI_SRC = read_content("mpfever_ui.script.lua")
BRIDGE_PARTS = [
    extract(BRIDGE_SRC, r"^SIM\.featEvent = function\(st, name, param\)\n.*?^end\n", "SIM.featEvent"),
    extract(BRIDGE_SRC, r"^SIM\.featNative = function\(state, param, seq0\)\n.*?^end\n", "SIM.featNative"),
    extract(BRIDGE_SRC, r"^SIM\.featWho = function\(st, a, own, now\)\n.*?^end\n", "SIM.featWho"),
    extract(BRIDGE_SRC, r"^SIM\.featBuildCo = function\(args\)\n.*?^end\n", "SIM.featBuildCo"),
    extract(BRIDGE_SRC, r"^G\.featBridge = function\(\)\n.*?^end\n", "G.featBridge"),
    extract(BRIDGE_SRC, r"^G\.featGui = function\(st\)\n.*?^end\n", "G.featGui"),
    extract(BRIDGE_SRC, r"^G\.featRefuse = function\(p\)\n.*?^end\n", "G.featRefuse"),
    extract(BRIDGE_SRC, r"^G\.featGuiVeto = function\(id, name, param\)\n.*?^end\n", "G.featGuiVeto"),
    extract(BRIDGE_SRC, r"^G\.featRequest = function\(p\)\n.*?^end\n", "G.featRequest"),
    # (0.8.11, #331: stampHeld sends a game script's bursts as one action, see G.gsBatchable)
    extract(BRIDGE_SRC, r"^G\.GSBATCH_MIN, G\.GSBATCH_MAX = .*?\n", "G.GSBATCH_MIN"),
    extract(BRIDGE_SRC, r"^G\.gsBatchable = function\(p\)\n.*?^end\n", "G.gsBatchable"),
    extract(BRIDGE_SRC, r"^local function stampHeld\(\)\n.*?^end\n", "stampHeld", local=True),
    extract(BRIDGE_SRC, r"^local function guiHandleEvent\(userParams, state, guiState, src, id, name, param\)\n.*?^end\n", "guiHandleEvent", local=True),
]
WINDOW_PART = extract(UI_SRC, r"^U\.featOff = .*?^U\.featTabRows = function\(K, st, key\)\n.*?^end\n", "the window's game options")

# the bridge's and the window's surroundings, mocked: a game of its own per runtime
IHARNESS = r'''
NOW, MCOUNT, YEAR = 100000, 100, 1950
LOGS, CHAT, EVENTS, SIMQ, SENTL, QUEUED, UILINES, FS, REQLINES = {}, {}, {}, {}, {}, {}, {}, {}, {}
function log(s) LOGS[#LOGS + 1] = tostring(s) end
function countLogs(pat) local n = 0 for _, l in ipairs(LOGS) do if l:find(pat, 1, true) then n = n + 1 end end return n end
function gameTime() return NOW end
function T(fr, en) return en end
function money(n) return tostring(n) end
BS, TAB, NL = "/", "\t", "\n"
K = { FEAT = true }
R, CO = {}, {}
GAME = { st = {} }
STATE = { get = function() return GAME.st end, set = function() end }
FEATCALLS = 0
C = { ROLE = "client", NAME = "nobody", SERVER = false, DIR = "D", BS = "/", NL = "\n", CR = "\r", ACTIVE = true,
  T = function(fr, en) return en end, Tf = function(fr, en) return en end,
  line = function(kind, r) return kind .. " " .. tostring(r.tok) .. " " .. tostring(r.success) .. " " .. tostring(r.err) end,
  appendFile = function(path, text) FS[path] = (FS[path] or "") .. text return true end,
  deser = function(p) return p end,
  ser = function(v) return ser(v) end,
  IO = { open = function(path, mode)
    if mode == "wb" then local buf = {} return { write = function(_, s) buf[#buf + 1] = s end, close = function() FS[path] = table.concat(buf) end } end
    local s = FS[path]
    if not s then return nil end
    return { read = function() return s end, close = function() end } end } }
C.feat = function() FEATCALLS = FEATCALLS + 1 return F end
G = { frames = 1000, session = { started = true, resync = false }, connected = true, cmode = "shared", peers = {}, oseq = 0,
  me = "nobody", myCo = nil, waits = {}, modWait = {} }
G.coEvent = function(name, param) EVENTS[#EVENTS + 1] = { name = name, p = ser(param or {}), from = G.me } end
G.featChat = function(t) CHAT[#CHAT + 1] = t return true end
G.resyncRefuse = function() return false end
G.uiEdit = function() return nil end
G.pvPoints = function(param) return param.pts or {} end
SIM = {}
SIM.featBridge = function()
  return { log = log, gameTime = gameTime, STEP = 200, R = R, CO = CO,
    money = function() return 0 end, book = function() error("no money moves in perms") end,
    companies = function() return {} end, month = function() return MCOUNT end,
    date = function() return { year = YEAR, month = 1, day = 1 } end }
end
function toSim(name, p) SIMQ[#SIMQ + 1] = { name = name, p = ser(p) } end
function send(kind, p) SENTL[#SENTL + 1] = kind end
function queueLocal(a) QUEUED[#QUEUED + 1] = a.fn end
function stampFor(t) return t + 400 end
function pausedStamp(t) return t end
function gameSpeed() return 1 end
function readLines(name) if name ~= "ui.log" then return {} end local l = UILINES; UILINES = {} return l end
function parseLine(line) return line.kind, nil, line.p end
function ui(kind, p) UILINES[#UILINES + 1] = { kind = kind, p = p } end
-- the window's
U = { isHost = function(st) return st and st.host == true end, winChanged = function() end }
function sendLine(kind, p) REQLINES[#REQLINES + 1] = kind .. " " .. tostring(p.m) .. " " .. tostring(p.kind) .. " " .. tostring(p.payload) end
WK = { TEXT_W = 556, ICON_SETTINGS = "i", builtin = { TextInputField = function(t) return { kind = "input", key = t.meta.localKey, on = t.onValueChange } end },
  style = function(s) return s end }
function WK.text(t, class, cls, w) return { kind = "text", t = tostring(t) } end
function WK.muted(t, w) return { kind = "muted", t = tostring(t) } end
function WK.section(icon, t) return { kind = "section", t = t } end
function WK.gap() return { kind = "gap" } end
function WK.row(c) return { kind = "row", c = c } end
function WK.col(c) return { kind = "col", c = c } end
function WK.btn(label, tip, fn, primary, enabled) return { kind = "btn", t = label, fn = fn, primary = primary, enabled = enabled ~= false } end
-- (the 1 s rate of the modules' gui: every call of the test runs it)
function guiNow() F.guiAt = -10; G.frames = G.frames + 1; G.featGui(GAME.st) end
function simDeliver()
  local q = SIMQ; SIMQ = {}
  for _, e in ipairs(q) do SIM.featEvent(GAME.st, e.name, deser(e.p)) end
end
function permsSrc() return ser(GAME.st.feat and GAME.st.feat.perms) end
'''


class IGame:
    """A game of the integrated test: the options host, the module, the bridge's and the window's real hook functions."""

    def __init__(self, me, role):
        self.L = lua52.LuaRuntime(unpack_returned_tuples=True)
        self.L.execute(HARNESS)       # (ser, deser, plainErr)
        self.L.execute(IHARNESS)
        g = self.L.globals()
        g.PERMS_SRC = SRC
        g.F = self.L.execute(read_content("mpfever_feat.lua"))
        self.L.execute(r'''
        PRICES = { [11] = 600000, [12] = 150000 }
        ZONES = {}
        F.loader = function(id)
          if id ~= "perms" then return nil end
          local M = load(PERMS_SRC, "=perms")()
          M.modelPrice = function(i) return PRICES[i] or 0 end
          M.draw = { circle = function(k, x, y) ZONES[k] = { x, y } end, remove = function(k) ZONES[k] = nil end,
            focus = function() end, center = function() return 10, 20, 0 end }
          PERMS = M
          return M
        end
        F.load(log)
        ''')
        for part in BRIDGE_PARTS:
            if part:
                self.L.execute(part)
        if WINDOW_PART:
            self.L.execute(WINDOW_PART)
        g.G.me, g.C.NAME, g.C.ROLE = me, me.split("#")[0], role
        self.name = me

    def run(self, code):
        return self.L.execute(code)

    def g(self):
        return self.L.globals()


def ideliver(games):
    """The events the games' interfaces sent (G.coEvent), applied by every game in the same order, with their sender as the bridge
    stamps it (mpfFrom), through the bridge's SIM.featEvent. Returns the names."""
    names = []
    for src in games:
        evs = src.g().EVENTS
        src.run("EVENTS = {}")
        for i in range(1, len(evs) + 1):
            e = evs[i]
            names.append(e.name)
            for gm in games:
                gm.g().ev_in = gm.L.eval("function(p, from) local t = deser(p); t.mpfFrom = from; SIM.featEvent(GAME.st, '%s', t) end" % e.name)
                gm.g().ev_in(e.p, e["from"])
    return names


def test_integrated():
    print("integrated: the options host, the bridge's and the window's real functions")
    host, bob = IGame("Host", "host"), IGame("Bob#1", "client")
    games = [host, bob]
    opts = "perms=1;perms.budget=1000000;plans=1"
    # ---- all off: nothing at all
    for gm in games:
        gm.run("guiNow()")
        gm.run("ui('speed_req', { speed = 2 }); stampHeld()")
        r = gm.run("return guiHandleEvent(nil, nil, nil, 'src', 'bulldozer', 'builder.proposalCreate', { {}, { costs = 5 } })")
        g = gm.g()
        check(g.FEATCALLS == 0 and len(g.EVENTS) == 0 and len(g.SIMQ) == 0 and len(g.FS) == 0 and r is None,
              gm.name + ", options off: no hook, no event, no note to the simulation, no file, no answer to a tool")
        check(len(g.SENTL) == 1 and g.SENTL[1] == "speed_req", gm.name + ", options off: a speed request goes to MPFever.exe as before")
        gm.run("SENTL = {}")
    # ---- the host's options into the game (f_opts), applied by every game
    host.g().G.featOpts = opts
    for gm in games:
        gm.run("guiNow()")
    check([n for n in ideliver(games)] == ["f_opts"], "the host's game sends f_opts")
    for gm in games:
        gm.run("guiNow()")
        g = gm.g()
        check(g.GAME.st.optsText == opts and g.G.featOn and g.G.featAllow and g.G.featVeto, gm.name + ": the options on, allow and the tools' answers wanted")
    check(len(bob.g().SIMQ) == 1 and bob.g().SIMQ[1].name == "f_me", "Bob's game tells its simulation its session name (f_me)")
    for gm in games:
        gm.run("simDeliver()")
    check(bob.g().SIM.featMe == "Bob#1" and host.g().SIM.featMe == "Host", "the simulations know their game's session name")
    bob.run("SIM.featEvent(GAME.st, 'f_me', { name = 'Eve', mpfFrom = 'Eve#3' })")
    check(bob.g().SIM.featMe == "Bob#1", "an f_me of another game (an action, with its sender) is ignored")
    check("\nme\tbob\tmember\tbdvlms\t1000000\t0" in (bob.g().FS["D/feat_perms_team.txt"] or ""), "Bob's window file: a member with the default budget")
    # ---- the host takes Bob's vehicles right away from its window (feat_req through stampHeld)
    host.run("ui('feat_req', { m = 'perms', kind = 'right', payload = 'bob\\tv' }); stampHeld()")
    check(ideliver(games) == ["f_perms_set"], "the host's window request becomes f_perms_set")
    check(host.g().permsSrc() == bob.g().permsSrc() and '["bob"]={["co"]=0,["r"]="bdlms"}' in host.g().permsSrc(), "both games: Bob bdlms")
    for gm in games:
        gm.run("guiNow()")
    # ---- Bob's purchase refused before anything is sent; the window's command gets its refusal
    bob.run("CHAT = {}; ui('act_req', { tok = 'tk', id = 4, fn = 'makeVehicleBuyCmd', args = { n = 3, 1, 2, { vehicles = { { part = { modelId = 11 } } } } } }); stampHeld()")
    g = bob.g()
    check(len(g.SENTL) == 0 and len(g.QUEUED) == 0, "Bob's purchase is neither sent nor applied")
    check("result tk false game option: You may not buy" in (g.FS["D/results.log"] or ""), "the window's command gets its refusal (results.log)")
    check(len(g.CHAT) == 1 and "You may not buy" in g.CHAT[1] and g.G.featRefused == 1, "Bob's chat says why")
    host.run("ui('act_req', { tok = 'th', id = 1, fn = 'makeVehicleBuyCmd', args = { n = 3, 1, 2, { vehicles = { { part = { modelId = 11 } } } } } }); stampHeld()")
    check(list(host.g().SENTL.values()) == ["act"] and list(host.g().QUEUED.values()) == ["makeVehicleBuyCmd"], "the host's purchase goes (the leader is never restricted)")
    # ---- speed and pause: allowed, then refused once the right is taken, the chat said once for repeated requests
    bob.run("SENTL = {}; ui('speed_req', { speed = 0 }); stampHeld()")
    check(list(bob.g().SENTL.values()) == ["speed_req"], "Bob's pause goes to MPFever.exe while he has the right")
    host.run("ui('feat_req', { m = 'perms', kind = 'right', payload = 'bob\\ts' }); stampHeld()")
    ideliver(games)
    bob.run("SENTL = {}; CHAT = {}; ui('speed_req', { speed = 0 }); ui('speed_req', { speed = 0 }); stampHeld()")
    g = bob.g()
    check(len(g.SENTL) == 0 and g.G.featRefused == 3, "without it both requests are refused here")
    check(len(g.CHAT) == 1 and "speed" in g.CHAT[1], "and the chat says it once")
    # ---- guiHandleEvent answers: the store's button, the line window, the tools
    r = bob.run("return guiHandleEvent(nil, nil, nil, 'src', 'vehicleStore', 'mission.buyVehicle', { modelId2quantity = { [12] = 1 } })")
    check(isinstance(r, str) and "You may not buy" in r, "the store's buy button is off for Bob: " + str(r))
    check(bob.run("return guiHandleEvent(nil, nil, nil, 'src', 'management.line', 'delete', 5)") is None, "Bob may delete a line")
    check(bob.run("return guiHandleEvent(nil, nil, nil, 'src', 'bulldozer', 'builder.proposalCreate', { {}, { costs = 10 } })") is None, "Bob's bulldozer is not turned down")
    host.run("ui('feat_req', { m = 'perms', kind = 'right', payload = 'bob\\tb' }); stampHeld()")
    ideliver(games)
    r = bob.run("local r = guiHandleEvent(nil, nil, nil, 'src', 'trackBuilder', 'builder.proposalCreate', { {}, { costs = 10 } }); return next(r.errorMessages), r.skipRender")
    check(r[0] == "You may not build (your team's rule)." and r[1] is False, "Bob's track tool is turned down, its route still shown")
    check(bob.g().countLogs("trackBuilder/builder.proposalCreate answered by perms") == 1, "the answer is logged for the in-game check")
    bob.run("guiHandleEvent(nil, nil, nil, 'src', 'trackBuilder', 'builder.proposalApply', { {}, { costs = 10 } })")
    check(bob.g().countLogs("feat perms: WARNING the tool trackBuilder applied a build") == 1, "a build applied although turned down is logged")
    check(host.run("return guiHandleEvent(nil, nil, nil, 'src', 'trackBuilder', 'builder.proposalCreate', { {}, { costs = 10 } })") is None, "the host's tool is not")
    host.run("ui('feat_req', { m = 'perms', kind = 'right', payload = 'bob\\tb' }); stampHeld()")
    ideliver(games)
    # ---- a tool's build: counted for its builder on its own game (the capture) and on the other (the replay), once
    bob.run("""local s0 = GAME.st.outSeq or 0
      GAME.st.out = { { n = s0 + 1, at = NOW, cost = 300000, args = {} } }
      GAME.st.outSeq = s0 + 1
      SIM.featNative(STATE, { 'proposal', 'data' }, s0)""")
    host.run("""GAME.st.rcost = { { at = NOW, uid = 'Bob#1:7', cost = 300000, got = 0, n = 0 } }
      SIM.replayBuildAt = NOW
      SIM.featNative(STATE, { 'proposal', 'data' }, GAME.st.outSeq or 0)
      SIM.featNative(STATE, { 'proposal2', 'data2' }, GAME.st.outSeq or 0)""")
    hs, bs = host.g().permsSrc(), bob.g().permsSrc()
    check(hs == bs and '["spent"]={["bob"]=300000}' in hs, "Bob's build of 300 000 counted once on both games")
    check(host.g().countLogs("feat perms: bob spends 300000 (nativeBuild)") == 1, "the spending is logged")
    bob.run("SIM.featMe = nil; GAME.st.out[1].n = 9; GAME.st.outSeq = 9; local a = {}; SIM.featWho(GAME.st, a, true, NOW); WHO = a.origin")
    check(bob.g().WHO is None and bob.g().countLogs("session name is not known yet") == 1, "before f_me, an own build has no builder (logged)")
    bob.run("SIM.featMe = 'Bob#1'")
    check(host.run("return SIM.featBuildCo({ proposal = { a = { k = 'player', co = 4 }, b = { k = 'player', co = 4 }, c = { k = 'player', co = 2 } } })") == 4,
          "the company a captured build names most (a computer company's, on the host's game)")
    # ---- the year from the calendar (H5: 1 January), the months from the game months
    for gm in games:
        gm.run("F.simTick(GAME.st, SIM.featBridge()); MCOUNT = 101; F.simTick(GAME.st, SIM.featBridge())")
    check('["year"]=1950' in host.g().permsSrc() and '["mon"]=101' in host.g().permsSrc(), "the year from the calendar, the month from the game months")
    for gm in games:
        gm.run("MCOUNT = 102; F.simTick(GAME.st, SIM.featBridge())")
    check('["spent"]' in host.g().permsSrc(), "the spending stays within the year")
    for gm in games:
        gm.run("YEAR = 1951; MCOUNT = 103; F.simTick(GAME.st, SIM.featBridge())")
    check('["spent"]' not in host.g().permsSrc() and host.g().permsSrc() == bob.g().permsSrc(), "1 January: the year's spending back to 0 on both games")
    check(host.run("return PERMS.yearNow({}, 25)") == 2, "without the calendar: twelve game months a year")
    # ---- the window's tab, drawn by the window's own helpers (U.featU)
    bob.run("ui('feat_req', { m = 'perms', kind = 'ask', payload = '250000\\tdepot' }); stampHeld()")
    ideliver(games)
    for gm in games:
        gm.run("guiNow()")
    check("Bob asks for approval of" in "\n".join(host.g().CHAT.values()), "the host is told of Bob's request in its chat")
    rows = host.run("ROWS = U.featTabRows(WK, { mode = 'shared', opts = '%s', host = true, me = 'Host' }, 'f_team'); return #ROWS" % opts)
    labels = host.run(r'''local out, most = {}, 0
      for _, r in ipairs(ROWS) do
        if r.kind == "row" then
          local n = 0
          for _, b in ipairs(r.c) do if b.kind == "btn" then n = n + 1; out[#out + 1] = b.t end end
          if n > most then most = n end
        end
      end
      return table.concat(out, "|"), most''')
    check(rows > 8 and "Accept" in labels[0] and "[ ] Vehicles" in labels[0] and labels[1] <= 3,
          "the host's tab: Accept and the rights toggles, three buttons a row at most (%d rows)" % rows)
    host.run(r'''for _, r in ipairs(ROWS) do if r.kind == "row" then for _, b in ipairs(r.c) do if b.t == "Accept" then b.fn() end end end end''')
    check(any(l.startswith("feat_req perms answer 1\t1") for l in host.g().REQLINES.values()), "Accept: the window's request to the module (feat_req)")
    bob.run("ROWS = U.featTabRows(WK, { mode = 'shared', opts = '%s', me = 'Bob#1' }, 'f_team')" % opts)
    inputs = bob.run(r'''local n = 0 for _, r in ipairs(ROWS) do if r.kind == "input" then n = n + 1; if n == 1 then r.on("123456") end end end return n''')
    check(inputs >= 2, "the tab's text fields (u.input of the window): %d" % inputs)
    check(bob.run("return PERMS.UIV.name") == "123456", "a text field gives its text to the module (the plan's name)")
    check(bob.g().countLogs("failed") == 0 and host.g().countLogs("failed") == 0, "no hook failed (%s)" % [l for l in host.g().LOGS.values() if "failed" in l][:2])


def main():
    test_declarations()
    test_off()
    games = test_coop()
    test_reload(games)
    test_server_owner()
    test_separate()
    test_ui()
    test_switch()
    test_integrated()
    if failures:
        print(f"FAIL {len(failures)} check(s):")
        for f in failures:
            print("   " + f)
        return 1
    print("PASS all checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
