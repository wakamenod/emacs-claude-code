;;; ecc-hint.el --- Context left and prompt suggestions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; What the client says about a conversation without being asked
;; (section 6.11 of IMPLEMENTATION_PLAN.md):
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
;; The suggestion costs something -- it needs the --prompt-suggestions
;; flag -- so it has a defcustom of its own that switches it off
;; (NFR-3).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'format-spec)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-chat)

;;;; Options

(defcustom ecc-model-context-window '(("[1m]" . 1000000)
                                      ("opus-5" . 1000000)
                                      ("sonnet-5" . 1000000)
                                      ("fable-5" . 1000000)
                                      ("haiku-4-5" . 200000)
                                      ("opus" . 1000000)
                                      ("sonnet" . 1000000)
                                      ("fable" . 1000000)
                                      ("haiku" . 200000))
  "Context window in tokens of the models whose name matches.
An alist of (SUBSTRING . TOKENS); the first entry whose substring
appears in the model name wins, and `ecc-context-window-default' is
used when none does.  The bare names at the end are the aliases a
`/model' is given (\"opus\", \"haiku\"), which is all that is known of
the model between sending one and the answer that names it in full.

A 1M window can be announced in the model name
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
The last real assistant message is the truth: the CLI names the model
on every one, and a `/model\=' sent from here or from the terminal of a
hand-off shows up there and nowhere else.  Before the first answer
there is system/init, and before that only what the session was
started with -- a session read from history has neither, which is why
the recorded messages are asked first."
  (or (ecc-session-last-model session)
      (alist-get 'model (ecc-session-init session))
      (ecc-model-option session :model nil)))

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
        (t 'ecc-ok-face)))

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
  "Return what the header line of SESSION says about its context.
The right of the header line is a tight place, so this is the bare
percentage.  What is left of the window is told by its colour --
yellow-green, amber, red as it runs out (FR-HINT-3)."
  (when ecc-context-indicator
    (when-let* ((left (ecc-hint-context-left session)))
      (propertize (format "%d%%" (round (* 100 left)))
                  'face (ecc-hint-context-face left)))))

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

;;;; What a session was told about itself

(defun ecc-hint-state-get (session key)
  "Return KEY of the hint state of SESSION."
  (alist-get key (ecc-session-hint-state session)))

(defun ecc-hint-state-put (session key value)
  "Set KEY of the hint state of SESSION to VALUE."
  (setf (alist-get key (ecc-session-hint-state session)) value))

;;;; The prompt suggestion (FR-HINT-4)

(defun ecc-hint-suggestion (session)
  "Return the prompt the CLI last suggested for SESSION, or nil."
  (let ((suggestion (ecc-hint-state-get session 'suggestion)))
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

(add-hook 'ecc-progress-hook #'ecc-hint--on-suggestion)
(add-hook 'ecc-render-header-functions #'ecc-hint-context-indicator)

(provide 'ecc-hint)

;;; ecc-hint.el ends here
