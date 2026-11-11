#!/bin/bash
# The program inside "Black & White.app" that macOS starts when the app is opened.
#
# It finds the player's own game files, keeps what the game writes under
#   ~/Library/Application Support/Black & White
# keeps a log of every start under
#   ~/Library/Logs/Black & White
# and then becomes bw_native (exec), so the game is the app's one process.
#
# Settings are in ~/Library/Application Support/Black & White/settings.conf, which is written
# on the first start (one KEY=value per line, # starts a comment) and changed by the "Black &
# White Settings" app (native/app/settings); it can be edited by hand as well. Where the game's files are
# comes from the same file (GAME_DIR, DISC_DIR, EXE) and, when it names none, from the places
# the app was built with (Contents/Resources/defaults.conf).
#
# For testing only: BW_APP_SUPPORT_DIR and BW_APP_LOGS_DIR move the two folders above,
# BW_APP_NO_DIALOG=1 writes messages to stderr instead of showing them,
# BW_APP_DRYRUN=1 prints what would be started and stops,
# BW_APP_PRINT_SETTINGS=1 loads settings only, prints RESOLUTION and BW_RENDER_SCALE, and stops
# (BW_APP_BUNDLE_ROOT replaces the bundle root; BW_APP_DISPLAY_POINTS sets the main display size
# for PICTURE=native; BW_APP_DISPLAY_DENSITY sets its pixel density, for the automatic RENDER_SCALE).
# Any other BW_* variable in the environment goes on to the game.

set -u

if [ -n "${BW_APP_BUNDLE_ROOT:-}" ]; then
  CONTENTS="$BW_APP_BUNDLE_ROOT"
else
  CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
fi
NAME="Black & White"
SUPPORT="${BW_APP_SUPPORT_DIR:-$HOME/Library/Application Support/$NAME}"
LOGS="${BW_APP_LOGS_DIR:-$HOME/Library/Logs/$NAME}"
SETTINGS="$SUPPORT/settings.conf"
# The program file the code was lifted from; bw_native checks the same SHA-256 before it
# starts anything. Which one (and which native build runs it) follows GAME_VERSION in the
# settings (written when the player's copy was added): 100, 142 or ci. EXE_SHA256 named by
# hand in settings.conf replaces the version's value; this is the 1.00 fallback.
EXE_SHA256="86a30b08ab2ea8a240403d37f8f0303cf65aa5cde8e7f673049ab01654ccf755"
GAME_VERSION=""
NATIVE_BIN="bw_native"
EXE_CANDIDATES=()

note() { printf '%s\n' "$*" >&2; }

