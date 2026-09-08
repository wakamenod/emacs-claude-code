;;; ecc-window.el --- Where the session buffers are shown  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.13 of IMPLEMENTATION_PLAN.md: which window a transcript is
;; shown in (FR-WIN-1), hiding and restoring them per project and per tab
;; (FR-WIN-2, FR-WIN-5), the name a session goes by (FR-WIN-3) and the
;; rule that decides which session a command sends to (FR-WIN-4).
;;
;; It also keeps track of the last buffer the user worked in that is not
;; part of this package, which is the source `ecc-context' quotes from.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'ecc-core)
(require 'ecc-model)

(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-session-buffer-name "ecc-session" (name))
(declare-function ecc-chat-goto-prompt "ecc-chat" ())

(defcustom ecc-window-use-side-window t
  "Non-nil shows a transcript in a side window rather than an ordinary one."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-window-side 'right
  "Side of the frame the transcript window is put on."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'ecc)

(defcustom ecc-window-width 0.4
  "Width of the transcript side window, as a fraction or a column count."
  :type 'number
  :group 'ecc)

(defcustom ecc-window-height 0.4
  "Height of the transcript side window when it is put on top or bottom."
  :type 'number
  :group 'ecc)

(defcustom ecc-window-ask-name-for-second-session t
  "Non-nil asks for a name when a project gets a second session (FR-WIN-3)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-window-remember-session-per-buffer t
  "Non-nil remembers in a buffer which session was chosen for it (FR-WIN-4)."
  :type 'boolean
  :group 'ecc)

(defvar-local ecc--bound-session-id nil
  "Id of the session this buffer sends to, once one has been chosen.")

;;;; Projects and names (FR-WIN-3)

(defun ecc-window-project-root (&optional directory)
  "Return the root of the project of DIRECTORY, or DIRECTORY itself.
DIRECTORY defaults to `default-directory' (plan section 6.13)."
  (let ((default-directory (or directory default-directory)))
    (or (when-let* ((project (project-current nil)))
          (file-name-as-directory (expand-file-name (project-root project))))
        (file-name-as-directory (expand-file-name default-directory)))))

(defun ecc-window-project-sessions (&optional root)
  "Return the sessions whose project is ROOT, most recently used first.
ROOT defaults to the project of the current buffer."
  (let ((root (or root (ecc-window-project-root))))
    (seq-filter (lambda (session)
                  (equal (ecc-session-project-root session) root))
                (ecc-model-sessions))))

(defun ecc-window-read-session-name (root)
  "Return a name for a new session in ROOT, asking when it is not the first.
The first session of a project is named after the directory; the ones
after it are told apart by a name the user gives (FR-WIN-3)."
  (when (and ecc-window-ask-name-for-second-session
             (ecc-window-project-sessions root))
    (let ((name (read-string
                 (format "Name of this %s session: "
                         (file-name-nondirectory (directory-file-name root))))))
      (unless (string-empty-p (string-trim name))
        (string-trim name)))))

(defun ecc-rename-session (session name)
  "Rename SESSION to NAME and rename its buffers with it (FR-WIN-3)."
  (interactive
   (let ((session (ecc-window-resolve-session current-prefix-arg)))
     (list session (read-string "New name: " (ecc-session-name session)))))
  (let ((name (ecc-model-unique-name (string-trim name))))
    (when (string-empty-p name)
      (user-error "The name is empty"))
    (setf (ecc-session-name session) name)
    (require 'ecc-session)
    (when (buffer-live-p (ecc-session-buffer session))
      (with-current-buffer (ecc-session-buffer session)
        (rename-buffer (ecc-session-buffer-name name) t)))
    (force-mode-line-update t)
    name))

;;;; The buffer the user came from

(defvar ecc-window--last-source-buffer nil
  "The last buffer selected that does not belong to this package.")

(defun ecc-window-buffer-session (&optional buffer)
  "Return the session BUFFER belongs to, or nil."
  (let ((buffer (or buffer (current-buffer))))
    (and (boundp 'ecc-render--session)
         (buffer-local-value 'ecc-render--session buffer))))

(defun ecc-window-own-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is one this package put on the screen."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (or (ecc-window-buffer-session buffer)
             (string-prefix-p "*ecc" (buffer-name buffer))))))

(defvar ecc-window--last-region nil
  "(BUFFER BEG END) of the last region seen in an ordinary buffer.
The mark of the buffer the user came from is not to be relied on at the
moment a prompt is sent: a command run in between deactivates it, and
`@region' then had nothing to quote though a region was plainly still
highlighted on the screen.  This is what it looked like while it lived.")

(defun ecc-window-buffer-region (&optional buffer)
  "Return (BUFFER BEG END) when BUFFER has a region to quote, or nil."
  (let ((buffer (or buffer (current-buffer))))
    (when (and (buffer-live-p buffer)
               (not (ecc-window-own-buffer-p buffer))
               (not (minibufferp buffer)))
      (with-current-buffer buffer
        (when (use-region-p)
          (list buffer (region-beginning) (region-end)))))))

(defun ecc-window--frame-region ()
  "Return the region of a buffer shown in some window, or nil."
  (seq-some (lambda (window) (ecc-window-buffer-region (window-buffer window)))
            (window-list)))

(defun ecc-window-snapshot-region ()
  "Remember the region of the buffer the user is leaving (FR-CTX-1)."
  (when-let* ((region (or (ecc-window-buffer-region ecc-window--last-source-buffer)
                          (ecc-window--frame-region))))
    (setq ecc-window--last-region region)))

(defun ecc-window--live-region (region)
  "Return REGION when its buffer is alive and its bounds still hold."
  (pcase region
    (`(,buffer ,beg ,end)
     (when (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (and (<= (point-min) beg) (< beg end) (<= end (point-max)))))
       region))))

