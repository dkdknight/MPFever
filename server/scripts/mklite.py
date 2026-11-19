# LITE copy (v3) of a Transport Fever 3 install or of a mod, for a server without rendering. Run on Linux, from the host's own files.
# Every archive keeps its exact byte layout (the engine reads entries at the offsets of its central directory). For the entries stored
# without compression:
#   .dds .wav .ogg .blob : the data is not copied (a hole in the file: no disk space, reads as zeros) except its first KEEP bytes
#   .tga                 : rewritten as a valid image of the same size, all pixels 0 (RLE or raw as the original), the rest is a hole
#   .png                 : rewritten as a valid PNG of the same size and format, all pixels 0 (one tiny zlib stream), the rest is a hole
# Loose files of a mod folder are treated the same way (same rules, same code). Everything else is copied as it is.
import os, sys, struct, zipfile, zlib, shutil, time

KEEP = 512
HOLE_EXT = {'.dds', '.wav', '.ogg', '.blob'}
CH = 8 * 1024 * 1024


def tga_stub(data, avail):
    """a TGA of the same size with zero pixels, in at most avail bytes, or None if the format is not handled"""
    if len(data) < 18:
        return None
    idlen, cmap, itype = data[0], data[1], data[2]
    w, h = struct.unpack('<HH', data[12:16])
    bpp = data[16]
    if cmap != 0 or itype not in (2, 3, 10, 11) or bpp not in (8, 16, 24, 32) or w == 0 or h == 0:
        return None
    head = data[:18 + idlen]
    px = bpp // 8
    if itype in (2, 3):                     # raw: zeros are valid pixels
        return head, 0
    out = bytearray(head)                   # RLE: runs of zero pixels, never across a scanline
    zero = b'\x00' * px
    for _ in range(h):
        n = w
        while n > 0:
            k = min(n, 128)
            out.append(0x80 | (k - 1)); out += zero; n -= k
    if len(out) > avail:
        return None
    return bytes(out), len(out)


def png_stub(data, avail):
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    pos = 8; chunks = []; ihdr = None
    while pos + 8 <= len(data):
        ln, typ = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        chunks.append((typ, body)); pos += 12 + ln
        if typ == b'IHDR':
            ihdr = body
        if typ == b'IEND':
            break
    if ihdr is None or len(ihdr) < 13:
        return None
    w, h, depth, ctype, comp, flt, interlace = struct.unpack('>IIBBBBB', ihdr[:13])
    if interlace != 0 or w == 0 or h == 0:
        return None
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if ch is None:
        return None
    rowbytes = (w * ch * depth + 7) // 8
    raw = b'\x00' * ((rowbytes + 1) * h)    # filter byte 0 + zero pixels
    idat = zlib.compress(raw, 9)
    out = bytearray(b'\x89PNG\r\n\x1a\n')
    done = False
    for typ, body in chunks:
        if typ == b'IDAT':
            if not done:
                done = True
                out += struct.pack('>I', len(idat)) + b'IDAT' + idat + struct.pack('>I', zlib.crc32(b'IDAT' + idat) & 0xffffffff)
            continue
        out += struct.pack('>I', len(body)) + typ + body + struct.pack('>I', zlib.crc32(typ + body) & 0xffffffff)
    if not done or len(out) > avail:
        return None
    return bytes(out), len(out)


def plan_entry(ext, data_len, read):
    """(bytes to write at the start of the entry's data, offset from which it is a hole) or None to keep the entry"""
    if ext in HOLE_EXT:
        return (None, KEEP) if data_len > KEEP else None
    if ext in ('.tga', '.png'):
        r = (tga_stub if ext == '.tga' else png_stub)(read(), data_len)
        if r is None:
            return None
        new, used = r
        used = max(len(new), used)
        return (new, used) if data_len > used + 64 else None
    return None


def process_zip(s, d, stats):
    size = os.path.getsize(s)
    plans = []                              # (data_start, data_end, new_bytes_or_None, hole_from_offset)
    with zipfile.ZipFile(s) as z, open(s, 'rb') as fi:
        for i in z.infolist():
            if i.is_dir() or i.compress_type != zipfile.ZIP_STORED:
                continue
            ext = os.path.splitext(i.filename)[1].lower()
            if ext not in HOLE_EXT and ext not in ('.tga', '.png'):
                continue
            fi.seek(i.header_offset); h = fi.read(30)
            if h[:4] != b'PK\x03\x04':
                continue
            nlen, elen = struct.unpack('<HH', h[26:30])
            ds = i.header_offset + 30 + nlen + elen
            de = ds + i.compress_size

            def read(ds=ds, n=i.compress_size):
                fi.seek(ds); return fi.read(n)
            p = plan_entry(ext, de - ds, read)
            if p:
                new, hole_from = p
                plans.append((ds, de, new, hole_from))
    plans.sort()
    with open(s, 'rb') as fi, open(d, 'wb') as fo:
        fo.truncate(size)
        pos = 0
        for ds, de, new, hole_from in plans:
            if ds > pos:
                copy_range(fi, fo, pos, ds, stats)
            if new is None:                 # keep the first hole_from bytes, hole the rest
                copy_range(fi, fo, ds, ds + hole_from, stats)
            else:
                fo.seek(ds); fo.write(new); stats['written'] += len(new)
            stats['hole'] += de - (ds + hole_from)
            pos = de
        if pos < size:
            copy_range(fi, fo, pos, size, stats)
    stats['plans'] += len(plans)


def copy_range(fi, fo, a, b, stats):
    fi.seek(a); fo.seek(a); n = b - a
    while n > 0:
        buf = fi.read(min(CH, n))
        if not buf:
            break
        fo.write(buf); n -= len(buf); stats['copied'] += len(buf)


def process_loose(s, d, stats):
    ext = os.path.splitext(s)[1].lower()
    size = os.path.getsize(s)
    if ext in HOLE_EXT or ext in ('.tga', '.png'):
        with open(s, 'rb') as fi:
            def read():
                fi.seek(0); return fi.read()
            p = plan_entry(ext, size, read)
            if p:
                new, hole_from = p
                with open(d, 'wb') as fo:
                    fo.truncate(size)
                    if new is None:
                        fi.seek(0); fo.write(fi.read(hole_from))
                    else:
                        fo.write(new)
                stats['hole'] += size - hole_from; stats['plans'] += 1
                return
    shutil.copy2(s, d)


if __name__ == '__main__':
    SRC, DST = sys.argv[1], sys.argv[2]
    stats = dict(hole=0, copied=0, written=0, plans=0)
    t0 = time.time(); nz = 0
    for dp, dn, fn in os.walk(SRC):
        out = os.path.join(DST, os.path.relpath(dp, SRC))
        os.makedirs(out, exist_ok=True)
        for f in fn:
            s = os.path.join(dp, f); d = os.path.join(out, f)
            if f.lower().endswith('.zip'):
                nz += 1; process_zip(s, d, stats)
                if nz % 200 == 0:
                    print('zips', nz, int(time.time() - t0), 's', flush=True)
            else:
                process_loose(s, d, stats)
    print('DONE zips', nz, 'entries rewritten/holed', stats['plans'], 'hole GB', round(stats['hole'] / 2**30, 2),
          'copied GB', round(stats['copied'] / 2**30, 2), 'stubs MB', round(stats['written'] / 2**20, 1), 'in', int(time.time() - t0), 's')
