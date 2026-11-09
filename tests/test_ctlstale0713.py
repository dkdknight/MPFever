"""Test of #171's fix (0.7.13, native/ctl_players.h, ReadControl and DropAtLoad of native/mpfever_native.cpp), offline: the
header is built with MSVC into a small DLL (as native/build.bat builds the module: freestanding, /WX) and driven through
ctypes, on the real control file of #171 (tests/data/native_ctl_171.txt: keywords, entity ids and tokens only).

MrWhiskey1, 2026-11-08 15:40:34: a client cut from its host joined again from the main menu, and its game stopped right after
the load ("entity is not known", entity 227907, Player, from UI::CSelector). The bridge says this machine's company again
every few seconds ("setlocal 227907 <token>", with "setothers" and "setcanon"); the native module reads its control file only
when a command is added, and that game, cut from its host, added one every 15 s: its last lines (15:36:39) stayed unread. The
drop at the next load (DropAtLoad, 0.7.5) emptied the values, and the first reading after the load took those lines again:
the interface read the player of the company of the game before, which the new world does not have. The lines written before
the game now running began to load are now the game before's (DropAtLoad marks where the file ends): counted, never taken.
MPFEVER_CTLSTALE=1: taken, as before.

Cases:
  - no load (no mark): the values 0.7.12 took (227907, 148447, 148447 227901, token 17739928);
  - at every line boundary of the file (and in lines cut in the middle, and on lines made to be odd), through the same
    16383-byte window as ReadControl: the header gives what a model of 0.7.12's three readings gives (the last setlocal,
    setothers, setcanon, value and token), without a mark, and with a mark and MPFEVER_CTLSTALE=1's way;
  - the load of 15:40 (the mark at the file's end): nothing taken, the lines counted, the last old one local player 227907;
  - the load of 15:22 (the file cut after its 39th line): nothing taken (231644, 148447 and 148447 231630 before), the lines
    of the new game written after it taken;
  - lines written after the mark: taken; a line whose newline comes after the mark (half written at the load): taken; a mark
    beyond the file's size (the file written anew): nothing old;
  - MPFEVER_CTLSTALE=1's way (takeOld): taken as before, marked as written before the load;
  - the autotest "tomenustale": the bridge's H.tomenu writes "s<seq>" (lupa), mpfever_auto.lua says the last player lines
    again with a new token on the main menu (lupa, a mocked game, real files), lines 0.7.12 took after the load and the fix
    leaves out; the launcher's scenario keeps the company mode and keeps the mouse over the client's world;
  - the module's text: DropAtLoad marks the file before it drops this machine's company, ReadControl reads the player lines by
    the header at the place of its own readings, MPFEVER_CTLSTALE read, the logs.
Needs Visual Studio's C++ tools (as build.bat) and lupa. Run: python tests/test_ctlstale0713.py
"""
import ctypes
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
CONTENT = ROOT / "mod" / "mpfever_1" / "content"
FIXTURE = ROOT / "tests" / "data" / "native_ctl_171.txt"
WINDOW = 16383   # ReadControl reads the file's last sizeof(buf) - 1 bytes
NOUT = 13 + 32
fails = []


def check(what, cond, got=""):
    print(("PASS " if cond else "FAIL ") + what + (f": {got}" if got != "" and not cond else ""), flush=True)
    if not cond:
        fails.append(what)
    return cond


