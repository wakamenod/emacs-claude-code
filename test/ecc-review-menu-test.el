;;; ecc-review-menu-test.el --- Tests for ecc-review-menu  -*- lexical-binding: t; -*-

;;; Commentary:

;; The menu cannot be driven in batch, so what its suffixes call is
;; tested instead: the ranges `b' and `c' build, the guess at the base
;; branch, the counts, the session the comments go to, and the arguments
;; each suffix hands `ecc-review' or `ecc-review-worktree'.  The git
;; cases build a throwaway repository.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-review-menu)
(require 'ecc-review-agent)
(require 'ecc-mcp)

;;;; Helpers

(defmacro ecc-review-menu-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory
                (file-truename (make-temp-file "ecc-review-menu" t)))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-menu-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY and return its output, trimmed.
The test fails when git does."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (string-trim (cdr result))))

(defun ecc-review-menu-test--write (directory file content)
  "Write CONTENT to FILE under DIRECTORY."
  (with-temp-file (expand-file-name file directory) (insert content)))

(defun ecc-review-menu-test--commit (directory file content)
  "Write CONTENT to FILE under DIRECTORY, commit it and return the short id."
  (ecc-review-menu-test--write directory file content)
  (ecc-review-menu-test--git directory "add" file)
  (ecc-review-menu-test--git directory "commit" "-q" "-m" file)
  (ecc-review-menu-test--git directory "rev-parse" "--short" "HEAD"))

(defun ecc-review-menu-test--repo (directory)
  "Make DIRECTORY a repository of three branches and return its commits.
main has one commit, develop one more, and feature -- checked out --
one more again: the returned list is those three short ids, oldest
first."
  (ecc-review-menu-test--git directory "init" "-q" "-b" "main")
  (ecc-review-menu-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-menu-test--git directory "config" "user.name" "t")
  (let* ((one (ecc-review-menu-test--commit directory "a.txt" "a\n"))
         (two (progn (ecc-review-menu-test--git directory "checkout" "-q" "-b" "develop")
                     (ecc-review-menu-test--commit directory "b.txt" "b\n")))
         (three (progn (ecc-review-menu-test--git directory "checkout" "-q" "-b" "feature")
                       (ecc-review-menu-test--commit directory "c.txt" "c\n"))))
    (list one two three)))

(defmacro ecc-review-menu-test--capturing (calls &rest body)
  "Run BODY with `ecc-review' and `ecc-review-worktree' recorded in CALLS.
Each call is pushed as (COMMAND STYLE ARGS...), STYLE being the
`ecc-review-style' it ran with.  `ecc-review-menu--last' is restored."
  (declare (indent 1))
  `(let ((,calls nil)
         (ecc-review-menu--last nil)
         (ecc-review-style 'diff))
     (cl-letf (((symbol-function 'ecc-review)
                (lambda (&rest args)
                  (push (cons 'ecc-review (cons ecc-review-style args)) ,calls)))
               ((symbol-function 'ecc-review-worktree)
                (lambda (&rest args)
                  (push (cons 'ecc-review-worktree (cons ecc-review-style args))
                        ,calls))))
       ,@body)))

(defun ecc-review-menu-test--id (directory revision)
  "Return the full id of REVISION in DIRECTORY."
  (ecc-review-menu-test--git directory "rev-parse" revision))

(defun ecc-review-menu-test--kill-reviews ()
  "Kill every review buffer a test left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (kill-buffer buffer))))

(defun ecc-review-menu-test--tool (session name &optional arguments)
  "Call the tool NAME as SESSION would and return its text, failing on a failure."
  (pcase-let ((`(,failed . ,text) (let ((ecc-mcp--session-id (ecc-session-id session)))
                                    (ecc-mcp-call-tool name arguments))))
    (when failed (ert-fail text))
    text))

;;;; Which branch b compares with

(ert-deftest ecc-review-menu-test-guess-base ()
  "The base is the nearest candidate that HEAD has gone beyond."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (let ((root (ecc-review-git-root directory)))
        ;; A feature branch off develop: one commit beyond develop, two
        ;; beyond main.  The fork comes with the guess.
        (should (equal (ecc-review-menu-guess-base root)
                       (cons "develop" (ecc-review-menu-test--id directory two))))
        ;; A branch just cut from develop, with main behind: develop, at
        ;; HEAD itself, so that b shows the working tree alone.
        (ecc-review-menu-test--git directory "checkout" "-q" "-b" "fresh" "develop")
        (should (equal (ecc-review-menu-guess-base root)
                       (cons "develop" (ecc-review-menu-test--id directory two))))
        ;; The current branch is never its own base.
        (ecc-review-menu-test--git directory "checkout" "-q" "develop")
        (should (equal (car (ecc-review-menu-guess-base root)) "main"))
        ;; On main with develop ahead: develop is ahead of HEAD and would
        ;; compare HEAD with itself, so it is not the base.
        (ecc-review-menu-test--git directory "checkout" "-q" "main")
        (should-not (equal (car (ecc-review-menu-guess-base root)) "develop"))
        ;; On main with commits not pushed: origin/main, where they show.
        (ecc-review-menu-test--git directory "update-ref" "refs/remotes/origin/main" "HEAD")
        (ecc-review-menu-test--git directory "symbolic-ref" "refs/remotes/origin/HEAD"
                                   "refs/remotes/origin/main")
        (ecc-review-menu-test--commit directory "m.txt" "m\n")
        (should (equal (car (ecc-review-menu-guess-base root)) "origin/main"))
        ;; Without origin/HEAD, develop is a base again: main has a
        ;; commit of its own now, so develop no longer holds HEAD.
        (ecc-review-menu-test--git directory "symbolic-ref" "--delete"
                                   "refs/remotes/origin/HEAD")
        (should (equal (car (ecc-review-menu-guess-base root)) "develop"))
        ;; The upstream of main counts: as far behind HEAD as develop, and
        ;; its tip nearer, so it wins the tie.
        ;; An upstream is read through the remote's fetch refspec.
        (ecc-review-menu-test--git directory "remote" "add" "origin" "https://example.com/r.git")
        (ecc-review-menu-test--git directory "config" "branch.main.remote" "origin")
        (ecc-review-menu-test--git directory "config" "branch.main.merge" "refs/heads/main")
        (should (equal (car (ecc-review-menu-guess-base root)) "origin/main"))
        ;; A feature branch's own upstream is not its base.
        (ecc-review-menu-test--git directory "checkout" "-q" "feature")
        (ecc-review-menu-test--git directory "update-ref" "refs/remotes/origin/feature"
                                   "HEAD~1")
        (ecc-review-menu-test--git directory "config" "branch.feature.remote" "origin")
        (ecc-review-menu-test--git directory "config" "branch.feature.merge"
                                   "refs/heads/feature")
        (should (equal (car (ecc-review-menu-guess-base root)) "develop"))))))

