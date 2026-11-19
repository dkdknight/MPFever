"""Checks of scripts/webadmin.py: the token, the allowed commands, what is refused, and a command round trip through the page's API (a fake launcher behind it)."""
import http.client, json, os, stat, sys, tempfile, threading, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import webadmin


class Token(unittest.TestCase):
    def test_made_once_private_and_kept(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "secrets", "admin-token")
            first = webadmin.load_token(path)
            self.assertGreaterEqual(len(first), 32)
            self.assertEqual(webadmin.load_token(path), first)
            if os.name == "posix":
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_a_short_file_is_made_again(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "t")
            open(path, "w").write("abc")
            self.assertGreaterEqual(len(webadmin.load_token(path)), 32)


class Commands(unittest.TestCase):
    def test_allowed_verbs(self):
        for ok in ("status", "say Restart in 5 minutes", "kick Bob", "speed 2", "restart", "SAVE"):
            self.assertIsNone(webadmin.check_command(ok), ok)

    def test_refused(self):
        for bad in ("", "stop", "start headless", "exit", "say a" + chr(10) + "stop", "say " + "x" * 400, "rm -rf /", "  "):
            self.assertIsNotNone(webadmin.check_command(bad), repr(bad))


class Api(unittest.TestCase):
    TOKEN = "t" * 40

    @classmethod
    def setUpClass(cls):
        cls.ran = []
        webadmin.time.sleep = lambda s: None                   # the pause after a refused call
        cls.srv = webadmin.make_server("127.0.0.1", 0, cls.TOKEN, run=lambda c: (cls.ran.append(c) or (0, "answer to " + c)), tail=lambda n: ["line one", "line two"][:n])
        cls.port = cls.srv.server_port
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown(); cls.srv.server_close()

    def call(self, method, path, body=None, token=TOKEN, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        if token:
            h["Authorization"] = "Bearer " + token
        c.request(method, path, json.dumps(body) if body is not None else None, h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, r, data

    def test_the_page_needs_no_token_and_carries_a_strict_policy(self):
        code, r, data = self.call("GET", "/", token=None)
        self.assertEqual(code, 200)
        self.assertIn(b"MPFever server", data)
        self.assertIn("default-src 'none'", r.getheader("Content-Security-Policy"))
        self.assertEqual(self.call("GET", "/app.js", token=None)[0], 200)

    def test_the_api_needs_the_token(self):
        self.assertEqual(self.call("GET", "/api/logs", token=None)[0], 401)
        self.assertEqual(self.call("GET", "/api/logs", token="wrong")[0], 401)
        self.assertEqual(self.call("POST", "/api/command", {"command": "status"}, token="wrong")[0], 401)
        self.assertNotIn("status", self.ran)

    def test_logs(self):
        code, _, data = self.call("GET", "/api/logs?n=1")
        self.assertEqual((code, json.loads(data)["lines"]), (200, ["line one"]))

    def test_a_command_is_run_and_answered(self):
        code, _, data = self.call("POST", "/api/command", {"command": "say hello all"})
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(data), {"ok": True, "output": "answer to say hello all"})
        self.assertIn("say hello all", self.ran)

    def test_a_forbidden_command_is_never_run(self):
        code, _, data = self.call("POST", "/api/command", {"command": "stop"})
        self.assertEqual(code, 400)
        self.assertNotIn("stop", self.ran)

    def test_a_page_of_another_site_is_refused(self):
        code, _, _ = self.call("POST", "/api/command", {"command": "status"}, headers={"Origin": "http://evil.example"})
        self.assertEqual(code, 401)

    def test_a_bad_body(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("POST", "/api/command", "not json", {"Authorization": "Bearer " + self.TOKEN})
        self.assertEqual(c.getresponse().status, 400)

    def test_unknown_path(self):
        self.assertEqual(self.call("GET", "/etc/passwd", token=None)[0], 404)


if __name__ == "__main__":
    unittest.main()
