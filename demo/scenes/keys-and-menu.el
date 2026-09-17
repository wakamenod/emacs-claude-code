;;; keys-and-menu.el --- The keys 0.3.0 moved, and the menu they moved into  -*- lexical-binding: t; -*-

;;; Commentary:

;; The breaking half of 0.3.0 is a keyboard: the Spaces took the
;; lower-case keys of `ecc-global-map' and of `ecc-menu', the dashboard
;; moved up to `C-c c B', `w' in the menu became the rewrite and `W' the
;; worktree menu, and four commands went away altogether -- `ecc-toggle',
;; `ecc-toggle-all', `ecc-window-focus-source' and
;; `ecc-prompt-resend-last'.  None of that can be read off a test: what
;; matters is what a key does in the buffer it is pressed in, in the
;; user's own configuration, where `C-c c' is bound to the prefix.
;;
;; The scene presses nothing.  It asks each key what it runs, in a real
;; buffer, and opens the two menus so that the columns can be read.
;;
;; Played by demo/scenes/keys-and-menu.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-chat)

(defvar demo-chat-buffer "*ecc keys*"
  "A buffer in `ecc-chat-mode', for the keys that only live in a session.")

;;;; What the keys are asked in

(defun demo-scene-build ()
  "Build a project to press the keys in.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s from %s" (ecc-version)
                    (abbreviate-file-name (locate-library "ecc"))))
  nil)

(defun demo-report-setting ()
  "Say what the layout setting is, and that the old one is gone."
  (demo-say (format "ecc-use-spaces = %S (default t) -- ecc-layout is %s"
                    ecc-use-spaces
                    (if (boundp 'ecc-layout) "STILL BOUND" "gone")))
  nil)

;;;; The keys, one line at a time

(defun demo-keys (&rest keys)
  "Say what each of KEYS runs in the buffer that is current."
  (demo-say
   (mapconcat (lambda (key)
                (format "%s → %s" key
                        (or (key-binding (kbd key)) "unbound")))
              keys "   "))
  nil)

(defun demo-report-spaces-keys ()
  "The four keys the Spaces took."
  (demo-keys "C-c c j" "C-c c b" "C-c c z" "C-c c V"))

(defun demo-report-moved-keys ()
  "The keys that now mean something else, and the one that is watched."
  (demo-keys "C-c c B" "C-c c r" "C-c c c"))

(defun demo-report-review-keys ()
  "The two reviews, which are one review with one argument between them."
  (demo-keys "C-c c D" "C-c c G"))

(defun demo-report-gone-keys ()
  "The keys whose commands went away with them."
  (demo-keys "C-c c w" "C-c c C"))

(defun demo-report-gone-commands ()
  "Say that the removed commands really are gone, by name."
  (let ((gone '(ecc-toggle ecc-toggle-all ecc-window-focus-source
                           ecc-prompt-resend-last ecc-worktree-kill-session
                           ecc-worktree-delete-branch ecc-window-forget-session)))
    (demo-say (format "removed: %s"
                      (mapconcat (lambda (symbol)
                                   (format "%s %s" symbol
                                           (if (fboundp symbol) "STILL HERE" "✓")))
                                 gone "   "))))
  nil)

(defun demo-report-kept-command ()
  "Say that what the removed command was built on is still there."
  (demo-say (format "ecc-focus-project is %s and is M-x now; ecc-window--focus-source is %s"
                    (if (commandp 'ecc-focus-project) "a command" "NOT a command")
                    (if (fboundp 'ecc-window--focus-source) "kept" "GONE")))
  nil)

;;;; The keys of a session buffer

(defun demo-open-chat ()
  "Open a buffer in `ecc-chat-mode\\=', where the prompt keys live."
  (switch-to-buffer (get-buffer-create demo-chat-buffer))
  (ecc-chat-mode)
  (demo-say "A session buffer's own keys, in ecc-chat-mode")
  nil)

(defun demo-report-chat-keys ()
  "Say what the prompt region's keys run."
  (with-current-buffer demo-chat-buffer
    (demo-keys "C-c C-r" "M-p" "C-c C-t"))
  nil)

;;;; The menus

(defun demo-open-menu ()
  "Open `ecc-menu\\=', whose columns are what moved."
  (run-at-time 0.2 nil #'ecc-menu)
  nil)

(defun demo-open-worktree-menu ()
  "Open `ecc-worktree-menu\\=', which is W in `ecc-menu\\=' now."
  (run-at-time 0.2 nil (lambda ()
                         (ignore-errors (transient-quit-all))
                         (run-at-time 0.3 nil #'ecc-worktree-menu)))
  nil)

(defun demo-close-menu ()
  "Close whatever transient is open."
  (run-at-time 0.2 nil (lambda () (ignore-errors (transient-quit-all))))
  nil)

(provide 'keys-and-menu)
;;; keys-and-menu.el ends here
