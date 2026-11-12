"""Offline test: what the 2026-11-12 reports lacked is now in them (0.8.4).

  - #263 (gs_as, a client): its game crashed, its MPFever left the session before the report, so the host's logs could not be
    asked for. Its MPFever now tells the host ("game_crashed") before leaving, and the host asks every player in the chat to send a
    report now (MPFEVER_CRASHNOTICE=0: as before). The message is the host's alone to read: never passed on to the games.
  - #254 / #262: a game closed with code 53 at its start; Steam not running, other rights, or a game already running (stefa's)
    could not be told apart. report.txt says what runs on the PC (MPFEVER_REPORTENV=0: no such line).
launcher/MainForm.cs, ReportShare.cs, Reporter.cs and lang.json are read.
Run: python tests/test_reportgaps084.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


def read(n):
    return open(os.path.join(L, n), encoding="utf-8-sig").read().replace("\r\n", "\n")


mf, rs, rp = read("MainForm.cs"), read("ReportShare.cs"), read("Reporter.cs")

# the crashed player's side
i = mf.index("void LeaveOnGameExit()")
leave = mf[i:mf.index("\n        }\n", i)]
a, b = leave.find('Msg.Make("game_crashed"'), leave.find("foreach (var cl in gone) try { cl.Leave(); }")
check("#263: the crashed game's MPFever tells the host before its connections are closed", 0 < a < b)
check("  only after a crash (Reporter.CrashedSince, as the crash question)", "Reporter.CrashedSince(gameStartedAt" in leave[:b])
check("  switch MPFEVER_CRASHNOTICE=0", 'GetEnvironmentVariable("MPFEVER_CRASHNOTICE") != "0"' in mf and "CrashNoticeOn()" in leave)
# the host's side
j = mf.index("void OnHostMessage(Msg m, Peer from)")
host = mf[j:j + 6000]
k = host.find('if (m.Kind == "game_crashed")')
check("the host reads it before its switch, and never passes it on (return)", 0 < k < host.find("switch (m.Kind)") and "return; }" in host[k:k + 160])
check("  from a player only (from != null)", "if (from != null) OnPlayerCrashed(BaseName(from.Name))" in host[k:k + 160])
o = mf[mf.index("void OnPlayerCrashed(string who)"):]
o = o[:o.index("\n        }\n")]
check("  said in the chat and in the host's log", 'HostChat("msg", "MPFever", text)' in o and "Log.Warn(text)" in o)
en = "{0}'s game crashed. To help find why, every player please send « Report a problem » now, before leaving the session."
check("  the English text", en in o)
lang = json.load(open(os.path.join(L, "lang.json"), encoding="utf-8-sig"))["texts"]
codes = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
check("  lang.json: in every language, with the player's name", en in lang and all("{0}" in lang[en].get(c, "") for c in codes))

# report.txt
s = rs[rs.index("string ReportSummary(bool crashed"):]
s = s[:s.index("return sb.ToString();")]
check("#254/#262: report.txt says what runs on this PC and the game's last exit code", '"This PC now: " + Reporter.RunningNow()' in s and "the game's last exit code" in s)
check("  switch MPFEVER_REPORTENV=0", 'GetEnvironmentVariable("MPFEVER_REPORTENV") != "0"' in s)
r = rp[rp.index("internal static string RunningNow()"):]
r = r[:r.index("\n        }\n")]
check("  the games of Transport Fever 3 with their start times", 'GetProcessesByName("TransportFever3")' in r and "StartTime" in r)
check("  Steam running or not", 'GetProcessesByName("steam")' in r and "NOT running" in r)
check("  MPFever as administrator", "WindowsBuiltInRole.Administrator" in r)
check("  every reading guarded (a report is never lost to it)", r.count("catch") >= 3)

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
