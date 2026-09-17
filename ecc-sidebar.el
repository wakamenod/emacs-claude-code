;;; ecc-sidebar.el --- The Spaces and the sessions down the left  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A narrow window on the left of the frame with two lists in it: the
;; Spaces at the top -- the projects and their worktrees, numbered, each
;; marked with what it is doing -- and the sessions at the bottom, with
;; what each is waiting for.
;;
;; It is the one place that says what every project is doing at once.
;; The dashboard already lists the sessions and lists them better; what
;; it does not do is stay on the screen while you work, which is the
;; whole of what this is for.  So it is drawn narrow, it never takes the
;; selected window, and everything in it is one key away: RET goes there,
;; a and d answer what is waiting, TAB folds a repository's worktrees
;; away.
;;
;; It is drawn as text with properties rather than as a `tabulated-list':
;; two sections with different columns, and a second line under some
;; rows, is not what a tabulated list is for.
;;
;; The marks, the colours and the beat of the blink are the tab line's
;; (`ecc-tab-mark-of-state', `ecc-tab-faces-of-state',
;; `ecc-tab-blink-functions'), so that a session says the same thing
;; wherever it is drawn.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'hl-line)
(require 'mule-util)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-window)
(require 'ecc-worktree)
(require 'ecc-space)
(require 'ecc-notify)
(require 'ecc-visual)
(require 'ecc-answer)
(require 'ecc-perm)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-start-worktree "ecc-worktree" (branch))
(declare-function ecc-remove-worktree "ecc-worktree" (path))

(defconst ecc-sidebar-buffer-name "*ecc-sidebar*"
  "Name of the sidebar buffer.")

(defcustom ecc-sidebar-width 28
  "Width of the sidebar window, in columns.
herdr draws its own at 26; two more here because a Space carries a
bracketed number in front of the name and Emacs has no room to spare
on the right.

It is a setting for the reason `ecc-space-session-min-width\=' is one: it
is a screen.  Twenty-eight columns of a 13-inch laptop at a large font
and of a 34-inch display are not the same fraction of the frame, and
the names a project has are not the same length for everybody."
  :type 'integer
  :group 'ecc)

