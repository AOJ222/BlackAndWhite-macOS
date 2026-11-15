# Black & White for Mac

A native macOS port of **Black & White** (2001, Lionhead Studios) for Apple silicon. It is
an unofficial fan project.

The download holds none of the game's **content**: the worlds, creatures, sounds, music,
movies and text all come from **your own copy of Black & White**. On first start the app asks
for your copy, reads the game from it, checks every file, and sets itself up. After that it
starts at once and your copy is not needed again. If you do not own the game, this download
cannot do anything for you.

It does hold the game's **program**: the game's executable and program libraries for each
version it supports, and Apple silicon code translated from them. See
[What is in the download](#what-is-in-the-download).

## Download and play

The latest prebuilt release is on the GitHub Releases page.

1. Download the release zip and unzip it.
2. Move `Black & White.app` into Applications (`Black & White Settings.app` too if you want it).
3. Open it. It is not notarised, so on first launch macOS may refuse: System Settings →
   Privacy & Security → **Open Anyway** → **Open**.
4. Add your copy of the game: an `.iso` image of the disc, a folder that is a copy of
   the disc, or the folder the game is already installed in.
   Set-up takes under a minute and about 3 GB.
5. Play. Later starts go straight to the game.

**Requirements:** an Apple silicon Mac running macOS 27, about 3 GB free, and your own copy
of the game. It has been tried on one Mac only: an M2 Pro with 16 GB on macOS 27.2. Other
chips are untried, and so are macOS 27.0 and 27.1 (parts of the app were built for 27.2, so
it may not run there).

**What you need:** your own copy of Black & White in English: the original PC disc as sold,
or a copy patched to 1.10, 1.20 or the unofficial Fan Patch 1.42 (1.10 copies have not been
tried). Other language editions are not supported yet: the import checks the English
voice-over files, so a copy in another language should be refused (not tried).

## How it works

The original game's x86 code is statically recompiled to native Apple silicon code
(`bw_native`) with [SwARc](https://github.com/JTM-rootstorm/SwARc), an open-source
recompiler and runtime by JT (MIT licence) that this port builds on and extends. The
recompiled game runs against replacements for its Windows, DirectDraw/Direct3D 7,
DirectInput, audio and Bink layers, over SDL and Metal: a mixture of SwARc's runtime code
and replacements written for this port (see `native/NOT-ORIGINAL.md`). At run time the only
game files it reads are in `~/Library/Application Support/Black & White`: the game content
imported from your copy, and the game's program files, which the app copies there from
inside itself during set-up (the program files in your copy are never used). That is why
every supported copy works the same way: an unpatched copy plays the original 1.00 build,
and a patched copy (1.10/1.20, the Fan Patch) plays the Fan Patch 1.42 build.

## What is in the download

- **The translated game:** `bw_native` (1.00) and `bw_native_142` (Fan Patch 1.42), the
  game's program translated to Apple silicon code, with the SwARc runtime libraries and the
  open-source libraries listed in `THIRD_PARTY_NOTICES.md`. This code is derived from the
  original game program.
- **The game's program files,** one set per version (`Contents/Resources/ProgramKit` for
  1.00, `ProgramKit-142` for Fan Patch 1.42): the executable `runblack.exe` and four
  program libraries (DLLs). At set-up the app copies the set for your version into your
  game folder. The Fan Patch 1.42 files are those of that unofficial community patch.
- **A manifest for each version:** the name, size and checksum of every file the app expects
  from your copy, used to check it. The manifests contain no game files.
- **Licence texts:** a `Licenses` folder with this project's licence, SwARc's, SoftFloat's
  and those of the libraries above, and a written offer of the source code of FFmpeg, the
  one library in the download under the LGPL.
- **None of the game's worlds, creatures, sounds, music, movies or text.** They are not in
  the download; they come only from your copy.

## Building from source

```
python3 native/app/build-app.py --release --out <folder>
```

This builds the apps from a `bw_native` build (the `bw-native` and `swarc` trees) and
bundles everything the first start needs, including the disc importer. Nothing that
identifies the building Mac (its folders, user name or disc copy) is baked into a
`--release` build. The build does bundle the program files described above, which the
builder supplies from outside this repository. The FFmpeg libraries in the download are an
LGPL-only build of FFmpeg 8.1.2 (`Licenses/SOURCE-OFFER.txt` gives its source and the
configure line); `--ffmpeg-dir <folder>` bundles the libraries of such a build instead of the
ones `bw_native` was linked against, and a `--release` build refuses an FFmpeg built under
the GPL. This repository currently contains the app and importer layer; the separate
`bw-native` and `swarc` source trees are also required for a full build and are not
included here yet. See `native/app/README.md` for the full picture: the launcher, the
settings app, the manifest the game is checked against, and the tests
(`native/app/tests/`).

## Status

- **1.00 build (an unpatched copy):** single-player is playable; Lands 1–5 run, and key
  moments are covered by turn-by-turn parity checks against the original game. The game is
  also checked by hand during development. A full start-to-finish campaign run is the
  current testing focus.
- **Fan Patch 1.42 build (patched copies):** new in 0.3.0. Set-up from 1.20 and Fan Patch
  1.42 copies has been run, and both started and played the intro. The turn-by-turn checks
  have not been run on this build, and 1.10 copies have not been tried.
- Creature Isle, the expansion, is not supported yet.
- Sound and the opening movies run; so far they have been checked by programs only, not by
  ear and eye. Networking (LAN multiplayer) does not work.
- The Settings app and the game's own Options screen change picture size and frame rate.
  The Options screen also has Sound and Master Volume rows; the Settings app's window has
  no volume row.
- Tried on one Mac only (see Requirements).
- Known limits are listed in `native/app/README.md` and `native/NOT-ORIGINAL.md`.

## Legal note

Black & White is a trademark of its respective owners. This is an unofficial fan port,
not affiliated with or endorsed by those owners. This repository holds no game data,
artwork or game executable. The downloadable app does hold the game's program files and
code translated from them (see [What is in the download](#what-is-in-the-download)), but
the game's worlds, creatures, sounds, music, movies and text on your Mac come only from
your own copy of the game.

This is a non-commercial fan project. It is free to download, it does not accept
donations, sponsorship or payment of any kind, and nothing in it is for sale.

The MIT licence (see `LICENSE`) covers original code written for this project only. It
does not cover the original game, the game's program files, code derived from them,
SwARc or the other third-party components, which keep their own terms. Please read
`NOTICE.md` and `THIRD_PARTY_NOTICES.md`, and do not upload game files or other
copyrighted material to this project. This is a description of what the download
contains, not legal advice.

## Credits and thanks

- **Lionhead Studios** made Black & White. This port exists because the original game is
  worth keeping playable.
- **[SwARc](https://github.com/JTM-rootstorm/SwARc)** by JT — the static recompiler and
  runtime this port is built on. The translated game (`bw_native`) is its output, and the
  layers the game runs against are built on its runtime. Released under the MIT licence.
- **[openblack](https://github.com/openblack/openblack)** — the open-source engine
  project whose years of work documenting the game's file formats (meshes, landscapes,
  animations, script bytecode) this project learned a great deal from.
- **[bw1-decomp](https://github.com/openblack/bw1-decomp)** — the matching
  decompilation of the original executables. Its recovered source was an essential
  reference for how the original game actually behaves.
- **The Black & White community** — the modders and archivists of
  [bwgame.net](https://www.bwgame.net) and Planet Black & White, including Daniels118's
  challenge-script tools and the decompiled challenge sources shared there, and the
  **[StrategyWiki](https://strategywiki.org/wiki/Black_%26_White)** guide contributors,
  whose controls guide served as a checklist for this port's input work.
- The open-source libraries bundled with the app are credited in `THIRD_PARTY_NOTICES.md`,
  which names the licence each one is under; their licence texts are in the download's
  `Licenses` folder.

Thank you all. Standing on this work is what made a port like this possible; any
mistakes in it are this project's own. (Acknowledgement is not a licence statement:
for what is actually bundled and under what terms, see `THIRD_PARTY_NOTICES.md`.)
