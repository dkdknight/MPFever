"""The systems' entity lists of the engine's two world states kept in one order (0.8.18, #150; native/fam_order.h and FamCheck /
InstallFamSync in native/mpfever_native.cpp, switch MPFEVER_FAMSYNC), offline.

The engine makes each batch of steps on the other of its two world states and copies the state just simulated into the next one
(Replicate: the change records replayed, then every component copied). The ecs::ComponentGroupFamily lists, the entities a system
runs over, are not copied: each state keeps its own, in the order of its own adds (at the end) and removes (the last entity moved
into the removed one's place). A system's results can depend on that order: AnimalMoveSystem draws its random numbers per run of
128 animals, from a generator seeded with the run's first index. If the copy's list ends in another order than the simulated
state's, a step's results depend on which state makes it, that is on how the steps are cut into batches, and two games part.

The header is built with MSVC into a small DLL (as native/build.bat builds the module: freestanding, /WX) and driven through
ctypes with families made in Python (entries {entity, its components' places}, add at the end, remove by swap and pop):
  - the kinds: the entry size from the RTTI name (ComponentGroupFamily1..4: 8 to 20 bytes; NoList and other classes: none);
  - the first difference, the same entities in another order (and not: another entity, an entity twice), the heap sort;
  - the plan: the copy's last entries removed down to the first difference (each the last one then: nothing else moves), the
    simulated state's entries added in their order: the copy's list is then the simulated state's, byte for byte (500 cases);
  - THE BUG, a model of two games with the animals' draws per run of 128: the copy's replay leaves another order (removes
    replayed in another order); one game makes batches of 4 steps, the other of 1 to 4: without the fix the animals' targets
    part between the games; with the plan applied after every copy (the module's FamCheck) they stay alike at every step, and
    alike to one state making every step one after the other;
  - the module's wiring: after the loop's copy only, the switch, the fixes list (native_fx.txt), the minute's counters;
  - with the game installed (build 40425, stamp 6ad9ce10): the families' vector in the engine, the swap and pop, the animal
    family's RTTI name, the animals' runs of 128 and their generator seeded per run.
Needs Visual Studio's C++ tools (as build.bat). Run: python tests/test_famorder0818.py
"""
import ctypes
import os
import pathlib
import random
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
#include "fam_order.h"
extern "C" __declspec(dllexport) u32 fo_entry_size(const char* n, int max) { return FoEntrySize(n, max); }
extern "C" __declspec(dllexport) u64 fo_first_diff(const u8* x, const u8* y, u64 n, u32 es) { return FoFirstDiff(x, y, n, es); }
extern "C" __declspec(dllexport) u64 fo_first_ent_diff(const u8* x, const u8* y, u64 n, u32 es) { return FoFirstEntDiff(x, y, n, es); }
extern "C" __declspec(dllexport) long fo_same_set(const u8* x, const u8* y, u64 k, u64 n, u32 es, u32* sx, u32* sy) { return FoSameSet(x, y, k, n, es, sx, sy) ? 1 : 0; }
extern "C" __declspec(dllexport) void fo_plan(const u8* x, const u8* y, u64 k, u64 n, u32 es, u32* rem, u32* add) { FoPlan(x, y, k, n, es, rem, add); }
extern "C" __declspec(dllexport) void fo_sort(u32* a, u64 n) { FoSortU32(a, n); }
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
    check("fam_order.h built (cl /WX, link)", True)
    lib = ctypes.CDLL(str(tmp / "harness.dll"))
    lib.fo_entry_size.argtypes = [ctypes.c_char_p, ctypes.c_int]
    lib.fo_entry_size.restype = ctypes.c_uint32
    lib.fo_first_diff.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32]
    lib.fo_first_diff.restype = ctypes.c_uint64
    lib.fo_first_ent_diff.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32]
    lib.fo_first_ent_diff.restype = ctypes.c_uint64
    lib.fo_same_set.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
    lib.fo_same_set.restype = ctypes.c_long
    lib.fo_plan.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
    lib.fo_plan.restype = None
    lib.fo_sort.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
    lib.fo_sort.restype = None
    return lib


