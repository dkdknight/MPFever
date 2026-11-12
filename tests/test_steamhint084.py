"""Offline test: the game closed with code 53 right after its start is explained (0.8.4, issue #254, MPFEVER_STEAMHINT=0 off).

#254 (simon): the game closed three times in under half a second with code 53 (SteamAPI_Init failed: Steam not running, or
Steam and the game with different rights); the launcher only wrote « closed (code 53) ». launcher/MainForm.cs and lang.json are read.
Run: python tests/test_steamhint084.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MF = os.path.join(HERE, "..", "launcher", "MainForm.cs")
LJ = os.path.join(HERE, "..", "launcher", "lang.json")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(MF, encoding="utf-8-sig").read().replace("\r\n", "\n")
m = re.search(r"internal static bool SteamUnreachableExit\(int\? code, TimeSpan lived\) => (.*?);\n", src)
check("SteamUnreachableExit exists", m is not None)
body = m.group(1) if m else ""
check("  code 53 only", "code == 53" in body)
check("  within 30 s of the start (a game closed later with 53 is not explained this way)", "lived < TimeSpan.FromSeconds(30)" in body)

i = src.index('Log.W(F("Transport Fever 3 fermé (code {0}{1}).", "Transport Fever 3 closed (code {0}{1}).", code,')
blk = src[i:i + 1400]
check("the menu game's exit writes the hint after its exit code",
      "SteamUnreachableExit(g?.ExitCode, DateTime.Now - gameStartedAt)" in blk and blk.index("SteamUnreachableExit") < blk.index("LeaveOnGameExit();"))
check("  switch MPFEVER_STEAMHINT=0 turns it off", 'GetEnvironmentVariable("MPFEVER_STEAMHINT") != "0"' in blk)
check("  as a warning (shown), not a dim line", "Log.Warn(T(\"Le jeu n'a pas pu joindre Steam" in blk)

en = "The game could not reach Steam and closed at once. Start Steam and sign in, then start MPFever again. Steam and MPFever must run with the same rights: neither « as administrator », or both."
check("  the English text in the code", en in blk)
lang = json.load(open(LJ, encoding="utf-8-sig"))["texts"]
codes = ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]
check("lang.json: the hint in every language", en in lang and all(lang[en].get(c) for c in codes))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
