;;; ecc-diff-test.el --- Tests for ecc-diff  -*- lexical-binding: t; -*-

;;; Commentary:

;; The pure diff functions.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-diff)

(defun ecc-diff-test--tags (lines)
  "Return the tags of the diff LINES as a string of + - and space."
  (mapconcat (lambda (line)
               (pcase (car line) ('added "+") ('removed "-") (_ " ")))
             lines ""))

(defun ecc-diff-test--faces (text)
  "Return the face of every line of TEXT, as a list."
  (mapcar (lambda (line) (get-text-property 0 'face line))
          (seq-remove #'string-empty-p (split-string text "\n"))))

(ert-deftest ecc-diff-test-lines ()
  "A changed line in the middle is one removal and one addition."
  (let ((lines (ecc-diff-lines "a\nb\nc\n" "a\nB\nc\n")))
    (should (equal (ecc-diff-test--tags lines) " -+ "))
    (should (equal (mapcar #'cdr lines) '("a" "b" "B" "c")))
    (should (equal (ecc-diff-counts lines) '(1 . 1))))
  ;; Insertions, deletions and equality.
  (should (equal (ecc-diff-test--tags (ecc-diff-lines "a\n" "a\nb\n")) " +"))
  (should (equal (ecc-diff-test--tags (ecc-diff-lines "a\nb\n" "b\n")) "- "))
  (should (equal (ecc-diff-test--tags (ecc-diff-lines "x\n" "x\n")) " "))
  (should (equal (ecc-diff-test--tags (ecc-diff-lines nil "p\nq")) "++"))
  (should (equal (ecc-diff-test--tags (ecc-diff-lines "p\nq" "")) "--")))

(ert-deftest ecc-diff-test-lines-large-fallback ()
  "Two texts too large to compare exactly still give a usable diff."
  (let* ((ecc-diff-max-cells 10)
         (old (mapconcat (lambda (i) (format "old %d" i)) (number-sequence 1 20) "\n"))
         (new (mapconcat (lambda (i) (format "new %d" i)) (number-sequence 1 20) "\n"))
         (lines (ecc-diff-lines old new)))
    (should (equal (ecc-diff-counts lines) '(20 . 20)))))

(ert-deftest ecc-diff-test-hunks ()
  "Changes far apart become separate hunks with the right line numbers."
  (let* ((old (mapconcat #'number-to-string (number-sequence 1 30) "\n"))
         (new (string-replace "\n15\n" "\n15x\n"
                              (string-replace "\n3\n" "\n3x\n" old)))
         (hunks (ecc-diff-hunks (ecc-diff-lines old new) 2)))
    (should (= (length hunks) 2))
    (should (equal (seq-take (car hunks) 4) '(1 5 1 5)))
    (should (equal (seq-take (cadr hunks) 4) '(13 5 13 5)))
    (should (equal (ecc-diff-hunk-header (cadr hunks)) "@@ -13,5 +13,5 @@"))
    ;; Two changes within reach of each other share a hunk.
    (should (= 1 (length (ecc-diff-hunks
                          (ecc-diff-lines "a\nb\nc\nd\n" "A\nb\nc\nD\n") 3))))))

(ert-deftest ecc-diff-test-format-faces ()
  "Every line carries the diff-mode face for its kind."
  (let ((text (ecc-diff-render "a\nb\nc\n" "a\nB\nc\n" 1)))
    (should (equal (ecc-diff-test--faces text)
                   '(diff-hunk-header diff-context diff-removed diff-added
                                      diff-context)))
    (should (string-prefix-p "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n" text)))
  ;; Equal texts have no diff at all.
  (should-not (ecc-diff-render "same\n" "same\n")))

(ert-deftest ecc-diff-test-for-edit-with-context ()
  "An Edit shows the lines of the file around it."
  (let* ((file "def greet(name):\n    \"\"\"Say hi.\"\"\"\n    return \"hi \" + name\n\n\ndef farewell(name):\n    \"\"\"Say bye.\"\"\"\n    return \"bye \" + name\n")
         (text (ecc-diff-for-edit "    return \"hi \" + name"
                                  "    return \"hello \" + name" file 3)))
    (should (equal (substring-no-properties text)
                   (concat "@@ -1,6 +1,6 @@\n"
                           " def greet(name):\n"
                           "     \"\"\"Say hi.\"\"\"\n"
                           "-    return \"hi \" + name\n"
                           "+    return \"hello \" + name\n"
                           " \n"
                           " \n"
                           " def farewell(name):\n")))))

(ert-deftest ecc-diff-test-for-edit-without-file ()
  "Without the file the strings themselves are compared."
  (let ((text (ecc-diff-for-edit "x = 1\ny = 2\n" "x = 1\ny = 3\n")))
    (should (equal (substring-no-properties text) " x = 1\n-y = 2\n+y = 3\n"))))

(ert-deftest ecc-diff-test-for-write ()
  "A Write of a new file is all additions; over an old one it is a diff."
  (should (equal (substring-no-properties (ecc-diff-for-write "a\nb\n"))
                 "@@ -0,0 +1,2 @@\n+a\n+b\n"))
  (should (equal (substring-no-properties (ecc-diff-for-write "a\nc\n" "a\nb\n" 0))
                 "@@ -2,1 +2,1 @@\n-b\n+c\n"))
  (should (string-search "no change" (ecc-diff-for-write "a\n" "a\n"))))

(ert-deftest ecc-diff-test-from-patch ()
  "The structuredPatch of the CLI is rendered and counted as it is."
  (let* ((patch (vector '((oldStart . 1) (oldLines . 3) (newStart . 1) (newLines . 3)
                          (lines . [" a" "-b" "+B" " c"]))))
         (text (ecc-diff-from-patch patch)))
    (should (equal (substring-no-properties text) "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"))
    (should (equal (ecc-diff-test--faces text)
                   '(diff-hunk-header diff-context diff-removed diff-added
                                      diff-context)))
    (should (equal (ecc-diff-patch-counts patch) '(1 . 1)))
    (should (equal (ecc-diff-patch-counts []) '(0 . 0)))))

(ert-deftest ecc-diff-test-for-tool ()
  "Only Edit and Write have a diff."
  (should (ecc-diff-for-tool "Edit" '((old_string . "a") (new_string . "b"))))
  (should (ecc-diff-for-tool "Write" '((content . "a"))))
  (should-not (ecc-diff-for-tool "Bash" '((command . "ls")))))

(ert-deftest ecc-diff-test-file-content ()
  "A file is read whole; a missing or oversized one gives nil."
  (let ((file (make-temp-file "ecc-diff" nil nil "one\ntwo\n")))
    (unwind-protect
        (progn
          (should (equal (ecc-diff-file-content file) "one\ntwo\n"))
          (let ((ecc-diff-max-file-size 3))
            (should-not (ecc-diff-file-content file)))
          (should-not (ecc-diff-file-content (concat file ".missing")))
          (should-not (ecc-diff-file-content nil)))
      (delete-file file))))

(provide 'ecc-diff-test)

;;; ecc-diff-test.el ends here
