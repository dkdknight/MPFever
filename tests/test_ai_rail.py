"""The computer companies' railways (0.6.4, mpfever_ai.lua: RL), offline through lupa (Lua 5.2) with the mocked game of
tests/ai_mock.py:
  - the station's modules are the ones the game's own template makes (modular_station.script's createTemplateFn, run on the
    game's file on 2026-10-31: a cargo station, one track, 3 or 2 platforms, eras a/b/c, simple track before 1930);
  - the track between two stations: its ends are the two nodes, its pieces join, it leaves each end straight on, its heights
    stay within the grade over hilly ground and end at the nodes' heights, every piece a track (type 1) of the company;
  - what is in its way: a street crossed on a 50 m concrete bridge 7 m over it, nothing of the street touched; two streets 30 m
    apart (even ones it may not cut) under one bridge; a bridge with no room before its end, a street crossed nearly along, a
    town house 30 m away, a curve too tight, a street 5 m beside it: refused; a river crossed on a bridge 7 m over the water, a lake 500 m wide refused;
    a town in the middle of a 6 km way: the straight track refused, the search's (A*) way round it taken;
  - the train: the cheapest locomotive strong enough that needs no catenary (not the electric one, not one off sale, not an 18 M
    Big Boy), the wagon that carries
    the most of the cargo, as many wagons as the platforms take;
  - the route: a producer and an industry that takes its cargo 4 km apart (not 1 km: the trucks' reach), none for a producer
    making less than 300 a year;
  - the lines and vehicles of trains are kept from the buses and trucks' rules (myLines, myVehicles), all lines with all;
  - a line given up is destroyed only once no person or cargo travels on it or waits at its stops (after 20 looks all the
    same; MPFEVER_AIDESTROYIDLE=0: at once, as before);
  - a line of trains: a train more when cargo piles up at its first stop (bought at the depot that reaches it, then sent to
    the line); none while it loses money or has 3 trains; a train sold a look once it lost money with nothing waiting 5 looks;
  - MPFEVER_AIRAIL=0: no railway, every line and vehicle as before.
Needs lupa (pip install lupa). Run: python tests/test_ai_rail.py
"""
import sys

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker

check, failures = checker()

# createTemplateFn of base/content/stations/rail/modular_station/modular_station.script.lua (templateIndex 6: cargo, through;
# tracks 1, specialization 1, catenary 1)
GAME = {
    (1972, 3): {3400005: "side_building_1_cargo", 3400020: "main_building_1_cargo", 3400035: "side_building_1_cargo",
                6399990: "platform_cargo_era_b", 6400000: "platform_cargo_era_b", 6400010: "platform_cargo_era_b", 6400020: "platform_cargo_era_b",
                8401990: "T/standard/standard", 8402000: "T/standard/standard", 8402010: "T/standard/standard", 8402020: "T/standard/standard"},
    (1925, 3): {3400005: "side_building_1_cargo", 3400020: "main_building_1_cargo", 3400035: "side_building_1_cargo",
                6399990: "platform_cargo_era_a", 6400000: "platform_cargo_era_a", 6400010: "platform_cargo_era_a", 6400020: "platform_cargo_era_a",
                8401990: "T/simple/simple", 8402000: "T/simple/simple", 8402010: "T/simple/simple", 8402020: "T/simple/simple"},
    (1995, 2): {3400000: "main_building_1_cargo", 6399990: "platform_cargo_era_c", 6400000: "platform_cargo_era_c", 6400010: "platform_cargo_era_c",
                8401990: "T/standard/standard", 8402000: "T/standard/standard", 8402010: "T/standard/standard"},
}


def game_name(short):
    if short.startswith("T/"):
        return "::/trainstation___/infrastructure/track/" + short[2:] + ".street_template"
    return "::/stations/rail/modular_station/" + short + ".module"


