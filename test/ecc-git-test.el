;;; ecc-git-test.el --- Tests for ecc-git  -*- lexical-binding: t; -*-

;;; Commentary:

;; The porcelain parser as a pure function, and the rest against a
;; throwaway repository: the two runners, the questions about worktrees
;; and the cache that keeps their answers, the root of a repository, and
;; the snapshot a session's review is taken against.  git is not a
;; dependency of this package, so every case that runs one is skipped
;; where there is none.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-git)

;;;; Helpers

(defmacro ecc-git-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards.
The cache is fresh as well: a test must not see what an earlier one
asked git."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-git" t)))
         (ecc-git--cache (make-hash-table :test #'equal)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-git-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-git-run-with-stderr directory
                       (append '("-c" "user.name=t" "-c" "user.email=t@example.com"
                                 "-c" "init.defaultBranch=main")
                               args))))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-git-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defun ecc-git-test--repository (directory)
  "Make DIRECTORY a git repository with one commit of x.txt in it."
  (ecc-git-test--git directory "init" "-q" ".")
  (ecc-git-test--write (expand-file-name "x.txt" directory) "one\n")
  (ecc-git-test--git directory "add" "x.txt")
  (ecc-git-test--git directory "commit" "-q" "-m" "init"))

;;;; Running git

