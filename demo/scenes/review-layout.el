;;; review-layout.el --- The two layouts of an ediff review  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 9 of the review comments.  What a batch test cannot see is the
;; review on a real frame, with the user's own ediff settings -- a
;; control panel in a frame of its own, by default -- and theme: the
;; two sides one above the other with the reply pane on the right when
;; it opens; | putting them side by side with the pane under them and
;; back; the keys of the left window meeting those of the right in the
;; middle while they are side by side; where the review is at the right
;; end of the right window's header line; no control panel unless ?
;; asks for the help; the reply pane in a frame of its own that never
;; takes the focus; and S in the review menu offering a new session
;; first, which then gets the comments.
;;
;; The review belongs to an archived session with no process.  S starts
;; one real session, to which nothing is sent, and the scene kills it.
;; Keys of the review are typed with `execute-kbd-macro' in the window
;; they belong to, as in review-direct.el; those of the menu go on
;; `unread-command-events', where transient and the minibuffer read
;; them, as in review-menu.el.
;;
;; Every step reports what it found, and the scene ends by saving the
;; reports to /tmp/ecc-demo-review-layout-log.txt, which is what the run
;; is judged from.
;;
;; Played by demo/scenes/review-layout.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-review-direct)
(require 'ecc-review-talk)
(require 'ecc-review-menu)

(defvar demo-session nil "The archived session the review belongs to.")

(defvar demo-started nil "The sessions S started, to be killed at the end.")

(defun demo-lines (edit)
  "Return 60 lines of src/table.py, with EDIT, a function of N, changing some."
  (mapconcat (lambda (n)
               (or (funcall edit n)
                   (format "    row_%02d = lookup(table, %d)  # unchanged\n" n n)))
             (number-sequence 1 60) ""))

(defun demo-old (n)
  "The old text of line N of src/table.py, where it is not the plain one."
  (pcase n
    (1 "def build(table):\n")
    (12 "    total = sum(table)\n")
    (50 "    return total\n")
    (_ nil)))

(defun demo-new (n)
  "The new text of line N of src/table.py, where it is not the plain one."
  (pcase n
    (1 "def build(table):\n")
    (12 "    total = sum(row.value for row in table)\n")
    (30 "    row_30 = lookup(table, 30)  # unchanged\n    cache = {}\n")
    (50 "    return total, cache\n")
    (_ nil)))

;;;; What the scene is played on

(defun demo-scene-build ()
  "Build the project: two files committed, then changed.  Called by demo.el.
`ediff-window-setup-function' is left as the user has it: the review
lays itself out the plain way whatever it says."
  (setq ecc-review-style 'ediff
        ecc-review-files-shown nil
        ecc-review-talk-reply-height 8
        ecc-review-talk-reply-place 'auto
        ecc-review-ediff-layout 'stacked
        ecc-review-talk-make-frame-function
        (lambda ()
          (make-frame `((name . "ecc review reply")
                        (width . ,ecc-review-talk-reply-width) (height . 30)
                        (minibuffer . nil) (no-focus-on-map . t) (unsplittable . t)))))
  (demo-fresh-repository)
  (demo-write "src/table.py" (demo-lines #'demo-old))
  (demo-write "src/util.py" "def double(x):\n    return 2 * x\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-write "src/table.py" (demo-lines #'demo-new))
  (demo-write "src/util.py" "def double(x):\n    return x + x\n")
  (find-file (expand-file-name "src/table.py" demo-root))
  (delete-other-windows)
  (demo-say (format "ecc %s   theme %S   ecc-use-spaces %S   ediff-window-setup-function %S"
                    (ecc-version) custom-enabled-themes ecc-use-spaces
                    (default-value 'ediff-window-setup-function)))
  nil)

(defun demo-open-session ()
  "Make the session the review belongs to."
  (setq demo-session (ecc-model-create-session
                      :id "demo-review-layout"
                      :name "layout"
                      :project-root demo-root
                      :kind 'archived))
  (ecc-model-set-state demo-session 'idle)
  nil)

(defun demo-open-ediff ()
  "Open the review of everything uncommitted, in ediff, as G opens it."
  (ecc-review-worktree demo-session "HEAD" demo-root)
  nil)

;;;; Looking

(defun demo-control-buffer ()
  "Return the control buffer of the ediff review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-side-window (side)
  "Return the window of SIDE, `A' or `B', of the review."
  (buffer-local-value (if (eq side 'A) 'ediff-window-A 'ediff-window-B)
                      (demo-control-buffer)))

(defun demo-header-string (header)
  "Return HEADER as text, a stretch of space written as [->ALIGN-TO]."
  (let ((out "") (i 0))
    (while (< i (length header))
      (let ((next (or (next-single-property-change i 'display header) (length header)))
            (display (get-text-property i 'display header)))
        (setq out (concat out (if (eq (car-safe display) 'space)
                                  (format "[->%S]" (plist-get (cdr display) :align-to))
                                (substring-no-properties header i next))))
        (setq i next)))
    out))

(defun demo-report (label)
  "Say, under LABEL, the layout, the panes, the panel and the keyboard."
  (let* ((control (demo-control-buffer))
         (a (demo-side-window 'A))
         (b (demo-side-window 'B))
         (pane (buffer-local-value 'ecc-review-talk--pane control))
         (pane-window (and (buffer-live-p pane) (get-buffer-window pane t)))
         (selected (frame-selected-window (demo-main-frame))))
    (demo-say
     (format "[%s] %s (A %S, B %S); keyboard in %s; reply pane %s; control panel %s; frames %s"
             label
             (if (< (cadr (window-edges a)) (cadr (window-edges b))) "STACKED" "SIDE BY SIDE")
             (window-edges a) (window-edges b)
             (cond ((eq selected a) "the A window")
                   ((eq selected b) "the B window")
                   (t (buffer-name (window-buffer selected))))
             (cond ((not pane-window) "not shown")
                   ((eq (window-parameter pane-window 'ecc-review-talk) 'frame)
                    (format "in the frame %S, focus state %S"
                            (frame-parameter (window-frame pane-window) 'name)
                            (frame-focus-state (window-frame pane-window))))
                   (t (format "%S side window, %dx%d"
                              (window-parameter pane-window 'window-side)
                              (window-total-width pane-window)
                              (window-total-height pane-window))))
             (if-let* ((window (get-buffer-window control t)))
                 (format "SHOWN, %d lines, mode line %S, help %s"
                         (window-total-height window)
                         (window-parameter window 'mode-line-format)
                         (if (buffer-local-value 'ediff-use-long-help-message control)
                             "long" "brief"))
               "not on the screen")
             (mapconcat (lambda (frame) (format "%S" (frame-parameter frame 'name)))
                        (seq-filter #'frame-visible-p (frame-list)) ", ")))
    (with-current-buffer control
      (demo-say (format "[%s] A header: %s" label
                        (demo-header-string
                         (buffer-local-value 'header-line-format ediff-buffer-A))))
      (demo-say (format "[%s] B header: %s" label
                        (demo-header-string
                         (buffer-local-value 'header-line-format ediff-buffer-B))))))
  nil)

;;;; Doing

(defun demo-type (side keys &optional text)
  "Type KEYS in the window of SIDE, and TEXT and RET into what it reads.
Scheduled, so that the server has its answer before the keys run."
  (run-at-time
   0.2 nil
   (lambda ()
     (let ((window (demo-side-window side)))
       (with-selected-frame (window-frame window)
         (select-window window)
         (execute-kbd-macro (vconcat (kbd keys)
                                     (and text (vconcat text (kbd "RET")))))))))
  nil)

(defun demo-close ()
  "Close the review."
  (when-let* ((control (demo-control-buffer)))
    (ecc-review-ediff-quit control))
  (find-file (expand-file-name "src/table.py" demo-root))
  (delete-other-windows)
  nil)

(defun demo-reply-in-a-frame ()
  "Open the review again with the reply pane in a frame of its own."
  (setq ecc-review-talk-reply-place 'frame)
  (demo-open-ediff))

(defun demo-report-closed (label)
  "Say, under LABEL, the frames left once the review is closed."
  (demo-say (format "[%s] frames %s; reply frame %S; selected frame %S" label
                    (mapconcat (lambda (frame) (format "%S" (frame-parameter frame 'name)))
                               (seq-filter #'frame-visible-p (frame-list)) ", ")
                    ecc-review-talk--frame
                    (frame-parameter (selected-frame) 'name)))
  nil)

;;;; The menu

(defun demo-keys (&rest chunks)
  "Type CHUNKS 0.8 s apart: a string is a key description, a list a text.
They go on `unread-command-events', where transient and the minibuffer
read them the way they read typing."
  (let ((delay 0.3))
    (dolist (chunk chunks)
      (let ((events (if (consp chunk)
                        (string-to-list (car chunk))
                      (listify-key-sequence (kbd chunk)))))
        (run-at-time delay nil
                     (lambda ()
                       (setq unread-command-events
                             (append unread-command-events events)))))
      (setq delay (+ delay 0.8))))
  nil)

(defun demo-open-menu ()
  "Open the review menu in src/table.py."
  (find-file (expand-file-name "src/table.py" demo-root))
  (demo-run-key-in "table.py" "C-c c D")
  nil)

(defun demo-new-session ()
  "S, the first choice, and a name for the second session of the project."
  (demo-keys "S" (list ecc-review-menu-new-session-label) "RET" '("layout-new") "RET"))

(defun demo-report-menu (label)
  "Say, under LABEL, the heading of the menu and the sessions there are."
  (let ((buffer (get-buffer (or (bound-and-true-p transient--buffer-name) " *transient*"))))
    (demo-say (format "[%s] menu %s; heading: %s; sessions: %s" label
                      (if (and buffer (get-buffer-window buffer t)) "open" "closed")
                      (if ecc-review-menu--state
                          (substring-no-properties (ecc-review-menu--header))
                        "-")
                      (mapconcat (lambda (session)
                                   (format "%s(%s)" (ecc-session-name session)
                                           (ecc-session-state session)))
                                 (ecc-model-sessions) ", ")))
    (setq demo-started (seq-remove (lambda (session) (eq session demo-session))
                                   (ecc-model-sessions))))
  nil)

(defun demo-close-menu ()
  "Close whatever transient is open."
  (run-at-time 0.2 nil (lambda () (ignore-errors (transient-quit-all))))
  nil)

(defun demo-cleanup ()
  "Kill the session S started."
  (dolist (session demo-started)
    (ignore-errors (ecc-kill session)))
  nil)

(provide 'review-layout)
;;; review-layout.el ends here
