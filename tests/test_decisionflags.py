"""The platform-decision flags of the two game states (native/decision_flags.h, 0.6.8, after TPF3-MP's decision-sync),
offline: the header is built with MSVC into a small DLL (the way native/build.bat builds the module: freestanding, /WX) and
driven through ctypes with a stand-in for the game's memory: two engines with their per-entity table (16-byte masks at
+0xc0/+0xc8), the vehicles' MovePaths (the flag at +0x70) and a getter.

Cases: the flags that differ are copied from the source engine into the destination and counted, the source is left as it
was, equal flags copy nothing; an entity outside either engine's table is skipped without asking the getter (the game's
getter does not check it); a vehicle without a MovePath in one engine, or the same MovePath in both, is skipped. Then the
drift it removes: a flag cleared on one state, read stale on the other by a game whose batches fell otherwise.
With the game installed (build 40425, stamp 6ad9ce10), the places the native module relies on are checked in
TransportFever3.exe: the decision read found once, its getter's shape and MovePath's type descriptor, Replicate taking each
state's engine at +0x18, AddEntity growing the per-entity table by 16 bytes; and the module's wiring (MPFEVER_DECISIONSYNC,
the copy after the simulation loop's Replicate only). Another build is only reported.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_decisionflags.py
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
#include "decision_flags.h"
extern "C" __declspec(dllexport) long ds_copy(u64 a, u64 z, const i32* ent, u64 n, MovePathF get) { return DsCopyFlags(a, z, ent, n, get); }
extern "C" __declspec(dllexport) long ds_in(u64 eng, i32 ent) { return DsEntityIn(eng, ent) ? 1 : 0; }
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
    check("decision_flags.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.ds_copy.argtypes = [ctypes.c_uint64, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p]
    lib.ds_copy.restype = ctypes.c_long
    lib.ds_in.argtypes = [ctypes.c_uint64, ctypes.c_int32]
    lib.ds_in.restype = ctypes.c_long
    return lib


# ---------------------------------------------------------------- the stand-in for the game's memory
KEEP = []
GETTER_T = ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_uint64, ctypes.c_int32)


class Engine:
    """An engine with a per-entity table of n entities and MovePaths for some of them."""

    def __init__(self, n):
        self.mem = (ctypes.c_uint8 * 0x100)()
        self.table = (ctypes.c_uint8 * (16 * max(n, 1)))()
        KEEP.extend([self.mem, self.table])
        base = ctypes.addressof(self.table)
        ctypes.c_uint64.from_address(ctypes.addressof(self.mem) + 0xc0).value = base
        ctypes.c_uint64.from_address(ctypes.addressof(self.mem) + 0xc8).value = base + 16 * n
        self.paths = {}

    @property
    def addr(self):
        return ctypes.addressof(self.mem)

    def path(self, ent, flag):
        p = (ctypes.c_uint8 * 0xa0)()
        KEEP.append(p)
        p[0x70] = flag
        self.paths[ent] = p
        return p


ENGINES = {}
CALLS = []


def _get(eng, ent):
    CALLS.append((eng, ent))
    e = ENGINES.get(eng)
    p = e.paths.get(ent) if e else None
    return ctypes.addressof(p) if p is not None else 0


GET = GETTER_T(_get)
GETP = ctypes.cast(GET, ctypes.c_void_p).value


def ents(*xs):
    a = (ctypes.c_int32 * len(xs))(*xs)
    KEEP.append(a)
    return a


def unit_cases(lib):
    a, z = Engine(20), Engine(20)
    ENGINES.clear(); ENGINES[a.addr] = a; ENGINES[z.addr] = z
    a7, a8, a9 = a.path(7, 1), a.path(8, 0), a.path(9, 1)
    z7, z8, z9 = z.path(7, 0), z.path(8, 1), z.path(9, 1)
    lst = ents(7, 8, 9)
    n = lib.ds_copy(a.addr, z.addr, lst, 3, GETP)
    check(f"the flags that differ copied into the destination and counted ({n})", n == 2 and (z7[0x70], z8[0x70], z9[0x70]) == (1, 0, 1))
    check("the source left as it was", (a7[0x70], a8[0x70], a9[0x70]) == (1, 0, 1))
    check("equal flags: nothing copied", lib.ds_copy(a.addr, z.addr, lst, 3, GETP) == 0)

    # outside a table: the getter not asked
    small = Engine(5)
    ENGINES[small.addr] = small
    small.path(3, 0)
    a.path(3, 1)
    CALLS.clear()
    n = lib.ds_copy(a.addr, small.addr, ents(3, 7, 12, -1), 4, GETP)
    asked = sorted(set(e for _, e in CALLS))
    check(f"an entity outside either engine's table (7, 12 >= 5; -1) skipped without asking the getter (asked {asked})", asked == [3] and n == 1)
    check("DsEntityIn: 0 and 4 inside a table of 5, 5 and -1 outside",
          [lib.ds_in(small.addr, x) for x in (0, 4, 5, -1)] == [1, 1, 0, 0])
    empty = Engine(0)
    ctypes.c_uint64.from_address(empty.addr + 0xc0).value = 0
    ctypes.c_uint64.from_address(empty.addr + 0xc8).value = 0
    check("an engine whose table is empty: nothing inside", lib.ds_in(empty.addr, 0) == 0)

    # no MovePath in one engine, or the same MovePath in both
    b2, z2 = Engine(20), Engine(20)
    ENGINES[b2.addr] = b2; ENGINES[z2.addr] = z2
    b2.path(4, 1)                      # z2 has no MovePath for 4
    shared = b2.path(5, 1); z2.paths[5] = shared
    check("a vehicle without a MovePath in the destination, or the same MovePath in both: skipped",
          lib.ds_copy(b2.addr, z2.addr, ents(4, 5), 2, GETP) == 0 and shared[0x70] == 1)


def scenario(lib):
    """Two games, each with two states; a bus's flag is cleared on the state that ran step 10. The step after reads it on the
    state its batches give; with the game's own copy the two games read other values, with the flags copied after each
    Replicate they read the same."""
    def game(batches, sync):
        s = [Engine(10), Engine(10)]
        ENGINES.clear()
        for e in s:
            ENGINES[e.addr] = e
            e.path(1, 1)
        cur, step, reads = 0, 0, []
        for size in batches:
            for _ in range(size):
                step += 1
                if step == 10:
                    s[cur].paths[1][0x70] = 0         # the flag cleared by this state's update only
                if step == 11:
                    reads.append(s[cur].paths[1][0x70])
            # the loop's Replicate into the other state (the world, not the flag), then the copy
            if sync:
                lib.ds_copy(s[cur].addr, s[1 - cur].addr, ents(1), 1, GETP)
            cur = 1 - cur
        return reads
    g1, g2 = game([10, 4], False), game([9, 5], False)
    check(f"the game's own copy: batches cut otherwise, the flag read at step 11 differs ({g1} / {g2})", g1 != g2)
    s1, s2 = game([10, 4], True), game([9, 5], True)
    check(f"with the flags copied after each Replicate: the same on both games ({s1} / {s2})", s1 == s2 == [0])


# ---------------------------------------------------------------- the installed game (build 40425) and the module's wiring
def game_exe():
    if os.environ.get("TF3_EXE"):
        return pathlib.Path(os.environ["TF3_EXE"])
    for d in [ROOT] + list(ROOT.parents)[:6]:
        p = d / "TransportFever3.exe"
        if p.is_file():
            return p
    return None


def wiring():
    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8")
    m = re.search(r'^extern "C" u64 ReplDetour\(void\* src, void\* dst, u64 flag\)\n\{\n.*?^\}\n', src, re.S | re.M)
    check("ReplDetour copies the flags after the game's Replicate, for the simulation loop's call only",
          m is not None and re.search(r"g_replOrig\(src, dst, flag\);.*RVA_REPL_LOOP\) DecisionCopy\(src, dst\);", m.group(0), re.S) is not None)
    check("off unless MPFEVER_DECISIONSYNC=1 (0 differences on 40425)", "MPFEVER_DECISIONSYNC\", v, 3) > 0 && v[0] == '1'))" in src)
    check("installed after the order fixes, its counters in the order fixes' line",
          "InstallIndustryDemand();\n    InstallDecisionSync();" in src and '"; decision flags "' in src)
    return src


def exe_layout(src):
    exe = game_exe()
    if exe is None:
        print("note: TransportFever3.exe not found next to the repository (TF3_EXE names it): the game's layout is not checked here")
        return
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
              "(the native module checks it at the game's start and turns the copy off if it differs)")
        return
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

    m = re.search(r"^static void InstallDecisionSync\(\)\n\{\n.*?^\}\n", src, re.S | re.M)
    if not check("InstallDecisionSync found in mpfever_native.cpp", m is not None):
        return
    body = m.group(0)
    sig = re.search(r'FindSigRva\("([0-9A-F? ]+)"\)', body).group(1)
    hits = find(sig)
    if not check(f"40425: the decision read found once ({[hex(h) for h in hits]})", len(hits) == 1):
        return
    at = hits[0]
    check(f"40425: the stolen bytes at {at + 21:x} are movzx eax,[rax+70h] / test al,al, then a short jmp",
          rd(at + 21, 7) == bytes.fromhex("0FB6407084C0EB") and "Splice(mem, at + 21, 6, DecisionNote)" in body)
    getter = at + 7 + 5 + struct.unpack("<i", rd(at + 8, 4))[0]
    head = bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", re.search(r"static const u8 head\[\] = \{([^}]*)\}", body).group(1)))
    check(f"40425: MovePath's getter {getter:x} is the shape the module checks", rd(getter, len(head)) == head and len(head) == 21)
    desc = getter + 21 + 4 + struct.unpack("<i", rd(getter + 21, 4))[0]
    check(f"40425: its lea names MovePath's type descriptor ({desc:x})", rd(desc + 0x10, 29) == b".?AUMovePath@component@ecs@@\0")
    # Update2: the engine argument kept at [rsp+70h], the node list loaded from [r13+8] with r13 the system
    f = find("48 8B C4 48 89 58 20 44 89 40 18 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 68 FA FF FF")
    check(f"40425: Update2 ({[hex(x) for x in f]}) keeps the system in r13 and the engine at [rsp+70h], its count at [rbp+5b0h]",
          len(f) == 1 and f[0] < at < f[0] + 0x400 and rd(f[0] + 0x48, 12) == bytes.fromhex("4C8BE9 48894D20 4889542470")
          and find("49 8B 45 08 48 8B 38 49 8B 4D 10") == [at - 0xda] and rd(f[0] + 0x1bd, 6) == bytes.fromhex("399D B0050000"))
    r = find("48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 50 41 8B E8")
    check(f"40425: Replicate ({[hex(x) for x in r]}) copies the engines at +18h of the two states",
          len(r) == 1 and rd(r[0] + 0x30, 4) == bytes.fromhex("488B5918") and rd(r[0] + 0x47, 4) == bytes.fromhex("4C8B4718"))
    ae = find("48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 41 56 41 57 48 83 EC 40 4C 8B FA")
    check("40425: AddEntity grows the per-entity table at +0xc0 by 16 bytes an entity",
          len(ae) == 1 and bytes.fromhex("48 83 87 C8 00 00 00 10") in rd(ae[0], 0x400))


def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf_decision_"))
    try:
        lib = build(tmp)
        if lib is not None:
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
