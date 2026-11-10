"""Offline test: no Lua file of the mod uses one of its top-level locals above the line that declares it (0.8.1).

The regression of 0.7.17 (#200/#201/#208, 2026-11-10): REFUND.book, written at line 439 of mpfever_bridge.script.lua, read
SIM.ctTick while "local SIM" is declared at line 772. In REFUND.book that name is therefore the global SIM, nil: "attempt to
index global 'SIM'" at each replay's own step, which aborted the whole simApplyDue of that step on that game (hundreds of times
in the field). Its own test defined a global SIM and passed.

Every .lua file of mod/ is read with tests/luascan.py (scopes followed, comments and strings left out): a name read as a global
that is declared as a top-level local further down in the same file fails. (test_globals081.py checks every global; this one
names the class of the 0.7.17 bug.) Run: python tests/test_localorder081.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import luascan  # noqa: E402

ROOT = os.path.join(HERE, "..", "mod")


def check_file(path=None, src=None):
    r = luascan.scan(path, src)
    toks = r["tokens"]
    out = []
    for name, line, idx in r["reads"]:
        d = r["toplevel"].get(name)
        if d is not None and d > idx:
            out.append((line, name, toks[d][2]))
    return out


fails = []
files = []
for dp, dn, fn in os.walk(ROOT):
    for f in fn:
        if f.endswith(".lua"):
            files.append(os.path.join(dp, f))
for p in sorted(files):
    rel = os.path.relpath(p, os.path.join(HERE, ".."))
    for ln, name, decl in sorted(set(check_file(p))):
        print(f"FAIL {rel}:{ln}: '{name}' read as a global, declared 'local' at line {decl} below")
        fails.append(rel)
print(f"{len(files)} Lua files checked")

found = check_file(src="local T = {}\nfunction T.f() return SIMX.tick end\nlocal SIMX = { tick = 1 }\n")
if not any(n == "SIMX" for _, n, _ in found):
    print("FAIL the checker does not find a local used above its declaration")
    fails.append("probe")
else:
    print("ok   the checker finds a local used above its declaration (the bug of 0.7.17)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
