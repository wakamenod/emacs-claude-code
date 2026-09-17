;;; tab-bar-hidden.el --- Spaces with no tab bar drawn  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of the three tab-bar corrections, in the user's own
;; configuration.  A Space is a tab, and a tab is a named window
;; arrangement of the frame; `tab-bar-mode' only draws the strip above
;; it.  This package used to turn that mode on behind the user's back,
;; let `tab-bar.el' announce every move between Spaces in the echo area,
;; key the zoom on the mode rather than on the tab, and keep which tab a
;; Space is in in one table for the whole Emacs although a tab belongs
;; to a frame.
;;
;; Four things it shows, in order:
;;
;;   1. `tab-bar-show' nil: the Spaces are made, named and switched with
;;      nothing drawn, and the mode stays off.
;;   2. What tab-bar says when nobody quiets it, and that ecc's own
;;      moves leave none of it behind.
;;   3. `ecc-space-zoom' per Space, which was keyed on the mode and so
;;      collapsed to one key with the bar hidden.
;;   4. Two frames.  The second one is off camera -- only the demo
;;      frame's own window is recorded -- so what it holds is read out
;;      in the echo area, and what it does to this frame is on screen.
;;
;; It starts real sessions and sends them nothing: what is being shown
;; is where the tabs go and what the echo area says.
;;
;; Played by demo/scenes/tab-bar-hidden.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-worktree)
(require 'tab-bar)

(defvar demo-sessions nil
  "The sessions this scene started, by name.")

(defvar demo-second-frame nil
  "The frame this scene opens to show that a tab belongs to one.")

(defvar demo-messages-mark 1
  "Where `*Messages*' had got to when the quiet stretch began.")

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t)
  (setq ecc-space-always-session t)
  (setq demo-sessions nil)
  (setq demo-second-frame nil)
  ;; The setting under test.  It is a defcustom with a `:set' of its own
  ;; -- setting it plainly does not reach the frames -- so it is set the
  ;; way a user would, and the mode is left off for the scene to show
  ;; that nothing here turns it on.
  (customize-set-variable 'tab-bar-show nil)
  (when (bound-and-true-p tab-bar-mode)
    (tab-bar-mode -1))
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc and which layout this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc-use-spaces = %S   tab-bar-show = %S   ecc from %s"
                    ecc-use-spaces tab-bar-show
                    (abbreviate-file-name (locate-library "ecc-space"))))
  nil)

;;;; Saying what the tabs and the bar are doing

(defun demo-report-bar ()
  "Say what the tab bar is, and what the frame has of it."
  (demo-say
   (format "tab-bar-show = %S   tab-bar-mode = %S   this frame's tab-bar-lines = %S   tabs = %d"
           tab-bar-show (bound-and-true-p tab-bar-mode)
           (frame-parameter nil 'tab-bar-lines)
           (length (funcall tab-bar-tabs-function))))
  nil)

(defun demo-report-spaces ()
  "Say what Spaces there are, which is showing, and how many tabs."
  (let* ((spaces (ecc-space-list))
         (current (ecc-space-current-key))
         (drawn (mapconcat
                 (lambda (space)
                   (format "%s%s"
                           (if (ecc-space-child-p space spaces) "\\_ " "")
                           (ecc-space-name space)))
                 spaces " | ")))
    (demo-say (format "Spaces: %s      -- showing: %s      -- tabs on this frame: %d"
                      (if (string-empty-p drawn) "none" drawn)
                      (if current (ecc-space-name (ecc-space-of-root current)) "none")
                      (length (funcall tab-bar-tabs-function)))))
  nil)

(defun demo-report-windows ()
  "Say what the windows of this tab are showing."
  (demo-say (format "Windows here: %s"
                    (mapconcat (lambda (window)
                                 (buffer-name (window-buffer window)))
                               (window-list nil 'no-minibuffer) " | ")))
  nil)

;;;; 2. What tab-bar says when nobody quiets it

(defun demo-raw-tab-talk ()
  "Make and close a tab with the plain commands, so tab-bar speaks.
This is what every move between Spaces put in the echo area before: with
the bar hidden `tab-bar.el' cannot show what it did, so it says it, and
ecc's own message was written over by somebody else's."
  (tab-bar-new-tab)
  (tab-bar-rename-tab "loud")
  nil)

