"""Review of PR #412 (the relay's kept save, 0.8.18), offline: what the review found and how it is fixed.

1. The last save at close (FinalKeep) was never sent: its condition ended with "relay != null", always true once "relay is
   RemoteRelay" held, so it returned every time (the rename server -> relay had changed "server != null", the dedicated server).
2. A host's save went to the relay in parts of 1 MiB on the session's own connection: every message of the session waited behind
   the part being written (about 1.7 s at 5 Mbit/s up), at every autosave. The host now sends parts of 128 KiB (the relay takes
   any part up to 1 MiB, older relays too).
3. Two uploads at once (one longer than the autosave interval): the relay's second "begin" aborted the first, the first one's parts
   were still taken and the hash failed: no save kept, ever. One upload at a time; an autosave during one is not sent (logged).
4. The relay wrote the save to its disk while holding hostGate, which every player's message takes: a slow disk held the whole
   session. Only the host check is under hostGate now; the disk work under checkpointGate only.
5. Fetching the save (Resume) connects as the relay's host for a moment: on a --migration relay its leaving asked a player to take
   over. The fetch says "no handover".
6. A host without a relay read its settings (and DPAPI) at every autosave before finding it had no relay: the relay first.
Run: python tests/test_relayreview0818.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = []


def check(what, cond):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)


def read(p):
    return (ROOT / p).read_text(encoding="utf-8", errors="replace")


cp = read("launcher/Checkpoint.cs")
fk = cp[cp.index("void FinalKeep()"):]
fk = fk[:fk.index("\n        }\n") if "\n        }\n" in fk else fk.index("\r\n        }\r\n")]
cond = re.search(r"if \(!\(relay is RemoteRelay\)(.*?)\) return;", fk, re.S)
check("1. FinalKeep's condition found", cond is not None)
if cond:
    check("1. FinalKeep no longer returns on 'relay != null' (always true there)", "relay != null" not in cond.group(1))
    check("1. FinalKeep leaves out a dedicated server (server != null)", "server != null" in cond.group(1))

wire = read("launcher/CheckpointWire.cs")
m = re.search(r"public const int UploadChunkSize = (\d+) \* 1024;", wire)
check("2. a smaller part for the host's upload (UploadChunkSize)", m is not None and int(m.group(1)) <= 256)
rr = read("launcher/RemoteRelay.cs")
up = rr[rr.index("public string UploadCheckpoint"):]
up = up[:up.index("public byte[] DownloadCheckpoint")]
check("2. UploadCheckpoint cuts the save in UploadChunkSize parts", "CheckpointWire.UploadChunkSize" in up and "CheckpointWire.ChunkSize" not in up)
rc = read("relay/RelayCheckpoint.cs")
check("2. the relay takes any part up to ChunkSize (smaller ones too)", "bytes.Length > ChunkSize" in rc)

ks = cp[cp.index("void KeepSaveOnRelay("):]
ks = ks[:ks.index("Thread keepThread;")]
check("3. one upload at a time (keepThread still alive: this autosave not sent)", "keepThread != null && keepThread.IsAlive" in ks)
check("3. ... and said in the log", "The previous save is still being sent to the relay: this one is not sent." in ks)
check("6. the relay checked before the key is read", ks.index("if (remote == null) return;") < ks.index("string key = RelayKey();"))

proto = read("relay/CheckpointProtocol.cs")
hc = proto[proto.index("void HandleCheckpoint("):]
hc = hc[:hc.index("Msg CheckpointReply(")]
check("4. only the host check under hostGate", "lock (hostGate) { if (sender != host) return; }" in hc)
check("4. the disk work (CheckpointRequest) not under hostGate", hc.index("lock (hostGate) { if (sender != host) return; }") < hc.index("CheckpointRequest(message"))

fetch = cp[cp.index("static string FetchSaveFromRelay("):]
check("5. the fetch connects with no handover", "new RemoteRelay { NoHandover = true }" in fetch[:fetch.index("remote.Connect(")])

lang = read("launcher/lang.json")
check("the new text translated (lang.json)", '"The previous save is still being sent to the relay: this one is not sent.": {' in lang)

print(("FAILED: " + str(len(fails))) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
