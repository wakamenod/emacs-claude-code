;;; ecc-sync.el --- Keep file buffers in step with what Claude wrote  -*- lexical-binding: t; -*-

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

;; When a tool result says Claude changed a file, the buffer visiting it
;; is reverted so that the editor never shows stale text.  A buffer with
;; unsaved changes is left alone and the user is warned, or asked,
;; depending on `ecc-sync-modified-action'.  The same check tells
;; `ecc-perm' to warn before a change to such a file is allowed.

;;; Code:

(require 'cl-lib)
(require 'ecc-core)
(require 'ecc-model)

(defvar ecc-sync-enabled t
  "Non-nil reverts a buffer when Claude changes the file it visits.")

(defvar ecc-sync-modified-action 'warn
  "What to do when Claude changes a file whose buffer has unsaved changes.
`warn' leaves the buffer alone and says so, `ask' offers to revert it,
and `revert' throws the unsaved changes away without asking.")

(defvar ecc-sync-after-revert-hook nil
  "Functions run in a buffer right after this package reverted it.")

;;;; Finding the buffer

(defun ecc-sync-buffer-visiting (path)
  "Return the buffer visiting PATH, or nil.
Symbolic links are followed so that the path the CLI reports finds a
buffer that visits the file under another name."
  (when (stringp path)
    (or (find-buffer-visiting path)
        (let ((true (file-truename path)))
          (and (not (equal true path)) (find-buffer-visiting true))))))

(defun ecc-sync-unsaved-buffer (path)
  "Return the buffer visiting PATH when it has unsaved changes, else nil."
  (when-let* ((buffer (ecc-sync-buffer-visiting path)))
    (and (buffer-modified-p buffer) buffer)))

;;;; Reverting

(defun ecc-sync--line-and-column (position)
  "Return (LINE . COLUMN) of POSITION in the current buffer."
  (save-excursion
    (goto-char position)
    (cons (line-number-at-pos) (current-column))))

(defun ecc-sync--goto-line-and-column (place)
  "Move point to the line and column in PLACE, as far as the buffer allows."
  (goto-char (point-min))
  (forward-line (1- (car place)))
  (move-to-column (cdr place)))

(defun ecc-sync-revert-buffer (buffer)
  "Reload BUFFER from its file, keeping point and the windows where they were.
Positions are kept by line and column, which survives a change above
them better than a character offset.  Returns BUFFER."
  (with-current-buffer buffer
    (let ((windows (mapcar (lambda (window)
                             (cons window (ecc-sync--line-and-column
                                           (window-point window))))
                           (get-buffer-window-list buffer nil t)))
          (here (ecc-sync--line-and-column (point))))
      (revert-buffer t t t)
      (ecc-sync--goto-line-and-column here)
      (dolist (pair windows)
        (when (window-live-p (car pair))
          (save-excursion
            (ecc-sync--goto-line-and-column (cdr pair))
            (set-window-point (car pair) (point)))))
      (run-hooks 'ecc-sync-after-revert-hook)))
  buffer)

(defun ecc-sync-revert-file (path &optional force)
  "Revert the buffer visiting PATH and return it, or nil when there is none.
A buffer with unsaved changes is handled as `ecc-sync-modified-action'
says, unless FORCE is non-nil.  Returns nil when nothing was reverted."
  (when-let* ((buffer (ecc-sync-buffer-visiting path)))
    (cond
     ((not (buffer-modified-p buffer))
      (ecc-sync-revert-buffer buffer))
     ((or force (eq ecc-sync-modified-action 'revert))
      (ecc-sync-revert-buffer buffer))
     ((eq ecc-sync-modified-action 'ask)
      (when (y-or-n-p (format "%s has unsaved changes.  Replace them with what Claude wrote? "
                              (buffer-name buffer)))
        (ecc-sync-revert-buffer buffer)))
     (t
      (message "ecc: %s was not reverted; it has unsaved changes"
               (buffer-name buffer))
      nil))))

(defun ecc-sync--on-file-changed (session path)
  "Revert the buffer visiting PATH, which Claude changed in SESSION."
  (when ecc-sync-enabled
    (condition-case err
        (when (ecc-sync-revert-file path)
          (ecc-log (ecc-session-name session) "reverted %s" path))
      (error
       (ecc-log (ecc-session-name session) "revert of %s failed: %s"
                path (error-message-string err))
       (message "ecc: reverting %s failed: %s"
                (abbreviate-file-name path) (error-message-string err))))))

(add-hook 'ecc-sync-file-changed-hook #'ecc-sync--on-file-changed)

(provide 'ecc-sync)

;;; ecc-sync.el ends here
