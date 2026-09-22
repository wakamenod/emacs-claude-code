;;; rename-command.el --- /rename reaches Emacs, and R stops renaming to NAME<2>  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two things a batch test can say but nobody had seen on the screen.
;;
;; `/rename' is the CLI's own command, and the live stream reports it
;; as one synthetic assistant message carrying `local_command_run' and
;; `local_command_source'.  Nothing here read those, so the command was
;; drawn as a reply the model had written and the new name never
;; reached the session: the mode line, the buffer and every menu went
;; on saying the old one.  On camera it is the header, the buffer name
;; and the line the transcript gains.
;;
;; `C-c c R' is the other half.  Its prompt offers the name the session
;; has, and confirming it unchanged used to rename the session to
;; NAME<2>, because the uniqueness check counted the session itself.
;; The step presses RET on the offered name and the name stays.
;;
;; One real session; the CLI answers `/rename' itself, so no turn goes
;; to the model and the scene costs nothing.
;;
;; Played by demo/scenes/rename-command.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-prompt)

(defvar demo-session nil "The session being renamed.")
(defvar demo-source "greet.py" "A file, so the project has something in it.")

(defun demo-scene-build ()
  "Build the project.  Called by demo.el once there is a frame."
  (demo-fresh-repository)
  (demo-write demo-source "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name demo-source demo-root))
  ;; The scene presses `C-c c R'; the README's binding is what makes it
  ;; that, and this Emacs carries the user's init rather than a promise.
  (global-set-key (kbd "C-c c") 'ecc-global-map)
  (demo-say (format "ecc from %s" (abbreviate-file-name (locate-library "ecc"))))
  nil)

;;;; The session

(defun demo-start ()
  "Start the session the scene renames."
  (setq demo-session (ecc-start demo-root "morning"))
  (ecc-window-select-session demo-session)
  (demo-frame)
  nil)

(defun demo-buffer ()
  "Return the name of the session buffer, which a rename changes."
  (buffer-name (ecc-session-buffer demo-session)))

(defun demo-report (what)
  "Say what the session is called, calling this moment WHAT."
  (demo-say (format "%s: name %S · buffer %S · header %S"
                    what
                    (ecc-session-name demo-session)
                    (demo-buffer)
                    (substring-no-properties
                     (string-trim (ecc-render-status-line demo-session)))))
  nil)

(defun demo-report-last-turn ()
  "Say what the last turn is made of.
`command\\=' is the point of the scene: before this branch the CLI's
answer arrived as `text\\=', indistinguishable from the model talking."
  (let ((turn (car (last (ecc-session-turns demo-session)))))
    (demo-say (format "last turn: prompt %S · nodes %S"
                      (ecc-turn-prompt turn)
                      (mapcar #'ecc-node-type (ecc-turn-children turn)))))
  nil)

;;;; Typing the command

(defun demo-type-rename ()
  "Write `/rename afternoon' in the prompt region."
  (with-current-buffer (ecc-session-buffer demo-session)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (with-selected-window window
        (ecc-chat-goto-prompt)
        (ecc-chat-set-draft "/rename afternoon"))))
  nil)

(defun demo-send ()
  "Press `C-c C-c', which is what sends the prompt region."
  (demo-run-key-in (demo-buffer) "C-c C-c"))

(defun demo-show-the-transcript ()
  "Put point where what the command printed stands."
  (when-let* ((window (get-buffer-window (ecc-session-buffer demo-session) t)))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -6)))
  nil)

;;;; The key

(defun demo-press-rename-key ()
  "Press `C-c c R' and answer RET, which takes the name it offers."
  (demo-run-key-in (demo-buffer) "C-c c R" ""))

(defun demo-press-rename-key-with-a-name ()
  "Press `C-c c R' and type a name over the one it offers."
  (demo-run-key-in (demo-buffer) "C-c c R"
                   ;; The offered name is the initial input; it is
                   ;; cleared the way a typist would, with C-a C-k.
                   (concat "\C-a\C-k" "evening")))

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'rename-command)
;;; rename-command.el ends here
