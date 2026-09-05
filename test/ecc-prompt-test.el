;;; ecc-prompt-test.el --- Tests for ecc-prompt  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sending, queueing and slash command completion (FR-INP-1, 2, 3, 6).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-prompt)
(require 'ecc-dispatch)

(defmacro ecc-prompt-test--in-buffer (session &rest body)
  "Run BODY in the prompt buffer of SESSION."
  (declare (indent 1))
  `(with-current-buffer (ecc-prompt-ensure-buffer ,session) ,@body))

(ert-deftest ecc-prompt-test-send ()
  "The buffer goes out as a user message and is emptied (FR-INP-1)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "hello\nworld")
      (ecc-prompt-send)
      (should (string-empty-p (buffer-string))))
    (let ((sent (car (ecc-test-sent-messages))))
      (should (equal (ecc-protocol-serialize sent)
                     (ecc-protocol-serialize
                      (ecc-protocol-user-message "hello\nworld")))))
    ;; Sending opens the turn; the CLI does not announce one (plan 4.1).
    (should (ecc-session-current-turn session))
    (should (equal (ecc-turn-prompt (ecc-session-current-turn session))
                   "hello\nworld"))))

(ert-deftest ecc-prompt-test-empty-prompt-is-refused ()
  "An empty buffer is not sent."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "   \n")
      (should-error (ecc-prompt-send) :type 'user-error))
    (should-not (ecc-test-sent-messages))))

(ert-deftest ecc-prompt-test-queue-while-running ()
  "A prompt sent during a turn waits its turn (FR-INP-6)."
  (ecc-test-with-fake-session session
    (ecc-model-begin-turn session "first")
    (ecc-prompt-test--in-buffer session
      (insert "second")
      (ecc-prompt-send))
    (should (equal (ecc-session-input-queue session) '("second")))
    ;; Nothing left the client: only the first prompt is in flight.
    (should-not (ecc-test-sent-messages))
    (ecc-dispatch session '((type . "result") (subtype . "success")))
    (should-not (ecc-session-input-queue session))
    (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "second"))))

(ert-deftest ecc-prompt-test-slash-commands-go-through ()
  "A slash command is sent as ordinary text (FR-INP-2)."
  (ecc-test-with-fake-session session
    (ecc-prompt-test--in-buffer session
      (insert "/context")
      (ecc-prompt-send))
    (should (equal (alist-get 'content
                              (alist-get 'message (car (ecc-test-sent-messages))))
                   "/context"))))

(ert-deftest ecc-prompt-test-completion ()
  "Completion offers the commands of the initialize answer (FR-INP-3)."
  (ecc-test-with-fake-session session
    (setf (ecc-session-commands session)
          [((name . "context") (description . "Show context usage")
            (argumentHint . ""))
           ((name . "compact") (description . "Compact the conversation")
            (argumentHint . "[instructions]"))])
    (setf (ecc-session-init session) '((slash_commands . ["context" "review"])))
    (ecc-prompt-test--in-buffer session
      (insert "/co")
      (let ((capf (ecc-prompt-capf)))
        (should capf)
        (should (= (nth 0 capf) (line-beginning-position)))
        (should (= (nth 1 capf) (point)))
        (should (member "/context" (nth 2 capf)))
        (should (member "/compact" (nth 2 capf)))
        ;; A command only system/init knows about is offered too.
        (should (member "/review" (nth 2 capf)))
        ;; The description is what the completion user interface shows.
        (should (string-search "Show context usage"
                               (funcall (plist-get (nthcdr 3 capf)
                                                   :annotation-function)
                                        "/context")))
        (should (string-search "[instructions]"
                               (funcall (plist-get (nthcdr 3 capf)
                                                   :annotation-function)
                                        "/compact"))))
      ;; Only the first word of a slash line is a command.
      (insert " and more")
      (should-not (ecc-prompt-capf))
      (erase-buffer)
      (insert "hello")
      (should-not (ecc-prompt-capf)))))

(provide 'ecc-prompt-test)

;;; ecc-prompt-test.el ends here
