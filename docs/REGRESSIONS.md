# MPFever: regressions and behaviours that must stay

Read this before changing MPFever. Every fix must keep the behaviours below, and every regression found gets an entry here,
with its cause and the test that now guards it.

## Behaviours that must stay

| Behaviour | Since | Where | Test |
|---|---|---|---|
| **Join review**: a player joining a game already running sees its mods and DLCs on the Multiplayer page and presses « Join the game » before the game loads, **every time** (0.7.10, the user's choice; before: only when something differed). A player who accepted already, back after a cut to the same game, is not asked again. | 0.7.0 / 0.7.10 | MainForm.JoinReviewClear, welcome "review" | test_joinreview.py, test_reviewdlc0710.py |
| **Lobby** of a player's own game: the players wait in the lobby with the savegame's mods and DLCs until the host starts. | 0.4 | MainForm lobby, mpfever_menu.lua | test_lobbylayout.py, test_lobbyrules.py |
| A **personal mod** (taken for personal on the Multiplayer page) is not compared with the host's. | 0.4.6 | Mods, modpersonal | test_modlocal077.py |
| The **savegame played is never written** by MPFever: session saves have names of their own. | 0.5 | resync_save, HostAutosave | test_gameautosave077.py |
| **Reports** keep taking out the personal data (Windows and PC names, Steam numbers, public IPs, e-mails). | 0.3 | Reporter.Redact | test_reportshare079.py |
| **Auto Signals and other mods' script signals and stops** are built on every game. | 0.7.8 | C.scriptEdgeObjects | test_scripteo077.py |
| A **mod is known by its own id** (the top level's "modId" of its mod.json), never by a dependency's it names first (#159). | 0.7.12 | Mods.TopModId, Mods.Scan | test_modidtop0712.py, selftest |
| A **mod's custom entity** (L-Signalsystem's previews...) that exists on a game is still moved, changed and taken away there; only one that is not there, or is a node, a segment, a construction... there, is skipped, replayed or sent by the mod's own script (#156, #158). | 0.7.11 | executeActionOnce, DET.installModCmds, C.notCustomEntity | test_customguard0711.py |
| A **player's actions apply in the order that player made them**, also across a pause: a paused action first applies that player's earlier actions still waiting for their step, in its own turn and at its time, on every game (#168); a paused action whose player has nothing waiting goes in the same frame as before (MPFEVER_PTPULL=0: as in 0.7.12). | 0.7.13 | G.pullHold, SIM.ptPull, runPausedActions | test_ptpull0713.py |
| A **game loaded in the same run of the game** (a join from the main menu, a resynchronisation, "toshared") never plays a company of the game before: the native module forgets this machine's, the savegame's and the other companies' at the load, and leaves out the control file's player lines written before it (#171). | 0.7.5 / 0.7.13 | DropAtLoad, ReadControl / native/ctl_players.h, pollCompanies | test_cofile075.py, test_ctlstale0713.py |
| A **purchase the company cannot pay** is refused on every game alike (the engine's own rule, as in single player): no resync, no id taken. mod.log and the report say why ("not enough money: price P, company money B") and the buyer is told on the chat notice. A purchase made keeps its "result after N step(s): entity E" line byte for byte (idcmp.py). MPFEVER_BUYMONEY=0: as in 0.7.12 (#148/#170). | 0.7.13 | executeActionOnce, C.buyWhy/C.buyNote, U.buyRefusedText | test_buymoney0713.py |
| **Two players' builds at the same step** are both shipped and applied in rank order: a player's held build is never released while another player's replay is in the engine's hands (between the dry run and the build of a stop or signal, the frames after its answer, the stops placed again after a street), so it is never taken for that replay (#161, #166). | 0.7.13 | runNativeRelease, G.ownWaitsReplay, G.sameStepWait | test_ownafterreplay0713.py |
| The checks' **diagnostic parts** (buildIds, personsDigest) are only logged ("(diagnostic) ..."): never a reason to reload, never "a local measure" after a reload, never a whole dump, and a game that does not measure one gets no native-module advice. | 0.4 / 0.7.13 | MainForm.DiagnosticParts, NeverLocalParts, OnSyncHash | test_persondigest0713.py, selftest RunPersonDigest0713 |
| The **persons and land vehicles in one piece** stay OFF unless MPFEVER_PERSONSERIAL=1 / MPFEVER_VEHSERIAL=1 is set on every game (they change the engine's random draws: one game with and one without drift apart); the animals' one-piece patch is unchanged. | 0.7.13 | native InstallPersonSerial, InstallOrderFixes | test_personserial0713.py |
| A **resynchronisation reloads every game, the host's too**, in this order: pause, every game stopped, the host's session save, the host's own reload before any send, whole games, then differences, then the next base kept. A player's base is never read while a whole game is written over it. Every 0.7.13 speed-up keeps this order (RESYNCGC, DELTAPREREAD, DELTAEARLY). | 0.5 / 0.7.13 | MainForm.ResyncLocked, SendDeltas, OnDeltaFile | test_resyncspeed0713.py, test_waitjoiners.py |
| **Every game of a session simulates and replays alike**: no player's own setting changes how a game replays the others' builds or simulates, and the host's session settings are the same on every game. The experimental « Other players' builds without waiting », « Several players building without stopping » (host) and « Same platform order (test) » (player) are gone; MPFEVER_NOWAIT / MPFEVER_NOSTOP / MPFEVER_ORDER2 exist only in the environment of every game, for tests. | 0.7.13 | Options.All, G.featureOn, InstallOrderFixes | test_expopts0713.py, test_order2_0710.py, selftest |
| A **player's construction tool** leads (BUILDLEAD). The vehicle and line windows lead only with MPFEVER_ACTLEAD=1 or MPFEVER_NOSTOP=1, research switches off by default since 0.7.13 (the line window also with MPFEVER_LINELEAD=1): never make them lead by default by mistake. A computer company never leads. | 0.7.4 / 0.7.10 / 0.7.13 | G.lineLeadStamp, G.actLeadWindow, G.featureOn | test_ailead079.py, test_linelead.py, test_expopts0713.py |
| The launcher keeps « ⚙ Settings », Ko-fi and Discord reachable (left card and bottom bar); a player hosts and joins only from the game's Multiplayer page / Steam / server list; --dev keeps Host / Join / Local test | 0.7.13 | MainForm.ConnCard, BuildLinksCard | test_launcherlinks0713.py, selftest |

## Regressions found

| Found | Broken in | What broke | Cause | Fixed in | Test |
|---|---|---|---|---|---|
| 2026-11-08 (the user) | 0.7.8 | The join review no longer opened for most players. | DLCSESSION dropped the "different DLCs" warning, and the review opened on that warning only. | 0.7.10 | test_reviewdlc0710.py |
| 2026-11-08 (#133) | 0.7.6 | A track upgrade replayed in its rebuilt form was shipped again by every game: several resyncs. | The #131 fix (node configs given again) changed what the replay builds, and the capture compared it with the shipped build. | 0.7.7 | test_rebuiltsig077.py |
| 2026-11-08 | 0.7.1 | The signals and stops mods put up by script (Auto Signals...) were refused on every game. | A script names an edge object's segment by edgeEntity, not as a tool does. | 0.7.8 | test_scripteo077.py |

## Before every release

- `python tests/run_all.py` (build.bat runs it): every test passes.
- Check the table above against the changes of the release: does any of them touch one of these behaviours? Then test it in
  game (an autotest, or the real tools).
- A behaviour changed on purpose: say so in the CHANGELOG and update this file.
