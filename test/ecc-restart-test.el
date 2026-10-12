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
          (ecc-mcp-config-function nil)
          (ecc-stop-grace 2.0))
     (set-file-modes bin #o755)
     (unwind-protect
         (cl-letf (((symbol-function 'ecc-review-ensure-baseline) #'ignore)
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
  (ecc-proc-start session))

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
            (puthash session (current-buffer) ecc-inline--targets)
            (ecc-restart-test--refused session))
        (remhash session ecc-inline--targets)
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

(ert-deftest ecc-restart-test-the-target-is-the-menu-s ()
  "Outside a session buffer the session is the one the menu acts on.
A recording is never offered: picked by mistake, it would be resumed."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      (cl-letf (((symbol-function 'ecc-read-session)
                 (lambda (&rest _) (error "It offered the recordings")))
                ((symbol-function 'ecc-window-resolve-session)
                 (lambda (&rest _) session)))
        (should (eq session (ecc--restart-target)))))))

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

(provide 'ecc-restart-test)

;;; ecc-restart-test.el ends here
