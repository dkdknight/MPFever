"""Test of #148's fix (0.7.13, MPFEVER_BUYMONEY): a vehicle purchase the engine refused says why, and its buyer is told.

#148 (0.7.9, three players) and #170 (0.7.12): 27 of 154 purchases, then 29, ended as "action X result after 10 step(s): nothing
created", taken for an MPFever fault. The engine refused them on every game alike (no resync, no id taken): the buying company
had less money than the price when the purchase was applied (vehicle_util_engine::BuyVehicle 0x26a8480, its check 0xcd5f30 as the
tools' "Not enough money"; most were the line manager's clones, one purchase per vehicle with no money check). AMD:11: price
367,290, company money 275,888; AMD:48-51: 1,231,077 -> 238,076 = 3 x 331,000, the 4th refused. Nothing told the buyer.

Now (mod/mpfever_1/content):
  - C.buyWhy / C.buyNote (mpfever_common.lua): the engine's rule (price above the money, a depot toll taken off; unlimited money,
    balance nil: never) and the note for mod.log;
  - executeActionOnce (mpfever_bridge.script.lua): the price (getPartPrice of the rebuilt configuration's parts, else the
    models' cost) and the buyer's money, read when the purchase goes to the engine; on the result (paused: in the callback) and
    with the watch (running); the watch's end and the paused line say "(not enough money: price P, company money B)";
    "action X result after N step(s): entity E" stays byte for byte (idcmp.py), r.err stays "created entity not found";
  - G.reportResult: act_refused carries why, price and balance;
  - U.buyRefusedText / U.buyRefusedShow (mpfever_ui.script.lua): the buyer's notice, two short items (the notice cuts at 70
    characters), shown from pollResults for this player's own purchases (and the autotests' ones, H.buypoor);
  - H.buypoor: the in-game scenario.
A depot toll's fee goes on the result as tollFee: result.toll stays the owner guard's { from, to, fee }, which the pause's end
sends to the simulation (SIM.noteDepotToll keeps only a table; the fee in its place lost every toll paid in a pause, #122 back).
The general notice ("refused by the game") only for the engine's refusals (no err, or "created entity not found"); a purchase
MPFever itself refused (another company's depot, missing entities...) says nothing, as in 0.7.12.
MPFEVER_BUYMONEY=0: nothing read, nothing said, as in 0.7.12. Needs lupa. Run: python tests/test_buymoney0713.py
"""
import json
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
CONTENT = os.path.join(ROOT, "mod", "mpfever_1", "content")


def read(name):
    return open(os.path.join(CONTENT, name), encoding="utf-8").read().replace("\r\n", "\n")


src = read("mpfever_bridge.script.lua")
com = read("mpfever_common.lua")
ui = read("mpfever_ui.script.lua")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


def cut(text, start, end):
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j + len(end)]


# ------------------------------------------------------------------ the sources
helpers = cut(com, "function C.buyWhy(m)", "\nend\n")
helpers += cut(com, "function C.buyNote(m)", "\nend\n")
texts = cut(com, "function C.T(fr, en)", "\nend\n") + cut(com, "function C.Tf(fr, en, ...)", "\nend\n")
watch = cut(src, "\t-- entities created one or more steps after their command (vehicle purchases)\n", "\t\tst.watches = keepW\n")
watch = watch + "\t\tchanged = true\n\tend\n"
check(src[src.index("\t\tst.watches = keepW\n"):].startswith("\t\tst.watches = keepW\n\t\tchanged = true\n\tend\n"), "the watches' block found whole")
buy = cut(src, "\tlocal buyMoney = nil\n", "\n\tend\n")
cb = cut(src, "\t\toks, errs = pcall(sendCommand, cmd, function(data, ok, resultEntities)\n", "\n\t\tend)\n")
paused = cut(src, '\t\t\t\t\tlog("paused action " .. tostring(r.uid) .. " " .. tostring(r.fn) .. " at t="', 'C.buyNote(r) or ""))\n')
pausedDone = cut(src, '\t\t\t\t\tlog("paused action " .. tostring(r.uid) .. " " .. tostring(r.fn) .. " at t="',
                 '\t\t\t\t\tif r.toll then toSim("depot_toll", r.toll) end\n')
m = re.search(r"^SIM\.noteDepotToll = function\(reg, t\)\n.*?^end\n", src, re.S | re.M)
noteToll = m.group(0) if m else ""
check(m is not None, "SIM.noteDepotToll found")
report = cut(src, "function G.reportResult(r)\n", "\nend\n")
m = re.search(r"^U\.buyRefusedText = function\(r\)\n.*?^end\nU\.buyRefusedShow = function\(r\)\n.*?^end\n", ui, re.S | re.M)
uitext = m.group(0) if m else ""
check(m is not None, "U.buyRefusedText and U.buyRefusedShow found")
m = re.search(r"^local function money\(n\)\n.*?^end\n", ui, re.S | re.M)
money = m.group(0)
m = re.search(r"^local function pollResults\(\)\n.*?^end\n", ui, re.S | re.M)
poll = m.group(0)
m = re.search(r"^H\.buypoor = function\(from, p\)\n.*?^end\n", src, re.S | re.M)
buypoor = m.group(0) if m else ""
check(m is not None, "the autotest scenario H.buypoor is there")

