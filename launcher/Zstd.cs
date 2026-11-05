using System;
using System.IO;
using System.Runtime.CompilerServices;

namespace MPFever
{
    // Zstandard (RFC 8878) decoder working on whole buffers, and a writer of uncompressed zstd frames.
    // Frames may follow each other (their contents are joined), skippable frames are skipped, dictionaries
    // are not supported. A frame's content checksum, when it has one, is verified.
    // Thread-safe: every call has its own decoder state; the shared tables are read-only.
    static class Zstd
    {
        const uint FrameMagic = 0xFD2FB528;
        const int BlockSizeMax = 128 * 1024;
        const int MaxArray = 0x7FFFFFC7;     // largest byte[] .NET allows

        public static byte[] DecompressFile(string path)
        {
            return Decompress(File.ReadAllBytes(path));
        }

        /// <summary>(0.7.0) The first bytes of a zstd file's content (at most maxOut, fewer when the content is shorter), decoded from
        /// the start of the file only: what a savegame says before its world (its mods list, see SaveInfo.Mods) without decompressing
        /// hundreds of MB. Throws when the file is not zstd data.</summary>
        public static byte[] DecompressHead(string path, int maxOut)
        {
            byte[] head;
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                // (zstd rarely compresses a savegame's first part more than 50:1; a block is at most 128 KiB of input)
                int want = (int)Math.Min(f.Length, Math.Max(1L << 20, (long)maxOut * 4 + 2 * BlockSizeMax));
                head = new byte[want];
                int got = 0, n;
                while (got < want && (n = f.Read(head, got, want - got)) > 0) got += n;
                if (got < want) Array.Resize(ref head, got);
            }
            if (head.Length < 4 || BitConverter.ToUInt32(head, 0) != FrameMagic) throw new InvalidDataException("Not zstd data.");
            return new Decoder(head) { HeadLimit = Math.Max(1, maxOut) }.RunHead();
        }

        public static byte[] Decompress(byte[] compressed)
        {
            if (compressed == null) throw new ArgumentNullException(nameof(compressed));
            try
            {
                return new Decoder(compressed).Run();
            }
            // reads past the end of the input or of a table: the data is damaged
            catch (IndexOutOfRangeException) { throw Corrupt(); }
            catch (ArgumentException) { throw Corrupt(); }
        }

