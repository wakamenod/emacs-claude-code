;;; ecc-usage.el --- What the plan limits and this session have used  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; One buffer answering "how much of the plan is left", the same
;; question the web client answers under Settings > Usage.
;;
;; The numbers are not worked out here.  The CLI answers the control
;; request `get_usage' with the structured form of what its own
;; `/usage' dialog draws: the plan rate limit windows it read from the
;; claude.ai usage endpoint, the cost and tokens of the session that
;; was asked, and a scan of the transcripts on this machine saying what
;; has been spending the limits.  Asking is a line of JSON, so nothing
;; is estimated and nothing drifts from what the web client says.
;;
;; The answer is experimental and the CLI says so: a key that is not
;; there is skipped rather than guessed at.  The windows above all are
;; read from `limits', the array the CLI already sorted out for its own
;; dialog, because the object beside it carries a window per code name
;; (`nimbus_quill', `cinder_cove', ...) and new ones keep arriving.
;;
;; A usage question is not about a conversation, so it does not need
;; one: with no session running, `ecc-usage' starts a CLI of its own,
;; asks, and stops it again.  No prompt is sent, so it costs nothing.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'iso8601)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)

(declare-function ecc-dashboard-session-at-point "ecc-dashboard" ())

;; posframe is not a dependency of this package: without it, and on a
;; frame that cannot carry a child frame, the buffer goes in a window.
(declare-function posframe-workable-p "posframe" ())
(declare-function posframe-show "posframe" (buffer &rest args))
(declare-function posframe-hide "posframe" (buffer))
(declare-function posframe-poshandler-frame-center "posframe" (info))

(defvar ecc-usage-buffer-name "*ecc-usage*"
  "Name of the buffer `ecc-usage' draws into.")

