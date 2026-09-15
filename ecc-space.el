;;; ecc-space.el --- One tab per project, and what lives in it  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A Space is a project -- a repository, or a worktree of one -- with a
;; tab of the tab bar to itself.  This is the `spaces' value of
;; `ecc-layout'; with `classic' nothing here is called except by whoever
;; asks for it outright.
;;
;; What a Space buys over `ecc-focus-project' is that the arrangement is
;; kept.  Focusing deals the session windows out again every time, which
;; is the right thing when the windows have roles; here they have none,
;; so a transcript the user split, moved or made wider stays that way,
;; and going to another Space and back brings it all back, because a tab
;; is a window configuration.
;;
;; The model -- what the Spaces are, how they are ordered, what state
;; each is in -- knows nothing about tab-bar and is worked out from the
;; sessions and from git alone.  The tab-bar part underneath it is kept
;; thin on purpose.
;;
;; A Space is found again by the NAME of its tab and not by a key on the
;; tab: whether Emacs 29.1 carries a key of one's own through the places
;; it rebuilds a tab is not something this package has checked (32.0.50
;; does carry it, verified 2026-09-14), and a name is carried by every
;; version there is.
;;
;; The ordering of parents and children is herdr's `workspace_entries'
;; (src/client/shell/sidebar.rs:443-528), so that the two lay a
;; repository out the same way.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-bar)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-window)
(require 'ecc-worktree)
(require 'ecc-notify)

(declare-function ecc-render--project-name-1 "ecc-render" (directory))
(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-start "ecc" (&optional directory name))
(declare-function dired-noselect "dired" (dir-or-list &optional switches))
(declare-function ecc-sidebar-show "ecc-sidebar" ())

;;;; Settings

(defcustom ecc-space-session-min-width 80
  "Columns a session window needs before the row is divided again.
The sessions of a Space stand side by side and are never stacked, so
this is what says how many fit: a row with no room for another column
this wide gives the new session a window that is already there rather
than making every transcript narrower.  `window-min-width' is a floor
under it; a smaller number buys nothing, Emacs refusing the split.

It is a setting because it is a screen: the number of transcripts that
can be read at once on a 13-inch laptop and on a 34-inch display is not
the same number."
  :type 'integer
  :group 'ecc)

;;;; The model

(cl-defstruct ecc-space
  key     ; `ecc-window-project-key' of the root: what groups the sessions
  root    ; the directory, as `file-name-as-directory'
  name    ; what the sidebar and the tab call it
  parent  ; key of the main worktree when this is a linked worktree, else nil
  branch) ; the branch checked out there, or nil

(defvar ecc-space--used nil
  "Alist of a Space key to when it was last selected.
Only for the Spaces that have no session: `ecc-window-session-projects'
already puts the rest in the order they were worked in, and a Space
with a tab and nothing running in it would otherwise have no place in
that order at all.")

(defun ecc-space--name (root parent branch)
  "Return what a Space at ROOT with PARENT and BRANCH is called.
A worktree goes by its branch, which is what tells two checkouts of one
repository apart -- the directory name is a slug of that branch and
says nothing more.  The `worktree/' that herdr puts in front of the
branches it generates is dropped, as it drops it."
  (require 'ecc-render)
  (if (and parent branch)
      (string-remove-prefix "worktree/" branch)
    (ecc-render--project-name-1 root)))

(defun ecc-space-of-root (root)
  "Return the Space of the project ROOT belongs to."
  (let* ((key (ecc-window-project-key root))
         (main (ecc-worktree-main key))
         (parent (and main (ecc-window-project-key main)))
         (branch (ecc-worktree-branch key)))
    (make-ecc-space :key key :root key
                    :name (ecc-space--name key parent branch)
                    :parent parent :branch branch)))

(defun ecc-space--keys ()
  "Return the project keys that have a Space, the ones worked in first.
A project has a Space when a session of it is running or when a tab was
opened for it; a tab with nothing running in it keeps the place it was
last selected in, after everything that has a session."
  (let ((keys (ecc-window-session-projects))
        (idle (sort (seq-remove (lambda (key)
                                  (member key (ecc-window-session-projects)))
                                (ecc-space--tab-keys))
                    (lambda (a b)
                      (> (or (alist-get a ecc-space--used 0 nil #'equal) 0)
                         (or (alist-get b ecc-space--used 0 nil #'equal) 0))))))
    (append keys idle)))

(defun ecc-space-list ()
  "Return every Space there is, a parent before the children under it.
A child whose parent has no Space stands on its own, in the place its
own project holds; the rest follow their parent in the order they were
worked in.  This is what numbers the Spaces and what the sidebar draws
down the screen."
  (let* ((keys (ecc-space--keys))
         (spaces (mapcar #'ecc-space-of-root keys))
         (ordered nil))
    (dolist (space spaces)
      (unless (member (ecc-space-parent space) keys)
        (push space ordered)
        (dolist (child spaces)
          (when (equal (ecc-space-parent child) (ecc-space-key space))
            (push child ordered)))))
    (nreverse ordered)))

(defun ecc-space-child-p (space &optional spaces)
  "Return non-nil when SPACE is drawn under a parent among SPACES.
A worktree whose repository has no Space of its own is not a child of
anything on the screen, however much git says about where it came
from.  SPACES defaults to `ecc-space-list'."
  (and (ecc-space-parent space)
       (seq-find (lambda (other)
                   (equal (ecc-space-key other) (ecc-space-parent space)))
                 (or spaces (ecc-space-list)))
       t))

(defun ecc-space-number (space &optional spaces)
  "Return the place SPACE holds among SPACES, counting from one.
Children are counted with the rest: the number is what `ecc-space-jump'
takes and what the sidebar puts in front of every row.  SPACES defaults
to `ecc-space-list'."
  (when-let* ((spaces (or spaces (ecc-space-list)))
              (index (seq-position spaces (ecc-space-key space)
                                   (lambda (other key)
                                     (equal (ecc-space-key other) key)))))
    (1+ index)))

(defun ecc-space-sessions (space)
  "Return the sessions running in SPACE, most recently used first."
  (ecc-window-project-sessions (ecc-space-root space)))

(defun ecc-space-state (space)
  "Return the one state that stands for the sessions of SPACE, or nil."
  (ecc-tab-state-roll-up (ecc-space-sessions space)))

(defun ecc-space-equal (a b)
  "Return non-nil when the Spaces A and B are the same one."
  (and a b (equal (ecc-space-key a) (ecc-space-key b))))

;;;; The tabs underneath

(defvar ecc-space--tabs nil
  "Alist of a Space key to the name of the tab it lives in.")

(defun ecc-space--tab-index (name)
  "Return the index of the tab called NAME, or nil."
  (and name (tab-bar--tab-index-by-name name)))

(defun ecc-space--tab-keys ()
  "Return the Space keys that still have a tab, in the order of the alist."
  (delq nil (mapcar (lambda (entry)
                      (and (ecc-space--tab-index (cdr entry)) (car entry)))
                    ecc-space--tabs)))

(defun ecc-space-tab (space)
  "Return the name of the tab of SPACE, or nil.
A tab the user closed is forgotten here rather than offered again."
  (let ((name (alist-get (ecc-space-key space) ecc-space--tabs nil nil #'equal)))
    (cond ((ecc-space--tab-index name) name)
          (name (setf (alist-get (ecc-space-key space) ecc-space--tabs
                                 nil 'remove #'equal)
                      nil)
                nil))))

(defun ecc-space--unique-tab-name (base)
  "Return BASE, or BASE with a suffix when a tab already goes by it.
Two worktrees of two repositories are called `main' as often as not."
  (let ((name base)
        (n 1))
    (while (ecc-space--tab-index name)
      (setq n (1+ n)
            name (format "%s<%d>" base n)))
    name))

(defun ecc-space--forget-tab (tab &rest _)
  "Forget the Space of TAB, which is about to be closed.
On `tab-bar-tab-pre-close-functions'.  Nothing is stopped: the sessions
go on running with no window, which is what `ecc-toggle' and the
sidebar bring back."
  (when-let* ((name (alist-get 'name tab))
              (key (car (rassoc name ecc-space--tabs))))
    (setf (alist-get key ecc-space--tabs nil 'remove #'equal) nil)))

(add-hook 'tab-bar-tab-pre-close-functions #'ecc-space--forget-tab)

(defvar ecc-space--laying-out nil
  "Non-nil while a Space is being dealt its windows for the first time.")

(defun ecc-space--lay-out-sessions (space)
  "Stand the sessions of SPACE side by side in the tab just made.
Most recently used first, to the right of the source, until the row has
no room for another column of `ecc-space-session-min-width\='.  The ones
that do not fit go on running with no window, which the sidebar and
`ecc-toggle\=' bring back.

A tab is a window arrangement and this is the only moment there is none
to keep: from here on the windows are the user\='s, and coming back to
the Space brings them back as they were left."
  (let ((ecc-space--laying-out t))
    (catch 'full
      (dolist (session (ecc-space-sessions space))
        (unless (ecc-space-display-session session t)
          (throw 'full nil))))))

(defun ecc-space--lay-out (space)
  "Fill the new tab of SPACE with the source of the project and its sessions.
One window with the code in it, which is what the user is looking at
when they ask for a project, and the sessions of the Space beside it:
going to a Space is asking to work there, and a tab that comes up with
the transcripts hidden is one the user has to unpack by hand."
  (let* ((root (ecc-space-root space))
         (buffer (or (ecc-window-project-source-buffer root)
                     ;; A directory is a fair answer to where the source
                     ;; is, but only if it is still there: a worktree
                     ;; whose checkout was removed under a Space that is
                     ;; still open would otherwise take the tab down with
                     ;; an error instead of opening it empty.
                     (and (file-directory-p root)
                          (progn (require 'dired) (dired-noselect root))))))
    (when (buffer-live-p buffer)
      (set-window-buffer (selected-window) buffer))
    ;; A tab carries its own windows, so the sidebar has to be put in
    ;; every one of them.  Loaded here rather than required: the
    ;; sidebar is built on the Spaces, so the dependency runs the other
    ;; way.
    (require 'ecc-sidebar)
    (ecc-sidebar-show)
    (ecc-space--lay-out-sessions space)))

(defun ecc-space-select (space)
  "Show SPACE and return the name of its tab, or nil under `classic'.
Under `spaces' its windows come back exactly as they were left: a tab
is a window configuration, which is the whole point of laying the
sessions out this way.

Under `classic' there are no tabs of ours and none is made -- turning
the tab bar on because somebody pressed a number in the sidebar would
be changing the layout behind their back.  Showing a Space there is
what it has always been: focusing that project."
  (if (eq ecc-layout 'spaces)
      (ecc-space--select-tab space)
    (ecc-space--select-classic space)))

(defun ecc-space--select-classic (space)
  "Focus the project of SPACE the way `classic' has always focused one.
A Space with nothing running in it has no windows to deal out, so its
source is shown instead; `ecc-focus-project' refuses that case, and
refusing is no answer to somebody who asked to be taken there."
  (let ((root (ecc-space-root space)))
    (if (ecc-window-project-sessions root)
        (ecc-focus-project root)
      (ecc-window-focus-source root))
    (setf (alist-get (ecc-space-key space) ecc-space--used nil nil #'equal)
          (float-time))
    nil))

(defvar ecc-space--starting nil
  "Keys of the Spaces whose automatic session is being started.
Starting a session shows it, showing it selects its Space, and selecting
a Space with nothing in it is what starts one.  The first turn of that
circle has not registered its session yet when the second comes round,
so the key is held here instead.")

(defun ecc-space--ensure-session (space)
  "Start a session in SPACE when nothing of it is running.
Going to a Space is asking to work there, and a Space with nothing
running is a tab with a file in it and no way to say anything.  There is
no setting: a Space that lands empty is one that looks broken.

Failing to start is not failing to go there -- the tab is made and the
message says what happened -- and a checkout that is gone is left alone
rather than started in a directory that does not exist."
  (when (and (not ecc-space--laying-out)
             (not (member (ecc-space-key space) ecc-space--starting))
             (null (ecc-space-sessions space))
             (file-directory-p (ecc-space-root space)))
    (let ((ecc-space--starting (cons (ecc-space-key space) ecc-space--starting)))
      (require 'ecc)
      (condition-case error
          (ecc-start (ecc-space-root space))
        (error (message "%s: nothing started: %s" (ecc-space-name space)
                        (error-message-string error)))))))

(defun ecc-space--select-tab (space)
  "Show SPACE in its tab, making the tab when it has none.
A Space with nothing running in it gets a session; see
`ecc-space--ensure-session\='."
  (unless (bound-and-true-p tab-bar-mode)
    (tab-bar-mode 1))
  (let ((name (ecc-space-tab space)))
    (if name
        (tab-bar-select-tab-by-name name)
      (setq name (ecc-space--unique-tab-name (ecc-space-name space)))
      (tab-bar-new-tab)
      (tab-bar-rename-tab name)
      (setf (alist-get (ecc-space-key space) ecc-space--tabs nil nil #'equal)
            name)
      (ecc-space--lay-out space))
    (setf (alist-get (ecc-space-key space) ecc-space--used nil nil #'equal)
          (float-time))
    (ecc-space--ensure-session space)
    name))

(defun ecc-space-current-key ()
  "Return the Space key of the tab that is showing, or nil.
Nil when the tab is not one of ours, which is what says that the user
went somewhere this package has no opinion about."
  (when-let* ((tab (and (fboundp 'tab-bar--current-tab) (tab-bar--current-tab)))
              (name (alist-get 'name tab)))
    (car (rassoc name ecc-space--tabs))))

(defun ecc-space-current ()
  "Return the Space that is showing, or nil.
With `spaces' that is the Space of the current tab; with `classic'
there are no tabs of ours, so it is the project the current buffer is
in, the same one `ecc-start' would use."
  (pcase ecc-layout
    ('spaces (when-let* ((key (ecc-space-current-key)))
               (ecc-space-of-root key)))
    (_ (ecc-space-of-root (ecc-window-context-project-root)))))

;;;; Showing a session in a Space

(defun ecc-space--session-windows ()
  "Return the windows of this tab showing a session, left to right."
  (sort (seq-filter (lambda (window)
                      (ecc-window-buffer-session (window-buffer window)))
                    (window-list nil 'no-minibuffer))
        (lambda (a b) (< (nth 0 (window-edges a)) (nth 0 (window-edges b))))))

(defun ecc-space--window-to-split (windows)
  "Return the one of WINDOWS a new session should be opened beside, or nil.
The rightmost, so that a session appears where the last one did and the
row reads in the order the sessions were started; nil says the row is
full and `ecc-space-display-session' puts the new session into a window
that is already there instead of making a narrower one.

A rightmost window with less than two sessions' worth of columns is
widened first, out of the room its siblings have, so that the rule
holds however the row was arranged."
  ;; Measured with `window-total-width\=', not `window-body-width\=': the
  ;; body leaves out the fringes, the margins and the scroll bar -- five
  ;; columns on the frame this was measured on (2026-09-15) -- while
  ;; `window-splittable-p\=' and the `window-width\=' handed to
  ;; `display-buffer\=' are both in the total.  Mixing the two refused
  ;; splits that fit and made the new window narrower than it was asked
  ;; to be.
  (let* ((room (* 2 (max ecc-space-session-min-width window-min-width)))
         (right (car (last windows))))
    (when (and (< (window-total-width right) room) (cdr windows))
      (ignore-errors
        (window-resize right (- room (window-total-width right)) t t)))
    (and (>= (window-total-width right) room) right)))

(defun ecc-space--display-beside (buffer window width)
  "Show BUFFER in a new window WIDTH columns wide, to the right of WINDOW."
  ;; `split-width-threshold' is 160 by default and is how `display-buffer'
  ;; guesses whether a window is wide enough to be worth dividing.  The
  ;; guess is not wanted here: the layout has already decided, and the
  ;; width a session may not go under is `ecc-space-session-min-width'.
  ;; Left at the default, `window-splittable-p' refuses every window
  ;; narrower than 160 columns, `display-buffer-in-direction' returns
  ;; nil and `display-buffer' falls through to its other methods, which
  ;; put the new session under the row -- the one thing a Space does not
  ;; do (measured 2026-09-15, in an 80-column frame).
  (let ((split-width-threshold (* 2 (max ecc-space-session-min-width
                                         window-min-width))))
    (display-buffer-in-direction
     buffer `((direction . right)
              (window . ,window)
              (window-width . ,width)))))

(defun ecc-space--window-to-reuse (windows)
  "Return the one of WINDOWS holding the session used longest ago.
What a Space gives up when the row is full: rather than divide a
transcript into a column too narrow to read, the session nobody has
worked in for longest hands its window over."
  (cl-labels ((age (window)
                ;; `ecc-model-sessions' is most recently used first, so
                ;; the shorter the tail from a session, the longer ago
                ;; it was worked in.  A window whose session is gone
                ;; from the order has no tail at all and goes first.
                (length (memq (ecc-window-buffer-session (window-buffer window))
                              (ecc-model-sessions)))))
    (car (sort (copy-sequence windows)
               (lambda (a b) (< (age a) (age b)))))))

(defun ecc-space-display-session (session &optional no-reuse)
  "Show SESSION in the Space of its project and return its window.
The sessions of a Space stand side by side: the first goes beside the
source, to the right, and every one after it divides the rightmost of
them.  They are ordinary windows, with no role and no dedication: from
here on they are the user\\='s to arrange.

Nothing is ever stacked.  A row with no room left for a column of
`ecc-space-session-min-width' does not grow a narrower one -- the
window of the session used longest ago shows the new session instead,
and the one it held goes on running with no window, which the sidebar
and `ecc-toggle' bring back.

NO-REUSE says the caller would rather show nothing than take a window
away from another session: nil comes back instead, and the session goes
on running without a window.  That is how `ecc-space--lay-out\=' fills a
row and knows where to stop.

A session already on the screen of this tab is left where it is rather
than opened a second time."
  (require 'ecc-session)
  (let ((buffer (ecc-session-ensure-buffer session)))
    (ecc-space-select (ecc-space-of-root (ecc-window-session-project session)))
    (or (get-buffer-window buffer)
        (if-let* ((windows (ecc-space--session-windows)))
            (or (when-let* ((beside (ecc-space--window-to-split windows)))
                  ;; Half of what it divides.  Left to itself
                  ;; `display-buffer-in-direction' gives the new window
                  ;; a few columns whatever room there is, so the second
                  ;; session of a Space came up as a sliver beside a
                  ;; wide transcript (measured 2026-09-15).
                  (ecc-space--display-beside
                   buffer beside (/ (window-total-width beside) 2)))
                (unless no-reuse
                  (let ((window (ecc-space--window-to-reuse windows)))
                    (set-window-buffer window buffer)
                    window)))
          ;; Told which window to split, so that the sidebar on the left
          ;; is not what gets divided (verified 2026-09-14).
          (ecc-space--display-beside
           buffer (or (ecc-window--source-window) (selected-window))
           ecc-window-width)))))

;;;; Commands

;;;###autoload
(defun ecc-space-zoom ()
  "Fill the tab with the window point is in, or put the windows back.
The arrangement is kept per tab, so a Space zoomed in one is not
zoomed in another.  A side window that asked not to be deleted -- the
sidebar -- stays where it is (verified 2026-09-14)."
  (interactive)
  (let* ((key (ecc-window--layout-key))
         (saved (frame-parameter nil 'ecc-space-zoom))
         (state (alist-get key saved nil nil #'equal)))
    (cond
     (state
      (setf (alist-get key saved nil 'remove #'equal) nil)
      (set-frame-parameter nil 'ecc-space-zoom saved)
      (window-state-put state (frame-root-window) 'safe)
      (message "Windows as they were"))
     ;; A side window cannot be made the only window, and the sidebar is
     ;; one.  Saying so beats the error `delete-other-windows' raises.
     ((window-parameter (selected-window) 'window-side)
      (user-error "This window cannot fill the tab on its own"))
     ;; Nothing to put away.  Saving a state here would be worse than
     ;; doing nothing: the key would then be "zoomed" without the screen
     ;; having changed, and the way back would do nothing either.
     ((null (ecc-space--zoomable-windows))
      (message "Nothing to zoom: there is no other window to put away"))
     (t
      (setf (alist-get key saved nil nil #'equal)
            (window-state-get (frame-root-window) t))
      (set-frame-parameter nil 'ecc-space-zoom saved)
      (delete-other-windows)
      (message "Zoomed; the same key puts the windows back")))))

(defun ecc-space--zoomable-windows ()
  "Return the windows `delete-other-windows' would take down from here.
The sidebar is not among them: it asks not to be deleted, so zooming
with only the sidebar beside you changes nothing on the screen."
  (seq-remove (lambda (window)
                (or (eq window (selected-window))
                    (window-parameter window 'no-delete-other-windows)))
              (window-list nil 'no-minibuffer)))

(defun ecc-space-label (space &optional spaces)
  "Return the line SPACE is offered under, among SPACES."
  (format "%2s %-24s %-9s %s"
          (or (ecc-space-number space spaces) "")
          (ecc--truncate (ecc-space-name space) 24)
          (or (ecc-space-state space) "")
          (abbreviate-file-name (ecc-space-root space))))

(defun ecc-space-read (&optional prompt)
  "Ask which Space to use, with PROMPT."
  (let ((spaces (ecc-space-list)))
    (unless spaces
      (user-error "No project has a session or a tab"))
    (let* ((labels (mapcar (lambda (space)
                             (cons (ecc-space-label space spaces) space))
                           spaces))
           (choice (completing-read (or prompt "Space: ")
                                    (mapcar #'car labels) nil t)))
      (cdr (assoc choice labels)))))

;;;###autoload
(defun ecc-space-goto (space)
  "Go to SPACE, opening its tab when it has none."
  (interactive (list (ecc-space-read "Go to Space: ")))
  (ecc-space-select space)
  (message "%s" (ecc-space-name space)))

;;;###autoload
(defun ecc-space-jump (n)
  "Go to the Nth Space, counting from one down the sidebar."
  (interactive "p")
  (let* ((spaces (ecc-space-list))
         (space (nth (1- n) spaces)))
    (unless space
      (user-error "There is no Space %d" n))
    (ecc-space-select space)
    (message "%s" (ecc-space-name space))))

;;;###autoload
(defun ecc-space-close (space)
  "Close the tab of SPACE, stopping the sessions running in it.
The checkout of a worktree is not touched; `ecc-remove-worktree' is
what undoes one."
  (interactive (list (or (ecc-space-current) (ecc-space-read "Close Space: "))))
  (let ((sessions (ecc-space-sessions space))
        (name (ecc-space-tab space)))
    (when sessions
      (unless (yes-or-no-p (format "Stop %d session%s of %s? "
                                   (length sessions)
                                   (if (= 1 (length sessions)) "" "s")
                                   (ecc-space-name space)))
        (user-error "Left alone"))
      (require 'ecc)
      (mapc #'ecc-kill sessions))
    (when name
      (tab-bar-close-tab-by-name name))
    (message "Closed %s" (ecc-space-name space))))

(provide 'ecc-space)

;;; ecc-space.el ends here