(defun ecc-window-context-buffer ()
  "Return the buffer `@cursor' and `@diagnostics' read, or nil (FR-CTX-1).
The buffer the user last worked in first, then any ordinary buffer on
the screen, then the one a region was last seen in.  The first of those
is nil until `ecc-track-source-buffer-mode' has watched a buffer being
selected, which is not the case in an Emacs that only ever resumed a
session, so the two after it are what make the references work there."
  (or (ecc-window-last-source-buffer)
      (seq-find (lambda (buffer)
                  (and (not (ecc-window-own-buffer-p buffer))
                       (not (minibufferp buffer))
                       (not (string-prefix-p " " (buffer-name buffer)))))
                (mapcar #'window-buffer (window-list)))
      (car (ecc-window--live-region ecc-window--last-region))))

(defun ecc-window-active-region ()
  "Return (BUFFER BEG END) for `@region' and the like, or nil (FR-CTX-1).
The buffer the user last worked in is asked first, then any buffer on
the screen, and the snapshot of `ecc-window-snapshot-region' last: a
mark that died between choosing the region and sending the prompt is
the one failure this is here to survive."
  (or (ecc-window-buffer-region (ecc-window-last-source-buffer))
      (ecc-window--frame-region)
      (ecc-window--live-region ecc-window--last-region)))

(defun ecc-window-note-source-buffer (&rest _)
  "Remember the current buffer as the source to quote from (FR-CTX-1)."
  ;; The region is taken down before the buffer is, because the buffer
  ;; being left is still the one recorded here.
  (ecc-window-snapshot-region)
  (let ((buffer (window-buffer (selected-window))))
    (unless (or (ecc-window-own-buffer-p buffer)
                (minibufferp buffer)
                (string-prefix-p " " (buffer-name buffer)))
      (setq ecc-window--last-source-buffer buffer))))

(defun ecc-window-last-source-buffer ()
  "Return the buffer to take file, line and region from (FR-CTX-1).
That is the current buffer when it is an ordinary one, and otherwise
the last ordinary buffer that was selected."
  (cond ((not (ecc-window-own-buffer-p)) (current-buffer))
        ((buffer-live-p ecc-window--last-source-buffer)
         ecc-window--last-source-buffer)))

(define-minor-mode ecc-track-source-buffer-mode
  "Follow which ordinary buffer the user last worked in (FR-CTX-1).
The commands that quote code into a prompt need it: by the time one of
them runs, the current buffer may be a transcript or a prompt."
  :global t
  :group 'ecc
  (if ecc-track-source-buffer-mode
      (progn
        (add-hook 'window-selection-change-functions #'ecc-window-note-source-buffer)
        (add-hook 'window-buffer-change-functions #'ecc-window-note-source-buffer))
    (remove-hook 'window-selection-change-functions #'ecc-window-note-source-buffer)
    (remove-hook 'window-buffer-change-functions #'ecc-window-note-source-buffer)))

;;;; Showing and hiding (FR-WIN-1, FR-WIN-2, FR-WIN-5)

(defvar ecc-window--slots nil
  "Alist of session id and the side window slot it was given.")

(defun ecc-window-slot (session)
  "Return the side window slot of SESSION, giving it one if it has none.
Sessions keep their slot for as long as they live, so that a redisplay
does not shuffle the windows around."
  (let ((id (ecc-session-id session)))
    (or (cdr (assoc id ecc-window--slots))
        (let ((slot (1+ (apply #'max -1 (mapcar #'cdr ecc-window--slots)))))
          (push (cons id slot) ecc-window--slots)
          slot))))

(defun ecc-window--side-parameters (slot)
  "Return the display action alist for SLOT."
  (let ((horizontal (memq ecc-window-side '(left right))))
    `((side . ,ecc-window-side)
      (slot . ,slot)
      ,@(if horizontal
            `((window-width . ,ecc-window-width))
          `((window-height . ,ecc-window-height))))))

