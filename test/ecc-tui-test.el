;;; ecc-tui-test.el --- Tests for ecc-tui  -*- lexical-binding: t; -*-

;;; Commentary:

;; The hand-off to the terminal client: the command it is opened with
;; (FR-TUI-1, 2), the transcript following the recording while it is
;; there (FR-TUI-3), the session coming back afterwards (FR-TUI-4) and
;; the rule that only one process may have a session at a time
;; (FR-TUI-5).  No terminal is started here; what would open one is
;; replaced.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-tui)
(require 'ecc-session)
(require 'ecc-render)

(defvar ecc-tui-test--opened nil
  "What the fake terminal was asked to open.")

(defmacro ecc-tui-test--with-session (var &rest body)
  "Run BODY with VAR bound to a session whose terminal is a fake one.
The process the session would run is pretended to be alive until
`ecc-proc-stop' is called, so that the hand-off has something to stop."
  (declare (indent 1) (debug (symbolp body)))
  `(ecc-test-with-fake-session ,var
     (let ((ecc-tui-test--opened nil)
           (ecc-tui--handoffs (make-hash-table :test #'equal))
           ;; Nothing here answers an interrupt on its own, so the wait
           ;; for the turn to end is kept short.
           (ecc-tui-interrupt-timeout 0.3)
           (alive t)
           (stopped nil)
           (interrupted nil))
       (ignore stopped interrupted)
       (cl-letf* (((symbol-function 'process-live-p) (lambda (&rest _) alive))
                  ((symbol-function 'ecc-proc-interrupt)
                   (lambda (session)
                     (setq interrupted t)
                     ;; The CLI answers an interrupt with a result, which
                     ;; is what takes the session out of `running'.
                     (ecc-model-set-state session 'idle)))
                  ((symbol-function 'ecc-proc-stop)
                   (lambda (_session) (setq stopped t alive nil)))
                  ((symbol-function 'ecc-registry-session) (lambda (_id) nil))
                  ((symbol-function 'ecc-tui--open-vterm)
                   (lambda (session)
                     (setq ecc-tui-test--opened (ecc-tui-shell-command session))
                     (get-buffer-create (ecc-tui-buffer-name session)))))
         (unwind-protect (progn ,@body)
           (ecc-tui-follow-stop ,var)
           (when-let* ((buffer (get-buffer (ecc-tui-buffer-name ,var))))
             (kill-buffer buffer)))))))

;;;; The command the terminal is opened with (FR-TUI-1, FR-TUI-2)

(ert-deftest ecc-tui-test-command ()
  "The terminal resumes the same session with the interactive CLI."
  (ecc-test-with-fake-session session
    (setf (ecc-session-options session) '(:model "haiku" :max-budget-usd 0.5))
    (should (equal (ecc-tui-arguments session)
                   (list ecc-executable "--resume" (ecc-session-id session)
                         "--model" "haiku" "--max-budget-usd" "0.5")))
    ;; None of the headless flags belong in a terminal.
    (should-not (member "--output-format" (ecc-tui-arguments session)))
    (should-not (member "-p" (ecc-tui-arguments session)))
    (let ((ecc-tui-extra-args '("--effort" "high")))
      (should (equal (last (ecc-tui-arguments session) 2) '("--effort" "high"))))
    (should (string-search (format "--resume %s" (ecc-session-id session))
                           (ecc-tui-shell-command session)))))

(ert-deftest ecc-tui-test-external-command ()
  "An external terminal is described by a command with specifications."
  (ecc-test-with-fake-session session
    (setf (ecc-session-cwd session) "/tmp/work/")
    (let ((ecc-tui-external-command "open -na Ghostty --args -e %c --resume %i"))
      (should (equal (ecc-tui-external-command session)
                     (format "open -na Ghostty --args -e %s --resume %s"
                             ecc-executable (ecc-session-id session)))))
    (let ((ecc-tui-external-command "cd %d && %c --resume %i"))
      (should (string-prefix-p "cd /tmp/work/ && " (ecc-tui-external-command session))))))

;;;; Only one process at a time (FR-TUI-5)

(ert-deftest ecc-tui-test-stops-the-process-first ()
  "The session is interrupted and stopped before the terminal opens."
  (ecc-tui-test--with-session session
    (ecc-model-set-state session 'running)
    (ecc-tui-open session)
    (should interrupted)
    (should stopped)
    (should (eq (ecc-session-state session) 'idle))
    (should ecc-tui-test--opened)
    (should (eq (ecc-session-kind session) 'handoff))
    (should (ecc-tui-handoff-p session))
    ;; It cannot be handed over twice.
    (should-error (ecc-tui-open session) :type 'user-error)))

(ert-deftest ecc-tui-test-a-turn-that-ignores-the-interrupt-is-waited-out ()
  "The wait for a running turn has an end, and the process goes anyway."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-proc-interrupt)
               (lambda (_session) (setq interrupted t))))
      (ecc-model-set-state session 'running)
      (let ((start (float-time)))
        (ecc-tui-open session)
        (should (>= (- (float-time) start) ecc-tui-interrupt-timeout)))
      (should interrupted)
      (should stopped)
      (should (ecc-tui-handoff-p session)))))

(ert-deftest ecc-tui-test-refuses-when-the-process-will-not-stop ()
  "A process that will not die keeps the session: two of them branch it."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-proc-stop) (lambda (_session) nil)))
      (should-error (ecc-tui-open session) :type 'user-error))
    (should-not ecc-tui-test--opened)
    (should-not (ecc-tui-handoff-p session))
    (should-not (eq (ecc-session-kind session) 'handoff))))

(ert-deftest ecc-tui-test-refuses-when-another-process-has-it ()
  "A session already running elsewhere is named rather than resumed."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-registry-session)
               (lambda (_id) '((pid . 4242) (name . "elsewhere")))))
      (should-error (ecc-tui-open session) :type 'user-error))
    (should-not ecc-tui-test--opened)))

;;;; Following the recording while the terminal has it (FR-TUI-3)

(defun ecc-tui-test--write (file lines)
  "Write LINES to FILE, each followed by a newline."
  (with-temp-file file
    (let ((coding-system-for-write 'utf-8-unix))
      (dolist (line lines) (insert line "\n")))))

(defun ecc-tui-test--append (file text)
  "Append TEXT to FILE as it stands."
  (with-temp-buffer
    (let ((coding-system-for-write 'utf-8-unix))
      (insert text)
      (write-region (point-min) (point-max) file t 'quiet))))

(ert-deftest ecc-tui-test-follow-reads-what-the-terminal-appends ()
  "The transcript keeps up with the recording the terminal writes."
  (let* ((file (make-temp-file "ecc-tui-" nil ".jsonl"))
         (lines (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents (ecc-test-history-fixture "session")))
                  (split-string (buffer-string) "\n" t)))
         (half (/ (length lines) 2)))
    (unwind-protect
        (ecc-tui-test--with-session session
          (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) file))
                    ;; Nothing may be watched in batch; the timer and the
                    ;; explicit read are what the test drives.
                    ((symbol-function 'file-notify-add-watch)
                     (lambda (&rest _) nil)))
            (ecc-tui-test--write file (seq-take lines half))
            (ecc-tui-open session)
            ;; What the recording already held is not replayed: the
            ;; transcript on screen already has it.
            (should (= (length (ecc-session-turns session)) 0))
            (should (= (ecc-tui-read-new-lines session) 0))
            ;; The terminal appends; the buffer follows.
            (ecc-tui-test--write file lines)
            (should (> (ecc-tui-read-new-lines session) 0))
            (let ((turns (length (ecc-session-turns session))))
              (should (> turns 0))
              ;; A line that is only half written is left for next time.
              (ecc-tui-test--append file "{\"type\":\"user\",\"mess")
              (should (= (ecc-tui-read-new-lines session) 0))
              (should (= (length (ecc-session-turns session)) turns))
              (ecc-tui-test--append
               file (concat "age\":{\"role\":\"user\",\"content\":\"and now?\"},"
                            "\"uuid\":\"z\",\"parentUuid\":null,"
                            "\"timestamp\":\"2026-09-06T00:00:00.000Z\"}\n"))
              (should (= (ecc-tui-read-new-lines session) 1))
              (should (= (length (ecc-session-turns session)) (1+ turns)))
              (should (equal (ecc-turn-prompt
                              (car (last (ecc-session-turns session))))
                             "and now?")))
            ;; A recording replaced under us is picked up from its end
            ;; rather than replayed from the top.
            (let ((turns (length (ecc-session-turns session))))
              (ecc-tui-test--write file (seq-take lines 2))
              (should (= (ecc-tui-read-new-lines session) 0))
              (should (= (length (ecc-session-turns session)) turns)))))
      (delete-file file))))

(ert-deftest ecc-tui-test-buffer-says-where-the-session-is ()
  "The transcript says the session is in a terminal (FR-TUI-3)."
  (ecc-tui-test--with-session session
    (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil)))
      (ecc-session-ensure-buffer session)
      (ecc-tui-open session)
      (ecc-render-flush session)
      (should (string-search "open in the terminal"
                             (ecc-test-buffer-string (ecc-session-buffer session))))
      (with-current-buffer (ecc-session-buffer session)
        (should (string-search "⇄ terminal" (ecc-render-mode-line-process)))
        (should (string-search "handed over to the terminal"
                               (substring-no-properties (ecc-render-header-line))))))))

;;;; Coming back (FR-TUI-4)

(ert-deftest ecc-tui-test-returns-when-the-terminal-is-gone ()
  "The session is resumed headless once its terminal buffer has ended."
  (ecc-tui-test--with-session session
    (let ((resumed nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) nil))
                ((symbol-function 'ecc-proc-start)
                 (lambda (_session &optional resume _fork) (setq resumed resume))))
        (ecc-tui-open session)
        (should-not (ecc-tui-finished-p session))
        ;; While the terminal is there, nothing is resumed.
        (ecc-tui--tick session)
        (should-not resumed)
        (should (ecc-tui-handoff-p session))
        (kill-buffer (ecc-tui-buffer-name session))
        (should (ecc-tui-finished-p session))
        (ecc-tui--tick session)
        (should (eq resumed t))
        (should (eq (ecc-session-kind session) 'own))
        (should-not (ecc-tui-handoff-p session))))))

(ert-deftest ecc-tui-test-does-not-resume-behind-a-live-terminal ()
  "A terminal that is still running keeps the session (FR-TUI-5)."
  (ecc-tui-test--with-session session
    (let ((resumed nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) t))
                ((symbol-function 'ecc-proc-start)
                 (lambda (_session &optional resume _fork) (setq resumed resume))))
        (ecc-tui-open session)
        (kill-buffer (ecc-tui-buffer-name session))
        (should-not (ecc-tui-return session))
        (should-not resumed)))))

(ert-deftest ecc-tui-test-external-terminal-is-watched-in-the-registry ()
  "An external terminal is over once it has been seen and is gone."
  (ecc-tui-test--with-session session
    (let ((live nil))
      (cl-letf (((symbol-function 'ecc-history-file) (lambda (_id) nil))
                ((symbol-function 'ecc-registry-live-p) (lambda (_id) live))
                ((symbol-function 'ecc-tui--open-external) (lambda (_session) nil)))
        (let ((ecc-tui-terminal 'external))
          (ecc-tui-open session))
        ;; Not there yet: the terminal is still starting up, not gone.
        (should-not (ecc-tui-finished-p session))
        (setq live t)
        (should-not (ecc-tui-finished-p session))
        (setq live nil)
        (should (ecc-tui-finished-p session))))))

(provide 'ecc-tui-test)

;;; ecc-tui-test.el ends here
