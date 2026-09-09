;;; ecc-btw-test.el --- Tests for ecc-btw  -*- lexical-binding: t; -*-

;;; Commentary:

;; The side questions of FR-BTW-1..4.  No CLI is started: what would go
;; out on stdin is collected by `ecc-test-with-fake-session', and the
;; answers are the ones test/fixtures/side-question.jsonl recorded from
;; the real 2.1.266 (scripts/record-side-question.sh).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-btw)
(require 'ecc-prompt)
(require 'ecc-chat)

(defun ecc-btw-test--sent-request (n)
  "Return the request object of the Nth control request sent."
  (alist-get 'request (nth n (ecc-test-sent-messages))))

(defmacro ecc-btw-test-with-session (var &rest body)
  "Run BODY with VAR bound to a fake session that has no side questions."
  (declare (indent 1) (debug (symbolp body)))
  `(ecc-test-with-fake-session ,var
     (let ((ecc-btw--exchanges (make-hash-table :test #'eq))
           (ecc-btw--inflight (make-hash-table :test #'eq)))
       (unwind-protect
           (progn ,@body)
         (when-let* ((buffer (get-buffer (ecc-btw-buffer-name ,var))))
           (kill-buffer buffer))))))

(defun ecc-btw-test--answer (session request-id response)
  "Hand SESSION the answer RESPONSE to REQUEST-ID, the way the CLI would."
  (ecc-dispatch
   session
   (ecc-protocol-parse-line
    (ecc-protocol-serialize
     `((type . "control_response")
       (response . ((subtype . "success")
                    (request_id . ,request-id)
                    (response . ,response))))))))

;;;; What goes out

(ert-deftest ecc-btw-test-asks-with-a-control-request ()
  "A side question is a control request, not a prompt (FR-BTW-1)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "この関数はどこで使われている？")))
      (should (stringp request-id))
      (let ((request (ecc-btw-test--sent-request 0)))
        (should (equal (alist-get 'subtype request) "side_question"))
        (should (equal (alist-get 'question request)
                       "この関数はどこで使われている？"))
        ;; Nothing was threaded on the first question.
        (should-not (assq 'history request)))
      ;; No prompt was sent and no turn was opened: the conversation is
      ;; untouched (FR-BTW-2).
      (should-not (seq-find (lambda (message)
                              (equal (alist-get 'type message) "user"))
                            (ecc-test-sent-messages)))
      (should-not (ecc-session-current-turn session)))))

(ert-deftest ecc-btw-test-an-empty-question-asks-nothing ()
  "/btw on its own is a usage message (FR-BTW-1)."
  (ecc-btw-test-with-session session
    (should-error (ecc-btw-ask session "   ") :type 'user-error)
    (should-not (ecc-test-sent-messages))))

(ert-deftest ecc-btw-test-one-at-a-time ()
  "A second side question waits for the first to be answered."
  (ecc-btw-test-with-session session
    (ecc-btw-ask session "one")
    (should-error (ecc-btw-ask session "two") :type 'user-error)
    (should (= (length (ecc-test-sent-messages)) 1))))

;;;; The answer

(ert-deftest ecc-btw-test-the-answer-lands-in-the-buffer ()
  "The recorded answer becomes an exchange and is drawn (FR-BTW-3)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "What number did I ask you to \
remember?")))
      (should (ecc-btw-inflight session))
      (ecc-btw-test--answer session request-id
                            '((response . "4271") (synthetic . :false)))
      (should-not (ecc-btw-inflight session))
      (let ((exchange (car (ecc-btw-exchanges session))))
        (should (equal (plist-get exchange :response) "4271"))
        (should-not (plist-get exchange :synthetic))
        (should-not (plist-get exchange :error)))
      (with-current-buffer (ecc-btw-buffer-name session)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-search "4271" text))
          (should (string-search "/btw What number" text))
          (should-not (string-search "Answering" text)))))))

(ert-deftest ecc-btw-test-a-synthetic-answer-says-so ()
  "A model that reached for a tool answered nothing (FR-BTW-3)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "read the file for me")))
      (ecc-btw-test--answer session request-id
                            '((response . "") (synthetic . t))))
    (should (plist-get (car (ecc-btw-exchanges session)) :synthetic))
    (with-current-buffer (ecc-btw-buffer-name session)
      (should (string-search "tried to call a tool"
                             (buffer-substring-no-properties (point-min)
                                                             (point-max)))))))

(ert-deftest ecc-btw-test-a-fallback-is-named ()
  "A side question answered by another model says which (FR-BTW-3)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "why?")))
      (ecc-btw-test--answer
       session request-id
       '((response . "because")
         (synthetic . :false)
         (refusal_fallback . ((original_model . "claude-opus-5")
                              (fallback_model . "claude-sonnet-5")
                              (content . "…"))))))
    (with-current-buffer (ecc-btw-buffer-name session)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-search "claude-sonnet-5" text))
        (should (string-search "claude-opus-5" text))))))

(ert-deftest ecc-btw-test-an-error-is-not-swallowed ()
  "A refused side question is shown and logged, not dropped."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "anything")))
      (ecc-dispatch
       session
       (ecc-protocol-parse-line
        (ecc-protocol-serialize
         `((type . "control_response")
           (response . ((subtype . "error")
                        (request_id . ,request-id)
                        (error . "Side question cancelled"))))))))
    (should-not (ecc-btw-inflight session))
    (should (plist-get (car (ecc-btw-exchanges session)) :error))
    (with-current-buffer (ecc-btw-buffer-name session)
      (should (string-search "Side question cancelled"
                             (buffer-substring-no-properties (point-min)
                                                             (point-max)))))))

;;;; The context of a follow-up (FR-BTW-4)

(ert-deftest ecc-btw-test-history-threads-the-follow-up ()
  "The next question carries the answered ones as a vector (FR-BTW-4)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "first")))
      (ecc-btw-test--answer session request-id
                            '((response . "one") (synthetic . :false))))
    (ecc-btw-ask session "second")
    (let ((history (alist-get 'history (ecc-btw-test--sent-request 1))))
      ;; A vector, so that json-serialize writes an array (plan section 2.3).
      (should (vectorp history))
      (should (= (length history) 1))
      (should (equal (alist-get 'question (aref history 0)) "first"))
      (should (equal (alist-get 'response (aref history 0)) "one")))))

(ert-deftest ecc-btw-test-history-is-capped-and-skips-failures ()
  "Only the last few answered exchanges are threaded (FR-BTW-4)."
  (ecc-btw-test-with-session session
    (dotimes (n 4)
      (let ((request-id (ecc-btw-ask session (format "q%d" n))))
        (ecc-btw-test--answer session request-id
                              `((response . ,(format "a%d" n))
                                (synthetic . :false)))))
    ;; One that failed has no answer to thread.
    (ecc-btw--add-exchange session (list :question "broken" :error "no"))
    (let ((ecc-btw-history-limit 2))
      (ecc-btw-ask session "next")
      (let ((history (alist-get 'history (ecc-btw-test--sent-request 4))))
        (should (= (length history) 2))
        (should (equal (alist-get 'question (aref history 0)) "q2"))
        (should (equal (alist-get 'question (aref history 1)) "q3"))))))

(ert-deftest ecc-btw-test-clearing-forgets-the-context ()
  "Clearing the buffer starts the next question afresh (FR-BTW-4)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "first")))
      (ecc-btw-test--answer session request-id
                            '((response . "one") (synthetic . :false))))
    (with-current-buffer (ecc-btw-buffer session)
      (ecc-btw-clear))
    (should-not (ecc-btw-exchanges session))
    (ecc-btw-ask session "second")
    (should-not (assq 'history (ecc-btw-test--sent-request 1)))))

;;;; Progress, cancelling and timing out (FR-BTW-3)

(ert-deftest ecc-btw-test-progress-stays-out-of-the-transcript ()
  "control_request_progress is not a note in the conversation (FR-BTW-2)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "waiting")))
      (ecc-dispatch
       session
       (ecc-protocol-parse-line
        (ecc-protocol-serialize
         `((type . "system")
           (subtype . "control_request_progress")
           (request_id . ,request-id)
           (status . "api_retry")
           (attempt . 1)
           (max_retries . 3)))))
      ;; Nothing was added to the transcript, only to the side buffer.
      (should-not (ecc-session-turns session))
      (with-current-buffer (ecc-btw-buffer-name session)
        (should (string-search "attempt 1/3"
                               (buffer-substring-no-properties
                                (point-min) (point-max))))))))

(ert-deftest ecc-btw-test-cancel-withdraws-the-request ()
  "k stops waiting and tells the CLI to drop the work (FR-BTW-3)."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "long one")))
      (with-current-buffer (ecc-btw-buffer session)
        (ecc-btw-cancel))
      (let ((cancel (car (last (ecc-test-sent-messages)))))
        (should (equal (alist-get 'type cancel) "control_cancel_request"))
        (should (equal (alist-get 'request_id cancel) request-id))))
    (should-not (ecc-btw-inflight session))
    (should (equal (plist-get (car (ecc-btw-exchanges session)) :error)
                   "Cancelled."))))

(ert-deftest ecc-btw-test-a-timeout-says-so ()
  "An answer that never comes does not leave the question hanging."
  (ecc-btw-test-with-session session
    (let ((request-id (ecc-btw-ask session "into the void")))
      (ecc-btw--time-out session request-id))
    (should-not (ecc-btw-inflight session))
    (should (string-search "No answer"
                           (plist-get (car (ecc-btw-exchanges session)) :error)))))

;;;; The way in (FR-BTW-1)

(ert-deftest ecc-btw-test-intercept-takes-the-draft ()
  "/btw in the prompt region is not sent to the CLI (FR-BTW-1)."
  (ecc-btw-test-with-session session
    (should (ecc-btw-intercept session "/btw なぜこの設計にした？"))
    (should (equal (alist-get 'subtype (ecc-btw-test--sent-request 0))
                   "side_question"))
    (should (equal (alist-get 'question (ecc-btw-test--sent-request 0))
                   "なぜこの設計にした？"))))

(ert-deftest ecc-btw-test-intercept-leaves-other-drafts-alone ()
  "Anything else goes to the CLI as it always did (FR-BTW-1)."
  (ecc-btw-test-with-session session
    (should-not (ecc-btw-intercept session "/context"))
    (should-not (ecc-btw-intercept session "by the way, what is this?"))
    (should-not (ecc-btw-intercept session "/btwitter is not it"))
    (should-not (ecc-test-sent-messages))))

(ert-deftest ecc-btw-test-intercept-of-a-bare-btw-sends-nothing ()
  "/btw with no question opens the panel, and never sends (FR-BTW-1)."
  (ecc-btw-test-with-session session
    ;; With nothing asked yet there is nothing to show.
    (should (ecc-btw-intercept session "/btw"))
    (should-not (ecc-test-sent-messages))
    (should-not (get-buffer (ecc-btw-buffer-name session)))
    ;; Once something has been asked, a bare /btw brings it back, the
    ;; way the terminal client's panel does.
    (let ((request-id (ecc-btw-ask session "the first one")))
      (ecc-btw-test--answer session request-id
                            '((response . "an answer") (synthetic . :false))))
    (kill-buffer (ecc-btw-buffer-name session))
    (should (ecc-btw-intercept session "/btw"))
    (should (get-buffer (ecc-btw-buffer-name session)))
    (should (= (length (ecc-test-sent-messages)) 1))))

(ert-deftest ecc-btw-test-the-intercept-is-really-registered ()
  "Loading the package puts /btw on the send path (FR-BTW-1).
The other tests bind `ecc-prompt-intercept-functions\=' themselves, so
they would pass even if nothing ever registered."
  (should (memq 'ecc-btw-intercept ecc-prompt-intercept-functions)))

(ert-deftest ecc-btw-test-send-does-not-reach-the-cli ()
  "`ecc-prompt-send' hands /btw over and empties the region (FR-BTW-1)."
  (ecc-btw-test-with-session session
    (let ((ecc-prompt-intercept-functions '(ecc-btw-intercept)))
      (ecc-session-ensure-buffer session)
      (with-current-buffer (ecc-session-buffer session)
        (ecc-chat-set-draft "/btw これは何をしている？")
        (should (eq (ecc-prompt-send) 'intercepted))
        ;; The draft is gone but can be brought back.
        (should (equal (string-trim (ecc-chat-draft)) ""))
        (should (equal (car ecc-prompt-history) "/btw これは何をしている？"))
        ;; What went out is the control request, not a prompt.
        (should (equal (alist-get 'subtype (ecc-btw-test--sent-request 0))
                       "side_question"))
        (should-not (ecc-session-current-turn session))))))

(ert-deftest ecc-btw-test-btw-is-offered-in-completion ()
  "/btw is a candidate although the CLI never names it (FR-BTW-1)."
  (ecc-btw-test-with-session session
    (setf (ecc-session-commands session)
          [((name . "context") (description . "Show context usage"))])
    (let ((commands (ecc-prompt-commands session)))
      (should (assoc "/btw" commands))
      (should (assoc "/context" commands))
      ;; The list the CLI sent is not touched.
      (should (= (length (ecc-session-commands session)) 1)))))

(ert-deftest ecc-btw-test-the-panel-opens-on-its-own ()
  "The panel can be opened without asking anything (FR-BTW-3)."
  (ecc-btw-test-with-session session
    (should (commandp 'ecc-btw-show))
    ;; Nothing has been asked yet: it opens and says so, and sends
    ;; nothing to the CLI.
    (let ((buffer (ecc-btw-show session)))
      (should (buffer-live-p buffer))
      (with-current-buffer buffer
        (should (derived-mode-p 'ecc-btw-mode))
        (should (eq ecc-btw--session session))
        (should (string-search "Nothing asked yet"
                               (buffer-substring-no-properties (point-min)
                                                               (point-max))))))
    (should-not (ecc-test-sent-messages))
    ;; And it is on a key of the prompt region.
    (should (eq (lookup-key ecc-chat-mode-map (kbd "C-c b")) 'ecc-btw-show))))

;;;; More than one session (CLAUDE.md: anything that spans sessions)

(ert-deftest ecc-btw-test-two-sessions-do-not-mix ()
  "Each session keeps its own side questions and its own buffer."
  (ecc-test-with-fake-session first
    (let ((ecc-btw--exchanges (make-hash-table :test #'eq))
          (ecc-btw--inflight (make-hash-table :test #'eq))
          (second (ecc-model-create-session
                   :name "second" :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (let ((request-id (ecc-btw-ask first "the first one")))
              (ecc-btw-test--answer first request-id
                                    '((response . "answer one")
                                      (synthetic . :false))))
            (let ((request-id (ecc-btw-ask second "the second one")))
              (ecc-btw-test--answer second request-id
                                    '((response . "answer two")
                                      (synthetic . :false))))
            (should (= (length (ecc-btw-exchanges first)) 1))
            (should (= (length (ecc-btw-exchanges second)) 1))
            (with-current-buffer (ecc-btw-buffer-name first)
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-search "answer one" text))
                (should-not (string-search "answer two" text))))
            (with-current-buffer (ecc-btw-buffer-name second)
              (should (string-search "answer two"
                                     (buffer-substring-no-properties
                                      (point-min) (point-max))))))
        (dolist (session (list first second))
          (when-let* ((buffer (get-buffer (ecc-btw-buffer-name session))))
            (kill-buffer buffer)))
        (ecc-test-cleanup-session second)))))

;;;; Display

(ert-deftest ecc-btw-test-posframe-is-only-asked-for-when-set ()
  "The window is the default; posframe needs the package and a frame."
  (let ((ecc-btw-display 'window))
    (should-not (ecc-btw--posframe-p))))

;;;; The recording of the real thing

(ert-deftest ecc-btw-test-the-fixture-is-answered-the-way-it-was-recorded ()
  "The shapes this module reads are the ones 2.1.266 really sent."
  (let ((responses nil)
        (progress nil))
    (dolist (line (ecc-test-fixture-lines "side-question"))
      (let ((message (ecc-protocol-parse-line line)))
        (cond
         ((equal (alist-get 'type message) "control_response")
          (push (alist-get 'response message) responses))
         ((equal (alist-get 'subtype message) "control_request_progress")
          (push message progress)))))
    (setq responses (nreverse responses) progress (nreverse progress))
    ;; Four side questions were asked: three answered, one cancelled.
    (should (= (length progress) 4))
    (should (= (length responses) 4))
    (should (seq-every-p (lambda (message)
                           (equal (alist-get 'status message) "started"))
                         progress))
    (let ((first (car responses)))
      (should (equal (alist-get 'subtype first) "success"))
      (should (equal (alist-get 'response (alist-get 'response first)) "4271"))
      (should (eq (alist-get 'synthetic (alist-get 'response first)) :false)))
    (let ((last (car (last responses))))
      (should (equal (alist-get 'subtype last) "error"))
      (should (equal (alist-get 'error last) "Side question cancelled")))))

(provide 'ecc-btw-test)

;;; ecc-btw-test.el ends here
