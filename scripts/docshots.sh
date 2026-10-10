#!/usr/bin/env bash
# Make the pictures and the videos the documentation site points at.
#
#   scripts/docshots.sh [outdir]
#
# Writes the stills into docs/site/src/assets and the short videos into
# docs/site/public/videos, or both into the directory given.  A video is
# an mp4 (H.264, yuv420p, no audio) encoded from the frames captured
# while the scene plays, and NAME.webp beside it is its first frame, the
# poster the page shows until the video is played.  Beside each one are
# its subtitles, NAME.en.vtt and NAME.ja.vtt, written by hand; this
# script writes their cue times, from the `cue' marks in the scene, and
# leaves their text alone.  Each step is held, by repeating its last
# frame, until its subtitle can be read (`readable_frames').
#
# Opens a throwaway GUI Emacs, walks it through each scene and captures
# the frame.  Most scenes replay recordings, so they cost nothing and
# come out the same every time; the ones about an answer arriving run
# the real CLI, with haiku and a budget.
#
# macOS only.  It needs `swiftc' (the Xcode command line tools), `ffmpeg'
# and `cwebp' (brew install webp: Homebrew's ffmpeg has no WebP encoder),
# and the terminal running this needs Screen Recording permission (System
# Settings -> Privacy & Security -> Screen Recording); without it
# record-window says it cannot see the windows.
#
# Only the Emacs this starts is in the pictures: its frame may be covered
# by other windows, and the machine may be used while it runs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Everything this makes is of the checkout the script is in, and goes
# into that checkout, wherever it is started from.  The defaults were
# relative to the current directory, so a run started anywhere else
# wrote there (2026-10-10).  docshots.el makes sure the code in the
# pictures is this checkout's too (`shot-foreign-ecc').
outdir=${1:-$root/docs/site/src/assets}
# The videos are not processed by Astro's image pipeline, so they and
# their subtitles are served as they are, from public/.  Given a
# directory, the videos go into videos/ under it, with a copy of their
# subtitles: `stretch' reads their text and `retime' writes their times.
videodir=$root/docs/site/public/videos
if [ -n "${1:-}" ]; then
    mkdir -p "$1/videos"
    cp "$videodir"/*.vtt "$1/videos/"
    videodir=$1/videos
fi
# The conversation the hand-off scene resumes in the terminal.  It is
# recorded once, in the demo project, and kept: the CLI can only
# --resume a conversation it has really had.
handover_id=47497a40-9f64-4203-b040-ebf68c77354e
handover_prompt="Name three things worth testing in parse_line in reader.py. One short line each, no code."
emacs_app=${EMACS_APP:-/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app}
# emacs-plus keeps emacsclient beside the .app rather than inside it.
emacsclient=${EMACSCLIENT:-$(command -v emacsclient || echo "${emacs_app%/*}/bin/emacsclient")}
frames=$(mktemp -d -t ecc-docshot-frames)
geom=$(mktemp -t ecc-docshot-geom); rm -f "$geom"
err=$(mktemp -t ecc-docshot-err); rm -f "$err"
n=0

# The pictures are taken by demo/record-window.swift, the recorder of
# demo/record.sh, built where that builds it.  It takes the frame's own
# window, child frames included, and nothing that covers it: this used
# to take a rectangle of the screen with `screencapture -R', which took
# whatever was in that corner -- with the person at the machine using
# it, their own Emacs, twice on 2026-10-10.  The frame is found by a
# title of this run's own.
recorder=$root/demo/.build/record-window
if [ ! -x "$recorder" ] || [ "$root/demo/record-window.swift" -nt "$recorder" ]; then
    echo "building $recorder" >&2
    mkdir -p "$root/demo/.build"
    swiftc -O -parse-as-library -o "$recorder" "$root/demo/record-window.swift" \
        2>&1 | grep -v "^ld: warning" || true
fi
[ -x "$recorder" ] || { echo "could not build $recorder" >&2; exit 1; }
title="ecc docshot $$ $RANDOM"
# The display the frame stands on: the one with the most pixels to the
# point, since the pictures are taken in its pixels.  A frame left on a
# screen of one pixel to the point beside a Retina one came out at half
# the width (2026-10-10).
display=$("$recorder" --displays | sort -k5 -nr | head -1)
read -r display_x display_y _ _ display_scale <<< "$display"
echo "taking the pictures on the display at $display_x,$display_y ($display_scale pixels to the point)" >&2

# Both the recording and the terminal of the hand-off scene run the real
# CLI, and a Claude Code session this script was started from would pass
# its own environment on: CLAUDE_CODE_CHILD_SESSION turns transcript
# saving off, and the CLI then says so across the top of the picture.
# macOS `open' passes the environment to the Emacs it starts, so this has
# to be gone before any of it runs.
for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

cleanup() {
    if [ -n "${capturing:-}" ]; then kill -INT "$capturing" 2>/dev/null || true; fi
    pkill -f 'scripts/docshots.el' 2>/dev/null || true
    rm -rf "$frames"
}
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

# Start a new video; the frames of each live in a directory of their own.
# The frame is asked for its size first, as it is before a still: a scene
# before this one may have resized it.
# The frames are taken by `recorder', which films the whole time from here
# to `video'; `hold' notes which of them belong in the video.
scene() {
    scene=$1
    n=0
    rm -rf "${frames:?}/${scene:?}" "${frames:?}/${scene:?}".*
    mkdir -p "$frames/$scene"
    regeom
    "$recorder" --title "$title" --fps "$fps" --frames "$frames/$scene.raw" &
    capturing=$!
    for _ in $(seq 1 100); do
        [ -s "$frames/$scene.raw/started" ] && break
        sleep 0.1
    done
    [ -s "$frames/$scene.raw/started" ] || { echo "$scene: no frame came" >&2; exit 1; }
    started=$(cat "$frames/$scene.raw/started")
}

# Start the next subtitle here.  The frames captured so far are its
# start time, and the next mark, or the end of the video, is its end.
# A scene marks one cue per cue in its .vtt files, in the same order;
# the first mark comes before the first hold.
cue() { echo "$n" >> "$frames/$scene.cues"; }

# How many frames a second the videos are captured and played at.
fps=10

now_ms() { local t=${EPOCHREALTIME/[.,]/}; echo $((10#${t:0:${#t}-3})); }

# Put $1 seconds of what is happening now into the video.  The frames
# are the recorder's, taken the whole time; a hold takes the ones that fall
# inside it.  What happens between two holds -- the `sleep' while a
# scene sets itself up -- is filmed and left out, as it always was.
# Every frame is a real capture: writing the same frame out twice to
# hold a state makes the video no smoother, only longer.  A step that
# settles -- a window rearranging, a posframe arriving -- is then
# actually seen settling.
hold() {
    local from to first last i step=$((1000 / fps))
    from=$(now_ms)
    sleep "$1"
    to=$(now_ms)
    # Frame I is the screen at `started' + (I - 1) * step.
    first=$(( (from - started + step - 1) / step + 1 ))
    last=$(( (to - started + step - 1) / step ))
    (( last < first )) && last=$first
    for (( i = first; i <= last; i++ )); do
        echo "$i" >> "$frames/$scene.ticks"
        n=$((n + 1))
    done
}

# What to keep of a picture of the whole window, as an ffmpeg filter:
# the rectangle `regeom' read, in points, turned into pixels by the
# width of the picture against the width of the window.  The window's
# corners are rounded and come out transparent, so the picture is put
# on the theme's background first.
keep() {
    echo "format=rgba,split[a][b];[a]drawbox=c=0x1a1b26@1:t=fill:replace=1[bg];[bg][b]overlay=format=rgb,crop=w=iw*$CW/$OW:h=iw*$CH/$OW:x=iw*$CX/$OW:y=iw*$CY/$OW"
}

# Stop filming, and lay the frames the holds took out in order, as
# $frames/$scene/0001.png on.  A frame the capture had not written by
# the time it was stopped is the one before it again.
cut() {
    local i k=0 have=""
    kill -INT "$capturing" 2>/dev/null || true
    wait "$capturing" 2>/dev/null || true
    # The recorder takes the window at the size it had when the scene
    # began; a frame that changed size after that is scaled into it.
    if [ -e "$frames/$scene.raw/resized" ]; then
        echo "$scene: the frame changed size during the scene; nothing written" >&2
        exit 1
    fi
    while read -r i; do
        k=$((k + 1))
        [ -f "$(printf '%s/%04d.png' "$frames/$scene.raw" "$i")" ] \
            && have=$(printf '%s/%04d.png' "$frames/$scene.raw" "$i")
        [ -n "$have" ] || { echo "$scene: frame $i was never taken" >&2; exit 1; }
        ln "$have" "$(printf '%s/%s/%04d.png' "$frames" "$scene" "$k")"
    done < "$frames/$scene.ticks"
}

# Encode the frames of the current scene into a video, and time its
# subtitles.  yuv420p and +faststart are what every browser plays and
# starts before the whole file is in; the scale keeps both sides even,
# which yuv420p needs.
#
# The site shows a video across its 45rem (720 CSS pixel) content
# column, so a display of two pixels to the point wants 1440: that is
# the width, or the width of the capture if it is narrower -- nothing is
# made larger than it was taken.  The frame is 916 points wide, which is
# 1832 pixels on a Retina screen, so it comes out at 1440 there and at
# 916 on a screen of one pixel to the point, whatever machine runs this.
# The frame is put on the display with the most pixels to the point.
# -crf 20 keeps monospaced text clean at that size; a screen is mostly
# flat colour, so a video is still a few hundred kilobytes.  The videos
# were 900 wide at -crf 30 until 2026-10-10, and their text was soft.
#
# A band of the theme's background (doom-tokyo-night's #1a1b26) is added
# below the picture.  A browser draws its controls and the subtitles over
# the bottom of a video, which is where the echo area and the mode line
# are; the band gives them somewhere else to go.  It is about 46 CSS
# pixels at the width the site shows a video: room for a control bar of
# 40 to 46 with nothing hidden, or for a line of subtitles while the
# controls are away.  With both on screen the subtitle covers the echo
# area and part of the mode line.  It was 80, which cleared both at
# once, and was taken down by two text rows of the recording at the
# user's request (2026-10-03).  The controls are a fixed CSS height, so
# the band is a share of the width, iw*58/900, rounded up to an even
# number: 94 rows at 1440 wide, 47 CSS pixels.
video_width=1440
video_crf=20

video() {
    cut
    stretch
    ffmpeg -hide_banner -loglevel error -y \
        -framerate "$fps" -pattern_type glob -i "$frames/$scene/*.png" \
        -vf "$(keep),scale=w='trunc(min($video_width,iw)/2)*2':h=-2:flags=lanczos,pad=iw:ih+2*ceil(iw*29/900):0:0:color=0x1a1b26,format=yuv420p" \
        -c:v libx264 -preset slow -crf "$video_crf" -an -movflags +faststart \
        "$videodir/$scene.mp4"
    poster
    retime
    rm -rf "${frames:?}/${scene:?}" "${frames:?}/${scene:?}".*
}

# How long a subtitle has to stay on screen to be read, in frames:
# at least 1.5 seconds, and at least 15 characters a second of its English
# or 7 of its Japanese, whichever asks for longer, since one video serves
# both tracks.  15 a second is a little under what subtitles for adults
# are usually held to, because the reader is also watching the frame;
# Japanese is read at about half the characters a second.  The scenes
# were paced for GIFs without captions, with steps of 0.3 to 1 second,
# and 113 of the cues were too short to read by this rule (2026-10-03).
readable_frames() {
    local LC_ALL=en_US.UTF-8
    local en=$1 ja=$2 ms=1500
    (( ${#en} * 1000 / 15 > ms )) && ms=$(( ${#en} * 1000 / 15 ))
    (( ${#ja} * 1000 / 7 > ms )) && ms=$(( ${#ja} * 1000 / 7 ))
    echo $(( (ms * fps + 999) / 1000 ))
}

# The text of each cue of a .vtt, one line per cue.
cue_texts() { awk 'p { print; p = 0 } / --> / { p = 1 }' "$1"; }

# Hold the last frame of each step until its subtitle can be read, by
# repeating that frame, and move the cue marks to match.  It is done to
# the frames rather than by holding longer while capturing, because the
# steps of several scenes run inside Emacs on its own timers
# (`shot-script'): a longer hold in this script would not wait for them,
# only move the cue away from the step it names.  The motion inside a
# step keeps its speed; only the still end of it grows.  A scene whose
# subtitles do not have one cue per mark is left as captured, and
# `retime' then names it.
stretch() {
    local marks="$frames/$scene.cues" out="$frames/$scene.stretched"
    local en_vtt="$videodir/$scene.en.vtt" ja_vtt="$videodir/$scene.ja.vtt"
    local -a start en ja moved
    local k i last need m=0
    [ -f "$marks" ] && [ -f "$en_vtt" ] && [ -f "$ja_vtt" ] || return 0
    mapfile -t start < "$marks"
    mapfile -t en < <(cue_texts "$en_vtt")
    mapfile -t ja < <(cue_texts "$ja_vtt")
    [ ${#start[@]} -eq ${#en[@]} ] && [ ${#en[@]} -eq ${#ja[@]} ] || return 0
    mkdir -p "$out"
    for k in "${!start[@]}"; do
        last=${start[k+1]:-$n}
        moved+=("$m")
        for (( i = start[k] + 1; i <= last; i++ )); do
            m=$((m + 1))
            ln "$(printf '%s/%s/%04d.png' "$frames" "$scene" "$i")" "$(printf '%s/%04d.png' "$out" "$m")"
        done
        need=$(readable_frames "${en[k]}" "${ja[k]}")
        (( last < 1 )) && last=1
        for (( i = $(( ${start[k+1]:-$n} - start[k] )); i < need; i++ )); do
            m=$((m + 1))
            ln "$(printf '%s/%s/%04d.png' "$frames" "$scene" "$last")" "$(printf '%s/%04d.png' "$out" "$m")"
        done
    done
    rm -rf "${frames:?}/${scene:?}"
    mv "$out" "$frames/$scene"
    printf '%s\n' "${moved[@]}" > "$marks"
    n=$m
}

# Write the first frame of the video as its poster.  It is taken from
# the mp4 rather than from the first capture so that it is the picture
# the video opens on, scaled the same.  WebP at quality 80 is a seventh
# of the size of the same frame as a PNG (2026-10-03).
poster() {
    ffmpeg -hide_banner -loglevel error -y -i "$videodir/$scene.mp4" \
        -frames:v 1 "$frames/$scene.poster.png"
    cwebp -quiet -q 80 "$frames/$scene.poster.png" -o "$videodir/$scene.webp"
    rm -f "${frames:?}/${scene:?}.poster.png"
}

# Write the times of the cue marks into the subtitles of the scene.  The
# Nth timing line of each .vtt gets the Nth mark; a file whose number of
# cues differs from the number of marks is left as it was and named, as
# the scene and its subtitles no longer agree.
retime() {
    local vtt
    [ -f "$frames/$scene.cues" ] || return 0
    for vtt in "$videodir/$scene".*.vtt; do
        [ -f "$vtt" ] || continue
        if awk -v fps="$fps" -v total="$n" '
            function ts(f,  s) {
                s = f / fps
                return sprintf("%02d:%02d:%06.3f", int(s / 3600), int(s / 60) % 60, s - int(s / 60) * 60)
            }
            NR == FNR { start[++marks] = $1; next }
            / --> / {
                if (++cues > marks) next
                print ts(start[cues]) " --> " ts(cues < marks ? start[cues + 1] : total)
                next
            }
            { print }
            END { exit cues != marks }
        ' "$frames/$scene.cues" "$vtt" > "$vtt.new"; then
            mv "$vtt.new" "$vtt"
        else
            rm -f "$vtt.new"
            echo "   $vtt: its cues and the scene's marks differ; left alone" >&2
        fi
    done
}

# Ask the frame where it is now.  The menu and the minibuffer resize it,
# and a frame that would grow past the bottom of the screen is moved.
regeom() {
    e '(shot-report-geometry)'
    read -r CX CY CW CH OW < "$geom"
}

# Capture one frame to a file of its own, at the full resolution of the
# screen: Astro scales a still for the page.
still() {
    regeom
    shoot "$1"
}

shoot() {
    "$recorder" --title "$title" --shot "$frames/shot.png" 2>&1 | grep -v "^record-window: wrote" >&2 || true
    ffmpeg -hide_banner -loglevel error -y -i "$frames/shot.png" \
        -vf "$(keep)" -frames:v 1 "$1"
    rm -f "$frames/shot.png"
}

if [ -z "$(ls "$HOME"/.claude/projects/*/"$handover_id".jsonl 2>/dev/null)" ]; then
    echo "recording the conversation the hand-off scene resumes..." >&2
    mkdir -p /tmp/records
    (cd /tmp/records && claude -p --session-id "$handover_id" \
         --model haiku --max-budget-usd 0.10 "$handover_prompt" >/dev/null)
