;;; ecc-plan.el --- Reviewing a plan before Claude leaves plan mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The ExitPlanMode request carries the whole plan.  It is opened in an
;; editable buffer where feedback is given three ways: a comment
;; attached to a line, an `@claude:' marker written into the text, and a
;; plain edit of the text.  Approving with C-c C-c looks for all three;
;; when any is found the request is denied with a structured message
;; that asks for a new plan, otherwise it is allowed together with the
;; permission mode to switch to.  A plan shown again marks the lines
;; that changed since the last one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'diff-mode)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-diff)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-window)

(defvar ecc-plan-modes '("acceptEdits" "default" "bypassPermissions" "plan")
  "Permission modes offered when a plan is approved.
Choosing \"plan\" sends setMode plan back with the approval; whether
the CLI stays in plan mode after ExitPlanMode is not verified.")

(defcustom ecc-plan-default-mode "acceptEdits"
  "Permission mode switched to when a plan is approved without choosing one.
Nil approves without asking for a mode change, which the CLI answers
by leaving plan mode for the default mode."
  :type '(choice (const :tag "Leave it to the CLI" nil) string)
  :group 'ecc)

(defvar ecc-plan-auto-open t
  "Non-nil opens the review buffer as soon as a plan arrives.
Only done while the transcript of the session is on screen, so that a
session running in the background does not grab the window.")

(defvar ecc-plan-feedback-footer
  "Please update your plan to match these changes and call ExitPlanMode again."
  "Sentence that closes every feedback message.")

(defface ecc-plan-comment-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face of a line comment shown after the line it belongs to."
  :group 'ecc)

(defface ecc-plan-commented-line-face
  '((t :underline (:style wave :color "orange")))
  "Face of a line that carries a comment."
  :group 'ecc)

(defface ecc-plan-changed-face
  '((t :inherit diff-added :weight bold))
  "Face of the margin mark on a line that changed since the last plan."
  :group 'ecc)

(defconst ecc-plan-marker-regexp "^.*@[Cc]laude:?[ \t]*\\(.+\\)$"
  "Matches a line holding an @claude marker; group 1 is the text.")

;;;; The buffer

(defvar-local ecc-plan--request nil
  "The ExitPlanMode request this buffer reviews.")

(defvar-local ecc-plan--original nil
  "The plan text as Claude sent it.")

(defvar-local ecc-plan--comments nil
  "Overlays of the line comments, in no particular order.")

(defvar-local ecc-plan--mode nil
  "Permission mode chosen with `ecc-plan-set-mode', or nil for the default.")

(defvar-local ecc-plan--changes nil
  "(ADDED . REMOVED) line counts against the previous plan, or nil.")

