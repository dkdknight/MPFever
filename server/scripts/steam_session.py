#!/usr/bin/env python3
"""Steam session of the dedicated server: sign in once (QR code, no password, no graphical interface), keep the refresh token, and hand it to
Madeira Dock at every game start as its one-use transfer file (format MDOCK001, see madeira-dock src/auth.c).

  steam_session.py login   [--file steam.json]            QR sign-in with the Steam mobile app; stores the refresh token (mode 0600)
  steam_session.py status  [--file steam.json]            account, SteamID, token expiry (exit 1: no usable session)
  steam_session.py feed    --file steam.json --out PATH --app 3493540   keeps PATH present for Dock (it deletes the file when it reads it)

The token is never printed, never put on a command line or in an environment variable. Only Steam's own authentication service
(IAuthenticationService on api.steampowered.com) is contacted, with the account owner's approval in the Steam mobile app."""
import argparse, base64, json, os, struct, sys, time, urllib.parse, urllib.request

API = "https://api.steampowered.com/IAuthenticationService/%s/v1/"
STEAMID64_BASE = 76561197960265728          # account id -> SteamID64 (individual, public universe, desktop instance)


def build_transfer(steamid, app, account, token):
    """The bytes of the MDOCK001 transfer file (same checks as Dock's parser)."""
    name, tok = account.encode("ascii"), token.encode("ascii")
    sid = int(steamid)
    if (sid >> 56) != 1 or ((sid >> 52) & 15) != 1 or ((sid >> 32) & 0xfffff) != 1 or not (sid & 0xffffffff):
        raise ValueError("not an individual SteamID64")
    if not 1 <= len(name) <= 64 or not all(33 <= c <= 126 for c in name):
        raise ValueError("bad account name")
    if not 1 <= len(tok) <= 8192 or not all(chr(c).isalnum() or chr(c) in "._-" for c in tok):
        raise ValueError("bad token")
    if not 0 < app < 0xffffffff:
        raise ValueError("bad app id")
    return b"MDOCK001" + struct.pack("<QIHH", sid, app, len(name), len(tok)) + name + tok


def jwt_claims(token):
    part = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def write_private(path, data):
    """Atomic write, owner-only (0600)."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def call(method, fields):
    body = urllib.parse.urlencode({"input_json": json.dumps(fields)}).encode()
    with urllib.request.urlopen(urllib.request.Request(API % method, data=body), timeout=30) as r:
        return json.loads(r.read().decode())["response"]


def show_qr(url):
    print("\nScan this QR code with the Steam mobile app (Steam Guard > Sign in with QR) and approve:\n", flush=True)
    try:
        import qrcode
        q = qrcode.QRCode(border=1)
        q.add_data(url)
        q.print_ascii(invert=True)
    except Exception:
        pass
    print("\nOr open this link in the Steam mobile app:\n  %s\n" % url, flush=True)


def cmd_login(a):
    r = call("BeginAuthSessionViaQR", {"device_friendly_name": "MPFever dedicated server", "platform_type": 1})
    cid, rid, interval = r["client_id"], r["request_id"], max(int(r.get("interval", 5)), 2)
    show_qr(r["challenge_url"])
    deadline = time.time() + 600
    while time.time() < deadline:
        time.sleep(interval)
        p = call("PollAuthSessionStatus", {"client_id": cid, "request_id": rid})
        if p.get("new_client_id"):                                   # the QR code was renewed
            cid = p["new_client_id"]
            if p.get("new_challenge_url"):
                show_qr(p["new_challenge_url"])
        if p.get("refresh_token") and p.get("account_name"):
            claims = jwt_claims(p["refresh_token"])
            sess = {"account": p["account_name"], "steamid": str(claims["sub"]), "refresh_token": p["refresh_token"],
                    "expires": claims.get("exp"), "created": int(time.time())}
            os.makedirs(os.path.dirname(os.path.abspath(a.file)), mode=0o700, exist_ok=True)
            write_private(a.file, json.dumps(sess).encode())
            print("Signed in as %s (SteamID %s). Session saved (valid until %s)." % (
                sess["account"], sess["steamid"], time.strftime("%Y-%m-%d", time.gmtime(sess["expires"])) if sess["expires"] else "?"))
            return 0
    print("Timed out: the code was not approved within 10 minutes.", file=sys.stderr)
    return 1


def load(path):
    with open(path) as f:
        s = json.load(f)
    for k in ("account", "steamid", "refresh_token"):
        if not s.get(k):
            raise ValueError("incomplete session file (%s)" % k)
    return s


def cmd_status(a):
    try:
        s = load(a.file)
    except Exception as e:
        print("no usable Steam session: %s" % e, file=sys.stderr)
        return 1
    exp = s.get("expires")
    left = (exp - time.time()) / 86400 if exp else None
    print("account %s, SteamID %s, token %s" % (s["account"], s["steamid"],
          "valid for %.0f more days" % left if left is not None and left > 0 else ("EXPIRED" if left is not None else "expiry unknown")))
    return 0 if left is None or left > 0 else 1


def cmd_feed(a):
    s = load(a.file)
    data = build_transfer(s["steamid"], a.app, s["account"], s["refresh_token"])
    while True:
        if not os.path.exists(a.out):
            write_private(a.out, data)
        time.sleep(1)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("login", "status", "feed"):
        p = sub.add_parser(name)
        p.add_argument("--file", default=os.environ.get("STEAM_SESSION_FILE", "/data/secrets/steam.json"))
        if name == "feed":
            p.add_argument("--out", required=True)
            p.add_argument("--app", type=int, default=3493540)
    a = ap.parse_args(argv)
    return {"login": cmd_login, "status": cmd_status, "feed": cmd_feed}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
