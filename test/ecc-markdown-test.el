;;; ecc-markdown-test.el --- Tests for ecc-markdown  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Markdown faces of FR-OUT-8 (plan section 8).  The text itself
;; must come out unchanged; only faces are added.  A table is the one
;; thing that is redrawn rather than coloured, and it is tested apart in
;; `ecc-table-test'.

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

(defun ecc-markdown-test--faces-at (text needle &optional offset)
  "Return the faces at NEEDLE in TEXT as a list, OFFSET characters in.
A span can carry several faces once a major mode has coloured a code
block on top of `ecc-markdown-code-face' (FR-OUT-15)."
  (let ((face (ecc-markdown-test--face-at text needle offset)))
    (if (listp face) face (list face))))

(ert-deftest ecc-markdown-test-text-is-unchanged ()
  "Fontifying only adds properties (FR-OUT-8).
A table is the one construct whose text is rewritten, and there is none
here; `ecc-table-test' covers that."
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
    (should (memq 'ecc-markdown-code-face
                  (ecc-markdown-test--faces-at text "print(1)")))
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


;;;; Syntax highlighting of code blocks (FR-OUT-15)

(ert-deftest ecc-markdown-test-language-mode ()
  "A fence language is resolved to a major mode, or to nothing."
  (should (eq (ecc-markdown-language-mode "elisp") 'emacs-lisp-mode))
  (should (eq (ecc-markdown-language-mode "ELisp") 'emacs-lisp-mode))
  (should (eq (ecc-markdown-language-mode "lisp") 'lisp-mode))
  ;; Not in the alist, but LANG-mode exists.
  (should (eq (ecc-markdown-language-mode "conf") 'conf-mode))
  ;; No mode by any of the three routes.
  (should-not (ecc-markdown-language-mode "no-such-language"))
  (should-not (ecc-markdown-language-mode ""))
  (should-not (ecc-markdown-language-mode nil)))

(ert-deftest ecc-markdown-test-code-block-is-highlighted ()
  "The body of a fence gets the faces of the mode its language names."
  (let* ((text (ecc-markdown-fontify "```elisp
(defun foo ())
```
"))
         (faces (ecc-markdown-test--faces-at text "defun")))
    (should (memq 'font-lock-keyword-face faces))
    ;; The block is still code, so a span the mode left alone keeps the
    ;; colour every code block has.
    (should (memq 'ecc-markdown-code-face
                  (ecc-markdown-test--faces-at text "foo")))
    ;; The fence lines themselves are not coloured as code.
    (should (eq (ecc-markdown-test--face-at text "```elisp")
                'ecc-markdown-code-face))))

(ert-deftest ecc-markdown-test-unknown-language-falls-back ()
  "A fence naming nothing Emacs knows keeps the plain code face."
  (let ((text (ecc-markdown-fontify "```no-such-language
(defun foo ())
```
")))
    (should (eq (ecc-markdown-test--face-at text "defun") 'ecc-markdown-code-face)))
  (let ((text (ecc-markdown-fontify "```
(defun foo ())
```
")))
    (should (eq (ecc-markdown-test--face-at text "defun") 'ecc-markdown-code-face))))

(ert-deftest ecc-markdown-test-highlighting-can-be-turned-off ()
  "`ecc-markdown-highlight-code' nil leaves every block in one colour."
  (let* ((ecc-markdown-highlight-code nil)
         (text (ecc-markdown-fontify "```elisp
(defun foo ())
```
")))
    (should (eq (ecc-markdown-test--face-at text "defun") 'ecc-markdown-code-face))))

(ert-deftest ecc-markdown-test-long-block-is-not-highlighted ()
  "A block longer than the limit is left in one colour."
  (let* ((body (mapconcat #'identity (make-list 20 "(defun foo ())") "
"))
         (source (format "```elisp
%s
```
" body)))
    (let ((ecc-markdown-highlight-max-lines 5))
      (should (eq (ecc-markdown-test--face-at (ecc-markdown-fontify source) "defun")
                  'ecc-markdown-code-face)))
    (let ((ecc-markdown-highlight-max-lines nil))
      (should (memq 'font-lock-keyword-face
                    (ecc-markdown-test--faces-at (ecc-markdown-fontify source)
                                                 "defun"))))))

(ert-deftest ecc-markdown-test-unclosed-block-is-highlighted ()
  "A block the model is still writing is coloured as far as it goes."
  (let ((text (ecc-markdown-fontify "```elisp
(defun foo ()")))
    (should (memq 'font-lock-keyword-face
                  (ecc-markdown-test--faces-at text "defun")))))

(ert-deftest ecc-markdown-test-highlighting-leaves-the-text-alone ()
  "Colouring a block adds no characters and moves none (FR-OUT-15)."
  (let ((source "Before\n\n```elisp\n(defun foo ())\n```\n\nAfter\n"))
    (should (equal (substring-no-properties (ecc-markdown-fontify source)) source))))

(provide 'ecc-markdown-test)

;;; ecc-markdown-test.el ends here
