"""Offline test (0.8.16): the Linux relay's published file is trimmed and compressed.

The relay of 0.8.15 was 68 MB: a self-contained single file carries the whole .NET runtime. Published single-file, the project
now trims the runtime to what the relay uses and compresses it (about 13 MB on Linux, 11 MB on Windows; the trimmed file passes
the relay's 120 self-test checks, run by the CI and the Release workflow on the Linux file). Trim warnings are errors in this
project (TreatWarningsAsErrors), so a use the trimmer can't see fails the build instead of the server.
  - MPFeverRelay.csproj: PublishTrimmed (unless set) and EnableCompressionInSingleFile when PublishSingleFile is true;
  - warnings stay errors; the workflows still run --selftest on the published Linux file.
Run: python tests/test_relaytrim0816.py
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
proj = open(os.path.join(HERE, "..", "server-linux", "MPFeverRelay.csproj"), encoding="utf-8").read()
rel = open(os.path.join(HERE, "..", ".github", "workflows", "release.yml"), encoding="utf-8").read()
fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check("<PropertyGroup Condition=\"'$(PublishSingleFile)' == 'true'\">" in proj, "only for the published single file")
check("<PublishTrimmed Condition=\"'$(PublishTrimmed)' == ''\">true</PublishTrimmed>" in proj, "  the runtime trimmed (-p:PublishTrimmed=false: whole, as before)")
check("<EnableCompressionInSingleFile>true</EnableCompressionInSingleFile>" in proj, "  and compressed")
check("<TreatWarningsAsErrors>true</TreatWarningsAsErrors>" in proj, "trim warnings stay errors")
check("artifacts/linux/mpfever-relay --selftest" in rel, "the Release workflow tests the published Linux file")

print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
