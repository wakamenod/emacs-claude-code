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
      (should (string-search "2 hunks" text))
      (should (string-search "foo.el\n  hunk 1  @@ -1,3 +1,3 @@  new L1-L3\n" text))
      (should (string-search "  hunk 2  @@ -10,2 +10,3 @@  new L10-L12\n" text))
      (should-not (string-search "+added" text)))
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
                                              '((file . "other.el")))
                   "No comments."))
    (should (car (ecc-review-agent-test--call session "review_list_comments"
                                              '((author . "nobody")))))
    ;; Clearing takes Claude's and keeps the user's.
    (should (string-search "Removed 1 comments.  The user's 2 were kept"
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
              (should (string-search "everything changed since the session started: 1 files, 1 hunks"
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