        // Writes data as one zstd frame of raw (stored) blocks, which any zstd decoder reads back unchanged.
        // The header has the content size and a 2 MB window descriptor, like the game's own saves. No
        // single-segment flag: that would make the window the whole content (hundreds of MB), and streaming
        // decoders refuse windows above 128 MB by default.
        public static void WriteRawFrame(string path, byte[] data)
        {
            using (var f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
                WriteRawFrame(f, data);
        }

        public static void WriteRawFrame(Stream output, byte[] data)
        {
            if (output == null) throw new ArgumentNullException(nameof(output));
            if (data == null) throw new ArgumentNullException(nameof(data));
            var h = new byte[10];
            h[0] = 0x28; h[1] = 0xB5; h[2] = 0x2F; h[3] = 0xFD;
            h[4] = 0x80;    // frame header descriptor: 4-byte content size, no checksum, no dictionary
            h[5] = 0x58;    // window descriptor: 2 MB
            uint n = (uint)data.Length;
            h[6] = (byte)n; h[7] = (byte)(n >> 8); h[8] = (byte)(n >> 16); h[9] = (byte)(n >> 24);
            output.Write(h, 0, h.Length);
            var bh = new byte[3];
            int pos = 0;
            do
            {
                int len = Math.Min(BlockSizeMax, data.Length - pos);
                bool last = pos + len == data.Length;
                int v = (len << 3) | (last ? 1 : 0);    // block type 0: raw
                bh[0] = (byte)v; bh[1] = (byte)(v >> 8); bh[2] = (byte)(v >> 16);
                output.Write(bh, 0, 3);
                output.Write(data, pos, len);
                pos += len;
            } while (pos < data.Length);
        }

        static InvalidDataException Corrupt()
        {
            return new InvalidDataException("Corrupted zstd data.");
        }

        // ---- shared tables

        // literal length and match length codes: base value and number of extra bits
        static readonly int[] LLBase = {
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
            16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
            8192, 16384, 32768, 65536 };
        static readonly byte[] LLExtra = {
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
            13, 14, 15, 16 };
        static readonly int[] MLBase = {
            3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
            19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
            35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
            4099, 8195, 16387, 32771, 65539 };
        static readonly byte[] MLExtra = {
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
            12, 13, 14, 15, 16 };

        // predefined distributions (RFC 8878 3.1.1.3.2.2)
        static readonly short[] LLNorm = {
            4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
            2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
            -1, -1, -1, -1 };
        static readonly short[] MLNorm = {
            1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
            -1, -1, -1, -1, -1 };
        static readonly short[] OFNorm = {
            1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1 };

        const int KindLL = 0, KindOF = 1, KindML = 2;

        // (declared after the tables above: static fields are initialised in text order)
        static readonly ulong[] LLDefault = BuildDefault(KindLL, LLNorm, 6);
        static readonly ulong[] OFDefault = BuildDefault(KindOF, OFNorm, 5);
        static readonly ulong[] MLDefault = BuildDefault(KindML, MLNorm, 6);

        static ulong[] BuildDefault(int kind, short[] norm, int log)
        {
            int maxSym = norm.Length - 1;
            var n = new short[64];
            Array.Copy(norm, n, norm.Length);
            var sym = new byte[512]; var bits = new byte[512]; var state = new ushort[512];
            BuildFse(n, maxSym, log, new int[64], sym, bits, state);
            var t = new ulong[1 << log];
            for (int u = 0; u < t.Length; u++) t[u] = SeqEntry(kind, sym[u], bits[u], state[u]);
            return t;
        }

        // A sequence decoding table entry: bits 0-7 state bits, 8-15 extra bits of the value,
        // 16-31 base of the next state, 32-63 base of the value.
        static ulong SeqEntry(int kind, int sym, int stateBits, int nextState)
        {
            uint baseValue; int extra;
            if (kind == KindLL) { baseValue = (uint)LLBase[sym]; extra = LLExtra[sym]; }
            else if (kind == KindML) { baseValue = (uint)MLBase[sym]; extra = MLExtra[sym]; }
            else { baseValue = 1u << sym; extra = sym; }
            return (ulong)baseValue << 32 | (uint)nextState << 16 | (uint)extra << 8 | (uint)stateBits;
        }

        // ---- FSE

        // Reads an FSE table description (normalised counts); returns its size in bytes.
        static int ReadFseHeader(byte[] s, int p, int end, short[] norm, int maxSym, int maxLog, out int log)
        {
            int bit = 0;
            log = (int)PeekBits(s, p, end, bit, 4) + 5;
            bit += 4;
            if (log > maxLog) throw Corrupt();
            int remaining = (1 << log) + 1, threshold = 1 << log, nbBits = log + 1, sym = 0;
            while (remaining > 1)
            {
                if (sym > maxSym) throw Corrupt();
                int max = 2 * threshold - 1 - remaining;
                int v = (int)PeekBits(s, p, end, bit, nbBits);
                int count;
                if ((v & (threshold - 1)) < max) { count = v & (threshold - 1); bit += nbBits - 1; }
                else
                {
                    count = v & (2 * threshold - 1);
                    if (count >= threshold) count -= max;
                    bit += nbBits;
                }
                count--;    // -1: "less than 1" probability
                remaining -= count < 0 ? -count : count;
                norm[sym++] = (short)count;
                if (remaining < 1) throw Corrupt();
                if (count == 0)
                {
                    // 2-bit repeat flags: how many more symbols have a zero probability
                    int r;
                    do
                    {
                        r = (int)PeekBits(s, p, end, bit, 2);
                        bit += 2;
                        for (int i = 0; i < r; i++)
                        {
                            if (sym > maxSym) throw Corrupt();
                            norm[sym++] = 0;
                        }
                    } while (r == 3);
                }
                while (remaining < threshold) { nbBits--; threshold >>= 1; }
            }
            for (int i = sym; i <= maxSym; i++) norm[i] = 0;
            int bytes = (bit + 7) >> 3;
            if (bytes > end - p) throw Corrupt();
            return bytes;
        }

        // n (<= 24) bits at bit position 'bit' of the forward bit stream starting at p; bytes from 'end' on read as 0
        static uint PeekBits(byte[] s, int p, int end, int bit, int n)
        {
            int q = p + (bit >> 3);
            uint v = 0;
            for (int i = 0; i < 4; i++)
                if (q + i < end) v |= (uint)s[q + i] << (8 * i);
            return (v >> (bit & 7)) & ((1u << n) - 1);
        }

        // Builds an FSE decoding table: symbol, number of bits to read and base of the next state, per state.
        static void BuildFse(short[] norm, int maxSym, int log, int[] next, byte[] sym, byte[] bits, ushort[] state)
        {
            int size = 1 << log, high = size - 1;
            for (int s = 0; s <= maxSym; s++)
            {
                if (norm[s] == -1) { sym[high--] = (byte)s; next[s] = 1; }
                else next[s] = norm[s];
            }
            int step = (size >> 1) + (size >> 3) + 3, mask = size - 1, pos = 0;
            for (int s = 0; s <= maxSym; s++)
            {
                for (int i = 0; i < norm[s]; i++)
                {
                    sym[pos] = (byte)s;
                    do pos = (pos + step) & mask; while (pos > high);
                }
            }
            if (pos != 0) throw Corrupt();
            for (int u = 0; u < size; u++)
            {
                int s = sym[u];
                int ns = next[s]++;
                int nb = log - HighBit((uint)ns);
                bits[u] = (byte)nb;
                state[u] = (ushort)((ns << nb) - size);
            }
        }

        static int HighBit(uint v)
        {
            int r = 0;
            while ((v >>= 1) != 0) r++;
            return r;
        }

        // ---- backward bit streams (read from the end towards 'start')
        // c holds the 8 bytes at 'ptr'; 'used' counts the bits already taken from its top.

        static void InitReader(byte[] s, int start, int end, out int ptr, out ulong c, out int used)
        {
            if (end <= start) throw Corrupt();
            int last = s[end - 1];
            if (last == 0) throw Corrupt();     // the last byte holds the end mark
            int skip = 8 - HighBit((uint)last);
            if (end - start >= 8)
            {
                ptr = end - 8;
                c = BitConverter.ToUInt64(s, ptr);
                used = skip;
            }
            else
            {
                ptr = start;
                c = 0;
                for (int i = start; i < end; i++) c |= (ulong)s[i] << (8 * (i - start));
                used = skip + (8 - (end - start)) * 8;
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static void Reload(byte[] s, int start, ref int ptr, ref ulong c, ref int used)
        {
            if (ptr >= start + 8)
            {
                ptr -= used >> 3;
                used &= 7;
                c = BitConverter.ToUInt64(s, ptr);
            }
            else if (ptr > start)
            {
                int n = used >> 3;
                if (n > ptr - start) n = ptr - start;
                ptr -= n;
                used -= n << 3;
                c = BitConverter.ToUInt64(s, ptr);
            }
        }

        // next n (0..31) bits; the caller makes sure they are in the container
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        static int Bits(ulong c, ref int used, int n)
        {
            int v = (int)(((c << used) >> 1) >> (63 - n));
            used += n;
            return v;
        }

        // same, but bits past the start of the stream read as 0
        static int BitsSafe(ulong c, ref int used, int n)
        {
            int v = used >= 64 ? 0 : (int)(((c << used) >> 1) >> (63 - n));
            used += n;
            return v;
        }

        // Decodes one Huffman-coded literal stream into d[dp .. dp + count).
        static void DecodeHuffStream(byte[] s, int start, int end, byte[] d, int dp, int count, ushort[] table, int tableBits)
        {
            int ptr, used;
            ulong c;
            InitReader(s, start, end, out ptr, out c, out used);
            int shift = 64 - tableBits;
            int perReload = 57 / tableBits;     // after a reload at least 57 bits are available
            int dEnd = dp + count;
            while (dp < dEnd)
            {
                Reload(s, start, ref ptr, ref c, ref used);
                int stop = dp + perReload;
                if (stop > dEnd) stop = dEnd;
                while (dp < stop)
                {
                    int e = table[(int)((c << used) >> shift)];
                    d[dp++] = (byte)e;
                    used += e >> 8;
                }
            }
            if (ptr != start || used != 64) throw Corrupt();
        }

        // ---- xxHash64 (frame content checksum; SaveDelta uses it too)

        const ulong P1 = 11400714785074694791UL, P2 = 14029467366897019727UL, P3 = 1609587929392839161UL,
            P4 = 9650029242287828579UL, P5 = 2870177450012600261UL;

        static ulong Rotl(ulong x, int r) { return (x << r) | (x >> (64 - r)); }
        static ulong Round(ulong acc, ulong v) { return Rotl(acc + v * P2, 31) * P1; }
        static ulong Merge(ulong h, ulong v) { return (h ^ Round(0, v)) * P1 + P4; }

        internal static ulong XXH64(byte[] b, int off, int len)
        {
            int p = off, end = off + len;
            ulong h;
            if (len >= 32)
            {
                ulong v1 = unchecked(P1 + P2), v2 = P2, v3 = 0, v4 = unchecked(0 - P1);
                int limit = end - 32;
                do
                {
                    v1 = Round(v1, BitConverter.ToUInt64(b, p));
                    v2 = Round(v2, BitConverter.ToUInt64(b, p + 8));
                    v3 = Round(v3, BitConverter.ToUInt64(b, p + 16));
                    v4 = Round(v4, BitConverter.ToUInt64(b, p + 24));
                    p += 32;
                } while (p <= limit);
                h = Rotl(v1, 1) + Rotl(v2, 7) + Rotl(v3, 12) + Rotl(v4, 18);
                h = Merge(h, v1); h = Merge(h, v2); h = Merge(h, v3); h = Merge(h, v4);
            }
            else h = P5;
            h += (ulong)len;
            for (; p + 8 <= end; p += 8) h = Rotl(h ^ Round(0, BitConverter.ToUInt64(b, p)), 27) * P1 + P4;
            if (p + 4 <= end) { h = Rotl(h ^ (BitConverter.ToUInt32(b, p) * P1), 23) * P2 + P3; p += 4; }
            for (; p < end; p++) h = Rotl(h ^ (b[p] * P5), 11) * P1;
            h ^= h >> 33; h *= P2;
            h ^= h >> 29; h *= P3;
            h ^= h >> 32;
            return h;
        }

        // ---- decoder

        struct FrameHeader
        {
            public long ContentSize;    // -1: not given
            public int BlockMax;        // largest block content: min(window, 128 KB)
            public bool Checksum;
        }

        sealed class SeqTable
        {
            public readonly int Kind, MaxSym, MaxLog, DefaultLog;
            public readonly ulong[] Default, Fse = new ulong[512], Rle = new ulong[1];
            public ulong[] Cur;     // table of the previous block (repeat mode); null at the start of a frame
            public int Log;

            public SeqTable(int kind, int maxSym, int maxLog, ulong[] def, int defaultLog)
            {
                Kind = kind; MaxSym = maxSym; MaxLog = maxLog; Default = def; DefaultLog = defaultLog;
            }
        }

        sealed class Decoder
        {
            readonly byte[] src;
            byte[] dst;
            int op;                 // output position
            int frameStart, blockMax;

            // literals of the current block: lit[litPos .. litEnd)
            readonly byte[] litBuf = new byte[BlockSizeMax];
            byte[] lit;
            int litPos, litEnd;

            // Huffman table of the frame: entry = symbol | bits << 8, indexed by the next hufBits bits
            readonly ushort[] huf = new ushort[1 << 11];
            int hufBits;            // 0: no table yet in this frame
            readonly byte[] weights = new byte[256];
            readonly int[] rankCount = new int[16], rankStart = new int[16];

            // FSE work space
            readonly short[] norm = new short[64];
            readonly int[] next = new int[64];
            readonly byte[] fSym = new byte[512], fBits = new byte[512];
            readonly ushort[] fState = new ushort[512];

            readonly SeqTable ll = new SeqTable(KindLL, 35, 9, LLDefault, 6);
            readonly SeqTable of = new SeqTable(KindOF, 31, 8, OFDefault, 5);
            readonly SeqTable ml = new SeqTable(KindML, 52, 9, MLDefault, 6);
            int rep1, rep2, rep3;

            public Decoder(byte[] src) { this.src = src; }

            /// <summary>(DecompressHead) the output wanted at most: decoding stops at the first block that reaches it, or where the
            /// input given (the start of a file) ends.</summary>
            public int HeadLimit;

            sealed class HeadDone : Exception { }

            public byte[] RunHead()
            {
                dst = new byte[HeadLimit + BlockSizeMax];
                try { DecodeFrame(4); }
                catch (HeadDone) { }
                // (the input ends in the middle of a block: what was decoded before it is kept)
                catch (IndexOutOfRangeException) { }
                catch (ArgumentException) { }
                catch (InvalidDataException) { }
                Array.Resize(ref dst, Math.Min(op, HeadLimit));
                return dst;
            }

            public byte[] Run()
            {
                dst = new byte[OutputBound()];
                int ip = 0;
                while (ip < src.Length)
                {
                    uint magic = BitConverter.ToUInt32(src, ip);
                    if ((magic & 0xFFFFFFF0u) == 0x184D2A50u) ip = SkipSkippable(ip);
                    else if (magic == FrameMagic) ip = DecodeFrame(ip + 4);
                    else throw new InvalidDataException("Not zstd data.");
                }
                if (op != dst.Length) Array.Resize(ref dst, op);
                return dst;
            }

            int SkipSkippable(int ip)
            {
                uint size = BitConverter.ToUInt32(src, ip + 4);
                if (size > (uint)(src.Length - ip - 8)) throw Corrupt();
                return ip + 8 + (int)size;
            }

            // Walks the frames' block headers: exact size when the frames give it, else an upper bound.
            long OutputBound()
            {
                long total = 0;
                int ip = 0;
                while (ip < src.Length)
                {
                    uint magic = BitConverter.ToUInt32(src, ip);
                    if ((magic & 0xFFFFFFF0u) == 0x184D2A50u) { ip = SkipSkippable(ip); continue; }
                    if (magic != FrameMagic) throw new InvalidDataException("Not zstd data.");
                    FrameHeader h;
                    ip = ReadFrameHeader(ip + 4, out h);
                    long sum = 0;
                    while (true)
                    {
                        if (src.Length - ip < 3) throw Corrupt();
                        int bh = src[ip] | src[ip + 1] << 8 | src[ip + 2] << 16;
                        ip += 3;
                        int type = (bh >> 1) & 3, size = bh >> 3;
                        int skip = type == 1 ? 1 : size;
                        if (type == 3 || skip > src.Length - ip) throw Corrupt();
                        sum += type == 2 ? h.BlockMax : size;
                        ip += skip;
                        if ((bh & 1) != 0) break;
                    }
                    if (h.Checksum)
                    {
                        if (src.Length - ip < 4) throw Corrupt();
                        ip += 4;
                    }
                    if (h.ContentSize >= 0)
                    {
                        if (h.ContentSize > sum) throw Corrupt();
                        sum = h.ContentSize;
                    }
                    total += sum;
                }
                if (total > MaxArray) throw new InvalidDataException("Decompressed data too large for one array.");
                return total;
            }

            int ReadFrameHeader(int p, out FrameHeader h)
            {
                int fhd = src[p++];
                if ((fhd & 0x08) != 0) throw Corrupt();     // reserved bit
                bool single = (fhd & 0x20) != 0;
                long window = 0;
                if (!single)
                {
                    int wd = src[p++];
                    long b = 1L << (10 + (wd >> 3));
                    window = b + (b >> 3) * (wd & 7);
                }
                int dictBytes = (fhd & 3) == 3 ? 4 : fhd & 3;
                uint dictId = 0;
                for (int i = 0; i < dictBytes; i++) dictId |= (uint)src[p++] << (8 * i);
                if (dictId != 0) throw new NotSupportedException("zstd dictionaries are not supported.");
                int fcsFlag = fhd >> 6;
                int fcsBytes = fcsFlag == 0 ? (single ? 1 : 0) : 1 << fcsFlag;
                long fcs = -1;
                if (fcsBytes > 0)
                {
                    ulong v = 0;
                    for (int i = 0; i < fcsBytes; i++) v |= (ulong)src[p++] << (8 * i);
                    if (fcsBytes == 2) v += 256;
                    if (v > MaxArray) throw new InvalidDataException("Decompressed data too large for one array.");
                    fcs = (long)v;
                }
                if (single) window = fcs;
                h.ContentSize = fcs;
                h.BlockMax = (int)Math.Min(window, BlockSizeMax);
                h.Checksum = (fhd & 4) != 0;
                return p;
            }

            int DecodeFrame(int ip)
            {
                FrameHeader h;
                ip = ReadFrameHeader(ip, out h);
                frameStart = op;
                blockMax = h.BlockMax;
                rep1 = 1; rep2 = 4; rep3 = 8;
                hufBits = 0;
                ll.Cur = null; of.Cur = null; ml.Cur = null;
                while (true)
                {
                    int bh = src[ip] | src[ip + 1] << 8 | src[ip + 2] << 16;
                    ip += 3;
                    int type = (bh >> 1) & 3, size = bh >> 3;
                    if (type == 0)
                    {
                        Ensure(size);
                        Buffer.BlockCopy(src, ip, dst, op, size);
                        op += size;
                        ip += size;
                    }
                    else if (type == 1)
                    {
                        Ensure(size);
                        byte v = src[ip++];
                        byte[] d = dst;
                        for (int i = op, e = op + size; i < e; i++) d[i] = v;
                        op += size;
                    }
                    else if (type == 2)
                    {
                        if (size > blockMax || size > src.Length - ip) throw Corrupt();
                        DecodeBlock(ip, ip + size);
                        ip += size;
                    }
                    else throw Corrupt();
                    if (HeadLimit > 0 && op >= HeadLimit) throw new HeadDone();
                    if ((bh & 1) != 0) break;
                }
                if (h.Checksum)
                {
                    uint want = BitConverter.ToUInt32(src, ip);
                    ip += 4;
                    if ((uint)XXH64(dst, frameStart, op - frameStart) != want)
                        throw new InvalidDataException("zstd checksum mismatch.");
                }
                if (h.ContentSize >= 0 && op - frameStart != h.ContentSize) throw Corrupt();
                return ip;
            }

            void Ensure(long size)
            {
                if (op + size > dst.Length) Grow(op + size);
            }

            void Grow(long need)
            {
                if (need > MaxArray) throw new InvalidDataException("Decompressed data too large for one array.");
                long size = Math.Max(need, (long)dst.Length + dst.Length / 4 + BlockSizeMax);
                Array.Resize(ref dst, (int)Math.Min(size, MaxArray));
            }

            void DecodeBlock(int ip, int end)
            {
                int blockStart = op;
                ip = DecodeLiterals(ip, end);
                if (ip >= end) throw Corrupt();
                int b0 = src[ip++];
                int nbSeq;
                if (b0 < 128) nbSeq = b0;
                else if (b0 < 255) nbSeq = ((b0 - 128) << 8) + src[ip++];
                else { nbSeq = src[ip] + (src[ip + 1] << 8) + 0x7F00; ip += 2; }
                if (nbSeq == 0)
                {
                    if (ip != end) throw Corrupt();
                    int n = litEnd - litPos;
                    Ensure(n);
                    Buffer.BlockCopy(lit, litPos, dst, op, n);
                    op += n;
                    return;
                }
                if (ip >= end) throw Corrupt();
                int modes = src[ip++];
                if ((modes & 3) != 0) throw Corrupt();
                ip = LoadTable(ll, modes >> 6, ip, end);
                ip = LoadTable(of, (modes >> 4) & 3, ip, end);
                ip = LoadTable(ml, (modes >> 2) & 3, ip, end);
                DecodeSequences(ip, end, nbSeq, blockStart);
            }

            int LoadTable(SeqTable t, int mode, int ip, int end)
            {
                switch (mode)
                {
                    case 0:     // predefined
                        t.Cur = t.Default;
                        t.Log = t.DefaultLog;
                        return ip;
                    case 1:     // one symbol
                        {
                            if (ip >= end) throw Corrupt();
                            int sym = src[ip++];
                            if (sym > t.MaxSym) throw Corrupt();
                            t.Rle[0] = SeqEntry(t.Kind, sym, 0, 0);
                            t.Cur = t.Rle;
                            t.Log = 0;
                            return ip;
                        }
                    case 2:     // FSE table description
                        {
                            int log;
                            ip += ReadFseHeader(src, ip, end, norm, t.MaxSym, t.MaxLog, out log);
                            BuildFse(norm, t.MaxSym, log, next, fSym, fBits, fState);
                            for (int u = 0, n = 1 << log; u < n; u++) t.Fse[u] = SeqEntry(t.Kind, fSym[u], fBits[u], fState[u]);
                            t.Cur = t.Fse;
                            t.Log = log;
                            return ip;
                        }
                    default:    // repeat the previous block's table
                        if (t.Cur == null) throw Corrupt();
                        return ip;
                }
            }

            int DecodeLiterals(int ip, int end)
            {
                int b0 = src[ip];
                int type = b0 & 3, sf = (b0 >> 2) & 3;
                if (type < 2)
                {
                    // raw or RLE literals
                    int size;
                    if ((sf & 1) == 0) { size = b0 >> 3; ip += 1; }
                    else if (sf == 1) { size = (b0 >> 4) + (src[ip + 1] << 4); ip += 2; }
                    else { size = (b0 >> 4) + (src[ip + 1] << 4) + (src[ip + 2] << 12); ip += 3; }
                    if (size > blockMax) throw Corrupt();
                    if (type == 0)
                    {
                        if (size > end - ip) throw Corrupt();
                        lit = src; litPos = ip; litEnd = ip + size;
                        return ip + size;
                    }
                    if (ip >= end) throw Corrupt();
                    byte v = src[ip];
                    for (int i = 0; i < size; i++) litBuf[i] = v;
                    lit = litBuf; litPos = 0; litEnd = size;
                    return ip + 1;
                }

                // Huffman-coded literals (type 3: with the previous block's table)
                int regen, csize, hsize;
                if (sf < 2)
                {
                    int v = src[ip] | src[ip + 1] << 8 | src[ip + 2] << 16;
                    regen = (v >> 4) & 0x3FF; csize = (v >> 14) & 0x3FF; hsize = 3;
                }
                else if (sf == 2)
                {
                    uint v = BitConverter.ToUInt32(src, ip);
                    regen = (int)(v >> 4) & 0x3FFF; csize = (int)(v >> 18) & 0x3FFF; hsize = 4;
                }
                else
                {
                    long v = BitConverter.ToUInt32(src, ip) | (long)src[ip + 4] << 32;
                    regen = (int)(v >> 4) & 0x3FFFF; csize = (int)(v >> 22) & 0x3FFFF; hsize = 5;
                }
                ip += hsize;
                if (regen > blockMax || csize > end - ip) throw Corrupt();
                int cend = ip + csize;
                if (type == 2) ip = ReadHuffmanTable(ip, cend);
                else if (hufBits == 0) throw Corrupt();
                if (sf == 0)
                {
                    DecodeHuffStream(src, ip, cend, litBuf, 0, regen, huf, hufBits);
                }
                else
                {
                    if (cend - ip < 10) throw Corrupt();
                    int p1 = ip + 6;
                    int p2 = p1 + (src[ip] | src[ip + 1] << 8);
                    int p3 = p2 + (src[ip + 2] | src[ip + 3] << 8);
                    int p4 = p3 + (src[ip + 4] | src[ip + 5] << 8);
                    int seg = (regen + 3) / 4, last = regen - 3 * seg;
                    if (p4 >= cend || last < 0) throw Corrupt();
                    DecodeHuffStream(src, p1, p2, litBuf, 0, seg, huf, hufBits);
                    DecodeHuffStream(src, p2, p3, litBuf, seg, seg, huf, hufBits);
                    DecodeHuffStream(src, p3, p4, litBuf, 2 * seg, seg, huf, hufBits);
                    DecodeHuffStream(src, p4, cend, litBuf, 3 * seg, last, huf, hufBits);
                }
                lit = litBuf; litPos = 0; litEnd = regen;
                return cend;
            }

            int ReadHuffmanTable(int ip, int end)
            {
                if (ip >= end) throw Corrupt();
                int hb = src[ip++];
                int n;
                if (hb < 128)
                {
                    // FSE-compressed weights
                    if (hb == 0 || hb > end - ip) throw Corrupt();
                    n = DecodeWeights(ip, ip + hb);
                    ip += hb;
                }
                else
                {
                    // 4-bit weights, two per byte
                    n = hb - 127;
                    int bytes = (n + 1) >> 1;
                    if (bytes > end - ip) throw Corrupt();
                    for (int i = 0; i < n; i++)
                    {
                        int b = src[ip + (i >> 1)];
                        weights[i] = (byte)((i & 1) == 0 ? b >> 4 : b & 15);
                    }
                    ip += bytes;
                }
                BuildHuffman(n);
                return ip;
            }

            int DecodeWeights(int p, int end)
            {
                int log;
                int hdr = ReadFseHeader(src, p, end, norm, 15, 6, out log);
                BuildFse(norm, 15, log, next, fSym, fBits, fState);
                int start = p + hdr, ptr, used;
                ulong c;
                InitReader(src, start, end, out ptr, out c, out used);
                int s1 = BitsSafe(c, ref used, log);
                int s2 = BitsSafe(c, ref used, log);
                int n = 0;
                // two interleaved states; the stream ends when an update reads past its start
                while (true)
                {
                    if (n > 253) throw Corrupt();
                    weights[n++] = fSym[s1];
                    s1 = fState[s1] + BitsSafe(c, ref used, fBits[s1]);
                    Reload(src, start, ref ptr, ref c, ref used);
                    if (used > 64) { weights[n++] = fSym[s2]; break; }
                    if (n > 253) throw Corrupt();
                    weights[n++] = fSym[s2];
                    s2 = fState[s2] + BitsSafe(c, ref used, fBits[s2]);
                    Reload(src, start, ref ptr, ref c, ref used);
                    if (used > 64) { weights[n++] = fSym[s1]; break; }
                }
                return n;
            }

            // Builds the decoding table from weights[0 .. n) (the last symbol's weight is implied).
            void BuildHuffman(int n)
            {
                Array.Clear(rankCount, 0, rankCount.Length);
                uint total = 0;
                for (int i = 0; i < n; i++)
                {
                    int w = weights[i];
                    if (w > 11) throw Corrupt();
                    rankCount[w]++;
                    if (w > 0) total += 1u << (w - 1);
                }
                if (total == 0) throw Corrupt();
                int maxBits = HighBit(total) + 1;
                if (maxBits > 11) throw Corrupt();
                uint rest = (1u << maxBits) - total;
                if ((rest & (rest - 1)) != 0) throw Corrupt();
                int lastW = HighBit(rest) + 1;
                weights[n++] = (byte)lastW;
                rankCount[lastW]++;
                // codes of the lightest weights come first, symbols in order within a weight
                int pos = 0;
                for (int w = 1; w <= maxBits; w++)
                {
                    rankStart[w] = pos;
                    pos += rankCount[w] << (w - 1);
                }
                for (int s = 0; s < n; s++)
                {
                    int w = weights[s];
                    if (w == 0) continue;
                    int len = 1 << (w - 1), at = rankStart[w];
                    ushort e = (ushort)(s | (maxBits + 1 - w) << 8);
                    for (int k = 0; k < len; k++) huf[at + k] = e;
                    rankStart[w] = at + len;
                }
                hufBits = maxBits;
            }

            void DecodeSequences(int start, int end, int nbSeq, int blockStart)
            {
                byte[] s = src;
                int ptr, used;
                ulong c;
                InitReader(s, start, end, out ptr, out c, out used);
                ulong[] llt = ll.Cur, oft = of.Cur, mlt = ml.Cur;
                int lls = Bits(c, ref used, ll.Log);
                int ofs = Bits(c, ref used, of.Log);
                int mls = Bits(c, ref used, ml.Log);

                byte[] d = dst;
                int o = op, fs = frameStart;
                byte[] lt = lit;
                int lp = litPos, lend = litEnd;
                int r1 = rep1, r2 = rep2, r3 = rep3;
                long blockLimit = (long)blockStart + blockMax;
                int limit = (int)Math.Min(blockLimit, d.Length);

                for (int i = 0; ;)
                {
                    Reload(s, start, ref ptr, ref c, ref used);
                    ulong le = llt[lls], oe = oft[ofs], me = mlt[mls];
                    long ov = (long)(oe >> 32) + Bits(c, ref used, (int)(oe >> 8) & 0xFF);
                    int mlen = (int)(me >> 32) + Bits(c, ref used, (int)(me >> 8) & 0xFF);
                    if (used > 48) Reload(s, start, ref ptr, ref c, ref used);
                    int llen = (int)(le >> 32) + Bits(c, ref used, (int)(le >> 8) & 0xFF);

                    // offset: a new one, or one of the 3 last ones
                    int off;
                    if (ov > 3)
                    {
                        if (ov - 3 > int.MaxValue) throw Corrupt();
                        off = (int)(ov - 3);
                        r3 = r2; r2 = r1; r1 = off;
                    }
                    else
                    {
                        int k = (int)ov - (llen == 0 ? 0 : 1);
                        if (k == 0) off = r1;
                        else if (k == 1) { off = r2; r2 = r1; r1 = off; }
                        else if (k == 2) { off = r3; r3 = r2; r2 = r1; r1 = off; }
                        else
                        {
                            off = r1 - 1;
                            if (off == 0) throw Corrupt();
                            r3 = r2; r2 = r1; r1 = off;
                        }
                    }

                    if (++i < nbSeq)
                    {
                        if (used > 38) Reload(s, start, ref ptr, ref c, ref used);
                        lls = (int)((le >> 16) & 0xFFFF) + Bits(c, ref used, (int)le & 0xFF);
                        mls = (int)((me >> 16) & 0xFFFF) + Bits(c, ref used, (int)me & 0xFF);
                        ofs = (int)((oe >> 16) & 0xFFFF) + Bits(c, ref used, (int)oe & 0xFF);
                    }

                    // execute: llen literals, then mlen bytes from off bytes back
                    if ((long)o + llen + mlen > limit)
                    {
                        if ((long)o + llen + mlen > blockLimit) throw Corrupt();
                        op = o;
                        Grow((long)o + llen + mlen);
                        d = dst;
                        limit = (int)Math.Min(blockLimit, d.Length);
                    }
                    if (llen > lend - lp) throw Corrupt();
                    if (llen > 0)
                    {
                        if (llen < 16) { for (int k = 0; k < llen; k++) d[o + k] = lt[lp + k]; }
                        else Buffer.BlockCopy(lt, lp, d, o, llen);
                        o += llen;
                        lp += llen;
                    }
                    if (off > o - fs) throw Corrupt();
                    int from = o - off;
                    if (off >= mlen)
                    {
                        if (mlen < 16) { for (int k = 0; k < mlen; k++) d[o + k] = d[from + k]; }
                        else Buffer.BlockCopy(d, from, d, o, mlen);
                    }
                    else if (off == 1)
                    {
                        byte v = d[from];
                        for (int k = 0; k < mlen; k++) d[o + k] = v;
                    }
                    else if (mlen < 32)
                    {
                        for (int k = 0; k < mlen; k++) d[o + k] = d[from + k];
                    }
                    else
                    {
                        // overlapping copy: the pattern repeats every 'off' bytes, so copy in growing pieces
                        int done = 0, dist = off;
                        while (done < mlen)
                        {
                            int n = Math.Min(dist, mlen - done);
                            Buffer.BlockCopy(d, o + done - dist, d, o + done, n);
                            done += n;
                            dist <<= 1;
                        }
                    }
                    o += mlen;
                    if (i >= nbSeq) break;
                }

                // literals after the last sequence
                int rest = lend - lp;
                if ((long)o + rest > limit)
                {
                    if ((long)o + rest > blockLimit) throw Corrupt();
                    op = o;
                    Grow((long)o + rest);
                    d = dst;
                }
                Buffer.BlockCopy(lt, lp, d, o, rest);
                o += rest;
                if (ptr != start || used != 64) throw Corrupt();
                op = o;
                rep1 = r1; rep2 = r2; rep3 = r3;
            }
        }
    }
}
