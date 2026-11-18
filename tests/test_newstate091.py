"""Offline test: after a load, the simulation never reads this machine's company as the player (0.9.0, #425, MPFEVER_NEWSTATEDROP).

Report #425 (Flubi host, lulei client, separate companies): right after every load, lulei's native log shows
  10:50:21 local player 116899 from the control file / savegame company 64532 / local player 64532 -> 116899 (apply, state ...5e60)
  10:50:21 savegame company 64532 dropped: a new game state / local player 116899 dropped: a new game state ...5c40
  10:50:22 local player 116899 from the control file / savegame company 64532
The engine's second state of the game just loaded (...5c40, one of the two states of the load: "a game is being loaded (states
...5c40, ...5e60)") came to ApplyLocalPlayer as "a new game state", and both companies were dropped. The state ...5e60 still held
lulei's company in its word, and the simulation's readings of the player (PatchPlayerReads) give the savegame's company only while
it is known, else the word as it is: for about a second the game's scripts saw lulei's company as the player on lulei's game only.
The game's company growth script (company_growth.script.tl: ensureState(getPlayer())) made a record for lulei's company there
("progression.companyState.116899" in lulei's dump only), "script:progression" differed after every load and the launcher left it out
as a local measure ("Lokale Messwerte (ab jetzt ignoriert): script:progression"). At 10:53:33 the local player was even written before
the savegame's company was read from the same control file.
The fix keeps both companies when the new state is one of the two states of the game loaded last (g_loadGs, from ReplDetour's load
copy), and reads the savegame's company from the control file before this machine's.
Part 1 checks the native source; part 2 replays the logged sequence on a model of the readings, before and after.
Run: python tests/test_newstate091.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "native", "mpfever_native.cpp")
fails = []


def check(name, cond, got=""):
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f": {got}" if got != "" and not cond else ""))
    if not cond:
        fails.append(name)


def model(fixed):
    """The logged sequence of lulei's game at the load of 10:50, on a model of the native module: states A (...5e60) and B
    (...5c40), the words, the values, and what the simulation reads (the savegame's company when known, else the word)."""
    S = {"canon": 0, "local": 0, "words": {"A": 64532, "B": 64532}, "seen": set(), "loadGs": set()}
    sim_reads = []

    def sim_read(state):
        # PatchPlayerReads, the simulation thread: the canon when known, else the word as read
        sim_reads.append(S["canon"] if S["canon"] else S["words"][state])

    def load():
        # ReplDetour: the load's first copy (states A and B), DropAtLoad
        S["canon"] = 0; S["local"] = 0
        if fixed:
            S["loadGs"] = {"A", "B"}

    def control(local, canon):
        # the control file: "setlocal", then "setcanon" (the mod writes them in that order)
        if fixed:
            S["canon"] = canon; S["local"] = local
        else:
            S["local"] = local
            apply("A")                      # a command applied between the two lines (10:53:33)
            sim_read("A")
            S["canon"] = canon

    def apply(state):
        # ApplyLocalPlayer on the state applying a command
        if state not in S["seen"]:
            S["seen"].add(state)
            if not (fixed and state in S["loadGs"]) and len(S["seen"]) > 1:
                S["canon"] = 0
                if S["local"]:
                    S["local"] = 0
                    return
        if S["local"]:
            S["words"][state] = S["local"]

    load()
    S["seen"] = {"A"}                       # state A known from the iterations
    control(116899, 64532)
    apply("A")                              # local player 64532 -> 116899 (apply, state A)
    apply("B")                              # a new game state B: dropped (before the fix)
    for _ in range(5):                      # the simulation's scripts during the next second (dt 0 calls while held)
        sim_read("A")
    control(116899, 64532)                  # the mod says them again
    sim_read("A")
    return sim_reads


def main():
    src = open(SRC, encoding="utf-8").read().replace("\r\n", "\n")
    alp = src[src.index("static void ApplyLocalPlayer(const char* why)\n{"):]
    alp = alp[:alp.index("\n}\n")]
    check("ApplyLocalPlayer keeps both companies when the new state is one of the two states of the game loaded last",
          "bool second = !NewStateDrop() && !LoadKeepLocal() && g_slot && (g_slot == g_loadGs[0] || g_slot == g_loadGs[1])" in alp
          and alp.index("if (second)") < alp.index('DropCanon("a new game state");'))
    # (the review of 0.9.0: a load begun on another thread between the control file's check and its values leaves the game
    # before's values: kept only when both were taken since the last load)
    check("  only values taken from the control file since that load (the load count noted with each value)",
          "&& g_localLoads == g_ctlLoads && g_canonLoads == g_ctlLoads;" in alp
          and "g_canon = pk.canon; g_canonLoads = loads0;" in src and "g_localPlayer = pk.local; g_localLoads = loads0;" in src)
    br = open(os.path.join(HERE, "..", "mod", "mpfever_1", "content", "mpfever_bridge.script.lua"), encoding="utf-8").read().replace("\r\n", "\n")
    i_c = br.find('if canonFirst and reg.canon then nativeCtl("setcanon "')
    i_l = br.find('nativeCtl("setlocal " .. c.ent .. " " .. tok)')
    check("the mod writes the savegame's company to the control file before this machine's (each line its own write)",
          0 < i_c < i_l and 'local canonFirst = os.getenv("MPFEVER_NEWSTATEDROP") ~= "1"' in br
          and 'if not canonFirst and reg.canon then nativeCtl("setcanon "' in br)
    rd = src[src.index('extern "C" u64 ReplDetour(void* src, void* dst, u64 flag)'):]
    rd = rd[:rd.index("u64 r = g_replOrig(src, dst, flag);")]
    check("ReplDetour notes the two states at the load's first copy (with DropAtLoad)",
          "g_loadGs[0] = src; g_loadGs[1] = dst;" in rd and rd.index("g_loadGs[0] = src;") < rd.index("DropAtLoad();"))
    ctl = src[src.index("bool canonFirst = !NewStateDrop();") - 2000:src.index("if (!canonFirst) takeCanon();") + 40]
    check("the control file: the savegame's company taken before this machine's (MPFEVER_NEWSTATEDROP=1: as before)",
          "if (canonFirst) takeCanon();" in ctl and ctl.index("if (canonFirst) takeCanon();") < ctl.index("if (pk.haveLocal && pk.localTok != g_localTok) {")
          and 'GetEnvironmentVariableA("MPFEVER_NEWSTATEDROP"' in src)

    before = model(False)
    after = model(True)
    check("before (the bug): the simulation read lulei's company (116899) as the player after the load", 116899 in before, before)
    check("after: the simulation reads the savegame's company (64532) only", set(after) == {64532}, after)

    print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
