#!/bin/bash
# Exercise the front door (the app's first start) without the game: its own checks, its
# reading of a disc, and its refusal of things that are not the supported disc.
#
#   native/app/tests/frontdoor.sh                 self-test and refusal cases
#   BW_TEST_ISO=~/Downloads/BNW.iso native/app/tests/frontdoor.sh
#                                                 and a full import of that image into a
#                                                 scratch folder, checked with import-game.py
#
# Everything happens in a scratch folder that is removed at the end. No game is started.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bw-frontdoor-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bundle/Resources" "$WORK/support"
cp "$HERE/game-manifest.json" "$WORK/bundle/Resources/"

# The program files the app generates the program from, staged from this Mac's own build
# inputs when they are at hand (they are never files of the repository).
KIT="$WORK/bundle/Resources/ProgramKit"
PROG="$HERE/../../bw1-decomp/orig/BW1W100"
if [ -f "$PROG/runblack-decrypted.exe" ]; then
  mkdir -p "$KIT"
  cp "$PROG/runblack-decrypted.exe" "$KIT/runblack.exe"
  cp "$PROG/lhlogr.dll" "$PROG/LHaudiodllR.dll" "$PROG/LHMultiplayerR.dll" "$KIT/"
  cp "$HERE/../../native/run/game/Plug Ins/ScriptLibraryR.dll" "$KIT/"
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

if [ -n "${BW_TEST_ISO:-}" ]; then
  echo "== importing $BW_TEST_ISO =="
  "$BIN" --import-iso "$BW_TEST_ISO" | tail -2 || failures=$((failures + 1))
  "$BIN" --check-setup | tail -1 || failures=$((failures + 1))
  echo "== the imported folder against the manifest =="
  python3 "$HERE/import-game.py" --check "$WORK/support/Game" --quick || failures=$((failures + 1))
else
  echo "== no BW_TEST_ISO given: the full import was not run =="
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all front-door checks passed"
