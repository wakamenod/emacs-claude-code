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
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)

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
;; mouse-1 on a tab switches to it.

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
  '((t :inherit ecc-heading-face))
  "Face of the tab of a session that is working."
  :group 'ecc)

(defface ecc-tab-attention-face
  '((t :inherit ecc-pending-face))
  "Face of the tab of a session that is waiting for an answer."
  :group 'ecc)

(defface ecc-tab-idle-face
  '((t :inherit ecc-dim-face))
  "Face of the tab of a session with nothing to do."
  :group 'ecc)

(defface ecc-tab-current-face
  '((t :inherit (bold ecc-heading-face) :underline t))
  "Face of the tab of the session the window is showing."
  :group 'ecc)

(defun ecc-tab-state (session)
  "Return `attention', `running', `exited' or `idle' for SESSION."
  (cond
   ((ecc-session-pending session) 'attention)
   ((memq (ecc-session-state session) '(starting running compacting)) 'running)
   ((eq (ecc-session-state session) 'exited) 'exited)
   (t 'idle)))

(defun ecc-tab-mark (session)
  "Return the character that stands for the state of SESSION."
  (pcase (ecc-tab-state session)
    ('attention "⚠") ('running "●") ('exited "✗") (_ "·")))

(defun ecc-tab-face (session current)
  "Return the face of the tab of SESSION, CURRENT saying whether it is shown."
  (if current
      'ecc-tab-current-face
    (pcase (ecc-tab-state session)
      ('attention 'ecc-tab-attention-face)
      ('running 'ecc-tab-running-face)
      ('exited 'ecc-error-face)
      (_ 'ecc-tab-idle-face))))

(defun ecc-tab-label (session &optional current)
  "Return the tab of SESSION, CURRENT saying whether it is the one shown."
  (propertize (format " %s %s " (ecc-tab-mark session)
                      (ecc--truncate (ecc-session-name session) 20))
              'face (ecc-tab-face session current)
              'help-echo (format "%s: %s" (ecc-session-name session)
                                 (ecc-tab-state session))
              'mouse-face 'tab-line-highlight
              'keymap (let ((map (make-sparse-keymap)))
                        (define-key map [tab-line mouse-1]
                                    (lambda ()
                                      (interactive)
                                      (ecc-tab-line-visit session)))
                        map)))

(defun ecc-tab-line-visit (session)
  "Show SESSION in the window the tab was clicked in."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (pop-to-buffer buffer))))

(defun ecc-tab-line-string (&optional buffer)
  "Return the tab line listing every session, from BUFFER's point of view."
  (let* ((buffer (or buffer (current-buffer)))
         (current (buffer-local-value 'ecc-render--session buffer)))
    (ecc--mode-line-escape
     (mapconcat (lambda (session)
                  (ecc-tab-label session (eq session current)))
                (ecc-model-sessions)
                ""))))

(defconst ecc-tab-line--construct '(:eval (ecc-tab-line-string))
  "What `ecc-tab-line-mode' puts in `tab-line-format'.")

(defvar ecc-tab-line-mode)

(defun ecc-tab-line--install (&rest _)
  "Put the tab line in every session buffer, or take it out again."
  (dolist (session (ecc-model-sessions))
    (when-let* ((buffer (ecc-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq-local tab-line-format
                      (and ecc-tab-line-mode ecc-tab-line--construct))))))
  (force-mode-line-update t))

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
                (pcase state ('attention "⚠") (_ "●"))
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