(defun ecc-display-session (session)
  "Show the buffer of SESSION and return its window.
The window is not selected; `ecc-window-select-session' does that."
  (require 'ecc-session)
  (let ((buffer (ecc-session-ensure-buffer session)))
    (if ecc-window-use-side-window
        (display-buffer-in-side-window
         buffer (ecc-window--side-parameters (ecc-window-slot session)))
      (display-buffer buffer))))

(defun ecc-window-select-session (session)
  "Show the buffer of SESSION, select its window and go to the prompt.
That is where something can be typed, which is what showing a session
is usually for (FR-WIN-1)."
  (let ((window (ecc-display-session session)))
    (when (window-live-p window)
      (select-window window)
      (ecc-chat-goto-prompt))
    window))

;;;; Opening a review (FR-WIN-5)

;; A diff or a plan wants room, and the session windows are what there
;; is to take it from.  What happens is the user's to decide: whether
;; the session windows step aside, and where point ends up.

(defcustom ecc-window-hide-on-review nil
  "Whether opening a diff or a plan review hides the session windows.
`project' hides the sessions of the project being reviewed, `all'
hides every session, and nil leaves the windows as they are
\(FR-WIN-5).  `ecc-toggle' brings back what was hidden."
  :type '(choice (const :tag "Leave them alone" nil)
                 (const :tag "The sessions of this project" project)
                 (const :tag "Every session" all))
  :group 'ecc)

(defcustom ecc-window-review-focus 'review
  "Where point goes when a diff or a plan review opens (FR-WIN-5).
`review' selects the review, `session' leaves it in the transcript and
nil leaves it wherever it was."
  :type '(choice (const :tag "The review" review)
                 (const :tag "The transcript" session)
                 (const :tag "Wherever it was" nil))
  :group 'ecc)

