;;; ecc-review-agent-test.el --- Tests for ecc-review-agent  -*- lexical-binding: t; -*-

;;; Commentary:

;; Claude's side of a review.  Every tool is called through
;; `ecc-mcp-call-tool', the way the server calls it, with the session id
;; bound the way a request's URL binds it; the review buffers are filled
;; with a diff of their own, and `review_open' runs against a throwaway
;; repository.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-review-agent)
(require 'ecc-review-ediff)
(require 'ecc-session)

;;;; Helpers

(defconst ecc-review-agent-test--diff
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
  "A diff of one file in two hunks, as `ecc-review-test--diff' is.")

(defun ecc-review-agent-test--fill (session text)
  "Put the diff TEXT in the review buffer of SESSION and return the buffer."
  (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                    session text temporary-file-directory))

(defun ecc-review-agent-test--goto (line)
  "Move to the start of the first line that is LINE exactly."
  (goto-char (point-min))
  (re-search-forward (concat "^" (regexp-quote line) "$"))
  (beginning-of-line))

(defun ecc-review-agent-test--kill-review-buffers ()
  "Kill every buffer the review left behind."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecc-review" (buffer-name buffer))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun ecc-review-agent-test--write (path content)
  "Write CONTENT to PATH."
  (with-temp-file path (insert content)))

(defmacro ecc-review-agent-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-review-agent" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-review-agent-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-review--git directory args)))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-review-agent-test--call (session name &optional arguments)
  "Call the tool NAME as SESSION would, with the alist ARGUMENTS.
Returns (FAILED . TEXT), as `ecc-mcp-call-tool' does."
  (let ((ecc-mcp--session-id (and session (ecc-session-id session))))
    (ecc-mcp-call-tool name arguments)))

(defun ecc-review-agent-test--ok (session name &optional arguments)
  "Call the tool NAME as SESSION would and return its text, failing on a failure."
  (pcase-let ((`(,failed . ,text) (ecc-review-agent-test--call session name arguments)))
    (when failed (ert-fail text))
    text))

(defmacro ecc-review-agent-test--with-review (session &rest body)
  "Run BODY with SESSION a fake session reviewing `ecc-review-agent-test--diff'.
The review buffer is current."
  (declare (indent 1))
  `(ecc-test-with-fake-session ,session
     (unwind-protect
         (with-current-buffer (ecc-review-agent-test--fill ,session ecc-review-agent-test--diff)
           ,@body)
       (ecc-review-agent-test--kill-review-buffers))))

;;;; Finding the review

(ert-deftest ecc-review-agent-test-no-review-says-what-to-do ()
  "Without a review the tools fail with a sentence that names review_open."
  (ecc-test-with-fake-session session
    (dolist (name '("review_hunks" "review_list_comments" "review_navigate"))
      (pcase-let ((`(,failed . ,text) (ecc-review-agent-test--call session name)))
        (should failed)
        (should (string-search "Call review_open first" text))))
    ;; A proposal under review is not the review the tools mean.
    (ecc-review--fill (get-buffer-create "*ecc-review: test (proposal)*")
                      session ecc-review-agent-test--diff nil 'a-request)
    (unwind-protect
        (should (car (ecc-review-agent-test--call session "review_hunks")))
      (ecc-review-agent-test--kill-review-buffers)))
  ;; And a call that names no session is refused.
  (should (car (ecc-review-agent-test--call nil "review_hunks"))))

