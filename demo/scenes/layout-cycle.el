;;; layout-cycle.el --- The layouts of a Space, one press of V at a time  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-space-cycle-layout' (C-c c V, V in the menu): four real sessions
;; in one project, and the key pressed again and again, through the six
;; layouts and back to the first.  Then the tab is pulled apart and a
;; fresh press puts back the layout it last had, and C-u goes back to
;; the first.
;;
;; Each press is the command `C-c c V' is bound to in the selected
;; window, called with `last-command' set the way the key pressed twice
;; leaves it -- a step arrives from emacsclient, and the command loop
;; never sees one press follow another.
;;
;; Played by demo/scenes/layout-cycle.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-space)
(require 'ecc-sidebar)

(defvar demo-sessions nil "The sessions this scene started, newest first.")

(defun demo-scene-build ()
  "Build the project.  Called by demo.el once there is a frame."
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return \"hi \" + name\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (find-file (expand-file-name "greet.py" demo-root))
  (demo-say (format "ecc from %s"
                    (abbreviate-file-name (locate-library "ecc"))))
  nil)

(defun demo-start-session (name)
  "Start a real session called NAME in the project."
  (push (ecc-start demo-root name) demo-sessions)
  (demo-frame)
  nil)

(defun demo-session-window ()
  "Return a window showing one of the sessions of this scene, or nil."
  (seq-some (lambda (session)
              (get-buffer-window (ecc-session-buffer session) t))
            demo-sessions))

(defun demo-report-windows ()
  "Say what the main area of this tab holds: name, size and place of each window."
  (when-let* ((window (demo-session-window)))
    (with-selected-frame (window-frame window)
      (let* ((main (window-main-window))
             (x0 (nth 0 (window-edges main)))
             (y0 (nth 1 (window-edges main))))
        (demo-say
         (format "%s · %s"
                 (nth 1 (assq (ecc-space--layout) ecc-space--layouts))
                 (mapconcat
                  (lambda (window)
                    (let ((edges (window-edges window)))
                      (format "%s %dx%d@%d,%d"
                              (buffer-name (window-buffer window))
                              (window-total-width window)
                              (window-total-height window)
                              (- (nth 0 edges) x0) (- (nth 1 edges) y0))))
                  (seq-remove (lambda (window)
                                (window-parameter window 'window-side))
                              (window-list nil 'never))
                  " | "))))))
  nil)

(defun demo-press (&optional again first)
  "Press `C-c c V' in the selected window: right after itself when AGAIN.
FIRST is `C-u'.  The windows are reported once the layout is built."
  (run-at-time
   0.2 nil
   (lambda ()
     (when-let* ((window (demo-session-window)))
       (with-selected-frame (window-frame window)
         (let ((command (with-current-buffer (window-buffer (selected-window))
                          (key-binding (kbd "C-c c V"))))
               (last-command (if again 'ecc-space-cycle-layout 'ignore))
               (current-prefix-arg first))
           (setq this-command command)
           (call-interactively command))))
     (run-at-time 1 nil #'demo-report-windows)))
  nil)

(defun demo-mess-it-up ()
  "Fill the tab with one transcript, the way `C-x 1' on it leaves it."
  (when-let* ((window (demo-session-window)))
    (with-selected-frame (window-frame window)
      (with-selected-window window
        (delete-other-windows))))
  (demo-report-windows))

(defun demo-cleanup ()
  "Stop every session."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say "Every session stopped.")
  nil)

(provide 'layout-cycle)
;;; layout-cycle.el ends here
