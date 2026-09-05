;;; ecc-inbox.el --- Every request waiting for an answer, in one place  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Three ways to reach a request without hunting for its session
;; (section 6.6 of IMPLEMENTATION_PLAN.md): the Inbox buffer that lists
;; the requests of every session (FR-INBOX-1), the commands that jump to
;; the next one (FR-INBOX-2), and the commands that answer the oldest
;; one from wherever the user is (FR-INBOX-3).  A mode line indicator
;; shows how many are waiting (FR-PERM-4).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-window)

(declare-function ecc-plan-open "ecc-plan" (request))
;; Both are autoloaded commands of modules that require this one; the
;; keymap only names them (plan section 1.3).
(declare-function ecc-dashboard "ecc-dashboard" ())
(declare-function ecc-history-open "ecc-history" (session-id))

(defcustom ecc-answer-confirm t
  "Non-nil asks before a request is answered from another buffer."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-answer-exclude-tools '("Bash")
  "Tools that `ecc-answer-allow' and friends never answer.
A request for one of them has to be answered where it can be read."
  :type '(repeat string)
  :group 'ecc)

;;;; Describing a request

(defun ecc-inbox-kind-label (request)
  "Return the kind of REQUEST as a short label."
  (pcase (ecc-request-kind request)
    ('question "question")
    ('plan "plan")
    (_ "permission")))

(defun ecc-inbox-summary (request)
  "Return the one line summary of REQUEST."
  (pcase (ecc-request-kind request)
    ('question
     (ecc-render--one-line
      (mapconcat (lambda (question) (or (alist-get 'question question) ""))
                 (ecc-question-questions request) " / ")))
    ('plan
     (ecc-render--one-line
      (ecc--truncate (or (alist-get 'plan (ecc-request-input request)) "") 80)))
    (_ (ecc-render--one-line
        (concat (ecc-request-tool-name request) "  "
                (ecc-render-tool-summary (ecc-request-tool-name request)
                                         (ecc-request-input request)))))))

(defun ecc-inbox-age-string (seconds)
  "Return SECONDS as a short age such as 12s, 3m or 2h."
  (cond ((< seconds 60) (format "%ds" (round seconds)))
        ((< seconds 3600) (format "%dm" (floor seconds 60)))
        (t (format "%dh" (floor seconds 3600)))))

;;;; The Inbox buffer (FR-INBOX-1)

(defconst ecc-inbox-buffer-name "*ecc-inbox*"
  "Name of the Inbox buffer.")

(defvar ecc-inbox-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-inbox-visit)
    (define-key map (kbd "a") #'ecc-inbox-allow)
    (define-key map (kbd "d") #'ecc-inbox-deny)
    (define-key map (kbd "g") #'ecc-inbox-refresh)
    map)
  "Keymap of `ecc-inbox-mode'.")

(define-derived-mode ecc-inbox-mode tabulated-list-mode "Claude-Inbox"
  "Major mode listing the requests of every session that wait for an answer.

\\{ecc-inbox-mode-map}"
  :interactive nil
  (setq tabulated-list-format [("経過" 6 t) ("セッション" 16 t) ("種別" 10 t)
                               ("要約" 0 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'ecc-inbox--collect nil t)
  (tabulated-list-init-header))

(defun ecc-inbox-entries ()
  "Return the `tabulated-list-entries' of every waiting request, oldest first."
  (mapcar (lambda (request)
            (list request
                  (vector (ecc-inbox-age-string (ecc-model-request-age request))
                          (ecc-session-name (ecc-request-session request))
                          (ecc-inbox-kind-label request)
                          (ecc-inbox-summary request))))
          (ecc-model-pending-all)))

(defun ecc-inbox--collect ()
  "Fill `tabulated-list-entries' for the Inbox."
  (setq tabulated-list-entries (ecc-inbox-entries)))

(defun ecc-inbox ()
  "Show every request waiting for an answer, across sessions (FR-INBOX-1)."
  (interactive)
  (let ((buffer (get-buffer-create ecc-inbox-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-inbox-mode)
        (ecc-inbox-mode))
      (ecc-inbox--collect)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-inbox-refresh ()
  "Draw the Inbox again."
  (interactive)
  (when-let* ((buffer (get-buffer ecc-inbox-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ecc-inbox--collect)
        (tabulated-list-print t)))))

(defun ecc-inbox-request-at-point ()
  "Return the request of the Inbox row at point, or signal an error."
  (let ((request (tabulated-list-get-id)))
    (unless (ecc-request-p request)
      (user-error "No request on this line"))
    (unless (memq request (ecc-session-pending (ecc-request-session request)))
      (user-error "This request was answered already"))
    request))

(defun ecc-inbox-goto-request (request)
  "Show where REQUEST is answered: its section, question or plan buffer."
  (pcase (ecc-request-kind request)
    ('question (pop-to-buffer (ecc-question-open request)))
    ('plan (require 'ecc-plan) (pop-to-buffer (ecc-plan-open request)))
    (_ (let* ((session (ecc-request-session request))
              (window (ecc-display-session session)))
         (when (window-live-p window)
           (select-window window))
         (when-let* ((node (ecc-request-node request)))
           (ecc-render-goto-node session node))))))

(defun ecc-inbox-visit ()
  "Go to the request at point (FR-INBOX-1)."
  (interactive)
  (ecc-inbox-goto-request (ecc-inbox-request-at-point)))

(defun ecc-inbox-allow ()
  "Allow the request at point."
  (interactive)
  (let ((request (ecc-inbox-request-at-point)))
    (ecc-perm-allow-request request)
    (ecc-inbox-refresh)))

(defun ecc-inbox-deny (reason)
  "Deny the request at point with REASON."
  (interactive (list (read-string "拒否の理由（空でも可）: ")))
  (let ((request (ecc-inbox-request-at-point)))
    (ecc-perm-respond request 'deny :message reason)
    (ecc-inbox-refresh)))

;;;; Going round the requests (FR-INBOX-2)

(defun ecc-inbox-current-request ()
  "Return the request the current buffer is about, or nil."
  (or (bound-and-true-p ecc-question--request)
      (bound-and-true-p ecc-plan--request)
      (and (derived-mode-p 'ecc-inbox-mode) (tabulated-list-get-id))
      (ecc-perm-request-at-point)))

(defun ecc-next-attention (&optional project-root)
  "Jump to the next request waiting for an answer, across sessions.
With PROJECT-ROOT, only the sessions of that project are visited.
The order is the arrival order and it wraps around."
  (interactive)
  (let* ((requests (ecc-model-pending-all project-root))
         (current (ecc-inbox-current-request))
         (position (and current (seq-position requests current #'eq)))
         (next (cond ((null requests) nil)
                     ((null position) (car requests))
                     (t (nth (mod (1+ position) (length requests)) requests)))))
    (if (null next)
        (message "要対応はありません")
      (ecc-inbox-goto-request next)
      (message "%d/%d: %s — %s"
               (1+ (seq-position requests next #'eq)) (length requests)
               (ecc-session-name (ecc-request-session next))
               (ecc-inbox-summary next)))
    next))

(defun ecc-next-attention-in-project ()
  "Jump to the next request waiting in a session of the current project."
  (interactive)
  (ecc-next-attention (ecc-window-project-root)))

;;;; Answering from anywhere (FR-INBOX-3)

(defun ecc-answer-target (&optional kind)
  "Return the oldest waiting request that may be answered blind, or nil.
KIND limits the search to that kind of request.  Tools listed in
`ecc-answer-exclude-tools' are skipped."
  (seq-find (lambda (request)
              (and (or (null kind) (eq (ecc-request-kind request) kind))
                   (not (member (ecc-request-tool-name request)
                                ecc-answer-exclude-tools))))
            (ecc-model-pending-all)))

(defun ecc-answer--confirm (verb request)
  "Return non-nil when REQUEST may be answered with VERB.
The tool and its summary are shown first, so that the user knows what
is being answered from afar."
  (or (not ecc-answer-confirm)
      (y-or-n-p (format "%s %s: %s? " verb
                        (ecc-session-name (ecc-request-session request))
                        (ecc-inbox-summary request)))))

(defun ecc-answer-allow ()
  "Allow the oldest waiting permission request, from any buffer (FR-INBOX-3)."
  (interactive)
  (let ((request (or (ecc-answer-target 'permission)
                     (user-error "No permission request is waiting"))))
    (when (ecc-answer--confirm "Allow" request)
      (ecc-perm-allow-request request)
      (message "許可しました: %s" (ecc-inbox-summary request))
      request)))

(defun ecc-answer-deny (reason)
  "Deny the oldest waiting request with REASON, from any buffer (FR-INBOX-3)."
  (interactive (list (read-string "拒否の理由（空でも可）: ")))
  (let ((request (or (ecc-answer-target)
                     (user-error "No request is waiting"))))
    (when (ecc-answer--confirm "Deny" request)
      (ecc-perm-respond request 'deny :message reason)
      (message "拒否しました: %s" (ecc-inbox-summary request))
      request)))

(defun ecc-answer-option (n)
  "Answer the oldest waiting question with its option N (FR-INBOX-3).
A question with a single item is sent at once; with several, the
question buffer opens with the first one answered."
  (interactive "p")
  (let* ((request (or (ecc-answer-target 'question)
                      (user-error "No question is waiting")))
         (buffer (ecc-question-open request)))
    (with-current-buffer buffer
      (goto-char (point-min))
      (ecc-question-choose n)
      (if (seq-every-p #'identity ecc-question--answers)
          (when (ecc-answer--confirm
                 (format "Answer %s to" (string-join (aref ecc-question--answers 0) ", "))
                 request)
            (ecc-question-submit))
        (pop-to-buffer buffer)))
    request))

(defun ecc-answer-option-1 () "Answer the oldest question with option 1." (interactive) (ecc-answer-option 1))
(defun ecc-answer-option-2 () "Answer the oldest question with option 2." (interactive) (ecc-answer-option 2))
(defun ecc-answer-option-3 () "Answer the oldest question with option 3." (interactive) (ecc-answer-option 3))
(defun ecc-answer-option-4 () "Answer the oldest question with option 4." (interactive) (ecc-answer-option 4))

(defvar ecc-global-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'ecc-answer-allow)
    (define-key map (kbd "d") #'ecc-answer-deny)
    (define-key map (kbd "n") #'ecc-next-attention)
    (define-key map (kbd "N") #'ecc-next-attention-in-project)
    (define-key map (kbd "i") #'ecc-inbox)
    (define-key map (kbd "D") #'ecc-dashboard)
    (define-key map (kbd "h") #'ecc-history-open)
    (define-key map (kbd "1") #'ecc-answer-option-1)
    (define-key map (kbd "2") #'ecc-answer-option-2)
    (define-key map (kbd "3") #'ecc-answer-option-3)
    (define-key map (kbd "4") #'ecc-answer-option-4)
    map)
  "Keymap of the commands that work from any buffer.
Bind it to a prefix, for instance (global-set-key (kbd \"C-c c\") ecc-global-map).")

;;;; The mode line indicator (FR-PERM-4)

(defun ecc-inbox-mode-line-string ()
  "Return the mode line text saying how many requests are waiting."
  (let ((n (length (ecc-model-pending-all))))
    (if (zerop n)
        ""
      (propertize (format " ⚠ecc:%d " n)
                  'face 'ecc-pending-face
                  'help-echo "Claude is waiting for an answer.  mouse-1: Inbox"
                  'mouse-face 'mode-line-highlight
                  'local-map (let ((map (make-sparse-keymap)))
                               (define-key map [mode-line mouse-1] #'ecc-inbox)
                               map)))))

(defconst ecc-inbox--mode-line-construct '(:eval (ecc-inbox-mode-line-string))
  "What `ecc-inbox-indicator-mode' adds to `global-mode-string'.")

(define-minor-mode ecc-inbox-indicator-mode
  "Show in every mode line how many requests are waiting (FR-PERM-4)."
  :global t
  :group 'ecc
  (if ecc-inbox-indicator-mode
      (unless (member ecc-inbox--mode-line-construct global-mode-string)
        (setq global-mode-string
              (append (or global-mode-string '(""))
                      (list ecc-inbox--mode-line-construct))))
    (setq global-mode-string
          (remove ecc-inbox--mode-line-construct global-mode-string)))
  (force-mode-line-update t))

;;;; Wiring

(defun ecc-inbox--on-change (&rest _)
  "Redraw the Inbox and the indicators after a request came or went."
  (ecc-inbox-refresh)
  (force-mode-line-update t))

(add-hook 'ecc-request-added-hook #'ecc-inbox--on-change)
(add-hook 'ecc-request-resolved-hook #'ecc-inbox--on-change)

(provide 'ecc-inbox)

;;; ecc-inbox.el ends here
