# Checks mpf_steamnet.cpp (Steam networking in the game) the way MPFever.exe will drive it: commands appended to
# steamnet_cmd.txt, steamnet_status.txt read up to "end=1", loopback listeners for the dial-back, bytes through and compared.
#   python steamnet_test.py mock                 the Steam core with a stand-in for Steam (steamnet_test_build.bat first): no game
#   python steamnet_test.py selftest <MB> [dir]  one running game: a P2P stream to its own Steam ID, echoed and checked
#   python steamnet_test.py games [--fake] [hostDir clientDir]   two running games on one PC (MPFever's local test): Steam's
#                                                IP mode between them, a self-test then real tunnels (--fake: relay-like lag,
#                                                loss and rate limit, Steam's global test settings)
# A game's folder is its MPFever session folder (MPFEVER_DIR, %TEMP%\mpfever\host-... / client-...); left out, the freshest
# ones are taken (their steamnet_status.txt rewritten in the last 3 s).
import ctypes, glob, hashlib, os, random, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
fails = 0

def check(cond, what):
    global fails
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond: fails += 1
    return cond

class Game:
    def __init__(self, d, name):
        self.dir, self.name, self.seq = d, name, int(time.time()) % 100000 * 100
        self.logAt = os.path.getsize(self.path("native.log")) if os.path.exists(self.path("native.log")) else 0
    def path(self, f): return os.path.join(self.dir, f)
    def cmd(self, line):
        self.seq += 1
        with open(self.path("steamnet_cmd.txt"), "a", newline="") as f: f.write(f"{self.seq}\t{line}\n")
    def log(self):
        try:
            with open(self.path("native.log"), "rb") as f: f.seek(self.logAt); return f.read().decode("utf-8", "replace")
        except OSError: return ""
    def status(self):
        try:
            with open(self.path("steamnet_status.txt"), "r") as f: s = f.read()
        except OSError: return None
        out = []
        for l in s.split("\n"):
            if l == "end=1": return out
            out.append(l)
        return None   # (read while it was written: no "end=1" yet)
    def head(self):
        st = self.status()
        return fields(st[0]) if st else {}
    def tunnel(self, tid):
        for l in (self.status() or [])[1:]:
            f = fields(l)
            if f.get("t") == tid: return f
        return None
    def wait_log(self, text, timeout=10, quiet=False):
        r = wait(lambda: text in self.log(), timeout)
        if not quiet or not r: check(r, f"{self.name} log: {text}")
        return r

def fields(line):
    d = {}
    if " why=" in line: line, d["why"] = line.split(" why=", 1)
    for kv in line.split(" "):
        if "=" in kv: k, v = kv.split("=", 1); d[k] = v
    return d

def wait(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        r = pred()
        if r: return r
        time.sleep(0.05)
    return None

def listener():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8); s.settimeout(45)
    return s, s.getsockname()[1]

def readline(c):
    b = b""
    while not b.endswith(b"\n"):
        x = c.recv(1)
        if not x: break
        b += x
    return b.decode("utf-8", "replace")

def pump(src, dst, n, slow=False):
    """n random bytes from src to dst: (sha256 sent, sha256 received, bytes received)"""
    data = random.randbytes(n)
    got = bytearray()
    def reader():
        dst.settimeout(120)
        while len(got) < n:
            x = dst.recv(1 << 16)
            if not x: break
            got.extend(x)
            if slow: time.sleep(0.002)
    t = threading.Thread(target=reader); t.start()
    src.sendall(data)
    t.join(180)
    return hashlib.sha256(data).hexdigest(), hashlib.sha256(bytes(got)).hexdigest(), len(got)

def both_ways(a, b, na, nb, what):
    res = {}
    t1 = threading.Thread(target=lambda: res.__setitem__("ab", pump(a, b, na)))
    t2 = threading.Thread(target=lambda: res.__setitem__("ba", pump(b, a, nb)))
    t0 = time.time(); t1.start(); t2.start(); t1.join(240); t2.join(240)
    s = time.time() - t0
    ab, ba = res.get("ab", ("", "x", 0)), res.get("ba", ("", "x", 0))
    check(ab[0] == ab[1], f"{what}: {na >> 20} MB player -> host intact ({ab[2]} bytes)")
    check(ba[0] == ba[1], f"{what}: {nb >> 20} MB host -> player intact ({ba[2]} bytes), {s:.1f} s, {(na + nb) / s / 1048576:.2f} MB/s together")

