;;; ecc-live-test.el --- Tests that run the real CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; These are the acceptance checks of phase 1 that need a process.  They
;; are tagged `live' and `make test' skips them; run them by hand with
;;
;;     make test-live
;;
;; Every session started here follows the rules of CLAUDE.md: the cheap
;; model, a spending cap, and the emacs-gravity plugin switched off so
;; that its hooks stay out of the recording.  Nothing is persisted, so
;; the sessions cannot be resumed afterwards and leave nothing behind.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)
(require 'ecc-history)
(require 'ecc-registry)
(require 'ecc-dashboard)

(defconst ecc-test-live-options
  '(:model "haiku"
    :max-budget-usd 0.5
    :streaming nil
    :disabled-plugins ("emacs-bridge@emacs-gravity-marketplace")
    :extra-args ("--no-session-persistence"))
  "Launch options every live test uses.")

(defvar ecc-test-live-timeout 90
  "Seconds a live test waits for the CLI before giving up.")

(defun ecc-test-live-wait (session predicate &optional what)
  "Wait until PREDICATE returns non-nil for SESSION, then return its value.
WHAT names the thing waited for in the error message."
  (let ((deadline (+ (float-time) ecc-test-live-timeout))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline)
                (process-live-p (ecc-session-process session)))
      (accept-process-output (ecc-session-process session) 0.2))
    (unless value
      (ert-fail (format "timed out waiting for %s" (or what "the CLI"))))
    value))

(defun ecc-test-live-wait-for-result (session)
  "Wait until the current turn of SESSION is finished."
  (ecc-test-live-wait session
                      (lambda () (and (null (ecc-session-current-turn session))
                                      (car (last (ecc-session-turns session)))))
                      "a result"))

(defmacro ecc-test-live-with-session (var &rest body)
  "Run BODY with VAR bound to a started session, killed afterwards."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (default-directory temporary-file-directory)
          (,var (ecc-model-create-session
                 :name "live"
                 :project-root temporary-file-directory
                 :options ecc-test-live-options)))
     (unwind-protect
         (progn
           (ecc-session-ensure-buffer ,var)
           ;; Nothing is waited for here: system/init only arrives once a
           ;; prompt has been sent (docs/verified.md), so a test that
           ;; waited for it before sending would hang.
           (ecc-proc-start ,var)
           ,@body)
       (ecc-proc-stop ,var)
       (ecc-test-cleanup-session ,var))))

