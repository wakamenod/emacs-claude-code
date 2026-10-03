;;; ecc-review-talk.el --- Talk to Claude without leaving a review  -*- lexical-binding: t; -*-

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

;; An ediff review takes the whole frame (`ecc-review-ediff-full-frame'),
;; which hides the session and its prompt.  Asking Claude about the diff
;; would mean leaving the review, so the asking is done from the review
;; itself:
;;
;; - T asks Claude for a tour of the review (`ecc-review-talk-tour-prompt'),
;;   t for its next stop, and M reads a line and sends it.  They go to
;;   the session of the review and are sent the way a prompt typed in
;;   the minibuffer is (`ecc-send'): queued while a turn runs.
;;
;; - In an ediff review a pane shows the latest reply of that session
;;   as it streams, each tool call on a line of its own, and whatever
;;   Claude is waiting for -- a permission, a question, a plan -- which
;;   y answers from the review.  The pane is a side window: on the right
;;   while the two sides of the review are one above the other, at the
;;   bottom while they are side by side or the frame has no room on the
;;   right (`ecc-review-talk--side').  It is put back, on the side the
;;   layout asks for, whenever ediff lays its windows out again, as | does,
;;   and it goes when the review is quit.  `ecc-review-talk-reply-place'
;;   puts it in a frame of its own instead.  It is never selected: the
;;   keys of the review stay where they are typed.
;;
;; A diff review shares the frame with the session, whose transcript is
;; beside it, so it has the keys and no pane.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-answer)
(require 'ecc-context)
(require 'ecc-review)
(require 'ecc-review-agent)

(defvar ediff-window-A)
(defvar ediff-buffer-B)
(declare-function ediff-keep-window-config "ediff-wind" (control-buf))
(declare-function ecc-review-ediff-stacked-p "ecc-review-ediff" (&optional control))
(declare-function ecc-review-files--pane-window "ecc-review-files" (review))

(defcustom ecc-review-talk-reply-height 12
  "How many lines the reply pane under an ediff review takes, or nil for none.
The pane shows what Claude says while the review hides the session; it
is under the review while the two sides are side by side.  The lines it
takes are the review's, and how many a screen can spare is the
screen's.  nil shows no pane, wherever it would go."
  :type '(choice (integer :tag "Lines") (const :tag "No pane" nil))
  :group 'ecc)

(defcustom ecc-review-talk-reply-width 75
  "How many columns the reply pane right of an ediff review takes.
It is on the right while the two sides of the review are one above the
other (`ecc-review-ediff-layout'), and under them when the frame cannot
spare the columns (`ecc-review-talk-min-diff-width').  75 is for a
frame of 155 columns or more, which leaves the diff 80; a narrower one
has the pane under the review, `ecc-review-talk-reply-height' lines
high.  Fewer columns keep the pane on the right of a narrower frame,
with Claude's reply wrapped shorter."
  :type 'integer
  :group 'ecc)

(defcustom ecc-review-talk-reply-place 'auto
  "Where the reply pane of an ediff review goes.
`auto' makes it a side window of the review's frame: on the right while
the two sides are one above the other, at the bottom while they are
side by side.  `frame' gives each review a frame of its own for the
pane, opened with the review and closed with it.  That frame is for
reading: it is never given the focus, and \`y' answers from the
review."
  :type '(choice (const :tag "Beside the review, by its layout" auto)
                 (const :tag "A frame of its own" frame))
  :group 'ecc)

(defvar ecc-review-talk-min-diff-width 80
  "The fewest columns the two sides of a stacked review are left by the pane.
A frame that would leave them fewer with the reply pane on the right
has it at the bottom instead.")

(defvar ecc-review-talk-tour-prompt
  "Walk me through the changes in the review I have open, the most \
important first.  For each stop, bring it into view with review_navigate, \
explain it in a few sentences, and put a review_comment on any line that \
needs my attention.  Then stop and wait: I will ask for the next stop."
  "What the key T of a review sends to the session of the review.")

(defvar ecc-review-talk-next-prompt "Next stop."
  "What the key t of a review sends to the session of the review.
Where the user is follows it (`ecc-review-talk--where').")

(defvar ecc-review-talk-where-label "Where I am in the review:"
  "What the place of the user in the review is introduced by, after t and M.")

(defface ecc-review-talk-speaker-face
  '((t :inherit ecc-heading-face))
  "Face of the name in front of what Claude says in the reply pane."
  :group 'ecc)

;;;; Sending

(defun ecc-review-talk--session ()
  "Return the session of this review, or signal that this is no review."
  (unless (ecc-review-buffer-p)
    (user-error "Not a review of files"))
  ecc-review--session)

(defun ecc-review-talk--needs-tools (session)
  "Signal a `user-error' unless SESSION has the review tools of this Emacs.
A tour is made of them; without MCP the model has none to call."
  (unless (ecc-model-option session :mcp ecc-mcp-enabled)
    (user-error "A tour needs the review tools: turn on `ecc-mcp-enabled' and start %s again"
                (ecc-session-name session))))

;; The model would otherwise spend its first calls asking for what this
;; Emacs knows: where the user is, with t and M.  A round trip of a tool
;; took 2-5 s (2026-10-02).

(defun ecc-review-talk--where ()
  "Return the block that says where the user is in this review, or nil.
The file, the line and its side, and the hunk with its @@ header and its
number among the hunks of the file (`ecc-review-place-at-point'); the
patch is not in it.  A quote block like the context a prompt is given
\(`ecc-context-format')."
  (when-let* ((place (ecc-review-place-at-point))
              (path (plist-get place :path)))
    (let ((hunk (plist-get place :hunk))
          (line (plist-get place :line)))
      (concat "\n\n---\n" ecc-review-talk-where-label (format " `%s`" path)
              (when line
                (format " L%d (%s side)" line (plist-get place :side)))
              (cond (hunk
                     (let ((number (ecc-review-hunk-number hunk)))
                       (format ", hunk %d/%d `%s`" (car number) (cdr number)
                               (plist-get hunk :header))))
                    (line ", outside any hunk"))))))

(defun ecc-review-talk-send (text)
  "Send TEXT to the session of this review as a prompt, and show the pane.
Sent the way `ecc-send' sends a prompt typed in the minibuffer, which
queues it while a turn is running and says so."
  (let ((session (ecc-review-talk--session)))
    (ecc-review-talk--show-pane (current-buffer))
    (ecc-send text session)))

;;;###autoload
(defun ecc-review-talk-tour ()
  "Ask Claude for a tour of this review, one stop at a time.
Claude shows each stop with `review_navigate', explains it, comments
on the lines that need attention, and waits to be asked for the next
stop (`ecc-review-talk-next')."
  (interactive)
  (ecc-review-talk--needs-tools (ecc-review-talk--session))
  (ecc-review-talk-send ecc-review-talk-tour-prompt))

;;;###autoload
(defun ecc-review-talk-next ()
  "Ask Claude for the next stop of the tour, saying where the user is."
  (interactive)
  (ecc-review-talk--needs-tools (ecc-review-talk--session))
  (ecc-review-talk-send (concat ecc-review-talk-next-prompt (ecc-review-talk--where))))

;;;###autoload
(defun ecc-review-talk-message (text)
  "Send TEXT, read in the minibuffer, to the session of this review.
Where the user is in the review goes with it (`ecc-review-talk--where')."
  (interactive
   (list (read-string (format "To %s: " (ecc-session-name (ecc-review-talk--session))))))
  (when (string-empty-p (string-trim text))
    (user-error "Prompt is empty"))
  (ecc-review-talk-send (concat text (ecc-review-talk--where))))

;;;; Answering what Claude waits for

(defun ecc-review-talk--request (session)
  "Return the oldest request SESSION is waiting on, or signal that there is none.
Every tool, Bash included: `ecc-answer-exclude-tools' keeps a request
from being answered from a row that cuts it short, and the pane prints
a request whole."
  (or (car (ecc-session-pending session))
      (user-error "%s is not waiting for anything" (ecc-session-name session))))

(defun ecc-review-talk--read-answers (request)
  "Read an answer to each question of REQUEST in the minibuffer.
Return them as `ecc-question-send-answers' takes them.  They are
collected here, not in the question buffer of the session, which keeps
whatever the user has chosen there; a \\[keyboard-quit] part way leaves
nothing changed."
  (mapcar
   (lambda (question)
     (let* ((labels (ecc-perm-question-options question))
            (prompt (format "%s " (or (alist-get 'question question) "Answer:")))
            (answers (seq-remove #'string-empty-p
                                 (mapcar #'string-trim
                                         (if (ecc-question--multi-p question)
                                             (completing-read-multiple prompt labels)
                                           (list (completing-read prompt labels)))))))
       (unless answers
         (user-error "No answer given"))
       (cons (alist-get 'question question) (string-join (delete-dups answers) ", "))))
   (ecc-question-questions request)))

(defun ecc-review-talk-answer ()
  "Answer what the session of this review is waiting for.
A permission or a plan is allowed or denied, a question is answered in
the minibuffer.  What is answered is the one the reply pane shows."
  (interactive)
  (let* ((session (ecc-review-talk--session))
         (request (ecc-review-talk--request session))
         (summary (ecc-answer-summary request)))
    (if (eq (ecc-request-kind request) 'question)
        ;; A request the CLI took back while the minibuffer was read is
        ;; refused by `ecc-perm-respond', where every answer goes.
        (ecc-question-send-answers request (ecc-review-talk--read-answers request))
      (let* ((plan (eq (ecc-request-kind request) 'plan))
             (choice (car (read-multiple-choice
                           (format "%s: %s" (ecc-session-name session) summary)
                           (if plan
                               '((?y "approve" "Approve the plan as it stands")
                                 (?n "deny" "Refuse the plan and say why"))
                             '((?y "allow" "Let Claude use the tool this once")
                               (?n "deny" "Refuse and say why")))))))
        (pcase choice
          (?y (pcase (ecc-perm-allow-request request)
                ('deny (message "Denied: %s (the buffer has unsaved changes)" summary))
                ('save (message "Saved the buffer and allowed: %s" summary))
                (_ (message "%s: %s" (if plan "Approved" "Allowed") summary))))
          (?n (ecc-perm-respond request 'deny
                                :message (read-string "Reason for denying (may be empty): "))
              (message "Denied: %s" summary)))))))

;;;; The pane

(defvar ecc-review-talk--panes nil
  "The live reply panes, whichever review they belong to.")

(defvar-local ecc-review-talk--pane nil
  "The reply pane of this review, or nil.")

(defvar-local ecc-review-talk--review nil
  "The review this reply pane belongs to.")

(defvar-local ecc-review-talk--of nil
  "The session whose replies this pane shows.")

(defvar-local ecc-review-talk--tail nil
  "The text node whose end is the end of what this pane says, or nil.
A delta of that node is appended at `ecc-review-talk--tail-end'; any
other change writes the pane again.")

(defvar-local ecc-review-talk--tail-end nil
  "Where the next piece of `ecc-review-talk--tail' goes.")

(defvar-local ecc-review-talk--shown-turn nil
  "The turn this pane was last written from.
Written from another, every window of the pane follows its end again.")

(defvar-local ecc-review-talk--kept nil
  "Where the side window of the pane was read from as it was taken down.
What `ecc-review-talk--reading' said of it: a pair of places, its start
and its point, while it did not show the end of the pane, and nil while
it followed it.  The side window the pane is shown in next is put there
and this is cleared (`ecc-review-talk--show-pane'); so it is when the
pane is still on the screen then, in a frame of its own, or when another
turn begins.")

(defvar ecc-review-talk-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    ;; The keys the review scrolls the pane with, and special-mode's
    ;; own two, scroll it the same way here.
    (define-key map (kbd "u") #'ecc-review-talk-scroll-back)
    (define-key map (kbd "d") #'ecc-review-talk-scroll-on)
    (define-key map (kbd "DEL") #'ecc-review-talk-scroll-back)
    (define-key map (kbd "SPC") #'ecc-review-talk-scroll-on)
    map)
  "Keymap of `ecc-review-talk-mode'.")

(define-derived-mode ecc-review-talk-mode special-mode "Claude-Reply"
  "Major mode of the pane an ediff review shows Claude's replies in.

\\{ecc-review-talk-mode-map}"
  :interactive nil
  (setq truncate-lines nil
        word-wrap t)
  (buffer-disable-undo)
  (setq mode-line-format '(:eval (ecc-review-talk--mode-line)))
  (add-hook 'kill-buffer-hook #'ecc-review-talk--forget nil t))

(defun ecc-review-talk--forget ()
  "Take this pane off the list of panes, as it is killed."
  (setq ecc-review-talk--panes (delq (current-buffer) ecc-review-talk--panes)))

(defun ecc-review-talk--mode-line ()
  "Return the mode line of this reply pane: whose replies, and the state."
  (let ((session ecc-review-talk--of))
    (concat " "
            (propertize "Claude" 'face 'ecc-review-talk-speaker-face)
            (propertize (format " · %s · " (ecc-session-name session)) 'face 'ecc-dim-face)
            (pcase (ecc-session-state session)
              ('running "replying…")
              ((or 'waiting-permission 'waiting-question 'waiting-plan)
               (propertize "waiting for you: y answers" 'face 'ecc-pending-face))
              (state (format "%s" state))))))

(defun ecc-review-talk--pane-buffer (review)
  "Return the reply pane of REVIEW, made when it has none."
  (with-current-buffer review
    (if (buffer-live-p ecc-review-talk--pane)
        ecc-review-talk--pane
      (let ((pane (ecc-review-pane-buffer review "reply" #'ecc-review-talk-mode
                                          'ecc-review-talk--review)))
        (with-current-buffer pane
          (setq ecc-review-talk--of (buffer-local-value 'ecc-review--session review)))
        (cl-pushnew pane ecc-review-talk--panes)
        (add-hook 'kill-buffer-hook #'ecc-review-talk--review-killed nil t)
        (ecc-review-talk--write pane)
        (setq ecc-review-talk--pane pane)))))

(defun ecc-review-talk--take-down (pane &optional side-only)
  "Take every window showing the reply PANE off the screen.
SIDE-ONLY leaves the frame of its own (`ecc-review-talk-reply-place')
alone: only the side windows of a review's frame go.  Where the side
window was read from is kept for the next one (`ecc-review-talk--kept');
any other window showing the pane is taken down and nothing kept of it."
  (with-current-buffer pane
    (setq ecc-review-talk--kept nil))
  (dolist (window (get-buffer-window-list pane nil t))
    (pcase (window-parameter window 'ecc-review-talk)
      ('frame
       (unless side-only
         (ecc-review-talk--close-frame pane)))
      (side
       (when (memq side '(right bottom))
         (with-current-buffer pane
           (setq ecc-review-talk--kept (ecc-review-talk--reading window))))
       (ecc-review-pane-take-down window '(ecc-review-talk))))))

(defun ecc-review-talk--review-killed ()
  "Kill the reply pane of this review with it, and the window it is in.
The frame of its own goes too, when it shows this pane."
  (when (buffer-live-p ecc-review-talk--pane)
    (ecc-review-talk--take-down ecc-review-talk--pane)
    (kill-buffer ecc-review-talk--pane)))

;;;;; Where it goes

(defun ecc-review-talk--side (review)
  "Return the side the reply pane of REVIEW goes on: `right' or `bottom'.
On the right while the two sides of the review are one above the other
and the frame can spare `ecc-review-talk-reply-width' columns and still
leave them `ecc-review-talk-min-diff-width' -- the files pane of this
review counted, as wide as it is, while it is on the screen -- else at
the bottom.  Run in the control buffer."
  (let ((frame (window-frame ediff-window-A))
        (files (ecc-review-files--pane-window review)))
    (if (and (ecc-review-ediff-stacked-p review)
             (>= (- (window-total-width (frame-root-window frame))
                    ecc-review-talk-reply-width
                    (if files (window-total-width files) 0))
                 ecc-review-talk-min-diff-width))
        'right
      'bottom)))

(defun ecc-review-talk--in-side-window (pane side)
  "Show PANE in a side window of the frame of this review, on SIDE; return it.
Run in the control buffer."
  (let ((window (with-selected-window ediff-window-A
                  (display-buffer-in-side-window
                   pane `((side . ,side) (slot . 0)
                          ,@(if (eq side 'right)
                                `((window-width . ,ecc-review-talk-reply-width)
                                  (preserve-size . (t . nil)))
                              `((window-height . ,ecc-review-talk-reply-height)
                                (preserve-size . (nil . t))))
                          (dedicated . t)
                          (window-parameters . ((no-other-window . t)
                                                (no-delete-other-windows . t))))))))
    (when (window-live-p window)
      (set-window-parameter window 'ecc-review-talk side))
    window))

(defvar-local ecc-review-talk--frame nil
  "The frame of its own this reply pane is shown in, or nil.
Each pane has its own: two reviews open at once, of one session or of
two, each keep their reply where it was, and closing one closes its
frame alone.")

(defvar ecc-review-talk-make-frame-function #'ecc-review-talk--make-frame
  "The function that makes the frame of a reply pane; it returns the frame.
Called from the frame of the review with the name the frame is to have,
when it takes an argument.  One that takes none -- what this was before
the frame had a name -- is called with none, and the frame it returns is
given the name (`ecc-review-talk--new-frame').")

(defun ecc-review-talk--new-frame (name)
  "Make the frame NAME of a reply pane, with `ecc-review-talk-make-frame-function'."
  (let* ((function ecc-review-talk-make-frame-function)
         (most (cdr (func-arity function))))
    (if (or (eq most 'many) (>= most 1))
        (funcall function name)
      (let ((frame (funcall function)))
        (set-frame-parameter frame 'name name)
        frame))))

(defun ecc-review-talk--make-frame (name)
  "Make the frame NAME a reply pane is shown in, without giving it the focus."
  (make-frame `((name . ,name)
                (width . ,ecc-review-talk-reply-width)
                (height . 30)
                (minibuffer . nil)
                (no-focus-on-map . t)
                (unsplittable . t))))

(defun ecc-review-talk--frame-window (frame)
  "Return the window the reply pane is shown in, in FRAME, its frame of its own.
A live one: its only window as it is made, or the first, should
something on `after-make-frame-functions' have split it."
  (frame-first-window frame))

(defun ecc-review-talk--in-frame (pane)
  "Show PANE in its frame of its own, made when it has none; return its window.
The frame is named after the pane, which is named after the review,
and used again while it is there.
Nothing is selected and no frame is given the focus: the keyboard stays
in the window of the review it was in, which is selected again should
making the frame have moved it."
  (let ((selected (selected-window)))
    (with-current-buffer pane
      (unless (frame-live-p ecc-review-talk--frame)
        (setq ecc-review-talk--frame
              (ecc-review-talk--new-frame (buffer-name pane))))
      (let ((window (ecc-review-talk--frame-window ecc-review-talk--frame)))
        (set-window-dedicated-p window nil)
        (set-window-buffer window pane)
        (set-window-dedicated-p window t)
        (set-window-parameter window 'ecc-review-talk 'frame)
        (unless (eq (selected-window) selected)
          (select-window selected))
        window))))

(defun ecc-review-talk--close-frame (pane)
  "Delete the frame of its own of the reply PANE, and forget it.
Whichever frame has the focus keeps it: that frame never had it."
  (with-current-buffer pane
    (let ((frame ecc-review-talk--frame))
      (setq ecc-review-talk--frame nil)
      (when (frame-live-p frame)
        (delete-frame frame)))))

(defun ecc-review-talk--show-pane (review)
  "Show the reply pane of REVIEW and return its window.
Only for an ediff review, and only while `ecc-review-talk-reply-height'
is a number; nil otherwise, or when the review is on no window.  The
pane is a side window on the side `ecc-review-talk--side' says, taken
down while ediff lays its windows out again with | or m and put back
afterwards, or the frame of its own (`ecc-review-talk-reply-place').
It is not selected."
  (with-current-buffer review
    (when (and ecc-review-talk-reply-height
               (derived-mode-p 'ediff-mode)
               (window-live-p ediff-window-A))
      (let ((pane (ecc-review-talk--pane-buffer review)))
        (or (when-let* ((shown (get-buffer-window pane t)))
              (with-current-buffer pane
                (setq ecc-review-talk--kept nil))
              shown)
            (let ((window (if (eq ecc-review-talk-reply-place 'frame)
                              (ecc-review-talk--in-frame pane)
                            (ecc-review-talk--in-side-window
                             pane (ecc-review-talk--side review)))))
              (when (window-live-p window)
                (with-current-buffer pane
                  (ecc-review-talk--put window ecc-review-talk--kept)
                  (setq ecc-review-talk--kept nil)))
              window))))))

(defun ecc-review-talk--on-displayed (review)
  "Show the reply pane of REVIEW now that it is on the screen.
On `ecc-review-displayed-functions'."
  (when (ecc-review-buffer-p review)
    (with-current-buffer review
      (when (derived-mode-p 'ediff-mode)
        (add-hook 'ediff-before-setup-windows-hook #'ecc-review-talk--leave-the-frame nil t)
        (add-hook 'ediff-after-setup-windows-hook #'ecc-review-talk--keep-the-pane nil t)
        (when (buffer-live-p ediff-buffer-B)
          (with-current-buffer ediff-buffer-B
            (add-hook 'window-size-change-functions #'ecc-review-talk--size-changed nil t)))))
    (ecc-review-talk--show-pane review)))

(add-hook 'ecc-review-displayed-functions #'ecc-review-talk--on-displayed)

(defun ecc-review-talk--recheck-side (review)
  "Move the reply pane of REVIEW to the side `ecc-review-talk--side' says now.
The side is worked out as ediff lays the windows out; the files pane
shown or hidden, and the frame made wider or narrower, change what the
diff is left without ediff laying anything out.  A pane in a frame of
its own, or on the side it should be, is left as it is.  A pane that has
the keyboard -- the user went there to read it back -- has it again on
its new side."
  (when (buffer-live-p review)
    (with-current-buffer review
      (when-let* ((pane ecc-review-talk--pane)
                  ((buffer-live-p pane))
                  ((window-live-p ediff-window-A))
                  (window (seq-find (lambda (window)
                                      (memq (window-parameter window 'ecc-review-talk)
                                            '(right bottom)))
                                    (get-buffer-window-list pane nil t))))
        (unless (eq (window-parameter window 'ecc-review-talk) (ecc-review-talk--side review))
          (let ((selected (eq (selected-window) window)))
            (ecc-review-talk--take-down pane 'side-only)
            (let ((new (ecc-review-talk--show-pane review)))
              (when (and selected (window-live-p new))
                (select-window new)))))))))

(defun ecc-review-talk--size-changed (_window)
  "Check the side of the reply pane once a window of the right side changed size.
On `window-size-change-functions' of the buffer of the right side of an
ediff review, whose window takes what the frame is made wider or
narrower by, and what the files pane takes or gives back as \`s' or
\`q' in it shows or hides it, in either layout.  Run as redisplay finds
the change, not on a timer."
  (ecc-review-talk--recheck-side ecc-review--part-of))

(defun ecc-review-talk--leave-the-frame ()
  "Take the reply pane off the frame when ediff is about to lay out its windows.
On `ediff-before-setup-windows-hook\\=' of the control buffer.  ediff
puts its control panel in the lowest window of the frame
\(`ediff-select-lowest-window\\='), and with the pane there the panel
took the window of the left side instead: after | the review showed
the control buffer where its old text had been.

The hook is run on every recentre, n and p included, and most of them
lay nothing out: the pane is taken down only when ediff will, which it
decides with `ediff-keep-window-config\\=' just after this hook.  A pane
taken down and put back on every key would resize the windows twice a
key and lose the height the user gave it."
  (when-let* ((pane ecc-review-talk--pane)
              ((buffer-live-p pane))
              ((not (ediff-keep-window-config (current-buffer)))))
    (ecc-review-talk--take-down pane 'side-only)))

(defun ecc-review-talk--keep-the-pane ()
  "Show the reply pane again once ediff has laid out its windows.
On `ediff-after-setup-windows-hook\\=' of the control buffer."
  (when (buffer-live-p ecc-review-talk--pane)
    (ecc-review-talk--show-pane (current-buffer))))

(defun ecc-review-talk--end-shown-p (window)
  "Return non-nil when the row the pane ends on is in WINDOW, which shows it.
The pane ends with a newline, and the empty row after it is the one
`ecc-review-talk--window-to-the-end' puts at the bottom: a window
scrolled back by a single row, the last line of text on its bottom row,
does not show the end.  Counted in rows of the screen from the start,
no more than the window has, which needs no redisplay and takes no
longer however far back the window is.  Run in the pane."
  (save-excursion
    (goto-char (window-start window))
    (let ((rows (window-body-height window)))
      (< (vertical-motion rows window) rows))))

;;;;; Where each window is

;; A window of the pane follows its end while the end is in view, and
;; stays where it is once it is not -- scrolled back with u, the mouse
;; wheel or a key of its own.  Which it is is asked of the window before
;; each change, so that nothing has to see the scrolling done.  Where it
;; stays is kept by line, not by position: the pane is written afresh
;; for most changes, and a tool line before the start that has gone
;; from " …" to done is shorter than it was.

(defun ecc-review-talk--place-of (position)
  "Return POSITION of this pane as (LINE . COLUMN), LINE counted from 1."
  (save-excursion
    (goto-char position)
    (cons (line-number-at-pos) (- position (line-beginning-position)))))

(defun ecc-review-talk--position-of (place)
  "Return the position of PLACE, a (LINE . COLUMN), in this pane as it is now.
A line now shorter, or gone, gives its end, or the end of the pane."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- (car place)))
    (min (+ (point) (cdr place)) (line-end-position))))

(defun ecc-review-talk--reading (window)
  "Return where WINDOW of this pane is read from, or nil while it shows the end.
A pair of places (`ecc-review-talk--place-of'): its start and its point."
  (unless (ecc-review-talk--end-shown-p window)
    (cons (ecc-review-talk--place-of (window-start window))
          (ecc-review-talk--place-of (window-point window)))))

(defun ecc-review-talk--put (window reading)
  "Put WINDOW of this pane back to READING, or at the end when it is nil.
READING is what `ecc-review-talk--reading' returned before a change.
The start goes to the beginning of the row of the screen its line and
column fall in, and point is kept where it was while that is in the
window, else put at the start: redisplay would scroll the window to a
point above the start or below its last row -- a window shorter than
the one point was kept in, as | gives the pane -- and lose the start."
  (if (null reading)
      (ecc-review-talk--window-to-the-end window)
    (let* ((start (save-excursion
                    (goto-char (ecc-review-talk--position-of (car reading)))
                    (vertical-motion 0 window)
                    (point)))
           (below (save-excursion
                    (goto-char start)
                    (let ((rows (window-body-height window)))
                      (and (= (vertical-motion rows window) rows) (point)))))
           (point (ecc-review-talk--position-of (cdr reading))))
      (set-window-start window start t)
      (set-window-point window (if (or (< point start) (and below (>= point below)))
                                   start
                                 point)))))

;;;;; Scrolling it

(defun ecc-review-talk--pane-window ()
  "Return the window of the reply pane of this review, or signal there is none."
  (ecc-review-talk--session)
  (or (and (buffer-live-p ecc-review-talk--pane)
           (car (get-buffer-window-list ecc-review-talk--pane nil t)))
      (user-error "This review shows no reply pane")))

(defun ecc-review-talk--scroll-window ()
  "Return the window of the reply pane the scrolling keys move.
The selected window in the pane itself, else the pane of this review."
  (if (derived-mode-p 'ecc-review-talk-mode)
      (selected-window)
    (ecc-review-talk--pane-window)))

(defun ecc-review-talk--scroll (back)
  "Scroll the reply pane half its height, BACK or on.
The start of its window is moved, rows of the screen at a time, and
nothing is selected: the keyboard stays where it was.  On, to where the
end is in view, puts the end at the bottom, where the window follows
it again."
  (let* ((window (ecc-review-talk--scroll-window))
         (lines (max 1 (/ (window-body-height window) 2))))
    (with-current-buffer (window-buffer window)
      (let ((start (window-start window)))
        (if back
            (when (= start (point-min))
              (user-error "At the start of Claude's reply"))
          (when (ecc-review-talk--end-shown-p window)
            (user-error "At the end of Claude's reply")))
        (let ((new (save-excursion
                     (goto-char start)
                     (vertical-motion (if back (- lines) lines) window)
                     (point))))
          (set-window-start window new)
          ;; Where redisplay would not scroll the window back to.
          (set-window-point window new))
        (when (and (not back) (ecc-review-talk--end-shown-p window))
          (ecc-review-talk--window-to-the-end window))))))

(defun ecc-review-talk-scroll-back ()
  "Scroll the reply pane back, to what Claude said before.
It stays there as Claude goes on, until \\[ecc-review-talk-scroll-on]
brings its end into view again or another turn begins.  So does a pane
scrolled back any other way."
  (interactive)
  (ecc-review-talk--scroll t))

(defun ecc-review-talk-scroll-on ()
  "Scroll the reply pane on, toward the end of what Claude says.
Reaching the end, it follows what comes in again."
  (interactive)
  (ecc-review-talk--scroll nil))

;;;;; What it says

(defun ecc-review-talk--short-name (name)
  "Return the tool NAME without the mcp__SERVER__ of this Emacs's server."
  (let ((prefix (format "mcp__%s__" ecc-mcp-server-name)))
    (if (string-prefix-p prefix name) (substring name (length prefix)) name)))

(defun ecc-review-talk--place (input)
  "Return the place in the review the review tool INPUT names, or nil."
  (let ((file (alist-get 'file input))
        (line (alist-get 'line input))
        (hunk (alist-get 'hunk input))
        (comment (alist-get 'comment_id input))
        (direction (alist-get 'direction input))
        (reply (alist-get 'reply_to input)))
    (cond
     (comment (format "#%s" comment))
     (direction (if (equal direction "prev_comment") "previous comment" "next comment"))
     ((and file line) (format "%s:%s%s" file line
                              (if (equal (alist-get 'side input) "old") " (old)" "")))
     ((and file hunk) (format "%s hunk %s" file hunk))
     (file file)
     (reply (format "reply to #%s" reply)))))

(defun ecc-review-talk-tool-summary (name input)
  "Return what the reply pane says of a call to NAME with INPUT, after the name.
A review tool says where in the review; any other tool what the
transcript's heading says."
  (let ((summary
         (pcase (ecc-review-talk--short-name name)
           ((or "review_navigate" "review_hunks") (ecc-review-talk--place input))
           ("review_comment"
            (concat (or (ecc-review-talk--place input) "")
                    (when-let* ((text (alist-get 'text input)))
                      (format ": %s" (ecc--truncate (ecc-render--one-line text) 50)))))
           ("review_comment_apply"
            (ecc-review--count (length (alist-get 'comments input)) "comment"))
           ("review_open" (or (alist-get 'range input)
                              (and (eq (alist-get 'staged input) t) "staged")))
           ("review_list_comments" (alist-get 'author input))
           ("review_remove_comment" (format "#%s" (alist-get 'id input)))
           ("review_clear_comments" (or (alist-get 'file input) "every file"))
           (_ (ecc-render-tool-summary name input)))))
    (if (stringp summary) summary "")))

(defun ecc-review-talk--tool-line (node)
  "Return the line of the reply pane for the tool or agent NODE."
  (let* ((name (or (ecc-model-node-get node 'name) "?"))
         (summary (ecc-review-talk-tool-summary name (ecc-model-node-get node 'input))))
    (concat (propertize (concat "  " (ecc-review-talk--short-name name)
                                (if (string-empty-p summary) "" (concat " → " summary)))
                        'face 'ecc-dim-face)
            (pcase (ecc-node-status node)
              ('running (propertize " …" 'face 'ecc-dim-face))
              ('error (propertize " ✗" 'face 'error))
              ('denied (propertize " (denied)" 'face 'warning))
              (_ ""))
            "\n")))

(defun ecc-review-talk--insert-node (node)
  "Insert what the reply pane says of NODE, a child of the turn it shows."
  (pcase (ecc-node-type node)
    ('text
     (let ((text (or (ecc-model-streaming-text node) (ecc-model-node-get node 'text) "")))
       (unless (and (string-empty-p text) (not (ecc-node-streaming node)))
         (unless (bobp) (insert "\n"))
         (insert text "\n")
         (setq ecc-review-talk--tail node)
         (set-marker ecc-review-talk--tail-end (1- (point))))))
    ('step
     (dolist (child (ecc-node-children node))
       (when (memq (ecc-node-type child) '(tool agent))
         (insert (ecc-review-talk--tool-line child))
         (setq ecc-review-talk--tail nil))))
    ((or 'tool 'agent)
     (insert (ecc-review-talk--tool-line node))
     (setq ecc-review-talk--tail nil))))

(defun ecc-review-talk--request-text (request)
  "Return what the reply pane says of REQUEST: what it asks, whole."
  (let ((input (ecc-request-input request)))
    (pcase (ecc-request-kind request)
      ('question
       (mapconcat
        (lambda (question)
          (concat (propertize (or (alist-get 'question question) "") 'face 'ecc-pending-face)
                  "\n"
                  (let ((n 0))
                    (mapconcat (lambda (option)
                                 (format "  %d. %s%s" (cl-incf n) (alist-get 'label option)
                                         (if-let* ((description (alist-get 'description option)))
                                             (propertize (format " — %s" description)
                                                         'face 'ecc-dim-face)
                                           "")))
                               (append (alist-get 'options question) nil)
                               "\n"))))
        (ecc-question-questions request) "\n"))
      ('plan
       (concat (propertize "Claude has a plan for you to approve:" 'face 'ecc-pending-face)
               "\n" (string-trim (or (alist-get 'plan input) ""))))
      (_
       (concat (propertize (format "Claude asks to use %s:"
                                   (ecc-review-talk--short-name
                                    (or (ecc-request-display-name request)
                                        (ecc-request-tool-name request))))
                           'face 'ecc-pending-face)
               "\n"
               (or (and (equal (ecc-request-tool-name request) "Bash")
                        (alist-get 'command input))
                   (ecc-review-talk-tool-summary (ecc-request-tool-name request) input))
               (if-let* ((description (or (alist-get 'description input)
                                          (ecc-request-description request))))
                   (propertize (format "\n%s" description) 'face 'ecc-dim-face)
                 ""))))))

(defun ecc-review-talk--insert-requests (session)
  "Insert what SESSION is waiting for, the oldest one first, and how to answer."
  (let ((first t))
    (dolist (request (ecc-session-pending session))
      (unless (bobp) (insert "\n"))
      (insert (ecc-review-talk--request-text request) "\n")
      (when first
        (insert (propertize
                 (pcase (ecc-request-kind request)
                   ('question "y answers it here")
                   ('plan "y approves or denies it here")
                   (_ "y allows or denies it here"))
                 'face 'ecc-dim-face)
                "\n")
        (setq first nil))
      (setq ecc-review-talk--tail nil))))

(defun ecc-review-talk--turn (session)
  "Return the turn of SESSION the reply pane shows: the latest one."
  (car (last (ecc-session-turns session))))

(defun ecc-review-talk--write (pane)
  "Write the reply PANE again from its session's latest turn.
A window that showed the end of the pane shows its end again, and one
that did not shows the lines it showed (`ecc-review-talk--reading').
Written from a turn other than the last time, every window follows the
end, and so does the window the pane is shown in next."
  (with-current-buffer pane
    (let* ((session ecc-review-talk--of)
           (turn (ecc-review-talk--turn session))
           (new-turn (not (eq turn ecc-review-talk--shown-turn)))
           (windows (mapcar (lambda (window)
                              (cons window (unless new-turn
                                             (ecc-review-talk--reading window))))
                            (get-buffer-window-list pane nil t)))
           (inhibit-read-only t))
      (when new-turn
        (setq ecc-review-talk--shown-turn turn
              ecc-review-talk--kept nil))
      (erase-buffer)
      (setq ecc-review-talk--tail nil)
      (unless (markerp ecc-review-talk--tail-end)
        (setq ecc-review-talk--tail-end (make-marker)))
      (set-marker-insertion-type ecc-review-talk--tail-end t)
      (if (null turn)
          (insert (propertize "Nothing from Claude yet.  T asks for a tour, M says something.\n"
                              'face 'ecc-dim-face))
        (when-let* ((prompt (ecc-turn-prompt turn)))
          (unless (string-empty-p prompt)
            (insert (propertize (concat "› " (ecc--truncate (ecc-render--one-line prompt) 200))
                                'face 'ecc-dim-face)
                    "\n")))
        (dolist (child (ecc-turn-children turn))
          (ecc-review-talk--insert-node child)))
      (ecc-review-talk--insert-requests session)
      (unless ecc-review-talk--tail
        (set-marker ecc-review-talk--tail-end nil))
      (pcase-dolist (`(,window . ,reading) windows)
        (ecc-review-talk--put window reading)))))

(defun ecc-review-talk--window-to-the-end (window)
  "Put the end of the pane at the bottom of WINDOW, which shows it.
No window is selected for it: the start is reckoned from the end in
the window's own width.  Run in the pane."
  (set-window-point window (point-max))
  (set-window-start window
                    (save-excursion
                      (goto-char (point-max))
                      (vertical-motion (- (max 1 (1- (window-body-height window))))
                                       window)
                      (point))
                    t))

;;;;; Following the session

(defun ecc-review-talk--panes-of (session)
  "Return the reply panes showing SESSION.
A filter and nothing more: it runs on every streamed piece, and a pane
leaves the list as it is killed (`ecc-review-talk--forget')."
  (seq-filter (lambda (pane) (eq (buffer-local-value 'ecc-review-talk--of pane) session))
              ecc-review-talk--panes))

(defun ecc-review-talk--on-change (session &rest _)
  "Write the panes of SESSION again: a turn began, or a request came or went."
  (mapc #'ecc-review-talk--write (ecc-review-talk--panes-of session)))

(defun ecc-review-talk--shown-p (session node)
  "Return non-nil when NODE of SESSION is one the reply pane shows.
What Claude says in the turn and the calls of its steps; not a
subagent's nodes, which the pane never shows, nor a request, which
`ecc-request-added-hook\\=' and `ecc-request-resolved-hook\\=' bring --
answering one changes its node as well, and the pane would be written
twice."
  (let ((turn (ecc-review-talk--turn session))
        (parent (ecc-node-parent node)))
    (and (memq (ecc-node-type node) '(text tool agent))
         (or (eq parent turn)
             (and (ecc-node-p parent)
                  (eq (ecc-node-type parent) 'step)
                  (eq (ecc-node-parent parent) turn))))))

(defun ecc-review-talk--on-node (session node)
  "Write the panes of SESSION again when NODE is one they show."
  (when-let* ((panes (ecc-review-talk--panes-of session)))
    (when (ecc-review-talk--shown-p session node)
      (mapc #'ecc-review-talk--write panes))))

(defun ecc-review-talk--on-delta (session node text)
  "Append TEXT, which streamed into NODE of SESSION, to the panes showing it.
Only what Claude says in the turn itself: a subagent's text and
thinking are not in the pane.  Appended where the node ends, when it is
what the pane ends with, else the pane is written again."
  (when-let* ((panes (ecc-review-talk--panes-of session)))
    (when (and (eq (ecc-node-type node) 'text)
               (eq (ecc-node-parent node) (ecc-review-talk--turn session)))
      (dolist (pane panes)
        (if (and (eq (buffer-local-value 'ecc-review-talk--tail pane) node)
                 (marker-position (buffer-local-value 'ecc-review-talk--tail-end pane)))
            (with-current-buffer pane
              ;; Text added after the start of a window moves nothing in
              ;; it: only the windows that showed the end are put at it.
              (let ((following (seq-filter #'ecc-review-talk--end-shown-p
                                           (get-buffer-window-list pane nil t)))
                    (inhibit-read-only t))
                (save-excursion
                  (goto-char ecc-review-talk--tail-end)
                  (insert text))
                (mapc #'ecc-review-talk--window-to-the-end following)))
          (ecc-review-talk--write pane))))))

(dolist (hook '(ecc-turn-started-hook ecc-request-added-hook ecc-request-resolved-hook))
  (add-hook hook #'ecc-review-talk--on-change))

(add-hook 'ecc-node-added-hook #'ecc-review-talk--on-node)
(add-hook 'ecc-node-updated-hook #'ecc-review-talk--on-node)
(add-hook 'ecc-stream-delta-hook #'ecc-review-talk--on-delta)

(defun ecc-review-talk--on-state (session &rest _)
  "Say the new state of SESSION in the mode line of its panes, and no other."
  (dolist (pane (ecc-review-talk--panes-of session))
    (with-current-buffer pane
      (force-mode-line-update))))

(add-hook 'ecc-session-state-changed-hook #'ecc-review-talk--on-state)

(provide 'ecc-review-talk)

;;; ecc-review-talk.el ends here
