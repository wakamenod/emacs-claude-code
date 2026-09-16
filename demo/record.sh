#!/usr/bin/env bash
# Record a demonstration of this checkout, in the user's own configuration.
#
#   demo/record.sh <scene> [out.mp4]
#
# Opens a second GUI Emacs, loads ~/.emacs.d/init.el into it and puts
# this checkout in front of whatever ecc that init points at, plays the
# scene named -- demo/scenes/<scene>.el for what it builds and what its
# steps are, demo/scenes/<scene>.sh for the order and the pauses -- and
# records the frame it is played in.  demo/README.md says how to write a
# scene; demo.el says why a step is run the way it is.
#
# It is for a check by eye, not for the documentation: the pictures the
# site and README.md carry are made by scripts/docshots.sh and
# scripts/screenshot.sh, which dress a throwaway -Q Emacs up instead.
#
# macOS only.  ffmpeg records "Capture screen 0" and the output is
# cropped to the rectangle the frame is held in, so nothing else on the
# screen is in the video; the terminal running this needs Screen
# Recording permission (System Settings -> Privacy & Security -> Screen
# Recording), or the video comes out black.
set -euo pipefail

scene=${1:?usage: demo/record.sh <scene> [out.mp4]}
here=$(cd "$(dirname "$0")" && pwd)
out=${2:-$here/$scene.mp4}
scene_el=$here/scenes/$scene.el
scene_sh=$here/scenes/$scene.sh
[ -f "$scene_el" ] || { echo "no such scene: $scene_el" >&2; exit 1; }
[ -f "$scene_sh" ] || { echo "no such scene: $scene_sh" >&2; exit 1; }

emacs_app=${EMACS_APP:-/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app}
# emacs-plus keeps emacsclient beside the .app rather than inside it.
emacsclient=${EMACSCLIENT:-$(command -v emacsclient || echo "${emacs_app%/*}/bin/emacsclient")}
server=ecc-demo
ready=/tmp/ecc-demo-ready.txt

# The frame is held at (40,140), 1700x950 (demo.el), and the ediff
# control panel is a frame of its own placed above the top of it, so the
# crop starts at the corner of the screen.  These are the pixels of a 2x
# display; on a 1x one, halve them.
crop=${DEMO_CROP:-3560:2260:0:0}
fps=10

# Which avfoundation device the screen is.  It is 4 on this machine;
# `ffmpeg -f avfoundation -list_devices true -i ""' says what it is on
# another, as "[N] Capture screen 0".
screen=${DEMO_SCREEN_DEVICE:-4}

# macOS `open' hands this process's environment to the Emacs it starts,
# and a Claude Code session's own variables turn transcript saving off in
# the CLI a scene may start -- the session then says so across the top of
# the picture.
for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

ffmpeg_pid=
cleanup() {
    [ -n "$ffmpeg_pid" ] && kill -INT "$ffmpeg_pid" 2>/dev/null || true
    pkill -f "demo/demo.el" 2>/dev/null || true
}
trap cleanup EXIT

# A run that failed may have left its Emacs and its socket behind.
pkill -f "demo/demo.el" 2>/dev/null || true
rm -f "$ready" "${TMPDIR:-/tmp}/emacs$(id -u)/$server"

# `open' is the only way to a frame the window system will really draw:
# running the executable from a terminal leaves `display-graphic-p' nil.
# With -Q the command line is processed; with this user's init loaded by
# Emacs itself it is not, which is why demo.el loads the init by hand.
open -n -a "$emacs_app" --args -Q \
     --eval "(setq demo-scene-file \"$scene_el\")" -l "$here/demo.el"

for _ in $(seq 1 60); do [ -f "$ready" ] && break; sleep 1; done
[ -f "$ready" ] || { echo "the demo Emacs never came up" >&2; exit 1; }
echo "ecc loaded from: $(cat "$ready")" >&2

ffmpeg -hide_banner -loglevel error -y \
    -f avfoundation -capture_cursor 1 -framerate "$fps" -i "$screen" \
    -vf "crop=$crop,scale=1456:-2" -pix_fmt yuv420p -r "$fps" "$out" &
ffmpeg_pid=$!
sleep 3

# A step that opens a minibuffer can leave `emacsclient' waiting for an
# answer that only comes when the minibuffer does -- the scenes are
# written not to, but a wait here would hang the whole run.
e() {
    echo "-- $1" >&2
    if ! timeout 25 "$emacsclient" -s "$server" -e "$1" >/dev/null; then
        echo "   (no answer in 25s)" >&2
    fi
}

# A caption in the echo area.  Mind the quoting: it goes through the
# shell and then through the Lisp reader, so no " of its own.
say() { e "(demo-say \"$1\")"; }

# shellcheck source=/dev/null
. "$scene_sh"

kill -INT "$ffmpeg_pid" 2>/dev/null || true
wait "$ffmpeg_pid" 2>/dev/null || true
ffmpeg_pid=
echo "wrote $out" >&2
ls -lh "$out" >&2
