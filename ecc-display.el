;;; ecc-display.el --- Showing a session  -*- lexical-binding: t; -*-

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

;; Showing a session, and the Spaces it is shown in.
;;
;; A Space is a project -- a repository, or a worktree of one -- with a
;; tab of the tab bar to itself, and every session is shown in the Space
;; of its project.  This file holds what a Space is (the model, worked
;; out from the sessions and from git alone), the tabs underneath it, the
;; layouts its windows are dealt in, and every way a session reaches the
;; screen: in its window, a buffer beside it, a review beside it, another
;; session switched into a window.  It also holds the session picker,
;; which groups the sessions by Space, and the project a command means,
;; which the tab showing is the second answer to.
;;
;; Every module that shows a session comes here -- a question answered,
;; the sidebar, a recording opened, a restore -- and the buffer shown is
;; made by `ecc-chat', with the prompt in it.  So this file sits above
;; `ecc-chat' and below all of those.  `ecc-window', below `ecc-chat',
;; keeps to the projects, the source buffers and the regions.  The
;; commands on a Space -- going to one, closing one, the layouts cycled,
;; the zoom -- are `ecc-space', above everything that shows a session:
;; going to a Space with nothing running starts a session there, and
;; nothing here starts one.
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
(require 'ecc-git)
(require 'ecc-window)
(require 'ecc-chat)

;; A tab carries its own windows, so every new Space tab is given the
;; sidebar (`ecc-space--lay-out'), and a Space that closes redraws it
;; (`ecc-space--close-empty').  The sidebar draws the Spaces and so is
;; built on this file; it is loaded where it is called.  This is the one
;; call from here into a module above, and it is kept on purpose: the
;; sidebar is in every Space tab from the first one on, which a
;; subscription that started once the sidebar was shown would not give.
(declare-function ecc-sidebar-show "ecc-sidebar" ())
(declare-function ecc-sidebar-redraw "ecc-sidebar" (&rest _))

;;;; Settings

(defvar ecc-window-width 0.4
  "Width of the session column of a Space, as a fraction or a column count.
A fraction is of the whole frame, the sidebar counted.  It is the
column a lone session is put in beside the source, and the column of
the `beside' and `stacked' layouts of `ecc-space-cycle-layout'.")

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
  (if (and parent branch)
      (string-remove-prefix "worktree/" branch)
    (ecc-window-project-name root)))

(defun ecc-space-of-root (root)
  "Return the Space of the project ROOT belongs to."
  (let* ((key (ecc-window-project-key root))
         (main (ecc-git-main-worktree key))
         (parent (and main (ecc-window-project-key main)))
         (branch (ecc-git-branch key)))
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
  "Remember that the Space KEY lives in the tab called NAME on FRAME.
This is where the first Space comes to be, so the global hooks the
Spaces need go on here and not when the file is loaded: before it there
is no tab to forget and no Space to close.  They go on as they are, and
each decides for itself when it runs whether there is anything to do,
since the settings it reads can change after."
  (add-hook 'tab-bar-tab-pre-close-functions #'ecc-space--forget-tab)
  (add-hook 'kill-buffer-hook #'ecc-space--forget-on-source-kill)
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
reading it asks git nothing.

The frame's `tabs' parameter is read rather than `tab-bar-tabs', which
on a frame that has never had a tab makes the first one and runs
`tab-bar-tab-post-open-functions' for it: the save that read it was
then announced a tab opened and scheduled a second save (Emacs 32.0.50,
2026-10-18).  A frame without the parameter has no Space tab."
  (let ((tabs (ecc-space--tabs frame)))
    (delq nil (mapcar (lambda (tab)
                        (car (rassoc (alist-get 'name tab) tabs)))
                      (frame-parameter frame 'tabs)))))

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
  ;; every one of them; see the `declare-function' at the top.
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
Opening the repository selects its Space, and the key is held here so
that nothing that selects it again goes looking for a repository again.")

(defun ecc-space--parent-space (space)
  "Return the Space of the repository SPACE was checked out from, or nil.
Nil when SPACE is not a worktree, when the repository has a Space
already -- a tab or a session of its own -- when git says the
repository is itself a linked worktree, and when its directory is gone."
  (when-let* ((parent (ecc-space-parent space))
              ((not (member parent (ecc-space--keys))))
              ((not (member parent ecc-space--ensuring-parent)))
              ((file-directory-p parent))
              ((not (ecc-git-main-worktree parent))))
    (ecc-space-of-root parent)))

(defun ecc-space--ensure-parent (space)
  "Open the Space of the repository SPACE was checked out from.
A worktree with no repository above it is a child with nothing to hang
under: `ecc-space-list' leaves it at the top of the sidebar, and the
tree the Spaces are drawn in says nothing about where it came from.  So
opening a worktree opens the repository too, the way herdr's
`ensure_source_parent_membership' does.

The tab is made before the tab of SPACE, so the worktree is what the
user is left looking at.  Nothing is started here.  Going to the
worktree with `ecc-space-select' starts a session in the repository
too, under `ecc-space-always-session'; a worktree shown any other way --
a session started in it, a recording opened, a restore -- leaves the
repository's tab with nothing running in it until the user goes there."
  (when-let* ((parent (ecc-space--parent-space space)))
    (let ((ecc-space--ensuring-parent
           (cons (ecc-space-key parent) ecc-space--ensuring-parent)))
      (ecc-space--select-tab parent)
      (push (ecc-space-key parent) ecc-space--implicit))))

(defun ecc-space--select-tab (space)
  "Show SPACE in its tab, making the tab when it has none.
A worktree opened for the first time brings its repository with it; see
`ecc-space--ensure-parent\='.  Nothing is started: a Space with nothing
running in it gets a session when the user goes there, through
`ecc-space-select\=', and not when a session is shown.

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
    name))

(defun ecc-space-current-key ()
  "Return the Space key of the tab that is showing, or nil.
Nil when the tab is not one of ours, which is what says that the user
went somewhere this package has no opinion about."
  (when-let* ((tab (and (fboundp 'tab-bar--current-tab) (tab-bar--current-tab)))
              (name (alist-get 'name tab)))
    (car (rassoc name (ecc-space--tabs)))))

(defun ecc-space-current ()
  "Return the Space of the tab that is showing, or nil."
  (when-let* ((key (ecc-space-current-key)))
    (ecc-space-of-root key)))

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
  (let ((buffer (ecc-session-ensure-buffer session)))
    (ecc-space--select-tab (ecc-space-of-root (ecc-window-session-project session)))
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


;;;; Forgetting a Space

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

(defun ecc-space--close-empty (space)
  "Close SPACE, which has nothing left in it.
The tab goes, which is what takes the user to the Space beside it, and
the key is forgotten everywhere it was written down."
  (let ((ecc-space--closing t))
    (ecc-space-forget (ecc-space-root space))
    (setq ecc-space--implicit
          (delete (ecc-space-key space) ecc-space--implicit)))
  (ecc-space--child-gone space)
  ;; See the `declare-function' at the top.
  (require 'ecc-sidebar)
  (ecc-sidebar-redraw)
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

(defun ecc-space--forget-on-source-kill ()
  "Close the Space of the buffer being killed when nothing else is left.
The other half of `ecc-space-always-session': with the setting off a
Space is kept alive by its source, so killing the last buffer of the
project is what closes it.  On `kill-buffer-hook'."
  (when (and (not ecc-space-always-session)
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

;;;; The windows of a tab

(defun ecc-window--layout-key ()
  "Return the key an arrangement of this tab is stored under.
A frame with tabs keeps a layout per tab, so the zoom of
`ecc-space-zoom' is kept per tab as well.

The frame\='s own `tabs' parameter is what is asked, not `tab-bar-mode':
tabs are made, named and switched with the bar hidden exactly as with
it shown, `tab-bar-show' nil being a supported way to run the Spaces, and
keying on the mode would put every tab of such a frame on one list.
`tab-bar--current-tab' is not asked either: with no tabs at all it
invents one named after the buffer that is showing, which drifts as the
buffer changes, and writes the parameter while it is at it (verified
2026-09-17 on Emacs 32.0.50).

A lone tab counts only when it was named on purpose.  `explicit-name'
is what tells a tab this package made from the one Emacs names after
whatever buffer happens to be in it."
  (let* ((tabs (frame-parameter nil 'tabs))
         (current (assq 'current-tab tabs)))
    (or (and current
             (or (cdr tabs) (alist-get 'explicit-name current))
             (alist-get 'name current))
        'frame)))

(defun ecc-window--source-window ()
  "Return the window of this tab the source code belongs in, or nil.
The largest window that is not a side window, which is where a lone
session is split off beside the source.  `window-main-window' is no use
here: with the windows of a layout open the main area is split, and
what comes back is the internal window above them."
  (car (sort (seq-remove (lambda (window) (window-parameter window 'window-side))
                         (window-list nil 'no-minibuffer))
             (lambda (a b) (> (window-body-height a) (window-body-height b))))))

;;;; Showing a session

(defun ecc-display-session (session)
  "Show the buffer of SESSION in the Space of its project; return its window.
The window is not selected; `ecc-window-select-session' does that.
Where it is shown is `ecc-space-display-session'."
  (ecc-space-display-session session))

(defun ecc-window-display-beside-session (buffer session &optional no-select)
  "Show BUFFER beside the window of SESSION and return the window.
Everything that opens a buffer of its own out of one conversation goes
through here: a question, a plan, a log, an agent transcript, a node
laid open.  Where it lands is `ecc-space-display-beside-session\=', which
never takes the window of another session.

The window is selected unless NO-SELECT says otherwise: the buffer is
opened to be read or answered."
  (let ((window (ecc-space-display-beside-session buffer session)))
    (when (and (not no-select) (window-live-p window))
      (select-window window))
    window))

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
every session, and nil leaves the windows as they are, which is the
default.

What was hidden is not written down.  The way back is
`ecc-space-cycle-layout\=', which deals the tab again, or
`ecc-show-session\=' one session at a time.")

(defvar ecc-window-review-focus 'review
  "Where point goes when a diff or a plan review opens.
`review' selects the review, `session' leaves it in the transcript and
nil leaves it wherever it was.")

(defun ecc-window-hide-for-review (&optional session)
  "Take the session windows `ecc-window-hide-on-review\=' asks for off the screen.
SESSION is the session being reviewed, which decides what `project'
means.  This is the half of opening a review that a review shown by
something other than `display-buffer\=' -- ediff lays out its own
windows -- still wants."
  (ecc-window-hide-sessions
   (pcase ecc-window-hide-on-review
     ('all (ecc-model-sessions))
     ('project (if session
                   (ecc-window-project-sessions
                    (ecc-session-project-root session))
                 (ecc-window-project-sessions)))
     (_ nil))))

(defun ecc-window-display-review (buffer &optional session)
  "Show the review in BUFFER, of SESSION, and return its window.
`ecc-window-hide-on-review' and `ecc-window-review-focus' decide what
happens to the session windows and where point lands."
  (ecc-window-hide-for-review session)
  (let ((window (if session
                    (ecc-window-display-beside-session buffer session t)
                  (display-buffer buffer))))
    (pcase ecc-window-review-focus
      ('review (when (window-live-p window) (select-window window)))
      ('session
       (when-let* ((buffer (and session (ecc-session-buffer session)))
                   (session-window (and (buffer-live-p buffer)
                                        (get-buffer-window buffer))))
         (select-window session-window))))
    window))

(defun ecc-window-show-review-quietly (buffer session &optional replaceable)
  "Show the review in BUFFER beside SESSION without moving anybody.
Returns the window that shows it, or nil.  This is how a review Claude
opened or moved reaches the screen: the user is somewhere else -- very
likely typing in the prompt -- so nothing is selected, no session
window is hidden, and `ecc-window-review-focus\=' and
`ecc-window-hide-on-review\=' are not consulted, both being about a
review the user asked for.

A review already on a visible frame is left where it is.  Otherwise it
is shown only when SESSION is on the screen of the selected frame --
which is the tab showing, so no tab or Space is ever gone to -- and
never in the window the user is in: the selected one, or the one the
minibuffer was entered from.  REPLACEABLE, a predicate on a buffer,
names what may be put out of its window -- another review of the same
session, so that a second review takes the window of the first rather
than dividing the session again.  Then the widest window holding
nothing of this package, then a new one divided off the session\='s.
Not `ecc-window-display-beside-session\=': that selects
the Space of the session, and may pick the very window the user is
typing in, which would then take their next keys.  Where there is no
such window the review waits in its buffer, and nil says so.

A rule of the user\='s own in `display-buffer-alist\=' that matches
BUFFER is followed instead (`ecc-window--display-by-rule\=') -- as long
as it too leaves the user\='s window, and tab, alone."
  (or (get-buffer-window buffer 'visible)
      (when-let* ((session-buffer (ecc-session-buffer session))
                  ((buffer-live-p session-buffer))
                  (session-window (get-buffer-window session-buffer)))
        (if (ecc-window--user-rule-p buffer)
            (ecc-window--display-by-rule buffer)
          (pcase (ecc-window--quiet-review-window session-window replaceable)
            (`(,window . ,type)
             ;; `window' for a window made for it, so that `quit-window'
             ;; deletes it; `reuse' for one it borrowed, so that the
             ;; buffer that was there comes back.  A new window also
             ;; forgets the buffer `split-window' gave it to begin with,
             ;; as `display-buffer' has it forget: with that one in its
             ;; history `quit-window' shows it again rather than deleting
             ;; the window (Emacs 32.0.50, 2026-10-01).
             (display-buffer-record-window type window buffer)
             (set-window-buffer window buffer)
             (when (eq type 'window)
               (set-window-prev-buffers window nil))
             window))))))

(defun ecc-window--users-windows ()
  "Return the windows the user is working in.
The selected one, and while the minibuffer is active the one it was
entered from -- the window a \\[find-file] or an \\[execute-extended-command] goes back to."
  (delq nil (list (selected-window) (minibuffer-selected-window))))

(defun ecc-window--quiet-review-window (session-window replaceable)
  "Return (WINDOW . TYPE) for a review to go in quietly beside SESSION-WINDOW.
TYPE is `reuse\=' for a window that shows something else now and `window\='
for one divided off SESSION-WINDOW.  REPLACEABLE is the predicate of
`ecc-window-show-review-quietly\='.  Nil when there is none."
  (let* ((users (ecc-window--users-windows))
         (free (seq-filter (lambda (window)
                             (and (not (memq window users))
                                  (not (window-parameter window 'window-side))
                                  (not (window-dedicated-p window))))
                           (window-list nil 'no-minibuffer)))
         (widest (lambda (windows)
                   (car (sort windows (lambda (a b) (> (window-total-width a)
                                                       (window-total-width b))))))))
    (if-let* ((window (or (and replaceable
                               (funcall widest
                                        (seq-filter (lambda (window)
                                                      (funcall replaceable
                                                               (window-buffer window)))
                                                    free)))
                          (funcall widest
                                   (seq-remove (lambda (window)
                                                 (ecc-window-own-buffer-p
                                                  (window-buffer window)))
                                               free)))))
        (cons window 'reuse)
      (when-let* ((window (ecc-window--split-quietly session-window)))
        (cons window 'window)))))

(defvar ecc-window-quiet-split-min-height 8
  "Fewest lines each half has when a review divides a session window.")

(defun ecc-window--split-quietly (session-window)
  "Divide SESSION-WINDOW for a review and return the new window, or nil.
To the right when it has room for two columns of 80, which is what a
diff wants to be read in; below it when it has room for two halves of
`ecc-window-quiet-split-min-height\=' lines; not at all otherwise, nor
when it is a side window.  The selected window stays selected and keeps
its buffer: the new window is the other half.  The room is measured
first, so that a window too small to divide is an answer and not an
error, and any other error of `split-window\=' is left to be seen."
  (unless (window-parameter session-window 'window-side)
    (let ((direction
           (cond ((>= (window-total-width session-window) 160) 'right)
                 ((>= (window-total-height session-window)
                      (* 2 (max ecc-window-quiet-split-min-height window-min-height)))
                  'below))))
      (when direction
        (split-window session-window nil direction)))))

(defun ecc-window--user-rule-p (buffer)
  "Return non-nil when `display-buffer-alist\=' has a rule for BUFFER."
  (seq-some (lambda (entry)
              (buffer-match-p (car entry) (buffer-name buffer) nil))
            display-buffer-alist))

(defun ecc-window--display-by-rule (buffer)
  "Show BUFFER the way the user\='s `display-buffer-alist\=' says, or not at all.
Returns the window, or nil.  The rule is followed through
`display-buffer\=' with the selected window kept and no other frame
switched to; afterwards the window the user is in has to hold what it
held, and the tab has to be the one it was.  A rule that took either --
it is theirs, and may say anything -- is undone, and the review waits in
its buffer."
  (let* ((users (mapcar (lambda (window) (cons window (window-buffer window)))
                        (ecc-window--users-windows)))
         (configuration (current-window-configuration))
         (tab (and (fboundp 'tab-bar--current-tab-index) (tab-bar--current-tab-index)))
         (window (save-selected-window
                   (display-buffer buffer '(nil (inhibit-switch-frame . t)
                                                (inhibit-same-window . t)))))
         (now (and (fboundp 'tab-bar--current-tab-index) (tab-bar--current-tab-index))))
    (if (and (window-live-p window)
             (equal tab now)
             (not (assq window users))
             (seq-every-p (lambda (user)
                            (and (window-live-p (car user))
                                 (eq (window-buffer (car user)) (cdr user))))
                          users))
        window
      (unless (equal tab now)
        (tab-bar-select-tab (1+ tab)))
      (set-window-configuration configuration)
      nil)))

;;;; Which project, and which session

(defun ecc-window-context-project-root ()
  "Return the project a new session should start in.
The current buffer when there is a file or a directory behind it, then
the last buffer the user worked in that had one, and `default-directory'
last.  A buffer with nothing behind it -- the scratch buffer, a
transcript, the sidebar, a help window -- says nothing about which
project was meant, and a session started from one of those used to land
wherever that buffer happened to be, which is how a session ends up in
a project nobody asked for.

The Space of the tab that is showing comes second: the user chose that
Space, and choosing one is as plain a statement of which project is
meant as the buffer in front of them."
  (ecc-window-project-key
   (or (ecc-window-buffer-directory (current-buffer))
       (ecc-space-current-key)
       (ecc-window-buffer-directory ecc-window--last-source-buffer)
       default-directory)))

(defvar-local ecc--bound-session-id nil
  "Id of the session this buffer sends to, once one has been chosen.")

(defun ecc-window--session-group (key)
  "Return (TITLE . PARENT) for the group of the sessions of the project KEY.
A session with no project is in a group of its own, titled \"-\"; the
rest are grouped by Space, titled as the Space picker titles it, and
PARENT is the key of the repository a linked worktree belongs to."
  (if (string-empty-p key)
      (list "-")
    (let ((space (ecc-space-of-root key)))
      (cons (ecc-space-title space) (ecc-space-parent space)))))

(defun ecc-window--sessions-by-use (sessions)
  "Return SESSIONS, the one whose buffer was selected last first.
`buffer-list' is kept in that order.  The registry is not: it moves a
session to the front when it starts, not when it is used.  A session
with no live buffer goes after the rest, and sessions that tie keep the
order of SESSIONS."
  (let ((rank (make-hash-table :test #'eq))
        (n 0))
    (dolist (buffer (buffer-list))
      (puthash buffer (setq n (1+ n)) rank))
    (mapcar #'cdr
            ;; `sort' is stable.
            (sort (mapcar (lambda (session)
                            (cons (gethash (ecc-session-buffer session) rank
                                           most-positive-fixnum)
                                  session))
                          sessions)
                  (lambda (a b) (< (car a) (car b)))))))

(defun ecc-window--session-groups (sessions)
  "Return an alist of each project of SESSIONS to the title of its group.
In the order the projects first come up among SESSIONS, except that a
worktree follows its repository when that has sessions here too, the
way the sidebar draws it.  Two projects that would still go by the
same title are told apart the way their tabs are, `main<2>\='."
  (let* ((groups (mapcar (lambda (key)
                           (cons key (ecc-window--session-group key)))
                         (seq-uniq (mapcar #'ecc-window-session-project
                                           sessions))))
         (keys (mapcar #'car groups))
         (ordered nil)
         (titled nil))
    ;; The same walk as `ecc-space-list'.
    (dolist (group groups)
      (unless (member (cddr group) keys)
        (push group ordered)
        (dolist (child groups)
          (when (equal (cddr child) (car group))
            (push child ordered)))))
    (dolist (group (nreverse ordered))
      (push (cons (car group)
                  (ecc--unique-name (cadr group)
                                    (lambda (title) (rassoc title titled))))
            titled))
    (nreverse titled)))

(defun ecc-window--session-candidates (sessions)
  "Return an alist of a candidate to its group title and session, for SESSIONS.
The candidate is the title and the name, `Space/name\=', so that typing
the name of a Space narrows the list to its sessions -- and the name of
a repository to its sessions and those of its worktrees.  A group\='s
sessions come together, in the order of the groups, and keep the order
of SESSIONS among themselves."
  (mapcan (lambda (group)
            (let ((title (cdr group)))
              (mapcar (lambda (session)
                        (cons (concat title "/" (ecc-session-name session))
                              (cons title session)))
                      (seq-filter (lambda (session)
                                    (equal (ecc-window-session-project session)
                                           (car group)))
                                  sessions))))
          (ecc-window--session-groups sessions)))

(defun ecc-window--session-line (session name)
  "Return SESSION as the picker shows it: the mark of its state, then NAME.
NAME is the name as the candidate carries it, with whatever faces the
completion UI put on it to show what matched: vertico highlights a
candidate before it hands it to the `group-function\=' (confirmed
2026-10-07), and a name taken from SESSION afresh would lose them.  The
mark is the one its tab and its sidebar row carry, at the moment of
asking: no blinking.  Only the mark takes a face of its own."
  (concat (ecc-tab-column-mark (ecc-model-activity session)) " " name))

(defun ecc-window--session-table (candidates)
  "Return a completion table of CANDIDATES, grouped by Space and kept in order.
CANDIDATES is what `ecc-window--session-candidates\=' returns.  As a line
is shown, the group title comes off its front and the mark of the
session\='s state goes in its place.  The title is matched against what
is typed, the mark is not."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata
          (group-function
           . ,(lambda (candidate transform)
                (let ((entry (cdr (assoc candidate candidates))))
                  (cond ((null entry) (if transform candidate ""))
                        (transform
                         (ecc-window--session-line
                          (cdr entry)
                          (substring candidate (1+ (length (car entry))))))
                        (t (car entry))))))
          ;; Most recently used first, which sorting would throw away.
          (display-sort-function . identity)
          (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun ecc-window-read-session (&optional prompt sessions)
  "Ask which of SESSIONS to use, with PROMPT.
SESSIONS defaults to every live session.  They are offered most
recently used first, by `ecc-window--sessions-by-use', grouped by the
Space they belong to, each under the
mark of its state.  A group comes where its most recently used session
does."
  (let ((sessions (ecc-window--sessions-by-use
                   (or sessions (ecc-model-sessions)))))
    (cond
     ((null sessions) (user-error "No session is running"))
     ((null (cdr sessions)) (car sessions))
     (t (let* ((candidates (ecc-window--session-candidates sessions))
               (choice (completing-read (or prompt "Session: ")
                                        (ecc-window--session-table candidates)
                                        nil t)))
          (cddr (assoc choice candidates)))))))

(defun ecc-window-bound-session ()
  "Return the session this buffer was told to send to, or nil."
  (and ecc--bound-session-id (ecc-model-session ecc--bound-session-id)))

(defun ecc-window-resolve-session (&optional force-ask)
  "Return the session a command in this buffer should talk to.
The order is: the session of this buffer, the session this buffer was
bound to before, the only session of this project, the only session on
screen, the most recently started one.  FORCE-ASK, a prefix argument in
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

;;;; Switching a window to another session

(defun ecc-window--switch-target ()
  "Return the window `ecc-switch-session' should change, or nil.
The current window when it shows a session, and none otherwise, which
means the Space that is showing."
  (let ((window (selected-window)))
    (and (ecc-window-buffer-session (window-buffer window))
         window)))

;; Defined in `ecc-notify', which is above this file; read here so that
;; the sessions `ecc-switch-session' offers are the tabs on the screen.
(defvar ecc-tab-line-scope)

(defun ecc-window--switch-row (window)
  "Return the sessions of the tab row of WINDOW, most recently started first.
The row of the session WINDOW shows: its project, or every session when
`ecc-tab-line-scope' is `all', which is what `ecc-tab-line--sessions'
draws.  A WINDOW that shows no session has no row, and the project
meant is the Space that is showing, or else the one `ecc-start' would
use."
  (let ((session (and (window-live-p window)
                      (ecc-window-buffer-session (window-buffer window)))))
    ;; The same rule as `ecc-tab-line--sessions'; change them together.
    (cond
     ((eq (bound-and-true-p ecc-tab-line-scope) 'all) (ecc-model-sessions))
     (session (ecc-window-project-sessions
               (ecc-window-session-project session)))
     (t (ecc-window-project-sessions
         (or (ecc-space-current-key)
             (ecc-window-context-project-root)))))))

(defun ecc-window--read-switch (every)
  "Ask which session `ecc-switch-session' should show.
The sessions of the tab row of the window being switched, or every
session when EVERY; the one that window already shows is not among them."
  (let* ((window (ecc-window--switch-target))
         (current (and (window-live-p window)
                       (ecc-window-buffer-session (window-buffer window))))
         (sessions (remq current (if every
                                     (ecc-model-sessions)
                                   (ecc-window--switch-row window)))))
    (cond
     (sessions (ecc-window-read-session "Switch to: " sessions))
     ((or every (eq (bound-and-true-p ecc-tab-line-scope) 'all))
      (user-error "No other session is running"))
     (t (user-error "%s" (substitute-command-keys
                          "No other session in this project; \\[universal-argument] \\[ecc-switch-session] lists them all"))))))

;;;###autoload
(defun ecc-switch-session (session)
  "Show SESSION in this window, the way clicking its tab would.
Which session a window shows is the user's to choose: this is the same
choice the tab line offers, for when the tabs are not to hand.

Interactively the choice is the tabs of this window -- the sessions of
its project, or all of them under `ecc-tab-line-scope' `all' -- less the
one it already shows.  With a prefix argument it is every session.

A session from outside the row is not put into this window, where it
would sit among another project's tabs: it is shown in its own Space,
by `ecc-window-select-session'.  One another window of this Space
already shows is selected there rather than shown twice."
  (interactive (list (ecc-window--read-switch current-prefix-arg)))
  (let* ((window (ecc-window--switch-target))
         (frame (and (window-live-p window) (window-frame window)))
         (buffer (ecc-session-buffer session))
         (shown (and frame (buffer-live-p buffer)
                     (get-buffer-window buffer frame))))
    (cond
     ((or (not frame)
          (not (memq session (ecc-window--switch-row window))))
      (ecc-window-select-session session))
     (shown
      (select-window shown)
      (ecc-chat-goto-prompt)
      shown)
     (t
      (set-window-buffer window (ecc-session-ensure-buffer session))
      (select-window window)
      (ecc-chat-goto-prompt)
      window))))

(defvar ecc-display-chat-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'ecc-switch-session)
    map)
  "The keys of this file in the prompt region of a session buffer.
A parent of `ecc-chat-mode-map'.")

(ecc-chat-add-keymap-parent ecc-chat-mode-map ecc-display-chat-map)

(provide 'ecc-display)

;;; ecc-display.el ends here
