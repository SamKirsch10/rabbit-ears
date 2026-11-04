#!/usr/bin/env python3
"""Turn a source icon PNG into an iOS AppIcon.appiconset.

iOS app icons must be a full-bleed square with no transparency, so this takes a source
that may have transparent corners or a transparent margin, drops the margin, scales the
icon to fill the canvas, flattens its corners onto the nearest opaque colour, and writes
an opaque RGB PNG plus the appiconset Contents.json.

  python3 scripts/make_app_icon.py icon.png iOS/Assets.xcassets/AppIcon.appiconset

Only stdlib is used: PNG decoding/encoding and the background extension are done here
because PIL isn't installed.
"""
import sys, zlib, struct, os


def decode(path):
    """Return (w, h, rgba) for an 8-bit non-interlaced RGB or RGBA PNG."""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f'{path}: not a PNG')
    pos, idat, info = 8, b'', []
    w = h = depth = ctype = interlace = 0
    while pos < len(data):
        ln, typ = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        crc = struct.unpack('>I', data[pos + 8 + ln:pos + 8 + ln + 4])[0]
        if zlib.crc32(typ + body) != crc:
            sys.exit(f'{path}: bad crc in chunk {typ}')
        pos += 12 + ln
        if typ == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif typ == b'IDAT':
            idat += body
        elif typ in (b'gAMA', b'sRGB', b'iCCP'):
            info.append((typ, body))
        elif typ == b'IEND':
            break
    if depth != 8 or ctype not in (2, 6) or interlace:
        sys.exit(f'{path}: need an 8-bit RGB/RGBA non-interlaced PNG '
                 f'(got depth={depth} type={ctype} interlace={interlace})')
    raw = zlib.decompress(idat)
    src_bpp = 4 if ctype == 6 else 3
    stride = w * src_bpp
    rgba = bytearray(w * h * 4)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f == 1:                                   # Sub
            for i in range(src_bpp, stride):
                line[i] = (line[i] + line[i - src_bpp]) & 0xFF
        elif f == 2:                                 # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:                                 # Average
            for i in range(stride):
                a = line[i - src_bpp] if i >= src_bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:                                 # Paeth
            for i in range(stride):
                a = line[i - src_bpp] if i >= src_bpp else 0
                b = prev[i]
                c = prev[i - src_bpp] if i >= src_bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif f != 0:
            sys.exit(f'{path}: unknown row filter {f}')
        for x in range(w):
            q = (y * w + x) * 4
            rgba[q:q + 3] = line[x * src_bpp:x * src_bpp + 3]
            rgba[q + 3] = line[x * src_bpp + 3] if src_bpp == 4 else 255
        prev = line
    return w, h, rgba, info


def chunk(typ, data):
    """One PNG chunk: length, type, data, crc32 of type+data."""
    return struct.pack('>I', len(data)) + typ + data + struct.pack('>I', zlib.crc32(typ + data))


def encode_rgb(path, w, h, rgb, chunks=()):
    """Write an opaque 8-bit RGB PNG. chunks are colour-info chunks (gAMA/sRGB/iCCP) to keep."""
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)                      # filter: None
        raw += rgb[y * stride:(y + 1) * stride]
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    for typ, body in chunks:
        out += chunk(typ, body)
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    out += chunk(b'IEND', b'')
    open(path, 'wb').write(out)


def nearest_opaque(w, h, rgba, opaque_min):
    """Index of the nearest opaque pixel for every pixel, by a 3/3/4 chamfer distance transform.

    Used to fill the transparent corners left over once the icon fills the whole canvas.
    """
    n = w * h
    INF = 1 << 30
    d = [INF] * n
    src = [-1] * n
    for p in range(n):
        if rgba[p * 4 + 3] >= opaque_min:
            d[p] = 0
            src[p] = p
    if src.count(-1) == n:
        sys.exit('no opaque pixels found')
    for y in range(h):
        base = y * w
        for x in range(w):
            p = base + x
            if d[p] == 0:
                continue
            best, bs = d[p], src[p]
            if x > 0:
                q = p - 1
                if d[q] + 3 < best:
                    best, bs = d[q] + 3, src[q]
                if y > 0 and d[q - w] + 4 < best:
                    best, bs = d[q - w] + 4, src[q - w]
            if y > 0:
                q = p - w
                if d[q] + 3 < best:
                    best, bs = d[q] + 3, src[q]
                if x + 1 < w and d[q + 1] + 4 < best:
                    best, bs = d[q + 1] + 4, src[q + 1]
            d[p], src[p] = best, bs
    for y in range(h - 1, -1, -1):
        base = y * w
        for x in range(w):
            p = base + x
            if d[p] == 0:
                continue
            best, bs = d[p], src[p]
            if x + 1 < w:
                q = p + 1
                if d[q] + 3 < best:
                    best, bs = d[q] + 3, src[q]
                if y + 1 < h and d[q + w] + 4 < best:
                    best, bs = d[q + w] + 4, src[q + w]
            if y + 1 < h:
                q = p + w
                if d[q] + 3 < best:
                    best, bs = d[q] + 3, src[q]
                if x > 0 and d[q - 1] + 4 < best:
                    best, bs = d[q - 1] + 4, src[q - 1]
            d[p], src[p] = best, bs
    return src


