;;; ecc-space.el --- One tab per project, and what lives in it  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
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

;; A Space is a project -- a repository, or a worktree of one -- with a
;; tab of the tab bar to itself.  This is what `ecc-use-spaces' turns on;
;; with it nil nothing here is called except by whoever asks for it
;; outright.
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
(declare-function ecc-history-project-roots "ecc-history" ())

;;;; Settings

;; It said how many transcripts a row of them had room for.  The windows
;; of a Space are laid out to fixed proportions now, and how many
;; sessions are on the screen is the layout's to say.
(make-obsolete-variable 'ecc-space-session-min-width
                        "the layouts of `ecc-space-cycle-layout' say how \
many sessions are on the screen."
                        "0.4.2")

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
opening a project should spend either of them -- to look at a
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
A worktree goes by its branch, which is what tells two worktrees of one
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

(defun ecc-space-title (space)
  "Return what SPACE goes by in a picker.
A linked worktree is titled after the repository it belongs to and then
its branch, `repo › branch\=', with the repository's own title in front,
so that typing what the repository goes by -- `app<2>\=' as well as
`app\=' -- finds its worktrees too.  The branch and not the worktree's
tab: a tab's `<2>\=' is there to tell tabs apart, and the repository in
front already does.  Any other Space goes by the name of its tab when
it has one, so that the picker and the tab bar agree, and otherwise by
its name; a past one has no tab, and none is looked for.  The Space
picker offers a Space under this, and the session picker titles the
group of a Space's sessions with it."
  (if-let* ((parent (ecc-space-parent space)))
      (concat (ecc-space-title (ecc-space-of-root parent))
              " › " (ecc-space-name space))
    (or (and (not (ecc-space-past space)) (ecc-space-tab space))
        (ecc-space-name space))))

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

(defun ecc-space-at-p (root)
  "Return non-nil when the project ROOT belongs to has a Space."
  (and (member (ecc-window-project-key root) (ecc-space--keys)) t))

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

