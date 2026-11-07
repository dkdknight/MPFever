"""Offline test of the game's rules of 0.5.14 (one company per player): the start money of a new company, the sharing rules
on or off, the computer companies' settings, kept in the savegame.

mpfever_co.lua and mpfever_eco.lua are loaded whole; G.coEco and the first lines of H.session are taken from the real
bridge file. All run through lupa (Lua 5.2) with a mocked game. Cases:
  - mpfever_eco.lua's co_rules event: from the host only, months among the choices, the sharing rules switched off kept (and
    kept when an event says nothing of them), the start money kept from 0 to 10 billion only (floored), the computer
    companies' text checked (digits, ':', ',' and '-', 300 characters at most), the "mpfrules:" text MPFever.exe reads back (0.7.4: with the auction's rule, auction=mode:minutes);
  - E.sharingOff: every track, station, stop and depot open and free whatever the companies set, their settings counting
    again once the rules are back on;
  - the bridge's sender (G.coEco on the host's game): the sharing rules switched off are sent ("newRules and false or nil"
    gave nil: the rules stayed on, found by test o1), a start money the rules cannot keep is not sent again every 10 s
    (review fix), at most one event every 600 frames, MPFEVER_SHARESWITCH=0: the bankruptcy only, as before; the eco.txt
    lines of the Game tab ("share", "start");
  - H.session: the host's choice read (false or 0: off; none: on).
Run: python tests/test_gamerules.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
BRIDGE = os.path.join(CONTENT, "mpfever_bridge.script.lua")

MOCK = r'''
ENV = {}
local realTime = os.time
os.getenv = function(k) return ENV[k] end
api = { engine = { util = { finance = { getPlayersBalance = function() return 0 end } } } }
LOGS, EVENTS, FILES = {}, {}, {}
ENVE = { log = function(s) LOGS[#LOGS + 1] = s end, gameTime = function() return 0 end }
'''

# the interface's half of the bridge around G.coEco
BRIDGE_MOCK = r'''
NL, BS = "\n", "\\"
C = { ROLE = "host", DIR = "dir", eco = function() return E end,
  IO = { open = function(p, mode) local f = { t = {} } function f:write(s) self.t[#self.t + 1] = s end function f:close() FILES[p] = table.concat(self.t) end return f end },
  Tf = function(fr, en, ...) return string.format(en, ...) end }
G = { frames = 1000, session = { started = false }, coMyKey = function() return "host" end,
  coEvent = function(name, p) EVENTS[#EVENTS + 1] = { name = name, p = p } end, coNewsSay = function() end }
H = {}
function log(s) LOGS[#LOGS + 1] = s end
function uiRequest() end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m_eco = re.search(r"^G\.coEco = function\(st, reg, c\)\n.*?^end\n", src, re.S | re.M)
    m_ses = re.search(r"^H\.session = function\(from, p\)\n(.*?if p\.cmode ~= nil then G\.coAi = p\.ai end\n)", src, re.S | re.M)
    if not (m_eco and m_ses):
        print("FAIL: G.coEco or H.session not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK)
    CO = L.execute(open(os.path.join(CONTENT, "mpfever_co.lua"), encoding="utf-8").read())
    L.globals().CO = CO
    L.execute("ENVE.CO = CO")
    L.globals().E = L.execute(open(os.path.join(CONTENT, "mpfever_eco.lua"), encoding="utf-8").read())
    L.execute(BRIDGE_MOCK)
    L.execute(m_eco.group(0))
    L.execute("H.session = function(from, p)\n" + m_ses.group(1) + "end\n")
    lua_run = L.eval("function(code) local f = assert(load(code)) return f() end")

    def run(code):
        # (a Lua error is a result too: the case that gets it fails, the others still run)
        try:
            return lua_run(code)
        except lupa.LuaError as e:
            return "LUA ERROR " + str(e).splitlines()[0]
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    run(r'''
st = { co = CO.new("separate", 100, 2000000) }
CO.join(st.co, "host", "Host", true, "Host Co", "s1", 1)
local c2 = CO.join(st.co, "bob", "Bob", false, "Bob Co", "s2", 2)
c2.ent = 200
function rules(p, from)
  p.mpfFrom = from or "Host"
  E.event(st, "co_rules", p, ENVE)
  local r = st.co.rules or {}
  return tostring(r.bankrupt) .. " " .. tostring(r.share) .. " " .. tostring(r.start) .. " " .. tostring(r.ai) .. " | " .. tostring(r.cfg)
end
''')
    print("co_rules (mpfever_eco.lua)")
    check("a player's game cannot set the rules", run('return rules({ bankrupt = 6, share = false }, "Bob#1")') == "nil nil nil nil | nil")
    check("months not among the choices: refused", run('return rules({ bankrupt = 5 })') == "nil nil nil nil | nil")
    got = run('return rules({ bankrupt = 12 })')
    check("the bankruptcy only: the text MPFever.exe reads back", got == "12 nil nil nil | mpfrules:bankrupt=12;share=1;start=;ai=;auction=assets:5;", got)
    got = run('return rules({ bankrupt = 6, share = false, start = 5000000, ai = "1:7:3:1000000,2:3:1:-1" })')
    check("sharing off, start money, computer companies", got ==
          "6 false 5000000 1:7:3:1000000,2:3:1:-1 | mpfrules:bankrupt=6;share=0;start=5000000;ai=1:7:3:1000000,2:3:1:-1;auction=assets:5;", got)
    check("the log says the sharing rules are off", any("OFF" in str(s) for s in L.globals().LOGS.values()))
    got = run('return rules({ bankrupt = 6 })')
    check("an event that says nothing of them keeps them (sharing still off)", got.startswith("6 false 5000000 1:7:3:1000000,2:3:1:-1"), got)
    got = run('return rules({ bankrupt = 6, share = true })')
    check("sharing on again", got.startswith("6 true 5000000") and "share=1;" in got, got)
    check("a start money under 0: not kept", run('return rules({ bankrupt = 6, start = -1 })').startswith("6 true 5000000 "))
    check("over 10 billion: not kept", run('return rules({ bankrupt = 6, start = 1e10 + 1 })').startswith("6 true 5000000 "))
    got = run('return rules({ bankrupt = 6, start = 1e10 })')
    check("10 billion: kept", got.startswith("6 true 10000000000 ") and "start=10000000000;" in got, got)
    check("not a number: not kept", run('return rules({ bankrupt = 6, start = "abc" })').startswith("6 true 10000000000 "))
    check("0: kept", run('return rules({ bankrupt = 6, start = 0 })').startswith("6 true 0 "))
    check("a fraction: floored", run('return rules({ bankrupt = 6, start = 2500000.7 })').startswith("6 true 2500000 "))
    keep = "6 true 2500000 1:7:3:1000000,2:3:1:-1 "
    check("a computer companies' text with ';': refused", run('return rules({ bankrupt = 6, ai = "1:7:2;x=1" })').startswith(keep))
    check("with letters: refused", run('return rules({ bankrupt = 6, ai = "1:7:a" })').startswith(keep))
    check("over 300 characters: refused", run('return rules({ bankrupt = 6, ai = string.rep("1", 301) })').startswith(keep))
    check("not a text: refused", run('return rules({ bankrupt = 6, ai = 12 })').startswith(keep))
    check("an empty text: kept (no computer company)", run('return rules({ bankrupt = 6, ai = "" })').startswith("6 true 2500000  |"))

    print("E.sharingOff: everything open and free")
    run(r'''
st.co.track = { ["2"] = { rule = "private" } }
st.co.stops = { ["2"] = { rule = "toll", fee = 500 } }
st.co.depotCo = { ["2"] = { rule = "private", toll = 1000 } }
st.co.depots = { d1 = { rule = "private" } }
st.co.stationRule = { sg1 = { rule = "private", fee = 0, co = 2 } }
function rulesNow()
  local c2 = CO.find(st.co, 2)
  local r, f, own = E.stationRule(st.co, "sg1", 2)
  return E.trackRule(st.co, c2).rule .. " " .. E.stopRule(st.co, c2).rule .. " " .. E.depotCoRule(st.co, c2).rule .. " "
    .. E.depotRule(st.co, "d1", 2).rule .. " " .. r .. "/" .. f .. "/" .. tostring(own) .. " " .. tostring(E.anyStopFee(st.co))
end
''')
    got = run("st.co.rules.share = true; return rulesNow()")
    check("rules on: each company's settings", got == "private toll private private private/0/true true", got)
    got = run("st.co.rules.share = false; return tostring(E.sharingOff(st.co)) .. ' ' .. rulesNow()")
    check("rules off: open and free", got == "true open open open open open/0/false false", got)
    got = run("st.co.rules.share = nil; return tostring(E.sharingOff(st.co)) .. ' ' .. rulesNow()")
    check("none set: on, the settings kept", got == "false private toll private private private/0/true true", got)

    print("the host's sender (G.coEco)")
    run(r'''
st.co.track, st.co.stops, st.co.depotCo, st.co.depots, st.co.stationRule = nil, nil, nil, nil, nil
st.co.rules = { bankrupt = 12 }
function send(env, frames)
  ENV = env or {}
  EVENTS = {}
  G.frames = frames or (G.frames + 601)
  G.coEco(st, st.co, CO.find(st.co, 1))
  ENV = {}
  if #EVENTS > 0 then LAST = EVENTS[#EVENTS] end
  local t = {}
  for _, e in ipairs(EVENTS) do
    t[#t + 1] = e.name .. " bankrupt=" .. tostring(e.p.bankrupt) .. " share=" .. tostring(e.p.share) .. " start=" .. tostring(e.p.start) .. " ai=" .. tostring(e.p.ai)
  end
  return table.concat(t, " ; ")
end
function apply()
  local p = LAST.p
  local q = {}
  for k, v in pairs(p) do q[k] = v end
  return rules(q)
end
''')
    got = run('G.coBankrupt, G.coShare, G.coStart, G.coAi = 12, false, nil, nil; return send()')
    check("sharing switched off in the lobby: sent as false", got == "co_rules bankrupt=12 share=false start=nil ai=nil", got)
    got = run("apply(); return tostring(st.co.rules.share) .. ' ' .. send()")
    check("kept by the game, then nothing more to send", got == "false ", got)
    got = run('G.coShare = true; local a = send(); local b = send(nil, G.frames + 100); return a .. " | " .. b')
    check("on again: sent once, not again within 600 frames", got == "co_rules bankrupt=12 share=true start=nil ai=nil | ", got)
    run("apply()")
    got = run('G.coStart = 2e10; return send() .. "|" .. send()')
    check("a start money the rules cannot keep: not sent (it went every 10 s)", got == "|", got)
    got = run('G.coStart = -5; return send()')
    check("nor one under 0", got == "", got)
    got = run('G.coStart = 5000000; local a = send(); apply(); return a .. " | " .. send()')
    check("a start money: sent, then kept", got == "co_rules bankrupt=12 share=true start=5000000 ai=nil | ", got)
    got = run('G.coAi = "1:7:2:-1"; local a = send(); apply(); return a .. " | " .. send()')
    check("the computer companies: sent, then kept", got == "co_rules bankrupt=12 share=true start=5000000 ai=1:7:2:-1 | ", got)
    got = run('G.coBankrupt, G.coShare = 6, false; return send({ MPFEVER_SHARESWITCH = "0" })')
    check("MPFEVER_SHARESWITCH=0: the bankruptcy only, as before", got == "co_rules bankrupt=6 share=nil start=nil ai=nil", got)
    got = run('G.coBankrupt = 12; return send({ MPFEVER_SHARESWITCH = "0" })')
    check("MPFEVER_SHARESWITCH=0: nothing else compared", got == "", got)
    got = run('C.ROLE = "client"; G.coShare = false; local r = send(); C.ROLE = "host"; return r')
    check("another game sends nothing", got == "", got)
    got = run(r'''
st.co.rules.share = false
st.co.rules.start = 3000000
send()
local t = FILES["dir\\eco.txt"] or ""
return (t:match("share\t%d") or "?") .. " " .. (t:match("start\t%d+") or "?")
''')
    check("eco.txt tells the Game tab: share 0, start 3000000", got == "share\t0 start\t3000000", got)

    print("H.session")
    got = run(r'''
local out = {}
for _, v in ipairs({ "nil", "false", "0", "true", "1" }) do
  local p = { cmode = "separate" }
  if v == "false" then p.share = false elseif v == "true" then p.share = true elseif v ~= "nil" then p.share = tonumber(v) end
  G.coShare = "x"
  H.session("Host", p)
  out[#out + 1] = v .. "=" .. tostring(G.coShare)
end
G.coShare = "x"
H.session("Host", { share = false })
out[#out + 1] = "no mode=" .. tostring(G.coShare)
return table.concat(out, " ")
''')
    check("the sharing rules read: false and 0 off, none on; a session without a mode changes nothing", got ==
          "nil=true false=false 0=false true=true 1=true no mode=x", got)

    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
