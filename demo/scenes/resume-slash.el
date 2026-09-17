;;; resume-slash.el --- /resume carries a window on with another conversation  -*- lexical-binding: t; -*-

;;; Commentary:

;; `/resume', typed in a session, is Emacs's own: the CLI names no
;; resume among its slash commands.  The CLI is stopped, the session is
;; emptied, its id becomes the recording's, the recording is read into
;; the same buffer and the CLI is started again with --resume.  The
;; window, the tab, the buffer, the name and the review baseline do not
;; move.
;;
;; Two real sessions: one is given something to say, so that it leaves
;; a recording worth coming back to, and the other is the window that
;; is carried on.  What is checked on camera is that the buffer, the
;; window and the name are the same objects afterwards and the id is
;; not.
;;
;; Played by demo/scenes/resume-slash.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-history)
(require 'ecc-prompt)

(defvar demo-first nil "The session that leaves the recording.")
(defvar demo-second nil "The window that is carried on.")
(defvar demo-first-id nil "The id of the conversation to come back to.")
(defvar demo-before nil "What the second session was, before /resume.")
(defvar demo-source "greet.py" "A file, so the Space has something beside it.")

(defun demo-scene-build ()
  "Build the project.  Called by demo.el once there is a frame."
  (demo-fresh-repository)
  (demo-write demo-source "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name demo-source demo-root))
  (demo-say (format "ecc from %s" (abbreviate-file-name (locate-library "ecc"))))
  nil)

;;;; A conversation worth coming back to

(defun demo-start-first ()
  "Start the session that will leave the recording."
  (setq demo-first (ecc-start demo-root "morning"))
  (demo-frame)
  nil)

(defun demo-say-something ()
  "Give that session a turn of its own, so the recording has one."
  (ecc-send "Reply with exactly: the kettle is on." demo-first)
  nil)

(defun demo-stop-first ()
  "Stop it, leaving the conversation where a resume can find it."
  (setq demo-first-id (ecc-session-id demo-first))
  (ecc-proc-stop demo-first)
  (demo-say (format "%s stopped, on %s"
                    (ecc-session-name demo-first)
                    (substring demo-first-id 0 8)))
  nil)

(defun demo-kill-first ()
  "Take the first session out of the list, leaving only its recording.
That is the case `/resume\\=' is for: a project worked in this morning,
with nothing running in it now."
  (ecc-kill demo-first)
  (demo-frame)
  nil)

;;;; The window that is carried on

(defun demo-start-second ()
  "Start the fresh session whose window will be carried on."
  (setq demo-second (ecc-start demo-root "afternoon"))
  (ecc-window-select-session demo-second)
  (setq demo-before
        (list (ecc-session-id demo-second)
              (ecc-session-buffer demo-second)
              (get-buffer-window (ecc-session-buffer demo-second) t)
              (ecc-session-name demo-second)))
  (demo-frame)
  nil)

(defun demo-report-second (what)
  "Say what the second session is, calling this moment WHAT."
  (demo-say (format "%s: %s · id %s · buffer %s · window %s · turns %d"
                    what
                    (ecc-session-name demo-second)
                    (substring (ecc-session-id demo-second) 0 8)
                    (buffer-name (ecc-session-buffer demo-second))
                    (if (eq (get-buffer-window (ecc-session-buffer demo-second) t)
                            (nth 2 demo-before))
                        "the same one" "MOVED")
                    (length (seq-filter #'ecc-turn-prompt
                                        (ecc-session-turns demo-second)))))
  nil)

(defun demo-report-what-moved ()
  "Say which of the four things changed and which did not."
  (demo-say (format "id %s · buffer %s · window %s · name %s"
                    (if (equal (nth 0 demo-before) (ecc-session-id demo-second))
                        "UNCHANGED" "is the recording's now")
                    (if (eq (nth 1 demo-before) (ecc-session-buffer demo-second))
                        "the same object" "REPLACED")
                    (if (eq (nth 2 demo-before)
                            (get-buffer-window (ecc-session-buffer demo-second) t))
                        "the same object" "REPLACED")
                    (if (equal (nth 3 demo-before) (ecc-session-name demo-second))
                        "unchanged" "CHANGED")))
  nil)

;;;; Typing the command

(defun demo-type-resume (&optional argument)
  "Write `/resume' in the prompt region, with ARGUMENT when given."
  (with-current-buffer (ecc-session-buffer demo-second)
    (when-let* ((window (get-buffer-window (current-buffer) t)))
      (with-selected-window window
        (ecc-chat-goto-prompt)
        (ecc-chat-set-draft (if argument
                                (format "/resume %s" argument)
                              "/resume")))))
  nil)

(defun demo-type-resume-with-id ()
  "Write `/resume <id>', which takes a conversation without asking."
  (demo-type-resume demo-first-id))

(defun demo-send ()
  "Press `C-c C-c', which is what sends the prompt region."
  (demo-run-key-in (buffer-name (ecc-session-buffer demo-second)) "C-c C-c"))

(defun demo-answer (&optional text)
  "Answer the minibuffer with TEXT, the way typing would."
  (when (active-minibuffer-window)
    (setq unread-command-events
          (append (string-to-list (or text ""))
                  (listify-key-sequence (kbd "RET")))))
  nil)

(defun demo-answer-later (text seconds)
  "Answer the minibuffer with TEXT after SECONDS."
  (run-at-time seconds nil #'demo-answer text)
  nil)

(defun demo-report-command ()
  "Say that the command is Emacs's own and not one the CLI offers."
  (demo-say (format "/resume is offered by Emacs (%s) · the CLI's own commands: %d, none of them resume"
                    (cdr (assoc "/resume" ecc-prompt-local-commands))
                    (length (ecc-prompt-commands demo-second))))
  nil)

(defun demo-show-the-transcript ()
  "Put point where the conversation that was read in ends."
  (when-let* ((window (get-buffer-window (ecc-session-buffer demo-second) t)))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -6)))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'resume-slash)
;;; resume-slash.el ends here
