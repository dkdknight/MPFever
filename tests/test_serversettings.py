"""Offline test of the dedicated server's settings window (0.6.13, the user's request of 2026-11-05: "a nice interface for every
setting of the server, with the list of the savegames and the computer companies", instead of mpfever_server.properties in
Notepad).

  - the game options' catalog the window shows (launcher/gameopts.json) is the one the feature modules give now
    (tools/gen_gameopts.py --check), and MPFever.exe embeds it;
  - every key the server reads (ServerConfig.Set) is written by the window (ServerConfig.Text), so « Save » loses none, and the
    file keeps its comments; the two new keys, bankruptcy-months and ai-companies, are read by the session (BankruptMonths(),
    AiPayload());
  - the window: its six pages (server, world with the savegames, companies, computer companies, game options, running), « Save »
    writes the file through ServerConfig.Save, the server reads it again when stopped, at the next restart when running, or now
    with « Save and restart the world »; the server's card opens it (MPFEVER_SERVERNOTEPAD=1: Notepad, as before).
The writing and reading back, the computer companies' text and the catalog's loading are checked by MPFever.exe --selftest
(RunServerConfig). Run: python tests/test_serversettings.py
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


def main():
    try:
        import lupa  # noqa: F401
    except ImportError:
        print("lupa is not installed (pip install lupa): test skipped")
        return 0
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_gameopts.py"), "--check"], capture_output=True, text=True)
    check("the game options' catalog is up to date (python tools/gen_gameopts.py)", r.returncode == 0, (r.stdout + r.stderr).strip())
    proj = read("launcher", "MPFever.csproj")
    check("MPFever.exe embeds it", '<EmbeddedResource Include="gameopts.json" LogicalName="gameopts.json" />' in proj)

    server = read("launcher", "Server.cs")
    sets = set(re.findall(r'^\s*case "([a-z-]+)":', server[server.index("bool Set(string key, string v)"):server.index("public static string AiCanon")], re.M))
    text = server[server.index("public string Text() =>"):server.index("/// <summary>Reads the settings.")]
    written = set(re.findall(r'"([a-z-]+)=" \+', text))
    check("every key the server reads is written by the window", sets <= written and len(sets) >= 22, sorted(sets - written))
    check("the new keys", {"bankruptcy-months", "ai-companies"} <= sets)
    check("the comments are kept in the file", text.count('"# ') >= 20)
    check("written through a temporary file", "File.Replace(tmp, path, null)" in server)
    form = read("launcher", "MainForm.cs")
    check("the session reads the bankruptcy months", "if (string.IsNullOrEmpty(v) && server != null) v = server.BankruptMonths.ToString(CultureInfo.InvariantCulture);" in form)
    check("and the server's computer companies (no lobby)", "if (lobbyAi.Count == 0 && server != null) return server.AiCompanies ?? \"\";" in form)

    win = read("launcher", "ServerSettings.cs")
    pages = re.findall(r'AddPage\(T\("([^"]+)"', win)
    check("the six pages", pages == ["Serveur", "Monde", "Entreprises", "Entreprises de l'ordinateur", "Options de partie", "Fonctionnement"], pages)
    check("the world: the savegames of this PC, their picture, mods, DLCs and companies",
          "GameInstall.SaveDirs()" in win and 'Path.ChangeExtension(it.File, ".jpg")' in win and "SaveInfo.Mods(file)" in win and "SaveInfo.Read(file, true)" in win)
    check("the world: the resynchronisations' and crashes' savegames hidden, the autosaves on demand",
          'name.StartsWith("MPFever resync"' in win and 'name.StartsWith("crash_"' in win and 'n.StartsWith("autosave_"' in win)
    check("the computer companies: add, remove, level, colour, start money, the savegame's taken again",
          "ais.Count >= 8" in win and "ais.Remove(ai)" in win and "ai.Level = pick" in win and "ai.Color = pick" in win and "ai.Money = long.Parse" in win and "WorldAi()" in win)
    check("the game options: the catalog's of the mode, without the public games', through GameOpts.Apply",
          "GameOptsCatalog.ForServer(Config.CompanyMode)" in win and 'o.Module != "public"' in win and win.count("GameOpts.Apply(") == 2)
    check("« Save » writes the file; « Save and restart the world » while it runs", "c.Save(path);" in win and "RestartAsked = true;" in win)
    check("the card opens the window, Notepad with MPFEVER_SERVERNOTEPAD=1", "OpenServerSettings();" in server and 'MPFEVER_SERVERNOTEPAD' in server
          and 'if (d.RestartAsked) ServerCommand("restart");' in server and "ReloadServerConfig(); UpdateServerCard();" in server)
    check("--serversettings shows the window alone (and --shots takes its pages)", '"--serversettings"' in form and "t.SaveShots(args[si + 1])" in form)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
