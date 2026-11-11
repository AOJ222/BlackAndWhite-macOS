#!/usr/bin/env python3
"""Builds "Black & White.app" from a bw_native build.

    python3 native/app/build-app.py [--build-dir DIR] [--out DIR] [--game-dir DIR] [--disc-dir DIR]
                                    [--install] [--force] [--release]

The app holds the native build, the libraries it loads, and the program files the set-up
generates the game program from; it holds no game content — every world, texture and
sound comes from the player's own copy of the game. On its first
start it asks for that copy and sets the game up from it (frontdoor/, a compiled
Swift program, Contents/MacOS/BlackWhite); later starts go straight to the game. With
--release nothing about this Mac is baked in: defaults.conf names only the program the build
was made from, so the app always starts with the add-your-disc step. Without --release, and
without --game-dir and --disc-dir, the folders it is set up to use are the copies that
stage-game.py puts in ~/Library/Application Support/Black & White/, or, when those do not
exist, the repository's own.

What it does:
  1. Takes bw_native and every non-system library it loads (SwARc's librecomp_*.dylib, SDL3,
     ffmpeg and what ffmpeg loads) from the build directory and Homebrew, and copies them in.
  2. Rewrites each library's install name and its references to @rpath/<name>, removes every
     other run-path (the build directory's, Homebrew's) and adds one that points inside the app,
     so the app cannot silently load a library from outside itself.
  3. Signs everything ad hoc (the Apple silicon loader needs a signature; there is no identity).
  4. Writes Info.plist, the icon (AppIcon.icns, drawn by make-icon.swift and packed by iconutil),
     BUILD-INFO.txt (the revisions the build came from, and whether the trees had uncommitted
     changes) and defaults.conf (where this Mac's game files are).
  5. Checks the result: the signature, every library reference, every run-path, the icon, and that
     the app's own bw_native starts (dyld must find every library inside the app).
  6. Builds "Black & White Settings.app" beside it (settings/BlackWhiteSettings.swift): the window
     where the screen, picture size, sharpness, frame limit and sound are chosen, which writes
     settings.conf and can restart the game with the new choices. It is signed and checked the same
     way (its own checks run from inside the finished bundle).
  7. Compiles the front door (frontdoor/BlackWhiteFrontDoor.swift) as the bundle's main
     executable, Contents/MacOS/BlackWhite, with launcher.sh in Resources as
     BlackWhiteLauncher.sh, game-manifest.json in Resources, and unshield in
     Contents/Helpers (its library goes in Frameworks with the rest), so a first start can
     add the player's disc with no Terminal and no tools of the Mac's own. The front door's
     own checks run from inside the finished bundle, as the settings app's do.

It changes nothing in the build directory or in the trees the build came from. It refuses to
copy bw_native while a build is running (the file may be half written).
"""
import argparse
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]  # native/app -> native -> the repository root
NAME = "Black & White"
LAUNCHER_NAME = "BlackWhite"
LAUNCHER_SCRIPT_NAME = "BlackWhiteLauncher"  # launcher.sh, which the front door hands over to
FRONTDOOR_SOURCE = HERE / "frontdoor" / "BlackWhiteFrontDoor.swift"
ICON_NAME = "AppIcon"  # Resources/AppIcon.icns, named by CFBundleIconFile
# The pictures an icon file is made of, as iconutil names them (16 to 512 points, at 1x and 2x).
ICON_PICTURES = ["icon_%dx%d%s.png" % (n, n, at) for n in (16, 32, 128, 256, 512) for at in ("", "@2x")]
BUNDLE_ID = "local.blackandwhite.native"
SETTINGS_NAME = NAME + " Settings"
SETTINGS_EXECUTABLE = "BlackWhiteSettings"
SETTINGS_BUNDLE_ID = BUNDLE_ID + ".settings"
SETTINGS_SOURCE = HERE / "settings" / "BlackWhiteSettings.swift"
MIN_FREE_GB_WARN = 15
MIN_FREE_GB_STOP = 12
STAGED = Path.home() / "Library/Application Support/Black & White"
INSTALL_DIR = Path.home() / "Applications"
# Folders macOS keeps private from an app until the user lets it in (and a shell script cannot ask).
PRIVATE_FOLDERS = [Path.home() / n for n in ("Desktop", "Documents", "Downloads")]