fi

# A run that failed may have left its Emacs and its socket behind.
pkill -f 'scripts/docshots.el' 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/emacs$(id -u)/ecc-docshot"

open -n -a "$emacs_app" --args -Q --chdir "$root" \
  --eval "(setq shot-geometry-file \"$geom\" shot-error-file \"$err\" shot-frame-title \"$title\" shot-display-origin (quote ($display_x . $display_y)))" \
  -l "$root/scripts/docshots.el"

for _ in $(seq 1 30); do
    [ -f "$geom" ] && break
    [ -f "$err" ] && { echo "setup failed: $(cat "$err")" >&2; exit 1; }
    sleep 1
done
[ -f "$geom" ] || { echo "the frame never reported its geometry" >&2; exit 1; }
read -r CX CY CW CH OW < "$geom" || true

mkdir -p "$outdir" "$videodir"

if want switch; then
    # 1. Switching a window from one session to another.  A scene has to
    # keep changing or the extra seconds buy nothing: type a letter at a
    # time, and go back the way it came rather than holding the last
    # picture.  The sequence runs inside Emacs, so its long hold is cut
    # where shot-scene-switch-sequence opens the picker (0.5s), presses
    # RET (4.2s), opens it again (6.0s) and presses RET again (9.1s).
    scene switch
    cue; e '(shot-scene-switch-start)'      ; hold 0.67
    e '(shot-scene-switch-sequence)'
    hold 0.5; cue; hold 3.7; cue; hold 1.8; cue; hold 3.1; cue; hold 1.9
    video
    e '(shot-scene-switch-end)'
