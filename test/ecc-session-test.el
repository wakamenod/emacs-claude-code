;;; ecc-session-test.el --- Tests for ecc-session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Where a session is: the root it was started in, which is what the
;; transcript's `default-directory' and everything that groups sessions
;; by project asks, and which nothing but the user moves.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-model)
(require 'ecc-dispatch)
(require 'ecc-session)
(require 'ecc-window)

(defun ecc-session-test--init (cwd)
  "Return a system/init message reporting CWD."
  `((type . "system") (subtype . "init") (cwd . ,cwd)))

(defmacro ecc-session-test--with-tree (root inner &rest body)
  "Run BODY with ROOT a fresh directory and INNER a directory inside it."
  (declare (indent 2))
  `(let* ((,root (file-name-as-directory (make-temp-file "ecc-session" t)))
          (,inner (file-name-as-directory
                   (expand-file-name "worktree" ,root))))
     (unwind-protect
         (progn (make-directory ,inner t) ,@body)
       (delete-directory ,root t))))

(ert-deftest ecc-session-test-set-name-runs-the-hook ()
  "A rename is announced, with the session, once the name is in place."
  (ecc-test-with-fake-session session
    (let* ((heard nil)
           (ecc-session-renamed-hook
            (list (lambda (s) (push (ecc-session-name s) heard)))))
      (ecc-model-set-name session "renamed")
      (should (equal heard '("renamed"))))))

(ert-deftest ecc-session-test-the-buffer-follows-a-rename-in-the-model ()
  "A name the model is given reaches the buffer before anything else hears.
`/rename\=' in the CLI renames through `ecc-model-set-name\=', which knows
no buffer; the buffer follows on `ecc-session-renamed-hook\=', ahead of
whatever else listens there."
  (ecc-test-with-fake-session session
    (let* ((buffer (ecc-session-ensure-buffer session))
           (seen nil)
           (probe (lambda (_s) (push (buffer-name buffer) seen))))
      (add-hook 'ecc-session-renamed-hook probe)
      (unwind-protect
          (should (equal (ecc-model-set-name session "renamed") "renamed"))
        (remove-hook 'ecc-session-renamed-hook probe))
      (should (equal (buffer-name buffer) (ecc-session-buffer-name "renamed")))
      (should (equal seen (list (ecc-session-buffer-name "renamed")))))))

(ert-deftest ecc-session-test-the-cli-cwd-does-not-move-the-buffer ()
  "A cwd the CLI reports leaves the transcript where the session is.
CLI 2.1.272 reports the directory the last Bash tool call left it in as
the session cwd (confirmed 2026-09-16): a model that runs `cd\\=' would
otherwise take Magit and the project commands run from the transcript
with it."
  (ecc-test-with-fake-session session
    (ecc-session-test--with-tree started moved
      (setf (ecc-session-project-root session) started
            (ecc-session-cwd session) started)
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-dispatch session (ecc-session-test--init
                               (directory-file-name moved)))
        (should (equal (ecc-session-cwd session) (directory-file-name moved)))
        (should (equal (buffer-local-value 'default-directory buffer) started))
        (should (equal (ecc-session-directory session) started))))))

(ert-deftest ecc-session-test-set-root-moves-the-buffer ()
  "The root moving takes the transcript with it, and only to a real one."
  (ecc-test-with-fake-session session
    (ecc-session-test--with-tree started moved
      (setf (ecc-session-project-root session) started)
      (let ((buffer (ecc-session-ensure-buffer session)))
        (should (equal (ecc-session-set-root session moved) moved))
        (should (equal (buffer-local-value 'default-directory buffer) moved))
        (should (equal (ecc-session-directory session) moved))
        ;; A directory that is not there is refused: a
        ;; `default-directory' pointing at nothing breaks every command
        ;; in the buffer.
        (should-not (ecc-session-set-root session "/nowhere/at/all/here/"))
        (should (equal (buffer-local-value 'default-directory buffer) moved))))))

(ert-deftest ecc-session-test-only-the-moved-session-moves ()
  "One session moving leaves the others where they are.
Two sessions, because what a move does to the one that did not move is
the part that goes wrong."
  (ecc-test-with-fake-session one
    (ecc-session-test--with-tree started moved
      (let ((two (ecc-model-create-session :name "two" :project-root started)))
        (unwind-protect
            (progn
              (setf (ecc-session-project-root one) started)
              (ecc-session-ensure-buffer one)
              (ecc-session-ensure-buffer two)
              (ecc-session-set-root one moved)
              ;; The CLI of the other one says it is somewhere else
              ;; again; neither says anything about where two is.
              (ecc-dispatch two (ecc-session-test--init
                                 (directory-file-name moved)))
              (should (equal (ecc-session-directory two) started))
              (should (equal (buffer-local-value
                              'default-directory (ecc-session-buffer two))
                             started))
              (should-not (equal (ecc-window-session-project one)
                                 (ecc-window-session-project two))))
          (ecc-test-cleanup-session two))))))

;;;; Telling the CLI the name

(defun ecc-session-test--sent-lines ()
  "Return the text of every user message sent, oldest first."
  (delq nil (mapcar (lambda (message)
                      (and (equal (alist-get 'type message) "user")
                           (alist-get 'content (alist-get 'message message))))
                    (ecc-test-sent-messages))))

(defun ecc-session-test--result (&optional cost)
  "Return the result of an ordinary turn costing COST."
  `((type . "result") (subtype . "success") (is_error . :false)
    (total_cost_usd . ,(or cost 0.01)) (result . "done")))

(ert-deftest ecc-session-test-rename-tells-the-cli ()
  "A rename of an idle session reaches its CLI at once, as /rename.
It opens no turn and goes nowhere near the queue."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-test-with-running-cli session
      (should (equal (ecc-session-rename session "refactor") "refactor"))
      (should (equal (buffer-name (ecc-session-buffer session)) "*ecc: refactor*"))
      (should (equal (ecc-session-test--sent-lines) '("/rename refactor")))
      (should-not (ecc-session-current-turn session))
      (should-not (ecc-session-turns session))
      (should-not (ecc-session-input-queue session))
      (should (eq (ecc-session-state session) 'idle))
      (should-not (ecc-session-rename-pending session))
      (should (equal (ecc-session-rename-sent session) "refactor")))))

(ert-deftest ecc-session-test-rename-sends-the-unique-name ()
  "The CLI is told NAME<2> when another session holds NAME.
The two then agree on what the session is called."
  (ecc-test-with-fake-session session
    (let ((other (ecc-model-create-session :name "refactor"
                                           :project-root temporary-file-directory)))
      (unwind-protect
          (ecc-test-with-running-cli session
            (should (equal (ecc-session-rename session "refactor") "refactor<2>"))
            (should (equal (ecc-session-test--sent-lines) '("/rename refactor<2>")))
            (should (equal (ecc-session-name other) "refactor")))
        (ecc-test-cleanup-session other)))))

(ert-deftest ecc-session-test-rename-waits-for-the-turn ()
  "A rename made while a turn runs goes once it ends, ahead of the queue.
The prompts queued meanwhile keep their order, and the rename is never
one of them."
  (ecc-test-with-fake-session session
    (ecc-test-with-running-cli session
      (ecc-proc-send-prompt session "first")
      (should (eq (ecc-proc-send-prompt session "second") 1))
      (ecc-session-rename session "refactor")
      (ecc-session-rename session "renamed")
      ;; Nothing went while the turn ran, and the queue holds the prompt alone.
      (should (equal (ecc-session-test--sent-lines) '("first")))
      (should (equal (mapcar #'ecc-queued-text (ecc-session-input-queue session))
                     '("second")))
      (should (ecc-session-rename-pending session))
      (ecc-dispatch session (ecc-session-test--result))
      ;; The last name, once, and then the queued prompt in its own turn.
      (should (equal (ecc-session-test--sent-lines)
                     '("first" "/rename renamed" "second")))
      (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "second"))
      (should-not (ecc-session-input-queue session))
      (should (equal (ecc-session-rename-sent session) "renamed")))))

(ert-deftest ecc-session-test-rename-while-one-is-out ()
  "A second rename waits for the CLI to answer the first, then goes."
  (ecc-test-with-fake-session session
    (ecc-test-with-running-cli session
      (ecc-session-rename session "one")
      (ecc-session-rename session "two")
      (should (equal (ecc-session-test--sent-lines) '("/rename one")))
      (ecc-dispatch session '((type . "result") (subtype . "success")
                              (local_command . "rename") (total_cost_usd . 0)))
      (should (equal (ecc-session-test--sent-lines) '("/rename one" "/rename two")))
      (should (equal (ecc-session-rename-sent session) "two"))
      (should-not (ecc-session-rename-pending session)))))

(ert-deftest ecc-session-test-rename-of-a-stopped-session ()
  "A session with no CLI is renamed here, and its next CLI is told."
  (ecc-test-with-fake-session session
    (ecc-model-set-state session 'exited)
    (ecc-session-rename session "later")
    (should (equal (ecc-session-name session) "later"))
    (should-not ecc-test-sent)
    (should (ecc-session-rename-pending session))
    (let ((spawn (symbol-function 'make-process))
          (process nil))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _)
                   (setq process (funcall spawn :name "ecc-test-sleep"
                                          :command '("sleep" "30") :noquery t))))
                ((symbol-function 'ecc-proc-control) #'ignore))
        (unwind-protect
            (progn
              (ecc-proc-start session t)
              (should (equal (ecc-session-test--sent-lines) '("/rename later")))
              (should-not (ecc-session-rename-pending session))
              (should-not (ecc-session-current-turn session)))
          (when process (delete-process process)))))))

(ert-deftest ecc-session-test-rename-unanswered-at-exit ()
  "A rename the CLI exited without answering waits for the next one."
  (ecc-test-with-fake-session session
    (ecc-test-with-running-cli session
      (ecc-session-rename session "refactor")
      (should (ecc-session-rename-sent session))
      (ecc-proc--handle-exit session 1 "killed")
      (should-not (ecc-session-rename-sent session))
      (should (ecc-session-rename-pending session)))))

(provide 'ecc-session-test)

;;; ecc-session-test.el ends here
