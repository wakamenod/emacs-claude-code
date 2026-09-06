;;; ecc-context-test.el --- Tests for ecc-context  -*- lexical-binding: t; -*-

;;; Commentary:

;; What Emacs knows and the CLI does not: the file, the line and the
;; region of the buffer the user came from (FR-CTX-1), how it is quoted
;; (FR-CTX-2), the diagnostics (FR-CTX-4) and the commands that send from
;; a source buffer (FR-CTX-5).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-context)

(defmacro ecc-context-test--with-file (var content &rest body)
  "Run BODY in a buffer visiting a temporary file holding CONTENT.
VAR is bound to the file name."
  (declare (indent 2))
  `(let ((,var (make-temp-file "ecc-context" nil ".py")))
     (unwind-protect
         (with-temp-buffer
           (insert ,content)
           (write-region (point-min) (point-max) ,var nil 'silent)
           (setq buffer-file-name ,var)
           (setq default-directory (file-name-directory ,var))
           (python-mode)
           (goto-char (point-min))
           ,@body)
       (delete-file ,var))))

(ert-deftest ecc-context-test-capture-line ()
  "Without a region only the file and the line are captured (FR-CTX-1)."
  (ecc-context-test--with-file file "a = 1\nb = 2\nc = 3\n"
    (forward-line 1)
    (let ((context (ecc-context-capture :buffer (current-buffer))))
      (should (equal (plist-get context :path) (file-name-nondirectory file)))
      (should (= (plist-get context :line) 2))
      (should-not (plist-get context :text))
      (should (equal (plist-get context :language) "python")))))

(ert-deftest ecc-context-test-capture-region ()
  "A region is captured with the lines it spans (FR-CTX-1)."
  (ecc-context-test--with-file _file "a = 1\nb = 2\nc = 3\n"
    (let* ((beg (point-min))
           (end (progn (goto-char (point-min)) (forward-line 2) (point)))
           (context (ecc-context-capture :buffer (current-buffer)
                                         :region (cons beg end))))
      (should (= (plist-get context :line) 1))
      ;; The newline that ends line 2 does not make it a three line region.
      (should (= (plist-get context :end-line) 2))
      (should (equal (plist-get context :text) "a = 1\nb = 2")))))

(ert-deftest ecc-context-test-format ()
  "The context is a quote block the user can read before sending (FR-CTX-2)."
  (ecc-context-test--with-file file "a = 1\nb = 2\n"
    (let* ((context (ecc-context-capture :buffer (current-buffer)
                                         :region (cons (point-min) (point-max))))
           (block (ecc-context-format context)))
      (should (string-prefix-p "\n\n---\nCurrent context: " block))
      (should (string-search (format "`%s` L1-L2" (file-name-nondirectory file))
                             block))
      (should (string-search "```python\na = 1\nb = 2\n```" block)))
    ;; Without a region there is a location but no code block.
    (let ((block (ecc-context-format
                  (ecc-context-capture :buffer (current-buffer)))))
      (should (string-search " L1" block))
      (should-not (string-search "```" block)))))

(ert-deftest ecc-context-test-language-falls-back-to-the-file-name ()
  "A buffer without a mode is fenced by what its file name says."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/x/calc.py")
    (should (equal (ecc-context-language) "python"))
    (setq buffer-file-name nil)
    (should (equal (ecc-context-language) "")))
  (should (equal (ecc-context-language 'emacs-lisp-mode) "elisp"))
  (should (equal (ecc-context-language 'python-ts-mode) "python")))

(ert-deftest ecc-context-test-long-region-is-cut ()
  "A huge region is cut down, with a note saying so."
  (let ((ecc-context-max-lines 3))
    (ecc-context-test--with-file _file "1\n2\n3\n4\n5\n6\n"
      (let ((context (ecc-context-capture :buffer (current-buffer)
                                          :region (cons (point-min) (point-max)))))
        (should (string-prefix-p "1\n2\n3" (plist-get context :text)))
        (should (string-search "lines omitted" (plist-get context :text)))))))

(ert-deftest ecc-context-test-file-range ()
  "A line range is read out of the file, or out of its buffer (FR-INP-8)."
  (ecc-context-test--with-file file "1\n2\n3\n4\n5\n"
    (let ((context (ecc-context-file-range file 2 4)))
      (should (equal (plist-get context :text) "2\n3\n4"))
      (should (= (plist-get context :line) 2))
      (should (= (plist-get context :end-line) 4)))
    ;; An end past the last line is clipped rather than an error.
    (should (equal (plist-get (ecc-context-file-range file 4 99) :text) "4\n5"))
    (should-not (ecc-context-file-range "/no/such/file.py" 1 2))))

(ert-deftest ecc-context-test-file-range-prefers-the-buffer ()
  "Unsaved work is quoted as the user sees it, not as the file has it."
  (ecc-context-test--with-file file "1\n2\n3\n"
    (let ((buffer (current-buffer)))
      (erase-buffer)
      (insert "one\ntwo\nthree\n")
      (cl-letf (((symbol-function 'find-buffer-visiting)
                 (lambda (&rest _) buffer)))
        (should (equal (plist-get (ecc-context-file-range file 1 2) :text)
                       "one\ntwo"))))))

(ert-deftest ecc-context-test-diagnostics-from-flymake ()
  "flymake is asked first for the diagnostics (FR-CTX-4)."
  (with-temp-buffer
    (insert "a = 1\nb = undefined\n")
    (cl-letf (((symbol-function 'flymake-diagnostics)
               (lambda (&rest _) (list 'diag-2 'diag-1)))
              ((symbol-function 'flymake-diagnostic-beg)
               (lambda (diag) (if (eq diag 'diag-1) 1 8)))
              ((symbol-function 'flymake-diagnostic-text)
               (lambda (diag) (if (eq diag 'diag-1) "first  problem" "second\nproblem"))))
      (should (equal (ecc-context-diagnostics)
                     '("L1: first problem" "L2: second problem")))
      (should (equal (ecc-context-diagnostics-block)
                     "```\nL1: first problem\nL2: second problem\n```")))))

(ert-deftest ecc-context-test-diagnostics-fall-back-to-help-echo ()
  "A checker this package does not know about is read off the overlay."
  (with-temp-buffer
    (insert (propertize "bad line" 'help-echo "syntax error"))
    (should (equal (ecc-context-diagnostics nil (point-min) (point-max))
                   '("L1: syntax error")))))

;;;; The commands (FR-CTX-5)

(defun ecc-context-test--sent-text ()
  "Return the text of the single prompt that was sent."
  (alist-get 'content (alist-get 'message (car (ecc-test-sent-messages)))))

(ert-deftest ecc-context-test-send ()
  "A line from the minibuffer reaches the session (FR-CTX-5 a)."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      (ecc-send "hello"))
    (should (equal (ecc-context-test--sent-text) "hello"))
    (should (ecc-session-current-turn session))
    (should-error (ecc-send "  ") :type 'user-error)))

(ert-deftest ecc-context-test-send-with-context ()
  "The file and the line are attached to what the user typed (FR-CTX-5 b)."
  (ecc-test-with-fake-session _session
    (ecc-context-test--with-file file "a = 1\nb = 2\n"
      (forward-line 1)
      (ecc-send-with-context "これは何?"))
    (let ((text (ecc-context-test--sent-text)))
      (should (string-prefix-p "これは何?" text))
      (should (string-search "Current context: " text))
      (should (string-search " L2" text)))))

(ert-deftest ecc-context-test-send-region ()
  "The region goes out quoted, under the instruction that was given."
  (ecc-test-with-fake-session _session
    (ecc-context-test--with-file _file "a = 1\nb = 2\n"
      (ecc-send-region (point-min) (point-max) "説明して"))
    (let ((text (ecc-context-test--sent-text)))
      (should (string-prefix-p "説明して" text))
      (should (string-search "```python\na = 1\nb = 2\n```" text)))))

(ert-deftest ecc-context-test-send-buffer-file ()
  "The file itself is sent as an @ reference the CLI resolves (FR-CTX-5 d)."
  (ecc-test-with-fake-session _session
    (ecc-context-test--with-file file "a = 1\n"
      (set-buffer-modified-p nil)
      (ecc-send-buffer-file)
      (should (string-suffix-p (concat "@" (file-name-nondirectory file))
                               (ecc-context-test--sent-text))))))

(ert-deftest ecc-context-test-fix-error-at-point ()
  "The diagnostic at point is quoted with the code around it (FR-CTX-5 e)."
  (ecc-test-with-fake-session _session
    (ecc-context-test--with-file _file "a = 1\nb = undefined\nc = 3\n"
      (forward-line 1)
      (cl-letf (((symbol-function 'flymake-diagnostics)
                 (lambda (beg end) (and (<= beg 8) (>= end 8) (list 'diag))))
                ((symbol-function 'flymake-diagnostic-beg) (lambda (_) 8))
                ((symbol-function 'flymake-diagnostic-text)
                 (lambda (_) "undefined name")))
        (ecc-fix-error-at-point))
      ;; No diagnostic on this line: nothing is sent.
      (goto-char (point-min))
      (should-error (ecc-fix-error-at-point) :type 'user-error))
    (let ((text (ecc-context-test--sent-text)))
      (should (string-search "L2: undefined name" text))
      (should (string-search "b = undefined" text))
      (should (= 1 (length (ecc-test-sent-messages)))))))

(provide 'ecc-context-test)

;;; ecc-context-test.el ends here
