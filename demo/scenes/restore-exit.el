;;; restore-exit.el --- The first half of ecc-restore: sessions open at exit  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of feat/session-restore, in two recordings because the
;; point of it is a restart: this one opens two Spaces with three real
;; sessions in them, shows the state file following every session that
;; starts or is killed, and ends with `kill-emacs'.  `restore-back' is
;; the Emacs that comes after it.
;;
;; Both halves work in `demo-restore-root' -- two repositories, alpha and
;; beta -- and write `demo-restore-file' rather than the temporary file
;; demo.el points `ecc-restore-file' at, so the second can read what the
;; first left.  `restore-back' loads this file for the helpers.
;;
;; Played by demo/scenes/restore-exit.sh through demo/record.sh.

;;; Code:

(require 'ecc)

(defvar demo-restore-root "/tmp/ecc-demo-restore/"
  "The directory both halves work in: a repository alpha and one beta.")

(defvar demo-restore-file "/tmp/ecc-demo-restore-state.eld"
  "The state file both halves share.")

(defun demo-restore-project (name)
  "Return the directory of the project NAME."
  (file-name-as-directory (expand-file-name name demo-restore-root)))

(defun demo-restore-use-file ()
  "Point `ecc-restore-file' at the file both halves share."
  (setq ecc-use-spaces t
        ecc-restore-file demo-restore-file))

;;;; Saying what is there

(defun demo-restore-report-file ()
  "Say what the state file holds, read back from the disk."
  (let ((state (ecc-restore--read)))
    (demo-say
     (if (null state)
         (format "%s: nothing saved" (abbreviate-file-name ecc-restore-file))
       (format "%s -- Spaces: %s   sessions: %s"
               (abbreviate-file-name ecc-restore-file)
               (mapconcat (lambda (root)
                            (file-name-nondirectory (directory-file-name root)))
                          (plist-get state :spaces) ", ")
               (mapconcat (lambda (entry) (plist-get entry :name))
                          (plist-get state :sessions) ", ")))))
  nil)

(defun demo-restore-report-sessions ()
  "Say which sessions there are, what state each is in, and whether a CLI runs."
  (demo-say
   (format "Sessions: %s   -- tabs: %s"
           (or (mapconcat
                (lambda (session)
                  (format "%s [%s, %s]"
                          (ecc-session-name session)
                          (ecc-session-state session)
                          (if (process-live-p (ecc-session-process session))
                              "CLI running" "no process")))
                (ecc-model-sessions) "  ")
               "none")
           (mapconcat (lambda (tab) (or (alist-get 'name tab) "?"))
                      (funcall tab-bar-tabs-function) " | ")))
  nil)

;;;; Building the projects

(defun demo-restore-repository (name file content)
  "Make the repository NAME with FILE holding CONTENT, committed."
  (let ((demo-root (demo-restore-project name)))
    (demo-fresh-repository)
    (demo-write file content)
    (demo-git "add" ".")
    (demo-git "commit" "-q" "-m" "first")))

(defun demo-scene-build ()
  "Build both projects and open the first.  Called by demo.el once there is a frame."
  (demo-restore-use-file)
  (ignore-errors (delete-file demo-restore-file))
  (delete-directory demo-restore-root t)
  (demo-restore-repository "alpha" "greet.py"
                           "def greet(name):\n    return \"hi \" + name\n")
  (demo-restore-repository "beta" "notes.md" "# beta\n\nNotes.\n")
  (setq demo-root (demo-restore-project "alpha"))
  (demo-restore-show-source "alpha" "greet.py"))

(defun demo-restore-show-source (project file)
  "Visit FILE of PROJECT and say which ecc this is."
  (find-file (expand-file-name file (demo-restore-project project)))
  (demo-say (format "ecc from %s   state file: %s"
                    (abbreviate-file-name (locate-library "ecc"))
                    (abbreviate-file-name ecc-restore-file)))
  nil)

;;;; The steps

(defun demo-restore-start (project name)
  "Start a real session called NAME in PROJECT."
  (let ((default-directory (demo-restore-project project)))
    (ecc-start (demo-restore-project project) name))
  nil)

(defun demo-restore-send (name text)
  "Send TEXT to the session called NAME, so its recording has a turn."
  (ecc-send text (seq-find (lambda (session)
                             (equal (ecc-session-name session) name))
                           (ecc-model-sessions)))
  nil)

(defun demo-restore-kill (name)
  "Kill the session called NAME, as `k' in the sidebar would."
  (when-let* ((session (seq-find (lambda (session)
                                   (equal (ecc-session-name session) name))
                                 (ecc-model-sessions))))
    (ecc-kill session))
  nil)

(defun demo-restore-exit ()
  "Quit Emacs the way a user does, a moment after this step has answered."
  (run-at-time 1 nil #'kill-emacs)
  nil)

(provide 'restore-exit)
;;; restore-exit.el ends here
