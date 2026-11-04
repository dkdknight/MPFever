// The game states a list of the native module remembers (0.6.12), kept apart so that tests/test_stateseen.py builds it.
//
// Two lists keep game states: the states this machine's player was written into (NoteWritten) and the states seen applying
// commands (ApplyLocalPlayer: a state never seen is a game just loaded, whose entity ids mean nothing yet). Each holds 16. Once
// full, a state not in it always took the first place: after about eight games loaded in one game process (two states each:
// the session's start and every resynchronisation), the two states the engine runs its batches on by turns took that place in
// turn. Each was then "a new game state" at every batch, and this machine's player and the savegame's company were forgotten at
// every batch: the mod says them again every 400 frames, so the line routes on the map showed for an instant every few seconds
// and stayed hidden otherwise (Discord, 2026-11-03, after a resynchronisation), and the tools built for the savegame's company
// in between. A state not in a full list now takes the place of the one put there longest ago.
// MPFEVER_SEENFIRST=1: the first place, as before.
#pragma once

static const int SEEN_MAX = 16;

// The place of a state that is not in a list: n is the list's length (it grows up to SEEN_MAX), next the place the next state
// takes once the list is full (the oldest one, in turn).
static inline int SeenPlace(int* n, int* next, bool firstPlace)
{
    if (*n < SEEN_MAX) return (*n)++;
    if (firstPlace) return 0;
    int i = *next % SEEN_MAX;
    *next = (i + 1) % SEEN_MAX;
    return i;
}