# ------------------------------------------------------------------ static checks
check('os.getenv("MPFEVER_BUYMONEY") ~= "0"' in buy and 'os.getenv("MPFEVER_BUYMONEY") ~= "0"' in watch
      and 'os.getenv("MPFEVER_BUYMONEY") == "0"' in uitext, "MPFEVER_BUYMONEY=0 in the simulation, the watch and the interface")
check('r.err = "created entity not found"' in watch, "r.err stays 'created entity not found'")
check('"nothing created yet (the replacement is made at a depot)"' in watch, "  a replacement's text unchanged")
check("if okc and c then return c, tryLabel(t), errs, args end" in src, "buildCommand gives the rebuilt arguments as its 4th value")
check("local cmd, label, errs, cargs = buildCommand(a.fn" in src, "  executeActionOnce takes them")
check(src.index("local buyMoney = nil") < src.index("local createdKey = (a.fn == \"makeLineCreateCmd\""), "  read before the command goes")
check(src.index("local okm, missing = pcall(missingEntities") < src.index("local buyMoney = nil"),
      "  after every check that skips the action (only purchases that reach the engine)")
check("fn = a.fn, money = buyMoney }" in src, "the figures go with the watch (running game)")
check("local cmd, label, fails = buildCommand(\"makeWorldBuildProposalCmd\"" in src, "the other caller of buildCommand unchanged")
check(not re.search(r"(?m)^local buyMoney|^local cargs", src), "no new local of the main chunk (200-local limit)")
check("U.pending[r.id] = nil" in poll and "pcall(U.buyRefusedShow, r)" in poll, "the notice from pollResults")
check(poll.index("pcall(p.cb, data, r.success == true, entities)") < poll.index("pcall(U.buyRefusedShow, r)"),
      "  after the window's own callback")
check("uiRequest(\"makeVehicleBuyCmd\"" in buypoor and "for _ = 1, 4 do" in buypoor and "2.5 * P" in buypoor
      and '"buypoor: needs MPFEVER_COMPANIES=separate"' in buypoor and '"buypoor: host only"' in buypoor,
      "H.buypoor: 2.5 prices left, 4 copies in one frame, host only, separate companies")

try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    check(False, "lupa is installed (pip install lupa)")

if lupa:
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = L.eval("function(code) return assert(load(code))() end")
    L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS = {}
