;;; ecc-review-pr-test.el --- Tests for ecc-review-pr  -*- lexical-binding: t; -*-

;;; Commentary:

;; gh is never run for real here: every test goes through
;; `ecc-review-pr-test--with-gh', which points `ecc-review-gh-executable'
;; at a shell script printing canned JSON, and keeps git from fetching
;; anything but a local path.  A runner of GitHub Actions has a real gh,
;; logged in, and a test that reached it would ask GitHub.  The commits
;; of a pull request are fetched from a bare repository that has a
;; refs/pull/1/head of its own, the way GitHub has one.
;;
;; The second half is about every review whose right side is not the
;; files on disk -- `b' of another branch, `c', `r' of two commits, `p'
;; of somebody else's pull request -- saying so, and the others not.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-review-menu)
(require 'ecc-review-pr)
(require 'ecc-review-agent)
(require 'ecc-review-ediff)

;;;; Helpers

(defmacro ecc-review-pr-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory
                (file-truename (make-temp-file "ecc-review-pr" t)))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-pr-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY and return its output, trimmed.
The test fails when git does."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (string-trim (cdr result))))

(defun ecc-review-pr-test--commit (directory file content)
  "Write CONTENT to FILE under DIRECTORY, commit it and return its full id."
  (with-temp-file (expand-file-name file directory) (insert content))
  (ecc-review-pr-test--git directory "add" file)
  (ecc-review-pr-test--git directory "commit" "-q" "-m" file)
  (ecc-review-pr-test--git directory "rev-parse" "HEAD"))

(defun ecc-review-pr-test--identity (directory)
  "Give the repository DIRECTORY an author to commit as."
  (ecc-review-pr-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-pr-test--git directory "config" "user.name" "t"))

(defvar ecc-review-pr-test--gh-script
  "#!/bin/sh
d='%s'
printf '%%s|%%s\\n' \"$PWD\" \"$*\" >> \"$d/log\"
if [ -f \"$d/fail\" ]; then cat \"$d/fail\" >&2; exit 4; fi
case \"$1 $2\" in
  'pr list') cat \"$d/list.json\" ;;
  'pr view') if [ -f \"$d/view-$3.json\" ]; then cat \"$d/view-$3.json\";
             else echo \"no pull request $3\" >&2; exit 1; fi ;;
  *) echo \"unexpected: $*\" >&2; exit 2 ;;
esac
"
  "The fake gh, formatted with the directory of its answers.
It logs each call as DIRECTORY|ARGS to log, fails with the text of fail
when there is one, and answers `pr list' with list.json and `pr view N'
with view-N.json.")

(defmacro ecc-review-pr-test--with-gh (dir &rest body)
  "Run BODY with a fake gh whose answers are in the directory DIR.
`ecc-review-gh-executable' is the script, so no real gh is run, and
git may fetch only from a local path."
  (declare (indent 1))
  `(ecc-review-pr-test--with-directory ,dir
     (let ((script (expand-file-name "gh" ,dir)))
       (with-temp-file script
         (insert (format ecc-review-pr-test--gh-script (directory-file-name ,dir))))
       (set-file-modes script #o755)
       (let ((ecc-review-gh-executable script)
             (process-environment (cons "GIT_ALLOW_PROTOCOL=file" process-environment)))
         ,@body))))

(defun ecc-review-pr-test--answer (dir file prs)
  "Write PRS, plists of gh's own field names, as the JSON FILE of DIR."
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file (expand-file-name file dir)
      (insert (json-serialize (if (keywordp (car-safe prs)) prs (vconcat prs)))))))

(defun ecc-review-pr-test--log (dir)
  "Return the calls the fake gh in DIR logged, as (DIRECTORY . ARGS) strings."
  (let ((log (expand-file-name "log" dir)))
    (and (file-exists-p log)
         (with-temp-buffer
           (insert-file-contents log)
           (split-string (buffer-string) "\n" t)))))

