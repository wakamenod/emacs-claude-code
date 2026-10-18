;;; history-button-click.el --- The history button reads the older page on a click  -*- lexical-binding: t; -*-

;;; Commentary:

;; The scene of refactor/history-button-keymap: the "Load older
;; messages" button no longer carries an action of its own.  Its keys
;; are `ecc-history-button-map', and `ecc-history' binds RET and
;; mouse-2 there.  What a batch test cannot see is the click: mouse-1
;; on a `follow-link' button becomes mouse-2, in the window clicked.
;;
;; The scene opens the recording the tests read, one turn to a page so
;; that there is an older page to read, and clicks the button twice
;; with real mouse events -- once with the session window selected, and
;; once with another window selected -- and says after each how many
;; turns the session holds.
;;
;; Played by demo/scenes/history-button-click.sh through demo/record.sh.

;;; Code:

(require 'ecc)

(defun demo-recording ()
  "Return the recording opened: three turns, the one the history tests read.
It is found beside the ecc this Emacs loaded, which is this checkout's."
  (expand-file-name "test/fixtures/history/session.jsonl"
                    (file-name-directory (locate-library "ecc"))))

(defvar demo-session nil
  "The session the recording was opened in.")

(defun demo-scene-build ()
  "Open the recording, one turn to a page.  Called once there is a frame."
  (setq ecc-history-page-turns 1)
  (let* ((file (demo-recording))
         (id (file-name-base file)))
    (puthash id file ecc-history--files)
    (when-let* ((frame (demo-main-frame)))
      (with-selected-frame frame
        (setq demo-session (ecc-history-open id)))))
  (demo-report))

(defun demo-window ()
  "Return the window of the session in the demo frame."
  (get-buffer-window (ecc-session-buffer demo-session) (demo-main-frame)))

(defun demo-report ()
  "Say how many turns the session holds, and whether the button is there."
  (with-current-buffer (ecc-session-buffer demo-session)
    (demo-say (format "%d turn(s) read; button %s; RET on it runs %S"
                      (length (ecc-session-turns demo-session))
                      (if (save-excursion
                            (goto-char (point-min))
                            (search-forward "Load older messages" nil t))
                          "shown"
                        "gone")
                      (save-excursion
                        (goto-char (point-min))
                        (and (search-forward "Load older messages" nil t)
                             (progn (goto-char (match-beginning 0))
                                    (key-binding (kbd "RET"))))))))
  nil)

(defun demo-select-session-window ()
  "Select the window of the session, as a click into it would have."
  (let ((window (demo-window)))
    (with-selected-frame (demo-main-frame)
      (select-window window)))
  (demo-say (format "Selected %s"
                    (buffer-name (window-buffer (selected-window)))))
  nil)

(defun demo-select-other-window ()
  "Select a window of the demo frame that is not the session's.
The click must then find the session from the window clicked."
  (let ((session-window (demo-window)))
    (with-selected-frame (demo-main-frame)
      (let ((other (or (seq-find (lambda (window) (not (eq window session-window)))
                                 (window-list nil 'no-minibuffer))
                       (split-window session-window nil 'left))))
        (unless (eq (window-buffer other) (get-buffer-create "*scratch*"))
          (set-window-buffer other "*scratch*"))
        (select-window other)
        (demo-say (format "Selected %s; the session is in another window"
                          (buffer-name (window-buffer other)))))))
  nil)

(defun demo-click ()
  "Click mouse-1 on the button, as the hand would.
The press and the release are put on `unread-command-events\\=' from a
timer, so the command loop reads them as it reads a click: the press
goes through `mouse-1-click-follows-link\\=' and the release comes out
as mouse-2."
  (let* ((window (demo-window))
         (pos (with-current-buffer (window-buffer window)
                (save-excursion
                  (goto-char (point-min))
                  (search-forward "Load older messages")
                  (match-beginning 0))))
         (posn (posn-at-point pos window)))
    (demo-say (format "Clicking at %d in %s; selected window shows %s"
                      pos window (buffer-name (window-buffer (selected-window)))))
    (run-at-time 0.2 nil
                 (lambda ()
                   (setq unread-command-events
                         (list (list 'down-mouse-1 posn)
                               (list 'mouse-1 posn))))))
  nil)

(provide 'history-button-click)
;;; history-button-click.el ends here