(defalias 'ecc-plan--parent-mode
  (if (require 'markdown-mode nil t) 'markdown-mode 'text-mode)
  "The mode `ecc-plan-mode' is derived from: markdown-mode when installed.")

(defvar ecc-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-plan-approve)
    (define-key map (kbd "C-c C-k") #'ecc-plan-deny)
    (define-key map (kbd "C-c C-d") #'ecc-plan-show-diff)
    (define-key map (kbd "C-c C-a") #'ecc-plan-comment)
    (define-key map (kbd "C-c C-r") #'ecc-plan-remove-comment)
    (define-key map (kbd "C-c C-p") #'ecc-plan-set-mode)
    (define-key map (kbd "C-c C-n") #'ecc-plan-next-change)
    map)
  "Keymap of `ecc-plan-mode\='.
The plan is edited here, so a letter has to stay a letter and every
command sits under \\`C-c C-\='.  Not \\`C-c <letter>\=': the Emacs Lisp
manual reserves that for users.  \\`C-c C-m\=' is unusable as well,
because a terminal cannot tell it from \\`C-c RET\='.  `a\=' adds a note
and `r\=' removes it; `p\=' is the permission mode, as it is in
`ecc-menu\='.")

(define-derived-mode ecc-plan-mode ecc-plan--parent-mode "Claude-Plan"
  "Major mode of the buffer a plan is reviewed in.

\\{ecc-plan-mode-map}"
  :interactive nil
  (setq header-line-format '(:eval (ecc-plan--header-line))))

(defun ecc-plan-buffer-name (session)
  "Return the name of the plan buffer of SESSION."
  (format "*ecc-plan: %s*" (ecc-session-name session)))

(defun ecc-plan-buffer (request)
  "Return the live buffer reviewing REQUEST, or nil."
  (let ((buffer (get-buffer (ecc-plan-buffer-name (ecc-request-session request)))))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer (eq ecc-plan--request request))
         buffer)))

(defun ecc-plan-text (request)
  "Return the plan text carried by REQUEST."
  (or (alist-get 'plan (ecc-request-input request)) ""))

(defun ecc-plan-file-path (request)
  "Return the file the CLI wrote the plan of REQUEST to, or nil.
The ExitPlanMode input carries it as `planFilePath'; a CLI that names
none gives nil."
  (let ((path (alist-get 'planFilePath (ecc-request-input request))))
    (and (stringp path) (not (string-empty-p path)) path)))

(defun ecc-plan-open (request)
  "Return the buffer reviewing REQUEST, creating it if needed."
  (or (ecc-plan-buffer request)
      (let* ((session (ecc-request-session request))
             (buffer (get-buffer-create (ecc-plan-buffer-name session)))
             (plan (ecc-plan-text request))
             (previous (ecc-session-last-plan session)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (ecc-plan-mode)
            (setq ecc-render--session session)
            (erase-buffer)
            (insert plan)
            (setq ecc-plan--request request
                  ecc-plan--original plan
                  ecc-plan--comments nil
                  ecc-plan--mode nil
                  ecc-plan--changes (and previous (ecc-plan--mark-changes previous plan)))
            (set-buffer-modified-p nil)
            (goto-char (point-min))))
        (setf (ecc-session-last-plan session) plan)
        buffer)))

(defun ecc-plan--header-line ()
  "Return the header line of the plan buffer."
  (ecc--mode-line-escape
   (concat
   (propertize (format " Plan review: %s"
                       (if ecc-plan--request
                           (ecc-session-name (ecc-request-session ecc-plan--request))
                         "?"))
               'face 'ecc-heading-face)
   (propertize (format "  ·  next mode: %s  ·  comments: %d%s"
                       (or ecc-plan--mode ecc-plan-default-mode "(CLI default)")
                       (length ecc-plan--comments)
                       (if ecc-plan--changes
                           (format "  ·  vs previous: +%d −%d"
                                   (car ecc-plan--changes) (cdr ecc-plan--changes))
                         ""))
               'face 'ecc-dim-face)
   ;; The keys `ecc-plan-mode-map' really binds.  This named two that
   ;; are not bound at all (fixed 2026-09-11).
   (propertize "  ·  C-c C-c approve  C-c C-k deny  C-c C-a comment  C-c C-p mode"
               'face 'ecc-dim-face))))

;;;; What changed since the last plan

(defun ecc-plan--mark-changes (previous current)
  "Mark in the current buffer the lines of CURRENT that are new since PREVIOUS.
Returns (ADDED . REMOVED)."
  (let ((lines (ecc-diff-lines previous current))
        (line 1)
        (added 0)
        (removed 0))
    (dolist (entry lines)
      (pcase (car entry)
        ('removed (cl-incf removed))
        (tag
         (when (eq tag 'added)
           (cl-incf added)
           (save-excursion
             (goto-char (point-min))
             (forward-line (1- line))
             (let ((overlay (make-overlay (line-beginning-position)
                                          (line-beginning-position 2))))
               (overlay-put overlay 'ecc-plan-changed t)
               (overlay-put overlay 'line-prefix
                            (propertize "▎" 'face 'ecc-plan-changed-face))
               (overlay-put overlay 'wrap-prefix
                            (propertize "▎" 'face 'ecc-plan-changed-face)))))
         (cl-incf line))))
    (cons added removed)))

(defun ecc-plan-changed-lines ()
  "Return the line numbers marked as changed since the previous plan."
  (sort (mapcar (lambda (overlay) (line-number-at-pos (overlay-start overlay)))
                (seq-filter (lambda (overlay) (overlay-get overlay 'ecc-plan-changed))
                            (overlays-in (point-min) (point-max))))
        #'<))

(defun ecc-plan-next-change ()
  "Move to the next line that changed since the previous plan."
  (interactive)
  (let ((here (line-number-at-pos))
        (lines (ecc-plan-changed-lines)))
    (if-let* ((next (seq-find (lambda (line) (> line here)) lines)))
        (progn (goto-char (point-min)) (forward-line (1- next)))
      (user-error (if lines "No further change" "This plan was not shown before")))))

;;;; Line comments

(defun ecc-plan-comment-at-point ()
  "Return the comment overlay on the current line, or nil."
  (seq-find (lambda (overlay) (overlay-get overlay 'ecc-plan-comment))
            (overlays-in (line-beginning-position) (line-end-position))))

(defun ecc-plan-comment (text)
  "Attach the comment TEXT to the current line.
The line is underlined and the comment shown after it."
  (interactive (list (read-string "Comment on this line: "
                                  (when-let* ((overlay (ecc-plan-comment-at-point)))
                                    (overlay-get overlay 'ecc-plan-comment)))))
  (when (string-empty-p (string-trim text))
    (user-error "Empty comment"))
  (when-let* ((old (ecc-plan-comment-at-point)))
    (ecc-plan--delete-comment old))
  (let ((overlay (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put overlay 'ecc-plan-comment (string-trim text))
    (overlay-put overlay 'face 'ecc-plan-commented-line-face)
    (overlay-put overlay 'after-string
                 (propertize (format "  ; %s" (string-trim text))
                             'face 'ecc-plan-comment-face))
    (push overlay ecc-plan--comments)
    (force-mode-line-update)
    overlay))

(defun ecc-plan--delete-comment (overlay)
  "Remove the comment OVERLAY."
  (setq ecc-plan--comments (delq overlay ecc-plan--comments))
  (delete-overlay overlay))

(defun ecc-plan-remove-comment ()
  "Remove the comment attached to the current line."
  (interactive)
  (let ((overlay (or (ecc-plan-comment-at-point)
                     (user-error "No comment on this line"))))
    (ecc-plan--delete-comment overlay)
    (force-mode-line-update)))

(defun ecc-plan-comments ()
  "Return the comments of this buffer as (LINE CONTEXT TEXT), by line."
  (sort (mapcar (lambda (overlay)
                  (save-excursion
                    (goto-char (overlay-start overlay))
                    (list (line-number-at-pos)
                          (string-trim (buffer-substring-no-properties
                                        (line-beginning-position) (line-end-position)))
                          (overlay-get overlay 'ecc-plan-comment))))
                (seq-filter #'overlay-buffer ecc-plan--comments))
        (lambda (a b) (< (car a) (car b)))))

;;;; Feedback

(defun ecc-plan-markers (text)
  "Return the @claude markers in TEXT as a list of (CONTEXT . MARKER).
CONTEXT is the last non-empty line before the marker, or nil at the top."
  (let ((markers nil)
        (context nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match ecc-plan-marker-regexp line)
        (push (cons context (string-trim (match-string 1 line))) markers))
       ((not (string-empty-p (string-trim line)))
        (setq context (string-trim line)))))
    (nreverse markers)))

(defun ecc-plan-strip-markers (text)
  "Return TEXT without its @claude marker lines."
  (string-join (seq-remove (lambda (line) (string-match-p ecc-plan-marker-regexp line))
                           (split-string text "\n"))
               "\n"))

(defun ecc-plan-diff-text (original current)
  "Return the unified diff of ORIGINAL against CURRENT as plain text, or nil."
  (when-let* ((diff (ecc-diff-render original current)))
    (substring-no-properties diff)))

(defun ecc-plan--quote (string)
  "Return STRING shortened and quoted for a feedback line."
  (format "\"%s\"" (ecc--truncate string 60)))

(defun ecc-plan-feedback (original current comments &optional general)
  "Return the feedback message for the plan, or nil when there is none.
ORIGINAL is the plan as sent, CURRENT the text of the buffer, COMMENTS
the list `ecc-plan-comments' returns and GENERAL a free comment.  The
message has the sections of emacs-gravity: inline comments, @claude
markers, the diff of the edits, and the general comment."
  (let* ((markers (ecc-plan-markers current))
         (diff (ecc-plan-diff-text original (ecc-plan-strip-markers current)))
         (general (and general (not (string-empty-p (string-trim general)))
                       (string-trim general)))
         (sections nil))
    (when comments
      (push (concat "## Inline comments:\n"
                    (mapconcat (lambda (comment)
                                 (format "- Line %d (near %s): %s"
                                         (nth 0 comment)
                                         (ecc-plan--quote (nth 1 comment))
                                         (ecc-plan--quote (nth 2 comment))))
                               comments "\n"))
            sections))
    (when markers
      (push (concat "## @claude markers:\n"
                    (mapconcat (lambda (marker)
                                 (format "- %s%s"
                                         (if (car marker)
                                             (format "(after %s) " (ecc-plan--quote (car marker)))
                                           "")
                                         (cdr marker)))
                               markers "\n"))
            sections))
    (when diff
      (push (concat "## Changes requested:\n```diff\n"
                    (string-trim-right diff "\n")
                    "\n```")
            sections))
    (when general
      (push (concat "## General comment:\n" general) sections))
    (when sections
      (concat "# Plan Feedback\n\n"
              (string-join (nreverse sections) "\n\n")
              "\n\n" ecc-plan-feedback-footer))))

(defun ecc-plan-buffer-feedback (&optional general)
  "Return the feedback of the current plan buffer, with GENERAL, or nil."
  (ecc-plan-feedback ecc-plan--original
                     (buffer-substring-no-properties (point-min) (point-max))
                     (ecc-plan-comments)
                     general))

;;;; Approving and denying

(defun ecc-plan--updated-permissions (mode)
  "Return the updatedPermissions vector switching to MODE, or nil."
  (when (and mode (not (string-empty-p mode)))
    (vector (ecc-protocol-set-mode-suggestion mode))))

(defun ecc-plan--read-mode ()
  "Ask for the permission mode to switch to."
  (let ((choice (completing-read "Permission mode after approval: "
                                 (append ecc-plan-modes '("(CLI default)"))
                                 nil t nil nil
                                 (or ecc-plan--mode ecc-plan-default-mode))))
    (and (not (equal choice "(CLI default)")) choice)))

(defun ecc-plan-set-mode (mode)
  "Choose MODE as the permission mode to switch to on approval."
  (interactive (list (ecc-plan--read-mode)))
  (setq ecc-plan--mode mode)
  (force-mode-line-update)
  (message "Permission mode on approval: %s" (or mode "(CLI default)")))

(defun ecc-plan-approve-request (request &optional mode)
  "Allow REQUEST as it stands, switching to permission MODE.
MODE defaults to `ecc-plan-default-mode'.  Used when the plan is
approved without opening the review buffer."
  (let ((mode (or mode ecc-plan-default-mode)))
    (ecc-perm-respond request 'allow
                      :updated-permissions (ecc-plan--updated-permissions mode)
                      :message (if mode (format "approved → %s" mode) "approved"))))

(defun ecc-plan--finish (buffer)
  "Take BUFFER off the screen once its request was answered."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (ecc-perm-close-buffer buffer)))

(defun ecc-plan-approve (&optional mode)
  "Approve the plan, or send the feedback found in the buffer.
A line comment, an @claude marker or an edit turns the approval into a
deny carrying the structured feedback; with none of them the request is
allowed and the CLI is asked to switch to MODE.  MODE defaults to what
`ecc-plan-set-mode' chose, then to `ecc-plan-default-mode'; a prefix
argument asks for it."
  (interactive (list (and current-prefix-arg (ecc-plan--read-mode))))
  (let* ((request (or ecc-plan--request (user-error "Not a plan buffer")))
         (session (ecc-request-session request))
         (buffer (current-buffer))
         (mode (or mode ecc-plan--mode ecc-plan-default-mode))
         (feedback (ecc-plan-buffer-feedback))
         (summary (format "Sent back for revision (%d comments, %d markers%s)"
                          (length (ecc-plan-comments))
                          (length (ecc-plan-markers (buffer-string)))
                          (if (ecc-plan-diff-text ecc-plan--original
                                                  (ecc-plan-strip-markers (buffer-string)))
                              ", body edited" ""))))
    (unless (memq request (ecc-session-pending session))
      (user-error "This plan was answered already"))
    (if feedback
        (progn
          (ecc-perm-respond request 'deny :message feedback)
          (message "%s" summary))
      (ecc-plan-approve-request request mode)
      (message "Plan approved%s" (if mode (format " (permission mode → %s)" mode) "")))
    (ecc-plan--finish buffer)
    feedback))

(defun ecc-plan-deny (reason)
  "Deny the plan with REASON as the general comment.
Inline comments, markers and edits present in the buffer are sent
along with it."
  (interactive (list (read-string "Revision request (comment on the whole plan): ")))
  (let* ((request (or ecc-plan--request (user-error "Not a plan buffer")))
         (session (ecc-request-session request))
         (buffer (current-buffer))
         (feedback (or (ecc-plan-buffer-feedback reason)
                       (ecc-plan-feedback "" "" nil "The user rejected this plan."))))
    (unless (memq request (ecc-session-pending session))
      (user-error "This plan was answered already"))
    (ecc-perm-respond request 'deny :message feedback)
    (message "Plan sent back")
    (ecc-plan--finish buffer)
    feedback))

(defun ecc-plan-show-diff ()
  "Show what was edited in the plan so far, against the original."
  (interactive)
  (let ((diff (ecc-plan-diff-text ecc-plan--original
                                  (ecc-plan-strip-markers (buffer-string))))
        (buffer (get-buffer-create "*ecc-plan-diff*")))
    (unless diff
      (user-error "The plan has not been edited"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff)
        (diff-mode)
        (setq buffer-read-only t)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

;;;; Wiring

(defun ecc-plan--on-request-added (session request)
  "Open the review buffer for REQUEST of SESSION when it is a plan."
  (when (and ecc-plan-auto-open
             (eq (ecc-request-kind request) 'plan)
             (get-buffer-window (ecc-session-buffer session) t))
    (ecc-window-display-review (ecc-plan-open request) session)))

(defun ecc-plan--on-request-resolved (_session request)
  "Close the review buffer of REQUEST, which was answered somewhere else."
  (when-let* ((buffer (ecc-plan-buffer request)))
    ;; The buffer that is answering closes itself once it is done.
    (unless (eq buffer (current-buffer))
      (ecc-plan--finish buffer))))

(add-hook 'ecc-request-added-hook #'ecc-plan--on-request-added)
(add-hook 'ecc-request-resolved-hook #'ecc-plan--on-request-resolved)

(provide 'ecc-plan)

;;; ecc-plan.el ends here
