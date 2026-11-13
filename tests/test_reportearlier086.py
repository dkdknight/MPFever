"""Offline test: a report holds the evening's earlier sessions too (0.8.6; Reporter.EarlierSessions / EarlierFile / Collect in
launcher/Reporter.cs).

#278 (Creeper, 2026-11-13): the game was started again for a second session; the first session's folder, where the first resync of
the evening happened, was in no report. #272: the first drift's folder was gone the same way. Now:
  - the sessions of the last hours next to the current ones (the same sessions folder), newest first, two at most, by their mod.log's
    time; the current ones never twice;
  - their logs and drift files only (no savegame), under session-earlier/<folder>/;
  - MPFEVER_REPORTEARLIER=0: the current ones only, as before; MPFEVER_REPORTEARLIER=<hours> (8 by default).
launcher/Reporter.cs is read.
Run: python tests/test_reportearlier086.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


rp = open(os.path.join(HERE, "..", "launcher", "Reporter.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
c = rp[rp.index("public static string Collect(IEnumerable<string> sessionDirs"):]
c = c[:c.index("using (var z = ZipFile.Open(zip, ZipArchiveMode.Create))")]
check("Collect adds the earlier sessions after the current ones", c.index('"session/" + Path.GetFileName(dir)') < c.index("foreach (var dir in EarlierSessions(current))"))
check("  their files filtered by EarlierFile, top folder only, under session-earlier/",
      'Directory.GetFiles(dir, "*", SearchOption.TopDirectoryOnly).Where(EarlierFile)' in c and '"session-earlier/" + Path.GetFileName(dir) + "/" + Path.GetFileName(f)' in c)
e = rp[rp.index("public static List<string> EarlierSessions(IEnumerable<string> current)"):]
e = e[:e.index("static DateTime LastActivity(string dir)")]
check("switch MPFEVER_REPORTEARLIER=0: none", 'GetEnvironmentVariable("MPFEVER_REPORTEARLIER")' in e and 'if (sw == "0") return res;' in e)
check("  8 hours by default, or the hours given", "double hours = 8;" in e and "hours = h;" in e)
check("the same sessions folder as the current ones, never a current one",
      "Directory.GetDirectories(parent)" in e and "!cur.Contains(Path.GetFullPath(d).TrimEnd('\\\\', '/'))" in e)
check("  newest first by activity, within the hours, two at most",
      ".Where(x => x.t >= since)" in e and ".OrderByDescending(x => x.t)" in e and ".Take(2)" in e and "return res.Take(2).ToList();" in e)
la = rp[rp.index("static DateTime LastActivity(string dir)"):]
check("activity = the session's mod.log time", 'Path.Combine(dir, "mod.log")' in la[:600] and "File.GetLastWriteTime(log)" in la[:600])
f = rp[rp.index("public static bool EarlierFile(string path)"):]
f = f[:f.index("\n        }\n")]
for n in ["mod.log", "in.log", "out.log", "native.log", "results.log"]:
    check("  takes " + n, '"' + n + '"' in f)
check("  takes the drift files", 'n.StartsWith("drift_")' in f and 'n.StartsWith("sdump_drift")' in f and '"native_drift.txt"' in f)
check("  never a savegame or the chat", ".sav" not in f and "chat" not in f)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
