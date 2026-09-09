;;; ecc-markdown.el --- Minimal Markdown faces for assistant text  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-markdown-fontify' takes the text of an assistant reply and returns
;; it with faces for headings, list bullets, code blocks, inline code and
;; bold (FR-OUT-8).  Apart from a table, the text itself is not changed,
;; so what the model wrote is what the buffer shows and what a copy
;; yields.  A table is the one thing that cannot be lined up with
;; properties alone, and `ecc-table-format' redraws it; see
;; `ecc-table.el'.
;;
;; This is deliberately small.  `markdown-mode' is not used: the session
;; buffer has no font lock (plan section 9, item 7), and a pure function
;; over a string is what the renderer and the tests want.
;;
;; A fenced code block whose fence names a language Emacs has a major
;; mode for is coloured with that mode (FR-OUT-15).  The mode runs in a
;; temporary buffer and only its faces are copied out, so the session
;; buffer still has no font lock of its own.

;;; Code:

(require 'cl-lib)
(require 'ecc-core)
(require 'ecc-table)

(defface ecc-markdown-heading-face
  '((t :inherit bold :height 1.1))
  "Face for a Markdown heading line."
  :group 'ecc)

(defface ecc-markdown-code-face
  '((((background dark) (min-colors 88)) :foreground "#a5b4fc")
    (((background light) (min-colors 88)) :foreground "#5a5fd0")
    (((background dark)) :foreground "brightblue")
    (t :foreground "blue"))
  "Face for code, both fenced blocks and inline spans.
Only the foreground is set, and it is a pale violet leaning towards
blue -- the violet the terminal client draws with (`autoAccept\=',
#af87ff; `docs/verified.md\=', 2026-09-08) was too strong to read a
sentence through, so this is lighter and cooler than that.
A band of background behind every function name broke the line up and
was hard to read, so there is none (2026-09-09).  Inside a fenced block
the faces of the major mode are laid on top of this one, so code that is
highlighted keeps its own colours and only what the mode leaves alone is
coloured here.

