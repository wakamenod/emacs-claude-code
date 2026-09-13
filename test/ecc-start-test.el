;;; ecc-start-test.el --- Tests for where a session starts  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-start' used to take the project of whichever buffer was current,
;; so a session run from a transcript, the dashboard or the scratch
;; buffer landed wherever that buffer happened to be.  It now takes the
;; project of the buffer the user was working in -- one with a file or a
;; directory behind it -- and says where the session started.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)

(defmacro ecc-start-test--with-project (root &rest body)
  "Run BODY with ROOT and everything under it answering as one project.
The file system is never asked: `project-current' is told that a
directory under ROOT belongs to a transient project rooted there."
  (declare (indent 1))
  `(let ((ecc-window--project-root-cache (make-hash-table :test #'equal))
         (ecc-window--project-source-buffers nil)
         (ecc-window--last-source-buffer nil))
     (cl-letf (((symbol-function 'project-current)
                (lambda (&rest _)
                  (let ((directory (expand-file-name default-directory)))
                    (when (string-prefix-p ,root directory)
                      (cons 'transient ,root))))))
       ,@body)))

(ert-deftest ecc-start-test-root-comes-from-the-last-file-buffer ()
  "A session started from a buffer with no file behind it follows the user.
The scratch buffer, a transcript and the dashboard are all ordinary
buffers standing in some directory of their own, and starting from one
of them used to put the session there."
  (ecc-start-test--with-project "/tmp/ecc-start-project/"
    (let ((source (generate-new-buffer "a.el"))
          (scratch (generate-new-buffer "*notes*")))
      (unwind-protect
          (progn
            (with-current-buffer source
              (setq buffer-file-name "/tmp/ecc-start-project/src/a.el"
                    default-directory "/tmp/ecc-start-project/src/"))
            (with-current-buffer scratch
              (setq default-directory "/tmp/somewhere-else/"))
            ;; Working in the file records it, buffer and project both.
            (with-current-buffer source
              (cl-letf (((symbol-function 'window-buffer)
                         (lambda (&rest _) source)))
                (ecc-window-note-source-buffer)))
            ;; Starting from the file itself uses its project, not the
            ;; subdirectory it sits in.
            (with-current-buffer source
              (should (equal (ecc-window-context-project-root)
                             "/tmp/ecc-start-project/")))
            ;; And starting from a buffer with nothing behind it follows
            ;; the last file the user really was in.
            (with-current-buffer scratch
              (should (equal (ecc-window-context-project-root)
                             "/tmp/ecc-start-project/"))))
        (dolist (buffer (list source scratch))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest ecc-start-test-arguments-follow-the-context ()
  "The interactive form reads the directory the same way, prefix or not."
  (ecc-start-test--with-project "/tmp/ecc-start-project/"
    (let ((source (generate-new-buffer "b.el")))
      (unwind-protect
          (with-current-buffer source
            (setq buffer-file-name "/tmp/ecc-start-project/b.el"
                  default-directory "/tmp/ecc-start-project/")
            (let ((current-prefix-arg nil))
              (should (equal (car (ecc-start--read-arguments))
                             "/tmp/ecc-start-project/")))
            ;; With a prefix argument the project is what is offered to
            ;; edit, rather than the answer itself.
            (let ((current-prefix-arg t)
                  (offered nil))
              (cl-letf (((symbol-function 'read-directory-name)
                         (lambda (_prompt &optional default &rest _)
                           (setq offered default)
                           "/tmp/chosen/"))
                        ((symbol-function 'read-string) (lambda (&rest _) "")))
                (should (equal (car (ecc-start--read-arguments)) "/tmp/chosen/"))
                (should (equal offered "/tmp/ecc-start-project/")))))
        (when (buffer-live-p source) (kill-buffer source))))))

(provide 'ecc-start-test)

;;; ecc-start-test.el ends here
