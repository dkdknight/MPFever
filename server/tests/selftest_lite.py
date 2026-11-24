import os, struct, zlib, random, shutil, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts'))
import mklite as M
random.seed(1)
tmp = tempfile.mkdtemp(prefix='fakemod_')
src = os.path.join(tmp, 'src', 'mymod', 'res'); dst = os.path.join(tmp, 'dst')
os.makedirs(src)
def png(w, h):
    raw = b''.join(b'\x00' + bytes(random.randrange(256) for _ in range(w * 4)) for _ in range(h))
    def ch(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw, 1)) + ch(b'IEND', b'')
def tga_rle(w, h):
    out = bytearray(b'\x00\x00\x0a' + b'\x00' * 9 + struct.pack('<HH', w, h) + b'\x20\x28')
    for _ in range(h):
        for _ in range(w):                       # worst case: one raw pixel per packet
            out.append(0); out += bytes(random.randrange(256) for _ in range(4))
    return bytes(out)
def tga_raw(w, h):
    return b'\x00\x00\x02' + b'\x00' * 9 + struct.pack('<HH', w, h) + b'\x18\x20' + bytes(random.randrange(256) for _ in range(w * h * 3))
files = {'tex/a.png': png(256, 256), 'tex/b.tga': tga_rle(128, 128), 'tex/c.tga': tga_raw(64, 64),
         'tex/d.dds': b'DDS ' + bytes(random.randrange(256) for _ in range(300000)), 'scripts/x.lua': b'return {}\n', 'models/m.msh': b'MSH' + bytes(5000)}
for n, d in files.items():
    p = os.path.join(src, n); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(d)
stats = dict(hole=0, copied=0, written=0, plans=0)
for dp, dn, fn in os.walk(os.path.join(tmp, 'src')):
    out = os.path.join(dst, os.path.relpath(dp, os.path.join(tmp, 'src'))); os.makedirs(out, exist_ok=True)
    for f in fn: M.process_loose(os.path.join(dp, f), os.path.join(out, f), stats)
print('entries rewritten/holed:', stats['plans'], 'hole bytes:', stats['hole'])
ok = True
for n, d in files.items():
    o = open(os.path.join(dst, 'mymod', 'res', n), 'rb').read()
    sz_ok = len(o) == len(d)
    msg = ''
    if n.endswith('.png'):
        pos = 8; idat = b''; crc_ok = True
        while pos < len(o):
            ln, t = struct.unpack('>I4s', o[pos:pos+8]); b = o[pos+8:pos+8+ln]
            crc_ok &= (struct.unpack('>I', o[pos+8+ln:pos+12+ln])[0] == zlib.crc32(t + b) & 0xffffffff)
            if t == b'IDAT': idat += b
            pos += 12 + ln
            if t == b'IEND': break
        raw = zlib.decompress(idat); msg = 'png decodes to %d bytes (expected %d), crc ok=%s, all zero=%s' % (len(raw), (256*4+1)*256, crc_ok, raw.count(0) == len(raw) - 0)
    if n == 'tex/b.tga':
        w, h = 128, 128; px = 0; pos = 18
        while px < w * h:
            c = o[pos]; pos += 1; k = (c & 127) + 1
            if c & 128: pos += 4
            else: pos += 4 * k
            px += k
        msg = 'rle tga decodes %d pixels (expected %d), stream ends at byte %d of %d' % (px, w*h, pos, len(o))
    print('%-14s size kept=%s  %s' % (n, sz_ok, msg))
    ok &= sz_ok
print('ALL SIZES KEPT' if ok else 'SIZE MISMATCH')
du = sum(getattr(os.stat(os.path.join(dp, f)), 'st_blocks', 0) * 512 for dp, dn, fn in os.walk(dst) for f in fn)
print('allocated in dst (bytes):', du, '  logical:', sum(len(d) for d in files.values()))
shutil.rmtree(tmp)
sys.exit(0 if ok else 1)