def ends(c, timeout=10):
    c.settimeout(timeout)
    try:
        while c.recv(65536): pass
        return True
    except (ConnectionResetError, ConnectionAbortedError): return True
    except OSError: return False

def latency(a, b, n=20):
    lat = []
    for _ in range(n):
        t = time.time(); a.sendall(b"act\tme\t{}\n"); x = b""
        b.settimeout(5)
        while not x.endswith(b"\n"): x += b.recv(100)
        lat.append(time.time() - t)
    return max(lat), sum(lat) / len(lat)

def tunnel(host, player, E, eport, R, sid, vport, kind, tid, nonce, secret, route):
    """a player's connect, both dial-backs and their first lines: (player socket, host socket)"""
    player.cmd(f"connect {tid} {sid} {vport} {eport} {nonce} {kind}")
    try:
        ce, _ = E.accept(); cr, _ = R.accept()
    except OSError as e:
        check(False, f"{tid}: both games dialled their loopback port ({e})"); return None, None
    le, lr = readline(ce), readline(cr)
    route_ok = lambda l: route is None or f'["route"]="{route}"' in l
    check(le.startswith(f'steamtun\t{tid}\t{{["n"]="{nonce}",["route"]="') and '["ping"]=' in le and le.endswith("}\n") and route_ok(le), f"{tid}: player's first line {le!r}")
    check(lr.startswith('steamtun\t') and f'{{["k"]="{secret}",["kind"]="{kind}",["route"]="' in lr and lr.endswith("}\n") and route_ok(lr), f"{tid}: host's first line {lr!r}")
    return ce, cr

# ---------------------------------------------------------------- the stand-in for Steam (no game)

