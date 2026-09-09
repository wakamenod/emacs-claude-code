;;; ecc-plan-test.el --- Tests for ecc-plan  -*- lexical-binding: t; -*-

;;; Commentary:

;; The feedback generator as a pure function, and the review buffer
;; driven through the recorded ExitPlanMode request (FR-PLAN-1 to 5).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-plan)
(require 'ecc-session)

(defconst ecc-plan-test--plan "# Plan\n\nCreate utils.py.\nAdd add(a, b).\nAdd sub(a, b).\n")

;;;; Pure functions

(ert-deftest ecc-plan-test-markers ()
  "@claude markers are found with the line before them as context."
  (should (equal (ecc-plan-markers "a\n\n@claude: do x\nb\n @Claude do y\n@claude:top")
                 '(("a" . "do x") ("b" . "do y") ("b" . "top"))))
  (should (equal (car (ecc-plan-markers "@claude: first")) '(nil . "first")))
  (should (equal (ecc-plan-strip-markers "a\n@claude: x\nb") "a\nb")))

(ert-deftest ecc-plan-test-feedback-nil-without-changes ()
  "An untouched plan gives no feedback, so it is approved (FR-PLAN-3)."
  (should-not (ecc-plan-feedback ecc-plan-test--plan ecc-plan-test--plan nil))
  (should-not (ecc-plan-feedback ecc-plan-test--plan ecc-plan-test--plan nil "  ")))

(ert-deftest ecc-plan-test-feedback-sections ()
  "Each kind of feedback gets its own section, in a fixed order."
  (let* ((edited (concat (string-replace "Add sub(a, b)." "Add subtract(a, b)."
                                         ecc-plan-test--plan)
                         "@claude: add mul too\n"))
         (comments '((3 "Create utils.py." "put it in src/")))
         (feedback (ecc-plan-feedback ecc-plan-test--plan edited comments "thanks")))
    (should (string-prefix-p "# Plan Feedback\n\n## Inline comments:\n" feedback))
    (should (string-search "- Line 3 (near \"Create utils.py.\"): \"put it in src/\"" feedback))
    (should (string-search "## @claude markers:\n- (after \"Add subtract(a, b).\") add mul too" feedback))
    (should (string-search "## Changes requested:\n```diff\n" feedback))
    (should (string-search "-Add sub(a, b).\n+Add subtract(a, b)." feedback))
    ;; The marker line itself is not part of the diff.
    (should-not (string-search "+@claude" feedback))
    (should (string-search "## General comment:\nthanks" feedback))
    (should (string-suffix-p ecc-plan-feedback-footer feedback))
    (should (< (string-search "## Inline" feedback)
               (string-search "## @claude" feedback)
               (string-search "## Changes" feedback)
               (string-search "## General" feedback)))))

(ert-deftest ecc-plan-test-feedback-comment-only ()
  "A comment alone is enough to turn the approval into a deny."
  (let ((feedback (ecc-plan-feedback ecc-plan-test--plan ecc-plan-test--plan
                                     '((4 "Add add(a, b)." "type hints")))))
    (should (string-search "## Inline comments:" feedback))
    (should-not (string-search "## Changes requested:" feedback))
    (should-not (string-search "## General comment:" feedback))))

;;;; The review buffer

(defun ecc-plan-test--request (session)
  "Feed the plan recording to SESSION and return the ExitPlanMode request."
  (let ((request (ecc-test-feed-until-request session "plan-mode" "計画して")))
    (should (eq (ecc-request-kind request) 'plan))
    request))

(ert-deftest ecc-plan-test-open ()
  "The buffer holds the plan, is editable and knows its request (FR-PLAN-1)."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-plan-test--request session))
           (buffer (ecc-plan-open request)))
      (with-current-buffer buffer
        (should (derived-mode-p 'ecc-plan-mode))
        (should-not buffer-read-only)
        (should (equal (buffer-string) (alist-get 'plan (ecc-request-input request))))
        (should (string-prefix-p "# Plan: utils.py" (buffer-string)))
        (should (eq ecc-plan--request request))
        (should-not ecc-plan--changes))
      ;; Opening again returns the same buffer.
      (should (eq (ecc-plan-open request) buffer))
      (should (equal (ecc-session-last-plan session) (ecc-plan-text request))))))

(ert-deftest ecc-plan-test-file-path ()
  "The buffer keeps the planFilePath the request carried."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-plan-test--request session))
           (buffer (ecc-plan-open request)))
      (should (equal (ecc-plan-file-path request)
                     "/Users/jun/.claude/plans/plan-do-not-implement-inherited-platypus.md"))
      (should (buffer-live-p buffer))))
  ;; A request without the field, or with an empty one, has no file.
  (should-not (ecc-plan-file-path (make-ecc-request :input '((plan . "# Plan")))))
  (should-not (ecc-plan-file-path
               (make-ecc-request :input '((plan . "# Plan") (planFilePath . ""))))))

(ert-deftest ecc-plan-test-visit-file-from-the-transcript ()
  "RET on a plan that was answered already opens its file."
  (let ((path (make-temp-file "ecc-plan-" nil ".md" "# Plan on disk\n")))
    (unwind-protect
        (ecc-test-with-fake-session session
          (ecc-session-ensure-buffer session)
          (let* ((request (ecc-plan-test--request session))
                 (node (ecc-request-node request)))
            (setf (ecc-request-input request)
                  (cons (cons 'planFilePath path)
                        (assq-delete-all 'planFilePath (ecc-request-input request))))
            (ecc-plan-approve-request request)
            (ecc-render-flush session)
            (with-current-buffer (ecc-session-buffer session)
              (should (ecc-render-goto-id (ecc-node-id node)))
              (let (opened)
                (cl-letf (((symbol-function 'find-file-other-window)
                           (lambda (file) (setq opened file))))
                  (ecc-session-visit))
                (should (equal opened path))))))
      (delete-file path))))

(ert-deftest ecc-plan-test-plan-section ()
  "The plan file is listed in the Plan section, where RET opens it.
The path is taken from the ExitPlanMode call, so it is there after a
resume too, where the permission request is not replayed."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (should-not (ecc-model-plan-files session))
    (let* ((request (ecc-plan-test--request session))
           (path (ecc-plan-file-path request)))
      ;; The tool call alone recorded it, before the request was answered.
      (should (equal (ecc-model-plan-files session) (list path)))
      ;; A plan shown again names the same file and is not listed twice.
      (ecc-model-note-plan-file session path)
      (should (equal (ecc-model-plan-files session) (list path)))
      (ecc-plan-approve-request request)
      (ecc-render-flush session)
      (with-current-buffer (ecc-session-buffer session)
        (should (string-search "Plan (1)" (ecc-test-buffer-string)))
        (should (string-search (abbreviate-file-name path) (ecc-test-buffer-string)))
        (should (ecc-render-goto-id (concat "plan:" path)))
        (should (equal (ecc-chat-plan-file-at-point) path))
        (should-not (ecc-chat-file-at-point))
        (let (opened)
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (file) (setq opened file))))
            (ecc-session-visit))
          (should (equal opened path)))
        ;; P moves to the section from anywhere in the buffer.
        (ecc-chat-goto-prompt)
        (ecc-chat-goto-plans)
        (should (equal (ecc-chat-heading-at-point) "plans"))))))

(ert-deftest ecc-plan-test-approve-clean ()
  "C-c C-c on an untouched plan allows and switches to acceptEdits (FR-PLAN-4)."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-plan-test--request session))
           (buffer (ecc-plan-open request)))
      (with-current-buffer buffer
        (should-not (ecc-plan-approve)))
      (should-not (buffer-live-p buffer))
      (should-not (ecc-session-pending session))
      (let ((response (ecc-test-response 0)))
        (should (equal (alist-get 'behavior response) "allow"))
        (should (equal (ecc-protocol-serialize (alist-get 'updatedPermissions response))
                       "[{\"type\":\"setMode\",\"mode\":\"acceptEdits\",\"destination\":\"session\"}]"))
        ;; The plan is echoed back untouched.
        (should (equal (alist-get 'plan (alist-get 'updatedInput response))
                       (ecc-plan-text request))))
      (should (equal (ecc-model-node-get (ecc-request-node request) 'outcome-message)
                     "approved → acceptEdits")))))

(ert-deftest ecc-plan-test-approve-with-chosen-mode ()
  "C-c m picks the mode; nil sends no permission change."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-plan-open (ecc-plan-test--request session))
      (ecc-plan-set-mode "plan")
      (ecc-plan-approve))
    (should (equal (alist-get 'mode (aref (alist-get 'updatedPermissions
                                                     (ecc-test-response 0))
                                          0))
                   "plan")))
  (ecc-test-with-fake-session session
    (let ((ecc-plan-default-mode nil))
      (with-current-buffer (ecc-plan-open (ecc-plan-test--request session))
        (ecc-plan-approve)))
    (should-not (assq 'updatedPermissions (ecc-test-response 0)))))

(ert-deftest ecc-plan-test-smart-approve-becomes-deny ()
  "A comment, a marker and an edit turn C-c C-c into a deny with 3 sections."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-plan-test--request session))
           (buffer (ecc-plan-open request)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line 2)
        (ecc-plan-comment "keep the functions one-liners")
        (should (= 1 (length (ecc-plan-comments))))
        (should (equal (nth 0 (car (ecc-plan-comments))) 3))
        (goto-char (point-max))
        (insert "@claude: add mul(a, b) as well\n")
        (goto-char (point-min))
        (search-forward "No tests requested")
        (replace-match "Add a doctest for each function")
        (let ((feedback (ecc-plan-approve)))
          (should (string-search "## Inline comments:\n- Line 3" feedback))
          (should (string-search "keep the functions one-liners" feedback))
          (should (string-search "## @claude markers:" feedback))
          (should (string-search "add mul(a, b) as well" feedback))
          (should (string-search "## Changes requested:" feedback))
          (should (string-search "+Add a doctest for each function" feedback))
          (should-not (string-search "## General comment:" feedback))))
      (should-not (buffer-live-p buffer))
      (let ((response (ecc-test-response 0)))
        (should (equal (alist-get 'behavior response) "deny"))
        (should (string-prefix-p "# Plan Feedback" (alist-get 'message response))))
      (should (eq (ecc-node-status (ecc-request-node request)) 'denied)))))

(ert-deftest ecc-plan-test-explicit-deny ()
  "C-c C-k sends the reason as the general comment, with anything else found."
  (ecc-test-with-fake-session session
    (let ((request (ecc-plan-test--request session)))
      (with-current-buffer (ecc-plan-open request)
        (ecc-plan-comment "why?")
        (ecc-plan-deny "start over"))
      (let ((message (alist-get 'message (ecc-test-response 0))))
        (should (string-search "## Inline comments:" message))
        (should (string-search "## General comment:\nstart over" message))))
    ;; With nothing at all the message still asks for a plan.
    (ecc-test-with-fake-session session
      (with-current-buffer (ecc-plan-open (ecc-plan-test--request session))
        (ecc-plan-deny ""))
      (should (string-search "rejected" (alist-get 'message (ecc-test-response 0)))))))

(ert-deftest ecc-plan-test-comment-overlay-and-removal ()
  "A comment is drawn on its line and can be taken off again (FR-PLAN-2 a)."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-plan-open (ecc-plan-test--request session))
      (goto-char (point-min))
      (let ((overlay (ecc-plan-comment "first")))
        (should (overlay-get overlay 'after-string))
        (should (string-search "first" (overlay-get overlay 'after-string)))
        ;; A second comment on the same line replaces the first.
        (ecc-plan-comment "second")
        (should (= 1 (length (ecc-plan-comments))))
        (should (equal (nth 2 (car (ecc-plan-comments))) "second"))
        (ecc-plan-remove-comment)
        (should-not (ecc-plan-comments))
        (should-error (ecc-plan-remove-comment) :type 'user-error)))))

(ert-deftest ecc-plan-test-changed-lines-since-previous ()
  "A plan shown again marks the lines that are new (FR-PLAN-5)."
  (ecc-test-with-fake-session session
    (let ((request (ecc-plan-test--request session)))
      (with-current-buffer (ecc-plan-open request)
        (ecc-plan-approve))
      ;; The revised plan arrives as a new request.
      (let* ((revised (concat (ecc-plan-text request) "Also add mul(a, b).\n"))
             (node (ecc-model-add-node session :type 'plan :status 'pending))
             (second (make-ecc-request
                      :request-id "req-plan-2" :session session :kind 'plan
                      :tool-name "ExitPlanMode" :display-name "ExitPlanMode"
                      :input `((plan . ,revised)) :tool-use-id "toolu_p2"
                      :created-at (current-time) :node node)))
        (ecc-model-node-put node 'request second)
        (ecc-model-add-request session second)
        (with-current-buffer (ecc-plan-open second)
          (should (equal ecc-plan--changes '(1 . 0)))
          (should (equal (ecc-plan-changed-lines)
                         (list (length (split-string (ecc-plan-text request) "\n")))))
          (goto-char (point-min))
          (ecc-plan-next-change)
          (should (looking-at "Also add mul"))
          (should-error (ecc-plan-next-change) :type 'user-error)
          (ecc-plan-approve))))))

(ert-deftest ecc-plan-test-approve-request-without-buffer ()
  "`a' on the plan section approves as it stands with the default mode."
  (ecc-test-with-fake-session session
    (let ((request (ecc-plan-test--request session)))
      (should (eq (ecc-perm-allow-request request) 'allow))
      (should-not (ecc-session-pending session))
      (should (equal (alist-get 'mode (aref (alist-get 'updatedPermissions
                                                       (ecc-test-response 0))
                                            0))
                     "acceptEdits")))))

(ert-deftest ecc-plan-test-buffer-closes-when-answered-elsewhere ()
  "Answering the plan from another buffer takes the review buffer away."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-plan-test--request session))
           (buffer (ecc-plan-open request)))
      (ecc-perm-respond request 'deny :message "elsewhere")
      (should-not (buffer-live-p buffer))
      (with-temp-buffer
        (should-error (ecc-plan-approve) :type 'user-error)))))

(ert-deftest ecc-plan-test-show-diff ()
  "C-c C-d shows the edits as a diff, and complains when there is none."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-plan-open (ecc-plan-test--request session))
      (should-error (ecc-plan-show-diff) :type 'user-error)
      (goto-char (point-max))
      (insert "One more line.\n")
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
        (ecc-plan-show-diff))
      (should (string-search "+One more line." (with-current-buffer "*ecc-plan-diff*"
                                                 (buffer-string)))))))

(provide 'ecc-plan-test)

;;; ecc-plan-test.el ends here
