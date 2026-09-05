;;; ecc-sync-test.el --- Tests for ecc-sync  -*- lexical-binding: t; -*-

;;; Commentary:

;; Reverting the buffer of a file Claude changed (FR-SYNC-1) and telling
;; when a buffer has unsaved changes (FR-SYNC-2).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-sync)

(defmacro ecc-sync-test--with-file (file buffer &rest body)
  "Run BODY with FILE a temp file holding two lines, visited by BUFFER."
  (declare (indent 2))
  `(let* ((,file (make-temp-file "ecc-sync" nil ".txt" "one\ntwo\n"))
          (,buffer (find-file-noselect ,file)))
     (unwind-protect
         (progn ,@body)
       (with-current-buffer ,buffer (set-buffer-modified-p nil))
       (kill-buffer ,buffer)
       (delete-file ,file))))

(defun ecc-sync-test--write (file text)
  "Replace the content of FILE by TEXT, the way Claude would."
  (with-temp-file file (insert text)))

(ert-deftest ecc-sync-test-revert-keeps-line-and-column ()
  "A clean buffer is reloaded and point stays on its line and column."
  (ecc-sync-test--with-file file buffer
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (forward-char 2))
    (ecc-sync-test--write file "zero\none\ntwo\n")
    (should (eq (ecc-sync-revert-file file) buffer))
    (with-current-buffer buffer
      (should (equal (buffer-string) "zero\none\ntwo\n"))
      (should (= (line-number-at-pos) 2))
      (should (= (current-column) 2))
      (should-not (buffer-modified-p)))))

(ert-deftest ecc-sync-test-modified-buffer-is-left-alone ()
  "With the default action a buffer with unsaved changes is only warned about."
  (ecc-sync-test--with-file file buffer
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "three\n"))
    (ecc-sync-test--write file "changed\n")
    (let ((ecc-sync-modified-action 'warn))
      (should-not (ecc-sync-revert-file file)))
    (with-current-buffer buffer
      (should (buffer-modified-p))
      (should (string-search "three" (buffer-string))))
    (should (eq (ecc-sync-unsaved-buffer file) buffer))))

(ert-deftest ecc-sync-test-modified-buffer-ask-and-revert ()
  "The ask action asks, the revert action does not."
  (ecc-sync-test--with-file file buffer
    (with-current-buffer buffer (insert "x"))
    (ecc-sync-test--write file "a\n")
    (let ((ecc-sync-modified-action 'ask))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (should-not (ecc-sync-revert-file file)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (should (ecc-sync-revert-file file))))
    (should (equal (with-current-buffer buffer (buffer-string)) "a\n"))
    (with-current-buffer buffer (insert "y"))
    (ecc-sync-test--write file "b\n")
    (let ((ecc-sync-modified-action 'revert))
      (should (ecc-sync-revert-file file)))
    (should (equal (with-current-buffer buffer (buffer-string)) "b\n"))
    (should-not (ecc-sync-unsaved-buffer file))))

(ert-deftest ecc-sync-test-no-buffer-does-nothing ()
  "A file nobody visits is not an error."
  (should-not (ecc-sync-revert-file "/nonexistent/ecc-sync.txt"))
  (should-not (ecc-sync-unsaved-buffer nil)))

(ert-deftest ecc-sync-test-tool-result-reverts-through-the-hook ()
  "A successful Write result reloads the buffer of the file (FR-SYNC-1)."
  (ecc-test-with-fake-session session
    (ecc-sync-test--with-file file buffer
      (ecc-model-begin-turn session "書いて")
      (ecc-dispatch session
                    `((type . "assistant") (uuid . "u1")
                      (message . ((role . "assistant")
                                  (content . [((type . "tool_use") (id . "t1") (name . "Write")
                                               (input . ((file_path . ,file)
                                                         (content . "written\n"))))])))))
      (ecc-sync-test--write file "written\n")
      (ecc-dispatch session
                    '((type . "user")
                      (message . ((role . "user")
                                  (content . [((type . "tool_result") (tool_use_id . "t1")
                                               (content . "ok"))])))))
      (should (equal (with-current-buffer buffer (buffer-string)) "written\n"))
      (with-current-buffer (ecc--log-buffer (ecc-session-name session))
        (should (string-search "reverted" (buffer-string)))))))

(ert-deftest ecc-sync-test-disabled ()
  "Nothing is reverted while `ecc-sync-enabled' is nil."
  (ecc-test-with-fake-session session
    (ecc-sync-test--with-file file buffer
      (ecc-sync-test--write file "new\n")
      (let ((ecc-sync-enabled nil))
        (ecc-sync--on-file-changed session file))
      (should (equal (with-current-buffer buffer (buffer-string)) "one\ntwo\n")))))

(provide 'ecc-sync-test)

;;; ecc-sync-test.el ends here
