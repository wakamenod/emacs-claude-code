;;; ecc-window.el --- Where the session buffers are shown  -*- lexical-binding: t; -*-

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

;; The project a session or a buffer belongs to, the window roles,
;; taking transcripts off the screen, the name a session goes by and the
;; rule that decides which session a command sends to.  Showing a
;; session is `ecc-display', above this file and above `ecc-chat', which
;; makes the buffer that is shown.
;;
;; It also keeps track of the last buffer the user worked in that is not
;; part of this package, which is the source `ecc-context' quotes from.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-visual)

;; What a session window does under `spaces' is not decided here.  The
;; operations whose answer depends on the layout -- which project the tab
;; showing stands for, what a group of sessions is called, and in
;; `ecc-display' where a session or a buffer beside it is shown and what
;; focusing a project does -- are generic functions of the layout,
;; `ecc-window--layout', whose default body is the `classic' answer;
;; `ecc-space', which requires both files, specialises each of them on
;; `spaces'.  No code here calls into `ecc-space': the Spaces are built
;; on top of the windows, and the dependency runs that way alone.  With `ecc-use-spaces' nil no method of
;; `ecc-space' is ever chosen.

(defun ecc-window--layout ()
  "Return the layout the session windows follow: `spaces' or `classic'.
It is what the generic functions of this file dispatch on, and it says
`spaces' whenever `ecc-use-spaces' is non-nil."
  (if ecc-use-spaces 'spaces 'classic))

