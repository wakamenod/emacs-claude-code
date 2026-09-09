;;; ecc-answer-test.el --- Tests for ecc-answer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Going round the waiting requests and answering the oldest one from
;; anywhere (FR-INBOX-2, FR-INBOX-3, FR-PERM-4).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-answer)
(require 'ecc-session)

(defmacro ecc-answer-test--with-two-sessions (a b &rest body)
  "Run BODY with A and B two registered sessions, each with a pending request.
The request of A is a Bash call and older; the one of B is a Write."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,a
     (let ((,b (ecc-model-create-session :name "other"
                                        :project-root (make-temp-file "ecc-answer" t)))
           (ecc-window-use-side-window nil)
           (ecc-answer-confirm nil))
       (unwind-protect
           (progn
             (ecc-session-ensure-buffer ,a)
             (ecc-session-ensure-buffer ,b)
             (let ((first (ecc-test-add-request ,a "Bash")))
               (setf (ecc-request-input first) '((command . "git status")))
               (setf (ecc-request-created-at first) (time-subtract (current-time) 90)))
             (ecc-test-add-request ,b "Write")
             ,@body)
         (delete-directory (ecc-session-project-root ,b) t)
         (ecc-test-cleanup-session ,b)))))

;;;; Going round (FR-INBOX-2)

(ert-deftest ecc-answer-test-next-attention-cycles ()
  "Each call moves to the next waiting request and wraps around."
  (ecc-answer-test--with-two-sessions a b
    (let ((first (car (ecc-session-pending a)))
          (second (car (ecc-session-pending b))))
      ;; From an unrelated buffer the oldest request is the first stop.
      (with-temp-buffer
        (should (eq (ecc-next-attention) first))
        (should (eq (current-buffer) (ecc-session-buffer a)))
        (should (eq (ecc-perm-request-at-point) first)))
      ;; From there the next one is in the other session, and then round.
      (with-current-buffer (ecc-session-buffer a)
        (should (eq (ecc-next-attention) second))
        (should (eq (current-buffer) (ecc-session-buffer b))))
      (with-current-buffer (ecc-session-buffer b)
        (should (eq (ecc-perm-request-at-point) second))
        (should (eq (ecc-next-attention) first))))))

(ert-deftest ecc-answer-test-next-attention-in-project ()
  "The project variant only visits the sessions of the current project."
  (ecc-answer-test--with-two-sessions a b
    (let ((default-directory (ecc-session-project-root b)))
      (should (eq (ecc-next-attention-in-project) (car (ecc-session-pending b))))
      (should (eq (ecc-next-attention-in-project) (car (ecc-session-pending b)))))
    (ecc-perm-respond (car (ecc-session-pending b)) 'deny)
    (let ((default-directory (ecc-session-project-root b)))
      (with-temp-buffer
        (should-not (ecc-next-attention-in-project))))))

;;;; Answering from anywhere (FR-INBOX-3)

(ert-deftest ecc-answer-test-answer-allow-skips-excluded-tools ()
  "The oldest request is a Bash call, so the Write of the other session goes first."
  (ecc-answer-test--with-two-sessions a b
    (with-temp-buffer
      (let ((expected (car (ecc-session-pending b))))
        (should (eq (ecc-answer-allow) expected)))
      (should (ecc-session-pending a))
      (should-not (ecc-session-pending b))
      (should-error (ecc-answer-allow) :type 'user-error)
      (let ((ecc-answer-exclude-tools nil))
        (should (ecc-answer-allow)))
      (should-not (ecc-session-pending a)))))

(ert-deftest ecc-answer-test-answer-confirms-first ()
  "With confirmation on, the tool and summary are shown and no is respected."
  (ecc-answer-test--with-two-sessions a b
    (let ((ecc-answer-confirm t)
          (asked nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (setq asked prompt) nil)))
        (should-not (ecc-answer-allow)))
      (should (string-search "other" asked))
      (should (string-search "Write" asked))
      (should (ecc-session-pending b)))))

(ert-deftest ecc-answer-test-answer-deny ()
  "Deny from anywhere answers the oldest request of any tool."
  (ecc-answer-test--with-two-sessions a b
    (with-temp-buffer
      (let ((ecc-answer-exclude-tools nil)
            (expected (car (ecc-session-pending a))))
        (should (eq (ecc-answer-deny "later") expected))))
    (should-not (ecc-session-pending a))
    (should (ecc-session-pending b))))

(ert-deftest ecc-answer-test-answer-option ()
  "A number answers the oldest question; a second one finishes it and sends."
  (ecc-test-with-fake-session session
    (let ((request (ecc-test-feed-until-request session "ask-user-question" "質問して"))
          (ecc-answer-confirm nil))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
        ;; Two questions: the first number answers the first and the
        ;; buffer stays open for the second.
        (should (eq (ecc-answer-option 2) request))
        (should (ecc-session-pending session))
        (should (ecc-question-buffer request))
        (ecc-answer-option 1))
      (should-not (ecc-session-pending session))
      (should (equal (ecc-protocol-serialize
                      (alist-get 'answers (alist-get 'updatedInput (ecc-test-response 0))))
                     "{\"Which editor do you prefer?\":\"Vim\",\"Which languages do you use?\":\"Elisp\"}")))))

