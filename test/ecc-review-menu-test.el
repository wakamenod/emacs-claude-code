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
        ;; The current branch is never its own base.
        (ecc-review-menu-test--git directory "checkout" "-q" "develop")
        (should (equal (car (ecc-review-menu-guess-base root)) "main"))
        ;; On main with develop ahead: develop holds HEAD already and would
        ;; compare HEAD with itself, so there is no base at all.
        (ecc-review-menu-test--git directory "checkout" "-q" "main")
        (should-not (ecc-review-menu-guess-base root))
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

(ert-deftest ecc-review-menu-test-no-base-makes-b-inapt ()
  "With no branch to compare with, b cannot be chosen, and its line says why."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-review-menu-test--git directory "checkout" "-q" "main")
    (let ((ecc-review-menu--state (ecc-review-menu-make-state nil directory)))
      (should (plist-get ecc-review-menu--state :root))
      (should (ecc-review-menu--no-base-p))
      (should (string-search "no branch to compare with"
                             (ecc-review-menu--describe 'branch)))
      (should (eq (oref (get 'ecc-review-menu-branch 'transient--suffix) inapt-if)
                  #'ecc-review-menu--no-base-p)))))

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
        (should (equal (ecc-review-menu-commit-range root two)
                       (cons (concat two-id "^!") (concat two " b.txt"))))
        (should (equal (car (ecc-review-menu-commit-range root two "")) (concat two-id "^!")))
        (should (equal (car (ecc-review-menu-commit-range root two two-id))
                       (concat two-id "^!")))
        (should (equal (ecc-review-menu-commit-range root two three)
                       (cons (format "%s^..%s" two-id three-id)
                             (format "%s to %s" two three))))
        ;; Picked newest first, the span is the same.
        (should (equal (car (ecc-review-menu-commit-range root three two))
                       (format "%s^..%s" two-id three-id)))
        ;; The first commit has no parent: the empty tree stands in.
        (let ((alone (car (ecc-review-menu-commit-range root one))))
          (should (equal alone (format "%s..%s" empty one-id)))
          ;; Which compares commits, not the working tree, and shows
          ;; that commit's file and nothing later.
          (should-not (ecc-review--range-includes-worktree-p root alone))
          (should (equal (ecc-review-menu-test--git directory "diff" "--name-only" alone)
                         "a.txt")))
        (should (equal (car (ecc-review-menu-commit-range root one two))
                       (format "%s..%s" empty two-id)))
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
               (buffer (let ((ecc-review-range-label (cdr range)))
                         (ecc-review-worktree-buffer session (car range) directory))))
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
        (should (string-search "feature with its working tree" (car seen)))
        ;; Local branches before the remote ones, read once with the menu.
        (should (equal (cadr seen) '("develop" "feature" "main")))
        (should (equal (ecc-review-menu--read-base) "develop"))))))

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
                  (should (string-prefix-p "test" (car offered)))
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

(ert-deftest ecc-review-menu-test-context ()
  "The menu is about the buffer's session, else the project's, else the last one."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--with-directory elsewhere
      (ecc-review-menu-test--repo directory)
      (ecc-test-with-fake-session first
        (setf (ecc-session-project-root first) elsewhere)
        (cl-letf (((symbol-function 'ecc-window-context-project-root)
                   (lambda () directory)))
          (with-temp-buffer
            ;; The project has no session: G's rule finds none ...
            (should (equal (ecc-review-context) (cons nil directory)))
            ;; ... and the menu takes the session used last, with its project.
            (should (equal (ecc-review-menu--context) (cons first elsewhere)))
            (let ((ecc-review-menu--state (ecc-review-menu-make-state first elsewhere)))
              (should (string-search "test" (ecc-review-menu--header)))
              (should-not (ecc-review-menu--no-session-p)))
            ;; A session of the project is preferred to it.
            (let ((second (ecc-model-create-session :name "second"
                                                    :project-root directory)))
              (unwind-protect
                  (progn
                    (should (equal (ecc-review-context) (cons second directory)))
                    (should (equal (ecc-review-menu--context) (cons second directory))))
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

(ert-deftest ecc-review-menu-test-outside-git ()
  "Outside git only D works, and the heading says why."
  (ecc-review-menu-test--with-directory directory
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (let ((ecc-review-menu--state (ecc-review-menu-make-state session directory)))
        (should-not (plist-get ecc-review-menu--state :root))
        (should (ecc-review-menu--outside-git-p))
        (should (ecc-review-menu--no-base-p))
        (should-not (ecc-review-menu--no-session-p))
        (should (string-search "not a git repository"
                               (ecc-review-menu--compare-heading)))
        ;; Only the session's own changes are counted.
        (should (equal (mapcar #'car (plist-get ecc-review-menu--state :counts))
                       '(session)))
        (should-error (ecc-review-menu--root) :type 'user-error)
        (dolist (command '(ecc-review-menu-uncommitted ecc-review-menu-unstaged
                           ecc-review-menu-staged ecc-review-menu-commit
                           ecc-review-menu-range))
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