def protected_by_macos(folder):
    folder = Path(folder).resolve()
    return any(folder == p or p in folder.parents for p in PRIVATE_FOLDERS) or str(folder).startswith("/Volumes/")


def run(*args, check=True):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise SystemExit("failed: %s\n%s%s" % (" ".join(str(a) for a in args), p.stdout, p.stderr))
    return p


def is_system(path):
    return path.startswith("/usr/lib/") or path.startswith("/System/")


def otool_deps(image):
    """The install paths an image loads, without its own install name."""
    lines = run("/usr/bin/otool", "-L", image).stdout.splitlines()[1:]
    deps = []
    for line in lines:
        m = re.match(r"\s+(\S.*?) \(compatibility version", line)
        if m:
            deps.append(m.group(1))
    own = install_id(image)
    return [d for d in deps if d != own]


def install_id(image):
    lines = run("/usr/bin/otool", "-D", image).stdout.splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def rpaths(image):
    lines = run("/usr/bin/otool", "-l", image).stdout.splitlines()
    found = []
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for j in range(i + 1, min(i + 4, len(lines))):
                m = re.match(r"\s+path (.*) \(offset \d+\)", lines[j])
                if m:
                    found.append(m.group(1))
                    break
    return found


def resolve(dep, image, exe):
    """The real file an install path names, as seen from `image` (a run-time loader search)."""
    leaf = dep.split("/", 1)[1] if dep.startswith("@") else None
    candidates = []
    if dep.startswith("@rpath/"):
        for rp in rpaths(image) + rpaths(exe) + ["/opt/homebrew/lib"]:
            rp = rp.replace("@loader_path", str(Path(image).parent))
            rp = rp.replace("@executable_path", str(Path(exe).parent))
            candidates.append(Path(rp) / leaf)
    elif dep.startswith("@loader_path/"):
        candidates.append(Path(image).parent / leaf)
    elif dep.startswith("@executable_path/"):
        candidates.append(Path(exe).parent / leaf)
    else:
        candidates.append(Path(dep))
    for c in candidates:
        if c.exists():
            return c.resolve()
    raise SystemExit("cannot find %s (loaded by %s)" % (dep, image))


def closure(exe):
    """leaf name -> real file, for every non-system library the executable loads, directly or not."""
    found = {}
    stack = [Path(exe)]
    while stack:
        image = stack.pop()
        for dep in otool_deps(image):
            if is_system(dep):
                continue
            real = resolve(dep, image, exe)
            leaf = os.path.basename(dep)
            if leaf in found:
                if found[leaf] != real:
                    raise SystemExit("two different files are called %s: %s and %s" % (leaf, found[leaf], real))
                continue
            found[leaf] = real
            stack.append(real)
    return found


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def git(tree, *args):
    p = subprocess.run(["git", "-C", str(tree)] + [str(a) for a in args], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else "unknown"


def tree_state(tree):
    rev = git(tree, "rev-parse", "--short", "HEAD")
    branch = git(tree, "rev-parse", "--abbrev-ref", "HEAD")
    changes = git(tree, "status", "--porcelain")
    n = len([l for l in changes.splitlines() if l.strip()])
    return rev, branch, n


SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".inc", ".m", ".mm", ".cmake"}
NOT_BUILT_FROM = {"tests", "test", "docs", "inputs", "tools", "examples"}


