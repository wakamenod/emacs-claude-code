;;; ecc-space.el --- One tab per project, and what lives in it  -*- lexical-binding: t; -*-

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

;; The commands on the Spaces: going to one, by name or by number,
;; closing one, the layouts of `ecc-space-cycle-layout' and the zoom, and
;; the picker they ask with.  What a Space is, its tabs and how a session
;; is shown in one are `ecc-display', below every module that shows a
;; session; what is here is above them, because going to a Space with
;; nothing running in it starts a session there (`ecc-space-select'),
;; and a Space whose last session goes closes itself.
;;
;; What a Space buys is that the arrangement is kept.  The windows have
;; no roles, so a transcript the user split, moved or made wider stays
;; that way, and going to another Space and back brings it all back,
;; because a tab is a window configuration.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-bar)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-window)
(require 'ecc-worktree)
(require 'ecc-notify)
(require 'ecc-history)
(require 'ecc-lifecycle)
(require 'ecc-chat)
(require 'ecc-display)

;;;; Settings

;; It said how many transcripts a row of them had room for.  The windows
;; of a Space are laid out to fixed proportions now, and how many
;; sessions are on the screen is the layout's to say.
(make-obsolete-variable 'ecc-space-session-min-width
                        "the layouts of `ecc-space-cycle-layout' say how \
many sessions are on the screen."
                        "0.4.2")

;;;; The state of a Space

(defun ecc-space-state (space)
  "Return the one state that stands for the sessions of SPACE, or nil."
  (ecc-tab-state-roll-up (ecc-space-sessions space)))

;;;; Going to a Space

(defun ecc-space-select (space)
  "Go to SPACE and return the name of its tab.
Its windows come back exactly as they were left: a tab is a window
configuration, which is the whole point of laying the sessions out this
way.  A Space with nothing running in it gets a session; see
`ecc-space--ensure-session'.  So does the repository a worktree opened
for the first time brings with it, before the worktree's own, so that
the worktree is what the user is left looking at.

This is going to a Space, which the user does.  Showing a session goes
to its Space as well (`ecc-space--select-tab'), and starts nothing."
  (when-let* ((parent (ecc-space--parent-space space)))
    (ecc-space--ensure-parent space)
    (ecc-space--ensure-session parent))
  (prog1 (ecc-space--select-tab space)
    (ecc-space--ensure-session space)))

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
      (condition-case error
          (ecc-start (ecc-space-root space))
        (error (message "%s: nothing started: %s" (ecc-space-name space)
                        (error-message-string error)))))))

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
from here."
  (interactive "P")
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
         (past (and (not open-only) (ecc-space-past-projects))))
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

(defun ecc-space--session-removed (session)
  "Take the windows of SESSION away, and its Space when it was the last.
On `ecc-session-removed-hook'.  A Space is closed only under
`ecc-space-always-session': with the setting off a Space stands on its
source buffer alone and goes with that instead, in
`ecc-space--forget-on-source-kill'.

A session of a Space that is still being started is not the end of
anything: `ecc-proc--start-failed' forgets a session that never came
up, and the tab the user just asked for would go with it."
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
    (ecc-space--close-empty space)))

(add-hook 'ecc-session-removed-hook #'ecc-space--session-removed)

(provide 'ecc-space)

;;; ecc-space.el ends here
