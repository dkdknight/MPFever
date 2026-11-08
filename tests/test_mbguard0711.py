"""Test of #152's fix (0.7.11): the module builder lets its construction go when another player's build removed it, instead of
the game stopping on "Assertion `m_entity.GetId() < 0 || (EntityExists(m_entity) && HasComponent(m_entity, Construction))'
failed" (UI/Actions/ModuleBuilder.cpp:268, Pascal's game 2026-11-08 17:48, a station open in the module editor while janik's
build was replayed).

The module builder (UI::ModuleBuilder) keeps the construction it edits at +0x118 and the game state at +0xc0; four of its
functions read it, then ask the engine (EntityExists 0x4f7fa0, HasComponent 0x2bc2ad0 on 40425) and stop the game when it is
gone. The native module splices those four reads (native/mpfever_native.cpp, InstallModuleBuilderGuard): a construction that
no longer exists, or whose id is now another entity's, is set to -1, the tool's own "no construction" state, which the game
accepts. MPFEVER_MBGUARD=0: not hooked.

Checked here: the four signatures are unique in the game's code and lead to the same engine functions (when the game's exe
is next to the repository, as on the developer's PC; else skipped), and the native code's shape.
Run: python tests/test_mbguard0711.py
"""
import os
import re
import struct
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
nat = open(os.path.join(ROOT, "native", "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" else ""))
    if not cond:
        fails.append(name)


m = re.search(r"static void InstallModuleBuilderGuard\(\)\n\{.*?\n\}\n", nat, re.S)
check(m is not None, "InstallModuleBuilderGuard found")
body = m.group(0) if m else ""
sigs = re.findall(r'\{ "([0-9A-F? ]+)", (\d+), (\d+) \}', body)
check(len(sigs) == 4, "four sites", len(sigs))
check('GetEnvironmentVariableA("MPFEVER_MBGUARD"' in body, "MPFEVER_MBGUARD=0: not hooked")
g = re.search(r"static void ModuleBuilderGuard\(SavedRegs\* r\)\n\{.*?\n\}\n", nat, re.S)
gb = g.group(0) if g else ""
check("*(i32*)(self + 0x118) = -1;" in gb and "if (id < 0) return;" in gb and "g_mbExists(eng, id) && g_mbHas(eng, id, &g_mbConType)" in gb,
      "the guard: an existing construction kept, a gone one (or an id now another entity's) set to -1")
check("InstallModuleBuilderGuard();" in nat, "installed at the module's start")

exe = os.path.join(ROOT, "..", "TransportFever3.exe")
if not os.path.isfile(exe):
    print("the game's exe is not next to the repository: the signature part skipped")
else:
    d = open(exe, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    opt = struct.unpack_from("<H", d, pe + 20)[0]
    sh = pe + 24 + opt
    text = None
    for i in range(nsec):
        name, vs, va, rs, ro = struct.unpack_from("<8sIIII", d, sh + 40 * i)
        if name.startswith(b".text"):
            text = (va, ro, rs)
    va, ro, rs = text
    blob = d[ro:ro + rs]

    def find(sig):
        rx = b"".join(b"." if t == "??" else re.escape(bytes([int(t, 16)])) for t in sig.split())
        return [va + x.start() for x in re.finditer(rx, blob, re.S)]

    def call_target(rva):
        o = ro + rva - va
        assert d[o] == 0xE8
        return rva + 5 + struct.unpack_from("<i", d, o + 1)[0]

    exists = set()
    for sig, off, steal in sigs:
        hits = find(sig)
        check(len(hits) == 1, f"signature unique: {sig[:40]}...", len(hits))
        if len(hits) == 1:
            site = hits[0] + int(off)
            o = ro + site - va
            # the stolen bytes read +0x118 (mov edx,[rcx+118h] or lea rdi,[rcx+118h])
            check(d[o:o + int(steal)] in (bytes.fromhex("8b9118010000"), bytes.fromhex("488db918010000")), f"  stolen bytes at {site:#x} read +0x118")
            e8 = hits[0] + sig.split().index("E8")
            exists.add(call_target(e8))
    check(len(exists) == 1, "  all four call the same EntityExists", [hex(x) for x in exists])
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
