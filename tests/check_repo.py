"""Checks of the repository that need neither the game nor a build: what a release must never ship.

  - one version everywhere: build.bat (the archives' names), the launcher (MainForm.Version, what the lobby compares), the
    first entry of docs/CHANGELOG.txt, and any version written in the mod's description (modinfo.json);
  - every Lua file of the mod compiles under Lua 5.2 (the game's), not only those of content/ (test_locals.py);
  - every JSON file of the repository parses (lang.json, mod.json, _content.json, modinfo.json);
  - every Python file of the repository compiles;
  - no merge conflict marker left in a text file;
  - the texts of the code and the mod are valid UTF-8.

Needs lupa (pip install lupa). Run: python tests/check_repo.py (exit code 1 when anything is wrong)
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEXT = {".lua", ".cs", ".cpp", ".h", ".py", ".bat", ".json", ".txt", ".md", ".def", ".asm", ".csproj", ".gitignore"}
failed = False


def check(cond, what):
    global failed
    print(("  ok    " if cond else "  FAIL  ") + what)
    failed = failed or not cond


def tracked():
    # (the files of the next commit too: tracked, or new and not ignored)
    out = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT, capture_output=True, check=True).stdout.decode("utf-8")
    return [ROOT / p for p in out.split("\0") if p and (ROOT / p).is_file()]


def versions():
    found = {}
    m = re.search(r'^set "VERSION=([^"]+)"', (ROOT / "build.bat").read_text(encoding="utf-8"), re.M)
    found["build.bat"] = m and m.group(1)
    m = re.search(r'public const string Version = "([^"]+)"', (ROOT / "launcher" / "MainForm.cs").read_text(encoding="utf-8"))
    found["launcher/MainForm.cs"] = m and m.group(1)
    m = re.search(r"^(\d+\.\d+\.\d+\S*) - ", (ROOT / "docs" / "CHANGELOG.txt").read_text(encoding="utf-8"), re.M)
    found["docs/CHANGELOG.txt"] = m and m.group(1)
    # (0.7.9) the mod's own version, said by the game in its "hello" (issue #136: an old copy of the mod in the game's folder)
    m = re.search(r'^C\.MODVERSION = "([^"]+)"', (ROOT / "mod" / "mpfever_1" / "content" / "mpfever_common.lua").read_text(encoding="utf-8"), re.M)
    found["mpfever_common.lua C.MODVERSION"] = m and m.group(1)
    v = found["build.bat"]
    check(v is not None and all(found.values()) and len(set(found.values())) == 1,
          "one version everywhere: " + ", ".join(f"{k} {x}" for k, x in found.items()))
    info = (ROOT / "mod" / "mpfever_1" / "_metadata" / "modinfo.json").read_text(encoding="utf-8-sig")
    other = [x for x in re.findall(r"\d+\.\d+\.\d+[\w-]*", info) if x != v]
    check(not other, "the mod's description (modinfo.json) names no other version" + (f": {other}" if other else ""))


def lua_files(files):
    try:
        import lupa.lua52 as lua52
    except ImportError:
        check(False, "lupa is installed (pip install lupa)")
        return
    compile_err = lua52.LuaRuntime().eval("function(s, n) local f, e = load(s, n) return e end")
    lua = [f for f in files if f.suffix == ".lua"]
    bad = []
    for f in lua:
        err = compile_err(f.read_text(encoding="utf-8"), f.name)
        if err:
            bad.append(f"{f.relative_to(ROOT)}: {err}")
    check(lua and not bad, f"{len(lua)} Lua files compile under Lua 5.2" + "".join("\n          " + b for b in bad))


def json_files(files):
    bad = []
    js = [f for f in files if f.suffix == ".json"]
    for f in js:
        try:
            json.loads(f.read_text(encoding="utf-8-sig"))
        except ValueError as e:
            bad.append(f"{f.relative_to(ROOT)}: {e}")
    check(js and not bad, f"{len(js)} JSON files parse" + "".join("\n          " + b for b in bad))


def mod_content(files):
    # (0.6) the mod's content files and its list of them (mod/mpfever_1/_content.json) agree: a new file of content/ (a feature
    # module mpfever_feat_<id>.lua) must be listed there, as mpfever_ai.lua was in 0.5.12, and nothing listed may be missing
    cj = ROOT / "mod" / "mpfever_1" / "_content.json"
    listed = set(json.loads(cj.read_text(encoding="utf-8-sig")).get("files") or [])
    content = ROOT / "mod" / "mpfever_1" / "content"
    present = {f.name for f in files if f.parent == content}
    missing, extra = sorted(present - listed), sorted(listed - present)
    check(not missing and not extra, "the mod's _content.json lists its content files"
          + (f": not listed {missing}" if missing else "") + (f": listed, not there {extra}" if extra else ""))


def python_files(files):
    bad = []
    py = [f for f in files if f.suffix == ".py"]
    for f in py:
        try:
            compile(f.read_text(encoding="utf-8"), str(f), "exec")
        except SyntaxError as e:
            bad.append(f"{f.relative_to(ROOT)}: {e}")
    check(py and not bad, f"{len(py)} Python files compile" + "".join("\n          " + b for b in bad))


def text_files(files):
    undecodable, markers = [], []
    texts = [f for f in files if f.suffix in TEXT or f.name in TEXT]
    for f in texts:
        try:
            s = f.read_bytes().decode("utf-8")
        except UnicodeDecodeError:
            undecodable.append(str(f.relative_to(ROOT)))
            continue
        if re.search(r"^(<<<<<<< |=======\r?$|>>>>>>> )", s, re.M):
            markers.append(str(f.relative_to(ROOT)))
    check(not undecodable, f"{len(texts)} text files are UTF-8" + (f": not {undecodable}" if undecodable else ""))
    check(not markers, "no merge conflict marker" + (f": {markers}" if markers else ""))


def main():
    files = tracked()
    versions()
    lua_files(files)
    json_files(files)
    mod_content(files)
    python_files(files)
    text_files(files)
    print("all passed" if not failed else "FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
