#!/usr/bin/env python3
"""logship: follows a log file of the game or of Dock and writes its lines to this process's output in the server's own log shape, so `docker logs` holds one stream.

  logship.py game /path/stdout.txt warn     # the game's log ([time - LEVEL - thread - module]  message); only warn and above
  logship.py dock /path/dock.log debug      # Dock's log ([steam-host] ...); everything

Levels: debug < info < warn < error; `off` ships nothing. The file may be replaced or emptied (the game starts again): it is followed from its start then.
One line out per line in: {"ts","level","component","msg"} (LOG_FORMAT=text: `HH:MM:SS LEVEL component msg`)."""
import json, os, re, sys, time

LEVELS = {"debug": 0, "info": 1, "warn": 2, "error": 3}
GAME_LINE = re.compile(r"^\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)Z - (\w+)\s*- ([^-]*?)\s*- ([^\]]*?)\s*\]\s?(.*)$")
GAME_LEVEL = {"VERBOSE": "debug", "DEBUG": "debug", "MESSAGE": "info", "INFO": "info", "WARNING": "warn", "ERROR": "error", "FATAL": "error"}
NOT_BAD = re.compile(r"\S*(error|fail\w*)=0\b", re.I)               # "launch-client-error=0" is a result code that says all went well
BAD_WORDS = re.compile(r"\b(error|failed|fail|fatal|cannot|denied|refused)\b", re.I)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".%03dZ" % (int(time.time() * 1000) % 1000)


class Shaper:
    """Turns the lines of one file into (ts, level, component, msg); a line that continues the one before it (a stack, a detail) keeps that line's level."""

    def __init__(self, kind):
        self.kind, self.level, self.ts = kind, "debug", None

    def shape(self, line):
        line = line.rstrip("\r\n")
        if not line.strip():
            return None
        if self.kind == "game":
            m = GAME_LINE.match(line)
            if m:
                self.level = GAME_LEVEL.get(m.group(3).upper(), "info")
                self.ts = "%sT%s.000Z" % (m.group(1), m.group(2))
                return self.ts, self.level, "game", m.group(6).strip() or "(" + m.group(5) + ")"
            if line.startswith("[MPFEVER"):                   # the MPFever mod's own lines, no time stamp
                self.level, self.ts = "info", None
                return now(), "info", "game", line
            return self.ts or now(), self.level, "game", line.strip()      # a continuation
        level = "warn" if BAD_WORDS.search(NOT_BAD.sub("", line)) else "debug"
        return now(), level, "dock", line.strip()


def emit(rec, fmt, out):
    ts, level, comp, msg = rec
    if fmt == "text":
        out.write("%s %-5s %s: %s\n" % (ts[11:19], level.upper(), comp, msg))
    else:
        out.write(json.dumps({"ts": ts, "level": level, "component": comp, "msg": msg}, ensure_ascii=False) + "\n")
    out.flush()


def same_start(path, head):
    try:
        with open(path, "rb") as f:
            return f.read(len(head)) == head
    except OSError:
        return True


def follow(path, shaper, minimum, fmt, out, stop=lambda: False, poll=0.5, skip_existing=False):
    """Reads the file from its start and on (skip_existing: from its end, what an earlier run wrote is not shipped again); reopened when it is replaced or shortened."""
    pos, ino, buf, head = 0, None, "", b""
    if skip_existing:
        try:
            st = os.stat(path)
            pos, ino = st.st_size, st.st_ino
            with open(path, "rb") as f:
                head = f.read(64)
        except OSError:
            pass
    while not stop():
        try:
            st = os.stat(path)
        except OSError:
            time.sleep(poll)
            continue
        if ino != st.st_ino or st.st_size < pos or (head and not same_start(path, head)):
            pos, ino, buf, head = 0, st.st_ino, "", b""      # replaced, emptied, or written again from its start (the game starts again)
        if st.st_size > pos:
            with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
                f.seek(pos)
                data = f.read()
                pos = f.tell()
            buf += data
            if not head:
                with open(path, "rb") as f:
                    head = f.read(64)
            *lines, buf = buf.split("\n")
            for line in lines:
                rec = shaper.shape(line)
                if rec and LEVELS[rec[1]] >= minimum:
                    emit(rec, fmt, out)
        else:
            time.sleep(poll)


def main(argv):
    if len(argv) != 4 or argv[1] not in ("game", "dock") or argv[3] not in list(LEVELS) + ["off"]:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    if argv[3] == "off":
        return 0
    follow(argv[2], Shaper(argv[1]), LEVELS[argv[3]], os.environ.get("LOG_FORMAT", "json"), sys.stdout, skip_existing=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(0)
