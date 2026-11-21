"""Offline test: a computer company's track goes through a hill in a tunnel and over a valley on a bridge, no longer in deep cuts
and on high embankments (0.9.4, issue #450, MPFEVER_AITUNNEL; mod/mpfever_1/content/mpfever_ai.lua RL.structures,
RL.trackProposal, RL.buildTrack, RL.corridorIn), through lupa (Lua 5.2) with the mocked game of tests/ai_mock.py.

The bug (#450, TrainCityDaniel, 2026-11-20): "AI passenger track 160485-202888: 3716 m, straight, 1 crossing(s) bridged": the
track went straight through the hills, the engine cutting the ground for it (its heights follow the ground within 3 % between its
ends: under a hill they stay far below it), and over the valleys on embankments. It only had bridges over what it crosses and over
water. The fix: each piece at least 15 m under the ground (its two ends and its middle) is a tunnel (the game's rock tunnel for
trains), each piece at least 12 m over it a bridge; a run shorter than 100 m, or within 40 m of an end, stays as it was; refused by
the engine's dry run, the same way is tried again as before.

  part 1, MPFEVER_AITUNNEL=0 (the bug): a 3 km track under a 60 m hill: every piece a plain track, 30 m and more under the ground;
  part 2, the fix: the pieces deep under the hill a tunnel (the rock tunnel for trains, not the road's), one run of more than 100 m,
  none shallower than 15 m; over a 40 m deep valley, one bridge of the game's concrete bridge; a short hump stays as it was; no
  tunnel type in the game: no tunnel;
  part 3, RL.structures on its own (the ends, the bridges already there, the shortest run);
  part 4, the wiring: the dry run's refusal tries the plain track, the depot's approach stays plain, the log names them.
Run: python tests/test_aitunnel094.py
"""
import os, sys

try:
    import lupa.lua52  # noqa: F401
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

from ai_mock import load, checker

check, failures = checker()
SRC = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content", "mpfever_ai.lua"),
           encoding="utf-8").read().replace("\r\n", "\n")


