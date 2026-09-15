;;; ecc-image-test.el --- Tests for ecc-image  -*- lexical-binding: t; -*-

;;; Commentary:

;; The directory a session writes its images to, what a file is named
;; and when it is swept away.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-image)

(defmacro ecc-image-test--with-dir (&rest body)
  "Run BODY with `ecc-image-dir' pointing at a directory of its own."
  (declare (indent 0))
  `(let ((ecc-image-dir (make-temp-file "ecc-images" t)))
     (unwind-protect (progn ,@body)
       (when (file-directory-p ecc-image-dir)
         (delete-directory ecc-image-dir t)))))

(ert-deftest ecc-image-test-save-writes-under-the-session ()
  "An image lands in the directory of its session, named by its type."
  (ecc-test-with-fake-session session
    (ecc-image-test--with-dir
      (let ((file (ecc-image-save session "\x89PNG-data" "image/png")))
        (should (file-exists-p file))
        (should (equal (file-name-extension file) "png"))
        (should (string-prefix-p (expand-file-name (ecc-session-id session)
                                                   ecc-image-dir)
                                 file))
        ;; jpeg keeps the extension the CLI expects.
        (should (equal (file-name-extension
                        (ecc-image-save session "x" "image/jpeg"))
                       "jpg"))
        ;; A name given by hand is what the file is called.
        (should (equal (file-name-nondirectory
                        (ecc-image-save session "x" "image/png" "abc123"))
                       "abc123.png"))
        (should (ecc-image-cleanup-session session))
        (should-not (file-exists-p file))))))

(ert-deftest ecc-image-test-images-can-be-kept ()
  "With cleanup off the files outlive the session."
  (ecc-test-with-fake-session session
    (let ((ecc-image-cleanup 'never))
      (ecc-image-test--with-dir
        (let ((file (ecc-image-save session "x" "image/png")))
          (should-not (ecc-image-cleanup-session session))
          (should (file-exists-p file)))))))

(provide 'ecc-image-test)

;;; ecc-image-test.el ends here
