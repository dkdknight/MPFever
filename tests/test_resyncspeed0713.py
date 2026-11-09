"""Test of the resynchronisation speed-ups of #161/#166 (0.7.13, launcher/MainForm.cs, Core.cs, Zstd.cs).

yoyo, YkeWoudstra and Bence, 2026-11-08 (reports r161, r166): each resynchronisation of a 274 MB savegame took 2 to 5.5 minutes,
until the slowest PC's game had loaded it (248 s on a PC of 16 GB whose game ran half in the page file), while the launcher kept
2.5 to 2.9 GB of arrays it no longer used, never collected. The host worked the differences out after its save (its base
decompressed, then the new savegame, then both compared: 9 s), and a player read and decompressed its base only once the last
part of the differences had come (6 to 15 s), its 948 MB file read whole and then copied whole by the decoder.
Now:
  A. MPFEVER_RESYNCGC: the big arrays are dropped and collected once used (FreeResyncMemory, never inside a lock); the memory is
     logged (the launcher's and the PC's free RAM; the game's at each order to reload and each game ready).
  B. MPFEVER_DELTAPREREAD: a player's base is read while the differences arrive, with Zstd.ReadSaveRaw (a file MPFever wrote
     without compression straight into one array, anything else decompressed as before).
  C. MPFEVER_DELTAEARLY: the host decompresses its base from the start of the resynchronisation (used only when it is still the
     base compared with), and the new savegame at the same time.
Each =0: as before. Zstd.ReadSaveRaw (raw and real zstd frames, look-alikes), SaveDelta.Apply on its result and FreeResyncMemory
run in the selftest (SelfTest.RunResyncSpeed0713). The order of ResyncLocked is unchanged (docs/REGRESSIONS.md).
Run: python tests/test_resyncspeed0713.py
"""
import base64
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*parts):
    return open(os.path.join(ROOT, *parts), encoding="utf-8-sig").read().replace("\r\n", "\n")


mf = read("launcher", "MainForm.cs")
core = read("launcher", "Core.cs")
zs = read("launcher", "Zstd.cs")
st = read("launcher", "SelfTest.cs")
reg = read("docs", "REGRESSIONS.md")
lang = json.loads(read("launcher", "lang.json"))["texts"]
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def method(src, sig):
    """A method of 8 spaces' indentation, from its signature to its closing brace."""
    i = src.index(sig)
    j = src.index("\n        {\n", i)
    return src[i:src.index("\n        }\n", j) + 10]


def code_only(s):
    """s with its comments and the insides of its string and char literals blanked (same length, same places)."""
    out, k, n = list(s), 0, len(s)

    def blank(i, j):
        for x in range(i, j):
            if out[x] != "\n":
                out[x] = " "
    while k < n:
        c = s[k]
        if s.startswith("//", k):
            e = s.find("\n", k)
            e = n if e < 0 else e
            blank(k, e)
            k = e
        elif c == '"' or (c in "@$" and s[k + 1:k + 2] == '"'):
            verbatim = c == "@"
            k += 1 if c == '"' else 2
            start = k
            while k < n:
                if verbatim and s[k:k + 2] == '""':
                    k += 2
                elif s[k] == '"':
                    break
                elif s[k] == "\\" and not verbatim:
                    k += 2
                else:
                    k += 1
            blank(start, k)
            k += 1
        elif c == "'":
            e = k + (3 if s[k + 1] == "\\" else 2)
            while e < n and s[e] != "'":
                e += 1
            blank(k + 1, e)
            k = e + 1
        else:
            k += 1
    return "".join(out)


def statement_end(s, k):
    """The end of the statement starting at s[k] (code_only text): its closing brace when it is a block, else its ';' outside
    brackets."""
    depth, block = 0, s[k] == "{"
    while k < len(s):
        c = s[k]
        if c in "({[":
            depth += 1
        elif c in ")}]":
            depth -= 1
            if block and depth == 0:
                return k
        elif c == ";" and depth == 0 and not block:
            return k
        k += 1
    return k