fi

if want menu; then
    # 2. The menu, open over a session.
    e '(shot-scene-menu)'           ; sleep 3; still "$outdir/menu.png"
    e '(shot-scene-quit)'           ; sleep 1
fi

# The four scenes below are answered by the model, so they need a session
# that really runs.  It is started once, whichever of them is being taken.
if want send-region || want fix-error || want inline || want rewrite \
       || want at-cursor || want context || want image || want btw; then
    e '(shot-start-live)'               ; sleep 4
fi

if want send-region; then
    # 3. Sending the region from a source buffer.  This one runs the real
    # CLI: the point of the picture is the answer coming back.
    scene send-region
    cue; e '(shot-scene-send-region-point)'  ; hold 0.67
    e '(shot-scene-send-region-mark)'   ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.67
    cue; e '(shot-scene-send-region-sequence)'
    # The typing and then the answer streaming in are the motion, so the
    # frames are taken while they happen rather than after.  The question
    # is sent at 4.2s, and the answer starts a few seconds later.
    hold 4.4; cue; hold 2.6; cue; hold 10
    video
    e '(shot-dump-live-log)'
fi

if want fix-error; then
    # 4. Fixing the error a checker found.  The file really is broken and
    # the checker really is run; only the checker is the standard library
    # rather than something installed.
    scene fix-error
    cue; e '(shot-scene-fix-error-open)'     ; sleep 3; hold 1
    e '(shot-scene-fix-error-point)'    ; hold 0.67
    cue; e '(shot-scene-fix-error)'          ; hold 0.67
    hold 1.5; cue; hold 4; cue; hold 4.5
    # Allowing it is part of the scene: the edit is made, the buffer picks
    # it up, and the checker has nothing left to complain about.  It also
    # leaves nothing waiting, which would blink through every picture taken
    # after this one.
    cue; e '(shot-scene-allow)'              ; sleep 1; hold 0.67
    hold 8
    cue; e '(shot-scene-recheck)'            ; sleep 2; hold 1.33
    video
