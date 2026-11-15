using System;
using System.Collections.Generic;

// The launcher's Core.cs (shared with the Windows launcher, see MPFeverRelay.csproj) refers to a few members of classes that
// live in Windows-only files (MainForm.cs, Mods.cs). The Linux server has no game and no window: these are the minimum.
namespace MPFever
{
    static class MainForm
    {
        // keep equal to MainForm.Version in launcher/MainForm.cs (checked by tests/check_repo.py)
        public const string Version = "0.8.10";
        internal static string MemNow() => "";
    }

    static class Mods
    {
        public static readonly HashSet<string> MovedOut = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public static string InstalledDlcs() => "";
    }

    // used by GameLink (the link to a running game), which the Linux server never creates
    static class Options
    {
        public static bool Disabled => true;
        public static string ModFile() => "";
        public static string InfoFile() => "";
        public static Dictionary<string, string> NativeEnv() => new Dictionary<string, string>();
        public static Dictionary<string, string> TestDefaults() => new Dictionary<string, string>();
    }

    static class Reporter
    {
        public static int OtherGamesRunning(int exceptPid) => 0;
    }
}
