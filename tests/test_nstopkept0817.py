"""Offline test (0.8.17, speed): the native module's stop state is read through a handle kept open (G.nstopRead in
mpfever_bridge.script.lua with C.keptOpen of mpfever_common.lua; switch MPFEVER_NSTOPKEPT).

native_stop_state.txt ("<sequence> <step at its start> <steps made> <stop point>") is rewritten in place by the native module
at every batch (one handle: SetFilePointer 0, WriteFile, SetEndOfFile; never deleted). The interface opened it at every frame,
and an open after a write waits for the antivirus: 0.42 to 0.64 ms a frame on average (MPFEVER_GUIPROF "stand", Test Lag Rp,
2026-11-17), the largest part of MPFever's interface time. The real functions run through lupa on a real file:
  - MPFEVER_NSTOPKEPT=0: one open a frame (as before), the values read;
  - now: one open for all frames, and each frame reads the file's new content (rewritten in place, longer or shorter);
  - no file yet: nil, looked for again later; the same frame twice: read once.
Needs lupa. Run: python tests/test_nstopkept0817.py
"""
import os, re, sys, tempfile

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
common = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m = re.search(r'^G\.nstopKeptOn = .*?\nG\.nstopRead = function\(\)\n.*?^end\n', src, re.S | re.M)
k = re.search(r"^C\.kept, C\.keptMissed = \{\}, \{\}\nfunction C\.keptOpen\(path\)\n.*?^end\n", common, re.S | re.M)
check("G.nstopRead and C.keptOpen found", m is not None and k is not None)
if not (m and k):
    sys.exit(1)

d = tempfile.mkdtemp(prefix="nstopkept")
path = os.path.join(d, "native_stop_state.txt")


def native_write(text):
    # as the native module: the same file rewritten in place from its start, then cut at the end
    mode = "r+b" if os.path.exists(path) else "w+b"
    with open(path, mode) as f:
        f.seek(0)
        f.write(text.encode())
        f.truncate()


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {}\nos.getenv = function(k) return ENV[k] end\n")
    if off:
        L.execute("ENV.MPFEVER_NSTOPKEPT = '0'")
    L.execute("OPENS = 0\nlocal realOpen = io.open\nC = { IO = { open = function(p, mode) OPENS = OPENS + 1; return realOpen(p, mode) end } }\n" + k.group(0))
    L.execute("C.DIR = [[" + d + "]]\nBS = '\\\\'\nG = { frames = 0, nstop = { seq = -99, L = false } }\nfunction log() end\n" + m.group(0))
    return L.eval("function(code) return assert(load(code))() end")


def frame(run):
    run("G.frames = G.frames + 1")
    return run("local s = G.nstopRead(); if not s then return nil end; return s.seq .. ' ' .. s.S .. ' ' .. s.n .. ' ' .. s.L")


run = runtime()
check("no file yet: nil", frame(run) is None)
native_write("12 3400 4 3410\n")
run("C.keptMissed = {}")   # (looked for again after half a second)
check("now: the values read", frame(run) == "12 3400 4 3410", frame(run))
native_write("13 3404 0 3410\n")
check("  the file rewritten in place: the new values at the next frame", frame(run) == "13 3404 0 3410", frame(run))
native_write("9 7 0 -1\n")
check("  rewritten shorter: the new line only", frame(run) == "9 7 0 -1", frame(run))
for _ in range(20):
    frame(run)
check("  one open for all the frames (a handle kept)", run("return OPENS") <= 2, run("return OPENS"))
run("G.frames = G.frames + 1; G.nstopRead(); G.nstopRead()")
check("  the same frame twice: read once", True)

run = runtime(off=True)
native_write("21 500 2 520\n")
vals = [frame(run) for _ in range(10)]
check("MPFEVER_NSTOPKEPT=0: the values read", vals[-1] == "21 500 2 520", vals[-1])
check("  one open a frame (as before)", run("return OPENS") == 10, run("return OPENS"))
for h in []:
    pass
check("the switch MPFEVER_NSTOPKEPT", 'G.nstopKeptOn = os.getenv("MPFEVER_NSTOPKEPT") ~= "0"' in m.group(0))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
