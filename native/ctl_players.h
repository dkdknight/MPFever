// The player lines of the native module's control file (native_ctl.txt), kept apart so that tests/test_ctlstale0713.py builds
// them (0.7.13, #171).
//
// "setlocal <entity> <token>" (this machine's company), "setothers <token> <entity>..." (the other companies') and
// "setcanon <token> <entity>" (the savegame's): the bridge's interface half says them again every few seconds with a new
// token, the last line of each kind in the part of the file read wins, and ReadControl takes it when its token is not the one
// taken last. The module reads the file only when a command is added: a game that added none after its last lines (a client
// cut from its host applied one command every 15 s, then went back to the main menu) left them unread, and the next game
// loaded in the same run of the game took them right after the drop at its load (DropAtLoad): its interface read the player
// of this machine's company of the game before, an entity the new world does not have, and the engine closed the game
// ("entity is not known" from UI::CSelector, MrWhiskey1 joining again, 2026-11-08 15:40:34).
// A line whose '\n' lies before oldEnd (the file's size when the game now running began to load; 0: no load yet) is now the
// game before's: counted, never taken. takeOld (MPFEVER_CTLSTALE=1): taken, as before.
// Freestanding, as the module (no C runtime): no memcmp.
#pragma once

struct CtlPlayers {
    long local, localTok; bool haveLocal, localOld;   // the last "setlocal" taken (localOld: written before the load, takeOld)
    long others[32]; int nOthers; long othersTok; bool haveOthers;
    long canon, canonTok; bool haveCanon;
    int nOld; long oldLocal, oldLocalTok;             // the player lines of the game before, and the last "setlocal" of them
};

static inline void CtlPickInit(CtlPlayers* p)
{
    p->local = 0; p->localTok = 0; p->haveLocal = false; p->localOld = false;
    p->nOthers = 0; p->othersTok = 0; p->haveOthers = false;
    p->canon = 0; p->canonTok = 0; p->haveCanon = false;
    p->nOld = 0; p->oldLocal = 0; p->oldLocalTok = 0;
}

// where ReadControl reads the file from (its last cap bytes), and the mark it goes by: none when the file is shorter than the
// mark (written anew: nothing in it is the game before's)
static inline unsigned CtlWindow(unsigned size, unsigned cap, unsigned* oldEnd)
{
    if (*oldEnd > size) *oldEnd = 0;
    return size > cap ? size - cap : 0;
}

// a line whose '\n' is at j in the part read (the file's offset bufOff + j; j = the part's length when the line has none yet)
static inline bool CtlLineOld(unsigned bufOff, unsigned j, unsigned oldEnd) { return oldEnd != 0 && bufOff + j < oldEnd; }

static inline bool CtlIs(const char* l, int len, const char* p, int n)
{
    if (len < n + 1) return false;
    for (int i = 0; i < n; i++) if (l[i] != p[i]) return false;
    return true;
}

// one line of the file (len characters, without its '\n'): true when it is a player line, taken or counted as the game
// before's. The three readings are ReadControl's of 0.7.12, unchanged.
static inline bool CtlPickLine(const char* l, int len, bool old, bool takeOld, CtlPlayers* p)
{
    if (CtlIs(l, len, "setlocal ", 9)) {
        // "setlocal <entity> <token>": the last such line wins
        int k = 9;
        long v = 0, tok = 0;
        for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) v = v * 10 + (l[k] - '0');
        for (k++; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
        if (old) { p->nOld++; p->oldLocal = v; p->oldLocalTok = tok; }
        if (!old || takeOld) { p->local = v; p->localTok = tok; p->haveLocal = true; p->localOld = old; }
        return true;
    }
    if (CtlIs(l, len, "setothers ", 10)) {
        // "setothers <token> <entity>...": the last such line wins
        int k = 10;
        long tok = 0, tmp[32];
        int n = 0;
        for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
        while (k < len && n < 32) {
            while (k < len && (l[k] < '0' || l[k] > '9')) k++;
            long e = 0; bool any = false;
            for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) { e = e * 10 + (l[k] - '0'); any = true; }
            if (any) tmp[n++] = e;
        }
        if (old) p->nOld++;
        if (!old || takeOld) { for (int q = 0; q < n; q++) p->others[q] = tmp[q]; p->nOthers = n; p->othersTok = tok; p->haveOthers = true; }
        return true;
    }
    if (CtlIs(l, len, "setcanon ", 9)) {
        // "setcanon <token> <entity>": the last such line wins
        int k = 9;
        long tok = 0, e = 0;
        for (; k < len && l[k] >= '0' && l[k] <= '9'; k++) tok = tok * 10 + (l[k] - '0');
        for (k++; k < len && l[k] >= '0' && l[k] <= '9'; k++) e = e * 10 + (l[k] - '0');
        if (old) p->nOld++;
        if (!old || takeOld) { p->canon = e; p->canonTok = tok; p->haveCanon = true; }
        return true;
    }
    return false;
}

// the player lines of the part of the file read (got bytes from the file's offset bufOff), cut into lines as ReadControl does
static inline void CtlPickPlayers(const char* buf, unsigned got, unsigned bufOff, unsigned oldEnd, bool takeOld, CtlPlayers* p)
{
    CtlPickInit(p);
    for (unsigned i = 0; i < got; ) {
        unsigned j = i;
        while (j < got && buf[j] != '\n') j++;
        CtlPickLine(buf + i, (int)(j - i), CtlLineOld(bufOff, j, oldEnd), takeOld, p);
        i = j + 1;
    }
}