# A message the player can read, then stop.
fail() {
  note "$NAME: $1"
  if [ -z "${BW_APP_NO_DIALOG:-}" ]; then
    /usr/bin/osascript - "$1" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  display dialog (item 1 of argv) with title "Black & White" buttons {"OK"} default button 1 with icon stop
end run
APPLESCRIPT
  fi
  exit 1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

GAME_DIR=""
DISC_DIR=""
EXE=""
DATA_DIR="$SUPPORT/data"
SCREEN_MODE="window"
RESOLUTION="1280x800"
AUDIO="device"
VOLUME=""
POINTER=""
FPS_CAP=""
QUIT_GRACE_MS=""
PICTURE="classic"
RENDER_SCALE=""
# What PICTURE and RENDER_SCALE work out to; sent to the game as BW_RENDER_SCALE only when set,
# so a BW_RENDER_SCALE in the environment (a test run) goes on unchanged for a classic picture.
PICTURE_SCALE=""

# KEY=value lines, only the keys above; the file is read as text and never run as a script.
load_conf() {
  [ -f "$1" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; esac
    case "$key" in
      GAME_DIR|DISC_DIR|EXE|EXE_SHA256|GAME_VERSION|DATA_DIR|SCREEN_MODE|RESOLUTION|AUDIO|VOLUME|POINTER|FPS_CAP|QUIT_GRACE_MS|PICTURE|RENDER_SCALE)
        printf -v "$key" '%s' "$val"
        ;;
    esac
  done < "$1"
}

# Main display size in Cocoa points (WIDTHxHEIGHT), or empty when it cannot be read.
main_display_points() {
  if [ -n "${BW_APP_DISPLAY_POINTS:-}" ]; then
    printf '%s' "$BW_APP_DISPLAY_POINTS"
    return 0
  fi
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var f = $.NSScreen.mainScreen.frame;
    var w = Math.round(f.size.width);
    var h = Math.round(f.size.height);
    w + "x" + h;
  ' 2>/dev/null
}

# The main display's pixel density (2 on a Retina display), or empty when it cannot be read.
# BW_APP_DISPLAY_DENSITY replaces it, for tests.
main_display_density() {
  if [ -n "${BW_APP_DISPLAY_DENSITY:-}" ]; then
    printf '%s' "$BW_APP_DISPLAY_DENSITY"
    return 0
  fi
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    String($.NSScreen.mainScreen.backingScaleFactor);
  ' 2>/dev/null
}

# Automatic sharpness: 2 on a Retina display, 1 on any other (and when the density cannot be read).
automatic_scale() {
  local d
  d="$(trim "$(main_display_density)")"
  if [[ "$d" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$d" 'BEGIN { exit !(v >= 1.5) }'; then
    printf '2'
  else
    printf '1'
  fi
}

# What a RENDER_SCALE value gives: a number as it stands; "auto" is the display's own density. Empty
# is the same, except that nothing is printed where that is 1, or where the environment has a
# BW_RENDER_SCALE already (a test run), so the game's own setting goes on as it was.
effective_scale() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    '')
      [ -n "${BW_RENDER_SCALE:-}" ] && return 0
      [ "$(automatic_scale)" = 2 ] && printf '2'
      return 0
      ;;
    auto) automatic_scale ;;
    *) printf '%s' "$1" ;;
  esac
}

render_scale_ok() {
  local s="$1"
  [ "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" = auto ] && return 0
  [[ "$s" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v v="$s" 'BEGIN { exit !(v >= 0.5 && v <= 4) }'
}

normalize_picture() {
  local p
  p="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$p" in
    classic|1440p|4k|native) printf '%s' "$p" ;;
    '') printf '%s' classic ;;
    *) printf '%s' "$p" ;;
  esac
}

# Sets RESOLUTION and PICTURE_SCALE from PICTURE and optional RENDER_SCALE. The classic picture
# is RESOLUTION as it stands; a RENDER_SCALE draws it finer (and, in a window, makes the window
# grow with it). With none, or "auto", the scale is the display's own pixel density (2 on a Retina
# display, where a sharpness of 1 would give a window of half the picture's size and a coarse
# picture); where the environment already has a BW_RENDER_SCALE (a test run) and the file has none,
# that one goes on unchanged.
apply_picture_settings() {
  local mode scale
  mode="$(normalize_picture "$PICTURE")"
  case "$mode" in
    classic)
      PICTURE_SCALE="$(effective_scale "$RENDER_SCALE")"
      return 0
      ;;
    1440p)
      RESOLUTION="1280x720"
      scale="2"
      ;;
    4k)
      RESOLUTION="1920x1080"
      scale="2"
      ;;
    native)
      local pts
      pts="$(main_display_points)"
      pts="$(trim "$pts")"
      if [[ "$pts" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
        # Even numbers: the game's own picture sizes are even, and an odd height (1117 on
        # a 16-inch built-in display) has never been run.
        local pw="${pts%x*}" ph="${pts#*x}"
        RESOLUTION="$((pw / 2 * 2))x$((ph / 2 * 2))"
        scale="$(automatic_scale)"
      else
        note "$NAME: PICTURE=native but the main display size could not be read; using classic picture size."
        PICTURE="classic"
        PICTURE_SCALE="$(effective_scale "$RENDER_SCALE")"
        return 0
      fi
      ;;
    *)
      note "$NAME: unknown PICTURE \"$PICTURE\" in $SETTINGS; using classic."
      PICTURE="classic"
      PICTURE_SCALE="$(effective_scale "$RENDER_SCALE")"
      return 0
      ;;
  esac
  if [ -n "$RENDER_SCALE" ]; then
    scale="$(effective_scale "$RENDER_SCALE")"
  fi
  PICTURE_SCALE="$scale"
}

