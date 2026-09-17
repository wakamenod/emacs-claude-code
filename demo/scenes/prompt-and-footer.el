;;; prompt-and-footer.el --- The model before the first answer, and the prompt history  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two smaller pieces of 0.3.0, both of them under the prompt region.
;;
;; The footer names the model before the session has answered.  The CLI
;; says which model ran on every assistant message and says it nowhere
;; earlier, so a session just started -- the one moment the model is
;; worth knowing -- had nothing on the right of its footer.  What the
;; CLI is about to resolve is worked out here instead: the session's own
;; `:model', then ANTHROPIC_MODEL in the environment, then the `model'
;; of the Claude Code settings files.  The scene shows the settings file
;; being read, the first answer replacing it, and ANTHROPIC_MODEL
;; beating a settings file that names something else.
;;
;; And `ecc-prompt-history-insert' (`C-c C-r', `H' in the menu), which
;; replaced `ecc-prompt-resend-last': `M-p' walks the history one entry
;; at a time and replaces the whole region as it goes, which is no way
;; to reach the fiftieth entry back.
;;
;; Played by demo/scenes/prompt-and-footer.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-chat)
(require 'ecc-prompt)
(require 'ecc-proc)

(defvar demo-session nil "The session whose footer is read.")
(defvar demo-env-session nil "The session started with ANTHROPIC_MODEL set.")

;;;; The project, with a Claude Code settings file in it

(defun demo-scene-build ()
  "Build a project whose settings name a model.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write "README.md" "# footer\n\nA project whose settings name a model.\n")
  (demo-write ".claude/settings.json" "{\n  \"model\": \"opus\"\n}\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "README.md" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s -- .claude/settings.json names \"opus\"" (ecc-version)))
  nil)

;;;; The footer

(defun demo-start-session ()
  "Start a session, and show it before anything has been sent."
  (setq demo-session (ecc-start demo-root "footer"))
  (ecc-display-session demo-session)
  (demo-frame)
  nil)

(defun demo-report-footer (&optional session what)
  "Say what the footer under the prompt of SESSION reads."
  (let ((session (or session demo-session)))
    (with-current-buffer (ecc-session-buffer session)
      (demo-say (format "%s footer: %S   ·   startup model: %S   ·   CLI has said: %S"
                        (or what "")
                        (string-trim (or (ecc-chat-footer-shown) "(none)"))
                        (ecc-proc-startup-model session)
                        (ecc-render--model-name session)))))
  nil)

(defun demo-report-footer-before ()
  "The footer of a session that has not answered yet."
  (demo-report-footer demo-session "before the first prompt --"))

(defun demo-report-footer-after ()
  "The footer once the CLI has said which model answered."
  (demo-report-footer demo-session "after the first answer --"))

(defun demo-send-something ()
  "Send one short prompt, so that the CLI says which model ran."
  ;; `ecc-chat-goto-prompt' rather than `point-max': the footer lies
  ;; past the prompt region and is read-only, so an insert at the end of
  ;; the buffer answers "Text is read-only" and nothing is sent
  ;; (2026-09-18).
  (with-current-buffer (ecc-session-buffer demo-session)
    (ecc-chat-goto-prompt)
    (insert "Reply with exactly: ok")
    (ecc-prompt-send))
  nil)

(defun demo-start-env-session ()
  "Start a session with ANTHROPIC_MODEL set, against settings naming opus."
  (let ((ecc-extra-environment (cons "ANTHROPIC_MODEL=haiku"
                                     (bound-and-true-p ecc-extra-environment))))
    (setq demo-env-session (ecc-start demo-root "env")))
  (ecc-display-session demo-env-session)
  (demo-frame)
  nil)

(defun demo-report-env-footer ()
  "Say which of the two the footer believes."
  (demo-report-footer demo-env-session "ANTHROPIC_MODEL=haiku against settings opus --"))

;;;; The prompt history

(defun demo-fill-the-history ()
  "Put a handful of prompts into the history without sending them."
  (dolist (text '("first: rename the greeting function"
                  "second: write a test for the empty name"
                  "third: what does this module depend on?"
                  "fourth: summarise the last commit"
                  "fifth: and now something else entirely"))
    (ecc-prompt-history-add text))
  (demo-say (format "%d prompts in the history (it holds two hundred)"
                    (length ecc-prompt-history)))
  nil)

(defun demo-half-written ()
  "Start writing a prompt, so that what is inserted lands beside it."
  (with-current-buffer (ecc-session-buffer demo-session)
    (let ((start (ecc-chat-prompt-start)))
      (delete-region start (ecc-chat-prompt-end))
      (ecc-chat-goto-prompt)
      (insert "Before you answer, remember: "))
    (demo-frame))
  nil)

(defun demo-key (key &optional text prefix)
  "Run what KEY does in the transcript."
  (demo-run-key-in (ecc-session-buffer demo-session) key text prefix))

(defun demo-report-region ()
  "Say what the prompt region holds now."
  (with-current-buffer (ecc-session-buffer demo-session)
    (demo-say (format "the prompt region: %S"
                      (buffer-substring-no-properties
                       (ecc-chat-prompt-start) (ecc-chat-prompt-end)))))
  nil)

(defun demo-clear-region ()
  "Empty the prompt region again."
  (with-current-buffer (ecc-session-buffer demo-session)
    (delete-region (ecc-chat-prompt-start) (ecc-chat-prompt-end)))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'prompt-and-footer)
;;; prompt-and-footer.el ends here