def mock(failclosed):
    SID = 76561197960265728 + 12345
    dll = ctypes.CDLL(os.path.join(HERE, "out", "steamnet_mock.dll"))
    dll.TestStart.argtypes = [ctypes.c_uint64, ctypes.c_char_p, ctypes.c_int]
    d = tempfile.mkdtemp(prefix="steamnet_mock_")
    g = Game(d, "game")
    if failclosed:
        dll.TestRename(10)
        check(dll.TestStart(SID, d.encode(), 1) == 0, "start refused when SendRateMin has another name")
        st = g.status()
        check(st and st[0].startswith("ready=-1 pid=") and "SendRateMin" in st[0], f"status ready=-1 with the reason: {st}")
        check("steam networking: off: configuration value 10" in g.log(), "the log says why")
        return
    with open(g.path("steamnet_cmd.txt"), "w", newline="") as f: f.write("1\thost\t1 abcd\n")   # an earlier game's: skipped
    check(dll.TestStart(SID, d.encode(), 1) == 1, "start")
    wait(lambda: g.head().get("ready") == "1", 3)
    h = g.head()
    check(h.get("ready") == "1" and h.get("sid") == str(SID) and h.get("pid") == str(os.getpid()) and h.get("listen") == "-", f"first status line {h}")
    check("bytes of earlier commands skipped" in g.log() and "mock: debug output reaches the log" in g.log(), "earlier commands skipped, Steam's messages logged")

    g.cmd("selftest 8")
    g.wait_log("self-test passed", 60)
    check(", the same)" in g.log(), "read-back rates are those set")
    check(wait(lambda: g.head().get("selftest") == "ok", 3), "status selftest=ok")

    R, rport = listener(); E, eport = listener()
    secret, nonce = "0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"
    g.cmd(f"host {rport} {secret}")
    g.wait_log("hosting: listening on the Steam virtual ports 28090 and 28091")
    ce, cr = tunnel(g, g, E, eport, R, SID, 28090, "main", "c1", nonce, secret, "lan")
    both_ways(ce, cr, 6 << 20, 3 << 20, "c1")
    f = g.tunnel("c1"); check(f and f["state"] == "connected" and f["peer"] == str(SID), f"c1 status {f}")
    mx, avg = latency(ce, cr); check(mx < 0.2, f"small messages through at once (max {mx * 1000:.0f} ms)")
    ce.sendall(b"last words\n"); ce.close()
    tail = b""; cr.settimeout(10)
    try:
        while True:
            x = cr.recv(65536)
            if not x: break
            tail += x
    except OSError: pass
    check(tail == b"last words\n", "the host's side got the last bytes, then the end of its stream")
    cr.close()
    check(wait(lambda: (g.tunnel("c1") or {}).get("code") == "1000", 5), f"c1 closed with 1000: {g.tunnel('c1')}")

    ce, cr = tunnel(g, g, E, eport, R, SID, 28091, "bulk", "c2", nonce, secret, "lan")
    h = pump(cr, ce, 20 << 20, slow=True); check(h[0] == h[1], f"20 MB through backpressure intact ({h[2]} bytes)")
    g.cmd("close c2"); check(ends(ce) and ends(cr), "close c2: both loopback sides end")

    ce, cr = tunnel(g, g, E, eport, R, SID, 28090, "main", "c3", nonce, secret, "lan")
    g.cmd("conf drop c3"); check(ends(ce) and ends(cr), "conf drop c3: both loopback sides end")

    for c in ["conf rate_main 2000000", "conf fake_loss 0.5", "conf fake_lag 20", "conf bogus 1", "conf ice -1"]: g.cmd(c)
    g.wait_log("conf bogus 1: unknown key")
    check("mock: global float 2=00.50" in g.log() and "mock: global int 4=20" in g.log(), "fake loss and lag set globally")

    dead = socket.socket(); dead.bind(("127.0.0.1", 0)); dport = dead.getsockname()[1]; dead.close()
    g.cmd(f"connect c6 {SID} 28090 {dport} {nonce} main")
    check(wait(lambda: (g.tunnel("c6") or {}).get("code") == "1002", 8), f"a failed dial-back: code 1002 {g.tunnel('c6')}")
    try: cr, _ = R.accept(); readline(cr); check(ends(cr), "the host's side of c6 ends too")
    except OSError: check(False, "the host's side of c6 was dialled")

    g.cmd("connect c9 123 28090 1 ab main"); g.wait_log("is not a player's Steam ID")
    g.cmd("frobnicate"); g.wait_log("unknown command frobnicate")
    with open(g.path("steamnet_cmd.txt"), "a", newline="") as f: f.write("justone\n")
    g.wait_log("a command line without a command: justone")

    g.cmd("unhost"); g.wait_log("hosting stopped")
    check(wait(lambda: g.head().get("listen") == "-", 6), "listen=- after unhost")
    g.cmd(f"connect c4 {SID} 28090 {eport} {nonce} main")
    check(wait(lambda: (g.tunnel("c4") or {}).get("state") == "closed", 5), f"no host any more: c4 closed {g.tunnel('c4')}")
    g.cmd(f"connect c4 {SID} 28090 {eport} {nonce} main"); time.sleep(0.6)
    check(sum(1 for l in (g.status() or [])[1:] if l.startswith("t=c4 ")) == 1, "an id used again: one status line")

    g.cmd("ipmode listen 27500"); g.cmd("ipmode connect 127.0.0.1:27500"); g.cmd(f"host {rport} {secret}")
    g.wait_log("hosting: listening")
    ce, cr = tunnel(g, g, E, eport, R, 0, 0, "main", "c5", nonce, secret, "lan")
    both_ways(ce, cr, 1 << 20, 1 << 20, "c5 (IP mode)")
    h = g.head(); check(h.get("iplisten") == "127.0.0.1:27500" and h.get("ipto") == "127.0.0.1:27500", f"status IP fields {h}")

    g.cmd("ipmode listen 27600 echo"); g.cmd("ipmode connect 127.0.0.1:27600")
    n = g.log().count("self-test passed"); g.cmd("selftest 4")
    check(wait(lambda: g.log().count("self-test passed") > n, 60), "a self-test over IP passed")

    g.cmd("ipmode off"); time.sleep(0.2)
    ce, cr = tunnel(g, g, E, eport, R, SID, 28090, "main", "c8", nonce, secret, "lan")
    dll.TestFailSends(1); ce.sendall(b"x" * 1000)
    check(ends(cr) and ends(ce), "a message Steam refuses ends the tunnel on both loopback sides")
    g.wait_log("Steam refused a message"); dll.TestFailSends(0)

    # (0.7.7) the rate control: a main link with nothing of its own waiting keeps its rate whatever the relay's quality;
    # lowered as before when its data waits; nearly everything arriving for 3 s gives its start rate back, even idle
    ce, cr = tunnel(g, g, E, eport, R, SID, 28090, "main", "c11", nonce, secret, "lan")
    rate = lambda: int((g.tunnel("c11") or {}).get("rate", "0") or 0)
    wait(lambda: rate() > 0, 3); start = rate()
    dll.TestQuality(50, 0); time.sleep(3.5)
    check(start > 0 and rate() == start and "c11 rate lowered" not in g.log(), f"quality 0.50, nothing waiting: the main link keeps {start} bytes/s ({rate()})")
    dll.TestQuality(50, 200000)
    check(wait(lambda: 0 < rate() < start, 4) and "c11 rate lowered" in g.log(), f"quality 0.50 with 200 KB waiting: lowered, as before ({rate()})")
    dll.TestQuality(100, 0)
    check(wait(lambda: rate() == start, 6) and "c11 rate restored" in g.log(), f"then everything arriving, nothing waiting: its start rate back ({rate()})")
    g.cmd("conf aimd_idle 0"); time.sleep(0.2); dll.TestQuality(50, 0)
    check(wait(lambda: 0 < rate() < start, 4), f"conf aimd_idle 0: lowered with nothing waiting, as before ({rate()})")
    dll.TestQuality(-1, 0); g.cmd("conf aimd_idle 1")
    g.cmd("close c11"); ends(ce); ends(cr)

    dll.TestNoFriends(1)
    g.cmd(f"host {rport} {secret} 1"); g.wait_log(", friends only")
    g.cmd(f"connect c10 {SID} 28090 {eport} {nonce} main")
    check(wait(lambda: (g.tunnel("c10") or {}).get("code") == "1001", 5), f"friends only: a stranger refused with 1001 {g.tunnel('c10')}")
    dll.TestNoFriends(0); g.cmd(f"host {rport} {secret}")

    ce, cr = tunnel(g, g, E, eport, R, SID, 28090, "main", "c7", nonce, secret, "lan")
    time.sleep(0.3)
    dll.TestShutdown()
    check(dll.TestShutdownCalled() == 1, "the game's SteamAPI_Shutdown went on to the original")
    g.wait_log("the game closes Steam: 2 connection(s) closed", 3)
    g.wait_log("stopped (the game closes Steam)", 3)
    check(dll.TestOpenConns() == 0, f"no Steam connection left open ({dll.TestOpenConns()})")
    print("session folder:", d)

