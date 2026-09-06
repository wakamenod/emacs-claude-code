;;; ecc-dashboard.el --- Every Claude session in one list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.7 of IMPLEMENTATION_PLAN.md: one `tabulated-list-mode'
;; buffer showing the sessions this package runs, the ones another
;; process runs, and the ones that only exist as a recording
;; (FR-DASH-1 to 6).
;;
;; The three sources are read differently.  The sessions of this Emacs
;; are in the model and are always current.  The sessions of another
;; process come from `ecc-registry', which reads the files Claude Code
;; keeps about itself: no subprocess, and the directory can be watched,
;; so the list is current without polling for it.  The recordings are
;; scanned on the first draw and on g, reading the two ends of each file
;; rather than all of it.
;;
;; A session that appears in more than one source is shown once: a live
;; session knows more about itself than its recording does.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-inbox)
(require 'ecc-history)
(require 'ecc-registry)
(require 'ecc-window)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-session-ensure-buffer "ecc-session" (session))

(defcustom ecc-dashboard-poll-interval 30
  "Seconds between two rereads of the session registry (FR-DASH-2).
The registry is watched, so this only catches what a file notification
missed, and it only runs while the dashboard is on screen."
  :type 'number
  :group 'ecc)

(defcustom ecc-dashboard-recordings t
  "Non-nil lists the recorded conversations as well (FR-DASH-2 c).
Scanning them reads a few lines of every file under
`ecc-history-directory'."
  :type 'boolean
  :group 'ecc)

(defconst ecc-dashboard-buffer-name "*ecc-dashboard*"
  "Name of the dashboard buffer.")

;;;; The rows

;; A row is an `ecc-dashboard-entry'.  It is what the three sources have
;; in common, and it carries whatever the source could say; a column
;; shows an empty string for what it could not.

(cl-defstruct ecc-dashboard-entry
  "One line of the dashboard."
  key           ; the session id, which is what makes a row unique
  kind          ; own | external | archived
  session       ; the `ecc-session', for an own or opened session
  agent         ; the `claude agents --json' object, for an external one
  file          ; the recording, for an archived one
  name state cwd model prompt time cost
  waiting)      ; how many requests of this session wait for an answer

(defun ecc-dashboard--session-entry (session)
  "Return the row of SESSION, which this Emacs runs."
  (let ((turn (car (last (ecc-session-turns session)))))
    (make-ecc-dashboard-entry
     :key (ecc-session-id session)
     :kind (if (eq (ecc-session-kind session) 'archived) 'archived 'own)
     :session session
     :name (ecc-session-name session)
     :state (format "%s" (ecc-session-state session))
     :cwd (or (ecc-session-cwd session) (ecc-session-project-root session))
     :model (or (alist-get 'model (ecc-session-init session))
                (ecc-model-option session :model ecc-model))
     :prompt (or (and turn (ecc-turn-prompt turn)) "")
     :time (or (ecc-session-last-result-time session)
               (and turn (ecc-turn-start-time turn)))
     :cost (ecc-session-total-cost session)
     :waiting (length (ecc-session-pending session)))))

(defun ecc-dashboard--agent-entry (agent)
  "Return the row of AGENT, a session another process runs (FR-DASH-6).
The CLI records its state itself; `waitingFor' says what it is waiting
for when it is not simply busy or idle."
  (let ((waiting-for (alist-get 'waitingFor agent))
        (status (alist-get 'status agent)))
    (make-ecc-dashboard-entry
     :key (alist-get 'sessionId agent)
     :kind 'external
     :agent agent
     :name (or (alist-get 'name agent) "?")
     :state (if (and waiting-for (stringp waiting-for))
                (format "waiting: %s" waiting-for)
              (or status "?"))
     :cwd (alist-get 'cwd agent)
     :model (or (alist-get 'version agent) "")
     :prompt (or (alist-get 'kind agent) "")
     :time (when-let* ((updated (or (alist-get 'updatedAt agent)
                                    (alist-get 'startedAt agent))))
             (time-convert (/ updated 1000.0) 'list))
     :cost nil
     :waiting (if (and waiting-for (stringp waiting-for)) 1 0))))

(defun ecc-dashboard--file-entry (info)
  "Return the row of the recording described by INFO (FR-DASH-2 c)."
  (make-ecc-dashboard-entry
   :key (alist-get 'session-id info)
   :kind 'archived
   :file (alist-get 'file info)
   :name (or (alist-get 'title info) (alist-get 'session-id info))
   :state "archived"
   :cwd (alist-get 'cwd info)
   :model ""
   :prompt (or (alist-get 'prompt info) "")
   :time (or (alist-get 'time info) (alist-get 'mtime info))
   :cost (alist-get 'cost info)
   :waiting 0))

;;;; The sources

(defvar ecc-dashboard--agents nil
  "The sessions Claude Code is running, as `ecc-registry' last read them.")

(defvar ecc-dashboard--recordings nil
  "The scan of `ecc-history-directory', as a list of alists.")

(defvar ecc-dashboard--timer nil
  "Timer that polls the sessions of other processes, or nil.")

(defun ecc-dashboard-refresh-agents (&optional callback)
  "Reread the sessions Claude Code is running (FR-DASH-2 b).
CALLBACK, when given, is called once they are in.  Reading the registry
costs a few small files, so unlike `claude agents --json' this needs no
process and can be done as often as the list is drawn."
  (setq ecc-dashboard--agents (ecc-registry-sessions))
  (when callback (funcall callback))
  ecc-dashboard--agents)

(defun ecc-dashboard-refresh-recordings ()
  "Scan `ecc-history-directory' and remember what it holds (FR-DASH-2 c)."
  (setq ecc-dashboard--recordings
        (when ecc-dashboard-recordings
          (mapcar #'ecc-history-scan-file (ecc-history-files)))))

(defun ecc-dashboard-entries ()
  "Return the rows of every session, the ones needing an answer first.
A session known from several sources is shown once, with the row of
the source that knows most about it (FR-DASH-4)."
  (let ((seen (make-hash-table :test #'equal))
        rows)
    (dolist (make (list
                   (mapcar #'ecc-dashboard--session-entry (ecc-model-sessions))
                   (mapcar #'ecc-dashboard--agent-entry ecc-dashboard--agents)
                   (mapcar #'ecc-dashboard--file-entry ecc-dashboard--recordings)))
      (dolist (entry make)
        (let ((key (ecc-dashboard-entry-key entry)))
          (unless (and key (gethash key seen))
            (when key (puthash key t seen))
            (push entry rows)))))
    (ecc-dashboard--sort (nreverse rows))))

(defun ecc-dashboard--sort (rows)
  "Return ROWS with the ones waiting for an answer first, then by time.
`sort' is destructive and ROWS is freshly made here, but the sessions
it was built from are not, so the list is copied (docs/verified.md)."
  (seq-sort (lambda (a b)
              (let ((wa (ecc-dashboard-entry-waiting a))
                    (wb (ecc-dashboard-entry-waiting b)))
                (cond ((not (eq (> wa 0) (> wb 0))) (> wa 0))
                      ((not (eq (ecc-dashboard-entry-kind a)
                                (ecc-dashboard-entry-kind b)))
                       (< (ecc-dashboard--kind-rank a)
                          (ecc-dashboard--kind-rank b)))
                      (t (ecc-dashboard--newer-p a b)))))
            rows))

(defun ecc-dashboard--kind-rank (entry)
  "Return the sort rank of the kind of ENTRY."
  (pcase (ecc-dashboard-entry-kind entry) ('own 0) ('external 1) (_ 2)))

(defun ecc-dashboard--newer-p (a b)
  "Return non-nil when row A was active more recently than row B."
  (let ((ta (ecc-dashboard-entry-time a))
        (tb (ecc-dashboard-entry-time b)))
    (cond ((and ta tb) (time-less-p tb ta))
          (ta t)
          (t nil))))

;;;; Drawing

(defun ecc-dashboard--kind-label (entry)
  "Return the kind of ENTRY as a short label."
  (pcase (ecc-dashboard-entry-kind entry)
    ('own "own") ('external "ext") (_ "arch")))

(defun ecc-dashboard--time-label (time)
  "Return TIME as a short label, or an empty string when it is nil."
  (if (null time)
      ""
    (let ((age (float-time (time-subtract (current-time) time))))
      (if (< age 86400)
          (format-time-string "%H:%M" time)
        (format-time-string "%m/%d" time)))))

(defun ecc-dashboard--row (entry)
  "Return the `tabulated-list-entries' row of ENTRY."
  (list entry
        (vector
         (ecc-dashboard--kind-label entry)
         (ecc--truncate (or (ecc-dashboard-entry-name entry) "") 24)
         (let ((state (or (ecc-dashboard-entry-state entry) "")))
           (if (> (ecc-dashboard-entry-waiting entry) 0)
               (propertize state 'face 'ecc-pending-face)
             state))
         (abbreviate-file-name (or (ecc-dashboard-entry-cwd entry) ""))
         (ecc--truncate (or (ecc-dashboard-entry-model entry) "") 20)
         (ecc--truncate (or (ecc-dashboard-entry-prompt entry) "") 60)
         (ecc-dashboard--time-label (ecc-dashboard-entry-time entry))
         (if (ecc-dashboard-entry-cost entry)
             (format "$%.2f" (ecc-dashboard-entry-cost entry))
           ""))))

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
    (define-key map (kbd "r") #'ecc-dashboard-rename)
    (define-key map (kbd "R") #'ecc-dashboard-resume)
    (define-key map (kbd "a") #'ecc-dashboard-allow)
    (define-key map (kbd "d") #'ecc-dashboard-deny)
    (define-key map (kbd "g") #'ecc-dashboard-refresh)
    map)
  "Keymap of `ecc-dashboard-mode'.")

(define-derived-mode ecc-dashboard-mode tabulated-list-mode "Claude-Sessions"
  "Major mode listing every Claude session Emacs can see.

\\{ecc-dashboard-mode-map}"
  :interactive nil
  (setq tabulated-list-format [("Kind" 5 t) ("Name" 24 t) ("State" 18 t)
                               ("cwd" 30 t) ("Model" 20 t) ("Last prompt" 40 t)
                               ("Updated" 7 t) ("Cost" 8 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'ecc-dashboard--collect nil t)
  (add-hook 'kill-buffer-hook #'ecc-dashboard--stop-timer nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun ecc-dashboard ()
  "Show every Claude session Emacs can see (FR-DASH-1)."
  (interactive)
  (let ((buffer (get-buffer-create ecc-dashboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-dashboard-mode)
        (ecc-dashboard-mode))
      (ecc-dashboard-refresh-recordings)
      (ecc-dashboard-refresh-agents)
      (ecc-dashboard--collect)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    (ecc-dashboard--start-watch)
    buffer))

(defun ecc-dashboard-redraw ()
  "Draw the dashboard again from what is already known."
  (when-let* ((buffer (get-buffer ecc-dashboard-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((point (point)))
          (ecc-dashboard--collect)
          (tabulated-list-print t)
          (goto-char (min point (point-max))))))))

(defun ecc-dashboard-refresh ()
  "Read every source again and draw the dashboard (FR-DASH-2)."
  (interactive)
  (ecc-dashboard-refresh-recordings)
  (ecc-dashboard-refresh-agents)
  (ecc-dashboard-redraw))

;;;; Keeping up with the registry (FR-DASH-6)

;; The registry directory is watched, which is what makes a session
;; started in a terminal appear here at once.  A file notification is a
;; courtesy rather than a promise, so a slow timer reads it again while
;; the dashboard is on screen (plan section 9, item 15).

(defun ecc-dashboard--start-watch ()
  "Watch the session registry and poll it slowly while the list is shown."
  (add-hook 'ecc-registry-changed-hook #'ecc-dashboard--registry-changed)
  (ecc-registry-watch)
  (unless ecc-dashboard--timer
    (setq ecc-dashboard--timer
          (run-at-time ecc-dashboard-poll-interval ecc-dashboard-poll-interval
                       #'ecc-dashboard--poll))))

(defun ecc-dashboard--stop-timer ()
  "Stop watching and polling the session registry."
  (remove-hook 'ecc-registry-changed-hook #'ecc-dashboard--registry-changed)
  (ecc-registry-unwatch)
  (when ecc-dashboard--timer
    (cancel-timer ecc-dashboard--timer)
    (setq ecc-dashboard--timer nil)))

(defun ecc-dashboard--registry-changed ()
  "Draw the dashboard again after a session started or stopped."
  (when (get-buffer ecc-dashboard-buffer-name)
    (ecc-dashboard-refresh-agents)
    (ecc-dashboard-redraw)))

(defun ecc-dashboard--poll ()
  "Read the registry again, or stop when the dashboard is gone.
Nothing is read while the dashboard is not shown anywhere."
  (let ((buffer (get-buffer ecc-dashboard-buffer-name)))
    (cond
     ((not (buffer-live-p buffer)) (ecc-dashboard--stop-timer))
     ((null (get-buffer-window buffer t)) nil)
     (t (ecc-dashboard-refresh-agents)
        (ecc-dashboard-redraw)))))

;;;; Commands

(defun ecc-dashboard-entry-at-point ()
  "Return the row at point, or signal an error."
  (let ((entry (tabulated-list-get-id)))
    (unless (ecc-dashboard-entry-p entry)
      (user-error "No session on this line"))
    entry))

(defun ecc-dashboard-session-at-point (&optional open)
  "Return the session of the row at point.
With OPEN, a row that is only a recording is read into a session
first (FR-DASH-3); without it, such a row returns nil."
  (let ((entry (ecc-dashboard-entry-at-point)))
    (or (ecc-dashboard-entry-session entry)
        (ecc-model-session (ecc-dashboard-entry-key entry))
        (when open
          (ecc-history-session (ecc-dashboard-entry-key entry)
                               (ecc-dashboard-entry-file entry))))))

(defun ecc-dashboard-visit ()
  "Open the session at point (FR-DASH-3).
A session of this Emacs shows its buffer.  A recording is read back
into one, at most `ecc-history-page-turns' turns of it.  A session
another process runs has no transcript here, so its recording is shown
read only and R offers to resume it."
  (interactive)
  (let* ((entry (ecc-dashboard-entry-at-point))
         (key (ecc-dashboard-entry-key entry)))
    (pcase (ecc-dashboard-entry-kind entry)
      ('own (let ((session (ecc-dashboard-entry-session entry)))
              (require 'ecc-window)
              (select-window (ecc-display-session session))))
      (_ (if (ecc-history-file key)
             (progn (ecc-history-open key)
                    (when (eq (ecc-dashboard-entry-kind entry) 'external)
                      (message
                       "Session of another process; R stops it and resumes here")))
           (user-error "%s has no recording" key))))))

(defun ecc-dashboard-new (directory)
  "Start a session in DIRECTORY (FR-DASH-5)."
  (interactive (list (read-directory-name "Directory: " (ecc-window-project-root))))
  (require 'ecc)
  (ecc-start directory)
  (ecc-dashboard-redraw))

(defun ecc-dashboard-stop ()
  "Stop the session at point (FR-DASH-5)."
  (interactive)
  (let ((session (or (ecc-dashboard-session-at-point)
                     (user-error "This session does not run in this Emacs"))))
    (require 'ecc)
    (ecc-kill session)
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-delete ()
  "Delete the recording of the session at point, after asking (FR-DASH-5)."
  (interactive)
  (let* ((entry (ecc-dashboard-entry-at-point))
         (file (or (ecc-dashboard-entry-file entry)
                   (ecc-history-file (ecc-dashboard-entry-key entry))
                   (user-error "This session has no recording"))))
    (when (yes-or-no-p (format "Delete %s? " (abbreviate-file-name file)))
      (delete-file file)
      (when-let* ((session (ecc-model-session (ecc-dashboard-entry-key entry))))
        (when (eq (ecc-session-kind session) 'archived)
          (ecc-model-remove-session session)))
      (ecc-dashboard-refresh))))

(defun ecc-dashboard-rename (name)
  "Rename the session at point to NAME (FR-DASH-5)."
  (interactive (list (read-string "New name: ")))
  (let ((session (or (ecc-dashboard-session-at-point)
                     (user-error "This session does not run in this Emacs"))))
    (when (string-empty-p name)
      (user-error "The name may not be empty"))
    (setf (ecc-session-name session) (ecc-model-unique-name name))
    (when (buffer-live-p (ecc-session-buffer session))
      (with-current-buffer (ecc-session-buffer session)
        (rename-buffer (format "*ecc: %s*" (ecc-session-name session)) t)))
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-resume ()
  "Resume the session at point (FR-DASH-3, FR-HIST-3).
A session another process runs has to be stopped there first: two CLIs
on one recording would each write their own version of it, which is
the exclusion of FR-TUI-5."
  (interactive)
  (let ((fork current-prefix-arg))
    ;; A session another process is running is refused by
    ;; `ecc-history-resume' unless the user insists (FR-TUI-5).
    (let ((session (or (ecc-dashboard-session-at-point t)
                       (user-error "This session has no recording"))))
      (ecc-history-resume session fork)
      (require 'ecc-window)
      (select-window (ecc-display-session session))
      (ecc-dashboard-redraw))))

(defun ecc-dashboard--request-at-point ()
  "Return the oldest request of the session at point, or signal an error."
  (let ((session (or (ecc-dashboard-session-at-point)
                     (user-error "This session does not run in this Emacs"))))
    (or (car (ecc-session-pending session))
        (user-error "%s is not waiting for an answer" (ecc-session-name session)))))

(defun ecc-dashboard-allow ()
  "Allow the oldest waiting request of the session at point (FR-DASH-4)."
  (interactive)
  (ecc-perm-allow-request (ecc-dashboard--request-at-point))
  (ecc-dashboard-redraw))

(defun ecc-dashboard-deny (reason)
  "Deny the oldest waiting request of the session at point with REASON."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (ecc-perm-respond (ecc-dashboard--request-at-point) 'deny :message reason)
  (ecc-dashboard-redraw))

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
