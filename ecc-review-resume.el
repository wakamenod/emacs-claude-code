;;; ecc-review-resume.el --- Taking a review up again where it was left  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5-5
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

;; A review is a buffer, and its comments live in it: closing the review
;; half-way, or Emacs, lost whatever had been written and not sent.  This
;; keeps the last review of each session and scope in a file of its own,
;; `ecc-review-resume-file', and `ecc-review-resume' opens it again: the
;; same session, what it compared and how it was shown, the comments not
;; sent yet and the place being read.  Nothing is asked or reopened when
;; a review is opened the ordinary way.
;;
;; A review is saved as it closes (`ecc-review-closing-functions'), as
;; Emacs exits, and once Emacs is idle after its comments were drawn --
;; every change to them ends in a drawing -- so that a crash loses only
;; what changed in the last second.  Each comment is saved as the review
;; keeps it, an `ecc-review-note' on the shape of the reading it is on
;; (`ecc-review-map-shape-data'), and so is the place being read, as a
;; note of no author on its line.  The review opened again carries all
;; of them from there to its first reading as a refresh carries them
;; (`ecc-review--receive'): a comment whose line changed meanwhile comes
;; back outdated, and the place goes to the nearest line that stayed.
;; Sent comments are not saved, the conversation having them; Claude's
;; are, as the review showed them.
;;
;; One review is kept per session and scope -- what it compares and the
;; files it was kept to (`ecc-review-resume--scope-key') -- the one saved
;; last, with one rule against losing what was written: a review opened
;; afresh does not replace a saved one of its scope that has comments
;; not sent until it has some of its own (`ecc-review-resume--put').  A
;; review resumed is the saved one carrying on (`ecc-review-resume--key'),
;; and keeps it up to date.
;;
;; `ecc-review-quit', C-c C-k, drops a review and what was saved of it,
;; asking first when it has comments not sent; nothing of it is saved
;; after that, by the closing, by a save waiting for an idle moment or
;; at exit.  Every other way a review ends saves it.
;;
;; The review of what a session changed since it started compares the
;; working tree with its baseline, a git tree nothing names.  Its id is
;; saved and no ref is made, so `git gc' deletes the tree two weeks on;
;; a review whose tree is gone is not resumed against another, and says
;; why.  A saved review older than that, or one whose project is gone, is
;; dropped at the next write.
;;
;; The layout of the file is versioned (`ecc-review-resume--version'):
;; a plist whose `:reviews' are keyed by session and scope.  `:walks' is kept
;; for the pull requests read a commit at a time (`ecc-review-pr.el'),
;; one per (ROOT . NUMBER) with the comments it holds by range; this
;; version writes none, and does not save a review that is part of one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-review-map)
(require 'ecc-review)

(declare-function ecc-review-ediff-buffer "ecc-review-ediff" (session &optional paths))
(declare-function ecc-review-ediff-range-buffer "ecc-review-ediff"
                  (session &optional range root paths))
(declare-function ecc-review-files-set-filter "ecc-review-files" (review filter &optional note))

(defvar ecc-review-resume-file (expand-file-name "ecc-reviews.eld" user-emacs-directory)
  "File the last review of each session and scope is saved in, as Lisp data.
A variable rather than a setting, as `ecc-restore-file' is: where a
package keeps its state is not a taste, and `user-emacs-directory' is
where Emacs keeps the rest.")

(defvar ecc-review-resume-enabled (not noninteractive)
  "Non-nil saves the reviews as they close, change and as Emacs exits.
A batch Emacs saves nothing: a script or a test that opens reviews must
not write over what the user's own Emacs left.")

(defvar ecc-review-resume-max-age (* 14 24 60 60)
  "Seconds a saved review is kept after it was last saved.
Two weeks, git's default `gc.pruneExpire': by then the tree a review of
what a session changed compares with is gone (`ecc-review-tree-exists-p').")

(defvar ecc-review-resume-delay 1
  "Seconds of idle time after the comments of a review changed before it is saved.
Saving while somebody types would hold up the typing.")

(defconst ecc-review-resume--version 1
  "Version of the layout of `ecc-review-resume-file'.")

(defvar-local ecc-review-resume--key nil
  "Which saved review this review is, or nil before it is first saved.
A review resumed takes the key of the one it was saved as.")

(defvar-local ecc-review-resume--dropped nil
  "Non-nil once \\[ecc-review-quit] is dropping this review.
Nothing of it is saved from then on (`ecc-review-resume--saved-p').")

(defvar ecc-review-resume--pending nil
  "The reviews whose comments were drawn since they were last saved.")

(defvar ecc-review-resume--timer nil
  "The idle timer that saves `ecc-review-resume--pending', or nil.")

;;;; What is saved

(defun ecc-review-resume--saved-p (review)
  "Return non-nil when REVIEW is a review to save.
A review of files, not of one proposal, not one of a pull request read
a commit at a time, whose comments its walk holds, and not one being
dropped."
  (and (buffer-live-p review)
       (with-current-buffer review
         (and (ecc-review-buffer-p)
              (null ecc-review--walk)
              (null ecc-review-resume--dropped)))))

(defun ecc-review-resume--scope-key (session range paths directory)
  "Return what tells one saved review from another: (SESSION RANGE PATHS).
SESSION is the id of the session, RANGE what the review compares
\(`ecc-review--range'), and PATHS the files it was kept to, made
relative to DIRECTORY and sorted, so that the same files are one scope
whatever order or form they were given in."
  (list session range
        (sort (mapcar (lambda (path)
                        (file-relative-name (expand-file-name path directory) directory))
                      paths)
              #'string<)))

(defun ecc-review-resume--entry-key (entry)
  "Return the scope key of the saved review ENTRY."
  (ecc-review-resume--scope-key (plist-get entry :session) (plist-get entry :range)
                                (plist-get entry :paths) (plist-get entry :directory)))

(defun ecc-review-resume--review-key (review)
  "Return the scope key of the open review REVIEW."
  (with-current-buffer review
    (ecc-review-resume--scope-key (ecc-session-id ecc-review--session) ecc-review--range
                                  ecc-review--paths default-directory)))

(defun ecc-review-resume--plain (object)
  "Return OBJECT without text properties when it is a string."
  (if (stringp object) (substring-no-properties object) object))

(defun ecc-review-resume--note-data (note index)
  "Return NOTE as it is saved.
INDEX is a function giving the number of a shape among those saved."
  (list :id (ecc-review-note-id note)
        :author (ecc-review-note-author note)
        :path (ecc-review-note-path note)
        :side (ecc-review-note-side note)
        :line (ecc-review-note-line note)
        :line-text (ecc-review-resume--plain (ecc-review-note-line-text note))
        :nth (ecc-review-note-nth note)
        :hunk-key (let ((key (ecc-review-note-hunk-key note)))
                    (and key (cons (ecc-review-resume--plain (car key))
                                   (ecc-review-resume--plain (cdr key)))))
        :hunk-range (ecc-review-note-hunk-range note)
        :hunk-text (ecc-review-resume--plain (ecc-review-note-hunk-text note))
        :text (ecc-review-resume--plain (ecc-review-note-text note))
        :reply-to (ecc-review-note-reply-to note)
        :outdated (ecc-review-note-outdated note)
        :shape (funcall index (ecc-review-note-shape note))))

(defun ecc-review-resume--note (data shapes)
  "Return the comment DATA was saved from, on one of SHAPES."
  (ecc-review-note-create
   :id (plist-get data :id)
   :author (plist-get data :author)
   :path (plist-get data :path)
   :side (plist-get data :side)
   :line (plist-get data :line)
   :line-text (plist-get data :line-text)
   :nth (plist-get data :nth)
   :hunk-key (plist-get data :hunk-key)
   :hunk-range (plist-get data :hunk-range)
   :hunk-text (plist-get data :hunk-text)
   :text (plist-get data :text)
   :reply-to (plist-get data :reply-to)
   :outdated (plist-get data :outdated)
   :shape (and (plist-get data :shape) (nth (plist-get data :shape) shapes))))

(defun ecc-review-resume--unit-near (place)
  "Return the hunk of this review nearest PLACE, which is in none.
PLACE is `ecc-review-place-at-point's: a file header of the diff, or a
line both sides of an ediff review share.  The last hunk of its file
that starts on or above its line, else the first of its file."
  (let* ((path (plist-get place :path))
         (line (plist-get place :line))
         (start (if (eq (plist-get place :side) 'old) :old-start :start))
         (units (seq-filter (lambda (unit) (equal (plist-get unit :path) path))
                            (ecc-review-units))))
    (or (and line
             (car (last (seq-filter (lambda (unit)
                                      (<= (or (plist-get unit start) 0) line))
                                    units))))
        (car units))))

(defun ecc-review-resume--line-read ()
  "Return the line of this review being read, or nil.
A line as `ecc-review-lines' has it:
the line at point in the window the review is shown in, or the hunk it
is nearest when it is on no line of one."
  (let ((window (ecc-review-shown-window)))
    (save-excursion
      ;; The point of a diff review is its window's; an ediff review
      ;; reads the windows of its two sides itself.
      (when (and window (eq (window-buffer window) (current-buffer)))
        (goto-char (window-point window)))
      (when-let* ((place (ecc-review-place-at-point))
                  (hunk (or (plist-get place :hunk) (ecc-review-resume--unit-near place)))
                  (lines (ecc-review--unit-lines hunk)))
        (or (and (plist-get place :side)
                 (seq-find (lambda (line)
                             (and (eq (plist-get line :side) (plist-get place :side))
                                  (eql (plist-get line :line) (plist-get place :line))))
                           lines))
            (car lines))))))

(defun ecc-review-resume--place ()
  "Return the place this review is being read, put on its line, or nil.
A note of no author, shaped as a comment is, for the review opened again
to carry.  Nil when the review is being read again: its text is not the
reading any place could be put on."
  (when (or (null ecc-review--reading) (ecc-review--reading-current-p))
    (when-let* ((line (ecc-review-resume--line-read)))
      (ecc-review--anchor (ecc-review-note-create) line))))

(defun ecc-review-resume--new-key ()
  "Return a key no saved review has."
  (format "%x-%x" (floor (* 1000 (float-time))) (random most-positive-fixnum)))

(defun ecc-review-resume-entry (review &optional previous)
  "Return REVIEW as it is saved.
PREVIOUS is the entry saved for its session, whose place is kept when
none can be read now."
  (with-current-buffer review
    (let* ((session ecc-review--session)
           (shapes nil)
           (index (lambda (shape)
                    (when shape
                      (or (seq-position shapes shape #'eq)
                          (progn (setq shapes (append shapes (list shape)))
                                 (1- (length shapes)))))))
           (key (or ecc-review-resume--key
                    (setq ecc-review-resume--key (ecc-review-resume--new-key))))
           (notes (mapcar (lambda (note) (ecc-review-resume--note-data note index))
                          (seq-remove #'ecc-review-note-sent ecc-review--notes)))
           (place (ecc-review-resume--place)))
      (list :session (ecc-session-id session)
            :name (ecc-session-name session)
            :root (ecc-session-project-root session)
            :directory default-directory
            :style (if (derived-mode-p 'ediff-mode) 'ediff 'diff)
            :range ecc-review--range
            :label (ecc-review-resume--plain ecc-review--label)
            :paths ecc-review--paths
            :baseline (and (null ecc-review--range) (ecc-session-baseline session))
            :key key
            :time (float-time)
            :place (cond (place (ecc-review-resume--note-data place index))
                         ((equal (plist-get previous :key) key)
                          (plist-get previous :place)))
            :notes notes
            :shapes (mapcar #'ecc-review-map-shape-data shapes)
            :next-id ecc-review--next-id
            :show-agent ecc-review--show-agent
            :filter ecc-review--filter))))

(defun ecc-review-resume--unsent (entry)
  "Return how many of your comments ENTRY saved, every one of them unsent."
  (seq-count (lambda (note) (eq (plist-get note :author) 'user))
             (plist-get entry :notes)))

(defun ecc-review-resume--same-p (a b)
  "Return non-nil when the entries A and B differ in nothing but their time."
  (equal (plist-put (copy-sequence a) :time nil)
         (plist-put (copy-sequence b) :time nil)))

(defun ecc-review-resume--put (entries entry)
  "Return ENTRIES with ENTRY as the review saved for its scope, first.
The scope is the session and what the review compares
\(`ecc-review-resume--scope-key'): the reviews of one session that
compare other things are each kept.  A review opened afresh -- another
key -- with none of your comments leaves a saved review of its scope
that has some where it is: opening a review the ordinary way, before
resuming the one with comments, would otherwise throw those comments
away.  An entry that differs from the one saved in nothing but its time
changes nothing."
  (let* ((scope (ecc-review-resume--entry-key entry))
         (old (seq-find (lambda (other) (equal (ecc-review-resume--entry-key other) scope))
                        entries)))
    (cond ((and old (ecc-review-resume--same-p old entry)) entries)
          ((and old
                (not (equal (plist-get old :key) (plist-get entry :key)))
                (> (ecc-review-resume--unsent old) 0)
                (zerop (ecc-review-resume--unsent entry)))
           entries)
          (t (cons entry (remq old entries))))))

(defun ecc-review-resume--prune (entries)
  "Return ENTRIES without those that cannot be resumed any more.
One saved longer ago than `ecc-review-resume-max-age', and one whose
project directory is gone."
  (let ((oldest (- (float-time) ecc-review-resume-max-age)))
    (seq-filter (lambda (entry)
                  (let ((time (plist-get entry :time))
                        (root (plist-get entry :root)))
                    (and (numberp time) (> time oldest)
                         (stringp root) (file-directory-p root))))
                entries)))

;;;; Reading and writing the file

(defun ecc-review-resume--read ()
  "Return what `ecc-review-resume-file' holds, or nil when nothing is saved.
A file that cannot be read, or of a layout this version does not read,
is an error, and nothing is written over it."
  (let ((file ecc-review-resume-file))
    (when (file-readable-p file)
      (let ((state (with-temp-buffer
                     (insert-file-contents file)
                     (unless (string-blank-p (buffer-string))
                       (condition-case error
                           (read (current-buffer))
                         (error (error "Cannot read %s: %s" (abbreviate-file-name file)
                                       (error-message-string error))))))))
        (unless (or (null state)
                    (and (listp state)
                         (eql (plist-get state :version) ecc-review-resume--version)))
          (error "%s is not a layout this version of ecc reads"
                 (abbreviate-file-name file)))
        state))))

(defun ecc-review-resume--write (state entries)
  "Write ENTRIES as the saved reviews, keeping the rest of STATE.
Nothing is written when they are what STATE has already.  The text goes
to a file beside it first and is renamed over it, so a crash in the
middle leaves the old one.  Return non-nil when it wrote."
  (unless (and state (equal entries (plist-get state :reviews)))
    (let* ((state (plist-put (plist-put (copy-sequence state) :version ecc-review-resume--version)
                             :reviews entries))
           (text (let ((print-length nil)
                       (print-level nil)
                       (print-circle nil)
                       (print-escape-newlines t))
                   (concat ";; -*- mode: lisp-data -*-\n"
                           ";; The last review of each session and scope; `ecc-review-resume' reads this.\n"
                           (prin1-to-string state) "\n")))
           (file (expand-file-name ecc-review-resume-file))
           (temp (concat file ".tmp"))
           (coding-system-for-write 'utf-8-unix))
      (make-directory (file-name-directory file) t)
      (write-region text nil temp nil 'silent)
      (rename-file temp file t)
      t)))

(defun ecc-review-resume-save (review)
  "Save REVIEW as the last review of its session and scope.
Return non-nil when the file was written.  Nothing is saved while
`ecc-review-resume-enabled' is nil, nor for a review that is not one to
save (`ecc-review-resume--saved-p')."
  (when (and ecc-review-resume-enabled (ecc-review-resume--saved-p review))
    (ecc-review-resume--watch)
    (setq ecc-review-resume--pending (delq review ecc-review-resume--pending))
    (let* ((state (ecc-review-resume--read))
           (entries (plist-get state :reviews))
           (scope (ecc-review-resume--review-key review))
           (previous (seq-find (lambda (entry)
                                 (equal (ecc-review-resume--entry-key entry) scope))
                               entries)))
      (ecc-review-resume--write
       state (ecc-review-resume--prune
              (ecc-review-resume--put entries (ecc-review-resume-entry review previous)))))))

(defun ecc-review-resume--save-safely (review)
  "Save REVIEW, saying so when that fails rather than failing what called it.
A review is saved as it closes and as Emacs exits, and neither may stop
because the file could not be written.  The error goes to the log and
the echo area."
  (condition-case error
      (ecc-review-resume-save review)
    (error
     (ecc-log "review" "saving %s for ecc-review-resume failed: %S"
              (if (buffer-live-p review) (buffer-name review) review) error)
     (message "ecc: %s was not saved to be resumed: %s"
              (if (buffer-live-p review) (buffer-name review) "a review")
              (error-message-string error))
     nil)))

;;;; When it is saved

(defun ecc-review-resume--watch ()
  "Save the open reviews when Emacs exits, from the first review on.
Not when this file is loaded: an Emacs that never opens a review has
nothing to save at its exit."
  (add-hook 'kill-emacs-hook #'ecc-review-resume--save-at-exit))

(defun ecc-review-resume--on-draw ()
  "Save this review once Emacs is idle: its comments were just drawn.
On `ecc-review-after-draw-hook'.  A drawing that changed nothing saved
writes nothing (`ecc-review-resume--put')."
  (when (and ecc-review-resume-enabled (ecc-review-resume--saved-p (current-buffer)))
    (ecc-review-resume--watch)
    (cl-pushnew (current-buffer) ecc-review-resume--pending)
    (unless (timerp ecc-review-resume--timer)
      (setq ecc-review-resume--timer
            (run-with-idle-timer ecc-review-resume-delay nil
                                 #'ecc-review-resume--save-pending)))))

(defun ecc-review-resume--save-pending ()
  "Save the reviews whose comments were drawn since they were last saved."
  (setq ecc-review-resume--timer nil)
  (let ((reviews (reverse ecc-review-resume--pending)))
    (setq ecc-review-resume--pending nil)
    (dolist (review reviews)
      (when (buffer-live-p review)
        (ecc-review-resume--save-safely review)))))

(defun ecc-review-resume--on-closing (review)
  "Save REVIEW as it closes.  On `ecc-review-closing-functions'."
  (when (ecc-review-resume--saved-p review)
    (ecc-review-resume--save-safely review)))

(defun ecc-review-resume--on-dropping (review)
  "Forget what was saved of REVIEW, which \\[ecc-review-quit] is dropping.
On `ecc-review-dropping-functions'.  The saved review that is REVIEW's
own -- the one it saved, or was resumed from -- goes, and another of its
scope it did not replace stays.  Nothing of REVIEW is saved from here
on: not as it closes, not by an idle save waiting for it, not at exit.
A file that cannot be written is said so, and the review is dropped
all the same."
  (with-current-buffer review
    (setq ecc-review-resume--dropped t))
  (setq ecc-review-resume--pending (delq review ecc-review-resume--pending))
  (when-let* ((key (buffer-local-value 'ecc-review-resume--key review))
              ((bound-and-true-p ecc-review-resume-enabled)))
    (condition-case error
        (let ((state (ecc-review-resume--read)))
          (ecc-review-resume--write
           state (seq-remove (lambda (entry) (equal (plist-get entry :key) key))
                             (plist-get state :reviews))))
      (error
       (ecc-log "review" "dropping the saved %s failed: %S" (buffer-name review) error)
       (message "ecc: the saved copy of %s was not dropped: %s"
                (buffer-name review) (error-message-string error))))))

(defun ecc-review-resume--save-at-exit ()
  "Save every review still open as Emacs exits.
The one used last is saved last, and so is the one a session keeps when
it has two open."
  (when ecc-review-resume-enabled
    (dolist (buffer (reverse (buffer-list)))
      (when (ecc-review-resume--saved-p buffer)
        (ecc-review-resume--save-safely buffer)))))

(add-hook 'ecc-review-after-draw-hook #'ecc-review-resume--on-draw)
(add-hook 'ecc-review-closing-functions #'ecc-review-resume--on-closing)
(add-hook 'ecc-review-dropping-functions #'ecc-review-resume--on-dropping)

;;;; Taking a review up again

(defun ecc-review-resume-entries ()
  "Return the reviews saved to be resumed, saved last first."
  (ecc-review-resume--prune (plist-get (ecc-review-resume--read) :reviews)))

(defun ecc-review-resume-saved-p ()
  "Return non-nil when a review is saved to be resumed.
A file that cannot be read counts as one: \\[ecc-review-resume] then
says what is wrong with it.  The error goes to the log."
  (condition-case error
      (and (ecc-review-resume-entries) t)
    (error (ecc-log "review" "reading %s failed: %S" ecc-review-resume-file error)
           t)))

(defun ecc-review-resume--scope (entry)
  "Return what the review ENTRY saved compared, in words.
The files it was kept to are named, two at most, and counted beyond."
  (let ((range (plist-get entry :range))
        (paths (plist-get entry :paths)))
    (concat (if range
                (ecc-review--range-name range (plist-get entry :label))
              "since the session started")
            (when paths
              (format " (%s)" (if (<= (length paths) 2)
                                  (string-join paths ", ")
                                (ecc-review--count (length paths) "file")))))))

(defun ecc-review-resume--where (entry)
  "Return the place the review ENTRY saved was read at, FILE:LINE, or nil."
  (when-let* ((place (plist-get entry :place))
              (path (plist-get place :path)))
    (if-let* ((line (if (plist-get place :side)
                        (plist-get place :line)
                      (car (plist-get place :hunk-range)))))
        (format "%s:%s" path line)
      path)))

(defun ecc-review-resume-describe (entry)
  "Return the line ENTRY is offered as.
The session, what the review compared, where it was read, its comments
and when it was saved; a session not in this Emacs says so."
  (let* ((yours (ecc-review-resume--unsent entry))
         (claude (- (length (plist-get entry :notes)) yours)))
    (string-join
     (delq nil (list (or (plist-get entry :name) "?")
                     (ecc-review-resume--scope entry)
                     (ecc-review-resume--where entry)
                     (concat (ecc-review--count yours "unsent comment")
                             (when (> claude 0) (format ", %d of Claude's" claude)))
                     (format-time-string "%Y-%m-%d %H:%M" (plist-get entry :time))
                     (unless (ecc-model-session (plist-get entry :session))
                       "not open in this Emacs")))
     " · ")))

(defun ecc-review-resume--choices (entries)
  "Return ENTRIES as (LINE . ENTRY), each LINE told apart from the others.
Two that would read alike -- two sessions of one name, or one session's
reviews of files the line only counts -- are numbered, <2> and on."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar (lambda (entry)
              (let* ((line (ecc-review-resume-describe entry))
                     (count (1+ (gethash line seen 0))))
                (puthash line count seen)
                (cons (if (> count 1) (format "%s <%d>" line count) line) entry)))
            entries)))

(defun ecc-review-resume-read ()
  "Ask which saved review to resume and return its entry.
The one saved last is offered first."
  (let* ((choices (ecc-review-resume--choices
                   (or (ecc-review-resume-entries)
                       (user-error "No review is saved to be resumed"))))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action choices string predicate)))))
    (cdr (assoc (completing-read "Resume the review of: " table nil t nil nil (caar choices))
                choices))))

(defun ecc-review-resume--open-review (session entry)
  "Return the review of SESSION open now of the scope ENTRY saved, or nil.
One that compares the same thing kept to other files is an error: it
is the buffer the review would be opened in, and its comments would
mix with the saved ones."
  (let ((scope (ecc-review-resume--entry-key entry))
        (other nil))
    (or (seq-find (lambda (buffer)
                    (with-current-buffer buffer
                      (and (eq ecc-review--session session)
                           (ecc-review-buffer-p)
                           (equal ecc-review--range (plist-get entry :range))
                           (or (equal (ecc-review-resume--review-key buffer) scope)
                               (progn (setq other buffer) nil)))))
                  (buffer-list))
        (when other
          (user-error "%s is open on other files; close it to resume this review"
                      (buffer-name other))))))

(defun ecc-review-resume--take-baseline (session entry)
  "Make the baseline the review ENTRY saved compared with SESSION's again.
Only a review of what the session changed since it started has one.
When git no longer has the tree, that is an error: a review against
another baseline would not be the review that was left."
  (when-let* (((null (plist-get entry :range)))
              (tree (plist-get entry :baseline)))
    (unless (ecc-review-tree-exists-p (plist-get entry :directory) tree)
      (user-error "Cannot resume the review of %s: git no longer has %s, the tree it compared with (git gc deletes a tree nothing names after two weeks)"
                  (plist-get entry :name) (substring tree 0 (min 7 (length tree)))))
    ;; A session restored before its baseline was saved has taken a new
    ;; one: the tree the review was read against is the one it started at.
    (unless (equal (ecc-session-baseline session) tree)
      (setf (ecc-session-baseline session) tree))))

(defun ecc-review-resume--paths (entry)
  "Return the files the review ENTRY saved kept to, absolute.
They are saved relative to the repository, and the session of the
review may work in a directory under it."
  (let ((directory (plist-get entry :directory)))
    (mapcar (lambda (path) (expand-file-name path directory))
            (plist-get entry :paths))))

(defun ecc-review-resume--open (session entry)
  "Open the review of SESSION that ENTRY saved, as it was opened.
Return its buffer: the control buffer of an ediff review, which is on
the screen by then, or a diff review, which is not shown yet."
  (let ((range (plist-get entry :range))
        (directory (plist-get entry :directory))
        (paths (ecc-review-resume--paths entry)))
    (if (eq (plist-get entry :style) 'ediff)
        (progn (require 'ecc-review-ediff)
               (if range
                   (ecc-review-ediff-range-buffer session range directory paths)
                 (ecc-review-ediff-buffer session paths)))
      (if range
          (ecc-review-range-buffer session range directory paths)
        (ecc-review-buffer session paths)))))

(defun ecc-review-resume--restore (review entry)
  "Put the comments ENTRY saved back in REVIEW, and return where it was read.
Each is carried from the reading it was saved on, as a refresh carries
it, and so is the place, which is returned as a line of REVIEW: its own
line, or the nearest that stayed, or nil."
  (with-current-buffer review
    (let* ((shapes (mapcar #'ecc-review-map-shape-from-data (plist-get entry :shapes)))
           (notes (mapcar (lambda (data) (ecc-review-resume--note data shapes))
                          (plist-get entry :notes)))
           (place (when-let* ((data (plist-get entry :place)))
                    (ecc-review-resume--note data shapes))))
      (setq ecc-review-resume--key (plist-get entry :key)
            ecc-review--show-agent (if (plist-member entry :show-agent)
                                       (plist-get entry :show-agent)
                                     t)
            ecc-review--notes (append ecc-review--notes notes)
            ecc-review--next-id (apply #'max ecc-review--next-id
                                       (or (plist-get entry :next-id) 1)
                                       (mapcar (lambda (note) (1+ (ecc-review-note-id note)))
                                               notes)))
      (ecc-review--hold place 'view)
      (unwind-protect
          (progn
            (ecc-review--receive (append notes (and place (list place))))
            (ecc-review--draw-notes)
            (when-let* ((filter (plist-get entry :filter)))
              (require 'ecc-review-files)
              (ecc-review-files-set-filter review filter))
            (and place
                 (or (ecc-review--locate-note place)
                     (ecc-review--nearest-line place))))
        (ecc-review--let-go (list place))))))

(defun ecc-review-resume--reopen (session entry)
  "Open the review ENTRY saved for SESSION again, with its comments; return it."
  (ecc-review-resume--take-baseline session entry)
  (let* ((review (ecc-review-resume--open session entry))
         (line (ecc-review-resume--restore review entry)))
    (unless (eq (plist-get entry :style) 'ediff)
      (ecc-review--display review session))
    (with-current-buffer review
      (when line
        (ecc-review-move-to line (ecc-review-shown-window)))
      (let* ((notes (seq-remove #'ecc-review-note-sent ecc-review--notes))
             (yours (seq-count (lambda (note) (eq (ecc-review-note-author note) 'user)) notes))
             (outdated (seq-count #'ecc-review-note-outdated notes)))
        (message "Resumed the review of %s%s: %s not sent yet%s"
                 (ecc-session-name session)
                 (if-let* ((where (ecc-review-resume--where entry)))
                     (format " at %s" where)
                   "")
                 (ecc-review--count yours "comment")
                 (if (> outdated 0) (format ", %d outdated" outdated) ""))))
    review))

;;;###autoload
(defun ecc-review-resume (entry)
  "Take up again a review that was closed, or open when Emacs exited.
The last review of each session and scope is saved as it closes and as
Emacs exits; this asks which one, and opens it again as it was opened
-- the same session, what it compared and the files it was kept to, in
diff or in ediff -- with the comments not sent yet back on their lines
and point where it was.  A comment whose line changed since is
outdated, as after a refresh, and a place whose line went is the
nearest line that stayed.  \\[ecc-review-quit] in a review drops it,
and what was saved of it, instead.

ENTRY is a saved review, `ecc-review-resume-read' asks for it.  The
session has to be in this Emacs, stopped or not: `ecc-restore' brings
back the sessions of the last one, and the CLI starts when the comments
are sent.  A review of that session comparing the same thing, kept to
the same files, that is open already is gone to instead.  What a
session changed since it started is compared with the baseline the
review was read against, which git keeps for two weeks; once it is
gone, the review cannot be resumed."
  (interactive (progn (ecc--require-package) (list (ecc-review-resume-read))))
  (let ((session (or (ecc-model-session (plist-get entry :session))
                     (user-error "%s is not open in this Emacs; bring it back with M-x ecc-restore or from the history (h), then resume its review"
                                 (or (plist-get entry :name) "The session of that review")))))
    (if-let* ((open (ecc-review-resume--open-review session entry)))
        (progn (with-current-buffer open (ecc-review-go-back))
               (message "The review of %s is open already" (ecc-session-name session))
               open)
      (ecc-review-resume--reopen session entry))))

(provide 'ecc-review-resume)

;;; ecc-review-resume.el ends here
