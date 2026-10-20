;;; ecc-git.el --- What git says about a directory  -*- lexical-binding: t; -*-

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

;; What this package asks git about a directory: which repository and
;; which worktree it is in, which branch is out, and what its files hold
;; at one moment.  Nothing here starts a session, changes a repository
;; or draws anything, so it sits under every module that needs an
;; answer -- the start of a session, its recording, the windows, the
;; review and the worktree commands -- and depends on `ecc-core' and
;; `ecc-model' alone: the model, for the baseline a session's review is
;; taken against.
;;
;; The sidebar asks, of every project it lists, whether it is a linked
;; worktree and of what -- `ecc-git-main-worktree' is what puts a
;; worktree under its parent -- and it asks on every redraw, so those
;; answers are kept for a few seconds rather than worked out again.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecc-core)
(require 'ecc-model)

(defvar ecc-git-executable "git"
  "Name of, or path to, the git executable.")

;;;; Running git

(defun ecc-git--call (directory stderr args)
  "Run git with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT).
Returns nil when git cannot be run at all.  STDERR is where what git
writes to stderr goes, as `call-process' takes it: nil throws it away,
t puts it in OUTPUT with the rest."
  (when (executable-find ecc-git-executable)
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory)))
        (condition-case err
            (cons (apply #'call-process ecc-git-executable nil
                         (list t stderr) nil args)
                  (buffer-string))
          (file-error
           (ecc-log "git" "git failed: %s" (error-message-string err))
           nil))))))

;; Two runners and not one, because they read different streams.  The
;; review parses what git prints -- a diff, a tree id, a list of names
;; split on NUL -- and a warning on stderr in the middle of that would
;; be read as part of it.  The worktree commands show git's refusal to
;; the user, and git refuses on stderr.  The questions about worktrees
;; below (`ecc-git-output') have always gone through the second, and
;; still do: on a success git writes nothing there they would misread.

(defun ecc-git-run (directory &rest args)
  "Run git with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT).
Returns nil when git cannot be run at all.  OUTPUT is what git wrote to
stdout; stderr is thrown away."
  (ecc-git--call directory nil args))

(defun ecc-git-run-with-stderr (directory &rest args)
  "Run git with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT).
Returns nil when git cannot be run at all, or DIRECTORY is not a
directory.  What git writes to stderr is in OUTPUT with the rest: the
whole point of asking git to create or remove a worktree is that its
refusal can be shown to the user, and it refuses on stderr."
  (when (file-directory-p directory)
    (ecc-git--call directory t args)))

;;;; What git says about the worktrees

(cl-defstruct ecc-git-worktree-entry
  path        ; the worktree, as `file-name-as-directory'
  branch      ; the branch it is on, without refs/heads/, or nil
  main-p      ; non-nil for the main worktree, which git lists first
  detached-p  ; non-nil when HEAD is not on a branch
  locked-p    ; git's reason, or t, when the worktree is locked, else nil
  prunable-p) ; git's reason when the worktree is gone, else nil

(defun ecc-git-output (directory &rest args)
  "Return the trimmed output of a successful git with ARGS in DIRECTORY.
Nil when git failed or could not be run.  An empty string is a fair
answer -- `git branch --list' says that way that the branch does not
exist -- so a caller that cares tells it from nil."
  (pcase (apply #'ecc-git-run-with-stderr directory args)
    (`(0 . ,output) (string-trim output))))

(defun ecc-git--short-branch (ref)
  "Return REF without the refs/heads/ in front of it."
  (if (string-prefix-p "refs/heads/" ref)
      (substring ref (length "refs/heads/"))
    ref))

