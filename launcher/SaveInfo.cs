using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace MPFever
{
    // What a savegame says about MPFever's companies, read from the decompressed savegame without loading it.
    //
    // The game keeps the mod's state (its companies' registry among it, see mpfever_co.lua) as serialized Lua tables: each value starts
    // with its type (int32): a string 3, its length (int32) and its bytes; a number 2 and a double; a table 4 and its entries; a table's keys come in
    // alphabetical order. A company is { ..., color = <palette index>, ent, [gone], id = n, key = "<player>", members, name, ... }:
    // its "key" entry comes right after its "id" one, which tells it from a member's { key, sid } (key first).
    static class SaveInfo
    {
        public sealed class Company
        {
            public int Number;     // n of the key "ai:<n>"
            public string Name = "";
            public int Color;      // palette index (1-12), 0 when unknown
        }

        static readonly byte[] KeyEntry = { 3, 0, 0, 0, 3, 0, 0, 0, (byte)'k', (byte)'e', (byte)'y', 3, 0, 0, 0 };
        static readonly byte[] IdEntry = { 3, 0, 0, 0, 2, 0, 0, 0, (byte)'i', (byte)'d', 2, 0, 0, 0 };
        static readonly byte[] ColorEntry = { 3, 0, 0, 0, 5, 0, 0, 0, (byte)'c', (byte)'o', (byte)'l', (byte)'o', (byte)'r', 2, 0, 0, 0 };
        static readonly byte[] GoneEntry = { 3, 0, 0, 0, 4, 0, 0, 0, (byte)'g', (byte)'o', (byte)'n', (byte)'e' };
        static readonly byte[] NameEntry = { 3, 0, 0, 0, 4, 0, 0, 0, (byte)'n', (byte)'a', (byte)'m', (byte)'e', 3, 0, 0, 0 };

        /// <summary>The computer companies of a savegame (keys "ai:n", not gone), by number; empty when none or unreadable.</summary>
        public static List<Company> AiCompanies(string savePath)
        {
            byte[] d;
            try { d = Zstd.DecompressFile(savePath); }
            catch (Exception e) { Log.W("savegame companies: " + e.Message); return new List<Company>(); }
            return AiCompaniesOf(d);
        }

        /// <summary>(0.6) What a lobby reads of its savegame, from one decompression (a big savegame takes seconds): its computer
        /// companies (only when asked: one company per player), its game's rules and its game options (see AiCompanies, Rules,
        /// Opts); null when the savegame cannot be read.</summary>
        public sealed class Marks
        {
            public List<Company> Ai;
            public Dictionary<string, string> Rules;
            public string Opts;
            public bool Separate;   // (0.6.8) played with one company per player (see SeparateOf)
        }

        public static Marks Read(string savePath, bool ai)
        {
            byte[] d;
            try { d = Zstd.DecompressFile(savePath); }
            catch (Exception e) { Log.W("savegame: " + e.Message); return null; }
            return new Marks { Ai = ai ? AiCompaniesOf(d) : null, Rules = RulesOf(d), Opts = OptsOf(d), Separate = SeparateOf(d) };
        }

        static List<Company> AiCompaniesOf(byte[] d)
        {
            var found = new SortedDictionary<int, Company>();
            for (int i = IndexOf(d, KeyEntry, 0); i >= 0; i = IndexOf(d, KeyEntry, i + 1))
            {
                int v = i + KeyEntry.Length;
                if (v + 4 > d.Length) break;
                int len = BitConverter.ToInt32(d, v);
                if (len < 4 || len > 12 || v + 4 + len > d.Length) continue;
                string key = Encoding.ASCII.GetString(d, v + 4, len);
                if (!key.StartsWith("ai:", StringComparison.Ordinal) || !int.TryParse(key.Substring(3), out int n) || n < 1 || n > 32) continue;
                // (a company's own key: its "id" entry right before)
                int idAt = i - IdEntry.Length - 8;
                if (idAt < 0 || !Same(d, idAt, IdEntry)) continue;
                if (found.ContainsKey(n)) continue;
                var c = new Company { Number = n };
                // its colour and whether it is gone: in the entries before (chief, color, ent, gone, id)
                int from = Math.Max(0, i - 200);
                int col = LastIndexOf(d, ColorEntry, from, i);
                if (col >= 0 && col + ColorEntry.Length + 8 <= d.Length)
                {
                    double x = BitConverter.ToDouble(d, col + ColorEntry.Length);
                    if (x >= 1 && x <= 12 && x == Math.Floor(x)) c.Color = (int)x;
                }
                if (LastIndexOf(d, GoneEntry, col >= 0 ? col : from, i) >= 0) continue;
                // its name: after its members
                int nm = IndexOf(d, NameEntry, v, Math.Min(d.Length, v + 4000));
                if (nm >= 0)
                {
                    int nv = nm + NameEntry.Length;
                    int nl = nv + 4 <= d.Length ? BitConverter.ToInt32(d, nv) : -1;
                    if (nl >= 0 && nl <= 200 && nv + 4 + nl <= d.Length) c.Name = Encoding.UTF8.GetString(d, nv + 4, nl);
                }
                found[n] = c;
            }
            return new List<Company>(found.Values);
        }

        // the registry's mode = "separate" entry (mpfever_co.lua: reg = { ..., mode = "separate", ... })
        static readonly byte[] SeparateEntry = { 3, 0, 0, 0, 4, 0, 0, 0, (byte)'m', (byte)'o', (byte)'d', (byte)'e', 3, 0, 0, 0, 8, 0, 0, 0,
            (byte)'s', (byte)'e', (byte)'p', (byte)'a', (byte)'r', (byte)'a', (byte)'t', (byte)'e' };

        /// <summary>(0.6.8, #115) Whether a decompressed savegame was played with one company per player: its companies'
        /// registry is in it. Hosted with one company for everybody, the other players' companies are not used (a player
        /// found "my company is gone" and its buildings locked, 50 minutes to find out why).</summary>
        public static bool SeparateOf(byte[] d) => d != null && IndexOf(d, SeparateEntry, 0) >= 0;

        static readonly byte[] RulesMark = Encoding.ASCII.GetBytes("mpfrules:");

        /// <summary>The game's rules of a savegame of one company per player (0.5.14): the text "mpfrules:k=v;k=v;..." the game
        /// keeps (mpfever_eco.lua's co_rules), as keys and values (bankrupt, share, start); null when it has none.</summary>
        public static Dictionary<string, string> Rules(string savePath)
        {
            byte[] d;
            try { d = Zstd.DecompressFile(savePath); }
            catch (Exception e) { Log.W("savegame rules: " + e.Message); return null; }
            return RulesOf(d);
        }

        static Dictionary<string, string> RulesOf(byte[] d)
        {
            int i = IndexOf(d, RulesMark, 0);
            if (i < 0) return null;
            // (the text is a Lua string of the game's state: its length right before it)
            int len = i >= 4 ? BitConverter.ToInt32(d, i - 4) : -1;
            if (len < RulesMark.Length || len > 400 || i + len > d.Length) return null;
            var r = new Dictionary<string, string>();
            foreach (var kv in Encoding.ASCII.GetString(d, i + RulesMark.Length, len - RulesMark.Length).Split(';'))
            {
                int eq = kv.IndexOf('=');
                if (eq > 0) r[kv.Substring(0, eq)] = kv.Substring(eq + 1);
            }
            return r.Count > 0 ? r : null;
        }

        static readonly byte[] OptsMark = Encoding.ASCII.GetBytes("mpfopts:");

        /// <summary>The game options of a savegame (0.6): the text "mpfopts:&lt;options&gt;;" its game keeps (mpfever_feat.lua's applyOpts),
        /// the options string itself ("" when they were all switched off); null when it has none (no option was ever on).</summary>
        public static string Opts(string savePath)
        {
            byte[] d;
            try { d = Zstd.DecompressFile(savePath); }
            catch (Exception e) { Log.W("savegame options: " + e.Message); return null; }
            return OptsOf(d);
        }

        /// <summary>The game options of a decompressed savegame (see Opts).</summary>
        public static string OptsOf(byte[] d)
        {
            int i = IndexOf(d, OptsMark, 0);
            if (i < 0) return null;
            // (a Lua string of the game's state: its length right before it, the text ends with ';')
            int len = i >= 4 ? BitConverter.ToInt32(d, i - 4) : -1;
            if (len < OptsMark.Length + 1 || len > GameOpts.MaxText + OptsMark.Length + 1 || i + len > d.Length || d[i + len - 1] != (byte)';') return null;
            return Encoding.ASCII.GetString(d, i + OptsMark.Length, len - OptsMark.Length - 1);
        }

        /// <summary>(0.7.0) A mod a savegame lists (the game's GameSaveCommandData modDescs, near the start of the decompressed file):
        /// its id, origin ("DLC", "UserMods", "mod.io", ...), its Mod Hub number (a mod.io mod's; "" else) and its name.</summary>
        public sealed class SaveMod
        {
            public string Id = "", Source = "", Hub = "", Name = "";
        }

        /// <summary>(0.7.0) The mods a savegame lists, read from its first MB only (a dedicated server's world, the server window's
        /// list of savegames); null when the list is not found. Seen in build 40425's savegames (and documented by TPF3-MP for 40408):
        /// a count (uint32), then per mod five strings (uint32 length, UTF-8: id, source, hub id "source,id" or a mod.io number,
        /// name, url) and an int32 severity of 0 to 2. The list is the first place of the first 64 KiB where a whole list holds.</summary>
        public static List<SaveMod> Mods(string savePath)
        {
            byte[] d;
            try { d = Zstd.DecompressHead(savePath, 1 << 20); }
            catch (Exception e) { Log.W("savegame mods: " + e.Message); return null; }
            return ModsOf(d);
        }

        public static List<SaveMod> ModsOf(byte[] d)
        {
            if (d == null) return null;
            for (int off = 0; off + 4 <= Math.Min(d.Length, 65536); off++)
            {
                uint count = BitConverter.ToUInt32(d, off);
                if (count < 1 || count > 4096) continue;
                var list = new List<SaveMod>();
                int p = off + 4;
                bool ok = true;
                for (int i = 0; i < count && ok; i++)
                {
                    var f = new string[5];
                    for (int k = 0; k < 5 && ok; k++)
                    {
                        if (p + 4 > d.Length) { ok = false; break; }
                        uint len = BitConverter.ToUInt32(d, p);
                        if (len > 4096 || p + 4 + len > d.Length) { ok = false; break; }
                        // (the id, source and hub id strict: a wrong place rarely holds valid UTF-8 there; a name or url as it comes)
                        try { f[k] = (k < 3 ? new UTF8Encoding(false, true) : new UTF8Encoding(false, false)).GetString(d, p + 4, (int)len); }
                        catch { ok = false; break; }
                        p += 4 + (int)len;
                    }
                    if (!ok || p + 4 > d.Length) { ok = false; break; }
                    int sev = BitConverter.ToInt32(d, p);
                    p += 4;
                    bool hubOk = f[2].IndexOf(',') > 0 || (f[2].Length > 0 && f[2].All(char.IsDigit));
                    if (sev < 0 || sev > 2 || f[0].Length == 0 || f[0].Any(char.IsControl) || f[1].Any(char.IsControl) || !hubOk) { ok = false; break; }
                    list.Add(new SaveMod { Id = f[0], Source = f[1], Hub = f[2].All(char.IsDigit) ? f[2] : "", Name = f[3].Length > 0 ? f[3] : f[0] });
                }
                if (ok) return list;
            }
            return null;
        }

        /// <summary>(0.7.0) A savegame's mods as the host's menu writes them (host_mods.txt: "id|name|source|hub" entries joined by
        /// ";;", MPFever's own left out), for Mods.Describe.</summary>
        public static string MenuList(List<SaveMod> mods)
        {
            if (mods == null) return "";
            string C(string s) => System.Text.RegularExpressions.Regex.Replace(s ?? "", "[|;\\p{Cc}]", " ");
            return string.Join(";;", mods.Where(m => m.Id != "mpfever_1").Select(m => C(m.Id) + "|" + C(m.Name) + "|" + C(m.Source) + "|" + C(m.Hub)));
        }

        static bool Same(byte[] d, int at, byte[] p)
        {
            if (at < 0 || at + p.Length > d.Length) return false;
            for (int k = 0; k < p.Length; k++) if (d[at + k] != p[k]) return false;
            return true;
        }

        static int IndexOf(byte[] d, byte[] p, int start, int end = -1)
        {
            if (end < 0) end = d.Length;
            int last = end - p.Length;
            for (int i = Array.IndexOf(d, p[0], start); i >= 0 && i <= last; i = Array.IndexOf(d, p[0], i + 1))
                if (Same(d, i, p)) return i;
            return -1;
        }

        static int LastIndexOf(byte[] d, byte[] p, int start, int end)
        {
            for (int i = end - p.Length; i >= start; i--) if (d[i] == p[0] && Same(d, i, p)) return i;
            return -1;
        }
    }
}
