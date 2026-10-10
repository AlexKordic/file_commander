#!/usr/bin/env bash
# Plays the promo in this terminal with the overlay drawn over it, then cleans up.
#
#   tools/promo/runpromo.sh               rebuild the world and play the storyboard
#   tools/promo/runpromo.sh --calibrate   line the overlay up with this window first
#   tools/promo/runpromo.sh --speed 2     any other option goes to play.py
#
# Run it in the iTerm2 window you record, after starting the screen recorder.
# Ctrl+\ aborts. The overlay is stopped however the run ends.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
out=build-promo
python="$out/venv/bin/python"
log="$out/overlay.log"

calibrate=0
play_args=()
for arg in "$@"; do
  case "$arg" in
    --calibrate) calibrate=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) play_args+=("$arg") ;;
  esac
done

say() { printf 'runpromo: %s\n' "$*"; }
fail() { printf 'runpromo: %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || fail "the overlay is macOS-only; use play.py directly elsewhere"
[[ -x build-release/fc ]] || fail "build FC first: cmake --preset release && cmake --build --preset release"
mkdir -p "$out"

if [[ ! -x "$python" ]]; then
  say "setting up $out/venv"
  python3 -m venv "$out/venv"
  "$out/venv/bin/pip" install --quiet -r tools/promo/requirements.txt
fi

say "building the overlay"
swift build -c release --package-path tools/promo/overlay --quiet
overlay="$(swift build -c release --package-path tools/promo/overlay --show-bin-path)/fc-promo-overlay"

if pgrep -x fc-promo-overlay > /dev/null; then
  say "stopping the overlay that was already running"
  pkill -x fc-promo-overlay || true
  for _ in $(seq 30); do pgrep -x fc-promo-overlay > /dev/null || break; sleep 0.1; done
  pkill -9 -x fc-promo-overlay 2> /dev/null || true
fi

overlay_pid=
cleanup() {
  if [[ -n "$overlay_pid" ]]; then
    kill "$overlay_pid" 2> /dev/null || true
    wait "$overlay_pid" 2> /dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$overlay" > "$log" 2>&1 &
overlay_pid=$!
for _ in $(seq 50); do
  grep -q 'listening on' "$log" && break
  kill -0 "$overlay_pid" 2> /dev/null || { cat "$log" >&2; fail "the overlay did not start"; }
  sleep 0.1
done
grep -q 'listening on' "$log" || fail "the overlay did not start listening; see $log"

if [[ $calibrate == 1 ]] || grep -q 'not calibrated' "$log"; then
  say "calibrating: line the grid up with the coloured cells, then press Enter"
  sleep 1
  "$python" tools/promo/play.py --pattern --overlay
fi

say "building the world"
python3 tools/promo/make_world.py > "$out/world.log" 2>&1 || { cat "$out/world.log" >&2; fail "make_world.py failed"; }

"$python" tools/promo/play.py --overlay --srt "$out/captions.srt" --events "$out/events.jsonl" \
  ${play_args[@]+"${play_args[@]}"}
say "captions in $out/captions.srt, overlay events in $out/events.jsonl"
