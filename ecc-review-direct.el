;;; ecc-review-direct.el --- Reading an ediff review in its two windows  -*- lexical-binding: t; -*-

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

;; ediff keeps its keys in the control panel, and a window of the two
;; sides has none of them: the keyboard had to be in the panel, where
;; there is no line of the files to stand on, so c could only be about a
;; whole difference, and what was read was not what was acted on.  The
;; two buffers of an ediff review are this package's own and read-only,
;; so they can carry the keys themselves:
;;
;; - `ecc-review-direct-mode' is on in both.  Its keys are those of the
;;   control panel, looked up in the panel's keymap and run in the
;;   control buffer, the way ediff's commands expect to be run; the
;;   keyboard stays in the window they were typed in.  c, x and RET are
;;   the windows' own: c comments on the line at point -- the old side
;;   on the left, the new on the right, as the diff review does -- x
;;   removes the comments of that line first, and RET opens the file.
;;   (d is the diff review's key for that; here d and u scroll the
;;   reply pane, `ecc-review-talk.el'.)
;;   The review opens with the keyboard in the right window; the header
;;   lines show the keys and where the review is, and the panel is out
;;   of sight but for the help ? shows (`ecc-review-ediff.el').
;;
;; - Point drives the review.  After a command in either window, a
;;   difference that point has gone into becomes the current one: its
;;   colour, its bar and its number, and nothing scrolled -- ediff's own
;;   select lays both windows out again, which would move the one being
;;   read.  The other window is put at the line that stands against
;;   point, at the same height.  In the lines both sides share, it is
;;   found from the difference above, the lines between being the same;
;;   the current difference stays what it was, so that what the panel
;;   says and c in the panel are still about the one last read, and n
;;   and p go from point to the difference below or above it.  An
;;   isearch is followed when it stops on a match and when it ends, not
;;   at every character typed; n, p, j, { and } move both windows the
;;   way ediff does.
;;
;; - Scrolling one window alone -- C-v, M-v, the wheel -- is not
;;   followed (2026-10-02, to be decided once it has been used): v and V
;;   scroll both, and C-l or the next move puts them together again.
;;
;; - RET opens the file the line is in, at that line as the file is now:
;;   the review may be of commits the files have moved on from, or of a
;;   working tree that has changed since it was read, so the line is
;;   carried through what changed in between (`ecc-visit-shift-through').
;;   A line of the left side opens where it stands now -- a line taken
;;   out, where it was.  The file goes in a frame of its own, the same
;;   one each time, and the review is left as it is
;;   (`ecc-review-direct--file-window' is the one place that says so).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ediff)
(require 'ecc-core)
(require 'ecc-diff)
(require 'ecc-review)
(require 'ecc-review-files)
(require 'ecc-visit)

;; `ecc-review-ediff.el' requires this file, so these are declared
;; rather than required: they are only ever reached from a review that
;; file opened.
(defvar ecc-review-ediff--buffers)
(defvar ecc-review-ediff--sections)
(declare-function ecc-review-ediff--section-texts "ecc-review-ediff" (buffer sections index))
(declare-function ecc-review-ediff--file-place "ecc-review-ediff" (side position))
(declare-function ecc-review-ediff--unit-lines "ecc-review-ediff" (unit))
(declare-function ecc-review-ediff-select-in-place "ecc-review-ediff" (n &optional flag))
(declare-function ecc-review-ediff-remove-comment "ecc-review-ediff" (&optional all))
(declare-function ecc-review-ediff-next-difference "ecc-review-ediff" (&optional arg))
(declare-function ecc-review-ediff-stacked-p "ecc-review-ediff" (&optional control))
(declare-function ecc-review-ediff-previous-difference "ecc-review-ediff" (&optional arg))

;;;; The review a window belongs to

(defun ecc-review-direct--control ()
  "Return the control buffer of the review this buffer is a side of, or signal."
  (let ((control ecc-review--part-of))
    (unless (buffer-live-p control)
      (user-error "This review has been closed"))
    control))

(defun ecc-review-direct--side (control &optional buffer)
  "Return `A' or `B', the side of the review in CONTROL that BUFFER is, or nil.
BUFFER defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer control
      (cond ((eq buffer ediff-buffer-A) 'A)
            ((eq buffer ediff-buffer-B) 'B)))))

(defun ecc-review-direct--other (side)
  "Return the side that is not SIDE."
  (if (eq side 'A) 'B 'A))

(defun ecc-review-direct--buffer (side)
  "Return the buffer of SIDE.  Run in the control buffer."
  (if (eq side 'A) ediff-buffer-A ediff-buffer-B))

(defun ecc-review-direct--window (side)
  "Return the window SIDE is shown in, or nil.  Run in the control buffer."
  (let ((window (if (eq side 'A) ediff-window-A ediff-window-B)))
    (and (window-live-p window)
         (eq (window-buffer window) (ecc-review-direct--buffer side))
         window)))

(defun ecc-review-direct-give-keyboard (control &optional side)
  "Select the window of SIDE of the review in CONTROL, the right one by default.
Its frame is given the input focus when it is not the frame that has it:
ediff hands its control frame the focus as it lays out the windows of a
graphical Emacs, and the keys typed next would go there."
  (when (buffer-live-p control)
    (when-let* ((window (with-current-buffer control
                          (ecc-review-direct--window (or side 'B)))))
      (ecc-review-direct--select window)
      ;; Where ediff put the two sides is where they stand together:
      ;; the first command, whatever it is, is no move of point.
      (with-current-buffer control
        (ecc-review-direct--remember)))))

(defun ecc-review-direct--select (window)
  "Select WINDOW, and give its frame the input focus when another frame has it."
  (let ((frame (window-frame window)))
    (unless (eq frame (selected-frame))
      (if (display-graphic-p frame)
          (select-frame-set-input-focus frame)
        (select-frame frame)))
    (select-window window)))

;;;; Where the two sides stand against each other

(defun ecc-review-direct--difference-before (side position)
  "Return the last difference that begins at POSITION of SIDE or above, or -1.
The differences are in order on each side, so this is a binary search.
Run in the control buffer."
  (let ((low 0)
        (high (1- ediff-number-of-differences))
        (found -1))
    (while (<= low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (ediff-get-diff-posn side 'beg middle) position)
            (setq found middle
                  low (1+ middle))
          (setq high (1- middle)))))
    found))

(defun ecc-review-direct--difference-at (side position)
  "Return the difference POSITION of SIDE is in, or nil.
A difference that holds no line on SIDE holds no position of it either.
Run in the control buffer."
  (let ((n (ecc-review-direct--difference-before side position)))
    (and (>= n 0)
         (< position (ediff-get-diff-posn side 'end n))
         n)))

(defun ecc-review-direct--difference-near (side position)
  "Return the difference the line of POSITION of SIDE belongs to, or nil.
The one POSITION is in, or one that holds no line on SIDE and stands at
the start of this line -- where the other side put lines in or took
them out, which ediff marks on this line.  Run in the control buffer."
  (or (ecc-review-direct--difference-at side position)
      (let ((n (ecc-review-direct--difference-before side position)))
        (and (>= n 0)
             (= (ediff-get-diff-posn side 'beg n) (ediff-get-diff-posn side 'end n))
             (= (ediff-get-diff-posn side 'beg n)
                (with-current-buffer (ecc-review-direct--buffer side)
                  (save-excursion (goto-char position) (line-beginning-position))))
             n))))

(defun ecc-review-direct--lines-between (buffer from to)
  "Return how many lines of BUFFER there are from FROM to TO, both at a line start."
  (with-current-buffer buffer
    (count-lines from to)))

(defun ecc-review-direct--counterpart (side position)
  "Return (N . OTHER) for the line at POSITION of SIDE.
N is the difference the line is in, nil in the lines both sides share.
OTHER is the start of the line that stands against it on the other side:
in a difference, the line as many lines down its other side, or that
side's last when it has fewer, or where it would be when it has none --
a line taken out stands against the place it was taken from; elsewhere,
the line as many lines below the end of the difference above, or below
the top.  Run in the control buffer."
  (let* ((other (ecc-review-direct--other side))
         (buffer (ecc-review-direct--buffer side))
         (other-buffer (ecc-review-direct--buffer other))
         (bol (with-current-buffer buffer
                (save-excursion (goto-char position) (line-beginning-position))))
         (k (ecc-review-direct--difference-before side position))
         (inside (and (>= k 0) (< position (ediff-get-diff-posn side 'end k))))
         (from (cond ((< k 0) (with-current-buffer buffer (point-min)))
                     (inside (ediff-get-diff-posn side 'beg k))
                     (t (ediff-get-diff-posn side 'end k))))
         (other-from (cond ((< k 0) (with-current-buffer other-buffer (point-min)))
                           (inside (ediff-get-diff-posn other 'beg k))
                           (t (ediff-get-diff-posn other 'end k))))
         (down (ecc-review-direct--lines-between buffer from bol))
         (down (if inside
                   (min down (max 0 (1- (ecc-review-direct--lines-between
                                         other-buffer other-from
                                         (ediff-get-diff-posn other 'end k)))))
                 down)))
    (cons (and inside k)
          (with-current-buffer other-buffer
            (save-excursion
              (goto-char other-from)
              (forward-line down)
              (point))))))

;;;; Following point

(defvar-local ecc-review-direct--aligned nil
  "The start of the line the two sides were last put together at, in this side.
A command that leaves point on another line moves the other side; one
that leaves it here does not.  A position, not a marker: this is set
after every command, and a marker made each time would be one more for
every edit of the buffer to walk.")

(defun ecc-review-direct--remember ()
  "Take the lines the two windows have point on as where they stand together.
Run in the control buffer, after something other than point moving put
them where they are -- ediff, or this package."
  (dolist (side '(A B))
    (let ((buffer (ecc-review-direct--buffer side))
          (window (ecc-review-direct--window side)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq ecc-review-direct--aligned
                (save-excursion
                  (goto-char (if window (window-point window) (point)))
                  (line-beginning-position))))))))

(defun ecc-review-direct--strings-rows (window position)
  "Return the rows the overlay strings at POSITION take up in WINDOW.
They are drawn above the text at POSITION.
The after-string of an overlay that ends at POSITION and the
before-string of one that starts there: a comment of the review is the
after-string of its line, drawn above the line that follows.
`count-screen-lines' counts the rows of the strings inside what it
counts but not of those at its end, and `vertical-motion' up from
POSITION does not pass them either, so a comment right above the line
at point -- where \\`c' puts it -- set the two sides two rows apart
\(2026-10-02).  A string's rows are its newlines."
  (let ((rows 0))
    (dolist (overlay (overlays-in (max (point-min) (1- position)) (1+ position)))
      (when (memq (overlay-get overlay 'window) (list nil window))
        (let ((after (and (= (overlay-end overlay) position)
                          (overlay-get overlay 'after-string)))
              (before (and (= (overlay-start overlay) position)
                           (overlay-get overlay 'before-string))))
          (dolist (string (list after before))
            (when (stringp string)
              (cl-incf rows (cl-count ?\n string)))))))
    rows))

(defun ecc-review-direct--near-p (window from to)
  "Return non-nil when FROM and TO are no more than WINDOW's height apart.
Counted in lines of the buffer, which is cheap: the rows of the screen
are worked out over that distance only (`ecc-review-direct--rows')."
  (<= (count-lines (min from to) (max from to)) (window-body-height window)))

(defun ecc-review-direct--rows (window bol)
  "Return how far below the start of WINDOW the line starting at BOL is drawn.
In rows of the screen -- wrapped lines, comments and hidden text as
redisplay draws them (`ecc-review-direct--strings-rows') -- when BOL is
in the window or near it; negative above its start.  Far from it --
\\[end-of-buffer], a jump, a search -- in lines of the buffer: walking the
display over the whole distance stalled a large review, and redisplay
scrolls the window there anyway.  Run in WINDOW's buffer."
  (let ((start (window-start window)))
    (cond
     ((not (ecc-review-direct--near-p window start bol))
      (if (>= bol start) (count-lines start bol) (- (count-lines bol start))))
     ((= bol start) 0)
     ((> bol start)
      (+ (count-screen-lines start bol nil window)
         (ecc-review-direct--strings-rows window bol)))
     (t (- (count-screen-lines bol start nil window))))))

(defun ecc-review-direct--start-for (window position rows)
  "Return a start for WINDOW that puts the line of POSITION ROWS down.
The measure of `ecc-review-direct--rows': rows of the screen near
POSITION, lines of the buffer far from it.  Run in WINDOW's buffer."
  (save-excursion
    (goto-char position)
    (cond ((> (abs rows) (window-body-height window))
           (forward-line (- rows)))
          ;; The line is above the start: the start goes as far below it.
          ((< rows 0)
           (vertical-motion (- rows) window))
          (t
           (vertical-motion (- (max 0 (- rows (ecc-review-direct--strings-rows
                                                window position))))
                            window)))
    (point)))

(defun ecc-review-direct--align (window side position other)
  "Show OTHER at the height the line of POSITION is at in WINDOW.
WINDOW shows SIDE and is left alone; OTHER is a position of the other
side, whose window is scrolled.  The height is counted on the screen,
not in lines of the buffer (`ecc-review-direct--rows'): a comment drawn
under a line of one side only, a line wrapped in a half-width window
and a file the filter hides take up rows the other side does not have.
Where the line of POSITION is off the window -- point moved past its
edge, and redisplay has not scrolled it yet -- OTHER is put as far off
the other window, without forcing its start, so that redisplay scrolls
both the same way.  Run in the control buffer."
  (when-let* ((other-window (ecc-review-direct--window (ecc-review-direct--other side))))
    (let* ((rows (with-current-buffer (window-buffer window)
                   (ecc-review-direct--rows
                    window (save-excursion (goto-char position) (line-beginning-position)))))
           (other-start (with-current-buffer (window-buffer other-window)
                          (ecc-review-direct--start-for other-window other rows))))
      (set-window-start other-window other-start t)
      (set-window-point other-window other))))

(defun ecc-review-direct--follow (&optional align-only)
  "Put the review where point is, in the window selected.
A difference point is in becomes the current one, without the laying
out of windows that ediff's select does, unless ALIGN-ONLY; the other
side is put against point (`ecc-review-direct--align').  Run in a side
of a review."
  (let ((control ecc-review--part-of)
        (window (selected-window))
        (position (point)))
    (when (and (buffer-live-p control) (eq (window-buffer window) (current-buffer)))
      (let ((side (ecc-review-direct--side control)))
        (with-current-buffer control
          (when (and side (eq window (ecc-review-direct--window side))
                     (buffer-live-p (ecc-review-direct--buffer (ecc-review-direct--other side))))
            (let ((n (and (not align-only) (ecc-review-direct--difference-near side position)))
                  (other (cdr (ecc-review-direct--counterpart side position))))
              (when (and n (not (eql n ediff-current-difference)))
                (ecc-review-ediff-select-in-place n))
              (ecc-review-direct--align window side position other)
              (with-current-buffer (ecc-review-direct--buffer (ecc-review-direct--other side))
                (setq ecc-review-direct--aligned other))))))
      (setq ecc-review-direct--aligned
            (save-excursion (goto-char position) (line-beginning-position))))))

(defun ecc-review-direct--follow-logged (&optional align-only)
  "Follow point (`ecc-review-direct--follow'), and say so when that fails.
ALIGN-ONLY is the follow's.  It runs from `post-command-hook', which
takes a function that signals off the hook for good: following would
stop for the rest of the session and nothing would say why.  The error
is logged and shown instead."
  (condition-case error
      (ecc-review-direct--follow align-only)
    (error
     (ecc-log "review" "following point failed: %S" error)
     (message "Following point in the review failed: %s" (error-message-string error)))))

(defun ecc-review-direct--after-isearch ()
  "Follow point once the search has ended, unless it ended where it began.
On `isearch-mode-end-hook' in a side of a review."
  (unless (eql (line-beginning-position) ecc-review-direct--aligned)
    (ecc-review-direct--follow-logged)))

(defun ecc-review-direct--post-command ()
  "Follow point after a command, when it moved to another line.
On `post-command-hook' in a side of a review.  During an isearch only
when it stops on the next match, \\`C-s' or \\`C-r', not as each character is
typed; the end of a search is `ecc-review-direct--after-isearch'.  A
command that scrolls one window is not followed: the line it leaves
point on is taken as the place, and the next move goes from there."
  (cond
   ((bound-and-true-p isearch-mode)
    (when (memq this-command '(isearch-repeat-forward isearch-repeat-backward))
      (ecc-review-direct--follow-logged)))
   ((and (symbolp this-command) (get this-command 'scroll-command))
    (setq ecc-review-direct--aligned (line-beginning-position)))
   ((not (eql (line-beginning-position) ecc-review-direct--aligned))
    (ecc-review-direct--follow-logged))))

;;;; The keys

(defvar-local ecc-review-direct--panel-had-the-keyboard nil
  "Non-nil when the control panel had the keyboard as it was taken off the screen.
Set in the control buffer by `ecc-review-ediff--hide-the-panel', and
read and cleared after the command (`ecc-review-direct--keep-the-keyboard').")

(defun ecc-review-direct--keep-the-keyboard (control side window)
  "Give the keyboard back to SIDE of the review in CONTROL, if a command took it.
WINDOW is the one the key was typed in.  ediff selects its control panel
when it lays out its windows again, and on a graphical Emacs focuses its
control frame; either way -- the panel since taken off the screen
included -- or with WINDOW gone with the old layout, the window of SIDE
is selected again.  A command that chose to put the keyboard somewhere
else -- the minibuffer, the files pane -- is left to."
  (when (buffer-live-p control)
    (with-current-buffer control
      (let ((taken (or ecc-review-direct--panel-had-the-keyboard
                       (not (window-live-p window))
                       (eq (selected-window) ediff-control-window)
                       (and (frame-live-p ediff-control-frame)
                            (eq (selected-frame) ediff-control-frame)))))
        (setq ecc-review-direct--panel-had-the-keyboard nil)
        (when side
          (when taken
            (ecc-review-direct-give-keyboard control side))
          (ecc-review-direct--remember))))))

(defun ecc-review-direct--run (control command)
  "Run COMMAND in CONTROL the way its control panel runs it.
In the control buffer, which ediff's commands require, with the window
the key was typed in still selected -- what the command reads from the
minibuffer is read where the user is looking -- and the keyboard kept
there afterwards (`ecc-review-direct--keep-the-keyboard').  The prefix
argument and the key typed reach COMMAND as they would from the panel."
  (let ((side (ecc-review-direct--side control))
        (window (selected-window)))
    (unwind-protect
        (with-current-buffer control
          ;; Only a panel taken off the screen by this command counts:
          ;; one taken by a layout of before -- the opening, a move of
          ;; Claude's -- is no reason to take the keyboard back now.
          (setq ecc-review-direct--panel-had-the-keyboard nil)
          (setq this-command command)
          (call-interactively command))
      (ecc-review-direct--keep-the-keyboard control side window))
    ;; ediff scrolls each side by an amount of its own, worked out from
    ;; the sizes of the current difference, and the two came apart by a
    ;; row (2026-10-02): the other side is put against this one again.
    ;; Only that: a scroll is not followed, and the difference it may
    ;; have dragged point into does not become the current one.
    (when (and (eq command 'ediff-scroll-vertically)
               (eq (selected-window) window)
               (buffer-live-p control))
      (ecc-review-direct--follow-logged 'align-only))))

(defun ecc-review-direct-relay ()
  "Do what the key just typed does in the control panel of this review."
  (interactive)
  (let* ((control (ecc-review-direct--control))
         (keys (this-single-command-keys))
         (command (with-current-buffer control (key-binding keys))))
    (unless (commandp command)
      (user-error "%s does nothing in a review" (key-description keys)))
    (ecc-review-direct--run control command)))

(defun ecc-review-direct--from-point (side position forward)
  "Make n or p go from POSITION of SIDE, when point is off the current difference.
The difference above point is made current, without being selected, for
n to go to the one below; the one below, for p to go to the one above.
In a difference, that difference.  With none below point, or none above,
the end or the beginning of the list, which ediff says it is at.  Run in
the control buffer."
  (unless (and (ediff-valid-difference-p ediff-current-difference)
               (eql (ecc-review-direct--difference-near side position)
                    ediff-current-difference))
    (let* ((k (ecc-review-direct--difference-before side position))
           (from (cond ((eql (ecc-review-direct--difference-near side position) k) k)
                       ((and forward (= k (1- ediff-number-of-differences)))
                        ediff-number-of-differences)
                       (forward k)
                       ((< k 0) -1)
                       (t (1+ k)))))
      (unless (eql from ediff-current-difference)
        (ecc-review-ediff-select-in-place from 'unselect-only)))))

(defun ecc-review-direct--step (forward)
  "Go to the next difference below point, FORWARD, or the one above it.
As n and p of the control panel, from the difference at point, or from
point in the lines both sides share.  Where there is none to go to the
review is left on the difference it was on."
  (let* ((control (ecc-review-direct--control))
         (side (ecc-review-direct--side control))
         (position (point))
         (was (buffer-local-value 'ediff-current-difference control)))
    (with-current-buffer control
      (ecc-review-direct--from-point side position forward))
    (condition-case error
        (ecc-review-direct--run control (if forward
                                            #'ecc-review-ediff-next-difference
                                          #'ecc-review-ediff-previous-difference))
      (error
       (when (buffer-live-p control)
         (with-current-buffer control
           (unless (eql ediff-current-difference was)
             (ecc-review-ediff-select-in-place was))))
       (signal (car error) (cdr error))))))

(defun ecc-review-direct-next-difference (&optional _arg)
  "Go to the next difference below point, ARG of them.
The prefix argument reaches the control panel's n as it is."
  (interactive "p")
  (ecc-review-direct--step t))

(defun ecc-review-direct-previous-difference (&optional _arg)
  "Go to the previous difference above point, ARG of them.
The prefix argument reaches the control panel's p as it is."
  (interactive "p")
  (ecc-review-direct--step nil))

;;;; Comments on a line

(defun ecc-review-direct--line-at-point (control side)
  "Return the line at point of SIDE of the review in CONTROL, or nil.
A line a difference takes out on the left or puts in on the right, as
`ecc-review-lines' has it; nil on a line both sides share."
  (let ((bol (line-beginning-position))
        (buffer (current-buffer)))
    (with-current-buffer control
      (when-let* ((n (ecc-review-direct--difference-at side bol)))
        (seq-find (lambda (line)
                    (and (plist-get line :side)
                         (eq (plist-get line :buffer) buffer)
                         (eql (plist-get line :position) bol)))
                  (ecc-review-ediff--unit-lines (nth n (ecc-review-units))))))))

(defun ecc-review-direct-comment ()
  "Put a comment on the line at point.
On the left it is about the line as the change took it out, on the
right as it put it in, as \\`c' on a line of the diff review is.  Where
the line carries a comment of yours, it is offered for editing; where
it carries only Claude\\='s, what you type answers it.  On a line both
sides share there is nothing to comment on."
  (interactive)
  (let* ((control (ecc-review-direct--control))
         (line (or (ecc-review-direct--line-at-point
                    control (ecc-review-direct--side control))
                   (user-error "Not on a changed line: nothing to comment on"))))
    (with-current-buffer control
      (apply #'ecc-review-comment (ecc-review--read-comment line)))))

(defun ecc-review-direct-remove-comment (&optional all)
  "Remove a comment on the line at point, whoever wrote it.
When the line carries none, a comment of the current difference, as
\\`x' in the control panel does.  With a prefix argument ALL every
comment of the review is offered."
  (interactive "P")
  (let* ((control (ecc-review-direct--control))
         (line (and (not all)
                    (ecc-review-direct--line-at-point
                     control (ecc-review-direct--side control)))))
    (with-current-buffer control
      (if-let* ((here (and line (ecc-review--notes-on line))))
          (let ((note (ecc-review--pick-note here "Remove comment: ")))
            (ecc-review-remove-note note)
            (ecc-review--draw-notes)
            (message "Comment #%d removed (%d left)" (ecc-review-note-id note)
                     (length ecc-review--notes)))
        (ecc-review-ediff-remove-comment all)))))

;;;; Opening the file

(defun ecc-review-direct--section-text (path)
  "Return what the right side of this review holds of PATH, or nil.
Read the way the differences are computed (`ecc-review-ediff--section-texts').
Run in the control buffer."
  (when-let* ((tail (member (assoc path ecc-review-ediff--sections)
                            ecc-review-ediff--sections)))
    (cdar (ecc-review-ediff--section-texts (cdr ecc-review-ediff--buffers)
                                           (seq-take tail 2) 2))))

(defun ecc-review-direct--file-text (file)
  "Return (TEXT . WHY): what FILE holds now, or why that is not known.
TEXT is its buffer when one visits it, else the disk, and WHY nil; or
TEXT is nil and WHY says why a line cannot be followed through it:
`too-large' past `ecc-diff-max-file-size' -- a buffer as much as a
file -- `binary', or `unreadable'.  FILE is a regular file."
  (if-let* ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (if (> (buffer-size) ecc-diff-max-file-size)
            (cons nil 'too-large)
          (save-restriction
            (widen)
            (cons (buffer-substring-no-properties (point-min) (point-max)) nil))))
    (let ((size (file-attribute-size (file-attributes file))))
      (cond ((not (file-readable-p file)) (cons nil 'unreadable))
            ((and size (> size ecc-diff-max-file-size)) (cons nil 'too-large))
            ((ecc-diff-binary-p file) (cons nil 'binary))
            (t (if-let* ((text (ecc-diff-file-content file)))
                   (cons text nil)
                 (cons nil 'unreadable)))))))

(defun ecc-review-direct-line-now (line shown now)
  "Return where LINE of SHOWN, a file as the review shows it, is in NOW.
NOW is the same file as it is; what changed between the two moves the
line as a later change of a session moves a line of its diff."
  (if (or (null now) (equal shown now) (string-empty-p shown))
      line
    (ecc-visit-shift-through line (ecc-diff-hunks (ecc-diff-lines shown now) 0))))

(defun ecc-review-direct--place-now (path line)
  "Return (FILE . LINE): where LINE of PATH, as the review shows it, is now.
FILE is absolute.  The right side holds the files as the review read
them, which may not be how they are -- a review of commits, or of a
working tree that changed since -- and the line is carried through
that (`ecc-review-direct-line-now').  A file too large, binary or
unreadable keeps the line the review shows, and that is said; one that
is no longer a regular file -- a directory now -- is refused.  Run in
the control buffer."
  (let ((file (expand-file-name path))
        (shown (ecc-review-direct--section-text path)))
    (when (and (file-exists-p file) (not (file-regular-p file)))
      (user-error "%s is not a regular file now" path))
    (pcase-let ((`(,now . ,why) (if (and shown (file-exists-p file))
                                    (ecc-review-direct--file-text file)
                                  '(nil))))
      (when why
        (message "%s %s: opened at the line the review shows" path
                 (pcase why
                   ('too-large "is too large to follow")
                   ('binary "is binary now")
                   (_ "cannot be read"))))
      (cons file (if now (ecc-review-direct-line-now line shown now) line)))))

(defun ecc-review-direct-source (side position)
  "Return (FILE . LINE): where the line at POSITION of SIDE is in its file now.
A line of the left side is taken where it stands on the right first
\(`ecc-review-direct--counterpart'), which for a line taken out is where
it was; then `ecc-review-direct--place-now'.  Run in the control buffer."
  (let* ((position (if (eq side 'A)
                       (cdr (ecc-review-direct--counterpart 'A position))
                     position))
         (place (or (ecc-review-ediff--file-place 'B position)
                    (user-error "Not in a file of the review"))))
    (ecc-review-direct--place-now (car place) (max 1 (cdr place)))))

(defun ecc-review-direct-open-unit (unit)
  "Open the file of the difference UNIT at its first line on the right, as now.
The file and the line are the difference's own, :path and :start --
not what is at its place on the right, which for lines taken out at the
end of a file is the separator of the next one."
  (pcase-let ((`(,file . ,line) (ecc-review-direct--place-now (plist-get unit :path)
                                                              (plist-get unit :start))))
    (ecc-review-direct-open-file file line)))

(defvar ecc-review-direct-make-frame-function #'make-frame
  "The function that makes the frame the files of an ediff review open in.
Called with no argument; it returns the frame.")

(defvar ecc-review-direct--files-frame nil
  "The frame the files of ediff reviews are opened in, or nil.")

(defun ecc-review-direct--frame-usable-p (frame)
  "Return non-nil when a file can be shown in the selected window of FRAME.
A frame that has come to hold a review, or whose selected window is
dedicated, would lose what it shows."
  (and (frame-live-p frame)
       (not (window-dedicated-p (frame-selected-window frame)))
       (not (seq-some (lambda (window)
                        (let ((buffer (window-buffer window)))
                          (or (buffer-live-p (buffer-local-value 'ecc-review--part-of buffer))
                              (ecc-review-buffer-p buffer))))
                      (window-list frame 'no-minibuffer)))))

(defun ecc-review-direct--file-window ()
  "Return the window a file opened from an ediff review is shown in.
This is the one place that says where.  The review has its frame to
itself and is left as it is: the file goes in a frame of its own, made
the first time (`ecc-review-direct-make-frame-function') and used again
while it is there."
  (unless (ecc-review-direct--frame-usable-p ecc-review-direct--files-frame)
    (setq ecc-review-direct--files-frame (funcall ecc-review-direct-make-frame-function)))
  (frame-selected-window ecc-review-direct--files-frame))

(defun ecc-review-direct--show-file (buffer)
  "Show BUFFER where the files of an ediff review open; select it, return it.
The `where' of `ecc-visit-open'."
  (let ((window (ecc-review-direct--file-window)))
    (set-window-buffer window buffer)
    (ecc-review-direct--select window)
    window))

(defun ecc-review-direct-open-file (file line)
  "Show FILE at LINE where the files of an ediff review open, and go there.
LINE nil keeps the point the buffer had.  FILE is opened under the name
a buffer visits it by already, if one does: a name through a symbolic
link -- /tmp on macOS -- would visit it again and say that the two
names are one file.  The rest is `ecc-visit-open', a video or a sound
played by the machine."
  (let ((visiting (find-buffer-visiting file)))
    (ecc-visit-open (if visiting (buffer-file-name visiting) file) line nil
                    #'ecc-review-direct--show-file)))

(defun ecc-review-direct-visit ()
  "Open the file the line at point is in, at that line as the file is now.
In a frame of its own, the review staying as it is
\(`ecc-review-direct--file-window')."
  (interactive)
  (let* ((control (ecc-review-direct--control))
         (side (ecc-review-direct--side control))
         (position (point))
         (target (with-current-buffer control
                   (ecc-review-direct-source side position))))
    (ecc-review-direct-open-file (car target) (cdr target))))

(cl-defmethod ecc-review-files-open-file (entry &context (major-mode ediff-mode))
  "Open the file ENTRY of this ediff review at its first change, as RET would.
In the frame the files of a review open in; a file with no difference
shown keeps the point its buffer had."
  (let* ((path (plist-get entry :path))
         (unit (seq-find (lambda (unit) (equal (plist-get unit :path) path))
                         (ecc-review-units))))
    (if unit
        (ecc-review-direct-open-unit unit)
      (ecc-review-direct-open-file (expand-file-name path) nil))))

;;;; The keys on the screen

(defvar ecc-review-direct-header-keys
  '((A ("n/p" . "diff") ("j" . "jump") ("{ }" . "comments") ("c" . "comment")
       ("x" . "delete") ("l" . "list") ("a" . "Claude's") ("s" . "files")
       ("/" . "filter"))
    (B ("RET" . "open") ("T" . "tour") ("t" . "next") ("M" . "message")
       ("C-c C-c" . "send") ("q" . "quit") ("u/d" . "reply") ("v/V" . "scroll")
       ("!" . "reread") ("?" . "all keys")))
  "The keys the header line of each window of an ediff review shows.
For each side, (KEY . WHAT) in the order they are shown.  Every key
works in either window, so the two lines are one list cut in two: the
left has reading and your comments, the right Claude, the files, sending
and closing.  The most used come first, so that a narrow window loses
the least of them at its right edge.  The right one ends with the key
of the help, which a window too narrow for them all keeps: it drops the
keys before it, from the last (`ecc-review-direct--header-line').")

(defun ecc-review-direct--key-pieces (side)
  "Return the keys the header line of SIDE shows, a string for each.
Faces are put on the strings here; no font-lock runs in a review."
  (mapcar (lambda (key)
            (concat (propertize (car key) 'face 'bold)
                    " "
                    (propertize (cdr key) 'face 'ecc-dim-face)))
          (alist-get side ecc-review-direct-header-keys)))

(defun ecc-review-direct--join (pieces)
  "Return the keys PIECES as a header line has them: after a space, two apart.
Every header line of keys is made by this, and so is what the width of
one is measured on."
  (concat " " (string-join pieces "  ")))

(defun ecc-review-direct--keys (side)
  "Return the keys the header line of SIDE shows, as one string.
Without the space they start with on the header line."
  (substring (ecc-review-direct--join (ecc-review-direct--key-pieces side)) 1))

(defun ecc-review-direct--to-the-right (text)
  "Return a space that runs up to where TEXT, put after it, ends at the right edge.
Where what is before it reaches that place already -- a narrow window --
it takes no room, and TEXT follows."
  (propertize " " 'display `(space :align-to (- right ,(string-width text)))))

(defun ecc-review-direct--status (control)
  "Return where the review in CONTROL is, for the right end of a header line.
The current difference out of how many -- `3/12', `-/12' with none
current -- and what the filter hides, as `/FILTER: 2 hidden'.  It
starts with two spaces, so that it stands apart from the keys even
where the window is too narrow to put it at the right edge."
  (with-current-buffer control
    (concat "  "
            (if (zerop ediff-number-of-differences)
                (propertize "no difference" 'face 'ecc-dim-face)
              (propertize (format "%s/%d"
                                  (if (ediff-valid-difference-p ediff-current-difference)
                                      (1+ ediff-current-difference)
                                    "-")
                                  ediff-number-of-differences)
                          'face 'bold))
            (when ecc-review--filter
              (propertize (format "  /%s: %d hidden" ecc-review--filter
                                  (length ecc-review--hidden))
                          'face 'ecc-dim-face))
            " ")))

(defun ecc-review-direct--header (side &optional right)
  "Return the header line of the window of SIDE: the keys it is read with.
RIGHT puts the keys at the right edge of the window, where they meet
those of the other side in the middle when the two are side by side.
A header line is no line of the buffer, so the lines the two sides are
put together by (`ecc-review-direct--align') are not counted in it."
  (let ((keys (ecc-review-direct--keys side)))
    (if right
        (concat (ecc-review-direct--to-the-right (concat keys " ")) keys " ")
      (ecc-review-direct--join (ecc-review-direct--key-pieces side)))))

(defvar-local ecc-review-direct--header-keys nil
  "The keys of the header line of this side, a string for each.")

(defvar-local ecc-review-direct--header-status nil
  "Where the review is, for the header line of this side, or nil.")

(defvar-local ecc-review-direct--header-cache nil
  "The last right header line drawn: (WIDTH PIECES STATUS . TEXT).
Redisplay draws the header line far more often than the window, the
keys or the status change, and each of those draws looks it up here
rather than fitting the keys again (`ecc-review-direct--header-line').")

(defun ecc-review-direct--fit-keys (pieces width)
  "Return the keys PIECES as the header line has them, in WIDTH columns, or nil.
The last of them -- the help -- is kept, and the ones before it are
dropped from the last until the rest fit."
  (let ((pieces (copy-sequence pieces))
        (text nil))
    (while (and pieces
                (> (string-width (setq text (ecc-review-direct--join pieces)))
                   width)
                (cdr pieces))
      (setq pieces (nconc (butlast pieces 2) (last pieces))))
    (and pieces (<= (string-width text) width) text)))

(defun ecc-review-direct--header-line (&optional window)
  "Return the header line of the right side in WINDOW, the selected one by default.
The keys, and where the review is at the right end.  Where WINDOW is too
narrow for both, the keys before the last, the help, are left out from
the last until they fit; where it is too narrow for the help and where
the review is, where the review is comes first and the keys after it,
as many as fit: with the panel out of sight, nothing else says it.
Worked out as the header line is drawn, from the strings made when the
difference or the layout changes (`ecc-review-direct-refresh-headers'),
so that a window made narrower is followed at once.  What it comes to
is kept for the next draw of the same width, keys and status
\(`ecc-review-direct--header-cache')."
  (let ((pieces ecc-review-direct--header-keys)
        (status ecc-review-direct--header-status)
        (width (window-width window))
        (cache ecc-review-direct--header-cache))
    (if (and cache
             (eql (nth 0 cache) width)
             (eq (nth 1 cache) pieces)
             (eq (nth 2 cache) status))
        (nthcdr 3 cache)
      (let ((text
             (if (null status)
                 (ecc-review-direct--join pieces)
               (if-let* ((keys (ecc-review-direct--fit-keys
                                pieces (- width (string-width status)))))
                   (concat keys (ecc-review-direct--to-the-right status) status)
                 (concat (substring status 1) "│" (ecc-review-direct--join pieces))))))
        (setq ecc-review-direct--header-cache (cl-list* width pieces status text))
        text))))

(defun ecc-review-direct-header-text (buffer &optional window)
  "Return the header line BUFFER, a side of a review, shows in WINDOW, as a string.
WINDOW is the window of BUFFER by default."
  (with-current-buffer buffer
    (if (stringp header-line-format)
        header-line-format
      (ecc-review-direct--header-line (or window (get-buffer-window buffer t))))))

(defun ecc-review-direct-refresh-headers (control)
  "Write the header lines of the two windows of the review in CONTROL again.
The left one is put at the right edge while the two sides are side by
side and at the left while one is above the other; the right one --
the window that has the keyboard -- ends with where the review is
\(`ecc-review-direct--header-line').  Run as the layout or the
difference changes, from the hooks of the control buffer; nothing that
would come out the same is set again."
  (with-current-buffer control
    (let ((left (ecc-review-direct--header 'A (not (ecc-review-ediff-stacked-p control))))
          (keys (ecc-review-direct--key-pieces 'B))
          (status (ecc-review-direct--status control)))
      (when (buffer-live-p ediff-buffer-A)
        (with-current-buffer ediff-buffer-A
          (unless (equal-including-properties header-line-format left)
            (setq header-line-format left)
            (force-mode-line-update))))
      (when (buffer-live-p ediff-buffer-B)
        (with-current-buffer ediff-buffer-B
          (let ((changed nil))
            (unless (equal-including-properties ecc-review-direct--header-keys keys)
              (setq ecc-review-direct--header-keys keys
                    changed t))
            (unless (equal-including-properties ecc-review-direct--header-status status)
              (setq ecc-review-direct--header-status status
                    changed t))
            (unless (equal header-line-format '(:eval (ecc-review-direct--header-line)))
              (setq header-line-format '(:eval (ecc-review-direct--header-line))
                    changed t))
            ;; What the construct reads changed, not the construct itself:
            ;; redisplay would not draw the header line again on its own.
            (when changed
              (force-mode-line-update))))))))

;;;; The mode

(defvar ecc-review-direct-relayed-keys
  '("j" "{" "}" "a" "b" "s" "/" "T" "t" "M" "y" "u" "d" "l" "!" "?" "i" "q"
    "v" "V" "C-l" "|" "m" "h" "@" "*" "<" ">" "##" "#c" "#h" "#f"
    "C-c C-c" "C-c C-k")
  "The keys of the control panel that the two windows of a review have too.
Each does there what it does in the panel, wherever that is bound
\(`ecc-review-direct-relay').")

(defvar ecc-review-direct-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Digits and - are a prefix argument, as in the control panel, and
    ;; the other keys that insert text do nothing: the buffer is
    ;; read-only, and 3j is how a difference is jumped to.
    (suppress-keymap map)
    (dolist (key ecc-review-direct-relayed-keys)
      (define-key map (kbd key) #'ecc-review-direct-relay))
    (define-key map (kbd "n") #'ecc-review-direct-next-difference)
    (define-key map (kbd "p") #'ecc-review-direct-previous-difference)
    ;; ediff's own second keys for them, which its help shows.
    (define-key map (kbd "SPC") #'ecc-review-direct-next-difference)
    (define-key map (kbd "DEL") #'ecc-review-direct-previous-difference)
    (define-key map (kbd "c") #'ecc-review-direct-comment)
    (define-key map (kbd "x") #'ecc-review-direct-remove-comment)
    (define-key map (kbd "RET") #'ecc-review-direct-visit)
    map)
  "Keymap of `ecc-review-direct-mode'.")

(define-minor-mode ecc-review-direct-mode
  "The keys of an ediff review in its two windows, and point driving it.
On in both buffers of an ediff review.  The keys of the control panel
do there what they do in the panel; \\`c' comments on the line at
point, \\`x' removes a comment of it and \\`RET' opens its file; moving
point makes the difference it is in the current one and puts the other
window against it.

\\{ecc-review-direct-mode-map}"
  :lighter nil
  :interactive nil
  (if ecc-review-direct-mode
      (progn
        (add-hook 'post-command-hook #'ecc-review-direct--post-command nil t)
        (add-hook 'isearch-mode-end-hook #'ecc-review-direct--after-isearch nil t))
    (remove-hook 'post-command-hook #'ecc-review-direct--post-command t)
    (remove-hook 'isearch-mode-end-hook #'ecc-review-direct--after-isearch t)))

(defun ecc-review-direct-setup (control)
  "Turn `ecc-review-direct-mode' on in the two sides of the review in CONTROL.
Each is given the header line of its side (`ecc-review-direct-refresh-headers')."
  (with-current-buffer control
    (dolist (buffer (list ediff-buffer-A ediff-buffer-B))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ecc-review-direct-mode 1)
          (setq ecc-review-direct--aligned nil)))))
  (ecc-review-direct-refresh-headers control))

(provide 'ecc-review-direct)

;;; ecc-review-direct.el ends here