# ---------------------------------------------------------------- running games

def fresh_folders():
    roots = [os.path.join(tempfile.gettempdir(), "mpfever"), os.path.join(os.environ.get("ProgramData", ""), "MPFever", "sessions"),
             os.path.join(os.environ.get("PUBLIC", ""), "MPFever", "sessions")]
    out = []
    for r in roots:
        for d in glob.glob(os.path.join(r, "*")):
            st = os.path.join(d, "steamnet_status.txt")
            if os.path.exists(st) and time.time() - os.path.getmtime(st) < 3: out.append(d)
    return sorted(out, key=lambda d: os.path.getmtime(os.path.join(d, "native.log")) if os.path.exists(os.path.join(d, "native.log")) else 0)

def ready(g):
    h = g.head()
    if not check(h.get("ready") == "1", f"{g.name} ({g.dir}): Steam networking ready: {(g.status() or ['no status'])[0]}"): sys.exit(1)

def selftest(mb, d):
    if not d:
        ds = fresh_folders()
        if not ds: print("no running game found (no steamnet_status.txt rewritten in the last 3 s)"); sys.exit(1)
        d = ds[-1]
    g = Game(d, "game"); ready(g)
    g.cmd(f"selftest {mb}")
    r = wait(lambda: "self-test passed" in g.log() or "self-test FAILED" in g.log(), 60 + mb * 3)
    for l in g.log().splitlines():
        if "self-test" in l or "selftest" in l or "accepted as" in l or "status callbacks" in l: print("   ", l)
    check(r and "self-test passed" in g.log(), f"self-test of {mb} MB")

