;;; ecc-hint-test.el --- Tests for ecc-hint  -*- lexical-binding: t; -*-

;;; Commentary:

;; The recap and the conditions that hold it back (FR-HINT-1, 2), the
;; context left and what the mode line says about it (FR-HINT-3), the
;; prompt suggestion (FR-HINT-4) and the reset a compaction makes
;; (FR-HINT-5).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-hint)
(require 'ecc-session)
(require 'ecc-prompt)
(require 'ecc-session)
(require 'ecc-render)

(defun ecc-hint-test--synthetic (text)
  "Return the assistant message the CLI answers a slash command with."
  `((type . "assistant")
    (uuid . "synthetic-1")
    (session_id . "s")
    (message . ((model . "<synthetic>")
                (role . "assistant")
                (content . [((type . "text") (text . ,text))])
                (usage . ((input_tokens . 0) (output_tokens . 0)))))))

(defun ecc-hint-test--result ()
  "Return a result message that closes a turn."
  '((type . "result") (subtype . "success") (total_cost_usd . 0.0012)
    (num_turns . 1) (duration_ms . 900)))

(defmacro ecc-hint-test--with-live-session (var &rest body)
  "Run BODY with VAR bound to a fake session that looks like it is running.
The recap refuses to speak to a session without a process, and a fake
session has none."
  (declare (indent 1) (debug (symbolp body)))
  `(ecc-test-with-fake-session ,var
     (cl-letf (((symbol-function 'process-live-p) (lambda (&rest _) t)))
       ,@body)))

(defun ecc-hint-test--said (session prompt answer)
  "Have SESSION answer PROMPT, so that there is something to sum up."
  (ecc-model-begin-turn session prompt)
  (ecc-dispatch session `((type . "assistant")
                          (uuid . ,(format "u-%s" (length (ecc-session-turns session))))
                          (message . ((model . "claude-haiku-4-5-20251001")
                                      (content . [((type . "text") (text . ,answer))])
                                      (usage . ((input_tokens . 1000)
                                                (cache_read_input_tokens . 500)))))))
  (ecc-dispatch session (ecc-hint-test--result)))

;;;; The context window and what is left of it (FR-HINT-3)

(ert-deftest ecc-hint-test-context-window ()
  "The window comes from --autocompact, or from the name of the model."
  (ecc-test-with-fake-session session
    ;; Nothing said yet: the default model window less the room the CLI
    ;; keeps to compact in.
    (let ((ecc-model nil))
      (should (= (ecc-hint-context-window session) (round (* 200000 0.87)))))
    ;; The name announces a million token window.
    (setf (ecc-session-init session) '((model . "claude-sonnet-5[1m]")))
    (should (= (ecc-hint-model-window session) 1000000))
    (should (= (ecc-hint-context-window session) (round (* 1000000 0.87))))
    ;; --autocompact says the threshold outright and wins.
    (setf (ecc-session-options session) '(:autocompact 50000))
    (should (= (ecc-hint-context-window session) 50000))
    ;; The share kept free is a setting.
    (setf (ecc-session-options session) nil)
    (setf (ecc-session-init session) '((model . "claude-haiku-4-5")))
    (let ((ecc-autocompact-buffer 0.0))
      (should (= (ecc-hint-context-window session) 200000)))))

(ert-deftest ecc-hint-test-context-left ()
  "The fraction left follows the usage, and warns before it runs out."
  (ecc-test-with-fake-session session
    (setf (ecc-session-options session) '(:autocompact 1000))
    ;; Nothing has been said, so there is nothing to say about it.
    (should-not (ecc-hint-context-left session))
    (should-not (ecc-hint-context-string session))
    (ecc-model-update-usage session '((input_tokens . 400)
                                      (cache_read_input_tokens . 100)))
    (should (= (ecc-session-context-tokens session) 500))
    (should (< (abs (- (ecc-hint-context-left session) 0.5)) 0.001))
    (should (eq (ecc-hint-context-face (ecc-hint-context-left session)) 'ecc-dim-face))
    (should (equal (substring-no-properties (ecc-hint-context-string session))
                   "context 50% left"))
    ;; Below the warning threshold the face changes; below the critical
    ;; one the line says what to do about it.
    (ecc-model-update-usage session '((input_tokens . 850)))
    (should (eq (ecc-hint-context-face (ecc-hint-context-left session))
                'ecc-warning-face))
    (ecc-model-update-usage session '((input_tokens . 950)))
    (should (eq (ecc-hint-context-face (ecc-hint-context-left session))
                'ecc-error-face))
    (should (string-search "run /compact" (ecc-hint-context-string session)))
    ;; A window that is overrun reads as empty, not as a negative share.
    (ecc-model-update-usage session '((input_tokens . 5000)))
    (should (= (ecc-hint-context-left session) 0.0))
    ;; The indicator can be switched off without switching the estimate off.
    (let ((ecc-context-indicator nil))
      (should-not (ecc-hint-context-indicator session)))))

(ert-deftest ecc-hint-test-context-indicator-is-in-the-header ()
  "The header line of a session carries the context left (FR-HINT-3)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (setf (ecc-session-options session) '(:autocompact 1000))
    (ecc-model-update-usage session '((input_tokens . 100)))
    (with-current-buffer (ecc-session-buffer session)
      ;; The header line is read for %-constructs, so what goes into it
      ;; carries a doubled percent sign; it reaches the eye as one.
      (should (string-search "context 90%% left"
                             (substring-no-properties (ecc-render-header-line))))
      (should (string-search "context 90% left"
                             (substring-no-properties
                              (ecc-hint-context-string session)))))))

;;;; The mode line (FR-HINT-3)

(ert-deftest ecc-hint-test-mode-line ()
  "The mode line says what the session costs and how full it is."
  (ecc-test-with-fake-session session
    (setf (ecc-session-options session) '(:autocompact 1000))
    (setf (ecc-session-init session) '((model . "claude-haiku-4-5")
                                       (permissionMode . "acceptEdits")))
    (setf (ecc-session-permission-mode session) "acceptEdits")
    (ecc-model-update-usage session '((input_tokens . 250)))
    (setf (ecc-session-total-cost session) 0.5)
    ;; Nothing is put in the mode line unless it was asked for: the
    ;; header line carries the same numbers (FR-HINT-3).
    (should (equal (ecc-hint-mode-line-string session) ""))
    (let* ((ecc-mode-line-format " %n · %m · %p · %l · %c")
           (line (substring-no-properties (ecc-hint-mode-line-string session))))
      (should (equal line " test · claude-haiku-4-5 · acceptEdits · 75% · $0.5000")))
    ;; Every item and the whole format are settings (FR-HINT-3, NFR-7).
    (let ((ecc-mode-line-format "%t %r"))
      (ecc-dispatch session (car (ecc-test-fixture-messages "compact")))
      (setf (ecc-session-rate-limit session)
            (alist-get 'rate_limit_info
                       (ecc-test-find-message
                        "compact" (lambda (m) (equal (alist-get 'type m)
                                                     "rate_limit_event")))))
      (should (equal (substring-no-properties (ecc-hint-mode-line-string session))
                     "250 5h 18% 7d 15%")))
    (let ((ecc-mode-line-format nil))
      (should (equal (ecc-hint-mode-line-string session) "")))
    ;; A buffer that shows no session says nothing rather than failing.
    (should (equal (ecc-hint-mode-line-string nil) ""))))

(ert-deftest ecc-hint-test-rate-limit ()
  "The rate limit windows are read out of the event the CLI sends."
  (ecc-test-with-fake-session session
    (should-not (ecc-hint-rate-limit-max session))
    (dolist (message (ecc-test-fixture-messages "compact"))
      (when (equal (alist-get 'type message) "rate_limit_event")
        (ecc-dispatch session message)))
    (should (equal (ecc-hint-rate-limit session 'five_hour) 0.18))
    (should (equal (ecc-hint-rate-limit session 'seven_day) 0.15))
    (should (equal (ecc-hint-rate-limit-max session) 0.18))
    (should (equal (ecc-hint-rate-limit-string session) "5h 18% 7d 15%"))))

;;;; When a recap is worth asking for (FR-HINT-2)

(ert-deftest ecc-hint-test-skip-reasons ()
  "Each condition of FR-HINT-2 holds the recap back, and says which."
  (ecc-hint-test--with-live-session session
    ;; A session that has not finished starting is busy; once it is
    ;; idle, there is still nothing to sum up.
    (should (eq (ecc-hint-recap-skip-reason session) 'busy))
    (ecc-model-set-state session 'idle)
    (should (eq (ecc-hint-recap-skip-reason session) 'nothing-said))
    (ecc-hint-test--said session "hello" "hi")
    ;; The result is fresh: the user has just read the answer.
    (should (eq (ecc-hint-recap-skip-reason session) 'too-soon))
    (setf (ecc-session-last-result-time session)
          (time-subtract (current-time) 60))
    (should-not (ecc-hint-recap-skip-reason session))
    ;; A turn in flight, or a request waiting for an answer.
    (ecc-model-set-state session 'running)
    (should (eq (ecc-hint-recap-skip-reason session) 'busy))
    (ecc-model-set-state session 'idle)
    (let ((request (ecc-test-add-request session)))
      (should (eq (ecc-hint-recap-skip-reason session) 'waiting))
      (ecc-model-resolve-request session request 'allow))
    (ecc-model-set-state session 'idle)
    ;; A draft in the prompt region.
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat-goto-prompt)
      (insert "  "))
    (should-not (ecc-hint-recap-skip-reason session))
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat-goto-prompt)
      (insert "and now?"))
    (should (eq (ecc-hint-recap-skip-reason session) 'draft))
    (with-current-buffer (ecc-session-ensure-buffer session) (ecc-prompt-clear))
    ;; The rate limit is nearly used up.
    (setf (ecc-session-rate-limit session)
          '((unifiedWindows . ((five_hour . ((utilization . 0.95)))))))
    (should (eq (ecc-hint-recap-skip-reason session) 'rate-limited))
    (setf (ecc-session-rate-limit session) nil)
    ;; Nothing new since the last recap.
    (ecc-hint-recap-put session 'turn (ecc-turn-id (car (last (ecc-session-turns session)))))
    (should (eq (ecc-hint-recap-skip-reason session) 'unchanged))
    (ecc-hint-recap-put session 'turn nil)
    ;; One is already on its way.
    (ecc-hint-recap-put session 'awaiting (current-time))
    (should (eq (ecc-hint-recap-skip-reason session) 'asked))
    (ecc-hint-recap-put session 'awaiting nil)
    ;; Switched off, or a session this Emacs does not run (NFR-3).
    (let ((ecc-recap-enabled nil))
      (should (eq (ecc-hint-recap-skip-reason session) 'disabled)))
    (setf (ecc-session-kind session) 'archived)
    (should (eq (ecc-hint-recap-skip-reason session) 'not-ours))
    (setf (ecc-session-kind session) 'own))
  ;; A session with no process cannot be asked anything.
  (ecc-test-with-fake-session session
    (ecc-hint-test--said session "hello" "hi")
    (should (eq (ecc-hint-recap-skip-reason session) 'no-process))))

;;;; The recap itself (FR-HINT-1)

(ert-deftest ecc-hint-test-recap-round-trip ()
  "The recap is sent outside the transcript and shown at its end."
  (ecc-hint-test--with-live-session session
    (ecc-session-ensure-buffer session)
    (ecc-hint-test--said session "add a test" "done")
    (setf (ecc-session-last-result-time session) (time-subtract (current-time) 60))
    (should-not (ecc-hint-maybe-recap session))
    ;; It went out as a prompt of its own, without joining the queue.
    (should (equal (ecc-test-sent-text 0) "/recap"))
    (should-not (ecc-session-input-queue session))
    ;; The turn it opened is not part of the conversation being read.
    (should (= (length (ecc-session-turns session)) 1))
    (should (ecc-turn-transient (ecc-session-current-turn session)))
    ;; The CLI answers with a synthetic line and closes the turn.
    (ecc-dispatch session (ecc-hint-test--synthetic "Goal: a test.  Next: run it."))
    (ecc-dispatch session (ecc-hint-test--result))
    (should (= (length (ecc-session-turns session)) 1))
    (should (eq (ecc-session-state session) 'idle))
    (should-not (ecc-hint-recap-get session 'awaiting))
    (should (equal (ecc-hint-recap-get session 'text) "Goal: a test.  Next: run it."))
    ;; The answer is kept as a node of its own kind, not as assistant text.
    (let ((node (ecc-model-node session (ecc-hint-recap-get session 'node))))
      (should (eq (ecc-node-type node) 'recap)))
    ;; It is drawn under the transcript, in its own face.
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      ;; One line, whatever the CLI wrapped it as.
      (should (string-search "✎ Goal: a test. Next: run it." text)))
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (should (search-forward "✎ Goal" nil t))
      (should (eq (get-text-property (1- (point)) 'face) 'ecc-recap-face)))
    ;; The cost of the recap is counted, but it is not the moment the
    ;; session last answered the user.
    (should (> (ecc-session-total-cost session) 0.002))
    (should (< (float-time (time-subtract (current-time)
                                          (ecc-session-last-result-time session)))
               61))
    (should (> (float-time (time-subtract (current-time)
                                          (ecc-session-last-result-time session)))
               10))
    ;; Nothing new has been said since, so no second recap goes out.
    (should (eq (ecc-hint-maybe-recap session) 'unchanged))))

(ert-deftest ecc-hint-test-recap-from-a-recording ()
  "A recorded /recap exchange lands as the line under the transcript.
The fixture holds one real turn and the `/recap' that followed it, so
the shape of the answer is the CLI's rather than this test's."
  (ecc-hint-test--with-live-session session
    (ecc-session-ensure-buffer session)
    (let* ((lines (ecc-test-fixture-lines "recap"))
           (turn-lines nil))
      ;; Everything up to and including the first result is the turn the
      ;; user asked for; what follows is the recap.
      (while (and lines (null turn-lines))
        (let ((line (pop lines)))
          (ecc-dispatch session (ecc-protocol-parse-line line))
          (when (equal (alist-get 'type (ecc-protocol-parse-line line)) "result")
            (setq turn-lines t))))
      (should (= (length (ecc-session-turns session)) 1))
      (setf (ecc-session-last-result-time session) (time-subtract (current-time) 60))
      (ecc-hint-send-recap session)
      (dolist (line lines)
        (ecc-dispatch session (ecc-protocol-parse-line line)))
      ;; One line, kept out of the conversation and drawn under it.
      (should (= (length (ecc-session-turns session)) 1))
      (should (string-prefix-p "Building ecc, an Emacs client"
                               (ecc-hint-recap-get session 'text)))
      (ecc-render-flush session)
      (should (string-search "✎ Building ecc"
                             (ecc-test-buffer-string (ecc-session-buffer session)))))))

(ert-deftest ecc-hint-test-recap-does-not-notify ()
  "A recap is not a finished turn: nothing announces it (FR-NOTIFY-1)."
  (ecc-hint-test--with-live-session session
    (let ((finished nil))
      (let ((ecc-turn-finished-hook
             (list (lambda (_session turn) (push turn finished)))))
        (ecc-hint-test--said session "hello" "hi")
        (should (= (length finished) 1))
        (setf (ecc-session-last-result-time session)
              (time-subtract (current-time) 60))
        (ecc-hint-send-recap session)
        (ecc-dispatch session (ecc-hint-test--synthetic "Goal: none."))
        (ecc-dispatch session (ecc-hint-test--result))
        (should (= (length finished) 1))))))

(ert-deftest ecc-hint-test-recap-that-never-comes-back ()
  "A recap with no answer lets go of the turn it opened."
  (ecc-hint-test--with-live-session session
    (ecc-hint-test--said session "hello" "hi")
    (setf (ecc-session-last-result-time session) (time-subtract (current-time) 60))
    (ecc-hint-send-recap session)
    ;; A prompt sent meanwhile waits behind the recap.
    (should (= (ecc-proc-send-prompt session "next please") 1))
    (ecc-hint--give-up session (ecc-hint-recap-get session 'awaiting))
    (should-not (ecc-hint-recap-get session 'awaiting))
    ;; What was waiting goes out once the recap is let go of, in a turn
    ;; of its own that the transcript does show.
    (should (equal (ecc-test-sent-text 1) "next please"))
    (should-not (ecc-session-input-queue session))
    (should-not (ecc-turn-transient (ecc-session-current-turn session)))
    (should (= (length (ecc-session-turns session)) 2))))

;;;; Compaction (FR-HINT-5)

(ert-deftest ecc-hint-test-compaction-resets-the-indicator ()
  "A compaction empties the window again and says so (FR-HINT-5)."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (setf (ecc-session-options session) '(:autocompact 19000))
    (ecc-model-begin-turn session "/compact")
    (ecc-model-update-usage session '((input_tokens . 17496)))
    (should (< (ecc-hint-context-left session) ecc-context-critical-threshold))
    (should (string-search "run /compact" (ecc-hint-context-string session)))
    ;; The status message says a compaction started, the boundary how
    ;; much is left of the conversation.
    (ecc-dispatch session '((type . "system") (subtype . "status")
                            (status . "compacting")))
    (should (eq (ecc-session-state session) 'compacting))
    (dolist (message (ecc-test-fixture-messages "compact"))
      (when (member (alist-get 'subtype message) '("status" "compact_boundary"))
        (ecc-dispatch session message)))
    (should (= (ecc-session-context-tokens session) 1339))
    (should (> (ecc-hint-context-left session) 0.9))
    (should-not (string-search "run /compact" (ecc-hint-context-string session)))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "⟲ compact done, context reset" text))
      (should (string-search "17.5k → 1.3k tokens" text)))))

;;;; The prompt suggestion (FR-HINT-4)

(ert-deftest ecc-hint-test-suggestion ()
  "A suggestion is shown over an empty prompt region and taken with a key."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session)))
      (ecc-dispatch session '((type . "prompt_suggestion")
                              (prompt_suggestion . "Run the tests")))
      (should (equal (ecc-hint-suggestion session) "Run the tests"))
      (should (equal (ecc-hint-show-suggestion session) "Run the tests"))
      (with-current-buffer buffer
        (should (string-search "Run the tests" (ecc-chat-placeholder-shown)))
        ;; It is in the way of a draft, so it goes when one is written.
        (ecc-chat-goto-prompt)
        (insert "no thanks")
        (should-not (ecc-hint-show-suggestion session))
        (should-not (ecc-chat-placeholder-shown))
        (ecc-prompt-clear)
        (should (ecc-hint-show-suggestion session))
        ;; One key writes it into the prompt region.
        (call-interactively #'ecc-hint-accept-suggestion)
        (should (equal (string-trim (ecc-chat-draft)) "Run the tests"))
        (should-not (ecc-chat-placeholder-shown)))
      ;; It costs an API flag, so it can be left out of sight (NFR-3):
      ;; the placeholder goes back to its plain words.
      (with-current-buffer buffer (ecc-prompt-clear))
      (let ((ecc-prompt-suggestion-display nil))
        (should-not (ecc-hint-show-suggestion session))
        (with-current-buffer buffer
          (should (equal (ecc-chat-placeholder-shown) ecc-chat-placeholder)))))))

(provide 'ecc-hint-test)

;;; ecc-hint-test.el ends here
