"""Offline test of the launcher's left card in 0.7.13 (asked by the user, 2026-11-09):

  The « Connection » card of the MPFever window (your name, host address, port, « Host a game », « Join by IP ») had been of no
  use since the game's Multiplayer page (0.3.18) hosts and joins (its lobby, the server list, Steam invitations, +mpfever_connect),
  and players clicked its buttons before starting the game: a session without the lobby, then a second game with « Start
  Transport Fever 3 ». A player's window now shows « ⚙ Settings » (the settings window), « ♥ Support MPFever » (Ko-fi) and
  « Discord » there, and where to host or join. The developer mode (--dev, the autotests) keeps the old card, whose buttons
  start its sessions; MPFEVER_CONNCARD=1 shows it to a player as before. The port of a lobby, which only that card's field
  changed: port= in mpfever_settings.txt (28090 without it, as before).
The decisions (ConnCard, PortSetting) are run by the launcher's self-test; this checks the code uses them where it must and that
nothing the sessions use went with the card.
Run: python tests/test_launcherlinks0713.py
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read()


main = read("launcher", "MainForm.cs")
thanks = read("launcher", "ThanksDialog.cs")
server = read("launcher", "Server.cs")
selftest = read("launcher", "SelfTest.cs")
lang = json.loads(read("launcher", "lang.json"))["texts"]
fails = []


def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def body(src, start, end):
    i = src.find(start)
    j = src.find(end, i + 1) if i >= 0 else -1
    return src[i:j] if i >= 0 and j > i else ""


bu = body(main, "        void BuildUi()", "// ---------------------------------------------------------------- language")
links = body(main, "        Card BuildLinksCard()", "\n        }\n")
opens = body(main, "        void OpenSettings()", "\n        }\n")

# 1. the card a player's window shows, the old one in developer mode or with the switch
check("the left card: the server's, the old one (--dev, MPFEVER_CONNCARD=1) or the links",
      "Ui.StackTop(left, ServerMode ? BuildServerCard() : ConnCardOn ? conn : BuildLinksCard(), Ui.Gap(14));" in bu)
check("  the old card only in developer mode or with MPFEVER_CONNCARD=1",
      'internal static bool ConnCard(bool dev, string env) => dev || env == "1";' in main
      and 'static bool ConnCardOn => ConnCard(Dev, Environment.GetEnvironmentVariable("MPFEVER_CONNCARD"));' in main)
check("  the old card itself unchanged (name, address and port, host, join, local test in --dev)",
      'Ui.Field(T("Votre nom", "Your name"), nameBox),' in bu and "Ui.Gap(8), hostRow, Ui.Gap(16), hostBtn, Ui.Gap(8), joinBtn };" in bu
      and "if (Dev) connItems.AddRange(new Control[] { Ui.Gap(8), localBtn });" in bu
      and 'var portField = Ui.Field(T("Port", "Port"), portBox);' in bu)

# 2. the new card: three buttons on the existing code, nothing of a session
check("links: Settings opens the settings window", 'T("⚙ Réglages", "⚙ Settings")' in links and "settingsBtn.Click += (s, e) => OpenSettings();" in links)
check("links: Support MPFever opens Ko-fi", 'T("♥ Soutenir MPFever", "♥ Support MPFever")' in links
      and "supportBtn.Click += (s, e) => ThanksDialog.Open(ThanksDialog.KofiUrl);" in links)
check("links: Discord opens the invitation", '{ Text = "Discord" }' in links and "discordBtn.Click += (s, e) => ThanksDialog.Open(ThanksDialog.DiscordUrl);" in links)
check("links: the launcher's button kinds, a caption, and where to host or join",
      "new ModernButton(ButtonKind.Primary)" in links and links.count("new ModernButton(ButtonKind.Secondary)") == 2
      and 'Ui.Caption(T("Réglages et communauté", "Settings and community"))' in links and "Text = PlayWhereText()" in links
      and "Ui.FitHeight(card);" in links)
check("links: no session control in it", all(x not in links for x in ("hostBtn", "joinBtn", "localBtn", "hostBox", "portBox", "nameBox", "StartHost", "StartClient", "Guard(")))
check("the URLs: Ko-fi and the Discord invitation", 'public const string KofiUrl = "https://ko-fi.com/knighthd";' in thanks
      and 'public const string DiscordUrl = "https://discord.gg/DfMxFUQZCR";' in thanks
      and "internal static void Open(string url)" in thanks and "try { Process.Start(url); }" in thanks)

# 3. the bottom bar keeps its links; one settings window for both
check("the bottom bar: Settings, Discord, Ko-fi, the author, as before",
      all(x in bu for x in ("footer.Controls.Add(settingsLink);", "footer.Controls.Add(discord);", "footer.Controls.Add(kofi);", "footer.Controls.Add(credit);",
                            'Process.Start("https://ko-fi.com/knighthd")', "Process.Start(ThanksDialog.DiscordUrl)")))
check("the bottom bar's Settings opens the same window", "settingsLink.Click += (s, e) => OpenSettings();" in bu)
check("the settings window as before (read only for a guest, every game gets the settings)",
      "bool guest = relay == null && clients.Count > 0 && Options.HostSession != null;" in opens
      and "using (var d = new OptionsDialog(guest)) d.ShowDialog(this);" in opens and "foreach (var g in games.ToList()) g.WriteSettings();" in opens)

# 4. the help before the game: where to play for a player, the old text with the old card
check("the first help: where to play (the old text with the old card)",
      'else h = !ConnCardOn ? PlayWhereText() : T("Hébergez une partie ou rejoignez un ami avec son adresse IP.' in main)

# 5. what the sessions use stays: host / join themselves, the menu, Steam invitations, +mpfever_connect, the autotests, the server
kept = [
    ("StartHost and StartClient", "void StartHost(string name, bool launch, GameLink existing = null)" in main
     and "void StartClient(string name, string host, int port, bool launch, GameLink existing = null, string password = null)" in main),
    ("the old card's handlers (--dev)", "hostBtn.Click += (s, e) => Guard(() => StartHost(PlayerName(), true));" in main
     and "joinBtn.Click += (s, e) => Guard(() => StartClient(PlayerName(), hostBox.Text.Trim(), (int)portBox.Value, true));" in main
     and "localBtn.Click += (s, e) => Guard(StartLocalTest);" in main),
    ("the autotests' local test", "Guard(StartLocalTest);" in body(main, "void InitFinish()", "/// <summary>(0.6.5, #111)")
     and 'StartClient("Client", "127.0.0.1", (int)portBox.Value, true)' in main),
    ("the Multiplayer page's host and join", "try { StartHost(name, false, menuGame); }" in main and "try { StartClient(name, host, port, false, menuGame," in main),
    ("the port of the page's lobby and joins, the relay's", main.count("(int)portBox.Value") >= 5 and "int listenPort = server != null ? server.Port : (int)portBox.Value;" in main),
    ("Steam invitations and --join", main.count('OnMenuRequest("join", addr, menuGame.Name)') == 2 and 'connect.IndexOf("+mpfever_connect", StringComparison.Ordinal)' in main
     and 'steamConnect = "+mpfever_connect " + viaSteam + pub + ":" + port' in main),
    ("the page's name shown and kept", 'SaveSetting("name", name);' in main and "nameBox.Text = name" in main),
    ("the buttons off once a session runs (Guard, the menu, the server)", "try { a(); running = true; hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false; }" in main
     and main.count("hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false;") == 2 and "hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false;" in server),
    ("the dedicated server's card", "Card BuildServerCard()" in server),
]
for name, cond in kept:
    check("kept: " + name, cond)

# 6. the port of a lobby without the card's field
check("port: port= in mpfever_settings.txt, else 28090", "Value = SavedPort() };" in main
      and 'static int SavedPort() => PortSetting(LoadSettings().TryGetValue("port", out var p) ? p : null);' in main
      and "&& n >= 1024 && n <= 65535 ? n : 28090;" in main)

# 7. the texts in every language (test_lang.py checks every text; these are the new ones and the ones reused)
LANGS = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
for k in ["Settings and community", "⚙ Settings", "♥ Support MPFever",
          "To host or join a game: the « Multiplayer (MPFever) » page of the game's main menu, the server list or a Steam invitation."]:
    check("translated in 11 languages: " + k[:50].encode("ascii", "replace").decode(), all((lang.get(k) or {}).get(c) for c in LANGS))

# 8. the self-test runs the decisions
check("the self-test runs ConnCard and PortSetting", "ok &= RunLinks0713();" in selftest and "MainForm.ConnCard(" in selftest and "MainForm.PortSetting(" in selftest)

print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