(defun ecc-window-display-review (buffer &optional session)
  "Show the review in BUFFER, of SESSION, and return its window.
`ecc-window-hide-on-review' and `ecc-window-review-focus' decide what
happens to the session windows and where point lands (FR-WIN-5)."
  (let ((hidden (pcase ecc-window-hide-on-review
                  ('all (ecc-model-sessions))
                  ('project (if session
                                (ecc-window-project-sessions
                                 (ecc-session-project-root session))
                              (ecc-window-project-sessions)))
                  (_ nil))))
    (when hidden
      (let ((visible (seq-filter #'ecc-window-session-visible-p hidden)))
        (when visible
          (ecc-window-set-hidden-sessions (mapcar #'ecc-session-id visible))
          (mapc #'ecc-window-hide-session visible))))
    (let ((window (display-buffer buffer)))
      (pcase ecc-window-review-focus
        ('review (when (window-live-p window) (select-window window)))
        ('session
         (when-let* ((buffer (and session (ecc-session-buffer session)))
                     (session-window (and (buffer-live-p buffer)
                                          (get-buffer-window buffer))))
           (select-window session-window))))
      window)))

(defun ecc-window-session-buffers (session)
  "Return the live buffers of SESSION that are shown in a window of their own."
  (seq-filter #'buffer-live-p
              (list (ecc-session-buffer session))))

(defun ecc-window-session-visible-p (session &optional frame)
  "Return non-nil when a buffer of SESSION is shown on FRAME."
  (seq-some (lambda (buffer) (get-buffer-window buffer (or frame nil)))
            (ecc-window-session-buffers session)))

(defun ecc-window-hide-session (session)
  "Take the windows of SESSION off the screen without killing its buffers."
  (dolist (buffer (ecc-window-session-buffers session))
    (dolist (window (get-buffer-window-list buffer nil nil))
      (when (and (window-live-p window)
                 (not (eq window (frame-root-window window))))
        (delete-window window)))))

(defun ecc-window--layout-key ()
  "Return the key the hidden session list is stored under.
With `tab-bar-mode' on, every tab keeps its own layout, so the hidden
list is per tab as well (FR-WIN-5)."
  (or (and (bound-and-true-p tab-bar-mode)
           (fboundp 'tab-bar--current-tab)
           (alist-get 'name (tab-bar--current-tab)))
      'frame))

(defun ecc-window-hidden-sessions ()
  "Return the ids of the sessions hidden by `ecc-toggle' here."
  (alist-get (ecc-window--layout-key)
             (frame-parameter nil 'ecc-hidden-sessions) nil nil #'equal))

(defun ecc-window-set-hidden-sessions (ids)
  "Remember IDS as the sessions hidden by `ecc-toggle' here."
  (let ((alist (frame-parameter nil 'ecc-hidden-sessions)))
    (setf (alist-get (ecc-window--layout-key) alist nil nil #'equal) ids)
    (set-frame-parameter nil 'ecc-hidden-sessions alist)
    ids))

;;;###autoload
(defun ecc-toggle (&optional all)
  "Hide the session windows of this project, or bring back the hidden ones.
With ALL, a prefix argument interactively, every session is toggled
rather than the ones of the current project (FR-WIN-2)."
  (interactive "P")
  (let* ((sessions (if all (ecc-model-sessions)
                     (ecc-window-project-sessions)))
         (visible (seq-filter #'ecc-window-session-visible-p sessions)))
    (cond
     (visible
      (ecc-window-set-hidden-sessions (mapcar #'ecc-session-id visible))
      (mapc #'ecc-window-hide-session visible)
      (message "Hid %d sessions" (length visible)))
     (t
      (let ((shown (seq-filter
                    #'identity
                    (mapcar #'ecc-model-session
                            (or (ecc-window-hidden-sessions)
                                (mapcar #'ecc-session-id sessions))))))
        (if (null shown)
            (message "No session to show")
          (mapc #'ecc-display-session shown)
          (ecc-window-set-hidden-sessions nil)
          (message "Showing %d sessions" (length shown)))
        shown)))))

;;;###autoload
(defun ecc-toggle-all ()
  "Hide or restore the session windows of every project (FR-WIN-2)."
  (interactive)
  (ecc-toggle t))

;;;; Which session a command talks to (FR-WIN-4)

(defun ecc-window-displayed-sessions (&optional frame)
  "Return the sessions with a window on FRAME."
  (seq-filter (lambda (session) (ecc-window-session-visible-p session frame))
              (ecc-model-sessions)))

(defun ecc-window-session-label (session)
  "Return the line SESSION is offered under when there is a choice."
  (format "%-24s  %-8s %s"
          (ecc--truncate (ecc-session-name session) 24)
          (or (ecc-session-state session) "")
          (abbreviate-file-name (or (ecc-session-project-root session) ""))))

(defun ecc-window-read-session (&optional prompt sessions)
  "Ask which of SESSIONS to use, with PROMPT.
SESSIONS defaults to every live session, most recently used first."
  (let ((sessions (or sessions (ecc-model-sessions))))
    (cond
     ((null sessions) (user-error "No session is running"))
     ((null (cdr sessions)) (car sessions))
     (t (let* ((labels (mapcar (lambda (session)
                                 (cons (ecc-window-session-label session) session))
                               sessions))
               (choice (completing-read (or prompt "Session: ")
                                        (mapcar #'car labels) nil t)))
          (cdr (assoc choice labels)))))))

(defun ecc-window-bound-session ()
  "Return the session this buffer was told to send to, or nil."
  (and ecc--bound-session-id (ecc-model-session ecc--bound-session-id)))

(defun ecc-window-resolve-session (&optional force-ask)
  "Return the session a command in this buffer should talk to (FR-WIN-4).
The order is: the session of this buffer, the session this buffer was
bound to before, the only session of this project, the only session on
screen, the most recently used one.  FORCE-ASK, a prefix argument in
the commands that take one, always asks; the answer is remembered in
the buffer."
  (or (ecc-window-buffer-session)
      (and (not force-ask)
           (or (ecc-window-bound-session)
               (let ((project (ecc-window-project-sessions)))
                 (and project (null (cdr project)) (car project)))
               (let ((shown (ecc-window-displayed-sessions)))
                 (and shown (null (cdr shown)) (car shown)))
               (car (ecc-model-sessions))))
      (let ((session (ecc-window-read-session "Send to: ")))
        (when (and session ecc-window-remember-session-per-buffer)
          (setq-local ecc--bound-session-id (ecc-session-id session)))
        session)))

(defun ecc-window-forget-session (session)
  "Forget the slot and the hidden entry SESSION had."
  (setq ecc-window--slots
        (assoc-delete-all (ecc-session-id session) ecc-window--slots)))

(provide 'ecc-window)

;;; ecc-window.el ends here
