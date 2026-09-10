;;; ecc-dispatch.el --- Turn CLI messages into model changes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-dispatch' is the table the CLI stream is read through: it looks
;; at the type and subtype of a parsed message, updates the model and
;; lets the model announce the change.
;;
;; Nothing is dropped.  A message this file does not know, and any error
;; raised while handling one, ends up as an `unknown' node in the
;; transcript and in the log.
;;
;; Streaming: with --include-partial-messages every content block
;; arrives three times, as a content_block_start, as deltas and as the
;; complete assistant message.  The start creates a provisional node,
;; the deltas grow its streamed text, and the assistant message finds
;; that node again and fills in the final content, so that the tree has
;; one node per block whether or not the stream events came.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-diff)

(defvar ecc-turn-approve-tools '("Edit" "Write" "NotebookEdit")
  "Tools that a turn-wide approval covers.")

(defconst ecc-dispatch-file-tools
  '(("Read" . read) ("Edit" . edit) ("MultiEdit" . edit) ("NotebookEdit" . edit)
    ("Write" . write))
  "Tools that touch a file, and the kind of access they make.")

;;;; Entry point

(defun ecc-dispatch (session message)
  "Apply MESSAGE to SESSION.
Errors are caught: an unreadable message must never stop the stream."
  (condition-case err
      (ecc-dispatch--message session message)
    (error
     (ecc-log (ecc-session-name session) "dispatch error: %s on %S"
              (error-message-string err) message)
     (ecc-dispatch--unknown session message (error-message-string err)))))

(setq ecc-proc-message-function #'ecc-dispatch)

(defun ecc-dispatch--message (session message)
  "Apply MESSAGE to SESSION without catching errors."
  (pcase (ecc-protocol-type message)
    ('system (ecc-dispatch--system session message))
    ('assistant (ecc-dispatch--assistant session message))
    ('user (ecc-dispatch--user session message))
    ('control_request (ecc-dispatch--control-request session message))
    ('control_response (ecc-dispatch--control-response session message))
    ('control_cancel_request (ecc-dispatch--control-cancel session message))
    ;; The CLI keeps a quiet stream alive; there is nothing to show.
    ('keep_alive nil)
    ('result (ecc-dispatch--result session message))
    ('stream_event (ecc-dispatch--stream-event session message))
    ('rate_limit_event
     (setf (ecc-session-rate-limit session) (alist-get 'rate_limit_info message))
     (run-hook-with-args 'ecc-usage-hook session))
    ('command_lifecycle (ecc-dispatch--command-lifecycle session message))
    ('tool_progress (ecc-dispatch--tool-progress session message))
    ('prompt_suggestion
     (setf (alist-get 'suggestion (ecc-session-hint-state session))
           (alist-get 'prompt_suggestion message))
     (run-hook-with-args 'ecc-progress-hook session))
    (_ (ecc-dispatch--unknown session message nil))))

(defun ecc-dispatch--unknown (session message reason)
  "Keep MESSAGE of SESSION as an unknown node, noting REASON.
It goes beside the conversation rather than into a turn of its own: a
message this version does not understand can arrive between turns --
`post_turn_summary' did, and opened a turn that nothing would ever
close, which left the session running for good and every later prompt
queued behind it (2026-09-08).  Nothing is dropped either way
."
  (ecc-model-add-aside session
                       :type 'unknown
                       :status 'done
                       :data (list (cons 'message message)
                                   (cons 'reason reason))))

(defun ecc-dispatch--progress (session key value)
  "Set KEY of the progress information of SESSION to VALUE and announce it."
  (setf (alist-get key (ecc-session-progress session)) value)
  (run-hook-with-args 'ecc-progress-hook session))

(defun ecc-dispatch--tool-progress (session message)
  "Note in SESSION how long the call MESSAGE reports on has been running.
The CLI sends this every thirty seconds while a tool is still working,
under a `tool_use_id\=' of its own -- the id of the call with a
`-heartbeat-N\=' suffix -- so the call itself is the parent \(confirmed
2026-09-10).  A heartbeat that arrives after the result is ignored: the
heading then says what the call cost, not how long it had been waiting."
  (when-let* ((id (or (alist-get 'parent_tool_use_id message)
                      (alist-get 'tool_use_id message)))
              (node (ecc-model-node session id))
              (seconds (alist-get 'elapsed_time_seconds message))
              ((eq (ecc-node-status node) 'running)))
    (ecc-model-node-put node 'elapsed seconds)
    (ecc-model-node-changed session node)))

;;;; system

(defconst ecc-dispatch-system-subtypes
  '("init" "status" "thinking_tokens" "hook_started" "hook_response"
    "hook_progress" "permission_denied" "compact_boundary" "task_started"
    "task_progress" "task_updated" "task_notification" "task_summary"
    "background_tasks_changed" "commands_changed" "session_state_changed"
    "local_command" "bridge_state" "post_turn_summary")
  "The system subtypes `ecc-dispatch--system' handles.
Kept next to the function it lists, and checked against it by a test.
`ecc-history' asks this before handing a recorded line over: a
recording holds subtypes the stream never sends, and those belong in a
note rather than among the messages this version does not understand.")

(defun ecc-dispatch--system (session message)
  "Apply the system MESSAGE to SESSION."
  (pcase (ecc-protocol-subtype message)
    ('init (ecc-dispatch--init session message))
    ('status (ecc-dispatch--status session message))
    ('thinking_tokens
     (ecc-dispatch--progress session 'thinking-tokens
                             (alist-get 'estimated_tokens message)))
    ('control_request_progress
     ;; Progress on a control request Emacs sent, not on the turn: the
     ;; side question reports "started" and then every API retry.  It
     ;; belongs to whoever sent the request, and putting it in the
     ;; transcript would be noise the CLI never meant for it.
     (run-hook-with-args 'ecc-control-progress-hook session
                         (alist-get 'request_id message) message))
    ((or 'hook_started 'hook_response)
     ;; A SessionStart hook runs before any turn does.
     (ecc-model-add-aside session :type 'system :status 'done
                          :data (list (cons 'kind 'hook)
                                      (cons 'message message))))
    ;; A hook that runs for a while reports its output once a second.
    ;; The hook itself already has a note of its own from hook_started.
    ('hook_progress nil)
    ('local_command
     (ecc-dispatch-command-output session (alist-get 'content message)))
    ('bridge_state (ecc-dispatch--bridge-state session message))
    ('post_turn_summary (ecc-dispatch--post-turn-summary session message))
    ('task_summary (ecc-dispatch--task-summary session message))
    ;; What the CLI thinks the session is doing.  Only sent when
    ;; CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS is set, and ecc keeps the
    ;; state of a session itself.
    ('session_state_changed nil)
    ('permission_denied
     (when-let* ((node (ecc-model-node session (alist-get 'tool_use_id message))))
       (setf (ecc-node-status node) 'denied)
       (ecc-model-note-tool-finished session node)
       (ecc-model-node-changed session node)))
    ;; /reload-plugins, /reload-skills and a plugin installed while the
    ;; session runs send the whole list again.
    ('commands_changed
     (setf (ecc-session-commands session) (alist-get 'commands message))
     (run-hook-with-args 'ecc-commands-updated-hook session))
    ('compact_boundary (ecc-dispatch--compacted session message nil))
    ((or 'task_started 'task_progress 'task_updated 'task_notification
         'background_tasks_changed)
     (ecc-dispatch--task session message))
    (_ (ecc-dispatch--system-note session message))))

(defun ecc-dispatch--system-note (session message)
  "Keep the system MESSAGE of SESSION as a folded note.
The CLI grows a system subtype whenever it grows a feature -- twenty of
them can reach the stream of 2.1.265, and the list only gets longer --
so one this version has no use for is bookkeeping rather than a fault,
and it is not drawn in the colour of an error.  The raw message is kept
under the note and in the log, so nothing is dropped."
  (ecc-log (ecc-session-name session) "system/%s is not handled"
           (or (alist-get 'subtype message) "?"))
  (ecc-model-add-aside session :type 'system :status 'done
                       :data (list (cons 'kind 'notice)
                                   (cons 'message message))))

(defun ecc-dispatch--task-summary (session message)
  "Apply the system/task_summary MESSAGE to SESSION.
The CLI keeps a line of its own saying what the turn is doing, and
sends it again every time it changes; `detail\=' is null when the turn
ends and the line is cleared.  It says the same thing the state line
does, so it goes there rather than into the transcript (2026-09-09)."
  (let ((detail (alist-get 'detail message)))
    (ecc-dispatch--progress session 'task-summary (and (stringp detail) detail))))

(defun ecc-dispatch--bridge-state (session message)
  "Apply the system/bridge_state MESSAGE to SESSION.
Remote Control reports itself this way: `ready\=' once the bridge is up
and `connected\=' when somebody is on the other end, the latter with
the epoch of the bridge (confirmed 2026-09-08).  A `detail\='
comes with a state that needs explaining."
  (let ((state (alist-get 'state message))
        (detail (alist-get 'detail message)))
    (ecc-model-set-remote-control session
                                  'enabled t
                                  'state state
                                  'detail detail)
    (when-let* ((epoch (alist-get 'bridge_epoch message)))
      (ecc-model-set-remote-control session 'bridge-epoch epoch))
    (ecc-model-add-aside session :type 'system :status 'done
                         :data (list (cons 'kind 'remote-control)
                                     (cons 'text (format "remote control %s%s"
                                                         (or state "?")
                                                         (if detail
                                                             (format " — %s" detail)
                                                           "")))))
    (run-hook-with-args 'ecc-remote-control-functions session)
    (run-hook-with-args 'ecc-progress-hook session)))

(defun ecc-dispatch--post-turn-summary (session message)
  "Apply the system/post_turn_summary MESSAGE to SESSION.
The CLI sums a turn up as it ends: which message it summarizes, a
`status_category\=' such as \"completed\", a `status_detail\=' in
words, and `needs_action\=' -- empty when it does not.  The transcript
already holds the turn it describes, so this is kept where the state
line and the dashboard can reach it rather than drawn (measured
2026-09-08)."
  (let ((detail (alist-get 'status_detail message))
        (needs-action (alist-get 'needs_action message)))
    (setf (alist-get 'turn-summary (ecc-session-progress session))
          (list (cons 'category (alist-get 'status_category message))
                (cons 'detail detail)
                (cons 'needs-action (and (stringp needs-action)
                                         (not (string-empty-p needs-action))
                                         needs-action))
                (cons 'summarizes (alist-get 'summarizes_uuid message))))
    (ecc-log (ecc-session-name session) "turn summary: %s%s"
             (or detail (alist-get 'status_category message) "?")
             (if (and (stringp needs-action) (not (string-empty-p needs-action)))
                 (format " (needs action: %s)" needs-action) ""))
    (run-hook-with-args 'ecc-progress-hook session)))

(defun ecc-dispatch--init (session message)
  "Apply the system/init MESSAGE to SESSION.
Init arrives once per turn, not once per session, so this only
updates what it is told and never rebuilds the session."
  (setf (ecc-session-init session) message)
  (when-let* ((id (alist-get 'session_id message)))
    (ecc-model-set-session-id session id))
  (when-let* ((cwd (alist-get 'cwd message)))
    (setf (ecc-session-cwd session) cwd))
  (when-let* ((mode (alist-get 'permissionMode message)))
    (setf (ecc-session-permission-mode session) mode))
  ;; A session that never got its process up is still `starting'; init
  ;; proves the CLI is there.
  (when (eq (ecc-session-state session) 'starting)
    (ecc-model-set-state session 'idle))
  (run-hook-with-args 'ecc-session-init-hook session))

(defun ecc-dispatch--status (session message)
  "Apply the system/status MESSAGE to SESSION."
  (when-let* ((mode (alist-get 'permissionMode message)))
    (setf (ecc-session-permission-mode session) mode))
  (let ((status (alist-get 'status message)))
    (setf (alist-get 'status (ecc-session-progress session)) status)
    (when (equal status "compacting")
      (ecc-model-set-state session 'compacting)))
  ;; The key is present with a null value on the closing message, so ask
  ;; for the cell rather than the value.
  (when (assq 'compact_result message)
    (ecc-dispatch--compacted session message (alist-get 'compact_result message)))
  (run-hook-with-args 'ecc-status-hook session)
  (run-hook-with-args 'ecc-progress-hook session))

(defun ecc-dispatch--compacted (session message result)
  "Note in SESSION that MESSAGE reports a compaction with RESULT.
RESULT is nil on the compact_boundary that opens the compacted
conversation, and the outcome the CLI reported on the status message
that closes the compaction itself."
  (let ((metadata (alist-get 'compact_metadata message)))
    ;; A compaction happens between turns as often as during one.
    (ecc-model-add-aside session :type 'system :status 'done
                         :data (list (cons 'kind 'compact)
                                     (cons 'result result)
                                     (cons 'error (alist-get 'compact_error message))
                                     (cons 'metadata metadata)
                                     (cons 'message message)))
    ;; The context left starts again from what is in the window now.
    ;; Only the boundary knows how much that is; a successful status
    ;; message is followed by one, so its guess of zero is corrected
    ;; within the same exchange.  A failed compaction changed nothing
    ;; and must not move the estimate.
    (let ((post (alist-get 'post_tokens metadata)))
      (when (or post (null result) (equal result "success"))
        (setf (ecc-session-context-tokens session) (or post 0))
        (run-hook-with-args 'ecc-usage-hook session))))
  (when (eq (ecc-session-state session) 'compacting)
    (ecc-model-set-state session
                         (if (ecc-session-current-turn session) 'running 'idle)))
  (run-hook-with-args 'ecc-compact-hook session))

(defun ecc-dispatch--task (session message)
  "Apply a task lifecycle MESSAGE to SESSION.
The node is looked up in the session rather than in the current turn,
because an asynchronous agent reports after the turn is over (D5).  A
tool that starts a subagent is an agent from then on, even when its
messages never arrive because it runs in the background; a task that is
only a backgrounded shell command stays the tool it is."
  (let* ((node (ecc-model-node session (alist-get 'tool_use_id message)))
         (patch (alist-get 'patch message))
         (status (or (alist-get 'status message) (alist-get 'status patch))))
    (when node
      (when (and (eq (ecc-node-type node) 'tool)
                 (or (ecc-dispatch--agent-task-p message)
                     (member (ecc-model-node-get node 'name)
                             ecc-dispatch-agent-tools)))
        (setf (ecc-node-type node) 'agent))
      (ecc-model-node-put node 'task message)
      (when-let* ((type (alist-get 'subagent_type message)))
        (ecc-model-node-put node 'agent-type type))
      (when-let* ((description (alist-get 'description message)))
        (ecc-model-node-put node 'agent-description description))
      (when-let* ((usage (alist-get 'usage message)))
        (ecc-model-node-put node 'agent-usage usage))
      (when-let* ((summary (alist-get 'summary message)))
        (ecc-model-node-put node 'agent-summary summary))
      (when status (ecc-model-node-put node 'task-status status))
      (ecc-model-node-changed session node))))

;;;; assistant

(defun ecc-dispatch--assistant (session message)
  "Apply the assistant MESSAGE to SESSION, one content block at a time.
A block that was streamed already has a node; it is completed rather
than added again."
  (let* ((turn (ecc-model-ensure-turn session))
         (synthetic (ecc-protocol-synthetic-p message))
         (uuid (or (alist-get 'uuid message) (ecc-model-next-node-id session)))
         (parent-id (alist-get 'parent_tool_use_id message))
         (index -1))
    ;; A synthetic reply reports no tokens, so it must not move the
    ;; context estimate.  An agent talks in a context of its own, so
    ;; neither its tokens nor its model belong to the session.
    (unless (or synthetic parent-id)
      (ecc-model-update-usage session
                              (alist-get 'usage (alist-get 'message message)))
      ;; The recording carries no system/init, so this is the only place
      ;; a session read from history learns which model it talks to.
      (when-let* ((model (alist-get 'model (alist-get 'message message))))
        (setf (ecc-session-last-model session) model)))
    (dolist (block (ecc-protocol-content-blocks message))
      (cl-incf index)
      (let ((id (format "%s:%d" uuid index))
            (parent (ecc-dispatch--parent session message turn)))
        (pcase (alist-get 'type block)
          ("thinking"
           (ecc-dispatch--finish-block
            session parent-id 'thinking id parent
            (list (cons 'text (alist-get 'thinking block)))))
          ("text"
           (ecc-dispatch--finish-block
            session parent-id 'text id parent
            (list (cons 'text (alist-get 'text block))
                  (cons 'synthetic synthetic))))
          ("tool_use" (ecc-dispatch--tool-use session block parent))
          (_ (ecc-model-add-node session :id id :type 'unknown :status 'done
                                 :parent parent
                                 :data (list (cons 'block block)))))))))

(defun ecc-dispatch--finish-block (session parent-id type id parent data)
  "Complete the streamed node of TYPE under PARENT-ID in SESSION.
When nothing was streamed a new node is added instead; ID, PARENT and
DATA describe it.  Returns the node."
  (let ((node (ecc-model-find-stream session parent-id type)))
    (if (null node)
        (ecc-model-add-node session :id id :type type :status 'done
                            :parent parent :data data)
      (setf (ecc-node-data node) data
            (ecc-node-status node) 'done
            (ecc-node-streaming-text node) nil)
      (ecc-model-close-stream session node)
      (ecc-model-node-changed session node)
      node)))

(defconst ecc-dispatch-agent-tools '("Task" "Agent")
  "Names of the tools that start a subagent.")

(defun ecc-dispatch--agent-task-p (task)
  "Return non-nil when the TASK lifecycle message is a subagent.
The CLI registers a backgrounded shell command as a task as well, and
tells the two apart by `task_type\=': `local_agent\=' for a subagent and
`local_bash\=' for a command, the latter carrying no `subagent_type\='
either (confirmed against claude 2.1.265 on 2026-09-10)."
  (or (equal (alist-get 'task_type task) "local_agent")
      (and (alist-get 'subagent_type task) t)))

(defun ecc-dispatch--agent-tool-p (node)
  "Return non-nil when NODE is a tool that starts a subagent.
A `parent_tool_use_id\=' is not enough on its own to call a node an
agent: the CLI names a plain tool there as well, and a Bash drawn as an
agent takes the command out of its heading and puts a tool count and a
duration in its place (2026-09-09)."
  (or (eq (ecc-node-type node) 'agent)
      (member (ecc-model-node-get node 'name) ecc-dispatch-agent-tools)
      (ecc-dispatch--agent-task-p (ecc-model-node-get node 'task))))

(defun ecc-dispatch--parent (session message turn)
  "Return the node MESSAGE belongs under in TURN of SESSION.
A message with a parent_tool_use_id belongs to a subagent, so it goes
under the tool node that started it, and that tool is an agent from
then on.  A node that starts no subagent keeps its type and
only takes the message as a child."
  (let ((parent-id (alist-get 'parent_tool_use_id message)))
    (or (when-let* ((node (and parent-id (ecc-model-node session parent-id))))
          (when (ecc-dispatch--agent-tool-p node)
            (setf (ecc-node-type node) 'agent))
          node)
        turn)))

(defun ecc-dispatch--tool-use (session block parent)
  "Add the tool_use BLOCK to SESSION under PARENT, or complete its node.
The node exists already when the block was streamed."
  (let* ((id (alist-get 'id block))
         (node (or (and id (ecc-model-node session id))
                   (ecc-dispatch--new-tool session id (alist-get 'name block)
                                           parent))))
    (ecc-model-close-stream session node)
    (ecc-dispatch--tool-input session node (alist-get 'input block))
    node))

(defun ecc-dispatch--new-tool (session id name parent)
  "Add a running tool node ID called NAME under PARENT in SESSION."
  (ecc-model-note-tool-running
   session
   (ecc-model-add-node
    session
    :id id
    :type 'tool
    :parent (ecc-model-step-for-tool session parent)
    :status 'running
    :data (list (cons 'name name)
                (cons 'started (current-time))))))

(defun ecc-dispatch--tool-input (session node input)
  "Record INPUT as the final input of the tool NODE of SESSION.
File tools are noted in the Files summary and, for an Edit or a Write,
what the file looks like before the call is kept for the diff."
  (let ((name (ecc-model-node-get node 'name)))
    (ecc-model-node-put node 'input input)
    (setf (ecc-node-streaming-text node) nil)
    (ecc-dispatch--progress session 'running-tool
                            (cons name (alist-get 'file_path input)))
    ;; The Files summary counts a call once its result says it happened
    ;; (a denied Write wrote nothing); the entry itself is made now so
    ;; that the state of the file before the call can be kept on it.
    ;; ExitPlanMode names the file the CLI wrote the plan to.  It is
    ;; taken from the tool call rather than from the permission request,
    ;; because only the call is in the recording a resume replays.
    (when (equal name "ExitPlanMode")
      (ecc-model-note-plan-file session (alist-get 'planFilePath input)))
    (when-let* ((kind (cdr (assoc name ecc-dispatch-file-tools))))
      (ecc-model-note-file session (alist-get 'file_path input) nil)
      (when (memq kind '(edit write))
        (ecc-model-node-put node 'before
                            (ecc-dispatch--file-before session
                                                       (alist-get 'file_path input)))))
    (when (equal name "TodoWrite")
      (ecc-dispatch--todos session (alist-get 'todos input)))
    (ecc-model-node-changed session node)))

(defun ecc-dispatch--file-before (session path)
  "Return what PATH of SESSION looks like before Claude changes it.
The file on disk is the truth; the content of the last Read is the
fallback when the file cannot be read.  Returns nil when neither is
known."
  (or (ecc-diff-file-content path)
      (when-let* ((entry (and (stringp path)
                              (gethash path (ecc-session-files session)))))
        (ecc-file-entry-snapshot entry))))

(defun ecc-dispatch--todos (session todos)
  "Replace the task list of SESSION with the TodoWrite TODOS."
  (let ((n 0))
    (ecc-model-replace-tasks
     session
     (mapcar (lambda (todo)
               (make-ecc-task :id (format "%d" (cl-incf n))
                              :subject (alist-get 'content todo)
                              :status (or (alist-get 'status todo) "pending")))
             (append (or todos []) nil)))))

;;;; user

(defun ecc-dispatch--user (session message)
  "Apply the user MESSAGE to SESSION.
Most of these are tool results.  With --replay-user-messages the CLI
also echoes prompts back: the echo of one sent from here is an
acknowledgement and nothing more, while one nobody here typed came from
somewhere else -- a phone on the Remote Control bridge -- and is the
prompt of the turn about to run (`ecc-dispatch--remote-prompt\=').  A
text message under a parent_tool_use_id is the prompt a subagent was
started with."
  (if (ecc-protocol-replay-p message)
      (let ((content (alist-get 'content (alist-get 'message message))))
        (setf (alist-get 'replayed (ecc-session-progress session)) content)
        (unless (ecc-proc-take-sent-echo session content)
          (ecc-dispatch--remote-prompt session message content)))
    (let ((parent (ecc-dispatch--parent session message
                                        (ecc-model-ensure-turn session))))
      (dolist (block (ecc-protocol-content-blocks message))
        (pcase (alist-get 'type block)
          ("tool_result" (ecc-dispatch--tool-result session block message))
          ("text"
           (let ((text (alist-get 'text block)))
             (cond
              ;; The note the CLI writes before the record of a local
              ;; command is addressed to the model, and is not drawn;
              ;; the log keeps it.
              ((ecc-protocol-command-caveat-p text)
               (ecc-log (ecc-session-name session) "local command caveat skipped"))
              ((ecc-protocol-parse-command text)
               (ecc-dispatch--command session text parent))
              ((ecc-protocol-command-output text)
               (ecc-dispatch-command-output session text))
              (t
               ;; Notes the CLI writes into the conversation itself, such as
               ;; the acknowledgement of an interrupt, or the prompt of an agent.
               (ecc-model-add-node session :type 'system :status 'done
                                   :parent parent
                                   :data (list (cons 'kind (if (ecc-turn-p parent)
                                                               'note 'prompt))
                                               (cons 'text text)))))))
          (_ (ecc-model-add-node session :type 'unknown :status 'done
                                 :parent parent
                                 :data (list (cons 'block block)))))))))

(defun ecc-dispatch--remote-prompt (session message content)
  "Show CONTENT of MESSAGE as a prompt of SESSION that Emacs did not send.
It came from wherever else the session can be reached, which today
means the Remote Control bridge.  The CLI echoes it before it answers,
so the usual case is that no turn is open yet and this opens one, the
way `ecc-proc-send-user\=' would have; a turn already opened by an
answer that arrived first takes the text as its prompt instead.

Synthetic messages are left alone: the CLI writes those into the
conversation itself (a system reminder, the record of a local command)
and they are not anybody\='s prompt."
  (unless (or (ecc--json-true-p (alist-get 'isSynthetic message))
              (not (stringp content))
              (string-empty-p (string-trim content))
              (ecc-protocol-command-caveat-p content)
              (ecc-protocol-parse-command content)
              (ecc-protocol-command-output content))
    (ecc-log (ecc-session-name session) "prompt from elsewhere: %s"
             (ecc--truncate content 60))
    (let ((turn (or (ecc-session-current-turn session)
                    (ecc-model-begin-turn session content))))
      (unless (ecc-turn-prompt turn)
        (setf (ecc-turn-prompt turn) content))
      ;; It is still a turn nobody here started, and the state line and
      ;; the queue message say so.
      (setf (ecc-turn-label turn) ecc-model-remote-turn-label)
      (run-hook-with-args 'ecc-progress-hook session)
      turn)))

(defun ecc-dispatch--command (session text parent)
  "Add the local command TEXT records to SESSION under PARENT.
A slash command the CLI answered itself is not a prompt: it opens no
turn, and what it printed arrives after it and is put on this node
."
  (let* ((fields (ecc-protocol-parse-command text))
         (node (ecc-model-add-node session :type 'command :status 'done
                                   :parent parent
                                   :data (list (cons 'name (alist-get 'name fields))
                                               (cons 'args (alist-get 'args fields))
                                               (cons 'output nil)))))
    (setf (alist-get 'command-node (ecc-session-progress session))
          (ecc-node-id node))
    node))

(defun ecc-dispatch-command-output (session text)
  "Put what a local command printed, TEXT, on the command node of SESSION.
TEXT is the whole `<local-command-stdout>' element, or what
`system/local_command' carries.  Without a command to put it on -- a
page of a recording can start between the two lines -- it is kept as a
system note rather than dropped."
  (let* ((output (or (ecc-protocol-command-output text) text))
         (id (alist-get 'command-node (ecc-session-progress session)))
         (node (and id (ecc-model-node session id))))
    (if (not (and node (eq (ecc-node-type node) 'command)))
        (ecc-model-add-aside session :type 'system :status 'done
                             :data (list (cons 'kind 'command-output)
                                         (cons 'text output)))
      (ecc-model-node-put node 'output
                          (let ((had (ecc-model-node-get node 'output)))
                            (if (and had (not (string-empty-p had)))
                                (concat had "\n" output)
                              output)))
      (ecc-model-node-changed session node)
      node)))

(defun ecc-dispatch--tool-result (session block message)
  "Store the tool_result BLOCK of MESSAGE on its tool node in SESSION."
  (let* ((id (alist-get 'tool_use_id block))
         (node (ecc-model-node session id))
         (error-p (eq (alist-get 'is_error block) t))
         (structured (alist-get 'tool_use_result message)))
    (if (null node)
        (ecc-model-add-aside session :type 'unknown :status 'done
                             :data (list (cons 'block block)
                                         (cons 'reason "no tool_use for this result")))
      (ecc-model-node-put node 'result (alist-get 'content block))
      (ecc-model-node-put node 'is-error error-p)
      (ecc-model-node-put node 'finished (current-time))
      (setf (ecc-node-status node) (if error-p 'error 'done))
      (ecc-model-note-tool-finished session node)
      (ecc-dispatch--progress session 'running-tool nil)
      (unless error-p
        (when-let* ((kind (cdr (assoc (ecc-model-node-get node 'name)
                                      ecc-dispatch-file-tools))))
          (ecc-model-note-file session
                               (alist-get 'file_path (ecc-model-node-get node 'input))
                               kind))
        (ecc-dispatch--structured-result session node structured))
      (ecc-model-node-changed session node)
      (let ((name (ecc-model-node-get node 'name))
            (path (alist-get 'file_path (ecc-model-node-get node 'input))))
        (when (and path (not error-p)
                   (memq (cdr (assoc name ecc-dispatch-file-tools)) '(edit write)))
          (run-hook-with-args 'ecc-sync-file-changed-hook session path)))
      node)))

(defun ecc-dispatch--structured-result (session node result)
  "Apply the structured tool_use_result RESULT of the tool NODE to SESSION.
The CLI reports what a file tool did in a machine readable form next to
the text Claude sees: the content a Read returned, the original file and
the patch of an Edit or a Write, the id and status of a task."
  (let ((name (ecc-model-node-get node 'name))
        (input (ecc-model-node-get node 'input)))
    (pcase name
      ("Read"
       (ecc-model-note-snapshot session (alist-get 'file_path input)
                                (alist-get 'content (alist-get 'file result))))
      ((or "Edit" "MultiEdit")
       (let ((path (alist-get 'file_path input))
             (original (alist-get 'originalFile result))
             (patch (alist-get 'structuredPatch result)))
         (ecc-model-note-hunk session path
                              (or (alist-get 'oldString result)
                                  (alist-get 'old_string input))
                              (or (alist-get 'newString result)
                                  (alist-get 'new_string input))
                              patch
                              (if (stringp original)
                                  original
                                (ecc-model-node-get node 'before)))
         (when (stringp original)
           (ecc-model-note-snapshot
            session path
            (string-replace (or (alist-get 'old_string input) "")
                            (or (alist-get 'new_string input) "")
                            original)))))
      ("Write"
       (let ((original (or (alist-get 'originalFile result)
                           (ecc-model-node-get node 'before))))
         (ecc-model-note-hunk session (alist-get 'file_path input)
                              original
                              (or (alist-get 'content result)
                                  (alist-get 'content input))
                              (alist-get 'structuredPatch result)
                              original)))
      ("TaskCreate"
       (let ((task (alist-get 'task result)))
         (ecc-model-note-task session (alist-get 'id task)
                              (or (alist-get 'subject task)
                                  (alist-get 'subject input))
                              (or (alist-get 'status task) "pending"))))
      ("TaskUpdate"
       (ecc-model-note-task session
                            (or (alist-get 'taskId result) (alist-get 'taskId input))
                            (alist-get 'subject input)
                            (or (alist-get 'to (alist-get 'statusChange result))
                                (alist-get 'status input))))
      ((or "TaskList" "TaskGet")
       (when-let* ((tasks (alist-get 'tasks result)))
         (ecc-model-replace-tasks
          session
          (mapcar (lambda (task)
                    (make-ecc-task :id (format "%s" (alist-get 'id task))
                                   :subject (alist-get 'subject task)
                                   :status (alist-get 'status task)))
                  (append tasks nil))))))))

;;;; control_request (can_use_tool)

(defun ecc-dispatch--request-kind (tool-name)
  "Return the kind of request TOOL-NAME asks for."
  (pcase tool-name
    ("AskUserQuestion" 'question)
    ("ExitPlanMode" 'plan)
    (_ 'permission)))

(defun ecc-dispatch--control-request (session message)
  "Apply the control_request MESSAGE from the CLI to SESSION."
  (if (not (eq (ecc-protocol-control-subtype message) 'can_use_tool))
      (ecc-dispatch--unknown session message nil)
    (let* ((request-object (alist-get 'request message))
           (tool-name (alist-get 'tool_name request-object))
           (kind (ecc-dispatch--request-kind tool-name))
           (input (ecc-protocol-request-input message))
           (_ (when (eq kind 'plan)
                (ecc-model-note-plan-file session (alist-get 'planFilePath input))))
           (request (make-ecc-request
                     :request-id (alist-get 'request_id message)
                     :session session
                     :kind kind
                     :tool-name tool-name
                     :display-name (or (alist-get 'display_name request-object)
                                       tool-name)
                     :description (alist-get 'description request-object)
                     :input input
                     :tool-use-id (alist-get 'tool_use_id request-object)
                     :suggestions (ecc-protocol-request-suggestions message)
                     :created-at (current-time))))
      (if (ecc-dispatch-auto-approve-p session request)
          (ecc-dispatch--auto-allow session request)
        (setf (ecc-request-node request)
              (ecc-model-add-node
               session
               :type kind
               :status 'pending
               :data (list (cons 'request request)
                           (cons 'message message)
                           ;; What the file looks like now, for the diff
                           ;; shown before the change is allowed.
                           (cons 'before
                                 (when (memq (cdr (assoc tool-name
                                                         ecc-dispatch-file-tools))
                                             '(edit write))
                                   (ecc-dispatch--file-before
                                    session (alist-get 'file_path input)))))))
        (ecc-model-add-request session request)))))

(defun ecc-dispatch-auto-approve-p (session request)
  "Return non-nil when SESSION may allow REQUEST without asking.
A turn wide approval covers `ecc-turn-approve-tools', and a tool the
user allowed for the whole session is never asked about again ."
  (let ((name (ecc-request-tool-name request)))
    (and (eq (ecc-request-kind request) 'permission)
         (or (and (ecc-session-auto-approve-turn session)
                  (member name ecc-turn-approve-tools))
             (member name (ecc-session-auto-approve-kinds session)))
         t)))

(defun ecc-dispatch--auto-allow (session request)
  "Allow REQUEST of SESSION at once and note it in the transcript."
  (ecc-proc-send-json session
                      (ecc-protocol-permission-allow
                       (ecc-request-request-id request)
                       :updated-input (ecc-request-input request)))
  (ecc-model-add-aside session :type 'system :status 'done
                       :data (list (cons 'kind 'auto-allow)
                                   (cons 'text (format "auto-allowed %s"
                                                       (ecc-request-tool-name request))))))

(defun ecc-dispatch--command-lifecycle (session message)
  "Apply the command_lifecycle MESSAGE to SESSION.
The CLI reports what became of a prompt it was handed: `queued\=',
`started\=' and `completed\=', each naming the uuid of the user message
it is about.  A prompt sent from the Remote Control bridge arrives this
way and no other -- the text is not in the stream unless
`ecc-replay-user-messages\=' is on (confirmed 2026-09-08) -- which is
worth knowing but not worth a line in the transcript: the answer that
follows is the line.  It is kept in the progress information, where the
state line can reach it, and in the log."
  (let ((state (alist-get 'state message))
        (uuid (alist-get 'command_uuid message)))
    (ecc-log (ecc-session-name session) "prompt %s: %s" (or uuid "?") state)
    (setf (alist-get 'command-lifecycle (ecc-session-progress session))
          (cons uuid state))
    (run-hook-with-args 'ecc-progress-hook session)))

;;;; control_response

(defun ecc-dispatch--control-response (session message)
  "Apply the control_response MESSAGE to SESSION."
  (let* ((outer (alist-get 'response message))
         (request-id (alist-get 'request_id outer))
         (response (alist-get 'response outer))
         (callback (ecc-proc-take-control-callback session request-id)))
    (when (equal (alist-get 'subtype outer) "error")
      (ecc-log (ecc-session-name session) "control request %s failed: %s"
               request-id (alist-get 'error outer))
      ;; An error carries no inner response object, so what went wrong is
      ;; handed to the callback in its place: a request that was refused
      ;; is not the same as one that was answered with nothing, and the
      ;; caller has to be able to tell (a permission mode this model
      ;; cannot have, for one).
      (setq response (list (cons 'error (or (alist-get 'error outer) t)))))
    ;; The initialize response carries the model catalogue beside the
    ;; commands, and /model is offered from it.  It is read first so
    ;; that the hook below sees both.
    (when (assq 'models response)
      (setf (ecc-session-models session) (alist-get 'models response)))
    (when (assq 'commands response)
      (setf (ecc-session-commands session) (alist-get 'commands response))
      (run-hook-with-args 'ecc-commands-updated-hook session))
    (when (functionp callback)
      (funcall callback session response))))

(defun ecc-dispatch--control-cancel (session message)
  "Withdraw the request MESSAGE cancels from SESSION.
The CLI sends it when it no longer needs the answer, and a permission
answered somewhere else is how that happens here: with
Remote Control on, a can_use_tool goes to Emacs and to the phone at
once, and whoever answers first ends it for both (measured
2026-09-08).  Nothing is sent back; the request is closed, so that the
transcript stops asking for an answer that has already been given, and
so does the state line."
  (let* ((request-id (alist-get 'request_id message))
         (request (and request-id (ecc-model-request session request-id))))
    (ecc-log (ecc-session-name session) "request %s was withdrawn%s"
             (or request-id "?") (if request "" " (nothing pending)"))
    (when request
      (when-let* ((node (ecc-request-node request)))
        (ecc-model-node-put node 'outcome-message "answered elsewhere"))
      (ecc-model-resolve-request session request 'done)
      (run-hook-with-args 'ecc-progress-hook session))
    ;; A control request of our own can be withdrawn too; its callback
    ;; will never be called, so it is forgotten rather than left to time
    ;; out.
    (when request-id
      (ecc-proc-take-control-callback session request-id))
    request))

;;;; result

(defun ecc-dispatch--result (session message)
  "Close the current turn of SESSION with the result MESSAGE."
  (let ((turn (ecc-model-ensure-turn session)))
    (ecc-model-add-node session :type 'result :parent turn :status 'done
                        :data (list (cons 'result message)))
    (ecc-model-finish-turn session message)
    ;; The turn is over, so nothing is waiting for the answer to a
    ;; request it left open -- an interrupt ends a turn this way.
    (when-let* ((abandoned (ecc-model-abandon-requests
                            session "the turn ended before it was answered")))
      (ecc-log (ecc-session-name session)
               "the result closed %d unanswered request(s)" (length abandoned)))
    (ecc-model-set-state session 'idle)
    (setf (alist-get 'thinking-tokens (ecc-session-progress session)) nil
          (alist-get 'running-tool (ecc-session-progress session)) nil
          (alist-get 'streaming (ecc-session-progress session)) nil
          ;; The CLI clears its own line with a null detail, but a turn
          ;; that ended some other way must not leave it standing.
          (alist-get 'task-summary (ecc-session-progress session)) nil)
    (run-hook-with-args 'ecc-progress-hook session)
    (ecc-proc-drain-queue session)
    turn))

;;;; stream_event

(defun ecc-dispatch--stream-event (session message)
  "Apply the streaming MESSAGE to SESSION.
A content_block_start opens a provisional node, the deltas grow it, and
the assistant message that follows completes it.  A content_block_stop
that comes without an assistant message closes the node with what was
streamed."
  (let* ((event (alist-get 'event message))
         (parent-id (alist-get 'parent_tool_use_id message))
         (index (alist-get 'index event)))
    (pcase (alist-get 'type event)
      ("message_start"
       (ecc-model-ensure-turn session))
      ("content_block_start"
       (ecc-dispatch--block-start session message parent-id index
                                  (alist-get 'content_block event)))
      ("content_block_delta"
       (ecc-dispatch--block-delta session parent-id index (alist-get 'delta event)))
      ("content_block_stop"
       (when-let* ((node (ecc-model-stream-node session parent-id index)))
         (when (ecc-node-streaming node)
           (ecc-dispatch--block-stop session node))))
      ("message_delta"
       (when-let* ((usage (alist-get 'usage event)))
         (setf (alist-get 'output-tokens (ecc-session-progress session))
               (alist-get 'output_tokens usage))))
      ("message_stop"
       (ecc-dispatch--progress session 'streaming nil))
      (_ nil))))

(defun ecc-dispatch--block-start (session message parent-id index block)
  "Open a node in SESSION for the streamed content BLOCK.
The block is at INDEX under PARENT-ID; MESSAGE is the stream_event it
came in."
  (let* ((turn (ecc-model-ensure-turn session))
         (parent (ecc-dispatch--parent session message turn))
         (type (alist-get 'type block))
         (node
          (pcase type
            ("tool_use"
             (let ((node (ecc-dispatch--new-tool session (alist-get 'id block)
                                                 (alist-get 'name block) parent)))
               (ecc-dispatch--progress session 'running-tool
                                       (cons (alist-get 'name block) nil))
               node))
            ((or "text" "thinking")
             (ecc-model-add-node session
                                 :type (intern type)
                                 :parent parent
                                 :status 'running
                                 :data (list (cons 'text ""))))
            (_ nil))))
    (when node
      (ecc-model-open-stream session parent-id index node))
    node))

(defun ecc-dispatch--block-delta (session parent-id index delta)
  "Grow the node of SESSION streaming block INDEX under PARENT-ID by DELTA."
  (let ((node (ecc-model-stream-node session parent-id index))
        (text (pcase (alist-get 'type delta)
                ("text_delta" (alist-get 'text delta))
                ("thinking_delta" (alist-get 'thinking delta))
                ("input_json_delta" (alist-get 'partial_json delta))
                (_ nil))))
    (when (and node text (not (string-empty-p text)))
      (ecc-model-append-stream session node text)
      (setf (alist-get 'streaming (ecc-session-progress session))
            (cons (ecc-node-type node)
                  (length (ecc-node-streaming-text node)))))))

(defun ecc-dispatch--block-stop (session node)
  "Close the streamed NODE of SESSION with the text it received.
The complete assistant message normally arrives first and replaces
the streamed text; this is the fallback when it did not."
  (pcase (ecc-node-type node)
    ((or 'text 'thinking)
     (ecc-model-node-put node 'text (or (ecc-node-streaming-text node) ""))
     (setf (ecc-node-status node) 'done))
    (_ nil))
  (setf (ecc-node-streaming-text node) nil)
  (ecc-model-close-stream session node)
  (ecc-model-node-changed session node))

(provide 'ecc-dispatch)

;;; ecc-dispatch.el ends here
