"""Offline test (0.8.17, #405): when a build shipped at the click comes out otherwise on its builder's game, only a game that built
its copy reports the difference (G.preshipSettle, G.prePost in mpfever_bridge.script.lua, switch MPFEVER_PREVERIFY).

Flubi's station edit (2026-11-16 21:02, host): built otherwise than its copy (the copy was stale, see test_preparestale0817.py);
the builder reported it ("its capture shipped, resynchronisation") and every game was reloaded, while lulei's game had not built the
copy yet, got the capture first and built it ("its capture came before its time here: built from the capture"): alike.
G.preshipSettle, G.preVerifyOn and G.prePost are taken from the real bridge and run through lupa:
  - MPFEVER_PREVERIFY=0: the builder reports it, lulei's game (the capture) says nothing: a reload for nothing (the bug);
  - now: the builder reports nothing; a game that built the capture says nothing (no reload);
  - a game that built the copy reports it when the capture differs in form, or lands at another step (a build released a
    batch late, see test_relhold0817.py), even when nothing had changed since the click;
  - a game that built the copy, the capture alike: nothing (not built again).
Needs lupa. Run: python tests/test_preverify0817.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


m1 = re.search(r"^G\.preshipSettle = function\(a, o\)\n.*?^end\n", src, re.S | re.M)
m2 = re.search(r"^G\.preVerifyOn = function.*?\n", src, re.M)
m3 = re.search(r"^G\.prePost = function\(p\)\n.*?^end\n", src, re.S | re.M)
check("the functions found", all((m1, m2, m3)))
if not all((m1, m2, m3)):
    sys.exit(1)


def runtime(off=False):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
LOGS, SENT = {}, {}
function log(s) LOGS[#LOGS + 1] = s end
function send(kind, p) SENT[#SENT + 1] = kind end
G = { me = "Flubi", preUsed = {}, preHeld = {}, preVerdict = {} }
G.groundProbe = function() end
G.preStreetSig = function(m) return m and m.sig or nil end
G.preDrop = function(uid) return DROP == uid end
''' + m2.group(0) + m1.group(0) + m3.group(0))
    if off:
        L.execute("ENV.MPFEVER_PREVERIFY = '0'")
    return L, L.eval("function(code) return assert(load(code))() end")


def builder(off):
    L, run = runtime(off)
    run("""E = { pre = 'Flubi:60', preSig = 'copy2', preAt = 4509000, preClean = true, id = 60 }
A = { preOf = E }
DONE = G.preshipSettle(A, { at = 4509000, args = { { sig = 'built1' } } })""")
    return run("return #SENT"), run("return A.post")


def other(off, used, capture):
    L, run = runtime(off)
    if used:
        run("G.preUsed['Flubi:60'] = { sig = 'copy2', t = 0, at = 4509000 }")
    else:
        run("DROP = 'Flubi:60'")
    run("R = G.prePost(%s)" % capture)
    return run("return #SENT"), run("return R")


CAP = "{ post = 'Flubi:60', preClean = true, at = 4509000, args = { { sig = 'built1' } } }"
n, post = builder(True)
n2, _ = other(True, False, CAP)
check("MPFEVER_PREVERIFY=0: the builder reports it, lulei's game (the capture) says nothing: a reload for nothing (the bug)", n == 1 and post == "Flubi:60" and n2 == 0, (n, n2))
n, post = builder(False)
check("now: the builder ships its capture and reports nothing", n == 0 and post == "Flubi:60", n)
n2, r = other(False, False, CAP)
check("now: lulei's game builds the capture (it came before its time there) and reports nothing", n2 == 0 and r is False, (n2, r))
n3, r = other(False, True, CAP)
check("a game that built the copy (2 street pieces) gets the capture (1): it reports it", n3 == 1 and r is True, (n3, r))
n4, r = other(True, True, CAP)
check("  (with MPFEVER_PREVERIFY=0 it said nothing, the builder did)", n4 == 0, n4)
n5, r = other(False, True, "{ post = 'Flubi:60', preClean = true, at = 4509400, args = { { sig = 'copy2' } } }")
check("a game that built the copy, the capture alike but landed 2 steps later on its builder's game: it reports it", n5 == 1, n5)
n6, r = other(False, True, "{ post = 'Flubi:60', preClean = true, at = 4509000, args = { { sig = 'copy2' } } }")
check("a game that built the copy, the capture alike at the same step: nothing, not built again", n6 == 0 and r is True, (n6, r))

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
