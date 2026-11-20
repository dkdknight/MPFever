"""Offline test of the public list service (serverlist/ServerList.cs), version 2 (MPFever 0.6, note 09): the players' own games
in the list next to the dedicated servers, and the dedicated servers' API kept as it was for the MPFever versions before 0.6.

The real MPFeverServerList.exe runs on a free port of 127.0.0.1 (--loopback: no firewall question; the announcing address is
then the one X-Forwarded-For names, as behind the list's reverse proxy). It is built first when missing or older than its
source (MSBuild found as build.bat finds it). Cases: health says v2; a dedicated server announced as before 0.6 is listed by
/api/servers with exactly the old fields; a player's game is in /api/games only, without its address unless its host shows
it; two games behind one address and port (CGNAT) are two entries; a game needs a Steam id or its address; one announce every
10 s; a game's Steam id refused from another address while it lives, taken again by its host after a restart of its
MPFever; 8 games per address; a removal.
Run: python tests/test_serverlist.py
"""
import json
import os
import pathlib
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXE = ROOT / "serverlist" / "bin" / "Release" / "MPFeverServerList.exe"
SRC = ROOT / "serverlist" / "ServerList.cs"
OLD_KEYS = {"id", "name", "address", "steam", "reachable", "version", "build", "mode", "world", "motd", "players", "max", "password"}


def build():
    """The service built as build.bat builds it (it may be missing or older than its source)."""
    vswhere = pathlib.Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    if not vswhere.is_file():
        return "vswhere.exe not found: install Visual Studio, or build serverlist\\MPFeverServerList.csproj"
    found = subprocess.run([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.Component.MSBuild", "-find", r"MSBuild\**\Bin\MSBuild.exe"],
                           capture_output=True, text=True).stdout.strip().splitlines()
    if not found:
        return "MSBuild not found"
    p = subprocess.run([found[0], str(ROOT / "serverlist" / "MPFeverServerList.csproj"), "-restore", "-p:Configuration=Release", "-v:minimal", "-nologo"],
                       capture_output=True, text=True)
    return None if p.returncode == 0 and EXE.is_file() else "build failed:\n" + p.stdout[-3000:]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class List:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, None

    def post(self, path, body, ip):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode("utf-8"),
                                     headers={"Content-Type": "application/json", "X-Forwarded-For": ip})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read().decode("utf-8"))


def game(steam, name="Partie de Lena", **kw):
    d = {"kind": "game", "name": name, "port": 28090, "version": "0.6.0", "build": "12345", "mode": "separate", "world": "Lena 1",
         "host": "Lena", "lang": "fr", "state": "lobby", "players": 1, "max": 8, "password": False, "joinPlaying": False,
         "showAddress": False, "steam": steam, "address": "", "token": ""}
    d.update(kw)
    return d


