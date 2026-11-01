using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The mods of a session's savegame: where each one is installed on this PC, which version (a fingerprint of
    /// its files), what it does (models only, game data changed at load, interface, or a script acting in the game) and
    /// how it goes with MPFever. The host sends its list to the players, whose launcher compares it with their own mods:
    /// a player with another version of a mod cannot load the host's game (it would never match it).
    ///
    /// Lists travel as "id|name|source|fingerprint|kind|personal|hub|size" entries joined by ";;" (the menu's own list is
    /// "id|name|source|hub"; hub: the mod's number on its Mod Hub, mod.io or Steam Workshop, from which a player who lacks it
    /// installs it; size: its folder's size in MB on the host's PC, for a mod the host may send itself).
    ///
    /// Personal mods (0.5.0): a mod that only changes this player's interface (windows, overlays, styles: nothing that reaches
    /// the simulation, see Personal) may be active in one player's game and not in another's. The host's personal mods are
    /// left out of the other players' loads of its game, and each player's own are added to them (load_mods.txt, read by
    /// mpfever_auto.lua). A player may also take a mod for personal by hand (Forced: a warning says it can desynchronise the
    /// game), and turn off one found personal (Off).</summary>
    static class Mods
    {
        public const string Assets = "assets", Load = "load", Ui = "ui", Sim = "sim";

        /// <summary>What MPFever knows of a mod: "ok", "fixed" (made to work by MPFever), "caution" (untested script acting in the
        /// game), "bad" (known to break a session), with a short note.</summary>
        public sealed class Verdict { public string Level, Note; }

        // the mods seen in issue reports (see docs/MODS.md); the others are judged by what their files do
        static readonly Dictionary<string, Func<Verdict>> Known = new Dictionary<string, Func<Verdict>>
        {
            ["tpf3mp_1"] = () => new Verdict { Level = "bad", Note = T("Autre mod multijoueur : il modifie les mêmes choses que MPFever. Désactivez-le.", "Another multiplayer mod: it changes the same things as MPFever. Turn it off.") },
            ["auto_line_namer_1"] = () => new Verdict { Level = "fixed", Note = T("Les noms donnés par le jeu de l'hôte s'appliquent partout (0.4.0).", "The names given by the host's game apply everywhere (0.4.0).") },
            ["zhenya_auto_color_lines"] = () => new Verdict { Level = "fixed", Note = T("Les couleurs données par le jeu de l'hôte s'appliquent partout (0.4.0).", "The colours given by the host's game apply everywhere (0.4.0).") },
            ["zhenya_auto_assign_terminals"] = () => new Verdict { Level = "fixed", Note = T("Les quais choisis par le jeu de l'hôte s'appliquent partout (0.4.0).", "The platforms chosen by the host's game apply everywhere (0.4.0).") },
            // (0.6.7) Real Track Cant builds its cant pieces by script on every game: each game ships them as a player's builds, the
            // constructions then differ (393 against 469 in the session of 2026-11-01 02:20) and the host's game reloads (#96)
            ["devers_1"] = () => new Verdict { Level = "bad", Note = T("Real Track Cant construit tout seul sur chaque jeu : la partie se recharge sans cesse. Désactivez-le.", "Real Track Cant builds by itself on every game: the game keeps reloading. Turn it off.") },
            // (0.6.7) the game's own "No costs": nothing is charged, MPFever books no refund difference then (REFUND.freeBuilds)
            ["urbangames_no_costs_1"] = () => new Verdict { Level = "fixed", Note = T("Constructions gratuites : MPFever ne corrige plus leur prix entre les jeux (0.6.7).", "Free building: MPFever no longer evens out its price between the games (0.6.7).") },
            ["auto_signals_1"] = () => new Verdict { Level = "fixed", Note = T("Les signaux ajoutés ne sont construits qu'une fois, par le jeu qui a posé le signal (0.4.0).", "Added signals are built once, by the game where the signal was placed (0.4.0).") },
        };

        /// <summary>(0.6.7) A mod of this PC only, published on no Mod Hub (the game's origins "StagingArea", "Local", "User"...):
        /// only the host can send it.</summary>
        public static bool LocalSource(string source) => Regex.IsMatch(source ?? "", "staging|local|user", RegexOptions.IgnoreCase);

        public static Verdict Judge(string id, string kind)
        {
            if (id != null && Known.TryGetValue(id, out var k)) return k();
            if (kind == Sim) return new Verdict { Level = "caution", Note = T("Script qui agit sur la partie : pas encore testé avec MPFever.", "Script acting on the game: not tested with MPFever yet.") };
            return new Verdict { Level = "ok", Note = "" };
        }

        // ---- where the mods are installed

        static Dictionary<string, string> dirs;
        static DateTime dirsAt;
        static readonly Regex ModIdRx = new Regex("\"modId\"\\s*:\\s*\"([^\"]+)\"");

        /// <summary>The folder of an installed mod (mod.io, Steam Workshop, this player's own mods, the game's), or null.</summary>
        public static string Dir(string id)
        {
            lock (Known)
            {
                if (dirs == null || (DateTime.UtcNow - dirsAt).TotalSeconds > 30) { dirs = Scan(); dirsAt = DateTime.UtcNow; }
                return id != null && dirs.TryGetValue(id, out var d) ? d : null;
            }
        }

        /// <summary>The installed mods are looked for again at the next question (a mod was just installed).</summary>
        public static void Rescan() { lock (Known) dirs = null; }

        /// <summary>The folders of this player's own mods under the game's "local" folder: mods, and staging_area (0.6.7).</summary>
        public static List<string> LocalRoots(string local)
        {
            var r = new List<string> { Path.Combine(local, "mods") };
            if (Environment.GetEnvironmentVariable("MPFEVER_NOSTAGING") != "1") r.Add(Path.Combine(local, "staging_area"));
            return r;
        }

        static Dictionary<string, string> Scan()
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var roots = new List<string>();
            try
            {
                var pub = Environment.GetEnvironmentVariable("PUBLIC") ?? @"C:\Users\Public";
                var modio = Path.Combine(pub, "mod.io");
                if (Directory.Exists(modio)) foreach (var g in Directory.GetDirectories(modio)) roots.Add(Path.Combine(g, "mods"));
            }
            catch { }
            // (0.6.7) and the mods being made there, not published (the game's "StagingArea" origin: local\staging_area): the host's
            // own launcher did not find them, so it never offered them to a player who lacked them (session of 2026-11-01, three
            // SNCB I11 mods; the player's game refused the host's savegame twice). MPFEVER_NOSTAGING=1: not searched, as before
            try { foreach (var s in GameInstall.SaveDirs()) roots.AddRange(LocalRoots(Path.GetDirectoryName(s))); } catch { }
            try { foreach (var lib in GameInstall.SteamLibraries()) roots.Add(Path.Combine(lib, "steamapps", "workshop", "content", GameInstall.AppId)); } catch { }
            try { var g = GameInstall.FindGameDir(); if (g != null) { roots.Add(Path.Combine(g, "mods")); roots.Add(Path.Combine(g, "mods", "release")); } } catch { }
            foreach (var root in roots)
            {
                try
                {
                    if (!Directory.Exists(root)) continue;
                    foreach (var d in Directory.GetDirectories(root))
                    {
                        string id = null;
                        try
                        {
                            var mj = Path.Combine(d, "mod.json");
                            if (File.Exists(mj)) { var m = ModIdRx.Match(File.ReadAllText(mj)); if (m.Success) id = m.Groups[1].Value; }
                        }
                        catch { }
                        id = id ?? Path.GetFileName(d);
                        if (!map.ContainsKey(id)) map[id] = d;
                    }
                }
                catch { }
            }
            return map;
        }

        // ---- what a mod is

        static readonly Regex Skip = new Regex(@"(^|[\\/])(texture_metadata_cache\.lua|_metadata|texture_cache)([\\/]|$)|\.cache$", RegexOptions.IgnoreCase);

        /// <summary>The version of an installed mod: its files' paths and sizes, and the contents of its scripts and data.</summary>
        public static string Fingerprint(string dir)
        {
            try
            {
                var files = Directory.GetFiles(dir, "*", SearchOption.AllDirectories)
                    .Select(f => f.Substring(dir.Length).TrimStart('\\', '/').Replace('\\', '/'))
                    .Where(r => !Skip.IsMatch(r)).OrderBy(r => r, StringComparer.Ordinal).ToList();
                using (var sha = SHA1.Create())
                using (var md5 = MD5.Create())
                {
                    var sb = new StringBuilder();
                    foreach (var r in files)
                    {
                        var fi = new FileInfo(Path.Combine(dir, r));
                        sb.Append(r.ToLowerInvariant()).Append(':').Append(fi.Length);
                        var ext = Path.GetExtension(r).ToLowerInvariant();
                        if ((ext == ".lua" || ext == ".json" || ext == ".tl") && fi.Length < 4000000)
                            sb.Append(':').Append(BitConverter.ToString(md5.ComputeHash(File.ReadAllBytes(fi.FullName))).Replace("-", ""));
                        sb.Append('\n');
                    }
                    return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(sb.ToString()))).Replace("-", "").Substring(0, 12).ToLowerInvariant();
                }
            }
            catch { return ""; }
        }

        static readonly Regex RunScript = new Regex("\"(pre|post)?[Rr]unScript\"\\s*:\\s*\\{\\s*\"fileName\"\\s*:\\s*\"[^\"]+\"");

        /// <summary>sim: a game script that runs in the simulation (it can change the game by itself); ui: interface only;
        /// load: the game's data changed when it loads (the same on every PC with the same version); assets: models only.</summary>
        public static string Kind(string dir)
        {
            try
            {
                bool ui = false, load = false;
                foreach (var f in Directory.GetFiles(dir, "*.lua", SearchOption.AllDirectories))
                {
                    var name = Path.GetFileName(f).ToLowerInvariant();
                    var rel = f.Replace('\\', '/').ToLowerInvariant();
                    if (name.EndsWith(".gs.lua") || rel.Contains("/game_script/"))
                    {
                        var s = File.ReadAllText(f);
                        if (s.Contains("updateScript") || s.Contains("handleEventScript") || (rel.Contains("/game_script/") && Regex.IsMatch(s, @"\b(update|handleEvent)\s*=")))
                            return Sim;
                        ui = true;
                    }
                    else if (name.EndsWith(".res.lua") && new FileInfo(f).Length < 200000)
                    {
                        var s = File.ReadAllText(f);
                        if (s.Contains("react-")) ui = true;
                    }
                    else if (name == "mod.lua" && Regex.IsMatch(File.ReadAllText(f), @"\b(runFn|postRunFn|preRunFn)\b")) load = true;
                }
                var mj = Path.Combine(dir, "mod.json");
                if (File.Exists(mj) && RunScript.IsMatch(File.ReadAllText(mj))) load = true;
                return ui ? Ui : load ? Load : Assets;
            }
            catch { return ""; }
        }

        static readonly Dictionary<string, Tuple<string, string, string>> infoCache = new Dictionary<string, Tuple<string, string, string>>();

        /// <summary>The fingerprint, kind and personal verdict ("" = personal, else why not) of an installed mod ("" and "not
        /// installed" when not found here), computed once per folder and date.</summary>
        static Tuple<string, string, string> Info(string id)
        {
            var d = Dir(id);
            if (d == null) return Tuple.Create("", "", "not installed");
            string key;
            try { key = d + "@" + Directory.GetLastWriteTimeUtc(d).Ticks; } catch { key = d; }
            lock (infoCache)
            {
                if (infoCache.TryGetValue(key, out var t)) return t;
                t = Tuple.Create(Fingerprint(d), Kind(d), Personal(d));
                infoCache[key] = t;
                return t;
            }
        }

        static readonly Dictionary<string, string> sizeCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        /// <summary>The size of an installed mod's folder in MB (one decimal), "" when it is not installed here.</summary>
        public static string SizeMb(string id)
        {
            var d = Dir(id);
            if (d == null) return "";
            lock (sizeCache)
            {
                if (sizeCache.TryGetValue(d, out var v)) return v;
                long n = 0;
                try { foreach (var f in Directory.GetFiles(d, "*", SearchOption.AllDirectories)) n += new FileInfo(f).Length; } catch { }
                v = (n / 1048576.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
                sizeCache[d] = v;
                return v;
            }
        }

        // ---- personal mods

        /// <summary>This player's choices (settings personal.forced / personal.off, see MainForm): mods taken for personal by
        /// hand, and personal mods turned off.</summary>
        public static HashSet<string> Forced = new HashSet<string>(StringComparer.OrdinalIgnoreCase), Off = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        static readonly string[] InertExt = { ".tga", ".dds", ".png", ".jpg", ".jpeg", ".ttf", ".otf", ".md", ".txt", ".json" };
        static readonly Regex ResourceDir = new Regex(@"(^|/)(construction|constructions|model|models|vehicle|vehicles|multiple_unit|street|streets|track|tracks|bridge|bridges|tunnel|tunnels|config|names|terrain|environment|industry|industries|town|towns|landuse|game_script|scripts|shaders|textures|sound|sounds|animation|ground_texture|autogroundtex|asset|assets)/", RegexOptions.IgnoreCase);
        static readonly Regex Unsafe = new Regex(@"\bapi\s*\.\s*cmd\b|\bsendCommand\b|\bmake[A-Z]\w*Cmd\b|\bgame\s*\.\s*(interface|config)\b|\baddModifier\b|\b(addAsTable|setAsTable|removeAsTable|setVisible)\b|Rep\s*[.:]\s*(add|set|remove)\b|\b(loadstring|dofile|loadfile|setfenv|rawset)\b|\bload\s*\(|_ENV|_G\s*\[|\bdebug\s*\.|\bapp\s*\.\s*(loadGame|stopGame|quit|saveGame)|\b(updateScript|handleEventScript|guiUpdate|guiHandleEvent)\b");

        /// <summary>Whether a mod only changes its player's interface: "" when it does, else the first reason it may not (fails
        /// closed: a file it cannot account for makes it shared). Personal: GUI scripts and resources (react plugins and
        /// replacements, styles, strings, icons) that send no command, write no resource, run no game script and no script at
        /// load, and load no code by a name made at run time.</summary>
        public static string Personal(string dir)
        {
            try
            {
                var mj = Path.Combine(dir, "mod.json");
                if (!File.Exists(mj)) return "no mod.json";
                var json = File.ReadAllText(mj);
                if (!ModIdRx.IsMatch(json)) return "mod.json without modId";
                if (RunScript.IsMatch(json)) return "a script runs when the game loads";
                if (Regex.IsMatch(json, "\"archives\"\\s*:\\s*\\[")) return "archives of content";
                var cj = Path.Combine(dir, "_content.json");
                if (File.Exists(cj) && Regex.IsMatch(File.ReadAllText(cj), "\"archives\"\\s*:\\s*\\[")) return "archives of content";
                int n = 0;
                foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                {
                    if (++n > 400) return "too many files";
                    var rel = f.Substring(dir.Length).TrimStart('\\', '/').Replace('\\', '/');
                    if (Skip.IsMatch(rel)) continue;
                    var name = Path.GetFileName(rel).ToLowerInvariant();
                    var ext = Path.GetExtension(name);
                    if (!rel.StartsWith("content/", StringComparison.OrdinalIgnoreCase))
                    {
                        // outside content/ the game loads nothing but mod.json (and mod.lua, TF2's way)
                        if (name == "mod.lua") return "mod.lua";
                        continue;
                    }
                    var inner = rel.Substring(8);
                    if (ResourceDir.IsMatch("/" + inner)) return "game resources (" + inner + ")";
                    if (ext == ".lua")
                    {
                        if (name.EndsWith(".gs.lua")) return "a game script (" + inner + ")";
                        if (new FileInfo(f).Length > 2000000) return "a script too large to read (" + inner + ")";
                        var code = Regex.Replace(File.ReadAllText(f), @"--\[(=*)\[[\s\S]*?\]\1\]|--[^\n]*", "");
                        var m = Unsafe.Match(code);
                        if (m.Success) return m.Value.Trim() + " in " + inner;
                        if (name.EndsWith(".res.lua") && !Regex.IsMatch(code, "react-|\"?type\"?\\s*=\\s*\"(rename_scheme|rename_scheme_component|menu_category|menu_filter_category|drag_and_drop)\""))
                            return "a resource that is not the interface's (" + inner + ")";
                        continue;
                    }
                    if (InertExt.Contains(ext)) continue;
                    return "a file of the game's world (" + inner + ")";
                }
                return "";
            }
            catch (Exception e) { return "unreadable (" + e.Message + ")"; }
        }

        /// <summary>Every installed mod: its folder and whether it is personal, else why not (MPFever.exe --modscan).</summary>
        public static List<string> ScanReport()
        {
            var rows = new List<string>();
            foreach (var kv in Scan().OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
            {
                var why = Personal(kv.Value);
                rows.Add((why == "" ? "personal  " : "shared    ") + kv.Key + (why == "" ? "" : "  (" + why + ")") + "  " + kv.Value);
            }
            return rows;
        }

        /// <summary>A mod of the game itself (its mods folder: the campaign, sandbox...): never a player's personal mod.</summary>
        static bool GameOwn(string dir)
        {
            try
            {
                var g = GameInstall.FindGameDir();
                return g != null && Path.GetFullPath(dir).StartsWith(Path.GetFullPath(Path.Combine(g, "mods")), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        /// <summary>A mod is personal here: found so (and not turned off), or taken for personal by hand.</summary>
        public static bool IsMine(string id)
        {
            if (string.IsNullOrEmpty(id) || Dir(id) == null || GameOwn(Dir(id))) return false;
            if (Forced.Contains(id)) return true;
            return !Off.Contains(id) && Info(id).Item3 == "";
        }

        /// <summary>This player's personal mods for the menu: "id|state|on" entries (state auto: found personal, forced: taken by
        /// hand), the installed mods found personal and those taken by hand.</summary>
        public static string MineView()
        {
            Dictionary<string, string> all;
            lock (Known) { if (dirs == null || (DateTime.UtcNow - dirsAt).TotalSeconds > 30) { dirs = Scan(); dirsAt = DateTime.UtcNow; } all = new Dictionary<string, string>(dirs); }
            var rows = new List<string>();
            foreach (var id in all.Keys.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
            {
                if (id.Equals("mpfever_1", StringComparison.OrdinalIgnoreCase) || id.Equals("tpf3mp_1", StringComparison.OrdinalIgnoreCase) || id.Equals("texture_cache", StringComparison.OrdinalIgnoreCase)) continue;
                if (GameOwn(all[id])) continue;
                bool auto = Info(id).Item3 == "";
                if (!auto && !Forced.Contains(id)) continue;
                rows.Add(string.Join("|", Clean(id), auto ? "auto" : "forced", IsMine(id) ? "1" : "0"));
            }
            return string.Join(";;", rows);
        }

        /// <summary>A player's load of the host's game: the mods to leave out (the host's personal ones this player does not run,
        /// those this player took for personal and does not run) and this player's own to add. One "drop TAB id" or "add TAB
        /// id" line each (load_mods.txt in the game's session folder).</summary>
        public static string LoadPlan(string hostList)
        {
            var lines = new List<string>();
            var host = Parse(hostList);
            var hostIds = new HashSet<string>(host.Select(e => e.Id), StringComparer.OrdinalIgnoreCase);
            foreach (var e in host)
            {
                if (BuiltIn(e)) continue;
                bool personal = e.P != "" || Forced.Contains(e.Id);
                if (personal && !IsMine(e.Id)) lines.Add("drop\t" + e.Id);
            }
            Dictionary<string, string> all;
            lock (Known) { if (dirs == null) { dirs = Scan(); dirsAt = DateTime.UtcNow; } all = new Dictionary<string, string>(dirs); }
            foreach (var id in all.Keys.OrderBy(x => x, StringComparer.Ordinal))
                if (!hostIds.Contains(id) && !id.Equals("mpfever_1", StringComparison.OrdinalIgnoreCase) && IsMine(id)) lines.Add("add\t" + id);
            return string.Join("\n", lines) + (lines.Count > 0 ? "\n" : "");
        }

        public sealed class Entry { public string Id, Name, Source, Fp, Kind, P = "", Hub = "", Size = ""; }

        public static List<Entry> Parse(string list)
        {
            var r = new List<Entry>();
            foreach (var e in (list ?? "").Split(new[] { ";;" }, StringSplitOptions.RemoveEmptyEntries))
            {
                var f = e.Split('|');
                if (f[0].Trim() == "") continue;
                r.Add(new Entry { Id = f[0].Trim(), Name = f.Length > 1 && f[1].Trim() != "" ? f[1].Trim() : f[0].Trim(), Source = f.Length > 2 ? f[2].Trim() : "",
                    Fp = f.Length > 3 ? f[3].Trim() : "", Kind = f.Length > 4 ? f[4].Trim() : "", P = f.Length > 5 ? f[5].Trim() : "",
                    Hub = f.Length > 6 ? f[6].Trim() : "", Size = f.Length > 7 ? f[7].Trim() : "" });
            }
            return r;
        }

        static string Clean(string s) => Regex.Replace(s ?? "", "[|;\\p{Cc}]", " ");

        static bool BuiltIn(Entry e) => e.Source.IndexOf("BuiltIn", StringComparison.OrdinalIgnoreCase) >= 0 || e.Source.Equals("DLC", StringComparison.OrdinalIgnoreCase);

        /// <summary>The host: its savegame's mods ("id|name|source", from its menu) with the fingerprint, kind and personal mark
        /// of each (auto: found personal, forced: taken for personal by the host).</summary>
        public static string Describe(string list)
        {
            return string.Join(";;", Parse(list).Select(e =>
            {
                var i = BuiltIn(e) ? Tuple.Create("", Assets, "built in") : Info(e.Id);
                string p = BuiltIn(e) || Off.Contains(e.Id) ? "" : Forced.Contains(e.Id) ? "forced" : i.Item3 == "" ? "auto" : "";
                // (the menu's list: its 4th field is the mod's Mod Hub number)
                string hub = Regex.Replace(e.Fp ?? "", "[^0-9A-Za-z_-]", "");
                string size = BuiltIn(e) ? "" : SizeMb(e.Id);
                return string.Join("|", Clean(e.Id), Clean(e.Name), Clean(e.Source), i.Item1, i.Item2, p, hub, size);
            }));
        }

        /// <summary>A player: the host's mods compared with this PC's. View: "id|name|source|kind|level|here|note|personal" for
        /// the menu, here = "ok", "differs" (another version), "notfound" (no folder found here: the menu asks the game whether it
        /// is installed), "" (not compared: the host's own list, a mod of the game itself, or a folder the host could not find);
        /// personal = "host" (the host's personal mod: not needed here), "mine" (taken for personal here), "" (needed as the
        /// host's). A personal one is never missing nor another version.</summary>
        public sealed class Check { public string View = ""; public List<string> Differs = new List<string>(), Missing = new List<string>(), Bad = new List<string>(), MissingIds = new List<string>(); }

        public static Check Compare(string hostList, bool isHost)
        {
            var c = new Check();
            var rows = new List<string>();
            foreach (var e in Parse(hostList))
            {
                string here = "";
                string kind = e.Kind;
                string personal = isHost ? (e.P != "" ? "host" : "") : (e.P != "" ? "host" : Forced.Contains(e.Id) ? "mine" : "");
                if (!isHost && !BuiltIn(e))
                {
                    var mine = Info(e.Id);
                    if (Dir(e.Id) == null) { here = "notfound"; if (personal == "") { c.Missing.Add(e.Name); c.MissingIds.Add(e.Id); } }
                    else if (e.Fp != "" && mine.Item1 != "") { here = mine.Item1 == e.Fp ? "ok" : "differs"; if (here == "differs" && personal == "") c.Differs.Add(e.Name); }
                    if (kind == "") kind = mine.Item2;
                }
                var v = Judge(e.Id, kind);
                if (v.Level == "bad") c.Bad.Add(e.Name);
                rows.Add(string.Join("|", Clean(e.Id), Clean(e.Name), Clean(e.Source), kind, v.Level, here, Clean(v.Note), personal, e.Hub, e.Size));
            }
            c.View = string.Join(";;", rows);
            return c;
        }

    }
}
