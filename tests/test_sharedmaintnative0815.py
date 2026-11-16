"""Offline test of the shared maintenance's native side (0.8.15, InstallSharedMaint in native/mpfever_native.cpp).

The engine's maintenance update (TransportVehicleSystem, 40425 0xb872e0) lists each depot's candidate vehicles in 0xb83470
(40420 0xb7e290, read with Ghidra): "the depot has no PlayerOwned || (vehicle's owner >= 0 && vehicle's owner == depot's owner)",
r12 holding the depot's PlayerOwned. The module splices where both paths that set r12 join (vpxor xmm0 / vmovdqu [rsp+28h],xmm0)
and clears r12 for a depot the simulation's table says open. Cases:
  - the signature: the call that reads PlayerOwned, the two paths that set r12, the 10 stolen bytes at +15, the loop's owner check
    on r12 further on (test r12,r12 / je / mov eax,[rdi+4] / js / cmp eax,[r12] / jne);
  - the splice's function clears r12 only with a table of this load that says on and the depot open; nothing without a table;
  - the table comes through the C runtime's getenv (imported by the game, called by its os.getenv); the names start with "\\1MPFM";
    the parser refuses a count out of bounds and unsorted depots; a table of another load is never used;
  - installed after the vehicles' wear; its result logged;
  - with the game installed (build 40425): the signature matches exactly once, the stolen bytes are those two instructions, r12 is
    read nowhere else in the function than in that check, and the game imports getenv from api-ms-win-crt-environment-l1-1-0.dll,
    called by the engine's getenv wrapper behind os.getenv. Another build is only reported.
Run: python tests/test_sharedmaintnative0815.py
"""
import os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.join(HERE, "..", "native", "mpfever_native.cpp")
GAME = os.path.join(HERE, "..", "..", "TransportFever3.exe")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def block(src, head):
    m = re.search(r"^" + re.escape(head) + r"\n\{\n.*?^\}\n", src, re.S | re.M)
    return m.group(0) if m else ""


