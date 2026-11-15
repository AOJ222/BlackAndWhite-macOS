#!/bin/bash
# Check the "Black & White Settings" app against the launcher, without the game and without a window:
# the app's own checks, then files the app writes read back by launcher.sh as the app meant, and
# a file from an earlier build kept working (and keeping its other keys) through a save.
# Everything happens in a scratch folder; the player's settings and logs are not touched.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/../launcher.sh"
SOURCE="$HERE/../settings/BlackWhiteSettings.swift"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bw-settings-app.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SUPPORT="$WORK/support"
LOGS="$WORK/logs"
BUNDLE="$WORK/fake-bundle"
mkdir -p "$SUPPORT" "$LOGS" "$BUNDLE/Contents/Resources"
touch "$BUNDLE/Contents/Resources/defaults.conf"

failures=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { # check DESCRIPTION EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        wanted: %s\n        got:    %s\n' "$2" "$3"; fi
}

if [ -n "${BW_SETTINGS_BIN:-}" ]; then
  APP="$BW_SETTINGS_BIN"
else
  APP="$WORK/BlackWhiteSettings"
  printf 'compiling %s ...\n' "$SOURCE"
  swiftc -O -parse-as-library -target arm64-apple-macos13.0 "$SOURCE" -o "$APP" || { echo "compile failed"; exit 1; }
fi

export BW_APP_SUPPORT_DIR="$SUPPORT"
export BW_APP_LOGS_DIR="$LOGS"
# The launcher works out the automatic sharpness from the display's density; the checks below are
# made as on a plain display (1) unless one says Retina (2).
export BW_APP_DISPLAY_DENSITY=1

echo
echo "== the app's own checks =="
"$APP" --selftest >"$WORK/selftest.txt" 2>&1
selftest_status=$?
tail -n 3 "$WORK/selftest.txt"
check "the app's own checks pass" 0 "$selftest_status"

# What the launcher works out from the file as it stands: RESOLUTION, scale, picture.
launcher_says() {
  BW_APP_NO_DIALOG=1 BW_APP_PRINT_SETTINGS=1 BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" "$@" bash "$LAUNCHER" 2>&1 |
    awk -F= '{ v[$1] = $2 } END { printf "%s scale=%s picture=%s", v["RESOLUTION"], v["BW_RENDER_SCALE"], v["PICTURE"] }'
}
launcher_says_with() { # launcher_says_with DISPLAY_POINTS
  BW_APP_NO_DIALOG=1 BW_APP_PRINT_SETTINGS=1 BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" BW_APP_DISPLAY_POINTS="$1" \
    bash "$LAUNCHER" 2>&1 |
    awk -F= '{ v[$1] = $2 } END { printf "%s scale=%s picture=%s", v["RESOLUTION"], v["BW_RENDER_SCALE"], v["PICTURE"] }'
}

echo
echo "== a file from an earlier build, saved by the app =="
cat >"$SUPPORT/settings.conf" <<'TEXT'
# an earlier build's file
SCREEN_MODE=desktop
RESOLUTION=1280x800
PICTURE=4k
GAME_DIR=/somewhere/Game
DISC_DIR=/somewhere/Disc
POINTER=virtual
QUIT_GRACE_MS=5000
AUDIO=device
TEXT
before="$(launcher_says)"
check "the launcher reads the earlier file as 4k at a scale of 2" "1920x1080 scale=2 picture=4k" "$before"
"$APP" --print >"$WORK/print.txt" 2>&1
check "the app reads the same picture" "1920x1080 sharpness=2" \
  "$(awk -F= '$1 == "resolution" { r = $2 } $1 == "sharpness" { s = $2 } END { print r " sharpness=" s }' "$WORK/print.txt")"
"$APP" --set fps=30 >/dev/null 2>&1
after="$(launcher_says)"
check "after a save the launcher works out the same picture size and scale" \
  "1920x1080 scale=2 picture=classic" "$after"
conf_value() { awk -F= -v k="$1" '$1 == k { v = $2 } END { print v }' "$SUPPORT/settings.conf"; }
check "the screen mode is kept" "desktop" "$(conf_value SCREEN_MODE)"
check "the frame cap is the new one" "30" "$(conf_value FPS_CAP)"
check "GAME_DIR is kept" "/somewhere/Game" "$(conf_value GAME_DIR)"
check "DISC_DIR is kept" "/somewhere/Disc" "$(conf_value DISC_DIR)"
check "POINTER is kept" "virtual" "$(conf_value POINTER)"
check "QUIT_GRACE_MS is kept" "5000" "$(conf_value QUIT_GRACE_MS)"
if [ -f "$SUPPORT/settings.conf.previous" ] && grep -q '^PICTURE=4k' "$SUPPORT/settings.conf.previous"; then
  ok "the file as it was is kept as settings.conf.previous"
else
  bad "the file as it was is kept as settings.conf.previous"
fi

