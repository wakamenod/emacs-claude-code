;;; ecc-transient.el --- One menu for every ecc command  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1") (transient "0.7.0"))

;;; Commentary:

;; One place to reach the whole package from.  `ecc-menu' reaches every
;; command worth a key; the slash command submenu is built from what the
;; CLI said in its initialize answer, so it shows the skills and the
;; plugin commands of the session at hand rather than a fixed list.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'transient)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-window)
(require 'ecc-prompt)
(require 'ecc-context)
(require 'ecc-notify)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-resume "ecc" (session &optional fork))
(declare-function ecc-read-session "ecc" (&optional prompt))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-dashboard "ecc-dashboard" ())
(declare-function ecc-capabilities-show "ecc-dashboard" (session))
(declare-function ecc-inline-prompt "ecc-inline" (question))
(declare-function ecc-rewrite "ecc-inline" (beg end instruction))
(declare-function ecc-next-attention "ecc-answer" (&optional project-root))
(declare-function ecc-next-attention-in-project "ecc-answer" ())
(declare-function ecc-answer-option-1 "ecc-answer" ())
(declare-function ecc-answer-option-2 "ecc-answer" ())
(declare-function ecc-answer-option-3 "ecc-answer" ())
(declare-function ecc-answer-option-4 "ecc-answer" ())
(declare-function ecc-answer-allow "ecc-answer" ())
(declare-function ecc-answer-deny "ecc-answer" (reason))
(declare-function ecc-perm-allow-all "ecc-perm" (&optional remember))
(declare-function ecc-review "ecc-review" (&optional session paths))
(declare-function ecc-session-timeline "ecc-session" ())
(declare-function ecc-chat-goto-files "ecc-chat" ())
(declare-function ecc-chat-goto-plans "ecc-chat" ())
(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-history-open "ecc-history" (session-id))
(declare-function ecc-tui-open "ecc-tui" (&optional session))
(declare-function ecc-tui-return "ecc-tui" (&optional session))

;;;; Commands the menu needs of its own

(defun ecc-menu-session ()
  "Return the session the menu acts on."
  (ecc-window-resolve-session))

;;;###autoload
(defun ecc-show-session ()
  "Show the session this buffer talks to and go to its prompt.
The window comes back and the point lands where something can be
typed."
  (interactive)
  (let ((session (ecc-menu-session)))
    (ecc-window-select-session session)
    session))

;;;###autoload
(defun ecc-interrupt ()
  "Interrupt the running turn of the session this buffer talks to."
  (interactive)
  (let ((session (ecc-menu-session)))
    (ecc-proc-interrupt session)
    (message "%s: interrupt sent" (ecc-session-name session))))

;;;###autoload
(defun ecc-set-permission-mode (mode)
  "Ask the session this buffer talks to to switch to permission MODE."
  (interactive
   (list (completing-read "Permission mode: "
                          '("default" "acceptEdits" "plan" "auto"
                            "bypassPermissions")
                          nil t)))
  (let ((session (ecc-menu-session)))
    (ecc-proc-set-permission-mode session mode)
    (message "%s: switching to %s" (ecc-session-name session) mode)))


;;;###autoload
(defun ecc-remote-control-toggle ()
  "Turn Remote Control on or off for the session this buffer talks to.
With it on the session shows up in the Code tab of the Claude app and
can be driven from there; whether it starts that way is up to the
Claude Code settings, which this package follows."
  (interactive)
  (let* ((session (ecc-menu-session))
         (on (ecc-model-remote-control session 'enabled)))
    (unless (or on (ecc-model-remote-control session 'available))
      (user-error "%s cannot offer Remote Control%s" (ecc-session-name session)
                  (if (ecc-session-init session) ""
                    " yet; the CLI has not answered initialize")))
    (unless (or on (ecc-proc-remote-control-offerable-p session))
      (user-error "%s is not a session Remote Control accepts (an untrusted \
or internal workspace)" (ecc-session-name session)))
    (ecc-proc-remote-control session (not on)
                             (lambda (session reason)
                               (message "%s: remote control refused: %s"
                                        (ecc-session-name session) reason)))
    (message "%s: turning remote control %s" (ecc-session-name session)
             (if on "off" "on"))))

(defun ecc-remote-control--url (session)
  "Return the URL that opens SESSION away from Emacs, or signal."
  (or (ecc-model-remote-control session 'session-url)
      (user-error "%s is not on the Remote Control bridge"
                  (ecc-session-name session))))

;;;###autoload
(defun ecc-remote-control-open ()
  "Open the session this buffer talks to at claude.ai/code."
  (interactive)
  (browse-url (ecc-remote-control--url (ecc-menu-session))))

;;;###autoload
(defun ecc-remote-control-copy-url ()
  "Put the claude.ai/code URL of this session in the kill ring."
  (interactive)
  (let ((url (ecc-remote-control--url (ecc-menu-session))))
    (kill-new url)
    (message "%s" url)))

;;;###autoload
(defun ecc-set-model (model)
  "Ask the session this buffer talks to to use MODEL.
The CLI answers a /model command even when it is driven headless, so
the model can be changed without restarting it."
  (interactive
   (let* ((session (ecc-menu-session))
          (current (ecc-prompt-current-model session)))
     (list (completing-read (if current
                                (format "Model (currently %s): " current)
                              "Model: ")
                            (ecc-prompt-model-candidates session)))))
  (let ((session (ecc-menu-session)))
    (ecc-proc-send-prompt session (concat "/model " model))
    model))

;;;###autoload
(defun ecc-show-log ()
  "Show the raw protocol log of the session this buffer talks to."
  (interactive)
  (pop-to-buffer (ecc--log-buffer (ecc-session-name (ecc-menu-session)))))

(defun ecc-menu--in-session (command)
  "Show the transcript of the session at hand and run COMMAND there.
The commands that move around a transcript need its window, not just
its buffer."
  (require 'ecc-session)
  (let ((session (ecc-menu-session)))
    (select-window (ecc-display-session session))
    (call-interactively command)))

;;;###autoload
(defun ecc-goto-files ()
  "Move to the Files section of the session this buffer talks to."
  (interactive)
  (ecc-menu--in-session #'ecc-chat-goto-files))

;;;###autoload
(defun ecc-goto-plan ()
  "Move to the Plan section of the session this buffer talks to."
  (interactive)
  (ecc-menu--in-session #'ecc-chat-goto-plans))

;;;###autoload
(defun ecc-timeline ()
  "Pick a turn of the session this buffer talks to."
  (interactive)
  (ecc-menu--in-session #'ecc-session-timeline))

;;;###autoload
(defun ecc-customize ()
  "Open the customization group of this package."
  (interactive)
  (customize-group 'ecc))

;;;; The slash command submenu

(defconst ecc-transient--keys
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  "Characters handed out as keys of a generated suffix.")

(defvar ecc-transient--slash-commands (make-hash-table :test #'equal)
  "Commands generated for a slash command, keyed by its name.")

(defun ecc-transient-slash-command (name)
  "Return a command that sends the slash command NAME.
The command is interned once and reused, so that the menu keeps the
same suffix from one call to the next."
  (or (gethash name ecc-transient--slash-commands)
      (let ((symbol (intern (format "ecc-slash%s" name))))
        (defalias symbol
          (lambda ()
            (interactive)
            (let* ((session (ecc-menu-session))
                   (argument (when (ecc-prompt-interactive-command-p session name)
                               (ecc-prompt-read-argument name session)))
                   (text (if argument (concat name " " argument) name)))
              ;; The menu is another way to run what the prompt region
              ;; runs, so a command Emacs answers itself -- /btw -- must
              ;; not be sent from here either.
              (if (run-hook-with-args-until-success
                   'ecc-prompt-intercept-functions session text)
                  (message "%s was answered by Emacs" name)
                (ecc-proc-send-prompt session text)
                (message "Sent %s to %s" text (ecc-session-name session)))))
          (format "Send the slash command %s to the session at hand." name))
        (puthash name symbol ecc-transient--slash-commands)
        symbol)))

(defun ecc-transient-slash-suffixes (&optional session)
  "Return the suffix specifications for the slash commands of SESSION."
  (let* ((session (or session (ecc-menu-session)))
         (commands (ecc-prompt-offered-commands session))
         (terminal (ecc-prompt-terminal-commands session))
         (limit (length ecc-transient--keys)))
    (seq-map-indexed
     (lambda (command index)
       (let ((name (car command)))
         (list (string (aref ecc-transient--keys index))
               (string-trim
                (format "%s %s%s" name
                        (if (member name terminal) "[terminal UI] " "")
                        (ecc--truncate (cdr command) 48)))
               (ecc-transient-slash-command name))))
     (seq-take commands limit))))

;;;###autoload
(defun ecc-slash-command (name)
  "Send the slash command NAME, chosen with completion."
  (interactive
   (let* ((session (ecc-window-resolve-session))
          (commands (ecc-prompt-offered-commands session)))
     (list (completing-read "Slash command: " (mapcar #'car commands) nil nil "/"))))
  (funcall (ecc-transient-slash-command name)))

(defun ecc-transient--setup-slash (_children)
  "Return the children of `ecc-slash-menu', built from the session."
  (transient-parse-suffixes 'ecc-slash-menu (ecc-transient-slash-suffixes)))

;;;###autoload (autoload 'ecc-slash-menu "ecc-transient" nil t)
(transient-define-prefix ecc-slash-menu ()
  "Slash commands the session at hand knows about."
  [:description "Slash commands"
   :class transient-column
   :setup-children ecc-transient--setup-slash
   :pad-keys t]
  ["Other"
   ("/" "Choose with completion" ecc-slash-command)])

(transient-define-suffix ecc-menu-allow-all (args)
  "Allow every request waiting in this session.
With --remember among ARGS the tools involved are not asked about again
for the rest of the session."
  :description "Allow every waiting request"
  (interactive (list (transient-args 'ecc-allow-all-menu)))
  (require 'ecc-perm)
  (ecc-perm-allow-all (and (member "--remember" args) t)))

(transient-define-prefix ecc-allow-all-menu ()
  "Allow every request waiting in this session, remembering the tools or not.
A prefix of its own rather than a switch in `ecc-menu\=', because in
transient an argument belongs to the prefix and not to a suffix: sitting
in the Respond column, --remember read as though it applied to every
allow and deny there, when only this one command looks at it."
  ["Allow every waiting request"
   ("-r" "Remember the tools" "--remember")
   ("A" ecc-menu-allow-all)])

(transient-define-suffix ecc-menu-resume (session args)
  "Resume SESSION, forking it when --fork is among ARGS.
Forking is a switch rather than a prefix argument because it is the
choice worth seeing before it is made: a second process on a live
session forks the conversation with no lock to stop it.  The switch
lives in `ecc-resume-menu\=', which opening this way always shows."
  :description "Resume"
  (interactive (list (ecc-read-session "Resume: ")
                     (transient-args 'ecc-resume-menu)))
  (ecc-resume session (and (member "--fork" args) t)))

;;;###autoload (autoload 'ecc-resume-menu "ecc-transient" nil t)
(transient-define-prefix ecc-resume-menu ()
  "Resume a session, forking the conversation or not.
A prefix of its own for the reason `ecc-allow-all-menu\=' is: --fork sat
at the head of the Session column and read as though Start and Kill took
it too."
  ["Resume"
   ("-f" "Fork the conversation" "--fork")
   ("r" ecc-menu-resume)])

;;;; The main menu

;;;###autoload (autoload 'ecc-menu "ecc-transient" nil t)
(transient-define-prefix ecc-menu ()
  "Everything this package can do."
  ["Claude Code"
   ["Session"
    ("c" "Start" ecc-start)
    ("r" "Resume" ecc-resume-menu)
    ("k" "Kill" ecc-kill)
    ("R" "Rename" ecc-rename-session)
    ("v" "Go to the prompt" ecc-show-session)
    ("w" "Hide or restore windows" ecc-toggle)
    ("S" "Switch this window to another session" ecc-switch-session)
    ("i" "Interrupt" ecc-interrupt)
    ("t" "Hand over to the terminal" ecc-tui-open)
    ("u" "Take it back" ecc-tui-return)]
   ["Send"
    ("s" "Send a line" ecc-send)
    ("x" "Send with context" ecc-send-with-context)
    ("g" "Send the region" ecc-send-region)
    ("f" "Send this file" ecc-send-buffer-file)
    ("e" "Fix the error at point" ecc-fix-error-at-point)
    ("l" "Ask inline" ecc-inline-prompt)
    ("W" "Rewrite the region" ecc-rewrite)]
   ["Review"
    ("D" "Diff review" ecc-review)
    ("F" "Files" ecc-goto-files)
    ("P" "Plan" ecc-goto-plan)
    ("T" "Timeline" ecc-timeline)]]
  ["Respond and look around"
   ["Respond"
    ("a" "Allow the oldest request" ecc-answer-allow)
    ("A" "Allow every waiting request" ecc-allow-all-menu)
    ("d" "Deny the oldest request" ecc-answer-deny)
    ("n" "Next request" ecc-next-attention)
    ("N" "Next request in this project" ecc-next-attention-in-project)
    ("1" "Answer with option 1" ecc-answer-option-1)
    ("2" "Answer with option 2" ecc-answer-option-2)
    ("3" "Answer with option 3" ecc-answer-option-3)
    ("4" "Answer with option 4" ecc-answer-option-4)]
   ["View"
    ("b" "Dashboard" ecc-dashboard)
    ("y" "Capabilities" ecc-capabilities-show)
    ("h" "History" ecc-history-open)
    ("U" "Usage" ecc-usage)
    ("L" "Log" ecc-show-log)]
   ["Config"
    ("m" "Model" ecc-set-model)
    ("p" "Permission mode" ecc-set-permission-mode)
    ("o" "Remote control" ecc-remote-control-toggle)
    ("O" "Open remotely" ecc-remote-control-open)
    ("K" "Copy the remote URL" ecc-remote-control-copy-url)]])

(provide 'ecc-transient)

;;; ecc-transient.el ends here
