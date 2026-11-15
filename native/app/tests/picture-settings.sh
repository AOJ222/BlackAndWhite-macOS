#!/bin/bash
# Exercise launcher picture settings (no game, no bw_native). Uses BW_APP_PRINT_SETTINGS=1.
# Each case names the RESOLUTION, BW_RENDER_SCALE and PICTURE the launcher must work out; the
# script ends with status 1 when one differs.
set -u

LAUNCHER="$(cd "$(dirname "$0")/.." && pwd)/launcher.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bw-picture-settings.XXXXXX")"
BUNDLE="$WORK/fake-bundle"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$BUNDLE/Contents/Resources" "$WORK/support"
touch "$BUNDLE/Contents/Resources/defaults.conf"

failures=0

# run_case NAME DISPLAY_POINTS EXPECTED_RESOLUTION EXPECTED_SCALE EXPECTED_PICTURE LINE...
run_case() {
  local name="$1" display="$2" want_res="$3" want_scale="$4" want_picture="$5"
  shift 5
  local settings="$WORK/support/settings.conf"
  {
    printf '%s\n' "$@"
  } >"$settings"
  local stderr="$WORK/$name.err"
  local out
  local -a env=(
    BW_APP_NO_DIALOG=1
    BW_APP_PRINT_SETTINGS=1
    BW_APP_BUNDLE_ROOT="$BUNDLE/Contents"
    BW_APP_SUPPORT_DIR="$WORK/support"
    BW_APP_LOGS_DIR="$WORK/logs"
  )
  [ -n "$display" ] && env+=(BW_APP_DISPLAY_POINTS="$display")
  # The display's pixel density: 1 (a plain display) unless a case sets DENSITY=2 (Retina); EXTRA
  # is one more variable of the environment, such as a test run's own BW_RENDER_SCALE.
  env+=(BW_APP_DISPLAY_DENSITY="${DENSITY:-1}")
  [ -n "${EXTRA:-}" ] && env+=("$EXTRA")
  out="$(env "${env[@]}" bash "$LAUNCHER" 2>"$stderr")"
  printf '=== %s ===\n' "$name"
  if [ -s "$stderr" ]; then
    sed 's/^/note: /' "$stderr"
  fi
  printf '%s\n' "$out"
  local want
  want="$(printf 'RESOLUTION=%s\nBW_RENDER_SCALE=%s\nPICTURE=%s' "$want_res" "$want_scale" "$want_picture")"
  if [ "$out" = "$want" ]; then
    printf 'ok\n\n'
  else
    printf 'FAIL: wanted\n%s\n\n' "$want"
    failures=$((failures + 1))
  fi
}

run_case classic \
  '' 1280x800 '' classic \
  'RESOLUTION=1280x800' \
  'PICTURE=classic'

run_case 'classic, larger resolution' \
  '' 1920x1200 '' classic \
  'RESOLUTION=1920x1200' \
  'PICTURE=classic'

run_case 'classic with a render scale' \
  '' 1280x800 2 classic \
  'RESOLUTION=1280x800' \
  'PICTURE=classic' \
  'RENDER_SCALE=2'

run_case 'classic, other resolution and a render scale' \
  '' 1440x900 1.5 classic \
  'RESOLUTION=1440x900' \
  'PICTURE=classic' \
  'RENDER_SCALE=1.5'

run_case '1440p preset' \
  '' 1280x720 2 1440p \
  'RESOLUTION=1920x1080' \
  'PICTURE=1440p'

run_case '4k preset' \
  '' 1920x1080 2 4k \
  'PICTURE=4k'

DENSITY=2 run_case 'native (fake Retina display 1728x1117)' \
  1728x1117 1728x1116 2 native \
  'PICTURE=native'

run_case 'native, scale given (what the Settings app writes)' \
  1728x1117 1728x1116 1 native \
  'PICTURE=native' \
  'RENDER_SCALE=1'

run_case 'custom render scale on 4k' \
  '' 1920x1080 1.5 4k \
  'PICTURE=4k' \
  'RENDER_SCALE=1.5'

run_case 'unknown picture' \
  '' 1024x768 '' classic \
  'PICTURE=ultra' \
  'RESOLUTION=1024x768'

# Automatic: an empty RENDER_SCALE (or "auto") is the display's own pixel density.
DENSITY=2 run_case 'classic, no scale, Retina display (automatic: 2)' \
  '' 1280x800 2 classic \
  'PICTURE=classic' \
  'RENDER_SCALE='

DENSITY=2 run_case 'classic, RENDER_SCALE missing, Retina display (an older file: automatic)' \
  '' 1280x800 2 classic \
  'RESOLUTION=1280x800'

DENSITY=2 run_case 'classic, RENDER_SCALE=auto, Retina display' \
  '' 1920x1080 2 classic \
  'RESOLUTION=1920x1080' \
  'RENDER_SCALE=auto'

DENSITY=1 run_case 'classic, RENDER_SCALE=auto, plain display' \
  '' 1920x1080 1 classic \
  'RESOLUTION=1920x1080' \
  'RENDER_SCALE=auto'

DENSITY=1 run_case 'classic, no scale, plain display (left as the game has it)' \
  '' 1280x800 '' classic \
  'RESOLUTION=1280x800'

DENSITY=2 run_case 'classic, a scale of 1 given, Retina display (kept: 1)' \
  '' 1280x800 1 classic \
  'RESOLUTION=1280x800' \
  'RENDER_SCALE=1'

DENSITY=2 EXTRA=BW_RENDER_SCALE=3 run_case 'classic, no scale, Retina display, a test run gives its own scale (left alone)' \
  '' 1280x800 '' classic \
  'RESOLUTION=1280x800'

DENSITY=2 run_case 'native, no scale, Retina display (automatic: 2)' \
  1728x1117 1728x1116 2 native \
  'PICTURE=native'

DENSITY=1 run_case 'native, no scale, plain display (automatic: 1)' \
  1728x1117 1728x1116 1 native \
  'PICTURE=native'

DENSITY=1 run_case '4k preset, RENDER_SCALE=auto, plain display (the scale is the display'"'"'s: 1)' \
  '' 1920x1080 1 4k \
  'PICTURE=4k' \
  'RENDER_SCALE=auto'

DENSITY=unreadable run_case 'classic, RENDER_SCALE=auto, density cannot be read (1)' \
  '' 1280x800 1 classic \
  'RESOLUTION=1280x800' \
  'RENDER_SCALE=auto'

# bad render scale must fail, with any picture
for picture in 4k classic; do
  settings="$WORK/support/settings.conf"
  printf 'PICTURE=%s\nRENDER_SCALE=9\n' "$picture" >"$settings"
  printf '=== bad render scale with PICTURE=%s (expect failure) ===\n' "$picture"
  if BW_APP_NO_DIALOG=1 BW_APP_PRINT_SETTINGS=1 \
    BW_APP_BUNDLE_ROOT="$BUNDLE/Contents" \
    BW_APP_SUPPORT_DIR="$WORK/support" \
    BW_APP_LOGS_DIR="$WORK/logs" \
    bash "$LAUNCHER" >/dev/null 2>&1; then
    printf 'FAIL: launcher exited 0\n\n'
    failures=$((failures + 1))
  else
    printf 'launcher exited non-zero (ok)\n\n'
  fi
done

if [ "$failures" -ne 0 ]; then
  printf '%d case(s) failed\n' "$failures"
  exit 1
fi
printf 'all picture-settings cases passed\n'
