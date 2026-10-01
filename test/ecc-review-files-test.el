;;; ecc-review-files-test.el --- Tests for ecc-review-files  -*- lexical-binding: t; -*-

;;; Commentary:

;; The files pane (s) and the file filter (/) of a review, in both kinds
;; of review.  The diff review is filled with a diff of its own; the
;; ediff review runs against a throwaway repository with
;; `ediff-setup-windows-plain', which works in batch.  The pane is made
;; narrow, the frame of a batch Emacs being 80 columns.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-review)
(require 'ecc-review-files)
(require 'ecc-review-ediff)
(require 'ecc-review-agent)
(require 'ecc-session)

;;;; Helpers

(defconst ecc-review-files-test--diff
  "diff --git a/src/one.el b/src/one.el
index 1111111..2222222 100644
--- a/src/one.el
+++ b/src/one.el
@@ -1 +1 @@
-old
+new
@@ -10,0 +11,2 @@
+eleven
+twelve
@@ -20 +22 @@
--- a line of dashes
+++ a line of pluses
diff --git a/made.txt b/made.txt
new file mode 100644
--- /dev/null
+++ b/made.txt
@@ -0,0 +1,2 @@
+a
+b
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/before.el b/after.el
similarity index 90%
rename from before.el
rename to after.el
--- a/before.el
+++ b/after.el
@@ -3 +3 @@
-x
+y
diff --git a/pic.png b/pic.png
new file mode 100644
Binary files /dev/null and b/pic.png differ
"
  "A diff of a changed, a new, a deleted, a renamed and a binary file.
The third hunk of src/one.el takes out a line that reads like a ---
header and puts in one that reads like a +++ one.")

(defun ecc-review-files-test--fill (session &optional text)
  "Put TEXT, the diff of this file by default, in a review of SESSION."
  (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                    session (or text ecc-review-files-test--diff)
                    temporary-file-directory))

(defun ecc-review-files-test--kill-buffers ()
  "Kill every buffer a review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun ecc-review-files-test--line (path)
  "Return the line of the diff that is the first of PATH's hunks."
  (seq-find (lambda (line) (equal (plist-get line :path) path)) (ecc-review-lines)))

(defun ecc-review-files-test--pane-text (review)
  "Return the text of the files pane of REVIEW."
  (with-current-buffer (buffer-local-value 'ecc-review-files--pane review)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ecc-review-files-test--pane-paths (review)
  "Return the paths the files pane of REVIEW lists, in order."
  (with-current-buffer (buffer-local-value 'ecc-review-files--pane review)
    (let ((paths nil))
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((path (get-text-property (point) 'ecc-review-file)))
          (push path paths))
        (forward-line 1))
      (nreverse paths))))

(defun ecc-review-files-test--current (review)
  "Return the path the files pane of REVIEW marks as being read."
  (with-current-buffer (buffer-local-value 'ecc-review-files--pane review)
    (goto-char (point-min))
    (and (re-search-forward "^▸ " nil t)
         (get-text-property (point) 'ecc-review-file))))

(defmacro ecc-review-files-test--with-pane (&rest body)
  "Run BODY with the pane narrow, hidden and forgotten afterwards."
  (declare (indent 0))
  `(let ((ecc-review-files-width 24)
         (ecc-review-files-shown nil))
     (save-window-excursion
       (delete-other-windows)
       ,@body)))

(defun ecc-review-files-test--beside (session review)
  "Show SESSION's buffer and REVIEW side by side, the session on the left.
Return the window of REVIEW."
  (delete-other-windows)
  (set-window-buffer (selected-window)
                     (or (ecc-session-buffer session)
                         (setf (ecc-session-buffer session)
                               (get-buffer-create
                                (format " *ecc-review-files-test: %s*"
                                        (ecc-session-name session))))))
  (let ((right (split-window-right)))
    (set-window-buffer right review)
    (select-window right)
    right))

