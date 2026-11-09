"""Test of the crash summary a report carries in place of the game's crash dump (0.7.15, #174; launcher/CrashSummary.cs,
launcher/Reporter.cs, launcher/SelfTest.cs, docs/PRIVACY.txt).

Since 0.7.13 a report never carries the game's crash dump (the game's memory: addresses, Steam numbers; Cowboy Pilot,
2026-11-09). hluki's crash (#174) then came with no trace of where the game stopped. The launcher now reads the dump on the
player's PC and puts a summary in the report (game/crash_summary.txt): the error's code and kind, the thread, where the error
came as module+offset, and up the crashed thread's stack the values that point into a module (the likely return addresses);
no memory content, no address outside a module, no path, no account number. The dump itself still never goes.
  - CrashSummary reads the minidump's streams: the module list (4), the exception (6: code, address, an access violation's
    kind and address, the context's rsp/rip at 0x98/0xF8) and the thread list (3: the crashed thread's stack);
  - Reporter.Collect waits for the dump to be written, makes the summary only when the dump stays out (MPFEVER_CRASHSUMMARY=0:
    none, as in 0.7.13), and the report's "Left out" note says where the summary is;
  - the selftest (MPFever.exe --selftest, SelfTest.RunCrashSummary0715) makes one from a minidump it writes;
  - the same reading, done here in Python on the same kind of minidump, gives the same places.
Run: python tests/test_crashsummary0715.py
"""
import os, re, struct, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


cs = read("launcher", "CrashSummary.cs")
check("BitConverter.ToUInt32(d, 0) != 0x504D444D" in cs and "streams.TryGetValue(4, out var ml)" in cs
      and "streams.TryGetValue(6, out var ex)" in cs and "streams.TryGetValue(3, out var tl)" in cs,
      "CrashSummary: a minidump's module list, exception and thread list")
check("uint o = ml.rva + 4 + 108 * i;" in cs and "uint o = tl.rva + 4 + 48 * i;" in cs and "U32(d, ex.rva + 8 + 152 + 4)" in cs
      and "U64(d, ctxRva + 0x98), rip = U64(d, ctxRva + 0xF8)" in cs,
      "  the minidump's sizes: a module 108 bytes, a thread 48, the context after the 152-byte record; rsp/rip of an x64 context")
check("m.Name = name.Substring(name.LastIndexOfAny(new[] { '\\\\', '/' }) + 1);" in cs, "  a module by its file name only (no folder)")
check('if (w == null || w.EndsWith("+0x0", StringComparison.Ordinal)) continue;' in cs and "shown < 48" in cs,
      "  only the stack's values inside a module (not a module's start), 48 at most")
check('" outside the game\'s parts"' in cs and "at < 0x10000" in cs, "  an access violation's address only as module+offset, or near 0")

rep = read("launcher", "Reporter.cs")
i = rep.find("public static string Collect(")
body = rep[i:rep.find("using (var z = ZipFile.Open(zip, ZipArchiveMode.Create))", i)]
check('Private(dmp) && Environment.GetEnvironmentVariable("MPFEVER_CRASHSUMMARY") != "0"' in body
      and "(!Private(dmp) || withSummary)" in body and "WaitWritten(dmp, 15)" in body,
      "Reporter: the summary when the dump stays out, after the dump is written (MPFEVER_CRASHSUMMARY=0: none)")
check('var text = CrashSummary.Make(dmp);' in body and 'Add(tmp, "game/crash_summary.txt");' in body,
      "  in the report as game/crash_summary.txt")
check("what it says of the crash is in game/crash_summary.txt" in rep, "  the report's note on the dump says where the summary is")
check(re.search(r"static bool Private\(string name\)[\s\S]*?\.dmp", rep) is not None, "  the dump itself still never goes (Reporter.Private)")

st = read("launcher", "SelfTest.cs")
check("ok &= RunCrashSummary0715();" in st and "static bool RunCrashSummary0715()" in st and "CrashSummary.Make(d)" in st,
      "the selftest makes one from a minidump it writes")
pv = read("docs", "PRIVACY.txt")
check("Since 0.7.15, a crash summary made from that dump" in pv and "MPFEVER_CRASHSUMMARY=0" in pv, "PRIVACY.txt says what the summary holds")

# the same reading in Python, on a minidump laid out as the selftest's
B = 0x140000000
d = bytearray(1600)
def w32(o, v): struct.pack_into("<I", d, o, v)
def w64(o, v): struct.pack_into("<Q", d, o, v)
w32(0, 0x504D444D); w32(8, 3); w32(12, 32)
w32(32, 4); w32(36, 112); w32(40, 68); w32(44, 6); w32(48, 168); w32(52, 400); w32(56, 3); w32(60, 52); w32(64, 1300)
w32(68, 1); w64(72, B); w32(80, 0x5000000); w32(92, 180)
nm = "C:\\Users\\Someone\\Games\\TransportFever3.exe".encode("utf-16-le"); w32(180, len(nm)); d[184:184 + len(nm)] = nm
w32(400, 7); w32(408, 0xC0000005); w64(424, B + 0x1234); w32(432, 2); w64(448, 0x10); w32(560, 0x4D0); w32(564, 700)
w64(700 + 0x98, 0x1000000 + 16); w64(700 + 0xF8, B + 0x1234)
w32(1300, 1); w32(1304, 7); w64(1328, 0x1000000); w32(1336, 64); w32(1340, 1400)
for k, v in enumerate([B + 0x9999, 0, B + 0x2000, 0x12345, B + 0x3000, B, 0, B + 0x4ABC]):
    w64(1400 + 8 * k, v)
n, dr = struct.unpack_from("<II", d, 8)
streams = {}
for k in range(n):
    t, size, rva = struct.unpack_from("<III", d, dr + 12 * k)
    streams[t] = rva
mods = []
cnt, = struct.unpack_from("<I", d, streams[4])
for k in range(cnt):
    o = streams[4] + 4 + 108 * k
    base, size = struct.unpack_from("<QI", d, o)
    nr, = struct.unpack_from("<I", d, o + 20); ln, = struct.unpack_from("<I", d, nr)
    mods.append((base, size, bytes(d[nr + 4:nr + 4 + ln]).decode("utf-16-le").split("\\")[-1]))
def where(a):
    for b, s, name in mods:
        if b <= a < b + s:
            return "%s+0x%x" % (name, a - b)
er = streams[6]
tid, = struct.unpack_from("<I", d, er); code, = struct.unpack_from("<I", d, er + 8); addr, = struct.unpack_from("<Q", d, er + 24)
ctx, = struct.unpack_from("<I", d, er + 8 + 152 + 4); rsp, = struct.unpack_from("<Q", d, ctx + 0x98)
o = streams[3] + 4
start, size, mem = struct.unpack_from("<QII", d, o + 24)
hits = [where(struct.unpack_from("<Q", d, mem + p)[0]) for p in range((rsp - start) & ~7, size, 8)]
hits = [h for h in hits if h and not h.endswith("+0x0")]
check(code == 0xC0000005 and where(addr) == "TransportFever3.exe+0x1234" and hits == ["TransportFever3.exe+0x2000",
      "TransportFever3.exe+0x3000", "TransportFever3.exe+0x4abc"], "the same layout read in Python: the selftest's expected places")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
