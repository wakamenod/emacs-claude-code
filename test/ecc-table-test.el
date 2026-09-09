;;; ecc-table-test.el --- Tests for ecc-table  -*- lexical-binding: t; -*-

;;; Commentary:

;; A Markdown table is drawn with its columns lined up, however wide the
;; characters of its cells are to draw and however much of them the
;; Markdown code hides.  The tables here are in Japanese on purpose:
;; that is the case the layout exists for.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-markdown)
(require 'ecc-table)

(defun ecc-table-test--lines (text)
  "Return the lines of TEXT once it has been fontified."
  (split-string (string-trim-right (ecc-markdown-fontify text) "\n+") "\n"))

(defun ecc-table-test--widths (text)
  "Return what each line of TEXT costs to draw, in columns.
What is hidden is passed over, which is what the eye does too."
  (mapcar #'ecc-table--width (ecc-table-test--lines text)))

(defun ecc-table-test--rectangular-p (text)
  "Return non-nil when every line of TEXT is drawn the same width."
  (let ((widths (ecc-table-test--widths text)))
    (and widths (apply #'= widths))))

(ert-deftest ecc-table-test-ascii-lines-up ()
  "A plain table comes out framed, and every line of it is as wide."
  (let ((lines (ecc-table-test--lines "| a | bb |\n|---|----|\n| ccc | d |\n")))
    (should (string-prefix-p "┌" (nth 0 lines)))
    (should (string-prefix-p "│" (nth 1 lines)))
    (should (string-prefix-p "├" (nth 2 lines)))
    (should (string-prefix-p "└" (car (last lines))))
    (should (= 5 (length lines)))
    (should (ecc-table-test--rectangular-p "| a | bb |\n|---|----|\n| ccc | d |\n"))))

(ert-deftest ecc-table-test-japanese-lines-up ()
  "A Japanese cell is twice as wide as it is long, and the columns hold."
  (let ((text "| 項目 | 状態 |\n|------|------|\n| 認証 | 完了 |\n| a | 未着手 |\n"))
    (should (ecc-table-test--rectangular-p text))
    ;; Counting characters rather than columns is exactly the mistake
    ;; that leaves the table ragged, so the two must not agree here.
    (should-not (apply #'= (mapcar #'length (ecc-table-test--lines text))))))

(ert-deftest ecc-table-test-hidden-markup-lines-up ()
  "Bold and inline code cost the columns they draw, not the ones they hold."
  (let ((text "| a | b |\n|---|---|\n| **bold** | `code` |\n| x | y |\n"))
    (should (ecc-table-test--rectangular-p text))
    ;; The markup is still there, hidden, so a search still finds it.
    (should (string-search "**bold**" (ecc-markdown-fontify text)))))

(ert-deftest ecc-table-test-alignment ()
  "A colon in the row of dashes puts the cell left, right or in the middle."
  (let ((lines (ecc-table-test--lines
                "| name | value | mid |\n|:-----|------:|:---:|\n| x | y | z |\n")))
    (should (equal (substring-no-properties (nth 3 lines))
                   "│ x    │     y │  z  │"))))

(ert-deftest ecc-table-test-wraps-what-is-too-wide ()
  "A cell wider than its share is wrapped, and nothing is lost."
  (let* ((ecc-table-max-width 30)
         (text "| 名前 | 説明 |\n|---|---|\n| /btw | 走っているターンの脇で質問する |\n")
         (lines (ecc-table-test--lines text)))
    (should (ecc-table-test--rectangular-p text))
    (should (= 30 (ecc-table--width (car lines))))
    ;; The row took two lines rather than one, and the frame is still
    ;; four lines of its own.
    (should (= 6 (length lines)))))

(ert-deftest ecc-table-test-ragged-rows ()
  "A row with too few cells is filled out and one with too many widens it."
  (let ((text "| a | b | c\n|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |\n"))
    (should (ecc-table-test--rectangular-p text))))

(ert-deftest ecc-table-test-escaped-and-quoted-pipes ()
  "A pipe inside code, and one a backslash escapes, part no cells."
  (let ((lines (ecc-table-test--lines "| a | b |\n|---|---|\n| x \\| y | `p|q` |\n")))
    (should (string-search "x \\| y" (nth 3 lines)))
    (should (string-search "p|q" (nth 3 lines)))
    (should (ecc-table-test--rectangular-p "| a | b |\n|---|---|\n| x \\| y | `p|q` |\n"))))

(ert-deftest ecc-table-test-what-is-not-a-table-is-left-alone ()
  "Without the row of dashes there is no table, and a fence holds none."
  (let ((prose "a | b\nc | d\n")
        (fenced "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```\n"))
    (should (equal (substring-no-properties (ecc-markdown-fontify prose)) prose))
    (should (equal (substring-no-properties (ecc-markdown-fontify fenced)) fenced))))

(ert-deftest ecc-table-test-style-off-changes-nothing ()
  "With the style off the table arrives as the model wrote it."
  (let ((ecc-table-style 'off)
        (text "| a | 日本語 |\n|:--|--:|\n| 1 | x |\n"))
    (should (equal (substring-no-properties (ecc-markdown-fontify text)) text))))

(ert-deftest ecc-table-test-style-pipe-keeps-the-pipes ()
  "The pipe style lines the columns up without drawing a frame."
  (let* ((ecc-table-style 'pipe)
         (text "| a | 日本語 |\n|:--|--:|\n| 1 | x |\n")
         (lines (ecc-table-test--lines text)))
    (should (= 3 (length lines)))
    (should (string-prefix-p "|" (car lines)))
    (should (ecc-table-test--rectangular-p text))))

(ert-deftest ecc-table-test-faces ()
  "The frame is dim, the header is bold and the table carries its face."
  (let* ((text (ecc-markdown-fontify "| a | b |\n|---|---|\n| 1 | 2 |\n"))
         (frame (get-text-property (string-search "┌" text) 'face text))
         (header (get-text-property (string-search "a" text) 'face text)))
    (should (memq 'ecc-table-border-face (if (listp frame) frame (list frame))))
    (should (memq 'ecc-table-header-face (if (listp header) header (list header))))
    (should (memq 'ecc-table-face (if (listp header) header (list header))))))

(ert-deftest ecc-table-test-a-table-among-other-things ()
  "Text before and after a table is untouched, and both survive it."
  (let ((lines (ecc-table-test--lines "前置き\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n後書き\n")))
    (should (equal (substring-no-properties (car lines)) "前置き"))
    (should (equal (substring-no-properties (car (last lines))) "後書き"))
    (should (string-prefix-p "┌" (nth 2 lines)))))

(provide 'ecc-table-test)

;;; ecc-table-test.el ends here
