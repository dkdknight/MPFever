using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace MPFever.StandaloneRelay
{
    /// <summary>
    /// (0.9.3) The relay announces its host to the public server list (--list-url), so that a dedicated server behind a router that lets nothing in appears in it. The list shows a server
    /// with the address its announce came from and looks at that address: from the relay's own (public) address it answers, which is not true of the server's. Only a relay with a host key does it
    /// (the key is what says the host is the server, not a stranger), and only what the host sent in "tun_list" (its name, world, mode, version, build, motd, number of places, password or not)
    /// goes to the list, with the relay's port and the number of players it counts itself. The relay stops when its host leaves or stops sending (every 30 s).
    /// </summary>
    sealed partial class SessionCore
    {
        readonly object listGate = new object();
        string listName = "", listVersion = "", listBuild = "", listMode = "", listWorld = "", listMotd = "", listId, listToken;
        int listMax;
        bool listPassword, listLoggedError;
        DateTime listInfoAt = DateTime.MinValue;
        Timer listTimer;

        static readonly HttpClient ListHttp = MakeListHttp();

        static HttpClient MakeListHttp()
        {
            // (over IPv4 when there is one: the list takes the address the announce came from, and the relay's port is open on it)
            var handler = new SocketsHttpHandler
            {
                ConnectTimeout = TimeSpan.FromSeconds(6),
                ConnectCallback = async (ctx, ct) =>
                {
                    var all = await Dns.GetHostAddressesAsync(ctx.DnsEndPoint.Host, ct);
                    var v4 = all.Where(a => a.AddressFamily == AddressFamily.InterNetwork).ToArray();
                    var use = v4.Length > 0 ? v4[0] : all[0];
                    var socket = new Socket(use.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                    try { await socket.ConnectAsync(new IPEndPoint(use, ctx.DnsEndPoint.Port), ct); return new NetworkStream(socket, true); }
                    catch { socket.Dispose(); throw; }
                }
            };
            var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("MPFever-relay/" + RelayProtocol.Number);
            return client;
        }

        bool ListingOn => opt.ListUrl != "" && opt.HostKey != "";

        /// <summary>The host's "tun_list": what to tell the list about it ({[ "json" ]=text}: the launcher's own announce body).</summary>
        void HandleListInfo(Msg m)
        {
            if (!ListingOn) return;
            string text = (LuaLit.Parse(m.Payload ?? "") as Dictionary<object, object>) is Dictionary<object, object> t && t.TryGetValue("json", out var jv) ? jv as string : null;
            if (string.IsNullOrEmpty(text) || text.Length > 4096) return;
            try
            {
                using (var doc = JsonDocument.Parse(text))
                {
                    var r = doc.RootElement;
                    string S(string k, int max) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "").Trim() is string s && s.Length > max ? s.Substring(0, max) : (v.GetString() ?? "").Trim() : "";
                    int max = r.TryGetProperty("max", out var mv) && mv.ValueKind == JsonValueKind.Number && mv.TryGetInt32(out int mi) ? mi : 0;
                    bool first;
                    lock (listGate)
                    {
                        listName = S("name", 40); listVersion = S("version", 20); listBuild = S("build", 20); listMode = S("mode", 12); listWorld = S("world", 60); listMotd = S("motd", 140);
                        listMax = Math.Max(0, Math.Min(max, opt.MaxPlayers));
                        listPassword = r.TryGetProperty("password", out var pv) && pv.ValueKind == JsonValueKind.True;
                        listInfoAt = DateTime.UtcNow;
                        first = listTimer == null;
                        if (first) listTimer = new Timer(_ => AnnounceNow(), null, 0, 30000);
                    }
                }
            }
            catch (JsonException) { }
        }

        /// <summary>A player came or went: the list hears of the new number soon, not at the next 30 s.</summary>
        void NudgeList()
        {
            Timer t; lock (listGate) t = listTimer;
            if (t != null) { try { t.Change(500, 30000); } catch (ObjectDisposedException) { } }
        }

        void AnnounceNow()
        {
            string body;
            lock (listGate)
            {
                if (listTimer == null) return;
                if (!HasHost || DateTime.UtcNow - listInfoAt > TimeSpan.FromSeconds(120)) { StopListingLocked(false); return; }
                using (var ms = new MemoryStream())
                {
                    using (var w = new Utf8JsonWriter(ms))
                    {
                        w.WriteStartObject();
                        w.WriteString("name", listName); w.WriteNumber("port", relay.Port); w.WriteString("version", listVersion); w.WriteString("build", listBuild);
                        w.WriteString("mode", listMode); w.WriteString("world", listWorld); w.WriteString("motd", listMotd);
                        w.WriteNumber("players", relay.Admitted().Count(p => !IsHost(p))); w.WriteNumber("max", listMax); w.WriteBoolean("password", listPassword);
                        w.WriteString("steam", ""); w.WriteString("address", ""); w.WriteString("token", listToken ?? "");
                        w.WriteEndObject();
                    }
                    body = Encoding.UTF8.GetString(ms.ToArray());
                }
            }
            Post("/api/announce", body, reply =>
            {
                using (var doc = JsonDocument.Parse(reply))
                {
                    var r = doc.RootElement;
                    if (r.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True)
                    {
                        lock (listGate)
                        {
                            if (r.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String) listId = id.GetString();
                            if (r.TryGetProperty("token", out var tk) && tk.ValueKind == JsonValueKind.String) listToken = tk.GetString();
                            if (listLoggedError) { listLoggedError = false; Log.Ok("The public list takes the announce again"); }
                        }
                        if (!listShownOnce) { listShownOnce = true; Log.Ok("The host is announced to the public list " + opt.ListUrl + " from this relay's address"); }
                    }
                    else if (r.TryGetProperty("error", out var err) && !(err.GetString() ?? "").StartsWith("too often", StringComparison.Ordinal))
                        LogListError("the list refused the announce: " + err.GetString());
                }
            });
        }

        bool listShownOnce;

        void LogListError(string what)
        {
            lock (listGate) { if (listLoggedError) return; listLoggedError = true; }
            Log.Warn("Public list: " + what);
        }

        void Post(string path, string body, Action<string> onReply)
        {
            Task.Run(async () =>
            {
                try
                {
                    using (var content = new StringContent(body, Encoding.UTF8, "application/json"))
                    using (var resp = await ListHttp.PostAsync(opt.ListUrl.TrimEnd('/') + path, content).ConfigureAwait(false))
                        onReply?.Invoke(await resp.Content.ReadAsStringAsync().ConfigureAwait(false));
                }
                catch (Exception e) when (e is HttpRequestException || e is TaskCanceledException || e is JsonException || e is IOException || e is SocketException)
                {
                    LogListError("unreachable (" + e.GetType().Name + ")");
                }
            });
        }

        /// <summary>The host left (or stopped telling): the list is told to forget the entry.</summary>
        void StopListing()
        {
            lock (listGate) StopListingLocked(true);
        }

        void StopListingLocked(bool remove)
        {
            var t = listTimer; listTimer = null;
            try { t?.Dispose(); } catch { }
            string id = listId, token = listToken;
            listId = null; listToken = null; listShownOnce = false;
            if (remove && id != null) Post("/api/remove", "{\"id\":\"" + id + "\",\"token\":\"" + (token ?? "") + "\"}", null);
        }
    }
}