(defun ecc-git-parse-worktrees (string)
  "Return the worktrees of a `git worktree list --porcelain' STRING.
A list of `ecc-git-worktree-entry', the main worktree first, which is the
order git prints them in.  A record is a `worktree PATH' line followed
by the attributes of that worktree -- `HEAD', `branch', `detached',
`bare', `locked' and `prunable' -- and a blank line ends it.  An
attribute this package has no use for is skipped rather than refused:
git adds them.  `locked' may carry a reason, put there by Claude Code's
own worktree (2026-09-14), and the reason is kept."
  (let ((entries nil)
        (current nil))
    (dolist (line (split-string (or string "") "\n"))
      (cond
       ((string-prefix-p "worktree " line)
        (setq current (make-ecc-git-worktree-entry
                       :path (file-name-as-directory
                              (substring line (length "worktree ")))
                       :main-p (null entries)))
        (push current entries))
       ((null current) nil)
       ((string-prefix-p "branch " line)
        (setf (ecc-git-worktree-entry-branch current)
              (ecc-git--short-branch (substring line (length "branch ")))))
       ((equal line "detached")
        (setf (ecc-git-worktree-entry-detached-p current) t))
       ((string-prefix-p "locked" line)
        (setf (ecc-git-worktree-entry-locked-p current)
              (let ((reason (string-trim (substring line (length "locked")))))
                (if (string-empty-p reason) t reason))))
       ((string-prefix-p "prunable" line)
        (setf (ecc-git-worktree-entry-prunable-p current)
              (or (string-trim (substring line (length "prunable"))) t)))))
    (nreverse entries)))

;;;; Keeping the answers

;; The sidebar asks `ecc-git-main-worktree' and `ecc-git-branch' of
;; every project it draws, on every redraw, and each of those is a git
;; process.  The answers are kept the way `ecc-window--project-root-cache'
;; keeps a project root, with a clock on top: a branch does change under
;; Emacs, unlike a project root, so the cache is thrown away by the
;; worktree commands and goes stale on its own besides.  A test binds a
;; fresh hash.

(defvar ecc-git--cache (make-hash-table :test #'equal)
  "Hash of a question about a directory to the answer git gave.")

(defvar ecc-git--cache-ttl 10
  "How many seconds an answer from git is reused for.
Long enough that a redraw costs no process, short enough that a branch
switched in a terminal shows up without anybody asking for it.")

(defun ecc-git-forget ()
  "Forget what git has said about the worktrees.
The next question asks git again.  Called by the worktree commands,
and by whatever offers the user a way to refresh."
  (clrhash ecc-git--cache))

(defun ecc-git--memo (key thunk)
  "Return the value of THUNK for KEY, asking it at most every few seconds."
  (let ((hit (gethash key ecc-git--cache))
        (now (float-time)))
    (if (and hit (< (- now (car hit)) ecc-git--cache-ttl))
        (cdr hit)
      (cdr (puthash key (cons now (funcall thunk)) ecc-git--cache)))))

(defun ecc-git--key (directory)
  "Return the cache key DIRECTORY is asked under."
  (file-name-as-directory (expand-file-name (or directory default-directory))))

(defun ecc-git-worktrees (root)
  "Return the worktrees of the repository holding ROOT, main first.
Nil when ROOT is not in a git repository, or git is not installed."
  (let ((root (ecc-git--key root)))
    (ecc-git--memo
     (cons 'list root)
     (lambda ()
       (when-let* ((output (ecc-git-output
                            root "worktree" "list" "--porcelain")))
         (ecc-git-parse-worktrees output))))))

(defun ecc-git-toplevel (directory)
  "Return the top of the worktree holding DIRECTORY, or nil."
  (let ((directory (ecc-git--key directory)))
    (ecc-git--memo
     (cons 'toplevel directory)
     (lambda ()
       (when-let* ((output (ecc-git-output
                            directory "rev-parse" "--show-toplevel")))
         (and (not (string-empty-p output))
              (file-name-as-directory output)))))))

(defun ecc-git-main-worktree (root)
  "Return the main worktree of ROOT when ROOT is a linked worktree.
Nil when ROOT is the main worktree itself, or is not in a repository at
all.  That nil is the whole answer a caller needs to lay a repository
out: a directory with a main worktree above it is a worktree of
somebody else's project, and everything else stands on its own.

The paths are compared through `file-truename' because git resolves
symbolic links and the caller has not: on macOS a worktree under
\"/tmp\" is \"/private/tmp\" to git and neither spelling is wrong."
  (let ((root (ecc-git--key root)))
    (ecc-git--memo
     (cons 'main root)
     (lambda ()
       (when-let* ((top (ecc-git-toplevel root))
                   (entries (ecc-git-worktrees root))
                   (main (ecc-git-worktree-entry-path (car entries))))
         (unless (equal (file-truename main) (file-truename top))
           main))))))

(defun ecc-git-session-name (root)
  "Return what a session started in ROOT should be called, or nil.
The branch, when ROOT is a worktree of a repository: that is what the
Space above it is called and what the user asked for, and the directory
is a slug of the branch that says nothing more -- one screen calling the
same thing `feat/one\=' and `feat-one\=' is one name too many (2026-09-17).

Nil for the main worktree and for a directory outside a repository,
where the name of the directory is the answer, and for a detached HEAD,
which has no branch.  The `worktree/\=' herdr puts in front of the
branches it generates is dropped, as `ecc-space--name\=' drops it."
  (when (ecc-git-main-worktree root)
    (when-let* ((branch (ecc-git-branch root)))
      (string-remove-prefix "worktree/" branch))))

(defun ecc-git-branch (root)
  "Return the branch checked out in ROOT, or nil.
Nil for a detached HEAD as well as for a directory that is not in a
repository: neither has a branch to name."
  (let ((root (ecc-git--key root)))
    (ecc-git--memo
     (cons 'branch root)
     (lambda ()
       (when-let* ((ref (ecc-git-output
                         root "symbolic-ref" "--quiet" "HEAD")))
         (and (not (string-empty-p ref))
              (ecc-git--short-branch ref)))))))

(defun ecc-git-ahead-behind (root)
  "Return (AHEAD . BEHIND) of ROOT against its upstream, or nil.
Nil when the branch has no upstream, which is the usual case for a
branch that was made here and never pushed.

The left side of `rev-list --left-right' is the first revision named,
which is the upstream, so the left count is what the upstream has and
HEAD does not -- behind -- and the right count is ahead.  Verified
against git 2.50.1 by `ecc-git-test-ahead-behind' (2026-09-14)."
  (let ((root (ecc-git--key root)))
    (ecc-git--memo
     (cons 'ahead-behind root)
     (lambda ()
       (when-let* ((output (ecc-git-output
                            root "rev-list" "--left-right" "--count"
                            "@{u}...HEAD")))
         (pcase (split-string output)
           (`(,behind ,ahead)
            (cons (string-to-number ahead) (string-to-number behind)))))))))

(defun ecc-git-worktree-of-branch (root branch)
  "Return the worktree of the repository ROOT that has BRANCH checked out.
Nil when no worktree holds it.  git allows one branch in one worktree
at a time, so this is what says in advance that `ecc-worktree-create'
would be refused -- and where the work on that branch already is."
  (seq-find (lambda (entry) (equal (ecc-git-worktree-entry-branch entry) branch))
            (ecc-git-worktrees root)))

(defun ecc-git-branches (root)
  "Return the local branches of the repository holding ROOT."
  (when-let* ((output (ecc-git-output
                       root "branch" "--format=%(refname:short)")))
    (split-string output "\n" t)))

;;;; Where a repository is

(defun ecc-git-root (path)
  "Return the root of the git repository holding PATH, or nil.
PATH may name a file: its directory is asked.  Unlike
`ecc-git-toplevel', which the sidebar asks on every redraw, the answer is
not kept, so a review always asks git afresh."
  (let ((directory (file-name-directory (expand-file-name path))))
    (when (file-directory-p directory)
      (pcase (ecc-git-run directory "rev-parse" "--show-toplevel")
        (`(0 . ,output)
         (let ((root (string-trim output)))
           (and (not (string-empty-p root))
                (file-name-as-directory (expand-file-name root)))))))))

;;;; What the working tree held at one moment

(defun ecc-git--with-index (root index &rest args)
  "Run git with ARGS in ROOT against the index file INDEX.
Returns (EXIT-CODE . OUTPUT) like `ecc-git-run\=', or nil."
  (let ((process-environment
         (cons (concat "GIT_INDEX_FILE=" index) process-environment)))
    (apply #'ecc-git-run root args)))

(defun ecc-git-snapshot (root &optional no-add)
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
  (let ((index (ecc-git--snapshot-index root)))
    (unwind-protect
        (ecc-git--snapshot-tree
         root
         (if no-add
             '(0 . "")
           (ecc-git--with-index root index "add" "-A" "--"))
         (lambda () (ecc-git--with-index root index "write-tree")))
      (when (file-exists-p index) (delete-file index)))))

(defun ecc-git--snapshot-index (root)
  "Return a throwaway index file for a snapshot of ROOT.
It is a copy of the repository\='s own index, for its stat cache, or a
name with no file behind it when there is none to copy."
  (let ((index (make-temp-file "ecc-review-index"))
        (real (pcase (ecc-git-run root "rev-parse" "--git-path" "index")
                (`(0 . ,output)
                 (expand-file-name (string-trim output) root)))))
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
    index))

