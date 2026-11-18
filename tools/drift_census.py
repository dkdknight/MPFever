"""Where the drifts of the local tests started (0.9.0, #150): every pair of games (a host and its client of one autotest) that kept
drift rings on both sides, compared with tools/drift_diff.py at their first common check, and the systems of the first difference
counted. Found on 2026-11-18: 3 of 3 drifts since 11-13 began with AnimalMoveSystem on one game only (fixed in 0.9.0).

    python tools/drift_census.py [sessions folder] [--since YYYY-MM-DD]
    (default folder: %TEMP%\\mpfever, where the launcher keeps its sessions)
"""
import collections
import datetime
import glob
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("drift_diff", os.path.join(HERE, "drift_diff.py"))
dd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dd)


def pairs(root, since):
    """(host dir, client dir) of the autotests: the client's folder made within 40 s after the host's."""
    hosts = sorted(glob.glob(os.path.join(root, "Host-*")), key=os.path.getctime)
    clients = sorted(glob.glob(os.path.join(root, "Client-*")), key=os.path.getctime)
    for h in hosts:
        if os.path.getmtime(h) < since or not glob.glob(os.path.join(h, "drift_*_steps.txt")):
            continue
        ht = os.path.getctime(h)
        c = next((c for c in clients if 0 <= os.path.getctime(c) - ht <= 40), None)
        if c and glob.glob(os.path.join(c, "drift_*_steps.txt")):
            yield h, c


def census(root, since, out=print):
    tally = collections.Counter()
    for h, c in pairs(root, since):
        common = sorted(set(dd.find_all(h)) & set(dd.find_all(c)))
        if not common:
            continue
        lines = []
        try:
            r = dd.compare(h, c, common[0], out=lines.append)
        except Exception as e:  # (a file cut short: said and skipped)
            out("%s: %s" % (os.path.basename(h), e))
            continue
        sysl = next((l for l in lines if "systems involved" in l), None)
        what = sysl.split(":", 1)[1].strip() if sysl else ("free-id queue only" if r and r.get("first_queue_step") else "no difference")
        tally[re.sub(r" \(\d+\)", "", what)] += 1
        when = datetime.datetime.fromtimestamp(os.path.getmtime(h)).strftime("%m-%d %H:%M")
        out("%s %s check %d step %s | %s" % (when, os.path.basename(h), common[0], r.get("first_ops_step") if r else "-", what[:110]))
    out("TALLY: " + (", ".join("%s %d" % kv for kv in tally.most_common()) or "no pair with drift rings on both games"))
    return tally


def main(argv):
    root = os.path.join(os.environ.get("TEMP", "."), "mpfever")
    since = 0.0
    args = list(argv)
    if "--since" in args:
        i = args.index("--since")
        since = datetime.datetime.strptime(args[i + 1], "%Y-%m-%d").timestamp()
        del args[i:i + 2]
    if args:
        root = args[0]
    census(root, since)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
