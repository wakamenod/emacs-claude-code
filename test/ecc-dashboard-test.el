;;; ecc-dashboard-test.el --- Tests for ecc-dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; The three sources of the session list, the order the rows come in and
;; what the keys of the list do (FR-DASH-1 to 6).
;;
;; Every test uses two sessions of this Emacs: a dashboard with one row
;; hides the sorting and the deduplication, which is where the bugs are
;; (CLAUDE.md).
;;
;; test/fixtures/agents.json is what `claude agents --json' answered on
;; this machine; test/fixtures/history/session.jsonl is a recording made
;; by scripts/record-history.sh.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-dashboard)
(require 'ecc-history)
(require 'ecc-session)

(defconst ecc-dashboard-test-agents
  (with-temp-buffer
    (insert-file-contents (expand-file-name "fixtures/agents.json"
                                            ecc-test-directory))
    (buffer-string))
  "The recorded answer of `claude agents --json'.")

(defmacro ecc-dashboard-test--with-two-sessions (a b &rest body)
  "Run BODY with A and B two sessions of this Emacs, plus recorded sources.
A is idle, B is waiting for an answer to a Write, and both the agent
list and the recordings are the ones in test/fixtures."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,a
     (let* ((root (make-temp-file "ecc-dashboard" t))
            (project (expand-file-name "-tmp-project" root))
            (,b (ecc-model-create-session :name "other" :project-root root))
            (ecc-history-directory root)
            (ecc-history--files (make-hash-table :test #'equal))
            (ecc-dashboard--agents
             (ecc-protocol-parse-agents ecc-dashboard-test-agents))
            (ecc-dashboard--recordings nil)
            (ecc-window-use-side-window nil))
       (unwind-protect
           (progn
             (make-directory project t)
             (copy-file (ecc-test-history-fixture "session")
                        (expand-file-name
                         "24a1aa86-d53f-4457-b09e-4f4caf450f03.jsonl" project))
             (ecc-dashboard-refresh-recordings)
             (ecc-model-set-state ,a 'idle)
             (ecc-test-add-request ,b "Write")
             ,@body)
         (delete-directory root t)
         (ecc-test-cleanup-session ,b)))))

(defun ecc-dashboard-test--names (entries)
  "Return the names of ENTRIES, in order."
  (mapcar #'ecc-dashboard-entry-name entries))

(defun ecc-dashboard-test--kinds (entries)
  "Return the kinds of ENTRIES, in order."
  (mapcar #'ecc-dashboard-entry-kind entries))

;;;; The sources (FR-DASH-2, FR-DASH-6)

(ert-deftest ecc-dashboard-test-parses-the-agent-list ()
  "The answer of `claude agents --json' is read as recorded."
  (let ((agents (ecc-protocol-parse-agents ecc-dashboard-test-agents)))
    (should (= 4 (length agents)))
    (should (equal "emacs-gravity-a6" (alist-get 'name (car agents))))
    (should (equal "idle" (alist-get 'status (car agents))))
    (should (alist-get 'pid (car agents)))
    ;; A CLI that does not know the subcommand prints something else.
    (should-not (ecc-protocol-parse-agents "unknown command\n"))
    (should-not (ecc-protocol-parse-agents ""))))

(ert-deftest ecc-dashboard-test-three-sources ()
  "The sessions of this Emacs, of other processes and of the files all show."
  (ecc-dashboard-test--with-two-sessions a b
    (let ((entries (ecc-dashboard-entries)))
      (should (member "test" (ecc-dashboard-test--names entries)))
      (should (member "other" (ecc-dashboard-test--names entries)))
      (should (member "emacs-gravity-a6" (ecc-dashboard-test--names entries)))
      ;; The recording is listed under the title the CLI gave it.
      (should (member "Hello" (ecc-dashboard-test--names entries)))
      (should (equal (append '(own own)
                             (make-list (length ecc-dashboard--agents) 'external)
                             '(archived))
                     (ecc-dashboard-test--kinds entries)))
      (should (= (+ 3 (length ecc-dashboard--agents)) (length entries)))
      (ignore a b))))

(ert-deftest ecc-dashboard-test-external-state-comes-from-the-cli ()
  "An external row shows what the CLI said about it (FR-DASH-6).
The recording holds one session the CLI reported without a status, so
this also pins down what a row with nothing to say looks like."
  (ecc-dashboard-test--with-two-sessions a b
    (let* ((entries (seq-filter (lambda (e)
                                  (eq 'external (ecc-dashboard-entry-kind e)))
                                (ecc-dashboard-entries)))
           (states (mapcar #'ecc-dashboard-entry-state entries)))
      (should (= (length ecc-dashboard--agents) (length entries)))
      (should (member "idle" states))
      (should (member "busy" states))
      (should (member "?" states))
      (should (seq-every-p #'ecc-dashboard-entry-cwd entries))
      (should (seq-every-p #'ecc-dashboard-entry-time entries))
      ;; None of them is waiting, so none is sorted to the top.
      (should (seq-every-p (lambda (e) (= 0 (ecc-dashboard-entry-waiting e)))
                           entries))
      (ignore a b))))

(ert-deftest ecc-dashboard-test-external-waiting-for ()
  "A CLI that says what a session waits for puts it at the top (FR-DASH-6)."
  (ecc-dashboard-test--with-two-sessions a b
    ;; With no session of this Emacs waiting, the external one is on top.
    (ecc-perm-allow-request (car (ecc-session-pending b)))
    (let ((ecc-dashboard--agents
           (list '((sessionId . "ext-1") (name . "waiter") (cwd . "/tmp")
                   (status . "busy") (waitingFor . "permission")))))
      (let ((entry (car (ecc-dashboard-entries))))
        (should (equal "waiter" (ecc-dashboard-entry-name entry)))
        (should (equal "waiting: permission" (ecc-dashboard-entry-state entry)))
        (should (= 1 (ecc-dashboard-entry-waiting entry)))))
    (ignore a b)))

(ert-deftest ecc-dashboard-test-one-row-per-session ()
  "A session of this Emacs is not listed again as its recording."
  (ecc-dashboard-test--with-two-sessions a b
    ;; The session of this Emacs now has the id of the recording.
    (ecc-model-set-session-id a "24a1aa86-d53f-4457-b09e-4f4caf450f03")
    (let ((entries (ecc-dashboard-entries)))
      (should (= (+ 2 (length ecc-dashboard--agents)) (length entries)))
      (should-not (member "Hello" (ecc-dashboard-test--names entries)))
      (should (member "test" (ecc-dashboard-test--names entries)))
      (ignore b))))

;;;; The order (FR-DASH-4)

(ert-deftest ecc-dashboard-test-waiting-comes-first ()
  "A session waiting for an answer is at the top, whatever its kind."
  (ecc-dashboard-test--with-two-sessions a b
    (let ((entries (ecc-dashboard-entries)))
      (should (equal "other" (ecc-dashboard-entry-name (car entries))))
      (should (= 1 (ecc-dashboard-entry-waiting (car entries))))
      (ignore a))
    ;; Once it is answered it goes back among the others.
    (ecc-perm-allow-request (car (ecc-session-pending b)))
    (should (equal (append '(own own)
                           (make-list (length ecc-dashboard--agents) 'external)
                           '(archived))
                   (ecc-dashboard-test--kinds (ecc-dashboard-entries))))))

(ert-deftest ecc-dashboard-test-sorting-keeps-the-queues ()
  "Sorting the rows does not reorder the pending queue of a session.
`sort' is destructive and the rows are built from live lists."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-test-add-request b "Bash")
    (let ((queue (ecc-session-pending b)))
      (ecc-dashboard-entries)
      (should (eq queue (ecc-session-pending b)))
      (should (= 2 (length (ecc-session-pending b))))
      (ignore a))))

;;;; The buffer and its keys (FR-DASH-1, 3, 4, 5)

(defmacro ecc-dashboard-test--in-buffer (&rest body)
  "Draw the dashboard without asking the CLI and run BODY inside it."
  `(cl-letf (((symbol-function 'ecc-dashboard-refresh-agents) #'ignore)
             ((symbol-function 'ecc-dashboard--start-timer) #'ignore)
             ((symbol-function 'pop-to-buffer) #'set-buffer))
     (let ((buffer (ecc-dashboard)))
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(ert-deftest ecc-dashboard-test-buffer-lists-every-row ()
  "The buffer holds one line per session, the waiting one first."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (should (derived-mode-p 'ecc-dashboard-mode))
     (should (= (+ 3 (length ecc-dashboard--agents))
                (count-lines (point-min) (point-max))))
     (goto-char (point-min))
     (should (equal "other" (ecc-dashboard-entry-name (tabulated-list-get-id))))
     ;; The columns of FR-DASH-1 are all filled for a session of this Emacs.
     (let ((row (tabulated-list-get-entry)))
       (should (equal "own" (aref row 0)))
       (should (equal "other" (aref row 1)))
       (should (string-search "waiting" (aref row 2)))
       (should (string-prefix-p "/" (aref row 3))))
     (ignore a b))))

(ert-deftest ecc-dashboard-test-answers-from-the-row ()
  "The a and d keys answer the oldest request of the row (FR-DASH-4)."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (goto-char (point-min))
     (ecc-dashboard-allow)
     (should-not (ecc-session-pending b))
     (should (equal "allow" (alist-get 'behavior (ecc-test-response 0))))
     ;; The row of a session that is not waiting says so rather than
     ;; answering something else.
     (goto-char (point-min))
     (should-error (ecc-dashboard-allow) :type 'user-error)
     (ignore a))))

(ert-deftest ecc-dashboard-test-visit-and-resume ()
  "RET opens a session; a recording is read back and R resumes it."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     ;; A session of this Emacs shows its transcript.
     (let (shown)
       (cl-letf (((symbol-function 'ecc-display-session)
                  (lambda (session) (setq shown session) nil))
                 ((symbol-function 'select-window) #'ignore))
         (goto-char (point-min))
         (ecc-dashboard-visit)
         (should (eq shown b))))
     ;; The archived row reads its recording into a session.
     (goto-char (point-max))
     (forward-line -1)
     (should (eq 'archived (ecc-dashboard-entry-kind (tabulated-list-get-id))))
     (let ((session (cl-letf (((symbol-function 'ecc-display-session) #'ignore))
                      (ecc-dashboard-visit)
                      (ecc-model-session "24a1aa86-d53f-4457-b09e-4f4caf450f03"))))
       (should session)
       (should (= 3 (length (ecc-session-turns session))))
       ;; R starts the CLI on what was read.
       (let (started)
         (cl-letf (((symbol-function 'ecc-proc-start)
                    (lambda (s &optional resume fork)
                      (setq started (list s resume fork))))
                   ((symbol-function 'ecc-display-session) #'ignore)
                   ((symbol-function 'select-window) #'ignore))
           (ecc-dashboard-resume)
           (should (equal (list session t nil) started))))
       (ecc-test-cleanup-session session))
     (ignore a))))

(ert-deftest ecc-dashboard-test-external-resume-asks-first ()
  "Resuming a session another process runs asks before doing it (FR-TUI-5)."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (goto-char (point-min))
     (while (not (eq 'external (ecc-dashboard-entry-kind (tabulated-list-get-id))))
       (forward-line 1))
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
       (should-error (ecc-dashboard-resume) :type 'user-error))
     (ignore a b))))

(ert-deftest ecc-dashboard-test-delete-asks-and-removes ()
  "D deletes the recording of the row, but only after a yes (FR-DASH-5)."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (goto-char (point-max))
     (forward-line -1)
     (let ((file (ecc-dashboard-entry-file (tabulated-list-get-id))))
       (should (file-exists-p file))
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
         (ecc-dashboard-delete))
       (should (file-exists-p file))
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                 ((symbol-function 'ecc-dashboard-refresh-agents) #'ignore))
         (ecc-dashboard-delete))
       (should-not (file-exists-p file)))
     (ignore a b))))

(ert-deftest ecc-dashboard-test-rename ()
  "r renames a session of this Emacs and its buffer (FR-DASH-5)."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-session-ensure-buffer b)
    (ecc-dashboard-test--in-buffer
     (goto-char (point-min))
     (ecc-dashboard-rename "renamed")
     (should (equal "renamed" (ecc-session-name b)))
     (should (get-buffer "*ecc: renamed*"))
     (should-error (ecc-dashboard-rename "") :type 'user-error)
     (ignore a))))

(ert-deftest ecc-dashboard-test-stop ()
  "k stops the session of the row and takes it off the list (FR-DASH-5)."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (goto-char (point-min))
     (ecc-dashboard-stop)
     (should-not (ecc-model-session (ecc-session-id b)))
     (should (member "test" (ecc-dashboard-test--names (ecc-dashboard-entries))))
     (ignore a))))

;;;; Polling (plan section 9, item 15)

(ert-deftest ecc-dashboard-test-poll-only-while-shown ()
  "The CLI is not asked while the dashboard is off screen."
  (let ((asked 0)
        (ecc-dashboard--timer nil))
    (cl-letf (((symbol-function 'ecc-dashboard-refresh-agents)
               (lambda (&rest _) (cl-incf asked))))
      ;; No buffer at all: the timer stops itself.
      (let ((buffer (get-buffer ecc-dashboard-buffer-name)))
        (when buffer (kill-buffer buffer)))
      (setq ecc-dashboard--timer (run-at-time 3600 nil #'ignore))
      (ecc-dashboard--poll)
      (should (= 0 asked))
      (should-not ecc-dashboard--timer)
      ;; A buffer nobody shows is left alone, and the timer keeps running.
      (let ((buffer (get-buffer-create ecc-dashboard-buffer-name)))
        (unwind-protect
            (progn (ecc-dashboard--poll)
                   (should (= 0 asked)))
          (kill-buffer buffer))))))

(provide 'ecc-dashboard-test)

;;; ecc-dashboard-test.el ends here