(ert-deftest ecc-review-agent-test-hunks ()
  "review_hunks numbers the hunks of each file and can add their text."
  (ecc-review-agent-test--with-review session
    (let ((text (ecc-review-agent-test--ok session "review_hunks")))
      (should (string-search "1 file, 2 hunks;" text))
      (should-not (string-search "comments\n" text))
      (should (string-search "foo.el\n  hunk 1  @@ -1,3 +1,3 @@  new L1-L3\n" text))
      (should (string-search "  hunk 2  @@ -10,2 +10,3 @@  new L10-L12\n" text))
      (should-not (string-search "+added" text)))
    ;; One of anything is one, not one of a plural.
    (ecc-review-agent-test--ok session "review_comment"
                               '((file . "foo.el") (line . 11) (text . "x")))
    (should (string-search "new L10-L12  1 comment\n"
                           (ecc-review-agent-test--ok session "review_hunks")))
    (should (string-search "comments: 0 by the user, 1 by you."
                           (ecc-review-agent-test--ok session "review_hunks")))
    (should (string-search "+added"
                           (ecc-review-agent-test--ok
                            session "review_hunks" '((include_patch . t)))))
    ;; JSON false is false.
    (should-not (string-search "+added"
                               (ecc-review-agent-test--ok
                                session "review_hunks" '((include_patch . :false)))))
    (should (car (ecc-review-agent-test--call session "review_hunks"
                                              '((file . "nope.el")))))))

;;;; Comments

(ert-deftest ecc-review-agent-test-comment ()
  "review_comment puts Claude's comment on a line, a hunk, or under another."
  (ecc-review-agent-test--with-review session
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment"
                    '((file . "foo.el") (line . 11) (text . "Why a new line?")))
                   "Added #1 at foo.el:11 (new)"))
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment"
                    '((file . "b/foo.el") (line . 2) (side . "old") (text . "Gone")))
                   "Added #2 at foo.el:2 (old)"))
    ;; A context line is on both sides, and is anchored on the new one.
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment"
                    '((file . "foo.el") (line . 3) (side . "old") (text . "Same")))
                   "Added #3 at foo.el:3 (new)"))
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment"
                    '((file . "foo.el") (hunk . 2) (text . "The whole of it")))
                   "Added #4 at foo.el L10-L12"))
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment" '((reply_to . 1) (text . "Answering")))
                   "Added #5 at foo.el:11 (new)"))
    ;; Always Claude's, and drawn.
    (should (seq-every-p #'ecc-review--agent-p ecc-review--notes))
    (should (equal (ecc-review-note-reply-to (ecc-review-find-note 5)) 1))
    (should (string-search "#1 Claude: Why a new line?"
                           (mapconcat (lambda (o) (or (overlay-get o 'after-string) ""))
                                      (ecc-review-comment-overlays) "")))
    ;; A line that is not in the diff: the answer says which are.
    (pcase-let ((`(,failed . ,text)
                 (ecc-review-agent-test--call
                  session "review_comment"
                  '((file . "foo.el") (line . 99) (text . "x")))))
      (should failed)
      (should (string-search "foo.el:99 (new) is not in the diff" text))
      (should (string-search "shows L1-L3, L10-L12" text)))
    (pcase-let ((`(,failed . ,text)
                 (ecc-review-agent-test--call
                  session "review_comment"
                  '((file . "foo.el") (line . 12) (side . "old") (text . "x")))))
      (should failed)
      (should (string-search "The old side of foo.el shows L1-L3, L10-L11" text)))
    (dolist (bad '(((file . "foo.el") (line . 1) (hunk . 1) (text . "x"))
                   ((file . "foo.el") (text . "x"))
                   ((file . "foo.el") (line . 1) (text . "  "))
                   ((file . "foo.el") (hunk . 3) (text . "x"))
                   ((reply_to . 42) (text . "x"))))
      (should (car (ecc-review-agent-test--call session "review_comment" bad))))
    (should (= (length ecc-review--notes) 5))))

(ert-deftest ecc-review-agent-test-apply-is-all-or-nothing ()
  "review_comment_apply adds every comment, or none when one is wrong."
  (ecc-review-agent-test--with-review session
    (pcase-let ((`(,failed . ,text)
                 (ecc-review-agent-test--call
                  session "review_comment_apply"
                  `((comments . [((file . "foo.el") (line . 1) (text . "fine"))
                                 ((file . "foo.el") (line . 50) (text . "not a line"))])))))
      (should failed)
      (should (string-search "comment 2: foo.el:50 (new) is not in the diff" text))
      (should (string-search "Nothing was added." text)))
    (should-not ecc-review--notes)
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment_apply"
                    `((comments . [((file . "foo.el") (line . 1) (text . "one"))
                                   ((file . "foo.el") (line . 12) (text . "two"))])))
                   "Added #1 at foo.el:1 (new)\nAdded #2 at foo.el:12 (new)"))
    (should (car (ecc-review-agent-test--call session "review_comment_apply"
                                              '((comments . [])))))))

(ert-deftest ecc-review-agent-test-list-remove-and-clear ()
  "Claude reads the user's comments with their hunk, removes any, clears its own."
  (ecc-review-agent-test--with-review session
    (ecc-review-agent-test--goto "+TWO")
    (ecc-review-comment "Keep it lower case")
    (ecc-review-agent-test--ok session "review_comment"
                               '((file . "foo.el") (line . 11) (text . "Mine")))
    (ecc-review-agent-test--goto "+added")
    (ecc-review-comment "Fine by me")
    (let ((all (ecc-review-agent-test--ok session "review_list_comments"))
          (users (ecc-review-agent-test--ok session "review_list_comments"
                                            '((author . "user")))))
      (should (string-search "#1 [user] foo.el:2 (new): Keep it lower case\n```diff\n@@ -1,3 +1,3 @@"
                             all))
      ;; A reply is listed under what it answers.
      (should (string-search "#2 [claude] foo.el:11 (new): Mine\n  #3 [user] foo.el:11 (new): Fine by me"
                             all))
      (should-not (string-search "[claude]" users))
      (should (string-search "#3 [user] foo.el:11 (new) (reply to #2): Fine by me" users)))
    (should (equal (ecc-review-agent-test--ok session "review_list_comments"
                                              '((file . "foo.el") (author . "claude")))
                   "#2 [claude] foo.el:11 (new): Mine"))
    (should (car (ecc-review-agent-test--call session "review_list_comments"
                                              '((author . "nobody")))))
    ;; Clearing takes Claude's and keeps the user's.
    (should (string-search "Removed 1 comment.  The user's 2 were kept"
                           (ecc-review-agent-test--ok session "review_clear_comments")))
    (should (equal (mapcar #'ecc-review-note-id ecc-review--notes) '(1 3)))
    ;; Removing one of the user's, once dealt with, is allowed.
    (should (equal (ecc-review-agent-test--ok session "review_remove_comment"
                                              '((id . "#1")))
                   "Removed #1, the user's comment at foo.el:2 (new)."))
    (should (car (ecc-review-agent-test--call session "review_remove_comment"
                                              '((id . 1)))))
    (ecc-review-agent-test--ok session "review_clear_comments"
                               '((include_user_comments . t)))
    (should-not ecc-review--notes)))

;;;; Showing and moving

(ert-deftest ecc-review-agent-test-navigate-keeps-the-focus ()
  "review_navigate moves the review window and never selects it."
  (ecc-review-agent-test--with-review session
    (let ((review (current-buffer))
          (session-buffer (ecc-session-ensure-buffer session)))
      (save-window-excursion
        (delete-other-windows)
        (switch-to-buffer session-buffer)
        (let ((selected (selected-window)))
          ;; The session is on the screen, so the review comes up beside it.
          (should (equal (ecc-review-agent-test--ok
                          session "review_navigate"
                          '((file . "foo.el") (line . 11)))
                         "Showing foo.el:11 (new) to the user."))
          (should (eq (selected-window) selected))
          (should (eq (window-buffer selected) session-buffer))
          (let ((window (get-buffer-window review)))
            (should window)
            (should (= (window-point window)
                       (with-current-buffer review
                         (ecc-review-agent-test--goto "+added") (point)))))
          (ecc-review-agent-test--ok session "review_comment"
                                     '((file . "foo.el") (line . 2) (text . "a")))
          (ecc-review-agent-test--ok session "review_comment"
                                     '((file . "foo.el") (hunk . 2) (text . "b")))
          (ecc-review-agent-test--ok session "review_navigate" '((comment_id . 1)))
          (should (= (window-point (get-buffer-window review))
                     (with-current-buffer review (ecc-review-agent-test--goto "+TWO") (point))))
          (ecc-review-agent-test--ok session "review_navigate"
                                     '((direction . "next_comment")))
          (should (= (window-point (get-buffer-window review))
                     (with-current-buffer review
                       (ecc-review-agent-test--goto "@@ -10,2 +10,3 @@") (point))))
          (should (car (ecc-review-agent-test--call session "review_navigate"
                                                    '((direction . "next_comment")))))
          (should (eq (selected-window) selected)))))))

(ert-deftest ecc-review-agent-test-a-hidden-session-is-not-brought-forward ()
  "A session nobody is looking at gets its review moved, not put on the screen."
  (ecc-review-agent-test--with-review session
    (let ((review (current-buffer)))
      (save-window-excursion
        (delete-other-windows)
        (switch-to-buffer (get-buffer-create "*ecc-review-agent-test elsewhere*"))
        (let ((configuration (current-window-configuration)))
          (should (string-search "not on the screen"
                                 (ecc-review-agent-test--ok
                                  session "review_navigate" '((file . "foo.el") (hunk . 2)))))
          (should-not (get-buffer-window review))
          (should (compare-window-configurations
                   configuration (current-window-configuration)))
          ;; The point went there, for when the user opens it.
          (should (= (with-current-buffer review (point))
                     (with-current-buffer review
                       (save-excursion (ecc-review-agent-test--goto "@@ -10,2 +10,3 @@")
                                       (point)))))))
      (kill-buffer "*ecc-review-agent-test elsewhere*"))))

(ert-deftest ecc-review-agent-test-open ()
  "review_open reviews the session's changes or a range, and refuses an option."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-directory directory
      (unwind-protect
          (let ((file (concat directory "x.txt")))
            (ecc-review-agent-test--git directory "init" "-q")
            (ecc-review-agent-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-agent-test--git directory "config" "user.name" "t")
            (ecc-review-agent-test--write file "one\ntwo\nthree\n")
            (ecc-review-agent-test--git directory "add" "x.txt")
            (ecc-review-agent-test--git directory "commit" "-q" "-m" "init")
            (setf (ecc-session-project-root session) directory)
            (ecc-review-agent-test--write file "one\n2\nthree\n")
            (let ((text (ecc-review-agent-test--ok session "review_open")))
              (should (string-search "not on the screen" text))
              (should (string-search "everything changed since the session started: 1 file, 1 hunk;"
                                     text))
              (should (string-search "x.txt\n  hunk 1  @@ -2 +2 @@" text)))
            (should (get-buffer "*ecc-review: test*"))
            ;; A comment survives reading it again.
            (ecc-review-agent-test--ok session "review_comment"
                                       '((file . "x.txt") (line . 2) (text . "why 2")))
            (ecc-review-agent-test--ok session "review_open")
            (with-current-buffer "*ecc-review: test*"
              (should (= (length ecc-review--notes) 1)))
            ;; A range opens the working tree review, and the tools
            ;; follow it there.
            (should (string-search "the working tree against HEAD"
                                   (ecc-review-agent-test--ok session "review_open"
                                                              '((range . "HEAD")))))
            (should (string-search "No comments."
                                   (ecc-review-agent-test--ok session "review_list_comments")))
            ;; git is never handed an option.
            (pcase-let ((`(,failed . ,text)
                         (ecc-review-agent-test--call session "review_open"
                                                      '((range . "--output=/tmp/x")))))
              (should failed)
              (should (string-search "cannot start with -" text))))
        (ecc-review-agent-test--kill-review-buffers)))))

(ert-deftest ecc-review-agent-test-open-staged-and-paths ()
  "review_open reviews what is staged, or only some files, and says so."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-directory directory
      (unwind-protect
          (progn
            (ecc-review-agent-test--git directory "init" "-q")
            (ecc-review-agent-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-agent-test--git directory "config" "user.name" "t")
            (ecc-review-agent-test--write (concat directory "x.txt") "one\n")
            (ecc-review-agent-test--write (concat directory "y.txt") "alpha\n")
            (ecc-review-agent-test--git directory "add" "x.txt" "y.txt")
            (ecc-review-agent-test--git directory "commit" "-q" "-m" "init")
            (setf (ecc-session-project-root session) directory)
            (ecc-review-agent-test--write (concat directory "x.txt") "ONE\n")
            (ecc-review-agent-test--write (concat directory "y.txt") "ALPHA\n")
            (ecc-review-agent-test--git directory "add" "y.txt")
            (ecc-review-agent-test--write (concat directory "new.txt") "hello\n")
            (let ((text (ecc-review-agent-test--ok session "review_open"
                                                   '((staged . t)))))
              (should (string-search "Review of what is staged: 1 file, 1 hunk" text))
              (should (string-search "y.txt" text))
              (should-not (string-search "new.txt" text)))
            (should (get-buffer "*ecc-review: test (staged changes)*"))
            ;; --staged in range is the same thing.
            (should (string-search "what is staged"
                                   (ecc-review-agent-test--ok session "review_open"
                                                              '((range . "--staged")))))
            (let ((text (ecc-review-agent-test--ok
                         session "review_open"
                         '((range . "HEAD") (paths . ["x.txt" " new.txt"])))))
              (should (string-search "the working tree against HEAD in x.txt, new.txt: 2 files"
                                     text))
              (should-not (string-search "y.txt" text)))
            (dolist (bad '(((range . "HEAD") (staged . t))
                           ((range . "") (staged . t))
                           ((range . "--output=/tmp/x") (staged . :false))
                           ((paths . [1]))))
              (should (car (ecc-review-agent-test--call session "review_open" bad))))
            ;; staged false is no staged at all.
            (should (string-search "the working tree against HEAD:"
                                   (ecc-review-agent-test--ok
                                    session "review_open"
                                    '((range . "HEAD") (staged . :false))))))
        (ecc-review-agent-test--kill-review-buffers)))))

(ert-deftest ecc-review-agent-test-what-a-range-is ()
  "A range of commits is called the commits it names, not the working tree against it.
git is asked once at most: never for what needs no asking, nor for the
bare HEAD, which is the working tree even before the first commit, nor
for a review whose right side is not checked out."
  (skip-unless (executable-find "git"))
  (ecc-review-agent-test--with-directory directory
    (ecc-review-agent-test--git directory "init" "-q")
    (ecc-review-agent-test--git directory "config" "user.email" "t@example.com")
    (ecc-review-agent-test--git directory "config" "user.name" "t")
    (with-temp-buffer
      (setq default-directory directory)
      (let* ((asked 0)
             (git (symbol-function 'ecc-review--git))
             (what (lambda (range)
                     (setq ecc-review--range range
                           asked 0)
                     (cl-letf (((symbol-function 'ecc-review--git)
                                (lambda (&rest args)
                                  (setq asked (1+ asked))
                                  (apply git args))))
                       (ecc-review-agent--what)))))
        ;; No commit yet: HEAD is still the working tree.
        (should (equal (funcall what "HEAD") "the working tree against HEAD"))
        (should (= asked 0))
        (ecc-review-agent-test--write (concat directory "x.txt") "one\n")
        (ecc-review-agent-test--git directory "add" "x.txt")
        (ecc-review-agent-test--git directory "commit" "-q" "-m" "one")
        (ecc-review-agent-test--write (concat directory "x.txt") "two\n")
        (ecc-review-agent-test--git directory "commit" "-q" "-am" "two")
        (let ((id (string-trim (ecc-review-agent-test--git directory "rev-parse" "HEAD"))))
          (pcase-dolist (`(,range ,said ,questions)
                         `((nil "everything changed since the session started" 0)
                           (staged "what is staged" 0)
                           ("" "what is not staged yet" 0)
                           ("HEAD" "the working tree against HEAD" 0)
                           ("HEAD~1" "the working tree against HEAD~1" 1)
                           (,(concat id "^!") ,(format "the commits %s^!" id) 1)
                           ("HEAD~1..HEAD" "the commits HEAD~1..HEAD" 1)
                           ("HEAD~1...HEAD" "the commits HEAD~1...HEAD" 1)))
            (should (equal (funcall what range) said))
            (should (= asked questions))))
        ;; A right side not checked out is of commits already: another
        ;; branch's pull request, or a commit before HEAD of one's own.
        (setq-local ecc-review--elsewhere "fix/x (a1b2c3d)")
        (should (equal (funcall what "HEAD~1...a1b2c3d")
                       (concat "the commits HEAD~1...a1b2c3d, whose right side, "
                               "fix/x (a1b2c3d), is not checked out here")))
        (should (= asked 0))))))

(ert-deftest ecc-review-agent-test-replies ()
  "reply_to answers a comment of either author, alone and in a batch."
  (ecc-review-agent-test--with-review session
    (ecc-review-agent-test--goto "+TWO")
    (ecc-review-comment "Keep it lower case")
    ;; An answer to the user: under their comment, their text untouched.
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment" '((reply_to . "#1") (text . "Will do")))
                   "Added #2 at foo.el:2 (new)"))
    (should (equal (ecc-review-note-text (ecc-review-find-note 1)) "Keep it lower case"))
    (should (eq (ecc-review-note-author (ecc-review-find-note 1)) 'user))
    (should (string-search "#1 [user] foo.el:2 (new): Keep it lower case"
                           (ecc-review-agent-test--ok session "review_list_comments")))
    (should (string-search "\n  #2 [claude] foo.el:2 (new): Will do"
                           (ecc-review-agent-test--ok session "review_list_comments")))
    ;; The file of the comment answered may be said; another may not,
    ;; and neither may a line or a hunk.
    (should (ecc-review-agent-test--ok
             session "review_comment"
             '((reply_to . 1) (file . "foo.el") (text . "Same file"))))
    (dolist (bad '(((reply_to . 1) (line . 11) (text . "x"))
                   ((reply_to . 1) (hunk . 1) (text . "x"))
                   ((reply_to . 1) (file . "bar.el") (text . "x"))))
      (should (car (ecc-review-agent-test--call session "review_comment" bad))))
    ;; In a batch, checked with the rest: a bad reply adds nothing.
    (pcase-let ((`(,failed . ,text)
                 (ecc-review-agent-test--call
                  session "review_comment_apply"
                  '((comments . [((file . "foo.el") (line . 11) (text . "fine"))
                                 ((reply_to . 99) (text . "to nothing"))
                                 "not an object"])))))
      (should failed)
      (should (string-search "comment 2: There is no comment #99" text))
      (should (string-search "comment 3: A comment is an object" text)))
    (should (= (length ecc-review--notes) 3))
    (should (equal (ecc-review-agent-test--ok
                    session "review_comment_apply"
                    '((comments . [((file . "foo.el") (line . 11) (text . "fine"))
                                   ((reply_to . 1) (text . "And another"))])))
                   "Added #4 at foo.el:11 (new)\nAdded #5 at foo.el:2 (new)"))
    (should (equal (ecc-review-note-reply-to (ecc-review-find-note 5)) 1))
    ;; Only the user's go in the prompt, the reply to Claude with it.
    (ecc-review-agent-test--goto "+added")
    (ecc-review-comment "Answering Claude" (ecc-review--comment-plan (ecc-review--line-at-point)))
    (let ((message (ecc-review-buffer-message)))
      (should (string-search "Keep it lower case" message))
      (should (string-search "In reply to Claude's #4: fine" message))
      (should-not (string-search "Will do\n" message)))))

(ert-deftest ecc-review-agent-test-a-sent-comment-is-listed-as-sent ()
  "review_list_comments marks the user's comments a prompt has carried."
  (ecc-review-agent-test--with-review session
    (ecc-review-agent-test--goto "+TWO")
    (ecc-review-comment "Keep it lower case")
    (should-not (string-search "(sent"
                               (ecc-review-agent-test--ok session "review_list_comments")))
    (ecc-review-send)
    (should (string-search "#1 [user] foo.el:2 (new) (sent: it came to you in a prompt already): Keep it lower case"
                           (ecc-review-agent-test--ok
                            session "review_list_comments" '((author . "user")))))
    ;; The review is still there to answer it in.
    (should (ecc-review-agent-test--ok
             session "review_comment" '((reply_to . 1) (text . "Done"))))))

(ert-deftest ecc-review-agent-test-review-tools-do-not-make-the-review-stale ()
  "A review tool's result is no reason to read the review again."
  (ecc-review-agent-test--with-review session
    (let ((ecc-review-auto-refresh t)
          (ecc-review--watch-timer nil))
      (unwind-protect
          (progn
            (dolist (tool ecc-review-agent-tools)
              (ecc-review--on-tool-finished
               session (make-ecc-node :type 'tool
                                      :data `((name . ,(format "mcp__%s__%s"
                                                               ecc-mcp-server-name tool)))))
              (should-not ecc-review--stale))
            ;; Another server's tool of the same name is not one of them.
            (ecc-review--on-tool-finished
             session (make-ecc-node :type 'tool :data '((name . "mcp__other__review_open"))))
            (should ecc-review--stale))
        (when (timerp ecc-review--watch-timer)
          (cancel-timer ecc-review--watch-timer))))))

(ert-deftest ecc-review-agent-test-open-paths-outside-git ()
  "Outside git, review_open takes a path relative to the project, or absolute."
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-directory directory
      (unwind-protect
          (let ((a (concat directory "a.txt"))
                (b (concat directory "b.txt")))
            (setf (ecc-session-project-root session) directory)
            (dolist (path (list a b))
              (let ((entry (ecc-model-note-file session path nil)))
                (setf (ecc-file-entry-original entry) "one\n"
                      (ecc-file-entry-snapshot entry) (concat "one\n" path "\n")
                      (ecc-file-entry-edits entry) 1)))
            (let ((text (ecc-review-agent-test--ok session "review_open"
                                                   '((paths . ["a.txt"])))))
              (should (string-search "1 file" text))
              (should (string-search "a.txt" text))
              (should-not (string-search "b.txt" text)))
            (should (string-search "1 file"
                                   (ecc-review-agent-test--ok
                                    session "review_open" `((paths . [,b]))))))
        (ecc-review-agent-test--kill-review-buffers)))))

;;;; What goes wrong

(ert-deftest ecc-review-agent-test-an-unknown-file-is-named ()
  "Listing or clearing the comments of a file the review has not got says so."
  (ecc-review-agent-test--with-review session
    (ecc-review-agent-test--ok session "review_comment"
                               '((file . "foo.el") (line . 11) (text . "Mine")))
    (dolist (name '("review_list_comments" "review_clear_comments"))
      (pcase-let ((`(,failed . ,text)
                   (ecc-review-agent-test--call session name '((file . "nope.el")))))
        (should failed)
        (should (string-search "nope.el is not in the review; its files are: foo.el"
                               text))))
    (should (= (length ecc-review--notes) 1))
    ;; A file that only has outdated comments left can still be named.
    (setf (ecc-review-note-path (car ecc-review--notes)) "gone.el")
    (should (string-search "#1 [claude] gone.el"
                           (ecc-review-agent-test--ok session "review_list_comments"
                                                      '((file . "gone.el")))))
    (ecc-review-agent-test--ok session "review_clear_comments" '((file . "gone.el")))
    (should-not ecc-review--notes)))

;;;; A place set while nobody looks

(ert-deftest ecc-review-agent-test-a-hidden-place-is-kept ()
  "review_navigate on a review nobody sees: opening it by hand lands there."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-directory directory
      (unwind-protect
          (let ((file (concat directory "x.txt"))
                (ecc-review-style 'diff)
                (ecc-window-hide-on-review nil)
                (ecc-window-review-focus 'review))
            (ecc-review-agent-test--git directory "init" "-q")
            (ecc-review-agent-test--git directory "config" "user.email" "t@example.com")
            (ecc-review-agent-test--git directory "config" "user.name" "t")
            (ecc-review-agent-test--write
             file (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 20) ""))
            (ecc-review-agent-test--git directory "add" "x.txt")
            (ecc-review-agent-test--git directory "commit" "-q" "-m" "init")
            (ecc-review-agent-test--write
             file (mapconcat (lambda (n) (format (if (memq n '(2 15)) "LINE %d\n" "line %d\n") n))
                             (number-sequence 1 20) ""))
            (setf (ecc-session-project-root session) directory)
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer (get-buffer-create "*ecc-review-agent-test elsewhere*"))
              (ecc-review-agent-test--ok session "review_open")
              (let ((reply (ecc-review-agent-test--ok
                            session "review_navigate"
                            '((file . "x.txt") (line . 15)))))
                (should (string-search "Its point is at x.txt:15 (new)" reply))
                ;; What is not kept is said: a window in another tab.
                (should (string-search "in another tab keeps the place it had" reply)))
              ;; The user opens the review, which reads the diff again.
              (ecc-review session)
              (let ((review (get-buffer "*ecc-review: test*")))
                (should (eq (window-buffer (selected-window)) review))
                (should (looking-at-p "\\+LINE 15"))
                (should (= (window-point (selected-window)) (point))))))
        (ecc-review-agent-test--kill-review-buffers)
        (when (get-buffer "*ecc-review-agent-test elsewhere*")
          (kill-buffer "*ecc-review-agent-test elsewhere*"))))))

(ert-deftest ecc-review-agent-test-a-second-review-takes-the-first-ones-window ()
  "Opening another review of the session puts it where the first one was."
  (ecc-test-with-fake-session session
    (unwind-protect
        (let ((first (ecc-review-agent-test--fill session ecc-review-agent-test--diff))
              (second (ecc-review--fill (get-buffer-create
                                         (ecc-review-buffer-name session nil "HEAD"))
                                        session ecc-review-agent-test--diff
                                        temporary-file-directory nil nil "HEAD"))
              (display-buffer-alist nil))
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer (ecc-session-ensure-buffer session))
            (let ((window (ecc-review-agent--show first session)))
              (should window)
              (should (eq (ecc-review-agent--show second session) window))
              (should (eq (window-buffer window) second))
              (should (= (length (window-list)) 2)))))
      (ecc-review-agent-test--kill-review-buffers))))

;;;; More than one session

(ert-deftest ecc-review-agent-test-sessions-do-not-cross ()
  "A call from one session never touches the review of another."
  (ecc-test-with-fake-session one
    (let ((two (ecc-model-create-session :name "two"
                                         :project-root temporary-file-directory)))
      (unwind-protect
          (let ((review-one (ecc-review-agent-test--fill one ecc-review-agent-test--diff))
                (review-two (ecc-review-agent-test--fill two ecc-review-agent-test--diff)))
            (ecc-review-agent-test--ok one "review_comment"
                                       '((file . "foo.el") (line . 1) (text . "one's")))
            (ecc-review-agent-test--ok two "review_comment"
                                       '((file . "foo.el") (line . 2) (text . "two's")))
            (should (equal (mapcar #'ecc-review-note-text
                                   (buffer-local-value 'ecc-review--notes review-one))
                           '("one's")))
            (should (equal (mapcar #'ecc-review-note-text
                                   (buffer-local-value 'ecc-review--notes review-two))
                           '("two's")))
            ;; Clearing in one leaves the other alone.
            (ecc-review-agent-test--ok one "review_clear_comments")
            (should-not (buffer-local-value 'ecc-review--notes review-one))
            (should (= 1 (length (buffer-local-value 'ecc-review--notes review-two))))
            (should (string-search "two's"
                                   (ecc-review-agent-test--ok two "review_list_comments")))
            (should (equal (ecc-review-agent-test--ok one "review_list_comments")
                           "No comments.")))
        (ecc-review-agent-test--kill-review-buffers)
        (ecc-test-cleanup-session two)))))

;;;; A review in ediff

(defmacro ecc-review-agent-test--with-ediff (session control &rest body)
  "Run BODY with CONTROL the ediff review of SESSION's change to a.txt.
a.txt went from line1..line10 to line 2 changed, a line put in after
line 6 and line 9 taken out.  ediff lays its windows out the way batch
can."
  (declare (indent 2))
  `(ecc-review-agent-test--with-directory directory
     (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
           (ecc-review-ediff-layout 'side-by-side)
           (,control nil))
       (unwind-protect
           (let ((file (concat directory "a.txt")))
             (ecc-review-agent-test--git directory "init" "-q")
             (ecc-review-agent-test--git directory "config" "user.email" "t@example.com")
             (ecc-review-agent-test--git directory "config" "user.name" "t")
             (ecc-review-agent-test--write
              file (mapconcat (lambda (n) (format "line%d\n" n)) (number-sequence 1 10) ""))
             (ecc-review-agent-test--git directory "add" "a.txt")
             (ecc-review-agent-test--git directory "commit" "-q" "-m" "init")
             (setf (ecc-session-project-root ,session) directory)
             (should (ecc-review-ensure-baseline ,session))
             (ecc-review-agent-test--write
              file "line1\nLINE2\nline3\nline4\nline5\nline6\nnew\nline7\nline8\nline10\n")
             (setq ,control (ecc-review-ediff-buffer ,session))
             ,@body)
         (when (buffer-live-p ,control)
           (ecc-review-ediff-quit ,control))
         (ecc-review-agent-test--kill-review-buffers)))))

(ert-deftest ecc-review-agent-test-ediff-hunks-and-comments ()
  "The tools read an ediff review: its differences, its lines, its comments."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-ediff session control
      (let ((text (ecc-review-agent-test--ok session "review_hunks")))
        (should (string-search "1 file, 3 hunks;" text))
        (should (string-search
                 (concat "a.txt\n"
                         "  hunk 1  difference 1  old L2-L2  new L2-L2\n"
                         "  hunk 2  difference 2  old none  new L7-L7\n"
                         "  hunk 3  difference 3  old L9-L9  new none\n")
                 text)))
      (should (string-search "+LINE2" (ecc-review-agent-test--ok
                                       session "review_hunks" '((include_patch . t)))))
      (should (equal (ecc-review-agent-test--ok
                      session "review_comment"
                      '((file . "a.txt") (line . 7) (text . "Why this line?")))
                     "Added #1 at a.txt:7 (new)"))
      (should (equal (ecc-review-agent-test--ok
                      session "review_comment"
                      '((file . "a.txt") (line . 9) (side . "old") (text . "Still used")))
                     "Added #2 at a.txt:9 (old)"))
      (should (equal (ecc-review-agent-test--ok
                      session "review_comment" '((file . "a.txt") (hunk . 1) (text . "Case")))
                     "Added #3 at a.txt L2-L2"))
      ;; A line both sides hold is in no difference.
      (pcase-let ((`(,failed . ,text)
                   (ecc-review-agent-test--call
                    session "review_comment" '((file . "a.txt") (line . 5) (text . "x")))))
        (should failed)
        (should (string-search "The new side of a.txt shows L2, L7;" text)))
      (with-current-buffer control
        ;; Drawn on their sides, with the label the diff review uses.
        (let ((drawn (lambda (buffer)
                       (mapconcat (lambda (overlay)
                                    (if (eq (overlay-buffer overlay) buffer)
                                        (or (overlay-get overlay 'after-string) "")
                                      ""))
                                  ecc-review--comments ""))))
          (should (string-search "#1 Claude: Why this line?"
                                 (funcall drawn ediff-buffer-B)))
          (should (string-search "#3 Claude: Case" (funcall drawn ediff-buffer-B)))
          (should (string-search "#2 Claude: Still used" (funcall drawn ediff-buffer-A))))
        ;; The user answers one with c on its difference.
        (ediff-jump-to-difference 2)
        (ecc-review-ediff-comment "It is the new default"))
      (let ((users (ecc-review-agent-test--ok session "review_list_comments"
                                              '((author . "user")))))
        (should (string-search "#4 [user] a.txt:7 (new) (reply to #1): It is the new default"
                               users))
        (should (string-search "+new" users)))
      (should (string-search "Removed 3 comments.  The user's 1 were kept"
                             (ecc-review-agent-test--ok session "review_clear_comments")))
      (should (equal (with-current-buffer control (mapcar #'ecc-review-note-id ecc-review--notes))
                     '(4))))))

(ert-deftest ecc-review-agent-test-ediff-navigate-keeps-the-focus ()
  "review_navigate moves the ediff to the difference and line, selecting nothing."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-ediff session control
      (let ((selected (selected-window))
            (windows (window-list nil 'no-minibuffer)))
        (should (equal (ecc-review-agent-test--ok
                        session "review_navigate"
                        '((file . "a.txt") (line . 9) (side . "old")))
                       "Showing a.txt:9 (old) to the user."))
        (should (eq (selected-window) selected))
        (should (equal (window-list nil 'no-minibuffer) windows))
        (with-current-buffer control
          (should (= ediff-current-difference 2))
          (should (equal (let ((window ediff-window-A))
                           (with-current-buffer ediff-buffer-A
                             (save-excursion
                               (goto-char (window-point window))
                               (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position)))))
                         "line9")))
        (ecc-review-agent-test--ok session "review_comment"
                                   '((file . "a.txt") (line . 2) (text . "a")))
        (ecc-review-agent-test--ok session "review_navigate" '((comment_id . 1)))
        (with-current-buffer control
          (should (= ediff-current-difference 0)))
        (ecc-review-agent-test--ok session "review_comment"
                                   '((file . "a.txt") (line . 7) (text . "b")))
        (should (equal (ecc-review-agent-test--ok session "review_navigate"
                                                  '((direction . "next_comment")))
                       "Showing comment #2 to the user."))
        (with-current-buffer control
          (should (= ediff-current-difference 1)))
        (should (eq (selected-window) selected))))))

(ert-deftest ecc-review-agent-test-ediff-open-reads-it-in-place ()
  "review_open never starts ediff: it reads the user's ediff again, or opens a diff."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-ediff session control
      (ecc-review-agent-test--ok session "review_comment"
                                 '((file . "a.txt") (line . 2) (text . "kept")))
      (let ((text (ecc-review-agent-test--ok session "review_open")))
        (should (string-prefix-p ecc-review-agent-in-place-text text))
        (should-not (string-search "were not applied" text))
        (should (string-search "3 hunks" text)))
      ;; No diff review was opened beside it, and the comment is there.
      (should-not (get-buffer "*ecc-review: test*"))
      (should (= 1 (length (buffer-local-value 'ecc-review--notes control))))
      ;; What it could not do is said.
      (should (string-search "the range, staged or paths you gave were not applied"
                             (ecc-review-agent-test--ok session "review_open"
                                                        '((range . "HEAD")))))
      (should-not (get-buffer "*ecc-review: test (HEAD)*"))
      ;; Once the ediff is closed, review_open opens the diff review --
      ;; whatever `ecc-review-style' says.
      (ecc-review-ediff-quit control)
      (let ((ecc-review-style 'ediff)
            (before (seq-filter (lambda (b) (with-current-buffer b (derived-mode-p 'ediff-mode)))
                                (buffer-list))))
        (should (string-search "everything changed since the session started"
                               (ecc-review-agent-test--ok session "review_open")))
        (should (get-buffer "*ecc-review: test*"))
        (should (equal (seq-filter (lambda (b) (with-current-buffer b
                                                 (derived-mode-p 'ediff-mode)))
                                   (buffer-list))
                       before))))))

(ert-deftest ecc-review-agent-test-ediff-open-compares-paths-as-the-review-reads-them ()
  "review_open's paths are compared with the review's after reading them alike."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-ediff session control
      (ecc-review-ediff-quit control)
      (setq control (ecc-review-ediff-buffer session (list (concat directory "a.txt"))))
      (dolist (paths (list ["a.txt"] (vector (concat directory "a.txt"))))
        (should-not (string-search "were not applied"
                                   (ecc-review-agent-test--ok session "review_open"
                                                              `((paths . ,paths))))))
      ;; No paths is every file, which this review of one is not.
      (should (string-search "were not applied"
                             (ecc-review-agent-test--ok session "review_open")))
      (should (string-search "were not applied"
                             (ecc-review-agent-test--ok session "review_open"
                                                        '((paths . ["b.txt"]))))))))

(ert-deftest ecc-review-agent-test-ediff-open-of-another-repository ()
  "review_open's paths are read against the held review's own repository.
The ediff review is of another repository than the session's project,
and a review_open without paths is answered, not failed."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-review-agent-test--with-ediff session control
      (ecc-review-ediff-quit control)
      (ecc-review-agent-test--with-directory other
        (ecc-review-agent-test--git other "init" "-q")
        (ecc-review-agent-test--git other "config" "user.email" "t@example.com")
        (ecc-review-agent-test--git other "config" "user.name" "t")
        (ecc-review-agent-test--write (concat other "f.txt") "one\n")
        (ecc-review-agent-test--write (concat other "g.txt") "one\n")
        (ecc-review-agent-test--git other "add" ".")
        (ecc-review-agent-test--git other "commit" "-q" "-m" "init")
        (ecc-review-agent-test--write (concat other "f.txt") "two\n")
        (ecc-review-agent-test--write (concat other "g.txt") "two\n")
        (setq control (ecc-review-ediff-range-buffer session "HEAD" other (list "f.txt")))
        (unwind-protect
            (progn
              (should-not (string-search "were not applied"
                                         (ecc-review-agent-test--ok
                                          session "review_open"
                                          '((range . "HEAD") (paths . ["f.txt"])))))
              (should (string-search "were not applied"
                                     (ecc-review-agent-test--ok session "review_open"
                                                                '((range . "HEAD"))))))
          (ecc-review-ediff-quit control))))))

(ert-deftest ecc-review-agent-test-ediff-and-another-session ()
  "One session's calls reach its own ediff review and never another's."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session one
    (let ((two (ecc-model-create-session :name "two"
                                         :project-root temporary-file-directory)))
      (unwind-protect
          (ecc-review-agent-test--with-ediff one control
            (let ((review-two (ecc-review-agent-test--fill two ecc-review-agent-test--diff)))
              (ecc-review-agent-test--ok one "review_comment"
                                         '((file . "a.txt") (line . 2) (text . "one's")))
              (ecc-review-agent-test--ok two "review_comment"
                                         '((file . "foo.el") (line . 2) (text . "two's")))
              (should (equal (mapcar #'ecc-review-note-text
                                     (buffer-local-value 'ecc-review--notes control))
                             '("one's")))
              (should (equal (mapcar #'ecc-review-note-text
                                     (buffer-local-value 'ecc-review--notes review-two))
                             '("two's")))
              (should (string-search "difference 1"
                                     (ecc-review-agent-test--ok one "review_hunks")))
              (should-not (string-search "difference"
                                         (ecc-review-agent-test--ok two "review_hunks")))
              ;; review_open from two does not read one's ediff again.
              (let ((tick (with-current-buffer control
                            (with-current-buffer ediff-buffer-B
                              (buffer-chars-modified-tick)))))
                (ecc-review-agent-test--call two "review_open")
                (should (= tick (with-current-buffer control
                                  (with-current-buffer ediff-buffer-B
                                    (buffer-chars-modified-tick))))))
              (ecc-review-agent-test--ok two "review_clear_comments")
              (should (= 1 (length (buffer-local-value 'ecc-review--notes control))))))
        (ecc-test-cleanup-session two)))))

;;;; Publishing and allowing

(ert-deftest ecc-review-agent-test-published-with-ecc ()
  "Loading ecc publishes the review tools and their instructions with the server."
  (require 'ecc)
  (let ((published (mapcar #'ecc-mcp-tool-name (ecc-mcp-published-tools))))
    (dolist (name ecc-review-agent-tools)
      (should (member name published))))
  (let ((instructions (alist-get 'instructions (ecc-mcp--server-info))))
    (should (string-search "review_open" instructions)))
  ;; Taken out of the list, the tools take their paragraph with them.
  (let ((ecc-mcp-excluded-tools ecc-review-agent-tools))
    (should-not (string-search "review_open"
                               (or (alist-get 'instructions (ecc-mcp--server-info)) "")))))

(ert-deftest ecc-review-agent-test-opens-only-when-asked ()
  "The model is told to open the review when the user asks for it, not after an edit.
The instructions and review_open's description say so alike, and the
instructions still say how to read and answer the user's comments, which
C-c C-c and M rely on."
  (require 'ecc)
  (let ((instructions (ecc-mcp-instructions))
        (description (alist-get 'description
                                (ecc-mcp-tool-object (ecc-mcp-tool "review_open")))))
    (should-not (string-search "asked to explain, walk through or review changes"
                               instructions))
    (dolist (text (list instructions description))
      (should (string-search "only when the user asks for the review" text))
      (should (string-search "a review they have open" text)))
    (should (string-search "summing up what you have just changed is not"
                           instructions))
    (should (string-search "not to explain or sum up changes you have just made"
                           description))
    (dolist (words '("review_comment " "review_comment_apply" "review_navigate"
                     "review_list_comments with author \"user\""
                     "review_remove_comment" "reply_to"))
      (should (string-search words instructions)))))

(ert-deftest ecc-review-agent-test-allowed-without-asking ()
  "A review tool is allowed at once; another tool of the server is still asked."
  (ecc-test-with-fake-session session
    (let ((request (lambda (tool)
                     `((type . "control_request")
                       (request_id . ,(concat "req-" tool))
                       (request . ((subtype . "can_use_tool")
                                   (tool_name . ,tool)
                                   (display_name . ,tool)
                                   (input . ((text . "x")))
                                   (tool_use_id . ,(concat "toolu-" tool))))))))
      (ecc-dispatch session (funcall request
                                     (format "mcp__%s__review_comment" ecc-mcp-server-name)))
      (should-not (ecc-session-pending session))
      (should (equal (alist-get 'behavior
                                (alist-get 'response
                                           (alist-get 'response
                                                      (car (last (ecc-test-sent-messages))))))
                     "allow"))
      (ecc-dispatch session (funcall request
                                     (format "mcp__%s__project_info" ecc-mcp-server-name)))
      (should (= 1 (length (ecc-session-pending session))))
      ;; A server of another name is not ours.
      (ecc-dispatch session (funcall request "mcp__other__review_comment"))
      (should (= 2 (length (ecc-session-pending session))))
      (let ((ecc-review-agent-auto-allow nil))
        (ecc-dispatch session (funcall request
                                       (format "mcp__%s__review_open" ecc-mcp-server-name)))
        (should (= 3 (length (ecc-session-pending session))))))))

(provide 'ecc-review-agent-test)

;;; ecc-review-agent-test.el ends here
