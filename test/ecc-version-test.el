;;; ecc-version-test.el --- Tests for reporting the version  -*- lexical-binding: t; -*-

;;; Commentary:

;; The version lives in one place, the Version header of ecc.el, and is
;; read back from there.  These tests are what catches a release that
;; forgot to move it, and a `ecc-version' that breaks on a machine with
;; no CLI on it -- which is the machine it is most often called on.

;;; Code:

(require 'ert)
(require 'ecc)

(ert-deftest ecc-version-test-is-the-header ()
  "`ecc-version' holds a version number, not the \"unknown\" fallback."
  (should (stringp ecc-version))
  (should (string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\'" ecc-version)))

(ert-deftest ecc-version-test-matches-the-source ()
  "The version read back is the one written in the header of ecc.el."
  (let ((file (locate-library "ecc.el" t)))
    (should file)
    (should (equal ecc-version
                   (with-temp-buffer
                     (insert-file-contents file nil 0 4096)
                     (lm-header "version"))))))

(ert-deftest ecc-version-test-reports-without-a-cli ()
  "A missing CLI is reported, not raised."
  (let ((ecc-executable "ecc-no-such-executable"))
    (should-not (ecc--cli-version))
    (should (string-match-p "not found" (ecc-version)))))

(ert-deftest ecc-version-test-inserts-with-a-prefix ()
  "A prefix argument puts the line in the buffer instead of the echo area."
  (let ((ecc-executable "ecc-no-such-executable"))
    (with-temp-buffer
      (ecc-version t)
      (should (string-match-p (regexp-quote (format "ecc %s" ecc-version))
                              (buffer-string)))
      (should (string-match-p (regexp-quote emacs-version) (buffer-string))))))

(provide 'ecc-version-test)
;;; ecc-version-test.el ends here
