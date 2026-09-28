;;; ecc-restore.el --- Bring the sessions of the last Emacs back  -*- lexical-binding: t; -*-

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

;; `desktop-save-mode' cannot bring a session back: a session buffer is
;; the view of a CLI process, and the process does not survive Emacs.
;; What does survive is the recording, and a session is its id, so this
;; keeps a small file of which sessions were open and which Spaces held
;; them, and `ecc-restore' reads it back.
;;
;; The file is written whenever that set changes -- a session starts,
;; stops or is killed, a tab opens or closes -- and not only when Emacs
;; exits, which a crash never does.  Everything in it comes from the
;; sessions in memory and the tab bar: nothing is read from a recording
;; and git is not asked, so a write costs next to nothing and one that
;; would say the same thing again is skipped.
;;
;; At exit the file is written one last time and then left alone.
;; Whatever goes down after that -- buffers, processes -- is Emacs
;; shutting down, not the user closing a session, and it must not be
;; saved as an Emacs with nothing open.
;;
;; Until `ecc-restore' has been run, what the last Emacs left is carried
;; along in every write, the one at exit included.  Starting a session
;; before restoring would otherwise write over the file with that one
;; session, and the restore that followed would find nothing to bring
;; back -- in this Emacs, or in the next one if this one quits first.
;; A session killed on purpose leaves the file; one the last Emacs left
;; and nobody restored is still waiting to be, and stays.
;;
;; A session comes back stopped, read from its recording, with no
;; process: N sessions are not N CLIs at startup, and whether another
;; process is running one of them is asked when the user goes to use
;; it, one at a time, by the resume every stopped session already has.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-bar)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-history)

(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-display-session "ecc-window" (session))
(declare-function ecc-rename-session "ecc-window" (session name))
(declare-function ecc-render-refresh "ecc-render" (session))
(declare-function ecc--enable-session-modes "ecc" ())
(declare-function ecc-space-tab-roots "ecc-space" (&optional frame))
(declare-function ecc-space-of-root "ecc-space" (root))
(declare-function ecc-space-select "ecc-space" (space))
(defvar ecc-space-always-session)

(defvar ecc-restore-file (expand-file-name "ecc-state.eld" user-emacs-directory)
  "File the open sessions and Spaces are saved in, as Lisp data.
A variable rather than a setting: where a package keeps its state is
not a taste, and `user-emacs-directory' is where Emacs keeps the rest.")

