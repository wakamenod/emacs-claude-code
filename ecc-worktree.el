;;; ecc-worktree.el --- git worktrees a session can live in  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; What git says about the worktrees of a repository, and the commands
;; that start a session in one.
;;
;; A worktree is a second checkout of the same repository on a branch of
;; its own.  It is the way to let two sessions work on one project
;; without either of them seeing the other's edits, and it is what
;; `CLAUDE.md' asks of the sessions that work on this package.
;;
;; Nothing here draws anything.  The reason the reading side exists at
;; all is that the sidebar asks, of every project it lists, whether it is
;; a linked worktree and of what -- `ecc-worktree-main' is what puts a
;; worktree under its parent -- and it asks on every redraw, so the
;; answers are kept for a few seconds rather than worked out again.
;;
;; The branch is never deleted with the checkout on its own.  Removing a
;; worktree is undoing a checkout, and the work is on the branch -- so
;; the branch is offered, as a question of its own, to whoever has just
;; undone the checkout it was in.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecc-core)
(require 'ecc-window)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-proc-send-prompt "ecc-proc" (session text))
(declare-function ecc-mcp-define-tool "ecc-mcp" (&rest arguments))
(declare-function ecc-mcp-session "ecc-mcp" ())

(defcustom ecc-worktree-directory ".claude/worktrees"
  "Where `ecc-worktree-create' puts a checkout.
A relative name is taken from the main worktree of the repository, so
the default puts a worktree of a branch at
\".claude/worktrees/<slug>\" inside the repository itself -- which is
where Claude Code's own worktrees go, verified with `git worktree list'
on this repository (2026-09-14).

An absolute name is a directory for every repository to share, and a
checkout lands at \"<directory>/<repository>/<slug>\", the repository
being the directory name of its main worktree.  \"~\" is expanded.

This is a setting rather than a variable because where a checkout may
be put is a difference between machines: a repository inside a synced
folder, or a home directory on a small disk, wants them somewhere
else."
  :type 'directory
  :group 'ecc)

(defvar ecc-worktree-git-executable "git"
  "Name of, or path to, the git executable.
Separate from `ecc-review-git-executable' on purpose: this file is
below `ecc-review' and must not pull the review in to ask git a
question.")

;;;; What git says

(cl-defstruct ecc-worktree-entry
  path        ; the checkout, as `file-name-as-directory'
  branch      ; the branch it is on, without refs/heads/, or nil
  main-p      ; non-nil for the main worktree, which git lists first
  detached-p  ; non-nil when HEAD is not on a branch
  prunable-p) ; git's reason when the checkout is gone, else nil

(defun ecc-worktree--git (directory &rest args)
  "Run git with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT).
Returns nil when git cannot be run at all.  What git writes to stderr
is in OUTPUT with the rest: the whole point of asking git to create or
remove a worktree is that its refusal can be shown to the user, and it
refuses on stderr."
  (when (and (executable-find ecc-worktree-git-executable)
             (file-directory-p directory))
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory)))
        (condition-case err
            (cons (apply #'call-process ecc-worktree-git-executable nil
                         (list t t) nil args)
                  (buffer-string))
          (file-error
           (ecc-log "worktree" "git failed: %s" (error-message-string err))
           nil))))))

(defun ecc-worktree--output (directory &rest args)
  "Return the trimmed output of a successful git with ARGS in DIRECTORY.
Nil when git failed or could not be run.  An empty string is a fair
answer -- `git branch --list' says that way that the branch does not
exist -- so a caller that cares tells it from nil."
  (pcase (apply #'ecc-worktree--git directory args)
    (`(0 . ,output) (string-trim output))))

(defun ecc-worktree--short-branch (ref)
  "Return REF without the refs/heads/ in front of it."
  (if (string-prefix-p "refs/heads/" ref)
      (substring ref (length "refs/heads/"))
    ref))

(defun ecc-worktree-parse (string)
  "Return the worktrees of a `git worktree list --porcelain' STRING.
A list of `ecc-worktree-entry', the main worktree first, which is the
order git prints them in.  A record is a `worktree PATH' line followed
by the attributes of that worktree -- `HEAD', `branch', `detached',
`bare', `locked' and `prunable' -- and a blank line ends it.  An
attribute this package has no use for is skipped rather than refused:
git adds them (`locked' carries a reason here, put there by Claude
Code's own worktree, 2026-09-14)."
  (let ((entries nil)
        (current nil))
    (dolist (line (split-string (or string "") "\n"))
      (cond
       ((string-prefix-p "worktree " line)
        (setq current (make-ecc-worktree-entry
                       :path (file-name-as-directory
                              (substring line (length "worktree ")))
                       :main-p (null entries)))
        (push current entries))
       ((null current) nil)
       ((string-prefix-p "branch " line)
        (setf (ecc-worktree-entry-branch current)
              (ecc-worktree--short-branch (substring line (length "branch ")))))
       ((equal line "detached")
        (setf (ecc-worktree-entry-detached-p current) t))
       ((string-prefix-p "prunable" line)
        (setf (ecc-worktree-entry-prunable-p current)
              (or (string-trim (substring line (length "prunable"))) t)))))
    (nreverse entries)))

;;;; Keeping the answers

;; The sidebar asks `ecc-worktree-main' and `ecc-worktree-branch' of
;; every project it draws, on every redraw, and each of those is a git
;; process.  The answers are kept the way `ecc-window--project-root-cache'
;; keeps a project root, with a clock on top: a branch does change under
;; Emacs, unlike a project root, so the cache is thrown away by the
;; commands here and goes stale on its own besides.  A test binds a
;; fresh hash.

(defvar ecc-worktree--cache (make-hash-table :test #'equal)
  "Hash of a question about a directory to the answer git gave.")

(defvar ecc-worktree--cache-ttl 10
  "How many seconds an answer from git is reused for.
Long enough that a redraw costs no process, short enough that a branch
switched in a terminal shows up without anybody asking for it.")

(defun ecc-worktree-forget ()
  "Forget what git has said about the worktrees.
The next question asks git again.  Called by the commands here, and by
whatever offers the user a way to refresh."
  (clrhash ecc-worktree--cache))

(defun ecc-worktree--memo (key thunk)
  "Return the value of THUNK for KEY, asking it at most every few seconds."
  (let ((hit (gethash key ecc-worktree--cache))
        (now (float-time)))
    (if (and hit (< (- now (car hit)) ecc-worktree--cache-ttl))
        (cdr hit)
      (cdr (puthash key (cons now (funcall thunk)) ecc-worktree--cache)))))

(defun ecc-worktree--key (directory)
  "Return the cache key DIRECTORY is asked under."
  (file-name-as-directory (expand-file-name (or directory default-directory))))

(defun ecc-worktree-list (root)
  "Return the worktrees of the repository holding ROOT, main first.
Nil when ROOT is not in a git repository, or git is not installed."
  (let ((root (ecc-worktree--key root)))
    (ecc-worktree--memo
     (cons 'list root)
     (lambda ()
       (when-let* ((output (ecc-worktree--output
                            root "worktree" "list" "--porcelain")))
         (ecc-worktree-parse output))))))

(defun ecc-worktree-toplevel (directory)
  "Return the top of the worktree holding DIRECTORY, or nil."
  (let ((directory (ecc-worktree--key directory)))
    (ecc-worktree--memo
     (cons 'toplevel directory)
     (lambda ()
       (when-let* ((output (ecc-worktree--output
                            directory "rev-parse" "--show-toplevel")))
         (and (not (string-empty-p output))
              (file-name-as-directory output)))))))

(defun ecc-worktree-main (root)
  "Return the main worktree of ROOT when ROOT is a linked worktree.
Nil when ROOT is the main worktree itself, or is not in a repository at
all.  That nil is the whole answer a caller needs to lay a repository
out: a directory with a main worktree above it is a checkout of
somebody else's project, and everything else stands on its own.

The paths are compared through `file-truename' because git resolves
symbolic links and the caller has not: on macOS a worktree under
\"/tmp\" is \"/private/tmp\" to git and neither spelling is wrong."
  (let ((root (ecc-worktree--key root)))
    (ecc-worktree--memo
     (cons 'main root)
     (lambda ()
       (when-let* ((top (ecc-worktree-toplevel root))
                   (entries (ecc-worktree-list root))
                   (main (ecc-worktree-entry-path (car entries))))
         (unless (equal (file-truename main) (file-truename top))
           main))))))

(defun ecc-worktree-branch (root)
  "Return the branch checked out in ROOT, or nil.
Nil for a detached HEAD as well as for a directory that is not in a
repository: neither has a branch to name."
  (let ((root (ecc-worktree--key root)))
    (ecc-worktree--memo
     (cons 'branch root)
     (lambda ()
       (when-let* ((ref (ecc-worktree--output
                         root "symbolic-ref" "--quiet" "HEAD")))
         (and (not (string-empty-p ref))
              (ecc-worktree--short-branch ref)))))))

(defun ecc-worktree-ahead-behind (root)
  "Return (AHEAD . BEHIND) of ROOT against its upstream, or nil.
Nil when the branch has no upstream, which is the usual case for a
branch that was made here and never pushed.

The left side of `rev-list --left-right' is the first revision named,
which is the upstream, so the left count is what the upstream has and
HEAD does not -- behind -- and the right count is ahead.  Verified
against git 2.50.1 by `ecc-worktree-test-ahead-behind' (2026-09-14)."
  (let ((root (ecc-worktree--key root)))
    (ecc-worktree--memo
     (cons 'ahead-behind root)
     (lambda ()
       (when-let* ((output (ecc-worktree--output
                            root "rev-list" "--left-right" "--count"
                            "@{u}...HEAD")))
         (pcase (split-string output)
           (`(,behind ,ahead)
            (cons (string-to-number ahead) (string-to-number behind)))))))))

(defun ecc-worktree-of-branch (root branch)
  "Return the worktree of the repository ROOT that has BRANCH checked out.
Nil when no checkout holds it.  git allows one branch in one worktree
at a time, so this is what says in advance that `ecc-worktree-create'
would be refused -- and where the work on that branch already is."
  (seq-find (lambda (entry) (equal (ecc-worktree-entry-branch entry) branch))
            (ecc-worktree-list root)))

(defun ecc-worktree-branches (root)
  "Return the local branches of the repository holding ROOT."
  (when-let* ((output (ecc-worktree--output
                       root "branch" "--format=%(refname:short)")))
    (split-string output "\n" t)))

;;;; Where a new one goes

(defun ecc-worktree-slug (branch)
  "Return the directory name a worktree of BRANCH is put under.
Anything that is not a letter or a digit becomes a dash, a run of them
becomes one, the result is lower case and is not left starting or
ending in a dash.  A branch that has nothing else in it -- \"--\" --
answers \"worktree\", because a directory still needs a name.  This is
herdr's `branch_to_path_slug', so that the two agree about where a
worktree of a branch would be."
  (let ((slug (string-trim
               (replace-regexp-in-string "[^[:alnum:]]+" "-"
                                         (downcase (or branch "")))
               "-+" "-+")))
    (if (string-empty-p slug) "worktree" slug)))

(defun ecc-worktree-path (root branch)
  "Return where a worktree of BRANCH for the repository ROOT belongs.
ROOT is the main worktree.  See `ecc-worktree-directory' for the two
shapes; the result is a directory name and nothing is created."
  (let ((slug (ecc-worktree-slug branch))
        (directory ecc-worktree-directory))
    (file-name-as-directory
     (if (or (file-name-absolute-p directory) (string-prefix-p "~" directory))
         (expand-file-name
          slug (expand-file-name
                (file-name-nondirectory (directory-file-name root))
                (expand-file-name directory)))
       (expand-file-name slug (expand-file-name directory root))))))

;;;; Making and unmaking one

(defun ecc-worktree--refused (result what)
  "Signal that git refused WHAT, quoting RESULT.
RESULT is what `ecc-worktree--git' returned."
  (user-error "%s: %s" what
              (if result
                  (string-trim (cdr result))
                "git could not be run")))

(defun ecc-worktree-create (root branch &optional base)
  "Check BRANCH of the repository ROOT out beside it, and return where.
ROOT is the main worktree.  An existing BRANCH is checked out as it
is; a new one is made, from BASE or from HEAD.  Whatever git says when
it refuses is what the error says."
  (let* ((branch (string-trim (or branch "")))
         (path (and (not (string-empty-p branch))
                    (ecc-worktree-path root branch))))
    (when (string-empty-p branch)
      (user-error "The branch name is empty"))
    (when (file-exists-p path)
      (user-error "%s exists already" (abbreviate-file-name path)))
    (let* ((known (ecc-worktree--output root "branch" "--list" branch))
           (result (if (and known (not (string-empty-p known)))
                       (ecc-worktree--git root "worktree" "add" path branch)
                     (ecc-worktree--git root "worktree" "add" "-b" branch path
                                        (or base "HEAD")))))
      (unless (eq 0 (car-safe result))
        (ecc-worktree--refused result (format "Cannot add a worktree for %s"
                                              branch)))
      (ecc-worktree-forget)
      path)))

(defun ecc-worktree-remove (path &optional force)
  "Remove the worktree checked out at PATH, and return PATH.
The branch is left alone: what is undone is a checkout.  Deleting it
too is `ecc-worktree-delete-branch\=', which the commands offer once
this has returned.

git refuses a checkout with changes in it that are not committed, and
that refusal is put to the user as a question of its own rather than
answered for them -- FORCE non-nil is that answer given in advance.
Its other refusals -- a worktree that is locked, one that is the main
one -- are passed on as they are: neither is a thing to insist on."
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (where (or (ecc-worktree-main path) path))
         (result (ecc-worktree--git where "worktree" "remove" path)))
    (when (and result
               (/= 0 (car result))
               (string-match-p "modified or untracked files" (cdr result))
               (or force
                   (yes-or-no-p
                    (format "%s has changes that are not committed.  \
Remove it anyway? "
                            (abbreviate-file-name path)))))
      (setq result (ecc-worktree--git where "worktree" "remove" "--force" path)))
    (unless (eq 0 (car-safe result))
      (ecc-worktree--refused result (format "Cannot remove %s"
                                            (abbreviate-file-name path))))
    (ecc-worktree-forget)
    path))

(defun ecc-worktree-delete-branch (root branch &optional force)
  "Delete BRANCH from the repository ROOT, and return BRANCH, or nil.
Nil when git had to be insisted with and the user would not.

git refuses to delete a branch whose commits are on no other branch,
and that refusal is put to the user as a question of its own rather
than answered for them -- FORCE non-nil is that answer given in
advance.  Its other refusals -- a branch that is checked out somewhere,
a name no branch has -- are passed on as they are."
  (let* ((result (ecc-worktree--git root "branch" "-d" branch))
         (unmerged (and result
                        (/= 0 (car result))
                        (string-match-p "not fully merged" (cdr result)))))
    (when (or (not unmerged)
              force
              (yes-or-no-p
               (format "%s is not merged anywhere else.  Delete it anyway? "
                       branch)))
      (when unmerged
        (setq result (ecc-worktree--git root "branch" "-D" branch)))
      (unless (eq 0 (car-safe result))
        (ecc-worktree--refused result (format "Cannot delete %s" branch)))
      (ecc-worktree-forget)
      branch)))

(defun ecc-worktree-offer-branch-removal (root branch)
  "Offer to delete BRANCH of the repository ROOT, and return it when deleted.
This is for the moment a checkout of BRANCH has just been undone: the
work is on the branch, so the branch is never taken without being asked
for, and the question is asked where somebody is thinking about it.

Nothing is offered for a checkout that was detached, which had no
branch of its own, for a branch that is gone already, or for one that
is still checked out in another worktree -- git would refuse that one,
and the question would be a dead end in front of it."
  (when (and root branch
             (member branch (ecc-worktree-branches root))
             (null (ecc-worktree-of-branch root branch))
             (yes-or-no-p (format "Delete the branch %s as well? " branch)))
    (ecc-worktree-delete-branch root branch)))

(defun ecc-worktree--removed (main path branch)
  "Say that the checkout PATH is gone, having offered BRANCH with it.
MAIN is the repository PATH hung off, and BRANCH what it had checked
out, both read before the removal.  One message for both answers: two
in a row would leave the user with whichever arrived last."
  (let ((deleted (ecc-worktree-offer-branch-removal main branch)))
    (message "Removed %s%s" (abbreviate-file-name path)
             (if deleted (format " and the branch %s" deleted) ""))))

;;;; Offering to undo a checkout nothing is left in

;; A worktree is usually made for one session, so the moment that session
;; is stopped is the moment to ask whether the checkout should go too --
;; and the only moment the user is thinking about it.  The offer is not
;; inside `ecc-kill': that is the primitive `ecc-space-close' and
;; `ecc-remove-worktree' call in a loop, and a primitive that sometimes
;; deletes a directory is one nobody can call safely.  What calls this is
;; the handful of places where a person stopped one session by hand.

(defun ecc-worktree--visiting-buffers (root)
  "Return the buffers visiting a file under ROOT."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (seq-filter (lambda (buffer)
                  (when-let* ((file (buffer-file-name buffer)))
                    (string-prefix-p root (expand-file-name file))))
                (buffer-list))))

(defun ecc-worktree-offer-removal (root)
  "Offer to undo the checkout at ROOT, and return it when it was removed.
Nothing is offered unless ROOT is a linked worktree with no session of
this Emacs left in it: stopping one of two sessions working there is no
reason to take the tree from the other.

The buffers still visiting the checkout are counted in the question
rather than killed.  This package does not close a user\\='s buffers, and
a file that goes out from under one is something to be told about
before the fact, not tidied up after."
  (when (and root
             (ecc-worktree-main root)
             (null (ecc-window-project-sessions root)))
    ;; The repository and the branch are read while the checkout is
    ;; still there: once it is gone there is no directory to ask git
    ;; about, and the branch is what the next question is about.
    (let ((main (ecc-worktree-main root))
          (branch (ecc-worktree-branch root))
          (open (length (ecc-worktree--visiting-buffers root))))
      (when (yes-or-no-p
             (format "Nothing is left running in %s.  Remove the checkout%s? "
                     (abbreviate-file-name root)
                     (if (zerop open)
                         ""
                       (format " (%d open buffer%s will be left pointing at \
deleted files)"
                               open (if (= 1 open) "" "s")))))
        (ecc-worktree-remove root)
        (ecc-worktree--removed main root branch)
        root))))

(defun ecc-worktree-kill-session (session)
  "Stop SESSION, then offer to undo its checkout when it was a worktree.
The project is read before the session is stopped: `ecc-kill' forgets
it, and there is nothing to ask about afterwards."
  (require 'ecc)
  (let ((root (ecc-window-session-project session)))
    (ecc-kill session)
    (ecc-worktree-offer-removal root)))

(defvar ecc-worktree-delegate-brief
  "You are in a git worktree of %s, checked out at %s on the branch %s.
The work below was handed to you by the session %s, which is staying in
the repository it came from; it is yours from here.

%s"
  "What a delegated session is told, before the brief it was given.
The arguments are the repository, the checkout, the branch, the session
that handed the work over and the brief itself.  A session that was
started for one piece of work is told where it is and who sent it: the
transcript it came from is not there to be read, and a worktree looks
like the repository until git is asked.")

(defun ecc-worktree-delegate (root branch brief &optional base)
  "Start a session on BRANCH in a worktree of ROOT and hand it BRIEF.
Returns the session.  ROOT is any directory of the repository; the
checkout is made beside its main worktree, under
`ecc-worktree-directory\='.  BASE is what a branch that does not exist yet
is made from, HEAD by default.

BRIEF is everything the new session will be told, so it is refused
empty.  It is sent as the first prompt of the session, which is why
nothing here waits: the CLI takes a prompt as soon as its process is
up.

A branch that is checked out in another worktree already is refused
rather than gone to, which is what `ecc-start-worktree\=' does when a
person asked for it: two sessions in one checkout is not what handing a
piece of work over means, and the caller -- a model naming a branch of
its own -- can name another one."
  (require 'ecc)
  (let* ((asked (ecc-worktree--key root))
         (root (or (ecc-worktree-main asked) asked))
         (branch (string-trim (or branch "")))
         (brief (string-trim (or brief ""))))
    (when (string-empty-p branch)
      (user-error "The branch name is empty"))
    (when (string-empty-p brief)
      (user-error "There is nothing to hand over"))
    (when-let* ((held (ecc-worktree-of-branch root branch)))
      (user-error "%s is checked out at %s already; name another branch"
                  branch (abbreviate-file-name
                          (ecc-worktree-entry-path held))))
    (let* ((path (ecc-worktree-create root branch base))
           (from (ecc-worktree--delegating-session))
           (session (ecc-start path)))
      (ecc-proc-send-prompt
       session (format ecc-worktree-delegate-brief
                       (abbreviate-file-name root)
                       (abbreviate-file-name path)
                       branch
                       (or from "another session")
                       brief))
      session)))

(defun ecc-worktree--delegating-session ()
  "Return the name of the session handing work over, or nil.
The MCP server knows which session is calling it; a command run by hand
has the buffer it was run in."
  (cond
   ((and (fboundp 'ecc-mcp-session) (ecc-mcp-session))
    (ecc-session-name (ecc-mcp-session)))
   ((bound-and-true-p ecc-render--session)
    (ecc-session-name ecc-render--session))))

;;;; Handing a piece of work over from inside a session

;; The flow this is for: the user, in a session, asks for something to be
;; done in a worktree of its own.  Left alone the CLI runs `git worktree
;; add' and goes on working in the same session -- one conversation, two
;; checkouts, and the transcript, the Space and `default-directory' all
;; still pointing at the repository.  The tool gives the model somewhere
;; to put that request instead: Emacs makes the checkout, opens it as a
;; Space of its own, starts a session in it and hands it the brief the
;; model wrote, and the model names the branch.

(defun ecc-worktree-mcp-delegate (branch task &optional base)
  "Start a session on BRANCH in a worktree and hand it TASK.
The MCP tool `start_worktree_session\='.  The repository is the one the
calling session works in, BASE is what a new branch is made from, and
the answer names the session that has the work now."
  (let* ((session (and (fboundp 'ecc-mcp-session) (ecc-mcp-session)))
         (root (or (and session (or (ecc-session-cwd session)
                                    (ecc-session-project-root session)))
                   default-directory))
         (started (ecc-worktree-delegate root branch task base)))
    (format "Started the session %s in %s, on the branch %s.  It has the brief and is working on it; the work is no longer yours."
            (ecc-session-name started)
            (abbreviate-file-name (ecc-session-project-root started))
            branch)))

(defun ecc-worktree-register-mcp-tool ()
  "Publish `start_worktree_session\=' to the model."
  (ecc-mcp-define-tool
   :name "start_worktree_session"
   :description "Hand a piece of work to a second Claude session running in a git worktree of this project.  Emacs makes the checkout, opens it as a window of its own, starts a session there and gives it the brief.  Use this whenever the user asks for something to be done in a worktree, on a branch or in a session of its own, instead of running `git worktree add' yourself and carrying on here.  You choose the branch name, the way this repository names its branches.  The brief is the only thing the new session is told -- it cannot read this conversation -- so write it to stand on its own: what to do, why, the files and the decisions already made here, and what finished looks like.  When this returns, the work belongs to that session: report where it went and do not do it here as well."
   :args '(("branch" "string" "The branch to make, named the way this repository names its branches" t)
           ("task" "string" "The whole brief for the new session, standing on its own without this conversation" t)
           ("base" "string" "The revision the branch is made from; HEAD by default"))
   :function #'ecc-worktree-mcp-delegate))

(with-eval-after-load 'ecc-mcp (ecc-worktree-register-mcp-tool))

;;;; Commands

(defun ecc-worktree-context-root ()
  "Return the main worktree of the project a command should act in.
A worktree of a worktree is not a thing, so a command run from a
linked checkout means the repository it came from."
  (let ((root (ecc-window-context-project-root)))
    (or (ecc-worktree-main root) root)))

(defun ecc-worktree-read-branch (root)
  "Ask for the branch a new worktree of ROOT should be on.
The existing branches are offered but nothing is filled in: the name of
a branch is the user's to give, and a default here would be a branch
made by accident."
  (string-trim (completing-read "Branch for the worktree: "
                                (ecc-worktree-branches root))))

(defun ecc-worktree-read-linked (prompt)
  "Ask with PROMPT which linked worktree of this project to act on.
The current one answers for itself when the command was run in one."
  (let ((root (ecc-window-context-project-root)))
    (if (ecc-worktree-main root)
        root
      (let* ((entries (seq-remove #'ecc-worktree-entry-main-p
                                  (ecc-worktree-list root))))
        (unless entries
          (user-error "This project has no worktree of its own"))
        (let* ((labels (mapcar (lambda (entry)
                                 (cons (ecc-worktree--label entry) entry))
                               entries))
               (choice (completing-read prompt (mapcar #'car labels) nil t)))
          (ecc-worktree-entry-path (cdr (assoc choice labels))))))))

(defun ecc-worktree--label (entry)
  "Return the line the worktree ENTRY is offered under."
  (format "%-24s  %s"
          (ecc--truncate (or (ecc-worktree-entry-branch entry) "(detached)") 24)
          (abbreviate-file-name (ecc-worktree-entry-path entry))))

;;;###autoload
(defun ecc-start-worktree (branch)
  "Check BRANCH out in a worktree of this project and start a session there.
The branch may be one that exists or one to make.  Where the checkout
goes is `ecc-worktree-directory'."
  (interactive (list (ecc-worktree-read-branch (ecc-worktree-context-root))))
  (require 'ecc)
  (let* ((root (ecc-worktree-context-root))
         ;; git allows one branch in one worktree at a time, so asking
         ;; for a branch that is checked out already can only mean the
         ;; checkout that has it -- the alternative being git's refusal,
         ;; which is a dead end in front of the thing that was wanted.
         ;; The name of that checkout need not be the one this package
         ;; would have given it: Claude Code's own worktrees turn a `/'
         ;; into a `+' where this turns it into a `-' (2026-09-14), so
         ;; the branch is what is asked about, not the directory.
         (existing (ecc-worktree-of-branch root branch))
         (path (cond
                ((null existing) (ecc-worktree-create root branch))
                ((ecc-worktree-entry-main-p existing)
                 (user-error "%s is the branch of the repository itself"
                             branch))
                ((yes-or-no-p
                  (format "%s is checked out at %s already.  Start a session there? "
                          branch
                          (abbreviate-file-name
                           (ecc-worktree-entry-path existing))))
                 (ecc-worktree-entry-path existing))
                (t (user-error "Left alone"))))
         (session (ecc-start path)))
    (message "Started %s in %s (branch %s)"
             (ecc-session-name session) (abbreviate-file-name path) branch)
    session))

;;;###autoload
(defun ecc-start-in-worktree (path)
  "Start a session in the worktree PATH of this project.
Interactively, the worktrees of the project are offered."
  (interactive
   (list (let* ((root (ecc-window-context-project-root))
                (entries (seq-remove #'ecc-worktree-entry-main-p
                                     (ecc-worktree-list root))))
           (unless entries
             (user-error "This project has no worktree of its own"))
           (let ((labels (mapcar (lambda (entry)
                                   (cons (ecc-worktree--label entry) entry))
                                 entries)))
             (ecc-worktree-entry-path
              (cdr (assoc (completing-read "Worktree: " (mapcar #'car labels)
                                           nil t)
                          labels)))))))
  (require 'ecc)
  (ecc-start path))

;;;###autoload
(defun ecc-remove-worktree (path)
  "Remove the worktree at PATH, stopping the sessions that work in it.
Interactively, the worktree the command was run in, or one chosen from
the worktrees of this project.  The checkout goes, and the branch it
was on is offered afterwards rather than taken with it."
  (interactive (list (ecc-worktree-read-linked "Remove worktree: ")))
  (let ((sessions (ecc-window-project-sessions path)))
    (if sessions
        (unless (yes-or-no-p (format "Stop %d session%s and remove %s? "
                                     (length sessions)
                                     (if (= 1 (length sessions)) "" "s")
                                     (abbreviate-file-name path)))
          (user-error "Left alone"))
      ;; Nothing is running there, but a checkout is still a directory
      ;; full of work.  git refuses one with uncommitted changes in it
      ;; and `ecc-worktree-remove' asks before insisting; this asks
      ;; before the command that has no other confirmation at all does
      ;; anything.
      (unless (yes-or-no-p (format "Remove the worktree %s? "
                                   (abbreviate-file-name path)))
        (user-error "Left alone")))
    (when sessions
      (require 'ecc)
      (mapc #'ecc-kill sessions))
    ;; Read while the checkout is still there, and asked about once it
    ;; is gone: a branch cannot be deleted while a worktree holds it.
    (let ((main (ecc-worktree-main path))
          (branch (ecc-worktree-branch path)))
      (ecc-worktree-remove path)
      (ecc-worktree--removed main path branch))))

(provide 'ecc-worktree)

;;; ecc-worktree.el ends here
