"""Offline test: a game whose native module does not run is told to everyone (0.8.5, #268, MPFEVER_NATIVECHECK=0 off).

#268 (Jakob host, Arne): Arne started MPFever.exe away from its archive's folder ("not in a release folder", "winhttp.dll is
missing"); an old winhttp.dll stayed in the game's folder, found no signature file and switched its hooks off. The towns drifted
every 3 minutes (13 resynchronisations), while the warning was only on Arne's own screen. The mod now says in its hello whether its
native module runs ("nat"), and the host says it in the chat.
mpfever_bridge.script.lua, launcher/ModCopies.cs, MainForm.cs and lang.json are read; the mod's reading is run with lupa.
Run: python tests/test_nativecheck085.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(HERE, "..", *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


br = read("mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
mc = read("launcher", "ModCopies.cs")
mf = read("launcher", "MainForm.cs")

i = br.index('send("hello", { name = C.NAME')
blk = br[i - 900:i + 400]
check("the hello carries nat", "nat = nat })" in blk)
check("  'on' when native_state.txt exists (written once the module's fixes went in)", '"native_state.txt"' in blk and 'nat = "on"' in blk)
check("  'off' when the module started (native.log) but wrote no state; 'none' otherwise", '"native.log"' in blk and 'nat = "off"' in blk and 'local nat = "none"' in blk)
check("  read under pcall (the hello is never lost to it)", "pcall(function()" in blk)

check("the host looks at every hello", "WarnNative(m.From, m.Payload);" in mf)
w = mc[mc.index("void WarnNative(string who, string payload)"):]
w = w[:w.index("\n        }\n")]
check("  said in the log and the chat, once per player", "HostChat(\"msg\", \"MPFever\", text)" in w and "nativeWarned.Add" in w)
check("  switch MPFEVER_NATIVECHECK=0", 'GetEnvironmentVariable("MPFEVER_NATIVECHECK") == "0"' in w)
p = mc[mc.index("internal static string NativeProblem(string who, string payload)"):]
p = p[:p.index("\n        }\n")]
check("  only for 'off' or 'none' (a hello without nat, an older mod: nothing)", 'if (nat != "off" && nat != "none") return null;' in p)
en = "MPFever's native module does not run on {0}'s game (MPFever.exe started away from its archive's folder?): that game will drift away from the others. {0}, please extract the whole MPFever archive into one folder and start MPFever.exe from there."
check("  the English text", en in p)
lang = json.load(open(os.path.join(HERE, "..", "launcher", "lang.json"), encoding="utf-8-sig"))["texts"]
check("  lang.json: every language, with the name", en in lang and all("{0}" in lang[en].get(c, "") for c in ["de", "es", "it", "nl", "pl", "pt-BR", "ru", "ja", "ko", "zh-CN", "zh-TW"]))

try:
    import lupa.lua52 as lupa
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    body = re.search(r'\t\tlocal nat = "none"\n(\t\tpcall\(function\(\).*?\n\t\tend\)\n)', blk, re.S).group(1)
    L.execute("FILES = {} BS = '/' C = { DIR = 'd', IO = { open = function(p) if FILES[p] then return { close = function() end } end return nil end } }")
    f = L.eval("function() local nat = 'none'\n" + body + " return nat end")
    L.execute("FILES = { ['d/native_state.txt'] = true, ['d/native.log'] = true }")
    check("lupa: module running -> on", f() == "on")
    L.execute("FILES = { ['d/native.log'] = true }")
    check("lupa: #268, started with hooks off -> off", f() == "off")
    L.execute("FILES = {}")
    check("lupa: no module -> none", f() == "none")
except ImportError:
    print("lupa is not installed: the reading's cases not run")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
