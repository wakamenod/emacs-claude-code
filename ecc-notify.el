;;; ecc-notify.el --- Telling the user that Claude wants something  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.12 of IMPLEMENTATION_PLAN.md (FR-NOTIFY-1).  Three events
;; are worth an interruption: a turn that finished, a request that needs
;; an answer, and a session whose CLI stopped on its own.  How loudly
;; they are announced is `ecc-notify-level', and a desktop notification
;; is held back while the Emacs frame has the focus: the user is looking
;; at it already.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-line)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-visual)

(declare-function notifications-notify "notifications" (&rest params))
(declare-function ecc-window-session-visible-p "ecc-window" (session &optional frame))

(defvar ecc-render--session)

(defcustom ecc-notify-level 'message
  "How much noise an event of a session makes (FR-NOTIFY-1).
`message' writes one line in the echo area, `pulse' flashes the
transcript as well, and `desktop' also asks the desktop to show a
notification.  Nil says nothing at all."
  :type '(choice (const :tag "Echo area" message)
                 (const :tag "Echo area and a flash" pulse)
                 (const :tag "Desktop notification" desktop)
                 (const :tag "Nothing" nil))
  :group 'ecc)

(defcustom ecc-notify-events '(turn-finished request exited)
  "Events that are announced (FR-NOTIFY-1)."
  :type '(set (const :tag "A turn finished" turn-finished)
              (const :tag "A request needs an answer" request)
              (const :tag "A session stopped on its own" exited))
  :group 'ecc)

(defcustom ecc-notify-function #'ecc-notify-default
  "Function called with SESSION, EVENT and TEXT to announce something.
Replacing it takes over notification completely (FR-NOTIFY-1)."
  :type 'function
  :group 'ecc)

(defcustom ecc-notify-sound nil
  "Name of the sound a desktop notification plays, or nil for silence.
On macOS this is the name of a system sound such as \"Glass\"."
  :type '(choice (const :tag "Silent" nil) string)
  :group 'ecc)

(defcustom ecc-notify-suppress-when-focused t
  "Non-nil holds desktop notifications back while Emacs has the focus."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-notify-title "Claude Code"
  "Title of a desktop notification."
  :type 'string
  :group 'ecc)

;;;; What is announced

(defun ecc-notify-turn-text (session turn)
  "Return the line announcing that TURN of SESSION finished."
  (let ((result (ecc-turn-result turn)))
    (format "%s: done%s"
            (ecc-session-name session)
            (if-let* ((duration (ecc-model-turn-duration turn)))
                (format " (%.1fs%s)" duration
                        (if (and result (alist-get 'is_error result)) ", error" ""))
              ""))))

(defun ecc-notify-request-text (session request)
  "Return the line announcing REQUEST of SESSION."
  (format "%s: waiting on %s"
          (ecc-session-name session)
          (or (ecc-request-display-name request)
              (ecc-request-tool-name request)
              (format "%s" (ecc-request-kind request)))))

;;;; How it is announced

(defun ecc-notify-focused-p ()
  "Return non-nil when a frame of this Emacs has the input focus."
  (and (display-graphic-p)
       (cl-some (lambda (frame)
                  (eq t (frame-focus-state frame)))
                (frame-list))))

(defun ecc-notify-desktop-p ()
  "Return non-nil when this notification should reach the desktop."
  (and (eq ecc-notify-level 'desktop)
       (not (and ecc-notify-suppress-when-focused (ecc-notify-focused-p)))))

(defun ecc-notify--applescript (text)
  "Return the AppleScript that shows TEXT as a notification."
  (let ((escape (lambda (string)
                  (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" (or string "")))))
    (format "display notification \"%s\" with title \"%s\"%s"
            (funcall escape text)
            (funcall escape ecc-notify-title)
            (if ecc-notify-sound
                (format " sound name \"%s\"" (funcall escape ecc-notify-sound))
              ""))))

(defun ecc-notify-desktop (text)
  "Show TEXT as a desktop notification, as far as this system can."
  (cond
   ((eq system-type 'darwin)
    ;; Asynchronously: osascript takes a moment and nothing waits for it.
    (start-process "ecc-notify" nil "osascript" "-e"
                   (ecc-notify--applescript text)))
   ((fboundp 'notifications-notify)
    (notifications-notify :title ecc-notify-title :body text))
   (t (message "%s" text))))

(defun ecc-notify-pulse (session)
  "Flash the first line of the transcript of SESSION, if it is on screen."
  (require 'pulse)
  (when-let* ((buffer (ecc-session-buffer session))
              (window (and (buffer-live-p buffer) (get-buffer-window buffer t))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (when (fboundp 'pulse-momentary-highlight-region)
          (pulse-momentary-highlight-region (point-min) (line-end-position)))))
    window))

(defun ecc-notify-default (session event text)
  "Announce TEXT about EVENT of SESSION at `ecc-notify-level'."
  (when ecc-notify-level
    (message "%s" text)
    (when (memq ecc-notify-level '(pulse desktop))
      (ecc-notify-pulse session))
    (when (ecc-notify-desktop-p)
      (ecc-notify-desktop text))
    (unless (eq event 'turn-finished)
      (force-mode-line-update t))
    t))

(defun ecc-notify (session event text)
  "Announce TEXT about EVENT of SESSION through `ecc-notify-function'."
  (when (and ecc-notify-level (memq event ecc-notify-events))
    (funcall ecc-notify-function session event text)))

;;;; Wiring (FR-NOTIFY-1)

(defun ecc-notify--turn-finished (session turn)
  "Announce that TURN of SESSION finished."
  (ecc-notify session 'turn-finished (ecc-notify-turn-text session turn)))

(defun ecc-notify--request-added (session request)
  "Announce that REQUEST of SESSION needs an answer."
  (ecc-notify session 'request (ecc-notify-request-text session request)))

(defun ecc-notify--exited (session status)
  "Announce that the CLI of SESSION stopped with STATUS.
A session the user stopped, and one that stopped with status zero, are
not worth a notification."
  (when (and (integerp status) (/= status 0)
             (not (ecc-proc-stopped-on-request-p session)))
    (ecc-notify session 'exited
                (format "%s: the CLI exited with code %s"
                        (ecc-session-name session) status))))

;;;; The tab line of the sessions (FR-NOTIFY-2)

;; Every session is a tab in the tab line of a session window, coloured
;; by what it is doing: running, waiting for an answer, or idle.  Which
;; session the window shows is what the tab line marks as current, and
;; mouse-1 on a tab shows that session in the window the tab was
;; clicked in.
;;
;; The tabs are `tab-line-mode' itself rather than a tab line drawn
;; here: that is where the look of a tab, the scrolling and the
;; click come from.  Only what a tab says, and its colour, are ours.

(defcustom ecc-tab-line t
  "Non-nil lists every session in the tab line of a session window.
`ecc-tab-line-mode' is turned on by the first session started
\(FR-NOTIFY-2)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-tab-bar-state nil
  "Non-nil marks the state of the sessions in the tab bar too.
`ecc-tab-bar-tab-name' has to be `tab-bar-tab-name-function' for this
to have anywhere to show (FR-NOTIFY-2)."
  :type 'boolean
  :group 'ecc)

(defface ecc-tab-running-face
  '((t :inherit (ecc-running-face ecc-heading-face)))
  "Face of the tab of a session that is working.
The yellow green of `ecc-running-face', which the transcript and the
mode line use for the same state, over the weight of a heading."
  :group 'ecc)

(defface ecc-tab-attention-face
  '((t :inherit ecc-pending-face))
  "Face of the tab of a session that is waiting for an answer."
  :group 'ecc)

(defface ecc-tab-idle-face
  '((t :inherit ecc-dim-face))
  "Face of the tab of a session with nothing to do."
  :group 'ecc)

(defcustom ecc-tab-blink t
  "Non-nil blinks the tab of a session that is waiting for an answer.
A tab that wants something is worth more than a colour when the eye is
on the source code.  The rhythm is `ecc-visual-blink-interval', so that
a blinking tab and the blinking line of the request it stands for keep
step (FR-NOTIFY-2, FR-OUT-11 c)."
  :type 'boolean
  :group 'ecc)

(defface ecc-tab-attention-blink-face
  '((t :inherit ecc-tab-attention-face :inverse-video t))
  "Face of a tab waiting for an answer, on every other beat of the blink."
  :group 'ecc)

(defface ecc-tab-current-face
  '((t :inherit (bold ecc-heading-face) :underline t))
  "Face of the tab of the session the window is showing."
  :group 'ecc)

(defvar ecc-tab--blink-phase nil
  "Non-nil on the beat a tab waiting for an answer is drawn lit.")

(defvar ecc-tab--blink-timer nil
  "Timer that blinks the tabs of the sessions waiting for an answer.")

(defun ecc-tab-state (session)
  "Return `attention', `running', `exited' or `idle' for SESSION."
  (cond
   ((ecc-session-pending session) 'attention)
   ((memq (ecc-session-state session) '(starting running compacting)) 'running)
   ((eq (ecc-session-state session) 'exited) 'exited)
   (t 'idle)))

(defun ecc-tab-mark (session)
  "Return the character that stands for the state of SESSION.
A session with nothing to say gets no mark: a row of tabs is quieter
when only the ones that want something are marked."
  (pcase (ecc-tab-state session)
    ('attention "⚠") ('running "▶") ('exited "✗") (_ "")))

(defun ecc-tab-faces (session current)
  "Return the faces to lay over the tab of SESSION, the telling one first.
CURRENT says the window is showing this session.  The state comes
first so that its colour wins, and `ecc-tab-current-face' follows to
add what it alone says -- the weight and the underline that mark the
tab one is looking at.  Putting `current' first instead, as this did
before, cost the tab of the session in front of you the very colour
that says what it is doing.  An idle tab is the one exception, and is
left to `ecc-tab-current-face' alone."
  (let ((state (if (and ecc-tab--blink-phase
                        (eq (ecc-tab-state session) 'attention))
                   'ecc-tab-attention-blink-face
                 (pcase (ecc-tab-state session)
                   ('attention 'ecc-tab-attention-face)
                   ('running 'ecc-tab-running-face)
                   ('exited 'ecc-error-face)
                   (_ 'ecc-tab-idle-face)))))
    (cond
     ;; Idle is not a colour so much as the want of one: the dim face
     ;; is there to sink the sessions with nothing to say into the
     ;; background, and the one being read does not belong there.  Dim
     ;; and current together read as neither.
     ((and current (eq state 'ecc-tab-idle-face))
      (list 'ecc-tab-current-face))
     (current (list state 'ecc-tab-current-face))
     (t (list state)))))

(defun ecc-tab-line-tabs ()
  "Return the session buffers, oldest session first (FR-NOTIFY-2).
This is `tab-line-tabs-function' in a session buffer.  The registry is
kept most recently used first, which is the wrong order for a row of
tabs -- they would move about as one works -- so the sessions are put
back into the order they were made in."
  (let ((sessions (sort (copy-sequence (ecc-model-sessions))
                        (lambda (a b)
                          (< (or (ecc-session-created a) 0)
                             (or (ecc-session-created b) 0))))))
    (seq-filter #'buffer-live-p (mapcar #'ecc-session-buffer sessions))))

(defun ecc-tab-line-tab-name (buffer &optional _tabs)
  "Return what the tab of BUFFER says (`tab-line-tab-name-function')."
  (let ((session (and (buffer-live-p buffer)
                      (buffer-local-value 'ecc-render--session buffer))))
    (if (not session)
        (buffer-name buffer)
      (let ((mark (ecc-tab-mark session)))
        (format " %s%s "
                (if (string-empty-p mark) "" (concat mark " "))
                (ecc--truncate (ecc-session-name session) 20))))))

(defun ecc-tab-line-tab-face (tab _tabs face buffer-p selected-p)
  "Colour the tab of a session by its state (`tab-line-tab-face-functions').
TAB is a buffer when BUFFER-P, and SELECTED-P says it is the one the
window shows.  FACE is what the tab line settled on, which is kept
underneath so that the theme still decides the shape of a tab."
  (let* ((buffer (if buffer-p tab (cdr (assq 'buffer tab))))
         (session (and (buffer-live-p buffer)
                       (buffer-local-value 'ecc-render--session buffer))))
    (if session
        `(:inherit (,@(ecc-tab-faces session selected-p) ,face))
      face)))

(defvar ecc-tab-line-mode)

(defun ecc-tab-line--install (&rest _)
  "Put the tab line in every session buffer, or take it out again.
The tabs are the ones of `tab-line-mode' itself, so that they look and
behave like tabs: clicking one shows that session in the window the tab
was clicked in, which is the whole point of them (FR-NOTIFY-2)."
  (dolist (session (ecc-model-sessions))
    (when-let* ((buffer (ecc-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (cond
           (ecc-tab-line-mode
            (setq-local tab-line-tabs-function #'ecc-tab-line-tabs
                        tab-line-tab-name-function #'ecc-tab-line-tab-name
                        tab-line-tab-face-functions '(ecc-tab-line-tab-face))
            (tab-line-mode 1))
           (t
            (tab-line-mode -1)
            (kill-local-variable 'tab-line-tabs-function)
            (kill-local-variable 'tab-line-tab-name-function)
            (kill-local-variable 'tab-line-tab-face-functions)))))))
  ;; A tab line is cached per window on a key that does not know a
  ;; session's state, so a state that changed needs the cache cleared
  ;; rather than a redisplay alone.
  (tab-line-force-update t)
  (ecc-tab-blink-update))

;;;; Blinking the tabs that want an answer (FR-NOTIFY-2, FR-OUT-11 c)

(defun ecc-tab--waiting-p ()
  "Return non-nil when some session is waiting for an answer."
  (seq-some (lambda (session) (eq (ecc-tab-state session) 'attention))
            (ecc-model-sessions)))

(defun ecc-tab--windows ()
  "Return the windows showing a session buffer, on any frame."
  (let (windows)
    (dolist (session (ecc-model-sessions))
      (let ((buffer (ecc-session-buffer session)))
        (when (buffer-live-p buffer)
          (setq windows (nconc (get-buffer-window-list buffer nil t) windows)))))
    windows))

(defun ecc-tab--blink-redisplay ()
  "Draw the tab lines of the session windows again.
The tab line of a window is cached on a key that knows nothing of the
blink, so the cache is what has to go; a redisplay on its own would
show the same tabs over again."
  (when-let* ((windows (ecc-tab--windows)))
    (dolist (window windows)
      (set-window-parameter window 'tab-line-cache nil))
    (force-mode-line-update t)
    windows))

(defun ecc-tab-blink-stop ()
  "Stop the blink and leave the waiting tabs lit no longer."
  (when ecc-tab--blink-timer
    (cancel-timer ecc-tab--blink-timer)
    (setq ecc-tab--blink-timer nil))
  (when ecc-tab--blink-phase
    (setq ecc-tab--blink-phase nil)
    (ecc-tab--blink-redisplay)))

(defun ecc-tab--blink-tick ()
  "Turn the waiting tabs on or off, and stop once nothing is waiting."
  (if (not (and ecc-tab-line-mode ecc-tab-blink (ecc-tab--waiting-p)))
      (ecc-tab-blink-stop)
    (setq ecc-tab--blink-phase (not ecc-tab--blink-phase))
    ;; A session with no window costs only this: there is nothing on the
    ;; screen to draw again.
    (ecc-tab--blink-redisplay)))

(defun ecc-tab-blink-update ()
  "Blink the tabs while a session waits for an answer, and stop after.
Called from `ecc-tab-line--install', which every event that changes
what a tab says already goes through."
  (if (and ecc-tab-line-mode ecc-tab-blink (ecc-tab--waiting-p))
      (unless ecc-tab--blink-timer
        (setq ecc-tab--blink-timer
              (run-at-time ecc-visual-blink-interval ecc-visual-blink-interval
                           #'ecc-tab--blink-tick)))
    (ecc-tab-blink-stop)))

(define-minor-mode ecc-tab-line-mode
  "List every session in the tab line of the session windows (FR-NOTIFY-2)."
  :global t
  :group 'ecc
  (if ecc-tab-line-mode
      (progn
        (add-hook 'ecc-session-state-changed-hook #'ecc-tab-line--install)
        (add-hook 'ecc-request-added-hook #'ecc-tab-line--install)
        (add-hook 'ecc-request-resolved-hook #'ecc-tab-line--install)
        (add-hook 'ecc-session-init-hook #'ecc-tab-line--install))
    (remove-hook 'ecc-session-state-changed-hook #'ecc-tab-line--install)
    (remove-hook 'ecc-request-added-hook #'ecc-tab-line--install)
    (remove-hook 'ecc-request-resolved-hook #'ecc-tab-line--install)
    (remove-hook 'ecc-session-init-hook #'ecc-tab-line--install))
  (ecc-tab-line--install))

(defun ecc-tab-bar-tab-name ()
  "Return the name of the current tab, marked with the state of its sessions.
Set `tab-bar-tab-name-function' to this to see in the tab bar which
tab is waiting for an answer (FR-NOTIFY-2)."
  (let* ((name (funcall (default-value 'tab-bar-tab-name-function)))
         (sessions (seq-filter (lambda (session)
                                 (when-let* ((buffer (ecc-session-buffer session)))
                                   (get-buffer-window buffer)))
                               (ecc-model-sessions)))
         (state (cond ((null sessions) nil)
                      ((seq-find (lambda (session)
                                   (eq (ecc-tab-state session) 'attention))
                                 sessions)
                       'attention)
                      ((seq-find (lambda (session)
                                   (eq (ecc-tab-state session) 'running))
                                 sessions)
                       'running))))
    (if (and ecc-tab-bar-state state)
        (format "%s %s"
                (pcase state ('attention "⚠") (_ "▶"))
                name)
      name)))

(define-minor-mode ecc-notify-mode
  "Announce what the sessions of this Emacs are waiting for (FR-NOTIFY-1)."
  :global t
  :group 'ecc
  (if ecc-notify-mode
      (progn
        (add-hook 'ecc-turn-finished-hook #'ecc-notify--turn-finished)
        (add-hook 'ecc-request-added-hook #'ecc-notify--request-added)
        (add-hook 'ecc-session-exited-hook #'ecc-notify--exited))
    (remove-hook 'ecc-turn-finished-hook #'ecc-notify--turn-finished)
    (remove-hook 'ecc-request-added-hook #'ecc-notify--request-added)
    (remove-hook 'ecc-session-exited-hook #'ecc-notify--exited)))

(provide 'ecc-notify)

;;; ecc-notify.el ends here
