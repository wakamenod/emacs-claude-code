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
(require 'ecc-git-test)

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

(ert-deftest ecc-lifecycle-test-start-does-not-wait-for-the-baseline ()
  "A session comes up while git is still reading the tree for its review.
With an antivirus that scans every file git opens, the `git add -A' of
the baseline took 15 s on a repository of 5700 files (2026-10-20), and
Emacs was frozen for all of it.  A prompt sent meanwhile waits in the
queue, since the CLI must not touch a file before the baseline has
it, and goes out once it is taken."
  (skip-unless (executable-find "git"))
  (ecc-git-test--with-directory directory
    (ecc-git-test--repository directory)
    (let* ((slow (make-temp-file "ecc-slow-git"))
           (ecc-git-executable slow)
           (ecc-test-sent nil)
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (session nil))
      (with-temp-file slow
        (insert (format "#!/bin/sh\n[ \"$1\" = add ] && sleep 1\nexec %s \"$@\"\n"
                        (shell-quote-argument (executable-find "git")))))
      (set-file-modes slow #o755)
      (unwind-protect
          (cl-letf (((symbol-function #'ecc-proc-start)
                     (lambda (session &rest _)
                       (setf (ecc-session-process session)
                             (make-process :name "ecc-test-cli"
                                           :command '("sleep" "60")
                                           :noquery t))))
                    ((symbol-function #'ecc-proc-send-json)
                     (lambda (_session object) (push object ecc-test-sent) object))
                    ((symbol-function #'ecc--enable-session-modes) #'ignore)
                    ((symbol-function #'ecc-window-select-session) #'ignore))
            (let ((start (float-time)))
              (setq session (ecc-start directory "slow"))
              (should (< (- (float-time) start) 0.5)))
            (should-not (ecc-session-baseline session))
            (should (equal (ecc-proc-send-prompt session "hello") 1))
            (should-not ecc-test-sent)
            (let ((deadline (+ (float-time) 10)))
              (while (and (not (ecc-session-baseline session))
                          (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (equal (ecc-session-baseline session)
                           (let ((ecc-git-executable "git"))
                             (ecc-git-snapshot directory))))
            (should-not (ecc-session-input-queue session))
            (should (equal (ecc-test-sent-text 0) "hello")))
        (when session
          (delete-process (ecc-session-process session))
          (ecc-test-cleanup-session session))
        (delete-file slow)))))

(provide 'ecc-lifecycle-test)

;;; ecc-lifecycle-test.el ends here