(defvar ecc-sidebar-sessions-sort 'spaces
  "How the sessions at the bottom of the sidebar are ordered.
`spaces' keeps them under their Space, in the order they were started,
so that the bottom of the sidebar reads like the top.  `priority' puts
what wants an answer first, then what is working, then the rest, which
is the order to read when there are more sessions than room.")

(defvar ecc-sidebar-spinner-interval 0.2
  "Seconds between the frames of the spinner in the sidebar.")

(defvar ecc-sidebar--collapsed nil
  "Keys of the Spaces whose worktrees are folded away.")

(defvar ecc-sidebar--spinner-timer nil
  "Timer turning the spinner while the sidebar is on the screen.")

(defvar ecc-sidebar--last-space nil
  "The Space the sidebar last drew as the current one.")

;;;; The rows

(defun ecc-sidebar--item-at-point ()
  "Return what the line at point stands for: a Space or a session."
  (get-text-property (line-beginning-position) 'ecc-sidebar-item))

(defun ecc-sidebar--space-at-point ()
  "Return the Space of the line at point, or nil.
A session row answers with the Space its session runs in, so that the
keys that act on a Space work from either list."
  (let ((item (ecc-sidebar--item-at-point)))
    (cond ((ecc-space-p item) item)
          ((ecc-session-p item)
           (ecc-space-of-root (ecc-window-session-project item))))))

(defun ecc-sidebar--session-at-point ()
  "Return the session of the line at point, or nil."
  (let ((item (ecc-sidebar--item-at-point)))
    (and (ecc-session-p item) item)))

(defun ecc-sidebar--insert (text item &optional detail)
  "Insert TEXT as a row standing for ITEM, followed by a newline.
DETAIL marks a second line, which `n' and `p' pass over."
  (insert (propertize (concat text "\n")
                      'ecc-sidebar-item item
                      'ecc-sidebar-detail detail))
  nil)

(defun ecc-sidebar--heading (text)
  "Insert TEXT as the heading of a section."
  (insert (propertize text 'face 'ecc-heading-face)
          (propertize "\n" 'ecc-sidebar-heading t)))

(defun ecc-sidebar--fill (left right)
  "Return LEFT and RIGHT with the room between them, LEFT cut if it must be.
RIGHT is put against the right edge of the sidebar: what a session is
waiting for in the Sessions list, and whether a repository is folded in
the Spaces one.  An empty RIGHT leaves the row where it ends rather
than trailing the spaces that would have led to it."
  (let* ((width (max 12 (1- ecc-sidebar-width)))
         (room (max 1 (- width (string-width right))))
         ;; Not `ecc--fit': it flattens a run of spaces to one, which is
         ;; the indent of a worktree row gone.
         (left (if (< (string-width left) room)
                   left
                 (truncate-string-to-width left (1- room) nil nil "…"))))
    (if (string-empty-p right)
        left
      (concat left
              (make-string (max 1 (- room (string-width left))) ?\s)
              right))))

(defun ecc-sidebar--mark (state)
  "Return the mark that stands for STATE in the sidebar.
Idle takes a mark of its own -- the tab line leaves it blank -- because
the mark opens the row here, and a blank one would put the name of an
idle Space a column to the left of every other name."
  (pcase state
    ('nil " ")
    ('idle "·")
    (_ (ecc-tab-mark-of-state state))))

;;;; The Spaces

(defvar ecc-sidebar--toggle-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<mouse-1>") #'ecc-sidebar-mouse-toggle-children)
    map)
  "Keymap of the fold arrow at the right end of a repository's row.")

(defun ecc-sidebar--connector (space spaces)
  "Return the tree line drawn in front of SPACE, one of the drawn SPACES.
Empty for a repository; for a worktree, the line that ties it to the
row above, closed off on the last one.  SPACES is what is on the
screen rather than every Space there is: a fold can leave one worktree
of three drawn, and it is the last of what is drawn that closes the
line."
  (if (not (ecc-space-child-p space spaces))
      ""
    (let ((last (car (last (ecc-space-children
                            (ecc-space-parent space) spaces)))))
      (if (ecc-space-equal space last) "  └─ " "  ├─ "))))

(defun ecc-sidebar--number-width (spaces)
  "Return the room the bracketed number takes for any of SPACES.
The widest wins, so that the names line up once the tenth Space opens."
  (length (format "[%d]" (max 1 (length spaces)))))

(defun ecc-sidebar--space-state (space spaces)
  "Return the state SPACE is drawn with, among every Space in SPACES.
A folded repository answers for its worktrees as well: with the rows
away, its mark is the only thing left to say that one of them is
waiting.  herdr does the same (`displayed_workspace_status')."
  (let ((children (and (member (ecc-space-key space) ecc-sidebar--collapsed)
                       (ecc-space-children space spaces))))
    (if (null children)
        (ecc-space-state space)
      (ecc-tab-state-roll-up
       (seq-mapcat #'ecc-space-sessions (cons space children))))))

(defun ecc-sidebar--toggle-mark (space spaces)
  "Return the fold arrow of SPACE, or an empty string when it has no worktree.
SPACES is every Space there is: a repository whose worktrees are all
folded away still has them."
  (if (null (ecc-space-children space spaces))
      ""
    (if (member (ecc-space-key space) ecc-sidebar--collapsed) "▸" "▾")))

(defun ecc-sidebar--space-row (space spaces visible)
  "Insert the row of SPACE and its detail line.
SPACES is every Space there is, which is what numbers the row; VISIBLE
is what the sidebar draws, which is what the tree lines follow."
  (let* ((current (ecc-space-equal space (ecc-space-current)))
         (child (ecc-space-child-p space visible))
         (state (ecc-sidebar--space-state space spaces))
         (number (ecc-space-number space spaces))
         (left (concat (ecc-sidebar--connector space visible)
                       (ecc-sidebar--mark state)
                       " "
                       (string-pad (if number (format "[%d]" number) "")
                                   (ecc-sidebar--number-width spaces))
                       " "
                       (ecc-space-name space)))
         (toggle (ecc-sidebar--toggle-mark space spaces))
         (faces (ecc-tab-faces-of-state state current))
         (row (propertize (ecc-sidebar--fill left toggle) 'face faces)))
    (unless (string-empty-p toggle)
      (add-text-properties (- (length row) (length toggle)) (length row)
                           (list 'keymap ecc-sidebar--toggle-map
                                 'mouse-face 'highlight
                                 'help-echo "mouse-1: fold or unfold")
                           row))
    (ecc-sidebar--insert row space)
    ;; What git says goes under the parent alone: a worktree is already
    ;; named by its branch, and herdr leaves its git details out for the
    ;; same reason (`suppress_git_details').
    (unless child
      (when-let* ((detail (ecc-sidebar--git-detail space)))
        (ecc-sidebar--insert (propertize (concat "   " detail)
                                         'face 'ecc-dim-face)
                             space t)))))

(defun ecc-sidebar--git-detail (space)
  "Return the git line under SPACE, or nil when there is nothing to add.
The branch is left out when the Space is already named after it, which
is what a worktree with no parent on the screen would otherwise do: the
same string twice, one under the other, saying nothing the second
time."
  (let* ((branch (ecc-space-branch space))
         (named (equal (ecc-space-name space)
                       (and branch (string-remove-prefix "worktree/" branch))))
         (ahead (and branch (ecc-worktree-ahead-behind (ecc-space-root space))))
         (parts (delq nil
                      (list (and branch (not named) branch)
                            (and ahead (format "↑%d ↓%d"
                                               (car ahead) (cdr ahead)))))))
    (and parts (string-join parts " "))))

(defun ecc-sidebar--visible-spaces ()
  "Return the Spaces to draw, the folded-away worktrees left out.
The Space one is in is drawn whatever its parent says: folding a
repository away must not hide the very worktree being worked in, which
is what herdr does as well."
  (let ((spaces (ecc-space-list))
        (current (ecc-space-current)))
    (seq-filter
     (lambda (space)
       (or (not (ecc-space-child-p space spaces))
           (not (member (ecc-space-parent space) ecc-sidebar--collapsed))
           (ecc-space-equal space current)))
     spaces)))

(defun ecc-sidebar--draw-spaces ()
  "Draw the Spaces section."
  (ecc-sidebar--heading "Spaces")
  (let ((spaces (ecc-space-list))
        (visible (ecc-sidebar--visible-spaces)))
    (dolist (space visible)
      (ecc-sidebar--space-row space spaces visible))))

;;;; The sessions

(defun ecc-sidebar--state-word (session)
  "Return what SESSION is doing, in a word.
What waits on the user comes first: a session can be waiting for an
answer while its state still says that it runs."
  (let ((waiting (length (ecc-session-pending session))))
    (cond
     ((> waiting 1) (format "waiting ×%d" waiting))
     ((= waiting 1) "waiting")
     (t (format "%s" (or (ecc-session-state session) ""))))))

(defun ecc-sidebar--sessions ()
  "Return the sessions in the order the sidebar lists them."
  (let ((sessions (ecc-model-sessions)))
    (pcase ecc-sidebar-sessions-sort
      ('priority
       ;; Stable within a rank: `ecc-model-sessions' is most recently
       ;; used first, which is the nearest thing the model keeps to the
       ;; order the states last changed in.
       (let ((rank (lambda (session)
                     (pcase (ecc-tab-state session)
                       ('attention 0) ('running 1) ('idle 2) (_ 3)))))
         (seq-sort-by rank #'< sessions)))
      (_
       (seq-mapcat (lambda (space)
                     (seq-sort-by #'ecc-session-created #'<
                                  (ecc-space-sessions space)))
                   (ecc-space-list))))))

(defun ecc-sidebar--session-row (session)
  "Insert the row of SESSION."
  (let* ((state (ecc-tab-state session))
         (current (and (ecc-window-session-visible-p session) t))
         (frame (and (eq state 'running)
                     (ecc-visual-spinner-string 'ecc-running-face)))
         (mark (if (and frame (not (string-empty-p frame)))
                   frame
                 (ecc-sidebar--mark state)))
         (left (concat mark " " (ecc--truncate (ecc-session-name session) 18))))
    (ecc-sidebar--insert
     (propertize (ecc-sidebar--fill left (ecc-sidebar--state-word session))
                 'face (ecc-tab-faces-of-state state current))
     session)))

(defun ecc-sidebar--draw-sessions ()
  "Draw the sessions section."
  (ecc-sidebar--heading "Sessions")
  (let ((sessions (ecc-sidebar--sessions)))
    (if (null sessions)
        (ecc-sidebar--insert (propertize "   none" 'face 'ecc-dim-face) nil t)
      (mapc #'ecc-sidebar--session-row sessions))))

;;;; Drawing and redrawing

(defun ecc-sidebar--draw ()
  "Draw the whole sidebar into the current buffer."
  (ecc-sidebar--draw-spaces)
  (insert "\n")
  (ecc-sidebar--draw-sessions))

(defun ecc-sidebar--same-item-p (a b)
  "Return non-nil when the rows A and B stand for the same thing."
  (cond ((and (ecc-space-p a) (ecc-space-p b)) (ecc-space-equal a b))
        ((and (ecc-session-p a) (ecc-session-p b)) (eq a b))
        (t (equal a b))))

(defun ecc-sidebar--detail-p ()
  "Return non-nil when the line at point is the second line of a row."
  (and (get-text-property (line-beginning-position) 'ecc-sidebar-detail) t))

(defun ecc-sidebar--goto-item (item &optional detail)
  "Put point on the row standing for ITEM, or leave it where it is.
DETAIL asks for the second line of that row rather than its first.  A
Space and the git line under it stand for the same Space, so without
this point came back a line higher than it was, on every redraw -- and
with the spinner redrawing several times a second, moving down onto a
git line was impossible (reported and reproduced 2026-09-15)."
  (when item
    (let ((found nil)
          (fallback nil))
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (when (ecc-sidebar--same-item-p (ecc-sidebar--item-at-point) item)
          (if (eq (ecc-sidebar--detail-p) (and detail t))
              (setq found (point))
            (unless fallback (setq fallback (point)))))
        (forward-line 1))
      (when (or found fallback)
        (goto-char (or found fallback))
        t))))

(defun ecc-sidebar-redraw (&rest _)
  "Draw the sidebar again, keeping point on the row it was on."
  (when-let* ((buffer (get-buffer ecc-sidebar-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (item (ecc-sidebar--item-at-point))
            (detail (ecc-sidebar--detail-p))
            (line (line-number-at-pos)))
        (erase-buffer)
        (ecc-sidebar--draw)
        (unless (ecc-sidebar--goto-item item detail)
          (goto-char (point-min))
          (forward-line (1- line)))
        (beginning-of-line)))
    (ecc-sidebar--spinner-update))
  nil)

;;;; The spinner

(defun ecc-sidebar--visible-p ()
  "Return non-nil when the sidebar is on a screen somewhere."
  (and (get-buffer ecc-sidebar-buffer-name)
       (get-buffer-window ecc-sidebar-buffer-name t)
       t))

(defun ecc-sidebar--running-p ()
  "Return non-nil when a session is working."
  (seq-some (lambda (session) (eq (ecc-session-state session) 'running))
            (ecc-model-sessions)))

(defun ecc-sidebar--spinner-stop ()
  "Stop the spinner of the sidebar."
  (when ecc-sidebar--spinner-timer
    (cancel-timer ecc-sidebar--spinner-timer)
    (setq ecc-sidebar--spinner-timer nil)))

(defun ecc-sidebar--spinner-update ()
  "Turn the spinner while something runs where it can be seen."
  (if (and ecc-visual-enable-spinner
           (ecc-sidebar--running-p)
           (ecc-sidebar--visible-p))
      (unless ecc-sidebar--spinner-timer
        (setq ecc-sidebar--spinner-timer
              (run-at-time ecc-sidebar-spinner-interval
                           ecc-sidebar-spinner-interval
                           #'ecc-sidebar--spinner-tick)))
    (ecc-sidebar--spinner-stop)))

(defun ecc-sidebar--spinner-tick ()
  "Turn the spinner one frame, or stop when there is nothing to turn.
A sidebar nobody is looking at is not worth a timer."
  (if (and (ecc-sidebar--visible-p) (ecc-sidebar--running-p))
      (progn (ecc-visual-spinner-advance)
             (ecc-sidebar-redraw))
    (ecc-sidebar--spinner-stop)))

;;;; Hearing about a change

(defconst ecc-sidebar--hooks
  '(ecc-session-state-changed-hook
    ecc-request-added-hook
    ecc-request-resolved-hook
    ecc-session-init-hook
    ecc-session-exited-hook
    ecc-session-removed-hook
    ecc-turn-finished-hook)
  "The hooks that change what the sidebar says.
The same set the tab line listens to, and the two are drawn from the
same facts.")

(defun ecc-sidebar--tab-changed (&rest _)
  "Draw the sidebar again when the tab showing has changed.
Emacs 29.1 has no `tab-bar-tab-post-select-functions' -- it arrived in
30.1 (verified 2026-09-14) -- so on 29.1 the change is noticed from
`window-configuration-change-hook' instead, which is where selecting a
tab shows up."
  (let ((key (and ecc-use-spaces (ecc-space-current-key))))
    (unless (equal key ecc-sidebar--last-space)
      (setq ecc-sidebar--last-space key)
      (ecc-sidebar-redraw))))

(defun ecc-sidebar--listen (add)
  "Start listening for what changes the sidebar, or stop when ADD is nil."
  (let ((change (if add #'add-hook #'remove-hook)))
    (dolist (hook ecc-sidebar--hooks)
      (funcall change hook #'ecc-sidebar-redraw))
    (funcall change 'ecc-tab-blink-functions #'ecc-sidebar-redraw)
    (if (boundp 'tab-bar-tab-post-select-functions)
        (funcall change 'tab-bar-tab-post-select-functions
                 #'ecc-sidebar--tab-changed)
      (funcall change 'window-configuration-change-hook
               #'ecc-sidebar--tab-changed))))

(defun ecc-sidebar--teardown ()
  "Stop listening and stop the spinner, the buffer being gone."
  (ecc-sidebar--listen nil)
  (ecc-sidebar--spinner-stop))

;;;; The keys

(defun ecc-sidebar-next-line ()
  "Move to the next row, passing over headings and detail lines."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (or (null (ecc-sidebar--item-at-point))
                    (get-text-property (line-beginning-position)
                                       'ecc-sidebar-detail)))
      (forward-line 1))
    (when (and (eobp) (null (ecc-sidebar--item-at-point)))
      (goto-char start))
    (beginning-of-line)))

(defun ecc-sidebar-previous-line ()
  "Move to the previous row, passing over headings and detail lines."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (or (null (ecc-sidebar--item-at-point))
                    (get-text-property (line-beginning-position)
                                       'ecc-sidebar-detail)))
      (forward-line -1))
    (when (null (ecc-sidebar--item-at-point))
      (goto-char start))
    (beginning-of-line)))

(defun ecc-sidebar-visit ()
  "Go to what the row at point stands for."
  (interactive)
  (let ((item (ecc-sidebar--item-at-point)))
    (cond
     ((ecc-session-p item) (ecc-window-select-session item))
     ;; `ecc-space-select' is what knows the difference between the
     ;; layouts, so RET and the number keys cannot drift apart.
     ((ecc-space-p item) (ecc-space-select item))
     (t (user-error "Nothing on this line")))))

(defun ecc-sidebar-toggle-children ()
  "Fold the worktrees of the Space at point away, or unfold them."
  (interactive)
  (let* ((space (ecc-sidebar--space-at-point))
         (key (and space (if (ecc-space-child-p space)
                             (ecc-space-parent space)
                           (ecc-space-key space)))))
    (unless key
      (user-error "Nothing to fold here"))
    (if (member key ecc-sidebar--collapsed)
        (setq ecc-sidebar--collapsed (delete key ecc-sidebar--collapsed))
      (push key ecc-sidebar--collapsed))
    (ecc-sidebar-redraw)))

(defun ecc-sidebar-mouse-toggle-children (event)
  "Fold or unfold the worktrees of the row EVENT was clicked on.
The arrow is bound rather than the row, so a click anywhere else on a
repository still goes there."
  (interactive "e")
  (mouse-set-point event)
  (ecc-sidebar-toggle-children))

(defun ecc-sidebar-start-session ()
  "Start a session in the Space of the row at point."
  (interactive)
  (require 'ecc)
  (let ((space (or (ecc-sidebar--space-at-point)
                   (user-error "No Space on this line"))))
    (ecc-start (ecc-space-root space))))

(defun ecc-sidebar-start-worktree ()
  "Make a worktree of the Space at point and start a session in it."
  (interactive)
  (require 'ecc-worktree)
  (let ((space (or (ecc-sidebar--space-at-point)
                   (user-error "No Space on this line"))))
    (let ((default-directory (ecc-space-root space)))
      (call-interactively #'ecc-start-worktree))))

(defun ecc-sidebar-close-space ()
  "Close the Space of the row at point."
  (interactive)
  (ecc-space-close (or (ecc-sidebar--space-at-point)
                       (user-error "No Space on this line"))))

(defun ecc-sidebar-remove-worktree ()
  "Remove the directory of the worktree Space at point."
  (interactive)
  (require 'ecc-worktree)
  (let ((space (or (ecc-sidebar--space-at-point)
                   (user-error "No Space on this line"))))
    (unless (ecc-space-parent space)
      (user-error "%s is not a worktree" (ecc-space-name space)))
    (ecc-remove-worktree (ecc-space-root space))
    (ecc-sidebar-redraw)))

(defun ecc-sidebar-kill-session ()
  "Stop the session of the row at point."
  (interactive)
  (require 'ecc)
  (let ((session (or (ecc-sidebar--session-at-point)
                     (user-error "No session on this line"))))
    (when (yes-or-no-p (format "Stop %s? " (ecc-session-name session)))
      (ecc-kill session)
      (ecc-sidebar-redraw))))

(defun ecc-sidebar--oldest-request ()
  "Return the oldest request the session at point is waiting on."
  (let ((session (or (ecc-sidebar--session-at-point)
                     (user-error "No session on this line"))))
    (or (car (ecc-session-pending session))
        (user-error "%s is not waiting for anything"
                    (ecc-session-name session)))))

(defun ecc-sidebar-allow ()
  "Allow what the session at point is waiting on."
  (interactive)
  (let ((request (ecc-sidebar--oldest-request)))
    (unless (eq (ecc-request-kind request) 'permission)
      (user-error "That is a %s, not a permission request"
                  (ecc-request-kind request)))
    (when (ecc-answer--confirm "Allow" request)
      (ecc-perm-allow-request request)
      (message "Allowed: %s" (ecc-answer-summary request)))))

(defun ecc-sidebar-deny (reason)
  "Deny what the session at point is waiting on, with REASON."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (let ((request (ecc-sidebar--oldest-request)))
    (when (ecc-answer--confirm "Deny" request)
      (ecc-perm-respond request 'deny :message reason)
      (message "Denied: %s" (ecc-answer-summary request)))))

(defun ecc-sidebar-refresh ()
  "Ask git again and draw the sidebar afresh."
  (interactive)
  (ecc-worktree-forget)
  (ecc-sidebar-redraw))

(defvar ecc-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-sidebar-visit)
    (define-key map (kbd "<mouse-1>") #'ecc-sidebar-visit)
    (define-key map (kbd "n") #'ecc-sidebar-next-line)
    (define-key map (kbd "p") #'ecc-sidebar-previous-line)
    (define-key map (kbd "TAB") #'ecc-sidebar-toggle-children)
    (define-key map (kbd "c") #'ecc-sidebar-start-session)
    (define-key map (kbd "W") #'ecc-sidebar-start-worktree)
    (define-key map (kbd "x") #'ecc-sidebar-close-space)
    (define-key map (kbd "X") #'ecc-sidebar-remove-worktree)
    (define-key map (kbd "k") #'ecc-sidebar-kill-session)
    (define-key map (kbd "a") #'ecc-sidebar-allow)
    (define-key map (kbd "d") #'ecc-sidebar-deny)
    (define-key map (kbd "g") #'ecc-sidebar-refresh)
    (define-key map (kbd "q") #'ecc-sidebar-hide)
    (dotimes (n 9)
      (define-key map (kbd (number-to-string (1+ n)))
                  #'ecc-sidebar-jump))
    map)
  "Keymap of `ecc-sidebar-mode'.")

(defun ecc-sidebar-jump ()
  "Go to the Space whose number is the key that was typed."
  (interactive)
  (ecc-space-jump (string-to-number (this-command-keys))))

(define-derived-mode ecc-sidebar-mode special-mode "ecc-sidebar"
  "Major mode of the sidebar listing the Spaces and the sessions."
  (setq truncate-lines t
        cursor-in-non-selected-windows nil)
  (hl-line-mode 1)
  (ecc-sidebar--listen t)
  (add-hook 'kill-buffer-hook #'ecc-sidebar--teardown nil t))

;;;; The window

(defun ecc-sidebar--window ()
  "Return the window showing the sidebar on this frame, or nil."
  (when-let* ((buffer (get-buffer ecc-sidebar-buffer-name)))
    (get-buffer-window buffer)))

;;;###autoload
(defun ecc-sidebar-show ()
  "Show the sidebar on the left of the frame and return its window.
The window is not selected: the sidebar is something to glance at
while working, and it is `no-other-window' for the same reason."
  (interactive)
  (let ((buffer (get-buffer-create ecc-sidebar-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-sidebar-mode)
        (ecc-sidebar-mode)))
    (ecc-sidebar-redraw)
    (let ((window
           (display-buffer-in-side-window
            buffer `((side . left)
                     (slot . 0)
                     (window-width . ,ecc-sidebar-width)
                     ;; Without this the sidebar is resized with the
                     ;; frame, in proportion, like any other window: a
                     ;; 28-column sidebar on a 100-column frame came back
                     ;; 82 columns wide when the frame was made 292 wide,
                     ;; and what it draws is `ecc-sidebar-width' columns
                     ;; whatever the window measures, so the rest of it
                     ;; was blank and half the screen was gone (measured
                     ;; 2026-09-16).
                     (preserve-size . (t . nil))
                     (window-parameters . ((no-delete-other-windows . t)
                                           (no-other-window . t)))))))
      (when window
        ;; A window that is already there is reused as it is, so one that
        ;; grew before this was fixed -- or that a frame resize widened
        ;; between two calls -- is put back to its width here.
        (ecc-sidebar--set-width window))
      window)))

(defun ecc-sidebar--set-width (window)
  "Make WINDOW exactly `ecc-sidebar-width' columns wide and keep it there."
  (let ((delta (- ecc-sidebar-width (window-total-width window))))
    (unless (zerop delta)
      (ignore-errors (window-resize window delta t)))
    (window-preserve-size window t t)))

;;;###autoload
(defun ecc-sidebar-hide ()
  "Take the sidebar off the screen, leaving its buffer alive.
Only this window: `window-toggle-side-windows' would take the session
windows of the `classic' layout down with it."
  (interactive)
  (when-let* ((window (ecc-sidebar--window)))
    (delete-window window))
  (ecc-sidebar--spinner-stop))

;;;###autoload
(defun ecc-sidebar-toggle ()
  "Show the sidebar, or hide it when it is on the screen."
  (interactive)
  (if (ecc-sidebar--window)
      (ecc-sidebar-hide)
    (ecc-sidebar-show)))

;;;###autoload
(defun ecc-sidebar-focus ()
  "Go into the sidebar, showing it first when it is not up, and come back.
`no-other-window' is what keeps `C-x o' from landing in the sidebar by
accident while working, and it leaves the keys of `ecc-sidebar-mode'
with no way in at all -- point cannot be got there by hand.  This is
that way in, and the same key typed again is the way out, which is what
makes the sidebar something to dip into rather than a window to
navigate around."
  (interactive)
  (let ((window (or (ecc-sidebar--window) (ecc-sidebar-show))))
    (if (eq (selected-window) window)
        ;; Back where we came from: the largest window that is neither
        ;; a side window nor one of ours is where the work is.
        (select-window (or (ecc-window--source-window)
                           (next-window window nil 'no-minibuffer)))
      (select-window window)
      ;; Somewhere useful rather than on the heading, if point has
      ;; never been put anywhere.
      (unless (ecc-sidebar--item-at-point)
        (goto-char (point-min))
        (ecc-sidebar-next-line))
      window)))

(provide 'ecc-sidebar)

;;; ecc-sidebar.el ends here
