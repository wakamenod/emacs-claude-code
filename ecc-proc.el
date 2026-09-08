;;; ecc-proc.el --- CLI process handling for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Builds the command line, starts the CLI, splits its output into lines
;; and sends JSON back.  Sections 2.1, 2.2, 2.4 and 2.5 of
;; IMPLEMENTATION_PLAN.md.
;;
;; Together with `ecc-protocol' this is the only place that touches the
;; wire format.  Parsed messages leave through
;; `ecc-proc-message-function', which `ecc-dispatch' sets; this file never
;; calls upwards by name (plan section 1.3).

;;; Code:

(require 'cl-lib)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)

(defcustom ecc-control-timeout 30
  "Seconds to wait for the answer to a control request before warning."
  :type 'number
  :group 'ecc)

(defcustom ecc-stop-grace 2.0
  "Seconds the CLI is given to stop by itself before it is killed.
A terminated CLI writes its last lines and takes itself out of the
session registry other Claude Code processes read, which a killed one
cannot; it normally takes a fraction of a second.  Zero kills at once."
  :type 'number
  :group 'ecc)

(defvar ecc-proc-message-function #'ignore
  "Function called with a session and every parsed message.
`ecc-dispatch' installs itself here when it is loaded.")

;;;; Buffers

(defun ecc-proc-stream-buffer (session)
  "Return the line buffer of SESSION, creating it if needed."
  (let ((buffer (ecc-session-stream-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (format " *ecc-stream: %s*" (ecc-session-name session))))
      (with-current-buffer buffer
        (buffer-disable-undo)
        (set-buffer-multibyte t))
      (setf (ecc-session-stream-buffer session) buffer))
    buffer))

(defun ecc-proc-stderr-buffer (session)
  "Return the standard error buffer of SESSION, creating it if needed."
  (get-buffer-create (format "*ecc-stderr: %s*" (ecc-session-name session))))

;;;; The command line (plan section 2.1)

(defun ecc-proc--model (session)
  "Return the model SESSION should be started with, or nil for none.

Only the option of the session is asked, and there is no setting that
answers for every session (2026-09-08, `docs/decisions.md'): the model
of a session belongs to the Claude Code settings, which the CLI reads
on its own.  The CLI also has no record of what a session was started
with -- resuming without --model picks up the model of the last real
assistant message of the recording, and passing --model overrides that
for good (verified on 2026-09-06, `docs/verified.md'), which would undo
every `/model' made since, in the terminal of a hand-off above all
\(FR-TUI-4)."
  (ecc-model-option session :model nil))

(defun ecc-proc-build-command (session &optional resume fork)
  "Return the command list that starts the CLI for SESSION.
With RESUME non-nil the session id is passed to --resume instead of
--session-id, and FORK adds --fork-session.

--model is only passed when this session was given one of its own; a
new session otherwise takes the model of the Claude Code settings, and
a resumed one the model its recording ends on (see `ecc-proc--model')."
  (let* ((opt (lambda (key default) (ecc-model-option session key default)))
         (command
          (append
           (list ecc-executable "-p"
                 "--input-format" "stream-json"
                 "--output-format" "stream-json"
                 "--verbose"
                 "--permission-prompt-tool" "stdio")
           (if resume
               ;; A fork normally resumes the session itself; `:resume-from'
               ;; lets a new session branch off another one instead, which
               ;; is how the inline questions of FR-INLINE-1 get a
               ;; conversation of their own without taking over the one
               ;; they branched from.
               (append (list "--resume" (or (ecc-model-option session
                                                              :resume-from nil)
                                            (ecc-session-id session)))
                       (and fork (list "--fork-session")))
             (list "--session-id" (ecc-session-id session)))
           (and (funcall opt :streaming ecc-streaming-enabled)
                (list "--include-partial-messages"))
           (and (funcall opt :subagent-text ecc-subagent-text-enabled)
                (list "--forward-subagent-text"))
           (and (funcall opt :prompt-suggestions ecc-prompt-suggestions-enabled)
                (list "--prompt-suggestions"))
           (and (funcall opt :hook-events ecc-hook-events-enabled)
                (list "--include-hook-events"))
           (when-let* ((model (ecc-proc--model session)))
             (list "--model" model))
           (when-let* ((mode (funcall opt :permission-mode ecc-permission-mode)))
             (list "--permission-mode" mode))
           (when-let* ((effort (funcall opt :effort ecc-effort)))
             (list "--effort" effort))
           (when-let* ((autocompact (funcall opt :autocompact ecc-autocompact)))
             (list "--autocompact" (format "%s" autocompact)))
           (when-let* ((tools (funcall opt :allowed-tools ecc-allowed-tools)))
             (cons "--allowedTools" tools))
           (when-let* ((tools (funcall opt :disallowed-tools ecc-disallowed-tools)))
             (cons "--disallowedTools" tools))
           (when-let* ((config (and ecc-mcp-config-function
                                    (funcall ecc-mcp-config-function session))))
             (list "--mcp-config" config))
           (when-let* ((settings (ecc-protocol-settings-json
                                 (funcall opt :disabled-plugins
                                          ecc-disabled-plugins))))
             (list "--settings" settings))
           (and (funcall opt :safe-mode ecc-safe-mode) (list "--safe-mode"))
           (funcall opt :extra-args ecc-extra-args))))
    (if ecc-command-wrapper-function
        (funcall ecc-command-wrapper-function command
                 (ecc-session-project-root session))
      command)))

