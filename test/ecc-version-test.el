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

;; `ecc-version' is a constant made while ecc.el loads, so an error in
;; reading the header is an error in loading ecc.  These are the files
;; and executables that look usable and are not.

(ert-deftest ecc-version-test-header-of-a-file-that-cannot-be-read ()
  "A missing file, or a directory, has no version rather than an error."
  (let ((directory (make-temp-file "ecc-version" t)))
    (unwind-protect
        (progn
          (should-not (ecc--header-version
                       (expand-file-name "no-such.el" directory)))
          ;; Readable to `file-readable-p', and a `file-error' to read.
          (should (file-readable-p directory))
          (should-not (ecc--header-version directory)))
      (delete-directory directory t))))

(ert-deftest ecc-version-test-header-of-a-file ()
  "The Version header of a readable file is what is read back."
  (let ((file (make-temp-file "ecc-version" nil ".el"
                              (concat ";;; x.el --- x\n\n"
                                      ";; Version: 9.8.7\n"))))
    (unwind-protect
        (should (equal (ecc--header-version file) "9.8.7"))
      (delete-file file))))

(defun ecc-version-test--script (directory name text)
  "Write TEXT to an executable NAME in DIRECTORY and return its path."
  (let ((file (expand-file-name name directory)))
    (with-temp-file file (insert text))
    (set-file-modes file #o755)
    file))

(ert-deftest ecc-version-test-cli-that-cannot-start ()
  "An executable that is found and cannot be started gives a nil."
  (let ((directory (make-temp-file "ecc-version" t)))
    (unwind-protect
        (let ((ecc-executable (ecc-version-test--script
                               directory "claude"
                               "#!/no/such/interpreter\necho 1.2.3\n")))
          (should (executable-find ecc-executable))
          (should-not (ecc--cli-version))
          (should (string-match-p "not found" (ecc-version))))
      (delete-directory directory t))))

(ert-deftest ecc-version-test-cli-that-fails ()
  "An executable that exits with an error gives a nil."
  (let ((directory (make-temp-file "ecc-version" t)))
    (unwind-protect
        (let ((ecc-executable (ecc-version-test--script
                               directory "claude"
                               "#!/bin/sh\necho 1.2.3\nexit 1\n")))
          (should-not (ecc--cli-version)))
      (delete-directory directory t))))

(ert-deftest ecc-version-test-cli-number ()
  "Only the number of what the CLI prints is kept."
  (let ((directory (make-temp-file "ecc-version" t)))
    (unwind-protect
        (let ((ecc-executable (ecc-version-test--script
                               directory "claude"
                               "#!/bin/sh\necho '2.1.290 (Claude Code)'\n")))
          (should (equal (ecc--cli-version) "2.1.290")))
      (delete-directory directory t))))

(provide 'ecc-version-test)
;;; ecc-version-test.el ends here
