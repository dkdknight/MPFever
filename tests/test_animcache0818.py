"""The animals' cached figures made again at the start of every batch (0.8.18, #150; InstallAnimCache / AnimUpdateWrap in
native/mpfever_native.cpp, switch MPFEVER_ANIMALCACHE), offline.

Every drift between two games of one PC that kept both games' rings (2026-11-13 to 11-17) began with an entity made or removed by
AnimalMoveSystem on one game only, the free-id queue splitting there. AnimalMoveSystem keeps an entry per animal (vfunc4 makes it,
vfunc5 erases it), made again only when the animal's components are said changed; the copy of a batch replays the change records
before copying the components, so the copy's entry is made from its OLD components (as the aircraft's was, 0.8.8). A step's result
then depends on which state makes it, and the batches differ between games. Each animal's entry is now made again at the first
update of every batch, in the state that makes it.
  - THE BUG, a model: animals moving, an entry (their box) made from the components at the time of a change; the copy makes it
    from its old components, then copies them. Two games cut the steps into other batches: without the fix their animals' entries
    and what is decided from them part; with the entries made again at the first update of each batch, both stay alike;
  - the module's wiring: the signature, the vtable's slot 12, vfunc5 then vfunc4 for every animal, once per batch (or every step),
    the switch, the fixes list, the minute's counters;
  - with the game installed (build 40425, stamp 6ad9ce10): the signature found once, at AnimalMoveSystem::Update2 (0xa960e0),
    in one vtable whose slots 4 and 5 are 0xa95a10 and 0xa95d10.
Run: python tests/test_animcache0818.py
"""
import pathlib
import random
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []


def check(what, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + what + (" -- " + str(detail) if detail and not cond else ""), flush=True)
    if not cond:
        fails.append(what)


