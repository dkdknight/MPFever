"""Offline test: a vehicle bought gets a fresh id, not the head of the free-id queue (0.7.7, InstallFreshBuy and FreshAdd in
native/mpfever_native.cpp).

The user's server (16 threads) and PC (32 threads), 2026-11-07 23:41: the AI bought a truck at the same step on both games, it
was 118852 on the server and 111350 on the PC; the order fixes sort the vehicles by id, the vehicles and the towns drifted and
the games were reloaded. A purchase is not made by its command (no "script entities" counted): the vehicles' system makes the
vehicle at a later step. MPFEVER_ENTLOG of a purchase (Test Gameplay, 2026-11-08 01:13): "-79058" freed by another system in
that step, then "+79058" the vehicle (AddEntity returning to 26a8250, from 26a8850, from 9deb11), the queue's head, which two
games had different for a few steps (0.6.8's analysis). The 0.6.8 fresh ids covered the commands' own entities only.
  - with the game on this PC (build 40425): each of the three calls is found once (its signature at 26a8240 / 26a883d / 9deafa), calling
    AddEntity, the function the first is in, the function the second is in;
  - the native module checks those three targets before it turns it on, and gives the fresh id only for AddEntity returning to
    the wrapper's call with the two callers above it on the stack, on the simulated state's engine, on the simulation thread;
    after the copies' replay (whose fresh ids follow the source's), before the commands' branch;
  - MPFEVER_FRESHBUY=0: the queue's id, as before; counted in the "order fixes" line ("vehicles bought").
Run: python tests/test_freshbuy077.py
"""
import os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


nat = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
S0 = "48 8D 54 24 40 49 8B CF C5 F8 77 E8 ?? ?? ?? ?? 8B 54 24 40 41 89 14 24"
S1 = "44 8B CB 45 8B C7 49 8B D5 48 8D 4C 24 48 E8 ?? ?? ?? ?? 4C 89 6D A0 8B 7C 24 48"
S2 = "4C 89 7C 24 28 48 89 74 24 20 4C 8B C8 48 8D 4C 24 70 E8 ?? ?? ?? ?? 8B 00 41 89 44 24 50"
i = nat.find("static void InstallFreshBuy()\n{")
inst = nat[i:nat.find("\n}\n", i)]
check(i > 0 and all('FindSigRva("' + s + '")' in inst for s in (S0, S1, S2)), "the three calls found by signature")
check("if (t0 != RVA_ADDENTITY)" in inst and "!(t1 <= s0 && s0 - t1 < 0x1000)" in inst and "!(t2 <= s1 && s1 - t2 < 0x1000)" in inst,
      "  their targets checked: AddEntity, the function of the first, the function of the second")
check("g_buySite[0] = s0 + 16; g_buySite[1] = s1 + 19; g_buySite[2] = s2 + 23;" in inst, "  the return addresses after each call")
check('GetEnvironmentVariableA("MPFEVER_FRESHBUY", v, 3) > 0 && v[0] == \'0\'' in inst, "MPFEVER_FRESHBUY=0: the queue's ids, as before")
check("    InstallFreshBuy();\n}" in nat, "installed with the commands' fresh ids (only when those are on)")
f = nat[nat.find("static void FreshAdd(SavedRegs* r)"):]
f = f[:f.find("\n}\n")]
rep, buy, cmd = f.find("if (g_freshReplayTid == tid) {"), f.find("if (g_freshBuy && r->r8 && tid == g_simTid) {"), f.find("if (g_scriptTid == tid && g_cmdTid != tid) {")
check(0 < rep < buy < cmd, "FreshAdd: after the copies' replay, before the scripts' and the commands' branches")
blk = f[buy:cmd]
check("ret0 == g_base + g_buySite[0] && BuyChain(sp + 0x60)" in blk, "  AddEntity returning to the wrapper, the two callers above it")
check("*(u64*)(gs + 0x18) == r->rdi" in blk and "r->r8 = 0;" in blk, "  on the simulated state's engine only: the queue's size read as 0 (a fresh id)")
check("ret0 = g_base + g_addCaller" in blk, "  through the entity watch's detour too (MPFEVER_ENTWATCH)")
bc = nat[nat.find("static bool BuyChain(u64 sp)"):]
bc = bc[:bc.find("\n}\n")]
check("Readable((void*)sp, 0x800)" in bc and "for (int j = i + 1; j < 0x100; j++) if (q[j] == b) return true;" in bc, "BuyChain: the first caller, then the second above it")
check('.str(", vehicles bought ").dec(g_freshBuyN)' in nat, "counted in the order fixes' line")

exe = os.path.join(HERE, "..", "..", "TransportFever3.exe")
if not os.path.exists(exe):
    print("(the game is not on this PC: its code not looked at)")
else:
    d = open(exe, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    stamp = struct.unpack_from("<I", d, pe + 8)[0]
    secs = []
    for k in range(nsec):
        o = pe + 24 + opt + 40 * k
        vs, va, rs, ro = struct.unpack_from("<IIII", d, o + 8)
        secs.append((d[o:o + 8].rstrip(b"\0"), va, vs, ro, rs))

    def off(r):
        for _, va, vs, ro, rs in secs:
            if va <= r < va + max(vs, rs):
                return ro + (r - va)

    def find(sig):
        pat = b"".join(b"." if p == "??" else re.escape(bytes([int(p, 16)])) for p in sig.split())
        return [va + mm.start() for n, va, vs, ro, rs in secs if n.startswith(b".tex") for mm in re.finditer(pat, d[ro:ro + rs], re.S)]

    def target(call):
        return call + 5 + struct.unpack_from("<i", d, off(call) + 1)[0]

    a, b, c = find(S0), find(S1), find(S2)
    if stamp != 0x6ad9ce10:
        print("(not build 40425 here: the places not compared)")
        check(len(a) <= 1 and len(b) <= 1 and len(c) <= 1, "the game: each call at most once")
    else:
        check(a == [0x26a8240] and b == [0x26a883d] and c == [0x9deafa], "the game: each call found once (" + ",".join(hex(x) for x in a + b + c) + ")")
        if a and b and c:
            t0, t1, t2 = target(a[0] + 11), target(b[0] + 14), target(c[0] + 18)
            check(t0 == 0x2bc0260, "  the wrapper calls AddEntity (" + hex(t0) + ")")
            check(t1 == 0x26a8000 and t1 <= a[0] < t1 + 0x1000, "  its caller calls the wrapper (" + hex(t1) + ")")
            check(t2 == 0x26a8480 and t2 <= b[0] < t2 + 0x1000, "  the vehicles' system calls that caller (" + hex(t2) + ")")
            check((a[0] + 16, b[0] + 19, c[0] + 23) == (0x26a8250, 0x26a8850, 0x9deb11), "  the return addresses the entity log showed")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
