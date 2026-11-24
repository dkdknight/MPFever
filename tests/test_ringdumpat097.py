"""Offline test (0.9.7, #150 research): MPFEVER_RINGDUMPAT=<check>[,<check>...] asks the native module for its rings at those checks
without any drift (mpfever_bridge.script.lua, extendedParts), so that two games in sync can be compared over the same steps.

The question of #454 (chris's game applied many more loop commands than Wretched's before the animals split): is that normal in a
synced session? Answered with this switch on Test Leawood (2 games, soak 600 s x4, checks 6/12/18/24): the entities stayed
identical while the loop commands differed (script events 28/32 up to 48/65, a few steps apart): it is normal.
  - the request is the same file the drift diagnostic writes (native_drift.txt: the check's number), polled by the native module;
  - only the checks listed, only with the variable (nothing by default), never for a check that is not a number.
Run: python tests/test_ringdumpat097.py
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


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def main():
    src = open(BRIDGE, encoding="utf-8").read().replace("\r\n", "\n")
    m = re.search(r"\n(\t\t-- \(0\.9\.7, #150 research; tests: MPFEVER_RINGDUMPAT.*?\n\t\tend\n)", src, re.S)
    check(m is not None, "the MPFEVER_RINGDUMPAT block found")
    if not m:
        return 1
    blk = m.group(1)
    i = src.find("local function extendedParts(parts, checkN)")
    j = src.find("pcall(SDUMP.keepDrift, SDUMP.driftN, dump)")
    check(0 < i < j < src.find(blk), "  in extendedParts, after the drift's own request (checkN in scope)")
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(r"""
ENV = {}
os = { getenv = function(k) return ENV[k] end }
C = { DIR = "D", IO = {} }
BS = "/"
NL = "\n"
WRITTEN = {}
LOGS = {}
function log(t) LOGS[#LOGS + 1] = t end
C.IO.open = function(path, mode) local f = { path = path }; function f:write(s, nl) WRITTEN[#WRITTEN + 1] = self.path .. "=" .. s end; function f:close() end; return f end
function run(checkN, env)
  ENV = env or {}
  WRITTEN = {}
""" + blk + r"""
  return table.concat(WRITTEN, ";")
end
""")
    run = L.eval("run")
    lua_table = L.eval("function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end")

    def env(**kw):
        return lua_table(L.table_from(kw))

    check(run(12, None) == "", "no variable: nothing asked (as before)")
    check(run(12, env(MPFEVER_RINGDUMPAT="6,12,18")) == "D/native_drift.txt=12", "a listed check: native_drift.txt gets its number")
    check(run(1, env(MPFEVER_RINGDUMPAT="12")) == "" and run(2, env(MPFEVER_RINGDUMPAT="12")) == "", "another check (1, 2 for 12): nothing")
    check(run(6, env(MPFEVER_RINGDUMPAT="6")) == "D/native_drift.txt=6", "a single check")
    check(run(None, env(MPFEVER_RINGDUMPAT="6")) == "", "no check number: nothing")
    nat = open(os.path.join(HERE, "..", "native", "mpfever_native.cpp"), encoding="utf-8").read()
    check('PathOf(path, "native_drift.txt");' in nat and "if (v <= 0 || v == g_driftLast) return;" in nat, "the native module polls that file and dumps once per number")
    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
