;;; ecc-review.el --- Reviewing what Claude changed, hunk by hunk  -*- lexical-binding: t; -*-

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

;; The main way of working the requirements describe: let Claude change
;; things, then open every change of the session as one diff, walk the
;; hunks, attach a comment to the ones that need work and send all the
;; comments as a single prompt.
;;
;; `ecc-review' and `ecc-review-range' are the same review against
;; different bases: the first against what the working tree held when
;; the session started (`ecc-git-ensure-baseline'), so the commits
;; made during it are still shown; the second against HEAD by default,
;; so only what is uncommitted is.  Neither asks how a file was
;; changed -- an edit, a shell command and a script all read alike --
;; because both compare trees rather than replaying what the CLI
;; reported doing.  Outside a git repository there is no tree to
;; compare, and only there is a file still diffed against what it was
;; before the first change of the session (`ecc-file-entry-original').
;; The buffer is a read-only `diff-mode', so n, p and RET are the
;; usual ones.
;;
;; A comment is on a line -- the old side of a removed one, the new side
;; of any other -- or on a whole hunk from its @@ header.  Comments are
;; kept as `ecc-review-note's apart from the text, and every reading of
;; the diff carries each to where its line went
;; (`ecc-review--take-reading'), so lines put in or taken out above one
;; move it rather than losing it; one whose line changed or went is kept
;; and marked outdated.
;; Claude writes comments into the same buffer over MCP
;; (`ecc-review-agent.el'), drawn in a face of their own; only the
;; user's are sent.
;;
;; An open review follows the files (`ecc-review-auto-refresh'): what
;; the session does and what is saved marks it stale, and it is read
;; again, the comments put back, once the user stops typing and it is
;; on the screen.
;;
;; The same buffer reviews one proposal before it is applied: a comment
;; on the diff of a pending Edit or Write goes back as the message of
;; the deny, and `ecc-review-edit-proposal' changes the text of the
;; proposal and allows it with the new text.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'diff-mode)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-git)
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-review-map)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-window)
(require 'ecc-lifecycle)

(autoload 'ecc-review-files-toggle "ecc-review-files" nil t)
(autoload 'ecc-review-files-filter "ecc-review-files" nil t)
(autoload 'ecc-review-talk-tour "ecc-review-talk" nil t)
(autoload 'ecc-review-talk-next "ecc-review-talk" nil t)
(autoload 'ecc-review-talk-message "ecc-review-talk" nil t)
(autoload 'ecc-review-pr-next-commit "ecc-review-pr" nil t)
(autoload 'ecc-review-pr-previous-commit "ecc-review-pr" nil t)
(autoload 'ecc-review-pr-send-all "ecc-review-pr" nil t)
(declare-function ecc-review-pr-walk-status "ecc-review-pr" (&optional subject))
(declare-function ecc-review-ediff-buffer "ecc-review-ediff" (session &optional paths))
(declare-function ecc-review-ediff-range-buffer "ecc-review-ediff"
                  (session &optional range root paths))

(defcustom ecc-review-style 'diff
  "How `ecc-review\=' and `ecc-review-range\=' show what changed.
`diff' is one read-only unified diff of every file, the hunks walked
with n and p.  `ediff' lays the files out side by side instead -- what
they held on the left, what they hold now on the right, every file of
the review in one ediff session -- and n and p walk the differences
across the file boundaries.  Both are read-only, both comment with c,
and both send the same prompt.

The review of one proposal waiting to be allowed is a diff either way:
it is one change to allow or refuse, not a tree to read through."
  :type '(choice (const :tag "One diff-mode buffer" diff)
                 (const :tag "ediff, every file in one session" ediff))
  :group 'ecc)

(defvar ecc-review-header
  "Review comments on the changes below.  Please act on each of them."
  "First line of the prompt the review comments are sent as.")

(defvar ecc-review-elsewhere-note
  "These changes are %s.  Their right side, %s, is not checked out here, so the lines below are not in the files of the working tree.  Ask before editing anything for them, and do not check anything out yourself."
  "Second line of the prompt of a review whose right side is not on disk.
Formatted with what the review is called and the revision on its right
\(`ecc-review-elsewhere').")

(defvar ecc-review-proposal-header
  "Review comments on the proposal below.  Please act on each of them and propose it again."
  "First line of the deny message built from comments on a proposal.")

(defvar ecc-review-context-lines 0
  "Lines of context around a change in the diffs of a review.
It is passed to git as -U and used by the diffs the review builds
itself, so the two read alike.  It is an argument of the git the review
runs and nothing else: no `git config\=' is read or written, and the git
of a terminal is unaffected.

0, the default, makes every run of changed lines a hunk of its own,
which is the granularity a review comment wants: a comment carries the
hunk it sits on, and lines nobody meant to talk about only blur what is
being asked for.  Raise it to read a change in its surroundings.

The review of one proposal has `ecc-review-proposal-context-lines\=' of
its own.")

(defvar ecc-review-proposal-context-lines 3
  "Lines of context in the diff of a proposal waiting to be allowed.
The question there is not the one a working tree review asks.  A hunk
is something to comment on; a proposal is something to allow or refuse,
and what it is about to overwrite is half of that judgement, so the
lines around the change stay.")

(defface ecc-review-comment-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face of a comment shown under the hunk it belongs to."
  :group 'ecc)

(defface ecc-review-agent-comment-face
  '((t :inherit font-lock-doc-face :slant italic))
  "Face of a comment Claude put on the review.
Inherited, like `ecc-review-comment-face\=', so that the theme decides
the colour and the two authors never read alike."
  :group 'ecc)

(defface ecc-review-sent-comment-face
  '((t :inherit (ecc-dim-face ecc-review-comment-face)))
  "Face of a comment of yours a prompt has carried to Claude already.
Dimmed, so that what is still to be sent stands out; it stays in the
review for Claude\='s replies."
  :group 'ecc)

(defface ecc-review-commented-hunk-face
  '((t :inherit diff-hunk-header :weight bold))
  "Face of the header of a hunk that carries a comment."
  :group 'ecc)

;;;; Which files

(defun ecc-review-files (session &optional paths)
  "Return the file entries of SESSION that were edited or written.
When PATHS is given only those files are returned, in the order of
PATHS; each is absolute or relative to the project of SESSION, and is
compared with the entries the way the two name the same file.  Entries
only read are left out."
  (let ((changed (seq-filter (lambda (entry)
                               (> (+ (ecc-file-entry-edits entry)
                                     (ecc-file-entry-writes entry))
                                  0))
                             (ecc-model-files session))))
    (if paths
        (let ((directory (or (ecc-session-project-root session) default-directory)))
          (delq nil (mapcar (lambda (path)
                              (let ((path (expand-file-name path directory)))
                                (seq-find (lambda (entry)
                                            (equal (expand-file-name
                                                    (ecc-file-entry-path entry) directory)
                                                   path))
                                          changed)))
                            paths)))
      changed)))

;;;; Git

(defvar ecc-review--diff-command '("-c" "core.quotePath=false" "diff")
  "How a review runs git's diff: with the names of files as they are.
git C-quotes a path with a byte past ASCII by default -- the octal
escapes of its UTF-8 between double quotes -- and the review would show
that and look for a file of that name.")

(defvar ecc-review--diff-options
  '("--no-color" "--no-ext-diff" "--no-textconv" "--inter-hunk-context=0"
    "--src-prefix=a/" "--dst-prefix=b/" "--full-index")
  "What every diff a review reads is made with, whatever the user's git says.
The review parses what git prints, so the settings that change it are
put back: `color.diff' and `diff.external' would write something else; a
textconv driver in .gitattributes would show a file as other lines than
its blobs have, which the diff of two blobs that carries the comments
counts; `diff.interHunkContext' would fuse two hunks with the unchanged
lines between them, which then read as changed; and `diff.noprefix' or
`diff.mnemonicPrefix' would name the files without the a/ and b/ the
review takes off.  The index lines name the blobs whole, so that two
readings of one blob say so with the same id; the review shows them
short (`ecc-review--shorten-ids').")

(defvar ecc-review-shown-id-length 7
  "How many characters of a blob id an index line of the review shows.
git's own short form.  The whole id stays on the line, as the text
property `ecc-review-blob' (`ecc-review--shorten-ids').")

(defun ecc-review--git-unquote (text start)
  "Return (NAME . END) for the name git C-quoted at START of TEXT, or nil.
NAME is the name decoded and END where the quote closed.  git quotes a
name with a tab, a newline, a double quote or a backslash in it, even
with `core.quotePath' off: between double quotes, with \\t, \\n,
\\\" and \\\\, and any other byte it escapes in octal, which are
the bytes of UTF-8."
  (when (and (< start (length text)) (eq (aref text start) ?\"))
    (let ((i (1+ start))
          (n (length text))
          (pieces nil)
          (bytes nil)
          (end nil))
      (cl-flet ((flush ()
                  (when bytes
                    (push (decode-coding-string (apply #'unibyte-string (nreverse bytes)) 'utf-8)
                          pieces)
                    (setq bytes nil))))
        (while (and (< i n) (not end))
          (let ((char (aref text i)))
            (cond
             ((eq char ?\") (setq end (1+ i)))
             ((and (eq char ?\\) (< (1+ i) n))
              (let ((next (aref text (1+ i))))
                (if (and (<= ?0 next ?7) (<= (+ i 4) n)
                         (string-match-p "\\`[0-7]\\{3\\}\\'" (substring text (1+ i) (+ i 4))))
                    (progn (push (string-to-number (substring text (1+ i) (+ i 4)) 8) bytes)
                           (setq i (+ i 4)))
                  (flush)
                  (push (string (pcase next (?a ?\a) (?b ?\b) (?t ?\t) (?n ?\n) (?v ?\v)
                                       (?f ?\f) (?r ?\r) (_ next)))
                        pieces)
                  (setq i (+ i 2)))))
             (t (flush)
                (push (string char) pieces)
                (setq i (1+ i))))))
        (flush))
      (and end (cons (apply #'concat (nreverse pieces)) end)))))

(defun ecc-review--git-quote-char (char)
  "Return how git writes CHAR in a C-quoted name, or nil when it is itself.
git's rule (quote.c, with `core.quotePath' off): a control character,
DEL, a double quote and a backslash are escaped; those with a letter of
their own by it, the others as three octal digits."
  (pcase char
    (?\a "\\a") (?\b "\\b") (?\t "\\t") (?\n "\\n") (?\v "\\v") (?\f "\\f")
    (?\r "\\r") (?\" "\\\"") (?\\ "\\\\")
    ((pred (lambda (char) (or (< char 32) (= char 127)))) (format "\\%03o" char))))

(defun ecc-review--git-quote (name)
  "Return NAME as git writes it in a diff header, C-quoted when it has to be.
For the headers the review writes itself, which are read back like
git's (`ecc-review-git-name'): a name with a character git escapes in
it (`ecc-review--git-quote-char') goes between double quotes; any other
is itself, as git writes it with `core.quotePath' off."
  (if (not (seq-some #'ecc-review--git-quote-char name))
      name
    (concat "\""
            (mapconcat (lambda (char) (or (ecc-review--git-quote-char char) (string char)))
                       name "")
            "\"")))

(defun ecc-review-git-name (text)
  "Return the file name TEXT, what follows ---, +++ or rename to in a diff, says.
A name git C-quoted is decoded (`ecc-review--git-unquote'); a bare one
runs to the tab git puts after a name with a space in it."
  (or (car (ecc-review--git-unquote text 0))
      (car (split-string text "\t"))))

(defun ecc-review-git-diff-names (line &optional old new)
  "Return (A . B), the names the diff --git LINE gives the two sides, or nil.
Each with its prefix, as git wrote it, a C-quoted one decoded.  Two bare
names are split where the line can only split: with OLD and NEW, the
names a rename or a copy gives on its own header lines, into a/PREFIX
OLD and b/PREFIX NEW for one PREFIX; without them, into two names alike
but for a/ and b/.  Nil when the line splits neither way."
  (when (string-prefix-p "diff --git " line)
    (let* ((rest (substring line (length "diff --git ")))
           (size (length rest)))
      (cond
       ((ecc-review--git-unquote rest 0)
        (pcase-let ((`(,a . ,end) (ecc-review--git-unquote rest 0)))
          (and (< end size) (eq (aref rest end) ?\s)
               (cons a (ecc-review-git-name (substring rest (1+ end)))))))
       ;; A bare name, then a quoted one: the quote that runs to the end.
       ((string-suffix-p "\"" rest)
        (catch 'split
          (let ((at 0))
            (while (setq at (string-search " \"" rest at))
              (pcase (ecc-review--git-unquote rest (1+ at))
                (`(,b . ,(pred (= size))) (throw 'split (cons (substring rest 0 at) b))))
              (setq at (1+ at))))))
       ((and old new)
        (let ((twice (- size (length old) (length new) 5)))
          (when (and (>= twice 0) (cl-evenp twice))
            (let* ((a (substring rest 0 (+ 2 (/ twice 2) (length old))))
                   (b (substring rest (min size (1+ (length a))))))
              (and (string-prefix-p "a/" a) (string-suffix-p old a)
                   (string-prefix-p " b/" (substring rest (length a)))
                   (string-suffix-p new b)
                   (equal (substring a 2 (- (length a) (length old)))
                          (substring b 2 (- (length b) (length new))))
                   (cons a b))))))
       ((cl-oddp size)
        (let ((a (substring rest 0 (/ size 2)))
              (b (substring rest (1+ (/ size 2)))))
          (and (eq (aref rest (/ size 2)) ?\s)
               (string-prefix-p "a/" a) (string-prefix-p "b/" b)
               (equal (substring a 2) (substring b 2))
               (cons a b))))))))

(defun ecc-review--git-string (directory &rest args)
  "Return what git ARGS in DIRECTORY print, trimmed.
Nil when git fails or prints nothing."
  (pcase (apply #'ecc-git-run directory args)
    (`(0 . ,output)
     (let ((text (string-trim output)))
       (and (not (string-empty-p text)) text)))))

(defun ecc-review--merge-base (root left right)
  "Return the commit where LEFT and RIGHT part in ROOT, or nil."
  (ecc-review--git-string root "merge-base" left right))

(defun ecc-review--relative (path root)
  "Return PATH relative to the repository ROOT, through symbolic links.
git reports its root with links resolved, so the directory of PATH is
resolved too -- the directory and not the file: a symbolic link git
tracks is a file of its own, and resolving it would name its target, or
a path outside the repository."
  (let ((path (expand-file-name path)))
    (file-relative-name (expand-file-name (file-name-nondirectory path)
                                          (file-truename (file-name-directory path)))
                        root)))

(defun ecc-review-git-tracked (root paths)
  "Return the members of PATHS that git tracks in the repository at ROOT.
PATHS are absolute; the result keeps their order."
  (pcase (apply #'ecc-git-run root "ls-files" "-z" "--"
                (mapcar (lambda (path) (ecc-review--relative path root)) paths))
    (`(0 . ,output)
     (let ((tracked (split-string output "\0" t)))
       (seq-filter (lambda (path)
                     (member (ecc-review--relative path root) tracked))
                   paths)))))

(defun ecc-review-git-diff (root paths &optional range under)
  "Return the unified diff git reports for PATHS under ROOT, or nil.
PATHS may be nil, which diffs everything under ROOT.  RANGE is what to
diff against -- a revision like \"HEAD\" or a range like
\"main...HEAD\", or `staged\=' for the index against HEAD -- and
defaults to the index, the way `git diff' works.  The file names carry
a/ and b/ prefixes and are relative to ROOT, or with UNDER, a directory
name relative to another directory, relative to that one."
  (pcase (ecc-review--git-diff root paths range under)
    (`(0 . ,output)
     (and (not (string-empty-p output)) output))
    (result
     (ecc-log "review" "git diff failed in %s: %S" root result)
     nil)))

(defun ecc-review--range-arguments (range)
  "Return the arguments of `git diff\=' that diff against RANGE.
`staged\=' is --staged, nil and \"\" are nothing -- the index against
the working tree -- and a revision or a range is itself."
  (cond ((eq range 'staged) (list "--staged"))
        ((and range (not (string-empty-p range))) (list range))))

(defun ecc-review--git-diff (root paths &optional range under)
  "Return the (EXIT-CODE . OUTPUT) of the git diff of PATHS under ROOT.
RANGE is what to diff against, and UNDER what the names are put under
\(`ecc-review-git-diff').  This is `ecc-review-git-diff\=' without
the judgement: a caller that has to tell a diff that is empty from one
git refused to make -- an unknown revision, say -- reads the code."
  (apply #'ecc-git-run root
         (append ecc-review--diff-command
                 ecc-review--diff-options
                 (list (format "-U%d" (max 0 ecc-review-context-lines)))
                 (and under (list (concat "--src-prefix=a/" under)
                                  (concat "--dst-prefix=b/" under)))
                 (ecc-review--range-arguments range)
                 (list "--")
                 (mapcar (lambda (path) (ecc-review--relative path root)) paths))))

(define-obsolete-variable-alias 'ecc-review-untracked-max-bytes
  'ecc-review-max-bytes "0.3.0")

(defvar ecc-review-max-bytes 200000
  "How large a file a review prints in full.
A larger one is named and left out: nobody reviews a megabyte of
generated output, and the review is a prompt before it is anything
else.  This covers the untracked files of the working tree review and
the files a session changed -- a lock file a package manager wrote
again is the usual one -- and the two old sides of a file a review
compares to carry its comments (`ecc-review--blobs').")

(defalias 'ecc-review--binary-p #'ecc-diff-binary-p
  "Return non-nil when a path looks binary, or cannot be read.
git does not apply its own test to a new file diffed against
/dev/null -- the empty side is text, so the pair is text and the bytes
of a PNG land in the diff -- which is why the review has to ask for
itself.")

(defun ecc-review--omitted-note (path reason &optional new-file)
  "Return the diff entry naming PATH without its content, because of REASON.
NEW-FILE writes the header of a file that did not exist before."
  (format "diff --git %s %s\n%s%s\n"
          (ecc-review--git-quote (concat "a/" path)) (ecc-review--git-quote (concat "b/" path))
          (if new-file "new file mode 100644\n" "") reason))

(defun ecc-review--untracked-paths (root &optional paths)
  "Return the files under ROOT git does not track, relative to ROOT.
What .gitignore excludes is left out.  PATHS, relative to ROOT, are
pathspecs that restrict the answer; nil is every file."
  (pcase (apply #'ecc-git-run root "ls-files" "-z" "--others" "--exclude-standard"
                "--" paths)
    (`(0 . ,output) (split-string output "\0" t))))

(defun ecc-review-git-untracked (root &optional paths)
  "Return the diff of the files under ROOT git does not track, or nil.
What .gitignore excludes is left out, and each file is diffed against
nothing so that it reads like the rest of the diff.  A binary file, or
one larger than `ecc-review-max-bytes\=', is named rather than
printed.  PATHS, relative to ROOT, restrict it to those files."
  (let ((texts nil))
    (dolist (path (ecc-review--untracked-paths root paths))
      (let* ((full (expand-file-name path root))
             (size (file-attribute-size (file-attributes full))))
        (cond
         ((ecc-review--binary-p full)
          (push (ecc-review--omitted-note
                 path (format "Binary files /dev/null and b/%s differ" path)
                 t)
                texts))
         ((and size (> size ecc-review-max-bytes))
          (push (ecc-review--omitted-note
                 path (format "Files /dev/null and b/%s differ (%s, not shown)"
                              path (file-size-human-readable size))
                 t)
                texts))
         (t
          ;; --no-index exits 1 when the two sides differ, which is
          ;; every time here, so only a larger code is a failure.
          (pcase (apply #'ecc-git-run root
                        (append ecc-review--diff-command ecc-review--diff-options
                                (list (format "-U%d" (max 0 ecc-review-context-lines))
                                      "--no-index" "--" "/dev/null" path)))
            ((and `(,code . ,diff)
                  (guard (and (memq code '(0 1)) (not (string-empty-p diff)))))
             (push diff texts)))))))
    (let ((text (string-join (nreverse texts) "")))
      (and (not (string-empty-p text)) text))))

(defun ecc-review--unborn-p (root)
  "Return non-nil when the repository at ROOT has no commit yet."
  (pcase (ecc-git-run root "rev-parse" "--verify" "--quiet" "HEAD")
    (`(0 . ,_) nil)
    (_ t)))

(defun ecc-review--empty-tree (root)
  "Return the hash of the empty tree of the repository at ROOT, or nil.
Asked of git rather than written out: the 4b825dc everybody knows is the
SHA-1 one, and a repository whose object format is SHA-256 has another.
`ecc-git-run\=' gives git no stdin, so --stdin reads nothing and git
names the tree of nothing."
  (pcase (ecc-git-run root "hash-object" "-t" "tree" "--stdin")
    (`(0 . ,output)
     (let ((hash (string-trim output)))
       (and (not (string-empty-p hash)) hash)))))

;;;; What a range names

(defun ecc-review-parse-range (range)
  "Return RANGE as `ecc-review-range\=' takes it, or signal why not.
Nil and `staged\=' are returned as they are.  A string is trimmed;
\"--staged\" and \"--cached\" -- what `git diff\=' calls the index against
HEAD -- become `staged\='.  Any other string starting with - is refused:
the range goes to git as an argument, and an option there is not a
revision -- --output=FILE makes git write a file.  A revision never
starts with -, so no branch is mistaken for one.  The range typed at
\\[universal-argument] \\[ecc-review-range] and the one Claude gives
`review_open\=' are both read here."
  (cond
   ((memq range '(nil staged)) range)
   ((not (stringp range))
    (error "A range is a string or `staged', not %S" range))
   (t
    (let ((range (string-trim range)))
      (cond
       ((member range '("--staged" "--cached")) 'staged)
       ((string-prefix-p "-" range)
        (user-error "A range is a revision or a range of them, like HEAD or main...HEAD; it cannot start with -"))
       (t range))))))

(defvar ecc-review--fork-names (make-hash-table :test #'equal)
  "Hash of (ROOT . COMMIT) to what a review against that commit is called.
`ecc-review-name-fork\=' fills it.")

(defun ecc-review-name-fork (root commit name)
  "Call a review of the working tree of ROOT against COMMIT by NAME.
COMMIT is the full id of where a branch parted from its base, which is
what `ecc-review-menu\=' compares a branch and its working tree with: an
id that says nothing, so the menu says \"develop + working tree\" here.
It may also be a range of full ids, as a pull request is reviewed by
\(`ecc-review-pr-range\='), which is then called NAME as it is written.
The name belongs to the commit, not to the caller, so a review of the
same commit opened by Claude is called the same and is the same buffer."
  (puthash (cons root commit) name ecc-review--fork-names))

(defun ecc-review--commit (root revision)
  "Return the full id of the commit REVISION names in ROOT, or nil."
  (ecc-review--git-string root "rev-parse" "--verify" "--quiet"
                          (concat revision "^{commit}")))

(defun ecc-review-commit-alone (root commit)
  "Return the range that reviews COMMIT of ROOT alone, a full id.
COMMIT^!, the change `git show' shows; a commit with no parent -- the
first of the repository -- is compared with the empty tree instead,
which is what a parent would have held: COMMIT^! there names COMMIT
alone, and git would compare it with the working tree."
  (if (ecc-review--git-string root "rev-parse" "--verify" "--quiet" (concat commit "^"))
      (concat commit "^!")
    (format "%s..%s"
            (or (ecc-review--empty-tree root)
                (user-error "Cannot name the empty tree in %s" (abbreviate-file-name root)))
            commit)))

(defun ecc-review--commit-line (root commit &optional subject)
  "Return the short id of COMMIT in ROOT, and its SUBJECT when asked for."
  (ecc--truncate (or (ecc-review--git-string root "log" "-1" "--no-color"
                                             (if subject "--format=%h %s" "--format=%h")
                                             commit "--")
                     commit)
                 48))

(defun ecc-review-range-label (root range)
  "Return what a review of ROOT against RANGE is called, or nil for RANGE itself.
A range made of commit ids -- what `ecc-review-menu\=' and Claude both
give for a commit or a branch -- is called after the commits rather than
after the ids, so that an id written short and one written in full name
the same review: X^! is the short id and subject of X, X^..Y the short
ids of the two, a span from the empty tree the commit it ends at, and a
lone commit the name `ecc-review-name-fork\=' gave it, else its short
id.  A range of names, such as HEAD or main...HEAD, is its own name:
what it names moves, and the review moves with it."
  (when (and (stringp range) (not (string-empty-p range)))
    (let ((id "[0-9a-f]\\{4,64\\}"))
      (save-match-data
        (cond
         ((gethash (cons root range) ecc-review--fork-names))
         ((string-match (format "\\`\\(%s\\)\\^!\\'" id) range)
          (when-let* ((commit (ecc-review--commit root (match-string 1 range))))
            (ecc-review--commit-line root commit t)))
         ((string-match (format "\\`\\(%s\\)\\(\\^?\\)\\.\\.\\(%s\\)\\'" id id) range)
          (let ((from (match-string 1 range))
                (parent (match-string 2 range))
                (to (ecc-review--commit root (match-string 3 range))))
            (cond
             ((null to) nil)
             ((not (string-empty-p parent))
              (when-let* ((from (ecc-review--commit root from)))
                (format "%s to %s" (ecc-review--commit-line root from)
                        (ecc-review--commit-line root to))))
             ((equal (ecc-review--git-string root "rev-parse" "--verify" "--quiet" from)
                     (ecc-review--empty-tree root))
              (if (ecc-review--git-string root "rev-parse" "--verify" "--quiet"
                                          (concat to "^"))
                  (format "first commit to %s" (ecc-review--commit-line root to))
                (ecc-review--commit-line root to t))))))
         ((string-match (format "\\`%s\\'" id) range)
          (when-let* ((commit (ecc-review--commit root range)))
            (or (gethash (cons root commit) ecc-review--fork-names)
                (ecc-review--commit-line root commit)))))))))

(defun ecc-review--range-name (range &optional label)
  "Return RANGE in words for a buffer name or a header line.
LABEL, when given, is that name (`ecc-review-range-label\=')."
  ;; With a space in them, so that no ref can share the name, and the
  ;; buffer and comments of the review of a branch called "staged".
  (cond (label label)
        ((eq range 'staged) "staged changes")
        ((string-empty-p range) "unstaged changes")
        (t range)))

(defun ecc-review--effective-range (root range)
  "Return what git is given for RANGE in the repository at ROOT.
A repository with no commit has no HEAD to diff against, and git calls
that a bad revision rather than an empty diff.  The empty tree is what
HEAD would mean there, so the first code written in a project can be
reviewed before it is committed.  Only the bare \"HEAD\" is substituted:
\"main...HEAD\" in such a repository really is unresolvable, and still
says so.  The test is made afresh every time, so the first commit puts
the real HEAD back without anything having to be invalidated."
  (if (and (equal range "HEAD") (ecc-review--unborn-p root))
      (or (ecc-review--empty-tree root) range)
    range))

(defun ecc-review--range-includes-worktree-p (root range)
  "Return non-nil when diffing against RANGE in ROOT reads the working tree.
The files git does not track belong in such a review and in no other: a
review of commits -- \"a..b\", \"a...b\", \"REV^!\" -- that listed them
would show work that is in none of those commits.  The empty range, what
is not staged, reads the working tree, and `staged\=' does not.

The string is not parsed here but handed to git, which knows every way
of writing a revision:
`git rev-parse --revs-only\=' prints one line per revision a range names,
an excluded one with ^ in front, and `git diff\=' compares a lone
revision with the working tree and anything else with another commit.
So one line not starting with ^, and nothing more, is the working tree."
  (cond
   ((eq range 'staged) nil)
   ((or (null range) (string-empty-p range)) t)
   (t (pcase (ecc-git-run root "rev-parse" "--revs-only" range)
        (`(0 . ,output)
         (let ((lines (split-string output "\n" t)))
           (and (= (length lines) 1)
                (not (string-prefix-p "^" (car lines))))))))))

(defun ecc-review--right-revision (range)
  "Return the revision on the right of RANGE, the side shown as it is now.
B of A..B and A...B, HEAD when B is left out, X of X^!, and RANGE
itself otherwise."
  (save-match-data
    (cond ((string-match "\\.\\.\\.?\\(.*\\)\\'" range)
           (let ((right (match-string 1 range)))
             (if (string-empty-p right) "HEAD" right)))
          ((string-match "\\`\\(.+\\)\\^!\\'" range) (match-string 1 range))
          (t range))))

(defvar ecc-review--side-names (make-hash-table :test #'equal)
  "Hash of (ROOT . COMMIT) to the name of COMMIT as the right side of a review.
`ecc-review-name-side\=' fills it, and `ecc-review-elsewhere\=' reads it.")

(defun ecc-review-name-side (root commit name)
  "Call the full id COMMIT of ROOT by NAME when it is the right side of a review.
The head of a pull request is reviewed by its id, which says nothing to
somebody who has to check it out: `ecc-review-pr-range\=' gives it the
name of its branch here."
  (puthash (cons root commit) name ecc-review--side-names))

(defun ecc-review-elsewhere (root range)
  "Return the right side of a review of ROOT against RANGE when it is not here.
Nil when the files on disk are what the review shows on its right: a
review of the working tree (`ecc-review--range-includes-worktree-p'),
of what is staged, or of commits that end at HEAD.  Otherwise the
revision on the right (`ecc-review--right-revision'), a name as it was
written and an id as its short id, after the name
`ecc-review-name-side' gave it when there is one: a branch not checked
out, a pull request, a commit of the past.  Comments on such a review are about
lines that are in none of the files Claude edits, and the review and
its prompt say so (`ecc-review-elsewhere-note')."
  (when (and root (stringp range) (not (string-empty-p range))
             (not (ecc-review--range-includes-worktree-p root range)))
    (let* ((right (ecc-review--right-revision range))
           (commit (ecc-review--commit root right)))
      (cond
       ((null commit) right)
       ((equal commit (ecc-review--commit root "HEAD")) nil)
       ((string-prefix-p (downcase right) commit)
        (let ((short (ecc-review--commit-line root commit))
              (name (gethash (cons root commit) ecc-review--side-names)))
          (if name (format "%s (%s)" name short) short)))
       (t right)))))

;;;; What the working tree held at one moment

(defun ecc-review--head-tree (root)
  "Return the tree of HEAD at ROOT, or the empty tree when there is none.
The base a review falls back to when it has no baseline of its own."
  (if (ecc-review--unborn-p root)
      (ecc-review--empty-tree root)
    (ecc-review--git-string root "rev-parse" "--verify" "--quiet" "HEAD^{tree}")))

(defun ecc-review--numstat (root base now paths)
  "Return (PATH . BINARY-P) for every file that differs between BASE and NOW.
ROOT is the repository the two trees belong to, and PATHS restricts the
comparison.  Renames are not looked for, so that
each entry names one path and the sizes below can be decided file by
file; a rename reads as a delete and an add, which a review can see."
  (pcase (apply #'ecc-git-run root
                (append (list "diff" "--numstat" "-z" "--no-renames" base now "--")
                        paths))
    (`(0 . ,output)
     (let ((fields (split-string output "\0" t))
           (entries nil))
       ;; Each record is "ADDED\tDELETED\tPATH"; a binary one counts "-".
       (dolist (field fields)
         (when (string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t\\(.*\\)\\'"
                             field)
           (push (cons (match-string 3 field)
                       (equal (match-string 1 field) "-"))
                 entries)))
       (nreverse entries)))
    (result (ecc-log "review" "numstat failed in %s: %S" root result)
            nil)))

(defun ecc-review-baseline-diff (root base &optional paths)
  "Return the diff of the working tree at ROOT against the tree BASE, or nil.
PATHS, relative to ROOT, restrict it.  The working tree is snapshotted
and the two trees compared, so a file created, changed or deleted by
any means -- an edit, a shell command, a script -- reads the same, and
what was already changed before BASE was taken is not shown again.

A file larger than `ecc-review-max-bytes\=' is named rather than printed.
git decides for itself which files are binary here, because both sides
are trees: the test `ecc-review--binary-p\=' has to make for a file
diffed against /dev/null does not arise.  A file that no longer exists
is printed however long it was; its lines are leaving, and a review
that hid them would hide the whole of what happened to it."
  (when-let* ((now (ecc-git-snapshot root)))
    (let ((shown nil)
          (notes nil))
      (pcase-dolist (`(,path . ,binary) (ecc-review--numstat root base now paths))
        (let ((size (file-attribute-size
                     (file-attributes (expand-file-name path root)))))
          (if (and size (not binary) (> size ecc-review-max-bytes))
              (push (ecc-review--omitted-note
                     path (format "Files a/%s and b/%s differ (%s, not shown)"
                                  path path (file-size-human-readable size)))
                    notes)
            (push path shown))))
      (let* ((diff (and shown
                        (pcase (apply #'ecc-git-run root
                                      (append
                                       ecc-review--diff-command
                                       ecc-review--diff-options
                                       (list "--no-renames"
                                             (format "-U%d"
                                                     (max 0 ecc-review-context-lines))
                                             base now "--")
                                       (nreverse shown)))
                          (`(0 . ,output) output)
                          (result (ecc-log "review" "baseline diff failed in %s: %S"
                                           root result)
                                  nil))))
             (text (concat (or diff "") (string-join (nreverse notes) ""))))
        (and (not (string-empty-p text)) text)))))

;;;; A diff made from what the session recorded

(defun ecc-review--current-content (entry)
  "Return what the file of ENTRY holds now: the file, else the last snapshot."
  (or (ecc-diff-file-content (ecc-file-entry-path entry))
      (ecc-file-entry-snapshot entry)))

(defun ecc-review--file-header (path &optional new-file)
  "Return the ---/+++ lines naming PATH, from /dev/null when NEW-FILE.
A name git would quote is quoted (`ecc-review--git-quote')."
  (let ((name (ecc-review--git-quote path)))
    (format "--- %s\n+++ %s\n" (if new-file "/dev/null" name) name)))

(defun ecc-review-fallback-diff (entry)
  "Return the diff of the file of ENTRY over the session, or nil.
The whole file before the first change is compared with the file now;
when the start is not known, the changes are shown one after the other
from what the CLI reported for each (files git does not track)."
  (let* ((path (ecc-file-entry-path entry))
         (original (ecc-file-entry-original entry))
         (current (ecc-review--current-content entry))
         ;; What comes out of here is a patch: `ecc-review--file-header'
         ;; puts ---/+++ in front of it and `diff-mode' reads the rest.
         ;; The transcript's numbered style would not be a patch.
         (ecc-diff-style 'unified)
         (body
          (cond
           ((and (eq original 'unknown) (null (ecc-file-entry-hunks entry))) nil)
           ((eq original 'unknown)
            (let ((patches (ecc-file-entry-patches entry))
                  (parts nil))
              (dolist (hunk (ecc-file-entry-hunks entry))
                (push (cond ((and (car patches) (> (length (car patches)) 0))
                             (ecc-diff-from-patch (car patches)))
                            ((null (car hunk)) (ecc-diff-for-write (cdr hunk) nil))
                            (t (ecc-diff-render (car hunk) (cdr hunk)
                                                ecc-review-context-lines)))
                      parts)
                (setq patches (cdr patches)))
              (let ((text (string-join (delq nil (nreverse parts)) "")))
                (and (not (string-empty-p text)) text))))
           ((null current) nil)
           ((null original) (ecc-diff-for-write current nil))
           (t (ecc-diff-render original current ecc-review-context-lines)))))
    (when body
      (concat (ecc-review--file-header path (null original))
              (substring-no-properties body)))))

(defun ecc-review-diff-text (entries)
  "Return the diff of the files of ENTRIES as one unified diff, or nil.
Files git tracks are diffed by git, one call per repository; the rest
are diffed from what the session recorded.  Returns (TEXT . ROOT)
where ROOT is the repository the git part is relative to, when there
is one."
  (let ((groups nil)                    ; (root . paths), in order of appearance
        (roots (make-hash-table :test #'equal))
        (parts nil)
        (git-root nil))
    (dolist (entry entries)
      (let* ((path (expand-file-name (ecc-file-entry-path entry)))
             (root (or (gethash (file-name-directory path) roots)
                       (puthash (file-name-directory path)
                                (or (ecc-git-root path) 'none)
                                roots))))
        (if (eq root 'none)
            (push (cons entry nil) parts)
          (let ((group (assoc root groups)))
            (if group
                (setcdr group (append (cdr group) (list entry)))
              (setq groups (append groups (list (list root entry)))))))))
    (let ((texts nil))
      (dolist (group groups)
        (let* ((root (car group))
               (tracked (ecc-review-git-tracked
                         root (mapcar (lambda (e) (expand-file-name (ecc-file-entry-path e)))
                                      (cdr group)))))
          (when tracked
            (unless git-root (setq git-root root))
            ;; The files of another repository are named from the first,
            ;; the directory the review is read in: a file is one file
            ;; of the review whatever repository it is in, and RET goes
            ;; to it.
            (when-let* ((diff (ecc-review-git-diff
                               root tracked nil
                               (and (not (equal root git-root))
                                    (file-name-as-directory
                                     (file-relative-name root git-root))))))
              (push diff texts)))
          (dolist (entry (cdr group))
            (unless (member (expand-file-name (ecc-file-entry-path entry)) tracked)
              (push (cons entry nil) parts)))))
      (dolist (part (nreverse parts))
        (when-let* ((diff (ecc-review-fallback-diff (car part))))
          (push diff texts)))
      (let ((text (string-join (nreverse texts) "")))
        (and (not (string-empty-p text))
             (cons text git-root))))))

;;;; The buffer

(defvar-local ecc-review--session nil
  "The session this review buffer belongs to.")

(defvar-local ecc-review--request nil
  "The pending request this buffer reviews, or nil for a review of files.")

(defvar-local ecc-review--paths nil
  "The files this review was restricted to, or nil for every changed file.")

(defvar-local ecc-review--range nil
  "What a review of the working tree diffs against, or nil for a session review.
A string is what git is given: \"HEAD\" for everything uncommitted,
\"\" for what is not staged yet, \"main...HEAD\" for a branch.  The
symbol `staged\=' is what is staged, the index against HEAD.")

(defvar-local ecc-review--label nil
  "What this review of the working tree is called, if not its range.
`ecc-review-range-label\=' of its range, for the header line.")

(defvar-local ecc-review--elsewhere nil
  "The right side of this review when it is not the files on disk, or nil.
`ecc-review-elsewhere\=' of its range, for the header line and the prompt.")

(defvar-local ecc-review--walk nil
  "The pull request this review is a part of, read a commit at a time, or nil.
An `ecc-review-pr-walk\=' of `ecc-review-pr.el\=': the whole of the pull
request, or one of its commits, with \\`]' and \\`[' going between them.")

(defvar-local ecc-review--stale nil
  "Non-nil when the files may have changed since this review was read.")

(defvar-local ecc-review--fingerprint nil
  "What this review was last filled with: (HASH . TICK), or nil.
HASH is the sha1 of the text put in, and TICK the
`buffer-chars-modified-tick\=' right after.  A text with the same hash
is not put in again only while the tick says that nothing has edited
the buffer since -- a key of `diff-mode\=' that got past the review\='s
own keymap, say -- so that \`g' always repairs it.")

(defvar-local ecc-review--failed nil
  "Why the last reading of this review again failed, or nil.
A review that failed is not read again by itself until \`g' reads it.")

(defvar-local ecc-review--notes nil
  "The comments of this review, as `ecc-review-note's in the order made.
They are the record; the overlays in `ecc-review--comments\=' are only
how they are drawn, and are made again from here on every redraw.")

(defvar-local ecc-review--next-id 1
  "The id the next comment of this review is given.
Ids only go up, so an id a removed comment had is never handed out
again and a model holding it cannot hit another comment with it.")

(defvar-local ecc-review--show-agent t
  "Non-nil draws Claude\='s comments; toggled with `ecc-review-toggle-agent\='.")

(defvar-local ecc-review--filter nil
  "What the files of this review are filtered by, or nil for every file.
\\`/' sets it (`ecc-review-files-filter\='), and it is kept across every
reading of the review again.")

(defvar-local ecc-review--hidden nil
  "The paths of the files the filter of this review hides.
Hidden, not dropped: their comments are kept and sent, and nothing is
read again to hide them (`ecc-review-files.el\=').")

(defun ecc-review-hidden-p (path)
  "Return non-nil when the filter of this review hides the file PATH."
  (and ecc-review--hidden (member path ecc-review--hidden) t))

(defvar ecc-review-before-draw-hook nil
  "Run in a review buffer before its comments are drawn again.
The filter hides its files here (`ecc-review-files.el\='), so that the
comments of a file it hides are not drawn.")

(defvar ecc-review-after-draw-hook nil
  "Run in a review buffer after its comments have been drawn again.
Every reading of the review again and every change to its comments
ends in a drawing, so the list of its files is written again here.")

(defvar ecc-review--refilling nil
  "Non-nil while a review is being read again into its buffer.
The comments are drawn before the place being read is put back, so
what follows the place waits for `ecc-review-refilled-hook\='.")

(defvar ecc-review-refilled-hook nil
  "Run in a review buffer once it has been read again and its place put back.
The files pane marks the file being read here, and a file the filter
hides is stepped off here.")

(defvar ecc-review-displayed-functions nil
  "Functions called with a review buffer the user has just opened.
The review is on the screen by then; the files pane comes up beside it
here when it is wanted.")

(defvar ecc-review-moved-hook nil
  "Run in a diff review after its view was moved without a command.
What Claude moves over MCP, and what the files pane moves, is no
command of the review's own, so `post-command-hook\=' does not hear it.")

(defvar-local ecc-review--comments nil
  "Overlays drawing the comments, one per place that carries any.")

(defvar-local ecc-review--decorations nil
  "Overlays marking the header of every hunk that carries a comment.")

;; A review is a buffer that holds comments and sends them, keeping
;; them, marked sent, for Claude's replies.  Both kinds keep their
;; comments the same way, as `ecc-review-note's in `ecc-review--notes' of
;; the buffer the review is driven from -- the diff buffer itself, or the
;; control buffer of an ediff review -- and put them back with the same
;; rules.  How one lists them and how one closes -- on C-c C-k, or once
;; the review of a proposal has sent its deny -- are these two slots: the
;; diff buffer is killed, an ediff review is quit through ediff so that
;; the windows come back.  What else differs -- where a line is, how a comment is
;; drawn, how the view is moved -- is the generic functions under "Kinds
;; of review" below, so that C-c C-c, the prompt shown to be confirmed,
;; C-c C-k and the tools of `ecc-review-agent.el' are the same code for
;; both.

(defvar-local ecc-review--comments-function #'ecc-review-comments
  "How this review buffer lists its comments.
Called with no argument in the review buffer; returns the plists
`ecc-review-format-message\=' takes.")

(defvar-local ecc-review--close-function #'ecc-perm-close-buffer
  "How this review buffer is closed.
By \\[ecc-review-quit], or once the review of a proposal has denied it
with its comments.  Called with the review buffer.")

(defun ecc-review--close (review)
  "Close the review buffer REVIEW the way it asks to be closed."
  (when (buffer-live-p review)
    (funcall (buffer-local-value 'ecc-review--close-function review) review)))

(defvar-local ecc-review--part-of nil
  "The review buffer this buffer shows a part of, or nil.
The two sides of an ediff review point at its control buffer, which is
where the review is kept: a window coming to show one of them is a
review coming into view.")

(defun ecc-review-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is a review of files.
A diff review, or the control buffer of an ediff review; the review of
a proposal is not one, being about that proposal rather than the files.
BUFFER defaults to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (and ecc-review--session
         (null ecc-review--request)
         (derived-mode-p 'ecc-review-mode 'ediff-mode))))

;;;; Kinds of review

;; The diff review is the default of each of these, and `ecc-review-
;; ediff.el' has the ediff review's own; they are called in the review
;; buffer, and dispatch on its major mode.  The tools of
;; `ecc-review-agent.el' and the following of the files reach a review
;; through these alone, so neither asks which kind it has.

(cl-defgeneric ecc-review-lines ()
  "Return every line of this review a comment can be on.
Each is a plist of `ecc-review--hunk-lines', and the @@ header of each
hunk is among them, as the line a comment on the whole hunk is on."
  (ecc-review--lines))

(cl-defgeneric ecc-review-units ()
  "Return the hunks of this review, as `ecc-review-hunk-at' plists, in order."
  (ecc-review-hunks))

(cl-defgeneric ecc-review-unit-description (hunk)
  "Return how `review_hunks' describes HUNK after its number."
  (format "%s  new L%d-L%d" (plist-get hunk :header)
          (plist-get hunk :start) (plist-get hunk :end)))

(cl-defgeneric ecc-review-place-at-point ()
  "Return where the user is in this review, as a plist, or nil.
:path is the file, relative to the review; :hunk the hunk the user is
in, as `ecc-review-units' has it, or nil between hunks; :line the
number of the line they are on, and :side the side it counts on, `old'
or `new' -- nil, both of them, on a header.  In the diff review it is
the line at point, on the side of that line; a file header is the file
it begins, and nothing after the last hunk."
  (if-let* ((bounds (ecc-review--hunk-bounds)))
      (let* ((hunk (ecc-review-hunk-at (car bounds) (cdr bounds)))
             (bol (line-beginning-position))
             (line (seq-find (lambda (line) (eql (plist-get line :position) bol))
                             (ecc-review--hunk-lines hunk))))
        (list :path (plist-get hunk :path) :hunk hunk
              :line (plist-get line :line) :side (plist-get line :side)))
    (save-excursion
      (beginning-of-line)
      (when (re-search-forward ecc-diff-hunk-regexp nil t)
        (list :path (ecc-review--hunk-path (match-beginning 0)))))))

(cl-defgeneric ecc-review-region ()
  "Return the lines of this review the user has selected, or nil.
Nil without an active region (`use-region-p'); otherwise a plist:
:buffer is the buffer the region is in, :side the side it is on in a
review that shows the two apart, `old' or `new' (nil in the diff
review), and :lines the lines it touches, in order.  Each line is a
plist of :path, :side and :line as `ecc-review-place-at-point' names
them, :text without its marker, :marker, the character a diff puts in
front of it, and :hunk, the hunk it is in or nil.  In the diff review
those are the lines of the hunks the region touches, the @@ headers and
the file headers left out, so a region over nothing else has no lines;
a region that ends at the start of a line leaves that line out."
  (when (use-region-p)
    (let ((beg (save-excursion (goto-char (region-beginning)) (line-beginning-position)))
          (end (region-end)))
      (list :buffer (current-buffer)
            :side nil
            :lines (mapcan
                    (lambda (hunk)
                      (when (and (< (plist-get hunk :position) end)
                                 (> (plist-get hunk :bound) beg))
                        (mapcan (lambda (line)
                                  (when-let* ((side (plist-get line :side))
                                              ((<= beg (plist-get line :position)))
                                              ((< (plist-get line :position) end)))
                                    (list (append (list :marker (cond ((eq side 'old) ?-)
                                                                      ((plist-get line :old-line) ?\s)
                                                                      (t ?+)))
                                                  line))))
                                (ecc-review--hunk-lines hunk))))
                    (ecc-review-units))))))

(defun ecc-review-hunk-number (hunk)
  "Return (N . TOTAL): HUNK is hunk N of the TOTAL hunks of its file.
Counted from 1, the way `review_hunks' numbers them."
  (let* ((path (plist-get hunk :path))
         (key (ecc-review--hunk-key hunk))
         (hunks (seq-filter (lambda (other) (equal (plist-get other :path) path))
                            (ecc-review-units))))
    (cons (1+ (or (seq-position hunks key
                                (lambda (other key) (equal (ecc-review--hunk-key other) key)))
                  -1))
          (length hunks))))

(cl-defgeneric ecc-review--note-place (note line lines)
  "Return (BUFFER BEG END PROPERTY KEY) for drawing NOTE, put on LINE.
LINE is nil for an outdated comment, and LINES are all the lines of the
review.  The overlay goes in BUFFER between BEG and END and shows the
comment as its PROPERTY, `after-string' or `before-string'; KEY is a
position in the order of the review, which is what the comments are
sorted and walked by (`ecc-review-note-position')."
  (pcase-let ((`(,beg ,end ,property) (ecc-review--place note line lines)))
    (list (current-buffer) beg end property beg)))

(defun ecc-review--hunk-place (line)
  "Return which hunk LINE, a line of a reading, is in: (PATH HEADER NTH).
NTH tells it from the hunks of its file before it with the same header
\(`ecc-review-map-number'), as in a diff that joins a patch for each edit."
  (list (plist-get line :path)
        (plist-get (plist-get line :hunk) :header)
        (or (plist-get line (if (plist-get line :side) :hunk-nth :nth)) 0)))

(cl-defgeneric ecc-review--decorate (commented lines)
  "Mark the hunks of LINES that COMMENTED names as carrying comments.
COMMENTED are `ecc-review--hunk-place's, and LINES all the lines of the
review.  Which of the hunks with its header each is, is the reading's
\(`ecc-review--canonical'), asked only of a header COMMENTED names: its
file has a comment on it, and is in the reading already.  Return the
overlays made."
  (let ((overlays nil)
        (headers (mapcar (lambda (place) (cons (car place) (cadr place))) commented)))
    (dolist (line lines)
      (when (and (null (plist-get line :side))
                 (member (cons (plist-get line :path) (plist-get (plist-get line :hunk) :header))
                         headers)
                 (member (ecc-review--hunk-place (ecc-review--canonical line)) commented))
        (let ((overlay (make-overlay (plist-get line :position)
                                     (save-excursion
                                       (goto-char (plist-get line :position))
                                       (line-end-position)))))
          (overlay-put overlay 'face 'ecc-review-commented-hunk-face)
          (push overlay overlays))))
    overlays))

(cl-defgeneric ecc-review-reading-position (window)
  "Return where the review is being read, as a KEY of `ecc-review--note-place'.
WINDOW is the window it is on the screen in, or nil."
  (if window (window-point window) (point)))

(defun ecc-review--window-start (window position)
  "Return a start for WINDOW that puts POSITION a quarter of the way down."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char position)
      (forward-line (- (/ (window-body-height window) 4)))
      (point))))

(cl-defgeneric ecc-review-move-to (place window)
  "Move the view of this review to PLACE, without selecting anything.
PLACE is a comment or a line of `ecc-review-lines'.  WINDOW is the
window the review is shown in, or nil; point moves either way, so that
the review opens there."
  (let ((position (or (if (ecc-review-note-p place)
                          (ecc-review-note-position place)
                        (plist-get place :position))
                      (point-min))))
    (goto-char position)
    (when window
      (set-window-point window position)
      (set-window-start window (ecc-review--window-start window position)))
    (run-hooks 'ecc-review-moved-hook)))

(cl-defgeneric ecc-review-shown-window ()
  "Return the window this review is on the screen in, or nil."
  (get-buffer-window (current-buffer) 'visible))

(cl-defgeneric ecc-review-show-quietly (session others)
  "Show this review of SESSION without taking anything; return its window.
OTHERS is a predicate on a buffer: another review on the screen that
gives up its window to this one (`ecc-window-show-review-quietly')."
  (ecc-window-show-review-quietly (current-buffer) session others))

(cl-defgeneric ecc-review-go-back ()
  "Put the keyboard back in this review, which something else had it from.
The diff review is popped to; an ediff review has its own way."
  (pop-to-buffer (current-buffer)))

(cl-defgeneric ecc-review-takes-the-screen-p ()
  "Return non-nil when this review cannot be opened without taking the screen.
Such a review is read again where it is, never opened afresh by
Claude."
  nil)

(cl-defgeneric ecc-review-reread (&optional watching)
  "Read this review again from what it remembers, keeping its comments.
WATCHING is `ecc-review--show\='s: a review read because the files
changed stays open when its changes have gone."
  (ecc-review--reread (current-buffer) watching))

(defvar ecc-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'ecc-review-comment)
    (define-key map (kbd "l") #'ecc-review-list-comments)
    (define-key map (kbd "d") #'ecc-review-remove-comment)
    (define-key map (kbd "a") #'ecc-review-toggle-agent)
    (define-key map (kbd "{") #'ecc-review-previous-comment)
    (define-key map (kbd "}") #'ecc-review-next-comment)
    (define-key map (kbd "C-c C-c") #'ecc-review-send)
    (define-key map (kbd "C-c C-k") #'ecc-review-quit)
    (define-key map (kbd "e") #'ecc-review-edit-proposal)
    (define-key map (kbd "g") #'ecc-review-refresh)
    (define-key map (kbd "q") #'quit-window)
    ;; s was `diff-split-hunk', which edits the buffer and is refused
    ;; below with the rest; s toggles the files pane instead.
    (define-key map (kbd "s") #'ecc-review-files-toggle)
    (define-key map (kbd "/") #'ecc-review-files-filter)
    ;; diff-mode's own moves, past the files the filter hides.
    (define-key map (kbd "n") #'ecc-review-next-hunk)
    (define-key map (kbd "p") #'ecc-review-previous-hunk)
    (define-key map (kbd "N") #'ecc-review-next-file)
    (define-key map (kbd "P") #'ecc-review-previous-file)
    ;; Talking to the session of the review without going to its prompt
    ;; (`ecc-review-talk.el').  t and M rather than N and m: N is the
    ;; next file just above, and m is ediff's wide display, and the keys
    ;; are the same in both kinds of review (decided 2026-10-02).
    (define-key map (kbd "T") #'ecc-review-talk-tour)
    (define-key map (kbd "t") #'ecc-review-talk-next)
    (define-key map (kbd "M") #'ecc-review-talk-message)
    ;; A pull request read a commit at a time (`ecc-review-pr.el').
    ;; C-c C-a was `diff-apply-hunk', which writes into the file the
    ;; hunk is of: a review reads and comments, and Claude changes the
    ;; files.
    (define-key map (kbd "]") #'ecc-review-pr-next-commit)
    (define-key map (kbd "[") #'ecc-review-pr-previous-commit)
    (define-key map (kbd "C-c C-a") #'ecc-review-pr-send-all)
    ;; The header line has room for the keys used most; ? lists every
    ;; one, as it does in the control panel of an ediff review.
    (define-key map (kbd "?") #'ecc-review-help)
    ;; `diff-mode' edits its buffer from these, read-only or not: they
    ;; bind `inhibit-read-only'.  A review is a copy of what git said, and
    ;; one stray k would leave it saying something else; u and @ revert
    ;; the hunk in the file itself.  The two undo commands go too, there
    ;; being no undo to go back with.
    (dolist (key '("k" "K" "R" "u" "@"
                   "C-c C-s" "C-c C-r" "C-c C-u" "C-c C-d" "C-c C-l" "C-c C-w"
                   "C-c M-u" "C-c C-m n"
                   "<remap> <undo>" "<remap> <undo-ignore-read-only>"))
      (define-key map (kbd key) #'ecc-review-read-only))
    map)
  ;; The keys in the last paragraph are written out, not \\[...]: it is
  ;; about those keys -- which ones the manual reserves and which ones
  ;; `diff-mode' already has -- and a rebinding does not change that.
  ;; checkdoc reports the second chord of `C-c C-c' all the same.
  "Keymap of `ecc-review-mode\='.
The buffer is read-only, so a letter is free to be a command, and these
come before `diff-mode-shared-map\=' and `diff-mode-read-only-map\='.
Those move with n, N, p, P, { and } and visit with o and RET, and edit
the buffer with k, K, R, s and more; every key of `diff-mode\=' that
edits it, or reverts the file, says that the review is read-only
instead (`ecc-review-read-only\='), but s, which lists the files.

Nothing here takes a \\`C-c <letter>\=' key: the Emacs Lisp manual
reserves those for users.  \\`C-c C-c\=' and \\`C-c C-k\=' shadow
`diff-mode\=', deliberately: finishing and aborting are what those two
mean everywhere in Emacs.  So do { and }, which move between the
comments here and between files in `diff-mode\=': N and P still do
that.")

(defun ecc-review--past-hidden (count forward backward regexp what)
  "Move COUNT of what REGEXP finds, past what the filter hides.
FORWARD and BACKWARD are the moves of `diff-mode' that go to the next
and the previous one, and a negative COUNT goes back, as it does in
them.  WHAT names what is moved to, for the message.

Without a filter this is FORWARD with COUNT, called as a key calls it
\(`funcall-interactively'): only then does `diff-mode' scroll the whole
hunk into view and refine it as it is reached (`diff-refine'
`navigation').  With one, the place to go is found by a search over the
starts REGEXP finds that are not hidden, and only the last move, the
one that lands there, is made as a key would make it -- each hidden
hunk stepped over interactively would scroll to hidden text and make a
marker for refining, hundreds to a keypress.  With nothing kept further
on, point and the window are left as they were and that is said."
  (if (null ecc-review--hidden)
      (funcall-interactively (if (< count 0) backward forward) (abs count))
    (let* ((back (< count 0))
           (here (point))
           (starts nil))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (let ((start (match-beginning 0)))
            (unless (invisible-p start)
              (push start starts)))))
      (setq starts (nreverse starts))
      (let ((target (nth (1- (abs count))
                         (if back
                             (reverse (seq-filter (lambda (start) (< start here)) starts))
                           (seq-filter (lambda (start) (> start here)) starts)))))
        (unless target
          (user-error "No %s %s in the files the filter keeps"
                      (if back "previous" "next") what))
        ;; On TARGET, and the key's move with a count of 0, which counts
        ;; the start it stands on and lands there: the move scrolls and
        ;; refines the one hunk it lands on.  Not BACKWARD from just after
        ;; TARGET, which Emacs 29 and 30 take one start further back.
        (goto-char target)
        (funcall-interactively forward 0)))))

(defun ecc-review-next-hunk (&optional count)
  "Go to the next hunk, COUNT of them, past the files the filter hides."
  (interactive "p")
  (ecc-review--past-hidden (or count 1) #'diff-hunk-next #'diff-hunk-prev
                           diff-hunk-header-re "hunk"))

(defun ecc-review-previous-hunk (&optional count)
  "Go to the previous hunk, COUNT of them, past the files the filter hides."
  (interactive "p")
  (ecc-review--past-hidden (- (or count 1)) #'diff-hunk-next #'diff-hunk-prev
                           diff-hunk-header-re "hunk"))

(defun ecc-review-next-file (&optional count)
  "Go to the next file, COUNT of them, past the files the filter hides."
  (interactive "p")
  (ecc-review--past-hidden (or count 1) #'diff-file-next #'diff-file-prev
                           diff-file-header-re "file"))

(defun ecc-review-previous-file (&optional count)
  "Go to the previous file, COUNT of them, past the files the filter hides."
  (interactive "p")
  (ecc-review--past-hidden (- (or count 1)) #'diff-file-next #'diff-file-prev
                           diff-file-header-re "file"))

(defconst ecc-review-long-help-message
  "Move around                          Comments
  n / p     next, previous hunk        c         comment on this line (@@: the hunk)
  N / P     next, previous file        { / }     previous, next comment
  RET / o   go to the source           d         remove a comment here
  s         list the files             l         jump to a comment
  /         filter the files           a         show or hide Claude's
  g         read the diff again        C-c C-c   send the new comments
  q         bury the review            C-u C-c C-c  edit them, then send
  ] / [     next, previous commit      C-c C-k   drop the review
                                       C-c C-a   send every commit's
Claude
  T         ask for a tour of the review
  t         the next stop of the tour
  M         say something to Claude, about the region when it is active

C-c C-c sends the comments not sent yet and keeps the review open: the
sent ones stay, dimmed, for Claude's replies, and the next C-c C-c sends
only those made since.  q buries the review and C-c C-k drops it.

] and [ go through the commits of a pull request opened with p in the
review menu, and C-c C-a sends the comments of all of them not sent yet
as one prompt, keeping every review as C-c C-c keeps this one.

The review is read-only: it shows what git says.  Claude changes the
files, from the prompt the comments are sent as."
  "What \\`?' shows in a diff review of files.")

(defconst ecc-review-proposal-long-help-message
  "Move around                          Comments
  n / p     next, previous hunk        c         comment on this line (@@: the hunk)
  RET / o   go to the source           { / }     previous, next comment
  q         bury the review            d         remove a comment here
                                       l         jump to a comment
The proposal                           C-c C-c   send the comments as a deny
  e         edit it and apply it       C-u C-c C-c  edit them, then deny
                                       C-c C-k   drop the review

This reviews one change Claude proposes.  The comments go back as the
reason it is refused: C-c C-c denies the proposal.  e is the way to
accept it, changed or not."
  "What \\`?' shows in the review of one proposal.")

(defun ecc-review-help ()
  "Show every key of this diff review in the help window.
The review of a proposal has keys of its own, and sending its comments
denies the proposal."
  (interactive)
  (let ((text (if ecc-review--request
                  ecc-review-proposal-long-help-message
                ecc-review-long-help-message)))
    (with-help-window (help-buffer)
      (princ text))))

(defun ecc-review-read-only ()
  "Say that the review cannot be edited, in place of a `diff-mode' edit."
  (interactive)
  (user-error "The review is read-only: it shows what git says; g reads it again"))

(define-derived-mode ecc-review-mode diff-mode "Claude-Review"
  "Major mode of the buffer the changes of a session are reviewed in.

\\{ecc-review-mode-map}"
  :interactive nil
  (setq buffer-read-only t)
  ;; Nothing in it is typed: every change is a whole diff put in again,
  ;; and an undo list keeping each one would grow by the size of the
  ;; diff on every refresh, until `undo-outer-limit\=' put up a warning.
  (buffer-disable-undo)
  ;; While the buffer is read-only the review keys come first, then the
  ;; keys `diff-mode' gives a read-only buffer (n, p, RET, ...), which
  ;; not every Emacs installs by itself.
  (setq-local minor-mode-overriding-map-alist
              (append (list (cons 'buffer-read-only ecc-review-mode-map)
                            (cons 'buffer-read-only diff-mode-shared-map))
                      (seq-remove (lambda (entry)
                                    (memq (cdr entry)
                                          (list ecc-review-mode-map diff-mode-shared-map)))
                                  minor-mode-overriding-map-alist)))
  (setq header-line-format '(:eval (ecc-review--header-line)))
  (ecc-review--watch-files))

(defun ecc-review-buffer-name (session &optional request range label)
  "Return the name of the review buffer of SESSION.
With REQUEST it is the buffer reviewing that one proposal; with RANGE,
the one reviewing the working tree, called LABEL when given
\(`ecc-review-range-label\=').  The three are different buffers: a
review of the working tree does not take the place of the review of
what the session changed.  The name is made from what is reviewed,
not from who asked for it, so the review the menu opens and the one
`review_open\=' opens are one buffer."
  (cond
   (request (format "*ecc-review: %s (proposal)*" (ecc-session-name session)))
   (range (format "*ecc-review: %s (%s)*" (ecc-session-name session)
                  (ecc-review--range-name range label)))
   (t (format "*ecc-review: %s*" (ecc-session-name session)))))

(defun ecc-review--header-line ()
  "Return the header line of the review buffer."
  (ecc--mode-line-escape
   (concat
   (propertize (format " %s: %s"
                       (cond (ecc-review--request "Proposal review")
                             (ecc-review--range
                              (format (if ecc-review--elsewhere "Review (%s)" "Working tree (%s)")
                                      (ecc-review--range-name ecc-review--range
                                                              ecc-review--label)))
                             (t "Review"))
                       (if ecc-review--session
                           (ecc-session-name ecc-review--session)
                         "?"))
               'face 'ecc-heading-face)
   ;; Which commit of which pull request, and the comments of the others.
   (when ecc-review--walk
     (concat "  ·  " (ecc-review-pr-walk-status)))
   (when ecc-review--elsewhere
     (propertize (format "  ·  the right side is %s, not checked out here" ecc-review--elsewhere)
                 'face 'warning))
   (when ecc-review--failed
     (propertize (format "  ·  could not read the diff: %s; g to retry" ecc-review--failed)
                 'face 'error))
   (propertize (concat "  ·  " (ecc-review--count-string)) 'face 'ecc-dim-face)
   (when ecc-review--filter
     (propertize (format "  ·  /%s: %s hidden by filter" ecc-review--filter
                         (ecc-review--count (length ecc-review--hidden) "file"))
                 'face 'warning))
   (propertize (if ecc-review--request
                   "  ·  c comment  e edit and apply  C-c C-c send as deny (C-u edits)  n/p hunk  RET source"
                 (concat "  ·  c comment  { } comments  d delete  n/p hunk  s files  / filter  T tour  t next  M message  C-c C-c send"
                         (when ecc-review--walk "  ] [ commits  C-c C-a send all")
                         "  ? all keys"))
               'face 'ecc-dim-face))))

(defun ecc-review-pane-name (review kind)
  "Return the name of the KIND pane of REVIEW: \"*ecc-review-KIND: ...*\".
What follows the colon is what follows it in the name of the review
itself, so that a pane says which review it belongs to."
  (with-current-buffer review
    (let ((name (ecc-review-buffer-name ecc-review--session nil ecc-review--range
                                        ecc-review--label)))
      (format "*ecc-review-%s: %s" kind (substring name (length "*ecc-review: "))))))

(defun ecc-review-pane-buffer (review kind mode review-var)
  "Make the KIND pane of REVIEW, a buffer in MODE, and return it.
REVIEW-VAR is the buffer-local variable of MODE that says which review
a pane belongs to; it is set to REVIEW.  The pane is named
`ecc-review-pane-name\=', unless a live pane of another review has
that name already, which happens to two reviews of one session and one
range read under different labels: then it gets a name of its own."
  (let* ((name (ecc-review-pane-name review kind))
         (taken (get-buffer name))
         (owner (and taken (buffer-local-value review-var taken)))
         (pane (if (and (buffer-live-p owner) (not (eq owner review)))
                   (generate-new-buffer name)
                 (get-buffer-create name))))
    (with-current-buffer pane
      (funcall mode)
      (set review-var review))
    pane))

(defun ecc-review-pane-take-down (window &optional parameters)
  "Take the pane in WINDOW off the screen.
Deleted, or, where it cannot be -- the last window of its frame -- given
back to another buffer, so that no stale pane stays dedicated there.
The window parameters a pane sets go first: `no-other-window\=',
`no-delete-other-windows\=' and the PARAMETERS of its own, so that a
window given back is one that \\[other-window] reaches and
\\[delete-other-windows] deletes."
  (dolist (parameter (append '(no-other-window no-delete-other-windows) parameters))
    (set-window-parameter window parameter nil))
  (if (eq (window-deletable-p window) t)
      (delete-window window)
    (set-window-dedicated-p window nil)
    (switch-to-prev-buffer window 'bury)))

(defun ecc-review--count (n noun)
  "Return N NOUNs in words: \"1 comment\", \"2 comments\"."
  (format "%d %s%s" n noun (if (= n 1) "" "s")))

(defun ecc-review--count-string ()
  "Return what the header line says about the comments of this buffer.
Claude\='s are counted while they are hidden: hiding them is for reading
the diff, not for forgetting that they are there."
  (let ((yours 0) (sent 0) (claude 0) (outdated 0))
    (dolist (note ecc-review--notes)
      (if (eq (ecc-review-note-author note) 'claude)
          (cl-incf claude)
        (cl-incf yours)
        (when (ecc-review-note-sent note)
          (cl-incf sent)))
      (when (ecc-review-note-outdated note)
        (cl-incf outdated)))
    (concat (format "comments: %d yours" yours)
            (when (> sent 0)
              (format " (%d sent)" sent))
            (when (> claude 0)
              (format ", %d Claude's%s" claude
                      (if ecc-review--show-agent "" " (hidden)")))
            (when (> outdated 0)
              (format " (%d outdated)" outdated)))))

(defun ecc-review--nothing-text (text)
  "Return the text a review shows when there is nothing to review, TEXT."
  (propertize (concat text ".  This review follows the files,"
                      " and the next change will show up here.\n")
              'font-lock-face 'ecc-dim-face))

(defun ecc-review--show (content session &optional buffer watching)
  "Fill the review of SESSION with CONTENT and return its buffer.
CONTENT is what `ecc-review--session-content\=' or
`ecc-review--range-content\=' read: a plist of :text, the diff or nil
when there is none, :root, :paths, :range, :name, the name of the
review buffer, and :nothing, what to say when there is no diff.

BUFFER is the review to fill, the one named :name by default.  With no
diff to show, WATCHING -- a review read again because the files changed
-- fills it with :nothing and keeps it open: what was reviewed may have
been undone or committed, and the next change will show up there.
Without WATCHING that is a `user-error\=', and no buffer is made.

A text the buffer holds already is not put in again: the erase and the
redraw are skipped, so the buffer is not modified, its undo and its
overlays are left alone, and a refresh that finds nothing new costs only
the reading."
  (let* ((text (or (plist-get content :text)
                   (if watching
                       (ecc-review--nothing-text (plist-get content :nothing))
                     (user-error "%s" (plist-get content :nothing)))))
         (buffer (or buffer (get-buffer-create (plist-get content :name)))))
    (if (with-current-buffer buffer
          (and (derived-mode-p 'ecc-review-mode)
               (null ecc-review--request)
               (eq ecc-review--session session)
               (equal ecc-review--fingerprint
                      (cons (secure-hash 'sha1 text) (buffer-chars-modified-tick)))
               (equal ecc-review--paths (plist-get content :paths))
               (equal ecc-review--range (plist-get content :range))))
        (with-current-buffer buffer
          (setq ecc-review--stale nil
                ecc-review--failed nil
                ecc-review--label (plist-get content :label)
                ecc-review--elsewhere (plist-get content :elsewhere))
          (force-mode-line-update)
          buffer)
      (prog1 (ecc-review--fill buffer session text (plist-get content :root) nil
                               (plist-get content :paths) (plist-get content :range))
        (with-current-buffer buffer
          (setq ecc-review--label (plist-get content :label)
                ecc-review--elsewhere (plist-get content :elsewhere)))))))

(defvar ecc-review--held)               ; below, with the readings
(defvar ecc-review--reading)

(defun ecc-review--fill (buffer session text root &optional request paths range)
  "Put the diff TEXT into BUFFER for SESSION and draw its comments again.
ROOT is the directory the file names of TEXT are relative to; REQUEST,
PATHS and RANGE are remembered as what the buffer reviews.

The comments are kept across a redraw, each carried to where its line
is now (`ecc-review--take-reading\='); one whose line changed or went is
marked outdated and kept, never dropped.  So is the place being read:
point, and in every window showing the buffer its point and how far
down the window that line was, are put back on the same line by the
same rule, or on the nearest line that stayed when that one went --
whether the diff was read again by \\`g', by opening the review again, or
by Claude.  A buffer that reviewed another proposal before starts with
no comments and at the top: that was about something that is not being
asked any more, and nothing kept to carry its places is kept either.
A buffer edited since it was read has no place to keep, and opens at
the top."
  (with-current-buffer buffer
    (let* ((same (and (derived-mode-p 'ecc-review-mode)
                      (eq ecc-review--request request)))
           (placed (and same (seq-remove #'ecc-review-note-outdated ecc-review--notes)))
           (held ecc-review--held)
           (fingerprint nil)
           (views nil))
      ;; The places read are held from here, and whatever this holds is
      ;; let go however it ends -- even part of the way through saving.
      (unwind-protect
          (progn
            (setq views (and same (ecc-review--reading-current-p) (ecc-review--save-views)))
            (unless (derived-mode-p 'ecc-review-mode)
              (ecc-review-mode))
            (unless same
              (setq ecc-review--notes nil
                    ecc-review--next-id 1)
              (ecc-review--forget-places))
            (ecc-review--begin-reading)
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (ecc-review--shorten-ids text))
              (unless (bolp) (insert "\n")))
            (setq default-directory (or root (ecc-session-project-root session)
                                        default-directory)
                  ecc-review--session session
                  ecc-render--session session
                  ecc-review--request request
                  ecc-review--paths paths
                  ecc-review--range range
                  ecc-review--stale nil
                  ecc-review--failed nil)
            (set-buffer-modified-p nil)
            ;; Not what this buffer was filled with until its reading is
            ;; whole: a refill that stops before leaves the next g to read
            ;; again, rather than taking the text for read.
            (setq ecc-review--fingerprint nil)
            (setq fingerprint (cons (secure-hash 'sha1 text) (buffer-chars-modified-tick)))
            (goto-char (point-min))
            ;; The lines are read once, and only when something is to be
            ;; put back on them.
            (let ((lines (and (or ecc-review--notes ecc-review--held) (ecc-review--lines))))
              (ecc-review--take-reading lines)
              (let ((ecc-review--refilling t))
                (ecc-review--draw-notes lines))
              (ecc-review--restore-views views))
            (run-hooks 'ecc-review-refilled-hook)
            ;; Counted one by one: a comment that found its line again does
            ;; not make up for another that lost it.
            (let ((lost (seq-count #'ecc-review-note-outdated placed)))
              (when (> lost 0)
                (message "%s no longer %s a line of the diff; kept as outdated"
                         (ecc-review--count lost "comment")
                         (if (= lost 1) "matches" "match"))))
            (unless (ecc-review--reading-incomplete ecc-review--reading)
              (setq ecc-review--fingerprint fingerprint))
            buffer)
        (ecc-review--let-go (seq-remove (lambda (place) (memq place held))
                                        ecc-review--held))))))

(defun ecc-review--shorten-ids (text)
  "Return the diff TEXT with the blob ids of its index lines short, kept whole.
git is asked for whole ids (`ecc-review--diff-options'), which two
readings of one blob have to share; an index line of two of them is 92
characters, which wraps in half a frame and comes again for every file.
Each id is cut to `ecc-review-shown-id-length' characters, git's own
short form, and the whole id kept on what is left of it as the text
property `ecc-review-blob', which is where the old side of a file is
read from (`ecc-review--base-of').  Nothing else reads an index line: a
hunk's text, which is what is sent to Claude, starts at its @@ line."
  (let ((pieces nil)
        (start 0)
        (short (lambda (id)
                 (if (> (length id) ecc-review-shown-id-length)
                     (propertize (substring id 0 ecc-review-shown-id-length) 'ecc-review-blob id)
                   id))))
    (while (string-match "^index \\([0-9a-f]+\\)\\.\\.\\([0-9a-f]+\\)" text start)
      (push (substring text start (match-beginning 1)) pieces)
      (push (funcall short (match-string 1 text)) pieces)
      (push ".." pieces)
      (push (funcall short (match-string 2 text)) pieces)
      (setq start (match-end 2)))
    (if (null pieces)
        text
      (push (substring text start) pieces)
      (apply #'concat (nreverse pieces)))))

(defun ecc-review--view-at (position)
  "Return (ANCHOR . COLUMN) for POSITION, or nil.
ANCHOR is a note-shaped record of the line POSITION is on -- the @@ line
of the next hunk when it is on a file header -- held to be carried to
the next reading, and COLUMN how far into the line it is.  The line is
read from the hunk there, as \\`c' reads it, and the other hunks of its
file only when nothing else kept on it has had them read in this
reading (`ecc-review--keep').  The caller lets ANCHOR go."
  (save-excursion
    (goto-char position)
    (let ((line (or (ecc-review--line-at-point)
                    (and (re-search-forward ecc-diff-hunk-regexp nil t)
                         (progn (beginning-of-line) (ecc-review--line-at-point))))))
      (when line
        (let ((anchor (ecc-review--anchor (ecc-review-note-create) line)))
          (ecc-review--hold anchor 'view)
          (cons anchor (max 0 (- position (plist-get line :position)))))))))

(defun ecc-review--save-views ()
  "Return where this buffer is being read, to be put back after a redraw.
The answer is a list of (WINDOW ANCHOR COLUMN LINES-FROM-TOP), WINDOW
being nil for the point of the buffer itself, or nil when the buffer is
empty.

Only live windows are seen.  A window in the saved configuration of
another tab -- under `spaces\=', the tab of another Space -- keeps a
point of its own that the erase puts at the top, and nothing here can
reach it: going back to that tab shows the review from its start.  What
is kept for it is the buffer\='s own point, which is where the review
opens when it is opened again, and what `review_navigate\=' says it
kept."
  (when (> (buffer-size) 0)
    (let ((views nil))
      (when-let* ((view (ecc-review--view-at (point))))
        (push (list nil (car view) (cdr view) 0) views))
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (when-let* ((view (ecc-review--view-at (window-point window))))
          (push (list window (car view) (cdr view)
                      (count-lines (window-start window)
                                   (save-excursion
                                     (goto-char (window-point window))
                                     (line-beginning-position))))
                views)))
      views)))

(defun ecc-review--restore-views (views)
  "Put the VIEWS of `ecc-review--save-views\=' back on this reading.
A place whose line went goes to the start of the nearest line that
stayed, and one with no line of its file left to the top."
  (pcase-dolist (`(,window ,anchor ,column ,from-top) views)
    (let* ((own (ecc-review--locate-note anchor))
           (line (or own (ecc-review--nearest-line anchor)))
           (column (if own column 0))
           (position (if line
                         (min (+ (plist-get line :position) column)
                              (save-excursion
                                (goto-char (plist-get line :position))
                                (line-end-position)))
                       (point-min))))
      (if (null window)
          (goto-char position)
        (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
          (set-window-point window position)
          (set-window-start window (save-excursion
                                     (goto-char position)
                                     (forward-line (- from-top))
                                     (point))))))))

;;;; Hunks

(defun ecc-review-hunk-range (header)
  "Return (START . END) of the new side of the hunk HEADER line.
A hunk that only removes lines is one line wide at its position."
  (when (string-match ecc-diff-hunk-regexp header)
    (let ((start (string-to-number (match-string 3 header)))
          (count (if (match-string 4 header)
                     (string-to-number (match-string 4 header))
                   1)))
      (cons start (+ start (max count 1) -1)))))

(defun ecc-review--hunk-bounds ()
  "Return (BEG . END) of the hunk the point is in, or nil.
END is after the newline of the last line.  Nil is returned on a file
header or before the first hunk."
  (save-excursion
    (let ((here (point)))
      (condition-case nil
          (let ((beg (progn (diff-beginning-of-hunk) (point))))
            ;; Point was in front of the hunk found backwards if a file
            ;; header lies between the two.
            (unless (save-excursion
                      (goto-char beg)
                      (re-search-forward "^\\(?:\\+\\+\\+\\|diff \\)" (max here (1+ beg)) t))
              (cons beg (progn (diff-end-of-hunk) (point)))))
        (error nil)))))

(defun ecc-review--hunk-path (beg)
  "Return the file name of the hunk starting at BEG, without a/ or b/.
As git wrote it, a C-quoted name decoded (`ecc-review-git-name')."
  (save-excursion
    (goto-char beg)
    (let* ((names (mapcar #'ecc-review-git-name (diff-hunk-file-names)))
           (new (car names))
           (old (cadr names))
           (name (if (or (null new) (equal new "/dev/null")) old new)))
      (when name
        (replace-regexp-in-string "\\`[ab]/" "" name)))))

(defun ecc-review-hunk-at (beg end &optional path)
  "Return the hunk between BEG and END as a plist.
The plist has :path, :start and :end of the new side, :header, :text
being the whole hunk, :position and :bound, the positions it runs
between.  PATH is the name of its file when the caller has read it
already: read here, it is read from the file's header back up the
hunks before."
  (save-excursion
    (goto-char beg)
    (let* ((header (buffer-substring-no-properties (point) (line-end-position)))
           (range (ecc-review-hunk-range header)))
      (list :path (or path (ecc-review--hunk-path beg))
            :start (car range)
            :end (cdr range)
            :header header
            :text (string-trim-right (buffer-substring-no-properties beg end) "\n")
            :position beg
            :bound end))))

(defun ecc-review--hunk-key (hunk)
  "Return what identifies HUNK across a redraw: its file and its header."
  (cons (plist-get hunk :path) (plist-get hunk :header)))

(defun ecc-review-hunks ()
  "Return every hunk of the current buffer as `ecc-review-hunk-at' plists."
  (save-excursion
    (goto-char (point-min))
    (let ((hunks nil))
      (while (re-search-forward ecc-diff-hunk-regexp nil t)
        (when-let* ((bounds (ecc-review--hunk-bounds)))
          (push (ecc-review-hunk-at (car bounds) (cdr bounds)) hunks)
          (goto-char (max (point) (1- (cdr bounds))))))
      (nreverse hunks))))

;;;; Lines

(defun ecc-review--hunk-lines (hunk)
  "Return the lines of HUNK, a plist of `ecc-review-hunk-at', header first.
Each line is a plist: :position, where it starts; :path; :side, `new'
for an added or a context line, `old' for a removed one and nil for the
@@ header; :line, its number on that side; :old-line, the number a
context line has on the old side as well; :text, the line without its
marker; and :hunk, HUNK itself.

The numbers are counted down from the @@ header the way git counts
them: a removed line takes the next number of the old side, an added
one the next of the new side, a context line one of each.  It is the
count `ecc-visit--unified-line' makes, done here from the markers
rather than from the faces, which a review buffer has only once
font-lock has been round."
  (save-excursion
    (goto-char (plist-get hunk :position))
    (let* ((header (plist-get hunk :header))
           (path (plist-get hunk :path))
           (bound (plist-get hunk :bound))
           (old (if (string-match ecc-diff-hunk-regexp header)
                    (string-to-number (match-string 1 header))
                  1))
           (new (or (plist-get hunk :start) 1))
           (lines (list (list :position (point) :path path :side nil :line nil
                              :text header :hunk hunk))))
      (forward-line 1)
      (while (< (point) bound)
        (let ((position (point))
              (text (buffer-substring-no-properties
                     (min (1+ (point)) (line-end-position)) (line-end-position))))
          (pcase (char-after)
            (?- (push (list :position position :path path :side 'old :line old
                            :text text :hunk hunk)
                      lines)
                (cl-incf old))
            (?+ (push (list :position position :path path :side 'new :line new
                            :text text :hunk hunk)
                      lines)
                (cl-incf new))
            ;; A context line; an empty one is a context line whose
            ;; leading space something on the way trimmed.
            ((or ?\s ?\n)
             (push (list :position position :path path :side 'new :line new
                         :old-line old :text text :hunk hunk)
                   lines)
             (cl-incf new)
             (cl-incf old))))
        (forward-line 1))
      (nreverse lines))))

(defun ecc-review--lines ()
  "Return every line of every hunk of this buffer, as `ecc-review--hunk-lines'."
  (mapcan #'ecc-review--hunk-lines (ecc-review-hunks)))

(defun ecc-review--line-at-point ()
  "Return the line of the diff at point, or nil off a hunk."
  (when-let* ((bounds (ecc-review--hunk-bounds)))
    (let ((bol (line-beginning-position)))
      (seq-find (lambda (line) (= (plist-get line :position) bol))
                (ecc-review--hunk-lines
                 (ecc-review-hunk-at (car bounds) (cdr bounds)))))))

;;;; Comments

(cl-defstruct (ecc-review-note (:constructor ecc-review-note-create)
                               (:copier nil))
  "One comment of a review, kept apart from how it is drawn.
The place is kept as a line of the diff rather than as a position, so
that the comment can be carried to the next reading of the diff
\(`ecc-review--take-reading\='): PATH, SIDE and LINE name the line, NTH
which of the lines of that side and number it is (`ecc-review-map-shape',
0 but in a diff that joins a patch for each edit), and LINE-TEXT is
what it said; on a whole hunk, NTH is which of the hunks with its
header it is.  SIDE is nil for a comment on a whole hunk.  HUNK-KEY, HUNK-RANGE and HUNK-TEXT are the
hunk it was in when last found -- its key, the lines of its new side
and its text, which is what an outdated comment is still sent with.
SHAPE is the shape of the reading the comment is on, or, outdated, was
last on (`ecc-review-map-shape'): the next reading, of this review or of
the one it is handed to, carries it from there.  SENT is non-nil once a
prompt has carried the comment to Claude: it stays in the review, drawn
dimmed, for Claude\='s replies to answer, and the next
\\[ecc-review-send] leaves it out."
  id              ; an integer, unique in the buffer and never reused
  author          ; `user' or `claude'
  path side line line-text
  nth             ; how many lines of the file before it share its side and number
  hunk-key hunk-range hunk-text
  text
  reply-to        ; the id of the comment this one answers, or nil
  outdated        ; non-nil when no line of the diff matches any more
  shape           ; the shape of the reading it is on, or was last on
  sent)           ; non-nil once a prompt has carried it

(defun ecc-review--agent-p (note)
  "Return non-nil when NOTE is one of Claude's."
  (eq (ecc-review-note-author note) 'claude))

(defun ecc-review-find-note (id)
  "Return the comment of this buffer whose id is ID, or nil."
  (seq-find (lambda (note) (eql (ecc-review-note-id note) id)) ecc-review--notes))

(defun ecc-review--parent (note)
  "Return the comment NOTE answers, when it is still there."
  (when-let* ((id (ecc-review-note-reply-to note)))
    (ecc-review-find-note id)))

(defun ecc-review--shown-p (note)
  "Return non-nil when NOTE is drawn: Claude's are hidden by `a'."
  (or ecc-review--show-agent (not (ecc-review--agent-p note))))

(defun ecc-review--visible-p (note)
  "Return non-nil when NOTE is drawn: shown, and on a file the filter keeps."
  (and (ecc-review--shown-p note)
       (not (ecc-review-hidden-p (ecc-review-note-path note)))))

(defun ecc-review--drawn-under (note)
  "Return the comment NOTE is drawn under, or nil when it stands alone."
  (when-let* ((parent (ecc-review--parent note)))
    (and (ecc-review--shown-p parent) parent)))

(defun ecc-review--anchor (note line)
  "Put NOTE on LINE, a plist of `ecc-review--hunk-lines' of this reading.
Return NOTE.  From then on a comment on that line is carried to every
reading of the review that follows (`ecc-review--take-reading'), and so
is any other place while it is held (`ecc-review--holding').  LINE is
taken as the reading has it, which says which of the lines with its
number it is."
  (let* ((line (ecc-review--canonical line))
         (hunk (plist-get line :hunk)))
    (setf (ecc-review-note-path note) (plist-get line :path)
          (ecc-review-note-nth note) (plist-get line :nth)
          (ecc-review-note-side note) (plist-get line :side)
          (ecc-review-note-line note) (plist-get line :line)
          (ecc-review-note-line-text note) (and (plist-get line :side)
                                                (plist-get line :text))
          (ecc-review-note-hunk-key note) (ecc-review--hunk-key hunk)
          (ecc-review-note-hunk-range note) (cons (plist-get hunk :start)
                                                  (plist-get hunk :end))
          (ecc-review-note-hunk-text note) (plist-get hunk :text)
          (ecc-review-note-outdated note) nil)
    (ecc-review--keep note)))

;;;; Readings, and carrying a place from one to the next

;; A comment, the place being read and the line \\`c' was pressed on are
;; each kept as a line of one reading of the diff -- a path, a side and a
;; number -- and every reading is a new diff.  A reading is made in one
;; place, `ecc-review--take-reading', which the diff review calls when it
;; is filled and the ediff review when ediff has computed the
;; differences, and that is where every place is carried to it, all at
;; once, by where each line of the last reading of its file is in this
;; one (`ecc-review-map-lines').  So a place moves with lines put in or
;; taken out above it, wherever they were, and one whose line changed or
;; went is outdated, never put on a line that only reads alike.
;;
;; Looking a place up never carries anything: it reads the reading, and
;; only while the reading is of the text the review shows.  Between the
;; text changing and its reading being taken -- or after a key that got
;; past the keymap edited the buffer -- there is no reading to look in,
;; and a lookup is an error rather than a line of something else.
;;
;; The comments are carried for as long as they are in the review; the
;; place being read and the line \\`c' was pressed on only while they are
;; held, across the one refill or the one comment they are for.  Each
;; place keeps the shape of the reading it is on, and is carried from
;; there -- a comment handed to another review too -- and a reading keeps
;; the lines of the files something is on, and of no other.

(cl-defstruct (ecc-review--reading (:constructor ecc-review--reading-create)
                                   (:copier nil))
  "One reading of what a review shows, made by `ecc-review--take-reading'.
TEXT is the text it was made of, as `ecc-review--text' says it, and
`pending' while the review is being read again.  SHAPES is a hash of
each path something is on to its `ecc-review-map-shape' in this
reading.  FILES and INDEX are the lines of those files and of no other,
by path and by place, read when a place is first looked for in one.
INCOMPLETE is non-nil when something could not be carried to it -- a
failure, or git not answering -- for the review to be read again whole
by the next \\`g' rather than taken for read (`ecc-review--fall-short');
UNANSWERED the repositories git failed to read the old sides of in this
reading, which it is not asked again.  UNITS is the hunks of the review
by file (`ecc-review--units-by-path'), gone through once, when a file is
first wanted -- or, while the reading is taken, made from the lines the
caller read (`ecc-review--units-of')."
  text shapes files index units positions incomplete unanswered)

(defvar-local ecc-review--reading nil
  "The reading of this review its places are on, nil before the first.")

(defvar-local ecc-review--held nil
  "The places other than comments carried to each reading, for now.
The place being read across a refill, the line \\`c' was pressed on
while the comment is typed, the difference being read across a reading
of an ediff review; each is let go once it has been put back.")

(defvar-local ecc-review--views nil
  "The places held that are the place being read, for `ecc-review--restore-views'.
Only these go to the nearest line that stayed when their own went.")

(defvar-local ecc-review--nearest nil
  "A weak hash of each held place whose line went to the nearest line that stayed.
That line is (SIDE . NUMBER); the place being read goes there when its
own line has gone.")

(defvar-local ecc-review--base-diffs nil
  "A hash of each pair of old blobs, (FROM . TO), to how the one became the other.
What `ecc-review--base-hunks' found, failures included: two blobs do not
change, so neither does their diff, and git is asked once, and a
failure said once.")

(defun ecc-review--forget-places ()
  "Forget what this review keeps to carry its places: it reviews something else.
A place still held -- the line \\`c' was pressed on, while the comment
is typed -- is a line of what was reviewed before, and no line of what
is now: it is marked `replaced', for what holds it to say so."
  (dolist (place ecc-review--held)
    (setf (ecc-review-note-outdated place) 'replaced
          (ecc-review-note-shape place) nil))
  (setq ecc-review--reading nil
        ecc-review--held nil
        ecc-review--views nil
        ecc-review--nearest nil
        ecc-review--base-diffs nil))

(cl-defgeneric ecc-review--text ()
  "Return what says which text this review shows; it changes with the text.
For a diff review, the characters of its buffer."
  (buffer-chars-modified-tick))

(defun ecc-review--reading-current-p ()
  "Return non-nil when this review has a reading of the text it shows."
  (and ecc-review--reading
       (eq (ecc-review--reading-text ecc-review--reading) (ecc-review--text))))

(defun ecc-review--fall-short (reading)
  "Mark READING, of this review, as one something could not be carried to.
The next \\`g' reads the review again whole: what it was filled with is
not taken for read any more (`ecc-review--fingerprint'), whenever this
is found out -- while the review is filled, or later, when comments are
handed to it (`ecc-review--receive')."
  (setf (ecc-review--reading-incomplete reading) t)
  (setq ecc-review--fingerprint nil))

(defun ecc-review--begin-reading ()
  "Note that what this review shows is about to be read again.
Until `ecc-review--take-reading' nothing can be looked up: what is there
is neither the last reading nor the next."
  (when ecc-review--reading
    (setf (ecc-review--reading-text ecc-review--reading) 'pending)))

(defun ecc-review--take-reading (&optional lines)
  "Make what this review shows now its reading, and carry every place to it.
This is where a reading is made, and the only one: the diff review
calls it once filled (`ecc-review--fill'), the ediff review once ediff
has computed the differences.  Every comment and every place held is
carried at once, from the reading each was last on
\(`ecc-review--carry'); the lines of a file are read only when something
is on it.  LINES, all the lines of the review when the caller has read
them, give the hunks of each file for the carrying, which then does not
go through the review again; they are not kept."
  (let ((reading (ecc-review--reading-create :text 'pending
                                             :shapes (make-hash-table :test #'equal)
                                             :files (make-hash-table :test #'equal)
                                             :index (make-hash-table :test #'equal)
                                             :positions (make-hash-table :test #'equal)
                                             :units (and lines (ecc-review--units-of lines))))
        (places (append ecc-review--notes ecc-review--held)))
    (setq ecc-review--reading reading)
    (if places
        (ecc-review--carry-to places reading)
      (setf (ecc-review--reading-text reading) (ecc-review--text)))
    ;; The hunks of every file are not kept: a file wanted later is
    ;; found by going through the review (`ecc-review--units-by-path').
    (when lines
      (setf (ecc-review--reading-units reading) nil))
    reading))

(defun ecc-review--carry-to (places reading)
  "Carry PLACES to READING, of what this review shows, which is its reading then.
Until every place is carried, READING is of no text (`pending'), and
nothing can be looked up in it: a place not carried yet would be found
by numbers of another reading, on a line that only reads alike, and
put there for good.  So a carrying that stops part of the way -- quit
while git is read, or an error no file's carrying caught -- leaves the
review to be read again whole (`ecc-review--fall-short'), each place
still on the reading it was last on."
  (let ((text (ecc-review--text))
        (done nil))
    (setf (ecc-review--reading-text reading) 'pending)
    (unwind-protect
        (progn
          (ecc-review--carry places reading)
          (ecc-review--prune reading)
          (setq done t))
      (if done
          (setf (ecc-review--reading-text reading) text)
        (ecc-review--fall-short reading)))))

(defun ecc-review--units-of (lines)
  "Return `ecc-review--units-by-path' for the review LINES are all the lines of."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (line lines)
      (unless (plist-get line :side)
        (push (plist-get line :hunk) (gethash (plist-get line :path) table))))
    (maphash (lambda (key units) (puthash key (nreverse units) table)) table)
    table))

(defun ecc-review--this-reading ()
  "Return the reading of this review, the one of the text it shows.
A review not read yet has its first reading made now.  One whose text
changed since its reading -- being read again, or edited by a key that
got past its keymap -- has none, and that is an error: a line looked up
there would be a line of something else."
  (cond ((null ecc-review--reading) (ecc-review--take-reading))
        ((ecc-review--reading-current-p) ecc-review--reading)
        (t (error "%s changed since it was read; g reads it again" (buffer-name)))))

(cl-defgeneric ecc-review--unit-lines (unit)
  "Return the lines of UNIT, a hunk of `ecc-review-units', header first."
  (ecc-review--hunk-lines unit))

(cl-defgeneric ecc-review--units-by-path ()
  "Return a hash of each file of this review to its hunks, in order.
A hunk is there as where it begins, made into a hunk by
`ecc-review--unit-at' when its file is wanted.  The review is gone
through once, and a file's name read once, at its header -- reading it
at every hunk would go back through all the hunks before it."
  (let ((table (make-hash-table :test #'equal))
        (path nil)
        (after nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward ecc-diff-hunk-regexp nil t)
        (when-let* ((bounds (ecc-review--hunk-bounds)))
          (let ((beg (car bounds)))
            ;; A file header since the last hunk begins another file.
            (when (or (null after)
                      (save-excursion
                        (goto-char beg)
                        (re-search-backward "^\\(?:diff \\|\\+\\+\\+ \\)" after t)))
              (setq path (ecc-review--hunk-path beg)))
            (push beg (gethash path table))
            (setq after (cdr bounds))
            (goto-char (max (point) (1- (cdr bounds))))))))
    (maphash (lambda (key starts) (puthash key (nreverse starts) table)) table)
    table))

(cl-defgeneric ecc-review--unit-at (item &optional path)
  "Return the hunk ITEM of `ecc-review--units-by-path' stands for.
ITEM is where the hunk begins, or the hunk itself (`ecc-review--units-of');
PATH is the file `ecc-review--units-by-path' has it under, whose name is
not read again."
  (if (not (integerp item))
      item
    (save-excursion
      (goto-char item)
      (end-of-line)
      (when-let* ((bounds (ecc-review--hunk-bounds)))
        (ecc-review-hunk-at (car bounds) (cdr bounds) path)))))

(defun ecc-review--file-of (reading path)
  "Return the lines of the file PATH in READING, reading them the first time.
This is what the lines of a file are, everywhere: the hunks the review
has under PATH (`ecc-review--units-by-path'), numbered
\(`ecc-review-map-number') and kept in READING's index, by place."
  (let ((files (ecc-review--reading-files reading)))
    (pcase (gethash path files 'unread)
      ('unread
       (let ((own (mapcan (lambda (item) (ecc-review--unit-lines (ecc-review--unit-at item path)))
                          (gethash path (or (ecc-review--reading-units reading)
                                            (setf (ecc-review--reading-units reading)
                                                  (ecc-review--units-by-path))))))
             (index (ecc-review--reading-index reading)))
         (dolist (line (ecc-review-map-number own))
           (puthash (ecc-review--line-key line) line index)
           (puthash (ecc-review--position-key line) line
                    (ecc-review--reading-positions reading)))
         (puthash path own files)))
      (own own))))

(defun ecc-review--line-key (line)
  "Return the key of LINE in the index of a reading.
\(PATH SIDE NUMBER NTH) for a line, (hunk PATH HEADER NTH) for the header
of a hunk (`ecc-review-map-shape' says what NTH is)."
  (ecc-review--place-key (plist-get line :path) (plist-get line :side)
                         (if (plist-get line :side)
                             (plist-get line :line)
                           (plist-get (plist-get line :hunk) :header))
                         (plist-get line :nth)))

(defun ecc-review--place-key (path side number nth)
  "Return the key of a place in the index of a reading: see `ecc-review--line-key'.
The place is of the file PATH, on SIDE, numbered NUMBER, the NTH of
those; NUMBER is the header of the hunk for a place on a whole hunk,
SIDE nil."
  (if side
      (list path side number (or nth 0))
    (list 'hunk path number (or nth 0))))

(defun ecc-review--canonical (line)
  "Return LINE as this reading has it, which says its NTH.
LINE is a line of the review now, read from the buffer by whatever read
it; the reading's own line at the same place is the one that knows which
of the lines with its number it is."
  (if (plist-member line :nth)
      line
    (let ((reading (ecc-review--this-reading)))
      (ecc-review--file-of reading (plist-get line :path))
      (or (gethash (ecc-review--position-key line) (ecc-review--reading-positions reading))
          line))))

(defun ecc-review--position-key (line)
  "Return where LINE is, as the reading finds a line by it.
Its position and buffer, and its side: in an ediff review the line
standing for a difference is where its first line of the right side is."
  (list (plist-get line :position) (plist-get line :buffer) (plist-get line :side)))

(defun ecc-review--forget-file (reading path)
  "Drop the lines of the file PATH from READING: nothing is on it any more."
  (let ((index (ecc-review--reading-index reading)))
    (dolist (line (gethash path (ecc-review--reading-files reading)))
      (remhash (ecc-review--line-key line) index)
      (remhash (ecc-review--position-key line) (ecc-review--reading-positions reading)))
    (remhash path (ecc-review--reading-files reading))
    (remhash path (ecc-review--reading-shapes reading))))

(defun ecc-review--line-of (place)
  "Return the line of this reading PLACE names, by its path, side and number.
The header of its hunk for a place on a whole hunk."
  (let* ((reading (ecc-review--this-reading))
         (path (ecc-review-note-path place))
         (side (ecc-review-note-side place)))
    (ecc-review--file-of reading path)
    (gethash (ecc-review--place-key path side
                                    (if side
                                        (ecc-review-note-line place)
                                      (cdr (ecc-review-note-hunk-key place)))
                                    (ecc-review-note-nth place))
             (ecc-review--reading-index reading))))

(defun ecc-review--hold (place &optional view)
  "Carry PLACE, put on a line by `ecc-review--anchor', until it is let go.
VIEW non-nil says PLACE is the place being read."
  (when place
    (push place ecc-review--held)
    (when view
      (push place ecc-review--views))))

(defun ecc-review--let-go (places)
  "Stop carrying PLACES, held by `ecc-review--hold'."
  (setq ecc-review--held (seq-remove (lambda (place) (memq place places))
                                     ecc-review--held)
        ecc-review--views (seq-remove (lambda (place) (memq place places))
                                      ecc-review--views))
  (when ecc-review--nearest
    (dolist (place places)
      (remhash place ecc-review--nearest))))

(defmacro ecc-review--holding (place &rest body)
  "Run BODY with PLACE carried to every reading of the review meanwhile.
PLACE is let go when BODY is done, however it ends."
  (declare (indent 1) (debug t))
  (let ((held (make-symbol "held"))
        (buffer (make-symbol "buffer")))
    `(let ((,held ,place)
           (,buffer (current-buffer)))
       (ecc-review--hold ,held)
       (unwind-protect (progn ,@body)
         (when (buffer-live-p ,buffer)
           (with-current-buffer ,buffer
             (ecc-review--let-go (list ,held))))))))

(cl-defgeneric ecc-review--base-of (hunk)
  "Return the old side of the file HUNK is in, as a shape keeps it.
HUNK is the first hunk of its file.  In a diff git made the old side is
a blob, (blob REPOSITORY ID), named on the index line of the file's own
header: from its --- line up through git's extended header lines to its
diff line, which has to name the file -- an empty file git added or
deleted has a header and no --- line, and its index line is not the
next file's.  `empty' is no file.

A proposal's diff names the old side it was made against on its own
header, as the text property `ecc-review-old-side': (proposal HASH) of
the file as the proposal found it, or nil when its hunks are numbered
against nothing known (`ecc-review-request-diff').  What the session
recorded of the file is not that file: it may have changed since.

Another file with no diff line of its own was diffed from what the
session recorded (`ecc-review-fallback-diff').  When the session knows what the
file held before its first change, that is the old side of every
reading, (recorded HASH); when it does not, the diff joins a patch for
each edit and says nothing of an old side, which is nil."
  (save-excursion
    (goto-char (plist-get hunk :position))
    (forward-line -1)
    (when (looking-at-p "\\+\\+\\+ ")
      (forward-line -1))
    (when (looking-at-p "--- ")
      (let ((path (plist-get hunk :path))
            (named (get-text-property (point) 'ecc-review-old-side))
            (id nil)
            (from nil)
            (to nil))
        (while (and (zerop (forward-line -1))
                    (looking-at "\\(?:index \\([0-9a-f]+\\)\\.\\.\\|\\(?:old\\|new\\|deleted file\\|new file\\) mode \\|similarity \\|dissimilarity \\|\\(?:rename\\|copy\\) \\(?:\\(from\\)\\|to\\) \\(.*\\)\\)"))
          (cond ((match-beginning 1)
                 ;; Whole, as git gave it, under the short one shown.
                 (setq id (or (get-text-property (match-beginning 1) 'ecc-review-blob)
                              (match-string-no-properties 1))))
                ((match-beginning 3)
                 (if (match-beginning 2)
                     (setq from (ecc-review-git-name (match-string-no-properties 3)))
                   (setq to (ecc-review-git-name (match-string-no-properties 3)))))))
        ;; A diff line above that names another file is that file's: a
        ;; file git shows no hunk of -- a mode, an empty file, a rename
        ;; -- ends right above, and this file has no header of its own.
        (cond ((and id path
                    (equal (cdr (ecc-review-git-diff-names
                                 (buffer-substring-no-properties (point) (line-end-position))
                                 from to))
                           (concat "b/" path)))
               (if (string-match-p "\\`0+\\'" id)
                   'empty
                 (list 'blob (ecc-review--repository-of path) id)))
              (named (car named))
              (path (ecc-review--recorded-base path)))))))

(defvar ecc-review--original-hashes (make-hash-table :test #'eq :weakness 'key)
  "A weak hash of each original a session recorded to its sha1.
An original is the text of a file before its first change, kept once
by its entry; it is hashed once, not at every reading of every review.")

(defun ecc-review--recorded-base (path)
  "Return the old side of PATH from what the session of this review recorded.
\(recorded HASH) of what the file held before its first change, `empty'
for a file the session created, nil when that is not known.  The entry
is the session's own for the path, as it was named or as this review
names it; one that saw no operation -- a call denied or still waiting --
records nothing (`ecc-model-files')."
  (when-let* ((session ecc-review--session)
              (files (ecc-session-files session))
              (entry (or (gethash (expand-file-name path default-directory) files)
                         (gethash path files)))
              ((> (+ (ecc-file-entry-reads entry) (ecc-file-entry-edits entry)
                     (ecc-file-entry-writes entry))
                  0)))
    (pcase (ecc-file-entry-original entry)
      ((and original (pred stringp))
       (list 'recorded (or (gethash original ecc-review--original-hashes)
                           (puthash original (secure-hash 'sha1 original)
                                    ecc-review--original-hashes))))
      ('nil 'empty))))

(defun ecc-review--repository-of (path)
  "Return the repository the file PATH of this review is in.
The directory above it that holds .git, found without running git;
this review's own directory when there is none."
  (ecc-review-repository-name
   (or (locate-dominating-file (expand-file-name path default-directory) ".git")
       default-directory)))

(defun ecc-review-repository-name (directory)
  "Return the name a blob's repository DIRECTORY goes by in an old side.
Its true name, as a directory: `locate-dominating-file' gives back the
name it was asked about, abbreviated, and a directory reached through a
link has two names, and the same blob of the same repository has to be
the same old side whichever review read it."
  (file-name-as-directory (file-truename directory)))

(defun ecc-review--shape-of (lines)
  "Return the shape of LINES, the lines of one file, nil for none."
  (when lines
    (ecc-review-map-shape lines (ecc-review--base-of (plist-get (car lines) :hunk)))))

(defun ecc-review--shape-now (reading path)
  "Return the shape of the file PATH in READING, taking it the first time."
  (let ((shapes (ecc-review--reading-shapes reading)))
    (or (gethash path shapes)
        (when-let* ((shape (ecc-review--shape-of (ecc-review--file-of reading path))))
          (puthash path shape shapes)))))

(defun ecc-review--keep (place)
  "Keep PLACE, just put on a line of this reading, and return it.
PLACE takes the shape of its file in this reading, which the next
reading carries it from (`ecc-review--carry'); the lines of the file are
read then, and kept with the reading."
  (setf (ecc-review-note-shape place)
        (ecc-review--shape-now (ecc-review--this-reading) (ecc-review-note-path place)))
  place)

(defun ecc-review--base-hunks (from to reading)
  "Return how the old side FROM became TO, for `ecc-review-map-lines'.
The hunks between the two blobs, from what this review kept of them
\(`ecc-review--diff-blobs'); nil for one old side; `none' when one of
them is no file; `text' when one of them is not known to be a blob, or
the two are blobs of two repositories, so that the old sides are not
known to have anything in common; `unknown' when git cannot give them.
TO is the old side of a file in READING, which a pair git did not give
leaves to be read again (`ecc-review--fall-short')."
  (cond ((not (and from to)) 'text)
        ((equal from to) nil)
        ((or (eq from 'empty) (eq to 'empty)) 'none)
        ((and (eq (car-safe from) 'blob) (eq (car-safe to) 'blob)
              (equal (nth 1 from) (nth 1 to)))
         (let ((pair (cons (nth 2 from) (nth 2 to)))
               (kept (lambda (pair)
                       (if ecc-review--base-diffs
                           (gethash pair ecc-review--base-diffs 'unasked)
                         'unasked))))
           (when (eq (funcall kept pair) 'unasked)
             (ecc-review--diff-blobs (nth 1 from) (list pair) reading))
           ;; No hunks is two blobs that differ in nothing a line says --
           ;; a newline put at the end -- and one old side.
           (pcase (funcall kept pair)
             ;; Not given this time; asked again the next.
             ('unasked
              (ecc-review--fall-short reading)
              'unknown)
             (hunks hunks))))
        (t 'text)))

(defun ecc-review--diff-blobs (repository pairs reading)
  "Keep in `ecc-review--base-diffs' how each of PAIRS of blobs became the other.
PAIRS are (FROM . TO) blob ids of REPOSITORY.  Every blob is read
through one git process (`ecc-review--blobs') and the two of a pair
compared here (`ecc-review-map-text-hunks'): a reading that moved the old
side of forty files runs git once, not forty times.  A blob git does not
have makes its pairs `unknown' for good, a blob does not come to be; so
does one over `ecc-review-max-bytes', which is not read.
git failing to run at all keeps nothing: the repository is not asked
again in READING, which is left to be read again, and the next reading
asks again."
  (unless ecc-review--base-diffs
    (setq ecc-review--base-diffs (make-hash-table :test #'equal)))
  (let* ((wanted (and (not (member repository (ecc-review--reading-unanswered reading)))
                      (seq-remove (lambda (pair)
                                    (not (eq (gethash pair ecc-review--base-diffs 'unasked)
                                             'unasked)))
                                  pairs)))
         (texts (and wanted
                     (ecc-review--blobs repository
                                        (delete-dups (mapcan (lambda (pair)
                                                               (list (car pair) (cdr pair)))
                                                             (copy-sequence wanted)))))))
    (when (and wanted (null texts))
      (push repository (ecc-review--reading-unanswered reading))
      (ecc-review--fall-short reading))
    (when texts
      (dolist (pair wanted)
        (let ((from (gethash (car pair) texts))
              (to (gethash (cdr pair) texts)))
          ;; A failure comparing two blobs is that pair's alone, and is
          ;; not kept: the next reading compares them again.
          (condition-case error
              (puthash pair
                       (cond ((and (stringp from) (stringp to))
                              (ecc-review-map-text-hunks from to))
                             ((or (eq from 'too-large) (eq to 'too-large))
                              (ecc-log "review" "not comparing %s and %s in %s: over %d bytes"
                                       (car pair) (cdr pair) repository ecc-review-max-bytes)
                              'unknown)
                             (t
                              (ecc-log "review" "no blob %s or %s in %s"
                                       (car pair) (cdr pair) repository)
                              'unknown))
                       ecc-review--base-diffs)
            (error (ecc-log "review" "comparing %s and %s failed: %S"
                            (car pair) (cdr pair) error))))))))

(defun ecc-review--blobs (repository ids)
  "Return a hash of each of IDS to the text of its blob in REPOSITORY.
The sizes are asked first, by `git cat-file --batch-check', and the
blobs within `ecc-review-max-bytes' read by one `git cat-file --batch'
\(`ecc-review--cat-file'), as the ediff review reads its sides: a larger
one is `too-large', never read, for comparing two of them line by line
in Lisp would hold Emacs up for seconds.  An id that is no blob git has
is not in the hash.  Nil when git cannot be run."
  (let ((texts (make-hash-table :test #'equal))
        (small nil))
    (and (ecc-review--cat-file repository ids "--batch-check"
                               (lambda (id type size)
                                 (when (equal type "blob")
                                   (if (> size ecc-review-max-bytes)
                                       (puthash id 'too-large texts)
                                     (push id small)))))
         (or (null small)
             (ecc-review--cat-file repository (nreverse small) "--batch"
                                   (lambda (id type _size bytes)
                                     (when (equal type "blob")
                                       (puthash id bytes texts)))))
         texts)))

(defun ecc-review--cat-file (root ids option each)
  "Run `git cat-file OPTION' in ROOT on IDS and call EACH on what it says.
OPTION is \"--batch-check\" or \"--batch\".  EACH is called with an
id, its type and its size, and under --batch with its bytes as well, a
unibyte string; nothing is called for an id git does not have.  Return
non-nil when git was run and answered; a git that fails is logged, and
the answer is nil.  The diff review reads the blobs of its old sides
with this (`ecc-review--blobs'), the ediff review those of both sides."
  (cond
   ((null ids) nil)
   ((not (executable-find ecc-git-executable))
    (ecc-log "review" "cat-file %s: no %s to run in %s" option ecc-git-executable root)
    nil)
   (t
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (mapconcat #'identity ids "\n") "\n")
      (let* ((default-directory (file-name-as-directory root))
             (coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (code (condition-case error
                       (call-process-region (point-min) (point-max)
                                            ecc-git-executable
                                            t '(t nil) nil "cat-file" option)
                     (file-error (error-message-string error)))))
        (if (not (eq code 0))
            (progn (ecc-log "review" "cat-file %s failed in %s: %S" option root code)
                   nil)
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
                    (goto-char (min (point-max) (1+ end))))))))
          t))))))

(defun ecc-review--map-from (from to maps reading)
  "Return where each line of the shape FROM is in TO (`ecc-review-map-lines').
TO is of READING, and MAPS keeps each map made in it by FROM, so that
one is made once, whatever number of places is carried from it."
  (pcase (gethash from maps)
    ('nil (puthash from
                   (condition-case error
                       (ecc-review-map-lines
                        from to (ecc-review--base-hunks (ecc-review-map-shape-base from)
                                                        (ecc-review-map-shape-base to)
                                                        reading))
                     (error (cons 'failed error)))
                   maps)
          (ecc-review--map-from from to maps reading))
    (`(failed . ,error) (signal (car error) (cdr error)))
    (map map)))

(defun ecc-review--carry (places reading)
  "Carry PLACES to READING, each from the reading it was last on.
A place keeps the shape of the reading it is on, or, outdated, was last
on (`ecc-review-note-shape'): that is where it is carried from, whatever
review that reading was of.  A place on a line goes to the number its
line has now, and one on a whole hunk to the hunk its lines are in now
\(`ecc-review--hunk-goes').  A place whose line changed or went is
outdated, keeping that shape, and comes back when its line, carried from
there, is in a later reading: the change was undone.  The places of one
shape are carried as one (`ecc-review--carry-file'), and one outdated
before this reading is looked for once all the others were carried.  A
place that is not outdated and has no shape was not put on a line here
or anywhere -- its numbers are of no reading known -- and is outdated,
which the log says."
  (let ((maps (make-hash-table :test #'eq))
        (placed nil)
        (lost nil))
    (dolist (place places)
      (let ((shape (ecc-review-note-shape place)))
        (cond ((ecc-review-note-outdated place)
               (when shape
                 (push place (alist-get shape lost nil nil #'eq))))
              (shape (push place (alist-get shape placed nil nil #'eq)))
              (t (ecc-log "review" "comment %S on %s has no reading to be carried from"
                          (ecc-review-note-id place) (ecc-review-note-path place))
                 (setf (ecc-review-note-outdated place) t)))))
    (setq placed (nreverse placed)
          lost (nreverse lost))
    (let ((shapes (ecc-review--shapes-for (append placed lost) reading)))
      (ecc-review--diff-moved-blobs (append placed lost) shapes reading)
      (pcase-dolist (`(,from . ,group) placed)
        (ecc-review--carry-file (nreverse group) from reading maps shapes))
      (pcase-dolist (`(,from . ,group) lost)
        (ecc-review--carry-file (nreverse group) from reading maps shapes t)))))

(defun ecc-review--shapes-for (groups reading)
  "Return the shape in READING of each file GROUPS are on, taken once.
GROUPS are (SHAPE . PLACES).  The answer is a hash of each path to
\(shape . SHAPE), SHAPE nil for a file READING does not show, or to
\(failed . ERROR) when its lines could not be read or its shape taken:
the carrying of that file says so (`ecc-review--carry-file')."
  (let ((shapes (make-hash-table :test #'equal)))
    (pcase-dolist (`(,_from . ,group) groups)
      (let ((path (ecc-review-note-path (car group))))
        (unless (gethash path shapes)
          (puthash path
                   (condition-case error
                       (cons 'shape (ecc-review--shape-now reading path))
                     (error (cons 'failed error)))
                   shapes))))
    shapes))

(defun ecc-review--diff-moved-blobs (groups shapes reading)
  "Diff at once every old blob GROUPS are carried from that READING moved.
GROUPS are (SHAPE . PLACES) and SHAPES the shape of each of their files
in READING (`ecc-review--shapes-for'); a file whose old side is another
blob now is diffed with the others of its repository
\(`ecc-review--diff-blobs'), before any is carried."
  (let ((pairs nil))
    (pcase-dolist (`(,from . ,group) groups)
      (pcase-let ((`(,kind . ,to) (gethash (ecc-review-note-path (car group)) shapes))
                  (base (ecc-review-map-shape-base from)))
        (when (and (eq kind 'shape) to)
          (let ((now (ecc-review-map-shape-base to)))
            (when (and (eq (car-safe base) 'blob) (eq (car-safe now) 'blob)
                       (equal (nth 1 base) (nth 1 now))
                       (not (equal (nth 2 base) (nth 2 now))))
              (push (cons (nth 2 base) (nth 2 now)) (alist-get (nth 1 base) pairs nil nil #'equal)))))))
    (pcase-dolist (`(,repository . ,wanted) pairs)
      ;; A failure here is the repository's: it is not asked again for
      ;; each file, and the files of it carry nothing through a moved
      ;; old side this time.
      (condition-case error
          (ecc-review--diff-blobs repository wanted reading)
        (error (ecc-log "review" "reading the old sides in %s failed: %S" repository error)
               (push repository (ecc-review--reading-unanswered reading))
               (ecc-review--fall-short reading))))))

(defun ecc-review--prune (reading)
  "Keep in READING the lines and shapes of the files places are on, and no other.
The places are the comments of this review and the places held; one
that is outdated is on no line of READING, but for the place being
read, which is put back on the nearest line that stayed, in its file,
once the reading is taken (`ecc-review--restore-views')."
  (let ((wanted (make-hash-table :test #'equal))
        (paths nil))
    (dolist (place (append ecc-review--notes ecc-review--held))
      (unless (and (ecc-review-note-outdated place)
                   (not (memq place ecc-review--views)))
        (puthash (ecc-review-note-path place) t wanted)))
    (maphash (lambda (path _) (push path paths)) (ecc-review--reading-files reading))
    (dolist (path paths)
      (unless (gethash path wanted)
        (ecc-review--forget-file reading path)))))

(defun ecc-review--receive (notes)
  "Carry NOTES, handed over from another review, to this one's reading.
Each is carried from the reading it was last on, as at a reading of this
review (`ecc-review--carry'): one that went outdated there comes back
here when its line is here."
  (ecc-review--carry-to notes (ecc-review--this-reading)))

(defun ecc-review--carry-file (places from reading maps shapes &optional back)
  "Carry PLACES, all on the reading of the shape FROM, to READING.
MAPS keeps the maps made in READING, and SHAPES the shape there of the
file of PLACES, or why it could not be taken (`ecc-review--shapes-for').
Where each place goes is worked out for all of them -- the map made,
each line looked for -- before any moves, so that a failure leaves every
one where it was: outdated, keeping FROM, and why in the log.  Without
BACK a place whose line is not there is outdated; with BACK, PLACES are
outdated already and come back when their line is there."
  (let* ((path (ecc-review-note-path (car places)))
         (moves (condition-case error
                    (let* ((to (pcase (gethash path shapes)
                                 (`(shape . ,shape) shape)
                                 (`(failed . ,error) (signal (car error) (cdr error)))))
                           (map (and to (ecc-review--map-from from to maps reading)))
                           (index (ecc-review--reading-index reading)))
                      (mapcar (lambda (place)
                                (list place (ecc-review--where place from map index back) to))
                              places))
                  (error
                   (ecc-log "review" "carrying the comments on %s failed: %S" path error)
                   (ecc-review--fall-short reading)
                   (mapcar (lambda (place) (list place (cons 'lost nil) nil)) places)))))
    (pcase-dolist (`(,place ,where ,to) moves)
      (pcase where
        (`(line . ,line)
         (if (plist-get line :side)
             (setf (ecc-review-note-line place) (plist-get line :line))
           (setf (ecc-review-note-hunk-key place) (ecc-review--hunk-key (plist-get line :hunk))))
         (setf (ecc-review-note-nth place) (plist-get line :nth)
               (ecc-review-note-shape place) to
               (ecc-review-note-outdated place) nil))
        (`(lost . ,nearest)
         (unless back
           (ecc-review--lose place nearest)))))))

(defun ecc-review--carried (map index path side number nth)
  "Return the line of this reading, among INDEX, MAP carries a line to, or nil.
The line is that of PATH and SIDE numbered NUMBER, the NTH of those, in
the reading MAP carries from."
  (when-let* ((to (funcall map side number nth)))
    (gethash (ecc-review--place-key path side (car to) (cdr to)) index)))

(defun ecc-review--where (place from map index &optional back)
  "Return where PLACE, on a line of the reading of FROM, is in this one.
\(line . LINE), LINE the line of this reading -- the header of the hunk
for a place on a whole hunk -- by MAP among the lines of INDEX; else
\(lost . NEAREST): NEAREST is the nearest line that stayed, worked out
for the place being read and still placed -- not BACK -- and for no
other: nothing else goes there."
  (let ((path (ecc-review-note-path place))
        (side (ecc-review-note-side place)))
    (or (and map
             (if side
                 (let ((line (ecc-review--carried map index path side
                                                  (ecc-review-note-line place)
                                                  (ecc-review-note-nth place))))
                   (and line (equal (plist-get line :text) (ecc-review-note-line-text place))
                        (cons 'line line)))
               (when-let* ((header (ecc-review--hunk-goes
                                    path (cdr (ecc-review-note-hunk-key place))
                                    (or (ecc-review-note-nth place) 0) from map index)))
                 (cons 'line header))))
        (cons 'lost (and map (not back) (memq place ecc-review--views)
                         (ecc-review--nearest-to place from map index))))))

(defun ecc-review--hunk-goes (path header nth from map index)
  "Return the header of the hunk of this reading the hunk HEADER of FROM is now.
That hunk, of the file PATH, is the NTH of FROM with that header.  Its
changed lines -- the ones it takes out and puts in, not the context
around them -- are carried one by one, by MAP among the lines of
INDEX.  When half of them or more changed again or went, it is another
hunk now, and the answer is nil; otherwise it is the hunk most of the
rest are in, the first of those on a tie."
  (let* ((members (seq-filter (lambda (member)
                                (ecc-review-map-changed-p from (car member) (cadr member)
                                                          (cddr member)))
                              (cdr (assoc (cons header nth) (ecc-review-map-shape-hunks from)))))
         (stayed 0)
         (votes nil))
    (dolist (member members)
      (when-let* ((line (ecc-review--carried map index path (car member)
                                             (cadr member) (cddr member))))
        (setq stayed (1+ stayed))
        (let* ((key (cons (plist-get (plist-get line :hunk) :header) (plist-get line :hunk-nth)))
               (vote (assoc key votes)))
          (if vote
              (setcdr vote (1+ (cdr vote)))
            (push (cons key 1) votes)))))
    (when (> (* 2 stayed) (length members))
      (let ((best (car (seq-reduce (lambda (best vote) (if (> (cdr vote) (cdr best)) vote best))
                                   (cdr (reverse votes)) (car (last votes))))))
        (gethash (ecc-review--place-key path nil (car best) (cdr best)) index)))))

(defun ecc-review--nearest-to (place from map index)
  "Return the line nearest the one PLACE was on in FROM that this reading has.
\(SIDE NUMBER . NTH), by MAP among the lines of INDEX, or nil: that line
itself first -- the first line of a hunk, for a place on a hunk, may
have stayed -- then the one after it, since that is where its place
went, then the one before, and so on outwards."
  (let* ((order (vconcat (ecc-review-map-shape-order from)))
         (path (ecc-review-note-path place))
         (side (ecc-review-note-side place))
         (nth (or (ecc-review-note-nth place) 0))
         (here (if side
                   (cons side (cons (ecc-review-note-line place) nth))
                 (cadr (assoc (cons (cdr (ecc-review-note-hunk-key place)) nth)
                              (ecc-review-map-shape-hunks from)))))
         (at (seq-position order here)))
    (when at
      (catch 'found
        (dotimes (away (length order))
          (dolist (other (if (zerop away)
                             (list at)
                           (list (+ at away) (- at away))))
            (when (< -1 other (length order))
              (let* ((member (aref order other))
                     (line (ecc-review--carried map index path (car member)
                                                (cadr member) (cddr member))))
                (when line
                  (throw 'found (cons (plist-get line :side)
                                      (cons (plist-get line :line) (plist-get line :nth)))))))))))))

(defun ecc-review--lose (place nearest)
  "Mark PLACE outdated: its line is not in this reading.
PLACE keeps the shape it was on, to come back by, and NEAREST, the
nearest line that stayed, is kept for the place being read to go to."
  (setf (ecc-review-note-outdated place) t)
  (when nearest
    (unless ecc-review--nearest
      (setq ecc-review--nearest (make-hash-table :test #'eq :weakness 'key)))
    (puthash place nearest ecc-review--nearest)))

(defun ecc-review--locate-note (note)
  "Return the line of this reading NOTE is on, or nil when it is outdated.
NOTE is on the line of its path and side with its number, saying what it
said, or, on a whole hunk, on the hunk of its path with its header: the
reading carried it there when it was taken."
  (unless (ecc-review-note-outdated note)
    (let ((line (ecc-review--line-of note)))
      (and line
           (or (null (ecc-review-note-side note))
               (equal (plist-get line :text) (ecc-review-note-line-text note)))
           line))))

(defun ecc-review--nearest-line (place)
  "Return the line of this reading nearest the line of PLACE that stayed, or nil.
That is the line the reading found when PLACE lost its own."
  (when-let* ((nearest (and ecc-review--nearest (gethash place ecc-review--nearest))))
    (let ((reading (ecc-review--this-reading))
          (path (ecc-review-note-path place)))
      (ecc-review--file-of reading path)
      (gethash (ecc-review--place-key path (car nearest) (cadr nearest) (cddr nearest))
               (ecc-review--reading-index reading)))))

(defun ecc-review--relocate ()
  "Put every comment back on its line of this reading and return where each went.
The answer is a hash of each comment to its line, nil for an outdated
one.  A reply goes wherever the comment it answers went; the comments
are in the order they were made, so that one is placed first."
  (let ((places (make-hash-table :test #'eq)))
    (dolist (note ecc-review--notes)
      (let* ((parent (ecc-review--parent note))
             (line (if parent
                       (gethash parent places)
                     (ecc-review--locate-note note))))
        (if line
            (ecc-review--anchor note line)
          (setf (ecc-review-note-outdated note) t))
        (puthash note line places)))
    places))

(defun ecc-review--place (note line lines)
  "Return (BEG END PROPERTY) of the overlay NOTE, placed on LINE, is drawn with.
LINES are all the lines of the buffer, where an outdated one is placed.
A comment on a line is drawn under the line and one on a hunk under the
hunk.  An outdated one has no line: it is drawn above the first hunk of
its file, right under the file header, or at the top when the file has
gone from the diff altogether."
  (cond
   ((and line (plist-get line :side))
    (let ((beg (plist-get line :position)))
      (list beg (save-excursion (goto-char beg) (forward-line 1) (point))
            'after-string)))
   (line
    (let ((hunk (plist-get line :hunk)))
      (list (plist-get hunk :position) (plist-get hunk :bound) 'after-string)))
   (t
    (let* ((first (seq-find (lambda (line)
                              (equal (plist-get line :path)
                                     (ecc-review-note-path note)))
                            lines))
           (beg (if first (plist-get first :position) (point-min))))
      (list beg beg 'before-string)))))

(defun ecc-review-note-lines (note)
  "Return the lines NOTE is about: \"L42 (new)\", or \"L10-L14\" for a hunk."
  (if (ecc-review-note-side note)
      (format "L%d (%s)" (ecc-review-note-line note) (ecc-review-note-side note))
    (let ((range (ecc-review-note-hunk-range note)))
      (format "L%s-L%s" (car range) (cdr range)))))

(defun ecc-review-note-where (note)
  "Return where NOTE is: \"foo.el:42 (new)\", or \"foo.el L10-L14\" for a hunk."
  (if (ecc-review-note-side note)
      (format "%s:%d (%s)" (ecc-review-note-path note) (ecc-review-note-line note)
              (ecc-review-note-side note))
    (concat (ecc-review-note-path note) " " (ecc-review-note-lines note))))

(defun ecc-review--children (note)
  "Return the shown replies to NOTE, in the order they were made."
  (seq-filter (lambda (other)
                (and (ecc-review--shown-p other)
                     (eq (ecc-review--drawn-under other) note)))
              ecc-review--notes))

(defun ecc-review--note-string (note depth)
  "Return NOTE as it is drawn, DEPTH replies deep, with its replies under it."
  (let* ((agent (ecc-review--agent-p note))
         (prefix (concat (make-string (+ 2 (* 2 depth)) ?\s) "▎ "))
         (head (concat (format "#%d " (ecc-review-note-id note))
                       (and agent "Claude: ")
                       (and (ecc-review-note-outdated note)
                            (format "[outdated, was %s] "
                                    (ecc-review-note-lines note)))
                       (and (ecc-review-note-reply-to note)
                            (not (ecc-review--drawn-under note))
                            (format "[reply to #%d] " (ecc-review-note-reply-to note))))))
    (concat
     (propertize (concat prefix head
                         (string-replace "\n" (concat "\n" prefix)
                                         (ecc-review-note-text note))
                         "\n")
                 'face (cond (agent 'ecc-review-agent-comment-face)
                             ((ecc-review-note-sent note) 'ecc-review-sent-comment-face)
                             (t 'ecc-review-comment-face)))
     (mapconcat (lambda (child) (ecc-review--note-string child (1+ depth)))
                (ecc-review--children note) ""))))

(defun ecc-review--subtree (note)
  "Return NOTE and every shown reply under it."
  (cons note (mapcan #'ecc-review--subtree (ecc-review--children note))))

(defvar-local ecc-review--positions nil
  "Hash of each comment to where it was drawn last, hidden ones included.")

(defun ecc-review--draw-notes (&optional lines)
  "Draw the comments of this buffer again from `ecc-review--notes'.
Every comment is put back first (`ecc-review--relocate'), so this is
also what keeps them in place across a refresh.  LINES are the lines of
the buffer when the caller has read them already; with no comment there
is nothing to read them for.  Return non-nil once drawn.

A review whose text changed since its reading -- a reading that
stopped, a key that got past the keymap -- has nowhere to put a
comment: what is drawn is left as it is, the echo area says that \`g'
reads the review again (`ecc-review--undrawn'), and the answer is nil.
That is no error: the callers draw after what they came to do -- a
prompt sent, a comment removed, a loop over the reviews of a pull
request -- and that is done either way."
  (if (and ecc-review--notes ecc-review--reading (not (ecc-review--reading-current-p)))
      (progn (message "%s" (ecc-review--undrawn))
             nil)
    (mapc #'delete-overlay ecc-review--comments)
    (mapc #'delete-overlay ecc-review--decorations)
    (setq ecc-review--comments nil
          ecc-review--decorations nil
          ecc-review--positions (make-hash-table :test #'eq))
    (run-hooks 'ecc-review-before-draw-hook)
    (when ecc-review--notes
      (ecc-review--draw-notes-on (or lines (ecc-review-lines))))
    (run-hooks 'ecc-review-after-draw-hook)
    (force-mode-line-update)
    t))

(defun ecc-review--undrawn ()
  "Return what to say of comments not drawn: the review is to be read again."
  (format "%s changed since it was read: g reads it again and draws its comments"
          (buffer-name)))

(defun ecc-review--and-drawn (drawn)
  "Return \"\" when DRAWN, what `ecc-review--draw-notes' answered.
Otherwise the notice that the comments wait for \\`g', to follow a
message that would hide the one the drawing gave."
  (if drawn "" (concat "; " (ecc-review--undrawn))))

(defun ecc-review--draw-notes-on (lines)
  "Draw the comments of this buffer on LINES, the lines it holds now.
Where each goes is the kind of review's own (`ecc-review--note-place\=');
the overlays are made there, in whichever buffer that is, and kept here."
  (let* ((places (ecc-review--relocate))
         (groups nil)
         (commented nil))
    (dolist (note ecc-review--notes)
      (pcase-let ((`(,buffer ,beg ,end ,property ,key)
                   (ecc-review--note-place note (gethash note places) lines)))
        (puthash note key ecc-review--positions)
        (when (ecc-review--visible-p note)
          (when-let* (((not (ecc-review-note-outdated note)))
                      (line (gethash note places)))
            (cl-pushnew (ecc-review--hunk-place line) commented :test #'equal))
          (unless (ecc-review--drawn-under note)
            (push note (alist-get (list buffer beg end property) groups
                                  nil nil #'equal))))))
    (pcase-dolist (`((,buffer ,beg ,end ,property) . ,roots) (nreverse groups))
      (let ((overlay (make-overlay beg end buffer t nil))
            (roots (nreverse roots)))
        (overlay-put overlay 'ecc-review-notes (mapcan #'ecc-review--subtree roots))
        (overlay-put overlay property
                     (mapconcat (lambda (note) (ecc-review--note-string note 0))
                                roots ""))
        (push overlay ecc-review--comments)))
    (setq ecc-review--decorations (ecc-review--decorate commented lines))))

(defun ecc-review-comment-overlays ()
  "Return the live overlays drawing the comments of this buffer."
  (setq ecc-review--comments (seq-filter #'overlay-buffer ecc-review--comments)))

(defun ecc-review-note-position (note)
  "Return where NOTE was drawn last, or would have been when hidden.
In a diff review that is a position of its buffer; in an ediff review
it is the KEY of `ecc-review--note-place\=', a position in the order of
the review."
  (and ecc-review--positions (gethash note ecc-review--positions)))

(defun ecc-review--copy-anchor (note from)
  "Put NOTE where the comment FROM is, outdated or not, and return NOTE.
It is carried from the reading FROM is on, and comes back by it."
  (dolist (slot '(path side line line-text nth hunk-key hunk-range hunk-text outdated shape))
    (setf (cl-struct-slot-value 'ecc-review-note slot note)
          (cl-struct-slot-value 'ecc-review-note slot from)))
  note)

(defun ecc-review-add-note (author text line &optional reply-to)
  "Add a comment by AUTHOR saying TEXT on LINE and return it.
LINE is a plist of `ecc-review--hunk-lines', or a note whose place the
comment takes.  With REPLY-TO, the id of the comment answered, LINE may
be nil and the reply goes where that one is.  The comment is not drawn
yet: `ecc-review--draw-notes\=' does that, once for however many are
added."
  (let* ((parent (and reply-to (or (ecc-review-find-note reply-to)
                                   (error "No comment #%s" reply-to))))
         (note (ecc-review-note-create :id ecc-review--next-id :author author
                                       :text text :reply-to reply-to)))
    (cond ((ecc-review-note-p line) (ecc-review--copy-anchor note line))
          (line (ecc-review--anchor note line))
          (t (ecc-review--copy-anchor note parent)))
    (cl-incf ecc-review--next-id)
    (setq ecc-review--notes (append ecc-review--notes (list note)))
    note))

(cl-defgeneric ecc-review--note-removed (_note)
  "Forget what this review kept about the comment NOTE, which is gone."
  nil)

(defun ecc-review-remove-note (note)
  "Take NOTE out of this review; draw again afterwards.
Its replies stay, drawn on their own: a reply of the user\='s is the
user\='s whatever happens to what it answered."
  (ecc-review--note-removed note)
  (setq ecc-review--notes (delq note ecc-review--notes)))

(defun ecc-review--notes-on (line)
  "Return the shown comments that sit on LINE, in the order they were made."
  (let* ((line (ecc-review--canonical line))
         (side (plist-get line :side)))
    (seq-filter (lambda (note)
                  (and (ecc-review--shown-p note)
                       (not (ecc-review-note-outdated note))
                       (equal (ecc-review-note-path note) (plist-get line :path))
                       (eq (ecc-review-note-side note) side)
                       (eql (or (ecc-review-note-nth note) 0) (plist-get line :nth))
                       (if side
                           (eql (ecc-review-note-line note) (plist-get line :line))
                         (equal (ecc-review-note-hunk-key note)
                                (ecc-review--hunk-key (plist-get line :hunk))))))
                ecc-review--notes)))

(defun ecc-review--comment-target (line)
  "Return what \\`c' on LINE does to the comments there.
\(edit . NOTE) for the last comment of yours on it, else (reply . NOTE)
for the last of Claude\='s, else nil for a comment of its own."
  (let ((notes (ecc-review--notes-on line)))
    (if-let* ((own (car (last (seq-remove #'ecc-review--agent-p notes)))))
        (cons 'edit own)
      (when-let* ((claude (car (last (seq-filter #'ecc-review--agent-p notes)))))
        (cons 'reply claude)))))

(defmacro ecc-review--keeping-text (text &rest body)
  "Run BODY, which puts the comment TEXT in the review; when it fails, keep TEXT.
What was typed goes to the kill ring and the error says so, whatever
stopped it -- the review read again meanwhile, another proposal, a quit
-- rather than going with the comment.  An empty TEXT is nothing to
keep.  BODY ends once the comment is in: what comes after, drawing it
included, is no failure to keep it (`ecc-review--comment-made')."
  (declare (indent 1) (debug t))
  (let ((typed (make-symbol "typed")))
    `(let ((,typed ,text))
       (condition-case error
           (progn ,@body)
         ((error quit)
          (if (string-empty-p (string-trim ,typed))
              (signal (car error) (cdr error))
            (kill-new ,typed)
            (if (eq (car error) 'quit)
                (progn (message "The comment is in the kill ring")
                       (signal 'quit nil))
              (user-error "%s; the comment is in the kill ring"
                          (error-message-string error)))))))))

(defun ecc-review--comment-plan (line)
  "Return what \\`c' on LINE is to do, settled before anything is typed.
The answer is (ANCHOR KIND ID): ANCHOR a note-shaped record of LINE,
KIND `edit', `reply' or nil for a comment of its own, and ID the comment
edited or answered."
  (let ((target (ecc-review--comment-target line)))
    (list (ecc-review--anchor (ecc-review-note-create) line)
          (car target)
          (and target (ecc-review-note-id (cdr target))))))

(defun ecc-review--read-comment (line)
  "Settle what \\`c' on LINE does and read the text; return (TEXT PLAN).
The arguments of `ecc-review-comment\\=', read the way it reads them: the
plan first, then the comment, offered for editing when it is one of
yours already.  The line is held while the text is typed: the diff
read again meanwhile carries it along."
  (let* ((plan (ecc-review--comment-plan line))
         (target (and (nth 2 plan) (ecc-review-find-note (nth 2 plan)))))
    (list (ecc-review--holding (car plan)
            (pcase (nth 1 plan)
              ('edit (read-string "Comment: " (ecc-review-note-text target)))
              ('reply (read-string (format "Reply to Claude's #%d: " (nth 2 plan))))
              (_ (read-string (if (plist-get line :side)
                                  "Comment on this line: "
                                "Comment on this hunk: ")))))
          plan)))

(defun ecc-review-comment (text &optional plan)
  "Put the comment TEXT on the line at point.
On the @@ header of a hunk the comment is about the whole hunk; on a
removed line it is about the old side, on an added or a context line
about the new.  Where the line carries a comment of yours already, TEXT
replaces it, and interactively that one is offered for editing.  Where
it carries only Claude\='s, TEXT is your reply to the last of them.
Returns the comment.

PLAN is what `ecc-review--comment-plan\=' decided when the command was
started.  Interactively it is taken before the text is read, because
the buffer does not stand still while it is typed: Claude may put a
comment on the same line, or the diff may be read again and the line
move.  The comment goes where it was meant for -- a comment of its own
does not turn into a reply to what arrived meanwhile -- on the line
carried to where it went (`ecc-review--take-reading\='), and when that
line has changed or gone it is kept as outdated rather than lost with
the text."
  (interactive
   (let ((line (or (ecc-review--line-at-point)
                   (user-error "Not on a line of a hunk"))))
     (ecc-review--read-comment line)))
  (ecc-review--comment-made
   (ecc-review--keeping-text text
     (pcase-let* ((`(,anchor ,kind ,id)
                   (or plan (ecc-review--comment-plan
                             (or (ecc-review--line-at-point)
                                 (user-error "Not on a line of a hunk")))))
                  (text (string-trim text))
                  (target (and id (ecc-review-find-note id))))
       (when (string-empty-p text)
         (user-error "Empty comment"))
       (when (eq (ecc-review-note-outdated anchor) 'replaced)
         (user-error "The review shows another proposal now"))
       ;; Only a comment of its own needs its line: an edit changes the
       ;; text of one that is somewhere already, whatever the reading.
       (if (and (eq kind 'edit) target)
           (ecc-review--edit-note target text)
         (ecc-review-add-note 'user text (or (ecc-review--locate-note anchor) anchor)
                              (and (eq kind 'reply) target id)))))
   "The line has gone from the diff; the comment is kept as outdated"))

(defun ecc-review--comment-made (note gone)
  "Draw the comments, NOTE just made or edited among them; say so and return NOTE.
GONE is what to say when the place NOTE is on has gone.  NOTE is in the
review already, and a failure from here is said as what it is: what
was typed is not put in the kill ring, to be yanked into a second copy."
  (condition-case error
      (ecc-review--draw-notes)
    (error (error "Comment #%d is in the review, but drawing the comments failed: %s"
                  (ecc-review-note-id note) (error-message-string error))))
  (if (ecc-review-note-outdated note)
      (message "%s" gone)
    (message "Comment attached (%d in all)"
             (seq-count (lambda (note) (not (ecc-review--agent-p note)))
                        ecc-review--notes)))
  note)

(defun ecc-review--notes-here ()
  "Return the shown comments on the line at point, in the order they were made.
Those drawn from this line -- on it, on its hunk when it is the @@
header, outdated ones above the first hunk of a file -- and otherwise
the comments on the whole of the hunk point is in."
  (let* ((bol (line-beginning-position))
         (overlays (ecc-review-comment-overlays))
         (notes (or (mapcan (lambda (overlay)
                              (and (= (overlay-start overlay) bol)
                                   (copy-sequence (overlay-get overlay 'ecc-review-notes))))
                            overlays)
                    (mapcan (lambda (overlay)
                              (and (<= (overlay-start overlay) (point))
                                   (< (point) (overlay-end overlay))
                                   (seq-filter (lambda (note)
                                                 (and (null (ecc-review-note-side note))
                                                      (not (ecc-review-note-outdated note))))
                                               (overlay-get overlay 'ecc-review-notes))))
                            overlays))))
    (sort notes (lambda (a b) (< (ecc-review-note-id a) (ecc-review-note-id b))))))

(defun ecc-review-note-label (note)
  "Return the one line label of NOTE: id, author, place and text."
  (format "#%d [%s] %s%s: %s"
          (ecc-review-note-id note)
          (if (ecc-review--agent-p note) "Claude" "you")
          (ecc-review-note-where note)
          (if (ecc-review-note-outdated note) " (outdated)" "")
          (ecc--truncate (ecc-review-note-text note) 60)))

(defun ecc-review--pick-note (notes prompt &optional always)
  "Return the one of NOTES asked for with PROMPT, or the only one.
With ALWAYS the only one is asked about too: NOTES were not chosen by
where point is, and a lone comment elsewhere is not to go unasked."
  (if (or (cdr notes) always)
      (let* ((labels (mapcar #'ecc-review-note-label notes))
             (choice (completing-read prompt labels nil t)))
        (nth (seq-position labels choice) notes))
    (car notes)))

(defun ecc-review-remove-comment (&optional all)
  "Remove a comment on the line at point, whoever wrote it.
When the line carries more than one, which is asked.  With a prefix
argument ALL every comment of the review is offered, wherever point is."
  (interactive "P")
  (let* ((here (and (not all) (ecc-review--notes-here)))
         (note (ecc-review--pick-note
                (cond (here)
                      ((not all) (user-error "No comment on this line; C-u d offers them all"))
                      ((ecc-review--ordered (seq-filter #'ecc-review--visible-p
                                                        ecc-review--notes)))
                      (t (user-error "No comment in this review")))
                "Remove comment: "
                (not here))))
    (ecc-review-remove-note note)
    (let ((drawn (ecc-review--draw-notes)))
      (message "Comment #%d removed (%d left)%s" (ecc-review-note-id note)
               (length ecc-review--notes) (ecc-review--and-drawn drawn)))))

(defun ecc-review--key (key)
  "Return KEY, a KEY of `ecc-review--note-place\=', as a list of numbers.
A position alone is (POSITION 0 0); an ediff review gives several
comments one position and tells them apart by the rest of the list."
  (if (consp key) key (list key 0 0)))

(defun ecc-review--key< (a b)
  "Return non-nil when the KEY A comes before the KEY B."
  (let ((a (ecc-review--key a))
        (b (ecc-review--key b)))
    (while (and a b (= (car a) (car b)))
      (setq a (cdr a) b (cdr b)))
    (and a b (< (car a) (car b)))))

(defun ecc-review--ordered (notes)
  "Return NOTES in the order of the review, then in the order they were made."
  (sort (copy-sequence notes)
        (lambda (a b)
          (let ((pa (or (ecc-review-note-position a) most-positive-fixnum))
                (pb (or (ecc-review-note-position b) most-positive-fixnum)))
            (or (ecc-review--key< pa pb)
                (and (not (ecc-review--key< pb pa))
                     (< (ecc-review-note-id a) (ecc-review-note-id b))))))))

(defun ecc-review-note-beyond (from forward)
  "Return the first comment past FROM, after it when FORWARD, else before.
FROM is a position in the order of the review, a KEY of
`ecc-review--note-place\=' (`ecc-review-reading-position\=').  The
comments are walked by where they are drawn, Claude\='s hidden ones
included; of several in one place, the one made first.  Those on a
file the filter hides are passed over."
  (let* ((notes (seq-filter (lambda (note)
                              (and (ecc-review-note-position note)
                                   (not (ecc-review-hidden-p (ecc-review-note-path note)))))
                            (ecc-review--ordered ecc-review--notes)))
         (positions (mapcar #'ecc-review-note-position notes))
         (position (if forward
                       (seq-find (lambda (p) (ecc-review--key< from p)) positions)
                     (car (last (seq-filter (lambda (p) (ecc-review--key< p from))
                                            positions))))))
    (and position
         (seq-find (lambda (note) (equal (ecc-review-note-position note) position))
                   notes))))

(defun ecc-review--note-plist (note)
  "Return NOTE as the plist `ecc-review-format-message\=' takes."
  (let ((range (ecc-review-note-hunk-range note))
        (parent (ecc-review--parent note)))
    (append (list :path (ecc-review-note-path note)
                  :start (car range) :end (cdr range)
                  :header (cdr (ecc-review-note-hunk-key note))
                  :text (ecc-review-note-hunk-text note)
                  :position (ecc-review-note-position note)
                  :comment (ecc-review-note-text note)
                  :id (ecc-review-note-id note))
            (when (ecc-review-note-side note)
              (list :side (ecc-review-note-side note)
                    :line (ecc-review-note-line note)))
            (when (ecc-review-note-reply-to note)
              (list :reply-to (ecc-review-note-reply-to note)
                    :reply-author (and parent (ecc-review-note-author parent))
                    :reply-text (and parent (ecc-review-note-text parent))))
            (when (ecc-review-note-outdated note)
              (list :outdated t)))))

(defun ecc-review--edit-note (note text)
  "Make TEXT the text of NOTE and return NOTE.
A comment that had been sent is one to send again: what Claude read is
not what it says any more."
  (setf (ecc-review-note-text note) text
        (ecc-review-note-sent note) nil)
  note)

(defun ecc-review--unsent-notes ()
  "Return your comments of this buffer that no prompt has carried yet."
  (seq-remove (lambda (note)
                (or (ecc-review--agent-p note) (ecc-review-note-sent note)))
              ecc-review--notes))

(defun ecc-review-comments ()
  "Return your comments of this buffer not sent yet, in the order of the diff.
Claude\='s are left out: they are what Claude wrote, and the prompt is
what you have to say.  So are those a prompt has carried already
\(`ecc-review-note-sent'): they stay in the review for Claude's replies,
and Claude has read them.  Each is a plist: :path, :start and :end of the
hunk\='s new side, :header, :text being the whole hunk, :position and
:comment; one on a line adds :side and :line, a reply :reply-to,
:reply-author and :reply-text, and one that matches no line of the diff
any more :outdated, its :text then being the hunk as it last was."
  (mapcar #'ecc-review--note-plist
          (ecc-review--ordered (ecc-review--unsent-notes))))

(defun ecc-review--comment-label (comment)
  "Return the one line label of COMMENT used in the list."
  (format "%s  L%s-L%s: %s"
          (or (plist-get comment :path) "?")
          (plist-get comment :start) (plist-get comment :end)
          (ecc--truncate (plist-get comment :comment) 60)))

(defun ecc-review-list-comments ()
  "Pick one of the comments, either author's, and move to it."
  (interactive)
  (let* ((notes (or (ecc-review--ordered (seq-filter #'ecc-review--visible-p
                                                     ecc-review--notes))
                    (user-error "No comment yet")))
         (note (ecc-review--pick-note notes "Comment: ")))
    (goto-char (or (ecc-review-note-position note) (point-min)))))

(defun ecc-review--comment-positions ()
  "Return where the comments are drawn, in order, each place once."
  (sort (delete-dups (mapcar #'overlay-start (ecc-review-comment-overlays))) #'<))

(defun ecc-review-next-comment ()
  "Move to the next place in the diff that carries a comment."
  (interactive)
  (goto-char (or (seq-find (lambda (position) (> position (point)))
                           (ecc-review--comment-positions))
                 (user-error "No comment below"))))

(defun ecc-review-previous-comment ()
  "Move to the previous place in the diff that carries a comment."
  (interactive)
  (goto-char (or (car (last (seq-filter (lambda (position) (< position (point)))
                                        (ecc-review--comment-positions))))
                 (user-error "No comment above"))))

(defun ecc-review-toggle-agent ()
  "Show or hide Claude\='s comments.
Hidden, they are still counted in the header line.  They are never
part of the prompt, shown or not."
  (interactive)
  (setq ecc-review--show-agent (not ecc-review--show-agent))
  (let ((drawn (ecc-review--draw-notes)))
    (message "%s%s"
             (if ecc-review--show-agent
                 "Showing Claude's comments"
               "Hiding Claude's comments")
             (ecc-review--and-drawn drawn))))

;;;; The message

(defun ecc-review--fence (text)
  "Return a fence line that TEXT cannot close early."
  (let ((fence "```"))
    (while (string-search fence text)
      (setq fence (concat fence "`")))
    fence))

(defun ecc-review-format-message (comments &optional header)
  "Return the prompt carrying COMMENTS as one block each.
COMMENTS are the plists of `ecc-review-comments'; HEADER replaces
`ecc-review-header'.

A block is headed by the file and the lines: \"L10-L14\" for a comment
on a whole hunk, \"L42 (new)\" for one on a line, with \"(outdated)\"
after it when the line is no longer in the diff.  The whole hunk
follows either way, so that the line is read in its surroundings, and a
reply quotes the comment it answers before its own."
  (concat
   (or header ecc-review-header) "\n\n"
   (mapconcat (lambda (comment)
                (let ((fence (ecc-review--fence (plist-get comment :text))))
                  (format "## %s  %s%s\n%sdiff\n%s\n%s\n%sComment: %s"
                          (or (plist-get comment :path) "?")
                          (if (plist-get comment :side)
                              (format "L%d (%s)" (plist-get comment :line)
                                      (plist-get comment :side))
                            (format "L%d-L%d" (plist-get comment :start)
                                    (plist-get comment :end)))
                          (if (plist-get comment :outdated) " (outdated)" "")
                          fence (plist-get comment :text) fence
                          (ecc-review--reply-line comment)
                          (plist-get comment :comment))))
              comments "\n\n")))

(defun ecc-review--reply-line (comment)
  "Return the line saying which comment COMMENT answers, or \"\"."
  (let ((id (plist-get comment :reply-to)))
    (cond
     ((null id) "")
     ((plist-get comment :reply-text)
      (format "In reply to %s #%d: %s\n"
              (if (eq (plist-get comment :reply-author) 'claude) "Claude's" "your")
              id (plist-get comment :reply-text)))
     (t (format "In reply to #%d, which has since been removed\n" id)))))

(defun ecc-review-buffer-message ()
  "Return the prompt for the comments of the current review buffer, or nil.
A review whose right side is not on disk says so under the first line
\(`ecc-review-elsewhere-note')."
  (when-let* ((comments (funcall ecc-review--comments-function)))
    (ecc-review-format-message
     comments
     (cond (ecc-review--request ecc-review-proposal-header)
           (ecc-review--elsewhere
            (concat ecc-review-header "\n"
                    (format ecc-review-elsewhere-note
                            (ecc-review--range-name ecc-review--range ecc-review--label)
                            ecc-review--elsewhere)))))))

;;;;; Confirming before sending

(defvar-local ecc-review-message--review nil
  "The review buffer whose comments this message carries.")

(defvar-local ecc-review-message--sent-function nil
  "What settles the reviews this message was made from once it is sent, or nil.
Nil leaves `ecc-review-message--review' to `ecc-review--after-send'; a
message made from the comments of several reviews marks theirs sent
\(`ecc-review-pr-send-all').")

(defvar-local ecc-review-message--notes nil
  "The comments this message was made from, marked sent once it goes.
Those of the review when the message was opened: one added while it is
read over is not in the text, and is left for the next send.")

(defvar ecc-review-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-review-message-send)
    (define-key map (kbd "C-c C-k") #'ecc-review-message-cancel)
    map)
  "Keymap of `ecc-review-message-mode'.")

(defalias 'ecc-review-message--parent-mode
  (if (require 'markdown-mode nil t) 'markdown-mode 'text-mode)
  "The mode `ecc-review-message-mode' is derived from.")

(define-derived-mode ecc-review-message-mode ecc-review-message--parent-mode
  "Claude-Review-Message"
  "Major mode of the buffer the review prompt is confirmed in.

\\{ecc-review-message-mode-map}"
  :interactive nil
  (setq header-line-format
        (propertize " C-c C-c sends, C-c C-k goes back; the text may be edited" 'face 'ecc-dim-face)))

(defun ecc-review-message-buffer-name (session)
  "Return the name of the confirmation buffer of SESSION."
  (format "*ecc-review-message: %s*" (ecc-session-name session)))

(defun ecc-review--deliver (session text request)
  "Send TEXT to SESSION, as a prompt or as the refusal of REQUEST.
REQUEST non-nil makes TEXT the message of the deny of that proposal
instead of a prompt of its own.  Signals a `user-error\=' when there is
nothing to send or the proposal has been answered already."
  (when (string-empty-p text)
    (user-error "The message is empty"))
  (cond
   (request
    (unless (memq request (ecc-session-pending session))
      (user-error "This proposal was answered already"))
    (ecc-perm-respond request 'deny :message text)
    (message "Denied with comments: %s" (ecc-request-tool-name request)))
   (t
    (let ((outcome (ecc-proc-send-prompt session text)))
      (if (eq outcome 'sent)
          (message "Review comments sent")
        (message "A turn is running; queued at position %d" outcome))))))

(defun ecc-review-send (&optional edit)
  "Send the comments of this review not sent yet as one prompt.
The review stays open, and the comments in it, drawn dimmed: Claude
answers them there with replies, and \\[ecc-review-send] again sends only
those made since.  In the review of a proposal they are sent as the
message of the deny instead, and the review is closed, the proposal
being answered.  With a prefix argument EDIT the prompt is opened in a
buffer of its own first, to be read over and changed before it goes:
the comments are the prompt, so the common case is to send them as
they stand, and the key that says send sends."
  (interactive "P")
  (let ((session (or ecc-review--session (user-error "Not a review buffer"))))
    (ecc-review-send-text session
                          (or (ecc-review-buffer-message)
                              (user-error (if (seq-some #'ecc-review-note-sent
                                                        ecc-review--notes)
                                              "Nothing to send: every comment has been sent"
                                            "No comment to send; put one on a hunk with c")))
                          (current-buffer) edit)))

(defun ecc-review--after-send (review notes)
  "Settle REVIEW once a prompt made from its comments NOTES has gone.
The review of a proposal is closed: the proposal has been answered.  A
review of files stays open, NOTES marked sent and drawn again."
  (when (buffer-live-p review)
    (if (buffer-local-value 'ecc-review--request review)
        (ecc-review--close review)
      (with-current-buffer review
        (dolist (note notes)
          (setf (ecc-review-note-sent note) t))
        (ecc-review--draw-notes)
        (force-mode-line-update)))))

(defun ecc-review-send-text (session text review &optional edit sent)
  "Send TEXT, made from the comments of REVIEW not sent yet, to SESSION.
As the deny of the proposal REVIEW is of, if it is one, and REVIEW is
closed; otherwise REVIEW stays open, those comments marked sent
\(`ecc-review--after-send').  With EDIT the text is opened in a buffer
of its own first, to be read over and changed before it goes, and
\\<ecc-review-message-mode-map>\\[ecc-review-message-cancel] there
goes back to REVIEW.  SENT, a function of no argument, settles what TEXT
was made from once it has gone, in place of settling REVIEW alone.
Return TEXT when it was sent."
  (let ((request (buffer-local-value 'ecc-review--request review))
        (notes (with-current-buffer review (ecc-review--unsent-notes))))
    (if (not edit)
        (progn (ecc-review--deliver session text request)
               (if sent (funcall sent) (ecc-review--after-send review notes))
               text)
      (let ((buffer (get-buffer-create (ecc-review-message-buffer-name session))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (ecc-review-message-mode)
            (insert text)
            (setq ecc-render--session session
                  ecc-review-message--review review
                  ecc-review-message--notes notes
                  ecc-review-message--sent-function sent)
            (set-buffer-modified-p nil)
            (goto-char (point-min))))
        (pop-to-buffer buffer)
        nil))))

(defun ecc-review-message-send ()
  "Send the text of this buffer and go back to the review it came from.
The comments it was made from are marked sent there.  The review of a
proposal is closed instead, the proposal being answered by the deny."
  (interactive)
  (let* ((review ecc-review-message--review)
         (session (or ecc-render--session (user-error "Not a review message")))
         (text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (request (and (buffer-live-p review)
                       (buffer-local-value 'ecc-review--request review)))
         (sent ecc-review-message--sent-function)
         (notes ecc-review-message--notes)
         (message-buffer (current-buffer)))
    (ecc-review--deliver session text request)
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer message-buffer)
    (if sent (funcall sent) (ecc-review--after-send review notes))
    (when (and (buffer-live-p review) (not request))
      (with-current-buffer review
        (ecc-review-go-back)))
    text))

(defun ecc-review-message-cancel ()
  "Drop this message and go back to the review buffer."
  (interactive)
  (let ((review ecc-review-message--review))
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer (current-buffer))
    (when (buffer-live-p review)
      (with-current-buffer review
        (ecc-review-go-back)))))

;;;; Opening a review

(defun ecc-review-session ()
  "Return the session a review command is about, or signal an error."
  (or ecc-review--session ecc-render--session
      (car (ecc-model-sessions))
      (user-error "No session is running")))

(defun ecc-review-changed-paths (session)
  "Return the files changed since SESSION started, relative to its repository.
Nil when the session is not in a git repository, where what changed is
known only from what the session recorded."
  (when-let* ((root (ecc-git-root (or (ecc-session-project-root session)
                                      default-directory)))
              (base (or (ecc-session-baseline session)
                        (ecc-review--head-tree root)))
              (now (ecc-git-snapshot root)))
    (mapcar #'car (ecc-review--numstat root base now nil))))

(defun ecc-review--relative-paths (paths root base)
  "Return PATHS relative to the repository ROOT.
Each is absolute or relative to BASE, the directory the session works
in, which is what a path given by Claude or typed is relative to."
  (mapcar (lambda (path) (ecc-review--relative (expand-file-name path base) root))
          paths))

(defun ecc-review--target (session range root paths &optional base)
  "Return what a review of SESSION against RANGE is of, as a plist.
Both kinds of review read this, so that they name, restrict and fail
alike.  RANGE nil is the review of everything SESSION changed; anything
else is what `ecc-review-parse-range\=' takes, nil having been replaced
by the default first.  ROOT is a directory in the repository, the
project of SESSION by default, and PATHS, absolute or relative to BASE
-- ROOT, else the project of SESSION -- restrict the review.

The plist has :root, the root of the repository, nil for a review of
SESSION outside git (and an error for a review of a range there);
:range; :label, what the range is called (`ecc-review-range-label\=');
:elsewhere, the right side when it is not on disk (`ecc-review-elsewhere\=');
:paths, relative to :root when there is one and as given when
not; :name, the name of the review buffer; and :nothing, what to say
when there is no change to show."
  (let* ((range (and range (ecc-review-parse-range range)))
         (directory (or root (ecc-session-project-root session) default-directory))
         (root (or (ecc-git-root directory)
                   (and range
                        (user-error "%s is not in a git repository"
                                    (abbreviate-file-name directory)))))
         (label (and root (ecc-review-range-label root range))))
    (list :root root
          :range range
          :label label
          :elsewhere (ecc-review-elsewhere root range)
          :paths (if root
                     (ecc-review--relative-paths
                      paths root (or base (if range directory
                                            (or (ecc-session-project-root session)
                                                root))))
                   paths)
          :name (ecc-review-buffer-name session nil range label)
          :nothing (cond
                    ((null root) "No file was edited or written in this session")
                    ((null range)
                     (format "Nothing has changed in %s since this session started"
                             (abbreviate-file-name root)))
                    ((eq range 'staged)
                     (format "Nothing is staged in %s" (abbreviate-file-name root)))
                    (t (format "No change against %s in %s"
                               (if (string-empty-p range) "the index" range)
                               (abbreviate-file-name root)))))))

(defun ecc-review--session-content (session paths &optional base)
  "Read what the review of the changes of SESSION holds; see `ecc-review--show\='.
PATHS, absolute or relative to BASE -- the project of SESSION by
default -- restrict it to those files.

In a git repository this is the working tree as it stands against the
baseline taken when the session started.  Outside git it is built from
what the session recorded: there is no tree to compare against, so the
files the CLI reported editing are diffed against what it reported
them holding first."
  (let* ((target (ecc-review--target session nil nil paths base))
         (root (plist-get target :root))
         (paths (plist-get target :paths))
         (name (plist-get target :name)))
    (if (not root)
        (let* ((entries (ecc-review-files session paths))
               (diff (and entries (ecc-review-diff-text entries))))
          (list :name name :text (car diff) :root (cdr diff) :paths paths
                :nothing (if entries
                             "The files of this session show no change"
                           (plist-get target :nothing))))
      (let ((base (or (ecc-session-baseline session)
                      (ecc-review--head-tree root)
                      (user-error "Cannot read the history of %s"
                                  (abbreviate-file-name root)))))
        (list :name name :text (ecc-review-baseline-diff root base paths)
              :root root :paths paths :nothing (plist-get target :nothing))))))

(defun ecc-review-buffer (session &optional paths)
  "Return the buffer reviewing the changes of SESSION, filled.
PATHS restricts the review to those files.  Signals an error when no
file has a change to show.

In a git repository this is the working tree as it stands against the
baseline taken when the session started, so a file changed by a shell
command or a script reads like one changed by an edit, and work the
session committed along the way is still here.  A session that has no
baseline -- one that was already running before this Emacs learned to
take them -- falls back to HEAD, which is `ecc-review-range\='.
Outside git the session\='s own record is all there is."
  (ecc-review--show (ecc-review--session-content session paths) session))

(defun ecc-review-read-paths (session)
  "Ask for some of the files SESSION changed and return them absolute.
Offered relative to the repository and handed on absolute, which is
what the review reads either way.  None chosen is nil, every file."
  (let ((root (ecc-git-root (or (ecc-session-project-root session)
                                default-directory))))
    (mapcar (lambda (path) (expand-file-name path root))
            (completing-read-multiple
             "Files (empty for all): "
             (or (ecc-review-changed-paths session)
                 (mapcar #'ecc-file-entry-path (ecc-review-files session)))
             nil t))))

;;;###autoload
(defun ecc-review (&optional session paths)
  "Open everything that changed since SESSION started as one diff to review.
SESSION defaults to the session of the current buffer.  PATHS, given
interactively with a prefix argument, restricts the review to those
files.

This and `ecc-review-range\=' are the same review against different
bases: this one against where the session started, so the commits made
during it are still shown; that one against the last commit by
default, or any other range."
  (interactive
   (let ((session (ecc-review-session)))
     (list session (and current-prefix-arg (ecc-review-read-paths session)))))
  (let ((session (or session (ecc-review-session))))
    (if (and (eq ecc-review-style 'ediff)
             ;; Outside git there are no two trees to lay side by side:
             ;; the review is built from what the session recorded, and
             ;; what that gives is a diff.
             (ecc-git-root (or (ecc-session-project-root session)
                               default-directory)))
        (progn (require 'ecc-review-ediff)
               (ecc-review-ediff-buffer session paths))
      (ecc-review--display (ecc-review-buffer session paths) session))))

(defun ecc-review--display (buffer session)
  "Show the review BUFFER of SESSION, which the user opened; return its window.
`ecc-review-displayed-functions\=' are told of it."
  (prog1 (ecc-window-display-review buffer session)
    (run-hook-with-args 'ecc-review-displayed-functions buffer)))

(defun ecc-review--reread (buffer &optional watching)
  "Read the diff of the review BUFFER again, into BUFFER itself.
The review is built again the way it was first built, from what it
remembers -- its session, its request, its range and its files -- so
the comments and the place being read are kept (`ecc-review--fill\=').
WATCHING is `ecc-review--show\=''s: a review read because the files
changed stays open when its diff has gone."
  (with-current-buffer buffer
    (let ((session (or ecc-review--session (user-error "Not a review buffer"))))
      (if ecc-review--request
          (ecc-review-request ecc-review--request)
        (ecc-review--show
         (if ecc-review--range
             ;; `ecc-review--fill' left the repository in
             ;; `default-directory', so the refresh reads the same tree
             ;; even from a session of another.
             (ecc-review--range-content session ecc-review--range
                                           default-directory ecc-review--paths
                                           default-directory)
           ;; The paths it keeps are relative to the repository.
           (ecc-review--session-content session ecc-review--paths default-directory))
         session buffer watching)))))

(defun ecc-review-refresh ()
  "Read the diff again, keeping the comments and the place being read.
A review whose reading failed is tried again and follows the files
again; one that has nothing to show now stays open and says so, as it
would have had the files been followed all along.  When it fails again
the new error is what its header line says."
  (interactive)
  (let ((failed ecc-review--failed))
    (setq ecc-review--failed nil)
    (condition-case error
        (ecc-review-reread failed)
      (error
       (when failed
         (setq ecc-review--failed (error-message-string error))
         (force-mode-line-update))
       (signal (car error) (cdr error)))))
  (message "Refreshed"))

;;;; Following the files

;; A review is read again as the files under it change, so that it shows
;; the tree as it is now and not as it was when it opened.  Three things say that they may have: a
;; tool of the session finishing -- any tool that can write, since a shell
;; command or a script changes files as well as an edit does, and
;; `ecc-files-updated-hook' hears only of edits -- a turn ending, and a
;; file of the repository being saved in Emacs.  None of them reads the
;; diff: each marks the reviews it concerns stale and asks for the one
;; timer, which reads the stale reviews that are on the screen once the
;; user has stopped typing for a moment.  A review out of sight stays stale until
;; it is shown again.  The timer runs once and is made again by the next
;; change; a repeating timer that takes longer than its period starves
;; everything else (the freeze of 2026-09-21).
;;
;; Reading a review again never shows, selects or divides a window: it
;; fills a buffer that is already where it is.

(defcustom ecc-review-auto-refresh t
  "Whether an open review reads the diff again as the files change.
When non-nil a review follows the files: it is read again when a tool
of its session finishes -- a shell command as much as an edit -- when a
turn ends, and when a file of its repository is saved in Emacs.  Your
comments and the place you are reading are kept, as \\`g' keeps them,
and a review whose changes have all gone stays open and says so.  Only
a review on the screen is read at once; one out of sight is read when
it is shown again.  The review of one proposal waiting to be allowed is
never read again: it is about that proposal, not about the files.  A
review in ediff (`ecc-review-style\\=' `ediff\\=') follows them the same
way, keeping the difference being read and where its two sides are.

When nil a review shows the diff as it was opened, until \\`g'."
  :type 'boolean
  :group 'ecc)

(defvar ecc-review-auto-refresh-delay 0.5
  "Seconds Emacs is idle before a stale review on the screen is read again.
The changes of one step of a turn come together, a tool result and the
end of the turn a moment apart, and are read in one go.")

(defvar ecc-review--watch-timer nil
  "The timer that reads the stale reviews again, or nil.
There is at most one, and it runs once.")

(defvar ecc-review-unchanging-tools
  '("Read" "Grep" "Glob" "LS" "WebFetch" "WebSearch" "TodoWrite" "TodoRead"
    "ToolSearch" "Skill" "AskUserQuestion" "EnterPlanMode" "ExitPlanMode"
    "ListMcpResourcesTool" "ReadMcpResourceTool")
  "Tools whose result says nothing about the files.
A result of one of these does not make a review stale: it would only
have the working tree read again, for nothing.  A tool missing from
here costs that reading and nothing else, so the list keeps to tools
that cannot write; a shell, a subagent or a notebook edit can.")

(defvar ecc-review-unchanging-tool-functions nil
  "Functions given a tool name, returning non-nil when it changes no file.
The tools of other modules that only read or annotate -- the review
tools of `ecc-review-agent.el\=', whose `review_open\=' has just read the
review itself -- say so here.")

(defun ecc-review--watched-p (buffer)
  "Return non-nil when the review BUFFER follows the files.
A review of files does; the review of a proposal does not, and nor does
one whose last reading failed, until \\`g' reads it."
  (and (buffer-live-p buffer)
       (ecc-review-buffer-p buffer)
       (null (buffer-local-value 'ecc-review--failed buffer))))

(defun ecc-review--schedule-refresh ()
  "Make sure the timer that reads the stale reviews again is waiting.
It is an ordinary timer, `ecc-review-auto-refresh-delay\=' from now,
which waits again when it finds the user at work.  An idle timer would
have to be set at the idle time so far plus the delay -- Emacs is often
idle already when a tool result arrives -- and if the idle period ended
before that, the timer would wait for an idle period as long again:
minutes after watching Claude work for minutes."
  (unless (memq ecc-review--watch-timer timer-list)
    (setq ecc-review--watch-timer
          (run-at-time ecc-review-auto-refresh-delay nil #'ecc-review--watch-fire))))

(defun ecc-review--watch-fire ()
  "Read the stale reviews again, or wait again while the user is at work.
At work is input pending, or Emacs idle for less than
`ecc-review-auto-refresh-delay\=' -- or not idle at all."
  (setq ecc-review--watch-timer nil)
  (let ((idle (current-idle-time)))
    (if (or (input-pending-p)
            (null idle)
            (< (float-time idle) ecc-review-auto-refresh-delay))
        (ecc-review--schedule-refresh)
      (ecc-review--refresh-stale))))

(defun ecc-review--mark-stale (predicate)
  "Mark stale every review following the files for which PREDICATE holds.
PREDICATE is called with no argument in each review buffer.  When any
was marked, the timer is asked for."
  (when ecc-review-auto-refresh
    (let ((marked nil))
      (dolist (buffer (buffer-list))
        (when (and (ecc-review--watched-p buffer)
                   (with-current-buffer buffer (funcall predicate)))
          (with-current-buffer buffer (setq ecc-review--stale t))
          (setq marked t)))
      (when marked
        (ecc-review--schedule-refresh)))))

(defun ecc-review--under-p (file directory)
  "Return non-nil when FILE is DIRECTORY or under it, links resolved."
  (string-prefix-p (file-name-as-directory (file-truename directory))
                   (file-name-as-directory (file-truename file))))

(defun ecc-review--tool-files (session node)
  "Return the files the tool NODE of SESSION changed or names, absolute.
The file its input names, and the files a Bash call's `bashEditDiff'
says it changed, when the CLI sent one (`ecc-dispatch--bash-edit-diff\=').
A relative one is relative to the project of SESSION -- not to whatever
buffer is current when the result arrives."
  (when node
    (let ((root (or (ecc-session-project-root session) default-directory)))
      (mapcar (lambda (path) (expand-file-name path root))
              (delete-dups
               (delq nil
                     (cons (ecc-tool-input-path (ecc-model-node-get node 'input))
                           (plist-get (ecc-model-node-get node 'bash-edit)
                                      :changed))))))))

(defvar ecc-review--changed-in-turn (make-hash-table :test #'eq :weakness 'key)
  "Sessions a tool that can change files has finished for in this turn.
The end of a turn reads the reviews again only for these: a turn of
reads and searches changed nothing.")

(defun ecc-review--forget-session (session)
  "Forget what this module kept about SESSION, which has gone."
  (remhash session ecc-review--changed-in-turn))

(defun ecc-review--on-session-change (session &optional files)
  "Mark stale the reviews SESSION may have changed the files of.
Its own; every review whose repository holds the directory SESSION
works in, since a working tree review shows whoever changed a file and
two sessions share one; and every review of a repository one of FILES
is in, which is how a session working from above the repository -- a
session in ~/Projects editing one of the projects in it -- is heard.  A
shell command of such a session names a file only when the CLI sent its
`bashEditDiff'; otherwise it is heard only by its own reviews and those
whose repository holds its directory."
  (let ((directory (ecc-session-project-root session)))
    (ecc-review--mark-stale
     (lambda ()
       (or (eq ecc-review--session session)
           (and directory (ecc-review--under-p directory default-directory))
           (seq-some (lambda (file) (ecc-review--under-p file default-directory))
                     files))))))

(defun ecc-review--on-tool-finished (session node)
  "Mark stale the reviews the tool NODE of SESSION may have changed.
Unless it is one that changes no file (`ecc-review-unchanging-tools\=')."
  (let ((name (and node (ecc-model-node-get node 'name))))
    (unless (and (stringp name)
                 (or (member name ecc-review-unchanging-tools)
                     (run-hook-with-args-until-success
                      'ecc-review-unchanging-tool-functions name)))
      (puthash session t ecc-review--changed-in-turn)
      (ecc-review--on-session-change session (ecc-review--tool-files session node)))))

(defun ecc-review--on-turn-finished (session _turn)
  "Mark stale the reviews SESSION may have changed in the turn that ended.
Only when a tool that can change files finished in it."
  (when (gethash session ecc-review--changed-in-turn)
    (remhash session ecc-review--changed-in-turn)
    (ecc-review--on-session-change session)))

(defun ecc-review--on-save ()
  "Mark stale the reviews of the repository the file just saved is in."
  (when-let* ((file buffer-file-name))
    (ecc-review--mark-stale
     (lambda () (ecc-review--under-p file default-directory)))))

(defun ecc-review--on-window-buffer-change (frame)
  "Ask for the timer when a window of FRAME shows a stale review.
That is how a review out of sight is read again once it is shown.  A
window showing a part of a review -- a side of an ediff review -- shows
the review."
  (when (seq-some (lambda (window)
                    (let* ((buffer (window-buffer window))
                           (review (or (buffer-local-value 'ecc-review--part-of buffer)
                                       buffer)))
                      (and (buffer-live-p review)
                           (buffer-local-value 'ecc-review--stale review))))
                  (window-list frame 'no-minibuffer))
    (ecc-review--schedule-refresh)))

(defun ecc-review--refresh-stale ()
  "Read again every stale review that is on the screen.
A review that cannot be read is left as it was, with why in its header
line, and is not read again by itself until \\`g' does: the error is
shown once and logged, rather than every time a window changes.  It
does not keep the other reviews from being read.  Called before its
time -- the timer still waiting -- it takes the timer's place."
  (when (timerp ecc-review--watch-timer)
    (cancel-timer ecc-review--watch-timer))
  (setq ecc-review--watch-timer nil)
  (when ecc-review-auto-refresh
    (dolist (buffer (buffer-list))
      (when (and (ecc-review--watched-p buffer)
                 (buffer-local-value 'ecc-review--stale buffer)
                 (with-current-buffer buffer (ecc-review-shown-window)))
        (condition-case error
            (with-current-buffer buffer (ecc-review-reread t))
          (error
           (let ((text (error-message-string error)))
             (with-current-buffer buffer
               (setq ecc-review--stale nil
                     ecc-review--failed text)
               (force-mode-line-update))
             (ecc-log "review" "reading %s again failed: %s" (buffer-name buffer) text)
             (message "%s: %s" (buffer-name buffer) text))))))))

(add-hook 'ecc-tool-finished-hook #'ecc-review--on-tool-finished)
(add-hook 'ecc-turn-finished-hook #'ecc-review--on-turn-finished)
(add-hook 'ecc-session-removed-hook #'ecc-review--forget-session)

(defun ecc-review--watch-files ()
  "Have the reviews follow the files saved and the windows shown.
Called where a review comes to be -- `ecc-review-mode\=' and the control
buffer of an ediff review, which is in `ediff-mode\=' -- and not when the
file is loaded: until then a file saved has no review to mark stale, and
a window changed none to read again.  Nothing takes them off when the
last review goes: telling when that is would mean counting the two
sides of an ediff review too, and with no review each finds nothing."
  (add-hook 'after-save-hook #'ecc-review--on-save)
  (add-hook 'window-buffer-change-functions #'ecc-review--on-window-buffer-change))

;;;; Reviewing a range

(define-obsolete-variable-alias 'ecc-review-worktree-default-range
  'ecc-review-default-range "0.4.0")

(defvar ecc-review-default-range "HEAD"
  "What `ecc-review-range\=' diffs against without a prefix argument.
\"HEAD\" is everything uncommitted, staged or not, which is what the
CLI\='s own /diff shows.  \"\" is only what is not staged yet.")

(defun ecc-review-range-paths (directory range)
  "Return the files a review of DIRECTORY against RANGE would show.
They are relative to the repository, the changed ones first and then
those git does not track, when RANGE reads the working tree.  What
\\[universal-argument] \\[ecc-review-range] offers to choose from."
  (when-let* ((root (ecc-git-root directory)))
    (let* ((range (ecc-review-parse-range (or range ecc-review-default-range)))
           (effective (ecc-review--effective-range root range)))
      (delete-dups
       (append
        (pcase (apply #'ecc-git-run root "diff" "--name-only" "-z"
                      (append (ecc-review--range-arguments effective)
                              (list "--")))
          (`(0 . ,output) (split-string output "\0" t)))
        (and (ecc-review--range-includes-worktree-p root effective)
             (ecc-review--untracked-paths root)))))))

(define-obsolete-function-alias 'ecc-review-worktree-session
  #'ecc-review-range-session "0.4.0")

(defun ecc-review-range-session (root)
  "Return the session the comments on a review of ROOT go to.
The session of ROOT is preferred over whichever session happens to be
current: a review of one project handed to a session running in another
would tell Claude to change files it is not looking at.  When ROOT has
no session, starting one is offered."
  (or (car (ecc-window-project-sessions root))
      (if (y-or-n-p (format "No session in %s.  Start one? "
                            (abbreviate-file-name root)))
          (ecc-start root)
        (user-error "The comments need a session to go to"))))

(defun ecc-review--range-content (session range root paths &optional base)
  "Read what a review of a range holds; see `ecc-review--show\='.
The arguments are those of `ecc-review-range-buffer\=', and BASE is
what relative PATHS are relative to: ROOT, else the project of SESSION.
RANGE nil is `ecc-review-default-range\='."
  (let* ((target (ecc-review--target
                  session (or range ecc-review-default-range) root paths base))
         (range (plist-get target :range))
         (root (plist-get target :root))
         (paths (plist-get target :paths))
         (effective (ecc-review--effective-range root range))
         (tracked (pcase (ecc-review--git-diff
                          root (mapcar (lambda (path) (expand-file-name path root)) paths)
                          effective)
                    (`(0 . ,output) output)
                    ;; An unknown revision is not "no change": without
                    ;; this the buffer would quietly show the untracked
                    ;; files alone and look like a working tree that is
                    ;; clean but for them.
                    (`(,code . ,_)
                     (user-error "Git cannot diff against %S in %s (exit %d)"
                                 range (abbreviate-file-name root) code))
                    (_ (user-error "Git cannot be run in %s"
                                   (abbreviate-file-name root)))))
         (text (concat tracked
                       (or (and (ecc-review--range-includes-worktree-p root effective)
                                (ecc-review-git-untracked root paths))
                           ""))))
    (list :name (plist-get target :name)
          :label (plist-get target :label)
          :elsewhere (plist-get target :elsewhere)
          :text (and (not (string-empty-p text)) text)
          :root root :paths paths :range range
          :nothing (plist-get target :nothing))))

(define-obsolete-function-alias 'ecc-review-worktree-buffer
  #'ecc-review-range-buffer "0.4.0")

(defun ecc-review-range-buffer (session &optional range root paths)
  "Return the buffer reviewing ROOT against RANGE, filled.
The comments of the buffer go to SESSION.  ROOT defaults to the project
of SESSION, and RANGE to `ecc-review-default-range\=': a
revision or a range of them, \"\" for what is not staged, or `staged\='
for what is (`ecc-review-parse-range\=').  PATHS, absolute or relative
to ROOT -- the project of SESSION by default -- restrict the review to
those files; nil is every file.  Every change under the repository is
shown, whoever made it, and when RANGE reads the working tree the files
git does not track are appended (`ecc-review--range-includes-worktree-p\=').
Signals an error when the directory is not a git repository or has
nothing to show."
  (ecc-review--show (ecc-review--range-content session range root paths) session))

(defun ecc-review-read-range ()
  "Ask what range to review, and return it parsed.
What \\[universal-argument] \\[ecc-review-range] asks, and `r\=' in
`ecc-review-menu\=': a revision or a range, empty for what is not
staged, --staged for what is (`ecc-review-parse-range\=')."
  (ecc-review-parse-range
   (read-string "Diff against (empty for unstaged, --staged for the index): "
                ecc-review-default-range)))

(defun ecc-review-range-read-paths (directory range)
  "Ask for some of the files a review of DIRECTORY against RANGE shows.
They come back absolute; none chosen is nil, every file."
  (let ((root (ecc-git-root directory)))
    (mapcar (lambda (path) (expand-file-name path root))
            (completing-read-multiple
             "Files (empty for all): "
             (ecc-review-range-paths directory range) nil t))))

(defun ecc-review-context ()
  "Return (SESSION . DIRECTORY): which session a review is for, and where.
The project comes from the buffer the user is working in -- the
session of a transcript and its project, else the project of the
source being worked on and its session.  SESSION is nil when that
project has none; nothing is started here.  `ecc-review-range\=' and
`ecc-review-menu\=' both start from this."
  (let* ((buffer-session (ecc-window-buffer-session))
         (directory (if buffer-session
                        (ecc-window-session-project buffer-session)
                      (ecc-context-project-root))))
    (cons (or buffer-session (car (ecc-window-project-sessions directory)))
          (and directory (file-name-as-directory (expand-file-name directory))))))

(defun ecc-review-range--read-arguments ()
  "Return the (SESSION RANGE ROOT PATHS) `ecc-review-range\=' should run with.
The project comes from the buffer the user is working in -- this is a
command for the code, not for a transcript -- and the session from that
project, which is the one that can act on the diff.  With a prefix
argument the range is asked for, and then the files, out of those the
range would show; none chosen is every file."
  (let* ((context (ecc-review-context))
         (root (cdr context))
         (session (or (car context) (ecc-review-range-session root)))
         (range (and current-prefix-arg (ecc-review-read-range)))
         (paths (and current-prefix-arg (ecc-review-range-read-paths root range))))
    (list session range root paths)))

;;;###autoload
(defun ecc-review-range (&optional session range root paths)
  "Open the project against a git range as one diff to review.
The default range is HEAD: every uncommitted change of the project,
your own work included, so that it can be commented on and handed to
Claude.  `ecc-review\=' is the other review, of what the session
changed since it started.  ROOT is the project, the one of the buffer
the command was run from; SESSION is where the comments go, the session
of that project, started when it has none.  RANGE is what git diffs
against, asked for with a prefix argument: a revision like \"HEAD\", a
range like \"main...HEAD\" or \"a..b\", nothing for what is not staged
yet, or --staged for what is.  PATHS, asked for after it, restrict the
review to those files."
  (interactive (ecc-review-range--read-arguments))
  (let ((session (or session (ecc-review-session))))
    (pcase ecc-review-style
      ('ediff (require 'ecc-review-ediff)
              (ecc-review-ediff-range-buffer session range root paths))
      (_ (ecc-review--display (ecc-review-range-buffer session range root paths)
                              session)))))

;;;###autoload
(define-obsolete-function-alias 'ecc-review-worktree #'ecc-review-range "0.4.0")

(defun ecc-review-quit ()
  "Close the review buffer, dropping its comments."
  (interactive)
  (ecc-review--close (current-buffer)))

;;;; Reviewing one proposal

(defun ecc-review-request-diff (request &optional before)
  "Return the diff of the Edit or Write REQUEST as unified diff text.
BEFORE is the file as it is before the call, when known.  A hunk
header is always present so that the text is a hunk for `diff-mode'."
  (let* ((name (ecc-request-tool-name request))
         (input (ecc-request-input request))
         (path (alist-get 'file_path input))
         ;; A hunk for `diff-mode', as the docstring says: the @@ header
         ;; and the markers, not the transcript's line numbers.
         (ecc-diff-style 'unified)
         ;; Whether the hunks are numbered against BEFORE: an Edit whose
         ;; text is not found there is a hunk of its own two strings.
         (in-before nil)
         (body (pcase name
                 ((or "Edit" "MultiEdit")
                  (let ((old (or (alist-get 'old_string input) ""))
                        (new (or (alist-get 'new_string input) "")))
                    (if (and before (string-search old before))
                        (progn (setq in-before t)
                               (ecc-diff-for-edit old new before
                                                  ecc-review-proposal-context-lines))
                      (ecc-diff-format-hunks
                       (ecc-diff-hunks (ecc-diff-lines old new)
                                       ecc-review-proposal-context-lines)))))
                 ("Write"
                  (setq in-before (and before t))
                  (ecc-diff-for-write (or (alist-get 'content input) "") before
                                      ecc-review-proposal-context-lines))
                 (_ nil))))
    (when (and body (not (string-empty-p body)))
      (concat (propertize (ecc-review--file-header (or path "?") (null before))
                          'ecc-review-old-side
                          (list (and in-before (list 'proposal (secure-hash 'sha1 before)))))
              (substring-no-properties body)))))

(defun ecc-review-request (&optional request)
  "Open the diff of the pending Edit or Write REQUEST to comment on it.
REQUEST defaults to the one at point.  Returns the buffer."
  (interactive)
  (let* ((request (or request (ecc-perm-permission-request)))
         (session (ecc-request-session request))
         (node (ecc-request-node request))
         (before (or (and node (ecc-model-node-get node 'before))
                     (ecc-diff-file-content
                      (alist-get 'file_path (ecc-request-input request)))))
         (diff (or (ecc-review-request-diff request before)
                   (user-error "%s is not a change to a file that can be reviewed"
                               (ecc-request-tool-name request)))))
    (unless (memq request (ecc-session-pending session))
      (user-error "This request was answered already"))
    (let ((buffer (ecc-review--fill
                   (get-buffer-create (ecc-review-buffer-name session request))
                   session diff nil request)))
      (when (called-interactively-p 'any)
        (ecc-window-display-review buffer session))
      buffer)))

(defun ecc-review-comment-request (text)
  "Open the review of the request at point and put the comment TEXT on it.
The way a comment is left from the transcript."
  (interactive (list nil))
  (let ((buffer (ecc-review-request)))
    (pop-to-buffer buffer)
    (unless (ecc-review--hunk-bounds)
      (diff-hunk-next))
    (if text
        (ecc-review-comment text)
      (call-interactively #'ecc-review-comment))))

(defun ecc-review--request-buffer (request)
  "Return the live buffer reviewing REQUEST, or nil."
  (let ((buffer (get-buffer (ecc-review-buffer-name (ecc-request-session request)
                                                    request))))
    (and (buffer-live-p buffer)
         (eq (buffer-local-value 'ecc-review--request buffer) request)
         buffer)))

(defun ecc-review--on-request-resolved (session request)
  "Close the buffers reviewing REQUEST of SESSION, answered somewhere else."
  (when-let* ((buffer (ecc-review--request-buffer request)))
    (unless (eq buffer (current-buffer))
      (let ((message-buffer (get-buffer (ecc-review-message-buffer-name session))))
        (when (and message-buffer
                   (eq (buffer-local-value 'ecc-review-message--review message-buffer)
                       buffer))
          (ecc-perm-close-buffer message-buffer)))
      (ecc-perm-close-buffer buffer)))
  (when-let* ((buffer (ecc-review-proposal--buffer request)))
    (unless (eq buffer (current-buffer))
      (ecc-perm-close-buffer buffer))))

(add-hook 'ecc-request-resolved-hook #'ecc-review--on-request-resolved)

;;;; Editing a proposal before allowing it

(defvar ecc-review-edited-note
  "The user changed the earlier %s (%s) as follows before applying it.  Work from this from now on:"
  "Format of the note queued after a proposal was changed and applied.
The two arguments are the tool name and the file; the diff between
the proposal and what was applied follows.")

(defvar-local ecc-review-proposal--request nil
  "The request whose text this buffer edits.")

(defvar-local ecc-review-proposal--original nil
  "The text of the proposal as Claude sent it.")

(defvar ecc-review-proposal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-review-proposal-apply)
    (define-key map (kbd "C-c C-k") #'ecc-review-proposal-cancel)
    map)
  "Keymap of `ecc-review-proposal-mode'.")

(define-minor-mode ecc-review-proposal-mode
  "Minor mode of the buffer the text of a proposal is edited in."
  :lighter " Claude-Proposal"
  :keymap ecc-review-proposal-mode-map
  (setq header-line-format
        (and ecc-review-proposal-mode
             (propertize " Editing the proposal; C-c C-c allows it as it stands, C-c C-k goes back"
                         'face 'ecc-dim-face))))

(defun ecc-review-proposal-key (request)
  "Return the input key that holds the text REQUEST proposes, or nil."
  (pcase (ecc-request-tool-name request)
    ((or "Edit" "MultiEdit") 'new_string)
    ("Write" 'content)
    (_ nil)))

(defun ecc-review-proposal-buffer-name (session)
  "Return the name of the buffer a proposal of SESSION is edited in."
  (format "*ecc-edit-proposal: %s*" (ecc-session-name session)))

(defun ecc-review-proposal--buffer (request)
  "Return the live buffer editing REQUEST, or nil."
  (let ((buffer (get-buffer (ecc-review-proposal-buffer-name
                             (ecc-request-session request)))))
    (and (buffer-live-p buffer)
         (eq (buffer-local-value 'ecc-review-proposal--request buffer) request)
         buffer)))

(defun ecc-review-edit-proposal (&optional request)
  "Edit the text the pending REQUEST proposes, to apply it changed.
REQUEST defaults to the one this buffer reviews, then to the one at
point.  Returns the buffer."
  (interactive)
  (let* ((request (or request ecc-review--request (ecc-perm-permission-request)))
         (session (ecc-request-session request))
         (key (or (ecc-review-proposal-key request)
                  (user-error "%s has no text to edit" (ecc-request-tool-name request))))
         (path (alist-get 'file_path (ecc-request-input request)))
         (text (or (alist-get key (ecc-request-input request)) ""))
         (buffer (get-buffer-create (ecc-review-proposal-buffer-name session))))
    (unless (memq request (ecc-session-pending session))
      (user-error "This request was answered already"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        ;; The mode of the file, so that the text is edited the way the
        ;; file would be.
        (let ((buffer-file-name path))
          (condition-case nil (set-auto-mode) (error (fundamental-mode))))
        (setq buffer-read-only nil)
        (setq ecc-render--session session
              ecc-review-proposal--request request
              ecc-review-proposal--original text)
        (ecc-review-proposal-mode 1)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (when (called-interactively-p 'any)
      (pop-to-buffer buffer))
    buffer))

(defun ecc-review-proposal-note (request original edited)
  "Return the note telling Claude that REQUEST was applied as EDITED, not ORIGINAL."
  (concat (format ecc-review-edited-note
                  (ecc-request-tool-name request)
                  (or (alist-get 'file_path (ecc-request-input request)) "?"))
          "\n```diff\n"
          (string-trim-right
           (substring-no-properties
            (or (let ((ecc-diff-style 'unified))
                  (ecc-diff-render original edited))
                ""))
           "\n")
          "\n```"))

(defun ecc-review-proposal-apply ()
  "Allow the proposal with the text of this buffer in place of Claude's.
When the text was changed, a note saying so is put in front of the
prompt queue so that the next message tells Claude what was applied."
  (interactive)
  (let* ((request (or ecc-review-proposal--request (user-error "Not a proposal buffer")))
         (session (ecc-request-session request))
         (key (ecc-review-proposal-key request))
         (edited (buffer-substring-no-properties (point-min) (point-max)))
         (changed (not (equal edited ecc-review-proposal--original)))
         (buffer (current-buffer)))
    (unless (memq request (ecc-session-pending session))
      (user-error "This request was answered already"))
    (if (not changed)
        (progn
          (ecc-perm-allow-request request)
          (message "Allowed as it stands: %s" (ecc-request-tool-name request)))
      (let ((input (copy-alist (ecc-request-input request))))
        (setf (alist-get key input) edited)
        (ecc-perm-respond request 'allow :updated-input input
                          :message "edited by the user and applied")
        (ecc-model-queue-input
         session (ecc-review-proposal-note request ecc-review-proposal--original edited)
         nil t)
        (message "Allowed with your changes: %s (the next message carries what you changed)"
                 (ecc-request-tool-name request))))
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer buffer)
    (when-let* ((review (ecc-review--request-buffer request)))
      (ecc-perm-close-buffer review))
    changed))

(defun ecc-review-proposal-cancel ()
  "Drop the edit and leave the request waiting."
  (interactive)
  (set-buffer-modified-p nil)
  (ecc-perm-close-buffer (current-buffer)))

(provide 'ecc-review)

;;; ecc-review.el ends here