fi

if want inline; then
    # 5. Asking about the region and being answered where the code is.
    scene inline
    cue; e '(shot-scene-send-region-point)'  ; hold 0.33
    e '(shot-scene-send-region-mark)'   ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.67
    cue; e '(shot-scene-inline-sequence)'
    # The question is sent at 3.0s, and the answer took about eleven
    # seconds to come back (2026-10-10).
    hold 3.2; cue; hold 9.8; cue; hold 8
    video
fi

if want rewrite; then
    # 6. Rewriting the region, and accepting what comes back.
    scene rewrite
    cue; e '(shot-scene-send-region-point)'  ; hold 0.33
    e '(shot-scene-send-region-mark)'   ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.33
    e '(shot-scene-send-region-extend)' ; hold 0.67
    cue; e '(shot-scene-rewrite-sequence)'
    # The instruction is sent at 3.0s.
    hold 3.2; cue; hold 2.8; cue; hold 8
    cue; e '(shot-scene-accept)'             ; sleep 1; hold 1.33
    video
fi

if want at-cursor; then
    # An @ reference: the point stands in the source, the prompt says
    # @cursor, and what is sent carries the line it was on.
    scene at-cursor
    cue; e '(shot-scene-cursor-point 11)'          ; hold 0.67
    cue; e '(shot-prompt-type "Can ")'            ; hold 0.33
    e '(shot-prompt-type "@cursor")'         ; hold 0.33
    e '(shot-prompt-type " give an empty field?")' ; hold 0.67
    cue; e '(shot-prompt-send)'                   ; hold 0.67
    hold 4.5; cue; hold 7.5
    video