def in_lock(body, pos):
    """Whether body[pos] is inside a lock (...) statement of body."""
    code = code_only(body)
    for m in re.finditer(r"\block \(", code):
        if m.start() > pos:
            break
        k, depth = m.end() - 1, 0
        while True:
            depth += {"(": 1, ")": -1}.get(code[k], 0)
            if depth == 0:
                break
            k += 1
        k += 1
        while code[k] in " \n":
            k += 1
        if k <= pos <= statement_end(code, k):
            return True
    return False


def order(text, *parts):
    """Each part found after the one before it."""
    at = 0
    for p in parts:
        at = text.find(p, at)
        if at < 0:
            return False
        at += len(p)
    return True


# (the lock check itself, on a few shapes)
_t = "a(); lock (g) { x(); FreeResyncMemory(\"in\"); } lock (g) y = z.Where(n => n != \"}\").ToArray(); FreeResyncMemory(\"out\");"
check(in_lock(_t, _t.index('FreeResyncMemory("in")')) and not in_lock(_t, _t.index('FreeResyncMemory("out")')), "(the lock check tells inside from outside)")

# ---- the switches
for sw, fn in (("MPFEVER_RESYNCGC", "ResyncGcOn"), ("MPFEVER_DELTAPREREAD", "DeltaPreReadOn"), ("MPFEVER_DELTAEARLY", "DeltaEarlyOn")):
    check(f'internal static bool {fn}() => Environment.GetEnvironmentVariable("{sw}") != "0";' in mf, f"{sw}=0: as before (on by default)")

# ---- A. RESYNCGC
fr = method(mf, "internal static long FreeResyncMemory(string where)")
check("bool on = ResyncGcOn();" in fr and "if (on) { GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect(); }" in fr,
      "A. FreeResyncMemory collects only when MPFEVER_RESYNCGC is not 0")
check(order(fr, "if (on) {", 'Log.Dim("memory (" + where + "): " + b + " -> " + MemText(after));') and "return on ? before - after : -1;" in fr,
      "  the memory before and after logged either way; -1 when nothing was collected")
check("LargeObjectHeapCompactionMode" not in mf and mf.count("GC.Collect(") == 2 and "GC.Collect(" not in core,
      "  no compaction of the large objects; nothing else collects")
check(fr.index("try") < fr.index("LauncherPrivateMb()") and "catch { return -1; }" in fr, "  it never throws (its callers would ask for the whole game again)")
mem = method(mf, "static string MemText(long privateMb)")
check("GlobalMemoryStatusEx(ref m)" in mem and '"RAM free " + (m.AvailPhys >> 20) + " of " + (m.TotalPhys >> 20) + " MB"' in mem
      and "p.PrivateMemorySize64 >> 20" in mf, "  the line: the launcher's private memory, the PC's free RAM")

od = method(mf, "void OnDeltaFile(GameLink game, Client client, string me, Msg m)")
ors = method(mf, "void OnResyncFile(GameLink game, Msg m)")
ou = method(mf, "void OnResyncUse(GameLink game, Client client, string me, Msg m)")
sd = method(mf, "void SendDeltas(int id, byte[] bytes, string sha, HashSet<string> names")
check(order(od, "LoadReceivedSave(game, m, id, null, sha, newRaw);", "newRaw = null; baseRaw = null; delta = null; got = null;", 'FreeResyncMemory("differences applied");', "catch (Exception e)"),
      "A. a player, differences applied: base, differences and new savegame dropped, then collected, after the load order")
check(order(ors, "LoadReceivedSave(game, m, id, all, sha);", "all = null; got = null;", 'FreeResyncMemory("game received");'),
      "  a player, whole game received: the game and its parts dropped, then collected")
check(order(ou, "LoadReceivedSave(game, m, id, bytes, sha);", "bytes = null;", 'FreeResyncMemory("own copy loaded");', "return;"),
      "  a player, its own copy: dropped, then collected")