def newest_source(tree):
    """(write time, path) of the most recently written tracked source file of a tree that goes into a build."""
    p = subprocess.run(["git", "-C", str(tree), "ls-files", "-z"], capture_output=True, text=True)
    best = (0, None)
    for rel in p.stdout.split("\0"):
        if not rel:
            continue
        parts = Path(rel).parts
        if NOT_BUILT_FROM & set(parts[:-1]):
            continue
        name = parts[-1]
        if Path(name).suffix not in SOURCE_SUFFIXES and name != "CMakeLists.txt":
            continue
        try:
            t = int((tree / rel).stat().st_mtime)
        except OSError:
            continue
        if t > best[0]:
            best = (t, rel)
    return best


def stale_notes(artifact_time, trees):
    """Say so when a source file was written after the newest piece of the build that went into the app."""
    notes = []
    for tree in trees:
        t, rel = newest_source(tree)
        if rel and t > artifact_time + 2:
            notes.append(
                "%s/%s was written at %s, after the newest part of this build (%s); rebuild bw_native, then this app"
                % (tree.name, rel, time.strftime("%H:%M:%S", time.localtime(t)),
                   time.strftime("%H:%M:%S", time.localtime(artifact_time)))
            )
    return notes


def rewrite(image, is_exe):
    """Install name and references to @rpath/<leaf>; only a run-path inside the app is left."""
    args = ["/usr/bin/install_name_tool"]
    if not is_exe:
        args += ["-id", "@rpath/" + image.name]
    for dep in otool_deps(image):
        if not is_system(dep):
            args += ["-change", dep, "@rpath/" + os.path.basename(dep)]
    for rp in sorted(set(rpaths(image))):
        args += ["-delete_rpath", rp]
    args += ["-add_rpath", "@executable_path/../Frameworks" if is_exe else "@loader_path"]
    args.append(str(image))
    run(*args)


def sign(path):
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", path)


def unshield_files():
    """(the unshield program, its library's leaf name, the library file) on this Mac."""
    named = os.environ.get("BW_UNSHIELD")
    places = [named] if named else []
    places += [shutil.which("unshield"), "/opt/homebrew/bin/unshield", "/usr/local/bin/unshield"]
    program = next((Path(p) for p in places if p and os.access(p, os.X_OK)), None)
    if program is None:
        raise SystemExit("unshield was not found; it unpacks the disc's installer files inside the app "
                         "(brew install unshield, or BW_UNSHIELD=<path>)")
    leaf = next((os.path.basename(d) for d in otool_deps(program) if "libunshield" in d), None)
    if leaf is None:
        raise SystemExit("%s does not load a libunshield library" % program)
    for candidate in (program.parent.parent / "lib" / leaf, Path("/opt/homebrew/lib") / leaf,
                      Path("/usr/local/lib") / leaf):
        if candidate.exists():
            return program, leaf, candidate
    raise SystemExit("the library %s that %s loads was not found" % (leaf, program))


def make_icon(dest):
    """Draws the icon (make-icon.swift) and packs its ten pictures into the .icns file `dest`."""
    with tempfile.TemporaryDirectory(prefix="bw-icon-") as tmp:
        tool = Path(tmp) / "make-icon"
        iconset = Path(tmp) / (ICON_NAME + ".iconset")
        run("/usr/bin/swiftc", "-O", HERE / "make-icon.swift", "-o", tool)
        run(tool, iconset)
        run("/usr/bin/iconutil", "--convert", "icns", "--output", dest, iconset)


