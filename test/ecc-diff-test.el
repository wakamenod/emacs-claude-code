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
  "Return the face of the body of every line of TEXT, as a list.
The last character of a line is what carries the kind of the line: the
first is the line number, which is drawn as a line number."
  (mapcar (lambda (line) (get-text-property (1- (length line)) 'face line))
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
  "Every line is numbered and carries the diff-mode face for its kind."
  (let ((text (ecc-diff-render "a\nb\nc\n" "a\nB\nc\n" 1)))
    (should (equal (ecc-diff-test--faces text)
                   '(diff-context diff-removed diff-added diff-context)))
    ;; The number is drawn as a number, whatever the line is.
    (should (eq (get-text-property 0 'face text) 'shadow))
    ;; A changed line ends in the spacer that carries its colour to the
    ;; right edge: one space, so the text is still the text.
    (should (equal (substring-no-properties text) "1  a\n2 -b \n2 +B \n3  c\n"))
    (should (equal (get-text-property (string-search "-b " text) 'display text) nil))
    (should (equal (get-text-property (+ 2 (string-search "-b " text)) 'display text)
                   '(space :align-to right))))
  ;; Equal texts have no diff at all.
  (should-not (ecc-diff-render "same\n" "same\n")))

(ert-deftest ecc-diff-test-numbers-are-the-cli-s ()
  "A context or added line is numbered in the new file, a removed one in the old.
Measured against the TUI of CLI 2.1.278 on 2026-09-22, which draws
exactly these numbers for exactly this deletion."
  (should (equal (substring-no-properties
                  (ecc-diff-render "a\nb\nc\nd\ne\nf\ng\nh\n"
                                   "a\nb\nc\nf\ng\nh\n" 3))
                 (concat "1  a\n2  b\n3  c\n"
                         "4 -d \n5 -e \n"
                         "4  f\n5  g\n6  h\n")))
  ;; The cell is as wide as the widest number, so the columns line up.
  (let ((old (mapconcat #'number-to-string (number-sequence 1 30) "\n")))
    (should (string-search "⋮\n13  13\n"
                           (substring-no-properties
                            (ecc-diff-render old (string-replace "\n15\n" "\n15x\n"
                                                                (string-replace "\n3\n" "\n3x\n" old))
                                             2))))))

(ert-deftest ecc-diff-test-the-unified-style-is-still-a-patch ()
  "Bound to `unified', the output is what `diff-mode' and the review read.
`ecc-review.el' builds its buffers out of this, and a patch with line
numbers in it is not a patch."
  (let ((ecc-diff-style 'unified))
    (should (equal (substring-no-properties (ecc-diff-render "a\nb\nc\n" "a\nB\nc\n" 1))
                   "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"))
    (should (equal (substring-no-properties
                    (ecc-diff-from-patch
                     (vector '((oldStart . 1) (oldLines . 3) (newStart . 1) (newLines . 3)
                               (lines . [" a" "-b" "+B" " c"])))))
                   "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"))
    (should (equal (substring-no-properties (ecc-diff-for-write "a\nb\n"))
                   "@@ -0,0 +1,2 @@\n+a\n+b\n"))))

(ert-deftest ecc-diff-test-summary ()
  "The counts are said in the words the CLI says them in."
  (should (equal (ecc-diff-summary '(1 . 1)) "Added 1 line, removed 1 line"))
  (should (equal (ecc-diff-summary '(2 . 0)) "Added 2 lines"))
  (should (equal (ecc-diff-summary '(0 . 2)) "Removed 2 lines"))
  (should (equal (ecc-diff-summary '(0 . 1)) "Removed 1 line"))
  (should-not (ecc-diff-summary '(0 . 0))))

(ert-deftest ecc-diff-test-for-edit-with-context ()
  "An Edit shows the lines of the file around it."
  (let* ((file "def greet(name):\n    \"\"\"Say hi.\"\"\"\n    return \"hi \" + name\n\n\ndef farewell(name):\n    \"\"\"Say bye.\"\"\"\n    return \"bye \" + name\n")
         (text (ecc-diff-for-edit "    return \"hi \" + name"
                                  "    return \"hello \" + name" file 3)))
    (should (equal (substring-no-properties text)
                   (concat "1  def greet(name):\n"
                           "2      \"\"\"Say hi.\"\"\"\n"
                           "3 -    return \"hi \" + name \n"
                           "3 +    return \"hello \" + name \n"
                           "4  \n"
                           "5  \n"
                           "6  def farewell(name):\n")))))

(ert-deftest ecc-diff-test-for-edit-without-file ()
  "Without the file the strings themselves are compared."
  (let ((text (ecc-diff-for-edit "x = 1\ny = 2\n" "x = 1\ny = 3\n")))
    ;; Nothing to number: the file the strings came out of is unknown.
    (should (equal (substring-no-properties text) " x = 1\n-y = 2 \n+y = 3 \n"))))

(ert-deftest ecc-diff-test-for-write ()
  "A Write of a new file is all additions; over an old one it is a diff."
  (should (equal (substring-no-properties (ecc-diff-for-write "a\nb\n"))
                 "1 +a \n2 +b \n"))
  (should (equal (substring-no-properties (ecc-diff-for-write "a\nc\n" "a\nb\n" 0))
                 "2 -b \n2 +c \n"))
  (should (string-search "no change" (ecc-diff-for-write "a\n" "a\n"))))

(ert-deftest ecc-diff-test-from-patch ()
  "The structuredPatch of the CLI is rendered and counted as it is."
  (let* ((patch (vector '((oldStart . 1) (oldLines . 3) (newStart . 1) (newLines . 3)
                          (lines . [" a" "-b" "+B" " c"]))))
         (text (ecc-diff-from-patch patch)))
    (should (equal (substring-no-properties text) "1  a\n2 -b \n2 +B \n3  c\n"))
    (should (equal (ecc-diff-test--faces text)
                   '(diff-context diff-removed diff-added diff-context)))
    (should (equal (ecc-diff-patch-counts patch) '(1 . 1)))
    (should (equal (ecc-diff-patch-counts []) '(0 . 0)))))

(ert-deftest ecc-diff-test-for-tool ()
  "Only the file tools have a diff, and none of them returns an empty one."
  (should (ecc-diff-for-tool "Edit" '((old_string . "a") (new_string . "b"))))
  (should (ecc-diff-for-tool "Write" '((content . "a"))))
  (should (ecc-diff-for-tool "MultiEdit"
                             '((file_path . "/tmp/x")
                               (edits . [((old_string . "a") (new_string . "b"))]))))
  (should (ecc-diff-for-tool "NotebookEdit" '((new_source . "print(1)"))))
  (should-not (ecc-diff-for-tool "Bash" '((command . "ls"))))
  ;; Nothing to show is nil, never "": the caller draws the file path of
  ;; anything non-nil and would leave it standing over an empty body.
  (should-not (ecc-diff-for-tool "MultiEdit" '((file_path . "/tmp/x"))))
  (should-not (ecc-diff-for-tool "Edit" '((old_string . "") (new_string . "")))))

(ert-deftest ecc-diff-test-tool-p ()
  "The cheap test agrees with whether a diff comes out."
  (dolist (case '(("Edit" ((old_string . "a") (new_string . "b")) t)
                  ("Edit" ((old_string . "") (new_string . "")) nil)
                  ("MultiEdit" ((edits . [((old_string . "a") (new_string . "b"))])) t)
                  ("MultiEdit" ((file_path . "/tmp/x")) nil)
                  ("Write" ((content . "a")) t)
                  ("Write" ((file_path . "/tmp/x")) nil)
                  ("NotebookEdit" ((new_source . "x")) t)
                  ("NotebookEdit" ((cell_id . "c")) nil)
                  ("Bash" ((command . "ls")) nil)))
    (pcase-let ((`(,name ,input ,want) case))
      (should (eq (and (ecc-diff-tool-p name input) t) want)))))

(ert-deftest ecc-diff-test-for-multi-edit-on-a-file ()
  "Every edit is laid on the file in turn and one diff comes out."
  (let* ((file "one\ntwo\nthree\nfour\nfive\n")
         (edits (vector '((old_string . "two") (new_string . "TWO"))
                        '((old_string . "five") (new_string . "FIVE"))))
         (diff (ecc-diff-for-multi-edit edits file 1))
         (text (substring-no-properties diff)))
    (should (string-search "2 -two \n2 +TWO \n" text))
    (should (string-search "5 -five \n5 +FIVE \n" text))
    (should (equal (ecc-diff-text-counts diff) '(2 . 2))))
  ;; A later edit sees what an earlier one wrote.
  (let ((text (substring-no-properties
               (ecc-diff-for-multi-edit
                (vector '((old_string . "a") (new_string . "b"))
                        '((old_string . "b") (new_string . "c")))
                "a\n" 0))))
    (should (equal text "1 -a \n1 +c \n")))
  ;; replace_all is honoured; without it only the first match moves.
  (should (equal (ecc-diff-text-counts
                  (ecc-diff-for-multi-edit
                   (vector '((old_string . "x") (new_string . "y") (replace_all . t)))
                   "x\nx\nx\n"))
                 '(3 . 3)))
  (should (equal (ecc-diff-text-counts
                  (ecc-diff-for-multi-edit
                   (vector '((old_string . "x") (new_string . "y")
                             (replace_all . :false)))
                   "x\nx\nx\n"))
                 '(1 . 1)))
  ;; An edit whose old_string is not in the file changes nothing at all.
  (should-not (ecc-diff-for-multi-edit
               (vector '((old_string . "absent") (new_string . "z")))
               "a\nb\n")))

(ert-deftest ecc-diff-test-for-multi-edit-without-the-file ()
  "Unread, each edit is its own old against new, in order."
  (let ((text (substring-no-properties
               (ecc-diff-for-multi-edit
                (vector '((old_string . "a") (new_string . "b"))
                        '((old_string . "c") (new_string . "d")))))))
    (should (equal text "-a \n+b \n-c \n+d \n")))
  (should-not (ecc-diff-for-multi-edit [])))

(ert-deftest ecc-diff-test-for-notebook-edit ()
  "The new source of a cell is shown as added lines."
  (let ((text (ecc-diff-for-notebook-edit
               '((cell_id . "abc") (edit_mode . "replace")
                 (new_source . "import os\nprint(os.name)\n")))))
    (should (string-search "1 +import os \n2 +print(os.name) \n"
                           (substring-no-properties text)))
    ;; The cell takes the place of the file name: nothing else says
    ;; which of a notebook's cells these lines are.
    (should (string-prefix-p "cell abc\n" (substring-no-properties text)))
    (should (equal (ecc-diff-test--faces text)
                   '(shadow diff-added diff-added))))
  ;; A deletion names no source, and a diff of nothing is nil.
  (should-not (ecc-diff-for-notebook-edit
               '((cell_id . "abc") (edit_mode . "delete"))))
  (should-not (ecc-diff-for-notebook-edit '((new_source . "")))))

(ert-deftest ecc-diff-test-patch-wins-over-the-guess ()
  "With the patch of the CLI in hand the guess from BEFORE is dropped."
  (let ((patch (vector '((oldStart . 10) (oldLines . 1) (newStart . 10) (newLines . 1)
                         (lines . ["-real" "+really"])))))
    (should (equal (substring-no-properties
                    (ecc-diff-for-tool "Edit" '((old_string . "a") (new_string . "b"))
                                       "a\n" patch))
                   "10 -real \n10 +really \n"))
    ;; An empty patch is no patch: what is known is still drawn.
    (should (string-search "+b "
                           (substring-no-properties
                            (ecc-diff-for-tool "Edit"
                                               '((old_string . "a") (new_string . "b"))
                                               "a\n" []))))
    ;; A tool with no diff of its own gains none from a patch.
    (should-not (ecc-diff-for-tool "Bash" '((command . "ls")) nil patch))))

(ert-deftest ecc-diff-test-text-counts ()
  "Added and removed lines are counted, numbers and context are not.
The faces are what says which line is which: a line of the file may
start with a + of its own, and every line starts with its number."
  (should (equal (ecc-diff-text-counts (ecc-diff-render "a\nb\nc\n" "a\nB\nC\n" 1))
                 '(2 . 2)))
  (should (equal (ecc-diff-text-counts (ecc-diff-for-write "+a\n+b\n")) '(2 . 0)))
  (should (equal (ecc-diff-text-counts "") '(0 . 0)))
  (should (equal (ecc-diff-text-counts nil) '(0 . 0))))

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

(ert-deftest ecc-diff-test-a-binary-file-has-no-content ()
  "A binary file is not read: there is nothing to diff and a lot to draw."
  (let ((png (expand-file-name "red-square.png"
                               (expand-file-name "fixtures" ecc-test-directory)))
        (text (make-temp-file "ecc-diff-text" nil ".txt" "hello\n")))
    (unwind-protect
        (progn
          (should (ecc-diff-binary-p png))
          (should-not (ecc-diff-file-content png))
          (should-not (ecc-diff-binary-p text))
          (should (equal (ecc-diff-file-content text) "hello\n"))
          ;; An unreadable path counts as binary rather than as text.
          (should (ecc-diff-binary-p "/nonexistent/x")))
      (delete-file text))))

(provide 'ecc-diff-test)

;;; ecc-diff-test.el ends here