fi

if want context; then
    # The editor context, attached to every prompt while it is on.
    scene context
    cue; e '(shot-scene-cursor-point 20)'                                 ; hold 0.67
    cue; e '(shot-prompt-command (quote ecc-prompt-toggle-context))'      ; hold 1
    cue; e '(shot-prompt-type "Where am I?")'                             ; hold 0.67
    e '(shot-prompt-send)'                                           ; hold 0.67
    hold 4; cue; hold 8
    cue; e '(shot-prompt-command (quote ecc-prompt-toggle-context))'      ; hold 0.67
    video
fi

if want image; then
    # An image in a prompt.  It goes by path rather than inline, so the
    # picture is opened beside the session first: without it the scene
    # is one line of text appearing in the prompt region.  The session
    scene image
    cue; e '(shot-scene-image-open)'                             ; hold 1
    cue; e '(shot-scene-insert-image)'                           ; hold 1
    cue; e '(shot-prompt-type "What is in this image? One line.")'; hold 0.67
    e '(shot-prompt-send)'                                  ; hold 0.67
    hold 1.5; cue; hold 10.5
    video
fi

if want suggestion; then
    # The prompt the CLI offers, and C-c C-s taking it.  This one has a
    # session of its own: the model the settings name sends suggestions
    # and haiku does not, so the other scenes' session cannot be used.
    e '(shot-start-live-default)' ; sleep 5
    # Two turns: no suggestion came after one of them, and the CLI
    # offered one after the second (confirmed 2026-09-11).
    e '(shot-prompt-type "Read reader.py and say in one line what it does.")'
    e '(shot-prompt-send)'  ; sleep 30
    e '(shot-prompt-type "Good. What next?")'
    e '(shot-prompt-send)'
    # A suggestion arrives when the CLI has one to offer, so this asks
    # until it does rather than sleeping a fixed time.
    for _ in $(seq 1 45); do
        sleep 2
        if "$emacsclient" -s ecc-docshot -e '(shot-suggestion-p)' 2>/dev/null | grep -q t; then
            break
        fi
    done
    scene suggestion
    cue; hold 1
    cue; e '(shot-prompt-command (quote ecc-hint-accept-suggestion))' ; hold 1.33
    cue; e '(shot-prompt-send)'                                       ; hold 0.67
    hold 0.5; cue; hold 13.5
    video
