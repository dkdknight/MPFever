"""Lists the Lua errors in game logs: autotest session folders, or players' reports unpacked (0.8.1, LUAERRGATE).

The regression of 0.7.17 ("attempt to index global 'SIM'") sat in the logs of autotests judged "in sync" and in the field's
reports for a day. Run on any folder before saying "no regression":
    python tests/check_game_logs.py <folder> [<folder>...]      (searches *.log below each folder)
Exit code 1 when a Lua error line is found. The same rule as the launcher's autotest (MainForm.LuaErrorLines).
"""
import os, re, sys

PATTERN = re.compile(r"attempt to (index|call|perform arithmetic|compare|concatenate|get length)|simulation apply failed")


def scan(folders):
    found = {}
    for root in folders:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                if not f.endswith(".log"):
                    continue
                p = os.path.join(dp, f)
                try:
                    with open(p, encoding="utf-8", errors="replace") as h:
                        for line in h:
                            if PATTERN.search(line):
                                key = re.sub(r"\d+", "N", re.sub(r'\[string "[^"]*"\]', "[file]", line.strip()))[:200]
                                found.setdefault(key, []).append(p)
                except OSError:
                    pass
    return found


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    res = scan(sys.argv[1:])
    for key, where in sorted(res.items(), key=lambda kv: -len(kv[1])):
        print(f"{len(where):6d}  {key}")
        print(f"        e.g. {where[0]}")
    print("no Lua error" if not res else f"\n{sum(len(v) for v in res.values())} Lua error line(s)")
    sys.exit(1 if res else 0)
