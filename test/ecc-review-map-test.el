;;; ecc-review-map-test.el --- Tests for ecc-review-map  -*- lexical-binding: t; -*-

;;; Commentary:

;; Where a line of one reading of a diff is in the next, from the shapes
;; of the two readings alone.  The readings are diffs read the way the
;; review reads them, in a buffer of their own.

;;; Code:

(require 'ert)
(require 'ecc-review)
(require 'ecc-review-map)

(defun ecc-review-map-test--shape (diff &optional base)
  "Return the shape of the one file of the unified DIFF, its old side BASE."
  (with-temp-buffer
    (diff-mode)
    (insert diff)
    (ecc-review-map-shape (ecc-review--lines) base)))

(defun ecc-review-map-test--at (map side number &optional nth)
  "Return the number MAP carries line NUMBER of SIDE, the NTH of those, to."
  (car (funcall map side number nth)))

(defun ecc-review-map-test--diff (&rest hunks)
  "Return a diff of a.txt made of HUNKS, each a string with its @@ line."
  (concat "--- a/a.txt\n+++ b/a.txt\n" (apply #'concat hunks)))

(ert-deftest ecc-review-map-test-the-shape-of-a-reading ()
  "A shape keeps the lines taken out and put in, by number, and the hunks."
  (let ((shape (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -2,1 +2,2 @@\n-b\n+B\n+C\n"
                                           "@@ -9,0 +11,1 @@\n+z\n")
                "1234567")))
    (should (equal (ecc-review-map-shape-base shape) "1234567"))
    (should (equal (ecc-review-map-shape-removed shape) '((2 . "b"))))
    (should (equal (ecc-review-map-shape-added shape) '((2 . "B") (3 . "C") (11 . "z"))))
    (should (equal (ecc-review-map-shape-hunks shape)
                   '((("@@ -2,1 +2,2 @@" . 0) (old 2 . 0) (new 2 . 0) (new 3 . 0))
                     (("@@ -9,0 +11,1 @@" . 0) (new 11 . 0)))))
    (should (equal (ecc-review-map-shape-order shape)
                   '((old 2 . 0) (new 2 . 0) (new 3 . 0) (new 11 . 0))))))

(ert-deftest ecc-review-map-test-lines-put-in-above ()
  "Lines put in above a line, in its hunk or another, move it down."
  (let* ((from (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -6,0 +7,3 @@\n+def share():\n+    t = total()\n+    return p / t\n")))
         (to (ecc-review-map-test--shape
              (ecc-review-map-test--diff "@@ -0,0 +1,1 @@\n+import math\n"
                                         "@@ -6,0 +8,5 @@\n+def share():\n+    t = total()\n"
                                         "+    if t == 0:\n+        return 0\n+    return p / t\n")))
         (map (ecc-review-map-lines from to)))
    (should (equal (mapcar (lambda (line) (ecc-review-map-test--at map 'new line)) '(7 8 9)) '(8 9 12)))
    ;; A line of the old side the diff does not show moves by one too.
    (should (= (ecc-review-map-test--at map 'new 3) 4))
    (should (= (ecc-review-map-test--at map 'new 40) 43))
    ;; The old side does not move.
    (should (= (ecc-review-map-test--at map 'old 5) 5))))

(ert-deftest ecc-review-map-test-a-changed-line-matches-nothing ()
  "A line that changed, or went, is nowhere, however alike the lines elsewhere."
  (let* ((from (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -0,0 +1,4 @@\n+f() {\n+  if (x)\n+    return nil;\n+}\n"
                                           "@@ -10,0 +15,4 @@\n+g() {\n+  if (y)\n+    return nil;\n+}\n")))
         (to (ecc-review-map-test--shape
              (ecc-review-map-test--diff "@@ -0,0 +1,4 @@\n+f() {\n+  if (x)\n+    return 0;\n+}\n"
                                         "@@ -10,0 +15,4 @@\n+g() {\n+  if (y)\n+    return nil;\n+}\n")))
         (map (ecc-review-map-lines from to)))
    (should-not (ecc-review-map-test--at map 'new 3))
    (should (equal (mapcar (lambda (line) (ecc-review-map-test--at map 'new line)) '(1 2 4 17)) '(1 2 4 17)))))

(ert-deftest ecc-review-map-test-a-moved-old-side ()
  "When the old side moved, its lines are carried through the hunks between the two."
  ;; Numbered as `ecc-diff-hunks' numbers them: what takes nothing out
  ;; is in front of the line it names.
  (should (equal (ecc-review-map-text-hunks "1\n2\n3\n4\nx\n6\n" "a\nb\n1\n2\n3\n4\ny\n6\n")
                 '((1 0 1 2) (5 1 7 1))))
  (should (equal (ecc-review-map-text-hunks "a\nb\nc\n" "a\nc\n") '((2 1 2 0))))
  (let* ((hunks '((1 0 1 2) (5 1 7 1) (10 0 12 3)))
         (forward (ecc-diff-shifter hunks))
         (backward (ecc-diff-shifter hunks t)))
    (should (equal (mapcar forward '(1 4 5 6 9 10 12)) '(3 6 nil 8 11 15 17)))
    (should (equal (mapcar backward '(1 2 3 7 11 12 14 15)) '(nil nil 1 nil 9 nil nil 10))))
  (let* ((from (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -0,0 +1,2 @@\n+import\n+\n"
                                           "@@ -6,0 +9,1 @@\n+share\n")
                "aaaaaaa"))
         (to (ecc-review-map-test--shape
              (ecc-review-map-test--diff "@@ -8,0 +9,1 @@\n+share\n")
              "bbbbbbb")))
    ;; Not knowing how the old sides differ, nothing is matched.
    (should-not (ecc-review-map-test--at (ecc-review-map-lines from to 'unknown) 'new 9))
    (let ((map (ecc-review-map-lines from to '((1 0 1 2)))))
      (should (= (ecc-review-map-test--at map 'new 9) 9))
      ;; The import is in the old side now: no change, and no line put in.
      (should-not (ecc-review-map-test--at map 'new 1))
      (should (= (ecc-review-map-test--at map 'old 3) 5)))))

(ert-deftest ecc-review-map-test-an-old-side-that-appears-or-is-the-same ()
  "No hunks between two old sides is one side; `none' carries no line of it."
  (let* ((from (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -2,1 +2,2 @@\n-b\n+B\n+C\n") "aaaaaaa"))
         (to (ecc-review-map-test--shape
              (ecc-review-map-test--diff "@@ -0,0 +1,1 @@\n+top\n@@ -2,1 +3,2 @@\n-b\n+B\n+C\n")
              "aaaaaaaa")))
    (let ((map (ecc-review-map-lines from to nil)))
      (should (= (ecc-review-map-test--at map 'new 2) 3))
      (should (= (ecc-review-map-test--at map 'old 2) 2)))
    (let* ((to (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -0,0 +1,4 @@\n+a\n+B\n+C\n+c\n") 'empty))
           (map (ecc-review-map-lines from to 'none)))
      (should (= (ecc-review-map-test--at map 'new 2) 2))
      (should (= (ecc-review-map-test--at map 'new 3) 3))
      (should-not (ecc-review-map-test--at map 'old 2)))))

(ert-deftest ecc-review-map-test-patches-of-each-edit-are-matched-by-text ()
  "Two readings that do not say their old side are matched by the text of their lines.
A diff made from what a session recorded joins a patch for each edit,
each numbered against the file as that edit found it: a patch put in
before two others does not move them, and they are not the same old
side either."
  (let* ((from (ecc-review-map-test--shape
                (ecc-review-map-test--diff "@@ -10,0 +10 @@\n+a\n" "@@ -20,0 +20 @@\n+b\n")))
         (to (ecc-review-map-test--shape
              (ecc-review-map-test--diff "@@ -2,0 +2,2 @@\n+x\n+y\n"
                                         "@@ -10,0 +10 @@\n+a\n" "@@ -20,0 +20 @@\n+b\n")))
         (map (ecc-review-map-lines from to 'text)))
    (should-not (ecc-review-map-same-base-p from to))
    (should (= (ecc-review-map-test--at map 'new 10) 10))
    (should (= (ecc-review-map-test--at map 'new 20) 20))
    ;; Nothing was taken out to be matched.
    (should-not (ecc-review-map-test--at map 'old 10))
    ;; A line rewritten is still nowhere.
    (let ((to (ecc-review-map-test--shape
               (ecc-review-map-test--diff "@@ -10,0 +10 @@\n+A\n" "@@ -20,0 +20 @@\n+b\n"))))
      (should-not (ecc-review-map-test--at (ecc-review-map-lines from to 'text) 'new 10)))))

(ert-deftest ecc-review-map-test-patches-sharing-a-number ()
  "Two patches of one file at one number are two lines, matched each to its own.
A diff that joins a patch for each edit numbers each against the file as
its edit found it: the NTH of a line tells them apart."
  (let* ((diff (lambda (&rest hunks) (apply #'ecc-review-map-test--diff hunks)))
         (from (ecc-review-map-test--shape
                (funcall diff "@@ -10,1 +10,1 @@\n-a old\n+a new\n"
                         "@@ -10,1 +10,1 @@\n-b old\n+b new\n")))
         (to (ecc-review-map-test--shape
              (funcall diff "@@ -2,0 +2 @@\n+top\n"
                       "@@ -10,1 +10,1 @@\n-a old\n+a new\n"
                       "@@ -10,1 +10,1 @@\n-b old\n+b new\n")))
         (map (ecc-review-map-lines from to 'text)))
    (should (equal (mapcar #'car (ecc-review-map-shape-hunks from))
                   '(("@@ -10,1 +10,1 @@" . 0) ("@@ -10,1 +10,1 @@" . 1))))
    (should (equal (funcall map 'new 10 0) '(10 . 0)))
    (should (equal (funcall map 'new 10 1) '(10 . 1)))
    (should (equal (funcall map 'old 10 1) '(10 . 1)))))

(ert-deftest ecc-review-map-test-a-new-file-too-large-to-compare-whole ()
  "A file put in whole is matched by its lines that are there once, then between them."
  (let* ((lines (mapcar (lambda (n) (format "line %d" n)) (number-sequence 1 400)))
         (diff (lambda (lines)
                 (ecc-review-map-test--diff
                  (format "@@ -0,0 +1,%d @@\n" (length lines))
                  (mapconcat (lambda (line) (concat "+" line "\n")) lines ""))))
         (from (ecc-review-map-test--shape (funcall diff (append '("}" "}") lines))))
         (to (ecc-review-map-test--shape
              (funcall diff (append '("new" "}" "}")
                                    (seq-take lines 199) '("changed") (seq-drop lines 200)))))
         (ecc-diff-max-cells 1000)
         (map (ecc-review-map-lines from to)))
    (should (= (ecc-review-map-test--at map 'new 1) 2))
    (should (= (ecc-review-map-test--at map 'new 3) 4))
    (should-not (ecc-review-map-test--at map 'new 202))
    (should (= (ecc-review-map-test--at map 'new 402) 403))))

(provide 'ecc-review-map-test)
;;; ecc-review-map-test.el ends here
