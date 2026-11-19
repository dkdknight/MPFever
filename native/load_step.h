// (0.9.1, #426) The update the engine makes as it loads a game makes no step: the loop's first batch makes it, on every game.
//
// As a game is loaded, the engine copies it into a fresh state (ReplDetour sees that copy, "a game is being loaded") and runs one
// update of it right away, outside the simulation loop: on the loading thread, or on the new simulation thread before the loop's
// first iteration (PreIterDetour). That update asks the steps function for its number of steps like every batch (StepsForBatch):
// the speed of the savegame, unless a stop point holds the game there. Whether it held depended on what was left from before:
//  - a game whose mod had written a stop point less than 10 s before (StopAlive) stood at the loaded step (0 steps);
//  - a game loaded after more than 10 s in the main menu (its stop point left alone) or the first game of the process (no stop
//    file yet) made its steps in that update, on a thread that is not the simulation's.
// The steps made there miss everything the module does for the simulation's thread: a vehicle or a line a game script makes in
// that step keeps the free-id queue's id instead of a fresh one (see "fresh ids"). Report #426 (2026-11-18, three players, the
// host back from the main menu): the host's and chris's games made step 63239 at their load and their game script's new entity
// took the queue's id 115753; dujuk's game, held by the stop point of its session before, made that step in the loop and gave it
// the fresh id 324810. From then on every vehicle and line made by a command had another id on dujuk's game (324811 for the
// others' 324810), and its game drifted from the first step of the session ("resync" after two minutes).
// Now that update makes no step on any game, whatever was left from before: every game makes its first steps after a load in the
// loop, on the simulation's thread, with the same rules. MPFEVER_LOADSTEP=1: as before (that update makes the steps it is given).
#pragma once

struct LoadStep {
    int pending;                       // a game was loaded and the loop has not made an iteration of it yet
    unsigned long long loads, held;    // games loaded; updates at a load that would have made steps
};

// a game is being loaded (its first copy into a fresh state)
static void LoadStepSeen(LoadStep* s)
{
    s->pending = 1;
    s->loads++;
}

// the simulation loop's iteration (its pre-iteration): from here on the batches are the loop's
static void LoadStepIter(LoadStep* s)
{
    s->pending = 0;
}

// the steps the batch makes: none for the update at a load (on: the fix; off: MPFEVER_LOADSTEP=1, as before)
static unsigned LoadStepSteps(LoadStep* s, unsigned sp, int on)
{
    if (!on || !s->pending) return sp;
    if (sp > 0) s->held++;
    return 0;
}