fi

if want btw; then
    # A question asked beside a turn that is running, answered without
    # interrupting it.
    scene btw
    cue; e '(shot-scene-btw-turn)'   ; hold 0.67
    hold 3
    cue; e '(shot-scene-btw-sequence (list "does " "read_records " "skip comments?"))'
    # The question is sent at 3.6s.
    hold 3.8; cue; hold 2.6
    hold 10
    video
    # The answer floats in a posframe, and a posframe outlives every
    # window command: without this it lies over every scene after it.
    e '(shot-scene-btw-end)'
fi

if want capabilities; then
    # What the session can do: the list the CLI reported in system/init.
    scene capabilities
    cue; e '(shot-scene-capabilities)'                        ; sleep 1; hold 1.33
    cue; e '(shot-scene-capabilities-toggle "Slash commands")'; hold 1
    e '(shot-scene-capabilities-toggle "Skills")'        ; hold 1
    e '(shot-scene-capabilities-toggle "Agents")'        ; hold 1
    e '(shot-scene-capabilities-toggle "Skills")'        ; hold 1.33
    video
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
    # minibuffer here, so each step is one call and a hold of its own.
    # It comes first because the scene after it leaves a picker on the
    # screen.
    scene fold
    cue; e '(shot-scene-fold-start)'                         ; hold 0.67
    cue; e '(shot-scene-fold (quote ecc-chat-collapse-all))' ; hold 1
    cue; e '(shot-scene-fold (quote ecc-chat-show-level-2))' ; hold 0.67
    e '(shot-scene-fold (quote ecc-chat-show-level-3))' ; hold 0.67
    cue; e '(shot-scene-fold (quote ecc-chat-next-heading))' ; hold 0.33
    e '(shot-scene-fold (quote ecc-chat-next-heading))' ; hold 0.33
    cue; e '(shot-scene-fold (quote ecc-chat-toggle))'       ; hold 1
    e '(shot-scene-fold (quote ecc-chat-toggle))'       ; hold 1
    cue; e '(shot-scene-fold (quote ecc-chat-expand-all))'   ; hold 1
    video

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
    cue; e '(shot-scene-permission)'        ; sleep 1; hold 1
    cue; e '(shot-scene-permission-allow)'  ; hold 0.67
    cue; e '(shot-scene-permission-finish)' ; sleep 1; hold 1.33
    video
