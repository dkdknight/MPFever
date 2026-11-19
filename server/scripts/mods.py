#!/usr/bin/env python3
"""mods: the mods of the worlds the server hosts. They come from mod.io (the game's Mod Hub), with the administrator's own API key.

  mods login                      store the mod.io API path and key (typed here, kept 0600 in the data volume, never in the image)
  mods list  <save>               the mods a savegame needs (id, origin, mod.io number, name)
  mods sync  <save> [--check]     install or update the savegame's mod.io mods (--check: only say what would change)
  mods status                     the mods installed on the server, with their version
  mods setup-root                 tell the launcher and the game where the mods are (called at every start)

Each mod is kept twice: the full version as mod.io publishes it (<data>/mods/full/<mod number>/: what the server sends to a joining player) and the version the game loads
(<data>/modio/<game>/mods/<mod number>/): the same files, sizes and scripts, but the data a headless server never uses (textures, sounds) left out (see mklite.py).
Only the mod.io API (the administrator's key) is contacted."""
import argparse, getpass, hashlib, html, json, os, re, shutil, struct, sys, tempfile, time, urllib.error, urllib.request, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mklite

MOD_ID = re.compile(r"^[A-Za-z0-9_.-]+$")
GAME_ID = 10640                                          # Transport Fever 3 on mod.io
WINE_ROOT = "C:\\modio"                                   # LITE as the game (Wine) sees it
DATA = os.environ.get("DATA", "/data")
CONF = os.path.join(DATA, "secrets", "modio.json")
FULL = os.path.join(DATA, "mods", "full")
LITE = os.path.join(DATA, "modio")
UA = "MPFever-server/1.0 (+https://github.com/dkdknight/MPFever)"      # mod.io (Cloudflare) refuses the default Python agent


# ---------------------------------------------------------------- the savegame's mod list (SaveInfo.ModsOf of the launcher)

def mods_of(d):
    """The mods a savegame lists, from its first bytes decompressed: [(id, origin, mod.io number or '', name)], or None. A count (uint32), then per mod five strings
    (uint32 length, UTF-8: id, origin, hub id, name, url) and an int32 severity of 0 to 2; the list is the first place of the first 64 KiB where a whole list holds."""
    n = min(len(d), 65536)
    for off in range(0, max(n - 3, 0)):
        count = struct.unpack_from("<I", d, off)[0]
        if count < 1 or count > 4096:
            continue
        p, out, ok = off + 4, [], True
        for _ in range(count):
            f = []
            for k in range(5):
                if p + 4 > len(d):
                    ok = False; break
                ln = struct.unpack_from("<I", d, p)[0]
                if ln > 4096 or p + 4 + ln > len(d):
                    ok = False; break
                try:
                    f.append(d[p + 4:p + 4 + ln].decode("utf-8", "strict" if k < 3 else "replace"))
                except UnicodeDecodeError:
                    ok = False; break
                p += 4 + ln
            if not ok or p + 4 > len(d):
                ok = False; break
            sev = struct.unpack_from("<i", d, p)[0]
            p += 4
            hub_ok = "," in f[2][1:] or f[2].isdigit()
            if sev < 0 or sev > 2 or not f[0] or any(ord(c) < 32 for c in f[0] + f[1]) or not hub_ok:
                ok = False; break
            out.append((f[0], f[1], f[2] if f[2].isdigit() else "", f[3] or f[0]))
        if ok:
            return out
    return None


def save_mods(path):
    import zstandard
    with open(path, "rb") as fh:
        head = zstandard.ZstdDecompressor().stream_reader(fh).read(1 << 20)
    return mods_of(head)


# ---------------------------------------------------------------- mod.io

def load_conf():
    try:
        with open(CONF) as f:
            c = json.load(f)
        if c.get("host") and c.get("api_key"):
            return c
    except (OSError, ValueError):
        pass
    return None


PACE = 1.2                                          # seconds between two API calls (mod.io allows 60 a minute to a key)
_last = [0.0]


