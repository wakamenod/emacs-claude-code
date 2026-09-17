;;; resume-fix.el --- The exit of a CLI that has been replaced  -*- lexical-binding: t; -*-

;;; Commentary:

;; What `/resume', `ecc-resume' and the dashboard's `R' all do is stop
;; one CLI and start another inside the same command.  Emacs runs a
;; process sentinel when it next waits for output, which is regularly
;; after the second one is already installed, and the exit of the first
;; was applied to the session running the second: the process slot went
;; to nil, the state to `exited', the pending requests were closed and
;; the turn the new CLI had just been given was aborted as "left open by
;; the exit".  The prompt had gone out, so the answer came back to a
;; session nothing was listening to -- a prompt with nothing under it,
;; in a session that looked stopped while its CLI was running.  Five
;; resumes in ten, measured against CLI 2.1.274 on 2026-09-17.
;;
;; The scene does not wait for the race: it hands the session the exit
;; of the process that went, which is what the sentinel does late, and
;; plays it twice -- once with `ecc-proc--stale-exit-p' stubbed out,
;; which is the code as it was, and once as it ships.
;;
;; Played by demo/scenes/resume-fix.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-history)
(require 'ecc-proc)

(defvar demo-session nil
  "The session that is stopped and started again.")

(defvar demo-old-process nil
  "The CLI that went, whose exit arrives late.")

(defvar demo-word "ZARQUON"
  "The word the session is asked to remember, and then for.")

(defvar demo-asked nil
  "The questions the false exit made ecc ask, newest first.")

(defun demo-answer-no (prompt)
  "Answer PROMPT no, after putting it on the screen.
A session declared exited is a session ecc offers to resume, and the
offer is a `y-or-n-p' nobody is there to answer: the Emacs of a
recording stops dead on it and every step after it times out.  Saying
no is also the honest answer -- the CLI never went -- and the question
being asked at all is part of what the old code did (2026-09-18)."
  (push prompt demo-asked)
  (demo-say (format "%sno" prompt))
  (sit-for 3)
  nil)

(defun demo-report-asked ()
  "Say what the false exit made ecc ask."
  (demo-say (format "Questions ecc asked: %d%s"
                    (length demo-asked)
                    (if demo-asked
                        (format "   -- %s" (string-join (reverse demo-asked) " // "))
                      "   -- none")))
  nil)

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t
        demo-session nil
        demo-old-process nil
        demo-asked nil)
  (advice-add 'y-or-n-p :override #'demo-answer-no)
  (advice-add 'yes-or-no-p :override #'demo-answer-no)
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s   --   the fix is %s"
                    (abbreviate-file-name (locate-library "ecc-proc"))
                    (if (fboundp 'ecc-proc--stale-exit-p)
                        "ecc-proc--stale-exit-p"
                      "NOT IN THIS BUILD")))
  nil)

;;;; A conversation worth coming back to

(defun demo-start-session ()
  "Start a real session in the project."
  (let ((default-directory demo-root))
    (setq demo-session (ecc-start demo-root "resume")))
  nil)

(defun demo-remember ()
  "Give the session something to remember, so that resuming can be tested."
  (ecc-proc-send-prompt
   demo-session
   (format "Remember the word %s.  Reply with exactly: OK" demo-word))
  nil)

(defun demo-report-session ()
  "Say what the session is: its state, its process and its last answer."
  (demo-say
   (format "%s: state %S, process %s, turns %d, last answer %S"
           (ecc-session-name demo-session)
           (ecc-session-state demo-session)
           (if (process-live-p (ecc-session-process demo-session))
               "running" "none")
           (length (ecc-session-turns demo-session))
           (demo-last-answer)))
  nil)

(defun demo-last-answer ()
  "Return the text of the last turn of the session."
  (let ((turn (car (last (ecc-session-turns demo-session)))))
    (if turn
        (string-trim
         (mapconcat (lambda (node)
                      (if (eq (ecc-node-type node) 'text)
                          (or (ecc-model-node-get node 'text) "")
                        ""))
                    (ecc-turn-children turn) ""))
      "")))

(defun demo-show-transcript ()
  "Put the transcript on the screen at its end."
  (ecc-display-session demo-session)
  (when-let* ((window (get-buffer-window (ecc-session-buffer demo-session) t)))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (demo-frame)
  nil)

;;;; The two readings of one late exit

(defvar demo-stale-exit-p (and (fboundp 'ecc-proc--stale-exit-p)
                               (symbol-function 'ecc-proc--stale-exit-p))
  "The fix, kept so that the scene can put it back.")

(defun demo-use-the-old-code ()
  "Take the fix out: every exit is the session's own, as it was."
  (fset 'ecc-proc--stale-exit-p #'ignore)
  (demo-say "ecc-proc--stale-exit-p stubbed out -- this is the code as it was")
  nil)

(defun demo-use-the-new-code ()
  "Put the fix back."
  (fset 'ecc-proc--stale-exit-p demo-stale-exit-p)
  (demo-say "ecc-proc--stale-exit-p back in place -- this is 0.3.0 as it ships")
  nil)

(defun demo-resume-and-ask ()
  "Stop the CLI, start it again on the same conversation, and ask the word.
The process that went is kept: its exit is handed over afterwards, which
is what Emacs does when it runs the sentinel late."
  (setq demo-old-process (ecc-session-process demo-session))
  (ecc-proc-stop demo-session)
  (ecc-history-resume demo-session)
  (ecc-proc-send-prompt
   demo-session
   "Which word did I ask you to remember?  Answer with it alone.")
  (demo-say "stopped, resumed with --resume, and the prompt is away")
  nil)

(defun demo-late-exit ()
  "Hand the session the exit of the CLI that went, the way the sentinel does.
Emacs runs a sentinel when it next waits for output; by then the session
is running the process that was started after it."
  (demo-say (format "the sentinel of the CLI that went (code 143) arrives now, %s"
                    (if (eq demo-old-process (ecc-session-process demo-session))
                        "and it IS the session's own"
                      "and the session is running another one")))
  (ecc-proc--handle-exit demo-session 143 "terminated" demo-old-process)
  nil)

(defun demo-wait-for-the-answer (&optional seconds)
  "Give the CLI SECONDS to answer, and say whether it reached the buffer."
  ;; `sit-for' alone: the process slot of a session the old code
  ;; declared exited is nil, and `accept-process-output' on nil waits
  ;; for any process at all, which held this Emacs long enough that the
  ;; recorder's next steps timed out and the scene stopped where it was
  ;; (2026-09-18).
  (let ((deadline (+ (float-time) (or seconds 25))))
    (while (and (< (float-time) deadline)
                (string-empty-p (demo-last-answer)))
      (sit-for 0.3)))
  (demo-say (format "the transcript %s the answer"
                    (if (string-match-p
                         demo-word
                         (with-current-buffer (ecc-session-buffer demo-session)
                           (buffer-substring-no-properties
                            (max (point-min) (- (point-max) 2000)) (point-max))))
                        "HAS"
                      "does NOT have")))
  nil)

(defun demo-forget-the-session ()
  "Stop what is left of the session, so the second half starts clean."
  (when demo-session
    (ignore-errors (ecc-kill demo-session)))
  (setq demo-session nil)
  nil)

(defun demo-cleanup ()
  "Put the fix back and stop whatever is running."
  (demo-use-the-new-code)
  (when (and demo-session (process-live-p (ecc-session-process demo-session)))
    (ignore-errors (ecc-kill demo-session)))
  nil)

(provide 'resume-fix)
;;; resume-fix.el ends here
