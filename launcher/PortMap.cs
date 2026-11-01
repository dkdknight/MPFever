using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>Opens the host's TCP port on the router by itself, so that friends can join over the Internet without
    /// forwarding it by hand: UPnP (the router's Internet Gateway Device: AddPortMapping), else NAT-PMP (RFC 6886, routers
    /// with miniupnpd or Apple's). The mapping is removed when the session ends or MPFever closes. The router's own public
    /// address tells whether the Internet can reach this PC at all: an address of the provider's own network (CGNAT,
    /// 100.64.0.0/10) or a private one means the provider shares one public address among many customers, and no port can be
    /// opened (IPv6 or a tunnel such as Radmin or Porthole then). upnp=0 in mpfever_settings.txt turns it off.</summary>
    static class PortMap
    {
        public sealed class Result
        {
            public string Method;        // "UPnP", "NAT-PMP", or null (none worked)
            public string External;      // the router's public address, when it said
            public string Problem;       // why nobody outside can reach this PC, when known (CGNAT...)
            public string Error;
        }

        static readonly object Gate = new object();
        static Action close;             // removes the current mapping
        static int openPort;

        public static bool Enabled => !(MainForm.LoadSettings().TryGetValue("upnp", out var v) && v.Trim() == "0");

        /// <summary>Maps <paramref name="port"/> (TCP) in the background; <paramref name="done"/> gets the result.</summary>
        public static void OpenAsync(int port, Action<Result> done = null)
        {
            if (!Enabled) { Log.Dim(T("Ouverture automatique du port désactivée (upnp=0).", "Automatic port opening off (upnp=0).")); return; }
            new Thread(() =>
            {
                Result r;
                try { r = Open(port); }
                catch (Exception e) { r = new Result { Error = e.Message }; }
                Report(port, r);
                try { done?.Invoke(r); } catch { }
            }) { IsBackground = true, Name = "Port mapping" }.Start();
        }

        static void Report(int port, Result r)
        {
            if (r.Method != null)
                Log.Ok(F("Port {0} (TCP) ouvert automatiquement sur la box ({1}){2}.", "Port {0} (TCP) opened on the router by itself ({1}){2}.",
                    port, r.Method, r.External != null ? F(", adresse publique {0}", ", public address {0}", r.External) : ""));
            else
                Log.Warn(F("Le port {0} n'a pas pu être ouvert automatiquement sur la box ({1}) : redirigez-le à la main pour jouer par Internet.",
                    "Port {0} could not be opened on the router by itself ({1}): forward it by hand to play over the Internet.", port, r.Error ?? "UPnP / NAT-PMP"));
            if (r.Problem != null) Log.Warn(r.Problem);
        }

        /// <summary>The mapping made last is removed (at most 2 s).</summary>
        public static void Close()
        {
            Action c;
            lock (Gate) { c = close; close = null; }
            if (c == null) return;
            var t = new Thread(() => { try { c(); } catch { } }) { IsBackground = true };
            t.Start();
            t.Join(2000);
            Log.Dim(F("Port {0} refermé sur la box.", "Port {0} closed again on the router.", openPort));
        }

        // (0.6.7) every step in the log: the report of 2026-11-01 said only "no UPnP answer" for four different failures (no SSDP
        // answer, the description not read, no WAN service, a SOAP fault), and nobody could tell which one the host's box gave
        static void Step(string text) { Log.Dim("  " + T("ouverture du port : ", "port opening: ") + text); }

        public static Result Open(int port)
        {
            Close();
            var r = new Result();
            var why = new List<string>();
            string lan = null;
            // UPnP: every WAN connection service of every router that answered, those on a default gateway first
            try
            {
                var all = DiscoverAll(2500);
                if (all.Count == 0) why.Add(T("pas de réponse UPnP", "no UPnP answer"));
                foreach (var igd in all)
                {
                    try
                    {
                        var local = LocalAddressTowards(igd.Host);
                        lan = lan ?? local;
                        string ext = null;
                        try { ext = igd.ExternalAddress(); } catch (Exception e) { Step("UPnP " + igd.ServiceType + " GetExternalIPAddress: " + e.Message); }
                        int lease = igd.AddMapping(port, local);
                        r.External = ext;
                        r.Problem = ProblemOf(ext);
                        r.Method = "UPnP";
                        Step(F("UPnP {0} : port {1} vers {2}, bail {3}", "UPnP {0}: port {1} to {2}, lease {3}", igd.ControlUrl, port, local, lease == 0 ? T("permanent", "permanent") : lease + " s"));
                        // (a limited lease is renewed at half of it, until the session ends)
                        Timer renew = lease > 0 ? new Timer(_ => { try { igd.AddMappingLease(port, local, lease); } catch { } }, null, lease * 500, lease * 500) : null;
                        lock (Gate) { openPort = port; close = () => { renew?.Dispose(); igd.DeleteMapping(port); }; }
                        return r;
                    }
                    catch (Exception e)
                    {
                        var u = e as UpnpException;
                        Step("UPnP " + igd.ControlUrl + " (" + igd.ServiceType + "): " + e.Message);
                        why.Add("UPnP: " + e.Message + (u != null && u.Code == 606 ? T(" (la box n'autorise pas ce PC à ouvrir des ports : Fritz!Box, cochez « Autoriser les partages de ports indépendants » pour ce PC)", " (the router does not let this PC open ports: on a Fritz!Box, tick \"Permit independent port sharing\" for this PC)") : ""));
                    }
                }
            }
            catch (Exception e) { why.Add("UPnP: " + e.Message); }
            // PCP (RFC 6887, many recent boxes), then NAT-PMP (RFC 6886), on every interface's default gateway
            foreach (var gw in Gateways())
            {
                try
                {
                    lan = lan ?? LocalAddressTowards(gw.ToString());
                    var local = IPAddress.Parse(LocalAddressTowards(gw.ToString()));
                    var nonce = new byte[12]; new Random().NextBytes(nonce);
                    var pcp = Pcp.Map(gw, local, port, 7200, nonce, out var pcpExt, out int pcpLife, out string pcpWhy);
                    Step("PCP " + gw + ": " + (pcp ? F("port ouvert pour {0} s", "port opened for {0} s", pcpLife) : pcpWhy));
                    if (pcp)
                    {
                        r.Method = "PCP"; r.External = pcpExt?.ToString(); r.Problem = ProblemOf(r.External);
                        int life = Math.Max(120, pcpLife);
                        var renew = new Timer(st => { try { Pcp.Map(gw, local, port, 7200, nonce, out _, out _, out _); } catch { } }, null, life * 500, life * 500);
                        lock (Gate) { openPort = port; close = () => { renew.Dispose(); Pcp.Map(gw, local, port, 0, nonce, out _, out _, out _); }; }
                        return r;
                    }
                    why.Add("PCP " + gw + ": " + pcpWhy);
                    var ext = NatPmp.ExternalAddress(gw, out string extWhy);
                    if (ext == null) Step("NAT-PMP " + gw + " " + T("adresse publique : ", "public address: ") + extWhy);
                    // (the mapping is asked even when the public address was not given: some boxes answer only that)
                    if (NatPmp.Map(gw, port, 7200, out int life2, out string mapWhy))
                    {
                        Step("NAT-PMP " + gw + ": " + F("port ouvert pour {0} s", "port opened for {0} s", life2));
                        r.Method = "NAT-PMP"; r.External = ext?.ToString(); r.Problem = ProblemOf(r.External);
                        int life = Math.Max(120, life2);
                        var renew = new Timer(st => { try { NatPmp.Map(gw, port, 7200, out _, out _); } catch { } }, null, life * 500, life * 500);
                        lock (Gate) { openPort = port; close = () => { renew.Dispose(); NatPmp.Map(gw, port, 0, out _, out _); }; }
                        return r;
                    }
                    Step("NAT-PMP " + gw + ": " + mapWhy);
                    why.Add("NAT-PMP " + gw + ": " + mapWhy);
                }
                catch (Exception e) { why.Add(gw + ": " + e.Message); }
            }
            r.Error = string.Join(" ; ", why.Distinct()) + (lan != null ? F(". À rediriger sur la box : TCP {0} vers {1}", ". To forward on the router: TCP {0} to {1}", port, lan) : "");
            return r;
        }

        /// <summary>Why nobody outside reaches this PC when the router's public address is <paramref name="ext"/>.</summary>
        public static string ProblemOf(string ext)
        {
            if (ext == null || !IPAddress.TryParse(ext, out var ip) || ip.AddressFamily != AddressFamily.InterNetwork) return null;
            var b = ip.GetAddressBytes();
            bool cgnat = b[0] == 100 && (b[1] & 0xC0) == 64;
            bool priv = b[0] == 10 || (b[0] == 172 && (b[1] & 0xF0) == 16) || (b[0] == 192 && b[1] == 168);
            if (!cgnat && !priv) return null;
            return F("La box a l'adresse {0}, qui n'est pas une adresse publique : votre fournisseur d'accès partage une adresse entre plusieurs clients (CGNAT). Les autres joueurs ne pourront pas vous rejoindre par votre adresse IPv4 : utilisez IPv6 si vous l'avez tous les deux, un serveur dédié chez quelqu'un d'autre, ou un tunnel (Radmin VPN, Porthole...).",
                "The router's address is {0}, not a public one: your provider shares one address among several customers (CGNAT). Other players cannot join you through your IPv4 address: use IPv6 if you both have it, a dedicated server at someone else's, or a tunnel (Radmin VPN, Porthole...).", ext);
        }

        /// <summary>This PC's address on the network of <paramref name="host"/> (the one a connection to it leaves from).</summary>
        static string LocalAddressTowards(string host)
        {
            using (var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
            {
                s.Connect(host, 1900);
                return ((IPEndPoint)s.LocalEndPoint).Address.ToString();
            }
        }

        static IEnumerable<IPAddress> Gateways()
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().GatewayAddresses.Select(g => g.Address))
                .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(IPAddress.Any))
                .Distinct();
        }

        // ---------------------------------------------------------------- UPnP

        /// <summary>A router's WANIPConnection (or WANPPPConnection) service.</summary>
        public sealed class Igd
        {
            public string Host, ControlUrl, ServiceType;

            public string ExternalAddress()
            {
                var resp = Soap("GetExternalIPAddress", "");
                var m = Regex.Match(resp, "<NewExternalIPAddress>([^<]*)</NewExternalIPAddress>");
                return m.Success && m.Groups[1].Value.Trim() != "" ? m.Groups[1].Value.Trim() : null;
            }

            string Args(int port, string local, int lease) =>
                "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>"
                + "<NewInternalPort>" + port + "</NewInternalPort><NewInternalClient>" + local + "</NewInternalClient>"
                + "<NewEnabled>1</NewEnabled><NewPortMappingDescription>MPFever</NewPortMappingDescription>"
                + "<NewLeaseDuration>" + lease + "</NewLeaseDuration>";

            public void AddMappingLease(int port, string local, int lease) { Soap("AddPortMapping", Args(port, local, lease)); }

            /// <summary>Maps the port; returns the lease taken (0: permanent). (0.6.7) By the router's error code: 718 (the port
            /// is mapped already, most often MPFever's own mapping left by a crash or an older address of this PC) is removed and
            /// asked again; 725 (permanent leases only) is asked permanent; any other refusal of a permanent one, 2 hours.</summary>
            public int AddMapping(int port, string local)
            {
                // (a permanent mapping first; some routers only take a limited one: 2 hours then)
                try { Soap("AddPortMapping", Args(port, local, 0)); return 0; }
                catch (UpnpException e) when (e.Code == 718)
                {
                    try { DeleteMapping(port); } catch { }
                    try { Soap("AddPortMapping", Args(port, local, 0)); return 0; }
                    catch (UpnpException e2) when (e2.Code == 718) { throw new UpnpException(718, T("le port est déjà redirigé vers un autre appareil du réseau", "the port is already forwarded to another device of the network")); }
                    catch (WebException) { Soap("AddPortMapping", Args(port, local, 7200)); return 7200; }
                }
                catch (UpnpException e) when (e.Code == 606 || e.Code == 725) { throw; }
                catch (WebException) { Soap("AddPortMapping", Args(port, local, 7200)); return 7200; }
            }

            public void DeleteMapping(int port)
            {
                Soap("DeletePortMapping", "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>");
            }

            public string Soap(string action, string args)
            {
                var body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                    + "<s:Body><u:" + action + " xmlns:u=\"" + ServiceType + "\">" + args + "</u:" + action + "></s:Body></s:Envelope>";
                var req = (HttpWebRequest)WebRequest.Create(ControlUrl);
                // (0.6.7) never through the system's proxy (an IP literal of the local network is not "local" to it), no 100-continue
                req.Proxy = null;
                req.ServicePoint.Expect100Continue = false;
                req.Method = "POST";
                req.Timeout = req.ReadWriteTimeout = 3000;
                req.ContentType = "text/xml; charset=\"utf-8\"";
                req.Headers.Add("SOAPAction", "\"" + ServiceType + "#" + action + "\"");
                var bytes = Encoding.UTF8.GetBytes(body);
                using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
                try
                {
                    using (var resp = req.GetResponse())
                    using (var r = new StreamReader(resp.GetResponseStream())) return r.ReadToEnd();
                }
                catch (WebException e) when (e.Response != null)
                {
                    // (the router's own error code, in the SOAP fault: 718, 725, 606... instead of "(500) Internal Server Error")
                    string fault = "";
                    try { using (var r = new StreamReader(e.Response.GetResponseStream())) fault = r.ReadToEnd(); } catch { }
                    var code = Regex.Match(fault, "<errorCode>\\s*(\\d+)\\s*</errorCode>");
                    if (!code.Success) throw;
                    var desc = Regex.Match(fault, "<errorDescription>([^<]*)</errorDescription>").Groups[1].Value.Trim();
                    throw new UpnpException(int.Parse(code.Groups[1].Value), action + " " + desc);
                }
            }
        }

        /// <summary>A router's UPnP refusal, with its error code.</summary>
        public sealed class UpnpException : WebException
        {
            public readonly int Code;
            public UpnpException(int code, string text) : base(F("erreur UPnP {0} {1}", "UPnP error {0} {1}", code, text).Trim()) { Code = code; }
        }

        static readonly string[] SearchTypes = {
            "urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
            "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANPPPConnection:1", "upnp:rootdevice",
        };

        /// <summary>The first router that answers an SSDP search and describes a WAN connection service, or null.</summary>
        public static Igd DiscoverUpnp(int timeoutMs) => DiscoverAll(timeoutMs).FirstOrDefault();

        /// <summary>(0.6.7) Every WAN connection service of every device that answered an SSDP search, those of a default gateway
        /// first. The search goes out of EVERY interface (one socket each: Windows sent it out of the lowest-metric one only, a
        /// VPN's or a virtual machine's adapter for instance), twice, and the answers are taken until the end (a TV or a NAS
        /// that answered first stopped the wait before the router, which answers within MX = 2 s).
        /// MPFEVER_SSDPONE=1: one socket on any interface, as before.</summary>
        public static List<Igd> DiscoverAll(int timeoutMs)
        {
            var locations = new List<string>();
            var sockets = new List<Socket>();
            try
            {
                var addrs = new List<IPAddress>();
                if (Environment.GetEnvironmentVariable("MPFEVER_SSDPONE") != "1")
                    try
                    {
                        addrs = NetworkInterface.GetAllNetworkInterfaces()
                            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.SupportsMulticast)
                            .SelectMany(n => n.GetIPProperties().UnicastAddresses.Select(a => a.Address))
                            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)).Distinct().ToList();
                    }
                    catch { }
                if (addrs.Count == 0) addrs.Add(IPAddress.Any);
                foreach (var a in addrs)
                {
                    try
                    {
                        var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                        s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                        s.Bind(new IPEndPoint(a, 0));
                        if (!a.Equals(IPAddress.Any)) s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, a.GetAddressBytes());
                        s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 2);
                        sockets.Add(s);
                    }
                    catch (Exception e) { Step("SSDP " + a + ": " + e.Message); }
                }
                var to = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
                void Search()
                {
                    foreach (var s in sockets)
                        foreach (var st in SearchTypes)
                        {
                            var msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + st + "\r\n\r\n";
                            try { s.SendTo(Encoding.ASCII.GetBytes(msg), to); } catch { }
                        }
                }
                Search();
                bool again = false;
                var buf = new byte[4096];
                var t0 = DateTime.UtcNow;
                var until = t0.AddMilliseconds(timeoutMs);
                while (DateTime.UtcNow < until && sockets.Count > 0)
                {
                    if (!again && (DateTime.UtcNow - t0).TotalMilliseconds > 800) { again = true; Search(); }
                    var ready = sockets.ToList();
                    Socket.Select(ready, null, null, 100_000);
                    foreach (var s in ready)
                    {
                        try
                        {
                            EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                            int n = s.ReceiveFrom(buf, ref from);
                            var m = Regex.Match(Encoding.ASCII.GetString(buf, 0, n), @"^LOCATION:\s*(\S+)", RegexOptions.IgnoreCase | RegexOptions.Multiline);
                            if (m.Success && !locations.Contains(m.Groups[1].Value)) locations.Add(m.Groups[1].Value);
                        }
                        catch { }
                    }
                }
            }
            finally { foreach (var s in sockets) try { s.Close(); } catch { } }
            Step(F("SSDP sur {0} interface(s) : {1} réponse(s) {2}", "SSDP on {0} interface(s): {1} answer(s) {2}", sockets.Count, locations.Count, string.Join(" ", locations)));
            var gws = new HashSet<string>();
            try { foreach (var g in Gateways()) gws.Add(g.ToString()); } catch { }
            var found = new List<Igd>();
            foreach (var loc in locations.OrderBy(l => { try { return gws.Contains(new Uri(l).Host) ? 0 : 1; } catch { return 1; } }))
            {
                try
                {
                    var list = FromDescriptionAll(loc, Fetch(loc));
                    if (list.Count > 0) Step(loc + ": " + string.Join(", ", list.Select(i => i.ServiceType.Split(':').Reverse().Skip(1).FirstOrDefault() + " " + i.ControlUrl)));
                    found.AddRange(list);
                }
                catch (Exception e) { Step(loc + ": " + T("description non lue : ", "description not read: ") + e.Message); }
            }
            return found;
        }

        static string Fetch(string url)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Proxy = null;
            req.Timeout = req.ReadWriteTimeout = 3000;
            using (var resp = req.GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream())) return r.ReadToEnd();
        }

        /// <summary>The WAN connection service of a device description (its controlURL made absolute), or null.</summary>
        public static Igd FromDescription(string location, string xml) => FromDescriptionAll(location, xml).FirstOrDefault();

        /// <summary>(0.6.7) Every WAN connection service of a device description, in its order: a box that lists an unused
        /// WANPPPConnection before its WANIPConnection got the mapping on the dead one, and nothing else was tried.</summary>
        public static List<Igd> FromDescriptionAll(string location, string xml)
        {
            var list = new List<Igd>();
            var baseUri = new Uri(location);
            var ub = Regex.Match(xml, "<URLBase>([^<]+)</URLBase>", RegexOptions.IgnoreCase);
            if (ub.Success && Uri.TryCreate(ub.Groups[1].Value.Trim(), UriKind.Absolute, out var u)) baseUri = u;
            foreach (Match svc in Regex.Matches(xml, "<service>(.*?)</service>", RegexOptions.Singleline | RegexOptions.IgnoreCase))
            {
                var type = Regex.Match(svc.Groups[1].Value, "<serviceType>([^<]+)</serviceType>", RegexOptions.IgnoreCase).Groups[1].Value.Trim();
                if (!type.StartsWith("urn:schemas-upnp-org:service:WANIPConnection:") && !type.StartsWith("urn:schemas-upnp-org:service:WANPPPConnection:")) continue;
                var ctl = Regex.Match(svc.Groups[1].Value, "<controlURL>([^<]+)</controlURL>", RegexOptions.IgnoreCase).Groups[1].Value.Trim();
                if (ctl == "") continue;
                var abs = new Uri(baseUri, ctl);
                list.Add(new Igd { Host = abs.Host, ControlUrl = abs.ToString(), ServiceType = type });
            }
            return list;
        }

        // ---------------------------------------------------------------- NAT-PMP (RFC 6886)

        public static class NatPmp
        {
            static byte[] Ask(IPAddress gw, byte[] req, int answerLen)
            {
                using (var u = new UdpClient())
                {
                    u.Client.ReceiveTimeout = 250;
                    u.Connect(gw, 5351);
                    // (the RFC's retries: 250 ms, then 500 ms)
                    for (int i = 0; i < 2; i++)
                    {
                        u.Send(req, req.Length);
                        try
                        {
                            var from = new IPEndPoint(IPAddress.Any, 0);
                            var a = u.Receive(ref from);
                            if (a.Length >= answerLen) return a;
                        }
                        catch (SocketException) { u.Client.ReceiveTimeout = 500; }
                    }
                }
                return null;
            }

            static string Code(byte[] a) => a == null ? T("pas de réponse", "no answer") : F("code {0}", "result {0}", (a[2] << 8) | a[3])
                + (((a[2] << 8) | a[3]) == 1 ? T(" (version non prise en charge : la box parle PCP)", " (unsupported version: the router speaks PCP)") : "");

            public static IPAddress ExternalAddress(IPAddress gw) => ExternalAddress(gw, out _);

            public static IPAddress ExternalAddress(IPAddress gw, out string why)
            {
                var a = Ask(gw, new byte[] { 0, 0 }, 12);
                why = Code(a);
                if (a == null || a[1] != 128 || a[2] != 0 || a[3] != 0) return null;
                return new IPAddress(new[] { a[8], a[9], a[10], a[11] });
            }

            public static bool Map(IPAddress gw, int port, int lifetime) => Map(gw, port, lifetime, out _, out _);

            /// <summary>Maps the TCP port for <paramref name="lifetime"/> seconds (0 removes the mapping); the lifetime granted.</summary>
            public static bool Map(IPAddress gw, int port, int lifetime, out int granted, out string why)
            {
                var req = new byte[12];
                req[1] = 2;    // TCP
                req[4] = (byte)(port >> 8); req[5] = (byte)port;
                req[6] = (byte)(lifetime == 0 ? 0 : port >> 8); req[7] = (byte)(lifetime == 0 ? 0 : port);
                req[8] = (byte)(lifetime >> 24); req[9] = (byte)(lifetime >> 16); req[10] = (byte)(lifetime >> 8); req[11] = (byte)lifetime;
                var a = Ask(gw, req, 16);
                granted = a != null && a.Length >= 16 ? (a[12] << 24) | (a[13] << 16) | (a[14] << 8) | a[15] : 0;
                why = Code(a);
                if (a != null && a.Length >= 12 && a[1] == 130 && a[2] == 0 && a[3] == 0 && ((a[10] << 8) | a[11]) != port && lifetime > 0)
                    why = F("la box donne le port public {0} au lieu de {1}", "the router gives public port {0} instead of {1}", (a[10] << 8) | a[11], port);
                return a != null && a[1] == 130 && a[2] == 0 && a[3] == 0 && (lifetime == 0 || ((a[10] << 8) | a[11]) == port);
            }
        }

        // ---------------------------------------------------------------- PCP (RFC 6887)

        /// <summary>(0.6.7) PCP's MAP request, which many recent boxes answer instead of (or besides) UPnP and NAT-PMP.</summary>
        public static class Pcp
        {
            /// <summary>A MAP request for the TCP port to this PC (<paramref name="client"/>), external port = internal port.</summary>
            public static byte[] Request(IPAddress client, int port, int lifetime, byte[] nonce)
            {
                var q = new byte[60];
                q[0] = 2; q[1] = 1;   // version 2, MAP request
                q[4] = (byte)(lifetime >> 24); q[5] = (byte)(lifetime >> 16); q[6] = (byte)(lifetime >> 8); q[7] = (byte)lifetime;
                var c = client.GetAddressBytes();
                q[18] = 0xff; q[19] = 0xff; q[20] = c[0]; q[21] = c[1]; q[22] = c[2]; q[23] = c[3];   // ::ffff:a.b.c.d
                Array.Copy(nonce, 0, q, 24, 12);
                q[36] = 6;            // TCP
                q[40] = (byte)(port >> 8); q[41] = (byte)port;
                q[42] = (byte)(lifetime == 0 ? 0 : port >> 8); q[43] = (byte)(lifetime == 0 ? 0 : port);
                q[54] = 0xff; q[55] = 0xff;   // suggested external address ::ffff:0.0.0.0 (any)
                return q;
            }

            /// <summary>Reads a MAP answer to <paramref name="nonce"/>: success, the external port and address, the lifetime.</summary>
            public static bool Parse(byte[] a, byte[] nonce, out int extPort, out IPAddress ext, out int life, out string why)
            {
                extPort = 0; ext = null; life = 0;
                if (a == null) { why = T("pas de réponse", "no answer"); return false; }
                if (a.Length < 60 || a[0] != 2 || a[1] != 0x81) { why = F("réponse inattendue ({0} octets)", "unexpected answer ({0} bytes)", a.Length); return false; }
                for (int i = 0; i < 12; i++) if (a[24 + i] != nonce[i]) { why = T("réponse à une autre demande", "answer to another request"); return false; }
                life = (a[4] << 24) | (a[5] << 16) | (a[6] << 8) | a[7];
                extPort = (a[42] << 8) | a[43];
                ext = new IPAddress(new[] { a[56], a[57], a[58], a[59] });
                if (a[3] != 0) { why = F("code {0}", "result {0}", a[3]) + (a[3] == 2 ? T(" (non autorisé)", " (not authorized)") : ""); return false; }
                why = null;
                return true;
            }

            public static bool Map(IPAddress gw, IPAddress client, int port, int lifetime, byte[] nonce, out IPAddress ext, out int life, out string why)
            {
                ext = null; life = 0; why = T("pas de réponse", "no answer");
                var q = Request(client, port, lifetime, nonce);
                using (var u = new UdpClient())
                {
                    u.Connect(gw, 5351);
                    // (the RFC's retries, doubled each time)
                    foreach (int wait in new[] { 250, 500, 1000 })
                    {
                        u.Client.ReceiveTimeout = wait;
                        u.Send(q, q.Length);
                        try
                        {
                            var from = new IPEndPoint(IPAddress.Any, 0);
                            var a = u.Receive(ref from);
                            // (a NAT-PMP-only box answers a PCP request with its own "unsupported version")
                            if (a.Length >= 4 && a[0] == 0) { why = T("la box ne parle que NAT-PMP", "the router speaks NAT-PMP only"); return false; }
                            bool ok = Parse(a, nonce, out int extPort, out ext, out life, out why);
                            if (ok && lifetime > 0 && extPort != port) { why = F("la box donne le port public {0} au lieu de {1}", "the router gives public port {0} instead of {1}", extPort, port); return false; }
                            return ok;
                        }
                        catch (SocketException) { }
                    }
                }
                return false;
            }
        }
    }
}
