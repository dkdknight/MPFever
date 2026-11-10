"""A small static reader of Lua files for the tests (0.8.1): it follows the scopes of a file (function parameters, locals, for
variables, blocks) and lists the names used as globals, the way luacheck does, without any download.

    scan(path) -> {
        "reads":  [(name, line, token index)],    a name read where no enclosing scope declares it
        "writes": [(name, line, in_function)],    a name assigned where no enclosing scope declares it (a global made)
        "toplevel": {name: token index},          the file's top-level locals and where they are declared
        "tokens": [...],
    }
Used by test_localorder081.py (a local used above its declaration) and test_globals081.py (unknown globals).
"""
import re

KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil",
            "not", "or", "repeat", "return", "then", "true", "until", "while"}


def tokens(src):
    """(kind, value, line): kind = name, num, str, op; comments dropped, a string gives ("str", "", line)."""
    i, n, line = 0, len(src), 1
    out = []
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if c in " \t\r\f\v":
            i += 1; continue
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:i + 64])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            line += src.count("\n", i, j); i = j; continue
        m = re.match(r"\[(=*)\[", src[i:i + 64])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(("str", "", line)); line += src.count("\n", i, j); i = j; continue
        if c in "\"'":
            j = i + 1
            start = line
            while j < n and src[j] != c:
                if src[j] == "\\":
                    if src[j + 1:j + 2] == "\n": line += 1
                    j += 2; continue
                if src[j] == "\n": line += 1
                j += 1
            out.append(("str", "", start)); i = j + 1; continue
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", src[i:i + 256])
        if m:
            out.append(("name", m.group(0), line)); i += len(m.group(0)); continue
        if c.isdigit() or (c == "." and src[i + 1:i + 2].isdigit()):
            m = re.match(r"0[xX][0-9a-fA-F.]*(?:[pP][+-]?\d+)?|\d*\.?\d*(?:[eE][+-]?\d+)?", src[i:i + 64])
            out.append(("num", m.group(0), line)); i += max(1, len(m.group(0))); continue
        for op in ("...", "..", "::", "==", "~=", "<=", ">=", "//", "<<", ">>"):
            if src.startswith(op, i):
                out.append(("op", op, line)); i += len(op); break
        else:
            out.append(("op", c, line)); i += 1
    return out


def scan(path=None, src=None):
    if src is None:
        src = open(path, encoding="utf-8-sig").read()
    toks = tokens(src)
    N = len(toks)
    scopes = [set()]
    toplevel = {}
    reads, writes = [], []
    brace = []
    pending_for = None
    fdepth = [0]              # functions open, to tell a global made inside a function

    def declared(v):
        return any(v in s for s in scopes)

    def push(names=(), fn=False):
        scopes.append(set(names)); fdepth.append(fdepth[-1] + (1 if fn else 0))

    def pop():
        if len(scopes) > 1:
            scopes.pop(); fdepth.pop()

    i = 0
    while i < N:
        k, v, ln = toks[i]
        prev = toks[i - 1] if i > 0 else ("", "", 0)
        nxt = toks[i + 1] if i + 1 < N else ("", "", 0)
        if k == "op":
            if v in "({[": brace.append(v)
            elif v in ")}]" and brace: brace.pop()
            i += 1; continue
        if k != "name":
            i += 1; continue
        if v == "local":
            if nxt[1] == "function":
                name = toks[i + 2][1]
                scopes[-1].add(name)
                if len(scopes) == 1: toplevel.setdefault(name, i)
                i += 1
                continue
            j = i + 1
            names = []
            while j < N and toks[j][0] == "name":
                names.append(toks[j][1]); j += 1
                if j < N and toks[j][1] == "<": j += 3
                if j < N and toks[j][1] == ",": j += 1; continue
                break
            for nm in names:
                scopes[-1].add(nm)
                if len(scopes) == 1: toplevel.setdefault(nm, i)
            i = j
            continue
        if v == "function":
            j = i + 1
            fname = []
            while j < N and toks[j][1] != "(":
                fname.append(toks[j]); j += 1
            if fname and fname[0][0] == "name":
                base = fname[0][1]
                if len(fname) > 1:
                    if not declared(base): reads.append((base, fname[0][2], i + 1))
                elif not declared(base):
                    writes.append((base, fname[0][2], fdepth[-1] > 0))
            j += 1
            params = []
            while j < N and toks[j][1] != ")":
                if toks[j][0] == "name": params.append(toks[j][1])
                j += 1
            if any(t[1] == ":" for t in fname): params.append("self")
            push(params, fn=True)
            brace.append("(")
            i = j
            continue
        if v == "for":
            j = i + 1
            names = []
            while j < N and toks[j][1] not in ("=", "in"):
                if toks[j][0] == "name": names.append(toks[j][1])
                j += 1
            pending_for = names
            i = j; continue
        if v == "do":
            push(pending_for or ()); pending_for = None; i += 1; continue
        if v == "then" or v == "repeat":
            push(); i += 1; continue
        if v in ("elseif", "else"):
            pop()
            if v == "else": push()
            i += 1; continue
        if v in ("until", "end"):
            pop(); i += 1; continue
        if v in KEYWORDS:
            i += 1; continue
        if prev[1] in (".", ":", "goto", "::") or nxt[1] == "::":
            i += 1; continue
        if nxt[1] == "=" and brace and brace[-1] == "{" and prev[1] in ("{", ",", ";"):
            i += 1; continue
        if not declared(v):
            # an assignment target: NAME = / NAME, x = (at a statement's start, outside brackets)
            if not (brace and brace[-1] in "([{") and nxt[1] in ("=", ",") and prev[1] not in ("=", "==", "(", ",", "return", "and", "or", "not", "..", "+", "-", "*", "/", "%", "^", "#", "<", ">", "<=", ">=", "~="):
                writes.append((v, ln, fdepth[-1] > 0))
            elif not (brace and brace[-1] in "([{") and prev[1] == "," and nxt[1] in ("=", ","):
                writes.append((v, ln, fdepth[-1] > 0))
            else:
                reads.append((v, ln, i))
        i += 1
    return {"reads": reads, "writes": writes, "toplevel": toplevel, "tokens": toks}
