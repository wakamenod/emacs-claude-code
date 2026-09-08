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
            ;; Answer in the question buffer (FR-PERM-5).
            (with-current-buffer (ecc-question-open request)
              (ecc-question-choose 1)
              (ecc-question-choose 1)
              (ecc-question-choose 2)
              (ecc-question-submit))))))
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

(ert-deftest ecc-dispatch-test-result-closes-an-unanswered-question ()
  "A turn that ends leaves no question waiting, and no buffer for it.
An interrupt ends the turn with a result while the question is still on
screen; left pending, it would blink for an answer nobody wants."
  (ecc-test-with-fake-session session
    (let* ((request (ecc-test-feed-until-request session "ask-user-question" "質問して"))
           (node (ecc-request-node request))
           (buffer (ecc-question-open request))
           (sent (length (ecc-test-sent-messages))))
      (should (eq (ecc-session-state session) 'waiting-question))
      (ecc-dispatch session '((type . "result")
                              (subtype . "error_during_execution")
                              (is_error . t)))
      (should-not (ecc-session-pending session))
      (should (eq (ecc-session-state session) 'idle))
      (should (eq (ecc-node-status node) 'denied))
      ;; Nothing is sent back: the CLI is not listening for it any more.
      (should (= sent (length (ecc-test-sent-messages))))
      (should-not (buffer-live-p buffer)))))

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
    ;; The estimate of what is in the window starts again from what the
    ;; boundary says is left of the conversation (FR-HINT-5); the
    ;; recording of this fixture compacted 17496 tokens down to 1339.
    (should (= (ecc-session-context-tokens session) 1339))))

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
      ;; The task lifecycle found the same node by its tool_use_id and
      ;; told us what kind of agent it is.
      (should (ecc-model-node-get agent 'task))
      (should (equal (ecc-model-node-get agent 'agent-type) "Explore"))
      (should (equal (ecc-model-node-get agent 'task-status) "completed"))
      ;; The prompt, the thinking, the one Bash call and the reply of the
      ;; agent hang under it, tools grouped in steps like a turn.
      (should (equal (ecc-test-node-shape (ecc-node-children agent))
                     '(system thinking (step tool) thinking text)))
      ;; An agent is not a TODO item (FR-OUT-13).
      (should (= (hash-table-count (ecc-session-tasks session)) 0)))))

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

(ert-deftest ecc-dispatch-test-system-subtype-list-is-current ()
  "Every subtype `ecc-dispatch-system-subtypes' names is really handled.
`ecc-history' trusts the list to tell a subtype of the stream from one
only a recording holds, so it may not drift from the table."
  (dolist (subtype ecc-dispatch-system-subtypes)
    (ecc-test-with-fake-session session
      (ecc-dispatch session `((type . "system") (subtype . ,subtype)))
      (should (equal (cons subtype 0)
                     (cons subtype
                           (length (seq-filter
                                    (lambda (node)
                                      (eq (ecc-node-type node) 'unknown))
                                    (hash-table-values
                                     (ecc-session-nodes session)))))))))
  ;; A subtype that is not in the list does land among the unknown ones.
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "system") (subtype . "away_summary")))
    (should (= 1 (length (seq-filter (lambda (node)
                                       (eq (ecc-node-type node) 'unknown))
                                     (hash-table-values
                                      (ecc-session-nodes session))))))))

(ert-deftest ecc-dispatch-test-bridge-state ()
  "Remote Control reports itself as system/bridge_state, not as the unknown.
Two of them arrive, `ready' and then `connected', and only the second
carries the epoch of the bridge (docs/verified.md, 2026-09-08)."
  (ecc-test-with-fake-session session
    (let ((announced 0))
      (let ((ecc-remote-control-functions
             (list (lambda (_session) (cl-incf announced)))))
        (ecc-dispatch session '((type . "system") (subtype . "bridge_state")
                                (state . "ready") (session_id . "s1")))
        (should (equal (ecc-model-remote-control session 'state) "ready"))
        (should-not (ecc-model-remote-control session 'bridge-epoch))
        (ecc-dispatch session '((type . "system") (subtype . "bridge_state")
                                (state . "connected") (bridge_epoch . 1)
                                (session_id . "s1")))
        (should (equal (ecc-model-remote-control session 'state) "connected"))
        (should (equal (ecc-model-remote-control session 'bridge-epoch) 1))
        (should (ecc-model-remote-control session 'enabled))
        (should (= 2 announced)))
      (let ((nodes (hash-table-values (ecc-session-nodes session))))
        (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                              nodes))
        (should (equal '("remote control connected" "remote control ready")
                       (sort (mapcar (lambda (node)
                                       (ecc-model-node-get node 'text))
                                     (seq-filter
                                      (lambda (node)
                                        (eq (ecc-model-node-get node 'kind)
                                            'remote-control))
                                      nodes))
                             #'string<)))))))

(ert-deftest ecc-dispatch-test-bridge-state-leaves-the-session-idle ()
  "The bridge reporting itself between turns starts no turn.
The turn would never end, so the session would say `running' for ever
and the next prompt would queue behind it."
  (ecc-test-with-fake-session session
    (ecc-model-set-state session 'idle)
    (ecc-dispatch session '((type . "system") (subtype . "bridge_state")
                            (state . "connected") (bridge_epoch . 1)))
    (should (eq (ecc-session-state session) 'idle))
    (should-not (ecc-session-current-turn session))
    ;; The turn it hangs on says what it is, rather than "(resumed)".
    (should (equal "(session)" (ecc-turn-label (car (ecc-session-turns session)))))
    ;; A later notice joins the same turn instead of adding another.
    (ecc-dispatch session '((type . "system") (subtype . "bridge_state")
                            (state . "disconnected")))
    (should (= 1 (length (ecc-session-turns session))))))

(ert-deftest ecc-dispatch-test-a-remote-turn-says-so ()
  "An answer to a prompt sent from elsewhere is not a resumed turn.
The CLI does not echo user messages to a stream-json client, so a turn
somebody started from the bridge arrives with no prompt of its own; it
would otherwise read as \"(resumed)\", which is what a recording looks
like."
  (ecc-test-with-fake-session session
    (ecc-model-set-remote-control session 'enabled t 'state "connected")
    (ecc-dispatch session '((type . "assistant")
                            (message . ((role . "assistant")
                                        (model . "claude-opus-5")
                                        (content . [((type . "text")
                                                     (text . "はい"))])))))
    (let ((turn (car (ecc-session-turns session))))
      (should (equal "(remote)" (ecc-turn-label turn)))
      (should-not (ecc-turn-prompt turn)))
    ;; Without the bridge it stays what it was.
    (ecc-test-with-fake-session other
      (ecc-dispatch other '((type . "assistant")
                            (message . ((role . "assistant")
                                        (model . "claude-opus-5")
                                        (content . [((type . "text")
                                                     (text . "はい"))])))))
      (should-not (ecc-turn-label (car (ecc-session-turns other)))))))

(ert-deftest ecc-dispatch-test-bridge-state-detail ()
  "A state that needs explaining brings a detail, and it is shown."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "system") (subtype . "bridge_state")
                            (state . "disconnected") (detail . "network lost")))
    (should (equal (ecc-model-remote-control session 'detail) "network lost"))
    (should (seq-find
             (lambda (node)
               (equal (ecc-model-node-get node 'text)
                      "remote control disconnected — network lost"))
             (hash-table-values (ecc-session-nodes session))))))

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


;;;; Streaming (FR-OUT-4)

(ert-deftest ecc-dispatch-test-stream-blocks ()
  "A streamed block is one node from its start to its completion."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "長いファイルを書いて")
    (let* ((deltas nil)
           (ecc-stream-delta-hook
            (list (lambda (_session node text) (push (cons (ecc-node-type node) text) deltas)))))
      (dolist (line (ecc-test-fixture-lines "partial-messages"))
        (let ((message (ecc-protocol-parse-line line)))
          (ecc-dispatch session message)
          (let ((event (alist-get 'event message)))
            (when (and (equal (alist-get 'type event) "content_block_start")
                       (equal (alist-get 'type (alist-get 'content_block event)) "tool_use"))
              ;; The tool node exists as soon as its block starts, with no
              ;; input yet, under a step of the turn.
              (let ((node (ecc-model-node session "toolu_01QcvmkL7eVaiQDvpEut8Pak")))
                (should node)
                (should (ecc-node-streaming node))
                (should-not (ecc-model-node-get node 'input))
                (should (eq (ecc-node-type (ecc-node-parent node)) 'step)))))))
      (setq deltas (nreverse deltas))
      ;; 29 input deltas of which one is empty, and 17 text deltas (verified.md).
      (should (= 28 (cl-count 'tool deltas :key #'car)))
      (should (= 17 (cl-count 'text deltas :key #'car)))
      (should (equal (apply #'concat (mapcar #'cdr (seq-filter (lambda (d) (eq (car d) 'text))
                                                               deltas)))
                     "Done. Created `long.py` with 60 functions (f0 through f59), each with a one-line docstring and return statement, separated by blank lines. The file is approximately 300 lines.")))
    ;; Afterwards the tree is the one of an unstreamed turn, the tool has
    ;; its full input, and nothing is left open.
    (let* ((turn (car (ecc-session-turns session)))
           (tool (ecc-model-node session "toolu_01QcvmkL7eVaiQDvpEut8Pak")))
      (should (equal (ecc-test-turn-shape turn)
                     '(thinking (step tool) permission thinking text result)))
      (should-not (ecc-node-streaming tool))
      (should (string-suffix-p "long.py" (alist-get 'file_path (ecc-model-node-get tool 'input))))
      (should (eq (ecc-node-status tool) 'done))
      (should (= 0 (hash-table-count (ecc-session-stream-blocks session)))))))

(ert-deftest ecc-dispatch-test-stream-stop-without-message ()
  "A block that stops without its assistant message keeps the streamed text."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "hi")
    (dolist (event '(((type . "content_block_start") (index . 0)
                      (content_block . ((type . "text") (text . ""))))
                     ((type . "content_block_delta") (index . 0)
                      (delta . ((type . "text_delta") (text . "Hel"))))
                     ((type . "content_block_delta") (index . 0)
                      (delta . ((type . "text_delta") (text . "lo"))))
                     ((type . "content_block_stop") (index . 0))))
      (ecc-dispatch session (list (cons 'type "stream_event") (cons 'event event))))
    (let ((node (car (ecc-turn-children (ecc-session-current-turn session)))))
      (should (eq (ecc-node-type node) 'text))
      (should (equal (ecc-model-node-get node 'text) "Hello"))
      (should (eq (ecc-node-status node) 'done))
      (should-not (ecc-node-streaming node)))))

;;;; Files and tasks from tool_use_result (FR-OUT-12, FR-OUT-13)

(ert-deftest ecc-dispatch-test-edit-records-hunk-and-snapshot ()
  "An Edit keeps the patch the CLI reported and what the file became."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "edit-tool" "greet を直して")
    (let ((entry (car (ecc-model-files session))))
      (should (string-suffix-p "hello.py" (ecc-file-entry-path entry)))
      (should (= (ecc-file-entry-reads entry) 1))
      (should (= (ecc-file-entry-edits entry) 1))
      (should (= (length (ecc-file-entry-hunks entry)) 1))
      (should (equal (car (ecc-file-entry-hunks entry))
                     '("    return \"hi \" + name" . "    return \"hello \" + name")))
      (should (= 1 (length (car (ecc-file-entry-patches entry)))))
      ;; The Read filled the snapshot; the Edit updated it.
      (should (string-search "return \"hello \" + name" (ecc-file-entry-snapshot entry)))
      (should-not (string-search "return \"hi \" + name" (ecc-file-entry-snapshot entry))))
    ;; Both the tool node and the permission node knew the file before
    ;; the change, from the Read (FR-DIFF-1).
    (let ((edit (seq-find (lambda (n) (and (eq (ecc-node-type n) 'tool)
                                           (equal (ecc-model-node-get n 'name) "Edit")))
                          (hash-table-values (ecc-session-nodes session))))
          (permission (seq-find (lambda (n) (eq (ecc-node-type n) 'permission))
                                (hash-table-values (ecc-session-nodes session)))))
      (should (string-search "return \"hi \" + name" (ecc-model-node-get edit 'before)))
      (should (string-search "return \"hi \" + name"
                             (ecc-model-node-get permission 'before))))))

(ert-deftest ecc-dispatch-test-tasks ()
  "TaskCreate, TaskUpdate and TaskList keep the task list (FR-OUT-13)."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "tasks" "タスクを作って")
    (let ((tasks (ecc-model-tasks session)))
      (should (equal (mapcar #'ecc-task-id tasks) '("1" "2")))
      (should (equal (mapcar #'ecc-task-subject tasks) '("Write tests" "Update docs")))
      (should (equal (mapcar #'ecc-task-status tasks) '("completed" "pending"))))
    ;; No file was touched, so the Files summary is empty.
    (should-not (ecc-model-files session))))

(ert-deftest ecc-dispatch-test-todo-write ()
  "TodoWrite replaces the whole list from its input."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "todo")
    (ecc-dispatch session
                  '((type . "assistant") (uuid . "u1")
                    (message . ((role . "assistant")
                                (content . [((type . "tool_use") (id . "t1") (name . "TodoWrite")
                                             (input . ((todos . [((content . "a") (status . "completed"))
                                                                 ((content . "b") (status . "in_progress"))]))))])))))
    (should (equal (mapcar #'ecc-task-status (ecc-model-tasks session))
                   '("completed" "in_progress")))))

(ert-deftest ecc-dispatch-test-denied-write-is-not-counted ()
  "A Write that was denied is not a write in the Files summary."
  (ecc-test-with-fake-session session
    (let ((answers '(deny allow)))
      (dolist (line (ecc-test-fixture-lines "permission-deny-retry"))
        (let ((message (ecc-protocol-parse-line line)))
          (ecc-dispatch session message)
          (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
            (ecc-perm-respond (car (ecc-session-pending session))
                              (if (eq (pop answers) 'deny) 'deny 'allow)
                              :message "内容を hi にして")))))
    (let ((entry (car (ecc-model-files session))))
      (should (= (ecc-file-entry-writes entry) 1))
      (should (= (length (ecc-file-entry-hunks entry)) 1)))))

(ert-deftest ecc-dispatch-test-commands-changed ()
  "A reloaded command list replaces the old one (FR-INP-3, FR-SES-8).
The CLI sends system/commands_changed after /reload-plugins and
/reload-skills; leaving it unhandled left the completion stale and put
the whole list into an unknown node."
  (ecc-test-with-fake-session session
    (setf (ecc-session-commands session)
          [((name . "old") (description . "gone") (argumentHint . ""))])
    (let ((announced 0))
      (let ((ecc-commands-updated-hook
             (list (lambda (_session) (setq announced (1+ announced))))))
        (ecc-dispatch session
                      '((type . "system") (subtype . "commands_changed")
                        (commands . [((name . "new") (description . "fresh")
                                      (argumentHint . "[x]"))]))))
      (should (= announced 1)))
    (should (equal (alist-get 'name (aref (ecc-session-commands session) 0)) "new"))
    ;; It is understood, so nothing is left over as unknown.
    (should-not (seq-some (lambda (node) (eq (ecc-node-type node) 'unknown))
                          (let (nodes)
                            (maphash (lambda (_id node) (push node nodes))
                                     (ecc-session-nodes session))
                            nodes)))))

(ert-deftest ecc-dispatch-test-running-tool-is-tracked ()
  "The running tool is known without a walk over every node (NFR-1).
It is the tool that started last and has no result yet, and nothing
once every result is in."
  (ecc-test-with-fake-session session
    (let ((seen-running nil))
      (dolist (message (ecc-test-fixture-messages "tool-use-write"))
        (ecc-dispatch session message)
        (let ((running (ecc-model-running-tool session)))
          (when running
            (setq seen-running t)
            (should (eq (ecc-node-status running) 'running))
            (should (memq (ecc-node-type running) '(tool agent))))))
      (should seen-running)
      (should-not (ecc-model-running-tool session))
      (should-not (alist-get 'running-tools (ecc-session-progress session))))))

(ert-deftest ecc-dispatch-test-running-tool-forgets-a-denied-one ()
  "A tool that was denied is not running, even without a result."
  (ecc-test-with-fake-session session
    (let ((node (ecc-dispatch--new-tool session "toolu_x" "Bash"
                                        (ecc-model-ensure-turn session))))
      (should (eq (ecc-model-running-tool session) node))
      (ecc-dispatch session '((type . "system") (subtype . "permission_denied")
                              (tool_use_id . "toolu_x")))
      (should-not (ecc-model-running-tool session)))))

(ert-deftest ecc-dispatch-test-local-command ()
  "A slash command the CLI ran becomes one node, its caveat none (FR-HIST-2)."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "hello")
    (let ((user (lambda (text)
                  (ecc-dispatch session
                                `((type . "user")
                                  (message . ((role . "user") (content . ,text))))))))
      (funcall user (concat "<local-command-caveat>Caveat: ignore this."
                            "</local-command-caveat>"))
      (funcall user (concat "<command-name>/color</command-name>\n"
                            "            <command-args>red</command-args>"))
      (ecc-dispatch session '((type . "system") (subtype . "local_command")
                              (content . "<local-command-stdout>Session color set to: red</local-command-stdout>")))
      (funcall user "<local-command-stdout>and again</local-command-stdout>"))
    (let ((nodes (hash-table-values (ecc-session-nodes session))))
      ;; The caveat is not drawn at all, so it is not a node.
      (should (= 1 (length nodes)))
      (let ((node (car nodes)))
        (should (eq (ecc-node-type node) 'command))
        (should (equal (ecc-model-node-get node 'name) "/color"))
        (should (equal (ecc-model-node-get node 'args) "red"))
        ;; Both ways of recording what a command printed land on it.
        (should (equal (ecc-model-node-get node 'output)
                       "Session color set to: red\nand again"))))))

(ert-deftest ecc-dispatch-test-command-output-without-a-command ()
  "Output whose command is not in this page is kept rather than dropped."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "hello")
    (ecc-dispatch session '((type . "system") (subtype . "local_command")
                            (content . "<local-command-stdout>Bye!</local-command-stdout>")))
    (let ((node (car (hash-table-values (ecc-session-nodes session)))))
      (should (eq (ecc-node-type node) 'system))
      (should (equal (ecc-model-node-get node 'kind) 'command-output))
      (should (equal (ecc-model-node-get node 'text) "Bye!")))))

(provide 'ecc-dispatch-test)

;;; ecc-dispatch-test.el ends here