def games(fake, dirs):
    if len(dirs) < 2:
        ds = fresh_folders()
        hosts = [d for d in ds if os.path.basename(d).lower().startswith("host")]
        clients = [d for d in ds if os.path.basename(d).lower().startswith("client")]
        if not hosts or not clients: print("two running games not found (host-... and client-... with a fresh steamnet_status.txt): give their folders"); sys.exit(1)
        dirs = [hosts[-1], clients[-1]]
    host, player = Game(dirs[0], "host"), Game(dirs[1], "player")
    ready(host); ready(player)
    if fake:
        for g in (host, player):
            for c in ["conf fake_lag 20", "conf fake_loss 0.5", "conf fake_rate 4000000"]: g.cmd(c)
    # 1. a self-test from the player's game to an echo in the host's game (real UDP between two processes)
    host.cmd("ipmode listen 27500 echo"); host.wait_log("IP mode: listening on UDP 127.0.0.1:27500")
    player.cmd("ipmode connect 127.0.0.1:27500"); player.wait_log("IP mode: connections and self-tests go to UDP 127.0.0.1:27500")
    player.cmd("selftest 16")
    r = wait(lambda: "self-test passed" in player.log() or "self-test FAILED" in player.log(), 120)
    for l in player.log().splitlines():
        if "self-test" in l or "selftest" in l: print("   ", l)
    check(r and "self-test passed" in player.log(), "16 MB from the player's game echoed by the host's game")
    host.wait_log("(test, echo)", 2)
    # 2. tunnels, as MPFever.exe will use them: the host's dial-back to its relay port, the player's to its client
    R, rport = listener(); E, eport = listener()
    secret, nonce = "%032x" % random.getrandbits(128), "%032x" % random.getrandbits(128)
    host.cmd("ipmode listen 27510"); host.cmd(f"host {rport} {secret}"); host.wait_log("hosting: listening")
    player.cmd("ipmode connect 127.0.0.1:27510")
    t0 = time.time()
    ce, cr = tunnel(host, player, E, eport, R, 0, 0, "main", "t1", nonce, secret, None)
    if ce:
        print(f"    connected in {time.time() - t0:.1f} s")
        mx, avg = latency(ce, cr); print(f"    small messages player -> host: {avg * 1000:.1f} ms average, {mx * 1000:.0f} ms at most")
        both_ways(ce, cr, 8 << 20, 8 << 20, "t1 (main)")
        cb, hb = tunnel(host, player, E, eport, R, 0, 0, "bulk", "t2", nonce, secret, None)
        if cb:
            h = pump(hb, cb, 16 << 20); check(h[0] == h[1], f"t2 (bulk): 16 MB host -> player intact ({h[2]} bytes)")
            cb.close(); check(ends(hb), "t2 closed by the player: the host's side ends")
        print("    status, player:", player.tunnel("t1"))
        ce.sendall(b"bye\n"); ce.close()
        cr.settimeout(10); tail = b""
        try:
            while True:
                x = cr.recv(65536)
                if not x: break
                tail += x
        except OSError: pass
        check(tail == b"bye\n", "t1 closed by the player: the host got its last bytes, then the end of its stream")
        check(wait(lambda: (player.tunnel("t1") or {}).get("state") == "closed", 5), f"t1 closed in the player's status {player.tunnel('t1')}")
    host.cmd("unhost"); host.cmd("ipmode off"); player.cmd("ipmode off")
    if fake:
        for g in (host, player):
            for c in ["conf fake_lag 0", "conf fake_loss 0", "conf fake_rate 0"]: g.cmd(c)

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a: print(__doc__ if __doc__ else open(__file__).read().split("import")[0]); sys.exit(2)
    if a[0] == "mock":
        if len(a) > 1 and a[1] == "failclosed": mock(True)
        else:
            mock(False)
            # (the module's state is the process's: the fail-closed start runs in a process of its own)
            if subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "mock", "failclosed"]).returncode: fails += 1
    elif a[0] == "selftest": selftest(int(a[1]) if len(a) > 1 else 64, a[2] if len(a) > 2 else None)
    elif a[0] == "games":
        fake = "--fake" in a
        games(fake, [x for x in a[1:] if x != "--fake"])
    print("RESULT", "OK" if not fails else f"{fails} FAILED")
    sys.exit(1 if fails else 0)
