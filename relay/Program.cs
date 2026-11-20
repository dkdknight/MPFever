using System;
using System.Globalization;
using System.IO;
using System.Threading;

namespace MPFever.StandaloneRelay
{
    static class Program
    {
        static readonly string Usage = @"mpfever-relay, relay protocol " + RelayProtocol.Number + @" - MPFever relay, without a game (Linux or Windows)

  mpfever-relay [--port 28090] [--password SECRET] [--max-players 8] [--name TEXT] [--migration] [--host-key SECRET]
                [--max-connections 64] [--grace 60] [--migration-timeout 120]
  mpfever-relay --selftest

Players join it as they join a host (Multiplayer, Join a game, this relay's address). The first player in is the host: its MPFever
hosts through this relay, so it needs no open port, and everybody reaches the same address. The relay runs no game.
  --migration          EXPERIMENTAL (off by default): let a player take over when the host leaves
  --host-key SECRET    only the launcher that shows this key may host the relay (a dedicated server behind a router that lets nothing in:
                       it connects out and hosts here); players need no password then, or the --password one. Not with --migration
  --max-connections N  connections accepted at once, let in or not (default 64; 0: no limit)
  --grace SECONDS      how long a guest that drops is waited for (default 60; 0: not waited for)
  --checkpoint-dir DIR         keep the latest complete save of the session in DIR (the host sends it; it survives an empty relay)
  --checkpoint-owner-key KEY   key the host's launcher shows to store and read that save (needed with --checkpoint-dir)
  --resume-without-host KEY    EXPERIMENTAL: a player who shows KEY may read the save and host from it when nobody hosts
  --migration-timeout SECONDS  how long a successor has to connect as the host before the next one is asked (default 120)
  --listen ADDRESS             listen on that address only (the address of a VPN such as Tailscale or WireGuard, or a LAN), not on every one:
                               nothing else can reach the relay
  --password-file FILE, --checkpoint-owner-key-file FILE, --resume-without-host-file FILE, --host-key-file FILE
                               the same secrets, read from a file (a container secret, a systemd credential), not from the command line
Set a password (--password) on a relay that is reachable from the Internet: without one anybody may join or host.
The secrets can also come from the environment, so that they are not in the command line (a container's settings, `ps`):
MPFEVER_RELAY_PASSWORD, MPFEVER_RELAY_HOST_KEY, MPFEVER_RELAY_CHECKPOINT_OWNER_KEY and MPFEVER_RELAY_RESUME_WITHOUT_HOST (or the same with _FILE added: a path); an option on
the command line wins.
See docs/RELAY.md.";

        /// <summary>Why these settings cannot be used, or null.</summary>
        internal static string Validate(RelayOptions o)
        {
            if (o.Port < 1 || o.Port > 65535) return "--port must be between 1 and 65535";
            if (o.MaxPlayers < 1 || o.MaxPlayers > 64) return "--max-players must be between 1 and 64";
            if (o.MaxConnections < 0 || o.MaxConnections > 100000) return "--max-connections must be between 0 and 100000";
            if (o.Grace < 0 || o.Grace > 3600) return "--grace must be between 0 and 3600 seconds";
            if (o.MigrationTimeoutSeconds < 5 || o.MigrationTimeoutSeconds > 3600) return "--migration-timeout must be between 5 and 3600 seconds";
            if (!string.IsNullOrEmpty(o.CheckpointDirectory) && string.IsNullOrEmpty(o.CheckpointOwnerKey)) return "--checkpoint-dir needs --checkpoint-owner-key";
            if (o.ResumeWithoutHost && string.IsNullOrEmpty(o.CheckpointDirectory)) return "--resume-without-host needs --checkpoint-dir";
            // (the host key is the one thing that keeps a stranger from hosting: it is not the password every player knows, and a relay with a host key has one host for good)
            if (o.HostKey != "" && o.HostKey == o.Password) return "the host key must differ from the password: every player knows the password";
            if (o.HostKey != "" && o.Migration) return "--host-key and --migration cannot be used together: with a host key the relay's host is always the one that shows it";
            // (a key that is another key, or the password every player knows, would give the save to whoever has the other)
            if (o.CheckpointOwnerKey != "" && o.CheckpointOwnerKey == o.Password) return "the owner key must differ from the password: every player knows the password";
            if (o.ResumeWithoutHost && o.CheckpointRecoveryKey == o.Password) return "the recovery key must differ from the password: every player knows the password";
            if (o.ResumeWithoutHost && o.CheckpointRecoveryKey == o.CheckpointOwnerKey) return "the recovery key must differ from the owner key";
            return null;
        }

        /// <summary>The secrets given by the environment (an option on the command line, read after, wins).</summary>
        internal static void ApplyEnvironment(RelayOptions o, Func<string, string> get, Func<string, string> readFile = null)
        {
            readFile = readFile ?? File.ReadAllText;
            // (the variable itself, else the file its _FILE variable names: a container secret or a systemd credential)
            string Secret(string name)
            {
                string v = get(name);
                if (!string.IsNullOrEmpty(v)) return v;
                string path = get(name + "_FILE");
                return string.IsNullOrEmpty(path) ? null : ReadSecret(path, readFile);
            }
            string s = Secret("MPFEVER_RELAY_PASSWORD");
            if (!string.IsNullOrEmpty(s)) o.Password = s;
            s = Secret("MPFEVER_RELAY_HOST_KEY");
            if (!string.IsNullOrEmpty(s)) o.HostKey = s;
            s = Secret("MPFEVER_RELAY_CHECKPOINT_OWNER_KEY");
            if (!string.IsNullOrEmpty(s)) o.CheckpointOwnerKey = s;
            s = Secret("MPFEVER_RELAY_RESUME_WITHOUT_HOST");
            if (!string.IsNullOrEmpty(s)) { o.CheckpointRecoveryKey = s; o.ResumeWithoutHost = true; }
        }

        /// <summary>The secret in a file: its text without the line break at the end. Never says what the file holds.</summary>
        internal static string ReadSecret(string path, Func<string, string> readFile = null)
        {
            string text;
            try { text = (readFile ?? File.ReadAllText)(path); }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { throw new ArgumentException("cannot read the secret file " + path + " (" + e.GetType().Name + ")"); }
            text = text.TrimEnd('\r', '\n');
            if (text == "") throw new ArgumentException("the secret file " + path + " is empty");
            return text;
        }

        /// <summary>Secrets that are easy to guess or to copy: said at start, not refused (a private network may not need more).</summary>
        internal static string[] WeakSecrets(RelayOptions o)
        {
            var list = new System.Collections.Generic.List<string>();
            if (o.Password != "" && o.Password.Length < 8) list.Add("the password is shorter than 8 characters");
            if (o.HostKey != "" && o.HostKey.Length < 16) list.Add("the host key is shorter than 16 characters (use openssl rand -hex 16)");
            if (o.CheckpointOwnerKey != "" && o.CheckpointOwnerKey.Length < 16) list.Add("the owner key is shorter than 16 characters (use openssl rand -hex 16)");
            if (o.ResumeWithoutHost && o.CheckpointRecoveryKey.Length < 16) list.Add("the recovery key is shorter than 16 characters (use openssl rand -hex 16)");
            return list.ToArray();
        }

        static int Main(string[] args)
        {
            var opt = new RelayOptions();
            try { ApplyEnvironment(opt, Environment.GetEnvironmentVariable); }
            catch (ArgumentException e) { Console.Error.WriteLine(e.Message); return 2; }
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
                        case "--listen": opt.Listen = System.Net.IPAddress.Parse(Next()); break;
                        case "--password-file": opt.Password = ReadSecret(Next()); break;
                        case "--host-key": opt.HostKey = Next(); break;
                        case "--host-key-file": opt.HostKey = ReadSecret(Next()); break;
                        case "--max-players": opt.MaxPlayers = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--name": opt.Name = Next(); break;
                        case "--migration": opt.Migration = true; break;
                        case "--max-connections": opt.MaxConnections = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--grace": opt.Grace = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--migration-timeout": opt.MigrationTimeoutSeconds = int.Parse(Next(), CultureInfo.InvariantCulture); break;
                        case "--checkpoint-dir": opt.CheckpointDirectory = Next(); break;
                        case "--checkpoint-owner-key": opt.CheckpointOwnerKey = Next(); break;
                        case "--checkpoint-owner-key-file": opt.CheckpointOwnerKey = ReadSecret(Next()); break;
                        case "--resume-without-host": opt.CheckpointRecoveryKey = Next(); opt.ResumeWithoutHost = true; break;
                        case "--resume-without-host-file": opt.CheckpointRecoveryKey = ReadSecret(Next()); opt.ResumeWithoutHost = true; break;
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
                relay.BindTo = opt.Listen;
                relay.Start(opt.Port);
                Log.Ok("Relay '" + opt.Name + "' listening on " + (opt.Listen != null ? opt.Listen + ", " : "") + "TCP port " + opt.Port + (opt.Password != "" ? " (password set)" : "") + (opt.HostKey != "" ? " (host key set)" : "") + ", " + opt.MaxPlayers
                    + " players at most");
                if (opt.Migration) Log.Warn("EXPERIMENTAL: host migration is enabled.");
                if (opt.MaxConnections == 0) Log.Warn("--max-connections 0: no limit on connections. Do not use it on a relay reachable from the Internet.");
                if (opt.Password == "" && opt.HostKey == "") Log.Warn("No password is set: anybody who can reach this port may join, or host. Use --password on a public relay.");
                else if (opt.Password == "") Log.Ok("No password: anybody may join as a player; only the launcher that shows the host key may host.");
                foreach (var weak in WeakSecrets(opt)) Log.Warn("Weak secret: " + weak + ".");
                var quit = new ManualResetEvent(false);
                Console.CancelKeyPress += (s, e) => { e.Cancel = true; quit.Set(); };
                AppDomain.CurrentDomain.ProcessExit += (s, e) => quit.Set();
                quit.WaitOne();
                Log.W("Relay stopped");
            }
            return 0;
        }
    }
}