(defun ecc-space-tree-line (space spaces)
  "Return the tree line drawn in front of SPACE, one of the drawn SPACES.
Empty for a repository; for a worktree, the line that ties it to the
row above, closed off on the last one.  SPACES is what is on the
screen rather than every Space there is: a fold of the sidebar can
leave one worktree of three drawn, and it is the last of what is drawn
that closes the line.  The sidebar and `ecc-space-read\=' draw with it."
  (if (not (ecc-space-child-p space spaces))
      ""
    (let ((last (car (last (ecc-space-children
                            (ecc-space-parent space) spaces)))))
      (if (ecc-space-equal space last) "  └─ " "  ├─ "))))

(defun ecc-space-number-label (number spaces)
  "Return NUMBER as `[n]\=', padded to the room the widest of SPACES takes.
The widest wins, so that the names after it line up once the tenth
Space opens.  A NUMBER of nil -- a Space that is not on the screen --
is a blank of the same width.  The sidebar and `ecc-space-read\=' draw
with it."
  (string-pad (if number (format "[%d]" number) "")
              (length (format "[%d]" (max 1 (length spaces))))))

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
  "Return the sessions running in SPACE, most recently started first."
  (ecc-window-project-sessions (ecc-space-root space)))

(defun ecc-space-state (space)
  "Return the one state that stands for the sessions of SPACE, or nil."
  (ecc-tab-state-roll-up (ecc-space-sessions space)))

(defun ecc-space-equal (a b)
  "Return non-nil when the Spaces A and B are the same one."
  (and a b (equal (ecc-space-key a) (ecc-space-key b))))

;;;; The tabs underneath

(defmacro ecc-space--quietly (&rest body)
  "Run BODY without the tab commands announcing themselves.
`tab-bar.el\=' messages on every tab added, renamed, selected and closed
-- but only with `tab-bar-mode\=' off, where the bar itself cannot show
what happened (Emacs 32.0.50, confirmed 2026-09-17).  With
`tab-bar-show\=' nil that is every move between Spaces, told twice: once
in tab-bar\='s words and once in this package\='s.  `message-log-max\='
goes with `inhibit-message\=': a log of \"Added new tab at right\" is no
more use than the echo area was.

Only the tab-bar calls belong inside.  A session started on arriving at
a Space has something of its own to say.

It stays above everything that uses it.  A macro called before it is
defined compiles to a function call, which signals `invalid-function\='
when it is reached -- and whether that happens depends on what the
compiler happened to have loaded already: `make compile\=' does the
whole package in one process, so it got this right while the Emacs a
user starts did not.  A demo found it (2026-09-17)."
  (declare (indent 0) (debug t))
  `(let ((inhibit-message t)
         (message-log-max nil))
     ,@body))

;; Which tab a Space lives in is kept on the frame, not in one table for
;; the whole Emacs.  A tab belongs to a frame -- `tab-bar--tab-index-by-name\='
;; finds one only on the frame that is selected -- so a table shared by every
;; frame claimed a tab the frame in front could not see: `ecc-space-tab\='
;; then forgot it, the Space opened a second tab here, and the frame it came
;; from was left with one that nothing pointed at.  `ecc-space-close\=' run
;; from the other frame stopped the sessions and left the tab standing
;; (both verified on two frames, 2026-09-17).
;;
;; So a Space may have a tab on each frame, which is what it has always had
;; on the screen; only the book-keeping has caught up.  The zoom of
;; `ecc-space-zoom\=' is kept the same way.

(defun ecc-space--tabs (&optional frame)
  "Return the alist of a Space key to the name of its tab on FRAME."
  (frame-parameter frame 'ecc-space-tabs))

(defun ecc-space--remember-tab (key name &optional frame)
  "Remember that the Space KEY lives in the tab called NAME on FRAME."
  (let ((tabs (ecc-space--tabs frame)))
    (setf (alist-get key tabs nil nil #'equal) name)
    (set-frame-parameter frame 'ecc-space-tabs tabs)))

(defun ecc-space--drop-tab (key &optional frame)
  "Forget which tab the Space KEY lives in on FRAME."
  (let ((tabs (ecc-space--tabs frame)))
    (setf (alist-get key tabs nil 'remove #'equal) nil)
    (set-frame-parameter frame 'ecc-space-tabs tabs)))

(defun ecc-space--close-tab-everywhere (key)
  "Close the tab of the Space KEY on every frame that has one.
A Space is closed on its own account, not on the frame\='s: its sessions
are stopped wherever they were shown, and a tab left standing on
another frame would hold a Space with nothing in it.  A sole tab is
forgotten rather than closed, Emacs refusing to delete the last one."
  (dolist (frame (frame-list))
    (when-let* ((name (alist-get key (ecc-space--tabs frame) nil nil #'equal)))
      (with-selected-frame frame
        (when (and (ecc-space--tab-index name) (cdr (tab-bar-tabs)))
          (ecc-space--quietly (tab-bar-close-tab-by-name name))))
      (ecc-space--drop-tab key frame))))

(defun ecc-space--tab-index (name)
  "Return the index of the tab called NAME, or nil."
  (and name (tab-bar--tab-index-by-name name)))

(defun ecc-space--tab-keys ()
  "Return the Space keys that still have a tab, in the order of the alist."
  (delq nil (mapcar (lambda (entry)
                      (and (ecc-space--tab-index (cdr entry)) (car entry)))
                    (ecc-space--tabs))))

(defun ecc-space-tab-roots (&optional frame)
  "Return the roots of the Spaces with a tab on FRAME, in the order of the tabs.
What `ecc-restore' saves: the tab bar is the order the user sees, and
reading it asks git nothing."
  (let ((tabs (ecc-space--tabs frame)))
    (delq nil (mapcar (lambda (tab)
                        (car (rassoc (alist-get 'name tab) tabs)))
                      (tab-bar-tabs frame)))))

(defun ecc-space-tab (space)
  "Return the name of the tab of SPACE, or nil.
A tab the user closed is forgotten here rather than offered again."
  (let ((name (alist-get (ecc-space-key space) (ecc-space--tabs)
                         nil nil #'equal)))
    (cond ((ecc-space--tab-index name) name)
          (name (ecc-space--drop-tab (ecc-space-key space))
                nil))))

(defun ecc-space--unique-tab-name (base)
  "Return BASE, or BASE with a suffix when a tab already goes by it.
Two worktrees of two repositories are called `main' as often as not."
  (ecc--unique-name base #'ecc-space--tab-index))

(defun ecc-space--forget-tab (tab &rest _)
  "Forget the Space of TAB, which is about to be closed.
On `tab-bar-tab-pre-close-functions'.  Nothing is stopped: the sessions
go on running with no window, which is what the sidebar and
`ecc-space-cycle-layout' bring back."
  (when-let* ((name (alist-get 'name tab))
              (key (car (rassoc name (ecc-space--tabs)))))
    (ecc-space--drop-tab key)))

(add-hook 'tab-bar-tab-pre-close-functions #'ecc-space--forget-tab)

(defvar ecc-space--laying-out nil
  "Non-nil while the windows of a Space are being laid out.
The transcripts are put on the screen one after another, and nothing
that happens to a session in between -- one that fails to come up, a
Space found with nothing running -- starts or closes anything.")

(defun ecc-space--source-buffer (space)
  "Return the buffer the source window of SPACE should hold, or nil."
  (let ((root (ecc-space-root space)))
    (or (ecc-window-project-source-buffer root)
        ;; A directory is a fair answer to where the source is, but only
        ;; if it is still there: a worktree whose directory was removed
        ;; under a Space that is still open would otherwise take the tab
        ;; down with an error instead of opening it empty.
        (and (file-directory-p root)
             (progn (require 'dired) (dired-noselect root))))))

(defun ecc-space--lay-out (space)
  "Fill the new tab of SPACE with the source of the project and its sessions.
One window with the code in it, which is what the user is looking at
when they ask for a project, and the sessions of the Space beside it:
going to a Space is asking to work there, and a tab that comes up with
the transcripts hidden is one the user has to unpack by hand.

A tab is a window arrangement and this is the only moment there is none
to keep: from here on the windows are the user\='s, and coming back to
the Space brings them back as they were left."
  ;; A tab carries its own windows, so the sidebar has to be put in
  ;; every one of them.  Loaded here rather than required: the sidebar
  ;; is built on the Spaces, so the dependency runs the other way.
  (require 'ecc-sidebar)
  ;; The code is put in front first: the layout leaves point in the
  ;; buffer it found it in, and a frame with no room for a session
  ;; still has room for this.
  (let ((buffer (ecc-space--source-buffer space)))
    (when (buffer-live-p buffer)
      (set-window-buffer (selected-window) buffer)))
  (ecc-sidebar-show)
  ;; A tab of the same name may have been laid out before and closed.
  (ecc-space--remember-layout nil)
  (ecc-space--build space (ecc-space--layout)))

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
Space puts it, and takes half of what it divides.

A tab laid out with no source on purpose -- the sessions side by side,
or four of them in a grid -- is somebody\='s arrangement, and is left
as it is: going to a Space is not asking for another layout."
  (unless (or (ecc-space--source-window)
              (memq (ecc-space--layout) '(pair grid)))
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
  (if ecc-use-spaces
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
      (ecc-window--focus-source root))
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
message says what happened -- and a worktree that is gone is left alone
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
repository is itself a linked worktree, and when its directory is gone."
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
brings its repository with it; see `ecc-space--ensure-parent\='.

`tab-bar-mode\=' is not turned on here.  A tab is a named window
configuration of the frame and the mode only draws the bar above it:
`tab-bar-new-tab\=' turns the mode on by itself where `tab-bar-show\=' is
t, its default, and leaves it off where the user set that to nil
\(verified 2026-09-17 on Emacs 32.0.50).  Whether the bar is shown is
theirs to say -- the sidebar lists the Spaces with more about each than
the bar can -- and this package has no opinion to force."
  (let ((name (ecc-space-tab space)))
    (if name
        (progn (ecc-space--quietly (tab-bar-select-tab-by-name name))
               (ecc-space--ensure-source space))
      (ecc-space--ensure-parent space)
      (setq name (ecc-space--unique-tab-name (ecc-space-name space)))
      (ecc-space--quietly
        (tab-bar-new-tab)
        (tab-bar-rename-tab name))
      (ecc-space--remember-tab (ecc-space-key space) name)
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
    (car (rassoc name (ecc-space--tabs)))))

(defun ecc-space-current ()
  "Return the Space that is showing, or nil.
With `ecc-use-spaces' that is the Space of the current tab; without it
there are no tabs of ours, so it is the project the current buffer is
in, the same one `ecc-start' would use."
  (if ecc-use-spaces
      (when-let* ((key (ecc-space-current-key)))
        (ecc-space-of-root key))
    (ecc-space-of-root (ecc-window-context-project-root))))

;;;; Showing a session in a Space

(defun ecc-space--session-windows ()
  "Return the windows of this tab showing a session, left to right."
  (sort (seq-filter (lambda (window)
                      (ecc-window-buffer-session (window-buffer window)))
                    (window-list nil 'no-minibuffer))
        (lambda (a b) (< (nth 0 (window-edges a)) (nth 0 (window-edges b))))))

(defun ecc-space--width-beside (width window)
  "Return the columns to take out of WINDOW for something WIDTH wide.
WIDTH is columns, or a fraction of the frame the way `display-buffer\='
reads one -- of the whole frame, the sidebar counted, which is how a
Space has always measured the column of its sessions.  Capped at what
leaves WINDOW `window-min-width\=', so the columns come out of WINDOW
and out of nothing else."
  (min (if (floatp width)
           (round (* width (window-total-width (frame-root-window window))))
         width)
       (- (window-total-width window) window-min-width)))

(defun ecc-space--split-off (window size side)
  "Split a window SIZE columns or lines wide off WINDOW, on SIDE, and return it.
A split that would leave either half under the least WINDOW can be --
`window-min-width\=' or `window-min-height\=', or more with a header line
or a margin -- signals an error, which is left to the caller.  The right
margin of a transcript is not counted, and is taken away first.

`window-combination-resize\=' is bound to nil so that the room comes out
of WINDOW alone: a user who set it would otherwise have every sibling
give a share, and the proportions a layout asks for would come out as
something else."
  (let ((horizontal (memq side '(left right))))
    ;; A transcript keeps what it has over `ecc-chat-text-width' in its
    ;; right margin, and `window-min-size' counts a margin: a transcript
    ;; filling a 215-column main area refused every split, and the key
    ;; said there was no room (recorded 2026-10-12).  The margin goes;
    ;; `ecc-chat--set-margins' sets it again once the window has its
    ;; new size.
    (when (and horizontal (ecc-window-buffer-session (window-buffer window)))
      (set-window-margins window (car (window-margins window)) nil))
    (let ((least (window-min-size window horizontal))
          (total (window-total-size window horizontal)))
      ;; Checked here because `split-window' does not: given SIZE, it
      ;; holds neither half to `window-min-width' and made a window of 78
      ;; columns and one of 2 out of 80 with that set to 27.  Only a
      ;; split with no SIZE is refused for it (Emacs 32.0.50, 2026-10-12).
      (when (or (< size least) (< (- total size) least))
        (error "No room in %s for a window %d wide" window size))
      (let ((window-combination-resize nil))
        (split-window window (- size) side)))))

(defun ecc-space--show-in-new (buffer window)
  "Show BUFFER in WINDOW, which was made for it, and return WINDOW.
Recorded the way `display-buffer\=' records a window it made, so that
quitting BUFFER there deletes the window rather than showing whatever
was in it before."
  (display-buffer-record-window 'window window buffer)
  (set-window-buffer window buffer)
  ;; A window `split-window' made shows the buffer of the window it was
  ;; split from, and `set-window-buffer' puts that buffer in its
  ;; history; `quit-window' then goes back to it rather than delete the
  ;; window, quit-restore or not, and a plan quit beside a transcript
  ;; left a second copy of the transcript in its place (Emacs 32.0.50,
  ;; 2026-10-12).  `display-buffer' clears the history of a window it
  ;; makes, after showing the buffer in it, and so does this.
  (set-window-prev-buffers window nil)
  window)

(defun ecc-space--display-beside (buffer window width &optional direction)
  "Show BUFFER in a new window WIDTH columns wide, beside WINDOW.
DIRECTION is which side of WINDOW it goes on, `right\=' by default.
WIDTH is read by `ecc-space--width-beside\='.  Return the new window, or
nil when WINDOW is too narrow to be divided at all.

The window is made with `split-window\=', not `display-buffer\='.  Asked
for a split it cannot make, `display-buffer\=' goes on to its other ways
of showing a buffer, and they put a session under the others (measured
2026-09-15, in an 80-column frame).  Asked for a width, it resizes with
every minimum and every `preserve-size\=' ignored, which took ten
columns out of the sidebar (measured 2026-09-22)."
  (when-let* ((new (condition-case nil
                       (ecc-space--split-off
                        window (ecc-space--width-beside width window)
                        (or direction 'right))
                     ;; Emacs refusing the split is the answer nil
                     ;; stands for here, not a failure.
                     (error nil))))
    (ecc-space--show-in-new buffer new)))

(defun ecc-space--window-used-longest-ago (windows)
  "Return the one of WINDOWS whose session was selected longest ago.
By use, as `ecc-window--sessions-by-use\=' reads it off `buffer-list\=':
the transcript nobody has looked at for longest is the one missed
least.  Not by start: the session started first is as often as not the
one being worked in."
  (cl-flet ((session-of (window)
              (ecc-window-buffer-session (window-buffer window))))
    (let ((oldest (car (last (ecc-window--sessions-by-use
                              (delete-dups (mapcar #'session-of windows)))))))
      (seq-find (lambda (window) (eq (session-of window) oldest)) windows))))

(defun ecc-space-display-session (session &optional no-reuse)
  "Show SESSION in the Space of its project and return its window.
A session already on the screen of this tab is left where it is.
Otherwise nothing is divided: the window of the session used longest
ago shows SESSION instead, and the one it held goes on running with no
window, which the sidebar and `ecc-space-cycle-layout\=' bring back.
How many sessions are on the screen, and where, is the layout\='s to
say, and showing one more is not asking for another layout.

Only a tab with no session window at all gets one: beside the source,
to the right, `ecc-window-width\=' wide.  It is an ordinary window, with
no role and no dedication: from here on it is the user\='s to arrange.

NO-REUSE says the caller would rather show nothing than take a window
away from another session: nil comes back instead, and the session goes
on running without a window."
  (require 'ecc-session)
  (let ((buffer (ecc-session-ensure-buffer session)))
    (ecc-space-select (ecc-space-of-root (ecc-window-session-project session)))
    (or (get-buffer-window buffer)
        (if-let* ((windows (ecc-space--session-windows)))
            (unless no-reuse
              (let ((window (ecc-space--window-used-longest-ago windows)))
                (set-window-buffer window buffer)
                window))
          ;; Told which window to split, so that the sidebar on the left
          ;; is not what gets divided (verified 2026-09-14).
          (ecc-space--display-beside
           buffer (or (ecc-window--source-window) (selected-window))
           ecc-window-width)))))

;;;; Laying a Space out

;; A layout is built from nothing, every time.  Every window of the tab
;; but the side windows goes, and the one left is divided to fixed
;; proportions with `split-window': the same frame and the same sessions
;; give the same windows, whatever the tab looked like before.  What it
;; replaced put the sessions in a row one split at a time, beside
;; whatever was there and widening the rightmost first, and every
;; arrangement it started from was one more way for that to go wrong:
;; transcripts crushed to two columns, ten columns out of the sidebar, a
;; sliver beside a wide transcript, a session put under the others.

(defvar ecc-space--layouts
  '((beside  "source + session"             0)
    (pair    "two sessions"                 2)
    (thirds  "source + two sessions"        2)
    (over    "two sessions over the source" 2)
    (stacked "source + two stacked"         2)
    (grid    "2x2 grid"                     3))
  "The layouts a Space is laid out in, in the order they are gone through.
Each is (NAME DESCRIPTION SESSIONS): what `ecc-space--split\=' knows it
by, what the echo area calls it, and the fewest sessions it needs.  The
first is the one a new tab gets.")

(defun ecc-space--split (layout main sessions)
  "Divide MAIN, the one window of the main area, for LAYOUT.
SESSIONS is how many sessions there are to show.  Return the windows in
the order they are filled: the window of the source first -- nil when
LAYOUT has none -- then one for each slot.  A split Emacs refuses
signals an error."
  (pcase layout
    ;; Source | P1.  The session column is as wide as it has always
    ;; been, `ecc-window-width' of the frame.
    ('beside
     (if (zerop sessions)
         (list main)
       (list main (ecc-space--split-off
                   main (ecc-space--width-beside ecc-window-width main)
                   'right))))
    ;; P1 | P2, the source hidden.
    ('pair
     (list nil main (ecc-space--split-off
                     main (/ (window-total-width main) 2) 'right)))
    ;; Source | P1 | P2, in thirds.
    ('thirds
     (let* ((total (window-total-width main))
            (rest (ecc-space--split-off main (- total (/ total 3)) 'right)))
       (list main rest (ecc-space--split-off
                        rest (/ (window-total-width rest) 2) 'right))))
    ;; P1 | P2 across the top three fifths, the source under them.
    ('over
     (let ((below (ecc-space--split-off
                   main (round (* 0.4 (window-total-height main))) 'below)))
       (list below main (ecc-space--split-off
                         main (/ (window-total-width main) 2) 'right))))
    ;; Source | the column of `beside', P1 over P2 in it.
    ('stacked
     (let ((column (ecc-space--split-off
                    main (ecc-space--width-beside ecc-window-width main)
                    'right)))
       (list main column (ecc-space--split-off
                          column (/ (window-total-height column) 2) 'below))))
    ;; P1 P2 over P3 P4.  With three sessions the fourth cell is the
    ;; source's, the slot having no session for it.
    ('grid
     (let* ((below (ecc-space--split-off
                    main (/ (window-total-height main) 2) 'below))
            (right (ecc-space--split-off
                    main (/ (window-total-width main) 2) 'right))
            (corner (ecc-space--split-off
                     below (/ (window-total-width below) 2) 'right)))
       (list nil main right below corner)))
    (_ (error "No layout called %s" layout))))

(defun ecc-space--slot-sessions (space)
  "Return the sessions of SPACE in the order the slots of a layout take them.
The session of the selected window first, which is the one being worked
in, and the rest by use, most recently selected first.  With no session
selected, by use alone."
  (let ((sessions (ecc-window--sessions-by-use (ecc-space-sessions space)))
        (current (ecc-window-buffer-session (window-buffer (selected-window)))))
    (if (memq current sessions)
        (cons current (delq current sessions))
      sessions)))

(defun ecc-space--main-window ()
  "Return the window of this tab a layout is built from, or nil.
The selected window when it is not a side window, so that what is
being read is what stays; else the first that is not."
  (seq-find (lambda (window) (not (window-parameter window 'window-side)))
            (cons (selected-window) (window-list nil 'no-minibuffer))))

(defun ecc-space--layout-source (space window)
  "Return the buffer the source of SPACE is shown in, laid out from WINDOW.
The source of the project when there is one; else what WINDOW is showing,
when that is not a buffer of this package -- a transcript there would
be on the screen twice."
  (let ((source (ecc-space--source-buffer space)))
    (cond ((buffer-live-p source) source)
          ((not (ecc-window-own-buffer-p (window-buffer window)))
           (window-buffer window))
          (t (get-scratch-buffer-create)))))

(defun ecc-space--build (space layout)
  "Lay SPACE out in the windows of this tab as LAYOUT, from nothing.
Every window of the tab goes but the side windows -- the sidebar asks
not to be deleted, and keeps its place and its width -- and the one left
is divided as `ecc-space--split\=' says: the source of the project, and
the sessions of SPACE by `ecc-space--slot-sessions\='.  A slot with no
session left for it shows the source; a session with no slot goes on
running with no window.

Return non-nil when LAYOUT was built.  When Emacs refuses to delete a
window or to make one of the splits -- a frame too small for it -- the
windows are put back as they were and nil comes back.

Point stays in the buffer it was in when that is still on the screen,
and goes to the first session when it is not.  It is moved without
touching `buffer-list\=', which is the order the slots are filled in:
laying the same Space out again keeps every session in its slot."
  (require 'ecc-session)
  (let* ((main (or (ecc-space--main-window)
                   (user-error "No window here to lay the Space out in")))
         (selected (window-buffer (selected-window)))
         (sessions (ecc-space--slot-sessions space))
         (source (ecc-space--layout-source space main))
         ;; A configuration rather than `window-state-get': a state keeps
         ;; only the parameters in `window-persistent-parameters', so the
         ;; sidebar came back from one without `no-delete-other-windows'
         ;; and the next layout tried deleted it (2026-10-12).  A
         ;; configuration puts back the windows themselves.
         (state (current-window-configuration))
         (windows nil))
    (condition-case nil
        (progn
          ;; Not `delete-other-windows', which keeps a side window only
          ;; when it carries `no-delete-other-windows'.  That parameter
          ;; does not survive a window state -- one put back by a
          ;; desktop, a package or, until it saved a configuration,
          ;; `ecc-space-zoom' (2026-10-12) -- and a side window of
          ;; anybody else's never had it.  A layout is of the main area,
          ;; so every side window is kept for being one.
          (dolist (window (window-list nil 'no-minibuffer))
            (unless (or (eq window main) (window-parameter window 'window-side))
              (delete-window window)))
          (setq windows (ecc-space--split layout main (length sessions))))
      ;; Only taking the tab down and dividing it are inside: a window
      ;; that will not be deleted, or a split the frame is too small for,
      ;; and the answer is the windows as they were rather than a tab
      ;; left half taken apart.
      (error (set-window-configuration state)))
    (when windows
      (let ((ecc-space--laying-out t)
            (slots (cdr windows)))
        (cl-loop for window in windows
                 for index from 0
                 for session = (and (> index 0) (pop sessions))
                 when window
                 do (let ((buffer (if session
                                      (ecc-session-ensure-buffer session)
                                    source)))
                      (set-window-dedicated-p window nil)
                      (if (eq window main)
                          ;; What it was quitting back to is gone with
                          ;; the arrangement it belonged to.
                          (progn (set-window-parameter window 'quit-restore nil)
                                 (set-window-buffer window buffer))
                        (ecc-space--show-in-new buffer window))))
        (select-window (or (get-buffer-window selected)
                           (car slots)
                           (car windows))
                       'norecord))
      t)))

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

(defvar ecc-space--divide-right-width 80
  "Columns each half of a session window divided to the right must have.
What `ecc-space-display-beside-session' asks of a transcript it has to
divide for a question or a plan: twice this wide, the two halves stand
side by side, each a transcript or a plan one can read; narrower, the
buffer goes below the transcript instead.")

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
session window divided: to the right when each half would be
`ecc-space--divide-right-width' wide, below it when not, and never so
that a transcript is lost."
  (require 'ecc-session)
  (let ((session-window (ecc-space-display-session session)))
    (or (get-buffer-window buffer)
        (when-let* ((source (ecc-space--popup-window)))
          (ecc-space--display-in buffer source))
        (when (window-live-p session-window)
          (if (>= (window-total-width session-window)
                  (* 2 ecc-space--divide-right-width))
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

(defun ecc-space--forget-zoom ()
  "Forget the arrangement `ecc-space-zoom\=' saved for this tab.
Zooming and putting back are two halves of one key, so the way back is
thrown away as it is taken -- and `ecc-space-cycle-layout\=' throws it
away too, the arrangement it was the way back to having just gone."
  (let ((saved (frame-parameter nil 'ecc-space-zoom)))
    (setf (alist-get (ecc-window--layout-key) saved nil 'remove #'equal) nil)
    (set-frame-parameter nil 'ecc-space-zoom saved)))

;;;###autoload
(defun ecc-space-zoom ()
  "Fill the tab with the window point is in, or put the windows back.
The arrangement is kept per tab, so a Space zoomed in one is not
zoomed in another.  A side window that asked not to be deleted -- the
sidebar -- stays where it is (verified 2026-09-14)."
  (interactive)
  (let* ((key (ecc-window--layout-key))
         (saved (frame-parameter nil 'ecc-space-zoom))
         (configuration (alist-get key saved nil nil #'equal)))
    ;; Only a configuration of this frame is a way back.  A frame made
    ;; by `clone-frame' inherits the parameter, and putting back a
    ;; configuration of another frame rearranges that frame; a desktop
    ;; restores it as the string "Unprintable entity".  `tab-bar' makes
    ;; the same check before putting a tab back from one.  Anything else
    ;; is no zoom, and the next zoom saves over it.
    (unless (and (window-configuration-p configuration)
                 (eq (window-configuration-frame configuration)
                     (selected-frame)))
      (setq configuration nil))
    (cond
     (configuration
      (ecc-space--forget-zoom)
      (set-window-configuration configuration)
      (message "Windows as they were"))
     ;; A side window cannot be made the only window, and the sidebar is
     ;; one.  Saying so beats the error `delete-other-windows' raises.
     ((window-parameter (selected-window) 'window-side)
      (user-error "This window cannot fill the tab on its own"))
     ;; Nothing to put away.  Saving the windows here would be worse than
     ;; doing nothing: the key would then be "zoomed" without the screen
     ;; having changed, and the way back would do nothing either.
     ((null (ecc-space--zoomable-windows))
      (message "Nothing to zoom: there is no other window to put away"))
     (t
      ;; A window configuration, not a window state.  A state keeps only
      ;; the parameters in `window-persistent-parameters', so the sidebar
      ;; came back from one without `no-delete-other-windows' and the
      ;; next zoom deleted it with the rest (2026-10-12, Emacs 32.0.50).
      ;; A configuration puts back the windows themselves, parameters and
      ;; all, and the point moved in the zoomed window stays where it was
      ;; moved to.  It outlives leaving the tab and coming back: the tab
      ;; bar puts a tab back from a configuration of the same windows.
      (setf (alist-get key saved nil nil #'equal)
            (current-window-configuration))
      (set-frame-parameter nil 'ecc-space-zoom saved)
      (delete-other-windows)
      (message "Zoomed; the same key puts the windows back")))))

;; The layout a tab was last given is kept on the frame, per tab, the
;; way the zoom of `ecc-space-zoom' is: a Space laid out in thirds in one
;; tab is not in thirds in another.

(defun ecc-space--layout ()
  "Return the layout this tab was last given, the first of them by default."
  (or (alist-get (ecc-window--layout-key) (frame-parameter nil 'ecc-space-layout)
                 nil nil #'equal)
      (caar ecc-space--layouts)))

(defun ecc-space--remember-layout (layout)
  "Remember LAYOUT as the one this tab was given; nil forgets it."
  (let ((saved (frame-parameter nil 'ecc-space-layout)))
    (setf (alist-get (ecc-window--layout-key) saved nil 'remove #'equal) layout)
    (set-frame-parameter nil 'ecc-space-layout saved)))

(defun ecc-space--layouts-from (layout)
  "Return the names of the layouts, LAYOUT first and the rest after it in turn."
  (let* ((names (mapcar #'car ecc-space--layouts))
         (tail (memq layout names)))
    (append tail (butlast names (length tail)))))

(defun ecc-space--cycling-p ()
  "Return non-nil when the command before this one was a layout of a Space.
The obsolete name counts: \\[execute-extended-command] can still reach
it, and pressing the key after it is going on from there."
  (memq last-command '(ecc-space-cycle-layout ecc-space-reset-windows)))

(defvar-keymap ecc-space-layout-repeat-map
  :doc "The key that goes on to the next layout of a Space under `repeat-mode'."
  :repeat t
  "V" #'ecc-space-cycle-layout)

;;;###autoload
(defun ecc-space-cycle-layout (&optional first)
  "Lay this Space out again, from nothing, or in the next layout.
Pressed right after itself, it goes on to the next layout of the
Space; pressed after anything else, it builds the layout this tab was
last given again, which puts back a tab that has been split, zoomed,
filled with a review or given over to transcripts.  With a prefix
argument FIRST it goes back to the first layout, the one a new tab
gets.  Under `repeat-mode' the last key alone goes on cycling.

The layouts, in turn, with the source of the project S and the sessions
P1, P2...:

  source + session       S | P1, the column `ecc-window-width' wide
  two sessions           P1 | P2, the source hidden
  source + two sessions  S | P1 | P2, in thirds
  sessions over source   P1 | P2 above, S across the bottom two fifths
  source + two stacked   S | P1 over P2, the column as wide as the first
  2x2 grid               P1 P2 over P3 P4; with three sessions, S in P4\='s cell

P1 is the session in the selected window, or else the one used most
recently, and the rest follow by use; going from one layout to the next
keeps every session in its slot.  The sessions with no slot go on
running with no window.  A layout that needs more sessions than the
Space has is passed over, and so is one the frame is too small for:
Emacs refusing a split puts the windows back as they were and the next
layout is tried.

The sidebar stays as it is: it is a side window that asked not to be
deleted, and keeps its place and its width; one that was hidden stays
hidden.  The zoom of this Space is forgotten: the arrangement it was
the way back to has just gone, and `ecc-space-zoom\=' afterwards zooms
from here.

A `spaces\=' command.  Under `classic\=' a transcript lives in a side
window with a role, and `ecc-focus-project\=' is what deals those out
again."
  (interactive "P")
  (unless ecc-use-spaces
    (user-error "Laying the windows out needs `ecc-use-spaces'; \
without it the roles are dealt out by `ecc-focus-project'"))
  (let* ((space (or (ecc-space-current)
                    (user-error "This tab is not a Space; `C-c c j' goes to one")))
         (count (length (ecc-space-sessions space)))
         (current (ecc-space--layout))
         (next (and (not first) (ecc-space--cycling-p)))
         (candidates
          (seq-filter
           (lambda (name)
             (and (<= (nth 2 (assq name ecc-space--layouts)) count)
                  ;; Going on, the layout on the screen is where the
                  ;; cycle starts, not somewhere to go.
                  (not (and next (eq name current)))))
           (ecc-space--layouts-from
            (cond (first (caar ecc-space--layouts))
                  (next (cadr (ecc-space--layouts-from current)))
                  (t current)))))
         (built (seq-find (lambda (layout) (ecc-space--build space layout))
                          candidates)))
    (cond
     (built
      (ecc-space--forget-zoom)
      (ecc-space--remember-layout built)
      (message "Layout: %s" (nth 1 (assq built ecc-space--layouts))))
     (next
      (message "No other layout for %s: %s" (ecc-space-name space)
               (if candidates
                   "this frame is too small"
                 (format "%d session%s" count (if (= 1 count) "" "s")))))
     (t
      (user-error "No room in this frame to lay %s out"
                  (ecc-space-name space))))))

(define-obsolete-function-alias 'ecc-space-reset-windows
  #'ecc-space-cycle-layout "0.4.2")

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

A worktree that has been removed is left out: its recordings are still
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

(defun ecc-space--candidates (spaces past)
  "Return an alist of a candidate to its Space, for SPACES and then PAST.
The candidate is the title of the Space, `ecc-space-title\=', and nothing
else: the mark, the number, the tree line and the directory are put
around it as it is shown, so that what is typed is matched against the
name alone.  Two Spaces that would go by the same title are told apart
the way their tabs are, `main<2>\='."
  (let ((candidates nil))
    (dolist (space (append spaces past))
      (push (cons (ecc--unique-name (ecc-space-title space)
                                    (lambda (title) (assoc title candidates)))
                  space)
            candidates))
    (nreverse candidates)))

(defun ecc-space--affixes (candidates spaces)
  "Return an alist of each of CANDIDATES to the prefix and suffix it is shown with.
CANDIDATES is what `ecc-space--candidates\=' returns and SPACES the
Spaces on the screen.  The prefix is what the sidebar puts in front of
a row -- the mark of the Space\='s state, its number and the tree line
of a worktree -- in the order mark, number, line, so that the marks and
the numbers stand in columns of their own.  A Space with nothing
running gets a blank for the mark.  A past one gets a blank for both
and no tree line, and none of the three is worked out for it: it is not
on the screen, so it has no state and no number, and a worktree of a
repository that is would otherwise be drawn as one of its children,
under `Past\=', with nothing above it.  The suffix is the directory,
dimmed, in a column after the longest line, with a dimmed `past\=' in
front of it on a past line: the default *Completions* shows no group
headings unless `completions-group\=' is on, and without one that word
is all that tells a past project from an open Space with nothing in it."
  (let* ((blank (concat (ecc-tab-column-mark nil) " "
                        (ecc-space-number-label nil spaces) " "))
         (prefixes
          (mapcar (lambda (entry)
                    (let ((space (cdr entry)))
                      (if (ecc-space-past space)
                          blank
                        (concat (ecc-tab-column-mark (ecc-space-state space))
                                " "
                                (ecc-space-number-label
                                 (ecc-space-number space spaces) spaces)
                                " "
                                (ecc-space-tree-line space spaces)))))
                  candidates))
         (column (+ 2 (apply #'max
                             (cl-mapcar (lambda (entry prefix)
                                          (+ (string-width prefix)
                                             (string-width (car entry))))
                                        candidates prefixes)))))
    (cl-mapcar
     (lambda (entry prefix)
       (list (car entry) prefix
             (concat (make-string (- column (string-width prefix)
                                     (string-width (car entry)))
                                  ?\s)
                     (propertize (concat (if (ecc-space-past (cdr entry))
                                             "past "
                                           "     ")
                                         (abbreviate-file-name
                                          (ecc-space-root (cdr entry))))
                                 'face 'completions-annotations))))
     candidates prefixes)))

(defun ecc-space--table (candidates spaces)
  "Return a completion table of CANDIDATES, grouped and kept in order.
CANDIDATES is what `ecc-space--candidates\=' returns and SPACES the
Spaces on the screen.  The groups are `Open\=', the Spaces on the
screen in the order the sidebar numbers them, and `Past\=', the projects
only recordings are left of, newest first; sorting the candidates
would throw both orders away.

What goes around a name is an `affixation-function\='s and not the
`group-function\='s transform, the way the session picker does it.  The
default *Completions* calls a `group-function\=' only with
`completions-group\=' on, which it is not by default, and an
`affixation-function\=' always; vertico calls both, the affixation on
the candidate it has already highlighted what matched in, and the
prefix and suffix are outside the candidate either way, so the match
highlighting is the UI\='s own (both read 2026-10-12, in Emacs
32.0.50\='s minibuffer.el and vertico 20260913).  marginalia stands in
its own affixation only for a category it has an annotator for, and
this table has no category."
  ;; Both functions are called for every line on every redisplay, so a
  ;; line is found in a table rather than by walking the lists.  `equal'
  ;; ignores text properties, and so does its hash: a candidate the UI
  ;; has put its match faces on is found all the same.
  (let ((lines (make-hash-table :test #'equal)))
    (cl-mapc (lambda (entry affix)
               (puthash (car entry) (cons (cdr entry) (cdr affix)) lines))
             candidates (ecc-space--affixes candidates spaces))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          `(metadata
            (group-function
             . ,(lambda (candidate transform)
                  (let ((space (car (gethash candidate lines))))
                    (cond (transform candidate)
                          ((and space (ecc-space-past space)) "Past")
                          (t "Open")))))
            (affixation-function
             . ,(lambda (strings)
                  ;; The string handed in, not the one kept here: it
                  ;; carries the faces of what matched.
                  (mapcar (lambda (string)
                            (cons string
                                  (or (cdr (gethash string lines))
                                      (list "" ""))))
                          strings)))
            (display-sort-function . identity)
            (cycle-sort-function . identity))
        (complete-with-action action candidates string predicate)))))

(defun ecc-space-read (&optional prompt open-only)
  "Ask which Space to use, with PROMPT.
The Spaces on the screen come first, under `Open\=', in the order they
are numbered, and the projects only recordings are left of follow under
`Past\=' unless OPEN-ONLY says to leave them out -- for a command that
has nothing to do to a Space that is not open.  Each is offered by its
name, `ecc-space-title\=', and shown the way the sidebar draws it, with
the mark of its state, its number, the tree line of a worktree, and its
directory after it."
  (let* ((spaces (ecc-space-list))
         (past (and ecc-use-spaces (not open-only)
                    (ecc-space-past-projects))))
    (unless (or spaces past)
      (user-error (if open-only
                      "No Space is open"
                    "No project has a session, a tab or a recording")))
    (let* ((candidates (ecc-space--candidates spaces past))
           (choice (completing-read (or prompt "Space: ")
                                    (ecc-space--table candidates spaces)
                                    nil t)))
      ;; REQUIRE-MATCH lets an empty answer through: RET with nothing
      ;; typed returns "" under the default completion.
      (or (cdr (assoc choice candidates))
          (user-error "No Space chosen")))))

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

The worktrees of the group are offered afterwards, in one question:
their Spaces are gone and nothing is left running in them, so this is
the moment somebody is thinking about the directories.  Answering no
leaves them where they are, and `ecc-remove-worktree' still undoes one
by itself."
  (interactive (list (or (ecc-space-current) (ecc-space-read "Close Space: " t))))
  ;; Everything is read before the first kill: closing a session closes
  ;; the Space it was the last of, and the children would be gone from
  ;; `ecc-space-list' halfway through the loop.
  (let* ((spaces (ecc-space-list))
         (children (ecc-space-children space spaces))
         (group (cons space children))
         (sessions (seq-mapcat #'ecc-space-sessions group)))
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
      (dolist (one group)
        (ecc-space--close-tab-everywhere (ecc-space-key one))
        (setq ecc-space--implicit
              (delete (ecc-space-key one) ecc-space--implicit))))
    (ecc-space--child-gone space)
    (message "Closed %s" (ecc-space--group-name space children))
    ;; Asked outside the `ecc-space--closing' above: the tabs are gone
    ;; by now, and the kills under it have already told
    ;; `ecc-worktree--session-removed' to stay quiet about this group.
    (ecc-worktree-offer-group-removal
     (delq nil (mapcar (lambda (one)
                         (and (ecc-space-parent one) (ecc-space-root one)))
                       group)))))

(defun ecc-space--group-name (space children)
  "Return what to call SPACE and the CHILDREN closing with it."
  (if children
      (format "%s and %s" (ecc-space-name space)
              (string-join (mapcar #'ecc-space-name children) ", "))
    (ecc-space-name space)))

(defun ecc-space-forget (root)
  "Close the tab of the Space at ROOT and forget it.
For a worktree that is about to be removed: once the directory is gone
the Space is nowhere to go back to, and a tab left behind keeps it in
`ecc-space-list\=' and in the sidebar with nothing underneath it.  Call
this while ROOT is still there, so the key it groups under is the one
its sessions used.

The sessions are not touched: whoever removes a worktree stops them
first.  A sole tab is forgotten rather than closed, Emacs refusing to
delete the last one."
  (let* ((key (ecc-window-project-key root))
         (space (ecc-space-of-root key)))
    (ecc-space--close-tab-everywhere key)
    (setf (alist-get key ecc-space--used nil 'remove #'equal) nil)
    (setq ecc-space--implicit (delete key ecc-space--implicit))
    ;; Asked while ROOT is still there: once the worktree is gone git
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

A transcript window with a tab line is a row of tabs, and one tab of it
closing is not the window closing: the window is given the tab beside
the one that went (`ecc-tab-line-neighbour') and stays where it is.
The question is put once for every window, and with the frame it is on:
the transcripts of a Space stand side by side under one row of tabs, and
a tab the window next door is already showing is not a tab to move to.
With nothing left to show -- no tab, or none that is not on the screen
already -- the window goes as it always did.  The stream buffer carries
no tab line and is not part of any row, so its window is only ever
deleted.

The tab is put there with `ecc-space--display-in' rather than
`set-window-buffer': the window still carries the `quit-restore' of the
transcript that has just gone, and Emacs 32 resizes a window back to
the width recorded with it.

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
          (let ((neighbour (and (eq buffer (ecc-session-buffer session))
                                (ecc-tab-line-neighbour
                                 session (window-frame window)))))
            (cond
             (neighbour (ecc-space--display-in neighbour window))
             ((eq (window-deletable-p window) t)
              (delete-window window))
             (t (when-let* ((space (ecc-space-current))
                            (source (ecc-space--source-buffer space))
                            ((buffer-live-p source)))
                  (set-window-buffer window source))))))))))

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
  (when ecc-use-spaces
    (ecc-space--delete-session-windows session)
    (when-let* (((not ecc-space--closing))
                ((not ecc-space--laying-out))
                ((ecc-model-own-session-p session))
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
  (when (and ecc-use-spaces
             (not ecc-space-always-session)
             (not ecc-space--closing))
    (when-let* ((directory (ecc-window-buffer-directory (current-buffer)))
                (key (ecc-window-project-key directory))
                ((alist-get key (ecc-space--tabs) nil nil #'equal))
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
