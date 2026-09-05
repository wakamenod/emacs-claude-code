;;; ecc-live-test.el --- Tests that run the real CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; These are the acceptance checks of phase 1 that need a process.  They
;; are tagged `live' and `make test' skips them; run them by hand with
;;
;;     make test-live
;;
;; Every session started here follows the rules of CLAUDE.md: the cheap
;; model, a spending cap, and the emacs-gravity plugin switched off so
;; that its hooks stay out of the recording.  Nothing is persisted, so
;; the sessions cannot be resumed afterwards and leave nothing behind.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)

(defconst ecc-test-live-options
  '(:model "haiku"
    :max-budget-usd 0.5
    :streaming nil
    :disabled-plugins ("emacs-bridge@emacs-gravity-marketplace")
    :extra-args ("--no-session-persistence"))
  "Launch options every live test uses.")

(defvar ecc-test-live-timeout 90
  "Seconds a live test waits for the CLI before giving up.")

(defun ecc-test-live-wait (session predicate &optional what)
  "Wait until PREDICATE returns non-nil for SESSION, then return its value.
WHAT names the thing waited for in the error message."
  (let ((deadline (+ (float-time) ecc-test-live-timeout))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline)
                (process-live-p (ecc-session-process session)))
      (accept-process-output (ecc-session-process session) 0.2))
    (unless value
      (ert-fail (format "timed out waiting for %s" (or what "the CLI"))))
    value))

(defun ecc-test-live-wait-for-result (session)
  "Wait until the current turn of SESSION is finished."
  (ecc-test-live-wait session
                      (lambda () (and (null (ecc-session-current-turn session))
                                      (car (last (ecc-session-turns session)))))
                      "a result"))

(defmacro ecc-test-live-with-session (var &rest body)
  "Run BODY with VAR bound to a started session, killed afterwards."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (default-directory temporary-file-directory)
          (,var (ecc-model-create-session
                 :name "live"
                 :project-root temporary-file-directory
                 :options ecc-test-live-options)))
     (unwind-protect
         (progn
           (ecc-session-ensure-buffer ,var)
           ;; Nothing is waited for here: system/init only arrives once a
           ;; prompt has been sent (docs/verified.md), so a test that
           ;; waited for it before sending would hang.
           (ecc-proc-start ,var)
           ,@body)
       (ecc-proc-stop ,var)
       (ecc-test-cleanup-session ,var))))

