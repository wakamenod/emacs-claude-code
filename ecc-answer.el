;;; ecc-answer.el --- Answer a waiting request from anywhere  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Maintainer: Jun <wakamenod@gmail.com>
;; Package-Requires: ((emacs "29.1"))
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
(declare-function ecc-resume "ecc" (session &optional fork))
(declare-function ecc-review "ecc-review" (&optional session paths))
(declare-function ecc-review-worktree "ecc-review" (&optional session range root))
(declare-function ecc-search "ecc-search" (query &optional everywhere))
(declare-function ecc-sidebar-focus "ecc-sidebar" ())
(declare-function ecc-space-goto "ecc-space" (space))
(declare-function ecc-space-zoom "ecc-space" ())
(declare-function ecc-space-reset-windows "ecc-space" ())
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
  ;; A question and a plan open a buffer of their own;
  ;; `ecc-window-display-beside-session' puts it where the session is,
  ;; Space and all.  A permission request is answered in the transcript,
  ;; and `ecc-display-session' goes there on its own.
  (pcase (ecc-request-kind request)
    ('question
     (ecc-window-display-beside-session (ecc-question-open request)
                                        (ecc-request-session request)))
    ('plan
     (require 'ecc-plan)
     (ecc-window-display-beside-session (ecc-plan-open request)
                                        (ecc-request-session request)))
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

(defun ecc-answer-session-request (session)
  "Return the oldest request of SESSION that may be answered from a list.
What the sidebar and the dashboard answer with `a\\=' and `d\\=': the row
says which session, and this says what of it.  A tool of
`ecc-answer-exclude-tools\\=' is refused here as `ecc-answer-target\\='
skips it elsewhere -- a shell command has to be read whole before it is
answered, and a row carries a summary cut to fit -- and `RET\\=' on the
row is the way to where it can be read."
  (let ((request (or (car (ecc-session-pending session))
                     (user-error "%s is not waiting for anything"
                                 (ecc-session-name session)))))
    (when (member (ecc-request-tool-name request) ecc-answer-exclude-tools)
      (user-error "%s is waiting on %s; answer that in the transcript (RET)"
                  (ecc-session-name session)
                  (ecc-request-tool-name request)))
    request))

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
        (ecc-window-display-beside-session buffer
                                           (ecc-request-session request))))
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
    ;; Resume itself rather than the menu in front of it: it is the
    ;; commonest thing done here, and `C-u' is the fork.  `ecc-menu'
    ;; keeps `ecc-resume-menu' under r, because the fork is worth one
    ;; form where it is seen before it is pressed.
    (define-key map (kbd "r") #'ecc-resume)
    (define-key map (kbd "R") #'ecc-rename-session)
    (define-key map (kbd "v") #'ecc-show-session)
    (define-key map (kbd "i") #'ecc-interrupt)
    (define-key map (kbd "t") #'ecc-tui-open)
    ;; The Spaces have the lower-case keys, being where the day is spent:
    ;; `j' goes to one, `b' is the sidebar that lists them, `z' is
    ;; herdr's zoom and `V' puts the tab back to the arrangement a new
    ;; Space gets.  `v' goes to the prompt of a session and `V' to the
    ;; windows around it, which is the pair worth having beside each
    ;; other.
    ;;
    ;; `B' is the dashboard: the capital beside the `b' that is pressed
    ;; all day, the two being the same list, one that stays on the screen
    ;; and one that does not.
    ;;
    ;; Nothing here makes or removes a worktree.  The three that do
    ;; belong together and are done in a week what these are done in an
    ;; hour: they are `ecc-worktree-menu', under `?' then `W'.
    (define-key map (kbd "j") #'ecc-space-goto)
    (define-key map (kbd "b") #'ecc-sidebar-focus)
    (define-key map (kbd "z") #'ecc-space-zoom)
    (define-key map (kbd "V") #'ecc-space-reset-windows)
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
    (define-key map (kbd "B") #'ecc-dashboard)
    (define-key map (kbd "D") #'ecc-review)
    ;; `G' is next to `D' because the two are one review with one
    ;; argument between them: what changed since the session started,
    ;; and what changed since the last commit.
    (define-key map (kbd "G") #'ecc-review-worktree)
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
the only way to reach it from a buffer that is not a session.  `r' is the
one key whose command differs: here it resumes at once, with the fork in
the prefix argument, while in the menu it opens `ecc-resume-menu', where
the fork is a switch.  The meaning is the same; only the form differs.")

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