check(order(sd, "byte[] baseRaw = null, newRaw = null;", "try", 'catch (Exception e) { Log.W("differences: " + e.Message); delta = null; }',
            "baseRaw = newRaw = null; baseEarly = null;", 'FreeResyncMemory("differences made");', "SendSave(id, bytes, sha, names);", "foreach (var peer in want)"),
      "  the host: both decompressed savegames (and the early base's task) dropped after the comparison, collected before the sending")
calls = [(name, body) for name, body in (("OnDeltaFile", od), ("OnResyncFile", ors), ("OnResyncUse", ou), ("SendDeltas", sd))]
check(all(not in_lock(body, body.index("FreeResyncMemory(")) for _, body in calls), "  never inside a lock")
check(mf.count("FreeResyncMemory(\"") == 4 and len(re.findall(r"\bFreeResyncMemory\(", mf)) == 5, "  nowhere else (4 calls)")
check("resyncBytes = bytes;" in mf and "resyncBytes = null" not in mf, "  the host's savegame kept for the players back after a cut (resync_have)")

lm = core[core.index("        void LogMemory()\n"):core.index("        sealed class Tail : IDisposable")]
check(order(lm, "if ((DateTime.UtcNow - memAt).TotalMinutes < 5) return;", "memAt = DateTime.UtcNow;", "LogMemoryNow(null);")
      and '"[{0}] game memory: {1} MB private, {2} MB in RAM (peak {3} MB)"' in lm
      and '(why != null ? " (" + why + "; " + MainForm.MemNow() + ")" : "")' in lm, "A. the game's memory every 5 minutes as before, now also with why")
hl = mf.index('hostGame.ToGame(Msg.Make("resync_load", hostName,')
check(mf.index('hostGame.LogMemoryNow("resync load");', hl) - hl < 300, "  the host's game's memory at its order to reload")
cl = mf.index('game.ToGame(Msg.Make("resync_load", m.From,')
check(mf.index('game.LogMemoryNow("resync load");', cl) - cl < 300, "  a player's game's memory at its order to reload")
h = mf.index('case "hello":')
check('ThreadPool.QueueUserWorkItem(_ => hg.LogMemoryNow("game ready"))' in mf[h:mf.index("break;", h)] and 'ThreadPool.QueueUserWorkItem(_ => g.LogMemoryNow("game ready"))' in mf,
      "  each game's memory once ready (host and players), aside from the game's messages")

# ---- B. DELTAPREREAD
lk = od[od.index("lock (deltaParts)"):od.index("if (StopIfModsDiffer(game)) return;")]
newid = lk[lk.index("if (!deltaParts.TryGetValue(id, out got) || got.Length != n)\n                {"):lk.index("got[i] = m.Data;")]
check(order(newid, "deltaParts[id] = got = new byte[n][];",
            "if (DeltaPreReadOn() && bsha != null && bsha == lastSaveSha && lastSavePath != null && File.Exists(lastSavePath))",
            "deltaPre = new DeltaPreRead { Id = id, SavePath = file, Read = System.Threading.Tasks.Task.Run(() => Zstd.ReadSaveRaw(file)) };"),
      "B. the base read from the first part of new differences (under lock (deltaParts)), only when from this PC's base")
check(mf.count("deltaPre = new DeltaPreRead") == 1, "  nowhere else")
ap = od[od.index("new Thread(() =>"):]
check(order(ap, 'throw new InvalidDataException("not the base this PC has")', "var baseRaw = DeltaPreReadOn() ? PreReadBase(id) : Zstd.DecompressFile(lastSavePath);",
            "SaveDelta.Apply(baseRaw, delta)", "LoadReceivedSave(game, m, id, null, sha, newRaw);"),
      "  applied: the base checked first, then taken (MPFEVER_DELTAPREREAD=0: decompressed now, as before)")
