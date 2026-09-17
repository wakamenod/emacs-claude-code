;;; resume-key.el --- C-c c r resumes, C-u C-c c r forks  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of feat/resume-key: the key that used to open
;; `ecc-resume-menu' now runs `ecc-resume' itself, the prefix argument
;; is the fork, and the prompt says which of the two is about to
;; happen.  It builds a little repository, starts two real sessions in
;; it, stops them, and then presses the key from a file buffer -- where
;; there is a choice to be asked about, so that the prompt is on camera.
;;
;; `ecc-menu' is shown at the end still holding `ecc-resume-menu' under
;; r: the fork stays a switch in the one place it can be seen before it
;; is pressed.
;;
;; Played by demo/scenes/resume-key.sh through demo/record.sh.

;;; Code:

(require 'ecc)

(defvar demo-sessions nil
  "The sessions this scene started, newest first.")

(defvar demo-source "greet.py"
  "The file the key is pressed in: a buffer that is not a session.")

(defvar demo-last-prompt nil
  "The minibuffer prompt the last step was answered at.
It is what the scene is really about -- Resume: or Fork: -- and it is
read off the minibuffer rather than assumed.")

;;;; What the sessions are started in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (demo-fresh-repository)
  (demo-write demo-source "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-show-source))

(defun demo-show-source ()
  "Show the file, and go to it.
The key is pressed here rather than in a transcript: in a session that
has stopped `ecc-read-session\\=' resumes that one without asking, and
the prompt is the half of this change that can be seen.

The window is whatever `display-buffer\\=' gives.  Clearing the frame
first is not open to this: a session lives in a side window, and
`delete-other-windows\\=' in one of them fails with \"Cannot make side
window the only window\" (2026-09-17)."
  (when-let* ((frame (demo-main-frame)))
    ;; The frame is worked in without being raised or given the
    ;; keyboard: what is recorded is its own window, and a demonstration
    ;; can play beside somebody working.
    (with-selected-frame frame
      (let* ((buffer (find-file-noselect (expand-file-name demo-source demo-root)))
             (window (or (get-buffer-window buffer frame)
                         (display-buffer buffer))))
        (when (window-live-p window)
          (select-window window)))))
  (demo-say (format "ecc from %s" (abbreviate-file-name (locate-library "ecc"))))
  nil)

(defun demo-ids ()
  "Say which conversation each session is on.
It is what a fork changes and a resume does not: the buffer goes on
under an id of its own."
  (demo-say (mapconcat
             (lambda (session)
               (format "%s is on %s"
                       (ecc-session-name session)
                       (substring (ecc-session-id session) 0 8)))
             (ecc-model-sessions)
             "   "))
  nil)

;;;; Two sessions, so that there is something to choose between

(defun demo-start-session (name)
  "Start a real session called NAME in the project."
  (push (ecc-start demo-root name) demo-sessions)
  nil)

(defun demo-send (text)
  "Send TEXT to the session started last, so its recording has a turn in it."
  (ecc-send text (car demo-sessions))
  nil)

(defun demo-stop-sessions ()
  "Stop every session, leaving them where a resume can find them.
`ecc-proc-stop\\=' rather than `ecc-kill\\=': the conversation stays in the
list, which is what is being resumed."
  (dolist (session demo-sessions)
    (ecc-proc-stop session))
  (demo-say (format "%d session(s) stopped: %s"
                    (length demo-sessions)
                    (mapconcat #'ecc-session-name demo-sessions ", ")))
  nil)

;;;; Pressing the key

(defun demo-answer (&optional text)
  "Answer the minibuffer with TEXT, after noting the prompt it asked with.
The answer is left on `unread-command-events\\=' from a timer because that
is the only way in: Emacs does not answer the server while it is reading
from the minibuffer, so the step that opened it has already returned."
  (when-let* ((window (active-minibuffer-window)))
    (setq demo-last-prompt
          (with-current-buffer (window-buffer window) (minibuffer-prompt)))
    (setq unread-command-events
          (append (string-to-list (or text ""))
                  (listify-key-sequence (kbd "RET")))))
  nil)

(defun demo-resume-key (&optional prefix text hold)
  "Press \\=`C-c c r\\=' in the source buffer, with PREFIX, answering with TEXT.
The prompt is held HOLD seconds first, which is what there is to look
at: the same key with and without `C-u\\=' asks Resume: or Fork:."
  (demo-run-key-in demo-source "C-c c r" nil prefix)
  (run-at-time (or hold 6) nil #'demo-answer text)
  nil)

(defun demo-report-key ()
  "Say what the key runs now, from the buffer it is pressed in."
  (demo-say-key-in demo-source "C-c c r"))

(defun demo-report-prompt ()
  "Say what the prompt was, and what came of it."
  (demo-say (format "The prompt was %S -- now running: %s"
                    demo-last-prompt
                    (or (mapconcat #'ecc-session-name
                                   (seq-filter
                                    (lambda (session)
                                      (process-live-p (ecc-session-process session)))
                                    (ecc-model-sessions))
                                   ", ")
                        "nothing")))
  nil)

;;;; The menu, which keeps the switch

(defun demo-open-resume-menu ()
  "Open `ecc-resume-menu\\=', which r in `ecc-menu\\=' still opens."
  (run-at-time 0.2 nil #'ecc-resume-menu)
  nil)

(defun demo-close-menu ()
  "Close whatever transient is open."
  (run-at-time 0.2 nil (lambda () (ignore-errors (transient-quit-all))))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session this scene left running."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'resume-key)
;;; resume-key.el ends here