def build_settings_app(parent, icon, build_id):
    """Builds "Black & White Settings.app" in `parent` from settings/BlackWhiteSettings.swift.

    It uses the system's frameworks only, so there is nothing to bundle or rewrite; it is signed
    ad hoc like the game. `icon` is the game's AppIcon.icns, which it shares.
    """
    app = parent / (SETTINGS_NAME + ".app")
    contents = app / "Contents"
    for sub in ("MacOS", "Resources"):
        (contents / sub).mkdir(parents=True)
    run("/usr/bin/swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos13.0",
        SETTINGS_SOURCE, "-o", contents / "MacOS" / SETTINGS_EXECUTABLE)
    shutil.copy2(icon, contents / "Resources" / (ICON_NAME + ".icns"))
    plist = {
        "CFBundleName": SETTINGS_NAME,
        "CFBundleDisplayName": SETTINGS_NAME,
        "CFBundleIdentifier": SETTINGS_BUNDLE_ID,
        "CFBundleExecutable": SETTINGS_EXECUTABLE,
        "CFBundleIconFile": ICON_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.00 native",
        "CFBundleVersion": build_id,
        "LSMinimumSystemVersion": "13.0",
        "LSApplicationCategoryType": "public.app-category.games",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with open(contents / "Info.plist", "wb") as f:
        plistlib.dump(plist, f)
    sign(app)
    return app


def verify_settings(app):
    """What must hold of a finished settings app; the list of what does not."""
    problems = []
    r = run("/usr/bin/codesign", "--verify", "--deep", "--strict", app, check=False)
    if r.returncode != 0:
        problems.append("settings app: codesign --verify failed: " + (r.stderr or r.stdout).strip())
    plist = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    exe = app / "Contents" / "MacOS" / plist.get("CFBundleExecutable", "")
    if not exe.is_file():
        problems.append("settings app: the executable named by Info.plist (%r) is missing" % plist.get("CFBundleExecutable"))
        return problems
    if not (app / "Contents" / "Resources" / (plist.get("CFBundleIconFile", "") + ".icns")).is_file():
        problems.append("settings app: the icon named by Info.plist is missing")
    for dep in otool_deps(exe):
        if not is_system(dep):
            problems.append("settings app loads %s, which is not a system library" % dep)
    # Its own checks (reading and writing the file) run from inside the finished bundle.
    p = subprocess.run([str(exe), "--selftest"], capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        problems.append("settings app --selftest: exit %s\n%s%s" % (p.returncode, p.stdout[-600:], p.stderr[-300:]))
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-dir", default=str(REPO / "native/bw-native/build/release"))
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--game-dir", help="the game folder to bake in as the default (see below)")
    ap.add_argument("--disc-dir", help="the disc copy to bake in as the default (see below)")
    ap.add_argument("--force", action="store_true", help="build although a build is running")
    ap.add_argument("--release", action="store_true",
                    help="a copy for other Macs: no game folder or disc copy of this Mac in defaults.conf, "
                         "so its first start is the add-your-disc step")
    ap.add_argument("--install", action="store_true",
                    help="also copy the finished app to ~/Applications (replacing an earlier copy there)")
    args = ap.parse_args()

    # The defaults are the copies made by stage-game.py when they exist: an app started from Finder
    # cannot read the Desktop, where the repository's own copies are.
    if args.game_dir:
        game_dir = Path(args.game_dir).resolve()
    elif (STAGED / "Game").is_dir():
        game_dir = STAGED / "Game"
    else:
        game_dir = REPO / "native/run/game"
    if args.disc_dir:
        disc_dir = Path(args.disc_dir).resolve()
    elif (STAGED / "Disc").is_dir():
        disc_dir = STAGED / "Disc"
    else:
        disc_dir = REPO / "native/run/cd"
    if not args.release:
        for label, folder in (("game folder", game_dir), ("disc copy", disc_dir)):
            if protected_by_macos(folder):
                print("warning: the %s %s is under a folder macOS keeps private from apps started in Finder; "
                      "run native/app/stage-game.py and build again" % (label, folder))

    build = Path(args.build_dir).resolve()
    exe = build / "bw_native"
    if not exe.is_file():
        raise SystemExit("no bw_native in %s" % build)

    free_gb = shutil.disk_usage(HERE).free / 2**30
    if free_gb < MIN_FREE_GB_STOP:
        raise SystemExit("only %.1f GiB free; the stop limit is %d GiB" % (free_gb, MIN_FREE_GB_STOP))
    if free_gb < MIN_FREE_GB_WARN:
        print("warning: %.1f GiB free; the limit to start work is %d GiB" % (free_gb, MIN_FREE_GB_WARN))

    # Do not copy a program that is being linked.
    busy = run("/usr/bin/pgrep", "-f", "ninja -C|cmake --build", check=False).stdout.split()
    if busy and not args.force:
        raise SystemExit("a build is running (pid %s); wait for it, or use --force" % " ".join(busy))
    first = (exe.stat().st_size, exe.stat().st_mtime_ns)
    time.sleep(1.5)
    if first != (exe.stat().st_size, exe.stat().st_mtime_ns):
        raise SystemExit("bw_native changed while it was being read; run this again")

    libs = closure(exe)

    # When the parts of this build were written, read before anything is copied or rewritten: the
    # program, and the libraries built inside this repository (not Homebrew's).
    lib_times = [int(Path(real).stat().st_mtime) for real in libs.values() if str(real).startswith(str(REPO))]
    newest_lib = max(lib_times) if lib_times else int(exe.stat().st_mtime)
    artifact_time = max(int(exe.stat().st_mtime), newest_lib)

    out = Path(args.out).resolve()
    work = out / (".building-%d" % os.getpid())
    app = work / (NAME + ".app")
    contents = app / "Contents"
    for sub in ("MacOS", "Frameworks", "Resources"):
        (contents / sub).mkdir(parents=True)

    shutil.copy2(exe, contents / "MacOS" / "bw_native")
    for leaf, real in sorted(libs.items()):
        shutil.copy2(real, contents / "Frameworks" / leaf)
    # unshield's libraries ride with the game's libraries (its own, and the OpenSSL it
    # loads); the program itself is placed below, in Helpers.
    unshield_program, unshield_leaf, unshield_lib = unshield_files()
    for leaf, real in sorted(closure(unshield_program).items()):
        if leaf in libs and libs[leaf] != real:
            raise SystemExit("two different files are called %s: %s and %s" % (leaf, libs[leaf], real))
        shutil.copy2(real, contents / "Frameworks" / leaf)
    for p in list((contents / "Frameworks").iterdir()) + [contents / "MacOS" / "bw_native"]:
        os.chmod(p, 0o755)

    for p in sorted((contents / "Frameworks").iterdir()):
        rewrite(p, False)
    rewrite(contents / "MacOS" / "bw_native", True)

    # The front door is the bundle's main executable: a compiled program, so macOS lets it
    # ask for the player's disc. It hands over to the launcher script beside it once the
    # game is set up (and answers the test switches through it, as before).
    run("/usr/bin/swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos13.0",
        FRONTDOOR_SOURCE, "-o", contents / "MacOS" / LAUNCHER_NAME)
    # The launcher script goes in Resources, not MacOS: the bundle seal covers it there,
    # and a loose script in MacOS makes codesign refuse the bundle.
    shutil.copy2(HERE / "launcher.sh", contents / "Resources" / (LAUNCHER_SCRIPT_NAME + ".sh"))
    os.chmod(contents / "Resources" / (LAUNCHER_SCRIPT_NAME + ".sh"), 0o755)
    shutil.copy2(HERE / "game-manifest.json", contents / "Resources" / "game-manifest.json")

    # The program files the front door generates the game program from at set-up, so the
    # player's own copy of the game is only ever asked for the game itself, never for a
    # program of its own. They are taken from the folder the build was lifted from
    # (BW_PROGRAM_DIR, else bw1-decomp's) and checked against the manifest; they are
    # build inputs of this Mac, never files of this repository.
    program_dir = Path(os.environ.get("BW_PROGRAM_DIR") or REPO / "bw1-decomp/orig/BW1W100")
    manifest = __import__("json").loads((HERE / "game-manifest.json").read_text())
    kit = contents / "Resources" / "ProgramKit"
    kit.mkdir()
    for entry in manifest.get("program", []):
        dest = entry["dest"]
        leaf = dest.rsplit("/", 1)[-1]
        cands = [program_dir / ("runblack-decrypted.exe" if dest == "runblack.exe" else leaf),
                 program_dir / dest, program_dir / leaf,
                 REPO / "native/run/game" / dest]
        src = next((c for c in cands if c.is_file()), None)
        if src is None:
            raise SystemExit("the program file for %s was not found in %s; set BW_PROGRAM_DIR to the "
                             "folder the build was lifted from" % (dest, program_dir))
        if sha256(src) != entry["sha256"] or src.stat().st_size != entry["size"]:
            raise SystemExit("%s is not the program file the manifest names for %s" % (src, dest))
        shutil.copy2(src, kit / leaf)

    helpers = contents / "Helpers"
    helpers.mkdir()
    bundled_unshield = helpers / "unshield"
    shutil.copy2(unshield_program, bundled_unshield)
    os.chmod(bundled_unshield, 0o755)
    tool_args = ["/usr/bin/install_name_tool"]
    for rp in sorted(set(rpaths(bundled_unshield))):
        tool_args += ["-delete_rpath", rp]
    tool_args += ["-add_rpath", "@executable_path/../Frameworks", str(bundled_unshield)]
    run(*tool_args)

    make_icon(contents / "Resources" / (ICON_NAME + ".icns"))

    build_tree = REPO / "native/bw-native"
    swarc_tree = REPO / "native/swarc"
    bw_rev, bw_branch, bw_dirty = tree_state(build_tree)
    sw_rev, sw_branch, sw_dirty = tree_state(swarc_tree)
    build_id = "%s%s" % (bw_rev, "+" if bw_dirty or sw_dirty else "")
    info = [
        "built %s" % time.strftime("%Y-%m-%d %H:%M:%S"),
        "bw-native %s (%s), %s" % (bw_rev, bw_branch, "uncommitted changes in %d files" % bw_dirty if bw_dirty else "clean"),
        "swarc %s (%s), %s" % (sw_rev, sw_branch, "uncommitted changes in %d files" % sw_dirty if sw_dirty else "clean"),
        "bw_native sha256 %s (as built, before the library paths were rewritten)" % sha256(exe),
        "bw_native file written %s; newest library of the build written %s"
        % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(exe.stat().st_mtime)),
           time.strftime("%H:%M:%S", time.localtime(newest_lib))),
        "libraries bundled: %d" % len(libs),
        "first start: the front door (compiled) offers to add the player's own copy of the game (disc, disc folder or installed copy, any version); the program files are generated at set-up from the bundled program kit; unshield is bundled",
        "defaults: %s" % ("release (no game folder or disc copy named)" if args.release
                          else "this Mac's game folder and disc copy"),
    ] + stale_notes(artifact_time, [build_tree, swarc_tree])
    (contents / "Resources" / "BUILD-INFO.txt").write_text("\n".join(info) + "\n")

    defaults = []
    # The program file the runtime insists on, read from the source it was built from.
    pin = re.search(r'kExe\s*=\s*\{"[^"]+",\s*"([0-9a-f]{64})"\}', (build_tree / "src/main.cpp").read_text())
    if pin:
        defaults.append("EXE_SHA256=%s" % pin.group(1))
    if not args.release and game_dir.is_dir():
        defaults.append("GAME_DIR=%s" % game_dir)
    if not args.release and disc_dir.is_dir():
        defaults.append("DISC_DIR=%s" % disc_dir)
    (contents / "Resources" / "defaults.conf").write_text(
        "# Where this Mac's game files were when the app was built. The player's settings.conf wins.\n"
        + "\n".join(defaults) + "\n")

    plist = {
        "CFBundleName": NAME,
        "CFBundleDisplayName": NAME,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleExecutable": LAUNCHER_NAME,
        "CFBundleIconFile": ICON_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.00 native",
        "CFBundleVersion": build_id,
        "LSMinimumSystemVersion": "27.0",
        "LSApplicationCategoryType": "public.app-category.games",
        "LSSupportsGameMode": True,
        "NSHighResolutionCapable": True,
        "NSSupportsAutomaticGraphicsSwitching": True,
    }
    with open(contents / "Info.plist", "wb") as f:
        plistlib.dump(plist, f)

    for p in sorted((contents / "Frameworks").iterdir()):
        sign(p)
    sign(contents / "Helpers" / "unshield")
    sign(contents / "MacOS" / LAUNCHER_NAME)
    sign(contents / "MacOS" / "bw_native")
    sign(app)

    problems = verify(app, libs, args.release)
    settings_app = build_settings_app(work, contents / "Resources" / (ICON_NAME + ".icns"), build_id)
    problems += verify_settings(settings_app)
    if problems:
        shutil.rmtree(work, ignore_errors=True)
        print("the app was not built:")
        for p in problems:
            print("  -", p)
        raise SystemExit(1)

    final = out / (NAME + ".app")
    if final.exists():
        shutil.rmtree(final)
    app.rename(final)
    settings_final = out / (SETTINGS_NAME + ".app")
    if settings_final.exists():
        shutil.rmtree(settings_final)
    settings_app.rename(settings_final)
    shutil.rmtree(work, ignore_errors=True)
    size = sum(f.stat().st_size for f in final.rglob("*") if f.is_file()) / 2**20
    print("built %s (%.0f MiB, %d libraries, %s)" % (final, size, len(libs), build_id))
    print("built %s" % settings_final)
    for line in info:
        print("  " + line)

    if args.install:
        install(final, settings_final)