cat = ap[ap.index("catch (Exception e)"):]
check(order(cat, 'differences not usable ({1}): asking the host for the whole game.', 'Msg.Make("resync_need", me,', "DropPreRead();"),
      "  differences not usable: the whole game asked for, as before (then the base read for them let go)")
pr = method(mf, "byte[] PreReadBase(int id)")
check("lock (deltaParts) { pre = deltaPre; deltaPre = null; }" in pr and order(pr, "var b = pre.Read.GetAwaiter().GetResult();", "if (pre.Id == id && pre.SavePath == path)", "return b;", "return Zstd.ReadSaveRaw(path);"),
      "  the base read beforehand used only for the same differences and file; else (or failed) read now")
dp = method(mf, "void DropPreRead()")
check("lock (deltaParts) { pre = deltaPre; deltaPre = null; }" in dp and "pre.Read.Wait();" in dp, "  let go only once its reading is over")
check(order(ors, "DropPreRead();", "LoadReceivedSave(game, m, id, all, sha);") and order(ou, "DropPreRead();", "LoadReceivedSave(game, m, id, bytes, sha);"),
      "  never read while a whole game is written over it")
rs = zs[zs.index("public static byte[] ReadSaveRaw(string path)"):zs.index("static bool ReadFull(")]
check("content = ReadRawFrame(f);" in rs and "return content ?? DecompressFile(path);" in rs, "B. Zstd.ReadSaveRaw: anything but MPFever's raw frame decompressed as before")
check("h[4] != 0x80 || h[5] != 0x58" in rs and "if (type != 0 || n > BlockSizeMax || n > size - pos) return null;" in rs
      and "if (pos != size || f.Position != len) return null;" in rs and "len < 10 + size + 3" in rs,
      "  read straight only: WriteRawFrame's header, raw blocks, the size matched, nothing after; nothing allocated for a smaller file")
check("h[4] = 0x80;" in zs and "h[5] = 0x58;" in zs, "  the header WriteRawFrame writes")

# ---- C. DELTAEARLY
rl = mf[mf.index("void ResyncLocked(string reason)"):mf.index("void SendSave(int id, byte[] bytes, string sha, IEnumerable<string> names)")]
check(order(rl, "var baseEarly = EarlyDeltaBase(out string earlySha, out string earlyPath);", 'Pause(T("resynchronisation", "resynchronisation"));')
      and "SendDeltas(id, bytes, sha, viaDelta, Taken(ref baseEarly), earlySha, earlyPath);" in rl
      and "static T Taken<T>(ref T v) where T : class { var x = v; v = null; return x; }" in mf,
      "C. the host's base decompressed from the start, given to SendDeltas (nothing of ResyncLocked's keeps it)")
eb = method(mf, "System.Threading.Tasks.Task<byte[]> EarlyDeltaBase(out string sha, out string path)")
check(order(eb, "sha = deltaBaseSha; path = deltaBasePath;", "if (!DeltaEarlyOn() || sha == null || path == null) return null;",
            "lock (reviewing) names = names.Where(n => !reviewing.Contains(n)).ToArray();", "if (DeltaPeers(names).Count == 0) return null;",
            "return System.Threading.Tasks.Task.Run(() => Zstd.DecompressFile(file));")
      and 'catch (Exception e) { Log.W("differences\' base: " + e.Message); return null; }' in eb,
      "  only when a player may get the differences (DeltaPeers: MPFEVER_DELTA, the file there); never stops the resynchronisation")
check(order(sd, 'string baseSha = deltaBaseSha ?? "";', "if (DeltaEarlyOn())", "bool early = baseEarly != null && earlySha == baseSha && earlyPath == basePath;",
            "() => baseRaw = early ? baseEarly.GetAwaiter().GetResult() : Zstd.DecompressFile(basePath),", "() => newRaw = Zstd.Decompress(bytes));",
            "else\n                {\n                    baseRaw = Zstd.DecompressFile(deltaBasePath);\n                    newRaw = Zstd.Decompress(bytes);\n                }",
            "delta = SaveDelta.Make(baseRaw, newRaw);"),
      "  used only when its fingerprint and file are the base compared with; MPFEVER_DELTAEARLY=0: one after the other, as before")
