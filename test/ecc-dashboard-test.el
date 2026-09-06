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
(require 'ecc-registry)
(require 'ecc-session)

(defconst ecc-dashboard-test-agents
  (with-temp-buffer
    (insert-file-contents (expand-file-name "fixtures/agents.json"
                                            ecc-test-directory))
    (buffer-string))
  "The recorded answer of `claude agents --json'.")

(defconst ecc-dashboard-test-registry
  (expand-file-name "fixtures/registry" ecc-test-directory)
  "The recorded session registry the dashboard reads.")

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
             ((symbol-function 'ecc-dashboard--start-watch) #'ignore)
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

(ert-deftest ecc-dashboard-test-reads-the-registry ()
  "The sessions of other processes come from the registry, not a subprocess."
  (let ((ecc-registry-directory ecc-dashboard-test-registry)
        (ecc-registry-check-process nil)
        (ecc-dashboard--agents nil)
        (called nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "The dashboard started a process"))))
      (ecc-dashboard-refresh-agents (lambda () (setq called t))))
    (should called)
    (should (= 3 (length ecc-dashboard--agents)))
    (should (equal "emacs-claude-code-00"
                   (alist-get 'name (car ecc-dashboard--agents))))
    ;; The row keeps what the registry says about it.
    (let ((entry (ecc-dashboard--agent-entry (car ecc-dashboard--agents))))
      (should (eq 'external (ecc-dashboard-entry-kind entry)))
      (should (equal "busy" (ecc-dashboard-entry-state entry)))
      (should (equal "2.1.261" (ecc-dashboard-entry-model entry))))))

(ert-deftest ecc-dashboard-test-registry-change-redraws ()
  "A session starting or stopping elsewhere reaches the list at once."
  (ecc-dashboard-test--with-two-sessions a b
    (let ((ecc-registry-directory ecc-dashboard-test-registry)
          (ecc-registry-check-process nil)
          (ecc-dashboard--agents nil)
          (buffer (get-buffer-create ecc-dashboard-buffer-name)))
      (unwind-protect
          (with-current-buffer buffer
            (ecc-dashboard-mode)
            (ecc-dashboard--registry-changed)
            (should (= 3 (length ecc-dashboard--agents)))
            ;; The rows were drawn again with the new list in them.
            (should (member "emacs-claude-code-00"
                            (ecc-dashboard-test--names
                             (mapcar #'car tabulated-list-entries)))))
        (kill-buffer buffer)))
    (ignore a b)))

(ert-deftest ecc-dashboard-test-poll-only-while-shown ()
  "The registry is not reread while the dashboard is off screen."
  (let ((asked 0)
        (ecc-dashboard--timer nil))
    (cl-letf (((symbol-function 'ecc-dashboard-refresh-agents)
               (lambda (&rest _) (cl-incf asked)))
              ((symbol-function 'ecc-dashboard-redraw) #'ignore))
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


;;;; Capabilities (FR-DASH-7)

(defmacro ecc-dashboard-test-with-capabilities (session &rest body)
  "Run BODY with SESSION bound to a session whose project defines things.
The project holds a skill, an agent and a command of its own, the user
directory holds one of each too, and a plugin holds a skill: the three
scopes FR-DASH-7 asks for."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((root (make-temp-file "ecc-capabilities-project" t))
          (home (make-temp-file "ecc-capabilities-home" t))
          (plugin (make-temp-file "ecc-capabilities-plugin" t))
          (ecc-capabilities-directory home))
     (unwind-protect
         (ecc-test-with-fake-session ,session
           (setf (ecc-session-project-root ,session) root)
           (ecc-dashboard-test--write
            (expand-file-name ".claude/skills/project-skill/SKILL.md" root))
           (ecc-dashboard-test--write
            (expand-file-name ".claude/agents/project-agent.md" root))
           (ecc-dashboard-test--write
            (expand-file-name ".claude/commands/project-command.md" root))
           (ecc-dashboard-test--write
            (expand-file-name "skills/user-skill/SKILL.md" home))
           (ecc-dashboard-test--write
            (expand-file-name "skills/plugin-skill/SKILL.md" plugin))
           (setf (ecc-session-init ,session)
                 `((skills . ["project-skill" "user-skill" "plugin-skill"
                              "unknown-skill"])
                   (agents . ["project-agent" "general-purpose"])
                   (slash_commands . ["project-command" "project-skill" "clear"])
                   (mcp_servers . [((name . "emacs") (status . "connected"))])
                   (plugins . [((name . "demo") (path . ,plugin)
                                (source . "demo@market") (version . "1.0"))])
                   (tools . ["Read" "mcp__emacs__xref_find_references"
                             "mcp__emacs__project_info"])))
           (setf (ecc-session-commands ,session)
                 [((name . "project-command") (description . "Does a thing."))])
           ,@body)
       (delete-directory root t)
       (delete-directory home t)
       (delete-directory plugin t))))

(defun ecc-dashboard-test--write (file)
  "Create FILE, and the directories above it, with a line in it."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert "# sample\n")))

(defun ecc-dashboard-test--capability (entries kind name)
  "Return the KIND called NAME among ENTRIES."
  (seq-find (lambda (entry)
              (and (eq (ecc-capability-kind entry) kind)
                   (equal (ecc-capability-name entry) name)))
            entries))

(ert-deftest ecc-dashboard-test-capabilities-scopes ()
  "Each capability is placed in the scope whose directory defines it."
  (ecc-dashboard-test-with-capabilities session
    (let ((entries (ecc-capabilities session)))
      (should (eq (ecc-capability-scope
                   (ecc-dashboard-test--capability entries 'skill "project-skill"))
                  'project))
      (should (eq (ecc-capability-scope
                   (ecc-dashboard-test--capability entries 'skill "user-skill"))
                  'global))
      (let ((from-plugin (ecc-dashboard-test--capability
                          entries 'skill "plugin-skill")))
        (should (eq (ecc-capability-scope from-plugin) 'plugin))
        (should (equal (ecc-capability-origin from-plugin) "demo")))
      ;; Nothing on disk defines it, so it comes with the CLI.
      (let ((builtin (ecc-dashboard-test--capability
                      entries 'skill "unknown-skill")))
        (should (eq (ecc-capability-scope builtin) 'builtin))
        (should-not (ecc-capability-file builtin)))
      (should (eq (ecc-capability-scope
                   (ecc-dashboard-test--capability entries 'agent "project-agent"))
                  'project)))))

(ert-deftest ecc-dashboard-test-capabilities-files ()
  "RET has a file to open for everything that has one."
  (ecc-dashboard-test-with-capabilities session
    (let* ((entries (ecc-capabilities session))
           (skill (ecc-dashboard-test--capability entries 'skill "project-skill"))
           (command (ecc-dashboard-test--capability
                     entries 'command "project-command"))
           (plugin (ecc-dashboard-test--capability entries 'plugin "demo")))
      (should (string-suffix-p "skills/project-skill/SKILL.md"
                               (ecc-capability-file skill)))
      (should (string-suffix-p "commands/project-command.md"
                               (ecc-capability-file command)))
      ;; A plugin opens where it lives.
      (should (file-directory-p (ecc-capability-file plugin))))))

(ert-deftest ecc-dashboard-test-capabilities-descriptions-and-servers ()
  "Descriptions come from initialize, and a server says how it is doing."
  (ecc-dashboard-test-with-capabilities session
    (let* ((entries (ecc-capabilities session))
           (command (ecc-dashboard-test--capability
                     entries 'command "project-command"))
           (server (ecc-dashboard-test--capability entries 'mcp "emacs")))
      (should (equal (ecc-capability-description command) "Does a thing."))
      ;; The MCP server carries its status and how many tools it published.
      (should (equal (ecc-capability-detail server) "connected, 2 tools"))
      ;; A command a skill installs is listed once, as the skill.
      (should-not (ecc-dashboard-test--capability entries 'command "project-skill")))))

(ert-deftest ecc-dashboard-test-capabilities-buffer ()
  "The buffer groups by kind and scope, and folds a group away."
  (ecc-dashboard-test-with-capabilities session
    (with-temp-buffer
      (ecc-capabilities-mode)
      (setq ecc-capabilities--session session)
      (ecc-capabilities-draw session)
      (let ((text (ecc-test-buffer-string)))
        (should (string-search "Skills (4)" text))
        (should (string-search "Agents (2)" text))
        (should (string-search "Slash commands (2)" text))
        (should (string-search "MCP servers (1)" text))
        (should (string-search "Plugins (1)" text))
        (should (string-search "project (1)" text))
        (should (string-search "project-skill" text))
        (should (string-search "connected, 2 tools" text)))
      ;; Folding the skills hides what is under them and nothing else.
      (goto-char (point-min))
      (should (search-forward "Skills (4)" nil t))
      (goto-char (line-beginning-position))
      (ecc-capabilities-toggle)
      (let ((text (ecc-test-buffer-string)))
        (should (string-search "Skills (4)" text))
        (should-not (string-search "project-skill" text))
        (should (string-search "project-agent" text)))
      ;; And unfolding brings them back.
      (goto-char (point-min))
      (should (search-forward "Skills (4)" nil t))
      (goto-char (line-beginning-position))
      (ecc-capabilities-toggle)
      (should (string-search "project-skill" (ecc-test-buffer-string))))))

(ert-deftest ecc-dashboard-test-capabilities-without-init ()
  "A session that has not heard from the CLI yet says so rather than fails."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      (ecc-capabilities-mode)
      (ecc-capabilities-draw session)
      (should (string-search "Nothing yet" (ecc-test-buffer-string))))))

(provide 'ecc-dashboard-test)

;;; ecc-dashboard-test.el ends here
