"""Checks of scripts/bundle.py: what goes in the support zip and, above all, what never does."""
import io, os, sys, tempfile, unittest, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import bundle


def put(path, text="x", mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(text)


class Bundle(unittest.TestCase):
    def build(self):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        data, tmp = os.path.join(d, "data"), os.path.join(d, "tmp")
        srv = os.path.join(data, "srv")
        put(os.path.join(srv, "logs", "launcher-1.log"), '{"msg":"joined"}\n')
        put(os.path.join(srv, "launcher.out"), "out\n")
        put(os.path.join(srv, "dock.log"), "[steam-host] ok\n")
        put(os.path.join(srv, "mpfever_server.properties"), "name=Test\npassword=hunter2\nrelaykey=abc\nport=28090\n")
        put(os.path.join(srv, "gamelogs", "stdout-1.txt"), "old game log\n")
        put(os.path.join(srv, "sessions", "S1", "in.log"), "in\n")
        put(os.path.join(tmp, "S2", "mp_status.txt"), "IN SYNC\n")
        crash = os.path.join(data, "wine", "drive_c", "Program Files (x86)", "Steam", "userdata", "42", "3493540", "local", "crash_dump")
        put(os.path.join(crash, "stdout.txt"), "current game log\n")
        put(os.path.join(crash, "abc_1.txt"), "crash text\n")
        put(os.path.join(crash, "abc_3.json"), "{}")
        put(os.path.join(crash, "abc_0.dmp"), b"MDMP", "wb")
        put(os.path.join(data, "secrets", "steam.json"), '{"refresh":"SECRETTOKEN"}')
        put(os.path.join(data, "secrets", "modio.json"), '{"api_key":"SECRETKEY"}')
        put(os.path.join(srv, "dock-auth.mdock"), "SECRETTRANSFER")
        put(os.path.join(data, "saves", "world.sav"), "SAVE")
        out = io.StringIO()
        env = {"WORLD": "w", "PASSWORD": "pw-secret", "STEAM_TOKEN": "t", "PATH": "/bin", "GAME_LOG": "info", "MPFEVER_IMAGE_VERSION": "0.9.3"}
        self.assertEqual(bundle.make(data, env, out, tmp), 0)
        path = out.getvalue().split(" (")[0]
        self.assertTrue(os.path.isfile(path), out.getvalue())
        z = zipfile.ZipFile(path)
        return z, {n: z.read(n).decode() for n in z.namelist()}

    def test_what_is_in(self):
        _, files = self.build()
        for name in ("info.txt", "launcher-logs/launcher-1.log", "launcher.out", "dock.log", "config/mpfever_server.properties", "game-logs/stdout-1.txt", "game-logs/current-stdout.txt",
                     "crash-reports/abc_1.txt", "crash-reports/abc_3.json", "sessions/S1/in.log", "sessions/S2/mp_status.txt"):
            self.assertIn(name, files)

    def test_what_never_is(self):
        z, files = self.build()
        names = " ".join(files)
        for bad in ("secrets", "steam.json", "modio.json", ".dmp", "dock-auth", ".sav"):
            self.assertNotIn(bad, names)
        everything = "\n".join(files.values())
        for secret in ("SECRETTOKEN", "SECRETKEY", "SECRETTRANSFER", "hunter2", "abc\n", "pw-secret"):
            self.assertNotIn(secret, everything)

    def test_settings_are_blanked_not_dropped(self):
        _, files = self.build()
        props = files["config/mpfever_server.properties"]
        self.assertIn("password=<hidden>", props)
        self.assertIn("relaykey=<hidden>", props)
        self.assertIn("port=28090", props)

    def test_info_lists_the_settings_without_secrets(self):
        _, files = self.build()
        text = files["info.txt"]
        self.assertIn("WORLD=w", text)
        self.assertIn("GAME_LOG=info", text)
        self.assertIn("0.9.3", text)
        self.assertNotIn("PASSWORD", text)
        self.assertNotIn("STEAM_TOKEN", text)
        self.assertNotIn("PATH=", text)


if __name__ == "__main__":
    unittest.main()
