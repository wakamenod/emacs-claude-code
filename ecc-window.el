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

;; The project a session or a buffer belongs to and the name it goes by,
;; the source buffers of a project, the last buffer the user worked in
;; that is not part of this package -- the source `ecc-context' quotes
;; from -- and the region in it, and taking transcripts off the screen.
;;
;; Showing a session, the Spaces it is shown in and which session a
;; command means are `ecc-display', above this file and above
;; `ecc-chat', which makes the buffer that is shown.  Nothing here calls
;; into a module that requires this file.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-visual)


;; The side windows a transcript was once shown in are gone with the
;; layout that had them, and a Space shows every session (0.5.0).
(make-obsolete-variable 'ecc-window-use-side-window "Spaces are always on." "0.5.0")
(make-obsolete-variable 'ecc-window-side "Spaces are always on." "0.5.0")
(make-obsolete-variable 'ecc-window-height "Spaces are always on." "0.5.0")
(make-obsolete-variable 'ecc-window-large-frame-min-height
                        "Spaces are always on; a layout of `ecc-space-cycle-layout' \
says how many sessions are on the screen."
                        "0.5.0")
(make-obsolete-variable 'ecc-window-sub-height "Spaces are always on." "0.5.0")

(defvar ecc-window-ask-name-for-second-session t
  "Non-nil asks for a name when a project gets a second session.")

(defvar ecc-window-remember-session-per-buffer t
  "Non-nil remembers in a buffer which session was chosen for it.")

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
Only a buffer behind a file or a directory is here: what a Space puts
back in its source window is the source, and the compilation log or the
scratch buffer of a project is not that.  A
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

;;;; Taking transcripts off the screen

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

(defun ecc-window-hide-sessions (sessions)
  "Take down the windows of the SESSIONS that are on screen, and say which.
Nothing is written down about where they were.  There was a record of
it once, for a command that put every hidden session back in the window
it came from; what brings one back now deals the whole arrangement again
-- `ecc-space-cycle-layout\=' -- or shows one session at a time, from
the sidebar or `ecc-show-session\='."
  (when-let* ((visible (seq-filter #'ecc-window-session-visible-p sessions)))
    (mapc #'ecc-window-hide-session visible)
    visible))

(defun ecc-window-displayed-sessions (&optional frame)
  "Return the sessions with a window on FRAME."
  (seq-filter (lambda (session) (ecc-window-session-visible-p session frame))
              (ecc-model-sessions)))

;;;; The source of a project

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

(provide 'ecc-window)

;;; ecc-window.el ends here
