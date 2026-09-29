;;; restore-back.el --- The second half of ecc-restore: the Emacs after  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Emacs that comes after `restore-exit': nothing is open, and the
;; state file says what was.  `ecc-restore' brings the two Spaces back
;; in the order of their tabs, with their sessions stopped and no CLI
;; under any of them.  A prompt typed into one starts that one alone.
;; Running the command again brings nothing back twice.
;;
;; The helpers, `demo-restore-root' and `demo-restore-file' are the
;; first half's; nothing is rebuilt here, since the projects and the
;; recordings are what the first half left.
;;
;; Played by demo/scenes/restore-back.sh through demo/record.sh, after
;; demo/scenes/restore-exit.sh.

;;; Code:

(load (expand-file-name "restore-exit" (file-name-directory load-file-name)) nil t)

(defun demo-scene-build ()
  "Open the first project again, building nothing.  Called by demo.el once there is a frame."
  (demo-restore-use-file)
  (setq demo-root (demo-restore-project "alpha"))
  (demo-restore-show-source "alpha" "greet.py"))

(defun demo-restore-run ()
  "Run `ecc-restore', as M-x would."
  (call-interactively #'ecc-restore)
  nil)

(defun demo-restore-type-and-send (name text)
  "Type TEXT into the prompt region of the session NAME and send it.
The prompt is what starts a restored session, so it goes through
`ecc-prompt-send' like a key would, from a timer: a resume that asks a
question must not hold the step."
  (let ((session (seq-find (lambda (session)
                             (equal (ecc-session-name session) name))
                           (ecc-model-sessions))))
    (run-at-time
     0.2 nil
     (lambda ()
       (with-current-buffer (ecc-session-buffer session)
         (when-let* ((window (get-buffer-window (current-buffer))))
           (select-window window))
         (ecc-chat-goto-prompt)
         (insert text)
         (ecc-prompt-send)))))
  nil)

(defun demo-restore-goto-space (project)
  "Go to the Space of PROJECT."
  (ecc-space-select (ecc-space-of-root (demo-restore-project project)))
  nil)

(defun demo-restore-cleanup ()
  "Stop every session this scene started."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'restore-back)
;;; restore-back.el ends here