def main():
    L, M = load()
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    RL = M.f.RL

    print("station modules")
    for (year, length), want in GAME.items():
        p = RL.stationParams(year, length)
        got = {int(k): v.name for k, v in p.modules.items()}
        exp = {k: game_name(v) for k, v in want.items()}
        check(got == exp, f"{year}, {length} platforms: the game's template's modules" + ("" if got == exp else f" (got {sorted(got.items())})"))
        check(p.tracks == 1 and p.length == length and p.catenary == 1 and p.trackType == (2 if year >= 1930 else 1), f"{year}: its parameters")

    print("track")
    run('''
      E.groundZ = function(x, y, z) return 45 + 40 * math.sin(x / 250) end
      SP = M.f.RL.trackProposal(E, { ent = 700 }, 11, { x = 0, y = 0, z = 45 }, { x = 1, y = 0 }, 22, { x = 3000, y = 60, z = 60 }, { x = -1, y = 0 }, 1972)
    ''')
    res = run('''
      local edges = SP.streetProposal.edgesToAdd
      local nodes = SP.streetProposal.nodesToAdd
      local pos = {}
      for _, n in ipairs(nodes) do pos[n.entity] = n.comp.position end
      pos[11] = { x = 0, y = 0, z = 45 }; pos[22] = { x = 3000, y = 60, z = 60 }
      local joined, typed, owned, grade, maxStep = true, true, true, 0, 0
      for i, e in ipairs(edges) do
        local c = e.comp
        if i > 1 and c.node0 ~= edges[i - 1].comp.node1 then joined = false end
        if e.type ~= 1 or c.roadTemplate ~= "::/infrastructure/track/standard/standard.street_template" or c.roadStyle ~= "::/infrastructure/track/standard/standard.street" then typed = false end
        if not (e.playerOwned and e.playerOwned.player == 700) then owned = false end
        local a, b = pos[c.node0], pos[c.node1]
        local run = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        grade = math.max(grade, math.abs(b.z - a.z) / run)
        maxStep = math.max(maxStep, run)
        if math.abs(c.position0.z - a.z) > 1e-6 or math.abs(c.position1.z - b.z) > 1e-6 then joined = false end
      end
      local first, last = edges[1].comp, edges[#edges].comp
      local t0 = first.tangent0
      local t1 = last.tangent1
      local straight0 = t0.y == 0 and t0.x > 0
      local straight1 = math.abs(t1.y) < 1e-9 and t1.x > 0
      return #edges, joined, typed, owned, grade, maxStep, first.node0, last.node1, straight0, straight1
    ''')
    n, joined, typed, owned, grade, step, n0, n1, s0, s1 = res
    check(n >= 50, f"3 km in pieces of about 60 m ({n})")
    check(n0 == 11 and n1 == 22, "from the first node to the second")
    check(joined, "every piece starts where the last one ended, at its nodes' heights")
    check(typed and owned, "every piece a track of the year's template, owned by the company")
    check(grade <= 0.0301, f"within 3 % over hilly ground ({grade:.4f})")
    check(step <= 62, f"no piece longer than about 60 m ({step:.1f})")
    check(s0 and s1, "it leaves each end straight on, along the station")

    print("what is in its way")
    run('''
      E.groundZ = function(x, y, z) return 10 end
      -- a street from (1500,-300) to (1500,300) across the way, and one to its node at (2500,300)
      function STREET(e, a, b, n0, n1, cut, owner)
        local m = { position0 = { x = a.x, y = a.y, z = 10 }, position1 = { x = b.x, y = b.y, z = 10 },
          tangent0 = { x = b.x - a.x, y = b.y - a.y, z = 0 }, tangent1 = { x = b.x - a.x, y = b.y - a.y, z = 0 },
          node0 = n0, node1 = n1, roadTemplate = "::/street/town.street_template", roadStyle = "::/street/town.street", roadType = 0 }
        local pts = {}
        for i = 0, 20 do pts[#pts + 1] = (M.f.RL.herm(m, i / 20)) end
        return { e = e, m = m, pts = pts, street = true, owner = owner, cut = cut }
      end
      function WAY(W, way, p1)
        return M.f.RL.trackProposal(E, { ent = 700 }, 11, { x = 0, y = 0, z = 10 }, { x = 1, y = 0 }, 22, p1 or { x = 3000, y = 0, z = 10 }, { x = -1, y = 0 }, 1972, way, W)
      end
    ''')
    run('api.res.bridgeTypeRep = { getAll = function() return { [0] = "::/infrastructure/bridge/cable.bridge", [1] = "::/infrastructure/bridge/concrete.bridge" } end }')
    BRIDGE = '''
      local function bridges(sp)
        local list = {}
        for _, e in ipairs(sp.streetProposal.edgesToAdd) do
          local c = e.comp
          if c.type == 1 then list[#list + 1] = { len = math.sqrt((c.position1.x - c.position0.x) ^ 2 + (c.position1.y - c.position0.y) ^ 2), z0 = c.position0.z, z1 = c.position1.z, idx = c.typeIndex, x0 = c.position0.x, x1 = c.position1.x } end
        end
        return list
      end
    '''
    res = run(BRIDGE + '''
      local W = { edges = { STREET(501, { x = 1500, y = -300 }, { x = 1500, y = 300 }, 61, 62, true) }, houses = {}, cons = {}, segmap = {} }
      local sp, len, why, n = WAY(W)
      if not sp then return false, why end
      local b = bridges(sp)
      local ok = n == 1 and #b == 1 and b[1].idx == 1 and math.abs(b[1].z0 - 17) < 0.01 and math.abs(b[1].z1 - 17) < 0.01 and b[1].x0 < 1500 and b[1].x1 > 1500
        and math.abs(b[1].len - 50) < 2 and sp.streetProposal.edgesToRemove == nil
      return ok, tostring(n) .. " crossing(s), " .. #b .. " bridge(s) " .. (b[1] and string.format("%.1f m at %.1f-%.1f from x %.0f to %.0f", b[1].len, b[1].z0, b[1].z1, b[1].x0, b[1].x1) or "")
    ''')
    check(res[0], f"a street across its way: crossed on the concrete bridge, 50 m long, 7 m over it, nothing of the street touched ({res[1]})")
    res = run(BRIDGE + '''
      local W = { edges = { STREET(501, { x = 1500, y = -300 }, { x = 1500, y = 300 }, 61, 62, false), STREET(502, { x = 1530, y = -300 }, { x = 1530, y = 300 }, 63, 64, false) },
        houses = {}, cons = {}, segmap = {} }
      local sp, len, why, n = WAY(W)
      if not sp then return false, why end
      local b = bridges(sp)
      return n == 2 and #b == 1 and b[1].x0 < 1500 and b[1].x1 > 1530, tostring(n) .. " crossing(s), " .. #b .. " bridge(s)"
    ''')
    check(res[0], f"two streets 30 m apart (even ones it may not cut): both under one bridge ({res[1]})")
    res = run('''
      local W = { edges = { STREET(501, { x = 20, y = -300 }, { x = 20, y = 300 }, 61, 62, true) }, houses = {}, cons = {}, segmap = {} }
      local sp, len, why = WAY(W)
      return sp == nil and tostring(why):find("bridge", 1, true) ~= nil, tostring(why)
    ''')
    check(res[0], f"a street 20 m from its end: no room for the bridge, refused ({res[1]})")
    res = run('''
      local W = { edges = { STREET(501, { x = 1000, y = -300 }, { x = 1100, y = 300 }, 61, 62, true), STREET(502, { x = 1100, y = 300 }, { x = 1000, y = -300 }, 62, 61, true) },
        houses = {}, cons = {}, segmap = {} }
      local sp, len, why = WAY({ edges = { STREET(501, { x = 1000, y = -10 }, { x = 2000, y = 10 }, 61, 62, true) }, houses = {}, cons = {}, segmap = {} })
      return sp == nil and tostring(why):find("slantwise", 1, true) ~= nil, tostring(why)
    ''')
    check(res[0], f"a street it would cross nearly along: refused ({res[1]})")
    res = run('''
      -- the cells of the distance checks, as RL.world makes them
      function GRID(W)
        W.grid = {}
        for _, w in ipairs(W.edges) do
          for j = 1, #w.pts - 1 do
            local a, b = w.pts[j], w.pts[j + 1]
            for ci = math.floor(math.min(a.x, b.x) / 20), math.floor(math.max(a.x, b.x) / 20) do
              for cj = math.floor(math.min(a.y, b.y) / 20), math.floor(math.max(a.y, b.y) / 20) do
                local k = ci .. ":" .. cj
                W.grid[k] = W.grid[k] or {}
                W.grid[k][#W.grid[k] + 1] = { w = w, a = a, b = b }
              end
            end
          end
        end
        return W
      end
      local beside = GRID({ edges = { STREET(501, { x = 1000, y = 5 }, { x = 1400, y = 5 }, 61, 62, true) }, houses = {}, cons = {}, segmap = {} })
      local sp, len, why = WAY(beside)
      local across = GRID({ edges = { STREET(502, { x = 1500, y = -300 }, { x = 1500, y = 300 }, 63, 64, true) }, houses = {}, cons = {}, segmap = {} })
      local sp2, len2, why2 = WAY(across)
      return sp == nil and tostring(why):find("beside", 1, true) ~= nil and sp2 ~= nil, tostring(why) .. " / " .. tostring(why2)
    ''')
    check(res[0], f"a street 5 m beside its way: refused; a street across it: crossed on its bridge, not too near ({res[1]})")
    res = run(BRIDGE + '''
      -- a river 100 m wide across the way (the ground under the water level, 0, from 1450 to 1550)
      E.groundZ = function(x, y, z) if x > 1450 and x < 1550 then return -3 end return 10 end
      local sp, len, why = WAY({ edges = {}, houses = {}, cons = {}, segmap = {} })
      E.groundZ = function(x, y, z) return 10 end
      if not sp then return false, why end
      local b = bridges(sp)
      return #b == 1 and b[1].x0 <= 1445 and b[1].x1 >= 1555 and math.abs(b[1].z0 - 7) < 0.01, #b .. " bridge(s) " .. (b[1] and string.format("from x %.0f to %.0f at %.1f", b[1].x0, b[1].x1, b[1].z0) or "")
    ''')
    check(res[0], f"a river across its way: crossed on a bridge 7 m over the water ({res[1]})")
    res = run('''
      E.groundZ = function(x, y, z) if x > 1200 and x < 1700 then return -3 end return 10 end
      local sp, len, why = WAY({ edges = {}, houses = {}, cons = {}, segmap = {} })
      E.groundZ = function(x, y, z) return 10 end
      return sp == nil and tostring(why):find("water", 1, true) ~= nil, tostring(why)
    ''')
    check(res[0], f"a lake 500 m wide: refused ({res[1]})")
    res = run('''
      local W = { edges = {}, houses = { { x = 1500, y = 30 } }, cons = {}, segmap = {} }
      local sp, len, why = WAY(W)
      return sp == nil and tostring(why):find("houses", 1, true) ~= nil, tostring(why)
    ''')
    check(res[0], f"a town house 30 m from its way: refused ({res[1]})")
    res = run('''
      local sp, len, why = WAY(nil, { { x = 150, y = 300 } }, { x = 300, y = 0, z = 10 })
      return sp == nil and tostring(why):find("radius", 1, true) ~= nil, tostring(why)
    ''')
    check(res[0], f"a curve too tight: refused ({res[1]})")
    res = run('''
      -- a town in the middle of a 6 km way: houses every 60 m from (2700,-600) to (3300,600)
      local houses = {}
      for x = 2700, 3300, 60 do for y = -600, 600, 60 do houses[#houses + 1] = { x = x, y = y } end end
      local p1 = { x = 6000, y = 0, z = 10 }
      local W = { edges = {}, houses = houses, cons = {}, segmap = {}, box = M.f.RL.box({ x = 0, y = 0 }, p1) }
      local straight = WAY(W, nil, p1)
      local way, why = M.f.RL.plan(E, { x = 0, y = 0, z = 10 }, { x = 1, y = 0 }, p1, { x = -1, y = 0 }, W)
      if not way then return false, why end
      local sp, len, why2 = WAY(W, way, p1)
      return straight == nil and sp ~= nil, tostring(#way) .. " points, " .. tostring(why2)
    ''')
    check(res[0], f"a town in the way: the straight track refused, the search's way round it taken ({res[1]})")

    print("train")
    run('''
      MODELS = {
        [1] = { n = "::/vehicle/train/diesel.mdl", md = { availability = { yearFrom = 1930 }, landVehicle = { engines = { { power = 800, type = 0 } } }, cost = { price = 400000 },
                transportVehicle = { compartments = { { loadConfigs = { { cargoEntry = { capacity = 0, cargoTypeSet = "any" } } } } } } } },
        [8] = { n = "::/vehicle/train/bigboy.mdl", md = { availability = { yearFrom = 1930 }, landVehicle = { engines = { { power = 4560, type = 1 } } }, cost = { price = 18000000 } } },
        [9] = { n = "::/vehicle/train/small.mdl", md = { availability = { yearFrom = 1930 }, landVehicle = { engines = { { power = 300, type = 0 } } }, cost = { price = 100000 } } },
        [2] = { n = "::/vehicle/train/electric.mdl", md = { availability = { yearFrom = 1930 }, landVehicle = { engines = { { power = 3000, type = 2 } } }, cost = { price = 300000 } } },
        [3] = { n = "::/vehicle/train/old_steam.mdl", md = { availability = { yearFrom = 1900, yearTo = 1940 }, landVehicle = { engines = { { power = 2000, type = "STEAM" } } } } },
        [4] = { n = "::/vehicle/train/railcar.mdl", md = { availability = { yearFrom = 1930 }, landVehicle = { engines = { { power = 1500, type = "DIESEL" } } },
                transportVehicle = { compartments = { { loadConfigs = { { cargoEntry = { capacity = 50, cargoTypeSet = "any" } } } } } } } },
        [5] = { n = "::/vehicle/waggon/bulk.mdl", md = { availability = { yearFrom = 1915, yearTo = 1990 }, cost = { price = 50000 }, boundingInfo = { bbMin = { x = -4 }, bbMax = { x = 4 } },
                transportVehicle = { compartments = { { loadConfigs = { { cargoEntry = { capacity = 40, cargoTypeSet = { [2] = true } } } } } } } } },
        [6] = { n = "::/vehicle/waggon/goods.mdl", md = { availability = { yearFrom = 1915 }, transportVehicle = { compartments = { { loadConfigs = { { cargoEntry = { capacity = 30, cargoTypeSet = { [3] = true } } } } } } } } },
        [7] = { n = "::/vehicle/truck/old.mdl", md = { availability = { yearFrom = 1900 } } },
      }
      api.res.modelRep.getAll = function() local t = {} for id, m in pairs(MODELS) do t[id] = m.n end return t end
      api.res.modelRep.get = function(id) return { metadata = MODELS[id].md } end
    ''')
    t = run('local t = M.f.RL.train(E, 2) return t')
    check(t is not None and t.loco.id == 1, "the cheapest locomotive strong enough that needs no catenary, on sale, with no load of its own (not the Big Boy, not the electric one, not the weak one)")
    check(t is not None and t.wagon.id == 5, "the wagon that carries the most of that cargo for its price")
    check(t is not None and 2 <= t.n <= 6 and t.seats == t.n * 40, f"as many wagons as the platforms take ({t.n if t else '-'})")
    check(t is not None and t.price == 400000 + t.n * 50000, "its price: the locomotive and its wagons")
    check(run('return M.f.RL.train(E, 9) == nil'), "no wagon for that cargo: no train")

    print("route")
    run('''
      INDCACHE = {}
      FARM = addIndustry(1001, { primary = true, outputs = { 2 }, pos = { x = 0, y = 0, z = 0 } })
      MILL = addIndustry(1101, { outputs = { 5 }, inputs = { [2] = true }, pos = { x = 4000, y = 0, z = 0 } })
      NEAR = addIndustry(1201, { outputs = { 6 }, inputs = { [2] = true }, pos = { x = 1000, y = 0, z = 0 } })
      PROD[1004] = 300
      useIndustries()
    ''')
    r = run('return M.f.RL.route(E, { ent = 700 }, {}, {})')
    check(r is not None and r["from"].e == 1001 and r.to.e == 1101 and r.cargo == 2, "the farm to the mill 4 km away, not the one 1 km away")
    check(run('return M.f.RL.route(E, { ent = 700 }, {}, { { pos = { x = 100, y = 0 } } }) == nil'), "not a producer one of its train stations serves")
    check(run('PROD[1004] = 110; local r = M.f.RL.route(E, { ent = 700 }, {}, {}); PROD[1004] = 300; return r == nil'), "a producer of 110 a year: no railway (300 at least)")

    print("a line given up is destroyed only once nothing waits")
    res = run('''
      local l = { e = 777, groups = { 1, 2 } }
      local out = {}
      out[#out + 1] = tostring(M.f.lineIdle(E, l))                        -- the engine cannot tell (no person system here): as before
      api.engine.system.simPersonSystem = { getSimPersonsForLine = function() return {} end }
      WAIT[777] = 0
      out[#out + 1] = tostring(M.f.lineIdle(E, l))                        -- nothing waits, nobody travels
      WAIT[777] = 3
      out[#out + 1] = tostring(M.f.lineIdle(E, l))                        -- cargo waits at its stops
      WAIT[777] = 0
      api.engine.system.simPersonSystem = { getSimPersonsForLine = function() return { 5, 6 } end }
      out[#out + 1] = tostring(M.f.lineIdle(E, l))                        -- persons travel on it
      for i = 1, 25 do M.f.lineIdle(E, l) end
      out[#out + 1] = tostring(M.f.lineIdle(E, l))                        -- after 20 looks: destroyed all the same
      G.AI.idleTries = nil
      os.getenv = (function(g) return function(k) if k == "MPFEVER_AIDESTROYIDLE" then return "0" end return g(k) end end)(os.getenv)
      out[#out + 1] = tostring(M.f.lineIdle(E, l))                        -- MPFEVER_AIDESTROYIDLE=0: at once, as before
      api.engine.system.simPersonSystem = nil
      return table.concat(out, " ")
    ''')
    check(res == "true true false false true true", f"cannot tell: yes; nothing waits: yes; cargo waits: no; persons on it: no; after 20 looks: yes; switch at 0: yes ({res})")

    print("lines and vehicles of trains kept apart")
    run('''
      LINES, VEH = {}, {}
      OWN[601], OWN[602], OWN[801], OWN[802] = 700, 700, 700, 700
      LINES = { 601, 602 }
      STOPS[601], STOPS[602] = { 41, 42 }, { 51, 52 }
      G.AIT.railGroup = { [41] = true, [51] = false }
      VEH = { 801, 802 }
      VLINE[801], VLINE[802] = 601, 602
      api.type.enum.Carrier = { ROAD = 0, RAIL = 1 }
      local gc = api.engine.getComponent
      api.engine.getComponent = function(e, ct)
        local c = gc(e, ct)
        if ct == "TRANSPORT_VEHICLE" and c then c.carrier = (e == 801) and 1 or 0 end
        return c
      end
    ''')
    check(run('return #M.f.myLines(E, 700)') == 1 and run('return M.f.myLines(E, 700)[1].e') == 602, "a line of trains not among the buses and trucks' lines")
    check(run('return #M.f.myLines(E, 700, true)') == 2, "all lines with all")
    check(run('return #M.f.myVehicles(E, 700)') == 1 and run('return M.f.myVehicles(E, 700)[1].e') == 802, "a train not among the vehicles")
    check(run('return #M.f.RL.trains(E, 700)') == 1, "the company's trains")
    print("lines of trains managed")
    res = run('''
      -- line 601 (rail, first group 41): train 801 on it, grain (cargo 2) loaded at its first stop; a depot 950 that reaches it
      local gc = api.engine.getComponent
      api.engine.getComponent = function(e, ct)
        if ct == "LINE" and e == 601 then
          local load = {}; for k = 1, 6 do load[k] = (k == 3) end
          return { stops = { { stationGroup = 41, stopConfig = { load = load } }, { stationGroup = 42 } }, vehicleInfo = { transportModes = {} } }
        end
        if ct == "STATION_GROUP" and e == 41 then return { stations = { 4100 } } end
        if ct == "STATION" and e == 4100 then return { terminals = { { vehicleNodeId = 4101 } } } end
        if ct == "CONSTRUCTION" and e == 950 then return { fileName = "::/depots/rail/rail_depot.con", depots = { 951 }, transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } } end
        if ct == "VEHICLE_DEPOT" and e == 951 then return { outNodes = { 952 } } end
        if ct == "TRANSPORT_VEHICLE" and (e == 803 or e == 804) then local c = gc(e, ct); if c then c.carrier = 1 end return c end
        return gc(e, ct)
      end
      CONS = { 950 }; OWN[950] = 700
      MONEY[700] = 50000000
      LBAL[601] = 300000
      WAIT[601] = 500
      ACTS = {}
      G.AI = {}; G.AIS = {}
      local co = { ent = 700, id = 2 }
      local bought = M.f.RL.manage(E, co, 50000000)
      local buy = lastAct("makeVehicleBuyCmd")
      local first = bought == true and buy ~= nil and buy.args[2] == 951 and G.AI.trainFor == 601
      -- the next look: the idle train sent to that line
      VEH[#VEH + 1] = 803; OWN[803] = 700; VLINE[803] = -1
      local sent = M.f.RL.manage(E, co, 50000000)
      local set = lastAct("makeVehicleSetLineCmd")
      local second = sent == true and set ~= nil and set.args[1] == 803 and set.args[2] == 601
      -- a line that loses money (past its first two months): no train more
      ACTS = {}; G.AI.railLookAt = nil; VLINE[803] = 601; LBAL[601] = -500000; G.AI.railSince = { [601] = TIME - 500000 }
      local lose = M.f.RL.manage(E, co, 50000000)
      -- three trains already: none more
      LBAL[601] = 300000; G.AI.railLookAt = nil; VEH[#VEH + 1] = 804; OWN[804] = 700; VLINE[804] = 601
      local full = M.f.RL.manage(E, co, 50000000)
      -- losing money with nothing waiting, past its first two months: a train sold after 5 looks
      ACTS = {}; LBAL[601] = -500000; WAIT[601] = 0
      local sold = 0
      for i = 1, 6 do G.AI.railLookAt = nil; if M.f.RL.manage(E, co, 50000000) == true then sold = sold + 1 end end
      local sale = acts("makeVehicleSellCmd")
      -- given up so: RL.underway takes its stations for a railway running, no train bought for it again
      local dropped = G.AI.railDropped and G.AI.railDropped[601] == true
      api.engine.getComponent = gc
      VEH = { 801, 802 }
      return tostring(first) .. " " .. tostring(second) .. " " .. tostring(lose) .. " " .. tostring(full) .. " " .. acts("makeVehicleBuyCmd") .. " " .. sale .. " " .. tostring(dropped)
    ''')
    check(res == "true true false false 0 2 true", f"cargo piling up: a train more at its depot, then sent to the line; losing money or 3 trains: none; losing with nothing waiting 5 looks: a train sold a look ({res})")

    run('os.getenv = (function(g) return function(k) if k == "MPFEVER_AIRAIL" then return "0" end return g(k) end end)(os.getenv)')
    check(run('return #M.f.myLines(E, 700)') == 2 and run('return #M.f.myVehicles(E, 700)') == 2, "MPFEVER_AIRAIL=0: every line and vehicle, as before")
    check(run('return M.f.RL.project(E, { ent = 700, id = 2 }, {}, 1e9, true)') is False, "MPFEVER_AIRAIL=0: no railway")

    print(f"\n{len(failures)} failure(s)" if failures else "\nall passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
