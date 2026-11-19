#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Read-only check of pinned RVAs against an independently obtained Valve DLL.

No Valve binaries are distributed with Dock. This check uses PE/RTTI metadata,
not execution, and needs only Python's standard library. It does not establish
call signatures; retain the disassembly review in docs/CLIENT_LAYOUTS.md.
"""
from pathlib import Path
import hashlib, re, struct, sys

raw = Path(sys.argv[1]).read_bytes()
fingerprint = hashlib.sha256(raw).hexdigest()
source = (Path(__file__).resolve().parents[1] / 'src/client_layout.c').read_text()
block = re.search(r'"' + fingerprint + r'",\s*(\d+),([^}]+)', source)
assert block, 'Unknown SHA-256; never infer a layout from similar metadata'
rvas = [int(x, 16) for x in re.findall(r'0x[0-9a-f]+', block[2])]
assert len(rvas) == 18
pe = struct.unpack_from('<I', raw, 0x3c)[0]
assert raw[pe:pe+4] == b'PE\0\0' and struct.unpack_from('<H', raw, pe+4)[0] == 0x8664
sections = struct.unpack_from('<H', raw, pe+6)[0]
optional_size = struct.unpack_from('<H', raw, pe+20)[0]
opt = pe+24
assert struct.unpack_from('<H', raw, opt)[0] == 0x20b
base = struct.unpack_from('<Q', raw, opt+24)[0]
image_size, headers = struct.unpack_from('<II', raw, opt+56)
assert image_size < 128*1024*1024
image = bytearray(image_size); image[:headers] = raw[:headers]
for i in range(sections):
    h = opt+optional_size+i*40
    va, size, offset = struct.unpack_from('<III', raw, h+12)
    assert va+size <= image_size and offset+size <= len(raw)
    image[va:va+size] = raw[offset:offset+size]

def vtable(name):
    pattern = b'.?AV'+name.encode()+b'@@\0'
    td = image.index(pattern)-16
    candidates=[]
    for ref in re.finditer(re.escape(struct.pack('<I', td)), image):
        col=ref.start()-12
        if col < 0: continue
        signature, offset, _, _, _, self_rva = struct.unpack_from('<6I', image, col)
        if signature != 1 or offset != 0 or self_rva != col: continue
        for v in re.finditer(re.escape(struct.pack('<Q', base+col)), image):
            candidates.append(v.start()+8)
    assert len(candidates) == 1, (name, candidates)
    return candidates[0]

groups = [('CSteamClient',[8,33,43],rvas[:3]),
          ('IClientUserMap',[1,4,6,49,50,56,67,181,182],rvas[3:12]),
          ('IClientAppManagerMap',[2,5],rvas[12:14]),
          ('IClientUserMap',[71],rvas[14:15]),
          ('IClientUserMap',[5,214,215],rvas[15:18])]
for name,slots,expected in groups:
    table = vtable(name)
    for slot,rva in zip(slots,expected):
        actual=struct.unpack_from('<Q', image, table+8*slot)[0]-base
        assert actual==rva,(name,slot,hex(actual),hex(rva))
    print(f'PASS: {name}, {len(slots)} pinned methods')
print('PASS:',fingerprint,'adapter',block[1])

# ml1990: the called IPC wrapper must name its own method through a
# RIP-relative LEA and serialize the method's IPC function ID. This binds the
# pinned slot to RequestCustomBinaries, not merely to a table position.
def names_method(rva, name, function_id, limit=0x200):
    code, found_name = image[rva:rva+limit], False
    for i in range(len(code)-7):
        if code[i] in (0x48, 0x4c) and code[i+1] == 0x8d and code[i+2] & 0xc7 == 0x05:
            target = rva+i+7+struct.unpack_from('<i', code, i+3)[0]
            if image[target:target+len(name)+1] == name.encode()+b'\0': found_name = True
    return found_name and struct.pack('<I', function_id) in code

assert names_method(rvas[14], 'RequestCustomBinaries', 0x08711e2c), 'slot 71 is not RequestCustomBinaries'
print('PASS: IClientUserMap slot 71 names RequestCustomBinaries (IPC function 0x08711e2c)')

# Offline logon: the three wrappers must name their own methods and serialize
# their IPC function IDs, as above.
for rva, name, function_id in ((rvas[15], 'GetLogonState', 0xb3679023),
                               (rvas[16], 'CanLogonOffline', 0xe391b9f0),
                               (rvas[17], 'LogOnOffline', 0x706f013f)):
    assert names_method(rva, name, function_id), f'{name} is not at its pinned slot'
print('PASS: IClientUserMap slots 5/214/215 name GetLogonState, CanLogonOffline, LogOnOffline')
