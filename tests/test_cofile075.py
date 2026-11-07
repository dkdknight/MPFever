"""Offline test: the interface no longer takes the companies of the world before (0.7.5, the crash "separate -> shared").

The user's crash of 2026-10-28, reproduced by the autotest "toshared" twice on 2026-11-07 (ts2 14:20:39, ts3 14:33:40): a
client game that played a session of one company per player, then joined a session of one company for everybody without
closing the game, crashed right after the load ("it != components.end()", ecs::Engine::GetComponentDataIndex, from
UI::CSelector). Its session folder stays the same until the game closes, and the bridge writes companies.txt only with one
company per player: the interface read the file of the session before ("me 3", company 3 = entity 108734, which the new world
does not have as a company), and the native module still gave the interface this machine's company of the session before
(108734) while the new world's interface made itself: the money popups' HUD item (0x789bf0) kept that player and read its
popups' positions on an entity that is no company there.
  - the interface's pollCompanies (run here through lupa with a mocked game): a file naming an entity that is no company in
    this world is left (no map, no company of its own, said once), read again later; a file of this world is taken;
    MPFEVER_COFILEOLD=1: taken as it is, as before;
  - the bridge writes "me 0" (no companies) in a session of one company for everybody (coGui), MPFEVER_COFILEOLD=1: not;
  - the native module forgets this machine's company, the savegame's and the others' when a game is being loaded (its first
    copy into a fresh state, before its interface is made), MPFEVER_LOADKEEPLOCAL=1: kept.
Run: python tests/test_cofile075.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_ui.script.lua")
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
FILE = ""
LOGS = {}
C = { DIR = "d", BS = "/", NL = "\n", TAB = "\t",
  IO = { open = function(path, mode) return { read = function() return FILE end, close = function() end } end } }
PLAYERS = { [31434] = true, [46534] = true }
api = { type = { ComponentType = { PLAYER = "player" } }, engine = {
  entityExists = function(e) return e == 31434 or e == 46534 or e == 5000 end,
  getComponent = function(e, ct) if ct == "player" and PLAYERS[e] then return {} end return nil end } }
U = {}
function log(s) LOGS[#LOGS + 1] = s end
local function patchGameModules() end
'''


def main():
    ui = open(UI, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"^local function pollCompanies\(\)\n.*?^end\n", ui, re.S | re.M)
    check(m is not None, "pollCompanies found")
    if not m:
        return 1
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(MOCK + "\n" + m.group(0) + "\nPOLL = pollCompanies")
    stale = "me\t3\n1\t31434\t\n2\t46534\tFirma keviK\n3\t108734\tEntreprise Client\ncolor\t1\t7\n"
    L.execute("FILE = " + repr(stale).replace("\\t", "\\t") + "; POLL()")
    check(L.eval("next(U.coMap) == nil and U.myCo == nil and U.canon == nil"), "a file of the world before (entity 108734 no company here): no companies, no company of its own")
    check(L.eval("#LOGS == 1 and LOGS[1]:find('108734', 1, true) ~= nil"), "said once")
    L.execute("POLL(); POLL()")
    check(L.eval("#LOGS == 1 and U.myCo == nil"), "read again later, still left, said once")
    good = "me\t2\n1\t31434\t\n2\t46534\tFirma keviK\ncolor\t1\t7\ncolor\t2\t2\n"
    L.execute("FILE = " + repr(good) + "; POLL()")
    check(L.eval("U.myCo == 2 and U.coMap[46534] == 2 and U.coMap[31434] == 1 and U.canon == 31434"), "a file of this world: taken (its company 2, the savegame's 31434)")
    check(L.eval("#LOGS == 2 and LOGS[2]:find('companies known to the interface', 1, true) ~= nil"), "  and logged as before")
    L.execute("FILE = 'me\\t0\\n'; POLL()")
    check(L.eval("U.myCo == nil and next(U.coMap) == nil"), "\"me 0\" (one company for everybody): none")
    L.execute("ENV.MPFEVER_COFILEOLD = '1'; U = {}; FILE = " + repr(stale) + "; POLL()")
    check(L.eval("U.myCo == 3 and U.coMap[108734] == 3"), "MPFEVER_COFILEOLD=1: taken as it is, as before")

    br = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    i = br.find("local function coGui(st)")
    body = br[i:i + 900]
    check('if G.cmode ~= "separate" then' in body and 'G.coFile = "me\t0" .. NL' in body and 'C.IO.open(C.DIR .. BS .. "companies.txt", "wb")' in body,
          "the bridge writes \"me 0\" in a session of one company for everybody")
    check('os.getenv("MPFEVER_COFILEOLD") ~= "1"' in body, "  not with MPFEVER_COFILEOLD=1")

    nat = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
    i = nat.find('extern "C" u64 ReplDetour(void* src, void* dst, u64 flag)')
    rd = nat[i:i + 3000]
    a = rd.find("if (dst && before == 0xFFFFFFFFu && (u32)((uptr)_ReturnAddress() - g_base) != RVA_REPL_LOOP) {")
    b = rd.find("if (!LoadKeepLocal()) DropAtLoad();")
    c = rd.find("u64 r = g_replOrig(src, dst, flag);")
    check(0 < a < b < c, "native: a game being loaded (its first copy into a fresh state, before its interface is made) forgets this machine's company")
    d = nat[nat.find("static void DropAtLoad()"):]
    d = d[:d.find("\n}\n")]
    check("_InterlockedExchange(&g_localPlayer, 0)" in d and "NoteStale(0, lp)" in d and "g_nOthers = 0;" in d and 'DropCanon("a game is being loaded")' in d,
          "  and the savegame's and the other companies' (until the mod says them again)")
    check('GetEnvironmentVariableA("MPFEVER_LOADKEEPLOCAL", e, 3)' in nat, "  MPFEVER_LOADKEEPLOCAL=1: kept, as before")
    br2 = br[br.find("if c and c.ent and (G.myCo ~= c.id or G.myEnt ~= c.ent or osig ~= G.coOthers"):][:400]
    check("G.frames - (G.coAsserted or 0) > (G.frames < 1200 and 30 or 400)" in br2, "  (the mod says this machine's company again every 400 frames, 30 at first, with a new token)")

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