def api(conf, path, query=""):
    url = "%s%s?api_key=%s%s" % (conf["host"].rstrip("/"), path, conf["api_key"], ("&" + query) if query else "")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(6):
        wait = _last[0] + PACE - time.time()
        if wait > 0:
            time.sleep(wait)
        _last[0] = time.time()
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5:
                raise
            try:
                delay = int(e.headers.get("Retry-After") or e.headers.get("X-RateLimit-RetryAfter") or 30)
            except ValueError:
                delay = 30
            time.sleep(min(max(delay, 1), 120))                    # mod.io's rate limit: wait as it says, then ask again


def live_file(conf, mod_id):
    """(mod, file) of the Windows build a mod.io mod currently publishes."""
    m = api(conf, "/games/%d/mods/%s" % (GAME_ID, mod_id))
    live = next((p["modfile_live"] for p in m.get("platforms", []) if p.get("platform") == "windows"), None) or (m.get("modfile") or {}).get("id")
    if not live:
        raise RuntimeError("mod %s publishes no Windows file" % mod_id)
    return m, api(conf, "/games/%d/mods/%s/files/%s" % (GAME_ID, mod_id, live))


def download(url, dest, md5):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    h = hashlib.md5()
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            h.update(b); f.write(b)
    if h.hexdigest() != md5:
        raise RuntimeError("download of %s does not match its published hash" % os.path.basename(dest))


def extract_all(z, dest, warn=print):
    """Extracts an archive; an entry that does not stay in the folder is refused. Some mods are published with a wrong CRC on a few entries (the data inflates fine and the whole
    file matches mod.io's hash): such an entry is kept as published, with a warning, as the game's own installer does."""
    root = os.path.realpath(dest)
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        target = os.path.realpath(os.path.join(dest, name))
        if name.startswith("/") or (target != root and not target.startswith(root + os.sep)):
            raise RuntimeError("unsafe path in the mod's archive: %s" % info.filename)
        if info.is_dir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        try:
            with z.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
        except zipfile.BadZipFile as e:
            if "CRC" not in str(e):
                raise
            crc, info.CRC = info.CRC, None                  # no reference to compare with: the data as it inflates
            try:
                with z.open(info) as src, open(target, "wb") as out:
                    shutil.copyfileobj(src, out)
            finally:
                info.CRC = crc
            warn("wrong CRC in the published archive for %s (kept as published)" % info.filename)


