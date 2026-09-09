;;; ecc-dashboard-test.el --- Tests for ecc-dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; The rows of the session list, the order they come in and what the
;; keys of the list do (FR-DASH-1, 3, 4, 5).
;;
;; Every test uses two sessions of this Emacs: a dashboard with one row
;; hides the sorting, which is where the bugs are (CLAUDE.md).
;;
;; test/fixtures/history/session.jsonl is a recording made by
;; scripts/record-history.sh; it is what R and D work on.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-dashboard)
(require 'ecc-history)
(require 'ecc-registry)
(require 'ecc-session)

(defconst ecc-dashboard-test-recording "24a1aa86-d53f-4457-b09e-4f4caf450f03"
  "Id of the recording test/fixtures/history/session.jsonl holds.")

(defun ecc-dashboard-test--model (entries name)
  "Return the model of the row of ENTRIES called NAME."
  (ecc-dashboard-entry-model
   (seq-find (lambda (entry) (equal name (ecc-dashboard-entry-name entry)))
             entries)))

(defmacro ecc-dashboard-test--with-two-sessions (a b &rest body)
  "Run BODY with A and B two sessions of this Emacs.
A is idle, B is waiting for an answer to a Write, and a recording of
test/fixtures sits where `ecc-history-directory' looks for it."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,a
     (let* ((root (make-temp-file "ecc-dashboard" t))
            (project (expand-file-name "-tmp-project" root))
            (,b (ecc-model-create-session :name "other" :project-root root))
            (ecc-history-directory root)
            (ecc-history--files (make-hash-table :test #'equal))
            (ecc-window-use-side-window nil))
       (unwind-protect
           (progn
             (make-directory project t)
             (copy-file (ecc-test-history-fixture "session")
                        (expand-file-name
                         (concat ecc-dashboard-test-recording ".jsonl") project))
             (ecc-model-set-state ,a 'idle)
             (ecc-test-add-request ,b "Write")
             ,@body)
         (delete-directory root t)
         (ecc-test-cleanup-session ,b)))))

(defun ecc-dashboard-test--names (entries)
  "Return the names of ENTRIES, in order."
  (mapcar #'ecc-dashboard-entry-name entries))

;;;; The rows (FR-DASH-1)

(ert-deftest ecc-dashboard-test-lists-only-the-sessions-of-this-emacs ()
  "The list is the model and nothing else: no registry, no recordings."
  (ecc-dashboard-test--with-two-sessions a b
    (let ((entries (ecc-dashboard-entries)))
      (should (equal '("other" "test") (ecc-dashboard-test--names entries)))
      (should (seq-every-p #'ecc-dashboard-entry-session entries)))
    ;; A recording read back is a reader, not a conversation to answer.
    (let ((archived (ecc-history-session ecc-dashboard-test-recording)))
      (unwind-protect
          (should-not (member "Hello" (ecc-dashboard-test--names
                                       (ecc-dashboard-entries))))
        (ecc-test-cleanup-session archived)))
    (ignore a b)))

(ert-deftest ecc-dashboard-test-model-is-the-family-it-belongs-to ()
  "The Model column names a family rather than a full model."
  (ecc-dashboard-test--with-two-sessions a b
    (setf (ecc-session-last-model a) "claude-opus-5")
    (setf (ecc-session-last-model b) "claude-sonnet-4-5-20250929")
    (let ((entries (ecc-dashboard-entries)))
      (should (equal "opus" (ecc-dashboard-test--model entries "test")))
      (should (equal "sonnet" (ecc-dashboard-test--model entries "other"))))))

;;;; The order (FR-DASH-4)

(ert-deftest ecc-dashboard-test-waiting-comes-first ()
  "A session waiting for an answer is at the top, whatever its kind."
  (ecc-dashboard-test--with-two-sessions a b
    (let ((entries (ecc-dashboard-entries)))
      (should (equal "other" (ecc-dashboard-entry-name (car entries))))
      (should (= 1 (ecc-dashboard-entry-waiting (car entries))))
      (ignore a))
    ;; Once it is answered it goes back among the others, by time.
    (ecc-perm-allow-request (car (ecc-session-pending b)))
    (setf (ecc-session-last-result-time a) (current-time))
    (should (equal '("test" "other")
                   (ecc-dashboard-test--names (ecc-dashboard-entries))))))

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
  `(cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
     (let ((buffer (ecc-dashboard)))
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(ert-deftest ecc-dashboard-test-buffer-lists-every-row ()
  "The buffer holds one line per session, the waiting one first."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (should (derived-mode-p 'ecc-dashboard-mode))
     (should (= 2 (count-lines (point-min) (point-max))))
     (goto-char (point-min))
     (should (equal "other" (ecc-dashboard-entry-name (tabulated-list-get-id))))
     ;; The columns of FR-DASH-1 are all filled.
     (let ((row (tabulated-list-get-entry)))
       (should (equal "other" (aref row 0)))
       (should (string-search "waiting" (aref row 1)))
       ;; The project is the last name of the path, and the whole path
       ;; is in the tooltip.
       (should (equal (file-name-nondirectory
                       (directory-file-name (ecc-session-project-root b)))
                      (aref row 2)))
       (should (equal (abbreviate-file-name (ecc-session-project-root b))
                      (get-text-property 0 'help-echo (aref row 2))))
       ;; Time is read as words rather than as a clock.
       (should (string-match-p "\\(ago\\|just now\\)" (aref row 5))))
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
  "RET shows the transcript of the row and R resumes its recording."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-model-set-session-id b ecc-dashboard-test-recording)
    (ecc-dashboard-test--in-buffer
     (let (shown started)
       (cl-letf (((symbol-function 'ecc-display-session)
                  (lambda (session) (setq shown session) nil))
                 ((symbol-function 'select-window) #'ignore))
         (goto-char (point-min))
         (ecc-dashboard-visit)
         (should (eq shown b))
         ;; R starts the CLI on the recording of that session.
         (cl-letf (((symbol-function 'ecc-proc-start)
                    (lambda (s &optional resume fork)
                      (setq started (list s resume fork)))))
           (ecc-dashboard-resume)
           (should (equal (list b t nil) started)))))
     (ignore a))))

(ert-deftest ecc-dashboard-test-delete-asks-and-removes ()
  "D deletes the recording of the row, but only after a yes (FR-DASH-5)."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-model-set-session-id b ecc-dashboard-test-recording)
    (ecc-dashboard-test--in-buffer
     (goto-char (point-min))
     (let ((file (ecc-history-file ecc-dashboard-test-recording)))
       (should (file-exists-p file))
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
         (ecc-dashboard-delete))
       (should (file-exists-p file))
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
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

(provide 'ecc-dashboard-test)

;;; ecc-dashboard-test.el ends here
