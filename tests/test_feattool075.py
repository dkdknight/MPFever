"""The game options' copy of a tool's build is taken in time (0.7.5, G.featTool in mpfever_bridge.script.lua).

A game option's allow of a build made with a tool (fn "nativeBuild", when the native module reports it held, "deferred") gets
the build the tool applies (G.featTakeTool, a copy at most 5 frames old). The copy was taken at builder.proposalApply, which the
game sends AFTER the engine applied the build (seen in game 2026-11-07 night: proposalCreate, proposalPrepareForApply, the
command held by the DLL, ..., proposalApply): too late, G.featTakeTool gave nothing. It is now taken at
builder.proposalPrepareForApply, before the command; MPFEVER_FEATTOOLAPPLY=1: at proposalApply, as before (never both).
Run: python tests/test_feattool075.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


i = src.find("local function guiHandleEvent(userParams, state, guiState, src, id, name, param)")
ev = src[i:src.find("\nend\n", i)]
check(i > 0, "guiHandleEvent found")
prep = ev.find('elseif name == "builder.proposalPrepareForApply" then')
apply_ = ev.find('elseif name == "builder.proposalApply" then')
check(0 < prep < apply_, "the two events found")
newcall = 'if G.featOn and G.featAllow and os.getenv("MPFEVER_FEATTOOLAPPLY") ~= "1" then pcall(G.featTool, param) end'
oldcall = 'if G.featOn and G.featAllow and os.getenv("MPFEVER_FEATTOOLAPPLY") == "1" then pcall(G.featTool, param) end'
check(prep < ev.find(newcall) < apply_, "the copy taken at proposalPrepareForApply")
check(ev.find(oldcall) > apply_, "MPFEVER_FEATTOOLAPPLY=1: at proposalApply, as before")
check(ev.count("pcall(G.featTool, param)") == 2, "never both (one switch, opposite conditions)")
t = src.find("G.featTakeTool = function()")
check("G.frames - t.frame <= 5" in src[t:t + 300], "the copy is used when at most 5 frames old")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
