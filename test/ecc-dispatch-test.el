;;; ecc-dispatch-test.el --- Replay tests for ecc-dispatch  -*- lexical-binding: t; -*-

;;; Commentary:

;; The recorded fixtures are fed to a session that has no process, and
;; the shape of the resulting model is compared against what it should
;; be.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-model)
(require 'ecc-dispatch)
(require 'ecc-perm)
(require 'ecc-render)

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
    ;; The initialize response carries the slash commands.
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
        ;; tool_use and tool_result found each other by id.
        (should (eq tool (ecc-model-node
                          session "toolu_01Hcu5xtMTxBqGiZ6MfT3XyZ")))))
    ;; The file Claude wrote was recorded.
    (should (= 1 (hash-table-count (ecc-session-files session))))
    (let ((entry (car (hash-table-values (ecc-session-files session)))))
      (should (= (ecc-file-entry-writes entry) 1)))))

(ert-deftest ecc-dispatch-test-permission-request ()
  "A can_use_tool request queues up and waits for an answer."
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

(defun ecc-dispatch-test--can-use-tool (tool input)
  "Return a can_use_tool control_request for TOOL with INPUT."
  `((type . "control_request")
    (request_id . "req-refuse")
    (request . ((subtype . "can_use_tool")
                (tool_name . ,tool)
                (display_name . ,tool)
                (input . ,input)
                (tool_use_id . "toolu_refuse")))))

(ert-deftest ecc-dispatch-test-a-request-can-be-refused ()
  "A refusing function answers the request before anybody is asked."
  (ecc-test-with-fake-session session
    (let ((ecc-request-refuse-functions
           (list (lambda (_session request)
                   (when (equal (ecc-request-tool-name request) "Write")
                     "Emacs answers this one")))))
      (ecc-dispatch session (ecc-dispatch-test--can-use-tool
                             "Write" '((file_path . "/tmp/a.txt"))))
      ;; The deny went out, carrying the whole reason: a refusal the
      ;; model cannot read is one it tries again.
      (let ((response (alist-get 'response
                                 (alist-get 'response
                                            (car (ecc-test-sent-messages))))))
        (should (equal (alist-get 'behavior response) "deny"))
        (should (equal (alist-get 'message response) "Emacs answers this one")))
      ;; And nobody was asked: nothing pending, no node of its own, and
      ;; the session is not waiting on a permission.
      (should-not (ecc-session-pending session))
      (should-not (eq (ecc-session-state session) 'waiting-permission))
      (should (seq-find (lambda (node)
                          (eq (ecc-model-node-get node 'kind) 'refused))
                        (hash-table-values (ecc-session-nodes session))))
      ;; A tool the function says nothing about is asked about as before.
      (ecc-dispatch session (ecc-dispatch-test--can-use-tool
                             "Bash" '((command . "ls"))))
      (should (= 1 (length (ecc-session-pending session)))))))

(ert-deftest ecc-dispatch-test-file-changed-hook ()
  "A successful write tells the rest of Emacs to reload the file."
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
  "AskUserQuestion is a question, not a permission."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "質問して")
    (dolist (line (ecc-test-fixture-lines "ask-user-question"))
      (let ((message (ecc-protocol-parse-line line)))
        (ecc-dispatch session message)
        (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
          (let ((request (car (ecc-session-pending session))))
            (should (eq (ecc-request-kind request) 'question))
            (should (eq (ecc-session-state session) 'waiting-question))
            ;; Answer in the question buffer.
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
      ;; Every question is answered in one object keyed by its text, and
      ;; a multiSelect answer is one comma separated string.
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
    ;; boundary says is left of the conversation; the recording of this
    ;; fixture compacted 17496 tokens down to 1339.
    (should (= (ecc-session-context-tokens session) 1339))))

(ert-deftest ecc-dispatch-test-replay-echo-adds-nothing ()
  "The echo of a prompt is an acknowledgement, not a message (D5).
The recording was made by a client that sent both prompts itself, so
both echoes are its own; the session under test is told as much, the
way `ecc-proc-send-user\=' would have."
  (ecc-test-with-fake-session session
    (setf (ecc-session-sent-echoes session)
          (list "Reply with exactly: ONE" "Reply with exactly: TWO"))
    (ecc-test-dispatch session "replay-user-messages" "Reply with exactly: ONE")
    (should-not (ecc-session-sent-echoes session))
    (dolist (turn (ecc-session-turns session))
      (should-not (ecc-turn-label turn)))
    (dolist (turn (ecc-session-turns session))
      (dolist (node (ecc-turn-children turn))
        (should-not (and (eq (ecc-node-type node) 'system)
                         (equal (ecc-model-node-get node 'kind) 'note)))))
    (should (equal (alist-get 'replayed (ecc-session-progress session))
                   "Reply with exactly: TWO"))))

(ert-deftest ecc-dispatch-test-subagent-nesting ()
  "Messages of a subagent hang under the tool that started it."
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
      ;; An agent is not a TODO item.
      (should (= (hash-table-count (ecc-session-tasks session)) 0)))))

(ert-deftest ecc-dispatch-test-backgrounded-bash-stays-a-tool ()
  "A backgrounded shell command is a task, but not an agent.
Recorded from claude 2.1.265 on 2026-09-10: the CLI registers such a
command as a task of its own, `local_bash\=', and the heading of a Bash
drawn as an agent loses its command."
  (ecc-test-with-fake-session session
    (ecc-test-dispatch session "background-bash" "run it in the background")
    (let ((nodes (hash-table-values (ecc-session-nodes session))))
      (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'agent)) nodes))
      (let ((bash (seq-find (lambda (node)
                              (equal (ecc-model-node-get node 'name) "Bash"))
                            nodes)))
        (should bash)
        (should (eq (ecc-node-type bash) 'tool))
        ;; The task itself is kept, so the heading can still say how it goes.
        (let ((task (ecc-model-node-get bash 'task)))
          (should task)
          (should (equal (alist-get 'task_type task) "local_bash"))
          (should-not (alist-get 'subagent_type task))
          (should-not (ecc-dispatch--agent-task-p task)))
        ;; Its command is what the heading reads, not a tool count.
        (should (equal (ecc-render-tool-summary
                        "Bash" (ecc-model-node-get bash 'input))
                       "sleep 8; echo finished"))))))

(ert-deftest ecc-dispatch-test-only-an-agent-tool-becomes-an-agent ()
  "A plain tool named as a parent stays a tool."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "動かして")
    (let ((bash (ecc-model-add-node session :id "toolu_bash" :type 'tool
                                    :data '((name . "Bash")
                                            (input . ((command . "ls"))))))
          (task (ecc-model-add-node session :id "toolu_task" :type 'tool
                                    :data '((name . "Agent")
                                            (input . ((description . "look")))))))
      ;; A message that names the Bash as its parent hangs under it, but
      ;; does not turn it into an agent.
      (should (eq bash (ecc-dispatch--parent
                        session '((parent_tool_use_id . "toolu_bash")) nil)))
      (should (eq (ecc-node-type bash) 'tool))
      ;; The tool that does start a subagent is promoted, as before.
      (should (eq task (ecc-dispatch--parent
                        session '((parent_tool_use_id . "toolu_task")) nil)))
      (should (eq (ecc-node-type task) 'agent))
      ;; A backgrounded shell command is a task too, and stays a tool:
      ;; the CLI calls it `local_bash\=' (confirmed 2026-09-10).
      (ecc-model-node-put bash 'task '((tool_use_id . "toolu_bash")
                                       (task_type . "local_bash")))
      (should (eq (ecc-node-type (ecc-dispatch--parent
                                  session '((parent_tool_use_id . "toolu_bash")) nil))
                  'tool))
      ;; A task that does start a subagent promotes the tool it names.
      (let ((spawn (ecc-model-add-node session :id "toolu_spawn" :type 'tool
                                       :data '((name . "Bash")))))
        (ecc-model-node-put spawn 'task '((tool_use_id . "toolu_spawn")
                                          (task_type . "local_agent")))
        (should (eq (ecc-node-type (ecc-dispatch--parent
                                    session '((parent_tool_use_id . "toolu_spawn")) nil))
                    'agent))))))

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
  "Nothing in any recording falls through the dispatch table."
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
  ;; A subtype that is not in the list is a note, not an error: the CLI
  ;; adds one whenever it grows a feature (2026-09-09).
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "system") (subtype . "away_summary")))
    (let ((nodes (hash-table-values (ecc-session-nodes session))))
      (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                            nodes))
      (should (seq-find (lambda (node)
                          (and (eq (ecc-node-type node) 'system)
                               (eq (ecc-model-node-get node 'kind) 'notice)))
                        nodes))
      ;; It arrived between turns and must not have opened one (76e61b1).
      (should-not (ecc-session-current-turn session)))))

(ert-deftest ecc-dispatch-test-task-summary ()
  "The line the CLI keeps about the turn goes to the state line, not the
transcript, and a null detail clears it (2026-09-09)."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "system") (subtype . "task_summary")
                            (detail . "reading ecc-dispatch.el")))
    (should (equal "reading ecc-dispatch.el"
                   (alist-get 'task-summary (ecc-session-progress session))))
    (should (= 0 (hash-table-count (ecc-session-nodes session))))
    (should-not (ecc-session-current-turn session))
    (ecc-dispatch session '((type . "system") (subtype . "task_summary")
                            (detail . :null)))
    (should-not (alist-get 'task-summary (ecc-session-progress session)))))

(ert-deftest ecc-dispatch-test-hook-progress-is-quiet ()
  "The output a running hook reports every second draws nothing: the hook
already has a note of its own from hook_started."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "system") (subtype . "hook_progress")
                            (hook_id . "h1") (hook_name . "SessionStart")
                            (stdout . "working…")))
    (should (= 0 (hash-table-count (ecc-session-nodes session))))))

(ert-deftest ecc-dispatch-test-bridge-state ()
  "Remote Control reports itself as system/bridge_state, not as the unknown.
Two of them arrive, `ready' and then `connected', and only the second
carries the epoch of the bridge (confirmed 2026-09-08)."
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

(ert-deftest ecc-dispatch-test-a-remote-turn-queues-and-drains ()
  "A prompt typed while a remote turn runs waits for it and then goes.
Emacs did not open that turn, so nothing local knows it is there; the
prompt must not be lost, and it must not wait for ever."
  (ecc-test-with-fake-session session
    (ecc-model-set-remote-control session 'enabled t 'state "connected")
    (ecc-dispatch session '((type . "assistant")
                            (message . ((role . "assistant")
                                        (model . "claude-opus-5")
                                        (content . [((type . "text")
                                                     (text . "はい"))])))))
    (should (eq (ecc-session-state session) 'running))
    (should (equal 1 (ecc-proc-send-prompt session "ecc から送る")))
    ;; It is in the queue, not on the wire.
    (should (equal '("ecc から送る") (ecc-session-input-queue session)))
    (should-not (seq-find (lambda (message) (equal (alist-get 'type message) "user"))
                          (ecc-test-sent-messages)))
    ;; The result of the remote turn closes it and lets the queue go.
    (ecc-dispatch session '((type . "result") (subtype . "success")
                            (is_error . :false)))
    (should (eq (ecc-session-state session) 'running))
    (should-not (ecc-session-input-queue session))
    (should (equal "ecc から送る" (ecc-test-sent-text 0)))))

(ert-deftest ecc-dispatch-test-replay-echo-of-our-own-prompt ()
  "The echo of a prompt sent from here is an acknowledgement, not news.
With --replay-user-messages every user message comes back; ours must
not draw a second time (measured 2026-09-08)."
  (ecc-test-with-fake-session session
    (ecc-proc-send-user session "hello")
    (should (= 1 (length (ecc-session-turns session))))
    (ecc-dispatch session '((type . "user")
                            (message . ((role . "user") (content . "hello")))
                            (isReplay . t)))
    (should (= 1 (length (ecc-session-turns session))))
    (should-not (ecc-turn-label (car (ecc-session-turns session))))
    (should-not (ecc-session-sent-echoes session))
    ;; The same text sent twice is recognised twice, and no more.
    (ecc-dispatch session '((type . "user")
                            (message . ((role . "user") (content . "hello")))
                            (isReplay . t)))
    (should (equal "(remote)"
                   (ecc-turn-label (car (last (ecc-session-turns session))))))))

(ert-deftest ecc-dispatch-test-replay-shows-a-prompt-from-elsewhere ()
  "A prompt nobody typed here is drawn as the prompt of its turn.
Sent from a phone over Remote Control, it reaches the CLI without
passing through Emacs; the echo is the only way it can be shown."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "user")
                            (message . ((role . "user")
                                        (content . "スマホからの投稿です")))
                            (isReplay . t)
                            (origin . ((kind . "human")))))
    (let ((turn (car (ecc-session-turns session))))
      (should (equal "スマホからの投稿です" (ecc-turn-prompt turn)))
      (should (equal "(remote)" (ecc-turn-label turn))))
    ;; The answer that follows joins that turn rather than opening one.
    (ecc-dispatch session '((type . "assistant")
                            (message . ((role . "assistant")
                                        (model . "claude-opus-5")
                                        (content . [((type . "text")
                                                     (text . "はい"))])))))
    (should (= 1 (length (ecc-session-turns session))))))

(ert-deftest ecc-dispatch-test-replay-leaves-the-cli-own-notes-alone ()
  "What the CLI writes into the conversation itself is not a prompt."
  (ecc-test-with-fake-session session
    (dolist (message '(((type . "user")
                        (message . ((role . "user")
                                    (content . "<system-reminder>x</system-reminder>")))
                        (isReplay . t) (isSynthetic . t))
                       ((type . "user")
                        (message . ((role . "user") (content . "   ")))
                        (isReplay . t))
                       ((type . "user")
                        (message . ((role . "user")
                                    (content . "<command-name>/model</command-name>")))
                        (isReplay . t))))
      (ecc-dispatch session message))
    (should-not (ecc-session-turns session))))

(ert-deftest ecc-dispatch-test-a-message-after-the-result-starts-no-turn ()
  "Anything arriving between turns leaves the session idle and sending.
This is the failure of 2026-09-08: `post_turn_summary' came after the
result of a turn started from a phone, drew as an unknown node, and
that node opened a turn nothing would ever close.  The session read
`running' from then on and every prompt typed here queued behind a turn
that had already ended."
  (dolist (message '(((type . "system") (subtype . "post_turn_summary")
                      (status_category . "completed"))
                     ((type . "system") (subtype . "away_summary"))
                     ((type . "no_such_type_at_all"))
                     ((type . "system") (subtype . "hook_started")
                      (hook_name . "SessionStart"))))
    (ecc-test-with-fake-session session
      ;; A turn from elsewhere ran and ended.
      (ecc-model-set-remote-control session 'enabled t 'state "connected")
      (ecc-dispatch session '((type . "user")
                              (message . ((role . "user") (content . "スマホから")))
                              (isReplay . t)))
      (ecc-dispatch session '((type . "result") (subtype . "success")
                              (is_error . :false)))
      (should (eq (ecc-session-state session) 'idle))
      ;; And then this arrives.
      (ecc-dispatch session message)
      (should (equal (cons message 'idle)
                     (cons message (ecc-session-state session))))
      (should-not (ecc-session-current-turn session))
      ;; So the next prompt goes out instead of queueing for ever.
      (should (eq 'sent (ecc-proc-send-prompt session "ecc から送る"))))))

(ert-deftest ecc-dispatch-test-a-permission-answered-elsewhere-is-withdrawn ()
  "A permission the phone answered stops asking here (measured 2026-09-08).
With Remote Control on, a can_use_tool reaches Emacs and the phone at
once; whoever answers first ends it, and the CLI withdraws the other
side with control_cancel_request.  Unhandled, the transcript went on
showing a request nobody could answer and the session stayed in
`waiting-permission' until the turn ended."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "書いて")
    (let* ((request (ecc-test-add-request session "Write"))
           (node (ecc-request-node request)))
      (should (eq (ecc-session-state session) 'waiting-permission))
      (ecc-dispatch session `((type . "control_cancel_request")
                              (request_id . ,(ecc-request-request-id request))
                              (session_id . "s1")))
      (should-not (ecc-session-pending session))
      (should (eq (ecc-node-status node) 'done))
      (should (equal "answered elsewhere"
                     (ecc-model-node-get node 'outcome-message)))
      ;; The turn is still running; nothing was sent back.
      (should (eq (ecc-session-state session) 'running))
      (should-not (ecc-test-sent-messages)))
    ;; One for a request that is not here is not an unknown message.
    (ecc-dispatch session '((type . "control_cancel_request")
                            (request_id . "gone")))
    (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                          (hash-table-values (ecc-session-nodes session))))))

(ert-deftest ecc-dispatch-test-keep-alive-is-quiet ()
  "A keep_alive says nothing and must draw nothing."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "keep_alive")))
    (should-not (ecc-session-turns session))
    (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                          (hash-table-values (ecc-session-nodes session))))))

(ert-deftest ecc-dispatch-test-post-turn-summary-is-not-unknown ()
  "The summary the CLI writes as a turn ends is known, and quiet."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "system") (subtype . "post_turn_summary")
                            (summarizes_uuid . "ed94573f")
                            (status_category . "completed")
                            (status_detail . "user request acknowledged")
                            (needs_action . "")))
    (let ((summary (alist-get 'turn-summary (ecc-session-progress session))))
      (should (equal (alist-get 'category summary) "completed"))
      (should (equal (alist-get 'detail summary) "user request acknowledged"))
      ;; An empty needs_action means none, not the empty string.
      (should-not (alist-get 'needs-action summary)))
    (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                          (hash-table-values (ecc-session-nodes session))))
    ;; It arrives as a turn ends, and must not open one of its own.
    (should-not (ecc-session-turns session))))

(ert-deftest ecc-dispatch-test-command-lifecycle-is-not-unknown ()
  "The lifecycle of a prompt is known, and quiet.
It says a prompt was queued or started, naming the uuid of the user
message; the answer that follows is what the transcript shows, so this
only reaches the progress information and the log."
  (ecc-test-with-fake-session session
    (ecc-dispatch session '((type . "command_lifecycle")
                            (command_uuid . "4a2abdf3") (state . "queued")))
    (should (equal '("4a2abdf3" . "queued")
                   (alist-get 'command-lifecycle (ecc-session-progress session))))
    (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                          (hash-table-values (ecc-session-nodes session))))
    (should-not (ecc-session-turns session))))

(ert-deftest ecc-dispatch-test-tool-progress-times-a-running-call ()
  "The heartbeat of a running tool is known, and times the call.
It carries a `tool_use_id\=' of its own -- the id of the call with a
`-heartbeat-N\=' suffix -- so the call it reports on is the parent."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "run something slow")
    (ecc-dispatch session
                  '((type . "assistant") (uuid . "u1")
                    (message . ((role . "assistant")
                                (content . [((type . "tool_use") (id . "t1")
                                             (name . "Bash")
                                             (input . ((command . "sleep 90"))))])))))
    (ecc-dispatch session '((type . "tool_progress")
                            (tool_use_id . "t1-heartbeat-0")
                            (tool_name . "Bash")
                            (parent_tool_use_id . "t1")
                            (elapsed_time_seconds . 30)
                            (heartbeat . t)))
    (should (equal 30 (ecc-model-node-get (ecc-model-node session "t1") 'elapsed)))
    (should-not (seq-find (lambda (node) (eq (ecc-node-type node) 'unknown))
                          (hash-table-values (ecc-session-nodes session))))))

(ert-deftest ecc-dispatch-test-tool-progress-after-the-result-is-ignored ()
  "A heartbeat behind the result leaves the finished call alone.
What the heading says then is what the call cost, not how long it had
been waiting."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "run something slow")
    (ecc-dispatch session
                  '((type . "assistant") (uuid . "u1")
                    (message . ((role . "assistant")
                                (content . [((type . "tool_use") (id . "t1")
                                             (name . "Bash")
                                             (input . ((command . "sleep 90"))))])))))
    (ecc-dispatch session '((type . "tool_progress")
                            (parent_tool_use_id . "t1")
                            (elapsed_time_seconds . 30)))
    (ecc-dispatch session
                  '((type . "user") (uuid . "u2")
                    (message . ((role . "user")
                                (content . [((type . "tool_result") (tool_use_id . "t1")
                                             (content . "done"))])))))
    (ecc-dispatch session '((type . "tool_progress")
                            (parent_tool_use_id . "t1")
                            (elapsed_time_seconds . 60)))
    (should (equal 30 (ecc-model-node-get (ecc-model-node session "t1") 'elapsed)))))

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

;;;; Robustness

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

;;;; Automatic approval

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

;;;; The input queue drains when the turn ends

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


;;;; Streaming

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
      ;; 29 input deltas of which one is empty, and 17 text deltas.
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

;;;; Images

(defmacro ecc-dispatch-test--with-images (session &rest body)
  "Run BODY with SESSION writing its images somewhere of its own."
  (declare (indent 1))
  `(let ((ecc-image-dir (make-temp-file "ecc-images" t)))
     (unwind-protect (progn ,@body)
       (setf (ecc-session-tmp-dir ,session) nil)
       (when (file-directory-p ecc-image-dir)
         (delete-directory ecc-image-dir t)))))

(defun ecc-dispatch-test--image-block ()
  "Return an image content block carrying the image fixture."
  `((type . "image")
    (source . ((type . "base64") (media_type . "image/png")
               (data . ,(base64-encode-string (ecc-test-image-bytes) t))))))

(defun ecc-dispatch-test--no-base64 (node)
  "Fail unless the data of NODE carries none of the image fixture."
  (should-not (string-search (base64-encode-string (ecc-test-image-bytes) t)
                             (format "%S" (ecc-node-data node)))))

(ert-deftest ecc-dispatch-test-assistant-image-becomes-a-file ()
  "An image block on an assistant message is one node naming a file."
  (ecc-test-with-fake-session session
    (ecc-dispatch-test--with-images session
      (ecc-model-begin-turn session "見せて")
      (ecc-dispatch session
                    `((type . "assistant") (uuid . "u1")
                      (message . ((content . [,(ecc-dispatch-test--image-block)])))))
      (let* ((children (ecc-turn-children (ecc-session-current-turn session)))
             (node (car children)))
        (should (= (length children) 1))
        (should (eq (ecc-node-type node) 'image))
        (should (eq (ecc-node-status node) 'done))
        (should (eq (ecc-model-node-get node 'role) 'assistant))
        (should (file-exists-p (ecc-model-node-get node 'path)))
        (should (= (ecc-model-node-get node 'bytes)
                   (length (ecc-test-image-bytes))))
        ;; The whole point: the payload is on disk, not in the model.
        (ecc-dispatch-test--no-base64 node)))))

(ert-deftest ecc-dispatch-test-a-streamed-image-is-one-node ()
  "A streamed image block and the message that closes it are one node."
  (ecc-test-with-fake-session session
    (ecc-dispatch-test--with-images session
      (ecc-model-begin-turn session "見せて")
      (ecc-dispatch session
                    `((type . "stream_event")
                      (event . ((type . "content_block_start") (index . 0)
                                (content_block . ,(ecc-dispatch-test--image-block))))))
      ;; The assistant message arrives before the stop: that is the
      ;; order the CLI sends them in (see partial-messages.jsonl).
      (ecc-dispatch session
                    `((type . "assistant") (uuid . "u1")
                      (message . ((content . [,(ecc-dispatch-test--image-block)])))))
      (ecc-dispatch session
                    '((type . "stream_event")
                      (event . ((type . "content_block_stop") (index . 0)))))
      (let ((children (ecc-turn-children (ecc-session-current-turn session))))
        (should (= (length children) 1))
        (should (eq (ecc-node-type (car children)) 'image))
        (should (eq (ecc-node-status (car children)) 'done))
        (should (= 0 (hash-table-count (ecc-session-stream-blocks session))))))))

(ert-deftest ecc-dispatch-test-a-user-image-is-drawn-not-unknown ()
  "An image block on a user message is an image node, not an unknown one."
  (ecc-test-with-fake-session session
    (ecc-dispatch-test--with-images session
      (ecc-model-begin-turn session "これ")
      (ecc-dispatch session
                    `((type . "user")
                      (message . ((content . [,(ecc-dispatch-test--image-block)])))))
      (let ((node (car (ecc-turn-children (ecc-session-current-turn session)))))
        (should (eq (ecc-node-type node) 'image))
        (should (eq (ecc-model-node-get node 'role) 'user))
        (ecc-dispatch-test--no-base64 node)))))

(ert-deftest ecc-dispatch-test-an-unreachable-image-keeps-its-reason ()
  "A source this side cannot read is a node with a reason and no block."
  (ecc-test-with-fake-session session
    (ecc-dispatch-test--with-images session
      (ecc-model-begin-turn session "これ")
      (ecc-dispatch session
                    '((type . "user")
                      (message . ((content . [((type . "image")
                                               (source . ((type . "file")
                                                          (file_id . "abc")))
                                               )])))))
      (let ((node (car (ecc-turn-children (ecc-session-current-turn session)))))
        (should (eq (ecc-node-type node) 'image))
        (should (equal (ecc-model-node-get node 'reason) "image source: file"))
        (should-not (ecc-model-node-get node 'block))))))

(ert-deftest ecc-dispatch-test-a-result-image-leaves-no-base64 ()
  "An image in a tool result becomes a path beside the text it came with."
  (ecc-test-with-fake-session session
    (ecc-dispatch-test--with-images session
      (ecc-model-begin-turn session "撮って")
      (ecc-dispatch session
                    '((type . "assistant") (uuid . "u1")
                      (message . ((content . [((type . "tool_use") (id . "t1")
                                               (name . "Read")
                                               (input . ((file_path . "/tmp/a.png"))))])))))
      (ecc-dispatch session
                    `((type . "user")
                      (message . ((content . [((type . "tool_result")
                                               (tool_use_id . "t1")
                                               (content . [((type . "text") (text . "here"))
                                                           ,(ecc-dispatch-test--image-block)]))])))))
      (let* ((node (ecc-model-node session "t1"))
             (result (ecc-model-node-get node 'result)))
        (should (vectorp result))
        (should (= (length result) 2))
        (should (equal (alist-get 'text (aref result 0)) "here"))
        (should (equal (alist-get 'type (aref result 1)) "image"))
        (should (file-exists-p (alist-get 'path (aref result 1))))
        (should-not (alist-get 'data (aref result 1)))
        (should-not (alist-get 'source (aref result 1)))
        (ecc-dispatch-test--no-base64 node)))))

;;;; Files and tasks from tool_use_result

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
    ;; the change, from the Read.
    (let ((edit (seq-find (lambda (n) (and (eq (ecc-node-type n) 'tool)
                                           (equal (ecc-model-node-get n 'name) "Edit")))
                          (hash-table-values (ecc-session-nodes session))))
          (permission (seq-find (lambda (n) (eq (ecc-node-type n) 'permission))
                                (hash-table-values (ecc-session-nodes session)))))
      (should (string-search "return \"hi \" + name" (ecc-model-node-get edit 'before)))
      (should (string-search "return \"hi \" + name"
                             (ecc-model-node-get permission 'before))))))

(ert-deftest ecc-dispatch-test-tasks ()
  "TaskCreate, TaskUpdate and TaskList keep the task list."
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
  "A reloaded command list replaces the old one.
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
  "The running tool is known without a walk over every node.
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
  "A slash command the CLI ran becomes one node, its caveat none."
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

(ert-deftest ecc-dispatch-test-task-notification-is-not-a-prompt ()
  "An injected task notice is a folded aside, live stream or not.
It arrives with no turn open, and a turn nothing would ever close
leaves the session busy for good."
  (let ((text (concat "<task-notification>\n  <task-id>bash_7</task-id>\n"
                      "  <status>stopped</status>\n  <summary>Background shell"
                      " command did not finish</summary>\n</task-notification>")))
    (ecc-test-with-fake-session session
      ;; The echo of a message nobody here sent is not a prompt from
      ;; elsewhere when the CLI wrote it itself.
      (ecc-dispatch session `((type . "user") (isReplay . t)
                              (message . ((role . "user") (content . ,text)))))
      (should-not (ecc-session-turns session))
      (should-not (ecc-session-current-turn session))
      ;; Without --replay-user-messages it arrives as a plain user message.
      (ecc-dispatch session `((type . "user")
                              (origin . ((kind . "task-notification")))
                              (message . ((role . "user") (content . ,text)))))
      (let ((nodes (hash-table-values (ecc-session-nodes session))))
        (should (= 1 (length nodes)))
        (should (eq (ecc-node-type (car nodes)) 'system))
        (should (eq 'task-notice (ecc-model-node-get (car nodes) 'kind)))
        (should (equal "Background shell command did not finish"
                       (ecc-model-node-get (car nodes) 'summary))))
      ;; The notice went beside the conversation: no turn was opened for it.
      (should-not (ecc-session-current-turn session))
      (should-not (seq-some #'ecc-turn-prompt (ecc-session-turns session))))))

;;;; What a command wrote

(defun ecc-dispatch-test--tool (session name input result &optional write error-p)
  "Run a whole tool call NAME with INPUT and RESULT in SESSION, return its node.
The node is made first, the way the stream makes it, and WRITE, a thunk
that stands in for what the call did to the disk, runs after it: what
the call wrote is then newer than the `started\=' of the node, as it is
in life.  ERROR-P makes the result an error."
  (ecc-dispatch session `((type . "assistant")
                          (message . ((content . [((type . "tool_use")
                                                   (id . "toolu_written")
                                                   (name . ,name)
                                                   (input . ,input))])))))
  (when write (funcall write))
  (ecc-dispatch session
                `((type . "user")
                  (message . ((content . [((type . "tool_result")
                                           (tool_use_id . "toolu_written")
                                           (is_error . ,(if error-p t :false))
                                           (content . ,result))])))))
  (ecc-model-node session "toolu_written"))

(defmacro ecc-dispatch-test--in-dir (var &rest body)
  "Run BODY with VAR bound to a fresh temporary directory, deleted after."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-written" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-dispatch-test--touch (dir name &optional age)
  "Write a stand-in file NAME in DIR, AGE seconds old, and return its path."
  (let ((path (expand-file-name name dir)))
    (with-temp-file path (insert "not really a video"))
    (when age
      (set-file-times path (time-add (current-time) (- age))))
    path))

(ert-deftest ecc-dispatch-test-a-command-that-wrote-a-video-shows-it ()
  "A Bash call that made an mp4 hands the renderer the file it made."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "record it")
      (let* ((path nil)
             (node (ecc-dispatch-test--tool
                    session "Bash"
                    '((command . "demo/record.sh tab-close"))
                    ;; record.sh names what it made in its own output;
                    ;; the command line names only the scene.
                    "saved demo/tab-close.mp4\n"
                    (lambda ()
                      (make-directory (expand-file-name "demo" dir) t)
                      (setq path (ecc-dispatch-test--touch
                                  dir "demo/tab-close.mp4"))))))
        ;; The path was named relative to the session, not to
        ;; `default-directory', and it is what the renderer draws.
        (should (equal (ecc-model-node-get node 'written-images) (list path)))
        (should (equal (ecc-render--tool-images node)
                       (list (list path nil nil))))))))

(ert-deftest ecc-dispatch-test-a-command-that-only-named-a-video-shows-nothing ()
  "An `ls' names every mp4 in a directory and wrote none of them."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "what is in demo")
      ;; Older than `ecc-dispatch--written-slack' by a wide margin: the
      ;; slack is there for a filesystem's rounding, not for this.
      (ecc-dispatch-test--touch dir "old.mp4" 3600)
      (let ((node (ecc-dispatch-test--tool session "Bash"
                                           '((command . "ls *.mp4"))
                                           "old.mp4\n")))
        (should-not (ecc-model-node-get node 'written-images))
        (should-not (ecc-render--tool-images node))))))

(ert-deftest ecc-dispatch-test-a-command-naming-nothing-on-disk-shows-nothing ()
  "A path that is not there is not drawn."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "record it")
      (let ((node (ecc-dispatch-test--tool session "Bash"
                                           '((command . "make gone.mp4"))
                                           "done\n")))
        (should-not (ecc-model-node-get node 'written-images))))))

(ert-deftest ecc-dispatch-test-an-errored-command-shows-nothing ()
  "A call that failed is credited with nothing, whatever is on disk."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "record it")
      (let ((node (ecc-dispatch-test--tool
                   session "Bash" '((command . "demo/record.sh broken"))
                   "no such scene\n"
                   (lambda () (ecc-dispatch-test--touch dir "broken.mp4"))
                   t)))
        (should-not (ecc-model-node-get node 'written-images))))))

(ert-deftest ecc-dispatch-test-what-a-command-wrote-is-capped ()
  "Only the first few files of a command are kept."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "record them all")
      (let* ((names '("a.png" "b.png" "c.png" "d.png" "e.png" "f.png"))
             (ecc-dispatch-max-written-images 4)
             (node (ecc-dispatch-test--tool
                    session "Bash"
                    `((command . ,(concat "shoot " (string-join names " "))))
                    "shot\n"
                    (lambda ()
                      (dolist (name names)
                        (ecc-dispatch-test--touch dir name))))))
        (should (equal (ecc-model-node-get node 'written-images)
                       (mapcar (lambda (name) (expand-file-name name dir))
                               (seq-take names 4))))))))

(ert-deftest ecc-dispatch-test-a-file-tool-is-unchanged ()
  "A Read of a picture still draws its `file_path' and gains no list."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "look at it")
      (let* ((path (ecc-dispatch-test--touch dir "shot.png"))
             (node (ecc-dispatch-test--tool session "Read"
                                            `((file_path . ,path))
                                            "read it\n")))
        (should-not (ecc-model-node-get node 'written-images))
        (should (equal (ecc-render--tool-images node)
                       (list (list path nil nil))))))))

(ert-deftest ecc-dispatch-test-a-result-image-is-not-doubled ()
  "A command whose result carried an image block draws it once."
  (ecc-dispatch-test--in-dir dir
    (ecc-test-with-fake-session session
      (setf (ecc-session-project-root session) dir)
      (ecc-model-begin-turn session "shoot")
      (ecc-dispatch session '((type . "assistant")
                              (message . ((content . [((type . "tool_use")
                                                       (id . "toolu_written")
                                                       (name . "Bash")
                                                       (input . ((command . "shoot shot.png"))))])))))
      (let* ((node (ecc-model-node session "toolu_written"))
             (path (ecc-dispatch-test--touch dir "shot.png")))
        ;; The image block the CLI sent, as `ecc-dispatch--result-content'
        ;; leaves it: the base64 already written to a file of its own.
        (ecc-model-node-put node 'result
                            (vector `((type . "image") (path . ,path)
                                      (bytes . 12))
                                    `((type . "text") (text . ,(concat "wrote " path)))))
        (ecc-dispatch--note-written-images session node)
        (should-not (ecc-model-node-get node 'written-images))
        (should (equal (ecc-render--tool-images node)
                       (list (list path 12 nil))))))))

(provide 'ecc-dispatch-test)

;;; ecc-dispatch-test.el ends here
