;;; ecc-markdown.el --- Minimal Markdown faces for assistant text  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-markdown-fontify' takes the text of an assistant reply and returns
;; it with faces for headings, list bullets, code blocks, inline code and
;; bold (FR-OUT-8).  The text itself is not changed, so what the model
;; wrote is what the buffer shows and what a copy yields.
;;
;; This is deliberately small.  `markdown-mode' is not used: the session
;; buffer has no font lock (plan section 9, item 7), and a pure function
;; over a string is what the renderer and the tests want.

;;; Code:

(require 'ecc-core)

(defface ecc-markdown-heading-face
  '((t :inherit bold :height 1.1))
  "Face for a Markdown heading line."
  :group 'ecc)

(defface ecc-markdown-code-face
  '((t :inherit fixed-pitch :foreground "#8fbc8f"))
  "Face for code, both fenced blocks and inline spans."
  :group 'ecc)

(defface ecc-markdown-bullet-face
  '((t :inherit font-lock-builtin-face))
  "Face for the marker of a list item."
  :group 'ecc)

(defface ecc-markdown-bold-face
  '((t :inherit bold))
  "Face for bold text."
  :group 'ecc)

(defconst ecc-markdown-fence-regexp "^[ \t]*\\(```\\|~~~\\)"
  "Regexp matching the line that opens or closes a fenced code block.")

(defconst ecc-markdown-heading-regexp "^#\\{1,6\\}[ \t]+.*$"
  "Regexp matching a heading line.")

(defconst ecc-markdown-bullet-regexp "^[ \t]*\\([-*+]\\|[0-9]+[.)]\\)[ \t]+"
  "Regexp matching the marker of a list item; group 1 is the marker.")

(defconst ecc-markdown-inline-code-regexp "`\\([^`\n]+\\)`"
  "Regexp matching an inline code span.")

(defconst ecc-markdown-bold-regexp "\\*\\*\\([^*\n]+\\)\\*\\*"
  "Regexp matching bold text.")

(defun ecc-markdown--add-face (start end face)
  "Give the text between START and END FACE, keeping earlier faces."
  (add-face-text-property start end face nil))

(defun ecc-markdown--fontify-inline (start end)
  "Add the faces of inline code and bold between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward ecc-markdown-inline-code-regexp end t)
      (ecc-markdown--add-face (match-beginning 0) (match-end 0)
                              'ecc-markdown-code-face))
    (goto-char start)
    (while (re-search-forward ecc-markdown-bold-regexp end t)
      (ecc-markdown--add-face (match-beginning 0) (match-end 0)
                              'ecc-markdown-bold-face))))

(defun ecc-markdown-fontify (text)
  "Return TEXT with faces for its Markdown structure.
The characters are left as they are; only text properties are added."
  (if (or (null text) (string-empty-p text))
      (or text "")
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((in-fence nil))
        (while (not (eobp))
          (let ((start (line-beginning-position))
                (end (line-end-position)))
            (cond
             ((looking-at ecc-markdown-fence-regexp)
              (setq in-fence (not in-fence))
              (ecc-markdown--add-face start end 'ecc-markdown-code-face))
             (in-fence
              (ecc-markdown--add-face start end 'ecc-markdown-code-face))
             ((looking-at ecc-markdown-heading-regexp)
              (ecc-markdown--add-face start end 'ecc-markdown-heading-face))
             (t
              (when (looking-at ecc-markdown-bullet-regexp)
                (ecc-markdown--add-face (match-beginning 1) (match-end 1)
                                        'ecc-markdown-bullet-face))
              (ecc-markdown--fontify-inline start end))))
          (forward-line 1)))
      (buffer-string))))

(defun ecc-markdown-code-blocks (text)
  "Return the fenced code blocks of TEXT as a list of (START END . BODY).
START and END are 0-based character positions of the fence lines in
TEXT, and BODY is the text between them without the fences."
  (let (blocks)
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (let (open)
        (while (re-search-forward ecc-markdown-fence-regexp nil t)
          (if (null open)
              (setq open (line-beginning-position))
            (let* ((close (line-end-position))
                   (body-start (save-excursion (goto-char open) (forward-line 1) (point)))
                   (body-end (line-beginning-position)))
              (push (cons (1- open)
                          (cons (1- close)
                                (buffer-substring-no-properties body-start body-end)))
                    blocks)
              (setq open nil))))))
    (nreverse blocks)))

(defun ecc-markdown-code-block-at (text offset)
  "Return the body of the fenced code block of TEXT containing OFFSET.
OFFSET is a 0-based character position.  Returns nil outside a block."
  (cddr (seq-find (lambda (block)
                    (and (<= (car block) offset) (<= offset (cadr block))))
                  (ecc-markdown-code-blocks text))))

(provide 'ecc-markdown)

;;; ecc-markdown.el ends here
