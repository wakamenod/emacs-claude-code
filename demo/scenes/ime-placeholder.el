;;; ime-placeholder.el --- The placeholder gives way to what an input method composes  -*- lexical-binding: t; -*-

;;; Commentary:

;; On the NS port of Emacs 32 the macOS input method shows what it is
;; composing as the string of an empty overlay at point, and the
;; placeholder of an empty prompt region is an empty overlay at the same
;; place.  The composing text was drawn behind the whole placeholder,
;; with the cursor and the candidate window left in front of it.
;;
;; The scene calls the functions the input method's events run --
;; `ns-insert-marked-text', `ns-insert-working-text' and
;; `ns-unput-working-text' -- with `ns-working-text' set, since nothing
;; here can type through the real input method.  The candidate window is
;; therefore not in the picture; where the composing text is drawn is.
;; It is played once with the advice taken off, which is the bug, and
;; once with it on.
;;
;; Played by demo/scenes/ime-placeholder.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-chat)
(require 'ecc-proc)

(defvar ns-working-text)
(defvar ns-working-overlay)

(defvar demo-session nil "The session whose prompt is typed into.")

(defconst demo-ime-functions
  '(ns-insert-working-text ns-insert-marked-text ns-delete-working-text)
  "The functions ecc-chat.el advises.")

(defun demo-scene-build ()
  "Build a small project.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write "README.md" "# ime\n\nA project to type Japanese into.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "README.md" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s -- %s" (ecc-version) emacs-version))
  nil)

(defun demo-start-session ()
  "Start a session and show its empty prompt."
  (setq demo-session (ecc-start demo-root "ime"))
  (ecc-display-session demo-session)
  (demo-frame)
  nil)

(defmacro demo-in-prompt (&rest body)
  "Run BODY in the session's window, point in the prompt region."
  `(let* ((buffer (ecc-session-buffer demo-session))
          (window (demo-window-of buffer)))
     (with-selected-window window
       (with-current-buffer buffer
         ,@body))))

(defun demo-goto-prompt ()
  "Put point at the start of the empty prompt region."
  (demo-in-prompt (ecc-chat-goto-prompt) (ecc-chat-update-placeholder))
  nil)

(defun demo-report (what)
  "Say what the prompt region shows, after WHAT."
  (demo-in-prompt
   (let ((ov ns-working-overlay))
     (demo-say
      (format "%s -- placeholder: %S · composing: %S · draft: %S"
              what
              (ecc-chat-placeholder-shown)
              (and (overlayp ov) (overlay-buffer ov)
                   (substring-no-properties
                    (or (overlay-get ov 'before-string)
                        (overlay-get ov 'after-string) "")))
              (ecc-chat-draft)))))
  nil)

(defun demo-advice-off ()
  "Take the fix away, to show the bug."
  (dolist (function demo-ime-functions)
    (advice-remove function #'ecc-chat--after-working-text))
  (demo-say "The advice is off: this is how it was")
  nil)

(defun demo-advice-on ()
  "Put the fix back, as ecc-chat.el installs it."
  (dolist (function demo-ime-functions)
    (advice-add function :after #'ecc-chat--after-working-text))
  (demo-say (format "The advice is on: %S"
                    (mapcar (lambda (f)
                              (and (advice-member-p #'ecc-chat--after-working-text f) t))
                            demo-ime-functions)))
  nil)

(defun demo-mark (text)
  "Compose TEXT as marked text, the way the emacs-plus input method does."
  (demo-in-prompt
   (setq ns-working-text text)
   (ns-insert-marked-text 0 0))
  nil)

(defun demo-work (text)
  "Compose TEXT as working text, the other way the NS port does."
  (demo-in-prompt
   (setq ns-working-text text)
   (ns-insert-working-text))
  nil)

(defun demo-cancel ()
  "Cancel composing, as Esc in the input method does."
  (demo-in-prompt (ns-unput-working-text))
  nil)

(defun demo-commit (text)
  "Commit TEXT: the working text goes and real text is inserted."
  (demo-in-prompt
   (ns-unput-working-text)
   (insert text))
  nil)

(defun demo-clear ()
  "Empty the prompt region again."
  (demo-in-prompt
   (delete-region (ecc-chat-prompt-start) (ecc-chat-prompt-end))
   (ecc-chat-goto-prompt)
   (ecc-chat-update-placeholder))
  nil)

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'ime-placeholder)
;;; ime-placeholder.el ends here