(defun ecc-review-pr-test--pr (number title head base head-oid base-oid &rest more)
  "Return a pull request as gh prints it, MORE fields taking the place of its own."
  (append more
          (list :number number :title title :headRefName head :baseRefName base
                :headRefOid head-oid :baseRefOid base-oid
                :author (list :login "someone" :name "Some One")
                :isDraft :false :isCrossRepository :false
                :url (format "https://github.com/o/r/pull/%d" number))))

(defun ecc-review-pr-test--upstream (directory)
  "Make the GitHub of the tests under DIRECTORY and a clone of it.
DIRECTORY/o/r.git is bare, with a main of two commits and a
refs/pull/1/head one commit beyond the first, which no branch holds.
DIRECTORY/work is a clone, on main, which has not fetched the pull
request.  Return (WORK BASE-OID HEAD-OID)."
  (let ((bare (expand-file-name "o/r.git" directory))
        (seed (file-name-as-directory (expand-file-name "seed" directory)))
        (work (file-name-as-directory (expand-file-name "work" directory))))
    (make-directory bare t)
    (make-directory seed t)
    (ecc-review-pr-test--git bare "init" "-q" "--bare" "-b" "main")
    (ecc-review-pr-test--git seed "init" "-q" "-b" "main")
    (ecc-review-pr-test--identity seed)
    (ecc-review-pr-test--git seed "remote" "add" "origin" bare)
    (ecc-review-pr-test--commit seed "a.txt" "a\n")
    (ecc-review-pr-test--git seed "push" "-q" "origin" "main")
    (ecc-review-pr-test--git seed "checkout" "-q" "-b" "topic")
    (let ((head (ecc-review-pr-test--commit seed "b.txt" "b\n")))
      (ecc-review-pr-test--git seed "push" "-q" "origin" "HEAD:refs/pull/1/head")
      (ecc-review-pr-test--git seed "checkout" "-q" "main")
      (let ((base (ecc-review-pr-test--commit seed "c.txt" "c\n")))
        (ecc-review-pr-test--git seed "push" "-q" "origin" "main")
                ;; --no-local: a clone of a path copies every object, the
        ;; pull request's too, and there would be nothing to fetch.
        (ecc-review-pr-test--git directory "clone" "-q" "--no-local" bare work)
        (ecc-review-pr-test--identity work)
        (list work base head)))))