fi

if want question; then
    scene question
    cue; e '(shot-scene-question)'            ; sleep 1; hold 1
    cue; e '(shot-scene-question-open)'       ; sleep 1; hold 1
    cue; e '(shot-scene-question-choose 1)'   ; hold 0.67
    cue; e '(shot-scene-question-choose 1)'   ; hold 0.67
    e '(shot-scene-question-choose 2)'   ; hold 1
    cue; e '(shot-scene-question-submit)'     ; sleep 1; hold 1.33
    video
fi

if want review; then
    # Every change of the session as one diff, a comment on a line, and
    # the prompt that would go out.
    scene review
    cue; e '(shot-scene-review)'        ; sleep 1; hold 1
    cue; e '(shot-scene-review-comment (list "what about " "two trailing " "commas?"))'
    hold 4.8
    cue; e '(shot-scene-review-hunk)'   ; hold 1
    cue; e '(shot-scene-review-send)'   ; sleep 1; hold 1.67
    video
fi

if want proposal; then
    # The text of a proposal, changed before it is allowed.
    scene proposal
    cue; e '(shot-scene-proposal)'       ; sleep 1; hold 1
    cue; e '(shot-scene-proposal-edit)'  ; sleep 1; hold 1
    cue; e '(shot-scene-proposal-type "\n\n\ndef test_parse_line_empty():\n")' ; hold 0.33
    e '(shot-scene-proposal-type "    assert parse_line(\"\") == []\n")' ; hold 1
    cue; e '(shot-scene-proposal-apply)' ; sleep 1; hold 1.33
    video
fi

if want plan; then
    # A plan, a comment on one of its lines, the mode it would be
    # approved into, and C-c C-c -- which, with a comment there, sends
    # the plan back with it rather than approving it.
    scene plan
    cue; e '(shot-scene-plan)'               ; sleep 1; hold 1.33
    cue; e '(shot-scene-plan-comment 4 (list "make strict " "keyword-" "only"))'
    hold 4.8
    hold 0.67
    cue; e '(shot-scene-plan-mode-sequence)'
    hold 3.6
    cue; e '(shot-scene-plan-approve)'       ; sleep 1; hold 1.33
    video
fi

if want files; then
    # The Files section: a row unfolded, then reviewed on its own.
    scene files
    cue; e '(shot-scene-files)'                                  ; sleep 1; hold 1
    e '(shot-scene-files-key (quote ecc-chat-next-heading))'; hold 0.67
    cue; e '(shot-scene-files-key (quote ecc-chat-toggle))'      ; hold 1.33
    cue; e '(shot-scene-files-key (quote ecc-session-review-file))' ; sleep 1; hold 1.33
    video
fi

if want timeline; then
    # The turn picker.  Last of the replayed scenes: it leaves a
    # minibuffer on the screen, as the resume picker does.
    e '(shot-scene-timeline)' ; sleep 3; still "$outdir/timeline.png"
    e '(shot-scene-quit)'     ; sleep 1
