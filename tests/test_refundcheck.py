"""Offline test: refund differences not booked yet count in the money checks (0.6.12, the user's session of 2026-11-03 20:37).

The replays of a pause are booked at the first step after it (REFUND.book books a record once its time is past). The paused
checkpoints compared the money without them: the host corrected the replaying game by the difference, and the booking after
the pause added it again (-336 456 on the client, exactly its eight differences). They now count as booked (REFUND.heldOf), as
REFUND.pending already did for a booking not applied yet; up to 256 records are kept (8 before: a long pause dropped some).
MPFEVER_REFUNDCHECK=0: as before.

Run: python tests/test_refundcheck.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


MOCK = r'''
ENV = {}
os.getenv = function(k) return ENV[k] end
BS = "\\"
C = { IO = { open = function() return nil end }, DIR = "x" }
log = function() end
STEP = 200
ACC = {}   -- player entity -> { balance, loan }
api = { type = { ComponentType = { ACCOUNT = "acc" } },
  engine = { getComponent = function(e, ct) return ACC[e] end, util = { getPlayer = function() return 1 end } } }
'''


def chunk(src):
    a = re.search(r"^local REFUND = .*?^function REFUND\.heldOf\(key\).*?\n", src, re.S | re.M)
    b = re.search(r"^local function authValues\(reg\)\n.*?^end\n", src, re.S | re.M)
    return (a.group(0) if a else None), (b.group(0) if b else None)


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    a, b = chunk(src)
    check("REFUND and authValues found", a is not None and b is not None)
    if not (a and b):
        return 1
    check("the money check counts them too", 'acc.balance + REFUND.heldOf("b" .. c.id)) .. "/" .. acc.loan' in src and '(acc.balance + REFUND.heldOf("balance")) .. "/" .. acc.loan' in src)
    check("the simulation's checkpoint and the interface read their copy of st.rcost", "REFUND.list = st.rcost\n\t\t\t\t\tlocal okA, auth = pcall(authValues, st.co)" in src and "G.co = st.co\n\tREFUND.list = st.rcost" in src)
    check("256 records kept", "while #st.rcost > (REFUND.CHECKED and 256 or 8) do" in src)

    def run_case(env_off):
        L = lupa.LuaRuntime(unpack_returned_tuples=True)
        L.execute(MOCK)
        if env_off:
            L.execute('ENV.MPFEVER_REFUNDCHECK = "0"')
        # (made global here: the bridge keeps them local)
        L.execute(a.replace("local REFUND = ", "REFUND = ", 1) + b.replace("local function authValues", "function authValues", 1) + "\nAUTH = authValues")
        return L, L.eval("function(code) return assert(load(code))() end")

    L, run = run_case(False)
    # shared company: the host built a station for 96 420 in a pause, the client's replay cost 96 000; both started at 1 000 000
    got = run("""
      REFUND.list = { { at = 100, uid = "Knight-HD:312", cost = 96420, got = 96000, n = 1 } }
      ACC[1] = { balance = 1000000 - 96000, loan = 0 }
      local client = AUTH(nil).balance
      local host = 1000000 - 96420
      return client .. " " .. host""")
    check("#20:37: the replaying game's paused value is the builder's (no correction, no double booking)", got == "903580 903580", got)
    got = run("""
      REFUND.list = { { cost = 100, got = 50, n = 1, co = 2 }, { cost = 10, got = 30, n = 1, co = 3 }, { cost = 10, got = 99, n = 0, co = 2 } }
      return REFUND.unbooked("b2") .. " " .. REFUND.unbooked("b3") .. " " .. REFUND.unbooked("balance")""")
    check("one company per player: each company's own records; one not applied yet does not count", got == "-50 20 -30", got)
    got = run("""
      REFUND.pending = { { key = "b2", amount = -7, till = 1e9 } }
      return tostring(REFUND.heldOf("b2"))""")
    check("a booking not applied yet counts as before, added to the records not booked", got == "-57", got)
    got = run("""
      REFUND.pending = {}
      REFUND.list = { { cost = 100, got = 50, n = 1, co = 2 } }
      ACC[20] = { balance = 1000, loan = 5 }
      local t = AUTH({ mode = "separate", list = { { id = 2, ent = 20 } } })
      return t.b2 .. " " .. t.l2""")
    check("one company per player: the host's corrections compare the same values", got == "950 5", got)
    got = run("""REFUND.list = nil; return tostring(REFUND.unbooked("balance"))""")
    check("no record: nothing", got == "0", got)
    got = run("""REFUND.free = "urbangames_no_costs_1"; REFUND.list = { { cost = 100, got = 50, n = 1 } }; return tostring(REFUND.unbooked("balance"))""")
    check("a mod that makes building free: nothing (nothing is booked either)", got == "0", got)

    L, run = run_case(True)
    got = run("""REFUND.list = { { cost = 96420, got = 96000, n = 1 } }; return tostring(REFUND.unbooked("balance"))""")
    check("MPFEVER_REFUNDCHECK=0: not counted, as before", got == "0", got)

    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
