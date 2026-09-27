;;; ecc-diff.el --- Line diffs for the ecc transcript  -*- lexical-binding: t; -*-

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

;; Pure functions that turn the input of an Edit or a Write into unified
;; diff text carrying the faces of `diff-mode'.  No external `diff'
;; process is run, so the result is the same in batch tests and on a
;; machine without the tool.
;;
;; The sources are:
;;
;; - an Edit before it is applied: old_string against new_string, with
;;   a few lines of the file around the match when the file is known;
;; - a MultiEdit before it is applied: its edits laid on the file one
;;   after another, and the file before against the file after;
;; - a Write before it is applied: the current file against the content;
;; - a NotebookEdit before it is applied: the new source of the cell;
;; - a structuredPatch the CLI reports after a change, which already has
;;   the hunks and their line numbers and is what really happened.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'diff-mode)
(require 'ecc-core)

(defcustom ecc-diff-context-lines 3
  "Lines of context shown around a change."
  :type 'integer
  :group 'ecc)

(defvar ecc-diff-max-file-size (* 1024 1024)
  "Largest file, in bytes, read to give a diff its context.")

(defvar ecc-diff-max-cells 400000
  "Largest product of the two line counts the exact diff is tried on.
Above it the whole old text is shown removed and the new text added,
which keeps a Write of thousands of lines from freezing Emacs.")

;;;; Reading a file

(defun ecc-diff-binary-p (path)
  "Return non-nil when PATH looks binary, or cannot be read.
This is git\='s own test: a NUL byte in the first 8000."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 8000)
        (and (search-forward "\0" nil t) t))
    (error t)))

(defun ecc-diff-file-content (path)
  "Return the content of the file at PATH, or nil.
Nil is returned for a missing, unreadable, too large or binary file.

Binary because there is nothing to diff there and a great deal to
draw: a Write over an existing PNG put the bytes of the old one in the
transcript, line by line, under the picture it had just drawn
\(2026-09-16).  Every caller already reads nil as \"not known\"."
  (when (and (stringp path) (file-readable-p path) (not (file-directory-p path)))
    (let ((size (file-attribute-size (file-attributes path))))
      (when (and size (<= size ecc-diff-max-file-size)
                 (not (ecc-diff-binary-p path)))
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))))))

;;;; The diff itself

(defun ecc-diff--split (text)
  "Return the lines of TEXT as a list, without a trailing empty line."
  (if (or (null text) (string-empty-p text))
      nil
    (let ((lines (split-string text "\n")))
      (if (string-empty-p (car (last lines)))
          (butlast lines)
        lines))))

(defun ecc-diff--lcs-table (a b)
  "Return the longest common subsequence table of vectors A and B."
  (let* ((n (length a))
         (m (length b))
         (table (make-vector (1+ n) nil)))
    (dotimes (i (1+ n))
      (aset table i (make-vector (1+ m) 0)))
    (let ((i (1- n)))
      (while (>= i 0)
        (let ((j (1- m)))
          (while (>= j 0)
            (aset (aref table i) j
                  (if (equal (aref a i) (aref b j))
                      (1+ (aref (aref table (1+ i)) (1+ j)))
                    (max (aref (aref table (1+ i)) j)
                         (aref (aref table i) (1+ j)))))
            (setq j (1- j))))
        (setq i (1- i))))
    table))