(defvar ecc-window-use-side-window t
  "Non-nil shows a transcript in a side window rather than an ordinary one.
Nil falls back to a plain `display-buffer', which gives up the window
roles -- main, sub-1, sub-2 -- and the tab line that goes with them.  It
is a way out rather than a supported layout.")

(defvar ecc-window-side 'right
  "Side of the frame the transcript window is put on.
`ecc-display-session-in-role' calls `display-buffer-in-side-window'
outright, so `display-buffer-alist' is never consulted for a transcript
and this is the way to move one (decided 2026-09-10).")

(defvar ecc-window-width 0.4
  "Width of the transcript side window, as a fraction or a column count.")

(defvar ecc-window-height 0.4
  "Height of the transcript side window when it is put on top or bottom.")

(defcustom ecc-window-large-frame-min-height 80
  "Height, in lines, a frame needs before it gets a third session window.
Below it the sessions share two windows and the tab line reaches the
rest.  The default tells a laptop from a large display: a 14-inch screen
holds around 58 lines and a 16-inch one around 67, while the display
this was measured on holds 114."
  :type 'integer
  :group 'ecc)

(defcustom ecc-window-sub-height 0.33
  "Height of the third session window, as a fraction or a line count.
It is taken from the main area of the frame -- the source code, usually
-- rather than from the side the other two are on.

Which side the other two stand on, and how wide they are, is
`ecc-window-side' and `ecc-window-width'; both are plain variables to
`setq' rather than settings."
  :type 'number
  :group 'ecc)

(defvar ecc-window-ask-name-for-second-session t
  "Non-nil asks for a name when a project gets a second session.")

(defvar ecc-window-remember-session-per-buffer t
  "Non-nil remembers in a buffer which session was chosen for it.")

(defvar-local ecc--bound-session-id nil
  "Id of the session this buffer sends to, once one has been chosen.")

;; Declared here rather than beside the rest of the source-buffer
;; machinery below: `ecc-window-context-project-root' reads it, and a
;; variable used above its `defvar' compiles to a free reference --
;; whether that is caught depends on what the compiler had loaded
;; already, so `make compile' let it pass while the file compiled on its
;; own did not (confirmed 2026-09-17).
(defvar ecc-window--last-source-buffer nil
  "The last buffer selected that does not belong to this package.")

;;;; Projects and names

(defun ecc-window-project-root (&optional directory)
  "Return the root of the project of DIRECTORY, or DIRECTORY itself.
DIRECTORY defaults to `default-directory'."
  (let ((default-directory (or directory default-directory)))
    (or (when-let* ((project (project-current nil)))
          (file-name-as-directory (expand-file-name (project-root project))))
        (file-name-as-directory (expand-file-name default-directory)))))

(defun ecc-window-project-name (directory)
  "Return the name `project.el\=' gives DIRECTORY, or the name of DIRECTORY.
A remote directory is never asked about: `project-current\=' would go
over the wire for it, and the header line of a transcript
\(`ecc-render--project-name\=') is drawn on every command."
  (or (and (not (file-remote-p directory))
           ;; The one `ignore-errors' in ecc.  `project-current' calls
           ;; each function on `project-find-functions', and other
           ;; packages add their own there: what those signal is theirs
           ;; to decide, so there is no error class to name here.  An
           ;; error let out would break the header line, which is drawn
           ;; on every command, so any failure falls back to the name of
           ;; the directory below.
           (ignore-errors
             (when-let* ((project (let ((default-directory directory))
                                    (project-current nil))))
               (project-name project))))
      (file-name-nondirectory (directory-file-name directory))))

(defvar ecc-window--project-root-cache (make-hash-table :test #'equal)
  "Hash of a directory to the project root above it.
`project-current\=' walks the directories above a root, and the tab line
asks which project a session is in on every redisplay.  A directory
rarely stops belonging to a project inside one Emacs, so the answer is
kept rather than worked out again; a test binds a fresh hash.")

(defun ecc-window-project-key (directory)
  "Return the project DIRECTORY belongs to, as the key its sessions group under.
Two sessions are in the same project when this says the same of them,
so everything that groups them goes through here: the root that comes
back is `project.el\='s, which is what makes a session started in a
subdirectory group with the tree it is part of rather than stand alone."
  (if (or (null directory) (equal directory ""))
      ""
    (or (gethash directory ecc-window--project-root-cache)
        (puthash directory (ecc-window-project-root directory)
                 ecc-window--project-root-cache))))

(defun ecc-window-session-project (session)
  "Return the project SESSION belongs to.
The root the session was started in, which `ecc-session-set-root\=' moves
when the user types a `/cd\=' and nothing else does.  The cwd the CLI
reports is not asked: CLI 2.1.272 reports as the session cwd whatever
directory the last Bash tool call left it in (confirmed 2026-09-16), so
a model that runs `cd /tmp\=' would move the session out of its Space,
out of its tab line and into a project nobody started it in.  It is
second only for a session that has no root of its own."
  (ecc-window-project-key (or (ecc-session-project-root session)
                              (ecc-session-cwd session))))

(defun ecc-window-session-projects ()
  "Return the projects that have a session, most recently started first."
  (seq-uniq (mapcar #'ecc-window-session-project (ecc-model-sessions))))

(defun ecc-window-project-sessions (&optional root)
  "Return the sessions whose project is ROOT, most recently started first.
ROOT defaults to the project of the current buffer.  It is matched as a
project rather than as a path, so a session started in a subdirectory
of ROOT is one of them."
  (let ((key (ecc-window-project-key (or root default-directory))))
    (seq-filter (lambda (session)
                  (equal (ecc-window-session-project session) key))
                (ecc-model-sessions))))

(defun ecc-window-context-project-root ()
  "Return the project a new session should start in.
The current buffer when there is a file or a directory behind it, then
the last buffer the user worked in that had one, and `default-directory'
last.  A buffer with nothing behind it -- the scratch buffer, a
transcript, the sidebar, a help window -- says nothing about which
project was meant, and a session started from one of those used to land
wherever that buffer happened to be, which is how a session ends up in
a project nobody asked for.

With `spaces' the tab that is showing comes second: the user chose that
Space, and choosing one is as plain a statement of which project is
meant as the buffer in front of them."
  (ecc-window-project-key
   (or (ecc-window-buffer-directory (current-buffer))
       (ecc-window--tab-root (ecc-window--layout))
       (ecc-window-buffer-directory ecc-window--last-source-buffer)
       default-directory)))

(cl-defgeneric ecc-window--tab-root (_layout)
  "Return the root of the project the tab showing stands for, or nil.
Nil under the `classic' LAYOUT, where a tab stands for no project;
`ecc-space' answers under `spaces' with the Space of the tab."
  nil)

(defun ecc-window-read-session-name (root)
  "Return a name for a new session in ROOT, asking when it is not the first.
The first session of a project is named after the directory; the ones
after it are told apart by a name the user gives."
  (when (and ecc-window-ask-name-for-second-session
             (ecc-window-project-sessions root))
    (let ((name (read-string
                 (format "Name of this %s session: "
                         (file-name-nondirectory (directory-file-name root))))))
      (unless (string-empty-p (string-trim name))
        (string-trim name)))))

;;;; The buffer the user came from

(defvar ecc-window--project-source-buffers nil
  "Alist of a project root to the last buffer of it the user worked in.
Only a buffer behind a file or a directory is here: what
`ecc-focus-project\=' puts back in the main window is the source, and the
compilation log or the scratch buffer of a project is not that.  A
buffer that has since been killed is dropped when the list is read.")

(defun ecc-window-buffer-session (&optional buffer)
  "Return the session BUFFER belongs to, or nil."
  (let ((buffer (or buffer (current-buffer))))
    (and (boundp 'ecc-render--session)
         (buffer-local-value 'ecc-render--session buffer))))

(defun ecc-window-own-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is one this package put on the screen."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (or (ecc-window-buffer-session buffer)
             (string-prefix-p "*ecc" (buffer-name buffer))))))

(defvar ecc-window--last-region nil
  "(BUFFER BEG END) of the last region seen in an ordinary buffer.
The mark of the buffer the user came from is not to be relied on at the
moment a prompt is sent: a command run in between deactivates it, and
`@region' then had nothing to quote though a region was plainly still
highlighted on the screen.  This is what it looked like while it lived.")

(defun ecc-window-buffer-region (&optional buffer)
  "Return (BUFFER BEG END) when BUFFER has a region to quote, or nil."
  (let ((buffer (or buffer (current-buffer))))
    (when (and (buffer-live-p buffer)
               (not (ecc-window-own-buffer-p buffer))
               (not (minibufferp buffer)))
      (with-current-buffer buffer
        (when (use-region-p)
          (list buffer (region-beginning) (region-end)))))))

(defun ecc-window--frame-region ()
  "Return the region of a buffer shown in some window, or nil."
  (seq-some (lambda (window) (ecc-window-buffer-region (window-buffer window)))
            (window-list)))

(defun ecc-window-snapshot-region ()
  "Remember the region of the buffer the user is leaving."
  (when-let* ((region (or (ecc-window-buffer-region ecc-window--last-source-buffer)
                          (ecc-window--frame-region))))
    (setq ecc-window--last-region region)))

(defun ecc-window--live-region (region)
  "Return REGION when its buffer is alive and its bounds still hold."
  (pcase region
    (`(,buffer ,beg ,end)
     (when (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (and (<= (point-min) beg) (< beg end) (<= end (point-max)))))
       region))))

(defun ecc-window-context-buffer ()
  "Return the buffer `@cursor' and `@diagnostics' read, or nil.
The buffer the user last worked in first, then any ordinary buffer on
the screen, then the one a region was last seen in.  The first of those
is nil until `ecc-track-source-buffer-mode' has watched a buffer being
selected, which is not the case in an Emacs that only ever resumed a
session, so the two after it are what make the references work there."
  (or (ecc-window-last-source-buffer)
      (seq-find (lambda (buffer)
                  (and (not (ecc-window-own-buffer-p buffer))
                       (not (minibufferp buffer))
                       (not (string-prefix-p " " (buffer-name buffer)))))
                (mapcar #'window-buffer (window-list)))
      (car (ecc-window--live-region ecc-window--last-region))))

(defun ecc-window-active-region ()
  "Return (BUFFER BEG END) for `@region' and the like, or nil.
The buffer the user last worked in is asked first, then any buffer on
the screen, and the snapshot of `ecc-window-snapshot-region' last: a
mark that died between choosing the region and sending the prompt is
the one failure this is here to survive."
  (or (ecc-window-buffer-region (ecc-window-last-source-buffer))
      (ecc-window--frame-region)
      (ecc-window--live-region ecc-window--last-region)))

(defun ecc-window-buffer-directory (&optional buffer)
  "Return the directory BUFFER stands for, or nil.
That is the directory of the file it visits, or the one a Dired buffer
lists.  A buffer behind neither -- the scratch buffer, a compilation
log, a transcript -- says nothing about which project the user is in,
which is the whole use of this."
  (when-let* ((buffer (or buffer (current-buffer)))
              ((buffer-live-p buffer))
              ((not (ecc-window-own-buffer-p buffer))))
    (if-let* ((file (buffer-file-name buffer)))
        (file-name-directory file)
      (with-current-buffer buffer
        (and (derived-mode-p 'dired-mode) default-directory)))))

(defun ecc-window-note-source-buffer (&rest _)
  "Remember the current buffer as the source to quote from."
  ;; The region is taken down before the buffer is, because the buffer
  ;; being left is still the one recorded here.
  (ecc-window-snapshot-region)
  (let ((buffer (window-buffer (selected-window))))
    (unless (or (ecc-window-own-buffer-p buffer)
                (minibufferp buffer)
                (string-prefix-p " " (buffer-name buffer)))
      (setq ecc-window--last-source-buffer buffer)
      ;; And which project it was, so that a focus on that project
      ;; later can put this buffer back rather than guess.
      (when-let* ((directory (ecc-window-buffer-directory buffer))
                  (key (ecc-window-project-key directory)))
        (setf (alist-get key ecc-window--project-source-buffers nil nil #'equal)
              buffer)))))

(defun ecc-window-last-source-buffer ()
  "Return the buffer to take file, line and region from.
That is the current buffer when it is an ordinary one, and otherwise
the last ordinary buffer that was selected."
  (cond ((not (ecc-window-own-buffer-p)) (current-buffer))
        ((buffer-live-p ecc-window--last-source-buffer)
         ecc-window--last-source-buffer)))

;;;###autoload
(define-minor-mode ecc-track-source-buffer-mode
  "Follow which ordinary buffer the user last worked in.
The commands that quote code into a prompt need it: by the time one of
them runs, the current buffer may be a transcript or a prompt."
  :global t
  :group 'ecc
  (if ecc-track-source-buffer-mode
      (progn
        (add-hook 'window-selection-change-functions #'ecc-window-note-source-buffer)
        (add-hook 'window-buffer-change-functions #'ecc-window-note-source-buffer))
    (remove-hook 'window-selection-change-functions #'ecc-window-note-source-buffer)
    (remove-hook 'window-buffer-change-functions #'ecc-window-note-source-buffer)))

;;;; Showing and hiding

;; This package puts three windows on the screen at the most: `main' at
;; the near end of the side, `sub-1' after it, and `sub-2' under the
;; main area of the frame -- the source code, usually -- on a frame with
;; the height to spare.  A session past that gets no window of its own:
;; it takes over a sub window, and the tab line is how the ones that are
;; not on the screen are reached.
;;
;; Which window has which role is written on the window itself, in the
;; `ecc-window-role' parameter, rather than kept in a table here: the
;; user closes windows, and a table of our own would go stale.

(defconst ecc-window-roles '(main sub-1 sub-2)
  "The roles a window of this package can have, in the order they fill.")

(defvar ecc-window--last-sub nil
  "The sub role the last session was given, so that the next one alternates.")

(defun ecc-window-large-frame-p (&optional frame)
  "Return non-nil when FRAME has the room for a third session window."
  (>= (frame-height frame) ecc-window-large-frame-min-height))

(defun ecc-window-available-roles (&optional frame)
  "Return the roles FRAME has the room for, in the order they fill.
A frame that is not tall enough goes without `sub-2'."
  (if (ecc-window-large-frame-p frame)
      ecc-window-roles
    (remq 'sub-2 ecc-window-roles)))

(defun ecc-window--role-window (role &optional frame)
  "Return the live window carrying ROLE on FRAME, or nil."
  (seq-find (lambda (window)
              (eq (window-parameter window 'ecc-window-role) role))
            (window-list frame 'no-minibuffer)))

(defun ecc-window--role-free-p (role &optional frame)
  "Return non-nil when no session holds ROLE on FRAME.
A window some other buffer borrowed -- a review, say -- counts as free:
the session that was in it has left the screen already."
  (let ((window (ecc-window--role-window role frame)))
    (or (null window)
        (not (ecc-window-buffer-session (window-buffer window))))))

(defun ecc-window--session-role (session &optional frame)
  "Return the role of the window SESSION is shown in on FRAME, or nil."
  (let ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (seq-find (lambda (role)
                  (let ((window (ecc-window--role-window role frame)))
                    (and window (eq (window-buffer window) buffer))))
                ecc-window-roles))))

(defun ecc-window--next-sub (&optional frame)
  "Return the sub role for the next session on FRAME, taking the subs in turn.
Asking does not move the turn along: only a session that really goes
into a sub window does that, in `ecc-display-session-in-role'."
  (let ((subs (remq 'main (ecc-window-available-roles frame))))
    (or (cadr (memq ecc-window--last-sub subs)) (car subs))))

(defun ecc-window-role-for (session &optional frame)
  "Return the role the window of SESSION should have on FRAME.
The window it is in already wins; then the first role standing empty;
then a sub window, the two being taken in turn.  `main' is never taken
from the session that holds it: only the user moves that one, by
clicking a tab or with `ecc-switch-session'."
  (or (ecc-window--session-role session frame)
      (seq-find (lambda (role) (ecc-window--role-free-p role frame))
                (ecc-window-available-roles frame))
      (ecc-window--next-sub frame)))

(defun ecc-window--side-parameters (role)
  "Return the display action alist of the side window of ROLE."
  (let ((horizontal (memq ecc-window-side '(left right))))
    `((side . ,ecc-window-side)
      (slot . ,(if (eq role 'main) 0 1))
      (window-parameters . ((ecc-window-role . ,role)))
      ,@(if horizontal
            `((window-width . ,ecc-window-width))
          `((window-height . ,ecc-window-height))))))

(defun ecc-window--sub-2-parameters ()
  "Return the display action alist of the third window.
It is not a side window: a side window at the bottom would run the
whole width of the frame and pass under the other two.  This one takes
its room from the main area instead, which leaves the side alone.  It
is left undedicated on purpose, so that a review may borrow it and
`quit-window' hand it back."
  `((direction . below)
    (window . main)
    (window-height . ,ecc-window-sub-height)
    (window-parameters . ((ecc-window-role . sub-2)))))

;;;; Keeping a side window a side window

(defun ecc-window-repair-side-windows (&optional frame)
  "Give back the dedication a session side window lost.
Both `switch-to-buffer', which is how the tab line changes what a
window shows, and `set-window-buffer' clear the `side' dedication of a
side window, and an undedicated side window is the next one
`display-buffer' takes over -- geometry and all.  This puts it back.
FRAME is what `window-buffer-change-functions' passes."
  (dolist (window (window-list (and (framep frame) frame) 'no-minibuffer))
    (when (and (memq (window-parameter window 'ecc-window-role) '(main sub-1))
               (window-parameter window 'window-side)
               (not (window-dedicated-p window)))
      (set-window-dedicated-p window 'side))))

(defun ecc-window-session-buffers (session)
  "Return the live buffers of SESSION that are shown in a window of their own."
  (seq-filter #'buffer-live-p
              (list (ecc-session-buffer session))))

(defun ecc-window-session-visible-p (session &optional frame)
  "Return non-nil when a buffer of SESSION is shown on FRAME."
  (seq-some (lambda (buffer) (get-buffer-window buffer (or frame nil)))
            (ecc-window-session-buffers session)))

(defun ecc-window-hide-session (session)
  "Take the windows of SESSION off the screen without killing its buffers."
  (dolist (buffer (ecc-window-session-buffers session))
    (dolist (window (get-buffer-window-list buffer nil nil))
      (when (and (window-live-p window)
                 (not (eq window (frame-root-window window))))
        (delete-window window)))))

(defun ecc-window--layout-key ()
  "Return the key an arrangement of this tab is stored under.
A frame with tabs keeps a layout per tab, so the zoom of
`ecc-space-zoom' is kept per tab as well.

The frame\='s own `tabs' parameter is what is asked, not `tab-bar-mode':
tabs are made, named and switched with the bar hidden exactly as with
it shown, `tab-bar-show' nil being a supported way to run `spaces', and
keying on the mode would put every tab of such a frame on one list.
`tab-bar--current-tab' is not asked either: with no tabs at all it
invents one named after the buffer that is showing, which drifts as the
buffer changes, and writes the parameter while it is at it (verified
2026-09-17 on Emacs 32.0.50).

A lone tab counts only when it was named on purpose.  `explicit-name'
is what tells a tab this package made from the one Emacs names after
whatever buffer happens to be in it."
  (let* ((tabs (frame-parameter nil 'tabs))
         (current (assq 'current-tab tabs)))
    (or (and current
             (or (cdr tabs) (alist-get 'explicit-name current))
             (alist-get 'name current))
        'frame)))

(defun ecc-window-hide-sessions (sessions)
  "Take down the windows of the SESSIONS that are on screen, and say which.
Nothing is written down about where they were.  There was a record of
it once, for a command that put every hidden session back in the window
it came from; what brings one back now deals the whole arrangement again
-- `ecc-space-cycle-layout\=' under `spaces\=', `ecc-focus-project\='
under `classic\=' -- or shows one session at a time, from the sidebar
or `ecc-show-session\='."
  (when-let* ((visible (seq-filter #'ecc-window-session-visible-p sessions)))
    (mapc #'ecc-window-hide-session visible)
    visible))

;;;; Focusing one project

;; Several projects at once is what this package is for, and it is also
;; what fills a frame with windows and tabs that have nothing to do with
;; what is being worked on.  Focusing puts the frame back to one project:
;; the rest is taken off the screen without being killed, and focusing
;; another project is what brings it back.
;;
;; This is the `classic' answer, and the command is in `ecc-display'.
;; Under `spaces' a project has a tab of its own and there is nothing to
;; deal: `ecc-focus-project' goes to the Space and leaves the windows
;; alone.

(defun ecc-window--buffer-in-project-p (buffer key)
  "Return non-nil when BUFFER belongs to the project KEY.
The project of the buffer is worked out the same way the project of a
session is, rather than the path being matched: the two normalisations
differ -- `/var' against `/private/var' on macOS -- and a buffer in a
subdirectory belongs to the project all the same."
  (when-let* ((directory (ecc-window-buffer-directory buffer)))
    (equal (ecc-window-project-key directory) key)))

(defun ecc-window-project-source-buffer (root &optional on-screen)
  "Return the buffer the main window should show for ROOT, or nil.
A buffer of the project that is on the screen already comes first:
moving it would be taking away what the user is looking at.  Then the
one last worked in there, then the most recently used buffer of the
project, `buffer-list' being in that order already.  ON-SCREEN is the
buffers to count as shown, for a test that has no windows."
  (let ((key (ecc-window-project-key root)))
    (or (seq-find (lambda (buffer) (ecc-window--buffer-in-project-p buffer key))
                  (or on-screen (mapcar #'window-buffer (window-list))))
        (let ((remembered (alist-get key ecc-window--project-source-buffers
                                     nil nil #'equal)))
          (if (buffer-live-p remembered)
              remembered
            ;; A buffer that has been killed is dropped rather than
            ;; offered again.
            (setf (alist-get key ecc-window--project-source-buffers
                             nil 'remove #'equal)
                  nil)
            nil))
        (seq-find (lambda (buffer) (ecc-window--buffer-in-project-p buffer key))
                  (buffer-list)))))

(defun ecc-window--source-window ()
  "Return the window the source code belongs in, or nil.
The largest window that is neither a side window nor one of ours.
`window-main-window' is no use here: with a third session window open
the main area is split, and what comes back is the internal window
above the two."
  (car (sort (seq-remove (lambda (window)
                           (or (window-parameter window 'window-side)
                               (window-parameter window 'ecc-window-role)))
                         (window-list nil 'no-minibuffer))
             (lambda (a b) (> (window-body-height a) (window-body-height b))))))

(defun ecc-window--read-project-buffer (root)
  "Ask which buffer of the project ROOT the main window should show."
  (let* ((key (ecc-window-project-key root))
         (buffers (seq-filter (lambda (buffer)
                                (ecc-window--buffer-in-project-p buffer key))
                              (buffer-list))))
    (if (null buffers)
        (ecc-window-project-source-buffer root)
      (get-buffer (completing-read "Show: " (mapcar #'buffer-name buffers)
                                   nil t nil nil
                                   (buffer-name (car buffers)))))))

(defun ecc-window--focus-source (root &optional choose)
  "Show the source of the project ROOT in the main window, and select it.
CHOOSE asks which buffer rather than taking the likeliest.  A project
with no buffer open is listed instead: a directory is a fair answer to
where the source is, and it is somewhere to start reading.

The half of focusing a project that puts the code in front of you, for
`ecc-focus-project\=' and for the `classic\=' side of `ecc-space-select\='.
It was a command of its own on `C-c c V' until the Spaces took that key
for `ecc-space-cycle-layout\=', which puts back the whole arrangement
rather than this one window.

Selecting the window is not a flourish.  Every command that takes no
prefix argument -- `ecc-start\=', `ecc-next-attention-in-project\=',
`ecc-window-resolve-session\=' -- reads the project off the current
buffer, so leaving point here is what makes the whole package agree
about which project one is in."
  (require 'dired)
  (let ((window (ecc-window--source-window))
        (buffer (or (if choose
                        (ecc-window--read-project-buffer root)
                      (ecc-window-project-source-buffer root))
                    (dired-noselect root))))
    (when (and (window-live-p window) (buffer-live-p buffer))
      (set-window-buffer window buffer)
      (select-window window)
      window)))

(defun ecc-window-project-label (root sessions)
  "Return the line the project ROOT with SESSIONS is offered under."
  (format "%-24s  %-11s %s"
          (ecc--truncate (ecc-window-project-name root) 24)
          (format "%d session%s" (length sessions)
                  (if (= 1 (length sessions)) "" "s"))
          (abbreviate-file-name root)))

(defun ecc-window-read-project (&optional prompt)
  "Ask which of the projects that have a session to use, with PROMPT.
A single project answers for itself: there is nothing to choose."
  (let ((projects (ecc-window-session-projects)))
    (cond
     ((null projects) (user-error "No session is running"))
     ((null (cdr projects)) (car projects))
     (t (let* ((labels (mapcar (lambda (root)
                                 (cons (ecc-window-project-label
                                        root (ecc-window-project-sessions root))
                                       root))
                               projects))
               (choice (completing-read (or prompt "Project: ")
                                        (mapcar #'car labels) nil t)))
          (cdr (assoc choice labels)))))))

;;;; Which session a command talks to

(defun ecc-window-displayed-sessions (&optional frame)
  "Return the sessions with a window on FRAME."
  (seq-filter (lambda (session) (ecc-window-session-visible-p session frame))
              (ecc-model-sessions)))

(defun ecc-window--session-group (key)
  "Return (TITLE . PARENT) for the group of the sessions of the project KEY.
A session with no project is in a group of its own, titled \"-\"; the
rest are grouped by `ecc-window--project-group\='."
  (if (string-empty-p key)
      (list "-")
    (ecc-window--project-group (ecc-window--layout) key)))

(cl-defgeneric ecc-window--project-group (_layout key)
  "Return (TITLE . PARENT) for the group of the sessions of KEY under LAYOUT.
Under `classic' it is the project, with no PARENT: telling a worktree
from its repository asks git, and nothing under `classic' reaches
`ecc-worktree'.  Under `spaces' `ecc-space' groups them by Space, titled
as the Space picker titles it, and PARENT is the key of the repository
a linked worktree belongs to."
  (list (ecc-window-project-name key)))

(defun ecc-window--sessions-by-use (sessions)
  "Return SESSIONS, the one whose buffer was selected last first.
`buffer-list' is kept in that order.  The registry is not: it moves a
session to the front when it starts, not when it is used.  A session
with no live buffer goes after the rest, and sessions that tie keep the
order of SESSIONS."
  (let ((rank (make-hash-table :test #'eq))
        (n 0))
    (dolist (buffer (buffer-list))
      (puthash buffer (setq n (1+ n)) rank))
    (mapcar #'cdr
            ;; `sort' is stable.
            (sort (mapcar (lambda (session)
                            (cons (gethash (ecc-session-buffer session) rank
                                           most-positive-fixnum)
                                  session))
                          sessions)
                  (lambda (a b) (< (car a) (car b)))))))

(defun ecc-window--session-groups (sessions)
  "Return an alist of each project of SESSIONS to the title of its group.
In the order the projects first come up among SESSIONS, except that a
worktree follows its repository when that has sessions here too, the
way the sidebar draws it.  Two projects that would still go by the
same title are told apart the way their tabs are, `main<2>\='."
  (let* ((groups (mapcar (lambda (key)
                           (cons key (ecc-window--session-group key)))
                         (seq-uniq (mapcar #'ecc-window-session-project
                                           sessions))))
         (keys (mapcar #'car groups))
         (ordered nil)
         (titled nil))
    ;; The same walk as `ecc-space-list'.
    (dolist (group groups)
      (unless (member (cddr group) keys)
        (push group ordered)
        (dolist (child groups)
          (when (equal (cddr child) (car group))
            (push child ordered)))))
    (dolist (group (nreverse ordered))
      (push (cons (car group)
                  (ecc--unique-name (cadr group)
                                    (lambda (title) (rassoc title titled))))
            titled))
    (nreverse titled)))

(defun ecc-window--session-candidates (sessions)
  "Return an alist of a candidate to its group title and session, for SESSIONS.
The candidate is the title and the name, `Space/name\=', so that typing
the name of a Space narrows the list to its sessions -- and the name of
a repository to its sessions and those of its worktrees.  A group\='s
sessions come together, in the order of the groups, and keep the order
of SESSIONS among themselves."
  (mapcan (lambda (group)
            (let ((title (cdr group)))
              (mapcar (lambda (session)
                        (cons (concat title "/" (ecc-session-name session))
                              (cons title session)))
                      (seq-filter (lambda (session)
                                    (equal (ecc-window-session-project session)
                                           (car group)))
                                  sessions))))
          (ecc-window--session-groups sessions)))

(defun ecc-window--session-line (session name)
  "Return SESSION as the picker shows it: the mark of its state, then NAME.
NAME is the name as the candidate carries it, with whatever faces the
completion UI put on it to show what matched: vertico highlights a
candidate before it hands it to the `group-function\=' (confirmed
2026-10-07), and a name taken from SESSION afresh would lose them.  The
mark is the one its tab and its sidebar row carry, at the moment of
asking: no blinking.  Only the mark takes a face of its own."
  (concat (ecc-tab-column-mark (ecc-model-activity session)) " " name))

(defun ecc-window--session-table (candidates)
  "Return a completion table of CANDIDATES, grouped by Space and kept in order.
CANDIDATES is what `ecc-window--session-candidates\=' returns.  As a line
is shown, the group title comes off its front and the mark of the
session\='s state goes in its place.  The title is matched against what
is typed, the mark is not."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata
          (group-function
           . ,(lambda (candidate transform)
                (let ((entry (cdr (assoc candidate candidates))))
                  (cond ((null entry) (if transform candidate ""))
                        (transform
                         (ecc-window--session-line
                          (cdr entry)
                          (substring candidate (1+ (length (car entry))))))
                        (t (car entry))))))
          ;; Most recently used first, which sorting would throw away.
          (display-sort-function . identity)
          (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun ecc-window-read-session (&optional prompt sessions)
  "Ask which of SESSIONS to use, with PROMPT.
SESSIONS defaults to every live session.  They are offered most
recently used first, by `ecc-window--sessions-by-use', grouped by the
Space they belong to -- the project under `classic\=' -- each under the
mark of its state.  A group comes where its most recently used session
does."
  (let ((sessions (ecc-window--sessions-by-use
                   (or sessions (ecc-model-sessions)))))
    (cond
     ((null sessions) (user-error "No session is running"))
     ((null (cdr sessions)) (car sessions))
     (t (let* ((candidates (ecc-window--session-candidates sessions))
               (choice (completing-read (or prompt "Session: ")
                                        (ecc-window--session-table candidates)
                                        nil t)))
          (cddr (assoc choice candidates)))))))

(defun ecc-window-bound-session ()
  "Return the session this buffer was told to send to, or nil."
  (and ecc--bound-session-id (ecc-model-session ecc--bound-session-id)))

(defun ecc-window-resolve-session (&optional force-ask)
  "Return the session a command in this buffer should talk to.
The order is: the session of this buffer, the session this buffer was
bound to before, the only session of this project, the only session on
screen, the most recently started one.  FORCE-ASK, a prefix argument in
the commands that take one, always asks; the answer is remembered in
the buffer."
  (or (ecc-window-buffer-session)
      (and (not force-ask)
           (or (ecc-window-bound-session)
               (let ((project (ecc-window-project-sessions)))
                 (and project (null (cdr project)) (car project)))
               (let ((shown (ecc-window-displayed-sessions)))
                 (and shown (null (cdr shown)) (car shown)))
               (car (ecc-model-sessions))))
      (let ((session (ecc-window-read-session "Send to: ")))
        (when (and session ecc-window-remember-session-per-buffer)
          (setq-local ecc--bound-session-id (ecc-session-id session)))
        session)))

(provide 'ecc-window)

;;; ecc-window.el ends here
