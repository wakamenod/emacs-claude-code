;;; ecc-hint.el --- Recap, context left and prompt suggestions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; What the client says about a conversation without being asked
;; (section 6.11 of IMPLEMENTATION_PLAN.md):
;;
;; - the recap (FR-HINT-1, 2).  The terminal client sums a conversation
;;   up when the user has been away; its away summary is driven by
;;   terminal focus events that never reach a headless session, so Emacs
;;   sends `/recap' itself when the frame has been idle or unfocused for
;;   a while.  The answer is a synthetic one liner and is shown at the
;;   end of the transcript rather than as a turn of its own: nothing the
;;   user typed is in it.
;;
;; - the context left (FR-HINT-3, 5).  The CLI does not tell a headless
;;   session how full the window is -- `autocompact_state' only goes to
;;   CLAUDE_CODE_REMOTE (REQUIREMENTS section 7) -- so the estimate is
;;   made here out of the usage of the last assistant message and the
;;   window of the model in use.  A compaction resets it.
;;
;; - the prompt suggestion (FR-HINT-4), shown in the prompt region while
;;   it is empty and taken with one key.
;;
;; Every one of these costs something -- an API call for the recap, the
;; --prompt-suggestions flag for the suggestion -- so each has a
;; defcustom of its own that switches it off (NFR-3).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'format-spec)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-chat)

;;;; Options

