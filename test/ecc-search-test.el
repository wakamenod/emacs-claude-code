;;; ecc-search-test.el --- Tests for ecc-search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Searching the recordings of a project for what was said in them:
;; what counts as something said, which files are looked in, how little
;; of one is parsed, and how a hit is drawn.
;;
;; The recordings here are written by the tests rather than recorded,
;; because what is being tested is which kinds of line are picked up
;; and a fixture holds whatever the CLI happened to write that day.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-search)

(defvar ecc-search-test--uuid 0
  "Counter making every line of a written recording a different uuid.")

(defvar ecc-search-test--timestamp "2026-09-01T10:00:00.000Z"
  "The time the lines of the recording being written say they were written.
It is what orders the sessions, so each recording is written under one
of its own.")

(defun ecc-search-test--line (session cwd type content &optional extra)
  "Return one line of a recording of SESSION in CWD.
TYPE is \"user\" or \"assistant\" and CONTENT is what its message
says, a string or a vector of blocks.  EXTRA is folded into the line
itself, which is where `isMeta' and `isSidechain' live."
  (let ((message (if (equal type "assistant")
                     `((role . "assistant") (model . "claude-opus-5")
                       (content . ,content))
                   `((role . "user") (content . ,content)))))
    (json-serialize
     (append extra
             `((type . ,type)
               (sessionId . ,session)
               (cwd . ,cwd)
               (uuid . ,(format "uuid-%d" (cl-incf ecc-search-test--uuid)))
               (timestamp . ,ecc-search-test--timestamp)
               (message . ,message))))))

(defun ecc-search-test--write (file session cwd lines)
  "Write LINES as the recording of SESSION in CWD to FILE.
Each of LINES is (TYPE CONTENT [EXTRA]) for `ecc-search-test--line'."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (let ((coding-system-for-write 'utf-8-unix))
      (dolist (line lines)
        (insert (apply #'ecc-search-test--line session cwd line) "\n")))))

(defmacro ecc-search-test--with-recordings (root &rest body)
  "Run BODY with `ecc-history-directory' holding two written recordings.
ROOT is bound to a working directory the two ran in: the older one
says needle in a prompt, the newer one in an answer, and both hold it
in places that are not conversation as well."
  (declare (indent 1))
  `(let* ((directory (make-temp-file "ecc-search-dir" t))
          (,root (file-name-as-directory (file-truename
                                          (make-temp-file "ecc-search-root" t))))
          (ecc-history-directory directory)
          (ecc-history--files (make-hash-table :test #'equal))
          (project (expand-file-name (ecc-history-project-directory ,root) directory)))
     (unwind-protect
         (progn
           (let ((ecc-search-test--timestamp "2026-09-01T10:00:00.000Z"))
             (ecc-search-test--write
              (expand-file-name "aaaaaaaa-0000-0000-0000-000000000001.jsonl" project)
              "aaaaaaaa-0000-0000-0000-000000000001" ,root
              '(("user" "where does the needle live?")
                ("assistant" [((type . "text") (text . "In the model."))]))))
           (let ((ecc-search-test--timestamp "2026-09-02T10:00:00.000Z"))
             (ecc-search-test--write
              (expand-file-name "bbbbbbbb-0000-0000-0000-000000000002.jsonl" project)
              "bbbbbbbb-0000-0000-0000-000000000002" ,root
              '(("user" "what about the haystack?")
                ("assistant" [((type . "text") (text . "The needle is in ecc-model.el."))])
                ;; None of the rest is anything a person said.
                ("assistant" [((type . "tool_use") (name . "Read")
                               (input . ((file_path . "/tmp/needle.txt"))))])
                ("user" [((type . "tool_result") (content . "a needle in the output"))])
                ("user" "<local-command-stdout>needle</local-command-stdout>")
                ("user" "a needle said by the CLI" ((isMeta . t))))))
           ,@body)
       (delete-directory directory t)
       (delete-directory ,root t))))

;;;; What counts as something said

(ert-deftest ecc-search-test-finds-prompts-and-answers ()
  "A hit is the prose of a prompt or of an answer, and nothing else."
  (ecc-search-test--with-recordings root
    (let* ((groups (ecc-search-groups "needle" root))
           (hits (seq-mapcat #'cdr groups)))
      (should (= 2 (length groups)))
      (should (equal '("assistant" "user") (mapcar #'ecc-search-hit-role hits)))
      (should (equal '("The needle is in ecc-model.el."
                       "where does the needle live?")
                     (mapcar #'ecc-search-hit-text hits))))))

(ert-deftest ecc-search-test-roles-narrow-the-search ()
  "`ecc-search-roles' says which half of the conversation is read."
  (ecc-search-test--with-recordings root
    (let* ((ecc-search-roles '("user"))
           (groups (ecc-search-groups "needle" root)))
      (should (= 1 (length groups)))
      (should (equal "where does the needle live?"
                     (ecc-search-hit-text (car (cdr (car groups)))))))))

(ert-deftest ecc-search-test-ignores-case ()
  "The query is matched without regard to case, grep and Emacs alike."
  (ecc-search-test--with-recordings root
    (should (= 2 (length (ecc-search-groups "NEEDLE" root))))))

(ert-deftest ecc-search-test-no-hit-is-no-group ()
  "A string nobody said lists nothing."
  (ecc-search-test--with-recordings root
    (should (null (ecc-search-groups "thimble" root)))))

;;;; The sessions

(ert-deftest ecc-search-test-newest-session-first ()
  "The session used most recently is listed first."
  (ecc-search-test--with-recordings root
    (should (equal '("bbbbbbbb-0000-0000-0000-000000000002"
                     "aaaaaaaa-0000-0000-0000-000000000001")
                   (mapcar (lambda (group) (alist-get 'session-id (car group)))
                           (ecc-search-groups "needle" root))))))

(ert-deftest ecc-search-test-sibling-project-is-left-out ()
  "A recording of another project is not listed for this one.
The directory of /tmp/root is a name prefix of the one of /tmp/root-2,
so the name is not enough and the working directory decides."
  (ecc-search-test--with-recordings root
    (let* ((sibling (concat (directory-file-name root) "-2/"))
           (file (expand-file-name
                  (format "%s/cccccccc-0000-0000-0000-000000000003.jsonl"
                          (ecc-history-project-directory sibling))
                  ecc-history-directory)))
      (ecc-search-test--write file "cccccccc-0000-0000-0000-000000000003" sibling
                              '(("user" "a needle next door")))
      (should (= 2 (length (ecc-search-groups "needle" root))))
      (should (= 3 (length (ecc-search-groups "needle" nil)))))))

;;;; How much of a recording is read

(ert-deftest ecc-search-test-parses-only-the-lines-that-matched ()
  "Only the lines holding the string are parsed as JSON.
A recording is tens of thousands of messages and this is what makes
searching one cheap; parsing every line would answer the same and be
too slow to run from a keystroke."
  (ecc-search-test--with-recordings root
    (let* ((file (expand-file-name
                  (format "%s/bbbbbbbb-0000-0000-0000-000000000002.jsonl"
                          (ecc-history-project-directory root))
                  ecc-history-directory))
           (lines (length (ecc-history-lines file)))
           (parsed 0)
           (read (symbol-function 'ecc--json-read)))
      (should (> lines 4))
      (cl-letf (((symbol-function 'ecc--json-read)
                 (lambda (string) (cl-incf parsed) (funcall read string))))
        (ecc-search--scan-file file "haystack"))
      (should (= 1 parsed)))))

(ert-deftest ecc-search-test-without-grep-the-answer-is-the-same ()
  "With no grep on PATH every recording is read, and finds the same."
  (ecc-search-test--with-recordings root
    (let ((with-grep (ecc-search-groups "needle" root))
          (without (let ((ecc-search-programs nil))
                     (ecc-search-groups "needle" root))))
      (should (equal (mapcar (lambda (group) (alist-get 'session-id (car group)))
                             with-grep)
                     (mapcar (lambda (group) (alist-get 'session-id (car group)))
                             without))))))

(ert-deftest ecc-search-test-a-grep-that-failed-searches-everything ()
  "A grep that could not answer must not shrink the search to nothing."
  (ecc-search-test--with-recordings root
    (let ((ecc-search-programs '(("grep" "--no-such-option"))))
      (should (= 2 (length (ecc-search-groups "needle" root)))))))

;;;; Drawing a hit

(ert-deftest ecc-search-test-excerpt-flattens-and-marks ()
  "An excerpt is one line, cut around the hit, with the hit marked."
  (let* ((text (concat "a paragraph\n\nand another that says needle "
                       (make-string 300 ?x)))
         (excerpt (ecc-search--excerpt text "needle")))
    (should-not (string-match-p "\n" excerpt))
    (should (string-match-p "paragraph and another that says" excerpt))
    (should (string-suffix-p "…" excerpt))
    (should (<= (length excerpt) (+ 2 ecc-search-excerpt-width)))
    (let ((at (string-match "needle" excerpt)))
      (should (memq 'ecc-search-match-face
                    (ensure-list (get-text-property at 'face excerpt)))))))

(ert-deftest ecc-search-test-excerpt-opens-in-the-middle ()
  "A hit far into a message is shown with what is around it."
  (let ((excerpt (ecc-search--excerpt
                  (concat (make-string 300 ?x) " needle " (make-string 300 ?y))
                  "needle")))
    (should (string-prefix-p "…" excerpt))
    (should (string-match-p "x+ needle y+" excerpt))))

;;;; The buffer

(ert-deftest ecc-search-test-buffer-lists-the-sessions ()
  "Every line of a session's block opens that session."
  (ecc-search-test--with-recordings root
    (unwind-protect
        (progn
          (ecc-search--draw (ecc-search-groups "needle" root) "needle" root)
          (with-current-buffer ecc-search-buffer-name
            (should (eq major-mode 'ecc-search-mode))
            (should (equal "needle" ecc-search--query))
            (goto-char (point-min))
            (should (string-match-p "2 sessions said needle"
                                    (buffer-substring-no-properties
                                     (point-min) (line-end-position))))
            ;; The first block is the newest session, and its heading
            ;; and its hits all say so.
            (forward-line 2)
            (should (equal "bbbbbbbb-0000-0000-0000-000000000002"
                           (ecc-search-session-at-point)))
            (should (search-forward "The needle is in ecc-model.el." nil t))
            (should (equal "bbbbbbbb-0000-0000-0000-000000000002"
                           (ecc-search-session-at-point)))
            ;; The line the model said it on is the only one listed:
            ;; the tool result and the command output that also hold
            ;; the string were not said by anyone.
            (goto-char (point-min))
            (should-not (search-forward "a needle in the output" nil t))
            (goto-char (point-min))
            (forward-line 2)
            (ecc-search-next)
            (should (equal "aaaaaaaa-0000-0000-0000-000000000001"
                           (ecc-search-session-at-point)))
            (ecc-search-previous)
            (should (equal "bbbbbbbb-0000-0000-0000-000000000002"
                           (ecc-search-session-at-point)))))
      (when (get-buffer ecc-search-buffer-name)
        (kill-buffer ecc-search-buffer-name)))))

(ert-deftest ecc-search-test-empty-query-is-refused ()
  "A search for nothing says so rather than listing every session."
  (should-error (ecc-search "   ") :type 'user-error))

(provide 'ecc-search-test)

;;; ecc-search-test.el ends here
