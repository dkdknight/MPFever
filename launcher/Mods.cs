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
            // constructions then differ (393 against 469 in the session of 2026-11-01 02:20) and the host's game reloads (#96).
            // (0.7.0) Those builds come from its interface, by itself after a load: one game sends them now (mpfever_modauto.lua)
            ["devers_1"] = () => new Verdict { Level = "caution", Note = T("Ses constructions automatiques ne partent plus que d'un jeu (0.7.0) : à confirmer en partie.", "Its automatic builds now go from one game only (0.7.0): to confirm in a session.") },
            // (0.6.7) the game's own "No costs": nothing is charged, MPFever books no refund difference then (REFUND.freeBuilds)
            ["urbangames_no_costs_1"] = () => new Verdict { Level = "fixed", Note = T("Constructions gratuites : MPFever ne corrige plus leur prix entre les jeux (0.6.7).", "Free building: MPFever no longer evens out its price between the games (0.6.7).") },
            ["auto_signals_1"] = () => new Verdict { Level = "fixed", Note = T("Les signaux ajoutés ne sont construits qu'une fois, par le jeu qui a posé le signal (0.4.0).", "Added signals are built once, by the game where the signal was placed (0.4.0).") },
        };

        // (0.7.0) the 83 most downloaded script mods of mod.io, read one by one (docs/MODS.md): those that work as they are, and
        // those made to work by 0.7.0 (their interface's automatic commands sent by one game only, see mpfever_modauto.lua)
        static readonly string[] CheckedOk =
        {
            "parallel_tracks_1", "parallel_roads_1", "automatic_signal_spacing", "automatic_station_throat", "auto_bridges_1",
            "express_local_stations_1", "ethan_track_connector", "celmi_timetables", "tcoleman_financial_statements_1",
            "keinschlechterruf", "budok_stop_capacity_tf3_1", "hary_export_hub", "dgbooth_supply_chain_manager_1", "spy_industry_evolution",
            "maksymenkoml_roadform_1", "move_it", "move_it_probe_overpass", "undo_tf3_test", "road_station_expander",
            "local_underground_cargo_stop", "industry_tram_access_1", "deadeye_tpf3_bus_bay", "bus_loops_1", "miib_city_bus_lines",
            "mz_gleisset3", "cmf_bb27000_base_pack_1", "tpf3_grab_bb60000_1", "tpf3_Grab_SignalFR_Mod_1", "zhenya_easy_terminal_assignment",
            "jansc_fehlerstellen", "train_horns_1", "square_better_minimap", "build_anyway_1", "zhenya_doubleclick_to_edit",
        };
        static readonly string[] FixedHostNames = { "visual_auto_namer", "gameburrow_destinationdisplays" };
        static readonly string[] Fixed0613 =
        {
            "line_role_renamer", "modern_bus_shelter", "kamil_street_lights_1", "sydney_harbour_bridge", "zhenya_optimized_traffic_lights",
            "square_smart_lanes", "epod_pay_your_tolls_tf3_1", "epod_pyt_mega_warehouse_1", "blueprint_demo", "just_more_weather_1",
            "square_organic_towns", "gabri_cargo_catchment_1", "advanced_station_editor", "john_cargo_station_drag",
        };
        static readonly string[] ToCheck = { "stombor_zoning", "hugedragonyk_uep3_b07_shopping_mall_and_auto_dealership_1", "stardorn_industry_upgrades" };

        static Verdict Checked(string id)
        {
            if (CheckedOk.Contains(id)) return new Verdict { Level = "ok", Note = T("Script lu : rien qui désynchronise (0.7.0).", "Script read: nothing that desynchronises (0.7.0).") };
            if (FixedHostNames.Contains(id)) return new Verdict { Level = "fixed", Note = T("Les noms donnés par le jeu de l'hôte s'appliquent partout (0.4.0).", "The names given by the host's game apply everywhere (0.4.0).") };
            if (Fixed0613.Contains(id)) return new Verdict { Level = "fixed", Note = T("Ce qu'il envoie tout seul ne part plus que d'un jeu (0.7.0) : à confirmer en partie.", "What it sends by itself now goes from one game only (0.7.0): to confirm in a session.") };
            if (ToCheck.Contains(id)) return new Verdict { Level = "caution", Note = T("Script lu : un point reste à vérifier en partie (voir MODS.md).", "Script read: one point is still to check in a session (see MODS.md).") };
            return null;
        }

        /// <summary>(0.6.7) A mod of this PC only, published on no Mod Hub (the game's origins "StagingArea", "Local", "User"...):
        /// only the host can send it.</summary>
        public static bool LocalSource(string source) => Regex.IsMatch(source ?? "", "staging|local|user", RegexOptions.IgnoreCase);

        // ---- (0.6.9) the game's DLCs
        // The DLCs (the Deluxe edition's upgrade pack, the pre-order pack) activate themselves in every game of the PC that owns
        // them: their animals, people, vehicles and landmarks are in its world and not in the world of a player without them, so
        // the two games make other entities, then the vehicles' and the lines' ids, the vehicles and the towns go apart (the
        // reports of AMD and keviK, 2026-11-02: keviK with both packs, AMD with none, 7 reloads). The lobby says so.

        /// <summary>The DLCs installed with the game on this PC (the folders of the game's "dlcs" with a mod.json), sorted, comma
        /// separated; "none" when there is none, "" when the game's folder is not found. MPFEVER_DLCS: a list given instead (tests).</summary>
        public static string InstalledDlcs()
        {
            var forced = Environment.GetEnvironmentVariable("MPFEVER_DLCS");
            if (forced != null) return forced.Trim() == "" ? "none" : string.Join(",", forced.Split(',').Select(x => x.Trim()).Where(x => x != "").OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
            try
            {
                var g = GameInstall.FindGameDir();
                if (g == null) return "";
                var d = Path.Combine(g, "dlcs");
                if (!Directory.Exists(d)) return "none";
                var ids = Directory.GetDirectories(d).Where(x => File.Exists(Path.Combine(x, "mod.json"))).Select(x => Path.GetFileName(x))
                    .OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
                return ids.Count == 0 ? "none" : string.Join(",", ids);
            }
            catch { return ""; }
        }

        /// <summary>(0.7.0) The DLCs a game uses: those of its savegame's mods (a "described" list, see Describe: the entries whose
        /// source is "DLC"; the host can switch one off in the savegame's mods when it loads it), "none" when it uses none; null
        /// when the savegame's mods are not known (the host's installed DLCs are said then, see SessionDlcs in MainForm).</summary>
        public static string SaveDlcs(string described, bool known)
        {
            if (!known) return null;
            var ids = Parse(described).Where(e => e.Source.Equals("DLC", StringComparison.OrdinalIgnoreCase)).Select(e => e.Id)
                .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            return ids.Count == 0 ? "none" : string.Join(",", ids);
        }

        /// <summary>A DLC's name for the players.</summary>
        public static string DlcName(string id)
        {
            if (id.IndexOf("deluxe", StringComparison.OrdinalIgnoreCase) >= 0) return T("pack Deluxe", "Deluxe pack");
            if (id.IndexOf("preorder", StringComparison.OrdinalIgnoreCase) >= 0) return T("bonus de précommande", "pre-order pack");
            return id;
        }

        /// <summary>(0.7.0) Where a player gets a DLC: the Steam store page of the Deluxe upgrade (app 3979620), else the game's
        /// own page (3493540: the pre-order pack is not sold on its own; the page lists what is).</summary>
        public static string DlcStoreUrl(string id) =>
            (id ?? "").IndexOf("deluxe", StringComparison.OrdinalIgnoreCase) >= 0 ? "steam://store/3979620" : "steam://store/3493540";

        /// <summary>(0.7.0) What the host and the players can do when their DLCs differ (the user's choice, 2026-11-05: no second
        /// press of « Start the game » any more, the advice instead).</summary>
        public static string DlcAdvice() => T(
            " Pour l'éviter, l'hôte peut désactiver ces DLC dans les mods de la sauvegarde (au chargement de la partie), ou les joueurs peuvent acquérir les DLC qui leur manquent. La partie peut tout de même être lancée, mais des désynchronisations peuvent se produire.",
            " To avoid it, the host can switch these DLCs off in the savegame's mods (when loading the game), or the players can get the DLCs they lack. The game can still be started, but desynchronisations may happen.");

        /// <summary>What differs between two DLC lists (InstalledDlcs): the names of those only in the first, those only in the
        /// second. Nothing when either list is unknown ("": an older MPFever, or no game folder).</summary>
        public static (List<string> OnlyA, List<string> OnlyB) DlcDiff(string a, string b)
        {
            var none = (new List<string>(), new List<string>());
            if (string.IsNullOrEmpty(a) || string.IsNullOrEmpty(b)) return none;
            List<string> Of(string s) => s == "none" ? new List<string>() : s.Split(',').Select(x => x.Trim()).Where(x => x != "").ToList();
            var la = Of(a); var lb = Of(b);
            return (la.Where(x => !lb.Contains(x, StringComparer.OrdinalIgnoreCase)).Select(DlcName).ToList(),
                    lb.Where(x => !la.Contains(x, StringComparer.OrdinalIgnoreCase)).Select(DlcName).ToList());
        }

        /// <summary>The warning for a player whose DLCs are not the host's (DlcDiff of the host's list and the player's), "" when
        /// they are the same.</summary>
        public static string DlcWarning(string player, string hostList, string playerList)
        {
            var (hostOnly, playerOnly) = DlcDiff(hostList, playerList);
            if (hostOnly.Count == 0 && playerOnly.Count == 0) return "";
            var parts = new List<string>();
            if (playerOnly.Count > 0) parts.Add(F("{0} a {1}, pas la partie de l'hôte", "{0} has the {1}, the host's game does not", player, string.Join(", ", playerOnly)));
            if (hostOnly.Count > 0) parts.Add(F("la partie de l'hôte utilise {1}, {0} ne l'a pas", "the host's game uses the {1}, {0} does not have it", player, string.Join(", ", hostOnly)));
            return string.Join(T(" ; ", "; "), parts);
        }

        /// <summary>(0.7.0) The DLCs of a host's game and of this PC for the menu's list, "id|name|state|store;..." in the host's
        /// order then this PC's: state "both" (alike), "host" (the host's game uses it, this PC lacks it: to get, the store page) or
        /// "mine" (this PC has it, the host's game does not). "" when either list is unknown or neither has any.</summary>
        public static string DlcListView(string hostList, string mine)
        {
            if (string.IsNullOrEmpty(hostList) || string.IsNullOrEmpty(mine)) return "";
            List<string> Of(string s) => s == "none" ? new List<string>() : s.Split(',').Select(x => x.Trim()).Where(x => x != "").ToList();
            var h = Of(hostList); var m = Of(mine);
            var rows = new List<string>();
            foreach (var id in h.Concat(m.Where(x => !h.Contains(x, StringComparer.OrdinalIgnoreCase))))
            {
                bool inH = h.Contains(id, StringComparer.OrdinalIgnoreCase), inM = m.Contains(id, StringComparer.OrdinalIgnoreCase);
                rows.Add(string.Join("|", Clean(id), Clean(DlcName(id)), inH && inM ? "both" : inH ? "host" : "mine", DlcStoreUrl(id)));
            }
            return string.Join(";", rows);
        }

        /// <summary>(0.7.0) The whole warning from the differences of each player (DlcWarning), the advice once: "" when none.</summary>
        public static string DlcWarningText(IEnumerable<string> differences)
        {
            var d = (differences ?? Enumerable.Empty<string>()).Where(x => !string.IsNullOrEmpty(x)).ToList();
            if (d.Count == 0) return "";
            return T("DLC différents : ", "Different DLCs: ") + string.Join(T(" ; ", "; "), d) + T(". Des désynchronisations sont possibles.", ". Desynchronisations may happen.") + DlcAdvice();
        }

        public static Verdict Judge(string id, string kind)
        {
            if (id != null && Known.TryGetValue(id, out var k)) return k();
            var c = id != null ? Checked(id) : null;
            if (c != null) return c;
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

        /// <summary>(0.7.6, MODIOROOT) The folders mod.io keeps this game's Mod Hub mods in, in the order the game's mod.io SDK
        /// takes them: a user's settings (%LOCALAPPDATA%\mod.io\10640\&lt;user&gt;\user.json), then mod.io's own
        /// (%LOCALAPPDATA%\mod.io\globalsettings.json), each when its "RootLocalStoragePath" names an absolute folder, then the
        /// default (%PUBLIC%\mod.io). mod.io's support tells players to move their mods to another drive that way; MPFever looked
        /// in the default folder only, so the mods of such a player were "not installed" (as TPF3-MP found, 1.5.0). Only that
        /// key is read (a user.json also holds the user's mod.io login). old (MPFEVER_MODIOROOT=0): the default only, as before.</summary>
        internal static List<string> ModioStorages(string localAppData, string pub, bool old)
        {
            var r = new List<string>();
            void Add(string p) { if (p != null && !r.Any(x => string.Equals(x.TrimEnd('\\', '/'), p.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))) r.Add(p); }
            if (!old && !string.IsNullOrEmpty(localAppData))
            {
                try
                {
                    var users = Path.Combine(localAppData, "mod.io", "10640");
                    if (Directory.Exists(users))
                        foreach (var u in Directory.GetDirectories(users).Select(d => Path.Combine(d, "user.json")).Where(File.Exists).OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                            Add(ModioStoragePath(u));
                }
                catch { }
                Add(ModioStoragePath(Path.Combine(localAppData, "mod.io", "globalsettings.json")));
            }
            Add(Path.Combine(pub ?? @"C:\Users\Public", "mod.io"));
            return r;
        }

        static readonly Regex StorageRx = new Regex("\"RootLocalStoragePath\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

        /// <summary>(0.7.6) The absolute folder a mod.io settings file names in "RootLocalStoragePath", or null (no file, no key,
        /// an empty or relative one: it moves nothing).</summary>
        internal static string ModioStoragePath(string file)
        {
            try
            {
                if (!File.Exists(file)) return null;
                var m = StorageRx.Match(File.ReadAllText(file));
                if (!m.Success) return null;
                var v = Regex.Replace(m.Groups[1].Value, @"\\(.)", x => x.Groups[1].Value == "n" ? "\n" : x.Groups[1].Value == "t" ? "\t" : x.Groups[1].Value).Trim();
                if (v == "" || !Path.IsPathRooted(v) || v.StartsWith("\\") && !v.StartsWith("\\\\")) return null;
                return v;
            }
            catch { return null; }
        }

        static Dictionary<string, string> Scan()
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var roots = new List<string>();
            try
            {
                var pub = Environment.GetEnvironmentVariable("PUBLIC") ?? @"C:\Users\Public";
                var lad = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                foreach (var modio in ModioStorages(lad, pub, Environment.GetEnvironmentVariable("MPFEVER_MODIOROOT") == "0"))
                    try { if (Directory.Exists(modio)) foreach (var g in Directory.GetDirectories(modio)) roots.Add(Path.Combine(g, "mods")); } catch { }
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
