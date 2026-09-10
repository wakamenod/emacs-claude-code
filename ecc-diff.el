;;; ecc-diff.el --- Line diffs for the ecc transcript  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Pure functions that turn the input of an Edit or a Write into unified
;; diff text carrying the faces of `diff-mode'.  No external `diff'
;; process is run, so the result is the same in batch tests and on a
;; machine without the tool.
;;
;; Three sources are handled:
;;
;; - an Edit before it is applied: old_string against new_string, with
;;   a few lines of the file around the match when the file is known;
;; - a Write before it is applied: the current file against the content;
;; - a structuredPatch the CLI reports after a change, which already has
;;   the hunks and their line numbers.

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

(defun ecc-diff-file-content (path)
  "Return the content of the file at PATH, or nil.
Nil is returned for a missing, unreadable or too large file."
  (when (and (stringp path) (file-readable-p path) (not (file-directory-p path)))
    (let ((size (file-attribute-size (file-attributes path))))
      (when (and size (<= size ecc-diff-max-file-size))
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

(defun ecc-diff-format-lines (lines &optional header)
  "Return LINES as unified diff text with faces, one line per element.
HEADER, when given, is a hunk header string put in front.  Every line
ends in a newline."
  (concat
   (when header
     (propertize (concat header "\n") 'face 'diff-hunk-header))
   (mapconcat (lambda (line)
                (propertize (concat (ecc-diff--marker (car line)) (cdr line) "\n")
                            'face (ecc-diff--face (car line))))
              lines "")))

(defun ecc-diff-hunk-header (hunk)
  "Return the @@ header line of HUNK."
  (pcase-let ((`(,old-start ,old-count ,new-start ,new-count . ,_) hunk))
    (format "@@ -%d,%d +%d,%d @@" old-start old-count new-start new-count)))

(defun ecc-diff-format-hunks (hunks)
  "Return HUNKS, as made by `ecc-diff-hunks', as unified diff text."
  (mapconcat (lambda (hunk)
               (ecc-diff-format-lines (nthcdr 4 hunk) (ecc-diff-hunk-header hunk)))
             hunks ""))

(defun ecc-diff-render (old new &optional context)
  "Return the unified diff of OLD against NEW as text with faces.
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
        (ecc-diff-format-lines lines (format "@@ -0,0 +1,%d @@" (length lines))))
    (or (ecc-diff-render old-content content context)
        (propertize "(no change)\n" 'face 'diff-context))))

(defun ecc-diff-from-patch (patch)
  "Return the diff text of the structuredPatch PATCH the CLI reported.
PATCH is a vector of hunk objects with oldStart, oldLines, newStart,
newLines and lines, the lines already carrying their +, - or space."
  (mapconcat
   (lambda (hunk)
     (concat
      (propertize (format "@@ -%s,%s +%s,%s @@\n"
                          (alist-get 'oldStart hunk) (alist-get 'oldLines hunk)
                          (alist-get 'newStart hunk) (alist-get 'newLines hunk))
                  'face 'diff-hunk-header)
      (mapconcat (lambda (line)
                   (propertize (concat line "\n")
                               'face (pcase (and (> (length line) 0) (aref line 0))
                                       (?+ 'diff-added)
                                       (?- 'diff-removed)
                                       (_ 'diff-context))))
                 (append (alist-get 'lines hunk) nil) "")))
   (append patch nil) ""))

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

(defun ecc-diff-for-tool (name input &optional before)
  "Return the diff text for the call to tool NAME with INPUT, or nil.
BEFORE is what the file looked like before the call, when known.
Only Edit and Write have a diff; other tools return nil."
  (pcase name
    ((or "Edit" "MultiEdit")
     (ecc-diff-for-edit (or (alist-get 'old_string input) "")
                        (or (alist-get 'new_string input) "")
                        before))
    ("Write"
     (ecc-diff-for-write (or (alist-get 'content input) "") before))
    (_ nil)))

(provide 'ecc-diff)

;;; ecc-diff.el ends here