echo
echo "== choices the app writes, read by the launcher =="
rm -f "$SUPPORT/settings.conf" "$SUPPORT/settings.conf.previous"
"$APP" --set >/dev/null 2>&1
check "no choices written: the standard picture, Automatic, on a plain display" "1280x800 scale= picture=classic" "$(launcher_says)"
check "the same file on a Retina display: Automatic is 2" "1280x800 scale=2 picture=classic" \
  "$(BW_APP_DISPLAY_DENSITY=2 launcher_says)"

"$APP" --set resolution=1920x1080 sharpness=auto >/dev/null 2>&1
check "1920x1080 at Automatic on a Retina display is drawn at a scale of 2 (4K)" "1920x1080 scale=2 picture=classic" \
  "$(BW_APP_DISPLAY_DENSITY=2 launcher_says)"
check "... and at a scale of 1 on a plain display" "1920x1080 scale= picture=classic" "$(launcher_says)"

"$APP" --set resolution=1920x1200 sharpness=2 >/dev/null 2>&1
check "1920x1200, sharpness 2" "1920x1200 scale=2 picture=classic" "$(launcher_says)"

"$APP" --set resolution=1280x720 sharpness=1 >/dev/null 2>&1
check "1280x720, sharpness 1 (written as 1, so Retina does not make it Automatic)" "1280x720 scale=1 picture=classic" \
  "$(BW_APP_DISPLAY_DENSITY=2 launcher_says)"

"$APP" --set resolution=native sharpness=2 >/dev/null 2>&1
check "this Mac's display, sharpness 2 (a 1728x1117 display)" \
  "1728x1116 scale=2 picture=native" "$(launcher_says_with 1728x1117)"

"$APP" --set resolution=native sharpness=1 >/dev/null 2>&1
check "this Mac's display, sharpness 1 (the scale 1 is kept, not turned into 2)" \
  "1728x1116 scale=1 picture=native" "$(launcher_says_with 1728x1117)"

"$APP" --set resolution=1680x1050 sharpness=1.5 >/dev/null 2>&1
check "1680x1050, sharpness 1.5" "1680x1050 scale=1.5 picture=classic" "$(launcher_says)"

echo
echo "== the whole launcher, up to the point of starting the game =="
# A stand-in install: the files the launcher looks for, a disc copy with its .volume file, and an
# "exe" whose checksum is the one the settings give.
GAME="$WORK/Game"
DISC="$WORK/Disc"
mkdir -p "$GAME/Plug Ins" "$DISC"
touch "$GAME/lhlogr.dll" "$GAME/LHaudiodllR.dll" "$GAME/LHMultiplayerR.dll" "$GAME/Plug Ins/ScriptLibraryR.dll"
touch "$DISC.volume"
echo "stand-in program" >"$GAME/runblack.exe"
sum="$(shasum -a 256 "$GAME/runblack.exe" | cut -d' ' -f1)"
cat >"$SUPPORT/settings.conf" <<TEXT
GAME_DIR=$GAME
DISC_DIR=$DISC
EXE_SHA256=$sum
TEXT
"$APP" --set screen=desktop resolution=1920x1200 sharpness=2 fps=0 sound=off >/dev/null 2>&1
rm -rf "$SUPPORT/data"
dry="$(BW_SETTINGS_BIN="$APP" BW_APP_NO_DIALOG=1 BW_APP_DRYRUN=1 BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" bash "$LAUNCHER" 2>&1)"
env_line="$(printf '%s\n' "$dry" | awk '/^environment:/')"
case "$env_line" in
  *BW_FULLSCREEN=desktop*) ok "screen mode reaches the game" ;;
  *) bad "screen mode reaches the game"; printf '        %s\n' "$env_line" ;;
esac
case "$env_line" in
  *BW_AUDIO=off*) ok "sound off reaches the game" ;;
  *) bad "sound off reaches the game"; printf '        %s\n' "$env_line" ;;
esac
case "$env_line" in
  *"BW_FPS_CAP=0"*) ok "no frame limit reaches the game" ;;
  *) bad "no frame limit reaches the game"; printf '        %s\n' "$env_line" ;;
esac
case "$env_line" in
  *"BW_RENDER_SCALE=2"*) ok "sharpness reaches the game" ;;
  *) bad "sharpness reaches the game"; printf '        %s\n' "$env_line" ;;
esac
registry="$SUPPORT/data/bw/registry.txt"
check "the game's registry has the picture width (1920 = 0x780)" "80070000" \
  "$(awk -F'\t' '$1 == "screenw" { print $3; exit }' "$registry")"
check "the game's registry has the picture height (1200 = 0x4b0)" "b0040000" \
  "$(awk -F'\t' '$1 == "screenh" { print $3; exit }' "$registry")"

echo
echo "== the game's own Options screen =="
# The launcher gives the game the Screen and Resolution choices the Settings app lists, and the path
# of the app to apply one with.
menu_line="$(printf '%s\n' "$dry" | awk '/^options menu:/')"
check "the launcher finds the Settings app and the game is given its list (8 sizes, 2 screens, 2 current)" \
  "options menu: $APP (12 lines)" "$menu_line"
