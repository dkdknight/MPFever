using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    /// <summary>(0.7.9, issue #136) Another copy of MPFever's mod than the one this MPFever installs.
    ///
    /// The host of #136 had once unpacked MPFever into the game's own mods folder (mods\release\MPFever\mod\mpfever_1). The game
    /// found two mods "mpfever_1" and took that one ("Multiple (2) mods with same id found mpfever_1, the one from
    /// mods/release/MPFever/mod/mpfever_1/ has been selected"), older than 0.7.5, while its MPFever was 0.7.8 and copied the 0.7.8
    /// mod into the player's mods folder at every start: the two games ran two versions of the mod, and they parted a few seconds
    /// after every resynchronisation (19 in half an hour). Now:
    ///   - before the game starts, the launcher looks for other copies in the game's mods folder (and the players' staging_area):
    ///     a copy that is not the same as this MPFever's mod is offered to be moved out, into old-mod-copies\ next to MPFever.exe
    ///     (a dedicated server moves it at once, saying so);
    ///   - the game says its mod's version in its "hello" (C.MODVERSION): the host warns everyone, in the log and the chat,
    ///     when a game's is not the host's MPFever's (a mod before 0.7.9 says none).
    /// MPFEVER_STALEMODS=0, MPFEVER_MODVERCHECK=0: neither, as before.</summary>
    static class ModCopies
    {
        /// <summary>The copies of the mod "mpfever_1" under the game's mods folder (any depth up to 5) and the players'
        /// staging_area folders that differ from `src` (this MPFever's mod: a copy identical to it is no harm).</summary>
        public static List<string> Stale(string gameDir, string src, IEnumerable<string> extraRoots = null)
        {
            var found = new List<string>();
            var roots = new List<string>();
            if (!string.IsNullOrEmpty(gameDir)) roots.Add(Path.Combine(gameDir, "mods"));
            if (extraRoots != null) roots.AddRange(extraRoots);
            foreach (var root in roots.Where(r => r != null && Directory.Exists(r)))
                Walk(root, 0, found);
            string Norm(string p) { try { return Path.GetFullPath(p).TrimEnd('\\', '/'); } catch { return p; } }
            var mine = src == null ? null : Norm(src);
            return found.Select(Norm).Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(d => !string.Equals(d, mine, StringComparison.OrdinalIgnoreCase) && !Same(d, src)).ToList();
        }

        static void Walk(string dir, int depth, List<string> found)
        {
            if (depth > 5) return;
            string[] subs;
            try { subs = Directory.GetDirectories(dir); } catch { return; }
            foreach (var d in subs)
            {
                if (string.Equals(Path.GetFileName(d), "mpfever_1", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(d, "mod.json"))) { found.Add(d); continue; }
                // (a mod's own content is not looked into: a game folder has a few hundred mods)
                if (File.Exists(Path.Combine(d, "mod.json")) || File.Exists(Path.Combine(d, "mod.lua"))) continue;
                Walk(d, depth + 1, found);
            }
        }

        /// <summary>Whether two copies of the mod have the same files (names and sizes, and the same bridge script).</summary>
        public static bool Same(string a, string b)
        {
            try
            {
                if (a == null || b == null || !Directory.Exists(a) || !Directory.Exists(b)) return false;
                Dictionary<string, long> Files(string d) => Directory.GetFiles(d, "*", SearchOption.AllDirectories)
                    .ToDictionary(f => f.Substring(d.Length).TrimStart('\\', '/').ToLowerInvariant(), f => new FileInfo(f).Length);
                var fa = Files(a); var fb = Files(b);
                if (fa.Count != fb.Count || fa.Any(kv => !fb.TryGetValue(kv.Key, out var l) || l != kv.Value)) return false;
                var bridge = Path.Combine("content", "mpfever_bridge.script.lua");
                var pa = Path.Combine(a, bridge); var pb = Path.Combine(b, bridge);
                return !File.Exists(pa) || File.ReadAllBytes(pa).SequenceEqual(File.ReadAllBytes(pb));
            }
            catch { return false; }
        }

        /// <summary>A copy moved out of the game's folders, into `into`\&lt;date&gt;\&lt;n&gt;\mpfever_1 (copied, then deleted, when
        /// it is on another disk). Returns where it went.</summary>
        public static string MoveAside(string copy, string into)
        {
            var dst = Path.Combine(into, DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture));
            for (int i = 1; ; i++) { var t = Path.Combine(dst, i.ToString(CultureInfo.InvariantCulture), "mpfever_1"); if (!Directory.Exists(t)) { dst = t; break; } }
            Directory.CreateDirectory(Path.GetDirectoryName(dst));
            try { Directory.Move(copy, dst); }
            catch (IOException)
            {
                GameInstall.CopyDir(copy, dst);
                Directory.Delete(copy, true);
            }
            try { File.WriteAllText(Path.Combine(Path.GetDirectoryName(dst), "where-it-was.txt"), copy + "\r\n"); } catch { }
            return dst;
        }

        /// <summary>The text of a game whose mod is not the host's MPFever's (null: the same). mv: the version its "hello" said
        /// (null or "": a mod before 0.7.9).</summary>
        public static string VersionProblem(string who, string mv, string mine)
        {
            if (!string.IsNullOrEmpty(mv) && mv == mine) return null;
            var what = string.IsNullOrEmpty(mv) ? T("une version d'avant la 0.7.9", "a version before 0.7.9") : mv;
            return F("Le jeu de {0} fait tourner le mod MPFever {1}, pas celui de MPFever {2} : c'est une autre copie du mod (souvent un vieux MPFever décompressé dans le dossier mods du jeu, comme mods\\release\\MPFever). Les parties vont se désynchroniser : fermez le jeu, supprimez cette copie, relancez par MPFever.",
                "{0}'s game runs MPFever's mod {1}, not the one of MPFever {2}: it is another copy of the mod (often an old MPFever unpacked into the game's mods folder, like mods\\release\\MPFever). The games will desync: close the game, delete that copy, start again through MPFever.", who, what, mine);
        }
    }

    sealed partial class MainForm
    {
        List<string> staleMods;
        readonly HashSet<string> modVersionWarned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        /// <summary>(0.7.9) InitInstall: the other copies of the mod (see ModCopies).</summary>
        void FindStaleMods()
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_STALEMODS") == "0") return;
            try
            {
                var extra = new List<string>();
                var steam = GameInstall.SteamPath();
                var userdata = steam == null ? null : Path.Combine(steam, "userdata");
                if (userdata != null && Directory.Exists(userdata))
                    foreach (var u in Directory.GetDirectories(userdata)) extra.Add(Path.Combine(u, GameInstall.AppId, "local", "staging_area"));
                staleMods = ModCopies.Stale(gameDir, GameInstall.FindModSource(), extra);
                foreach (var s in staleMods) Log.Warn(F("Autre copie du mod MPFever trouvée : {0}. Le jeu peut la prendre à la place de celle de ce MPFever.", "Another copy of MPFever's mod found: {0}. The game may take it in place of this MPFever's.", s));
            }
            catch (Exception e) { Log.W("stale mods: " + e.Message); }
        }

        /// <summary>(0.7.9) InitFinish, on the window's thread: those copies moved out, the player agreeing (a server: at once).</summary>
        void OfferStaleMods()
        {
            var list = staleMods;
            staleMods = null;
            if (list == null || list.Count == 0 || autotest) return;
            bool move = ServerMode;
            if (!move)
            {
                var text = F("Une autre copie du mod MPFever se trouve dans les dossiers du jeu :\n\n{0}\n\nLe jeu la prend à la place de celle de ce MPFever : vos parties se désynchroniseraient sans cesse (issue #136).\n\nLa déplacer hors du jeu, dans le dossier old-mod-copies de MPFever ?",
                    "Another copy of MPFever's mod is in the game's folders:\n\n{0}\n\nThe game takes it in place of this MPFever's: your games would desync again and again (issue #136).\n\nMove it out of the game, into MPFever's old-mod-copies folder?", string.Join("\n", list));
                move = MessageBox.Show(this, text, "MPFever", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;
            }
            if (!move) { Log.Warn(T("Copie du mod laissée en place : les parties risquent de se désynchroniser.", "Copy of the mod left in place: the games may desync.")); return; }
            foreach (var c in list)
                try
                {
                    var to = ModCopies.MoveAside(c, Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "old-mod-copies"));
                    Log.Ok(F("Copie du mod déplacée : {0} -> {1}", "Copy of the mod moved: {0} -> {1}", c, to));
                }
                catch (Exception e) { Log.Err(F("Copie du mod impossible à déplacer ({0}) : supprimez {1} vous-même, le jeu fermé.", "Could not move the copy of the mod ({0}): delete {1} yourself, with the game closed.", e.Message, c)); }
        }

        /// <summary>(0.7.9) The host: a game's mod version from its "hello" (see ModCopies.VersionProblem).</summary>
        /// <summary>(0.8.4, #268) A game whose native module does not run (its hello's "nat": "off" or "none"): Arne had started
        /// MPFever.exe away from its archive's folder, an old winhttp.dll stayed in the game's folder with hooks off, and the towns
        /// drifted every 3 minutes (13 resynchronisations) while his own warning went unseen. Said to everyone, once per player.
        /// A hello without "nat" (an older mod): nothing. MPFEVER_NATIVECHECK=0: not said</summary>
        internal static string NativeProblem(string who, string payload)
        {
            var h = LuaLit.Parse(payload) as Dictionary<object, object>;
            var nat = h != null && h.TryGetValue("nat", out var v) ? v as string : null;
            if (nat != "off" && nat != "none") return null;
            return F("Le module natif de MPFever ne tourne pas sur le jeu de {0} (MPFever.exe lancé hors du dossier de son archive ?) : ce jeu va dériver des autres. {0}, extrayez toute l'archive MPFever dans un dossier et lancez MPFever.exe depuis ce dossier.",
                "MPFever's native module does not run on {0}'s game (MPFever.exe started away from its archive's folder?): that game will drift away from the others. {0}, please extract the whole MPFever archive into one folder and start MPFever.exe from there.", who);
        }

        /// <summary>(0.8.16) The native fixes that change the simulation (the hello's "fx", native_fx.txt: names separated by ';'),
        /// a player's compared with the host's: the names the host's game has and that game has not, and the reverse. Null when
        /// they are the same (or one is unknown: an older mod). A game without one of them drifts from the others (the shared
        /// maintenance on one game only, an order fix of one game build only).</summary>
        internal static string NativeFxProblem(string who, string fx, string hostFx)
        {
            if (fx == null || hostFx == null) return null;
            var mine = new HashSet<string>(fx.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
            var host = new HashSet<string>(hostFx.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
            var missing = host.Where(x => !mine.Contains(x)).OrderBy(x => x, StringComparer.Ordinal).ToList();
            var extra = mine.Where(x => !host.Contains(x)).OrderBy(x => x, StringComparer.Ordinal).ToList();
            if (missing.Count == 0 && extra.Count == 0) return null;
            var parts = new List<string>();
            if (missing.Count > 0) parts.Add(F("sans {0}", "without {0}", string.Join(", ", missing)));
            if (extra.Count > 0) parts.Add(F("avec en plus {0}", "with {0} on top", string.Join(", ", extra)));
            return F("Les correctifs natifs de MPFever du jeu de {0} ne sont pas ceux de l'hôte ({1}) : ce jeu va dériver des autres. Tout le monde doit avoir la même version de MPFever et du jeu.",
                "The MPFever native fixes of {0}'s game are not the host's ({1}): that game will drift from the others. Everybody needs the same MPFever version and the same game version.", who, string.Join("; ", parts));
        }

        /// <summary>(0.8.16, #385) A game that runs an older native module than its mod (natold in its hello).</summary>
        internal static string NativeOldProblem(string who, string natver)
        {
            return F("Le jeu de {0} tourne avec un ancien module natif de MPFever ({1}) : le jeu était ouvert pendant la mise à jour, et ce jeu va dériver des autres. {0}, fermez le jeu puis relancez MPFever.",
                "{0}'s game runs an old MPFever native module ({1}): the game was open during the update, and that game will drift from the others. {0}, please close the game, then start MPFever again.",
                who, natver ?? L.T("avant la 0.8.16", "before 0.8.16"));
        }

        readonly Dictionary<string, string> nativeFx = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<string> nativeFxWarned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        /// <summary>(0.8.16) The host: every game's native fixes from its hello, compared with the host's own game's (said once per
        /// player and difference). MPFEVER_NATIVEFXCHECK=0: not compared.</summary>
        void WarnNativeFx(string who, string payload)
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_NATIVEFXCHECK") == "0") return;
            try
            {
                var h = LuaLit.Parse(payload) as Dictionary<object, object>;
                // ((0.8.16, #385) a game whose native module is older than its mod: MPFever updated while the game was open)
                if (h != null && h.TryGetValue("natold", out var old) && old is bool ob && ob)
                {
                    var t0 = NativeOldProblem(BaseName(who ?? ""), h.TryGetValue("natver", out var nv) ? nv as string : null);
                    bool first; lock (nativeFx) first = nativeFxWarned.Add("old|" + BaseName(who ?? ""));
                    if (first) { Log.Err(t0); HostChat("msg", "MPFever", t0); }
                }
                var fx = h != null && h.TryGetValue("fx", out var v) ? v as string : null;
                if (fx == null) return;
                var texts = new List<string>();
                lock (nativeFx)
                {
                    nativeFx[BaseName(who ?? "")] = fx;
                    if (!nativeFx.TryGetValue(BaseName(hostName ?? ""), out var hostFx)) return;
                    foreach (var kv in nativeFx)
                    {
                        if (string.Equals(kv.Key, BaseName(hostName ?? ""), StringComparison.OrdinalIgnoreCase)) continue;
                        var text = NativeFxProblem(kv.Key, kv.Value, hostFx);
                        if (text != null && nativeFxWarned.Add(kv.Key + "|" + kv.Value + "|" + hostFx)) texts.Add(text);
                    }
                }
                foreach (var t in texts) { Log.Err(t); HostChat("msg", "MPFever", t); }
            }
            catch { }
        }

        readonly HashSet<string> nativeWarned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void WarnNative(string who, string payload)
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_NATIVECHECK") == "0") return;
            try
            {
                var text = NativeProblem(BaseName(who ?? ""), payload);
                if (text == null) return;
                lock (nativeWarned) if (!nativeWarned.Add(BaseName(who ?? ""))) return;
                Log.Err(text);
                HostChat("msg", "MPFever", text);
            }
            catch { }
        }

        void WarnModVersion(string who, string payload)
        {
            if (Environment.GetEnvironmentVariable("MPFEVER_MODVERCHECK") == "0") return;
            try
            {
                var h = LuaLit.Parse(payload) as Dictionary<object, object>;
                if (h == null) return;
                var mv = h.TryGetValue("mv", out var v) ? v as string : null;
                var text = ModCopies.VersionProblem(BaseName(who ?? ""), mv, Version);
                if (text == null) return;
                lock (modVersionWarned) if (!modVersionWarned.Add(BaseName(who ?? "") + "|" + mv)) return;
                Log.Err(text);
                HostChat("msg", "MPFever", text);
            }
            catch { }
        }
    }
}
