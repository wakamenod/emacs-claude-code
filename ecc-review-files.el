;;; ecc-review-files.el --- The files of a review, listed and filtered  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The files pane and the file filter of a review, after Hunk's
;; (github.com/modem-dev/hunk): s shows a list of the files beside the
;; diff -- what happened to each, how many lines, how many comments --
;; and / narrows the review to the files whose path, former path or
;; Claude's comments contain what is typed.
;;
;; The pane is a buffer of its own, one per review, and is always
;; immediately left of what it lists.  An ediff review has the frame to
;; itself, so there it is a side window on the left, which ediff's own
;; laying out of its windows leaves alone; a diff review shares the frame
;; with the sessions, so there it is split off the left of the review's
;; window.  Whether it is shown is remembered for as long as Emacs runs,
;; and the next review opens with it or without it the same way.
;;
;; The filter hides and reads nothing again: the files left out are made
;; invisible -- both sides of them in an ediff review -- and the moves of
;; the review step over them, but their comments are kept and still
;; sent.  It is kept across every reading of the review again.
;;
;; What a review is made of differs between the two kinds, so the few
;; questions this asks of one -- which files, which is being read, how
;; to go to one, how to hide some -- are generic functions with the diff
;; review's answers here and the ediff review's in `ecc-review-ediff.el'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecc-core)
(require 'ecc-review)

(defcustom ecc-review-files-width 32
  "How many columns the files pane of a review takes.
The pane sits immediately left of the diff, and the columns it takes
are the diff's; how many a screen can spare is the screen's."
  :type 'integer
  :group 'ecc)

(defvar ecc-review-files-shown nil
  "Non-nil while the files pane is wanted.
\\`s' in a review sets it, and every review opened afterwards opens
with the pane or without it accordingly, for as long as Emacs runs.")