log = function(s) LOGS[#LOGS + 1] = s end
C = { LANG = {}, LANGCODE = "en" }
''' + helpers + texts)

    # -------------------------------------------------------------- C.buyWhy / C.buyNote, r148's real figures
    def why(t):
        return run(f"return C.buyWhy({t})")

    def note(t):
        return run(f"return C.buyNote({t})")

    check(why("{ price = 367290, balance = 275888 }") == "money", "AMD:11 (367,290 with 275,888): the money")
    check(note("{ price = 367290, balance = 275888 }") == " (not enough money: price 367290, company money 275888)",
          "  its note", note("{ price = 367290, balance = 275888 }"))
    check(why("{ price = 331000, balance = 238076 }") == "money", "AMD:51, the 4th clone (331,000 with 238,076): the money")
    check(why("{ price = 905258, balance = 8662426 }") is None, "AMD:479 (905,258 with 8,662,426): not the money")
    check(note("{ price = 905258, balance = 8662426 }") == " (price 905258, company money 8662426: not the money)", "  its note")
    check(why("{ price = 500000, balance = 500000 }") is None, "a price equal to the money: paid (the engine's 'jle')")
    check(why("{ price = 500000 }") is None and note("{ price = 500000 }") == " (unlimited money)", "unlimited money (balance nil): never the money")
    check(why("{ price = 0, balance = -5 }") is None, "a price of 0: never the money")
    check(why("{ price = 500000, balance = 520000, toll = 30000 }") == "money", "a depot toll taken off the money")
    check("+ depot toll 30000" in note("{ price = 500000, balance = 520000, toll = 30000 }"), "  said in the note")
    check(why("{ price = 300000, balance = -311000 }") == "money", "#170: a company in debt")
    check(note("nil") == "" and note("{}") == "" and why("nil") is None, "nothing known: nothing said")
    # (the series of 4 clones, AMD:48-51, one per step, each one seeing the booking of the one before)
    made, bal = 0, 1231077
    for _ in range(4):
        if why(f"{{ price = 331000, balance = {bal} }}") is None:
            made, bal = made + 1, bal - 331000
    check(made == 3 and bal == 1231077 - 3 * 331000, "AMD:48-51: 3 clones made from 1,231,077 at 331,000 each, the 4th refused", f"{made} {bal}")

    # -------------------------------------------------------------- the watch's end (running game)
    L.execute('''
VEH = { 101, 102 }
LINES = {}
R = { entitiesWith = function(k) return VEH end }
api = { engine = { system = { lineSystem = { getLines = function() return LINES end } } } }
function runWatch(st, now)
	local changed = false
''' + watch + '''
	return changed
end
function newWatch(uid, fn, money)
	return { tok = "t", id = 1, uid = uid, fn = fn, success = true, watch = { kind = "TRANSPORT_VEHICLE", key = "V" .. uid .. "@1", before = { 101, 102 }, steps = 0, fn = fn, money = money } }
end
function steps(st, n) for i = 1, n do runWatch(st, 1000 + i * 200) end end
''')
    MONEY = "{ price = 367290, balance = 275888 }"
    L.execute(f'LOGS = {{}}; ST = {{ watches = {{ newWatch("AMD:11", "makeVehicleBuyCmd", {MONEY}) }} }}; steps(ST, 10)')
    r = run("return ST.results and ST.results[1]")
    check(r is not None and r["success"] is False and r["err"] == "created entity not found" and r["why"] == "money"
          and r["price"] == 367290 and r["balance"] == 275888, "10 steps, nothing made: refused, why = money, the figures")
    check(run("return LOGS[#LOGS]") == "action AMD:11 result after 10 step(s): nothing created (not enough money: price 367290, company money 275888)",
          "  its line says why", run("return LOGS[#LOGS]"))
    check(run("return #ST.watches") == 0, "  the watch ends")
    L.execute(f'LOGS = {{}}; ST = {{ watches = {{ newWatch("AMD:12", "makeVehicleBuyCmd", {MONEY}) }} }}; runWatch(ST, 1200); VEH = {{ 101, 102, 50001 }}; runWatch(ST, 1400); VEH = {{ 101, 102 }}')
    r = run("return ST.results and ST.results[1]")
    check(r is not None and r["created"]["e"] == 50001 and r["why"] is None and r["success"] is True, "a vehicle made at step 2: no reason")
    check(run("return LOGS[#LOGS]") == "action AMD:12 result after 2 step(s): entity 50001", "  its line byte for byte (idcmp.py)", run("return LOGS[#LOGS]"))
    L.execute('LOGS = {}; ST = { watches = { newWatch("AMD:13", "makeVehicleReplaceCmd", nil) } }; steps(ST, 10)')
    r = run("return ST.results[1]")
    check(r["success"] is True and run("return LOGS[#LOGS]") == "action AMD:13 result after 10 step(s): nothing created yet (the replacement is made at a depot)",
          "a replacement: not a refusal, its text unchanged")
    L.execute('LOGS = {}; ST = { watches = { newWatch("AMD:14", "makeVehicleBuyCmd", nil) } }; steps(ST, 10)')
    r = run("return ST.results[1]")
    check(run("return LOGS[#LOGS]") == "action AMD:14 result after 10 step(s): nothing created" and r["why"] is None and r["price"] is None,
          "a watch of 0.7.12's save (no figures): the old line byte for byte")
    L.execute(f'ENV.MPFEVER_BUYMONEY = "0"; LOGS = {{}}; ST = {{ watches = {{ newWatch("AMD:15", "makeVehicleBuyCmd", {MONEY}) }} }}; steps(ST, 10); ENV.MPFEVER_BUYMONEY = nil')
    r = run("return ST.results[1]")
    check(run("return LOGS[#LOGS]") == "action AMD:15 result after 10 step(s): nothing created" and r["why"] is None and r["price"] is None
          and r["err"] == "created entity not found", "MPFEVER_BUYMONEY=0: as in 0.7.12")
    L.execute('LOGS = {}; ST = { watches = { newWatch("AMD:16", "makeVehicleBuyCmd", { price = 400000 }) } }; steps(ST, 10)')
    check(run("return LOGS[#LOGS]").endswith("nothing created (unlimited money)") and run("return ST.results[1].why") is None,
          "unlimited money: said, never the money")
    # (a purchase at another company's depot for a toll: its result keeps the owner guard's table, the fee goes as tollFee)
    L.execute('LOGS = {}; local w = newWatch("AMD:17", "makeVehicleBuyCmd", { price = 500000, balance = 520000, toll = 30000 }); '
              'w.toll = { from = 1, to = 2, fee = 30000 }; ST = { watches = { w } }; steps(ST, 10)')
    r = run("return ST.results[1]")
    check(r["why"] == "money" and run("return type(ST.results[1].toll)") == "table" and run("return ST.results[1].toll.fee") == 30000
          and r["tollFee"] == 30000, "a toll at the watch's end: why = money, the toll still the guard's table, its fee as tollFee",
          (r["why"], run("return type(ST.results[1].toll)"), r["tollFee"]))
    check(run("return LOGS[#LOGS]") == "action AMD:17 result after 10 step(s): nothing created (not enough money: price 500000 + depot toll 30000, company money 520000)",
          "  its line says the toll", run("return LOGS[#LOGS]"))

    # -------------------------------------------------------------- the price and the money, read when the purchase goes
    L.execute('''
CALLS = 0
PRICES = { [4218] = 612345, [4417] = 98765 }
MODELS = { [4218] = { metadata = { cost = { price = 650000 } } }, [4417] = { metadata = { cost = { price = 100000 } } } }
BAL = { [7] = 275888.75 }
function setApi(o)
	api = { engine = { util = {
		vehicle = { getPartPrice = function(part) CALLS = CALLS + 1; if o.priceErr then error("no price here") end return PRICES[part.part.modelId] end },
		finance = { getPlayersBalance = function(p) if o.balErr then error("no balance") end return BAL[p] end } } },
		res = { modelRep = { get = function(id) return MODELS[id] end } } }
	if o.none then api = {} end
end
function cfgOf(ids) local v = {} for i, id in ipairs(ids) do v[i] = { part = { modelId = id }, purchaseTime = 25000000 } end return { vehicles = v } end
function runBuy(a, cargs, result)
''' + buy + '''
	return buyMoney
end
function buyOf(fn, ids, player, toll, plainOnly)
	local a = { fn = fn, args = { player, 55, cfgOf(ids) } }
	return runBuy(a, (not plainOnly) and { player, 55, cfgOf(ids) } or nil, { toll = toll })
end
''')
    L.execute("setApi({})")
    b = run('return buyOf("makeVehicleBuyCmd", { 4218, 4417 }, 7)')
    check(b is not None and b["price"] == 612345 + 98765 and b["balance"] == 275888 and b["toll"] is None,
          "a 2-part train: the parts' prices added up, the money", b and (b["price"], b["balance"]))
    BAL_NIL = run('BAL[8] = nil; return buyOf("makeVehicleBuyCmd", { 4218 }, 8)')
    check(BAL_NIL is not None and BAL_NIL["balance"] is None and BAL_NIL["price"] == 612345, "unlimited money: balance nil")
    run('setApi({ priceErr = true }); return nil')
    b = run('return buyOf("makeVehicleBuyCmd", { 4218, 4417 }, 7)')
    check(b is not None and b["price"] == 750000, "no getPartPrice here: the models' cost", b and b["price"])
    b = run('setApi({}); return buyOf("makeVehicleBuyCmd", { 4218 }, 7, nil, true)')
    check(b is not None and b["price"] == 650000, "no rebuilt configuration: the models' cost", b and b["price"])
    b = run('setApi({ priceErr = true, balErr = true }); return buyOf("makeVehicleBuyCmd", { 4218 }, 7)')
    check(b is None, "no money to read: nothing (and no error)")
    b = run('setApi({ none = true }); return buyOf("makeVehicleBuyCmd", { 4218 }, 7)')
    check(b is None, "nothing of the api: nothing (and no error)")
    run('setApi({}); return nil')
    b = run('return buyOf("makeVehicleBuyCmd", { 4218 }, 7, { from = 2, to = 1, fee = 30000 })')
    check(b is not None and b["toll"] == 30000, "a depot toll goes with it")
    b = run('CALLS = 0; return buyOf("makeVehicleSellCmd", { 4218 }, 7)')
    check(b is None and run("return CALLS") == 0, "another command: nothing read")
    b = run('ENV.MPFEVER_BUYMONEY = "0"; CALLS = 0; local r = buyOf("makeVehicleBuyCmd", { 4218 }, 7); ENV.MPFEVER_BUYMONEY = nil; return r')
    check(b is None and run("return CALLS") == 0, "MPFEVER_BUYMONEY=0: nothing read (getPartPrice never called)")

    # -------------------------------------------------------------- the engine's answer in a pause (the callback)
    L.execute('''
C.marshal = function(x) return x end
function runCb(result, buyMoney, ok)
	local isBuild, createdKey, ckey, done = false, "V", "Vu@1", nil
	local cmd = {}
	local oks, errs
	local sendCommand = function(c, f) f({}, ok, ok and { { 50077 } } or {}) end
''' + cb + '''
	return result
end
''')
    r = run(f"return runCb({{ uid = 'keviK#2:210', fn = 'makeVehicleBuyCmd', success = false }}, {{ price = 598778, balance = 41217 }}, false)")
    check(r["success"] is False and r["why"] == "money" and r["price"] == 598778 and r["balance"] == 41217,
          "keviK#2:210 refused in a pause with 41,217: why = money, the figures")
    r = run(f"return runCb({{ uid = 'AMD:479', fn = 'makeVehicleBuyCmd', success = false }}, {{ price = 905258, balance = 8662426 }}, true)")
    check(r["success"] is True and r["why"] is None and r["created"]["e"] == 50077 and r["price"] == 905258, "AMD:479 made in a pause: no reason")
    r = run("return runCb({ uid = 'u', fn = 'makeVehicleBuyCmd', success = false }, nil, false)")
    check(r["why"] is None and r["price"] is None, "nothing read (0.7.12, MPFEVER_BUYMONEY=0): nothing added")
    # (a purchase in a pause at another company's depot for a toll: the guard's toll table must reach the simulation)
    L.execute('''
TOSIM = {}
SIM = {}
function runDone(r, fn)
	local a, now = { fn = fn }, 25459200
	local G, toSim = { featOn = nil, rebind = function() end }, function(k, p) TOSIM[#TOSIM + 1] = { k = k, p = p } end
''' + pausedDone + '''
	return TOSIM
end
''' + noteToll + '''
function NOTE_TOLL(reg, t)
	local prev = C.eco
	C.eco = function() return nil end
	local k = SIM.noteDepotToll(reg, t)
	C.eco = prev
	return k
end
''')
    GUARD = "{ uid = 'Sascha#1:80', fn = 'makeVehicleBuyCmd', success = false, toll = { from = 1, to = 2, fee = 30000 } }"
    run(f"R_CB = runCb({GUARD}, {{ price = 905258, balance = 8662426, toll = 30000 }}, true); return nil")
    check(run("return R_CB.success") is True, "a purchase at a toll depot made in a pause")
    check(run("return type(R_CB.toll)") == "table" and run("return R_CB.toll.fee") == 30000 and run("return R_CB.toll.from") == 1
          and run("return R_CB.toll.to") == 2 and run("return R_CB.tollFee") == 30000,
          "  the callback leaves result.toll the guard's { from, to, fee }, the fee as tollFee",
          (run("return type(R_CB.toll)"), run("return R_CB.tollFee")))
    run("TOSIM = {}; LOGS = {}; runDone(R_CB, 'makeVehicleBuyCmd'); DT = nil; for _, x in ipairs(TOSIM) do if x.k == 'depot_toll' then DT = x end end; return nil")
    check(run("return DT ~= nil and type(DT.p)") == "table",
          "  the pause's end sends the simulation a table for 'depot_toll'", run("return DT and type(DT.p)"))
    check(run("REG = {}; return NOTE_TOLL(REG, DT and DT.p)") is True and run("return REG.tollIncome and REG.tollIncome['2']") == 30000
          and run("return REG.tollExpense and REG.tollExpense['1']") == 30000, "  and SIM.noteDepotToll keeps it (the companies window's tolls, #122)")
    run(f"R_CB = runCb({GUARD}, {{ price = 500000, balance = 520000, toll = 30000 }}, false); return nil")
    check(run("return R_CB.why") == "money" and run("return type(R_CB.toll)") == "table" and run("return R_CB.tollFee") == 30000,
          "a purchase at a toll depot refused in a pause: why = money, the guard's table kept")
    run("TOSIM = {}; LOGS = {}; runDone(R_CB, 'makeVehicleBuyCmd'); return nil")
    check(run("return LOGS[#LOGS]") == "paused action Sascha#1:80 makeVehicleBuyCmd at t=25459200 -> REFUSED (not enough money: price 500000 + depot toll 30000, company money 520000)",
          "  its line says the toll (the fee from tollFee)", run("return LOGS[#LOGS]"))
    run(f"R_CB = runCb({GUARD}, nil, true); return nil")
    check(run("return type(R_CB.toll)") == "table" and run("return R_CB.tollFee") is None,
          "  nothing read (MPFEVER_BUYMONEY=0): the guard's table untouched")

    # -------------------------------------------------------------- the paused line
    L.execute('''
function pausedLine(r, fn)
	local a, now = { fn = fn }, 25459200
''' + paused + '''
	return LOGS[#LOGS]
end
''')
    s = run("return pausedLine({ uid = 'Sascha#1:79', fn = 'makeVehicleBuyCmd', success = false, price = 367290, balance = 157268, why = 'money' }, 'makeVehicleBuyCmd')")
    check(s == "paused action Sascha#1:79 makeVehicleBuyCmd at t=25459200 -> REFUSED (not enough money: price 367290, company money 157268)",
          "Sascha#1:79 refused in a pause: its line says why", s)
    s = run("return pausedLine({ uid = 'AMD:479', fn = 'makeVehicleBuyCmd', success = true, price = 905258, balance = 8662426 }, 'makeVehicleBuyCmd')")
    check(s == "paused action AMD:479 makeVehicleBuyCmd at t=25459200 -> OK", "  a purchase made: the line as before", s)
    s = run("return pausedLine({ uid = 'u', fn = 'makeVehicleBuyCmd', success = false }, 'makeVehicleBuyCmd')")
    check(s == "paused action u makeVehicleBuyCmd at t=25459200 -> REFUSED", "  without the figures: as before", s)
    s = run("return pausedLine({ uid = 'u', fn = 'makeLineCreateCmd', success = false, price = 5 }, 'makeLineCreateCmd')")
    check(s == "paused action u makeLineCreateCmd at t=25459200 -> REFUSED", "  another command: as before", s)

    # -------------------------------------------------------------- act_refused
    L.execute('''
G = { gsAnswer = function() end }
SENT = {}
send = function(k, p) SENT[#SENT + 1] = { k = k, p = p } end
replayFailed = function() end
''' + report)
    run("G.reportResult({ uid = 'AMD:11', fn = 'makeVehicleBuyCmd', success = false, err = 'created entity not found', why = 'money', price = 367290, balance = 275888 }); return nil")
    p = run("return SENT[#SENT].p")
    check(run("return SENT[#SENT].k") == "act_refused" and p["why"] == "money" and p["price"] == 367290 and p["balance"] == 275888
          and p["err"] == "created entity not found", "act_refused: why, price and balance for the launcher's log and the reports")
    run("G.reportResult({ uid = 'x', fn = 'makeVehicleSellCmd', success = false, err = 'e' }); return nil")
    p = run("return SENT[#SENT].p")
    check(sorted(k for k in p.keys()) == ["err", "fn", "uid"], "  another refusal: the same payload as before", list(p.keys()))
    n = run("return #SENT")
    run("G.reportResult({ uid = 'y', fn = 'makeVehicleBuyCmd', success = true, price = 1, balance = 2 }); return nil")
    check(run("return #SENT") == n, "  a purchase made: nothing sent")

    # -------------------------------------------------------------- the buyer's notice
    L.execute('''
T = C.T
api = { util = { formatMoney = function(n)
	local s = tostring(math.floor(math.abs(n)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and "-$" or "$") .. out
end } }
NEWS = {}
U = { onChatNews = function(items) NEWS[#NEWS + 1] = items end }
''' + money + uitext)
    rich = "{ fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 367290, balance = 275888 }"
    items = run(f"return U.buyRefusedText({rich})")
    check(items is not None and len(items) == 2 and items[1]["text"] == "Purchase refused: not enough money."
          and items[2]["text"] == "Price $367,290, your company has $275,888.", "EN: two items, the price and the money",
          items and [items[k]["text"] for k in items])
    check(items[1]["kind"] == "msg" and items[1]["name"] == "MPFever", "  chat notice items from MPFever")
    items = run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 500000, balance = 520000, toll = 30000 })")
    check(items[2]["text"] == "Price $530,000, your company has $520,000.", "  with a depot toll: the price and the toll", items[2]["text"])
    items = run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 500000, balance = 520000, "
                "tollFee = 30000, toll = { from = 1, to = 2, fee = 30000 } })")
    check(items is not None and items[2]["text"] == "Price $530,000, your company has $520,000.",
          "  a result's toll: the fee from tollFee (its toll is the guard's table)", items and items[2]["text"])
    items = run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false, err = 'created entity not found' })")
    check(items is not None and len(items) == 1 and items[1]["text"] == "Purchase refused by the game: no vehicle made.", "no reason known: one general item")
    items = run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false })")
    check(items is not None and len(items) == 1 and items[1]["text"] == "Purchase refused by the game: no vehicle made.",
          "  the engine's answer in a pause (no err): the general item")
    for err in ("it belongs to company 2 (Weed Co.)", "DESYNC missing entities: 55", "references: 55", "DESYNC unresolved: V1@2",
                "send: boom", "game option: no vehicles", "not available to this company yet (x.y)", "full: rebuild failed"):
        check(run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false, err = %s })" % json.dumps(err)) is None,
              f"  refused by MPFever, not the game ({err}): no notice blaming the game")
    run("C.LANGCODE = 'fr'; return nil")
    items = run(f"return U.buyRefusedText({rich})")
    check(items[1]["text"] == "Achat refusé : pas assez d'argent." and items[2]["text"] == "Prix $367,290, votre entreprise a $275,888.",
          "FR", [items[k]["text"] for k in items])
    run("C.LANGCODE = 'en'; return nil")
    for lang in ("fr", "en"):
        run(f"C.LANGCODE = '{lang}'; return nil")
        big = run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 99999999, balance = -99999999 })")
        gen = run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = false })")
        longest = max(len(t) for t in [big[k]["text"] for k in big] + [gen[1]["text"]])
        check(longest <= 70, f"  {lang}: each item 70 characters at most with 99,999,999 amounts (the notice cuts there)", longest)
    run("C.LANGCODE = 'en'; return nil")
    check(run("return U.buyRefusedText({ fn = 'makeVehicleBuyCmd', success = true, price = 1, balance = 0 })") is None, "a purchase made: nothing")
    check(run("return U.buyRefusedText({ fn = 'makeVehicleSellCmd', success = false })") is None, "another command: nothing")
    check(run(f"ENV.MPFEVER_BUYMONEY = '0'; local r = U.buyRefusedText({rich}); ENV.MPFEVER_BUYMONEY = nil; return r") is None,
          "MPFEVER_BUYMONEY=0: nothing said")

    # (the translations: the same 70 characters, the amounts as long as they get)
    lang = json.load(open(os.path.join(ROOT, "launcher", "lang.json"), encoding="utf-8-sig"))["texts"]
    keys = ["Purchase refused: not enough money.", "Price %s, your company has %s.", "Purchase refused by the game: no vehicle made."]
    for k in keys:
        tr = lang.get(k) or {}
        codes = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
        check(all(tr.get(c) for c in codes), f"lang.json: '{k}' in every language")
        longest = max((len(tr.get(c, "").replace("%s", "-$99,999,999")) for c in codes), default=0)
        check(longest <= 70, "  every translation 70 characters at most", longest)

    # -------------------------------------------------------------- pollResults: the buyer's own purchases, the autotests'
    tmp = tempfile.mkdtemp(prefix="buymoney0713_")
    try:
        resfile = os.path.join(tmp, "results.log")
        L.globals().TMPDIR = tmp
        L.execute('''
C.ACTIVE = true
C.IO = io
C.DIR = TMPDIR
C.BS = "/"
C.NL = string.char(10)
C.TAB = string.char(9)
C.ROLE = "host"
C.deser = function(s) return load("return " .. s)() end
C.plain = function(x) return x end
CBS = {}
U.tok, U.resOff, U.stats, U.pending = "tokA", 0, { answered = 0 }, {}
''' + poll + '''
POLL = pollResults
''')

        def add(payload):
            with open(resfile, "a", encoding="utf-8", newline="\n") as f:
                f.write("result\tHost\t" + payload + "\n")

        def pend(i):
            L.execute(f"U.pending[{i}] = {{ name = 'makeVehicleBuyCmd', t0 = 0, cb = function(data, ok, ents) CBS[#CBS + 1] = ok end }}")

        add("{ tok = 'auto-host', id = 1, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 1, balance = 0 }")
        L.execute("NEWS = {}; LOGS = {}; POLL()")
        check(run("return #NEWS") == 0, "an autotest's purchase already in results.log when this interface started: not new")
        pend(5)
        add("{ tok = 'tokA', id = 5, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 367290, balance = 275888 }")
        L.execute("POLL()")
        check(run("return #CBS") == 1 and run("return CBS[1]") is False, "the window's callback answered (refused)")
        check(run("return #NEWS") == 1 and run("return #NEWS[1]") == 2, "  and the buyer told: the notice's two items")
        check(any(str(run(f"return LOGS[{i}]")).startswith("purchase refused shown: money price 367290 company 275888") for i in range(1, run("return #LOGS") + 1)),
              "  logged: 'purchase refused shown: money price 367290 company 275888'")
        pend(6)
        add("{ tok = 'tokA', id = 6, fn = 'makeVehicleBuyCmd', success = true, price = 367290, balance = 900000 }")
        L.execute("POLL()")
        check(run("return #NEWS") == 1 and run("return #CBS") == 2, "a purchase made: callback, no notice")
        add("{ tok = 'tokB', id = 7, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 1, balance = 0 }")
        add("{ tok = 'tokA', id = 9, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 1, balance = 0 }")
        L.execute("POLL()")
        check(run("return #NEWS") == 1, "another player's purchase, or one already answered: nothing (only the buyer, once)")
        add("{ tok = 'auto-host', id = 2, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 2, balance = 1 }")
        L.execute("POLL()")
        check(run("return #NEWS") == 1, "an autotest's purchase without MPFEVER_SCENARIO: nothing")
        L.execute("ENV.MPFEVER_SCENARIO = 'buypoor'")
        add("{ tok = 'auto-host', id = 3, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 3, balance = 1 }")
        add("{ tok = 'auto-client', id = 3, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 3, balance = 1 }")
        L.execute("POLL()")
        check(run("return #NEWS") == 2, "an autotest's new purchase of this game (MPFEVER_SCENARIO): the notice too (H.buypoor)")
        # (a reload: the interface reads results.log again from its start; nothing said twice)
        L.execute("U.resOff, U.resStart, U.pending = 0, nil, {}; POLL()")
        check(run("return #NEWS") == 2, "results.log read again after a reload: nothing said twice")
        L.execute("ENV.MPFEVER_BUYMONEY = '0'; ENV.MPFEVER_SCENARIO = nil")
        pend(10)
        add("{ tok = 'tokA', id = 10, fn = 'makeVehicleBuyCmd', success = false, why = 'money', price = 367290, balance = 275888 }")
        L.execute("POLL()")
        check(run("return #NEWS") == 2 and run("return #CBS") == 3, "MPFEVER_BUYMONEY=0: the callback as before, no notice")
        L.execute("ENV.MPFEVER_BUYMONEY = nil")
        pend(11)
        add("{ tok = 'tokA', id = 11, fn = 'makeVehicleBuyCmd', success = false, err = 'it belongs to company 2 (Weed Co.)' }")
        L.execute("POLL()")
        check(run("return #NEWS") == 2 and run("return #CBS") == 4,
              "a purchase MPFever refused (another company's private depot): the callback, no 'refused by the game' notice")
        pend(12)
        add("{ tok = 'tokA', id = 12, fn = 'makeVehicleBuyCmd', success = false }")
        L.execute("POLL()")
        check(run("return #NEWS") == 3 and run("return #NEWS[3]") == 1 and run("return #CBS") == 5,
              "  one the engine refused in a pause (no reason known): the general item")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # -------------------------------------------------------------- H.buypoor with a mocked game
    tmp = tempfile.mkdtemp(prefix="buypoor0713_")
    try:
        L.globals().TMPDIR = tmp
        L.execute('''
H, AUTO, DONE, REQ = {}, {}, {}, {}
BS, NL, TAB = "/", string.char(10), string.char(9)
C.DIR, C.ROLE, C.NAME = TMPDIR, "host", "Host"
C.copy = function(x) return load("return " .. C.ser(x))() end
C.ser = function(v)
	if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
	local out = {}
	for k, x in pairs(v) do out[#out + 1] = "[" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "]=" .. C.ser(x) end
	return "{" .. table.concat(out, ",") .. "}"
end
C.marshal = function(x) return C.copy(x) end
G = { frames = 0, waits = {}, cmode = "separate", myCo = 1, co = { list = { { id = 1, ent = 7 }, { id = 2, ent = 8 } } } }
OWN = { [201] = 7, [202] = 8, [203] = 7 }
BAL = { [7] = 3000000, [8] = 100000 }
TVS = { [201] = { depot = 55, transportVehicleConfig = { vehicles = { { part = { modelId = 4218 } }, { part = { modelId = 4417 } } } } },
	[202] = { depot = 56 }, [203] = { depot = -1 } }
R = { entitiesWith = function() local r = {} for v in pairs(OWN) do r[#r + 1] = v end table.sort(r) return r end, ownerOf = function(v) return OWN[v] end }
api = { type = { ComponentType = { TRANSPORT_VEHICLE = "tv" } },
	engine = { getComponent = function(v) return TVS[v] end, entityExists = function(e) return e == 55 or e == 56 end,
		util = { getPlayer = function() return 7 end, vehicle = { getPartPrice = function(p) return ({ [4218] = 400000, [4417] = 100000 })[p.part.modelId] end },
			finance = { getPlayersBalance = function(e) return BAL[e] end } } } }
uiRequest = function(fn, margs) REQ[#REQ + 1] = { fn = fn, args = margs } end
autoFinish = function() AUTO.running = false; DONE[#DONE + 1] = AUTO.results end
function frames(n)
	for i = 1, n do
		G.frames = G.frames + 1
		local w = G.waits
		G.waits = {}
		for _, x in ipairs(w) do if G.frames >= x.at then x.fn() else G.waits[#G.waits + 1] = x end end
	end
end
''' + buypoor)
        L.execute("H.buypoor('host', { role = 'host' })")
        req = run("return REQ[1]")
        check(req is not None and req["fn"] == "makeScriptingSendEventCmd" and req["args"][3] == "give"
              and req["args"][4]["to"] == 2 and req["args"][4]["amount"] == 3000000 - 1250000,
              "H.buypoor: all the money but 2.5 prices (price 500,000) given to the other company", req and req["args"][4]["amount"])
        L.execute("BAL[7] = 1250000; frames(300)")
        check(run("return #REQ") == 5 and all(run(f"return REQ[{i}].fn") == "makeVehicleBuyCmd" and run(f"return REQ[{i}].args[2]") == 55
                                              for i in range(2, 6)), "  then 4 copies of its vehicle requested in one frame")
        check(run("return REQ[2].args[3] ~= REQ[3].args[3]") is True, "  each with its own copy of the configuration")
        with open(os.path.join(tmp, "results.log"), "a", encoding="utf-8", newline="\n") as f:
            for i, (ok, why) in enumerate([(True, None), (True, None), (False, "money"), (False, "money")]):
                f.write("result\tHost\t{ tok = 'auto-host', id = %d, fn = 'makeVehicleBuyCmd', success = %s%s }\n"
                        % (i + 1, "true" if ok else "false", ", why = 'money'" if why else ""))
            f.write("result\tHost\t{ tok = 'auto-client', id = 9, fn = 'makeVehicleBuyCmd', success = false }\n")
        L.execute("BAL[7] = 250000; OWN[301] = 7; OWN[302] = 7; frames(600)")
        res = run("return DONE[1] and DONE[1][1]")
        check(res == "buypoor: price 500000, money 1250000 -> 250000 (booked 2.00 prices), vehicles 2 -> 4, made 2, refused 2 (not enough money 2)",
              "  its report: the booked prices, the vehicles, the refusals", res)
        L.execute("DONE = {}; H.buypoor('client', { role = 'client' })")
        check(run("return #DONE") == 0, "a scenario for the other game: nothing here")
        L.execute("C.ROLE = 'client'; H.buypoor('host', { role = 'client' })")
        check(run("return DONE[1] and DONE[1][1]") == "buypoor: host only", "the client: 'host only'")
        L.execute("C.ROLE = 'host'; G.cmode = 'shared'; DONE = {}; H.buypoor('host', { role = 'host' })")
        check(run("return DONE[1] and DONE[1][1]") == "buypoor: needs MPFEVER_COMPANIES=separate", "one company for all: says it needs separate companies")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
