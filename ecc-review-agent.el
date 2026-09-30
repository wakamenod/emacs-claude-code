;;; ecc-review-agent.el --- Claude's side of a review, over MCP  -*- lexical-binding: t; -*-

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

;; The review buffer carries comments both ways.  The user's go to
;; Claude as a prompt (`ecc-review-send'); this file is the other
;; direction.  Over the MCP server of this Emacs (`ecc-mcp.el'), Claude
;; can open the review, put comments on its lines, move the user's view
;; to a place in it, and read, remove or clear comments -- the way Hunk
;; (github.com/modem-dev/hunk) lets an agent annotate a diff somebody is
;; reading in a terminal.
;;
;; A tool works on the review of the session that called it: the URL
;; every session reaches the server at carries the session id
;; (`ecc-mcp-session'), so there is nothing to list or choose.  Of that
;; session's reviews it takes the one on the screen, else the one Claude
;; opened last, else the one used last.
;;
;; What the tools will not do: write or change a comment of the user's
;; -- Claude may remove one it has dealt with, never put words in it --
;; take the keyboard, or hide a session window.  A review Claude opens
;; or moves is shown only beside a session on the screen, and nothing
;; is selected (`ecc-window-show-review-quietly').  The tools touch no
;; file, which is why they are allowed without asking
;; (`ecc-review-agent-auto-allow').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-review)
(require 'ecc-window)
(require 'ecc-mcp)

(defvar ecc-review-agent-auto-allow t
  "Non-nil allows the review tools without asking.
They put comments into a buffer of this Emacs and move its view; they
write no file and run no command, so there is no judgement about
safety or cost to be made here, which is why this is a variable and not
a setting.  Set it to nil to be asked about them like any other tool.")

(defvar ecc-review-agent-instructions
  "The user reads changes in an Emacs review buffer: a unified diff they \
comment on line by line, whose comments come to you as a prompt.  When \
you are asked to explain, walk through or review changes, call \
review_open, put each remark on the line it is about with review_comment \
\(or several at once with review_comment_apply), and use review_navigate \
to bring the place you are talking about into view.  Keep a comment to \
what that line needs; the rest belongs in your answer.  To read what the \
user left, call review_list_comments with author \"user\"; once you have \
dealt with one, remove it with review_remove_comment.  You cannot write \
or change the user's comments; answer one with reply_to."
  "The paragraph the MCP server gives the model about the review tools.
A sentence sent to the model, so a variable and not a setting.  It is
read when a session starts, so a `setq\\=' takes effect on the next one.")

(defvar ecc-review-agent-no-review-text
  "No review is open for this session.  Call review_open first: it opens \
the changes as a diff in the user's Emacs, and the other review tools \
work on that."
  "What a review tool answers when the session has no review open.
A sentence the model can act on: an error that only says no is one it
works around.")

(defvar ecc-review-agent-ediff-text
  "The user is reviewing these changes in ediff, which the review tools \
do not reach: the comments they write there come to you as a prompt when \
they send them with C-c C-c."
  "What the model is told while the user reviews in ediff.
`ecc-review-style\=' `ediff\=' keeps its comments against the differences
of an ediff session, which these tools do not read yet; said in a
sentence, so that the model does not take the silence for no comment.")

(defconst ecc-review-agent-tools
  '("review_open" "review_hunks" "review_comment" "review_comment_apply"
    "review_navigate" "review_list_comments" "review_remove_comment"
    "review_clear_comments")
  "The tools this file publishes.")

;;;; Which review

(defvar ecc-review-agent--opened (make-hash-table :test #'eq :weakness 'key)
  "Hash of a session to the review buffer Claude opened last for it.")

(defun ecc-review-agent--session ()
  "Return the session calling, or signal that the call named none."
  (or (ecc-mcp-session)
      (error "The review tools work on the review of a session, and this call came from none")))

(defun ecc-review-agent--buffers (session)
  "Return the review buffers of SESSION, the one used last first.
The review of a proposal is left out: it is the user's to answer, and it
closes the moment they do."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'ecc-review-mode)
                       (eq ecc-review--session session)
                       (null ecc-review--request))))
              (buffer-list)))

(defun ecc-review-agent--ediff-p (session)
  "Return non-nil when SESSION has a review open in ediff.
The control buffer of such a review is the one whose comments are
listed by `ecc-review-ediff-comments\='."
  (seq-some (lambda (buffer)
              (and (eq (buffer-local-value 'ecc-review--comments-function buffer)
                       'ecc-review-ediff-comments)
                   (eq (buffer-local-value 'ecc-review--session buffer) session)))
            (buffer-list)))

(defun ecc-review-agent--with-ediff-note (session text)
  "Return TEXT, followed by `ecc-review-agent-ediff-text\=' when SESSION has one."
  (if (ecc-review-agent--ediff-p session)
      (concat text "\n\n" ecc-review-agent-ediff-text)
    text))

(defun ecc-review-agent-buffer (session)
  "Return the review buffer the tools of SESSION work on.
One on the screen comes first, the one Claude opened last among those;
then the one Claude opened last; then the one used last.  Signals
`ecc-review-agent-no-review-text\\=' when SESSION has none."
  (let* ((buffers (ecc-review-agent--buffers session))
         (opened (car (memq (gethash session ecc-review-agent--opened) buffers)))
         (shown (seq-filter (lambda (buffer) (get-buffer-window buffer 'visible))
                            buffers)))
    (or (car (memq opened shown))
        (car shown)
        opened
        (car buffers)
        (error "%s" (ecc-review-agent--with-ediff-note
                     session ecc-review-agent-no-review-text)))))

(defmacro ecc-review-agent--in-review (&rest body)
  "Run BODY in the review buffer of the session calling."
  (declare (indent 0) (debug t))
  `(with-current-buffer (ecc-review-agent-buffer (ecc-review-agent--session))
     ,@body))

(defun ecc-review-agent--show (buffer session)
  "Show the review BUFFER of SESSION the quiet way; return its window or nil.
Another review of SESSION on the screen gives up its window to it, so
that a second `review_open\=' does not divide the session again."
  (ecc-window-show-review-quietly
   buffer session
   (lambda (other)
     (and (not (eq other buffer))
          (memq other (ecc-review-agent--buffers session))))))

;;;; Reading what the model sent

(defun ecc-review-agent--integer (value name)
  "Return VALUE, the argument NAME, as an integer or nil.
A number may come as a string, and an id as \"#3\"."
  (cond
   ((null value) nil)
   ((integerp value) value)
   ((and (stringp value) (string-empty-p (string-trim value))) nil)
   ((and (stringp value) (string-match "\\`[ \t]*#?\\([0-9]+\\)[ \t]*\\'" value))
    (string-to-number (match-string 1 value)))
   (t (error "%s should be a number, not %S" name value))))

