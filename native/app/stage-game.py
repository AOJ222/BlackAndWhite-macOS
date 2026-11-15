#!/usr/bin/env python3
"""Put a copy of the game folder and the disc copy where Black & White.app can read them.

macOS keeps ~/Desktop, ~/Documents, ~/Downloads and removable or network volumes private from each
app until the user lets it in, and it cannot ask when an app's main program is a shell script (the
log shows the request answered with "auth_value absent" and the read fails with "Operation not
permitted"). An app started from Finder therefore cannot read game files that sit on the Desktop,
although the same files read fine from Terminal.

This script copies the two folders into ~/Library/Application Support/Black & White/ (Game, Disc and
Disc.volume), which every app may read. On the same APFS volume the copy is made with clones, which
share the original's disk blocks until a file changes, so it costs next to no disk space and takes a
second or two. build-app.py then uses the copies as the app's default folders.

    python3 native/app/stage-game.py                 # copy (or report that the copy is current)
    python3 native/app/stage-game.py --replace       # copy again, replacing an earlier copy
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DEFAULT_DEST = Path.home() / "Library/Application Support/Black & White"
LIFTED_FILES = ["lhlogr.dll", "LHaudiodllR.dll", "LHMultiplayerR.dll", "Plug Ins/ScriptLibraryR.dll"]
MIN_FREE_GB_AFTER_COPY = 15  # the limit this project keeps on the shared machine


def tree_size(root):
    """(file count, total bytes) of the regular files under root."""
    count = 0
    total = 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                continue
            count += 1
            total += os.path.getsize(p)
    return count, total


def free_bytes(path):
    return shutil.disk_usage(path).free


def same_volume(a, b):
    return os.stat(a).st_dev == os.stat(b).st_dev


def remove_tree(path):
    # The disc copy keeps its read-only folder modes; make everything writable before removing.
    for dirpath, dirs, files in os.walk(path):
        os.chmod(dirpath, 0o755)
        for name in files:
            try:
                os.chmod(os.path.join(dirpath, name), 0o644)
            except OSError:
                pass
    shutil.rmtree(path)


def clone_tree(src, dst, can_clone):
    """Copy src to dst; with clones when the volumes allow (cp -c), as plain copies otherwise."""
    cmd = ["/bin/cp", "-R", "-p"]
    if can_clone:
        cmd.insert(1, "-c")
    cmd += [str(src), str(dst)]
    subprocess.run(cmd, check=True)


def stage(src, dst, what, replace, can_clone):
    src_count, src_bytes = tree_size(src)
    if dst.exists():
        count, size = tree_size(dst)
        if (count, size) == (src_count, src_bytes) and not replace:
            print("%s: already copied (%d files, %.0f MiB); nothing to do" % (what, count, size / 2**20))
            return
        if not replace:
            raise SystemExit(
                "%s: %s exists and differs from %s (%d files, %.0f MiB against %d files, %.0f MiB); "
                "run again with --replace to copy it afresh"
                % (what, dst, src, count, size / 2**20, src_count, src_bytes / 2**20)
            )
    partial = dst.with_name(dst.name + ".partial")
    if partial.exists():
        remove_tree(partial)
    before = free_bytes(dst.parent)
    clone_tree(src, partial, can_clone)
    count, size = tree_size(partial)
    if (count, size) != (src_count, src_bytes):
        remove_tree(partial)
        raise SystemExit(
            "%s: the copy has %d files, %.0f MiB, the original has %d files, %.0f MiB; removed the copy"
            % (what, count, size / 2**20, src_count, src_bytes / 2**20)
        )
    if dst.exists():
        remove_tree(dst)
    partial.rename(dst)
    used = max(0, before - free_bytes(dst.parent))
    print(
        "%s: copied %d files, %.0f MiB; the disk gave up about %.0f MiB for it"
        % (what, count, size / 2**20, used / 2**20)
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game-dir", default=str(REPO / "native/run/game"))
    ap.add_argument("--disc-dir", default=str(REPO / "native/run/cd"))
    ap.add_argument("--dest", default=str(DEFAULT_DEST))
    ap.add_argument("--replace", action="store_true", help="copy afresh when an earlier copy exists")
    args = ap.parse_args()

    game = Path(args.game_dir).resolve()
    disc = Path(args.disc_dir).resolve()
    disc_volume = disc.with_name(disc.name + ".volume")
    dest = Path(args.dest).expanduser()

    for needed in LIFTED_FILES:
        if not (game / needed).is_file():
            raise SystemExit("%s is not the game folder: %s is missing" % (game, needed))
    if not disc.is_dir() or not disc_volume.is_file():
        raise SystemExit("the disc copy needs a folder %s and a label file %s next to it" % (disc, disc_volume))

    dest.mkdir(parents=True, exist_ok=True)
    can_clone = same_volume(game, dest) and same_volume(disc, dest)
    need = sum(tree_size(p)[1] for p in (game, disc))
    if not can_clone:
        free_gb = (free_bytes(dest) - need) / 2**30
        if free_gb < MIN_FREE_GB_AFTER_COPY:
            raise SystemExit(
                "the folders are on another volume, so a full copy of %.1f GiB is needed, and it would leave "
                "%.1f GiB free (the limit is %d GiB)" % (need / 2**30, free_gb, MIN_FREE_GB_AFTER_COPY)
            )
        print("note: not the same volume as %s, so the copy is a full one" % dest)

    stage(game, dest / "Game", "game folder", args.replace, can_clone)
    stage(disc, dest / "Disc", "disc copy", args.replace, can_clone)
    shutil.copy2(disc_volume, dest / "Disc.volume")
    print("disc label file: %s" % (dest / "Disc.volume"))
    print("ready: %s" % dest)


if __name__ == "__main__":
    sys.exit(main())
