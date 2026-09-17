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
# macOS only.  `screencapture -v' records the display and ffmpeg crops
# what it wrote to the rectangle the frame is held in, so nothing else on
# the screen is in the video; the terminal running this needs Screen
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
# The server and the ready file are named after this checkout, and the
# Emacs of a run that failed is killed by its full path: two worktrees
# recording a demonstration at the same time shared the name `ecc-demo',
# so a step of one run was answered by the other run's Emacs and each
# start killed the other (2026-09-17).
tag=$(basename "$(dirname "$here")")
server=ecc-demo-$tag
ready=/tmp/ecc-demo-$tag-ready.txt

# The frame is held at (40,140), 1700x950 (demo.el), and the ediff
# control panel is a frame of its own placed above the top of it, so the
# crop starts at the corner of the screen.  These are the pixels of a 2x
# display; on a 1x one, halve them.
crop=${DEMO_CROP:-3560:2260:0:0}
fps=10

# Which display is recorded, counted the way `screencapture -D' counts.
screen=${DEMO_SCREEN_DISPLAY:-1}

# The screen is taken with `screencapture -v' and cropped afterwards
# with ffmpeg, rather than captured by ffmpeg itself: on this machine
# (ffmpeg 8, macOS 26) the avfoundation input says the pixel format it
# was given is not one the device supports, then waits for a frame that
# never comes, while `screencapture' -- which needs the same Screen
# Recording permission, and has it -- records the same display without a
# word (2026-09-17).  SIGINT is how it is stopped, and it finishes the
# file it was writing.
raw_dir=$(mktemp -d -t ecc-demo-raw)
raw=$raw_dir/screen.mov

# macOS `open' hands this process's environment to the Emacs it starts,
# and a Claude Code session's own variables turn transcript saving off in
# the CLI a scene may start -- the session then says so across the top of
# the picture.
for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

capture_pid=
cleanup() {
    [ -n "$capture_pid" ] && kill -INT "$capture_pid" 2>/dev/null || true
    pkill -f "$here/demo.el" 2>/dev/null || true
    rm -rf "$raw_dir"
}
trap cleanup EXIT

# A run that failed may have left its Emacs and its socket behind.
pkill -f "$here/demo.el" 2>/dev/null || true
rm -f "$ready" "${TMPDIR:-/tmp}/emacs$(id -u)/$server"

# `open' is the only way to a frame the window system will really draw:
# running the executable from a terminal leaves `display-graphic-p' nil.
# With -Q the command line is processed; with this user's init loaded by
# Emacs itself it is not, which is why demo.el loads the init by hand.
open -n -a "$emacs_app" --args -Q \
     --eval "(setq demo-server-name \"$server\" demo-ready-file \"$ready\" demo-scene-file \"$scene_el\")" \
     -l "$here/demo.el"

for _ in $(seq 1 60); do [ -f "$ready" ] && break; sleep 1; done
[ -f "$ready" ] || { echo "the demo Emacs never came up" >&2; exit 1; }
echo "ecc loaded from: $(cat "$ready")" >&2

screencapture -v -C -D "$screen" "$raw" &
capture_pid=$!
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

kill -INT "$capture_pid" 2>/dev/null || true
wait "$capture_pid" 2>/dev/null || true
capture_pid=

# `screencapture -v' writes the whole display, at a size of its own
# choosing rather than the screen's: the crop is in the pixels of a 2x
# display (above), so it is scaled by what the recording came out at
# against what a still of the same screen measures.
shot=$(mktemp -t ecc-demo-shot).png
screencapture -x -D "$screen" "$shot"
screen_width=$(sips -g pixelWidth "$shot" | awk '/pixelWidth/ {print $2}')
rm -f "$shot"
raw_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
                    -of csv=p=0 "$raw")
scaled=$(awk -F: -v r="$raw_width" -v s="$screen_width" \
             '{f = r / s; printf "%d:%d:%d:%d", $1*f, $2*f, $3*f, $4*f}' \
             <<<"$crop")
ffmpeg -hide_banner -loglevel error -y -i "$raw" \
    -vf "crop=$scaled,scale=1456:-2" -pix_fmt yuv420p -r "$fps" "$out"
rm -rf "$raw_dir"
echo "wrote $out" >&2
ls -lh "$out" >&2
