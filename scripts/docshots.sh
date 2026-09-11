#!/usr/bin/env bash
# Make the pictures the documentation site points at.
#
#   scripts/docshots.sh [outdir]
#
# Writes the stills and the short animations the site points at into
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

# Which scenes to take.  All of them, unless SCENES names some:
#
#   SCENES="menu resume" scripts/docshots.sh
#
# Retaking one picture is the common case -- a key changes, a colour
# changes -- and taking all of them runs the real CLI four times.
want() {
    [ -z "${SCENES:-}" ] && return 0
    case " $SCENES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Start a new animation; the frames of each live in a directory of their own.
# The frame is asked where it is first, as it is before a still: the
# position read at startup can be stale by the time a scene runs -- the
# corner the frame is placed in is settled by the window system, not by
# Emacs -- and every frame of the animation would then be cut off on one
# side (confirmed 2026-09-11).
scene() {
    scene=$1
    n=0
    mkdir -p "$frames/$scene"
    regeom
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

if want switch; then
    # 1. Switching a window from one session to another, as an animation.
    # Frames that repeat are merged into one long frame by the time the site
    # has converted the animation, so a scene has to keep changing: type a
    # letter at a time, and go back the way it came rather than holding the
    # last picture.
    scene switch
    e '(shot-scene-switch-start)'      ; snap 2
    e '(shot-scene-switch-sequence)'
    for _ in $(seq 1 22); do sleep 0.5; snap; done
    gif
fi

if want menu; then
    # 2. The menu, open over a session.
    e '(shot-scene-menu)'           ; sleep 3; still "$outdir/menu.png"
    e '(shot-scene-quit)'           ; sleep 1
fi

# The four scenes below are answered by the model, so they need a session
# that really runs.  It is started once, whichever of them is being taken.
if want send-region || want fix-error || want inline || want rewrite \
       || want at-cursor || want image || want context || want suggestion; then
    e '(shot-start-live)'               ; sleep 4
fi

if want send-region; then
    # 3. Sending the region from a source buffer.  This one runs the real
    # CLI: the point of the picture is the answer coming back.
    scene send-region
    e '(shot-scene-send-region-point)'  ; snap 2
    e '(shot-scene-send-region-mark)'   ; snap
    e '(shot-scene-send-region-extend)' ; snap
    e '(shot-scene-send-region-extend)' ; snap
    e '(shot-scene-send-region-extend)' ; snap 2
    e '(shot-scene-send-region-sequence)'
    # The typing and then the answer streaming in are the motion, so the
    # frames are taken while they happen rather than after.
    for _ in $(seq 1 10); do sleep 0.5; snap; done
    for _ in $(seq 1 12); do sleep 1; snap; done
    gif
    e '(shot-dump-live-log)'
fi

if want fix-error; then
    # 4. Fixing the error a checker found.  The file really is broken and
    # the checker really is run; only the checker is the standard library
    # rather than something installed.
    scene fix-error
    e '(shot-scene-fix-error-open)'     ; sleep 3; snap 3
    e '(shot-scene-fix-error-point)'    ; snap 2
    e '(shot-scene-fix-error)'          ; snap 2
    for _ in $(seq 1 10); do sleep 1; snap; done
    # Allowing it is part of the scene: the edit is made, the buffer picks
    # it up, and the checker has nothing left to complain about.  It also
    # leaves nothing waiting, which would blink through every picture taken
    # after this one.
    e '(shot-scene-allow)'              ; sleep 1; snap 2
    for _ in $(seq 1 8); do sleep 1; snap; done
    e '(shot-scene-recheck)'            ; sleep 2; snap 4
    gif
fi

if want inline; then
    # 5. Asking about the region and being answered where the code is.
    scene inline
    e '(shot-scene-send-region-point)'  ; snap
    e '(shot-scene-send-region-mark)'   ; snap
    e '(shot-scene-send-region-extend)' ; snap
    e '(shot-scene-send-region-extend)' ; snap
    e '(shot-scene-send-region-extend)' ; snap 2
    e '(shot-scene-inline-sequence)'
    for _ in $(seq 1 8); do sleep 0.5; snap; done
    for _ in $(seq 1 12); do sleep 1; snap; done
    gif
fi

if want rewrite; then
    # 6. Rewriting the region, and accepting what comes back.
    scene rewrite
    e '(shot-scene-send-region-point)'  ; snap
    e '(shot-scene-send-region-mark)'   ; snap
    e '(shot-scene-send-region-extend)' ; snap
    e '(shot-scene-send-region-extend)' ; snap
    e '(shot-scene-send-region-extend)' ; snap 2
    e '(shot-scene-rewrite-sequence)'
    for _ in $(seq 1 8); do sleep 0.5; snap; done
    for _ in $(seq 1 10); do sleep 1; snap; done
    e '(shot-scene-accept)'             ; sleep 1; snap 4
    gif
fi

if want at-cursor; then
    # An @ reference: the point stands in the source, the prompt says
    # @cursor, and what is sent carries the line it was on.
    scene at-cursor
    e '(shot-scene-cursor-point 7)'          ; snap 2
    e '(shot-prompt-type "What does ")'      ; snap
    e '(shot-prompt-type "@cursor")'         ; snap
    e '(shot-prompt-type " return?")'        ; snap 2
    e '(shot-prompt-send)'                   ; snap 2
    for _ in $(seq 1 12); do sleep 1; snap; done
    gif
fi

if want context; then
    # The editor context, attached to every prompt while it is on.
    scene context
    e '(shot-scene-cursor-point 3)'                                  ; snap 2
    e '(shot-prompt-command (quote ecc-prompt-toggle-context))'      ; snap 3
    e '(shot-prompt-type "Where am I?")'                             ; snap 2
    e '(shot-prompt-send)'                                           ; snap 2
    for _ in $(seq 1 12); do sleep 1; snap; done
    e '(shot-prompt-command (quote ecc-prompt-toggle-context))'      ; snap 2
    gif
fi

if want image; then
    # An image in a prompt: it is written to disk and referenced by path.
    scene image
    e '(shot-scene-insert-image)'                 ; snap 3
    e '(shot-prompt-type "What is in this image?")'; snap 2
    e '(shot-prompt-send)'                        ; snap 2
    for _ in $(seq 1 14); do sleep 1; snap; done
    gif
fi

if want suggestion; then
    # The prompt the CLI offers, and C-c C-s taking it.  A suggestion
    # arrives when the CLI feels like offering one, so this asks until
    # there is one rather than sleeping a fixed time.
    e '(shot-prompt-type "Name one thing to test here. One line.")'
    e '(shot-prompt-send)'
    for _ in $(seq 1 40); do
        sleep 2
        if "$emacsclient" -s ecc-docshot -e '(shot-suggestion-p)' 2>/dev/null | grep -q t; then
            break
        fi
    done
    scene suggestion
    e '(shot-scene-cursor-point 1)'   ; snap
    e '(shot-prompt-command (quote ecc-chat-goto-prompt))' ; snap 3
    e '(shot-prompt-command (quote ecc-hint-accept-suggestion))' ; snap 4
    e '(shot-prompt-send)'            ; snap 2
    for _ in $(seq 1 10); do sleep 1; snap; done
    gif
fi

if want capabilities; then
    # What the session can do: the list the CLI reported in system/init.
    scene capabilities
    e '(shot-scene-capabilities)'                        ; sleep 1; snap 4
    e '(shot-scene-capabilities-toggle "Slash commands")'; snap 3
    e '(shot-scene-capabilities-toggle "Skills")'        ; snap 3
    e '(shot-scene-capabilities-toggle "Agents")'        ; snap 3
    e '(shot-scene-capabilities-toggle "Skills")'        ; snap 4
    gif
fi

if want sessions; then
    # The dashboard and the tab line, over four sessions in four states.
    # It replays fixtures, so it costs nothing; it is placed before the
    # scenes that follow because it leaves a permission waiting, which
    # `shot-scene-sessions-end' then answers.
    e '(shot-scene-sessions)'     ; sleep 2; still "$outdir/tabs.png"
    e '(shot-scene-dashboard)'    ; sleep 2; still "$outdir/dashboard.png"
    e '(shot-scene-sessions-end)' ; sleep 1
fi

if want prompt; then
    # The transcript folding, and the point walking the headings.  No
    # minibuffer here, so each step is one call and one frame.  It comes
    # first because the scene after it leaves a picker on the screen.
    scene fold
    e '(shot-scene-fold-start)'                         ; snap 2
    e '(shot-scene-fold (quote ecc-chat-collapse-all))' ; snap 3
    e '(shot-scene-fold (quote ecc-chat-show-level-2))' ; snap 2
    e '(shot-scene-fold (quote ecc-chat-show-level-3))' ; snap 2
    e '(shot-scene-fold (quote ecc-chat-next-heading))' ; snap
    e '(shot-scene-fold (quote ecc-chat-next-heading))' ; snap
    e '(shot-scene-fold (quote ecc-chat-toggle))'       ; snap 3
    e '(shot-scene-fold (quote ecc-chat-toggle))'       ; snap 3
    e '(shot-scene-fold (quote ecc-chat-expand-all))'   ; snap 3
    gif

    # The slash command list, open over a session.  Like the resume
    # picker, it stays on the screen until it is dismissed.
    e '(shot-scene-slash)'   ; sleep 3; still "$outdir/slash.png"
    e '(shot-scene-quit)'    ; sleep 1
    e '(shot-scene-clear-prompt)'
fi

# Two answers, both replayed: the recording is stopped where it asks,
# answered here as a user would, and played to its end afterwards.
if want permission; then
    scene permission
    e '(shot-scene-permission)'        ; sleep 1; snap 3
    e '(shot-scene-permission-allow)'  ; snap 2
    e '(shot-scene-permission-finish)' ; sleep 1; snap 4
    gif
fi

if want question; then
    scene question
    e '(shot-scene-question)'            ; sleep 1; snap 3
    e '(shot-scene-question-open)'       ; sleep 1; snap 3
    e '(shot-scene-question-choose 1)'   ; snap 2
    e '(shot-scene-question-choose 1)'   ; snap 2
    e '(shot-scene-question-choose 2)'   ; snap 3
    e '(shot-scene-question-submit)'     ; sleep 1; snap 4
    gif
fi

if want handover; then
    # 7. Handing a session over to the terminal.  The CLI is the real one,
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
fi

if want resume; then
    # The picker of `ecc-resume' is last: it stays on screen, and a
    # minibuffer with a completion UI over it does not reliably take a `C-g'
    # fed to it from the server.
    e '(shot-scene-resume)'         ; sleep 3; still "$outdir/resume.png"

fi

echo "wrote the pictures of ${SCENES:-every scene} into $outdir"