print_derived_settings() {
  printf 'RESOLUTION=%s\n' "$RESOLUTION"
  if [ -n "$PICTURE_SCALE" ]; then
    printf 'BW_RENDER_SCALE=%s\n' "$PICTURE_SCALE"
  else
    printf 'BW_RENDER_SCALE=\n'
  fi
  printf 'PICTURE=%s\n' "$(normalize_picture "$PICTURE")"
}

load_conf "$CONTENTS/Resources/defaults.conf"

mkdir -p "$SUPPORT" "$LOGS" || fail "Cannot make the folders $SUPPORT and $LOGS."

if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<'SETTINGS_TEXT'
# Black & White settings.
#
# The "Black & White Settings" app writes this file; it can be edited by hand as well. The game
# reads it once, when it starts, so a change is used the next time the game is opened.
#
# SCREEN_MODE: window (a window you can move; the default), desktop (borderless, over the whole
#   screen) or exclusive (a real display mode switch).
SCREEN_MODE=window
#
# RESOLUTION: the game's own picture size, WIDTHxHEIGHT. A larger one shows more of the world
#   at once and makes the buttons smaller. It is shown in the window or on the screen with its
#   shape kept.
RESOLUTION=1280x800
#
# PICTURE: classic (the size above; the default) or native (this Mac's main display in points,
#   as even numbers, which then replaces RESOLUTION). 1440p and 4k, the older presets, set both
#   RESOLUTION and RENDER_SCALE and are still understood.
PICTURE=classic
#
# RENDER_SCALE: how many times finer the world is drawn than the picture size, 0.5 to 4. Empty
#   (or auto) is automatic: 2 on a Retina display, 1 on other displays, worked out at each start.
#   In a window the window grows by the same factor, so 2 gives a 1280x800 picture a 1280x800-point
#   window on a Retina display. The buttons and the hand are not redrawn finer.
RENDER_SCALE=
#
# FPS_CAP: the most pictures a second the game shows (0: no limit). Left out, it is 60 in a window
#   you are playing in. The game's turns run at about 10 a second whatever this says.
# FPS_CAP=60
#
# AUDIO: device (play the sound) or off.
AUDIO=device
# VOLUME: the master volume, 0 to 100. Left out, it is 100. The game's Options screen sets it.
# VOLUME=100
#
# Set by hand, if wanted (the Settings app leaves them as they are):
#   QUIT_GRACE_MS=15000   closing the window asks the game to quit; at some moments (the opening
#                         films, loading) it ignores that, so the app ends it this many
#                         milliseconds after the first request (0: never)
#   POINTER=absolute      absolute (the hand follows the pointer exactly) or virtual (the hand is
#                         steered by the pointer's motion); empty lets the game decide
#   GAME_DIR=/path/to/the/installed/Black & White
#   DISC_DIR=/path/to/the/disc/copy       (the folder next to its .volume file)
#   EXE=/path/to/the/program/file
#   GAME_VERSION=100                      which version was set up: 100, 142 (Fan Patch) or
#                                         ci (Creature Isle); written when a disc is added
SETTINGS_TEXT
fi

load_conf "$SETTINGS"

picture_mode="$(normalize_picture "$PICTURE")"
case "$picture_mode" in
  classic|1440p|4k|native) ;;
  *)
    note "$NAME: unknown PICTURE \"$PICTURE\" in $SETTINGS; using classic."
    PICTURE="classic"
    picture_mode="classic"
    ;;
esac
if [ -n "$RENDER_SCALE" ]; then
  render_scale_ok "$RENDER_SCALE" ||
    fail "RENDER_SCALE in $SETTINGS must be a number from 0.5 to 4 (it is \"$RENDER_SCALE\")."
fi
apply_picture_settings
picture_mode="$(normalize_picture "$PICTURE")"
[[ "$RESOLUTION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] ||
  fail "RESOLUTION must look like 1280x800 (it is \"$RESOLUTION\" after PICTURE settings)."

if [ -n "${BW_APP_PRINT_SETTINGS:-}" ]; then
  print_derived_settings
  exit 0
fi

case "$SCREEN_MODE" in
  window|desktop|exclusive) ;;
  *) fail "SCREEN_MODE in $SETTINGS must be window, desktop or exclusive (it is \"$SCREEN_MODE\")." ;;
