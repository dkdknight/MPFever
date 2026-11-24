#!/usr/bin/env python3
"""bundle: one zip with what a bug report on this server needs, made by `mpfever-admin bundle`.

  docker compose exec mpfever-server mpfever-admin bundle      # prints the zip's path; docker compose cp mpfever-server:<path> .

In the zip: the versions and settings (info.txt), the launcher's logs, the session folders (in.log, mod.log, native.log, mp_status.txt ... the files that explain a desynchronisation),
the game's logs (the current one and the ones kept at each start), Dock's log, the game's crash reports (text and json, not the memory dumps) and the server's settings with every
password, key and token blanked. Never in it: the secrets folder, the Steam transfer file, savegames, memory dumps."""
import glob, os, platform, re, subprocess, sys, time, zipfile

SENSITIVE_NAME = re.compile(r"PASS|KEY|TOKEN|SECRET|AUTH", re.I)
SENSITIVE_LINE = re.compile(r"^(\s*[\w.\-]*(?:password|passwd|pw|key|token|secret)[\w.\-]*\s*[=:]\s*).*$", re.I | re.M)
TAIL = 2 * 1024 * 1024                                          # the end of a log larger than this
FILE_LIMIT = 20 * 1024 * 1024
APPID = "3493540"


def redact(text):
    return SENSITIVE_LINE.sub(lambda m: m.group(1) + "<hidden>", text)


def tail(path, limit=TAIL):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > limit:
            f.seek(size - limit)
        data = f.read()
    return data.decode("utf-8", "replace")


def newest(pattern, n):
    files = [p for p in glob.glob(pattern) if os.path.isfile(p)]
    return sorted(files, key=os.path.getmtime, reverse=True)[:n]


def info(env, data):
    lines = ["MPFever dedicated server bundle, %s UTC" % time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()),
             "image version: %s (%s)" % (env.get("MPFEVER_IMAGE_VERSION", "?"), env.get("MPFEVER_IMAGE_REVISION", "?")),
             "system: %s" % platform.platform()]
    try:
        lines.append("wine: " + subprocess.run(["wine", "--version"], capture_output=True, text=True, timeout=20).stdout.strip())
    except (OSError, subprocess.SubprocessError):
        lines.append("wine: ?")
    manifest = os.path.join(data, "wine", "drive_c", "Program Files (x86)", "Steam", "steamapps", "appmanifest_%s.acf" % APPID)
    try:
        with open(manifest, errors="replace") as f:
            for line in f:
                if '"buildid"' in line or '"lastupdated"' in line:
                    lines.append("game manifest:" + " ".join(line.split()))
    except OSError:
        lines.append("game manifest: not found")
    lines.append("")
    lines.append("settings (the container's environment, secrets left out):")
    for k in sorted(env):
        if not SENSITIVE_NAME.search(k) and k in WANTED_ENV:
            lines.append("  %s=%s" % (k, env[k]))
    return "\n".join(lines) + "\n"


WANTED_ENV = {"WORLD", "SERVER_NAME", "PORT", "MAX_PLAYERS", "PUBLIC", "PAUSE_WHEN_EMPTY", "PLAYER_SPEED_CONTROL", "COMPANY_MODE", "LOG_FORMAT", "UPDATE_CHECK", "MODS_SYNC", "GAME_LOG",
              "ADMIN_UI", "TZ", "MPFEVER_IMAGE_VERSION", "MPFEVER_IMAGE_REVISION"}


def collect(data, env, session_root):
    """[(name in the zip, text or None, path or None)] of what goes in."""
    srv = os.path.join(data, "srv")
    items = [("info.txt", info(env, data), None)]
    for path in newest(os.path.join(srv, "logs", "*"), 10):
        items.append(("launcher-logs/" + os.path.basename(path), None, path))
    for name in ("launcher.out", "dock.log"):
        path = os.path.join(srv, name)
        if os.path.isfile(path):
            items.append((name, None, path))
    for name in ("mpfever_settings.txt", "mpfever_server.properties"):
        path = os.path.join(srv, name)
        if os.path.isfile(path):
            items.append(("config/" + name, None, path))
    sessions = sorted((d for d in glob.glob(os.path.join(srv, "sessions", "*")) if os.path.isdir(d)), key=os.path.getmtime, reverse=True)[:3]
    live = sorted((d for d in glob.glob(os.path.join(session_root, "*")) if os.path.isdir(d)), key=os.path.getmtime, reverse=True)[:1]
    for d in live + [s for s in sessions if os.path.basename(s) not in {os.path.basename(x) for x in live}]:
        for path in sorted(glob.glob(os.path.join(d, "*"))):
            if os.path.isfile(path):
                items.append(("sessions/%s/%s" % (os.path.basename(d), os.path.basename(path)), None, path))
    for path in newest(os.path.join(srv, "gamelogs", "*"), 5):
        items.append(("game-logs/" + os.path.basename(path), None, path))
    crash = os.path.join(data, "wine", "drive_c", "Program Files (x86)", "Steam", "userdata", "*", APPID, "local", "crash_dump")
    for path in newest(os.path.join(crash, "stdout.txt"), 1):
        items.append(("game-logs/current-stdout.txt", None, path))
    for ext in ("json", "txt"):
        for path in newest(os.path.join(crash, "*." + ext), 5):
            if os.path.basename(path) != "stdout.txt":
                items.append(("crash-reports/" + os.path.basename(path), None, path))
    return items


def make(data=None, env=None, out=sys.stdout, session_root="/tmp/mpfever"):
    data = data or os.environ.get("DATA", "/data")
    env = os.environ if env is None else env
    reports = os.path.join(data, "reports")
    os.makedirs(reports, exist_ok=True)
    zpath = os.path.join(reports, "mpfever-server-bundle-%s.zip" % time.strftime("%Y%m%d-%H%M%S", time.gmtime()))
    count = 0
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text, path in collect(data, env, session_root):
            if text is None:
                try:
                    if os.path.getsize(path) > FILE_LIMIT and not name.endswith((".log", ".txt", ".out")):
                        continue
                    text = tail(path)
                except OSError:
                    continue
            z.writestr(name, redact(text))
            count += 1
    print("%s (%d files, %.1f MB)" % (zpath, count, os.path.getsize(zpath) / 1048576.0), file=out)
    return 0


if __name__ == "__main__":
    sys.exit(make())