def installed(mod_id):
    try:
        with open(os.path.join(FULL, str(mod_id), ".modio.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def lite_tree(src, dst):
    """The same tree with what a headless server never uses left out (mklite.py): every file keeps its size."""
    stats = dict(hole=0, copied=0, written=0, plans=0)
    for root, _dirs, files in os.walk(src):
        out = os.path.join(dst, os.path.relpath(root, src))
        os.makedirs(out, exist_ok=True)
        for name in files:
            mklite.process_loose(os.path.join(root, name), os.path.join(out, name), stats)
    return stats


# what the game's own state file keeps of a mod's profile (it does not start with the other fields of mod.io's answer)
PROFILE_KEYS = ("community_options", "date_added", "date_live", "date_updated", "dependencies", "description", "description_plaintext", "id", "logo", "maturity_option", "media",
                "metadata_blob", "metadata_kvp", "modfile", "name", "profile_url", "stats", "status", "submitted_by", "summary", "tags", "visible")


def no_nulls(o):
    """The game's library reads every text field as text: a null where mod.io gave none stops it at start."""
    if isinstance(o, dict):
        return {k: no_nulls(v) for k, v in o.items()}
    if isinstance(o, list):
        return [no_nulls(v) for v in o]
    return "" if o is None else o


def register(m, f, lite_dir):
    """The game's mod.io library keeps the list of installed mods in <root>/<game>/metadata/state.json and knows no mod that is not in it: this adds or replaces this mod's entry
    (the profile as mod.io published it, the folder as the game sees it)."""
    path = os.path.join(LITE, str(GAME_ID), "metadata", "state.json")
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}
    mods_list = [e for e in state.get("Mods", []) if e.get("ID") != m["id"]]
    size = sum(os.path.getsize(os.path.join(r, n)) for r, _d, names in os.walk(lite_dir) for n in names)
    seen_by_wine = WINE_ROOT + lite_dir[len(LITE):].replace("/", "\\")
    profile = no_nulls({k: m[k] for k in PROFILE_KEYS if k in m})
    profile["modfile"] = no_nulls(f)                              # (the file that is live for Windows: the profile's own "modfile" is empty when files are per platform)
    mods_list.append({"ID": m["id"], "NeverRetryCategory": 0, "NeverRetryCode": 0, "PathOnDisk": seen_by_wine, "Profile": profile, "SizeOnDisk": size, "State": 1,
                      "SubscriptionCount": [(m.get("stats") or {}).get("subscribers_total", 1)]})
    mods_list.sort(key=lambda e: e["ID"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        json.dump({"Mods": mods_list, "version": 1}, fh)
    os.replace(path + ".tmp", path)


def find_mod_folders(src):
    """The folders of mods under src: src itself when it holds mod.lua, else each of its sub-folders that does."""
    if os.path.isfile(os.path.join(src, "mod.lua")):
        return [src]
    return [os.path.join(src, d) for d in sorted(os.listdir(src)) if os.path.isfile(os.path.join(src, d, "mod.lua"))]


def copy_plain(src, dst):
    """A folder copied as plain files and folders: links are left out (a mod must not reach outside its own folder)."""
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        out = os.path.join(dst, os.path.relpath(root, src))
        os.makedirs(out, exist_ok=True)
        for name in files:
            path = os.path.join(root, name)
            if not os.path.islink(path):
                shutil.copyfile(path, os.path.join(out, name))


def import_mods(src, dest_mods, log=print):
    """Imports mods of the administrator's PC (a mods folder or one mod folder, for example the game's local/mods folder): the full copy is kept for the players, the reduced one goes to the game's own
    mods folder (dest_mods). Returns [(id, 'new' | 'updated')]."""
    done = []
    for folder in find_mod_folders(src):
        mod_id = os.path.basename(os.path.normpath(folder))
        if not MOD_ID.match(mod_id):
            log("skipped %s: a mod's folder name uses letters, digits, _ . - only" % mod_id)
            continue
        work = tempfile.mkdtemp(prefix="mod-", dir=os.path.join(DATA, "mods") if os.path.isdir(os.path.join(DATA, "mods")) else None)
        try:
            full_new, lite_new = os.path.join(work, "full"), os.path.join(work, "lite")
            copy_plain(folder, full_new)
            with open(os.path.join(full_new, ".modio.json"), "w") as fh:
                json.dump({"mod_id": 0, "name": mod_id, "title": mod_id, "source": "import", "installed": int(time.time())}, fh)
            lite_tree(full_new, lite_new)
            os.remove(os.path.join(lite_new, ".modio.json"))
            full_dir, lite_dir = os.path.join(FULL, mod_id), os.path.join(dest_mods, mod_id)
            have = os.path.isdir(full_dir)
            for target, new in ((full_dir, full_new), (lite_dir, lite_new)):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.isdir(target):
                    shutil.rmtree(target)
                shutil.move(new, target)
            done.append((mod_id, "updated" if have else "new"))
            log("%s: %s" % ("updated" if have else "imported", mod_id))
        finally:
            shutil.rmtree(work, ignore_errors=True)
    return done


def install(conf, mod_id, force=False, check=False, log=print):
    """Installs or updates one mod.io mod; returns 'new', 'updated', 'current' (or 'would-install' / 'would-update' with check)."""
    m, f = live_file(conf, mod_id)
    have = installed(mod_id)
    if have and have.get("file_id") == f["id"] and not force:
        if not check:
            register(m, f, os.path.join(LITE, str(GAME_ID), "mods", str(mod_id)))      # (also refreshes the profile)
        return "current"
    kind = "update" if have else "install"
    if check:
        return "would-" + kind
    log("%s %s (%s, %.1f MB)" % ("updating" if have else "installing", html.unescape(m["name"]), f.get("version") or "?", f["filesize"] / 1e6))
    work = tempfile.mkdtemp(prefix="mod-", dir=os.path.join(DATA, "mods") if os.path.isdir(os.path.join(DATA, "mods")) else None)
    try:
        zpath = os.path.join(work, "mod.zip")
        download(f["download"]["binary_url"], zpath, f["filehash"]["md5"])
        full_new = os.path.join(work, "full")
        with zipfile.ZipFile(zpath) as z:
            extract_all(z, full_new, lambda msg: log("warning: " + msg))
        meta = {"mod_id": int(mod_id), "name": m.get("name_id") or m.get("name"), "title": html.unescape(m.get("name") or ""), "file_id": f["id"], "md5": f["filehash"]["md5"],
                "version": f.get("version"), "date_updated": f.get("date_added"), "installed": int(time.time())}
        with open(os.path.join(full_new, ".modio.json"), "w") as fh:
            json.dump(meta, fh)
        lite_new = os.path.join(work, "lite")
        lite_tree(full_new, lite_new)
        os.remove(os.path.join(lite_new, ".modio.json"))
        full_dir, lite_dir = os.path.join(FULL, str(mod_id)), os.path.join(LITE, str(GAME_ID), "mods", str(mod_id))
        for target, new in ((full_dir, full_new), (lite_dir, lite_new)):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.isdir(target):
                shutil.rmtree(target)
            shutil.move(new, target)
        register(m, f, lite_dir)
        return "updated" if have else "new"
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ---------------------------------------------------------------- commands

def cmd_login(a):
    host = a.host or input("mod.io API path (mod.io/me/access, like https://u-123456.modapi.io/v1): ").strip()
    key = os.environ.get("MODIO_API_KEY") or (sys.stdin.readline().strip() if not sys.stdin.isatty() else getpass.getpass("mod.io API key (not shown): ").strip())
    if not host.startswith("https://") or len(key) < 16:
        print("the API path must start with https:// and the key must be the 32 characters of mod.io/me/access", file=sys.stderr)
        return 2
    conf = {"host": host, "api_key": key}
    try:
        name = api(conf, "/games/%d" % GAME_ID).get("name")
    except urllib.error.URLError as e:
        print("mod.io refused this path and key: %s" % e, file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(CONF), mode=0o700, exist_ok=True)
    fd = os.open(CONF + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(conf, f)
    os.replace(CONF + ".tmp", CONF)
    print("mod.io access works (%s). Saved." % name)
    return 0


def modio_mods(path):
    lst = save_mods(path)
    if lst is None:
        raise RuntimeError("cannot read the mod list of %s" % path)
    return lst


def cmd_import(a):
    if not os.path.isdir(a.path):
        print("%s is not a folder (mount your mods folder into the container: -v <folder>:/import:ro)" % a.path, file=sys.stderr)
        return 2
    done = import_mods(a.path, a.dest)
    if not done:
        print("no mod found in %s (a mod's folder holds mod.lua)" % a.path, file=sys.stderr)
        return 1
    subscribe()
    return 0


def cmd_list(a):
    """The mods of a world, and for each whether this server has it: mod.io mods and imported ones are kept in full for the players."""
    for mid, origin, hub, name in modio_mods(a.save):
        if origin == "BuiltInMods":
            state = "game"
        elif origin == "mod.io":
            state = "installed" if hub and installed(hub) else "MISSING"
        else:
            state = "installed" if os.path.isdir(os.path.join(FULL, mid)) else "MISSING (mods import)"
        print("%-8s %-14s %-9s %-10s %s" % (origin, mid[:14], hub or "-", state, name))
    return 0


def subscribe():
    """The game's mod.io library lists as installed only the mods its signed-in user is subscribed to (<user>/AppData/Local/mod.io/<game>/<steam account>/user.json). A server has no mod.io
    account to sign in with, so it gets a local user record subscribed to every mod installed here: the library then reports them, and nothing leaves the machine."""
    try:
        with open(os.path.join(LITE, str(GAME_ID), "metadata", "state.json"), encoding="utf-8") as fh:
            ids = sorted(int(e["ID"]) for e in json.load(fh).get("Mods", []))
    except (OSError, ValueError):
        return 0
    wine = os.environ.get("WINEPREFIX", os.path.join(DATA, "wine"))
    users = os.path.join(wine, "drive_c", "users")
    steam = os.path.join(wine, "drive_c", "Program Files (x86)", "Steam", "userdata")
    accounts = sorted(d for d in (os.listdir(steam) if os.path.isdir(steam) else []) if d.isdigit() and d != "0")
    n = 0
    for u in (sorted(os.listdir(users)) if os.path.isdir(users) else []):
        base = os.path.join(users, u, "AppData", "Local", "mod.io", str(GAME_ID))
        if u == "Public" or not os.path.isdir(os.path.dirname(base)):
            continue
        existing = sorted(d for d in (os.listdir(base) if os.path.isdir(base) else []) if d.isdigit())
        for acc in accounts or existing:
            os.makedirs(os.path.join(base, acc), exist_ok=True)
            blank = {"filename": "", "original": "", "thumb_100x100": "", "thumb_50x50": ""}
            record = {"Avatar": blank, "DeferredUnsubscribes": [], "OAuth": {"expiry": 4102444800, "status": 0, "token": "offline"},
                      "Profile": {"avatar": blank, "date_online": 0, "display_name_portal": "mpfever-server", "id": 1, "profile_url": "https://mod.io", "username": "mpfever-server"},
                      "subscriptions": ids, "version": 1}
            with open(os.path.join(base, acc, "user.json"), "w", encoding="utf-8") as fh:
                json.dump(record, fh)
            n += 1
    return n


def cmd_sync(a):
    conf = load_conf()
    if not conf:
        print("no mod.io access yet: run  mods login", file=sys.stderr)
        return 3
    want = [(mid, hub, name) for mid, origin, hub, name in modio_mods(a.save) if origin == "mod.io" and hub]
    rc, counts = 0, {}
    for mid, hub, name in want:
        try:
            r = install(conf, hub, check=a.check)
        except (urllib.error.URLError, RuntimeError, OSError, zipfile.BadZipFile) as e:
            print("FAILED %s (%s): %s" % (name, hub, e), file=sys.stderr)
            rc = 1
            continue
        counts[r] = counts.get(r, 0) + 1
        if r != "current":
            print("%s: %s" % (r, name))
    if not a.check:
        subscribe()
    print("mods of the world: %d from mod.io (%s)" % (len(want), ", ".join("%d %s" % (v, k) for k, v in sorted(counts.items())) or "none"))
    return rc


def cmd_status(a):
    if not os.path.isdir(FULL):
        print("no mod installed")
        return 0
    for d in sorted(os.listdir(FULL)):
        meta = installed(d) or {}
        print("%-9s %-34s v%-6s file %s" % (d, (meta.get("title") or meta.get("name") or "?")[:34], meta.get("version") or "?", meta.get("file_id") or "?"))
    return 0


def cmd_setup_root(a):
    """The launcher (Mono) and the game (Wine) both read %LOCALAPPDATA%/mod.io/globalsettings.json: RootLocalStoragePath is where they find the mods."""
    home = os.environ.get("HOME", DATA)
    wine = os.environ.get("WINEPREFIX", os.path.join(DATA, "wine"))
    users = os.path.join(wine, "drive_c", "users")
    targets = [(os.path.join(os.environ.get("XDG_DATA_HOME", os.path.join(home, ".local", "share")), "mod.io", "globalsettings.json"), LITE)]
    if os.path.isdir(users):
        for u in sorted(os.listdir(users)):
            if u not in ("Public",) and os.path.isdir(os.path.join(users, u)):
                targets.append((os.path.join(users, u, "AppData", "Local", "mod.io", "globalsettings.json"), WINE_ROOT))
    os.makedirs(LITE, exist_ok=True)
    link = os.path.join(wine, "drive_c", "modio")                  # the game's mod.io library cannot use a Z: folder that exists (Wine error 4390): the folder is reached through C:
    if os.path.isdir(os.path.dirname(link)):
        if os.path.islink(link) and os.readlink(link) != LITE:
            os.remove(link)
        if not os.path.lexists(link):
            os.symlink(LITE, link)
    for path, root in targets:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"RootLocalStoragePath": root}, f)
    subscribe()
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("login"); p.add_argument("--host")
    p = sub.add_parser("list"); p.add_argument("save")
    p = sub.add_parser("sync"); p.add_argument("save"); p.add_argument("--check", action="store_true")
    p = sub.add_parser("import"); p.add_argument("path"); p.add_argument("--dest", required=True)
    sub.add_parser("status")
    sub.add_parser("setup-root")
    a = ap.parse_args(argv)
    try:
        return {"login": cmd_login, "list": cmd_list, "sync": cmd_sync, "status": cmd_status, "import": cmd_import, "setup-root": cmd_setup_root}[a.cmd](a)
    except (RuntimeError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