(defun demo-raw-tab-quiet-again ()
  "Close the tab the last step made, and say what closing says."
  (tab-bar-close-tab-by-name "loud")
  nil)

(defun demo-mark-messages ()
  "Remember where `*Messages*' has got to, and say so."
  (setq demo-messages-mark
        (with-current-buffer (get-buffer-create "*Messages*") (point-max)))
  (demo-say "From here on, only ecc speaks.  Watch the echo area while the Spaces change")
  nil)

(defun demo-report-quiet ()
  "Say what tab-bar has said since the mark, which should be nothing."
  (let* ((text (with-current-buffer (get-buffer-create "*Messages*")
                 (buffer-substring-no-properties
                  (min demo-messages-mark (point-max)) (point-max))))
         (heard (seq-filter
                 (lambda (line)
                   (string-match-p
                    "Added new tab\\|Renamed tab\\|Selected tab\\|Deleted tab"
                    line))
                 (split-string text "\n" t))))
    (demo-say (format "tab-bar said, in all of that: %s"
                      (if heard (string-join heard " / ") "nothing"))))
  nil)

;;;; The Spaces themselves

(defun demo-start-here ()
  "Start a session in the repository, which makes its Space."
  (let ((default-directory demo-root))
    (push (cons "greet" (ecc-start demo-root)) demo-sessions))
  nil)

