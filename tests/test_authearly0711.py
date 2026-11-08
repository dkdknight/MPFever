"""Offline test of #147's fixes (0.7.11): the host's money corrections (mod/mpfever_1/content/mpfever_bridge.script.lua).

A. Domenik's game (2026-11-08, separate companies, a few steps behind the host all session) was never corrected: at every
   checkpoint the host's values ("auth") reached its simulation before it took that checkpoint itself, found no own values
   with that number, and were dropped without a word (company 2 stayed 9000 apart for half an hour). Now:
   - the host's values with no own checkpoint yet are kept (st.authEarly, 8 at most) and applied when this game takes that
     checkpoint ("came before this game took it: applied now"); the same for the paused checkpoints taken in the GUI half
     (G.authEarly);
   - a checkpoint is corrected once only (st.authDone), whichever came first;
   - MPFEVER_AUTHEARLY=0: dropped, as before.
B. The flip-flop (keviK 2026-11-07: -252676 at a checkpoint, +252676 at the next): a refund booked by the simulation (no
   answer callback, applied with the next step's commands) was counted two steps; a checkpoint one step later counted it on top
   of the balance that had it already. Counted during its own update only now (MPFEVER_REFUNDSTEP=0: two steps, as before).
Run: python tests/test_authearly0711.py
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
src = open(os.path.join(ROOT, "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


ev = src[src.index('		elseif name == "auth" then'):]
ev = ev[:ev.index("\t\tstate:set(st)")]
check('if not matched and type(param.n) == "number" and os.getenv("MPFEVER_AUTHEARLY") ~= "0" then' in ev
      and "st.authEarly[#st.authEarly + 1] = param" in ev and "while #st.authEarly > 8 do" in ev,
      "A: the host's values before this game's checkpoint kept (8 at most); MPFEVER_AUTHEARLY=0: dropped as before")
check("if not (st.authDone and st.authDone[param.n]) then" in ev and "st.authDone[param.n] = true" in ev,
      "  a checkpoint corrected once only")
ck = src[src.index("					st.authOwn[#st.authOwn + 1] = { n = a.n, auth = okA and auth or nil }"):][:1500]
check("if e.n == a.n and not (st.authDone and st.authDone[a.n]) then" in ck and "correctMoney(auth, e, a.n, api.cmd.sendCommand, st.co)" in ck,
      "  applied when this game takes that checkpoint, with its own values of that checkpoint")
check("elseif e.n > a.n then keepE[#keepE + 1] = e end" in ck, "  older ones dropped (a checkpoint this game will not take)")
check("if k < a.n - 20 then st.authDone[k] = nil end" in ck, "  the corrected ones remembered for the last 20 only")
ha = src[src.index("H.auth = function(from, p)"):]
ha = ha[:ha.index("\nend\n")]
check('if type(p.ptd) == "number" and from ~= "early" and os.getenv("MPFEVER_AUTHEARLY") ~= "0" then' in ha and "G.authEarly[p.n] = p" in ha
      and ha.index("G.authEarly[p.n] = p") < ha.index('toSim("auth", p)'), "  a paused checkpoint's values kept in the GUI half too (and still passed on)")
pc = src[src.index("				G.authOwn[a.n] = okA and auth or nil"):][:600]
check('if e and okA then pcall(H.auth, "early", e) end' in pc, "  applied when this game takes that paused checkpoint")
rb = src[src.index("function REFUND.book(st, now)"):]
rb = rb[:rb.index("\nend\n")]
check('if p.quiet and os.getenv("MPFEVER_REFUNDSTEP") ~= "0" then p.till = now end' in rb
      and rb.index("p.quiet = true end") < rb.index("p.till = now end"), "B: the simulation's refund booking counted during its own update only")
check("if p.till >= now then live[#live + 1] = p" in rb, "  dropped at the next update (its step is past)")
check("local p = { key = REFUND.key(st.co, rc.co), amount = d, till = now + 2 * STEP }" in rb, "  a booking with an answer callback: two steps, as before")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
