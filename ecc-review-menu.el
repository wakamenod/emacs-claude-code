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
;; `ecc-review-range' with the arguments chosen, and those are the
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

(declare-function ecc-start "ecc" (&optional directory name))

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
:upstreams the upstream of each local branch that has one, and
:distances how far those are from it, filled as `b' shows them
\(`ecc-review-menu--distance'); :base the guess at the branch the current
one forked from and :fork the commit where they part; :counts an alist
of a choice to how many files it would show -- a number, nil when it is
not counted, or a string saying why it could not be.  Dropped when the
menu goes away (`ecc-review-menu--forget-state').")

(defvar ecc-review-menu--last nil
  "The choice made last in `ecc-review-menu', a symbol of its labels.")

(defvar ecc-review-menu--branch-history nil
  "Branches typed at the questions of `b'.")

(defvar ecc-review-menu--commit-history nil
  "Commits typed at the questions of `c'.")

;;;; Asking git

(defun ecc-review-menu--left-right (root left right)
  "Return (L R): the commits of ROOT only LEFT has and only RIGHT has, or nil."
  (when-let* ((counts (ecc-review--git-string root "rev-list" "--left-right" "--count"
                                              (concat left "..." right) "--")))
    (mapcar #'string-to-number (split-string counts))))

(defun ecc-review-menu--track (upstream track)
  "Return (UPSTREAM AHEAD BEHIND) from what git says of a branch, or nil.
TRACK is its %(upstream:track,nobracket): \"ahead 2, behind 4\",
\"behind 4\", empty when the two are level, \"gone\" when UPSTREAM is no
more -- BEHIND is then the symbol `gone'.  Nil without an UPSTREAM."
  (when (and upstream (not (string-empty-p upstream)))
    (let ((count (lambda (word)
                   (if (string-match (concat word " \\([0-9]+\\)") track)
                       (string-to-number (match-string 1 track))
                     0))))
      (list upstream (funcall count "ahead")
            (if (equal track "gone") 'gone (funcall count "behind"))))))

(defun ecc-review-menu--all-distances (root)
  "Return how far each local branch of ROOT is from its upstream, as an alist.
Of each branch that has one, to (UPSTREAM AHEAD BEHIND), from one call
of git: what a list of branches shows beside them
\(`ecc-review-menu--distance')."
  (pcase (ecc-review--git root "for-each-ref"
                          "--format=%(refname)%00%(upstream:short)%00%(upstream:track,nobracket)"
                          "refs/heads")
    (`(0 . ,output)
     (delq nil (mapcar (lambda (line)
                         (pcase-let ((`(,ref ,upstream ,track) (split-string line "\0")))
                           (when-let* ((gap (ecc-review-menu--track upstream (or track ""))))
                             (cons (string-remove-prefix "refs/heads/" ref) gap))))
                       (split-string output "\n" t))))))

(defun ecc-review-menu--distance-of (root branch refs)
  "Return how far BRANCH of ROOT is from its upstream, or nil.
\(UPSTREAM AHEAD BEHIND), BEHIND the symbol `gone' for an upstream
REFS no longer lists; nil for a branch with no upstream.  One call of
git, made only when it is asked for, which the guess does for the one
branch it chose (`ecc-review-menu--fresher').  A list of branches asks
for all of them at once (`ecc-review-menu--all-distances')."
  (when-let* ((upstream (alist-get branch (plist-get refs :upstreams) nil nil #'equal)))
    (if (not (member upstream (plist-get refs :branches)))
        (list upstream 0 'gone)
      (pcase (ecc-review-menu--left-right root upstream branch)
        (`(,behind ,ahead) (list upstream ahead behind))))))

(defun ecc-review-menu--refs (root)
  "Return what the branches of ROOT are, as a plist, from one call of git.
:current is the branch checked out, nil when HEAD is detached;
:upstream the branch it tracks; :origin-head the branch origin/HEAD
points at; :branches the local and then the remote branches, without
the symbolic origin/HEAD, which names one of them again; :upstreams an
alist of each local branch that has an upstream to that upstream."
  (pcase (ecc-review--git root "for-each-ref"
                          "--format=%(HEAD)%00%(refname)%00%(upstream:short)%00%(symref)"
                          "refs/heads" "refs/remotes")
    (`(0 . ,output)
     (let (current upstream origin-head locals remotes upstreams)
       (dolist (line (split-string output "\n" t))
         (pcase-let ((`(,head ,ref ,up ,symref) (split-string line "\0")))
           (cond
            ((string-prefix-p "refs/heads/" ref)
             (let ((name (substring ref (length "refs/heads/"))))
               (push name locals)
               (when (and up (not (string-empty-p up)))
                 (push (cons name up) upstreams))
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
             :branches (append (nreverse locals) (nreverse remotes))
             :upstreams (nreverse upstreams))))))

