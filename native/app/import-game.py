#!/usr/bin/env python3
"""Build the game folder and the disc copy that Black & White.app reads, from your own copy of the game.

    python3 native/app/import-game.py --iso ~/Downloads/BNW.iso        # from a disc image
    python3 native/app/import-game.py --disc <folder>                  # from a folder copy of the disc
    python3 native/app/import-game.py --folder <game folder>           # from an installed copy, any version
    python3 native/app/import-game.py --iso BNW.iso --dest <folder>    # or into another folder
    python3 native/app/import-game.py --iso BNW.iso --replace          # again, replacing an earlier import
    python3 native/app/import-game.py --check "<folder>/Game"          # check a game folder; changes nothing
    python3 native/app/import-game.py --ci-disc <folder>               # add Creature Isle over a set-up game
    python3 native/app/import-game.py --ci-folder <game folder>        # the same from an installed copy

Any complete copy of the game works: the original disc as sold, a patched copy (1.10/1.20, the Fan
Patch), or another language edition. Nothing in this repository contains game data:
native/app/game-manifest.json lists, for every file of the game folder, where it comes from on the disc,
its size, its SHA-256 and the forms it is known in from the other versions of the game, and this script
builds the folder from that list and checks every file it makes. Which version the copy is (the original
game, or a patched one that plays through the Fan Patch 1.42 build) is read from the copy itself and
written to settings.conf as GAME_VERSION; the five program files are never taken from the player's copy:
they are generated from the program files that version's native build was made from (--program-dir), so
no copy of the game is refused for carrying a different program. Creature Isle (its disc, or the folder
it is installed in) is added over a set-up base game the same way, from game-manifest-ci.json, and
GAME_VERSION becomes ci.

What it does, in order (disc image):
  1. reads the image without mounting it and copies its files into <dest>/Disc (read-only, like a disc),
     with the label and volume facts in <dest>/Disc.volume (native/bw-native/tools/prepare_disc.py);
  2. unpacks the installer's cabinets (<dest>/Disc/data1.cab and data2.cab) with `unshield` into a scratch
     folder (it is not installed by this script: `brew install unshield`);
  3. builds <dest>/Game from the cabinet files and from the disc's loose files, file by file as the
     manifest says, compares each file with the manifest (files that carry a language are accepted in
     any form; the rest must be a known form), then generates the program files;
  4. only when every file is right, puts the folder in place (an earlier Game folder is replaced only with
     --replace), and removes the scratch folder.

From an installed copy (--folder) the files are already in the game folder's layout and are taken as
they are; the disc copy is an empty folder with the right label, which is all the game's disc check
asks for. The default <dest> is ~/Library/Application Support/Black & White, where an app may read (a
game folder on the Desktop, in Documents or in Downloads is private from an app started by Finder: see
README.md). Disk needed: about the image's size plus 2.5 GiB while it runs (about 0.7 + 1.4 GiB
afterwards); it refuses to leave less than 15 GiB free.

--check reads a game folder and reports files that are missing or changed against the manifest (the
program files and two textures that the game itself seems to write to are allowed to differ). It reads
only.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DEFAULT_DEST = Path.home() / "Library/Application Support/Black & White"
MANIFEST = HERE / "game-manifest.json"
MANIFESTS = {"100": MANIFEST, "142": HERE / "game-manifest-142.json", "ci": HERE / "game-manifest-ci.json"}
PREPARE_DISC = REPO / "native/bw-native/tools/prepare_disc.py"
DEFAULT_PROGRAM_DIR = REPO / "bw1-decomp/orig/BW1W100"
# Where each version's program files live on this Mac (build inputs, never repository files).
PROGRAM_DIRS = {"100": DEFAULT_PROGRAM_DIR,
                "142": REPO / "toolkit-trial/bw-1.42",
                "ci": REPO / "bw1-decomp/orig/BW1WCI"}
# A program file an installed copy may carry, and the version it means (the two readable
# programs, and the two protected ones, whose files still say which version the copy is).
FOLDER_PROGRAM_VERSIONS = {
    "86a30b08ab2ea8a240403d37f8f0303cf65aa5cde8e7f673049ab01654ccf755": "100",
    "b1163b44f4e6c5e64d81d5fcce95dea8efdc587ad52910df4d4942e01dbfb3d1": "100",
    "3f58bc02a6c421b4e66ef08716646bf0e1fa55ab292786edb521d7596ed48aba": "142",
    "8b950ab537e77b32c22affea8d2e3dc6e8e62155d9f68a6a82d2a1114c4775ca": "142",
}
CHUNK = 1 << 20
SCRATCH_GIB = 2.5  # the unpacked cabinets (0.5) and the new game folder (1.4), with room to spare
UNSHIELD_PLACES = ("/opt/homebrew/bin/unshield", "/usr/local/bin/unshield")


def die(message):
    print("import-game: " + message, file=sys.stderr)
    sys.exit(1)


def load_manifest(version="100"):
    path = MANIFESTS[version]
    if not path.is_file():
        die("%s is missing (make-game-manifest.py writes it)" % path)
    manifest = json.loads(path.read_text())
    if manifest.get("format") != 2 or not manifest.get("files"):
        die("%s is not a manifest this script understands" % path)
    return manifest


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def copy_hashed(src, dst):
    """Copy src to dst; returns (size, SHA-256 of what was written)."""
    h = hashlib.sha256()
    size = 0
    dst.parent.mkdir(parents=True, exist_ok=True)
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        for block in iter(lambda: fin.read(CHUNK), b""):
            h.update(block)
            fout.write(block)
            size += len(block)
    return size, h.hexdigest()


def accepts(entry, size, digest):
    """Whether a made file may stand in the game folder (see the manifest's "check")."""
    if entry.get("check") == "any":
        return True
    if entry.get("mutable"):
        return size == entry["size"]
    if size == entry["size"] and digest == entry["sha256"]:
        return True
    return any(size == v["size"] and digest == v["sha256"] for v in entry.get("variants", []))


def remove_tree(path):
    """Remove a folder even when it holds read-only files and folders (the disc copy is read-only)."""
    if not os.path.lexists(path):
        return
    subprocess.run(["chmod", "-R", "u+w", str(path)], check=False)
    shutil.rmtree(path, ignore_errors=True)


def find_unshield():
    found = shutil.which("unshield")
    if found:
        return found
    for place in UNSHIELD_PLACES:
        if os.access(place, os.X_OK):
            return place
    die("unshield was not found. It unpacks the disc's installer cabinets and is not installed by this script: "
        "run `brew install unshield` (Homebrew), then run this again.")


def free_gib(path):
    return shutil.disk_usage(path).free / (1 << 30)


def program_sources(program_dir, manifest):
    """{dest: source} for the manifest's five generated program files."""
    pdir = Path(program_dir)
    sources = {}
    for entry in manifest.get("program", []):
        dest = entry["dest"]
        leaf = dest.rsplit("/", 1)[-1]
        cands = [pdir / dest, pdir / leaf, pdir / "Plug Ins" / leaf,
                 REPO / "native/run/game" / dest]
        if leaf.endswith(".exe"):
            cands.insert(0, pdir / (leaf[:-4] + "-decrypted.exe"))
        src = next((c for c in cands if c.is_file()), None)
        if src is not None:
            sources[dest] = src
    return sources


def generate_program(game_stage, manifest, program_dir):
    """Write the program files into the staged game folder; returns the bytes written."""
    sources = program_sources(program_dir, manifest)
    total = 0
    for entry in manifest.get("program", []):
        src = sources.get(entry["dest"])
        if src is None:
            die("the program file for %s was not found in %s (the app generates the program from the "
                "files the build was made from; they are not in this repository)" % (entry["dest"], program_dir))
        size, digest = copy_hashed(src, game_stage / entry["dest"])
        if size != entry["size"] or digest != entry["sha256"]:
            die("%s in %s is not the program file the manifest names" % (src, program_dir))
        total += size
    return total


# ---- --check

def check_folder(root, manifest, quick=False):
    root = Path(root)
    if not root.is_dir():
        die("%s is not a folder" % root)
    ok = 0
    missing, changed, allowed = [], [], []
    entries = [(e, False) for e in manifest["files"]] + [(e, True) for e in manifest.get("program", [])]
    for entry, is_program in entries:
        p = root / entry["dest"]
        if not p.is_file():
            if entry.get("optional"):
                ok += 1
                continue
            missing.append(entry["dest"])
            continue
        if quick:
            ok += 1
            continue
        good = (p.stat().st_size == entry["size"] and sha256_file(p) == entry["sha256"]) if is_program \
            else accepts(entry, p.stat().st_size, sha256_file(p))
        if good:
            ok += 1
        elif entry.get("mutable"):
            allowed.append(entry["dest"])
        else:
            changed.append(entry["dest"])
    total = len(entries)
    print("%s: %d of %d files as the manifest says" % (root, ok, total))
    if allowed:
        print("  %d differ and are allowed to (the game seems to write to them): %s" % (len(allowed), ", ".join(allowed)))
    for what, items in (("missing", missing), ("changed", changed)):
        if items:
            print("  %d %s:" % (len(items), what))
            for item in items[:20]:
                print("    " + item)
            if len(items) > 20:
                print("    ... and %d more" % (len(items) - 20))
    return not missing and not changed


# ---- finding files in an installed copy

class FolderIndex:
    """A manifest file inside an installed copy: at its own path, where a real installation
    puts it (Data/ for some meshes the game folder keeps under Data/Misc/), or by name."""

    def __init__(self, root):
        self.by_path = {}
        self.by_name = {}
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                p = Path(dirpath) / name
                rel = p.relative_to(root).as_posix()
                self.by_path[rel.lower()] = p
                self.by_name.setdefault(name.lower(), []).append(p)

    def find(self, entry):
        hit = self.by_path.get(entry["dest"].lower())
        if hit:
            return hit
        if entry["dest"].startswith("Data/Misc/"):
            hit = self.by_path.get(("Data/" + entry["dest"][len("Data/Misc/"):]).lower())
            if hit:
                return hit
        cands = self.by_name.get(entry["dest"].rsplit("/", 1)[-1].lower(), [])
        if len(cands) == 1:
            return cands[0]
        for cand in cands:
            if accepts(entry, cand.stat().st_size, sha256_file(cand)):
                return cand
        return cands[0] if cands else None


# ---- the import

def load_prepare_disc():
    spec = importlib.util.spec_from_file_location("prepare_disc", PREPARE_DISC)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_game(find, manifest, game_stage, what="Black & White", made_hashes=None):
    """Build the staged game folder's content files through find(entry) -> source path;
    returns total bytes, or None (with the staged folder removed) when the copy is refused."""
    missing, wrong = [], []
    total = 0
    for entry in manifest["files"]:
        src = find(entry)
        if src is None or not Path(src).is_file():
            if not entry.get("optional"):
                missing.append(entry["dest"])
            continue
        size, digest = copy_hashed(src, game_stage / entry["dest"])
        if made_hashes is not None:
            made_hashes[entry["dest"]] = (size, digest)
        total += size
        if not accepts(entry, size, digest):
            wrong.append(entry["dest"])
    if missing or wrong:
        print("import-game: that doesn't look like a complete copy of %s." % what, file=sys.stderr)
        for label, items in (("not found", missing), ("not the game's files", wrong)):
            if items:
                print("  %d %s:" % (len(items), label), file=sys.stderr)
                for item in items[:15]:
                    print("    " + item, file=sys.stderr)
                if len(items) > 15:
                    print("    ... and %d more" % (len(items) - 15), file=sys.stderr)
        print("  Any complete copy of the game works: the original disc, a patched copy, or another "
              "language edition. Nothing was set up.", file=sys.stderr)
        remove_tree(game_stage)
        return None
    return total


def detect_version(folder, manifest, made_hashes):
    """Which version of the game a copy that passed the checks is: an installed copy's own
    program file says so when it is a known one; otherwise the form of Scripts/info.dat
    does (the file each patch rewrote). The original game is the answer when neither speaks."""
    if folder is not None:
        program = Path(folder) / "runblack.exe"
        if program.is_file():
            version = FOLDER_PROGRAM_VERSIONS.get(sha256_file(program))
            if version:
                return version
    for entry in manifest["files"]:
        if entry["dest"] == "Scripts/info.dat" and entry["dest"] in made_hashes:
            _size, digest = made_hashes[entry["dest"]]
            if digest == entry["sha256"]:
                return "100"
            if any(digest == v["sha256"] for v in entry.get("variants", [])):
                return "142"
    return "100"


def write_settings(dest, version):
    """settings.conf in dest: the game and disc folders, and which version was set up."""
    dest = Path(dest)
    wanted = {"GAME_DIR": str(dest / "Game"), "DISC_DIR": str(dest / "Disc"), "GAME_VERSION": version}
    path = dest / "settings.conf"
    lines = path.read_text().splitlines() if path.is_file() else []
    seen = set()
    out = []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in wanted:
            out.append("%s=%s" % (key, wanted[key]))
            seen.add(key)
        else:
            out.append(line)
    if not out or not out[0].startswith("#"):
        out.insert(0, "# Black & White settings (written when your disc was added).")
    for key, value in wanted.items():
        if key not in seen:
            out.append("%s=%s" % (key, value))
    path.write_text("\n".join(out) + "\n")


def place(dest, game_stage, disc_stage, volume_text, marker_text, total, count):
    game, disc = dest / "Game", dest / "Disc"
    if game.exists():
        remove_tree(game)
    game_stage.rename(game)
    if disc_stage is not None:
        if disc.exists():
            remove_tree(disc)
        disc_stage.rename(disc)
    elif not disc.exists():
        disc.mkdir(parents=True)
    (dest / "Disc.volume").write_text(volume_text)
    (dest / "Game.imported").write_text(marker_text)
    print("done: %d files, %.0f MiB in %s" % (count, total / (1 << 20), game))
    print("      disc copy %s (label file %s)" % (disc, dest / "Disc.volume"))
    return 0


def import_image(iso, dest, replace, keep_temp, min_free, program_dir):
    manifest = load_manifest()
    iso = Path(iso).expanduser()
    if not iso.is_file():
        die("no disc image at %s" % iso)
    if not PREPARE_DISC.is_file():
        die("%s is missing" % PREPARE_DISC)
    unshield = find_unshield()

    prepare = load_prepare_disc()
    pvd = prepare.read_pvd(iso)  # exits with a message if this is not an ISO 9660 image
    if pvd["label"] == "BNWCI":
        return import_ci_image(iso, dest, program_dir)

    dest = Path(dest).expanduser()
    game, disc = dest / "Game", dest / "Disc"
    if game.exists() and not replace:
        die("%s exists already; run again with --replace to build it afresh (or --check %s to see how it stands)" % (game, game))
    dest.mkdir(parents=True, exist_ok=True)
    need = iso.stat().st_size / (1 << 30) + SCRATCH_GIB
    left = free_gib(dest) - need
    if left < min_free:
        die("not enough disk: this needs about %.1f GiB while it runs and would leave %.1f GiB free (the limit is %d GiB)"
            % (need, left, min_free))

    print("1/4 disc copy: %s -> %s" % (iso, disc))
    argv = [sys.executable, str(PREPARE_DISC), "--image", str(iso), "--out", str(disc)]
    if replace:
        argv.append("--force")
    r = subprocess.run(argv)
    if r.returncode != 0 or not (disc / "data1.cab").is_file():
        remove_tree(disc)
        try:
            os.remove(str(disc) + ".volume")
        except OSError:
            pass
        die("the disc copy could not be made (see above)")

    return finish_disc_import(dest, disc, unshield, manifest, program_dir, keep_temp,
                              _volume_value(dest / "Disc.volume", "image_sha256"), pvd["label"])


def import_disc_folder(folder, dest, replace, keep_temp, min_free, program_dir):
    manifest = load_manifest()
    folder = Path(folder).expanduser()
    cab = next((p for p in folder.iterdir() if p.name.lower() == "data1.cab"), None) if folder.is_dir() else None
    if cab is None:
        die("%s is not a copy of the Black & White disc: it has no data1.cab at the top" % folder)
    unshield = find_unshield()
    if cab_is_creature_isle(cab, unshield):
        return import_ci_disc_folder(folder, dest, program_dir)
    dest = Path(dest).expanduser()
    game, disc = dest / "Game", dest / "Disc"
    if game.exists() and not replace:
        die("%s exists already; run again with --replace to build it afresh" % game)
    dest.mkdir(parents=True, exist_ok=True)
    left = free_gib(dest) - SCRATCH_GIB
    if left < min_free:
        die("not enough disk: this would leave %.1f GiB free (the limit is %d GiB)" % (left, min_free))
    print("1/4 disc copy: %s -> %s" % (folder, disc))
    if disc.exists():
        remove_tree(disc)
    shutil.copytree(folder, disc)
    (dest / "Disc.volume").write_text("label=BNW\nfs=CDFS\nserial=%08X\nsectors=0\nimage_size=0\nimage_sha256=\n"
                                      % zlib.crc32(b"BNW"))
    return finish_disc_import(dest, disc, unshield, manifest, program_dir, keep_temp, "", "BNW")


def finish_disc_import(dest, disc, unshield, manifest, program_dir, keep_temp, image_hash, label):
    scratch = dest / ".import-scratch"
    remove_tree(scratch)
    scratch.mkdir()
    cab = scratch / "cab"
    print("2/4 unpacking the installer cabinets with %s" % unshield)
    with open(scratch / "unshield.log", "w") as log:
        r = subprocess.run([unshield, "-d", str(cab), "x", str(disc / "data1.cab")], stdout=log, stderr=subprocess.STDOUT)
    if r.returncode != 0 or not cab.is_dir():
        tail = (scratch / "unshield.log").read_text().splitlines()[-5:]
        die("unshield failed (exit %d); its last lines:\n  %s\n(the scratch folder %s was kept)" % (r.returncode, "\n  ".join(tail), scratch))

    partial = dest / "Game.partial"
    remove_tree(partial)
    print("3/4 building the game folder (%d files)" % len(manifest["files"]))

    def find(entry):
        return (cab if entry["from"] == "cab" else disc) / entry["src"]

    made = {}
    total = build_game(find, manifest, partial, made_hashes=made)
    if total is None:
        print("  (the disc copy in %s is fine and was kept; the scratch folder %s was kept)" % (disc, scratch), file=sys.stderr)
        return 1
    version, program_bytes = generate_for_version(partial, manifest, made, None, program_dir)
    total += program_bytes
    print("    version: %s (program generated from %s)" % (version, program_dir or PROGRAM_DIRS[version]))
    print("4/4 putting the folder in place")
    marker = "image_sha256=%s\nlabel=%s\nfiles=%d\nbytes=%d\n" % (image_hash, label, len(manifest["files"]), total)
    result = place(dest, partial, None, _volume_text(dest), marker, total, len(manifest["files"]))
    if not keep_temp:
        remove_tree(scratch)
    if result == 0:
        write_settings(dest, version)
    return result


def generate_for_version(game_stage, manifest, made_hashes, folder, program_override):
    """Generate the version's program into the staged folder; returns (version, bytes)."""
    version = detect_version(folder, manifest, made_hashes)
    total = generate_program(game_stage, load_manifest(version),
                             program_override or PROGRAM_DIRS[version])
    return version, total


def _volume_text(dest):
    existing = dest / "Disc.volume"
    if existing.is_file():
        return existing.read_text()
    return "label=BNW\nfs=CDFS\nserial=%08X\nsectors=0\nimage_size=0\nimage_sha256=\n" % zlib.crc32(b"BNW")


def import_folder(folder, dest, replace, min_free, program_dir, route_ci=True):
    manifest = load_manifest()
    folder = Path(folder).expanduser()
    if not (folder / "Data").is_dir() or not (folder / "Scripts").is_dir():
        die("%s is not an installed copy of Black & White: it has no Data and Scripts folders" % folder)
    if route_ci and (folder / "CreatureIsle.exe").is_file():
        return import_ci_folder(folder, dest, replace, min_free, program_dir)
    dest = Path(dest).expanduser()
    game = dest / "Game"
    if game.exists() and not replace:
        die("%s exists already; run again with --replace to build it afresh" % game)
    dest.mkdir(parents=True, exist_ok=True)
    left = free_gib(dest) - SCRATCH_GIB
    if left < min_free:
        die("not enough disk: this would leave %.1f GiB free (the limit is %d GiB)" % (left, min_free))
    print("1/2 building the game folder from %s (%d files)" % (folder, len(manifest["files"])))
    index = FolderIndex(folder)
    partial = dest / "Game.partial"
    remove_tree(partial)
    made = {}
    total = build_game(index.find, manifest, partial, made_hashes=made)
    if total is None:
        return 1
    version, program_bytes = generate_for_version(partial, manifest, made, folder, program_dir)
    total += program_bytes
    print("    version: %s (program generated from %s)" % (version, program_dir or PROGRAM_DIRS[version]))
    print("2/2 putting the folder in place")
    volume = "label=BNW\nfs=CDFS\nserial=%08X\nsectors=0\nimage_size=0\nimage_sha256=\n" % zlib.crc32(str(folder).encode())
    marker = "image_sha256=\nlabel=BNW\nfiles=%d\nbytes=%d\n" % (len(manifest["files"]), total)
    # An installed copy brings no disc: an empty disc copy with the right label is all
    # the game's disc check asks for.
    disc_stage = dest / ".Disc.partial"
    remove_tree(disc_stage)
    disc_stage.mkdir()
    result = place(dest, partial, disc_stage, volume, marker, total, len(manifest["files"]))
    if result == 0:
        write_settings(dest, version)
    return result


# ---- Creature Isle, over a set-up base game

def cab_is_creature_isle(cab_file, unshield):
    """Whether an installer cabinet is the expansion's: its file groups are named in its listing."""
    r = subprocess.run([unshield, "l", str(cab_file)], capture_output=True, text=True)
    return "CreatureIsles\\" in r.stdout or "CreatureIsles/" in r.stdout


def finish_ci_import(dest, find, disc_stage, label, serial, image_hash, program_dir, keep_temp=False):
    """Lay the expansion's files over a copy of the set-up game folder, generate its
    program, and put both in place. disc_stage is a staged disc copy, or None for an
    empty one carrying the expansion's label."""
    dest = Path(dest).expanduser()
    if not (dest / "Game").is_dir():
        die("Creature Isle is played over the base game: set Black & White up first, then add Creature Isle")
    manifest = load_manifest("ci")
    partial = dest / "Game.partial"
    remove_tree(partial)
    shutil.copytree(dest / "Game", partial)
    print("building Creature Isle over the game folder (%d files)" % len(manifest["files"]))
    total = build_game(find, manifest, partial, "Creature Isle")
    if total is None:
        return 1
    total += generate_program(partial, manifest, program_dir or PROGRAM_DIRS["ci"])
    if disc_stage is None:
        disc_stage = dest / ".Disc.partial"
        remove_tree(disc_stage)
        disc_stage.mkdir()
    volume = "label=%s\nfs=CDFS\nserial=%08X\nsectors=0\nimage_size=0\nimage_sha256=%s\n" % (label, serial, image_hash)
    marker = "image_sha256=%s\nlabel=%s\nfiles=%d\nbytes=%d\n" % (image_hash, label, len(manifest["files"]), total)
    result = place(dest, partial, disc_stage, volume, marker, total, len(manifest["files"]))
    if result == 0:
        write_settings(dest, "ci")
    return result


def import_ci_image(iso, dest, program_dir):
    iso = Path(iso).expanduser()
    unshield = find_unshield()
    prepare = load_prepare_disc()
    pvd = prepare.read_pvd(iso)
    dest = Path(dest).expanduser()
    if not (dest / "Game").is_dir():
        die("Creature Isle is played over the base game: set Black & White up first, then add Creature Isle")
    stage = dest / ".Disc.partial"
    remove_tree(stage)
    r = subprocess.run([sys.executable, str(PREPARE_DISC), "--image", str(iso), "--out", str(stage), "--force"])
    if r.returncode != 0 or not (stage / "data1.cab").is_file():
        remove_tree(stage)
        die("the disc copy could not be made (see above)")
    image_hash = _volume_value(str(stage) + ".volume", "image_sha256")
    remove_tree(str(stage) + ".volume")
    scratch = dest / ".import-scratch"
    remove_tree(scratch)
    scratch.mkdir()
    cab = scratch / "cab"
    print("unpacking the expansion's installer cabinets with %s" % unshield)
    with open(scratch / "unshield.log", "w") as log:
        r = subprocess.run([unshield, "-d", str(cab), "x", str(stage / "data1.cab")],
                           stdout=log, stderr=subprocess.STDOUT)
    if r.returncode != 0 or not cab.is_dir():
        die("unshield failed (exit %d); the scratch folder %s was kept" % (r.returncode, scratch))
    result = finish_ci_import(dest, lambda e: cab / e["src"], stage, pvd["label"],
                              zlib.crc32(b"BNWCI"), image_hash, program_dir)
    remove_tree(scratch)
    return result


def import_ci_disc_folder(folder, dest, program_dir):
    folder = Path(folder).expanduser()
    unshield = find_unshield()
    dest = Path(dest).expanduser()
    if not (dest / "Game").is_dir():
        die("Creature Isle is played over the base game: set Black & White up first, then add Creature Isle")
    stage = dest / ".Disc.partial"
    remove_tree(stage)
    shutil.copytree(folder, stage)
    scratch = dest / ".import-scratch"
    remove_tree(scratch)
    scratch.mkdir()
    cab = scratch / "cab"
    print("unpacking the expansion's installer cabinets with %s" % unshield)
    with open(scratch / "unshield.log", "w") as log:
        r = subprocess.run([unshield, "-d", str(cab), "x", str(stage / "data1.cab")],
                           stdout=log, stderr=subprocess.STDOUT)
    if r.returncode != 0 or not cab.is_dir():
        die("unshield failed (exit %d); the scratch folder %s was kept" % (r.returncode, scratch))
    result = finish_ci_import(dest, lambda e: cab / e["src"], stage, "BNWCI",
                              zlib.crc32(b"BNWCI"), "", program_dir)
    remove_tree(scratch)
    return result


def import_ci_folder(folder, dest, replace, min_free, program_dir):
    """Creature Isle from a folder the expansion is installed in. Such a folder holds the
    base game as well, so when the base game is not set up yet it is set up from the same
    folder first."""
    folder = Path(folder).expanduser()
    dest = Path(dest).expanduser()
    if not (dest / "Game").is_dir():
        result = import_folder(folder, dest, replace, min_free, program_dir, route_ci=False)
        if result != 0:
            return result
    return finish_ci_import(dest, FolderIndex(folder).find, None, "BNWCI",
                            zlib.crc32(str(folder).encode()), "", program_dir)


def _volume_value(path, key):
    try:
        for line in Path(path).read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iso", help="your Black & White disc image (a Creature Isle image adds the expansion)")
    ap.add_argument("--disc", help="a folder that is a copy of the disc (data1.cab at the top; "
                                   "a Creature Isle copy adds the expansion)")
    ap.add_argument("--folder", help="an installed copy of the game (the folder holding Data and Scripts)")
    ap.add_argument("--ci-folder", help="an installed copy of Creature Isle, added explicitly")
    ap.add_argument("--dest", default=str(DEFAULT_DEST), help="where Game, Disc and Disc.volume go")
    ap.add_argument("--replace", action="store_true", help="replace an earlier import")
    ap.add_argument("--keep-scratch", action="store_true", help="keep the folder of unpacked cabinets")
    ap.add_argument("--min-free-gb", type=int, default=15, help="free disk to leave (default 15)")
    ap.add_argument("--program-dir",
                    help="the folder the program files were lifted from (default: each version's own)")
    ap.add_argument("--check", metavar="GAME_FOLDER", help="check a game folder against the manifest; changes nothing")
    ap.add_argument("--version", choices=("100", "142", "ci"), default="100",
                    help="with --check: which version's manifest to check against (ci checks both)")
    ap.add_argument("--quick", action="store_true", help="with --check: compare sizes only")
    args = ap.parse_args()
    if args.check:
        if args.version == "ci":
            ok = check_folder(args.check, load_manifest("100"), args.quick)
            return 0 if check_folder(args.check, load_manifest("ci"), args.quick) and ok else 1
        return 0 if check_folder(args.check, load_manifest(args.version), args.quick) else 1
    if args.iso:
        return import_image(args.iso, args.dest, args.replace, args.keep_scratch, args.min_free_gb, args.program_dir)
    if args.disc:
        return import_disc_folder(args.disc, args.dest, args.replace, args.keep_scratch, args.min_free_gb, args.program_dir)
    if args.ci_folder:
        return import_ci_folder(args.ci_folder, args.dest, args.replace, args.min_free_gb, args.program_dir)
    if args.folder:
        return import_folder(args.folder, args.dest, args.replace, args.min_free_gb, args.program_dir)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
