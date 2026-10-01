;;; ecc-review-test.el --- Tests for ecc-review  -*- lexical-binding: t; -*-

;;; Commentary:

;; The message generator and the diff builders as pure functions, the
;; review buffer driven by hand, the review of a proposal before it is
;; applied and the edit-and-apply flow.  The git cases build a throwaway
;; repository.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-session)

;;;; Helpers

(cl-defun ecc-review-test--entry (session path &key original snapshot edits writes)
  "Give SESSION an entry for PATH with ORIGINAL, SNAPSHOT, EDITS and WRITES."
  (let ((entry (ecc-model-note-file session path nil)))
    (setf (ecc-file-entry-original entry) original
          (ecc-file-entry-snapshot entry) snapshot
          (ecc-file-entry-edits entry) (or edits 0)
          (ecc-file-entry-writes entry) (or writes 0))
    entry))

(defun ecc-review-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defmacro ecc-review-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-review" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-test--two-files (session directory)
  "Record two changed files of DIRECTORY in SESSION and return their paths.
Neither is in a git repository, so both are diffed from the records."
  (let ((a (concat directory "a.txt"))
        (b (concat directory "b.txt")))
    (ecc-review-test--entry session a :original "one\ntwo\nthree\n"
                            :snapshot "one\n2\nthree\n" :edits 1)
    (ecc-review-test--entry session b :original nil
                            :snapshot "hello\n" :writes 1)
    (list a b)))

