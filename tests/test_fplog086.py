"""Offline test: the native module says the floating-point control of the simulation's thread (0.8.6, #150; DriftStep in
native/mpfever_native.cpp, _mm_getcsr in native/win.h).

#274 drifted between an AMD and an Intel PC on the same Windows build, and the game's code has no rsqrt/rcp instruction (whole exe
scanned): a driver or a library that changes the SSE control (rounding, flush-to-zero, denormals-are-zero) on one PC would make that
game compute otherwise. native.log now says the simulation's thread's MXCSR at the first step and whenever it changes:
  - read in DriftStep (the simulation's thread, before every step), its flag bits 0-5 left out;
  - said once per value, with the step;
  - MPFEVER_FPLOG=0: not said;
  - _mm_getcsr declared for the freestanding build (no SDK, no C runtime).
Run: python tests/test_fplog086.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
N = os.path.join(HERE, "..", "native")
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


src = open(os.path.join(N, "mpfever_native.cpp"), encoding="utf-8").read().replace("\r\n", "\n")
win = open(os.path.join(N, "win.h"), encoding="utf-8").read()
d = src[src.index("static void DriftStep(void* engine)"):]
d = d[:d.index("\n}\n")]
check("read in DriftStep, before the step's ring entry", 0 < d.find("_mm_getcsr()") < d.find("long i = g_dStepN++ & (DIAG_STEPS - 1);"))
check("  its flag bits left out", "u32 c = _mm_getcsr() & 0xFFC0u;" in d)
check("  said once per value, with the step", "if (c != lastCsr)" in d and 'b.str("floating-point control of the simulation\'s thread: MXCSR ").hex(c).str(" at step ").dec((i64)step); LogLine(b);' in d)
check("  switch MPFEVER_FPLOG=0", 'GetEnvironmentVariableA("MPFEVER_FPLOG", e, 3) == 1 && e[0] == \'0\'' in d)
check("_mm_getcsr declared for the freestanding build", 'extern "C" unsigned int _mm_getcsr(void);' in win)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
