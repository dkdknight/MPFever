"""Offline test of MPFever's report service (0.7.9, serverlist/Reports.cs): a player's report (the zip of every player's logs)
sent with POST /api/report, kept, given back by its link, and the GitHub issue opened by the service itself.

The real MPFeverServerList.exe runs on a free port of 127.0.0.1 (--loopback; the sending address is the one X-Forwarded-For
names), with its reports in a temporary folder (MPFEVER_REPORTS_DIR) and GitHub played by a small server of this test
(MPFEVER_GITHUB_API, MPFEVER_GITHUB_TOKEN). Cases: a report opens an issue (title, body with the link, the key sent as a
Bearer); the link gives the zip back byte for byte; a report naming an issue goes as a comment of it; not a zip, a bad length,
a cut body: refused; 3 reports every 10 minutes from one address; an unknown link: 404; without a key (a second run): the
file kept, no issue, said why.
Run: python tests/test_reportservice079.py
"""
import http.server
import io
import json
import os
import pathlib
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXE = ROOT / "serverlist" / "bin" / "Release" / "MPFeverServerList.exe"
SRCS = [ROOT / "serverlist" / "ServerList.cs", ROOT / "serverlist" / "Reports.cs"]
sys.path.insert(0, str(ROOT / "tests"))
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" else ""))
    if not cond:
        fails.append(name)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def a_zip(text="hello"):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("report.txt", text)
        z.writestr("players/Jakob/session/x/mod.log", "log " * 1000)
    return b.getvalue()


def body(meta, zipb):
    j = json.dumps(meta).encode("utf-8")
    return struct.pack("<i", len(j)) + j + zipb


def post(base, data, ip):
    req = urllib.request.Request(base + "/api/report", data=data, headers={"Content-Type": "application/octet-stream", "X-Forwarded-For": ip})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except ValueError:
            return e.code, None


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, b"", {}


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        data = json.loads(self.rfile.read(n).decode("utf-8"))
        FakeGitHub.calls.append({"path": self.path, "auth": self.headers.get("Authorization"), "data": data})
        num = 137 + len(FakeGitHub.calls)
        out = {"html_url": f"https://github.com/dkdknight/MPFever/issues/{num}"} if self.path.endswith("/issues") else \
            {"html_url": "https://github.com/dkdknight/MPFever/issues/136#issuecomment-1"}
        b = json.dumps(out).encode("utf-8")
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


def start(port, reports, env_extra):
    env = dict(os.environ, MPFEVER_REPORTS_DIR=str(reports), **env_extra)
    env.pop("MPFEVER_GITHUB_TOKEN", None) if "MPFEVER_GITHUB_TOKEN" not in env_extra else None
    proc = subprocess.Popen([str(EXE), str(port), "--loopback"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=2):
                return proc
        except OSError:
            time.sleep(0.1)
    return proc


def main():
    if not EXE.is_file() or any(EXE.stat().st_mtime < s.stat().st_mtime for s in SRCS):
        import test_serverlist
        why = test_serverlist.build()
        if why:
            print("FAIL the service could not be built: " + why)
            return 1
    gh = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
    threading.Thread(target=gh.serve_forever, daemon=True).start()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="mpfever-reports-"))
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    proc = start(port, tmp / "a", {"MPFEVER_GITHUB_TOKEN": "test-key", "MPFEVER_GITHUB_API": f"http://127.0.0.1:{gh.server_address[1]}"})
    try:
        z = a_zip()
        code, ans = post(base, body({"title": "Problem (MPFever 0.7.9, shared company)", "body": "### What happened\nA player sent this report."}, z), "203.0.113.1")
        check("a report: kept, the issue opened by the service", code == 200 and ans and ans.get("ok") is True
              and ans.get("issue", "").startswith("https://github.com/dkdknight/MPFever/issues/") and ans.get("file", "").startswith(base + "/r/"), ans)
        call = FakeGitHub.calls[0] if FakeGitHub.calls else {}
        check("  GitHub asked with the service's key, the title and the logs' link", call.get("path") == "/repos/dkdknight/MPFever/issues"
              and call.get("auth") == "Bearer test-key" and call.get("data", {}).get("title") == "Problem (MPFever 0.7.9, shared company)"
              and ans and ans.get("file", "") in call.get("data", {}).get("body", ""), call)
        st, got, hd = get(ans.get("file", base + "/r/none")) if ans else (0, b"", {})
        check("  the link gives the zip back, byte for byte", st == 200 and got == z and hd.get("Content-Type") == "application/zip", (st, len(got)))
        code, ans2 = post(base, body({"title": "t", "body": "b", "issue": 136}, a_zip("2")), "203.0.113.1")
        check("a report naming an issue: a comment of it", code == 200 and len(FakeGitHub.calls) == 2 and FakeGitHub.calls[1]["path"] == "/repos/dkdknight/MPFever/issues/136/comments", FakeGitHub.calls[-1:])
        code, bad = post(base, body({"title": "t", "body": "b"}, b"MZ" + b"\0" * 100), "203.0.113.2")
        check("not a zip: refused", code == 400 and bad and "zip" in bad.get("error", ""), (code, bad))
        code, bad = post(base, struct.pack("<i", 999999) + b"{}" + z, "203.0.113.3")
        check("a bad length: refused", code == 400, (code, bad))
        code, ans3 = post(base, body({"title": "t3", "body": "b"}, a_zip("3")), "203.0.113.1")
        code4, ans4 = post(base, body({"title": "t4", "body": "b"}, a_zip("4")), "203.0.113.1")
        check("3 reports every 10 minutes from one address", code == 200 and code4 == 429 and ans4 and "10 minutes" in ans4.get("error", ""), (code, code4, ans4))
        st, _, _ = get(base + "/r/" + "0" * 32 + ".zip")
        st2, _, _ = get(base + "/r/../../port.txt")
        check("an unknown or odd link: 404", st == 404 and st2 == 404, (st, st2))
        kept = sorted(p.name for p in (tmp / "a").glob("*.zip"))
        check("the reports kept under random names", len(kept) == 3 and all(len(k) == 36 for k in kept), kept)
    finally:
        proc.kill()
        proc.wait(10)
    # without a key: the file kept, no issue
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    proc = start(port, tmp / "b", {})
    try:
        before = len(FakeGitHub.calls)
        code, ans = post(base, body({"title": "t", "body": "b"}, a_zip()), "203.0.113.9")
        check("without a GitHub key: the file kept, no issue, said why", code == 200 and ans and ans.get("issue") == "" and ans.get("file", "").startswith(base + "/r/")
              and "key" in ans.get("note", "") and len(FakeGitHub.calls) == before, ans)
    finally:
        proc.kill()
        proc.wait(10)
        gh.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
