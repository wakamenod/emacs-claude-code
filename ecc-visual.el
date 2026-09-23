;;; ecc-visual.el --- Spinners, pulses and icons for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The movement the terminal client gets for free and a buffer of text
;; does not.  A spinner while a turn runs, a pulsing background under
;; the tool that is running, a blinking line where an answer is wanted,
;; a flash when something finishes, and an icon per tool.
;;
;; Every effect is a timer over an overlay, and every one of them can be
;; turned off by itself.  Two rules keep them from becoming a cost: at
;; most `ecc-visual-max-effects' overlays move at a time, and a timer
;; whose buffer is not on screen stops itself.
;;
;; This module knows nothing about the model or the renderer; it is
;; given overlays and buffers.  `ecc-render' is what decides which line
;; deserves which effect.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'pulse)
(require 'ecc-core)

(defvar ecc-visual-enable-spinner t
  "Non-nil turns the spinner of a running turn.")

(defvar ecc-visual-enable-pulse t
  "Non-nil pulses the background of a running tool or agent.")

(defvar ecc-visual-enable-blink t
  "Non-nil blinks the line of a request waiting for an answer.")

(defvar ecc-visual-enable-icons t
  "Non-nil puts an icon in front of a tool name.")

(defvar ecc-visual-enable-flash t
  "Non-nil flashes a section that has just finished.")

(defvar ecc-visual-max-effects 4
  "Most overlays that may be animated at one time.
The effects exist to draw the eye; more than a few of them at once do
the opposite, and each one is a timer.")

(defvar ecc-visual-spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the spinner, in order.")

(defvar ecc-visual-spinner-interval 0.1
  "Seconds between two frames of the spinner.")

(defvar ecc-visual-pulse-interval 0.08
  "Seconds between two steps of a pulsing background.")

(defvar ecc-visual-pulse-period 1.6
  "Seconds a pulsing background takes to go and come back.")

(defvar ecc-visual-pulse-color "#3a5f3a"
  "Colour a pulsing background travels towards.")

(defvar ecc-visual-pulse-depth 0.6
  "How far towards `ecc-visual-pulse-color' a pulse goes, from 0 to 1.")

(defvar ecc-visual-blink-interval 0.6
  "Seconds between two states of a blinking line.")

(defface ecc-visual-blink-face
  '((t :inherit ecc-pending-face :inverse-video t))
  "Face a blinking line takes on every other tick."
  :group 'ecc)

(defface ecc-visual-pulse-face
  '((t :inherit highlight))
  "Face used for a pulse when the colours cannot be blended.
A terminal that cannot name its background colour gets a plain
highlight rather than nothing."
  :group 'ecc)

;;;; A timer that repeats

(defvar ecc-visual-repeat-overruns 2
  "Ticks in a row that may outlast their interval before the timer stops.
One is forgiven: a tick that happened to hold a pause of the display or
a slow disk is no sign of a tick that cannot keep up.")

(defun ecc-visual-repeat (interval switch function &rest args)
  "Call FUNCTION with ARGS every INTERVAL seconds, or stop when it cannot keep up.
Returns the timer.  A tick that takes longer than INTERVAL -- the time
Emacs spent collecting garbage inside it left out -- for
`ecc-visual-repeat-overruns' ticks running cancels the timer and sets
SWITCH, the variable that turns the effect on, to nil, so that nothing
starts it again in this Emacs; a message says which one went and why.

Every repeating timer of this package goes through here, because a
tick slower than its interval takes Emacs down with it: keyboard.c
`timer_check' runs timers for as long as one is due, a timer runs with
`inhibit-quit' bound, and `timer-event-handler' puts a repeat timer
that is late back into the past, so a late tick is due again the moment
it ends and Emacs never returns to its input -- not to a key, not to
`C-g', not to emacsclient.  The sidebar's tick took 0.39 s on a 0.2 s
timer in an Emacs that had not collected garbage for 27 hours, and the
whole of Emacs stood still until a SIGUSR2 broke the tick (measured
2026-09-21).  An effect that cannot keep up is worth less than an Emacs
that answers."
  (let ((late 0) (timer nil))
    (setq timer
          (run-at-time
           interval interval
           (lambda ()
             (let ((start (float-time))
                   (collected gc-elapsed))
               (apply function args)
               (if (<= (- (float-time) start (- gc-elapsed collected)) interval)
                   (setq late 0)
                 (setq late (1+ late))
                 (when (>= late ecc-visual-repeat-overruns)
                   (cancel-timer timer)
                   (set switch nil)
                   (ecc-log "visual" "%s stopped: %s took longer than %.2fs, %d ticks running"
                            switch function interval late)
                   (message "ecc: %s set to nil, its tick took longer than %.2fs %d times running"
                            switch interval late)))))))
    timer))

;;;; The spinner

(defvar ecc-visual--tick 0
  "Number of spinner frames shown since Emacs started.")

(defvar ecc-visual--spinner-timers (make-hash-table :test #'eq)
  "Hash of a buffer to the spinner timer running for it.")

(defun ecc-visual-spinner-frame ()
  "Return the frame of the spinner for this moment."
  (let ((frames ecc-visual-spinner-frames))
    (if (zerop (length frames))
        ""
      (aref frames (mod ecc-visual--tick (length frames))))))

(defun ecc-visual-spinner-string (&optional face)
  "Return the current spinner frame in FACE, or nothing when it is off.
The frame carries the property `ecc-spinner', which is what
`ecc-visual-spinner-refresh' looks for once the frame is in a buffer."
  (if ecc-visual-enable-spinner
      (propertize (ecc-visual-spinner-frame) 'face (or face 'ecc-pending-face)
                  'ecc-spinner t)
    ""))

(defun ecc-visual-spinner-start (buffer)
  "Turn the spinner of BUFFER, redrawing its mode and header lines.
One timer per buffer; asking again while it turns changes nothing."
  (when (and ecc-visual-enable-spinner (buffer-live-p buffer)
             (not (gethash buffer ecc-visual--spinner-timers)))
    (puthash buffer
             (ecc-visual-repeat ecc-visual-spinner-interval 'ecc-visual-enable-spinner
                                #'ecc-visual--spinner-tick buffer)
             ecc-visual--spinner-timers)))

(defun ecc-visual-spinner-stop (buffer)
  "Stop the spinner of BUFFER."
  (when-let* ((timer (gethash buffer ecc-visual--spinner-timers)))
    (cancel-timer timer)
    (remhash buffer ecc-visual--spinner-timers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (force-mode-line-update)))))

(defun ecc-visual-spinner-running-p (buffer)
  "Return non-nil when the spinner of BUFFER is turning."
  (and (gethash buffer ecc-visual--spinner-timers) t))

(defun ecc-visual-spinner-advance ()
  "Move the spinner on to its next frame.
The frame is the same wherever it is drawn, so whoever turns it -- the
timer of a session buffer, or the dashboard drawing its list again --
moves every spinner on screen along with it."
  (cl-incf ecc-visual--tick))

(defun ecc-visual-spinner-refresh (buffer)
  "Draw the current frame over every spinner in BUFFER and touch nothing else.
A spinner is a run of text carrying `ecc-spinner', as
`ecc-visual-spinner-string' makes it; the run is replaced by the frame
with the properties it had, and point and the windows stay where they
were.  This is what a tick does to a list, rather than drawing the list
again: every insertion and deletion walks the whole chain of markers
of the buffer, so a redraw of twenty rows costs twenty-odd walks of a
chain that other packages -- winner, tab-bar-history, anything that
saves match data -- lengthen with every command, and once the walks
outlast the timer's interval Emacs stops answering, as
`ecc-visual-repeat' says."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((frame (ecc-visual-spinner-frame))
            (inhibit-read-only t)
            (inhibit-modification-hooks t)
            (buffer-undo-list t)
            (pos (point-min)))
        (unless (string-empty-p frame)
          (save-excursion
            (while (setq pos (text-property-not-all pos (point-max) 'ecc-spinner nil))
              (let ((end (or (next-single-property-change pos 'ecc-spinner)
                             (point-max)))
                    (props (text-properties-at pos)))
                (unless (equal (buffer-substring-no-properties pos end) frame)
                  (goto-char pos)
                  (insert (apply #'propertize frame props))
                  (delete-region (point) (+ (point) (- end pos))))
                (setq pos (+ pos (length frame)))))))))))

(defun ecc-visual--spinner-tick (buffer)
  "Advance the spinner and redraw BUFFER, or stop when there is no point.
A buffer nobody is looking at is not worth a timer ten times a second."
  (if (not (and (buffer-live-p buffer) (get-buffer-window buffer t)))
      (ecc-visual-spinner-stop buffer)
    (cl-incf ecc-visual--tick)
    (with-current-buffer buffer
      (force-mode-line-update))))

;;;; Overlay effects (c)

(defvar ecc-visual--effects nil
  "Overlays being animated, newest first.")

(defun ecc-visual-effects ()
  "Return the overlays being animated."
  ecc-visual--effects)

(defun ecc-visual-stop-overlay (overlay)
  "Stop the effect on OVERLAY and take its face back off."
  (when-let* ((timer (overlay-get overlay 'ecc-visual-timer)))
    (cancel-timer timer))
  (overlay-put overlay 'ecc-visual-timer nil)
  (overlay-put overlay 'face nil)
  (setq ecc-visual--effects (delq overlay ecc-visual--effects)))

(defun ecc-visual-clear-effects (&optional buffer)
  "Stop every effect, or every effect of BUFFER, and delete its overlays."
  (dolist (overlay (copy-sequence ecc-visual--effects))
    (when (or (null buffer) (eq (overlay-buffer overlay) buffer))
      (ecc-visual-stop-overlay overlay)
      (delete-overlay overlay))))

(defun ecc-visual--register (overlay)
  "Start counting OVERLAY as an effect, stopping the oldest over the limit."
  (push overlay ecc-visual--effects)
  (while (> (length ecc-visual--effects) (max 0 ecc-visual-max-effects))
    (let ((oldest (car (last ecc-visual--effects))))
      (ecc-visual-stop-overlay oldest)
      (delete-overlay oldest))))

(defun ecc-visual--animate (overlay interval switch tick)
  "Run TICK on OVERLAY every INTERVAL seconds until it is stopped.
SWITCH is the variable that turns this effect on, which a tick that
cannot keep up turns off (`ecc-visual-repeat')."
  (ecc-visual-stop-overlay overlay)
  (overlay-put overlay 'ecc-visual-phase 0)
  (funcall tick overlay)
  (overlay-put overlay 'ecc-visual-timer
               (ecc-visual-repeat interval switch #'ecc-visual--tick-overlay
                                  overlay tick))
  (ecc-visual--register overlay)
  overlay)

(defun ecc-visual--tick-overlay (overlay tick)
  "Advance OVERLAY with TICK, or stop when there is nothing to show.
An overlay whose buffer is gone, or is not on screen, costs nothing
once its timer is cancelled."
  (let ((buffer (overlay-buffer overlay)))
    (if (not (and buffer (buffer-live-p buffer) (get-buffer-window buffer t)))
        (ecc-visual-stop-overlay overlay)
      (overlay-put overlay 'ecc-visual-phase
                   (1+ (or (overlay-get overlay 'ecc-visual-phase) 0)))
      (funcall tick overlay))))

(defun ecc-visual-blend (from to ratio)
  "Return the colour RATIO of the way from FROM to TO, or nil.
Nil comes back when either colour cannot be resolved, which is what a
terminal without colours says."
  (let ((a (color-name-to-rgb from))
        (b (color-name-to-rgb to)))
    (when (and a b)
      (apply #'color-rgb-to-hex
             (append (cl-mapcar (lambda (x y) (+ x (* ratio (- y x)))) a b)
                     (list 2))))))

(defun ecc-visual--pulse-background (phase &optional background)
  "Return the background colour of a pulse at PHASE, or nil.
BACKGROUND is what the colour travels from, the background of the
default face by default; a display that cannot name it, such as a
batch Emacs, gets nil and a plain face instead.  The ratio follows a
cosine, so the colour arrives and leaves smoothly rather than jumping
at the ends."
  (let* ((steps (max 1 (round (/ ecc-visual-pulse-period
                                 (max 0.01 ecc-visual-pulse-interval)))))
         (angle (* 2 float-pi (/ (float (mod phase steps)) steps)))
         (ratio (* ecc-visual-pulse-depth (/ (- 1.0 (cos angle)) 2.0))))
    (ecc-visual-blend (or background (face-background 'default nil 'default))
                      ecc-visual-pulse-color ratio)))

(defun ecc-visual--pulse-tick (overlay)
  "Give OVERLAY the background of its current phase."
  (let ((color (ecc-visual--pulse-background
                (or (overlay-get overlay 'ecc-visual-phase) 0))))
    (overlay-put overlay 'face
                 (if color (list :background color) 'ecc-visual-pulse-face))))

(defun ecc-visual-pulse-overlay (overlay)
  "Pulse the background of OVERLAY while a tool runs."
  (if (not ecc-visual-enable-pulse)
      overlay
    (ecc-visual--animate overlay ecc-visual-pulse-interval
                         'ecc-visual-enable-pulse #'ecc-visual--pulse-tick)))

(defun ecc-visual--blink-tick (overlay)
  "Turn OVERLAY on or off according to its phase."
  (overlay-put overlay 'face
               (and (cl-oddp (or (overlay-get overlay 'ecc-visual-phase) 0))
                    'ecc-visual-blink-face)))

(defun ecc-visual-blink-overlay (overlay)
  "Blink OVERLAY while an answer is wanted."
  (if (not ecc-visual-enable-blink)
      overlay
    (ecc-visual--animate overlay ecc-visual-blink-interval
                         'ecc-visual-enable-blink #'ecc-visual--blink-tick)))

;;;; The flash of something finishing

(defun ecc-visual-flash-region (start end)
  "Flash the text between START and END once."
  (when (and ecc-visual-enable-flash (display-graphic-p))
    (pulse-momentary-highlight-region start end)
    t))

;;;; Icons

(defvar ecc-visual-icon-alist
  '(("Read"            "nf-cod-book"          "R" ecc-icon-read-face)
    ("NotebookRead"    "nf-cod-notebook"      "R" ecc-icon-read-face)
    ("Write"           "nf-cod-new_file"      "W" ecc-icon-write-face)
    ("Edit"            "nf-cod-edit"          "✎" ecc-icon-write-face)
    ("NotebookEdit"    "nf-cod-notebook"      "✎" ecc-icon-write-face)
    ("Bash"            "nf-cod-terminal"      "$" ecc-icon-shell-face)
    ("BashOutput"      "nf-cod-terminal"      "$" ecc-icon-shell-face)
    ("KillShell"       "nf-cod-terminal"      "$" ecc-icon-shell-face)
    ("Glob"            "nf-cod-search"        "*" ecc-icon-search-face)
    ("Grep"            "nf-cod-search"        "/" ecc-icon-search-face)
    ("Task"            "nf-cod-organization"  "@" ecc-icon-agent-face)
    ("Agent"           "nf-cod-organization"  "@" ecc-icon-agent-face)
    ("WebFetch"        "nf-cod-globe"         "⇩" ecc-icon-web-face)
    ("WebSearch"       "nf-cod-globe"         "?" ecc-icon-web-face)
    ("TodoWrite"       "nf-cod-checklist"     "☑" ecc-icon-task-face)
    ("AskUserQuestion" "nf-cod-question"      "?" ecc-icon-task-face)
    ("ExitPlanMode"    "nf-cod-checklist"     "▸" ecc-icon-task-face)
    ("Skill"           "nf-cod-star"          "★" ecc-icon-task-face))
  "Icon of each tool: (TOOL-NAME NERD-ICON-NAME ASCII FACE).
The nerd icon is used when `nerd-icons' is installed and the ASCII
stand-in on every other display, so the transcript reads the same
either way.  The faces carry a background as well as a foreground, so
that the icon reads as a small badge.

This was two tables until 2026-09-10, one for the glyphs and one for
the faces, and a tool could be in one and not the other: `NotebookRead'
and `KillShell' had a colour and no glyph.  One table cannot fall out
of step with itself.  A tool that is not here at all gets
`ecc-visual-default-icon' and `ecc-icon-face'.")

(defconst ecc-visual-default-icon '("nf-cod-tools" "·" ecc-icon-face)
  "Icon for a tool that is not in `ecc-visual-icon-alist'.")

(defun ecc-visual-icon-entry (tool-name)
  "Return the (NERD-ICON ASCII FACE) of TOOL-NAME, or the default."
  (or (cdr (assoc (or tool-name "") ecc-visual-icon-alist))
      ecc-visual-default-icon))

(defun ecc-visual-icon-face (tool-name)
  "Return the face the icon of TOOL-NAME is drawn in."
  (nth 2 (ecc-visual-icon-entry tool-name)))

(declare-function nerd-icons-codicon "nerd-icons" (name &rest args))

(defvar ecc-visual--nerd-icons 'unknown
  "Whether `nerd-icons' is available: t, nil, or `unknown' before looking.")

(defun ecc-visual-nerd-icons-p ()
  "Return non-nil when `nerd-icons' can be used, loading it once."
  (when (eq ecc-visual--nerd-icons 'unknown)
    (setq ecc-visual--nerd-icons
          (and (require 'nerd-icons nil t) (fboundp 'nerd-icons-codicon) t)))
  ecc-visual--nerd-icons)

(defun ecc-visual-icon (tool-name)
  "Return the icon of TOOL-NAME, or the empty string when icons are off.
A nerd icon is used when the font is there and an ASCII stand-in when it
is not, so the transcript reads the same either way.  Either one is
drawn in the face of its group (`ecc-visual-icon-face\='), which gives
it a background of its own."
  (if (not ecc-visual-enable-icons)
      ""
    (let* ((entry (ecc-visual-icon-entry tool-name))
           (face (nth 2 entry))
           (glyph (and (ecc-visual-nerd-icons-p)
                       (condition-case nil
                           (nerd-icons-codicon (nth 0 entry) :face face)
                         (error nil)))))
      (or glyph (propertize (nth 1 entry) 'face face)))))

(provide 'ecc-visual)

;;; ecc-visual.el ends here
