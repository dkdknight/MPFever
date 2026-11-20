"""Signatures of the engine places the native module uses, so that it finds them again in another game build.

    python tools/mksigs.py make <TransportFever3.exe>     (the build of tools/targets_<build>.txt, today 40420)
        writes native/mpfever_sigs.txt: one signature per place, each found exactly once in the executable's code
    python tools/mksigs.py check <TransportFever3.exe>    (a new game build)
        says which places native/mpfever_sigs.txt finds there (exactly once), and their addresses

Requires: pip install pefile capstone

A signature is the bytes of a few instructions, with ?? for what changes from one build to the next even when the code
does not: the 32-bit distances of calls and jumps and the displacements of RIP-relative operands. It starts at the place
(or a few instructions before it, when the place's own code is not unique) and grows one instruction at a time until it
matches exactly once in .text. The native module reads native/mpfever_sigs.txt (shipped with MPFever) only on a game build
it does not know (see "Targets by signature" in mpfever_native.cpp).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MIN_BYTES = 12
MAX_BYTES = 128
MAX_BACK = 12          # instructions of context tried before a place whose own code is not unique


def load(exe):
    import pefile
    pe = pefile.PE(exe, fast_load=False)
    text = next(s for s in pe.sections if s.Name.rstrip(b"\0") == b".text")
    data = text.get_data()
    funcs = []
    for e in getattr(pe, "DIRECTORY_ENTRY_EXCEPTION", []) or []:
        funcs.append((e.struct.BeginAddress, e.struct.EndAddress))
    funcs.sort()
    return pe, text.VirtualAddress, data, funcs


def disasm():
    import capstone
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = True
    return md


def wildcards(ins):
    """Positions (in the instruction) of the bytes that change between builds."""
    import capstone.x86 as x86
    wild = set()
    if ins.disp_size and ins.disp_offset:
        for op in ins.operands:
            if op.type == x86.X86_OP_MEM and op.mem.base == x86.X86_REG_RIP:
                wild.update(range(ins.disp_offset, ins.disp_offset + ins.disp_size))
    if ins.imm_size == 4 and ins.imm_offset and (ins.group(1) or ins.group(2) or ins.group(7)):   # jump, call, relative branch
        wild.update(range(ins.imm_offset, ins.imm_offset + 4))
    if ins.imm_size == 8 and ins.imm_offset:   # movabs of an address
        wild.update(range(ins.imm_offset, ins.imm_offset + 8))
    return wild


def regex_of(pat):
    out = []
    for b in pat:
        out.append(b"." if b is None else re.escape(bytes([b])))
    return re.compile(b"".join(out), re.DOTALL)


def count(data, pat, limit=2):
    n = 0
    for _ in regex_of(pat).finditer(data):
        n += 1
        if n >= limit:
            break
    return n


def text_of(pat):
    return " ".join("??" if b is None else "%02X" % b for b in pat)


def func_of(funcs, rva):
    lo, hi = 0, len(funcs)
    while lo < hi:
        mid = (lo + hi) // 2
        if funcs[mid][0] <= rva:
            lo = mid + 1
        else:
            hi = mid
    if lo and funcs[lo - 1][0] <= rva < funcs[lo - 1][1]:
        return funcs[lo - 1][0]
    return None


def boundaries(md, data, base, start, until):
    """Instruction starts from start (a function's) up to until."""
    out = []
    at = start
    while at < until:
        ins = next(md.disasm(data[at - base:at - base + 16], at), None)
        if ins is None:
            return None
        out.append(at)
        at += ins.size
    return out if at == until else None


def signature(md, data, base, start, anchor):
    """The shortest unique signature that starts at start and covers anchor; None if there is none within MAX_BYTES."""
    pat = []
    at = start
    while len(pat) < MAX_BYTES:
        ins = next(md.disasm(data[at - base:at - base + 16], at), None)
        if ins is None:
            return None
        wild = wildcards(ins)
        for i, b in enumerate(ins.bytes):
            pat.append(None if i in wild else b)
        at += ins.size
        if at > anchor and len(pat) >= MIN_BYTES and count(data, pat) == 1:
            # (no trailing wildcards)
            while pat and pat[-1] is None:
                pat.pop()
            return pat
    return None


def read_targets(path):
    targets, rules = [], {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        if line[0] == "rule":
            rules[int(line[1], 16)] = int(line[2])
            continue
        targets.append((line[0], int(line[1], 16)))
    return targets, rules


def read_sites20c(path):
    sites = []
    for m in re.finditer(r"\{ 0x([0-9a-f]+), (\d+), \{ ([^}]*) \}, (\d+), (\d+) \}", open(path, encoding="utf-8").read()):
        sites.append((int(m.group(1), 16), int(m.group(2)), int(m.group(4)), int(m.group(5))))
    return sites


def make(exe, build="40420", targets_path=None, out=None):
    pe, base, data, funcs = load(exe)
    md = disasm()
    targets, rules = read_targets(targets_path or os.path.join(HERE, "targets_%s.txt" % build))
    sites = read_sites20c(os.path.join(ROOT, "native", "sites20c.h")) if targets_path is None else []
    lines = ["# MPFever: the engine places of the native module by signature (made by tools/mksigs.py from TransportFever3.exe",
             "# build %s, link timestamp %08x). Read by the native module on a game build it does not know." % (build, pe.FILE_HEADER.TimeDateStamp),
             "#   <key> <offset> <signature>           the place is <offset> bytes after the start of the match",
             "#   site20c <rule> <dst> <base> <len> <offset> <signature>   a reading of the local-player word (+0x20C)"]
    failed = 0

    def one(rva):
        # the place's own code first, then a few instructions of context before it (inside its function)
        sig = signature(md, data, base, rva, rva)
        if sig:
            return 0, sig
        f = func_of(funcs, rva)
        b = boundaries(md, data, base, f, rva) if f is not None else None
        for k in range(1, MAX_BACK + 1):
            if not b or k > len(b):
                break
            start = b[-k]
            sig = signature(md, data, base, start, rva)
            if sig:
                return rva - start, sig
        return None, None

    for key, rva in targets:
        # a return address: the call before it is part of the place (5 bytes, call rel32)
        place = rva
        off, sig = one(place)
        if sig is None:
            print("NO SIGNATURE  %-12s %#x" % (key, rva))
            failed += 1
            continue
        lines.append("%s %d %s" % (key, off, text_of(sig)))
        print("ok  %-12s %#9x  +%-3d %d bytes" % (key, rva, off, len(sig)))
    for rva, ln, dst, regbase in sites:
        rule = rules.get(rva, 4)
        off, sig = one(rva)
        if sig is None:
            print("NO SIGNATURE  site20c      %#x" % rva)
            failed += 1
            continue
        lines.append("site20c %d %d %d %d %d %s" % (rule, dst, regbase, ln, off, text_of(sig)))
        print("ok  site20c      %#9x  +%-3d %d bytes" % (rva, off, len(sig)))
    out = out or os.path.join(ROOT, "native", "mpfever_sigs.txt")
    # (0.9.2) the places of later builds found by hand (from "# (0.9.2) build 40444" on) are kept: this executable has none of them
    if os.path.exists(out):
        kept = open(out, encoding="utf-8").read().split("\n")
        at = next((i for i, l in enumerate(kept) if l.startswith("# (0.9.2) build 40444")), None)
        if at is not None:
            lines += [l for l in kept[at:] if l.strip()]
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("%s: %d signatures, %d places without one" % (out, len(lines) - 4, failed))
    return 1 if failed else 0


def parse_sig(text):
    return [None if t == "??" else int(t, 16) for t in text.split()]


def check(exe, sigs=None):
    pe, base, data, funcs = load(exe)
    sigs = sigs or os.path.join(ROOT, "native", "mpfever_sigs.txt")
    found = missing = 0
    for line in open(sigs, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        key = parts[0]
        if key == "site20c":
            off, sig = int(parts[5]), parse_sig(" ".join(parts[6:]))
        else:
            off, sig = int(parts[1]), parse_sig(" ".join(parts[2:]))
        hits = [m.start() for m in regex_of(sig).finditer(data)][:3]
        if len(hits) == 1:
            found += 1
            print("found    %-12s %#x" % (key, base + hits[0] + off))
        else:
            missing += 1
            print("%-8s %-12s (%s)" % ("MISSING" if not hits else "AMBIGUOUS", key, "none" if not hits else "%d matches" % len(hits)))
    print("build stamp %08x: %d place(s) found, %d not" % (pe.FILE_HEADER.TimeDateStamp, found, missing))
    return 1 if missing else 0


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("make", "check"):
        print(__doc__)
        sys.exit(2)
    if sys.argv[1] == "make":
        # (make <exe> [targets file] [output]: another list, for tests)
        sys.exit(make(sys.argv[2], targets_path=sys.argv[3] if len(sys.argv) > 3 else None, out=sys.argv[4] if len(sys.argv) > 4 else None))
    sys.exit(check(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
