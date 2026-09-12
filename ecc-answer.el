;;; ecc-answer.el --- Answer a waiting request from anywhere  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes

;;; Commentary:

;; A session stops as soon as it needs a word from the user: a
;; permission to run a tool, a plan to review, a question to pick an
;; answer to.  With several sessions running, finding which one stopped
;; is the work this module takes away.
;;
;; Two ways of reaching a request without hunting for its session: the
;; commands that jump to the next one, and the commands that answer the
;; oldest one from wherever the user is.  A mode line indicator says how
;; many are waiting, and the dashboard is where they are seen as a list.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-window)

(declare-function ecc-plan-open "ecc-plan" (request))
;; Autoloaded commands of modules that require this one; the keymap only
;; names them.
(declare-function ecc-dashboard "ecc-dashboard" ())
(declare-function ecc-history-open "ecc-history" (session-id))
(declare-function ecc-interrupt "ecc-transient" ())
(declare-function ecc-menu "ecc-transient" ())
(declare-function ecc-resume-menu "ecc-transient" ())
(declare-function ecc-review "ecc-review" (&optional session paths))
(declare-function ecc-search "ecc-search" (query &optional everywhere))
(declare-function ecc-show-session "ecc-transient" ())
(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-tui-open "ecc-tui" (&optional session))
(declare-function ecc-usage "ecc-usage" ())

(defvar ecc-answer-confirm t
  "Non-nil asks before a request is answered from another buffer.")

