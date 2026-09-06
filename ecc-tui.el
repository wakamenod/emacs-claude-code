;;; ecc-tui.el --- Hand a session over to the real terminal UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.14 of IMPLEMENTATION_PLAN.md (FR-TUI-1 to FR-TUI-5).  The
;; terminal client can do things this one cannot, so a conversation can
;; be carried on there and taken back afterwards.
;;
;; The CLI has no lock on a session: two processes resuming the same id
;; write into the same recording and the conversation quietly grows a
;; second branch (docs/verified.md).  The hand-off is therefore not a
;; second window on the session but a change of hands: the process
;; Emacs runs is interrupted and stopped first, and the terminal is only
;; started once it is gone (FR-TUI-5).
;;
;; While the terminal has it, the buffer follows the recording the CLI
;; writes (FR-TUI-3): the lines the terminal appends are replayed
;; through `ecc-history', so the transcript keeps up without a process
;; of its own.  When the terminal is left, the session comes back
;; headless with --resume (FR-TUI-4).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'filenotify)
(require 'format-spec)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-registry)
(require 'ecc-history)

(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-window-resolve-session "ecc-window" (&optional force-ask))
(declare-function vterm "vterm" (&optional arg))
(defvar vterm-shell)
(defvar vterm-exit-functions)

;;;; Options

(defcustom ecc-tui-terminal 'vterm
  "Where a session handed over is opened (FR-TUI-1, FR-TUI-2).
`vterm' runs the CLI in a vterm buffer, `external' runs
`ecc-tui-external-command' instead."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "An external terminal" external))
  :group 'ecc)

(defcustom ecc-tui-external-command
  "open -na Ghostty --args -e %c --resume %i"
  "Shell command that opens the CLI in an external terminal (FR-TUI-2).
The specifications are %c the CLI executable, %i the session id and %d
the directory the session runs in."
  :type 'string
  :group 'ecc)

(defcustom ecc-tui-extra-args nil
  "Extra arguments passed to the CLI started in a terminal."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-tui-interrupt-timeout 10
  "Seconds to wait for a running turn to stop before the process is killed."
  :type 'number
  :group 'ecc)

(defcustom ecc-tui-follow t
  "Non-nil follows the recording while a session is open in a terminal.
This is what keeps the transcript current during a hand-off
\(FR-TUI-3); turning it off leaves the buffer as it was until the
session comes back."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-tui-poll-interval 2
  "Seconds between the checks made while a session is in a terminal.
A file notification is a courtesy rather than a promise, and an
external terminal has to be watched through the session registry, so
the timer runs even when the recording is being watched."
  :type 'number
  :group 'ecc)

(defcustom ecc-tui-return-on-exit t
  "Non-nil resumes a session in Emacs once its terminal is left (FR-TUI-4)."
  :type 'boolean
  :group 'ecc)

;;;; What is being handed over

(defvar ecc-tui--handoffs (make-hash-table :test #'equal)
  "Hash mapping a session id to the state of its hand-off.
The value is a plist with `:file' and `:position' for the recording
being followed, `:watch' its file notification descriptor, `:timer'
the poll timer, `:buffer' the terminal buffer when there is one and
`:seen' non-nil once the terminal has shown up in the registry.")

(defun ecc-tui-state (session)
  "Return the hand-off state of SESSION, or nil."
  (gethash (ecc-session-id session) ecc-tui--handoffs))

(defun ecc-tui--put (session key value)
  "Set KEY of the hand-off state of SESSION to VALUE."
  (puthash (ecc-session-id session)
           (plist-put (or (ecc-tui-state session) nil) key value)
           ecc-tui--handoffs))

(defun ecc-tui-handoff-p (session)
  "Return non-nil when SESSION is being driven from a terminal."
  (and (ecc-tui-state session) t))