(ert-deftest ecc-review-menu-test-guess-base-tie ()
  "Of two candidates as far behind HEAD, the one whose tip is nearer wins."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    ;; main and develop both part from feature at develop's commit once
    ;; main has gone on by two commits of its own: a tie on HEAD's side.
    (ecc-review-menu-test--git directory "checkout" "-q" "-B" "main" "develop")
    (ecc-review-menu-test--commit directory "m1.txt" "1\n")
    (ecc-review-menu-test--commit directory "m2.txt" "2\n")
    (ecc-review-menu-test--git directory "checkout" "-q" "feature")
    (let ((root (ecc-review-git-root directory))
          (ecc-review-menu-base-candidates '("main" "develop")))
      (should (equal (car (ecc-review-menu-guess-base root)) "develop")))))

(ert-deftest ecc-review-menu-test-no-base-still-asks ()
  "With no branch guessed, b asks for one with no default rather than going off."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-review-menu-test--git directory "checkout" "-q" "main")
    (let ((ecc-review-menu--state (ecc-review-menu-make-state nil directory))
          (seen nil))
      (should (plist-get ecc-review-menu--state :root))
      (should-not (plist-get ecc-review-menu--state :base))
      ;; Inapt outside git alone, and the line has no count.
      (should (eq (oref (get 'ecc-review-menu-branch 'transient--suffix) inapt-if)
                  #'ecc-review-menu--outside-git-p))
      (should (equal (ecc-review-menu--describe 'branch) "this branch vs …"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &optional _pred _match _initial _history default
                                 &rest _)
                   (setq seen (list prompt default (all-completions "" table)))
                   "develop")))
        (should (equal (ecc-review-menu--read-base) "develop")))
      (should (equal (car seen) "Base, the before side: "))
      (should-not (cadr seen))
      (should (member "develop" (nth 2 seen))))))

;;;; What b and c compare