# ---------------------------------------------------------------- a family as the engine keeps one
class Family:
    """A ComponentGroupFamilyN's list: entries (entity, places of its N components); add at the end, remove by moving the last
    entry into the removed one's place (0x255be0 on build 40425 for N = 3)."""

    def __init__(self, ncomp, entries=()):
        self.ncomp, self.list, self.pos = ncomp, [], {}
        for e in entries:
            self.add(e)

    def places(self, ent):
        # (the component places the engine gives an entity: the same in both states once the components are copied)
        return tuple((ent * 7 + 3 * i) % 100003 for i in range(self.ncomp))

    def add(self, ent):
        assert ent not in self.pos, f"entity {ent} added twice"
        self.pos[ent] = len(self.list)
        self.list.append((ent,) + self.places(ent))

    def remove(self, ent):
        p = self.pos.pop(ent)
        last = self.list.pop()
        if p < len(self.list):
            self.list[p] = last
            self.pos[last[0]] = p

    def ents(self):
        return [e[0] for e in self.list]

    def raw(self):
        return b"".join(struct.pack("<I" + "i" * self.ncomp, *e) for e in self.list)


def buf(b):
    return ctypes.create_string_buffer(b, max(len(b), 1))


def u32s(n):
    return (ctypes.c_uint32 * max(n, 1))()


def fam_sync(lib, x, y):
    """What FamCheck does for one family: compare, and when only the order differs, the plan applied with the family's calls.
    Returns 'same', 'fixed' or 'apart'."""
    es = 4 * (1 + x.ncomp)
    xr, yr = x.raw(), y.raw()
    xn, yn = len(x.list), len(y.list)
    n = min(xn, yn)
    first = lib.fo_first_diff(buf(xr), buf(yr), n, es)
    if first == n and xn == yn:
        return "same"
    first += lib.fo_first_ent_diff(buf(xr[first * es:]), buf(yr[first * es:]), n - first, es)
    if first == n and xn == yn:
        return "places"
    if xn != yn:
        return "apart"
    m = n - first
    sx, sy = u32s(m), u32s(m)
    if not lib.fo_same_set(buf(xr), buf(yr), first, n, es, sx, sy):
        return "apart"
    rem, add = u32s(m), u32s(m)
    lib.fo_plan(buf(xr), buf(yr), first, n, es, rem, add)
    before = list(y.list[:first])
    for i in range(m):
        assert y.list[-1][0] == rem[i], "the plan removes the copy's last entry each time"
        y.remove(rem[i])
        assert y.list[:first] == before[:len(y.list[:first])]
    for i in range(m):
        y.add(add[i])
    return "fixed"


def unit_cases(lib):
    names = {
        b".?AV?$ComponentGroupFamily3@UAnimal@component@ecs@@UModelInstanceList@23@UBoundingVolume@23@@ecs@@": 16,
        b".?AV?$ComponentGroupFamily4@ULandVehicle@component@ecs@@UMovePath@23@UCarriageList@23@UVehicleOrder@23@@ecs@@": 20,
        b".?AV?$ComponentGroupFamily1@UAccount@component@ecs@@@ecs@@": 8,
        b".?AV?$ComponentGroupFamily2@UTransportVehicle@component@ecs@@UMovePath@23@@ecs@@": 12,
        b".?AV?$ComponentGroupFamilyNoList1@UAssetGroup@component@ecs@@@ecs@@": 0,
        b".?AV?$ReplicaCompVec@UAnimal@component@ecs@@@ecs@@": 0,
        b".?AV?$ComponentGroupFamily": 0,
    }
    for n, want in names.items():
        got = lib.fo_entry_size(n, len(n))
        check(f"entry size of {n[:48].decode()}...: {want} ({got})", got == want)
    n = b".?AV?$ComponentGroupFamily3@UAnimal"
    check("a name cut before the digit's '@' gives no size", lib.fo_entry_size(n, 26) == 0)

    rnd = random.Random(818)
    a = [rnd.randrange(0, 1 << 32) for _ in range(3000)] + [5, 5, 0, 0xFFFFFFFF]
    arr = (ctypes.c_uint32 * len(a))(*a)
    lib.fo_sort(arr, len(a))
    check("the heap sort sorts 3004 numbers (with twins, 0 and the largest)", list(arr) == sorted(a))

    x = Family(3, range(1, 301))
    y = Family(3, range(1, 301))
    es = 16
    check("two lists alike: no difference", lib.fo_first_diff(buf(x.raw()), buf(y.raw()), 300, es) == 300)
    y.remove(150)
    y.add(150)
    check("an entity removed and added again: the first difference at its old place (150 -> 149)",
          lib.fo_first_diff(buf(x.raw()), buf(y.raw()), 300, es) == 149)
    pl = buf(b"".join(struct.pack("<Iiii", e[0], e[1] + 1, e[2], e[3]) for e in x.list))
    check("the same entities in the same order, other places of their components: a byte difference at 0, no entity difference",
          lib.fo_first_diff(buf(x.raw()), pl, 300, es) == 0 and lib.fo_first_ent_diff(buf(x.raw()), pl, 300, es) == 300)
    check("  another order: the first other entity (149)", lib.fo_first_ent_diff(buf(x.raw()), buf(y.raw()), 300, es) == 149)
    sx, sy = u32s(300), u32s(300)
    check("  the same entities from there", lib.fo_same_set(buf(x.raw()), buf(y.raw()), 149, 300, es, sx, sy) == 1)
    z = Family(3, list(range(1, 300)) + [999])
    check("another entity: not the same entities", lib.fo_same_set(buf(x.raw()), buf(z.raw()), 0, 300, es, sx, sy) == 0)
    def entry(e):
        return struct.pack("<Iiii", e, 0, 0, 0)
    tx = buf(b"".join(entry(e) for e in list(range(1, 300)) + [7]))
    tw = buf(b"".join(entry(e) for e in [7] + list(range(1, 300))))
    check("an entity twice (in both, another order): refused", lib.fo_same_set(tx, tw, 0, 300, es, sx, sy) == 0)

    # the plan, on families of every size made by random histories
    ok = bad = moved = 0
    for case in range(500):
        ncomp = 1 + case % 4
        base = list(range(1, 2 + rnd.randrange(0, 400)))
        x, y = Family(ncomp, base), Family(ncomp, base)
        # (the same removes and adds, in another order in the copy: the lists end with the same entities)
        rem = rnd.sample(base, rnd.randrange(0, len(base)))
        new = list(range(10000, 10000 + rnd.randrange(0, 30)))
        for e in rem:
            x.remove(e)
        for e in new:
            x.add(e)
        r2 = rem[:]
        rnd.shuffle(r2)
        for e in r2:
            y.remove(e)
        n2 = new[:]
        rnd.shuffle(n2)
        for e in n2:
            y.add(e)
        r = fam_sync(lib, x, y)
        if r == "same":
            continue
        if r == "fixed" and y.raw() == x.raw() and y.ents() == x.ents():
            ok += 1
        else:
            bad += 1
        moved += 1
    check(f"the plan makes the copy's list the simulated state's, byte for byte ({ok} of {moved} lists that differed; {bad} wrong)",
          moved > 300 and bad == 0)