(ert-deftest ecc-git-test-runners-read-their-streams ()
  "`ecc-git-run' reads stdout alone; `ecc-git-run-with-stderr' both.
Outside a repository, git refuses on stderr: the review must not read
that as output, and the worktree commands must have it to show."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (pcase-let ((`(,code . ,output)
                 (ecc-git-run directory "rev-parse" "--show-toplevel")))
      (should-not (eq code 0))
      (should (string-empty-p output)))
    (pcase-let ((`(,code . ,output)
                 (ecc-git-run-with-stderr directory "rev-parse" "--show-toplevel")))
      (should-not (eq code 0))
      (should (string-search "not a git repository" output)))
    ;; A directory that is not there is no answer from the second, and
    ;; no git run.
    (should-not (ecc-git-run-with-stderr (expand-file-name "gone" directory)
                                         "status"))))

(ert-deftest ecc-git-test-runners-without-git ()
  "With no git to run, both runners answer nil."
  (ecc-git-test--with-directory directory
    (let ((ecc-git-executable "ecc-git-test-no-such-program"))
      (should-not (ecc-git-run directory "status"))
      (should-not (ecc-git-run-with-stderr directory "status")))))

;;;; The porcelain

(defconst ecc-git-test--porcelain
  "worktree /repo
HEAD ec667d1aa8b60eedc6a3ba1d1a262840557c4990
branch refs/heads/release/0.2.0

worktree /repo/.claude/worktrees/feat+plugins
HEAD 006f20b778576e792d506211403321fa06310243
branch refs/heads/fix/plugin-review
locked claude session feat/plugins

worktree /repo/.claude/worktrees/loose
HEAD 8b3f9adef95086802cc9c5279082163492fe7a63
detached

worktree /repo/.claude/worktrees/gone
HEAD 077314722c14c2f0a166cde3a878571e696e1793
branch refs/heads/old
prunable gitdir file points to non-existent location
"
  "What `git worktree list --porcelain' looks like, with every attribute.")

(ert-deftest ecc-git-test-parse ()
  "Every record of the porcelain becomes an entry, the main one first."
  (let ((entries (ecc-git-parse-worktrees ecc-git-test--porcelain)))
    (should (= 4 (length entries)))
    (should (equal (mapcar #'ecc-git-worktree-entry-path entries)
                   '("/repo/" "/repo/.claude/worktrees/feat+plugins/"
                     "/repo/.claude/worktrees/loose/"
                     "/repo/.claude/worktrees/gone/")))
    (should (equal (mapcar #'ecc-git-worktree-entry-branch entries)
                   '("release/0.2.0" "fix/plugin-review" nil "old")))
    (should (equal (mapcar (lambda (entry)
                             (and (ecc-git-worktree-entry-main-p entry) t))
                           entries)
                   '(t nil nil nil)))
    (should (ecc-git-worktree-entry-detached-p (nth 2 entries)))
    (should-not (ecc-git-worktree-entry-detached-p (nth 1 entries)))
    (should (equal (ecc-git-worktree-entry-prunable-p (nth 3 entries))
                   "gitdir file points to non-existent location"))
    (should-not (ecc-git-worktree-entry-prunable-p (car entries)))))

(ert-deftest ecc-git-test-parse-empty ()
  "Nothing to parse is no worktrees rather than an error."
  (should-not (ecc-git-parse-worktrees ""))
  (should-not (ecc-git-parse-worktrees nil)))

(ert-deftest ecc-git-test-parse-locked ()
  "A locked worktree keeps git's reason, and t when git gave none."
  (let ((entries (ecc-git-parse-worktrees ecc-git-test--porcelain)))
    (should (equal (ecc-git-worktree-entry-locked-p (nth 1 entries))
                   "claude session feat/plugins"))
    (should-not (ecc-git-worktree-entry-locked-p (nth 2 entries))))
  (should (eq t (ecc-git-worktree-entry-locked-p
                 (cadr (ecc-git-parse-worktrees
                        "worktree /r\nHEAD 1\n\nworktree /r/w\nHEAD 2\nlocked\n"))))))

;;;; Against a real repository

(ert-deftest ecc-git-test-worktrees-and-branches ()
  "A linked worktree knows its parent, its branch and the others beside it."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    (let ((path (file-name-as-directory (expand-file-name "tree" directory))))
      (ecc-git-test--git directory "worktree" "add" "-b" "feat/x" path)
      (let ((entries (ecc-git-worktrees directory)))
        (should (= 2 (length entries)))
        (should (ecc-git-worktree-entry-main-p (car entries)))
        (should (equal (ecc-git-worktree-entry-branch (nth 1 entries)) "feat/x")))
      (should (equal (file-truename (ecc-git-main-worktree path))
                     (file-truename directory)))
      (should-not (ecc-git-main-worktree directory))
      (should (equal (file-truename (ecc-git-toplevel path)) (file-truename path)))
      (should (equal (ecc-git-branch path) "feat/x"))
      (should (equal (ecc-git-branch directory) "main"))
      (should (equal (ecc-git-worktree-entry-branch
                      (ecc-git-worktree-of-branch directory "feat/x"))
                     "feat/x"))
      (should-not (ecc-git-worktree-of-branch directory "nowhere"))
      (should (equal (sort (ecc-git-branches directory) #'string<)
                     '("feat/x" "main"))))))

(ert-deftest ecc-git-test-nothing-outside-a-repository ()
  "A directory that is not in a repository answers nil to everything."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (should-not (ecc-git-worktrees directory))
    (should-not (ecc-git-toplevel directory))
    (should-not (ecc-git-main-worktree directory))
    (should-not (ecc-git-branch directory))
    (should-not (ecc-git-ahead-behind directory))
    (should-not (ecc-git-root (expand-file-name "x.txt" directory)))))

(ert-deftest ecc-git-test-ahead-behind ()
  "The counts are ahead first, and a branch with no upstream has none.
This is what pins down which side of `rev-list --left-right' is which."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (let ((upstream (expand-file-name "up" directory))
          (clone (file-name-as-directory (expand-file-name "down" directory))))
      (make-directory upstream)
      (ecc-git-test--repository upstream)
      (ecc-git-test--git directory "clone" "-q" upstream "down")
      ;; Two commits on the upstream, one here: behind 2, ahead 1.
      (ecc-git-test--git upstream "commit" "-q" "--allow-empty" "-m" "u1")
      (ecc-git-test--git upstream "commit" "-q" "--allow-empty" "-m" "u2")
      (ecc-git-test--git clone "fetch" "-q")
      (ecc-git-test--git clone "commit" "-q" "--allow-empty" "-m" "d1")
      (should (equal (ecc-git-ahead-behind clone) '(1 . 2)))
      ;; A branch nobody has pushed has no upstream to count against.
      (ecc-git-test--git clone "checkout" "-q" "-b" "local-only")
      (clrhash ecc-git--cache)
      (should-not (ecc-git-ahead-behind clone)))))

(ert-deftest ecc-git-test-cache ()
  "An answer is reused until it is forgotten."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    (should (equal (ecc-git-branch directory) "main"))
    (ecc-git-test--git directory "checkout" "-q" "-b" "other")
    (should (equal (ecc-git-branch directory) "main"))
    (ecc-git-forget)
    (should (equal (ecc-git-branch directory) "other"))
    ;; And the clock lets go of it on its own.
    (let ((ecc-git--cache-ttl -1))
      (ecc-git-test--git directory "checkout" "-q" "-b" "third")
      (should (equal (ecc-git-branch directory) "third")))))

(ert-deftest ecc-git-test-a-session-in-a-worktree-goes-by-its-branch ()
  "The name of a session started in a worktree is the branch, not the slug.
The Space above it is called after the branch, and the directory is a
slug of that branch: one screen calling the same thing `feat/one\=' and
`feat-one\=' is one name too many (2026-09-17)."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    (let ((path (expand-file-name "feat-one" directory))
          (generated (expand-file-name "two" directory)))
      (ecc-git-test--git directory "worktree" "add" "-b" "feat/one" path)
      (should (equal (ecc-git-session-name path) "feat/one"))
      ;; The main worktree keeps the name of its directory, and so does a
      ;; directory that is in no repository at all.
      (should-not (ecc-git-session-name directory))
      (should-not (ecc-git-session-name temporary-file-directory))
      ;; herdr\='s prefix is dropped, as the Space drops it.
      (ecc-git-test--git directory "worktree" "add" "-b" "worktree/two" generated)
      (should (equal (ecc-git-session-name generated) "two")))))

(ert-deftest ecc-git-test-root ()
  "The root of the repository holding a file or a directory, slash-ended."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    (make-directory (expand-file-name "sub" directory))
    (let ((root (file-truename directory)))
      (should (equal (ecc-git-root (expand-file-name "x.txt" directory)) root))
      (should (equal (ecc-git-root (expand-file-name "sub/" directory)) root))
      ;; A file that does not exist yet is asked about through its
      ;; directory all the same.
      (should (equal (ecc-git-root (expand-file-name "sub/new.txt" directory))
                     root)))))

;;;; What the working tree held at one moment

(ert-deftest ecc-git-test-snapshot-leaves-the-repository-alone ()
  "A snapshot writes a tree and touches neither the index nor the tree."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    (ecc-git-test--write (concat directory "x.txt") "two\n")
    (ecc-git-test--write (concat directory "new.txt") "hello\n")
    (let ((root (ecc-git-root (concat directory "x.txt")))
          (before (ecc-git-test--git directory "status" "--porcelain")))
      (let ((tree (ecc-git-snapshot root)))
        (should (stringp tree))
        ;; The untracked file is in the tree, which is the point: it is
        ;; how a file that was already there stops reading as new.
        (should (string-search "new.txt"
                               (ecc-git-test--git root "ls-tree" "-r"
                                                  "--name-only" tree))))
      (should (equal before (ecc-git-test--git directory "status" "--porcelain")))
      ;; Nothing was stashed on the way.
      (should (string-empty-p (ecc-git-test--git directory "stash" "list"))))))

(ert-deftest ecc-git-test-snapshot-reads-a-file-as-old-as-the-index ()
  "A file whose stat is as new as the index is read, not trusted.
The stat cache the snapshot copies in is what makes it fast, and it is
also what would lose a file the CLI wrote in the same second as the
last commit and to the same length.  git re-reads such a file when the
index it was given is no newer than the file; the copy therefore has to
carry the time of the index it was made from."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    ;; git ignores the change time here, the way a write in the same second
    ;; leaves it saying nothing: a `set-file-times' can put back the
    ;; modification time of a file, and nothing can put back its change time.
    (ecc-git-test--git directory "config" "core.trustctime" "false")
    (let* ((root (ecc-git-root directory))
           (file (expand-file-name "x.txt" root))
           (index (expand-file-name ".git/index" root))
           ;; A moment ago, so that a copy of the index stamped now would be
           ;; the newer of the two and every cached stat would look sound.
           (moment (time-subtract (current-time) 5)))
      ;; Teach the index that stat while the content still agrees with it.
      (set-file-times file moment)
      (ecc-git-test--git directory "update-index" "--refresh")
      ;; Now the file changes, to the same number of bytes and back to the
      ;; stat the index holds: only its content says it changed at all.
      (ecc-git-test--write file "two\n")
      (set-file-times file moment)
      (set-file-times index moment)
      (should (equal (ecc-git-test--git root "diff" "--name-only" "HEAD"
                                        (ecc-git-snapshot root))
                     "x.txt\n")))))

(ert-deftest ecc-git-test-snapshot-no-add-is-the-index ()
  "With NO-ADD the snapshot is the index: what is staged and nothing else."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    ;; One change staged, one left unstaged, one file untracked.
    (ecc-git-test--write (concat directory "x.txt") "staged\n")
    (ecc-git-test--git directory "add" "x.txt")
    (ecc-git-test--write (concat directory "x.txt") "working\n")
    (ecc-git-test--write (concat directory "new.txt") "hello\n")
    (let* ((root (ecc-git-root directory))
           (index (ecc-git-snapshot root t))
           (whole (ecc-git-snapshot root)))
      (should index)
      (should-not (equal index whole))
      (should (equal (ecc-git-test--git directory "show" (concat index ":x.txt"))
                     "staged\n"))
      ;; The untracked file is only in the snapshot of the working tree.
      (should-not (equal 0 (car (ecc-git-run directory "show"
                                             (concat index ":new.txt")))))
      (should (equal (ecc-git-test--git directory "show" (concat whole ":x.txt"))
                     "working\n"))
      (should (equal (ecc-git-test--git directory "show" (concat whole ":new.txt"))
                     "hello\n"))
      ;; Neither disturbed the index of the repository itself.
      (should (equal (ecc-git-test--git directory "diff" "--cached" "--name-only")
                     "x.txt\n")))))

(ert-deftest ecc-git-test-ensure-baseline ()
  "A session takes a baseline once and keeps it; outside git it has none.
What a review is taken against has to outlive a resume, so a second call
changes nothing even after the files have.  A session outside git asks
again the next time, as a project can be put under git while it runs."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (let ((session (ecc-session--make :project-root directory)))
      (should-not (ecc-git-ensure-baseline session))
      (should-not (ecc-session-baseline session))
      (ecc-git-test--repository directory)
      (let ((first (ecc-git-ensure-baseline session)))
        (should (stringp first))
        (should (equal (ecc-session-baseline session) first))
        (ecc-git-test--write (concat directory "x.txt") "two\n")
        (should (equal (ecc-git-ensure-baseline session) first))
        (should-not (equal (ecc-git-snapshot (ecc-git-root directory)) first))))))

(provide 'ecc-git-test)

;;; ecc-git-test.el ends here
