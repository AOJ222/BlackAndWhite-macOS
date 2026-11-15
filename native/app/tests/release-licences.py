#!/usr/bin/env python3
"""Checks that build-app.py keeps a GPL-built FFmpeg out of a release, and that it takes FFmpeg
from the folder --ffmpeg-dir names (no game, no bw_native, nothing is built or started).

    python3 native/app/tests/release-licences.py

The app's own code is not under the GPL, so the FFmpeg it bundles has to be a build under the
LGPL. Each FFmpeg library states how it was built in its own file: the licence line that
avcodec_license() returns, and the configure line. This test writes small stand-in files that
hold those statements, in a temporary folder, and checks that:
  - ffmpeg_licence_problems names a library whose licence line says GPL;
  - it names a library configured with --enable-gpl, and one configured with --enable-nonfree;
  - it names libx264 and libx265, which only a GPL build loads;
  - it names nothing for an LGPL library whose configure line says --disable-gpl;
  - it leaves a library that is not FFmpeg's alone (those are covered by the Licenses folder);
  - resolve takes an FFmpeg library from the --ffmpeg-dir folder whatever path the loader
    command gave, and stops with a clear message when the folder does not have it.

Exit status 0 when every check passes, 1 when one fails.
"""
import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_app", HERE / "build-app.py")
build_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_app)

failures = []


def check(ok, what):
    print(("pass: " if ok else "FAIL: ") + what)
    if not ok:
        failures.append(what)


LGPL_LINE = b"libavcodec license: LGPL version 2.1 or later"
GPL_LINE = b"libavcodec license: GPL version 3 or later"
LGPL_CONFIGURE = b"--enable-shared --disable-static --disable-gpl --disable-nonfree --disable-autodetect"


def stand_in(folder, name, *statements):
    (Path(folder) / name).write_bytes(b"\0stand-in\0" + b"\0".join(statements) + b"\0")


with tempfile.TemporaryDirectory(prefix="bw-licence-test.") as tmp:
    tmp = Path(tmp)

    clean = tmp / "clean"
    clean.mkdir()
    stand_in(clean, "libavcodec.62.dylib", LGPL_LINE, LGPL_CONFIGURE)
    stand_in(clean, "libavutil.60.dylib", b"libavutil license: LGPL version 2.1 or later", LGPL_CONFIGURE)
    stand_in(clean, "libSDL3.0.dylib", b"a library of its own")
    check(build_app.ffmpeg_licence_problems(clean) == [],
          "an LGPL build (licence line LGPL, configured --disable-gpl) raises nothing")

    gpl_line = tmp / "gpl-line"
    gpl_line.mkdir()
    stand_in(gpl_line, "libavcodec.62.dylib", GPL_LINE, LGPL_CONFIGURE)
    check(build_app.ffmpeg_licence_problems(gpl_line) == ["libavcodec.62.dylib is built as GPL"],
          "a library whose licence line says GPL is named")

    gpl_configure = tmp / "gpl-configure"
    gpl_configure.mkdir()
    stand_in(gpl_configure, "libavformat.62.dylib", LGPL_LINE, b"--enable-gpl --enable-version3")
    check(build_app.ffmpeg_licence_problems(gpl_configure)
          == ["libavformat.62.dylib was configured with --enable-gpl"],
          "a library configured with --enable-gpl is named")

    nonfree = tmp / "nonfree"
    nonfree.mkdir()
    stand_in(nonfree, "libavutil.60.dylib", LGPL_LINE, b"--enable-nonfree")
    check(build_app.ffmpeg_licence_problems(nonfree)
          == ["libavutil.60.dylib was configured with --enable-nonfree"],
          "a library configured with --enable-nonfree is named")

    gpl_libs = tmp / "gpl-libs"
    gpl_libs.mkdir()
    stand_in(gpl_libs, "libavcodec.62.dylib", LGPL_LINE, LGPL_CONFIGURE)
    stand_in(gpl_libs, "libx264.165.dylib", b"an encoder")
    stand_in(gpl_libs, "libx265.215.dylib", b"an encoder")
    check(build_app.ffmpeg_licence_problems(gpl_libs)
          == ["libx264.165.dylib is a GPL library", "libx265.215.dylib is a GPL library"],
          "libx264 and libx265 are named as GPL libraries")

    other = tmp / "other"
    other.mkdir()
    stand_in(other, "libSomethingElse.1.dylib", GPL_LINE, b"--enable-gpl")
    check(build_app.ffmpeg_licence_problems(other) == [],
          "a library that is not FFmpeg's is left to the Licenses folder, not judged here")

    # --ffmpeg-dir: the FFmpeg libraries come from that folder, however the loader command names them.
    chosen = tmp / "chosen"
    chosen.mkdir()
    stand_in(chosen, "libavcodec.62.dylib", LGPL_LINE, LGPL_CONFIGURE)
    want = (chosen / "libavcodec.62.dylib").resolve()
    build_app.FFMPEG_DIR = chosen
    try:
        got_abs = build_app.resolve("/opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib", tmp / "image", tmp / "exe")
        got_rpath = build_app.resolve("@rpath/libavcodec.62.dylib", tmp / "image", tmp / "exe")
        check(got_abs == want and got_rpath == want,
              "resolve takes libavcodec from the --ffmpeg-dir folder (absolute and @rpath references)")
        try:
            build_app.resolve("@rpath/libavformat.62.dylib", tmp / "image", tmp / "exe")
            check(False, "resolve stops when the --ffmpeg-dir folder lacks a library")
        except SystemExit as stop:
            check("libavformat.62.dylib is loaded by" in str(stop) and str(chosen) in str(stop),
                  "resolve stops, naming the library and the folder, when the --ffmpeg-dir folder lacks it")
    finally:
        build_app.FFMPEG_DIR = None

if failures:
    print("%d check(s) failed" % len(failures))
    sys.exit(1)
print("all checks passed")
