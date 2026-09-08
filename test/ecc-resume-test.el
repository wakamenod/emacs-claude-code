;;; ecc-resume-test.el --- Tests for finding a session to resume  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-resume' used to know only the sessions this Emacs had started, so
;; it had nothing to offer in a fresh Emacs.  It now offers the
;; recordings of the project as well, and refuses to resume a session
;; another process is running (FR-SES-4, FR-HIST-3, FR-TUI-5).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)

(defmacro ecc-resume-test--with-recordings (var &rest body)
  "Run BODY with VAR bound to a recording of a project, and nothing running.
The recording is laid out the way the CLI does it, under a registry
that has no sessions in it."
  (declare (indent 1))
  `(let* ((root (make-temp-file "ecc-resume" t))
          (project (expand-file-name "-tmp-project" root))
          (,var (expand-file-name "24a1aa86-d53f-4457-b09e-4f4caf450f03.jsonl"
                                  project))
          (registry (make-temp-file "ecc-resume-registry" t))
          (ecc-history-directory root)
          (ecc-history--files (make-hash-table :test #'equal))
          (ecc-history--abandoned (make-hash-table :test #'equal))
          (ecc-registry-directory registry)
          (ecc--sessions (make-hash-table :test #'equal))
          (ecc--session-order nil)
          (ecc-render-debounce 0))
     (unwind-protect
         (progn
           (make-directory project t)
           (copy-file (ecc-test-history-fixture "session") ,var)
           ,@body)
       (delete-directory root t)
       (delete-directory registry t))))

(defun ecc-resume-test--cwd (file)
  "Return the working directory the recording FILE was made in."
  (alist-get 'cwd (ecc-history-scan-file file)))

;;;; Choosing a session (FR-SES-4)

(ert-deftest ecc-resume-test-offers-the-recordings-of-the-project ()
  "With nothing running, the recordings of this project are the candidates."
  (ecc-resume-test--with-recordings file
    (let ((candidates (ecc--session-candidates (ecc-resume-test--cwd file))))
      (should (= 1 (length candidates)))
      (should (equal "24a1aa86-d53f-4457-b09e-4f4caf450f03" (cdar candidates)))
      ;; The label says what it was called and what was last said in it.
      (should (string-search "Hello" (caar candidates)))
      ;; Another project has none of it.
      (should-not (ecc--session-candidates
                   (expand-file-name "ecc-elsewhere" temporary-file-directory))))))

(ert-deftest ecc-resume-test-own-sessions-come-first ()
  "A session of this Emacs is offered before the recordings, and only once."
  (ecc-resume-test--with-recordings file
    (let ((session (ecc-model-create-session
                    :id "24a1aa86-d53f-4457-b09e-4f4caf450f03"
                    :name "local"
                    :project-root (ecc-resume-test--cwd file))))
      (unwind-protect
          (let ((candidates (ecc--session-candidates (ecc-resume-test--cwd file))))
            ;; The recording is the same session, so it is not repeated.
            (should (= 1 (length candidates)))
            (should (string-search "local" (caar candidates)))
            ;; It opens with the icon of a session this Emacs holds.
            (should (string-prefix-p (ecc--session-status-icon 'own)
                                     (caar candidates))))
        (ecc-test-cleanup-session session)))))

(ert-deftest ecc-resume-test-a-session-of-this-emacs-is-timed-too ()
  "A session this Emacs holds is timed like a recording is.
It has answered nothing yet, so the time comes from its recording."
  (ecc-resume-test--with-recordings file
    (let ((session (ecc-model-create-session
                    :id "24a1aa86-d53f-4457-b09e-4f4caf450f03"
                    :name "local"
                    :project-root (ecc-resume-test--cwd file))))
      (unwind-protect
          (progn
            (should (string-search "just now"
                                   (caar (ecc--session-candidates
                                          (ecc-resume-test--cwd file)))))
            ;; Once it has answered, that is what the label reads from.
            (setf (ecc-session-last-result-time session)
                  (time-subtract (current-time) (* 3 3600)))
            (should (string-search "3 hours ago"
                                   (caar (ecc--session-candidates
                                          (ecc-resume-test--cwd file))))))
        (ecc-test-cleanup-session session)))))

(ert-deftest ecc-resume-test-the-columns-line-up ()
  "Every label puts its columns at the same place, whatever the script.
A Japanese title is twice as wide as it is long, so the fields are
measured in columns; with the length they would drift apart."
  (let* ((time (time-subtract (current-time) 3600))
         (ascii (ecc--session-label 'own "session order" time "hello"))
         (japanese (ecc--session-label 'own "セッション並び順" time "こんにちは"))
         (long (ecc--session-label
                'own "セッションの並び順とアイコンの見た目を直したいという話"
                time "x"))
         (column (lambda (label)
                   ;; Where the time column starts on the display.
                   (string-width (car (split-string label "1 hour ago"))))))
    (should (= (funcall column ascii) (funcall column japanese)))
    (should (= (funcall column ascii) (funcall column long)))
    ;; A title too long for its column is cut, not allowed to push.
    (should (string-search "…" long))))

(ert-deftest ecc-resume-test-the-status-is-one-icon ()
  "The state of a session is the single glyph the label opens with."
  (dolist (status '(running own elsewhere recorded))
    (let ((icon (ecc--session-status-icon status)))
      (should (= 1 (string-width icon)))
      (should (string-prefix-p icon (ecc--session-label status "n" nil "")))))
  ;; Without nerd-icons the ASCII stand-ins are used, and they differ.
  (let* ((ecc-visual--nerd-icons nil)
         (icons (mapcar #'ecc--session-status-icon
                        '(running own elsewhere recorded))))
    (should (equal '(">" "*" "@" "-") icons))))

(ert-deftest ecc-resume-test-time-label-reads-as-an-age ()
  "The time column says how long ago the conversation was worked in."
  (let ((label (lambda (seconds)
                 (ecc--session-time-label
                  (time-subtract (current-time) seconds)))))
    (should (equal "" (ecc--session-time-label nil)))
    (should (equal "just now" (funcall label 5)))
    (should (equal "1 minute ago" (funcall label 60)))
    (should (equal "5 minutes ago" (funcall label (* 5 60))))
    (should (equal "1 hour ago" (funcall label 3600)))
    (should (equal "3 hours ago" (funcall label (* 3 3600))))
    (should (equal "1 day ago" (funcall label 86400)))
    (should (equal "2 days ago" (funcall label (* 2 86400))))
    (should (equal "1 week ago" (funcall label (* 8 86400))))
    (should (equal "3 weeks ago" (funcall label (* 21 86400))))
    (should (equal "1 month ago" (funcall label (* 31 86400))))
    (should (equal "8 months ago" (funcall label (* 250 86400))))
    (should (equal "1 year ago" (funcall label (* 400 86400))))
    (should (equal "2 years ago" (funcall label (* 800 86400))))
    ;; Every label fits the column it is put in.
    (should (<= (length (funcall label (* 800 86400))) 14))))

(ert-deftest ecc-resume-test-the-table-keeps-the-order ()
  "The completion table hands the candidates over in the order they are in.
Without it the completion UI sorts them by name or by length, and the
most recent conversation is no longer the first one."
  (let* ((candidates '(("b newest" . "1") ("a older" . "2")))
         (table (ecc--session-table candidates))
         (metadata (cdr (funcall table "" nil 'metadata))))
    (should (equal '("b newest" "a older") (all-completions "" table)))
    (should (eq 'identity (alist-get 'display-sort-function metadata)))
    (should (eq 'identity (alist-get 'cycle-sort-function metadata)))))

(ert-deftest ecc-resume-test-reads-the-recording-back ()
  "Picking a recording gives a session with the conversation in it."
  (ecc-resume-test--with-recordings file
    (let* ((default-directory (ecc-resume-test--cwd file))
           (session (cl-letf (((symbol-function 'completing-read)
                               (lambda (&rest _) (error "Only one, do not ask"))))
                      (ecc-read-session))))
      (unwind-protect
          (progn
            (should (equal "24a1aa86-d53f-4457-b09e-4f4caf450f03"
                           (ecc-session-id session)))
            (should (eq 'archived (ecc-session-kind session))))
        (ecc-test-cleanup-session session)))))

(ert-deftest ecc-resume-test-asks-when-there-is-a-choice ()
  "With more than one candidate the user is asked which one."
  (ecc-resume-test--with-recordings file
    (let ((second (expand-file-name "11111111-1111-1111-1111-111111111111.jsonl"
                                    (file-name-directory file))))
      (copy-file file second)
      (let* ((default-directory (ecc-resume-test--cwd file))
             (asked nil)
             (session (cl-letf (((symbol-function 'completing-read)
                                 (lambda (_prompt table &rest _)
                                   (setq asked (all-completions "" table))
                                   (car (last asked)))))
                        (ecc-read-session))))
        (unwind-protect
            (progn
              (should (= 2 (length asked)))
              (should (ecc-session-p session)))
          (ecc-test-cleanup-session session))))))

(ert-deftest ecc-resume-test-widens-when-the-project-has-none ()
  "A project with no recording falls back to every recording."
  (ecc-resume-test--with-recordings file
    (let* ((default-directory temporary-file-directory)
           (candidates (or (ecc--session-candidates
                            (expand-file-name "ecc-elsewhere"
                                              temporary-file-directory))
                           (ecc--session-candidates))))
      (should (= 1 (length candidates)))
      (ignore file))))

(ert-deftest ecc-resume-test-nothing-anywhere ()
  "With no session and no recording, the error says so."
  (let ((ecc-history-directory (make-temp-file "ecc-resume-empty" t))
        (ecc--sessions (make-hash-table :test #'equal))
        (ecc--session-order nil))
    (unwind-protect
        (should-error (ecc-read-session) :type 'user-error)
      (delete-directory ecc-history-directory t))))

;;;; Refusing to run a session twice (FR-TUI-5)

(ert-deftest ecc-resume-test-refuses-a-session-another-process-runs ()
  "Resuming a session the registry says is running asks first.
Two CLIs on one recording write into the same file and the conversation
grows a second branch, so this may not happen by accident."
  (ecc-resume-test--with-recordings file
    (let ((session (ecc-history-session
                    "24a1aa86-d53f-4457-b09e-4f4caf450f03" file)))
      (unwind-protect
          (progn
            ;; Another process reports it is running this very session.
            (with-temp-file (expand-file-name "4242.json" ecc-registry-directory)
              (insert (ecc--json-write
                       '((pid . 4242)
                         (sessionId . "24a1aa86-d53f-4457-b09e-4f4caf450f03")
                         (name . "elsewhere") (status . "busy")))))
            (let ((ecc-registry-check-process nil))
              ;; Saying no stops it.
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                        ((symbol-function 'ecc-proc-start)
                         (lambda (&rest _) (error "It resumed anyway"))))
                (should-error (ecc-history-resume session) :type 'user-error))
              ;; Saying yes lets it through: the user may know better.
              (let (started)
                (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                          ((symbol-function 'ecc-proc-start)
                           (lambda (s &optional resume fork)
                             (setq started (list s resume fork)))))
                  (ecc-history-resume session)
                  (should (equal (list session t nil) started))))))
        (ecc-test-cleanup-session session)))))

(ert-deftest ecc-resume-test-nothing-running-does-not-ask ()
  "A session nobody is running is resumed without a question."
  (ecc-resume-test--with-recordings file
    (let ((session (ecc-history-session
                    "24a1aa86-d53f-4457-b09e-4f4caf450f03" file))
          (started nil))
      (unwind-protect
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) (error "It asked for no reason")))
                    ((symbol-function 'ecc-proc-start)
                     (lambda (s &optional resume fork)
                       (setq started (list s resume fork)))))
            (ecc-history-resume session)
            (should (equal (list session t nil) started)))
        (ecc-test-cleanup-session session)))))

(provide 'ecc-resume-test)

;;; ecc-resume-test.el ends here