(defun ecc-review-menu-guess-base (root &optional refs)
  "Return (BASE . FORK): the branch HEAD of ROOT most likely forked from.
FORK is the commit where the two part.  REFS is what
`ecc-review-menu--refs' says of ROOT, read again when not given.

The candidates are `ecc-review-menu-base-candidates', the branch
origin/HEAD points at, and the upstream of the current branch when the
current branch is one of those -- on main, origin/main is where the
commits not pushed yet show.  Left out are the ones that do not exist,
the current branch, and any that is ahead of HEAD -- HEAD is behind it,
with nothing of its own: develop when main is checked out and develop
has gone on would compare HEAD with itself.  A candidate at HEAD itself
stays: it is the branch a new one was just cut from, and the fork is
HEAD, so `b' shows the working tree.  Of the rest, the one HEAD has the
fewest commits beyond -- the commits from where the two part to HEAD --
wins, and of a tie the one whose own tip is nearest that point.  Nil
when none is left.

A local branch that won and is behind its upstream, with nothing of
its own, gives way to the upstream: the local develop is the remote
one of some time ago, and a feature cut from the remote one since
would have the commits it has not fetched yet in its review.  A
develop four commits behind put the files of two other pull requests
into the review, 57 of them where 46 had changed (2026-10-01)."
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
          (when (and (not (and (= ours 0) (> theirs 0)))
                     (or (null best)
                         (< ours (car best))
                         (and (= ours (car best)) (< theirs (cadr best)))))
            (setq best (list ours theirs candidate))))))
    (when-let* ((base (ecc-review-menu--fresher root (nth 2 best) refs))
                (fork (ecc-review--merge-base root base "HEAD")))
      (cons base fork))))

(defun ecc-review-menu--fresher (root branch refs)
  "Return the upstream of BRANCH when BRANCH only lags behind it, else BRANCH.
ROOT is the repository and REFS what `ecc-review-menu--refs' says of it:
BRANCH is local, behind its upstream and ahead of it by nothing, and
the upstream is a branch REFS knows.  The upstream must also pass the
rule the guess holds every candidate to -- not ahead of HEAD with
nothing of HEAD's own beyond it: a feature merged into origin/develop
since is contained in it, and the review would be the working tree
alone.  Two calls of git, for the one branch.  Nil for a BRANCH that is
nil."
  (pcase (and branch (ecc-review-menu--distance-of root branch refs))
    ((and `(,upstream 0 ,behind)
          (guard (and (numberp behind) (> behind 0)))
          (guard (pcase (ecc-review-menu--left-right root upstream "HEAD")
                   (`(,theirs ,ours) (not (and (= ours 0) (> theirs 0)))))))
     upstream)
    (_ branch)))

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
The diff of FORK against the working tree, which is what the review of
`b' shows -- a file a commit changed and the working tree put back is
in neither -- and the untracked files, which STATUS, the
`ecc-review-menu--status' of ROOT, has read already."
  (pcase (ecc-review--git root "diff" "--name-only" "-z" fork "--")
    (`(0 . ,output)
     (length (delete-dups (append (split-string output "\0" t)
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
working tree\", what the review is called (`ecc-review-name-fork').
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
  (or (ecc-review--commit root revision)
      (user-error "%s is not a commit in %s" revision (abbreviate-file-name root))))

(defun ecc-review-menu-commit-range (root from &optional to)
  "Return the range `c' reviews in ROOT: the commit FROM, or FROM through TO.
TO nil, empty or the commit FROM is FROM alone, FROM^!, the change
`git show' shows.  Otherwise it is FROM^..TO, FROM included; the two
are put in order first, so that a TO older than FROM is the same span
picked the other way round.  A commit with no parent -- the first of
the repository -- is compared with the empty tree instead, which is
what a parent would have held: FROM^! there names FROM alone, and git
would compare it with the working tree.

The range names the commits by their ids, not by the names typed: HEAD
or main moves, and a review read again would show another commit under
the same comments.  The review is called by the short ids and the
subject all the same (`ecc-review-range-label'), and Claude asking for
the same commits by id opens the same review."
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
      (cond
       ((and parent (null to-id)) (concat from-id "^!"))
       (parent (format "%s^..%s" from-id to-id))
       (t (format "%s..%s"
                  (or (ecc-review--empty-tree root)
                      (user-error "Cannot name the empty tree in %s"
                                  (abbreviate-file-name root)))
                  (or to-id from-id)))))))