(defun ecc-diff-lines (old new)
  "Return the line diff of OLD against NEW.
The result is a list of (TAG . LINE) where TAG is `context', `removed'
or `added', in the order of a unified diff."
  (let* ((a (ecc-diff--split old))
         (b (ecc-diff--split new))
         (prefix 0)
         (suffix 0))
    ;; Common prefix and suffix are context for sure; trimming them keeps
    ;; the table small for the usual edit of a few lines in a long file.
    (while (and a b (equal (car a) (car b)))
      (setq prefix (1+ prefix) a (cdr a) b (cdr b)))
    (let ((ra (reverse a)) (rb (reverse b)))
      (while (and ra rb (equal (car ra) (car rb)))
        (setq suffix (1+ suffix) ra (cdr ra) rb (cdr rb)))
      (setq a (nreverse ra) b (nreverse rb)))
    (let* ((va (vconcat a))
           (vb (vconcat b))
           (n (length va))
           (m (length vb))
           (middle
            (if (> (* n m) ecc-diff-max-cells)
                (append (mapcar (lambda (l) (cons 'removed l)) a)
                        (mapcar (lambda (l) (cons 'added l)) b))
              (let ((table (ecc-diff--lcs-table va vb))
                    (i 0) (j 0) out)
                (while (or (< i n) (< j m))
                  (cond
                   ((and (< i n) (< j m) (equal (aref va i) (aref vb j)))
                    (push (cons 'context (aref va i)) out)
                    (setq i (1+ i) j (1+ j)))
                   ((and (< i n)
                         (or (>= j m)
                             (>= (aref (aref table (1+ i)) j)
                                 (aref (aref table i) (1+ j)))))
                    (push (cons 'removed (aref va i)) out)
                    (setq i (1+ i)))
                   (t
                    (push (cons 'added (aref vb j)) out)
                    (setq j (1+ j)))))
                (nreverse out))))
           (all-old (ecc-diff--split old))
           (all-new (ecc-diff--split new)))
      (append (mapcar (lambda (l) (cons 'context l)) (seq-take all-old prefix))
              middle
              (mapcar (lambda (l) (cons 'context l))
                      (seq-drop all-new (- (length all-new) suffix)))))))

(defun ecc-diff-counts (lines)
  "Return (ADDED . REMOVED) for the diff LINES."
  (cons (seq-count (lambda (l) (eq (car l) 'added)) lines)
        (seq-count (lambda (l) (eq (car l) 'removed)) lines)))

(defun ecc-diff-hunks (lines &optional context old-start new-start)
  "Group the diff LINES into hunks with CONTEXT lines around each change.
OLD-START and NEW-START are the line numbers the first line of LINES
has in the old and the new text; both default to 1.  Returns a list of
hunks, each (OLD-START OLD-COUNT NEW-START NEW-COUNT . LINES)."
  (let* ((context (or context ecc-diff-context-lines))
         (vec (vconcat lines))
         (n (length vec))
         (changed (let (idx)
                    (dotimes (i n)
                      (unless (eq (car (aref vec i)) 'context)
                        (push i idx)))
                    (nreverse idx)))
         ranges)
    ;; Merge the windows around neighbouring changes.
    (dolist (i changed)
      (let ((from (max 0 (- i context)))
            (to (min (1- n) (+ i context))))
        (if (and ranges (<= from (1+ (cdar ranges))))
            (setcdr (car ranges) (max to (cdar ranges)))
          (push (cons from to) ranges))))
    (setq ranges (nreverse ranges))
    (let ((old-line (or old-start 1))
          (new-line (or new-start 1))
          (pos 0)
          hunks)
      (dolist (range ranges)
        ;; Advance the line counters over the lines skipped before the hunk.
        (while (< pos (car range))
          (pcase (car (aref vec pos))
            ('context (setq old-line (1+ old-line) new-line (1+ new-line)))
            ('removed (setq old-line (1+ old-line)))
            ('added (setq new-line (1+ new-line))))
          (setq pos (1+ pos)))
        (let ((hunk-lines nil) (old-count 0) (new-count 0))
          (while (<= pos (cdr range))
            (let ((line (aref vec pos)))
              (push line hunk-lines)
              (pcase (car line)
                ('context (setq old-count (1+ old-count) new-count (1+ new-count)))
                ('removed (setq old-count (1+ old-count)))
                ('added (setq new-count (1+ new-count)))))
            (setq pos (1+ pos)))
          (push (append (list old-line old-count new-line new-count)
                        (nreverse hunk-lines))
                hunks)
          (setq old-line (+ old-line old-count)
                new-line (+ new-line new-count))))
      (nreverse hunks))))

;;;; Text with faces

(defvar ecc-diff-style 'numbered
  "How a diff is laid out.

`numbered' is the transcript\\='s.  Every line carries the number it has
in the file, a changed line carries its colour to the right edge, and
there is no @@ header: this is what the CLI\\='s own TUI draws, measured
against it on 2026-09-22.  A context line and an added line are
numbered in the new file, a removed line in the old one.

`unified' is the patch: an @@ header and a one character marker at the
front of every line.  That is what `diff-mode\\=' reads and what
`ecc-review.el\\=' builds its buffers out of, so the review binds this
around its calls rather than the transcript binding the other.")

(defconst ecc-diff-hunk-gap "⋮"
  "What stands between two hunks where `numbered' has no @@ header.
The numbers jump on their own, but a diff that only jumps reads as one
run of lines with a mistake in it.")

(defun ecc-diff--face (tag)
  "Return the `diff-mode' face for the line TAG."
  (pcase tag
    ('added 'diff-added)
    ('removed 'diff-removed)
    ('header 'diff-hunk-header)
    (_ 'diff-context)))

(defun ecc-diff--marker (tag)
  "Return the one character prefix of a line with TAG."
  (pcase tag
    ('added "+")
    ('removed "-")
    (_ " ")))

(defconst ecc-diff--band
  (propertize " " 'display '(space :align-to right))
  "The spacer that carries a changed line\='s colour to the right edge.
A face on a newline colours one column and stops; a space told to
stretch to the edge colours the rest of the row, which is how the CLI
draws a changed line.  It is one space, so a line copied out of the
buffer is the line.  One string for every line there will ever be: it
is concatenated, never changed, and a diff of a thousand lines made a
thousand of these.")

(defun ecc-diff--number-width (numbers)
  "Return the width of the widest of NUMBERS, at least one."
  (max 1 (apply #'max 1 (mapcar (lambda (n) (length (number-to-string (or n 1))))
                                numbers))))

(defun ecc-diff--format-numbered (lines old-line new-line width)
  "Return LINES numbered from OLD-LINE and NEW-LINE, in a cell of WIDTH.
A nil OLD-LINE leaves every line unnumbered, which is what a diff of
two strings with no file behind them has to show.

Each line is built as one string and given its faces in place: a
`propertize\=' for the number and another for the body allocated two
more strings per line, and a Files summary of sixty files draws
thousands of them at every redraw."
  (let ((old (or old-line 1))
        (new (or new-line 1))
        (out nil))
    (dolist (line lines (apply #'concat (nreverse out)))
      (let* ((tag (car line))
             (text (cdr line))
             (face (ecc-diff--face tag))
             ;; Emacs has no %*d: the width goes into the string itself.
             (cell (if (null old-line)
                       ""
                     (concat (string-pad (number-to-string
                                          (if (eq tag 'removed) old new))
                                         width nil t)
                             " ")))
             (string (if (eq tag 'context)
                         (concat cell " " text "\n")
                       (concat cell (ecc-diff--marker tag) text
                               ecc-diff--band "\n"))))
        (put-text-property 0 (length string) 'face face string)
        (when (and (eq tag 'context) (> (length cell) 0))
          ;; `shadow' rather than `line-number': a theme gives the line
          ;; number column of a buffer a background of its own, and a
          ;; band of it down the middle of a diff is a column the diff
          ;; does not have.  The CLI draws the number in grey and
          ;; nothing else (2026-09-22).
          (put-text-property 0 (length cell) 'face 'shadow string))
        (push string out)
        (pcase tag
          ('context (setq old (1+ old) new (1+ new)))
          ('removed (setq old (1+ old)))
          ('added (setq new (1+ new))))))))

(defun ecc-diff--format-unified (lines header)
  "Return LINES as patch text, under the hunk HEADER when there is one."
  (concat
   (when header
     (propertize (concat header "\n") 'face 'diff-hunk-header))
   (mapconcat (lambda (line)
                (propertize (concat (ecc-diff--marker (car line)) (cdr line) "\n")
                            'face (ecc-diff--face (car line))))
              lines "")))

(defun ecc-diff-format-lines (lines &optional header old-line new-line width)
  "Return LINES as diff text with faces, one line per element.
HEADER is the hunk header of the `unified' style; OLD-LINE, NEW-LINE
and WIDTH are what the `numbered' style counts and pads with.  Every
line ends in a newline."
  (if (eq ecc-diff-style 'unified)
      (ecc-diff--format-unified lines header)
    (ecc-diff--format-numbered lines old-line new-line
                               (or width
                                   (ecc-diff--number-width
                                    (list (+ (or old-line 1) (length lines))
                                          (+ (or new-line 1) (length lines))))))))

(defun ecc-diff-hunk-header (hunk)
  "Return the @@ header line of HUNK."
  (pcase-let ((`(,old-start ,old-count ,new-start ,new-count . ,_) hunk))
    (format "@@ -%d,%d +%d,%d @@" old-start old-count new-start new-count)))

(defun ecc-diff-format-hunks (hunks)
  "Return HUNKS, as made by `ecc-diff-hunks', as diff text with faces."
  (if (eq ecc-diff-style 'unified)
      (mapconcat (lambda (hunk)
                   (ecc-diff--format-unified (nthcdr 4 hunk)
                                             (ecc-diff-hunk-header hunk)))
                 hunks "")
    (let ((width (ecc-diff--number-width
                  (apply #'append
                         (mapcar (lambda (hunk)
                                   (pcase-let ((`(,os ,oc ,ns ,nc . ,_) hunk))
                                     (list (+ os oc) (+ ns nc))))
                                 hunks)))))
      (mapconcat (lambda (hunk)
                   (pcase-let ((`(,old-start ,_ ,new-start ,_ . ,lines) hunk))
                     (ecc-diff--format-numbered lines old-start new-start width)))
                 hunks
                 (propertize (concat ecc-diff-hunk-gap "\n") 'face 'shadow)))))

(defun ecc-diff-render (old new &optional context)
  "Return the diff of OLD against NEW as text with faces.
CONTEXT is the number of context lines, defaulting to
`ecc-diff-context-lines'.  Returns nil when the texts are equal."
  (let ((lines (ecc-diff-lines old new)))
    (when (seq-find (lambda (l) (not (eq (car l) 'context))) lines)
      (ecc-diff-format-hunks (ecc-diff-hunks lines context)))))

;;;; The three sources

(defun ecc-diff--line-of (content string)
  "Return the 1-based line where STRING starts in CONTENT, or nil."
  (when (and content string (not (string-empty-p string)))
    (let ((pos (string-search string content)))
      (when pos
        (1+ (seq-count (lambda (c) (eq c ?\n)) (substring content 0 pos)))))))

(defun ecc-diff-for-edit (old-string new-string &optional file-content context)
  "Return the diff text of replacing OLD-STRING by NEW-STRING.
When FILE-CONTENT is given and contains OLD-STRING, the surrounding
lines of the file are shown as context and the hunk header carries the
real line numbers.  CONTEXT overrides `ecc-diff-context-lines'."
  (let* ((context (or context ecc-diff-context-lines))
         (line (ecc-diff--line-of file-content old-string)))
    (if (null line)
        (ecc-diff-format-lines (ecc-diff-lines old-string new-string))
      (let* ((file-lines (ecc-diff--split file-content))
             (old-lines (ecc-diff--split old-string))
             ;; The match may start mid-line; the hunk shows whole lines.
             (first (1- line))
             (last (+ first (max 1 (length old-lines))))
             (before (seq-subseq file-lines (max 0 (- first context)) first))
             (after (seq-subseq file-lines (min (length file-lines) last)
                                (min (length file-lines) (+ last context))))
             (old-block (string-join (seq-subseq file-lines first
                                                 (min (length file-lines) last))
                                     "\n"))
             (new-block (if (string-search old-string old-block)
                            (string-replace old-string new-string old-block)
                          new-string))
             (lines (append (mapcar (lambda (l) (cons 'context l)) before)
                            (ecc-diff-lines old-block new-block)
                            (mapcar (lambda (l) (cons 'context l)) after)))
             (start (1+ (- first (length before)))))
        (ecc-diff-format-hunks
         (ecc-diff-hunks lines context start start))))))

(defun ecc-diff-for-write (content &optional old-content context)
  "Return the diff text of writing CONTENT over OLD-CONTENT.
A nil OLD-CONTENT is a new file, and every line is shown as added.
CONTEXT overrides `ecc-diff-context-lines'."
  (if (null old-content)
      (let ((lines (mapcar (lambda (l) (cons 'added l)) (ecc-diff--split content))))
        (ecc-diff-format-lines lines (format "@@ -0,0 +1,%d @@" (length lines))
                               0 1 (ecc-diff--number-width
                                    (list (length lines)))))
    (or (ecc-diff-render old-content content context)
        (propertize "(no change)\n" 'face 'diff-context))))

(defun ecc-diff-from-patch (patch)
  "Return the diff text of the structuredPatch PATCH the CLI reported.
PATCH is a vector of hunk objects with oldStart, oldLines, newStart,
newLines and lines, the lines already carrying their +, - or space."
  (let* ((hunks (append patch nil))
         (tagged
          (mapcar
           (lambda (hunk)
             (cons hunk
                   (mapcar (lambda (line)
                             (pcase (and (> (length line) 0) (aref line 0))
                               (?+ (cons 'added (substring line 1)))
                               (?- (cons 'removed (substring line 1)))
                               (_ (cons 'context (if (> (length line) 0)
                                                     (substring line 1)
                                                   "")))))
                           (append (alist-get 'lines hunk) nil))))
           hunks)))
    (if (eq ecc-diff-style 'unified)
        (mapconcat
         (lambda (pair)
           (let ((hunk (car pair)))
             (ecc-diff--format-unified
              (cdr pair)
              (format "@@ -%s,%s +%s,%s @@"
                      (alist-get 'oldStart hunk) (alist-get 'oldLines hunk)
                      (alist-get 'newStart hunk) (alist-get 'newLines hunk)))))
         tagged "")
      (let ((width (ecc-diff--number-width
                    (apply #'append
                           (mapcar (lambda (hunk)
                                     (list (+ (or (alist-get 'oldStart hunk) 1)
                                              (or (alist-get 'oldLines hunk) 0))
                                           (+ (or (alist-get 'newStart hunk) 1)
                                              (or (alist-get 'newLines hunk) 0))))
                                   hunks)))))
        (mapconcat
         (lambda (pair)
           (ecc-diff--format-numbered (cdr pair)
                                      (or (alist-get 'oldStart (car pair)) 1)
                                      (or (alist-get 'newStart (car pair)) 1)
                                      width))
         tagged
         (propertize (concat ecc-diff-hunk-gap "\n") 'face 'shadow))))))

(defun ecc-diff-patch-counts (patch)
  "Return (ADDED . REMOVED) for the structuredPatch PATCH."
  (let ((added 0) (removed 0))
    (seq-doseq (hunk (or patch []))
      (seq-doseq (line (or (alist-get 'lines hunk) []))
        (when (> (length line) 0)
          (pcase (aref line 0)
            (?+ (setq added (1+ added)))
            (?- (setq removed (1+ removed)))))))
    (cons added removed)))

(defun ecc-diff--apply-edit (text old new all)
  "Return TEXT with OLD replaced by NEW, every occurrence when ALL.
Nothing is replaced when OLD is empty or is not there: the CLI would
have refused the edit, and a guess about what it meant would show a
change that never happened."
  (cond
   ((or (null text) (null old) (string-empty-p old)) text)
   ((ecc--json-true-p all) (string-replace old new text))
   ((string-search old text)
    (let ((pos (string-search old text)))
      (concat (substring text 0 pos) new (substring text (+ pos (length old))))))
   (t text)))

(defun ecc-diff-apply-edits (text edits)
  "Return TEXT with the EDITS of a MultiEdit applied in order, or nil.
Nil for a nil TEXT: a file nobody knows is a file no edit can be laid
on.  Each edit is `old_string\=', `new_string\=' and maybe `replace_all\='."
  (when text
    (let ((after text))
      (dolist (edit (append (or edits []) nil) after)
        (setq after (ecc-diff--apply-edit
                     after
                     (alist-get 'old_string edit)
                     (or (alist-get 'new_string edit) "")
                     (alist-get 'replace_all edit)))))))

(defun ecc-diff-for-multi-edit (edits &optional file-content context)
  "Return the diff text of applying EDITS, or nil when there is none.
EDITS is the `edits\=' vector of a MultiEdit: each element has
old_string, new_string and may have replace_all.  With FILE-CONTENT the
edits are applied to it one after another and the result is one diff of
the whole file, which is what the CLI is about to do; without it each
edit is shown as its own old against new, in order.  CONTEXT overrides
`ecc-diff-context-lines\='."
  (let ((edits (append (or edits []) nil)))
    (when edits
      (if file-content
          (ecc-diff-render file-content
                           (ecc-diff-apply-edits file-content edits)
                           context)
        (let ((text (mapconcat
                     (lambda (edit)
                       (ecc-diff-format-lines
                        (ecc-diff-lines (or (alist-get 'old_string edit) "")
                                        (or (alist-get 'new_string edit) ""))))
                     edits "")))
          (unless (string-empty-p text) text))))))

(defun ecc-diff-for-notebook-edit (input)
  "Return the diff text of the NotebookEdit INPUT, or nil.
The new source of the cell is shown as added lines.  The notebook
itself is not opened to find the old source: the file is JSON, and JSON
is read in `ecc-protocol.el\=' and nowhere else."
  (let ((source (alist-get 'new_source input))
        (mode (alist-get 'edit_mode input)))
    (cond
     ((equal mode "delete") nil)
     ((or (null source) (string-empty-p source)) nil)
     (t (let* ((lines (mapcar (lambda (l) (cons 'added l))
                              (ecc-diff--split source)))
               (cell (if-let* ((id (alist-get 'cell_id input)))
                         (format "cell %s" id)
                       "new cell")))
          (concat
           ;; The cell takes the place of the file: nothing else says
           ;; which of a notebook's cells these lines are.
           (if (eq ecc-diff-style 'unified)
               ""
             (propertize (concat cell "\n") 'face 'shadow))
           (ecc-diff-format-lines
            lines
            (format "@@ %s +1,%d @@" cell (length lines))
            0 1 (ecc-diff--number-width (list (length lines))))))))))

(defun ecc-diff-tool-p (name input)
  "Return non-nil when a call to NAME with INPUT would draw a diff.
This answers without building the diff, so that it can be asked of
every node of a transcript at every redraw."
  (pcase name
    ("Edit" (or (not (string-empty-p (or (alist-get 'old_string input) "")))
                (not (string-empty-p (or (alist-get 'new_string input) "")))))
    ("MultiEdit" (> (length (or (alist-get 'edits input) [])) 0))
    ("Write" (and (alist-get 'content input) t))
    ("NotebookEdit" (not (string-empty-p (or (alist-get 'new_source input) ""))))
    (_ nil)))

(defun ecc-diff-text-counts (text)
  "Return (ADDED . REMOVED) for the diff TEXT.
The lines are told apart by the face they carry rather than by their
first character: in the `numbered\=' style a line starts with its number
in the file, and a line of the file may start with a + of its own."
  (let ((added 0) (removed 0) (start 0) (size (length (or text ""))))
    (while (< start size)
      (let ((end (or (string-search "\n" text start) size))
            (faces (ensure-list (get-text-property start 'face text))))
        (cond ((memq 'diff-added faces) (setq added (1+ added)))
              ((memq 'diff-removed faces) (setq removed (1+ removed))))
        (setq start (1+ end))))
    (cons added removed)))

(defun ecc-diff-summary (counts)
  "Return what COUNTS, an (ADDED . REMOVED) pair, did, or nil for nothing.
The words are the CLI\='s own: \"Added 1 line, removed 1 line\", and a
side that changed nothing is left out rather than counted as zero
\(measured against the TUI on 2026-09-22)."
  (let* ((added (car counts))
         (removed (cdr counts))
         (lines (lambda (n) (if (= n 1) "line" "lines"))))
    (cond
     ((and (zerop added) (zerop removed)) nil)
     ((zerop removed) (format "Added %d %s" added (funcall lines added)))
     ((zerop added) (format "Removed %d %s" removed (funcall lines removed)))
     (t (format "Added %d %s, removed %d %s"
                added (funcall lines added)
                removed (funcall lines removed))))))

(defun ecc-diff-for-tool (name input &optional before patch)
  "Return the diff text for the call to tool NAME with INPUT, or nil.
BEFORE is what the file looked like before the call, when known.
PATCH, when given, is the structuredPatch the CLI reported once the
call had run; it says what the change really was and wins over the
guess made from BEFORE.  Only the file tools have a diff; the others
return nil."
  (let ((text
         (if (and patch (> (length patch) 0) (ecc-diff-tool-p name input))
             (ecc-diff-from-patch patch)
           (pcase name
             ("Edit"
              (ecc-diff-for-edit (or (alist-get 'old_string input) "")
                                 (or (alist-get 'new_string input) "")
                                 before))
             ("MultiEdit"
              (ecc-diff-for-multi-edit (alist-get 'edits input) before))
             ("Write"
              (ecc-diff-for-write (or (alist-get 'content input) "") before))
             ("NotebookEdit"
              (ecc-diff-for-notebook-edit input))
             (_ nil)))))
    ;; An empty string is not "no diff" to a caller that only asks
    ;; whether there is one: it draws a file path with nothing under it.
    (unless (or (null text) (string-empty-p text)) text)))

(provide 'ecc-diff)

;;; ecc-diff.el ends here