(defvar ecc-usage-skip-behaviors nil
  "Non-nil leaves out the section saying what is spending the limits.
Working it out costs the CLI a scan of every transcript it touched in
the last seven days, which is the slow part of the answer.")

(defvar ecc-usage-probe-args '("--tools" "" "--no-session-persistence")
  "Extra arguments of the CLI started only to be asked about the usage.
It answers one control request and is stopped again, so it needs no
tools, and a recording of it would be an empty conversation.")

(defvar ecc-usage-bar-width 20
  "Width, in characters, of the bar drawn beside a rate limit window.")

(defvar ecc-usage-reset-format 'relative
  "How the time a rate limit window resets at is written.
`relative' says how long there is to go, the way the web client does;
`absolute' gives the date and time; `both' gives the two of them.")

(defcustom ecc-usage-display 'window
  "Where `ecc-usage' shows what it found.
`window' puts the buffer in a window.  `posframe' floats it over the
frame instead, which needs the posframe package and a graphical frame;
without either, a window is used and the buffer is the same one."
  :type '(choice (const :tag "A window" window)
                 (const :tag "A frame floating over this one" posframe))
  :group 'ecc)

(defface ecc-usage-bar-face
  '((t :inherit success))
  "Face for the used part of a rate limit bar."
  :group 'ecc)

(defface ecc-usage-bar-warning-face
  '((t :inherit warning))
  "Face for the used part of a bar past `ecc-usage-warn-threshold'."
  :group 'ecc)

(defface ecc-usage-bar-critical-face
  '((t :inherit error))
  "Face for the used part of a bar past `ecc-usage-critical-threshold'."
  :group 'ecc)

(defface ecc-usage-bar-empty-face
  '((t :inherit shadow))
  "Face for the part of a rate limit bar that is still free."
  :group 'ecc)

(defvar ecc-usage-warn-threshold 70
  "Percentage of a window above which its bar is drawn as a warning.")

(defvar ecc-usage-critical-threshold 90
  "Percentage of a window above which its bar is drawn as an error.")

;;;; Asking

(defun ecc-usage-fetch (session callback)
  "Ask the CLI of SESSION for its structured `/usage' data.
CALLBACK is called with the session and the response object, or with
an object carrying `error' when the request was refused."
  (apply #'ecc-proc-control session "get_usage" callback
         (when ecc-usage-skip-behaviors (list 'skip_behaviors t))))

(defun ecc-usage--drop (session)
  "Stop the probe SESSION and forget it.
Doing it twice is harmless: the second call finds it already gone."
  (when (ecc-model-session (ecc-session-id session))
    (ecc-proc-stop session)
    (ecc-model-remove-session session)
    (dolist (buffer (list (ecc-session-stream-buffer session)
                          (get-buffer (format "*ecc-stderr: %s*"
                                              (ecc-session-name session)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun ecc-usage--probe (callback)
  "Start a CLI only to ask it about the usage, and call CALLBACK.
CALLBACK takes the same two arguments as the one of `ecc-usage-fetch'.
The session is stopped once the answer is in, and after the control
timeout either way, so that a CLI that never answers is not left
running."
  (let ((session (ecc-model-create-session
                  :name "usage"
                  :options (list :remote-control nil
                                 :usage-probe t
                                 :extra-args ecc-usage-probe-args))))
    (ecc-proc-start session)
    (ecc-usage-fetch
     session
     (lambda (probe response)
       ;; The callback runs inside the process filter, which is no
       ;; place to delete the process it is reading from.
       (run-at-time 0 nil #'ecc-usage--drop probe)
       (funcall callback probe response)))
    (run-at-time (+ ecc-control-timeout 5) nil #'ecc-usage--drop session)
    session))

(defun ecc-usage--live-session ()
  "Return the running session this buffer is about, or nil."
  (seq-find (lambda (session) (process-live-p (ecc-session-process session)))
            (delq nil (list (and (boundp 'ecc-render--session)
                                 (buffer-local-value 'ecc-render--session
                                                     (current-buffer)))
                            (and (derived-mode-p 'ecc-dashboard-mode)
                                 (ecc-dashboard-session-at-point))))))

(defun ecc-usage--ask (callback)
  "Get the usage data and call CALLBACK with the session and the response.
A running session is asked if there is one to ask; otherwise a CLI is
started for the question alone."
  (if-let* ((session (or (ecc-usage--live-session)
                         (seq-find (lambda (session)
                                     (process-live-p (ecc-session-process session)))
                                   (ecc-model-sessions)))))
      (progn (ecc-usage-fetch session callback) session)
    (ecc-usage--probe callback)))

;;;; Reading the answer

(defconst ecc-usage--limit-titles
  '(("session" . "Current session")
    ("weekly_all" . "Current week (all models)")
    ("weekly_opus" . "Current week (Opus)")
    ("weekly_sonnet" . "Current week (Sonnet only)"))
  "Heading for each `kind' of the `limits' array the CLI hands over.
A kind that is not here is titled from its own name, so a window added
to the plan shows up rather than disappearing.")

(defconst ecc-usage--named-windows
  '(("five_hour" . "Current session")
    ("seven_day" . "Current week (all models)")
    ("seven_day_opus" . "Current week (Opus)")
    ("seven_day_sonnet" . "Current week (Sonnet only)"))
  "Windows read by name when the answer carries no `limits' array.")

(defun ecc-usage--limit-title (limit)
  "Return the heading of LIMIT, one entry of the `limits' array."
  (let ((kind (alist-get 'kind limit))
        (model (alist-get 'display_name
                          (alist-get 'model (alist-get 'scope limit)))))
    (cond (model (format "Current week (%s)" model))
          ((cdr (assoc kind ecc-usage--limit-titles)))
          ((and (stringp kind) (not (string-empty-p kind)))
           (let ((words (replace-regexp-in-string "_" " " kind)))
             (concat (upcase (substring words 0 1)) (substring words 1))))
          (t "Limit"))))

(defun ecc-usage-windows (data)
  "Return the rate limit windows of DATA as a list of plists.
Each plist has `:title', `:percent', `:resets' and `:severity'.  The
`limits' array is preferred; the windows named one by one beside it
are the fallback for an answer that carries none."
  (let* ((limits (alist-get 'rate_limits data))
         (array (alist-get 'limits limits)))
    (if (and array (> (length array) 0))
        (mapcar (lambda (limit)
                  (list :title (ecc-usage--limit-title limit)
                        :percent (alist-get 'percent limit)
                        :resets (alist-get 'resets_at limit)
                        :severity (alist-get 'severity limit)))
                (append array nil))
      (delq nil
            (mapcar (lambda (entry)
                      (when-let* ((window (alist-get (intern (car entry)) limits)))
                        (list :title (cdr entry)
                              :percent (alist-get 'utilization window)
                              :resets (alist-get 'resets_at window)
                              :severity nil)))
                    ecc-usage--named-windows)))))

(defvar ecc-usage--time-zone nil
  "Zone the reset times are shown in; nil is the zone of this machine.
The tests pin it, because a snapshot may not depend on where the
machine running it happens to be.")

(defvar ecc-usage--now nil
  "Instant the times to go are counted from; nil is now.
The tests pin it, because a snapshot may not depend on when it ran.")

(defun ecc-usage--time-to-go (seconds)
  "Return SECONDS as the time there is to go, in words."
  (let* ((seconds (round seconds))
         (minutes (/ seconds 60))
         (hours (/ minutes 60))
         (days (/ hours 24)))
    (cond ((< seconds 60) "in less than a minute")
          ((< minutes 60) (format "in %dm" minutes))
          ((< hours 24) (if (zerop (% minutes 60))
                            (format "in %dh" hours)
                          (format "in %dh %dm" hours (% minutes 60))))
          (t (if (zerop (% hours 24))
                 (format "in %dd" days)
               (format "in %dd %dh" days (% hours 24)))))))

(defun ecc-usage--reset-string (iso)
  "Return when the window resetting at ISO resets, or nil.
`ecc-usage-reset-format' decides whether that is the time there is to
go, the time itself, or both."
  (when (stringp iso)
    (condition-case nil
        (let* ((time (encode-time (iso8601-parse iso)))
               (left (- (float-time time) (float-time (or ecc-usage--now
                                                          (current-time)))))
               (relative (if (<= left 0)
                             "any moment now"
                           (ecc-usage--time-to-go left)))
               (absolute (format-time-string "%m/%d %H:%M" time
                                             ecc-usage--time-zone)))
          (pcase ecc-usage-reset-format
            ('absolute absolute)
            ('both (format "%s (%s)" relative absolute))
            (_ relative)))
      (error nil))))

(defun ecc-usage--money (minor exponent currency)
  "Return MINOR units of CURRENCY as an amount, or nil.
EXPONENT is how many of the digits of MINOR are decimals."
  (when (numberp minor)
    (let ((places (if (numberp exponent) exponent 2)))
      (format (concat "%s%." (number-to-string (max 0 places)) "f")
              (if (member currency '("USD" nil)) "$" "")
              (/ minor (float (expt 10 places)))))))

(defun ecc-usage-credits (data)
  "Return what DATA says about the usage credits, or nil.
The `spend' object is preferred: it names its own currency and scale."
  (let* ((limits (alist-get 'rate_limits data))
         (spend (alist-get 'spend limits))
         (extra (alist-get 'extra_usage limits)))
    (cond
     ((and spend (alist-get 'limit spend))
      (let* ((used (alist-get 'used spend))
             (cap (alist-get 'limit spend))
             (currency (alist-get 'currency cap)))
        (list :used (ecc-usage--money (alist-get 'amount_minor used)
                                      (alist-get 'exponent used) currency)
              :limit (ecc-usage--money (alist-get 'amount_minor cap)
                                       (alist-get 'exponent cap) currency)
              :percent (alist-get 'percent spend)
              :enabled (ecc--json-true-p (alist-get 'enabled spend))
              :reason (alist-get 'disabled_reason spend))))
     (extra
      (let ((currency (alist-get 'currency extra))
            (places (alist-get 'decimal_places extra)))
        (list :used (ecc-usage--money (alist-get 'used_credits extra)
                                      places currency)
              :limit (ecc-usage--money (alist-get 'monthly_limit extra)
                                       places currency)
              :percent (alist-get 'utilization extra)
              :enabled (ecc--json-true-p (alist-get 'is_enabled extra))
              :reason (alist-get 'disabled_reason extra)))))))

;;;; Drawing

(defun ecc-usage--percent-face (percent severity)
  "Return the face for a window at PERCENT that the CLI called SEVERITY."
  (cond ((member severity '("critical" "rejected")) 'ecc-error-face)
        ((member severity '("warning" "allowed_warning")) 'ecc-warning-face)
        ((not (numberp percent)) 'ecc-dim-face)
        ((>= percent ecc-usage-critical-threshold) 'ecc-error-face)
        ((>= percent ecc-usage-warn-threshold) 'ecc-warning-face)
        (t 'default)))

(defun ecc-usage--bar-face (percent severity)
  "Return the face for the used part of a bar at PERCENT, called SEVERITY."
  (cond ((member severity '("critical" "rejected")) 'ecc-usage-bar-critical-face)
        ((member severity '("warning" "allowed_warning")) 'ecc-usage-bar-warning-face)
        ((not (numberp percent)) 'ecc-usage-bar-empty-face)
        ((>= percent ecc-usage-critical-threshold) 'ecc-usage-bar-critical-face)
        ((>= percent ecc-usage-warn-threshold) 'ecc-usage-bar-warning-face)
        (t 'ecc-usage-bar-face)))

(defun ecc-usage--bar (percent &optional severity)
  "Return a bar `ecc-usage-bar-width' wide filled to PERCENT.
The used part is coloured for how full the window is, or for SEVERITY
when the CLI graded it itself; the rest is dim."
  (let* ((width (max 1 ecc-usage-bar-width))
         (filled (if (numberp percent)
                     (min width (max 0 (round (* width (/ percent 100.0)))))
                   0)))
    (concat (propertize (make-string filled ?█)
                        'face (ecc-usage--bar-face percent severity))
            (propertize (make-string (- width filled) ?░)
                        'face 'ecc-usage-bar-empty-face))))

(defun ecc-usage--window-line (window)
  "Return the line drawn for the rate limit WINDOW, a plist."
  (let* ((percent (plist-get window :percent))
         (face (ecc-usage--percent-face percent (plist-get window :severity)))
         (resets (ecc-usage--reset-string (plist-get window :resets))))
    (concat "  " (format "%-28s" (plist-get window :title))
            (propertize (format "%4s  "
                                (if (numberp percent)
                                    (format "%d%%" (round percent))
                                  "—"))
                        'face face)
            (ecc-usage--bar percent (plist-get window :severity))
            (if resets
                (propertize (concat "  resets " resets) 'face 'ecc-dim-face)
              "")
            "\n")))

(defun ecc-usage--duration (ms)
  "Return MS milliseconds as a short duration."
  (if (not (numberp ms))
      "—"
    (ecc--duration (/ ms 1000.0))))

(defun ecc-usage--tokens (n)
  "Return the token count N with thousands separated."
  (if (not (numberp n))
      "—"
    (let ((text (number-to-string (round n))))
      (while (string-match "\\([0-9]\\)\\([0-9]\\{3\\}\\)\\(,\\|\\'\\)" text)
        (setq text (replace-match "\\1,\\2\\3" nil nil text)))
      text)))

(defun ecc-usage--limits-section (data)
  "Return the plan limit section of DATA."
  (if (not (ecc--json-true-p (alist-get 'rate_limits_available data)))
      (propertize
       "  Plan limits do not apply to this session (API key, Bedrock or Vertex).\n"
       'face 'ecc-dim-face)
    (let ((windows (ecc-usage-windows data))
          (credits (ecc-usage-credits data)))
      (concat
       (if windows
           (mapconcat #'ecc-usage--window-line windows "")
         (propertize "  The CLI reported no limit window.\n" 'face 'ecc-dim-face))
       (when (and credits (plist-get credits :limit))
         (concat "  " (format "%-28s" "Usage credits")
                 (format "%s / %s" (or (plist-get credits :used) "—")
                         (plist-get credits :limit))
                 (if (plist-get credits :enabled)
                     ""
                   (propertize (format "  (off%s)"
                                       (if (plist-get credits :reason)
                                           (concat ": " (plist-get credits :reason))
                                         ""))
                               'face 'ecc-dim-face))
                 "\n"))))))

(defun ecc-usage--session-section (data)
  "Return the section of DATA about the session that was asked."
  (let* ((session (alist-get 'session data))
         (cost (alist-get 'total_cost_usd session)))
    (when (and session (numberp cost))
      (concat
       (propertize "This session\n" 'face 'ecc-heading-face)
       (format "  $%.4f · api %s · wall %s · +%d −%d lines\n"
               cost
               (ecc-usage--duration (alist-get 'total_api_duration_ms session))
               (ecc-usage--duration (alist-get 'total_duration_ms session))
               (or (alist-get 'total_lines_added session) 0)
               (or (alist-get 'total_lines_removed session) 0))
       (mapconcat
        (lambda (entry)
          (let ((use (cdr entry)))
            (format "  %-28s in %s · out %s · cache %s r / %s w\n"
                    (car entry)
                    (ecc-usage--tokens (alist-get 'inputTokens use))
                    (ecc-usage--tokens (alist-get 'outputTokens use))
                    (ecc-usage--tokens (alist-get 'cacheReadInputTokens use))
                    (ecc-usage--tokens (alist-get 'cacheCreationInputTokens use)))))
        (alist-get 'model_usage session) "")
       "\n"))))

(defconst ecc-usage--behavior-labels
  '(("cache_miss" . "cache miss")
    ("long_context" . "long context")
    ("subagent_heavy" . "subagent heavy")
    ("high_parallel" . "highly parallel")
    ("cron" . "scheduled"))
  "What the CLI calls each behaviour it attributes usage to.")

(defun ecc-usage--shares (label items)
  "Return the line listing ITEMS, each a name and a percentage, under LABEL."
  (when (and items (> (length items) 0))
    (concat "    " (format "%-14s" label)
            (mapconcat (lambda (item)
                         (format "%s %d%%" (alist-get 'name item)
                                 (round (or (alist-get 'pct item) 0))))
                       (append items nil) " · ")
            "\n")))

(defun ecc-usage--window-behaviors (title window)
  "Return what WINDOW, the day or the week of `behaviors', says, under TITLE."
  (when window
    (concat
     "  " (propertize title 'face 'ecc-heading-face) "\n"
     (format "    %s requests · %s sessions\n"
             (ecc-usage--tokens (alist-get 'request_count window))
             (ecc-usage--tokens (alist-get 'session_count window)))
     (when-let* ((behaviors (alist-get 'behaviors window))
                 ((> (length behaviors) 0)))
       (concat "    "
               (mapconcat
                (lambda (behavior)
                  (let ((key (alist-get 'key behavior)))
                    (format "%s %d%%"
                            (or (cdr (assoc key ecc-usage--behavior-labels)) key)
                            (round (or (alist-get 'pct behavior) 0)))))
                (append behaviors nil) " · ")
               "\n"))
     (ecc-usage--shares "agents" (alist-get 'agents window))
     (ecc-usage--shares "skills" (alist-get 'skills window))
     (ecc-usage--shares "plugins" (alist-get 'plugins window))
     (ecc-usage--shares "MCP servers" (alist-get 'mcp_servers window)))))

(defun ecc-usage--behaviors-section (data)
  "Return the section of DATA saying what has been spending the limits."
  (when-let* ((behaviors (alist-get 'behaviors data)))
    (concat
     (propertize "What is spending the limits\n" 'face 'ecc-heading-face)
     (propertize
      "  Approximate: the sessions on this machine only, not other devices or claude.ai.\n"
      'face 'ecc-dim-face)
     (ecc-usage--window-behaviors "Last 24 hours" (alist-get 'day behaviors))
     (ecc-usage--window-behaviors "Last 7 days" (alist-get 'week behaviors))
     "\n")))

(defun ecc-usage-render (data &optional probe)
  "Return the usage answer DATA drawn as text.
With PROBE the answer came from a CLI started for the question alone,
whose own cost and tokens are zero and say nothing."
  (let ((plan (alist-get 'subscription_type data)))
    (concat
     (propertize (format "Claude Code usage%s\n"
                         (if (stringp plan) (concat " — " plan) ""))
                 'face 'ecc-heading-face)
     (ecc-usage--limits-section data)
     "\n"
     (if probe
         (propertize
          "No session was asked: a CLI was started for this question alone.\n\n"
          'face 'ecc-dim-face)
       (or (ecc-usage--session-section data) ""))
     (or (ecc-usage--behaviors-section data) ""))))

;;;; The buffer

(defvar-local ecc-usage--data nil
  "The last answer drawn in this buffer.")

(defvar ecc-usage-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ecc-usage-refresh)
    (define-key map (kbd "b") #'ecc-usage-toggle-behaviors)
    (define-key map (kbd "q") #'ecc-usage-hide)
    map)
  "Keymap of `ecc-usage-mode'.")

(define-derived-mode ecc-usage-mode special-mode "Claude-Usage"
  "Major mode showing how much of the Claude Code plan is left.

\\{ecc-usage-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

(defun ecc-usage--posframe-p ()
  "Return non-nil when the usage buffer can be floated over the frame."
  (and (eq ecc-usage-display 'posframe)
       (require 'posframe nil t)
       (posframe-workable-p)))

(defun ecc-usage-hide ()
  "Take the usage away."
  (interactive)
  (when-let* ((buffer (get-buffer ecc-usage-buffer-name)))
    (when (and (fboundp 'posframe-hide) (featurep 'posframe))
      (posframe-hide buffer))
    (when-let* ((window (get-buffer-window buffer)))
      (quit-window nil window))))

(defun ecc-usage--show-posframe (buffer)
  "Float BUFFER over the frame and read one key for it.
A child frame takes no focus of its own, so the keys of the usage
buffer are lent to the frame the user is really in until one of them
is done with."
  (posframe-show buffer
                 :position (point)
                 :poshandler #'posframe-poshandler-frame-center
                 :internal-border-width 1
                 :internal-border-color (face-foreground 'shadow nil t)
                 :accept-focus nil
                 :hidehandler nil)
  (set-transient-map
   (let ((map (make-sparse-keymap)))
     (define-key map (kbd "g") #'ecc-usage-refresh)
     (define-key map (kbd "b") #'ecc-usage-toggle-behaviors)
     map)
   ;; Stay up while g and b are being used; the first other key both
   ;; takes it away and does what it was going to do.
   (lambda () (memq this-command '(ecc-usage-refresh ecc-usage-toggle-behaviors)))
   #'ecc-usage-hide))

(defun ecc-usage--draw (text)
  "Put TEXT in the usage buffer, keeping where the user was looking."
  (when-let* ((buffer (get-buffer ecc-usage-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (forward-line (1- line))))
    (when (and (ecc-usage--posframe-p) (get-buffer-window buffer t))
      (ecc-usage--show-posframe buffer))))

(defun ecc-usage--receive (session response)
  "Draw RESPONSE, the usage answer SESSION gave."
  (if-let* ((error-message (alist-get 'error response)))
      (progn
        (ecc-log (ecc-session-name session) "get_usage failed: %s" error-message)
        (ecc-usage--draw
         (propertize (format "The CLI refused the usage request: %s\n"
                             error-message)
                     'face 'ecc-error-face)))
    (with-current-buffer (get-buffer-create ecc-usage-buffer-name)
      (setq ecc-usage--data response))
    (ecc-usage--draw
     (ecc-usage-render response (ecc-model-option session :usage-probe nil)))))

;;;###autoload
(defun ecc-usage ()
  "Show how much of the Claude Code plan has been used.
The CLI is asked for the same numbers the web client shows under
Settings > Usage.  With no session running, one is started for the
question alone and stopped again; no prompt is sent, so it costs
nothing."
  (interactive)
  (let ((buffer (get-buffer-create ecc-usage-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-usage-mode)
        (ecc-usage-mode))
      (when (= (buffer-size) 0)
        (let ((inhibit-read-only t))
          (insert (propertize "Asking the CLI…\n" 'face 'ecc-dim-face)))))
    (ecc-usage--ask #'ecc-usage--receive)
    (if (ecc-usage--posframe-p)
        (ecc-usage--show-posframe buffer)
      (pop-to-buffer buffer))
    buffer))

(defun ecc-usage-refresh ()
  "Ask again."
  (interactive)
  (ecc-usage--ask #'ecc-usage--receive)
  (message "Asking the CLI…"))

(defun ecc-usage-toggle-behaviors ()
  "Turn the section saying what is spending the limits on or off."
  (interactive)
  (setq ecc-usage-skip-behaviors (not ecc-usage-skip-behaviors))
  (message "What is spending the limits: %s"
           (if ecc-usage-skip-behaviors "not asked for" "asked for"))
  (ecc-usage-refresh))

(provide 'ecc-usage)

;;; ecc-usage.el ends here
