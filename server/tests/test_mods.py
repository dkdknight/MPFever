"""Checks of scripts/mods.py with no network: the savegame's mod list, and an install/update/check round trip against a fake mod.io server (own API path, file, hash, download)."""
import hashlib, http.server, io, json, os, struct, sys, tempfile, threading, unittest, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import mods

try:
    import zstandard
except ImportError:
    zstandard = None


def entry(mid, origin, hub, name):
    s = lambda x: struct.pack("<I", len(x.encode())) + x.encode()
    return s(mid) + s(origin) + s(hub) + s(name) + s("") + struct.pack("<i", 0)


def save_bytes(items, padding=40):
    body = struct.pack("<I", len(items)) + b"".join(entry(*i) for i in items)
    return b"\x07\x00\x00\x00junk" + b"\xff" * padding + body + b"\x00" * 200


class SaveList(unittest.TestCase):
    ITEMS = [("mpfever_1", "BuiltInMods", "BuiltInMods,mpfever_1", "MPFever Multiplayer"), ("apasz_zigzag", "mod.io", "6440137", "Zigzag Station"), ("own_mod_1", "UserMods", "UserMods,own_mod_1", "My mod")]

    def test_list_is_found_in_the_first_bytes(self):
        got = mods.mods_of(save_bytes(self.ITEMS))
        self.assertEqual([(g[0], g[1], g[2]) for g in got], [("mpfever_1", "BuiltInMods", ""), ("apasz_zigzag", "mod.io", "6440137"), ("own_mod_1", "UserMods", "")])
        self.assertEqual(got[1][3], "Zigzag Station")

    def test_no_list_gives_none(self):
        self.assertIsNone(mods.mods_of(b"\x00" * 500))

    @unittest.skipUnless(zstandard, "zstandard not installed")
    def test_compressed_save(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "w.sav")
            open(p, "wb").write(zstandard.ZstdCompressor().compress(save_bytes(self.ITEMS)))
            self.assertEqual(len(mods.save_mods(p)), 3)


def mod_zip(extra=b""):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_STORED) as z:
        z.writestr("mod.lua", "function data() return { info = { name = 'x' } } end")
        z.writestr("content/script.lua", "print('hi')")
        z.writestr("res/textures/big.dds", b"D" * 100000 + extra)
    return b.getvalue()


