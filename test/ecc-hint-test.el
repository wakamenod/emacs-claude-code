;;; ecc-hint-test.el --- Tests for ecc-hint  -*- lexical-binding: t; -*-

;;; Commentary:

;; The context left and what the mode line says about it (FR-HINT-3), the
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

;;;; The context window and what is left of it (FR-HINT-3)

(ert-deftest ecc-hint-test-context-window ()
  "The window comes from --autocompact, or from the name of the model."
  (ecc-test-with-fake-session session
    ;; Nothing said yet: the default model window less the room the CLI
    ;; keeps to compact in.
    (should (= (ecc-hint-context-window session) (round (* 200000 0.87))))
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

(ert-deftest ecc-hint-test-context-window-of-a-plain-claude-5-name ()
  "A Claude 5 model has its million token window without saying [1m].
The CLI announces no window anywhere, and the recordings of this
environment run past 200k tokens with no compaction, so the plain
names are listed in `ecc-model-context-window'."
  (ecc-test-with-fake-session session
    (dolist (model '("claude-opus-5" "claude-sonnet-5" "claude-fable-5-1"))
      (setf (ecc-session-init session) `((model . ,model)))
      (should (= (ecc-hint-model-window session) 1000000)))
    ;; 450k of a real session is half the window, not nothing left.
    (setf (ecc-session-init session) '((model . "claude-opus-5")))
    (ecc-model-update-usage session '((input_tokens . 2)
                                      (cache_read_input_tokens . 448377)
                                      (cache_creation_input_tokens . 2272)))
    (should (> (ecc-hint-context-left session) 0.4))
    (should (eq (ecc-hint-context-face (ecc-hint-context-left session))
                'ecc-dim-face))))

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
      ;; carries a doubled percent sign; it reaches the eye as one.  The
      ;; right of the header is a tight place, so it is the bare share
      ;; there and the whole sentence everywhere else.
      (should (string-search "90%%"
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
