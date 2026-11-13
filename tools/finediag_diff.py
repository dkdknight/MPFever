"""Compares two games' fine diagnostic files (finediag_<check>.txt, MPFEVER_FINEDIAG=1, mod/mpfever_1/content/mpfever_finediag.lua)
and says where they first differ: the step (game time), what (an aircraft, the animals, the persons/cargo, the land vehicles)
and, for an aircraft or an animal, which numbers.

Usage: python tools/finediag_diff.py <file of game A> <file of game B>
   or: python tools/finediag_diff.py <session folder A> <session folder B>   (their latest common finediag_<check>.txt)
"""
import os, re, sys, glob


def parse(path):
    steps, order, cur = {}, [], None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if line.startswith("step "):
                cur = line[5:].strip()
                steps[cur] = {}
                order.append(cur)
            elif cur is not None and line[:2] in ("A ", "a "):
                kind, ent, rest = (line.split(" ", 2) + ["", ""])[:3]
                steps[cur][kind + ent] = rest
            elif cur is not None and line[:2] in ("N ", "P ", "L "):
                steps[cur][line[0]] = line[2:]
    return steps, order


def fields(s):
    out = {}
    for tok in s.split(" "):
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def pick(a, b):
    if os.path.isdir(a) and os.path.isdir(b):
        fa = {re.search(r"finediag_(\w+)\.txt$", p).group(1): p for p in glob.glob(os.path.join(a, "finediag_*.txt"))}
        fb = {re.search(r"finediag_(\w+)\.txt$", p).group(1): p for p in glob.glob(os.path.join(b, "finediag_*.txt"))}
        common = sorted(set(fa) & set(fb), key=lambda x: int(x) if x.isdigit() else 0)
        if common:
            return fa[common[-1]], fb[common[-1]]
        if fa and fb:
            ka = max(fa, key=lambda x: int(x) if x.isdigit() else 0)
            kb = max(fb, key=lambda x: int(x) if x.isdigit() else 0)
            print("no common check: comparing", ka, "and", kb)
            return fa[ka], fb[kb]
        sys.exit("no finediag_*.txt in one of the folders")
    return a, b


def compare(pa, pb, out=print):
    A, oa = parse(pa)
    B, ob = parse(pb)
    common = [s for s in oa if s in B]
    out(f"{os.path.basename(pa)}: {len(oa)} steps, {os.path.basename(pb)}: {len(ob)} steps, {len(common)} in common"
        + (f" ({common[0]} .. {common[-1]})" if common else ""))
    if not common:
        return None
    for s in common:
        x, y = A[s], B[s]
        if x == y:
            continue
        out(f"FIRST DIFFERENCE at step {s} (the step before, {common[common.index(s) - 1] if common.index(s) else '-'}, alike)")
        keys = sorted(set(x) | set(y))
        found = []
        for k in keys:
            if x.get(k) == y.get(k):
                continue
            found.append(k)
            if k.startswith("A"):
                if k not in x or k not in y:
                    out(f"  aircraft {k[1:]}: only in {'A' if k in x else 'B'}")
                    continue
                fx, fy = fields(x[k]), fields(y[k])
                diff = [f for f in sorted(set(fx) | set(fy)) if fx.get(f) != fy.get(f)]
                out(f"  aircraft {k[1:]}: {len(diff)} number(s) differ")
                for f in diff[:20]:
                    out(f"     {f}: {fx.get(f)} | {fy.get(f)}")
            elif k.startswith("a"):
                out(f"  animal {k[1:]}: {x.get(k)} | {y.get(k)}")
            else:
                name = {"N": "animals (sums)", "P": "persons and cargo", "L": "land vehicles"}[k]
                out(f"  {name}:")
                if k == "P":
                    px = dict(p.strip().split(" ", 1) for p in x.get(k, "").split(";") if p.strip())
                    py = dict(p.strip().split(" ", 1) for p in y.get(k, "").split(";") if p.strip())
                    for c in sorted(set(px) | set(py)):
                        if px.get(c) != py.get(c):
                            out(f"     {c}: {px.get(c)} | {py.get(c)}")
                else:
                    out(f"     {x.get(k)} | {y.get(k)}")
        return s, found
    out("no difference in the common steps")
    return None


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    compare(*pick(sys.argv[1], sys.argv[2]))