CONTENTS_JSON = """{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024",
      "filename" : "AppIcon.png"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""


def main():
    if len(sys.argv) < 3:
        sys.exit(f'usage: {sys.argv[0]} <source.png> <appiconset-dir> [size]')
    src_path, out_dir = sys.argv[1], sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
    opaque_min = 200          # alpha below this counts as background, not icon content

    w, h, rgba, info = decode(src_path)
    if w != h:
        sys.exit(f'{src_path}: the source must be square ({w}x{h})')
    x0, y0, x1, y1 = opaque_bbox(w, h, rgba, opaque_min)
    if (x0, y0, x1, y1) != (0, 0, w - 1, h - 1):
        print(f'{w}x{h}: icon content is x {x0}..{x1}, y {y0}..{y1}; '
              f'cropped and scaled to fill {size}x{size}')
    rgba = resample(w, h, rgba, x0, y0, x1, y1, size, size)
    w = h = size

    src = nearest_opaque(w, h, rgba, opaque_min)
    rgb = bytearray(w * h * 3)
    outside = 0
    for p in range(w * h):
        a = rgba[p * 4 + 3]
        q = p * 3
        if a >= 255 and src[p] == p:
            rgb[q:q + 3] = rgba[p * 4:p * 4 + 3]
            continue
        outside += src[p] != p
        s = p * 4
        t = src[p] * 4
        for c in range(3):
            rgb[q + c] = (rgba[s + c] * a + rgba[t + c] * (255 - a)) // 255
    print(f'{w}x{h}: filled {outside} pixels outside the icon with the nearest icon colour, '
          f'and made all {w * h} pixels opaque')

    os.makedirs(out_dir, exist_ok=True)
    png = os.path.join(out_dir, 'AppIcon.png')
    encode_rgb(png, w, h, rgb, info)
    open(os.path.join(out_dir, 'Contents.json'), 'w').write(CONTENTS_JSON)
    assets = os.path.dirname(out_dir)
    if not os.path.exists(os.path.join(assets, 'Contents.json')):
        open(os.path.join(assets, 'Contents.json'), 'w').write(
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    print(f'wrote {png} and Contents.json')



def opaque_bbox(w, h, rgba, opaque_min):
    """Bounds of the icon's own pixels: (x0, y0, x1, y1), inclusive."""
    lo_x = lo_y = w * h
    hi_x = hi_y = -1
    for p in range(w * h):
        if rgba[p * 4 + 3] >= opaque_min:
            x, y = p % w, p // w
            lo_x = min(lo_x, x)
            hi_x = max(hi_x, x)
            lo_y = min(lo_y, y)
            hi_y = max(hi_y, y)
    if hi_x < 0:
        sys.exit('no opaque pixels found')
    return lo_x, lo_y, hi_x, hi_y


def resample(w, h, rgba, x0, y0, x1, y1, new_w, new_h):
    """Bilinear resample of the box x0..x1, y0..y1 of rgba (w wide) to new_w x new_h RGBA."""
    sx, sy = (x1 - x0 + 1) / new_w, (y1 - y0 + 1) / new_h
    out = bytearray(new_w * new_h * 4)
    for y in range(new_h):
        fy = min(max((y + 0.5) * sy - 0.5, 0.0), y1 - y0)
        iy = min(y0 + int(fy), h - 2)
        wy = min(fy - int(fy), 1.0)
        row = (iy * w) * 4
        next_row = row + w * 4
        for x in range(new_w):
            fx = min(max((x + 0.5) * sx - 0.5, 0.0), x1 - x0)
            ix = min(x0 + int(fx), w - 2)
            wx = min(fx - int(fx), 1.0)
            q = (y * new_w + x) * 4
            for c in range(4):
                p00 = row + ix * 4 + c
                top = rgba[p00] + (rgba[p00 + 4] - rgba[p00]) * wx
                bot = rgba[next_row + ix * 4 + c] + (rgba[next_row + ix * 4 + c + 4] - rgba[next_row + ix * 4 + c]) * wx
                out[q + c] = round(top + (bot - top) * wy)
    return out


if __name__ == '__main__':
    main()