(defun ecc-tui-sessions ()
  "Return the sessions that are open in a terminal."
  (seq-filter #'ecc-tui-handoff-p (ecc-model-sessions)))

;;;; The command the terminal runs

(defun ecc-tui-arguments (session)
  "Return the command line that opens SESSION in a terminal.
It is the interactive CLI, not the headless one this package drives:
no stream-json, no permission prompt tool, only the session to resume
and the options that decide what it costs."
  (append (list ecc-executable "--resume" (ecc-session-id session))
          (when-let* ((model (ecc-model-option session :model ecc-model)))
            (list "--model" model))
          (when-let* ((budget (ecc-model-option session :max-budget-usd
                                                ecc-max-budget-usd)))
            (list "--max-budget-usd" (format "%s" budget)))
          ecc-tui-extra-args))

(defun ecc-tui-shell-command (session)
  "Return the command that opens SESSION in a terminal, as one shell line."
  (mapconcat #'shell-quote-argument (ecc-tui-arguments session) " "))

(defun ecc-tui-external-command (session)
  "Return the shell command that opens SESSION in an external terminal."
  (format-spec ecc-tui-external-command
               `((?c . ,ecc-executable)
                 (?i . ,(ecc-session-id session))
                 (?d . ,(or (ecc-session-cwd session)
                            (ecc-session-project-root session) "")))))

;;;; Making sure nobody else has it (FR-TUI-5)

(defun ecc-tui--other-process (session)
  "Return the registry entry of another process running SESSION, or nil.
The process this Emacs runs is not another process."
  (let* ((entry (ecc-registry-session (ecc-session-id session)))
         (pid (and entry (alist-get 'pid entry)))
         (process (ecc-session-process session))
         (ours (and (processp process) (process-live-p process)
                    (process-id process))))
    (and pid (not (equal pid ours)) entry)))

(defun ecc-tui--release (session)
  "Stop the process Emacs runs for SESSION, so a terminal may have it.
A running turn is interrupted first and given `ecc-tui-interrupt-timeout'
seconds to come to an end, because a turn stopped mid-tool leaves the
CLI to write the result of a call that will never finish.  Signals when
the process cannot be stopped: two processes on one session id branch
the conversation without saying so (FR-TUI-5)."
  (let ((process (ecc-session-process session)))
    (when (process-live-p process)
      (when (eq (ecc-session-state session) 'running)
        (ecc-proc-interrupt session)
        (let ((deadline (+ (float-time) ecc-tui-interrupt-timeout)))
          (while (and (eq (ecc-session-state session) 'running)
                      (process-live-p process)
                      (< (float-time) deadline))
            (accept-process-output process 0.2))))
      (ecc-proc-stop session))
    (when (process-live-p (ecc-session-process session))
      (user-error "%s could not be stopped; the terminal would branch the conversation"
                  (ecc-session-name session)))))

;;;; Opening the terminal (FR-TUI-1, FR-TUI-2)

(defun ecc-tui-buffer-name (session)
  "Return the name of the terminal buffer of SESSION."
  (format "*ecc-tui: %s*" (ecc-session-name session)))

(defun ecc-tui--open-vterm (session)
  "Open SESSION in a vterm buffer and return it.
The CLI is run as the shell of the buffer rather than typed into one,
so that leaving it ends the buffer and Emacs can tell (FR-TUI-4)."
  (unless (require 'vterm nil t)
    (user-error "vterm is not installed; set `ecc-tui-terminal' to `external'"))
  (let* ((default-directory (or (ecc-session-cwd session)
                                (ecc-session-project-root session)
                                default-directory))
         (vterm-shell (ecc-tui-shell-command session))
         (buffer (save-window-excursion (vterm (ecc-tui-buffer-name session)))))
    (add-hook 'vterm-exit-functions #'ecc-tui--vterm-exited)
    buffer))

(defun ecc-tui--open-external (session)
  "Open SESSION in an external terminal and return the process."
  (let ((default-directory (or (ecc-session-cwd session)
                               (ecc-session-project-root session)
                               default-directory))
        (command (ecc-tui-external-command session)))
    (ecc-log (ecc-session-name session) "terminal: %s" command)
    (start-process-shell-command
     (format "ecc-tui-%s" (ecc-session-name session)) nil command)))

;;;###autoload
(defun ecc-tui-open (&optional session)
  "Carry on with SESSION in the real terminal UI (FR-TUI-1).
The turn in flight is interrupted, the process Emacs runs is stopped,
and the terminal resumes the same conversation.  The transcript
follows along and the session comes back when the terminal is left."
  (interactive)
  (let ((session (or session (ecc-window-resolve-session))))
    (when-let* ((entry (ecc-tui--other-process session)))
      (user-error "%s is already running as pid %s; stop it before handing over"
                  (or (alist-get 'name entry) (ecc-session-name session))
                  (or (alist-get 'pid entry) "?")))
    (when (ecc-tui-handoff-p session)
      (user-error "%s is already open in a terminal" (ecc-session-name session)))
    (ecc-tui--release session)
    (setf (ecc-session-kind session) 'handoff)
    (ecc-tui--put session :seen nil)
    (ecc-tui-follow-start session)
    (let ((opened (pcase ecc-tui-terminal
                    ('external (ecc-tui--open-external session))
                    (_ (ecc-tui--open-vterm session)))))
      (when (bufferp opened)
        (ecc-tui--put session :buffer opened)))
    (ecc-tui--start-timer session)
    (ecc-render-refresh session)
    (message "%s is in the terminal now; it comes back when you leave it"
             (ecc-session-name session))
    session))

;;;; Following the recording (FR-TUI-3)

(defun ecc-tui-follow-start (session)
  "Start following the recording of SESSION from where it stands now.
What the recording already holds is on screen; only what the terminal
appends from here on is replayed."
  (let ((file (ecc-history-file (ecc-session-id session))))
    (ecc-tui--put session :file file)
    (ecc-tui--put session :position (if file (ecc-tui--file-size file) 0))
    (when (and file ecc-tui-follow)
      (ecc-tui--watch session file))
    file))

(defun ecc-tui--file-size (file)
  "Return the size of FILE in bytes, or 0 when it is not there."
  (or (file-attribute-size (file-attributes file)) 0))

(defun ecc-tui--watch (session file)
  "Watch FILE and read what is appended to it into SESSION."
  (let ((id (ecc-session-id session)))
    (ecc-tui--put session :watch
                  (ignore-errors
                    (file-notify-add-watch
                     file '(change)
                     (lambda (&rest _)
                       (when-let* ((session (ecc-model-session id)))
                         (ecc-tui-read-new-lines session))))))))

(defun ecc-tui-read-new-lines (session)
  "Replay into SESSION whatever the terminal appended to its recording.
Returns the number of lines read.  Only whole lines are taken: a
notification can arrive while the CLI is halfway through writing one."
  (let* ((state (ecc-tui-state session))
         (file (or (plist-get state :file)
                   (let ((found (ecc-history-file (ecc-session-id session))))
                     (when found
                       (ecc-tui--put session :file found)
                       (ecc-tui--put session :position 0)
                       (when ecc-tui-follow (ecc-tui--watch session found))
                       found))))
         (from (or (plist-get state :position) 0))
         (size (and file (ecc-tui--file-size file))))
    (cond
     ((or (null file) (null size)) 0)
     ;; The recording was replaced under us; start again from its end
     ;; rather than replaying a file that has nothing to do with what is
     ;; on screen.
     ((< size from) (ecc-tui--put session :position size) 0)
     ((= size from) 0)
     (t
      (let* ((text (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8-unix))
                       (insert-file-contents file nil from size))
                     (buffer-string)))
             (cut (string-match-p "\n[^\n]*\\'" text))
             (whole (if cut (substring text 0 (1+ cut)) nil))
             (lines (and whole (split-string whole "\n" t))))
        (if (null lines)
            0
          (ecc-tui--put session :position (+ from (string-bytes whole)))
          (prog1 (length lines)
            (ecc-history--replay session lines)
            (ecc-render-refresh session))))))))

(defun ecc-tui-follow-stop (session)
  "Stop following the recording of SESSION and forget the hand-off."
  (when-let* ((state (ecc-tui-state session)))
    (when-let* ((watch (plist-get state :watch)))
      (ignore-errors (file-notify-rm-watch watch)))
    (when-let* ((timer (plist-get state :timer)))
      (cancel-timer timer)))
  (remhash (ecc-session-id session) ecc-tui--handoffs))

;;;; Noticing that the terminal is done (FR-TUI-4)

(defun ecc-tui--start-timer (session)
  "Start the timer that watches over the hand-off of SESSION."
  (let ((id (ecc-session-id session)))
    (ecc-tui--put session :timer
                  (run-with-timer ecc-tui-poll-interval ecc-tui-poll-interval
                                  (lambda ()
                                    (if-let* ((session (ecc-model-session id)))
                                        (ecc-tui--tick session)
                                      (ecc-tui--forget id)))))))

(defun ecc-tui--forget (id)
  "Cancel the hand-off of the session ID that is no longer there."
  (when-let* ((state (gethash id ecc-tui--handoffs)))
    (when-let* ((watch (plist-get state :watch)))
      (ignore-errors (file-notify-rm-watch watch)))
    (when-let* ((timer (plist-get state :timer)))
      (cancel-timer timer))
    (remhash id ecc-tui--handoffs)))

(defun ecc-tui--tick (session)
  "Read what the terminal wrote for SESSION and see whether it is over."
  (condition-case err
      (progn
        (when ecc-tui-follow (ecc-tui-read-new-lines session))
        (when (ecc-tui-finished-p session)
          (if ecc-tui-return-on-exit
              (ecc-tui-return session)
            (ecc-tui-follow-stop session))))
    (error (ecc-log (ecc-session-name session) "hand-off: %s"
                    (error-message-string err)))))

(defun ecc-tui-finished-p (session)
  "Return non-nil when the terminal that had SESSION is gone.
A vterm buffer answers for itself.  An external terminal is only
visible in the session registry, so it counts as finished once it has
been seen there and is there no longer; a terminal that never showed
up is waited for rather than given up on."
  (let* ((state (ecc-tui-state session))
         (buffer (plist-get state :buffer)))
    (cond
     ((bufferp buffer) (not (buffer-live-p buffer)))
     ((ecc-registry-live-p (ecc-session-id session))
      (ecc-tui--put session :seen t)
      nil)
     (t (and (plist-get state :seen) t)))))

(defun ecc-tui--vterm-exited (buffer &optional _event)
  "Take back the session whose terminal BUFFER has just ended."
  (when-let* ((session (seq-find (lambda (session)
                                   (eq (plist-get (ecc-tui-state session) :buffer)
                                       buffer))
                                 (ecc-tui-sessions))))
    (ecc-tui--put session :buffer nil)
    (when ecc-tui-return-on-exit
      (ecc-tui-return session))))

;;;###autoload
(defun ecc-tui-return (&optional session)
  "Take SESSION back from the terminal and run it in Emacs again (FR-TUI-4).
Whatever the terminal added is read first, so that nothing is missed,
and the session is then resumed headless.  A terminal that is still
running keeps the session: resuming it now would branch the
conversation."
  (interactive)
  (let ((session (or session (ecc-window-resolve-session))))
    (when (ecc-tui-handoff-p session)
      (when ecc-tui-follow (ecc-tui-read-new-lines session))
      (ecc-tui-follow-stop session))
    (setf (ecc-session-kind session) 'own)
    (cond
     ((process-live-p (ecc-session-process session)) session)
     ((ecc-registry-live-p (ecc-session-id session))
      (message "%s is still open in a terminal" (ecc-session-name session))
      nil)
     (t
      (require 'ecc-session)
      (ecc-session-ensure-buffer session)
      (ecc-proc-start session t)
      (message "%s is back in Emacs" (ecc-session-name session))
      session))))

(provide 'ecc-tui)

;;; ecc-tui.el ends here
