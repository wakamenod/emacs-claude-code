;;; ecc-restart-test.el --- Tests for restarting a running session  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-restart' stops the CLI of an idle session that is still running
;; and starts it again on the same conversation, in the same buffer.  The CLI
;; here is a real process -- a script that sleeps whatever it is given --
;; so that the stop, the sentinel and the start are the real ones; only
;; what would be written to it is collected instead.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)

(defvar ecc-restart-test--recording-lines
  '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}")
  "What the recording of a session that has been spoken to holds.")

(defmacro ecc-restart-test--with-cli (&rest body)
  "Run BODY with `ecc-executable' a stand-in CLI and no recording anywhere.
The stand-in sleeps whatever arguments it is given, so a session started
on it is a live process that `ecc-proc-stop' can stop.  The recordings
and the registry are empty directories of their own."
  (declare (indent 0) (debug t))
  `(let* ((bin (make-temp-file "ecc-restart-cli" nil ".sh"
                               "#!/bin/sh\nexec sleep 60\n"))
          (ecc-history-directory (make-temp-file "ecc-restart-history" t))
          (ecc-history--files (make-hash-table :test #'equal))
          (ecc-registry-directory (make-temp-file "ecc-restart-registry" t))
          (ecc-executable bin)
          (ecc-command-wrapper-function nil)
          (ecc-mcp-enabled nil)
          (ecc-stop-grace 2.0))
     (set-file-modes bin #o755)
     (unwind-protect
         (cl-letf (((symbol-function 'ecc-git-start-baseline) #'ignore)
                   ((symbol-function 'ecc--enable-session-modes) #'ignore)
                   ((symbol-function 'ecc-window-select-session) #'ignore))
           ,@body)
       (delete-file bin)
       (delete-directory ecc-history-directory t)
       (delete-directory ecc-registry-directory t))))

(defun ecc-restart-test--record (session)
  "Write a recording for SESSION, as the CLI does once it is spoken to."
  (let ((directory (expand-file-name "-tmp-project" ecc-history-directory)))
    (make-directory directory t)
    (with-temp-file (expand-file-name (concat (ecc-session-id session) ".jsonl")
                                      directory)
      (insert (mapconcat #'identity ecc-restart-test--recording-lines "\n")
              "\n"))))

(defun ecc-restart-test--start (session &optional spoken)
  "Start SESSION on the stand-in CLI and return the process.
With SPOKEN, it has been sent a prompt that was answered: there is a
turn in the transcript and a recording on disk."
  (when spoken
    (ecc-model-begin-turn session "hello")
    (ecc-model-finish-turn session nil)
    (ecc-restart-test--record session))
  (ecc-session-ensure-buffer session)
  (ecc-proc-start session #'ecc-dispatch))

(defun ecc-restart-test--stop-all (&rest sessions)
  "Stop the stand-in CLI of every one of SESSIONS.
The stop is marked as asked for, so that the exit is not offered a
resume from a timer that outlives the test."
  (dolist (session sessions)
    (setf (alist-get 'stop-requested (ecc-session-progress session)) t)
    (when (process-live-p (ecc-session-process session))
      (delete-process (ecc-session-process session)))))

;;;; Restarting

(ert-deftest ecc-restart-test-an-idle-session-is-resumed ()
  "A running session is stopped and started again with --resume.
The buffer is the one it had and the transcript is not read again."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let* ((old (ecc-restart-test--start session t))
                 (buffer (ecc-session-buffer session))
                 (turns (ecc-session-turns session)))
            (ecc-restart session)
            (let ((new (ecc-session-process session)))
              (should (process-live-p new))
              (should-not (eq new old))
              (should-not (process-live-p old))
              (should (member "--resume" (process-command new)))
              (should (member (ecc-session-id session) (process-command new)))
              (should-not (member "--session-id" (process-command new))))
            (should (eq buffer (ecc-session-buffer session)))
            (should (equal turns (ecc-session-turns session)))
            (should (eq (ecc-session-state session) 'idle)))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-no-recording-starts-under-the-same-id ()
  "A session that has not been spoken to starts again with --session-id.
The CLI writes no recording until it is sent a prompt, and --resume on
an id with none fails (2.1.290, 2026-10-12)."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session)
            (should-not (ecc-history-file (ecc-session-id session)))
            (ecc-restart session)
            (let ((command (process-command (ecc-session-process session))))
              (should (member "--session-id" command))
              (should (member (ecc-session-id session) command))
              (should-not (member "--resume" command))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-a-later-crash-is-still-offered-a-resume ()
  "The stop the restart asked for is forgotten once the new CLI is up.
Otherwise an exit nobody asked for, later on, would look requested and
not be offered a resume."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session t)
            (ecc-restart session)
            (should-not (ecc-proc-stopped-on-request-p session)))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-the-draft-is-kept ()
  "What was being typed in the prompt is still there after the restart."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session t)
            (with-current-buffer (ecc-session-buffer session)
              (ecc-chat-goto-prompt)
              (insert "half a thought"))
            (ecc-restart session)
            (with-current-buffer (ecc-session-buffer session)
              (should (equal "half a thought" (ecc-chat-draft)))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-r-restarts-a-live-session ()
  "R in a running session asks, then restarts it."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((old (ecc-restart-test--start session t))
                asked)
            (with-current-buffer (ecc-session-buffer session)
              ;; In the transcript, not the prompt, where R is a letter.
              (goto-char (point-min))
              (should (eq (key-binding (kbd "R")) #'ecc-session-resume))
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (prompt) (setq asked prompt) t)))
                (call-interactively #'ecc-session-resume)))
            (should asked)
            (should-not (eq old (ecc-session-process session)))
            (should (process-live-p (ecc-session-process session))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-r-resumes-a-stopped-session ()
  "R in a session that has stopped resumes it without a question."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (let (resumed)
        (ecc-session-ensure-buffer session)
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (error "It asked about a stopped session")))
                  ((symbol-function 'ecc-history-resume)
                   (lambda (s &optional fork) (setq resumed (list s fork)))))
          (with-current-buffer (ecc-session-buffer session)
            (call-interactively #'ecc-session-resume)))
        (should (equal (list session nil) resumed))))))

(ert-deftest ecc-restart-test-the-other-session-is-left-running ()
  "Restarting one session leaves the CLI of another alone."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session one
      (let ((two (ecc-model-create-session
                  :name "two" :project-root temporary-file-directory)))
        (unwind-protect
            (let ((other (ecc-restart-test--start two t)))
              (ecc-restart-test--start one t)
              (ecc-restart one)
              (should (eq other (ecc-session-process two)))
              (should (process-live-p other))
              (should (eq (ecc-session-state two) 'idle)))
          (ecc-restart-test--stop-all one two)
          (ecc-test-cleanup-session two))))))

;;;; What is refused

(defun ecc-restart-test--refused (session)
  "Check that restarting SESSION is refused and touches nothing.
The question is never reached, and the process is the one it had."
  (let ((process (ecc-session-process session)))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "It asked before refusing"))))
      (should-error (ecc-restart session t) :type 'user-error))
    (should (eq process (ecc-session-process session)))
    (should (process-live-p process))))

(ert-deftest ecc-restart-test-a-running-turn-is-refused ()
  "A session in the middle of a turn is not restarted; the message says to interrupt."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session t)
            (let ((turn (ecc-model-begin-turn session "work")))
              (ecc-restart-test--refused session)
              (should (eq turn (ecc-session-current-turn session))))
            (should (string-match-p
                     "interrupt it first (C-c C-z)"
                     (cadr (should-error (ecc-restart session)
                                         :type 'user-error)))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-a-waiting-request-is-refused ()
  "A request waiting for an answer keeps the session from being restarted.
A compaction or a request is a turn as well; the request is looked at on
its own all the same, since that is what would be cut off."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session t)
            (let ((request (ecc-test-add-request session)))
              (ecc-restart-test--refused session)
              (should (equal (list request) (ecc-session-pending session)))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-queued-prompts-are-refused ()
  "Prompts waiting in the queue keep the session from being restarted."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session t)
            (ecc-model-queue-input session "queued")
            (ecc-restart-test--refused session)
            (should (= 1 (length (ecc-session-input-queue session)))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-an-inline-session-is-refused ()
  "An inline session is a question on the side, and is not restarted.
The one that forks its parent would be started again on the parent's
conversation."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session)
            (setf (ecc-session-options session)
                  (plist-put (ecc-session-options session) :inline t))
            (ecc-restart-test--refused session))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-declining-leaves-it-alone ()
  "Saying no to the question stops nothing."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((old (ecc-restart-test--start session t)))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
              (should-error (ecc-restart session t) :type 'user-error))
            (should (eq old (ecc-session-process session)))
            (should (process-live-p old)))
        (ecc-restart-test--stop-all session)))))

;;;; What the new CLI is started with

(ert-deftest ecc-restart-test-the-permission-mode-is-kept ()
  "A session switched to plan is restarted in plan, not in its first mode.
The mode goes in for that start alone: the options the session was
asked to be started with are left as they were."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((ecc-permission-mode "acceptEdits"))
            (setf (ecc-session-options session) '(:streaming nil))
            (ecc-restart-test--start session t)
            ;; What S-TAB leaves once the CLI has agreed.
            (setf (ecc-session-permission-mode session) "plan")
            (ecc-restart session)
            (let ((command (process-command (ecc-session-process session))))
              (should (equal "plan" (cadr (member "--permission-mode" command)))))
            (should (equal '(:streaming nil) (ecc-session-options session))))
        (ecc-restart-test--stop-all session)))))

;;;; Which session

(ert-deftest ecc-restart-test-a-running-session-the-menu-names-is-taken ()
  "Outside a session buffer the session the menu acts on is taken while it runs.
A recording is never offered: picked by mistake, it would be resumed."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (progn
            (ecc-restart-test--start session)
            (with-temp-buffer
              (cl-letf (((symbol-function 'ecc-read-session)
                         (lambda (&rest _) (error "It offered the recordings")))
                        ((symbol-function 'completing-read)
                         (lambda (&rest _) (error "It asked")))
                        ((symbol-function 'ecc-window-resolve-session)
                         (lambda (&rest _) session)))
                (should (eq session (ecc--restart-target))))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-a-stopped-session-the-menu-names-is-passed-over ()
  "Outside a session buffer a stopped session is not taken for the target.
The menu's choice ends on the session used last, which may have
stopped, and restarting it would resume it without a word.  The running
sessions are asked among instead, with a question of the restart's own."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session stopped
      (let ((one (ecc-model-create-session
                  :name "one" :project-root temporary-file-directory))
            (two (ecc-model-create-session
                  :name "two" :project-root temporary-file-directory))
            asked)
        (unwind-protect
            (progn
              (ecc-restart-test--start one)
              (with-temp-buffer
                (cl-letf (((symbol-function 'ecc-window-resolve-session)
                           (lambda (&rest _) stopped)))
                  ;; One running: it is the only answer, and nothing is asked.
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (&rest _) (error "It asked with one candidate"))))
                    (should (eq one (ecc--restart-target))))
                  ;; Two running: asked among them, as a restart.
                  (ecc-restart-test--start two)
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (prompt table &rest _)
                               (setq asked (cons prompt (all-completions "" table)))
                               (car (all-completions "" table)))))
                    (should (memq (ecc--restart-target) (list one two))))
                  (should (equal "Restart: " (car asked)))
                  (should (= 2 (length (cdr asked))))
                  ;; None running: said so.
                  (ecc-restart-test--stop-all one two)
                  (should-error (ecc--restart-target) :type 'user-error))))
          (ecc-restart-test--stop-all one two)
          (ecc-test-cleanup-session one)
          (ecc-test-cleanup-session two))))))

(ert-deftest ecc-restart-test-asking-offers-the-running-sessions ()
  "With a prefix argument only the sessions whose CLI runs are offered.
Two sessions, one running and one stopped: the running one is the only
candidate, so it is taken without a question."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session stopped
      (ignore stopped)
      (let ((running (ecc-model-create-session
                      :name "running" :project-root temporary-file-directory)))
        (unwind-protect
            (progn
              (ecc-restart-test--start running)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) (error "It asked with one candidate"))))
                (should (eq running (ecc--restart-target t))))
              (ecc-restart-test--stop-all running)
              (should-error (ecc--restart-target t) :type 'user-error))
          (ecc-restart-test--stop-all running)
          (ecc-test-cleanup-session running))))))

;;;; Second review

(ert-deftest ecc-restart-test-a-background-task-is-refused ()
  "A session whose turn is over but whose background task runs is not idle.
Stopping the CLI would kill the subagent or the shell command and leave
its node unfinished for good.  Nothing interrupts a task, so the message
says to wait for it."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((agent nil))
            (ecc-restart-test--start session t)
            ;; Under the turn that started it, which has ended.
            (setq agent (ecc-model-add-node session :id "toolu_a" :type 'agent
                                            :parent (car (ecc-session-turns session))
                                            :status 'done
                                            :data '((task . ((task_id . "a"))))))
            (should (eq (ecc-session-state session) 'idle))
            (ecc-restart-test--refused session)
            (should (string-match-p
                     "idle with 1 background task still running; restart it once it is done"
                     (cadr (should-error (ecc-restart session) :type 'user-error))))
            ;; Once it has finished, the session may be restarted.
            (ecc-model-node-put agent 'task-status "completed")
            (should (ecc-restart session)))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-what-starts-during-the-question-is-refused ()
  "The question lets output in, so the session is looked at again after it.
A prompt from Remote Control, or a turn the CLI begins on its own, may
start while the question is open."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((old (ecc-restart-test--start session t)))
            (cl-letf (((symbol-function 'y-or-n-p)
                       (lambda (_prompt)
                         (ecc-model-begin-turn session "(remote)")
                         t)))
              (should-error (ecc-restart session t) :type 'user-error))
            (should (eq old (ecc-session-process session)))
            (should (process-live-p old)))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-a-fork-not-yet-settled-forks-again ()
  "A fork restarted before its first turn forks again, rather than going back.
Until system/init hands it its own id, the session still goes by the id
it branched from; resuming that without --fork-session took it back onto
the conversation it was forked from.  Once the id is its own, a restart
resumes it."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (unwind-protect
          (let ((parent-id (ecc-session-id session)))
            (ecc-restart-test--start session t)
            (ecc-restart-test--stop-all session)
            ;; C-u C-c c r: a fork of the stopped session, on the same object.
            (ecc-resume session t)
            (should (member "--fork-session"
                            (process-command (ecc-session-process session))))
            (ecc-restart session)
            (let ((command (process-command (ecc-session-process session))))
              (should (equal parent-id (cadr (member "--resume" command))))
              (should (member "--fork-session" command)))
            ;; The first turn hands the fork its id, and its recording.
            (ecc-dispatch session '((type . "system") (subtype . "init")
                                    (session_id . "11111111-2222-3333-4444-555555555555")))
            (ecc-restart-test--record session)
            (ecc-restart session)
            (let ((command (process-command (ecc-session-process session))))
              (should (equal "11111111-2222-3333-4444-555555555555"
                             (cadr (member "--resume" command))))
              (should-not (member "--fork-session" command))))
        (ecc-restart-test--stop-all session)))))

(ert-deftest ecc-restart-test-a-cli-that-ignores-the-stop-is-killed ()
  "A CLI that will not stop when asked is killed before the new one starts.
`ecc-proc-stop' deletes the process once the grace is over, which is
why the restart checks nothing after it: two CLIs never overlap."
  (ecc-restart-test--with-cli
    (ecc-test-with-fake-session session
      (let ((stubborn (make-temp-file "ecc-restart-stubborn" nil ".sh"
                                      "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n")))
        (set-file-modes stubborn #o755)
        (unwind-protect
            (let ((old (let ((ecc-executable stubborn))
                         (ecc-restart-test--start session t)))
                  (ecc-stop-grace 0.3))
              (ecc-restart session)
              (should-not (process-live-p old))
              (should (process-live-p (ecc-session-process session)))
              (should-not (eq old (ecc-session-process session))))
          (ecc-restart-test--stop-all session)
          (delete-file stubborn))))))

(provide 'ecc-restart-test)

;;; ecc-restart-test.el ends here
