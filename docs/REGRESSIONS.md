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
| A **player's tool** (vehicle window, line window, construction tool) leads; a computer company never does. | 0.7.4 / 0.7.10 | G.lineLeadStamp | test_ailead079.py |
| **Auto Signals and other mods' script signals and stops** are built on every game. | 0.7.8 | C.scriptEdgeObjects | test_scripteo077.py |

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
