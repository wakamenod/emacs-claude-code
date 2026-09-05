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
                    :name "mine"
                    :project-root (ecc-resume-test--cwd file))))
      (unwind-protect
          (let ((candidates (ecc--session-candidates (ecc-resume-test--cwd file))))
            ;; The recording is the same session, so it is not repeated.
            (should (= 1 (length candidates)))
            (should (string-search "mine" (caar candidates)))
            (should (string-search "この Emacs" (caar candidates))))
        (ecc-test-cleanup-session session)))))

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
                                 (lambda (_prompt candidates &rest _)
                                   (setq asked candidates)
                                   (car (last candidates)))))
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
