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

(ert-deftest ecc-proc-test-command-options ()
  "Session options win over the defcustoms (FR-SES-2)."
  (ecc-test-with-fake-session session
    (let ((ecc-model "opus")
          (ecc-streaming-enabled t))
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

(provide 'ecc-proc-test)

;;; ecc-proc-test.el ends here
