"""Offline test: the update takes the players' archive by its exact name, and no release asset can be taken for it (0.9.1).

2026-11-18, right after 0.9.0 was published: every 0.8.17 failed to update, "Update failed: MPFever.exe is missing from the update".
0.9.0's release held a new asset, MPFever-0.9.0-relay-win-x64.zip (the Windows relay). The updater (Updater.Newest) takes the first
asset whose name starts with "MPFever" and ends with ".zip" and is not the server's; GitHub lists the assets by name, and "-" sorts
before ".": the relay's zip came before MPFever-0.9.0.zip, and the players downloaded the relay. Renamed on the release
(Relay-MPFever-0.9.0-win-x64.zip), the update worked again.
The fix, both ways: the release workflow names the relay's archives Relay-MPFever-<version>-... (the updaters already installed,
0.8.17 and 0.9.0, keep their rule: no other asset may ever look like theirs), and the updater takes the archive named exactly
MPFever-<version>.zip (or -server.zip), else the first zip that is not the relay's (MPFEVER_UPDATEEXACT=0: as before).
The launcher's self-test (SelfTest.RunUpdater) runs the real Newest() on 0.9.0's asset list; this test checks the workflow's names
and replays both rules on that list.
Run: python tests/test_updatepick091.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def old_rule(assets, server=False):
    """0.8.17's and 0.9.0's Updater.Newest: the first MPFever*.zip in GitHub's order, the server's for a server."""
    zips = [a for a in assets if a.lower().startswith("mpfever") and a.lower().endswith(".zip")]
    is_server = lambda a: a.lower().endswith("-server.zip")
    return (next((a for a in zips if is_server(a)), None) if server else None) or next((a for a in zips if not is_server(a)), None)


def new_rule(assets, version, server=False):
    zips = [a for a in assets if a.lower().startswith("mpfever") and a.lower().endswith(".zip")]
    named = lambda n: next((a for a in zips if a.lower() == n.lower()), None)
    z = (named(f"MPFever-{version}-server.zip") if server else None) or named(f"MPFever-{version}.zip")
    if z:
        return z
    zips = [a for a in zips if "relay" not in a.lower()]
    is_server = lambda a: a.lower().endswith("-server.zip")
    return (next((a for a in zips if is_server(a)), None) if server else None) or next((a for a in zips if not is_server(a)), None)


def main():
    # 0.9.0's release as GitHub listed it (sorted by name)
    rel090 = sorted(["MPFever-0.9.0.zip", "MPFever-0.9.0-server.zip", "MPFever-0.9.0-relay-linux-x64.tar.gz", "MPFever-0.9.0-relay-win-x64.zip"])
    check("before (the bug): 0.8.17's rule takes the relay's zip on 0.9.0's release", old_rule(rel090) == "MPFever-0.9.0-relay-win-x64.zip", old_rule(rel090))
    check("after: the new rule takes MPFever-0.9.0.zip, the server MPFever-0.9.0-server.zip",
          new_rule(rel090, "0.9.0") == "MPFever-0.9.0.zip" and new_rule(rel090, "0.9.0", True) == "MPFever-0.9.0-server.zip")

    # the release workflow's archive names, for a version: what the old rule (every installed updater) would take
    wf = open(os.path.join(ROOT, ".github", "workflows", "release.yml"), encoding="utf-8").read()
    names = re.findall(r'\$?f\s*=\s*"([^"]+)"', wf)
    check("the release workflow names its relay archives", len(names) >= 2, names)
    v = "1.2.3"
    made = [n.replace("$v", v) for n in names]
    made += [f"MPFever-{v}.zip", f"MPFever-{v}-server.zip"]   # build.bat's
    made = sorted(made)
    check("every asset of a release: the old rule (0.8.17, 0.9.0) still takes the players' archive", old_rule(made) == f"MPFever-{v}.zip", (made, old_rule(made)))
    check("  and the server's for a server", old_rule(made, True) == f"MPFever-{v}-server.zip", old_rule(made, True))
    bad = [n for n in made if n.lower().startswith("mpfever") and n.lower().endswith(".zip") and n not in (f"MPFever-{v}.zip", f"MPFever-{v}-server.zip")]
    check("no other release asset starts with \"MPFever\" and ends with \".zip\"", not bad, bad)

    up = open(os.path.join(ROOT, "launcher", "Updater.cs"), encoding="utf-8-sig").read()
    check("Updater.Newest: the exact names first, the relay's left out, MPFEVER_UPDATEEXACT=0: as before",
          'named("MPFever-" + vs + ".zip")' in up and 'IndexOf("relay", StringComparison.OrdinalIgnoreCase) < 0' in up
          and 'GetEnvironmentVariable("MPFEVER_UPDATEEXACT") != "0"' in up)
    st = open(os.path.join(ROOT, "launcher", "SelfTest.cs"), encoding="utf-8-sig").read()
    check("the launcher's self-test runs the real Newest() on 0.9.0's asset list", 'Asset("MPFever-0.9.0-relay-win-x64.zip")' in st and "u3old" in st)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
