"""Offline test: a big text message goes compressed between the players' MPFever.exe, and comes out exactly as it was sent
(0.7.7, Msg.WriteTo / Msg.Zipped / Msg.Unzip / NetReader.Read in launcher/Core.cs).

A station edit's act is 600 to 838 KB of text (#133: 12 a minute, 8.1 MB at 22:16). Sent as is over an ordered link (Steam's
or TCP), it held that link 0.8 to 3.3 s per hop, and the other games stood until its data came (2.6 s in the middle after its
announce, 10.6 s at most). Now a text message of 16 KB or more is written as a binary "z_bin" message whose bytes are its text
deflated (12 to 16 times smaller); the reader gives back the same kind, sender and text, so nothing else sees a difference:
  - compressed once per message (a relay to several players reuses the bytes);
  - small messages and the binary ones (the savegame's parts): as before;
  - a player on another MPFever version never gets one (the host lets in only its own version);
  - MPFEVER_MSGZ=0: as before.
The launcher's self-test (RunReport077) writes two big acts and a small one on a stream and reads them back.
Run: python tests/test_msgz077.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
L = os.path.join(HERE, "..", "launcher")
core = open(os.path.join(L, "Core.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
st = open(os.path.join(L, "SelfTest.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
mf = open(os.path.join(L, "MainForm.cs"), encoding="utf-8-sig").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check('internal const string ZipKind = "z_bin";' in core and "internal const int ZipMin = 16 * 1024;" in core,
      "a compressed message is a binary one (kind ending in _bin), only from 16 KB")
check('Environment.GetEnvironmentVariable("MPFEVER_MSGZ") != "0"' in core, "MPFEVER_MSGZ=0: as before")
z = core[core.index("internal byte[] Zipped()"):]
z = z[:z.index("\n        }\n")]
check('Kind.EndsWith("_bin", StringComparison.Ordinal)) return null;' in z and "Payload.Length < ZipMin" in z,
      "Zipped: never a binary message, never a small one")
check("if (!zipTried)" in z and "lock (this)" in z, "  compressed once per message, safely from several relay threads")
check("if (ms.Length < bytes.Length) zipped = ms.ToArray();" in z and "catch { zipped = null; }" in z, "  sent as text when it does not get smaller or fails")
w = core[core.index("public void WriteTo(StreamWriter w)"):]
w = w[:w.index("\n        }\n")]
check(w.index("var z = Data == null ? Zipped() : null;") < w.index("w.WriteLine(ToString());"), "WriteTo: a text message tries compression first")
check(r'w.WriteLine(ZipKind + "\t" + From + "\t{[\"k\"]=" + LuaLit.Quote(Kind) + ",[\"len\"]=" + z.Length + "}");' in w
      and "w.BaseStream.Write(z, 0, z.Length);" in w and w.count("Flush()") >= 2,
      "  its line keeps the sender and the kind, then the deflated bytes, both flushed in order")
u = core[core.index("internal static Msg Unzip(Msg m)"):]
u = u[:u.index("\n        }\n")]
check("CompressionMode.Decompress" in u and "return new Msg { Kind = k, From = m.From, Payload = r.ReadToEnd() };" in u,
      "Unzip: the same kind, sender and text")
check('throw new IOException("compressed message without its kind");' in u, "  a broken one ends the connection (its sender sends it again)")
r = core[core.index("public Msg Read()"):]
r = r[:r.index("\n        }\n")]
check(r.index("m.Data = ReadBytes(len);") < r.index("if (m.Kind == Msg.ZipKind) return Msg.Unzip(m);"), "NetReader.Read: read like any binary message, then given back as text")
check("if (hv != Version && Environment.GetEnvironmentVariable(\"MPFEVER_ANYVERSION\") != \"1\")" in mf,
      "a player on another version leaves at once (never gets a compressed message it cannot read)")
check('"a big act read back exactly as sent (twice)"' in st and "the big one compressed on the wire" in st and "ReferenceEquals(big.Zipped(), big.Zipped())" in st,
      "the launcher's self-test reads big and small messages back through NetReader")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
