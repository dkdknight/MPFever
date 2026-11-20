#!/usr/bin/env python3
"""mpfever-admin: runs a console command of the MPFever server (the ones typed under the log of the server window) and prints what the server logged for it.

  docker compose exec mpfever-server mpfever-admin help
  docker compose exec mpfever-server mpfever-admin status
  docker compose exec mpfever-server mpfever-admin say "Restart in 5 minutes"
  docker compose exec mpfever-server mpfever-admin kick <player>
  docker compose exec mpfever-server mpfever-admin save
  docker compose exec mpfever-server mpfever-admin token      # the token of the administration page (SRV_ADMIN_UI=on)
  docker compose exec mpfever-server mpfever-admin bundle     # one zip with the logs, the session files and the crash reports, for a bug report

The command is handed to the launcher through a file in the command folder (MPFEVER_CMDDIR); the launcher runs it and writes <name>.done. Exit status: 0 done, 1 the server did not answer."""
import glob, json, os, sys, time

CMDDIR = os.environ.get("MPFEVER_CMDDIR", "/data/run/cmd")
LOGDIR = os.environ.get("MPFEVER_LOGDIR", "/data/srv/logs")
TIMEOUT = float(os.environ.get("MPFEVER_ADMIN_TIMEOUT", "60"))


def render(line):
    """One launcher log line as plain text: the message of a JSON line, or the line as it is."""
    line = line.rstrip("\n")
    if line.startswith("{"):
        try:
            o = json.loads(line)
            return ("%s %s" % (o.get("level", "info").upper(), o.get("msg", ""))).strip() if o.get("level") in ("warn", "error") else o.get("msg", "")
        except ValueError:
            return line
    return line.split(" ", 1)[1] if len(line) > 13 and line[2] == ":" and line[5] == ":" else line


def newest_log():
    files = glob.glob(os.path.join(LOGDIR, "launcher-*.log"))
    return max(files, key=os.path.getmtime) if files else None


def run(command, out=sys.stdout):
    if command.strip() == "bundle":                          # one zip for a bug report: logs, sessions, game logs, crash reports (no secrets): see bundle.py
        import bundle
        return bundle.make(out=out)
    if command.strip() == "token":                           # the administration page's token (SRV_ADMIN_UI=on), made at its first start
        try:
            with open(os.environ.get("MPFEVER_ADMIN_TOKEN_FILE", "/data/secrets/admin-token")) as f:
                print(f.read().strip(), file=out)
            return 0
        except OSError:
            print("no token yet: the administration page is off (SRV_ADMIN_UI=off) or has not started", file=sys.stderr)
            return 1
    if not command.strip():
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 1
    os.makedirs(CMDDIR, exist_ok=True)
    log = newest_log()
    start = os.path.getsize(log) if log else 0
    name = "%d-%d" % (time.time() * 1000, os.getpid())
    tmp, cmd, done = (os.path.join(CMDDIR, name + e) for e in (".tmp", ".cmd", ".done"))
    with open(tmp, "w") as f:
        f.write(command)
    os.replace(tmp, cmd)                                     # the launcher only reads finished files
    deadline = time.time() + TIMEOUT
    while time.time() < deadline and not os.path.exists(done):
        time.sleep(0.2)
    if not os.path.exists(done):
        try:
            os.remove(cmd)
        except OSError:
            pass
        print("the server did not answer within %d s (is the world running? `docker compose logs`)" % TIMEOUT, file=sys.stderr)
        return 1
    os.remove(done)
    time.sleep(0.5)                                          # the lines the command logged
    log = newest_log() or log
    if log:
        with open(log, "r", errors="replace") as f:
            f.seek(start)
            for line in f.read().splitlines():
                text = render(line)
                if text:
                    print(text, file=out)
    return 0


if __name__ == "__main__":
    sys.exit(run(" ".join(sys.argv[1:])))
