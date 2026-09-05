;;; ecc-dispatch.el --- Turn CLI messages into model changes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-dispatch' implements the table of section 4 of
;; IMPLEMENTATION_PLAN.md: it looks at the type and subtype of a parsed
;; message, updates the model and lets the model announce the change.
;;
;; Nothing is dropped.  A message this file does not know, and any error
;; raised while handling one, ends up as an `unknown' node in the
;; transcript and in the log (FR-OUT-1, NFR-2, plan section 9, item 19).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)

(defcustom ecc-turn-approve-tools '("Edit" "Write" "NotebookEdit")
  "Tools that a turn-wide approval covers (FR-PERM-7)."
  :type '(repeat string)
  :group 'ecc)

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
    ('result (ecc-dispatch--result session message))
    ('stream_event (ecc-dispatch--stream-event session message))
    ('rate_limit_event
     (setf (ecc-session-rate-limit session) (alist-get 'rate_limit_info message))
     (run-hook-with-args 'ecc-usage-hook session))
    ('prompt_suggestion
     (setf (alist-get 'suggestion (ecc-session-recap-state session))
           (alist-get 'prompt_suggestion message))
     (run-hook-with-args 'ecc-progress-hook session))
    (_ (ecc-dispatch--unknown session message nil))))

(defun ecc-dispatch--unknown (session message reason)
  "Keep MESSAGE of SESSION as an unknown node, noting REASON."
  (ecc-model-add-node session
                      :type 'unknown
                      :status 'done
                      :data (list (cons 'message message)
                                  (cons 'reason reason))))

;;;; system

(defun ecc-dispatch--system (session message)
  "Apply the system MESSAGE to SESSION."
  (pcase (ecc-protocol-subtype message)
    ('init (ecc-dispatch--init session message))
    ('status (ecc-dispatch--status session message))
    ('thinking_tokens
     (setf (alist-get 'thinking-tokens (ecc-session-progress session))
           (alist-get 'estimated_tokens message))
     (run-hook-with-args 'ecc-progress-hook session))
    ((or 'hook_started 'hook_response)
     (ecc-model-add-node session :type 'system :status 'done
                         :data (list (cons 'kind 'hook)
                                     (cons 'message message))))
    ('permission_denied
     (when-let* ((node (ecc-model-node session (alist-get 'tool_use_id message))))
       (setf (ecc-node-status node) 'denied)
       (ecc-model-node-changed session node)))
    ('compact_boundary (ecc-dispatch--compacted session message nil))
    ((or 'task_started 'task_progress 'task_updated 'task_notification
         'background_tasks_changed)
     (ecc-dispatch--task session message))
    (_ (ecc-dispatch--unknown session message nil))))

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
  (when (eq (ecc-session-state session) 'starting)
    (ecc-model-set-state session 'idle))
  (run-hook-with-args 'ecc-session-init-hook session))

(defun ecc-dispatch--status (session message)
  "Apply the system/status MESSAGE to SESSION."
  (when-let* ((mode (alist-get 'permissionMode message)))
    (setf (ecc-session-permission-mode session) mode))
  (when (equal (alist-get 'status message) "compacting")
    (ecc-model-set-state session 'compacting))
  ;; The key is present with a null value on the closing message, so ask
  ;; for the cell rather than the value (plan section 12.8).
  (when (assq 'compact_result message)
    (ecc-dispatch--compacted session message (alist-get 'compact_result message)))
  (run-hook-with-args 'ecc-status-hook session))

(defun ecc-dispatch--compacted (session message result)
  "Note in SESSION that MESSAGE reports a compaction with RESULT."
  (ecc-model-add-node session :type 'system :status 'done
                      :data (list (cons 'kind 'compact)
                                  (cons 'result result)
                                  (cons 'error (alist-get 'compact_error message))
                                  (cons 'message message)))
  (when (equal result "success")
    (setf (ecc-session-context-tokens session) 0))
  (when (eq (ecc-session-state session) 'compacting)
    (ecc-model-set-state session
                         (if (ecc-session-current-turn session) 'running 'idle)))
  (run-hook-with-args 'ecc-compact-hook session))

(defun ecc-dispatch--task (session message)
  "Apply a task lifecycle MESSAGE to SESSION.
The node is looked up in the session rather than in the current turn,
because an asynchronous agent reports after the turn is over (D5)."
  (let* ((node (ecc-model-node session (alist-get 'tool_use_id message)))
         (patch (alist-get 'patch message))
         (status (or (alist-get 'status message) (alist-get 'status patch))))
    (ecc-model-note-task session (alist-get 'task_id message)
                         (or (alist-get 'subject message)
                             (alist-get 'description message))
                         status)
    (when node
      (ecc-model-node-put node 'task message)
      (when status (ecc-model-node-put node 'task-status status))
      (ecc-model-node-changed session node))))

;;;; assistant

(defun ecc-dispatch--assistant (session message)
  "Apply the assistant MESSAGE to SESSION, one content block at a time."
  (let* ((turn (ecc-model-ensure-turn session))
         (synthetic (ecc-protocol-synthetic-p message))
         (uuid (or (alist-get 'uuid message) (ecc-model-next-node-id session)))
         (index -1))
    ;; A synthetic reply reports no tokens, so it must not move the
    ;; context estimate (plan section 9, item 12).
    (unless synthetic
      (ecc-model-update-usage session
                              (alist-get 'usage (alist-get 'message message))))
    (dolist (block (ecc-protocol-content-blocks message))
      (cl-incf index)
      (let ((id (format "%s:%d" uuid index))
            (parent (ecc-dispatch--parent session message turn)))
        (pcase (alist-get 'type block)
          ("thinking"
           (ecc-model-add-node session :id id :type 'thinking :status 'done
                               :parent parent
                               :data (list (cons 'text (alist-get 'thinking block)))))
          ("text"
           (ecc-model-add-node session :id id :type 'text :status 'done
                               :parent parent
                               :data (list (cons 'text (alist-get 'text block))
                                           (cons 'synthetic synthetic))))
          ("tool_use" (ecc-dispatch--tool-use session block parent))
          (_ (ecc-model-add-node session :id id :type 'unknown :status 'done
                                 :parent parent
                                 :data (list (cons 'block block)))))))))

(defun ecc-dispatch--parent (session message turn)
  "Return the node MESSAGE belongs under in TURN of SESSION.
A message with a parent_tool_use_id belongs to a subagent, so it goes
under the tool node that started it (FR-OUT-9)."
  (let ((parent-id (alist-get 'parent_tool_use_id message)))
    (or (when-let* ((node (and parent-id (ecc-model-node session parent-id))))
          (setf (ecc-node-type node) 'agent)
          node)
        turn)))

(defun ecc-dispatch--tool-use (session block parent)
  "Add the tool_use BLOCK to SESSION under PARENT."
  (let* ((name (alist-get 'name block))
         (input (alist-get 'input block))
         (step (if (ecc-turn-p parent)
                   (ecc-model-step-for-tool session parent)
                 parent))
         (node (ecc-model-add-node
                session
                :id (alist-get 'id block)
                :type 'tool
                :parent step
                :status 'running
                :data (list (cons 'name name)
                            (cons 'input input)
                            (cons 'started (current-time))))))
    (when-let* ((kind (cdr (assoc name ecc-dispatch-file-tools))))
      (ecc-model-note-file session (alist-get 'file_path input) kind))
    node))

;;;; user

(defun ecc-dispatch--user (session message)
  "Apply the user MESSAGE to SESSION.
Most of these are tool results; the CLI also echoes prompts back when
--replay-user-messages is on, and those are acknowledgements only."
  (if (ecc-protocol-replay-p message)
      (setf (alist-get 'replayed (ecc-session-progress session))
            (alist-get 'content (alist-get 'message message)))
    (dolist (block (ecc-protocol-content-blocks message))
      (pcase (alist-get 'type block)
        ("tool_result" (ecc-dispatch--tool-result session block))
        ("text"
         ;; Notes the CLI writes into the conversation itself, such as
         ;; the acknowledgement of an interrupt.
         (ecc-model-add-node session :type 'system :status 'done
                             :data (list (cons 'kind 'note)
                                         (cons 'text (alist-get 'text block)))))
        (_ (ecc-model-add-node session :type 'unknown :status 'done
                               :data (list (cons 'block block))))))))

(defun ecc-dispatch--tool-result (session block)
  "Store the tool_result BLOCK on the tool node it belongs to in SESSION."
  (let* ((id (alist-get 'tool_use_id block))
         (node (ecc-model-node session id))
         (error-p (eq (alist-get 'is_error block) t)))
    (if (null node)
        (ecc-model-add-node session :type 'unknown :status 'done
                            :data (list (cons 'block block)
                                        (cons 'reason "no tool_use for this result")))
      (ecc-model-node-put node 'result (alist-get 'content block))
      (ecc-model-node-put node 'is-error error-p)
      (ecc-model-node-put node 'finished (current-time))
      (setf (ecc-node-status node) (if error-p 'error 'done))
      (ecc-model-node-changed session node)
      (let ((name (ecc-model-node-get node 'name))
            (path (alist-get 'file_path (ecc-model-node-get node 'input))))
        (when (and path (not error-p)
                   (memq (cdr (assoc name ecc-dispatch-file-tools)) '(edit write)))
          (run-hook-with-args 'ecc-sync-file-changed-hook session path)))
      node)))

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
           (request (make-ecc-request
                     :request-id (alist-get 'request_id message)
                     :session session
                     :kind kind
                     :tool-name tool-name
                     :display-name (or (alist-get 'display_name request-object)
                                       tool-name)
                     :description (alist-get 'description request-object)
                     :input (ecc-protocol-request-input message)
                     :tool-use-id (alist-get 'tool_use_id request-object)
                     :suggestions (alist-get 'permission_suggestions request-object)
                     :created-at (current-time))))
      (if (ecc-dispatch-auto-approve-p session request)
          (ecc-dispatch--auto-allow session request)
        (setf (ecc-request-node request)
              (ecc-model-add-node session
                                  :type kind
                                  :status 'pending
                                  :data (list (cons 'request request)
                                              (cons 'message message))))
        (ecc-model-add-request session request)))))

(defun ecc-dispatch-auto-approve-p (session request)
  "Return non-nil when SESSION may allow REQUEST without asking.
A turn wide approval covers `ecc-turn-approve-tools' (FR-PERM-7), and a
tool the user allowed for the whole session is never asked about again
\(FR-PERM-9)."
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
  (ecc-model-add-node session :type 'system :status 'done
                      :data (list (cons 'kind 'auto-allow)
                                  (cons 'text (format "auto-allowed %s"
                                                      (ecc-request-tool-name request))))))

