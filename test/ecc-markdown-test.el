;;; ecc-markdown-test.el --- Tests for ecc-markdown  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Markdown faces of FR-OUT-8 (plan section 8).  The text itself
;; must come out unchanged; only faces are added.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-markdown)

(defconst ecc-markdown-test-sample
  "# Title\n\nSome `code` and **bold** here.\n\n- one\n- two\n1. three\n\n```python\nprint(1)\n```\n\nAfter."
  "A reply exercising every construct that is styled.")

(defun ecc-markdown-test--face-at (text needle &optional offset)
  "Return the face at NEEDLE in TEXT, OFFSET characters after its start."
  (let ((pos (string-search needle text)))
    (should pos)
    (get-text-property (+ pos (or offset 0)) 'face text)))

(ert-deftest ecc-markdown-test-text-is-unchanged ()
  "Fontifying only adds properties (FR-OUT-8)."
  (should (equal (substring-no-properties (ecc-markdown-fontify ecc-markdown-test-sample))
                 ecc-markdown-test-sample))
  (should (equal (ecc-markdown-fontify "") ""))
  (should (equal (ecc-markdown-fontify nil) "")))

(ert-deftest ecc-markdown-test-faces ()
  "Headings, bullets, code and bold get their faces; plain text gets none."
  (let ((text (ecc-markdown-fontify ecc-markdown-test-sample)))
    (should (eq (ecc-markdown-test--face-at text "# Title") 'ecc-markdown-heading-face))
    (should (eq (ecc-markdown-test--face-at text "`code`") 'ecc-markdown-code-face))
    (should (eq (ecc-markdown-test--face-at text "**bold**") 'ecc-markdown-bold-face))
    (should (eq (ecc-markdown-test--face-at text "- one") 'ecc-markdown-bullet-face))
    (should (eq (ecc-markdown-test--face-at text "1. three") 'ecc-markdown-bullet-face))
    ;; The bullet face stops at the marker.
    (should-not (ecc-markdown-test--face-at text "- one" 2))
    ;; The fence and everything inside it is code, inline spans included.
    (should (eq (ecc-markdown-test--face-at text "```python") 'ecc-markdown-code-face))
    (should (eq (ecc-markdown-test--face-at text "print(1)") 'ecc-markdown-code-face))
    (should-not (ecc-markdown-test--face-at text "Some "))
    (should-not (ecc-markdown-test--face-at text "After."))))

(ert-deftest ecc-markdown-test-bold-inside-fence-is-code ()
  "Inside a fence nothing but the code face applies."
  (let ((text (ecc-markdown-fontify "```\n**not bold**\n```\n")))
    (should (eq (ecc-markdown-test--face-at text "**not bold**") 'ecc-markdown-code-face))))

(ert-deftest ecc-markdown-test-code-blocks ()
  "Fenced blocks are found with their bodies, for copying (FR-OUT-14 e)."
  (let ((blocks (ecc-markdown-code-blocks ecc-markdown-test-sample)))
    (should (= (length blocks) 1))
    (should (equal (cddr (car blocks)) "print(1)\n"))
    (should (equal (ecc-markdown-code-block-at
                    ecc-markdown-test-sample
                    (string-search "print" ecc-markdown-test-sample))
                   "print(1)\n"))
    (should-not (ecc-markdown-code-block-at ecc-markdown-test-sample 0))
    ;; An unclosed fence is not a block.
    (should-not (ecc-markdown-code-blocks "```\nopen"))))

(provide 'ecc-markdown-test)

;;; ecc-markdown-test.el ends here