class FakeModio(http.server.BaseHTTPRequestHandler):
    zips = {}                                                # file id -> bytes
    live = {}                                                # mod id -> file id
    log = []

    def log_message(self, *a):
        pass

    def send(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        FakeModio.log.append(self.path.split("?")[0])
        if "api_key=KEY" not in self.path and not self.path.startswith("/dl/"):
            return self.send({"error": {"message": "bad key"}}, 401)
        parts = self.path.split("?")[0].strip("/").split("/")
        if parts[:1] == ["dl"]:
            data = FakeModio.zips[int(parts[1])]
            self.send_response(200); self.end_headers(); self.wfile.write(data); return
        if parts == ["v1", "games", "10640"]:
            return self.send({"id": 10640, "name": "Transport Fever 3"})
        if len(parts) == 5 and parts[3] == "mods":
            mid = int(parts[4])
            return self.send({"id": mid, "name": "Mod %d" % mid, "name_id": "mod_%d" % mid, "platforms": [{"platform": "windows", "modfile_live": FakeModio.live[mid]}]})
        if len(parts) == 7 and parts[5] == "files":
            fid, data = int(parts[6]), FakeModio.zips[int(parts[6])]
            host = "http://127.0.0.1:%d" % self.server.server_port
            return self.send({"id": fid, "version": "1.%d" % fid, "filesize": len(data), "filehash": {"md5": hashlib.md5(data).hexdigest()}, "download": {"binary_url": host + "/dl/%d" % fid}})
        self.send({"error": {"message": "not found"}}, 404)


class Install(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        mods.DATA, mods.CONF, mods.PACE = d, os.path.join(d, "secrets", "modio.json"), 0
        mods.FULL, mods.LITE = os.path.join(d, "mods", "full"), os.path.join(d, "modio")
        os.makedirs(os.path.join(d, "mods"))
        FakeModio.zips, FakeModio.live, FakeModio.log = {1: mod_zip()}, {777: 1}, []
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), FakeModio)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.conf = {"host": "http://127.0.0.1:%d/v1" % self.srv.server_port, "api_key": "KEY"}

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close(); self.tmp.cleanup()

    def test_install_update_and_check(self):
        quiet = lambda *a: None
        self.assertEqual(mods.install(self.conf, 777, check=True), "would-install")
        self.assertEqual(mods.install(self.conf, 777, log=quiet), "new")
        full = os.path.join(mods.FULL, "777")
        lite = os.path.join(mods.LITE, "10640", "mods", "777")
        self.assertTrue(os.path.isfile(os.path.join(full, ".modio.json")))
        self.assertFalse(os.path.exists(os.path.join(lite, ".modio.json")))
        # the full copy is the published files, the game's copy keeps every path and size with the textures left out
        self.assertEqual(os.path.getsize(os.path.join(full, "res/textures/big.dds")), 100000)
        self.assertEqual(os.path.getsize(os.path.join(lite, "res/textures/big.dds")), 100000)
        self.assertEqual(open(os.path.join(lite, "content/script.lua")).read(), "print('hi')")
        state = json.load(open(os.path.join(mods.LITE, "10640", "metadata", "state.json")))
        self.assertEqual([e["ID"] for e in state["Mods"]], [777])
        self.assertEqual(state["Mods"][0]["PathOnDisk"], "C:\\modio\\10640\\mods\\777")
        self.assertEqual(state["Mods"][0]["Profile"]["id"], 777)
        self.assertEqual(mods.install(self.conf, 777, log=quiet), "current")
        FakeModio.zips[2] = mod_zip(b"more"); FakeModio.live[777] = 2
        self.assertEqual(mods.install(self.conf, 777, check=True), "would-update")
        self.assertEqual(mods.install(self.conf, 777, log=quiet), "updated")
        self.assertEqual(mods.installed(777)["file_id"], 2)
        self.assertEqual(os.path.getsize(os.path.join(lite, "res/textures/big.dds")), 100004)

    def test_wrong_hash_is_refused_and_nothing_is_kept(self):
        class Bad(FakeModio):
            pass
        FakeModio.zips[1] = mod_zip()
        orig = mods.download
        mods.download = lambda url, dest, md5: orig(url, dest, "0" * 32)
        try:
            with self.assertRaises(RuntimeError):
                mods.install(self.conf, 777, log=lambda *a: None)
        finally:
            mods.download = orig
        self.assertFalse(os.path.exists(os.path.join(mods.FULL, "777")))

    def test_entry_with_a_wrong_crc_is_kept_with_a_warning(self):
        b = io.BytesIO()
        with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("a.lua", "x = 1")
            z.writestr("tex/big.dds", b"D" * 5000)
        raw = bytearray(b.getvalue())
        directory = bytes(raw).rfind(bytes([0x50, 0x4B, 1, 2]))      # the central directory record of the second entry: its CRC is 16 bytes in
        raw[directory + 16] ^= 0xFF
        with zipfile.ZipFile(io.BytesIO(bytes(raw))) as z:           # the archive must now really fail the check
            with self.assertRaises(zipfile.BadZipFile):
                z.read("tex/big.dds")
        FakeModio.zips[1] = bytes(raw)
        warnings = []
        with zipfile.ZipFile(io.BytesIO(bytes(raw))) as z, tempfile.TemporaryDirectory() as d:
            mods.extract_all(z, d, warnings.append)
            self.assertEqual(open(os.path.join(d, "tex", "big.dds"), "rb").read(), b"D" * 5000)
            self.assertEqual(open(os.path.join(d, "a.lua")).read(), "x = 1")
        self.assertEqual(len(warnings), 1)
        self.assertIn("big.dds", warnings[0])

    def test_unsafe_archive_is_refused(self):
        b = io.BytesIO()
        with zipfile.ZipFile(b, "w") as z:
            z.writestr("../evil.lua", "x")
        FakeModio.zips[1] = b.getvalue()
        with self.assertRaises(RuntimeError):
            mods.install(self.conf, 777, log=lambda *a: None)

    def test_setup_root_writes_both_settings_files(self):
        d = self.tmp.name
        os.makedirs(os.path.join(d, "wine", "drive_c", "users", "tf3"))
        os.environ["HOME"], os.environ["WINEPREFIX"] = d, os.path.join(d, "wine")
        self.assertEqual(mods.cmd_setup_root(None), 0)
        launcher = json.load(open(os.path.join(d, ".local", "share", "mod.io", "globalsettings.json")))
        wine = json.load(open(os.path.join(d, "wine", "drive_c", "users", "tf3", "AppData", "Local", "mod.io", "globalsettings.json")))
        self.assertEqual(launcher["RootLocalStoragePath"], mods.LITE)
        self.assertEqual(wine["RootLocalStoragePath"], "C:\\modio")
        self.assertEqual(os.path.realpath(os.path.join(d, "wine", "drive_c", "modio")), os.path.realpath(mods.LITE))


if __name__ == "__main__":
    unittest.main()
