;;; ecc-notify.el --- Telling the user that Claude wants something  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Maintainer: Jun <wakamenod@gmail.com>
;; Package-Requires: ((emacs "29.1"))
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

;; Interruptions worth making.  Three events are worth an interruption:
;; a turn that finished, a request that needs an answer, and a session
;; whose CLI stopped on its own.  How loudly they are announced is
;; `ecc-notify-level', and a desktop notification is held back while the
;; Emacs frame has the focus: the user is looking at it already.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-line)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-visual)
(require 'ecc-window)

(declare-function notifications-notify "notifications" (&rest params))
(declare-function ecc-window-session-visible-p "ecc-window" (session &optional frame))

(defvar ecc-render--session)

(defcustom ecc-notify-level 'message
  "How much noise an event of a session makes.
`message' writes one line in the echo area, `pulse' flashes the
transcript as well, and `desktop' also asks the desktop to show a
notification.  Nil says nothing at all."
  :type '(choice (const :tag "Echo area" message)
                 (const :tag "Echo area and a flash" pulse)
                 (const :tag "Desktop notification" desktop)
                 (const :tag "Nothing" nil))
  :group 'ecc)

(defcustom ecc-notify-events '(turn-finished request exited)
  "Events that are announced."
  :type '(set (const :tag "A turn finished" turn-finished)
              (const :tag "A request needs an answer" request)
              (const :tag "A session stopped on its own" exited))
  :group 'ecc)

(defcustom ecc-notify-function #'ecc-notify-default
  "Function called with SESSION, EVENT and TEXT to announce something.
Replacing it takes over notification completely."
  :type 'function
  :group 'ecc)

(defcustom ecc-notify-sound nil
  "Name of the sound a desktop notification plays, or nil for silence.
On macOS this is the name of a system sound such as \"Glass\"."
  :type '(choice (const :tag "Silent" nil) string)
  :group 'ecc)

(defcustom ecc-notify-suppress-when-focused t
  "Non-nil holds desktop notifications back while Emacs has the focus."
  :type 'boolean
  :group 'ecc)

(defvar ecc-notify-title "Claude Code"
  "Title of a desktop notification.")

;;;; What is announced

(defun ecc-notify-turn-text (session turn)
  "Return the line announcing that TURN of SESSION finished."
  (let ((result (ecc-turn-result turn)))
    (format "%s: done%s"
            (ecc-session-name session)
            (if-let* ((duration (ecc-model-turn-duration turn)))
                (format " (%.1fs%s)" duration
                        ;; `is_error' is false on every turn that went
                        ;; well, and JSON false reads as `:false', which
                        ;; is true to Emacs.
                        (if (ecc--json-true-p (alist-get 'is_error result))
                            ", error" ""))
              ""))))

(defun ecc-notify-request-text (session request)
  "Return the line announcing REQUEST of SESSION."
  (format "%s: waiting on %s"
          (ecc-session-name session)
          (or (ecc-request-display-name request)
              (ecc-request-tool-name request)
              (format "%s" (ecc-request-kind request)))))

;;;; How it is announced

(defun ecc-notify-focused-p ()
  "Return non-nil when a frame of this Emacs has the input focus."
  (and (display-graphic-p)
       (cl-some (lambda (frame)
                  (eq t (frame-focus-state frame)))
                (frame-list))))

(defun ecc-notify-desktop-p ()
  "Return non-nil when this notification should reach the desktop."
  (and (eq ecc-notify-level 'desktop)
       (not (and ecc-notify-suppress-when-focused (ecc-notify-focused-p)))))

(defun ecc-notify--applescript (text)
  "Return the AppleScript that shows TEXT as a notification."
  (let ((escape (lambda (string)
                  (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" (or string "")))))
    (format "display notification \"%s\" with title \"%s\"%s"
            (funcall escape text)
            (funcall escape ecc-notify-title)
            (if ecc-notify-sound
                (format " sound name \"%s\"" (funcall escape ecc-notify-sound))
              ""))))

(defun ecc-notify-desktop (text)
  "Show TEXT as a desktop notification, as far as this system can."
  (cond
   ((eq system-type 'darwin)
    ;; Asynchronously: osascript takes a moment and nothing waits for it.
    (start-process "ecc-notify" nil "osascript" "-e"
                   (ecc-notify--applescript text)))
   ((fboundp 'notifications-notify)
    (notifications-notify :title ecc-notify-title :body text))
   (t (message "%s" text))))

(defun ecc-notify-pulse (session)
  "Flash the first line of the transcript of SESSION, if it is on screen."
  (require 'pulse)
  (when-let* ((buffer (ecc-session-buffer session))
              (window (and (buffer-live-p buffer) (get-buffer-window buffer t))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (when (fboundp 'pulse-momentary-highlight-region)
          (pulse-momentary-highlight-region (point-min) (line-end-position)))))
    window))

(defun ecc-notify-default (session event text)
  "Announce TEXT about EVENT of SESSION at `ecc-notify-level'."
  (when ecc-notify-level
    (message "%s" text)
    (when (memq ecc-notify-level '(pulse desktop))
      (ecc-notify-pulse session))
    (when (ecc-notify-desktop-p)
      (ecc-notify-desktop text))
    (unless (eq event 'turn-finished)
      (force-mode-line-update t))
    t))

(defun ecc-notify (session event text)
  "Announce TEXT about EVENT of SESSION through `ecc-notify-function'."
  (when (and ecc-notify-level (memq event ecc-notify-events))
    (funcall ecc-notify-function session event text)))

;;;; Wiring

(defun ecc-notify--turn-finished (session turn)
  "Announce that TURN of SESSION finished."
  (ecc-notify session 'turn-finished (ecc-notify-turn-text session turn)))

(defun ecc-notify--request-added (session request)
  "Announce that REQUEST of SESSION needs an answer."
  (ecc-notify session 'request (ecc-notify-request-text session request)))

(defun ecc-notify--exited (session status)
  "Announce that the CLI of SESSION stopped with STATUS.
A session the user stopped, and one that stopped with status zero, are
not worth a notification."
  (when (and (integerp status) (/= status 0)
             (not (ecc-proc-stopped-on-request-p session)))
    (ecc-notify session 'exited
                (format "%s: the CLI exited with code %s"
                        (ecc-session-name session) status))))

;;;; The tab line of the sessions

;; Every session is a tab in the tab line of a session window, coloured
;; by what it is doing: running, waiting for an answer, or idle.  Which
;; session the window shows is what the tab line marks as current, and
;; mouse-1 on a tab shows that session in the window the tab was
;; clicked in.
;;
;; The tabs are `tab-line-mode' itself rather than a tab line drawn
;; here: that is where the look of a tab, the scrolling and the
;; click come from.  Only what a tab says, and its colour, are ours.

(defvar ecc-tab-bar-state nil
  "Non-nil marks the state of the sessions in the tab bar too.
`ecc-tab-bar-tab-name' has to be `tab-bar-tab-name-function' for this
to have anywhere to show.")

(defface ecc-tab-running-face
  '((t :inherit (ecc-running-face ecc-heading-face)))
  "Face of the tab of the working session the window is showing.
The yellow green of `ecc-running-face', which the transcript and the
mode line use for the same state, over the weight of a heading."
  :group 'ecc)

(defface ecc-tab-running-dim-face
  '((((class color) (min-colors 88) (background dark)) :foreground "#7a9c33")
    (((class color) (min-colors 88) (background light)) :foreground "#7d9e60")
    (((class color)) :foreground "green")
    (t :inherit default))
  "Face of the tab of a working session the window is not showing.
The full yellow green of `ecc-tab-running-face', bold, reads as the tab
one is looking at, whichever tab that is; a working session elsewhere
says the same thing more quietly, in a shade of the same green and at
the weight of the rest of the row."
  :group 'ecc)

(defface ecc-tab-attention-face
  '((t :inherit ecc-pending-face))
  "Face of the tab of a session that is waiting for an answer."
  :group 'ecc)

(defface ecc-tab-idle-face
  '((t :inherit ecc-dim-face))
  "Face of the tab of a session with nothing to do."
  :group 'ecc)

(defvar ecc-tab-blink t
  "Non-nil blinks the tab of a session that is waiting for an answer.
A tab that wants something is worth more than a colour when the eye is
on the source code.  The rhythm is `ecc-visual-blink-interval', so that
a blinking tab and the blinking line of the request it stands for keep
step.")

(defface ecc-tab-attention-blink-face
  '((t :inherit ecc-tab-attention-face :inverse-video t))
  "Face of a tab waiting for an answer, on every other beat of the blink."
  :group 'ecc)

(defface ecc-tab-current-face
  '((t :inherit (bold ecc-heading-face) :underline t))
  "Face of the tab of the session the window is showing."
  :group 'ecc)

(defvar ecc-tab--blink-phase nil
  "Non-nil on the beat a tab waiting for an answer is drawn lit.")

(defvar ecc-tab--blink-timer nil
  "Timer that blinks the tabs of the sessions waiting for an answer.")

(defun ecc-tab-state (session)
  "Return `attention', `running', `exited' or `idle' for SESSION."
  (cond
   ((ecc-session-pending session) 'attention)
   ((memq (ecc-session-state session) '(starting running compacting)) 'running)
   ((eq (ecc-session-state session) 'exited) 'exited)
   (t 'idle)))

(defun ecc-tab-state-roll-up (sessions)
  "Return the one state that stands for SESSIONS, or nil when there are none.
The loudest wins: a session waiting for an answer speaks for the
group, then one that is working, then one that has died.  Whatever
draws a group of sessions under a single mark -- a tab of the tab bar,
a Space in the sidebar -- folds them with this, so that they all agree
about what the mark means."
  (cond
   ((null sessions) nil)
   ((seq-find (lambda (s) (eq (ecc-tab-state s) 'attention)) sessions) 'attention)
   ((seq-find (lambda (s) (eq (ecc-tab-state s) 'running)) sessions) 'running)
   ((seq-find (lambda (s) (eq (ecc-tab-state s) 'exited)) sessions) 'exited)
   (t 'idle)))

(defun ecc-tab-mark-of-state (state)
  "Return the character that stands for STATE.
A state with nothing to say gets no mark: a row of tabs is quieter
when only the ones that want something are marked.  Somewhere with
room to line the marks up -- the sidebar -- puts its own character in
for the empty one."
  (pcase state
    ('attention "⚠") ('running "▶") ('exited "✗") (_ "")))

(defun ecc-tab-mark (session)
  "Return the character that stands for the state of SESSION."
  (ecc-tab-mark-of-state (ecc-tab-state session)))

(defun ecc-tab-faces (session current)
  "Return the faces to lay over the tab of SESSION, the telling one first.
CURRENT says the window is showing this session."
  (ecc-tab-faces-of-state (ecc-tab-state session) current))

(defun ecc-tab-faces-of-state (state current)
  "Return the faces for STATE, the telling one first.
CURRENT says the window is showing this session.  The state comes
first so that its colour wins, and `ecc-tab-current-face' follows to
add what it alone says -- the weight and the underline that mark the
tab one is looking at.  Putting `current' first instead, as this did
before, cost the tab of the session in front of you the very colour
that says what it is doing.  An idle tab is the one exception, and is
left to `ecc-tab-current-face' alone.  A running tab that is not the
current one takes the quieter `ecc-tab-running-dim-face': the full
green, bold, was bright enough elsewhere in the row to be read as the
tab in front of you."
  (let ((state (if (and ecc-tab--blink-phase (eq state 'attention))
                   'ecc-tab-attention-blink-face
                 (pcase state
                   ('attention 'ecc-tab-attention-face)
                   ('running (if current
                                 'ecc-tab-running-face
                               'ecc-tab-running-dim-face))
                   ('exited 'ecc-error-face)
                   (_ 'ecc-tab-idle-face)))))
    (cond
     ;; Idle is not a colour so much as the want of one: the dim face
     ;; is there to sink the sessions with nothing to say into the
     ;; background, and the one being read does not belong there.  Dim
     ;; and current together read as neither.
     ((and current (eq state 'ecc-tab-idle-face))
      (list 'ecc-tab-current-face))
     (current (list state 'ecc-tab-current-face))
     (t (list state)))))

(defvar ecc-tab-line-scope 'project
  "Which sessions the tab line of a session window lists.
`project' lists the sessions of that window's own project, so that a
row of tabs is the handful one is working among rather than every
session this Emacs has open; `all' lists them all.

A session outside the scope is still there and still reached:
`ecc-switch-session', the dashboard and `ecc-next-attention' all cross
projects.  What is given up is that its tab is not on the screen to
blink when it wants an answer -- the count in the mode line and
`ecc-notify-mode' are what say so then.")

;; Defined by the minor mode below; named here because the tab line is
;; asked about from above it.
(defvar ecc-tab-line-mode)

(defun ecc-tab-line--sessions (session)
  "Return the sessions a tab line about SESSION lists, the oldest first.
The sessions of SESSION\='s own project, or every session there is when
`ecc-tab-line-scope\=' says so or when SESSION is nil -- a tab line drawn
in a buffer that is nobody\='s session.

The registry is kept most recently used first, which is the wrong
order for a row of tabs -- they would move about as one works -- so the
sessions are put back into the order they were made in."
  (let ((sessions (if (and session (eq ecc-tab-line-scope 'project))
                      (ecc-window-project-sessions
                       (ecc-window-session-project session))
                    (ecc-model-sessions))))
    (sort (copy-sequence sessions)
          (lambda (a b)
            (< (or (ecc-session-created a) 0)
               (or (ecc-session-created b) 0))))))

(defun ecc-tab-line-tabs ()
  "Return the session buffers of this window, oldest session first.
This is `tab-line-tabs-function' in a session buffer, and redisplay
evaluates it in the buffer of the window being drawn, which is how the
tabs of one window come to be the sessions of its own project.
`ecc-tab-line-scope' widens that to every session, and so does being
called anywhere but in a session buffer."
  (seq-filter #'buffer-live-p
              (mapcar #'ecc-session-buffer
                      (ecc-tab-line--sessions (ecc-window-buffer-session)))))

(defun ecc-tab-line-neighbour (session &optional frame)
  "Return the buffer of the tab beside the one SESSION had, or nil.
What a window showing SESSION moves to when that tab is closed: the tab
to the right of it, and the tab to the left when it was the rightmost.
Closing a tab is stopping the session behind it (`ecc-tab-close\='), and a
window is not a thing to take away because one of the tabs in it went.

A tab another window of FRAME is already showing is not an answer.  A
Space stands its transcripts side by side, every one of them with the
same row of tabs above it, and moving to the tab next door would put
the same transcript in two windows.  FRAME defaults to the selected
one; the windows of another tab of it are not on the screen and do not
count.

The tabs are the ones of SESSION\='s row, so under `ecc-tab-line-scope\='
`all\=' the answer can be a session of another project -- which is what
that setting asks for: a row of tabs that crosses projects, and
clicking one of them does the same thing.

SESSION is out of the registry by the time this is asked -- the caller
is on `ecc-session-removed-hook\=' -- so what comes back is the tabs that
are left, and the place SESSION held among them is its `created\='
number.

nil is the answer when no tab is left to move to, and when the tab line
is off: there is then no row of tabs the window is one of, and whoever
asked has its own answer for a window with nothing to show."
  (when ecc-tab-line-mode
    (let* ((frame (or frame (selected-frame)))
           (created (or (ecc-session-created session) 0))
           (sessions (seq-filter
                      (lambda (other)
                        (let ((buffer (ecc-session-buffer other)))
                          (and (buffer-live-p buffer)
                               (not (get-buffer-window buffer frame)))))
                      (ecc-tab-line--sessions session)))
           (beside (or (seq-find (lambda (other)
                                   (> (or (ecc-session-created other) 0) created))
                                 sessions)
                       (car (last sessions)))))
      (and beside (ecc-session-buffer beside)))))

(defun ecc-tab-line-tab-name (buffer &optional _tabs)
  "Return what the tab of BUFFER says (`tab-line-tab-name-function')."
  (let ((session (and (buffer-live-p buffer)
                      (buffer-local-value 'ecc-render--session buffer))))
    (if (not session)
        (buffer-name buffer)
      (let ((mark (ecc-tab-mark session)))
        (format " %s%s "
                (if (string-empty-p mark) "" (concat mark " "))
                (ecc--truncate (ecc-session-name session) 20))))))

(defun ecc-tab-line-tab-face (tab _tabs face buffer-p selected-p)
  "Colour the tab of a session by its state (`tab-line-tab-face-functions').
TAB is a buffer when BUFFER-P, and SELECTED-P says it is the one the
window shows.  FACE is what the tab line settled on, which is kept
underneath so that the theme still decides the shape of a tab."
  (let* ((buffer (if buffer-p tab (cdr (assq 'buffer tab))))
         (session (and (buffer-live-p buffer)
                       (buffer-local-value 'ecc-render--session buffer))))
    (if session
        `(:inherit (,@(ecc-tab-faces session selected-p) ,face))
      face)))

(defvar ecc-tab-close-confirm t
  "Non-nil asks before the x of a tab stops the session it stands for.
Closing a tab here is not the cheap, undoable thing it is elsewhere in
Emacs -- it stops the CLI and forgets the transcript -- so it asks
first.")

(declare-function ecc-kill "ecc" (session))

(defun ecc-tab-close (buffer)
  "Stop the session of BUFFER (`tab-line-close-tab-function').
The tabs are the sessions of the registry rather than the buffers of a
window, so the tab line's own answer to the x -- burying the buffer --
left the tab exactly where it was (confirmed 2026-09-10).  Closing the
tab of a session is stopping it, which `ecc-tab-close-confirm' asks
about first.  A buffer with no session behind it is only killed."
  (let ((session (and (buffer-live-p buffer)
                      (buffer-local-value 'ecc-render--session buffer))))
    (cond
     ((not (buffer-live-p buffer)) nil)
     ((null session) (kill-buffer buffer))
     ((and ecc-tab-close-confirm
           (not (y-or-n-p (format "Stop %s? " (ecc-session-name session)))))
      (message "Left %s running" (ecc-session-name session)))
     (t (require 'ecc)
        (ecc-kill session)))))

;; `tab-line-force-update' is Emacs 30 and later (confirmed 2026-09-10 on
;; the CI matrix, which builds on 29.1).  What it does is what the blink
;; does by hand: drop the per-window cache, then ask for a redisplay.
(defun ecc-tab--force-update ()
  "Draw the tab lines again, cache and all."
  (if (fboundp 'tab-line-force-update)
      (funcall 'tab-line-force-update t)
    (dolist (window (window-list-1 nil nil t))
      (set-window-parameter window 'tab-line-cache nil))
    (force-mode-line-update t)))

(defun ecc-tab-line--install (&rest _)
  "Put the tab line in every session buffer, or take it out again.
The tabs are the ones of `tab-line-mode' itself, so that they look and
behave like tabs: clicking one shows that session in the window the tab
was clicked in, which is the whole point of them."
  (dolist (session (ecc-model-sessions))
    (when-let* ((buffer (ecc-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (cond
           (ecc-tab-line-mode
            (setq-local tab-line-tabs-function #'ecc-tab-line-tabs
                        tab-line-tab-name-function #'ecc-tab-line-tab-name
                        tab-line-tab-face-functions '(ecc-tab-line-tab-face)
                        tab-line-close-tab-function #'ecc-tab-close)
            (tab-line-mode 1))
           (t
            (tab-line-mode -1)
            (kill-local-variable 'tab-line-tabs-function)
            (kill-local-variable 'tab-line-tab-name-function)
            (kill-local-variable 'tab-line-tab-face-functions)
            (kill-local-variable 'tab-line-close-tab-function)))))))
  ;; A tab line is cached per window on a key that does not know a
  ;; session's state, so a state that changed needs the cache cleared
  ;; rather than a redisplay alone.
  (ecc-tab--force-update)
  (ecc-tab-blink-update))

;;;; Blinking the tabs that want an answer

(defun ecc-tab--waiting-p ()
  "Return non-nil when some session is waiting for an answer."
  (seq-some (lambda (session) (eq (ecc-tab-state session) 'attention))
            (ecc-model-sessions)))

(defun ecc-tab--windows ()
  "Return the windows showing a session buffer, on any frame."
  (let (windows)
    (dolist (session (ecc-model-sessions))
      (let ((buffer (ecc-session-buffer session)))
        (when (buffer-live-p buffer)
          (setq windows (nconc (get-buffer-window-list buffer nil t) windows)))))
    windows))

(defun ecc-tab--blink-redisplay ()
  "Draw the tab lines of the session windows again.
The tab line of a window is cached on a key that knows nothing of the
blink, so the cache is what has to go; a redisplay on its own would
show the same tabs over again."
  (when-let* ((windows (ecc-tab--windows)))
    (dolist (window windows)
      (set-window-parameter window 'tab-line-cache nil))
    (force-mode-line-update t)
    windows))

(defun ecc-tab-blink-stop ()
  "Stop the blink and leave the waiting tabs lit no longer."
  (when ecc-tab--blink-timer
    (cancel-timer ecc-tab--blink-timer)
    (setq ecc-tab--blink-timer nil))
  (when ecc-tab--blink-phase
    (setq ecc-tab--blink-phase nil)
    (ecc-tab--blink-redisplay)
    (run-hooks 'ecc-tab-blink-functions)))

(defvar ecc-tab-blink-functions nil
  "Functions run on every beat of the blink, and once when it stops.
Whatever draws the waiting sessions somewhere other than the tab line
-- the sidebar -- puts itself here, so that everything on the screen
blinks on the same beat rather than each on a timer of its own.")

(defun ecc-tab--blink-tick ()
  "Turn the waiting tabs on or off, and stop once nothing is waiting."
  (if (not (and ecc-tab-line-mode ecc-tab-blink (ecc-tab--waiting-p)))
      (ecc-tab-blink-stop)
    (setq ecc-tab--blink-phase (not ecc-tab--blink-phase))
    ;; A session with no window costs only this: there is nothing on the
    ;; screen to draw again.
    (ecc-tab--blink-redisplay)
    (run-hooks 'ecc-tab-blink-functions)))

(defun ecc-tab-blink-update ()
  "Blink the tabs while a session waits for an answer, and stop after.
Called from `ecc-tab-line--install', which every event that changes
what a tab says already goes through."
  (if (and ecc-tab-line-mode ecc-tab-blink (ecc-tab--waiting-p))
      (unless ecc-tab--blink-timer
        (setq ecc-tab--blink-timer
              (run-at-time ecc-visual-blink-interval ecc-visual-blink-interval
                           #'ecc-tab--blink-tick)))
    (ecc-tab-blink-stop)))

(define-minor-mode ecc-tab-line-mode
  "List every session in the tab line of the session windows."
  :global t
  :group 'ecc
  (if ecc-tab-line-mode
      (progn
        (add-hook 'ecc-session-state-changed-hook #'ecc-tab-line--install)
        (add-hook 'ecc-request-added-hook #'ecc-tab-line--install)
        (add-hook 'ecc-request-resolved-hook #'ecc-tab-line--install)
        (add-hook 'ecc-session-init-hook #'ecc-tab-line--install))
    (remove-hook 'ecc-session-state-changed-hook #'ecc-tab-line--install)
    (remove-hook 'ecc-request-added-hook #'ecc-tab-line--install)
    (remove-hook 'ecc-request-resolved-hook #'ecc-tab-line--install)
    (remove-hook 'ecc-session-init-hook #'ecc-tab-line--install))
  (ecc-tab-line--install))

(defun ecc-tab-bar-tab-name ()
  "Return the name of the current tab, marked with the state of its sessions.
Set `tab-bar-tab-name-function' to this to see in the tab bar which
tab is waiting for an answer."
  (let* ((name (funcall (default-value 'tab-bar-tab-name-function)))
         (sessions (seq-filter (lambda (session)
                                 (when-let* ((buffer (ecc-session-buffer session)))
                                   (get-buffer-window buffer)))
                               (ecc-model-sessions)))
         ;; Only the two states that ask for something are drawn here:
         ;; a tab is not the place to be told that a session finished.
         (state (car (memq (ecc-tab-state-roll-up sessions)
                           '(attention running)))))
    (if (and ecc-tab-bar-state state)
        (format "%s %s"
                (pcase state ('attention "⚠") (_ "▶"))
                name)
      name)))

(define-minor-mode ecc-notify-mode
  "Announce what the sessions of this Emacs are waiting for."
  :global t
  :group 'ecc
  (if ecc-notify-mode
      (progn
        (add-hook 'ecc-turn-finished-hook #'ecc-notify--turn-finished)
        (add-hook 'ecc-request-added-hook #'ecc-notify--request-added)
        (add-hook 'ecc-session-exited-hook #'ecc-notify--exited))
    (remove-hook 'ecc-turn-finished-hook #'ecc-notify--turn-finished)
    (remove-hook 'ecc-request-added-hook #'ecc-notify--request-added)
    (remove-hook 'ecc-session-exited-hook #'ecc-notify--exited)))

(provide 'ecc-notify)

;;; ecc-notify.el ends here
