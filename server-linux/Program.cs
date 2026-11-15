using System;
using System.Globalization;
using System.Threading;

namespace MPFever.LinuxServer
{
    static class Program
    {
        static readonly string Usage = @"mpfever-relay, relay protocol " + RelayProtocol.Number + @" - MPFever session server without a game (Linux)

  mpfever-relay [--port 28090] [--password SECRET] [--max-players 8] [--name TEXT] [--migration]
                [--max-connections 64] [--grace 60] [--migration-timeout 120]
  mpfever-relay --selftest

Players join it as they join a host (Multiplayer, Join a game, this server's address). The first player in is the host: its MPFever
hosts through this server, so it needs no open port, and everybody reaches the same address. The server runs no game.
  --migration          when the host leaves, a player that can take over does, instead of the session ending
  --max-connections N  connections accepted at once, let in or not (default 64; 0: no limit)
  --grace SECONDS      how long a guest that drops is waited for (default 60; 0: not waited for)
  --migration-timeout SECONDS  how long a successor has to connect as the host before the next one is asked (default 120)
Set a password (--password) on a server that is reachable from the Internet: without one anybody may join or host.
See docs/LINUX-RELAY.md.";

        /// <summary>Why these settings cannot be used, or null.</summary>
        static string Validate(ServerOptions o)
        {
            if (o.Port < 1 || o.Port > 65535) return "--port must be between 1 and 65535";
            if (o.MaxPlayers < 1 || o.MaxPlayers > 64) return "--max-players must be between 1 and 64";
            if (o.MaxConnections < 0 || o.MaxConnections > 100000) return "--max-connections must be between 0 and 100000";
            if (o.Grace < 0 || o.Grace > 3600) return "--grace must be between 0 and 3600 seconds";
            if (o.MigrationTimeoutSeconds < 5 || o.MigrationTimeoutSeconds > 3600) return "--migration-timeout must be between 5 and 3600 seconds";
            return null;
        }

        static int Main(string[] args)
        {
            var opt = new ServerOptions();
            bool selftest = false;
            try
            {
                for (int i = 0; i < args.Length; i++)
                {
                    string a = args[i];
                    string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException(a + " needs a value");
                    switch (a)
                    {
                        case "--port": opt.Port = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--password": opt.Password = Next(); break;
                        case "--max-players": opt.MaxPlayers = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--name": opt.Name = Next(); break;
                        case "--migration": opt.Migration = true; break;
                        case "--max-connections": opt.MaxConnections = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--grace": opt.Grace = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--migration-timeout": opt.MigrationTimeoutSeconds = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--selftest": selftest = true; break;
                        case "-h": case "--help": Console.WriteLine(Usage); return 0;
                        default: throw new ArgumentException("unknown option " + a);
                    }
                }
            }
            catch (Exception e) when (e is ArgumentException || e is FormatException || e is OverflowException)
            {
                Console.Error.WriteLine(e.Message + "\n\n" + Usage);
                return 2;
            }

            string bad = Validate(opt);
            if (bad != null) { Console.Error.WriteLine(bad + "\n\n" + Usage); return 2; }

            Log.Line += l => Console.WriteLine(l);
            if (selftest) return SelfTest.Run();

            using (var relay = new Relay())
            {
                var core = new SessionCore(relay, opt);
                relay.Start(opt.Port);
                Log.Ok("Server '" + opt.Name + "' listening on TCP port " + opt.Port + (opt.Password != "" ? " (password set)" : "") + ", " + opt.MaxPlayers
                    + " players at most" + (opt.Migration ? ", host migration on" : ""));
                if (opt.MaxConnections == 0) Log.Warn("--max-connections 0: no limit on connections. Do not use it on a server reachable from the Internet.");
                if (opt.Password == "") Log.Warn("No password is set: anybody who can reach this port may join, or host. Use --password on a public server.");
                var quit = new ManualResetEvent(false);
                Console.CancelKeyPress += (s, e) => { e.Cancel = true; quit.Set(); };
                AppDomain.CurrentDomain.ProcessExit += (s, e) => quit.Set();
                quit.WaitOne();
                Log.W("Server stopped");
            }
            return 0;
        }
    }
}
