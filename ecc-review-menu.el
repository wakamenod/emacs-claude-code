;;; ecc-review-menu.el --- Choose what a review compares  -*- lexical-binding: t; -*-

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

;; `ecc-review-menu' is where a review starts.  It asks what to compare
;; before anything is opened -- what the session changed since it
;; started, the working tree against HEAD, what is staged or not, this
;; branch against the one it forked from, a commit, or a range typed by
;; hand -- and says how many files each would show.  A menu is about
;; one session and its project: the session's changes, that project's
;; working tree and branches, and that session to send the comments to.
;; `S' turns the whole menu to another session.  What it opens is `ecc-review' or
;; `ecc-review-worktree' with the arguments chosen, and those are the
;; arguments `review_open' takes, so a review Claude is asked for in the
;; same words is the same review (`ecc-review-agent-open-description').
;;
;; Only what the transient bundled with Emacs 29.1 (0.4.1) has is used.
;; What the open menu is about lives in a variable of this file rather
;; than in the scope of the prefix, whose accessors are not the same in
;; 0.4.1 and in the transient of later Emacsen; it is dropped when the
;; menu goes away, so that nothing outlives it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-window)
(require 'ecc-review)

(defcustom ecc-review-menu-count-session-changes t
  "Non-nil makes `ecc-review-menu' count what the session changed.
That is the number beside `D', the files changed since the session
started, and it takes a snapshot of the working tree, which reads every
file: 35 ms on a repository of 300 files and 70 ms on one of 20000
\(measured 2026-10-01).  Set it to nil where that is too slow to open a
menu on; `D' stays, without its number."
  :type 'boolean
  :group 'ecc)

(defvar ecc-review-menu-base-candidates '("develop" "main" "master")
  "The branches `b' in `ecc-review-menu' guesses the current one forked from.
The branch origin/HEAD points at is tried too, and so is the upstream
of the current branch when that is itself one of them -- main against
origin/main is what has not been pushed.  See
`ecc-review-menu-guess-base' for how one is chosen.")

(defvar ecc-review-menu-commit-count 100
  "How many recent commits `c' in `ecc-review-menu' offers.")

(defconst ecc-review-menu--labels
  '((session . "since the session started")
    (worktree . "uncommitted (vs HEAD)")
    (unstaged . "unstaged")
    (staged . "staged")
    (branch . "this branch vs %s")
    (commit . "a commit…")
    (range . "a range…"))
  "What each choice of the menu compares, in the words the menu uses.")

(defvar ecc-review-menu--state nil
  "What the open `ecc-review-menu' is about, as a plist, or nil.
:session is the session reviewed and sent the comments, nil when there
is none; :directory is its project; :root the git root of that, nil
outside git; :branch the branch checked out and :branches every branch;
:base the guess at the branch the current one forked from and :fork
the commit where they part; :counts an alist of a choice to how many
files it would show -- a number, nil when it is not counted, or a
string saying why it could not be.  Dropped when the menu goes away
\(`ecc-review-menu--forget-state').")

(defvar ecc-review-menu--last nil
  "The choice made last in `ecc-review-menu', a symbol of its labels.")

(defvar ecc-review-menu--branch-history nil
  "Branches typed at the questions of `b'.")

(defvar ecc-review-menu--commit-history nil
  "Commits typed at the questions of `c'.")

;;;; Asking git

(defun ecc-review-menu--refs (root)
  "Return what the branches of ROOT are, as a plist, from one call of git.
:current is the branch checked out, nil when HEAD is detached;
:upstream the branch it tracks; :origin-head the branch origin/HEAD
points at; :branches the local and then the remote branches, without
the symbolic origin/HEAD, which names one of them again."
  (pcase (ecc-review--git root "for-each-ref"
                          "--format=%(HEAD)%00%(refname)%00%(upstream:short)%00%(symref)"
                          "refs/heads" "refs/remotes")
    (`(0 . ,output)
     (let (current upstream origin-head locals remotes)
       (dolist (line (split-string output "\n" t))
         (pcase-let ((`(,head ,ref ,up ,symref) (split-string line "\0")))
           (cond
            ((string-prefix-p "refs/heads/" ref)
             (let ((name (substring ref (length "refs/heads/"))))
               (push name locals)
               (when (equal head "*")
                 (setq current name
                       upstream (and up (not (string-empty-p up)) up)))))
            ((string-suffix-p "/HEAD" ref)
             (when (and (equal ref "refs/remotes/origin/HEAD")
                        symref (string-prefix-p "refs/remotes/" symref))
               (setq origin-head (substring symref (length "refs/remotes/")))))
            ((string-prefix-p "refs/remotes/" ref)
             (push (substring ref (length "refs/remotes/")) remotes)))))
       (list :current current :upstream upstream :origin-head origin-head
             :branches (append (nreverse locals) (nreverse remotes)))))))