(defun ecc-review-files-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-files-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defmacro ecc-review-files-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-review-files" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-files-test--ediff (session directory)
  "Open the ediff review of three files SESSION changed in DIRECTORY.
a.txt, b.txt and c.txt each have one line changed.  Return the control
buffer."
  (ecc-review-files-test--git directory "init" "-q")
  (ecc-review-files-test--git directory "config" "user.email" "t@example.com")
  (ecc-review-files-test--git directory "config" "user.name" "t")
  (dolist (name '("a.txt" "b.txt" "c.txt"))
    (ecc-review-files-test--write (concat directory name) "one\ntwo\nthree\n"))
  (ecc-review-files-test--git directory "add" ".")
  (ecc-review-files-test--git directory "commit" "-q" "-m" "init")
  (setf (ecc-session-project-root session) directory)
  (should (ecc-review-ensure-baseline session))
  (dolist (name '("a.txt" "b.txt" "c.txt"))
    (ecc-review-files-test--write (concat directory name)
                                  (format "one\n%s\nthree\n" (upcase name))))
  (ecc-review-ediff-buffer session))

(defmacro ecc-review-files-test--with-ediff (session control &rest body)
  "Run BODY with CONTROL the ediff review of three files of a fake SESSION."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,session
     (ecc-review-files-test--with-directory directory
       (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
             (,control nil))
         (unwind-protect
             (progn
               (setq ,control (ecc-review-files-test--ediff ,session directory))
               (with-current-buffer ,control
                 ,@body))
           (when (buffer-live-p ,control)
             (ecc-review-ediff-quit ,control))
           (ecc-review-files-test--kill-buffers))))))

;;;; The files of a diff review

(ert-deftest ecc-review-files-test-the-files-of-a-diff ()
  "Each file of a diff is one entry: what happened, its lines, its old name."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer (ecc-review-files-test--fill session)
          (should (equal (mapcar (lambda (entry)
                                   (list (plist-get entry :status) (plist-get entry :path)
                                         (plist-get entry :old-path)
                                         (plist-get entry :added) (plist-get entry :removed)))
                                 (ecc-review-files-entries))
                         '(("M" "src/one.el" nil 4 2)
                           ("A" "made.txt" nil 2 0)
                           ("D" "gone.txt" nil 0 1)
                           ("R" "after.el" "before.el" 1 1)
                           ("A" "pic.png" nil 0 0))))
          ;; Each runs to where the next begins, and the path is the one
          ;; the comments are kept under.
          (let ((entries (ecc-review-files-entries)))
            (cl-mapc (lambda (one two)
                       (should (= (plist-get one :end) (plist-get two :beg))))
                     entries (cdr entries))
            (should (= (plist-get (car (last entries)) :end) (point-max)))
            (should (equal (plist-get (ecc-review-files-test--line "after.el") :path)
                           "after.el"))))
      (ecc-review-files-test--kill-buffers))))

;;;; The pane