HARNESS = r'''
#include "ctl_players.h"
extern "C" void* memset(void*, int, decltype(sizeof(0)));
extern "C" void* memcpy(void*, const void*, decltype(sizeof(0)));
#pragma function(memset)
#pragma function(memcpy)
extern "C" void* memset(void* d, int v, decltype(sizeof(0)) n) { unsigned char* a = (unsigned char*)d; while (n--) *a++ = (unsigned char)v; return d; }
extern "C" void* memcpy(void* d, const void* s, decltype(sizeof(0)) n) { unsigned char* a = (unsigned char*)d; const unsigned char* b = (const unsigned char*)s; while (n--) *a++ = *b++; return d; }
// ReadControl's way: the file's last 16383 bytes from bufOff, the mark gone by (CtlWindow), the player lines (CtlPickPlayers,
// the same cut into lines as ReadControl's loop, which calls CtlPickLine for each line). Returns the mark gone by.
extern "C" __declspec(dllexport) int cp_read(const char* file, unsigned size, unsigned oldEnd, int takeOld, long* out)
{
    unsigned bufOff = CtlWindow(size, 16383, &oldEnd);
    CtlPlayers p;
    CtlPickPlayers(file + bufOff, size - bufOff, bufOff, oldEnd, takeOld != 0, &p);
    out[0] = p.local; out[1] = p.localTok; out[2] = p.haveLocal; out[3] = p.localOld;
    out[4] = p.canon; out[5] = p.canonTok; out[6] = p.haveCanon;
    out[7] = p.nOthers; out[8] = p.othersTok; out[9] = p.haveOthers;
    out[10] = p.nOld; out[11] = p.oldLocal; out[12] = p.oldLocalTok;
    for (int i = 0; i < 32; i++) out[13 + i] = i < p.nOthers ? p.others[i] : 0;
    return (int)oldEnd;
}
'''


def msvc_env():
    vswhere = os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Microsoft Visual Studio", "Installer", "vswhere.exe")
    if not os.path.isfile(vswhere):
        return None
    p = subprocess.run([vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                        "-property", "installationPath"], capture_output=True, text=True)
    vs = (p.stdout or "").strip().splitlines()
    if not vs:
        return None
    ver = (pathlib.Path(vs[0]) / "VC" / "Auxiliary" / "Build" / "Microsoft.VCToolsVersion.default.txt").read_text().strip()
    vc = pathlib.Path(vs[0]) / "VC" / "Tools" / "MSVC" / ver
    bin_ = vc / "bin" / "Hostx64" / "x64"
    return bin_, dict(os.environ, PATH=str(bin_) + os.pathsep + os.environ.get("PATH", ""),
                      INCLUDE=str(vc / "include"), LIB=str(vc / "lib" / "x64"))


