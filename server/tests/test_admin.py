"""Checks of scripts/admin.py and of the JSON log line of lib.sh that need no server: rendering of the launcher's log lines, and a command round trip with a fake launcher."""
import json, os, subprocess, sys, tempfile, threading, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import admin


class Render(unittest.TestCase):
    def test_json_info_is_the_message(self):
        self.assertEqual(admin.render(json.dumps({"ts": "x", "level": "info", "component": "launcher", "msg": "Speed: x1"})), "Speed: x1")

    def test_json_warn_and_error_are_marked(self):
        self.assertEqual(admin.render(json.dumps({"level": "warn", "msg": "slow"})), "WARN slow")
        self.assertEqual(admin.render(json.dumps({"level": "error", "msg": "boom"})), "ERROR boom")

    def test_text_line_loses_its_time(self):
        self.assertEqual(admin.render("12:41:52.791 === The server stops ==="), "=== The server stops ===")

    def test_unparsable_json_is_kept(self):
        self.assertEqual(admin.render("{broken"), "{broken")


class RoundTrip(unittest.TestCase):
    def test_command_is_executed_and_its_lines_printed(self):
        with tempfile.TemporaryDirectory() as d:
            cmds, logs = os.path.join(d, "cmd"), os.path.join(d, "logs")
            os.makedirs(cmds); os.makedirs(logs)
            log = os.path.join(logs, "launcher-1.log")
            open(log, "w").write(json.dumps({"level": "info", "msg": "old line"}) + "\n")
            admin.CMDDIR, admin.LOGDIR = cmds, logs

            def launcher():                                   # a fake launcher: runs the command, logs a line, writes .done
                for _ in range(100):
                    for f in os.listdir(cmds):
                        if f.endswith(".cmd"):
                            text = open(os.path.join(cmds, f)).read()
                            os.remove(os.path.join(cmds, f))
                            open(log, "a").write(json.dumps({"level": "info", "msg": "> " + text}) + "\n" + json.dumps({"level": "info", "msg": "Players: none"}) + "\n")
                            open(os.path.join(cmds, f[:-4] + ".done"), "w").write("ok")
                            return
                    time.sleep(0.05)
            t = threading.Thread(target=launcher); t.start()
            import io
            out = io.StringIO()
            rc = admin.run("status", out)
            t.join()
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().splitlines(), ["> status", "Players: none"])

    def test_no_answer_fails(self):
        with tempfile.TemporaryDirectory() as d:
            admin.CMDDIR, admin.LOGDIR, admin.TIMEOUT = os.path.join(d, "c"), os.path.join(d, "l"), 0.5
            self.assertEqual(admin.run("status"), 1)


@unittest.skipUnless(os.name == "posix", "bash script")
class LibLog(unittest.TestCase):
    def sh(self, fmt):
        env = dict(os.environ, LOG_FORMAT=fmt)
        return subprocess.run(["bash", "-c", '. "$1"; log "a \\"quoted\\" path C:\\\\x"', "_", os.path.join(HERE, "..", "scripts", "lib.sh")], capture_output=True, text=True, env=env)

    def test_json_line_is_valid_json(self):
        o = json.loads(self.sh("json").stdout)
        self.assertEqual((o["level"], o["component"]), ("info", "entrypoint"))
        self.assertIn('"quoted"', o["msg"])

    def test_text_line(self):
        self.assertRegex(self.sh("text").stdout, r"^\d\d:\d\d:\d\d INFO  a ")


if __name__ == "__main__":
    unittest.main()
