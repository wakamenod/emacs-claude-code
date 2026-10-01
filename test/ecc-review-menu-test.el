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

;;;; What b and c compare

(ert-deftest ecc-review-menu-test-guess-base ()
  "The base is the candidate HEAD has the fewest commits beyond."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (let ((root (ecc-review-git-root directory)))
      ;; feature is one commit beyond develop and two beyond main.
      (should (equal (ecc-review-menu-guess-base root) "develop"))
      ;; The current branch is never its own base.
      (ecc-review-menu-test--git directory "checkout" "-q" "develop")
      (should (equal (ecc-review-menu-guess-base root) "main"))
      (ecc-review-menu-test--git directory "checkout" "-q" "feature")
      ;; Where origin/HEAD points is a candidate too.
      (ecc-review-menu-test--git directory "update-ref" "refs/remotes/origin/trunk" "HEAD~1")
      (ecc-review-menu-test--git directory "symbolic-ref" "refs/remotes/origin/HEAD"
                                 "refs/remotes/origin/trunk")
      (let ((ecc-review-menu-base-candidates '("main")))
        (should (equal (ecc-review-menu-guess-base root) "origin/trunk")))
      ;; A candidate that does not exist is passed over, and none is nil.
      (let ((ecc-review-menu-base-candidates '("nope" "main")))
        (ecc-review-menu-test--git directory "symbolic-ref" "--delete"
                                   "refs/remotes/origin/HEAD")
        (should (equal (ecc-review-menu-guess-base root) "main")))
      (let ((ecc-review-menu-base-candidates '("nope")))
        (should-not (ecc-review-menu-guess-base root))))))

(ert-deftest ecc-review-menu-test-branch-range ()
  "b against the current branch is the fork point and the working tree."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (_one two _three) (ecc-review-menu-test--repo directory)
      (let ((root (ecc-review-git-root directory)))
        ;; Every way of saying the current branch is the same answer.
        (dolist (other '(nil "" "HEAD" "feature"))
          (should (equal (ecc-review-menu-branch-range root "develop" other) two)))
        ;; That range reads the working tree, untracked files and all.
        (should (ecc-review--range-includes-worktree-p root two))
        (ecc-review-menu-test--write directory "new.txt" "new\n")
        (ecc-review-menu-test--write directory "c.txt" "changed\n")
        (ecc-test-with-fake-session session
          (let ((text (plist-get (ecc-review--worktree-content session two root nil)
                                 :text)))
            (should (string-search "b/c.txt" text))
            (should (string-search "b/new.txt" text))
            ;; develop's own commit is not part of it.
            (should-not (string-search "b/b.txt" text))))
        ;; Another branch is what a pull request of it shows.
        (should (equal (ecc-review-menu-branch-range root "main" "develop")
                       "main...develop"))
        (should-not (ecc-review--range-includes-worktree-p root "main...develop"))
        ;; An option is not a branch.
        (should-error (ecc-review-menu-branch-range root "--output=x") :type 'user-error)
        (should-error (ecc-review-menu-branch-range root "main" "-x") :type 'user-error)
        (should-error (ecc-review-menu-branch-range root "") :type 'user-error)))))

(ert-deftest ecc-review-menu-test-commit-range ()
  "c is one commit, or a span from the older through the newer."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (seq-let (one two three) (ecc-review-menu-test--repo directory)
      (let* ((root (ecc-review-git-root directory))
             (empty (ecc-review--empty-tree root)))
        (should (equal (ecc-review-menu-commit-range root two) (concat two "^!")))
        (should (equal (ecc-review-menu-commit-range root two "") (concat two "^!")))
        (should (equal (ecc-review-menu-commit-range root two two) (concat two "^!")))
        (should (equal (ecc-review-menu-commit-range root two three)
                       (format "%s^..%s" two three)))
        ;; Picked newest first, the span is the same.
        (should (equal (ecc-review-menu-commit-range root three two)
                       (format "%s^..%s" two three)))
        ;; The first commit has no parent: the empty tree stands in.
        (let ((alone (ecc-review-menu-commit-range root one)))
          (should (equal alone (format "%s..%s" empty one)))
          ;; Which compares commits, not the working tree, and shows
          ;; that commit's file and nothing later.
          (should-not (ecc-review--range-includes-worktree-p root alone))
          (let ((names (ecc-review-menu-test--git directory "diff" "--name-only" alone)))
            (should (equal names "a.txt"))))
        (should (equal (ecc-review-menu-commit-range root one two)
                       (format "%s..%s" empty two)))
        (should-error (ecc-review-menu-commit-range root "no-such-commit")
                      :type 'user-error)))))

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
    (let ((root (ecc-review-git-root directory))
          (seen nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &optional _pred _match _initial _history default
                                 &rest _)
                   (setq seen (list prompt (all-completions "" table) default))
                   default)))
        (should (equal (ecc-review-menu--read-other root "develop") "feature"))
        (should (string-search "feature with its working tree" (car seen)))
        ;; Local branches before the remote ones.
        (should (equal (cadr seen) '("develop" "feature" "main")))))))

;;;; Counts

(ert-deftest ecc-review-menu-test-shortstat ()
  "The number of files is read out of git's summary line."
  (should (= (ecc-review-menu--shortstat-files
              " 3 files changed, 10 insertions(+), 2 deletions(-)\n")
             3))
  (should (= (ecc-review-menu--shortstat-files " 1 file changed, 1 insertion(+)\n") 1))
  (should (= (ecc-review-menu--shortstat-files "") 0)))

(ert-deftest ecc-review-menu-test-counts ()
  "Each choice counts the files its review shows, untracked ones included."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--repo directory)
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (ecc-review-ensure-baseline session)
      (ecc-review-menu-test--write directory "a.txt" "unstaged\n")
      (ecc-review-menu-test--write directory "z.txt" "staged\n")
      (ecc-review-menu-test--git directory "add" "z.txt")
      (ecc-review-menu-test--write directory "u.txt" "untracked\n")
      (let* ((root (ecc-review-git-root directory))
             (counts (ecc-review-menu-counts session root "develop")))
        (should (equal (alist-get 'worktree counts) 3))
        (should (equal (alist-get 'unstaged counts) 2))
        (should (equal (alist-get 'staged counts) 1))
        ;; c.txt, committed on feature, and the three above.
        (should (equal (alist-get 'branch counts) 4))
        ;; What changed since the session started: the three.
        (should (equal (alist-get 'session counts) 3))
        ;; The snapshot can be left out; the rest is still counted.
        (let ((ecc-review-menu-count-session-changes nil))
          (let ((counts (ecc-review-menu-counts session root "develop")))
            (should-not (alist-get 'session counts))
            (should (equal (alist-get 'staged counts) 1))))
        ;; No base, no count for b.
        (should-not (alist-get 'branch (ecc-review-menu-counts session root nil)))))))

(ert-deftest ecc-review-menu-test-describe ()
  "A line says what it compares and how many files, and marks the last choice."
  (let ((ecc-review-menu--state '(:base "develop"
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
                                   (ecc-review-menu--describe 'worktree))))
  (let ((ecc-review-menu--state '(:counts nil)))
    (should (string-search "this branch vs another" (ecc-review-menu--describe 'branch)))))

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
            (should (equal (nth 3 (pop calls)) two))
            (ecc-review-menu-branch "main" "develop" nil)
            (should (equal (nth 3 (pop calls)) "main...develop"))
            ;; c X RET.
            (ecc-review-menu-commit three nil nil)
            (should (equal (nth 3 (pop calls)) (concat three "^!")))
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

(ert-deftest ecc-review-menu-test-sessions ()
  "The comments go to the session of the buffer, and S sends them elsewhere.
Two sessions, so that the one chosen is told apart from the one at hand."
  (skip-unless (executable-find "git"))
  (ecc-review-menu-test--with-directory directory
    (ecc-review-menu-test--with-directory elsewhere
      (ecc-review-menu-test--repo directory)
      (ecc-test-with-fake-session first
        (setf (ecc-session-project-root first) directory)
        (let ((second (ecc-model-create-session :name "second" :project-root elsewhere)))
          (unwind-protect
              (progn
                ;; From a file of the project, the session of the project.
                (with-temp-buffer
                  (setq default-directory directory)
                  (setq buffer-file-name (concat directory "a.txt"))
                  (cl-letf (((symbol-function 'ecc-window-context-project-root)
                             (lambda () directory)))
                    (let ((context (ecc-review-menu--context)))
                      (should (eq (car context) first))
                      (should (equal (cdr context) directory))))
                  (setq buffer-file-name nil))
                (ecc-review-menu-test--capturing calls
                  (let ((ecc-review-menu--state (ecc-review-menu-make-state first directory))
                        (offered nil))
                    ;; The sessions of the project are offered first.
                    (cl-letf (((symbol-function 'completing-read)
                               (lambda (_prompt table &rest _)
                                 (setq offered (all-completions "" table))
                                 (car (last offered)))))
                      (ecc-review-menu-set-session (ecc-review-menu--read-session)))
                    (should (string-prefix-p "test" (car offered)))
                    (should (eq (plist-get ecc-review-menu--state :session) second))
                    (should (string-search "second" (ecc-review-menu--header)))
                    ;; The directory reviewed stays; the comments move.
                    (ecc-review-menu-uncommitted nil)
                    (should (equal (cdr (cdr (pop calls)))
                                   (list second "HEAD" directory nil)))
                    (ecc-review-menu-session-changes nil)
                    (should (eq (nth 2 (pop calls)) second)))))
            (ecc-test-cleanup-session second)))))))

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
