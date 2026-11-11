#!/bin/bash
# Exercise the front door (the app's first start) without the game: its own checks, its
# reading of a disc, and its refusal of things that are not the supported disc.
#
#   native/app/tests/frontdoor.sh                 self-test and refusal cases
#   BW_TEST_ISO=~/Downloads/BNW.iso native/app/tests/frontdoor.sh
#                                                 and a full import of that image into a
#                                                 scratch folder, checked with import-game.py
#   BW_TEST_FOLDER_142=<installed 1.42 folder>    and an import of that installed copy,
#                                                 which must come out as Fan Patch 1.42
#   BW_TEST_CI_DISC=<Creature Isle disc folder>   and, after the BW_TEST_ISO import,
#                                                 that the expansion is refused for now
#                                                 and the base game stays set up
#
# Everything happens in a scratch folder that is removed at the end. No game is started.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bw-frontdoor-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bundle/Resources" "$WORK/support"
cp "$HERE/game-manifest.json" "$HERE/game-manifest-142.json" "$HERE/game-manifest-ci.json" \
  "$WORK/bundle/Resources/"

# The program files the app generates each version's program from, staged from this Mac's
# own build inputs when they are at hand (they are never files of the repository).
KIT="$WORK/bundle/Resources/ProgramKit"
PROG="$HERE/../../bw1-decomp/orig/BW1W100"
if [ -f "$PROG/runblack-decrypted.exe" ]; then
  mkdir -p "$KIT"
  cp "$PROG/runblack-decrypted.exe" "$KIT/runblack.exe"
  cp "$PROG/lhlogr.dll" "$PROG/LHaudiodllR.dll" "$PROG/LHMultiplayerR.dll" "$KIT/"
  cp "$HERE/../../native/run/game/Plug Ins/ScriptLibraryR.dll" "$KIT/"
fi
KIT142="$WORK/bundle/Resources/ProgramKit-142"
PROG142="$HERE/../../toolkit-trial/bw-1.42"
if [ -f "$PROG142/runblack.exe" ]; then
  mkdir -p "$KIT142"
  cp "$PROG142/runblack.exe" "$PROG142/LHLogR.dll" "$PROG142/LHaudiodllR.dll" \
    "$PROG142/LHMultiplayerR.dll" "$KIT142/"
  cp "$PROG142/Plug Ins/ScriptLibraryR.dll" "$KIT142/"
fi
KITCI="$WORK/bundle/Resources/ProgramKit-CI"
PROGCI="$HERE/../../bw1-decomp/orig/BW1WCI"
if [ -f "$PROGCI/CreatureIsle-decrypted.exe" ]; then
  mkdir -p "$KITCI"
  cp "$PROGCI/CreatureIsle-decrypted.exe" "$KITCI/CreatureIsle.exe"
  cp "$PROGCI/LHLogR.dll" "$PROGCI/LHaudiodllR.dll" "$PROGCI/LHMultiplayerR.dll" \
    "$PROGCI/ScriptLibraryR.dll" "$KITCI/"
fi

BIN="$WORK/BlackWhite"
echo "== building the front door =="
/usr/bin/swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  "$HERE/frontdoor/BlackWhiteFrontDoor.swift" -o "$BIN" || exit 1

export BW_APP_BUNDLE_ROOT="$WORK/bundle"
export BW_APP_SUPPORT_DIR="$WORK/support"
failures=0

echo "== --selftest =="
"$BIN" --selftest || failures=$((failures + 1))

echo "== --check-setup on an empty folder (must say no) =="
if "$BIN" --check-setup; then
  echo "FAIL: an empty folder counted as set up"
  failures=$((failures + 1))
fi

echo "== a file that is not a disc image (must be refused, nothing left) =="
echo "not a disc" > "$WORK/not-a-disc.iso"
if "$BIN" --import-iso "$WORK/not-a-disc.iso"; then
  echo "FAIL: a text file counted as a disc"
  failures=$((failures + 1))
fi
[ -e "$WORK/support/Game" ] && { echo "FAIL: a refused import left a game folder"; failures=$((failures + 1)); }

echo "== a folder that is not a disc (must be refused) =="
mkdir -p "$WORK/not-a-disc"
if "$BIN" --import-disc "$WORK/not-a-disc"; then
  echo "FAIL: an empty folder counted as a disc"
  failures=$((failures + 1))
fi

echo "== a folder that is not an installed game (must be refused) =="
if "$BIN" --import-folder "$WORK/not-a-disc"; then
  echo "FAIL: an empty folder counted as an installed game"
  failures=$((failures + 1))
fi
[ -e "$WORK/support/Game" ] && { echo "FAIL: a refused import left a game folder"; failures=$((failures + 1)); }

echo "== a folder that is not Creature Isle (must be refused) =="
if "$BIN" --import-ci-folder "$WORK/not-a-disc"; then
  echo "FAIL: an empty folder counted as Creature Isle"
  failures=$((failures + 1))
fi

if [ -n "${BW_TEST_FOLDER_142:-}" ]; then
  echo "== importing the installed 1.42 copy $BW_TEST_FOLDER_142 =="
  "$BIN" --import-folder "$BW_TEST_FOLDER_142" | tail -2 || failures=$((failures + 1))
  "$BIN" --check-setup | grep -q "version:     Fan Patch 1.42" || { echo "FAIL: the 1.42 copy did not come out as Fan Patch 1.42"; failures=$((failures + 1)); }
  python3 "$HERE/import-game.py" --check "$WORK/support/Game" --version 142 --quick || failures=$((failures + 1))
fi

if [ -n "${BW_TEST_ISO:-}" ]; then
  echo "== importing $BW_TEST_ISO =="
  "$BIN" --import-iso "$BW_TEST_ISO" | tail -2 || failures=$((failures + 1))
  "$BIN" --check-setup | tail -1 || failures=$((failures + 1))
  echo "== the imported folder against the manifest =="
  python3 "$HERE/import-game.py" --check "$WORK/support/Game" --quick || failures=$((failures + 1))
  if [ -n "${BW_TEST_CI_DISC:-}" ]; then
    echo "== Creature Isle from $BW_TEST_CI_DISC (refused for now; the base game must stay) =="
    if "$BIN" --import-disc "$BW_TEST_CI_DISC" > /dev/null; then
      echo "FAIL: Creature Isle was accepted"
      failures=$((failures + 1))
    fi
    if "$BIN" --check-setup | grep -q "version:     Creature Isle"; then
      echo "FAIL: the set-up became Creature Isle"
      failures=$((failures + 1))
    fi
    python3 "$HERE/import-game.py" --check "$WORK/support/Game" --quick || failures=$((failures + 1))
  fi
else
  echo "== no BW_TEST_ISO given: the full import was not run =="
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all front-door checks passed"
