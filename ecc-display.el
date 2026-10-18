;;; ecc-display.el --- Showing a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Assisted-by: Claude Code:claude-opus-5-5
;; Assisted-by: Claude Code:claude-fable-5-1
;; Assisted-by: Claude Code:claude-haiku-4-5
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

;; Showing the buffer of a session: in its window, beside it, a review
;; beside it, and switching a window from one session to another.
;;
;; Every module that shows a session comes here -- a question answered,
;; the sidebar, a recording opened, a restore -- and the buffer shown is
;; made by `ecc-chat', with the prompt in it.  So this file sits above
;; `ecc-chat' and below all of those, and `ecc-window', below `ecc-chat',
;; keeps to the projects, the sources, the regions and which session a
;; command means.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-window)
(require 'ecc-chat)

;;;; Showing a session

(defun ecc-display-session-in-role (session role)
  "Show the buffer of SESSION in the window of ROLE and return that window.
A window that is there already keeps its place: what is in it is
replaced rather than a second window being opened."
  ;; The tab line changes what a window shows with `switch-to-buffer',
  ;; which costs a side window its dedication; so does anything else the
  ;; user does in one.  Nothing else puts it back, so this watches, from
  ;; the first window with a role on: before it there is nothing to
  ;; watch, and the Spaces give no window a role.
  (add-hook 'window-buffer-change-functions #'ecc-window-repair-side-windows)
  (when (memq role '(sub-1 sub-2))
    (setq ecc-window--last-sub role))
  (let ((buffer (ecc-session-ensure-buffer session))
        (window (ecc-window--role-window role)))
    (cond
     ;; `set-window-buffer' would do, but it drops the `side' dedication
     ;; of a side window, and an undedicated side window is the next
     ;; thing `display-buffer' takes.  Asking for the side window again
     ;; reuses the same one and leaves it dedicated.
     ((eq role 'sub-2)
      (if (window-live-p window)
          (progn (set-window-buffer window buffer)
                 (set-window-parameter window 'ecc-window-role role)
                 window)
        (display-buffer-in-direction buffer (ecc-window--sub-2-parameters))))
     (t
      (display-buffer-in-side-window
       buffer (ecc-window--side-parameters role))))))

(defun ecc-display-session (session)
  "Show the buffer of SESSION and return its window.
The window is not selected; `ecc-window-select-session' does that.
Where it is shown is `ecc-window--show-session'."
  (ecc-window--show-session (ecc-window--layout) session))

(cl-defgeneric ecc-window--show-session (_layout session)
  "Show the buffer of SESSION under LAYOUT and return its window.
Under `classic' the session goes into a window role, or to a plain
`display-buffer' without `ecc-window-use-side-window'; `ecc-space'
shows it in its Space under `spaces'."
  (if (not ecc-window-use-side-window)
      (display-buffer (ecc-session-ensure-buffer session))
    (ecc-display-session-in-role session (ecc-window-role-for session))))

(defun ecc-window-display-beside-session (buffer session &optional no-select)
  "Show BUFFER beside the window of SESSION and return the window.
Everything that opens a buffer of its own out of one conversation goes
through here: a question, a plan, a log, an agent transcript, a node
laid open.  Where it lands is `ecc-window--place-beside\='.

The window is selected unless NO-SELECT says otherwise: the buffer is
opened to be read or answered."
  (let ((window (ecc-window--place-beside (ecc-window--layout)
                                          buffer session no-select)))
    (when (and (not no-select) (window-live-p window))
      (select-window window))
    window))

(cl-defgeneric ecc-window--place-beside (_layout buffer _session no-select)
  "Show BUFFER beside the window of SESSION under LAYOUT; return the window.
Under `classic' it is `pop-to-buffer\=', which is what it always was, or
`display-buffer\=' when NO-SELECT says the buffer is not to be selected.
Under `spaces' `ecc-space' lets the Space decide, and there it never
takes the window of another session."
  (if no-select
      (display-buffer buffer)
    (pop-to-buffer buffer)
    (get-buffer-window buffer)))

(defun ecc-window-select-session (session)
  "Show the buffer of SESSION, select its window and go to the prompt.
That is where something can be typed, which is what showing a session
is usually for."
  (let ((window (ecc-display-session session)))
    (when (window-live-p window)
      (select-window window)
      (ecc-chat-goto-prompt))
    window))

;;;; Opening a review

;; A diff or a plan wants room, and the session windows are what there
;; is to take it from.  What happens is the user's to decide: whether
;; the session windows step aside, and where point ends up.

(defvar ecc-window-hide-on-review nil
  "Whether opening a diff or a plan review hides the session windows.
`project' hides the sessions of the project being reviewed, `all' hides
every session, and nil leaves the windows as they are, which is the
default.

What was hidden is not written down.  Under `spaces\=' the way back is
`ecc-space-cycle-layout\=', which deals the tab again; under `classic\='
it is `ecc-focus-project\=', or `ecc-show-session\=' one session at a
time.")

(defvar ecc-window-review-focus 'review
  "Where point goes when a diff or a plan review opens.
`review' selects the review, `session' leaves it in the transcript and
nil leaves it wherever it was.")

(defun ecc-window-hide-for-review (&optional session)
  "Take the session windows `ecc-window-hide-on-review\=' asks for off the screen.
SESSION is the session being reviewed, which decides what `project'
means.  This is the half of opening a review that a review shown by
something other than `display-buffer\=' -- ediff lays out its own
windows -- still wants."
  (ecc-window-hide-sessions
   (pcase ecc-window-hide-on-review
     ('all (ecc-model-sessions))
     ('project (if session
                   (ecc-window-project-sessions
                    (ecc-session-project-root session))
                 (ecc-window-project-sessions)))
     (_ nil))))

(defun ecc-window-display-review (buffer &optional session)
  "Show the review in BUFFER, of SESSION, and return its window.
`ecc-window-hide-on-review' and `ecc-window-review-focus' decide what
happens to the session windows and where point lands."
  (ecc-window-hide-for-review session)
  (let ((window (if session
                    (ecc-window-display-beside-session buffer session t)
                  (display-buffer buffer))))
    (pcase ecc-window-review-focus
      ('review (when (window-live-p window) (select-window window)))
      ('session
       (when-let* ((buffer (and session (ecc-session-buffer session)))
                   (session-window (and (buffer-live-p buffer)
                                        (get-buffer-window buffer))))
         (select-window session-window))))
    window))

(defun ecc-window-show-review-quietly (buffer session &optional replaceable)
  "Show the review in BUFFER beside SESSION without moving anybody.
Returns the window that shows it, or nil.  This is how a review Claude
opened or moved reaches the screen: the user is somewhere else -- very
likely typing in the prompt -- so nothing is selected, no session
window is hidden, and `ecc-window-review-focus\=' and
`ecc-window-hide-on-review\=' are not consulted, both being about a
review the user asked for.

A review already on a visible frame is left where it is.  Otherwise it
is shown only when SESSION is on the screen of the selected frame --
which is the tab showing, so no tab or Space is ever gone to -- and
never in the window the user is in: the selected one, or the one the
minibuffer was entered from.  REPLACEABLE, a predicate on a buffer,
names what may be put out of its window -- another review of the same
session, so that a second review takes the window of the first rather
than dividing the session again.  Then the widest window holding
nothing of this package, then a new one divided off the session\='s.
Not `ecc-window-display-beside-session\=': under `spaces\=' that selects
the Space of the session, and may pick the very window the user is
typing in, which would then take their next keys.  Where there is no
such window the review waits in its buffer, and nil says so.

A rule of the user\='s own in `display-buffer-alist\=' that matches
BUFFER is followed instead (`ecc-window--display-by-rule\=') -- as long
as it too leaves the user\='s window, and tab, alone."
  (or (get-buffer-window buffer 'visible)
      (when-let* ((session-buffer (ecc-session-buffer session))
                  ((buffer-live-p session-buffer))
                  (session-window (get-buffer-window session-buffer)))
        (if (ecc-window--user-rule-p buffer)
            (ecc-window--display-by-rule buffer)
          (pcase (ecc-window--quiet-review-window session-window replaceable)
            (`(,window . ,type)
             ;; `window' for a window made for it, so that `quit-window'
             ;; deletes it; `reuse' for one it borrowed, so that the
             ;; buffer that was there comes back.  A new window also
             ;; forgets the buffer `split-window' gave it to begin with,
             ;; as `display-buffer' has it forget: with that one in its
             ;; history `quit-window' shows it again rather than deleting
             ;; the window (Emacs 32.0.50, 2026-10-01).
             (display-buffer-record-window type window buffer)
             (set-window-buffer window buffer)
             (when (eq type 'window)
               (set-window-prev-buffers window nil))
             window))))))

(defun ecc-window--users-windows ()
  "Return the windows the user is working in.
The selected one, and while the minibuffer is active the one it was
entered from -- the window a \\[find-file] or an \\[execute-extended-command] goes back to."
  (delq nil (list (selected-window) (minibuffer-selected-window))))

(defun ecc-window--quiet-review-window (session-window replaceable)
  "Return (WINDOW . TYPE) for a review to go in quietly beside SESSION-WINDOW.
TYPE is `reuse\=' for a window that shows something else now and `window\='
for one divided off SESSION-WINDOW.  REPLACEABLE is the predicate of
`ecc-window-show-review-quietly\='.  Nil when there is none."
  (let* ((users (ecc-window--users-windows))
         (free (seq-filter (lambda (window)
                             (and (not (memq window users))
                                  (not (window-parameter window 'window-side))
                                  (not (window-dedicated-p window))))
                           (window-list nil 'no-minibuffer)))
         (widest (lambda (windows)
                   (car (sort windows (lambda (a b) (> (window-total-width a)
                                                       (window-total-width b))))))))
    (if-let* ((window (or (and replaceable
                               (funcall widest
                                        (seq-filter (lambda (window)
                                                      (funcall replaceable
                                                               (window-buffer window)))
                                                    free)))
                          (funcall widest
                                   (seq-remove (lambda (window)
                                                 (ecc-window-own-buffer-p
                                                  (window-buffer window)))
                                               free)))))
        (cons window 'reuse)
      (when-let* ((window (ecc-window--split-quietly session-window)))
        (cons window 'window)))))

(defvar ecc-window-quiet-split-min-height 8
  "Fewest lines each half has when a review divides a session window.")

(defun ecc-window--split-quietly (session-window)
  "Divide SESSION-WINDOW for a review and return the new window, or nil.
To the right when it has room for two columns of 80, which is what a
diff wants to be read in; below it when it has room for two halves of
`ecc-window-quiet-split-min-height\=' lines; not at all otherwise, nor
when it is a side window.  The selected window stays selected and keeps
its buffer: the new window is the other half.  The room is measured
first, so that a window too small to divide is an answer and not an
error, and any other error of `split-window\=' is left to be seen."
  (unless (window-parameter session-window 'window-side)
    (let ((direction
           (cond ((>= (window-total-width session-window) 160) 'right)
                 ((>= (window-total-height session-window)
                      (* 2 (max ecc-window-quiet-split-min-height window-min-height)))
                  'below))))
      (when direction
        (split-window session-window nil direction)))))

(defun ecc-window--user-rule-p (buffer)
  "Return non-nil when `display-buffer-alist\=' has a rule for BUFFER."
  (seq-some (lambda (entry)
              (buffer-match-p (car entry) (buffer-name buffer) nil))
            display-buffer-alist))

(defun ecc-window--display-by-rule (buffer)
  "Show BUFFER the way the user\='s `display-buffer-alist\=' says, or not at all.
Returns the window, or nil.  The rule is followed through
`display-buffer\=' with the selected window kept and no other frame
switched to; afterwards the window the user is in has to hold what it
held, and the tab has to be the one it was.  A rule that took either --
it is theirs, and may say anything -- is undone, and the review waits in
its buffer."
  (let* ((users (mapcar (lambda (window) (cons window (window-buffer window)))
                        (ecc-window--users-windows)))
         (configuration (current-window-configuration))
         (tab (and (fboundp 'tab-bar--current-tab-index) (tab-bar--current-tab-index)))
         (window (save-selected-window
                   (display-buffer buffer '(nil (inhibit-switch-frame . t)
                                                (inhibit-same-window . t)))))
         (now (and (fboundp 'tab-bar--current-tab-index) (tab-bar--current-tab-index))))
    (if (and (window-live-p window)
             (equal tab now)
             (not (assq window users))
             (seq-every-p (lambda (user)
                            (and (window-live-p (car user))
                                 (eq (window-buffer (car user)) (cdr user))))
                          users))
        window
      (unless (equal tab now)
        (tab-bar-select-tab (1+ tab)))
      (set-window-configuration configuration)
      nil)))

;;;; Focusing one project

;; The two commands here that dispatch on the layout are autoloaded from
;; `ecc' and not from this file.  Under `spaces' their answer is a method
;; of `ecc-space', which this file does not load, and an autoload that
;; loaded it alone gave the `classic' answer to the first command of the
;; day: `ecc-focus-project' refused a project with no session instead of
;; making its Space.  Loading the package is what the first command does.
;;;###autoload (autoload 'ecc-focus-project "ecc" "Show the sessions of ROOT alone, and its source in the main window." t)
(defun ecc-focus-project (root &optional choose)
  "Show the sessions of ROOT alone, and its source in the main window.
The session windows of every other project are taken off the screen;
nothing is killed and no process is stopped, so focusing one of those
projects brings its windows back.  CHOOSE, a prefix argument
interactively, asks which buffer of ROOT to show instead of taking the
likeliest.

The sessions of ROOT are dealt into the window roles in the order they
were last used, so the one worked in last is the one in the main
window.

With `spaces' there is nothing to deal and nothing to hide: the Space
of ROOT is a tab, and going to it brings back the windows the user
arranged there.  CHOOSE has no meaning then, the buffers of the tab
being whatever they were left as."
  (interactive (list (ecc-window-read-project "Focus project: ")
                     current-prefix-arg))
  (let ((key (ecc-window-project-key root)))
    (ecc-window--focus (ecc-window--layout)
                       key (ecc-window-project-sessions key) choose)))

(cl-defgeneric ecc-window--focus (_layout key sessions choose)
  "Focus the project KEY under LAYOUT and return SESSIONS, its sessions.
CHOOSE is that of `ecc-focus-project'.  Under `classic' the session
windows of every other project come down, SESSIONS are dealt into the
roles and the source of KEY goes in the main window.  Under `spaces'
`ecc-space' goes to the Space of KEY instead."
  (unless sessions
    (user-error "No session in %s" (abbreviate-file-name key)))
  (let ((hidden (ecc-window-hide-sessions
                 (seq-remove (lambda (session) (memq session sessions))
                             (ecc-window-displayed-sessions)))))
    (when ecc-window-use-side-window
      ;; The roles are dealt out again from nothing, so a window one of
      ;; these sessions already holds comes down first.  Moving a session
      ;; from one role to another otherwise leaves the window it came from
      ;; showing it as well, and the frame ends up with the same
      ;; transcript twice (confirmed 2026-09-13).
      (mapc #'ecc-window-hide-session sessions)
      (cl-mapc #'ecc-display-session-in-role
               sessions (ecc-window-available-roles)))
    (ecc-window--focus-source key choose)
    (message "Focused %s: %d session%s, %d hidden"
             (ecc--project-label key) (length sessions)
             (if (= 1 (length sessions)) "" "s") (length hidden))
    sessions))

;;;; Switching a window to another session

(defun ecc-window--switch-target ()
  "Return the window `ecc-switch-session' should change, or nil.
The current window when it shows a session or carries a role, and
`main' otherwise: a command run from the source code means the session
one is looking at.  The windows of a Space carry no role, so there it
is the current window or none, and none means the Space that is
showing."
  (let ((window (selected-window)))
    (if (or (window-parameter window 'ecc-window-role)
            (ecc-window-buffer-session (window-buffer window)))
        window
      (ecc-window--role-window 'main))))

;; Defined in `ecc-notify', which is above this file; read here so that
;; the sessions `ecc-switch-session' offers are the tabs on the screen.
(defvar ecc-tab-line-scope)

(defun ecc-window--switch-row (window)
  "Return the sessions of the tab row of WINDOW, most recently started first.
The row of the session WINDOW shows: its project, or every session when
`ecc-tab-line-scope' is `all', which is what `ecc-tab-line--sessions'
draws.  A WINDOW that shows no session has no row, and the project
meant is the Space that is showing, or under `classic' the one
`ecc-start' would use."
  (let ((session (and (window-live-p window)
                      (ecc-window-buffer-session (window-buffer window)))))
    ;; The same rule as `ecc-tab-line--sessions'; change them together.
    (cond
     ((eq (bound-and-true-p ecc-tab-line-scope) 'all) (ecc-model-sessions))
     (session (ecc-window-project-sessions
               (ecc-window-session-project session)))
     (t (ecc-window-project-sessions
         (or (ecc-window--tab-root (ecc-window--layout))
             (ecc-window-context-project-root)))))))

(defun ecc-window--read-switch (every)
  "Ask which session `ecc-switch-session' should show.
The sessions of the tab row of the window being switched, or every
session when EVERY; the one that window already shows is not among them."
  (let* ((window (ecc-window--switch-target))
         (current (and (window-live-p window)
                       (ecc-window-buffer-session (window-buffer window))))
         (sessions (remq current (if every
                                     (ecc-model-sessions)
                                   (ecc-window--switch-row window)))))
    (cond
     (sessions (ecc-window-read-session "Switch to: " sessions))
     ((or every (eq (bound-and-true-p ecc-tab-line-scope) 'all))
      (user-error "No other session is running"))
     (t (user-error "%s" (substitute-command-keys
                          "No other session in this project; \\[universal-argument] \\[ecc-switch-session] lists them all"))))))

;; Autoloaded from `ecc', as `ecc-focus-project' is and for its reason.
;;;###autoload (autoload 'ecc-switch-session "ecc" "Show SESSION in this window, the way clicking its tab would." t)
(defun ecc-switch-session (session)
  "Show SESSION in this window, the way clicking its tab would.
Which session a window shows is the user's to choose: this is the same
choice the tab line offers, for when the tabs are not to hand.

Interactively the choice is the tabs of this window -- the sessions of
its project, or all of them under `ecc-tab-line-scope' `all' -- less the
one it already shows.  With a prefix argument it is every session.

Under `spaces' a session from outside the row is not put into this
window, where it would sit among another project's tabs: it is shown in
its own Space, by `ecc-window-select-session'.  One another window of
this Space already shows is selected there rather than shown twice.
Under `classic' there is no Space for it to go to, and the session is
put into this window whatever its project."
  (interactive (list (ecc-window--read-switch current-prefix-arg)))
  (let* ((window (ecc-window--switch-target))
         (frame (and (window-live-p window) (window-frame window)))
         (buffer (ecc-session-buffer session))
         (shown (and ecc-use-spaces frame (buffer-live-p buffer)
                     (get-buffer-window buffer frame))))
    (cond
     ((or (not frame)
          (and ecc-use-spaces
               (not (memq session (ecc-window--switch-row window)))))
      (ecc-window-select-session session))
     (shown
      (select-window shown)
      (ecc-chat-goto-prompt)
      shown)
     (t
      (set-window-buffer window (ecc-session-ensure-buffer session))
      (ecc-window-repair-side-windows frame)
      (select-window window)
      (ecc-chat-goto-prompt)
      window))))

(defvar ecc-display-chat-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'ecc-switch-session)
    map)
  "The keys of this file in the prompt region of a session buffer.
A parent of `ecc-chat-mode-map'.")

(ecc-chat-add-keymap-parent ecc-chat-mode-map ecc-display-chat-map)

(provide 'ecc-display)

;;; ecc-display.el ends here
