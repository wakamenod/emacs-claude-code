;;; sidebar-keys.el --- Every key of the sidebar, on a real frame  -*- lexical-binding: t; -*-

;;; Commentary:

;; The sidebar as 0.3.0 ships it: the Spaces at the top with their
;; worktrees on tree lines, the sessions at the bottom with what each is
;; waiting for, and the keys that work there -- RET, n, p, TAB, the
;; numbers, c, W, a, d, k, x, X, g and q.
;;
;; Real sessions, and one of them is sent a prompt that makes the CLI
;; ask for a tool, so that `a' and `d' have something to answer.  The
;; questions ecc asks are put on the screen and answered without a
;; minibuffer, the way demo/scenes/worktree-removal-offer.el does it:
;; Emacs does not answer the recorder while a minibuffer is open.
;;
;; Played by demo/scenes/sidebar-keys.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-worktree)

(defvar demo-sessions nil
  "The sessions this scene started, by name.")

(defvar demo-answers nil
  "Alist of a regexp matching a question to the answer to give it.")

(defvar demo-asked nil
  "The questions that have been asked, newest first.")

;;;; The questions, answered without a minibuffer

(defun demo-answer (prompt)
  "Answer PROMPT from `demo-answers', after putting it on the screen."
  (let ((answer (cl-loop for (regexp . value) in demo-answers
                         when (string-match-p regexp prompt) return value)))
    (push prompt demo-asked)
    (demo-say (format "%s%s" prompt (if answer "yes" "no")))
    (sit-for 3)
    answer))

(defun demo-expect (&rest answers)
  "Take ANSWERS, a list of (REGEXP . ANSWER), as the answers to come."
  (setq demo-answers answers
        demo-asked nil)
  nil)