(ert-deftest ecc-review-menu-test-branch-range ()
  "b against the current branch is the fork point and the working tree."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (let ((root (ecc-review-git-root directory))
            (fork (ecc-review-menu-test--id directory two)))
        ;; Every way of saying the current branch is the same answer,
        ;; called after what it compares rather than after the id.
        (dolist (other '(nil "" "HEAD" "feature"))
          (should (equal (ecc-review-menu-branch-range root "develop" other)
                         (cons fork "develop + working tree"))))
        ;; The menu's own state answers without asking git again.
        (should (equal (car (ecc-review-menu-branch-range
                             root "develop" nil '(:branch "feature" :base "develop"
                                                  :fork "remembered")))
                       "remembered"))
        ;; That range reads the working tree, untracked files and all.
        (should (ecc-review--range-includes-worktree-p root fork))
        (ecc-review-menu-test--write directory "new.txt" "new\n")
        (ecc-review-menu-test--write directory "c.txt" "changed\n")
        (ecc-test-with-fake-session session
          (let ((text (plist-get (ecc-review--worktree-content session fork root nil)
                                 :text)))
            (should (string-search "b/c.txt" text))
            (should (string-search "b/new.txt" text))
            ;; develop's own commit is not part of it.
            (should-not (string-search "b/b.txt" text))))
        ;; Another branch is what a pull request of it shows.
        (should (equal (ecc-review-menu-branch-range root "main" "develop")
                       (cons "main...develop" nil)))
        (should (string-search "Name the branch"
                               (cadr (should-error (ecc-review-menu-branch-range root "")
                                                   :type 'user-error))))))))

(ert-deftest ecc-review-menu-test-options-are-not-names ()
  "b and c take a branch and a commit; --staged is the range of r alone."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (let ((root (ecc-review-git-root directory)))
      (dolist (call (list (lambda () (ecc-review-menu-branch-range root "--staged"))
                          (lambda () (ecc-review-menu-branch-range root "main" "--cached"))
                          (lambda () (ecc-review-menu-branch-range root "--output=x"))))
        (should (string-search "A branch is expected"
                               (cadr (should-error (funcall call) :type 'user-error)))))
      (dolist (call (list (lambda () (ecc-review-menu-commit-range root "--staged"))
                          (lambda () (ecc-review-menu-commit-range root "HEAD" "--cached"))))
        (should (string-search "A commit is expected"
                               (cadr (should-error (funcall call) :type 'user-error)))))
      ;; r is where --staged means the index.
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "--staged")))
        (should (eq (ecc-review-read-range) 'staged))))))

(ert-deftest ecc-review-menu-test-commit-range ()
  "c is one commit, or a span from the older through the newer, by their ids."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (one two three) (ecc-review-menu-test--repo directory)
      (let* ((root (ecc-review-git-root directory))
             (empty (ecc-review--empty-tree root))
             (one-id (ecc-review-menu-test--id directory one))
             (two-id (ecc-review-menu-test--id directory two))
             (three-id (ecc-review-menu-test--id directory three)))
        (should (equal (ecc-review-menu-commit-range root two) (concat two-id "^!")))
        (should (equal (ecc-review-range-label root (concat two-id "^!"))
                       (concat two " b.txt")))
        (should (equal (ecc-review-menu-commit-range root two "") (concat two-id "^!")))
        (should (equal (ecc-review-menu-commit-range root two two-id)
                       (concat two-id "^!")))
        (should (equal (ecc-review-menu-commit-range root two three)
                       (format "%s^..%s" two-id three-id)))
        (should (equal (ecc-review-range-label root (format "%s^..%s" two-id three-id))
                       (format "%s to %s" two three)))
        ;; Picked newest first, the span is the same.
        (should (equal (ecc-review-menu-commit-range root three two)
                       (format "%s^..%s" two-id three-id)))
        ;; The first commit has no parent: the empty tree stands in.
        (let ((alone (ecc-review-menu-commit-range root one)))
          (should (equal (ecc-review-range-label root alone) (concat one " a.txt")))
          (should (equal alone (format "%s..%s" empty one-id)))
          ;; Which compares commits, not the working tree, and shows
          ;; that commit's file and nothing later.
          (should-not (ecc-review--range-includes-worktree-p root alone))
          (should (equal (ecc-review-menu-test--git directory "diff" "--name-only" alone)
                         "a.txt")))
        (should (equal (ecc-review-menu-commit-range root one two)
                       (format "%s..%s" empty two-id)))
        (should (equal (ecc-review-range-label root (format "%s..%s" empty two-id))
                       (concat "first commit to " two)))
        (should-error (ecc-review-menu-commit-range root "no-such-commit")
                      :type 'user-error)))))

(ert-deftest ecc-review-menu-test-commit-review-stays-on-its-commit ()
  "A review of HEAD^! read again after a commit is still the commit it was,
under the name it was given."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one _two three) (ecc-review-menu-test--repo directory)
      (ecc-test-with-fake-session session
        (setf (ecc-session-project-root session) directory)
        (let* ((root (ecc-review-git-root directory))
               (range (ecc-review-menu-commit-range root "HEAD"))
               (buffer (ecc-review-worktree-buffer session range directory)))
          (unwind-protect
              (with-current-buffer buffer
                (should (equal (buffer-name buffer)
                               (format "*ecc-review: test (%s c.txt)*" three)))
                (should (string-search "b/c.txt" (buffer-string)))
                (ecc-review-menu-test--commit directory "d.txt" "d\n")
                (ecc-review-refresh)
                ;; The same commit, in the same buffer, called the same.
                (should (string-search "b/c.txt" (buffer-string)))
                (should-not (string-search "d.txt" (buffer-string)))
                (should (equal (buffer-name buffer)
                               (format "*ecc-review: test (%s c.txt)*" three)))
                (should (string-search (format "%s c.txt" three)
                                       (ecc-review--header-line))))
            (kill-buffer buffer)))))))

(ert-deftest ecc-review-menu-test-branch-review-is-named-for-what-it-compares ()
  "b RET RET is called after its base, and the same choice reuses its buffer."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-review-menu-test--write directory "c.txt" "changed\n")
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (let* ((ecc-review-menu--state (ecc-review-menu-make-state session directory))
             (buffers nil))
        (cl-letf (((symbol-function 'ecc-window-display-review)
                   (lambda (buffer &rest _) (push buffer buffers))))
          (unwind-protect
              (progn
                (ecc-review-menu-branch "develop" nil nil)
                (ecc-review-menu-branch "develop" "feature" nil)
                (should (eq (car buffers) (cadr buffers)))
                (should (equal (buffer-name (car buffers))
                               "*ecc-review: test (develop + working tree)*"))
                (with-current-buffer (car buffers)
                  ;; The range is still the id git is given.
                  (should (equal ecc-review--range (plist-get ecc-review-menu--state :fork)))
                  (ecc-review-refresh)
                  (should (equal (buffer-name) "*ecc-review: test (develop + working tree)*"))))
            (mapc #'kill-buffer (seq-uniq buffers))))))))

(ert-deftest ecc-review-menu-test-claude-opens-the-same-review ()
  "review_open of the commit b or c compares opens the buffer the menu opened.
The name comes from what is compared, so Claude's comments land in the
review the user is reading."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (ecc-review-menu-test--write directory "c.txt" "changed\n")
      (ecc-test-with-fake-session session
        (setf (ecc-session-project-root session) directory)
        (let ((ecc-review-menu--state (ecc-review-menu-make-state session directory))
              (menu nil))
          (cl-letf (((symbol-function 'ecc-window-display-review)
                     (lambda (buffer &rest _) (setq menu buffer))))
            (unwind-protect
                (progn
                  ;; b RET RET, then Claude with the fork git names.
                  (ecc-review-menu-branch "develop" nil nil)
                  (ecc-review-menu-test--tool
                   session "review_open"
                   `((range . ,(ecc-review-menu-test--git
                                directory "merge-base" "develop" "HEAD"))))
                  (should (eq (gethash session ecc-review-agent--opened) menu))
                  ;; c X RET, then Claude with the short id.
                  (ecc-review-menu-commit two nil nil)
                  (should (equal (buffer-name menu) (format "*ecc-review: test (%s b.txt)*" two)))
                  (ecc-review-menu-test--tool session "review_open"
                                             `((range . ,(concat two "^!"))))
                  (should (eq (gethash session ecc-review-agent--opened) menu)))
              (ecc-review-menu-test--kill-reviews))))))))

(ert-deftest ecc-review-menu-test-read-commits ()
  "The second question of c defaults to the first answer, which is one commit."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two three) (ecc-review-menu-test--repo directory)
      (let ((root (ecc-review-git-root directory))
            (answers nil)
            (defaults nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _table &optional _pred _match _initial _history default
                                    &rest _)
                     (push default defaults)
                     (let ((answer (pop answers)))
                       (if (equal answer "") default answer)))))
          ;; RET RET: HEAD alone.
          (setq answers '("" ""))
          (should (equal (ecc-review-menu--read-commits root) (list three nil)))
          ;; The first default is the newest commit, the second the first answer.
          (should (string-prefix-p three (cadr defaults)))
          (should (string-prefix-p three (car defaults)))
          ;; A line picked from the list is its commit.
          (setq answers (list (concat two " b.txt") ""))
          (should (equal (ecc-review-menu--read-commits root) (list two nil)))
          (setq answers (list two three))
          (should (equal (ecc-review-menu--read-commits root) (list two three))))))))

(ert-deftest ecc-review-menu-test-read-other-defaults-to-the-working-tree ()
  "The second question of b offers the current branch first."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (let ((ecc-review-menu--state (ecc-review-menu-make-state nil directory))
          (seen nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &optional _pred _match _initial _history default
                                 &rest _)
                   (setq seen (list prompt (all-completions "" table) default))
                   default)))
        (should (equal (ecc-review-menu--read-other "develop") "feature"))
        (should (equal (car seen)
                       "Changes on, the after side (default feature with its working tree): "))
        ;; Local branches before the remote ones, read once with the menu.
        (should (equal (cadr seen) '("develop" "feature" "main")))
        (should (equal (ecc-review-menu--read-base) "develop"))
        (should (equal (car seen) "Base, the before side (default develop): "))))))

(defun ecc-review-menu-test--stale-develop (directory)
  "Make the develop of DIRECTORY two commits behind an origin/develop it tracks.
The repository is `ecc-review-menu-test--repo''s, and feature is cut
again from origin/develop, the way a branch is cut from what was
fetched while the local develop stays where it was."
  (ecc-review-menu-test--repo directory)
  (ecc-review-menu-test--git directory "checkout" "-q" "develop")
  (ecc-review-menu-test--commit directory "d1.txt" "1\n")
  (ecc-review-menu-test--commit directory "d2.txt" "2\n")
  (ecc-review-menu-test--git directory "update-ref" "refs/remotes/origin/develop" "HEAD")
  (ecc-review-menu-test--git directory "reset" "-q" "--hard" "HEAD~2")
  (ecc-review-menu-test--git directory "remote" "add" "origin" "https://example.com/r.git")
  (ecc-review-menu-test--git directory "config" "branch.develop.remote" "origin")
  (ecc-review-menu-test--git directory "config" "branch.develop.merge" "refs/heads/develop")
  (ecc-review-menu-test--git directory "checkout" "-q" "-B" "feature" "origin/develop")
  (ecc-review-menu-test--commit directory "f.txt" "f\n"))

(ert-deftest ecc-review-menu-test-a-stale-base-gives-way-to-its-upstream ()
  "A guessed base behind its upstream, with nothing of its own, is the upstream.
The local develop two commits behind origin/develop would put those two
commits into the review of a feature cut from origin/develop; one with a
commit of its own is somebody's work, and stays."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--stale-develop directory)
    (let ((root (ecc-review-git-root directory)))
      (should (equal (ecc-review-menu-guess-base root)
                     (cons "origin/develop"
                           (ecc-review-menu-test--id directory "origin/develop"))))
      ;; And b counts the files of the feature alone.
      (let ((state (ecc-review-menu-make-state nil directory)))
        (should (equal (alist-get 'branch (plist-get state :counts)) 1)))
      ;; Kept while develop has a commit of its own: diverged, not stale.
      (ecc-review-menu-test--git directory "checkout" "-q" "develop")
      (ecc-review-menu-test--commit directory "own.txt" "own\n")
      (ecc-review-menu-test--git directory "checkout" "-q" "feature")
      (should (equal (car (ecc-review-menu-guess-base root)) "develop")))))

(ert-deftest ecc-review-menu-test-an-upstream-holding-head-is-no-base ()
  "The upstream of a stale base is not taken when it already holds HEAD.
feature, cut from develop, was merged into origin/develop, and the local
develop is behind: origin/develop holds feature, and b would show the
working tree alone.  The local develop stays the base."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (let ((root (ecc-review-git-root directory)))
        ;; origin/develop: develop, then feature merged in, then more.
        (ecc-review-menu-test--git directory "checkout" "-q" "-b" "merged" "develop")
        (ecc-review-menu-test--git directory "merge" "-q" "--no-ff" "-m" "merge" "feature")
        (ecc-review-menu-test--commit directory "after.txt" "after\n")
        (ecc-review-menu-test--git directory "update-ref" "refs/remotes/origin/develop" "HEAD")
        (ecc-review-menu-test--git directory "remote" "add" "origin" "https://example.com/r.git")
        (ecc-review-menu-test--git directory "config" "branch.develop.remote" "origin")
        (ecc-review-menu-test--git directory "config" "branch.develop.merge" "refs/heads/develop")
        (ecc-review-menu-test--git directory "checkout" "-q" "feature")
        (should (equal (ecc-review-menu-guess-base root)
                       (cons "develop" (ecc-review-menu-test--id directory two))))
        (let ((state (ecc-review-menu-make-state nil directory)))
          (should (equal (alist-get 'branch (plist-get state :counts)) 1)))))))

(ert-deftest ecc-review-menu-test-branches-say-how-far-they-are-behind ()
  "Each branch is offered with how far it is from its upstream, beside it.
An annotation: what is typed and returned is the name of the branch."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--stale-develop directory)
    (let ((ecc-review-menu--state (ecc-review-menu-make-state nil directory))
          (seen nil))
      (should (equal (ecc-review-menu--distance "develop") "  (2 behind origin/develop)"))
      ;; Cut from origin/develop, feature tracks it, a commit ahead.
      (should (equal (ecc-review-menu--distance "feature") "  (1 ahead of origin/develop)"))
      (should-not (ecc-review-menu--distance "main"))
      (should-not (ecc-review-menu--distance "origin/develop"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq seen (list (all-completions "" table)
                                    (completion-metadata-get
                                     (completion-metadata "" table nil)
                                     'annotation-function)))
                   "develop")))
        (should (equal (ecc-review-menu--read-base) "develop"))
        (should (equal (car seen) '("develop" "feature" "main" "origin/develop")))
        (should (equal (funcall (cadr seen) "develop") "  (2 behind origin/develop)"))
        (ecc-review-menu--read-other "develop")
        (should (equal (funcall (cadr seen) "develop") "  (2 behind origin/develop)")))
      ;; Ahead, both, and an upstream that has gone.
      (should (equal (ecc-review-menu--distance-string '("origin/a" 3 0))
                     "  (3 ahead of origin/a)"))
      (should (equal (ecc-review-menu--distance-string '("origin/b" 1 2))
                     "  (1 ahead, 2 behind origin/b)"))
      (should (equal (ecc-review-menu--distance-string '("origin/c" 0 gone))
                     "  (origin/c is gone)"))
      (should-not (ecc-review-menu--distance-string '("origin/d" 0 0))))))

(ert-deftest ecc-review-menu-test-distances-are-asked-for-when-shown ()
  "Opening the menu asks git nothing of how far branches are from their
upstreams; the first branch shown asks once for all of them, and the
rest ask nothing."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--stale-develop directory)
    (let ((asked nil))
      (cl-letf* ((git (symbol-function 'ecc-review--git))
                 ((symbol-function 'ecc-review--git)
                  (lambda (root &rest args)
                    (push args asked)
                    (apply git root args))))
        (let ((ecc-review-menu--state (ecc-review-menu-make-state nil directory nil t)))
          ;; The guess asks of the winner alone: develop against origin/develop.
          (should-not (seq-find (lambda (args) (string-search "track" (format "%S" args)))
                                asked))
          (should-not (seq-find (lambda (args) (member "origin/develop...feature" args))
                                asked))
          ;; The first annotation reads every branch with one call;
          ;; the rest ask nothing.
          (setq asked nil)
          (should (equal (ecc-review-menu--distance "develop") "  (2 behind origin/develop)"))
          (should (equal (ecc-review-menu--distance "feature") "  (1 ahead of origin/develop)"))
          (should-not (ecc-review-menu--distance "main"))
          (should (= (length asked) 1))
          (should (equal (caar asked) "for-each-ref"))
          (setq asked nil)
          (should (equal (ecc-review-menu--distance "develop") "  (2 behind origin/develop)"))
          (should-not asked))))))

;;;; Counts

(ert-deftest ecc-review-menu-test-status ()
  "One git status gives what is staged, not staged and not tracked."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-review-menu-test--write directory "a.txt" "unstaged\n")
    (ecc-review-menu-test--git directory "mv" "b.txt" "renamed.txt")
    (make-directory (concat directory "new"))
    (ecc-review-menu-test--write directory "new/one.txt" "1\n")
    (ecc-review-menu-test--write directory "new/two.txt" "2\n")
    (let ((status (ecc-review-menu--status (ecc-review-git-root directory))))
      ;; A rename is one path, the new one; the old one is not a file.
      (should (equal (plist-get status :staged) '("renamed.txt")))
      (should (equal (plist-get status :unstaged) '("a.txt")))
      ;; Each file of an untracked directory, not the directory.
      (should (equal (sort (plist-get status :untracked) #'string<)
                     '("new/one.txt" "new/two.txt"))))))

(ert-deftest ecc-review-menu-test-counts ()
  "Each choice counts the files its review shows, untracked ones included."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (ecc-test-with-fake-session session
        (setf (ecc-session-project-root session) directory)
        (ecc-review-ensure-baseline session)
        (ecc-review-menu-test--write directory "a.txt" "unstaged\n")
        (ecc-review-menu-test--write directory "z.txt" "staged\n")
        (ecc-review-menu-test--git directory "add" "z.txt")
        (ecc-review-menu-test--write directory "u.txt" "untracked\n")
        (let* ((root (ecc-review-git-root directory))
               (counts (ecc-review-menu-counts session root two)))
          (should (equal (alist-get 'worktree counts) 3))
          (should (equal (alist-get 'unstaged counts) 2))
          (should (equal (alist-get 'staged counts) 1))
          ;; c.txt, committed on feature, and the three above.
          (should (equal (alist-get 'branch counts) 4))
          ;; What changed since the session started: the three.
          (should (equal (alist-get 'session counts) 3))
          ;; The snapshot can be left out; the rest is still counted.
          (let ((ecc-review-menu-count-session-changes nil))
            (let ((counts (ecc-review-menu-counts session root two)))
              (should-not (alist-get 'session counts))
              (should (equal (alist-get 'staged counts) 1))))
          ;; No base, no count for b.
          (should-not (alist-get 'branch (ecc-review-menu-counts session root nil))))))))

(ert-deftest ecc-review-menu-test-branch-count-is-what-b-shows ()
  "A file a commit changed and the working tree put back is not counted."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (let ((root (ecc-review-git-root directory))
            (fork (ecc-review-menu-test--id directory two)))
        ;; c.txt came with feature's commit; the working tree drops it
        ;; again, so the fork and the working tree agree about it.
        (delete-file (concat directory "c.txt"))
        (ecc-review-menu-test--write directory "u.txt" "untracked\n")
        (should (= (ecc-review-menu--branch-count root fork (ecc-review-menu--status root))
                   1))
        (ecc-test-with-fake-session session
          (let ((text (plist-get (ecc-review--worktree-content session fork root nil) :text)))
            (should (string-search "b/u.txt" text))
            (should-not (string-search "c.txt" text))))))))

(ert-deftest ecc-review-menu-test-a-failed-count-is-not-nothing ()
  "A count that failed shows ?, says why, and never passes for none."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      ;; Nothing changed: a real 0, which is "nothing".
      (should (equal (ecc-review-menu--session-count session) 0))
      (cl-letf (((symbol-function 'ecc-review-snapshot) (lambda (&rest _) nil)))
        (let ((ecc-review-menu--state (ecc-review-menu-make-state session directory))
              (said nil))
          (should (stringp (alist-get 'session (plist-get ecc-review-menu--state :counts))))
          (should (string-match-p "  \\?\\'" (ecc-review-menu--describe 'session)))
          (should-not (string-search "nothing" (ecc-review-menu--describe 'session)))
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest args) (setq said (apply #'format format args)))))
            (ecc-review-menu--say-why))
          (should (string-search "working tree could not be read" said)))))))

(ert-deftest ecc-review-menu-test-count-setting-is-a-defcustom ()
  "Whether D is counted is a judgement about cost, so a setting."
  (should (custom-variable-p 'ecc-review-menu-count-session-changes)))

(ert-deftest ecc-review-menu-test-describe ()
  "A line says what it compares and how many files, and marks the last choice."
  (let ((ecc-review-menu--state '(:root "/r/" :base "develop"
                                  :counts ((worktree . 5) (staged . 0) (session . 1))))
        (ecc-review-menu--last 'staged))
    (should (string-match-p "\\`uncommitted (vs HEAD) +5 files\\'"
                            (ecc-review-menu--describe 'worktree)))
    (should (string-match-p "1 file\\'" (ecc-review-menu--describe 'session)))
    (should (string-search "this branch vs develop" (ecc-review-menu--describe 'branch)))
    (should (equal (ecc-review-menu--describe 'commit) "a commit…"))
    (let ((staged (ecc-review-menu--describe 'staged)))
      (should (string-match-p "nothing  (last)\\'" staged))
      (should (get-text-property 0 'ecc-review-menu-last staged)))
    (should-not (get-text-property 0 'ecc-review-menu-last
                                   (ecc-review-menu--describe 'worktree)))))

;;;; What the suffixes open

(ert-deftest ecc-review-menu-test-suffixes-open-the-review ()
  "Each choice opens the review its range names, in its session and directory."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two three) (ecc-review-menu-test--repo directory)
      (ecc-test-with-fake-session session
        (setf (ecc-session-project-root session) directory)
        (ecc-review-menu-test--capturing calls
          (let ((ecc-review-menu--state (ecc-review-menu-make-state session directory)))
            (should (equal (plist-get ecc-review-menu--state :base) "develop"))
            (ecc-review-menu-session-changes nil)
            (should (equal (pop calls) (list 'ecc-review 'diff session nil)))
            (should (eq ecc-review-menu--last 'session))
            (ecc-review-menu-uncommitted nil)
            (should (equal (pop calls)
                           (list 'ecc-review-worktree 'diff session "HEAD" directory nil)))
            (should (eq ecc-review-menu--last 'worktree))
            (ecc-review-menu-unstaged nil)
            (should (equal (nth 3 (pop calls)) ""))
            (ecc-review-menu-staged nil)
            (should (eq (nth 3 (pop calls)) 'staged))
            ;; b RET RET.
            (ecc-review-menu-branch "develop" "feature" nil)
            (should (equal (nth 3 (pop calls)) (ecc-review-menu-test--id directory two)))
            (ecc-review-menu-branch "main" "develop" nil)
            (should (equal (nth 3 (pop calls)) "main...develop"))
            ;; c X RET.
            (ecc-review-menu-commit three nil nil)
            (should (equal (nth 3 (pop calls))
                           (concat (ecc-review-menu-test--id directory three) "^!")))
            (should (eq ecc-review-menu--last 'commit))
            (ecc-review-menu-range "main..develop" nil)
            (should (equal (nth 3 (pop calls)) "main..develop"))
            (should (eq ecc-review-menu--last 'range))))))))

(ert-deftest ecc-review-menu-test-options ()
  "-e opens this one review the other way, and -f asks for the files."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-review-menu-test--write directory "a.txt" "changed\n")
    (ecc-review-menu-test--write directory "c.txt" "changed\n")
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (ecc-review-menu-test--capturing calls
        (let ((ecc-review-menu--state (ecc-review-menu-make-state session directory))
              (offered nil))
          (ecc-review-menu-uncommitted '("--ediff"))
          (should (eq (nth 1 (pop calls)) 'ediff))
          ;; The setting itself is left alone.
          (should (eq ecc-review-style 'diff))
          (let ((ecc-review-style 'ediff))
            (ecc-review-menu-staged '("--diff"))
            (should (eq (nth 1 (pop calls)) 'diff)))
          (cl-letf (((symbol-function 'completing-read-multiple)
                     (lambda (_prompt candidates &rest _)
                       (setq offered candidates)
                       '("c.txt"))))
            (ecc-review-menu-uncommitted '("--files"))
            ;; The files of that review are offered, and handed on absolute.
            (should (equal (sort (copy-sequence offered) #'string<) '("a.txt" "c.txt")))
            (should (equal (nth 5 (pop calls)) (list (concat directory "c.txt"))))
            (ecc-review-menu-session-changes '("--files"))
            (should (equal (nth 3 (pop calls)) (list (concat directory "c.txt"))))))))))

;;;; Which session

(ert-deftest ecc-review-menu-test-s-turns-the-menu-to-another-project ()
  "S to a session of another repository reviews that repository, there.
Two sessions in two repositories, so that the menu cannot review one
and send the comments to the other."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--with-directory elsewhere
      (ecc-review-menu-test--repo directory)
      (ecc-review-menu-test--repo elsewhere)
      (ecc-review-menu-test--git elsewhere "checkout" "-q" "develop")
      (ecc-test-with-fake-session first
        (setf (ecc-session-project-root first) directory)
        (let ((second (ecc-model-create-session :name "second" :project-root elsewhere))
              (offered nil))
          (unwind-protect
              (ecc-review-menu-test--capturing calls
                (let ((ecc-review-menu--state (ecc-review-menu-make-state first directory)))
                  ;; The sessions of the menu's project are offered first.
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt table &rest _)
                               (setq offered (all-completions "" table))
                               (car (last offered)))))
                    (ecc-review-menu-set-session (ecc-review-menu--read-session)))
                  ;; After the choice of a new session.
                  (should (equal (car offered) "+ new session"))
                  (should (string-prefix-p "test" (cadr offered)))
                  ;; The whole menu is the other project's now.
                  (should (eq (plist-get ecc-review-menu--state :session) second))
                  (should (equal (plist-get ecc-review-menu--state :directory) elsewhere))
                  (should (equal (plist-get ecc-review-menu--state :root) elsewhere))
                  (should (equal (plist-get ecc-review-menu--state :branch) "develop"))
                  (should (equal (plist-get ecc-review-menu--state :base) "main"))
                  (should (string-search "second" (ecc-review-menu--header)))
                  (should (string-search (abbreviate-file-name elsewhere)
                                         (ecc-review-menu--header)))
                  (ecc-review-menu-uncommitted nil)
                  (should (equal (cddr (pop calls)) (list second "HEAD" elsewhere nil)))
                  (ecc-review-menu-session-changes nil)
                  (should (eq (nth 2 (pop calls)) second))))
            (ecc-test-cleanup-session second)))))))

(ert-deftest ecc-review-menu-test-s-within-a-project-reads-little ()
  "S to another session of the same project counts that session again, alone."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-test-with-fake-session first
      (setf (ecc-session-project-root first) directory)
      (let ((second (ecc-model-create-session :name "second" :project-root directory))
            (asked nil))
        (unwind-protect
            (let ((ecc-review-menu--state (ecc-review-menu-make-state first directory)))
              (cl-letf (((symbol-function 'ecc-review-menu--status)
                         (lambda (&rest _) (push 'status asked) nil))
                        ((symbol-function 'ecc-review-menu--refs)
                         (lambda (&rest _) (push 'refs asked) nil)))
                (ecc-review-menu-set-session second))
              (should-not asked)
              (should (eq (plist-get ecc-review-menu--state :session) second))
              (should (equal (plist-get ecc-review-menu--state :base) "develop")))
          (ecc-test-cleanup-session second))))))

(ert-deftest ecc-review-menu-test-s-starts-a-new-session ()
  "S offers a new session first, which starts in the menu's project and gets the comments.
The project has a session already, so the new one is asked a name, as
\\[ecc-start] asks it; the window that was selected stays selected."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-test-with-fake-session first
      (setf (ecc-session-project-root first) directory)
      (let ((started nil)
            (offered nil)
            (selected (selected-window)))
        (unwind-protect
            (let ((ecc-review-menu--state (ecc-review-menu-make-state first directory)))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt table &rest _)
                           (setq offered (all-completions "" table))
                           (car offered)))
                        ((symbol-function 'read-string)
                         (lambda (&rest _) "second"))
                        ((symbol-function 'ecc-start)
                         (lambda (root name)
                           (let ((session (ecc-model-create-session
                                           :name name :project-root root)))
                             (push session started)
                             ;; Where a new session is shown.
                             (select-window (split-window))
                             session))))
                (ecc-review-menu-switch-session (ecc-review-menu--read-session)))
              (should (equal (car offered) "+ new session"))
              (should (= (length started) 1))
              (let ((second (car started)))
                (should (equal (ecc-session-name second) "second"))
                (should (equal (ecc-session-project-root second) directory))
                (should (eq (plist-get ecc-review-menu--state :session) second))
                (should (eq (plist-get ecc-review-menu--state :d-session) second))
                (should (string-search "second gets the comments"
                                       (substring-no-properties (ecc-review-menu--header)))))
              (should (eq (selected-window) selected))
              ;; The first is still there, and still offered.
              (should (memq first (ecc-model-sessions))))
          (delete-other-windows selected)
          (mapc #'ecc-test-cleanup-session started))))))

(ert-deftest ecc-review-menu-test-context ()
  "The git choices review the buffer's project; only D falls back elsewhere.
A buffer in a project with no session, and a session in another: w
reviews this project as G would, and D reviews the session used last."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--with-directory elsewhere
      (ecc-review-menu-test--repo directory)
      (ecc-review-menu-test--repo elsewhere)
      (ecc-test-with-fake-session first
        (setf (ecc-session-project-root first) elsewhere)
        (cl-letf (((symbol-function 'ecc-window-context-project-root)
                   (lambda () directory)))
          (with-temp-buffer
            (should (equal (ecc-review-context) (cons nil directory)))
            (should (equal (ecc-review-menu--context) (list nil first directory)))
            (ecc-review-menu-test--capturing calls
              (let ((ecc-review-menu--state (ecc-review-menu--fresh-state))
                    (offered nil))
                (should (equal (plist-get ecc-review-menu--state :root) directory))
                (should (string-search "D reviews test" (ecc-review-menu--header)))
                (should-not (ecc-review-menu--no-session-p))
                ;; w is G: this project, with a session offered here.
                (cl-letf (((symbol-function 'ecc-review-worktree-session)
                           (lambda (root) (setq offered root) 'started)))
                  (ecc-review-menu-uncommitted nil))
                (should (equal offered directory))
                (should (equal (cddr (pop calls)) (list 'started "HEAD" directory nil)))
                (ecc-review-menu-session-changes nil)
                (should (eq (nth 2 (pop calls)) first))))
            ;; A session of the project is preferred to it, for both.
            (let ((second (ecc-model-create-session :name "second"
                                                    :project-root directory)))
              (unwind-protect
                  (progn
                    (should (equal (ecc-review-context) (cons second directory)))
                    (should (equal (ecc-review-menu--context)
                                   (list second second directory))))
                (ecc-test-cleanup-session second)))))))))

(ert-deftest ecc-review-menu-test-state-goes-with-the-menu ()
  "Once the menu is gone, a suffix reviews where it is run, not the old menu."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--with-directory elsewhere
      (ecc-review-menu-test--repo directory)
      (ecc-review-menu-test--repo elsewhere)
      (ecc-test-with-fake-session first
        (setf (ecc-session-project-root first) directory)
        (let ((second (ecc-model-create-session :name "second" :project-root elsewhere)))
          (unwind-protect
              (ecc-review-menu-test--capturing calls
                ;; The menu opened in the first project, then quit.
                (setq ecc-review-menu--state (ecc-review-menu-make-state first directory))
                (unwind-protect
                    (progn
                      (let ((transient--prefix nil))
                        (run-hooks 'transient-exit-hook)
                        (ecc-review-menu--forget-state))
                      (should-not ecc-review-menu--state)
                      ;; From the other project, the other project.
                      (cl-letf (((symbol-function 'ecc-window-context-project-root)
                                 (lambda () elsewhere)))
                        (with-temp-buffer
                          (ecc-review-menu-uncommitted nil)))
                      (should (equal (cddr (pop calls)) (list second "HEAD" elsewhere nil)))
                      ;; Nothing was kept of it either.
                      (should-not ecc-review-menu--state))
                  (setq ecc-review-menu--state nil)))
            (ecc-test-cleanup-session second)))))))

(ert-deftest ecc-review-menu-test-a-suspended-menu-keeps-its-state ()
  "C-h or a switch of frame suspends the menu; its state and S's choice stay.
Transient resumes it without running `ecc-review-menu', so a state
dropped at the suspend would leave every choice off."
  (let ((ecc-review-menu--state '(:session chosen :directory "/p/"))
        (transient--prefix nil)
        (transient--stack (list (list 'ecc-review-menu nil nil))))
    (ecc-review-menu--forget-state)
    (should (eq (plist-get ecc-review-menu--state :session) 'chosen))
    ;; Gone from the stack, it is gone.
    (setq transient--stack nil)
    (ecc-review-menu--forget-state)
    (should-not ecc-review-menu--state)))

(ert-deftest ecc-review-menu-test-s-needs-an-open-menu ()
  "S with no menu open changes nothing and keeps no state."
  (ecc-test-with-fake-session session
    (let ((ecc-review-menu--state nil)
          (said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format format args)))))
        (should-not (ecc-review-menu-set-session session)))
      (should-not ecc-review-menu--state)
      (should (string-search "No review menu is open" said)))))

(ert-deftest ecc-review-menu-test-a-choice-without-the-menu-reads-little ()
  "Run with M-x, a choice makes one light state: no counts, no snapshot."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (let ((ecc-review-menu--state nil)
            (made nil)
            (counted nil))
        (ecc-review-menu-test--capturing calls
          (cl-letf (((symbol-function 'ecc-window-context-project-root)
                     (lambda () directory))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt _table &optional _pred _match _initial _history default
                                      &rest _)
                       default)))
            (advice-add 'ecc-review-menu-make-state :before
                        (lambda (&rest args) (push args made)) '((name . made)))
            (advice-add 'ecc-review-menu-counts :before
                        (lambda (&rest _) (setq counted t)) '((name . counted)))
            (unwind-protect
                (with-temp-buffer
                  (call-interactively #'ecc-review-menu-branch))
              (advice-remove 'ecc-review-menu-make-state 'made)
              (advice-remove 'ecc-review-menu-counts 'counted)))
          (should (= (length made) 1))
          (should (nth 3 (car made)))
          (should-not counted)
          (should (equal (nth 3 (pop calls))
                         (ecc-review-menu-test--git directory "merge-base" "develop" "HEAD")))
          (should-not ecc-review-menu--state))))))

(ert-deftest ecc-review-menu-test-head-tree ()
  "The tree of HEAD, or the empty tree before the first commit."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--git directory "init" "-q")
    (let ((root (ecc-review-git-root directory)))
      (should (equal (ecc-review--head-tree root) (ecc-review--empty-tree root)))
      (ecc-review-menu-test--git directory "config" "user.email" "t@example.com")
      (ecc-review-menu-test--git directory "config" "user.name" "t")
      (ecc-review-menu-test--commit directory "a.txt" "a\n")
      (should (equal (ecc-review--head-tree root)
                     (ecc-review-menu-test--git directory "rev-parse" "HEAD^{tree}"))))))

(ert-deftest ecc-review-menu-test-outside-git ()
  "Outside git only D works, and the heading says why."
  (ecc-review-menu-test--with-directory directory
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (let ((ecc-review-menu--state (ecc-review-menu-make-state session directory)))
        (should-not (plist-get ecc-review-menu--state :root))
        (should (ecc-review-menu--outside-git-p))
        (should-not (ecc-review-menu--no-session-p))
        (should (string-search "not a git repository"
                               (ecc-review-menu--compare-heading)))
        ;; Only the session's own changes are counted.
        (should (equal (mapcar #'car (plist-get ecc-review-menu--state :counts))
                       '(session)))
        (should-error (ecc-review-menu--root) :type 'user-error)
        (dolist (command '(ecc-review-menu-uncommitted ecc-review-menu-unstaged
                           ecc-review-menu-staged ecc-review-menu-branch
                           ecc-review-menu-commit ecc-review-menu-range))
          (let ((inapt (oref (get command 'transient--suffix) inapt-if)))
            (should (eq inapt #'ecc-review-menu--outside-git-p))))
        (should (eq (oref (get 'ecc-review-menu-session-changes 'transient--suffix)
                          inapt-if)
                    #'ecc-review-menu--no-session-p)))
      ;; No session: D has nothing to show.
      (let ((ecc-review-menu--state (ecc-review-menu-make-state nil directory)))
        (should (ecc-review-menu--no-session-p))
        (should (string-search "no session yet" (ecc-review-menu--header)))))))

(ert-deftest ecc-review-menu-test-review-open-speaks-the-menu ()
  "review_open's description is the variable, and names every choice."
  (let ((ecc-mcp-tools (make-hash-table :test #'equal))
        (ecc-mcp--instructions nil))
    (ecc-review-agent-register-tools)
    (should (equal (alist-get 'description
                              (ecc-mcp-tool-object (ecc-mcp-tool "review_open")))
                   ecc-review-agent-open-description)))
  (dolist (words '("staged true" "range \"HEAD\"" "range \"\"" "git merge-base"
                   "\"BASE...BRANCH\"" "\"X^!\"" "\"X^..Y\"" "paths"))
    (should (string-search words ecc-review-agent-open-description))))

(provide 'ecc-review-menu-test)

;;; ecc-review-menu-test.el ends here
