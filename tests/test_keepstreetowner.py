"""Offline test of the shared street given back to its company (0.6.10, SIM.keepStreetOwner in the bridge).

One company per player: a station, stop or depot put on another company's shared street made the street's new pieces the
builder's (the game's own rule; "the street no longer belongs to me", 2026-11-01). The user's rule: a shared street stays its
company's (one not shared is turned down in the tool, G.streetVeto). Before the build, the street segments it takes away that
belong to a company with open roads are noted by their end nodes; right after it, the new street segments that touch one of
those nodes, belong to another company and are not part of a construction are given back (makeEntitySetPlayerCmd), on every
game at the build's step. SIM.keepStreetOwner is taken from the real bridge and run through lupa (Lua 5.2) with mocks. Cases:
  - the client cuts the host's shared street: the two pieces go back to the host, the new branch stays the client's;
  - a piece that is a station's own segment (part of a construction): left alone;
  - the street's company has private roads (the AI's script, say): left as the game made it;
  - a town street (no owner), the builder's own street: nothing;
  - "post" at another step than "pre", or without "pre": nothing;
  - one company for everybody, MPFEVER_KEEPSTREETOWNER=0: nothing;
  - the bridge's handleEvent calls it at onPreBuildProposal and onPostBuildProposal.
Run: python tests/test_keepstreetowner.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOG = {}
log = function(s) LOG[#LOG + 1] = s end
NOW = 1000
gameTime = function() return NOW end
SIM = {}
-- edges: id -> { street = bool, node0, node1, owner, con }
EDGES = {}
-- the companies: player entity -> company id; their road rules
CO = {
  idOfEntity = function(reg, e) return reg.byEnt[e] end,
  find = function(reg, id) return reg.cos[id] end,
}
RULE = { [1] = "open", [2] = "open" }
C = { eco = function() return { roadRule = function(reg, c) return { rule = RULE[c.id] } end } end }
R = {
  CO = { mode = "separate", byEnt = { [500] = 1, [600] = 2 }, cos = { [1] = { id = 1 }, [2] = { id = 2 } } },
  ownerOf = function(e) return EDGES[e] and EDGES[e].owner end,
  -- (the new segments by their places: here the ids of the segments at those places, IDS)
  idsAt = function(segs, nodes) local out = {} for i = 1, #segs do out[i] = IDS[i] or -1 end return out end,
}
IDS = {}
SENT = {}
api = {
  type = { ComponentType = { BASE_EDGE_STREET = 'street', BASE_EDGE = 'edge' } },
  engine = {
    getComponent = function(e, ct)
      local d = EDGES[e]
      if not d then return nil end
      if ct == 'street' then return d.street and {} or nil end
      if ct == 'edge' then return { node0 = d.node0, node1 = d.node1 } end
    end,
    system = { streetConnectorSystem = { getConstructionEntityForEdge = function(e) return EDGES[e] and EDGES[e].con or -1 end } },
  },
  cmd = {
    makeEntitySetPlayerCmd = function(e, p) return { e = e, p = p } end,
    sendCommand = function(c) SENT[#SENT + 1] = c; EDGES[c.e].owner = c.p end,
  },
}
-- the host's street 10 (nodes 1-2) cut by the client: pieces 21 (1-91) and 22 (91-2) and branch 23 (91-92), all the client's
function SCENE()
  EDGES = { [10] = { street = true, node0 = 1, node1 = 2, owner = 500, con = -1 } }
  SENT = {}
end
local P = { x = 0, y = 0, z = 0 }
ADDED = { { comp = { position0 = P, position1 = P } }, { comp = { position0 = P, position1 = P } }, { comp = { position0 = P, position1 = P } } }
function BUILD(extra)
  IDS = { 21, 22, 23 }
  SIM.keepStreetOwner("pre", { { proposal = { removedSegments = { { entity = 10 } }, addedSegments = ADDED } } })
  EDGES[10] = nil
  EDGES[21] = { street = true, node0 = 1, node1 = 91, owner = 600, con = -1 }
  EDGES[22] = { street = true, node0 = 91, node1 = 2, owner = 600, con = -1 }
  EDGES[23] = { street = true, node0 = 91, node1 = 92, owner = 600, con = -1 }
  if extra then extra() end
  SIM.keepStreetOwner("post", { {}, {}, {} })
  -- (the commands go at the simulation's next update)
  SIM.keepStreetFlush()
end
'''


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    m = re.search(r"^SIM\.keepStreetOwner = function\(phase, param\)\r?\n.*?^end\r?\n", src, re.S | re.M)
    f = re.search(r"^SIM\.keepStreetFlush = function\(\)\r?\n.*?^end\r?\n", src, re.S | re.M)
    if not m or not f:
        print("FAIL: SIM.keepStreetOwner or SIM.keepStreetFlush not found in the bridge")
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK + m.group(0).replace("\r\n", "\n") + f.group(0).replace("\r\n", "\n"))
    run = L.eval("function(code) return assert(load(code))() end")

    run("SCENE(); BUILD()")
    check("the host's shared street cut by the client: its two pieces go back to the host",
          run("return EDGES[21].owner") == 500 and run("return EDGES[22].owner") == 500)
    check("the new branch stays the client's", run("return EDGES[23].owner") == 600)
    check("two commands, logged", run("return #SENT") == 2 and "given back" in str(run("return LOG[#LOG]")))

    run("SCENE(); BUILD(function() EDGES[22].con = 4444 end)")
    check("a piece that is a station's own segment: left alone", run("return EDGES[22].owner") == 600 and run("return EDGES[21].owner") == 500)

    run("SCENE(); RULE[1] = 'private'; BUILD(); RULE[1] = 'open'")
    check("the street's company has private roads: left as the game made it", run("return #SENT") == 0)

    run("SCENE(); EDGES[10].owner = nil; BUILD()")
    check("a town street (no owner): nothing", run("return #SENT") == 0)
    run("SCENE(); EDGES[10].owner = 600; BUILD()")
    check("the builder's own street: nothing", run("return #SENT") == 0)

    run("SCENE(); IDS = { 21 }; SIM.keepStreetOwner('pre', { { proposal = { removedSegments = { { entity = 10 } }, addedSegments = ADDED } } }); NOW = 1200; "
        "EDGES[21] = { street = true, node0 = 1, node1 = 91, owner = 600, con = -1 }; SIM.keepStreetOwner('post', { {}, {}, {} }); NOW = 1000")
    check("post at another step than pre: nothing", run("return #SENT") == 0)
    run("SCENE(); IDS = { 21 }; EDGES[21] = { street = true, node0 = 1, node1 = 91, owner = 600, con = -1 }; SIM.keepStreetOwner('post', { {}, {}, {} })")
    check("post without pre: nothing", run("return #SENT") == 0)

    run("SCENE(); R.CO.mode = 'shared'; BUILD(); R.CO.mode = 'separate'")
    check("one company for everybody: nothing", run("return #SENT") == 0)
    run("SCENE(); ENV.MPFEVER_KEEPSTREETOWNER = '0'; BUILD(); ENV.MPFEVER_KEEPSTREETOWNER = nil")
    check("MPFEVER_KEEPSTREETOWNER=0: nothing", run("return #SENT") == 0)

    check("handleEvent calls it before and after a build",
          'pcall(SIM.keepStreetOwner, "pre", param)' in src and 'pcall(SIM.keepStreetOwner, "post", param)' in src)
    check("nothing is sent from the build's event itself (the engine refuses it): queued, sent at the next update",
          "makeEntitySetPlayerCmd" not in m.group(0) and "pcall(SIM.keepStreetFlush)" in src)
    check("the keepowner scenario is there", "H.keepowner = function(from, p)" in src)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