;;;; Starting and stopping (plan sections 2.1 and 2.5)

(defun ecc-proc-session (process)
  "Return the session PROCESS belongs to, or nil."
  (and (processp process) (ecc-model-session (process-get process 'ecc-session-id))))

(defun ecc-proc-start (session &optional resume fork)
  "Start the CLI for SESSION and return the process.
RESUME and FORK are passed to `ecc-proc-build-command'."
  (when (process-live-p (ecc-session-process session))
    (error "Session %s is already running" (ecc-session-name session)))
  (let* ((command (ecc-proc-build-command session resume fork))
         (default-directory (or (ecc-session-project-root session) default-directory))
         process)
    (ecc-log (ecc-session-name session) "start: %s"
             (mapconcat #'shell-quote-argument command " "))
    (with-current-buffer (ecc-proc-stream-buffer session)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (setq process (make-process
                   :name (format "ecc: %s" (ecc-session-name session))
                   :command command
                   :connection-type 'pipe
                   :coding 'utf-8-unix
                   :noquery t
                   :buffer (ecc-proc-stream-buffer session)
                   :stderr (ecc-proc-stderr-buffer session)
                   :filter #'ecc-proc--filter
                   :sentinel #'ecc-proc--sentinel))
    (setf (alist-get 'stop-requested (ecc-session-progress session)) nil)
    (process-put process 'ecc-session-id (ecc-session-id session))
    (setf (ecc-session-process session) process)
    ;; The CLI is up as soon as `make-process' returned: it is waiting
    ;; for a prompt, which is what idle means (FR-UI-1).  `starting' is
    ;; left for a session whose process never came up, because
    ;; system/init only arrives with the first turn (docs/verified.md)
    ;; and a session that waited for it would spin for ever.
    (ecc-model-set-state session 'idle)
    ;; FR-SES-8: ask for the slash commands as soon as the CLI is up.
    (ecc-proc-control session "initialize" nil 'hooks nil)
    process))

(defun ecc-proc-stop (session)
  "Stop the CLI of SESSION if it is running, and wait for it to go.
It is asked to stop first and only killed when it will not: a CLI that
stops by itself removes its entry from the registry other Claude Code
processes read, so that nothing thinks the session is still running
\(FR-TUI-5).  The stop is noted, so that the sentinel can tell an exit
the user asked for from one the CLI decided on (FR-SES-7)."
  (let ((process (ecc-session-process session)))
    (setf (alist-get 'stop-requested (ecc-session-progress session)) t)
    (when (process-live-p process)
      (if (<= ecc-stop-grace 0)
          (delete-process process)
        (signal-process process 'TERM)
        (let ((deadline (+ (float-time) ecc-stop-grace)))
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.05)))
        (when (process-live-p process)
          (ecc-log (ecc-session-name session)
                   "did not stop in %ss; killing" ecc-stop-grace)
          (delete-process process))))
    ;; The process is gone from Emacs, but the system may take another
    ;; moment to forget it, and the registry is read by process id.
    (when (and process (not (process-live-p process)))
      (let ((pid (process-id process))
            (deadline (+ (float-time) 1.0)))
        (while (and pid (process-attributes pid) (< (float-time) deadline))
          (accept-process-output nil 0.02))))))

(defun ecc-proc-stopped-on-request-p (session)
  "Return non-nil when the CLI of SESSION was stopped from Emacs."
  (and (alist-get 'stop-requested (ecc-session-progress session)) t))

(defun ecc-proc--sentinel (process event)
  "Handle EVENT for PROCESS: close the session down cleanly."
  (let ((session (ecc-proc-session process)))
    (when (and session (not (process-live-p process)))
      (ecc-proc--handle-exit session (process-exit-status process) event))))

(defun ecc-proc--handle-exit (session status event)
  "Close SESSION down after its CLI exited with STATUS, described by EVENT."
  (ecc-log (ecc-session-name session) "exited: %s (code %s)"
           (string-trim (or event "")) status)
  (setf (ecc-session-process session) nil)
  (setf (alist-get 'exit-status (ecc-session-progress session)) status)
  (ecc-proc--close-pending session)
  ;; A turn the CLI was in the middle of will never get its result.
  ;; Left open, it would hold every later prompt in the queue, and a
  ;; resumed session would never speak again (FR-SES-7).
  (when-let* ((turn (ecc-model-abort-turn session)))
    (ecc-log (ecc-session-name session) "turn %s left open by the exit; closed"
             (ecc-turn-id turn)))
  (ecc-model-set-state session 'exited)
  (run-hook-with-args 'ecc-session-exited-hook session status))

(defun ecc-proc--close-pending (session)
  "Deny every unanswered request of SESSION (NFR-4).
The process is gone, so nothing can be sent; the requests are closed
locally so that the queue does not keep stale entries."
  (ecc-model-abandon-requests session "the session ended before it was answered")
  (clrhash (ecc-session-pending-controls session)))

;;;; Receiving (plan section 2.2)

(defun ecc-proc--filter (process chunk)
  "Feed CHUNK of PROCESS output into the session line buffer."
  (when-let* ((session (ecc-proc-session process)))
    (ecc-proc-feed session chunk)))

(defun ecc-proc-feed (session chunk)
  "Append CHUNK to the line buffer of SESSION and handle each whole line.
A chunk can stop in the middle of a line, and one line can be several
megabytes, so the leftover is kept in a buffer rather than a string."
  (let (lines)
    (with-current-buffer (ecc-proc-stream-buffer session)
      (goto-char (point-max))
      (insert chunk)
      (goto-char (point-max))
      (when (search-backward "\n" nil t)
        (setq lines (split-string
                     (buffer-substring-no-properties (point-min) (point)) "\n"))
        (delete-region (point-min) (1+ (point)))))
    (dolist (line lines)
      (unless (string-empty-p line)
        (ecc-proc-handle-line session line)))
    lines))

(defun ecc-proc-handle-line (session line)
  "Parse LINE of SESSION and hand it to `ecc-proc-message-function'."
  (ecc-log-raw (ecc-session-name session) 'recv line)
  (funcall ecc-proc-message-function session (ecc-protocol-parse-line line)))

;;;; Sending (plan sections 2.3 and 2.4)

(defun ecc-proc-send-json (session object)
  "Serialize OBJECT and send it to the CLI of SESSION as one line."
  (let ((line (concat (ecc-protocol-serialize object) "\n"))
        (process (ecc-session-process session)))
    (unless (process-live-p process)
      (error "Session %s is not running" (ecc-session-name session)))
    (ecc-log-raw (ecc-session-name session) 'send (substring line 0 -1))
    (process-send-string process line)
    line))

(defun ecc-proc-control (session subtype callback &rest fields)
  "Send a control request of SUBTYPE with FIELDS to SESSION.
CALLBACK, when non-nil, is called with the session and the inner
response object once the CLI answers.  Returns the request id."
  (let ((request-id (ecc--uuid)))
    (puthash request-id (or callback #'ignore)
             (ecc-session-pending-controls session))
    (run-at-time ecc-control-timeout nil
                 (lambda ()
                   (when (gethash request-id (ecc-session-pending-controls session))
                     (remhash request-id (ecc-session-pending-controls session))
                     (ecc-log (ecc-session-name session)
                              "control request %s (%s) timed out"
                              request-id subtype))))
    (ecc-proc-send-json session (apply #'ecc-protocol-control-request
                                       request-id subtype fields))
    request-id))

(defun ecc-proc-take-control-callback (session request-id)
  "Return and forget the callback SESSION registered for REQUEST-ID."
  (let ((callback (gethash request-id (ecc-session-pending-controls session))))
    (remhash request-id (ecc-session-pending-controls session))
    callback))

(defconst ecc-proc--model-command-regexp
  "\\`[ \t\n]*/model[ \t]+\\([^ \t\n]+\\)[ \t\n]*\\'"
  "What a `/model' that names a model looks like.
A `/model' with nothing after it asks rather than tells, and is left
alone.")

(defun ecc-proc--note-model (session content)
  "Take note of the model a `/model' among CONTENT names for SESSION.
The CLI answers a `/model' with a local command of its own and says
nothing else about it: the new name turns up in the next real assistant
message and nowhere earlier, so the header line would go on naming the
old model until the session is next spoken to (FR-HINT-3).  What is
remembered here is the name as it was typed, `opus' rather than
`claude-opus-5', and the next answer replaces it with the full one."
  (when (and (stringp content)
             (string-match ecc-proc--model-command-regexp content))
    (setf (ecc-session-last-model session) (match-string 1 content))))

(defun ecc-proc-send-user (session content)
  "Send CONTENT to SESSION as a user message and start a turn.
CONTENT is a string or a vector of content blocks.  The message goes
out before the turn is opened: a turn opened for a message that never
went out would hold every later prompt in the queue.  Nothing can
arrive in between, since output is only read when Emacs waits for it."
  (prog1 (ecc-proc-send-json session (ecc-protocol-user-message content))
    (ecc-proc--note-model session content)
    (ecc-model-begin-turn session (if (stringp content) content ""))))

(defun ecc-proc-send-transient (session content)
  "Send CONTENT to SESSION without opening a turn (plan section 9, item 11)."
  (ecc-proc-send-json session (ecc-protocol-user-message content)))

(defun ecc-proc-send-prompt (session text)
  "Send TEXT to SESSION, or queue it while a turn is running (FR-INP-6).
Returns `sent' or the position in the queue."
  (if (ecc-session-current-turn session)
      (ecc-model-queue-input session text)
    (ecc-proc-send-user session text)
    'sent))

(defun ecc-proc-drain-queue (session)
  "Send the next queued prompt of SESSION, if there is one."
  (when-let* ((text (and (null (ecc-session-current-turn session))
                        (ecc-model-pop-input session))))
    (ecc-proc-send-user session text)
    text))

(defun ecc-proc-interrupt (session)
  "Interrupt the running turn of SESSION (FR-SES-5).
A question or a permission the CLI was waiting on is closed as soon as
it acknowledges the interrupt: it has stopped listening for the answer,
and the `result' that ends the turn may never come while it is blocked
on the request."
  (ecc-proc-control
   session "interrupt"
   (lambda (session _response)
     (when-let* ((abandoned (ecc-model-abandon-requests
                             session "the turn was interrupted")))
       (ecc-log (ecc-session-name session)
                "interrupt closed %d unanswered request(s)"
                (length abandoned))))))

(defun ecc-proc-set-permission-mode (session mode &optional on-error)
  "Ask SESSION to switch to permission MODE (FR-SES-6).
ON-ERROR, when given, is called with the session and what the CLI said
if it refuses.  It does refuse: \"auto\" is only for a model that
supports it, and \"bypassPermissions\" only where it is allowed."
  (ecc-proc-control
   session "set_permission_mode"
   (lambda (session response)
     (let ((refusal (alist-get 'error response))
           (mode (alist-get 'mode response)))
       (cond (refusal (when on-error
                        (funcall on-error session
                                 (if (stringp refusal) refusal
                                   "the CLI refused the permission mode"))))
             (mode
              (setf (ecc-session-permission-mode session) mode)
              (run-hook-with-args 'ecc-permission-mode-functions session mode)))))
   'mode mode))

(provide 'ecc-proc)

;;; ecc-proc.el ends here
