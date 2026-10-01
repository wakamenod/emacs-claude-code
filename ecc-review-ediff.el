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
;; major mode as it is inserted, and the differences are marked in the
;; colours the diff review uses, because ediff's own faces for the
;; differences it is not standing on are invisible under a good many
;; themes.  The one being read is then told apart from them twice over:
;; a stronger shade of its own colour, and a bar in the fringe beside
;; every line of it, because under a theme that paints the current
;; difference in the very colours a diff is read by the shade alone
;; says nothing.
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

(defun ecc-review-ediff--blob-text (root blob cache)
  "Return the text of BLOB in ROOT, nil for no blob.
CACHE, a hash table or nil, keeps what was read under (raw . BLOB): a
blob is the same text for as long as it exists, so a file that did not
change since the review was last read is not read again.  A blob git
will not give is logged and signalled: taken for nothing, it would read
as a file created or deleted."
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
of (PATH BEFORE AFTER NOTE BEFORE-BLOB AFTER-BLOB) in the order git
reports, where BEFORE and AFTER are what the two trees hold, the BLOBs
their ids, and NOTE, when non-nil, says why neither is there: a file git
calls binary, one too large for `ecc-review-max-bytes\\=', a submodule,
or one git would not give is named and not shown.  Both sides being
empty, such a file is no difference at all
and only its separator line is read, which is where the note is put.
CACHE is that of `ecc-review-ediff--blob-text\\='."
  (let ((blobs (ecc-review-ediff--blobs root left right paths))
        (pairs nil))
    (pcase-dolist (`(,path . ,binary) (ecc-review--numstat root left right paths))
      (pcase-let* ((`(,before-id ,after-id ,before-mode ,after-mode)
                    (cdr (assoc path blobs)))
                   (submodule (member "160000" (list before-mode after-mode)))
                   (failed nil)
                   (`(,before . ,after)
                    (unless (or binary submodule)
                      (condition-case error
                          (cons (ecc-review-ediff--blob-text root before-id cache)
                                (ecc-review-ediff--blob-text root after-id cache))
                        (error (setq failed (error-message-string error))
                               nil))))
                   (size (max (string-bytes (or before "")) (string-bytes (or after ""))))
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
                    (and (not note) after-id))
              pairs)))
    (nreverse pairs)))

(defun ecc-review-ediff--prune (cache pairs)
  "Keep in CACHE only what the blobs of PAIRS need."
  (when cache
    (let ((wanted (make-hash-table :test #'equal)))
      (pcase-dolist (`(,_ ,_ ,_ ,_ ,before ,after) pairs)
        (when before (puthash before t wanted))
        (when after (puthash after t wanted)))
      (maphash (lambda (key _)
                 (unless (gethash (if (eq (car key) 'raw) (cdr key) (cadr key)) wanted)
                   (remhash key cache)))
               cache))))

;;;; The two buffers

(defvar-local ecc-review-ediff--sections nil
  "Where each file begins, as (PATH BASE-LINE NOW-LINE).
The lines are those of the separator line in the two buffers, in the
order the files were written out.  Buffer-local in the ediff control
buffer.")

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

(defun ecc-review-ediff--fontify (text path)
  "Return TEXT with the faces the major mode of PATH would give it.
Mode hooks are not run: a file of the review is read, never edited, and
a hook that starts a language server or asks a question has no business
in a buffer that exists to be diffed.  Anything the mode raises leaves
the text as it came."
  (if (or (not ecc-review-ediff-fontify) (null text) (string-empty-p text))
      text
    (condition-case nil
        (with-temp-buffer
          (insert text)
          (let ((buffer-file-name (expand-file-name path))
                (enable-local-variables nil)
                (inhibit-message t))
            (delay-mode-hooks (set-auto-mode)))
          ;; `font-lock-ensure' does nothing where font-lock is off, and
          ;; a batch Emacs has it off.
          (font-lock-mode 1)
          (font-lock-ensure)
          (buffer-string))
      (error text))))

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
  "Append SEPARATOR and TEXT to BUFFER and return the line of SEPARATOR.
`ecc-review-ediff-file-spacing\=' blank lines go in front of it unless
BUFFER is still empty.  TEXT is given a closing newline when it lacks
one, so that what follows starts a line of its own."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (= (point-min) (point-max))
        (insert (make-string (max 0 ecc-review-ediff-file-spacing) ?\n)))
      (prog1 (line-number-at-pos (point))
        ;; No font-lock in a buffer of this package: the face goes on
        ;; the text as it is inserted.
        (insert (propertize separator 'face 'ecc-heading-face) "\n")
        (unless (string-empty-p text)
          (insert text)
          (unless (bolp) (insert "\n")))))))

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
light one -- in bold.  The refinement inside the difference keeps
`ediff-fine-diff-A\=' and `-B\=', so what changed within the line is
still marked apart.  See also `ecc-review-ediff-current-diff-mark\='.")

(defvar ecc-review-ediff-current-diff-step 5
  "How far the colour of the current difference is carried, in lightness.
Five points of HSL lightness away from the background the theme gave
the difference: about half the step modus-vivendi itself puts between
`ediff-current-diff-A\=' and `ediff-fine-diff-A\='.  The colour is the
second answer to the question of which difference this is and not the
first -- the bar in the fringe is not a shade to compare, so what the
colour has to do is hold the eye where the bar has already sent it,
which a deeper shade of the same colour does without shouting.")

(defun ecc-review-ediff--stronger (face)
  "Return the attributes of FACE with its background carried a shade further.
Away from the background of the frame: lighter on a dark one, darker on
a light one.  A face with no background of its own, and a background
this display cannot name, are left to the bold alone."
  (let ((background (face-attribute face :background nil t)))
    (append (when (and (stringp background) (color-defined-p background))
              (list :background
                    (if (eq (frame-parameter nil 'background-mode) 'dark)
                        (color-lighten-name
                         background ecc-review-ediff-current-diff-step)
                      (color-darken-name
                       background ecc-review-ediff-current-diff-step))))
            (list :weight 'bold :extend t))))

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
       'ediff-current-diff-B (ecc-review-ediff--stronger 'ediff-current-diff-B)))))

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

(defun ecc-review-ediff--write (base now pairs nothing &optional cache)
  "Write PAIRS into the buffers BASE and NOW afresh and return the sections.
With no pair at all both say NOTHING, the same on both sides, so that
the review shows no difference and says why.  Nothing but the text is
touched: the major mode, the local variables ediff keeps in the two
buffers and the colours stay, which is what lets a review that is open
be read again into the same buffers.  CACHE keeps the fontified text
of each blob (`ecc-review-ediff--cache\='), so that a file that did not
change is not fontified again."
  (let ((sections nil))
    (dolist (buffer (list base now))
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
      (pcase-dolist (`(,path ,before ,after ,note ,before-blob ,after-blob) pairs)
        (let ((separator (ecc-review-ediff--separator path note)))
          (push (list path
                      (ecc-review-ediff--insert
                       base separator
                       (ecc-review-ediff--coloured before path before-blob cache))
                      (ecc-review-ediff--insert
                       now separator
                       (ecc-review-ediff--coloured after path after-blob cache)))
                sections))))
    (dolist (buffer (list base now))
      (with-current-buffer buffer
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)))
    (nreverse sections)))

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
                      ((ecc-review--ordered (seq-filter #'ecc-review--shown-p
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
  (let ((notes (or (ecc-review--ordered (seq-filter #'ecc-review--shown-p
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
                     |         m -wide display   |     C-c C-k -drop the review
                     |                           |          q -close the review
=====================|===========================|=============================
    i -status info   |     ? -help off           |      ! -read the files again
-------------------------------------------------------------------------------
Both buffers are read-only: a review reads, comments and sends, and writes
nothing.  Claude changes the files, from the prompt the comments are sent as."
  "What `?\\=' shows in the control panel of an ediff review.")

(defconst ecc-review-ediff-brief-help-message
  " c -comment   C-c C-c -send   q -quit   ? -help"
  "What the control panel of an ediff review says with the help off.")

(defun ecc-review-ediff--long-help-message ()
  "Return the long help of an ediff review.
This is what `ediff-long-help-message-function\\=' is set to."
  ecc-review-ediff-long-help-message)

(defun ecc-review-ediff--brief-help-message ()
  "Return the brief help of an ediff review.
This is what `ediff-brief-help-message-function\\=' is set to."
  ecc-review-ediff-brief-help-message)

;;;; Opening and closing

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
          (list (car ecc-review-ediff--buffers) (cdr ecc-review-ediff--buffers))))

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
        (ecc-review-ediff--mark-current))))
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
        ediff-number-of-differences (length ediff-difference-vector-A))
  (unless ecc-review-ediff--replacing
    (ecc-review--draw-notes)))

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
      (ecc-review-ediff--compute-differences))
    (let* ((lines (ecc-review-lines))
           (found (and current (ecc-review--locate-note current lines)))
           (n (and found (plist-get (plist-get found :hunk) :number))))
      (ecc-review--draw-notes lines)
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
    (ediff-refresh-mode-lines)
    (setq ecc-review--fingerprint (ecc-review-ediff--state hash)
          ecc-review--stale nil
          ecc-review--failed nil)
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
