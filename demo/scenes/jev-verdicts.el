;;; jev-verdicts.el --- What a finished turn meant, in the sidebar  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-jev' on a real frame, with real sessions and real requests to
;; Jev.  The CLI reports every session that has stopped as idle; this is
;; the check that the one waiting on the user is the one wearing the
;; mark, and that the ones that are not are left alone.
;;
;; Nothing here is staged: the prompts are ordinary, what Claude says
;; back is whatever it says, and the verdicts come from api.typesafe.ai.
;; The captions say what happened rather than what was meant to: the
;; first take of this scene promised a mark that the session never wore,
;; because the CLI answered a question with the AskUserQuestion tool and
;; a session waiting on a tool is not idle at all (2026-09-19).  That
;; case is now a step of its own, and the prompt that wants a question in
;; plain text says so.
;; jev.el is not on this Emacs's load-path by default and its key is in
;; the Keychain, so `demo-jev-setup' puts both in place and says what it
;; found -- without printing the key.
;;
;; Played by demo/scenes/jev-verdicts.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-jev)

(defvar demo-jev-directory "~/Projects/SideProjects/jev.el"
  "Where jev.el is checked out on this machine.
A demo runs the user's own configuration, and this one is not in it.")

(defvar demo-sessions nil
  "The sessions this scene started, by name.")

(defvar demo-answers nil
  "Alist of a regexp matching a question to the answer to give it.")

;;;; The questions, answered without a minibuffer

(defun demo-answer (prompt)
  "Answer PROMPT from `demo-answers', after putting it on the screen."
  (let ((answer (cl-loop for (regexp . value) in demo-answers
                         when (string-match-p regexp prompt) return value)))
    (demo-say (format "%s%s" prompt (if answer "yes" "no")))
    (sit-for 2)
    answer))

;;;; What the scene is played in

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t
        ecc-space-always-session t
        demo-sessions nil
        demo-answers '(("Stop \\|Remove\\|not committed\\|Allow" . t)))
  (advice-add 'yes-or-no-p :override #'demo-answer)
  (advice-add 'y-or-n-p :override #'demo-answer)
  (setq demo-root "/tmp/ecc-demo-jev-verdicts/")
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "README.md" "# greet\n\nA greeting.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "greet.py" demo-root))
  nil)

(defun demo-jev-setup ()
  "Put jev.el and its key where this Emacs can find them, and say what it found.
The key is read once here so that a Keychain that wants a dialog wants
it now, before anything is timed -- and its length is all that is said."
  (add-to-list 'load-path (expand-file-name demo-jev-directory))
  (let* ((loaded (require 'jev nil t))
         (key (when loaded
                (add-to-list 'auth-sources 'macos-keychain-internet)
                (setq jev-auth-source-user "jev")
                (ignore-errors
                  (length (jev--api-key jev-provider))))))
    (demo-say (format "ecc from %s   --   jev.el %s   --   provider %s, key %s"
                      (abbreviate-file-name (locate-library "ecc-jev"))
                      (if loaded (abbreviate-file-name (locate-library "jev"))
                        "NOT INSTALLED")
                      (if loaded jev-provider "-")
                      (if key (format "%d characters" key) "NOT FOUND"))))
  nil)

;;;; What it is showing

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

(defun demo-report-verdicts ()
  "Say what Jev made of each session, and what the CLI says about it."
  (demo-say
   (format "ecc-jev-enabled = %S   --   %s"
           ecc-jev-enabled
           (or (mapconcat
                (lambda (session)
                  (let ((verdict (ecc-jev-verdict session)))
                    (format "%s: state %s, jev %s"
                            (ecc-session-name session)
                            (ecc-tab-state session)
                            (if verdict
                                (format "%s at %s -> %s"
                                        (car verdict) (cdr verdict)
                                        (or (ecc-jev-mark-of (car verdict)
                                                             (cdr verdict))
                                            "the ordinary mark"))
                              "nothing"))))
                (ecc-model-sessions) " // ")
               "no sessions")))
  nil)

(defun demo-report-said (name)
  "Say the last thing the session called NAME said -- what Jev was sent."
  (let* ((session (cdr (assoc name demo-sessions)))
         (turn (and session (car (last (ecc-session-turns session)))))
         (text (and turn (ecc-jev--turn-text turn))))
    (demo-say (format "%s last said: %s" name
                      (if text (string-trim (replace-regexp-in-string
                                             "\n+" " " text))
                        "nothing"))))
  nil)

;;;; The steps

(defun demo-show-sidebar ()
  "Open the sidebar."
  (demo-run-key-in (get-file-buffer (expand-file-name "greet.py" demo-root))
                   "C-c c b")
  nil)

(defun demo-start-here (name)
  "Start a session called NAME in the repository."
  (let ((default-directory demo-root))
    (push (cons name (ecc-start demo-root name)) demo-sessions))
  nil)

(defun demo-send (name text)
  "Send TEXT to the session called NAME."
  (when-let* ((session (cdr (assoc name demo-sessions))))
    (ecc-proc-send-prompt session text))
  nil)

(defun demo-jev-on ()
  "Turn the verdicts on."
  (setq ecc-jev-enabled t)
  (demo-say "(setq ecc-jev-enabled t)   --   nothing else is required")
  nil)

(defun demo-point-on (name)
  "Put point in the sidebar on the row of the session or Space called NAME."
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
      ;; The window's point is what a key typed there acts on.
      (when-let* ((window (get-buffer-window ecc-sidebar-buffer-name)))
        (set-window-point window (point)))))
  nil)

(defun demo-answer-question (name)
  "Answer the question the session called NAME is waiting on, if it is.
The row is left alone when nothing is waiting: what a session does with
a question is the CLI's to decide, and a scene that insisted on one
stopped with an error in the middle of the recording (2026-09-19)."
  (if-let* ((session (cdr (assoc name demo-sessions)))
            (request (car (ecc-session-pending session))))
      (progn (demo-point-on name)
             (demo-run-key-in ecc-sidebar-buffer-name "a"))
    (demo-say (format "%s is not waiting for anything" name)))
  nil)

(defun demo-cleanup ()
  "Stop everything this scene started."
  (setq demo-answers '((".*" . t)))
  (dolist (entry demo-sessions)
    (when (process-live-p (ecc-session-process (cdr entry)))
      (ignore-errors (ecc-kill (cdr entry)))))
  nil)

(provide 'jev-verdicts)
;;; jev-verdicts.el ends here
