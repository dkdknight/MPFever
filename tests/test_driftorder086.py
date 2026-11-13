"""Offline test: tools/drift_diff.py tells "the same work in another order" (0.8.6, #272).

#272 (yoyo and Bence, 2026-11-12 22:04): at step 98381 yoyo's build and Bence's terrain edit, both for the same step, were applied
in another order on each game. Both games made as many additions and removals from the same callers; only the free ids each took
differed, and the tool showed "on A only / on B only" without saying it was an order. It now says SAME WORK, OTHER ORDER and lists
each game's operations made outside the engine's systems, in order, with their callers; a real difference (an entity made on one
game only) is not called an order.
Run: python tests/test_driftorder086.py
"""
import os, sys, tempfile, io

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import drift_diff  # noqa: E402

fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def game(root, name, step_ops, queue):
    d = os.path.join(root, name)
    os.makedirs(d)
    with open(os.path.join(d, "drift_7_steps.txt"), "w") as f:
        f.write("header\nstep <s> ...\n")
        f.write("step 100 queue 5 10 20 adds 1 rems 0 set 1\n")
        adds = sum(1 for o in step_ops if o[0].startswith("+"))
        rems = len(step_ops) - adds
        f.write("step 101 queue %s adds %d rems %d set %d\n" % (queue, adds, rems, hash(tuple(sorted(o[0] for o in step_ops))) & 0xffff))
    with open(os.path.join(d, "drift_7_ops.txt"), "w") as f:
        f.write("header\n<step> ...\n100 +5 AnimalMoveSystem.ecs 2bc0239\n")
        for o, s, c in step_ops:
            f.write("101 %s %s %s\n" % (o, s, c))
    return d


def run(a_ops, b_ops, qa="3 30 1", qb="3 31 2"):
    root = tempfile.mkdtemp()
    da, db = game(root, "a", a_ops, qa), game(root, "b", b_ops, qb)
    buf = []
    r = drift_diff.compare(da, db, 7, out=buf.append)
    return r, "\n".join(buf)


# yoyo: its build first (a01530, 9fff0d), then the terrain (481202 / 48117d); Bence: the terrain first
A = [("+62299", "-", "a01530"), ("+219344", "-", "9fff0d"), ("+345912", "-", "481202"), ("-345912", "-", "48117d")]
B = [("+62299", "-", "481202"), ("-62299", "-", "48117d"), ("+219344", "-", "a01530"), ("+345912", "-", "9fff0d")]
r, txt = run(A, B)
check(r["first_ops_step"] == 101, "the step is found", txt)
check(r.get("same_work_other_order") is True and "SAME WORK, OTHER ORDER" in txt, "same callers, other ids: told as an order", txt)
check("A, in order: +62299@a01530 +219344@9fff0d" in txt and "B, in order: +62299@481202 -62299@48117d" in txt,
      "each game's operations outside the systems, in order, with their callers", txt)

# a real difference: an entity removed on one game only
A2 = [("+10", "LandVehicleMoveSystem.ecs", "2bc0239"), ("-42083", "StockListSystem.ecs", "b4c8e5")]
B2 = [("+10", "LandVehicleMoveSystem.ecs", "2bc0239")]
r2, txt2 = run(A2, B2)
check(r2.get("same_work_other_order") is False and "SAME WORK" not in txt2, "an entity removed on one game only is no order", txt2)
check("-42083 by StockListSystem.ecs" in txt2, "  and is shown on A only", txt2)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