(defvar ecc-answer-exclude-tools '("Bash")
  "Tools that `ecc-answer-allow' and friends never answer.
A request for one of them has to be answered where it can be read.")

;;;; Describing a request

(defun ecc-answer-summary (request)
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

(defun ecc-answer-goto-request (request)
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

;;;; Going round the requests

(defun ecc-answer-current-request ()
  "Return the request the current buffer is about, or nil."
  (or (bound-and-true-p ecc-question--request)
      (bound-and-true-p ecc-plan--request)
      (ecc-perm-request-at-point)))

;;;###autoload
(defun ecc-next-attention (&optional project-root)
  "Jump to the next request waiting for an answer, across sessions.
With PROJECT-ROOT, only the sessions of that project are visited.
The order is the arrival order and it wraps around."
  (interactive)
  (let* ((requests (ecc-model-pending-all project-root))
         (current (ecc-answer-current-request))
         (position (and current (seq-position requests current #'eq)))
         (next (cond ((null requests) nil)
                     ((null position) (car requests))
                     (t (nth (mod (1+ position) (length requests)) requests)))))
    (if (null next)
        (message "Nothing needs attention")
      (ecc-answer-goto-request next)
      (message "%d/%d: %s — %s"
               (1+ (seq-position requests next #'eq)) (length requests)
               (ecc-session-name (ecc-request-session next))
               (ecc-answer-summary next)))
    next))

;;;###autoload
(defun ecc-next-attention-in-project ()
  "Jump to the next request waiting in a session of the current project."
  (interactive)
  (ecc-next-attention (ecc-window-project-root)))

;;;; Answering from anywhere

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
                        (ecc-answer-summary request)))))

;;;###autoload
(defun ecc-answer-allow ()
  "Allow the oldest waiting permission request, from any buffer."
  (interactive)
  (let ((request (or (ecc-answer-target 'permission)
                     (user-error "No permission request is waiting"))))
    (when (ecc-answer--confirm "Allow" request)
      (ecc-perm-allow-request request)
      (message "Allowed: %s" (ecc-answer-summary request))
      request)))

;;;###autoload
(defun ecc-answer-deny (reason)
  "Deny the oldest waiting request with REASON, from any buffer."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (let ((request (or (ecc-answer-target)
                     (user-error "No request is waiting"))))
    (when (ecc-answer--confirm "Deny" request)
      (ecc-perm-respond request 'deny :message reason)
      (message "Denied: %s" (ecc-answer-summary request))
      request)))

(defun ecc-answer-option (n)
  "Answer the oldest waiting question with its option N.
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

;; The symbol carries the keymap in its function cell as well as its value,
;; so that it is a prefix command and not only a variable.  A prefix command
;; is what `C-h', `which-key' and the rest read a prefix key through: bound to
;; the value, `C-c c' is a complete key sequence running a command, and
;; nothing offers to list what follows it.  The autoload form below is the
;; keymap kind, so the binding works before this file is loaded and loads it
;; when the key -- or the listing of that key -- asks for what is inside.
;;;###autoload (autoload 'ecc-global-map "ecc-answer" nil t 'keymap)
(defvar ecc-global-map
  (let ((map (make-sparse-keymap)))
    ;; The session.
    (define-key map (kbd "c") #'ecc-start)
    (define-key map (kbd "r") #'ecc-resume-menu)
    (define-key map (kbd "R") #'ecc-rename-session)
    (define-key map (kbd "v") #'ecc-show-session)
    (define-key map (kbd "j") #'ecc-focus-project)
    (define-key map (kbd "i") #'ecc-interrupt)
    (define-key map (kbd "t") #'ecc-tui-open)
    ;; Answering what is waiting.
    (define-key map (kbd "a") #'ecc-answer-allow)
    (define-key map (kbd "d") #'ecc-answer-deny)
    (define-key map (kbd "n") #'ecc-next-attention)
    (define-key map (kbd "N") #'ecc-next-attention-in-project)
    (define-key map (kbd "1") #'ecc-answer-option-1)
    (define-key map (kbd "2") #'ecc-answer-option-2)
    (define-key map (kbd "3") #'ecc-answer-option-3)
    (define-key map (kbd "4") #'ecc-answer-option-4)
    ;; Looking around.
    (define-key map (kbd "b") #'ecc-dashboard)
    (define-key map (kbd "D") #'ecc-review)
    (define-key map (kbd "h") #'ecc-history-open)
    (define-key map (kbd "/") #'ecc-search)
    (define-key map (kbd "U") #'ecc-usage)
    (define-key map (kbd "?") #'ecc-menu)
    map)
  "Keymap of the commands that work from any buffer.
What is here is the handful worth a key of its own, not everything the
package can do: `C-c c\=' is the user\='s own key, and a map of forty
commands leaves no room beside it and no listing anyone can read.  The
rest is reached through `ecc-menu\='.

Bind the symbol, not the value, to a prefix key:

    (global-set-key (kbd \"C-c c\") \='ecc-global-map)

which makes `ecc-global-map\=' a prefix command, so that
`describe-prefix-bindings\=' and `which-key\=' can say what follows it.
With an autoload form of the keymap kind -- generated from this file, or
written by hand where nothing generates one -- the binding can be made
before ecc is loaded.

Every key here means in `ecc-menu' what it means here, so that one letter
carries one meaning wherever it is pressed; `?' opens that menu, which is
the only way to reach it from a buffer that is not a session.")

(fset 'ecc-global-map ecc-global-map)

;;;; The mode line indicator

(defun ecc-pending-mode-line-string ()
  "Return the mode line text saying how many requests are waiting."
  (let ((n (length (ecc-model-pending-all))))
    (if (zerop n)
        ""
      (propertize (format " ⚠ecc:%d " n)
                  'face 'ecc-pending-face
                  'help-echo "Claude is waiting for an answer.  mouse-1: dashboard"
                  'mouse-face 'mode-line-highlight
                  'local-map (let ((map (make-sparse-keymap)))
                               (define-key map [mode-line mouse-1] #'ecc-dashboard)
                               map)))))

(defconst ecc-pending--mode-line-construct '(:eval (ecc-pending-mode-line-string))
  "What `ecc-pending-indicator-mode' adds to `global-mode-string'.")

(define-minor-mode ecc-pending-indicator-mode
  "Show in every mode line how many requests are waiting."
  :global t
  :group 'ecc
  (if ecc-pending-indicator-mode
      (unless (member ecc-pending--mode-line-construct global-mode-string)
        (setq global-mode-string
              (append (or global-mode-string '(""))
                      (list ecc-pending--mode-line-construct))))
    (setq global-mode-string
          (remove ecc-pending--mode-line-construct global-mode-string)))
  (force-mode-line-update t))

;;;; Wiring

(defun ecc-answer--on-change (&rest _)
  "Refresh the indicators after a request came or went."
  (force-mode-line-update t))

(add-hook 'ecc-request-added-hook #'ecc-answer--on-change)
(add-hook 'ecc-request-resolved-hook #'ecc-answer--on-change)

(provide 'ecc-answer)

;;; ecc-answer.el ends here
