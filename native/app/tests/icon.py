#!/usr/bin/env python3
"""Checks make-icon.swift, which draws the icon of Black & White.app (no game, no bw_native).

    python3 native/app/tests/icon.py

It compiles the drawing program and runs it three times: with --plain (the typographic icon, which
needs nothing but a system typeface), the way build-app.py runs it, with no options (the logo,
when native/app/icon-art/logo-art.txt is on this Mac; otherwise the plain icon again, which is
what a fresh clone gets), and with --plain --bezel 0 (the tile without its bezel). For each run it
checks that:
  - the ten pictures of an icon are written, each at the pixel size its name asks for;
  - the tile is the 824-unit rounded square of a macOS icon: opaque inside, a corner transparent,
    its rounded corner where it should be, a soft shadow under it;
  - the upper right half is white and the lower left half is black;
  - the logo is inverted across the cut: dark inside the white half, light inside the black half;
  - the bezel is a grey rim: it lifts the edge of the black half and dims the edge of the white half (and
    with --bezel 0 neither edge differs from its face);
  - nothing in the icon is coloured: no amber, no warm line along the cut;
  - the pupil is dark inside a light ring (the logo icon only);
  - iconutil packs the pictures into an .icns file and unpacks them again to the same ten names.
It also checks that a damaged logo file and a bad --bezel width are refused, with a message that
names the line or the option.

Standard library only (the PNG files are read here), so it runs under any python3. Exit status 0
when every check passes, 1 when one fails. When the logo file is missing the logo checks are
reported as not run.
"""
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
SOURCE = HERE / "make-icon.swift"
ART = HERE / "icon-art" / "logo-art.txt"
LOGO_HEIGHT, LOGO_DROP = 700, 2  # as in make-icon.swift: the logo is 700 units tall, centred, 2 units low
PICTURES = {  # file name -> pixels each way
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
failures = []


def check(ok, what):
    print("%s  %s" % ("ok  " if ok else "FAIL", what))
    if not ok:
        failures.append(what)


def run(*args):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True)


def read_png(path):
    """(width, height, rows) of an 8-bit RGBA PNG without interlacing; each row is bytes of r, g, b, a."""
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG file" % path)
    pos, idat, header = 8, b"", None
    while pos < len(data):
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + size
    width, height, depth, colour, _, _, interlace = header
    if (depth, colour, interlace) != (8, 6, 0):
        raise ValueError("%s: expected 8-bit RGBA without interlacing, got %s" % (path, (depth, colour, interlace)))
    raw, stride, rows, above, at = zlib.decompress(idat), width * 4, [], bytearray(width * 4), 0
    for _ in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            left = line[x - 4] if x >= 4 else 0
            up = above[x]
            upleft = above[x - 4] if x >= 4 else 0
            if kind == 1:
                line[x] = (line[x] + left) & 255
            elif kind == 2:
                line[x] = (line[x] + up) & 255
            elif kind == 3:
                line[x] = (line[x] + ((left + up) >> 1)) & 255
            elif kind == 4:
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                line[x] = (line[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else upleft)) & 255
        rows.append(bytes(line))
        above = line
    return width, height, rows


def pixel(rows, x, y):
    return tuple(rows[y][4 * x:4 * x + 4])


def brightness(rgba):
    return (rgba[0] + rgba[1] + rgba[2]) / 3


def eye_position():
    """Where the pupil is in the icon, in the drawing's 1024 units, as (x, y, half width, half height), or
    None without the logo's curves file. It is read from that file, so the check follows the art if it changes."""
    if not ART.is_file():
        return None
    box, points, group = None, [], None
    for line in ART.read_text().splitlines():
        field = line.split()
        if not field or field[0].startswith("#"):
            continue
        if field[0] == "box":
            box = [float(v) for v in field[1:5]]
        elif field[0] == "group":
            group = field[1]
        elif group == "eye" and field[0] in ("M", "C"):
            values = [float(v) for v in field[1:]]
            points += list(zip(values[0::2], values[1::2]))
    if box is None or not points:
        return None
    k = LOGO_HEIGHT / (box[3] - box[1])
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return (512 + k * (min(xs) + max(xs)) / 2, 512 + LOGO_DROP + k * (min(ys) + max(ys)) / 2,
            k * (max(xs) - min(xs)) / 2, k * (max(ys) - min(ys)) / 2)