esac
case "$AUDIO" in
  device|off) ;;
  *) fail "AUDIO in $SETTINGS must be device or off (it is \"$AUDIO\")." ;;
esac
case "$POINTER" in
  ''|absolute|virtual) ;;
  *) fail "POINTER in $SETTINGS must be absolute or virtual (it is \"$POINTER\")." ;;
esac
[[ -z "$VOLUME" || "$VOLUME" =~ ^(100|[0-9]{1,2})$ ]] ||
  fail "VOLUME in $SETTINGS must be 0 to 100 (it is \"$VOLUME\")."
[[ -z "$FPS_CAP" || "$FPS_CAP" =~ ^[0-9]{1,3}$ ]] ||
  fail "FPS_CAP in $SETTINGS must be a whole number of pictures a second, or 0 (it is \"$FPS_CAP\")."
[[ -z "$QUIT_GRACE_MS" || "$QUIT_GRACE_MS" =~ ^[0-9]{1,6}$ ]] ||
  fail "QUIT_GRACE_MS in $SETTINGS must be a whole number of milliseconds, or 0 (it is \"$QUIT_GRACE_MS\")."

# Which version was set up decides the native build and the program it runs. A pin named
# by hand in settings.conf (EXE_SHA256) replaces the version's own.
case "$GAME_VERSION" in
  142)
    NATIVE_BIN="bw_native_142"
    EXE_CANDIDATES=("$GAME_DIR/runblack.exe")
    grep -q '^EXE_SHA256=' "$SETTINGS" 2>/dev/null ||
      EXE_SHA256="3f58bc02a6c421b4e66ef08716646bf0e1fa55ab292786edb521d7596ed48aba"
    ;;
  ci)
    NATIVE_BIN="bw_native_ci"
    EXE_CANDIDATES=("$GAME_DIR/CreatureIsle.exe" "$GAME_DIR/CreatureIsle-decrypted.exe")
    grep -q '^EXE_SHA256=' "$SETTINGS" 2>/dev/null ||
      EXE_SHA256="72345d04368a40ec22e2960aed9e43b57f63bc299dfad56cbcd4bbf8faea3636"
    ;;
  *)
    GAME_VERSION="100"
    EXE_CANDIDATES=("$GAME_DIR/runblack-decrypted.exe" "$GAME_DIR/runblack.exe" "$DISC_DIR/crack/runblack.exe")
    grep -q '^EXE_SHA256=' "$SETTINGS" 2>/dev/null ||
      EXE_SHA256="86a30b08ab2ea8a240403d37f8f0303cf65aa5cde8e7f673049ab01654ccf755"
    ;;
esac

# The game's files.
[ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ] ||
  fail "The game's install folder was not found (GAME_DIR is \"$GAME_DIR\"). Open Black & White and add your disc to set it up, or put the folder's place in $SETTINGS."
for f in "lhlogr.dll" "LHaudiodllR.dll" "LHMultiplayerR.dll" "Plug Ins/ScriptLibraryR.dll"; do
  [ -f "$GAME_DIR/$f" ] || fail "$GAME_DIR has no \"$f\", so it is not the install this build was made for."
done
[ -n "$DISC_DIR" ] && [ -d "$DISC_DIR" ] && [ -f "$DISC_DIR.volume" ] ||
  fail "The disc copy was not found (DISC_DIR is \"$DISC_DIR\"; it needs a $(basename "${DISC_DIR:-disc}").volume file beside it). Open Black & White and add your disc to set it up, or put its place in $SETTINGS."

# macOS keeps Desktop, Documents, Downloads and other drives private from an app until the user lets
# it in, and an app whose main program is a script cannot ask. Files there can be seen (the tests
# above pass) but not opened, which would otherwise end as a puzzling "no runblack.exe" message.
blocked=""
{ : < "$GAME_DIR/lhlogr.dll"; } 2>/dev/null || blocked="$GAME_DIR"
/bin/ls "$DISC_DIR" >/dev/null 2>&1 || blocked="${blocked:-$DISC_DIR}"
[ -z "$blocked" ] ||
  fail "Black & White cannot read the files in $blocked. If that is under Desktop, Documents or Downloads, or on another drive, macOS keeps it private from this app. Add your disc again from the Black & White app (it keeps the game where it may be read), or name a readable place in $SETTINGS."

