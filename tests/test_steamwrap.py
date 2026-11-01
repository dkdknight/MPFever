"""Static check of the Steam tunnel's elapsed times (0.6.7, the join by Steam of 2026-11-01 00:49:30).

mpf_steamnet.cpp reads `now` once at the top of a loop pass; a tunnel whose state changes later in the pass (Connected's
SetState, from Steam's callbacks) gets a later Now(), and `now - t->stateAt` wrapped round as a u64: the host's dial-back
failed at once ("did not answer in 5 s") and the player could not join by Steam. Every elapsed time of a tunnel goes through
Since(now, at) now, which is never negative. This test fails if a raw subtraction of a tunnel's time comes back.
Run: python tests/test_steamwrap.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "native", "mpf_steamnet.cpp"), encoding="utf-8").read()
code = "\n".join(l.split("//")[0] for l in src.splitlines())
fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

check("Since() is defined and never negative", re.search(r"static u64 Since\(u64 now, u64 at\) \{ return now > at \? now - at : 0; \}", code) is not None)
raw = re.findall(r"now\s*-\s*t(?:->|\.)(?:stateAt|lastProgress|aimdLogAt)", code)
check("no raw `now - t->stateAt` / lastProgress / aimdLogAt left (%d found)" % len(raw), not raw)
check("the dial-back timeout uses Since", "Since(now, t->stateAt) > 5000" in code)
check("the closed tunnels are freed with Since", "Since(now, t.stateAt) > 30000" in code)
print("FAILED: " + ", ".join(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
