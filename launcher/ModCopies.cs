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

        /// <summary>(0.7.10) A game's hello with this player's « Same platform order (test) » added (["order2"]=true/false).</summary>
        public static string WithOrder2(string payload, bool on)
        {
            if (string.IsNullOrEmpty(payload)) return payload;
            int end = payload.LastIndexOf('}');
            if (end < 0 || payload.Contains("[\"order2\"]")) return payload;
            var inner = payload.Substring(0, end).TrimEnd();
            return inner + (inner.EndsWith("{", StringComparison.Ordinal) ? "" : ",") + "[\"order2\"]=" + (on ? "true" : "false") + payload.Substring(end);
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
        // (0.7.10) « Same platform order (test) » (MPFEVER_ORDER2): it changes how every game simulates, so a game without it in a
        // session with it (or the other way) drifts apart. The players' games tell theirs with their hello, the host warns.
        readonly HashSet<string> order2Warned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void WarnOrder2(string who, string payload)
        {
            try
            {
                var h = LuaLit.Parse(payload) as Dictionary<object, object>;
                bool theirs = h != null && h.TryGetValue("order2", out var v) && v is bool b && b;
                bool mine = Options.Order2On();
                if (theirs == mine) return;
                lock (order2Warned) if (!order2Warned.Add(BaseName(who ?? "") + "|" + theirs)) return;
                var text = F("« Ordre des quais identique (test) » : {0} l'a {1}, l'hôte l'a {2}. Tous les joueurs doivent avoir le même réglage (réglages du launcher, puis relancer le jeu), sinon les parties se désynchronisent.",
                    "« Same platform order (test) »: {0} has it {1}, the host has it {2}. Every player needs the same setting (the launcher's settings, then start the game again), or the games desync.",
                    BaseName(who ?? ""), theirs ? T("activé", "on") : T("désactivé", "off"), mine ? T("activé", "on") : T("désactivé", "off"));
                Log.Err(text);
                HostChat("msg", "MPFever", text);
            }
            catch { }
        }

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