(defun demo-report-asked ()
  "Say what was asked since the last `demo-expect'."
  (demo-say (format "Questions asked: %d%s"
                    (length demo-asked)
                    (if demo-asked
                        (format "   -- %s" (string-join (reverse demo-asked) " // "))
                      "   -- nothing was asked")))
  nil)

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t
        ecc-space-always-session t
        demo-sessions nil
        demo-answers nil
        demo-asked nil)
  (advice-add 'yes-or-no-p :override #'demo-answer)
  (advice-add 'y-or-n-p :override #'demo-answer)
  ;; A project of this scene's own.  `demo-root' is one path for
  ;; every scene, and `demo-fresh-repository' deletes it: a second
  ;; scene starting while this one runs took the worktrees of this
  ;; one out from under it (2026-09-17).
  (setq demo-root "/tmp/ecc-demo-sidebar-keys/")
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s   --   ecc-use-spaces = %S"
                    (abbreviate-file-name (locate-library "ecc-sidebar"))
                    ecc-use-spaces))
  nil)

;;;; The sidebar itself

(defun demo-sidebar-key (key &optional text prefix)
  "Run what KEY is bound to in the sidebar.  TEXT and PREFIX as in demo.el."
  (demo-run-key-in ecc-sidebar-buffer-name key text prefix))

(defun demo-say-sidebar-key (key)
  "Say what KEY runs in the sidebar."
  (demo-say-key-in ecc-sidebar-buffer-name key))

(defun demo-source-key (key &optional text prefix)
  "Run what KEY is bound to in the source buffer, which is the global map."
  (demo-run-key-in (get-file-buffer (expand-file-name "greet.py" demo-root))
                   key text prefix))

(defun demo-report-window ()
  "Say what kind of window the sidebar is, and how wide."
  (let ((window (get-buffer-window ecc-sidebar-buffer-name)))
    (demo-say
     (if window
         (format "sidebar window: %d columns, no-other-window = %S, side = %S, selected = %S"
                 (window-total-width window)
                 (window-parameter window 'no-other-window)
                 (window-parameter window 'window-side)
                 (eq window (selected-window)))
       "the sidebar is not on the screen")))
  nil)

(defun demo-report-rows ()
  "Say what the sidebar is drawing, line by line."
  (demo-say
   (if-let* ((buffer (get-buffer ecc-sidebar-buffer-name)))
       (with-current-buffer buffer
         (string-join
          (seq-remove #'string-empty-p
                      (split-string (string-trim (buffer-string)) "\n"))
          " / "))
     "no sidebar"))
  nil)

(defun demo-report-point ()
  "Say what the row point is on stands for."
  (with-current-buffer ecc-sidebar-buffer-name
    (let ((item (ecc-sidebar--item-at-point)))
      (demo-say (format "point is on: %s"
                        (cond ((ecc-session-p item)
                               (format "session %s" (ecc-session-name item)))
                              ((ecc-space-p item)
                               (format "Space %s" (ecc-space-name item)))
                              (t "nothing"))))))
  nil)

(defun demo-report-current ()
  "Say which Space is showing and what the windows of the tab are."
  (demo-say (format "showing: %s   --   windows: %s"
                    (if-let* ((key (ecc-space-current-key)))
                        (ecc-space-name (ecc-space-of-root key))
                      "none")
                    (mapconcat (lambda (window)
                                 (buffer-name (window-buffer window)))
                               (window-list nil 'no-minibuffer) " | ")))
  nil)

(defun demo-report-pending ()
  "Say what every session is waiting for."
  (demo-say (format "pending: %s"
                    (or (mapconcat
                         (lambda (request)
                           (format "%s wants %s"
                                   (ecc-session-name (ecc-request-session request))
                                   (or (ecc-request-tool-name request)
                                       (ecc-request-kind request))))
                         (ecc-model-pending-all) " | ")
                        "nothing")))
  nil)

;;;; The steps

(defun demo-show-sidebar ()
  "Open the sidebar the way the key does, and say which key that is."
  (demo-say-key-in (get-file-buffer (expand-file-name "greet.py" demo-root))
                   "C-c c b")
  (demo-source-key "C-c c b")
  nil)

(defun demo-report-the-two-keys ()
  "Say what the two keys that swapped now run."
  (with-current-buffer (get-file-buffer (expand-file-name "greet.py" demo-root))
    (demo-say (format "C-c c b runs %S   --   C-c c B runs %S"
                      (key-binding (kbd "C-c c b"))
                      (key-binding (kbd "C-c c B")))))
  nil)

(defun demo-start-here (&optional name)
  "Start a session in the repository."
  (let ((default-directory demo-root))
    (push (cons (or name "one") (ecc-start demo-root (or name "one")))
          demo-sessions))
  nil)

(defun demo-start-worktree (branch)
  "Check BRANCH out beside the demo project and start a session there."
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

(defun demo-point-on (name)
  "Put point in the sidebar on the row whose item is called NAME.
The rows are walked and each item asked its own name, rather than the
text searched: a Space is drawn with a mark, a number and a tree line in
front of it, and a name that is a substring of another name -- a session
called `alpha\=' under a worktree called `feat/alpha\=' -- would find the
wrong row."
  (with-current-buffer ecc-sidebar-buffer-name
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (let ((item (ecc-sidebar--item-at-point)))
          (when (and item
                     (not (get-text-property (line-beginning-position)
                                             'ecc-sidebar-detail))
                     (string-match-p
                      (regexp-quote name)
                      (cond ((ecc-session-p item) (ecc-session-name item))
                            ((ecc-space-p item) (ecc-space-name item))
                            (t ""))))
            (setq found (point))))
        (unless found (forward-line 1)))
      (unless found
        (error "No row called %s in the sidebar" name))
      (goto-char found)
      (beginning-of-line)
      ;; The window's point is what a key typed there acts on, and it is
      ;; restored over the buffer's the moment the window is selected: a
      ;; step that moved only the buffer's point ran every key on the row
      ;; the sidebar had last drawn point on (2026-09-17).
      (when-let* ((window (get-buffer-window ecc-sidebar-buffer-name)))
        (set-window-point window (point)))))
  (demo-report-point))

(defun demo-send (name text)
  "Send TEXT to the session called NAME."
  (when-let* ((session (cdr (assoc name demo-sessions))))
    (ecc-proc-send-prompt session text))
  nil)

(defun demo-cleanup ()
  "Stop everything this scene started and take the worktrees away."
  (setq demo-answers '((".*" . t)))
  (dolist (entry demo-sessions)
    (when (process-live-p (ecc-session-process (cdr entry)))
      (ignore-errors (ecc-kill (cdr entry)))))
  nil)

(provide 'sidebar-keys)
;;; sidebar-keys.el ends here
