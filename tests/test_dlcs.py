"""Offline test of the DLC check between the host and the players (0.6.9, launcher Mods.InstalledDlcs / DlcWarning, the
lobby's dlcWarn in mpfever_menu.lua).

The reports of AMD and keviK (2026-11-02, one company per player, 7 reloads): keviK's game loaded the Deluxe upgrade pack and
the pre-order pack, AMD's none. Those DLCs activate themselves and put their animals, people, vehicles and landmarks in the
world of one game only: the games made other entities (2 of 98 vehicles and lines with another id on each game, the first
right before the first reload), then the vehicles and the towns went apart. The launcher now compares them:
  - the host sends its DLCs in its lobby and its welcome; each player compares them (CheckHostDlcs), says so, and sends its
    own to the host (dlccheck), which names the player in its lobby ("(different DLCs)") and logs the warning;
  - the in-game lobby shows the warning in a red box (st.dlcWarn);
  - the problem report says this PC's DLCs and what differs; the launcher logs them when it starts.
The comparison itself is checked by MPFever.exe --selftest (RunDlcs). Run: python tests/test_dlcs.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


def main():
    mods = read("launcher", "Mods.cs")
    form = read("launcher", "MainForm.cs")
    core = read("launcher", "Core.cs")
    st = read("launcher", "SelfTest.cs")
    menu = read("mod", "mpfever_1", "content", "mpfever_menu.lua")
    check("this PC's DLCs: the folders of the game's dlcs with a mod.json", 'Path.Combine(g, "dlcs")' in mods and 'File.Exists(Path.Combine(x, "mod.json"))' in mods)
    # (0.7.0: the session's DLCs, the savegame's when its mods are known, see SessionDlcs and tests/test_joinreview.py)
    check("the host's lobby carries its DLCs", form.count('[\\"dlcs\\"]=" + LuaLit.Quote(SessionDlcs())') == 3)
    check("a player compares them, from the lobby and from the welcome", 'CheckHostDlcs(S("dlcs"), client, name);' in form and "CheckHostDlcs(ds0, client, name);" in form)
    check("and sends its own to the host", 'Msg.Make("dlccheck", name,' in form)
    check("the host names the player in its lobby and logs the warning", 'case "dlccheck":' in form and '" (DLC différents)", " (different DLCs)"' in form
          and "Log.Err(warn)" in form)
    check("the lobby's status carries the warning", '["dlcWarn"] = (lobbyOpen || hostGame != null) ? HostDlcWarn() : dlcWarn,' in form)
    check("the in-game lobby shows it", 'if st.dlcWarn and st.dlcWarn ~= "" then' in menu and "text(st.dlcWarn," in menu)
    check("the problem report says the DLCs", 'sb.AppendLine("DLCs: " + Mods.InstalledDlcs()' in form)
    check("the launcher logs them at start", "Mods.InstalledDlcs());" in core and '"DLC du jeu sur ce PC : "' in core)
    check("an older MPFever's lobby (no list): nothing said", "if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return none;" in mods)
    check("the self test runs the comparison", "ok &= RunDlcs();" in st)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
