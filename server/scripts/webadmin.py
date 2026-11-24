#!/usr/bin/env python3
"""webadmin: the server's administration page. Off unless SRV_ADMIN_UI=on; the one thing it does is hand console commands to the launcher, as `mpfever-admin` does.

  - listens on ADMIN_BIND:ADMIN_PORT inside the container (the Compose file publishes it on the host's 127.0.0.1 only: reach it from another machine through an SSH tunnel or a
    reverse proxy that adds TLS; the page is plain HTTP)
  - every call needs the token of /data/secrets/admin-token (made at the first start, mode 0600; `mpfever-admin token` prints it), sent as `Authorization: Bearer <token>`
  - only these console verbs: status, list, say, save, pause, resume, speed, kick, resync, restart (never `stop`); one line, 300 characters at most
  - every command and every refused call is logged in the server's JSON log (component "admin-ui")
No third-party code, no external resource: the page is this file."""
import hmac, json, os, secrets, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import admin, logship

DATA = os.environ.get("DATA", "/data")
TOKEN_FILE = os.environ.get("MPFEVER_ADMIN_TOKEN_FILE", os.path.join(DATA, "secrets", "admin-token"))
ALLOWED = ("status", "list", "say", "save", "pause", "resume", "speed", "kick", "resync", "restart")
MAX_COMMAND = 300
FMT = os.environ.get("LOG_FORMAT", "json")
RUN_LOCK = threading.Lock()                                   # one command at a time: each reads the log lines it caused


def note(level, msg):
    logship.emit((logship.now(), level, "admin-ui", msg), FMT, sys.stdout)


def load_token(path=None):
    """The token of the page: read, or made at the first start (an unreadable or empty file is made again)."""
    path = path or TOKEN_FILE
    try:
        with open(path) as f:
            token = f.read().strip()
        if len(token) >= 24:
            return token
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    token = secrets.token_urlsafe(32)
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    os.replace(path + ".tmp", path)
    return token


def check_command(text):
    """None when this console command may be run from the page, else why not."""
    text = (text or "").strip()
    if not text or len(text) > MAX_COMMAND or any(c in text for c in "\r\n\0"):
        return "one line of at most %d characters" % MAX_COMMAND
    if text.split(None, 1)[0].lower() not in ALLOWED:
        return "not available from the page (%s)" % ", ".join(ALLOWED)
    return None


def run_command(text):
    out = StringIO()
    with RUN_LOCK:
        rc = admin.run(text, out)
    return rc, out.getvalue()