def build(tmp):
    found = msvc_env()
    if not check("Visual Studio's C++ tools found (vswhere)", found is not None):
        return None
    bin_, env = found
    (tmp / "harness.cpp").write_text(HARNESS, encoding="utf-8")
    steps = [
        [str(bin_ / "lib.exe"), "/nologo", "/def:" + str(NATIVE / "kernel32.def"), "/out:" + str(tmp / "kernel32.lib"), "/machine:x64"],
        [str(bin_ / "cl.exe"), "/nologo", "/c", "/WX", "/O2", "/GS-", "/Zl", "/EHs-c-", "/GR-", "/std:c++17", "/I", str(NATIVE),
         str(tmp / "harness.cpp"), "/Fo:" + str(tmp / "harness.obj")],
        [str(bin_ / "link.exe"), "/nologo", "/WX", "/DLL", "/NODEFAULTLIB", "/NOENTRY", "/OUT:" + str(tmp / "harness.dll"),
         str(tmp / "harness.obj"), str(tmp / "kernel32.lib")],
    ]
    for s in steps:
        p = subprocess.run(s, cwd=tmp, env=env, capture_output=True, text=True)
        if p.returncode != 0:
            check("build: " + pathlib.Path(s[0]).name, False)
            print(p.stdout + p.stderr)
            return None
    check("ctl_players.h built (cl /WX, link, no C runtime)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.cp_read.argtypes = [ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_long)]
    lib.cp_read.restype = ctypes.c_int
    return lib


def pick(lib, data, mark=0, take_old=False):
    out = (ctypes.c_long * NOUT)()
    went = lib.cp_read(data, len(data), mark, 1 if take_old else 0, out)
    o = list(out)
    r = {"local": (o[0], o[1]) if o[2] else None, "localOld": bool(o[3]),
         "canon": (o[4], o[5]) if o[6] else None,
         "others": (o[13:13 + o[7]], o[8]) if o[9] else None,
         "nOld": o[10], "oldLocal": (o[11], o[12]), "mark": went}
    return r


def digits(l, k):
    """the digits of the line l from k on, as ReadControl's loops read them: the value, and where they end"""
    v = 0
    while k < len(l) and 48 <= l[k] <= 57:
        v = v * 10 + l[k] - 48
        k += 1
    return v, k


def old_model(data):
    """0.7.12's ReadControl (its lines 602-656 and 704-719): the file's last 16383 bytes, cut at each '\\n'; the last setlocal,
    setothers and setcanon line of the part read, each with its token"""
    buf = data[len(data) - WINDOW:] if len(data) > WINDOW else data
    got = len(buf)
    local = others = canon = None
    i = 0
    while i < got:
        j = buf.find(b"\n", i)
        if j < 0:
            j = got
        l = buf[i:j]
        n = len(l)
        if n >= 10 and l[:9] == b"setlocal ":
            v, k = digits(l, 9)
            tok = digits(l, k + 1)[0]
            local = (v, tok)
        elif n >= 11 and l[:10] == b"setothers ":
            tok, k = digits(l, 10)
            lst = []
            while k < n and len(lst) < 32:
                while k < n and not (48 <= l[k] <= 57):
                    k += 1
                k0 = k
                e, k = digits(l, k)
                if k > k0:
                    lst.append(e)
            others = (lst, tok)
        elif n >= 10 and l[:9] == b"setcanon ":
            tok, k = digits(l, 9)
            e = digits(l, k + 1)[0]
            canon = (e, tok)
        i = j + 1
    return {"local": local, "others": others, "canon": canon}


def same(r, m):
    return r["local"] == m["local"] and r["others"] == m["others"] and r["canon"] == m["canon"]


def lupa_cases(lib, data):
    try:
        import lupa.lua52 as lupa
    except ImportError:
        check("lupa is installed (pip install lupa)", False)
        return
    # --- the bridge's H.tomenu: "s<seq>" for "tomenustale", "<seq>" as before ("toshared")
    br = (CONTENT / "mpfever_bridge.script.lua").read_text(encoding="utf-8").replace("\r\n", "\n")
    m = re.search(r"^H\.tomenu = function\(from, p\)\n.*?^end\n", br, re.S | re.M)
    if not check("the bridge's H.tomenu found", m is not None):
        return
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
      ENV = { MPFEVER_SAVE = "MPFever test ctlstale" }
      os.getenv = function(k) return ENV[k] end
      FILES, LOGS, BS, H = {}, {}, "/", {}
      C = { DIR = "d", appendFile = function(p, t) FILES[p] = (FILES[p] or "") .. t; return true end }
      G = { frames = 0, waits = {} }
      app = { stopGame = function() STOPPED = true end }
      function log(s) LOGS[#LOGS + 1] = s end
    ''' + m.group(0))
    L.execute("H.tomenu(nil, { seq = 7, stale = true })")
    check("H.tomenu with p.stale (\"tomenustale\"): auto_reload.txt \"s7\"", L.eval("FILES['d/auto_reload.txt']") == "s7", L.eval("FILES['d/auto_reload.txt']"))
    check("  back to the main menu as before", L.eval("#G.waits == 1 and (G.waits[1].fn() or true) and STOPPED == true"))
    L.execute("FILES = {}; G.waits = {}; H.tomenu(nil, { seq = 8 })")
    check("H.tomenu without (\"toshared\"): \"8\", as before", L.eval("FILES['d/auto_reload.txt']") == "8", L.eval("FILES['d/auto_reload.txt']"))

    # --- mpfever_auto.lua on the main menu: the last player lines said again with token + 1, before the load
    auto = (CONTENT / "mpfever_auto.lua").read_text(encoding="utf-8")
    tmp = tempfile.mkdtemp(prefix="mpf_ctlstale_")
    try:
        def fresh():
            A = lupa.LuaRuntime(unpack_returned_tuples=True)
            A.execute("ENV = { MPFEVER_DIR = [[" + tmp + "]], MPFEVER_SAVE = 'MPFever test ctlstale' }")
            A.execute(r'''
              os.getenv = function(k) return ENV[k] end
              print = function() end
              LOADS = {}
              api = { type = { SavegameId = { new = function() return {} end } } }
              app = {
                SaveGameNamespace = { getSavegame = function() return "ns" end },
                findAllSavegames = function() return { { saveName = "MPFever test ctlstale", path = "p/t.sav", timestamp = 1 } } end,
                getSavegameInfo = function(id) LOADS[#LOADS + 1] = id.saveGameName; return nil end,
                loadGame = function(id) LOADS[#LOADS + 1] = id.saveGameName end,
                isWaitForStartReadyGame = function() return false end,
              }
            ''')
            A.execute(auto)
            return A

        def write(name, b):
            with open(os.path.join(tmp, name), "wb") as f:
                f.write(b)

        def read(name):
            p = os.path.join(tmp, name)
            return open(p, "rb").read() if os.path.exists(p) else None

        A = fresh()
        write("native_ctl.txt", data)
        write("auto_reload.txt", b"s638980123456789")
        A.execute("data().handleEvent(0, 'mainMenuReady', nil)")
        now = read("native_ctl.txt")
        added = now[len(data):]
        want = b"setlocal 227907 17739929\nsetothers 17739929 148447 227901\nsetcanon 17739929 148447\n"
        check("\"tomenustale\" on the main menu: the last setlocal, setothers and setcanon said again, token + 1", now[:len(data)] == data and added == want, added)
        check("  the reload taken (auto_reload.txt emptied) and the test savegame loaded again", read("auto_reload.txt") == b"" and len(list(A.eval("LOADS").values())) >= 1)
        log = (read("auto.log") or b"").decode("utf-8", "replace")
        check("  said in auto.log", "tomenustale: the last player lines of the game before said again, unread" in log, log)
        # the native module after that load: 0.7.12 took those lines (a new token: applied), the fix leaves them out
        r = pick(lib, now)
        check("  without a mark (0.7.12): 227907 taken again with its new token, the #171 crash's way",
              r["local"] == (227907, 17739929) and r["canon"] == (148447, 17739929) and r["others"] == ([148447, 227901], 17739929), r)
        r = pick(lib, now, len(now))
        check("  marked at the load: nothing taken, the last old one 227907", r["local"] is None and r["canon"] is None and r["others"] is None
              and r["oldLocal"] == (227907, 17739929), r)
        r = pick(lib, now, len(now), True)
        check("  MPFEVER_CTLSTALE=1: taken, marked as written before the load", r["local"] == (227907, 17739929) and r["localOld"], r)

        A = fresh()
        write("native_ctl.txt", data)
        write("auto_reload.txt", b"638980123456789")
        A.execute("data().handleEvent(0, 'mainMenuReady', nil)")
        check("\"toshared\" (no \"s\"): the control file left as it is, as before", read("native_ctl.txt") == data and read("auto_reload.txt") == b"")
        write("native_ctl.txt", b"enable 1\nenable 0\n")
        write("auto_reload.txt", b"s1")
        A.execute("data().handleEvent(0, 'mainMenuReady', nil)")
        check("\"tomenustale\" without player lines: nothing added", read("native_ctl.txt") == b"enable 1\nenable 0\n")
        os.remove(os.path.join(tmp, "native_ctl.txt"))
        write("auto_reload.txt", b"s2")
        A.execute("data().handleEvent(0, 'mainMenuReady', nil)")
        check("  without a control file: none made", read("native_ctl.txt") is None)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def text_cases():
    nat = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8").replace("\r\n", "\n")
    d = nat[nat.find("static void DropAtLoad()"):]
    d = d[:d.find("\n}\n")]
    i_mark = d.find("g_ctlOldEnd = (long)CtlFileSizeNow();")
    check("DropAtLoad marks where the control file ends before it drops this machine's company",
          0 < i_mark < d.find("_InterlockedIncrement(&g_ctlLoads);") < d.find("_InterlockedExchange(&g_localPlayer, 0)"))
    check("  MPFEVER_LOADKEEPLOCAL=1 still keeps everything (no DropAtLoad, no mark)", "if (!LoadKeepLocal()) DropAtLoad();" in nat)
    rc = nat[nat.find("static void ReadControl()"):]
    rc = rc[:rc.find("\n}\n")]
    check("ReadControl reads the mark before the file's size",
          0 < rc.find("long loads0 = g_ctlLoads, mark = g_ctlOldEnd;") < rc.find("DWORD size = GetFileSize(f, 0), got = 0;"))
    check("  the same window as before, the mark gone by (CtlWindow)",
          "DWORD bufOff = CtlWindow(size, (unsigned)(sizeof(buf) - 1), &oldEnd);" in rc and "SetFilePointer(f, (long)bufOff, 0, 0);" in rc
          and "if (size > sizeof(buf) - 1) size = sizeof(buf) - 1;" in rc)
    check("  the file written anew: the mark forgotten", "if (mark && !oldEnd) _InterlockedCompareExchange(&g_ctlOldEnd, 0, mark);" in rc)
    i_def = rc.find('memcmp(l, "defernext ", 10) == 0')
    i_pick = rc.find("else if (CtlPickLine(l, len, CtlLineOld(bufOff, j, oldEnd), takeOld, &pk)) {}")
    i_hud = rc.find('memcmp(l, "hudshare ", 9) == 0')
    check("  the player lines read by the header, at the place of its own readings in the chain", 0 < i_def < i_pick < i_hud)
    check("  its own readings gone", 'memcmp(l, "setlocal ", 9)' not in rc and 'memcmp(l, "setothers ", 10)' not in rc and 'memcmp(l, "setcanon ", 9)' not in rc)
    check("  MPFEVER_CTLSTALE=1: taken (CtlStaleKeep)", "bool takeOld = CtlStaleKeep();" in rc and 'GetEnvironmentVariableA("MPFEVER_CTLSTALE", e, 3)' in nat)
    check("  a load begun while the file was read: nothing taken",
          "if (!takeOld && g_ctlLoads != loads0) { pk.haveLocal = false; pk.haveCanon = false; pk.haveOthers = false; }" in rc)
    check("  the values taken as before, from the header",
          "if (pk.haveLocal && pk.localTok != g_localTok) {\n        g_localTok = pk.localTok; g_localPlayer = pk.local;" in rc
          and "if (pk.haveCanon && pk.canonTok != g_canonTok) {\n        g_canonTok = pk.canonTok; g_canon = pk.canon;" in rc
          and "if (pk.haveOthers && pk.othersTok != g_othersTok) {" in rc and "g_nOthers = pk.nOthers;" in rc)
    check("  logged: the lines left out (once a load), the local player taken (old ones always)",
          "player line(s) of the game before left out after the load" in rc and "from the control file (token " in rc
          and "a line written before this game's load (MPFEVER_CTLSTALE=1)" in rc and "g_ctlOldSaid = loads0;" in rc)
    check("  a few logs more after each load", "for (int k = 0; k < 3; k++) if (g_ctlShown[k] > 7) g_ctlShown[k] = 7;" in d)
    check('#include "ctl_players.h" in the module', '#include "ctl_players.h"' in nat)
    h = (NATIVE / "ctl_players.h").read_text(encoding="utf-8")
    check("the header needs no C runtime (no memcmp, no include)", "memcmp" not in h.replace("no memcmp", "") and "#include" not in h)

    ms = (ROOT / "launcher" / "MainForm.cs").read_text(encoding="utf-8-sig").replace("\r\n", "\n")
    i = ms.find('if (scenario == "tomenustale")')
    blk = ms[i:ms.find("continue;", i)] if i > 0 else ""
    check("the launcher's autotest \"tomenustale\"", i > 0 and ms.find('if (scenario == "toshared")') < i)
    check("  both games back to the main menu, the reload marked \"stale\"",
          'HostSend(Msg.Make("tomenu", hostName, "{[\\"seq\\"]=" + DateTime.Now.Ticks + ",[\\"stale\\"]=true}"));' in blk)
    check("  the company mode kept", "companyMode =" not in blk and "companyMode = " not in blk)
    check("  the mouse over the client's world from the order until a minute after the start",
          blk.count("AutoHover(clientWin(), hk++); Thread.Sleep(250);") == 3 and blk.find("AutoHover(clientWin()") < blk.find("StartSession();")
          and "Now + 60" in blk)
    check("  the result line", 'AutoLine("after the reload: " + (ClosedGames() == "" ? "both games running" : "CLOSED " + ClosedGames()));' in blk)


def main():
    raw = FIXTURE.read_bytes()
    data = raw.replace(b"\r\n", b"\n")   # (the file as the bridge writes it: '\n' only; a checkout may give '\r\n')
    lines = data.split(b"\n")[:-1]
    check("the fixture: #171's control file, 721 lines, 19795 bytes", len(lines) == 721 and len(data) == 19795, (len(lines), len(data)))
    check("the fixture holds keywords, entity ids and tokens only",
          all(re.fullmatch(rb"(setlocal|setothers|setcanon|enable|hudshare|opennet)( \d+)+", l) for l in lines))
    text_cases()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf-ctl-"))
    try:
        lib = build(tmp)
        if lib is None:
            print("FAILED: " + ", ".join(fails))
            return 1
        # (a) no load: what 0.7.12 took
        r = pick(lib, data)
        check("(a) no load: 227907, 148447, 148447 227901, token 17739928, nothing old",
              r["local"] == (227907, 17739928) and r["canon"] == (148447, 17739928) and r["others"] == ([148447, 227901], 17739928)
              and r["nOld"] == 0 and not r["localOld"], r)
        # (b) the header = 0.7.12's readings, at every line boundary, through the same window
        ends = [m.end() for m in re.finditer(rb"\n", data)]
        bad = [e for e in ends if not same(pick(lib, data[:e]), old_model(data[:e]))]
        check(f"(b) no mark: the same as 0.7.12 at each of the {len(ends)} line boundaries (the 16383-byte window)", not bad, bad[:5])
        rnd = random.Random(171)
        cuts = sorted(rnd.sample(range(1, len(data)), 300))
        bad = [c for c in cuts if not same(pick(lib, data[:c]), old_model(data[:c]))]
        check("(b) no mark: the same in 300 lines cut in the middle", not bad, bad[:5])
        bad = []
        for e in ends:
            mark = rnd.randrange(0, e + 1)
            if not same(pick(lib, data[:e], mark, True), old_model(data[:e])):
                bad.append((e, mark))
        check("(b) a mark and MPFEVER_CTLSTALE=1: the same as 0.7.12 at every line boundary", not bad, bad[:5])
        odd = (b"setlocal \nsetlocal\nsetlocal x\nsetlocal 12\nsetlocal 12 34 56\nsetlocal 7 8\r\nsetothers \nsetothers 5\n"
               b"setothers 5 a1 b2 c\nsetothers 6 " + b" ".join(str(n).encode() for n in range(100, 140)) + b"\n"
               b"setcanon 9\nsetcanon 9 \nsetcanon 10 11 12\nsetcanon\n\n\nsetothers 77\nsetlocal 99 88x\nsetcanon 3 4\nenable 1\n")
        olines = [m.end() for m in re.finditer(rb"\n", odd)]
        bad = [e for e in olines if not same(pick(lib, odd[:e]), old_model(odd[:e]))]
        check("(b) odd lines (too short, no digits, carriage returns, 40 entities, empty): the same as 0.7.12", not bad, bad[:5])
        r = pick(lib, odd[:olines[9]])
        check("  (40 entities: the first 32 kept, as before)", r["others"] == (list(range(100, 132)), 6), r["others"])
        # (c) the load of 15:40: the mark at the file's end
        r = pick(lib, data, len(data))
        check("(c) the load of 15:40 (marked at the file's end): nothing taken", r["local"] is None and r["canon"] is None and r["others"] is None, r)
        check("  the player lines in the part read counted, the last old one local player 227907",
              r["nOld"] > 0 and r["oldLocal"] == (227907, 17739928) and r["mark"] == len(data), r)
        # (d) the load of 15:22: the file cut after its 39th line
        p39 = b"".join(l + b"\n" for l in lines[:39])
        check("  (lines 37 to 39: \"enable 0\", the end of the first session)", lines[36:39] == [b"enable 0"] * 3)
        r = pick(lib, p39)
        check("(d) 0.7.12 at the load of 15:22: 231644, 148447, 148447 231630 taken again",
              r["local"] == (231644, 17635413) and r["canon"] == (148447, 17635413) and r["others"] == ([148447, 231630], 17635413), r)
        r = pick(lib, p39, len(p39))
        check("(d) marked: nothing taken", r["local"] is None and r["canon"] is None and r["others"] is None and r["nOld"] == 33, r)
        p43 = b"".join(l + b"\n" for l in lines[:43])
        r = pick(lib, p43, len(p39))
        check("  the new game's lines written after the mark taken: 227907, 148447, 148447 227901",
              r["local"] == (227907, 17660701) and r["canon"] == (148447, 17660701) and r["others"] == ([148447, 227901], 17660701)
              and not r["localOld"] and r["nOld"] == 33, r)
        # (e) lines written after the mark of 15:40
        more = data + b"setlocal 5 18000001\nsetothers 18000001 148447\nsetcanon 18000001 148447\n"
        r = pick(lib, more, len(data))
        check("(e) lines written after the mark: taken (5, 148447, 148447)",
              r["local"] == (5, 18000001) and r["others"] == ([148447], 18000001) and r["canon"] == (148447, 18000001) and not r["localOld"], r)
        r2 = pick(lib, more + b"hudshare 18000002\nenable 1\n", len(data))
        check("  other lines after them change nothing", r2["local"] == r["local"] and r2["others"] == r["others"] and r2["canon"] == r["canon"], r2)
        # (f) MPFEVER_CTLSTALE=1's way
        r = pick(lib, data, len(data), True)
        check("(f) MPFEVER_CTLSTALE=1: taken as before, marked as written before the load",
              r["local"] == (227907, 17739928) and r["canon"] == (148447, 17739928) and r["others"] == ([148447, 227901], 17739928)
              and r["localOld"], r)
        # (g) a line whose newline comes after the mark (half written at the load)
        half = data + b"setlocal 7 18000002\n"
        r = pick(lib, half, len(data) + 10)
        check("(g) a line half written at the load: new, taken", r["local"] == (7, 18000002) and not r["localOld"], r)
        nonl = data + b"setlocal 8 18000003"
        r = pick(lib, nonl, len(nonl))
        check("  a last line without its newline yet: new, taken", r["local"] == (8, 18000003), r)
        r = pick(lib, half, len(half))
        check("  the same line once its newline is in: old", r["local"] is None and r["oldLocal"] == (7, 18000002), r)
        # (h) a mark beyond the file's size: the file written anew, nothing old
        r = pick(lib, data, len(data) + 500)
        check("(h) a mark beyond the file's size (written anew): as without a mark, the mark forgotten",
              r["local"] == (227907, 17739928) and r["nOld"] == 0 and r["mark"] == 0, r)
        small = b"enable 1\nsetlocal 12 100\n"
        r = pick(lib, small, len(data))
        check("  (a file written anew, smaller than the window)", r["local"] == (12, 100) and r["mark"] == 0, r)
        r = pick(lib, b"", 0)
        check("  an empty file: nothing", r["local"] is None and r["canon"] is None and r["others"] is None and r["nOld"] == 0, r)
        lupa_cases(lib, data)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
