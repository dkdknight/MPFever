using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace MPFever
{
    /// <summary>(0.7.15, #174) What a crash dump says of the crash, without the dump. Since 0.7.13 a report never carries the game's
    /// crash dump (its memory: addresses, Steam numbers, Cowboy Pilot): hluki's crash of 2026-11-09 came without it and its place
    /// in the game's code could not be told. The summary reads from the dump only: the error code, the thread, where the error
    /// came (a module's file name and the offset in it) and, up the crashed thread's stack, the values that point into a module
    /// (the likely return addresses, as module+offset). No memory content, no address outside a module, no path (file names
    /// only), no account number. MPFEVER_CRASHSUMMARY=0: none, as in 0.7.13.</summary>
    static class CrashSummary
    {
        sealed class Mod { public ulong Base; public uint Size; public string Name; }

        /// <summary>The summary of the dump at that path, or null (no dump, not a minidump, unreadable).</summary>
        public static string Make(string path)
        {
            try
            {
                var fi = new FileInfo(path);
                if (!fi.Exists || fi.Length < 64 || fi.Length > (1L << 31)) return null;
                return Make(File.ReadAllBytes(path));
            }
            catch { return null; }
        }

        public static string Make(byte[] d)
        {
            try
            {
                if (d == null || d.Length < 32 || BitConverter.ToUInt32(d, 0) != 0x504D444D) return null;   // "MDMP"
                uint n = U32(d, 8), dir = U32(d, 12);
                var streams = new Dictionary<uint, (uint size, uint rva)>();
                for (uint i = 0; i < n && i < 512; i++)
                {
                    uint o = dir + 12 * i;
                    uint type = U32(d, o);
                    if (!streams.ContainsKey(type)) streams[type] = (U32(d, o + 4), U32(d, o + 8));
                }
                var mods = new List<Mod>();
                if (streams.TryGetValue(4, out var ml))                            // ModuleListStream
                {
                    uint nm = U32(d, ml.rva);
                    for (uint i = 0; i < nm && i < 4096; i++)
                    {
                        uint o = ml.rva + 4 + 108 * i;
                        var m = new Mod { Base = U64(d, o), Size = U32(d, o + 8) };
                        uint nr = U32(d, o + 20), ln = U32(d, nr);
                        if (ln > 2048 || nr + 4 + ln > d.Length) continue;
                        var name = Encoding.Unicode.GetString(d, (int)nr + 4, (int)ln);
                        m.Name = name.Substring(name.LastIndexOfAny(new[] { '\\', '/' }) + 1);
                        mods.Add(m);
                    }
                }
                string Where(ulong a)
                {
                    foreach (var m in mods)
                        if (a >= m.Base && a - m.Base < m.Size) return m.Name + "+0x" + (a - m.Base).ToString("x", CultureInfo.InvariantCulture);
                    return null;
                }
                var sb = new StringBuilder();
                sb.Append("Crash summary (made from the game's crash dump, which is not sent: no memory, no address outside the game's parts)\r\n");
                if (!streams.TryGetValue(6, out var ex))                           // ExceptionStream
                {
                    sb.Append("no error recorded in the dump\r\n");
                    return sb.ToString();
                }
                uint tid = U32(d, ex.rva);
                uint code = U32(d, ex.rva + 8);
                ulong addr = U64(d, ex.rva + 24);
                uint np = U32(d, ex.rva + 32);
                uint ctxRva = U32(d, ex.rva + 8 + 152 + 4);
                ulong rsp = U64(d, ctxRva + 0x98), rip = U64(d, ctxRva + 0xF8);
                sb.Append("error 0x").Append(code.ToString("x8", CultureInfo.InvariantCulture)).Append(" (").Append(CodeName(code)).Append(")");
                // (an access violation's kind: read 0, write 1, execute 8; its address only when it is in a module)
                if (code == 0xC0000005 && np >= 2)
                {
                    ulong kind = U64(d, ex.rva + 40), at = U64(d, ex.rva + 48);
                    sb.Append(kind == 1 ? ", writing" : kind == 8 ? ", executing" : ", reading");
                    var w = Where(at);
                    sb.Append(w != null ? " " + w : at < 0x10000 ? " near address 0 (0x" + at.ToString("x", CultureInfo.InvariantCulture) + ")" : " outside the game's parts");
                }
                sb.Append("\r\nat ").Append(Where(addr) ?? Where(rip) ?? "(outside the game's parts)").Append("\r\n");
                if (streams.TryGetValue(3, out var tl))                            // ThreadListStream
                {
                    uint nt = U32(d, tl.rva);
                    for (uint i = 0; i < nt && i < 8192; i++)
                    {
                        uint o = tl.rva + 4 + 48 * i;
                        if (U32(d, o) != tid) continue;
                        ulong start = U64(d, o + 24);
                        uint size = U32(d, o + 32), mem = U32(d, o + 36);
                        if (mem + (ulong)size > (ulong)d.Length) break;
                        ulong from = (rsp >= start && rsp - start < size) ? (rsp - start) & ~7UL : 0;
                        int shown = 0;
                        sb.Append("stack (values that point into the game's parts, from the crash up):\r\n");
                        for (ulong p = from; p + 8 <= size && shown < 48; p += 8)
                        {
                            var w = Where(U64(d, (uint)(mem + p)));
                            if (w == null || w.EndsWith("+0x0", StringComparison.Ordinal)) continue;
                            sb.Append("  ").Append(w).Append("\r\n");
                            shown++;
                        }
                        break;
                    }
                }
                return sb.ToString();
            }
            catch (Exception e) { return "Crash summary: the dump could not be read (" + e.GetType().Name + ")\r\n"; }
        }

        static string CodeName(uint c)
        {
            switch (c)
            {
                case 0xC0000005: return "access violation";
                case 0xC0000374: return "heap corruption";
                case 0xC0000409: return "stack buffer overrun / fast fail";
                case 0xC00000FD: return "stack overflow";
                case 0xC0000025: return "non-continuable exception (the game closing after an error)";
                case 0x80000003: return "breakpoint";
                case 0xE06D7363: return "C++ exception";
                default: return "other";
            }
        }

        static uint U32(byte[] d, ulong o) => o + 4 <= (ulong)d.Length ? BitConverter.ToUInt32(d, (int)o) : throw new InvalidDataException();
        static ulong U64(byte[] d, ulong o) => o + 8 <= (ulong)d.Length ? BitConverter.ToUInt64(d, (int)o) : throw new InvalidDataException();
    }
}