(defun demo-start-worktree (branch)
  "Check BRANCH out beside the demo project and start a session there.
The buffer and the directory are both pinned to `demo-root\\=', and the
root the command works out is checked before it is let near git: a step
arrives from `emacsclient\\=' with `*scratch*\\=' current, whose
`default-directory\\=' is the checkout this Emacs was started from --
the real repository, where a scene cut two worktrees before anybody
noticed (2026-09-17)."
  (with-current-buffer (find-file-noselect
                        (expand-file-name "greet.py" demo-root))
    (let* ((default-directory demo-root)
           (root (ecc-worktree-context-root)))
      (unless (equal (file-truename root) (file-truename demo-root))
        (error "The demo would have worked in %s, not %s" root demo-root))
      (push (cons branch (ecc-start-worktree branch)) demo-sessions)))
  nil)

(defun demo-goto-space (root)
  "Go to the Space of ROOT."
  (ecc-space-select (ecc-space-of-root root))
  nil)

(defun demo-goto-branch (branch)
  "Go to the Space of the worktree checked out on BRANCH."
  (when-let* ((session (cdr (assoc branch demo-sessions))))
    (ecc-space-select (ecc-space-of-root (ecc-session-project-root session))))
  nil)

(defun demo-cycle-spaces (times)
  "Go round every Space TIMES times, with a pause to watch each arrive."
  (dotimes (_ times)
    (dolist (space (ecc-space-list))
      (ecc-space-select space)
      (sit-for 1.2)))
  nil)

;;;; 3. The zoom, which is kept per tab

(defun demo-zoom ()
  "Fill this tab with the window point is in, and say what key that is."
  (ecc-space-zoom)
  nil)

(defun demo-report-zoom ()
  "Say which Space this is, what it is keyed under, and whether it is zoomed."
  (let ((key (ecc-window--layout-key)))
    (demo-say
     (format "Showing %s   -- zoom is kept under %S   -- zoomed here: %s   -- windows: %d"
             (if-let* ((current (ecc-space-current-key)))
                 (ecc-space-name (ecc-space-of-root current))
               "no Space of ours")
             key
             (if (alist-get key (frame-parameter nil 'ecc-space-zoom)
                            nil nil #'equal)
                 "yes" "no")
             (length (window-list nil 'no-minibuffer)))))
  nil)

;;;; 4. Two frames

(defun demo-open-second-frame ()
  "Open a second frame, off camera, and say what it has of the Spaces.
Only the demo frame's own window is recorded, so the other frame is
never in the picture: what it holds is read out here instead, and what
it does to this frame is on the screen."
  (setq demo-second-frame (make-frame '((name . "ecc demo: the other frame")
                                        (width . 100) (height . 30)
                                        (left . 2200) (top . 60))))
  ;; `make-frame' selects what it made, and a step arriving from
  ;; `emacsclient' afterwards would act on that frame rather than the one
  ;; being recorded.  Selected, not focused: a demo does not take the
  ;; keyboard off whoever is working beside it.
  (select-frame (demo-main-frame))
  (demo-report-frames)
  nil)

(defun demo-frame-tabs (frame)
  "Return what FRAME has of the Spaces, as a line to read out."
  (let ((tabs (ecc-space--tabs frame)))
    (if tabs
        (mapconcat (lambda (entry)
                     (format "%s -> tab %S"
                             (ecc-space-name (ecc-space-of-root (car entry)))
                             (cdr entry)))
                   tabs ", ")
      "nothing")))

(defun demo-report-frames ()
  "Say what each frame holds of the Spaces, and how many tabs it has."
  (demo-say
   (format "this frame: %s  [%d tabs]      the other frame: %s  [%d tabs]"
           (demo-frame-tabs (demo-main-frame))
           (length (with-selected-frame (demo-main-frame)
                     (funcall tab-bar-tabs-function)))
           (if (frame-live-p demo-second-frame)
               (demo-frame-tabs demo-second-frame) "not open")
           (if (frame-live-p demo-second-frame)
               (length (with-selected-frame demo-second-frame
                         (funcall tab-bar-tabs-function)))
             0)))
  nil)

(defun demo-open-space-on-the-other-frame (branch)
  "Go to the Space of BRANCH from the other frame, without leaving this one.
Before, this is where the table for the whole Emacs came apart: the tab
of that Space is on this frame, which the other frame cannot see by
name, so the record was dropped and this frame was left with a tab that
nothing pointed at."
  (when-let* ((session (cdr (assoc branch demo-sessions))))
    (with-selected-frame demo-second-frame
      (ecc-space-select (ecc-space-of-root (ecc-session-project-root session)))))
  (demo-report-frames)
  nil)

(defun demo-close-space-from-the-other-frame (branch)
  "Close the Space of BRANCH from the other frame, and watch this one.
A Space is closed on its own account: its sessions stop wherever they
were shown, so its tab goes from every frame that had one.  This frame
is about to lose a tab it was never asked about."
  (when-let* ((session (cdr (assoc branch demo-sessions))))
    (let ((root (ecc-session-project-root session)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt)
                   ;; Yes to stopping the sessions, no to removing the
                   ;; checkout: two questions, and only the first is what
                   ;; this step is about.
                   (let ((answer (and (string-match-p "Stop" prompt) t)))
                     (demo-say (concat prompt (if answer "yes" "no")))
                     (sit-for 4)
                     answer))))
        (with-selected-frame demo-second-frame
          (ecc-space-close (ecc-space-of-root root))))))
  (demo-report-frames)
  nil)

(defun demo-close-second-frame ()
  "Put the other frame away."
  (when (frame-live-p demo-second-frame)
    (delete-frame demo-second-frame))
  (setq demo-second-frame nil)
  (select-frame (demo-main-frame))
  nil)

;;;; The bar, for whoever wants it

(defun demo-show-the-bar ()
  "Draw the tab bar after all, which is the other half of the setting."
  (customize-set-variable 'tab-bar-show t)
  (tab-bar-mode 1)
  (demo-frame)
  (demo-say "tab-bar-show = t -- the same Spaces, with the strip drawn.  Either way is the user's to choose, and ecc no longer has a vote")
  nil)

(provide 'tab-bar-hidden)
;;; tab-bar-hidden.el ends here
