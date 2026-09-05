;;; ecc-model.el --- Transcript model for the ecc Claude Code client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The session, the Turn > Step > Tool tree and the queue of requests
;; waiting for an answer.  Section 3 of IMPLEMENTATION_PLAN.md.
;;
;; This file knows nothing about JSON, about processes or about
;; magit-section (NFR-9).  It only stores what `ecc-dispatch' hands it and
;; announces every change through the hooks of section 4.3, which is how
;; the renderer and the rest of the user interface hear about it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)

;;;; Hooks (plan section 4.3)

;; All of these are abnormal hooks.  The first argument is always the
;; session; a second argument, where there is one, is the node or the
;; request the change is about.

(defvar ecc-session-init-hook nil
  "Functions run with a session when a system/init message arrives.")

(defvar ecc-commands-updated-hook nil
  "Functions run with a session when its slash command list changes.")

(defvar ecc-status-hook nil
  "Functions run with a session when a system/status message arrives.")

(defvar ecc-progress-hook nil
  "Functions run with a session when progress information changes.")

(defvar ecc-node-added-hook nil
  "Functions run with a session and the node that was just added.")

(defvar ecc-node-updated-hook nil
  "Functions run with a session and the node that just changed.")

(defvar ecc-stream-delta-hook nil
  "Functions run with a session, a node and the text appended to it.")

(defvar ecc-request-added-hook nil
  "Functions run with a session and a request that needs an answer.")

(defvar ecc-request-resolved-hook nil
  "Functions run with a session and a request that has been answered.")

(defvar ecc-turn-started-hook nil
  "Functions run with a session and the turn that just started.")

(defvar ecc-turn-finished-hook nil
  "Functions run with a session and the turn that just finished.")

(defvar ecc-usage-hook nil
  "Functions run with a session when token usage or cost changed.")

(defvar ecc-compact-hook nil
  "Functions run with a session when the conversation was compacted.")

(defvar ecc-sync-file-changed-hook nil
  "Functions run with a session and a file path Claude just wrote.")

(defvar ecc-session-exited-hook nil
  "Functions run with a session and the exit status of its process.")

(defvar ecc-session-state-changed-hook nil
  "Functions run with a session and its previous state.")

;;;; Structures (plan section 3)

(cl-defstruct (ecc-session (:constructor ecc-session--make) (:copier nil))
  "One Claude Code conversation and everything Emacs knows about it."
  id                    ; session_id string (a UUID)
  name                  ; display name, unique among the live sessions
  project-root
  cwd
  kind                  ; own | external | archived | handoff
  process
  stream-buffer         ; line buffer for the process filter (plan 3.1
                        ; calls this partial-line; a buffer is used so
                        ; that a multi-megabyte line costs no repeated
                        ; string concatenation, see plan 2.2)
  state                 ; starting | idle | running | waiting-permission
                        ; | waiting-question | waiting-plan | compacting
                        ; | exited
  buffer
  prompt-buffer
  options               ; plist of launch options, nil means "use the
                        ; matching defcustom"
  init                  ; the latest system/init message
  commands              ; commands from the initialize response
  permission-mode
  turns                 ; list of ecc-turn, oldest first
  current-turn
  nodes                 ; hash: node id -> ecc-node
  pending               ; list of ecc-request, oldest first
  pending-controls      ; hash: request_id -> callback
  files                 ; hash: path -> ecc-file-entry
  tasks                 ; hash: task id -> ecc-task
  usage
  context-tokens
  total-cost
  rate-limit
  last-result-time
  progress              ; alist of progress information for the state line
  auto-approve-turn     ; FR-PERM-7
  auto-approve-kinds    ; FR-PERM-9
  input-queue           ; FR-INP-6, oldest first
  history-offset
  recap-state
  tmp-dir
  node-counter          ; counters for the ids of nodes and turns; the
  turn-counter)         ; ids have to be stable, see plan 9.6

(cl-defstruct ecc-turn
  "One prompt and everything that followed it up to the result."
  id start-time end-time prompt children result cost)

(cl-defstruct ecc-node
  "One item in the transcript tree."
  id
  type          ; step | text | thinking | tool | agent | system
                ; | permission | question | plan | recap | result | unknown
  parent        ; an ecc-node or an ecc-turn
  children
  data          ; alist, the keys depend on TYPE
  status        ; pending | running | done | error | denied
  streaming-text
  marker-start marker-end)              ; owned by the renderer

(cl-defstruct ecc-file-entry
  "What Claude did to one file during a session."
  path reads edits writes hunks)

(cl-defstruct ecc-task
  "One entry of Claude's own task list."
  id subject status)

(cl-defstruct ecc-request
  "A can_use_tool request that is waiting for an answer."
  request-id
  session
  kind                  ; permission | question | plan
  tool-name display-name description
  input                 ; the tool input, ready to be echoed back
  tool-use-id
  suggestions
  created-at
  node)

;;;; The session registry

(defvar ecc--sessions (make-hash-table :test #'equal)
  "Hash mapping a session id to its `ecc-session'.")

