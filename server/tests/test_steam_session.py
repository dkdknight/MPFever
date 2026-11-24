"""Checks of scripts/steam_session.py that need no network: the MDOCK001 transfer file against an independent copy of Madeira Dock's parser rules
(src/auth.c), the JWT claims, and the owner-only mode of the stored session."""
import base64, json, os, stat, struct, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import steam_session as S

STEAMID = "76561198000000001"
def _b64(d):
    return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()


TOKEN = _b64({"alg": "EdDSA", "typ": "JWT"}) + "." + _b64({"sub": STEAMID, "exp": 2000000000}) + ".c2ln-_x"


def dock_parse(b):
    """The checks of dock_auth_parse (madeira-dock src/auth.c): returns (steamid, app, account, token) or None."""
    if len(b) < 24 or len(b) > 24 + 64 + 8192 or b[:8] != b"MDOCK001":
        return None
    sid, app, ns, nt = struct.unpack("<QIHH", b[8:24])
    if (sid >> 56) != 1 or ((sid >> 52) & 15) != 1 or ((sid >> 32) & 0xfffff) != 1 or not (sid & 0xffffffff) or not app or app == 0xffffffff:
        return None
    if not ns or ns > 64 or not nt or nt > 8192 or len(b) != 24 + ns + nt:
        return None
    name, tok = b[24:24 + ns], b[24 + ns:]
    if any(c < 33 or c > 126 for c in name) or not all(chr(c).isalnum() or chr(c) in "._-" for c in tok):
        return None
    return sid, app, name.decode(), tok.decode()


class Transfer(unittest.TestCase):
    def test_roundtrip_accepted_by_dock_rules(self):
        b = S.build_transfer(STEAMID, 3493540, "some_account", TOKEN)
        self.assertEqual(dock_parse(b), (int(STEAMID), 3493540, "some_account", TOKEN))

    def test_rejects_bad_input(self):
        for args in [("12345", 3493540, "a", TOKEN), (STEAMID, 0, "a", TOKEN), (STEAMID, 3493540, "", TOKEN),
                     (STEAMID, 3493540, "a b", TOKEN), (STEAMID, 3493540, "a", ""), (STEAMID, 3493540, "a", "tok en"),
                     (STEAMID, 3493540, "a" * 65, TOKEN), (STEAMID, 3493540, "a", "x" * 8193)]:
            with self.assertRaises(ValueError):
                S.build_transfer(*args)

    def test_jwt_claims(self):
        self.assertEqual(S.jwt_claims(TOKEN)["sub"], STEAMID)


class Storage(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "POSIX modes")
    def test_private_file_mode(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "steam.json")
            S.write_private(p, b"{}")
            self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)

    def test_status_missing_and_expired(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "steam.json")
            self.assertEqual(S.main(["status", "--file", p]), 1)
            json.dump({"account": "a", "steamid": STEAMID, "refresh_token": TOKEN, "expires": 1}, open(p, "w"))
            self.assertEqual(S.main(["status", "--file", p]), 1)
            json.dump({"account": "a", "steamid": STEAMID, "refresh_token": TOKEN, "expires": 4000000000}, open(p, "w"))
            self.assertEqual(S.main(["status", "--file", p]), 0)


class Feed(unittest.TestCase):
    """The transfer file is written only while the game is not running (a mod of the running game finds no token on disk)."""
    def _run(self, running, ticks=2, existing=False, grace=0):
        calls = {"n": 0}
        def fake_sleep(_):
            calls["n"] += 1
            if calls["n"] >= ticks:
                raise KeyboardInterrupt
        with tempfile.TemporaryDirectory() as d:
            sess, out = os.path.join(d, "steam.json"), os.path.join(d, "auth.mdock")
            json.dump({"account": "a", "steamid": STEAMID, "refresh_token": TOKEN, "expires": 4000000000}, open(sess, "w"))
            if existing:
                open(out, "wb").write(b"x")
            old = (S.game_running, S.time.sleep)
            S.game_running, S.time.sleep = (lambda pattern: running), fake_sleep
            try:
                S.main(["feed", "--file", sess, "--out", out, "--grace", str(grace)])
            except KeyboardInterrupt:
                pass
            finally:
                S.game_running, S.time.sleep = old
            return os.path.exists(out)

    def test_no_file_while_the_game_runs(self):
        self.assertFalse(self._run(True))

    def test_the_file_is_removed_once_the_game_runs(self):
        self.assertFalse(self._run(True, existing=True))

    def test_the_file_stays_during_the_grace_time(self):
        self.assertTrue(self._run(True, existing=True, grace=3600))

    def test_file_when_the_game_is_not_running(self):
        self.assertTrue(self._run(False))


if __name__ == "__main__":
    unittest.main()
