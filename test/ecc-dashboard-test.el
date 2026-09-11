;;; ecc-dashboard-test.el --- Tests for ecc-dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; The rows of the session list, the order they come in and what the
;; keys of the list do.
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

;;;; The rows

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

;;;; The order

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

;;;; The buffer and its keys

(defmacro ecc-dashboard-test--in-buffer (&rest body)
  "Draw the dashboard without asking the CLI and run BODY inside it."
  `(cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
     (let ((buffer (ecc-dashboard)))
       (unwind-protect
           (with-current-buffer buffer ,@body)
         (kill-buffer buffer)))))

(defun ecc-dashboard-test--first-row ()
  "Go to the first row, which is the line after the column header.
The header line carries the summary, so the names of the columns are a
line of the buffer and the list starts below them."
  (goto-char (point-min))
  (ecc-dashboard--first-row))

(ert-deftest ecc-dashboard-test-buffer-lists-every-row ()
  "The buffer holds one line per session, the waiting one first."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (should (derived-mode-p 'ecc-dashboard-mode))
     ;; The column header, and a line per session under it.
     (should (= 3 (count-lines (point-min) (point-max))))
     (ecc-dashboard-test--first-row)
     (should (equal "other" (ecc-dashboard-entry-name (tabulated-list-get-id))))
     ;; The columns are all filled.
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
  "The a and d keys answer the oldest request of the row."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (ecc-dashboard-test--first-row)
     (ecc-dashboard-allow)
     (should-not (ecc-session-pending b))
     (should (equal "allow" (alist-get 'behavior (ecc-test-response 0))))
     ;; The row of a session that is not waiting says so rather than
     ;; answering something else.
     (ecc-dashboard-test--first-row)
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
         (ecc-dashboard-test--first-row)
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
  "D deletes the recording of the row, but only after a yes."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-model-set-session-id b ecc-dashboard-test-recording)
    (ecc-dashboard-test--in-buffer
     (ecc-dashboard-test--first-row)
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
  "r renames a session of this Emacs and its buffer."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-session-ensure-buffer b)
    (ecc-dashboard-test--in-buffer
     (ecc-dashboard-test--first-row)
     (ecc-dashboard-rename "renamed")
     (should (equal "renamed" (ecc-session-name b)))
     (should (get-buffer "*ecc: renamed*"))
     (should-error (ecc-dashboard-rename "") :type 'user-error)
     (ignore a))))

(ert-deftest ecc-dashboard-test-stop ()
  "k stops the session of the row and takes it off the list."
  (ecc-dashboard-test--with-two-sessions a b
    (ecc-dashboard-test--in-buffer
     (ecc-dashboard-test--first-row)
     (ecc-dashboard-stop)
     (should-not (ecc-model-session (ecc-session-id b)))
     (should (member "test" (ecc-dashboard-test--names (ecc-dashboard-entries))))
     (ignore a))))

;;;; What the list looks like

(ert-deftest ecc-dashboard-test-state-cell-says-what-it-is-doing ()
  "The State cell carries a mark, the word, and the colour of the state."
  (ecc-dashboard-test--with-two-sessions a b
    (let* ((entries (ecc-dashboard-entries))
           (waiting (car entries))
           (idle (cadr entries)))
      (should (eq b (ecc-dashboard-entry-session waiting)))
      (let ((cell (ecc-dashboard--state-cell waiting)))
        (should (string-search "waiting" cell))
        (should (eq 'ecc-pending-face (get-text-property 0 'face cell))))
      (let ((cell (ecc-dashboard--state-cell idle)))
        (should (string-search "idle" cell))
        (should (eq 'ecc-dim-face (get-text-property 0 'face cell))))
      ;; More than one request waiting is counted.
      (ecc-test-add-request b "Bash")
      (should (string-search "×2" (ecc-dashboard--state-cell
                                   (car (ecc-dashboard-entries)))))
      ;; A session that runs turns a spinner in place of a mark, and
      ;; wears a plain one where the spinner is turned off.
      (ecc-model-set-state a 'running)
      (let* ((running (lambda ()
                        (ecc-dashboard--state-cell
                         (seq-find (lambda (entry)
                                     (eq a (ecc-dashboard-entry-session entry)))
                                   (ecc-dashboard-entries)))))
             (cell (let ((ecc-visual-enable-spinner t)) (funcall running))))
        (should (string-search "running" cell))
        (should (member (substring-no-properties cell 0 1)
                        (append ecc-visual-spinner-frames nil)))
        (let ((ecc-visual-enable-spinner nil))
          (should (string-prefix-p "▶ running"
                                   (substring-no-properties
                                    (funcall running)))))))))

(ert-deftest ecc-dashboard-test-quiet-rows-are-dimmed ()
  "A row that is neither working nor waiting has its detail dimmed."
  (ecc-dashboard-test--with-two-sessions a b
    (setf (ecc-session-total-cost a) 1.5)
    (setf (ecc-session-total-cost b) 0.25)
    (let* ((rows (mapcar #'ecc-dashboard--row (ecc-dashboard-entries)))
           (waiting (cadr (car rows)))
           (idle (cadr (cadr rows))))
      (should (equal "$1.50" (substring-no-properties (aref idle 6))))
      (should (eq 'ecc-dim-face (get-text-property 0 'face (aref idle 6))))
      (should-not (get-text-property 0 'face (aref waiting 6))))))

(ert-deftest ecc-dashboard-test-summary-counts-what-there-is ()
  "The summary above the list counts the rows and adds their cost up.
`format-mode-line' says nothing in batch, so the function behind the
header line is called itself."
  (ecc-dashboard-test--with-two-sessions a b
    (setf (ecc-session-total-cost a) 1.5)
    (setf (ecc-session-total-cost b) 0.25)
    (let ((summary (ecc-dashboard--summary (ecc-dashboard-entries))))
      (should (string-search "1 waiting" summary))
      (should (string-search "1 idle" summary))
      (should-not (string-search "running" summary))
      (should (string-search "$1.75" summary)))
    (ecc-model-set-state a 'running)
    (should (string-search "1 running" (ecc-dashboard--summary
                                        (ecc-dashboard-entries))))
    ;; The rate limit the sessions are closest to is drawn as a bar,
    ;; and the header line doubles the percent sign it ends with.
    (setf (ecc-session-rate-limit b)
          '((unifiedWindows . ((five_hour . ((utilization . 0.61)))))))
    (let ((summary (ecc-dashboard--summary (ecc-dashboard-entries))))
      (should (string-search "61%" summary))
      (should (string-search "61%%" (ecc-dashboard--header-line))))))

(ert-deftest ecc-dashboard-test-summary-of-an-empty-list ()
  "With nothing to list the summary says how to start something."
  (should (string-search "+ starts one" (ecc-dashboard--summary nil))))

(ert-deftest ecc-dashboard-test-gutter-marks-the-rows ()
  "The gutter marks a row waiting for an answer, and one on screen."
  (ecc-dashboard-test--with-two-sessions a b
    (let ((entries (ecc-dashboard-entries)))
      (should (equal "!" (substring-no-properties
                          (ecc-dashboard--tag (car entries)))))
      (should-not (ecc-dashboard--tag (cadr entries))))
    (ecc-dashboard-test--in-buffer
     (ecc-dashboard-test--first-row)
     (should (equal "!" (buffer-substring-no-properties (point) (1+ (point)))))
     (ignore a b))))

(provide 'ecc-dashboard-test)

;;; ecc-dashboard-test.el ends here
