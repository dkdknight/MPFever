"""Fresh ids for the commands' new entities (native/fresh_ids.h and the AddEntity / replay splices of mpfever_native.cpp,
0.6.8), offline: the header is built with MSVC into a small DLL (as native/build.bat builds the module: freestanding, /WX) and
driven through ctypes with a stand-in for an engine's entity table (+0x90/+0x98, 24 bytes each) and its free-id queue's size
(+0xf8); the engine's AddEntity (the queue's smallest id, else the count) is modelled with the module's rule.

Cases: the count, a replayed record that is the count passed over the queue only when ids wait; the 2026-11-01 23:54 case
(two games whose queues differ in one id: a vehicle bought got 84704 and 62904) gives the same id with fresh ids, and the
counts stay alike; a copy replaying the records gets the source's ids. The module's wiring: the loop's commands and the scripts' commands
(MPFever's actions) on the simulation thread only, the iteration's builds too, the replay hooked before AddEntity, MPFEVER_FRESHIDS=0, the counters, the
exact freeq lines. With the game installed (build 40425, stamp 6ad9ce10): AddEntity's bytes the module checks and steals, its
two paths, the replay's call and id check, the queue appended at the end of a modification only. Another build is reported.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_freshids.py
"""
import ctypes
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
fails = []


def check(what, cond):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)
    return cond


