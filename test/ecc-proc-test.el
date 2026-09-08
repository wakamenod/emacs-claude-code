;;; ecc-proc-test.el --- Tests for ecc-proc  -*- lexical-binding: t; -*-

;;; Commentary:

;; The command line of section 2.1, the line buffering of section 2.2 and
;; the control request bookkeeping of section 2.4.  No test here starts a
;; process; the live tests do that (NFR-6).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-proc)
(require 'ecc-dispatch)

(defun ecc-proc-test--flag-value (command flag)
  "Return the argument that follows FLAG in COMMAND, or nil."
  (cadr (member flag command)))

(ert-deftest ecc-proc-test-command-essentials ()
  "The flags the protocol does not work without are always there."
  (ecc-test-with-fake-session session
    (let ((command (ecc-proc-build-command session)))
      (should (equal (car command) ecc-executable))
      (should (member "-p" command))
      ;; Without --verbose no stream-json comes out at all (9.2).
      (should (member "--verbose" command))
      (should (equal (ecc-proc-test--flag-value command "--input-format")
                     "stream-json"))
      (should (equal (ecc-proc-test--flag-value command "--output-format")
                     "stream-json"))
      (should (equal (ecc-proc-test--flag-value command "--permission-prompt-tool")
                     "stdio"))
      ;; The session id is ours, so that resume can find it (FR-SES-1).
      (should (equal (ecc-proc-test--flag-value command "--session-id")
                     (ecc-session-id session)))
      (should-not (member "--resume" command)))))

(ert-deftest ecc-proc-test-command-resume ()
  "Resuming replaces --session-id and can fork (FR-SES-4)."
  (ecc-test-with-fake-session session
    (let ((command (ecc-proc-build-command session t t)))
      (should (equal (ecc-proc-test--flag-value command "--resume")
                     (ecc-session-id session)))
      (should (member "--fork-session" command))
      (should-not (member "--session-id" command)))))

(ert-deftest ecc-proc-test-command-leaves-the-model-to-the-cli ()
  "No setting names a model for every session (2026-09-08).
A new session takes the model of the Claude Code settings and a resumed
one the model of the last real assistant message of its recording
\(2026-09-06, `docs/verified.md'), so --model is left out either way."
  (ecc-test-with-fake-session session
    (should-not (member "--model" (ecc-proc-build-command session)))
    (should-not (member "--model" (ecc-proc-build-command session t)))
    ;; A model of the session's own is meant, and is passed either way:
    ;; this is how the inline sessions of FR-INLINE-1 keep a model that
    ;; is not the one of the session they branch from.
    (setf (ecc-session-options session) '(:model "opus"))
    (should (equal (ecc-proc-test--flag-value
                    (ecc-proc-build-command session) "--model")
                   "opus"))
    (should (equal (ecc-proc-test--flag-value
                    (ecc-proc-build-command session t) "--model")
                   "opus"))))

(ert-deftest ecc-proc-test-command-options ()
  "Session options win over the defcustoms (FR-SES-2)."
  (ecc-test-with-fake-session session
    (let ((ecc-streaming-enabled t))
      (setf (ecc-session-options session)
            (list :model "haiku" :streaming nil
                  :permission-mode "plan" :allowed-tools '("Read" "Bash(git *)")
                  :disabled-plugins '("emacs-bridge@emacs-gravity-marketplace")
                  :extra-args '("--no-session-persistence")))
      (let ((command (ecc-proc-build-command session)))
        (should (equal (ecc-proc-test--flag-value command "--model") "haiku"))
        (should (equal (ecc-proc-test--flag-value command "--permission-mode") "plan"))
        (should-not (member "--include-partial-messages" command))
        ;; A repeatable flag takes each pattern as its own argument.
        (should (equal (seq-take (member "--allowedTools" command) 3)
                       '("--allowedTools" "Read" "Bash(git *)")))
        ;; Only the named plugin is switched off; --safe-mode would take
        ;; MCP servers, skills and commands with it (docs/verified.md).
        (should (equal (ecc-proc-test--flag-value command "--settings")
                       (concat "{\"enabledPlugins\":"
                               "{\"emacs-bridge@emacs-gravity-marketplace\":false}}")))
        (should-not (member "--safe-mode" command))
        (should (member "--no-session-persistence" command))))))

(ert-deftest ecc-proc-test-command-wrapper ()
  "A wrapper function gets the last word on the command line (FR-SES-9)."
  (ecc-test-with-fake-session session
    (let ((ecc-command-wrapper-function
           (lambda (command root) (append (list "mise" "exec" root "--") command))))
      (should (equal (seq-take (ecc-proc-build-command session) 3)
                     (list "mise" "exec" (ecc-session-project-root session)))))))

;;;; Line buffering (plan section 2.2 and 9, item 3)

(ert-deftest ecc-proc-test-lines-split-on-any-boundary ()
  "A chunk that stops in the middle of a line loses nothing."
  (ecc-test-with-fake-session session
    (let* ((seen nil)
           (ecc-proc-message-function (lambda (_session message) (push message seen)))
           (lines (ecc-test-fixture-lines "tool-use-write"))
           (text (concat (string-join lines "\n") "\n")))
      ;; Feed the whole recording in small, deliberately uneven pieces.
      (let ((position 0)
            (sizes '(1 7 3 64 2 1000 13)))
        (while (< position (length text))
          (let* ((size (nth (mod position (length sizes)) sizes))
                 (end (min (length text) (+ position size))))
            (ecc-proc-feed session (substring text position end))
            (setq position end))))
      (setq seen (nreverse seen))
      (should (= (length seen) (length lines)))
      (should (equal (mapcar (lambda (m) (alist-get 'type m)) seen)
                     (mapcar (lambda (line) (alist-get 'type (ecc--json-read line)))
                             lines)))
      ;; Nothing is left over once the last newline has arrived.
      (should (= 0 (buffer-size (ecc-proc-stream-buffer session)))))))

(ert-deftest ecc-proc-test-partial-line-waits ()
  "A line without its newline yet is held back, not handed on."
  (ecc-test-with-fake-session session
    (let* ((seen nil)
           (ecc-proc-message-function (lambda (_session message) (push message seen))))
      (ecc-proc-feed session "{\"type\":\"system\",")
      (should-not seen)
      (ecc-proc-feed session "\"subtype\":\"init\"}\n")
      (should (= (length seen) 1))
      (should (equal (alist-get 'subtype (car seen)) "init")))))

(ert-deftest ecc-proc-test-very-long-line ()
  "A multi-megabyte line arrives in one piece (plan 9, item 3)."
  (ecc-test-with-fake-session session
    (let* ((seen nil)
           (ecc-proc-message-function (lambda (_session message) (push message seen)))
           (content (make-string (* 5 1024 1024) ?x))
           (line (concat "{\"type\":\"assistant\",\"text\":\"" content "\"}\n")))
      (dotimes (i 64)
        (let ((size (/ (length line) 64)))
          (ecc-proc-feed session (substring line (* i size)
                                            (if (= i 63) nil (* (1+ i) size))))))
      (should (= (length seen) 1))
      (should (= (length (alist-get 'text (car seen))) (length content))))))

(ert-deftest ecc-proc-test-lines-are-logged ()
  "Every raw line reaches the log buffer (NFR-8)."
  (ecc-test-with-fake-session session
    (ecc-proc-feed session "{\"type\":\"system\",\"subtype\":\"init\"}\n")
    (with-current-buffer (ecc--log-buffer (ecc-session-name session))
      (should (string-search "<< {\"type\":\"system\"" (buffer-string))))))

;;;; Control requests (plan section 2.4)

(ert-deftest ecc-proc-test-control-round-trip ()
  "A control request remembers its callback until the answer arrives."
  (ecc-test-with-fake-session session
    (let* ((answered nil)
           (request-id (ecc-proc-control session "initialize"
                                         (lambda (_session response)
                                           (setq answered response))
                                         'hooks nil)))
      (should (= 1 (hash-table-count (ecc-session-pending-controls session))))
      (should (equal (ecc-protocol-serialize (car (ecc-test-sent-messages)))
                     (ecc-protocol-serialize (ecc-protocol-initialize request-id))))
      (ecc-dispatch session
                    (ecc-protocol-parse-line
                     (ecc-protocol-serialize
                      (ecc-protocol-control-response
                       request-id '((commands . [((name . "context"))]))))))
      (should answered)
      (should (= 0 (hash-table-count (ecc-session-pending-controls session))))
      ;; The commands of the answer are what completion offers (FR-INP-3).
      (should (equal (alist-get 'name (aref (ecc-session-commands session) 0))
                     "context")))))

(ert-deftest ecc-proc-test-pending-are-closed-on-exit ()
  "Nothing stays unanswered once the process is gone (NFR-4)."
  (ecc-test-with-fake-session session
    (let* ((node (ecc-model-add-node session :type 'permission :status 'pending))
           (request (make-ecc-request :request-id "r1" :session session
                                      :kind 'permission :tool-name "Write"
                                      :created-at (current-time) :node node)))
      (ecc-model-add-request session request)
      (ecc-proc-control session "interrupt" nil)
      (ecc-proc--close-pending session)
      (should-not (ecc-session-pending session))
      (should (eq (ecc-node-status node) 'denied))
      (should (= 0 (hash-table-count (ecc-session-pending-controls session)))))))

(ert-deftest ecc-proc-test-interrupt-closes-a-waiting-question ()
  "An interrupt closes the question it was asked in the middle of (FR-SES-5).
The CLI has stopped listening for the answer, so a request left pending
would blink for an answer that can no longer go anywhere."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "質問して")
    (let* ((request (ecc-test-add-request session "AskUserQuestion"
                                          '((questions . []))))
           (node (ecc-request-node request))
           (request-id (ecc-proc-interrupt session)))
      (should (eq (ecc-session-state session) 'waiting-question))
      (ecc-dispatch session
                    (ecc-protocol-parse-line
                     (ecc-protocol-serialize
                      (ecc-protocol-control-response
                       request-id '((still_queued . []))))))
      (should-not (ecc-session-pending session))
      (should (eq (ecc-node-status node) 'denied))
      (should (ecc-model-node-get node 'outcome-message))
      ;; Nothing was answered: only the interrupt itself went out.
      (should (= 1 (length (ecc-test-sent-messages)))))))

(ert-deftest ecc-proc-test-send-needs-a-process ()
  "Sending to a session that is not running is an error, not a silent drop.
This one uses the real sender, so it builds its session by hand."
  (let* ((ecc--sessions (make-hash-table :test #'equal))
         (ecc--session-order nil)
         (session (ecc-model-create-session
                   :name "no-process" :project-root temporary-file-directory)))
    (unwind-protect
        (should-error (ecc-proc-send-json session '((type . "user"))))
      (ecc-test-cleanup-session session))))

(ert-deftest ecc-proc-test-send-user-opens-no-turn-without-a-process ()
  "A prompt that cannot go out opens no turn.
Otherwise every later prompt would queue behind a turn that never
finishes."
  (let* ((ecc--sessions (make-hash-table :test #'equal))
         (ecc--session-order nil)
         (session (ecc-model-create-session
                   :name "no-process" :project-root temporary-file-directory)))
    (unwind-protect
        (progn
          (should-error (ecc-proc-send-prompt session "hello"))
          (should-not (ecc-session-current-turn session))
          (should-not (ecc-session-input-queue session))
          (should-not (eq (ecc-session-state session) 'running)))
      (ecc-test-cleanup-session session))))

(ert-deftest ecc-proc-test-a-slash-model-is-noted-as-it-is-sent ()
  "A `/model' changes what the session says it runs at once (FR-HINT-3).
The CLI names the new model in the next real assistant message and
nowhere earlier, so without this the header line goes on naming the old
one until the session is next spoken to."
  (ecc-test-with-fake-session session
    (ecc-proc-send-prompt session "/model opus")
    (should (equal (ecc-session-last-model session) "opus"))
    ;; The send above opened a turn, so this one queues behind it: it is
    ;; noted when it goes out, not when it is put in the queue.
    (ecc-proc-send-prompt session "/model haiku")
    (should (equal (ecc-session-last-model session) "opus"))
    (ecc-model-abort-turn session)
    (ecc-proc-drain-queue session)
    (should (equal (ecc-session-last-model session) "haiku"))
    ;; A `/model' with nothing after it asks rather than tells, and an
    ;; ordinary prompt says nothing about the model at all.
    (ecc-model-abort-turn session)
    (ecc-proc-send-prompt session "/model")
    (ecc-model-abort-turn session)
    (ecc-proc-send-prompt session "which model are you?")
    (should (equal (ecc-session-last-model session) "haiku"))))

(ert-deftest ecc-proc-test-exit-closes-the-open-turn ()
  "A CLI that dies in the middle of a turn leaves no turn open (FR-SES-7).
The next prompt after a resume must be sent, not queued."
  (ecc-test-with-fake-session session
    (let ((turn (ecc-model-begin-turn session "work")))
      (setf (ecc-session-auto-approve-turn session) t)
      (ecc-proc--handle-exit session 137 "killed")
      (should (eq (ecc-session-state session) 'exited))
      (should-not (ecc-session-current-turn session))
      (should (ecc-turn-end-time turn))
      (should-not (ecc-session-auto-approve-turn session))
      ;; The turn stays in the transcript; it just is not open any more.
      (should (memq turn (ecc-session-turns session))))))


;;;; Remote Control (docs/decisions.md, 2026-09-08)

(defun ecc-proc-test--initialize (session response)
  "Answer the initialize request of SESSION with RESPONSE.
The callback is the one `ecc-proc-start' registers; the process it
would need is not, so the request is sent by hand."
  (let ((request-id (ecc-proc-control session "initialize"
                                      #'ecc-proc--on-initialize 'hooks nil)))
    (ecc-dispatch session
                  (ecc-protocol-parse-line
                   (ecc-protocol-serialize
                    (ecc-protocol-control-response request-id response))))))

(defun ecc-proc-test--answer-last (session response)
  "Answer the control request SESSION sent last with RESPONSE."
  (let ((request-id (car (hash-table-keys (ecc-session-pending-controls session)))))
    (ecc-dispatch session
                  (ecc-protocol-parse-line
                   (ecc-protocol-serialize
                    (ecc-protocol-control-response request-id response))))))

(defun ecc-proc-test--remote-control-requests ()
  "Return the remote_control requests the session under test sent."
  (seq-filter (lambda (message)
                (equal (alist-get 'subtype (alist-get 'request message))
                       "remote_control"))
              (ecc-test-sent-messages)))

(defconst ecc-proc-test--initialize-response
  '((commands . [])
    (remote_control_available . t)
    (remote_control_auto_enable . t)
    (remote_control_auto_on_by_default . :false))
  "An initialize response of a machine where Remote Control is on.
The values are the ones measured on 2026-09-08 (docs/verified.md).")

(ert-deftest ecc-proc-test-initialize-turns-remote-control-on ()
  "A session follows what the initialize response says (FR-SES-2, `auto').
The CLI only advises a stream-json client, so the bridge is asked for
here or nowhere (docs/verified.md, 2026-09-08)."
  (ecc-test-with-fake-session session
    ;; Remote Control refuses a workspace that was never trusted, which
    ;; the temporary directory of the fake session is.
    (setf (ecc-session-project-root session) ecc-test-directory)
    (let ((ecc-remote-control 'auto))
      (ecc-proc-test--initialize session ecc-proc-test--initialize-response)
      (should (ecc-model-remote-control session 'available))
      (let ((requests (ecc-proc-test--remote-control-requests)))
        (should (= 1 (length requests)))
        (let ((request (alist-get 'request (car requests))))
          (should (eq (alist-get 'enabled request) t))
          (should (equal (alist-get 'name request) (ecc-session-name session)))))
      ;; The answer carries the URL that opens the session elsewhere;
      ;; without it nothing on screen says where the session went.
      (ecc-proc-test--answer-last
       session '((session_url . "https://claude.ai/code/session_01TED")
                 (connect_url . "https://claude.ai/code?environment=")
                 (environment_id . "")
                 (bridge_epoch . 1)
                 (bridge_session_id . "cse_01TED")))
      (should (ecc-model-remote-control session 'enabled))
      (should (equal (ecc-model-remote-control session 'session-url)
                     "https://claude.ai/code/session_01TED"))
      (should (equal (ecc-model-remote-control session 'bridge-session-id)
                     "cse_01TED"))
      (should (seq-find (lambda (node)
                          (eq (ecc-model-node-get node 'kind) 'remote-control))
                        (hash-table-values (ecc-session-nodes session)))))))

(ert-deftest ecc-proc-test-remote-control-stays-off-when-it-should ()
  "Nothing asks for the bridge unless the setting, the CLI and the workspace agree."
  (dolist (case '((nil . "the setting says no")
                  (auto-off . "the CLI advises against it")
                  (unavailable . "the CLI cannot offer it")
                  (temporary . "the workspace was never trusted")
                  (option . "the session opted out")))
    (ecc-test-with-fake-session session
      (unless (eq (car case) 'temporary)
        (setf (ecc-session-project-root session) ecc-test-directory))
      (when (eq (car case) 'option)
        (setf (ecc-session-options session) (list :remote-control nil)))
      (let ((ecc-remote-control (if (eq (car case) nil) nil 'auto))
            (response (copy-alist ecc-proc-test--initialize-response)))
        (pcase (car case)
          ('auto-off (setf (alist-get 'remote_control_auto_enable response) :false))
          ('unavailable (setf (alist-get 'remote_control_available response) :false)))
        (ecc-proc-test--initialize session response)
        (should (equal (cons (cdr case) 0)
                       (cons (cdr case)
                             (length (ecc-proc-test--remote-control-requests)))))))))

(ert-deftest ecc-proc-test-remote-control-is-asked-for-when-told-to ()
  "`t' asks wherever the CLI says it can offer it, advice or none."
  (ecc-test-with-fake-session session
    (setf (ecc-session-project-root session) ecc-test-directory)
    (let ((ecc-remote-control t)
          (response (copy-alist ecc-proc-test--initialize-response)))
      (setf (alist-get 'remote_control_auto_enable response) :false)
      (ecc-proc-test--initialize session response)
      (should (= 1 (length (ecc-proc-test--remote-control-requests)))))))

(ert-deftest ecc-proc-test-remote-control-refusal-is-kept ()
  "A refused bridge is left in the log and in the transcript (NFR-2).
Missing authentication, an organisation policy and an untrusted
workspace all come back as the error of a control response."
  (ecc-test-with-fake-session session
    (setf (ecc-session-project-root session) ecc-test-directory)
    (let (reported)
      (ecc-proc-remote-control session t (lambda (_session reason)
                                           (setq reported reason)))
      (ecc-proc-test--answer-last session nil)
      ;; The dispatcher turns the error subtype into an `error' key.
      (ecc-dispatch session
                    (ecc-protocol-parse-line
                     (ecc-protocol-serialize
                      `((type . "control_response")
                        (response . ((subtype . "error")
                                     (request_id . "gone")
                                     (error . "Remote Control requires a Claude subscription")))))))
      (should-not reported))
    ;; The same, with the request id the session is waiting on.
    (let (reported)
      (ecc-proc-remote-control session t (lambda (_session reason)
                                           (setq reported reason)))
      (let ((request-id (car (hash-table-keys
                              (ecc-session-pending-controls session)))))
        (ecc-dispatch session
                      (ecc-protocol-parse-line
                       (ecc-protocol-serialize
                        `((type . "control_response")
                          (response . ((subtype . "error")
                                       (request_id . ,request-id)
                                       (error . "workspace is not trusted"))))))))
      (should (equal reported "workspace is not trusted"))
      (should-not (ecc-model-remote-control session 'enabled))
      (should (equal (ecc-model-remote-control session 'error)
                     "workspace is not trusted"))
      (should (string-search "remote control refused: workspace is not trusted"
                             (mapconcat (lambda (node)
                                          (or (ecc-model-node-get node 'text) ""))
                                        (hash-table-values
                                         (ecc-session-nodes session))
                                        "\n")))
      (should (string-search "remote control on failed: workspace is not trusted"
                             (ecc-test-log-string
                              (ecc--log-buffer (ecc-session-name session))))))))

(ert-deftest ecc-proc-test-remote-control-off-clears-the-session ()
  "Switching the bridge off is answered with nothing, and forgets the URL."
  (ecc-test-with-fake-session session
    (ecc-model-set-remote-control session 'enabled t 'state "connected"
                                  'session-url "https://claude.ai/code/session_01TED")
    (ecc-proc-remote-control session nil)
    (let ((request (alist-get 'request (car (ecc-proc-test--remote-control-requests)))))
      (should (eq (alist-get 'enabled request) :false))
      (should-not (assq 'name request)))
    (ecc-proc-test--answer-last session nil)
    (should-not (ecc-model-remote-control session 'enabled))
    (should-not (ecc-model-remote-control session 'session-url))))

(provide 'ecc-proc-test)

;;; ecc-proc-test.el ends here
