using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The rules of a session that the host's PC decides (the lobby's start money, bankruptcy, sharing, auction, the computer
    /// companies, the session's game options, the autosave interval). The host sends them to every player ("hoststate", only when it hosts
    /// through a relay: nothing changes for the others), each launcher keeps the last it got, and the player who takes over as the host
    /// (host migration, docs/RELAY.md) goes on with them instead of its own settings: else the rules of the session changed under the
    /// players' feet at the change of host (a company that had six months before bankruptcy had twelve).</summary>
    sealed class HostRules
    {
        public string Money, Bankrupt, Share, Auction, Ai, Opts, PublicName;
        /// <summary>The players the host had let in, and the names it had banned (names only: no address, no Steam id).</summary>
        public List<string> Members = new List<string>(), Banned = new List<string>();
        public int AutosaveMinutes = -1;

        /// <summary>The "hoststate" message payload (a Lua table of text, as the other messages).</summary>
        public static string Payload(string money, string bankrupt, string share, string auction, string ai, string opts, int autosaveMinutes,
            string publicName = "", IEnumerable<string> members = null, IEnumerable<string> banned = null)
            => "{[\"v\"]=1,[\"money\"]=" + LuaLit.Quote(money ?? "") + ",[\"bankrupt\"]=" + LuaLit.Quote(bankrupt ?? "") + ",[\"share\"]=" + LuaLit.Quote(share ?? "")
               + ",[\"auction\"]=" + LuaLit.Quote(auction ?? "") + ",[\"ai\"]=" + LuaLit.Quote(ai ?? "") + ",[\"opts\"]=" + LuaLit.Quote(opts ?? "")
               + ",[\"auto\"]=" + autosaveMinutes.ToString(CultureInfo.InvariantCulture)
               + ",[\"pubname\"]=" + LuaLit.Quote(publicName ?? "") + ",[\"members\"]=" + LuaLit.Quote(Join(members)) + ",[\"banned\"]=" + LuaLit.Quote(Join(banned)) + "}";

        // (names in one text, a tab between them: a name has none)
        static string Join(IEnumerable<string> names) => names == null ? "" : string.Join("\t", names.Where(n => !string.IsNullOrEmpty(n) && n.IndexOf('\t') < 0));

        static List<string> Split(string s)
        {
            var list = new List<string>();
            if (string.IsNullOrEmpty(s) || s.Length > 8000) return list;
            foreach (var n in s.Split('\t'))
            {
                var t = n.Trim();
                if (t != "" && t.Length <= 64 && !t.Any(char.IsControl) && list.Count < 200 && !list.Contains(t, StringComparer.OrdinalIgnoreCase)) list.Add(t);
            }
            return list;
        }

        /// <summary>The rules a payload holds, each checked as the host's own settings are (an invalid value is left out: this player's
        /// own is used); null when it is not a payload of this version.</summary>
        public static HostRules Parse(string payload)
        {
            if (!(LuaLit.Parse(payload) is Dictionary<object, object> d)) return null;
            if (!d.TryGetValue("v", out var v) || !(v is double dv) || dv != 1) return null;
            string S(string k) => d.TryGetValue(k, out var x) && x is string s ? s : null;
            var r = new HostRules();
            string money = S("money"); if (long.TryParse(money ?? "", NumberStyles.None, CultureInfo.InvariantCulture, out long m) && m >= 0 && m <= 100000000000L) r.Money = m.ToString(CultureInfo.InvariantCulture);
            string bankrupt = S("bankrupt"); if (bankrupt == "0" || bankrupt == "3" || bankrupt == "6" || bankrupt == "12" || bankrupt == "24") r.Bankrupt = bankrupt;
            string share = S("share"); if (share == "0" || share == "1") r.Share = share;
            string auction = S("auction"); if (MainForm.ValidAuction(auction)) r.Auction = auction;
            // (the computer companies, "n:colour[:level[:money]],...": digits, colons and commas only)
            string ai = S("ai"); if (ai != null && ai.Length <= 2000 && ai.All(c => (c >= '0' && c <= '9') || c == ':' || c == ',')) r.Ai = ai;
            string opts = S("opts"); if (opts != null && opts.Length <= 4000) r.Opts = GameOpts.Canon(opts);
            if (d.TryGetValue("auto", out var a) && a is double ad && ad >= 0 && ad <= 1440) r.AutosaveMinutes = (int)ad;
            // (the public game's name, as the lobby limits it: 40 characters, none a control one)
            string pn = S("pubname"); if (pn != null && pn.Length <= 40 && !pn.Any(char.IsControl)) r.PublicName = pn.Trim();
            r.Members = Split(S("members"));
            r.Banned = Split(S("banned")).Select(n => new string(n.Where(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '-' || ch == '.' || ch == ':').ToArray())).Where(n => n != "").ToList();
            return r;
        }
    }

    sealed partial class MainForm
    {
        /// <summary>(a player) the rules the host last sent, and (the player who took over) the ones it goes on with: null until then, and
        /// again when the session ends.</summary>
        HostRules lastHostRules, inherited;
        /// <summary>The host's autosave interval a player who took over goes on with (-1: its own, as always).</summary>
        static volatile int inheritedAutosave = -1;
        /// <summary>(a player) the chat the host sent, to give the new players when this one takes over (the host keeps 50 of it too).</summary>
        readonly List<Msg> chatKept = new List<Msg>();

        /// <summary>(the host) its rules to every player, when it hosts through a relay (the only place where the host can change).</summary>
        void SendHostRules()
        {
            if (server != null || !(relay is RemoteRelay)) return;
            try
            {
                int auto = HostAutosaveMinutes(autotest);
                // (the public game's own name, the players it let in and the names it banned: only when it hosts a player's game with those
                // options, PublicGames.cs; nothing otherwise)
                string pub = LoadSettings().TryGetValue("pubname", out var pn) ? pn.Trim() : "";
                List<string> members = new List<string>(), banned = new List<string>();
                if (PublicHosting())
                {
                    members = relay.Admitted().Select(p => BaseName(p.Name)).Where(n => n != "").ToList();
                    if (Gate.On("join_bans")) banned = Gate.Bans().Select(b => b.Name).Where(n => n != "").ToList();
                }
                relay.Broadcast(Msg.Make("hoststate", hostName ?? "Host", HostRules.Payload(StartMoney(), BankruptMonths(), ShareRules(), AuctionRule(), AiPayload(), GameOptions(), auto, pub, members, banned)));
            }
            catch (Exception e) { Log.W("hoststate: " + e.Message); }
        }

        /// <summary>(a player) the host's rules arrived: kept for a change of host.</summary>
        void NoteHostRules(Msg m)
        {
            var r = HostRules.Parse(m.Payload);
            if (r != null) lastHostRules = r;
        }

        /// <summary>(a player) a chat message the host sent: kept (the last 50) for a change of host.</summary>
        void KeepChat(Msg m)
        {
            lock (chatKept) { chatKept.Add(m); if (chatKept.Count > 50) chatKept.RemoveAt(0); }
        }

        /// <summary>(the player who takes over as the host) goes on with the host's rules and its chat.</summary>
        void InheritFromHost()
        {
            inherited = lastHostRules;
            inheritedAutosave = inherited != null ? inherited.AutosaveMinutes : -1;
            lock (chatLog)
            {
                chatLog.Clear();
                lock (chatKept)
                {
                    chatLog.AddRange(chatKept);
                    // (the numbers go on where the host's stopped: a player skips the messages it has seen by their number)
                    foreach (var c in chatKept)
                        if (LuaLit.Parse(c.Payload) is Dictionary<object, object> d && d.TryGetValue("id", out var iv) && iv is double id && (long)id > chatId) chatId = (long)id;
                }
            }
            if (inherited != null)
            {
                // (the game's name, the players already let in, the names banned: the public games' gate, PublicGames.cs)
                if (!string.IsNullOrEmpty(inherited.PublicName)) pubName = inherited.PublicName;
                if (!PublicOff) Gate.InheritFromHost(inherited.Members, inherited.Banned);
            }
            if (inherited != null)
                Log.W("host change, the rules kept: start money " + inherited.Money + ", bankruptcy " + inherited.Bankrupt + ", sharing " + inherited.Share
                    + ", auction " + inherited.Auction + ", computer companies [" + inherited.Ai + "], options [" + inherited.Opts + "], autosave " + inherited.AutosaveMinutes + " min, chat "
                    + chatLog.Count + " messages, " + inherited.Members.Count + " players let in, " + inherited.Banned.Count + " banned names");
            Log.Ok(T("Changement d'hôte : les règles de la partie, les options, les compagnies d'ordinateur et le chat sont conservés.",
                     "Host change: the session's rules, options, computer companies and chat are kept."));
        }

        void ForgetHostRules()
        {
            inherited = lastHostRules = null;
            inheritedAutosave = -1;
            pubGate?.ForgetInherited();
            lock (chatKept) chatKept.Clear();
        }

        /// <summary>(a player) may this PC be asked to take over as the host? "takeover=0" in mpfever_settings.txt (the settings window's box)
        /// says no: a slow PC, a weak connection.</summary>
        static bool TakeoverAllowed() => TakeoverAllowedValue(LoadSettings().TryGetValue("takeover", out var v) ? v : null);
        internal static bool TakeoverAllowedValue(string setting) => !(setting != null && setting.Trim() == "0");
    }
}
