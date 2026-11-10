"""Offline test: no Lua file of the mod uses one of its top-level locals above the line that declares it (0.8.1).

The regression of 0.7.17 (#200/#201/#208, 2026-11-10): REFUND.book, written at line 439 of mpfever_bridge.script.lua, read
SIM.ctTick while "local SIM" is declared at line 772. In REFUND.book that name is therefore the global SIM, nil: "attempt to
index global 'SIM'" at each replay's own step, which aborted the whole simApplyDue of that step on that game (hundreds of times
in the field). Its own test defined a global SIM and passed.

This test reads every .lua file of mod/ (comments and strings left out), follows the scopes (function parameters, locals,
for variables, blocks) and reports every name read as a global (not declared in any enclosing scope at that point) that is
declared as a top-level local further down in the same file: the class of that bug. Run: python tests/test_localorder081.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "mod")

KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil",
            "not", "or", "repeat", "return", "then", "true", "until", "while"}


def tokens(src):
    """(kind, value, line): kind = name, op (comments and strings dropped, a string gives ("str", "", line))."""
    i, n, line = 0, len(src), 1
    out = []
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if c in " \t\r":
            i += 1; continue
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            line += src.count("\n", i, j); i = j; continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            line += src.count("\n", i, j); out.append(("str", "", line)); i = j; continue
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    if src[j + 1:j + 2] == "\n": line += 1
                    j += 2; continue
                if src[j] == "\n": line += 1
                j += 1
            out.append(("str", "", line)); i = j + 1; continue
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", src[i:])
        if m:
            out.append(("name", m.group(0), line)); i += len(m.group(0)); continue
        m = re.match(r"0[xX][0-9a-fA-F.]+(?:[pP][+-]?\d+)?|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?", src[i:])
        if m and (c.isdigit() or (c == "." and src[i + 1:i + 2].isdigit())):
            out.append(("num", m.group(0), line)); i += len(m.group(0)); continue
        for op in ("...", "..", "::", "==", "~=", "<=", ">=", "//", "<<", ">>"):
            if src.startswith(op, i):
                out.append(("op", op, line)); i += len(op); break
        else:
            out.append(("op", c, line)); i += 1
    return out


def check_file(path):
    src = open(path, encoding="utf-8-sig").read()
    toks = tokens(src)
    # top-level locals (depth 0) and the token index where each is declared
    problems = []
    scopes = [set()]          # names declared, innermost last
    kinds = ["file"]          # what opened each scope
    toplevel = {}             # name -> first declaration index at depth 0
    pending_for = None
    pending_params = None
    brace = []                # bracket stack to know table constructors
    reads = []                # (index, name, line, depth-0 visible names snapshot not needed)
    i = 0
    N = len(toks)

    def push(kind, names=()):
        scopes.append(set(names)); kinds.append(kind)

    def pop():
        if len(scopes) > 1:
            scopes.pop(); kinds.pop()

    while i < N:
        k, v, ln = toks[i]
        prev = toks[i - 1] if i > 0 else ("", "", 0)
        nxt = toks[i + 1] if i + 1 < N else ("", "", 0)
        if k == "op" and v in "({[":
            brace.append(v)
        elif k == "op" and v in ")}]":
            if brace: brace.pop()
        if k == "name" and v == "local":
            if nxt[1] == "function":
                name = toks[i + 2][1]
                scopes[-1].add(name)
                if len(scopes) == 1: toplevel.setdefault(name, i)
                i += 1  # "function" handled next round (its parameters, its scope), its name already declared
                continue
            # local a, b <attrib> = ...: the names are visible after the statement; reads in the expression come first, which
            # matters little here (declared names are added at once: a read of the same name in its own initializer is rare)
            j = i + 1
            names = []
            while j < N and toks[j][0] == "name":
                names.append(toks[j][1])
                j += 1
                if j < N and toks[j][1] == "<":  # attribute
                    j += 3
                if j < N and toks[j][1] == ",":
                    j += 1; continue
                break
            # the initializer's reads see the names undeclared: scan them first by declaring after the expression is passed
            decl_at = j
            for nm in names:
                if len(scopes) == 1: toplevel.setdefault(nm, i)
            # declare now but remember: reads before decl_at belong to the expression (handled by deferring)
            deferred = (names, decl_at)
            i = j
            # walk the expression tokens normally; declare when the statement ends: approximated by declaring right away
            for nm in names: scopes[-1].add(nm)
            continue
        if k == "name" and v == "function":
            # function name(params) / function a.b:c(params) / function(params)
            j = i + 1
            fname = []
            while j < N and toks[j][1] != "(":
                fname.append(toks[j]); j += 1
            # a global function name read: "function NAME(" assigns NAME (not a read); "function A.b(" reads A
            if fname and fname[0][0] == "name" and len(fname) > 1:
                base = fname[0][1]
                if not any(base in s for s in scopes): reads.append((i + 1, base, fname[0][2]))
            j += 1
            params = []
            while j < N and toks[j][1] != ")":
                if toks[j][0] == "name": params.append(toks[j][1])
                j += 1
            if any(t[1] == ":" for t in fname): params.append("self")
            push("function", params)
            brace.append("(")
            i = j  # at ")": the bracket stack pops it next round
            continue
        if k == "name" and v == "for":
            j = i + 1
            names = []
            while j < N and toks[j][1] not in ("=", "in"):
                if toks[j][0] == "name": names.append(toks[j][1])
                j += 1
            pending_for = names
            i += 1
            continue
        if k == "name" and v == "do":
            push("do", pending_for or ())
            pending_for = None
            i += 1; continue
        if k == "name" and v == "then":
            push("then"); i += 1; continue
        if k == "name" and v in ("elseif", "else"):
            pop()
            if v == "else": push("else")
            i += 1; continue
        if k == "name" and v == "repeat":
            push("repeat"); i += 1; continue
        if k == "name" and v == "until":
            pop(); i += 1; continue
        if k == "name" and v == "end":
            pop(); i += 1; continue
        if k == "name" and v not in KEYWORDS:
            if prev[1] in (".", ":", "goto", "::") or nxt[1] == "::":
                i += 1; continue
            # a table constructor's field name: { name = ... }
            if nxt[1] == "=" and brace and brace[-1] == "{" and prev[1] in ("{", ",", ";"):
                i += 1; continue
            if not any(v in s for s in scopes):
                reads.append((i, v, ln))
        i += 1

    for idx, name, ln in reads:
        d = toplevel.get(name)
        if d is not None and d > idx:
            problems.append((ln, name, toks[d][2]))
    return problems


fails = []
files = []
for dp, dn, fn in os.walk(ROOT):
    for f in fn:
        if f.endswith(".lua"):
            files.append(os.path.join(dp, f))
for p in sorted(files):
    probs = check_file(p)
    rel = os.path.relpath(p, os.path.join(HERE, ".."))
    seen = set()
    for ln, name, decl in probs:
        if (name, ln) in seen: continue
        seen.add((name, ln))
        print(f"FAIL {rel}:{ln}: '{name}' read as a global, declared 'local' at line {decl} below")
        fails.append(rel)
print(f"{len(files)} Lua files checked")

# the checker itself finds the bug of 0.7.17
probe = "local T = {}\nfunction T.f() return SIMX.tick end\nlocal SIMX = { tick = 1 }\n"
tmp = os.path.join(HERE, "_localorder_probe.lua")
open(tmp, "w").write(probe)
try:
    found = check_file(tmp)
finally:
    os.remove(tmp)
if not any(n == "SIMX" for _, n, _ in found):
    print("FAIL the checker does not find a local used above its declaration")
    fails.append("probe")
else:
    print("ok   the checker finds a local used above its declaration (the bug of 0.7.17)")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