;;;; control_response

(defun ecc-dispatch--control-response (session message)
  "Apply the control_response MESSAGE to SESSION."
  (let* ((outer (alist-get 'response message))
         (request-id (alist-get 'request_id outer))
         (response (alist-get 'response outer))
         (callback (ecc-proc-take-control-callback session request-id)))
    (when (equal (alist-get 'subtype outer) "error")
      (ecc-log (ecc-session-name session) "control request %s failed: %s"
               request-id (alist-get 'error outer)))
    (when (assq 'commands response)
      (setf (ecc-session-commands session) (alist-get 'commands response))
      (run-hook-with-args 'ecc-commands-updated-hook session))
    (when (functionp callback)
      (funcall callback session response))))

;;;; result

(defun ecc-dispatch--result (session message)
  "Close the current turn of SESSION with the result MESSAGE."
  (let ((turn (ecc-model-ensure-turn session)))
    (ecc-model-add-node session :type 'result :parent turn :status 'done
                        :data (list (cons 'result message)))
    (ecc-model-finish-turn session message)
    (ecc-model-set-state session
                         (if (ecc-session-pending session)
                             (ecc-session-state session)
                           'idle))
    (ecc-proc-drain-queue session)
    turn))

;;;; stream_event

(defun ecc-dispatch--stream-event (session message)
  "Note the streaming MESSAGE of SESSION.
Phase 1 renders from the complete assistant messages that follow, so
the deltas only drive the progress indicator here; phase 2 turns them
into incremental text (plan section 5.2, item 4)."
  (let ((event (alist-get 'event message)))
    (when (equal (alist-get 'type event) "content_block_delta")
      (setf (alist-get 'streaming (ecc-session-progress session))
            (or (alist-get 'text (alist-get 'delta event))
                (alist-get 'thinking (alist-get 'delta event))
                (alist-get 'partial_json (alist-get 'delta event))))
      (run-hook-with-args 'ecc-progress-hook session))))

(provide 'ecc-dispatch)

;;; ecc-dispatch.el ends here
