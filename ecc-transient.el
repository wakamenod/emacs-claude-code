;;; ecc-transient.el --- One menu for every ecc command  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1") (transient "0.7.0"))

;;; Commentary:

;; Section 6.18 of IMPLEMENTATION_PLAN.md (NFR-10).  `ecc-menu' reaches
;; every command worth a key; the slash command submenu is built from
;; what the CLI said in its initialize answer, so it shows the skills and
;; the plugin commands of the session at hand rather than a fixed list.

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
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-inbox "ecc-inbox" ())
(declare-function ecc-dashboard "ecc-dashboard" ())
(declare-function ecc-capabilities-show "ecc-dashboard" (session))
(declare-function ecc-inline-prompt "ecc-inline" (question))
(declare-function ecc-rewrite "ecc-inline" (beg end instruction))
(declare-function ecc-next-attention "ecc-inbox" (&optional project-root))
(declare-function ecc-answer-allow "ecc-inbox" ())
(declare-function ecc-answer-deny "ecc-inbox" (reason))
(declare-function ecc-review "ecc-review" (&optional session paths))
(declare-function ecc-session-timeline "ecc-session" ())
(declare-function ecc-session-goto-files "ecc-session" ())
(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-history-open "ecc-history" (session-id))
(declare-function ecc-tui-open "ecc-tui" (&optional session))
(declare-function ecc-tui-return "ecc-tui" (&optional session))

;;;; Commands the menu needs of its own

(defun ecc-menu-session ()
  "Return the session the menu acts on (FR-WIN-4)."
  (ecc-window-resolve-session))

;;;###autoload
(defun ecc-show-session ()
  "Show the session this buffer talks to and select its prompt buffer.
Both windows come back, and the point lands where something can be
typed: `C-x o' from a source buffer reaches the transcript first, which
is not where a prompt is written."
  (interactive)
  (let ((session (ecc-menu-session)))
    (ecc-display-prompt session)
    session))

;;;###autoload
(defun ecc-interrupt ()
  "Interrupt the running turn of the session this buffer talks to (FR-SES-5)."
  (interactive)
  (let ((session (ecc-menu-session)))
    (ecc-proc-interrupt session)
    (message "%s: interrupt sent" (ecc-session-name session))))

;;;###autoload
(defun ecc-set-permission-mode (mode)
  "Ask the session this buffer talks to to switch to permission MODE."
  (interactive
   (list (completing-read "Permission mode: "
                          '("default" "acceptEdits" "bypassPermissions" "plan")
                          nil t)))
  (let ((session (ecc-menu-session)))
    (ecc-proc-set-permission-mode session mode)
    (message "%s: switching to %s" (ecc-session-name session) mode)))

;;;###autoload
(defun ecc-set-model (model)
  "Ask the session this buffer talks to to use MODEL (FR-INP-5).
The CLI answers a /model command even when it is driven headless, so
the model can be changed without restarting it."
  (interactive (list (completing-read "Model: " (ecc-prompt-model-candidates))))
  (let ((session (ecc-menu-session)))
    (ecc-proc-send-prompt session (concat "/model " model))
    model))

;;;###autoload
(defun ecc-show-log ()
  "Show the raw protocol log of the session this buffer talks to (NFR-8)."
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
  (ecc-menu--in-session #'ecc-session-goto-files))

;;;###autoload
(defun ecc-timeline ()
  "Pick a turn of the session this buffer talks to (FR-OUT-14 d)."
  (interactive)
  (ecc-menu--in-session #'ecc-session-timeline))

;;;###autoload
(defun ecc-customize ()
  "Open the customization group of this package (NFR-7)."
  (interactive)
  (customize-group 'ecc))

;;;; The slash command submenu (NFR-10)

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
                   (argument (when (assoc name ecc-prompt-interactive-commands)
                               (ecc-prompt-read-argument name)))
                   (text (if argument (concat name " " argument) name)))
              (ecc-proc-send-prompt session text)
              (message "Sent %s to %s" text (ecc-session-name session))))
          (format "Send the slash command %s to the session at hand." name))
        (puthash name symbol ecc-transient--slash-commands)
        symbol)))

(defun ecc-transient-slash-suffixes (&optional session)
  "Return the suffix specifications for the slash commands of SESSION."
  (let* ((session (or session (ecc-menu-session)))
         (commands (ecc-prompt-commands session))
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
  "Send the slash command NAME, chosen with completion (FR-INP-2, 3)."
  (interactive
   (let* ((session (ecc-window-resolve-session))
          (commands (ecc-prompt-commands session)))
     (list (completing-read "Slash command: " (mapcar #'car commands) nil nil "/"))))
  (funcall (ecc-transient-slash-command name)))

(defun ecc-transient--setup-slash (_children)
  "Return the children of `ecc-slash-menu', built from the session."
  (transient-parse-suffixes 'ecc-slash-menu (ecc-transient-slash-suffixes)))

;;;###autoload (autoload 'ecc-slash-menu "ecc-transient" nil t)
(transient-define-prefix ecc-slash-menu ()
  "Slash commands the session at hand knows about (NFR-10)."
  [:description "Slash commands"
   :class transient-column
   :setup-children ecc-transient--setup-slash
   :pad-keys t]
  ["Other"
   ("/" "Choose with completion" ecc-slash-command)])

;;;; The main menu (NFR-10)

;;;###autoload (autoload 'ecc-menu "ecc-transient" nil t)
(transient-define-prefix ecc-menu ()
  "Everything this package can do (NFR-10)."
  ["Claude Code"
   ["Session"
    ("c" "Start" ecc-start)
    ("r" "Resume" ecc-resume)
    ("k" "Kill" ecc-kill)
    ("R" "Rename" ecc-rename-session)
    ("v" "Go to the prompt buffer" ecc-show-session)
    ("w" "Hide or restore windows" ecc-toggle)
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
    ("W" "Rewrite the region" ecc-rewrite)
    ("/" "Slash command" ecc-slash-menu)]
   ["Review"
    ("d" "Diff review" ecc-review)
    ("F" "Files" ecc-goto-files)
    ("T" "Timeline" ecc-timeline)]]
  ["Respond and look around"
   ["Respond"
    ("a" "Allow the oldest request" ecc-answer-allow)
    ("D" "Deny the oldest request" ecc-answer-deny)
    ("n" "Next request" ecc-next-attention)
    ("I" "Inbox" ecc-inbox)]
   ["View"
    ("b" "Dashboard" ecc-dashboard)
    ("y" "Capabilities" ecc-capabilities-show)
    ("h" "History" ecc-history-open)
    ("L" "Log" ecc-show-log)]
   ["Config"
    ("m" "Model" ecc-set-model)
    ("p" "Permission mode" ecc-set-permission-mode)
    ("C" "Customize" ecc-customize)]])

(provide 'ecc-transient)

;;; ecc-transient.el ends here