def tail_log(n):
    log = admin.newest_log()
    if not log:
        return []
    with open(log, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        f.seek(max(0, size - 64 * 1024))
        lines = f.read().decode("utf-8", "replace").splitlines()
    return [t for t in (admin.render(l) for l in lines[-n:]) if t]


class Handler(BaseHTTPRequestHandler):
    server_version = "mpfever-admin"
    token = ""
    run = staticmethod(run_command)
    tail = staticmethod(tail_log)

    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def origin_allowed(self, origin):
        """The page's origin is this server's: the Host of the request, or the Host a reverse proxy forwarded (X-Forwarded-Host), or an origin listed in
        SRV_ADMIN_ORIGINS (comma-separated, e.g. https://admin.example.org) for a proxy that sends neither. A page of another site is none of them."""
        o = origin.split("://", 1)[-1]
        hosts = {self.headers.get("Host", "")}
        fwd = self.headers.get("X-Forwarded-Host", "")
        if fwd:
            hosts.add(fwd.split(",")[0].strip())
        extra = [x.strip().rstrip("/") for x in os.environ.get("ADMIN_ORIGINS", "").split(",") if x.strip()]
        return o in hosts or origin.rstrip("/") in extra

    def authorised(self):
        given = self.headers.get("Authorization", "")
        ok = given.startswith("Bearer ") and hmac.compare_digest(given[7:].strip().encode(), self.token.encode())
        origin = self.headers.get("Origin")
        if ok and origin and not self.origin_allowed(origin):
            ok = False                                         # a page of another site
        if not ok:
            note("warn", "refused %s %s from %s (no valid token)" % (self.command, self.path.split("?")[0], self.client_address[0]))
            time.sleep(1)                                      # guessing is slow
            self.reply(401, {"error": "token required"})
        return ok

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            return self.reply(200, PAGE, "text/html")
        if path == "/app.js":
            return self.reply(200, SCRIPT, "application/javascript")
        if path == "/app.css":
            return self.reply(200, STYLE, "text/css")
        if path == "/api/logs":
            if not self.authorised():
                return
            try:
                n = max(1, min(500, int(self.path.split("n=")[1].split("&")[0]))) if "n=" in self.path else 120
            except ValueError:
                n = 120
            return self.reply(200, {"lines": self.tail(n)})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/api/command":
            return self.reply(404, {"error": "not found"})
        if not self.authorised():
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(size, 4096)) or b"{}")
            command = str(body.get("command", ""))
        except (ValueError, AttributeError):
            return self.reply(400, {"error": "a JSON body with a command"})
        why = check_command(command)
        if why:
            note("warn", "refused command from %s: %s" % (self.client_address[0], why))
            return self.reply(400, {"error": why})
        note("info", "command from %s: %s" % (self.client_address[0], command))
        rc, text = self.run(command)
        self.reply(200 if rc == 0 else 504, {"ok": rc == 0, "output": text})


def make_server(host, port, token, run=run_command, tail=tail_log):
    handler = type("BoundHandler", (Handler,), {"token": token, "run": staticmethod(run), "tail": staticmethod(tail)})
    return ThreadingHTTPServer((host, port), handler)


def main():
    host, port = os.environ.get("ADMIN_BIND", "0.0.0.0"), int(os.environ.get("ADMIN_PORT", "8080"))
    token = load_token()
    srv = make_server(host, port, token)
    note("info", "administration page listening on %s:%d (token in %s)" % (host, port, TOKEN_FILE))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MPFever server</title><link rel="stylesheet" href="/app.css"></head>
