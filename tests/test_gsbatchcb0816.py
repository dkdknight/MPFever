"""Offline test (0.8.16, #369): a game script's commands waiting for their answer go in a batch too, and each gets its answer.

Henrik and Julian's session (#369, 0.8.13): at the load, the mod Industry Brands (industry_brands) sent thousands of commands
(custom entities destroyed and made again, renames), each with a callback. The batch of 0.8.11 (#331) left out every command
waiting for an answer, so 13137 of them went as actions one by one: the host's simulation stood still for minutes, its game
time never moved and the host's resynchronisation failed ("the games did not stop").
  - G.gsBatchable: a command waiting for its answer is batchable; MPFEVER_GSBATCHCB=0: not, as in 0.8.11;
  - executeBatch: the batch's result lists each command's id and whether it was applied (itemIds, itemOk), in order;
  - G.reportResult: a batch's result answers each of its commands through G.gsAnswer (with its own success); any other
    result as before.
Needs lupa. Run: python tests/test_gsbatchcb0816.py
"""
import os, sys

try:
    import lupa.lua52 as lupa
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def body(head):
    i = src.find(head)
    return src[i:src.find("\nend\n", i) + 5] if i >= 0 else ""


gb = body("G.gsBatchable = function(p)")
xb = body("local function executeBatch(a, sendCommand, bind)")
rb = body("function G.reportResult(r)")
check(gb and xb and rb, "G.gsBatchable, executeBatch and G.reportResult found")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("""
ENV = {}
os.getenv = function(k) return ENV[k] end
G = {}
LOG = {}
function log(t) LOG[#LOG + 1] = t end
package.loaded.mpfever_gs_hook = { pending = { [7] = true } }
ANSWERS = {}
SENT = {}
function send(k, p) SENT[#SENT + 1] = k end
function gameTime() return 7388000 end
function replayFailed() end
-- the commands of a batch: those whose id is even are refused here
function executeActionOnce(sub) return { success = (sub.id % 2 == 1) } end
""")
L.execute(gb)
L.execute(xb.replace("local function executeBatch", "function executeBatch"))
L.execute(rb)
L.execute("G.gsAnswer = function(r) ANSWERS[#ANSWERS + 1] = tostring(r.tok) .. ':' .. tostring(r.id) .. ':' .. tostring(r.success) end")
run = L.eval("function(code) return assert(load(code))() end")

check(run('return G.gsBatchable({ tok = "gsmod-1-h", id = 7, fn = "makeCustomEntityDestroyCmd" })') is True,
      "a command waiting for its answer is batchable")
run('ENV.MPFEVER_GSBATCHCB = "0"')
check(run('return G.gsBatchable({ tok = "gsmod-1-h", id = 7, fn = "makeCustomEntityDestroyCmd" })') is False,
      "MPFEVER_GSBATCHCB=0: not, as in 0.8.11")
check(run('return G.gsBatchable({ tok = "gsmod-1-h", id = 8, fn = "makeCustomEntityDestroyCmd" })') is True,
      "  one without a callback still is")
run("ENV.MPFEVER_GSBATCHCB = nil")

run('''
R = executeBatch({ tok = "gsmod-1-h", id = 3, uid = "Henrik:9", fn = "mpfBatch", args = { { { fn = "makeEntitySetNameCmd", id = 3, args = {} },
  { fn = "makeEntitySetNameCmd", id = 4, args = {} }, { fn = "makeCustomEntityDestroyCmd", id = 5, args = {} } } } }, nil, {})
''')
check(run("return table.concat(R.itemIds, ',')") == "3,4,5", "the batch's result lists its commands' ids in order")
check(run("return tostring(R.itemOk[1]) .. tostring(R.itemOk[2]) .. tostring(R.itemOk[3])") == "truefalsetrue", "  and whether each was applied")
run("G.reportResult(R)")
check(run("return table.concat(ANSWERS, ' ')") == "gsmod-1-h:3:true gsmod-1-h:4:false gsmod-1-h:5:true",
      "G.reportResult answers each command of a batch, with its own success")
run("ANSWERS = {}")
run('G.reportResult({ tok = "gsmod-1-h", id = 12, fn = "makeEntitySetNameCmd", success = true })')
check(run("return table.concat(ANSWERS, ' ')") == "gsmod-1-h:12:true", "any other result: answered as before")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