(defun ecc-test-live-turn-text (turn)
  "Return the assistant text of TURN as one string."
  (mapconcat (lambda (node)
               (if (eq (ecc-node-type node) 'text)
                   (or (ecc-model-node-get node 'text) "")
                 ""))
             (ecc-turn-children turn) ""))

(ert-deftest ecc-test-live-basic ()
  "One prompt, one turn, a result with a cost, and a drawn transcript."
  :tags '(live)
  (ecc-test-live-with-session session
    (ecc-proc-send-prompt session "Reply with exactly: PONG")
    (let ((turn (ecc-test-live-wait-for-result session)))
      ;; The slash commands arrived in the initialize answer (FR-SES-8),
      ;; and system/init came with the turn.
      (should (ecc-session-commands session))
      (should (ecc-session-init session))
      (should (string-search "PONG" (ecc-test-live-turn-text turn)))
      (should (> (ecc-session-total-cost session) 0))
      (should (eq (ecc-session-state session) 'idle)))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "▌ Reply with exactly: PONG" text))
      (should (string-match-p "● end_turn · [0-9]+ turns · \\$" text)))))

(ert-deftest ecc-test-live-permission ()
  "Deny with a reason, get a new proposal, allow it, and see the file."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live" t))
           (file (expand-file-name "hello.txt" directory))
           (answered 0))
      (unwind-protect
          (progn
            ;; The prompt leaves the content open, so that the reason
            ;; given with the deny is a correction and not a contradiction
            ;; the model would rather ask about than act on.
            (ecc-proc-send-prompt
             session
             (format "Create the file %s containing a short greeting." file))
            ;; First proposal: refuse it and say what to write instead.
            (let ((request (ecc-test-live-wait
                            session (lambda () (car (ecc-session-pending session)))
                            "the first permission request")))
              (should (equal (ecc-request-tool-name request) "Write"))
              (should (eq (ecc-request-kind request) 'permission))
              (ecc-perm-respond request 'deny
                                :message "Make the content exactly: hello from emacs")
              (cl-incf answered))
            ;; Second proposal: allow it.
            (let ((request (ecc-test-live-wait
                            session (lambda () (car (ecc-session-pending session)))
                            "the second permission request")))
              (should (equal (alist-get 'content (ecc-request-input request))
                             "hello from emacs"))
              (ecc-perm-respond request 'allow)
              (cl-incf answered))
            (ecc-test-live-wait-for-result session)
            (should (= answered 2))
            (should (file-exists-p file))
            (should (equal (with-temp-buffer
                             (insert-file-contents file)
                             (string-trim (buffer-string)))
                           "hello from emacs"))
            (should-not (ecc-session-pending session)))
        (delete-directory directory t)))))

(ert-deftest ecc-test-live-slash-command ()
  "A slash command comes back as a synthetic reply (FR-INP-2, 4.2)."
  :tags '(live)
  (ecc-test-live-with-session session
    (ecc-proc-send-prompt session "/context")
    (let* ((turn (ecc-test-live-wait-for-result session))
           (text (seq-find (lambda (node) (eq (ecc-node-type node) 'text))
                           (ecc-turn-children turn))))
      (should text)
      (should (ecc-model-node-get text 'synthetic))
      ;; A synthetic answer costs nothing, so it must not move the
      ;; context estimate (plan section 9, item 12).
      (should (= (ecc-session-context-tokens session) 0)))))

(ert-deftest ecc-test-live-interrupt ()
  "An interrupt is answered and the turn ends (FR-SES-5)."
  :tags '(live)
  (ecc-test-live-with-session session
    (let ((answer nil))
      (ecc-proc-send-prompt session
                            "Count slowly from 1 to 500, one number per line.")
      (ecc-test-live-wait session
                          (lambda () (ecc-turn-children
                                      (ecc-session-current-turn session)))
                          "the turn to start")
      (ecc-proc-control session "interrupt"
                        (lambda (_session response) (setq answer (or response t))))
      (ecc-test-live-wait session (lambda () answer) "the interrupt answer")
      (ecc-test-live-wait-for-result session)
      (should-not (ecc-session-pending session))
      (should (process-live-p (ecc-session-process session))))))


(ert-deftest ecc-test-live-streaming ()
  "A long Write streams its input and the reply grows delta by delta.
The phase 2 acceptance check: each delta costs well under 5ms to draw."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live" t))
           (file (expand-file-name "long.py" directory))
           (deltas 0)
           (drawn 0.0)
           (text-seen nil))
      (setf (ecc-session-options session)
            (plist-put (copy-sequence ecc-test-live-options) :streaming t))
      ;; The process was started with the shared options; restart it with
      ;; --include-partial-messages.
      (ecc-proc-stop session)
      (ecc-test-live-wait session (lambda () (not (process-live-p (ecc-session-process session))))
                          "the process to stop")
      (setf (ecc-session-auto-approve-kinds session) '("Write"))
      (ecc-proc-start session)
      (unwind-protect
          (let ((ecc-stream-delta-hook
                 (cons (lambda (session node text)
                         (cl-incf deltas)
                         (when (eq (ecc-node-type node) 'text)
                           (setq text-seen t))
                         (cl-incf drawn
                                  (car (benchmark-run 1
                                         (ecc-render--on-delta session node text)))))
                       (remq #'ecc-render--on-delta ecc-stream-delta-hook)))
                (ecc-stream-throttle 0))
            (ecc-proc-send-prompt
             session
             (format "Write the file %s with 60 Python functions f0 to f59, each returning its number, separated by blank lines. Then reply with one short sentence." file))
            (let ((turn (ecc-test-live-wait-for-result session)))
              (should (file-exists-p file))
              (should (> deltas 5))
              (should text-seen)
              (message "streaming: %d deltas, %.2fms each to draw" deltas (* 1000 (/ drawn deltas)))
              (should (< (/ drawn deltas) 0.005))
              ;; Streamed blocks and complete messages made one tree.
              (should (seq-find (lambda (node) (and (eq (ecc-node-type node) 'step)
                                                    (= 1 (length (ecc-node-children node)))))
                                (ecc-turn-children turn)))
              (should (= 0 (hash-table-count (ecc-session-stream-blocks session))))
              (ecc-render-flush session)
              (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
                (should (string-search "✓ Write" text))
                (should (string-search "@@ -0,0 +1," text))
                (should (string-search "Files (1)" text)))))
        (delete-directory directory t)))))

(provide 'ecc-live-test)

;;; ecc-live-test.el ends here