(defface ecc-review-files-current-face
  '((t :inherit bold))
  "Face of the line of the file being read in the files pane."
  :group 'ecc)

;;;; What a review is made of

(defvar-local ecc-review-files--hiders nil
  "The overlays hiding the files the filter leaves out of this review.")

(defvar-local ecc-review-files--cache nil
  "(KEY . ENTRIES): the files of this review, for the review as KEY says it was.")

(defvar-local ecc-review-files--review nil
  "The review this files pane lists.")

(defvar-local ecc-review-files--pane nil
  "The files pane of this review, or nil.")

(defvar-local ecc-review-files--shown-path nil
  "The file the pane of this review marks as being read.")

(defvar-local ecc-review-files--hidden-changed nil
  "Non-nil when the last drawing changed which files the filter hides.")


(cl-defgeneric ecc-review-files-entries ()
  "Return the files of this review, in the order it shows them.
Each is a plist: :path, as the comments name it; :old-path, what a
renamed file was called; :status, \"M\", \"A\", \"D\" or \"R\"; :added
and :removed, how many lines; and whatever the kind of review needs to
find and hide the file again."
  (ecc-review-files--diff-entries))

(cl-defgeneric ecc-review-files-current ()
  "Return the path of the file being read in this review, or nil."
  (when-let* ((entry (seq-find (lambda (entry)
                                 (and (<= (plist-get entry :beg) (point))
                                      (< (point) (plist-get entry :end))))
                               (ecc-review-files--entries))))
    (plist-get entry :path)))

(cl-defgeneric ecc-review-files-goto (entry select)
  "Bring the file ENTRY of this review into view.
SELECT gives the review the keyboard; otherwise only its view moves."
  (let ((position (or (plist-get entry :first) (plist-get entry :beg)))
        (window (or (get-buffer-window (current-buffer))
                    (ecc-review-shown-window))))
    (goto-char position)
    (when (window-live-p window)
      (set-window-point window position)
      (set-window-start window (plist-get entry :beg))
      (when select (select-window window)))
    (run-hooks 'ecc-review-moved-hook)))

(defun ecc-review-files--spec (on)
  "Put the filter's invisibility in this buffer's spec when ON, else take it out.
Once: `add-to-invisibility-spec\=' adds an entry every time it is
called, and redisplay walks the whole spec."
  (if on
      (unless (and (listp buffer-invisibility-spec)
                   (or (memq 'ecc-review-filter buffer-invisibility-spec)
                       (assq 'ecc-review-filter buffer-invisibility-spec)))
        (add-to-invisibility-spec 'ecc-review-filter))
    (remove-from-invisibility-spec 'ecc-review-filter)))

(cl-defgeneric ecc-review-files-hide (entries)
  "Hide the files ENTRIES of this review, and show every other again."
  (mapc #'delete-overlay ecc-review-files--hiders)
  (setq ecc-review-files--hiders nil)
  (ecc-review-files--spec entries)
  (dolist (entry entries)
    (let ((overlay (make-overlay (plist-get entry :beg) (plist-get entry :end) nil t nil)))
      (overlay-put overlay 'invisible 'ecc-review-filter)
      (overlay-put overlay 'evaporate t)
      (push overlay ecc-review-files--hiders))))

(cl-defgeneric ecc-review-files-review-window ()
  "Return the window the files pane of this review goes beside, or nil."
  (get-buffer-window (current-buffer)))

(defun ecc-review-files--split (window)
  "Split `ecc-review-files-width' columns off the left of WINDOW; return them.
The two are made a combination of their own, so that the columns go
back to WINDOW when the pane is deleted, and not to the window on its
other side.  Nil when WINDOW is too narrow to give them: the pane is
never a reason for anything else to fail."
  (let ((window-combination-limit t))
    (condition-case nil
        (split-window window (- ecc-review-files-width) 'left)
      (error nil))))

(defun ecc-review-files--pane-beside (window)
  "Return the files pane window that goes with the review WINDOW, or nil."
  (seq-find (lambda (other)
              (eq (car (window-parameter other 'ecc-review-files-beside)) window))
            (window-list (window-frame window) 'no-minibuffer)))

(cl-defgeneric ecc-review-files-place-pane (pane)
  "Show PANE, the files pane of this review, left of the review; return its window.
Nil when the review is on no window to go beside, or when that window
is too narrow to give the pane its columns.  The pane window
remembers the window and the buffer it goes with: a review that comes
into that window takes the pane window over rather than splitting
another off, and when the review leaves it, or it is deleted, the pane
goes (`ecc-review-files--sweep')."
  (when-let* ((window (ecc-review-files-review-window)))
    (when-let* ((left (or (ecc-review-files--pane-beside window)
                          (ecc-review-files--split window))))
      (set-window-dedicated-p left nil)
      (set-window-buffer left pane)
      (set-window-dedicated-p left t)
      (set-window-parameter left 'ecc-review-files t)
      (set-window-parameter left 'ecc-review-files-beside (cons window (current-buffer)))
      (add-hook 'quit-window-hook #'ecc-review-files--quitting nil t)
      left)))

(defun ecc-review-files--sweep (frame)
  "Delete the files panes of FRAME whose review has left the window beside them.
On `window-buffer-change-functions': another buffer in the review's
window, or the window deleted, and the pane would list a review nobody
is reading."
  (dolist (window (window-list frame 'no-minibuffer))
    (when-let* ((beside (window-parameter window 'ecc-review-files-beside)))
      (unless (and (window-live-p (car beside))
                   (eq (window-buffer (car beside)) (cdr beside)))
        (ignore-errors (delete-window window))))))

(add-hook 'window-buffer-change-functions #'ecc-review-files--sweep)

(defun ecc-review-files--quitting ()
  "Take the files pane down with the review, on `quit-window-hook\='.
At once, and not at the next redisplay as `ecc-review-files--sweep' would."
  (when-let* ((pane (ecc-review-files--pane-beside (selected-window))))
    (ignore-errors (delete-window pane))))

(cl-defgeneric ecc-review-files-give-keyboard ()
  "Select the window of this review that its keys are typed in."
  (when-let* ((window (ecc-review-files-review-window)))
    (select-window window)))

(defun ecc-review-files--nearest-shown (path)
  "Return the file nearest PATH that the filter keeps: after it, else before."
  (let* ((entries (ecc-review-files--entries))
         (tail (or (member (ecc-review-files--entry (current-buffer) path) entries) entries))
         (shown (lambda (entry) (not (ecc-review-hidden-p (plist-get entry :path))))))
    (or (seq-find shown tail)
        (car (last (seq-filter shown (butlast entries (length tail))))))))

(cl-defgeneric ecc-review-files-filter-applied (&optional _quietly)
  "Run in this review once what its filter hides has changed.
Point, and the point of every window on the review, is moved off a file
it hides to the nearest one it keeps.  QUIETLY is for a change no
command of the user's made, a reading again or a comment of Claude's."
  (let ((moved nil))
    (dolist (window (cons nil (get-buffer-window-list (current-buffer) nil t)))
      (let ((position (if window (window-point window) (point))))
        (when (invisible-p position)
          (when-let* ((path (save-excursion (goto-char position) (ecc-review-files-current)))
                      (entry (ecc-review-files--nearest-shown path)))
            (let ((target (or (plist-get entry :first) (plist-get entry :beg))))
              (setq moved t)
              (if window
                  (progn (set-window-point window target)
                         (set-window-start window (plist-get entry :beg)))
                (goto-char target)))))))
    (when moved
      (run-hooks 'ecc-review-moved-hook))))

;;;; The diff review's files

(cl-defgeneric ecc-review-files--key ()
  "Return what says the files of this review may have changed when it changes."
  (buffer-chars-modified-tick))

(defun ecc-review-files--entries ()
  "Return `ecc-review-files-entries', read again only when the review changed."
  (let ((key (ecc-review-files--key)))
    (if (and ecc-review-files--cache
             (let ((was (car ecc-review-files--cache)))
               ;; The parts of the key are compared by identity: the
               ;; differences of an ediff review are a list made afresh
               ;; whenever they change, and read whole every time otherwise.
               (if (consp key)
                   (and (consp was) (= (length was) (length key)) (cl-every #'eq was key))
                 (eql was key))))
        (cdr ecc-review-files--cache)
      (cdr (setq ecc-review-files--cache (cons key (ecc-review-files-entries)))))))

(defun ecc-review-files--file-starts (hunks)
  "Return where each file of this diff buffer begins, in order.
HUNKS are its hunks.  A file begins at a diff line, or at a --- line
right above a +++ line with a hunk since the last beginning -- the
diffs this package makes of what git does not track have no diff line
-- and never inside a hunk, where a --- line is a line taken out."
  (save-excursion
    (goto-char (point-min))
    (let ((starts nil)
          (hunk-since t))
      (while (not (eobp))
        (let ((hunk (and hunks (= (point) (plist-get (car hunks) :position)) (pop hunks))))
          (cond
           (hunk
            (setq hunk-since t)
            (goto-char (plist-get hunk :bound)))
           (t
            (when (or (looking-at-p "diff ")
                      (and hunk-since
                           (looking-at-p "--- ")
                           (save-excursion (forward-line 1) (looking-at-p "\\+\\+\\+ "))))
              (push (point) starts)
              (setq hunk-since nil))
            (forward-line 1)))))
      (nreverse starts))))

(defun ecc-review-files--header-path (header)
  "Return the path the file header HEADER names, without a/ or b/, or nil."
  (save-match-data
    (cond
     ((string-match "^\\+\\+\\+ \\(?:b/\\)?\\(.+\\)$" header)
      (let ((path (match-string 1 header)))
        (if (and (equal path "/dev/null")
                 (string-match "^--- \\(?:a/\\)?\\(.+\\)$" header))
            (match-string 1 header)
          path)))
     ((string-match "^rename to \\(.+\\)$" header) (match-string 1 header))
     ((string-match "^diff --git a/.* b/\\(.+\\)$" header) (match-string 1 header)))))

(defun ecc-review-files--diff-entries ()
  "Return the files of this diff review, as `ecc-review-files-entries' does.
Each also has :beg and :end, where it runs in the buffer, and :first,
where its first hunk begins."
  (let* ((hunks (ecc-review-hunks))
         (starts (ecc-review-files--file-starts hunks))
         (entries nil))
    (while starts
      (let* ((beg (pop starts))
             (end (or (car starts) (point-max)))
             (mine (seq-filter (lambda (hunk)
                                 (and (>= (plist-get hunk :position) beg)
                                      (< (plist-get hunk :position) end)))
                               hunks))
             (header (buffer-substring-no-properties
                      beg (if mine (plist-get (car mine) :position) end)))
             (old (and (string-match "^rename from \\(.+\\)$" header)
                       (match-string 1 header)))
             (added 0)
             (removed 0))
        (dolist (hunk mine)
          (dolist (line (cdr (split-string (plist-get hunk :text) "\n")))
            (pcase (and (> (length line) 0) (aref line 0))
              (?+ (cl-incf added))
              (?- (cl-incf removed)))))
        (push (list :path (or (and mine (plist-get (car mine) :path))
                              (ecc-review-files--header-path header)
                              "?")
                    :old-path old
                    :status (cond (old "R")
                                  ((string-match-p "^\\(?:new file mode\\|--- /dev/null\\)"
                                                   header)
                                   "A")
                                  ((string-match-p "^\\(?:deleted file mode\\|\\+\\+\\+ /dev/null\\)"
                                                   header)
                                   "D")
                                  (t "M"))
                    :added added :removed removed
                    :beg beg :end end
                    :first (and mine (plist-get (car mine) :position)))
              entries)))
    (nreverse entries)))

;;;; The filter

(defun ecc-review-files--matches-p (entry filter notes)
  "Return non-nil when ENTRY is one of the files FILTER keeps.
Hunk's rule (`reviewFileMatchesFilter'): FILTER, ignoring case, is in
the path, the former path, or the text of one of Claude's NOTES on the
file.  An empty FILTER keeps every file."
  (or (null filter)
      (string-empty-p filter)
      (let ((wanted (downcase filter))
            (path (plist-get entry :path)))
        (seq-some (lambda (text) (and text (string-search wanted (downcase text))))
                  (cons path
                        (cons (plist-get entry :old-path)
                              (mapcar #'ecc-review-note-text
                                      (seq-filter
                                       (lambda (note)
                                         (and (ecc-review--agent-p note)
                                              (equal (ecc-review-note-path note) path)))
                                       notes))))))))

(defun ecc-review-files--hidden-entries (filter)
  "Return the files of this review FILTER leaves out."
  (and filter
       (seq-remove (lambda (entry)
                     (ecc-review-files--matches-p entry filter ecc-review--notes))
                   (ecc-review-files--entries))))

(defun ecc-review-files--before-draw ()
  "Hide again the files the filter of this review leaves out.
On `ecc-review-before-draw-hook': the comments drawn next leave the
hidden files out, and a comment of Claude's that has just come may have
brought a file back."
  (when (ecc-review-buffer-p)
    (let* ((hidden (ecc-review-files--hidden-entries ecc-review--filter))
           (paths (mapcar (lambda (entry) (plist-get entry :path)) hidden)))
      (unless (equal paths ecc-review--hidden)
        (setq ecc-review-files--hidden-changed t))
      (setq ecc-review--hidden paths)
      (when (or hidden ecc-review-files--hiders)
        (ecc-review-files-hide hidden)))))

(defun ecc-review-files--settle ()
  "Step off what the filter has come to hide, and write the pane again.
After the comments are drawn, or once a review read again has its place
back (`ecc-review-refilled-hook'), never in between: the place a reading
again puts back is the one to look at."
  (when (ecc-review-buffer-p)
    (when ecc-review-files--hidden-changed
      (setq ecc-review-files--hidden-changed nil)
      (ecc-review-files-filter-applied t))
    (ecc-review-files--render)))

(defun ecc-review-files--after-draw ()
  "Settle this review once its comments are drawn, unless it is read again.
On `ecc-review-after-draw-hook': the files or their comments changed."
  (unless ecc-review--refilling
    (ecc-review-files--settle)))

(add-hook 'ecc-review-before-draw-hook #'ecc-review-files--before-draw)
(add-hook 'ecc-review-after-draw-hook #'ecc-review-files--after-draw)
(add-hook 'ecc-review-refilled-hook #'ecc-review-files--settle)

;;;; The pane

(defvar ecc-review-files-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-review-files-visit)
    (define-key map (kbd "n") #'ecc-review-files-next)
    (define-key map (kbd "p") #'ecc-review-files-previous)
    (define-key map (kbd "s") #'ecc-review-files-toggle)
    (define-key map (kbd "q") #'ecc-review-files-toggle)
    (define-key map (kbd "/") #'ecc-review-files-filter)
    (define-key map (kbd "g") #'ecc-review-files-rebuild)
    map)
  "Keymap of `ecc-review-files-mode'.")

(defvar ecc-review-files--line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'ecc-review-files-visit)
    (define-key map [mouse-2] #'ecc-review-files-visit)
    map)
  "Keymap on each file's line of the pane, for a click.")

(define-derived-mode ecc-review-files-mode special-mode "Claude-Review-Files"
  "Major mode of the list of the files of a review.

\\{ecc-review-files-mode-map}"
  :interactive nil
  (setq truncate-lines t)
  (buffer-disable-undo))

(defun ecc-review-files--review ()
  "Return the review this command is about, or signal that there is none."
  (let ((review (if (derived-mode-p 'ecc-review-files-mode) ecc-review-files--review
                  (current-buffer))))
    (unless (and (buffer-live-p review) (ecc-review-buffer-p review))
      (user-error (if (buffer-live-p review)
                      "This is not a review of files"
                    "The review of this list has gone")))
    review))

(defun ecc-review-files--pane-name (review)
  "Return the name of the files pane of REVIEW."
  (with-current-buffer review
    (let ((name (ecc-review-buffer-name ecc-review--session nil ecc-review--range
                                        ecc-review--label)))
      (format "*ecc-review-files: %s"
              (substring name (length "*ecc-review: "))))))

(defun ecc-review-files--pane-buffer (review)
  "Return the files pane of REVIEW, made when it has none."
  (with-current-buffer review
    (if (buffer-live-p ecc-review-files--pane)
        ecc-review-files--pane
      (let* ((name (ecc-review-files--pane-name review))
             (taken (get-buffer name))
             (pane (if (and taken (buffer-live-p (buffer-local-value
                                                  'ecc-review-files--review taken))
                            (not (eq (buffer-local-value 'ecc-review-files--review taken)
                                     review)))
                       (generate-new-buffer name)
                     (get-buffer-create name))))
        (with-current-buffer pane
          (ecc-review-files-mode)
          (setq ecc-review-files--review review))
        (add-hook 'kill-buffer-hook #'ecc-review-files--review-killed nil t)
        (setq ecc-review-files--pane pane)))))

(defun ecc-review-files--pane-window (review)
  "Return the window showing the files pane of REVIEW, or nil."
  (let ((pane (buffer-local-value 'ecc-review-files--pane review)))
    (and (buffer-live-p pane) (get-buffer-window pane t))))

(defun ecc-review-files--review-killed ()
  "Take the files pane of this review down with it."
  (let ((pane ecc-review-files--pane))
    (when (buffer-live-p pane)
      (dolist (window (get-buffer-window-list pane nil t))
        (ignore-errors (delete-window window)))
      (kill-buffer pane))))

(defun ecc-review-files--count-string (yours claude)
  "Return YOURS and CLAUDE's comments as the pane shows them, or \"\"."
  (if (zerop (+ yours claude))
      ""
    (concat (propertize (number-to-string yours) 'face 'ecc-review-comment-face)
            (propertize "·" 'face 'ecc-dim-face)
            (propertize (number-to-string claude) 'face 'ecc-review-agent-comment-face))))

(defun ecc-review-files--status-face (status)
  "Return the face the letter STATUS is drawn in."
  (pcase status
    ("A" 'diff-indicator-added)
    ("D" 'diff-indicator-removed)
    (_ 'diff-indicator-changed)))

(defun ecc-review-files--truncate-left (text width)
  "Return TEXT cut to WIDTH columns from the left, the end kept."
  (if (<= (string-width text) width)
      text
    (concat "…" (truncate-string-to-width
                 text (string-width text) (- (string-width text) (max 1 (1- width)))))))

(defun ecc-review-files--line (entry current width notes)
  "Return the line of the pane for ENTRY, marked when it is CURRENT.
WIDTH is the width of the pane and NOTES the comments of the review."
  (let* ((path (plist-get entry :path))
         (mine (seq-filter (lambda (note) (equal (ecc-review-note-path note) path)) notes))
         (claude (seq-count #'ecc-review--agent-p mine))
         (yours (- (length mine) claude))
         (outdated (seq-some #'ecc-review-note-outdated mine))
         (lines (concat (if (> (plist-get entry :added) 0)
                            (propertize (format "+%d" (plist-get entry :added))
                                        'face 'diff-indicator-added)
                          "")
                        (if (and (> (plist-get entry :added) 0)
                                 (> (plist-get entry :removed) 0))
                            " " "")
                        (if (> (plist-get entry :removed) 0)
                            (propertize (format "−%d" (plist-get entry :removed))
                                        'face 'diff-indicator-removed)
                          "")))
         (comments (concat (ecc-review-files--count-string yours claude)
                           (if outdated (propertize "!" 'face 'warning) "")))
         (right (string-join (seq-remove #'string-empty-p (list lines comments)) "  "))
         (name (if (plist-get entry :old-path)
                   (format "%s → %s" (plist-get entry :old-path) path)
                 path))
         (room (max 4 (- width 4 (string-width right) 2)))
         (line (concat (if current "▸ " "  ")
                       (propertize (plist-get entry :status)
                                   'face (ecc-review-files--status-face
                                          (plist-get entry :status)))
                       " "
                       (propertize (ecc-review-files--truncate-left name room)
                                   'face (and current 'ecc-review-files-current-face))
                       (propertize " " 'display `(space :align-to (- right ,(1+ (string-width right)))))
                       right
                       "\n")))
    (add-text-properties 0 (length line)
                         (list 'ecc-review-file path
                               'mouse-face 'highlight
                               'help-echo "RET or mouse-1: go to this file"
                               'keymap ecc-review-files--line-map)
                         line)
    line))

(defun ecc-review-files--render (&optional filter)
  "Write the files pane of this review afresh, when it is on the screen.
A pane out of sight is written when it is shown again.  FILTER, when
given, is what is being typed after \\`/' and lists the files it would
keep; otherwise the filter of the review does."
  (when (and (buffer-live-p ecc-review-files--pane)
             (get-buffer-window ecc-review-files--pane t))
    (let* ((filter (or filter ecc-review--filter))
           (entries (ecc-review-files--entries))
           (kept (seq-filter (lambda (entry)
                               (ecc-review-files--matches-p entry filter ecc-review--notes))
                             entries))
           (current (ecc-review-files-current))
           (notes ecc-review--notes)
           (window (ecc-review-files--pane-window (current-buffer)))
           (width (if window (window-body-width window) ecc-review-files-width)))
      (setq ecc-review-files--shown-path current)
      (with-current-buffer ecc-review-files--pane
        (let ((inhibit-read-only t)
              (line (line-number-at-pos))
              (point-path (get-text-property (point) 'ecc-review-file)))
          (erase-buffer)
          (insert (propertize (format " Files (%d of %d)" (length kept) (length entries))
                              'face 'ecc-heading-face)
                  (if (and filter (not (string-empty-p filter)))
                      (propertize (format "  /%s" filter) 'face 'ecc-dim-face)
                    "")
                  "\n")
          (dolist (entry kept)
            (insert (ecc-review-files--line entry (equal (plist-get entry :path) current)
                                            width notes)))
          (when (null entries)
            (insert (propertize "  No file to show\n" 'face 'ecc-dim-face)))
          (goto-char (point-min))
          (unless (and point-path (ecc-review-files--goto-line point-path))
            (forward-line (1- line)))
          (when window (set-window-point window (point))))))))

(defun ecc-review-files--goto-line (path)
  "Put point on the line of PATH in this pane; return non-nil when there is one."
  (let ((match (text-property-search-forward 'ecc-review-file path t)))
    (when match
      (goto-char (prop-match-beginning match))
      t)))

(defun ecc-review-files--follow ()
  "Mark again the file being read in the pane of this review, when it moved."
  (when (and (buffer-live-p ecc-review-files--pane)
             (get-buffer-window ecc-review-files--pane t)
             (not (equal (ecc-review-files-current) ecc-review-files--shown-path)))
    (ecc-review-files--render)))

(defun ecc-review-files--show (review)
  "Show the files pane of REVIEW left of it; return its window, or nil.
Nil when the review is on no window."
  (with-current-buffer review
    (or (ecc-review-files--pane-window review)
        (let ((pane (ecc-review-files--pane-buffer review)))
          (add-hook 'post-command-hook #'ecc-review-files--follow nil t)
          (add-hook 'ecc-review-moved-hook #'ecc-review-files--follow nil t)
          (prog1 (ecc-review-files-place-pane pane)
            (ecc-review-files--render))))))

(defun ecc-review-files--hide-pane (review)
  "Take the files pane of REVIEW off the screen."
  (when-let* ((window (ecc-review-files--pane-window review)))
    (when (eq (selected-window) window)
      (with-current-buffer review
        (ecc-review-files-give-keyboard)))
    (ignore-errors (delete-window window))))

(defun ecc-review-files--on-displayed (review)
  "Show the files pane of REVIEW now that it is on the screen, if it is wanted.
On `ecc-review-displayed-functions'."
  (when (and ecc-review-files-shown (ecc-review-buffer-p review))
    (unless (ecc-review-files--show review)
      (ecc-log "review" "no room for the files pane of %s" (buffer-name review)))))

(add-hook 'ecc-review-displayed-functions #'ecc-review-files--on-displayed)

;;;###autoload
(defun ecc-review-files-toggle ()
  "Show or hide the list of the files of this review.
The list sits immediately left of the review, and the choice holds for
every review opened afterwards, for as long as Emacs runs."
  (interactive)
  (let ((review (ecc-review-files--review)))
    (if (ecc-review-files--pane-window review)
        (progn (setq ecc-review-files-shown nil)
               (ecc-review-files--hide-pane review))
      (setq ecc-review-files-shown t)
      (unless (ecc-review-files--show review)
        (user-error "The review is not on the screen, or its window is too narrow for the list")))))

(defun ecc-review-files-rebuild ()
  "Write the list of the files again."
  (interactive)
  (with-current-buffer (ecc-review-files--review)
    (setq ecc-review-files--cache nil)
    (ecc-review-files--render)))

(defun ecc-review-files--entry (review path)
  "Return the file of REVIEW whose path is PATH."
  (with-current-buffer review
    (seq-find (lambda (entry) (equal (plist-get entry :path) path))
              (ecc-review-files--entries))))

(defun ecc-review-files--entry-at (&optional event)
  "Return (REVIEW . ENTRY) for the line of the pane at point, or at EVENT."
  (when event
    (posn-set-point (event-start event)))
  (let ((review (ecc-review-files--review))
        (path (get-text-property (point) 'ecc-review-file)))
    (cons review (or (and path (ecc-review-files--entry review path))
                     (user-error "No file on this line")))))

(defun ecc-review-files-visit (&optional event)
  "Go to the file on this line of the list, and to the review.
EVENT is the click, when it was one."
  (interactive (list (and (mouse-event-p last-nonmenu-event) last-nonmenu-event)))
  (pcase-let ((`(,review . ,entry) (ecc-review-files--entry-at event)))
    (with-current-buffer review
      (ecc-review-files-goto entry t))))

(defun ecc-review-files--step (count)
  "Move COUNT files down the list and show that file in the review.
The list keeps the keyboard."
  (let ((review (ecc-review-files--review)))
    (forward-line count)
    (when (and (< count 0) (not (get-text-property (point) 'ecc-review-file)))
      (forward-line 1))
    (if (not (get-text-property (point) 'ecc-review-file))
        (progn (forward-line -1)
               (user-error "No more files"))
      (let ((entry (cdr (ecc-review-files--entry-at)))
            (window (selected-window)))
        (with-current-buffer review
          (ecc-review-files-goto entry nil))
        (when (window-live-p window)
          (select-window window))))))

(defun ecc-review-files-next ()
  "Show the next file of the list in the review."
  (interactive)
  (ecc-review-files--step 1))

(defun ecc-review-files-previous ()
  "Show the previous file of the list in the review."
  (interactive)
  (ecc-review-files--step -1))

;;;; The filter, typed

(defvar ecc-review-files--typing nil
  "The review whose filter is being typed, while it is.")

(defun ecc-review-files--typed ()
  "List the files what is typed so far keeps, in the pane of the review.
On `after-change-functions' of the minibuffer \\`/' reads in."
  (when (buffer-live-p ecc-review-files--typing)
    (let ((text (minibuffer-contents-no-properties)))
      (with-current-buffer ecc-review-files--typing
        (ecc-review-files--render text)))))

(defun ecc-review-files-set-filter (review filter &optional note)
  "Keep only the files of REVIEW that FILTER matches; nil or \"\" keeps all.
The files left out are hidden and nothing is read again.  NOTE is added
to what the echo area says."
  (with-current-buffer review
    (setq ecc-review--filter (and filter (not (string-empty-p (string-trim filter)))
                                  (string-trim filter)))
    (ecc-review--draw-notes)
    (ecc-review-files-filter-applied)
    (force-mode-line-update)
    (let ((hidden (length ecc-review--hidden)))
      (message "%s%s"
               (if ecc-review--filter
                   (format "%s hidden by filter" (ecc-review--count hidden "file"))
                 "Every file is shown")
               (or note "")))))

;;;###autoload
(defun ecc-review-files-filter ()
  "Keep only the files whose path, former path or Claude's comments match.
The list of the files narrows as the filter is typed, and RET hides
the rest of the review; an empty filter shows every file again.  Case
is ignored.  Nothing is read again, and the comments of a hidden file
are kept and sent with the others."
  (interactive)
  (let* ((review (ecc-review-files--review))
         (shown (ecc-review-files--pane-window review))
         (placed nil)
         (done nil))
    (unwind-protect
        (let ((filter
               (minibuffer-with-setup-hook
                   (lambda ()
                     (add-hook 'after-change-functions
                               (lambda (&rest _) (ecc-review-files--typed)) nil t))
                 (let ((ecc-review-files--typing review))
                   (unless shown
                     (setq placed (ecc-review-files--show review)))
                   (read-from-minibuffer "Filter files (empty for all): "
                                         (buffer-local-value 'ecc-review--filter review))))))
          (setq done t)
          (unless shown
            (ecc-review-files--hide-pane review))
          (ecc-review-files-set-filter review filter
                                       (and (not shown) (not placed)
                                            "; no room for the list of files")))
      (unless done
        (unless shown
          (ecc-review-files--hide-pane review))
        (with-current-buffer review
          (ecc-review-files--render))))))

(provide 'ecc-review-files)

;;; ecc-review-files.el ends here
