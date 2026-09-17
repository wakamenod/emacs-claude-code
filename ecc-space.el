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
(declare-function ecc-sidebar-redraw "ecc-sidebar" ())
(declare-function ecc-inline-session-p "ecc-inline" (session))
(declare-function ecc-history-project-roots "ecc-history" ())

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

(defcustom ecc-space-always-session t
  "Non-nil means a Space always holds a session.
Going to a Space then starts one when nothing of the project is
running, and a Space that runs out of sessions closes itself: a tab
with a file in it and no way to say anything is a Space that looks
broken, so there is never one on the screen.  That is the default
because it is what a Space is for.

Nil makes a Space a place to read as much as a place to work: opening
one shows the source of the project and starts nothing, and the Space
stays until the last buffer of the project is killed as well.

It is a setting because a session is a process and a budget.  Whether
opening a checkout should spend either of them -- to look at a
worktree beside the one being worked in, to keep a repository on the
screen for what its code says -- is a judgement about cost and about
how a person works, not something this package can settle for
everybody."
  :type 'boolean
  :group 'ecc)

;;;; The model

(cl-defstruct ecc-space
  key     ; `ecc-window-project-key' of the root: what groups the sessions
  root    ; the directory, as `file-name-as-directory'
  name    ; what the sidebar and the tab call it
  parent  ; key of the main worktree when this is a linked worktree, else nil
  branch  ; the branch checked out there, or nil
  past)   ; non-nil when nothing of it is running and only recordings are left

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

(defun ecc-space-children (space &optional spaces)
  "Return the Spaces of SPACE drawn under it among SPACES.
The worktrees of a repository that are on the screen, in the order they
are drawn.  SPACE is a Space or the key of one, which is what the
sidebar has in hand when it draws the tree lines.  SPACES defaults to
`ecc-space-list'."
  (let ((key (if (ecc-space-p space) (ecc-space-key space) space)))
    (seq-filter (lambda (other)
                  (equal (ecc-space-parent other) key))
                (or spaces (ecc-space-list)))))

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

(defun ecc-space--source-buffer (space)
  "Return the buffer the source window of SPACE should hold, or nil."
  (let ((root (ecc-space-root space)))
    (or (ecc-window-project-source-buffer root)
        ;; A directory is a fair answer to where the source is, but only
        ;; if it is still there: a worktree whose checkout was removed
        ;; under a Space that is still open would otherwise take the tab
        ;; down with an error instead of opening it empty.
        (and (file-directory-p root)
             (progn (require 'dired) (dired-noselect root))))))

(defun ecc-space--lay-out (space)
  "Fill the new tab of SPACE with the source of the project and its sessions.
One window with the code in it, which is what the user is looking at
when they ask for a project, and the sessions of the Space beside it:
going to a Space is asking to work there, and a tab that comes up with
the transcripts hidden is one the user has to unpack by hand."
  (let ((buffer (ecc-space--source-buffer space)))
    (when (buffer-live-p buffer)
      (set-window-buffer (selected-window) buffer))
    ;; A tab carries its own windows, so the sidebar has to be put in
    ;; every one of them.  Loaded here rather than required: the
    ;; sidebar is built on the Spaces, so the dependency runs the other
    ;; way.
    (require 'ecc-sidebar)
    (ecc-sidebar-show)
    (ecc-space--lay-out-sessions space)))

(defun ecc-space--source-window ()
  "Return a window of this tab the code can be read in, or nil.
Not `ecc-window--source-window\=', which answers with the largest window
whatever is in it: a tab whose source window was given to a transcript
still has windows, and none of them is a window to read the code in."
  (seq-find (lambda (window)
              (and (not (window-parameter window 'window-side))
                   (not (ecc-window-own-buffer-p (window-buffer window)))))
            (window-list nil 'no-minibuffer)))

(defun ecc-space--ensure-source (space)
  "Put the source of SPACE back when its tab has no window to read it in.
The windows of a tab are the user\='s and are left where they were put:
that is what a Space is for, and a source window showing another
project\='s file is a window the user pointed there.  A tab with nothing
but transcripts in it is the one case that is nobody\='s arrangement --
`delete-other-windows\=' on a transcript leaves it, and going to the
Space used to bring back a tab with no code in it and no way to say so.

The source opens to the left of the leftmost window, which is where a
Space puts it, and takes half of what it divides."
  (unless (ecc-space--source-window)
    (when-let* ((buffer (ecc-space--source-buffer space))
                ((buffer-live-p buffer))
                (windows (seq-remove (lambda (window)
                                       (window-parameter window 'window-side))
                                     (window-list nil 'no-minibuffer)))
                (leftmost (car (sort windows
                                     (lambda (a b)
                                       (< (nth 0 (window-edges a))
                                          (nth 0 (window-edges b))))))))
      (ecc-space--display-beside buffer leftmost
                                 (/ (window-total-width leftmost) 2)
                                 'left))))

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
running is a tab with a file in it and no way to say anything: that is
why `ecc-space-always-session' defaults on, and turning it off is
asking for a Space to read in.

Failing to start is not failing to go there -- the tab is made and the
message says what happened -- and a checkout that is gone is left alone
rather than started in a directory that does not exist."
  (when (and ecc-space-always-session
             (not ecc-space--laying-out)
             (not (member (ecc-space-key space) ecc-space--starting))
             (null (ecc-space-sessions space))
             (file-directory-p (ecc-space-root space)))
    (let ((ecc-space--starting (cons (ecc-space-key space) ecc-space--starting)))
      (require 'ecc)
      (condition-case error
          (ecc-start (ecc-space-root space))
        (error (message "%s: nothing started: %s" (ecc-space-name space)
                        (error-message-string error)))))))

(defvar ecc-space--closing nil
  "Non-nil while a Space is being closed on purpose.
The windows of a session that is killed are still taken away, but no
Space closes itself underneath the command doing the closing.")

(defvar ecc-space--implicit nil
  "Keys of the Spaces this package opened on somebody else's account.
A repository opened because a worktree of it was: nobody asked for it,
so it goes again when the last worktree under it does.  A repository
the user opened themselves is not here and stays.")

(defvar ecc-space--ensuring-parent nil
  "Keys of the Spaces whose repository is being opened behind them.
Opening the repository starts a session in it, which shows it, which
selects its Space: the key is held here so that the second turn of that
circle does not go looking for a repository again.")

(defun ecc-space--parent-space (space)
  "Return the Space of the repository SPACE was checked out from, or nil.
Nil when SPACE is not a worktree, when the repository has a Space
already -- a tab or a session of its own -- when git says the
repository is itself a linked worktree, and when its checkout is gone."
  (when-let* ((parent (ecc-space-parent space))
              ((not (member parent (ecc-space--keys))))
              ((not (member parent ecc-space--ensuring-parent)))
              ((file-directory-p parent))
              ((not (ecc-worktree-main parent))))
    (ecc-space-of-root parent)))

(defun ecc-space--ensure-parent (space)
  "Open the Space of the repository SPACE was checked out from.
A worktree with no repository above it is a child with nothing to hang
under: `ecc-space-list' leaves it at the top of the sidebar, and the
tree the Spaces are drawn in says nothing about where it came from.  So
opening a worktree opens the repository too, the way herdr's
`ensure_source_parent_membership' does.

The tab is made before the tab of SPACE and the session of SPACE is
started after it, so the worktree is what the user is left looking at.
Whether the repository gets a session of its own is
`ecc-space-always-session', like everywhere else."
  (when-let* ((parent (ecc-space--parent-space space)))
    (let ((ecc-space--ensuring-parent
           (cons (ecc-space-key parent) ecc-space--ensuring-parent)))
      (ecc-space--select-tab parent)
      (push (ecc-space-key parent) ecc-space--implicit))))

(defun ecc-space--select-tab (space)
  "Show SPACE in its tab, making the tab when it has none.
A Space with nothing running in it gets a session; see
`ecc-space--ensure-session\='.  A worktree opened for the first time
brings its repository with it; see `ecc-space--ensure-parent\='."
  (unless (bound-and-true-p tab-bar-mode)
    (tab-bar-mode 1))
  (let ((name (ecc-space-tab space)))
    (if name
        (progn (tab-bar-select-tab-by-name name)
               (ecc-space--ensure-source space))
      (ecc-space--ensure-parent space)
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

(defun ecc-space--display-beside (buffer window width &optional direction)
  "Show BUFFER in a new window WIDTH columns wide, beside WINDOW.
DIRECTION is which side of WINDOW it goes on, `right\=' by default."
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
     buffer `((direction . ,(or direction 'right))
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

(defun ecc-space--popup-window ()
  "Return the widest window of this tab a buffer of ours may be put in, or nil.
The same windows `ecc-space--source-window\=' will have -- no side
window, nothing of this package in it -- but the widest of them rather
than the first: what goes here is read, and in a Space the source
window is the one wide enough to read a plan in."
  (car (sort (seq-filter
              (lambda (window)
                (and (not (window-parameter window 'window-side))
                     (not (ecc-window-own-buffer-p (window-buffer window)))))
              (window-list nil 'no-minibuffer))
             (lambda (a b) (> (window-total-width a) (window-total-width b))))))

(defun ecc-space--display-in (buffer window)
  "Show BUFFER in WINDOW and return it, so that quitting puts back what was there.
`set-window-buffer\=' on its own tells the window nothing about where it
came from, and `quit-window\=' then has nothing to go back to.  The
`quit-restore\=' is written first, which also replaces whatever an older
`display-buffer\=' left there: Emacs 32 resizes a window back to the
width recorded with it, and a record from a wider arrangement made the
window jump (Emacs 32.0.50, 2026-09-16)."
  (display-buffer-record-window 'reuse window buffer)
  (set-window-buffer window buffer)
  window)

(defun ecc-space-display-beside-session (buffer session)
  "Show BUFFER next to SESSION in its Space and return the window.
A question, a plan, a log or an agent transcript comes out of one
conversation and belongs beside it.  Left to `display-buffer\=', it did
not land there: the session windows of a Space are narrower than
`split-width-threshold\=', so nothing could be divided and
`display-buffer-use-some-window\=' took whichever window had been used
longest ago -- the transcript of another session, which then vanished,
or a leftover window that fell back to `*scratch*\=' when the buffer was
closed (reported 2026-09-16).

The Space is gone to first and the session put on the screen, so that
the two are always seen together.  Then the widest window that holds no
session takes the buffer -- the source, which is the one window in a
Space wide enough to read a plan in, and which comes back as it was
when the buffer is quit.  Only where there is no such window is a
session window divided: to the right when it has the room for two
columns, below it when it has not, and never so that a transcript is
lost."
  (require 'ecc-session)
  (let ((session-window (ecc-space-display-session session)))
    (or (get-buffer-window buffer)
        (when-let* ((source (ecc-space--popup-window)))
          (ecc-space--display-in buffer source))
        (when (window-live-p session-window)
          (if (>= (window-total-width session-window)
                  (* 2 (max ecc-space-session-min-width window-min-width)))
              (ecc-space--display-beside
               buffer session-window
               (/ (window-total-width session-window) 2))
            (display-buffer-in-direction
             buffer `((direction . below)
                      (window . ,session-window)
                      (window-height . ,(/ (window-total-height session-window)
                                           2))))))
        (display-buffer buffer))))

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

(defun ecc-space-past-projects ()
  "Return a Space for every project that has only recordings left.
A project worked in before is somewhere to go back to, whether or not
anything of it is running: its Space is made, its session started, and
`/resume\=' is how the conversation that was there is picked up again.

They are deliberately not in `ecc-space-list\=': a project with no session
and no tab is not on the screen, and numbering it would move the numbers
the sidebar draws and the `1\='-`9\=' keys take under the user\='s feet.
`ecc-space-read\=' is the one place they are offered.

A checkout that has been removed is left out: its recordings are still
readable with `ecc-history-open\=', but there is nowhere to start."
  (require 'ecc-history)
  (let ((keys (ecc-space--keys))
        (seen (make-hash-table :test #'equal))
        (spaces nil))
    (dolist (root (ecc-history-project-roots))
      (when (file-directory-p root)
        (let ((key (ecc-window-project-key root)))
          (unless (or (member key keys) (gethash key seen))
            (puthash key t seen)
            (let ((space (ecc-space-of-root key)))
              (setf (ecc-space-past space) t)
              (push space spaces))))))
    (nreverse spaces)))

(defun ecc-space-label (space &optional spaces)
  "Return the line SPACE is offered under, among SPACES."
  (format "%2s %-24s %-9s %s"
          (or (ecc-space-number space spaces) "")
          (ecc--truncate (ecc-space-name space) 24)
          (or (ecc-space-state space) (and (ecc-space-past space) "past") "")
          (abbreviate-file-name (ecc-space-root space))))

(defun ecc-space--table (labels)
  "Return a completion table of LABELS that keeps the order they are in.
The live Spaces come in the order the sidebar numbers them and the past
ones newest first; sorting the candidates would throw both away."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action labels string predicate))))

(defun ecc-space-read (&optional prompt)
  "Ask which Space to use, with PROMPT.
The Spaces on the screen come first, in the order they are numbered,
and the projects only recordings are left of follow."
  (let* ((spaces (ecc-space-list))
         (past (and (eq ecc-layout 'spaces) (ecc-space-past-projects)))
         (all (append spaces past)))
    (unless all
      (user-error "No project has a session, a tab or a recording"))
    (let* ((labels (mapcar (lambda (space)
                             (cons (ecc-space-label space spaces) space))
                           all))
           (choice (completing-read (or prompt "Space: ")
                                    (ecc-space--table (mapcar #'car labels))
                                    nil t)))
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
A repository takes its worktrees with it: they are drawn under it and
are closed with it, the way herdr closes a group.  A worktree closed on
its own leaves the repository where it is.

The checkout of a worktree is not touched; `ecc-remove-worktree' is
what undoes one."
  (interactive (list (or (ecc-space-current) (ecc-space-read "Close Space: "))))
  ;; Everything is read before the first kill: closing a session closes
  ;; the Space it was the last of, and the children would be gone from
  ;; `ecc-space-list' halfway through the loop.
  (let* ((spaces (ecc-space-list))
         (children (ecc-space-children space spaces))
         (group (cons space children))
         (sessions (seq-mapcat #'ecc-space-sessions group))
         (names (delq nil (mapcar #'ecc-space-tab group))))
    (when sessions
      (unless (yes-or-no-p (format "Stop %d session%s of %s? "
                                   (length sessions)
                                   (if (= 1 (length sessions)) "" "s")
                                   (ecc-space--group-name space children)))
        (user-error "Left alone"))
      (require 'ecc)
      (let ((ecc-space--closing t))
        (mapc #'ecc-kill sessions)))
    (let ((ecc-space--closing t))
      (dolist (name names)
        (when (ecc-space--tab-index name)
          (tab-bar-close-tab-by-name name)))
      (dolist (one group)
        (setq ecc-space--implicit
              (delete (ecc-space-key one) ecc-space--implicit))))
    (ecc-space--child-gone space)
    (message "Closed %s" (ecc-space--group-name space children))))

(defun ecc-space--group-name (space children)
  "Return what to call SPACE and the CHILDREN closing with it."
  (if children
      (format "%s and %s" (ecc-space-name space)
              (string-join (mapcar #'ecc-space-name children) ", "))
    (ecc-space-name space)))

(defun ecc-space-forget (root)
  "Close the tab of the Space at ROOT and forget it.
For a checkout that is about to be removed: once the directory is gone
the Space is nowhere to go back to, and a tab left behind keeps it in
`ecc-space-list\=' and in the sidebar with nothing underneath it.  Call
this while ROOT is still there, so the key it groups under is the one
its sessions used.

The sessions are not touched: whoever removes a checkout stops them
first.  A sole tab is forgotten rather than closed, Emacs refusing to
delete the last one."
  (let* ((key (ecc-window-project-key root))
         (name (alist-get key ecc-space--tabs nil nil #'equal))
         (space (ecc-space-of-root key)))
    (when (and (ecc-space--tab-index name)
               (cdr (tab-bar-tabs)))
      (tab-bar-close-tab-by-name name))
    (setf (alist-get key ecc-space--tabs nil 'remove #'equal) nil)
    (setf (alist-get key ecc-space--used nil 'remove #'equal) nil)
    (setq ecc-space--implicit (delete key ecc-space--implicit))
    ;; Asked while ROOT is still there: once the checkout is gone git
    ;; can no longer say which repository it came from.
    (unless ecc-space--closing
      (ecc-space--child-gone space))))

;;;; When a session goes

;; A Space is not a thing that is made and destroyed: it is a project
;; with something of ours in it, and it stops being one when the last
;; of that goes.  Which is why what closes a Space is a session leaving
;; the model rather than a command -- and why the trigger is
;; `ecc-session-removed-hook' and not `ecc-session-exited-hook': a
;; session whose process died keeps its place so `/resume' has
;; somewhere to come back to.

(defun ecc-space--counts-p (session)
  "Return non-nil when the going of SESSION says anything about a Space.
A recording being read, the usage probe and an inline question are all
kind `own' and all belong to nobody: the probe has no project of its
own and lands in whatever directory was current, which would close the
Space of a project it was never in."
  (and (not (eq (ecc-session-kind session) 'archived))
       (not (ecc-model-option session :usage-probe nil))
       (not (and (fboundp 'ecc-inline-session-p)
                 (ecc-inline-session-p session)))))

(defun ecc-space--session-buffers (session)
  "Return the live buffers of SESSION."
  (seq-filter #'buffer-live-p
              (list (ecc-session-buffer session)
                    (ecc-session-stream-buffer session))))

(defun ecc-space--delete-session-windows (session)
  "Take the windows of SESSION away rather than leave them to Emacs.
A killed buffer is replaced in its window by whatever was there before
it, which in a Space is nothing to do with the project -- `*scratch*'
in the middle of a row of transcripts.  The window is deleted instead,
and the ones beside it take the room back.

The last window of the tab is given the source of the project instead:
a tab has to hold something, and the code is the one thing that is
always an answer.  `window-deletable-p' answers `tab' or `frame' for
that window -- it can be deleted, but only by taking the tab or the
frame with it -- so only a plain t is taken for yes.  The sidebar is a
side window and is neither deleted nor counted."
  (let ((buffers (ecc-space--session-buffers session)))
    (dolist (buffer buffers)
      (dolist (window (get-buffer-window-list buffer nil t))
        (unless (window-parameter window 'window-side)
          (if (eq (window-deletable-p window) t)
              (ignore-errors (delete-window window))
            (when-let* ((space (ecc-space-current))
                        (source (ecc-space--source-buffer space))
                        ((buffer-live-p source)))
              (set-window-buffer window source))))))))

(defun ecc-space--close-empty (space)
  "Close SPACE, which has nothing left in it.
The tab goes, which is what takes the user to the Space beside it, and
the key is forgotten everywhere it was written down."
  (let ((ecc-space--closing t))
    (ecc-space-forget (ecc-space-root space))
    (setq ecc-space--implicit
          (delete (ecc-space-key space) ecc-space--implicit)))
  (ecc-space--child-gone space)
  (when (fboundp 'ecc-sidebar-redraw)
    (ecc-sidebar-redraw))
  (message "Closed %s" (ecc-space-name space)))

(defun ecc-space--child-gone (child)
  "Close the repository of CHILD when nobody but CHILD asked for it.
A repository opened by `ecc-space--ensure-parent' is there to hold the
worktrees under it.  With the last of them gone and nothing running in
it, it is a tab nobody asked for."
  (when-let* ((parent-key (ecc-space-parent child))
              ((member parent-key ecc-space--implicit))
              (parent (ecc-space-of-root parent-key))
              ((null (ecc-space-sessions parent)))
              ((null (seq-remove (lambda (other)
                                   (equal (ecc-space-key other)
                                          (ecc-space-key child)))
                                 (ecc-space-children parent)))))
    (ecc-space--close-empty parent)))

(defun ecc-space--session-removed (session)
  "Take the windows of SESSION away, and its Space when it was the last.
On `ecc-session-removed-hook'.  A Space is closed only under
`ecc-space-always-session': with the setting off a Space stands on its
source buffer alone and goes with that instead, in
`ecc-space--forget-on-source-kill'.

A session of a Space that is still being started is not the end of
anything: `ecc-proc--start-failed' forgets a session that never came
up, and the tab the user just asked for would go with it."
  (when (eq ecc-layout 'spaces)
    (ecc-space--delete-session-windows session)
    (when-let* (((not ecc-space--closing))
                ((not ecc-space--laying-out))
                ((ecc-space--counts-p session))
                (key (ecc-window-session-project session))
                ((not (member key ecc-space--starting)))
                (space (ecc-space-of-root key))
                ;; An inline session left in the project counts: nothing
                ;; here closes a Space that still has something in it.
                ((null (ecc-space-sessions space)))
                (ecc-space-always-session))
      (ecc-space--close-empty space))))

(add-hook 'ecc-session-removed-hook #'ecc-space--session-removed)

(defun ecc-space--forget-on-source-kill ()
  "Close the Space of the buffer being killed when nothing else is left.
The other half of `ecc-space-always-session': with the setting off a
Space is kept alive by its source, so killing the last buffer of the
project is what closes it.  On `kill-buffer-hook'."
  (when (and (eq ecc-layout 'spaces)
             (not ecc-space-always-session)
             (not ecc-space--closing))
    (when-let* ((directory (ecc-window-buffer-directory (current-buffer)))
                (key (ecc-window-project-key directory))
                ((alist-get key ecc-space--tabs nil nil #'equal))
                (space (ecc-space-of-root key))
                ((null (ecc-space-sessions space)))
                ((null (ecc-space--other-project-buffers key))))
      (ecc-space--close-empty space))))

(defun ecc-space--other-project-buffers (key)
  "Return the live buffers of the project KEY, bar the current one."
  (seq-filter (lambda (buffer)
                (and (not (eq buffer (current-buffer)))
                     (not (ecc-window-own-buffer-p buffer))
                     (when-let* ((directory (ecc-window-buffer-directory buffer)))
                       (equal (ecc-window-project-key directory) key))))
              (buffer-list)))

(add-hook 'kill-buffer-hook #'ecc-space--forget-on-source-kill)

(provide 'ecc-space)

;;; ecc-space.el ends here