matches_build() {
  [ -f "$1" ] && [ "$(/usr/bin/shasum -a 256 "$1" | cut -d' ' -f1)" = "$EXE_SHA256" ]
}
if [ -n "$EXE" ]; then
  matches_build "$EXE" ||
    fail "EXE in $SETTINGS (\"$EXE\") is not the program this build was made from (SHA-256 $EXE_SHA256). Open Black & White and add your copy of the game again to set it up afresh."
else
  for candidate in "${EXE_CANDIDATES[@]}"; do
    if matches_build "$candidate"; then
      EXE="$candidate"
      break
    fi
  done
  [ -n "$EXE" ] ||
    fail "No program that matches this build was found in $GAME_DIR. Open Black & White and add your copy of the game again to set it up afresh."
fi

# The registry the game reads its picture size from. bw_native writes this file itself when it is
# missing (always 1280x800); writing it here makes the first start use RESOLUTION as well. The
# format is the runtime's own: key sections, then name, type 4 (DWORD) and little-endian hex.
dword() {
  printf '%02x%02x%02x%02x' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 ))
}
WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"
REGISTRY="$DATA_DIR/bw/registry.txt"
mkdir -p "$DATA_DIR/bw" || fail "Cannot make the folder $DATA_DIR."
if [ ! -f "$REGISTRY" ]; then
  {
    for root in hkcu hklm; do
      key="$root"
      for part in software "lionhead studios ltd" "black & white" bwsetup; do
        key="$key\\$part"
        printf '[%s]\n' "$key"
      done
      printf 'screenw\t4\t%s\n' "$(dword "$WIDTH")"
      printf 'screenh\t4\t%s\n' "$(dword "$HEIGHT")"
      printf 'screend\t4\t%s\n' "$(dword 32)"
    done
  } > "$REGISTRY"
else
  # Only the two size lines change; everything else the game keeps there stays as it is.
  tmp="$REGISTRY.new.$$"
  /usr/bin/awk -F'\t' -v OFS='\t' -v w="$(dword "$WIDTH")" -v h="$(dword "$HEIGHT")" '
    $1 == "screenw" && $2 == "4" { $3 = w }
    $1 == "screenh" && $2 == "4" { $3 = h }
    { print }' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
  rm -f "$tmp"
fi

LOG="$LOGS/native-$(date +%Y%m%d-%H%M%S).log"
{
  echo "start $(date '+%Y-%m-%d %H:%M:%S')"
  echo "version:     $GAME_VERSION (build $NATIVE_BIN)"
  echo "game folder: $GAME_DIR"
  echo "disc copy:   $DISC_DIR"
  echo "program:     $EXE"
  echo "data folder: $DATA_DIR"
  echo "screen mode: $SCREEN_MODE, picture $picture_mode, logical $RESOLUTION${PICTURE_SCALE:+, scale $PICTURE_SCALE}, audio $AUDIO${POINTER:+, pointer $POINTER}"
  [ -f "$CONTENTS/Resources/BUILD-INFO.txt" ] && sed 's/^/build: /' "$CONTENTS/Resources/BUILD-INFO.txt"
  echo "----"
} > "$LOG"

# The ten newest logs are kept.
ls -1t "$LOGS"/native-*.log 2>/dev/null | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done

