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
  (let ((result (apply #'ecc-git-run directory args)))
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

(ert-deftest ecc-review-test-obsolete-range-names ()
  "The names the range review had in 0.3 resolve to the new ones."
  (require 'ecc-review-ediff)
  (dolist (pair '((ecc-review-worktree . ecc-review-range)
                  (ecc-review-worktree-buffer . ecc-review-range-buffer)
                  (ecc-review-worktree-session . ecc-review-range-session)
                  (ecc-review-ediff-worktree-buffer . ecc-review-ediff-range-buffer)))
    (should (eq (symbol-function (car pair)) (cdr pair)))
    (should (get (car pair) 'byte-obsolete-info)))
  (should (eq (indirect-variable 'ecc-review-worktree-default-range)
              'ecc-review-default-range))
  (should (get 'ecc-review-worktree-default-range 'byte-obsolete-variable)))

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
        (should (equal (ecc-git-root tracked)
                       (file-name-as-directory (file-truename directory))))
        (should (equal (ecc-review-git-tracked (ecc-git-root tracked)
                                               (list tracked untracked))
                       (list tracked)))
        (let ((diff (ecc-review-diff-text (ecc-review-files session))))
          (should diff)
          (should (equal (cdr diff) (ecc-git-root tracked)))
          (should (string-search "diff --git a/x.txt b/x.txt\n" (car diff)))
          (should (string-search "\n-two\n+2\n" (car diff)))
          (should (string-search (format "--- /dev/null\n+++ %s\n@@ -0,0 +1,1 @@\n+hello\n"
                                         untracked)
                                 (car diff)))
          ;; git first, then the file it does not know.
          (should (< (string-search "diff --git" (car diff))
                     (string-search "/dev/null" (car diff)))))))))

;;;; The baseline a session is reviewed against

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
            (should (ecc-git-ensure-baseline session))
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
            (let ((first (ecc-git-ensure-baseline session)))
              (should first)
              ;; The session works, then its CLI is killed and started
              ;; again.  Resuming restarts the process, not the work.
              (ecc-review-test--write (concat directory "x.txt") "two\n")
              (should (equal (ecc-git-ensure-baseline session) first))
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
            (should (ecc-git-ensure-baseline session))
            ;; The session changes a file and commits it, as the project
            ;; asks for: meaningful steps rather than one lump.
            (ecc-review-test--write (concat directory "x.txt") "two\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "step")
            (ecc-review-test--write (concat directory "y.txt") "later\n")
            ;; Against HEAD the committed step is gone.
            (let ((buffer (ecc-review-range-buffer session)))
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
            (should (ecc-git-ensure-baseline session))
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
            (should-not (ecc-git-ensure-baseline session))
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
            (let ((buffer (ecc-review-range-buffer session)))
              (with-current-buffer buffer
                (should (derived-mode-p 'ecc-review-mode))
                (should (equal (buffer-name) "*ecc-review: test (HEAD)*"))
                (should (equal ecc-review--range "HEAD"))
                (should (equal default-directory (ecc-git-root directory)))
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
            (let ((buffer (ecc-review-range-buffer session "")))
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
                   (text (ecc-review-git-untracked (ecc-git-root directory))))
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
                (should (eq (ecc-review-range-session directory) mine))
                (should (eq (ecc-review-range-session other) session)))
            (ecc-test-cleanup-session mine)))))))

(ert-deftest ecc-review-test-worktree-offers-a-session ()
  "A project with no session offers to start one, and takes no for an answer."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (ecc-review-test--with-directory other
        (setf (ecc-session-project-root session) other)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (should-error (ecc-review-range-session directory) :type 'user-error))
        (let ((started nil))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                    ((symbol-function 'ecc-start)
                     (lambda (root &optional _name) (setq started root) session)))
            (should (eq (ecc-review-range-session directory) session))
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
              (with-current-buffer (ecc-review-range-buffer session)
                (should (= (length (ecc-review-hunks)) 1))))
            (let ((ecc-review-context-lines 0))
              (with-current-buffer (ecc-review-range-buffer session)
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
            (let ((error (should-error (ecc-review-range-buffer session "nope...HEAD")
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
            (should (ecc-review--unborn-p (ecc-git-root directory)))
            (let ((buffer (ecc-review-range-buffer session)))
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
            (let ((buffer (ecc-review-range-buffer session)))
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
            (let ((error (should-error (ecc-review-range-buffer session "nope...HEAD")
                                       :type 'user-error)))
              (should (string-search "nope...HEAD" (error-message-string error)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-worktree-needs-git ()
  "A project outside git says so rather than showing an empty diff."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (setf (ecc-session-project-root session) directory)
      (cl-letf (((symbol-function 'ecc-git-root) (lambda (_path) nil)))
        (should-error (ecc-review-range-buffer session) :type 'user-error)))))

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
              (should (eq (key-binding (kbd "n")) #'ecc-review-next-hunk))
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

(ert-deftest ecc-review-test-a-recorded-original-is-hashed-once ()
  "The old side of a file the session recorded is looked up, and hashed, once.
Not by going through every file of the session at every reading, and
not by hashing the whole original again each time."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let* ((paths (ecc-review-test--two-files session directory))
                 (original (ecc-file-entry-original
                            (gethash (car paths) (ecc-session-files session))))
                 (listed 0)
                 (hashed 0)
                 (list-files (symbol-function 'ecc-model-files))
                 (hash (symbol-function 'secure-hash)))
            (with-current-buffer (ecc-review-buffer session)
              (diff-hunk-next)
              (ecc-review-comment "on a")
              (should (equal (ecc-review--base-of (car (ecc-review-hunks)))
                             (list 'recorded (secure-hash 'sha1 original))))
              (cl-letf (((symbol-function 'ecc-model-files)
                         (lambda (&rest arguments)
                           (setq listed (1+ listed))
                           (apply list-files arguments)))
                        ((symbol-function 'secure-hash)
                         (lambda (algorithm object &rest arguments)
                           (when (eq object original)
                             (setq hashed (1+ hashed)))
                           (apply hash algorithm object arguments))))
                ;; Read again whole, twice, though nothing changed.
                (dotimes (_ 2)
                  (setq ecc-review--fingerprint nil)
                  (ecc-review-refresh)))
              (should (= hashed 0))
              ;; The diff itself is made from the session's files.
              (should (<= listed 2))
              (should-not (ecc-review-note-outdated (car ecc-review--notes)))))
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
                    ;; A comment made while the message is read over is
                    ;; not in it, and is left for the next send.
                    (with-current-buffer buffer
                      (diff-hunk-next)
                      (ecc-review-comment "later"))
                    (ecc-review-message-send))
                  (should-not (buffer-live-p message-buffer))
                  ;; Back in the review, which stays open.
                  (should (buffer-live-p buffer))
                  (should (eq (window-buffer (selected-window)) buffer))
                  (with-current-buffer buffer
                    (should (equal (mapcar (lambda (comment) (plist-get comment :comment))
                                           (ecc-review-comments))
                                   '("later")))
                    (should (ecc-review-note-sent (ecc-review-find-note 1))))
                  (let ((sent (car (ecc-test-sent-messages))))
                    (should (equal (alist-get 'type sent) "user"))
                    (should (equal (alist-get 'content (alist-get 'message sent))
                                   (concat expected "\n\n全体: テストも足すこと"))))
                  (should (ecc-session-current-turn session))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-send ()
  "C-c C-c without a prefix sends the comments and keeps the review open."
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
                ;; No buffer to confirm in, and the review stays, the
                ;; comment in it marked sent.
                (should-not (get-buffer "*ecc-review-message: test*"))
                (should (buffer-live-p buffer))
                (should (= (length ecc-review--notes) 1))
                (should (ecc-review-note-sent (car ecc-review--notes)))
                (should (string-search "(1 sent)" (ecc-review--count-string)))
                (should-not (ecc-review-comments))
                (let ((sent (car (ecc-test-sent-messages))))
                  (should (equal (alist-get 'type sent) "user"))
                  (should (equal (alist-get 'content (alist-get 'message sent))
                                 expected)))
                (should (ecc-session-current-turn session)))))
        (ecc-review-test--kill-review-buffers)))))

(defun ecc-review-test--comment-faces ()
  "Return the face each drawn comment of this review starts with, in order."
  (mapcar (lambda (overlay)
            (let ((string (or (overlay-get overlay 'after-string)
                              (overlay-get overlay 'before-string))))
              (get-text-property (string-search "#" string) 'face string)))
          (sort (copy-sequence (ecc-review-comment-overlays))
                (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(ert-deftest ecc-review-test-sent-comment-is-dimmed ()
  "A sent comment is drawn in its own face; one made since in the usual one."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((buffer (progn (ecc-review-test--two-files session directory)
                               (ecc-review-buffer session))))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "sent")
              (should (equal (ecc-review-test--comment-faces) '(ecc-review-comment-face)))
              (ecc-review-send)
              (diff-hunk-next)
              (ecc-review-comment "not yet")
              (should (equal (ecc-review-test--comment-faces)
                             '(ecc-review-sent-comment-face ecc-review-comment-face)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-send-again-sends-the-new-ones ()
  "A second C-c C-c carries only the comments made since the first."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((buffer (progn (ecc-review-test--two-files session directory)
                               (ecc-review-buffer session))))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "first round")
              (ecc-review-send)
              (diff-hunk-next)
              (ecc-review-comment "second round")
              ;; The first is a turn running by now, so this one is
              ;; queued; what it carries is what the send returns.
              (let ((text (ecc-review-send)))
                (should (string-search "Comment: second round" text))
                (should-not (string-search "first round" text)))
              (should (seq-every-p #'ecc-review-note-sent ecc-review--notes))
              (should (buffer-live-p buffer))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-send-with-nothing-left ()
  "With every comment sent, C-c C-c says so and sends nothing; C-u too."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((buffer (progn (ecc-review-test--two-files session directory)
                               (ecc-review-buffer session))))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "once")
              (ecc-review-send)
              (setq ecc-test-sent nil)
              (should (string-search "every comment has been sent"
                                     (cadr (should-error (ecc-review-send)
                                                         :type 'user-error))))
              (should-error (ecc-review-send t) :type 'user-error)
              (should-not (get-buffer "*ecc-review-message: test*"))
              (should-not ecc-test-sent)
              (should (buffer-live-p buffer))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-editing-a-sent-comment-unsends-it ()
  "A sent comment that is edited is sent again, with its new text."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((buffer (progn (ecc-review-test--two-files session directory)
                               (ecc-review-buffer session))))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "draft")
              (ecc-review-send)
              (ecc-review-comment "final")
              (should (= (length ecc-review--notes) 1))
              (should-not (ecc-review-note-sent (car ecc-review--notes)))
              (should (equal (mapcar (lambda (comment) (plist-get comment :comment))
                                     (ecc-review-comments))
                             '("final")))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-sent-mark-survives-a-refresh ()
  "A sent comment is still sent, and still left out, after the diff is read again."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let* ((paths (ecc-review-test--two-files session directory))
                 (buffer (ecc-review-buffer session)))
            (with-current-buffer buffer
              (diff-hunk-next)
              (ecc-review-comment "keep me")
              (ecc-review-send)
              (setf (ecc-file-entry-snapshot
                     (gethash (cadr paths) (ecc-session-files session)))
                    "hello\nworld\n")
              (ecc-review-refresh)
              (should (string-search "+world" (buffer-string)))
              (should (ecc-review-note-sent (car ecc-review--notes)))
              (should-not (ecc-review-note-outdated (car ecc-review--notes)))
              (should-not (ecc-review-comments))
              (should-error (ecc-review-send) :type 'user-error)))
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
                                   (car (ecc-model-queued-texts session)))))
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

(ert-deftest ecc-review-test-the-watch-goes-on-with-a-review ()
  "Saving a file and changing a window reach the reviews once there is one.
Not before: loading the package puts nothing on the global hooks."
  (let ((hooks '(after-save-hook window-buffer-change-functions)))
    (ecc-test-with-global-hooks hooks
      (should-not (memq #'ecc-review--on-save (default-value 'after-save-hook)))
      (should-not (memq #'ecc-review--on-window-buffer-change
                        (default-value 'window-buffer-change-functions)))
      (ecc-review-test--with-review session
        (should (memq #'ecc-review--on-save (default-value 'after-save-hook)))
        (should (memq #'ecc-review--on-window-buffer-change
                      (default-value 'window-buffer-change-functions)))))))

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
  "A comment is on its own line of this reading, carried there when it moved."
  (ecc-review-test--with-review session
    (let* ((lines (ecc-review--lines))
           (added (ecc-review-add-note 'user "a" (nth 7 lines)))
           (hunk (ecc-review-add-note 'user "c" (nth 5 lines))))
      ;; 1. Nothing moved: the same line, the same hunk.
      (should (= (plist-get (ecc-review--locate-note added) :position)
                 (plist-get (nth 7 lines) :position)))
      (should (= (plist-get (ecc-review--locate-note hunk) :position)
                 (plist-get (nth 5 lines) :position)))
      ;; 2. Read again with two lines put in above: where they went.
      (ecc-review-test--fill session ecc-review-test--shifted-diff)
      (let ((lines (ecc-review--lines)))
        (should (equal (plist-get (ecc-review--locate-note added) :line) 13))
        (should (equal (plist-get (plist-get (ecc-review--locate-note hunk) :hunk)
                                  :header)
                       "@@ -10,2 +12,3 @@"))
        ;; 3. A line of that number saying something else is not it.
        (setf (ecc-review-note-line-text added) "one")
        (should-not (ecc-review--locate-note added))))))

(ert-deftest ecc-review-test-a-hunk-that-grows-keeps-its-comment ()
  "A comment on a hunk stays on the hunk still over its lines.
A blank line said the same as a blank line put in forty lines further
down, and that one, being nowhere near, took the comment."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer
            (ecc-review-test--fill session "--- a/b.el\n+++ b/b.el\n@@ -5,0 +6,1 @@\n+\n")
          (ecc-review-test--goto "@@ -5,0 +6,1 @@")
          (ecc-review-comment "why the blank line?")
          (ecc-review-test--fill
           session
           (concat "--- a/b.el\n+++ b/b.el\n@@ -5,0 +6,2 @@\n+\n+(setq x 1)\n"
                   "@@ -40,0 +42,1 @@\n+\n"))
          (let ((note (car ecc-review--notes)))
            (should-not (ecc-review-note-outdated note))
            (should (equal (ecc-review-note-hunk-key note) '("b.el" . "@@ -5,0 +6,2 @@")))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-d-with-a-prefix-offers-every-comment ()
  "C-u d offers every comment of the review, wherever point is."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+TWO")
    (ecc-review-comment "one")
    (ecc-review-test--goto " one")
    (should-error (ecc-review-remove-comment) :type 'user-error)
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt labels &rest _) (setq asked labels) (car labels))))
        (ecc-review-remove-comment t))
      ;; Asked about even when there is one: it was not picked by point.
      (should (= (length asked) 1)))
    (should-not ecc-review--notes)))

(ert-deftest ecc-review-test-a-hunk-comment-follows-the-old-side ()
  "A comment on a whole hunk is found again by the old lines it covered.
A hunk put in above covers the new lines it was on; the old side, the
baseline, does not move.  A hunk that only adds is found by where it
adds."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer
            (ecc-review-test--fill
             session (concat "--- a/b.el\n+++ b/b.el\n@@ -5,0 +6,1 @@\n+added\n"
                             "@@ -100,1 +100,1 @@\n-a\n+b\n"))
          (ecc-review-test--goto "@@ -5,0 +6,1 @@")
          (ecc-review-comment "the addition")
          (ecc-review-test--goto "@@ -100,1 +100,1 @@")
          (ecc-review-comment "the change")
          ;; Fifteen lines put in at line 90 cover new lines 90-104, the
          ;; change's old place; three put in at the top push the addition.
          (ecc-review-test--fill
           session
           (concat "--- a/b.el\n+++ b/b.el\n@@ -0,0 +1,3 @@\n+x\n+y\n+z\n"
                   "@@ -5,0 +9,1 @@\n+added\n"
                   "@@ -89,0 +93,15 @@\n"
                   (mapconcat (lambda (n) (format "+new %d\n" n)) (number-sequence 1 15) "")
                   "@@ -100,1 +118,1 @@\n-a\n+b\n"))
          (should (equal (mapcar (lambda (note)
                                   (and (not (ecc-review-note-outdated note))
                                        (cdr (ecc-review-note-hunk-key note))))
                                 ecc-review--notes)
                         '("@@ -5,0 +9,1 @@" "@@ -100,1 +118,1 @@"))))
      (ecc-review-test--kill-review-buffers))))

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
  "Hunks merging into one or splitting apart leave a comment on its line."
  (ecc-review-test--with-review session
    (let* ((lines (ecc-review--lines))
           ;; " ten" opens the second hunk: nothing before it.
           (ten (ecc-review-add-note 'user "a" (nth 6 lines)))
           ;; "+TWO" sits between "one" and "three".
           (two (ecc-review-add-note 'user "b" (nth 3 lines))))
      ;; A line added at the top as well, so that neither is at the
      ;; number it had.  Merged into one hunk, " ten" has "nine" before it.
      (ecc-review-test--fill
       session (concat "--- a/foo.el\n+++ b/foo.el\n@@ -1,11 +1,13 @@\n+zero\n"
                       " one\n-two\n+TWO\n three\n four\n five\n six\n"
                       " seven\n eight\n nine\n ten\n+added\n eleven\n"))
      (should (equal (mapcar #'ecc-review-note-line (list ten two)) '(11 3)))
      (should-not (seq-some #'ecc-review-note-outdated (list ten two)))
      ;; Split off with no context, "+TWO" has nothing either side, and
      ;; is still itself; " ten" is no line of the diff any more.
      (ecc-review-test--fill
       session (concat "--- a/foo.el\n+++ b/foo.el\n@@ -0,0 +1 @@\n+zero\n"
                       "@@ -2,1 +3,1 @@\n-two\n+TWO\n"))
      (should (= (ecc-review-note-line two) 3))
      (should-not (ecc-review-note-outdated two))
      (should (ecc-review-note-outdated ten)))))

;;;; A comment follows its line as the files change

(defconst ecc-review-test--summary
  (concat "class Summary:\n"
          "    def __init__(self, rows):\n"
          "        self.rows = rows\n"
          "\n"
          "    def total(self):\n"
          "        return sum(self.rows)\n")
  "s.py when the session starts.")

(defconst ecc-review-test--share
  (concat ecc-review-test--summary
          "\n"
          "    def share(self, part):\n"
          "        total = self.total()\n"
          "        return part / total\n")
  "s.py once the session has added share(): one hunk, @@ -6,0 +7,4 @@.
Its last line, \"return part / total\", is L10.")

(defconst ecc-review-test--guarded
  (string-replace "        total = self.total()\n"
                  "        total = self.total()\n        if total == 0:\n            return 0.0\n"
                  ecc-review-test--share)
  "`ecc-review-test--share' with two lines put in above its return, L12 now.")

(defun ecc-review-test--session-review (session directory first)
  "Return the review of SESSION, which changed s.py in DIRECTORY to FIRST.
DIRECTORY is made a repository holding `ecc-review-test--summary' as
s.py when the session starts."
  (ecc-review-test--git directory "init" "-q")
  (ecc-review-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-test--git directory "config" "user.name" "t")
  (ecc-review-test--write (concat directory "s.py") ecc-review-test--summary)
  (ecc-review-test--git directory "add" "s.py")
  (ecc-review-test--git directory "commit" "-q" "-m" "init")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-git-ensure-baseline session))
  (ecc-review-test--write (concat directory "s.py") first)
  (ecc-review-buffer session))

(defmacro ecc-review-test--following (spec &rest body)
  "Run BODY in a review of a repository whose s.py a session changed.
SPEC is (SESSION DIRECTORY FIRST): SESSION and DIRECTORY are bound,
s.py holds FIRST, and BODY runs in the review buffer."
  (declare (indent 1))
  (let ((session (nth 0 spec)) (directory (nth 1 spec)) (first (nth 2 spec)))
    `(progn
       (skip-unless (executable-find "git"))
       (ecc-test-with-fake-session ,session
         (ecc-review-test--with-directory ,directory
           (unwind-protect
               (with-current-buffer (ecc-review-test--session-review
                                     ,session ,directory ,first)
                 ,@body)
             (ecc-review-test--kill-review-buffers)))))))

(defun ecc-review-test--change-and-refresh (directory text)
  "Make s.py in DIRECTORY hold TEXT and read the review again, as g does."
  (ecc-review-test--write (concat directory "s.py") text)
  (ecc-review-refresh))

(ert-deftest ecc-review-test-a-comment-follows-lines-put-in-above-it ()
  "Two lines put in right above a commented line, in its hunk, move the comment.
The line it was on is unchanged, two lines further down, and the review
following the files puts the comment there."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--with-watch
      (let ((configuration (current-window-configuration)))
        (unwind-protect
            (progn
              (set-window-buffer (selected-window) (current-buffer))
              (ecc-review-test--goto "+        return part / total")
              (ecc-review-comment "rows is 0 for an empty file: return 0.0 then")
              (should (= (ecc-review-note-line (car ecc-review--notes)) 10))
              (ecc-review-test--write (concat directory "s.py") ecc-review-test--guarded)
              (ecc-review--on-session-change session nil)
              (ecc-review--refresh-stale)
              (should (string-search "+            return 0.0" (buffer-string)))
              (let ((note (car ecc-review--notes)))
                (should-not (ecc-review-note-outdated note))
                (should (= (ecc-review-note-line note) 12))
                (should (equal (ecc-review-note-line-text note) "        return part / total"))
                ;; Drawn under that line, not as outdated.
                (let ((overlay (car (ecc-review-comment-overlays))))
                  (should (= (overlay-end overlay)
                             (progn (ecc-review-test--goto "+        return part / total")
                                    (line-beginning-position 2))))
                  (should-not (string-search "outdated" (overlay-get overlay 'after-string))))))
          (set-window-configuration configuration))))))

(ert-deftest ecc-review-test-a-comment-follows-lines-put-in-an-earlier-hunk ()
  "Lines put in at the top of the file, a hunk of their own, move the comment."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        total = self.total()")
    (ecc-review-comment "a property?")
    (ecc-review-test--change-and-refresh
     directory (concat "import math\n\n" ecc-review-test--share))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (= (ecc-review-note-line note) 11)))))

(ert-deftest ecc-review-test-a-comment-follows-lines-taken-out-above-it ()
  "Lines taken out above, in its hunk or in an earlier one, move the comment up."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "guard it")
    ;; The line right above it, in the same hunk.
    (ecc-review-test--change-and-refresh
     directory (string-replace "        total = self.total()\n" "" ecc-review-test--share))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (= (ecc-review-note-line note) 9)))
    ;; And a line under the class, a hunk of its own above.
    (ecc-review-test--change-and-refresh
     directory (thread-last ecc-review-test--share
                            (string-replace "        total = self.total()\n" "")
                            (string-replace "        self.rows = rows\n" "")))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (= (ecc-review-note-line note) 8)))))

(ert-deftest ecc-review-test-a-comment-whose-line-changed-is-outdated ()
  "A line whose own text changed, or that is gone, leaves its comment outdated."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "guard it")
    (ecc-review-test--goto "+        total = self.total()")
    (ecc-review-comment "a property?")
    (ecc-review-test--change-and-refresh
     directory (thread-last ecc-review-test--share
                            (string-replace "return part / total"
                                            "return part / total if total else 0.0")
                            (string-replace "        total = self.total()\n" "")))
    (let ((changed (ecc-review-find-note 1))
          (removed (ecc-review-find-note 2)))
      ;; The nearest line that stayed is looked for only for the place
      ;; being read.
      (should-not (and ecc-review--nearest (gethash changed ecc-review--nearest)))
      (should (ecc-review-note-outdated changed))
      (should (= (ecc-review-note-line changed) 10))
      (should (ecc-review-note-outdated removed))
      (should (= (ecc-review-note-line removed) 9)))))

(ert-deftest ecc-review-test-of-two-lines-alike-the-nearest-takes-the-comment ()
  "The same lines in two places: each comment goes to the one nearest it."
  (let ((first (concat "def a(part):\n    total = count()\n    return part / total\n"
                       "\n"
                       "def b(part):\n    total = count()\n    return part / total\n")))
    (ecc-review-test--following (session directory first)
      ;; Both are new lines: the whole file is.
      (ecc-review-test--goto "+    return part / total")
      (ecc-review-comment "in a")
      (forward-line 1)
      (re-search-forward "^\\+    return part / total$")
      (beginning-of-line)
      (ecc-review-comment "in b")
      (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(3 7)))
      (ecc-review-test--change-and-refresh directory (concat "import os\n" first))
      (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(4 8)))
      (should-not (seq-some #'ecc-review-note-outdated ecc-review--notes)))))

(ert-deftest ecc-review-test-a-blank-line-does-not-move-to-the-one-below ()
  "A comment on a blank line taken out does not go to a blank line further down.
The lines below both are the same, but the lines that were below the
comment are above that one."
  (let ((first (concat ecc-review-test--summary "\nx = 1\n\ny = 2\nz = 3\n\nw = 4\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "+x = 1")
      (forward-line 1)
      (ecc-review-comment "no blank line here")
      (should (= (ecc-review-note-line (car ecc-review--notes)) 9))
      (ecc-review-test--change-and-refresh
       directory (string-replace "x = 1\n\n" "x = 1\n" first))
      (should (ecc-review-note-outdated (car ecc-review--notes))))))

(ert-deftest ecc-review-test-a-comment-on-the-old-side-follows-its-line ()
  "A comment on a removed line stays on it as the hunk around it grows."
  (ecc-review-test--following
      (session directory (string-replace "sum(self.rows)" "math.fsum(self.rows)"
                                         ecc-review-test--summary))
    (ecc-review-test--goto "-        return sum(self.rows)")
    (ecc-review-comment "why not sum?")
    (should (equal (list (ecc-review-note-side (car ecc-review--notes))
                         (ecc-review-note-line (car ecc-review--notes)))
                   '(old 6)))
    ;; The line above it goes as well, and lines are put in at the top.
    (ecc-review-test--change-and-refresh
     directory (thread-last ecc-review-test--summary
                            (string-replace "    def total(self):\n"
                                            "    def total(self, start=0):\n")
                            (string-replace "sum(self.rows)" "math.fsum(self.rows)")
                            (concat "import math\n\n")))
    (should (string-search "\n-    def total(self):\n-        return sum(self.rows)\n"
                           (buffer-string)))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (eq (ecc-review-note-side note) 'old))
      (should (= (ecc-review-note-line note) 6)))))

(ert-deftest ecc-review-test-a-hunk-comment-follows-its-hunk ()
  "A comment on the @@ line of a hunk stays on it as the hunk grows and moves."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "@@ -6,0 +7,4 @@ class Summary:")
    (ecc-review-comment "a method of its own?")
    (ecc-review-test--change-and-refresh
     directory (concat "import math\n\n" ecc-review-test--guarded))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (equal (ecc-review-note-hunk-key note) '("s.py" . "@@ -6,0 +9,6 @@ class Summary:"))))))

(ert-deftest ecc-review-test-a-sent-comment-follows-its-line-still-sent ()
  "A comment sent to Claude follows its line and is still drawn as sent."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "rows is 0 for an empty file: return 0.0 then")
    (ecc-review-send)
    (should (ecc-review-note-sent (car ecc-review--notes)))
    (ecc-review-test--change-and-refresh directory ecc-review-test--guarded)
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (= (ecc-review-note-line note) 12))
      (should (ecc-review-note-sent note))
      (should (equal (ecc-review-test--comment-faces) '(ecc-review-sent-comment-face))))))

(ert-deftest ecc-review-test-a-changed-line-does-not-go-to-its-twin-in-another-hunk ()
  "A line rewritten is outdated, even when the same line is in another hunk.
The lines around both are alike too, so nothing but where the line was
tells them apart."
  (let ((first (concat "int f() {\n  if (x)\n    return nil;\n}\n"
                       ecc-review-test--summary
                       "int g() {\n  if (y)\n    return nil;\n}\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "+    return nil;")
      (ecc-review-comment "return 0 here")
      (should (= (ecc-review-note-line (car ecc-review--notes)) 3))
      (ecc-review-test--change-and-refresh
       directory (concat "int f() {\n  if (x)\n    return 0;\n}\n"
                         ecc-review-test--summary
                         "int g() {\n  if (y)\n    return nil;\n}\n"))
      (let ((note (car ecc-review--notes)))
        (should (ecc-review-note-outdated note))
        (should (= (ecc-review-note-line note) 3))))))

(ert-deftest ecc-review-test-a-changed-line-does-not-go-to-its-twin-in-its-hunk ()
  "A line rewritten is outdated, even when the same line is further down its hunk."
  (let ((first (concat ecc-review-test--summary
                       "    def a(self):\n        pass\n    def b(self):\n        pass\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "+        pass")
      (ecc-review-comment "say what a does")
      (should (= (ecc-review-note-line (car ecc-review--notes)) 8))
      (ecc-review-test--change-and-refresh
       directory (concat ecc-review-test--summary
                         "    def a(self):\n        return 1\n    def b(self):\n        pass\n"))
      (let ((note (car ecc-review--notes)))
        (should (ecc-review-note-outdated note))
        (should (= (ecc-review-note-line note) 8))))))

(ert-deftest ecc-review-test-a-comment-follows-a-block-ending-in-a-blank-line ()
  "Lines put in above that end in a blank line move the comment all the same.
A blank line was already below the commented one, in its hunk: the one
put in above reads like it."
  (let ((first (concat ecc-review-test--summary
                       "    def share(self, part):\n"
                       "        total = self.total()\n"
                       "        return part / total\n"
                       "\n"
                       "    def other(self):\n"
                       "        return 1\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "+        return part / total")
      (ecc-review-comment "guard it")
      (should (= (ecc-review-note-line (car ecc-review--notes)) 9))
      (ecc-review-test--change-and-refresh
       directory (string-replace "        return part / total\n"
                                 (concat "        if total == 0:\n            return 0\n\n"
                                         "        return part / total\n")
                                 first))
      (let ((note (car ecc-review--notes)))
        (should-not (ecc-review-note-outdated note))
        (should (= (ecc-review-note-line note) 12))))))

(ert-deftest ecc-review-test-g-keeps-point-near-a-line-that-went ()
  "g with point on a line that went puts it on the nearest line that stayed."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        total = self.total()")
    (forward-char 4)
    (ecc-review-test--change-and-refresh
     directory (string-replace "        total = self.total()\n" "" ecc-review-test--share))
    (should (bolp))
    (should (looking-at-p "^\\+        return part / total$"))
    ;; And on its own line, at the same column, while that stays.
    (forward-char 3)
    (ecc-review-test--change-and-refresh
     directory (concat "import math\n\n"
                       (string-replace "        total = self.total()\n" ""
                                       ecc-review-test--share)))
    (should (= (current-column) 3))
    (should (looking-back "^\\+  " (line-beginning-position)))
    (should (looking-at-p "      return part / total$"))))

(ert-deftest ecc-review-test-a-comment-follows-its-line-when-the-old-side-moves ()
  "A commit under a review of what is not committed moves the old side.
The lines it took in are no change any more, and a comment below them
stays on its line, carried through the old blob against the new."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((s (concat directory "s.py")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write s ecc-review-test--summary)
            (ecc-review-test--git directory "add" "s.py")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--share))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (ecc-review-test--goto "+        return part / total")
              (ecc-review-comment "guard it")
              (ecc-review-test--goto "+import math")
              (ecc-review-comment "not used")
              (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(12 1)))
              ;; The import is committed; share() is still not.
              (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--summary))
              (ecc-review-test--git directory "commit" "-q" "-a" "-m" "import")
              (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--share))
              (ecc-review-refresh)
              (should-not (string-search "+import math" (buffer-string)))
              (let ((guard (ecc-review-find-note 1))
                    (import (ecc-review-find-note 2)))
                (should-not (ecc-review-note-outdated guard))
                (should (= (ecc-review-note-line guard) 12))
                (should (ecc-review-note-outdated import)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-a-file-coming-under-git-keeps-the-review-reading ()
  "A file whose old side appears or goes leaves the review readable.
An untracked file has no old side; added to the index, it has one, and
taken out again it has none.  Lines put in are still matched by their
text; a line of the old side cannot be carried and is outdated."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let* ((x (ecc-review-test--repo directory))
                 (new (concat directory "new.txt")))
            (ecc-review-test--write new "a\nb\nc\n")
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "")
              (ecc-review-test--goto "+b")
              (ecc-review-comment "on b")
              ;; Into the index, and changed: its old side is a blob now.
              (ecc-review-test--git directory "add" "new.txt")
              (ecc-review-test--write new "top\na\nb\nc\n")
              (ecc-review-refresh)
              (should (string-search "+top" (buffer-string)))
              ;; b is no change any more.
              (should (ecc-review-note-outdated (car ecc-review--notes)))
              (ecc-review-test--write new "top\nmore\na\nb\nc\n")
              (ecc-review-refresh)
              (should (string-search "+more" (buffer-string)))
              ;; A tracked file changed, and then taken out of the index.
              (ecc-review-test--write x "one\n2\nthree\n")
              (ecc-review-refresh)
              (ecc-review-test--goto "+2")
              (ecc-review-comment "the new one")
              (ecc-review-test--goto "-two")
              (ecc-review-comment "the old one")
              (ecc-review-test--git directory "rm" "-q" "--cached" "x.txt")
              (ecc-review-refresh)
              (let ((new-side (ecc-review-find-note 2))
                    (old-side (ecc-review-find-note 3)))
                (should-not (ecc-review-note-outdated new-side))
                (should (= (ecc-review-note-line new-side) 2))
                (should (ecc-review-note-outdated old-side)))
              (ecc-review-test--write x "zero\none\n2\nthree\n")
              (ecc-review-refresh)
              (should (= (ecc-review-note-line (ecc-review-find-note 2)) 3))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-a-failure-to-carry-is-logged-and-outdates ()
  "When the comments of a file cannot be carried, they are outdated and the review reads on."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "guard it")
    (let ((logged nil))
      (cl-letf (((symbol-function 'ecc-review-map-lines)
                 (lambda (&rest _) (error "No map today")))
                ((symbol-function 'ecc-log)
                 (lambda (_category format &rest arguments)
                   (push (apply #'format format arguments) logged))))
        (ecc-review-test--change-and-refresh directory ecc-review-test--guarded))
      (should (seq-find (lambda (line) (string-search "No map today" line)) logged))
      (should (ecc-review-note-outdated (car ecc-review--notes))))
    ;; The next reading carries it again, from where it was last.
    (ecc-review-test--change-and-refresh
     directory (concat "import math\n\n" ecc-review-test--guarded))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (= (ecc-review-note-line note) 14)))))

(ert-deftest ecc-review-test-an-outdated-comment-does-not-come-back-to-a-look-alike ()
  "An outdated comment comes back to its own line, not to one that reads like it.
A lone brace taken out leaves its comment outdated; another brace at
the same number later, put in somewhere else, is not that line."
  (let ((first (concat ecc-review-test--summary "f {\n  a\n}\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "+}")
      (ecc-review-comment "close it later")
      (should (= (ecc-review-note-line (car ecc-review--notes)) 9))
      (ecc-review-test--change-and-refresh
       directory (concat ecc-review-test--summary "f {\n  a\n"))
      (should (ecc-review-note-outdated (car ecc-review--notes)))
      ;; A brace at L9 again, but above the class.
      (ecc-review-test--change-and-refresh
       directory (concat "a\nb\nc\nd\ne\nf\ng\nh\n}\n"
                         ecc-review-test--summary "f {\n  a\n"))
      (should (equal (seq-keep (lambda (line)
                                 (and (equal (plist-get line :text) "}")
                                      (plist-get line :line)))
                               (ecc-review--lines))
                     '(9)))
      (should (ecc-review-note-outdated (car ecc-review--notes)))
      ;; Its own brace back where it was: the comment is back.
      (ecc-review-test--change-and-refresh directory first)
      (let ((note (car ecc-review--notes)))
        (should-not (ecc-review-note-outdated note))
        (should (= (ecc-review-note-line note) 9))))))

(ert-deftest ecc-review-test-a-blob-git-does-not-have-outdates-once ()
  "An old side git does not have leaves its comments outdated, and git is asked once.
Two blobs do not change, nor does how one became the other: the diff of
a pair is kept, a failure with it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write (concat directory "s.py") ecc-review-test--summary)
            (ecc-review-test--git directory "add" "s.py")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (let* ((blob (string-trim (ecc-review-test--git directory "rev-parse" "HEAD:s.py")))
                   (missing (make-string 40 ?d))
                   (diff (lambda (id)
                           (format (concat "diff --git a/s.py b/s.py\nindex %s..%s 100644\n"
                                           "--- a/s.py\n+++ b/s.py\n")
                                   id (make-string 40 ?1))))
                   (body (lambda (text)
                           (let ((added (split-string
                                         (string-remove-suffix
                                          "\n" (substring text (length ecc-review-test--summary)))
                                         "\n")))
                             (format "@@ -6,0 +7,%d @@\n%s" (length added)
                                     (mapconcat (lambda (line) (concat "+" line "\n"))
                                                added "")))))
                   (buffer (get-buffer-create (ecc-review-buffer-name session)))
                   (asked 0)
                   (logged 0)
                   (blobs (symbol-function 'ecc-review--blobs)))
              (ecc-review--fill buffer session
                                (concat (funcall diff blob) (funcall body ecc-review-test--share))
                                directory)
              (with-current-buffer buffer
                (ecc-review-test--goto "+        return part / total")
                (ecc-review-comment "guard it"))
              (cl-letf (((symbol-function 'ecc-review--blobs)
                         (lambda (&rest arguments)
                           (cl-incf asked)
                           (apply blobs arguments)))
                        ((symbol-function 'ecc-log)
                         (lambda (&rest _) (cl-incf logged))))
                (dolist (text (list ecc-review-test--guarded
                                    (concat "import math\n\n" ecc-review-test--guarded)))
                  (ecc-review--fill buffer session
                                    (concat (funcall diff missing) (funcall body text))
                                    directory)))
              (with-current-buffer buffer
                (should (ecc-review-note-outdated (car ecc-review--notes))))
              (should (equal (list asked logged) '(1 1)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-the-users-diff-settings-do-not-reach-the-review ()
  "The review reads the same diff whatever the repository's diff settings say.
With `diff.interHunkContext' git fuses two hunks a line apart and shows
the line between them among the changed ones; `diff.noprefix' and
`diff.mnemonicPrefix' name the files otherwise."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (concat directory "x.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--git directory "config" "diff.interHunkContext" "2")
            (ecc-review-test--git directory "config" "diff.noprefix" "true")
            (ecc-review-test--git directory "config" "diff.mnemonicPrefix" "true")
            (ecc-review-test--write x "1\n2\n3\n4\n5\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (let ((first (string-trim (ecc-review-test--git directory "rev-parse" "HEAD:x.txt"))))
              (ecc-review-test--write x "1\nTWO\n3\nFOUR\n5\n")
              (setf (ecc-session-project-root session) directory)
              (with-current-buffer (ecc-review-range-buffer session "HEAD")
                (should (equal (mapcar (lambda (hunk)
                                         (list (plist-get hunk :path) (plist-get hunk :header)))
                                       (ecc-review-hunks))
                               '(("x.txt" "@@ -2 +2 @@") ("x.txt" "@@ -4 +4 @@"))))
                ;; The two old sides are compared line by line, the same.
                (ecc-review-test--git directory "commit" "-q" "-a" "-m" "two")
                (let ((second (string-trim
                               (ecc-review-test--git directory "rev-parse" "HEAD:x.txt"))))
                  (should (equal (ecc-review--base-hunks (list 'blob directory first)
                                                         (list 'blob directory second)
                                                         ecc-review--reading)
                                 '((2 1 2 1) (4 1 4 1))))))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-nothing-is-looked-up-between-a-text-and-its-reading ()
  "A lookup while the review is read again, or after it was edited, is an error.
Its places are on the lines of the last reading, which is not what the
buffer shows: a line found there would be a line of something else."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (ecc-review-comment "here")
    (let ((note (car ecc-review--notes)))
      (should (= (plist-get (ecc-review--locate-note note) :line) 11))
      (ecc-review--begin-reading)
      (should-error (ecc-review--locate-note note))
      (ecc-review-test--fill session ecc-review-test--shifted-diff)
      (should (= (plist-get (ecc-review--locate-note note) :line) 13))
      ;; Edited by a key that got past the keymap.
      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (insert "x\n"))
      (should-error (ecc-review--locate-note note))
      ;; Read again, it is on its line.
      (ecc-review-test--fill session ecc-review-test--shifted-diff)
      (should (= (plist-get (ecc-review--locate-note note) :line) 13)))))

(ert-deftest ecc-review-test-a-reading-reads-its-lines-once ()
  "The lines of a reading are read and indexed once, whatever looks them up."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (ecc-review-comment "here")
    (ecc-review-test--fill session ecc-review-test--shifted-diff)
    (let ((index (ecc-review--reading-index ecc-review--reading)))
      (should index)
      (ecc-review--draw-notes)
      (ecc-review-test--goto "+TWO")
      (ecc-review-comment "and here")
      (ecc-review--locate-note (car ecc-review--notes))
      (should (eq (ecc-review--reading-index ecc-review--reading) index))
      ;; The next reading reads them anew.
      (ecc-review-test--fill session ecc-review-test--diff)
      (should-not (eq (ecc-review--reading-index ecc-review--reading) index)))))

(ert-deftest ecc-review-test-a-file-is-carried-as-one ()
  "When one comment of a file cannot be carried, none of them moves.
Each is left on the line it had in the last reading, outdated, and comes
back from there once a reading can carry it."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+    def share(self, part):")
    (ecc-review-comment "first")
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "second")
    (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(8 10)))
    (let ((calls 0)
          (where (symbol-function 'ecc-review--where)))
      (cl-letf (((symbol-function 'ecc-review--where)
                 (lambda (&rest arguments)
                   (when (= (cl-incf calls) 2)
                     (error "The second one fails"))
                   (apply where arguments)))
                ((symbol-function 'ecc-log) #'ignore))
        (ecc-review-test--change-and-refresh
         directory (concat "import math\n\n" ecc-review-test--share))))
    ;; Neither moved: both are where the last reading had them.
    (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(8 10)))
    (should (seq-every-p #'ecc-review-note-outdated ecc-review--notes))
    (ecc-review-test--change-and-refresh
     directory (concat "import math\n\n" ecc-review-test--guarded))
    (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(10 14)))
    (should-not (seq-some #'ecc-review-note-outdated ecc-review--notes))))

(ert-deftest ecc-review-test-a-hunk-comment-goes-when-half-its-lines-do ()
  "A comment on a hunk follows it while more than half its lines stay.
Once half of them or more changed or went, it is another hunk, and the
comment is outdated."
  (let ((first (concat ecc-review-test--summary
                       "\n    def a(self):\n        return 1\n    def b(self):\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "@@ -6,0 +7,4 @@ class Summary:")
      (ecc-review-comment "two methods")
      ;; One line of four changed.
      (ecc-review-test--change-and-refresh
       directory (concat "import math\n\n" (string-replace "return 1" "return 2" first)))
      (let ((note (car ecc-review--notes)))
        (should-not (ecc-review-note-outdated note))
        (should (equal (cdr (ecc-review-note-hunk-key note)) "@@ -6,0 +9,4 @@ class Summary:")))
      ;; Two of the four that are there now.
      (ecc-review-test--change-and-refresh
       directory (concat "import math\n\n"
                         (thread-last first
                                      (string-replace "return 1" "return 3")
                                      (string-replace "def a" "def x"))))
      (should (ecc-review-note-outdated (car ecc-review--notes))))))

(ert-deftest ecc-review-test-a-failed-refill-lets-the-places-go ()
  "The places read are let go even when reading the diff again fails."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (cl-letf (((symbol-function 'ecc-review--lines) (lambda () (error "No lines"))))
      (should-error (ecc-review-test--fill session ecc-review-test--shifted-diff)))
    (should-not ecc-review--held)))

(ert-deftest ecc-review-test-outdated-comments-are-carried-back-once-a-reading ()
  "Comments outdated together come back by one map, and not in the reading that lost them."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (dolist (line '("+    def share(self, part):" "+        total = self.total()"
                    "+        return part / total"))
      (ecc-review-test--goto line)
      (ecc-review-comment line))
    (let ((maps 0) (wheres 0)
          (map (symbol-function 'ecc-review-map-lines))
          (where (symbol-function 'ecc-review--where)))
      (cl-letf (((symbol-function 'ecc-review-map-lines)
                 (lambda (&rest arguments) (cl-incf maps) (apply map arguments)))
                ((symbol-function 'ecc-review--where)
                 (lambda (&rest arguments)
                   ;; The comments, not the place being read.
                   (when (memq (car arguments) ecc-review--notes)
                     (cl-incf wheres))
                   (apply where arguments))))
        ;; The three lines go: each is looked for once, by one map.
        (ecc-review-test--change-and-refresh
         directory (concat ecc-review-test--summary "\n    def portion(self):\n        pass\n"))
        (should (seq-every-p #'ecc-review-note-outdated ecc-review--notes))
        (should (equal (list maps wheres) '(1 3)))
        ;; The next reading looks for them again, by one map from the
        ;; reading they were last on; the place being read comes by
        ;; another, from the reading before this one.
        (ecc-review-test--change-and-refresh
         directory (concat "import math\n\n" ecc-review-test--summary
                           "\n    def portion(self):\n        pass\n"))
        (should (equal (list maps wheres) '(3 6)))))))

(ert-deftest ecc-review-test-a-textconv-driver-does-not-reach-the-review ()
  "The review shows the lines a file's blobs hold, not what a textconv makes of them.
The diff of two old sides that carries the comments counts the lines of
the blobs, and the review has to count the same ones."
  (skip-unless (and (executable-find "git") (executable-find "tr")))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (concat directory "x.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--git directory "config" "diff.upper.textconv" "tr a-z A-Z")
            (ecc-review-test--write (concat directory ".gitattributes") "*.txt diff=upper\n")
            (ecc-review-test--write x "one\ntwo\nthree\n")
            (ecc-review-test--git directory "add" "x.txt" ".gitattributes")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write x "one\n2\nthree\n")
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (should (string-search "\n-two\n+2\n" (buffer-string)))
              (should-not (string-search "TWO" (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-patches-of-each-edit-keep-their-comments ()
  "A diff made from what the session recorded carries its comments by their text.
Each patch is numbered against the file as its edit found it, and none
names an old side: a patch put in before the others moves no line of
them, and they are not the same old side either."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((first (concat "--- s.py\n+++ s.py\n"
                             "@@ -10,0 +10 @@\n+a\n"
                             "@@ -20,0 +20 @@\n+b\n")))
          (with-current-buffer (ecc-review-test--fill session first)
            (ecc-review-test--goto "+a")
            (ecc-review-comment "on a")
            (ecc-review-test--goto "@@ -20,0 +20 @@")
            (ecc-review-comment "on the hunk of b")
            (ecc-review-test--fill
             session (concat "--- s.py\n+++ s.py\n"
                             "@@ -2,0 +2,2 @@\n+x\n+y\n"
                             "@@ -10,0 +10 @@\n+a\n"
                             "@@ -20,0 +20 @@\n+b\n"))
            (should-not (seq-some #'ecc-review-note-outdated ecc-review--notes))
            (should (= (ecc-review-note-line (ecc-review-find-note 1)) 10))
            (should (equal (cdr (ecc-review-note-hunk-key (ecc-review-find-note 2)))
                           "@@ -20,0 +20 @@"))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-a-file-with-no-header-of-its-own-has-no-old-side ()
  "A file of the diff with no diff line of its own does not take the one above's blob."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer
            (ecc-review-test--fill
             session
             (concat "diff --git a/img.png b/img.png\n"
                     "index 1234567890123456789012345678901234567890..abcdefabcdefabcdefabcdefabcdefabcdefabcd 100644\n"
                     "Binary files a/img.png and b/img.png differ\n"
                     "--- notes.txt\n+++ notes.txt\n@@ -1 +1 @@\n-a\n+b\n"
                     "diff --git a/s.py b/s.py\n"
                     "index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644\n"
                     "--- a/s.py\n+++ b/s.py\n@@ -1 +1 @@\n-c\n+d\n"))
          (let ((hunks (ecc-review-hunks)))
            (should (equal (mapcar (lambda (hunk) (plist-get hunk :path)) hunks)
                           '("notes.txt" "s.py")))
            (should-not (ecc-review--base-of (car hunks)))
            (should (equal (nth 2 (ecc-review--base-of (cadr hunks)))
                           "1111111111111111111111111111111111111111"))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-point-on-a-hunk-goes-to-its-line-that-stayed ()
  "Point on the @@ line of a hunk that went goes to the first of its lines that stayed."
  (let ((first (concat ecc-review-test--summary "    x = 1\n    y = 2\n    z = 3\n")))
    (ecc-review-test--following (session directory first)
      (ecc-review-test--goto "@@ -6,0 +7,3 @@ class Summary:")
      (ecc-review-test--change-and-refresh
       directory (concat ecc-review-test--summary "    x = 1\n    Y = 2\n    Z = 3\n"))
      (should (looking-at-p "^\\+    x = 1$")))))

(ert-deftest ecc-review-test-a-refill-that-fails-saving-the-place-lets-it-go ()
  "The places read are let go even when saving the second of them fails."
  (ecc-review-test--with-review session
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer (current-buffer))
      (ecc-review-test--goto "+added")
      (set-window-point (selected-window) (point))
      (let ((calls 0)
            (view-at (symbol-function 'ecc-review--view-at)))
        (cl-letf (((symbol-function 'ecc-review--view-at)
                   (lambda (position)
                     (when (= (cl-incf calls) 2)
                       (error "The window cannot be read"))
                     (funcall view-at position))))
          (should-error (ecc-review-test--fill session ecc-review-test--shifted-diff)))
        (should (= calls 2))
        (should-not ecc-review--held)))))

(ert-deftest ecc-review-test-a-hunk-comment-counts-its-changed-lines ()
  "With lines of context shown, a hunk whose changed line changed again is outdated.
The context around it stays and is not what the comment was about."
  (let ((ecc-review-context-lines 3)
        (first (concat ecc-review-test--summary "    pass\n")))
    (ecc-review-test--following (session directory first)
      (goto-char (point-min))
      (re-search-forward "^@@ -4,3 \\+4,4 @@")
      (beginning-of-line)
      (ecc-review-comment "why pass?")
      (ecc-review-test--change-and-refresh
       directory (concat ecc-review-test--summary "    return None\n"))
      (should (ecc-review-note-outdated (car ecc-review--notes))))))

(ert-deftest ecc-review-test-an-empty-file-above-lends-no-old-side ()
  "An empty file git added or deleted, right above a recorded file, lends it no blob.
Such a file has a header and an index line and no --- line, so the
recorded file's --- line comes right after its index line."
  (ecc-test-with-fake-session session
    (unwind-protect
        (dolist (empty (list (concat "diff --git a/e b/e\nnew file mode 100644\n"
                                     "index 0000000000000000000000000000000000000000.."
                                     "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n")
                             (concat "diff --git a/d b/d\ndeleted file mode 100644\n"
                                     "index e69de29bb2d1d6434b8b29ae775ad8c2e48c5391.."
                                     "0000000000000000000000000000000000000000\n")))
          (with-current-buffer
              (ecc-review-test--fill
               session (concat empty "--- notes.txt\n+++ notes.txt\n@@ -1 +1 @@\n-a\n+b\n"))
            (let ((hunk (car (ecc-review-hunks))))
              (should (equal (plist-get hunk :path) "notes.txt"))
              (should-not (ecc-review--base-of hunk)))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-a-comment-handed-over-comes-back-to-its-line ()
  "A comment handed to another review is carried from the reading it was last on.
One that went outdated in the review it came from comes back in the one
it is handed to, once its line is there."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "guard it")
    (ecc-review-test--change-and-refresh
     directory (string-replace "return part / total" "return 0" ecc-review-test--share))
    (let ((note (car ecc-review--notes)))
      (should (ecc-review-note-outdated note))
      ;; Its line back, two lines further down, in another review.
      (ecc-review-test--write (concat directory "s.py") ecc-review-test--guarded)
      (with-current-buffer (ecc-review-range-buffer session "HEAD")
        (setq ecc-review--notes (list note))
        (ecc-review--receive ecc-review--notes)
        (ecc-review--draw-notes)
        (should-not (ecc-review-note-outdated note))
        (should (= (ecc-review-note-line note) 12))))))

(ert-deftest ecc-review-test-a-comment-from-no-reading-is-not-trusted-by-number ()
  "A comment that was put on no line has nothing to be carried from, and is outdated.
Its numbers are of no reading known: the same number saying the same is
not enough."
  (ecc-review-test--with-review session
    (let ((logged nil))
      (setq ecc-review--notes
            (list (ecc-review-note-create :id 1 :author 'user :text "from nowhere"
                                          :path "foo.el" :side 'new :line 11
                                          :line-text "added")))
      (cl-letf (((symbol-function 'ecc-log)
                 (lambda (_category format &rest arguments)
                   (push (apply #'format format arguments) logged))))
        (ecc-review-test--fill session ecc-review-test--diff))
      (should (ecc-review-note-outdated (car ecc-review--notes)))
      (should (seq-find (lambda (line) (string-search "no reading" line)) logged)))))

(ert-deftest ecc-review-test-a-failure-reading-a-file-is-carried-like-any ()
  "Reading a file's lines and taking its shape fail like carrying it.
The comments of the file are outdated where they were, the reading is
taken all the same, and the next one carries them from there.  The
shape is tried once, and the failure said once: nothing tries it first
and lets the error go."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "guard it")
    (let ((logged nil)
          (calls 0))
      (cl-letf (((symbol-function 'ecc-review--base-of)
                 (lambda (&rest _) (setq calls (1+ calls)) (error "No header today")))
                ((symbol-function 'ecc-log)
                 (lambda (_category format &rest arguments)
                   (push (apply #'format format arguments) logged))))
        (ecc-review-test--change-and-refresh directory ecc-review-test--guarded))
      (should (= calls 1))
      (should (= (seq-count (lambda (line) (string-search "No header today" line)) logged) 1))
      (should (ecc-review-note-outdated (car ecc-review--notes)))
      (should (ecc-review--reading-current-p)))
    (ecc-review-test--change-and-refresh
     directory (concat "import math\n\n" ecc-review-test--guarded))
    (let ((note (car ecc-review--notes)))
      (should-not (ecc-review-note-outdated note))
      (should (= (ecc-review-note-line note) 14)))))

(ert-deftest ecc-review-test-point-goes-to-the-nearest-line-without-a-second-pass ()
  "Point whose line went is put on the nearest line that stayed from the reading.
The lines of its file are kept for it until then: going through the
whole review again to put point back is a refill's cost twice over.
The pass is counted by the file names it reads, one at each header."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (let ((names 0)
          (restoring nil)
          (name (symbol-function 'ecc-review--hunk-path))
          (restore (symbol-function 'ecc-review--restore-views)))
      (cl-letf (((symbol-function 'ecc-review--hunk-path)
                 (lambda (&rest arguments)
                   (when restoring
                     (setq names (1+ names)))
                   (apply name arguments)))
                ((symbol-function 'ecc-review--restore-views)
                 (lambda (&rest arguments)
                   (setq restoring t)
                   (unwind-protect (apply restore arguments)
                     (setq restoring nil)))))
        (ecc-review-test--change-and-refresh
         directory (string-replace "return part / total" "return 0" ecc-review-test--share)))
      (should (= names 0))
      (should (looking-at-p "^\\+        total = self.total()$")))))

(ert-deftest ecc-review-test-a-file-named-in-japanese-or-with-a-space ()
  "A file whose name has a space or Japanese in it is named as it is, and has its blob.
git C-quotes a name past ASCII unless told not to, and ends one with a
space with a tab on its --- and +++ lines."
  (skip-unless (executable-find "git"))
  (require 'ecc-review-files)
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((names '("日本.txt" "a b.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (dolist (name names)
              (ecc-review-test--write (concat directory name) "one\n"))
            (apply #'ecc-review-test--git directory "add" names)
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (dolist (name names)
              (ecc-review-test--write (concat directory name) "two\n"))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (let ((hunks (ecc-review-hunks)))
                (should (equal (sort (mapcar (lambda (hunk) (plist-get hunk :path)) hunks)
                                     #'string<)
                               (sort (copy-sequence names) #'string<)))
                (dolist (hunk hunks)
                  (should (eq (car-safe (ecc-review--base-of hunk)) 'blob))))
              (should (equal (sort (mapcar (lambda (entry) (plist-get entry :path))
                                           (ecc-review-files--diff-entries))
                                   #'string<)
                             (sort (copy-sequence names) #'string<)))))
        (ecc-review-test--kill-review-buffers)))))

(defconst ecc-review-test--two-patches
  (concat "--- u.txt\n+++ u.txt\n"
          "@@ -10,1 +10,1 @@\n-a old\n+a new\n"
          "@@ -10,1 +10,1 @@\n-b old\n+b new\n")
  "An untracked file edited twice at line 10: two patches with one header.")

(ert-deftest ecc-review-test-of-two-hunks-with-one-header-the-commented-stands-out ()
  "A comment marks the header of its own hunk, not of another with the same header."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer (ecc-review-test--fill session ecc-review-test--two-patches)
          (ecc-review-test--goto "+b new")
          (ecc-review-comment "on b")
          (should (= (length ecc-review--decorations) 1))
          (goto-char (overlay-start (car ecc-review--decorations)))
          (forward-line 1)
          (should (looking-at-p "^-b old$"))
          ;; A comment on the first hunk as a whole marks it too.
          (ecc-review-test--goto "-a old")
          (forward-line -1)
          (ecc-review-comment "on a")
          (should (= (length ecc-review--decorations) 2)))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-two-patches-at-one-number-keep-their-comments ()
  "Two patches of one file at one number are two places, each comment on its own.
A diff made from what the session recorded joins a patch for each edit,
each numbered against the file as its edit found it: an untracked file
edited twice at line 10 has two hunks @@ -10,1 +10,1 @@."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((patches (concat "@@ -10,1 +10,1 @@\n-a old\n+a new\n"
                               "@@ -10,1 +10,1 @@\n-b old\n+b new\n"))
              (under (lambda (text)
                       (save-excursion
                         (ecc-review-test--goto text)
                         (line-beginning-position 2)))))
          (with-current-buffer
              (ecc-review-test--fill session (concat "--- u.txt\n+++ u.txt\n" patches))
            (ecc-review-test--goto "+a new")
            (ecc-review-comment "on a")
            (goto-char (point-min))
            (re-search-forward "^@@ -10,1 \\+10,1 @@$" nil t 2)
            (beginning-of-line)
            (ecc-review-comment "on the second patch")
            (ecc-review-test--goto "+b new")
            (ecc-review-comment "on b")
            (let ((check
                   (lambda ()
                     (should-not (seq-some #'ecc-review-note-outdated ecc-review--notes))
                     (let ((ends (mapcar (lambda (note)
                                           (overlay-end
                                            (seq-find (lambda (overlay)
                                                        (memq note (overlay-get overlay 'ecc-review-notes)))
                                                      (ecc-review-comment-overlays))))
                                         ecc-review--notes)))
                       (should (= (nth 0 ends) (funcall under "+a new")))
                       (should (= (nth 2 ends) (funcall under "+b new")))))))
              (funcall check)
              (should (equal (mapcar #'ecc-review-note-nth ecc-review--notes) '(0 1 1)))
              ;; A patch put in before them: each stays on its own.
              (ecc-review-test--fill
               session (concat "--- u.txt\n+++ u.txt\n@@ -2,0 +2 @@\n+top\n" patches))
              (funcall check)
              (should (equal (mapcar #'ecc-review-note-nth ecc-review--notes) '(0 1 1))))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-c-across-another-proposal-adds-nothing-there ()
  "A comment typed while the review turns to another proposal is not put on that one.
The line c was pressed on is a line of the proposal that went; the same
line of the next is another proposal's line.  The text is in the kill
ring."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((buffer (get-buffer-create (ecc-review-buffer-name session))))
          (ecc-review--fill buffer session ecc-review-test--diff nil 'first)
          (with-current-buffer buffer
            (ecc-review-test--goto "+added")
            (let ((kill-ring nil))
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _)
                           (ecc-review--fill buffer session ecc-review-test--diff nil 'second)
                           "about the first")))
                (should-error (call-interactively #'ecc-review-comment) :type 'user-error))
              (should (equal (car kill-ring) "about the first")))
            (should-not ecc-review--notes)
            (should-not ecc-review--held)))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-a-patch-counts-its-own-changed-lines ()
  "A context line of one patch is not changed because another patch puts a line in at its number.
The hunk comment counts the lines its hunk changes: in a diff of a patch
for each edit, the context line x at 10 shares its number with the Y the
second patch puts in."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((second "@@ -10,1 +10,1 @@\n-y\n+Y\n"))
          (with-current-buffer
              (ecc-review-test--fill
               session (concat "--- u.txt\n+++ u.txt\n@@ -10,2 +10,2 @@\n x\n-a\n+A\n" second))
            (ecc-review-test--goto "@@ -10,2 +10,2 @@")
            (ecc-review-comment "on the first patch")
            ;; Its one line put in changes again: one of its two changed
            ;; lines stayed, which is not more than half.
            (ecc-review-test--fill
             session (concat "--- u.txt\n+++ u.txt\n@@ -10,2 +10,2 @@\n x\n-a\n+A2\n" second))
            (should (ecc-review-note-outdated (car ecc-review--notes)))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-a-recorded-original-is-one-old-side ()
  "A file outside git whose original the session recorded has one old side.
A brace put in, taken out, and put in after another line is not the
brace commented on: by text alone the comment would go to it."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((path (concat directory "x.txt")))
            (ecc-review-test--entry session path :original "a\nb\nc\n"
                                    :snapshot "a\n}\nb\nc\n" :edits 1)
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-buffer session)
              (ecc-review-test--goto "+}")
              (ecc-review-comment "why a brace?")
              (should (= (ecc-review-note-line (car ecc-review--notes)) 2))
              (setf (ecc-file-entry-snapshot (gethash path (ecc-session-files session)))
                    "a\nb\nc\n}\n")
              (ecc-review-refresh)
              (should (string-search "\n+}\n" (buffer-string)))
              (should (ecc-review-note-outdated (car ecc-review--notes)))))
        (ecc-review-test--kill-review-buffers)))))

(defun ecc-review-test--two-repositories (session directory)
  "Make DIRECTORY hold two repositories, each with x.txt, changed by SESSION.
SESSION works in DIRECTORY, which is in no repository.  Return the
paths of the two x.txt."
  (let ((paths nil))
    (dolist (name '("one" "two"))
      (let ((root (file-name-as-directory (concat directory name))))
        (make-directory root)
        (ecc-review-test--git root "init" "-q")
        (ecc-review-test--git root "config" "user.email" "t@example.com")
        (ecc-review-test--git root "config" "user.name" "t")
        (ecc-review-test--write (concat root "x.txt") (format "%s\na\nb\nc\n" name))
        (ecc-review-test--git root "add" "x.txt")
        (ecc-review-test--git root "commit" "-q" "-m" "init")
        (ecc-review-test--write (concat root "x.txt") (format "%s\na\nB\nc\n" name))
        (ecc-review-test--entry session (concat root "x.txt") :edits 1)
        (push (concat root "x.txt") paths)))
    (setf (ecc-session-project-root session) directory)
    (nreverse paths)))

(ert-deftest ecc-review-test-two-repositories-with-one-name ()
  "Two repositories with the same file are two files, each carried in its own.
The second repository's files are named from the first, and the old
side of each is diffed where its blobs are: a commit in the second moves
the comment on it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((paths (ecc-review-test--two-repositories session directory)))
            (with-current-buffer (ecc-review-buffer session)
              (let ((names (mapcar (lambda (hunk) (plist-get hunk :path)) (ecc-review-hunks))))
                (should (= (length (delete-dups (copy-sequence names))) 2))
                (should (member "x.txt" names))
                (let* ((other (seq-find (lambda (name) (string-prefix-p "../" name)) names))
                       (root (file-name-directory (expand-file-name other default-directory))))
                  (should (file-exists-p (expand-file-name other default-directory)))
                  ;; A comment on the B of each.
                  (goto-char (point-min))
                  (while (re-search-forward "^\\+B$" nil t)
                    (beginning-of-line)
                    (ecc-review-comment "upper case")
                    (forward-line 1))
                  (should (= (length ecc-review--notes) 2))
                  ;; Two lines committed at the top of the other one; its B
                  ;; is still a change.
                  (let ((name (file-name-nondirectory (directory-file-name root))))
                    (ecc-review-test--write (concat root "x.txt")
                                            (format "top\ntop\n%s\na\nb\nc\n" name))
                    (ecc-review-test--git root "commit" "-q" "-a" "-m" "top")
                    (ecc-review-test--write (concat root "x.txt")
                                            (format "top\ntop\n%s\na\nB\nc\n" name)))
                  (ecc-review-refresh)
                  (should-not (seq-some #'ecc-review-note-outdated ecc-review--notes))
                  (should (equal (sort (mapcar #'ecc-review-note-line ecc-review--notes) #'<)
                                 '(3 5)))
                  (ignore paths)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-git-failing-to-run-is-asked-again ()
  "Git failing to run is not taken for an answer: the next reading asks again."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((s (concat directory "s.py")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write s ecc-review-test--summary)
            (ecc-review-test--git directory "add" "s.py")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--share))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (ecc-review-test--goto "+        return part / total")
              (ecc-review-comment "guard it")
              (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--summary))
              (ecc-review-test--git directory "commit" "-q" "-a" "-m" "import")
              (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--share))
              (cl-letf (((symbol-function 'ecc-review--blobs) #'ignore))
                (ecc-review-refresh))
              (should (ecc-review-note-outdated (car ecc-review--notes)))
              (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--guarded))
              (ecc-review-refresh)
              (let ((note (car ecc-review--notes)))
                (should-not (ecc-review-note-outdated note))
                (should (= (ecc-review-note-line note) 14)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-a-newline-put-at-the-end-is-one-old-side ()
  "Two old blobs that differ only in the newline at the end are one old side.
No line of the one is not in the other; that is no hunks, and no comment
goes outdated for it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((s (concat directory "s.py")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write s (string-remove-suffix "\n" ecc-review-test--summary))
            (ecc-review-test--git directory "add" "s.py")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write s ecc-review-test--share)
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (ecc-review-test--goto "+        return part / total")
              (ecc-review-comment "guard it")
              ;; A commit of the newline at the end, and nothing else.
              (ecc-review-test--write s ecc-review-test--summary)
              (ecc-review-test--git directory "commit" "-q" "-a" "-m" "newline")
              (ecc-review-test--write s ecc-review-test--share)
              (ecc-review-refresh)
              (let ((note (car ecc-review--notes)))
                (should-not (ecc-review-note-outdated note))
                (should (= (ecc-review-note-line note) 10)))
              (ecc-review-refresh)
              (should-not (ecc-review-note-outdated (car ecc-review--notes)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-a-recorded-file-below-a-file-with-no-hunk ()
  "A recorded file right below a git file that has no hunk keeps its recorded old side.
A mode changed, an empty file added, a file renamed whole: git writes a
header and no hunk for each, and the recorded file's --- line comes
right after it."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((path (expand-file-name "x.txt" temporary-file-directory)))
          (ecc-review-test--entry session path :original "a\n" :snapshot "a\nb\n" :edits 1)
          (dolist (above (list "diff --git a/m b/m\nold mode 100644\nnew mode 100755\n"
                               (concat "diff --git a/e b/e\nnew file mode 100644\n"
                                       "index 0000000000000000000000000000000000000000.."
                                       "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n")
                               (concat "diff --git a/o b/n\nsimilarity index 100%\n"
                                       "rename from o\nrename to n\n")))
            (with-current-buffer
                (ecc-review-test--fill
                 session (concat above (format "--- %s\n+++ %s\n@@ -1,0 +2 @@\n+b\n" path path)))
              (let ((hunk (car (ecc-review-hunks))))
                (should (equal (plist-get hunk :path) path))
                (should (equal (ecc-review--base-of hunk)
                               (list 'recorded (secure-hash 'sha1 "a\n"))))))))
      (ecc-review-test--kill-review-buffers))))

(ert-deftest ecc-review-test-one-repository-has-one-name ()
  "A repository is named the same however it is reached: through ~, through a link."
  (ecc-review-test--with-directory directory
    (should (equal (ecc-review-repository-name (abbreviate-file-name directory))
                   (ecc-review-repository-name (file-truename directory))))
    (should (equal (ecc-review-repository-name (directory-file-name directory))
                   (ecc-review-repository-name directory)))))

(ert-deftest ecc-review-test-a-rename-in-another-repository-is-named-there ()
  "A file renamed whole in a second repository is named from the first, like its diff line."
  (require 'ecc-review-files)
  (let ((header (concat "diff --git a/../two/old.txt b/../two/new.txt\n"
                        "similarity index 100%\nrename from old.txt\nrename to new.txt\n")))
    (should (equal (ecc-review-files--header-path header) "../two/new.txt"))
    (should (equal (ecc-review-files--under header) "../two/")))
  (should (equal (ecc-review-files--header-path
                  "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n")
                 "new.txt"))
  ;; A new name that holds the old one and \" b/\" can be matched at the
  ;; wrong place by a search for the old one: the line is split by both.
  (let ((header (concat "diff --git a/../two/s b/../two/s b/s\n"
                        "similarity index 100%\nrename from s\nrename to s b/s\n")))
    (should (equal (ecc-review-files--under header) "../two/"))
    (should (equal (ecc-review-files--header-path header) "../two/s b/s")))
  ;; Names git quotes, with a double quote and a tab in them.
  (let ((header (concat "diff --git \"a/../two/o\\\"ld\" \"b/../two/n\\tew\"\n"
                        "similarity index 100%\nrename from \"o\\\"ld\"\nrename to \"n\\tew\"\n")))
    (should (equal (ecc-review-files--under header) "../two/"))
    (should (equal (ecc-review-files--header-path header) "../two/n\tew"))))

(ert-deftest ecc-review-test-a-file-is-named-once-a-reading ()
  "A reading reads the lines of a file with the file's name read once, at its header.
Not again at each of its hunks, which goes back up through the hunks
before it."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (ecc-review-comment "here")
    (let ((names 0)
          (name (symbol-function 'ecc-review--hunk-path)))
      (cl-letf (((symbol-function 'ecc-review--hunk-path)
                 (lambda (&rest arguments)
                   (setq names (1+ names))
                   (apply name arguments))))
        ;; A reading with no lines handed in goes through the review.
        (ecc-review--take-reading))
      ;; One file, two hunks.
      (should (= names 1))
      (should-not (ecc-review-note-outdated (car ecc-review--notes))))))

(ert-deftest ecc-review-test-names-git-quotes-are-read-as-they-are ()
  "git C-quotes a name with a tab, a newline, a double quote or a backslash in it.
Even with `core.quotePath' off; the review decodes it wherever a name
is read from a header, and an octal escape is a byte of UTF-8."
  (should (equal (ecc-review-git-name "\"b/a\\\"b.txt\"") "b/a\"b.txt"))
  (should (equal (ecc-review-git-name "\"b/t\\tab\\\\x\"") "b/t\tab\\x"))
  (should (equal (ecc-review-git-name "\"\\346\\227\\245.txt\"") "日.txt"))
  (should (equal (ecc-review-git-name "b/a b.txt\t") "b/a b.txt"))
  (should (equal (ecc-review-git-diff-names "diff --git a/a b.txt b/a b.txt")
                 '("a/a b.txt" . "b/a b.txt")))
  (should (equal (ecc-review-git-diff-names "diff --git a/x \"b/x\\ty\"") '("a/x" . "b/x\ty")))
  (should-not (ecc-review-git-diff-names "diff --git a/x y b/x z"))
  ;; What the review writes itself is read back the same way.
  (dolist (name '("plain.txt" "a b.txt" "a\"b.txt" "t\tab\\x" "日本.txt" "bell\a"))
    (should (equal (ecc-review-git-name (ecc-review--git-quote name)) name)))
  (should (equal (ecc-review--git-quote "a b.txt") "a b.txt"))
  (should (equal (ecc-review--git-quote "a\"b") "\"a\\\"b\"")))

(ert-deftest ecc-review-test-names-are-quoted-as-git-quotes-them ()
  "A name the review writes is quoted as git quotes it, DEL and letter escapes too."
  (skip-unless (executable-find "git"))
  (ecc-review-test--with-directory directory
    (let ((names (list "plain.txt" "a b.txt" "a\"b.txt" "t\tab" "d\177el" "b\aell"
                       "v\vf\fr\rx" "esc\ex" "日本.txt")))
      (ecc-review-test--git directory "init" "-q")
      (dolist (name names)
        (ecc-review-test--write (concat directory name) "x\n"))
      (apply #'ecc-review-test--git directory "add" "--" names)
      (should (equal (sort (split-string (ecc-review-test--git directory "-c" "core.quotePath=false"
                                                               "ls-files")
                                         "\n" t)
                           #'string<)
                     (sort (mapcar #'ecc-review--git-quote names) #'string<)))
      (dolist (name names)
        (should (equal (ecc-review-git-name (ecc-review--git-quote name)) name))))))

(ert-deftest ecc-review-test-a-file-whose-name-git-quotes ()
  "A file named with a double quote or a tab has its name, its blob and its comment.
Its comment is carried across a commit through its blob."
  (skip-unless (executable-find "git"))
  (require 'ecc-review-files)
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((names '("a\"b.txt" "t\tab.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (dolist (name names)
              (ecc-review-test--write (concat directory name) (ecc-review-test--numbered 1 5)))
            (apply #'ecc-review-test--git directory "add" names)
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (dolist (name names)
              (ecc-review-test--write (concat directory name)
                                      (concat (ecc-review-test--numbered 1 3) "X\n"
                                              (ecc-review-test--numbered 4 5))))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (should (string-search "\"b/a\\\"b.txt\"" (buffer-string)))
              (let ((hunks (ecc-review-hunks)))
                (should (equal (sort (mapcar (lambda (hunk) (plist-get hunk :path)) hunks)
                                     #'string<)
                               (sort (copy-sequence names) #'string<)))
                (dolist (hunk hunks)
                  (should (eq (car-safe (ecc-review--base-of hunk)) 'blob))))
              (should (equal (sort (mapcar (lambda (entry) (plist-get entry :path))
                                           (ecc-review-files--diff-entries))
                                   #'string<)
                             (sort (copy-sequence names) #'string<)))
              (ecc-review-test--goto "+X")
              (ecc-review-comment "on X")
              (let ((note (ecc-review-find-note 1)))
                ;; The old side moves by two lines under it.
                (ecc-review-test--write (concat directory (ecc-review-note-path note))
                                        (concat "p1\np2\n" (ecc-review-test--numbered 1 5)))
                (ecc-review-test--git directory "commit" "-q" "-a" "-m" "p")
                (ecc-review-test--write (concat directory (ecc-review-note-path note))
                                        (concat "p1\np2\n" (ecc-review-test--numbered 1 3) "X\n"
                                                (ecc-review-test--numbered 4 5)))
                (ecc-review-refresh)
                (should-not (ecc-review-note-outdated note))
                (should (= (ecc-review-note-line note) 6)))))
        (ecc-review-test--kill-review-buffers)))))

(defmacro ecc-review-test--failing-once (function kind &rest body)
  "Run BODY with FUNCTION signalling KIND, `error' or `quit', the first time it is called."
  (declare (indent 2))
  (let ((failed (make-symbol "failed"))
        (original (make-symbol "original")))
    `(let ((,failed nil)
           (,original (symbol-function ,function)))
       (cl-letf (((symbol-function ,function)
                  (lambda (&rest arguments)
                    (if ,failed
                        (apply ,original arguments)
                      (setq ,failed t)
                      (if (eq ,kind 'quit)
                          (signal 'quit nil)
                        (error "Injected into %s" ,function))))))
         ,@body))))

(defconst ecc-review-test--refill-steps
  '(ecc-review--save-views ecc-review--lines ecc-review--take-reading
    ecc-review--diff-moved-blobs ecc-review--diff-blobs ecc-review--blobs
    ecc-review--cat-file ecc-review-map-text-hunks ecc-review-map-lines ecc-review--carry-file
    ecc-review--draw-notes ecc-review--restore-views)
  "The steps of a refill of the diff review, each made to fail in turn.")

(defun ecc-review-test--typing-loses-nothing (comment)
  "Type a comment with COMMENT, the command of c, and check that the text is kept.
Either the comment is made, or the text is in the kill ring -- once it
was typed: c may stop before it asks for any."
  (let ((kill-ring nil)
        (typed nil))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (setq typed t) "typed"))
              ((symbol-function 'completing-read)
               (lambda (_prompt labels &rest _)
                 (or (seq-find (lambda (label) (string-search "new comment" label)) labels)
                     (car labels)))))
      (condition-case nil
          (call-interactively comment)
        ((error quit) nil)))
    (should (or (not typed)
                (member "typed" kill-ring)
                (seq-find (lambda (note) (equal (ecc-review-note-text note) "typed"))
                          ecc-review--notes)))))

(ert-deftest ecc-review-test-a-refill-failing-at-any-step-recovers ()
  "Whatever step of a refill fails or is quit, nothing typed is lost and g recovers.
The comment comes back to its line, carried from where it was."
  (skip-unless (executable-find "git"))
  (dolist (step ecc-review-test--refill-steps)
    (dolist (kind '(error quit))
      (ecc-test-with-fake-session session
        (ecc-review-test--with-directory directory
          (unwind-protect
              (let ((s (concat directory "s.py")))
                (ecc-review-test--git directory "init" "-q")
                (ecc-review-test--git directory "config" "user.email" "t@example.com")
                (ecc-review-test--git directory "config" "user.name" "t")
                (ecc-review-test--write s ecc-review-test--summary)
                (ecc-review-test--git directory "add" "s.py")
                (ecc-review-test--git directory "commit" "-q" "-m" "init")
                (ecc-review-test--write s ecc-review-test--share)
                (setf (ecc-session-project-root session) directory)
                (with-current-buffer (ecc-review-range-buffer session "HEAD")
                  (ecc-review-test--goto "+        return part / total")
                  (ecc-review-comment "guard it")
                  ;; A commit moves the old side: every step has work.
                  (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--summary))
                  (ecc-review-test--git directory "commit" "-q" "-a" "-m" "import")
                  (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--share))
                  (ecc-review-test--failing-once step kind
                    (condition-case nil (ecc-review-refresh) ((error quit) nil)))
                  ;; Drawn before any g, as a comment of Claude's draws:
                  ;; either the reading is whole, or nothing is looked up.
                  (condition-case nil (ecc-review--draw-notes) (error nil))
                  (let ((note (ecc-review-find-note 1)))
                    (should (or (ecc-review-note-outdated note)
                                (not (ecc-review--reading-current-p))
                                ;; On its line of the text shown, read
                                ;; again or not.
                                (= (ecc-review-note-line note)
                                   (if (string-search "@@ -8,0 +9,4 @@" (buffer-string)) 12 10)))))
                  (goto-char (point-min))
                  (when (re-search-forward "^\\+    def share" nil t)
                    (beginning-of-line))
                  (ecc-review-test--typing-loses-nothing #'ecc-review-comment)
                  (ecc-review-refresh)
                  (should (ecc-review--reading-current-p))
                  (let ((note (ecc-review-find-note 1)))
                    (should-not (ecc-review-note-outdated note))
                    (should (= (ecc-review-note-line note) 12)))))
            (ecc-review-test--kill-review-buffers)))))))

(defun ecc-review-test--numbered (from to)
  "Return the lines aFROM to aTO, each with its newline."
  (mapconcat (lambda (i) (format "a%d\n" i)) (number-sequence from to) ""))

(ert-deftest ecc-review-test-a-reading-stopped-while-carrying-is-no-reading ()
  "A refill quit while the old sides are read leaves nothing to look a comment up in.
Its comments are still on the reading they are carried from.  Drawn
before \\`g', one would be found by its old number on a line that only
reads alike -- here an X put in at L10, the number the commented X had
-- and kept there for good.  g carries it to its own line, L13."
  (skip-unless (executable-find "git"))
  (dolist (step '(ecc-review--diff-moved-blobs ecc-review--cat-file))
    (ecc-test-with-fake-session session
      (ecc-review-test--with-directory directory
        (unwind-protect
            (let ((x (concat directory "x.txt")))
              (ecc-review-test--git directory "init" "-q")
              (ecc-review-test--git directory "config" "user.email" "t@example.com")
              (ecc-review-test--git directory "config" "user.name" "t")
              (ecc-review-test--write x (ecc-review-test--numbered 1 20))
              (ecc-review-test--git directory "add" "x.txt")
              (ecc-review-test--git directory "commit" "-q" "-m" "init")
              (ecc-review-test--write x (concat (ecc-review-test--numbered 1 9) "X\n"
                                                (ecc-review-test--numbered 10 20)))
              (setf (ecc-session-project-root session) directory)
              (with-current-buffer (ecc-review-range-buffer session "HEAD")
                (ecc-review-test--goto "+X")
                (ecc-review-comment "about X")
                (should (= (ecc-review-note-line (ecc-review-find-note 1)) 10))
                ;; Two lines committed at the top: the X is L12 of the old
                ;; side's numbering, and L13 with another X put in at L10.
                (ecc-review-test--write x (concat "p1\np2\n" (ecc-review-test--numbered 1 20)))
                (ecc-review-test--git directory "commit" "-q" "-a" "-m" "p")
                (ecc-review-test--write x (concat "p1\np2\n" (ecc-review-test--numbered 1 7) "X\n"
                                                  (ecc-review-test--numbered 8 9) "X\n"
                                                  (ecc-review-test--numbered 10 20)))
                (ecc-review-test--failing-once step 'quit
                  (condition-case nil (ecc-review-refresh) (quit nil)))
                ;; As a comment of Claude's draws, before any g.
                (condition-case nil (ecc-review--draw-notes) (error nil))
                (ecc-review-refresh)
                (let ((note (ecc-review-find-note 1)))
                  (should-not (ecc-review-note-outdated note))
                  (should (= (ecc-review-note-line note) 13)))))
          (ecc-review-test--kill-review-buffers))))))

(ert-deftest ecc-review-test-index-lines-are-short-and-the-blob-is-whole ()
  "An index line shows git's short ids, and the old side is still the whole blob.
The review asks git for whole ids, which a comment is carried by; shown,
two of them make a line of 92 characters for every file."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (concat directory "x.txt")))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write x (ecc-review-test--numbered 1 20))
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write x (concat (ecc-review-test--numbered 1 9) "X\n"
                                              (ecc-review-test--numbered 10 20)))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (let ((blob (string-trim (ecc-review-test--git directory "rev-parse" "HEAD:x.txt"))))
                (goto-char (point-min))
                (should (re-search-forward "^index \\([0-9a-f]+\\)\\.\\.\\([0-9a-f]+\\) 100644$" nil t))
                (should (equal (match-string 1) (substring blob 0 7)))
                (should (= (length (match-string 2)) 7))
                (should (equal (ecc-review--base-of (car (ecc-review-hunks)))
                               (list 'blob (ecc-review-repository-name directory) blob))))
              (ecc-review-test--goto "+X")
              (ecc-review-comment "about X")
              ;; The old side moves under it.
              (ecc-review-test--write x (concat "p1\np2\n" (ecc-review-test--numbered 1 20)))
              (ecc-review-test--git directory "commit" "-q" "-a" "-m" "p")
              (ecc-review-test--write x (concat "p1\np2\n" (ecc-review-test--numbered 1 9) "X\n"
                                                (ecc-review-test--numbered 10 20)))
              (ecc-review-refresh)
              (goto-char (point-min))
              (should (re-search-forward "^index [0-9a-f]\\{7\\}\\.\\.[0-9a-f]\\{7\\} 100644$" nil t))
              (let ((note (ecc-review-find-note 1)))
                (should-not (ecc-review-note-outdated note))
                (should (= (ecc-review-note-line note) 12)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-an-old-side-too-large-is-not-compared ()
  "Two old blobs over `ecc-review-max-bytes' are not read, nor compared in Lisp.
Their sizes are asked first; the comments of the file go outdated and
the log says why, once."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let ((x (concat directory "x.txt"))
                (logged nil)
                (read nil)
                (cat-file (symbol-function 'ecc-review--cat-file)))
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write x (ecc-review-test--numbered 1 20))
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-test--write x (concat (ecc-review-test--numbered 1 9) "X\n"
                                              (ecc-review-test--numbered 10 20)))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD")
              (ecc-review-test--goto "+X")
              (ecc-review-comment "about X")
              (ecc-review-test--write x (concat "p1\np2\n" (ecc-review-test--numbered 1 20)))
              (ecc-review-test--git directory "commit" "-q" "-a" "-m" "p")
              (ecc-review-test--write x (concat "p1\np2\n" (ecc-review-test--numbered 1 9) "X\n"
                                                (ecc-review-test--numbered 10 20)))
              (let ((ecc-review-max-bytes 20))
                (cl-letf (((symbol-function 'ecc-log)
                           (lambda (_category format &rest arguments)
                             (push (apply #'format format arguments) logged)))
                          ((symbol-function 'ecc-review--cat-file)
                           (lambda (root ids option each)
                             (when (equal option "--batch")
                               (setq read (append ids read)))
                             (funcall cat-file root ids option each))))
                  (ecc-review-refresh)
                  (setq ecc-review--fingerprint nil)
                  (ecc-review-refresh)))
              (should-not read)
              (should (= (seq-count (lambda (line) (string-search "over 20 bytes" line)) logged) 1))
              (should (ecc-review-note-outdated (ecc-review-find-note 1)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-comments-handed-over-git-cannot-carry-are-read-again ()
  "Comments handed to a review that git does not answer for leave its next g to read it.
The review was filled and taken for read before they came; the reading
that could not carry them is no longer the end of it, and g carries
them from where they were."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (ecc-review-test--goto "+        return part / total")
    (ecc-review-comment "guard it")
    (let ((note (car ecc-review--notes))
          (s (concat directory "s.py")))
      ;; A commit moves the old side of the review it is handed to.
      (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--summary))
      (ecc-review-test--git directory "commit" "-q" "-a" "-m" "import")
      (ecc-review-test--write s (concat "import math\n\n" ecc-review-test--share))
      (with-current-buffer (ecc-review-range-buffer session "HEAD")
        (should ecc-review--fingerprint)
        (setq ecc-review--notes (list note))
        (cl-letf (((symbol-function 'ecc-review--blobs) #'ignore))
          (ecc-review--receive ecc-review--notes))
        (should (ecc-review-note-outdated note))
        (should-not ecc-review--fingerprint)
        (ecc-review-refresh)
        (should-not (ecc-review-note-outdated note))
        (should (= (ecc-review-note-line note) 12))))))

(ert-deftest ecc-review-test-git-that-fails-is-asked-once-a-reading ()
  "When git cannot read the old sides of a repository, it is asked once a reading.
Not again for every file whose old side moved, which would be a process
and a line of the log each; the next reading asks again."
  (ecc-review-test--following (session directory ecc-review-test--share)
    (let ((paths '("s.py" "t.py" "u.py"))
          (calls 0))
      (dolist (path paths)
        (ecc-review-test--write (concat directory path) ecc-review-test--summary))
      (ecc-review-test--git directory "add" ".")
      (ecc-review-test--git directory "commit" "-q" "-m" "more")
      (dolist (path paths)
        (ecc-review-test--write (concat directory path) ecc-review-test--share))
      (with-current-buffer (ecc-review-range-buffer session "HEAD")
        (dolist (path paths)
          (ecc-review-test--goto (format "+++ b/%s" path))
          (re-search-forward "^\\+        return part / total$")
          (beginning-of-line)
          (ecc-review-comment (concat "on " path)))
        (dolist (path paths)
          (ecc-review-test--write (concat directory path)
                                  (concat "import math\n\n" ecc-review-test--summary)))
        (ecc-review-test--git directory "commit" "-q" "-a" "-m" "import")
        (dolist (path paths)
          (ecc-review-test--write (concat directory path)
                                  (concat "import math\n\n" ecc-review-test--share)))
        (cl-letf (((symbol-function 'ecc-review--blobs)
                   (lambda (&rest _) (setq calls (1+ calls)) nil)))
          (ecc-review-refresh))
        (should (= calls 1))
        (should (seq-every-p #'ecc-review-note-outdated ecc-review--notes))
        (should (ecc-review--reading-incomplete ecc-review--reading))
        (ecc-review-refresh)
        (should (equal (mapcar #'ecc-review-note-line ecc-review--notes) '(12 12 12)))
        (should-not (seq-some #'ecc-review-note-outdated ecc-review--notes))))))

(defun ecc-review-test--drawn-texts ()
  "Return the comments drawn in this review, as the text of their overlays."
  (mapcar (lambda (overlay) (overlay-get overlay 'after-string))
          (ecc-review-comment-overlays)))

(ert-deftest ecc-review-test-a-stale-review-is-not-drawn-and-nothing-stops ()
  "Drawing a review whose text changed since its reading leaves what is drawn.
It says g reads the review again, once, and is no error: what the
command came to do -- send, remove, filter, hide Claude's -- is done."
  (require 'ecc-review-files)
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (ecc-review-comment "here")
    (ecc-review-test--goto "-two")
    (ecc-review-comment "there")
    (let ((drawn (ecc-review-test--drawn-texts))
          (messages nil))
      (should (= (length drawn) 2))
      ;; Read again, and stopped before its reading was whole.
      (ecc-review--begin-reading)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments)
                   (push (apply #'format-message format arguments) messages))))
        (should-not (ecc-review--draw-notes))
        (should (equal (ecc-review-test--drawn-texts) drawn))
        ;; C-c C-c: sent, and marked so, though not drawn again.
        (ecc-review-send)
        (should (= (length (ecc-test-sent-messages)) 1))
        (should (seq-every-p #'ecc-review-note-sent ecc-review--notes))
        (should (equal (ecc-review-test--drawn-texts) drawn))
        (ecc-review-files-set-filter (current-buffer) "foo")
        (should (equal (ecc-review-test--drawn-texts) drawn))
        (ecc-review-toggle-agent)
        (should (equal (ecc-review-test--drawn-texts) drawn))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt labels &rest _) (car labels))))
          (ecc-review-remove-comment t))
        (should (= (length ecc-review--notes) 1))
        (should (equal (ecc-review-test--drawn-texts) drawn)))
      (should (string-search "g reads it again" (car messages)))
      (should (string-prefix-p "Comment #" (car messages)))
      ;; g draws what is left.
      (ecc-review-test--fill session ecc-review-test--diff)
      (should (= (length (ecc-review-test--drawn-texts)) 1)))))

(ert-deftest ecc-review-test-c-edits-a-comment-whatever-the-reading ()
  "c that edits a comment of yours needs no line, and edits it on a stale reading too.
Only a new comment is put on a line; what was typed is not sent to the
kill ring for want of one."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (ecc-review-comment "first")
    (let ((kill-ring nil))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (ecc-review--begin-reading) "second")))
        (call-interactively #'ecc-review-comment))
      (should-not kill-ring)
      (should (equal (mapcar #'ecc-review-note-text ecc-review--notes) '("second"))))))

(ert-deftest ecc-review-test-c-keeps-what-was-typed-when-it-fails ()
  "c that cannot put its comment anywhere leaves what was typed in the kill ring.
Here the review is being read again when the text is in."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (let ((kill-ring nil))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (ecc-review--begin-reading) "about added")))
        (should-error (call-interactively #'ecc-review-comment) :type 'user-error))
      (should (equal (car kill-ring) "about added")))
    (should-not ecc-review--notes)))

(ert-deftest ecc-review-test-c-that-fails-after-the-comment-is-in-keeps-nothing ()
  "c that fails once its comment is in says so, and leaves the kill ring alone.
What was typed is in the review: yanked again, it would be a second copy."
  (ecc-review-test--with-review session
    (ecc-review-test--goto "+added")
    (let ((kill-ring nil))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "about added"))
                ((symbol-function 'ecc-review--draw-notes)
                 (lambda (&rest _) (error "No room to draw"))))
        (let ((message (error-message-string
                        (should-error (call-interactively #'ecc-review-comment)))))
          (should (string-search "No room to draw" message))
          (should (string-search "is in the review" message))
          (should-not (string-search "kill ring" message))))
      (should-not kill-ring)
      (should (equal (mapcar #'ecc-review-note-text ecc-review--notes) '("about added"))))))

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
    (ecc-review-test--fill session (string-replace "+TWO\n" "+Two\n"
                                                   ecc-review-test--shifted-diff))
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
                   (progn (ecc-review-test--goto "@@ -1,3 +1,5 @@") (point)))))
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
    ;; That line is gone: the start of the nearest line that stayed.
    (should (looking-at-p "^\\+TWO$"))
    ;; The places read are let go once they are back: nothing is carried
    ;; for them to the next reading.
    (should-not ecc-review--held)
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
    ;; The line c was pressed on is let go with the comment made.
    (should-not ecc-review--held)
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
          (should-not (buffer-local-value 'ecc-review--notes buffer))
          ;; Nor is anything kept to carry them by.
          (dolist (variable '(ecc-review--held ecc-review--nearest ecc-review--base-diffs))
            (should-not (buffer-local-value variable buffer)))
          ;; Its reading is of this proposal, and keeps no file of the last.
          (should (zerop (hash-table-count
                          (ecc-review--reading-shapes
                           (buffer-local-value 'ecc-review--reading buffer))))))
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

(ert-deftest ecc-review-test-a-proposal-is-carried-from-the-file-it-found ()
  "A proposal's old side is the file as the proposal found it, not the session's record.
The file changed on disk while the permission waited: the proposal,
reviewed again, is a diff against other lines, and a comment on a lone
brace follows its brace rather than staying on the number it had, where
another brace is now."
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (let* ((file (concat directory "f.txt"))
                 (request (ecc-test-add-request session "Edit"
                                                `((file_path . ,file)
                                                  (old_string . "x")
                                                  (new_string . "X")))))
            ;; The session changed the file before: it has a record of it.
            (ecc-review-test--entry session file :original "p\n}\nx\nq\n" :edits 1)
            (ecc-review-test--write file "p\n}\nx\nq\n")
            (cl-letf (((symbol-function #'ecc-diff-file-content)
                       (lambda (path) (with-temp-buffer (insert-file-contents path) (buffer-string)))))
             (with-current-buffer (ecc-review-request request)
              (should (equal (ecc-review--base-of (car (ecc-review-hunks)))
                             (list 'proposal (secure-hash 'sha1 "p\n}\nx\nq\n"))))
              (ecc-review-test--goto " }")
              (ecc-review-comment "a brace")
              (should (= (ecc-review-note-line (car ecc-review--notes)) 2))
              ;; Two lines above it on disk now, the first of them a brace.
              (ecc-review-test--write file "q0\n}\np\n}\nx\nq\n")
              (ecc-review-request request)
              (let ((note (car ecc-review--notes)))
                (should-not (ecc-review-note-outdated note))
                (should (= (ecc-review-note-line note) 4))))))
        (ecc-review-test--kill-review-buffers)))))

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
          (let ((note (car (ecc-model-queued-texts session))))
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
    (let ((root (ecc-git-root directory)))
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
              (with-current-buffer (ecc-review-range-buffer session range)
                (should (string-search "+beta" (buffer-string)))
                (should-not (string-search "new.txt" (buffer-string)))))
            (with-current-buffer (ecc-review-range-buffer session "HEAD~1")
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
            (with-current-buffer (ecc-review-range-buffer session "--cached")
              (should (equal (buffer-name) "*ecc-review: test (staged changes)*"))
              (should (eq ecc-review--range 'staged))
              (should (string-search "Working tree (staged changes)" (ecc-review--header-line)))
              (should (string-search "+gamma" (buffer-string)))
              (should-not (string-search "+2" (buffer-string)))
              (should-not (string-search "hello" (buffer-string))))
            ;; Nothing staged is nothing to review.
            (ecc-review-test--git directory "reset" "-q")
            (should-error (ecc-review-range-buffer session 'staged) :type 'user-error)
            ;; An option is never handed to git.
            (should-error (ecc-review-range-buffer session "--output=x")
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
            (should (equal (sort (ecc-review-range-paths directory "HEAD") #'string<)
                           '("new.txt" "other.txt" "x.txt" "y.txt")))
            (should (equal (ecc-review-range-paths directory "HEAD~1..HEAD")
                           '("y.txt")))
            (with-current-buffer (ecc-review-range-buffer session "HEAD" nil
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
            (should (equal (ecc-review-range--read-arguments)
                           (list session 'staged directory
                                 (list (expand-file-name
                                        "x.txt" (ecc-git-root directory)))))))
          ;; What is staged, and no untracked file.
          (should (equal offered '("x.txt")))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "--output=x")))
            (let ((current-prefix-arg '(4)))
              (should-error (ecc-review-range--read-arguments) :type 'user-error))))))))

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
                (let* ((review (ecc-review-range-buffer session "HEAD"))
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
                  (let ((review-one (ecc-review-range-buffer one "HEAD"))
                        (review-two (ecc-review-range-buffer two "HEAD")))
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
                (let ((review (ecc-review-range-buffer session "HEAD")))
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
                                    (ecc-review-range-buffer session "HEAD"))))
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
    (ecc-review-range-buffer session "HEAD")))

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
                  ;; One whose `bashEditDiff' names a file of it is.
                  (let ((bash (ecc-review-test--tool "Bash")))
                    (ecc-model-node-put bash 'bash-edit
                                        `(:changed (,(concat project "x.txt"))))
                    (ecc-review--on-tool-finished above bash))
                  (should (buffer-local-value 'ecc-review--stale review))
                  (with-current-buffer review (setq ecc-review--stale nil))
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
            (should-error (ecc-review-range-buffer session "HEAD") :type 'user-error)
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
            (let ((index (ecc-review-range-buffer session 'staged))
                  (branch (ecc-review-range-buffer session "staged")))
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
              (dolist (key '("k" "K" "R" "u" "@" "C-c C-r" "C-c C-s" "C-c C-l"))
                (should (eq (key-binding (kbd key)) #'ecc-review-read-only)))
              ;; s, diff-mode's split of a hunk, lists the files instead.
              (should (eq (key-binding (kbd "s")) #'ecc-review-files-toggle))
              (should (eq (key-binding (kbd "/")) #'ecc-review-files-filter))
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
              (with-current-buffer (ecc-review-range-buffer session "HEAD" nil '("foo.el"))
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
                                                 (ecc-git-root directory))
                           "link.txt"))
            (setf (ecc-session-project-root session) directory)
            (with-current-buffer (ecc-review-range-buffer session "HEAD" nil '("link.txt"))
              (should (equal ecc-review--paths '("link.txt")))
              (should (string-search "link.txt" (buffer-string)))))
        (ecc-review-test--kill-review-buffers)))))

;;;; What changed inside a line

(ert-deftest ecc-review-test-the-words-that-changed-are-marked ()
  "The diff review marks the words that changed within a line, as `diff-mode'
does wherever font-lock runs: `diff-refine' is left as it is."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-test--git directory "init" "-q")
            (ecc-review-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-test--git directory "config" "user.name" "t")
            (ecc-review-test--write (concat directory "x.txt") "one two three\n")
            (ecc-review-test--git directory "add" "x.txt")
            (ecc-review-test--git directory "commit" "-q" "-m" "init")
            (setf (ecc-session-project-root session) directory)
            (ecc-review-test--write (concat directory "x.txt") "one TWO three\n")
            (with-current-buffer (ecc-review-range-buffer session)
              (should diff-refine)
              ;; A batch Emacs runs no font-lock by itself; an Emacs with
              ;; `global-font-lock-mode' on does.
              (font-lock-mode 1)
              (font-lock-ensure)
              (goto-char (point-min))
              (search-forward "+one TWO")
              (should (seq-some (lambda (overlay)
                                  (eq (overlay-get overlay 'face) 'diff-refine-added))
                                (overlays-at (1- (point)))))))
        (ecc-review-test--kill-review-buffers)))))

(provide 'ecc-review-test)

;;; ecc-review-test.el ends here
