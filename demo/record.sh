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
# macOS only.  What is recorded is the demo frame's own window, through
# demo/record-window.swift: nothing that covers it is in the picture, it
# does not have to be in front, and two of these can run at once without
# recording each other.  Whatever runs this needs Screen Recording
# permission (System Settings -> Privacy & Security -> Screen Recording),
# or there is nothing to record.
#
# Neither way of recording the screen is here any more, and both had
# reasons of their own to go: ffmpeg's avfoundation input says the pixel
# format it was given is not one the device supports and then waits for a
# frame that never comes (ffmpeg 8, macOS 26), and `screencapture -v'
# writes the whole display at a size of its own choosing, to be cropped
# afterwards (2026-09-17).  A window needs neither.
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

# Everything a run owns is named after the checkout and the scene, so
# that two runs -- in two worktrees, driven by two sessions, of the same
# scene or of different ones -- do not take each other's Emacs, socket,
# ready file or window.  They did, and killed each other halfway
# through (2026-09-17).
tag=$(basename "$(dirname "$here")")-$scene
# The server is a Unix socket, and the whole of its path has to fit in
# the 104 characters of `sun_path' -- and $TMPDIR/emacs<uid>/ is 59 of
# them on macOS, which leaves 44 for the name.  A checkout and a scene
# with real names are longer than that: every step of a nine-minute
# recording came back with "socket-name ... too long" and the video was
# nine minutes of a frame nobody had touched (2026-09-17).  The name is
# the scene, cut short, and a digest of the whole tag: short enough,
# still one per checkout and scene, and still on the command line for
# `pkill -f' to find.  The ready file and the frame title are a plain
# file and a window title, and keep the long name.
server=ecc-demo-$(printf '%s' "$scene" | cut -c1-12)-$(printf '%s' "$tag" | md5 -q | cut -c1-6)
ready=/tmp/ecc-demo-$tag-ready.txt
title="ecc demo: $tag"

fps=${DEMO_FPS:-10}
width=${DEMO_WIDTH:-1456}

recorder=$here/.build/record-window

# macOS `open' hands this process's environment to the Emacs it starts,
# and a Claude Code session's own variables turn transcript saving off in
# the CLI a scene may start -- the session then says so across the top of
# the picture.
for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

recorder_pid=
cleanup() {
    # INT and then wait: the recorder writes the index of the mp4 when
    # it is asked to stop, and a file it did not finish has no `moov'
    # atom and will not open at all.
    if [ -n "$recorder_pid" ]; then
        kill -INT "$recorder_pid" 2>/dev/null || true
        wait "$recorder_pid" 2>/dev/null || true
    fi
    # This run's Emacs, by the server name on its command line -- never
    # every demo Emacs on the machine, which is another run's.  The name
    # is the pattern rather than the path: `pkill -f' takes a regexp, and
    # a checkout called `feat+worktree' is one that matches no such
    # thing.
    pkill -f "$server" 2>/dev/null || true
}
trap cleanup EXIT

# A run of THIS scene that failed may have left its Emacs and its socket
# behind.
pkill -f "$server" 2>/dev/null || true
rm -f "$ready" "${TMPDIR:-/tmp}/emacs$(id -u)/$server"

# Built here rather than committed: it is 128K of Mach-O and swiftc is
# on any machine that can run this at all.
if [ ! -x "$recorder" ] || [ "$here/record-window.swift" -nt "$recorder" ]; then
    echo "building $recorder" >&2
    mkdir -p "$here/.build"
    swiftc -O -parse-as-library -o "$recorder" "$here/record-window.swift" \
        2>&1 | grep -v "^ld: warning" || true
fi
[ -x "$recorder" ] || { echo "could not build $recorder" >&2; exit 1; }

# Played from a copy under a name of this run's own.  Every other
# checkout of this repository carries a record.sh of its own, and the
# older ones kill `demo/demo.el' -- every one on the machine, not their
# own -- when they start and when they finish.  Two of this scene's runs
# died that way (2026-09-17).
player=${TMPDIR:-/tmp}/ecc-demo-player-$scene.el
cp "$here/demo.el" "$player"

# `open' is the only way to a frame the window system will really draw:
# running the executable from a terminal leaves `display-graphic-p' nil.
# With -Q the command line is processed; with this user's init loaded by
# Emacs itself it is not, which is why demo.el loads the init by hand.
open -n -a "$emacs_app" --args -Q \
     --eval "(setq demo-scene-file \"$scene_el\" demo-server-name \"$server\" demo-ready-file \"$ready\" demo-frame-title \"$title\" demo-checkout \"$(cd "$here/.." && pwd)\")" \
     -l "$player"

for _ in $(seq 1 60); do [ -f "$ready" ] && break; sleep 1; done
[ -f "$ready" ] || { echo "the demo Emacs never came up" >&2; exit 1; }
echo "ecc loaded from: $(cat "$ready")" >&2
echo "server: $server" >&2

# `caffeinate -d' for the whole recording: a display that goes to sleep
# stops drawing, a window that is not drawn hands no frames over, and the
# scene is recorded as nothing at all.  It does not defeat a Mac that
# locks itself -- nothing does, and nothing should -- so a run left alone
# long enough to lock is a run to start again.
caffeinate -d -w $$ &
"$recorder" --title "$title" --out "$out" --fps "$fps" --width "$width" &
recorder_pid=$!
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

kill -INT "$recorder_pid" 2>/dev/null || true
wait "$recorder_pid" 2>/dev/null || true
recorder_pid=
echo "wrote $out" >&2
ls -lh "$out" >&2