(defun ecc-review-menu-guess-base (root &optional refs)
  "Return (BASE . FORK): the branch HEAD of ROOT most likely forked from.
FORK is the commit where the two part.  REFS is what
`ecc-review-menu--refs' says of ROOT, read again when not given.

The candidates are `ecc-review-menu-base-candidates', the branch
origin/HEAD points at, and the upstream of the current branch when the
current branch is one of those -- on main, origin/main is where the
commits not pushed yet show.  Left out are the ones that do not exist,
the current branch, and any that already holds HEAD: develop when main
is checked out and develop is ahead of it would compare HEAD with
itself.  Of the rest, the one HEAD has the fewest commits beyond -- the
commits from where the two part to HEAD -- wins, and of a tie the one
whose own tip is nearest that point.  Nil when none is left."
  (let* ((refs (or refs (ecc-review-menu--refs root)))
         (current (plist-get refs :current))
         (branches (plist-get refs :branches))
         (origin (plist-get refs :origin-head))
         (bases (append ecc-review-menu-base-candidates (and origin (list origin))))
         (upstream (and current
                        (member current (append ecc-review-menu-base-candidates
                                                (and origin (list (file-name-nondirectory
                                                                   origin)))))
                        (plist-get refs :upstream)))
         (candidates (seq-filter (lambda (branch)
                                   (and (member branch branches)
                                        (not (equal branch current))))
                                 (delete-dups (append bases (and upstream (list upstream))))))
         (best nil))
    (dolist (candidate candidates)
      ;; One call: the commits only the candidate has, and those only HEAD has.
      (when-let* ((counts (ecc-review--git-string root "rev-list" "--left-right" "--count"
                                                  (concat candidate "...HEAD") "--")))
        (pcase-let ((`(,theirs ,ours) (mapcar #'string-to-number (split-string counts))))
          (when (and (> ours 0)
                     (or (null best)
                         (< ours (car best))
                         (and (= ours (car best)) (< theirs (cadr best)))))
            (setq best (list ours theirs candidate))))))
    (when-let* ((base (nth 2 best))
                (fork (ecc-review--merge-base root base "HEAD")))
      (cons base fork))))

(defun ecc-review-menu--status (root)
  "Return the changed files of ROOT, read by one `git status', or nil.
A plist of :staged, :unstaged and :untracked, each a list of paths
relative to ROOT.  One call reads the working tree once for the three
counts that each took a `git diff' of their own -- and a listing of the
untracked files besides -- before."
  (pcase (ecc-review--git root "status" "--porcelain=v1" "-z" "--untracked-files=all")
    (`(0 . ,output)
     (let ((fields (split-string output "\0" t))
           staged unstaged untracked)
       (while fields
         (let* ((field (pop fields))
                (x (aref field 0))
                (y (aref field 1))
                (path (substring field 3)))
           (cond ((and (eq x ??) (eq y ??)) (push path untracked))
                 ((and (eq x ?!) (eq y ?!)))
                 (t (unless (eq x ?\s) (push path staged))
                    (unless (eq y ?\s) (push path unstaged))))
           ;; A rename or a copy names where it came from in the next field.
           (when (or (memq x '(?R ?C)) (memq y '(?R ?C)))
             (pop fields))))
       (list :staged staged :unstaged unstaged :untracked untracked)))))

(defun ecc-review-menu--branch-count (root fork status)
  "Return how many files ROOT holds that differ from the commit FORK.
STATUS is `ecc-review-menu--status' of ROOT: what the commits since FORK
changed, read from the history alone, together with what is changed in
the working tree, which STATUS has read already."
  (pcase (ecc-review--git root "diff" "--name-only" "-z" fork "HEAD" "--")
    (`(0 . ,output)
     (length (delete-dups (append (split-string output "\0" t)
                                  (plist-get status :staged)
                                  (plist-get status :unstaged)
                                  (plist-get status :untracked)))))
    (`(,code . ,_) (format "git diff failed (exit %s)" code))))

(defun ecc-review-menu--session-count (session)
  "Return how many files SESSION changed since it started.
Nil without a session or with `ecc-review-menu-count-session-changes'
off, and a string saying why when it could not be counted -- a count
of none is a number, 0, which a failure must not pass for."
  (when (and session ecc-review-menu-count-session-changes)
    (let ((root (ecc-review-git-root (or (ecc-session-project-root session)
                                         default-directory))))
      (if (not root)
          (length (ecc-review-files session))
        (let ((base (or (ecc-session-baseline session) (ecc-review--head-tree root)))
              (now (ecc-review-snapshot root)))
          (cond
           ((not base) "there is no tree to compare with")
           ((not now) "the working tree could not be read")
           (t (pcase (ecc-review--git root "diff" "--name-only" "-z" "--no-renames"
                                      base now "--")
                (`(0 . ,output) (length (split-string output "\0" t)))
                (`(,code . ,_) (format "git diff failed (exit %s)" code))
                (_ "git cannot be run")))))))))

(defun ecc-review-menu-counts (session root fork)
  "Return an alist of each choice of the menu to how many files it shows.
SESSION is the session of `D'; ROOT the repository, nil outside git;
FORK the commit of `b'.  A count is a number, nil when there is nothing
to count -- a commit or a range not chosen yet, a branch with no base
-- or a string saying why it could not be counted."
  (let ((status (and root (ecc-review-menu--status root)))
        (failed "git status failed"))
    `((session . ,(ecc-review-menu--session-count session))
      ,@(when root
          (let ((staged (plist-get status :staged))
                (unstaged (plist-get status :unstaged))
                (untracked (plist-get status :untracked)))
            `((worktree . ,(if status
                               (length (delete-dups (append staged unstaged untracked)))
                             failed))
              (unstaged . ,(if status
                               (length (delete-dups (append unstaged untracked)))
                             failed))
              (staged . ,(if status (length staged) failed))
              (branch . ,(and fork
                              (if status
                                  (ecc-review-menu--branch-count root fork status)
                                failed)))))))))

;;;; What a choice compares

(defun ecc-review-menu--name (name what example)
  "Return NAME, which is WHAT, trimmed; nil when it is empty.
A NAME starting with - is refused with a message naming WHAT is
expected and EXAMPLE of it: it would reach git as an option.  Unlike
the range of `r', --staged means nothing here."
  (let ((name (and name (string-trim name))))
    (cond ((or (null name) (string-empty-p name)) nil)
          ((string-prefix-p "-" name)
           (user-error "%s is expected here, like %s; %s is an option" what example name))
          (t name))))

(defun ecc-review-menu-branch-range (root base &optional other state)
  "Return (RANGE . LABEL), what `b' reviews in ROOT: OTHER against BASE.
OTHER nil, empty, HEAD or the current branch is the current branch
with its working tree.  RANGE is then the commit where it parted from
BASE, which `git diff' compares with the working tree, so what is not
committed yet and the files git does not track are in the review as
well (`ecc-review--range-includes-worktree-p'), and LABEL is \"BASE +
working tree\", what the review is called (`ecc-review-range-label').
Any other branch is BASE...OTHER, what a pull request of OTHER into
BASE shows, and needs no LABEL.  STATE, the menu's, supplies the
current branch and the fork of its base, which are read from git when
it is not given."
  (let* ((base (or (ecc-review-menu--name base "A branch" "develop or origin/main")
                   (user-error "Name the branch to compare with")))
         (other (ecc-review-menu--name other "A branch" "feature or HEAD"))
         (current (if state
                      (plist-get state :branch)
                    (ecc-review--git-string root "symbolic-ref" "--quiet" "--short" "HEAD"))))
    (if (or (null other) (member other (list "HEAD" current)))
        (cons (or (and state (equal base (plist-get state :base)) (plist-get state :fork))
                  (ecc-review--merge-base root base "HEAD")
                  (user-error "%s and HEAD have no commit in common in %s"
                              base (abbreviate-file-name root)))
              (format "%s + working tree" base))
      (cons (format "%s...%s" base other) nil))))

(defun ecc-review-menu--commit-id (root revision)
  "Return the commit REVISION names in ROOT, or signal that it names none."
  (or (ecc-review--git-string root "rev-parse" "--verify" "--quiet"
                              (concat revision "^{commit}"))
      (user-error "%s is not a commit in %s" revision (abbreviate-file-name root))))

(defun ecc-review-menu--commit-label (root from &optional to)
  "Return what the review of the commit FROM, or FROM through TO, is called.
The short id and the subject of one commit, or the short ids of two, as
git in ROOT abbreviates them."
  (if to
      ;; `rev-parse --short' shortens one revision, not two.
      (string-join (split-string (or (ecc-review--git-string root "log" "--no-walk=unsorted"
                                                             "--format=%h" from to "--")
                                     (concat from "\n" to)))
                   " to ")
    (let ((line (ecc-review--git-string root "log" "-1" "--no-color"
                                        "--format=%h %s" from)))
      (ecc--truncate (or line from) 48))))

(defun ecc-review-menu-commit-range (root from &optional to)
  "Return (RANGE . LABEL), what `c' reviews in ROOT: FROM, or FROM through TO.
TO nil, empty or the commit FROM is FROM alone, FROM^! -- what Hunk
calls `hunk show'.  Otherwise it is FROM^..TO, FROM included; the two
are put in order first, so that a TO older than FROM is the same span
picked the other way round.  A commit with no parent -- the first of
the repository -- is compared with the empty tree instead, which is
what a parent would have held: FROM^! there names FROM alone, and git
would compare it with the working tree.

RANGE names the commits by their ids, not by the names typed: HEAD or
main moves, and a review read again would show another commit under
the same comments.  LABEL is what the review is called
\(`ecc-review-menu--commit-label')."
  (let* ((from (or (ecc-review-menu--name from "A commit" "HEAD or a1b2c3d")
                   (user-error "Name the commit to review")))
         (to (ecc-review-menu--name to "A commit" "HEAD or a1b2c3d"))
         (from-id (ecc-review-menu--commit-id root from))
         (to-id (and to (ecc-review-menu--commit-id root to))))
    (when (equal to-id from-id)
      (setq to-id nil))
    ;; TO older than FROM: swap them.
    (when (and to-id (eq 0 (car (ecc-review--git root "merge-base" "--is-ancestor"
                                                  to-id from-id))))
      (cl-rotatef from-id to-id))
    (let ((parent (ecc-review--git-string root "rev-parse" "--verify" "--quiet"
                                          (concat from-id "^"))))
      (cons (cond
             ((and parent (null to-id)) (concat from-id "^!"))
             (parent (format "%s^..%s" from-id to-id))
             (t (format "%s..%s"
                        (or (ecc-review--empty-tree root)
                            (user-error "Cannot name the empty tree in %s"
                                        (abbreviate-file-name root)))
                        (or to-id from-id))))
            (ecc-review-menu--commit-label root from-id to-id)))))

;;;; What the menu is about

(defun ecc-review-menu--project (session)
  "Return the project directory of SESSION."
  (file-name-as-directory (expand-file-name (ecc-window-session-project session))))

(defun ecc-review-menu--context ()
  "Return (SESSION . DIRECTORY), what the menu opened here is about.
`ecc-review-context': the session of the current buffer or of its
project.  When that project has none, the session used last and its
own project, which is what \\`C-c c D' reviewed before it asked what to
compare; the heading names it, and `S' turns the menu to another."
  (let ((context (ecc-review-context)))
    (if-let* (((null (car context)))
              (recent (car (ecc-model-sessions))))
        (cons recent (ecc-review-menu--project recent))
      context)))

(defun ecc-review-menu-make-state (session directory)
  "Return what the menu is about for SESSION and DIRECTORY; see the state."
  (let* ((root (and directory (ecc-review-git-root directory)))
         (refs (and root (ecc-review-menu--refs root)))
         (guess (and root (ecc-review-menu-guess-base root refs))))
    (list :session session :directory directory :root root
          :branch (plist-get refs :current) :branches (plist-get refs :branches)
          :base (car guess) :fork (cdr guess)
          :counts (ecc-review-menu-counts session root (cdr guess)))))

(defun ecc-review-menu--current-state ()
  "Return the state of the open menu.
With no menu open -- a suffix run with \\[execute-extended-command] --
one is made afresh from the current buffer, and not kept."
  (or ecc-review-menu--state
      (let ((context (ecc-review-menu--context)))
        (ecc-review-menu-make-state (car context) (cdr context)))))

(defmacro ecc-review-menu--with-state (&rest body)
  "Run BODY with `ecc-review-menu--state' the state of the open menu.
When no menu is open, a state made from the current buffer for BODY
alone."
  (declare (indent 0) (debug t))
  `(let ((ecc-review-menu--state (ecc-review-menu--current-state)))
     ,@body))

(defun ecc-review-menu--forget-state ()
  "Drop the state of the menu once no review menu is open.
On `transient-exit-hook', which runs after the suffix that closed the
menu has finished, and also when another menu hands over to this one
-- D in `ecc-menu' -- when the menu now open is this one and its state
is kept.  Without this the state of the last menu stayed: a suffix run
later from elsewhere reviewed that menu's project, and a killed
session was kept alive."
  (unless (and (bound-and-true-p transient--prefix)
               (eq (oref transient--prefix command) 'ecc-review-menu))
    (setq ecc-review-menu--state nil)))

(defun ecc-review-menu--root ()
  "Return the repository the menu reviews, or signal that it is not in one."
  (let ((state (ecc-review-menu--current-state)))
    (or (plist-get state :root)
        (user-error "%s is not in a git repository"
                    (abbreviate-file-name (or (plist-get state :directory)
                                              default-directory))))))

(defun ecc-review-menu--outside-git-p ()
  "Return non-nil when the menu has no repository to compare in."
  (null (plist-get ecc-review-menu--state :root)))

(defun ecc-review-menu--no-base-p ()
  "Return non-nil when the menu has no branch for `b' to compare with."
  (null (plist-get ecc-review-menu--state :base)))

(defun ecc-review-menu--no-session-p ()
  "Return non-nil when the menu has no session to review the changes of."
  (null (plist-get ecc-review-menu--state :session)))

(defun ecc-review-menu-set-session (session)
  "Turn the menu to SESSION: its changes, its project, its comments.
A session of the same project changes the session and what it changed,
and nothing else is read again; one of another project makes the whole
menu again from that project, so that what is reviewed and where the
comments go cannot be two projects."
  (let* ((state (ecc-review-menu--current-state))
         (directory (ecc-review-menu--project session)))
    (setq ecc-review-menu--state
          (if (equal directory (plist-get state :directory))
              (let ((state (copy-sequence state)))
                (plist-put (plist-put state :session session)
                           :counts (cons (cons 'session (ecc-review-menu--session-count
                                                         session))
                                         (assq-delete-all
                                          'session (copy-alist (plist-get state :counts))))))
            (ecc-review-menu-make-state session directory)))
    session))

;;;; Opening the review

(defun ecc-review-menu--style (args)
  "Return the `ecc-review-style' the menu ARGS ask for this one review."
  (cond ((member "--ediff" args) 'ediff)
        ((member "--diff" args) 'diff)
        (t ecc-review-style)))

(defun ecc-review-menu-open (choice range args &optional label)
  "Open the review CHOICE stands for, against RANGE, with the menu's ARGS.
CHOICE `session' is `ecc-review' of the session of the menu; anything
else is `ecc-review-worktree' of its directory against RANGE, the
comments going to that session, or to one of the directory that is
offered to start when there is none.  LABEL is what that review is
called (`ecc-review-range-label').  --files among ARGS asks for the
files of that review to keep, and --ediff or --diff is the
`ecc-review-style' of this review alone.  CHOICE is remembered."
  (ecc-review-menu--with-state
    (let* ((state ecc-review-menu--state)
           (session (plist-get state :session))
           (directory (plist-get state :directory))
           (files (member "--files" args))
           (ecc-review-style (ecc-review-menu--style args))
           (ecc-review-range-label label))
      (setq ecc-review-menu--last choice)
      (if (eq choice 'session)
          (let ((session (or session (user-error "No session has changes to review"))))
            (ecc-review session (and files (ecc-review-read-paths session))))
        (let ((session (or session (ecc-review-worktree-session directory))))
          (ecc-review-worktree session range directory
                               (and files (ecc-review-worktree-read-paths
                                           directory range))))))))

;;;; Asking

(defun ecc-review-menu--in-order (candidates)
  "Return a completion table of CANDIDATES that keeps their order."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun ecc-review-menu--read-base ()
  "Ask for the branch to compare with, the guessed one by default."
  (let* ((state ecc-review-menu--state)
         (guess (plist-get state :base)))
    (completing-read (format-prompt "Compare with the branch" guess)
                     (ecc-review-menu--in-order (plist-get state :branches))
                     nil nil nil 'ecc-review-menu--branch-history guess)))

(defun ecc-review-menu--read-other (base)
  "Ask what to compare with BASE: the current branch by default."
  (let* ((state ecc-review-menu--state)
         (current (or (plist-get state :branch) "HEAD")))
    (completing-read (format "Compare %s with (default %s with its working tree): "
                             base current)
                     (ecc-review-menu--in-order (plist-get state :branches))
                     nil nil nil 'ecc-review-menu--branch-history current)))

(defun ecc-review-menu--commits (root)
  "Return the recent commits of ROOT as \"ID SUBJECT\" lines, newest first."
  (pcase (ecc-review--git root "log" "--no-color" "--format=%h %s"
                          "-n" (number-to-string ecc-review-menu-commit-count))
    (`(0 . ,output) (split-string output "\n" t))))

(defun ecc-review-menu--commit-of (answer)
  "Return the commit an ANSWER of `c' names: its first word."
  (car (split-string answer nil t)))

(defun ecc-review-menu--read-commits (root)
  "Ask for a commit of ROOT and for the last one to review with it.
Return (FROM TO), TO nil when the answer was FROM again."
  (let* ((commits (or (ecc-review-menu--commits root)
                      (user-error "There is no commit in %s yet"
                                  (abbreviate-file-name root))))
         (from (completing-read (format-prompt "Review the commit" (car commits))
                                (ecc-review-menu--in-order commits)
                                nil nil nil 'ecc-review-menu--commit-history
                                (car commits)))
         (line (or (seq-find (lambda (commit)
                               (equal (ecc-review-menu--commit-of commit)
                                      (ecc-review-menu--commit-of from)))
                             commits)
                   from))
         (to (completing-read "Through (default that commit alone): "
                              (ecc-review-menu--in-order commits)
                              nil nil nil 'ecc-review-menu--commit-history line))
         (from (ecc-review-menu--commit-of from))
         (to (ecc-review-menu--commit-of to)))
    (list from (and to (not (equal to from)) to))))

(defun ecc-review-menu--read-session ()
  "Ask for the session the menu is about, those of its project first."
  (let* ((state (ecc-review-menu--current-state))
         (project (and (plist-get state :directory)
                       (ecc-window-project-sessions (plist-get state :directory))))
         (sessions (append project (seq-difference (ecc-model-sessions) project)))
         (labels (mapcar (lambda (session)
                           (cons (format "%s  %s" (ecc-session-name session)
                                         (abbreviate-file-name
                                          (ecc-review-menu--project session)))
                                 session))
                         sessions)))
    (unless sessions
      (user-error "No session is running"))
    (cdr (assoc (completing-read "Review the session: "
                                 (ecc-review-menu--in-order (mapcar #'car labels))
                                 nil t nil nil
                                 (car (rassq (plist-get state :session) labels)))
                labels))))

;;;; The menu

(defun ecc-review-menu--count-string (count)
  "Return COUNT files in words: ? for a count that failed, nothing for none."
  (cond ((null count) "")
        ((stringp count) "?")
        ((zerop count) "nothing")
        ((= count 1) "1 file")
        (t (format "%d files" count))))

(defun ecc-review-menu--describe (choice)
  "Return the line of CHOICE in the menu: what it compares, and how many files.
The choice made last is marked, and carries the property
`ecc-review-menu-last' the cursor is put on."
  (let* ((state ecc-review-menu--state)
         (label (format (alist-get choice ecc-review-menu--labels)
                        (or (plist-get state :base) "…")))
         (count (if (and (eq choice 'branch) (plist-get state :root)
                         (null (plist-get state :base)))
                    "no branch to compare with"
                  (ecc-review-menu--count-string
                   (alist-get choice (plist-get state :counts)))))
         (text (string-trim-right (format "%-27s %s" label count))))
    (if (eq choice ecc-review-menu--last)
        (propertize (concat text "  " (propertize "(last)" 'face 'transient-value))
                    'ecc-review-menu-last t)
      text)))

(defun ecc-review-menu--header ()
  "Return the heading of the menu: the session it is about, and its project."
  (let ((session (plist-get ecc-review-menu--state :session))
        (directory (plist-get ecc-review-menu--state :directory)))
    (concat "Review  ·  "
            (if session
                (concat (propertize (ecc-session-name session) 'face 'transient-value)
                        " gets the comments")
              "no session yet (S to choose one)")
            (if directory
                (concat "  ·  " (abbreviate-file-name directory))
              ""))))

(defun ecc-review-menu--compare-heading ()
  "Return the heading of the choices, saying why most are off outside git."
  (if (ecc-review-menu--outside-git-p)
      "What to compare  (not a git repository: D alone)"
    "What to compare"))

(defun ecc-review-menu--say-why ()
  "Say in the echo area why a count of the menu is a question mark."
  (when-let* ((failed (seq-filter (lambda (cell) (stringp (cdr cell)))
                                  (plist-get ecc-review-menu--state :counts))))
    (message "Could not count %s"
             (mapconcat (lambda (cell)
                          (format "%s: %s" (car cell) (cdr cell)))
                        failed "; "))))

(defun ecc-review-menu--ediff-style-p ()
  "Return non-nil when a review opens in ediff unless told otherwise."
  (eq ecc-review-style 'ediff))

(transient-define-suffix ecc-review-menu-session-changes (args)
  "Review everything the session of the menu changed since it started.
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'session))
  :inapt-if #'ecc-review-menu--no-session-p
  (interactive (list (transient-args 'ecc-review-menu)))
  (ecc-review-menu-open 'session nil args))

(transient-define-suffix ecc-review-menu-uncommitted (args)
  "Review the working tree against HEAD, staged or not.
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'worktree))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive (list (transient-args 'ecc-review-menu)))
  (ecc-review-menu-open 'worktree "HEAD" args))

(transient-define-suffix ecc-review-menu-unstaged (args)
  "Review what is not staged yet: the working tree against the index.
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'unstaged))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive (list (transient-args 'ecc-review-menu)))
  (ecc-review-menu-open 'unstaged "" args))

(transient-define-suffix ecc-review-menu-staged (args)
  "Review what is staged: the index against HEAD.
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'staged))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive (list (transient-args 'ecc-review-menu)))
  (ecc-review-menu-open 'staged 'staged args))

(transient-define-suffix ecc-review-menu-branch (base other args)
  "Review the branch OTHER against BASE (`ecc-review-menu-branch-range').
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'branch))
  :inapt-if #'ecc-review-menu--no-base-p
  (interactive
   (ecc-review-menu--with-state
     (let* ((args (transient-args 'ecc-review-menu))
            (base (progn (ecc-review-menu--root) (ecc-review-menu--read-base))))
       (list base (ecc-review-menu--read-other base) args))))
  (ecc-review-menu--with-state
    (let ((range (ecc-review-menu-branch-range (ecc-review-menu--root) base other
                                               ecc-review-menu--state)))
      (ecc-review-menu-open 'branch (car range) args (cdr range)))))

(transient-define-suffix ecc-review-menu-commit (from to args)
  "Review the commit FROM, or FROM through TO (`ecc-review-menu-commit-range').
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'commit))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (ecc-review-menu--with-state
     (let ((args (transient-args 'ecc-review-menu)))
       (append (ecc-review-menu--read-commits (ecc-review-menu--root)) (list args)))))
  (ecc-review-menu--with-state
    (let ((range (ecc-review-menu-commit-range (ecc-review-menu--root) from to)))
      (ecc-review-menu-open 'commit (car range) args (cdr range)))))

(transient-define-suffix ecc-review-menu-range (range args)
  "Review the working tree against RANGE, typed as \\[universal-argument] \
\\[ecc-review-worktree] takes it.
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'range))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (ecc-review-menu--with-state
     (let ((args (transient-args 'ecc-review-menu)))
       (ecc-review-menu--root)
       (list (ecc-review-read-range) args))))
  (ecc-review-menu-open 'range range args))

(transient-define-suffix ecc-review-menu-switch-session (session)
  "Turn the menu to SESSION, chosen with completion: its project too."
  :description "review another session"
  :transient t
  (interactive (list (ecc-review-menu--read-session)))
  (ecc-review-menu-set-session session)
  (ecc-review-menu--say-why))

(transient-define-infix ecc-review-menu--in-ediff ()
  "Open this one review in ediff, leaving `ecc-review-style' as it is."
  :class 'transient-switch
  :argument "--ediff"
  :description "open in ediff"
  :if-not #'ecc-review-menu--ediff-style-p)

(transient-define-infix ecc-review-menu--in-diff ()
  "Open this one review as a diff, leaving `ecc-review-style' as it is."
  :class 'transient-switch
  :argument "--diff"
  :description "open as a diff"
  :if #'ecc-review-menu--ediff-style-p)

(defun ecc-review-menu--point-at-last ()
  "Put the cursor of the menu on the choice made last, so RET opens it again.
Done after the menu is drawn, by looking for the property
`ecc-review-menu--describe' puts on that line, rather than through the
internals of transient, which differ between the 0.4.1 of Emacs 29.1
and later ones.  Where the menu is not drawn yet -- a delay in
`transient-show-popup' -- the choice is still marked, and nothing else
happens."
  (when-let* ((buffer (get-buffer (or (bound-and-true-p transient--buffer-name)
                                      " *transient*")))
              (window (get-buffer-window buffer t))
              (position (with-current-buffer buffer
                          (text-property-any (point-min) (point-max)
                                             'ecc-review-menu-last t))))
    (with-selected-window window
      (goto-char position))))

;;;###autoload (autoload 'ecc-review-menu "ecc-review-menu" nil t)
(transient-define-prefix ecc-review-menu ()
  "Choose what to compare, and open it as a review.
The menu is about one session and its project (`ecc-review-menu--context'),
named in its heading; S turns it to another.  The counts are of the
files each review would show.  What the session
changed since it started is `ecc-review'; the rest is
`ecc-review-worktree' against the range the choice names.  -f asks for
the files to keep once the comparison is chosen, and -e opens this one
review the other way from `ecc-review-style'."
  [:description ecc-review-menu--header
   [:description ecc-review-menu--compare-heading
    ("D" ecc-review-menu-session-changes)
    ("w" ecc-review-menu-uncommitted)
    ("u" ecc-review-menu-unstaged)
    ("s" ecc-review-menu-staged)
    ("b" ecc-review-menu-branch)
    ("c" ecc-review-menu-commit)
    ("r" ecc-review-menu-range)]
   ["Options"
    ("-f" "only these files…" "--files")
    ("-e" ecc-review-menu--in-ediff)
    ("-e" ecc-review-menu--in-diff)
    ("S" ecc-review-menu-switch-session)]]
  (interactive)
  ;; The suffixes reach into the whole package, and a menu opened from a
  ;; cold Emacs has loaded this file alone (`ecc-transient--load').
  (require 'ecc)
  (add-hook 'transient-exit-hook #'ecc-review-menu--forget-state)
  (setq ecc-review-menu--state nil)
  (setq ecc-review-menu--state (ecc-review-menu--current-state))
  (transient-setup 'ecc-review-menu)
  (ecc-review-menu--point-at-last)
  (ecc-review-menu--say-why))

(provide 'ecc-review-menu)

;;; ecc-review-menu.el ends here
