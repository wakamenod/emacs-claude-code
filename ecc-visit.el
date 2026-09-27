;;; ecc-visit.el --- Opening the source a line of the transcript is about  -*- lexical-binding: t; -*-

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

;; RET or a click on code in the transcript opens the file it is about,
;; at the line: a line of the diff of an Edit or a Write, the heading of
;; a call that names a file, a line of the Files section or of a
;; permission request, and a path the model wrote in its reply.
;;
;; A diff line carries nothing that says where it is from.  The Files
;; section is drawn again at every redraw of the live region, and a
;; property per line of every diff in it would be paid for every time,
;; so the line is read back when RET is pressed instead: the number
;; drawn at its start in the `numbered' style, or the lines counted from
;; the @@ header above it in the `unified' one.  The file is the one of
;; the node, the row or the request the line belongs to.  What a click
;; follows is decided the same way, by `ecc-visit-follow-link-p' as the
;; `follow-link' of the transcript, with no `mouse-face' on the lines.
;;
;; A number drawn in a diff is where the line stood once that change was
;; made.  Every change the session made to the file after it is in
;; `ecc-file-entry-patches', and the line is moved through those, so it
;; lands where the line is now.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pulse)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-diff)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-markdown)
(require 'ecc-window)

;;;; Reading a diff line back

(defun ecc-visit--line-tag ()
  "Return what the line at point is in a diff, or nil when it is not one.
The answer is `added', `removed', `context' or `header', read from the
`diff-mode' faces the line was drawn with; the text alone cannot say,
since in the `numbered' style a line starts with its number and a line
of the file may start with a + of its own."
  (let ((pos (line-beginning-position))
        (end (line-end-position))
        tag)
    (while (and (not tag) (< pos end))
      (let ((faces (ensure-list (get-text-property pos 'face))))
        (setq tag (cond ((memq 'diff-added faces) 'added)
                        ((memq 'diff-removed faces) 'removed)
                        ((memq 'diff-hunk-header faces) 'header)
                        ((memq 'diff-context faces) 'context))))
      (setq pos (next-single-property-change pos 'face nil end)))
    tag))

(defun ecc-visit--number ()
  "Return the number the `numbered' style drew at the start of this line."
  (save-excursion
    (beginning-of-line)
    (and (looking-at "[ \t]*\\([0-9]+\\) ")
         (string-to-number (match-string 1)))))

(defun ecc-visit--neighbour (step)
  "Return the number of the nearest line STEP away that is not removed.
The search stays in the hunk: it stops at the first line that is not a
line of the diff, which is what stands between two hunks."
  (save-excursion
    (let (found done)
      (while (and (not done) (zerop (forward-line step)))
        (pcase (ecc-visit--line-tag)
          ('removed nil)
          ((or 'added 'context) (setq found (ecc-visit--number) done t))
          (_ (setq done t))))
      found)))

(defun ecc-visit--numbered-line ()
  "Return the line in the file the `numbered' diff line at point stands for.
An added or a context line is numbered in the new file already.  A
removed line is numbered in the old one, and in the new file it stands
where it was taken out: after the line above it that is still there, or
else before the one below."
  (when-let* ((number (ecc-visit--number)))
    (if (eq (ecc-visit--line-tag) 'removed)
        (or (when-let* ((above (ecc-visit--neighbour -1))) (1+ above))
            (ecc-visit--neighbour 1)
            number)
      number)))

(defun ecc-visit--unified-line ()
  "Return the line in the file the `unified' diff line at point stands for.
It is counted from the new start of the @@ header above; nil when there
is no header, which is a diff of two strings with no file behind them."
  (save-excursion
    (let ((count 0) start done)
      (while (and (not (or start done)) (zerop (forward-line -1)))
        (pcase (ecc-visit--line-tag)
          ('header (let ((text (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position))))
                     (if (string-match "\\+\\([0-9]+\\)" text)
                         (setq start (string-to-number (match-string 1 text)))
                       (setq done t))))
          ((or 'added 'context) (cl-incf count))
          ('removed nil)
          (_ (setq done t))))
      (and start (max 1 (+ start count))))))

(defun ecc-visit--diff-line ()
  "Return the line of the file the diff line at point stands for, or nil.
The two styles are told apart by the text alone, never by
`ecc-diff-style\\=', which may have changed since the diff was drawn: only
the `unified\\=' one has an @@ header, and a line with none above it is
read as `numbered\\='."
  (pcase (ecc-visit--line-tag)
    ('nil nil)
    ('header (save-excursion
               (forward-line 1)
               (and (ecc-visit--line-tag) (ecc-visit--unified-line))))
    (_ (or (ecc-visit--unified-line)
           (ecc-visit--numbered-line)))))

;;;; Where the file stands now

(defun ecc-visit--usable-patch-p (patch)
  "Return non-nil when PATCH is a structuredPatch with hunks in it."
  (and (vectorp patch) (> (length patch) 0)))

(defun ecc-visit-shift-line (session path line patch)
  "Return LINE of PATH moved through the changes SESSION made after PATCH.
LINE is a line of the file as PATCH left it.  Each change recorded
after it in `ecc-file-entry-patches\\=' moves the lines below its hunks
by what those hunks added less what they removed; a line inside a hunk
is left where it is, which is the place the change was made.  LINE
comes back unchanged when PATCH is not one the session recorded for
PATH."
  (let* ((entry (and line (ecc-visit--usable-patch-p patch)
                     (gethash path (ecc-session-files session))))
         (later (and entry (cdr (memq patch (ecc-file-entry-patches entry))))))
    (dolist (next later line)
      (when (ecc-visit--usable-patch-p next)
        (let ((delta 0))
          (seq-doseq (hunk next)
            (let ((old-start (alist-get 'oldStart hunk))
                  (old-lines (alist-get 'oldLines hunk))
                  (new-lines (alist-get 'newLines hunk)))
              (when (and (numberp old-start) (numberp old-lines) (numberp new-lines)
                         (>= line (+ old-start old-lines)))
                (cl-incf delta (- new-lines old-lines)))))
          (setq line (max 1 (+ line delta))))))))

(defun ecc-visit--first-change (patch)
  "Return the first line PATCH changed, in the file as it left it, or nil.
The hunk opens on lines of context; the change is what they stand
around."
  (when (ecc-visit--usable-patch-p patch)
    (let* ((hunk (aref patch 0))
           (start (alist-get 'newStart hunk))
           (lead (seq-take-while (lambda (line)
                                   (not (and (> (length line) 0)
                                             (memq (aref line 0) '(?+ ?-)))))
                                 (append (alist-get 'lines hunk) nil))))
      (and (numberp start) (max 1 (+ start (length lead)))))))

;;;; What point is on

(defun ecc-visit--input-path (input)
  "Return the file the tool INPUT names, or nil."
  (let ((path (and (consp input)
                   (or (alist-get 'file_path input)
                       (alist-get 'notebook_path input)))))
    (and (stringp path) (not (string-empty-p path)) path)))

(defun ecc-visit--node-input (node)
  "Return the input of the call NODE is about: its own, or its request\\='s."
  (pcase (ecc-node-type node)
    ('tool (ecc-model-node-get node 'input))
    ('permission (when-let* ((request (ecc-model-node-get node 'request)))
                   (ecc-request-input request)))))

(defun ecc-visit--notebook-p (input)
  "Return non-nil when INPUT names a notebook, whose lines are not the file\\='s."
  (and (consp input) (alist-get 'notebook_path input) t))

(defun ecc-visit--first-difference (before after)
  "Return the first line where AFTER differs from BEFORE, or nil.
A nil BEFORE is a file that was not there, or one not known; either way
the change starts at line 1.  The lines are split as the diff splits
them, without the empty one after a final newline, which would put a
blank line added at the end one line too far down."
  (if (null before)
      1
    (let ((old (ecc-diff--split before))
          (new (ecc-diff--split after))
          (line 1))
      (while (and old new (equal (car old) (car new)))
        (setq old (cdr old) new (cdr new) line (1+ line)))
      (and (or old new) line))))

(defun ecc-visit--edit-line (content edit)
  "Return the line of CONTENT the EDIT, an alist of an Edit\='s strings, is at."
  (or (ecc-diff--line-of content (alist-get 'new_string edit))
      (ecc-diff--line-of content (alist-get 'old_string edit))))

(defun ecc-visit--heading-line (session node path)
  "Return the line the heading of the tool NODE of SESSION opens PATH at.
A Read opens where it started reading; a change opens at the first
line it changed, moved through what came after it.  A change the CLI
has not reported a patch for -- one still running, or a Write of a new
file, whose `structuredPatch\=' is empty -- is looked for: an Edit and a
MultiEdit in the file, a Write against the file it replaced."
  (let* ((input (ecc-model-node-get node 'input))
         (patch (ecc-model-node-get node 'patch))
         (offset (alist-get 'offset input)))
    (pcase (ecc-model-node-get node 'name)
      ((guard (ecc-visit--notebook-p input)) nil)
      ("Read" (and (numberp offset) (max 1 offset)))
      ((guard (ecc-visit--usable-patch-p patch))
       (ecc-visit-shift-line session path (ecc-visit--first-change patch) patch))
      ("Edit" (ecc-visit--edit-line (ecc-diff-file-content path) input))
      ("MultiEdit"
       (let* ((content (ecc-diff-file-content path))
              (lines (delq nil (mapcar (lambda (edit)
                                         (ecc-visit--edit-line content edit))
                                       (alist-get 'edits input)))))
         (and lines (apply #'min lines))))
      ("Write"
       (let ((content (alist-get 'content input)))
         (and (stringp content)
              (ecc-visit--first-difference (ecc-model-node-get node 'before)
                                           content)))))))

(defun ecc-visit--files-patch (session path)
  "Return the patch the line at point in the Files row of PATH was drawn from.
The body of the row is the diff of every change of the file, one after
another (`ecc-render--file-diff-parts\\='): counting the lines of each
says which one the point is in."
  (when-let* ((entry (gethash path (ecc-session-files session)))
              (bounds (ecc-render-node-bounds (concat "file:" path))))
    (let ((offset (save-excursion
                    (let ((here (line-beginning-position)))
                      (goto-char (car bounds))
                      (forward-line 1)
                      (count-lines (point) here))))
          (patches (ecc-file-entry-patches entry))
          found)
      (dolist (part (ecc-render--file-diff-parts entry))
        (unless found
          (let ((lines (cl-count ?\n part)))
            (if (< offset lines)
                (setq found (list (car patches)))
              (setq offset (- offset lines)))))
        (setq patches (cdr patches)))
      (car found))))

(defun ecc-visit-target-at-point ()
  "Return what RET at point opens, as (PATH . LINE), or nil.
LINE is nil when there is no line to go to.  Asked in order: a path
the model wrote, a line of a diff, and the heading of a call that
names a file.  PATH is absolute but for the model\\='s own, which is
taken against `default-directory\\=', the directory of the session."
  (let* ((session ecc-render--session)
         (written (ecc-markdown-file-at-point))
         (row (ecc-chat-file-at-point))
         (node (and (not row) (ecc-chat-node-at-point)))
         (input (and node (ecc-visit--node-input node)))
         (path (or row (ecc-visit--input-path input)))
         (heading (and (ecc-chat-heading-at-point)
                       (equal (ecc-chat-heading-at-point)
                              (ecc-chat-node-id-at-point)))))
    (cond
     (written (cons (expand-file-name (car written)) (cdr written)))
     ((null path) nil)
     ((and heading row) (list path))
     (heading (and (eq (ecc-node-type node) 'tool)
                   (cons path (and session
                                   (ecc-visit--heading-line session node path)))))
     ((ecc-visit--line-tag)
      (let ((line (and (not (ecc-visit--notebook-p input))
                       (ecc-visit--diff-line))))
        (cons path
              (cond
               ((or (null line) (null session)) line)
               (row (ecc-visit-shift-line session path line
                                          (ecc-visit--files-patch session path)))
               ((eq (ecc-node-type node) 'tool)
                (ecc-visit-shift-line session path line
                                      (ecc-model-node-get node 'patch)))
               (t line))))))))

(defun ecc-visit-follow-link-p (pos)
  "Return non-nil when a click at POS has something to open.
This is the `follow-link\\=' of the transcript.  A link drawn with
`mouse-face\\=' is one; so is a line of a diff that has a file behind
it, which carries no `mouse-face\\=' so that nothing is put on it at
every redraw."
  (and (or (get-char-property pos 'mouse-face)
           (save-excursion
             (goto-char pos)
             (and (ecc-visit--line-tag) (ecc-visit-target-at-point))))
       t))

;;;; Opening

(defun ecc-visit-open (path &optional line session)
  "Open PATH beside SESSION at LINE, and return its window.
The window is chosen as every buffer opened out of a conversation is
\(`ecc-window-display-beside-session\\=').  With LINE the point goes to
it, the window is scrolled to put it in the middle and the line
flashes; without it the buffer keeps the point it had."
  (unless (file-exists-p path)
    (user-error "No such file: %s" (abbreviate-file-name path)))
  (let* ((buffer (find-file-noselect path))
         (window (if session
                     (ecc-window-display-beside-session buffer session)
                   (pop-to-buffer buffer)
                   (get-buffer-window buffer))))
    (when (and line (window-live-p window))
      (with-selected-window window
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter)
        (pulse-momentary-highlight-one-line (point))))
    window))

(provide 'ecc-visit)

;;; ecc-visit.el ends here
