"""Old vehicles of the computer companies renewed (0.7.0, mpfever_ai.lua renewStep): since 0.6.9 every company's vehicles wear,
and a computer company kept its first buses and trucks for the whole session. Offline, through lupa (Lua 5.2) with the mocked
game of tests/ai_mock.py.

  - vehicleAge: the age from the purchase time of its first part, the lifespan from its model (x 1000, game milliseconds);
    nil when it cannot be read;
  - renewPick: the oldest past its lifespan, on a line that may get one only; none when every vehicle is younger.
Needs lupa (pip install lupa). Run: python tests/test_ai_renew.py
"""
import sys

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker

check, failures = checker()
L, M = load()
run = L.eval("function(code) local f = assert(load(code)) return f() end")
Y = 1461000

print("vehicleAge")
run("""
FE = { api = { type = { ComponentType = { TRANSPORT_VEHICLE = 'tv' } },
  engine = { getComponent = function(e, c) if e == 99 then return nil end
    return { transportVehicleConfig = { vehicles = { { purchaseTime = 1000, part = { modelId = 11 } } } } } end },
  res = { modelRep = { get = function(id) return { metadata = { maintenance = { lifespan = 36525 } } } end } } } }
""")
got = run("local a, l = M.p.vehicleAge(FE, 5, 1000 + 30 * %d); return a .. ' ' .. l" % Y)
check(got == "%d %d" % (30 * Y, 36525000), "age from the purchase time, lifespan x 1000: " + str(got))
check(run("return M.p.vehicleAge(FE, 99, 5000)") is None, "a vehicle that cannot be read: nil")
run("""FE0 = { api = { type = FE.api.type, res = FE.api.res,
  engine = { getComponent = function(e, c) return { transportVehicleConfig = { vehicles = { { purchaseTime = 0, part = { modelId = 11 } } } } } end } } }""")
got = run("local a = M.p.vehicleAge(FE0, 5, 50 * %d, 49 * %d); return a" % (Y, Y))
check(got == Y, "a purchase time of 0 (the computer companies' purchases): the age from when this session first saw it: " + str(got))
check(run("return M.p.vehicleAge(FE0, 5, 50 * %d, nil)" % Y) is None, "a purchase time of 0 and never seen: nil")

print("modelSeatsOf")
run("""FE2 = { api = { type = { ComponentType = { TRANSPORT_VEHICLE = 'tv' } },
  engine = { getComponent = function(e, c) return { transportVehicleConfig = { vehicles = { { purchaseTime = 0, part = { modelId = 11 } } } } } end },
  res = { modelRep = { get = function(id) return { metadata = { transportVehicle = { compartments = { { loadConfigs = { { cargoEntry = { capacity = 24 } }, { cargoEntry = { capacity = 30 } } } } } } } } end } } } }""")
check(run("return M.p.modelSeatsOf(FE2, 5)") == 30, "the seats of its model: its biggest load")
check(run("return M.p.modelSeatsOf(FE, 99)") is None, "a vehicle that cannot be read: nil")

print("renewPick")
cands = "{ { e = 1, line = 10, age = 20, life = 25 }, { e = 2, line = 10, age = 30, life = 25 }, { e = 3, line = 11, age = 40, life = 25 } }"
check(run("return M.p.renewPick(%s, { [10] = true, [11] = true }).e" % cands) == 3, "the oldest past its lifespan")
check(run("return M.p.renewPick(%s, { [10] = true }).e" % cands) == 2, "only on a line that may get one (11 loses money)")
check(run("return M.p.renewPick({ { e = 1, line = 10, age = 20, life = 25 } }, { [10] = true })") is None, "every vehicle younger: none")
check(run("return M.p.renewPick({}, {})") is None, "no vehicle: none")

print("renewStep: a renewal under way")
run("ACTS = {}; E.G.AI = E.G.AI or {}; E.G.AI.renew = { old = 801, line = 70, n = 1, frame = E.G.frames }")
got = run("local r = M.p.renewStep(E, { id = 3, ent = 3 }, {}, { { e = 801, line = 70 } }, 2000000, 0, false); return tostring(r) .. ' ' .. acts('makeVehicleSellCmd')")
check(got == "false 0", "the new vehicle not on the line yet: the old one kept: " + str(got))
got = run("local r = M.p.renewStep(E, { id = 3, ent = 3 }, {}, { { e = 801, line = 70 }, { e = 802, line = 70 } }, 2000000, 0, false); return tostring(r) .. ' ' .. acts('makeVehicleSellCmd') .. ' ' .. tostring(E.G.AI.renew)")
check(got == "true 1 nil", "the new one runs on the line: the old one sold, the renewal over: " + str(got))
run("E.G.AI.renew = { old = 801, line = 70, n = 1, frame = E.G.frames - 999999 }; ACTS = {}")
got = run("local r = M.p.renewStep(E, { id = 3, ent = 3 }, {}, { { e = 801, line = 70 } }, 2000000, 0, false); return tostring(r) .. ' ' .. acts('makeVehicleSellCmd') .. ' ' .. tostring(E.G.AI.renewFail and E.G.AI.renewFail[801])")
check(got == "false 0 true", "no new vehicle for too long: given up, that vehicle not tried again: " + str(got))

sys.exit(1 if failures else 0)
