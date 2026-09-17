;;; late-fixes.el --- What came after the release branch was cut  -*- lexical-binding: t; -*-

;;; Commentary:

;; The fixes that went onto release/0.3.0 after the pull request was
;; opened, and that no other scene shows:
;;
;; * a session in a worktree is named by its branch, so the Space and
;;   the session under it are one spelling rather than two
;;   (`ecc-worktree-session-name');
;; * `a' and `d' in the sidebar and in the dashboard ask before they
;;   answer, and neither answers a tool of `ecc-answer-exclude-tools' --
;;   a shell command is read in the transcript, not from a row;
;; * `k' in the dashboard asks, as the sidebar's always has;
;; * `ecc-sidebar-width' is a setting;
;; * `ecc-worktree-directory' is a variable again, not a setting.
;;
;; One real session is made to ask for two tools -- a Write and a Bash
;; -- so that the answering keys have something to answer.  The
;; questions ecc asks are put on the screen and answered without a
;; minibuffer, as in demo/scenes/worktree-removal-offer.el.
;;
;; Played by demo/scenes/late-fixes.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-dashboard)
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
  (demo-say (format "Asked: %d%s"
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
        ;; The machine's own default may allow a Write without asking,
        ;; and then the answering keys have nothing to answer.
        ecc-permission-mode "default"
        demo-sessions nil
        demo-answers nil
        demo-asked nil)
  (advice-add 'yes-or-no-p :override #'demo-answer)
  (advice-add 'y-or-n-p :override #'demo-answer)
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (ecc-sidebar-show)
  (demo-say (format "ecc from %s" (abbreviate-file-name (locate-library "ecc-sidebar"))))
  nil)

;;;; The settings that changed shape

(defun demo-report-settings ()
  "Say which of the two is a setting now and which is a variable."
  (demo-say
   (format "ecc-sidebar-width: %s (%d)   --   ecc-worktree-directory: %s (%s)"
           (if (custom-variable-p 'ecc-sidebar-width) "a setting" "a variable")
           ecc-sidebar-width
           (if (custom-variable-p 'ecc-worktree-directory) "a setting" "a variable")
           ecc-worktree-directory))
  nil)

(defun demo-widen-the-sidebar (columns)
  "Draw the sidebar COLUMNS wide, which is what the setting is for."
  (setq ecc-sidebar-width columns)
  (ecc-sidebar-hide)
  (ecc-sidebar-show)
  (demo-say (format "ecc-sidebar-width = %d" columns))
  nil)

;;;; A session that goes by its branch

(defun demo-start-here (name)
  "Start a session in the repository under NAME."
  (let ((default-directory demo-root))
    (push (cons name (ecc-start demo-root name)) demo-sessions))
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

(defun demo-report-names ()
  "Say what the Spaces and the sessions are called, which used to differ."
  (demo-say
   (format "Spaces: %s      Sessions: %s"
           (mapconcat #'ecc-space-name (ecc-space-list) ", ")
           (mapconcat #'ecc-session-name (ecc-model-sessions) ", ")))
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

;;;; Something to answer

(defun demo-send (name text)
  "Send TEXT to the session called NAME."
  (when-let* ((session (cdr (assoc name demo-sessions))))
    (ecc-proc-send-prompt session text))
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

(defun demo-wait-for-a-request (&optional seconds)
  "Wait until something is waiting for an answer, or SECONDS pass."
  (let ((deadline (+ (float-time) (or seconds 30))))
    (while (and (< (float-time) deadline) (null (ecc-model-pending-all)))
      (sit-for 0.2)))
  (demo-report-pending))

;;;; The two lists of rows

(defun demo-sidebar--goto (name)
  "Put point and the sidebar window's point on the row called NAME."
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
      (unless found (error "No row called %s in the sidebar" name))
      (goto-char found)
      (beginning-of-line)
      (when-let* ((window (get-buffer-window ecc-sidebar-buffer-name)))
        (set-window-point window (point))))))

(defun demo-sidebar-do (name key &optional text prefix)
  "Run what KEY does in the sidebar on the row called NAME.
The row is found again inside the timer that runs the key: the sidebar
redraws several times a second while a session is working, and a step
that placed point and left the key to a later timer ran it on whatever
row the redraw had left point on (2026-09-18)."
  (run-at-time
   0.2 nil
   (lambda ()
     (when-let* ((window (get-buffer-window ecc-sidebar-buffer-name)))
       (with-selected-frame (window-frame window)
         (with-selected-window window
           (with-current-buffer ecc-sidebar-buffer-name
             (demo-sidebar--goto name)
             (let ((command (key-binding (kbd key))))
               (when text
                 (setq unread-command-events
                       (append (string-to-list text)
                               (listify-key-sequence (kbd "RET")))))
               (let ((current-prefix-arg prefix))
                 (condition-case error
                     (call-interactively command)
                   (user-error
                    (demo-say (format "%s: %s" key (error-message-string error))))))))))))) 
  nil)

(defun demo-sidebar-point-on (name)
  "Put point, and the sidebar window's point, on the row called NAME."
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
      (unless found (error "No row called %s in the sidebar" name))
      (goto-char found)
      (beginning-of-line)
      (when-let* ((window (get-buffer-window ecc-sidebar-buffer-name)))
        (set-window-point window (point)))))
  (demo-say (format "the sidebar's point is on %s" name))
  nil)

(defun demo-sidebar-key (key &optional text prefix)
  "Run what KEY is bound to in the sidebar."
  (demo-run-key-in ecc-sidebar-buffer-name key text prefix))

(defun demo-open-dashboard ()
  "Open the dashboard, which is the same list in the form that does not stay."
  (ecc-dashboard)
  (demo-frame)
  nil)

(defun demo-dashboard-point-on (name)
  "Put point, and the dashboard window's point, on the row of session NAME."
  (let ((buffer (get-buffer "*ecc-dashboard*")))
    (with-current-buffer buffer
      (goto-char (point-min))
      (unless (search-forward name nil t)
        (error "No row called %s in the dashboard" name))
      (beginning-of-line)
      (when-let* ((window (get-buffer-window buffer t)))
        (set-window-point window (point)))))
  (demo-say (format "the dashboard's point is on %s" name))
  nil)

(defun demo-dashboard-key (key &optional text prefix)
  "Run what KEY is bound to in the dashboard."
  (demo-run-key-in "*ecc-dashboard*" key text prefix))

(defun demo-report-message ()
  "Say what the last message of this Emacs was."
  (with-current-buffer "*Messages*"
    (save-excursion
      (goto-char (point-max))
      (forward-line -1)
      (demo-say (format "last message: %s"
                        (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))))
  nil)

(defun demo-cleanup ()
  "Stop everything this scene started."
  (setq demo-answers '((".*" . t)))
  (dolist (entry demo-sessions)
    (when (process-live-p (ecc-session-process (cdr entry)))
      (ignore-errors (ecc-kill (cdr entry)))))
  nil)

(provide 'late-fixes)
;;; late-fixes.el ends here
