;;; ecc-window.el --- Where the session buffers are shown  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Which window a transcript is shown in, hiding and restoring them per
;; project and per tab, the name a session goes by and the rule that
;; decides which session a command sends to.
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

(defvar ecc-window-use-side-window t
  "Non-nil shows a transcript in a side window rather than an ordinary one.
Nil falls back to a plain `display-buffer', which gives up the window
roles -- main, sub-1, sub-2 -- and the tab line that goes with them.  It
is a way out rather than a supported layout.")

(defvar ecc-window-side 'right
  "Side of the frame the transcript window is put on.
`ecc-display-session-in-role' calls `display-buffer-in-side-window'
outright, so `display-buffer-alist' is never consulted for a transcript
and this is the way to move one (decided 2026-09-10).")

(defvar ecc-window-width 0.4
  "Width of the transcript side window, as a fraction or a column count.")

(defvar ecc-window-height 0.4
  "Height of the transcript side window when it is put on top or bottom.")

(defcustom ecc-window-large-frame-min-height 80
  "Height, in lines, a frame needs before it gets a third session window.
Below it the sessions share two windows and the tab line reaches the
rest.  The default tells a laptop from a large display: a 14-inch screen
holds around 58 lines and a 16-inch one around 67, while the display
this was measured on holds 114."
  :type 'integer
  :group 'ecc)

(defcustom ecc-window-sub-height 0.33
  "Height of the third session window, as a fraction or a line count.
It is taken from the main area of the frame -- the source code, usually
-- rather than from the side the other two are on.

Which side the other two stand on, and how wide they are, is
`ecc-window-side' and `ecc-window-width'; both are plain variables to
`setq' rather than settings."
  :type 'number
  :group 'ecc)

(defvar ecc-window-ask-name-for-second-session t
  "Non-nil asks for a name when a project gets a second session.")

(defvar ecc-window-remember-session-per-buffer t
  "Non-nil remembers in a buffer which session was chosen for it.")

(defvar-local ecc--bound-session-id nil
  "Id of the session this buffer sends to, once one has been chosen.")

;;;; Projects and names

(defun ecc-window-project-root (&optional directory)
  "Return the root of the project of DIRECTORY, or DIRECTORY itself.
DIRECTORY defaults to `default-directory'."
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
after it are told apart by a name the user gives."
  (when (and ecc-window-ask-name-for-second-session
             (ecc-window-project-sessions root))
    (let ((name (read-string
                 (format "Name of this %s session: "
                         (file-name-nondirectory (directory-file-name root))))))
      (unless (string-empty-p (string-trim name))
        (string-trim name)))))