<body>
<header><h1>MPFever server</h1><span id="state">locked</span></header>
<main>
<section id="login"><label>Token <input id="token" type="password" autocomplete="off"></label><button id="enter">Sign in</button>
<p class="hint">The token is in the server's data volume: <code>docker compose exec mpfever-server mpfever-admin token</code></p></section>
<section id="panel" hidden>
<div class="grid">
<div class="card"><h2>Status</h2><pre id="status">-</pre><button data-cmd="status">Refresh</button></div>
<div class="card"><h2>World</h2>
<div class="row"><button data-cmd="save">Save</button><button data-cmd="pause">Pause</button><button data-cmd="resume">Resume</button><button data-cmd="resync">Resync all</button></div>
<div class="row">Speed <button data-cmd="speed 1">x1</button><button data-cmd="speed 2">x2</button><button data-cmd="speed 4">x4</button></div>
<div class="row"><button id="restart" class="danger">Restart the world</button></div></div>
<div class="card"><h2>Players</h2>
<div class="row"><input id="say" placeholder="Message to every player" maxlength="200"><button id="sendsay">Send</button></div>
<div class="row"><input id="kick" placeholder="Player to kick" maxlength="60"><button id="dokick" class="danger">Kick</button></div></div>
</div>
<div class="card"><h2>Last answer</h2><pre id="answer">-</pre></div>
<div class="card"><h2>Log</h2><pre id="log">-</pre></div>
</section>
</main>
<script src="/app.js"></script></body></html>
"""

STYLE = """:root{color-scheme:light dark;--bg:#f6f7f9;--fg:#1d2330;--card:#fff;--line:#d5dae2;--accent:#1f6feb;--danger:#c62828}
@media (prefers-color-scheme:dark){:root{--bg:#10141b;--fg:#e4e8ef;--card:#182030;--line:#2b3548;--accent:#5b9dff;--danger:#ef6b6b}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif}
header{display:flex;justify-content:space-between;align-items:center;padding:12px 16px;border-bottom:1px solid var(--line)}
h1{font-size:18px;margin:0}h2{font-size:14px;margin:0 0 8px;text-transform:uppercase;letter-spacing:.05em;opacity:.7}
main{max-width:980px;margin:0 auto;padding:16px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;margin-bottom:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin-bottom:12px}.grid .card{margin:0}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
button{background:var(--accent);color:#fff;border:0;border-radius:6px;padding:6px 12px;font:inherit;cursor:pointer}button.danger{background:var(--danger)}
input{flex:1;min-width:0;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);font:inherit}
pre{margin:0 0 8px;white-space:pre-wrap;word-break:break-word;font:13px/1.4 ui-monospace,monospace;max-height:320px;overflow:auto}
.hint{opacity:.7;font-size:13px}#state{font-size:13px;opacity:.7}
"""

SCRIPT = """(function () {
  var tokenBox = document.getElementById('token'), state = document.getElementById('state');
  var token = '';
  try { token = sessionStorage.getItem('mpf-token') || ''; } catch (e) {}
  function api(path, body) {
    var opt = { headers: { 'Authorization': 'Bearer ' + token } };
    if (body) { opt.method = 'POST'; opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body); }
    return fetch(path, opt).then(function (r) { return r.json().then(function (j) { j.status = r.status; return j; }); });
  }
  function unlock(ok) {
    document.getElementById('login').hidden = ok; document.getElementById('panel').hidden = !ok;
    state.textContent = ok ? 'connected' : 'locked';
  }
  function run(command, target) {
    return api('/api/command', { command: command }).then(function (j) {
      if (j.status === 401) { unlock(false); return; }
      var text = j.output || j.error || '';
      document.getElementById(target || 'answer').textContent = text;
    });
  }
  function refresh() {
    if (document.getElementById('panel').hidden) return;
    run('status', 'status');
    api('/api/logs?n=120').then(function (j) {
      if (j.status === 401) { unlock(false); return; }
      var el = document.getElementById('log'), bottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 20;
      el.textContent = (j.lines || []).join(String.fromCharCode(10));
      if (bottom) el.scrollTop = el.scrollHeight;
    });
  }
  function enter() {
    token = tokenBox.value.trim() || token;
    api('/api/logs?n=1').then(function (j) {
      if (j.status === 200) { try { sessionStorage.setItem('mpf-token', token); } catch (e) {} unlock(true); refresh(); }
      else { unlock(false); state.textContent = 'wrong token'; }
    });
  }
  document.getElementById('enter').onclick = enter;
  tokenBox.onkeydown = function (e) { if (e.key === 'Enter') enter(); };
  Array.prototype.forEach.call(document.querySelectorAll('button[data-cmd]'), function (b) {
    b.onclick = function () { run(b.getAttribute('data-cmd'), b.getAttribute('data-cmd') === 'status' ? 'status' : 'answer'); };
  });
  document.getElementById('sendsay').onclick = function () {
    var box = document.getElementById('say'); if (box.value.trim()) { run('say ' + box.value.trim()); box.value = ''; }
  };
  document.getElementById('dokick').onclick = function () {
    var box = document.getElementById('kick');
    if (box.value.trim() && confirm('Kick ' + box.value.trim() + '?')) { run('kick ' + box.value.trim()); box.value = ''; }
  };
  document.getElementById('restart').onclick = function () {
    if (confirm('Save and restart the world? Players are reloaded.')) run('restart');
  };
  if (token) { enter(); }
  setInterval(refresh, 5000);
})();
"""

if __name__ == "__main__":
    sys.exit(main())