fi

if want usage; then
    # What the plan has been used for.  The answer is a fixture's, so
    # nobody's own numbers go into it.
    e '(shot-scene-usage)'      ; sleep 2; still "$outdir/usage.png"
    e '(shot-scene-usage-hide)' ; sleep 1
fi

if want handover; then
    # 7. Handing a session over to the terminal.  The CLI is the real one,
    # resuming a conversation recorded in the demo project, so this scene
    # needs `claude' and a recording it can find.
    e '(shot-scene-quit)'           ; sleep 1

    scene handover
    cue; e '(shot-scene-handover-start)' ; sleep 1; hold 1
    cue; e '(shot-scene-handover)'       ; hold 0.33
    # The CLI drawing itself is the motion here, so the frames are taken
    # while it comes up rather than after.
    hold 1.2; cue; hold 8.8
    video
fi

if want resume; then
    # The picker of `ecc-resume' is last: it stays on screen, and a
    # minibuffer with a completion UI over it does not reliably take a `C-g'
    # fed to it from the server.
    e '(shot-scene-resume)'         ; sleep 3; still "$outdir/resume.png"

fi

if want usecase; then
    # The use-case page: going to a project that has only recordings, as
    # a video, and the Space a worktree hand-off leaves, as a still.
    # The start scene resizes and moves the frame, so the rectangle is
    # measured after it rather than before: `scene' asks for the geometry
    # as it stands, and taking it first caught the screen behind the
    # frame (2026-09-18).
    e '(shot-scene-usecase-start)'   ; sleep 1
    scene usecase-goto
    cue; hold 1
    e '(shot-scene-usecase-goto)'
    # The picker opens at 0.5s, and RET is pressed at 4.4s.
    hold 0.5; cue; hold 3.9; cue; hold 3.6
    video
    e '(shot-scene-quit)' ; sleep 1
    e '(shot-scene-usecase-worktree)' ; sleep 2; still "$outdir/usecase-worktree.png"
    e '(shot-scene-usecase-end)' ; sleep 1
fi

if want sidebar; then
    # The sidebar on its own, close up: several Spaces with two worktrees
    # under one of them, and a session waiting for an answer.  The
    # rectangle captured is the sidebar window rather than the frame.
    e '(shot-scene-sidebar)' ; sleep 2
    e '(shot-report-sidebar-geometry)'
    read -r CX CY CW CH OW < "$geom"
    shoot "$outdir/sidebar.png"
    e '(shot-scene-sidebar-end)' ; sleep 1
fi

if want spaces; then
    # The Spaces, as one still: the sidebar down the left, a tab for each
    # project across the top, and this project's source with its two
    # transcripts beside it.  It comes late because it widens the frame
    # and leaves a tab bar and a sidebar behind, both of which the
    # scene's own end takes away again.
    e '(shot-scene-spaces)' ; sleep 2; still "$outdir/spaces.png"
    e '(shot-scene-spaces-end)' ; sleep 1
fi

# Last, because it is the one scene that changes the type and the size
# of the frame.  Both the site's front page and README.md carry it, and
# README.md reads it from docs/images like the other two there.
if want overview; then
    # This one goes to two fixed places rather than into $outdir: the
    # site's front page carries it in its hero, where Starlight would
    # squash an image under src/assets into a 400x400 square, so it is
    # served from public/ as it is; README.md reads the copy in
    # docs/images beside the other two.
    e '(shot-scene-overview)' ; sleep 2
    mkdir -p "$root/docs/site/public" "$root/docs/images"
    still "$root/docs/site/public/overview.png"
    cp "$root/docs/site/public/overview.png" "$root/docs/images/overview.png"
    e '(shot-scene-overview-end)'
fi

# A module is loaded when a scene first needs it, so the check that
# every ecc file came from this checkout is made again at the end.
foreign=$(timeout 25 "$emacsclient" -s ecc-docshot -e '(shot-foreign-ecc)' 2>/dev/null || echo unknown)
if [ "$foreign" != nil ]; then
    echo "not this checkout's ecc: $foreign" >&2
    exit 1
fi

echo "wrote the pictures of ${SCENES:-every scene} from $root into $outdir and $videodir"
