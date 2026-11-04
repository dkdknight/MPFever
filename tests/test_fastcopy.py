"""Offline test of C.copy (mpfever_common.lua, 0.6.12): the same value as C.deser(C.ser(v)), without the text in between.

A big station's edit is a 2.3 MB action, which the replays copied several times through the text while the games stood
(0.17 s each, 0.04 s now). C.copy must give exactly what the text gave: what C.ser cannot write left out (functions, tables
deeper than 40), NaN and infinities as 0, every number exact, array and hash keys kept. Every copy of the bridge goes through it;
MPFEVER_FASTCOPY=0 goes through the text, as before.
Run: python tests/test_fastcopy.py
"""
import os, re, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
COMMON = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_common.lua")
BRIDGE = os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def runtime(env):
    src = open(COMMON, encoding="utf-8").read()
    m = re.search(r"^local function escapeChar\(c\).*?^C\.SLOWCOPY = .*?\n", src, re.S | re.M)
    if not m:
        return None
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("ENV = {} os.getenv = function(k) return ENV[k] end C = {} NL = string.char(10) CR = string.char(13) QUOTE = string.char(34) BS = string.char(92)")
    for k, v in env.items():
        L.execute(f'ENV.{k} = "{v}"')
    L.execute(m.group(0))
    return L.eval("function(code) return assert(load(code))() end")


CASES = r"""
local deep = {} local d = deep for i = 1, 45 do d.x = {} d = d.x end
local v = { 1, 2.5, -0.000123456789012345, 1e300, 2^53 + 2, "a\n\"b\\", true, false,
  nested = { [1] = { x = 1, y = { 3, 4 } }, [10] = "ten", [-3] = -3, ["7"] = "seven" },
  nan = 0/0, inf = math.huge, minf = -math.huge, f = function() end, deep = deep,
  vec = { x = 2953.085693359375, y = -2972.025634765625, z = 2.3676822185516357, __vec = true } }
return v
"""


# deep equality (the order of pairs may differ between two tables of the same content)
EQ = r"""
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, x in pairs(a) do if not same(x, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
"""


def main():
    src = open(BRIDGE, encoding="utf-8").read()
    check("the bridge copies through C.copy only", "C.deser(C.ser(" not in src and src.count("C.copy(") >= 20)
    for env, label in (({}, "C.copy"), ({"MPFEVER_FASTCOPY": "0"}, "MPFEVER_FASTCOPY=0")):
        run = runtime(env)
        check(label + ": found", run is not None)
        if run is None:
            return 1
        got = run(EQ + "local v = (function() " + CASES + " end)(); return same(C.copy(v), C.deser(C.ser(v)))")
        check(label + ": the same as through the text (numbers, keys, NaN, functions, depth)", got is True, got)
        got = run("local v = (function() " + CASES + " end)(); local c = C.copy(v); return tostring(c.nan) .. ' ' .. tostring(c.f) .. ' ' .. tostring(c.vec.x) .. ' ' .. #c .. ' ' .. tostring(c.nested[10])")
        check(label + ": NaN 0, no function, exact numbers, the array kept", got == "0 nil 2953.0856933594 8 ten", got)
        got = run("local v = { a = { 1 } }; local c = C.copy(v); c.a[1] = 9; return v.a[1]")
        check(label + ": a copy, not the same tables", got == 1, got)
    print("FAILED: " + ", ".join(fails) if fails else "all passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