HARNESS = r'''
#include "win.h"
#include "fresh_ids.h"
extern "C" __declspec(dllexport) i64 fi_count(const u8* eng) { return FiCount(eng); }
extern "C" __declspec(dllexport) long fi_replay(const u8* eng, i32 want) { return FiReplayFresh(eng, want) ? 1 : 0; }
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
        p = subprocess.run(s, cwd=tmp, env=env, capture_output=True, text=True, errors="replace")
        if p.returncode != 0:
            check("build: " + pathlib.Path(s[0]).name, False)
            print(p.stdout + p.stderr)
            return None
    check("fresh_ids.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    return lib




# ---------------------------------------------------------------- the stand-in for the game's memory
KEEP = []


def engine(count, queued):
    """An engine with `count` entities ever made and `queued` ids waiting (only the size matters here)."""
    mem = (ctypes.c_uint8 * 0x110)()
    ents = (ctypes.c_uint8 * (24 * max(count, 1)))()
    KEEP.extend([mem, ents])
    a = ctypes.addressof(mem)
    ctypes.c_uint64.from_address(a + 0x90).value = ctypes.addressof(ents)
    ctypes.c_uint64.from_address(a + 0x98).value = ctypes.addressof(ents) + 24 * count
    ctypes.c_uint64.from_address(a + 0xf8).value = queued
    return a


class Game:
    """AddEntity as the game does it (the queue's smallest id, the count when empty) with the native module's rule: a
    command's entity passes the queue over (fresh), and a copy replaying a record passes it over when fresh_ids.h says so."""

    def __init__(self, lib, count, queue, fresh=True):
        self.lib, self.count, self.queue, self.fresh = lib, count, sorted(queue), fresh

    def add(self, command=False, replay=None):
        hide = False
        if self.fresh and command and self.queue:
            hide = True
        if self.fresh and replay is not None:
            hide = bool(self.lib.fi_replay(engine(self.count, len(self.queue)), replay))
        if self.queue and not hide:
            return self.queue.pop(0)
        self.count += 1
        return self.count - 1

    def free(self, i):
        self.queue = sorted(self.queue + [i])


def unit_cases(lib):
    check("FiCount: the entities ever made (24 bytes each)", lib.fi_count(engine(37, 0)) == 37)
    bad = engine(5, 0)
    ctypes.c_uint64.from_address(bad + 0x98).value = ctypes.c_uint64.from_address(bad + 0x90).value + 25
    check("FiCount: a table that is not whole entries: -1", lib.fi_count(bad) == -1)
    check("a replayed id that is the count, with ids waiting: the queue passed over", lib.fi_replay(engine(100, 3), 100) == 1)
    check("a replayed id from the queue: the queue's head, as the game", lib.fi_replay(engine(100, 3), 42) == 0)
    check("a replayed fresh id with an empty queue: the game gives the count by itself", lib.fi_replay(engine(100, 0), 100) == 0)


def scenario(lib):
    """The 2026-11-01 23:54 case: the two games' queues differ in one id for a while (62904 waiting on the client only); a
    vehicle bought in that window."""
    for fresh in (False, True):
        host = Game(lib, 90000, [84704, 84869], fresh)
        client = Game(lib, 90000, [62904, 84704, 84869], fresh)
        client.queue.remove(84704)   # (same size: the host freed 84704 a few steps before the client, the client 62904)
        h, c = host.add(command=True), client.add(command=True)
        # (the simulation's own entities, then the late frees: the queues are alike again)
        host.add(); client.add()
        host.free(62904); client.free(84704)
        h2, c2 = host.add(command=True), client.add(command=True)
        if not fresh:
            check(f"the queue's ids for the commands (as before): the vehicle gets {h} on the host, {c} on the client", h != c)
        else:
            check(f"fresh ids: the vehicle gets {h} on both games", h == c == 90000)
            check(f"and the next command's entity too ({h2} / {c2}), the counts alike", h2 == c2 and host.count == client.count)
    # a copy of the state replays the source's records and must get every id again
    src = Game(lib, 500, [7, 9])
    rec = [src.add(), src.add(command=True), src.add(command=True), src.add()]
    copy = Game(lib, 500, [7, 9])
    got = [copy.add(replay=r) for r in rec]
    check(f"a copy replaying the records gets the same ids ({rec} / {got})", got == rec)
    copy0 = Game(lib, 500, [7, 9], fresh=False)
    got0 = [copy0.add() for r in rec]
    check(f"without the replay's rule the copy would get other ids ({got0}): the engine's check of the replay would fail", got0 != rec)


def game_exe():
    if os.environ.get("TF3_EXE"):
        return pathlib.Path(os.environ["TF3_EXE"])
    for d in [ROOT] + list(ROOT.parents)[:6]:
        p = d / "TransportFever3.exe"
        if p.is_file():
            return p
    return None


def game_layout():
    exe = game_exe()
    if exe is None:
        print("note: TransportFever3.exe not found next to the repository (TF3_EXE names it): the game's layout is not checked here")
        return None
    data = exe.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    nsec, = struct.unpack_from("<H", data, pe + 6)
    stamp, = struct.unpack_from("<I", data, pe + 8)
    optsize, = struct.unpack_from("<H", data, pe + 20)
    secs = []
    for i in range(nsec):
        o = pe + 24 + optsize + 40 * i
        name = data[o:o + 8].rstrip(b"\0").decode("latin1")
        vsize, va, rsize, raw = struct.unpack_from("<IIII", data, o + 8)
        secs.append((name, va, vsize, raw, rsize))
    if stamp != 0x6ad9ce10:
        print(f"note: the installed game is build stamp {stamp:08x}, not 40425 (6ad9ce10): its layout is not checked here "
              "(the native module checks it at the game's start and turns the fix off if it differs)")
        return None
    text = next(s for s in secs if s[0] == ".text")
    tbytes = data[text[3]:text[3] + text[4]]

    def rd(rva, n):
        for name, va, vs, raw, rs in secs:
            if va <= rva < va + max(vs, rs):
                return data[raw + rva - va:raw + rva - va + n]
        return b""

    def find(sig):
        pat = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in sig.split())
        return [text[1] + x.start() for x in re.finditer(pat, tbytes, re.S)]
    return rd, find


def wiring():
    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8")
    m = re.search(r'^extern "C" u64 ApplyDetour\(void\* a, void\* b\)\n\{\n.*?^\}\n', src, re.S | re.M)
    body = m.group(0) if m else ""
    check("ApplyDetour marks the loop's commands and the scripts' (MPFEVER_FRESHSCRIPT=0: the loop's only), on the simulation thread (before: test n4 of "
          "2026-11-02 stopped both games, 'entity == c.entity'; not CGame's own sink nor another thread: the tools' previews)",
          "g_cmdTid = sim && (inLoop || (script && freshScript)) ? g_simTid : 0;" in body
          and "freshScript = GetEnvironmentVariableA(\"MPFEVER_FRESHSCRIPT\", v, 3) > 0 && v[0] == '0' ? 0 : 1;" in body
          and "g_scriptTid = sim && script ? g_simTid : 0;" in body and "g_cmdTid = prevCmd; g_cmdKind = prevKind; g_scriptTid = prevScript;" in body)
    check("every command applied counted by where it came from and by thread", "_InterlockedIncrement(&g_applySite[" in body)
    p = re.search(r'^extern "C" u64 PreIterDetour\(void\* a\)\n\{\n.*?^\}\n', src, re.S | re.M)
    check("the builds applied at the iteration's start are commands too", p is not None and "g_cmdTid = g_simTid; g_cmdKind = 1;\n        g_applyOrig(g_slot, c);" in p.group(0))
    i = re.search(r"^static void InstallFreshIds\(\)\n\{\n.*?^\}\n", src, re.S | re.M)
    body = i.group(0) if i else ""
    check("the replay hooked before AddEntity, AddEntity at +0x55 (5 bytes)",
          body.find("Splice(mem, rep, 8, FreshReplay)") != -1 and body.find("Splice(mem, rep, 8, FreshReplay)") < body.find("Splice(mem, RVA_ADDENTITY + 0x55, 5, FreshAdd)"))
    check("MPFEVER_FRESHIDS=0 turns it off", 'GetEnvironmentVariableA("MPFEVER_FRESHIDS", v, 3) > 0 && v[0] == \'0\'' in body)
    f = re.search(r"^static void FreshAdd\(SavedRegs\* r\)\n\{\n.*?^\}\n", src, re.S | re.M)
    check("FreshAdd: only the applying state's engine, its queue's size read as 0",
          f is not None and "*(u64*)(gs + 0x18) != r->rdi" in f.group(0) and f.group(0).rstrip().endswith("r->r8 = 0;\n}"))
    check("only the commands' own vehicles and lines (AddEntity called from CustomEntityCreate or LineCreate) get fresh ids; the entities "
          "the systems make meanwhile keep the queue's (test x2: the copy makes those itself, with the queue's head)",
          f is not None and "if (ret != g_freshSite[0] && ret != g_freshSite[1]) { _InterlockedIncrement(&g_freshSkip); return; }" in f.group(0)
          and "*(u64*)(OrigRsp(r) + 0x58)" in f.group(0))
    check("installed after the decision flags, its counters in the order fixes' line",
          "InstallDecisionSync();\n    InstallFreshIds();" in src and '"; fresh ids "' in src and '"; applied "' in src
          and '", script entities "' in src)
    fa = re.search(r"^static void FreshAdd\(SavedRegs\* r\)\n\{\n.*?^\}\n", src, re.S | re.M)
    fb = fa.group(0) if fa else ""
    i = fb.find("if (g_scriptTid == tid && g_cmdTid != tid) {")
    j = fb.find("return;", i)
    check("a script command's entities keep the queue's ids (counted and logged, r8 left as it is)",
          i != -1 and j != -1 and "r->r8 = 0" not in fb[i:j] and "_InterlockedIncrement(&g_freshScript)" in fb[i:j])
    check("the free-id queue logged before each step that is a multiple of 50 (MPFEVER_FREEQLOG), with its hash and the count",
          "if (g_freeqExact) FreeqStep(engine);" in src and 'str(" hash ")' in src and 'str(" count ")' in src)
    return src


def exe_layout(src):
    found = game_layout()
    if not found:
        return
    rd, find = found
    ae = find("48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 40 4C 8B FA")
    if not check(f"40425: AddEntity found once ({[hex(x) for x in ae]})", len(ae) == 1):
        return
    a = ae[0]
    check("40425: AddEntity's engine in rdi, the queue's size in r8, then xor ebx,ebx / test r8,r8 / jne (the 5 bytes stolen at +0x55)",
          rd(a + 0x1b, 3) == bytes.fromhex("488BF9") and rd(a + 0x4e, 14) == bytes.fromhex("4C8B87F8000000 33DB 4D85C0 0F85"))
    jne = a + 0x5a + 6 + struct.unpack("<i", rd(a + 0x5c, 4))[0]
    check(f"40425: the queue's path ({jne:x}) takes the head from the deque at +0xe0/+0xe8/+0xf0 and lowers the size",
          rd(jne, 14) == bytes.fromhex("488B97F0000000 488B8FE8000000")
          and bytes.fromhex("488987F8000000") in rd(jne, 0x40))
    check("40425: the count's path: lea r10,[rdi+90h], the id the entries' count (24 bytes each)",
          rd(a + 0x60, 7) == bytes.fromhex("4C8D9790000000") and bytes.fromhex("48B8ABAAAAAAAAAAAA2A") in rd(a + 0x60, 0x30))
    r = find("48 8D 54 24 50 48 8B CF E8 ?? ?? ?? ?? 8B 43 04 39 44 24 50 0F 85")
    ok = len(r) == 1 and r[0] + 13 + struct.unpack("<i", rd(r[0] + 9, 4))[0] == a
    check(f"40425: the copy's replay ({[hex(x) for x in r]}) calls AddEntity and checks the id against the record's", ok)
    s0 = find("49 8D 8D D8 00 00 00 4D 8B 0C 24 49 8B 41 08 48 89 44 24 20 4D 8B 09 4D 8B 85 F8 00 00 00 48 8D 55 87 E8")
    check(f"40425: the freed ids join the queue at the end of a modification only ({[hex(x) for x in s0]})", len(s0) == 1)
    ap = find("48 89 5C 24 18 48 89 74 24 20 55 57 41 54 41 56 41 57 48 8D 6C 24 C9 48 81 EC B0 00 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 2F 4C 8B F2")
    sc = find("48 8B 45 08 48 8B 88 F0 01 00 00 48 63 81 98 00 00 00 48 8B D3 48 8B 4C C1 78 E8 ?? ?? ?? ?? 48 8B 4E 38")
    sk = find("48 8B 4B 08 48 8B 91 F0 01 00 00 48 63 8A 98 00 00 00 48 8B 4C CA 78 48 8B D0 E8 ?? ?? ?? ?? 48 8B 4F 38")
    tgt = lambda x: x + 31 + struct.unpack("<i", rd(x + 27, 4))[0]
    check(f"40425: the scripts' sink ({[hex(x) for x in sc]}) applies at once on the current state, after its thread-list test, "
          f"Apply returning to {sc[0] + 31 if sc else 0:x}",
          len(ap) == 1 and len(sc) == 1 and tgt(sc[0]) == ap[0] and rd(sc[0] - 0x47, 14) == bytes.fromhex("65488B0C2558000000BF10000000")
          and sc[0] + 31 == 0x120514)
    check(f"40425: CGame's own sink ({[hex(x) for x in sk]}) calls Apply too (counted only)", len(sk) == 1 and tgt(sk[0]) == ap[0])
    av = find("48 89 5C 24 30 48 8D 54 24 38 48 8B CB E8 ?? ?? ?? ?? 8B 5C 24 38 89 5C 24")
    al = find("48 89 5D C7 48 8D 55 CF 48 8B CB E8 ?? ?? ?? ?? 8B 5D CF 4D 8D 47 28")
    tg = lambda x, k: x + k + 5 + struct.unpack("<i", rd(x + k + 1, 4))[0]
    check(f"40425: the vehicles' and lines' own AddEntity calls ({[hex(x) for x in av]}, {[hex(x) for x in al]}) call AddEntity, returning to "
          f"{av[0] + 18 if av else 0:x} (CustomEntityCreate) and {al[0] + 16 if al else 0:x} (LineCreate)",
          len(av) == 1 and len(al) == 1 and tg(av[0], 13) == a and tg(al[0], 11) == a and av[0] + 18 == 0x9e0298 and al[0] + 16 == 0x9e24bb)
    pro = rd(a, 0x18)
    check("40425: AddEntity's frame at +0x55 is its 3 pushes and 0x40 bytes (the caller's return at [rsp+58h])",
          pro[15:21] == bytes.fromhex("5741564157") + b"H"[:1] and rd(a + 0x14, 4) == bytes.fromhex("4883EC40"))
    # the replay's id check is ecs::Replicator::Apply's "entity == c.entity" (Engine.cpp:138), the one AddEntity call of its switch
    rep_ = find("48 8D 54 24 50 48 8B CF E8 ?? ?? ?? ?? 8B 43 04 39 44 24 50 0F 85")
    fail = rep_[0] + 26 + struct.unpack("<i", rd(rep_[0] + 22, 4))[0] if rep_ else 0
    msg = fail + 0x1b + struct.unpack("<i", rd(fail + 0x17, 4))[0] if fail else 0
    check(f"40425: the replay's failed check ({fail:x}) is the assert 'entity == c.entity' (the crash of test n4)",
          bool(fail) and rd(msg, 19) == b"entity == c.entity" + b"\x00")
    sw = rd(0x2bc0ee0, 0x1d0) if rep_ and rep_[0] == 0x2bc0f43 else b""
    n_add = sum(1 for k in range(len(sw) - 5) if sw[k] == 0xE8 and 0x2bc0ee0 + k + 5 + struct.unpack("<i", sw[k + 1:k + 5])[0] == a)
    check(f"40425: Replicator::Apply calls AddEntity once ({n_add}): the replay splice covers every replayed new entity", n_add == 1)


def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf_freshids_"))
    try:
        lib = build(tmp)
        if lib is not None:
            lib.fi_count.argtypes = [ctypes.c_uint64]
            lib.fi_count.restype = ctypes.c_int64
            lib.fi_replay.argtypes = [ctypes.c_uint64, ctypes.c_int32]
            lib.fi_replay.restype = ctypes.c_long
            unit_cases(lib)
            scenario(lib)
            ctypes.windll.kernel32.FreeLibrary.argtypes = [ctypes.c_void_p]
            ctypes.windll.kernel32.FreeLibrary(lib._handle)
        src = wiring()
        exe_layout(src)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        print(f"FAIL {len(fails)} check(s): {', '.join(fails)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
