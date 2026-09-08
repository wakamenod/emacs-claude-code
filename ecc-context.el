;;; ecc-context.el --- Send what the editor is looking at  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.10 of IMPLEMENTATION_PLAN.md: what Emacs knows that the CLI
;; does not.  `ecc-context-capture' reads the file, the line and the
;; region of the buffer the user last worked in (FR-CTX-1), formats it as
;; a quote block the user can see before it is sent (FR-CTX-2), and the
;; commands at the end send from a source buffer without switching to a
;; transcript first (FR-CTX-5).
;;
;; Everything above `ecc-send' is a pure function of a buffer, so the
;; tests can build the block without a process or a window.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-window)

;; Diagnostics are read from whichever checker the user runs; neither is
;; a dependency of this package.
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flycheck-overlay-errors-at "flycheck" (pos))
(declare-function flycheck-overlay-errors-in "flycheck" (beg end))
(declare-function flycheck-error-message "flycheck" (err))
(declare-function flycheck-error-line "flycheck" (err))

(defcustom ecc-context-attach-by-default nil
  "Non-nil attaches the editor context to every prompt sent (FR-CTX-1).
It can be turned on and off in a session buffer with
\\<ecc-chat-mode-map>\\[ecc-prompt-toggle-context]."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-context-visible t
  "Non-nil appends the context to a prompt as a quote block (FR-CTX-2).
That is what the user sees before sending.  Nil sends the same text
without showing it in the prompt region, which is the invisible form
the requirement makes optional."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-context-cursor-lines 3
  "Lines quoted above and below the cursor by the `@cursor' reference.
Zero sends the line the cursor is on and nothing else."
  :type 'integer
  :group 'ecc)

(defcustom ecc-context-max-lines 200
  "Most lines of a region or a file range quoted into a prompt."
  :type 'integer
  :group 'ecc)

(defcustom ecc-context-language-alist
  '((emacs-lisp-mode . "elisp")
    (lisp-interaction-mode . "elisp")
    (c++-mode . "cpp")
    (c++-ts-mode . "cpp")
    (sh-mode . "bash")
    (bash-ts-mode . "bash"))
  "Major modes whose fenced code block language is not the mode name."
  :type '(alist :key-type symbol :value-type string)
  :group 'ecc)

;;;; Capturing (FR-CTX-1)

(defun ecc-context-mode-for-file (file)
  "Return the major mode `auto-mode-alist' names for FILE, or nil."
  (let ((mode (and file (assoc-default file auto-mode-alist #'string-match))))
    (and (symbolp mode) mode)))

(defun ecc-context-language (&optional mode file)
  "Return the fenced code block language for MODE, or the empty string.
MODE defaults to the major mode of the current buffer; when that is
`fundamental-mode', FILE (or the file of the buffer) is looked up in
`auto-mode-alist' instead, so that a file opened without its mode is
still fenced as what it is."
  (let ((mode (or mode major-mode)))
    (when (eq mode 'fundamental-mode)
      (setq mode (or (ecc-context-mode-for-file (or file buffer-file-name))
                     mode)))
    (or (cdr (assq mode ecc-context-language-alist))
        (let ((name (symbol-name mode)))
          (if (and (not (eq mode 'fundamental-mode))
                   (string-match "\\`\\(.*?\\)\\(-ts\\)?-mode\\'" name))
              (match-string 1 name)
            "")))))

(defun ecc-context-path (&optional buffer root)
  "Return the path of BUFFER relative to ROOT, or its name.
ROOT is where the CLI reading the path stands, and defaults to the
project of BUFFER itself.  A file outside it is named in full: a
relative path would be resolved from the directory of the session and
land on another file of that name, which is worse than a long label."
  (with-current-buffer (or buffer (current-buffer))
    (if buffer-file-name
        (let ((root (or root (ecc-window-project-root))))
          (if (string-prefix-p root buffer-file-name)
              (file-relative-name buffer-file-name root)
            (abbreviate-file-name buffer-file-name)))
      (buffer-name))))

(defun ecc-context--trim (text)
  "Return TEXT cut down to `ecc-context-max-lines' lines."
  (let ((lines (split-string text "\n")))
    (if (<= (length lines) ecc-context-max-lines)
        text
      (concat (string-join (seq-take lines ecc-context-max-lines) "\n")
              (format "\n… (%d more lines omitted)"
                      (- (length lines) ecc-context-max-lines))))))

(cl-defun ecc-context-capture (&key buffer region root)
  "Return what the editor is looking at, as a plist (FR-CTX-1).
BUFFER defaults to `ecc-window-last-source-buffer'.  The keys are
`:path', `:line', `:end-line', `:text' and `:language'; `:text' is only
there when a region is active, or when REGION is a cons of two
positions to take instead of the active one.  ROOT is what `:path' is
relative to, and is the project of the session the prompt goes to."
  (let ((buffer (or buffer (ecc-window-last-source-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((beg (cond ((consp region) (car region))
                          ((use-region-p) (region-beginning))))
               (end (cond ((consp region) (cdr region))
                          ((use-region-p) (region-end)))))
          (list :path (ecc-context-path buffer root)
                :buffer buffer
                :language (ecc-context-language)
                :line (line-number-at-pos (or beg (point)))
                :end-line (and end (line-number-at-pos
                                    (if (and (> end beg) (= (char-before end) ?\n))
                                        (1- end)
                                      end)))
                ;; The newline that ends the last line is part of the
                ;; region but not of the code block.
                :text (and beg (ecc-context--trim
                                (string-trim-right
                                 (buffer-substring-no-properties beg end)
                                 "\n")))))))))

(defun ecc-context-cursor (&optional buffer root)
  "Return what the cursor of BUFFER is looking at, as a plist (FR-CTX-1).
The lines around it are `ecc-context-cursor-lines' either way, while
`:line' is the line the cursor sits on and `:end-line' is nil: the
label of the block points at the cursor, not at the lines that came
along with it.  ROOT is what `:path' is relative to."
  (let ((buffer (or buffer (ecc-window-last-source-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((beg (save-excursion
                     (forward-line (- ecc-context-cursor-lines))
                     (line-beginning-position)))
              (end (save-excursion
                     (forward-line ecc-context-cursor-lines)
                     (line-end-position)))
              (line (line-number-at-pos)))
          (let ((context (ecc-context-capture :buffer buffer
                                              :region (cons beg end)
                                              :root root)))
            (plist-put (plist-put context :line line) :end-line nil)))))))

;;;; Formatting (FR-CTX-2)

(defun ecc-context-location (context)
  "Return the `path L12-L20' line of CONTEXT."
  (let ((line (plist-get context :line))
        (end (plist-get context :end-line)))
    (format "`%s`%s" (plist-get context :path)
            (cond ((and end (/= end line)) (format " L%d-L%d" line end))
                  (line (format " L%d" line))
                  (t "")))))

(defun ecc-context-format (context)
  "Return CONTEXT as the quote block appended to a prompt (FR-CTX-2)."
  (when context
    (concat "\n\n---\nCurrent context: " (ecc-context-location context)
            (when-let* ((text (plist-get context :text)))
              (format "\n```%s\n%s\n```" (plist-get context :language) text)))))

(defun ecc-context-block (&optional buffer root)
  "Return the context quote block for BUFFER, or nil when there is none.
ROOT is what the path of the block is relative to."
  (ecc-context-format (ecc-context-capture :buffer buffer :root root)))

;;;; File ranges and diagnostics (FR-INP-8, FR-CTX-4)

(defun ecc-context-file-range (path &optional start end)
  "Return lines START to END of PATH as a plist like `ecc-context-capture'.
The whole file is taken when START is nil.  Nil is returned when the
file cannot be read; a live buffer visiting it is preferred over the
file on disk, so that unsaved work is quoted as the user sees it."
  (let* ((file (expand-file-name path (ecc-window-project-root)))
         (buffer (find-buffer-visiting file)))
    (when (or buffer (file-readable-p file))
      (with-temp-buffer
        (if buffer
            (insert (with-current-buffer buffer
                      (buffer-substring-no-properties (point-min) (point-max))))
          (insert-file-contents file))
        (let* ((last (line-number-at-pos (point-max)))
               (start (max 1 (or start 1)))
               (end (min last (or end last)))
               (beg-pos (progn (goto-char (point-min))
                               (forward-line (1- start))
                               (point)))
               (end-pos (progn (goto-char (point-min))
                               (forward-line end)
                               (point))))
          (list :path path
                :language (ecc-context-language
                           (or (and buffer (buffer-local-value 'major-mode buffer))
                               (ecc-context-mode-for-file file)
                               major-mode)
                           file)
                :line start
                :end-line end
                :text (ecc-context--trim
                       (string-trim-right
                        (buffer-substring-no-properties beg-pos end-pos)
                        "\n"))))))))

(defun ecc-context--flymake (beg end)
  "Return the flymake diagnostics between BEG and END as (LINE . TEXT)."
  (when (fboundp 'flymake-diagnostics)
    (mapcar (lambda (diagnostic)
              (cons (line-number-at-pos (flymake-diagnostic-beg diagnostic))
                    (flymake-diagnostic-text diagnostic)))
            (flymake-diagnostics beg end))))

(defun ecc-context--flycheck (beg end)
  "Return the flycheck errors between BEG and END as (LINE . TEXT)."
  (when (fboundp 'flycheck-overlay-errors-in)
    (mapcar (lambda (error)
              (cons (flycheck-error-line error) (flycheck-error-message error)))
            (flycheck-overlay-errors-in beg end))))

(defun ecc-context--one-line (text)
  "Return TEXT on one line, with runs of whitespace squeezed out."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))

(defun ecc-context-diagnostics (&optional buffer beg end)
  "Return the diagnostics of BUFFER between BEG and END as strings.
The whole buffer is read when BEG is nil.  flymake is asked first, then
flycheck, and finally the help text of the overlays at point, which is
what a checker this package does not know about leaves behind."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((beg (or beg (point-min)))
           (end (or end (point-max)))
           (found (or (ecc-context--flymake beg end)
                      (ecc-context--flycheck beg end)
                      (when-let* ((help (get-char-property beg 'help-echo)))
                        (and (stringp help)
                             (list (cons (line-number-at-pos beg) help)))))))
      (mapcar (lambda (entry)
                (format "L%d: %s" (or (car entry) 0)
                        (ecc-context--one-line (cdr entry))))
              (seq-sort-by #'car #'< (delq nil found))))))

(defun ecc-context-diagnostics-block (&optional buffer beg end)
  "Return the diagnostics of BUFFER between BEG and END as a quote block."
  (let ((diagnostics (ecc-context-diagnostics buffer beg end)))
    (when diagnostics
      (format "```\n%s\n```" (string-join diagnostics "\n")))))

;;;; Commands that send from a source buffer (FR-CTX-5)

(defun ecc-context--send (text &optional session)
  "Send TEXT to SESSION, or to the session this buffer resolves to.
The prompt is queued when a turn is running (FR-INP-6); either way the
user is told what happened, because the transcript may not be on
screen."
  (let* ((session (or session (ecc-window-resolve-session current-prefix-arg)))
         (outcome (ecc-proc-send-prompt session text)))
    (if (eq outcome 'sent)
        (message "Sent to %s" (ecc-session-name session))
      (message "%s: a turn is running; queued at position %d"
               (ecc-session-name session) outcome))
    session))

;;;###autoload
(defun ecc-send (text &optional session)
  "Send TEXT from the minibuffer to SESSION (FR-CTX-5 a).
A prefix argument asks which session to send to."
  (interactive (list (read-string "Claude: ")))
  (when (string-empty-p (string-trim text))
    (user-error "Prompt is empty"))
  (ecc-context--send text session))

;;;###autoload
(defun ecc-send-with-context (text &optional session)
  "Send TEXT with the file and line of the current buffer (FR-CTX-5 b).
SESSION defaults to the one this buffer resolves to (FR-WIN-4)."
  (interactive (list (read-string "Claude (with context): ")))
  (ecc-context--send (concat text (or (ecc-context-block) "")) session))

;;;###autoload
(defun ecc-send-region (&optional beg end instruction)
  "Send the region, or the whole buffer, to Claude (FR-CTX-5 c).
BEG and END default to the region.  INSTRUCTION is asked for with a
prefix argument and put before the quoted code."
  (interactive
   (let ((instruction (when current-prefix-arg
                        (read-string "Instruction: "))))
     (if (use-region-p)
         (list (region-beginning) (region-end) instruction)
       (list (point-min) (point-max) instruction))))
  (let* ((buffer (current-buffer))
         (context (ecc-context-capture :buffer buffer :region (cons beg end)))
         (instruction (if (and instruction (not (string-empty-p (string-trim instruction))))
                          (string-trim instruction)
                        "Please answer the following about this code.")))
    (ecc-context--send (concat instruction (ecc-context-format context)))))

;;;###autoload
(defun ecc-send-buffer-file (&optional instruction)
  "Send the file of the current buffer as an @path reference (FR-CTX-5 d).
INSTRUCTION is asked for with a prefix argument."
  (interactive (list (when current-prefix-arg (read-string "Instruction: "))))
  (let ((file (or (buffer-file-name)
                  (user-error "This buffer is not visiting a file"))))
    (when (and (buffer-modified-p) (y-or-n-p "Save the buffer before sending? "))
      (save-buffer))
    (ecc-context--send
     (string-trim (format "%s @%s"
                          (or instruction "Please look at the following file.")
                          (ecc-context-path))))
    file))

;;;###autoload
(defun ecc-fix-error-at-point (&optional instruction)
  "Ask Claude to fix the diagnostic at point (FR-CTX-5 e, FR-CTX-4).
The diagnostics on the current line are quoted with the code around
them.  INSTRUCTION replaces the default request when given."
  (interactive (list (when current-prefix-arg (read-string "Instruction: "))))
  (let* ((line-beg (line-beginning-position))
         (line-end (line-end-position))
         (diagnostics (or (ecc-context-diagnostics nil line-beg line-end)
                          (user-error "No diagnostics on this line")))
         (context (ecc-context-capture
                   :buffer (current-buffer)
                   :region (cons (save-excursion
                                   (goto-char line-beg)
                                   (forward-line -3)
                                   (point))
                                 (save-excursion
                                   (goto-char line-end)
                                   (forward-line 4)
                                   (point))))))
    (ecc-context--send
     (concat (or instruction "Please fix the following error.")
             "\n\n```\n" (string-join diagnostics "\n") "\n```"
             (ecc-context-format context)))))

(provide 'ecc-context)

;;; ecc-context.el ends here