(defvar ecc--session-order nil
  "Session ids, most recently used first.")

(defun ecc-model-sessions ()
  "Return the live sessions, most recently used first."
  (delq nil (mapcar (lambda (id) (gethash id ecc--sessions)) ecc--session-order)))

(defun ecc-model-session (id)
  "Return the session with ID, or nil."
  (gethash id ecc--sessions))

(defun ecc-model-touch (session)
  "Move SESSION to the front of the most-recently-used order."
  (let ((id (ecc-session-id session)))
    (setq ecc--session-order (cons id (delete id ecc--session-order)))))

(defun ecc-model-unique-name (base)
  "Return BASE, or BASE with a suffix if a session already uses it."
  (let ((name base)
        (n 1))
    (while (seq-find (lambda (s) (equal (ecc-session-name s) name))
                     (ecc-model-sessions))
      (setq n (1+ n)
            name (format "%s<%d>" base n)))
    name))

(cl-defun ecc-model-create-session (&key id name project-root cwd kind options)
  "Make a session, register it and return it.
ID defaults to a fresh UUID, NAME to the directory name of
PROJECT-ROOT and KIND to `own'.  CWD, the directory the CLI reports
working in, defaults to PROJECT-ROOT.  OPTIONS is the plist of launch
options that overrides the defcustoms for this session."
  (let* ((root (or project-root default-directory))
         (session (ecc-session--make
                   :id (or id (ecc--uuid))
                   :name (ecc-model-unique-name
                          (or name (file-name-nondirectory
                                    (directory-file-name root))))
                   :project-root (file-name-as-directory (expand-file-name root))
                   :cwd (or cwd (file-name-as-directory (expand-file-name root)))
                   :kind (or kind 'own)
                   :state 'starting
                   :options options
                   :nodes (make-hash-table :test #'equal)
                   :pending-controls (make-hash-table :test #'equal)
                   :files (make-hash-table :test #'equal)
                   :tasks (make-hash-table :test #'equal)
                   :total-cost 0
                   :context-tokens 0
                   :node-counter 0
                   :turn-counter 0)))
    (puthash (ecc-session-id session) session ecc--sessions)
    (ecc-model-touch session)
    session))

(defun ecc-model-set-session-id (session id)
  "Move SESSION to ID, which the CLI reported in system/init.
Resuming with --fork-session hands back an id we did not choose."
  (unless (equal (ecc-session-id session) id)
    (remhash (ecc-session-id session) ecc--sessions)
    (setq ecc--session-order (delete (ecc-session-id session) ecc--session-order))
    (setf (ecc-session-id session) id)
    (puthash id session ecc--sessions)
    (ecc-model-touch session)))

(defun ecc-model-remove-session (session)
  "Forget SESSION."
  (remhash (ecc-session-id session) ecc--sessions)
  (setq ecc--session-order (delete (ecc-session-id session) ecc--session-order)))

(defun ecc-model-option (session key default)
  "Return the launch option KEY of SESSION, or DEFAULT when it has none."
  (let ((options (ecc-session-options session)))
    (if (plist-member options key)
        (plist-get options key)
      default)))

(defun ecc-model-set-state (session state)
  "Set the state of SESSION to STATE and announce the change."
  (let ((old (ecc-session-state session)))
    (unless (eq old state)
      (setf (ecc-session-state session) state)
      (run-hook-with-args 'ecc-session-state-changed-hook session old))))

;;;; Turns

(defun ecc-model-begin-turn (session prompt)
  "Start a turn in SESSION for PROMPT and return it.
The CLI does not announce the start of a turn, so Emacs decides it
when the prompt goes out (plan section 4.1)."
  (let ((turn (make-ecc-turn
               :id (format "turn-%d" (cl-incf (ecc-session-turn-counter session)))
               :start-time (current-time)
               :prompt prompt)))
    (setf (ecc-session-turns session)
          (nconc (ecc-session-turns session) (list turn)))
    (setf (ecc-session-current-turn session) turn)
    (ecc-model-set-state session 'running)
    (run-hook-with-args 'ecc-turn-started-hook session turn)
    turn))

(defun ecc-model-ensure-turn (session)
  "Return the current turn of SESSION, starting an implicit one if needed.
Output can arrive without Emacs having sent anything, for instance
after a resume, and none of it may be dropped (FR-OUT-1)."
  (or (ecc-session-current-turn session)
      (ecc-model-begin-turn session nil)))

(defun ecc-model-finish-turn (session result)
  "Close the current turn of SESSION with the RESULT message."
  (let ((turn (ecc-session-current-turn session)))
    (when turn
      (setf (ecc-turn-end-time turn) (current-time)
            (ecc-turn-result turn) result
            (ecc-turn-cost turn) (alist-get 'total_cost_usd result))
      (setf (ecc-session-current-turn session) nil)
      (setf (ecc-session-auto-approve-turn session) nil)
      (setf (ecc-session-last-result-time session) (current-time))
      (cl-incf (ecc-session-total-cost session)
               (or (alist-get 'total_cost_usd result) 0))
      (run-hook-with-args 'ecc-turn-finished-hook session turn))
    turn))

(defun ecc-model-turn-duration (turn)
  "Return the duration of TURN in seconds, as the CLI reported it.
Falls back to the wall clock when there is no result yet."
  (let ((ms (alist-get 'duration_ms (ecc-turn-result turn))))
    (cond (ms (/ ms 1000.0))
          ((and (ecc-turn-start-time turn) (ecc-turn-end-time turn))
           (float-time (time-subtract (ecc-turn-end-time turn)
                                      (ecc-turn-start-time turn))))
          (t nil))))

;;;; Nodes

(defun ecc-model-next-node-id (session)
  "Return a fresh node id for SESSION."
  (format "node-%d" (cl-incf (ecc-session-node-counter session))))

(defun ecc-model-node (session id)
  "Return the node of SESSION registered under ID, or nil."
  (and id (gethash id (ecc-session-nodes session))))

(defun ecc-model-node-children (parent)
  "Return the children of PARENT, which is a node or a turn."
  (if (ecc-turn-p parent) (ecc-turn-children parent) (ecc-node-children parent)))

(defun ecc-model-append-child (parent node)
  "Append NODE to the children of PARENT, a node or a turn."
  (setf (ecc-node-parent node) parent)
  (if (ecc-turn-p parent)
      (setf (ecc-turn-children parent)
            (nconc (ecc-turn-children parent) (list node)))
    (setf (ecc-node-children parent)
          (nconc (ecc-node-children parent) (list node)))))

(cl-defun ecc-model-add-node (session &key id type parent data status)
  "Add a node of TYPE to PARENT in SESSION and return it.
ID defaults to a generated one, PARENT to the current turn.  The
node is registered so that a later message can find it by ID."
  (let* ((parent (or parent (ecc-model-ensure-turn session)))
         (node (make-ecc-node :id (or id (ecc-model-next-node-id session))
                              :type type
                              :data data
                              :status status)))
    (ecc-model-append-child parent node)
    (puthash (ecc-node-id node) node (ecc-session-nodes session))
    (run-hook-with-args 'ecc-node-added-hook session node)
    node))

(defun ecc-model-node-changed (session node)
  "Announce that NODE of SESSION changed."
  (run-hook-with-args 'ecc-node-updated-hook session node))

(defun ecc-model-node-get (node key)
  "Return the value of KEY in the data of NODE."
  (alist-get key (ecc-node-data node)))

(defun ecc-model-node-put (node key value)
  "Set KEY to VALUE in the data of NODE."
  (setf (alist-get key (ecc-node-data node)) value))

(defun ecc-model-turn-of (node)
  "Return the turn NODE belongs to, or nil."
  (let ((parent (ecc-node-parent node)))
    (while (and parent (not (ecc-turn-p parent)))
      (setq parent (ecc-node-parent parent)))
    parent))

(defun ecc-model-step-for-tool (session turn)
  "Return the step of TURN of SESSION a new tool call belongs to.
A run of tool calls shares a step; assistant text or thinking ends the
run, because it becomes the last child of the turn instead (FR-OUT-2)."
  (let ((last (car (last (ecc-turn-children turn)))))
    (if (and last (eq (ecc-node-type last) 'step))
        last
      (ecc-model-add-node session :type 'step :parent turn :status 'running))))

(defun ecc-model-tool-counts (step)
  "Return an alist of tool name to call count for STEP, in first-seen order."
  (let (counts)
    (dolist (child (ecc-node-children step))
      (let ((name (or (ecc-model-node-get child 'name) "?")))
        (if (assoc name counts)
            (cl-incf (cdr (assoc name counts)))
          (setq counts (nconc counts (list (cons name 1)))))))
    counts))

;;;; Files and tasks (FR-OUT-12, FR-OUT-13)

(defun ecc-model-note-file (session path kind)
  "Record that Claude did KIND to PATH in SESSION.
KIND is one of `read', `edit' or `write'."
  (when (and path (stringp path))
    (let ((entry (or (gethash path (ecc-session-files session))
                     (puthash path (make-ecc-file-entry :path path :reads 0
                                                        :edits 0 :writes 0)
                              (ecc-session-files session)))))
      (pcase kind
        ('read (cl-incf (ecc-file-entry-reads entry)))
        ('edit (cl-incf (ecc-file-entry-edits entry)))
        ('write (cl-incf (ecc-file-entry-writes entry))))
      entry)))

(defun ecc-model-note-task (session id subject status)
  "Record the task ID of SESSION with SUBJECT and STATUS."
  (when id
    (let ((task (or (gethash id (ecc-session-tasks session))
                    (puthash id (make-ecc-task :id id) (ecc-session-tasks session)))))
      (when subject (setf (ecc-task-subject task) subject))
      (when status (setf (ecc-task-status task) status))
      task)))

;;;; Requests waiting for an answer (plan section 3.4)

(defun ecc-model-add-request (session request)
  "Add REQUEST to the pending queue of SESSION (FR-PERM-6)."
  (setf (ecc-session-pending session)
        (nconc (ecc-session-pending session) (list request)))
  (ecc-model-set-state session
                       (pcase (ecc-request-kind request)
                         ('question 'waiting-question)
                         ('plan 'waiting-plan)
                         (_ 'waiting-permission)))
  (run-hook-with-args 'ecc-request-added-hook session request)
  request)

(defun ecc-model-request (session request-id)
  "Return the pending request of SESSION with REQUEST-ID, or nil."
  (seq-find (lambda (r) (equal (ecc-request-request-id r) request-id))
            (ecc-session-pending session)))

(defun ecc-model-resolve-request (session request status)
  "Take REQUEST out of the pending queue of SESSION, marking it STATUS."
  (setf (ecc-session-pending session)
        (delq request (ecc-session-pending session)))
  (when-let* ((node (ecc-request-node request)))
    (setf (ecc-node-status node) status)
    (ecc-model-node-changed session node))
  (unless (ecc-session-pending session)
    (ecc-model-set-state session
                         (if (ecc-session-current-turn session) 'running 'idle)))
  (run-hook-with-args 'ecc-request-resolved-hook session request)
  request)

(defun ecc-model-pending-all ()
  "Return the pending requests of every session, oldest first."
  (sort (apply #'append (mapcar #'ecc-session-pending (ecc-model-sessions)))
        (lambda (a b) (time-less-p (ecc-request-created-at a)
                                   (ecc-request-created-at b)))))

;;;; Usage (FR-HINT-3 groundwork)

(defun ecc-model-update-usage (session usage)
  "Store USAGE on SESSION and recompute the context size."
  (when usage
    (setf (ecc-session-usage session) usage)
    (setf (ecc-session-context-tokens session)
          (+ (or (alist-get 'input_tokens usage) 0)
             (or (alist-get 'cache_read_input_tokens usage) 0)
             (or (alist-get 'cache_creation_input_tokens usage) 0)))
    (run-hook-with-args 'ecc-usage-hook session)))

;;;; The input queue (FR-INP-6)

(defun ecc-model-queue-input (session text)
  "Append TEXT to the queue of prompts of SESSION and return its position."
  (setf (ecc-session-input-queue session)
        (nconc (ecc-session-input-queue session) (list text)))
  (length (ecc-session-input-queue session)))

(defun ecc-model-pop-input (session)
  "Remove and return the next queued prompt of SESSION, or nil."
  (let ((queue (ecc-session-input-queue session)))
    (when queue
      (setf (ecc-session-input-queue session) (cdr queue))
      (car queue))))

(provide 'ecc-model)

;;; ecc-model.el ends here
