"""Offline test (0.8.17): the launcher's verdicts and docs/MODS.md name the mods made to work in 0.8.17 (launcher/Mods.cs Known,
launcher/lang.json, docs/MODS.md).
  - Ultimate Light Rail (mrnickert_ultimate_metro, #400), Town Transit Planner (miib_city_bus_lines, #394): "fixed", with their notes;
  - Auto Signals (auto_signals_1, #399): its note says 0.8.17;
  - every note translated (lang.json);
  - docs/MODS.md: a "Made compatible in 0.8.17" section with the four mods (Narrow One-Way Tram Track, #403, included).
Run: python tests/test_modverdicts0817.py
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def check(name, cond):
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails.append(name)


m = open(os.path.join(HERE, "..", "launcher", "Mods.cs"), encoding="utf-8-sig").read()
lang = json.load(open(os.path.join(HERE, "..", "launcher", "lang.json"), encoding="utf-8"))["texts"]
notes = {
    "mrnickert_ultimate_metro": "Its stations built with a tram street are replayed as the game's own stations (0.8.17, #400).",
    "miib_city_bus_lines": "In a pause, its street pieces replaced one after the other are all built (0.8.17, #394).",
    "auto_signals_1": "Its added signals are built on every game (0.7.8); a signal kept by a new track piece no longer crashes the other games (0.8.17, #399).",
}
for mod, note in notes.items():
    check(f"{mod}: a fixed verdict with its note", f'["{mod}"] = () => new Verdict {{ Level = "fixed"' in m and note in m)
    check(f"  translated in every language ({len(lang.get(note, {}))})", len(lang.get(note, {})) >= 11)
d = open(os.path.join(HERE, "..", "docs", "MODS.md"), encoding="utf-8").read()
sec = d[d.index("### Made compatible in 0.8.17"):d.index("### Made compatible in 0.7.0")]
for name, issue in (("Ultimate Light Rail", "#400"), ("Narrow One-Way Tram Track", "#403"), ("Auto Signals", "#399"), ("Town Transit Planner", "#394")):
    check(f"MODS.md 0.8.17: {name} ({issue})", f"| {name} |" in sec and issue in sec)

print("all ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