(ert-deftest ecc-review-files-test-the-pane-lists-the-files ()
  "One line a file: status, path, lines, comments by author, outdated mark."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((review (ecc-review-files-test--fill session))
                (ecc-review-files-width 36))
            ;; Alone in the frame, so that the pane is wide enough for
            ;; every name.
            (set-window-buffer (selected-window) review)
            (with-current-buffer review
              (ecc-review-add-note 'user "mine" (ecc-review-files-test--line "made.txt"))
              (ecc-review-add-note 'claude "theirs" (ecc-review-files-test--line "made.txt"))
              (ecc-review-add-note 'claude "again" (ecc-review-files-test--line "made.txt"))
              (let ((gone (ecc-review-add-note 'user "lost" (ecc-review-files-test--line
                                                             "gone.txt"))))
                ;; On a hunk that is no longer in the diff.
                (setf (ecc-review-note-hunk-key gone) '("gone.txt" . "@@ -9 +9 @@")
                      (ecc-review-note-hunk-old-range gone) '(9 . 9)))
              (ecc-review-files-toggle)
              (ecc-review--draw-notes))
            (let ((text (ecc-review-files-test--pane-text review)))
              (should (string-prefix-p " Files (5 of 5)\n" text))
              (should (equal (ecc-review-files-test--pane-paths review)
                             '("src/one.el" "made.txt" "gone.txt" "after.el" "pic.png")))
              (should (string-match-p "^  A made\\.txt +\\+2  1·2$" text))
              (should (string-match-p "^  D gone\\.txt +−1  1·0!$" text))
              (should (string-match-p "^  R before\\.el → after\\.el +\\+1 −1$" text))
              (should (string-match-p "^  A pic\\.png *$" text))
              ;; Faces are put on as the text goes in.
              (with-current-buffer (buffer-local-value 'ecc-review-files--pane review)
                (should-not font-lock-mode)
                (goto-char (point-min))
                (re-search-forward "^  \\(A\\) made")
                (should (eq (get-text-property (match-beginning 1) 'face)
                            'diff-indicator-added))
                (should (derived-mode-p 'special-mode))
                (should (equal (buffer-name) "*ecc-review-files: test*")))))
        (ecc-review-files-test--kill-buffers)))))

(ert-deftest ecc-review-files-test-the-pane-follows-point ()
  "The file point is in is marked, and moving into another moves the mark."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((review (ecc-review-files-test--fill session)))
            (ecc-review-files-test--beside session review)
            (with-current-buffer review
              (goto-char (point-min))
              (ecc-review-files-toggle)
              (should (equal (ecc-review-files-test--current review) "src/one.el"))
              (goto-char (plist-get (ecc-review-files-test--line "gone.txt") :position))
              (run-hooks 'post-command-hook)
              (should (equal (ecc-review-files-test--current review) "gone.txt"))
              ;; Moved by Claude, which is no command.
              (ecc-review-move-to (ecc-review-files-test--line "after.el") nil)
              (should (equal (ecc-review-files-test--current review) "after.el"))))
        (ecc-review-files-test--kill-buffers)))))

(ert-deftest ecc-review-files-test-the-pane-sits-left-of-the-diff ()
  "The pane is split off the left of the review: session | pane | diff.
s again takes it down, and the next review opened comes with it."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session session
      (unwind-protect
          (let* ((review (ecc-review-files-test--fill session))
                 (window (ecc-review-files-test--beside session review))
                 (session-window (get-buffer-window (ecc-session-buffer session))))
            (with-current-buffer review
              (ecc-review-files-toggle))
            (let ((pane (ecc-review-files--pane-window review)))
              (should (window-live-p pane))
              (should (= (nth 2 (window-edges pane)) (nth 0 (window-edges window))))
              (should (= (nth 0 (window-edges pane)) (nth 2 (window-edges session-window))))
              (should-not (window-parameter pane 'window-side)))
            (should ecc-review-files-shown)
            (with-current-buffer review
              (ecc-review-files-toggle))
            (should-not (ecc-review-files--pane-window review))
            (should-not ecc-review-files-shown)
            ;; The columns it took are the review's again.
            (should (seq-set-equal-p (window-list) (list session-window window)))
            (should (= (window-total-width window) (/ (frame-width) 2)))
            ;; Remembered: a review the user opens comes with the pane.
            (setq ecc-review-files-shown t)
            (cl-letf (((symbol-function 'ecc-window-display-review)
                       (lambda (buffer _session)
                         (set-window-buffer window buffer)
                         window)))
              (ecc-review--display review session))
            (should (window-live-p (ecc-review-files--pane-window review)))
            ;; And it goes with the review.
            (kill-buffer review)
            (should-not (get-buffer "*ecc-review-files: test*"))
            (should (= (length (window-list)) 2)))
        (ecc-review-files-test--kill-buffers)))))

(ert-deftest ecc-review-files-test-ret-goes-to-the-file ()
  "RET on a line of the pane goes to the file and to the review; n shows one."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session session
      (unwind-protect
          (let* ((review (ecc-review-files-test--fill session))
                 (window (ecc-review-files-test--beside session review)))
            (with-current-buffer review
              (goto-char (point-min))
              (ecc-review-files-toggle))
            (let ((pane (ecc-review-files--pane-window review)))
              (select-window pane)
              (goto-char (point-min))
              (forward-line 1)
              ;; n shows the next file and leaves the keyboard in the pane.
              (ecc-review-files-next)
              (should (eq (selected-window) pane))
              (should (= (window-point window)
                         (with-current-buffer review
                           (plist-get (ecc-review-files-test--line "made.txt") :position))))
              (ecc-review-files-next)
              (ecc-review-files-visit)
              (should (eq (selected-window) window))
              (should (= (window-point window)
                         (with-current-buffer review
                           (plist-get (ecc-review-files-test--line "gone.txt") :position))))
              (should (equal (ecc-review-files-test--current review) "gone.txt"))))
        (ecc-review-files-test--kill-buffers)))))

;;;; The filter

(ert-deftest ecc-review-files-test-what-the-filter-matches ()
  "Path, former path or Claude's comments, ignoring case; not the user's."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer (ecc-review-files-test--fill session)
          (ecc-review-add-note 'claude "Needle in the haystack"
                               (ecc-review-files-test--line "made.txt"))
          (ecc-review-add-note 'user "a needle of mine" (ecc-review-files-test--line "gone.txt"))
          (let ((kept (lambda (filter)
                        (mapcar (lambda (entry) (plist-get entry :path))
                                (seq-filter (lambda (entry)
                                              (ecc-review-files--matches-p
                                               entry filter ecc-review--notes))
                                            (ecc-review-files-entries))))))
            (should (equal (funcall kept "SRC/") '("src/one.el")))
            (should (equal (funcall kept "before") '("after.el")))
            (should (equal (funcall kept "needle") '("made.txt")))
            (should (equal (funcall kept ".el") '("src/one.el" "after.el")))
            (should (= (length (funcall kept "")) 5))
            (should (= (length (funcall kept nil)) 5))))
      (ecc-review-files-test--kill-buffers))))

(ert-deftest ecc-review-files-test-the-filter-hides-files-of-the-diff ()
  "The files left out are invisible, their comments kept, sent and not drawn.
} passes over them, the header line counts them, and a reading again
keeps the filter."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session session
      (unwind-protect
          (with-current-buffer (ecc-review-files-test--fill session)
            (ecc-review-add-note 'user "first" (ecc-review-files-test--line "src/one.el"))
            (ecc-review-add-note 'user "hidden" (ecc-review-files-test--line "made.txt"))
            (ecc-review-add-note 'claude "hidden too" (ecc-review-files-test--line "gone.txt"))
            (ecc-review-add-note 'user "last" (ecc-review-files-test--line "after.el"))
            (ecc-review--draw-notes)
            (ecc-review-files-set-filter (current-buffer) ".el")
            (should (equal ecc-review--hidden '("made.txt" "gone.txt" "pic.png")))
            (let ((made (plist-get (ecc-review-files-test--line "made.txt") :position))
                  (one (plist-get (ecc-review-files-test--line "src/one.el") :position)))
              (should (invisible-p made))
              (should-not (invisible-p one)))
            (should (string-search "/.el: 3 files hidden by filter" (ecc-review--header-line)))
            ;; Not drawn, but kept, and sent.
            (let ((drawn (mapconcat (lambda (overlay) (overlay-get overlay 'after-string))
                                    ecc-review--comments "")))
              (should (string-search "first" drawn))
              (should-not (string-search "hidden" drawn)))
            (should (= (length ecc-review--notes) 4))
            (should (string-search "hidden" (ecc-review-buffer-message)))
            ;; } walks from the first to the last, past the hidden two.
            (goto-char (point-min))
            (ecc-review-next-comment)
            (ecc-review-next-comment)
            (should (= (line-beginning-position)
                       (plist-get (ecc-review-files-test--line "after.el") :position)))
            (should-error (ecc-review-next-comment) :type 'user-error)
            ;; n walks the hunks of what is left: the three of src/one.el,
            ;; then after.el's, and no further.
            (goto-char (point-min))
            (dotimes (_ 4) (ecc-review-next-hunk))
            (should (= (point) (plist-get (ecc-review-files-test--line "after.el") :position)))
            (should-error (ecc-review-next-hunk) :type 'user-error)
            (should (= (point) (plist-get (ecc-review-files-test--line "after.el") :position)))
            ;; P: the head of after.el, then of src/one.el, past the two.
            (ecc-review-previous-file)
            (should (looking-at-p "--- a/before.el"))
            (ecc-review-previous-file)
            (should (looking-at-p "--- a/src/one.el"))
            ;; Read again: the filter holds.
            (ecc-review--fill (current-buffer) session
                              (concat ecc-review-files-test--diff
                                      "diff --git a/z.el b/z.el\n--- a/z.el\n+++ b/z.el\n@@ -1 +1 @@\n-q\n+r\n")
                              temporary-file-directory)
            (should (equal ecc-review--filter ".el"))
            (should (equal ecc-review--hidden '("made.txt" "gone.txt" "pic.png")))
            (should (invisible-p (plist-get (ecc-review-files-test--line "made.txt") :position)))
            ;; Empty: every file again.
            (ecc-review-files-set-filter (current-buffer) "")
            (should-not ecc-review--filter)
            (should-not ecc-review--hidden)
            (should-not (invisible-p (plist-get (ecc-review-files-test--line "made.txt")
                                                :position))))
        (ecc-review-files-test--kill-buffers)))))

(ert-deftest ecc-review-files-test-the-filter-narrows-the-pane-as-it-is-typed ()
  "/ shows the pane narrowed to what is typed, and RET filters the review."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session session
      (unwind-protect
          (let* ((review (ecc-review-files-test--fill session))
                 (seen nil))
            (ecc-review-files-test--beside session review)
            (cl-letf (((symbol-function 'read-from-minibuffer)
                       (lambda (&rest _)
                         ;; As the minibuffer hears each change.
                         (cl-letf (((symbol-function 'minibuffer-contents-no-properties)
                                    (lambda () "TXT")))
                           (ecc-review-files--typed))
                         (setq seen (list (window-live-p (ecc-review-files--pane-window review))
                                          (ecc-review-files-test--pane-paths review)
                                          (buffer-local-value 'ecc-review--filter review)))
                         "txt")))
              (with-current-buffer review
                (ecc-review-files-filter)))
            ;; While typing: shown, narrowed, and the review untouched.
            (should (equal seen '(t ("made.txt" "gone.txt") nil)))
            ;; Then: the review is filtered, the pane back as it was.
            (should (equal (buffer-local-value 'ecc-review--filter review) "txt"))
            (should-not (ecc-review-files--pane-window review))
            ;; C-g leaves the filter as it was.
            (cl-letf (((symbol-function 'read-from-minibuffer)
                       (lambda (&rest _) (signal 'quit nil))))
              (with-current-buffer review
                ;; A quit is no error, and `should-error' would not see it.
                (should (eq (condition-case nil
                                (progn (ecc-review-files-filter) 'returned)
                              (quit 'quit))
                            'quit))))
            (should (equal (buffer-local-value 'ecc-review--filter review) "txt"))
            (should-not (ecc-review-files--pane-window review)))
        (ecc-review-files-test--kill-buffers)))))

;;;; Claude and the filter

(defun ecc-review-files-test--call (session name &optional arguments)
  "Call the tool NAME as SESSION would; return (FAILED . TEXT)."
  (let ((ecc-mcp--session-id (and session (ecc-session-id session))))
    (ecc-mcp-call-tool name arguments)))

(ert-deftest ecc-review-files-test-claude-is-told-of-the-filter ()
  "review_hunks says what is hidden; review_navigate passes over it."
  (ecc-test-with-fake-session session
    (unwind-protect
        (with-current-buffer (ecc-review-files-test--fill session)
          (ecc-review-add-note 'claude "on one" (ecc-review-files-test--line "src/one.el"))
          (ecc-review-add-note 'claude "on made" (ecc-review-files-test--line "made.txt"))
          (ecc-review-add-note 'claude "on after" (ecc-review-files-test--line "after.el"))
          (ecc-review--draw-notes)
          (ecc-review-files-set-filter (current-buffer) ".el")
          (let ((text (cdr (ecc-review-files-test--call session "review_hunks"))))
            (should (string-search "filtered the files of this review by \".el\": 3 files hidden"
                                   text))
            (should (string-search "made.txt  (hidden by the user's filter)" text))
            (should-not (string-search "src/one.el  (hidden" text)))
          (goto-char (point-min))
          (pcase-let ((`(,failed . ,text)
                       (ecc-review-files-test--call session "review_navigate"
                                                    '((direction . "next_comment")))))
            (should-not failed)
            (should (string-search "comment #1" text)))
          (pcase-let ((`(,failed . ,text)
                       (ecc-review-files-test--call session "review_navigate"
                                                    '((direction . "next_comment")))))
            (should-not failed)
            (should (string-search "comment #3" text)))
          (pcase-let ((`(,failed . ,text)
                       (ecc-review-files-test--call session "review_navigate"
                                                    '((file . "made.txt")))))
            (should failed)
            (should (string-search "is hidden by the user" text))))
      (ecc-review-files-test--kill-buffers))))

;;;; The ediff review

(ert-deftest ecc-review-files-test-ediff-pane-is-a-left-side-window ()
  "In ediff the pane is a side window on the left that | leaves and q takes."
  (skip-unless (executable-find "git"))
  (ecc-review-files-test--with-pane
    (ecc-review-files-test--with-ediff session control
      (should (eq (key-binding (kbd "s")) #'ecc-review-files-toggle))
      (should (eq (key-binding (kbd "/")) #'ecc-review-files-filter))
      (ecc-review-files-toggle)
      (let ((pane (ecc-review-files--pane-window control)))
        (should (eq (window-parameter pane 'window-side) 'left))
        (should (= (nth 2 (window-edges pane)) (nth 0 (window-edges ediff-window-A))))
        (should (equal (ecc-review-files-test--pane-paths control)
                       '("a.txt" "b.txt" "c.txt")))
        (should (string-match-p "^▸ M a\\.txt +\\+1 −1$"
                                (ecc-review-files-test--pane-text control)))
        (ediff-toggle-split)
        (should (eq (ecc-review-files--pane-window control) pane))
        (should (window-live-p ediff-window-A))
        (should-not (eq ediff-window-A pane))
        (should-not (eq ediff-window-B pane)))
      (let ((pane-buffer ecc-review-files--pane))
        (ecc-review-ediff-quit control)
        (should-not (buffer-live-p pane-buffer))
        (should-not (seq-find (lambda (window)
                                (window-parameter window 'ecc-review-files))
                              (window-list)))))))

(ert-deftest ecc-review-files-test-ediff-pane-beside-a-shared-frame ()
  "Without the frame to itself the pane is split off the left side, and kept."
  (skip-unless (executable-find "git"))
  (let ((ecc-review-ediff-full-frame nil))
    (ecc-review-files-test--with-pane
      (ecc-review-files-test--with-ediff session control
        (ecc-review-files-toggle)
        (let ((pane (ecc-review-files--pane-window control)))
          (should-not (window-parameter pane 'window-side))
          (should (= (nth 2 (window-edges pane)) (nth 0 (window-edges ediff-window-A)))))
        (ediff-toggle-split)
        (let ((pane (ecc-review-files--pane-window control)))
          (should (window-live-p pane))
          (should (= (nth 2 (window-edges pane)) (nth 0 (window-edges ediff-window-A)))))))))

(ert-deftest ecc-review-files-test-ediff-pane-follows-the-difference ()
  "The pane marks the file of the difference ediff is on; RET goes to a file."
  (skip-unless (executable-find "git"))
  (ecc-review-files-test--with-pane
    (ecc-review-files-test--with-ediff session control
      (ediff-jump-to-difference 1)
      (ecc-review-files-toggle)
      (should (equal (ecc-review-files-test--current control) "a.txt"))
      (ecc-review-ediff-next-difference)
      (should (equal (ecc-review-files-test--current control) "b.txt"))
      (with-current-buffer ecc-review-files--pane
        (goto-char (point-min))
        (re-search-forward "c\\.txt")
        (ecc-review-files-visit))
      (should (= ediff-current-difference 2))
      (should (equal (ecc-review-files-test--current control) "c.txt")))))

(ert-deftest ecc-review-files-test-ediff-filter-hides-both-sides ()
  "Both halves of a file left out are hidden; n, p and j step over them."
  (skip-unless (executable-find "git"))
  (ecc-review-files-test--with-pane
    (ecc-review-files-test--with-ediff session control
      (ecc-review-add-note 'claude "a needle" (car (ecc-review-ediff--unit-lines
                                                    (nth 2 (ecc-review-units)))))
      (ecc-review--draw-notes)
      (ediff-jump-to-difference 1)
      (ecc-review-files-set-filter control "NEEDLE")
      ;; c.txt matches by Claude's comment; a and b are hidden, and the
      ;; review moved off a.txt to what is left.
      (should (equal ecc-review--hidden '("a.txt" "b.txt")))
      (should (= ediff-current-difference 2))
      (dolist (side (list ediff-buffer-A ediff-buffer-B))
        (with-current-buffer side
          (goto-char (point-min))
          (should (invisible-p (point)))
          (re-search-forward "═══ c.txt")
          (should-not (invisible-p (point)))))
      (should (string-search "/NEEDLE: 2 files hidden by filter" ediff-brief-help-message))
      (should-error (ecc-review-ediff-previous-difference) :type 'user-error)
      (should (= ediff-current-difference 2))
      ;; j to a hidden one goes to the first one kept after it.
      (ecc-review-ediff-jump-to-difference 1)
      (should (= ediff-current-difference 2))
      ;; Wider: b comes back, and p reaches it past nothing.
      (ecc-review-files-set-filter control "b.txt")
      (should (equal ecc-review--hidden '("a.txt" "c.txt")))
      (should (= ediff-current-difference 1))
      (should-error (ecc-review-ediff-next-difference) :type 'user-error)
      (ecc-review-files-set-filter control "")
      (ecc-review-ediff-next-difference)
      (should (= ediff-current-difference 2))
      (should-not (string-search "hidden by filter" ediff-brief-help-message)))))

(ert-deftest ecc-review-files-test-ediff-filter-holds-across-reading-again ()
  "A filtered ediff review read again hides the same files, and draws no comment there."
  (skip-unless (executable-find "git"))
  (ecc-review-files-test--with-pane
    (ecc-review-files-test--with-ediff session control
      (ecc-review-add-note 'user "on a" (car (ecc-review-ediff--unit-lines
                                              (nth 0 (ecc-review-units)))))
      (ecc-review-files-set-filter control "c.txt")
      (ecc-review-files-test--write (concat default-directory "b.txt") "changed again\n")
      (ecc-review-reread t)
      (should (equal ecc-review--filter "c.txt"))
      (should (equal ecc-review--hidden '("a.txt" "b.txt")))
      (with-current-buffer ediff-buffer-B
        (goto-char (point-min))
        (should (invisible-p (point))))
      (should-not (seq-some (lambda (overlay)
                              (string-search "on a" (or (overlay-get overlay 'after-string) "")))
                            ecc-review--comments))
      (should (string-search "on a" (ecc-review-buffer-message))))))

;;;; Two reviews

(ert-deftest ecc-review-files-test-two-sessions-keep-apart ()
  "The pane and the filter of one session's review leave another's alone."
  (ecc-review-files-test--with-pane
    (ecc-test-with-fake-session one
      (let ((two (ecc-model-create-session :name "two"
                                           :project-root temporary-file-directory)))
        (unwind-protect
            (let ((review-one (ecc-review-files-test--fill one))
                  (review-two (ecc-review-files-test--fill two)))
              (ecc-review-files-test--beside one review-one)
              (with-current-buffer review-one
                (ecc-review-files-toggle)
                (ecc-review-files-set-filter review-one "made"))
              (should (buffer-live-p (buffer-local-value 'ecc-review-files--pane review-one)))
              (should-not (buffer-local-value 'ecc-review-files--pane review-two))
              (should (= (length (buffer-local-value 'ecc-review--hidden review-one)) 4))
              (should-not (buffer-local-value 'ecc-review--filter review-two))
              (should-not (buffer-local-value 'ecc-review--hidden review-two))
              (with-current-buffer review-two
                (should-not (invisible-p (plist-get (ecc-review-files-test--line "gone.txt")
                                                    :position)))
                (should-not (string-search "hidden by filter" (ecc-review--header-line))))
              ;; Claude's calls from two see two's review, unfiltered.
              (should-not (string-search "filtered"
                                         (cdr (ecc-review-files-test--call two "review_hunks"))))
              (should (string-search "filtered"
                                     (cdr (ecc-review-files-test--call one "review_hunks")))))
          (ecc-test-cleanup-session two)
          (ecc-review-files-test--kill-buffers))))))

(provide 'ecc-review-files-test)

;;; ecc-review-files-test.el ends here