def check_icon(label, tool, options, expect_logo, tmp, bezel=True):
    """Runs the program with `options` and checks the pictures it writes."""
    iconset = tmp / (label + ".iconset")
    r = run(tool, iconset, *options)
    check(r.returncode == 0, "%s: the program runs%s" % (label, "" if r.returncode == 0 else ": " + r.stderr.strip()[:300]))
    if r.returncode != 0:
        return None
    check(("logo from" in r.stdout) == expect_logo,
          "%s: it draws %s (%s)" % (label, "the logo" if expect_logo else "the plain icon", r.stdout.strip().splitlines()[0]))

    written = sorted(p.name for p in iconset.iterdir())
    check(written == sorted(PICTURES), "%s: the ten pictures an icon needs are written (%d found)" % (label, len(written)))
    for name, pixels in sorted(PICTURES.items()):
        try:  # the size is in the header: bytes 16 to 24 of a PNG file
            width, height = struct.unpack(">II", (iconset / name).read_bytes()[16:24])
            check((width, height) == (pixels, pixels), "%s: %s is %d x %d pixels (wanted %d)" % (label, name, width, height, pixels))
        except (OSError, struct.error) as e:
            check(False, "%s: %s can be read: %s" % (label, name, e))

    # The 512-pixel picture. Positions below are in the drawing's own 1024 units, halved to pixels.
    width, height, rows = read_png(iconset / "icon_512x512.png")
    at = lambda ux, uy: pixel(rows, int(ux / 2), int(uy / 2))
    check(at(2, 2)[3] == 0, "%s: the corner outside the rounded square is transparent" % label)
    top, left, right, bottom = at(512, 106), at(106, 512), at(918, 512), at(512, 918)
    check(all(p[3] == 255 for p in (top, left, right, bottom)),
          "%s: the tile reaches 824 units: opaque 6 units inside each edge" % label)
    outside = [at(512, 94), at(94, 512), at(930, 512)]
    check(all(p[3] < 70 for p in outside), "%s: and ends there: faint 6 units outside the edges (alpha %s)" % (label, [p[3] for p in outside]))
    # the corner: 493.6 units from the middle along the diagonal (the tile's corner radius is 215)
    diag = lambda r: at(512 + r / 2 ** 0.5, 512 - r / 2 ** 0.5)
    check(diag(486)[3] == 255 and diag(502)[3] < 120,
          "%s: the corner is rounded where it should be (alpha %d at 486 units out, %d at 502)" % (label, diag(486)[3], diag(502)[3]))
    shadow = at(512, 940)[3]
    check(20 < shadow < 200, "%s: a soft shadow lies under the tile (alpha %d)" % (label, shadow))

    white_half, black_half = at(840, 200), at(168, 828)
    check(white_half[3] == 255 and brightness(white_half) > 215, "%s: the upper right half is white (%s)" % (label, white_half))
    check(black_half[3] == 255 and brightness(black_half) < 50, "%s: the lower left half is black (%s)" % (label, black_half))

    # The bezel is 15 units wide: 7 units in from an edge is the lip, 35 units in is the face. It lifts the black
    # half's edge (the left one) and dims the white half's (the right one).
    lip, face = brightness(at(107, 512)), brightness(at(135, 512))
    lip_white, face_white = brightness(at(917, 512)), brightness(at(889, 512))
    if bezel:
        check(lip > face + 25, "%s: the bezel lifts the black half's edge (%.0f at 7 units in, %.0f at 35)" % (label, lip, face))
        check(lip_white < face_white - 15, "%s: and dims the white half's edge (%.0f at 7 units in, %.0f at 35)" % (label, lip_white, face_white))
    else:
        check(abs(lip - face) < 20, "%s: with no bezel the black half's edge is as dark as the face (%.0f at 7 units in, %.0f at 35)" % (label, lip, face))
        check(abs(lip_white - face_white) < 15, "%s: and the white half's edge as light (%.0f at 7 units in, %.0f at 35)" % (label, lip_white, face_white))

    # In the middle, where the logo is: dark on the white half (above the cut, x > y) and light on the black half.
    span = range(128, 384)
    dark_on_white = sum(1 for y in span for x in span if x > y + 4 and brightness(pixel(rows, x, y)) < 110)
    light_on_black = sum(1 for y in span for x in span if x < y - 4 and brightness(pixel(rows, x, y)) > 150)
    check(dark_on_white > 2000, "%s: the logo is dark on the white half (%d dark pixels)" % (label, dark_on_white))
    check(light_on_black > 2000, "%s: the logo is light on the black half (%d light pixels)" % (label, light_on_black))

    # Nothing is coloured: the warmest the ground gets is 15 levels more red than blue, an amber highlight 100.
    warm = sum(1 for y in range(height) for x in range(width)
               if rows[y][4 * x + 3] == 255 and rows[y][4 * x] - rows[y][4 * x + 2] > 40)
    check(warm == 0, "%s: nothing in the icon is coloured: no amber, no warm line (%d pixels with red 40 above blue)" % (label, warm))

    # The pupil: down a line through it, from outside the ring: dark, a light ring, the dark pupil, the light
    # ring again.
    if expect_logo:
        eye = eye_position()
        if eye is None:
            check(False, "%s: the logo's curves file has a pupil to look at" % label)
        else:
            ex, ey, half_width, half_height = eye
            runs = ""
            for dy in range(-int(half_height) - 24, int(half_height) + 25, 2):
                b = brightness(at(ex, ey + dy))
                kind = "L" if b > 170 else "D" if b < 100 else ""
                if kind and not runs.endswith(kind):
                    runs += kind
            check("DLDL" in runs, "%s: the pupil is dark inside a light ring (%.0f, %.0f units: %s)" % (label, ex, ey, runs))

    packed, unpacked = tmp / (label + ".icns"), tmp / (label + "-again.iconset")
    r = run("/usr/bin/iconutil", "--convert", "icns", "--output", packed, iconset)
    check(r.returncode == 0 and packed.is_file() and packed.stat().st_size > 10000,
          "%s: iconutil packs the pictures into an .icns file%s" % (label, "" if r.returncode == 0 else ": " + r.stderr.strip()))
    r = run("/usr/bin/iconutil", "--convert", "iconset", "--output", unpacked, packed)
    again = sorted(p.name for p in unpacked.glob("*.png"))
    check(r.returncode == 0 and again == sorted(PICTURES), "%s: iconutil unpacks the file to the same ten names" % label)
    return rows


