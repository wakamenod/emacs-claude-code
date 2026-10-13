;;; ecc-lifecycle-test.el --- Tests for the way into a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; The autoloads of `ecc-start' and `ecc-resume' load `ecc-lifecycle'
;; alone, and so does every module above it that starts a session.  A
;; session wants the whole package, some of which registers itself when
;; it is loaded, so the way in loads `ecc' before the CLI starts.  Only a
;; second Emacs can show that: this one has the package loaded already.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)

(defun ecc-lifecycle-test--cold (form)
  "Run FORM in an Emacs that has loaded nothing but the autoloads.
`ecc-proc-start' is replaced by a throw, so that no CLI is started and
what was loaded is read at the moment one would have been.  Return
what FORM printed last."
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (script (make-temp-file "ecc-cold" nil ".el"))
        (directory (file-name-as-directory (make-temp-file "ecc-cold" t))))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t -*-\n")
            (prin1 `(progn
                      (setq load-path ',load-path
                            default-directory ,directory)
                      (load "ecc-autoloads" nil t)
                      (when (featurep 'ecc-lifecycle)
                        (error "The autoloads loaded the package"))
                      (advice-add 'ecc-proc-start :override
                                  (lambda (&rest _)
                                    (throw 'started
                                           (mapcar #'featurep
                                                   '(ecc ecc-hint ecc-mcp
                                                         ecc-transient)))))
                      (princ (format "\n%S\n" (catch 'started ,form nil))))
                   (current-buffer)))
          (with-temp-buffer
            (should (= 0 (call-process emacs nil t nil "-Q" "--batch" "-l" script)))
            (car (last (split-string (string-trim (buffer-string)) "\n")))))
      (delete-file script)
      (delete-directory directory t))))

(ert-deftest ecc-lifecycle-test-start-loads-the-package ()
  "A session started as the first command of an Emacs has the package.
The autoload of `ecc-start' loads `ecc-lifecycle', and the features
only `ecc' loads have to be there before the CLI starts."
  (should (equal (ecc-lifecycle-test--cold
                  '(ecc-start default-directory "cold"))
                 "(t t t t)")))

(ert-deftest ecc-lifecycle-test-resume-loads-the-package ()
  "A session resumed as the first command of an Emacs has the package."
  (should (equal (ecc-lifecycle-test--cold
                  '(progn
                     (require 'ecc-model)
                     (ecc-resume (ecc-model-create-session
                                  :project-root default-directory
                                  :name "cold"))))
                 "(t t t t)")))

(provide 'ecc-lifecycle-test)

;;; ecc-lifecycle-test.el ends here
