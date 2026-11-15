"""The ground under each build on every game of a report (0.8.11, the GROUND lines of mod.log, see G.groundProbe).

Every game logs, 30 frames after a build stands, "GROUND <uid> <builder|replay>: <n> points, sum <s>, signature <h>": the terrain's
height at 21 points along each new segment and 6 m to each side. A build whose signature differs between games left the ground
otherwise on one of them (the checks never compare the ground; the animals choose their way by it, #150).

    python tools/ground_diff.py <report folder> [more folders...]
"""
import os, re, sys

LINE = re.compile(r"^(\d\d:\d\d:\d\d) GROUND (\S+) (builder|replay): (\d+) points, sum (-?[\d.]+), signature (\d+)")


def secs(hms):
    h, m, s = (int(x) for x in hms.split(":"))
    return h * 3600 + m * 60 + s


def scan(folders):
    """{uid: [(seconds, game, who, n, sum, sig)]}: every GROUND line (a build's uid comes back after each resynchronisation, the
    counters start again: one uid may name several builds of a session)"""
    by = {}
    for root in folders:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                if f != "mod.log":
                    continue
                # (the folder given and the folder below it: two session folders given each have the relative path ".")
                game = os.path.join(os.path.basename(os.path.normpath(root)), os.path.relpath(dp, root))
                with open(os.path.join(dp, f), encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        m = LINE.match(line)
                        if m:
                            by.setdefault(m.group(2), []).append((secs(m.group(1)), game, m.group(3), int(m.group(4)), float(m.group(5)), int(m.group(6))))
    return by


def builds(lines, window=90):
    """The lines of one uid grouped by build: a builder's line with each other game's nearest line within window seconds (the
    clocks of two PCs may differ by a few seconds); without a builder's line, lines within window of each other"""
    groups = []
    for b in [x for x in lines if x[2] == "builder"]:
        g = {b[1]: b}
        for x in lines:
            if x[1] != b[1] and abs(x[0] - b[0]) <= window and (x[1] not in g or abs(x[0] - b[0]) < abs(g[x[1]][0] - b[0])):
                g[x[1]] = x
        groups.append(g)
    return groups


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    by = scan(argv[1:])
    seen, differ = 0, 0
    for uid, lines in sorted(by.items()):
        for games in builds(lines):
            if len(games) < 2:
                continue
            seen += 1
            if len({v[5] for v in games.values()}) > 1:
                differ += 1
                print("GROUND DIFFERS for build", uid)
                for g, v in sorted(games.items()):
                    print("   %-50s %02d:%02d:%02d %-7s %d points, sum %.4f, signature %d" % (g[:50], v[0] // 3600, v[0] // 60 % 60, v[0] % 60, v[2], v[3], v[4], v[5]))
    print("%d build(s) seen on two games or more, %d with another ground on one game" % (seen, differ))
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