(defun ecc-review-agent--side (value)
  "Return the side VALUE names, `new' when it names none."
  (pcase value
    ((or 'nil "" "new") 'new)
    ("old" 'old)
    (_ (error "The side is \"new\" or \"old\", not %S" value))))

(defun ecc-review-agent--paths ()
  "Return the files of this review that have hunks, in the order of the diff."
  (delete-dups (mapcar (lambda (hunk) (plist-get hunk :path)) (ecc-review-hunks))))

(defun ecc-review-agent--path (file &optional commented)
  "Return the path of this review that FILE names, or signal which there are.
FILE may be relative to the repository, absolute, or carry git\\='s a/
or b/ in front.  With COMMENTED the files that only carry outdated
comments count too: those can still be listed and cleared."
  (let ((paths (delete-dups (append (ecc-review-agent--paths)
                                    (and commented
                                         (mapcar #'ecc-review-note-path
                                                 ecc-review--notes)))))
        (wanted (and (stringp file) (string-trim file))))
    (or (and wanted
             (not (string-empty-p wanted))
             (seq-find (lambda (path)
                         (or (equal path wanted)
                             (equal path (replace-regexp-in-string
                                          "\\`[ab]/" "" wanted))
                             (equal (expand-file-name path)
                                    (expand-file-name wanted))))
                       paths))
        (error "%s is not in the review; its files are: %s"
               (or file "(no file)")
               (if paths (string-join paths ", ") "none")))))

(defun ecc-review-agent--ranges (path side lines)
  "Return what the SIDE of PATH shows in LINES, as \"L1-L3, L10-L12\"."
  (let ((ranges nil))
    (dolist (header (seq-filter (lambda (line)
                                  (and (null (plist-get line :side))
                                       (equal (plist-get line :path) path)))
                                lines))
      (let ((numbers (delq nil
                           (mapcar (lambda (line)
                                     (and (eq (plist-get line :hunk)
                                              (plist-get header :hunk))
                                          (if (eq side 'old)
                                              (if (eq (plist-get line :side) 'old)
                                                  (plist-get line :line)
                                                (plist-get line :old-line))
                                            (and (eq (plist-get line :side) 'new)
                                                 (plist-get line :line)))))
                                   lines))))
        (when numbers
          (let ((low (apply #'min numbers))
                (high (apply #'max numbers)))
            (push (if (= low high) (format "L%d" low) (format "L%d-L%d" low high))
                  ranges)))))
    (if ranges (string-join (nreverse ranges) ", ") "nothing")))

(defun ecc-review-agent--find-line (path side number lines)
  "Return the member of LINES that is line NUMBER of SIDE of PATH, or nil.
A context line is on both sides; it is found by its old number too, and
comes back as the new side line it is anchored as."
  (seq-find (lambda (line)
              (and (equal (plist-get line :path) path)
                   (if (eq side 'old)
                       (or (and (eq (plist-get line :side) 'old)
                                (eql (plist-get line :line) number))
                           (eql (plist-get line :old-line) number))
                     (and (eq (plist-get line :side) 'new)
                          (eql (plist-get line :line) number)))))
            lines))

(defun ecc-review-agent--hunk-line (path number lines)
  "Return the @@ header line of hunk NUMBER of PATH in LINES, counted from 1."
  (let ((headers (seq-filter (lambda (line)
                               (and (null (plist-get line :side))
                                    (equal (plist-get line :path) path)))
                             lines)))
    (or (and (> number 0) (nth (1- number) headers))
        (error "%s has %d hunks; there is no hunk %d" path (length headers) number))))

(defun ecc-review-agent--resolve (spec lines)
  "Return (LINE REPLY-TO TEXT) for the comment SPEC asks for, or signal why not.
SPEC is an alist of file, line, side, hunk, text and reply_to, the
arguments of `review_comment'.  LINES are the lines of the review."
  (let ((text (alist-get 'text spec))
        (reply-to (ecc-review-agent--integer (alist-get 'reply_to spec) "reply_to"))
        (number (ecc-review-agent--integer (alist-get 'line spec) "line"))
        (hunk (ecc-review-agent--integer (alist-get 'hunk spec) "hunk"))
        (file (alist-get 'file spec)))
    (unless (and (stringp text) (not (string-empty-p (string-trim text))))
      (error "The comment has no text"))
    (cond
     (reply-to
      (let ((parent (or (ecc-review-find-note reply-to)
                        (error "There is no comment #%d; review_list_comments lists them"
                               reply-to))))
        ;; A reply goes where the comment it answers is, so a place given
        ;; with it is either the same or a mistake that would be quietly
        ;; ignored.
        (when (or number hunk)
          (error "A reply goes under the comment it answers; give reply_to without line or hunk"))
        (when (and (stringp file) (not (string-empty-p (string-trim file)))
                   (not (equal (ignore-errors (ecc-review-agent--path file t))
                               (ecc-review-note-path parent))))
          (error "Comment #%d is on %s, not %s; give reply_to without file"
                 reply-to (ecc-review-note-path parent) file)))
      (list nil reply-to (string-trim text)))
     ((and number hunk)
      (error "Give line or hunk, not both"))
     ((not (or number hunk))
      (error "Give the line the comment is on, the hunk number for a whole hunk, or reply_to"))
     (t
      (let ((path (ecc-review-agent--path file)))
        (list (if hunk
                  (ecc-review-agent--hunk-line path hunk lines)
                (let ((side (ecc-review-agent--side (alist-get 'side spec))))
                  (or (ecc-review-agent--find-line path side number lines)
                      (error "%s:%d (%s) is not in the diff.  The %s side of %s shows %s; comment on one of those lines, or on a whole hunk with hunk"
                             path number side side path
                             (ecc-review-agent--ranges path side lines)))))
              nil
              (string-trim text)))))))

;;;; The tools

(defun ecc-review-agent--what ()
  "Return what the review of this buffer compares, in words."
  (concat
   (cond
    ((null ecc-review--range) "everything changed since the session started")
    ((eq ecc-review--range 'staged) "what is staged")
    ((string-empty-p ecc-review--range) "what is not staged yet")
    (t (format "the working tree against %s" ecc-review--range)))
   (when ecc-review--paths
     (format " in %s" (string-join ecc-review--paths ", ")))))

(defun ecc-review-agent--counts ()
  "Return the comments of this buffer counted by author, in words."
  (let ((user (seq-count (lambda (note) (not (ecc-review--agent-p note)))
                         ecc-review--notes))
        (claude (seq-count #'ecc-review--agent-p ecc-review--notes)))
    (format "%d by the user, %d by you" user claude)))

(defun ecc-review-agent--summary (&optional file include-patch)
  "Return the files and hunks of this review, of FILE alone when given.
INCLUDE-PATCH adds the text of each hunk."
  (let* ((paths (if file (list (ecc-review-agent--path file)) (ecc-review-agent--paths)))
         (hunks (ecc-review-hunks)))
    (concat
     (format "Review of %s: %s, %s; comments: %s.\n"
             (ecc-review-agent--what)
             (ecc-review--count (length (ecc-review-agent--paths)) "file")
             (ecc-review--count (length hunks) "hunk")
             (ecc-review-agent--counts))
     (mapconcat
      (lambda (path)
        (let ((number 0))
          (concat
           "\n" path "\n"
           (mapconcat
            (lambda (hunk)
              (cl-incf number)
              (let ((comments (seq-count
                               (lambda (note)
                                 (and (not (ecc-review-note-outdated note))
                                      (equal (ecc-review-note-hunk-key note)
                                             (ecc-review--hunk-key hunk))))
                               ecc-review--notes)))
                (concat
                 (format "  hunk %d  %s  new L%d-L%d%s\n"
                         number (plist-get hunk :header)
                         (plist-get hunk :start) (plist-get hunk :end)
                         (if (> comments 0) (concat "  " (ecc-review--count comments "comment")) ""))
                 (when include-patch
                   (let ((fence (ecc-review--fence (plist-get hunk :text))))
                     (format "%sdiff\n%s\n%s\n" fence (plist-get hunk :text) fence))))))
            (seq-filter (lambda (hunk) (equal (plist-get hunk :path) path)) hunks)
            ""))))
      paths ""))))

(defun ecc-review-agent--paths-argument (paths)
  "Return PATHS, the paths argument of review_open, as a list of strings."
  (let ((paths (cond ((null paths) nil)
                     ((stringp paths) (list paths))
                     ((vectorp paths) (append paths nil))
                     (t (error "paths is an array of file names, not %S" paths)))))
    (delq nil
          (mapcar (lambda (path)
                    (unless (stringp path)
                      (error "paths is an array of file names, and %S is not one" path))
                    (let ((path (string-trim path)))
                      (and (not (string-empty-p path)) path)))
                  paths))))

(defun ecc-review-agent-open (range staged paths)
  "Open the review of the session calling and return what it holds.
RANGE nil reviews everything changed since the session started; a
string is what git diffs the working tree against, \"\" meaning what is
not staged.  STAGED, a JSON boolean, reviews what is staged instead.
PATHS, an array of file names relative to the repository, restrict the
review to those.  A review that is open already is read again, its
comments kept.  The review is shown the quiet way, or not at all when
the user is not looking at the session."
  (let* ((session (ecc-review-agent--session))
         (paths (ecc-review-agent--paths-argument paths))
         ;; The range goes to git as an argument, so one that is an
         ;; option -- --output=FILE writes a file -- is refused before git
         ;; sees it (`ecc-review-parse-range\=').
         (range (ecc-review-parse-range (and (stringp range) range)))
         (range (cond ((not (ecc--json-true-p staged)) range)
                      ((memq range '(nil staged)) 'staged)
                      (t (error "Give range or staged, not both")))))
    (let* ((buffer (if range
                       (ecc-review-worktree-buffer session range nil paths)
                     (ecc-review-buffer session paths)))
           (window (ecc-review-agent--show buffer session)))
      (puthash session buffer ecc-review-agent--opened)
      (ecc-review-agent--with-ediff-note
       session
       (with-current-buffer buffer
         (concat (if window
                     "The review is open beside the session.\n"
                   "The review is open in Emacs but not on the screen: the user is not looking at this session, or it had no window to go in but the one they are using.\n")
                 (ecc-review-agent--summary)))))))

(defun ecc-review-agent-hunks (file include-patch)
  "Return the hunks of the review, of FILE alone when given.
INCLUDE-PATCH, a JSON boolean, adds the text of each."
  (ecc-review-agent--in-review
    (ecc-review-agent--summary (and (stringp file) (not (string-empty-p file)) file)
                               (ecc--json-true-p include-patch))))

(defun ecc-review-agent--add (specs)
  "Add a comment of Claude\\='s for each of SPECS and say what was added.
Every one is checked before any is added, so that a list with one bad
comment in it adds nothing and can be sent again whole."
  (ecc-review-agent--in-review
    (let ((lines (ecc-review--lines))
          (resolved nil)
          (errors nil)
          (index 0))
      (unless specs
        (error "There is no comment to add"))
      (seq-doseq (spec specs)
        (cl-incf index)
        (condition-case error
            (push (if (and (consp spec) (seq-every-p #'consp spec))
                      (ecc-review-agent--resolve spec lines)
                    (error "A comment is an object with the arguments of review_comment, not %S"
                           spec))
                  resolved)
          (error (push (if (cdr-safe specs) ; more than one
                           (format "comment %d: %s" index (error-message-string error))
                         (error-message-string error))
                       errors))))
      (when errors
        (error "%s%s" (string-join (nreverse errors) "\n")
               (if (> (length specs) 1) "\nNothing was added." "")))
      (let ((notes (mapcar (pcase-lambda (`(,line ,reply-to ,text))
                             (ecc-review-add-note 'claude text line reply-to))
                           (nreverse resolved))))
        (ecc-review--draw-notes)
        (mapconcat (lambda (note)
                     (format "Added #%d at %s" (ecc-review-note-id note)
                             (ecc-review-note-where note)))
                   notes "\n")))))

(defun ecc-review-agent-comment (file line side hunk text reply-to)
  "Put Claude\\='s comment TEXT on LINE of SIDE of FILE, or on HUNK.
With REPLY-TO the comment answers that one and goes where it is."
  (ecc-review-agent--add
   (list `((file . ,file) (line . ,line) (side . ,side) (hunk . ,hunk)
           (text . ,text) (reply_to . ,reply-to)))))

(defun ecc-review-agent-comment-apply (comments)
  "Put every one of COMMENTS on the review, or none of them.
COMMENTS is an array of objects with the arguments of review_comment."
  (unless (and (sequencep comments) (not (stringp comments)))
    (error "The comments are an array of objects, each with the arguments of review_comment"))
  (ecc-review-agent--add (append comments nil)))

(defun ecc-review-agent--window-start (window position)
  "Return a start for WINDOW that puts POSITION a quarter of the way down."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char position)
      (forward-line (- (/ (window-body-height window) 4)))
      (point))))

(defun ecc-review-agent--note-positions ()
  "Return where the comments of this buffer are, hidden ones included, in order."
  (sort (delete-dups (delq nil (mapcar #'ecc-review-note-position ecc-review--notes)))
        #'<))

(defun ecc-review-agent-navigate (file hunk line side comment-id direction)
  "Move the view of the review to a place and say where it went.
The place is COMMENT-ID, the next or previous comment in DIRECTION,
LINE of SIDE of FILE, HUNK of FILE, or the first hunk of FILE.  The
window is moved without being selected."
  (ecc-review-agent--in-review
    (let* ((window (ecc-review-agent--show (current-buffer) ecc-review--session))
           (from (if window (window-point window) (point)))
           (lines (ecc-review--lines))
           (id (ecc-review-agent--integer comment-id "comment_id"))
           (number (ecc-review-agent--integer line "line"))
           (hunk (ecc-review-agent--integer hunk "hunk"))
           (target
            (cond
             (id
              (let ((note (or (ecc-review-find-note id)
                              (error "There is no comment #%d" id))))
                (cons (ecc-review-note-position note) (format "comment #%d" id))))
             ((and (stringp direction) (not (string-empty-p direction)))
              (let* ((positions (ecc-review-agent--note-positions))
                     (position
                      (pcase direction
                        ("next_comment" (seq-find (lambda (p) (> p from)) positions))
                        ("prev_comment" (car (last (seq-filter (lambda (p) (< p from))
                                                               positions))))
                        (_ (error "The direction is next_comment or prev_comment, not %S"
                                  direction)))))
                (cons (or position (error "There is no comment %s the one in view"
                                          (if (equal direction "next_comment")
                                              "after" "before")))
                      "the comment there")))
             (t
              (let ((path (ecc-review-agent--path file)))
                (cond
                 (number
                  (let ((side (ecc-review-agent--side side)))
                    (cons (plist-get (or (ecc-review-agent--find-line path side number lines)
                                         (error "%s:%d (%s) is not in the diff; the %s side shows %s"
                                                path number side side
                                                (ecc-review-agent--ranges path side lines)))
                                     :position)
                          (format "%s:%d (%s)" path number side))))
                 (hunk
                  (cons (plist-get (ecc-review-agent--hunk-line path hunk lines) :position)
                        (format "hunk %d of %s" hunk path)))
                 (t (cons (plist-get (ecc-review-agent--hunk-line path 1 lines) :position)
                          path)))))))
           (position (car target)))
      (goto-char position)
      (if (not window)
          (format "The review is not on the screen (the user is not looking at this session, or it had no window to go in but the one they are using).  Its point is at %s, where it opens when the user opens it; a window already showing it in another tab keeps the place it had."
                  (cdr target))
        (set-window-point window position)
        (set-window-start window (ecc-review-agent--window-start window position))
        (format "Showing %s to the user." (cdr target))))))

(defun ecc-review-agent--note-line (note depth)
  "Return NOTE as `review_list_comments' lists it, DEPTH replies deep."
  (let ((indent (make-string (* 2 depth) ?\s)))
    (concat indent
            (format "#%d [%s] %s%s%s: "
                    (ecc-review-note-id note)
                    (ecc-review-note-author note)
                    (ecc-review-note-where note)
                    (if (ecc-review-note-outdated note)
                        " (outdated: the line is no longer in the diff)" "")
                    (if (and (ecc-review-note-reply-to note) (zerop depth))
                        (format " (reply to #%d)" (ecc-review-note-reply-to note))
                      ""))
            (string-replace "\n" (concat "\n" indent "  ") (ecc-review-note-text note))
            ;; The user's comment with the hunk it is on, so that it can
            ;; be acted on without a second call.
            (unless (ecc-review--agent-p note)
              (let ((fence (ecc-review--fence (or (ecc-review-note-hunk-text note) ""))))
                (format "\n%s%sdiff\n%s\n%s%s" indent fence
                        (ecc-review-note-hunk-text note) indent fence))))))

(defun ecc-review-agent-list-comments (author file)
  "Return the comments of the review, of AUTHOR and FILE when given.
A reply is listed under what it answers.  A review the user has open in
ediff is not read, and the answer says so rather than \"No comments\"."
  (let ((session (ecc-review-agent--session)))
    (if (and (ecc-review-agent--ediff-p session)
             (null (ecc-review-agent--buffers session)))
        ecc-review-agent-ediff-text
      (ecc-review-agent--with-ediff-note
       session (ecc-review-agent--list-comments author file)))))

(defun ecc-review-agent--list-comments (author file)
  "Return the comments of the diff review, of AUTHOR and FILE when given."
  (ecc-review-agent--in-review
    (let* ((author (pcase author
                     ((or 'nil "") nil)
                     ("user" 'user)
                     ("claude" 'claude)
                     (_ (error "The author is \"user\" or \"claude\", not %S" author))))
           (path (and (stringp file) (not (string-empty-p (string-trim file)))
                      (ecc-review-agent--path file t)))
           (notes (seq-filter (lambda (note)
                                (and (or (null author)
                                         (eq (ecc-review-note-author note) author))
                                     (or (null path)
                                         (equal (ecc-review-note-path note) path))))
                              (ecc-review--ordered ecc-review--notes)))
           (children (lambda (note)
                       (seq-filter (lambda (other)
                                     (eql (ecc-review-note-reply-to other)
                                          (ecc-review-note-id note)))
                                   notes)))
           (walk nil))
      (setq walk (lambda (note depth)
                   (cons (ecc-review-agent--note-line note depth)
                         (mapcan (lambda (child) (funcall walk child (1+ depth)))
                                 (funcall children note)))))
      (if (null notes)
          "No comments."
        (string-join
         (mapcan (lambda (note) (funcall walk note 0))
                 (seq-remove (lambda (note) (memq (ecc-review--parent note) notes))
                             notes))
         "\n")))))

(defun ecc-review-agent-remove-comment (id)
  "Remove the comment ID, whoever wrote it, and say which it was."
  (ecc-review-agent--in-review
    (let* ((id (or (ecc-review-agent--integer id "id") (error "Give the id of the comment")))
           (note (or (ecc-review-find-note id)
                     (error "There is no comment #%d; the comments are %s" id
                            (if ecc-review--notes
                                (mapconcat (lambda (note) (format "#%d" (ecc-review-note-id note)))
                                           ecc-review--notes ", ")
                              "none")))))
      (ecc-review-remove-note note)
      (ecc-review--draw-notes)
      (format "Removed #%d, %s comment at %s." id
              (if (ecc-review--agent-p note) "your" "the user's")
              (ecc-review-note-where note)))))

(defun ecc-review-agent-clear-comments (file include-user-comments)
  "Remove Claude\\='s comments, of FILE alone when given.
INCLUDE-USER-COMMENTS, a JSON boolean, removes the user\\='s as well."
  (ecc-review-agent--in-review
    (let* ((path (and (stringp file) (not (string-empty-p (string-trim file)))
                      (ecc-review-agent--path file t)))
           (all (ecc--json-true-p include-user-comments))
           (in-file (seq-filter (lambda (note)
                                  (or (null path)
                                      (equal (ecc-review-note-path note) path)))
                                ecc-review--notes))
           (gone (seq-filter (lambda (note) (or all (ecc-review--agent-p note))) in-file))
           (kept (- (length in-file) (length gone))))
      (mapc #'ecc-review-remove-note gone)
      (ecc-review--draw-notes)
      (format "Removed %s.%s" (ecc-review--count (length gone) "comment")
              (if (> kept 0)
                  (format "  The user's %d were kept; include_user_comments removes them too."
                          kept)
                "")))))

;;;; Publishing them

(defconst ecc-review-agent--side-schema
  '((type . "string") (enum . ["new" "old"]))
  "The schema of a side argument.")

(defun ecc-review-agent-register-tools ()
  "Publish the review tools and their paragraph of the server instructions."
  (ecc-mcp-define-tool
   :name "review_open"
   :description "Open the changes as a diff in the user's Emacs review buffer, or read it again when it is open; the comments on it are kept.  Without range it shows everything this session changed since it started, commits included.  With range it is the working tree against a revision (\"HEAD\" is everything uncommitted), \"\" what is not staged, or commits such as \"main...HEAD\" or \"HEAD~1..HEAD\".  staged shows what is staged instead.  paths keeps only those files.  The user's focus is left alone.  Returns the files and hunks, as review_hunks does."
   :args '(("range" "string" "What to diff the working tree against; leave it out for this session's changes")
           ("staged" "boolean" "Show what is staged, the index against HEAD, instead of a range")
           ("paths" ((type . "array") (items . ((type . "string"))))
            "Only these files, relative to the repository"))
   :function #'ecc-review-agent-open)
  (ecc-mcp-define-tool
   :name "review_hunks"
   :description "List the files and hunks of the open review: for each hunk its number in its file (from 1), its @@ header, the lines of its new side and how many comments it has."
   :args '(("file" "string" "Only this file, relative to the repository")
           ("include_patch" "boolean" "Add the text of each hunk"))
   :function #'ecc-review-agent-hunks)
  (ecc-mcp-define-tool
   :name "review_comment"
   :description "Put a comment on a line of the open review, where the user reads it under the line.  Give file and line (side \"new\" for an added or unchanged line, \"old\" for a removed one), or file and hunk for the whole hunk, or reply_to alone to answer a comment.  The line has to be in the diff; if it is not, the answer says which lines are.  Returns the id of the comment."
   :args `(("file" "string" "The file, relative to the repository")
           ("line" "integer" "The line number on the given side")
           ("side" ,ecc-review-agent--side-schema "Which side line counts on; new by default")
           ("hunk" "integer" "The number of the hunk in its file, from 1, for a comment on the whole hunk")
           ("text" "string" "The comment" t)
           ("reply_to" "integer" "The id of a comment this one answers"))
   :function #'ecc-review-agent-comment)
  (ecc-mcp-define-tool
   :name "review_comment_apply"
   :description "Put several comments on the open review at once, each with the arguments of review_comment.  All of them are checked first: if one is wrong, none is added and the answer says which, so fix it and send the list again."
   :args `(("comments"
            ((type . "array")
             (items . ((type . "object")
                       (properties . ((file . ((type . "string")))
                                      (line . ((type . "integer")))
                                      (side . ,ecc-review-agent--side-schema)
                                      (hunk . ((type . "integer")))
                                      (text . ((type . "string")))
                                      (reply_to . ((type . "integer")))))
                       (required . ["text"]))))
            "The comments to add" t))
   :function #'ecc-review-agent-comment-apply)
  (ecc-mcp-define-tool
   :name "review_navigate"
   :description "Scroll the user's review to a place, without taking their focus: a comment (comment_id), the next or previous comment (direction), a line (file, line and side), a hunk (file and hunk), or a file (file alone)."
   :args `(("file" "string" "The file, relative to the repository")
           ("hunk" "integer" "The number of the hunk in its file, from 1")
           ("line" "integer" "The line number on the given side")
           ("side" ,ecc-review-agent--side-schema "Which side line counts on; new by default")
           ("comment_id" "integer" "The id of a comment to show")
           ("direction" ((type . "string") (enum . ["next_comment" "prev_comment"]))
            "Move to the next or the previous comment from where the user is"))
   :function #'ecc-review-agent-navigate)
  (ecc-mcp-define-tool
   :name "review_list_comments"
   :description "List the comments of the open review, one per line: id, author, place and text, a reply under the comment it answers, an outdated one (its line is no longer in the diff) marked.  A comment of the user's comes with the hunk it is on."
   :args '(("author" ((type . "string") (enum . ["user" "claude"])) "Only this author's comments")
           ("file" "string" "Only this file's comments"))
   :function #'ecc-review-agent-list-comments)
  (ecc-mcp-define-tool
   :name "review_remove_comment"
   :description "Remove one comment of the open review by its id, yours or the user's -- a comment of the user's once you have dealt with it."
   :args '(("id" "integer" "The id of the comment" t))
   :function #'ecc-review-agent-remove-comment)
  (ecc-mcp-define-tool
   :name "review_clear_comments"
   :description "Remove your comments from the open review, of one file or all of them.  The user's are kept unless include_user_comments is true."
   :args '(("file" "string" "Only this file's comments")
           ("include_user_comments" "boolean" "Remove the user's comments as well"))
   :function #'ecc-review-agent-clear-comments)
  (ecc-mcp-define-instructions "review" 'ecc-review-agent-instructions
                               ecc-review-agent-tools))

(ecc-review-agent-register-tools)

;;;; Allowing them

(defun ecc-review-agent-allow-request (_session request)
  "Return non-nil when REQUEST calls one of the review tools of this Emacs.
On `ecc-request-allow-functions\\=', while `ecc-review-agent-auto-allow\\='
says so.  The prefix is made from `ecc-mcp-server-name\\=' -- the CLI
names a tool mcp__SERVER__TOOL -- and the rest has to be one of
`ecc-review-agent-tools\\=': a tool of another server, or another tool of
this one, is asked about as before.

Allowed here rather than by handing the CLI --allowedTools: that would
mix with the session\\='s own :allowed-tools, and the transcript would
not show that anything was allowed."
  (and ecc-review-agent-auto-allow
       (let ((prefix (format "mcp__%s__" ecc-mcp-server-name))
             (name (ecc-request-tool-name request)))
         (and (stringp name)
              (string-prefix-p prefix name)
              (member (substring name (length prefix)) ecc-review-agent-tools)
              t))))

(add-hook 'ecc-request-allow-functions #'ecc-review-agent-allow-request)

(provide 'ecc-review-agent)

;;; ecc-review-agent.el ends here
