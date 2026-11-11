"""Where two games of a session parted (the drift diagnostic of 0.8.2, MPFEVER_DRIFTDIAG, on by default).

When the host's check finds a lasting difference, every game writes, in its session folder (and so in « Report a problem »):
    drift_<check>_steps.txt   the digest of each of the last 16384 simulation steps: the free-id queue (size, sum, hash) and the
                              step's entity additions and removals (counts, an order-free hash of their ids)
    drift_<check>_ops.txt     the last 131072 entities the simulation's engine added (+) or removed (-): step, id, the engine
                              system whose update made it (its class name, the same on Steam, GOG and Epic), caller
    sdump_drift_<0..2>.txt    the mod's dump of that check (people, town buildings, vehicles, game scripts)
This compares two games' files of the same check:
  1. the first step whose additions/removals differ (an entity made or removed on one game only, or at another step);
  2. that step's operations on each game, those of one game only first, with the system that made them;
  3. the first step whose free-id queue differs (from there every new entity takes another id: people, town buildings).

    python tools/drift_diff.py <folder of game A> <folder of game B> [check]
    (a folder: a session folder, or a report's folder, or a player's folder in a report; searched below for drift_*_steps.txt)
"""
import collections, os, re, sys


def find_all(folder):
    found = {}
    for dp, dn, fn in os.walk(folder):
        for f in fn:
            m = re.match(r"drift_(\d+)_steps\.txt$", f)
            if m:
                found[int(m.group(1))] = dp
    return found


def pick(dir_a, dir_b, check=None):
    """The check to compare: the one asked for, else the latest both games wrote, else the latest of each (the steps are
    numbered alike on every game: two dumps whose steps overlap compare all the same)."""
    fa, fb = find_all(dir_a), find_all(dir_b)
    if check is not None:
        return (check, fa.get(check), check, fb.get(check))
    common = sorted(set(fa) & set(fb))
    if common:
        n = common[-1]
        return (n, fa[n], n, fb[n])
    na = max(fa) if fa else None
    nb = max(fb) if fb else None
    return (na, fa.get(na), nb, fb.get(nb))


STEP = re.compile(r"step (\d+) queue (\d+) (\d+) (\d+) adds (\d+) rems (\d+) set (\d+)")
OP = re.compile(r"(\d+) ([+-])(-?\d+) (\S+) (\S+)")


def steps(path):
    out = {}
    for l in open(path, encoding="utf-8", errors="replace"):
        m = STEP.match(l)
        if m:
            s = int(m.group(1))
            out[s] = {"queue": (int(m.group(2)), int(m.group(3)), int(m.group(4))), "ops": (int(m.group(5)), int(m.group(6)), int(m.group(7)))}
    return out


def ops(path):
    by = collections.defaultdict(list)
    for l in open(path, encoding="utf-8", errors="replace"):
        m = OP.match(l)
        if m:
            by[int(m.group(1))].append((m.group(2) + m.group(3), m.group(4), m.group(5)))
    return by


def compare(dir_a, dir_b, check=None, out=print):
    na, pa, nb, pb = pick(dir_a, dir_b, check)
    if not pa or not pb:
        out("no drift files in both folders (A: %s, B: %s)" % (na, nb))
        return None
    sa, sb = steps(os.path.join(pa, "drift_%d_steps.txt" % na)), steps(os.path.join(pb, "drift_%d_steps.txt" % nb))
    common = sorted(set(sa) & set(sb))
    out("checks %d (A) and %d (B): %d steps in common (%s .. %s)" % (na, nb, len(common), common[0] if common else "-", common[-1] if common else "-"))
    first_ops = next((s for s in common if sa[s]["ops"] != sb[s]["ops"]), None)
    first_q = next((s for s in common if sa[s]["queue"] != sb[s]["queue"]), None)
    res = {"check": na, "check_b": nb, "first_ops_step": first_ops, "first_queue_step": first_q, "only_a": [], "only_b": []}
    if first_ops is None:
        out("the steps' entity operations are alike in every step both games kept")
    else:
        out("FIRST STEP WHOSE ENTITY OPERATIONS DIFFER: %d (A adds/rems %d/%d, B %d/%d)" % (first_ops, sa[first_ops]["ops"][0], sa[first_ops]["ops"][1], sb[first_ops]["ops"][0], sb[first_ops]["ops"][1]))
        oa = ops(os.path.join(pa, "drift_%d_ops.txt" % na)).get(first_ops, [])
        ob = ops(os.path.join(pb, "drift_%d_ops.txt" % nb)).get(first_ops, [])
        ca = collections.Counter((o, s) for o, s, _ in oa)
        cb = collections.Counter((o, s) for o, s, _ in ob)
        res["only_a"] = sorted((ca - cb).elements())
        res["only_b"] = sorted((cb - ca).elements())
        if not oa and not ob:
            out("  (that step's operations are older than the rings: only the digests show it)")
        out("  on A only: " + (", ".join("%s by %s" % x for x in res["only_a"][:20]) or "-"))
        out("  on B only: " + (", ".join("%s by %s" % x for x in res["only_b"][:20]) or "-"))
        systems = collections.Counter(s for _, s in res["only_a"] + res["only_b"])
        out("  systems involved: " + (", ".join("%s (%d)" % kv for kv in systems.most_common()) or "-"))
    if first_q is not None:
        out("first step whose free-id queue differs: %d (A %s, B %s)" % (first_q, sa[first_q]["queue"], sb[first_q]["queue"]))
    else:
        out("the free-id queues are alike in every step both games kept")
    return res


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    r = compare(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else None)
    sys.exit(0 if r is not None else 1)
