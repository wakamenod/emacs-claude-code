;;; ecc-perm-test.el --- Tests for ecc-perm  -*- lexical-binding: t; -*-

;;; Commentary:

;; Answering a can_use_tool request: what goes on the wire, what happens
;; to the queue and what the transcript remembers (FR-PERM-1, 2, 5, 6).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-perm)
(require 'ecc-session)
(require 'ecc-dispatch)

(defun ecc-perm-test--request (session &optional name)
  "Add a pending request for tool NAME to SESSION and return it."
  (let* ((tool (or name "Write"))
         (node (ecc-model-add-node session :type 'permission :status 'pending))
         (request (make-ecc-request
                   :request-id "req-1" :session session
                   :kind (ecc-dispatch--request-kind tool)
                   :tool-name tool :display-name tool
                   :input '((file_path . "/tmp/a.txt") (content . "hi"))
                   :tool-use-id "toolu_1" :created-at (current-time)
                   :node node)))
    (ecc-model-node-put node 'request request)
    (setf (ecc-request-node request) node)
    (ecc-model-add-request session request)
    request))

(ert-deftest ecc-perm-test-allow ()
  "Allow echoes the input back unchanged (12.3)."
  (ecc-test-with-fake-session session
    (let ((request (ecc-perm-test--request session)))
      (ecc-perm-respond request 'allow)
      (should (equal (ecc-protocol-serialize (car (ecc-test-sent-messages)))
                     (concat "{\"type\":\"control_response\",\"response\":"
                             "{\"subtype\":\"success\",\"request_id\":\"req-1\","
                             "\"response\":{\"behavior\":\"allow\","
                             "\"updatedInput\":{\"file_path\":\"/tmp/a.txt\","
                             "\"content\":\"hi\"}}}}")))
      (should-not (ecc-session-pending session))
      (should (eq (ecc-node-status (ecc-request-node request)) 'done)))))

(ert-deftest ecc-perm-test-deny-with-a-reason ()
  "Deny sends the reason Claude will read (FR-PERM-2, 12.4)."
  (ecc-test-with-fake-session session
    (let ((request (ecc-perm-test--request session)))
      (ecc-perm-respond request 'deny :message "内容を hi にして")
      (let ((response (alist-get 'response
                                 (alist-get 'response (car (ecc-test-sent-messages))))))
        (should (equal (alist-get 'behavior response) "deny"))
        (should (equal (alist-get 'message response) "内容を hi にして")))
      (should (eq (ecc-node-status (ecc-request-node request)) 'denied))
      ;; The transcript keeps the reason next to the request.
      (should (equal (ecc-model-node-get (ecc-request-node request) 'outcome-message)
                     "内容を hi にして")))))

(ert-deftest ecc-perm-test-deny-without-a-reason ()
  "An empty reason still says something; the CLI needs a message."
  (ecc-test-with-fake-session session
    (ecc-perm-respond (ecc-perm-test--request session) 'deny :message "")
    (let ((response (alist-get 'response
                               (alist-get 'response (car (ecc-test-sent-messages))))))
      (should (equal (alist-get 'message response) ecc-perm-default-deny-message)))))

(ert-deftest ecc-perm-test-allow-with-mode ()
  "An allow can carry a permission mode change (12.5)."
  (ecc-test-with-fake-session session
    (ecc-perm-respond (ecc-perm-test--request session) 'allow
                      :updated-permissions
                      (vector (ecc-protocol-set-mode-suggestion "acceptEdits")))
    (let ((response (alist-get 'response
                               (alist-get 'response (car (ecc-test-sent-messages))))))
      (should (equal (alist-get 'mode (aref (alist-get 'updatedPermissions response) 0))
                     "acceptEdits")))))

(ert-deftest ecc-perm-test-commands-find-the-oldest ()
  "With no request at point the oldest waiting one is answered (FR-PERM-6)."
  (ecc-test-with-fake-session session
    (let ((first (ecc-perm-test--request session))
          (second (ecc-perm-test--request session "Bash")))
      (setf (ecc-request-request-id second) "req-2")
      (ecc-perm-deny "no")
      (should (equal (ecc-session-pending session) (list second)))
      (should (eq (ecc-node-status (ecc-request-node first)) 'denied))
      (ecc-perm-allow)
      (should-not (ecc-session-pending session)))))

(ert-deftest ecc-perm-test-request-at-point ()
  "In a session buffer the request under the point wins."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (let ((first (ecc-perm-test--request session))
          (second (ecc-perm-test--request session "Bash")))
      (setf (ecc-request-request-id second) "req-2")
      (ecc-render-flush session)
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-max))
        (search-backward "Permission: Bash")
        (should (eq (ecc-perm-request-at-point) second))
        (ecc-perm-allow)
        (should (equal (ecc-session-pending session) (list first)))))))

(ert-deftest ecc-perm-test-question-options ()
  "The labels offered for a question are the ones the CLI sent."
  (let* ((request (ecc-test-find-message
                   "ask-user-question"
                   (lambda (m) (eq (ecc-protocol-control-subtype m) 'can_use_tool))))
         (questions (alist-get 'questions (ecc-protocol-request-input request))))
    (should (equal (ecc-perm-question-options (aref questions 0))
                   '("Emacs" "Vim")))
    ;; multiSelect stays false rather than turning into null (9.5).
    (should (eq (alist-get 'multiSelect (aref questions 0)) :false))))

(provide 'ecc-perm-test)

;;; ecc-perm-test.el ends here
