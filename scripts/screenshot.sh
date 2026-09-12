#!/usr/bin/env bash
# Make docs/images/session.gif and docs/images/session.png.
#
#   scripts/screenshot.sh [outdir]
#
# Opens a throwaway GUI Emacs, walks it through a short ecc session, and
# captures a frame after each step.  No CLI and no network are involved,
# so it costs nothing and comes out the same every time.
#
# macOS only.  It needs `screencapture' and `ffmpeg', and the terminal
# running this needs Screen Recording permission (System Settings ->
# Privacy & Security -> Screen Recording); without it screencapture says
# "could not create image from display".
set -euo pipefail

outdir=${1:-docs/images}
emacs_app=${EMACS_APP:-/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app}
# emacs-plus keeps emacsclient beside the .app rather than inside it.
emacsclient=${EMACSCLIENT:-$(command -v emacsclient || echo "${emacs_app%/*}/bin/emacsclient")}
root=$(cd "$(dirname "$0")/.." && pwd)
frames=$(mktemp -d -t ecc-shot-frames)
geom=$(mktemp -t ecc-shot-geom); rm -f "$geom"
err=$(mktemp -t ecc-shot-err); rm -f "$err"
n=0

cleanup() { pkill -f 'scripts/screenshot.el' 2>/dev/null || true; rm -rf "$frames"; }
trap cleanup EXIT

e() { "$emacsclient" -s ecc-shot -e "$1" >/dev/null; }

# Capture one frame, $1 times (repeat to hold a moment longer).
snap() {
    local repeat=${1:-1}
    for _ in $(seq 1 "$repeat"); do
        n=$((n + 1))
        screencapture -x -R"$X,$Y,$W,$H" "$(printf '%s/%03d.png' "$frames" "$n")"
    done
}

open -n -a "$emacs_app" --args -Q --chdir "$root" \
  --eval "(setq shot-geometry-file \"$geom\" shot-error-file \"$err\")" \
  -l "$root/scripts/screenshot.el"

for _ in $(seq 1 30); do
    [ -f "$geom" ] && break
    [ -f "$err" ] && { echo "setup failed: $(cat "$err")" >&2; exit 1; }
    sleep 1
done
[ -f "$geom" ] || { echo "the frame never reported its geometry" >&2; exit 1; }
read -r X Y W H _cols _lines < "$geom" || true

# The geometry is the frame's outer edges, title bar included, which is
# the rectangle to capture.
snap 3                                     # the session, idle

# Typing, a few characters at a time.
for part in 'Make ' 'greet ' 'say ' 'hello ' 'instead ' 'of ' 'hi.'; do
    e "(shot-step-type \"$part\")"
    snap
done
snap 2

# The fixture, once the one sentence is dropped, runs:
#   1-5 system  6 thinking  7 Read  8 result  9 thinking  10 Edit
#   11 permission  12 result  13-14 system  15 thinking  16 text  17 done
e '(shot-step-send)'                       ; snap 2   # the turn opens
e '(shot-feed 1 8)'                        ; snap 2   # thinking, then Read
e '(shot-feed 9 11)'                       ; snap 4   # Edit, and the request waits
e '(shot-step-allow)'                      ; snap 3   # allowed, the diff appears
still=$n                                   # the still is this moment
e '(shot-feed 12 17)'                      ; snap 2   # the result and the summary
e '(shot-step-reread)'                     ; snap 5   # the source buffer catches up

mkdir -p "$outdir"
# The still is the frame where the diff has just been allowed.
cp "$(printf '%s/%03d.png' "$frames" "$still")" "$outdir/session.png"

ffmpeg -hide_banner -loglevel error -y \
    -framerate 3 -pattern_type glob -i "$frames/*.png" \
    -vf "scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer" \
    -loop 0 "$outdir/session.gif"

echo "wrote $outdir/session.gif ($n frames) and $outdir/session.png"
