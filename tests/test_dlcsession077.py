"""Offline test: a DLC some game of the session lacks is off for every game, the host's included (0.7.7, ApplyDlcOff in
launcher/MainForm.cs, Mods.DlcOff, dlcOffList in mpfever_auto.lua, C.dlcOffList / C.dropDlcs / C.loadWithPlan in mpfever_common.lua).

A DLC works like a mod of the savegame: a game loads its models, its game script (the Deluxe pack's balloon, math.random in the
simulation) and its animals only when the savegame's mods name it (4404 models on two PCs, one with both packs installed and one
with none; 4433 with the Deluxe pack named). A savegame naming a DLC a player lacked was loaded with it on the other games and
without it on that player's: the games parted (#109). Now:
  - the host decides, at the lobby's start and at every resynchronisation (a player joining among them), the savegame's DLCs that
    its PC or a player lacks (Mods.DlcOff, from each player's dlccheck); the set only grows until the session ends;
  - its own load is told (dlc_drop.txt next to the game), the players too ("dlcoff", written next to their game) before the
    savegame they load; the chat says which DLC is off and why;
  - every load leaves those DLCs out: the menu's (mpfever_auto.lua) and the reloads in the game (C.loadWithPlan), only entries the
    savegame names as DLCs;
  - a DLC installed and not used, or one switched off, gives no more "desyncs possible" warning;
  - MPFEVER_DLCSESSION=0: as before.
The launcher's self-test (RunReport077) runs Mods.DlcOff, DlcMinus and DlcWarning. Needs lupa (pip install lupa).
Run: python tests/test_dlcsession077.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
C_ = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
common = open(os.path.join(C_, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
auto = open(os.path.join(C_, "mpfever_auto.lua"), encoding="utf-8").read().replace("\r\n", "\n")
mf = open(os.path.join(HERE, "..", "launcher", "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(HERE, "..", "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


try:
    import lupa.lua52 as lupa
except ImportError:
    lupa = None
    print("lupa is not installed (pip install lupa): the Lua part skipped")

if lupa:
    fns = {}
    for name in ("dlcOffList", "dropDlcs"):
        m = re.search(r"^function C\." + name + r"\(.*?^end\n", common, re.S | re.M)
        check(m is not None, "C." + name + " found")
        fns[name] = m.group(0) if m else ""
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute('''
ENV = {}
os.getenv = function(k) return ENV[k] end
FILES = {}
BS, NL, CR = "\\\\", "\\n", "\\r"
C = { DIR = "S", IO = { open = function(p) local s = FILES[p] if not s then return nil end
  return { read = function() return s end, close = function() end } end } }
''' + fns["dlcOffList"] + fns["dropDlcs"] + '''
function mods(...) local t = {} for _, n in ipairs({...}) do t[#t + 1] = { name = n } end return t end
function names(t) local o = {} for _, m in ipairs(t) do o[#o + 1] = m.name end return table.concat(o, ",") end
DESCS = { urbangames_deluxe_upgrade_pack = { modSource = "DLC" }, auto_signals_1 = { modSource = "mod.io" }, mpfever_1 = { modSource = "local" } }
''')
    check(L.eval("C.dlcOffList()") is None, "no list, no test variable: nothing off (the reloads keep their old path)")
    L.execute('FILES["S\\\\dlc_drop.txt"] = "off\\turbangames_deluxe_upgrade_pack\\n"')
    off = L.eval("C.dlcOffList()")
    check(off is not None and off["urbangames_deluxe_upgrade_pack"] is True, "dlc_drop.txt read")
    L.execute('OUT, DROPPED = C.dropDlcs(mods("urbangames_deluxe_upgrade_pack", "auto_signals_1", "mpfever_1"), C.dlcOffList(), DESCS)')
    check(L.eval("names(OUT)") == "auto_signals_1,mpfever_1" and L.eval("names(mods(table.unpack(DROPPED)))") == "urbangames_deluxe_upgrade_pack",
          "the reload's mods without the DLC, the others kept")
    L.execute('FILES["S\\\\dlc_drop.txt"] = "off\\tauto_signals_1\\n"; OUT2 = C.dropDlcs(mods("auto_signals_1"), C.dlcOffList(), DESCS)')
    check(L.eval("names(OUT2)") == "auto_signals_1", "  only a DLC is ever left out (a mod named in the list stays)")
    L.execute('ENV.MPFEVER_DLCSESSION = "0"')
    check(L.eval("C.dlcOffList()") is None, "MPFEVER_DLCSESSION=0: nothing off")

lw = common[common.index("function C.loadWithPlan(id, logf, later)"):]
lw = lw[:lw.index("\nend\n")]
check("local off = C.dlcOffList()" in lw and "if not plan and not off then app.loadGame(id, false) return end" in lw,
      "C.loadWithPlan: the session's DLCs too; nothing to change: loaded as before")
check("mods, offOut = C.dropDlcs(mods, off, descs)" in lw and "details.mods = mods" in lw, "  the reload's details without them")
lp = auto[auto.index("local function loadPending()"):]
lp = lp[:lp.index("\nend\n")]
check("local off = dlcOffList()" in lp and 'if off[m.name] and isDlc then dropped[#dropped + 1] = m.name' in lp,
      "the menu's loads (host, player, server, autotest): the session's DLCs left out")
check('os.getenv("MPFEVER_DLCSESSION") == "0"' in auto[auto.index("local function dlcOffList()"):auto.index("local function descsOf(info)")],
      "  MPFEVER_DLCSESSION=0: none")
a = mf[mf.index("void ApplyDlcOff(IEnumerable<string> names, string why)"):]
a = a[:a.index("\n        }\n")]
check("var off = Mods.DlcOff(save, lists);" in a and "sessionDlcOff.Add(x)" in a, "the host: the savegame's DLCs some game lacks, added to the session's set")
check("WriteDlcDrop(host.Dir, off);" in a and 'Msg.Make("dlcoff"' in a and "HostChat(" in a, "  its own load told, the players told, the chat says it")
sl = mf[mf.index("void StartLobbyGame()"):]
check(sl.find("ApplyDlcOff(peers,") < sl.find('menuLoadSeq = "h" + DateTime.Now.Ticks;'), "the lobby's start: before the host's own load")
rl = mf[mf.index("void ResyncLocked(string reason)"):]
check(rl.find("ApplyDlcOff(dlcAll,") < rl.find('Msg.Make("resync_save"'), "a resynchronisation (a joining player among them): before the save every game reloads")
check('lock (playerDlcs) playerDlcs[who] = theirs;' in mf, "each player's DLCs kept from its dlccheck")
check('if (m.Kind == "dlcoff")' in mf and "WriteDlcDrop(game.Dir," in mf, "a player writes the host's list next to its game")
check("lock (sessionDlcOff) sessionDlcOff.Clear();" in mf and "WriteDlcDrop(game.Dir, null);" in mf, "forgotten when the session ends; a new player session starts with none")
check("Mods.DlcOff(" in st and "Mods.DlcMinus(" in st, "the launcher's self-test runs DlcOff and DlcMinus")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