(defun ecc-review-pr-test--kill-reviews ()
  "Kill every review buffer a test left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;;; The menu

(ert-deftest ecc-review-pr-test-hidden-without-gh ()
  "p is in the menu only where gh is, and off outside git like b."
  (let ((suffix (get 'ecc-review-menu-pull-request 'transient--suffix)))
    (should (eq (oref suffix if) #'ecc-review-pr-available-p))
    (should (eq (oref suffix inapt-if) #'ecc-review-menu--outside-git-p)))
  (let ((ecc-review-gh-executable "ecc-review-pr-test-no-such-gh"))
    (should-not (ecc-review-pr-available-p)))
  (ecc-review-pr-test--with-gh dir
    (ignore dir)
    (should (ecc-review-pr-available-p)))
  ;; Its line says what it is, with no count beside it.
  (let ((ecc-review-menu--state (list :counts nil))
        (ecc-review-menu--last nil))
    (should (equal (ecc-review-menu--describe 'pr) "a pull request…"))))

;;;; What gh says

(ert-deftest ecc-review-pr-test-parse-and-lines ()
  "gh's JSON is read whatever the title holds, and each is one line."
  (let* ((json (json-serialize
                (vector (ecc-review-pr-test--pr 113 "fix(review):\tタブと\n改行"
                                                "fix/x" "feat/y" "aaa" "bbb")
                        (ecc-review-pr-test--pr 7 "草稿" "draft" "develop" "ccc" "ddd"
                                                :isDraft t :isCrossRepository t))))
         (prs (ecc-review-pr-parse json)))
    (should (= (length prs) 2))
    (should (equal (plist-get (car prs) :title) "fix(review):\tタブと\n改行"))
    (should (equal (plist-get (car prs) :author) "someone"))
    (should-not (plist-get (car prs) :draft))
    (should (plist-get (cadr prs) :draft))
    (should (plist-get (cadr prs) :cross))
    (should (equal (ecc-review-pr-line (car prs))
                   "#113  fix(review): タブと 改行  fix/x → feat/y  @someone"))
    (should (equal (ecc-review-pr-line (cadr prs))
                   "#7  [draft] 草稿  draft → develop  @someone"))
    ;; One object, what `gh pr view' prints, is a list of one.
    (should (equal (mapcar (lambda (pr) (plist-get pr :number))
                           (ecc-review-pr-parse (json-serialize (ecc-review-pr-test--pr
                                                                 5 "t" "h" "b" "1" "2"))))
                   '(5)))
    (should-not (ecc-review-pr-parse "[]"))))

(ert-deftest ecc-review-pr-test-read-offers-in-order-with-default ()
  "The list is gh's, in its order, the PR of the current branch by default.
A number typed that is not listed is asked of gh by itself."
  (ecc-review-pr-test--with-gh dir
    (ecc-review-pr-test--answer
     dir "list.json"
     (list (ecc-review-pr-test--pr 9 "nine" "other" "develop" "1" "2")
           (ecc-review-pr-test--pr 8 "fork main" "main" "develop" "3" "4"
                                   :isCrossRepository t)
           (ecc-review-pr-test--pr 3 "mine" "feature" "develop" "5" "6")))
    (ecc-review-pr-test--answer dir "view-42.json"
                                (ecc-review-pr-test--pr 42 "merged" "old" "develop" "7" "8"))
    (let ((seen nil) (answer nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &optional _pred _match _initial _history default
                                  &rest _)
                   (setq seen (list default (all-completions "" table)))
                   (or answer default))))
        (let ((pr (ecc-review-pr-read dir "feature")))
          (should (equal (plist-get pr :number) 3))
          (should (equal (car seen) "#3  mine  feature → develop  @someone"))
          (should (equal (mapcar (lambda (line) (substring line 0 2)) (cadr seen))
                         '("#9" "#8" "#3"))))
        ;; A fork's main is not the main checked out here.
        (setq answer "9")
        (should (equal (plist-get (ecc-review-pr-read dir "main") :number) 9))
        (should-not (car seen))
        (setq answer "#42")
        (should (equal (plist-get (ecc-review-pr-read dir "main") :title) "merged"))
        (setq answer "nonsense")
        (should-error (ecc-review-pr-read dir "main") :type 'user-error)))
    ;; gh ran in the project, and was never asked to fetch or check out.
    (let ((log (ecc-review-pr-test--log dir)))
      (should (string-prefix-p (concat (directory-file-name dir) "|pr list --json ")
                               (car log)))
      (should (seq-some (lambda (line) (string-search "|pr view 42 --json" line)) log))
      (should-not (seq-some (lambda (line) (string-search "checkout" line)) log)))))

(ert-deftest ecc-review-pr-test-gh-error-is-surfaced ()
  "What gh says on failing is the user-error, not a silence."
  (ecc-review-pr-test--with-gh dir
    (with-temp-file (expand-file-name "fail" dir)
      (insert "To get started with GitHub CLI, please run:  gh auth login\n"))
    (let ((err (should-error (ecc-review-pr-list dir) :type 'user-error)))
      (should (string-search "gh auth login" (cadr err)))))
  (ecc-review-pr-test--with-gh dir
    (let ((err (should-error (ecc-review-pr-view dir 77) :type 'user-error)))
      (should (string-search "no pull request 77" (cadr err))))))

;;;; Where a pull request is reviewed

(ert-deftest ecc-review-pr-test-remote-of-url ()
  "Every way of writing a GitHub repository finds the remote that is it."
  (dolist (url '("git@github.com:O/R.git" "ssh://git@github.com/o/r"
                 "https://github.com/o/r" "https://github.com/o/r.git/"
                 "https://github.com/o/r/pull/12"))
    (should (equal (ecc-review-pr--repo-of-url url) '("github.com" . "o/r"))))
  (should (equal (ecc-review-pr--repo-of-url "/srv/git/o/r.git") '(nil . "o/r")))
  (ecc-review-pr-test--with-directory directory
    (ecc-review-pr-test--git directory "init" "-q")
    (ecc-review-pr-test--git directory "remote" "add" "fork" "git@github.com:me/r.git")
    (ecc-review-pr-test--git directory "remote" "add" "mirror" "https://example.com/o/r.git")
    (ecc-review-pr-test--git directory "remote" "add" "upstream" "git@github.com:o/r.git")
    ;; The same host wins over the same name elsewhere.
    (should (equal (ecc-review-pr-remote directory "https://github.com/o/r/pull/1")
                   "upstream"))
    (should (equal (ecc-review-pr-remote directory "https://github.com/x/y/pull/1")
                   "https://github.com/x/y.git"))))

(ert-deftest ecc-review-pr-test-fetch-only-when-missing ()
  "The commits are fetched when missing, into no ref, and not again."
  (skip-unless (executable-find "git"))
  (ecc-review-pr-test--with-gh dir
    (seq-let (work base head) (ecc-review-pr-test--upstream dir)
      (let ((pr (car (ecc-review-pr-parse
                      (json-serialize (ecc-review-pr-test--pr 1 "t" "topic" "main"
                                                              head base)))))
            (refs (ecc-review-pr-test--git work "for-each-ref"))
            (at (ecc-review-pr-test--git work "rev-parse" "HEAD")))
        ;; The base is here already: nothing to fetch for it alone.
        (should-not (ecc-review-pr-fetch work pr (list base)))
        (should-not (ecc-review-pr--has-commit-p work head))
        (should (ecc-review-pr-fetch work pr (list base head)))
        (should (ecc-review-pr--has-commit-p work head))
        ;; No branch, no ref, HEAD where it was.
        (should (equal (ecc-review-pr-test--git work "for-each-ref") refs))
        (should (equal (ecc-review-pr-test--git work "rev-parse" "HEAD") at))
        ;; Fetched once: the second time the remote is not even asked.
        (ecc-review-pr-test--git work "remote" "set-url" "origin"
                                 (expand-file-name "gone/o/r.git" dir))
        (should-not (ecc-review-pr-fetch work pr (list base head)))
        ;; A commit the remote does not have either is an error that says so.
        (ecc-review-pr-test--git work "remote" "set-url" "origin"
                                 (expand-file-name "o/r.git" dir))
        (should-error (ecc-review-pr-fetch work pr (list (make-string 40 ?e)))
                      :type 'user-error)))))

(ert-deftest ecc-review-pr-test-someone-elses-pr ()
  "Another branch's PR is BASE...HEAD by id, called after it, not on disk."
  (skip-unless (executable-find "git"))
  (ecc-review-pr-test--with-gh dir
    (seq-let (work base head) (ecc-review-pr-test--upstream dir)
      (ecc-review-pr-test--answer
       dir "list.json" (list (ecc-review-pr-test--pr 1 "ブランチの\t修正" "topic" "main"
                                                     head base)))
      (ecc-test-with-fake-session session
        (setf (ecc-session-project-root session) work)
        (let ((ecc-review-menu--state (ecc-review-menu-make-state session work))
              (ecc-review-style 'diff)
              (ecc-review-menu--last nil)
              (shown nil))
          (cl-letf (((symbol-function 'ecc-window-display-review)
                     (lambda (buffer &rest _) (setq shown buffer)))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "1")))
            (unwind-protect
                (let ((pr (ecc-review-pr-read work "main")))
                  (should (equal (ecc-review-pr-range work pr "main")
                                 (cons (format "%s...%s" base head) "PR #1 ブランチの 修正")))
                  (ecc-review-menu-pull-request pr nil)
                  (should (eq ecc-review-menu--last 'pr))
                  (should (equal (buffer-name shown) "*ecc-review: test (PR #1 ブランチの 修正)*"))
                  (with-current-buffer shown
                    ;; b.txt of the PR; c.txt, on main since, is not in it.
                    (should (string-search "b/b.txt" (buffer-string)))
                    (should-not (string-search "c.txt" (buffer-string)))
                    (should (equal ecc-review--elsewhere
                                   (ecc-review-pr-test--git work "rev-parse" "--short"
                                                            head)))
                    (should (string-search "not checked out here"
                                           (ecc-review--header-line)))))
              (ecc-review-pr-test--kill-reviews))))))))

(ert-deftest ecc-review-pr-test-own-pr-includes-the-working-tree ()
  "The PR of the branch checked out is that branch and its working tree."
  (skip-unless (executable-find "git"))
  (ecc-review-pr-test--with-gh dir
    (seq-let (work base head) (ecc-review-pr-test--upstream dir)
      ;; The branch is checked out here, with a commit not pushed and a
      ;; change not committed.
      (ecc-review-pr-test--git work "fetch" "-q" "origin" "pull/1/head")
      (ecc-review-pr-test--git work "checkout" "-q" "-b" "topic" head)
      (ecc-review-pr-test--commit work "d.txt" "d\n")
      (with-temp-file (expand-file-name "b.txt" work) (insert "b, edited\n"))
      (let* ((pr (car (ecc-review-pr-parse
                       (json-serialize (ecc-review-pr-test--pr 1 "t" "topic" "main"
                                                               head base)))))
             (fork (ecc-review-pr-test--git work "merge-base" base "HEAD")))
        (should (ecc-review-pr-own-p pr "topic"))
        (should (equal (ecc-review-pr-range work pr "topic")
                       (cons fork "PR #1: main + working tree")))
        (ecc-test-with-fake-session session
          (setf (ecc-session-project-root session) work)
          (let ((ecc-review-menu--state (ecc-review-menu-make-state session work))
                (ecc-review-style 'diff)
                (shown nil))
            (cl-letf (((symbol-function 'ecc-window-display-review)
                       (lambda (buffer &rest _) (setq shown buffer))))
              (unwind-protect
                  (progn
                    (ecc-review-menu-pull-request pr nil)
                    (should (equal (buffer-name shown)
                                   "*ecc-review: test (PR #1: main + working tree)*"))
                    (with-current-buffer shown
                      (should (string-search "b, edited" (buffer-string)))
                      (should (string-search "b/d.txt" (buffer-string)))
                      (should-not ecc-review--elsewhere)
                      (should-not (string-search "not checked out"
                                                 (ecc-review--header-line)))))
                (ecc-review-pr-test--kill-reviews)))))))))

;;;; Saying the right side is not on disk

(defun ecc-review-pr-test--three-branches (directory)
  "Make DIRECTORY main, develop and feature, one commit apart, on feature.
Return the full ids of the three commits."
  (ecc-review-pr-test--git directory "init" "-q" "-b" "main")
  (ecc-review-pr-test--identity directory)
  (let* ((one (ecc-review-pr-test--commit directory "a.txt" "a\n"))
         (two (progn (ecc-review-pr-test--git directory "checkout" "-q" "-b" "develop")
                     (ecc-review-pr-test--commit directory "b.txt" "b\n")))
         (three (progn (ecc-review-pr-test--git directory "checkout" "-q" "-b" "feature")
                       (ecc-review-pr-test--commit directory "c.txt" "c\n"))))
    (list one two three)))

(ert-deftest ecc-review-pr-test-elsewhere-of-each-choice ()
  "b of another branch, c and r of commits are elsewhere; D w u s and b of HEAD are not."
  (skip-unless (executable-find "git"))
  (ecc-review-pr-test--with-directory directory
    (seq-let (one two _three) (ecc-review-pr-test--three-branches directory)
      (let ((root (ecc-review-git-root directory))
            (short (lambda (id) (ecc-review-pr-test--git directory "rev-parse" "--short" id))))
        ;; D, w, u, s.
        (dolist (range '(nil "HEAD" "" staged))
          (should-not (ecc-review-elsewhere root range)))
        ;; b of the current branch: where it forked, and the working tree.
        (should-not (ecc-review-elsewhere
                     root (car (ecc-review-menu-branch-range root "develop"))))
        ;; c of the commit checked out is what the files hold.
        (should-not (ecc-review-elsewhere root (ecc-review-menu-commit-range root "HEAD")))
        ;; b of another branch, c of an older commit, r of two commits.
        (should (equal (ecc-review-elsewhere
                        root (car (ecc-review-menu-branch-range root "main" "develop")))
                       "develop"))
        (should (equal (ecc-review-elsewhere root (ecc-review-menu-commit-range root two))
                       (funcall short two)))
        (should (equal (ecc-review-elsewhere root (format "%s..%s" one two))
                       (funcall short two)))
        (should (equal (ecc-review-elsewhere root "main..develop") "develop"))
        (should-not (ecc-review-elsewhere root "main.."))))))

(ert-deftest ecc-review-pr-test-elsewhere-header-and-prompt ()
  "A review of another branch says so on its header line and in its prompt."
  (skip-unless (executable-find "git"))
  (ecc-review-pr-test--with-directory directory
    (ecc-review-pr-test--three-branches directory)
    (with-temp-file (expand-file-name "c.txt" directory) (insert "changed\n"))
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (let ((ecc-review-style 'diff)
            (comment '(:path "b.txt" :start 1 :end 1 :text "+b" :comment "why?")))
        (cl-letf (((symbol-function 'ecc-window-display-review) #'ignore))
          (unwind-protect
              (progn
                (with-current-buffer (ecc-review-worktree-buffer session "main...develop" directory)
                  (setq-local ecc-review--comments-function (lambda () (list comment)))
                  (should (equal ecc-review--elsewhere "develop"))
                  (let ((header (ecc-review--header-line)))
                    (should (string-search "Review (main...develop)" header))
                    (should (string-search "the right side is develop, not checked out here"
                                           header)))
                  (let ((prompt (ecc-review-buffer-message)))
                    (should (string-prefix-p (concat ecc-review-header "\n"
                                                     "These changes are main...develop.  "
                                                     "Their right side, develop, is not checked out here")
                                             prompt))
                    (should (string-search "do not check anything out yourself" prompt)))
                  (should (string-search "not checked out here" (ecc-review-agent--what))))
                ;; The working tree against HEAD says none of it.
                (with-current-buffer (ecc-review-worktree-buffer session "HEAD" directory)
                  (setq-local ecc-review--comments-function (lambda () (list comment)))
                  (should-not ecc-review--elsewhere)
                  (should (string-search "Working tree (HEAD)"
                                         (ecc-review--header-line)))
                  (should-not (string-search "not checked out"
                                             (ecc-review--header-line)))
                  (should (string-prefix-p (concat ecc-review-header "\n\n")
                                           (ecc-review-buffer-message)))))
            (ecc-review-pr-test--kill-reviews)))))))

(ert-deftest ecc-review-pr-test-elsewhere-in-ediff ()
  "An ediff review of another branch says so at the end of the right header line."
  (skip-unless (executable-find "git"))
  (ecc-review-pr-test--with-directory directory
    (ecc-review-pr-test--three-branches directory)
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) directory)
      (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
            (ecc-review-ediff-layout 'side-by-side)
            (ecc-review-talk-reply-height nil)
            (control nil))
        (unwind-protect
            (save-window-excursion
              (delete-other-windows)
              (setq control (ecc-review-ediff-worktree-buffer session "main...develop"
                                                              directory))
              (with-current-buffer control
                (should (equal ecc-review--elsewhere "develop"))
                (should (string-search "right: develop, not checked out"
                                       (ecc-review-direct-header-text ediff-buffer-B)))
                (should (string-search "Their right side, develop"
                                       (let ((ecc-review--comments-function
                                              (lambda () (list '(:path "b.txt" :start 1 :end 1
                                                                 :text "+b" :comment "?")))))
                                         (ecc-review-buffer-message))))))
          (when (buffer-live-p control)
            (ecc-review-ediff-quit control))
          (ecc-review-pr-test--kill-reviews))))))

(provide 'ecc-review-pr-test)

;;; ecc-review-pr-test.el ends here
