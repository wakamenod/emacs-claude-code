;;; ecc-perm.el --- Answering can_use_tool requests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Everything that answers a can_use_tool request goes through
;; `ecc-perm-respond' (section 6.3 of IMPLEMENTATION_PLAN.md), so that
;; the queue, the transcript and the CLI never disagree about what was
;; answered.  Deny is the default answer everywhere (NFR-4).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)

(defcustom ecc-perm-default-deny-message "User denied this tool call."
  "Message sent to Claude when the user denies without giving a reason."
  :type 'string
  :group 'ecc)

(cl-defun ecc-perm-respond (request behavior &key message updated-input
                                    updated-permissions)
  "Answer REQUEST with BEHAVIOR, which is `allow' or `deny'.
MESSAGE is the reason shown to Claude when denying.  UPDATED-INPUT
replaces the tool input of an allow, and defaults to echoing back what
the CLI sent.  UPDATED-PERMISSIONS is a vector of permission updates."
  (let ((session (ecc-request-session request)))
    (ecc-proc-send-json
     session
     (pcase behavior
       ('allow (ecc-protocol-permission-allow
                (ecc-request-request-id request)
                :updated-input (or updated-input (ecc-request-input request))
                :updated-permissions updated-permissions))
       ('deny (ecc-protocol-permission-deny
               (ecc-request-request-id request)
               (if (and message (not (string-empty-p message)))
                   message
                 ecc-perm-default-deny-message)))
       (_ (error "Unknown behavior %S" behavior))))
    (when-let* ((node (ecc-request-node request)))
      (ecc-model-node-put node 'outcome behavior)
      (ecc-model-node-put node 'outcome-message message))
    (ecc-model-resolve-request session request
                               (if (eq behavior 'allow) 'done 'denied))
    request))

;;;; Finding the request a command is about

(defun ecc-perm-request-at-point ()
  "Return the request the point is on, or nil."
  (when-let* ((session ecc-render--session)
              (section (magit-current-section))
              (value (oref section value))
              (node (and (stringp value) (ecc-model-node session value))))
    (ecc-model-node-get node 'request)))

(defun ecc-perm-current-request ()
  "Return the request a command should act on.
The one at point wins, then the oldest one of this session, then the
oldest one of any session, so that a request can be answered from
wherever the user happens to be (FR-PERM-6)."
  (or (ecc-perm-request-at-point)
      (when-let* ((session ecc-render--session))
        (car (ecc-session-pending session)))
      (car (ecc-model-pending-all))
      (user-error "No request is waiting for an answer")))

;;;; Commands

(defun ecc-perm-allow ()
  "Allow the request at point, or the oldest one waiting (FR-PERM-1)."
  (interactive)
  (let ((request (ecc-perm-current-request)))
    (if (eq (ecc-request-kind request) 'question)
        (ecc-perm-respond request 'allow
                          :updated-input (ecc-perm--answer-questions request))
      (ecc-perm-respond request 'allow))
    (message "許可しました: %s" (ecc-request-tool-name request))))

(defun ecc-perm-deny (&optional reason)
  "Deny the request at point with REASON, asking for one (FR-PERM-2)."
  (interactive (list (read-string "拒否の理由（空でも可）: ")))
  (let ((request (ecc-perm-current-request)))
    (ecc-perm-respond request 'deny :message reason)
    (message "拒否しました: %s" (ecc-request-tool-name request))))

;;;; AskUserQuestion (FR-PERM-5, minimal: one prompt per question)

(defun ecc-perm-question-options (question)
  "Return the option labels of QUESTION as a list of strings."
  (mapcar (lambda (option) (alist-get 'label option))
          (append (or (alist-get 'options question) []) nil)))

(defun ecc-perm--answer-questions (request)
  "Ask the questions of REQUEST and return the input to send back.
The questions are echoed unchanged; only `answers' is added, keyed by
the question text, with a multiSelect answer joined by \", \"."
  (let ((input (ecc-request-input request))
        (pairs nil))
    (seq-doseq (question (or (alist-get 'questions (ecc-request-input request)) []))
      (let* ((text (alist-get 'question question))
             (options (ecc-perm-question-options question))
             (multi (eq (alist-get 'multiSelect question) t))
             (answer (if multi
                         (string-join
                          (completing-read-multiple (format "%s " text) options)
                          ", ")
                       (completing-read (format "%s " text) options nil nil))))
        (push (cons text answer) pairs)))
    (append input (list (cons 'answers (ecc-protocol-answers (nreverse pairs)))))))

(provide 'ecc-perm)

;;; ecc-perm.el ends here
