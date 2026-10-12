;;; ecc-visit.el --- Opening the source a line of the transcript is about  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
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

;; RET on code in the transcript opens the file it is about, at the
;; line: a line of the diff of an Edit, a Write or a Bash command that
;; changed a file, the heading of a call that names a file, a line of the
;; Files section or of a permission request, and a path the model wrote
;; in its reply.
;;
;; A path the model wrote is the one of them that may not say where the
;; file is: a bare name, or a path written against a directory other
;; than the session's.  `ecc-visit-find-written' looks for it outward
;; from the session -- as written, among the files the session handled
;; and the ones Emacs visits, among the project's, and on the machine
;; when `ecc-visit-search-machine' lets it -- and stops at the first
;; place that has it.  Every other path is absolute already and is
;; opened as it is.
;;
;; A diff line carries nothing that says where it is from.  The Files
;; section is drawn again at every redraw of the live region, and a
;; property per line of every diff in it would be paid for every time,
;; so the line is read back when RET is pressed instead: the number
;; drawn at its start in the `numbered' style, or the lines counted from
;; the @@ header above it in the `unified' one.  The file is the one of
;; the node, the row or the request the line belongs to -- for a Bash
;; command, which names none, the one on the line over its diff.
;;
;; A click opens a path in a reply, which is drawn as a link with a
;; `mouse-face', and none of the rest: a diff line, a heading or a Bash
;; command's file line opens on RET alone, so that a click meant to put
;; the point there does not take the source window with it.  None of
;; them carries a `mouse-face' either, since a highlight under the
;; pointer says a click would do something.
;;
;; A number drawn in a diff is where the line stood once that change was
;; made.  Every change the session made to the file after it is in
;; `ecc-file-entry-patches', and the line is moved through those, so it
;; lands where the line is now.
;;
;; A video or a sound is not visited: a buffer of it would show its
;; bytes, so `ecc-visit-open' hands it to the machine's own player, the
;; way RET on a video drawn in the transcript does.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'pulse)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-diff)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-markdown)
(require 'ecc-window)
(require 'ecc-image)

(declare-function ecc-prompt-project-files "ecc-prompt" (session))

;;;; Reading a diff line back

(defun ecc-visit--line-tag ()
  "Return what the line at point is in a diff, or nil when it is not one.
The answer is `added', `removed', `context' or `header', read from the
`diff-mode' faces the line was drawn with; the text alone cannot say,
since in the `numbered' style a line starts with its number and a line
of the file may start with a + of its own."
  (let ((pos (line-beginning-position))
        (end (line-end-position))
        tag)
    (while (and (not tag) (< pos end))
      (let ((faces (ensure-list (get-text-property pos 'face))))
        (setq tag (cond ((memq 'diff-added faces) 'added)
                        ((memq 'diff-removed faces) 'removed)
                        ((memq 'diff-hunk-header faces) 'header)
                        ((memq 'diff-context faces) 'context))))
      (setq pos (next-single-property-change pos 'face nil end)))
    tag))

(defun ecc-visit--number ()
  "Return the number the `numbered' style drew at the start of this line."
  (save-excursion
    (beginning-of-line)
    (and (looking-at "[ \t]*\\([0-9]+\\) ")
         (string-to-number (match-string 1)))))

(defun ecc-visit--neighbour (step)
  "Return the number of the nearest line STEP away that is not removed.
The search stays in the hunk: it stops at the first line that is not a
line of the diff, which is what stands between two hunks."
  (save-excursion
    (let (found done)
      (while (and (not done) (zerop (forward-line step)))
        (pcase (ecc-visit--line-tag)
          ('removed nil)
          ((or 'added 'context) (setq found (ecc-visit--number) done t))
          (_ (setq done t))))
      found)))

(defun ecc-visit--numbered-line ()
  "Return the line in the file the `numbered' diff line at point stands for.
An added or a context line is numbered in the new file already.  A
removed line is numbered in the old one, and in the new file it stands
where it was taken out: after the line above it that is still there, or
else before the one below."
  (when-let* ((number (ecc-visit--number)))
    (if (eq (ecc-visit--line-tag) 'removed)
        (or (when-let* ((above (ecc-visit--neighbour -1))) (1+ above))
            (ecc-visit--neighbour 1)
            number)
      number)))

(defun ecc-visit--unified-line ()
  "Return the line in the file the `unified' diff line at point stands for.
It is counted from the new start of the @@ header above; nil when there
is no header, which is a diff of two strings with no file behind them."
  (save-excursion
    (let ((count 0) start done)
      (while (and (not (or start done)) (zerop (forward-line -1)))
        (pcase (ecc-visit--line-tag)
          ('header (let ((text (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position))))
                     (if (string-match "\\+\\([0-9]+\\)" text)
                         (setq start (string-to-number (match-string 1 text)))
                       (setq done t))))
          ((or 'added 'context) (cl-incf count))
          ('removed nil)
          (_ (setq done t))))
      (and start (max 1 (+ start count))))))

(defun ecc-visit--diff-line ()
  "Return the line of the file the diff line at point stands for, or nil.
The two styles are told apart by the text alone, never by
`ecc-diff-style\\=', which may have changed since the diff was drawn: only
the `unified\\=' one has an @@ header, and a line with none above it is
read as `numbered\\='."
  (pcase (ecc-visit--line-tag)
    ('nil nil)
    ('header (save-excursion
               (forward-line 1)
               (and (ecc-visit--line-tag) (ecc-visit--unified-line))))
    (_ (or (ecc-visit--unified-line)
           (ecc-visit--numbered-line)))))

;;;; Where the file stands now

(defun ecc-visit--usable-patch-p (patch)
  "Return non-nil when PATCH is a structuredPatch with hunks in it."
  (and (vectorp patch) (> (length patch) 0)))

(defun ecc-visit-shift-line (session path line patch)
  "Return LINE of PATH moved through the changes SESSION made after PATCH.
LINE is a line of the file as PATCH left it.  Each change recorded
after it in `ecc-file-entry-patches\\=' moves the lines below its hunks
by what those hunks added less what they removed; a line inside a hunk
is left where it is, which is the place the change was made.  LINE
comes back unchanged when PATCH is not one the session recorded for
PATH."
  (let* ((entry (and line (ecc-visit--usable-patch-p patch)
                     (gethash path (ecc-session-files session))))
         (later (and entry (cdr (memq patch (ecc-file-entry-patches entry))))))
    (dolist (next later line)
      (when (ecc-visit--usable-patch-p next)
        (setq line (ecc-visit-shift-through
                    line
                    (seq-keep (lambda (hunk)
                                (let ((old-start (alist-get 'oldStart hunk))
                                      (old-lines (alist-get 'oldLines hunk))
                                      (new-lines (alist-get 'newLines hunk)))
                                  (and (numberp old-start) (numberp old-lines)
                                       (numberp new-lines)
                                       (list old-start old-lines nil new-lines))))
                              next)))))))

(defun ecc-visit-shift-through (line hunks)
  "Return LINE moved through one change, made of HUNKS.
Each hunk is (OLD-START OLD-COUNT NEW-START NEW-COUNT ...), the shape of
`ecc-diff-hunks\\=', in the file before the change.  The hunks above LINE
move it by what they added less what they removed; a line inside a hunk
is left where it is, which is the place the change was made
\(`ecc-diff-shifter')."
  (max 1 (funcall (ecc-diff-shifter hunks) line t)))

(defun ecc-visit--first-change (patch)
  "Return the first line PATCH changed, in the file as it left it, or nil.
The hunk opens on lines of context; the change is what they stand
around."
  (when (ecc-visit--usable-patch-p patch)
    (let* ((hunk (aref patch 0))
           (start (alist-get 'newStart hunk))
           (lead (seq-take-while (lambda (line)
                                   (not (and (> (length line) 0)
                                             (memq (aref line 0) '(?+ ?-)))))
                                 (append (alist-get 'lines hunk) nil))))
      (and (numberp start) (max 1 (+ start (length lead)))))))

;;;; What point is on

(defun ecc-visit--node-input (node)
  "Return the input of the call NODE is about: its own, or its request\\='s."
  (pcase (ecc-node-type node)
    ('tool (ecc-model-node-get node 'input))
    ('permission (when-let* ((request (ecc-model-node-get node 'request)))
                   (ecc-request-input request)))))

(defun ecc-visit--notebook-p (input)
  "Return non-nil when INPUT names a notebook, whose lines are not the file\\='s."
  (and (consp input) (alist-get 'notebook_path input) t))

(defun ecc-visit--first-difference (before after)
  "Return the first line where AFTER differs from BEFORE, or nil.
A nil BEFORE is a file that was not there, or one not known; either way
the change starts at line 1.  The lines are split as the diff splits
them, without the empty one after a final newline, which would put a
blank line added at the end one line too far down."
  (if (null before)
      1
    (let ((old (ecc-diff--split before))
          (new (ecc-diff--split after))
          (line 1))
      (while (and old new (equal (car old) (car new)))
        (setq old (cdr old) new (cdr new) line (1+ line)))
      (and (or old new) line))))

(defun ecc-visit--edit-line (content edit)
  "Return the line of CONTENT the EDIT, an alist of an Edit\\='s strings, is at."
  (or (ecc-diff--line-of content (alist-get 'new_string edit))
      (ecc-diff--line-of content (alist-get 'old_string edit))))

(defun ecc-visit--heading-line (session node path)
  "Return the line the heading of the tool NODE of SESSION opens PATH at.
A Read opens where it started reading; a change opens at the first
line it changed, moved through what came after it.  A change the CLI
has not reported a patch for -- one still running, or a Write of a new
file, whose `structuredPatch\\=' is empty -- is worked out from the file
it changed: the file before it against the same file with the change
laid on.  An Edit or a MultiEdit with no file before it to lay the
change on is looked for in the file as it is, which cannot find an edit
that only deleted."
  (let* ((input (ecc-model-node-get node 'input))
         (patch (ecc-model-node-get node 'patch))
         (before (ecc-model-node-get node 'before))
         (edits (pcase (ecc-model-node-get node 'name)
                  ("Edit" (list input))
                  ("MultiEdit" (append (alist-get 'edits input) nil))))
         (offset (alist-get 'offset input)))
    (pcase (ecc-model-node-get node 'name)
      ((guard (ecc-visit--notebook-p input)) nil)
      ("Read" (and (numberp offset) (max 1 offset)))
      ((guard (ecc-visit--usable-patch-p patch))
       (ecc-visit-shift-line session path (ecc-visit--first-change patch) patch))
      ((guard (and edits before))
       (ecc-visit--first-difference before (ecc-diff-apply-edits before edits)))
      ((guard edits)
       (let* ((content (ecc-diff-file-content path))
              (lines (delq nil (mapcar (lambda (edit)
                                         (ecc-visit--edit-line content edit))
                                       edits))))
         (and lines (apply #'min lines))))
      ("Write"
       (let ((content (alist-get 'content input)))
         (and (stringp content)
              (ecc-visit--first-difference (ecc-model-node-get node 'before)
                                           content)))))))

(defun ecc-visit--files-patch (session path)
  "Return the patch the line at point in the Files row of PATH was drawn from.
PATH is a file of SESSION.
The body of the row is the diff of every change of the file, one after
another (`ecc-render--file-diff-parts\\='): counting the lines of each
says which one the point is in."
  (when-let* ((entry (gethash path (ecc-session-files session)))
              (bounds (ecc-render-node-bounds (concat "file:" path))))
    (let ((offset (save-excursion
                    (let ((here (line-beginning-position)))
                      (goto-char (car bounds))
                      (forward-line 1)
                      (count-lines (point) here))))
          (patches (ecc-file-entry-patches entry))
          found)
      (dolist (part (ecc-render--file-diff-parts entry))
        (unless found
          (let ((lines (cl-count ?\n part)))
            (if (< offset lines)
                (setq found (list (car patches)))
              (setq offset (- offset lines)))))
        (setq patches (cdr patches)))
      (car found))))

(defun ecc-visit--changed-file ()
  "Return (PATH . PATCH) of the file a Bash call changed that point is in.
A Bash call names no file of its own: the line over each file\\='s diff
carries it (`ecc-render--insert-bash-edit\\='), and the lines are walked
up to the nearest such line without leaving the node.  Nil when there
is none."
  (save-excursion
    (beginning-of-line)
    (let ((id (ecc-chat-node-id-at-point))
          found)
      (while (and id (not found))
        (setq found (get-text-property (point) 'ecc-changed-file))
        (unless (or found
                    (and (zerop (forward-line -1))
                         (equal (ecc-chat-node-id-at-point) id)))
          (setq id nil)))
      found)))

(defun ecc-visit-target-at-point ()
  "Return what RET at point opens, as (PATH . LINE), or nil.
LINE is nil when there is no line to go to.  Asked in order: a path
the model wrote, a line of a diff, and the heading of a call that
names a file.  PATH is absolute but for the model\\='s own, which is
taken against `default-directory\\=', the directory of the session, as
written: RET looks further for one that is not there
\(`ecc-visit-open-written\\=')."
  (let* ((session ecc-render--session)
         (written (ecc-markdown-file-at-point))
         (row (ecc-chat-file-at-point))
         (node (and (not row) (ecc-chat-node-at-point)))
         (input (and node (ecc-visit--node-input node)))
         (changed (and node (eq (ecc-node-type node) 'tool)
                       (not (ecc-tool-input-path input))
                       (ecc-visit--changed-file)))
         (path (or row (ecc-tool-input-path input) (car changed)))
         (heading (and (ecc-chat-heading-at-point)
                       (equal (ecc-chat-heading-at-point)
                              (ecc-chat-node-id-at-point)))))
    (cond
     (written (cons (expand-file-name (car written)) (cdr written)))
     ((null path) nil)
     ((and heading row) (list path))
     (heading (and (eq (ecc-node-type node) 'tool)
                   (cons path (and session
                                   (ecc-visit--heading-line session node path)))))
     ;; The line that names a file a Bash call changed opens it where
     ;; the change starts, as the heading of an Edit does.
     ((and changed (get-text-property (line-beginning-position) 'ecc-changed-file))
      (cons path (and session
                      (ecc-visit-shift-line session path
                                            (ecc-visit--first-change (cdr changed))
                                            (cdr changed)))))
     ((ecc-visit--line-tag)
      (let ((line (and (not (ecc-visit--notebook-p input))
                       (ecc-visit--diff-line))))
        (cons path
              (cond
               ((or (null line) (null session)) line)
               (row (ecc-visit-shift-line session path line
                                          (ecc-visit--files-patch session path)))
               ((eq (ecc-node-type node) 'tool)
                (ecc-visit-shift-line session path line
                                      (if changed
                                          (cdr changed)
                                        (ecc-model-node-get node 'patch))))
               (t line))))))))

;;;; Opening

(defun ecc-visit-open (path &optional line session where)
  "Open PATH beside SESSION at LINE, and return its window.
A video or a sound is played by the machine instead
\(`ecc-image-open-externally\\='), LINE is ignored and nil is returned:
a buffer of one would show its bytes.
The window is chosen as every buffer opened out of a conversation is
\(`ecc-window-display-beside-session\\=') -- or by WHERE, a function
called with the buffer that shows it and returns the window, for a
caller with somewhere else to put it.  With LINE the point goes to it,
the window is scrolled to put it in the middle and the line flashes;
without it the buffer keeps the point it had."
  (unless (file-exists-p path)
    (user-error "No such file: %s" (abbreviate-file-name path)))
  (if (ecc-image-plays-outside-p path)
      (progn (ecc-image-open-externally path) nil)
    (ecc-visit--open-in-buffer path line session where)))

(defun ecc-visit--open-in-buffer (path line session &optional where)
  "Visit PATH beside SESSION at LINE, or where WHERE puts it; return its window."
  (let* ((buffer (find-file-noselect path))
         (window (cond (where (funcall where buffer))
                       (session (ecc-window-display-beside-session buffer session))
                       (t (pop-to-buffer buffer)
                          (get-buffer-window buffer)))))
    (when (and line (window-live-p window))
      (ecc-visit-show-line window line))
    window))

(defun ecc-visit-show-line (window line)
  "Put the point of WINDOW on LINE, in the middle of it, and flash the line."
  (with-selected-window window
    (goto-char (point-min))
    (forward-line (1- line))
    (recenter)
    (pulse-momentary-highlight-one-line (point))))

;;;; Finding a path the model wrote

(defcustom ecc-visit-search-machine 'ask
  "Whether a file the model named is looked for on the whole machine.
It is asked only of a name found nowhere nearer: not as written, not
among the files the session handled or Emacs visits, and not among the
project\\='s files.  `ask' asks every time, `always' searches without
asking and `never' does not search.

The search goes through Spotlight on macOS and the locate database
elsewhere, which take a while and see every file of the user, not
only the project\\='s: whether that is worth it is a judgement about
cost and privacy, which is why it is a setting."
  :type '(choice (const :tag "Ask each time" ask)
                 (const :tag "Search without asking" always)
                 (const :tag "Never search" never))
  :group 'ecc)

(defvar ecc-visit-machine-search-function #'ecc-visit-machine-search
  "Function that returns the files of this machine called NAME.
It is called with a bare file name and returns absolute paths.  What
it returns is filtered again by the name as the model wrote it, so it
may return more than the files called NAME exactly.")

(defvar ecc-visit-machine-search-limit 300
  "How many of the machine\\='s files named like a path are offered at most.")

(defvar ecc-visit--chosen (make-hash-table :test #'eq :weakness 'key)
  "Session -> hash of what a path the model wrote was found to be.
The inner table maps the path as written to the file it was found as,
so that the same path opens at once the second time.  It lives here
and not in the session: it is a convenience of RET and nothing else.")

(defun ecc-visit-machine-search (name)
  "Return the files of this machine whose name contains NAME.
Spotlight is asked on macOS, the locate database elsewhere.  It is run
with `call-process\\=', so \\[keyboard-quit] stops it."
  (let ((command (if (eq system-type 'darwin)
                     (list "mdfind" "-name" name)
                   (list "locate" "--" name))))
    (unless (executable-find (car command))
      (user-error "Cannot search this machine: no %s" (car command)))
    (with-temp-buffer
      ;; mdfind writes two lines of locale logging to stderr on every
      ;; call and exits 0 whether it found anything or not, so only
      ;; stdout is read and the status is not.  It matches any part of
      ;; the name, in any case, and it does not see into a directory
      ;; whose name starts with a dot, such as .claude/worktrees/
      ;; (confirmed with macOS 26 on 2026-10-12).
      (apply #'call-process (car command) nil (list t nil) nil (cdr command))
      (split-string (buffer-string) "\n" t))))

(defun ecc-visit--written-suffix (token)
  "Return TOKEN as a suffix to look for, or nil when it is a full path.
A path that starts at the root or the home directory names one file
and no other.  The ./ and ../ at the start of a relative one are what
it was written against, and are dropped."
  (unless (or (file-name-absolute-p token) (string-prefix-p "~" token))
    (let ((suffix token))
      (while (string-match "\\`\\.\\.?/+" suffix)
        (setq suffix (substring suffix (match-end 0))))
      (and (not (string-empty-p suffix)) suffix))))

(defun ecc-visit--suffix-p (suffix path)
  "Return non-nil when PATH ends in SUFFIX on a directory boundary.
foo.el is the end of a/foo.el and not of a/barfoo.el."
  (string-suffix-p (concat "/" suffix) path))

(defun ecc-visit--matching (suffix paths)
  "Return the PATHS that end in SUFFIX and are there, each once.
A remote one is left out: asking whether it is there would open the
connection, and a buffer of one is all that could have named it."
  (seq-uniq (seq-filter (lambda (path)
                          (and (ecc-visit--suffix-p suffix path)
                               (not (file-remote-p path))
                               (file-exists-p path)))
                        paths)))

(defun ecc-visit--handled-files (session)
  "Return the files SESSION read, edited or wrote, as absolute paths."
  (and session
       (mapcar (lambda (entry) (expand-file-name (ecc-file-entry-path entry)))
               (ecc-model-files session))))

(defun ecc-visit--project-root (session)
  "Return the project root of SESSION as a directory name, or nil."
  (when-let* ((root (and session (ecc-session-project-root session))))
    (file-name-as-directory (expand-file-name root))))

(defun ecc-visit--project-files (session root)
  "Return the files of the project of SESSION, absolute under ROOT.
They are the list @ completion offers (`ecc-prompt-project-files\\=').
That file requires `ecc-session\\=', which requires this one, so it is
loaded when it is asked and not at the top: by the time RET is pressed
on a transcript, the prompt is there already."
  (require 'ecc-prompt)
  (mapcar (lambda (file) (expand-file-name file root))
          (ecc-prompt-project-files session)))

(defun ecc-visit--steps (from to)
  "Return how many directories there are to walk from FROM to TO."
  (let ((a (split-string (expand-file-name from) "/" t))
        (b (split-string (expand-file-name to) "/" t)))
    (while (and a b (equal (car a) (car b)))
      (setq a (cdr a) b (cdr b)))
    (+ (length a) (length b))))

(defun ecc-visit--display-name (path root)
  "Return PATH as it is shown: relative to ROOT inside it, abbreviated outside."
  (if (and root (string-prefix-p root path))
      (file-relative-name path root)
    (abbreviate-file-name path)))

(defun ecc-visit--sort (paths handled directory root)
  "Return PATHS in the order they are offered.
The files of the session (HANDLED) first, then those nearest to
DIRECTORY, then the shortest as shown against ROOT."
  (let ((key (lambda (path)
               (list (if (member path handled) 0 1)
                     (ecc-visit--steps directory (file-name-directory path))
                     (length (ecc-visit--display-name path root))))))
    (sort (copy-sequence paths)
          (lambda (a b)
            (let ((ka (funcall key a)) (kb (funcall key b)) result)
              (while (and ka (not result))
                (cond ((< (car ka) (car kb)) (setq result 'less))
                      ((> (car ka) (car kb)) (setq result 'more)))
                (setq ka (cdr ka) kb (cdr kb)))
              (eq result 'less))))))

(defun ecc-visit--choose (token paths root)
  "Return the one of PATHS the user picks as the file TOKEN names.
They are offered in the order given, shown against ROOT."
  (let* ((names (mapcar (lambda (path)
                          (cons (ecc-visit--display-name path root) path))
                        paths))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (category . file)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action (mapcar #'car names)
                                          string predicate)))))
    (cdr (assoc (completing-read (format "Open %s: " token) table nil t)
                names))))

(defun ecc-visit--search-machine-p ()
  "Return non-nil when the machine is to be searched, asking if need be."
  (pcase ecc-visit-search-machine
    ('always t)
    ('never nil)
    (_ (y-or-n-p "Not in the project; search this machine? "))))

(defun ecc-visit-find-written (session token &optional directory)
  "Return the file TOKEN, a path the model wrote in SESSION, names.
The answer is (PATH . WHERE), WHERE saying how it was found; an error
says where it was looked for when it was not.  DIRECTORY is the one
the session works in, `default-directory\\=' by default.

The places are tried in order, and the first that has it ends the
search:
- TOKEN as written, against DIRECTORY and then the project root;
- what was picked for TOKEN before in this session, while it is there;
- the files the session read or changed and those Emacs visits;
- the files of the project;
- the files of this machine, when `ecc-visit-search-machine\\=' allows.
After the first, a file matches when TOKEN is the end of its path on a
directory boundary: foo.el is a/foo.el and not a/barfoo.el, and
test/foo.el is a/test/foo.el.  A path that starts at the root or the
home directory is only taken as written.  Several matches are offered
with `completing-read\\=', and the pick is remembered."
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (root (ecc-visit--project-root session))
         (suffix (ecc-visit--written-suffix token))
         (chosen (and session (gethash session ecc-visit--chosen)))
         (remembered (and chosen (gethash token chosen)))
         (looked (list "the session's directory"))
         found where handled)
    (cond
     ((file-exists-p (expand-file-name token directory))
      (setq found (list (expand-file-name token directory))))
     ((and root (progn (push "the project root" looked)
                       (file-exists-p (expand-file-name token root))))
      (setq found (list (expand-file-name token root)) where 'root))
     ((null suffix))
     ((and remembered (file-exists-p remembered))
      (setq found (list remembered) where 'remembered))
     ((progn (setq handled (ecc-visit--handled-files session))
             (push "the files of this session and of Emacs" looked)
             (setq found (ecc-visit--matching
                          suffix
                          (append handled
                                  (delq nil (mapcar #'buffer-file-name
                                                    (buffer-list)))))))
      (setq where 'session))
     ((and root (progn (push "the project's files" looked)
                       (setq found (ecc-visit--matching
                                    suffix (ecc-visit--project-files session root)))))
      (setq where 'project))
     ((ecc-visit--search-machine-p)
      (push "this machine" looked)
      (setq found (seq-take (ecc-visit--matching
                             suffix (funcall ecc-visit-machine-search-function
                                             (file-name-nondirectory suffix)))
                            ecc-visit-machine-search-limit)
            where 'machine)))
    (unless found
      (user-error "No such file: %s (looked in %s)" token
                  (string-join (reverse looked) ", ")))
    (let ((path (if (cdr found)
                    (ecc-visit--choose token
                                       (ecc-visit--sort found handled directory root)
                                       root)
                  (car found))))
      (when (and session (memq where '(session project machine)))
        (unless chosen
          (setq chosen (puthash session (make-hash-table :test #'equal)
                                ecc-visit--chosen)))
        (puthash token path chosen))
      (cons path (if (and (eq where 'session) (not (member path handled)))
                     'buffer
                   where)))))

(defun ecc-visit-open-written (session written)
  "Open the file of WRITTEN, a path the model wrote, beside SESSION.
WRITTEN is (TOKEN . LINE) as the link carries it
\(`ecc-markdown-file-at-point\\='); the file is found by
`ecc-visit-find-written\\=', and opened at LINE wherever it was found.
The echo area says where, unless it was where the path said."
  (pcase-let* ((`(,path . ,where) (ecc-visit-find-written session (car written)))
               (window (ecc-visit-open path (cdr written) session)))
    (when where
      (message "Opened %s (%s)"
               (ecc-visit--display-name path (ecc-visit--project-root session))
               (pcase where
                 ('root "against the project root")
                 ('remembered "as picked before")
                 ('session "a file of this session")
                 ('buffer "a file Emacs visits")
                 ('project "in the project")
                 ('machine "on this machine"))))
    window))

(provide 'ecc-visit)

;;; ecc-visit.el ends here