The font is left alone as well, and `fixed-pitch' in particular is not
inherited.  The transcript is already drawn in the default face, which
is where a reader has put the pair of fonts that draws a Japanese
character exactly twice as wide as a Latin one; `fixed-pitch' names a
family of its own (Courier, on a Mac), the Japanese of the block keeps
falling back to the reader\='s own font, and the two are then no longer
in step -- which is what tears a table inside a fence out of line.  A
reader whose default face is proportional can put `:inherit
fixed-pitch' back."
  :group 'ecc)

(defface ecc-markdown-bullet-face
  '((t :inherit font-lock-builtin-face))
  "Face for the marker of a list item."
  :group 'ecc)

(defface ecc-markdown-bold-face
  '((t :inherit bold))
  "Face for bold text."
  :group 'ecc)

(defconst ecc-markdown-fence-regexp
  "^[ \t]*\\(```\\|~~~\\)[ \t]*\\([^ \t\n`]*\\)"
  "Regexp matching the line that opens or closes a fenced code block.
Group 1 is the fence itself and group 2 the language it names, which is
empty on a closing fence and on an opening one that names nothing.")

(defconst ecc-markdown-heading-regexp "^#\\{1,6\\}[ \t]+.*$"
  "Regexp matching a heading line.")

(defconst ecc-markdown-bullet-regexp "^[ \t]*\\([-*+]\\|[0-9]+[.)]\\)[ \t]+"
  "Regexp matching the marker of a list item; group 1 is the marker.")

(defconst ecc-markdown-inline-code-regexp "`\\([^`\n]+\\)`"
  "Regexp matching an inline code span.")

(defconst ecc-markdown-bold-regexp "\\*\\*\\([^*\n]+\\)\\*\\*"
  "Regexp matching bold text.")

(defcustom ecc-markdown-hide-markup t
  "Non-nil hides the markup around bold, code and headings (FR-OUT-8).
Nil leaves the asterisks, the backquotes and the number signs in
sight, which is what a reader who wants the source of the reply
rather than its shape wants."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-markdown-highlight-code t
  "Non-nil colours a fenced code block with the major mode of its language.
Nil leaves every block in `ecc-markdown-code-face' (FR-OUT-15)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-markdown-highlight-max-lines 300
  "Longest code block, in lines, that is coloured with a major mode.
A long block in a heavy mode costs more than the colour is worth, and
the transcript is redrawn often.  Nil colours every block."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'ecc)

(defcustom ecc-markdown-language-modes
  '(("elisp" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode)
    ("el" . emacs-lisp-mode)
    ("lisp" . lisp-mode)
    ("bash" . sh-mode)
    ("sh" . sh-mode)
    ("shell" . sh-mode)
    ("zsh" . sh-mode)
    ("console" . sh-mode)
    ("c++" . c++-mode)
    ("cpp" . c++-mode)
    ("cxx" . c++-mode)
    ("objc" . objc-mode)
    ("js" . js-mode)
    ("jsx" . js-mode)
    ("javascript" . js-mode)
    ("json" . js-json-mode)
    ("py" . python-mode)
    ("yml" . yaml-mode)
    ("md" . markdown-mode)
    ("markdown" . markdown-mode))
  "Fence languages whose major mode is not named after them.
A language that is not listed is looked up by trying `LANG-mode' and
`LANG-ts-mode', and then `auto-mode-alist' for the extension LANG."
  :type '(alist :key-type string :value-type symbol)
  :group 'ecc)

(defun ecc-markdown-language-mode (language)
  "Return the major mode that colours LANGUAGE, or nil when there is none.
Only a mode that is defined in this Emacs is returned, so a fence
naming a language no mode is installed for falls back to plain text."
  (when (and language (not (string-empty-p language)))
    (let* ((name (downcase language))
           (mode (or (cdr (assoc name ecc-markdown-language-modes))
                     (intern-soft (concat name "-ts-mode"))
                     (intern-soft (concat name "-mode"))
                     (let ((guess (assoc-default (concat "x." name) auto-mode-alist
                                                 #'string-match)))
                       (and (symbolp guess) guess)))))
      (and mode (fboundp mode) mode))))

(defun ecc-markdown--mode-faces (text mode)
  "Return the faces MODE gives TEXT as a list of (START END . FACE).
START and END are 0-based offsets into TEXT.  A mode that fails to
load, or to fontify, yields nil rather than an error: colour is not
worth breaking a transcript over."
  (condition-case error
      (with-temp-buffer
        (let ((inhibit-modification-hooks t))
          (insert text)
          (delay-mode-hooks (funcall mode))
          (font-lock-ensure))
        ;; A mode may colour with `font-lock-face' rather than `face';
        ;; both mean the same thing to the buffer the text ends up in.
        (let ((pos (point-min)))
          (while (< pos (point-max))
            (let ((next (next-single-property-change pos 'font-lock-face nil (point-max)))
                  (face (get-text-property pos 'font-lock-face)))
              (when face (add-face-text-property pos next face t))
              (setq pos next))))
        (let ((pos (point-min))
              (result nil))
          (while (< pos (point-max))
            (let ((next (next-single-property-change pos 'face nil (point-max)))
                  (face (get-text-property pos 'face)))
              (when face
                (push (cons (1- pos) (cons (1- next) face)) result))
              (setq pos next)))
          (nreverse result)))
    (error
     (ecc-log "markdown" "%s could not colour a code block: %s"
              mode (error-message-string error))
     nil)))

(defun ecc-markdown--add-face (start end face)
  "Give the text between START and END FACE, keeping earlier faces."
  (add-face-text-property start end face nil))

(defun ecc-markdown--hide-markup (start end)
  "Hide the text between START and END with the ecc-markup invisible spec.
Text is hidden but searchable; isearch-open-invisible makes it visible
during search."
  (when ecc-markdown-hide-markup
    (add-text-properties start end '(invisible ecc-markup
                                     isearch-open-invisible
                                     ecc-markdown--open-invisible))))

(defun ecc-markdown--open-invisible (overlay)
  "Open the text hidden by OVERLAY for `isearch-open-invisible'."
  (remove-text-properties (overlay-start overlay) (overlay-end overlay)
                          '(invisible ecc-markup)))

(defun ecc-markdown--fontify-code (start end language)
  "Colour the code between START and END with the mode of LANGUAGE.
START and END are positions in the current buffer, which holds the
text being fontified.  Nothing happens when the language is unknown,
when the block is longer than `ecc-markdown-highlight-max-lines', or
when `ecc-markdown-highlight-code' is nil."
  (when (and ecc-markdown-highlight-code (< start end))
    (when-let* ((mode (ecc-markdown-language-mode language))
                (text (buffer-substring-no-properties start end))
                (short (or (null ecc-markdown-highlight-max-lines)
                           (<= (1+ (cl-count ?\n text))
                               ecc-markdown-highlight-max-lines))))
      (pcase-dolist (`(,from ,to . ,face) (ecc-markdown--mode-faces text mode))
        (add-face-text-property (+ start from) (+ start to) face nil)))))

(defun ecc-markdown--fontify-inline (start end)
  "Add the faces of inline code and bold between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward ecc-markdown-inline-code-regexp end t)
      (ecc-markdown--add-face (match-beginning 0) (match-end 0)
                              'ecc-markdown-code-face)
      (ecc-markdown--hide-markup (match-beginning 0) (1+ (match-beginning 0)))
      (ecc-markdown--hide-markup (1- (match-end 0)) (match-end 0)))
    (goto-char start)
    (while (re-search-forward ecc-markdown-bold-regexp end t)
      (ecc-markdown--add-face (match-beginning 0) (match-end 0)
                              'ecc-markdown-bold-face)
      (ecc-markdown--hide-markup (match-beginning 0) (+ (match-beginning 0) 2))
      (ecc-markdown--hide-markup (- (match-end 0) 2) (match-end 0)))))

(defun ecc-markdown--fontify-table (start)
  "Lay out the table beginning at START, and return where its last line does.
START is at the beginning of the line the table opens on.  The inline
markup of the cells is coloured first, because hiding it is what makes
a cell narrower than the characters it holds and the layout counts what
is drawn (see `ecc-table--width').  The table is then replaced by
`ecc-table-format', which is the one place where fontifying changes the
text rather than only its properties."
  (let ((end (ecc-table-end))
        (lines nil))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (ecc-markdown--fontify-inline (line-beginning-position) (line-end-position))
        (forward-line 1)))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (push (buffer-substring (line-beginning-position) (line-end-position)) lines)
        (forward-line 1)))
    (let ((drawn (ecc-table-format (nreverse lines))))
      (delete-region start end)
      (goto-char start)
      (insert (string-join drawn "\n"))
      ;; The loop this returns to steps over one line, so point is left
      ;; on the last of the lines that were put in rather than past it.
      (goto-char (line-beginning-position))
      (point))))

(defun ecc-markdown-fontify (text)
  "Return TEXT with faces for its Markdown structure.
Every character is left as it is, a table apart; the rest is text
properties.
The body of a fenced code block gets the faces of the major mode its
fence names on top of `ecc-markdown-code-face' (FR-OUT-15).  Markup
symbols are hidden by the ecc-markup invisible property when
`ecc-markdown-hide-markup' is non-nil (FR-OUT-8).  A pipe table is the
one construct whose text is rewritten: `ecc-table-format' draws it with
its columns lined up."
  (if (or (null text) (string-empty-p text))
      (or text "")
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((body-start nil)
            (language nil))
        (while (not (eobp))
          (let ((start (line-beginning-position))
                (end (line-end-position)))
            (cond
             ((looking-at ecc-markdown-fence-regexp)
              (ecc-markdown--add-face start end 'ecc-markdown-code-face)
              ;; The fence says nothing a reader who can see the block
              ;; needs, so the whole line goes, the newline that ends it
              ;; included: what is left is the code.
              (ecc-markdown--hide-markup start (min (point-max) (1+ end)))
              (if body-start
                  (progn
                    (ecc-markdown--fontify-code body-start start language)
                    (setq body-start nil language nil))
                (setq language (match-string 2)
                      body-start (min (point-max) (1+ end)))))
             (body-start
              (ecc-markdown--add-face start end 'ecc-markdown-code-face))
             ((looking-at ecc-markdown-heading-regexp)
              (save-excursion
                (goto-char start)
                (ecc-markdown--hide-markup (point) (re-search-forward "#+" nil t)))
              (ecc-markdown--add-face start end 'ecc-markdown-heading-face))
             ((and (not (eq ecc-table-style 'off)) (ecc-table-at-point-p))
              (ecc-markdown--fontify-table start))
             (t
              (when (looking-at ecc-markdown-bullet-regexp)
                (let ((bullet-start (match-beginning 1))
                      (bullet-end (match-end 1)))
                  (put-text-property bullet-start bullet-end 'display "•")
                  (ecc-markdown--add-face bullet-start bullet-end
                                          'ecc-markdown-bullet-face)))
              (ecc-markdown--fontify-inline start end))))
          (forward-line 1))
        ;; A block the model has not closed yet: colour what is there.
        (when body-start
          (ecc-markdown--fontify-code body-start (point-max) language)))
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