def main():
    L, M = load()
    run = L.eval("function(code) local f = assert(load(code)) return f() end")
    run('''
      api.res.bridgeTypeRep = { getAll = function() return { [0] = "::/infrastructure/bridge/cable.bridge", [1] = "::/infrastructure/bridge/concrete.bridge" } end }
      api.res.tunnelTypeRep = { getAll = function() return { [0] = "::/infrastructure/tunnel/tunnel_a_car.tunnel", [1] = "::/infrastructure/tunnel/tunnel_a.tunnel",
        [2] = "::/infrastructure/tunnel/tunnel_b.tunnel" } end }
      HILL = function(x, y, z) return 10 + 60 * math.exp(-((x - 1500) / 350) ^ 2) end
      VALLEY = function(x, y, z) return 40 - 40 * math.exp(-((x - 1500) / 200) ^ 2) end
      HUMP = function(x, y, z) return 10 + 40 * math.exp(-((x - 1500) / 25) ^ 2) end
      function TRACK(ground, z)
        E.groundZ = ground
        return M.f.RL.trackProposal(E, { ent = 700 }, 11, { x = 0, y = 0, z = z }, { x = 1, y = 0 }, 22, { x = 3000, y = 0, z = z }, { x = -1, y = 0 }, 1972, nil, nil)
      end
      -- the pieces: { type, typeIndex, least depth under the ground (ends and middle), least height over it, length }
      function PIECES(sp)
        local out = {}
        for _, e in ipairs(sp.streetProposal.edgesToAdd) do
          local c = e.comp
          local a, b = c.position0, c.position1
          local mx, my, mz = (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2
          local under = math.min(E.groundZ(a.x, a.y) - a.z, E.groundZ(mx, my) - mz, E.groundZ(b.x, b.y) - b.z)
          local over = math.min(a.z - E.groundZ(a.x, a.y), mz - E.groundZ(mx, my), b.z - E.groundZ(b.x, b.y))
          out[#out + 1] = { c.type, c.typeIndex, under, over, math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) }
        end
        return out
      end
    ''')

    def pieces(code):
        t = run(code)
        return [list(t[k].values()) for k in sorted(t.keys())]

    def runs(ps, kind):
        out, cur = [], None
        for p in ps:
            if p[0] == kind:
                if cur is None:
                    cur = 0
                cur += p[4]
            elif cur is not None:
                out.append(cur); cur = None
        if cur is not None:
            out.append(cur)
        return out

    # ---- part 1: the bug
    run("ENV.MPFEVER_AITUNNEL = '0'")
    ps = pieces("return PIECES((TRACK(HILL, 10)))")
    check(all(p[0] == 0 for p in ps), "bug reproduced (MPFEVER_AITUNNEL=0): under the hill every piece a plain track")
    deepest = max(p[2] for p in ps)
    check(deepest > 30, f"  the deepest {deepest:.0f} m under the ground: a deep cut")
    run("ENV.MPFEVER_AITUNNEL = nil")

    # ---- part 2: the fix
    res = run("local sp, len, why, n, s = TRACK(HILL, 10) return s.tunnels, s.tunnelM, s.viaducts")
    ps = pieces("return PIECES((TRACK(HILL, 10)))")
    tun = [p for p in ps if p[0] == 2]
    check(len(tun) > 0 and all(p[1] == 1 for p in tun), "fix: under the hill, tunnel pieces of the rock tunnel for trains (not the road's)")
    check(all(p[2] >= 15 - 1e-6 for p in tun), "  none less than 15 m under the ground")
    r = runs(ps, 2)
    check(len(r) == 1 and r[0] >= 100, f"  one tunnel, more than 100 m ({r})")
    check(res[0] == 1 and abs(res[1] - r[0]) < 1 and res[2] == len(runs(ps, 1)), f"  said: {res[0]} tunnel(s), {res[1]:.0f} m, {res[2]} bridge(s)")
    check(all(p[3] >= 12 - 1e-6 for p in ps if p[0] == 1), "  (where the track comes down the hill at 3 % faster than the ground: bridges at least 12 m over it)")
    check(max(p[2] for p in ps if p[0] == 0) < 30, "  the deepest cut left is shallower")

    ps = pieces("return PIECES((TRACK(VALLEY, 40)))")
    br = [p for p in ps if p[0] == 1]
    check(len(br) > 0 and all(p[1] == 1 for p in br) and all(p[3] >= 12 - 1e-6 for p in br),
          "over a 40 m deep valley: bridge pieces of the concrete bridge, each at least 12 m over the ground")
    check(len(runs(ps, 1)) == 1, "  one bridge")
    ps = pieces("return PIECES((TRACK(HUMP, 10)))")
    check(all(p[0] == 0 for p in ps), "a hump 50 m wide (one piece under it): left as it was")
    run("api.res.tunnelTypeRep = { getAll = function() return {} end }")
    ps = pieces("return PIECES((TRACK(HILL, 10)))")
    check(not any(p[0] == 2 for p in ps), "no tunnel type in the game: no tunnel")

    # ---- part 3: RL.structures on its own
    def kinds(rows, total):
        code = "local p = {" + ",".join("{ s0 = %s, s1 = %s, under = %s, over = %s, fixed = %s }" % (a, b, u, o, "true" if f else "false")
                                         for a, b, u, o, f in rows) + "} local k = M.f.RL.structures(p, %s) local out = {} " \
               "for i = 1, #p do out[i] = k[i] or '-' end return table.concat(out)" % total
        return run(code)

    check(kinds([(0, 60, 20, -20, 0), (60, 120, 20, -20, 0), (120, 180, 20, -20, 0), (180, 240, 0, 0, 0)], 240) == "----",
          "a run starting at the track's end (within 40 m): left as it was")
    check(kinds([(0, 60, 0, 0, 0), (60, 120, 20, -20, 0), (120, 180, 20, -20, 0), (180, 240, 0, 0, 0)], 240) == "-tt-",
          "a run of 120 m from 60 m: a tunnel")
    check(kinds([(0, 60, 0, 0, 0), (60, 120, 20, -20, 0), (120, 180, 0, 0, 0), (180, 240, 0, 0, 0)], 240) == "----",
          "a run of 60 m: too short")
    check(kinds([(0, 60, 0, 0, 0), (60, 120, -20, 20, 0), (120, 180, -20, 20, 0), (180, 240, 0, 0, 0)], 240) == "-vv-",
          "high over the ground: a bridge")
    check(kinds([(0, 60, 0, 0, 0), (60, 120, -20, 20, 1), (120, 180, -20, 20, 0), (180, 240, -20, 20, 0), (240, 300, 0, 0, 0)], 300) == "--vv-",
          "a bridge already there (over a crossing or water) is left to itself")

    # ---- part 4: the wiring
    check("RL.TUNNEL, RL.VIADUCT, RL.STRUCTMIN, RL.STRUCTEND = 15, 12, 100, 40" in SRC, "15 m, 12 m, 100 m, 40 m")
    check('function RL.tunnelsOn() return os.getenv("MPFEVER_AITUNNEL") ~= "0" end' in SRC, "MPFEVER_AITUNNEL=0 switches it off")
    bt = SRC[SRC.index("function RL.buildTrack("):SRC.index("-- the railway of the company under way")]
    check("for _, plain in ipairs(RL.tunnelsOn() and { false, true } or { true }) do" in bt and "if not more then break end" in bt,
          "the track built: with its tunnels and bridges first, refused by the dry run the plain one")
    check('" with its tunnels and bridges" or ""' in bt and "%d tunnel(s) %.0f m, %d bridge(s) over the ground %.0f m" in bt, "  the log names them")
    ci = SRC[SRC.index("function RL.corridorIn("):SRC.index("function RL.buildTrack(")]
    check("for _, plain in ipairs(RL.tunnelsOn() and { false, true } or { true }) do" in ci
          and "if not (sp and structs and structs.tunnels + structs.viaducts > 0) then break end" in ci,
          "the railway's check before its stations are built: the same two tries")
    check("currentYear(E), {}, nil, true)" in SRC, "the depot's short approach stays plain")
    check('if a1.bridge or kinds[i] == "v" then c.type, c.typeIndex = 1, bridgeType' in SRC
          and 'elseif kinds[i] == "t" then c.type, c.typeIndex = 2, tunnelType' in SRC, "the pieces' types (2: a tunnel)")


main()
print(f"\n{len(failures)} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
