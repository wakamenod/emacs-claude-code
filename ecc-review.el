;;; ecc-review.el --- Reviewing what Claude changed, hunk by hunk  -*- lexical-binding: t; -*-

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

;; The main way of working the requirements describe: let Claude change
;; things, then open every change of the session as one diff, walk the
;; hunks, attach a comment to the ones that need work and send all the
;; comments as a single prompt.
;;
;; `ecc-review' and `ecc-review-worktree' are the same review against
;; different bases: the first against what the working tree held when
;; the session started (`ecc-review-ensure-baseline'), so the commits made
;; during it are still shown; the second against HEAD, so only what is
;; uncommitted is.  Neither asks how a file was changed -- an edit, a
;; shell command and a script all read alike -- because both compare
;; trees rather than replaying what the CLI reported doing.  Outside a
;; git repository there is no tree to compare, and only there is a file
;; still diffed against what it was before the first change of the
;; session (`ecc-file-entry-original').  The buffer is a read-only
;; `diff-mode', so n, p and RET are the usual ones.
;;
;; A comment is on a line -- the old side of a removed one, the new side
;; of any other -- or on a whole hunk from its @@ header.  Comments are
;; kept as `ecc-review-note's apart from the text, and every redraw puts
;; each back on the line that still says what its line said, so reading
;; the diff again after a change higher up in a file moves them rather
;; than losing them; one whose line is gone is kept and marked outdated.
;; Claude writes comments into the same buffer over MCP
;; (`ecc-review-agent.el'), drawn in a face of their own; only the
;; user's are sent.
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
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-window)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ediff-recenter "ediff-util" (&optional no-rehighlight))
(declare-function ecc-review-ediff-buffer "ecc-review-ediff" (session &optional paths))
(declare-function ecc-review-ediff-worktree-buffer "ecc-review-ediff"
                  (session &optional range root))

(defcustom ecc-review-style 'diff
  "How `ecc-review\=' and `ecc-review-worktree\=' show what changed.
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

(defvar ecc-review-git-executable "git"
  "The git program the review runs for `git diff'.")

(defvar ecc-review-header
  "Review comments on the changes below.  Please act on each of them."
  "First line of the prompt the review comments are sent as.")

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

(defface ecc-review-commented-hunk-face
  '((t :inherit diff-hunk-header :weight bold))
  "Face of the header of a hunk that carries a comment."
  :group 'ecc)

;;;; Which files

(defun ecc-review-files (session &optional paths)
  "Return the file entries of SESSION that were edited or written.
When PATHS is given only those files are returned, in the order of
PATHS.  Entries only read are left out."
  (let ((changed (seq-filter (lambda (entry)
                               (> (+ (ecc-file-entry-edits entry)
                                     (ecc-file-entry-writes entry))
                                  0))
                             (ecc-model-files session))))
    (if paths
        (delq nil (mapcar (lambda (path)
                            (seq-find (lambda (entry)
                                        (equal (ecc-file-entry-path entry) path))
                                      changed))
                          paths))
      changed)))

;;;; Git

(defun ecc-review--git (directory &rest args)
  "Run git with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT).
Returns nil when git cannot be run at all."
  (when (executable-find ecc-review-git-executable)
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory)))
        (condition-case err
            (cons (apply #'call-process ecc-review-git-executable nil
                         (list t nil) nil args)
                  (buffer-string))
          (file-error (ecc-log "review" "git failed: %s" (error-message-string err))
                      nil))))))