none="$(HOME="$WORK/nowhere" BW_SETTINGS_BIN= BW_APP_NO_DIALOG=1 BW_APP_DRYRUN=1 BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" \
  bash "$LAUNCHER" 2>&1 | awk '/^options menu:/')"
check "with no Settings app to be found the game is given no list (its Options screen is the original)" \
  "options menu: none" "$none"
menu="$("$APP" --game-menu 2>/dev/null)"
check "the menu's current Screen is the file's" desktop \
  "$(printf '%s\n' "$menu" | awk -F'\t' '$1 == "current" && $2 == "screen" { print $3 }')"
check "the menu's current Resolution is the file's" 1920x1200 \
  "$(printf '%s\n' "$menu" | awk -F'\t' '$1 == "current" && $2 == "resolution" { print $3 }')"
check "the menu names 1920x1200 by what is drawn, as the window does" "3840 x 2400" \
  "$(printf '%s\n' "$menu" | awk -F'\t' '$1 == "resolution" && $2 == "1920x1200" { print $3 }')"
check "every line of the menu is plain ASCII, as the game's font needs" 0 \
  "$(printf '%s\n' "$menu" | LC_ALL=C grep -c -v '^[ -~	]*$')"
"$APP" --set screen=window resolution=1280x720 sharpness=auto >/dev/null 2>&1
check "after a save the menu's current choices are the new ones" "window 1280x720" \
  "$("$APP" --game-menu 2>/dev/null | awk -F'\t' '$1 == "current" { printf "%s%s", sep, $3; sep = " " }')"

# A game that the Settings app opens again for a restart can be handed the values of the game that
# asked for it. They describe the settings that game started with, so the launcher works them out
# afresh at each start and the Settings app does not pass them on.
stale_env=(BW_DISPLAY_MENU=$'current\tscreen\tdesktop' BW_SETTINGS_TOOL=/old/tool BW_SETTINGS_GAME_APP=/old/app)
stale="$(env "${stale_env[@]}" BW_SETTINGS_BIN="$APP" BW_APP_NO_DIALOG=1 BW_APP_DRYRUN=1 BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" \
  bash "$LAUNCHER" 2>&1 | awk '/^options menu:/')"
check "a menu left in the environment by an earlier game is worked out again, not kept" \
  "options menu: $APP (12 lines)" "$stale"
stale_none="$(env "${stale_env[@]}" HOME="$WORK/nowhere" BW_SETTINGS_BIN= BW_APP_NO_DIALOG=1 BW_APP_DRYRUN=1 \
  BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" bash "$LAUNCHER" 2>&1 | awk '/^options menu:/')"
check "and when no Settings app is found it is dropped, not kept" "options menu: none" "$stale_none"

# A stand-in game app that writes its environment to a file when it is started. The Settings app
# opens it for a restart; it must get the test's own switches and none of the launcher's values.
FAKE="$WORK/Stand-in Game.app"
mkdir -p "$FAKE/Contents/MacOS"
cat >"$FAKE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>stand-in</string>
<key>CFBundleIdentifier</key><string>test.blackandwhite.stand-in-game</string>
<key>CFBundleName</key><string>Stand-in Game</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
printf '#!/bin/bash\nenv | sort > "%s/stand-in-env.txt"\n' "$WORK" >"$FAKE/Contents/MacOS/stand-in"
chmod +x "$FAKE/Contents/MacOS/stand-in"
if /usr/bin/codesign --force --sign - "$FAKE" >/dev/null 2>&1; then
  env "${stale_env[@]}" BW_SETTINGS_GAME_APP="$FAKE" BW_AUDIO=off BW_RENDER_SCALE=2 BW_FULLSCREEN=desktop \
    BW_FPS_CAP=60 BW_CD_DIR=/old/disc BW_TEST_SWITCH=kept "$APP" --restart-game >/dev/null 2>&1
  check "the restart command opens the game again" 0 "$?"
  for _ in $(seq 1 50); do [ -s "$WORK/stand-in-env.txt" ] && break; sleep 0.2; done
  opened_env="$(cat "$WORK/stand-in-env.txt" 2>/dev/null)"
  check "the game it opens is handed none of the launcher's values" "" \
    "$(printf '%s\n' "$opened_env" | grep -E '^(BW_DISPLAY_MENU|BW_SETTINGS_TOOL|BW_SETTINGS_GAME_APP|BW_AUDIO|BW_RENDER_SCALE|BW_FULLSCREEN|BW_FPS_CAP|BW_CD_DIR)=')"
  check "but it is handed the test's own switches" "BW_TEST_SWITCH=kept" \
    "$(printf '%s\n' "$opened_env" | grep -E '^BW_TEST_SWITCH=')"
else
  bad "the stand-in game app could not be signed, so the restart's environment was not checked"
fi

echo
if [ "$failures" -ne 0 ]; then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
echo "all settings-app checks passed"
