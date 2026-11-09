"""Test of the files' details (0.7.14, the user's request of 2026-11-09: version information in our files, against antivirus
blocks; launcher/MPFever.csproj, serverlist/MPFeverServerList.csproj, tools/mkres.py, build.bat, launcher/SelfTest.cs).

winhttp.dll carried its details since 0.6 (tools/mkres.py: publisher dkdknight, product MPFever, description, copyright, file
names); MPFever.exe and MPFeverServerList.exe only their version, with "MPFever" as publisher and no copyright. They now carry the
same publisher, product and copyright as the DLL, a description of their own and the release's version (build.bat). The
selftest (MPFever.exe --selftest, SelfTest.RunVersionInfo0714) reads them from the built files.
Run: python tests/test_versioninfo0714.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(*p):
    return open(os.path.join(ROOT, *p), encoding="utf-8-sig").read().replace("\r\n", "\n")


fails = []


def check(cond, name):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


mk = read("tools", "mkres.py")
company = re.search(r'\("CompanyName", "([^"]+)"\)', mk).group(1)
copyright_ = re.search(r'\("LegalCopyright", "([^"]+)"\)', mk).group(1)
product = re.search(r'\("ProductName", "([^"]+)"\)', mk).group(1)
check(company == "dkdknight" and product == "MPFever" and "GPL-3.0-or-later" in copyright_, "winhttp.dll's details (tools/mkres.py) as before")
for path, desc in ((("launcher", "MPFever.csproj"), "MPFever launcher (multiplayer for Transport Fever 3)"),
                   (("serverlist", "MPFeverServerList.csproj"), "MPFever server list (the public games of MPFever)")):
    pj = read(*path)
    name = path[1]
    check("<Company>%s</Company>" % company in pj and "<Product>%s</Product>" % product in pj
          and "<Copyright>%s</Copyright>" % copyright_ in pj, "%s: the DLL's publisher, product and copyright" % name)
    check("<AssemblyTitle>%s</AssemblyTitle>" % desc in pj and "<Description>%s</Description>" % desc in pj, "%s: its description" % name)
bb = read("build.bat")
check('set "VERSHPROPS' not in bb and '-p:Version=%VERSION%' in bb and bb.count("%VERPROPS%") >= 2,
      "build.bat: the release's version on both programs (and winhttp.dll through mkres.py)")
st = read("launcher", "SelfTest.cs")
check("ok &= RunVersionInfo0714();" in st and "static bool RunVersionInfo0714()" in st
      and 'exe.CompanyName == "dkdknight"' in st and "FileVersionInfo.GetVersionInfo(dll)" in st,
      "the selftest reads the details of the built MPFever.exe and of winhttp.dll next to it")
print(f"\n{len(fails)} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
