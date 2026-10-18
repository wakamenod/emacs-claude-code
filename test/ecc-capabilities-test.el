;;; ecc-capabilities-test.el --- Tests for ecc-capabilities  -*- lexical-binding: t; -*-

;;; Commentary:

;; Which session the Capabilities buffer is about when it is asked for.
;; Two sessions are registered, so that the one a buffer belongs to and
;; the most recent one are not the same session.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-capabilities)

(defmacro ecc-capabilities-test--with-two-sessions (a b &rest body)
  "Run BODY with A and B two sessions of this Emacs, B the most recent."
  (declare (indent 2))
  `(ecc-test-with-fake-session ,a
     (let ((,b (ecc-model-create-session
                :name "other" :project-root temporary-file-directory)))
       (unwind-protect (progn ,@body)
         (ecc-test-cleanup-session ,b)))))

(ert-deftest ecc-capabilities-test-read-session-from-a-session-buffer ()
  "In a session's buffer the Capabilities are that session's."
  (ecc-capabilities-test--with-two-sessions a b
    (should (eq b (car (ecc-model-sessions))))
    (with-temp-buffer
      (setq-local ecc-render--session a)
      (should (eq a (ecc-capabilities--read-session))))))

(ert-deftest ecc-capabilities-test-read-session-elsewhere ()
  "Outside a session's buffer they are the most recent session's."
  (ecc-capabilities-test--with-two-sessions _a b
    (with-temp-buffer
      (should (eq b (ecc-capabilities--read-session))))))

(ert-deftest ecc-capabilities-test-read-session-without-one ()
  "With no session there is nothing to look at."
  (let ((ecc--sessions (make-hash-table :test #'equal))
        (ecc--session-order nil))
    (with-temp-buffer
      (should-error (ecc-capabilities--read-session) :type 'user-error))))

(ert-deftest ecc-capabilities-test-show-draws-the-session ()
  "The buffer is drawn for the session asked for, and remembers it."
  (ecc-capabilities-test--with-two-sessions a _b
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (let ((buffer (ecc-capabilities-show a)))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'ecc-capabilities-mode))
              (should (eq a ecc-capabilities--session))
              (should (eq a (ecc-capabilities--read-session)))
              (should (string-prefix-p "Capabilities of test"
                                       (buffer-string))))
          (kill-buffer buffer))))))

(provide 'ecc-capabilities-test)

;;; ecc-capabilities-test.el ends here
