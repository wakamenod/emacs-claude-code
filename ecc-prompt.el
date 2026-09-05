;;; ecc-prompt.el --- The prompt buffer of a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Where a prompt is written and sent from.  Section 6.2 of
;; IMPLEMENTATION_PLAN.md.  Phase 1 covers multi-line input (FR-INP-1),
;; slash commands and their completion (FR-INP-2, FR-INP-3) and the queue
;; that holds a prompt back while a turn runs (FR-INP-6).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)

(defvar-local ecc-prompt--session nil
  "The session this prompt buffer belongs to.")

(defvar ecc-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-prompt-send)
    (define-key map (kbd "C-c C-k") #'ecc-prompt-clear)
    (define-key map (kbd "C-c C-q") #'ecc-prompt-show-queue)
    map)
  "Keymap of `ecc-prompt-mode'.")

(define-derived-mode ecc-prompt-mode text-mode "Claude-Prompt"
  "Major mode of the buffer a prompt is written in.

\\{ecc-prompt-mode-map}"
  :interactive nil
  (setq-local completion-at-point-functions
              (list #'ecc-prompt-capf))
  (visual-line-mode 1))

(defun ecc-prompt-buffer-name (name)
  "Return the name of the prompt buffer of the session called NAME."
  (format "*ecc-prompt: %s*" name))

(defun ecc-prompt-ensure-buffer (session)
  "Return the prompt buffer of SESSION, creating it if needed."
  (let ((buffer (ecc-session-prompt-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (ecc-prompt-buffer-name (ecc-session-name session))))
      (setf (ecc-session-prompt-buffer session) buffer)
      (with-current-buffer buffer
        (setq default-directory (or (ecc-session-project-root session)
                                    default-directory))
        (ecc-prompt-mode)
        (setq ecc-prompt--session session)))
    buffer))

(defun ecc-prompt-pop-to-buffer (session)
  "Show the prompt buffer of SESSION and select it."
  (pop-to-buffer (ecc-prompt-ensure-buffer session)))

(defun ecc-prompt-session ()
  "Return the session of this prompt buffer, or signal an error."
  (or ecc-prompt--session
      (user-error "This buffer does not belong to a Claude session")))

;;;; Sending

(defun ecc-prompt-send ()
  "Send the buffer as a prompt, or queue it while a turn runs (FR-INP-1, 6)."
  (interactive)
  (let* ((session (ecc-prompt-session))
         (text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "プロンプトが空です"))
    (let ((outcome (ecc-proc-send-prompt session text)))
      (erase-buffer)
      (if (eq outcome 'sent)
          (message "送信しました")
        (message "実行中のターンがあります。キューの %d 件目に入れました" outcome)))))

(defun ecc-prompt-clear ()
  "Empty the prompt buffer."
  (interactive)
  (erase-buffer))

(defun ecc-prompt-show-queue ()
  "Show the prompts waiting to be sent (FR-INP-6)."
  (interactive)
  (let ((queue (ecc-session-input-queue (ecc-prompt-session))))
    (if (null queue)
        (message "キューは空です")
      (message "キュー: %s"
               (mapconcat (lambda (text) (ecc--truncate text 30)) queue " | ")))))

;;;; Completion of slash commands (FR-INP-3)

(defun ecc-prompt-commands (session)
  "Return the slash commands of SESSION as an alist of name and description.
The initialize response is the better source because it carries a
description; the command list of system/init fills in the rest."
  (let ((commands nil))
    (seq-doseq (command (or (ecc-session-commands session) []))
      (let ((name (alist-get 'name command)))
        (when name
          (push (cons (concat "/" name)
                      (string-trim
                       (format "%s %s"
                               (or (alist-get 'argumentHint command) "")
                               (ecc--truncate (or (alist-get 'description command) "")
                                              70))))
                commands))))
    (seq-doseq (name (or (alist-get 'slash_commands (ecc-session-init session)) []))
      (when (and (stringp name) (not (assoc (concat "/" name) commands)))
        (push (cons (concat "/" name) "") commands)))
    (nreverse commands)))

(defun ecc-prompt-capf ()
  "Complete a slash command at point (FR-INP-3).
Only the first word of a line that starts with a slash is completed,
which is where the CLI looks for a command."
  (when-let* ((session ecc-prompt--session))
    (let ((start (line-beginning-position))
          (end (point)))
      (when (and (eq (char-after start) ?/)
                 (not (string-match-p "[ \t\n]" (buffer-substring-no-properties
                                                 start end))))
        (let ((commands (ecc-prompt-commands session)))
          (list start end (mapcar #'car commands)
                :exclusive 'no
                :annotation-function
                (lambda (candidate)
                  (when-let* ((description (cdr (assoc candidate commands))))
                    (unless (string-empty-p description)
                      (concat "  " description))))))))))

(provide 'ecc-prompt)

;;; ecc-prompt.el ends here