(defun ecc-review-git-root (path)
  "Return the root of the git repository holding PATH, or nil."
  (let ((directory (file-name-directory (expand-file-name path))))
    (when (file-directory-p directory)
      (pcase (ecc-review--git directory "rev-parse" "--show-toplevel")
        (`(0 . ,output)
         (let ((root (string-trim output)))
           (and (not (string-empty-p root))
                (file-name-as-directory (expand-file-name root)))))))))

(defun ecc-review--relative (path root)
  "Return PATH relative to the repository ROOT, through symbolic links.
git reports its root with links resolved, so PATH is resolved too."
  (file-relative-name (file-truename path) root))

(defun ecc-review-git-tracked (root paths)
  "Return the members of PATHS that git tracks in the repository at ROOT.
PATHS are absolute; the result keeps their order."
  (pcase (apply #'ecc-review--git root "ls-files" "-z" "--"
                (mapcar (lambda (path) (ecc-review--relative path root)) paths))
    (`(0 . ,output)
     (let ((tracked (split-string output "\0" t)))
       (seq-filter (lambda (path)
                     (member (ecc-review--relative path root) tracked))
                   paths)))))

(defun ecc-review-git-diff (root paths &optional range)
  "Return the unified diff git reports for PATHS under ROOT, or nil.
PATHS may be nil, which diffs everything under ROOT.  RANGE is what to
diff against -- a revision like \"HEAD\" or a range like
\"main...HEAD\" -- and defaults to the index, the way `git diff'
works.  The file names carry a/ and b/ prefixes and are relative to
ROOT."
  (pcase (ecc-review--git-diff root paths range)
    (`(0 . ,output)
     (and (not (string-empty-p output)) output))
    (result
     (ecc-log "review" "git diff failed in %s: %S" root result)
     nil)))

(defun ecc-review--git-diff (root paths &optional range)
  "Return the (EXIT-CODE . OUTPUT) of the git diff of PATHS under ROOT.
RANGE is what to diff against.  This is `ecc-review-git-diff\=' without
the judgement: a caller that has to tell a diff that is empty from one
git refused to make -- an unknown revision, say -- reads the code."
  (apply #'ecc-review--git root
         (append (list "diff" "--no-color" "--no-ext-diff"
                       (format "-U%d" (max 0 ecc-review-context-lines)))
                 (and range (not (string-empty-p range)) (list range))
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
again is the usual one.")

(defalias 'ecc-review--binary-p #'ecc-diff-binary-p
  "Return non-nil when a path looks binary, or cannot be read.
git does not apply its own test to a new file diffed against
/dev/null -- the empty side is text, so the pair is text and the bytes
of a PNG land in the diff -- which is why the review has to ask for
itself.")

(defun ecc-review--omitted-note (path reason &optional new-file)
  "Return the diff entry naming PATH without its content, because of REASON.
NEW-FILE writes the header of a file that did not exist before."
  (format "diff --git a/%s b/%s\n%s%s\n"
          path path (if new-file "new file mode 100644\n" "") reason))

(defun ecc-review-git-untracked (root)
  "Return the diff of the files under ROOT git does not track, or nil.
What .gitignore excludes is left out, and each file is diffed against
nothing so that it reads like the rest of the diff.  A binary file, or
one larger than `ecc-review-max-bytes\=', is named rather than
printed."
  (pcase (ecc-review--git root "ls-files" "-z" "--others" "--exclude-standard")
    (`(0 . ,output)
     (let ((texts nil))
       (dolist (path (split-string output "\0" t))
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
             (pcase (ecc-review--git root "diff" "--no-color" "--no-ext-diff"
                                     (format "-U%d" (max 0 ecc-review-context-lines))
                                     "--no-index" "--" "/dev/null" path)
               ((and `(,code . ,diff)
                     (guard (and (memq code '(0 1)) (not (string-empty-p diff)))))
                (push diff texts)))))))
       (let ((text (string-join (nreverse texts) "")))
         (and (not (string-empty-p text)) text))))))

(defun ecc-review--unborn-p (root)
  "Return non-nil when the repository at ROOT has no commit yet."
  (pcase (ecc-review--git root "rev-parse" "--verify" "--quiet" "HEAD")
    (`(0 . ,_) nil)
    (_ t)))

(defun ecc-review--empty-tree (root)
  "Return the hash of the empty tree of the repository at ROOT, or nil.
Asked of git rather than written out: the 4b825dc everybody knows is the
SHA-1 one, and a repository whose object format is SHA-256 has another.
`ecc-review--git\=' gives git no stdin, so --stdin reads nothing and git
names the tree of nothing."
  (pcase (ecc-review--git root "hash-object" "-t" "tree" "--stdin")
    (`(0 . ,output)
     (let ((hash (string-trim output)))
       (and (not (string-empty-p hash)) hash)))))

;;;; What the working tree held at one moment

(defun ecc-review--git-with-index (root index &rest args)
  "Run git with ARGS in ROOT against the index file INDEX.
Returns (EXIT-CODE . OUTPUT) like `ecc-review--git\=', or nil."
  (let ((process-environment
         (cons (concat "GIT_INDEX_FILE=" index) process-environment)))
    (apply #'ecc-review--git root args)))

(defun ecc-review-snapshot (root &optional no-add)
  "Return a git tree naming every file of the working tree at ROOT, or nil.
What .gitignore excludes is left out, as everywhere else in the review.

With NO-ADD the working tree is not read at all and the tree is the
index as it stands: what is staged, and nothing else.  That is the
right-hand side of nothing, but it is the left-hand side of a review
of what is not staged yet -- the same comparison `git diff\=' with no
revision makes.

Nothing of the repository is disturbed: the files are added to a
throwaway index and written out as a tree, so the real index, the
working tree and `refs/stash\=' are all untouched and no stash entry is
made.  Unreachable until something names it, the tree is an ordinary
object and `git gc\=' leaves it alone for `gc.pruneExpire\=' -- two weeks
by default -- which outlives any session.

The repository\='s own index is copied in first, for its stat cache: git
then hashes only the files that changed rather than all of them (25 ms
against 43 ms over 206 files, measured 2026-09-15).  A repository with
no commit needs no special case here; `git add\=' and `git write-tree\='
want no HEAD."
  (let ((index (make-temp-file "ecc-review-index"))
        (real (pcase (ecc-review--git root "rev-parse" "--git-path" "index")
                (`(0 . ,output)
                 (expand-file-name (string-trim output) root)))))
    (unwind-protect
        (progn
          (if (and real (file-readable-p real))
              ;; With the time of the index, not the time of the copy.
              ;; git re-reads a file whose cached stat is no older than the
              ;; index that holds it -- racily clean, the case its stat
              ;; cannot settle -- and trusts the stat otherwise.  A copy
              ;; stamped now is newer than every stat in it, so nothing is
              ;; racily clean any more and a file written in the same
              ;; second as the last commit, to the same length, reads as
              ;; unchanged and drops out of the review.  Measured on
              ;; 2026-09-15 (macOS, git 2.x, one second of stat
              ;; granularity): 7 misses in 900 runs of write-then-snapshot
              ;; without the time, none in 900 with it.
              (copy-file real index t t)
            ;; git writes the index itself; an empty file is not one.
            (delete-file index))
          (pcase (if no-add
                     '(0 . "")
                   (ecc-review--git-with-index root index "add" "-A" "--"))
            (`(0 . ,_)
             (pcase (ecc-review--git-with-index root index "write-tree")
               (`(0 . ,output)
                (let ((tree (string-trim output)))
                  (and (not (string-empty-p tree)) tree)))
               (result (ecc-log "review" "write-tree failed in %s: %S" root result)
                       nil)))
            (result (ecc-log "review" "snapshot failed in %s: %S" root result)
                    nil)))
      (when (file-exists-p index) (delete-file index)))))

(defun ecc-review--head-tree (root)
  "Return the tree of HEAD at ROOT, or the empty tree when there is none.
The base a review falls back to when it has no baseline of its own."
  (if (ecc-review--unborn-p root)
      (ecc-review--empty-tree root)
    (pcase (ecc-review--git root "rev-parse" "--verify" "--quiet" "HEAD^{tree}")
      (`(0 . ,output)
       (let ((tree (string-trim output)))
         (and (not (string-empty-p tree)) tree))))))

(defun ecc-review--numstat (root base now paths)
  "Return (PATH . BINARY-P) for every file that differs between BASE and NOW.
ROOT is the repository the two trees belong to, and PATHS restricts the
comparison.  Renames are not looked for, so that
each entry names one path and the sizes below can be decided file by
file; a rename reads as a delete and an add, which a review can see."
  (pcase (apply #'ecc-review--git root
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
  (when-let* ((now (ecc-review-snapshot root)))
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
                        (pcase (apply #'ecc-review--git root
                                      (append
                                       (list "diff" "--no-color" "--no-ext-diff"
                                             "--no-renames"
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

(defun ecc-review-ensure-baseline (session)
  "Record what the working tree of SESSION holds now unless it is known.
This is what `ecc-review\=' diffs against.  A session that already has
one keeps it: resuming restarts the CLI, not the work -- the
conversation, its id and its transcript all carry on -- and taking a
baseline again there would drop everything the session had already done
out of its own review.  A review is better too wide than too narrow: a
hunk that is shown can be passed over, one that is not cannot be
commented on.

So a session started afresh takes one because it has none, a session
resumed from a recording in a new Emacs takes its first, and a session
whose CLI was killed and started again keeps the one it began with.  A
session outside git keeps nil and is reviewed from what it recorded
instead -- and asks git again next time, since a project can be put
under git while a session runs."
  (or (ecc-session-baseline session)
      (setf (ecc-session-baseline session)
            (when-let* ((root (ecc-review-git-root
                               (or (ecc-session-project-root session)
                                   default-directory))))
              (ecc-review-snapshot root)))))

;;;; A diff made from what the session recorded

(defun ecc-review--current-content (entry)
  "Return what the file of ENTRY holds now: the file, else the last snapshot."
  (or (ecc-diff-file-content (ecc-file-entry-path entry))
      (ecc-file-entry-snapshot entry)))

(defun ecc-review--file-header (path &optional new-file)
  "Return the ---/+++ lines naming PATH, from /dev/null when NEW-FILE."
  (format "--- %s\n+++ %s\n" (if new-file "/dev/null" path) path))

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
                                (or (ecc-review-git-root path) 'none)
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
            (when-let* ((diff (ecc-review-git-diff root tracked)))
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
The string is what git is given: \"HEAD\" for everything uncommitted,
\"\" for what is not staged yet, \"main...HEAD\" for a branch.")

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

(defvar-local ecc-review--comments nil
  "Overlays drawing the comments, one per place that carries any.")

(defvar-local ecc-review--decorations nil
  "Overlays marking the header of every hunk that carries a comment.")

;; A review is a buffer that holds comments and is closed when they have
;; been sent.  How it holds them and how it closes are its own: the diff
;; buffer keeps overlays on hunks and is killed, an ediff review keeps
;; them against difference numbers in a control buffer and is quit
;; through ediff so that the windows come back.  Everything between --
;; C-c C-c, the prompt shown to be confirmed, C-c C-k -- is the same
;; code for both, because only these two slots differ.

(defvar-local ecc-review--comments-function #'ecc-review-comments
  "How this review buffer lists its comments.
Called with no argument in the review buffer; returns the plists
`ecc-review-format-message\=' takes.")

(defvar-local ecc-review--close-function #'ecc-perm-close-buffer
  "How this review buffer is closed once its comments have been sent.
Called with the review buffer.")

(defun ecc-review--close (review)
  "Close the review buffer REVIEW the way it asks to be closed."
  (when (buffer-live-p review)
    (funcall (buffer-local-value 'ecc-review--close-function review) review)))

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
    map)
  "Keymap of `ecc-review-mode\='.
The buffer is read-only, so a letter is free to be a command, and these
come before `diff-mode-shared-map\=' -- which uses k, K, n, N, o, p,
P, { and }.  Nothing here takes a \\`C-c <letter>\=' key: the Emacs Lisp
manual reserves those for users.  \\`C-c C-c\=' and \\`C-c C-k\=' shadow
`diff-mode\=', deliberately: finishing and aborting are what those two
mean everywhere in Emacs.  So do { and }, which move between the
comments here and between files in `diff-mode\=': N and P still do
that.")

(define-derived-mode ecc-review-mode diff-mode "Claude-Review"
  "Major mode of the buffer the changes of a session are reviewed in.

\\{ecc-review-mode-map}"
  :interactive nil
  (setq buffer-read-only t)
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
  (setq header-line-format '(:eval (ecc-review--header-line))))

(defun ecc-review-buffer-name (session &optional request range)
  "Return the name of the review buffer of SESSION.
With REQUEST it is the buffer reviewing that one proposal; with RANGE,
the one reviewing the working tree.  The three are different buffers:
a review of the working tree does not take the place of the review of
what the session changed."
  (cond
   (request (format "*ecc-review: %s (proposal)*" (ecc-session-name session)))
   (range (format "*ecc-review: %s (%s)*" (ecc-session-name session)
                  (if (string-empty-p range) "unstaged" range)))
   (t (format "*ecc-review: %s*" (ecc-session-name session)))))

(defun ecc-review--header-line ()
  "Return the header line of the review buffer."
  (ecc--mode-line-escape
   (concat
   (propertize (format " %s: %s"
                       (cond (ecc-review--request "Proposal review")
                             (ecc-review--range
                              (format "Working tree (%s)"
                                      (if (string-empty-p ecc-review--range)
                                          "unstaged" ecc-review--range)))
                             (t "Review"))
                       (if ecc-review--session
                           (ecc-session-name ecc-review--session)
                         "?"))
               'face 'ecc-heading-face)
   (propertize (concat "  ·  " (ecc-review--count-string)) 'face 'ecc-dim-face)
   (propertize (if ecc-review--request
                   "  ·  c comment  e edit and apply  C-c C-c send as deny (C-u edits)  n/p hunk  RET source"
                 "  ·  c comment  { } comments  a Claude's  l list  d delete  C-c C-c send (C-u edits)  n/p hunk  RET source")
               'face 'ecc-dim-face))))

(defun ecc-review--count-string ()
  "Return what the header line says about the comments of this buffer.
Claude\='s are counted while they are hidden: hiding them is for reading
the diff, not for forgetting that they are there."
  (let ((yours 0) (claude 0) (outdated 0))
    (dolist (note ecc-review--notes)
      (if (eq (ecc-review-note-author note) 'claude)
          (cl-incf claude)
        (cl-incf yours))
      (when (ecc-review-note-outdated note)
        (cl-incf outdated)))
    (concat (format "comments: %d yours" yours)
            (when (> claude 0)
              (format ", %d Claude's%s" claude
                      (if ecc-review--show-agent "" " (hidden)")))
            (when (> outdated 0)
              (format " (%d outdated)" outdated)))))

(defun ecc-review--fill (buffer session text root &optional request paths range)
  "Put the diff TEXT into BUFFER for SESSION and draw its comments again.
ROOT is the directory the file names of TEXT are relative to; REQUEST,
PATHS and RANGE are remembered as what the buffer reviews.

The comments are kept across a redraw, each put back where its line is
now (`ecc-review--locate-note\='); one whose line is gone is marked
outdated and kept, never dropped.  A buffer that reviewed another
proposal before starts with none: those comments were about something
that is not being asked any more."
  (with-current-buffer buffer
    (let ((same (and (derived-mode-p 'ecc-review-mode)
                     (eq ecc-review--request request)))
          (outdated (seq-count #'ecc-review-note-outdated ecc-review--notes)))
      (unless (derived-mode-p 'ecc-review-mode)
        (ecc-review-mode))
      (unless same
        (setq ecc-review--notes nil
              ecc-review--next-id 1
              outdated 0))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (unless (bolp) (insert "\n")))
      (setq default-directory (or root (ecc-session-project-root session)
                                  default-directory)
            ecc-review--session session
            ecc-render--session session
            ecc-review--request request
            ecc-review--paths paths
            ecc-review--range range)
      (set-buffer-modified-p nil)
      (goto-char (point-min))
      (ecc-review--draw-notes)
      (let ((lost (- (seq-count #'ecc-review-note-outdated ecc-review--notes)
                     outdated)))
        (when (> lost 0)
          (message "%d comments no longer match a line of the diff; kept as outdated"
                   lost)))
      buffer)))

;;;; Hunks

(defconst ecc-review--hunk-regexp
  "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
  "Matches a unified hunk header.
The groups are old start, old count, new start and new count.")

(defun ecc-review-hunk-range (header)
  "Return (START . END) of the new side of the hunk HEADER line.
A hunk that only removes lines is one line wide at its position."
  (when (string-match ecc-review--hunk-regexp header)
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
  "Return the file name of the hunk starting at BEG, without a/ or b/."
  (save-excursion
    (goto-char beg)
    (let* ((names (ignore-errors (diff-hunk-file-names)))
           (new (car names))
           (old (cadr names))
           (name (if (or (null new) (equal new "/dev/null")) old new)))
      (when name
        (replace-regexp-in-string "\\`[ab]/" "" name)))))

(defun ecc-review-hunk-at (beg end)
  "Return the hunk between BEG and END as a plist.
The plist has :path, :start and :end of the new side, :header, :text
being the whole hunk, :position and :bound, the positions it runs
between."
  (save-excursion
    (goto-char beg)
    (let* ((header (buffer-substring-no-properties (point) (line-end-position)))
           (range (ecc-review-hunk-range header)))
      (list :path (ecc-review--hunk-path beg)
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
      (while (re-search-forward ecc-review--hunk-regexp nil t)
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
           (old (if (string-match ecc-review--hunk-regexp header)
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
The place is kept as text rather than as a position, so that the
comment can be put back after the diff has been read again: PATH, SIDE
and LINE name the line and LINE-TEXT is what it said.  SIDE is nil for
a comment on a whole hunk.  HUNK-KEY, HUNK-RANGE and HUNK-TEXT are the
hunk it was in when last found -- its key, the lines of its new side
and its text, which is what an outdated comment is still sent with."
  id              ; an integer, unique in the buffer and never reused
  author          ; `user' or `claude'
  path side line line-text
  hunk-key hunk-range hunk-text
  text
  reply-to        ; the id of the comment this one answers, or nil
  outdated)       ; non-nil when no line of the diff matches any more

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

(defun ecc-review--drawn-under (note)
  "Return the comment NOTE is drawn under, or nil when it stands alone."
  (when-let* ((parent (ecc-review--parent note)))
    (and (ecc-review--shown-p parent) parent)))

(defun ecc-review--anchor (note line)
  "Put NOTE on LINE, a plist of `ecc-review--hunk-lines', and return it."
  (let ((hunk (plist-get line :hunk)))
    (setf (ecc-review-note-path note) (plist-get line :path)
          (ecc-review-note-side note) (plist-get line :side)
          (ecc-review-note-line note) (plist-get line :line)
          (ecc-review-note-line-text note) (and (plist-get line :side)
                                                (plist-get line :text))
          (ecc-review-note-hunk-key note) (ecc-review--hunk-key hunk)
          (ecc-review-note-hunk-range note) (cons (plist-get hunk :start)
                                                  (plist-get hunk :end))
          (ecc-review-note-hunk-text note) (plist-get hunk :text)
          (ecc-review-note-outdated note) nil)
    note))

(defun ecc-review--locate-note (note lines)
  "Return the member of LINES NOTE belongs on now, or nil when none is.
LINES are plists of `ecc-review--hunk-lines'.  A comment on a line goes
to the line of the same path and side that still says what its line
said, the one nearest the number it had -- which is the same line when
nothing above it moved, and the line it was pushed to when something
did.  A comment on a whole hunk goes to the hunk with the same header,
else to the first hunk of its path whose new side overlaps the lines it
covered.  Nil means none of that is there: the comment is outdated."
  (let ((path (ecc-review-note-path note))
        (side (ecc-review-note-side note)))
    (if side
        (let ((text (ecc-review-note-line-text note))
              (number (ecc-review-note-line note))
              (best nil))
          (dolist (line lines)
            (when (and (eq (plist-get line :side) side)
                       (equal (plist-get line :path) path)
                       (equal (plist-get line :text) text)
                       (or (null best)
                           (< (abs (- (plist-get line :line) number))
                              (abs (- (plist-get best :line) number)))))
              (setq best line)))
          best)
      (let ((headers (seq-filter (lambda (line)
                                   (and (null (plist-get line :side))
                                        (equal (plist-get line :path) path)))
                                 lines))
            (range (ecc-review-note-hunk-range note)))
        (or (seq-find (lambda (line)
                        (equal (ecc-review--hunk-key (plist-get line :hunk))
                               (ecc-review-note-hunk-key note)))
                      headers)
            (and (car range) (cdr range)
                 (seq-find (lambda (line)
                             (let ((hunk (plist-get line :hunk)))
                               (and (<= (plist-get hunk :start) (cdr range))
                                    (>= (plist-get hunk :end) (car range)))))
                           headers)))))))

(defun ecc-review--relocate (lines)
  "Put every comment back on LINES and return where each went.
The answer is a hash of each comment to its line, nil for an outdated
one.  A reply goes wherever the comment it answers went; the comments
are in the order they were made, so that one is placed first."
  (let ((places (make-hash-table :test #'eq)))
    (dolist (note ecc-review--notes)
      (let* ((parent (ecc-review--parent note))
             (line (if parent
                       (gethash parent places)
                     (ecc-review--locate-note note lines))))
        (if line
            (ecc-review--anchor note line)
          (setf (ecc-review-note-outdated note) t))
        (puthash note line places)))
    places))

(defun ecc-review--place (note line lines)
  "Return (BEG END PROPERTY) of the overlay NOTE, placed on LINE, is drawn with.
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
                 'face (if agent 'ecc-review-agent-comment-face 'ecc-review-comment-face))
     (mapconcat (lambda (child) (ecc-review--note-string child (1+ depth)))
                (ecc-review--children note) ""))))

(defun ecc-review--subtree (note)
  "Return NOTE and every shown reply under it."
  (cons note (mapcan #'ecc-review--subtree (ecc-review--children note))))

(defvar-local ecc-review--positions nil
  "Hash of each comment to where it was drawn last, hidden ones included.")

(defun ecc-review--draw-notes ()
  "Draw the comments of this buffer again from `ecc-review--notes'.
Every comment is put back first (`ecc-review--relocate'), so this is
also what keeps them in place across a refresh."
  (mapc #'delete-overlay ecc-review--comments)
  (mapc #'delete-overlay ecc-review--decorations)
  (setq ecc-review--comments nil
        ecc-review--decorations nil
        ecc-review--positions (make-hash-table :test #'eq))
  (let* ((lines (ecc-review--lines))
         (places (ecc-review--relocate lines))
         (groups nil)
         (commented nil))
    (dolist (note ecc-review--notes)
      (let ((place (ecc-review--place note (gethash note places) lines)))
        (puthash note (car place) ecc-review--positions)
        (when (ecc-review--shown-p note)
          (unless (ecc-review-note-outdated note)
            (cl-pushnew (ecc-review-note-hunk-key note) commented :test #'equal))
          (unless (ecc-review--drawn-under note)
            (push note (alist-get place groups nil nil #'equal))))))
    (pcase-dolist (`((,beg ,end ,property) . ,roots) (nreverse groups))
      (let ((overlay (make-overlay beg end nil t nil))
            (roots (nreverse roots)))
        (overlay-put overlay 'ecc-review-notes (mapcan #'ecc-review--subtree roots))
        (overlay-put overlay property
                     (mapconcat (lambda (note) (ecc-review--note-string note 0))
                                roots ""))
        (push overlay ecc-review--comments)))
    (dolist (line lines)
      (when (and (null (plist-get line :side))
                 (member (ecc-review--hunk-key (plist-get line :hunk)) commented))
        (let ((overlay (make-overlay (plist-get line :position)
                                     (save-excursion
                                       (goto-char (plist-get line :position))
                                       (line-end-position)))))
          (overlay-put overlay 'face 'ecc-review-commented-hunk-face)
          (push overlay ecc-review--decorations)))))
  (force-mode-line-update))

(defun ecc-review-comment-overlays ()
  "Return the live overlays drawing the comments of this buffer."
  (setq ecc-review--comments (seq-filter #'overlay-buffer ecc-review--comments)))

(defun ecc-review-note-position (note)
  "Return where NOTE was drawn last, or would have been when hidden."
  (and ecc-review--positions (gethash note ecc-review--positions)))

(defun ecc-review-add-note (author text line &optional reply-to)
  "Add a comment by AUTHOR saying TEXT on LINE and return it.
LINE is a plist of `ecc-review--hunk-lines'.  With REPLY-TO, the id of
the comment answered, LINE may be nil and the reply goes where that one
is.  The comment is not drawn yet: `ecc-review--draw-notes\=' does that,
once for however many are added."
  (let* ((parent (and reply-to (or (ecc-review-find-note reply-to)
                                   (error "No comment #%s" reply-to))))
         (note (ecc-review-note-create :id ecc-review--next-id :author author
                                       :text text :reply-to reply-to)))
    (if line
        (ecc-review--anchor note line)
      (dolist (slot '(path side line line-text hunk-key hunk-range hunk-text outdated))
        (setf (cl-struct-slot-value 'ecc-review-note slot note)
              (cl-struct-slot-value 'ecc-review-note slot parent))))
    (cl-incf ecc-review--next-id)
    (setq ecc-review--notes (append ecc-review--notes (list note)))
    note))

(defun ecc-review-remove-note (note)
  "Take NOTE out of this review; draw again afterwards.
Its replies stay, drawn on their own: a reply of the user\='s is the
user\='s whatever happens to what it answered."
  (setq ecc-review--notes (delq note ecc-review--notes)))

(defun ecc-review--notes-on (line)
  "Return the shown comments that sit on LINE, in the order they were made."
  (let ((side (plist-get line :side)))
    (seq-filter (lambda (note)
                  (and (ecc-review--shown-p note)
                       (not (ecc-review-note-outdated note))
                       (equal (ecc-review-note-path note) (plist-get line :path))
                       (eq (ecc-review-note-side note) side)
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

(defun ecc-review-comment (text)
  "Put the comment TEXT on the line at point.
On the @@ header of a hunk the comment is about the whole hunk; on a
removed line it is about the old side, on an added or a context line
about the new.  Where the line carries a comment of yours already, TEXT
replaces it, and interactively that one is offered for editing.  Where
it carries only Claude\='s, TEXT is your reply to the last of them.
Returns the comment."
  (interactive
   (let* ((line (or (ecc-review--line-at-point)
                    (user-error "Not on a line of a hunk")))
          (target (ecc-review--comment-target line)))
     (list (pcase target
             (`(edit . ,note) (read-string "Comment: " (ecc-review-note-text note)))
             (`(reply . ,note)
              (read-string (format "Reply to Claude's #%d: " (ecc-review-note-id note))))
             (_ (read-string (if (plist-get line :side)
                                 "Comment on this line: "
                               "Comment on this hunk: ")))))))
  (let ((line (or (ecc-review--line-at-point)
                  (user-error "Not on a line of a hunk")))
        (text (string-trim text)))
    (when (string-empty-p text)
      (user-error "Empty comment"))
    (prog1 (pcase (ecc-review--comment-target line)
             (`(edit . ,note) (setf (ecc-review-note-text note) text) note)
             (`(reply . ,note)
              (ecc-review-add-note 'user text line (ecc-review-note-id note)))
             (_ (ecc-review-add-note 'user text line)))
      (ecc-review--draw-notes)
      (message "Comment attached (%d in all)"
               (seq-count (lambda (note) (not (ecc-review--agent-p note)))
                          ecc-review--notes)))))

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

(defun ecc-review--pick-note (notes prompt)
  "Return the one of NOTES asked for with PROMPT, or the only one."
  (if (cdr notes)
      (let* ((labels (mapcar #'ecc-review-note-label notes))
             (choice (completing-read prompt labels nil t)))
        (nth (seq-position labels choice) notes))
    (car notes)))

(defun ecc-review-remove-comment ()
  "Remove a comment on the line at point, whoever wrote it.
When the line carries more than one, which is asked."
  (interactive)
  (let ((note (ecc-review--pick-note
               (or (ecc-review--notes-here) (user-error "No comment on this line"))
               "Remove comment: ")))
    (ecc-review-remove-note note)
    (ecc-review--draw-notes)
    (message "Comment #%d removed (%d left)" (ecc-review-note-id note)
             (length ecc-review--notes))))

(defun ecc-review--ordered (notes)
  "Return NOTES in the order of the diff, then in the order they were made."
  (sort (copy-sequence notes)
        (lambda (a b)
          (let ((pa (or (ecc-review-note-position a) (point-max)))
                (pb (or (ecc-review-note-position b) (point-max))))
            (or (< pa pb)
                (and (= pa pb) (< (ecc-review-note-id a) (ecc-review-note-id b))))))))

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

(defun ecc-review-comments ()
  "Return your comments of this buffer in the order of the diff.
Claude\='s are left out: they are what Claude wrote, and the prompt is
what you have to say.  Each is a plist: :path, :start and :end of the
hunk\='s new side, :header, :text being the whole hunk, :position and
:comment; one on a line adds :side and :line, a reply :reply-to,
:reply-author and :reply-text, and one that matches no line of the diff
any more :outdated, its :text then being the hunk as it last was."
  (mapcar #'ecc-review--note-plist
          (ecc-review--ordered (seq-remove #'ecc-review--agent-p ecc-review--notes))))

(defun ecc-review--comment-label (comment)
  "Return the one line label of COMMENT used in the list."
  (format "%s  L%s-L%s: %s"
          (or (plist-get comment :path) "?")
          (plist-get comment :start) (plist-get comment :end)
          (ecc--truncate (plist-get comment :comment) 60)))

(defun ecc-review-list-comments ()
  "Pick one of the comments, either author's, and move to it."
  (interactive)
  (let* ((notes (or (ecc-review--ordered (seq-filter #'ecc-review--shown-p
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
  (ecc-review--draw-notes)
  (message (if ecc-review--show-agent
               "Showing Claude's comments"
             "Hiding Claude's comments")))

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
  "Return the prompt for the comments of the current review buffer, or nil."
  (when-let* ((comments (funcall ecc-review--comments-function)))
    (ecc-review-format-message comments
                               (and ecc-review--request ecc-review-proposal-header))))

;;;;; Confirming before sending

(defvar-local ecc-review-message--review nil
  "The review buffer whose comments this message carries.")

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
  "Send the comments of this review as one prompt and close it.
In the review of a proposal they are sent as the message of the deny
instead.  With a prefix argument EDIT the prompt is opened in a buffer
of its own first, to be read over and changed before it goes: the
comments are the prompt, so the common case is to send them as they
stand, and the key that says send sends."
  (interactive "P")
  (let* ((session (or ecc-review--session (user-error "Not a review buffer")))
         (text (or (ecc-review-buffer-message)
                   (user-error "No comment to send; put one on a hunk with c")))
         (review (current-buffer)))
    (if (not edit)
        (progn (ecc-review--deliver session text ecc-review--request)
               (ecc-review--close review)
               text)
      (let ((buffer (get-buffer-create (ecc-review-message-buffer-name session))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (ecc-review-message-mode)
            (insert text)
            (setq ecc-render--session session
                  ecc-review-message--review review)
            (set-buffer-modified-p nil)
            (goto-char (point-min))))
        (pop-to-buffer buffer)))))

(defun ecc-review-message-send ()
  "Send the text of this buffer and close the review it came from."
  (interactive)
  (let* ((review ecc-review-message--review)
         (session (or ecc-render--session (user-error "Not a review message")))
         (text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (request (and (buffer-live-p review)
                       (buffer-local-value 'ecc-review--request review)))
         (message-buffer (current-buffer)))
    (ecc-review--deliver session text request)
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer message-buffer)
    (ecc-review--close review)
    text))

(defun ecc-review-message-cancel ()
  "Drop this message and go back to the review buffer."
  (interactive)
  (let ((review ecc-review-message--review))
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer (current-buffer))
    (when (buffer-live-p review)
      (pop-to-buffer review)
      ;; An ediff review has no window of its own to pop to: the control
      ;; buffer is one of three, and only ediff can lay them out again.
      (when (derived-mode-p 'ediff-mode)
        (ediff-recenter)))))

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
  (when-let* ((root (ecc-review-git-root (or (ecc-session-project-root session)
                                             default-directory)))
              (base (or (ecc-session-baseline session)
                        (ecc-review--head-tree root)))
              (now (ecc-review-snapshot root)))
    (mapcar #'car (ecc-review--numstat root base now nil))))

(defun ecc-review--session-buffer (session paths)
  "Return the review of SESSION built from what the session recorded.
PATHS restricts it to those files.  The way a project outside git is
reviewed: there is no tree to compare
against, so the files the CLI reported editing are diffed against what
it reported them holding first."
  (let* ((entries (ecc-review-files session paths))
         (diff (and entries (ecc-review-diff-text entries))))
    (unless entries
      (user-error "No file was edited or written in this session"))
    (unless diff
      (user-error "The files of this session show no change"))
    (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                      session (car diff) (cdr diff) nil paths)))

(defun ecc-review-buffer (session &optional paths)
  "Return the buffer reviewing the changes of SESSION, filled and current.
PATHS restricts the review to those files.  Signals an error when no
file has a change to show.

In a git repository this is the working tree as it stands against the
baseline taken when the session started, so a file changed by a shell
command or a script reads like one changed by an edit, and work the
session committed along the way is still here.  A session that has no
baseline -- one that was already running before this Emacs learned to
take them -- falls back to HEAD, which is `ecc-review-worktree\='.
Outside git the session\='s own record is all there is."
  (let ((root (ecc-review-git-root (or (ecc-session-project-root session)
                                       default-directory))))
    (if (not root)
        (ecc-review--session-buffer session paths)
      (let* ((base (or (ecc-session-baseline session)
                       (ecc-review--head-tree root)
                       (user-error "Cannot read the history of %s"
                                   (abbreviate-file-name root))))
             (diff (ecc-review-baseline-diff root base paths)))
        (unless diff
          (user-error "Nothing has changed in %s since this session started"
                      (abbreviate-file-name root)))
        (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                          session diff root nil paths)))))

;;;###autoload
(defun ecc-review (&optional session paths)
  "Open everything that changed since SESSION started as one diff to review.
SESSION defaults to the session of the current buffer.  PATHS, given
interactively with a prefix argument, restricts the review to those
files.

This and `ecc-review-worktree\=' are the same review against different
bases: this one against where the session started, so the commits made
during it are still shown; that one against the last commit."
  (interactive
   (let ((session (ecc-review-session)))
     (list session
           (and current-prefix-arg
                (completing-read-multiple
                 "Files: "
                 (or (ecc-review-changed-paths session)
                     (mapcar #'ecc-file-entry-path (ecc-review-files session)))
                 nil t)))))
  (let ((session (or session (ecc-review-session))))
    (if (and (eq ecc-review-style 'ediff)
             ;; Outside git there are no two trees to lay side by side:
             ;; the review is built from what the session recorded, and
             ;; what that gives is a diff.
             (ecc-review-git-root (or (ecc-session-project-root session)
                                      default-directory)))
        (progn (require 'ecc-review-ediff)
               (ecc-review-ediff-buffer session paths))
      (ecc-window-display-review (ecc-review-buffer session paths) session))))

(defun ecc-review-refresh ()
  "Read the diff again, keeping the comments whose hunks still exist."
  (interactive)
  (let ((session (or ecc-review--session (user-error "Not a review buffer"))))
    (cond
     (ecc-review--request (ecc-review-request ecc-review--request))
     ;; `ecc-review--fill' left the repository in `default-directory', so
     ;; the refresh reads the same tree even from a session of another.
     (ecc-review--range (ecc-review-worktree-buffer session ecc-review--range
                                                    default-directory))
     (t (ecc-review-buffer session ecc-review--paths)))
    (message "Refreshed")))

;;;; Reviewing the working tree

(defvar ecc-review-worktree-default-range "HEAD"
  "What `ecc-review-worktree\=' diffs against without a prefix argument.
\"HEAD\" is everything uncommitted, staged or not, which is what the
CLI\='s own /diff shows.  \"\" is only what is not staged yet.")

(defun ecc-review-worktree-session (root)
  "Return the session the comments on the working tree of ROOT go to.
The session of ROOT is preferred over whichever session happens to be
current: a review of one project handed to a session running in another
would tell Claude to change files it is not looking at.  When ROOT has
no session, starting one is offered."
  (or (car (ecc-window-project-sessions root))
      (if (y-or-n-p (format "No session in %s.  Start one? "
                            (abbreviate-file-name root)))
          (ecc-start root)
        (user-error "The comments need a session to go to"))))

(defun ecc-review-worktree-buffer (session &optional range root)
  "Return the buffer reviewing the working tree of ROOT, filled and current.
The comments of the buffer go to SESSION.  ROOT defaults to the project
of SESSION, and RANGE to `ecc-review-worktree-default-range\='.  Every
change under the repository is shown, whoever made it, and the files git
does not track are appended.  Signals an error when the directory is not
a git repository or has nothing to show."
  (let* ((range (or range ecc-review-worktree-default-range))
         (directory (or root (ecc-session-project-root session)))
         (root (or (ecc-review-git-root directory)
                   (user-error "%s is not in a git repository"
                               (abbreviate-file-name directory))))
         ;; A repository with no commit has no HEAD to diff against, and
         ;; git calls that a bad revision rather than an empty diff.  The
         ;; empty tree is what HEAD would mean there, so the first code
         ;; written in a project can be reviewed before it is committed.
         ;; Only the bare "HEAD" is substituted: "main...HEAD" in such a
         ;; repository really is unresolvable, and still says so.  The
         ;; test is made afresh every time, so the first commit puts the
         ;; real HEAD back without anything having to be invalidated.
         (effective (if (and (equal range "HEAD") (ecc-review--unborn-p root))
                        (or (ecc-review--empty-tree root) range)
                      range))
         (tracked (pcase (ecc-review--git-diff root nil effective)
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
         (text (concat tracked (or (ecc-review-git-untracked root) ""))))
    (when (string-empty-p text)
      (user-error "No change against %s in %s"
                  (if (string-empty-p range) "the index" range)
                  (abbreviate-file-name root)))
    (ecc-review--fill (get-buffer-create
                       (ecc-review-buffer-name session nil range))
                      session text root nil nil range)))

(defun ecc-review-worktree--read-arguments ()
  "Return the (SESSION RANGE ROOT) `ecc-review-worktree\=' should run with.
The project comes from the buffer the user is working in -- this is a
command for the code, not for a transcript -- and the session from that
project, which is the one that can act on the diff."
  (let* ((buffer-session (ecc-window-buffer-session))
         (root (if buffer-session
                   (ecc-window-session-project buffer-session)
                 (ecc-window-context-project-root)))
         (session (or buffer-session (ecc-review-worktree-session root))))
    (list session
          (and current-prefix-arg
               (read-string "Diff against (empty for unstaged): "
                            ecc-review-worktree-default-range))
          root)))

;;;###autoload
(defun ecc-review-worktree (&optional session range root)
  "Open the git diff of the working tree as one diff to review.
Unlike `ecc-review\=', which shows what the session changed, this shows
every uncommitted change of the project -- your own work included -- so
that it can be commented on and handed to Claude.  ROOT is the project,
the one of the buffer the command was run from; SESSION is where the
comments go, the session of that project, started when it has none.
RANGE is what git diffs against, asked for with a prefix argument: a
revision like \"HEAD\", a range like \"main...HEAD\", or nothing for
what is not staged yet."
  (interactive (ecc-review-worktree--read-arguments))
  (let ((session (or session (ecc-review-session))))
    (pcase ecc-review-style
      ('ediff (require 'ecc-review-ediff)
              (ecc-review-ediff-worktree-buffer session range root))
      (_ (ecc-window-display-review (ecc-review-worktree-buffer session range root)
                                    session)))))

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
         (body (pcase name
                 ((or "Edit" "MultiEdit")
                  (let ((old (or (alist-get 'old_string input) ""))
                        (new (or (alist-get 'new_string input) "")))
                    (if (and before (string-search old before))
                        (ecc-diff-for-edit old new before
                                           ecc-review-proposal-context-lines)
                      (ecc-diff-format-hunks
                       (ecc-diff-hunks (ecc-diff-lines old new)
                                       ecc-review-proposal-context-lines)))))
                 ("Write"
                  (ecc-diff-for-write (or (alist-get 'content input) "") before
                                      ecc-review-proposal-context-lines))
                 (_ nil))))
    (when (and body (not (string-empty-p body)))
      (concat (ecc-review--file-header (or path "?") (null before))
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
        (push (ecc-review-proposal-note request ecc-review-proposal--original edited)
              (ecc-session-input-queue session))
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
