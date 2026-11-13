"""Offline test: the computer companies' log lines go to mod.log only, without the game's debugPrint (0.8.7; C.fileLogger in
mod/mpfever_1/content/mpfever_common.lua, G.aiEnv in mpfever_bridge.script.lua, switch MPFEVER_AILOGPRINT).

Measured in game (test n13pf of 2026-11-13, MPFEVER_AIPROF and MPFEVER_LOGPROF): the game's debugPrint took 200 to 260 ms for
each line of the computer companies (about 20 a minute), 0.05 ms for the bridge's own lines in the same session; the host's
game held 0.4 to 1.7 s at once by a company's look. The mod.log write itself takes 0.2 ms.
  - C.fileLogger writes the line with its time to its file, as C.logger does, and never calls debugPrint;
  - nothing while MPFever is not active (C.ACTIVE), as C.logger;
  - the AI's env gets it as its log; MPFEVER_AILOGPRINT=1: the bridge's log (debugPrint too), as before.
Needs lupa (pip install lupa). Run: python tests/test_ailog087.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "mod", "mpfever_1", "content")
fails = []


def check(cond, name, got=""):
    print(("ok   " if cond else "FAIL ") + name + (f" ({got})" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


common = open(os.path.join(CONTENT, "mpfever_common.lua"), encoding="utf-8").read().replace("\r\n", "\n")
bridge = open(os.path.join(CONTENT, "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")

a = common.index("function C.fileLogger(fileName)")
b = common.index("\nend\n", a) + 5
fn = common[a:b]
check("debugPrint" not in fn, "C.fileLogger never calls the game's debugPrint")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute('''
C = { ACTIVE = true, DIR = "D" }
BS, NL = "\\\\", "\\n"
WROTE = {}
PRINTED = 0
debugPrint = function() PRINTED = PRINTED + 1 end
C.appendFile = function(path, text) WROTE[#WROTE + 1] = path .. "|" .. text; return true end
os.date = function() return "12:34:56" end
''' + fn + '''
local lg = C.fileLogger("mod.log")
lg("AI1 company 4: money 1")
C.ACTIVE = false
lg("not written")
''')
check(L.eval("#WROTE") == 1 and L.eval("WROTE[1]") == "D\\mod.log|12:34:56 AI1 company 4: money 1\n",
      "the line with its time, in its file (as C.logger writes it)", L.eval("WROTE[1]"))
check(L.eval("PRINTED") == 0, "  no debugPrint")
check(L.eval("#WROTE") == 1, "  nothing while MPFever is not active")

e = bridge.index("G.aiEnv = function()")
env = bridge[e:bridge.index("\nend\n", e)]
check('G.aiFileLog = G.aiFileLog or C.fileLogger("mod.log")' in env, "the AI's env: a file logger of mod.log")
check('local aiLog = os.getenv("MPFEVER_AILOGPRINT") == "1" and log or G.aiFileLog' in env, "  MPFEVER_AILOGPRINT=1: the bridge's log, as before")
check("log = aiLog," in env and "log = log," not in env, "  given to the AI as its log")

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