def install(built, built_settings):
    """Copy the built apps to ~/Applications, unless the copy there is running."""
    INSTALL_DIR.mkdir(exist_ok=True)
    pairs = [(built, INSTALL_DIR / (NAME + ".app"), "Contents/MacOS/bw_native"),
             (built_settings, INSTALL_DIR / (SETTINGS_NAME + ".app"), "Contents/MacOS/" + SETTINGS_EXECUTABLE)]
    for _, target, program in pairs:
        if run("/usr/bin/pgrep", "-f", "%s/%s" % (target, program), check=False).stdout.split():
            raise SystemExit("not installed: %s is running; quit it and run this again" % target)
    for source, target, _ in pairs:
        if target.exists():
            shutil.rmtree(target)
        run("/usr/bin/ditto", source, target)
        r = run("/usr/bin/codesign", "--verify", "--deep", "--strict", target, check=False)
        if r.returncode != 0:
            raise SystemExit("installed copy fails codesign --verify: " + (r.stderr or r.stdout).strip())
        print("installed %s" % target)


def verify(app, libs, release=False):
    problems = []
    contents = app / "Contents"
    frameworks = contents / "Frameworks"
    images = sorted(frameworks.iterdir()) + [contents / "MacOS" / "bw_native"]
    bundled = set(p.name for p in frameworks.iterdir())

    r = run("/usr/bin/codesign", "--verify", "--deep", "--strict", app, check=False)
    if r.returncode != 0:
        problems.append("codesign --verify failed: " + (r.stderr or r.stdout).strip())

    # The icon: Info.plist names it, the file is there, and it unpacks to the ten pictures.
    icon = contents / "Resources" / (ICON_NAME + ".icns")
    named = plistlib.loads((contents / "Info.plist").read_bytes()).get("CFBundleIconFile")
    if named != ICON_NAME or not icon.is_file():
        problems.append("the icon: Info.plist names %r (wanted %r) and %s %s"
                        % (named, ICON_NAME, icon.name, "exists" if icon.is_file() else "is missing"))
    else:
        with tempfile.TemporaryDirectory(prefix="bw-icon-check-") as tmp:
            unpacked = Path(tmp) / "check.iconset"
            r = run("/usr/bin/iconutil", "--convert", "iconset", "--output", unpacked, icon, check=False)
            found = sorted(p.name for p in unpacked.glob("*.png"))
            if r.returncode != 0 or found != sorted(ICON_PICTURES):
                problems.append("%s does not unpack to the ten pictures of an icon (iconutil exit %d, found %s)"
                                % (icon.name, r.returncode, found))

    for image in images:
        for dep in otool_deps(image):
            if is_system(dep):
                continue
            if not dep.startswith("@rpath/") or dep[len("@rpath/"):] not in bundled:
                problems.append("%s loads %s, which is not a system library or one bundled in the app" % (image.name, dep))
        allowed = ["@executable_path/../Frameworks"] if image.name == "bw_native" else ["@loader_path"]
        if sorted(rpaths(image)) != allowed:
            problems.append("%s has run-paths %s, wanted %s" % (image.name, rpaths(image), allowed))

    # The program must start from inside the app: dyld resolves every library it names before
    # main() runs, and the checks above leave it no way to find one outside the app.
    p = subprocess.run([str(contents / "MacOS" / "bw_native"), "--help"], capture_output=True, text=True, timeout=60)
    if p.returncode != 0 or "usage: bw_native" not in p.stderr:
        problems.append("bw_native --help from inside the app: exit %s, no usage line (stderr starts: %r)"
                        % (p.returncode, p.stderr[:200]))

    # The front door: a compiled main executable that loads nothing but system libraries,
    # the launcher script beside it, the manifest in Resources, and its own checks passing
    # from inside the bundle (against a scratch support folder, never the player's own).
    frontdoor = contents / "MacOS" / LAUNCHER_NAME
    if not frontdoor.is_file():
        problems.append("the front door (%s) is missing" % LAUNCHER_NAME)
    else:
        for dep in otool_deps(frontdoor):
            if not is_system(dep):
                problems.append("the front door loads %s, which is not a system library" % dep)
        with tempfile.TemporaryDirectory(prefix="bw-frontdoor-check-") as tmp:
            env = dict(os.environ, BW_APP_SUPPORT_DIR=tmp)
            p = subprocess.run([str(frontdoor), "--selftest"], capture_output=True, text=True, timeout=120, env=env)
            if p.returncode != 0 or "all checks passed" not in p.stdout:
                problems.append("the front door --selftest from inside the app: exit %s\n%s%s"
                                % (p.returncode, p.stdout[-600:], p.stderr[-300:]))
    if not (contents / "Resources" / (LAUNCHER_SCRIPT_NAME + ".sh")).is_file():
        problems.append("the launcher script (%s.sh) is missing from Resources" % LAUNCHER_SCRIPT_NAME)
    manifest_path = contents / "Resources" / "game-manifest.json"
    if not manifest_path.is_file():
        problems.append("game-manifest.json is missing from Resources")
    else:
        import json
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("format") != 2 or len(manifest.get("files", [])) != 1063 \
                or len(manifest.get("program", [])) != 5:
            problems.append("game-manifest.json does not list the game folder's 1063 content files and 5 program files")
        kit = contents / "Resources" / "ProgramKit"
        for entry in manifest.get("program", []):
            leaf = entry["dest"].rsplit("/", 1)[-1]
            if not (kit / leaf).is_file():
                problems.append("the program kit has no %s" % leaf)

    # unshield must run from inside the app (its library found through its own run-path).
    unshield = contents / "Helpers" / "unshield"
    if not unshield.is_file():
        problems.append("unshield is missing from Helpers")
    else:
        p = subprocess.run([str(unshield), "-V"], capture_output=True, text=True, timeout=60)
        if p.returncode != 0 or "Unshield version" not in p.stdout:
            problems.append("unshield from inside the app: exit %s (stdout starts: %r)" % (p.returncode, p.stdout[:120]))

    # A release names no folder of the Mac it was built on, so its first start is always
    # the add-your-disc step.
    if release:
        defaults = (contents / "Resources" / "defaults.conf").read_text()
        if "GAME_DIR=" in defaults or "DISC_DIR=" in defaults:
            problems.append("a release defaults.conf names a game folder or disc copy of this Mac")
    return problems


if __name__ == "__main__":
    main()