;;;; What the menu is about

(defun ecc-review-menu--project (session)
  "Return the project directory of SESSION."
  (file-name-as-directory (expand-file-name (ecc-window-session-project session))))

(defun ecc-review-menu--context ()
  "Return what the menu opened here is about, as (SESSION D-SESSION DIRECTORY).
DIRECTORY is the project of the current buffer and SESSION its session,
nil when it has none -- `ecc-review-context', which the git choices
follow as \\[ecc-review-range] does: they review this project, and with
no session here they offer to start one.  D-SESSION is the
session `D' reviews: SESSION, else the session used last, which is what
\\`C-c c D' reviewed before it asked what to compare."
  (let ((context (ecc-review-context)))
    (list (car context)
          (or (car context) (car (ecc-model-sessions)))
          (cdr context))))

(defun ecc-review-menu-make-state (session directory &optional d-session light)
  "Return what the menu is about for SESSION and DIRECTORY; see the state.
D-SESSION is the session of `D', SESSION by default.  LIGHT leaves the
counts out: what a choice run without the menu needs is where to
review, not how much."
  (let* ((d-session (or d-session session))
         (root (and directory (ecc-review-git-root directory)))
         (refs (and root (ecc-review-menu--refs root)))
         (guess (and root (ecc-review-menu-guess-base root refs))))
    (list :session session :d-session d-session :directory directory :root root
          :branch (plist-get refs :current) :branches (plist-get refs :branches)
          :upstreams (plist-get refs :upstreams)
          :distances (make-hash-table :test #'equal)
          :base (car guess) :fork (cdr guess)
          :counts (unless light
                    (ecc-review-menu-counts d-session root (cdr guess))))))

(defun ecc-review-menu--fresh-state (&optional light)
  "Return a state made from the current buffer, without counts when LIGHT."
  (pcase-let ((`(,session ,d-session ,directory) (ecc-review-menu--context)))
    (ecc-review-menu-make-state session directory d-session light)))

(defun ecc-review-menu--current-state ()
  "Return the state of the open menu.
With no menu open -- a choice run with \\[execute-extended-command] -- a
light one, without counts, is made from the current buffer and not
kept."
  (or ecc-review-menu--state (ecc-review-menu--fresh-state t)))

(defmacro ecc-review-menu--with-state (state &rest body)
  "Run BODY with `ecc-review-menu--state' bound to STATE.
STATE nil is the state of the open menu, or, with none open, one made
for BODY alone (`ecc-review-menu--current-state').  A choice reads its
state in its `interactive' form and hands it on as an argument, so that
run without the menu it is made once, not twice."
  (declare (indent 1) (debug t))
  `(let ((ecc-review-menu--state (or ,state (ecc-review-menu--current-state))))
     ,@body))

(defun ecc-review-menu--forget-state ()
  "Drop the state of the menu once the menu is really gone.
On `transient-exit-hook', which runs after the choice that closed the
menu has finished.  It also runs when another menu hands over to this
one -- D in `ecc-menu' -- and when this one is suspended, by \\`C-h' or
a switch of frame, to be resumed later: transient then puts it on its
stack, and resumes it without running `ecc-review-menu' again, so the
state, and the session `S' chose, are kept for it.  Without this the
state of the last menu stayed: a choice run later from elsewhere
reviewed that menu's project, and a killed session was kept alive."
  (unless (or (and (bound-and-true-p transient--prefix)
                   (eq (oref transient--prefix command) 'ecc-review-menu))
              (assq 'ecc-review-menu (bound-and-true-p transient--stack)))
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

(defun ecc-review-menu--no-session-p ()
  "Return non-nil when the menu has no session to review the changes of."
  (null (plist-get ecc-review-menu--state :d-session)))

(defun ecc-review-menu-set-session (session)
  "Turn the open menu to SESSION: its changes, its project, its comments.
A session of the same project changes the session and what it changed,
and nothing else is read again; one of another project makes the whole
menu again from that project, so that what is reviewed and where the
comments go cannot be two projects.  With no menu open there is
nothing to turn, and it says so."
  (if (not ecc-review-menu--state)
      (progn (message "No review menu is open; C-c c D opens one") nil)
    (let* ((state ecc-review-menu--state)
           (directory (ecc-review-menu--project session)))
      (setq ecc-review-menu--state
            (if (equal directory (plist-get state :directory))
                (let ((state (copy-sequence state)))
                  (plist-put
                   (plist-put (plist-put state :session session) :d-session session)
                   :counts (cons (cons 'session (ecc-review-menu--session-count session))
                                 (assq-delete-all
                                  'session (copy-alist (plist-get state :counts))))))
              (ecc-review-menu-make-state session directory)))
      session)))

;;;; Opening the review

(defun ecc-review-menu--style (args)
  "Return the `ecc-review-style' the menu ARGS ask for this one review."
  (cond ((member "--ediff" args) 'ediff)
        ((member "--diff" args) 'diff)
        (t ecc-review-style)))

(defun ecc-review-menu-open (choice range args &optional state)
  "Open the review CHOICE stands for, against RANGE, with the menu's ARGS.
CHOICE `session' is `ecc-review' of the session of `D'; anything else
is `ecc-review-range' of the menu's project against RANGE, the
comments going to its session, or to one offered to start there when
it has none.  --files among ARGS asks for the files of
that review to keep, and --ediff or --diff is the `ecc-review-style' of
this review alone.  STATE is the menu's (`ecc-review-menu--with-state').
CHOICE is remembered."
  (ecc-review-menu--with-state state
    (let* ((state ecc-review-menu--state)
           (directory (plist-get state :directory))
           (files (member "--files" args))
           (ecc-review-style (ecc-review-menu--style args)))
      (setq ecc-review-menu--last choice)
      (if (eq choice 'session)
          (let ((session (or (plist-get state :d-session)
                             (user-error "No session has changes to review"))))
            (ecc-review session (and files (ecc-review-read-paths session))))
        (let ((session (or (plist-get state :session)
                           (ecc-review-range-session directory))))
          (ecc-review-range session range directory
                               (and files (ecc-review-range-read-paths
                                           directory range))))))))

;;;; Asking

(defun ecc-review-menu--in-order (candidates &optional annotate)
  "Return a completion table of CANDIDATES that keeps their order.
ANNOTATE, a function of a candidate, says what is shown beside it."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity)
                   ,@(and annotate `((annotation-function . ,annotate))))
      (complete-with-action action candidates string predicate))))

(defun ecc-review-menu--distance-string (gap)
  "Return GAP, an `ecc-review-menu--distance-of', as shown beside a branch.
\"  (4 behind origin/develop)\", \"  (2 ahead of origin/develop)\" or
both; nothing for a branch level with its upstream or with none."
  (pcase gap
    (`(,upstream ,_ gone) (format "  (%s is gone)" upstream))
    (`(,_ 0 0) nil)
    (`(,upstream 0 ,behind) (format "  (%d behind %s)" behind upstream))
    (`(,upstream ,ahead 0) (format "  (%d ahead of %s)" ahead upstream))
    (`(,upstream ,ahead ,behind) (format "  (%d ahead, %d behind %s)" ahead behind upstream))))

(defun ecc-review-menu--distance (branch)
  "Return how far BRANCH is from its upstream, as shown beside it, or nil.
The first time a list asks, every local branch is read by one call of
git (`ecc-review-menu--all-distances') and kept in the menu's state, so
that opening the menu asks nothing of the kind and a list of eighty
branches is not eighty processes."
  (let* ((state ecc-review-menu--state)
         (distances (plist-get state :distances)))
    (when (assoc branch (plist-get state :upstreams))
      (ecc-review-menu--distance-string
       (if (not distances)
           (ecc-review-menu--distance-of (plist-get state :root) branch state)
         (unless (gethash :read distances)
           (pcase-dolist (`(,name . ,gap) (ecc-review-menu--all-distances
                                           (plist-get state :root)))
             (puthash name gap distances))
           (puthash :read t distances))
         (gethash branch distances))))))

(defun ecc-review-menu--branches ()
  "Return the branches of the menu as a completion table, with their distances."
  (ecc-review-menu--in-order (plist-get ecc-review-menu--state :branches)
                             #'ecc-review-menu--distance))

(defun ecc-review-menu--read-base ()
  "Ask for the base of the comparison, the before side, the guessed one by default."
  (let ((guess (plist-get ecc-review-menu--state :base)))
    (completing-read (format-prompt "Base, the before side" guess)
                     (ecc-review-menu--branches)
                     nil nil nil 'ecc-review-menu--branch-history guess)))

(defun ecc-review-menu--read-other (_base)
  "Ask for the after side, compared with the base: the current branch by default."
  (let ((current (or (plist-get ecc-review-menu--state :branch) "HEAD")))
    (completing-read (format "Changes on, the after side (default %s with its working tree): "
                             current)
                     (ecc-review-menu--branches)
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

(defvar ecc-review-menu-new-session-label "+ new session"
  "The choice of `S' in `ecc-review-menu' that starts a session in its project.")

(defun ecc-review-menu--read-session ()
  "Ask for the session the menu is about, those of its project first.
Return the session, or `new' for a new one in the project of the menu
\(`ecc-review-menu-new-session-label', offered first when the menu has a
project)."
  (let* ((state (ecc-review-menu--current-state))
         (directory (plist-get state :directory))
         (project (and directory (ecc-window-project-sessions directory)))
         (sessions (append project (seq-difference (ecc-model-sessions) project)))
         (labels (append
                  (and directory (list (cons ecc-review-menu-new-session-label 'new)))
                  (mapcar (lambda (session)
                            (cons (format "%s  %s" (ecc-session-name session)
                                          (abbreviate-file-name
                                           (ecc-review-menu--project session)))
                                  session))
                          sessions))))
    (unless labels
      (user-error "No session is running"))
    (cdr (assoc (completing-read "Review the session: "
                                 (ecc-review-menu--in-order (mapcar #'car labels))
                                 nil t nil nil
                                 (car (rassq (plist-get state :session) labels)))
                labels))))

(defun ecc-review-menu--back-to-tab (index name)
  "Select again the tab that was the INDEXth, 0 counting, and was called NAME.
`ecc-start' may have made tabs on either side of it -- a worktree's
Space brings its repository's -- so the tab now at INDEX is taken when
it has that name, else the first tab of that name, else the one at
INDEX.  Nothing is selected when that tab is the current one."
  (let* ((tabs (funcall tab-bar-tabs-function))
         (target (cond ((equal (alist-get 'name (nth index tabs)) name) index)
                       ((seq-position tabs name
                                      (lambda (tab name) (equal (alist-get 'name tab) name))))
                       (t (min index (1- (length tabs)))))))
    (unless (= target (tab-bar--current-tab-index))
      (tab-bar-select-tab (1+ target)))))

(defun ecc-review-menu--start-session ()
  "Start a session in the project of the menu and return it.
With `ecc-start', as \\[ecc-start] would, asking for a name when the
project has a session already.  The session is shown where a new one
is, and the user stays where the menu was opened: in its tab, with its
window selected, the menu open over it.  With `ecc-use-spaces' the
session may have gone to a Space of its own, in a tab `ecc-start'
switched to; that is switched back from, by the index and the name the
menu's tab had (`ecc-review-menu--back-to-tab'), and so it is when
`ecc-start' fails part of the way."
  (let ((directory (or (plist-get (ecc-review-menu--current-state) :directory)
                       (user-error "The menu is about no project")))
        (window (selected-window))
        (index (tab-bar--current-tab-index))
        (name (alist-get 'name (tab-bar--current-tab))))
    (unwind-protect
        (ecc-start directory (ecc-window-read-session-name directory))
      (ecc-review-menu--back-to-tab index name)
      (when (window-live-p window)
        (select-window window)))))

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
         (count (ecc-review-menu--count-string
                 (alist-get choice (plist-get state :counts))))
         (text (string-trim-right (format "%-27s %s" label count))))
    (if (eq choice ecc-review-menu--last)
        (propertize (concat text "  " (propertize "(last)" 'face 'transient-value))
                    'ecc-review-menu-last t)
      text)))

(defun ecc-review-menu--header ()
  "Return the heading of the menu: the sessions it is about, and its project.
When the project has no session, `D' and the rest are about different
ones, and the heading says which is which."
  (let* ((state ecc-review-menu--state)
         (session (plist-get state :session))
         (d-session (plist-get state :d-session))
         (directory (plist-get state :directory))
         (name (lambda (session)
                 (propertize (ecc-session-name session) 'face 'transient-value))))
    (concat "Review  ·  "
            (cond
             (session (concat (funcall name session) " gets the comments"))
             (d-session (concat "D reviews " (funcall name d-session)
                                ", the session used last; the rest offer to start one here"))
             (t "no session yet (S to choose one)"))
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

(transient-define-suffix ecc-review-menu-session-changes (args &optional state)
  "Review everything the session of the menu changed since it started.
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'session))
  :inapt-if #'ecc-review-menu--no-session-p
  (interactive (list (transient-args 'ecc-review-menu) ecc-review-menu--state))
  (ecc-review-menu-open 'session nil args state))

(transient-define-suffix ecc-review-menu-uncommitted (args &optional state)
  "Review the working tree against HEAD, staged or not.
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'worktree))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive (list (transient-args 'ecc-review-menu) ecc-review-menu--state))
  (ecc-review-menu-open 'worktree "HEAD" args state))

(transient-define-suffix ecc-review-menu-unstaged (args &optional state)
  "Review what is not staged yet: the working tree against the index.
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'unstaged))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive (list (transient-args 'ecc-review-menu) ecc-review-menu--state))
  (ecc-review-menu-open 'unstaged "" args state))

(transient-define-suffix ecc-review-menu-staged (args &optional state)
  "Review what is staged: the index against HEAD.
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'staged))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive (list (transient-args 'ecc-review-menu) ecc-review-menu--state))
  (ecc-review-menu-open 'staged 'staged args state))

(transient-define-suffix ecc-review-menu-branch (base other args &optional state)
  "Review the branch OTHER against BASE (`ecc-review-menu-branch-range').
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'branch))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (ecc-review-menu--with-state nil
     (let* ((args (transient-args 'ecc-review-menu))
            (base (progn (ecc-review-menu--root) (ecc-review-menu--read-base))))
       (list base (ecc-review-menu--read-other base) args ecc-review-menu--state))))
  (ecc-review-menu--with-state state
    (let* ((root (ecc-review-menu--root))
           (range (ecc-review-menu-branch-range root base other ecc-review-menu--state)))
      (when (cdr range)
        (ecc-review-name-fork root (car range) (cdr range)))
      (ecc-review-menu-open 'branch (car range) args ecc-review-menu--state))))

(transient-define-suffix ecc-review-menu-commit (from to args &optional state)
  "Review the commit FROM, or FROM through TO (`ecc-review-menu-commit-range').
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'commit))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (ecc-review-menu--with-state nil
     (let ((args (transient-args 'ecc-review-menu)))
       (append (ecc-review-menu--read-commits (ecc-review-menu--root))
               (list args ecc-review-menu--state)))))
  (ecc-review-menu--with-state state
    (ecc-review-menu-open 'commit (ecc-review-menu-commit-range (ecc-review-menu--root) from to)
                          args ecc-review-menu--state)))

(transient-define-suffix ecc-review-menu-range (range args &optional state)
  "Review the project against RANGE, typed as \\[universal-argument] \
\\[ecc-review-range] takes it.
ARGS are the arguments of the menu, and STATE its state
\(`ecc-review-menu--with-state')."
  :description (lambda () (ecc-review-menu--describe 'range))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (ecc-review-menu--with-state nil
     (let ((args (transient-args 'ecc-review-menu)))
       (ecc-review-menu--root)
       (list (ecc-review-read-range) args ecc-review-menu--state))))
  (ecc-review-menu-open 'range range args state))

(transient-define-suffix ecc-review-menu-switch-session (session)
  "Turn the menu to SESSION, chosen with completion: its project too.
SESSION `new' starts one in the project of the menu first
\(`ecc-review-menu--start-session'), and the comments go to it."
  :description "review another session"
  :transient t
  (interactive (list (ecc-review-menu--read-session)))
  (ecc-review-menu-set-session (if (eq session 'new)
                                   (ecc-review-menu--start-session)
                                 session))
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
`ecc-review-range' against the range the choice names.  -f asks for
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
  (setq ecc-review-menu--state (ecc-review-menu--fresh-state))
  (transient-setup 'ecc-review-menu)
  (ecc-review-menu--point-at-last)
  (ecc-review-menu--say-why))

(provide 'ecc-review-menu)

;;; ecc-review-menu.el ends here