# The game's own Options screen offers the Screen and Resolution choices as well (bw-native,
# src/display_menu.cpp). It is given the list the Settings app shows, so the two name every choice
# the same way, and applies a choice by running that app again (it writes the file, quits the game
# the way Cmd-Q does, and opens it again). A game with no Settings app to be found just has no such
# rows. BW_SETTINGS_BIN names the tool for a test.
settings_tool() {
  local candidate
  for candidate in "${BW_SETTINGS_BIN:-}" \
      "$CONTENTS/../../$NAME Settings.app/Contents/MacOS/BlackWhiteSettings" \
      "$HOME/Applications/$NAME Settings.app/Contents/MacOS/BlackWhiteSettings"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
# A game the Settings app opened for a restart can carry the values of the game that asked for it,
# which describe the settings that game started with, so these are always worked out here from the
# file just read.
unset BW_DISPLAY_MENU BW_SETTINGS_TOOL BW_SETTINGS_GAME_APP BW_MAIN_MENU
# The main menu's Online tab (bw-native, src/main_menu.cpp): Start Skirmish Game and Join
# Online Game live there under a Coming soon notice, still with their original actions,
# instead of in the main menu's column. A game started any other way keeps the original menu.
export BW_MAIN_MENU=online
tool="$(settings_tool || true)"
menu=""
[ -n "$tool" ] && menu="$("$tool" --game-menu 2>/dev/null || true)"
if [ -n "$menu" ]; then
  export BW_SETTINGS_TOOL="$tool"
  export BW_DISPLAY_MENU="$menu"
  export BW_SETTINGS_GAME_APP="$(cd "$CONTENTS/.." && pwd)"
fi

export BW_CD_DIR="$DISC_DIR"
export BW_FULLSCREEN="$SCREEN_MODE"
export BW_BACKGROUND="${BW_BACKGROUND:-0}"
[ "$AUDIO" = off ] && export BW_AUDIO=off
[ -n "$VOLUME" ] && export BW_MASTER_VOLUME="$VOLUME"
[ -n "$POINTER" ] && export BW_POINTER="$POINTER"
[ -n "$FPS_CAP" ] && export BW_FPS_CAP="$FPS_CAP"
[ -n "$QUIT_GRACE_MS" ] && export BW_QUIT_GRACE_MS="$QUIT_GRACE_MS"
[ -n "$PICTURE_SCALE" ] && export BW_RENDER_SCALE="$PICTURE_SCALE"

if [ -n "${BW_APP_DRYRUN:-}" ]; then
  echo "would start: $CONTENTS/MacOS/$NATIVE_BIN --game-dir $GAME_DIR --exe $EXE --data-dir $DATA_DIR"
  echo "environment: BW_CD_DIR=$BW_CD_DIR BW_FULLSCREEN=$BW_FULLSCREEN BW_BACKGROUND=$BW_BACKGROUND${BW_AUDIO:+ BW_AUDIO=$BW_AUDIO}${BW_MASTER_VOLUME:+ BW_MASTER_VOLUME=$BW_MASTER_VOLUME}${BW_POINTER:+ BW_POINTER=$BW_POINTER}${BW_FPS_CAP:+ BW_FPS_CAP=$BW_FPS_CAP}${BW_QUIT_GRACE_MS:+ BW_QUIT_GRACE_MS=$BW_QUIT_GRACE_MS}${BW_RENDER_SCALE:+ BW_RENDER_SCALE=$BW_RENDER_SCALE}"
  echo "registry:    $REGISTRY"
  echo "log:         $LOG"
  if [ -n "${BW_SETTINGS_TOOL:-}" ]; then
    echo "options menu: $BW_SETTINGS_TOOL ($(printf '%s\n' "$BW_DISPLAY_MENU" | grep -c .) lines)"
  else
    echo "options menu: none"
  fi
  exit 0
fi

# When the game ends with a fatal error (the runtime prints a line that starts with FATAL), say
# so and offer the log. The watcher waits for this process, which becomes the game below.
if [ -z "${BW_APP_NO_DIALOG:-}" ]; then
  parent=$$
  (
    exec >/dev/null 2>&1 </dev/null
    while kill -0 "$parent" 2>/dev/null; do sleep 2; done
    if grep -q '^FATAL' "$LOG" 2>/dev/null; then
      reason="$(grep -m1 '^FATAL' "$LOG" | cut -c1-300)"
      button="$(/usr/bin/osascript - "$reason" <<'APPLESCRIPT'
on run argv
  set r to display dialog ("Black & White stopped with an error." & return & return & (item 1 of argv)) with title "Black & White" buttons {"Close", "Show the log"} default button 2 with icon stop
  return button returned of r
end run
APPLESCRIPT
)"
      [ "$button" = "Show the log" ] && /usr/bin/open -R "$LOG"
    fi
  ) &
  disown 2>/dev/null || true
fi

exec "$CONTENTS/MacOS/$NATIVE_BIN" --game-dir "$GAME_DIR" --exe "$EXE" --data-dir "$DATA_DIR" >> "$LOG" 2>&1
