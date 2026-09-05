;;; ecc-dispatch-test.el --- Replay tests for ecc-dispatch  -*- lexical-binding: t; -*-

;;; Commentary:

;; The recorded fixtures are fed to a session that has no process, and
;; the shape of the resulting model is compared against what section 4 of
;; IMPLEMENTATION_PLAN.md says it should be.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-model)
(require 'ecc-dispatch)
(require 'ecc-perm)

;;;; basic-turn

(ert-deftest ecc-dispatch-test-basic-turn ()
  "One prompt gives one turn that ends idle with a cost."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "basic-turn" "hello")
    (should (= (length (ecc-session-turns session)) 1))
    (let ((turn (car (ecc-session-turns session))))
      ;; The empty thinking block is kept even though the renderer skips it.
      (should (equal (ecc-test-turn-shape turn) '(thinking text result)))
      (should (equal (ecc-turn-prompt turn) "hello"))
      (should (ecc-turn-end-time turn)))
    (should-not (ecc-session-current-turn session))
    (should (eq (ecc-session-state session) 'idle))
    (should (> (ecc-session-total-cost session) 0))
    (should (> (ecc-session-context-tokens session) 0))
    ;; system/init filled in what the CLI decided for us.
    (should (equal (alist-get 'model (ecc-session-init session))
                   "claude-haiku-4-5-20251001"))
    (should (equal (ecc-session-permission-mode session) "default"))
    ;; The initialize response carries the slash commands (FR-SES-8).
    (should (> (length (ecc-session-commands session)) 0))
    ;; rate_limit_event arrives at the top level, not inside system.
    (should (ecc-session-rate-limit session))))

(ert-deftest ecc-dispatch-test-init-is-idempotent ()
  "system/init arrives once per turn and must not rebuild the session."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "slash-commands" "/context")
    ;; Four commands were sent in the recording, so four inits arrived.
    (should (= (length (ecc-session-turns session)) 4))
    (should (= (hash-table-count ecc--sessions) 1))
    (should (eq (ecc-model-session (ecc-session-id session)) session))))

;;;; tool-use-write

(ert-deftest ecc-dispatch-test-tool-use ()
  "A tool call becomes a step with one tool that its result completes."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "tool-use-write" "hello.txt を作って")
    (let ((turn (car (ecc-session-turns session))))
      (should (equal (ecc-test-turn-shape turn)
                     '(thinking (step tool) permission thinking text result)))
      (let ((tool (car (ecc-node-children (nth 1 (ecc-turn-children turn))))))
        (should (equal (ecc-model-node-get tool 'name) "Write"))
        (should (eq (ecc-node-status tool) 'done))
        (should (string-prefix-p "File created successfully"
                                 (ecc-model-node-get tool 'result)))
        ;; tool_use and tool_result found each other by id (FR-OUT-5).
        (should (eq tool (ecc-model-node
                          session "toolu_01Hcu5xtMTxBqGiZ6MfT3XyZ")))))
    ;; The file Claude wrote was recorded (FR-OUT-12).
    (should (= 1 (hash-table-count (ecc-session-files session))))
    (let ((entry (car (hash-table-values (ecc-session-files session)))))
      (should (= (ecc-file-entry-writes entry) 1)))))

(ert-deftest ecc-dispatch-test-permission-request ()
  "A can_use_tool request queues up and waits for an answer (FR-PERM-1)."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "hello.txt を作って")
    (dolist (line (ecc-test-fixture-lines "tool-use-write"))
      (let ((message (ecc-protocol-parse-line line)))
        (ecc-dispatch session message)
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          ;; While it is unanswered the session says so.
          (should (eq (ecc-session-state session) 'waiting-permission))
          (let ((request (car (ecc-session-pending session))))
            (should (equal (ecc-request-tool-name request) "Write"))
            (should (eq (ecc-request-kind request) 'permission))
            (should (equal (ecc-request-request-id request)
                           (alist-get 'request_id message)))
            (should (eq (ecc-node-status (ecc-request-node request)) 'pending))
            (ecc-perm-respond request 'allow)
            (should-not (ecc-session-pending session))
            (should (eq (ecc-node-status (ecc-request-node request)) 'done))))))
    (let ((sent (ecc-test-sent-messages)))
      (should (= (length sent) 1))
      (should (equal (alist-get 'behavior
                                (alist-get 'response (alist-get 'response (car sent))))
                     "allow")))))

(ert-deftest ecc-dispatch-test-file-changed-hook ()
  "A successful write tells the rest of Emacs to reload the file (FR-SYNC-1)."
  (ecc-test-with-fake-session session
    (let (changed)
      (let ((ecc-sync-file-changed-hook
             (list (lambda (_session path) (push path changed)))))
        (ecc-test-dispatch session "tool-use-write" "hello.txt を作って"))
      (should (= (length changed) 1))
      (should (string-suffix-p "hello.txt" (car changed))))))

;;;; permission-deny-retry

(ert-deftest ecc-dispatch-test-deny-then-allow ()
  "Denying with a reason makes Claude try again in the same turn."
  (ecc-test-with-fake-session session
    (let ((answers '(deny allow)))
      (dolist (line (ecc-test-fixture-lines "permission-deny-retry"))
        (let ((message (ecc-protocol-parse-line line)))
          (ecc-dispatch session message)
          (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
            (let ((request (car (ecc-session-pending session))))
              (if (eq (pop answers) 'deny)
                  (ecc-perm-respond request 'deny :message "内容を hi にして")
                (ecc-perm-respond request 'allow)))))))
    (let ((turn (car (ecc-session-turns session))))
      (should (equal (ecc-test-turn-shape turn)
                     '(thinking (step tool) permission
                       thinking (step tool) permission thinking text result))))
    (let* ((sent (ecc-test-sent-messages))
           (responses (mapcar (lambda (object)
                                (alist-get 'response
                                           (alist-get 'response object)))
                              sent)))
      (should (equal (mapcar (lambda (r) (alist-get 'behavior r)) responses)
                     '("deny" "allow")))
      (should (equal (alist-get 'message (car responses)) "内容を hi にして")))))

;;;; ask-user-question

(ert-deftest ecc-dispatch-test-question ()
  "AskUserQuestion is a question, not a permission (FR-PERM-5)."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "質問して")
    (dolist (line (ecc-test-fixture-lines "ask-user-question"))
      (let ((message (ecc-protocol-parse-line line)))
        (ecc-dispatch session message)
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (let ((request (car (ecc-session-pending session))))
            (should (eq (ecc-request-kind request) 'question))
            (should (eq (ecc-session-state session) 'waiting-question))
            ;; Answer the way the minimal user interface does.
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "Emacs"))
                      ((symbol-function 'completing-read-multiple)
                       (lambda (&rest _) '("Elisp" "Python"))))
              (ecc-perm-allow))))))
    (let* ((response (alist-get 'response
                                (alist-get 'response
                                           (car (ecc-test-sent-messages)))))
           (answers (alist-get 'answers (alist-get 'updatedInput response))))
      (should (equal (alist-get 'behavior response) "allow"))
      ;; Every question is answered in one object keyed by its text, and a
      ;; multiSelect answer is one comma separated string (verified.md).
      (should (= (length answers) 2))
      (should (member '(Which\ editor\ do\ you\ prefer\? . "Emacs") answers))
      (should (seq-find (lambda (pair) (equal (cdr pair) "Elisp, Python")) answers))
      ;; The questions are echoed back untouched.
      (should (equal (alist-get 'questions (alist-get 'updatedInput response))
                     (alist-get 'questions
                                (ecc-protocol-request-input
                                 (ecc-test-find-message
                                  "ask-user-question"
                                  (lambda (m) (eq (ecc-protocol-control-subtype m)
                                                  'can_use_tool))))))))))

;;;; plan-mode

(ert-deftest ecc-dispatch-test-plan ()
  "ExitPlanMode is a plan review."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "計画して")
    (dolist (line (ecc-test-fixture-lines "plan-mode"))
      (let ((message (ecc-protocol-parse-line line)))
        (ecc-dispatch session message)
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (let ((request (car (ecc-session-pending session))))
            (when (eq (ecc-request-kind request) 'plan)
              (should (eq (ecc-session-state session) 'waiting-plan))
              (should (alist-get 'plan (ecc-request-input request))))
            (ecc-perm-respond request 'allow)))))
    (should-not (ecc-session-pending session))))

;;;; compact, replay, subagent and hook events

(ert-deftest ecc-dispatch-test-compact ()
  "The compacting status and its result are both handled (12.8)."
  (ecc-test-with-fake-session session
    (let (compacted)
      (let ((ecc-compact-hook (list (lambda (&rest _) (push t compacted)))))
        (ecc-model-begin-turn session "/compact")
        (ecc-model-update-usage session '((input_tokens . 500)))
        (dolist (line (ecc-test-fixture-lines "compact"))
          (ecc-dispatch session (ecc-protocol-parse-line line))))
      (should compacted))
    ;; The status arrives between turns, so the node lands in the
    ;; implicit turn the model opens for it.
    ;; Both the closing status and the compact_boundary that follows it
    ;; are kept; only the status says how it went.
    (let ((nodes (seq-filter (lambda (n) (equal (ecc-model-node-get n 'kind) 'compact))
                             (hash-table-values (ecc-session-nodes session)))))
      (should (= (length nodes) 2))
      (should (member "success" (mapcar (lambda (n) (ecc-model-node-get n 'result))
                                        nodes))))
    (should (= (ecc-session-context-tokens session) 0))))

(ert-deftest ecc-dispatch-test-replay-echo-adds-nothing ()
  "The echo of a prompt is an acknowledgement, not a message (D5)."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "replay-user-messages" "Reply with exactly: ONE")
    (dolist (turn (ecc-session-turns session))
      (dolist (node (ecc-turn-children turn))
        (should-not (and (eq (ecc-node-type node) 'system)
                         (equal (ecc-model-node-get node 'kind) 'note)))))
    (should (equal (alist-get 'replayed (ecc-session-progress session))
                   "Reply with exactly: TWO"))))

(ert-deftest ecc-dispatch-test-subagent-nesting ()
  "Messages of a subagent hang under the tool that started it (FR-OUT-9)."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "subagent" "探して")
    (let ((agent (seq-find (lambda (node) (eq (ecc-node-type node) 'agent))
                           (hash-table-values (ecc-session-nodes session)))))
      (should agent)
      (should (> (length (ecc-node-children agent)) 0))
      ;; The task lifecycle found the same node by its tool_use_id.
      (should (ecc-model-node-get agent 'task))
      (should (> (hash-table-count (ecc-session-tasks session)) 0)))))

(ert-deftest ecc-dispatch-test-hook-events ()
  "Hook events are kept as system nodes rather than as unknown ones."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "hook-events" "hello")
    (let ((nodes (hash-table-values (ecc-session-nodes session))))
      (should (seq-find (lambda (node)
                          (and (eq (ecc-node-type node) 'system)
                               (equal (ecc-model-node-get node 'kind) 'hook)))
                        nodes))
      (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                            nodes)))))

(ert-deftest ecc-dispatch-test-no-fixture-line-is-unknown ()
  "Nothing in any recording falls through the table of section 4."
  (dolist (name (ecc-test-fixture-names))
    (ecc-test-with-fake-session session
      (ecc-test-dispatch session name "prompt")
      (let ((unknown (seq-filter (lambda (node)
                                   (eq (ecc-node-type node) 'unknown))
                                 (hash-table-values (ecc-session-nodes session)))))
        (should (equal (cons name (length unknown)) (cons name 0)))))))

;;;; Robustness (NFR-2, plan section 9, item 19)

(ert-deftest ecc-dispatch-test-unknown-message-is-kept ()
  "A message this version does not know is shown, not dropped."
  (ecc-test-with-fake-session session
    (ecc-dispatch session (ecc-protocol-parse-line "{not json"))
    (ecc-dispatch session '((type . "brand_new_thing")))
    (let ((nodes (hash-table-values (ecc-session-nodes session))))
      (should (= 2 (length (seq-filter (lambda (n) (eq (ecc-node-type n) 'unknown))
                                       nodes)))))))

(ert-deftest ecc-dispatch-test-error-is-not-swallowed ()
  "An error while handling a message lands in the transcript and the log."
  (ecc-test-with-fake-session session
    (cl-letf (((symbol-function 'ecc-dispatch--assistant)
               (lambda (&rest _) (error "boom"))))
      (ecc-dispatch session '((type . "assistant") (uuid . "u1"))))
    (let ((node (car (hash-table-values (ecc-session-nodes session)))))
      (should (eq (ecc-node-type node) 'unknown))
      (should (string-search "boom" (ecc-model-node-get node 'reason))))
    (with-current-buffer (ecc--log-buffer (ecc-session-name session))
      (should (string-search "dispatch error" (buffer-string))))))

;;;; Automatic approval (FR-PERM-7, FR-PERM-9)

(ert-deftest ecc-dispatch-test-auto-approve ()
  "A turn wide approval answers matching requests without queueing them."
  (ecc-test-with-fake-session session
    (setf (ecc-session-auto-approve-turn session) t)
    (ecc-model-begin-turn session "書いて")
    (dolist (line (ecc-test-fixture-lines "tool-use-write"))
      (ecc-dispatch session (ecc-protocol-parse-line line)))
    (should-not (ecc-session-pending session))
    (let ((sent (ecc-test-sent-messages)))
      (should (= (length sent) 1))
      (should (equal (alist-get 'behavior
                                (alist-get 'response (alist-get 'response (car sent))))
                     "allow")))
    ;; A tool that is not on the list still asks.
    (setf (ecc-session-auto-approve-kinds session) '("Bash"))
    (should (ecc-dispatch-auto-approve-p
             session (make-ecc-request :kind 'permission :tool-name "Bash")))
    (should-not (ecc-dispatch-auto-approve-p
                 session (make-ecc-request :kind 'permission :tool-name "Grep")))))

;;;; The input queue drains when the turn ends (FR-INP-6)

(ert-deftest ecc-dispatch-test-queue-drains-on-result ()
  "A prompt that waited for the turn goes out as soon as the result lands."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "one")
    (should (= (ecc-proc-send-prompt session "two") 1))
    (ecc-dispatch session '((type . "result") (subtype . "success")
                            (total_cost_usd . 0.1)))
    (should-not (ecc-session-input-queue session))
    (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "two"))
    (let ((sent (car (last (ecc-test-sent-messages)))))
      (should (equal (alist-get 'content (alist-get 'message sent)) "two")))))

(provide 'ecc-dispatch-test)

;;; ecc-dispatch-test.el ends here
