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
;;
;; On top of allow and deny this file offers the permission suggestions
;; of the CLI (FR-PERM-3), a turn wide approval (FR-PERM-7), allow
;; patterns written to the project settings (FR-PERM-8), the bulk
;; operations (FR-PERM-9), the warning about unsaved buffers (FR-SYNC-2)
;; and the buffer an AskUserQuestion is answered in (FR-PERM-5).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'crm)
(require 'rmc)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-dispatch)
(require 'ecc-render)
(require 'ecc-sync)

(declare-function ecc-plan-approve-request "ecc-plan" (request &optional mode))

(defcustom ecc-perm-default-deny-message "User denied this tool call."
  "Message sent to Claude when the user denies without giving a reason."
  :type 'string
  :group 'ecc)

(defcustom ecc-perm-unsaved-deny-message
  "The file has unsaved changes in the editor; wait for the user to save it."
  "Message sent to Claude when a change is refused because of unsaved edits."
  :type 'string
  :group 'ecc)

(defcustom ecc-perm-remember-exclude-tools '("Bash")
  "Tools that `ecc-perm-allow-all-remember' allows once but never remembers.
Remembering a tool allows every later call of it for the rest of the
session without a look (FR-PERM-9); a tool that can run anything is
not worth that shortcut.  Nil remembers every tool."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-perm-settings-file ".claude/settings.local.json"
  "Settings file, relative to the project root, that allow patterns go to."
  :type 'string
  :group 'ecc)

;;;; Responding (the one place that answers)

(cl-defun ecc-perm-respond (request behavior &key message updated-input
                                    updated-permissions)
  "Answer REQUEST with BEHAVIOR, which is `allow' or `deny'.
MESSAGE is the reason shown to Claude when denying; for an allow it is
only kept in the transcript as what was answered.  UPDATED-INPUT
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
      (ecc-model-node-put node 'outcome-message
                          (and message (not (string-empty-p message)) message)))
    (ecc-model-resolve-request session request
                               (if (eq behavior 'allow) 'done 'denied))
    request))

;;;; Finding the request a command is about

(defun ecc-perm-session ()
  "Return the session a command in this buffer is about, or nil.
The session of the buffer wins, then the most recently used one."
  (or ecc-render--session (car (ecc-model-sessions))))

(defun ecc-perm-request-at-point ()
  "Return the request the point is on, or nil."
  (when-let* ((session ecc-render--session)
              (id (get-text-property (point) 'ecc-node))
              (node (ecc-model-node session id))
              (request (ecc-model-node-get node 'request)))
    (and (memq request (ecc-session-pending session)) request)))

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

(defun ecc-perm-permission-request ()
  "Return the current request, which must be a plain permission."
  (let ((request (ecc-perm-current-request)))
    (unless (eq (ecc-request-kind request) 'permission)
      (user-error "This is a %s, not a permission request"
                  (ecc-request-kind request)))
    request))

(defun ecc-perm-close-buffer (buffer)
  "Take BUFFER off every window and kill it."
  (when (buffer-live-p buffer)
    (dolist (window (get-buffer-window-list buffer nil t))
      (quit-window nil window))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun ecc-perm-file-request-p (request)
  "Return non-nil when REQUEST would change a file."
  (memq (cdr (assoc (ecc-request-tool-name request) ecc-dispatch-file-tools))
        '(edit write)))

;;;; Allowing, with the unsaved buffer check (FR-SYNC-2)

(defun ecc-perm--unsaved-choice (request)
  "Ask what to do when the file of REQUEST has unsaved changes.
Returns `save', `allow', `deny', or nil when there is nothing to ask."
  (when-let* ((buffer (and (ecc-perm-file-request-p request)
                           (ecc-sync-unsaved-buffer
                            (alist-get 'file_path (ecc-request-input request))))))
    (pcase (car (read-multiple-choice
                 (format "%s has unsaved changes" (buffer-name buffer))
                 '((?s "save and allow" "Save the buffer, then let Claude change the file")
                   (?a "allow anyway" "Let Claude change the file on disk as it is")
                   (?d "deny" "Refuse the change and tell Claude why"))))
      (?s (with-current-buffer buffer (save-buffer)) 'save)
      (?a 'allow)
      (?d 'deny))))

(defun ecc-perm-allow-request (request)
  "Allow REQUEST the way its kind wants, and return what happened.
A permission is allowed after the unsaved buffer check; a question
opens the buffer it is answered in; a plan is approved as it stands.
Returns `allow', `deny', `save' or `opened'."
  (pcase (ecc-request-kind request)
    ('question
     (pop-to-buffer (ecc-question-open request))
     'opened)
    ('plan
     (require 'ecc-plan)
     (ecc-plan-approve-request request)
     'allow)
    (_
     (let ((choice (ecc-perm--unsaved-choice request)))
       (if (eq choice 'deny)
           (ecc-perm-respond request 'deny :message ecc-perm-unsaved-deny-message)
         (ecc-perm-respond request 'allow))
       (or choice 'allow)))))

;;;; Commands

(defun ecc-perm-allow ()
  "Allow the request at point, or the oldest one waiting (FR-PERM-1)."
  (interactive)
  (let ((request (ecc-perm-current-request)))
    (pcase (ecc-perm-allow-request request)
      ('opened nil)
      ('deny (message "Denied: %s (the buffer has unsaved changes)"
                      (ecc-request-tool-name request)))
      (_ (message "Allowed: %s" (ecc-request-tool-name request))))))

(defun ecc-perm-deny (&optional reason)
  "Deny the request at point with REASON, asking for one (FR-PERM-2)."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (let ((request (ecc-perm-current-request)))
    (ecc-perm-respond request 'deny :message reason)
    (message "Denied: %s" (ecc-request-tool-name request))))

(defun ecc-perm-allow-next ()
  "Allow the oldest request waiting in this session (FR-PERM-9)."
  (interactive)
  (let ((request (or (car (ecc-session-pending (or (ecc-perm-session)
                                                   (user-error "No session"))))
                     (user-error "No request is waiting for an answer"))))
    (ecc-perm-allow-request request)
    (message "Allowed: %s" (ecc-request-tool-name request))))

(defun ecc-perm-deny-next (&optional reason)
  "Deny the oldest request waiting in this session with REASON (FR-PERM-9)."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (let ((request (or (car (ecc-session-pending (or (ecc-perm-session)
                                                   (user-error "No session"))))
                     (user-error "No request is waiting for an answer"))))
    (ecc-perm-respond request 'deny :message reason)
    (message "Denied: %s" (ecc-request-tool-name request))))

(defun ecc-perm-allow-all (&optional remember)
  "Allow every permission request waiting in this session (FR-PERM-9).
With REMEMBER, the tools involved are not asked about again for the
rest of the session.  Questions and plans are left for their own
buffers.  Returns the requests that were allowed."
  (interactive "P")
  (let* ((session (or (ecc-perm-session) (user-error "No session")))
         (requests (seq-filter (lambda (request)
                                 (eq (ecc-request-kind request) 'permission))
                               (copy-sequence (ecc-session-pending session))))
         (skipped (- (length (ecc-session-pending session)) (length requests)))
         (allowed nil))
    (unless requests
      (user-error "No permission request is waiting"))
    (dolist (request requests)
      (unless (eq (ecc-perm-allow-request request) 'deny)
        (push request allowed)
        (when (and remember
                   (not (member (ecc-request-tool-name request)
                                ecc-perm-remember-exclude-tools)))
          (cl-pushnew (ecc-request-tool-name request)
                      (ecc-session-auto-approve-kinds session)
                      :test #'equal))))
    (message "Allowed %d requests%s%s" (length allowed)
             (cond
              ((and remember (ecc-session-auto-approve-kinds session))
               (format "; %s is allowed on its own for the rest of this session"
                       (string-join (ecc-session-auto-approve-kinds session) ", ")))
              (remember
               (format "; nothing remembered (%s is never remembered)"
                       (string-join ecc-perm-remember-exclude-tools ", ")))
              (t ""))
             (if (> skipped 0)
                 (format " (%d questions and plans left alone)" skipped)
               ""))
    (nreverse allowed)))

(defun ecc-perm-allow-all-remember ()
  "Allow every waiting request and stop asking about those tools (FR-PERM-9)."
  (interactive)
  (ecc-perm-allow-all t))

;;;; Turn wide approval (FR-PERM-7)

(defun ecc-perm-approve-turn ()
  "Allow the request at point and every `ecc-turn-approve-tools' request.
Requests of those tools arriving until the end of the current turn are
allowed as they come; the flag is cleared by the result (FR-PERM-7)."
  (interactive)
  (let* ((at-point (ecc-perm-request-at-point))
         (session (or (and at-point (ecc-request-session at-point))
                      (ecc-perm-session)
                      (user-error "No session")))
         (allowed 0))
    (unless (or (ecc-session-current-turn session) (ecc-session-pending session))
      (user-error "No turn is running"))
    (setf (ecc-session-auto-approve-turn session) t)
    (dolist (request (copy-sequence (ecc-session-pending session)))
      (when (and (eq (ecc-request-kind request) 'permission)
                 (or (eq request at-point)
                     (member (ecc-request-tool-name request) ecc-turn-approve-tools)))
        (unless (eq (ecc-perm-allow-request request) 'deny)
          (cl-incf allowed))))
    (message "Allowed %d requests; %s is allowed on its own for this turn"
             allowed (string-join ecc-turn-approve-tools ", "))
    allowed))

;;;; Permission suggestions (FR-PERM-3)

(defun ecc-perm-suggestion-label (suggestion)
  "Return a readable description of the permission SUGGESTION."
  (pcase (alist-get 'type suggestion)
    ("setMode"
     (format "Set the permission mode to %s (%s)"
             (alist-get 'mode suggestion)
             (or (alist-get 'destination suggestion) "session")))
    ("addRules"
     (format "Add rules: %s (%s)"
             (mapconcat (lambda (rule)
                          (format "%s(%s)" (alist-get 'toolName rule)
                                  (alist-get 'ruleContent rule)))
                        (append (or (alist-get 'rules suggestion) []) nil) ", ")
             (or (alist-get 'destination suggestion) "session")))
    ("addDirectories"
     (format "Add directories: %s"
             (mapconcat #'identity
                        (append (or (alist-get 'directories suggestion) []) nil)
                        ", ")))
    (_ (ecc-protocol-value-string suggestion))))

(defun ecc-perm-choose-suggestion (request)
  "Ask which of the suggestions of REQUEST to apply and return it.
A single suggestion is returned without asking."
  (let ((suggestions (append (ecc-request-suggestions request) nil)))
    (if (= (length suggestions) 1)
        (car suggestions)
      (let* ((labels (mapcar (lambda (suggestion)
                               (cons (ecc-perm-suggestion-label suggestion)
                                     suggestion))
                             suggestions))
             (choice (completing-read "From now on: " (mapcar #'car labels) nil t)))
        (cdr (assoc choice labels))))))

(defun ecc-perm-allow-always ()
  "Allow the request and apply what the CLI suggested for the future.
With a permission suggestion, such as switching to acceptEdits, it is
sent back as updatedPermissions (FR-PERM-3).  Without one, an allow
pattern is chosen and saved instead (FR-PERM-8)."
  (interactive)
  (let ((request (ecc-perm-permission-request)))
    (if (null (ecc-request-suggestions request))
        (ecc-perm-add-pattern)
      (let ((suggestion (ecc-perm-choose-suggestion request)))
        (unless (eq (ecc-perm--unsaved-choice request) 'deny)
          (ecc-perm-respond request 'allow
                            :updated-permissions (vector suggestion)
                            :message (ecc-perm-suggestion-label suggestion))
          (message "Allowed: %s" (ecc-perm-suggestion-label suggestion)))))))

;;;; Allow patterns (FR-PERM-8)

(defun ecc-perm--bash-patterns (command)
  "Return the allow patterns for the Bash COMMAND, most specific first.
Only the first command of a pipeline or a list is looked at."
  (when (stringp command)
    (let* ((first (car (split-string command "\\s-*\\(?:|\\|&&\\|;\\)\\s-*" t)))
           (words (and first (split-string first "[ \t\n]+" t)))
           (w1 (car words))
           (w2 (cadr words)))
      (when w1
        (delete-dups
         (delq nil
               (list (and w2 (not (string-prefix-p "-" w2))
                          (format "Bash(%s %s *)" w1 w2))
                     (format "Bash(%s *)" w1)
                     (and (equal first (string-trim command))
                          (<= (length first) 80)
                          (not (string-search "\n" first))
                          (format "Bash(%s)" first)))))))))

(defun ecc-perm--file-patterns (tool-name path project-root)
  "Return the allow patterns for TOOL-NAME on PATH under PROJECT-ROOT.
Paths inside the project are written relative to it, others absolute
with the // prefix the CLI uses for absolute rules."
  (when (stringp path)
    (let* ((absolute (expand-file-name path))
           (root (and project-root (file-name-as-directory
                                    (expand-file-name project-root))))
           (inside (and root (string-prefix-p root absolute)))
           (shown (if inside (substring absolute (length root)) (concat "/" absolute)))
           (directory (file-name-directory shown))
           (extension (file-name-extension shown)))
      (delete-dups
       (delq nil
             (list (format "%s(%s)" tool-name shown)
                   (and directory (format "%s(%s**)" tool-name directory))
                   (and extension (format "%s(**/*.%s)" tool-name extension))))))))

(defun ecc-perm--mcp-patterns (tool-name)
  "Return the allow patterns for the MCP tool TOOL-NAME: the tool, then its server."
  (let ((parts (split-string tool-name "__")))
    (delete-dups
     (delq nil (list tool-name
                     (and (>= (length parts) 3)
                          (concat "mcp__" (nth 1 parts))))))))

(defun ecc-perm-suggest-patterns (tool-name input &optional project-root)
  "Return allow patterns for a call to TOOL-NAME with INPUT (FR-PERM-8).
PROJECT-ROOT makes file patterns relative.  The list goes from the
most specific pattern to the broadest, and is never empty."
  (or (pcase tool-name
        ("Bash" (ecc-perm--bash-patterns (alist-get 'command input)))
        ((or "Edit" "MultiEdit" "Write" "Read" "NotebookEdit")
         (ecc-perm--file-patterns tool-name (alist-get 'file_path input)
                                  project-root))
        ((pred (string-prefix-p "mcp__")) (ecc-perm--mcp-patterns tool-name))
        ("WebFetch"
         (when-let* ((url (alist-get 'url input))
                     (host (ignore-errors (url-host (url-generic-parse-url url)))))
           (list (format "WebFetch(domain:%s)" host))))
        (_ nil))
      (list tool-name)))

(defun ecc-perm-settings-file (session)
  "Return the settings file of the project of SESSION that patterns go to."
  (expand-file-name ecc-perm-settings-file (ecc-session-project-root session)))

(defun ecc-perm-save-patterns (session patterns)
  "Add PATTERNS to the allow list of the settings file of SESSION.
Returns the patterns that were new."
  (ecc-protocol-settings-add-allow (ecc-perm-settings-file session) patterns))

(defun ecc-perm-add-pattern ()
  "Save an allow pattern for the request at point, then offer to allow it.
The patterns are made by `ecc-perm-suggest-patterns'; the chosen ones
go to the permissions.allow list of the project settings file after a
confirmation that names the file and the patterns (FR-PERM-8)."
  (interactive)
  (let* ((request (ecc-perm-permission-request))
         (session (ecc-request-session request))
         (candidates (ecc-perm-suggest-patterns (ecc-request-tool-name request)
                                                (ecc-request-input request)
                                                (ecc-session-project-root session)))
         (crm-separator "[ \t]*;[ \t]*")
         (chosen (completing-read-multiple
                  (format "Allow patterns to save (; separated, default %s): " (car candidates))
                  candidates nil nil nil nil (car candidates)))
         (file (ecc-perm-settings-file session)))
    (setq chosen (seq-remove #'string-empty-p (mapcar #'string-trim chosen)))
    (unless chosen
      (user-error "No pattern chosen"))
    (unless (y-or-n-p (format "Add %s to %s? "
                              (string-join chosen ", ") (abbreviate-file-name file)))
      (user-error "Nothing written"))
    (let ((new (ecc-perm-save-patterns session chosen)))
      (message "%s: %s" (abbreviate-file-name file)
               (if new (format "added %s" (string-join new ", "))
                 "nothing to add")))
    (when (and (memq request (ecc-session-pending session))
               (y-or-n-p (format "Allow this %s now as well? "
                                 (ecc-request-tool-name request))))
      (ecc-perm-allow-request request))
    chosen))

;;;; AskUserQuestion (FR-PERM-5)

;; The questions are answered in a buffer of their own.  Every question
;; is listed with numbered options; the number keys choose for the
;; question the point is in, SPC toggles the option at point, `o' adds
;; a free text answer, and C-c C-c sends the answers.

(defface ecc-question-chosen-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a chosen option in the question buffer."
  :group 'ecc)

(defvar-local ecc-question--request nil
  "The request this question buffer answers.")

(defvar-local ecc-question--answers nil
  "Vector with, per question, the list of chosen labels or free texts.")

(defvar ecc-question-mode-map
  (let ((map (make-sparse-keymap)))
    (dotimes (n 9)
      (define-key map (kbd (number-to-string (1+ n))) #'ecc-question-choose))
    (define-key map (kbd "SPC") #'ecc-question-toggle-at-point)
    (define-key map (kbd "RET") #'ecc-question-toggle-at-point)
    (define-key map (kbd "o") #'ecc-question-other)
    (define-key map (kbd "n") #'ecc-question-next)
    (define-key map (kbd "p") #'ecc-question-previous)
    (define-key map (kbd "TAB") #'ecc-question-next)
    (define-key map (kbd "<backtab>") #'ecc-question-previous)
    (define-key map (kbd "u") #'ecc-question-clear)
    (define-key map (kbd "C-c C-c") #'ecc-question-submit)
    (define-key map (kbd "C-c C-k") #'ecc-question-cancel)
    map)
  "Keymap of `ecc-question-mode'.")

(define-derived-mode ecc-question-mode special-mode "Claude-Question"
  "Major mode of the buffer an AskUserQuestion is answered in.

\\{ecc-question-mode-map}"
  :interactive nil
  (setq-local truncate-lines nil))

(defun ecc-question-buffer-name (session)
  "Return the name of the question buffer of SESSION."
  (format "*ecc-question: %s*" (ecc-session-name session)))

(defun ecc-question-questions (request)
  "Return the questions of REQUEST as a list of alists."
  (append (or (alist-get 'questions (ecc-request-input request)) []) nil))

(defun ecc-question-buffer (request)
  "Return the live buffer answering REQUEST, or nil."
  (let ((buffer (get-buffer (ecc-question-buffer-name (ecc-request-session request)))))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer (eq ecc-question--request request))
         buffer)))

(defun ecc-question-open (request)
  "Return the buffer that answers REQUEST, creating it if needed."
  (or (ecc-question-buffer request)
      (let ((buffer (get-buffer-create
                     (ecc-question-buffer-name (ecc-request-session request)))))
        (with-current-buffer buffer
          (ecc-question-mode)
          (setq ecc-render--session (ecc-request-session request))
          (setq ecc-question--request request
                ecc-question--answers
                (make-vector (length (ecc-question-questions request)) nil))
          (ecc-question--draw)
          (goto-char (point-min))
          (ecc-question-next))
        buffer)))

(defun ecc-question--multi-p (question)
  "Return non-nil when QUESTION allows several answers."
  (eq (alist-get 'multiSelect question) t))

(defun ecc-question--option-labels (question)
  "Return the option labels of QUESTION."
  (mapcar (lambda (option) (alist-get 'label option))
          (append (or (alist-get 'options question) []) nil)))

(defalias 'ecc-perm-question-options #'ecc-question--option-labels)

(defun ecc-question--draw ()
  "Draw the questions and the answers so far into the current buffer."
  (let ((inhibit-read-only t)
        (questions (ecc-question-questions ecc-question--request))
        (index -1))
    (erase-buffer)
    (insert (propertize (format "Question from %s"
                                (ecc-session-name
                                 (ecc-request-session ecc-question--request)))
                        'face 'ecc-heading-face)
            (propertize (format "   (%d question%s)\n\n" (length questions)
                                (if (= (length questions) 1) "" "s"))
                        'face 'ecc-dim-face))
    (dolist (question questions)
      (cl-incf index)
      (let* ((chosen (aref ecc-question--answers index))
             (multi (ecc-question--multi-p question))
             (labels (ecc-question--option-labels question))
             (others (seq-remove (lambda (answer) (member answer labels)) chosen))
             (start (point))
             (n 0))
        (insert (propertize (format "Q%d  %s" (1+ index)
                                    (or (alist-get 'header question) ""))
                            'face 'ecc-heading-face)
                (propertize (if multi "  (several may be chosen)" "") 'face 'ecc-dim-face)
                "\n"
                (propertize (or (alist-get 'question question) "") 'face 'ecc-pending-face)
                "\n")
        (seq-doseq (option (or (alist-get 'options question) []))
          (cl-incf n)
          (let* ((label (alist-get 'label option))
                 (on (member label chosen))
                 (line (format "  %d. %s %s" n
                               (cond ((and multi on) "[x]")
                                     (multi "[ ]")
                                     (on "(•)")
                                     (t "( )"))
                               label)))
            (insert (propertize line 'face (if on 'ecc-question-chosen-face 'default)
                                'ecc-option label)
                    (if-let* ((description (alist-get 'description option)))
                        (propertize (format " — %s" description) 'face 'ecc-dim-face)
                      "")
                    "\n")))
        (insert (propertize (format "  o. %s Other%s" (if others (if multi "[x]" "(•)")
                                                      (if multi "[ ]" "( )"))
                                    (if others (concat ": " (string-join others ", ")) ""))
                            'face (if others 'ecc-question-chosen-face 'ecc-dim-face)
                            'ecc-option 'other)
                "\n\n")
        (put-text-property start (point) 'ecc-question index)))
    (insert (propertize
             (concat "1-9: choose  SPC/RET: toggle the option on this line  o: free text"
                     "  n/p: next/previous question  u: undo  C-c C-c: send"
                     "  C-c C-k: refuse the question")
             'face 'ecc-dim-face)
            "\n")))

(defun ecc-question--index-at-point ()
  "Return the index of the question the point is in, else the first unanswered."
  (or (get-text-property (point) 'ecc-question)
      (let ((index 0) (found nil))
        (while (and (not found) (< index (length ecc-question--answers)))
          (if (aref ecc-question--answers index)
              (cl-incf index)
            (setq found index)))
        (or found 0))))

(defun ecc-question--goto (index)
  "Move point to the heading of question INDEX."
  (goto-char (point-min))
  (let ((position (text-property-any (point-min) (point-max) 'ecc-question index)))
    (when position (goto-char position))))

(defun ecc-question--redraw (index)
  "Draw the buffer again and put the point back on question INDEX."
  (let ((line (- (line-number-at-pos)
                 (line-number-at-pos (or (text-property-any (point-min) (point-max)
                                                            'ecc-question index)
                                         (point))))))
    (ecc-question--draw)
    (ecc-question--goto index)
    (forward-line (max 0 line))))

(defun ecc-question-set-answer (index answer)
  "Choose ANSWER, a label or a free text, for question INDEX.
A multiSelect question toggles ANSWER; any other question replaces its
answer.  Returns the new list of answers of the question."
  (let* ((question (nth index (ecc-question-questions ecc-question--request)))
         (current (aref ecc-question--answers index)))
    (aset ecc-question--answers index
          (cond ((not (ecc-question--multi-p question)) (list answer))
                ((member answer current) (remove answer current))
                (t (append current (list answer)))))
    (aref ecc-question--answers index)))

(defun ecc-question-choose (n)
  "Choose option N of the question at point.
Interactively N comes from the key pressed.  A single answer question
moves on to the next question afterwards."
  (interactive (list (- last-command-event ?0)))
  (let* ((index (ecc-question--index-at-point))
         (question (nth index (ecc-question-questions ecc-question--request)))
         (labels (ecc-question--option-labels question))
         (label (nth (1- n) labels)))
    (unless (and (>= n 1) label)
      (user-error "Question %d has %d options" (1+ index) (length labels)))
    (ecc-question-set-answer index label)
    (ecc-question--redraw index)
    (unless (ecc-question--multi-p question)
      (ecc-question-next))))

(defun ecc-question-toggle-at-point ()
  "Choose or toggle the option on the current line."
  (interactive)
  (let ((option (get-text-property (line-beginning-position) 'ecc-option))
        (index (get-text-property (point) 'ecc-question)))
    (cond ((null index) (user-error "Not on a question"))
          ((null option) (user-error "Not on an option"))
          ((eq option 'other) (call-interactively #'ecc-question-other))
          (t (ecc-question-set-answer index option)
             (ecc-question--redraw index)))))

(defun ecc-question-other (text)
  "Answer the question at point with the free TEXT (the Other choice)."
  (interactive (list (read-string "Other answer: ")))
  (let ((index (ecc-question--index-at-point)))
    (when (string-empty-p (string-trim text))
      (user-error "Empty answer"))
    (ecc-question-set-answer index (string-trim text))
    (ecc-question--redraw index)))

(defun ecc-question-clear ()
  "Forget the answer of the question at point."
  (interactive)
  (let ((index (ecc-question--index-at-point)))
    (aset ecc-question--answers index nil)
    (ecc-question--redraw index)))

(defun ecc-question-next ()
  "Move to the next question, or to the send hint after the last one."
  (interactive)
  (let ((index (get-text-property (point) 'ecc-question))
        (count (length ecc-question--answers)))
    (ecc-question--goto (if (null index) 0 (min (1+ index) (1- count))))))

(defun ecc-question-previous ()
  "Move to the previous question."
  (interactive)
  (let ((index (or (get-text-property (point) 'ecc-question) 0)))
    (ecc-question--goto (max 0 (1- index)))))

(defun ecc-question-answers ()
  "Return the answers of this buffer as an alist of question text to answer.
Signals a `user-error' naming the first question left unanswered."
  (let ((index -1))
    (mapcar (lambda (question)
              (cl-incf index)
              (let ((chosen (aref ecc-question--answers index)))
                (unless chosen
                  (user-error "Question %d is not answered yet" (1+ index)))
                (cons (alist-get 'question question)
                      (string-join chosen ", "))))
            (ecc-question-questions ecc-question--request))))

(defun ecc-question-submit ()
  "Send the answers of this buffer to Claude (FR-PERM-5).
The questions are echoed back unchanged; only `answers' is added,
keyed by the question text, a multiSelect answer joined by \", \"."
  (interactive)
  (let* ((request ecc-question--request)
         (session (ecc-request-session request))
         (buffer (current-buffer))
         (pairs (ecc-question-answers)))
    (unless (memq request (ecc-session-pending session))
      (user-error "This question was answered already"))
    (when-let* ((node (ecc-request-node request)))
      (ecc-model-node-put node 'answers pairs))
    (ecc-perm-respond request 'allow
                      :updated-input (append (ecc-request-input request)
                                             (list (cons 'answers
                                                         (ecc-protocol-answers pairs))))
                      :message (concat "answered: "
                                       (mapconcat #'cdr pairs " · ")))
    (message "Answer sent")
    (ecc-perm-close-buffer buffer)
    pairs))

(defun ecc-question-cancel (&optional reason)
  "Refuse to answer the question, telling Claude REASON."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (let ((request ecc-question--request)
        (buffer (current-buffer)))
    (ecc-perm-respond request 'deny
                      :message (if (string-empty-p (or reason ""))
                                   "User declined to answer the question."
                                 reason))
    (message "Question refused")
    (ecc-perm-close-buffer buffer)))

(defun ecc-question--on-request-resolved (_session request)
  "Close the buffer of REQUEST, which was answered somewhere else."
  (when-let* ((buffer (ecc-question-buffer request)))
    ;; The buffer that is answering closes itself once it is done.
    (unless (eq buffer (current-buffer))
      (ecc-perm-close-buffer buffer))))

(add-hook 'ecc-request-resolved-hook #'ecc-question--on-request-resolved)

(provide 'ecc-perm)

;;; ecc-perm.el ends here
