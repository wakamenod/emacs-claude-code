;;; ecc-review-ediff-test.el --- Tests for ecc-review-ediff  -*- lexical-binding: t; -*-

;;; Commentary:

;; The concatenated buffers, the trees each review compares, a comment
;; on a difference turned into the prompt, and sending it.  Every test
;; drives ediff by hand with `ediff-setup-windows-plain', which works in
;; batch; the git cases build a throwaway repository the way
;; `ecc-review-test' does.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-session)

;;;; Helpers

;; `ecc-review-test.el' has the same three, under its own prefix: the
;; test files are loaded one after the other and each has to stand on
;; its own, so the helpers are not shared between them.

(defmacro ecc-review-ediff-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-review-ediff" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-ediff-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-ediff-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defun ecc-review-ediff-test--kill-buffers ()
  "Kill every buffer a review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defmacro ecc-review-ediff-test--with-ediff (&rest body)
  "Run BODY with ediff laying its windows out the way batch can."
  (declare (indent 0))
  `(let ((ediff-window-setup-function #'ediff-setup-windows-plain))
     ,@body))

(defun ecc-review-ediff-test--repository (directory)
  "Make DIRECTORY a git repository with one commit of x.txt and gone.txt."
  (ecc-review-ediff-test--git directory "init" "-q")
  (ecc-review-ediff-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-ediff-test--git directory "config" "user.name" "t")
  (ecc-review-ediff-test--write (concat directory "x.txt") "one\n")
  (ecc-review-ediff-test--write (concat directory "gone.txt") "bye\n")
  (ecc-review-ediff-test--git directory "add" "x.txt" "gone.txt")
  (ecc-review-ediff-test--git directory "commit" "-q" "-m" "init"))

(defun ecc-review-ediff-test--quit (control)
  "Quit the review in CONTROL, leaving nothing behind."
  (when (buffer-live-p control)
    (ecc-review-ediff-quit control))
  (ecc-review-ediff-test--kill-buffers))

;;;; The concatenated buffers

(ert-deftest ecc-review-ediff-test-one-session-for-every-file ()
  "Every changed file goes into the two buffers under the same separator."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                ;; The session changes one file, makes one and deletes one.
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (ecc-review-ediff-test--write (concat directory "made.txt") "new\n")
                (delete-file (concat directory "gone.txt"))
                (setq control (ecc-review-ediff-buffer session))
                (should (buffer-live-p control))
                (with-current-buffer control
                  (should (derived-mode-p 'ediff-mode))
                  (should (eq ecc-review--session session))
                  (let ((base (car ecc-review-ediff--buffers))
                        (now (cdr ecc-review-ediff--buffers))
                        (sections ecc-review-ediff--sections))
                    (should (equal (buffer-name base) "*ecc-review-base: test*"))
                    (should (equal (buffer-name now) "*ecc-review-now: test*"))
                    ;; One separator per file, in the order git reports.
                    (should (equal (mapcar #'car sections)
                                   '("gone.txt" "made.txt" "x.txt")))
                    ;; A blank line in front of every file but the first.
                    (should (equal (with-current-buffer base
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                                   (concat "═══ gone.txt ═══\nbye\n"
                                           "\n═══ made.txt ═══\n"
                                           "\n═══ x.txt ═══\none\n")))
                    (should (equal (with-current-buffer now
                                     (buffer-substring-no-properties
                                      (point-min) (point-max)))
                                   (concat "═══ gone.txt ═══\n"
                                           "\n═══ made.txt ═══\nnew\n"
                                           "\n═══ x.txt ═══\ntwo\n")))
                    ;; The separator lines are where the sections say.
                    (pcase-dolist (`(,path ,base-line ,now-line) sections)
                      (dolist (pair (list (cons base base-line) (cons now now-line)))
                        (with-current-buffer (car pair)
                          (goto-char (point-min))
                          (forward-line (1- (cdr pair)))
                          (should (equal (buffer-substring-no-properties
                                          (line-beginning-position)
                                          (line-end-position))
                                         (format "═══ %s ═══" path))))))
                    ;; One difference per file, and neither side can be
                    ;; written to -- ediff's own copy does nothing.
                    (should (= ediff-number-of-differences 3))
                    (should (buffer-local-value 'buffer-read-only base))
                    (should (buffer-local-value 'buffer-read-only now))
                    ;; Side by side, and only for this review: ediff reads
                    ;; the variable out of the control buffer.
                    (should (eq ediff-split-window-function
                                #'split-window-horizontally))
                    ;; And from the first frame, not from the first
                    ;; command: the windows are laid out again at setup.
                    (should (window-live-p ediff-window-A))
                    (should (window-live-p ediff-window-B))
                    (should-not (= (car (window-edges ediff-window-A))
                                   (car (window-edges ediff-window-B))))
                    ;; Only here: the ediff of anything else is as it was.
                    (should (eq (default-value 'ediff-split-window-function)
                                #'split-window-vertically))
                    (let ((before (with-current-buffer now (buffer-string))))
                      (ediff-jump-to-difference 1)
                      (ediff-copy-A-to-B nil)
                      (should (equal (with-current-buffer now (buffer-string))
                                     before))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-baseline-excludes-what-came-before ()
  "What was changed before the session started is in neither buffer."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                ;; Work of the user's own, before the session starts.
                (ecc-review-ediff-test--write (concat directory "x.txt") "mine\n")
                (ecc-review-ediff-test--write (concat directory "was-here.txt") "already\n")
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "theirs\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("x.txt")))
                  (should (equal (with-current-buffer (car ecc-review-ediff--buffers)
                                   (buffer-string))
                                 "═══ x.txt ═══\nmine\n"))
                  ;; One file, so no blank line is wanted anywhere.
                  (should-not (string-search
                               "\n\n"
                               (with-current-buffer (cdr ecc-review-ediff--buffers)
                                 (buffer-string))))
                  (should-not (string-search
                               "was-here"
                               (with-current-buffer (cdr ecc-review-ediff--buffers)
                                 (buffer-string))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-nothing-changed ()
  "A review with nothing to show says so rather than opening an empty ediff."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (ecc-review-ediff-test--repository directory)
        (setf (ecc-session-project-root session) directory)
        (should (ecc-review-ensure-baseline session))
        (should-error (ecc-review-ediff-buffer session) :type 'user-error)))))

(ert-deftest ecc-review-ediff-test-layout-can-be-set-back ()
  "The spacing and the split are the review's own, and both can be undone."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((ecc-review-ediff-file-spacing 0)
                    (ecc-review-ediff-split-window-function nil))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (ecc-review-ediff-test--write (concat directory "made.txt") "new\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  ;; No blank line between the files.
                  (should (equal (with-current-buffer (cdr ecc-review-ediff--buffers)
                                   (buffer-string))
                                 "═══ made.txt ═══\nnew\n═══ x.txt ═══\ntwo\n"))
                  ;; And ediff's own layout, not the review's.  (ediff
                  ;; makes the variable local in every control buffer of
                  ;; its own accord, so what is asked is the value.)
                  (should (eq ediff-split-window-function
                              (default-value 'ediff-split-window-function)))
                  (should (= (car (window-edges ediff-window-A))
                             (car (window-edges ediff-window-B))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-help-is-the-reviews-own ()
  "? shows the keys a review has, and none of the ones it has not."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (dolist (key '("c -comment" "d -remove" "l -list"
                                 "C-c C-c -send" "C-c C-k -drop"
                                 "q -close" "n,SPC -next diff"))
                    (should (string-match-p (regexp-quote key)
                                            ediff-long-help-message)))
                  ;; Both sides are read-only: nothing that would write.
                  (dolist (key '("a/b" "rx -restore" "wx -save" "wd -save"
                                 "~ -swap" "X -read-only"))
                    (should-not (string-match-p (regexp-quote key)
                                                ediff-long-help-message)))
                  ;; `ediff-setup' composes the messages once before it
                  ;; runs the startup hooks, so the brief one is the
                  ;; standard string unless it is composed again there.
                  (should-not (equal ediff-brief-help-message
                                     ediff-brief-message-string))
                  (should (string-match-p "C-c C-c -send"
                                          ediff-brief-help-message))
                  ;; And it is in the panel, not only in the variable:
                  ;; `ediff-setup' writes the help out before it runs
                  ;; the startup hooks.
                  (should (equal ediff-help-message ediff-brief-help-message))
                  (should (string-match-p (regexp-quote "C-c C-c -send")
                                          (buffer-string)))
                  (ediff-toggle-help)
                  (should (string-match-p (regexp-quote "c -comment on this diff")
                                          (buffer-string)))
                  (ediff-toggle-help)
                  ;; And no other ediff session is touched.
                  (should-not (default-value 'ediff-long-help-message-function))
                  (should-not (default-value 'ediff-brief-help-message-function))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-a-and-b-say-what-a-review-is ()
  "ediff's copy commands say what a review does instead of failing.
Both sides are read-only, so `a' and `b' could only signal
`buffer-read-only' -- an error naming a buffer nobody asked about, from
a key the review's own help does not offer."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (should (eq (key-binding (kbd "a")) #'ecc-review-ediff-copy-refused))
                  (should (eq (key-binding (kbd "b")) #'ecc-review-ediff-copy-refused))
                  ;; `current-message' is nil in batch, so what was said
                  ;; is taken where it is said.
                  (let (said)
                    (cl-letf (((symbol-function 'message)
                               (lambda (format &rest args)
                                 (setq said (apply #'format format args)))))
                      (ecc-review-ediff-copy-refused))
                    (should said)
                    (should (string-match-p "C-c C-c" said)))
                  ;; And the side it would have written to is untouched.
                  (let ((now (cdr ecc-review-ediff--buffers)))
                    (should (buffer-local-value 'buffer-read-only now)))))
            (ecc-review-ediff-test--quit control)))))))

;;;; What it looks like

(ert-deftest ecc-review-ediff-test-the-code-carries-the-faces-of-its-mode ()
  "The code of a review is coloured the way its own major mode colours it.
The buffers hold many files at once, so each is fontified on its own
and the faces are carried in as text properties; no buffer of ours runs
font-lock."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "code.py") "def greet():\n    return 1\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (with-current-buffer (cdr ecc-review-ediff--buffers)
                    (goto-char (point-min))
                    (should (search-forward "def" nil t))
                    ;; The keyword carries a face, and the separator its own.
                    (should (get-text-property (- (point) 1) 'face))
                    (goto-char (point-min))
                    (should (eq (get-text-property (point) 'face)
                                'ecc-heading-face))
                    ;; And the differences ediff is not standing on are
                    ;; marked in the colours a diff is read by, in these
                    ;; two buffers alone.
                    ;; `face-remap-add-relative' keeps the face itself at
                    ;; the end of the entry, so what is asked is what was
                    ;; put in front of it.
                    (should (memq 'diff-added
                                  (alist-get 'ediff-odd-diff-B
                                             face-remapping-alist)))
                    (should-not (default-value 'face-remapping-alist))
                    ;; What the prompt quotes is the text, never the faces.
                    (should-not
                     (text-properties-at
                      0 (plist-get (ecc-review-ediff--difference
                                    0 control)
                                   :text))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-plain-text-when-fontifying-is-off ()
  "`ecc-review-ediff-fontify' nil leaves the code as it came."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((ecc-review-ediff-fontify nil))
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write
                 (concat directory "code.py") "def greet():\n    return 1\n")
                (setq control (ecc-review-ediff-buffer session))
                (with-current-buffer control
                  (with-current-buffer (cdr ecc-review-ediff--buffers)
                    (goto-char (point-min))
                    (should (search-forward "def" nil t))
                    (should-not (get-text-property (- (point) 1) 'face)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-the-review-takes-the-frame ()
  "The review opens in a frame of its own windows, and gives them back.
Two texts side by side want the width, and `q' is the review's own
quit: ediff asks whether to quit, and the question goes to a
minibuffer the control frame of a graphical Emacs does not have."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                (delete-other-windows)
                ;; Something else on the screen, which the review takes
                ;; over and hands back.
                (let ((stranger (get-buffer-create "stranger.txt")))
                  (split-window-below)
                  (set-window-buffer (next-window) stranger)
                  (should (= (length (window-list nil 'no-minibuffer)) 2))
                  (setq control (ecc-review-ediff-buffer session))
                  (with-current-buffer control
                    (should (eq (key-binding (kbd "q")) #'ecc-review-quit))
                    ;; A and B, and nothing else of what was there.
                    (should-not (get-buffer-window stranger))
                    (should (memq (window-buffer ediff-window-A)
                                  (list (car ecc-review-ediff--buffers))))
                    (ecc-review-quit))
                  (should (get-buffer-window stranger))
                  (kill-buffer stranger)))
            (ecc-review-ediff-test--quit control)))))))

;;;; Binary and oversized files

(ert-deftest ecc-review-ediff-test-binary-and-oversize-are-named ()
  "A binary or oversized file is a separator line saying why, and no more."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (with-temp-file (concat directory "photo.png")
                  (set-buffer-multibyte nil)
                  (insert "\211PNG\r\n\032\n" (make-string 64 0) "\377\330\377"))
                (ecc-review-ediff-test--write (concat directory "dump.sql")
                                        (make-string 200 ?x))
                (let ((ecc-review-max-bytes 100))
                  (setq control (ecc-review-ediff-buffer session)))
                (with-current-buffer control
                  (let ((base (with-current-buffer (car ecc-review-ediff--buffers)
                                (buffer-string)))
                        (now (with-current-buffer (cdr ecc-review-ediff--buffers)
                               (buffer-string))))
                    (should (string-search "═══ photo.png (binary, not shown) ═══" now))
                    (should (string-search "not shown) ═══" now))
                    (should (string-search "dump.sql (" now))
                    ;; Nothing of either file is in the review.
                    (should-not (string-search "PNG" now))
                    (should-not (string-search "xxxxx" now))
                    (should (equal base now)))
                  ;; Both sides being empty, neither file is a difference.
                  (should (= ediff-number-of-differences 0))))
            (ecc-review-ediff-test--quit control)))))))

;;;; The trees a working tree review compares

(ert-deftest ecc-review-ediff-test-trees ()
  "Every range `ecc-review-worktree' takes resolves to two trees."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--repository directory)
    (ecc-review-ediff-test--write (concat directory "x.txt") "second\n")
    (ecc-review-ediff-test--git directory "commit" "-q" "-a" "-m" "second")
    (let* ((root (ecc-review-git-root directory))
           (head (ecc-review--head-tree root))
           (first (string-trim (ecc-review-ediff-test--git directory "rev-parse"
                                                     "HEAD~1^{tree}"))))
      ;; A revision is compared with the working tree as it stands.
      (ecc-review-ediff-test--write (concat directory "x.txt") "working\n")
      (let ((trees (ecc-review-ediff--trees root "HEAD")))
        (should (equal (car trees) head))
        (should-not (equal (cdr trees) head)))
      ;; Two revisions are two trees of the history and nothing else.
      (should (equal (ecc-review-ediff--trees root "HEAD~1..HEAD")
                     (cons first head)))
      (should (equal (ecc-review-ediff--trees root "HEAD~1...HEAD")
                     (cons first head)))
      ;; The empty range is the index against the working tree.
      (ecc-review-ediff-test--git directory "add" "x.txt")
      (let ((trees (ecc-review-ediff--trees root "")))
        (should (equal (car trees) (ecc-review-snapshot root t)))
        (should-not (equal (car trees) head)))
      (should-error (ecc-review-ediff--trees root "no-such-revision")
                    :type 'user-error))))

(ert-deftest ecc-review-ediff-test-trees-without-commits ()
  "HEAD in a repository with no commit is the empty tree."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-directory directory
    (ecc-review-ediff-test--git directory "init" "-q")
    (ecc-review-ediff-test--write (concat directory "x.txt") "one\n")
    (let* ((root (ecc-review-git-root directory))
           (trees (ecc-review-ediff--trees root "HEAD")))
      (should (equal (car trees) (ecc-review--empty-tree root)))
      (should-not (equal (car trees) (cdr trees))))))

(ert-deftest ecc-review-ediff-test-worktree ()
  "The working tree review shows every change, staged, unstaged or untracked."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (ecc-review-ediff-test--write (concat directory "x.txt") "unstaged\n")
                (ecc-review-ediff-test--write (concat directory "gone.txt") "staged\n")
                (ecc-review-ediff-test--git directory "add" "gone.txt")
                (ecc-review-ediff-test--write (concat directory "new.txt") "hello\n")
                (setf (ecc-session-project-root session) directory)
                (setq control (ecc-review-ediff-worktree-buffer session))
                (with-current-buffer control
                  (should (equal ecc-review--range "HEAD"))
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("gone.txt" "new.txt" "x.txt")))
                  (should (= ediff-number-of-differences 3)))
                (ecc-review-ediff-test--quit control)
                ;; Without a revision only what is not staged is shown.
                (setq control (ecc-review-ediff-worktree-buffer session ""))
                (with-current-buffer control
                  (should (equal (mapcar #'car ecc-review-ediff--sections)
                                 '("new.txt" "x.txt")))))
            (ecc-review-ediff-test--quit control)))))))

;;;; Comments and the prompt

(defun ecc-review-ediff-test--setup (session directory)
  "Make DIRECTORY a repository SESSION changed two files of, and open it."
  (ecc-review-ediff-test--repository directory)
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (delete-file (concat directory "gone.txt"))
  (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
  (ecc-review-ediff-buffer session))

(ert-deftest ecc-review-ediff-test-comment-carries-the-file-and-the-line ()
  "A comment on a difference names the file and the lines inside it."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--setup session directory))
                (with-current-buffer control
                  (should (= ediff-number-of-differences 2))
                  ;; Nothing is on a difference until ediff is moved.
                  (should (= ediff-current-difference -1))
                  (should-error (call-interactively #'ecc-review-ediff-comment)
                                :type 'user-error)
                  ;; The second difference is the change to x.txt.
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use a word")
                  (let ((comment (car (ecc-review-ediff-comments))))
                    (should (equal (plist-get comment :path) "x.txt"))
                    (should (equal (plist-get comment :start) 1))
                    (should (equal (plist-get comment :end) 1))
                    (should (equal (plist-get comment :text)
                                   "@@ -1,1 +1,1 @@\n-one\n+two"))
                    (should (equal (plist-get comment :header) "@@ -1,1 +1,1 @@"))
                    (should (equal (plist-get comment :comment) "use a word")))
                  ;; The first is the file that is gone: it has no line
                  ;; on the right, and is still that file's.
                  (ediff-jump-to-difference 1)
                  (ecc-review-ediff-comment "keep it")
                  (let ((comments (ecc-review-ediff-comments)))
                    (should (= (length comments) 2))
                    (should (equal (plist-get (car comments) :path) "gone.txt"))
                    (should (equal (plist-get (car comments) :text)
                                   "@@ -1,1 +1,0 @@\n-bye"))
                    ;; In the order of the differences, not of the typing.
                    (should (equal (plist-get (cadr comments) :path) "x.txt")))
                  ;; Shown under the difference on the right.
                  (should (string-search
                           "▎ use a word"
                           (overlay-get (nth 2 (assq 1 ecc-review-ediff--comments))
                                        'after-string)))
                  ;; Editing replaces, removing drops.
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use two words")
                  (should (= (length (ecc-review-ediff-comments)) 2))
                  (should (equal (plist-get (cadr (ecc-review-ediff-comments))
                                            :comment)
                                 "use two words"))
                  (ecc-review-ediff-remove-comment)
                  (should (= (length (ecc-review-ediff-comments)) 1))
                  (should-error (ecc-review-ediff-remove-comment)
                                :type 'user-error)))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-send ()
  "C-c C-c sends the comments as the diff review would and closes the ediff."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (let ((windows (current-window-configuration)))
                (setq control (ecc-review-ediff-test--setup session directory))
                (with-current-buffer control
                  (should (eq (key-binding (kbd "c")) #'ecc-review-ediff-comment))
                  (should (eq (key-binding (kbd "d"))
                              #'ecc-review-ediff-remove-comment))
                  (should (eq (key-binding (kbd "l"))
                              #'ecc-review-ediff-list-comments))
                  (should (eq (key-binding (kbd "C-c C-c")) #'ecc-review-send))
                  (should (eq (key-binding (kbd "C-c C-k")) #'ecc-review-quit))
                  (should-error (ecc-review-send) :type 'user-error)
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use a word")
                  (let ((base (car ecc-review-ediff--buffers))
                        (now (cdr ecc-review-ediff--buffers))
                        (expected (ecc-review-format-message
                                   (ecc-review-ediff-comments))))
                    (ecc-review-send)
                    (should (string-search "## x.txt  L1-L1" expected))
                    (let ((sent (car (ecc-test-sent-messages))))
                      (should (equal (alist-get 'type sent) "user"))
                      (should (equal (alist-get 'content (alist-get 'message sent))
                                     expected)))
                    (should (ecc-session-current-turn session))
                    ;; The control buffer and both sides are gone, and
                    ;; the screen is what it was.
                    (should-not (buffer-live-p control))
                    (should-not (buffer-live-p base))
                    (should-not (buffer-live-p now))
                    (should (compare-window-configurations
                             (current-window-configuration) windows)))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-send-editing-first ()
  "C-u C-c C-c shows the prompt; cancelling leaves the ediff open."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--setup session directory))
                (with-current-buffer control
                  (ediff-jump-to-difference 2)
                  (ecc-review-ediff-comment "use a word")
                  (let ((expected (ecc-review-format-message
                                   (ecc-review-ediff-comments))))
                    (ecc-review-send t)
                    (let ((message-buffer (get-buffer "*ecc-review-message: test*")))
                      (should message-buffer)
                      (with-current-buffer message-buffer
                        (should (equal (buffer-string) expected))
                        ;; Going back leaves the review to carry on.
                        (ecc-review-message-cancel))
                      (should-not (buffer-live-p message-buffer))
                      (should (buffer-live-p control))
                      (should-not ecc-test-sent)
                      ;; And sending from there closes the ediff.
                      (with-current-buffer control (ecc-review-send t))
                      (with-current-buffer (get-buffer "*ecc-review-message: test*")
                        (goto-char (point-max))
                        (insert "\n\n全体: テストも足すこと")
                        (ecc-review-message-send))
                      (should-not (buffer-live-p control))
                      (should (equal (alist-get 'content
                                                (alist-get 'message
                                                           (car (ecc-test-sent-messages))))
                                     (concat expected
                                             "\n\n全体: テストも足すこと")))))))
            (ecc-review-ediff-test--quit control)))))))

(ert-deftest ecc-review-ediff-test-quit-drops-the-comments ()
  "C-c C-k closes the review and its buffers without sending anything."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (setq control (ecc-review-ediff-test--setup session directory))
                (let (base now)
                  (with-current-buffer control
                    (ediff-jump-to-difference 1)
                    (ecc-review-ediff-comment "never mind")
                    (setq base (car ecc-review-ediff--buffers)
                          now (cdr ecc-review-ediff--buffers))
                    (ecc-review-quit))
                  (should-not (buffer-live-p control))
                  (should-not (buffer-live-p base))
                  (should-not (buffer-live-p now))
                  (should-not ecc-test-sent)))
            (ecc-review-ediff-test--quit control)))))))

;;;; The setting

(ert-deftest ecc-review-ediff-test-style-chooses-the-review ()
  "`ecc-review-style' decides which of the two `ecc-review' opens."
  (skip-unless (executable-find "git"))
  (ecc-review-ediff-test--with-ediff
    (ecc-test-with-fake-session session
      (ecc-review-ediff-test--with-directory directory
        (let ((control nil))
          (unwind-protect
              (progn
                (ecc-review-ediff-test--repository directory)
                (setf (ecc-session-project-root session) directory)
                (should (ecc-review-ensure-baseline session))
                (ecc-review-ediff-test--write (concat directory "x.txt") "two\n")
                ;; The default is the one diff-mode buffer.
                (should (eq ecc-review-style 'diff))
                (ecc-review session)
                (should (buffer-live-p (get-buffer "*ecc-review: test*")))
                (ecc-review-ediff-test--kill-buffers)
                (let ((ecc-review-style 'ediff))
                  (setq control (ecc-review session))
                  (should (buffer-live-p control))
                  (should (with-current-buffer control (derived-mode-p 'ediff-mode)))
                  (should-not (get-buffer "*ecc-review: test*"))))
            (ecc-review-ediff-test--quit control)))))))

(provide 'ecc-review-ediff-test)

;;; ecc-review-ediff-test.el ends here
