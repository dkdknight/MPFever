"""Offline test of the vehicles' wear for every company (0.6.9, InstallVehicleWear in native/mpfever_native.cpp).

A Discord report, then the stress test of 2026-11-02 (probe m3, Test Gameplay, one company per player): the other company's
vehicles never wore (156 of them, buses, trucks, trains, ships and planes, at 100 % for years), the savegame company's did.
The engine's maintenance update (TransportVehicleSystem, build 40425 at 0xb837f0) wears a vehicle's parts only when its
PlayerOwned owner is the system's player ([system+0x2c], the savegame's company); the native module takes that comparison's
jne out, so every vehicle with an owner wears, alike on every game. Cases:
  - the module's signature, the offset of the jne and the bytes it checks (75 0C) and writes (90 90);
  - MPFEVER_ALLWEAR=0 leaves the game as it is; the install is called with the other fixes;
  - with the game installed (build 40425): the signature matches exactly once, the jne is there and the instructions are the
    ones read with Ghidra (the owner read, the comparison, the wear flag set right after); another build is only reported.
Run: python tests/test_vehiclewear.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.join(HERE, "..", "native", "mpfever_native.cpp")
GAME = os.path.join(HERE, "..", "..", "TransportFever3.exe")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def main():
    src = open(NATIVE, encoding="utf-8").read()
    m = re.search(r"^static void InstallVehicleWear\(\)\n\{\n.*?^\}\n", src, re.S | re.M)
    check("InstallVehicleWear found", m is not None)
    if not m:
        return 1
    body = m.group(0)
    sig = re.search(r'FindSigRva\("([0-9A-F? ]+)"\)', body)
    check("it finds its place by a signature", sig is not None)
    sig = sig.group(1) if sig else ""
    toks = sig.split()
    off = re.search(r"g_base \+ at \+ (\d+)", body)
    off = int(off.group(1)) if off else -1
    check("the patched place is the jne of the signature (75 0C)", 0 <= off < len(toks) - 1 and toks[off] == "75" and toks[off + 1] == "0C", (off, toks[off:off + 2]))
    check("it checks those bytes before it writes", "site[0] == 0x75 && site[1] == 0x0C" in body)
    check("and writes two nops", "site[0] = 0x90; site[1] = 0x90;" in body)
    check("MPFEVER_ALLWEAR=0 leaves the game as it is", 'GetEnvironmentVariableA("MPFEVER_ALLWEAR", v, 3) > 0 && v[0] == \'0\'' in body
          and body.index("MPFEVER_ALLWEAR") < body.index("FindSigRva"))
    check("the install is called with the other fixes", "    InstallVehicleWear();\n" in src)
    check("its result is logged", '"vehicle wear: "' in body)

    if not os.path.exists(GAME):
        print("(the game is not installed here: its bytes not checked)")
    else:
        data = open(GAME, "rb").read()
        pat = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in toks)
        hits = [x.start() for x in re.finditer(pat, data, re.S)]
        if len(hits) != 1:
            print(f"(another game build: the signature matches {len(hits)} time(s), the module leaves the wear as it is)")
        else:
            h = hits[0]
            check("the game: the owner read and the comparison before the jne (mov ecx,[r14+2Ch]; cmp [rax],ecx)",
                  data[h + 15:h + 21] == bytes([0x41, 0x8B, 0x4E, 0x2C, 0x39, 0x08]))
            check("the game: the wear flag set right after (mov byte [rsp+32h],1)", data[h + 23:h + 28] == bytes([0xC6, 0x44, 0x24, 0x32, 0x01]))
            check("the game: no owner still means no wear (je before the read)", data[h + 13] == 0x74)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