# ---------------------------------------------------------------- THE BUG, a model
class Engine:
    """Two world states; each state's system keeps a box per animal, made from the state's components when the animal changes.
    The copy replays the changes (the box made from the copy's OLD position) and then copies the positions."""

    def __init__(self, n, refresh):
        self.pos = [[i * 10 for i in range(n)], [i * 10 for i in range(n)]]
        self.box = [[p // 50 for p in self.pos[0]], [p // 50 for p in self.pos[1]]]
        self.cur, self.refresh, self.log = 0, refresh, []

    def batch(self, steps, t):
        dst = 1 - self.cur
        for a in self.log:                                    # the replay: the copy's box from its OLD position
            self.box[dst][a] = self.pos[dst][a] // 50
        self.pos[dst] = list(self.pos[self.cur])                # then the components
        self.cur, self.log = dst, []
        if self.refresh and steps:                              # the fix: every box made again, first update of the batch
            self.box[dst] = [p // 50 for p in self.pos[dst]]
        for k in range(steps):
            for a in range(len(self.pos[dst])):
                # a decision from the box (the animal's cell): which way it goes
                d = 3 if (self.box[dst][a] + t + k + a) % 3 else -2
                self.pos[dst][a] += d
                nb = self.pos[dst][a] // 50
                if nb != self.box[dst][a]:
                    self.box[dst][a] = nb
                    self.log.append(a)
        return steps


def play(refresh, cuts, total=400, n=40):
    e = Engine(n, refresh)
    t = 0
    i = 0
    while t < total:
        s = min(cuts[i % len(cuts)], total - t)
        e.batch(s, t)
        t += s
        i += 1
    return e.pos[e.cur]


rnd = random.Random(7)
parted_old = alike_new = 0
for trial in range(20):
    cuts_b = [rnd.randint(1, 4) for _ in range(50)]
    if play(False, [4]) != play(False, cuts_b):
        parted_old += 1
    if play(True, [4]) == play(True, cuts_b):
        alike_new += 1
check(f"THE BUG: boxes made from the copy's old positions, other batches: the animals part ({parted_old}/20)", parted_old >= 18, parted_old)
check(f"the boxes made again at the first update of each batch: the animals stay alike whatever the batches ({alike_new}/20)", alike_new == 20, alike_new)

# ---------------------------------------------------------------- the module's wiring
src = (ROOT / "native" / "mpfever_native.cpp").read_text(encoding="utf-8", errors="replace")
SIG = "48 8B C4 48 89 58 20 55 56 57 41 54 41 55 41 56 41 57 48 8D 6C 24 A0 48 81 EC 60 01 00 00 C5 F8 29 70 B8 C5 F8 29 78 A8 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 30 C5 F8 28 FB 41 8B F8 4C 8B FA 48 8B F1 48 89 4D A0"
check("InstallAnimCache finds AnimalMoveSystem::Update2 by its signature", 'FindSigRva("' + SIG + '")' in src)
ar = src[src.index("static void AnimRefresh("):src.index("static u64 AnimUpdateWrap(")]
check("every animal: vfunc5 (erase) then vfunc4 (make)", "erase = *(EntityFn*)(vt + 0x28)" in ar and "build = *(EntityFn*)(vt + 0x20)" in ar
      and "{ erase(sys, engine, ids[i]); build(sys, engine, ids[i]); }" in ar)
check("the animals read before any entry is made", ar.index("ids[i] = *(u32*)(list") < ar.index("erase(sys, engine, ids[i])"))
aw = src[src.index("static u64 AnimUpdateWrap("):src.index("static u64 VtableSlotOf(")]
check("once per batch (g_batchSeq), at every step with =2 or when no batch is counted", "g_animMode == 2 || seq == 0 || seq != g_animSeqDone" in aw)
check("then the game's own update", "return g_animOrig(sys, engine, n, dt);" in aw)
check("the batches counted at the top of StepsForBatch", re.search(r'extern "C" u32 StepsForBatch\(void\* time, u32 speed, u32 asked\)\n\{\n    g_batchSeq\+\+;', src) is not None)
check("the switch MPFEVER_ANIMALCACHE (0 off, 2 every step)", 'GetEnvironmentVariableA("MPFEVER_ANIMALCACHE"' in src)
check("in the fixes list the host compares", 'if (ok) Fx("animalcache");' in src)
check("installed with the aircraft's", "InstallAirCache();\n    InstallAnimCache();" in src)
check("counted in the minute's line", "animals' figures made again " in src)
check("diagnostic: the entities the engine made or removed during a refresh counted (an entry made from old figures moves the animal)",
      "u32 a0 = g_stepAdds, r0 = g_stepRems;" in ar and "u32 da = g_stepAdds - a0, dr = g_stepRems - r0;" in ar and "changed the engine " in src)

# ---------------------------------------------------------------- the game's layout (build 40425)
exe = ROOT.parent / "TransportFever3.exe"
if not exe.is_file():
    print("SKIP the game's layout (no TransportFever3.exe next to the repository)")
else:
    try:
        import pefile
    except ImportError:
        pefile = None
        print("SKIP the game's layout (pip install pefile)")
    if pefile:
        pe = pefile.PE(str(exe), fast_load=True)
        if pe.FILE_HEADER.TimeDateStamp != 0x6ad9ce10:
            print("SKIP the game's layout (another game build: %x)" % pe.FILE_HEADER.TimeDateStamp)
        else:
            text = [x for x in pe.sections if x.Name.startswith(b".text")][0]
            data, va, base = text.get_data(), text.VirtualAddress, pe.OPTIONAL_HEADER.ImageBase
            pat = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in SIG.split())
            hits = [va + m.start() for m in re.finditer(pat, data, re.S)]
            check("the signature found once, at 0xa960e0", hits == [0xa960e0], [hex(h) for h in hits])
            vt = 0x371b428
            slots = [struct.unpack("<Q", pe.get_data(vt + 8 * i, 8))[0] - base for i in range(13)]
            check("AnimalMoveSystem's vtable: slot 12 = Update2, slot 4 = 0xa95a10 (make), slot 5 = 0xa95d10 (erase)",
                  slots[12] == 0xa960e0 and slots[4] == 0xa95a10 and slots[5] == 0xa95d10, [hex(x) for x in slots])

print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