(defun ecc-rename-session (session name)
  "Rename SESSION to NAME and rename its buffers with it."
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
  "Remember the region of the buffer the user is leaving."
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
  "Return the buffer `@cursor' and `@diagnostics' read, or nil.
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
  "Return (BUFFER BEG END) for `@region' and the like, or nil.
The buffer the user last worked in is asked first, then any buffer on
the screen, and the snapshot of `ecc-window-snapshot-region' last: a
mark that died between choosing the region and sending the prompt is
the one failure this is here to survive."
  (or (ecc-window-buffer-region (ecc-window-last-source-buffer))
      (ecc-window--frame-region)
      (ecc-window--live-region ecc-window--last-region)))

(defun ecc-window-note-source-buffer (&rest _)
  "Remember the current buffer as the source to quote from."
  ;; The region is taken down before the buffer is, because the buffer
  ;; being left is still the one recorded here.
  (ecc-window-snapshot-region)
  (let ((buffer (window-buffer (selected-window))))
    (unless (or (ecc-window-own-buffer-p buffer)
                (minibufferp buffer)
                (string-prefix-p " " (buffer-name buffer)))
      (setq ecc-window--last-source-buffer buffer))))

(defun ecc-window-last-source-buffer ()
  "Return the buffer to take file, line and region from.
That is the current buffer when it is an ordinary one, and otherwise
the last ordinary buffer that was selected."
  (cond ((not (ecc-window-own-buffer-p)) (current-buffer))
        ((buffer-live-p ecc-window--last-source-buffer)
         ecc-window--last-source-buffer)))

(define-minor-mode ecc-track-source-buffer-mode
  "Follow which ordinary buffer the user last worked in.
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

;;;; Showing and hiding

;; This package puts three windows on the screen at the most: `main' at
;; the near end of the side, `sub-1' after it, and `sub-2' under the
;; main area of the frame -- the source code, usually -- on a frame with
;; the height to spare.  A session past that gets no window of its own:
;; it takes over a sub window, and the tab line is how the ones that are
;; not on the screen are reached.
;;
;; Which window has which role is written on the window itself, in the
;; `ecc-window-role' parameter, rather than kept in a table here: the
;; user closes windows, and a table of our own would go stale.

(defconst ecc-window-roles '(main sub-1 sub-2)
  "The roles a window of this package can have, in the order they fill.")

(defvar ecc-window--last-sub nil
  "The sub role the last session was given, so that the next one alternates.")

(defun ecc-window-large-frame-p (&optional frame)
  "Return non-nil when FRAME has the room for a third session window."
  (>= (frame-height frame) ecc-window-large-frame-min-height))

(defun ecc-window-available-roles (&optional frame)
  "Return the roles FRAME has the room for, in the order they fill.
A frame that is not tall enough goes without `sub-2'."
  (if (ecc-window-large-frame-p frame)
      ecc-window-roles
    (remq 'sub-2 ecc-window-roles)))

(defun ecc-window--role-window (role &optional frame)
  "Return the live window carrying ROLE on FRAME, or nil."
  (seq-find (lambda (window)
              (eq (window-parameter window 'ecc-window-role) role))
            (window-list frame 'no-minibuffer)))

(defun ecc-window--role-free-p (role &optional frame)
  "Return non-nil when no session holds ROLE on FRAME.
A window some other buffer borrowed -- a review, say -- counts as free:
the session that was in it has left the screen already."
  (let ((window (ecc-window--role-window role frame)))
    (or (null window)
        (not (ecc-window-buffer-session (window-buffer window))))))

(defun ecc-window--session-role (session &optional frame)
  "Return the role of the window SESSION is shown in on FRAME, or nil."
  (let ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (seq-find (lambda (role)
                  (let ((window (ecc-window--role-window role frame)))
                    (and window (eq (window-buffer window) buffer))))
                ecc-window-roles))))

(defun ecc-window--next-sub (&optional frame)
  "Return the sub role for the next session on FRAME, taking the subs in turn.
Asking does not move the turn along: only a session that really goes
into a sub window does that, in `ecc-display-session-in-role'."
  (let ((subs (remq 'main (ecc-window-available-roles frame))))
    (or (cadr (memq ecc-window--last-sub subs)) (car subs))))

(defun ecc-window-role-for (session &optional frame)
  "Return the role the window of SESSION should have on FRAME.
The window it is in already wins; then the first role standing empty;
then a sub window, the two being taken in turn.  `main' is never taken
from the session that holds it: only the user moves that one, by
clicking a tab or with `ecc-switch-session'."
  (or (ecc-window--session-role session frame)
      (seq-find (lambda (role) (ecc-window--role-free-p role frame))
                (ecc-window-available-roles frame))
      (ecc-window--next-sub frame)))

(defun ecc-window--side-parameters (role)
  "Return the display action alist of the side window of ROLE."
  (let ((horizontal (memq ecc-window-side '(left right))))
    `((side . ,ecc-window-side)
      (slot . ,(if (eq role 'main) 0 1))
      (window-parameters . ((ecc-window-role . ,role)))
      ,@(if horizontal
            `((window-width . ,ecc-window-width))
          `((window-height . ,ecc-window-height))))))

(defun ecc-window--sub-2-parameters ()
  "Return the display action alist of the third window.
It is not a side window: a side window at the bottom would run the
whole width of the frame and pass under the other two.  This one takes
its room from the main area instead, which leaves the side alone.  It
is left undedicated on purpose, so that a review may borrow it and
`quit-window' hand it back."
  `((direction . below)
    (window . main)
    (window-height . ,ecc-window-sub-height)
    (window-parameters . ((ecc-window-role . sub-2)))))

(defun ecc-display-session-in-role (session role)
  "Show the buffer of SESSION in the window of ROLE and return that window.
A window that is there already keeps its place: what is in it is
replaced rather than a second window being opened."
  (require 'ecc-session)
  (when (memq role '(sub-1 sub-2))
    (setq ecc-window--last-sub role))
  (let ((buffer (ecc-session-ensure-buffer session))
        (window (ecc-window--role-window role)))
    (cond
     ;; `set-window-buffer' would do, but it drops the `side' dedication
     ;; of a side window, and an undedicated side window is the next
     ;; thing `display-buffer' takes.  Asking for the side window again
     ;; reuses the same one and leaves it dedicated.
     ((eq role 'sub-2)
      (if (window-live-p window)
          (progn (set-window-buffer window buffer)
                 (set-window-parameter window 'ecc-window-role role)
                 window)
        (display-buffer-in-direction buffer (ecc-window--sub-2-parameters))))
     (t
      (display-buffer-in-side-window
       buffer (ecc-window--side-parameters role))))))

(defun ecc-display-session (session)
  "Show the buffer of SESSION and return its window.
The window is not selected; `ecc-window-select-session' does that."
  (require 'ecc-session)
  (if (not ecc-window-use-side-window)
      (display-buffer (ecc-session-ensure-buffer session))
    (ecc-display-session-in-role session (ecc-window-role-for session))))

;;;; Keeping a side window a side window

(defun ecc-window-repair-side-windows (&optional frame)
  "Give back the dedication a session side window lost.
Both `switch-to-buffer', which is how the tab line changes what a
window shows, and `set-window-buffer' clear the `side' dedication of a
side window, and an undedicated side window is the next one
`display-buffer' takes over -- geometry and all.  This puts it back.
FRAME is what `window-buffer-change-functions' passes."
  (dolist (window (window-list (and (framep frame) frame) 'no-minibuffer))
    (when (and (memq (window-parameter window 'ecc-window-role) '(main sub-1))
               (window-parameter window 'window-side)
               (not (window-dedicated-p window)))
      (set-window-dedicated-p window 'side))))

(defun ecc-window-select-session (session)
  "Show the buffer of SESSION, select its window and go to the prompt.
That is where something can be typed, which is what showing a session
is usually for."
  (let ((window (ecc-display-session session)))
    (when (window-live-p window)
      (select-window window)
      (ecc-chat-goto-prompt))
    window))

;;;; Opening a review

;; A diff or a plan wants room, and the session windows are what there
;; is to take it from.  What happens is the user's to decide: whether
;; the session windows step aside, and where point ends up.

(defvar ecc-window-hide-on-review nil
  "Whether opening a diff or a plan review hides the session windows.
`project' hides the sessions of the project being reviewed, `all' hides
every session, and nil leaves the windows as they are.  `ecc-toggle'
brings back what was hidden.")

(defvar ecc-window-review-focus 'review
  "Where point goes when a diff or a plan review opens.
`review' selects the review, `session' leaves it in the transcript and
nil leaves it wherever it was.")

(defun ecc-window-display-review (buffer &optional session)
  "Show the review in BUFFER, of SESSION, and return its window.
`ecc-window-hide-on-review' and `ecc-window-review-focus' decide what
happens to the session windows and where point lands."
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
          (ecc-window-set-hidden-sessions (ecc-window--hidden-entries visible))
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
list is per tab as well."
  (or (and (bound-and-true-p tab-bar-mode)
           (fboundp 'tab-bar--current-tab)
           (alist-get 'name (tab-bar--current-tab)))
      'frame))

(defun ecc-window-hidden-sessions ()
  "Return the sessions hidden by `ecc-toggle' here, as (ID . ROLE) pairs.
The role goes with the id so that restoring puts every session back in
the window it came from, rather than dealing them out again."
  (alist-get (ecc-window--layout-key)
             (frame-parameter nil 'ecc-hidden-sessions) nil nil #'equal))

(defun ecc-window-set-hidden-sessions (entries)
  "Remember ENTRIES, a list of (ID . ROLE), as hidden by `ecc-toggle' here."
  (let ((alist (frame-parameter nil 'ecc-hidden-sessions)))
    (setf (alist-get (ecc-window--layout-key) alist nil nil #'equal) entries)
    (set-frame-parameter nil 'ecc-hidden-sessions alist)
    entries))

(defun ecc-window--hidden-entries (sessions)
  "Return the (ID . ROLE) pairs to remember for SESSIONS before hiding them."
  (mapcar (lambda (session)
            (cons (ecc-session-id session) (ecc-window--session-role session)))
          sessions))

(defun ecc-window--restore-hidden (entries)
  "Show again the sessions of ENTRIES, each in the role it had.
Return the sessions that were shown."
  (delq nil
        (mapcar (lambda (entry)
                  (when-let* ((session (ecc-model-session (car entry))))
                    (if (and (cdr entry) ecc-window-use-side-window)
                        (ecc-display-session-in-role session (cdr entry))
                      (ecc-display-session session))
                    session))
                entries)))

;;;###autoload
(defun ecc-toggle (&optional all)
  "Hide the session windows of this project, or bring back the hidden ones.
With ALL, a prefix argument interactively, every session is toggled
rather than the ones of the current project."
  (interactive "P")
  (let* ((sessions (if all (ecc-model-sessions)
                     (ecc-window-project-sessions)))
         (visible (seq-filter #'ecc-window-session-visible-p sessions)))
    (cond
     (visible
      (ecc-window-set-hidden-sessions (ecc-window--hidden-entries visible))
      (mapc #'ecc-window-hide-session visible)
      (message "Hid %d sessions" (length visible)))
     (t
      (let* ((entries (or (ecc-window-hidden-sessions)
                          (mapcar (lambda (session)
                                    (cons (ecc-session-id session) nil))
                                  sessions)))
             (shown (ecc-window--restore-hidden entries)))
        (if (null shown)
            (message "No session to show")
          (ecc-window-set-hidden-sessions nil)
          (message "Showing %d sessions" (length shown)))
        shown)))))

;;;###autoload
(defun ecc-toggle-all ()
  "Hide or restore the session windows of every project."
  (interactive)
  (ecc-toggle t))

;;;; Which session a command talks to

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
  "Return the session a command in this buffer should talk to.
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
  "Forget the hidden entry SESSION had.
The role it held needs no forgetting: it is written on the window, and
the window goes with the buffer."
  (let ((id (ecc-session-id session))
        (alist (frame-parameter nil 'ecc-hidden-sessions)))
    (dolist (layout alist)
      (setcdr layout (assoc-delete-all id (cdr layout))))
    (set-frame-parameter nil 'ecc-hidden-sessions alist)))

;;;; Switching a window to another session

(defun ecc-window--switch-target ()
  "Return the window `ecc-switch-session' should change.
The current window when it is one of ours, and `main' otherwise: a
command run from the source code means the session one is looking at."
  (let ((window (selected-window)))
    (if (window-parameter window 'ecc-window-role)
        window
      (ecc-window--role-window 'main))))

;;;###autoload
(defun ecc-switch-session (session)
  "Show SESSION in this window, the way clicking its tab would.
Which session a window shows is the user's to choose: this is the same
choice the tab line offers, for when the tabs are not to hand."
  (interactive (list (ecc-window-read-session "Switch to: ")))
  (require 'ecc-session)
  (let ((window (ecc-window--switch-target)))
    (if (not (window-live-p window))
        (ecc-window-select-session session)
      (set-window-buffer window (ecc-session-ensure-buffer session))
      (ecc-window-repair-side-windows (window-frame window))
      (select-window window)
      (ecc-chat-goto-prompt)
      window)))

;; The tab line changes what a window shows with `switch-to-buffer',
;; which costs a side window its dedication; so does anything else the
;; user does in one.  Nothing else puts it back, so this watches.
(add-hook 'window-buffer-change-functions #'ecc-window-repair-side-windows)

(provide 'ecc-window)

;;; ecc-window.el ends here
