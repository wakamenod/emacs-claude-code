#!/usr/bin/env bash
# Make the pictures the documentation site points at.
#
#   scripts/docshots.sh [outdir]
#
# Writes menu.png, resume.png and switch.gif into
# docs/site/src/assets (or into the directory given).
#
# Opens a throwaway GUI Emacs, walks it through each scene and captures
# the frame.  No CLI and no network are involved, so it costs nothing and
# comes out the same every time.
#
# macOS only.  It needs `screencapture' and `ffmpeg', and the terminal
# running this needs Screen Recording permission (System Settings ->
# Privacy & Security -> Screen Recording); without it screencapture says
# "could not create image from display".
set -euo pipefail

outdir=${1:-docs/site/src/assets}
# The conversation the hand-off scene resumes in the terminal.  It is
# recorded once, in the demo project, and kept: the CLI can only
# --resume a conversation it has really had.
handover_id=7c3d9e21-4b5a-4f18-9c62-1d0e8a7f5b34
handover_prompt="Name three things worth testing in a greeting function. One short line each, no code."
emacs_app=${EMACS_APP:-/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app}
# emacs-plus keeps emacsclient beside the .app rather than inside it.
emacsclient=${EMACSCLIENT:-$(command -v emacsclient || echo "${emacs_app%/*}/bin/emacsclient")}
root=$(cd "$(dirname "$0")/.." && pwd)
frames=$(mktemp -d -t ecc-docshot-frames)
geom=$(mktemp -t ecc-docshot-geom); rm -f "$geom"
err=$(mktemp -t ecc-docshot-err); rm -f "$err"
n=0

# Both the recording and the terminal of the hand-off scene run the real
# CLI, and a Claude Code session this script was started from would pass
# its own environment on: CLAUDE_CODE_CHILD_SESSION turns transcript
# saving off, and the CLI then says so across the top of the picture.
# macOS `open' passes the environment to the Emacs it starts, so this has
# to be gone before any of it runs.
for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

cleanup() { pkill -f 'scripts/docshots.el' 2>/dev/null || true; rm -rf "$frames"; }
trap cleanup EXIT

# A step that opens a minibuffer can leave `emacsclient' waiting for an
# answer that only comes when the minibuffer does -- the scenes are
# written not to, but a wait here would hang the whole run rather than
# spoil one picture.
e() {
    echo "-- $1" >&2
    if ! timeout 25 "$emacsclient" -s ecc-docshot -e "$1" >/dev/null; then
        echo "   (no answer in 25s)" >&2
    fi
}

# Start a new animation; the frames of each live in a directory of their own.
scene() {
    scene=$1
    n=0
    mkdir -p "$frames/$scene"
}

# Capture one frame, $1 times (repeat to hold a moment longer).
snap() {
    local repeat=${1:-1}
    for _ in $(seq 1 "$repeat"); do
        n=$((n + 1))
        screencapture -x -R"$X,$Y,$W,$H" "$(printf '%s/%s/%03d.png' "$frames" "$scene" "$n")"
    done
}

# Assemble the frames of the current scene into an animation.
gif() {
    ffmpeg -hide_banner -loglevel error -y \
        -framerate 3 -pattern_type glob -i "$frames/$scene/*.png" \
        -vf "scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer" \
        -loop 0 "$outdir/$scene.gif"
}

# Ask the frame where it is now.  The menu and the minibuffer resize it,
# and a frame that would grow past the bottom of the screen is moved.
regeom() {
    e '(shot-report-geometry)'
    read -r X Y W H _cols _lines < "$geom"
}

# Capture one frame to a file of its own.
still() {
    regeom
    screencapture -x -R"$X,$Y,$W,$H" "$1"
}

if [ -z "$(ls "$HOME"/.claude/projects/*/"$handover_id".jsonl 2>/dev/null)" ]; then
    echo "recording the conversation the hand-off scene resumes..." >&2
    mkdir -p /tmp/greet
    (cd /tmp/greet && claude -p --session-id "$handover_id" \
         --model haiku --max-budget-usd 0.10 "$handover_prompt" >/dev/null)
fi

# A run that failed may have left its Emacs and its socket behind.
pkill -f 'scripts/docshots.el' 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/emacs$(id -u)/ecc-docshot"

open -n -a "$emacs_app" --args -Q --chdir "$root" \
  --eval "(setq shot-geometry-file \"$geom\" shot-error-file \"$err\")" \
  -l "$root/scripts/docshots.el"

for _ in $(seq 1 30); do
    [ -f "$geom" ] && break
    [ -f "$err" ] && { echo "setup failed: $(cat "$err")" >&2; exit 1; }
    sleep 1
done
[ -f "$geom" ] || { echo "the frame never reported its geometry" >&2; exit 1; }
read -r X Y W H _cols _lines < "$geom" || true

mkdir -p "$outdir"

# 1. Switching a window from one session to another, as an animation.
# Frames that repeat are merged into one long frame by the time the site
# has converted the animation, so a scene has to keep changing: type a
# letter at a time, and go back the way it came rather than holding the
# last picture.
scene switch
e '(shot-scene-switch-start)'   ; snap 2
e '(shot-scene-switch-pick)'    ; sleep 2; snap 2
e '(shot-scene-type "n")'       ; snap
e '(shot-scene-type "o")'       ; snap
e '(shot-scene-type "t")'       ; snap 2
e '(shot-scene-return)'         ; sleep 1; snap 3
e '(shot-scene-switch-pick)'    ; sleep 2; snap 2
e '(shot-scene-type "g")'       ; snap
e '(shot-scene-type "r")'       ; snap 2
e '(shot-scene-return)'         ; sleep 1; snap 3
gif

# 2. The menu, open over a session.
e '(shot-scene-menu)'           ; sleep 3; still "$outdir/menu.png"
e '(shot-scene-quit)'           ; sleep 1

# 3. Sending the region from a source buffer.  This one runs the real
# CLI: the point of the picture is the answer coming back.
scene send-region
e '(shot-start-live)'               ; sleep 4
e '(shot-scene-send-region-point)'  ; snap 2
e '(shot-scene-send-region-mark)'   ; snap
e '(shot-scene-send-region-extend)' ; snap
e '(shot-scene-send-region-extend)' ; snap
e '(shot-scene-send-region-extend)' ; snap 2
e '(shot-scene-send-region-ask)'    ; sleep 1; snap 2
e '(shot-scene-type "What could ")' ; snap
e '(shot-scene-type "go wrong ")'   ; snap
e '(shot-scene-type "with this ")'  ; snap
e '(shot-scene-type "function?")'   ; snap 2
e '(shot-scene-return)'             ; snap 2
# The answer streaming in is the motion, so the frames are taken while
# it arrives rather than after it has.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do sleep 1; snap; done
gif
e '(shot-dump-live-log)'

# 4. Handing a session over to the terminal.  The CLI is the real one,
# resuming a conversation recorded in the demo project, so this scene
# needs `claude' and a recording it can find.
e '(shot-scene-quit)'           ; sleep 1

scene handover
e '(shot-scene-handover-start)' ; sleep 1; snap 3
e '(shot-scene-handover)'       ; snap
# The CLI drawing itself is the motion here, so the frames are taken
# while it comes up rather than after.
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; snap; done
gif

# The picker of `ecc-resume' is last: it stays on screen, and a
# minibuffer with a completion UI over it does not reliably take a `C-g'
# fed to it from the server.
e '(shot-scene-resume)'         ; sleep 3; still "$outdir/resume.png"

echo "wrote $outdir/switch.gif, $outdir/handover.gif, $outdir/menu.png and $outdir/resume.png"