def main():
    with tempfile.TemporaryDirectory(prefix="bw-icon-test-") as tmp:
        tmp = Path(tmp)
        tool = tmp / "make-icon"
        r = run("/usr/bin/swiftc", "-O", SOURCE, "-o", tool)
        check(r.returncode == 0, "make-icon.swift compiles" + ("" if r.returncode == 0 else ": " + r.stderr.strip()[:300]))
        if r.returncode != 0:
            return

        check_icon("plain", tool, ["--plain"], False, tmp)
        check_icon("flat", tool, ["--plain", "--bezel", "0"], False, tmp, bezel=False)
        if ART.is_file():
            check_icon("logo", tool, [], True, tmp)
        else:
            check_icon("default", tool, [], False, tmp)
            print("not run: the logo checks (%s is not on this Mac, so build-app.py draws the plain icon)" % ART)

        # A damaged logo file is refused, with the line that is wrong.
        broken = tmp / "broken.txt"
        broken.write_text("# a damaged file\nbox -10 -10 10 10\ngroup emblem\nM 0 0\nC 1 2 3\n")
        r = run(tool, tmp / "broken.iconset", "--art", broken)
        check(r.returncode == 1 and "line 5" in r.stderr,
              "a damaged logo file is refused, naming the line (exit %d: %s)" % (r.returncode, r.stderr.strip()[-80:]))
        r = run(tool, tmp / "missing.iconset", "--art", tmp / "no-such-file.txt")
        check(r.returncode == 1 and "cannot read" in r.stderr, "a missing logo file is refused (exit %d)" % r.returncode)

        # A bezel width that is not a number from 0 to 60 is refused.
        for width in ("99", "-3", "wide"):
            r = run(tool, tmp / "bad.iconset", "--plain", "--bezel", width)
            check(r.returncode == 1 and "--bezel" in r.stderr,
                  "--bezel %s is refused (exit %d: %s)" % (width, r.returncode, r.stderr.strip()[-70:]))


if __name__ == "__main__":
    main()
    print("\n%s" % ("all checks passed" if not failures else "%d check(s) failed" % len(failures)))
    sys.exit(1 if failures else 0)
