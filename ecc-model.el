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

(defvar ecc-files-updated-hook nil
  "Functions run with a session when its Files summary changed.")

(defvar ecc-tasks-updated-hook nil
  "Functions run with a session when its task list changed.")

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
  last-plan             ; text of the last plan reviewed (FR-PLAN-5)
  stream-blocks         ; hash: "PARENT:INDEX" -> node being streamed
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
  streaming     ; non-nil while stream events are still feeding the node
  streaming-text
  marker-start marker-end)              ; owned by the renderer

(cl-defstruct ecc-file-entry
  "What Claude did to one file during a session.
HUNKS is a list of (OLD . NEW) strings, oldest first, one per Edit or
Write; PATCHES holds the structuredPatch the CLI reported for each, in
the same order, and SNAPSHOT the content of the file as last seen."
  path reads edits writes hunks patches snapshot (added 0) (removed 0))

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
                   :stream-blocks (make-hash-table :test #'equal)
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

(defun ecc-model-step-for-tool (session parent)
  "Return the step under PARENT of SESSION a new tool call belongs to.
PARENT is a turn or an agent node.  A run of tool calls shares a step;
assistant text or thinking ends the run, because it becomes the last
child of PARENT instead (FR-OUT-2)."
  (let ((last (car (last (ecc-model-node-children parent)))))
    (if (and last (eq (ecc-node-type last) 'step))
        last
      (ecc-model-add-node session :type 'step :parent parent :status 'running))))

(defun ecc-model-running-tool (session)
  "Return the tool node of SESSION that is running right now, or nil.
The most recently started one wins when several are."
  (let (found)
    (maphash (lambda (_id node)
               (when (and (memq (ecc-node-type node) '(tool agent))
                          (eq (ecc-node-status node) 'running)
                          (or (null found)
                              (time-less-p (or (ecc-model-node-get found 'started) 0)
                                           (or (ecc-model-node-get node 'started) 0))))
                 (setq found node)))
             (ecc-session-nodes session))
    found))

;;;; Streaming (FR-OUT-4)

(defun ecc-model--stream-key (parent-id index)
  "Return the key of the streamed block INDEX under PARENT-ID."
  (format "%s:%s" (or parent-id "") index))

(defun ecc-model-open-stream (session parent-id index node)
  "Remember in SESSION that NODE receives block INDEX under PARENT-ID."
  (setf (ecc-node-streaming node) t)
  (unless (ecc-node-streaming-text node)
    (setf (ecc-node-streaming-text node) ""))
  (puthash (ecc-model--stream-key parent-id index) node
           (ecc-session-stream-blocks session))
  node)

(defun ecc-model-stream-node (session parent-id index)
  "Return the node of SESSION receiving block INDEX under PARENT-ID."
  (gethash (ecc-model--stream-key parent-id index)
           (ecc-session-stream-blocks session)))

(defun ecc-model-find-stream (session parent-id type &optional id)
  "Return the open streamed node of TYPE under PARENT-ID in SESSION.
With ID, only a node with that id qualifies.  The complete assistant
message that follows a streamed block uses this to find the node the
block was drawn into, so that nothing is drawn twice."
  (let ((prefix (ecc-model--stream-key parent-id ""))
        found found-index)
    (maphash (lambda (key node)
               (when (and (string-prefix-p prefix key)
                          (eq (ecc-node-type node) type)
                          (ecc-node-streaming node)
                          (or (null id) (equal (ecc-node-id node) id)))
                 ;; The lowest index is the block that started first.
                 (let ((index (string-to-number (substring key (length prefix)))))
                   (when (or (null found) (< index found-index))
                     (setq found node found-index index)))))
             (ecc-session-stream-blocks session))
    found))

(defun ecc-model-append-stream (session node text)
  "Append TEXT to the streamed text of NODE of SESSION.
Announces the delta through `ecc-stream-delta-hook' without marking the
node changed, so that the renderer can append rather than redraw."
  (when (and text (not (string-empty-p text)))
    (setf (ecc-node-streaming-text node)
          (concat (or (ecc-node-streaming-text node) "") text))
    (run-hook-with-args 'ecc-stream-delta-hook session node text))
  node)

(defun ecc-model-close-stream (session node)
  "Stop streaming into NODE of SESSION and forget its block."
  (setf (ecc-node-streaming node) nil)
  (let ((table (ecc-session-stream-blocks session))
        keys)
    (maphash (lambda (key value) (when (eq value node) (push key keys))) table)
    (dolist (key keys) (remhash key table)))
  node)

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
KIND is one of `read', `edit' or `write', or nil to only make sure the
entry exists.  Returns the entry, or nil when PATH is not a string."
  (when (and path (stringp path))
    (let ((entry (or (gethash path (ecc-session-files session))
                     (puthash path (make-ecc-file-entry :path path :reads 0
                                                        :edits 0 :writes 0)
                              (ecc-session-files session)))))
      (pcase kind
        ('read (cl-incf (ecc-file-entry-reads entry)))
        ('edit (cl-incf (ecc-file-entry-edits entry)))
        ('write (cl-incf (ecc-file-entry-writes entry))))
      (run-hook-with-args 'ecc-files-updated-hook session)
      entry)))

(defun ecc-model-note-hunk (session path old new &optional patch)
  "Record that Claude changed PATH of SESSION from OLD to NEW.
PATCH is the structuredPatch the CLI reported, when it did.  The line
counts of the Files section come from PATCH when there is one."
  (when-let* ((entry (ecc-model-note-file session path nil)))
    (setf (ecc-file-entry-hunks entry)
          (nconc (ecc-file-entry-hunks entry) (list (cons old new))))
    (setf (ecc-file-entry-patches entry)
          (nconc (ecc-file-entry-patches entry) (list patch)))
    (when (stringp new)
      (setf (ecc-file-entry-snapshot entry) new))
    entry))

(defun ecc-model-note-snapshot (session path content)
  "Remember CONTENT as what PATH of SESSION looked like when last read."
  (when-let* ((entry (and (stringp content) (ecc-model-note-file session path nil))))
    (setf (ecc-file-entry-snapshot entry) content)
    entry))

(defun ecc-model-files (session)
  "Return the file entries of SESSION that saw an operation, sorted by path.
An entry that only holds a snapshot, because a call was denied or is
still waiting, is left out."
  (sort (seq-filter (lambda (entry)
                      (> (+ (ecc-file-entry-reads entry)
                            (ecc-file-entry-edits entry)
                            (ecc-file-entry-writes entry))
                         0))
                    (hash-table-values (ecc-session-files session)))
        (lambda (a b) (string< (ecc-file-entry-path a) (ecc-file-entry-path b)))))

(defun ecc-model-note-task (session id subject status)
  "Record the task ID of SESSION with SUBJECT and STATUS.
Returns the task, or nil when ID is nil."
  (when id
    (let* ((id (format "%s" id))
           (task (or (gethash id (ecc-session-tasks session))
                     (puthash id (make-ecc-task :id id :status "pending")
                              (ecc-session-tasks session)))))
      (when subject (setf (ecc-task-subject task) subject))
      (when status (setf (ecc-task-status task) status))
      (run-hook-with-args 'ecc-tasks-updated-hook session)
      task)))

(defun ecc-model-replace-tasks (session tasks)
  "Replace the task list of SESSION by TASKS, a list of `ecc-task'."
  (clrhash (ecc-session-tasks session))
  (dolist (task tasks)
    (puthash (ecc-task-id task) task (ecc-session-tasks session)))
  (run-hook-with-args 'ecc-tasks-updated-hook session))

(defun ecc-model-tasks (session)
  "Return the tasks of SESSION, in id order."
  (sort (hash-table-values (ecc-session-tasks session))
        (lambda (a b)
          (let ((x (string-to-number (ecc-task-id a)))
                (y (string-to-number (ecc-task-id b))))
            (if (= x y)
                (string< (ecc-task-id a) (ecc-task-id b))
              (< x y))))))

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

(defun ecc-model-pending-all (&optional project-root)
  "Return the pending requests of every session, oldest first.
With PROJECT-ROOT, only the sessions of that project are looked at."
  ;; `append' shares the last list it is given and `sort' is destructive,
  ;; so the queue of a session must never be sorted in place.
  (seq-sort (lambda (a b) (time-less-p (ecc-request-created-at a)
                                       (ecc-request-created-at b)))
            (apply #'append
                   (mapcar (lambda (session) (copy-sequence (ecc-session-pending session)))
                           (if project-root
                               (seq-filter (lambda (session)
                                             (equal (ecc-session-project-root session)
                                                    (file-name-as-directory
                                                     (expand-file-name project-root))))
                                           (ecc-model-sessions))
                             (ecc-model-sessions))))))

(defun ecc-model-request-age (request)
  "Return how many seconds ago REQUEST arrived."
  (float-time (time-subtract (current-time) (ecc-request-created-at request))))

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