# ---------------------------------------------------------------- the bug: the animals' draws per run of 128
RUN = 128


def draws(order, step):
    """AnimalMoveSystem's update (0xa94350 on 40425): each run of 128 animals in the list's order has its own generator, seeded
    with the run's first index and the time; each animal of the run takes the generator's next number."""
    out = {}
    for start in range(0, len(order), RUN):
        g = random.Random((start * 2654435761 + step * 40503) & 0xFFFFFFFF)
        for e in order[start:start + RUN]:
            out[e] = g.randrange(1000)
    return out


class World:
    """One game: two states, each batch made on the other one; the copy replays the batch's removes in another order than they
    were made (a copy whose list ends in another order, as #150's drifts show the replay can leave one)."""

    def __init__(self, lib, ents, sync):
        self.lib, self.sync = lib, sync
        self.states = [Family(3, ents), Family(3, ents)]
        self.cur = 0
        self.next_id = 100000
        self.fixed = 0

    def step(self, t, log):
        f = self.states[self.cur]
        d = draws(f.ents(), t)
        # (an animal whose draw is low leaves, others come: the list's order changes by the removes)
        gone = [e for e in f.ents() if d[e] < 12]
        come = []
        for e in gone:
            f.remove(e)
        for _ in range(2 * len(gone) // 3):
            f.add(self.next_id)
            come.append(self.next_id)
            self.next_id += 1
        log.append((gone, come))
        return d

    def batch(self, t0, n):
        log, out = [], []
        for t in range(t0, t0 + n):
            out.append(self.step(t, log))
        # the copy into the other state, step by step: each step's removes replayed in another order (last first)
        other = self.states[1 - self.cur]
        for gone, come in log:
            for e in reversed(gone):
                other.remove(e)
            for e in come:
                other.add(e)
        if self.sync:
            if fam_sync(self.lib, self.states[self.cur], other) == "fixed":
                self.fixed += 1
        self.cur = 1 - self.cur
        return out


def run(lib, cuts, sync, steps=120):
    rnd = random.Random(150)
    ents = rnd.sample(range(1, 90000), 700)
    w = World(lib, ents, sync)
    out, t = [], 0
    i = 0
    while t < steps:
        n = min(cuts[i % len(cuts)], steps - t)
        out += w.batch(t, n)
        t += n
        i += 1
    return out, w


def scenario(lib):
    a, wa = run(lib, [4], False)
    b, wb = run(lib, [1, 3, 2, 4, 1, 1, 2], False)
    first = next((t for t in range(len(a)) if a[t] != b[t]), None)
    check(f"BUG: without the fix the two games' animals draw other targets (first at step {first}): batches of 4 against 1 to 4", first is not None)
    one, _ = run(lib, [10 ** 6], False)      # (one batch: every step one after the other on one state)
    a, wa = run(lib, [4], True)
    b, wb = run(lib, [1, 3, 2, 4, 1, 1, 2], True)
    c, wc = run(lib, [2], True)
    same = all(a[t] == b[t] == c[t] for t in range(len(a)))
    check(f"with the copy's lists put in order after every copy, the games stay alike at every step ({len(a)} steps, "
          f"lists put in order {wa.fixed}/{wb.fixed}/{wc.fixed} times)", same and wa.fixed > 0 and wb.fixed > 0)
    check("  and alike to one state making every step one after the other", all(a[t] == one[t] for t in range(len(a))))


# ---------------------------------------------------------------- the module's wiring
def wiring():
    src = (NATIVE / "mpfever_native.cpp").read_text(encoding="utf-8").replace("\r\n", "\n")
    check("fam_order.h included by the module", '#include "fam_order.h"' in src)
    m = re.search(r'^extern "C" u64 ReplDetour\(void\* src, void\* dst, u64 flag\)\n\{\n.*?^\}\n', src, re.S | re.M)
    body = m.group(0) if m else ""
    i_orig = body.find("u64 r = g_replOrig(src, dst, flag);")
    i_fam = body.find("== RVA_REPL_LOOP) FamCheck(src, dst);")
    check("ReplDetour calls FamCheck after the engine's copy, for the simulation loop's copy only", 0 <= i_orig < i_fam)
    f = re.search(r"^static void FamCheckBody\(void\* src, void\* dst\)\n\{\n.*?^\}\n", src, re.S | re.M)
    fb = f.group(0) if f else ""
    check("FamCheck reads the engines at GameState+0x18 and their families at +0x18/+0x20",
          "*(u64*)((u8*)src + 0x18)" in fb and "*(u64*)(ex + 0x18), fxe = *(u64*)(ex + 0x20)" in fb)
    check("FamCheck puts a list in order only with MPFEVER_FAMSYNC on, the same entities, and the family's own calls (slots 2 and 3)",
          "if (g_famSync == 1) {" in fb and "FoSameSet(" in fb and "*(FamFn*)(*(u64*)fy + 0x10), rem = *(FamFn*)(*(u64*)fy + 0x18)" in fb)
    # (2026-11-18, seen in game: 35 families of the copy at the same place were of another class, each state making its families as
    # its systems first ask for them; paired by place they were never compared, counted "odd")
    check("FamCheck pairs a family with the copy's family of the SAME CLASS (vtable), not the one at the same place",
          "vty[g] == vt" in fb and "!taken[g]" in fb and "*(u64*)fx != *(u64*)fy" not in fb)
    check("FamCheck checks the order again after putting it in order", "FoFirstEntDiff((const u8*)xb, (const u8*)yb, xn, es) == xn" in fb)
    check("FamCheck leaves alone the same entities in the same order with other places of their components (counted)",
          "first += FoFirstEntDiff(" in fb and "_InterlockedIncrement(&g_famPlaces)" in fb)
    check("the switch MPFEVER_FAMSYNC (=0: compared and written only)", 'GetEnvironmentVariableA("MPFEVER_FAMSYNC"' in src)
    # (2026-11-18, in game: every family read held 0 entities, the animals' among them on a map of 2549: off until the entries'
    # place in this build is known)
    check("by default the lists are compared and written only, never put in order (MPFEVER_FAMSYNC=1: in order; =off: nothing)",
          "if (GetEnvironmentVariableA(\"MPFEVER_FAMSYNC\", v, 3) <= 0) return 0;" in src and "if (g_famSync == 2) return;" in fb)
    # (2026-11-18 in game: AnimalMoveSystem's list pointer = the animals' family + 0x10; the slot-3 remove works on family + 8 with its
    # vector at +8..+0x10 of that part: the entries are at +0x10..+0x18 of the family. Read at +8 before, every family looked empty)
    check("compared only (the default): one copy in ten; put in order: every copy", "if (g_famSync == 0 && (famSeen++ % 10) != 0) return;" in src)
    check("the entries read at the family's +0x10..+0x18 (not +8)", "u64 xb = *(u64*)(fx + 0x10), xe = *(u64*)(fx + 0x18), yb = *(u64*)(fy + 0x10), ye = *(u64*)(fy + 0x18);" in fb
          and "*(u64*)(fx + 8)" not in fb)
    k = re.search(r"^static void InstallFamSync\(\)\n\{\n.*?^\}\n", src, re.S | re.M)
    kb = k.group(0) if k else ""
    check("InstallFamSync names the fix among those that change the simulation (native_fx.txt) when it is on and hooked",
          'if (g_famSync == 1) Fx("famsync");' in kb and "if (!g_replOn || !RVA_REPL_LOOP)" in kb)
    check("InstallFamSync is called once the copy is hooked", re.search(r"InstallAirCache\(\);\n(\s*InstallAnimCache\(\);\n)?\s*InstallFamSync\(\);", src) is not None)
    check("the minute's counters ('families' in the order fixes line)", '.str("/").dec(g_famPlaces).str("/").dec(g_famOdd)' in src)
    check("FamCheck times itself (average and largest in the minute's line)",
          "FamCheckBody(src, dst);" in src and '.str(" us a copy, ").dec(g_famUsMax)' in src)


# ---------------------------------------------------------------- the game's layout (build 40425)
def game_exe():
    if os.environ.get("TF3_EXE"):
        return pathlib.Path(os.environ["TF3_EXE"])
    for d in [ROOT] + list(ROOT.parents)[:6]:
        p = d / "TransportFever3.exe"
        if p.is_file():
            return p
    return None


def exe_layout():
    exe = game_exe()
    if exe is None:
        print("note: TransportFever3.exe not found next to the repository (TF3_EXE names it): the game's layout is not checked here")
        return
    data = exe.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    nsec, = struct.unpack_from("<H", data, pe + 6)
    stamp, = struct.unpack_from("<I", data, pe + 8)
    optsize, = struct.unpack_from("<H", data, pe + 20)
    if stamp != 0x6ad9ce10:
        print(f"note: the installed game is build stamp {stamp:08x}, not 40425 (6ad9ce10): its layout is not checked here")
        return
    secs = []
    for i in range(nsec):
        o = pe + 24 + optsize + 40 * i
        vsize, va, rsize, raw = struct.unpack_from("<IIII", data, o + 8)
        secs.append((va, vsize, raw, rsize))

    def rd(rva, n):
        for va, vs, raw, rs in secs:
            if va <= rva < va + max(vs, rs):
                return data[raw + rva - va:raw + rva - va + n]
        return b""

    def hx(s):
        return bytes(int(t, 16) for t in s.split())
    check("40425: the engine runs over its families at +0x18..+0x20 (0x2bc213a: mov r15,[r13+20h] / sub r15,[r13+18h] / sar r15,3)",
          rd(0x2bc213a, 12) == hx("4D 8B 7D 20 4D 2B 7D 18 49 C1 FF 03"))
    check("40425: ComponentGroupFamily3's remove moves the last entry into the removed one's place and pops (0x255c8a)",
          rd(0x255c8a, 23) == hx("48 8B 43 10 C5 F8 10 40 F0 48 8B 43 08 C5 F8 11 04 C8 48 83 43 10 F0"))
    check("40425: the family's slot 3 is that remove (0x255e50: add rcx,8 / mov edx,r8d / jmp)", rd(0x255e50, 8) == hx("48 83 C1 08 41 8B D0 E9"))
    check("40425: the animals' family is a ComponentGroupFamily3 (RTTI name)",
          b".?AV?$ComponentGroupFamily3@UAnimal@component@ecs@@UModelInstanceList@23@UBoundingVolume@23@@ecs@@" in data)
    check("40425: AnimalMoveSystem's update runs its animals in runs of 128 (mov r9d,80h before the loop's call, 0xa961dc)",
          rd(0xa961dc, 6) == hx("41 B9 80 00 00 00"))
    check("40425: each run seeds its own generator (MT19937, 624 words, 0x6c078965) from the run's first index (0xa944f0)",
          rd(0xa944f0, 0x25) == hx("41 8B C1 C1 E8 1E 41 33 C1 69 C8 65 89 07 6C 03 CA 89 8C 95 24 01 00 00 44 8B C9 48 FF C2 48 81 FA 70 02 00 00")
          and rd(0xa943fd, 3) == hx("45 8B C8"))


def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpf_famorder_"))
    try:
        lib = build(tmp)
        if lib is not None:
            unit_cases(lib)
            scenario(lib)
            ctypes.windll.kernel32.FreeLibrary.argtypes = [ctypes.c_void_p]
            ctypes.windll.kernel32.FreeLibrary(lib._handle)
        wiring()
        exe_layout()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        print(f"FAIL {len(fails)} check(s): {', '.join(fails)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
