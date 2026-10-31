# Writes the version resource of the native module (winhttp.dll) as a compiled .res file, which link.exe takes as it is:
# the module builds with the C++ tools alone, without the Windows SDK and its rc.exe. The fields are those Windows shows in
# the file's Properties > Details, and those code signing checks (product name and version, the same for every signed file
# of a release). Usage: mkres.py out.res VERSION   (VERSION as in build.bat, e.g. 0.5.10; a suffix such as -test is kept in
# the texts and left out of the numbers)
import re
import struct
import sys


def utf16z(s):
    return (s + "\0").encode("utf-16-le")


def pad4(b):
    return b + b"\0" * (-len(b) % 4)


def node(key, value=b"", value_len=0, text=False, children=()):
    """One VS_VERSIONINFO-style block: wLength, wValueLength, wType, szKey, padding, Value, padding, children."""
    body = pad4(struct.pack("<HHH", 0, value_len, 1 if text else 0) + utf16z(key)) + value
    for c in children:
        body = pad4(body) + c
    return struct.pack("<H", len(body)) + body[2:]


def string(key, text):
    return node(key, utf16z(text), len(text) + 1, text=True)


def version_res(version):
    nums = [int(x) for x in re.match(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", version).groups(default="0")] + [0]
    ms, ls = (nums[0] << 16) | nums[1], (nums[2] << 16) | nums[3]
    fixed = struct.pack("<13I", 0xFEEF04BD, 0x00010000, ms, ls, ms, ls, 0x3F, 0, 0x00040004, 2, 0, 0, 0)  # VOS_NT_WINDOWS32, VFT_DLL
    texts = [
        ("CompanyName", "dkdknight"),
        ("FileDescription", "MPFever native module (multiplayer for Transport Fever 3)"),
        ("FileVersion", version),
        ("InternalName", "winhttp"),
        ("LegalCopyright", "Copyright (C) 2026 dkdknight and the MPFever contributors. GPL-3.0-or-later"),
        ("OriginalFilename", "winhttp.dll"),
        ("ProductName", "MPFever"),
        ("ProductVersion", version),
    ]
    table = node("040904b0", text=True, children=[string(k, v) for k, v in texts])   # US English, Unicode
    info = node("VS_VERSION_INFO", fixed, len(fixed), children=[
        node("StringFileInfo", text=True, children=[table]),
        node("VarFileInfo", text=True, children=[node("Translation", struct.pack("<HH", 0x0409, 0x04B0), 4)]),
    ])
    # a .res file: an empty first entry, then the RT_VERSION entry (type 16, name 1, US English, moveable and pure)
    empty = struct.pack("<II", 0, 32) + struct.pack("<HHHH", 0xFFFF, 0, 0xFFFF, 0) + struct.pack("<IHHII", 0, 0, 0, 0, 0)
    header = struct.pack("<II", len(info), 32) + struct.pack("<HHHH", 0xFFFF, 16, 0xFFFF, 1) + struct.pack("<IHHII", 0, 0x30, 0x0409, 0, 0)
    return empty + header + pad4(info)


if __name__ == "__main__":
    out, version = sys.argv[1], sys.argv[2]
    with open(out, "wb") as f:
        f.write(version_res(version))
