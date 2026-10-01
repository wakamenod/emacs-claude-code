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
;; hand -- says how many files each would show, and names the session
;; the comments go to.  What it opens is `ecc-review' or
;; `ecc-review-worktree' with the arguments chosen, and those are the
;; arguments `review_open' takes, so a review Claude is asked for in the
;; same words is the same review (`ecc-review-agent-open-description').
;;
;; Only what the transient bundled with Emacs 29.1 (0.4.1) has is used.
;; What the open menu is about lives in a variable of this file rather
;; than in the scope of the prefix, whose accessors are not the same in
;; 0.4.1 and in the transient of later Emacsen.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-window)
(require 'ecc-review)

(defvar ecc-review-menu-count-session-changes t
  "Non-nil makes the menu count the files changed since the session started.
That count takes a snapshot of the working tree, the one thing in the
menu that reads every file: 35 ms on a repository of 300 files and 70
ms on one of 20000, where each of the other counts, which only ask git,
takes 10 to 25 ms (measured 2026-10-01).  Set it to nil where that is
too slow to open a menu on; the item stays, without its number.")

(defvar ecc-review-menu-base-candidates '("develop" "main" "master")
  "The branches `b' in `ecc-review-menu' guesses the current one forked from.
The branch origin/HEAD points at is tried too.  Of those that exist,
the one HEAD has the fewest commits beyond is the guess.")

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
  "What the open `ecc-review-menu' is about, as a plist.
:session is where the comments go, nil when there is no session yet;
:directory is the project reviewed; :root its git root, nil outside
git; :base the guess at the branch the current one forked from; and
:counts an alist of a choice to how many files it would show.")

(defvar ecc-review-menu--last nil
  "The choice made last in `ecc-review-menu', a symbol of its labels.")

(defvar ecc-review-menu--branch-history nil
  "Branches typed at the questions of `b'.")

(defvar ecc-review-menu--commit-history nil
  "Commits typed at the questions of `c'.")

;;;; Asking git

(defun ecc-review-menu--git-string (root &rest args)
  "Return what git ARGS in ROOT print, trimmed; nil on failure or nothing."
  (pcase (apply #'ecc-review--git root args)
    (`(0 . ,output)
     (let ((text (string-trim output)))
       (and (not (string-empty-p text)) text)))))

(defun ecc-review-menu--shortstat-files (output)
  "Return how many files the `git diff --shortstat' OUTPUT counts."
  (if (string-match "\\([0-9]+\\) files? changed" output)
      (string-to-number (match-string 1 output))
    0))

(defun ecc-review-menu--count (root range &optional untracked)
  "Return how many files the diff of ROOT against RANGE shows, or nil.
RANGE is what `ecc-review-worktree' takes.  UNTRACKED, the number of
files git does not track, is added: the caller knows whether RANGE
reads the working tree, and asking git again for every count would
cost a call each."
  (pcase (apply #'ecc-review--git root
                (append '("diff" "--shortstat")
                        (ecc-review--range-arguments
                         (ecc-review--effective-range root range))
                        '("--")))
    (`(0 . ,output)
     (+ (ecc-review-menu--shortstat-files output) (or untracked 0)))))

(defun ecc-review-menu--current-branch (root)
  "Return the branch checked out in ROOT, or nil when HEAD is detached."
  (ecc-review-menu--git-string root "symbolic-ref" "--quiet" "--short" "HEAD"))

(defun ecc-review-menu--branches (root)
  "Return the local and then the remote branches of ROOT.
The symbolic origin/HEAD is left out: it is another name of a branch
that is in the list already."
  (pcase (ecc-review--git root "for-each-ref" "--format=%(refname)"
                          "refs/heads" "refs/remotes")
    (`(0 . ,output)
     (delq nil (mapcar (lambda (ref)
                         (cond ((string-suffix-p "/HEAD" ref) nil)
                               ((string-prefix-p "refs/heads/" ref)
                                (substring ref (length "refs/heads/")))
                               ((string-prefix-p "refs/remotes/" ref)
                                (substring ref (length "refs/remotes/")))))
                       (split-string output "\n" t))))))

(defun ecc-review-menu-guess-base (root)
  "Return the branch the current branch of ROOT most likely forked from.
The candidates are `ecc-review-menu-base-candidates' and the branch
origin/HEAD points at, less the current branch.  Of those that exist,
the one HEAD has the fewest commits beyond -- the commits from where
the two part to HEAD -- wins, the earlier of a tie.  Nil when none
exists."
  (let* ((current (ecc-review-menu--current-branch root))
         (remote (ecc-review-menu--git-string root "symbolic-ref" "--quiet"
                                              "--short" "refs/remotes/origin/HEAD"))
         (candidates (remove current (delete-dups
                                      (append ecc-review-menu-base-candidates
                                              (and remote (list remote))))))
         (best nil)
         (fewest nil))
    (dolist (candidate candidates)
      ;; One call both checks that the branch exists and measures it.
      (when-let* ((count (ecc-review-menu--git-string
                          root "rev-list" "--count" "HEAD" (concat "^" candidate) "--")))
        (let ((count (string-to-number count)))
          (when (or (null fewest) (< count fewest))
            (setq best candidate fewest count)))))
    best))

(defun ecc-review-menu--merge-base (root base)
  "Return the short id of the commit where HEAD of ROOT parted from BASE."
  (when-let* ((commit (ecc-review-menu--git-string root "merge-base" base "HEAD")))
    (or (ecc-review-menu--git-string root "rev-parse" "--short" commit) commit)))

;;;; What a choice compares

(defun ecc-review-menu--worktree-side-p (root other)
  "Return non-nil when OTHER means the current branch of ROOT as it stands.
Nil, the empty string, HEAD and the name of the current branch do."
  (or (null other)
      (member other (list "" "HEAD"))
      (equal other (ecc-review-menu--current-branch root))))

(defun ecc-review-menu-branch-range (root base &optional other)
  "Return the range `b' reviews in ROOT: the branch OTHER against BASE.
OTHER nil, empty, HEAD or the current branch is the current branch
with its working tree.  The range is then the commit where it parted
from BASE alone, which `git diff' compares with the working tree, so
what is not committed yet and the files git does not track are in the
review as well (`ecc-review--range-includes-worktree-p').  Any other
branch is BASE...OTHER, what a pull request of OTHER into BASE shows.
A name starting with - is refused, as a range is."
  (when (or (null base) (string-empty-p (string-trim base)))
    (user-error "Name the branch to compare with"))
  (let ((base (ecc-review-parse-range base))
        (other (and other (ecc-review-parse-range other))))
    (if (ecc-review-menu--worktree-side-p root other)
        (or (ecc-review-menu--merge-base root base)
            (user-error "%s and HEAD have no commit in common in %s"
                        base (abbreviate-file-name root)))
      (format "%s...%s" base other))))

(defun ecc-review-menu--commit-id (root revision)
  "Return the commit REVISION names in ROOT, or signal that it names none."
  (or (ecc-review-menu--git-string root "rev-parse" "--verify" "--quiet"
                                   (concat (ecc-review-parse-range revision)
                                           "^{commit}"))
      (user-error "%s is not a commit in %s" revision (abbreviate-file-name root))))

(defun ecc-review-menu-commit-range (root from &optional to)
  "Return the range `c' reviews in ROOT: the commit FROM, or FROM through TO.
TO nil, empty or the commit FROM is FROM alone, FROM^! -- what Hunk
calls `hunk show'.  Otherwise it is FROM^..TO, FROM included; the two
are put in order first, so that a TO older than FROM is the same span
picked the other way round.  A commit with no parent -- the first of
the repository -- is compared with the empty tree instead, which is
what a parent would have held: FROM^! there names FROM alone, and git
would compare it with the working tree."
  (let* ((from-id (ecc-review-menu--commit-id root from))
         (to (and to (not (string-empty-p (string-trim to))) (string-trim to)))
         (to-id (and to (ecc-review-menu--commit-id root to))))
    (when (equal to-id from-id)
      (setq to nil))
    ;; TO older than FROM: swap them.
    (when (and to (eq 0 (car (ecc-review--git root "merge-base" "--is-ancestor"
                                               to-id from-id))))
      (cl-rotatef from to)
      (cl-rotatef from-id to-id))
    (let ((parent (ecc-review-menu--git-string root "rev-parse" "--verify"
                                               "--quiet" (concat from-id "^"))))
      (cond
       ((and parent (null to)) (concat from "^!"))
       (parent (format "%s^..%s" from to))
       (t (format "%s..%s"
                  (or (ecc-review--empty-tree root)
                      (user-error "Cannot name the empty tree in %s"
                                  (abbreviate-file-name root)))
                  (or to from)))))))

;;;; What the menu is about

(defun ecc-review-menu--context ()
  "Return (SESSION . DIRECTORY): where the comments go, and what is reviewed.
The rule of `ecc-review-worktree--read-arguments': the session of the
current buffer and its project, else the project of the buffer being
worked in and its session.  No session is started here; a review that
needs one offers to start it when it is chosen."
  (let* ((buffer-session (ecc-window-buffer-session))
         (directory (if buffer-session
                        (ecc-window-session-project buffer-session)
                      (ecc-window-context-project-root))))
    (cons (or buffer-session (car (ecc-window-project-sessions directory)))
          (and directory (file-name-as-directory (expand-file-name directory))))))

(defun ecc-review-menu--session-count (session)
  "Return how many files SESSION changed since it started, or nil.
Nil without a session, or with `ecc-review-menu-count-session-changes'
off."
  (when (and session ecc-review-menu-count-session-changes)
    (if (ecc-review-git-root (or (ecc-session-project-root session) default-directory))
        (length (ecc-review-changed-paths session))
      (length (ecc-review-files session)))))

(defun ecc-review-menu-counts (session root base)
  "Return an alist of each choice of the menu to how many files it shows.
SESSION is the session of `D'; ROOT the repository, nil outside git;
and BASE the branch of `b'.  A choice that cannot be counted -- a
commit or a range not chosen yet -- is missing, and one that failed is
nil."
  (let ((untracked (and root (length (ecc-review--untracked-paths root)))))
    `((session . ,(ecc-review-menu--session-count session))
      ,@(when root
          `((worktree . ,(ecc-review-menu--count root "HEAD" untracked))
            (unstaged . ,(ecc-review-menu--count root "" untracked))
            (staged . ,(ecc-review-menu--count root 'staged))
            (branch . ,(when-let* ((fork (and base (ecc-review-menu--merge-base
                                                     root base))))
                         (ecc-review-menu--count root fork untracked))))))))

(defun ecc-review-menu-make-state (session directory)
  "Return what the menu is about for SESSION and DIRECTORY; see the state."
  (let* ((root (and directory (ecc-review-git-root directory)))
         (base (and root (ecc-review-menu-guess-base root))))
    (list :session session :directory directory :root root :base base
          :counts (ecc-review-menu-counts session root base))))

(defun ecc-review-menu--current-state ()
  "Return the state of the menu, made from the current buffer if there is none."
  (or ecc-review-menu--state
      (let ((context (ecc-review-menu--context)))
        (setq ecc-review-menu--state
              (ecc-review-menu-make-state (car context) (cdr context))))))

(defun ecc-review-menu--root ()
  "Return the repository the menu reviews, or signal that it is not in one."
  (or (plist-get (ecc-review-menu--current-state) :root)
      (user-error "%s is not in a git repository"
                  (abbreviate-file-name
                   (or (plist-get (ecc-review-menu--current-state) :directory)
                       default-directory)))))

(defun ecc-review-menu--outside-git-p ()
  "Return non-nil when the menu has no repository to compare in."
  (null (plist-get ecc-review-menu--state :root)))

(defun ecc-review-menu--no-session-p ()
  "Return non-nil when the menu has no session to review the changes of."
  (null (plist-get ecc-review-menu--state :session)))

(defun ecc-review-menu-set-session (session)
  "Send the comments of the review the menu opens to SESSION.
What SESSION changed is counted again, since `D' is its changes."
  (let ((state (ecc-review-menu--current-state)))
    (setq ecc-review-menu--state
          (plist-put (plist-put state :session session)
                     :counts (cons (cons 'session (ecc-review-menu--session-count session))
                                   (assq-delete-all 'session
                                                    (copy-alist (plist-get state :counts))))))
    session))

;;;; Opening the review

(defun ecc-review-menu--style (args)
  "Return the `ecc-review-style' the menu ARGS ask for this one review."
  (cond ((member "--ediff" args) 'ediff)
        ((member "--diff" args) 'diff)
        (t ecc-review-style)))

(defun ecc-review-menu-open (choice range args)
  "Open the review CHOICE stands for, against RANGE, with the menu's ARGS.
CHOICE `session' is `ecc-review' of the session of the menu; anything
else is `ecc-review-worktree' of its directory against RANGE, the
comments going to that session, or to one of the directory that is
offered to start when there is none.  --files among ARGS asks for the
files of that review to keep, and --ediff or --diff is the
`ecc-review-style' of this review alone.  CHOICE is remembered."
  (let* ((state (ecc-review-menu--current-state))
         (session (plist-get state :session))
         (directory (plist-get state :directory))
         (files (member "--files" args))
         (ecc-review-style (ecc-review-menu--style args)))
    (setq ecc-review-menu--last choice)
    (if (eq choice 'session)
        (let ((session (or session (user-error "No session has changes to review"))))
          (ecc-review session (and files (ecc-review-read-paths session))))
      (let ((session (or session (ecc-review-worktree-session directory))))
        (ecc-review-worktree session range directory
                             (and files (ecc-review-worktree-read-paths
                                         directory range)))))))

;;;; Asking

(defun ecc-review-menu--in-order (candidates)
  "Return a completion table of CANDIDATES that keeps their order."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun ecc-review-menu--read-base (root)
  "Ask for the branch of ROOT to compare with, the guessed one by default."
  (let ((guess (plist-get (ecc-review-menu--current-state) :base)))
    (completing-read (format-prompt "Compare with the branch" guess)
                     (ecc-review-menu--in-order (ecc-review-menu--branches root))
                     nil nil nil 'ecc-review-menu--branch-history guess)))

(defun ecc-review-menu--read-other (root base)
  "Ask what to compare with BASE in ROOT: the current branch by default."
  (let ((current (or (ecc-review-menu--current-branch root) "HEAD")))
    (completing-read (format "Compare %s with (default %s with its working tree): "
                             base current)
                     (ecc-review-menu--in-order (ecc-review-menu--branches root))
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
  "Ask for the session the comments go to, those of the project first."
  (let* ((state (ecc-review-menu--current-state))
         (project (and (plist-get state :directory)
                       (ecc-window-project-sessions (plist-get state :directory))))
         (sessions (append project (seq-difference (ecc-model-sessions) project)))
         (labels (mapcar (lambda (session)
                           (cons (format "%s  %s" (ecc-session-name session)
                                         (abbreviate-file-name
                                          (or (ecc-session-project-root session) "")))
                                 session))
                         sessions)))
    (unless sessions
      (user-error "No session is running"))
    (cdr (assoc (completing-read "Comments go to: "
                                 (ecc-review-menu--in-order (mapcar #'car labels))
                                 nil t nil nil
                                 (car (rassq (plist-get state :session) labels)))
                labels))))

;;;; The menu

(defun ecc-review-menu--count-string (count)
  "Return COUNT files in words, or the empty string when it is unknown."
  (cond ((null count) "")
        ((zerop count) "nothing")
        ((= count 1) "1 file")
        (t (format "%d files" count))))

(defun ecc-review-menu--describe (choice)
  "Return the line of CHOICE in the menu: what it compares, and how many files.
The choice made last is marked, and carries the property
`ecc-review-menu-last' the cursor is put on."
  (let* ((state ecc-review-menu--state)
         (label (format (alist-get choice ecc-review-menu--labels)
                        (or (plist-get state :base) "another")))
         (text (string-trim-right
                (format "%-27s %s" label (ecc-review-menu--count-string
                                          (alist-get choice (plist-get state :counts)))))))
    (if (eq choice ecc-review-menu--last)
        (propertize (concat text "  " (propertize "(last)" 'face 'transient-value))
                    'ecc-review-menu-last t)
      text)))

(defun ecc-review-menu--header ()
  "Return the heading of the menu: the session the comments go to."
  (let ((session (plist-get ecc-review-menu--state :session)))
    (concat "Review  ·  comments go to: "
            (if session
                (propertize (ecc-session-name session) 'face 'transient-value)
              "no session yet (S to choose one)"))))

(defun ecc-review-menu--compare-heading ()
  "Return the heading of the choices, saying why most are off outside git."
  (if (ecc-review-menu--outside-git-p)
      "What to compare  (not a git repository: D alone)"
    "What to compare"))

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
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (let* ((args (transient-args 'ecc-review-menu))
          (root (ecc-review-menu--root))
          (base (ecc-review-menu--read-base root)))
     (list base (ecc-review-menu--read-other root base) args)))
  (ecc-review-menu-open 'branch
                        (ecc-review-menu-branch-range (ecc-review-menu--root) base other)
                        args))

(transient-define-suffix ecc-review-menu-commit (from to args)
  "Review the commit FROM, or FROM through TO (`ecc-review-menu-commit-range').
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'commit))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (let ((args (transient-args 'ecc-review-menu)))
     (append (ecc-review-menu--read-commits (ecc-review-menu--root)) (list args))))
  (ecc-review-menu-open 'commit
                        (ecc-review-menu-commit-range (ecc-review-menu--root) from to)
                        args))

(transient-define-suffix ecc-review-menu-range (range args)
  "Review the working tree against RANGE, typed as \\[universal-argument] \
\\[ecc-review-worktree] takes it.
ARGS are the arguments of the menu."
  :description (lambda () (ecc-review-menu--describe 'range))
  :inapt-if #'ecc-review-menu--outside-git-p
  (interactive
   (let ((args (transient-args 'ecc-review-menu)))
     (ecc-review-menu--root)
     (list (ecc-review-read-range) args)))
  (ecc-review-menu-open 'range range args))

(transient-define-suffix ecc-review-menu-switch-session (session)
  "Send the comments of the review to SESSION, chosen with completion."
  :description "send the comments elsewhere"
  :transient t
  (interactive (list (ecc-review-menu--read-session)))
  (ecc-review-menu-set-session session))

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
The counts are of the files each review would show.  What the session
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
  (let ((context (ecc-review-menu--context)))
    (setq ecc-review-menu--state
          (ecc-review-menu-make-state (car context) (cdr context))))
  (transient-setup 'ecc-review-menu)
  (ecc-review-menu--point-at-last))

(provide 'ecc-review-menu)

;;; ecc-review-menu.el ends here