check("ExceptionDispatchInfo.Capture(ae.Flatten().InnerExceptions[0]).Throw();" in sd, "  an error logged as before (not as 'One or more errors occurred')")
k = " (decompressing {0:0.0} s, comparing {1:0.0} s)"
check(f'F(" (décompression {{0:0.0}} s, comparaison {{1:0.0}} s)", "{k}"' in sd and k in lang and len([c for c in lang[k] if lang[k][c]]) == 11,
      "  the decompression and the comparison timed apart in the 'Differences' line (11 languages)")

# ---- the order of a resynchronisation (docs/REGRESSIONS.md)
check(order(rl, 'Pause(T("resynchronisation", "resynchronisation"));', "bool stopped = WaitUntil(", 'Msg.Make("resync_save"', "byte[] bytes = File.ReadAllBytes(file);",
            'hostGame.ToGame(Msg.Make("resync_load", hostName,', "SendSave(id, bytes, sha, all.Where(n => !viaDelta.Contains(n)));",
            "SendDeltas(id, bytes, sha, viaDelta,", "KeepDeltaBase(bytes, sha);", "bool back = WaitUntil(() => { if (resyncAbort) return true; lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);"),
      "the resynchronisation's order unchanged: pause, stop, save, read; the host reloads; whole games, differences, then the next base; the wait")
check(rl.count("resync_load") == 1 and "LuaLit.Quote(ResyncSaveName)" in rl[rl.index('"resync_save"'):rl.index('"resync_save"') + 200],
      "  the host reloads too; its session save has a name of its own")
check("| The **savegame played is never written** by MPFever: session saves have names of their own. |" in reg, "docs/REGRESSIONS.md: the savegame played is never written")

# ---- the selftest
check(re.search(r"ok &= RunDeadDirect0713\(\);(\s+ok &= Run\w+\(\);)*\s+ok &= RunResyncSpeed0713\(\);", st) is not None, "the selftest runs RunResyncSpeed0713")
rt = st[st.index("static bool RunResyncSpeed0713()"):st.index("static long Garbage0713(int count, int mb)")]
check(all(x in rt for x in ("Zstd.ReadSaveRaw(", "Zstd.DecompressFile(", "Zstd.ReadRawFrame(", "SaveDelta.Apply(Zstd.ReadSaveRaw(", "SaveDelta.Make(",
                            "Zstd.WriteRawFrame(", "Convert.FromBase64String(ZstdFrame0713)", "MainForm.FreeResyncMemory(", '"MPFEVER_RESYNCGC", "0"', "Garbage0713(3, 300);")),
      "  raw frames, a real zstd frame, look-alikes, the differences applied, the memory given back")
# (the selftest's real zstd frame: compressed blocks and a checksum, the content's size said: never read straight)
fr64 = "".join(re.findall(r'"([A-Za-z0-9+/=]+)"', st[st.index("const string ZstdFrame0713 ="):st.index(";", st.index("const string ZstdFrame0713 ="))]))
frame = base64.b64decode(fr64)
content = "".join("MPFever resync %d of %d\n" % (i % 50, i % 13) for i in range(10000)).encode()
types, p = [], 5 + 4
while True:
    bh = frame[p] | frame[p + 1] << 8 | frame[p + 2] << 16
    types.append((bh >> 1) & 3)
    p += 3 + (1 if (bh >> 1) & 3 == 1 else bh >> 3)
    if bh & 1:
        break
check(frame[:4] == b"\x28\xb5\x2f\xfd" and frame[4] == 0xA4 and int.from_bytes(frame[5:9], "little") == len(content) == 230307
      and types == [2, 2] and len(frame) == p + 4, "  its zstd frame: two compressed blocks, a checksum, the content's size")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