(ert-deftest ecc-answer-test-global-map ()
  "The global keymap carries the commands of FR-INBOX-3."
  (should (eq (lookup-key ecc-global-map (kbd "a")) #'ecc-answer-allow))
  (should (eq (lookup-key ecc-global-map (kbd "n")) #'ecc-next-attention))
  (should (eq (lookup-key ecc-global-map (kbd "4")) #'ecc-answer-option-4)))

;;;; The mode line (FR-PERM-4)

(ert-deftest ecc-answer-test-mode-line-indicator ()
  "The indicator counts the waiting requests and can be switched off."
  (ecc-answer-test--with-two-sessions a b
    (should (string-search "⚠ecc:2" (ecc-pending-mode-line-string)))
    (ecc-perm-respond (car (ecc-session-pending a)) 'deny)
    (should (string-search "⚠ecc:1" (ecc-pending-mode-line-string)))
    (ecc-perm-respond (car (ecc-session-pending b)) 'deny)
    (should (equal (ecc-pending-mode-line-string) "")))
  (let ((global-mode-string nil))
    (ecc-pending-indicator-mode 1)
    (should (member ecc-pending--mode-line-construct global-mode-string))
    (ecc-pending-indicator-mode -1)
    (should-not (member ecc-pending--mode-line-construct global-mode-string))))

(ert-deftest ecc-answer-test-session-mode-line-state ()
  "The session buffer names the waiting kind in its mode line (FR-PERM-4)."
  (ecc-answer-test--with-two-sessions a b
    (should (equal (substring-no-properties (ecc-render-mode-line-state a)) "⚠ permission"))
    (ecc-test-add-request a "AskUserQuestion")
    (should (equal (substring-no-properties (ecc-render-mode-line-state a))
                   "⚠ question ×2"))
    ;; `format-mode-line' draws nothing in batch, so the construct is
    ;; evaluated by hand.
    (with-current-buffer (ecc-session-buffer a)
      (should (eq (car mode-line-process) :eval))
      (should (string-search "⚠ question ×2"
                             (eval (cadr mode-line-process) t)))
      (should (string-search "⚠ question ×2" (ecc-render-mode-line-process))))
    ;; Answered, the session is back to the turn that was running.
    (ecc-perm-respond (car (ecc-session-pending b)) 'deny)
    (should (equal (substring-no-properties (ecc-render-mode-line-state b)) "● running"))
    (ecc-dispatch b '((type . "result") (subtype . "success") (total_cost_usd . 0)))
    (should-not (ecc-render-mode-line-state b))))

(provide 'ecc-answer-test)

;;; ecc-answer-test.el ends here