(defun ecc-git--snapshot-tree (root added write-tree)
  "Return the tree of a snapshot of ROOT, or nil.
ADDED is what `git add' returned, and WRITE-TREE runs `git write-tree'
when it succeeded."
  (pcase added
    (`(0 . ,_)
     (pcase (funcall write-tree)
       (`(0 . ,output)
        (let ((tree (string-trim output)))
          (and (not (string-empty-p tree)) tree)))
       (result (ecc-log "review" "write-tree failed in %s: %S" root result)
               nil)))
    (result (ecc-log "review" "snapshot failed in %s: %S" root result)
            nil)))

(defun ecc-git-ensure-baseline (session)
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
            (when-let* ((root (ecc-git-root
                               (or (ecc-session-project-root session)
                                   default-directory))))
              (ecc-git-snapshot root)))))

(defun ecc-git--snapshot-async (root callback)
  "Take `ecc-git-snapshot' of ROOT in the background.
CALLBACK is called with the tree, or nil, once git is done.

Only `git add' runs in the background: it opens every file whose stat
the index does not vouch for, and an antivirus that scans each file
opened made that 15 s on a repository of 5700 files, against 0.15 s
once they had been scanned (2026-10-20, Defender and Jamf Protect on
macOS).  `git write-tree' reads the index and the object store alone,
and took 30 ms there."
  (let ((index (ecc-git--snapshot-index root))
        (output (generate-new-buffer " *ecc-git-snapshot*"))
        (errors (generate-new-buffer " *ecc-git-snapshot-stderr*")))
    (condition-case err
        (let ((default-directory (file-name-as-directory root))
              (process-environment
               (cons (concat "GIT_INDEX_FILE=" index) process-environment)))
          (make-process
           :name "ecc-git-snapshot"
           :command (list ecc-git-executable "add" "-A" "--")
           :buffer output
           :stderr errors
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (let ((added (cons (process-exit-status process)
                                  (with-current-buffer errors
                                    (buffer-string)))))
                 (kill-buffer output)
                 (kill-buffer errors)
                 (funcall callback
                          (unwind-protect
                              (ecc-git--snapshot-tree
                               root added
                               (lambda ()
                                 (ecc-git--with-index root index "write-tree")))
                            (when (file-exists-p index)
                              (delete-file index)))))))))
      (file-error
       (ecc-log "review" "git failed: %s" (error-message-string err))
       (kill-buffer output)
       (kill-buffer errors)
       (when (file-exists-p index) (delete-file index))
       (funcall callback nil)))))

(defun ecc-git-start-baseline (session &optional then)
  "Start taking the baseline of SESSION in the background.
This is `ecc-git-ensure-baseline' without the wait, for the start of a
session: the baseline is taken unless SESSION has one, and
`ecc-session-baseline-pending' is set until git is done.  THEN, when
non-nil, is called with SESSION at that moment.  Nothing is started,
and THEN is not called, for a session that has a baseline, is taking
one, or is outside git."
  (unless (or (ecc-session-baseline session)
              (ecc-session-baseline-pending session))
    (when-let* ((root (ecc-git-root (or (ecc-session-project-root session)
                                        default-directory))))
      (setf (ecc-session-baseline-pending session) t)
      (ecc-git--snapshot-async
       root
       (lambda (tree)
         (setf (ecc-session-baseline session) tree
               (ecc-session-baseline-pending session) nil)
         (when then (funcall then session)))))))

(provide 'ecc-git)

;;; ecc-git.el ends here
