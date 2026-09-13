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
            ;; The session changed nothing, so the review of the session
            ;; refuses and this one still has everything to show.
            (should-error (ecc-review-buffer session) :type 'user-error)
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
                (should (equal (buffer-name) "*ecc-review: test (unstaged)*"))
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
        ;; The project of a session is its cwd first, so both are moved.
        (setf (ecc-session-cwd session) other
              (ecc-session-project-root session) other)
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
        (setf (ecc-session-cwd session) other
              (ecc-session-project-root session) other)
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
              ;; Shown under the hunk, counted in the header line.
              (should (string-search "▎ use a word"
                                     (overlay-get (car (last (ecc-review-comment-overlays)))
                                                  'after-string)))
              (should (string-search "comments: 2" (ecc-review--header-line)))
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

(ert-deftest ecc-review-test-send ()
  "C-c C-c shows the prompt to confirm; sending starts a turn."
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
                (ecc-review-send)
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
              (ecc-review-send)
              (with-current-buffer "*ecc-review-message: test*"
                (ecc-review-message-send)))
            (should-not ecc-test-sent)
            (should (= (length (ecc-session-input-queue session)) 1))
            (should (string-search "Comment: later"
                                   (car (ecc-session-input-queue session)))))
        (ecc-review-test--kill-review-buffers)))))

(ert-deftest ecc-review-test-refresh-keeps-comments ()
  "g reads the diff again and keeps the comments whose hunk is still there."
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
              (ecc-review-comment "lose me")
              ;; The second file changes shape; the first stays.
              (setf (ecc-file-entry-snapshot
                     (gethash (cadr paths) (ecc-session-files session)))
                    "hello\nworld\n")
              (ecc-review-refresh)
              (should (eq (current-buffer) buffer))
              (let ((comments (ecc-review-comments)))
                (should (= (length comments) 1))
                (should (equal (plist-get (car comments) :comment) "keep me"))
                (should (equal (plist-get (car comments) :path) (car paths))))
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
            (ecc-review-send)
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

(ert-deftest ecc-review-test-request-answered-elsewhere ()
  "A proposal answered from the transcript takes its review buffers away."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let* ((request (ecc-review-test--edit-request session))
               (buffer (ecc-review-request request)))
          (with-current-buffer buffer
            (diff-hunk-next)
            (ecc-review-comment "x")
            (ecc-review-send))
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

(provide 'ecc-review-test)

;;; ecc-review-test.el ends here
