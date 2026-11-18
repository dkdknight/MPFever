// (0.8.18, #150) The same batches on every game: where a batch of the simulation ends, and which of the engine's two world states
// makes it.
//
// The engine keeps two world states and makes each batch of steps on the other one (CGame::Sync flips them every 200 ms, at each
// batch, steps or none), after copying the state it made the batch before into it (Replicate: the change records replayed, then
// the components copied). Not everything is copied: the systems' entity lists (fam_order.h), the aircraft's cache (AIRCACHE),
// the accounts' list (CLEARSAME), and "previous" values taken at the start of each batch. So a step's result can depend on how
// the steps are cut into batches and on which state makes them. The games cut them differently: a game held behind a slower
// player's clock stands at its stop point (batches of no step, as many as it waits), another runs on. Most of the time that
// changes nothing; now and then it does, and the games part (#150, the "slight simulation drift" about once an hour between two
// PCs, never between two games of one PC that stand at the same steps).
//
// AlignBatch, called for every batch with the batch's first step S, the steps the speed gives (sp: 4 at 4x, 0 paused) and the
// steps the stop point leaves (n, 0 to sp), gives the steps this batch makes:
//  - a batch never runs past a multiple of the speed (it ends at 4, 8, 12... at 4x): after a batch cut by a stop point, the next
//    one comes back to the multiples. The stop points every game shares (another player's build, the session's pause) end the
//    batches at the same steps on every game; the mod rounds the others (the barrier of the other players' clocks, its own holds)
//    down to a multiple of the speed (G.alignDown in mpfever_bridge.script.lua);
//  - a run of batches with no step (paused, standing at a stop point) is always made of an EVEN number of batches: when the stop
//    point moves after an odd number, this game stands one batch more (200 ms). Every batch flips the two states, so the batches
//    with steps are made by the same state on every game, whatever each game waited.
// With both, every game makes the same batches, each on the same of its two states: what is not copied between the states follows
// the same history on every game.
#pragma once

struct BatchAlign {
    unsigned stillRun;      // batches with no step since the last batch with steps
    unsigned long long batches, stills, parityAdds, blockCuts;
};

// (parity: the rule of the even runs of still batches; 0 leaves the runs as they are, the batches' ends are still aligned)
static unsigned AlignBatch(BatchAlign* a, unsigned S, unsigned sp, unsigned n, int parity)
{
    a->batches++;
    if (n > sp) n = sp;
    if (n > 0 && sp > 1) {
        unsigned r = sp - S % sp;
        if (n > r) { n = r; a->blockCuts++; }
    }
    if (n == 0) { a->stillRun++; a->stills++; return 0; }
    if (parity && (a->stillRun & 1u)) { a->stillRun++; a->stills++; a->parityAdds++; return 0; }
    a->stillRun = 0;
    return n;
}