(defcustom ecc-recap-enabled t
  "Non-nil sums the conversation up after a while away (FR-HINT-1).
The summary is asked of the CLI with `/recap', which is a turn like
any other and costs what a short turn costs, so this can be turned
off (NFR-3)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-recap-idle-seconds 60
  "Seconds of Emacs idleness after which a session is summed up."
  :type 'number
  :group 'ecc)

(defcustom ecc-recap-blur-seconds 120
  "Seconds without focus on any frame after which a session is summed up.
Nil never sums a session up on losing focus."
  :type '(choice (const :tag "Never" nil) number)
  :group 'ecc)

(defcustom ecc-recap-quiet-seconds 30
  "Seconds that must pass after a result before a recap is worth asking.
The user has just been told what happened; saying it again reads as
noise and costs a turn (FR-HINT-2)."
  :type 'number
  :group 'ecc)

(defcustom ecc-recap-rate-limit-threshold 0.9
  "Rate limit utilization above which no recap is asked for (FR-HINT-2)."
  :type 'number
  :group 'ecc)

(defcustom ecc-recap-timeout 120
  "Seconds after which a recap that never came back is given up on.
The turn it opened is closed, so that prompts stop queueing behind it."
  :type 'number
  :group 'ecc)

(defcustom ecc-model-context-window '(("[1m]" . 1000000)
                                      ("opus-5" . 1000000)
                                      ("sonnet-5" . 1000000)
                                      ("fable-5" . 1000000)
                                      ("haiku-4-5" . 200000))
  "Context window in tokens of the models whose name matches.
An alist of (SUBSTRING . TOKENS); the first entry whose substring
appears in the model name wins, and `ecc-context-window-default' is
used when none does.  A 1M window can be announced in the model name
itself, as in \"claude-sonnet-5[1m]\", but it is not always: the
Claude 5 models carry one under their plain names too, which the CLI
says nowhere -- neither system/init nor the recording mentions a
window -- so the names are listed here (see docs/decisions.md,
2026-09-06)."
  :type '(alist :key-type string :value-type integer)
  :group 'ecc)

(defcustom ecc-context-window-default 200000
  "Context window in tokens assumed for a model that is not listed."
  :type 'integer
  :group 'ecc)

(defcustom ecc-autocompact-buffer 0.13
  "Fraction of the window the CLI keeps free to compact in.
Only used when the session was started without --autocompact, which
would say the threshold outright."
  :type 'number
  :group 'ecc)

(defcustom ecc-context-warn-threshold 0.2
  "Fraction of the context window left below which the indicator warns."
  :type 'number
  :group 'ecc)

(defcustom ecc-context-critical-threshold 0.1
  "Fraction left below which the indicator asks for a compaction."
  :type 'number
  :group 'ecc)

(defcustom ecc-mode-line-format nil
  "How a session describes itself in the mode line (FR-HINT-3).
Nil by default: the mode line is narrow, the same numbers are in the
header line, and a session that repeated them in both was unreadable.
The specifications are %n the session name, %m the model, %p the
permission mode, %l the context left as a percentage, %t the tokens in
the context, %c the cost so far, %r the rate limit utilization and %s
the state.  Nil shows nothing."
  :type '(choice (const :tag "Nothing" nil) string)
  :group 'ecc)

(defcustom ecc-context-indicator t
  "Non-nil shows the context left in the header line of a session."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-prompt-suggestion-display t
  "Non-nil shows the suggestion the CLI offers in the prompt region.
The suggestions only arrive when the session was started with
--prompt-suggestions, which `ecc-prompt-suggestions-enabled' controls."
  :type 'boolean
  :group 'ecc)

;;;; The model in use and its window (FR-HINT-3)

(defun ecc-hint-model (session)
  "Return the name of the model SESSION is talking to, or nil.
What the CLI said in system/init is the truth; before the first turn
there is only what the session was started with."
  (or (alist-get 'model (ecc-session-init session))
      (ecc-model-option session :model ecc-model)))

(defun ecc-hint-model-window (session)
  "Return the context window in tokens of the model of SESSION."
  (let ((model (or (ecc-hint-model session) "")))
    (or (cdr (seq-find (lambda (entry) (string-search (car entry) model))
                       ecc-model-context-window))
        ecc-context-window-default)))

(defun ecc-hint-context-window (session)
  "Return how many tokens SESSION may fill before it is compacted.
--autocompact says it outright; otherwise the window of the model less
the room the CLI keeps to compact in (`ecc-autocompact-buffer')."
  (let ((threshold (ecc-model-option session :autocompact ecc-autocompact)))
    (if (and (numberp threshold) (> threshold 0))
        threshold
      (round (* (ecc-hint-model-window session) (- 1.0 ecc-autocompact-buffer))))))

(defun ecc-hint-context-left (session)
  "Return the fraction of the context window of SESSION still free.
Nil when nothing has been said yet, so that no guess is shown before
there is one.  The fraction is clamped: a window can be overrun before
the CLI gets round to compacting."
  (let ((window (ecc-hint-context-window session))
        (tokens (ecc-session-context-tokens session)))
    (when (and (numberp tokens) (> window 0) (ecc-session-usage session))
      (max 0.0 (min 1.0 (/ (float (- window tokens)) window))))))

(defun ecc-hint-context-face (left)
  "Return the face the context indicator wears with LEFT of the window free."
  (cond ((null left) 'ecc-dim-face)
        ((<= left ecc-context-critical-threshold) 'ecc-error-face)
        ((<= left ecc-context-warn-threshold) 'ecc-warning-face)
        (t 'ecc-dim-face)))

(defun ecc-hint-context-string (session)
  "Return the context left of SESSION as a line, or nil when unknown.
Below `ecc-context-critical-threshold' the line says what to do about
it (FR-HINT-3)."
  (when-let* ((left (ecc-hint-context-left session)))
    (propertize (format "context %d%% left%s"
                        (round (* 100 left))
                        (if (<= left ecc-context-critical-threshold)
                            " — run /compact" ""))
                'face (ecc-hint-context-face left))))

(defun ecc-hint-context-indicator (session)
  "Return the header line addition of SESSION (FR-HINT-3)."
  (and ecc-context-indicator (ecc-hint-context-string session)))

;;;; The rate limit (FR-HINT-3)

(defun ecc-hint-rate-limit (session window)
  "Return the utilization of the rate limit WINDOW of SESSION, or nil.
WINDOW is a symbol such as `five_hour' or `seven_day'."
  (when-let* ((info (ecc-session-rate-limit session))
              (windows (alist-get 'unifiedWindows info)))
    (alist-get 'utilization (alist-get window windows))))

(defun ecc-hint-rate-limit-max (session)
  "Return the highest rate limit utilization SESSION was told about."
  (let ((values (delq nil (list (ecc-hint-rate-limit session 'five_hour)
                                (ecc-hint-rate-limit session 'seven_day)))))
    (when values (apply #'max values))))

(defun ecc-hint-rate-limit-string (session)
  "Return the rate limit windows of SESSION as a short string, or nil."
  (let ((five (ecc-hint-rate-limit session 'five_hour))
        (seven (ecc-hint-rate-limit session 'seven_day)))
    (when (or five seven)
      (string-join (delq nil (list (when five (format "5h %d%%" (round (* 100 five))))
                                   (when seven (format "7d %d%%" (round (* 100 seven))))))
                   " "))))

;;;; The mode line (FR-HINT-3)

(defun ecc-hint-token-string (tokens)
  "Return TOKENS in a form that fits a mode line."
  (cond ((null tokens) "?")
        ((>= tokens 1000000) (format "%.1fM" (/ tokens 1000000.0)))
        ((>= tokens 1000) (format "%.1fk" (/ tokens 1000.0)))
        (t (format "%d" tokens))))

(defun ecc-hint-mode-line-string (&optional session)
  "Return what SESSION says about itself in a mode line.
SESSION defaults to the one this buffer shows.  Returns an empty
string when there is nothing to say, so that the result can go
straight into a mode line construct."
  (let ((session (or session (bound-and-true-p ecc-render--session))))
    (if (or (null session) (null ecc-mode-line-format))
        ""
      (let ((left (ecc-hint-context-left session)))
        (format-spec
         ecc-mode-line-format
         `((?n . ,(ecc-session-name session))
           (?m . ,(or (ecc-hint-model session) "—"))
           (?p . ,(or (ecc-session-permission-mode session) "default"))
           (?l . ,(if left
                      (propertize (format "%d%%" (round (* 100 left)))
                                  'face (ecc-hint-context-face left))
                    "—"))
           (?t . ,(ecc-hint-token-string (ecc-session-context-tokens session)))
           (?c . ,(format "$%.4f" (or (ecc-session-total-cost session) 0)))
           (?r . ,(or (ecc-hint-rate-limit-string session) "—"))
           (?s . ,(format "%s" (ecc-session-state session)))))))))

;;;; The recap (FR-HINT-1, FR-HINT-2)

(defun ecc-hint-recap-get (session key)
  "Return KEY of the recap state of SESSION."
  (alist-get key (ecc-session-recap-state session)))

(defun ecc-hint-recap-put (session key value)
  "Set KEY of the recap state of SESSION to VALUE."
  (setf (alist-get key (ecc-session-recap-state session)) value))

(defun ecc-hint-draft-p (session)
  "Return non-nil when something is written in the prompt region of SESSION."
  (let ((buffer (ecc-session-buffer session)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (not (string-empty-p (string-trim (ecc-chat-draft))))))))

(defun ecc-hint-recap-skip-reason (session)
  "Return why SESSION is not worth summing up now, or nil when it is.
The conditions are the ones the terminal client uses for its away
summary (FR-HINT-2), each named by the symbol this returns."
  (let ((last-result (ecc-session-last-result-time session))
        (last-turn (car (last (ecc-session-turns session)))))
    (cond
     ((not ecc-recap-enabled) 'disabled)
     ((not (memq (ecc-session-kind session) '(own))) 'not-ours)
     ((not (process-live-p (ecc-session-process session))) 'no-process)
     ;; A request waiting for an answer is the more useful of the two
     ;; reasons, so it is looked at before the state it puts the
     ;; session in.
     ((ecc-session-pending session) 'waiting)
     ((not (eq (ecc-session-state session) 'idle)) 'busy)
     ((ecc-hint-recap-get session 'awaiting) 'asked)
     ((null last-turn) 'nothing-said)
     ((ecc-hint-draft-p session) 'draft)
     ((and last-result
           (< (float-time (time-subtract (current-time) last-result))
              ecc-recap-quiet-seconds))
      'too-soon)
     ;; Nothing has been said since the last recap, so it would be the
     ;; same sentence again.
     ((equal (ecc-hint-recap-get session 'turn) (ecc-turn-id last-turn)) 'unchanged)
     ((when-let* ((utilization (ecc-hint-rate-limit-max session)))
        (>= utilization ecc-recap-rate-limit-threshold))
      'rate-limited)
     (t nil))))

(defun ecc-hint-send-recap (session)
  "Ask SESSION for a recap of the conversation so far (FR-HINT-1).
The prompt goes out in a turn the transcript does not show: the user
did not ask for it, and the answer is a single line that belongs at
the end of the conversation rather than in it."
  (let ((last-turn (car (last (ecc-session-turns session)))))
    (ecc-hint-recap-put session 'awaiting (current-time))
    (ecc-hint-recap-put session 'turn (and last-turn (ecc-turn-id last-turn)))
    (ecc-model-begin-transient-turn session "/recap")
    (ecc-proc-send-transient session "/recap")
    (run-with-timer ecc-recap-timeout nil #'ecc-hint--give-up
                    session (ecc-hint-recap-get session 'awaiting))
    session))

(defun ecc-hint--give-up (session asked)
  "Close the recap of SESSION that was asked for at ASKED and never came.
A turn that never ends holds back everything typed after it."
  (when (equal (ecc-hint-recap-get session 'awaiting) asked)
    (ecc-hint-recap-put session 'awaiting nil)
    (let ((turn (ecc-session-current-turn session)))
      (when (and turn (ecc-turn-transient turn))
        (ecc-model-finish-turn session nil)
        (ecc-model-set-state session 'idle)
        (ecc-proc-drain-queue session)))
    (ecc-log (ecc-session-name session) "recap timed out")))

(defun ecc-hint-maybe-recap (session)
  "Sum SESSION up when nothing speaks against it (FR-HINT-1, 2).
Returns the reason it was skipped, or nil when the recap went out."
  (or (ecc-hint-recap-skip-reason session)
      (progn (ecc-hint-send-recap session) nil)))

(defun ecc-hint-recap-all ()
  "Sum up every session that is worth summing up."
  (dolist (session (ecc-model-sessions))
    (condition-case err
        (ecc-hint-maybe-recap session)
      (error (ecc-log (ecc-session-name session) "recap failed: %s"
                      (error-message-string err))))))

(defun ecc-hint--capture (session node)
  "Turn NODE into the recap of SESSION when that is what it is.
The CLI answers `/recap' with a synthetic assistant message, which
`ecc-dispatch' has already made a text node of; it is retyped rather
than copied, so that the transcript holds one node for one message."
  (when (and (ecc-hint-recap-get session 'awaiting)
             (eq (ecc-node-type node) 'text)
             (ecc-model-node-get node 'synthetic))
    (let ((text (string-trim (or (ecc-model-node-get node 'text) ""))))
      (setf (ecc-node-type node) 'recap)
      (ecc-hint-recap-put session 'awaiting nil)
      (ecc-hint-recap-put session 'node (ecc-node-id node))
      (ecc-hint-recap-put session 'time (current-time))
      (ecc-hint-recap-put session 'text text)
      ;; The node changed type after the renderer was told it arrived,
      ;; and the line belongs at the end of the transcript either way.
      (ecc-model-node-changed session node)
      text)))

(defun ecc-hint-recap-line (session)
  "Return the recap of SESSION as the line drawn under the transcript."
  (when-let* ((text (ecc-hint-recap-get session 'text)))
    (unless (string-empty-p text)
      (propertize (concat "✎ " (replace-regexp-in-string "[ \t\n]+" " " text))
                  'face 'ecc-recap-face))))

;;;; The prompt suggestion (FR-HINT-4)

(defun ecc-hint-suggestion (session)
  "Return the prompt the CLI last suggested for SESSION, or nil."
  (let ((suggestion (ecc-hint-recap-get session 'suggestion)))
    (cond ((stringp suggestion) suggestion)
          ((consp suggestion) (or (alist-get 'prompt suggestion)
                                  (alist-get 'text suggestion))))))

(defun ecc-hint-suggestion-placeholder (session)
  "Return the suggestion of SESSION as the placeholder of its prompt region.
The placeholder is only shown while nothing has been typed, which is
what keeps a suggestion out of the way of a draft (FR-HINT-4)."
  (when-let* ((suggestion (and ecc-prompt-suggestion-display
                               (ecc-hint-suggestion session))))
    (format "%s   (C-c C-s to take it)" suggestion)))

(add-hook 'ecc-chat-placeholder-functions #'ecc-hint-suggestion-placeholder)

(defun ecc-hint-show-suggestion (session)
  "Show the suggestion of SESSION in its prompt region (FR-HINT-4).
Returns the suggestion shown, or nil when there is none or a draft is
in the way."
  (let ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ecc-chat-update-placeholder)
        (and (ecc-hint-suggestion-placeholder session)
             (string-empty-p (string-trim (ecc-chat-draft)))
             (ecc-hint-suggestion session))))))

(defun ecc-hint-accept-suggestion ()
  "Write the suggested prompt into the prompt region (FR-HINT-4)."
  (interactive)
  (let* ((session (or ecc-render--session
                      (user-error "This buffer does not belong to a Claude session")))
         (suggestion (or (ecc-hint-suggestion session)
                         (user-error "Nothing has been suggested"))))
    (ecc-chat-goto-prompt)
    (insert suggestion)
    (ecc-chat-update-placeholder)
    suggestion))

(defun ecc-hint--on-suggestion (session &rest _)
  "Show whatever SESSION was last suggested, if anything changed."
  (when ecc-prompt-suggestion-display
    (ecc-hint-show-suggestion session)))

;;;; Wiring

(defvar ecc-hint--idle-timer nil
  "Timer that sums a conversation up after `ecc-recap-idle-seconds'.")

(defvar ecc-hint--blur-timer nil
  "Timer that sums a conversation up after the frames lost focus.")

(defun ecc-hint--focus-changed ()
  "Note that a frame gained or lost focus (FR-HINT-1).
Losing it starts the wait; getting it back calls the wait off."
  (if (ecc-hint-focused-p)
      (ecc-hint--cancel-blur)
    (when (and ecc-recap-blur-seconds (null ecc-hint--blur-timer))
      (setq ecc-hint--blur-timer
            (run-with-timer ecc-recap-blur-seconds nil
                            (lambda ()
                              (setq ecc-hint--blur-timer nil)
                              (unless (ecc-hint-focused-p)
                                (ecc-hint-recap-all))))))))

(defun ecc-hint-focused-p ()
  "Return non-nil when a frame of this Emacs has the focus."
  (seq-some (lambda (frame) (eq (frame-focus-state frame) t)) (frame-list)))

(defun ecc-hint--cancel-blur ()
  "Stop waiting for the blur to last long enough to sum up."
  (when ecc-hint--blur-timer
    (cancel-timer ecc-hint--blur-timer)
    (setq ecc-hint--blur-timer nil)))

(define-minor-mode ecc-hint-mode
  "Sum a conversation up after a while away and show what is left of it.
Turning this off stops the timers of FR-HINT-1; the indicators of
FR-HINT-3 stay, since they cost nothing."
  :global t
  :group 'ecc
  (ecc-hint--cancel-blur)
  (when ecc-hint--idle-timer
    (cancel-timer ecc-hint--idle-timer)
    (setq ecc-hint--idle-timer nil))
  (if ecc-hint-mode
      (progn
        (setq ecc-hint--idle-timer
              (run-with-idle-timer ecc-recap-idle-seconds t #'ecc-hint-recap-all))
        (add-function :after after-focus-change-function #'ecc-hint--focus-changed))
    (remove-function after-focus-change-function #'ecc-hint--focus-changed)))

(add-hook 'ecc-node-added-hook #'ecc-hint--capture)
(add-hook 'ecc-progress-hook #'ecc-hint--on-suggestion)
(add-hook 'ecc-render-tail-functions #'ecc-hint-recap-line)
(add-hook 'ecc-render-header-functions #'ecc-hint-context-indicator)

(provide 'ecc-hint)

;;; ecc-hint.el ends here
