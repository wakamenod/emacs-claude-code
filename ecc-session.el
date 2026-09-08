;;; ecc-session.el --- Session buffer and its commands for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The buffer a conversation is read and written in, and the commands
;; that act on it: visiting what is at point, reviewing, and taking
;; things out of the transcript (FR-OUT-14).  Section 6.1 of
;; IMPLEMENTATION_PLAN.md as revised by docs/phase9-ui-redesign.md.  The
;; major mode, the keys and the movement live in `ecc-chat'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-markdown)
(require 'ecc-diff)

(declare-function ecc-resume "ecc" (session &optional fork))
(declare-function ecc-perm-deny "ecc-perm" (&optional reason))
(declare-function ecc-perm-allow-all "ecc-perm" (&optional remember))
(declare-function ecc-question-open "ecc-perm" (request))
(declare-function ecc-plan-open "ecc-plan" (request))
(declare-function ecc-review "ecc-review" (&optional session paths))
(declare-function ecc-perm-request-at-point "ecc-perm" ())
(declare-function ecc-window-forget-session "ecc-window" (session))
(declare-function ecc-image-cleanup-session "ecc-prompt" (session))

(defun ecc-session--forget-on-kill ()
  "Stop and forget the session when its buffer is killed.
Killing the buffer is taken as killing the session (plan 9, item 10):
the CLI is stopped, the session leaves the list, and its line buffer
goes with it, so that nothing lingers in the dashboard as an exited
session with no buffer.  An agent transcript shares the session but is
not its buffer, so killing it does nothing."
  (when-let* ((session ecc-render--session))
    (when (and (eq (current-buffer) (ecc-session-buffer session))
               ;; `ecc-kill' has forgotten the session already; the
               ;; buffers are all that is left to it.
               (eq (ecc-model-session (ecc-session-id session)) session))
      (ecc-proc-stop session)
      (ecc-model-remove-session session)
      (when (fboundp 'ecc-window-forget-session)
        (ecc-window-forget-session session))
      (when (fboundp 'ecc-image-cleanup-session)
        (ecc-image-cleanup-session session))
      (let ((buffer (ecc-session-stream-buffer session)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun ecc-session-buffer-name (name)
  "Return the name of the buffer of the session called NAME."
  (format "*ecc: %s*" name))

(defun ecc-session-ensure-buffer (session)
  "Return the buffer of SESSION, creating and drawing it if needed."
  (let ((buffer (ecc-session-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (ecc-session-buffer-name (ecc-session-name session))))
      (setf (ecc-session-buffer session) buffer)
      (with-current-buffer buffer
        ;; The buffer lives in the project, so that project commands and
        ;; `ecc-next-attention-in-project' see the right root.
        (setq default-directory (or (ecc-session-project-root session)
                                    default-directory))
        (ecc-chat-mode)
        (add-hook 'kill-buffer-hook #'ecc-session--forget-on-kill nil t)
        (ecc-render-setup session buffer)))
    buffer))

(defun ecc-session-at-point ()
  "Return the session of the current buffer, or signal an error."
  (or ecc-render--session
      (user-error "This buffer does not belong to a Claude session")))

;;;; Commands

(defun ecc-session-refresh ()
  "Redraw the whole transcript (FR-OUT-10)."
  (interactive)
  (ecc-render-refresh (ecc-session-at-point)))

(defun ecc-session-interrupt ()
  "Interrupt the running turn (FR-SES-5)."
  (interactive)
  (let ((session (ecc-session-at-point)))
    (ecc-proc-interrupt session)
    (message "Interrupt requested")))

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
  "Open the thing at point: a file, an agent transcript or a detail buffer.
A question or a plan that is still waiting opens the buffer it is
answered in (FR-PERM-5, FR-PLAN-1)."
  (interactive)
  (let* ((session (ecc-session-at-point))
         (node (ecc-chat-node-at-point))
         (path (ecc-chat-file-at-point))
         (request (and node (ecc-model-node-get node 'request)))
         (pending (and request (memq request (ecc-session-pending session)))))
    (cond
     (path (find-file-other-window path))
     ((null node) (user-error "Nothing to show here"))
     ((eq (ecc-node-type node) 'agent) (ecc-session-show-agent session node))
     ((and pending (eq (ecc-node-type node) 'question))
      (require 'ecc-perm)
      (pop-to-buffer (ecc-question-open request)))
     ((and pending (eq (ecc-node-type node) 'plan))
      (require 'ecc-plan)
      (pop-to-buffer (ecc-plan-open request)))
     (t (ecc-session--show-node session node)))))

(defun ecc-session-review ()
  "Open every change of this session as one diff to review (FR-DIFF-3)."
  (interactive)
  (require 'ecc-review)
  (ecc-review (ecc-session-at-point)))

(defun ecc-session-review-file ()
  "Open the diff of the file at point in the Files section (FR-OUT-12)."
  (interactive)
  (require 'ecc-review)
  (ecc-review (ecc-session-at-point)
              (list (or (ecc-chat-file-at-point)
                        (user-error "Not on a file")))))

(defun ecc-session-review-or-deny ()
  "Deny the request at point, or open the review when not on one.
The d key of the transcript does both (plan sections 6.3 and 6.5)."
  (interactive)
  (require 'ecc-perm)
  (if (ecc-perm-request-at-point)
      (call-interactively #'ecc-perm-deny)
    (ecc-session-review)))

(defun ecc-session-allow-all-remember ()
  "Allow every waiting request and stop asking about those tools (FR-PERM-9)."
  (interactive)
  (require 'ecc-perm)
  (ecc-perm-allow-all t))

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
           (ecc-session--insert-call (ecc-model-node-get node 'name)
                                     (ecc-model-node-get node 'input)
                                     (ecc-model-node-get node 'before))
           (insert "\n")
           (insert (ecc-render--result-text (ecc-model-node-get node 'result))))
          ((or 'permission 'question 'plan)
           (let ((request (ecc-model-node-get node 'request)))
             (insert (format "%s  %s\n\n"
                             (if request (ecc-request-tool-name request) "?")
                             (ecc-node-status node)))
             (when request
               (ecc-session--insert-call (ecc-request-tool-name request)
                                         (ecc-request-input request)
                                         (ecc-model-node-get node 'before)))))
          (_ (insert (or (ecc-model-node-get node 'text)
                         (format "%S" (ecc-node-data node))))))
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buffer)))

(defun ecc-session--insert-call (name input before)
  "Insert the whole INPUT of a call to NAME, as a diff when it has one.
BEFORE is the file as it was before the call, when known."
  (let ((diff (ecc-diff-for-tool name input before)))
    (if diff
        (progn
          (when-let* ((path (alist-get 'file_path input)))
            (insert (abbreviate-file-name path) "\n"))
          (insert diff))
      (ecc-render--insert-input input ""))))

(defun ecc-session-show-agent (session node)
  "Show the transcript of the agent NODE of SESSION in its own buffer (FR-OUT-9)."
  (let* ((input (ecc-model-node-get node 'input))
         (title (format "%s: %s"
                        (or (ecc-model-node-get node 'agent-type)
                            (alist-get 'subagent_type input)
                            "Agent")
                        (ecc--truncate (or (alist-get 'description input)
                                           (ecc-model-node-get node 'agent-description)
                                           (ecc-node-id node))
                                       60)))
         (buffer (get-buffer-create (format "*ecc-agent: %s: %s*"
                                            (ecc-session-name session) title))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-chat-mode)
        (ecc-chat-mode))
      (ecc-render-draw-nodes session buffer
                             (concat (ecc-render--agent-heading node 0) "\n"
                                     (if-let* ((prompt (alist-get 'prompt input)))
                                         (concat "\n" prompt "\n")
                                       ""))
                             (ecc-node-children node)))
    (pop-to-buffer buffer)))

;;;; Timeline (FR-OUT-14 d)

(defun ecc-session-timeline ()
  "Pick a turn by its prompt and move there (FR-OUT-14 d)."
  (interactive)
  (let* ((session (ecc-session-at-point))
         (turns (ecc-session-turns session))
         (n 0)
         (candidates (mapcar (lambda (turn)
                               (cons (format "%2d  %s" (cl-incf n)
                                             (ecc--truncate (or (ecc-turn-prompt turn)
                                                                (ecc-turn-label turn)
                                                                "(resumed)")
                                                            70))
                                     turn))
                             turns)))
    (unless candidates
      (user-error "No turn yet"))
    (let* ((choice (completing-read "Turn: " (mapcar #'car candidates) nil t))
           (turn (cdr (assoc choice candidates))))
      (unless (and turn (ecc-render-node-bounds (ecc-turn-id turn)))
        (user-error "That turn is not drawn"))
      (ecc-render-goto-id (ecc-turn-id turn)))))

;;;; Extraction (FR-OUT-14 e, f)

(defun ecc-session--code-block-around-point (id)
  "Return the fenced code block of the node ID that contains point, or nil.
The buffer text is used, so the indentation the renderer added is
stripped from every line."
  (let* ((bounds (ecc-render-node-bounds id))
         (start (car bounds))
         (end (cdr bounds))
         (fence (concat "^\\([ \t]*\\)" (substring ecc-markdown-fence-regexp 1))))
    (save-excursion
      (let ((here (line-beginning-position)))
        (goto-char here)
        (end-of-line)
        (when (re-search-backward fence start t)
          (let ((indent (match-string 1)))
            (forward-line 1)
            (let ((body-start (point)))
              (when (and (re-search-forward fence end t)
                         (>= (line-beginning-position) here))
                (let ((body (buffer-substring-no-properties
                             body-start (line-beginning-position))))
                  (replace-regexp-in-string
                   (concat "^" (regexp-quote indent)) "" body))))))))))

(defun ecc-session-copy-at-point ()
  "Copy the code block at point, or else the whole assistant reply (FR-OUT-14 e)."
  (interactive)
  (let* ((node (ecc-chat-node-at-point))
         (text (cond
                ((null node) nil)
                ((eq (ecc-node-type node) 'text)
                 (or (ecc-session--code-block-around-point (ecc-node-id node))
                     (ecc-model-node-get node 'text)))
                ((memq (ecc-node-type node) '(tool agent))
                 (ecc-render--result-text (ecc-model-node-get node 'result)))
                (t (ecc-model-node-get node 'text)))))
    (unless (and text (not (string-empty-p text)))
      (user-error "Nothing to copy here"))
    (kill-new text)
    (message "Copied %d characters" (length text))))

(defun ecc-session--markdown-node (node depth)
  "Return NODE as Markdown, indented by DEPTH list levels."
  (let ((pad (make-string (* 2 depth) ?\s)))
    (pcase (ecc-node-type node)
      ('text (concat (ecc-model-node-get node 'text) "\n\n"))
      ('thinking (let ((text (string-trim (or (ecc-model-node-get node 'text) ""))))
                   (if (string-empty-p text) ""
                     (concat "<details><summary>Thinking</summary>\n\n" text
                             "\n\n</details>\n\n"))))
      ('step (concat (mapconcat (lambda (child)
                                  (ecc-session--markdown-node child depth))
                                (ecc-node-children node) "")
                     "\n"))
      ('tool (format "%s- `%s` %s\n" pad
                     (ecc-model-node-get node 'name)
                     (ecc-render-tool-summary (ecc-model-node-get node 'name)
                                              (ecc-model-node-get node 'input))))
      ('agent (concat (format "%s- Agent `%s`\n" pad
                              (or (ecc-model-node-get node 'agent-type) "Agent"))
                      (mapconcat (lambda (child)
                                   (ecc-session--markdown-node child (1+ depth)))
                                 (ecc-node-children node) "")))
      ((or 'permission 'question 'plan)
       (let ((request (ecc-model-node-get node 'request)))
         (format "%s- %s: %s — %s\n\n" pad (ecc-node-type node)
                 (if request (ecc-request-tool-name request) "?")
                 (ecc-node-status node))))
      ('result (let ((result (ecc-model-node-get node 'result)))
                 (format "_%s · $%.4f_\n\n"
                         (or (alist-get 'stop_reason result) "?")
                         (or (alist-get 'total_cost_usd result) 0))))
      ('system (if (eq (ecc-model-node-get node 'kind) 'prompt)
                   (format "%s> %s\n\n" pad
                           (string-replace "\n" (concat "\n" pad "> ")
                                           (or (ecc-model-node-get node 'text) "")))
                 ""))
      (_ ""))))

(defun ecc-session-export-markdown-string (session)
  "Return the transcript of SESSION as Markdown."
  (concat
   (format "# %s\n\n" (ecc-session-name session))
   (mapconcat
    (lambda (turn)
      (concat (format "## %s\n\n" (or (ecc-turn-prompt turn)
                                           (ecc-turn-label turn)
                                           "(resumed)"))
              (mapconcat (lambda (node) (ecc-session--markdown-node node 0))
                         (ecc-turn-children turn) "")))
    (ecc-session-turns session) "")))

(defun ecc-session-export-markdown (file)
  "Save the transcript as Markdown in FILE (FR-OUT-14 f)."
  (interactive
   (list (read-file-name "Export to: " nil nil nil
                         (format "%s.md" (ecc-session-name (ecc-session-at-point))))))
  (let ((session (ecc-session-at-point)))
    (with-temp-file file
      (insert (ecc-session-export-markdown-string session)))
    (message "Saved to %s" (abbreviate-file-name file))))

(provide 'ecc-session)

;;; ecc-session.el ends here
