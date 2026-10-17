;;; ecc-dashboard.el --- Every Claude session in one list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Assisted-by: Claude Code:claude-opus-5-5
;; Assisted-by: Claude Code:claude-fable-5-1
;; Assisted-by: Claude Code:claude-haiku-4-5
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

;; One `tabulated-list-mode' buffer showing the sessions this Emacs
;; runs.
;;
;; Only those.  A session another process runs cannot be answered or
;; steered from here, and a conversation that is only a recording is
;; not running at all; both are reached through `ecc-resume', which
;; offers every recording there is.  The list is therefore read from
;; the model alone and is always current: no registry, no scan of
;; ~/.claude/projects, and nothing to poll.
;;
;; The requests waiting for an answer come first, and a and d answer
;; them without leaving the list.
;;
;; What the list is drawn to show at a glance: the header line sums the
;; sessions up and draws the rate limit they are closest to, the State
;; column carries a mark and turns a spinner while a session works, the
;; gutter marks what waits on the user (!) and what is on screen (▶),
;; and a row that is doing nothing has its detail dimmed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'hl-line)
(require 'tabulated-list)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-capabilities)
(require 'ecc-visual)
(require 'ecc-hint)
(require 'ecc-perm)
(require 'ecc-answer)
(require 'ecc-history)
(require 'ecc-usage)
(require 'ecc-window)
(require 'ecc-session)
(require 'ecc-skill)
(require 'ecc-lifecycle)

(defconst ecc-dashboard-buffer-name "*ecc-dashboard*"
  "Name of the dashboard buffer.")

;;;; The rows

;; A row is an `ecc-dashboard-entry': what a column needs, worked out
;; once, so that drawing the list touches the session only here.

(cl-defstruct ecc-dashboard-entry
  "One line of the dashboard."
  key           ; the session id, which is what makes a row unique
  session       ; the `ecc-session' the row is about
  name state root cwd model prompt time cost
  waiting)      ; how many requests of this session wait for an answer

(defun ecc-dashboard--session-entry (session)
  "Return the row of SESSION, which this Emacs runs."
  (let ((turn (car (last (ecc-session-turns session)))))
    (make-ecc-dashboard-entry
     :key (ecc-session-id session)
     :session session
     :name (ecc-session-name session)
     :state (format "%s" (ecc-session-state session))
     :root (or (ecc-session-project-root session) (ecc-session-cwd session))
     :cwd (ecc-session-cwd session)
     :model (ecc-render--model-name session)
     :prompt (or (and turn (ecc-turn-prompt turn)) "")
     :time (or (ecc-session-last-result-time session)
               (and turn (ecc-turn-start-time turn)))
     :cost (ecc-session-total-cost session)
     :waiting (length (ecc-session-pending session)))))

(defun ecc-dashboard-entries ()
  "Return the rows of the sessions this Emacs runs, waiting ones first.
A session read back from a recording is a reader, not a conversation
that can be answered, so it is left out."
  (ecc-dashboard--sort
   (mapcar #'ecc-dashboard--session-entry
           (seq-remove (lambda (session)
                         (eq (ecc-session-kind session) 'archived))
                       (ecc-model-sessions)))))

(defun ecc-dashboard--sort (rows)
  "Return ROWS with the ones waiting for an answer first, then by time.
`sort' is destructive and ROWS is freshly made here, but the sessions
it was built from are not, so the list is copied."
  (seq-sort (lambda (a b)
              (let ((wa (ecc-dashboard-entry-waiting a))
                    (wb (ecc-dashboard-entry-waiting b)))
                (if (eq (> wa 0) (> wb 0))
                    (ecc-dashboard--newer-p a b)
                  (> wa 0))))
            rows))

(defun ecc-dashboard--newer-p (a b)
  "Return non-nil when row A was active more recently than row B."
  (let ((ta (ecc-dashboard-entry-time a))
        (tb (ecc-dashboard-entry-time b)))
    (cond ((and ta tb) (time-less-p tb ta))
          (ta t)
          (t nil))))

;;;; What a row says it is doing

(defconst ecc-dashboard-state-marks
  '((starting . ("◌" . ecc-dim-face))
    (idle . ("○" . ecc-dim-face))
    (compacting . ("⟲" . ecc-running-face))
    (exited . ("✗" . ecc-error-face)))
  "The mark and the face of each state, for the State column.
`running' turns a spinner in place of a mark, and a session with a
request waiting for an answer says so whatever its state is.")

(defun ecc-dashboard--state-cell (entry)
  "Return the State cell of ENTRY: a mark, and what the session is doing.
What waits on the user comes first, because a session can be waiting
for an answer while its state still says that it runs."
  (let ((waiting (ecc-dashboard-entry-waiting entry))
        (state (or (ecc-dashboard-entry-state entry) "")))
    (cond
     ((> waiting 0)
      (propertize (format "⚠ waiting%s"
                          (if (> waiting 1) (format " ×%d" waiting) ""))
                  'face 'ecc-pending-face))
     ((equal state "running")
      (let ((frame (ecc-visual-spinner-string 'ecc-running-face)))
        (concat (if (string-empty-p frame) "▶" frame)
                (propertize " running" 'face 'ecc-running-face))))
     (t
      (let ((mark (alist-get (intern state) ecc-dashboard-state-marks)))
        (propertize (format "%s %s" (or (car mark) "·") state)
                    'face (or (cdr mark) 'ecc-dim-face)))))))

(defun ecc-dashboard--quiet-p (entry)
  "Return non-nil when ENTRY is neither working nor waiting on the user.
The detail of such a row is dimmed, so that the few rows worth looking
at are the ones that carry the colour."
  (and (zerop (ecc-dashboard-entry-waiting entry))
       (not (member (ecc-dashboard-entry-state entry) '("running" "compacting")))))

(defun ecc-dashboard--detail (string quiet)
  "Return STRING as a cell of secondary detail, dimmed when QUIET."
  (if quiet (propertize string 'face 'ecc-dim-face) string))

;;;; The spinner of the list

;; One timer for the whole list: the State column of every running
;; session turns the same frame, which `ecc-visual' counts.  It runs
;; only while something runs and the list is on screen, and the tick
;; stops it as soon as either stops being true.

(defvar ecc-dashboard-spinner-interval 0.2
  "Seconds between two frames of the spinner in the State column.
Slower than `ecc-visual-spinner-interval': the whole list is drawn
again at every frame, and what the spinner has to say here is only
that something is moving.")

(defvar ecc-dashboard--spinner-timer nil
  "The timer turning the spinner of the list, or nil.")

(defun ecc-dashboard--running-p ()
  "Return non-nil when a session of this Emacs is working."
  (seq-some (lambda (session) (eq (ecc-session-state session) 'running))
            (ecc-model-sessions)))

(defun ecc-dashboard--spinner-stop ()
  "Stop the spinner of the list."
  (when ecc-dashboard--spinner-timer
    (cancel-timer ecc-dashboard--spinner-timer)
    (setq ecc-dashboard--spinner-timer nil)))

(defun ecc-dashboard--spinner-update ()
  "Turn the spinner while something runs where it can be seen."
  (if (and ecc-visual-enable-spinner
           (ecc-dashboard--running-p)
           (get-buffer-window ecc-dashboard-buffer-name t))
      (unless ecc-dashboard--spinner-timer
        (setq ecc-dashboard--spinner-timer
              (ecc-visual-repeat ecc-dashboard-spinner-interval
                                 'ecc-visual-enable-spinner
                                 #'ecc-dashboard--spinner-tick)))
    (ecc-dashboard--spinner-stop)))

(defun ecc-dashboard--spinner-tick ()
  "Turn the spinner one frame, or stop when there is nothing to turn.
A list nobody is looking at is not worth a timer."
  (if (and (get-buffer-window ecc-dashboard-buffer-name t)
           (ecc-dashboard--running-p))
      (progn (ecc-visual-spinner-advance)
             ;; The frame alone, over the spinners that are there: the
             ;; rows change on the hooks, and drawing the list again at
             ;; every frame is what the sidebar was doing when it took
             ;; Emacs down (`ecc-visual-repeat', 2026-09-21).
             (ecc-visual-spinner-refresh (get-buffer ecc-dashboard-buffer-name)))
    (ecc-dashboard--spinner-stop)))

;;;; The summary above the list

(defun ecc-dashboard--limit-cell (entries)
  "Return the rate limit the sessions of ENTRIES are closest to, as a bar.
Nobody is asked anything: the CLI tells a session what is left of its
limits, and the highest of what the sessions were told is what is
drawn.  Nil when none of them has been told yet."
  (when-let* ((worst (car (sort (delq nil
                                      (mapcar
                                       (lambda (entry)
                                         (ecc-hint-rate-limit-max
                                          (ecc-dashboard-entry-session entry)))
                                       entries))
                                #'>))))
    (let ((percent (* 100 worst))
          (ecc-usage-bar-width 10))
      (concat (ecc-usage--bar percent)
              (propertize (format " %d%%" (round percent))
                          'face (ecc-usage--percent-face percent nil))))))

(defun ecc-dashboard--summary (entries)
  "Return the line drawn above the list, summing ENTRIES up.
The counts come first, then what the sessions have cost, then the rate
limit they are closest to.  A count of zero is left out: the line says
what there is, not what there is not."
  (if (null entries)
      (propertize " No session yet — + starts one" 'face 'ecc-dim-face)
    (let ((waiting 0) (running 0) (quiet 0) (cost 0))
      (dolist (entry entries)
        (cond ((> (ecc-dashboard-entry-waiting entry) 0) (cl-incf waiting))
              ((member (ecc-dashboard-entry-state entry) '("running" "compacting"))
               (cl-incf running))
              (t (cl-incf quiet)))
        (when (numberp (ecc-dashboard-entry-cost entry))
          (cl-incf cost (ecc-dashboard-entry-cost entry))))
      (concat
       " "
       (string-join
        (delq nil
              (list
               (when (> waiting 0)
                 (propertize (format "⚠ %d waiting" waiting)
                             'face 'ecc-pending-face))
               (when (> running 0)
                 (propertize (format "▶ %d running" running)
                             'face 'ecc-running-face))
               (when (> quiet 0)
                 (propertize (format "○ %d idle" quiet) 'face 'ecc-dim-face))
               (when (> cost 0)
                 (propertize (format "$%.2f" cost) 'face 'ecc-dim-face))
               (ecc-dashboard--limit-cell entries)))
        "   ")))))

(defun ecc-dashboard--header-line ()
  "Return the summary of the list, for `header-line-format\='."
  (ecc--mode-line-escape (ecc-dashboard--summary (ecc-dashboard-entries))))

;;;; The gutter

(defun ecc-dashboard--shown-p (session)
  "Return non-nil when a window somewhere shows the buffer of SESSION."
  (let ((buffer (ecc-session-buffer session)))
    (and (buffer-live-p buffer) (get-buffer-window buffer t) t)))

(defun ecc-dashboard--tag (entry)
  "Return the mark the gutter of ENTRY carries, or nil for none.
A session waiting for an answer is marked before one that is merely on
screen: the gutter has room for one mark, and that is the one to spend
it on."
  (cond ((> (ecc-dashboard-entry-waiting entry) 0)
         (propertize "!" 'face 'ecc-pending-face))
        ((ecc-dashboard--shown-p (ecc-dashboard-entry-session entry))
         (propertize "▶" 'face 'ecc-running-face))))

(defun ecc-dashboard--tag-rows ()
  "Put the mark of every row in the gutter `tabulated-list-padding' leaves."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((entry (tabulated-list-get-id)))
        (when (ecc-dashboard-entry-p entry)
          (when-let* ((tag (ecc-dashboard--tag entry)))
            (tabulated-list-put-tag tag))))
      (forward-line 1))))

;;;; Drawing

(defun ecc-dashboard--project-cell (root &optional cwd)
  "Return the Project cell of a row whose session lives in ROOT.
Only the last name of the path is shown, because that is what tells one
project from another; the whole path is in the tooltip.  The column
names the root rather than CWD, the directory the CLI reports: that one
is wherever the last Bash tool call left the CLI (2.1.272, confirmed
2026-09-16), so it moves under a row that has not moved.  It is worth
seeing all the same, and follows the root in the tooltip when the two
have come apart."
  (let ((label (ecc--fit (ecc--project-label root) 20)))
    (if (null root)
        label
      (propertize label 'help-echo
                  (concat (abbreviate-file-name root)
                          (when (and cwd (not (equal (file-name-as-directory
                                                      (expand-file-name cwd))
                                                     (file-name-as-directory
                                                      (expand-file-name root)))))
                            (format " (the CLI is in %s)"
                                    (abbreviate-file-name cwd))))))))

(defun ecc-dashboard--row (entry)
  "Return the `tabulated-list-entries' row of ENTRY."
  (let ((quiet (ecc-dashboard--quiet-p entry)))
    (list entry
          (vector
           (ecc--truncate (or (ecc-dashboard-entry-name entry) "") 24)
           (ecc-dashboard--state-cell entry)
           (ecc-dashboard--detail
            (ecc-dashboard--project-cell (ecc-dashboard-entry-root entry)
                                         (ecc-dashboard-entry-cwd entry))
            quiet)
           (ecc-dashboard--detail (or (ecc-dashboard-entry-model entry) "") quiet)
           (ecc-dashboard--detail
            (ecc--truncate (or (ecc-dashboard-entry-prompt entry) "") 60) quiet)
           (ecc-dashboard--detail
            (ecc--session-time-label (ecc-dashboard-entry-time entry)) quiet)
           (ecc-dashboard--detail
            (if (ecc-dashboard-entry-cost entry)
                (format "$%.2f" (ecc-dashboard-entry-cost entry))
              "")
            quiet)))))

(defun ecc-dashboard--print (&optional remember)
  "Draw the list, mark its gutter and see to the spinner.
REMEMBER is passed to `tabulated-list-print'."
  (tabulated-list-print remember)
  (ecc-dashboard--tag-rows)
  (ecc-dashboard--first-row)
  (ecc-dashboard--spinner-update))

(defun ecc-dashboard--first-row ()
  "Move off the column header, which is a line of the buffer and holds no row."
  (when (and (null (tabulated-list-get-id)) (not (eobp)))
    (forward-line 1)))

(defun ecc-dashboard--collect ()
  "Fill `tabulated-list-entries' for the dashboard."
  (setq tabulated-list-entries (mapcar #'ecc-dashboard--row
                                       (ecc-dashboard-entries))))


(defvar ecc-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-dashboard-visit)
    (define-key map (kbd "+") #'ecc-dashboard-new)
    (define-key map (kbd "k") #'ecc-dashboard-stop)
    (define-key map (kbd "D") #'ecc-dashboard-delete)
    (define-key map (kbd "r") #'ecc-dashboard-resume)
    (define-key map (kbd "R") #'ecc-dashboard-rename)
    (define-key map (kbd "a") #'ecc-dashboard-allow)
    (define-key map (kbd "d") #'ecc-dashboard-deny)
    (define-key map (kbd "g") #'ecc-dashboard-refresh)
    (define-key map (kbd "C") #'ecc-dashboard-capabilities)
    (define-key map (kbd "S") #'ecc-skill-show)
    (define-key map (kbd "U") #'ecc-usage)
    map)
  "Keymap of `ecc-dashboard-mode'.")

(define-derived-mode ecc-dashboard-mode tabulated-list-mode "Claude-Sessions"
  "Major mode listing every Claude session Emacs can see.

\\{ecc-dashboard-mode-map}"
  :interactive nil
  (setq tabulated-list-format [("Name" 24 t) ("State" 18 t)
                               ("Project" 20 t) ("Model" 8 t) ("Last prompt" 40 t)
                               ("Updated" 14 t) ("Cost" 8 t)])
  ;; The header line carries the summary, so the column header is a
  ;; line of the buffer; `ecc-dashboard--first-row' keeps point off it.
  (setq tabulated-list-use-header-line nil)
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (setq header-line-format '(:eval (ecc-dashboard--header-line)))
  ;; Drawn again on every change, nothing here is to be undone; the
  ;; history would hold every redraw and every marker of the buffer.
  (buffer-disable-undo)
  (hl-line-mode 1)
  (add-hook 'tabulated-list-revert-hook #'ecc-dashboard--collect nil t)
  (add-hook 'kill-buffer-hook #'ecc-dashboard--spinner-stop nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun ecc-dashboard ()
  "Show the sessions this Emacs runs."
  (interactive)
  (let ((buffer (get-buffer-create ecc-dashboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-dashboard-mode)
        (ecc-dashboard-mode))
      (ecc-dashboard--collect)
      (ecc-dashboard--print t))
    (pop-to-buffer buffer)
    ;; The spinner wants a window, and there is one only now.
    (with-current-buffer buffer (ecc-dashboard--spinner-update))
    buffer))

(defun ecc-dashboard-redraw ()
  "Draw the dashboard again from what is already known."
  (when-let* ((buffer (get-buffer ecc-dashboard-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((point (point)))
          (ecc-dashboard--collect)
          (ecc-dashboard--print t)
          (goto-char (min point (point-max)))
          (ecc-dashboard--first-row))))))

(defun ecc-dashboard-refresh ()
  "Draw the dashboard again."
  (interactive)
  (ecc-dashboard-redraw))

;;;; Commands

(defun ecc-dashboard-entry-at-point ()
  "Return the row at point, or signal an error."
  (let ((entry (tabulated-list-get-id)))
    (unless (ecc-dashboard-entry-p entry)
      (user-error "No session on this line"))
    entry))

(defun ecc-dashboard-session-at-point ()
  "Return the session of the row at point."
  (ecc-dashboard-entry-session (ecc-dashboard-entry-at-point)))

(defun ecc-dashboard-capabilities ()
  "Show everything the session at point can do."
  (interactive)
  (ecc-capabilities-show (ecc-dashboard-session-at-point)))

(defun ecc-dashboard-visit ()
  "Show the transcript of the session at point."
  (interactive)
  (select-window (ecc-display-session (ecc-dashboard-session-at-point))))

(defun ecc-dashboard-new (directory)
  "Start a session in DIRECTORY."
  (interactive (list (read-directory-name "Directory: " (ecc-window-project-root))))
  (ecc-start directory)
  (ecc-dashboard-redraw))

(defun ecc-dashboard-stop ()
  "Stop the session at point, after asking.
The sidebar's `k\\=' asks and this did not, which is one list of rows
answering a key two ways; stopping a session takes its window and its
transcript with it, and the row point is on is whichever the last
redraw left it on."
  (interactive)
  (let ((session (ecc-dashboard-session-at-point)))
    (when (yes-or-no-p (format "Stop %s? " (ecc-session-name session)))
      (ecc-kill session)
      (ecc-dashboard-redraw))))

(defun ecc-dashboard-delete ()
  "Delete the recording of the session at point, after asking."
  (interactive)
  (let* ((entry (ecc-dashboard-entry-at-point))
         (file (or (ecc-history-file (ecc-dashboard-entry-key entry))
                   (user-error "This session has no recording"))))
    (when (yes-or-no-p (format "Delete %s? " (abbreviate-file-name file)))
      (delete-file file)
      (ecc-dashboard-refresh))))

(defun ecc-dashboard-rename (name)
  "Rename the session at point to NAME.
The prompt offers the name the session has, as `ecc-rename-session\='
does, and that is the command underneath: one rename, and one place
where the buffer and the mode line follow it."
  (interactive (list (read-string
                      "New name: "
                      (ecc-session-name (ecc-dashboard-session-at-point)))))
  (let ((session (ecc-dashboard-session-at-point)))
    (when (string-empty-p (string-trim name))
      (user-error "The name may not be empty"))
    (ecc-rename-session session name)
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-resume ()
  "Resume the session at point."
  (interactive)
  ;; A session another process is running is refused by
  ;; `ecc-history-resume' unless the user insists.
  (let ((session (ecc-dashboard-session-at-point)))
    (ecc-history-resume session current-prefix-arg)
    (select-window (ecc-display-session session))
    (ecc-dashboard-redraw)))

(defun ecc-dashboard--request-at-point ()
  "Return the request of the session at point, or signal an error.
`ecc-answer-session-request\\=' is what says which, here and in the
sidebar alike: the oldest one waiting, and not one for a tool that has
to be read where it was asked."
  (ecc-answer-session-request (ecc-dashboard-session-at-point)))

(defun ecc-dashboard-allow ()
  "Allow the oldest waiting request of the session at point.
Asked about first, the way the sidebar asks: a list of rows is answered
from the row point happens to be on, and `ecc-answer-confirm\\=' is what
says whether that is enough on its own."
  (interactive)
  (let ((request (ecc-dashboard--request-at-point)))
    (when (ecc-answer--confirm "Allow" request)
      (ecc-perm-allow-request request)
      (message "Allowed: %s" (ecc-answer-summary request))
      (ecc-dashboard-redraw))))

(defun ecc-dashboard-deny (reason)
  "Deny the oldest waiting request of the session at point with REASON."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (let ((request (ecc-dashboard--request-at-point)))
    (when (ecc-answer--confirm "Deny" request)
      (ecc-perm-respond request 'deny :message reason)
      (message "Denied: %s" (ecc-answer-summary request))
      (ecc-dashboard-redraw))))

;;;; Wiring

(defun ecc-dashboard--on-change (&rest _)
  "Draw the dashboard again after something changed in the model."
  (ecc-dashboard-redraw))

(dolist (hook '(ecc-request-added-hook
                ecc-request-resolved-hook
                ecc-turn-finished-hook
                ecc-session-state-changed-hook))
  (add-hook hook #'ecc-dashboard--on-change))

(provide 'ecc-dashboard)

;;; ecc-dashboard.el ends here
