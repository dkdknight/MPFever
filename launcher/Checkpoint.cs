using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The save a relay keeps for the session (EXPERIMENTAL, docs/RELAY.md "Keeping the save"): a host that uses a relay
    /// with a key ("relaykey=" in mpfever_settings.txt) sends it the session's autosave; a player with the key can fetch that save when
    /// nobody hosts and host from it. Nothing happens without "relay=" and "relaykey=".</summary>
    sealed partial class MainForm
    {
        internal const string ResumeSaveName = "MPFever relay save";

        static string RelayKey()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_RELAYKEY");
            if (string.IsNullOrWhiteSpace(v)) v = RelayConf(LoadSettings(), "relaykey");
            return (v ?? "").Trim();
        }

        /// <summary>The relay settings of mpfever_settings.txt: relay=, relaypw= and relaykey=. The first versions of the relay wrote
        /// server=, serverpw= and serverkey=: they are still read while the new name is not set (the Relay window writes the new names and
        /// empties the old ones).</summary>
        internal static string RelayConf(Dictionary<string, string> s, string key)
        {
            if (!(s.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v))) v = s.TryGetValue(LegacyRelayKey(key), out var old) ? old : "";
            if (key == "relay") return v;
            // (the password and the key are protected by Windows in the file, SecretStore.cs; a value typed by hand is read as it is)
            var plain = SecretStore.Unprotect(v);
            if (plain == null)
            {
                if (!relaySecretWarned)
                {
                    relaySecretWarned = true;
                    Log.Warn(T("Le mot de passe ou la clé du relais enregistrés ne peuvent pas être lus sur ce PC ou avec ce compte : saisissez-les à nouveau dans la fenêtre Relais.",
                               "The relay's saved password or key cannot be read on this PC or with this account: enter it again in the Relay window."));
                }
                return "";
            }
            return plain;
        }

        static bool relaySecretWarned;

        internal static string LegacyRelayKey(string key) => key == "relay" ? "server" : key == "relaypw" ? "serverpw" : key == "relaykey" ? "serverkey" : key;

        static string RelaySayWhy(Exception e)
        {
            switch (e.Message)
            {
                case "password": return T("Mot de passe du relais refusé (relaypw= dans mpfever_settings.txt).", "The relay's password was refused (relaypw= in mpfever_settings.txt).");
                case "hosted": return T("Quelqu'un héberge déjà sur ce relais : rejoignez-le.", "Somebody already hosts on this relay: join it instead.");
                case "relay": return T("Ce relais parle un autre protocole : mettez MPFever à jour ou utilisez un relais qui correspond.", "This relay speaks another protocol: update MPFever or use a relay that matches.");
                case "full": return T("Le relais est plein.", "The relay is full.");
                default: return e.Message;
            }
        }

        static string CheckpointWhy(string status)
        {
            switch (status)
            {
                case "denied": return T("clé refusée par le relais (relaykey= dans mpfever_settings.txt)", "the relay refused the key (relaykey= in mpfever_settings.txt)");
                case "empty": return T("le relais ne garde aucune sauvegarde", "the relay keeps no save");
                case "io": return T("le relais n'a pas pu écrire ou lire la sauvegarde", "the relay could not write or read the save");
                case "timeout": return T("pas de réponse du relais", "no answer from the relay");
                default: return T("sauvegarde refusée par le relais", "save refused by the relay") + " (" + status + ")";
            }
        }

        /// <summary>(a session autosave just succeeded) sends that save to the relay, in the background. Nothing without a key.</summary>
        void KeepSaveOnRelay(string saveName)
        {
            var remote = relay as RemoteRelay;
            string key = RelayKey();
            if (remote == null || key == "") return;
            keepThread = new Thread(() =>
            {
                try
                {
                    var file = GameInstall.FindSave(saveName);
                    if (file == null) return;
                    var bytes = File.ReadAllBytes(file);
                    var t0 = DateTime.UtcNow;
                    string status = remote.UploadCheckpoint(key, bytes);
                    if (status == "saved") Log.Ok(F("Sauvegarde gardée par le relais ({0:0.0} Mo, {1:0.0} s).", "Save kept by the relay ({0:0.0} MB, {1:0.0} s).", bytes.Length / 1048576.0, (DateTime.UtcNow - t0).TotalSeconds));
                    else Log.Warn(F("Le relais n'a pas gardé la sauvegarde : {0}", "The relay did not keep the save: {0}", CheckpointWhy(status)));
                }
                catch (Exception e) { Log.Warn(F("Le relais n'a pas gardé la sauvegarde : {0}", "The relay did not keep the save: {0}", e.Message)); }
            }) { IsBackground = true, Name = "Keep save" };
            keepThread.Start();
        }

        Thread keepThread;

        /// <summary>(the launcher is closing) a host that keeps its save on a relay makes one last session autosave and sends it, so what
        /// happened since the last periodic one is kept too. It waits 40 s at most; nothing is done without a relay and a key, when
        /// nothing happened since the last save (HostAutosave skips it), nor during a resynchronisation.</summary>
        void FinalKeep()
        {
            if (!(relay is RemoteRelay) || RelayKey() == "" || !started || hostGame == null || resyncing || relay != null) return;
            var t = new Thread(() => { HostAutosave(); keepThread?.Join(); }) { IsBackground = true, Name = "Final keep" };
            t.Start();
            t.Join(40000);
        }

        /// <summary>"Resume the relay's saved game" (RelayDialog): fetches the save the relay keeps into the game's savegames, under ResumeSaveName. The player
        /// then hosts as usual and loads it. Refused when somebody hosts on the relay already.</summary>
        void ResumeFromRelay()
        {
            string name = PlayerName();
            new Thread(() =>
            {
                try { FetchSaveFromRelay(name, out _); }
                catch (Exception e) { Log.Err(F("Reprise impossible : {0}", "Cannot resume: {0}", e.Message)); }
            }) { IsBackground = true, Name = "Resume" }.Start();
        }

        /// <summary>Connects to the relay (as its host, for a moment), reads the save it keeps and writes it into the game's savegames under
        /// ResumeSaveName. Returns the file. Throws InvalidOperationException with a reason for the player.</summary>
        static string FetchSaveFromRelay(string playerName, out long size)
        {
            string spec = RelaySetting(out string pw), key = RelayKey();
            if (spec == null || key == "") throw new InvalidOperationException(T("relay= et relaykey= doivent être dans mpfever_settings.txt", "relay= and relaykey= must be set in mpfever_settings.txt"));
            var remote = new RemoteRelay();
            try
            {
                ParseRelayAddress(spec, out string host, out int port);
                Log.W(F("Reprise : lecture de la sauvegarde gardée par {0}:{1}...", "Resume: reading the save kept by {0}:{1}...", host, port));
                try { remote.Connect(host, port, playerName, pw); }
                catch (Exception e) { throw new InvalidOperationException(RelaySayWhy(e)); }
                var bytes = remote.DownloadCheckpoint(key, out string status);
                if (bytes == null) throw new InvalidOperationException(CheckpointWhy(status));
                var dir = GameInstall.SaveDirs().FirstOrDefault(Directory.Exists);
                if (dir == null) throw new InvalidOperationException(T("dossier des sauvegardes du jeu introuvable", "the game's savegame folder was not found"));
                var target = Path.Combine(dir, ResumeSaveName + ".sav");
                var temp = target + ".part";
                File.WriteAllBytes(temp, bytes);
                if (File.Exists(target)) File.Delete(target);
                File.Move(temp, target);
                size = bytes.Length;
                Log.Ok(F("Sauvegarde reprise du relais : « {0} » ({1:0.0} Mo). Cliquez sur « Héberger une partie » puis chargez-la dans le jeu.",
                    "Save fetched from the relay: « {0} » ({1:0.0} MB). Click \"Host a game\", then load it in the game.", ResumeSaveName, bytes.Length / 1048576.0));
                return target;
            }
            finally { try { remote.Dispose(); } catch { } }
        }

        /// <summary>MPFever.exe --fetch-save [name]: the same, without a window (for a script or a test). Exit code 0 when the save was written.</summary>
        internal static int FetchSaveCli(string[] args)
        {
            Log.Line += l => Console.WriteLine(l);
            int i = Array.IndexOf(args, "--fetch-save");
            string name = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[i + 1] : "Resume";
            try { Console.WriteLine(FetchSaveFromRelay(name, out _)); return 0; }
            catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
        }
    }
}
