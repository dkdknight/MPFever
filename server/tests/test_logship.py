"""Checks of scripts/logship.py: the game's and Dock's lines become the server's log lines, filtered by level, and a replaced file is followed again."""
import io, json, os, sys, tempfile, threading, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import logship

WARN = "[2026-11-19 18:10:04Z - WARNING  - ModioAsyncThread - Main           ]  Texture error: Could not find texture x.dds"
INFO = "[2026-11-19 18:10:08Z - MESSAGE  - Main Thread      - Main           ]  Main menu is ready"
VERB = "[2026-11-19 18:10:09Z - VERBOSE  - Main             - ModRep         ]  Found 15 mods"
ERR = "[2026-11-19 17:53:17Z - ERROR    - Main             - Modio          ]+ Could not initialize Modio"


class Shape(unittest.TestCase):
    def test_game_levels_and_time(self):
        s = logship.Shaper("game")
        self.assertEqual(s.shape(WARN), ("2026-11-19T18:10:04.000Z", "warn", "game", "Texture error: Could not find texture x.dds"))
        self.assertEqual(s.shape(INFO)[1:], ("info", "game", "Main menu is ready"))
        self.assertEqual(s.shape(VERB)[1], "debug")
        self.assertEqual(s.shape(ERR)[1], "error")

    def test_a_continuation_keeps_the_level_of_its_line(self):
        s = logship.Shaper("game")
        s.shape(ERR)
        rec = s.shape("    + Location: gamelib/src/modhub/ModioModHubBackend.cpp(1911)")
        self.assertEqual((rec[1], rec[2], rec[3]), ("error", "game", "+ Location: gamelib/src/modhub/ModioModHubBackend.cpp(1911)"))

    def test_the_missing_sound_card_is_not_a_warning(self):
        s = logship.Shaper("game")
        head = s.shape("[2026-11-19 21:59:46Z - WARNING  -                  - Main           ]+ Could not read ogg file")
        cont = s.shape("    + Location: train_fever/src/Lib/audio/util/OggPlayer.cpp(184): operator ()")
        alut = s.shape("[2026-11-19 22:02:30Z - WARNING  -                  - Main           ]  alutCreateBufferFromFile failed for ::/Wind.wav: There is no current AL context (error code: 204).")
        self.assertEqual([head[1], cont[1], alut[1]], ["info", "info", "info"])
        self.assertEqual(s.shape(WARN)[1], "warn")                    # the next real warning is one again

    def test_accounts_a_server_does_not_have_are_not_errors(self):
        s = logship.Shaper("game")
        a = s.shape("[2026-11-20 08:20:10Z - ERROR    -                  - Main           ]+ Modio: User could not be verified (see previous warning), asking the user to log in again")
        b = s.shape("[2026-11-20 08:20:06Z - ERROR    -                  - Main           ]+ Error opening file")
        c = s.shape("    | DetailMessage: fileName='::/music/splash.ogg': error code: -132")
        e = s.shape("[2026-11-20 08:31:16Z - ERROR    -                  - Main           ]+ Modio: cannot re-authenticate without user interaction")
        self.assertEqual(e[1], "info")
        d = s.shape("[2026-11-20 08:20:11Z - ERROR    -                  - Main           ]+ Could not initialize Modio")
        self.assertEqual([a[1], b[1], c[1]], ["info", "info", "info"])
        self.assertEqual(d[1], "error")                               # a real mod.io failure stays one

    def test_mpfever_mod_lines_are_info(self):
        rec = logship.Shaper("game").shape("[MPFEVER-AUTO] loading savegame 'bigworld'")
        self.assertEqual((rec[1], rec[3]), ("info", "[MPFEVER-AUTO] loading savegame 'bigworld'"))

    def test_dock_lines(self):
        s = logship.Shaper("dock")
        self.assertEqual(s.shape("[steam-host] ml1830 engine005-present=1")[1:3], ("debug", "dock"))
        self.assertEqual(s.shape("[steam-host] login failed: denied")[1], "warn")
        self.assertEqual(s.shape("[steam-host] ml1830 launch-client-error=0")[1], "debug")      # a result code of 0 is no error
        self.assertIsNone(s.shape("   "))


class Follow(unittest.TestCase):
    def run_follow(self, minimum, fmt, steps):
        with tempfile.TemporaryDirectory() as d:
            path, out, done = os.path.join(d, "stdout.txt"), io.StringIO(), []
            t = threading.Thread(target=logship.follow, args=(path, logship.Shaper("game"), minimum, fmt, out, lambda: bool(done), 0.02))
            t.start()
            for text, mode in steps:
                with open(path, mode) as f:
                    f.write(text)
                time.sleep(0.3)
            done.append(1)
            t.join()
            return [l for l in out.getvalue().splitlines() if l]

    def test_only_warnings_and_above(self):
        lines = self.run_follow(logship.LEVELS["warn"], "json", [("\n".join([VERB, INFO, WARN, ERR]) + "\n", "w")])
        got = [json.loads(l) for l in lines]
        self.assertEqual([g["level"] for g in got], ["warn", "error"])
        self.assertEqual(got[0]["component"], "game")

    def test_a_file_that_starts_again_is_followed_from_its_start(self):
        lines = self.run_follow(logship.LEVELS["debug"], "json", [(INFO + "\n", "w"), (WARN + "\n", "w")])
        self.assertEqual([json.loads(l)["msg"] for l in lines], ["Main menu is ready", "Texture error: Could not find texture x.dds"])

    def test_a_half_written_line_waits(self):
        lines = self.run_follow(logship.LEVELS["debug"], "json", [(INFO[:30], "w"), (INFO[30:] + "\n", "a")])
        self.assertEqual([json.loads(l)["msg"] for l in lines], ["Main menu is ready"])

    def test_what_an_earlier_run_wrote_is_not_shipped_again(self):
        with tempfile.TemporaryDirectory() as d:
            path, out, done = os.path.join(d, "stdout.txt"), io.StringIO(), []
            open(path, "w").write(INFO + "\n")
            t = threading.Thread(target=logship.follow, args=(path, logship.Shaper("game"), 0, "json", out, lambda: bool(done), 0.02, True))
            t.start()
            time.sleep(0.2)
            open(path, "a").write(WARN + "\n")
            time.sleep(0.3)
            done.append(1)
            t.join()
            self.assertEqual([json.loads(l)["level"] for l in out.getvalue().splitlines()], ["warn"])

    def test_text_format(self):
        lines = self.run_follow(logship.LEVELS["info"], "text", [(INFO + "\n", "w")])
        self.assertEqual(lines, ["18:10:08 INFO  game: Main menu is ready"])


if __name__ == "__main__":
    unittest.main()
