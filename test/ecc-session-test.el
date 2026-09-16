;;; ecc-session-test.el --- Tests for ecc-session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Where a session is: the root it was started in, which is what the
;; transcript's `default-directory' and everything that groups sessions
;; by project asks, and which nothing but the user moves.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-model)
(require 'ecc-dispatch)
(require 'ecc-session)
(require 'ecc-window)

(defun ecc-session-test--init (cwd)
  "Return a system/init message reporting CWD."
  `((type . "system") (subtype . "init") (cwd . ,cwd)))

(defmacro ecc-session-test--with-tree (root inner &rest body)
  "Run BODY with ROOT a fresh directory and INNER a directory inside it."
  (declare (indent 2))
  `(let* ((,root (file-name-as-directory (make-temp-file "ecc-session" t)))
          (,inner (file-name-as-directory
                   (expand-file-name "worktree" ,root))))
     (unwind-protect
         (progn (make-directory ,inner t) ,@body)
       (delete-directory ,root t))))

(ert-deftest ecc-session-test-the-cli-cwd-does-not-move-the-buffer ()
  "A cwd the CLI reports leaves the transcript where the session is.
CLI 2.1.272 reports the directory the last Bash tool call left it in as
the session cwd (confirmed 2026-09-16): a model that runs `cd\\=' would
otherwise take Magit and the project commands run from the transcript
with it."
  (ecc-test-with-fake-session session
    (ecc-session-test--with-tree started moved
      (setf (ecc-session-project-root session) started
            (ecc-session-cwd session) started)
      (let ((buffer (ecc-session-ensure-buffer session)))
        (ecc-dispatch session (ecc-session-test--init
                               (directory-file-name moved)))
        (should (equal (ecc-session-cwd session) (directory-file-name moved)))
        (should (equal (buffer-local-value 'default-directory buffer) started))
        (should (equal (ecc-session-directory session) started))))))

(ert-deftest ecc-session-test-set-root-moves-the-buffer ()
  "The root moving takes the transcript with it, and only to a real one."
  (ecc-test-with-fake-session session
    (ecc-session-test--with-tree started moved
      (setf (ecc-session-project-root session) started)
      (let ((buffer (ecc-session-ensure-buffer session)))
        (should (equal (ecc-session-set-root session moved) moved))
        (should (equal (buffer-local-value 'default-directory buffer) moved))
        (should (equal (ecc-session-directory session) moved))
        ;; A directory that is not there is refused: a
        ;; `default-directory' pointing at nothing breaks every command
        ;; in the buffer.
        (should-not (ecc-session-set-root session "/nowhere/at/all/here/"))
        (should (equal (buffer-local-value 'default-directory buffer) moved))))))

(ert-deftest ecc-session-test-only-the-moved-session-moves ()
  "One session moving leaves the others where they are.
Two sessions, because what a move does to the one that did not move is
the part that goes wrong."
  (ecc-test-with-fake-session one
    (ecc-session-test--with-tree started moved
      (let ((two (ecc-model-create-session :name "two" :project-root started)))
        (unwind-protect
            (progn
              (setf (ecc-session-project-root one) started)
              (ecc-session-ensure-buffer one)
              (ecc-session-ensure-buffer two)
              (ecc-session-set-root one moved)
              ;; The CLI of the other one says it is somewhere else
              ;; again; neither says anything about where two is.
              (ecc-dispatch two (ecc-session-test--init
                                 (directory-file-name moved)))
              (should (equal (ecc-session-directory two) started))
              (should (equal (buffer-local-value
                              'default-directory (ecc-session-buffer two))
                             started))
              (should-not (equal (ecc-window-session-project one)
                                 (ecc-window-session-project two))))
          (ecc-test-cleanup-session two))))))

(provide 'ecc-session-test)

;;; ecc-session-test.el ends here
