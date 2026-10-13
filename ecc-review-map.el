;;; ecc-review-map.el --- Where a line of one reading of a diff is in the next  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Assisted-by: Claude Code:claude-opus-5-5
;; Assisted-by: Claude Code:claude-fable-5-1
;; Assisted-by: Claude Code:claude-haiku-4-5
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

;; A review is read again whenever the files under it change, and every
;; comment on it has to land on the line it was about.  The diff shows
;; no context, so the text around a line says little about where it went:
;; a blank line or a lone brace reads like a hundred others, and lines
;; put in right above a line change what is next to it and not the line.
;;
;; So nothing here guesses from the text around a line.  Of each reading
;; of a file, a shape is kept: the lines the diff takes out of the old
;; side and puts into the new, by number, and the blob the old side was.
;; From that, the new side of the file is a sequence in which a line the
;; old side had is its number there -- an identity, not a text -- and a
;; line put in is its text.  Two readings against the same old side share
;; every line of it that neither took out, and those are matched by
;; number; only the lines put in between two of them are matched by
;; text, and only with each other.  A line that changed, or one that is
;; gone, matches nothing.
;;
;; When the old side itself changed -- a commit under a review of what is
;; not committed, a branch that moved -- the caller hands over the hunks
;; of the old blob against the new one, which it has from comparing the
;; two blobs' texts (`ecc-review-map-text-hunks'), and the numbers of the
;; old side are carried through them first.  When the two old sides are
;; not known, the lines are matched by text and order alone
;; (`ecc-review-map--by-text'); when they cannot be compared, nothing
;; matches, and the caller's comments go outdated rather than somewhere
;; that only reads alike.
;;
;; Nothing here knows of comments, buffers or git: the review hands in
;; the lines it read, and gets back where each line went.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-diff)

(cl-defstruct (ecc-review-map-shape (:constructor ecc-review-map--make-shape)
                                    (:copier nil))
  "What one reading of the diff of a file says about its lines.
BASE is the blob of the old side, `empty' for a file that did not exist,
or nil when the diff does not say.  REMOVED and ADDED are the lines the
diff takes out of the old side and puts into the new, as (NUMBER . TEXT)
in order.

A line is named by its SIDE, its NUMBER and its NTH: how many lines of
the file before it, in the order of the diff, have that side and number.
That is 0 but in a diff that joins a patch for each edit, each numbered
against the file as its edit found it, where two lines can share a
number; a hunk is named by its header and how many before it have that
header.  HUNKS are ((HEADER . NTH) . MEMBERS), MEMBERS the (SIDE NUMBER
. NTH) of the lines of the hunk.  ORDER is every (SIDE NUMBER . NTH) of
the file in the order of the diff; TEXTS every line of its new side, put
in or not, and GONE every line it takes out, as ((NUMBER . NTH) . TEXT)
in that order.  ADDED-AT is the (NUMBER . NTH) of each line of ADDED,
and PUT-IN a hash of them, made when `ecc-review-map-changed-p' is first
asked: only a comment on a whole hunk asks."
  base removed added added-at hunks order texts gone put-in)

(defun ecc-review-map-number (lines)
  "Give each of LINES, the lines of one file in the order of the diff, its NTH.
Each line gets :nth, how many lines before it have its side and number
-- a hunk's header, how many before it have that header -- and each line
of a hunk :hunk-nth, the NTH of its hunk's header (`ecc-review-map-shape'
says why).  This is where an NTH is counted, and the only place: the
review indexes its lines by it, and the shape reads it.  Return LINES."
  (let ((seen (make-hash-table :test #'equal))
        (header nil))
    (dolist (line lines)
      (let* ((side (plist-get line :side))
             (key (if side
                      (cons side (plist-get line :line))
                    (plist-get (plist-get line :hunk) :header)))
             (count (gethash key seen 0)))
        (puthash key (1+ count) seen)
        (plist-put line :nth count)
        (if side
            (plist-put line :hunk-nth (plist-get header :nth))
          (setq header line)))))
  lines)

(defun ecc-review-map-shape (lines base)
  "Return the shape of LINES, the lines of one file of a reading.
LINES are plists of `ecc-review--hunk-lines', header first in each hunk,
numbered by `ecc-review-map-number' -- here, when the first has no NTH.
BASE is the blob of the old side, as `ecc-review-map-shape' keeps it."
  (unless (plist-member (car lines) :nth)
    (ecc-review-map-number lines))
  (let ((removed nil) (added nil) (put-in nil) (hunks nil) (order nil) (texts nil) (gone nil))
    (dolist (line lines)
      (let* ((side (plist-get line :side))
             (number (plist-get line :line))
             (nth (plist-get line :nth)))
        (if (null side)
            (push (list (cons (plist-get (plist-get line :hunk) :header) nth)) hunks)
          (push (cons side (cons number nth)) order)
          (push (cons (cons number nth) (plist-get line :text)) (if (eq side 'new) texts gone))
          (when hunks
            (push (cons side (cons number nth)) (cdar hunks)))
          (cond ((eq side 'old)
                 (push (cons number (plist-get line :text)) removed))
                ;; A context line is a line of the old side.
                ((not (plist-get line :old-line))
                 (push (cons number (plist-get line :text)) added)
                 (push (cons number nth) put-in))))))
    (ecc-review-map--make-shape
     :base base
     :removed (sort (nreverse removed) #'car-less-than-car)
     :added (sort (nreverse added) #'car-less-than-car)
     :added-at put-in
     :hunks (mapcar (lambda (hunk) (cons (car hunk) (nreverse (cdr hunk))))
                    (nreverse hunks))
     :order (nreverse order)
     :texts (nreverse texts)
     :gone (nreverse gone))))

(defun ecc-review-map-changed-p (shape side number nth)
  "Return non-nil when line NUMBER of SIDE, the NTH of those, is one SHAPE changes.
Not context: every line of the old side a diff shows is one it takes
out; a line of the new side is changed when it is put in.  The NTH tells
a line put in from context at its number in another patch of the file."
  (or (eq side 'old)
      (gethash (cons number nth)
               (or (ecc-review-map-shape-put-in shape)
                   (setf (ecc-review-map-shape-put-in shape)
                         (let ((keys (make-hash-table :test #'equal)))
                           (dolist (key (ecc-review-map-shape-added-at shape))
                             (puthash key t keys))
                           keys))))))

(defun ecc-review-map-same-base-p (from to)
  "Return non-nil when the shapes FROM and TO were read against one old side.
Two that do not say which are not known to be: a diff made from what a
session recorded joins a patch for each edit, each against the file as
that edit found it."
  (let ((base (ecc-review-map-shape-base from)))
    (and base (equal base (ecc-review-map-shape-base to)))))

(defun ecc-review-map-text-hunks (from to)
  "Return the hunks of the text FROM against TO.
Each is (OLD-START OLD-COUNT NEW-START NEW-COUNT), numbered as
`ecc-diff-hunks' numbers them.  The texts are two blobs, compared line
by line by the diff the transcript uses (`ecc-diff-lines'), split at
the lines held once when too large (`ecc-diff-patience'); the lines
themselves are not kept."
  (mapcar (lambda (hunk) (seq-take hunk 4))
          (ecc-diff-hunks (ecc-diff-lines from to #'ecc-diff-patience) 0)))

;;;; The new side as a sequence

(cl-defstruct (ecc-review-map--side (:constructor ecc-review-map--make-side)
                                    (:copier nil))
  "The new side of a shape: TOKENS, a vector of the lines down to the last
change, each the number of a line of the old side or the text of a line
put in; NEXT, the line of the old side that comes after them; and
POSITIONS, a hash of each number of the old side in TOKENS to its index."
  tokens next positions)

(defun ecc-review-map--side (shape)
  "Return the new side of SHAPE, as `ecc-review-map--side'."
  (let ((removed (ecc-review-map-shape-removed shape))
        (added (ecc-review-map-shape-added shape))
        (positions (make-hash-table))
        (tokens nil)
        (length 0) (new 1) (old 1))
    (while (or added removed)
      (cond ((and added (<= (caar added) new))
             (when (= (caar added) new)
               (push (cdar added) tokens)
               (setq length (1+ length) new (1+ new)))
             (setq added (cdr added)))
            ((and removed (<= (caar removed) old))
             (when (= (caar removed) old)
               (setq old (1+ old)))
             (setq removed (cdr removed)))
            (t
             (puthash old length positions)
             (push old tokens)
             (setq length (1+ length) new (1+ new) old (1+ old)))))
    (ecc-review-map--make-side :tokens (vconcat (nreverse tokens)) :next old
                               :positions positions)))

(defun ecc-review-map--token (side index)
  "Return line INDEX of SIDE, counting from 0: beyond TOKENS, the old side's."
  (let ((tokens (ecc-review-map--side-tokens side)))
    (if (< index (length tokens))
        (aref tokens index)
      (+ (ecc-review-map--side-next side) (- index (length tokens))))))

(defun ecc-review-map--index (side number)
  "Return the index of line NUMBER of the old side in SIDE, nil when taken out."
  (or (gethash number (ecc-review-map--side-positions side))
      (let ((next (ecc-review-map--side-next side)))
        (and (>= number next)
             (+ (length (ecc-review-map--side-tokens side)) (- number next))))))

;;;; Matching the lines put in

(defun ecc-review-map--put-in (tokens from to side)
  "Return the tokens FROM to TO of TOKENS, to be matched by their text.
Only lines put in are: a line of the old side left between two shared
ones is one the other reading took out, and stands here as (SIDE I),
which nothing of the other side equals."
  (let ((out (make-vector (max 0 (- to from)) nil)))
    (dotimes (i (length out))
      (let ((token (aref tokens (+ from i))))
        (aset out i (if (stringp token) token (list side i)))))
    out))

(defun ecc-review-map--match (a b a0 b0 map)
  "Match the put-in lines A against B, at A0 and B0 of the whole, into MAP.
By `ecc-diff-script', split at the lines held once when too large."
  (ecc-diff-script-walk (ecc-diff-script a b #'ecc-diff-patience)
                        (lambda (tag i j)
                          (when (eq tag 'context)
                            (aset map (+ a0 i) (+ b0 j)))))
  map)

;;;; The map

(defun ecc-review-map-lines (from to &optional base-hunks)
  "Return a function saying where each line of the reading FROM is in TO.
FROM and TO are shapes of one file (`ecc-review-map-shape').  The
function takes a SIDE, `old' or `new', and a line NUMBER of FROM, and
returns the number that line has on that side of TO, or nil when TO
does not have it: it changed, or it went.  A number returned may be of
a line TO shows no more -- one that is no longer a change -- which the
caller finds by looking.

The function takes the NTH of the line as well (`ecc-review-map-shape')
and returns (NUMBER . NTH).

When the two were read against different old sides, BASE-HUNKS say how
the old side of FROM became that of TO: the hunks of the one blob
against the other (`ecc-review-map-text-hunks'), nil for none; `none'
when one of them is no file, so that no line of the one is in the other
and only the lines put in are matched; `text' when one of them is not
known, so that the lines of the new sides are matched by their text and
order alone (`ecc-review-map--by-text'); and `unknown' when nothing can
be said, which matches nothing."
  (let ((carry (cond ((ecc-review-map-same-base-p from to) 'same)
                     ((eq base-hunks 'unknown) nil)
                     ((memq base-hunks '(none text)) base-hunks)
                     ((null base-hunks) 'same)
                     (t base-hunks))))
    (cond
     ((null carry) #'ignore)
     ((eq carry 'text) (ecc-review-map--by-text from to))
     (t
      (let* ((forward (pcase carry
                        ('same #'identity)
                        ('none #'ignore)
                        (_ (ecc-diff-shifter carry))))
             (backward (pcase carry
                         ('same #'identity)
                         ('none #'ignore)
                         (_ (ecc-diff-shifter carry t))))
             (a (ecc-review-map--side from))
             (b (ecc-review-map--side to))
             (map (ecc-review-map--matches a b forward backward)))
        (lambda (side number &optional _nth)
          (when-let* ((there
                       (pcase side
                         ('old (funcall forward number))
                         ('new
                          (let ((i (1- number)))
                            (if (< i (length map))
                                (and (aref map i) (1+ (aref map i)))
                              (when-let* ((there (funcall forward (ecc-review-map--token a i)))
                                          (j (ecc-review-map--index b there)))
                                (1+ j))))))))
            ;; Numbers of a diff against one blob are each one line's.
            (cons there 0))))))))

(defun ecc-review-map--by-text (from to)
  "Return the map of `ecc-review-map-lines' for FROM and TO by text alone.
The lines of each side, in the order of the diff -- the new side's
against the new side's, the lines taken out against the lines taken
out -- are matched by `ecc-diff-script', split at the lines held once
when too large, and a line goes where its match is.  For two readings
that do not say which blob their old side is: a patch of each edit
joined one after another numbers each against the file as that edit
found it, so neither the numbers nor the lines between the changes are
known to be shared."
  (let ((new (ecc-review-map--text-matches (ecc-review-map-shape-texts from)
                                           (ecc-review-map-shape-texts to)))
        (old (ecc-review-map--text-matches (ecc-review-map-shape-gone from)
                                           (ecc-review-map-shape-gone to))))
    (lambda (side number &optional nth)
      (gethash (cons number (or nth 0)) (if (eq side 'new) new old)))))

(defun ecc-review-map--text-matches (from to)
  "Return a hash of each (NUMBER . NTH) of FROM to that of its match in TO.
FROM and TO are lists of ((NUMBER . NTH) . TEXT) in the order of a diff."
  (let ((a (vconcat (mapcar #'cdr from)))
        (b (vconcat (mapcar #'cdr to)))
        (a-places (vconcat (mapcar #'car from)))
        (b-places (vconcat (mapcar #'car to)))
        (lines (make-hash-table :test #'equal)))
    (ecc-diff-script-walk (ecc-diff-script a b #'ecc-diff-patience)
                          (lambda (tag i j)
                            (when (eq tag 'context)
                              (puthash (aref a-places i) (aref b-places j) lines))))
    lines))

(defun ecc-review-map--matches (a b forward backward)
  "Return a vector of where each token of the side A is in the side B, or nil.
FORWARD carries a number of the old side of A to that of B, BACKWARD
the other way.  The lines of the old side both keep are matched first,
by number, and the lines put in between two of them are matched with
each other."
  (let* ((tokens-a (ecc-review-map--side-tokens a))
         (tokens-b (ecc-review-map--side-tokens b))
         (map (make-vector (length tokens-a) nil))
         (pairs nil)
         (beyond nil))
    ;; The lines of the old side A holds, in order, then those B holds
    ;; that come after all of A's: each pair once, both runs in order.
    (dotimes (i (length tokens-a))
      (let ((token (aref tokens-a i)))
        (when (integerp token)
          (when-let* ((there (funcall forward token))
                      (j (ecc-review-map--index b there)))
            (push (cons i j) pairs)))))
    (dotimes (j (length tokens-b))
      (let ((token (aref tokens-b j)))
        (when (integerp token)
          (when-let* ((here (funcall backward token))
                      (i (ecc-review-map--index a here))
                      ((>= i (length tokens-a))))
            (push (cons i j) beyond)))))
    (setq pairs (nconc (nreverse pairs) (nreverse beyond)))
    (let ((i0 0) (j0 0))
      ;; The last stretch runs to the end of both.
      (dolist (pair (append pairs (list (cons (length tokens-a) (length tokens-b)))))
        (let ((i1 (min (car pair) (length tokens-a)))
              (j1 (min (cdr pair) (length tokens-b))))
          (when (and (< i0 i1) (< j0 j1))
            (ecc-review-map--match (ecc-review-map--put-in tokens-a i0 i1 'from)
                                   (ecc-review-map--put-in tokens-b j0 j1 'to)
                                   i0 j0 map))
          (when (< (car pair) (length tokens-a))
            (aset map (car pair) (cdr pair)))
          (setq i0 (max i0 (1+ (car pair))) j0 (max j0 (1+ (cdr pair)))))))
    map))

(provide 'ecc-review-map)
;;; ecc-review-map.el ends here
