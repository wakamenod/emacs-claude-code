#!/usr/bin/env bash
# Take the session screenshot of docs/images/session.png.
#
#   scripts/screenshot.sh [out.png]
#
# Opens a throwaway GUI Emacs, replays two recorded fixtures through the
# real dispatch and renderer, sizes the frame, and captures just that
# window.  No CLI and no network are involved, so the picture is
# reproducible and costs nothing.
#
# macOS only: it needs `screencapture', and the terminal running this
# needs Screen Recording permission (System Settings -> Privacy &
# Security -> Screen Recording), or screencapture reports
# "could not create image from display".
set -euo pipefail

out=${1:-docs/images/session.png}
emacs_app=${EMACS_APP:-/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app}
root=$(cd "$(dirname "$0")/.." && pwd)
geom=$(mktemp -t ecc-shot-geom)
err=$(mktemp -t ecc-shot-err)
rm -f "$geom" "$err"

# `open' does not pass the environment on, so the paths go in as Lisp.
open -n -a "$emacs_app" --args -Q --chdir "$root" \
  --eval "(setq shot-geometry-file \"$geom\" shot-error-file \"$err\")" \
  -l "$root/scripts/screenshot.el"

for _ in $(seq 1 30); do
    [ -f "$geom" ] && break
    [ -f "$err" ] && { echo "frame setup failed: $(cat "$err")" >&2; exit 1; }
    sleep 1
done
[ -f "$geom" ] || { echo "the frame never reported its geometry" >&2; exit 1; }

read -r x y w h _cols _lines < "$geom" || true
# `frame-position' on macOS is the outer window, title bar included, so
# the frame rectangle is exactly what should be captured.
screencapture -x -R"$x,$y,$w,$h" "$out"
pkill -f 'scripts/screenshot.el' || true
rm -f "$geom" "$err"
echo "wrote $out"
