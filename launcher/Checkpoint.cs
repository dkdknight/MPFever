using System;
using System.IO;
using System.Linq;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The save a server keeps for the session (EXPERIMENTAL, docs/LINUX-RELAY.md "Keeping the save"): a host that uses a server
    /// with a key ("serverkey=" in mpfever_settings.txt) sends it the session's autosave; a player with the key can fetch that save when
    /// nobody hosts and host from it. Nothing happens without "server=" and "serverkey=".</summary>
    sealed partial class MainForm
    {
        internal const string ResumeSaveName = "MPFever relay save";

        static string ServerKey()
        {
            var v = Environment.GetEnvironmentVariable("MPFEVER_SERVERKEY");
            if (string.IsNullOrWhiteSpace(v)) LoadSettings().TryGetValue("serverkey", out v);
            return (v ?? "").Trim();
        }

        /// <summary>True when this launcher can keep a save on a server or fetch it (server= and serverkey= are set).</summary>
        static bool CanKeepSave() => ServerSetting(out _) != null && ServerKey() != "";

        static string ServerSayWhy(Exception e)
        {
            switch (e.Message)
            {
                case "password": return T("Mot de passe du serveur refusé (serverpw= dans mpfever_settings.txt).", "The server's password was refused (serverpw= in mpfever_settings.txt).");
                case "hosted": return T("Quelqu'un héberge déjà sur ce serveur : rejoignez-le.", "Somebody already hosts on this server: join it instead.");
                case "relay": return T("Ce serveur parle un autre protocole de relais : mettez MPFever à jour ou utilisez un serveur qui correspond.", "This server speaks another relay protocol: update MPFever or use a server that matches.");
                case "full": return T("Le serveur est plein.", "The server is full.");
                default: return e.Message;
            }
        }

        static string CheckpointWhy(string status)
        {
            switch (status)
            {
                case "denied": return T("clé refusée par le serveur (serverkey= dans mpfever_settings.txt)", "the server refused the key (serverkey= in mpfever_settings.txt)");
                case "empty": return T("le serveur ne garde aucune sauvegarde", "the server keeps no save");
                case "io": return T("le serveur n'a pas pu écrire ou lire la sauvegarde", "the server could not write or read the save");
                case "timeout": return T("pas de réponse du serveur", "no answer from the server");
                default: return T("sauvegarde refusée par le serveur", "save refused by the server") + " (" + status + ")";
            }
        }

        /// <summary>(a session autosave just succeeded) sends that save to the server, in the background. Nothing without a key.</summary>
        void KeepSaveOnServer(string saveName)
        {
            var remote = relay as RemoteRelay;
            string key = ServerKey();
            if (remote == null || key == "") return;
            new Thread(() =>
            {
                try
                {
                    var file = GameInstall.FindSave(saveName);
                    if (file == null) return;
                    var bytes = File.ReadAllBytes(file);
                    var t0 = DateTime.UtcNow;
                    string status = remote.UploadCheckpoint(key, bytes);
                    if (status == "saved") Log.Ok(F("Sauvegarde gardée par le serveur ({0:0.0} Mo, {1:0.0} s).", "Save kept by the server ({0:0.0} MB, {1:0.0} s).", bytes.Length / 1048576.0, (DateTime.UtcNow - t0).TotalSeconds));
                    else Log.Warn(F("Le serveur n'a pas gardé la sauvegarde : {0}", "The server did not keep the save: {0}", CheckpointWhy(status)));
                }
                catch (Exception e) { Log.Warn(F("Le serveur n'a pas gardé la sauvegarde : {0}", "The server did not keep the save: {0}", e.Message)); }
            }) { IsBackground = true, Name = "Keep save" }.Start();
        }

        /// <summary>"Resume the saved game": fetches the save the server keeps into the game's savegames, under ResumeSaveName. The player
        /// then hosts as usual and loads it. Refused when somebody hosts on the server already.</summary>
        void ResumeFromServer()
        {
            string name = PlayerName();
            resumeBtn.Enabled = false;
            new Thread(() =>
            {
                try { FetchSaveFromServer(name, out _); }
                catch (Exception e) { Log.Err(F("Reprise impossible : {0}", "Cannot resume: {0}", e.Message)); }
                finally { try { BeginInvoke((Action)(() => resumeBtn.Enabled = true)); } catch { } }
            }) { IsBackground = true, Name = "Resume" }.Start();
        }

        /// <summary>Connects to the server (as its host, for a moment), reads the save it keeps and writes it into the game's savegames under
        /// ResumeSaveName. Returns the file. Throws InvalidOperationException with a reason for the player.</summary>
        static string FetchSaveFromServer(string playerName, out long size)
        {
            string spec = ServerSetting(out string pw), key = ServerKey();
            if (spec == null || key == "") throw new InvalidOperationException(T("server= et serverkey= doivent être dans mpfever_settings.txt", "server= and serverkey= must be set in mpfever_settings.txt"));
            var remote = new RemoteRelay();
            try
            {
                ParseServer(spec, out string host, out int port);
                Log.W(F("Reprise : lecture de la sauvegarde gardée par {0}:{1}...", "Resume: reading the save kept by {0}:{1}...", host, port));
                try { remote.Connect(host, port, playerName, pw); }
                catch (Exception e) { throw new InvalidOperationException(ServerSayWhy(e)); }
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
                Log.Ok(F("Sauvegarde reprise du serveur : « {0} » ({1:0.0} Mo). Cliquez sur « Héberger une partie » puis chargez-la dans le jeu.",
                    "Save fetched from the server: « {0} » ({1:0.0} MB). Click \"Host a game\", then load it in the game.", ResumeSaveName, bytes.Length / 1048576.0));
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
            try { Console.WriteLine(FetchSaveFromServer(name, out _)); return 0; }
            catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
        }
    }
}
