"""Checks of the settings validation of scripts/entrypoint.sh (check_settings): the function is cut out of the script and run in bash with a
stand-in for die, so no game, no Docker and no network are needed."""
import os, re, shutil, subprocess, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BASH = shutil.which("bash")


def check_settings_source():
    text = open(os.path.join(HERE, "..", "scripts", "entrypoint.sh"), encoding="utf-8").read()
    start = text.index("need_choice() {")
    end = text.index("\n}\n", text.index("check_settings() {")) + 3
    return text[start:end]


def run(**env):
    script = 'die() { echo "$1"; exit "${2:-1}"; }\n' + check_settings_source() + "\ncheck_settings\n"
    e = {"PATH": os.environ.get("PATH", "")}
    e.update(env)
    p = subprocess.run([BASH, "-c", script], env=e, capture_output=True, text=True, timeout=30)
    return p.returncode, (p.stdout + p.stderr).strip()


@unittest.skipUnless(BASH, "bash is not available")
class CheckSettings(unittest.TestCase):
    def test_the_defaults_are_accepted(self):
        self.assertEqual(run()[0], 0)

    def test_a_line_break_in_a_value_is_refused(self):
        for name in ("SERVER_NAME", "MOTD", "PASSWORD", "RELAY", "RELAY_HOST_KEY", "PUBLIC_ADDRESS", "WORLD"):
            for br in ("\n", "\r"):
                code, out = run(**{name: "a" + br + "public=true"})
                self.assertEqual(code, 2, (name, repr(br), out))
                self.assertIn("SRV_" + name, out)

    def test_a_value_on_one_line_is_accepted(self):
        self.assertEqual(run(SERVER_NAME="My server", MOTD="Welcome! Have fun.")[0], 0)

    def test_the_warning_must_fit_in_the_stop_grace_period(self):
        self.assertEqual(run(SHUTDOWN_WARNING="110", STOP_GRACE="200")[0], 0)
        code, out = run(SHUTDOWN_WARNING="111", STOP_GRACE="200")
        self.assertEqual(code, 2, out)
        self.assertIn("SRV_STOP_GRACE", out)
        self.assertEqual(run(SHUTDOWN_WARNING="300", STOP_GRACE="400")[0], 0)

    def test_the_stop_grace_period_must_be_a_number(self):
        self.assertEqual(run(STOP_GRACE="soon")[0], 2)


if __name__ == "__main__":
    unittest.main()
