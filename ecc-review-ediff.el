;;; ecc-review-ediff.el --- Reviewing what Claude changed side by side  -*- lexical-binding: t; -*-

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

;; The other way `ecc-review' and `ecc-review-worktree' can show what
;; changed, chosen with `ecc-review-style': ediff rather than one
;; unified diff.  Everything after that is the review of `ecc-review.el'
;; -- c comments a difference, C-c C-c sends every comment as one
;; prompt -- because the comments are the same `ecc-review-note's, kept
;; in the control buffer, and what differs between the two kinds of
;; review is the generic functions of "Kinds of review" there, whose
;; ediff methods are here.
;;
;; To the comments and to Claude, a difference is a hunk and its lines
;; are the lines it takes out and puts in.  Claude's comments over MCP
;; (`ecc-review-agent.el') go under their line on the side it is on;
;; the user's c is about the whole difference, the keys of ediff going
;; to its control panel, and answers Claude when Claude has spoken
;; there.  An open ediff review follows the files as the diff review
;; does, read again into the same two buffers with the difference being
;; read and the place of each side kept.  The one thing Claude cannot do
;; is open one: ediff takes the frame and the keyboard.
;;
;; Concatenation, not one session per file.  Every changed file goes
;; into buffer A as it was and into buffer B as it is, one after the
;; other under the same separator line, and the two buffers are given
;; to `ediff-buffers' once.  n and p then walk every difference of the
;; whole review, across file boundaries, which is what a review wants;
;; ediff's own session groups walk files instead, and reach for
;; internal functions, file names and a non-recursive directory scan to
;; do it.  The separator lines are identical on both sides, so they are
;; never a difference themselves; each one's line number is remembered
;; in `ecc-review-ediff--sections', which is how a difference is
;; traced back to a file and a line in it without searching the buffer
;; for text that the content itself could hold.  A blank line in front
;; of each separator (`ecc-review-ediff-file-spacing') keeps one file
;; from running into the next.
;;
;; They are read as code, not as text: each file is fontified by its own
;; major mode -- what is on the screen before the review is shown, the
;; rest a slice at a time after -- and the differences are marked in the
;; colours the diff review uses, because ediff's own faces for the
;; differences it is not standing on are invisible under a good many
;; themes.  The one being read is then told apart from them twice over:
;; a stronger shade of its own colour, and a bar in the fringe beside
;; every line of it, because under a theme that paints the current
;; difference in the very colours a diff is read by the shade alone
;; says nothing.  What changed inside its lines is carried further still,
;; so that the stronger shade does not swallow it, and is marked in every
;; difference on the screen, not in the current one alone.
;;
;; Both buffers are read-only, and that is the whole of it: a review
;; reads, comments and sends, and writes nothing.  ediff's a and b say
;; `buffer-read-only' and change nothing, which is the behaviour
;; wanted -- the files on disk are Claude's to change, from the prompt
;; the comments are sent as.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'seq)
(require 'ediff)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-diff)
(require 'ecc-window)
(require 'ecc-review)
(require 'ecc-review-files)
(require 'ecc-review-talk)

;;;; The two trees a review compares

(defun ecc-review-ediff--tree (root spec)
  "Return the tree of the revision SPEC in ROOT, or nil."
  (ecc-review--git-string root "rev-parse" "--verify" "--quiet" (concat spec "^{tree}")))

(defun ecc-review-ediff--trees (root range)
  "Return (LEFT . RIGHT), the two trees RANGE names in ROOT.
RANGE is what `ecc-review-worktree\\=' is given: a revision like
\"HEAD\", a range like \"main...HEAD\", \"a..b\" or \"X^!\", the
empty string for what is not staged yet, or `staged\\=' for what is.  A revision
is compared with the working tree as it stands, so what git does not
track is in the review as well; a range is two trees of the history and
nothing else, and so is `staged\\='.  Signals a `user-error\\=' when git
cannot resolve it."
  (let* ((fail (lambda ()
                 (user-error "Git cannot diff against %S in %s"
                             range (abbreviate-file-name root))))
         (side (lambda (spec)
                 (or (ecc-review-ediff--tree root spec) (funcall fail))))
         (now (lambda ()
                (or (ecc-review-snapshot root)
                    (user-error "Cannot read the working tree of %s"
                                (abbreviate-file-name root))))))
    (cond
     ;; What is staged: HEAD against the index.
     ((eq range 'staged)
      (cons (or (ecc-review--head-tree root) (funcall fail))
            (or (ecc-review-snapshot root t) (funcall fail))))
     ;; What is not staged yet: the index against the working tree.
     ((or (null range) (string-empty-p range))
      (cons (or (ecc-review-snapshot root t) (funcall fail)) (funcall now)))
     ;; One commit, X^!: its first parent against it, which is what
     ;; `git diff X^!' shows of a commit that is not a merge.
     ((string-match "\\`\\(.+\\)\\^!\\'" range)
      (let ((commit (match-string 1 range)))
        (cons (funcall side (concat commit "^")) (funcall side commit))))
     ((string-match "\\`\\(.*?\\)\\.\\.\\.\\(.*\\)\\'" range)
      (let* ((left (or (match-string 1 range) ""))
             (right (or (match-string 2 range) ""))
             (left (if (string-empty-p left) "HEAD" left))
             (right (if (string-empty-p right) "HEAD" right))
             (base (or (ecc-review--merge-base root left right)
                       (funcall fail))))
        (cons (funcall side base) (funcall side right))))
     ((string-match "\\`\\(.*?\\)\\.\\.\\(.*\\)\\'" range)
      (let ((left (or (match-string 1 range) ""))
            (right (or (match-string 2 range) "")))
        (cons (funcall side (if (string-empty-p left) "HEAD" left))
              (funcall side (if (string-empty-p right) "HEAD" right)))))
     ;; A repository with no commit has no HEAD, and git calls that a
     ;; bad revision rather than an empty comparison.  The empty tree is
     ;; what HEAD would mean there, the way the diff review reads it.
     ((and (equal range "HEAD") (ecc-review--unborn-p root))
      (cons (or (ecc-review--empty-tree root) (funcall fail)) (funcall now)))
     (t (cons (funcall side range) (funcall now))))))

;;;; The pairs

(defun ecc-review-ediff--blobs (root left right paths)
  "Return the blobs of every file that differs between LEFT and RIGHT.
An alist of PATH to (BEFORE AFTER BEFORE-MODE AFTER-MODE), BEFORE and
AFTER the ids of the blobs the trees hold for PATH, nil for a tree that
does not name it -- one side of a file created or deleted -- and the
modes as git writes them, \"160000\" being a submodule, whose id is a
commit and no blob.  ROOT is the repository, PATHS restrict it."
  (pcase (apply #'ecc-review--git root
                (append (list "diff" "--raw" "-z" "--no-renames" "--no-abbrev"
                              left right "--")
                        paths))
    (`(0 . ,output)
     (let ((fields (split-string output "\0" t))
           (blobs nil))
       ;; Each record is ":MODE MODE BLOB BLOB STATUS" and then the path.
       (while fields
         (let ((record (split-string (pop fields) " "))
               (path (pop fields))
               (blob (lambda (id) (and (not (string-match-p "\\`0+\\'" id)) id))))
           (push (list path (funcall blob (nth 2 record)) (funcall blob (nth 3 record))
                       (string-remove-prefix ":" (nth 0 record)) (nth 1 record))
                 blobs)))
       (nreverse blobs)))
    (result (ecc-log "review" "diff --raw failed in %s: %S" root result)
            nil)))

(defun ecc-review-ediff--cat-file (root ids option each)
  "Run `git cat-file OPTION' in ROOT on IDS and call EACH on what it says.
OPTION is \"--batch-check\" or \"--batch\".  EACH is called with an
id, its type and its size, and under --batch with its bytes as well, a
unibyte string; nothing is called for an id git does not have.  A git
that fails is logged."
  (when (and ids (executable-find ecc-review-git-executable))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (mapconcat #'identity ids "\n") "\n")
      (let* ((default-directory (file-name-as-directory root))
             (coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (code (condition-case error
                       (call-process-region (point-min) (point-max)
                                            ecc-review-git-executable
                                            t '(t nil) nil "cat-file" option)
                     (file-error (error-message-string error)))))
        (if (not (eq code 0))
            (ecc-log "review" "cat-file %s failed in %s: %S" option root code)
          (goto-char (point-min))
          ;; "ID TYPE SIZE", and under --batch SIZE bytes and a newline;
          ;; "ID missing" for an id git does not have.
          (while (re-search-forward "^\\([0-9a-f]+\\) \\([a-z]+\\)\\(?: \\([0-9]+\\)\\)?\n"
                                    nil t)
            (let ((id (match-string 1))
                  (type (match-string 2))
                  (size (and (match-string 3) (string-to-number (match-string 3)))))
              (when size
                (if (not (equal option "--batch"))
                    (funcall each id type size)
                  (let ((end (min (point-max) (+ (point) size))))
                    (funcall each id type size (buffer-substring (point) end))
                    (goto-char (min (point-max) (1+ end)))))))))))))

(defun ecc-review-ediff--read-blobs (root blobs cache)
  "Read every blob of BLOBS in ROOT that CACHE lacks, through two git processes.
`git cat-file --batch-check' gives the size of each, and `git cat-file
--batch' the bytes of those within `ecc-review-max-bytes', so a review
of fifty files starts two processes where it started a hundred, and a
blob too large to show is never read: reading the two sides of 57
files took 0.80 s one process a file and takes 0.05 s this way
\(measured 2026-10-01).  Each size goes into CACHE under (size . BLOB),
and each text under (raw . BLOB), decoded the way `call-process' would
have decoded it.  What git will not give is left out of CACHE, and
`ecc-review-ediff--blob-text' asks for it alone, which says why; so does
a git that fails here altogether, which is logged."
  (let* ((wanted (seq-uniq (seq-remove (lambda (blob) (gethash (cons 'raw blob) cache))
                                       (delq nil (copy-sequence blobs)))))
         (coding (or (car (find-operation-coding-system
                           'call-process ecc-review-git-executable))
                     (car default-process-coding-system)
                     'undecided)))
    (ecc-review-ediff--cat-file
     root (seq-remove (lambda (blob) (gethash (cons 'size blob) cache)) wanted)
     "--batch-check"
     (lambda (id type size)
       (when (equal type "blob")
         (puthash (cons 'size id) size cache))))
    (ecc-review-ediff--cat-file
     root (seq-filter (lambda (blob)
                        (let ((size (gethash (cons 'size blob) cache)))
                          (and size (<= size ecc-review-max-bytes))))
                      wanted)
     "--batch"
     (lambda (id type _size bytes)
       (when (equal type "blob")
         (puthash (cons 'raw id) (decode-coding-string bytes coding) cache))))))

(defun ecc-review-ediff--blob-text (root blob cache)
  "Return the text of BLOB in ROOT, nil for no blob.
CACHE, a hash table or nil, keeps what was read under (raw . BLOB): a
blob is the same text for as long as it exists, so a file that did not
change since the review was last read is not read again, and
`ecc-review-ediff--read-blobs' fills it for a whole review at once.  A
blob that is not there is asked for alone.  A blob git will not give is
logged and signalled: taken for nothing, it would read as a file
created or deleted."
  (when blob
    (let ((key (cons 'raw blob)))
      (or (and cache (gethash key cache))
          (pcase (ecc-review--git root "cat-file" "blob" blob)
            (`(0 . ,output)
             (when cache (puthash key output cache))
             output)
            (result
             (ecc-log "review" "cat-file %s failed in %s: %S" blob root result)
             (error "git cat-file %s failed (%s)" (substring blob 0 (min 8 (length blob)))
                    (if (consp result)
                        (format "exit %s" (car result))
                      "git cannot be run"))))))))

(defun ecc-review-ediff-pairs (root left right &optional paths cache)
  "Return what differs between the trees LEFT and RIGHT of ROOT.
PATHS, relative to ROOT, restrict the comparison.  The result is a list
of (PATH BEFORE AFTER NOTE BEFORE-BLOB AFTER-BLOB STATUS) in the order
git reports, where BEFORE and AFTER are what the two trees hold, the BLOBs
their ids, STATUS \"A\" for a file the left tree does not name, \"D\"
for one the right does not and \"M\" for the rest, and NOTE, when
non-nil, says why neither is there: a file git
calls binary, one too large for `ecc-review-max-bytes\\=', a submodule,
or one git would not give is named and not shown.  Both sides being
empty, such a file is no difference at all
and only its separator line is read, which is where the note is put.
CACHE is that of `ecc-review-ediff--blob-text\\='; every blob is read
through it, and through one git process (`ecc-review-ediff--read-blobs\\=')."
  (let* ((blobs (ecc-review-ediff--blobs root left right paths))
         (numstat (ecc-review--numstat root left right paths))
         (cache (or cache (make-hash-table :test #'equal)))
         (pairs nil))
    (ecc-review-ediff--read-blobs
     root
     (mapcan (lambda (entry)
               (pcase-let ((`(,before ,after ,before-mode ,after-mode)
                            (cdr (assoc (car entry) blobs))))
                 (unless (or (cdr entry) (member "160000" (list before-mode after-mode)))
                   (list before after))))
             numstat)
     cache)
    (pcase-dolist (`(,path . ,binary) numstat)
      (pcase-let* ((`(,before-id ,after-id ,before-mode ,after-mode)
                    (cdr (assoc path blobs)))
                   (submodule (member "160000" (list before-mode after-mode)))
                   (failed nil)
                   ;; The size git gave with the blob, so that one too
                   ;; large to show is not read to be found too large.
                   (oversize (seq-find (lambda (size) (> size ecc-review-max-bytes))
                                       (delq nil (mapcar (lambda (id)
                                                           (and id (gethash (cons 'size id)
                                                                            cache)))
                                                         (list before-id after-id)))))
                   (`(,before . ,after)
                    (unless (or binary submodule oversize)
                      (condition-case error
                          (cons (ecc-review-ediff--blob-text root before-id cache)
                                (ecc-review-ediff--blob-text root after-id cache))
                        (error (setq failed (error-message-string error))
                               nil))))
                   (size (or oversize
                             (max (string-bytes (or before "")) (string-bytes (or after "")))))
                   (note (cond (submodule "submodule, not shown")
                               (binary "binary, not shown")
                               (failed (format "could not be read: %s" failed))
                               ((> size ecc-review-max-bytes)
                                (format "%s, not shown"
                                        (file-size-human-readable size))))))
        (push (list path
                    (if note "" (or before ""))
                    (if note "" (or after ""))
                    note
                    (and (not note) before-id)
                    (and (not note) after-id)
                    (cond ((null before-id) "A")
                          ((null after-id) "D")
                          (t "M")))
              pairs)))
    (nreverse pairs)))

(defun ecc-review-ediff--prune (cache pairs)
  "Keep in CACHE only what the blobs of PAIRS need.
Its keys are (raw . BLOB), (size . BLOB) and (face BLOB PATH FONTIFY)."
  (when cache
    (let ((wanted (make-hash-table :test #'equal)))
      (pcase-dolist (`(,_ ,_ ,_ ,_ ,before ,after) pairs)
        (when before (puthash before t wanted))
        (when after (puthash after t wanted)))
      (maphash (lambda (key _)
                 (unless (gethash (if (memq (car key) '(raw size)) (cdr key) (cadr key))
                                  wanted)
                   (remhash key cache)))
               cache))))

;;;; The two buffers

(defvar-local ecc-review-ediff--sections nil
  "Where each file begins, as (PATH BASE-LINE NOW-LINE STATUS).
The lines are those of the separator line in the two buffers, in the
order the files were written out, and STATUS is that of
`ecc-review-ediff-pairs\='.  Buffer-local in the ediff control buffer.")

(defvar-local ecc-review-ediff--cache nil
  "What this review read and coloured, by blob; see `ecc-review-ediff--blob-text\='.
Under (raw . BLOB) the text of a blob, and under (face BLOB PATH FONTIFY)
that text fontified as PATH.  Kept in the control buffer, pruned to the
blobs of the review on every reading.")

(defvar-local ecc-review-ediff--buffers nil
  "The (BASE . NOW) buffers this control buffer compares.")

(defvar-local ecc-review-ediff--windows nil
  "The window configuration to put back when this review is quit.")

(defvar-local ecc-review-ediff--frame nil
  "The frame the review was opened in, to hand the keyboard back to.")

(defun ecc-review-ediff-buffer-name (session side &optional range label)
  "Return the name of the SIDE buffer of the ediff review of SESSION.
SIDE is `base' for what the files held and `now' for what they hold.
RANGE is that of a review of the working tree, called LABEL when given
\(`ecc-review-range-label\='): every review has its own
two buffers, named the way `ecc-review-buffer-name\=' names the diff
reviews, so that two ediff reviews of one session -- of what it changed
and of the working tree -- do not write into each other's."
  (let ((name (ecc-review-buffer-name session nil range label)))
    (format "*ecc-review-%s:%s" side (substring name (length "*ecc-review:")))))

(defvar ecc-review-ediff-fontify t
  "Non-nil colours the code of a review the way its major mode would.
The two buffers hold many files at once and no one major mode fits
them, so each file is fontified on its own in a temporary buffer and
the faces are carried in as text properties.  That is how this package
works anyway: faces are put on at insertion time and no buffer of ours
runs font-lock.  Nil leaves the text plain, which is what it was.")

(defvar ecc-review-ediff-fontify-max-line 4000
  "Files of an ediff review with a line longer than this are left uncoloured.
A minified script or a document on one line is fontified as one piece
whatever it is cut into, and that piece can take seconds.")

(defvar ecc-review-ediff-fontify-chunk 100
  "How many lines of a file are fontified at a time.
Colouring checks the clock and the keyboard between two chunks.  A file
too large for this to matter is not shown at all
\(`ecc-review-max-bytes').")

(defun ecc-review-ediff--fontifiable-p (text)
  "Return non-nil when no line of TEXT is too long to colour.
How large a file may be at all is `ecc-review-max-bytes'."
  (let ((start 0)
        (fits t))
    (while (and fits start)
      (let ((end (string-search "\n" text start)))
        (when (> (- (or end (length text)) start) ecc-review-ediff-fontify-max-line)
          (setq fits nil))
        (setq start (and end (1+ end)))))
    fits))

(defun ecc-review-ediff--fontify-buffer (text path)
  "Return a buffer holding TEXT in the major mode of PATH, to be fontified.
Nil when there is nothing to colour or it is not to be coloured
\(`ecc-review-ediff--fontifiable-p').  Mode hooks are not run: a file of
the review is read, never edited, and a hook that starts a language
server or asks a question has no business in a buffer that exists to
be diffed.  A mode that raises is logged, and the text left plain; one
that is quit, or raises, leaves no buffer behind."
  (when (and ecc-review-ediff-fontify text (not (string-empty-p text))
             (ecc-review-ediff--fontifiable-p text))
    (let ((buffer (generate-new-buffer " *ecc-review-fontify*" t))
          (ready nil))
      (unwind-protect
          (condition-case error
              (with-current-buffer buffer
                (insert text)
                (let ((buffer-file-name (expand-file-name path))
                      (enable-local-variables nil)
                      (inhibit-message t))
                  (delay-mode-hooks (set-auto-mode)))
                ;; A batch Emacs has font-lock off.
                (font-lock-mode 1)
                (font-lock-set-defaults)
                (setq ready buffer))
            (error
             (ecc-log "review" "cannot set up %s to colour it: %S" path error)
             nil))
        (unless ready
          (kill-buffer buffer))))))

(defun ecc-review-ediff--fontify-chunk (buffer from)
  "Fontify a chunk of BUFFER from FROM on and return where it ends.
`ecc-review-ediff-fontify-chunk' lines, which font-lock may extend to
take in a construct that spans more."
  (with-current-buffer buffer
    (let ((to (save-excursion
                (goto-char from)
                (forward-line ecc-review-ediff-fontify-chunk)
                (point))))
      (font-lock-fontify-region from to)
      to)))

(defun ecc-review-ediff--face-runs (object from to)
  "Return the faces OBJECT has between FROM and TO, as (BEG END FACE) runs.
OBJECT is a string or a buffer.  `font-lock-face' counts as `face' where
`face' is not set: in a buffer of this package, which runs no
font-lock, it would show nothing.  Nothing else is carried -- not the
`invisible', `display' or `help-echo' a mode puts on its text: the
review shows the text as it is."
  (let ((runs nil)
        (position from))
    (while (< position to)
      ;; Any property's change, not each of the two faces': looking for
      ;; the next `font-lock-face' where there is none goes to the end
      ;; every time, which made 18,000 lines take 4 s.
      (let ((next (or (next-property-change position object to) to))
            (face (or (get-text-property position 'face object)
                      (get-text-property position 'font-lock-face object))))
        (when face
          (if (and runs (= (cadr (car runs)) position) (equal (nth 2 (car runs)) face))
              (setcar (cdr (car runs)) next)
            (push (list position next face) runs)))
        (setq position next)))
    (nreverse runs)))

(defun ecc-review-ediff--faces-only (string)
  "Return STRING with its faces and no other text property."
  (let ((plain (substring-no-properties string)))
    (pcase-dolist (`(,beg ,end ,face) (ecc-review-ediff--face-runs string 0 (length string)))
      (put-text-property beg end 'face face plain))
    plain))

(defun ecc-review-ediff--fontify (text path)
  "Return TEXT with the faces the major mode of PATH gives it, and only those.
All at once, which is what the colouring of an open review does a chunk
at a time (`ecc-review-ediff--colour-job'), with the same result."
  (if-let* ((buffer (ecc-review-ediff--fontify-buffer text path)))
      (unwind-protect
          (with-current-buffer buffer
            (font-lock-ensure)
            (ecc-review-ediff--faces-only (buffer-string)))
        (kill-buffer buffer))
    text))

(defun ecc-review-ediff--separator (path note)
  "Return the line that opens PATH in both buffers, saying NOTE if any."
  (format "═══ %s ═══" (if note (format "%s (%s)" path note) path)))

(defvar ecc-review-ediff-split-window-function #'split-window-horizontally
  "How an ediff review splits the window between its two sides.
Left and right by default: a review is read line against line, and
ediff\='s own default of one above the other puts a screen of air
between the two halves of a change.  It is set in the control buffer of
the review alone, so the ediff of anything else keeps the layout
`ediff-split-window-function\=' asks for; nil here leaves the review
with that layout too.

Where the control panel goes is `ediff-window-setup-function\=', which
this package does not touch: a graphical Emacs gives it a small frame
of its own, a terminal a window of the same frame, and
`ediff-toggle-multiframe\=' switches between the two.")

(defvar ecc-review-ediff-file-spacing 1
  "Blank lines put in front of each file but the first of an ediff review.
The separator line alone runs the files together where one ends and the
next begins; a line of air says at a glance that this is another file.
The blank lines are the same on both sides, so they are no difference of
their own, and they belong to the file above -- a deletion at the end of
one still reads against that file and not the next.")

(defun ecc-review-ediff--insert (buffer separator text)
  "Append SEPARATOR and TEXT to BUFFER; return (LINE BEG . END).
LINE is the line of SEPARATOR, and BEG and END are where TEXT went.
`ecc-review-ediff-file-spacing\=' blank lines go in front of it unless
BUFFER is still empty.  TEXT is given a closing newline when it lacks
one, so that what follows starts a line of its own."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (= (point-min) (point-max))
        (insert (make-string (max 0 ecc-review-ediff-file-spacing) ?\n)))
      (let ((line (line-number-at-pos (point))))
        ;; No font-lock in a buffer of this package: the face goes on
        ;; the text as it is inserted, or once it is known
        ;; (`ecc-review-ediff--colour-later').
        (insert (propertize separator 'face 'ecc-heading-face) "\n")
        (let ((beg (point)))
          (unless (string-empty-p text)
            (insert text)
            (unless (bolp) (insert "\n")))
          (cons line (cons beg (+ beg (length text)))))))))

(defvar ecc-review-ediff-diff-faces t
  "Non-nil marks every difference the way the diff review marks a hunk.
ediff paints the differences it is not standing on with
`ediff-odd-diff-A\=' and its relatives, which a good many themes leave
near enough invisible: the one this was found on gives them a shade of
the background and no foreground at all, so a review of six changes
showed one of them (2026-09-16).

Non-nil remaps those faces, in the two buffers of the review alone, to
`diff-removed\=' on the left and `diff-added\=' on the right -- the faces
the diff review already reads by, so the colours are the theme\='s own
and no other ediff is touched.  The difference ediff is standing on
keeps `ediff-current-diff-A\=' and `-B\='.")

(defvar ecc-review-ediff-current-diff-faces t
  "Non-nil paints the difference ediff is standing on a shade stronger.
`ecc-review-ediff-diff-faces\=' gives every other difference the colours
of `diff-removed\=' and `diff-added\=', and under a theme that paints
`ediff-current-diff-A\=' and `-B\=' in exactly those colours the
difference being read looks like all the rest: modus-vivendi gives both
`#4f1119\=' on the left and both `#00381f\=' on the right, so nothing
said which of the twelve differences n had just walked to
\(2026-09-18).

Non-nil remaps the two current-difference faces, in the two buffers of
the review alone, to a stronger shade of their own background -- the
theme\='s colour, lightened on a dark background and darkened on a
light one -- in bold.  What changed within the line is kept apart from
the stronger shade by `ecc-review-ediff-fine-diff-faces\='.  See also
`ecc-review-ediff-current-diff-mark\='.")

(defvar ecc-review-ediff-current-diff-step 5
  "How far the colour of the current difference is carried, in lightness.
Five points of HSL lightness away from the background the theme gave
the difference: about half the step modus-vivendi itself puts between
`ediff-current-diff-A\=' and `ediff-fine-diff-A\='.  The colour is the
second answer to the question of which difference this is and not the
first -- the bar in the fringe is not a shade to compare, so what the
colour has to do is hold the eye where the bar has already sent it,
which a deeper shade of the same colour does without shouting.")

(defvar ecc-review-ediff-fine-diff-faces t
  "Non-nil keeps what changed inside a line clearly apart from the rest.
ediff marks the words that changed within a difference with
`ediff-fine-diff-A\=' and `-B\=', and under a theme that gives those
nearly the background of the current difference, lightening that
background (`ecc-review-ediff-current-diff-faces\=') took the words
away: modus-vivendi gives `ediff-fine-diff-B\=' `#034f2f\=', and the
current difference became `#004f2b\=' (2026-10-01).

Non-nil remaps the two fine-difference faces, in the two buffers of the
review alone, to the background of `diff-refine-removed\=' on the left
and `diff-refine-added\=' on the right, carried a step further and then
as many more as it takes to stand `ecc-review-ediff-fine-diff-contrast\='
points of lightness apart from the backgrounds of the differences
around it, in bold.")

(defvar ecc-review-ediff-fine-diff-contrast 12
  "How far apart in lightness what changed in a line stands from its difference.
In points of HSL lightness, from the background of the current
difference and from that of the differences around it.  Under
modus-vivendi twelve takes the words that changed on the right from
`#034f2f\=', 16 points of lightness, to `#039759\=', 30, against a
current difference of `#00512d\=', 16 (2026-10-01).")

(defun ecc-review-ediff--dark-p ()
  "Return non-nil when the frame has a dark background."
  (eq (frame-parameter nil 'background-mode) 'dark))

(defun ecc-review-ediff--rgb (colour)
  "Return COLOUR as a list of red, green and blue between 0 and 1, or nil.
A colour written in hex is read as written, not as the nearest colour
the display can show -- a terminal, and a batch Emacs, would answer
green for any of the dark greens of a theme."
  (when (stringp colour)
    (if-let* ((values (color-values-from-color-spec colour)))
        (mapcar (lambda (value) (/ value 65535.0)) values)
      (color-name-to-rgb colour))))

(defun ecc-review-ediff--lightness (colour)
  "Return the HSL lightness of COLOUR, between 0 and 1, or nil."
  (when-let* ((rgb (ecc-review-ediff--rgb colour)))
    (nth 2 (apply #'color-rgb-to-hsl rgb))))

(defun ecc-review-ediff--shade (colour points)
  "Return COLOUR with its lightness moved by POINTS, as #RRGGBB, or nil.
POINTS are points of HSL lightness, negative for darker."
  (when-let* ((rgb (ecc-review-ediff--rgb colour)))
    (pcase-let ((`(,hue ,saturation ,lightness) (apply #'color-rgb-to-hsl rgb)))
      (apply #'color-rgb-to-hex
             (append (color-hsl-to-rgb hue saturation
                                       (min 1.0 (max 0.0 (+ lightness (/ points 100.0)))))
                     (list 2))))))

(defun ecc-review-ediff--background (face)
  "Return the background of FACE as a colour, or nil when it has none."
  (let ((background (face-attribute face :background nil t)))
    (and (stringp background) (ecc-review-ediff--rgb background) background)))

(defun ecc-review-ediff--stronger (face)
  "Return the attributes of FACE with its background carried a shade further.
Away from the background of the frame: lighter on a dark one, darker on
a light one.  A face with no background of its own, and a background
that is no colour, are left to the bold alone."
  (let ((background (ecc-review-ediff--background face)))
    (append (when background
              (list :background
                    (ecc-review-ediff--shade
                     background (if (ecc-review-ediff--dark-p)
                                    ecc-review-ediff-current-diff-step
                                  (- ecc-review-ediff-current-diff-step)))))
            (list :weight 'bold :extend t))))

(defun ecc-review-ediff--apart (start around)
  "Return START carried away from every colour of AROUND, or nil.
A step of `ecc-review-ediff-current-diff-step\=' at least, away from the
background of the frame, and then as many more as it takes to stand
`ecc-review-ediff-fine-diff-contrast\=' points of lightness from each
colour of AROUND; the other way when that runs out of lightness first."
  (let ((wanted (/ ecc-review-ediff-fine-diff-contrast 100.0))
        (levels (delq nil (mapcar #'ecc-review-ediff--lightness around))))
    (seq-some
     (lambda (direction)
       (let ((colour start)
             (found nil)
             (previous nil))
         (while (and (not found) colour
                     (not (equal previous (ecc-review-ediff--lightness colour))))
           (setq previous (ecc-review-ediff--lightness colour)
                 colour (ecc-review-ediff--shade
                         colour (* direction ecc-review-ediff-current-diff-step)))
           (when (and colour
                      (seq-every-p (lambda (level)
                                     (>= (abs (- (ecc-review-ediff--lightness colour) level))
                                         wanted))
                                   levels))
             (setq found colour)))
         found))
     (if (ecc-review-ediff--dark-p) '(1 -1) '(-1 1)))))

(defun ecc-review-ediff--fine (side)
  "Return the attributes the fine differences of SIDE, `A' or `B', are given.
Their background is that of `diff-refine-removed\=' or
`diff-refine-added\=' -- `ediff-fine-diff-A\=' or `-B\=' where the theme
gives those none -- carried apart from the backgrounds around it
\(`ecc-review-ediff--apart\='): of the current difference as this review
paints it, and of the differences it is not standing on.  In bold."
  (let* ((a (eq side 'A))
         (current (if a 'ediff-current-diff-A 'ediff-current-diff-B))
         (others (cond (ecc-review-ediff-diff-faces
                        (list (if a 'diff-removed 'diff-added)))
                       (a (list 'ediff-odd-diff-A 'ediff-even-diff-A))
                       (t (list 'ediff-odd-diff-B 'ediff-even-diff-B))))
         (around (delq nil (cons (if ecc-review-ediff-current-diff-faces
                                     (plist-get (ecc-review-ediff--stronger current)
                                                :background)
                                   (ecc-review-ediff--background current))
                                 (mapcar #'ecc-review-ediff--background others))))
         (start (or (ecc-review-ediff--background
                     (if a 'diff-refine-removed 'diff-refine-added))
                    (ecc-review-ediff--background
                     (if a 'ediff-fine-diff-A 'ediff-fine-diff-B))
                    (car around)))
         (background (and start (ecc-review-ediff--apart start around))))
    (append (and background (list :background background))
            (list :weight 'bold))))

(defun ecc-review-ediff--mark-differences (base now)
  "Give BASE and NOW the colours a diff is read by, if that is wanted."
  (when ecc-review-ediff-diff-faces
    (with-current-buffer base
      (face-remap-add-relative 'ediff-odd-diff-A 'diff-removed)
      (face-remap-add-relative 'ediff-even-diff-A 'diff-removed))
    (with-current-buffer now
      (face-remap-add-relative 'ediff-odd-diff-B 'diff-added)
      (face-remap-add-relative 'ediff-even-diff-B 'diff-added)))
  (when ecc-review-ediff-current-diff-faces
    (with-current-buffer base
      (face-remap-add-relative
       'ediff-current-diff-A (ecc-review-ediff--stronger 'ediff-current-diff-A)))
    (with-current-buffer now
      (face-remap-add-relative
       'ediff-current-diff-B (ecc-review-ediff--stronger 'ediff-current-diff-B))))
  (when ecc-review-ediff-fine-diff-faces
    (with-current-buffer base
      (face-remap-add-relative 'ediff-fine-diff-A (ecc-review-ediff--fine 'A)))
    (with-current-buffer now
      (face-remap-add-relative 'ediff-fine-diff-B (ecc-review-ediff--fine 'B)))))

;;;; Refining the differences on the screen

;; ediff marks what changed inside the lines of the difference it is
;; standing on and of no other, so a screen of differences showed which
;; words changed in one of them.  The others on the screen are refined
;; too, once they are on it: after the review opens, after n or p, and
;; after a scroll, on a timer that runs once and gives way to the
;; keyboard.  Each takes a diff process of its own, which is why it is
;; never all of them at once -- a review of a thousand differences would
;; start a thousand -- and none is visited twice until the differences
;; are computed again.  ediff's own limit, `ediff-auto-refine-limit',
;; holds for these as for the current one, and so do its switches: with
;; `@' at "hidden", or `h' leaving the differences ediff is not standing
;; on unpainted, the words that changed in those are not marked either.

(defvar ecc-review-ediff-colour-slice 0.05
  "How long one turn of the work done after a review opens may run, in seconds.
That work is colouring the files and refining the differences on the
screen.  A turn ends between two chunks of a file
\(`ecc-review-ediff-fontify-chunk'), so it runs over by one at most.")

(defvar ecc-review-ediff-colour-delay 0.05
  "How long colouring an open review waits between two turns, in seconds.")

(defvar ecc-review-ediff-colour-wait 0.3
  "How long the work after a review opens waits for input to be read first.
In seconds: colouring and refining both give way to the keyboard.")

(defvar ecc-review-ediff-refine-shown t
  "Non-nil marks what changed in the lines of every difference on the screen.
Nil leaves it to ediff, which marks it in the current difference alone.")

(defvar ecc-review-ediff-refine-delay 0.1
  "How long after a move or a scroll the differences shown are refined.")

(defvar-local ecc-review-ediff--refine-timer nil
  "The one-shot timer of the next refining of what is shown, or nil.
Buffer-local in the control buffer.")

(defun ecc-review-ediff--shown-differences ()
  "Return the numbers of the differences this review has on the screen."
  (let ((ranges (mapcar (lambda (side)
                          (let ((window (if (eq side 'A) ediff-window-A ediff-window-B))
                                (buffer (if (eq side 'A) ediff-buffer-A ediff-buffer-B)))
                            (and (window-live-p window) (eq (window-buffer window) buffer)
                                 (ecc-review-ediff--shown-range window))))
                        '(A B)))
        (shown nil))
    (dotimes (n (length ediff-difference-vector-A))
      (when (seq-some (lambda (pair)
                        (let ((range (cdr pair)))
                          (and range
                               (<= (ediff-get-diff-posn (car pair) 'beg n) (cdr range))
                               (>= (ediff-get-diff-posn (car pair) 'end n) (car range)))))
                      (list (cons 'A (car ranges)) (cons 'B (cadr ranges))))
        (push n shown)))
    (nreverse shown)))

(defvar-local ecc-review-ediff--refined nil
  "The differences on the screen this review has refined or passed over.
A hash table of their numbers, or nil for none; forgotten whenever the
differences are computed again.  Buffer-local in the control buffer.")

(defun ecc-review-ediff--refine-hidden-p ()
  "Return non-nil when ediff shows no refinement outside the current one.
`@' at \"Refinements are HIDDEN\", or highlighting that does not paint the
differences ediff is not standing on -- ASCII flags, none, or faces on
the current difference alone, as `h' cycles them."
  (or (eq ediff-auto-refine 'nix)
      (not ediff-use-faces)
      (not (eq ediff-highlighting-style 'face))
      (not ediff-highlight-all-diffs)))

(defun ecc-review-ediff--refine-shown (&optional deadline)
  "Refine the differences on the screen that ediff has not, and mark them.
Run in the control buffer.  Each is visited once: refined, or passed
over by ediff -- empty on one side, white space only, over
`ediff-auto-refine-limit' -- and remembered either way, so that a
scroll does not visit it again and have ediff say the same thing again.
What ediff says as it refines is about a difference the user is not
on, and goes neither to the echo area nor to *Messages*; what it
signals is not caught.  Return nil when DEADLINE, a `float-time',
passed or input came first with some left to do, t otherwise.

Nothing is refined unless `ediff-auto-refine' is `on', and Emacs 29
works its default out when ediff is loaded: `nix' where there is no
face support -- a batch Emacs, or a daemon whose init loads ediff
before any frame -- and then ediff refines not even the current
difference.  Emacs 30 made it `on' everywhere (checked 2026-10-01).
The review follows ediff there as everywhere."
  (catch 'interrupted
    (when (and ecc-review-ediff-refine-shown
               (eq ediff-auto-refine 'on)
               (not (ecc-review-ediff--refine-hidden-p))
               (> (length ediff-difference-vector-A) 0))
      (unless ecc-review-ediff--refined
        (setq ecc-review-ediff--refined (make-hash-table)))
      (let ((inhibit-message t)
            (message-log-max nil))
        (dolist (n (ecc-review-ediff--shown-differences))
          (unless (gethash n ecc-review-ediff--refined)
            (when (and deadline (or (> (float-time) deadline) (input-pending-p)))
              (throw 'interrupted nil))
            (puthash n t ecc-review-ediff--refined)
            ;; The current one is ediff's own.
            (unless (eql n ediff-current-difference)
              (ediff-install-fine-diff-if-necessary n))))))
    t))

(defun ecc-review-ediff--keep-refined ()
  "Mark again what changed in the difference ediff is leaving.
On `ediff-unselect-hook': ediff unmarks the fine differences of the
difference it leaves, which stays on the screen as often as not, and
this review marks every one it shows."
  (when (and ecc-review-ediff-refine-shown
             (not (ecc-review-ediff--refine-hidden-p))
             (ediff-valid-difference-p ediff-current-difference)
             (or (ediff-get-fine-diff-vector ediff-current-difference 'A)
                 (ediff-get-fine-diff-vector ediff-current-difference 'B)))
    (ediff-set-fine-diff-properties ediff-current-difference)))

(defun ecc-review-ediff--refining-changed ()
  "Follow `@' or `h': hide the refinements outside the current one, or refine.
Hidden, every difference but the current one loses its fine differences,
which ediff computes again when it stands on one; shown again, the
differences on the screen are refined anew.  Run in the control buffer."
  (setq ecc-review-ediff--refined nil)
  (if (or (not ecc-review-ediff-refine-shown) (ecc-review-ediff--refine-hidden-p))
      (dotimes (n (length ediff-difference-vector-A))
        (unless (eql n ediff-current-difference)
          (when (or (ediff-get-fine-diff-vector n 'A) (ediff-get-fine-diff-vector n 'B))
            (ediff-clear-fine-differences n))))
    (ecc-review-ediff--refine-later)))

(defun ecc-review-ediff-toggle-autorefine ()
  "Toggle auto-refine as ediff's `@' does, in every difference on the screen."
  (interactive)
  (ediff-toggle-autorefine)
  (ecc-review-ediff--refining-changed))

(defun ecc-review-ediff-toggle-hilit ()
  "Switch highlighting as ediff's `h' does, the refinements on the screen with it."
  (interactive)
  (ediff-toggle-hilit)
  (ecc-review-ediff--refining-changed))

(defun ecc-review-ediff--refine-later (&optional delay)
  "Refine the differences on the screen in DELAY seconds, once.
A timer set already is left to run: one is enough for all the moves
made before it fires.  Run in the control buffer."
  (unless (timerp ecc-review-ediff--refine-timer)
    (setq ecc-review-ediff--refine-timer
          (run-with-timer (or delay ecc-review-ediff-refine-delay) nil
                          #'ecc-review-ediff--refine-turn (current-buffer)))))

(defun ecc-review-ediff--refine-turn (control)
  "Refine a slice of what the review in CONTROL shows, and set the next turn."
  (when (buffer-live-p control)
    (with-current-buffer control
      (setq ecc-review-ediff--refine-timer nil)
      ;; A side killed under a live control buffer: ediff would signal
      ;; that a vital buffer is gone, on every scroll.
      (unless (or (not (ecc-review-ediff--sides-live-p))
                  (and (not (input-pending-p))
                       (ecc-review-ediff--refine-shown
                        (+ (float-time) ecc-review-ediff-colour-slice))))
        (ecc-review-ediff--refine-later ecc-review-ediff-colour-wait)))))

(defun ecc-review-ediff--scrolled (window _start)
  "Refine what WINDOW, a side of a review, shows after it scrolled.
On `window-scroll-functions' in the two buffers of a review: it runs
within redisplay, so it does nothing but set the timer."
  (let ((control (buffer-local-value 'ecc-review--part-of (window-buffer window))))
    (when (buffer-live-p control)
      (with-current-buffer control
        (ecc-review-ediff--refine-later)))))

;;;; The bar beside the difference being read

;; A colour alone is a poor answer to "which one am I on": every
;; difference of a review is coloured, and a shade is easy to miss
;; halfway down a long file.  The bar is in the fringe, outside the
;; text, so it costs the code no column and is not a colour to compare
;; -- either a line has it or it does not.

(defface ecc-review-ediff-current-mark-face
  '((t :inherit warning))
  "Face of the bar drawn beside the difference ediff is standing on."
  :group 'ecc)

(defvar ecc-review-ediff-current-diff-mark t
  "Non-nil draws a bar in the fringe beside the difference being read.
Every line of the current difference carries it, in both buffers, and
it moves with n and p.  The two windows of the review are given a
fringe to draw it in when the frame shows none
\(`ecc-review-ediff-fringe-width\='); a terminal, and a batch test,
have no fringe at all and show nothing, which is not an error.")

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'ecc-review-ediff-current-mark
    (make-vector 1 #b11100000) nil nil '(center repeated)))

(defvar ecc-review-ediff-fringe-width 8
  "How wide a fringe the two windows of a review are given, in pixels.
The bar is drawn in the left fringe, and a frame that shows no fringe
at all -- `initial-frame-alist\=' with `left-fringe\=' 0, or
`fringe-mode\=' nil -- has nowhere to draw it: the mark was there and
invisible (2026-09-18).  A review asks for the fringe it needs in its
own two windows, which is a window the review made and gives back when
it quits, and leaves every other window of the frame as the user set
it.

Nil asks for nothing, and on a frame without fringes the bar is not
drawn at all.")

(defun ecc-review-ediff--give-the-windows-a-fringe ()
  "Give the two windows of this review a left fringe to draw the bar in.
A window that has one already is left alone: what is wanted is a fringe
where there is none, not one width for everybody."
  (when (and ecc-review-ediff-fringe-width (display-graphic-p))
    (dolist (window (list ediff-window-A ediff-window-B))
      (when (and (window-live-p window)
                 (zerop (or (car (window-fringes window)) 0)))
        (set-window-fringes window ecc-review-ediff-fringe-width
                            (nth 1 (window-fringes window)))))))

(defvar-local ecc-review-ediff--marks nil
  "The overlays drawing the bar beside the current difference.
They live in the two buffers of the review; the list is buffer-local in
the control buffer, which is where they are made and unmade.")

(defun ecc-review-ediff--unmark-current ()
  "Take down the bar beside the difference that was being read."
  (mapc #'delete-overlay ecc-review-ediff--marks)
  (setq ecc-review-ediff--marks nil))

(defun ecc-review-ediff--mark-current ()
  "Draw the bar beside every line of the difference ediff is standing on.
This is what `ediff-select-hook\=' is set to in the control buffer of a
review, so the bar follows n, p and j; ediff runs it with the control
buffer current, which is where the differences are recorded."
  (ecc-review-ediff--unmark-current)
  (when (and ecc-review-ediff-current-diff-mark
             (ediff-valid-difference-p ediff-current-difference))
    ;; Asked for again at every difference rather than once at the
    ;; start: ediff lays its windows out afresh on | and m, and a
    ;; window that has just been made carries the frame's fringes.
    (ecc-review-ediff--give-the-windows-a-fringe)
    (let ((n ediff-current-difference)
          (marks nil)
          (mark (propertize
                 " " 'display '(left-fringe ecc-review-ediff-current-mark
                                            ecc-review-ediff-current-mark-face))))
      (dolist (side (list (cons 'A ediff-buffer-A) (cons 'B ediff-buffer-B)))
        (when (buffer-live-p (cdr side))
          (let ((beg (ediff-get-diff-posn (car side) 'beg n))
                (end (ediff-get-diff-posn (car side) 'end n)))
            (with-current-buffer (cdr side)
              (save-excursion
                (goto-char beg)
                (beginning-of-line)
                ;; A difference of no length at all -- what one side
                ;; holds and the other does not -- is one line all the
                ;; same: the place the text would go is what is marked.
                (while (progn
                         (let ((overlay (make-overlay (point) (point))))
                           (overlay-put overlay 'before-string mark)
                           (push overlay marks))
                         (and (zerop (forward-line 1)) (< (point) end)))))))))
      ;; The overlays are made in the two buffers of the review and
      ;; remembered in the control buffer, which is the one this runs
      ;; in: the list is buffer-local, so it is set here and nowhere in
      ;; between.
      (setq ecc-review-ediff--marks marks))))

(defun ecc-review-ediff--coloured (text path blob cache)
  "Return TEXT fontified as PATH, from CACHE when BLOB was fontified before.
The key holds `ecc-review-ediff-fontify\=' too: text kept plain is not
what is wanted once colours are asked for."
  (let ((key (list 'face blob path ecc-review-ediff-fontify)))
    (or (and cache blob (gethash key cache))
        (let ((coloured (ecc-review-ediff--fontify text path)))
          (when (and cache blob) (puthash key coloured cache))
          coloured))))

(defun ecc-review-ediff--known-colours (path blob cache)
  "Return the text of BLOB as PATH fontified, when CACHE holds it already.
It carries faces and nothing else (`ecc-review-ediff--faces-only'), as
a file coloured once the review is open does."
  (and cache blob (gethash (list 'face blob path ecc-review-ediff-fontify) cache)))

(cl-defstruct (ecc-review-ediff--job (:constructor ecc-review-ediff--make-job)
                                     (:copier nil))
  "A file of a side of a review that went in uncoloured, to be coloured.
BEG and END are markers around where TEXT went in; PATH is what it is
fontified as and BLOB what its colours are kept under.  WORK is the
buffer it is fontified in, once begun, DONE how far that has got and
FROM where the chunk before the last began.  KEPT is the text up to
KEPT-TO with its faces, newest piece first, which no chunk will touch
again: what is kept for the file once it is done, gathered a chunk at a
time so that no turn has the whole file to copy."
  beg end path blob text work done from kept kept-to)

(defvar-local ecc-review-ediff--uncoloured nil
  "The files of this side of a review written out without their colours.
A list of `ecc-review-ediff--job's, in the order they were written, to
be coloured once the review is on the screen
\(`ecc-review-ediff--colour-later').  Buffer-local in each of the two
buffers, and made afresh whenever they are written.")

(defvar-local ecc-review-ediff--work-buffers nil
  "The buffers this review fontifies files in, live or not.
Kept in the control buffer, which outlives the two sides: a side killed
takes its list of files to colour with it, and the buffers would stay.")

(defun ecc-review-ediff--kill-work-buffers ()
  "Kill every buffer this review fontifies a file in.  Run in the control buffer."
  (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
        ecc-review-ediff--work-buffers)
  (setq ecc-review-ediff--work-buffers nil))

(defun ecc-review-ediff--drop-job (job)
  "Forget JOB: its buffer, its markers, its place in the list of its side."
  (when (buffer-live-p (ecc-review-ediff--job-work job))
    (kill-buffer (ecc-review-ediff--job-work job)))
  (let ((buffer (marker-buffer (ecc-review-ediff--job-beg job))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq ecc-review-ediff--uncoloured (delq job ecc-review-ediff--uncoloured)))))
  (set-marker (ecc-review-ediff--job-beg job) nil)
  (set-marker (ecc-review-ediff--job-end job) nil))

(defun ecc-review-ediff--drop-jobs (buffer)
  "Forget every file of BUFFER still to be coloured."
  (when (buffer-live-p buffer)
    (mapc #'ecc-review-ediff--drop-job
          (copy-sequence (buffer-local-value 'ecc-review-ediff--uncoloured buffer)))))

(defun ecc-review-ediff--write (base now pairs nothing &optional cache)
  "Write PAIRS into the buffers BASE and NOW afresh and return the sections.
With no pair at all both say NOTHING, the same on both sides, so that
the review shows no difference and says why.  Nothing but the text is
touched: the major mode, the local variables ediff keeps in the two
buffers and the colours stay, which is what lets a review that is open
be read again into the same buffers.  CACHE keeps the fontified text
of each blob (`ecc-review-ediff--cache\='): a file coloured before goes
in with its colours, and every other is written plain and left in
`ecc-review-ediff--uncoloured', to be coloured once the review is on the
screen (`ecc-review-ediff--colour-later').  Fontifying every file first
was 0.7 s of the 1.7 s a review of 57 files took to open in batch, and
2 s in an Emacs with its modes set up (measured 2026-10-01)."
  (let ((sections nil)
        (uncoloured (list (cons base nil) (cons now nil))))
    (dolist (buffer (list base now))
      (ecc-review-ediff--drop-jobs buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer))))
    (if (null pairs)
        (dolist (buffer (list base now))
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (insert (propertize (concat nothing ".  This review follows the files,"
                                          " and the next change will show up here.\n")
                                  'face 'ecc-dim-face)))))
      (pcase-dolist (`(,path ,before ,after ,note ,before-blob ,after-blob ,status)
                     pairs)
        (let ((separator (ecc-review-ediff--separator path note))
              (lines nil))
          (pcase-dolist (`(,buffer ,text ,blob) (list (list base before before-blob)
                                                      (list now after after-blob)))
            (let* ((known (ecc-review-ediff--known-colours path blob cache))
                   (place (ecc-review-ediff--insert buffer separator (or known text))))
              (when (and (not known) ecc-review-ediff-fontify (not (string-empty-p text)))
                (push (ecc-review-ediff--make-job
                       :beg (set-marker (make-marker) (cadr place) buffer)
                       :end (set-marker (make-marker) (cddr place) buffer)
                       :path path :blob blob :text text)
                      (alist-get buffer uncoloured)))
              (push (car place) lines)))
          (push (append (cons path (nreverse lines)) (list status)) sections))))
    (dolist (buffer (list base now))
      (with-current-buffer buffer
        (setq ecc-review-ediff--uncoloured (nreverse (alist-get buffer uncoloured)))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)))
    (nreverse sections)))

;;;; Colouring the code once the review is open

;; The two buffers are written plain and opened, and the files are
;; coloured afterwards: what is on the screen first, before the review
;; is shown, and the rest on a timer that runs once and sets itself
;; again, for as long as there is anything left to colour.  Never a
;; repeating timer: a repeating timer whose work outgrew its interval
;; froze the user's Emacs on 2026-09-21.  A file is fontified a chunk
;; of lines at a time in a buffer of its own, and a turn stops at the
;; end of its time, between two chunks, or as soon as there is input
;; waiting, and starts with whatever is on the screen, so that a file
;; scrolled to is the next one coloured.  A turn can be quit with C-g.
;; The colours go on as text properties, the way they went in before, so
;; the comments drawn as overlays and the reading again of a review that
;; follows the files are untouched by them.

(defvar ecc-review-ediff-colour-first 0.2
  "How long colouring what is on the screen may hold up a review, in seconds.
What is not done by then is done on the timer, as the rest is.")

(defvar-local ecc-review-ediff--colour-timer nil
  "The one-shot timer of the next turn of colouring, or nil.
Buffer-local in the control buffer.")

(defun ecc-review-ediff--sides ()
  "Return the two buffers of this review, what was and what is.
Run in the control buffer."
  (list (car ecc-review-ediff--buffers) (cdr ecc-review-ediff--buffers)))

(defun ecc-review-ediff--sides-live-p ()
  "Return non-nil when both buffers of this review are still there."
  (seq-every-p #'buffer-live-p (ecc-review-ediff--sides)))

(defun ecc-review-ediff--copy-faces (object from to buffer at)
  "Put the faces OBJECT has between FROM and TO on BUFFER, from AT on.
Text properties, as the faces of this package always are, put on
without the buffer counting as changed: `buffer-chars-modified-tick',
which says whether a review was written into, does not move."
  (let ((runs (ecc-review-ediff--face-runs object from to)))
    (with-current-buffer buffer
      (with-silent-modifications
        (pcase-dolist (`(,beg ,end ,face) runs)
          (put-text-property (+ at (- beg from)) (+ at (- end from)) 'face face))))))

(defun ecc-review-ediff--shown-range (window)
  "Return (START . END), the part of its buffer WINDOW shows, about.
Counted in lines from the start of the window rather than asked of
redisplay, which may not have been round yet."
  (with-current-buffer (window-buffer window)
    (let ((start (window-start window)))
      (cons start (save-excursion
                    (goto-char start)
                    (forward-line (window-body-height window))
                    (point))))))

(defun ecc-review-ediff--colour-job (job deadline cache)
  "Colour JOB, a chunk at a time, until it is done or DEADLINE has passed.
At least one chunk, and no more once there is input waiting.  DEADLINE
is a `float-time', nil for no end and no regard for the keyboard.  Each
chunk carries the faces from where the chunk before it began: font-lock
may go back over the end of a chunk to fontify a construct that spans
it.  Done, the faces of the file are kept in CACHE, as they are shown.
Run in the control buffer, which keeps the buffer the file is fontified
in (`ecc-review-ediff--work-buffers').  A
file whose place no longer holds its text is left as it is: something
wrote into the side since it went in.  Return non-nil when JOB is done
with."
  (let* ((beg (ecc-review-ediff--job-beg job))
         (end (ecc-review-ediff--job-end job))
         (buffer (marker-buffer beg))
         (text (ecc-review-ediff--job-text job)))
    (cond
     ((not (and (buffer-live-p buffer) (= (- end beg) (length text))))
      (ecc-review-ediff--drop-job job)
      t)
     ((and (null (ecc-review-ediff--job-work job))
           (not (setf (ecc-review-ediff--job-work job)
                      (ecc-review-ediff--fontify-buffer
                       text (ecc-review-ediff--job-path job)))))
      (ecc-review-ediff--drop-job job)
      t)
     (t
      (unless (memq (ecc-review-ediff--job-work job) ecc-review-ediff--work-buffers)
        (setq ecc-review-ediff--work-buffers
              (cons (ecc-review-ediff--job-work job)
                    (seq-filter #'buffer-live-p ecc-review-ediff--work-buffers))))
      (let* ((work (ecc-review-ediff--job-work job))
             (done (or (ecc-review-ediff--job-done job) 1))
             (last (with-current-buffer work (point-max)))
             (first t))
        (condition-case error
            (while (and (< done last)
                        (or first (not (ecc-review-ediff--yield-p deadline))))
              (let ((to (ecc-review-ediff--fontify-chunk work done))
                    (from (or (ecc-review-ediff--job-from job) 1)))
                (ecc-review-ediff--copy-faces work from to buffer (+ beg (1- from)))
                (setf (ecc-review-ediff--job-from job) done
                      (ecc-review-ediff--job-done job) to)
                ;; What is before the start of this chunk is final now.
                (ecc-review-ediff--keep job (if (< to last) done last))
                (setq done to
                      first nil)))
          (error
           (ecc-log "review" "cannot colour %s: %S" (ecc-review-ediff--job-path job) error)
           (with-current-buffer buffer
             (with-silent-modifications
               (remove-text-properties beg end '(face nil))))
           (setq done nil)))
        (cond
         ((null done) (ecc-review-ediff--drop-job job) t)
         ((< done last) nil)
         (t
          ;; What is kept is what is shown, so that the file goes in
          ;; with exactly these colours when it is written again.
          (when (and cache (ecc-review-ediff--job-blob job))
            (puthash (list 'face (ecc-review-ediff--job-blob job)
                           (ecc-review-ediff--job-path job) ecc-review-ediff-fontify)
                     (apply #'concat (reverse (ecc-review-ediff--job-kept job)))
                     cache))
          (ecc-review-ediff--drop-job job)
          t)))))))

(defun ecc-review-ediff--keep (job to)
  "Keep the text of JOB as shown, with its faces, from where it was kept to TO.
TO is a position of the buffer JOB is fontified in."
  (let ((from (or (ecc-review-ediff--job-kept-to job) 1))
        (beg (ecc-review-ediff--job-beg job)))
    (when (> to from)
      (push (with-current-buffer (marker-buffer beg)
              (ecc-review-ediff--faces-only
               (buffer-substring (+ beg (1- from)) (+ beg (1- to)))))
            (ecc-review-ediff--job-kept job))
      (setf (ecc-review-ediff--job-kept-to job) to))))

(defun ecc-review-ediff--next-job (buffers &optional shown-only)
  "Return the file of BUFFERS to colour next, or nil.
One on the screen comes first, the first in the review otherwise.  With
SHOWN-ONLY, only one on the screen."
  (let ((live (seq-filter #'buffer-live-p buffers)))
    (or (seq-some
         (lambda (buffer)
           (let ((ranges (mapcar #'ecc-review-ediff--shown-range
                                 (get-buffer-window-list buffer nil t))))
             (seq-find (lambda (job)
                         (seq-some (lambda (range)
                                     (and (< (ecc-review-ediff--job-beg job) (cdr range))
                                          (> (ecc-review-ediff--job-end job) (car range))))
                                   ranges))
                       (buffer-local-value 'ecc-review-ediff--uncoloured buffer))))
         live)
        (and (not shown-only)
             (seq-some (lambda (buffer)
                         (car (buffer-local-value 'ecc-review-ediff--uncoloured buffer)))
                       live)))))

(defun ecc-review-ediff--yield-p (deadline)
  "Return non-nil when colouring is to stop: DEADLINE passed, or input waiting.
DEADLINE nil is no end, and then the keyboard is not asked either."
  (and deadline (or (>= (float-time) deadline) (input-pending-p))))

(defun ecc-review-ediff--colour (deadline &optional shown-only)
  "Colour this review until DEADLINE, a `float-time', or until it is done.
It stops as well, after a chunk, as soon as there is input waiting.
DEADLINE nil is no end.  With SHOWN-ONLY, only what is on the screen.
Run in the control buffer."
  (let ((buffers (ecc-review-ediff--sides))
        (job nil))
    (while (and (setq job (ecc-review-ediff--next-job buffers shown-only))
                (progn (ecc-review-ediff--colour-job job deadline ecc-review-ediff--cache)
                       t)
                (not (ecc-review-ediff--yield-p deadline))))))

(defun ecc-review-ediff--colour-later (&optional delay)
  "Colour what is left of this review a slice at a time, starting in DELAY.
DELAY is `ecc-review-ediff-colour-delay' by default.  Run in the control
buffer; the timer set before is dropped, so a review has one at most."
  (when (timerp ecc-review-ediff--colour-timer)
    (cancel-timer ecc-review-ediff--colour-timer))
  (setq ecc-review-ediff--colour-timer
        (and (seq-some (lambda (buffer)
                         (and (buffer-live-p buffer)
                              (buffer-local-value 'ecc-review-ediff--uncoloured buffer)))
                       (ecc-review-ediff--sides))
             (run-with-timer (or delay ecc-review-ediff-colour-delay) nil
                             #'ecc-review-ediff--colour-turn (current-buffer)))))

(defun ecc-review-ediff--colour-turn (control)
  "Colour a slice of the review in CONTROL, and set the next turn.
With input waiting nothing is coloured and the turn is put off.  A
review that has lost a side is coloured no more, and the buffers its
files were fontified in are killed.  The turn can be quit
\(`with-local-quit'): a timer runs with `inhibit-quit' on, and a file the
user would rather not wait for is a \\[keyboard-quit] away; it is taken up
again on the next turn, from the chunk the quit fell in."
  (when (buffer-live-p control)
    (with-current-buffer control
      (setq ecc-review-ediff--colour-timer nil)
      (cond
       ((not (ecc-review-ediff--sides-live-p))
        (mapc #'ecc-review-ediff--drop-jobs (ecc-review-ediff--sides))
        (ecc-review-ediff--kill-work-buffers))
       ((input-pending-p)
        (ecc-review-ediff--colour-later ecc-review-ediff-colour-wait))
       (t
        (ecc-review-ediff--colour-later
         (unless (with-local-quit
                   (ecc-review-ediff--colour (+ (float-time) ecc-review-ediff-colour-slice))
                   t)
           ecc-review-ediff-colour-wait)))))))

(defun ecc-review-ediff--after-write ()
  "Start what follows a writing of the two sides: colours and refining.
What is on the screen is coloured now, for `ecc-review-ediff-colour-first'
at most, and the rest later; the differences on the screen are refined
later.  The later work is set first, so that a quit of the colouring
now leaves the rest to the timers.  Run in the control buffer."
  (ecc-review-ediff--colour-later)
  (ecc-review-ediff--refine-later)
  (ecc-review-ediff--colour (+ (float-time) ecc-review-ediff-colour-first) t)
  ;; Done now, it may have left nothing for the timer.
  (ecc-review-ediff--colour-later))

(defun ecc-review-ediff--side-buffer (name)
  "Return a buffer named NAME, or like it when NAME is a side of an open review.
Two reviews never share a side: the second would write into the first."
  (let ((buffer (get-buffer name)))
    (if (and buffer
             (buffer-live-p (buffer-local-value 'ecc-review--part-of buffer)))
        (generate-new-buffer name)
      (get-buffer-create name))))

(defun ecc-review-ediff--build (session pairs &optional range cache label)
  "Fill the two buffers of SESSION with PAIRS and return (BASE NOW SECTIONS).
RANGE and LABEL name the buffers (`ecc-review-ediff-buffer-name\='), and
CACHE is `ecc-review-ediff--write\='s."
  (let ((base (ecc-review-ediff--side-buffer
               (ecc-review-ediff-buffer-name session 'base range label)))
        (now (ecc-review-ediff--side-buffer
              (ecc-review-ediff-buffer-name session 'now range label))))
    (dolist (buffer (list base now))
      (with-current-buffer buffer
        (fundamental-mode)))
    (let ((sections (ecc-review-ediff--write base now pairs nil cache)))
      (dolist (buffer (list base now))
        (with-current-buffer buffer
          (goto-char (point-min))))
      (ecc-review-ediff--mark-differences base now)
      (list base now sections))))

(defun ecc-review-ediff--section-at (sections line side)
  "Return the section of SECTIONS that LINE falls in on SIDE.
SIDE is 1 for the buffer of what the files held and 2 for the buffer of
what they hold now."
  (let ((found (car sections)))
    (dolist (section sections)
      (when (<= (nth side section) line)
        (setq found section)))
    found))

;;;; The differences as hunks

;; To the comments, and to Claude, a difference is a hunk: a plist like
;; the one `ecc-review-hunk-at' makes of a hunk of the diff review, with
;; the @@ header and the text of a patch, and lines like those of
;; `ecc-review--hunk-lines'.  A comment on it is then kept, put back
;; after a refresh (`ecc-review--locate-note') and sent exactly as one on
;; a hunk is.  The lines of a difference are the ones it takes out of the
;; old side and puts into the new; a line both sides hold is no line of
;; any difference, as a line of context is none of a diff read with no
;; context, which is what the diff review shows by default.

(defvar-local ecc-review-ediff--units nil
  "The differences of this review as hunks, made when first asked for.
Nil until then, and again whenever the differences are computed anew.")

(defun ecc-review-ediff--difference (n control)
  "Return difference N of the review in CONTROL as a hunk.
The plist is the one `ecc-review-hunk-at\\=' makes of a hunk of the diff
review -- :path, :start and :end of the new side, :header and :text, a
hunk of a patch under its @@ header -- so that the prompt an ediff
review sends reads exactly like the prompt the diff review sends.  It
adds :number, N itself; :old-start and :old-end, the lines of the old
side; :old-count and :new-count, how many lines each side has; and
where the difference is, :a-beg and :a-end in the buffer of what the
files held and :b-beg and :b-end in the buffer of what they hold now.
:position is :b-beg."
  (with-current-buffer control
    (let* ((base (car ecc-review-ediff--buffers))
           (now (cdr ecc-review-ediff--buffers))
           (a-beg (ediff-get-diff-posn 'A 'beg n control))
           (a-end (ediff-get-diff-posn 'A 'end n control))
           (b-beg (ediff-get-diff-posn 'B 'beg n control))
           (b-end (ediff-get-diff-posn 'B 'end n control))
           (a-text (with-current-buffer base
                     (buffer-substring-no-properties a-beg a-end)))
           (b-text (with-current-buffer now
                     (buffer-substring-no-properties b-beg b-end)))
           (a-line (with-current-buffer base (line-number-at-pos a-beg)))
           (b-line (with-current-buffer now (line-number-at-pos b-beg)))
           ;; A side with no line sits at the beginning of the line after
           ;; the difference, which for a deletion at the end of a file is
           ;; the separator of the next one.  The side that has lines is
           ;; the one that says which file this is.
           (section (if (string-empty-p b-text)
                        (ecc-review-ediff--section-at
                         ecc-review-ediff--sections a-line 1)
                      (ecc-review-ediff--section-at
                       ecc-review-ediff--sections b-line 2)))
           (a-start (max 1 (- a-line (nth 1 section))))
           (b-start (max 1 (- b-line (nth 2 section))))
           (a-count (seq-count (lambda (c) (eq c ?\n)) a-text))
           (b-count (seq-count (lambda (c) (eq c ?\n)) b-text))
           ;; A hunk of a patch: the @@ header is the line this hunk is
           ;; known by (`:header' below), and the markers are what the
           ;; comment is written against.
           (text (string-trim-right
                  (substring-no-properties
                   (let ((ecc-diff-style 'unified))
                     (ecc-diff-format-hunks
                      (ecc-diff-hunks (ecc-diff-lines a-text b-text)
                                      0 a-start b-start))))
                  "\n")))
      (list :path (car section)
            :start b-start
            :end (if (> b-count 0) (+ b-start b-count -1) b-start)
            :header (car (split-string text "\n"))
            :text text
            :position b-beg
            :number n
            :old-start a-start
            :old-end (if (> a-count 0) (+ a-start a-count -1) a-start)
            :old-count a-count
            ;; Where an empty old side sits: before the line it is
            ;; numbered with here, where git numbers the line before.
            :old-range (if (> a-count 0)
                           (cons a-start (+ a-start a-count -1))
                         (cons (- a-start 0.5) (- a-start 0.5)))
            :new-count b-count
            :a-beg a-beg :a-end a-end :b-beg b-beg :b-end b-end))))

(defun ecc-review-ediff--unit-lines (unit)
  "Return the lines of the difference UNIT, as `ecc-review--hunk-lines' does.
The first stands for the whole difference -- no side, at the place the
difference begins on the right -- and the rest are the lines it takes
out of the left, `old', and puts into the right, `new', each with
:buffer, the buffer it is in, and :position, where it starts there."
  (let* ((path (plist-get unit :path))
         (lines (list (list :position (plist-get unit :b-beg)
                            :buffer (cdr ecc-review-ediff--buffers)
                            :path path :side nil :line nil
                            :text (plist-get unit :header) :hunk unit))))
    (pcase-dolist (`(,side ,buffer ,beg ,end ,number)
                   (list (list 'old (car ecc-review-ediff--buffers)
                               (plist-get unit :a-beg) (plist-get unit :a-end)
                               (plist-get unit :old-start))
                         (list 'new (cdr ecc-review-ediff--buffers)
                               (plist-get unit :b-beg) (plist-get unit :b-end)
                               (plist-get unit :start))))
      (with-current-buffer buffer
        (save-excursion
          (goto-char beg)
          (while (< (point) end)
            (push (list :position (point) :buffer buffer :path path
                        :side side :line number
                        :text (buffer-substring-no-properties (point) (line-end-position))
                        :before nil :after nil :hunk unit)
                  lines)
            (cl-incf number)
            (unless (zerop (forward-line 1))
              (goto-char end))))))
    (setq lines (nreverse lines))
    (ecc-review--link-neighbours
     lines 'new (lambda (line) (eq (plist-get line :side) 'new)))
    (ecc-review--link-neighbours
     lines 'old (lambda (line) (eq (plist-get line :side) 'old)))
    lines))

(cl-defmethod ecc-review-units (&context (major-mode ediff-mode))
  "Return the differences of this ediff review as hunks, in order.
Counted from ediff's own vector of them rather than from
`ediff-number-of-differences\=', which ediff sets only after the
differences are in (`ecc-review-ediff--differences-computed\=')."
  (or ecc-review-ediff--units
      (setq ecc-review-ediff--units
            (let ((control (current-buffer)))
              (mapcar (lambda (n) (ecc-review-ediff--difference n control))
                      (number-sequence 0 (1- (length ediff-difference-vector-A))))))))

(cl-defmethod ecc-review-lines (&context (major-mode ediff-mode))
  "Return the lines of every difference of this ediff review."
  (mapcan #'ecc-review-ediff--unit-lines (ecc-review-units)))

(defun ecc-review-ediff--lines-of (count start end)
  "Return \"L3-L5\" for COUNT lines from START to END, \"none\" for none."
  (if (zerop count) "none" (format "L%d-L%d" start end)))

(cl-defmethod ecc-review-unit-description (hunk &context (major-mode ediff-mode))
  "Return how `review_hunks' describes the difference HUNK.
By ediff's own number, the one its mode line counts and j jumps to, and
the lines it covers on each side."
  (format "difference %d  old %s  new %s"
          (1+ (plist-get hunk :number))
          (ecc-review-ediff--lines-of (plist-get hunk :old-count)
                                      (plist-get hunk :old-start) (plist-get hunk :old-end))
          (ecc-review-ediff--lines-of (plist-get hunk :new-count)
                                      (plist-get hunk :start) (plist-get hunk :end))))

;;;; Where a comment is drawn

(defun ecc-review-ediff--separator-position (side path)
  "Return where the separator of PATH begins on SIDE, `A' or `B', or nil."
  (when-let* ((section (assoc path ecc-review-ediff--sections)))
    (with-current-buffer (if (eq side 'A) (car ecc-review-ediff--buffers)
                           (cdr ecc-review-ediff--buffers))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- (nth (if (eq side 'A) 1 2) section)))
        (point)))))

(cl-defmethod ecc-review--note-place (note line _lines &context (major-mode ediff-mode))
  "Return where NOTE, put on LINE, is drawn in an ediff review.
A comment on a line goes under the line, on the side the line is on:
the left for one the change took out, the right for one it put in.  A
comment on a whole difference goes under it on the right, where the
comments of a difference have always been.  An outdated one goes under
the separator of its file on the right, or at the very top when the
file has gone from the review.

The KEY is the order the comments are sorted, sent and walked in:
\(`ecc-review-ediff--key\=')."
  (let ((now (cdr ecc-review-ediff--buffers)))
    (cond
     ((and line (plist-get line :side))
      (let ((buffer (plist-get line :buffer))
            (beg (plist-get line :position)))
        (list buffer beg
              (with-current-buffer buffer
                (save-excursion (goto-char beg) (forward-line 1) (point)))
              'after-string
              (ecc-review-ediff--key line))))
     (line
      (let ((hunk (plist-get line :hunk)))
        (list now (plist-get hunk :b-end) (plist-get hunk :b-end) 'after-string
              (ecc-review-ediff--key line))))
     (t
      (if-let* ((beg (ecc-review-ediff--separator-position
                      'B (ecc-review-note-path note))))
          (list now beg (with-current-buffer now
                          (save-excursion (goto-char beg) (forward-line 1) (point)))
                'after-string (list beg 0 0))
        (let ((top (with-current-buffer now (point-min))))
          (list now top top 'before-string (list top 0 0))))))))

(defun ecc-review-ediff--key (line)
  "Return the place of LINE in the order of the review, as (POSITION RANK NUMBER).
POSITION is on the right: a line there is where it is, and a line on
the left -- or the whole of a difference -- is where its difference
begins there.  RANK puts the whole difference first, then the lines it
takes out, then those it puts in, and NUMBER is the number of the line:
every comment of a difference has a place of its own to be walked to
with \\`}' and sent in, not one shared by all those on the left."
  (let ((hunk (plist-get line :hunk)))
    (pcase (plist-get line :side)
      ('nil (list (plist-get hunk :b-beg) 0 0))
      ('old (list (plist-get hunk :b-beg) 1 (plist-get line :line)))
      (_ (list (plist-get line :position) 2 (plist-get line :line))))))

(cl-defmethod ecc-review--decorate (_commented _lines &context (major-mode ediff-mode))
  "Mark nothing: an ediff review has no @@ line to mark."
  nil)

;;;; Moving the view

(defvar-local ecc-review-ediff--at nil
  "(KEY . POINT): the comment or line the view was last moved to, and where
the right side was then.  The right side alone cannot tell apart the
comments on the left of one difference, which all begin at one place
there; while it has not moved since, KEY is where the review is read.")

(defun ecc-review-ediff--show-position (side position)
  "Put POSITION of SIDE, `A' or `B', a quarter of the way down its window.
The point of the buffer moves too, so that a side out of sight shows it
when it comes back; no window is selected."
  (let ((buffer (if (eq side 'A) ediff-buffer-A ediff-buffer-B))
        (window (if (eq side 'A) ediff-window-A ediff-window-B)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char position))
      (when (and (window-live-p window) (eq (window-buffer window) buffer))
        (set-window-point window position)
        (set-window-start window (ecc-review--window-start window position))))))

(cl-defmethod ecc-review-move-to (place _window &context (major-mode ediff-mode))
  "Move the ediff review to PLACE, a comment or a line, selecting no window.
ediff is put on the difference PLACE is in, the way j would put it there
but without laying the windows out again or handing the control panel
the keyboard -- which is what `ediff-jump-to-difference\\=' does, and
what Claude moving the view must not -- and the two sides are scrolled
to it: the line itself on its side, the beginning of the difference on
the other.  An outdated comment is shown under the separator of its
file."
  (let* ((line (if (ecc-review-note-p place)
                   (and (not (ecc-review-note-outdated place))
                        (ecc-review--locate-note place (ecc-review-lines)))
                 place))
         (hunk (and line (plist-get line :hunk))))
    (if (null hunk)
        (let ((path (and (ecc-review-note-p place) (ecc-review-note-path place))))
          (dolist (side '(A B))
            (ecc-review-ediff--show-position
             side (or (ecc-review-ediff--separator-position side path) 1))))
      (let ((n (plist-get hunk :number))
            (side (plist-get line :side)))
        (unless (eql n ediff-current-difference)
          (ediff-unselect-and-select-difference n nil 'no-recenter))
        (ecc-review-ediff--show-position
         'A (if (eq side 'old) (plist-get line :position) (plist-get hunk :a-beg)))
        (ecc-review-ediff--show-position
         'B (if (eq side 'new) (plist-get line :position) (plist-get hunk :b-beg)))))
    ;; Where this left the review, for the next comment to be found from.
    (setq ecc-review-ediff--at
          (cons (cond ((ecc-review-note-p place) (ecc-review-note-position place))
                      (line (ecc-review-ediff--key line)))
                (ecc-review-ediff--right-point)))))

(cl-defmethod ecc-review--note-removed (_note &context (major-mode ediff-mode))
  "Forget where the view was last moved: it may have been to that comment."
  (setq ecc-review-ediff--at nil))

(defun ecc-review-ediff--right-point ()
  "Return the point of the right side: of its window, else of its buffer."
  (if (and (window-live-p ediff-window-B)
           (eq (window-buffer ediff-window-B) ediff-buffer-B))
      (window-point ediff-window-B)
    (and (buffer-live-p ediff-buffer-B)
         (with-current-buffer ediff-buffer-B (point)))))

(cl-defmethod ecc-review-reading-position (_window &context (major-mode ediff-mode))
  "Return where the ediff review is being read, as a KEY of the review.
The comment or line it was last moved to, while the right side has not
moved since; otherwise just before the point of the right side, so that
the comments of the difference begun there are still ahead.  Before
any difference, the top."
  (let ((point (ecc-review-ediff--right-point)))
    (cond ((and ecc-review-ediff--at (car ecc-review-ediff--at)
                (eql (cdr ecc-review-ediff--at) point))
           (car ecc-review-ediff--at))
          (point (list point -1 0))
          ((ediff-valid-difference-p ediff-current-difference)
           (list (ediff-get-diff-posn 'B 'beg ediff-current-difference) -1 0))
          (t 0))))

(cl-defmethod ecc-review-shown-window (&context (major-mode ediff-mode))
  "Return the window on the right of this ediff review, when it is on the screen."
  (and (window-live-p ediff-window-B)
       (eq (window-buffer ediff-window-B) ediff-buffer-B)
       (frame-visible-p (window-frame ediff-window-B))
       ediff-window-B))

(cl-defmethod ecc-review-show-quietly (_session _others &context (major-mode ediff-mode))
  "Return the window of this ediff review, showing nothing that is not shown.
An ediff review lays out a frame of its own, and only the user opens one."
  (ecc-review-shown-window))

(cl-defmethod ecc-review-takes-the-screen-p (&context (major-mode ediff-mode))
  "Return t: an ediff review takes the frame and the keyboard when it opens."
  t)

;;;; Comments

(defun ecc-review-ediff--current-unit ()
  "Return the difference ediff is on, as a hunk, or signal that it is on none."
  (unless (and (boundp 'ediff-current-difference)
               (ediff-valid-difference-p ediff-current-difference))
    (user-error "Not on a difference"))
  (nth ediff-current-difference (ecc-review-units)))

(defun ecc-review-ediff--notes-in (unit)
  "Return the shown comments on the difference UNIT, in the order made.
Those on its lines and on the whole of it; an outdated comment is on no
difference."
  (let ((key (ecc-review--hunk-key unit)))
    (seq-filter (lambda (note)
                  (and (ecc-review--shown-p note)
                       (not (ecc-review-note-outdated note))
                       (equal (ecc-review-note-hunk-key note) key)))
                ecc-review--notes)))

(defun ecc-review-ediff--comment-choices (unit)
  "Return what \\`c' on the difference UNIT could do, the likeliest first.
A list of (KIND . NOTE): (reply . NOTE) for a comment of Claude\\='s there
you have not answered, (edit . NOTE) for a comment of yours on the whole
difference, and (nil) for a new comment.  The first is the reply when
the latest comment there is Claude\\='s and unanswered -- what Claude said
last is what is answered -- else the edit of your last own comment,
else a new one."
  (let* ((notes (ecc-review-ediff--notes-in unit))
         (answered (lambda (note)
                     (seq-some (lambda (other)
                                 (and (not (ecc-review--agent-p other))
                                      (eql (ecc-review-note-reply-to other)
                                           (ecc-review-note-id note))))
                               ecc-review--notes)))
         (replies (mapcar (lambda (note) (cons 'reply note))
                          (reverse (seq-filter (lambda (note)
                                                 (and (ecc-review--agent-p note)
                                                      (not (funcall answered note))))
                                               notes))))
         (edits (mapcar (lambda (note) (cons 'edit note))
                        (reverse (seq-filter (lambda (note)
                                               (and (not (ecc-review--agent-p note))
                                                    (null (ecc-review-note-reply-to note))
                                                    (null (ecc-review-note-side note))))
                                             notes))))
         (latest (car (last notes))))
    (append (if (and latest (eq (cdar replies) latest))
                (append replies edits)
              (append edits replies))
            (list (list nil)))))

(defun ecc-review-ediff--choice-label (choice)
  "Return how CHOICE of `ecc-review-ediff--comment-choices\\=' is offered."
  (pcase choice
    (`(reply . ,note) (format "reply to #%d: %s" (ecc-review-note-id note)
                              (ecc--truncate (ecc-review-note-text note) 50)))
    (`(edit . ,note) (format "edit #%d: %s" (ecc-review-note-id note)
                             (ecc--truncate (ecc-review-note-text note) 50)))
    (_ "new comment")))

(defun ecc-review-ediff--comment-plan (unit &optional choice)
  "Return what \\`c' on the difference UNIT is to do, as (ANCHOR KIND ID).
The answer of `ecc-review--comment-plan\\=', for a whole difference:
CHOICE, one of `ecc-review-ediff--comment-choices\\=' -- the first by
default -- with KIND `edit', `reply' or nil and ID the comment edited or
answered."
  (let ((choice (or choice (car (ecc-review-ediff--comment-choices unit)))))
    (list (ecc-review--anchor (ecc-review-note-create)
                              (car (ecc-review-ediff--unit-lines unit)))
          (car choice)
          (and (cdr choice) (ecc-review-note-id (cdr choice))))))

(defun ecc-review-ediff--read-choice (unit)
  "Ask which of the things \\`c' could do on UNIT is meant.
Whenever there is more than a new comment to choose -- a comment of
Claude\\='s to answer, one of yours to edit -- the choices are offered,
the likeliest of `ecc-review-ediff--comment-choices\\=' as the default,
so that RET takes it.  With nothing to answer or edit, nothing is asked."
  (let ((choices (ecc-review-ediff--comment-choices unit)))
    (if (null (cdr choices))
        (car choices)
      (let* ((labels (mapcar #'ecc-review-ediff--choice-label choices))
             (picked (completing-read "c: " labels nil t nil nil (car labels))))
        (nth (seq-position labels picked) choices)))))

(defun ecc-review-ediff-comment (text &optional plan)
  "Put the comment TEXT on the difference ediff is on.
The comment is about the whole difference: the keys of an ediff review
go to its control panel, which has no line of the files to stand on.
Where the latest comment of the difference is Claude\\='s and you have
not answered it, TEXT is your reply to it.  Otherwise, where the
difference carries a comment of yours on the whole of it, TEXT replaces
that one, and interactively it is offered for editing; else TEXT is a
new comment.  With more than one comment there to answer or edit,
which is asked.  Returns the comment.

PLAN is what `ecc-review-ediff--comment-plan\\=' decided when the command
was started, before the text was read: the review may be read again
while it is typed, and the comment goes to the difference it was meant
for, found again by what it says."
  (interactive
   (let* ((unit (ecc-review-ediff--current-unit))
          (plan (ecc-review-ediff--comment-plan
                 unit (ecc-review-ediff--read-choice unit)))
          (target (and (nth 2 plan) (ecc-review-find-note (nth 2 plan)))))
     (list (pcase (nth 1 plan)
             ('edit (read-string "Comment on this difference: "
                                 (ecc-review-note-text target)))
             ('reply (read-string (format "Reply to Claude's #%d: " (nth 2 plan))))
             (_ (read-string "Comment on this difference: ")))
           plan)))
  (pcase-let* ((`(,anchor ,kind ,id)
                (or plan (ecc-review-ediff--comment-plan (ecc-review-ediff--current-unit))))
               (text (string-trim text))
               (target (and id (ecc-review-find-note id)))
               (lines (ecc-review-lines))
               (line (ecc-review--locate-note anchor lines)))
    (when (string-empty-p text)
      (user-error "Empty comment"))
    (let ((note (if (and (eq kind 'edit) target)
                    (progn (setf (ecc-review-note-text target) text) target)
                  (ecc-review-add-note 'user text (or line anchor)
                                       (and (eq kind 'reply) target id)))))
      (ecc-review--draw-notes lines)
      (if (ecc-review-note-outdated note)
          (message "The difference has gone from the review; the comment is kept as outdated")
        (message "Comment attached (%d in all)"
                 (seq-count (lambda (note) (not (ecc-review--agent-p note)))
                            ecc-review--notes)))
      note)))

(defun ecc-review-ediff-remove-comment (&optional all)
  "Remove a comment of the difference ediff is on, whoever wrote it.
The outdated comments of its file are offered too, having no difference
of their own to be removed from.  When there is more than one, which
is asked.  With a prefix argument ALL, or off every difference, every
comment of the review is offered: an outdated one whose file has left
the review, or any in a review whose changes have all gone."
  (interactive "P")
  (let* ((unit (and (not all)
                    (boundp 'ediff-current-difference)
                    (ediff-valid-difference-p ediff-current-difference)
                    (ecc-review-ediff--current-unit)))
         (here (and unit
                    (append (ecc-review-ediff--notes-in unit)
                            (seq-filter (lambda (note)
                                          (and (ecc-review--shown-p note)
                                               (ecc-review-note-outdated note)
                                               (equal (ecc-review-note-path note)
                                                      (plist-get unit :path))))
                                        ecc-review--notes))))
         (note (ecc-review--pick-note
                (cond (here)
                      (unit (user-error "No comment on this difference; C-u d offers them all"))
                      ((ecc-review--ordered (seq-filter #'ecc-review--visible-p
                                                        ecc-review--notes)))
                      (t (user-error "No comment in this review")))
                "Remove comment: "
                (not here))))
    (ecc-review-remove-note note)
    (ecc-review--draw-notes)
    (message "Comment #%d removed (%d left)" (ecc-review-note-id note)
             (length ecc-review--notes))))

(defun ecc-review-ediff-list-comments ()
  "Pick one of the comments, either author's, and move to it."
  (interactive)
  (let ((notes (or (ecc-review--ordered (seq-filter #'ecc-review--visible-p
                                                    ecc-review--notes))
                   (user-error "No comment yet"))))
    (ecc-review-move-to (ecc-review--pick-note notes "Comment: ") nil)))

(defun ecc-review-ediff-next-comment ()
  "Move to the next comment of the review, to its difference and its line."
  (interactive)
  (ecc-review-move-to (or (ecc-review-note-beyond (ecc-review-reading-position nil) t)
                          (user-error "No comment below"))
                      nil))

(defun ecc-review-ediff-previous-comment ()
  "Move to the previous comment of the review, to its difference and its line."
  (interactive)
  (ecc-review-move-to (or (ecc-review-note-beyond (ecc-review-reading-position nil) nil)
                          (user-error "No comment above"))
                      nil))

(defun ecc-review-ediff-copy-refused ()
  "Say why `b\\=' does nothing in a review.
It is ediff\\='s copy of the right into the left, and both sides of a
review are read-only: a review reads, comments and sends, and what
changes the files is Claude, from the prompt the comments go out as.
Left to ediff it signalled `buffer-read-only\\=' against a buffer the
user had not asked about.  Its twin a is the review\\='s own, and shows
or hides Claude\\='s comments."
  (interactive)
  (message
   "A review reads; C-c C-c sends the comments and Claude makes the changes"))

;;;; The files pane and the filter

;; The ediff review's answers to what `ecc-review-files.el' asks of a
;; review.  A file is a section of both sides, from its separator line
;; to the next one; the filter hides both halves of it, and n, p and j
;; step over the differences in what it hides -- in this control buffer
;; alone, through `ediff-skip-diff-region-function', the way ediff's own
;; #h and #f skip theirs.

(defvar ecc-review-ediff-full-frame)

(cl-defmethod ecc-review-files-entries (&context (major-mode ediff-mode))
  "Return the files of this ediff review, one per section of the two sides.
The lines added and removed are those of its differences, which are
what the review shows; there are no renames, the review being made with
--no-renames."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (unit (ecc-review-units))
      (let ((count (or (gethash (plist-get unit :path) counts) (cons 0 0))))
        (puthash (plist-get unit :path)
                 (cons (+ (car count) (plist-get unit :new-count))
                       (+ (cdr count) (plist-get unit :old-count)))
                 counts)))
    (mapcar (lambda (section)
              (let ((count (gethash (car section) counts '(0 . 0))))
                (list :path (car section) :old-path nil
                      :status (or (nth 3 section) "M")
                      :added (car count) :removed (cdr count))))
            ecc-review-ediff--sections)))

(cl-defmethod ecc-review-files--key (&context (major-mode ediff-mode))
  "Return the sections and the differences of this review: what its files are."
  (list ecc-review-ediff--sections (ecc-review-units)))

(cl-defmethod ecc-review-files-current (&context (major-mode ediff-mode))
  "Return the file of the difference ediff is on, else of the right side's point."
  (if (ediff-valid-difference-p ediff-current-difference)
      (plist-get (nth ediff-current-difference (ecc-review-units)) :path)
    (when-let* ((point (and ecc-review-ediff--sections (ecc-review-ediff--right-point))))
      (car (ecc-review-ediff--file-place 'B point)))))

(defun ecc-review-ediff--give-the-control-panel-the-keyboard ()
  "Select the control panel of this review, and its frame when it has one."
  (when (window-live-p ediff-control-window)
    (select-window ediff-control-window)
    (when (and (display-graphic-p) (not (eq (window-frame ediff-control-window)
                                            (selected-frame))))
      (select-frame-set-input-focus (window-frame ediff-control-window)))))

(cl-defmethod ecc-review-files-goto (entry select &context (major-mode ediff-mode))
  "Put this review on the first difference of the file ENTRY.
A file with no difference -- one named and not shown -- is scrolled to
on both sides.  SELECT hands the control panel the keyboard."
  (let* ((path (plist-get entry :path))
         (unit (seq-find (lambda (unit) (equal (plist-get unit :path) path))
                         (ecc-review-units))))
    (if unit
        (ecc-review-move-to (car (ecc-review-ediff--unit-lines unit)) nil)
      (dolist (side '(A B))
        (ecc-review-ediff--show-position
         side (or (ecc-review-ediff--separator-position side path) 1))))
    (ecc-review-files--follow)
    (when select
      (ecc-review-ediff--give-the-control-panel-the-keyboard))))

(defun ecc-review-ediff--section-bounds (side path)
  "Return (BEG . END), where the file PATH runs on SIDE, `A' or `B'."
  (let* ((beg (ecc-review-ediff--separator-position side path))
         (next (cadr (member (assoc path ecc-review-ediff--sections)
                             ecc-review-ediff--sections))))
    (cons beg (or (and next (ecc-review-ediff--separator-position side (car next)))
                  (with-current-buffer (if (eq side 'A) (car ecc-review-ediff--buffers)
                                         (cdr ecc-review-ediff--buffers))
                    (point-max))))))

(cl-defmethod ecc-review-files-hide (entries &context (major-mode ediff-mode))
  "Hide both halves of the files ENTRIES of this ediff review, and no other.
The overlays live in the two sides and are kept here, in the control
buffer."
  (mapc #'delete-overlay ecc-review-files--hiders)
  (setq ecc-review-files--hiders nil)
  (dolist (side '(A B))
    (let ((buffer (if (eq side 'A) (car ecc-review-ediff--buffers)
                    (cdr ecc-review-ediff--buffers))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ecc-review-files--spec entries))
        (dolist (entry entries)
          (pcase-let ((`(,beg . ,end) (ecc-review-ediff--section-bounds
                                       side (plist-get entry :path))))
            (when beg
              (let ((overlay (make-overlay beg end buffer t nil)))
                (overlay-put overlay 'invisible 'ecc-review-filter)
                (overlay-put overlay 'evaporate t)
                (push overlay ecc-review-files--hiders)))))))))

(cl-defmethod ecc-review-files-review-window (&context (major-mode ediff-mode))
  "Return the left window of this ediff review, which the pane goes beside."
  (and (window-live-p ediff-window-A)
       (eq (window-buffer ediff-window-A) ediff-buffer-A)
       ediff-window-A))

(cl-defmethod ecc-review-files-place-pane (pane &context (major-mode ediff-mode))
  "Show PANE left of this ediff review, and return its window.
With the frame the review's own (`ecc-review-ediff-full-frame\\=') the
pane is a side window on the left, which ediff laying its windows out
again -- | and m -- leaves where it is, and which goes when the windows
of before the review are put back.  Otherwise it is split off the left
of the left side, and put back by `ecc-review-ediff--keep-the-pane'
whenever ediff lays the windows out again."
  (when-let* ((window (ecc-review-files-review-window)))
    (let ((left
           (if ecc-review-ediff-full-frame
               (with-selected-window window
                 (display-buffer-in-side-window
                  pane `((side . left) (slot . 0)
                         (window-width . ,ecc-review-files-width)
                         (preserve-size . (t . nil))
                         (dedicated . t)
                         (window-parameters . ((no-other-window . t)
                                               (no-delete-other-windows . t))))))
             ;; Nil, and no pane, when the left side is too narrow.
             (when-let* ((left (ecc-review-files--split window)))
               (set-window-buffer left pane)
               (set-window-dedicated-p left t)
               (set-window-parameter left 'no-other-window t)
               left))))
      (when (window-live-p left)
        (set-window-parameter left 'ecc-review-files t))
      left)))

(defun ecc-review-ediff--keep-the-pane ()
  "Show the files pane again after ediff laid out the windows, when it is wanted.
On `ediff-after-setup-windows-hook\\=' of the control buffer: a pane
split off the left side is deleted with the rest of the windows."
  (when (and ecc-review-files-shown
             (buffer-live-p ecc-review-files--pane)
             (not (ecc-review-files--pane-window (current-buffer))))
    (ecc-review-files--show (current-buffer))))

(defun ecc-review-ediff--leave-the-pane ()
  "Take the selection out of the files pane before ediff lays out the windows.
On `ediff-before-setup-windows-hook\\=' of the control buffer: ediff
deletes every other window from the one it finds selected, and a side
window cannot be the only one."
  (when-let* ((pane (ecc-review-files--pane-window (current-buffer)))
              (frame (window-frame pane))
              ((eq (frame-selected-window frame) pane))
              (other (seq-find (lambda (window) (not (eq window pane)))
                               (window-list frame 'no-minibuffer))))
    (if (eq (selected-window) pane)
        (select-window other)
      (set-frame-selected-window frame other))))

(defvar-local ecc-review-ediff--hidden-vector nil
  "(UNITS HIDDEN . VECTOR): which differences the filter hides, by number.
VECTOR is a bool-vector made for the differences UNITS and the files
HIDDEN, and made again when either is another list: a key that steps
over hidden differences asks about each of them, and asking the list
of differences every time cost the square of their number.")

(defun ecc-review-ediff--hidden-difference-p (n)
  "Return non-nil when the filter of this review hides difference N."
  (and ecc-review--hidden
       (ediff-valid-difference-p n)
       (let ((units (ecc-review-units)))
         (unless (and ecc-review-ediff--hidden-vector
                      (eq (car ecc-review-ediff--hidden-vector) units)
                      (eq (cadr ecc-review-ediff--hidden-vector) ecc-review--hidden))
           (let ((vector (make-bool-vector (length units) nil))
                 (index 0))
             (dolist (unit units)
               (aset vector index (ecc-review-hidden-p (plist-get unit :path)))
               (cl-incf index))
             (setq ecc-review-ediff--hidden-vector
                   (cons units (cons ecc-review--hidden vector)))))
         (let ((vector (cddr ecc-review-ediff--hidden-vector)))
           (and (< n (length vector)) (aref vector n))))))

(defun ecc-review-ediff--shown-differences-from (from to)
  "Return the differences from FROM to TO, both included, the filter keeps."
  (and (<= from to)
       (seq-remove #'ecc-review-ediff--hidden-difference-p (number-sequence from to))))

(defun ecc-review-ediff--move (move arg forward)
  "Call MOVE, ediff's next or previous difference, ARG differences, FORWARD or not.
The differences the filter hides are skipped as ediff skips those #h
hides, and signal that there is none left when every one is hidden."
  (if (null ecc-review--hidden)
      (funcall move arg)
    (unless (if forward
                (ecc-review-ediff--shown-differences-from
                 (1+ ediff-current-difference) (1- ediff-number-of-differences))
              (ecc-review-ediff--shown-differences-from 0 (1- ediff-current-difference)))
      (user-error (if forward
                      "No difference below in the files the filter keeps"
                    "No difference above in the files the filter keeps")))
    (let* ((skip ediff-skip-diff-region-function)
           (ediff-skip-diff-region-function
            (lambda (n) (or (ecc-review-ediff--hidden-difference-p n) (funcall skip n)))))
      (funcall move arg))))

(defun ecc-review-ediff-next-difference (&optional arg)
  "Go to the next difference, ARG of them, past those the filter hides."
  (interactive "p")
  (ecc-review-ediff--move #'ediff-next-difference arg t))

(defun ecc-review-ediff-previous-difference (&optional arg)
  "Go to the previous difference, ARG of them, past those the filter hides."
  (interactive "p")
  (ecc-review-ediff--move #'ediff-previous-difference arg nil))

(defun ecc-review-ediff--nearest-shown-difference (n)
  "Return the difference nearest N that the filter keeps, or nil for none.
The first one kept at N or after it, else the last one kept before it,
as `ecc-review-files--nearest-shown' finds a file.  Nil when the filter
keeps no difference at all; what that means is the caller's to say."
  (or (car (ecc-review-ediff--shown-differences-from
            (max 0 n) (1- ediff-number-of-differences)))
      (car (last (ecc-review-ediff--shown-differences-from
                  0 (min n (1- ediff-number-of-differences)))))))

(defun ecc-review-ediff-jump-to-difference-at-point (arg)
  "Go to the difference at point of a side, as ediff's ga and gb do.
When the filter hides it, to the nearest one it keeps, each side keeping
the point ga or gb gave it where that is not hidden; when it keeps none,
back to where the review was, and that is said.  ARG is ediff's."
  (interactive "P")
  (let ((was ediff-current-difference))
    (funcall-interactively #'ediff-jump-to-difference-at-point arg)
    (when (ecc-review-ediff--hidden-difference-p ediff-current-difference)
      (let ((target (ecc-review-ediff--nearest-shown-difference ediff-current-difference))
            (points (mapcar (lambda (window)
                              (and (window-live-p window) (window-point window)))
                            (list ediff-window-A ediff-window-B))))
        (unless target
          (ediff-unselect-and-select-difference was)
          (user-error "Every difference is in a file the filter hides"))
        (ediff-unselect-and-select-difference target)
        (cl-mapc (lambda (window point)
                   (when (and point (window-live-p window)
                              (not (with-current-buffer (window-buffer window)
                                     (invisible-p point))))
                     (set-window-point window point)))
                 (list ediff-window-A ediff-window-B) points)))))

(defun ecc-review-ediff-jump-to-difference (number)
  "Go to the difference NUMBER, as ediff's j does.
When the filter hides it, to the nearest one it keeps
\(`ecc-review-ediff--nearest-shown-difference'), and that is said."
  (interactive "p")
  (let ((n (cond ((< number 0) (+ ediff-number-of-differences number))
                 ((> number 0) (1- number))
                 (t -1))))
    (if (not (ecc-review-ediff--hidden-difference-p n))
        (ediff-jump-to-difference number)
      (let ((target (or (ecc-review-ediff--nearest-shown-difference n)
                        (user-error "Every difference is in a file the filter hides"))))
        (ediff-jump-to-difference (1+ target))
        (message "Difference %d is in a file the filter hides; this is %d"
                 (1+ n) (1+ target))))))

(defun ecc-review-ediff--write-help ()
  "Write the help of the control panel again, laying no window out.
What `ediff-setup-control-buffer\=' writes, without its fitting of the
window and its selecting of it."
  (let ((inhibit-read-only t)
        (control (current-buffer))
        (window (and (window-live-p ediff-control-window) ediff-control-window)))
    (erase-buffer)
    (ediff-set-help-message)
    (insert ediff-help-message)
    ;; It centres the help on the width of the selected window, which
    ;; here is seldom the panel.
    (unless (ediff-multiframe-setup-p)
      (if window
          (with-selected-window window
            (with-current-buffer control
              (ediff-indent-help-message)))
        (ediff-indent-help-message)))
    (ediff-set-help-overlays)
    (goto-char (point-min))
    (set-buffer-modified-p nil)))

(cl-defmethod ecc-review-files-filter-applied (&context (major-mode ediff-mode)
                                                        &optional quietly)
  "Move this review off a difference the filter now hides, and say what it hides.
The brief help carries the filter, so the control panel is written again.
QUIETLY -- a drawing no key of the user's asked for -- selects the
difference without recentring, which would lay the windows out again
and hand the panel the keyboard, and writes the help in place when what
is hidden `changed'; `unchanged' leaves it.  A key of the user's
recentres, which fits the panel to its new help."
  (when (ecc-review-ediff--hidden-difference-p ediff-current-difference)
    ;; With none kept, on no difference at all.
    (ediff-unselect-and-select-difference
     (or (ecc-review-ediff--nearest-shown-difference ediff-current-difference) -1)
     nil 'no-recenter))
  (cond
   ((eq quietly 'unchanged))
   (quietly
      (ecc-review-ediff--write-help))
   (t
    (setq ediff-window-config-saved "")
    (ecc-review-ediff--leave-the-pane)
    (ediff-recenter 'no-rehighlight))))

(cl-defmethod ecc-review-files-give-keyboard (&context (major-mode ediff-mode))
  "Give the control panel of this ediff review the keyboard, where its keys are."
  (ecc-review-ediff--give-the-control-panel-the-keyboard))

;;;; The help ? shows

;; ediff's own help is written for the ediff a two-way comparison
;; usually is: it offers a and b, rx, wx and wd and ~, none of which do
;; anything here -- both buffers are read-only and the two sides are
;; every file of the review at once -- and it says nothing of the
;; comment keys, C-c C-c and C-c C-k, or that q closes a review without
;; asking.  The layout below is ediff's, so that ? still looks like
;; ediff's help, with only the commands this review really has on it.

(defconst ecc-review-ediff-long-help-message
  "    Move around      |      Toggle features      |          Comments
=====================|===========================|=============================
p,DEL -previous diff |     | -vert/horiz split   |      c -comment on this diff
    n,SPC -next diff |         h -highlighting   |     d -remove a comment here
     j -jump to diff |      @ -auto-refinement   |  { } -previous, next comment
       C-l -recenter |        * -refine region   |         l -list the comments
   v/V -scroll up/dn |   ## -ignore whitespace   |     a -show or hide Claude's
   </> -scroll lt/rt |         #c -ignore case   |   C-c C-c -send the comments
  s -list the files  |         m -wide display   |     C-c C-k -drop the review
 / -filter the files |                           |          q -close the review
=====================|===========================|=============================
    i -status info   |     ? -help off           |      ! -read the files again
-------------------------------------------------------------------------------
  T -ask Claude for a tour of the review       t -the next stop of the tour
  M -say something to Claude                   y -answer what Claude asks
-------------------------------------------------------------------------------
Both buffers are read-only: a review reads, comments and sends, and writes
nothing.  Claude changes the files, from the prompt the comments are sent as."
  "What `?\\=' shows in the control panel of an ediff review.")

(defconst ecc-review-ediff-brief-help-message
  " n/p diff   c comment   { } comments   a Claude's   s files   / filter
 T tour   t next   M message   C-c C-c send   q quit   ! reread   ? all keys"
  "What the control panel of an ediff review says with the help off.
Two lines, so that the keys a review is read with are in sight without
\\`?'; a filter in force adds a third (`ecc-review-ediff--brief-help-message').")

(defun ecc-review-ediff--long-help-message ()
  "Return the long help of an ediff review.
This is what `ediff-long-help-message-function\\=' is set to."
  ecc-review-ediff-long-help-message)

(defun ecc-review-ediff--brief-help-message ()
  "Return the brief help of an ediff review, and the filter in force.
This is what `ediff-brief-help-message-function\\=' is set to; it is
read in the control buffer of the review."
  (concat ecc-review-ediff-brief-help-message
          (when ecc-review--filter
            (format "\n /%s: %s hidden by filter" ecc-review--filter
                    (ecc-review--count (length ecc-review--hidden) "file")))))

;;;; Opening and closing

(defvar ecc-review-ediff-progress-regexp
  "\\`\\(?:Buffer [A-C]: \\)?Processing difference region\\|\\`Computing differences"
  "The messages ediff writes as it computes the differences of a review.
\"Processing difference region N of M\" comes once every ten
differences, and each message is drawn at once: a review of a thousand
differences was a hundred redisplays of the echo area while it opened
\(2026-10-01).  They are not shown while a review is built or read again
\(`ecc-review-ediff--quietly'), and still go to *Messages*.")

(defun ecc-review-ediff--quiet-filter (next)
  "Return a `set-message-function' that drops ediff's progress, NEXT the rest.
A message matching `ecc-review-ediff-progress-regexp' is not shown;
any other goes to NEXT, the function that was there, and is shown the
way it would have been."
  (lambda (message)
    (cond ((string-match-p ecc-review-ediff-progress-regexp message) t)
          (next (funcall next message)))))

(defmacro ecc-review-ediff--quietly (&rest body)
  "Run BODY without showing ediff's progress messages.
Only those: an error, a question or anything else said meanwhile is
shown as ever (`ecc-review-ediff--quiet-filter')."
  (declare (indent 0) (debug t))
  `(let ((set-message-function (ecc-review-ediff--quiet-filter set-message-function)))
     ,@body))

(defvar ecc-review-ediff-full-frame t
  "Non-nil gives the review the whole frame it opens in.
Two texts side by side want the width: sharing the frame with the
sidebar and a transcript or two leaves each side too narrow to read a
line of code in.  The windows that were there are put back when the
review is quit, the same way the rest of the arrangement is.

Nil opens the review among whatever is on the screen, which is what
`ediff-buffers\=' would do on its own.")

(defun ecc-review-ediff--take-the-frame ()
  "Leave one window in this frame, for the review to be laid out in.
Side windows are taken down too -- a sidebar beside a two-column diff
is the width that was wanted for the code -- and come back with the
rest when the review is quit.  A frame that will not give up its
windows is left as it is rather than made an error of."
  (when-let* ((window (seq-find (lambda (window)
                                  (not (window-parameter window 'window-side)))
                                (window-list nil 'no-minibuffer))))
    (select-window window)
    (condition-case nil
        (let ((ignore-window-parameters t))
          (delete-other-windows window))
      (error nil))))

(defun ecc-review-ediff--on-quit ()
  "Take the review down: ediff's own cleanup, the buffers, the windows.
Run from `ediff-quit-hook\\=' in the control buffer, which
`ediff-cleanup-mess\\=' then kills, so what is needed afterwards is read
first."
  (let ((buffers ecc-review-ediff--buffers)
        (windows ecc-review-ediff--windows)
        (frame ecc-review-ediff--frame))
    (dolist (timer (list ecc-review-ediff--colour-timer ecc-review-ediff--refine-timer))
      (when (timerp timer)
        (cancel-timer timer)))
    ;; The buffers files were being fontified in.
    (mapc #'ecc-review-ediff--drop-jobs (ecc-review-ediff--sides))
    (ecc-review-ediff--kill-work-buffers)
    (ediff-cleanup-mess)
    (dolist (buffer (list (car buffers) (cdr buffers)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (when (window-configuration-p windows)
      (set-window-configuration windows))
    (ecc-review-ediff--take-the-keyboard frame)))

(defun ecc-review-ediff--take-the-keyboard (frame)
  "Give FRAME the input focus again, now that the review is closed.
On a graphical Emacs the control panel is a frame of its own, and it is
the frame that holds the keyboard while the review is being read.
`ediff-cleanup-mess\\=' deletes it and selects the frame the two sides
were shown in, but it selects it within Emacs only: the window system is
never told, so no frame is the one it considers focused.  A frame that
is not focused draws its cursor the way a window that is not selected
does -- and where `cursor-in-non-selected-windows\\=' is nil, that is no
cursor at all.  Quitting a review left an Emacs with the cursor gone
everywhere until something was clicked (reported 2026-09-18; plain
`ediff-buffers\\=' does it too).

Nothing is taken from the control panel by this: it is called after
`ediff-cleanup-mess\\=' has deleted the panel, and there is no
session left to drive."
  (when (and (frame-live-p frame)
             (display-graphic-p frame))
    (select-frame-set-input-focus frame)))

(defun ecc-review-ediff-quit (control)
  "Quit the ediff review in CONTROL, which closes it and its buffers.
This is what `ecc-review--close-function\\=' is set to: a review that
laid out its own windows puts them back rather than being killed."
  (when (buffer-live-p control)
    (with-current-buffer control
      (ediff-really-quit nil))))

(defun ecc-review-ediff--state (hash)
  "Return what this review is filled with, its fingerprint, for HASH.
HASH names the two trees compared (`ecc-review-ediff--content\='); the
ticks of the two sides say that nothing else wrote into them, and the
count of the differences that ediff has not computed them otherwise
since -- with `##' or `#c', say."
  (append (list hash (length ediff-difference-vector-A))
          (ecc-review-ediff--ticks)))

(defun ecc-review-ediff--ticks ()
  "Return the `buffer-chars-modified-tick' of the two sides of this review."
  (mapcar (lambda (buffer)
            (and (buffer-live-p buffer)
                 (with-current-buffer buffer (buffer-chars-modified-tick))))
          (ecc-review-ediff--sides)))

(defun ecc-review-ediff-open (session base now sections &optional range root paths
                                      hash cache)
  "Compare BASE and NOW as the review of SESSION and return the control buffer.
SECTIONS says where each file begins, and RANGE what a working tree
review is against.  ROOT is the repository and PATHS, relative to it,
the files the review was restricted to: what the review is read again
from as the files change.  HASH names the trees BASE and NOW were
filled from, and CACHE is what was read and coloured for them
\(`ecc-review-ediff--cache\=').  `ecc-window-hide-on-review\\=' is honoured before
ediff lays out its windows; quitting puts back what was on the screen."
  (ecc-window-hide-for-review session)
  (let ((windows (current-window-configuration))
        (frame (selected-frame))
        (control nil))
    (when ecc-review-ediff-full-frame
      (ecc-review-ediff--take-the-frame))
    (ecc-review-ediff--quietly
      (ediff-buffers
       base now
       (list
	(lambda ()
          (setq control (current-buffer))
          (setq-local ecc-review--session session
                      ecc-render--session session
                      ecc-review--range range
                      ecc-review--paths paths
                      ecc-review--notes nil
                      ecc-review--next-id 1
                      ecc-review--stale nil
                      ecc-review--failed nil
                      ecc-review-ediff--sections sections
                      ecc-review-ediff--units nil
                      ecc-review-ediff--cache cache
                      ecc-review-ediff--buffers (cons base now)
                      ecc-review-ediff--windows windows
                      ecc-review-ediff--frame frame
                      ecc-review--close-function #'ecc-review-ediff-quit
                      ediff-quit-hook (list #'ecc-review-ediff--on-quit))
          ;; The repository: a file saved under it is a change to follow.
          (when root
            (setq default-directory (file-name-as-directory root)))
          (setq-local ecc-review--fingerprint (ecc-review-ediff--state hash))
          ;; ediff computes the differences again by itself -- `##', `#c'
          ;; and `!' of a plain ediff go through `ediff-update-diffs' -- and
          ;; then the hunks and the comments drawn on them are about
          ;; differences it no longer has.  The function it computes them
          ;; with is local to this control buffer, so it is wrapped here
          ;; and no other ediff is touched.
          (setq-local ediff-setup-diff-regions-function
                      (let ((compute ediff-setup-diff-regions-function))
			(lambda (&rest args)
                          (prog1 (apply compute args)
                            (ecc-review-ediff--differences-computed)))))
          ;; A window coming to show either side is the review coming into
          ;; view, which is when a stale one is read again.
          (dolist (buffer (list base now))
            (with-current-buffer buffer
              (setq-local ecc-review--part-of control)))
          ;; The bar beside the current difference, and then the same
          ;; function for the difference the review opens on: ediff has
          ;; selected it before these hooks run.
          (add-hook 'ediff-select-hook #'ecc-review-ediff--mark-current nil t)
          ;; Both of these are read out of the control buffer of this
          ;; session as well (`ediff-defvar-local'), so no other ediff's ?
          ;; changes.
          (setq-local ediff-long-help-message-function
                      #'ecc-review-ediff--long-help-message
                      ediff-brief-help-message-function
                      #'ecc-review-ediff--brief-help-message)
          ;; ediff reads this one out of the control buffer of each session
          ;; (`ediff-wind.el'), which is why the review can be laid out its
          ;; own way without touching how the user's other ediffs look.
          (when ecc-review-ediff-split-window-function
            (setq-local ediff-split-window-function
			ecc-review-ediff-split-window-function))
          ;; `ediff-setup' lays out the windows and writes the help into
          ;; the panel before it runs these hooks, so both are done again
          ;; here: the review would otherwise open in ediff's own layout,
          ;; under ediff's own help, and turn into this one at the first
          ;; command that recentres.  It is the call `ediff-toggle-split'
          ;; and `ediff-toggle-help' both make for the same reason.
          (ediff-recenter)
          ;; `ediff-mode-map' is local to this control buffer, so these
          ;; keys reach no other ediff session.  c, d, l, {, } and ! are
          ;; the ones the diff review has; ediff has none of the first
          ;; five, and ! is its own "compute the differences again", which
          ;; for a review is reading the files again.
          (define-key ediff-mode-map (kbd "c") #'ecc-review-ediff-comment)
          (define-key ediff-mode-map (kbd "d") #'ecc-review-ediff-remove-comment)
          (define-key ediff-mode-map (kbd "l") #'ecc-review-ediff-list-comments)
          (define-key ediff-mode-map (kbd "{") #'ecc-review-ediff-previous-comment)
          (define-key ediff-mode-map (kbd "}") #'ecc-review-ediff-next-comment)
          (define-key ediff-mode-map (kbd "!") #'ecc-review-refresh)
          (define-key ediff-mode-map (kbd "C-c C-c") #'ecc-review-send)
          (define-key ediff-mode-map (kbd "C-c C-k") #'ecc-review-quit)
          ;; ediff's own q asks whether to quit this session, and the
          ;; question goes to a minibuffer the control frame does not have
          ;; -- on a graphical Emacs the panel is a frame of its own, small
          ;; enough to show nothing, so q read as a key that did nothing at
          ;; all (reported 2026-09-16).  A review is closed, not saved:
          ;; there is nothing to lose by the question and nothing to ask.
          (define-key ediff-mode-map (kbd "q") #'ecc-review-quit)
          ;; mouse-2 and RET over a line of the help look the command up
          ;; in the ediff manual, which knows nothing of c, d or l and
          ;; answers them with "Undocumented command!".  Silenced rather
          ;; than pointed somewhere else: what the ECC keys do is on the
          ;; help itself, and the manual has nothing to add about the
          ;; ediff ones that a review uses.
          (define-key ediff-mode-map [mouse-2] #'ignore)
          (define-key ediff-mode-map (kbd "RET") #'ignore)
          ;; ediff's own copy commands.  Both sides of a review are
          ;; read-only, so they could only fail, and they failed as
          ;; `ediff-copy-diff: buffer-read-only' -- an error about a
          ;; buffer the user never asked about, from a key the help does
          ;; not offer.  a is the diff review's own key for showing and
          ;; hiding Claude's comments, and b says what a review is.
          (define-key ediff-mode-map (kbd "a") #'ecc-review-toggle-agent)
          (define-key ediff-mode-map (kbd "b") #'ecc-review-ediff-copy-refused)
          ;; The files pane and the filter.  ediff binds s and / in a
          ;; merge alone -- the size of the merge window, the ancestor --
          ;; and a review is never a merge (checked 2026-10-01).  n, p
          ;; and j step over what the filter hides.
          (define-key ediff-mode-map (kbd "s") #'ecc-review-files-toggle)
          (define-key ediff-mode-map (kbd "/") #'ecc-review-files-filter)
          ;; Talking to the session, whose prompt the review hides, and
          ;; answering it from here (`ecc-review-talk.el').  ediff binds
          ;; none of T, t and y, and M only to the meta buffer of its
          ;; sessions, which has nothing to show for a review (checked
          ;; 2026-10-02).
          (define-key ediff-mode-map (kbd "T") #'ecc-review-talk-tour)
          (define-key ediff-mode-map (kbd "t") #'ecc-review-talk-next)
          (define-key ediff-mode-map (kbd "M") #'ecc-review-talk-message)
          (define-key ediff-mode-map (kbd "y") #'ecc-review-talk-answer)
          ;; Remapped rather than rebound, so that every key ediff gives
          ;; them -- SPC, DEL, <backspace>, <delete>, S-SPC, ga, gb -- is
          ;; covered.
          (define-key ediff-mode-map [remap ediff-next-difference]
                      #'ecc-review-ediff-next-difference)
          (define-key ediff-mode-map [remap ediff-previous-difference]
                      #'ecc-review-ediff-previous-difference)
          (define-key ediff-mode-map [remap ediff-jump-to-difference]
                      #'ecc-review-ediff-jump-to-difference)
          (define-key ediff-mode-map [remap ediff-jump-to-difference-at-point]
                      #'ecc-review-ediff-jump-to-difference-at-point)
          (add-hook 'ediff-select-hook #'ecc-review-files--follow nil t)
          (add-hook 'ediff-before-setup-windows-hook #'ecc-review-ediff--leave-the-pane nil t)
          (add-hook 'ediff-after-setup-windows-hook #'ecc-review-ediff--keep-the-pane nil t)
          (ecc-review-ediff--mark-current)
          ;; What is on the screen is coloured before the review is
          ;; shown, the rest after it (`ecc-review-ediff--colour-later'),
          ;; and the differences shown are refined as they come into view.
          (add-hook 'ediff-select-hook #'ecc-review-ediff--refine-later nil t)
          (add-hook 'ediff-unselect-hook #'ecc-review-ediff--keep-refined nil t)
          (define-key ediff-mode-map (kbd "@") #'ecc-review-ediff-toggle-autorefine)
          (define-key ediff-mode-map (kbd "h") #'ecc-review-ediff-toggle-hilit)
          (dolist (buffer (list base now))
            (with-current-buffer buffer
              (add-hook 'window-scroll-functions #'ecc-review-ediff--scrolled nil t)))
          (ecc-review-ediff--after-write)
          (run-hook-with-args 'ecc-review-displayed-functions control)))))
    control))

(defvar ecc-review-ediff--replacing nil
  "Non-nil while a review is being read again in place.
`ecc-review-ediff--replace\=' draws the comments itself, once the
difference being read is found again; the redraw after ediff computes
the differences would only draw them twice.")

(defun ecc-review-ediff--differences-computed ()
  "Forget the hunks of this review and draw its comments on the new ones.
Run whenever ediff has computed the differences, by whatever command.
ediff counts them only after this returns, and reads the count to say
whether a difference exists, so it is counted here first."
  (setq ecc-review-ediff--units nil
        ecc-review-ediff--at nil
        ecc-review-ediff--refined nil
        ediff-number-of-differences (length ediff-difference-vector-A))
  (unless ecc-review-ediff--replacing
    (ecc-review--draw-notes))
  ;; What ediff refined is gone with the differences it was in.
  (ecc-review-ediff--refine-later))

(defun ecc-review-ediff--content (session range root paths &optional base)
  "Return what an ediff review of SESSION against RANGE would compare.
The plist of `ecc-review--target\=' -- the repository, the paths, the
name and what to say when nothing changed, the same as the diff review
of the same thing -- with :left and :right, the two trees compared, and
:hash, which names them and the paths.  RANGE nil is everything SESSION
changed since it started, against the baseline `ecc-review\=' uses;
otherwise it is what `ecc-review-ediff--trees\=' takes.  Nothing is read
but the two trees: the files are read only once they are known to have
changed.  BASE is what relative PATHS are relative to, as in
`ecc-review--target\='; a review read again gives its repository, since
the paths it keeps are relative to that."
  (let* ((target (ecc-review--target session range root paths base))
         (range (plist-get target :range))
         (paths (plist-get target :paths))
         (root (or (plist-get target :root)
                   (user-error "%s is not in a git repository"
                               (abbreviate-file-name
                                (or (ecc-session-project-root session)
                                    default-directory)))))
         (trees (if range
                    (ecc-review-ediff--trees root range)
                  (cons (or (ecc-session-baseline session)
                            (ecc-review--head-tree root)
                            (user-error "Cannot read the history of %s"
                                        (abbreviate-file-name root)))
                        (or (ecc-review-snapshot root)
                            (user-error "Cannot read the working tree of %s"
                                        (abbreviate-file-name root)))))))
    (append (list :left (car trees) :right (cdr trees)
                  ;; With the settings that decide what is shown of
                  ;; them, so that \`!' after changing one shows it.
                  :hash (secure-hash 'sha1 (prin1-to-string
                                            (list (car trees) (cdr trees) paths
                                                  ecc-review-max-bytes
                                                  ecc-review-ediff-fontify))))
            target)))

(defun ecc-review-ediff--pairs-of (content cache)
  "Return the pairs of CONTENT, read through CACHE."
  (ecc-review-ediff-pairs (plist-get content :root) (plist-get content :left)
                          (plist-get content :right) (plist-get content :paths)
                          cache))

(defun ecc-review-ediff--start (session content)
  "Open the review of SESSION that CONTENT describes.
Return the control buffer.  CONTENT is what `ecc-review-ediff--content\='
read.  With nothing to compare that is a `user-error\=', and nothing is
opened."
  (let* ((cache (make-hash-table :test #'equal))
         (pairs (ecc-review-ediff--pairs-of content cache)))
    (unless pairs
      (user-error "%s" (plist-get content :nothing)))
    (pcase-let ((`(,a ,b ,sections)
                 (ecc-review-ediff--build session pairs (plist-get content :range) cache
                                          (plist-get content :label))))
      (let ((control (ecc-review-ediff-open session a b sections (plist-get content :range)
                                            (plist-get content :root) (plist-get content :paths)
                                            (plist-get content :hash) cache)))
        (when (buffer-live-p control)
          (with-current-buffer control
            (setq ecc-review--label (plist-get content :label))))
        control))))

(defun ecc-review-ediff-buffer (session &optional paths)
  "Open everything SESSION changed as one ediff and return the control buffer.
PATHS restricts it to those files.  This is `ecc-review-buffer\\=' laid
out side by side: the same baseline, the same working tree snapshot and
the same errors."
  (ecc-review-ediff--start session (ecc-review-ediff--content session nil nil paths)))

(defun ecc-review-ediff-worktree-buffer (session &optional range root paths)
  "Open the working tree of ROOT as one ediff and return the control buffer.
The comments go to SESSION.  RANGE defaults to
`ecc-review-worktree-default-range\\=', and PATHS restrict it to those
files.  This is `ecc-review-worktree-buffer\\=' laid out side by side."
  (ecc-review-ediff--start
   session (ecc-review-ediff--content
            session (or range ecc-review-worktree-default-range) root paths)))

;;;; Following the files

;; An ediff review follows the files the way the diff review does
;; (`ecc-review-auto-refresh'), on the same signals and the same one
;; timer: a stale review on the screen is read again into the same two
;; buffers, and ediff is made to compute its differences again.  Not
;; with `ediff-update-diffs', which recentres -- lays the windows out
;; again and, on a graphical Emacs, hands the control panel the keyboard
;; -- from wherever the user is typing.  The steps it takes in between
;; are taken here instead, and the windows are left where they are.
;;
;; What is kept is the difference being read, found again the way a
;; comment on it would be, and where each side is: the line of its file
;; that its window has its point on, moved by as many lines as the
;; difference being read moved in that file -- a change above it pushes
;; it down, and the view goes with it -- and as many lines from the top
;; of the window as it was.

(defun ecc-review-ediff--file-place (side position)
  "Return (PATH . OFFSET) for POSITION on SIDE, `A' or `B', or nil.
OFFSET is how many lines below the separator of PATH the position is."
  (let* ((buffer (if (eq side 'A) (car ecc-review-ediff--buffers)
                   (cdr ecc-review-ediff--buffers)))
         (index (if (eq side 'A) 1 2))
         (line (with-current-buffer buffer (line-number-at-pos position)))
         (section (ecc-review-ediff--section-at ecc-review-ediff--sections line index)))
    (and section (>= line (nth index section))
         (cons (car section) (- line (nth index section))))))

(defun ecc-review-ediff--file-position (side place)
  "Return the position of SIDE that PLACE, a (PATH . OFFSET), names, or nil."
  (when-let* ((beg (and place (ecc-review-ediff--separator-position side (car place)))))
    (with-current-buffer (if (eq side 'A) (car ecc-review-ediff--buffers)
                           (cdr ecc-review-ediff--buffers))
      (save-excursion
        (goto-char beg)
        (forward-line (cdr place))
        (point)))))

(defun ecc-review-ediff--save-views ()
  "Return where the two sides of this review are read, for after a refresh.
A list of (SIDE WINDOW PLACE LINES-FROM-TOP), WINDOW nil for the point
of the buffer itself."
  (let ((views nil))
    (dolist (side '(A B))
      (let ((buffer (if (eq side 'A) ediff-buffer-A ediff-buffer-B))
            (window (if (eq side 'A) ediff-window-A ediff-window-B)))
        (push (list side nil
                    (ecc-review-ediff--file-place side (with-current-buffer buffer (point)))
                    0)
              views)
        (when (and (window-live-p window) (eq (window-buffer window) buffer))
          (push (list side window
                      (ecc-review-ediff--file-place side (window-point window))
                      (with-current-buffer buffer
                        (count-lines (window-start window)
                                     (save-excursion
                                       (goto-char (window-point window))
                                       (line-beginning-position)))))
                views))))
    views))

(defun ecc-review-ediff--restore-views (views shifts)
  "Put the VIEWS of `ecc-review-ediff--save-views\\=' back.
SHIFTS is an alist of each side to (PATH . LINES): how far the
difference being read moved in PATH on that side, which a view of PATH
moves by too.  A place whose file has gone is left at the top."
  (pcase-dolist (`(,side ,window ,place ,from-top) views)
    (let* ((buffer (if (eq side 'A) ediff-buffer-A ediff-buffer-B))
           (shift (alist-get side shifts))
           (place (if (and place shift (equal (car place) (car shift)))
                      (cons (car place) (max 0 (+ (cdr place) (cdr shift))))
                    place))
           (position (or (ecc-review-ediff--file-position side place)
                         (with-current-buffer buffer (point-min)))))
      (if (null window)
          (with-current-buffer buffer (goto-char position))
        (when (and (window-live-p window) (eq (window-buffer window) buffer))
          (set-window-point window position)
          (set-window-start window (with-current-buffer buffer
                                     (save-excursion
                                       (goto-char position)
                                       (forward-line (- from-top))
                                       (point)))))))))

(defun ecc-review-ediff--compute-differences ()
  "Have ediff compute the differences of the two sides of this review again.
The steps of `ediff-update-diffs\\=' without its recentring: the two
buffers are written out, diffed, and the differences put back as ediff
keeps them.  None is selected afterwards."
  (dolist (overlay (append ediff-wide-bounds ediff-narrow-bounds))
    ;; The bounds of the comparison spanned the old text; the erase left
    ;; them empty at the top.
    (when (and (overlayp overlay) (buffer-live-p (overlay-buffer overlay)))
      (with-current-buffer (overlay-buffer overlay)
        (move-overlay overlay (point-min) (point-max)))))
  (let ((file-A (ediff-make-temp-file ediff-buffer-A))
        (file-B (ediff-make-temp-file ediff-buffer-B)))
    (unwind-protect
        (progn
          (ediff-clear-diff-vector 'ediff-difference-vector-A 'fine-diffs-also)
          (ediff-clear-diff-vector 'ediff-difference-vector-B 'fine-diffs-also)
          (setq ediff-killed-diffs-alist nil)
          (funcall ediff-setup-diff-regions-function file-A file-B nil)
          (setq ediff-number-of-differences (length ediff-difference-vector-A)))
      (delete-file file-A)
      (delete-file file-B))))

(defun ecc-review-ediff--reread (&optional _watching)
  "Read this ediff review again, keeping its comments and its place.
Read the way it was opened, from what it remembers.  A review whose two
trees are the ones it was filled from is left alone, without a file
being read; one whose changes have all gone stays open and says so, as
the diff review does when it follows the files -- an ediff review is
never closed by being read."
  (let* ((content (ecc-review-ediff--content ecc-review--session ecc-review--range
                                             default-directory ecc-review--paths
                                             default-directory))
         (hash (plist-get content :hash)))
    (setq ecc-review--label (plist-get content :label))
    (if (equal ecc-review--fingerprint (ecc-review-ediff--state hash))
        (progn (setq ecc-review--stale nil
                     ecc-review--failed nil)
               (current-buffer))
      (unless ecc-review-ediff--cache
        (setq ecc-review-ediff--cache (make-hash-table :test #'equal)))
      (let ((pairs (ecc-review-ediff--pairs-of content ecc-review-ediff--cache)))
        (prog1 (ecc-review-ediff--replace pairs (plist-get content :nothing) hash)
          (ecc-review-ediff--prune ecc-review-ediff--cache pairs))))))

(defun ecc-review-ediff--starts (n)
  "Return where difference N begins on each side, as ((A PATH . OFFSET) (B ...)).
Nil when N is no difference."
  (when (ediff-valid-difference-p n)
    (mapcar (lambda (side)
              (cons side (ecc-review-ediff--file-place
                          side (ediff-get-diff-posn side 'beg n))))
            '(A B))))

(defun ecc-review-ediff--replace (pairs nothing hash)
  "Put PAIRS into the two sides of this review in place of what they hold.
NOTHING is what to say when there is no pair, and HASH the fingerprint
of PAIRS.  The comments are put back, each where its line is now, and
so are the difference being read and the place of each side."
  (let* ((placed (seq-remove #'ecc-review-note-outdated ecc-review--notes))
         (current (and (ediff-valid-difference-p ediff-current-difference)
                       (ecc-review--anchor
                        (ecc-review-note-create)
                        (car (ecc-review-ediff--unit-lines
                              (nth ediff-current-difference (ecc-review-units)))))))
         (views (ecc-review-ediff--save-views))
         (starts (ecc-review-ediff--starts ediff-current-difference)))
    ;; Off the difference being read first, while its overlays are
    ;; still where ediff put them.
    (ediff-unselect-and-select-difference -1 nil 'no-recenter)
    (ecc-review-ediff--unmark-current)
    (setq ecc-review-ediff--sections
          (ecc-review-ediff--write ediff-buffer-A ediff-buffer-B pairs nothing
                                   ecc-review-ediff--cache)
          ecc-review-ediff--units nil)
    ;; The layout the view was last moved in is gone with the text.
    (setq ecc-review-ediff--at nil)
    (let ((ecc-review-ediff--replacing t))
      (ecc-review-ediff--quietly
        (ecc-review-ediff--compute-differences)))
    (let* ((lines (ecc-review-lines))
           (found (and current (ecc-review--locate-note current lines)))
           (n (and found (plist-get (plist-get found :hunk) :number))))
      (let ((ecc-review--refilling t))
        (ecc-review--draw-notes lines))
      (ecc-review-ediff--restore-views
       views
       (and n starts
            (cl-mapcar (lambda (before after)
                         (and (cdr before) (cdr after) (equal (cadr before) (cadr after))
                              (cons (car before)
                                    (cons (cadr before) (- (cddr after) (cddr before))))))
                       starts (ecc-review-ediff--starts n))))
      ;; The difference that was read, else the one the right side is
      ;; on now.
      (unless (or n (null current) (zerop ediff-number-of-differences))
        ;; `ediff-diff-at-point' counts from 1, as j does.
        (setq n (min (1- ediff-number-of-differences)
                     (max 0 (1- (ediff-diff-at-point
                                 'B (ecc-review-ediff--right-point)))))))
      (when n
        (ediff-unselect-and-select-difference n nil 'no-recenter)))
    ;; The files that changed went in plain.
    (ecc-review-ediff--after-write)
    (ediff-refresh-mode-lines)
    (setq ecc-review--fingerprint (ecc-review-ediff--state hash)
          ecc-review--stale nil
          ecc-review--failed nil)
    (run-hooks 'ecc-review-refilled-hook)
    (let ((lost (seq-count #'ecc-review-note-outdated placed)))
      (when (> lost 0)
        (message "%s no longer %s a difference of the review; kept as outdated"
                 (ecc-review--count lost "comment") (if (= lost 1) "is on" "are on"))))
    (current-buffer)))

(cl-defmethod ecc-review-reread (&context (major-mode ediff-mode) &optional watching)
  "Read this ediff review again (`ecc-review-ediff--reread\\=')."
  (ecc-review-ediff--reread watching))

(provide 'ecc-review-ediff)

;;; ecc-review-ediff.el ends here
