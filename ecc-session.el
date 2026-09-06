;;; ecc-session.el --- Session buffer and keys for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

;;; Commentary:

;; The buffer a conversation is read in: `ecc-session-mode', its keys and
;; the commands that move around a transcript and take things out of it
;; (FR-OUT-14).  Section 6.1 of IMPLEMENTATION_PLAN.md.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'magit-section)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-hint)
(require 'ecc-markdown)
(require 'ecc-diff)

(declare-function ecc-prompt-pop-to-buffer "ecc-prompt" (session))
(declare-function ecc-resume "ecc" (session &optional fork))
(declare-function ecc-perm-allow "ecc-perm" ())
(declare-function ecc-perm-deny "ecc-perm" (&optional reason))
(declare-function ecc-perm-allow-always "ecc-perm" ())
(declare-function ecc-perm-approve-turn "ecc-perm" ())
(declare-function ecc-perm-add-pattern "ecc-perm" ())
(declare-function ecc-perm-allow-all "ecc-perm" (&optional remember))
(declare-function ecc-question-open "ecc-perm" (request))
(declare-function ecc-plan-open "ecc-plan" (request))
(declare-function ecc-inbox "ecc-inbox" ())
(declare-function ecc-dashboard "ecc-dashboard" ())
(declare-function ecc-next-attention "ecc-inbox" ())
(declare-function ecc-review "ecc-review" (&optional session paths))
(declare-function ecc-perm-request-at-point "ecc-perm" ())
(declare-function ecc-menu "ecc-transient" ())
(declare-function ecc-tui-open "ecc-tui" (&optional session))

(defvar ecc-session-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'ecc-session-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "i") #'ecc-session-goto-prompt)
    (define-key map (kbd "RET") #'ecc-session-visit)
    (define-key map (kbd "R") #'ecc-session-resume)
    (define-key map (kbd "L") #'ecc-session-show-log)
    (define-key map (kbd "t") #'ecc-tui-open)
    (define-key map (kbd "a") #'ecc-perm-allow)
    (define-key map (kbd "d") #'ecc-session-review-or-deny)
    (define-key map (kbd "C-c d") #'ecc-session-review)
    (define-key map (kbd "C-c a") #'ecc-perm-allow-all)
    (define-key map (kbd "C-c A") #'ecc-session-allow-all-remember)
    (define-key map (kbd "C-c i") #'ecc-inbox)
    (define-key map (kbd "C-c D") #'ecc-dashboard)
    (define-key map (kbd "C-c n") #'ecc-next-attention)
    (define-key map (kbd "C-c C-k") #'ecc-session-interrupt)
    ;; Movement and extraction (FR-OUT-14)
    (define-key map (kbd "C-c C-n") #'ecc-session-next-turn)
    (define-key map (kbd "C-c C-p") #'ecc-session-previous-turn)
    (define-key map (kbd "]") #'ecc-session-next-block)
    (define-key map (kbd "[") #'ecc-session-previous-block)
    (define-key map (kbd "+") #'ecc-session-expand-all)
    (define-key map (kbd "-") #'ecc-session-collapse-all)
    (define-key map (kbd "T") #'ecc-session-timeline)
    (define-key map (kbd "w") #'ecc-session-copy-at-point)
    (define-key map (kbd "f") #'ecc-session-goto-files)
    (define-key map (kbd "C-c C-e") #'ecc-session-export-markdown)
    ;; One menu reaches every command (NFR-10).
    (define-key map (kbd "?") #'ecc-menu)
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
  ;; The state, and above all a request waiting for an answer, is shown
  ;; next to the mode name (FR-PERM-4), and after it what the session
  ;; costs and how much room is left in its context (FR-HINT-3).
  (setq-local mode-line-process
              ;; Escaped where it is put together rather than in each
              ;; piece: what the pieces return is text for a person.
              '(:eval (ecc--mode-line-escape
                       (concat (ecc-render-mode-line-process)
                               (ecc-hint-mode-line-string)))))
  (add-hook 'kill-buffer-hook #'ecc-session--forget-on-kill nil t))

(declare-function ecc-window-forget-session "ecc-window" (session))
(declare-function ecc-image-cleanup-session "ecc-prompt" (session))

(defun ecc-session--forget-on-kill ()
  "Stop and forget the session when its transcript buffer is killed.
Killing the buffer is taken as killing the session (plan 9, item 10):
the CLI is stopped, the session leaves the list, and its prompt and
line buffers go with it, so that nothing lingers in the dashboard as
an exited session with no buffer.  An agent transcript shares the
session but is not its buffer, so killing it does nothing."
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
      (dolist (buffer (list (ecc-session-prompt-buffer session)
                            (ecc-session-stream-buffer session)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

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
        ;; The buffer lives in the project, so that project commands and
        ;; `ecc-next-attention-in-project' see the right root.
        (setq default-directory (or (ecc-session-project-root session)
                                    default-directory))
        (ecc-session-mode)
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

