;;; ecc-review-talk.el --- Talk to Claude without leaving a review  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Hunk (github.com/modem-dev/hunk) has the diff in one terminal and
;; the agent in another, and the user asks the agent about the diff
;; from the second.  An ediff review takes the whole frame
;; (`ecc-review-ediff-full-frame'), which hides the session and its
;; prompt, so here the asking is done from the review itself:
;;
;; - T asks Claude for a tour of the review (`ecc-review-talk-tour-prompt'),
;;   t for its next stop, and M reads a line and sends it.  They go to
;;   the session of the review and are sent the way a prompt typed in
;;   the minibuffer is (`ecc-send'): queued while a turn runs.
;;
;; - In an ediff review a pane at the bottom of the frame shows the
;;   latest reply of that session as it streams, each tool call on a
;;   line of its own, and whatever Claude is waiting for -- a
;;   permission, a question, a plan -- which y answers from the control
;;   panel.  The pane is a side window at the bottom of the frame, put
;;   back whenever ediff lays its windows out again, and it goes when the
;;   review is quit.  It is never selected: the keys of the review stay
;;   in the control panel.
;;
;; A diff review shares the frame with the session, whose transcript is
;; beside it, so it has the keys and no pane.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-answer)
(require 'ecc-context)
(require 'ecc-review)
(require 'ecc-review-agent)

(defvar ediff-window-A)

(defcustom ecc-review-talk-reply-height 8
  "How many lines the reply pane under an ediff review takes, or nil for none.
The pane shows what Claude says while the review hides the session;
the lines it takes are the review's, and how many a screen can spare
is the screen's."
  :type '(choice (integer :tag "Lines") (const :tag "No pane" nil))
  :group 'ecc)

(defvar ecc-review-talk-tour-prompt
  "Walk me through the changes in the review I have open, the most \
important first.  For each stop, bring it into view with review_navigate, \
explain it in a few sentences, and put a review_comment on any line that \
needs my attention.  Then stop and wait: I will ask for the next stop."
  "What the key T of a review sends to the session of the review.")

(defvar ecc-review-talk-next-prompt "Next stop."
  "What the key t of a review sends to the session of the review.")

(defface ecc-review-talk-speaker-face
  '((t :inherit ecc-heading-face))
  "Face of the name in front of what Claude says in the reply pane."
  :group 'ecc)

;;;; Sending

(defun ecc-review-talk--session ()
  "Return the session of this review, or signal that this is no review."
  (unless (ecc-review-buffer-p)
    (user-error "Not a review of files"))
  ecc-review--session)

(defun ecc-review-talk--needs-tools (session)
  "Signal a `user-error' unless SESSION has the review tools of this Emacs.
A tour is made of them; without MCP the model has none to call."
  (unless (ecc-model-option session :mcp ecc-mcp-enabled)
    (user-error "A tour needs the review tools: turn on `ecc-mcp-enabled' and start %s again"
                (ecc-session-name session))))

(defun ecc-review-talk-send (text)
  "Send TEXT to the session of this review as a prompt, and show the pane.
Sent the way `ecc-send' sends a prompt typed in the minibuffer, which
queues it while a turn is running and says so."
  (let ((session (ecc-review-talk--session)))
    (ecc-review-talk--show-pane (current-buffer))
    (ecc-send text session)))

;;;###autoload
(defun ecc-review-talk-tour ()
  "Ask Claude for a tour of this review, one stop at a time.
Claude shows each stop with `review_navigate', explains it, comments
on the lines that need attention, and waits to be asked for the next
stop (`ecc-review-talk-next')."
  (interactive)
  (ecc-review-talk--needs-tools (ecc-review-talk--session))
  (ecc-review-talk-send ecc-review-talk-tour-prompt))

;;;###autoload
(defun ecc-review-talk-next ()
  "Ask Claude for the next stop of the tour."
  (interactive)
  (ecc-review-talk--needs-tools (ecc-review-talk--session))
  (ecc-review-talk-send ecc-review-talk-next-prompt))

;;;###autoload
(defun ecc-review-talk-message (text)
  "Send TEXT, read in the minibuffer, to the session of this review."
  (interactive
   (list (read-string (format "To %s: " (ecc-session-name (ecc-review-talk--session))))))
  (when (string-empty-p (string-trim text))
    (user-error "Prompt is empty"))
  (ecc-review-talk-send text))

;;;; Answering what Claude waits for

(defun ecc-review-talk--request (session)
  "Return the oldest request SESSION is waiting on, or signal that there is none.
Every tool, Bash included: `ecc-answer-exclude-tools' keeps a request
from being answered from a row that cuts it short, and the pane prints
a request whole."
  (or (car (ecc-session-pending session))
      (user-error "%s is not waiting for anything" (ecc-session-name session))))

(defun ecc-review-talk--answer-question (request)
  "Answer the question REQUEST through the minibuffer, one question at a time.
The answers are put in the buffer `ecc-question-open' makes and sent
from there, so they go back the way the question buffer sends them.
A buffer made here and left unsent is killed."
  (let* ((existed (ecc-question-buffer request))
         (buffer (ecc-question-open request))
         (sent nil))
    (unwind-protect
        (with-current-buffer buffer
          (let ((index 0))
            (dolist (question (ecc-question-questions request))
              (let ((labels (ecc-perm-question-options question))
                    (prompt (format "%s " (or (alist-get 'question question) "Answer:"))))
                (if (ecc-question--multi-p question)
                    (dolist (answer (completing-read-multiple prompt labels))
                      (ecc-question-set-answer index (string-trim answer)))
                  (let ((answer (string-trim (completing-read prompt labels))))
                    (when (string-empty-p answer)
                      (user-error "No answer given"))
                    (ecc-question-set-answer index answer))))
              (cl-incf index)))
          (prog1 (ecc-question-submit)
            (setq sent t)))
      (unless (or sent existed)
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun ecc-review-talk-answer ()
  "Answer what the session of this review is waiting for.
A permission or a plan is allowed or denied, a question is answered in
the minibuffer.  What is answered is the one the reply pane shows."
  (interactive)
  (let* ((session (ecc-review-talk--session))
         (request (ecc-review-talk--request session)))
    (if (eq (ecc-request-kind request) 'question)
        (ecc-review-talk--answer-question request)
      (let ((plan (eq (ecc-request-kind request) 'plan)))
        (pcase (car (read-multiple-choice
                     (format "%s: %s" (ecc-session-name session) (ecc-answer-summary request))
                     (if plan
                         '((?y "approve" "Approve the plan as it stands")
                           (?n "deny" "Refuse the plan and say why"))
                       '((?y "allow" "Let Claude use the tool this once")
                         (?n "deny" "Refuse and say why")))))
          (?y (ecc-perm-allow-request request)
              (message "%s: %s" (if plan "Approved" "Allowed") (ecc-answer-summary request)))
          (?n (ecc-perm-respond request 'deny
                                :message (read-string "Reason for denying (may be empty): "))
              (message "Denied: %s" (ecc-answer-summary request))))))))

;;;; The pane

(defvar ecc-review-talk--panes nil
  "The live reply panes, whichever review they belong to.")

(defvar-local ecc-review-talk--pane nil
  "The reply pane of this review, or nil.")

(defvar-local ecc-review-talk--review nil
  "The review this reply pane belongs to.")

(defvar-local ecc-review-talk--of nil
  "The session whose replies this pane shows.")

(defvar-local ecc-review-talk--tail nil
  "The text node whose end is the end of what this pane says, or nil.
A delta of that node is appended at `ecc-review-talk--tail-end'; any
other change writes the pane again.")

(defvar-local ecc-review-talk--tail-end nil
  "Where the next piece of `ecc-review-talk--tail' goes.")

(defvar ecc-review-talk-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap of `ecc-review-talk-mode'.")

(define-derived-mode ecc-review-talk-mode special-mode "Claude-Reply"
  "Major mode of the pane an ediff review shows Claude's replies in.

\\{ecc-review-talk-mode-map}"
  :interactive nil
  (setq truncate-lines nil
        word-wrap t)
  (buffer-disable-undo)
  (setq mode-line-format '(:eval (ecc-review-talk--mode-line)))
  (add-hook 'kill-buffer-hook #'ecc-review-talk--forget nil t))

(defun ecc-review-talk--forget ()
  "Take this pane off the list of panes, as it is killed."
  (setq ecc-review-talk--panes (delq (current-buffer) ecc-review-talk--panes)))

(defun ecc-review-talk--mode-line ()
  "Return the mode line of this reply pane: whose replies, and the state."
  (let ((session ecc-review-talk--of))
    (concat " "
            (propertize "Claude" 'face 'ecc-review-talk-speaker-face)
            (propertize (format " · %s · " (ecc-session-name session)) 'face 'ecc-dim-face)
            (pcase (ecc-session-state session)
              ('running "replying…")
              ((or 'waiting-permission 'waiting-question 'waiting-plan)
               (propertize "waiting for you: y answers" 'face 'ecc-pending-face))
              (state (format "%s" state))))))

(defun ecc-review-talk--pane-buffer (review)
  "Return the reply pane of REVIEW, made when it has none."
  (with-current-buffer review
    (if (buffer-live-p ecc-review-talk--pane)
        ecc-review-talk--pane
      (let* ((name (ecc-review-pane-name review "reply"))
             (taken (get-buffer name))
             (pane (if (and taken
                            (buffer-live-p (buffer-local-value 'ecc-review-talk--review taken))
                            (not (eq (buffer-local-value 'ecc-review-talk--review taken)
                                     review)))
                       (generate-new-buffer name)
                     (get-buffer-create name)))
            (session ecc-review--session))
        (with-current-buffer pane
          (ecc-review-talk-mode)
          (setq ecc-review-talk--review review
                ecc-review-talk--of session))
        (push pane ecc-review-talk--panes)
        (add-hook 'kill-buffer-hook #'ecc-review-talk--review-killed nil t)
        (ecc-review-talk--write pane)
        (setq ecc-review-talk--pane pane)))))

(defun ecc-review-talk--review-killed ()
  "Kill the reply pane of this review with it, and the window it is in."
  (when (buffer-live-p ecc-review-talk--pane)
    (dolist (window (get-buffer-window-list ecc-review-talk--pane nil t))
      (when (eq (window-deletable-p window) t)
        (delete-window window)))
    (kill-buffer ecc-review-talk--pane)))

(defun ecc-review-talk--show-pane (review)
  "Show the reply pane at the bottom of the frame of REVIEW; return its window.
Only for an ediff review, and only while `ecc-review-talk-reply-height'
is a number; nil otherwise, or when the review is on no window.  The
pane is a side window, taken down while ediff lays its windows out
again with | or m and put back afterwards, and it is not selected."
  (with-current-buffer review
    (when (and ecc-review-talk-reply-height
               (derived-mode-p 'ediff-mode)
               (window-live-p ediff-window-A))
      (let ((pane (ecc-review-talk--pane-buffer review)))
        (or (get-buffer-window pane t)
            (let ((window (with-selected-window ediff-window-A
                            (display-buffer-in-side-window
                             pane `((side . bottom) (slot . 0)
                                    (window-height . ,ecc-review-talk-reply-height)
                                    (preserve-size . (nil . t))
                                    (dedicated . t)
                                    (window-parameters . ((no-other-window . t)
                                                          (no-delete-other-windows . t))))))))
              (when (window-live-p window)
                (set-window-parameter window 'ecc-review-talk t)
                (ecc-review-talk--follow pane))
              window))))))

(defun ecc-review-talk--on-displayed (review)
  "Show the reply pane of REVIEW now that it is on the screen.
On `ecc-review-displayed-functions'."
  (when (ecc-review-buffer-p review)
    (with-current-buffer review
      (when (derived-mode-p 'ediff-mode)
        (add-hook 'ediff-before-setup-windows-hook #'ecc-review-talk--leave-the-frame nil t)
        (add-hook 'ediff-after-setup-windows-hook #'ecc-review-talk--keep-the-pane nil t)))
    (ecc-review-talk--show-pane review)))

(add-hook 'ecc-review-displayed-functions #'ecc-review-talk--on-displayed)

(defun ecc-review-talk--leave-the-frame ()
  "Take the reply pane off the frame before ediff lays out its windows.
On `ediff-before-setup-windows-hook\\=' of the control buffer.  ediff
puts its control panel in the lowest window of the frame
\(`ediff-select-lowest-window\\='), and with the pane there the panel
took the window of the left side instead: after | the review showed
the control buffer where its old text had been."
  (when-let* ((pane ecc-review-talk--pane)
              ((buffer-live-p pane)))
    (dolist (window (get-buffer-window-list pane nil t))
      (when (eq (window-deletable-p window) t)
        (delete-window window)))))

(defun ecc-review-talk--keep-the-pane ()
  "Show the reply pane again once ediff has laid out its windows.
On `ediff-after-setup-windows-hook\\=' of the control buffer."
  (when (buffer-live-p ecc-review-talk--pane)
    (ecc-review-talk--show-pane (current-buffer))))

;;;;; What it says

(defun ecc-review-talk--short-name (name)
  "Return the tool NAME without the mcp__SERVER__ of this Emacs's server."
  (let ((prefix (format "mcp__%s__" ecc-mcp-server-name)))
    (if (string-prefix-p prefix name) (substring name (length prefix)) name)))

(defun ecc-review-talk--place (input)
  "Return the place in the review the review tool INPUT names, or nil."
  (let ((file (alist-get 'file input))
        (line (alist-get 'line input))
        (hunk (alist-get 'hunk input))
        (comment (alist-get 'comment_id input))
        (direction (alist-get 'direction input))
        (reply (alist-get 'reply_to input)))
    (cond
     (comment (format "#%s" comment))
     (direction (if (equal direction "prev_comment") "previous comment" "next comment"))
     ((and file line) (format "%s:%s%s" file line
                              (if (equal (alist-get 'side input) "old") " (old)" "")))
     ((and file hunk) (format "%s hunk %s" file hunk))
     (file file)
     (reply (format "reply to #%s" reply)))))

(defun ecc-review-talk-tool-summary (name input)
  "Return what the reply pane says of a call to NAME with INPUT, after the name.
A review tool says where in the review; any other tool what the
transcript's heading says."
  (let ((summary
         (pcase (ecc-review-talk--short-name name)
           ((or "review_navigate" "review_hunks") (ecc-review-talk--place input))
           ("review_comment"
            (concat (or (ecc-review-talk--place input) "")
                    (when-let* ((text (alist-get 'text input)))
                      (format ": %s" (ecc--truncate (ecc-render--one-line text) 50)))))
           ("review_comment_apply"
            (ecc-review--count (length (alist-get 'comments input)) "comment"))
           ("review_open" (or (alist-get 'range input)
                              (and (eq (alist-get 'staged input) t) "staged")))
           ("review_list_comments" (alist-get 'author input))
           ("review_remove_comment" (format "#%s" (alist-get 'id input)))
           ("review_clear_comments" (or (alist-get 'file input) "every file"))
           (_ (ecc-render-tool-summary name input)))))
    (if (stringp summary) summary "")))

(defun ecc-review-talk--tool-line (node)
  "Return the line of the reply pane for the tool or agent NODE."
  (let* ((name (or (ecc-model-node-get node 'name) "?"))
         (summary (ecc-review-talk-tool-summary name (ecc-model-node-get node 'input))))
    (concat (propertize (concat "  " (ecc-review-talk--short-name name)
                                (if (string-empty-p summary) "" (concat " → " summary)))
                        'face 'ecc-dim-face)
            (pcase (ecc-node-status node)
              ('running (propertize " …" 'face 'ecc-dim-face))
              ('error (propertize " ✗" 'face 'error))
              ('denied (propertize " (denied)" 'face 'warning))
              (_ ""))
            "\n")))

(defun ecc-review-talk--insert-node (node)
  "Insert what the reply pane says of NODE, a child of the turn it shows."
  (pcase (ecc-node-type node)
    ('text
     (let ((text (or (ecc-model-streaming-text node) (ecc-model-node-get node 'text) "")))
       (unless (and (string-empty-p text) (not (ecc-node-streaming node)))
         (unless (bobp) (insert "\n"))
         (insert text "\n")
         (setq ecc-review-talk--tail node)
         (set-marker ecc-review-talk--tail-end (1- (point))))))
    ('step
     (dolist (child (ecc-node-children node))
       (when (memq (ecc-node-type child) '(tool agent))
         (insert (ecc-review-talk--tool-line child))
         (setq ecc-review-talk--tail nil))))
    ((or 'tool 'agent)
     (insert (ecc-review-talk--tool-line node))
     (setq ecc-review-talk--tail nil))))

(defun ecc-review-talk--request-text (request)
  "Return what the reply pane says of REQUEST: what it asks, whole."
  (let ((input (ecc-request-input request)))
    (pcase (ecc-request-kind request)
      ('question
       (mapconcat
        (lambda (question)
          (concat (propertize (or (alist-get 'question question) "") 'face 'ecc-pending-face)
                  "\n"
                  (let ((n 0))
                    (mapconcat (lambda (option)
                                 (format "  %d. %s%s" (cl-incf n) (alist-get 'label option)
                                         (if-let* ((description (alist-get 'description option)))
                                             (propertize (format " — %s" description)
                                                         'face 'ecc-dim-face)
                                           "")))
                               (append (alist-get 'options question) nil)
                               "\n"))))
        (ecc-question-questions request) "\n"))
      ('plan
       (concat (propertize "Claude has a plan for you to approve:" 'face 'ecc-pending-face)
               "\n" (string-trim (or (alist-get 'plan input) ""))))
      (_
       (concat (propertize (format "Claude asks to use %s:"
                                   (ecc-review-talk--short-name
                                    (or (ecc-request-display-name request)
                                        (ecc-request-tool-name request))))
                           'face 'ecc-pending-face)
               "\n"
               (or (and (equal (ecc-request-tool-name request) "Bash")
                        (alist-get 'command input))
                   (ecc-review-talk-tool-summary (ecc-request-tool-name request) input))
               (if-let* ((description (or (alist-get 'description input)
                                          (ecc-request-description request))))
                   (propertize (format "\n%s" description) 'face 'ecc-dim-face)
                 ""))))))

(defun ecc-review-talk--insert-requests (session)
  "Insert what SESSION is waiting for, the oldest one first, and how to answer."
  (let ((first t))
    (dolist (request (ecc-session-pending session))
      (unless (bobp) (insert "\n"))
      (insert (ecc-review-talk--request-text request) "\n")
      (when first
        (insert (propertize
                 (pcase (ecc-request-kind request)
                   ('question "y answers it here")
                   ('plan "y approves or denies it here")
                   (_ "y allows or denies it here"))
                 'face 'ecc-dim-face)
                "\n")
        (setq first nil))
      (setq ecc-review-talk--tail nil))))

(defun ecc-review-talk--turn (session)
  "Return the turn of SESSION the reply pane shows: the latest one."
  (car (last (ecc-session-turns session))))

(defun ecc-review-talk--write (pane)
  "Write the reply PANE again from its session's latest turn."
  (with-current-buffer pane
    (let* ((session ecc-review-talk--of)
           (turn (ecc-review-talk--turn session))
           (inhibit-read-only t))
      (erase-buffer)
      (setq ecc-review-talk--tail nil)
      (unless (markerp ecc-review-talk--tail-end)
        (setq ecc-review-talk--tail-end (make-marker)))
      (set-marker-insertion-type ecc-review-talk--tail-end t)
      (if (null turn)
          (insert (propertize "Nothing from Claude yet.  T asks for a tour, M says something.\n"
                              'face 'ecc-dim-face))
        (when-let* ((prompt (ecc-turn-prompt turn)))
          (unless (string-empty-p prompt)
            (insert (propertize (concat "› " (ecc--truncate (ecc-render--one-line prompt) 200))
                                'face 'ecc-dim-face)
                    "\n")))
        (dolist (child (ecc-turn-children turn))
          (ecc-review-talk--insert-node child)))
      (ecc-review-talk--insert-requests session)
      (unless ecc-review-talk--tail
        (set-marker ecc-review-talk--tail-end nil))))
  (ecc-review-talk--follow pane))

(defun ecc-review-talk--follow (pane)
  "Put the end of PANE at the bottom of every window showing it.
No window is selected for it: the start is reckoned from the end in
the window's own width."
  (with-current-buffer pane
    (goto-char (point-max))
    (dolist (window (get-buffer-window-list pane nil t))
      (set-window-point window (point-max))
      (set-window-start window
                        (save-excursion
                          (goto-char (point-max))
                          (vertical-motion (- (max 1 (1- (window-body-height window))))
                                           window)
                          (point))
                        t)))
  (force-mode-line-update t))

;;;;; Following the session

(defun ecc-review-talk--panes-of (session)
  "Return the live reply panes showing SESSION."
  (seq-filter (lambda (pane)
                (and (buffer-live-p pane)
                     (eq (buffer-local-value 'ecc-review-talk--of pane) session)))
              ecc-review-talk--panes))

(defun ecc-review-talk--on-change (session &rest _)
  "Write the panes of SESSION again: a turn, a node or a request came or went."
  (mapc #'ecc-review-talk--write (ecc-review-talk--panes-of session)))

(defun ecc-review-talk--on-node (session node)
  "Write the panes of SESSION again when NODE is in the turn they show."
  (when-let* ((panes (ecc-review-talk--panes-of session)))
    (when (eq (ecc-model-turn-of node) (ecc-review-talk--turn session))
      (mapc #'ecc-review-talk--write panes))))

(defun ecc-review-talk--on-delta (session node text)
  "Append TEXT, which streamed into NODE of SESSION, to the panes showing it.
Only what Claude says in the turn itself: a subagent's text and
thinking are not in the pane.  Appended where the node ends, when it is
what the pane ends with, else the pane is written again."
  (when-let* ((panes (ecc-review-talk--panes-of session)))
    (when (and (eq (ecc-node-type node) 'text)
               (eq (ecc-node-parent node) (ecc-review-talk--turn session)))
      (dolist (pane panes)
        (if (and (eq (buffer-local-value 'ecc-review-talk--tail pane) node)
                 (marker-position (buffer-local-value 'ecc-review-talk--tail-end pane)))
            (with-current-buffer pane
              (let ((inhibit-read-only t))
                (save-excursion
                  (goto-char ecc-review-talk--tail-end)
                  (insert text)))
              (ecc-review-talk--follow pane))
          (ecc-review-talk--write pane))))))

(dolist (hook '(ecc-turn-started-hook ecc-turn-finished-hook
                ecc-request-added-hook ecc-request-resolved-hook))
  (add-hook hook #'ecc-review-talk--on-change))
(add-hook 'ecc-node-added-hook #'ecc-review-talk--on-node)
(add-hook 'ecc-node-updated-hook #'ecc-review-talk--on-node)
(add-hook 'ecc-stream-delta-hook #'ecc-review-talk--on-delta)
(defun ecc-review-talk--on-state (session &rest _)
  "Say the new state of SESSION in the mode line of its panes."
  (when (ecc-review-talk--panes-of session)
    (force-mode-line-update t)))

(add-hook 'ecc-session-state-changed-hook #'ecc-review-talk--on-state)

(provide 'ecc-review-talk)

;;; ecc-review-talk.el ends here
