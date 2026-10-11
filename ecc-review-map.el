;;; ecc-review-map.el --- Where a line of one reading of a diff is in the next  -*- lexical-binding: t; -*-

;; This file is part of ecc.

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
;; of the old blob against the new one (`ecc-review-map-base-hunks'),
;; and the numbers of the old side are carried through them first.
;; Without them nothing matches, and the caller's comments go outdated
;; rather than somewhere that only reads alike.
;;
;; Nothing here knows of comments, buffers or git: the review hands in
;; the lines it read, and gets back where each line went.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defvar ecc-review-map-max-cells 400000
  "How large a stretch of put-in lines is matched line against line.
Two stretches whose lengths multiply past this are first split at the
lines each holds once (`ecc-review-map--patience'), and a piece that is
still too large matches nothing: its comments go outdated rather than
the review stopping to compare it.")

(cl-defstruct (ecc-review-map-shape (:constructor ecc-review-map--make-shape)
                                    (:copier nil))
  "What one reading of the diff of a file says about its lines.
BASE is the blob of the old side, `empty' for a file that did not exist,
or nil when the diff does not say.  REMOVED and ADDED are the lines the
diff takes out of the old side and puts into the new, as (NUMBER . TEXT)
in order.  HUNKS are (HEADER . MEMBERS), MEMBERS the (SIDE . NUMBER) of
the lines of the hunk.  ORDER is every (SIDE . NUMBER) of the file in
the order of the diff."
  base removed added hunks order)

(defun ecc-review-map-shape (lines base)
  "Return the shape of LINES, the lines of one file of a reading.
LINES are plists of `ecc-review--hunk-lines', header first in each hunk.
BASE is the blob of the old side, as `ecc-review-map-shape' keeps it."
  (let ((removed nil) (added nil) (hunks nil) (order nil))
    (dolist (line lines)
      (let ((side (plist-get line :side))
            (number (plist-get line :line)))
        (if (null side)
            (push (list (plist-get (plist-get line :hunk) :header)) hunks)
          (push (cons side number) order)
          (when hunks
            (push (cons side number) (cdar hunks)))
          (cond ((eq side 'old)
                 (push (cons number (plist-get line :text)) removed))
                ;; A context line is a line of the old side.
                ((not (plist-get line :old-line))
                 (push (cons number (plist-get line :text)) added))))))
    (ecc-review-map--make-shape
     :base base
     :removed (sort (nreverse removed) #'car-less-than-car)
     :added (sort (nreverse added) #'car-less-than-car)
     :hunks (mapcar (lambda (hunk) (cons (car hunk) (nreverse (cdr hunk))))
                    (nreverse hunks))
     :order (nreverse order))))

(defun ecc-review-map-same-base-p (from to)
  "Return non-nil when the shapes FROM and TO were read against one old side."
  (equal (ecc-review-map-shape-base from) (ecc-review-map-shape-base to)))

(defun ecc-review-map-base-hunks (diff)
  "Return the hunks of the unified diff DIFF.
Each is (OLD-START OLD-COUNT NEW-START NEW-COUNT)."
  (let ((hunks nil)
        (start 0))
    (while (string-match
            "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
            diff start)
      (push (list (string-to-number (match-string 1 diff))
                  (if (match-string 2 diff) (string-to-number (match-string 2 diff)) 1)
                  (string-to-number (match-string 3 diff))
                  (if (match-string 4 diff) (string-to-number (match-string 4 diff)) 1))
            hunks)
      (setq start (match-end 0)))
    (nreverse hunks)))

(defun ecc-review-map--carry-base (number hunks forward)
  "Return where line NUMBER of one old side is in the other, or nil.
HUNKS are those of `ecc-review-map-base-hunks'; FORWARD carries a line
of their old side to their new, and otherwise the other way.  A line
inside a hunk changed and is nowhere.  git numbers a hunk that takes
nothing out by the line before it, which a line after it is behind."
  (let ((shift 0))
    (catch 'done
      (dolist (hunk hunks)
        (let* ((start (if forward (nth 0 hunk) (nth 2 hunk)))
               (count (if forward (nth 1 hunk) (nth 3 hunk)))
               (other (if forward (nth 3 hunk) (nth 1 hunk)))
               (end (if (zerop count) start (+ start count -1))))
          (cond ((and (> count 0) (<= start number end)) (throw 'done nil))
                ((< end number) (setq shift (+ shift (- other count))))
                (t (throw 'done (+ number shift))))))
      (+ number shift))))

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

(defun ecc-review-map--put-in (tokens from to)
  "Return the tokens FROM to TO of TOKENS, a line of the old side as nothing.
Only lines put in are matched by their text: a line of the old side
left between two shared ones is one the other reading took out."
  (let ((out (make-vector (max 0 (- to from)) nil)))
    (dotimes (i (length out))
      (let ((token (aref tokens (+ from i))))
        (aset out i (and (stringp token) token))))
    out))

(defun ecc-review-map--lcs (a b a0 b0 map)
  "Match the vectors A and B, starting at A0 and B0 of the whole, into MAP.
The longest common subsequence of the two, nil matching nothing."
  (let* ((n (length a)) (m (length b))
         (table (make-vector (1+ n) nil)))
    (dotimes (i (1+ n))
      (aset table i (make-vector (1+ m) 0)))
    (let ((i (1- n)))
      (while (>= i 0)
        (let ((j (1- m))
              (row (aref table i))
              (below (aref table (1+ i))))
          (while (>= j 0)
            (aset row j (if (and (aref a i) (equal (aref a i) (aref b j)))
                            (1+ (aref below (1+ j)))
                          (max (aref below j) (aref row (1+ j)))))
            (setq j (1- j))))
        (setq i (1- i))))
    (let ((i 0) (j 0))
      (while (and (< i n) (< j m))
        (cond ((and (aref a i) (equal (aref a i) (aref b j)))
               (aset map (+ a0 i) (+ b0 j))
               (setq i (1+ i) j (1+ j)))
              ((>= (aref (aref table (1+ i)) j) (aref (aref table i) (1+ j)))
               (setq i (1+ i)))
              (t (setq j (1+ j))))))))

(defun ecc-review-map--increasing (pairs)
  "Return the longest run of PAIRS, (I . J) by I, whose J go up too."
  (let* ((pairs (vconcat pairs))
         (n (length pairs))
         (tails (make-vector n 0))      ; index of the pair ending each run
         (back (make-vector n nil))
         (runs 0))
    (dotimes (k n)
      (let ((low 0) (high runs)
            (j (cdr (aref pairs k))))
        (while (< low high)
          (let ((mid (/ (+ low high) 2)))
            (if (< (cdr (aref pairs (aref tails mid))) j)
                (setq low (1+ mid))
              (setq high mid))))
        (when (> low 0)
          (aset back k (aref tails (1- low))))
        (aset tails low k)
        (when (= low runs)
          (setq runs (1+ runs)))))
    (let ((out nil)
          (k (and (> runs 0) (aref tails (1- runs)))))
      (while k
        (push (aref pairs k) out)
        (setq k (aref back k)))
      out)))

(defun ecc-review-map--patience (a b a0 b0 map)
  "Match A and B, as `ecc-review-map--lcs' does, when they are too large for it.
The lines each holds exactly once, and in the same order, are matched
first; the stretches between them are matched again."
  (let ((counts (make-hash-table :test #'equal)))
    (seq-do-indexed (lambda (text i)
                      (when text
                        (let ((count (gethash text counts (list 0 nil 0 nil))))
                          (puthash text (list (1+ (nth 0 count)) i (nth 2 count) nil) counts))))
                    a)
    (seq-do-indexed (lambda (text j)
                      (when-let* ((count (gethash text counts)))
                        (puthash text (list (nth 0 count) (nth 1 count) (1+ (nth 2 count)) j)
                                 counts)))
                    b)
    (let ((pairs nil))
      (maphash (lambda (_text count)
                 (when (and (= (nth 0 count) 1) (= (nth 2 count) 1))
                   (push (cons (nth 1 count) (nth 3 count)) pairs)))
               counts)
      (let ((i 0) (j 0))
        (dolist (pair (ecc-review-map--increasing (sort pairs #'car-less-than-car)))
          (ecc-review-map--match (seq-subseq a i (car pair)) (seq-subseq b j (cdr pair))
                                 (+ a0 i) (+ b0 j) map)
          (aset map (+ a0 (car pair)) (+ b0 (cdr pair)))
          (setq i (1+ (car pair)) j (1+ (cdr pair))))
        (when pairs
          (ecc-review-map--match (seq-subseq a i) (seq-subseq b j) (+ a0 i) (+ b0 j) map))))))

(defun ecc-review-map--match (a b a0 b0 map)
  "Match the put-in lines A against B, at A0 and B0 of the whole, into MAP.
The lines both begin or end with are matched first; what is left between
is matched line against line, or split first when it is large."
  (let ((n (length a)) (m (length b))
        (start 0))
    (while (and (< start n) (< start m) (aref a start)
                (equal (aref a start) (aref b start)))
      (aset map (+ a0 start) (+ b0 start))
      (setq start (1+ start)))
    (let ((end 0))
      (while (and (< end (- n start)) (< end (- m start))
                  (aref a (- n end 1))
                  (equal (aref a (- n end 1)) (aref b (- m end 1))))
        (aset map (+ a0 (- n end 1)) (+ b0 (- m end 1)))
        (setq end (1+ end)))
      (let ((a (seq-subseq a start (- n end)))
            (b (seq-subseq b start (- m end))))
        (cond ((or (zerop (length a)) (zerop (length b))))
              ((<= (* (length a) (length b)) ecc-review-map-max-cells)
               (ecc-review-map--lcs a b (+ a0 start) (+ b0 start) map))
              (t (ecc-review-map--patience a b (+ a0 start) (+ b0 start) map)))))))

;;;; The map

(defun ecc-review-map-lines (from to &optional base-hunks)
  "Return a function saying where each line of the reading FROM is in TO.
FROM and TO are shapes of one file (`ecc-review-map-shape').  The
function takes a SIDE, `old' or `new', and a line NUMBER of FROM, and
returns the number that line has on that side of TO, or nil when TO
does not have it: it changed, or it went.  A number returned may be of
a line TO shows no more -- one that is no longer a change -- which the
caller finds by looking.

When the two were read against different old sides, BASE-HUNKS are the
hunks of the old blob of FROM against that of TO
\(`ecc-review-map-base-hunks'); `unknown', or nil there, matches
nothing."
  (let ((same (ecc-review-map-same-base-p from to)))
    (if (and (not same) (or (null base-hunks) (eq base-hunks 'unknown)))
        #'ignore
      (let* ((forward (if same #'identity
                        (lambda (number) (ecc-review-map--carry-base number base-hunks t))))
             (backward (if same #'identity
                         (lambda (number) (ecc-review-map--carry-base number base-hunks nil))))
             (a (ecc-review-map--side from))
             (b (ecc-review-map--side to))
             (map (ecc-review-map--matches a b forward backward)))
        (lambda (side number)
          (pcase side
            ('old (funcall forward number))
            ('new
             (let ((i (1- number)))
               (if (< i (length map))
                   (and (aref map i) (1+ (aref map i)))
                 (when-let* ((there (funcall forward (ecc-review-map--token a i)))
                             (j (ecc-review-map--index b there)))
                   (1+ j)))))))))))

(defun ecc-review-map--matches (a b forward backward)
  "Return a vector of where each token of the side A is in the side B, or nil.
FORWARD carries a number of the old side of A to that of B, BACKWARD
the other way.  The lines of the old side both keep are matched first,
by number, and the lines put in between two of them are matched with
each other."
  (let* ((tokens-a (ecc-review-map--side-tokens a))
         (tokens-b (ecc-review-map--side-tokens b))
         (map (make-vector (length tokens-a) nil))
         (pairs nil))
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
                      (i (ecc-review-map--index a here)))
            (push (cons i j) pairs)))))
    (setq pairs (seq-uniq (sort pairs #'car-less-than-car)))
    (let ((i0 0) (j0 0))
      ;; The last stretch runs to the end of both.
      (dolist (pair (append pairs (list (cons (length tokens-a) (length tokens-b)))))
        (let ((i1 (min (car pair) (length tokens-a)))
              (j1 (min (cdr pair) (length tokens-b))))
          (when (and (< i0 i1) (< j0 j1))
            (ecc-review-map--match (ecc-review-map--put-in tokens-a i0 i1)
                                   (ecc-review-map--put-in tokens-b j0 j1)
                                   i0 j0 map))
          (when (< (car pair) (length tokens-a))
            (aset map (car pair) (cdr pair)))
          (setq i0 (max i0 (1+ (car pair))) j0 (max j0 (1+ (cdr pair)))))))
    map))

(provide 'ecc-review-map)
;;; ecc-review-map.el ends here