(defvar ecc-restore-enabled (not noninteractive)
  "Non-nil saves the open sessions and Spaces as they change.
A batch Emacs saves nothing: a script or a test that starts sessions
must not write over what the user's own Emacs left.")

(defconst ecc-restore--version 1
  "Version of the layout of `ecc-restore-file'.")

(defvar ecc-restore--written nil
  "The text last written to `ecc-restore-file' by this Emacs, or nil.")

(defvar ecc-restore--owned nil
  "Non-nil once this Emacs has had a session that belongs in the file.
Set by a save that found one and by `ecc-restore'.  It is what lets the
exit write replace what the last Emacs left: a save is made for any tab
opened or closed, so having written the file says nothing about whether
this Emacs had anything of its own to put there.")

(defvar ecc-restore--frozen nil
  "Non-nil once Emacs is exiting and the file has been written for it.")

(defvar ecc-restore--previous 'unread
  "What the last Emacs left, until `ecc-restore' has taken it.
`unread' until the file is first needed, then the state read from it,
or nil when there was none or it has been restored.")

(defvar ecc-restore--timer nil
  "The timer of the save that is waiting to be made, or nil.")

;;;; What is saved

(defun ecc-restore--saved-p (session)
  "Return non-nil when SESSION is one to bring back.
A session of the user's own: not a recording being read, not the usage
probe, not an inline question, not one open in a terminal."
  (and (eq (ecc-session-kind session) 'own)
       (ecc-model-own-session-p session)))

(defun ecc-restore--session-entry (session)
  "Return the entry SESSION is saved as."
  (list :id (ecc-session-id session)
        :name (ecc-session-name session)
        :root (ecc-session-project-root session)
        :cwd (ecc-session-cwd session)))

(defun ecc-restore--space-roots ()
  "Return the roots of the Spaces with a tab, the selected frame first.
Nothing under `ecc-use-spaces' nil, where nothing may reach `ecc-space',
and nothing when it has not been loaded: then there are no tabs of ours,
and loading it to find that out would be loading it for nothing."
  (when (and ecc-use-spaces (featurep 'ecc-space))
    (let ((roots nil))
      (dolist (frame (cons (selected-frame)
                           (delq (selected-frame) (frame-list))))
        (dolist (root (ecc-space-tab-roots frame))
          (unless (member root roots)
            (push root roots))))
      (nreverse roots))))

(defun ecc-restore-state ()
  "Return what is open now, as it is saved.
A plist of the Space roots in the order of their tabs and the sessions,
most recently used first."
  (list :version ecc-restore--version
        :spaces (ecc-restore--space-roots)
        :sessions (mapcar #'ecc-restore--session-entry
                          (seq-filter #'ecc-restore--saved-p
                                      (ecc-model-sessions)))))

(defun ecc-restore--merge (state previous)
  "Return STATE with what PREVIOUS holds and STATE does not after it."
  (let ((ids (mapcar (lambda (entry) (plist-get entry :id))
                     (plist-get state :sessions))))
    (list :version ecc-restore--version
          :spaces (seq-uniq (append (plist-get state :spaces)
                                    (plist-get previous :spaces)))
          :sessions (append (plist-get state :sessions)
                            (seq-remove (lambda (entry)
                                          (member (plist-get entry :id) ids))
                                        (plist-get previous :sessions))))))

;;;; Reading and writing the file

(defun ecc-restore--read (&optional file)
  "Return the state saved in FILE, or nil.
FILE defaults to `ecc-restore-file'.  A file this version cannot read is
said so and taken for none."
  (let ((file (or file ecc-restore-file)))
    (when (file-readable-p file)
      (condition-case error
          (let ((state (with-temp-buffer
                         (insert-file-contents file)
                         (read (current-buffer)))))
            (if (and (listp state)
                     (eql (plist-get state :version) ecc-restore--version))
                state
              (message "ecc: %s is not a state this version reads"
                       (abbreviate-file-name file))
              nil))
        (error (message "ecc: cannot read %s: %s" (abbreviate-file-name file)
                        (error-message-string error))
               nil)))))

(defun ecc-restore--previous-state ()
  "Return what the last Emacs left and has not been restored, or nil."
  (when (eq ecc-restore--previous 'unread)
    (setq ecc-restore--previous (ecc-restore--read)))
  ecc-restore--previous)

(defun ecc-restore--write (state)
  "Write STATE to `ecc-restore-file' unless it says what is there already.
Returns non-nil when it wrote.  The text goes to a file beside it first
and is renamed over it, so a crash in the middle leaves the old one."
  (let ((text (let ((print-length nil)
                    (print-level nil)
                    (print-escape-newlines t))
                (concat ";; -*- mode: lisp-data -*-\n"
                        ";; The sessions and Spaces ecc had open; `ecc-restore' reads this.\n"
                        (prin1-to-string state) "\n"))))
    (unless (equal text ecc-restore--written)
      (let* ((file (expand-file-name ecc-restore-file))
             (temp (concat file ".tmp"))
             (coding-system-for-write 'utf-8-unix))
        (make-directory (file-name-directory file) t)
        (write-region text nil temp nil 'silent)
        (rename-file temp file t))
      (setq ecc-restore--written text)
      t)))

(defun ecc-restore--to-write ()
  "Return what is open, with what the last Emacs left and is not restored yet."
  (let ((state (ecc-restore-state)))
    (when (plist-get state :sessions)
      (setq ecc-restore--owned t))
    (if-let* ((previous (ecc-restore--previous-state)))
        (ecc-restore--merge state previous)
      state)))

(defun ecc-restore-save ()
  "Save the open sessions and Spaces, with what is still to be restored.
Nothing once Emacs is exiting; see `ecc-restore--save-at-exit'."
  (when ecc-restore--timer
    (cancel-timer ecc-restore--timer)
    (setq ecc-restore--timer nil))
  (unless ecc-restore--frozen
    (ecc-restore--write (ecc-restore--to-write))))

(defun ecc-restore--schedule (&rest _)
  "Save once what the current command has changed.
On the hooks that announce a session or a tab coming or going.  The
save is put off to a timer so that a command that opens a tab, names it
and starts a session in it writes once, and writes what it ended with."
  (when (and ecc-restore-enabled
             (not ecc-restore--frozen)
             (not ecc-restore--timer))
    (setq ecc-restore--timer (run-at-time 0 nil #'ecc-restore-save))))

(defun ecc-restore--save-at-exit ()
  "Write what is open as Emacs exits, and write nothing after it.
On `kill-emacs-hook', ahead of everything else there: what exits after
this is Emacs going down, and saved it would be an Emacs with nothing
open.  What the last Emacs left and nobody restored is carried along,
as every other write carries it: quitting before `ecc-restore' is not
a reason to lose it.  An Emacs that never had a session of its own
leaves the file alone altogether."
  (when (and ecc-restore-enabled
             (or ecc-restore--owned
                 (plist-get (ecc-restore-state) :sessions)))
    (condition-case error
        (ecc-restore--write (ecc-restore--to-write))
      (error (message "ecc: the sessions were not saved: %s"
                      (error-message-string error)))))
  (setq ecc-restore--frozen t))

(defun ecc-restore--drop-mark (session _old)
  "Forget that SESSION was restored once its CLI has started.
On `ecc-session-state-changed-hook'.  From then on it is a session like
any other, and one that stops later is not started by a prompt.  The
process is asked for and not the state alone: reading the recording
back walks the state through the turns it replays."
  (when (and (ecc-model-option session :restored nil)
             (process-live-p (ecc-session-process session)))
    (setf (ecc-session-options session)
          (ecc-restore--plist-without (ecc-session-options session) :restored))))

(defun ecc-restore--plist-without (plist key)
  "Return PLIST without KEY and its value."
  (let ((result nil))
    (while plist
      (unless (eq (car plist) key)
        (setq result (cons (cadr plist) (cons (car plist) result))))
      (setq plist (cddr plist)))
    (nreverse result)))

(add-hook 'ecc-session-state-changed-hook #'ecc-restore--drop-mark)
(add-hook 'ecc-session-state-changed-hook #'ecc-restore--schedule)
(add-hook 'ecc-session-removed-hook #'ecc-restore--schedule)
(add-hook 'ecc-session-init-hook #'ecc-restore--schedule)
(add-hook 'tab-bar-tab-post-open-functions #'ecc-restore--schedule)
(add-hook 'tab-bar-tab-pre-close-functions #'ecc-restore--schedule)
(add-hook 'kill-emacs-hook #'ecc-restore--save-at-exit -90)

;;;; Bringing it back

(defun ecc-restore--session (entry)
  "Bring back the session ENTRY describes, stopped, and return it.
Nil when it cannot come back; the reason is the second value of the
cons returned instead: (nil . REASON)."
  (let* ((id (plist-get entry :id))
         (root (plist-get entry :root))
         (file (and id (ecc-history-file id))))
    (cond
     ((null id) (cons nil "no id"))
     ;; A recording open to be read is not the session being open:
     ;; it is taken over below rather than counted.
     ((when-let* ((open (ecc-model-session id)))
        (not (eq (ecc-session-kind open) 'archived)))
      (cons nil 'open))
     ((not (and root (file-directory-p root)))
      (cons nil (format "%s is gone" (abbreviate-file-name (or root "?")))))
     ((ecc-model-session id)
      (ecc-restore--adopt (ecc-model-session id) entry))
     ((null file) (cons nil "nothing was recorded"))
     (t
      (let ((session (ecc-model-create-session
                      :id id
                      :name (plist-get entry :name)
                      :project-root root
                      :cwd (plist-get entry :cwd)
                      ;; Kept apart from `archived': this is the user's
                      ;; session, stopped, and is shown and saved as one.
                      :kind 'own
                      :options (list :restored t))))
        (puthash id file ecc-history--files)
        (ecc-model-set-state session 'exited)
        (require 'ecc-session)
        (ecc-session-ensure-buffer session)
        (ecc-history-load session)
        (cons session nil))))))

(defun ecc-restore--adopt (session entry)
  "Make SESSION, a recording open to be read, the restored session of ENTRY.
The recording is the same conversation: skipping the entry because it
is being read would leave it out of every save after this one, since a
recording being read is never saved.  So it becomes what a restored
session is -- the user's own, stopped, under its saved name and root --
in the buffer it already has.  Returns (SESSION . nil)."
  (setf (ecc-session-kind session) 'own
        (ecc-session-project-root session) (plist-get entry :root)
        (ecc-session-options session)
        (plist-put (ecc-session-options session) :restored t))
  (when-let* ((cwd (plist-get entry :cwd)))
    (setf (ecc-session-cwd session) cwd))
  (when-let* ((name (plist-get entry :name))
              ((not (equal name (ecc-session-name session)))))
    (require 'ecc-window)
    (ecc-rename-session session name))
  (when-let* ((buffer (ecc-session-buffer session))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq default-directory (plist-get entry :root))))
  (require 'ecc-render)
  (ecc-render-refresh session)
  (cons session nil))

(defun ecc-restore--spaces (roots)
  "Open a Space for each of ROOTS, in order, starting nothing.
Returns the roots that were opened and the ones that are gone, as a
cons.  `ecc-space-always-session' is off throughout: a Space that had
no session had none, and one that had them has them back already.  The
sessions are laid out the way a Space lays them out, and the first
Space is the one left showing."
  (require 'ecc-space)
  (let ((ecc-space-always-session nil)
        (opened nil)
        (gone nil))
    (dolist (root roots)
      (if (file-directory-p root)
          (progn (ecc-space-select (ecc-space-of-root root))
                 (push root opened))
        (push root gone)))
    (setq opened (nreverse opened))
    ;; The first of them is the one left showing.
    (when opened
      (ecc-space-select (ecc-space-of-root (car opened))))
    (cons opened (nreverse gone))))

;;;###autoload
(defun ecc-restore (&optional file)
  "Bring back the Spaces and sessions that were open when Emacs last exited.
The sessions come back stopped, read from their recordings, and no CLI
is started: sending a prompt starts one, as \\`R' does.  A session that
is open already is left as it is, so running this twice brings nothing
back twice, and one whose directory is gone is skipped and said so.

The Spaces are opened in the order their tabs were in, with the
sessions side by side as a Space lays them out; under `ecc-use-spaces'
nil only the sessions come back.

FILE is the state to read, `ecc-restore-file' by default.  To do this
every time Emacs starts, call it from the init file."
  (interactive)
  (require 'ecc)
  (let* ((state (or (and (null file) (ecc-restore--previous-state))
                    (ecc-restore--read file)))
         (restored nil)
         (open 0)
         (skipped nil)
         (spaces nil))
    (unless state
      (user-error "Nothing to restore in %s"
                  (abbreviate-file-name (or file ecc-restore-file))))
    ;; Oldest first, so that the one used last is the most recent again.
    (dolist (entry (reverse (plist-get state :sessions)))
      (pcase-let ((`(,session . ,reason) (ecc-restore--session entry)))
        (cond (session (push session restored))
              ((eq reason 'open) (cl-incf open))
              ((stringp reason)
               (push (format "%s (%s)" (or (plist-get entry :name) "?") reason)
                     skipped)))))
    (when restored
      (ecc--enable-session-modes))
    (if ecc-use-spaces
        (let ((result (ecc-restore--spaces (plist-get state :spaces))))
          (setq spaces (car result))
          (dolist (root (cdr result))
            (push (format "%s (gone)" (abbreviate-file-name root)) skipped)))
      (when restored
        (require 'ecc-window)
        (ecc-display-session (car restored))))
    (when (null file)
      (setq ecc-restore--previous nil
            ecc-restore--owned t))
    (ecc-restore--schedule)
    (message "Restored %d session%s%s%s%s"
             (length restored) (if (= 1 (length restored)) "" "s")
             (if spaces
                 (format " in %d Space%s" (length spaces)
                         (if (= 1 (length spaces)) "" "s"))
               "")
             (if (> open 0) (format "; %d open already" open) "")
             (if skipped
                 (format "; skipped %s" (string-join (nreverse skipped) ", "))
               ""))
    restored))

(provide 'ecc-restore)

;;; ecc-restore.el ends here