def main():
    src = open(NATIVE, encoding="utf-8").read()
    inst = block(src, "static void InstallSharedMaint()")
    cand = block(src, "static void MaintCandidates(SavedRegs* r)")
    parse = block(src, "static char* MaintGetenv(const char* s)")
    hook = block(src, "static char* GetenvHook(const char* name)")
    mtopen = block(src, "static bool MtOpen(const MaintTable& t, i32 depot, i32 owner)")
    check("InstallSharedMaint, MaintCandidates, MaintGetenv, GetenvHook, MtOpen found", all([inst, cand, parse, hook, mtopen]))
    sig = re.search(r'FindSigRva\("([0-9A-F? ]+)"\)', inst)
    toks = sig.group(1).split() if sig else []
    check("its place found by a signature", len(toks) > 60)
    check("  the PlayerOwned call, then r12 set on both paths (mov r12,rax / jmp / mov r12,r15)",
          toks[:3] == ["8B", "D3", "E8"] and toks[7:15] == ["4C", "8B", "E0", "EB", "03", "4D", "8B", "E7"], toks[:15])
    check("  the 10 stolen bytes at +15: vpxor xmm0,xmm0,xmm0 / vmovdqu [rsp+28h],xmm0",
          toks[15:25] == "C5 F9 EF C0 C5 FA 7F 44 24 28".split() and "Splice(mem, at + 15, 10, MaintCandidates)" in inst, toks[15:25])
    tail = " ".join(toks[-22:])
    check("  the loop's owner check on r12 at its end", tail == "4D 85 E4 74 15 8B 47 04 85 C0 0F 88 ?? ?? ?? ?? 41 3B 04 24 0F 85 ?? ?? ?? ??"[:len(tail)] or
          " ".join(toks).endswith("4D 85 E4 74 15 8B 47 04 85 C0 0F 88 ?? ?? ?? ?? 41 3B 04 24 0F 85 ?? ?? ?? ??"), tail)
    check("the splice clears r12 only for an open depot", "if (MtOpen(t, (i32)r->rbx, *(i32*)r->r12)) { r->r12 = 0;" in cand)
    check("  never without a table, nor with one of another load, nor when it says off",
          "if (!r->r12 || !g_mtHave) return;" in cand and "if (!t.on || t.loads != g_ctlLoads) return;" in cand
          and cand.index("t.loads != g_ctlLoads") < cand.index("MtOpen("))
    check("the getenv names start with \\1MPFM", "name[0] == 1 && name[1] == 'M' && name[2] == 'P' && name[3] == 'F' && name[4] == 'M'" in hook
          and "return g_getenvOrig ? g_getenvOrig(name) : 0;" in hook)
    check("the parser refuses counts out of bounds", 'if (nc < 0 || nc > MT_CO) return (char*)"bad";' in parse and 'if (nd < 0 || nd > MT_DEP) return (char*)"bad";' in parse)
    check("  and depots not sorted (binary search)", 'if (t.dep[i - 1][0] >= t.dep[i][0]) return (char*)"bad";' in parse)
    check("  a table written into the buffer not in use, marked to go in use", "long next = 1 - g_mtCur;" in parse and "g_mtPend = 1;" in parse
          and parse.index("t.loads = g_ctlLoads") < parse.index("g_mtPend = 1;") and "_InterlockedExchange(&g_mtCur" not in parse)
    start = block(src, "static void MaintIterStart()")
    check("  put in use only at the start of the next simulation iteration (the engine's lists came before the script's call in one "
          "session, after it in another)", "_InterlockedExchange(&g_mtCur, 1 - g_mtCur);" in start and "g_mtPend = 0;" in start
          and "    g_iter++;" + chr(10) + "    MaintIterStart();" + chr(10) in src)
    check("  nothing hooked without the pre-iteration hook (no table would ever go in use)", "u8* mem = (at && g_preIterOn) ? AllocNear(0x200) : 0;" in inst)
    check("  the question answers \"send\" for a table of another load, and \"same\" for the one given last (waiting or in use)",
          "const MaintTable& t = g_mt[g_mtPend ? 1 - g_mtCur : g_mtCur];" in parse and "bool same = (g_mtHave || g_mtPend) && t.tok == tok && t.loads == g_ctlLoads;" in parse)
    check("MtOpen: the depot's own setting first, then its company's rule, then the default",
          mtopen.index("t.dep[mid]") < mtopen.index("t.co[i]") < mtopen.index("return t.def != 0;"))
    check("getenv hooked in the game's imports", 'PatchImport(g_base, "api-ms-win-crt-environment-l1-1-0.dll", "getenv", (void*)&GetenvHook)' in inst)
    check("installed after the vehicles' wear", "    InstallVehicleWear();\n    InstallSharedMaint();\n" in src)
    check("its result logged", '"shared maintenance: "' in inst)

    if not os.path.exists(GAME):
        print("(the game is not installed here: its bytes not checked)")
    else:
        data = open(GAME, "rb").read()
        pat = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in toks)
        hits = [x.start() for x in re.finditer(pat, data, re.S)]
        if len(hits) != 1:
            print(f"(another game build: the signature matches {len(hits)} time(s), the module leaves the maintenance as it is)")
        else:
            h = hits[0]
            check("the game: the stolen bytes are the two instructions", data[h + 15:h + 25] == bytes.fromhex("C5F9EFC0C5FA7F442428"))
            # (the function's bounds from .pdata: r12 read nowhere else than the check)
            try:
                import pefile
                pe = pefile.PE(GAME, fast_load=True)
                text = [s for s in pe.sections if s.Name.rstrip(b"\0") == b".text"][0]
                rva = text.VirtualAddress + h - text.PointerToRawData
                pd = [s for s in pe.sections if s.Name.rstrip(b"\0") == b".pdata"][0]
                fb = fe = None
                for i in range(0, pd.Misc_VirtualSize - 11, 12):
                    b, e, _ = struct.unpack_from("<III", data, pd.PointerToRawData + i)
                    if b <= rva < e:
                        fb, fe = b, e
                        break
                check("the game: the place is inside a function of .pdata", fb is not None)
                if fb is not None:
                    import capstone
                    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
                    code = data[fb - text.VirtualAddress + text.PointerToRawData: fe - text.VirtualAddress + text.PointerToRawData]
                    uses = [(i.address, i.mnemonic, i.op_str) for i in md.disasm(code, fb) if "r12" in i.op_str]
                    others = [u for u in uses if u[1] not in ("push", "pop") and u[0] not in (rva + 7, rva + 12, rva + 85, rva + 101)]
                    check("the game: r12 is read nowhere else in the function than in that check", not others, others)
            except ImportError:
                print("(pefile or capstone missing: the function's uses of r12 not checked)")
            imp = data.find(b"api-ms-win-crt-environment-l1-1-0.dll")
            check("the game imports from api-ms-win-crt-environment-l1-1-0.dll", imp >= 0)
            check("  getenv among its names", data.find(b"\x00getenv\x00") >= 0)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