(defun ecc-test-live-turn-text (turn)
  "Return the assistant text of TURN as one string."
  (mapconcat (lambda (node)
               (if (eq (ecc-node-type node) 'text)
                   (or (ecc-model-node-get node 'text) "")
                 ""))
             (ecc-turn-children turn) ""))

(ert-deftest ecc-test-live-basic ()
  "One prompt, one turn, a result with a cost, and a drawn transcript."
  :tags '(live)
  (ecc-test-live-with-session session
    (ecc-proc-send-prompt session "Reply with exactly: PONG")
    (let ((turn (ecc-test-live-wait-for-result session)))
      ;; The slash commands arrived in the initialize answer (FR-SES-8),
      ;; and system/init came with the turn.
      (should (ecc-session-commands session))
      (should (ecc-session-init session))
      (should (string-search "PONG" (ecc-test-live-turn-text turn)))
      (should (> (ecc-session-total-cost session) 0))
      (should (eq (ecc-session-state session) 'idle)))
    (ecc-render-flush session)
    (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
      (should (string-search "▌ Reply with exactly: PONG" text))
      (should (string-match-p "● end_turn · [0-9]+ turns · \\$" text)))))

(ert-deftest ecc-test-live-permission ()
  "Deny with a reason, get a new proposal, allow it, and see the file."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live" t))
           (file (expand-file-name "hello.txt" directory))
           (answered 0))
      (unwind-protect
          (progn
            ;; The prompt leaves the content open, so that the reason
            ;; given with the deny is a correction and not a contradiction
            ;; the model would rather ask about than act on.
            (ecc-proc-send-prompt
             session
             (format "Create the file %s containing a short greeting." file))
            ;; First proposal: refuse it and say what to write instead.
            (let ((request (ecc-test-live-wait
                            session (lambda () (car (ecc-session-pending session)))
                            "the first permission request")))
              (should (equal (ecc-request-tool-name request) "Write"))
              (should (eq (ecc-request-kind request) 'permission))
              (ecc-perm-respond request 'deny
                                :message "Make the content exactly: hello from emacs")
              (cl-incf answered))
            ;; Second proposal: allow it.
            (let ((request (ecc-test-live-wait
                            session (lambda () (car (ecc-session-pending session)))
                            "the second permission request")))
              (should (equal (alist-get 'content (ecc-request-input request))
                             "hello from emacs"))
              (ecc-perm-respond request 'allow)
              (cl-incf answered))
            (ecc-test-live-wait-for-result session)
            (should (= answered 2))
            (should (file-exists-p file))
            (should (equal (with-temp-buffer
                             (insert-file-contents file)
                             (string-trim (buffer-string)))
                           "hello from emacs"))
            (should-not (ecc-session-pending session)))
        (delete-directory directory t)))))

(ert-deftest ecc-test-live-slash-command ()
  "A slash command comes back as a synthetic reply (FR-INP-2, 4.2)."
  :tags '(live)
  (ecc-test-live-with-session session
    (ecc-proc-send-prompt session "/context")
    (let* ((turn (ecc-test-live-wait-for-result session))
           (text (seq-find (lambda (node) (eq (ecc-node-type node) 'text))
                           (ecc-turn-children turn))))
      (should text)
      (should (ecc-model-node-get text 'synthetic))
      ;; A synthetic answer costs nothing, so it must not move the
      ;; context estimate (plan section 9, item 12).
      (should (= (ecc-session-context-tokens session) 0)))))

(ert-deftest ecc-test-live-interrupt ()
  "An interrupt is answered and the turn ends (FR-SES-5)."
  :tags '(live)
  (ecc-test-live-with-session session
    (let ((answer nil))
      (ecc-proc-send-prompt session
                            "Count slowly from 1 to 500, one number per line.")
      (ecc-test-live-wait session
                          (lambda () (ecc-turn-children
                                      (ecc-session-current-turn session)))
                          "the turn to start")
      (ecc-proc-control session "interrupt"
                        (lambda (_session response) (setq answer (or response t))))
      (ecc-test-live-wait session (lambda () answer) "the interrupt answer")
      (ecc-test-live-wait-for-result session)
      (should-not (ecc-session-pending session))
      (should (process-live-p (ecc-session-process session))))))


(ert-deftest ecc-test-live-streaming ()
  "A long Write streams its input and the reply grows delta by delta.
The phase 2 acceptance check: each delta costs well under 5ms to draw."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live" t))
           (file (expand-file-name "long.py" directory))
           (deltas 0)
           (drawn 0.0)
           (text-seen nil))
      (setf (ecc-session-options session)
            (plist-put (copy-sequence ecc-test-live-options) :streaming t))
      ;; The process was started with the shared options; restart it with
      ;; --include-partial-messages.
      (ecc-proc-stop session)
      (ecc-test-live-wait session (lambda () (not (process-live-p (ecc-session-process session))))
                          "the process to stop")
      (setf (ecc-session-auto-approve-kinds session) '("Write"))
      (ecc-proc-start session)
      (unwind-protect
          (let ((ecc-stream-delta-hook
                 (cons (lambda (session node text)
                         (cl-incf deltas)
                         (when (eq (ecc-node-type node) 'text)
                           (setq text-seen t))
                         (cl-incf drawn
                                  (car (benchmark-run 1
                                         (ecc-render--on-delta session node text)))))
                       (remq #'ecc-render--on-delta ecc-stream-delta-hook)))
                (ecc-stream-throttle 0))
            (ecc-proc-send-prompt
             session
             (format "Write the file %s with 60 Python functions f0 to f59, each returning its number, separated by blank lines. Then reply with one short sentence." file))
            (let ((turn (ecc-test-live-wait-for-result session)))
              (should (file-exists-p file))
              (should (> deltas 5))
              (should text-seen)
              (message "streaming: %d deltas, %.2fms each to draw" deltas (* 1000 (/ drawn deltas)))
              (should (< (/ drawn deltas) 0.005))
              ;; Streamed blocks and complete messages made one tree.
              (should (seq-find (lambda (node) (and (eq (ecc-node-type node) 'step)
                                                    (= 1 (length (ecc-node-children node)))))
                                (ecc-turn-children turn)))
              (should (= 0 (hash-table-count (ecc-session-stream-blocks session))))
              (ecc-render-flush session)
              (let ((text (ecc-test-buffer-string (ecc-session-buffer session))))
                (should (string-search "✓ Write" text))
                (should (string-search "@@ -0,0 +1," text))
                (should (string-search "Files (1)" text)))))
        (delete-directory directory t)))))

;;;; Phase 3 (permissions, plan review, Inbox, file sync)

(defun ecc-test-live-wait-any (sessions predicate &optional what)
  "Wait until PREDICATE returns non-nil, reading output from all SESSIONS.
WHAT names the thing waited for in the error message."
  (let ((deadline (+ (float-time) ecc-test-live-timeout))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline)
                (seq-some (lambda (session) (process-live-p (ecc-session-process session)))
                          sessions))
      (accept-process-output nil 0.2))
    (unless value
      (ert-fail (format "timed out waiting for %s" (or what "the CLI"))))
    value))

(defun ecc-test-live-restart (session options)
  "Stop the CLI of SESSION and start it again with OPTIONS."
  (setf (ecc-session-options session) options)
  (ecc-proc-stop session)
  (ecc-test-live-wait session
                      (lambda () (not (process-live-p (ecc-session-process session))))
                      "the process to stop")
  (ecc-proc-start session))

(defun ecc-test-live-wait-for-plan (session &optional previous)
  "Wait until SESSION has a plan request other than PREVIOUS and return it."
  (ecc-test-live-wait session
                      (lambda ()
                        (let ((request (car (ecc-session-pending session))))
                          (and request
                               (eq (ecc-request-kind request) 'plan)
                               (not (eq request previous))
                               request)))
                      "a plan review request"))

(ert-deftest ecc-test-live-plan ()
  "Feedback in the plan buffer sends the three sections and brings a new plan.
A clean approval then allows and switches the session to acceptEdits
\(the phase 3 acceptance check for FR-PLAN-1 to 5)."
  :tags '(live)
  (ecc-test-live-with-session session
    (let ((directory (make-temp-file "ecc-live-plan" t)))
      (unwind-protect
          (progn
            (setf (ecc-session-project-root session) (file-name-as-directory directory))
            (ecc-test-live-restart session
                                   (append '(:permission-mode "plan" :max-budget-usd 1.0)
                                           ecc-test-live-options))
            (ecc-proc-send-prompt
             session
             "Make a short plan (5 lines at most) for creating utils.py with add(a, b) and sub(a, b). Then call ExitPlanMode. Do not implement anything.")
            (let* ((first (ecc-test-live-wait-for-plan session))
                   (feedback nil))
              (should (alist-get 'plan (ecc-request-input first)))
              (with-current-buffer (ecc-plan-open first)
                (should (derived-mode-p 'ecc-plan-mode))
                (goto-char (point-min))
                (ecc-plan-comment "keep each function a one-liner")
                (goto-char (point-max))
                (insert "\nUse type hints on both functions.\n")
                (insert "@claude: add mul(a, b) as a third function\n")
                (setq feedback (ecc-plan-approve)))
              (should (string-search "## Inline comments:" feedback))
              (should (string-search "## @claude markers:" feedback))
              (should (string-search "## Changes requested:" feedback))
              (should (eq (ecc-node-status (ecc-request-node first)) 'denied))
              ;; The revised plan comes back as a new request.
              (let ((second (ecc-test-live-wait-for-plan session first)))
                (message "revised plan mentions mul: %s"
                         (and (string-search "mul" (ecc-plan-text second)) t))
                (with-current-buffer (ecc-plan-open second)
                  ;; FR-PLAN-5: the lines that changed are marked.
                  (should (ecc-plan-changed-lines))
                  (should-not (ecc-plan-approve "acceptEdits")))
                (ecc-test-live-wait-for-result session)
                (should-not (ecc-session-pending session))
                ;; system/status reported the switch (FR-PLAN-4).
                (should (equal (ecc-session-permission-mode session) "acceptEdits")))))
        (delete-directory directory t)))))

(ert-deftest ecc-test-live-pattern ()
  "A Bash request offers Bash(touch *) and the pattern lands in the settings.
Afterwards a matching command is sent again to see whether the running
CLI picks the new rule up without a restart.  A read-only command such
as git status is not used: the CLI runs those without asking."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live-pattern" t))
           (file (expand-file-name ".claude/settings.local.json" directory)))
      (unwind-protect
          (progn
            (setf (ecc-session-project-root session) (file-name-as-directory directory))
            (ecc-test-live-restart session ecc-test-live-options)
            (ecc-proc-send-prompt
             session "Run exactly `touch build.marker` with the Bash tool, then reply with one word.")
            (let ((request (ecc-test-live-wait
                            session (lambda () (car (ecc-session-pending session)))
                            "the Bash permission request")))
              (should (equal (ecc-request-tool-name request) "Bash"))
              (let ((patterns (ecc-perm-suggest-patterns
                               "Bash" (ecc-request-input request) directory)))
                (should (member "Bash(touch *)" patterns))
                (cl-letf (((symbol-function 'completing-read-multiple)
                           (lambda (&rest _) (list "Bash(touch *)")))
                          ((symbol-function 'y-or-n-p) (lambda (_) t)))
                  (with-current-buffer (ecc-session-buffer session)
                    (ecc-perm-add-pattern))))
              (should (equal (ecc-protocol-settings-allow-list
                              (ecc-protocol-read-settings-file file))
                             '("Bash(touch *)")))
              (should-not (ecc-session-pending session)))
            (ecc-test-live-wait-for-result session)
            ;; Does the running CLI honour the new rule?  Either outcome is
            ;; recorded; the answer goes to docs/verified.md.
            (ecc-proc-send-prompt session "Run exactly `touch other.marker` with the Bash tool, then reply with one word.")
            (let ((asked (ecc-test-live-wait
                          session
                          (lambda () (or (car (ecc-session-pending session))
                                         (and (null (ecc-session-current-turn session))
                                              'finished)))
                          "the second Bash call")))
              (message "settings.local.json hot reload: %s"
                       (if (eq asked 'finished) "yes (no can_use_tool arrived)"
                         "no (can_use_tool arrived again)"))
              (unless (eq asked 'finished)
                (ecc-perm-respond asked 'allow)
                (ecc-test-live-wait-for-result session))))
        (delete-directory directory t)))))

(ert-deftest ecc-test-live-inbox ()
  "Two sessions wait at once; the Inbox lists both and the oldest is answered first."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live-inbox" t))
           (other (ecc-model-create-session :name "live-2"
                                            :project-root temporary-file-directory
                                            :options ecc-test-live-options))
           (ecc-answer-confirm nil)
           ;; The model may reach for Bash instead of Write; both count here.
           (ecc-answer-exclude-tools nil))
      (unwind-protect
          (progn
            (ecc-session-ensure-buffer other)
            (ecc-proc-start other)
            (ecc-proc-send-prompt
             session (format "Create the file %s containing the word one, using the Write tool."
                             (expand-file-name "one.txt" directory)))
            (ecc-proc-send-prompt
             other (format "Create the file %s containing the word two, using the Write tool."
                           (expand-file-name "two.txt" directory)))
            (ecc-test-live-wait-any (list session other)
                                    (lambda () (= 2 (length (ecc-model-pending-all))))
                                    "two permission requests")
            (should (= 2 (length (ecc-inbox-entries))))
            (should (equal (sort (mapcar (lambda (e) (aref (cadr e) 1)) (ecc-inbox-entries))
                                 #'string<)
                           '("live" "live-2")))
            (let ((oldest (car (ecc-model-pending-all))))
              (should (eq (ecc-answer-allow) oldest))
              (should (= 1 (length (ecc-model-pending-all))))
              (should (ecc-answer-allow))
              (should-not (ecc-model-pending-all)))
            (ecc-test-live-wait-any (list session other)
                                    (lambda () (and (null (ecc-session-current-turn session))
                                                    (null (ecc-session-current-turn other))))
                                    "both results")
            (should (file-exists-p (expand-file-name "one.txt" directory)))
            (should (file-exists-p (expand-file-name "two.txt" directory))))
        (ecc-proc-stop other)
        (ecc-test-cleanup-session other)
        (delete-directory directory t)))))

(ert-deftest ecc-test-live-sync ()
  "An Edit by Claude reverts the buffer visiting the file; an unsaved one is warned."
  :tags '(live)
  (ecc-test-live-with-session session
    (let* ((directory (make-temp-file "ecc-live-sync" t))
           (file (expand-file-name "greet.py" directory))
           (buffer nil))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "def greet(name):\n    return \"hi \" + name\n"))
            (setq buffer (find-file-noselect file))
            (setf (ecc-session-auto-approve-kinds session) '("Edit" "Write"))
            (ecc-proc-send-prompt
             session (format "In %s replace the string \"hi \" with \"hello \" using the Edit tool. Do nothing else." file))
            (ecc-test-live-wait-for-result session)
            (should (string-search "hello" (with-current-buffer buffer (buffer-string))))
            (should-not (buffer-modified-p buffer))
            ;; Now the buffer has unsaved changes: it is left alone.
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "# local note\n"))
            (ecc-proc-send-prompt
             session (format "In %s replace the string \"hello \" with \"hey \" using the Edit tool. Do nothing else." file))
            (ecc-test-live-wait-for-result session)
            (should (string-search "hey " (with-temp-buffer (insert-file-contents file)
                                                            (buffer-string))))
            (should (buffer-modified-p buffer))
            (should (string-search "# local note" (with-current-buffer buffer (buffer-string))))
            (should (string-search "hello" (with-current-buffer buffer (buffer-string)))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))
        (delete-directory directory t)))))


(defun ecc-test-live-git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (with-temp-buffer
    (let ((default-directory directory))
      (unless (= (apply #'call-process "git" nil t nil args) 0)
        (ert-fail (format "git %s failed: %s" args (buffer-string)))))))

(defun ecc-test-live-file-string (file)
  "Return the trimmed content of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (string-trim (buffer-string))))

(ert-deftest ecc-test-live-review ()
  "The phase 4 acceptance check: three files changed, two hunks commented,
one prompt sent, and the files corrected the way the comments said
\(FR-DIFF-3, 4, 5).  One file is untracked, so its diff comes from the
records and not from git."
  :tags '(live)
  (skip-unless (executable-find "git"))
  (ecc-test-live-with-session session
    (let* ((directory (file-name-as-directory
                       (file-truename (make-temp-file "ecc-live-review" t))))
           (greeting (concat directory "greeting.txt"))
           (farewell (concat directory "farewell.txt"))
           (notes (concat directory "notes.txt"))
           (review nil))
      (setf (ecc-session-auto-approve-kinds session) '("Write" "Edit" "MultiEdit"))
      (unwind-protect
          (progn
            (ecc-test-live-git directory "init" "-q")
            (ecc-test-live-git directory "config" "user.email" "t@example.com")
            (ecc-test-live-git directory "config" "user.name" "t")
            (with-temp-file greeting (insert "hello\n"))
            (with-temp-file farewell (insert "bye\n"))
            (ecc-test-live-git directory "add" ".")
            (ecc-test-live-git directory "commit" "-q" "-m" "init")
            (ecc-proc-send-prompt
             session
             (format (concat "Using only the Edit and Write tools (no shell): "
                             "in %s replace the word in greeting.txt with: hi ; "
                             "replace the word in farewell.txt with: ciao ; "
                             "and create notes.txt containing the single word: todo")
                     directory))
            (ecc-test-live-wait-for-result session)
            (should (equal (ecc-test-live-file-string greeting) "hi"))
            (should (equal (ecc-test-live-file-string farewell) "ciao"))
            (should (equal (ecc-test-live-file-string notes) "todo"))
            ;; The review: git for the two tracked files, the records for
            ;; the new one, all in one buffer.
            (should (= (length (ecc-review-files session)) 3))
            (setq review (ecc-review-buffer session))
            (with-current-buffer review
              (let ((text (buffer-string)))
                (should (string-search "diff --git a/farewell.txt b/farewell.txt" text))
                (should (string-search "diff --git a/greeting.txt b/greeting.txt" text))
                (should (string-search "-bye\n+ciao\n" text))
                (should (string-search "-hello\n+hi\n" text))
                (should (string-search (format "--- /dev/null\n+++ %s\n" notes) text))
                (should (string-search "+todo\n" text)))
              (should (equal default-directory directory))
              (should (= (length (ecc-review-hunks)) 3))
              ;; Comment on the two git hunks, leave the new file alone.
              (goto-char (point-min))
              (diff-hunk-next)
              (ecc-review-comment "Use the word adios instead of ciao.")
              (diff-hunk-next)
              (ecc-review-comment "Use the word hey instead of hi.")
              (should (equal (mapcar (lambda (c) (plist-get c :path)) (ecc-review-comments))
                             '("farewell.txt" "greeting.txt")))
              (ecc-review-send)
              (with-current-buffer (ecc-review-message-buffer-name session)
                (let ((text (buffer-string)))
                  (should (string-prefix-p ecc-review-header text))
                  (should (string-search "## farewell.txt  L1-L1\n```diff\n@@ -1 +1 @@\n-bye\n+ciao\n```\nComment: Use the word adios instead of ciao." text))
                  (should (string-search "## greeting.txt  L1-L1\n" text)))
                (ecc-review-message-send)))
            (should-not (buffer-live-p review))
            (ecc-test-live-wait-for-result session)
            (should (equal (ecc-test-live-file-string farewell) "adios"))
            (should (equal (ecc-test-live-file-string greeting) "hey"))
            (should (equal (ecc-test-live-file-string notes) "todo")))
        (when (buffer-live-p review) (kill-buffer review))
        (delete-directory directory t)))))


;;;; Phase 5: the recording, resuming it, and the session list

(defconst ecc-test-live-persistent-options
  '(:model "haiku"
    :max-budget-usd 0.5
    :streaming nil
    :disabled-plugins ("emacs-bridge@emacs-gravity-marketplace"))
  "Launch options for a live test that needs the CLI to keep a recording.
The same as `ecc-test-live-options' without --no-session-persistence:
a test of the history has to have a history to read.")

(defmacro ecc-test-live-with-recorded-session (var &rest body)
  "Run BODY with VAR a started session the CLI writes a recording for.
The working directory and the recording are both removed afterwards."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-history--files (make-hash-table :test #'equal))
          (directory (file-name-as-directory (make-temp-file "ecc-live-hist" t)))
          (default-directory directory)
          (,var (ecc-model-create-session
                 :name "live-hist"
                 :project-root directory
                 :options ecc-test-live-persistent-options)))
     (unwind-protect
         (progn
           (ecc-session-ensure-buffer ,var)
           (ecc-proc-start ,var)
           ,@body)
       (ecc-proc-stop ,var)
       (ecc-test-cleanup-session ,var)
       (let ((recording (expand-file-name
                         (ecc-history-project-directory directory)
                         (expand-file-name ecc-history-directory))))
         (when (file-directory-p recording)
           (delete-directory recording t)))
       (delete-directory directory t))))

(ert-deftest ecc-test-live-history-resume ()
  "A recording is read back and the CLI carries on from it (FR-HIST-1, 3)."
  :tags '(live)
  (ecc-test-live-with-recorded-session session
    (ecc-proc-send-prompt session "Remember the word ZARQUON.  Reply with: OK")
    (ecc-test-live-wait-for-result session)
    (let ((id (ecc-session-id session)))
      ;; The CLI wrote the conversation down where we expect it.
      (ecc-proc-stop session)
      (ecc-test-live-wait session
                          (lambda () (not (process-live-p (ecc-session-process session))))
                          "the CLI to stop")
      (let ((file (ecc-history-file id)))
        (should file)
        ;; Emacs forgets the session, the way restarting would; what is
        ;; left is the recording, and that is what is read back.
        (ecc-model-remove-session session)
        (let ((archived (ecc-history-session id file)))
          (unwind-protect
              (progn
                (should (eq 'archived (ecc-session-kind archived)))
                (ecc-session-ensure-buffer archived)
                (should (= 1 (ecc-history-load archived)))
                (should (string-search
                         "ZARQUON"
                         (ecc-turn-prompt (car (ecc-session-turns archived)))))
                ;; Resuming appends to what was read, and the CLI still
                ;; remembers the conversation.  Nobody is running the
                ;; session any more, so nothing may be asked: the file
                ;; the killed CLI left in the registry is stale, and
                ;; `ecc-registry' has to see through it (FR-TUI-5).
                (setf (ecc-session-options archived)
                      ecc-test-live-persistent-options)
                (should-not (ecc-registry-live-p id))
                (cl-letf (((symbol-function 'yes-or-no-p)
                           (lambda (&rest _)
                             (ert-fail "asked about a session nobody runs"))))
                  (ecc-history-resume archived))
                (ecc-proc-send-prompt
                 archived "Which word did I ask you to remember?  Answer with it alone.")
                (let ((turn (ecc-test-live-wait-for-result archived)))
                  (should (= 2 (length (ecc-session-turns archived))))
                  (should (string-search "ZARQUON"
                                         (upcase (ecc-test-live-turn-text turn))))))
            (ecc-proc-stop archived)
            (ecc-test-cleanup-session archived)))))))

(ert-deftest ecc-test-live-agents ()
  "The registry agrees with `claude agents --json' (FR-DASH-2, FR-DASH-6).
The dashboard reads the files rather than running the command, so this
is what keeps the two from drifting apart."
  :tags '(live)
  (let* ((output (with-output-to-string
                   (with-current-buffer standard-output
                     (call-process ecc-executable nil t nil "agents" "--json"))))
         (reported (ecc-protocol-parse-agents output))
         (registry (ecc-registry-sessions)))
    ;; This very test runs inside a session, so neither is empty.
    (should reported)
    (should registry)
    ;; The command also lists background sessions that have finished,
    ;; which leave no file behind; every running one is in both.
    (let ((running (seq-filter (lambda (a) (alist-get 'pid a)) reported)))
      (should (equal (sort (mapcar (lambda (a) (alist-get 'sessionId a)) running)
                           #'string<)
                     (sort (mapcar (lambda (a) (alist-get 'sessionId a)) registry)
                           #'string<)))
      (dolist (agent running)
        (let ((entry (ecc-registry-session (alist-get 'sessionId agent))))
          (should entry)
          (should (equal (alist-get 'pid agent) (alist-get 'pid entry)))
          (should (equal (alist-get 'cwd agent) (alist-get 'cwd entry)))
          (should (equal (alist-get 'status agent) (alist-get 'status entry)))
          (should (ecc-dashboard--agent-entry entry)))))))

(ert-deftest ecc-test-live-context ()
  "A region sent from a source buffer arrives quoted (FR-CTX-5 c)."
  :tags '(live)
  (ecc-test-live-with-session session
    (with-temp-buffer
      (insert "def add(a, b):\n    return a - b\n")
      (setq buffer-file-name (expand-file-name "calc.py" temporary-file-directory))
      (unwind-protect
          (let ((ecc-render--session nil))
            ;; No transcript is current, so the session is the one this
            ;; buffer resolves to (FR-WIN-4).
            (ecc-send-region (point-min) (point-max)
                             "この関数のバグを一語で答えて。説明は不要。")
            (let ((text (ecc-test-live-turn-text
                         (ecc-test-live-wait-for-result session))))
              ;; The quote block reached the model: it can only answer
              ;; from the code, which is nowhere but in the prompt.
              (should (string-match-p
                       "subtract\\|minus\\|sign\\|operator\\|引き算\\|減算\\|マイナス\\|符号\\|演算子\\|-"
                       text))))
        (setq buffer-file-name nil)))
    (let ((prompt (ecc-turn-prompt (car (ecc-session-turns session)))))
      (should (string-search "```python" prompt))
      (should (string-search "return a - b" prompt))
      (should (string-search "`calc.py` L1-L2" prompt)))))

(ert-deftest ecc-test-live-image ()
  "An image is passed by path and the model can see it (FR-INP-9)."
  :tags '(live)
  (ecc-test-live-with-session session
    (let ((file (expand-file-name "red-square.png"
                                  (expand-file-name "fixtures" ecc-test-directory))))
      (should (file-exists-p file))
      ;; This is what pasting an image into the prompt buffer leaves
      ;; behind: a path, never base64 in the conversation.
      (ecc-proc-send-prompt
       session (format "@%s この画像の色を英語の一語で答えて。" file))
      ;; Reading the file is a tool call, and it needs an answer.
      (let ((deadline (+ (float-time) ecc-test-live-timeout)))
        (while (and (ecc-session-current-turn session)
                    (< (float-time) deadline)
                    (process-live-p (ecc-session-process session)))
          (accept-process-output (ecc-session-process session) 0.2)
          (when-let* ((request (car (ecc-session-pending session))))
            (ecc-perm-respond request 'allow))))
      (let ((text (ecc-test-live-turn-text
                   (car (last (ecc-session-turns session))))))
        (should (string-match-p "\\(?:^\\|[^a-zA-Z]\\)[Rr]ed" text))))))

(ert-deftest ecc-test-live-recap ()
  "/recap comes back as one synthetic line, outside the transcript (FR-HINT-1)."
  :tags '(live)
  (ecc-test-live-with-session session
    (ecc-proc-send-prompt
     session "Reply with exactly: PONG.  Do not use any tool.")
    (ecc-test-live-wait-for-result session)
    ;; The recap waits for the user to have been away; the wait itself
    ;; is what the timers of `ecc-hint-mode' do, and is not worth two
    ;; minutes of a test.
    (setf (ecc-session-last-result-time session)
          (time-subtract (current-time) 300))
    (should-not (ecc-hint-maybe-recap session))
    ;; It went out without opening a turn the transcript shows.
    (should (= (length (ecc-session-turns session)) 1))
    (should (ecc-turn-transient (ecc-session-current-turn session)))
    (ecc-test-live-wait session
                        (lambda () (ecc-hint-recap-get session 'text))
                        "the recap")
    ;; The result of the transient turn follows the line itself.
    (ecc-test-live-wait session
                        (lambda () (null (ecc-session-current-turn session)))
                        "the end of the recap turn")
    (let ((text (ecc-hint-recap-get session 'text)))
      ;; One line, and about this conversation.
      (should (> (length text) 10))
      (should-not (string-search "\n" text))
      ;; The conversation itself is untouched: one turn, the one asked.
      (should (= (length (ecc-session-turns session)) 1))
      (should (eq (ecc-session-state session) 'idle))
      (ecc-render-flush session)
      (let ((drawn (ecc-test-buffer-string (ecc-session-buffer session))))
        (should (string-search "✎ " drawn))
        (should (string-search (car (split-string text "  " t)) drawn))))
    ;; Nothing new has been said, so it is not asked again (FR-HINT-2).
    (should (eq (ecc-hint-maybe-recap session) 'unchanged))))

(ert-deftest ecc-test-live-context-left ()
  "The context left falls as the conversation grows (FR-HINT-3)."
  :tags '(live)
  (ecc-test-live-with-session session
    ;; The window is the one guessed from the model, since the session
    ;; was started without --autocompact: what is measured here is that
    ;; the estimate moves the right way, not the guess itself.
    (should-not (ecc-hint-context-left session))
    (ecc-proc-send-prompt session "Reply with exactly: ONE.  Do not use any tool.")
    (ecc-test-live-wait-for-result session)
    (let ((first (ecc-hint-context-left session))
          (tokens (ecc-session-context-tokens session)))
      ;; The estimate is the input side of the usage the CLI reported.
      (should (> tokens 0))
      (should (and (> first 0.0) (< first 1.0)))
      (should (string-search "context" (ecc-hint-context-string session)))
      (ecc-proc-send-prompt session "Reply with exactly: TWO.  Do not use any tool.")
      (ecc-test-live-wait-for-result session)
      (should (> (ecc-session-context-tokens session) tokens))
      (should (< (ecc-hint-context-left session) first))
      ;; The mode line says the same thing in one line.
      (should (string-match-p "%" (ecc-hint-mode-line-string session))))))


;;;; The Emacs MCP server (FR-MCP-1, the acceptance check of phase 8)

(ert-deftest ecc-test-live-mcp ()
  "Claude uses a tool this Emacs published, and its answer comes back.
The acceptance criterion of phase 8: a session started with
--mcp-config reaches the server of `ecc-mcp' and the tool_result holds
what the Elisp function returned."
  :tags '(live)
  (require 'ecc-mcp)
  (let ((ecc-mcp-port 0)
        (ecc-mcp-enabled t))
    (unwind-protect
        (progn
          (ecc-mcp-define-tool
           :name "ecc_live_probe"
           :description "Return the secret word this Emacs is holding.  \
Call it whenever the user asks for the secret word."
           :args nil
           :function (lambda () "shibboleth-42"))
          (ecc-test-live-with-session session
            ;; The server is up and the session was told where it is.
            (should (ecc-mcp-running-p))
            (should (member "--mcp-config" (ecc-proc-build-command session)))
            (ecc-proc-send-prompt
             session
             "Use the mcp__emacs__ecc_live_probe tool and reply with exactly \
what it returned, and nothing else.")
            (let* ((turn (ecc-test-live-wait-for-result session))
                   (text (ecc-test-live-turn-text turn)))
              ;; The CLI registered the server ...
              (should (seq-find
                       (lambda (server)
                         (equal (alist-get 'name server) ecc-mcp-server-name))
                       (append (alist-get 'mcp_servers
                                          (ecc-session-init session))
                               nil)))
              ;; ... and what the Elisp function returned came back.
              (should (string-search "shibboleth-42" text)))))
      (remhash "ecc_live_probe" ecc-mcp-tools)
      (ecc-mcp-stop))))

(provide 'ecc-live-test)

;;; ecc-live-test.el ends here
