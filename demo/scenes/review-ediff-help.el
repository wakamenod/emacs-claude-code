;;; review-ediff-help.el --- The ediff review's own help  -*- lexical-binding: t; -*-

;;; Commentary:

;; What `?' shows in the control panel of an ediff review, and the keys
;; it names: the scene of feat/review-ediff-help.  It builds a little
;; repository, starts a real session in it, changes the files behind the
;; session's back -- a review does not care how a file was changed --
;; and opens the review.
;;
;; Played by demo/scenes/review-ediff-help.sh through demo/record.sh.

;;; Code:

(require 'ecc-review-ediff)

(defvar demo-session nil
  "The session the review of this scene belongs to.")

;;;; What the review is of

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    \"\"\"Say hi.\"\"\"\n    return \"hi \" + name\n\n\ndef farewell(name):\n    return \"bye \" + name\n")
  (demo-write "README.md" "# greet\n\nA greeting, and a goodbye.\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc and which review style this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc-review-style = %S   ecc from %s"
                    ecc-review-style
                    (abbreviate-file-name (locate-library "ecc-review-ediff"))))
  nil)

(defun demo-start-session ()
  "Start a real session in the project.
Nothing is sent to it: the review is git against git, and the session is
there because a review belongs to one."
  (setq demo-session (ecc-start demo-root "help-demo"))
  nil)

(defun demo-change-files ()
  "Change the files the review is then taken of."
  (demo-write "greet.py" "def greet(name):\n    \"\"\"Say hi.\"\"\"\n    return f\"hello {name}!\"\n\n\ndef farewell(name):\n    return f\"goodbye {name}\"\n\n\ndef shout(name):\n    return greet(name).upper()\n")
  (demo-write "README.md" "# greet\n\nA greeting, a goodbye, and a shout.\n")
  (demo-write "NOTES.md" "Written during the session, so the review has a new file too.\n")
  nil)

(defun demo-open-review ()
  "Open the review of everything that changed since the session started."
  (ecc-review demo-session)
  nil)

;;;; The review's panel

(defun demo-control-buffer ()
  "Return the control buffer of the review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode)
                     ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-place-panel ()
  "Put the control panel above the frame, inside the picture.
On a graphical Emacs it is a frame of its own, placed relative to where
the frame of buffer A was when the review opened."
  (demo-float)
  (with-current-buffer (demo-control-buffer)
    (when (frame-live-p ediff-control-frame)
      (set-frame-position ediff-control-frame 40 20)
      (raise-frame ediff-control-frame)))
  nil)

(defun demo-key (key &optional text prefix)
  "Run what KEY does in the control panel.  TEXT and PREFIX as in demo.el."
  (demo-run-key-in (demo-control-buffer) key text prefix))

(defun demo-say-key (key)
  "Say what KEY runs in the control panel."
  (demo-say-key-in (demo-control-buffer) key))

;;;; What the scene points at

(defun demo-report-help ()
  "Say what the panel says with the help off."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "brief help = %S" ediff-brief-help-message)))
  nil)

(defun demo-report-ret ()
  "Say what RET and mouse-2 run in the panel now."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "In this panel RET runs %S and mouse-2 runs %S -- no more Undocumented command!"
                      (key-binding (kbd "RET")) (key-binding [mouse-2]))))
  nil)

(defun demo-point-on-help ()
  "Put point on the line of the help that names c, where RET used to fail."
  (with-current-buffer (demo-control-buffer)
    (goto-char (point-min))
    (when (search-forward "c -comment" nil t)
      (goto-char (match-beginning 0))))
  nil)

(defun demo-comments ()
  "Say how many comments the review is carrying, and what they are."
  (with-current-buffer (demo-control-buffer)
    (demo-say (format "%d comment(s): %S"
                      (length ecc-review-ediff--comments)
                      (mapcar #'cadr ecc-review-ediff--comments))))
  nil)

(defun demo-message-buffer ()
  "Return the prompt buffer the comments open with \\=`C-u C-c C-c\\='."
  (ecc-review-message-buffer-name demo-session))

(defun demo-cancel-message ()
  "Leave that prompt buffer the way C-c C-k does there."
  (demo-run-key-in (demo-message-buffer) "C-c C-k"))

(provide 'review-ediff-help)
;;; review-ediff-help.el ends here