(defun ecc-review-test--kill-review-buffers ()
  "Kill every buffer the review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;;; Pure functions

(ert-deftest ecc-review-test-hunk-range ()
  "The new side of a hunk header gives the line range shown in the message."
  (should (equal (ecc-review-hunk-range "@@ -10,3 +12,5 @@ def f():") '(12 . 16)))
  (should (equal (ecc-review-hunk-range "@@ -1 +1 @@") '(1 . 1)))
  ;; A hunk that only removes lines is still one line wide.
  (should (equal (ecc-review-hunk-range "@@ -4,2 +3,0 @@") '(3 . 3)))
  (should-not (ecc-review-hunk-range "--- a/x")))

(ert-deftest ecc-review-test-format-message ()
  "The prompt carries one block per comment."
  (let ((message (ecc-review-format-message
                  '((:path "src/a.py" :start 3 :end 5
                     :text "@@ -3,2 +3,3 @@\n a\n+b\n c" :comment "rename b")
                    (:path "src/b.py" :start 10 :end 10
                     :text "@@ -10 +10 @@\n-x\n+y" :comment "keep x")))))
    (should (equal message
                   (concat "Review comments on the changes below.  Please act on each of them.\n\n"
                           "## src/a.py  L3-L5\n```diff\n@@ -3,2 +3,3 @@\n a\n+b\n c\n```\nComment: rename b\n\n"
                           "## src/b.py  L10-L10\n```diff\n@@ -10 +10 @@\n-x\n+y\n```\nComment: keep x")))))

(ert-deftest ecc-review-test-format-message-fence ()
  "A hunk holding a fence is quoted with a longer one, and the header can change."
  (let ((message (ecc-review-format-message
                  '((:path "README.md" :start 1 :end 2
                     :text "@@ -1,2 +1,2 @@\n-```\n+```sh" :comment "language"))
                  "custom header")))
    (should (string-prefix-p "custom header\n\n" message))
    (should (string-search "````diff\n@@ -1,2 +1,2 @@\n-```\n+```sh\n````\n" message))))

(ert-deftest ecc-review-test-files-only-changed ()
  "Only files that were edited or written are reviewed, in path order or as asked."
  (ecc-test-with-fake-session session
    (ecc-review-test--entry session "/tmp/read.txt" :original 'unknown)
    (setf (ecc-file-entry-reads (gethash "/tmp/read.txt" (ecc-session-files session))) 2)
    (ecc-review-test--entry session "/tmp/b.txt" :writes 1)
    (ecc-review-test--entry session "/tmp/a.txt" :edits 1)
    (should (equal (mapcar #'ecc-file-entry-path (ecc-review-files session))
                   '("/tmp/a.txt" "/tmp/b.txt")))
    (should (equal (mapcar #'ecc-file-entry-path
                           (ecc-review-files session '("/tmp/b.txt" "/tmp/read.txt")))
                   '("/tmp/b.txt")))))

(ert-deftest ecc-review-test-original-from-fixtures ()
  "The recordings leave what each file was before the session changed it."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "edit-tool" "edit hello.py")
    (let ((entry (car (ecc-review-files session))))
      (should entry)
      (should (= (ecc-file-entry-edits entry) 1))
      ;; originalFile of the Edit result.
      (should (stringp (ecc-file-entry-original entry)))
      (should (string-search (car (car (ecc-file-entry-hunks entry)))
                             (ecc-file-entry-original entry)))))
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "tool-use-write" "write hello.txt")
    (let ((entry (car (ecc-review-files session))))
      (should entry)
      (should (= (ecc-file-entry-writes entry) 1))
      ;; A created file has no original: originalFile was null.
      (should (null (ecc-file-entry-original entry))))))

;;;; Diffs without git

(ert-deftest ecc-review-test-fallback-diff ()
  "A file outside git is diffed from what it was to what it is."
  (ecc-test-with-fake-session session
    (let ((edited (ecc-review-test--entry session "/nowhere/a.txt"
                                          :original "one\ntwo\nthree\n"
                                          :snapshot "one\n2\nthree\n" :edits 1))
          (created (ecc-review-test--entry session "/nowhere/b.txt"
                                           :original nil :snapshot "hello\nworld\n"
                                           :writes 1))
          (same (ecc-review-test--entry session "/nowhere/c.txt"
                                        :original "x\n" :snapshot "x\n" :edits 1)))
      (should (equal (ecc-review-fallback-diff edited)
                     "--- /nowhere/a.txt\n+++ /nowhere/a.txt\n@@ -2,1 +2,1 @@\n-two\n+2\n"))
      ;; The context is `ecc-review-context-lines', 0 by default.
      (should (equal (let ((ecc-review-context-lines 3))
                       (ecc-review-fallback-diff edited))
                     "--- /nowhere/a.txt\n+++ /nowhere/a.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n"))
      (should (equal (ecc-review-fallback-diff created)
                     "--- /dev/null\n+++ /nowhere/b.txt\n@@ -0,0 +1,2 @@\n+hello\n+world\n"))
      (should-not (ecc-review-fallback-diff same)))))

(ert-deftest ecc-review-test-fallback-diff-unknown-original ()
  "Without a known start the changes are shown one after the other."
  (ecc-test-with-fake-session session
    (let ((entry (ecc-review-test--entry session "/nowhere/a.txt" :original 'unknown
                                         :edits 2)))
      (ecc-model-note-hunk session "/nowhere/a.txt" "two" "2"
                           (vector '((oldStart . 2) (oldLines . 1) (newStart . 2)
                                     (newLines . 1) (lines . ["-two" "+2"]))))
      ;; The first change filled in the original; put it back to unknown
      ;; to test the path taken when no result carried it.
      (setf (ecc-file-entry-original entry) 'unknown)
      (ecc-model-note-hunk session "/nowhere/a.txt" "three" "3" nil)
      (setf (ecc-file-entry-original entry) 'unknown)
      (should (equal (ecc-review-fallback-diff entry)
                     (concat "--- /nowhere/a.txt\n+++ /nowhere/a.txt\n"
                             "@@ -2,1 +2,1 @@\n-two\n+2\n"
                             "@@ -1,1 +1,1 @@\n-three\n+3\n"))))))

;;;; Diffs with git

(ert-deftest ecc-review-test-git-diff ()
  "A tracked file is diffed by git; an untracked one from the records."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (let ((tracked (concat directory "x.txt"))
            (untracked (concat directory "new.txt")))
        (ecc-review-test--git directory "init" "-q")
        (ecc-review-test--git directory "config" "user.email" "t@example.com")
        (ecc-review-test--git directory "config" "user.name" "t")
        (ecc-review-test--write tracked "one\ntwo\nthree\n")
        (ecc-review-test--git directory "add" "x.txt")
        (ecc-review-test--git directory "commit" "-q" "-m" "init")
        (ecc-review-test--write tracked "one\n2\nthree\n")
        (ecc-review-test--write untracked "hello\n")
        (ecc-review-test--entry session tracked :original "one\ntwo\nthree\n"
                                :snapshot "one\n2\nthree\n" :edits 1)
        (ecc-review-test--entry session untracked :original nil
                                :snapshot "hello\n" :writes 1)
        (should (equal (ecc-review-git-root tracked)
                       (file-name-as-directory (file-truename directory))))
        (should (equal (ecc-review-git-tracked (ecc-review-git-root tracked)
                                               (list tracked untracked))
                       (list tracked)))
        (let ((diff (ecc-review-diff-text (ecc-review-files session))))
          (should diff)
          (should (equal (cdr diff) (ecc-review-git-root tracked)))
          (should (string-search "diff --git a/x.txt b/x.txt\n" (car diff)))
          (should (string-search "\n-two\n+2\n" (car diff)))
          (should (string-search (format "--- /dev/null\n+++ %s\n@@ -0,0 +1,1 @@\n+hello\n"
                                         untracked)
                                 (car diff)))
          ;; git first, then the file it does not know.
          (should (< (string-search "diff --git" (car diff))
                     (string-search "/dev/null" (car diff)))))))))

;;;; The baseline a session is reviewed against

(ert-deftest ecc-review-test-snapshot-leaves-the-repository-alone ()
  "A snapshot writes a tree and touches neither the index nor the tree."
  (skip-unless (executable-find "git"))
  (ecc-review-test--with-directory directory
    (ecc-review-test--git directory "init" "-q")
    (ecc-review-test--git directory "config" "user.email" "t@example.com")
    (ecc-review-test--git directory "config" "user.name" "t")
    (ecc-review-test--write (concat directory "x.txt") "one\n")
    (ecc-review-test--git directory "add" "x.txt")
    (ecc-review-test--git directory "commit" "-q" "-m" "init")
    (ecc-review-test--write (concat directory "x.txt") "two\n")
    (ecc-review-test--write (concat directory "new.txt") "hello\n")
    (let ((root (ecc-review-git-root (concat directory "x.txt")))
          (before (ecc-review-test--git directory "status" "--porcelain")))
      (let ((tree (ecc-review-snapshot root)))
        (should (stringp tree))
        ;; The untracked file is in the tree, which is the point: it is
        ;; how a file that was already there stops reading as new.
        (should (string-search "new.txt"
                               (ecc-review-test--git root "ls-tree" "-r"
                                                     "--name-only" tree))))
      (should (equal before (ecc-review-test--git directory "status" "--porcelain")))
      ;; Nothing was stashed on the way.
      (should (string-empty-p (ecc-review-test--git directory "stash" "list"))))))

(ert-deftest ecc-review-test-snapshot-reads-a-file-as-old-as-the-index ()
  "A file whose stat is as new as the index is read, not trusted.
The stat cache the snapshot copies in is what makes it fast, and it is
also what would lose a file the CLI wrote in the same second as the
last commit and to the same length.  git re-reads such a file when the
index it was given is no newer than the file; the copy therefore has to
carry the time of the index it was made from."
  (skip-unless (executable-find "git"))
  (ecc-review-test--with-directory directory
    (ecc-review-test--git directory "init" "-q")
    (ecc-review-test--git directory "config" "user.email" "t@example.com")
    (ecc-review-test--git directory "config" "user.name" "t")
    (ecc-review-test--write (concat directory "x.txt") "one\n")
    (ecc-review-test--git directory "add" "x.txt")
    (ecc-review-test--git directory "commit" "-q" "-m" "init")
    ;; git ignores the change time here, the way a write in the same second
    ;; leaves it saying nothing: a `set-file-times' can put back the
    ;; modification time of a file, and nothing can put back its change time.
    (ecc-review-test--git directory "config" "core.trustctime" "false")
    (let* ((root (ecc-review-git-root directory))
           (file (expand-file-name "x.txt" root))
           (index (expand-file-name ".git/index" root))
           ;; A moment ago, so that a copy of the index stamped now would be
           ;; the newer of the two and every cached stat would look sound.
           (moment (time-subtract (current-time) 5)))
      ;; Teach the index that stat while the content still agrees with it.
      (set-file-times file moment)
      (ecc-review-test--git directory "update-index" "--refresh")
      ;; Now the file changes, to the same number of bytes and back to the
      ;; stat the index holds: only its content says it changed at all.
      (ecc-review-test--write file "two\n")
      (set-file-times file moment)
      (set-file-times index moment)
      (should (assoc "x.txt"
                     (ecc-review--numstat root (ecc-review--head-tree root)
                                          (ecc-review-snapshot root) nil))))))

(ert-deftest ecc-review-test-snapshot-no-add-is-the-index ()
  "With NO-ADD the snapshot is the index: what is staged and nothing else."
  (skip-unless (executable-find "git"))
  (ecc-review-test--with-directory directory
    (ecc-review-test--git directory "init" "-q")
    (ecc-review-test--git directory "config" "user.email" "t@example.com")
    (ecc-review-test--git directory "config" "user.name" "t")
    (ecc-review-test--write (concat directory "x.txt") "one\n")
    (ecc-review-test--git directory "add" "x.txt")
    (ecc-review-test--git directory "commit" "-q" "-m" "init")
    ;; One change staged, one left unstaged, one file untracked.
    (ecc-review-test--write (concat directory "x.txt") "staged\n")
    (ecc-review-test--git directory "add" "x.txt")
    (ecc-review-test--write (concat directory "x.txt") "working\n")
    (ecc-review-test--write (concat directory "new.txt") "hello\n")
    (let* ((root (ecc-review-git-root directory))
           (index (ecc-review-snapshot root t))
           (whole (ecc-review-snapshot root)))
      (should index)
      (should-not (equal index whole))
      (should (equal (ecc-review-test--git directory "show" (concat index ":x.txt"))
                     "staged\n"))
      ;; The untracked file is only in the snapshot of the working tree.
      (should-not (equal 0 (car (ecc-review--git directory "show"
                                                 (concat index ":new.txt")))))
      (should (equal (ecc-review-test--git directory "show" (concat whole ":x.txt"))
                     "working\n"))
      (should (equal (ecc-review-test--git directory "show" (concat whole ":new.txt"))
                     "hello\n"))
      ;; Neither disturbed the index of the repository itself.
      (should (equal (ecc-review-test--git directory "diff" "--cached" "--name-only")
                     "x.txt\n")))))

(ert-deftest ecc-review-test-baseline-excludes-what-came-before ()
  "The session review shows what changed after the baseline, not before it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write (concat directory "x.txt") "one\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            ;; Work of the user's own, before the session starts.
            (ecc-review-test--write (concat directory "x.txt") "mine\n")
            (ecc-review-test--write (concat directory "was-here.txt") "already\n")
            (setf (ecc-session-project-root session) directory)
            (should (ecc-review-ensure-baseline session))
            ;; Now the session works, by no particular tool.
            (ecc-review-test--write (concat directory "x.txt") "theirs\n")
            (ecc-review-test--write (concat directory "made.txt") "new\n")
            (let ((buffer (ecc-review-buffer session)))
              (with-current-buffer buffer
                (let ((text (buffer-string)))
                  ;; The change the session made, from where it found it.
                  (should (string-search "\n-mine\n+theirs\n" text))
                  (should-not (string-search "-one\n" text))
                  ;; The file it created, and not the one already there.
                  (should (string-search "made.txt" text))
                  (should-not (string-search "was-here.txt" text))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-baseline-survives-a-resume ()
  "A session that has a baseline keeps it, so a resume loses no work."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write (concat directory "x.txt") "one\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (setf (ecc-session-project-root session) directory)
            (let ((first (ecc-review-ensure-baseline session)))
              (should first)
              ;; The session works, then its CLI is killed and started
              ;; again.  Resuming restarts the process, not the work.
              (ecc-review-test--write (concat directory "x.txt") "two\n")
              (should (equal (ecc-review-ensure-baseline session) first))
              ;; So the work done before the resume is still reviewable.
              (let ((buffer (ecc-review-buffer session)))
                (with-current-buffer buffer
                  (should (string-search "\n-one\n+two\n" (buffer-string)))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-baseline-spans-a-commit ()
  "Work the session committed is still shown; `git diff HEAD' would lose it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write (concat directory "x.txt") "one\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (setf (ecc-session-project-root session) directory)
            (should (ecc-review-ensure-baseline session))
            ;; The session changes a file and commits it, as the project
            ;; asks for: meaningful steps rather than one lump.
            (ecc-review-test--write (concat directory "x.txt") "two\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "step")
            (ecc-review-test--write (concat directory "y.txt") "later\n")
            ;; Against HEAD the committed step is gone.
            (let ((buffer (ecc-review-worktree-buffer session)))
              (with-current-buffer buffer
                (should-not (string-search "-one\n" (buffer-string)))))
            ;; Against the baseline it is still there, with the rest.
            (let ((buffer (ecc-review-buffer session)))
              (with-current-buffer buffer
                (let ((text (buffer-string)))
                  (should (string-search "\n-one\n+two\n" text))
                  (should (string-search "+later\n" text))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-baseline-names-an-oversized-file ()
  "A file too large to read is named rather than printed."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((ecc-review-max-bytes 100))
            (ecc-review-test--git directory "init" "-q")
            (setf (ecc-session-project-root session) directory)
            (should (ecc-review-ensure-baseline session))
            (ecc-review-test--write (concat directory "lock.json")
                                    (make-string 400 ?x))
            (ecc-review-test--write (concat directory "small.txt") "fine\n")
            (let ((buffer (ecc-review-buffer session)))
              (with-current-buffer buffer
                (let ((text (buffer-string)))
                  (should (string-search "not shown" text))
                  (should-not (string-search "xxxxxxxx" text))
                  (should (string-search "+fine\n" text))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-baseline-outside-git-uses-the-records ()
  "A project outside git is still reviewed from what the session recorded."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((file (concat directory "a.txt")))
            (ecc-review-test--write file "after\n")
            (ecc-review-test--entry session file :original "before\n"
                                    :snapshot "after\n" :edits 1)
            (setf (ecc-session-project-root session) directory)
            ;; No repository, so no baseline and nothing to diff trees with.
            (should-not (ecc-review-ensure-baseline session))
            (let ((buffer (ecc-review-buffer session)))
              (with-current-buffer buffer
                (should (string-search "\n-before\n+after\n" (buffer-string))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree ()
  "The working tree review shows every change of the repository."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((unstaged (concat directory "x.txt"))
                (staged (concat directory "y.txt"))
                (untracked (concat directory "new.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write unstaged "one\ntwo\nthree\n")
            (ecc-review-test--write staged "alpha\n")
            (ecc-review-test--git directory "add" "x.txt" "y.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write unstaged "one\n2\nthree\n")
            (ecc-review-test--write staged "beta\n")
            (ecc-review-test--git directory "add" "y.txt")
            (ecc-review-test--write untracked "hello\n")
            (setf (ecc-session-project-root session) directory)
            ;; This session never had a baseline taken, so the review of
            ;; the session falls back to HEAD and shows what this one
            ;; shows, rather than refusing for want of a record.
            (let ((buffer (ecc-review-buffer session)))
              (with-current-buffer buffer
                (should (string-search "\n-two\n+2\n" (buffer-string)))))
            (let ((buffer (ecc-review-worktree-buffer session)))
              (with-current-buffer buffer
                (should (derived-mode-p 'ecc-review-mode))
                (should (equal (buffer-name) "*ecc-review: test (HEAD)*"))
                (should (equal ecc-review--range "HEAD"))
                (should (equal default-directory (ecc-review-git-root directory)))
                (let ((text (buffer-string)))
                  ;; Unstaged, staged and untracked, none of them the
                  ;; session\='s own work.
                  (should (string-search "\n-two\n+2\n" text))
                  (should (string-search "\n-alpha\n+beta\n" text))
                  (should (string-search "+hello\n" text)))
                ;; A comment goes to the session the review belongs to.
                (goto-char (point-min))
                (diff-hunk-next)
                (ecc-review-comment "rename this")
                (should (string-search "rename this" (ecc-review-buffer-message)))))
            ;; Without a revision only what is not staged is shown.
            (let ((buffer (ecc-review-worktree-buffer session "")))
              (with-current-buffer buffer
                (should (equal (buffer-name) "*ecc-review: test (unstaged changes)*"))
                (should (string-search "\n-two\n+2\n" (buffer-string)))
                (should-not (string-search "-alpha" (buffer-string))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-untracked-binary-is-named ()
  "A binary or oversized untracked file is named, not printed."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((binary (concat directory "photo.png"))
                (big (concat directory "dump.sql"))
                (small (concat directory "notes.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write small "keep me\n")
            (with-temp-file binary
              (set-buffer-multibyte nil)
              (insert "\211PNG\r\n\032\n" (make-string 64 0) "\377\330\377"))
            (ecc-review-test--write big (make-string 200 ?x))
            (setf (ecc-session-project-root session) directory)
            (let* ((ecc-review-untracked-max-bytes 100)
                   (text (ecc-review-git-untracked (ecc-review-git-root directory))))
              (should (string-search "Binary files /dev/null and b/photo.png differ" text))
              (should (string-search "Files /dev/null and b/dump.sql differ" text))
              (should (string-search "not shown" text))
              (should (string-search "+keep me" text))
              ;; Nothing of either file leaked into the buffer.
              (should-not (string-search "PNG" text))
              (should-not (string-search "xxxxx" text))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-session-is-the-project-s ()
  "The comments go to the session of the project, not to whichever is current."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-directory other
        (setf (ecc-session-project-root session) other)
        (let ((mine (ecc-model-create-session :name "mine" :project-root directory)))
          (unwind-protect
              (progn
                (should (eq (ecc-review-worktree-session directory) mine))
                (should (eq (ecc-review-worktree-session other) session)))
            (ecc-test-cleanup-session mine)))))))

(ert-deftest ecc-review-test-worktree-offers-a-session ()
  "A project with no session offers to start one, and takes no for an answer."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-directory other
        (setf (ecc-session-project-root session) other)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (should-error (ecc-review-worktree-session directory) :type 'user-error))
        (let ((started nil))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                    ((symbol-function 'ecc-start)
                     (lambda (root &optional _name) (setq started root) session)))
            (should (eq (ecc-review-worktree-session directory) session))
            (should (equal started directory))))))))

(ert-deftest ecc-review-test-worktree-context-lines ()
  "`ecc-review-context-lines' is passed to git, splitting the hunks."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((path (concat directory "x.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write path "1\n2\n3\n4\n5\n6\n7\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            ;; Two changes four lines apart: one hunk at three lines of
            ;; context, two at none.
            (ecc-review-test--write path "one\n2\n3\n4\n5\n6\nseven\n")
            (setf (ecc-session-project-root session) directory)
            (let ((ecc-review-context-lines 3))
              (with-current-buffer (ecc-review-worktree-buffer session)
                (should (= (length (ecc-review-hunks)) 1))))
            (let ((ecc-review-context-lines 0))
              (with-current-buffer (ecc-review-worktree-buffer session)
                (should (= (length (ecc-review-hunks)) 2))
                ;; No context line came with them.
                (should-not (string-search "\n 2\n" (buffer-string))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-unknown-revision ()
  "A revision git refuses is said so, not shown as a tree with no change."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write (concat directory "x.txt") "one\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            ;; An untracked file would otherwise fill the buffer on its
            ;; own and hide that git never answered.
            (ecc-review-test--write (concat directory "new.txt") "hello\n")
            (setf (ecc-session-project-root session) directory)
            (let ((error (should-error (ecc-review-worktree-buffer session "nope...HEAD")
                                       :type 'user-error)))
              (should (string-search "nope...HEAD" (error-message-string error)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-without-commits ()
  "A repository with no commit yet reviews the code written in it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--write (concat directory "x.txt") "one\ntwo\n")
            (setf (ecc-session-project-root session) directory)
            (should (ecc-review--unborn-p (ecc-review-git-root directory)))
            (let ((buffer (ecc-review-worktree-buffer session)))
              (with-current-buffer buffer
                (should (derived-mode-p 'ecc-review-mode))
                ;; The range is still HEAD to the eye: only what git was
                ;; asked was changed, so a refresh reads the same tree and
                ;; the first commit puts the real HEAD back on its own.
                (should (equal (buffer-name) "*ecc-review: test (HEAD)*"))
                (should (equal ecc-review--range "HEAD"))
                (let ((text (buffer-string)))
                  (should (string-search "x.txt" text))
                  (should (string-search "+one\n" text))
                  (should (string-search "+two\n" text))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-without-commits-staged ()
  "Before the first commit a staged file is shown once, beside the untracked."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--write (concat directory "staged.txt") "alpha\n")
            (ecc-review-test--write (concat directory "new.txt") "hello\n")
            (ecc-review-test--git directory "add" "staged.txt")
            (setf (ecc-session-project-root session) directory)
            (let ((buffer (ecc-review-worktree-buffer session)))
              (with-current-buffer buffer
                (let ((text (buffer-string)))
                  ;; The staged file comes from the diff against the empty
                  ;; tree, the untracked one from `ecc-review-git-untracked'.
                  (should (string-search "+alpha\n" text))
                  (should (string-search "+hello\n" text))
                  ;; git stopped calling the staged file untracked when it
                  ;; was added, so the two halves cannot both claim it.
                  (should (= 1 (cl-count "diff --git a/staged.txt b/staged.txt"
                                         (split-string text "\n")
                                         :test #'equal)))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-without-commits-bad-range ()
  "Only the bare HEAD stands in for the empty tree; a bad range still errors."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--write (concat directory "new.txt") "hello\n")
            (setf (ecc-session-project-root session) directory)
            (let ((error (should-error (ecc-review-worktree-buffer session "nope...HEAD")
                                       :type 'user-error)))
              (should (string-search "nope...HEAD" (error-message-string error)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-needs-git ()
  "A project outside git says so rather than showing an empty diff."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (setf (ecc-session-project-root session) directory)
      (cl-letf (((symbol-function 'ecc-review-git-root) (lambda (_path) nil)))
        (should-error (ecc-review-worktree-buffer session) :type 'user-error)))))

;;;; The review buffer

(ert-deftest ecc-review-test-buffer-and-comments ()
  "Hunks are walked with n, commented with c, listed, edited and removed."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          ;; Three lines of context, so that a hunk has lines around the
          ;; change for the walking and the source jump to land on.
          (let* ((ecc-review-context-lines 3)
                 (paths (ecc-review-test--two-files session directory))
                 (buffer (ecc-review-buffer session)))
            (with-current-buffer buffer
              (should (derived-mode-p 'ecc-review-mode 'diff-mode))
              (should buffer-read-only)
              (should (equal (buffer-name) "*ecc-review: test*"))
              ;; The files are named in full, so the project is the place.
              (should (equal default-directory (ecc-session-project-root session)))
              ;; The review keys win over the read-only diff keys, which
              ;; stay available for moving around.
              (should (eq (key-binding (kbd "c")) #'ecc-review-comment))
              (should (eq (key-binding (kbd "C-c C-c")) #'ecc-review-send))
              (should (eq (key-binding (kbd "n")) #'diff-hunk-next))
              (should (eq (key-binding (kbd "RET")) #'diff-goto-source))
              (should (= (length (ecc-review-hunks)) 2))
              ;; Not on a hunk yet.
              (should (= (point) (point-min)))
              (should-error (ecc-review-comment "x") :type 'user-error)
              (diff-hunk-next)
              (ecc-review-comment "use a word")
              (diff-hunk-next)
              (ecc-review-comment "add a newline")
              (let ((comments (ecc-review-comments)))
                (should (= (length comments) 2))
                (should (equal (plist-get (car comments) :path) (car paths)))
                (should (equal (plist-get (car comments) :start) 1))
                (should (equal (plist-get (car comments) :end) 3))
                (should (equal (plist-get (car comments) :comment) "use a word"))
                (should (equal (plist-get (car comments) :text)
                               "@@ -1,3 +1,3 @@\n one\n-two\n+2\n three"))
                (should (equal (plist-get (cadr comments) :path) (cadr paths)))
                (should (equal (plist-get (cadr comments) :comment) "add a newline")))
              ;; Shown under the hunk with its id, counted in the header line.
              (should (string-search "▎ #1 use a word"
                                     (overlay-get (car (last (ecc-review-comment-overlays)))
                                                  'after-string)))
              (should (string-search "comments: 2 yours" (ecc-review--header-line)))
              ;; Editing replaces, removing drops.
              (ecc-review-comment "add two newlines")
              (should (= (length (ecc-review-comments)) 2))
              (should (equal (plist-get (cadr (ecc-review-comments)) :comment)
                             "add two newlines"))
              (ecc-review-remove-comment)
              (should (= (length (ecc-review-comments)) 1))
              (should-error (ecc-review-remove-comment) :type 'user-error)
              ;; RET goes to the file and line of the hunk.
              (ecc-review-test--write (car paths) "one\n2\nthree\n")
              (goto-char (point-min))
              (diff-hunk-next)
              (forward-line 2)
              (let ((location (diff-find-source-location)))
                (should (equal (buffer-file-name (nth 0 location)) (car paths)))
                (kill-buffer (nth 0 location)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-send-editing-first ()
  "C-u C-c C-c shows the prompt to confirm; sending starts a turn."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((buffer (progn (ecc-review-test--two-files session directory)
                               (ecc-review-buffer session))))
            (with-current-buffer buffer
              (should-error (ecc-review-send) :type 'user-error)
              (diff-hunk-next)
              (ecc-review-comment "use a word")
              (let ((expected (ecc-review-format-message (ecc-review-comments))))
                (ecc-review-send t)
                (let ((message-buffer (get-buffer "*ecc-review-message: test*")))
                  (should message-buffer)
                  (with-current-buffer message-buffer
                    (should (derived-mode-p 'ecc-review-message-mode))
                    (should (equal (buffer-string) expected))
                    ;; What is sent is the buffer, so an edit goes along.
                    (goto-char (point-max))
                    (insert "\n\n全体: テストも足すこと")
                    (ecc-review-message-send))
                  (should-not (buffer-live-p message-buffer))
                  (should-not (buffer-live-p buffer))
                  (let ((sent (car (ecc-test-sent-messages))))
                    (should (equal (alist-get 'type sent) "user"))
                    (should (equal (alist-get 'content (alist-get 'message sent))
                                   (concat expected "\n\n全体: テストも足すこと"))))
                  (should (ecc-session-current-turn session))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-send ()
  "C-c C-c without a prefix sends the comments and closes the review."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((buffer (progn (ecc-review-test--two-files session directory)
                               (ecc-review-buffer session))))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "use a word")
              (let ((expected (ecc-review-format-message (ecc-review-comments))))
                (ecc-review-send)
                ;; No buffer to confirm in, and the review is done with.
                (should-not (get-buffer "*ecc-review-message: test*"))
                (should-not (buffer-live-p buffer))
                (let ((sent (car (ecc-test-sent-messages))))
                  (should (equal (alist-get 'type sent) "user"))
                  (should (equal (alist-get 'content (alist-get 'message sent))
                                 expected)))
                (should (ecc-session-current-turn session)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-send-queues-while-running ()
  "During a turn the prompt joins the queue instead of interrupting."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--two-files session directory)
            (ecc-model-begin-turn session "working")
            (with-current-buffer (ecc-review-buffer session)
              (diff-hunk-next)
              (ecc-review-comment "later")
              (ecc-review-send))
            (should-not ecc-test-sent)
            (should (= (length (ecc-session-input-queue session)) 1))
            (should (string-search "Comment: later"
                                   (car (ecc-session-input-queue session)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-refresh-keeps-comments ()
  "g reads the diff again and keeps every comment, moved where its hunk went."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          ;; Three lines of context, so that a hunk has lines around the
          ;; change for the walking and the source jump to land on.
          (let* ((ecc-review-context-lines 3)
                 (paths (ecc-review-test--two-files session directory))
                 (buffer (ecc-review-buffer session)))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "keep me")
              (diff-hunk-next)
              (ecc-review-comment "follow me")
              ;; The second file changes shape; the first stays.
              (setf (ecc-file-entry-snapshot
                     (gethash (cadr paths) (ecc-session-files session)))
                    "hello\nworld\n")
              (ecc-review-refresh)
              (should (eq (current-buffer) buffer))
              ;; The second hunk has another header now, but it covers
              ;; the lines the comment was on, so the comment follows it.
              (let ((comments (ecc-review-comments)))
                (should (= (length comments) 2))
                (should (equal (plist-get (car comments) :comment) "keep me"))
                (should (equal (plist-get (car comments) :path) (car paths)))
                (should (equal (plist-get (cadr comments) :comment) "follow me"))
                (should (equal (plist-get (cadr comments) :header) "@@ -0,0 +1,2 @@"))
                (should-not (plist-get (cadr comments) :outdated)))
              (should (string-search "+world" (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-nothing-to-review ()
  "Without a changed file, or with files that show no change, nothing opens."
  (ecc-test-with-fake-session session
    (should-error (ecc-review-buffer session) :type 'user-error)
    (ecc-review-test--entry session "/nowhere/c.txt" :original "x\n" :snapshot "x\n"
                            :edits 1)
    (should-error (ecc-review-buffer session) :type 'user-error)
    (should-not (get-buffer "*ecc-review: test*"))))

(ert-deftest ecc-review-test-session-keys ()
  "d reviews from the transcript, denies on a request, and c comments on one."
  (should (eq (lookup-key ecc-chat-transcript-map (kbd "d")) #'ecc-session-review-or-deny))
  (should (eq (lookup-key ecc-request-section-map (kbd "d")) 'ecc-perm-deny))
  (should (eq (lookup-key ecc-request-section-map (kbd "c")) 'ecc-review-comment-request))
  (should (eq (lookup-key ecc-request-section-map (kbd "e")) 'ecc-review-edit-proposal))
  (should (eq (lookup-key ecc-file-section-map (kbd "d")) 'ecc-session-review-file))
  (ecc-test-with-fake-session session
    (ecc-test-add-request session)
    ;; With a request waiting somewhere but not at point, d still means
    ;; review; the request is answered from its own section.
    (with-temp-buffer
      (setq ecc-render--session session)
      (should-error (ecc-session-review-or-deny) :type 'user-error)
      (should (memq (car (ecc-session-pending session)) (ecc-session-pending session))))))

;;;; Comments on lines

(defconst ecc-review-test--diff
  "diff --git a/foo.el b/foo.el
--- a/foo.el
+++ b/foo.el
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
@@ -10,2 +10,3 @@
 ten
+added
 eleven
"
  "A diff of one file in two hunks, to comment on line by line.")

(defun ecc-review-test--fill (session text)
  "Put the diff TEXT in the review buffer of SESSION and return the buffer."
  (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                    session text temporary-file-directory))

(defun ecc-review-test--goto (line)
  "Move to the start of the first line that is LINE exactly."
  (goto-char (point-min))
  (re-search-forward (concat "^" (regexp-quote line) "$"))
  (beginning-of-line))

(defmacro ecc-review-test--with-review (session &rest body)
  "Run BODY in a review of `ecc-review-test--diff' for a fake SESSION."
  (declare (indent 1))
  `(ecc-test-with-fake-session ,session
     (unwind-protect
         (with-current-buffer (ecc-review-test--fill ,session ecc-review-test--diff)
           ,@body)
       (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-lines-are-numbered-on-their-side ()
  "A removed line counts on the old side, an added or a context line on the new."
  (ecc-review-test--with-review session
    (let ((lines (ecc-review--lines)))
      (should (equal (mapcar (lambda (line)
                               (list (plist-get line :side) (plist-get line :line)
                                     (plist-get line :text)))
                             lines)
                     '((nil nil "@@ -1,3 +1,3 @@")
                       (new 1 "one") (old 2 "two") (new 2 "TWO") (new 3 "three")
                       (nil nil "@@ -10,2 +10,3 @@")
                       (new 10 "ten") (new 11 "added") (new 12 "eleven"))))
      (should (equal (plist-get (nth 4 lines) :old-line) 3))
      (should (equal (plist-get (car lines) :path) "foo.el")))))

(ert-deftest ecc-review-test-comment-takes-its-side-from-the-line ()
  "c on -, + and context lines comments that line; on @@ the whole hunk."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "-two")
    (ecc-review-comment "why go")
    (ecc-review-test--goto "+TWO")
    (ecc-review-comment "shouting")
    (ecc-review-test--goto " three")
    (ecc-review-comment "context")
    (ecc-review-test--goto "@@ -10,2 +10,3 @@")
    (ecc-review-comment "whole hunk")
    (should (equal (mapcar (lambda (note)
                             (list (ecc-review-note-id note)
                                   (ecc-review-note-side note)
                                   (ecc-review-note-line note)))
                           ecc-review--notes)
                   '((1 old 2) (2 new 2) (3 new 3) (4 nil nil))))
    (should (equal (mapcar #'ecc-review-note-where ecc-review--notes)
                   '("foo.el:2 (old)" "foo.el:2 (new)" "foo.el:3 (new)"
                     "foo.el L10-L12")))
    ;; Drawn under the line, and the header of the hunk stands out.
    (ecc-review-test--goto "-two")
    (let ((overlay (seq-find (lambda (o) (overlay-get o 'ecc-review-notes))
                             (overlays-at (point)))))
      (should (equal (overlay-get overlay 'after-string) "  ▎ #1 why go\n"))
      (should (= (overlay-end overlay) (line-beginning-position 2))))
    (should (= (length ecc-review--decorations) 2))
    ;; Again on the same line edits rather than adding.
    (ecc-review-test--goto "+TWO")
    (ecc-review-comment "still shouting")
    (should (= (length ecc-review--notes) 4))
    (should (equal (ecc-review-note-text (ecc-review-find-note 2)) "still shouting"))
    ;; Not a line of a hunk.
    (goto-char (point-min))
    (should-error (ecc-review-comment "x") :type 'user-error)))

(defconst ecc-review-test--shifted-diff
  (thread-last ecc-review-test--diff
               (string-replace "@@ -1,3 +1,3 @@" "@@ -1,3 +1,5 @@")
               (string-replace "+TWO\n" "+TWO\n+more\n+lines\n")
               (string-replace "@@ -10,2 +10,3 @@" "@@ -10,2 +12,3 @@"))
  "`ecc-review-test--diff' with two lines added in its first hunk.
Everything in the second hunk is two lines further down.")

(defun ecc-review-test--lines-of (text)
  "Return the lines of the diff TEXT, read in a buffer of its own."
  (with-temp-buffer
    (diff-mode)
    (insert text)
    (ecc-review--lines)))

(ert-deftest ecc-review-test-locate-note ()
  "A comment stays, follows its line and neighbours, or is outdated."
  (ecc-review-test--with-review session
    (let* ((lines (ecc-review--lines))
           (added (ecc-review-add-note 'user "a" (nth 7 lines)))
           (shifted (ecc-review-test--lines-of
                     (string-replace "@@ -10,2 +10,3 @@" "@@ -10,2 +14,3 @@"
                                     ecc-review-test--diff))))
      ;; The lines next to it on its side are kept with it.
      (should (equal (ecc-review-note-line-before added) "ten"))
      (should (equal (ecc-review-note-line-after added) "eleven"))
      ;; 1. Nothing moved: the same line.
      (should (eq (ecc-review--locate-note added lines) (nth 7 lines)))
      ;; 2. Lines were added above: the line that says the same between
      ;; the same neighbours, nearest.
      (should (equal (plist-get (ecc-review--locate-note added shifted) :line) 15))
      ;; Not further than `ecc-review-note-max-shift'.
      (let ((ecc-review-note-max-shift 3))
        (should-not (ecc-review--locate-note added shifted)))
      ;; 3. The same text between other lines is another line: outdated.
      (setf (ecc-review-note-line-text added) "one")
      (should-not (ecc-review--locate-note added lines))
      ;; A hunk whose header changed still takes a comment on the lines
      ;; it covers; one that moved away from them does not.
      (let ((hunk (ecc-review-add-note 'user "c" (nth 5 lines))))
        (setf (ecc-review-note-hunk-key hunk) '("foo.el" . "@@ -10,2 +10,4 @@"))
        (should (eq (ecc-review--locate-note hunk lines) (nth 5 lines)))
        ;; Away from those lines, a hunk that says the same is the hunk
        ;; pushed down or pulled up -- no further than the line rule's
        ;; `ecc-review-note-max-shift'.
        (setf (ecc-review-note-hunk-range hunk) '(40 . 42))
        (should (eq (ecc-review--locate-note hunk lines) (nth 5 lines)))
        (let ((ecc-review-note-max-shift 3))
          (should-not (ecc-review--locate-note hunk lines)))
        ;; And one that says something else there is another hunk.
        (setf (ecc-review-note-hunk-text hunk) "@@ -40,2 +40,3 @@\n forty\n+other")
        (should-not (ecc-review--locate-note hunk lines))))))

(ert-deftest ecc-review-test-a-blank-line-does-not-wander ()
  "A comment on a blank line goes outdated rather than to another blank line."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer
            (ecc-review-test--fill
             session
             "--- a/b.el\n+++ b/b.el\n@@ -5,0 +6,3 @@\n+(defun a ()\n+\n+  1)\n")
          (ecc-review-test--goto "+")
          (ecc-review-comment "no blank line here")
          (ecc-review-test--fill
           session
           (concat "--- a/b.el\n+++ b/b.el\n@@ -5,0 +6,3 @@\n+(defun a ()\n+  2\n+  1)\n"
                   "@@ -40,0 +41,3 @@\n+(defun b ()\n+\n+  3)\n"))
          (let ((note (car ecc-review--notes)))
            (should (ecc-review-note-outdated note))
            (should (= (ecc-review-note-line note) 7))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-a-look-alike-at-the-same-number-is-not-the-line ()
  "Pushed down by lines added above, a blank line is not the blank line now in its place."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer
            (ecc-review-test--fill
             session
             "--- a/c.el\n+++ b/c.el\n@@ -9,3 +9,3 @@\n (defun a ()\n \n-  1)\n+  2)\n")
          (ecc-review-test--goto " ")
          (ecc-review-comment "about the blank line in a")
          (should (= (ecc-review-note-line (car ecc-review--notes)) 10))
          ;; Three lines above it, the middle one blank: that one is L10 now.
          (ecc-review-test--fill
           session
           (concat "--- a/c.el\n+++ b/c.el\n@@ -8,0 +9,3 @@\n+;; z\n+\n+(z)\n"
                   "@@ -9,3 +12,3 @@\n (defun a ()\n \n-  1)\n+  2)\n"))
          (let ((note (car ecc-review--notes)))
            (should-not (ecc-review-note-outdated note))
            (should (= (ecc-review-note-line note) 13))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-the-edge-of-a-hunk-survives-a-merge ()
  "A line at the edge of a hunk has a neighbour missing, which is not compared."
  (ecc-review-test--with-review session
    (let* ((lines (ecc-review--lines))
           ;; " ten" opens the second hunk: nothing before it.
           (ten (ecc-review-add-note 'user "a" (nth 6 lines)))
           ;; "+TWO" sits between "one" and "three".
           (two (ecc-review-add-note 'user "b" (nth 3 lines)))
           ;; A line added at the top as well, so that neither is at the
           ;; number it had and the neighbours are what decide.
           (merged (ecc-review-test--lines-of
                    (concat "--- a/foo.el\n+++ b/foo.el\n@@ -1,11 +1,13 @@\n+zero\n"
                            " one\n-two\n+TWO\n three\n four\n five\n six\n"
                            " seven\n eight\n nine\n ten\n+added\n eleven\n")))
           (split (ecc-review-test--lines-of
                   (concat "--- a/foo.el\n+++ b/foo.el\n@@ -0,0 +1 @@\n+zero\n"
                           "@@ -2,1 +3,1 @@\n-two\n+TWO\n"))))
      (should-not (ecc-review-note-line-before ten))
      ;; Merged into one hunk, " ten" has "nine" before it now.
      (should (equal (plist-get (ecc-review--locate-note ten merged) :line) 11))
      ;; Split off, "+TWO" has nothing either side, and is still itself.
      (should (equal (plist-get (ecc-review--locate-note two split) :line) 3)))))

(ert-deftest ecc-review-test-the-place-is-read-from-its-hunk-alone ()
  "Remembering the place reads the hunk it is in, not the whole diff."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (cl-letf (((symbol-function 'ecc-review--lines)
               (lambda () (error "The whole diff was read"))))
      (let ((view (car (ecc-review--save-views))))
        (should (equal (ecc-review-note-line (nth 1 view)) 11))))
    ;; On a file header, the first hunk after it.
    (goto-char (point-min))
    (should (equal (ecc-review-note-hunk-key (nth 1 (car (ecc-review--save-views))))
                   '("foo.el" . "@@ -1,3 +1,3 @@")))))

(ert-deftest ecc-review-test-a-comment-reads-the-diff-once ()
  "c reads the lines of the diff once, and draws with them."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (let ((reads 0)
          (lines (symbol-function 'ecc-review--lines)))
      (cl-letf (((symbol-function 'ecc-review--lines)
                 (lambda () (cl-incf reads) (funcall lines))))
        (ecc-review-comment "once"))
      (should (= reads 1)))))

(ert-deftest ecc-review-test-refresh-moves-and-outdates ()
  "A redraw keeps every comment: moved with its line, or marked outdated."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (ecc-review-comment "moves")
    (ecc-review-test--goto "+TWO")
    (ecc-review-comment "goes stale")
    (ecc-review-test--fill session
                           (thread-last ecc-review-test--diff
                                        (string-replace "@@ -10,2 +10,3 @@" "@@ -10,2 +12,3 @@")
                                        (string-replace "+TWO" "+Two")))
    (let ((moves (ecc-review-find-note 1))
          (stale (ecc-review-find-note 2)))
      (should (= (ecc-review-note-line moves) 13))
      (should-not (ecc-review-note-outdated moves))
      (should (ecc-review-note-outdated stale))
      ;; Outdated is drawn above the first hunk of its file, marked.
      (let ((overlay (seq-find (lambda (o) (memq stale (overlay-get o 'ecc-review-notes)))
                               (ecc-review-comment-overlays))))
        (should (string-search "[outdated, was L2 (new)] goes stale"
                               (overlay-get overlay 'before-string)))
        (should (= (overlay-start overlay)
                   (progn (ecc-review-test--goto "@@ -1,3 +1,3 @@") (point)))))
      (should (string-search "(1 outdated)" (ecc-review--header-line)))
      ;; It is still sent, with the hunk it was last seen in.
      (let ((message (ecc-review-buffer-message)))
        (should (string-search "## foo.el  L2 (new) (outdated)\n" message))
        (should (string-search "+TWO" message))
        (should (string-search "## foo.el  L13 (new)\n" message))))))

(ert-deftest ecc-review-test-outdated-are-counted-one-by-one ()
  "A comment that comes back does not hide one that went outdated."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+TWO")
    (ecc-review-comment "a")
    (ecc-review-test--goto "+added")
    (ecc-review-comment "b")
    (ecc-review-test--fill session (string-replace "+TWO" "+Two" ecc-review-test--diff))
    (should (ecc-review-note-outdated (ecc-review-find-note 1)))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments)
                   (push (apply #'format-message format arguments) messages))))
        (ecc-review-test--fill session (string-replace "+added" "+ADDED"
                                                       ecc-review-test--diff)))
      (should-not (ecc-review-note-outdated (ecc-review-find-note 1)))
      (should (ecc-review-note-outdated (ecc-review-find-note 2)))
      (should (member "1 comment no longer matches a line of the diff; kept as outdated"
                      messages)))))

(ert-deftest ecc-review-test-no-comment-reads-no-lines ()
  "Without a comment or a place to keep, drawing reads no line of the diff."
  (ecc-test-with-fake-session session
    (unwind-protect
        (cl-letf (((symbol-function 'ecc-review--lines)
                   (lambda () (error "The lines were read"))))
          (with-current-buffer (ecc-review-test--fill session ecc-review-test--diff)
            (ecc-review--draw-notes)
            (should-not (ecc-review-comment-overlays))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-refill-keeps-the-place ()
  "Reading the diff again keeps point and the window's start on the same lines."
  (ecc-review-test--with-review session
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer (current-buffer))
      (ecc-review-test--goto "+added")
      (forward-char 2)
      (set-window-point (selected-window) (point))
      (set-window-start (selected-window) (line-beginning-position 0))
      (ecc-review-test--fill session ecc-review-test--shifted-diff)
      (let ((added (progn (save-excursion (ecc-review-test--goto "+added") (point)))))
        (should (= (point) (+ added 2)))
        (should (= (window-point (selected-window)) (+ added 2)))
        (should (= (window-start (selected-window))
                   (save-excursion (ecc-review-test--goto " ten") (point))))))
    ;; A buffer shown nowhere keeps its point as well.
    (ecc-review-test--goto "+more")
    (ecc-review-test--fill session ecc-review-test--diff)
    ;; That line is gone: the top, not somewhere arbitrary.
    (should (= (point) (point-min)))
    (ecc-review-test--goto " eleven")
    (ecc-review-test--fill session ecc-review-test--shifted-diff)
    (should (looking-at-p " eleven"))))

(ert-deftest ecc-review-test-comment-while-the-buffer-changes ()
  "What happens while a comment is typed does not change where it goes."
  (ecc-review-test--with-review session
    ;; Claude comments the same line and the diff is read again, with the
    ;; line two further down, while the user is still typing.
    (ecc-review-test--goto "+added")
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (ecc-review-add-note 'claude "Meanwhile" (ecc-review--line-at-point))
                 (ecc-review--draw-notes)
                 (ecc-review-test--fill session ecc-review-test--shifted-diff)
                 "mine")))
      (call-interactively #'ecc-review-comment))
    (let ((mine (car (last ecc-review--notes))))
      (should (equal (ecc-review-note-text mine) "mine"))
      (should (eq (ecc-review-note-author mine) 'user))
      ;; Its own comment, not a reply to what arrived meanwhile.
      (should-not (ecc-review-note-reply-to mine))
      (should (= (ecc-review-note-line mine) 13))
      (should-not (ecc-review-note-outdated mine)))
    ;; The line goes altogether: the text is kept, as outdated.
    (ecc-review-test--goto "+TWO")
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (ecc-review-test--fill session
                                        (string-replace "+TWO" "+Two"
                                                        ecc-review-test--shifted-diff))
                 "about TWO")))
      (call-interactively #'ecc-review-comment))
    (let ((note (car (last ecc-review--notes))))
      (should (equal (ecc-review-note-text note) "about TWO"))
      (should (ecc-review-note-outdated note))
      (should (string-search "about TWO" (ecc-review-buffer-message))))))

(ert-deftest ecc-review-test-message-of-lines-and-replies ()
  "A line comment is headed by its line, a reply quotes Claude, Claude is not sent."
  (ecc-review-test--with-review session
    (let ((lines (ecc-review--lines)))
      (ecc-review-add-note 'claude "Is this a constant?" (nth 7 lines))
      (ecc-review--draw-notes))
    ;; c on a line that has only Claude's comment answers it.
    (ecc-review-test--goto "+added")
    (ecc-review-comment "No, a variable")
    (let ((reply (ecc-review-find-note 2)))
      (should (eq (ecc-review-note-author reply) 'user))
      (should (equal (ecc-review-note-reply-to reply) 1)))
    ;; Drawn under Claude's, indented, each in its own face.
    (let* ((overlay (car (ecc-review-comment-overlays)))
           (text (overlay-get overlay 'after-string)))
      (should (equal (substring-no-properties text)
                     "  ▎ #1 Claude: Is this a constant?\n    ▎ #2 No, a variable\n"))
      (should (eq (get-text-property 3 'face text) 'ecc-review-agent-comment-face))
      (should (eq (get-text-property (- (length text) 3) 'face text)
                  'ecc-review-comment-face)))
    ;; Again on the line edits the reply.
    (ecc-review-comment "No, a variable, and rename it")
    (should (= (length ecc-review--notes) 2))
    (ecc-review-test--goto "-two")
    (ecc-review-comment "keep two")
    (should (equal (ecc-review-buffer-message)
                   (concat ecc-review-header "\n\n"
                           "## foo.el  L2 (old)\n```diff\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n```\n"
                           "Comment: keep two\n\n"
                           "## foo.el  L11 (new)\n```diff\n@@ -10,2 +10,3 @@\n ten\n+added\n eleven\n```\n"
                           "In reply to Claude's #1: Is this a constant?\n"
                           "Comment: No, a variable, and rename it")))
    (should (string-search "comments: 2 yours, 1 Claude's" (ecc-review--header-line)))))

(ert-deftest ecc-review-test-hide-move-and-remove ()
  "a hides Claude's comments, { and } move between comments, d removes either."
  (ecc-review-test--with-review session
    (should (eq (key-binding (kbd "a")) #'ecc-review-toggle-agent))
    (should (eq (key-binding (kbd "{")) #'ecc-review-previous-comment))
    (should (eq (key-binding (kbd "}")) #'ecc-review-next-comment))
    (let ((lines (ecc-review--lines)))
      (ecc-review-add-note 'claude "mine" (nth 3 lines))
      (ecc-review-add-note 'user "yours" (nth 7 lines))
      (ecc-review--draw-notes))
    ;; Moving.
    (goto-char (point-min))
    (ecc-review-next-comment)
    (should (looking-at-p "\\+TWO"))
    (ecc-review-next-comment)
    (should (looking-at-p "\\+added"))
    (should-error (ecc-review-next-comment) :type 'user-error)
    (ecc-review-previous-comment)
    (should (looking-at-p "\\+TWO"))
    (should-error (ecc-review-previous-comment) :type 'user-error)
    ;; Hidden, Claude's is not drawn but still counted.
    (ecc-review-toggle-agent)
    (should (= (length (ecc-review-comment-overlays)) 1))
    (should (string-search "1 Claude's (hidden)" (ecc-review--header-line)))
    (goto-char (point-min))
    (ecc-review-next-comment)
    (should (looking-at-p "\\+added"))
    (ecc-review-toggle-agent)
    (should (= (length (ecc-review-comment-overlays)) 2))
    ;; d removes Claude's too; with nothing on the line it says so.
    (ecc-review-test--goto "+TWO")
    (ecc-review-remove-comment)
    (should (equal (mapcar #'ecc-review-note-text ecc-review--notes) '("yours")))
    (should-error (ecc-review-remove-comment) :type 'user-error)
    ;; Two on one line: which one is asked.
    (ecc-review-test--goto "+added")
    (ecc-review-add-note 'claude "and mine" (ecc-review--line-at-point))
    (ecc-review--draw-notes)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt labels &rest _)
                 (seq-find (lambda (label) (string-prefix-p "#3" label)) labels))))
      (ecc-review-remove-comment))
    (should (equal (mapcar #'ecc-review-note-text ecc-review--notes) '("yours")))
    ;; Ids are never handed out again.
    (ecc-review-test--goto "+TWO")
    (should (= (ecc-review-note-id (ecc-review-comment "again")) 4))))

(ert-deftest ecc-review-test-another-proposal-starts-clean ()
  "Refilling the buffer for another proposal drops the comments of the last."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((buffer (get-buffer-create (ecc-review-buffer-name session))))
          (ecc-review--fill buffer session ecc-review-test--diff nil 'first)
          (with-current-buffer buffer
            (ecc-review-test--goto "+TWO")
            (ecc-review-comment "about the first"))
          (ecc-review--fill buffer session ecc-review-test--diff nil 'first)
          (should (= (length (buffer-local-value 'ecc-review--notes buffer)) 1))
          (ecc-review--fill buffer session ecc-review-test--diff nil 'second)
          (should-not (buffer-local-value 'ecc-review--notes buffer)))
      (ecc-review-test--kill-review-buffers))))

;;;; Reviewing a proposal

(defun ecc-review-test--edit-request (session)
  "Add a pending Edit of /nowhere/r.txt to SESSION, with the file known."
  (let ((request (ecc-test-add-request session "Edit"
                                       '((file_path . "/nowhere/r.txt")
                                         (old_string . "two")
                                         (new_string . "2")))))
    (ecc-model-node-put (ecc-request-node request) 'before "one\ntwo\nthree\n")
    request))

(ert-deftest ecc-review-test-proposal-keeps-its-context ()
  "The proposal diff has its own context, unchanged by the review's."
  (ecc-test-with-fake-session session
    (let ((request (ecc-review-test--edit-request session))
          (before "one\ntwo\nthree\n"))
      (let ((ecc-review-context-lines 0))
        (should (equal (ecc-review-request-diff request before)
                       (concat "--- /nowhere/r.txt\n+++ /nowhere/r.txt\n"
                               "@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n"))))
      (let ((ecc-review-proposal-context-lines 0))
        (should (equal (ecc-review-request-diff request before)
                       (concat "--- /nowhere/r.txt\n+++ /nowhere/r.txt\n"
                               "@@ -2,1 +2,1 @@\n-two\n+2\n")))))))

(ert-deftest ecc-review-test-request-diff ()
  "A proposal is shown as a hunk of the file, or on its own without one."
  (ecc-test-with-fake-session session
    (let ((request (ecc-review-test--edit-request session)))
      (should (equal (ecc-review-request-diff request "one\ntwo\nthree\n")
                     "--- /nowhere/r.txt\n+++ /nowhere/r.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n"))
      (should (equal (ecc-review-request-diff request nil)
                     "--- /dev/null\n+++ /nowhere/r.txt\n@@ -1,1 +1,1 @@\n-two\n+2\n")))
    (let ((request (ecc-test-add-request session "Write"
                                         '((file_path . "/nowhere/w.txt")
                                           (content . "a\nb\n")))))
      (should (equal (ecc-review-request-diff request nil)
                     "--- /dev/null\n+++ /nowhere/w.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n")))
    (should-not (ecc-review-request-diff
                 (ecc-test-add-request session "Bash" '((command . "ls"))) nil))))

(ert-deftest ecc-review-test-request-comment-denies ()
  "Comments on a proposal go back as the message of the deny."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let* ((request (ecc-review-test--edit-request session))
               (buffer (ecc-review-request request)))
          (with-current-buffer buffer
            (should (equal (buffer-name) "*ecc-review: test (proposal)*"))
            (should (eq ecc-review--request request))
            (should (string-search "-two\n+2\n" (buffer-string)))
            (diff-hunk-next)
            (ecc-review-comment "spell it out")
            (ecc-review-send t)
            (with-current-buffer "*ecc-review-message: test*"
              (should (string-prefix-p ecc-review-proposal-header (buffer-string)))
              (should (string-search "## /nowhere/r.txt  L1-L3\n```diff\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n```\nComment: spell it out"
                                     (buffer-string)))
              (ecc-review-message-send)))
          (should-not (buffer-live-p buffer))
          (let ((response (ecc-test-response 0)))
            (should (equal (alist-get 'behavior response) "deny"))
            (should (string-prefix-p ecc-review-proposal-header
                                     (alist-get 'message response))))
          (should-not (ecc-session-pending session))
          (should (eq (ecc-node-status (ecc-request-node request)) 'denied)))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-request-comment-denies-at-once ()
  "Without a prefix the comments on a proposal go straight out as the deny."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let* ((request (ecc-review-test--edit-request session))
               (buffer (ecc-review-request request)))
          (with-current-buffer buffer
            (diff-hunk-next)
            (ecc-review-comment "spell it out")
            (ecc-review-send))
          (should-not (get-buffer "*ecc-review-message: test*"))
          (should-not (buffer-live-p buffer))
          (let ((response (ecc-test-response 0)))
            (should (equal (alist-get 'behavior response) "deny"))
            (should (string-search "Comment: spell it out"
                                   (alist-get 'message response))))
          (should-not (ecc-session-pending session)))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-request-answered-elsewhere ()
  "A proposal answered from the transcript takes its review buffers away."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let* ((request (ecc-review-test--edit-request session))
               (buffer (ecc-review-request request)))
          (with-current-buffer buffer
            (diff-hunk-next)
            (ecc-review-comment "x")
            (ecc-review-send t))
          (should (get-buffer "*ecc-review-message: test*"))
          (with-temp-buffer
            (ecc-perm-respond request 'allow))
          (should-not (buffer-live-p buffer))
          (should-not (get-buffer "*ecc-review-message: test*"))
          ;; Sending from a stale buffer is refused, not sent twice.
          (should-error (ecc-review-request request) :type 'user-error))
      (ecc-review-test--kill-review-buffers))))

;;;; Editing a proposal before allowing it

(ert-deftest ecc-review-test-edit-proposal ()
  "The edited text replaces the proposal in the allow, and a note is queued."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let* ((request (ecc-test-add-request session "Write"
                                              '((file_path . "/nowhere/w.txt")
                                                (content . "hello\n"))))
               (buffer (ecc-review-edit-proposal request)))
          (with-current-buffer buffer
            (should (equal (buffer-name) "*ecc-edit-proposal: test*"))
            (should ecc-review-proposal-mode)
            (should (equal (buffer-string) "hello\n"))
            (should (eq (key-binding (kbd "C-c C-c")) #'ecc-review-proposal-apply))
            (goto-char (point-max))
            (insert "world\n")
            (should (ecc-review-proposal-apply)))
          (should-not (buffer-live-p buffer))
          (let* ((response (ecc-test-response 0))
                 (updated (alist-get 'updatedInput response)))
            (should (equal (alist-get 'behavior response) "allow"))
            (should (equal (alist-get 'content updated) "hello\nworld\n"))
            (should (equal (alist-get 'file_path updated) "/nowhere/w.txt")))
          (should-not (ecc-session-pending session))
          (let ((note (car (ecc-session-input-queue session))))
            (should (string-prefix-p "The user changed the earlier Write (/nowhere/w.txt)" note))
            (should (string-search "```diff\n@@ -1,1 +1,2 @@\n hello\n+world\n```" note))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-edit-proposal-unchanged ()
  "Approving the text as it is allows the call plainly and queues nothing."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let* ((request (ecc-review-test--edit-request session))
               (buffer (ecc-review-edit-proposal request)))
          (with-current-buffer buffer
            (should (equal (buffer-string) "2"))
            (should-not (ecc-review-proposal-apply)))
          (should (equal (alist-get 'behavior (ecc-test-response 0)) "allow"))
          (should (equal (alist-get 'new_string
                                    (alist-get 'updatedInput (ecc-test-response 0)))
                         "2"))
          (should-not (ecc-session-input-queue session)))
      (ecc-review-test--kill-review-buffers))))

;;;; Which range reads the working tree

(defun ecc-review-test--repo (directory)
  "Make DIRECTORY a repository with x.txt and y.txt committed twice.
Returns the path of x.txt."
  (ecc-review-test--git directory "init" "-q")
  (ecc-review-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-test--git directory "config" "user.name" "t")
  (ecc-review-test--write (concat directory "x.txt") "one\ntwo\nthree\n")
  (ecc-review-test--write (concat directory "y.txt") "alpha\n")
  (ecc-review-test--git directory "add" "x.txt" "y.txt")
  (ecc-review-test--git directory "commit" "-q" "-m" "first")
  (ecc-review-test--write (concat directory "y.txt") "alpha\nbeta\n")
  (ecc-review-test--git directory "commit" "-q" "-a" "-m" "second")
  (concat directory "x.txt"))

(ert-deftest ecc-review-test-parse-range ()
  "--staged and --cached are the index; anything else starting with - is refused."
  (should-not (ecc-review-parse-range nil))
  (should (eq (ecc-review-parse-range 'staged) 'staged))
  (should (eq (ecc-review-parse-range "--staged") 'staged))
  (should (eq (ecc-review-parse-range " --cached ") 'staged))
  (should (equal (ecc-review-parse-range " main...HEAD ") "main...HEAD"))
  (should (equal (ecc-review-parse-range "") ""))
  (dolist (option '("--output=/tmp/x" "-p" " --no-index"))
    (should-error (ecc-review-parse-range option) :type 'user-error)))

(ert-deftest ecc-review-test-range-includes-worktree ()
  "git decides whether a range reads the working tree: a lone revision does."
  (skip-unless (executable-find "git"))
  (ecc-review-test--with-directory directory
    (ecc-review-test--repo directory)
    (let ((root (ecc-review-git-root directory)))
      (dolist (range '(nil "" "HEAD" "HEAD~1"))
        (should (ecc-review--range-includes-worktree-p root range)))
      (dolist (range '(staged "HEAD~1..HEAD" "HEAD~1...HEAD" "HEAD^!" "no-such-branch"))
        (should-not (ecc-review--range-includes-worktree-p root range))))))

(ert-deftest ecc-review-test-worktree-commits-leave-untracked-out ()
  "A review of commits shows no untracked file; one against a revision does."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--repo directory)
            (ecc-review-test--write (concat directory "new.txt") "hello\n")
            (setf (ecc-session-project-root session) directory)
            (dolist (range '("HEAD~1..HEAD" "HEAD~1...HEAD" "HEAD^!"))
              (with-current-buffer (ecc-review-worktree-buffer session range)
                (should (string-search "+beta" (buffer-string)))
                (should-not (string-search "new.txt" (buffer-string)))))
            (with-current-buffer (ecc-review-worktree-buffer session "HEAD~1")
              (should (string-search "+beta" (buffer-string)))
              (should (string-search "+hello" (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-staged ()
  "`staged' is the index against HEAD alone, named so, without untracked files."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (ecc-review-test--repo directory)))
            (ecc-review-test--write x "one\n2\nthree\n")
            (ecc-review-test--write (concat directory "y.txt") "gamma\n")
            (ecc-review-test--git directory "add" "y.txt")
            (ecc-review-test--write (concat directory "new.txt") "hello\n")
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-worktree-buffer session "--cached")
              (should (equal (buffer-name) "*ecc-review: test (staged changes)*"))
              (should (eq ecc-review--range 'staged))
              (should (string-search "Working tree (staged changes)" (ecc-review--header-line)))
              (should (string-search "+gamma" (buffer-string)))
              (should-not (string-search "+2" (buffer-string)))
              (should-not (string-search "hello" (buffer-string))))
            ;; Nothing staged is nothing to review.
            (ecc-review-test--git directory "reset" "-q")
            (should-error (ecc-review-worktree-buffer session 'staged) :type 'user-error)
            ;; An option is never handed to git.
            (should-error (ecc-review-worktree-buffer session "--output=x")
                          :type 'user-error)
            (should-not (file-exists-p (concat directory "x"))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-paths ()
  "PATHS narrow the diff and the untracked files, and survive g."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (ecc-review-test--repo directory)))
            (ecc-review-test--write x "one\n2\nthree\n")
            (ecc-review-test--write (concat directory "y.txt") "gamma\n")
            (ecc-review-test--write (concat directory "new.txt") "hello\n")
            (ecc-review-test--write (concat directory "other.txt") "other\n")
            (setf (ecc-session-project-root session) directory)
            (should (equal (sort (ecc-review-worktree-paths directory "HEAD") #'string<)
                           '("new.txt" "other.txt" "x.txt" "y.txt")))
            (should (equal (ecc-review-worktree-paths directory "HEAD~1..HEAD")
                           '("y.txt")))
            (with-current-buffer (ecc-review-worktree-buffer session "HEAD" nil
                                                             '("x.txt" "new.txt"))
              (should (equal ecc-review--paths '("x.txt" "new.txt")))
              (let ((text (buffer-string)))
                (should (string-search "+2" text))
                (should (string-search "+hello" text))
                (should-not (string-search "gamma" text))
                (should-not (string-search "other" text)))
              (ecc-review-test--write x "one\n2\n3\n")
              (ecc-review-refresh)
              (should (equal ecc-review--paths '("x.txt" "new.txt")))
              (should (string-search "+3" (buffer-string)))
              (should-not (string-search "gamma" (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-asks-for-files ()
  "C-u asks for the range, then for the files among those it would show."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (let ((x (ecc-review-test--repo directory))
            (offered nil))
        (ecc-review-test--write x "one\n2\nthree\n")
        (ecc-review-test--git directory "add" "x.txt")
        (ecc-review-test--write (concat directory "new.txt") "hello\n")
        (cl-letf (((symbol-function 'ecc-window-buffer-session) (lambda () session))
                  ((symbol-function 'ecc-window-session-project) (lambda (_) directory))
                  ((symbol-function 'read-string) (lambda (&rest _) "--staged"))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (_prompt candidates &rest _)
                     (setq offered candidates)
                     '("x.txt"))))
          (let ((current-prefix-arg '(4)))
            (should (equal (ecc-review-worktree--read-arguments)
                           (list session 'staged directory
                                 (list (expand-file-name
                                        "x.txt" (ecc-review-git-root directory)))))))
          ;; What is staged, and no untracked file.
          (should (equal offered '("x.txt")))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "--output=x")))
            (let ((current-prefix-arg '(4)))
              (should-error (ecc-review-worktree--read-arguments) :type 'user-error))))))))

;;;; Following the files

(defmacro ecc-review-test--with-watch (&rest body)
  "Run BODY with a timer of the watch of its own, cancelled afterwards."
  (declare (indent 0))
  `(let ((ecc-review--watch-timer nil)
         (ecc-review-auto-refresh t))
     (unwind-protect (progn ,@body)
       (when (timerp ecc-review--watch-timer)
         (cancel-timer ecc-review--watch-timer)))))

(defun ecc-review-test--watch-timers ()
  "Return the timers waiting to read the stale reviews again."
  (seq-filter (lambda (timer) (eq (timer--function timer) #'ecc-review--watch-fire))
              (append timer-list timer-idle-list)))

(defun ecc-review-test--fire (&optional idle)
  "Run the watch timer as it runs with Emacs IDLE seconds idle (default 10)."
  (cl-letf (((symbol-function 'current-idle-time)
             (lambda () (and idle (> idle 0) (seconds-to-time idle))))
            ((symbol-function 'input-pending-p) #'ignore))
    (timer-event-handler ecc-review--watch-timer)))

(defun ecc-review-test--line-at (window)
  "Return the text of the line WINDOW has its point on."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-point window))
      (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(ert-deftest ecc-review-test-watch-follows-the-files ()
  "A tool result marks the review stale; one timer reads it again in place.
The comments and the place in the window are kept, and nothing about the
windows changes: which is selected, what they show, how they are laid out."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-watch
        (let ((other (get-buffer-create "*ecc-review-test prompt*"))
              (configuration (current-window-configuration)))
          (unwind-protect
              (let ((x (ecc-review-test--repo directory)))
                (ecc-review-test--write x "one\n2\nthree\n")
                (setf (ecc-session-project-root session) directory)
                (let* ((review (ecc-review-worktree-buffer session "HEAD"))
                       (selected (progn (delete-other-windows)
                                        (set-window-buffer (selected-window) other)
                                        (selected-window)))
                       (window (split-window)))
                  (set-window-buffer window review)
                  (with-current-buffer review
                    (ecc-review-test--goto "+2")
                    (set-window-point window (point))
                    (ecc-review-comment "why 2"))
                  ;; A line is added above the one commented on.
                  (ecc-review-test--write x "zero\none\n2\nthree\n")
                  (ecc-review--on-session-change session nil)
                  (ecc-review--on-session-change session nil)
                  (ecc-review--on-session-change session nil)
                  (should (buffer-local-value 'ecc-review--stale review))
                  (should (memq #'ecc-review--on-tool-finished ecc-tool-finished-hook))
                  (should (memq #'ecc-review--on-turn-finished ecc-turn-finished-hook))
                  (should (memq #'ecc-review--on-save (default-value 'after-save-hook)))
                  (should (memq #'ecc-review--on-window-buffer-change
                                (default-value 'window-buffer-change-functions)))
                  ;; One timer for the three, and it runs once.
                  (should (= (length (ecc-review-test--watch-timers)) 1))
                  (should-not (timer--repeat-delay ecc-review--watch-timer))
                  (should (string-search "+2" (with-current-buffer review (buffer-string))))
                  (should-not (string-search "zero" (with-current-buffer review
                                                      (buffer-string))))
                  (let ((before (current-window-configuration)))
                    (ecc-review-test--fire 10)
                    (should (compare-window-configurations
                             before (current-window-configuration))))
                  (should-not (ecc-review-test--watch-timers))
                  (should (eq (selected-window) selected))
                  (should (eq (window-buffer selected) other))
                  (should (eq (window-buffer window) review))
                  (with-current-buffer review
                    (should (string-search "+zero" (buffer-string)))
                    (should-not ecc-review--stale)
                    (let ((note (car ecc-review--notes)))
                      (should (equal (ecc-review-note-text note) "why 2"))
                      (should-not (ecc-review-note-outdated note))
                      (should (= (ecc-review-note-line note) 3))))
                  (should (equal (ecc-review-test--line-at window) "+2"))))
            (set-window-configuration configuration)
            (kill-buffer other)
            (ecc-review-test--kill-review-buffers)))))))

(ert-deftest ecc-review-test-watch-hidden-and-other-sessions ()
  "Only a review on the screen is read; a hidden one waits until it is shown.
A session marks its own reviews and those of its repository, not another's."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session one
    (ecc-review-test--with-directory a
      (ecc-review-test--with-directory b
        (ecc-review-test--with-watch
          (let ((two (ecc-model-create-session :name "two" :project-root b))
                (three (ecc-model-create-session :name "three" :project-root a))
                (configuration (current-window-configuration)))
            (unwind-protect
                (let ((xa (ecc-review-test--repo a))
                      (xb (ecc-review-test--repo b)))
                  (ecc-review-test--write xa "one\nA\nthree\n")
                  (ecc-review-test--write xb "one\nB\nthree\n")
                  (setf (ecc-session-project-root one) a)
                  (let ((review-one (ecc-review-worktree-buffer one "HEAD"))
                        (review-two (ecc-review-worktree-buffer two "HEAD")))
                    (delete-other-windows)
                    (set-window-buffer (selected-window) review-one)
                    ;; Another session of the same repository marks it;
                    ;; the session of another repository does not.
                    (ecc-review--on-session-change three nil)
                    (should (buffer-local-value 'ecc-review--stale review-one))
                    (should-not (buffer-local-value 'ecc-review--stale review-two))
                    (ecc-review--on-session-change two nil)
                    (should (buffer-local-value 'ecc-review--stale review-two))
                    (ecc-review-test--write xa "one\nAA\nthree\n")
                    (ecc-review-test--write xb "one\nBB\nthree\n")
                    (ecc-review--refresh-stale)
                    (should (string-search "+AA" (with-current-buffer review-one
                                                   (buffer-string))))
                    ;; Out of sight: still stale, still as it was.
                    (should (buffer-local-value 'ecc-review--stale review-two))
                    (should-not (string-search "+BB" (with-current-buffer review-two
                                                       (buffer-string))))
                    ;; Shown, it asks for the timer, which reads it.
                    (set-window-buffer (selected-window) review-two)
                    (ecc-review--on-window-buffer-change (selected-frame))
                    (should (= (length (ecc-review-test--watch-timers)) 1))
                    (ecc-review-test--fire 10)
                    (should (string-search "+BB" (with-current-buffer review-two
                                                   (buffer-string))))
                    (should-not (buffer-local-value 'ecc-review--stale review-two))))
              (set-window-configuration configuration)
              (ecc-review-test--kill-review-buffers)
              (ecc-test-cleanup-session two)
              (ecc-test-cleanup-session three))))))))

(ert-deftest ecc-review-test-watch-leaves-some-alone ()
  "A proposal is never watched, and nothing is with the setting off."
  (ecc-review-test--with-watch
    (ecc-review-test--with-review session
      (let ((proposal (ecc-review--fill (get-buffer-create "*ecc-review: test (proposal)*")
                                        session ecc-review-test--diff nil 'request)))
        (ecc-review--on-session-change session nil)
        (should (buffer-local-value 'ecc-review--stale (current-buffer)))
        (should-not (buffer-local-value 'ecc-review--stale proposal))
        (setq ecc-review--stale nil)
        (cancel-timer ecc-review--watch-timer)
        (setq ecc-review--watch-timer nil)
        (let ((ecc-review-auto-refresh nil))
          (ecc-review--on-session-change session nil)
          (should-not ecc-review--stale)
          (should-not (ecc-review-test--watch-timers)))))))

(ert-deftest ecc-review-test-watch-on-save ()
  "Saving a file of the repository marks its reviews; one elsewhere does not."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-directory elsewhere
        (ecc-review-test--with-watch
          (unwind-protect
              (let ((x (ecc-review-test--repo directory)))
                (ecc-review-test--write x "one\n2\nthree\n")
                (setf (ecc-session-project-root session) directory)
                (let ((review (ecc-review-worktree-buffer session "HEAD")))
                  (with-current-buffer (find-file-noselect (concat elsewhere "z.txt"))
                    (insert "z")
                    (save-buffer)
                    (kill-buffer))
                  (should-not (buffer-local-value 'ecc-review--stale review))
                  (with-current-buffer (find-file-noselect x)
                    (goto-char (point-max))
                    (insert "four\n")
                    (save-buffer)
                    (kill-buffer))
                  (should (buffer-local-value 'ecc-review--stale review))))
            (ecc-review-test--kill-review-buffers)))))))

(ert-deftest ecc-review-test-watch-an-empty-diff-stays-open ()
  "A review whose changes have gone stays open under watch; g still refuses."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-watch
        (let ((configuration (current-window-configuration)))
          (unwind-protect
              (let* ((x (ecc-review-test--repo directory))
                     (review (progn (ecc-review-test--write x "one\n2\nthree\n")
                                    (setf (ecc-session-project-root session) directory)
                                    (ecc-review-worktree-buffer session "HEAD"))))
                (set-window-buffer (selected-window) review)
                (with-current-buffer review
                  (ecc-review-test--goto "+2")
                  (ecc-review-comment "why 2"))
                (ecc-review-test--git directory "commit" "-q" "-a" "-m" "third")
                (ecc-review--on-session-change session nil)
                (ecc-review--refresh-stale)
                (with-current-buffer review
                  (should (string-search "No change against HEAD" (buffer-string)))
                  (should (equal ecc-review--range "HEAD"))
                  ;; Kept, outdated, and back when the line is.
                  (should (ecc-review-note-outdated (car ecc-review--notes)))
                  (should-error (ecc-review-refresh) :type 'user-error)
                  (ecc-review-test--write x "one\n2\nthree\nfour\n")
                  (ecc-review-test--git directory "reset" "-q" "--soft" "HEAD~1")
                  (ecc-review--on-session-change session nil)
                  (ecc-review--refresh-stale)
                  (should (string-search "+2" (buffer-string)))
                  (should-not (ecc-review-note-outdated (car ecc-review--notes)))))
            (set-window-configuration configuration)
            (ecc-review-test--kill-review-buffers)))))))

(defun ecc-review-test--tool (name &optional input)
  "Return a tool node called NAME with INPUT, as a tool result carries."
  (make-ecc-node :type 'tool :data (list (cons 'name name) (cons 'input input))))

(defun ecc-review-test--watched-repo (session directory)
  "Make DIRECTORY a repository with a change, and return SESSION's review of it."
  (let ((x (ecc-review-test--repo directory)))
    (ecc-review-test--write x "one\n2\nthree\n")
    (setf (ecc-session-project-root session) directory)
    (ecc-review-worktree-buffer session "HEAD")))

(ert-deftest ecc-review-test-watch-timer-waits-for-idleness-not-for-an-idle-period ()
  "After a long idle period the refresh still comes within the delay.
An idle timer set at the idle time so far plus the delay waited for an
idle period as long again once a key was pressed."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-watch
        (let ((configuration (current-window-configuration)))
          (unwind-protect
              (let ((review (ecc-review-test--watched-repo session directory)))
                (set-window-buffer (selected-window) review)
                (ecc-review-test--write (concat directory "x.txt") "one\n22\nthree\n")
                ;; Five minutes of watching Claude work.
                (cl-letf (((symbol-function 'current-idle-time)
                           (lambda () (seconds-to-time 300))))
                  (ecc-review--on-session-change session))
                (should (= (length (ecc-review-test--watch-timers)) 1))
                (should (memq ecc-review--watch-timer timer-list))
                (should-not (timer--repeat-delay ecc-review--watch-timer))
                (should (<= (float-time (time-subtract (timer--time ecc-review--watch-timer)
                                                       nil))
                            ecc-review-auto-refresh-delay))
                ;; A key pressed meanwhile: the user is at work, so it
                ;; waits once more, the same delay, and reads nothing.
                (ecc-review-test--fire nil)
                (should (= (length (ecc-review-test--watch-timers)) 1))
                (should (<= (float-time (time-subtract (timer--time ecc-review--watch-timer)
                                                       nil))
                            ecc-review-auto-refresh-delay))
                (should (buffer-local-value 'ecc-review--stale review))
                ;; Idle for the delay: read.
                (ecc-review-test--fire 1)
                (should-not (ecc-review-test--watch-timers))
                (should (string-search "+22" (with-current-buffer review (buffer-string)))))
            (set-window-configuration configuration)
            (ecc-review-test--kill-review-buffers)))))))

(ert-deftest ecc-review-test-watch-ignores-tools-that-change-nothing ()
  "A Read, a Grep and the like mark nothing stale; a Bash does."
  (ecc-review-test--with-watch
    (ecc-review-test--with-review session
      (dolist (name '("Read" "Grep" "Glob" "WebFetch" "TodoWrite"))
        (ecc-review--on-tool-finished session (ecc-review-test--tool name))
        (should-not ecc-review--stale))
      (let ((ecc-review-unchanging-tool-functions
             (list (lambda (name) (equal name "mcp__x__look")))))
        (ecc-review--on-tool-finished session (ecc-review-test--tool "mcp__x__look"))
        (should-not ecc-review--stale))
      (ecc-review--on-tool-finished session (ecc-review-test--tool "Bash"))
      (should ecc-review--stale))))

(ert-deftest ecc-review-test-an-unchanged-refresh-changes-nothing ()
  "Reading the same diff again neither modifies the buffer nor keeps undo."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((review (ecc-review-test--watched-repo session directory)))
            (with-current-buffer review
              (should (eq buffer-undo-list t))
              (ecc-review-test--goto "+2")
              (ecc-review-comment "why 2")
              (let ((tick (buffer-modified-tick))
                    (overlays (ecc-review-comment-overlays)))
                (setq ecc-review--stale t)
                (ecc-review--reread review t)
                (should (= tick (buffer-modified-tick)))
                (should (equal overlays (ecc-review-comment-overlays)))
                (should-not ecc-review--stale)
                ;; A change is still read.
                (ecc-review-test--write (concat directory "x.txt") "one\n3\nthree\n")
                (ecc-review--reread review t)
                (should (/= tick (buffer-modified-tick)))
                (should (string-search "+3" (buffer-string)))
                (should (eq buffer-undo-list t)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-watch-a-failed-read-is-not-retried ()
  "A review that cannot be read says so once and waits for g."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-watch
        (let ((configuration (current-window-configuration))
              (said nil))
          (unwind-protect
              (let ((review (ecc-review-test--watched-repo session directory))
                    (moved (concat (directory-file-name directory) "-moved")))
                (set-window-buffer (selected-window) review)
                (rename-file (directory-file-name directory) moved)
                (unwind-protect
                    (progn
                      (ecc-review--on-session-change session)
                      (cl-letf (((symbol-function 'message)
                                 (lambda (&rest args) (push (apply #'format args) said))))
                        (ecc-review--refresh-stale))
                      (should (= (length said) 1))
                      (with-current-buffer review
                        (should ecc-review--failed)
                        (should-not ecc-review--stale)
                        (should (string-search "could not read the diff"
                                               (ecc-review--header-line)))
                        (should (string-search "g to retry" (ecc-review--header-line))))
                      ;; Not marked, not read, by the next change.
                      (ecc-review--on-session-change session)
                      (should-not (buffer-local-value 'ecc-review--stale review))
                      (ecc-review--on-window-buffer-change (selected-frame))
                      (should-not (ecc-review-test--watch-timers)))
                  (rename-file moved (directory-file-name directory)))
                ;; g reads it, and it follows the files again.
                (with-current-buffer review
                  (ecc-review-refresh)
                  (should-not ecc-review--failed))
                (ecc-review--on-session-change session)
                (should (buffer-local-value 'ecc-review--stale review)))
            (set-window-configuration configuration)
            (ecc-review-test--kill-review-buffers)))))))

(ert-deftest ecc-review-test-watch-hears-a-session-above-the-repository ()
  "A session rooted above the repository is heard through the file it named."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-watch
        (let* ((project (file-name-as-directory (concat directory "project")))
               (above (ecc-model-create-session :name "above" :project-root directory)))
          (unwind-protect
              (progn
                (make-directory project)
                (let ((review (ecc-review-test--watched-repo session project)))
                  ;; A shell command names no file: not heard.
                  (ecc-review--on-tool-finished above (ecc-review-test--tool "Bash"))
                  (should-not (buffer-local-value 'ecc-review--stale review))
                  (ecc-review--on-tool-finished
                   above (ecc-review-test--tool
                          "Edit" `((file_path . ,(concat project "x.txt")))))
                  (should (buffer-local-value 'ecc-review--stale review))))
            (ecc-review-test--kill-review-buffers)
            (ecc-test-cleanup-session above)))))))

(ert-deftest ecc-review-test-reread-fills-the-buffer-it-is-given ()
  "A review read again goes into its own buffer, whatever it is called now,
and the public builders keep their contract: an empty diff is an error
and makes no buffer."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((review (ecc-review-test--watched-repo session directory)))
            (with-current-buffer review (rename-buffer "*ecc-review renamed*"))
            (ecc-review-test--write (concat directory "x.txt") "one\n3\nthree\n")
            (ecc-review--reread review t)
            (should (string-search "+3" (with-current-buffer review (buffer-string))))
            (should-not (get-buffer "*ecc-review: test (HEAD)*"))
            (ecc-review-test--git directory "commit" "-q" "-a" "-m" "third")
            (should-error (ecc-review-worktree-buffer session "HEAD") :type 'user-error)
            (should-not (get-buffer "*ecc-review: test (HEAD)*"))
            (ecc-review--reread review t)
            (should (string-search "No change against HEAD"
                                   (with-current-buffer review (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-range-arguments ()
  "The range becomes the arguments of git diff in one place."
  (should (equal (ecc-review--range-arguments 'staged) '("--staged")))
  (should-not (ecc-review--range-arguments ""))
  (should-not (ecc-review--range-arguments nil))
  (should (equal (ecc-review--range-arguments "main...HEAD") '("main...HEAD"))))

(ert-deftest ecc-review-test-a-branch-called-staged-is-not-the-index ()
  "The review of the index and of a ref named staged are two buffers."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (ecc-review-test--repo directory)))
            (ecc-review-test--git directory "branch" "staged" "HEAD~1")
            (ecc-review-test--write x "one\n2\nthree\n")
            (ecc-review-test--git directory "add" "x.txt")
            (setf (ecc-session-project-root session) directory)
            (let ((index (ecc-review-worktree-buffer session 'staged))
                  (branch (ecc-review-worktree-buffer session "staged")))
              (should-not (eq index branch))
              (should (string-search "+beta" (with-current-buffer branch (buffer-string))))
              (should-not (string-search "+beta" (with-current-buffer index
                                                   (buffer-string))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-an-edited-review-is-repaired-by-g ()
  "No key of diff-mode edits the review, and g repairs one that was edited."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((review (ecc-review-test--watched-repo session directory)))
            (with-current-buffer review
              (dolist (key '("k" "K" "R" "s" "u" "@" "C-c C-r" "C-c C-s" "C-c C-l"))
                (should (eq (key-binding (kbd key)) #'ecc-review-read-only)))
              (should (eq (command-remapping #'undo) #'ecc-review-read-only))
              (should-error (ecc-review-read-only) :type 'user-error)
              (let ((text (buffer-string)))
                ;; Called directly, as a key that got past the keymap would.
                (ecc-review-test--goto "+2")
                (diff-hunk-kill)
                (should-not (equal text (buffer-string)))
                (ecc-review-refresh)
                (should (equal text (buffer-string))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-g-on-a-failed-review ()
  "g clears the failure: an empty review shows, and a new failure is kept."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((review (ecc-review-test--watched-repo session directory)))
            (with-current-buffer review
              ;; The diff has gone meanwhile: g shows the empty review, the
              ;; header line forgets the failure, and it is watched again.
              (setq ecc-review--failed "could not read")
              (ecc-review-test--git directory "commit" "-q" "-a" "-m" "third")
              (ecc-review-refresh)
              (should-not ecc-review--failed)
              (should (string-search "No change against HEAD" (buffer-string)))
              (should-not (string-search "could not read" (ecc-review--header-line)))
              (should (ecc-review--watched-p review))
              ;; It fails again: the new error is the one kept.
              (setq ecc-review--failed "old")
              (setq default-directory "/nonexistent-ecc-review/")
              (should-error (ecc-review-refresh))
              (should ecc-review--failed)
              (should-not (equal ecc-review--failed "old"))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-g-clears-the-failure-from-the-header ()
  "An unchanged diff read by g takes the failure off the header line."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((review (ecc-review-test--watched-repo session directory)))
            (with-current-buffer review
              (setq ecc-review--failed "the directory was gone")
              (let ((tick (buffer-modified-tick)))
                (ecc-review-refresh)
                (should (= tick (buffer-modified-tick))))
              (should-not (string-search "could not read the diff"
                                         (ecc-review--header-line)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-watch-a-turn-of-reads-reads-nothing ()
  "The end of a turn reads the reviews again only after a tool that can write."
  (ecc-review-test--with-watch
    (ecc-review-test--with-review session
      (clrhash ecc-review--changed-in-turn)
      (ecc-review--on-tool-finished session (ecc-review-test--tool "Read"))
      (ecc-review--on-turn-finished session nil)
      (should-not ecc-review--stale)
      (ecc-review--on-tool-finished session (ecc-review-test--tool "Bash"))
      (setq ecc-review--stale nil)
      (ecc-review--on-turn-finished session nil)
      (should ecc-review--stale)
      ;; And only once: the next turn starts clean.
      (setq ecc-review--stale nil)
      (ecc-review--on-turn-finished session nil)
      (should-not ecc-review--stale)
      (should (memq #'ecc-review--forget-session ecc-session-removed-hook)))))

(ert-deftest ecc-review-test-paths-are-relative-to-the-session ()
  "A relative path is relative to where the session works, a subdirectory too,
and a tool's relative file_path likewise."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-watch
        (unwind-protect
            (let ((sub (file-name-as-directory (concat directory "sub"))))
              (ecc-review-test--repo directory)
              (make-directory sub)
              (ecc-review-test--write (concat sub "foo.el") "foo\n")
              (ecc-review-test--write (concat directory "foo.el") "top\n")
              (setf (ecc-session-project-root session) sub)
              (with-current-buffer (ecc-review-worktree-buffer session "HEAD" nil '("foo.el"))
                (should (equal ecc-review--paths '("sub/foo.el")))
                (should (string-search "+foo" (buffer-string)))
                (should-not (string-search "+top" (buffer-string)))
                ;; Read again from the paths it keeps.
                (ecc-review-test--write (concat sub "foo.el") "foo\nbar\n")
                (ecc-review-refresh)
                (should (string-search "+bar" (buffer-string))))
              (with-current-buffer (ecc-review-buffer session '("foo.el"))
                (should (string-search "+foo" (buffer-string)))
                (should-not (string-search "+top" (buffer-string))))
              ;; A tool's relative path is the session's too, whatever
              ;; buffer is current.
              (let ((default-directory "/"))
                (should (equal (ecc-review--tool-files
                                session (ecc-review-test--tool "Edit" '((file_path . "foo.el"))))
                               (list (concat sub "foo.el"))))))
          (ecc-review-test--kill-review-buffers))))))

(ert-deftest ecc-review-test-a-tracked-symlink-is-itself ()
  "A path that is a symbolic link git tracks names the link, not its target."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--repo directory)
            (make-symbolic-link "x.txt" (concat directory "link.txt"))
            (should (equal (ecc-review--relative (concat directory "link.txt")
                                                 (ecc-review-git-root directory))
                           "link.txt"))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-worktree-buffer session "HEAD" nil '("link.txt"))
              (should (equal ecc-review--paths '("link.txt")))
              (should (string-search "link.txt" (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

(provide 'ecc-review-test)

;;; ecc-review-test.el ends here
