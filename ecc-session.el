;;; ecc-session.el --- Session buffer and keys for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

;;; Commentary:

;; The buffer a conversation is read in: `ecc-session-mode', its keys and
;; the commands that move around a transcript.  Section 6.1 of
;; IMPLEMENTATION_PLAN.md.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)

(declare-function ecc-prompt-pop-to-buffer "ecc-prompt" (session))
(declare-function ecc-resume "ecc" (session &optional fork))
(declare-function ecc-perm-allow "ecc-perm" ())
(declare-function ecc-perm-deny "ecc-perm" (&optional reason))

(defvar ecc-session-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'ecc-session-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "i") #'ecc-session-goto-prompt)
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "R") #'ecc-session-resume)
    (define-key map (kbd "L") #'ecc-session-show-log)
    (define-key map (kbd "a") #'ecc-perm-allow)
    (define-key map (kbd "d") #'ecc-perm-deny)
    (define-key map (kbd "C-c C-k") #'ecc-session-interrupt)
    map)
  "Keymap of `ecc-session-mode'.")

(define-derived-mode ecc-session-mode magit-section-mode "Claude"
  "Major mode of a Claude Code transcript.

\\{ecc-session-mode-map}"
  :interactive nil
  ;; Faces are applied when text is inserted, so no font lock is wanted;
  ;; the parent mode already switches it off.  A visibility indicator
  ;; would add text of its own to a collapsed heading, which the
  ;; rendering tests compare (plan section 9, item 7).
  (when (boundp 'magit-section-visibility-indicators)
    (setq-local magit-section-visibility-indicators nil))
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'ecc-session--kill-process nil t))

(defun ecc-session--kill-process ()
  "Stop the CLI when the session buffer goes away (plan 9, item 10)."
  (when-let* ((session ecc-render--session))
    (ecc-proc-stop session)))

(defun ecc-session-buffer-name (name)
  "Return the name of the transcript buffer of the session called NAME."
  (format "*ecc: %s*" name))

(defun ecc-session-ensure-buffer (session)
  "Return the transcript buffer of SESSION, creating and drawing it if needed."
  (let ((buffer (ecc-session-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (ecc-session-buffer-name (ecc-session-name session))))
      (setf (ecc-session-buffer session) buffer)
      (with-current-buffer buffer
        (let ((default-directory (or (ecc-session-project-root session)
                                     default-directory)))
          (ecc-session-mode))
        (ecc-render-setup session buffer)))
    buffer))

(defun ecc-session-at-point ()
  "Return the session of the current buffer, or signal an error."
  (or ecc-render--session
      (user-error "This buffer does not belong to a Claude session")))

(defun ecc-session-node-at-point ()
  "Return the node the point is on, or nil."
  (when-let* ((session ecc-render--session)
              (section (magit-current-section))
              (value (oref section value)))
    (and (stringp value) (ecc-model-node session value))))

;;;; Commands

(defun ecc-session-refresh ()
  "Redraw the whole transcript (FR-OUT-10)."
  (interactive)
  (ecc-render-refresh (ecc-session-at-point)))

(defun ecc-session-goto-prompt ()
  "Switch to the prompt buffer of this session."
  (interactive)
  (require 'ecc-prompt)
  (ecc-prompt-pop-to-buffer (ecc-session-at-point)))

(defun ecc-session-interrupt ()
  "Interrupt the running turn (FR-SES-5)."
  (interactive)
  (let ((session (ecc-session-at-point)))
    (ecc-proc-interrupt session)
    (message "中断を要求しました")))

(defun ecc-session-resume ()
  "Start this session again with --resume (FR-SES-7)."
  (interactive)
  (require 'ecc)
  (ecc-resume (ecc-session-at-point)))

(defun ecc-session-show-log ()
  "Show the raw protocol log of this session (NFR-8)."
  (interactive)
  (pop-to-buffer (ecc--log-buffer (ecc-session-name (ecc-session-at-point)))))

(defun ecc-session-visit ()
  "Show everything about the thing at point in its own buffer (FR-OUT-1)."
  (interactive)
  (let ((node (ecc-session-node-at-point)))
    (unless node
      (user-error "Nothing to show here"))
    (ecc-session--show-node (ecc-session-at-point) node)))

(defun ecc-session--show-node (session node)
  "Show every detail of NODE of SESSION in a buffer."
  (let ((buffer (get-buffer-create
                 (format "*ecc-detail: %s*" (ecc-session-name session)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s  (%s)\n\n" (ecc-node-type node) (ecc-node-id node)))
        (pcase (ecc-node-type node)
          ((or 'tool 'agent)
           (insert (format "%s\n\n" (ecc-model-node-get node 'name)))
           (ecc-render--insert-input (ecc-model-node-get node 'input) "")
           (insert "\n")
           (insert (ecc-render--result-text (ecc-model-node-get node 'result))))
          (_ (insert (or (ecc-model-node-get node 'text)
                         (format "%S" (ecc-node-data node))))))
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buffer)))

(provide 'ecc-session)

;;; ecc-session.el ends here