(defun ecc-session-file-at-point ()
  "Return the path of the Files row the point is on, or nil."
  (when-let* ((section (magit-current-section))
              (value (oref section value)))
    (and (stringp value) (string-prefix-p "file:" value) (substring value 5))))

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
         (node (ecc-session-node-at-point))
         (path (ecc-session-file-at-point))
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
              (list (or (ecc-session-file-at-point)
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
      (unless (derived-mode-p 'ecc-session-mode)
        (ecc-session-mode))
      (ecc-render-draw-nodes session buffer
                             (concat (ecc-render--agent-heading node 0) "\n"
                                     (if-let* ((prompt (alist-get 'prompt input)))
                                         (concat "\n" prompt "\n")
                                       ""))
                             (ecc-node-children node)))
    (pop-to-buffer buffer)))

;;;; Movement (FR-OUT-14 a, b, c)

(defun ecc-session--sections (predicate)
  "Return the sections of this buffer satisfying PREDICATE, in order."
  (let (found)
    (magit-map-sections (lambda (section)
                          (when (funcall predicate section)
                            (push section found))))
    (sort (nreverse found)
          (lambda (a b) (< (marker-position (oref a start))
                           (marker-position (oref b start)))))))

(defun ecc-session--goto-neighbour (sections forward)
  "Move to the section of SECTIONS after point, or before when not FORWARD."
  (let* ((pos (point))
         (target (if forward
                     (seq-find (lambda (s) (> (marker-position (oref s start)) pos))
                               sections)
                   (car (last (seq-filter
                               (lambda (s) (< (marker-position (oref s start)) pos))
                               sections))))))
    (if target
        (magit-section-goto target)
      (user-error (if forward "No further section" "No earlier section")))))

(defun ecc-session-next-turn ()
  "Move to the next turn (FR-OUT-14 a)."
  (interactive)
  (ecc-session--goto-neighbour (ecc-render-turn-sections) t))

(defun ecc-session-previous-turn ()
  "Move to the previous turn (FR-OUT-14 a)."
  (interactive)
  (ecc-session--goto-neighbour (ecc-render-turn-sections) nil))

(defun ecc-session--expandable-p (section)
  "Return non-nil when SECTION is a block that can be folded."
  (and (oref section content)
       (seq-some (lambda (class) (cl-typep section class))
                 ecc-render-expandable-classes)))

(defun ecc-session-next-block ()
  "Move to the next tool, diff or thinking block (FR-OUT-14 b)."
  (interactive)
  (ecc-session--goto-neighbour (ecc-session--sections #'ecc-session--expandable-p) t))

(defun ecc-session-previous-block ()
  "Move to the previous tool, diff or thinking block (FR-OUT-14 b)."
  (interactive)
  (ecc-session--goto-neighbour (ecc-session--sections #'ecc-session--expandable-p) nil))

(defun ecc-session-expand-all ()
  "Unfold every block in the transcript (FR-OUT-14 c)."
  (interactive)
  (dolist (section (ecc-session--sections #'ecc-session--expandable-p))
    (magit-section-show section)))

(defun ecc-session-collapse-all ()
  "Fold every block in the transcript, keeping the turns open (FR-OUT-14 c)."
  (interactive)
  (dolist (section (ecc-session--sections #'ecc-session--expandable-p))
    (magit-section-hide section)))

(defun ecc-session-goto-files ()
  "Move to the Files section, expanding it."
  (interactive)
  (let ((section (car (ecc-session--sections
                       (lambda (s) (cl-typep s 'ecc-section-files))))))
    (unless section
      (user-error "No file has been touched yet"))
    (magit-section-goto section)
    (magit-section-show section)))

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
                                                                "(resumed)")
                                                            70))
                                     turn))
                             turns)))
    (unless candidates
      (user-error "No turn yet"))
    (let* ((choice (completing-read "Turn: " (mapcar #'car candidates) nil t))
           (turn (cdr (assoc choice candidates)))
           (section (and turn (ecc-render--turn-section (ecc-turn-id turn)))))
      (unless section
        (user-error "That turn is not drawn"))
      (magit-section-goto section)
      (magit-section-show section))))

;;;; Extraction (FR-OUT-14 e, f)

(defun ecc-session--code-block-around-point (section)
  "Return the fenced code block of SECTION that contains point, or nil.
The buffer text is used, so the indentation the renderer added is
stripped from every line."
  (let ((start (marker-position (oref section start)))
        (end (marker-position (oref section end)))
        (fence (concat "^\\([ \t]*\\)" (substring ecc-markdown-fence-regexp 1))))
    (save-excursion
      (let ((here (line-beginning-position)))
        (goto-char here)
        (end-of-line)
        (when (re-search-backward fence start t)
          (let ((open (line-beginning-position))
                (indent (match-string 1)))
            (forward-line 1)
            (let ((body-start (point)))
              (when (and (re-search-forward fence end t)
                         (>= (line-beginning-position) here))
                (let ((body (buffer-substring-no-properties
                             body-start (line-beginning-position))))
                  (ignore open)
                  (replace-regexp-in-string
                   (concat "^" (regexp-quote indent)) "" body))))))))))

(defun ecc-session-copy-at-point ()
  "Copy the code block at point, or else the whole assistant reply (FR-OUT-14 e)."
  (interactive)
  (let* ((node (ecc-session-node-at-point))
         (section (magit-current-section))
         (text (cond
                ((null node) nil)
                ((eq (ecc-node-type node) 'text)
                 (or (ecc-session--code-block-around-point section)
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
      (concat (format "## %s\n\n" (or (ecc-turn-prompt turn) "(resumed)"))
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