def main():
    if not EXE.is_file() or EXE.stat().st_mtime < SRC.stat().st_mtime:
        why = build()
        if why:
            print("FAIL the service could not be built: " + why)
            return 1
    port = free_port()
    proc = subprocess.Popen([str(EXE), str(port), "--loopback"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    fails = []

    def check(name, cond, got=""):
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
        if not cond:
            fails.append(name)

    try:
        lst = List(port)
        health = None
        for _ in range(100):
            try:
                health = lst.get("/api/health")[1]
                break
            except OSError:
                time.sleep(0.1)
        check("health says v2", health is not None and health.get("ok") is True and health.get("v") == 2, health)

        # a dedicated server, announced as every MPFever before 0.6 does (no kind): listed by /api/servers as before
        srv = lst.post("/api/announce", {"name": "Big Server", "port": 28090, "version": "0.5.14", "build": "12345", "mode": "shared", "world": "W",
                                         "motd": "hi", "players": 2, "max": 8, "password": False, "steam": "76561198000000001", "address": "", "token": ""}, "203.0.113.10")
        check("server announce", srv.get("ok") is True and srv.get("token"), srv)
        servers = lst.get("/api/servers")[1]["servers"]
        check("server listed with the old fields only", len(servers) == 1 and set(servers[0]) == OLD_KEYS, servers)
        check("server address from its announce", servers and servers[0]["address"] == "203.0.113.10:28090", servers and servers[0]["address"])

        # (0.9.3) a server behind a router that lets nothing in hosts through a relay and announces the relay's address: that address is the one looked at, so it is listed (no Steam id here)
        relay = socket.socket(); relay.bind(("127.0.0.1", 0)); relay.listen(5)
        rport = relay.getsockname()[1]
        via = lst.post("/api/announce", {"name": "Behind a relay", "port": 28090, "version": "0.9.3", "build": "40444", "mode": "shared", "world": "W",
                                         "motd": "", "players": 0, "max": 8, "password": False, "steam": "", "address": f"127.0.0.1:{rport}", "token": ""}, "203.0.113.40")
        check("a server announcing a relay's address is accepted", via.get("ok") is True, via)
        listed = []
        for _ in range(50):
            listed = [x for x in lst.get("/api/servers")[1]["servers"] if x["name"] == "Behind a relay"]
            if listed:
                break
            time.sleep(0.1)
        check("and it is listed, reachable through that address", len(listed) == 1 and listed[0]["reachable"] is True and listed[0]["address"] == f"127.0.0.1:{rport}", listed)
        bad = lst.post("/api/announce", {"name": "Private target", "port": 28090, "version": "0.9.3", "build": "40444", "mode": "shared", "world": "W",
                                         "motd": "", "players": 0, "max": 8, "password": False, "steam": "", "address": "10.1.2.3:28090", "token": ""}, "203.0.113.41")
        time.sleep(1.5)
        check("a private address is never looked at: not listed (no Steam id, announcer unreachable)", bad.get("ok") is True
              and not [x for x in lst.get("/api/servers")[1]["servers"] if x["name"] == "Private target"])
        relay.close()
        # (taken out again: the counts below are those of the earlier servers)
        for ent, ip in ((via, "203.0.113.40"), (bad, "203.0.113.41")):
            lst.post("/api/remove", {"id": ent["id"], "token": ent["token"]}, ip)

        # a player's game: in /api/games only, without its address
        g1 = lst.post("/api/announce", game("76561198000000002"), "203.0.113.20")
        check("game announce", g1.get("ok") is True and g1.get("token"), g1)
        servers = lst.get("/api/servers")[1]["servers"]
        check("/api/servers: no player's game", len(servers) == 1 and servers[0]["name"] == "Big Server", [s["name"] for s in servers])
        code, games = lst.get("/api/games")
        rows = {r["steam"]: r for r in (games or {}).get("games", [])}
        r1 = rows.get("76561198000000002")
        check("/api/games: the game and the server", code == 200 and len(rows) == 2 and r1 is not None, list(rows))
        check("game fields", r1 is not None and r1["kind"] == "game" and r1["state"] == "lobby" and r1["host"] == "Lena" and r1["lang"] == "fr"
              and r1["joinPlaying"] is False and r1["max"] == 8 and r1["name"] == "Partie de Lena", r1)
        check("game listed without its address", r1 is not None and r1["address"] == "" and r1["reachable"] is False, r1 and r1["address"])
        check("the host's address in no answer", "203.0.113.20" not in json.dumps(games), "")
        check("server's kind", rows.get("76561198000000001", {}).get("kind") == "server", rows.get("76561198000000001"))

        # a second host behind the same address and port (a carrier's shared address): a game of its own
        g2 = lst.post("/api/announce", game("76561198000000003", name="Max's game", host="Max", lang="en"), "203.0.113.20")
        check("second game behind the same address and port", g2.get("ok") is True, g2)
        # no Steam id and no address: refused
        g0 = lst.post("/api/announce", game(""), "203.0.113.21")
        check("game without Steam id nor address refused", "error" in g0, g0)
        # too often
        again = lst.post("/api/announce", game("76561198000000002", token=g1["token"]), "203.0.113.20")
        check("one announce every 10 s", again.get("error") == "too often", again)
        # the same Steam id from another address, without the token: refused while the game lives
        steal = lst.post("/api/announce", game("76561198000000002", name="Fake"), "198.51.100.7")
        check("Steam id refused from another address", "error" in steal, steal)
        games = lst.get("/api/games")[1]["games"]
        check("the game kept its name", any(r["steam"] == "76561198000000002" and r["name"] == "Partie de Lena" for r in games), [r["name"] for r in games])

        # a host that shows its address: listed with it
        g3 = lst.post("/api/announce", game("76561198000000004", name="Ann's game", host="Ann", showAddress=True, address="198.51.100.30:28090"), "198.51.100.30")
        check("game showing its address", g3.get("ok") is True, g3)
        games = lst.get("/api/games")[1]["games"]
        r3 = next((r for r in games if r["steam"] == "76561198000000004"), None)
        check("address shown at its host's choice", r3 is not None and r3["address"] == "198.51.100.30:28090", r3)

        # the host's MPFever started again (a new token, same address): the game is taken again, not doubled (after the 10 s
        # between two announces of a game)
        time.sleep(10.3)
        restart =lst.post("/api/announce", game("76561198000000003", name="Max's game 2", host="Max"), "203.0.113.20")
        games = lst.get("/api/games")[1]["games"]
        maxes = [r for r in games if r["steam"] == "76561198000000003"]
        check("restarted host: one entry", restart.get("ok") is True and len(maxes) == 1 and maxes[0]["name"] == "Max's game 2", maxes)

        # at most 8 games from one address (two there already)
        res = [lst.post("/api/announce", game("7656119800000010" + str(k)), "203.0.113.20") for k in range(7)]
        oks = sum(1 for x in res if x.get("ok") is True)
        check("8 games per address", oks == 6 and "error" in res[-1], f"{oks} more taken, last {res[-1]}")

        # removal by id and token
        rm = lst.post("/api/remove", {"id": g2["id"], "token": restart.get("token")}, "203.0.113.20")
        check("removal of an old entry refused", "error" in rm, rm)
        rm = lst.post("/api/remove", {"id": restart["id"], "token": restart["token"]}, "203.0.113.20")
        games = lst.get("/api/games")[1]["games"]
        check("removal", rm.get("ok") is True and not any(r["steam"] == "76561198000000003" for r in games), rm)
        health = lst.get("/api/health")[1]
        check("health counts", health.get("servers") == 1 and health.get("games") == 8, health)
    finally:
        proc.kill()
        proc.wait(10)
    if fails:
        print(f"FAIL {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
