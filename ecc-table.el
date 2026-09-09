;;; ecc-table.el --- Lay out a Markdown table in columns  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes

;;; Commentary:

;; `ecc-table-format' takes the lines of a Markdown pipe table and gives
;; them back drawn with rules, every column the same width down the
;; table.  `ecc-markdown-fontify' calls it for each table it finds.
;;
;; A table the model writes is lined up by counting characters, which is
;; not what a column costs to draw: Japanese is twice as wide as it is
;; long, so a table with a Japanese cell in it arrives ragged.  On top of
;; that the Markdown code hides the markup around bold and inline code,
;; and hidden text is worth no columns at all, so even a table the model
;; lined up correctly loses a few columns wherever a cell holds `**' or a
;; backquote.  Both are the same mistake, and `ecc-table--width' -- which
;; counts columns and passes over what is hidden -- is the answer to
;; both.
;;
;; A cell too wide for its column is wrapped rather than cut, so nothing
;; the model wrote is lost.  The table is laid out to at most
;; `ecc-table-max-width' columns, and not to the width of the window: the
;; renderer draws an assistant reply once, when it stops streaming, and
;; freezes it, so a width taken from the window would only be right until
;; the window was next resized (`ecc-render-refresh' redraws everything
;; when that matters).
;;
;; Like the rest of the transcript, this counts on the buffer being drawn
;; in a font whose Japanese is exactly twice as wide as its Latin.  That
;; is the default face's business, and `ecc-table-face' is the handle for
;; a reader whose default face is not that: name the family there.  Note
;; that `fixed-pitch' is no answer on its own -- it names a family of its
;; own (Courier, on a Mac) while the Japanese keeps falling back to the
;; reader's own font, and the two are then no longer in step.

;;; Code:

(require 'cl-lib)
(require 'ecc-core)

(defface ecc-table-face
  '((t :inherit default))
  "Face put under the whole of a table, below every other face.
It says nothing on its own.  It is there so that a reader whose default
face does not draw a Japanese character exactly twice as wide as a
Latin one can name a family here that does, and have the columns line
up again."
  :group 'ecc)

(defface ecc-table-border-face
  '((t :inherit shadow))
  "Face for the rules that frame and part the cells of a table."
  :group 'ecc)

(defface ecc-table-header-face
  '((t :inherit bold))
  "Face for the cells of the first row of a table."
  :group 'ecc)

(defcustom ecc-table-style 'box
  "How a Markdown table is drawn in the transcript.
`box' redraws it with rules, `pipe' keeps the pipes the model wrote
and only lines the columns up, and `off' leaves the table exactly as
it arrived."
  :type '(choice (const :tag "Rules" box)
                 (const :tag "Pipes" pipe)
                 (const :tag "Leave alone" off))
  :group 'ecc)

(defcustom ecc-table-max-width 92
  "Widest a table is drawn, in columns, or nil for no limit.
A column wider than its share is wrapped to fit.  The transcript
indents an assistant reply by a couple of columns, so this is a little
under the width of the window it is meant for."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'ecc)

(defconst ecc-table-row-regexp "^[ \t]*|"
  "Regexp matching a line that could be a row of a table.")

(defconst ecc-table-delimiter-regexp
  "^[ \t]*|[ \t]*:?-+:?[ \t]*\\(|[ \t]*:?-+:?[ \t]*\\)*|?[ \t]*$"
  "Regexp matching the row of dashes that stands under the header.
It is what tells a table from a paragraph that happens to hold a pipe,
so a run of lines without one is left alone.")

;;;; Reading a table

(defun ecc-table-at-point-p ()
  "Return non-nil when a table begins on the line point is on.
Point is expected at the beginning of the line, and is not moved."
  (and (looking-at-p ecc-table-row-regexp)
       (save-excursion
         (forward-line 1)
         (and (not (eobp))
              (looking-at-p ecc-table-delimiter-regexp)))))

(defun ecc-table-end ()
  "Return the end of the table beginning on the line point is on.
That is the end of the last of the lines that are rows of it.  Point is
not moved."
  (save-excursion
    (while (and (not (eobp)) (looking-at-p ecc-table-row-regexp))
      (forward-line 1))
    (goto-char (max (point-min) (1- (point))))
    (line-end-position)))

(defun ecc-table--split-row (line)
  "Return the cells of LINE as a list of strings.
The text properties of the cells are kept, so a face and the hidden
markup that Markdown put on them survive the layout.  A pipe inside an
inline code span, and one a backslash escapes, part nothing."
  (let ((fields nil)
        (start 0)
        (index 0)
        (length (length line))
        (code nil))
    (while (< index length)
      (let ((char (aref line index)))
        (cond ((eq char ?\\) (setq index (1+ index)))
              ((eq char ?`) (setq code (not code)))
              ((and (eq char ?|) (not code))
               (push (substring line start index) fields)
               (setq start (1+ index)))))
      (setq index (1+ index)))
    (push (substring line start) fields)
    (setq fields (nreverse fields))
    ;; The pipe that opens the row, and the one that closes it, each
    ;; leave an empty field of their own behind; a cell that is truly
    ;; empty is the one after them.
    (when (and fields (ecc-table--blank-p (car fields)))
      (setq fields (cdr fields)))
    (when (and (cdr fields)
               (string-match-p "|[ \t]*\\'" line)
               (ecc-table--blank-p (car (last fields))))
      (setq fields (butlast fields)))
    (mapcar #'string-trim fields)))

(defun ecc-table--blank-p (string)
  "Return non-nil when STRING holds nothing but whitespace."
  (string-match-p "\\`[ \t]*\\'" string))

(defun ecc-table--align (cell)
  "Return the alignment the delimiter CELL asks for.
A colon on the left is `left', one on the right is `right', and one on
each side is `center'."
  (let* ((text (string-trim cell))
         (head (string-prefix-p ":" text))
         (tail (string-suffix-p ":" text)))
    (cond ((and head tail) 'center)
          (tail 'right)
          (t 'left))))

;;;; Counting columns

(defun ecc-table--hidden-p (string index)
  "Return non-nil when the character of STRING at INDEX is hidden markup."
  (let ((invisible (get-text-property index 'invisible string)))
    (if (listp invisible)
        (memq 'ecc-markup invisible)
      (eq invisible 'ecc-markup))))

(defun ecc-table--char-width (string index)
  "Return what the character of STRING at INDEX costs to draw, in columns.
Hidden markup costs nothing, which is what makes a cell holding bold or
inline code as wide on the display as it looks."
  (if (ecc-table--hidden-p string index)
      0
    (char-width (aref string index))))

(defun ecc-table--width (string)
  "Return what STRING costs to draw, in columns."
  (let ((width 0)
        (index 0)
        (length (length string)))
    (while (< index length)
      (setq width (+ width (ecc-table--char-width string index)))
      (setq index (1+ index)))
    width))

(defun ecc-table--break (string start width)
  "Return where a line of STRING beginning at START reaches WIDTH columns.
The index returned never falls in the middle of a character, and is
always past START, so that a character wider than the whole column
still moves the wrapping along."
  (let ((index start)
        (length (length string))
        (columns 0))
    (while (and (< index length)
                (<= (+ columns (ecc-table--char-width string index)) width))
      (setq columns (+ columns (ecc-table--char-width string index)))
      (setq index (1+ index)))
    (max index (min length (1+ start)))))

(defun ecc-table--last-space (string start end)
  "Return the index of the last space of STRING between START and END.
Nil when there is none to break a line on."
  (let ((index (1- end))
        (found nil))
    (while (and (null found) (> index start))
      (if (memq (aref string index) '(?\s ?\t))
          (setq found index)
        (setq index (1- index))))
    found))

(defun ecc-table--wrap (cell width)
  "Return CELL as a list of lines of at most WIDTH columns each.
A line is broken on a space where there is one, and on the column
otherwise, so that a long word or a run of Japanese is wrapped rather
than left to run past the table."
  (if (<= (ecc-table--width cell) width)
      (list cell)
    (let ((lines nil)
          (start 0)
          (length (length cell)))
      (while (< start length)
        (let* ((edge (ecc-table--break cell start width))
               (break (if (>= edge length)
                          length
                        (or (ecc-table--last-space cell start edge) edge))))
          (push (string-trim-right (substring cell start break)) lines)
          (setq start break)
          (while (and (< start length) (memq (aref cell start) '(?\s ?\t)))
            (setq start (1+ start)))))
      (nreverse lines))))

(defun ecc-table--pad (cell width align)
  "Return CELL padded with spaces to exactly WIDTH columns, put by ALIGN."
  (let ((room (max 0 (- width (ecc-table--width cell)))))
    (pcase align
      ('right (concat (make-string room ?\s) cell))
      ('center (let ((left (/ room 2)))
                 (concat (make-string left ?\s) cell
                         (make-string (- room left) ?\s))))
      (_ (concat cell (make-string room ?\s))))))

(defun ecc-table--columns (rows count)
  "Return the width of each of the COUNT columns of ROWS.
Each column is as wide as its widest cell, and then the widest columns
are narrowed one at a time until the table fits `ecc-table-max-width'."
  (let ((widths (make-list count 1)))
    (dolist (row rows)
      (let ((index 0))
        (dolist (cell row)
          (when (< index count)
            (setf (nth index widths) (max (nth index widths) (ecc-table--width cell))))
          (setq index (1+ index)))))
    (when ecc-table-max-width
      ;; Every column is drawn with a rule and a space on each side of
      ;; its text, and the table is closed by one more rule.
      (let ((budget (max count (- ecc-table-max-width (1+ (* 3 count))))))
        (while (> (apply #'+ widths) budget)
          (let ((widest 0))
            (dotimes (index count)
              (when (> (nth index widths) (nth widest widths))
                (setq widest index)))
            (setf (nth widest widths) (1- (nth widest widths)))))))
    widths))

;;;; Drawing it

(defun ecc-table--border (string)
  "Return STRING as a piece of the frame of a table."
  (propertize string 'face 'ecc-table-border-face))

(defun ecc-table--rule (left middle right widths)
  "Return a rule across a table, with LEFT, MIDDLE and RIGHT at the joints.
WIDTHS is the width of each column."
  (ecc-table--border
   (concat left
           (mapconcat (lambda (width) (make-string (+ width 2) ?─)) widths middle)
           right)))

(defun ecc-table--pipe-rule (widths aligns)
  "Return the row of dashes of a table drawn in the `pipe' style.
WIDTHS is the width of each column and ALIGNS how each is put; a column
wide enough to hold them keeps the colons that say so."
  (ecc-table--border
   (concat "|"
           (mapconcat
            (lambda (pair)
              (let* ((width (car pair))
                     (align (cdr pair))
                     (dashes (make-string width ?-)))
                (when (>= width 3)
                  (when (memq align '(left center))
                    (aset dashes 0 ?:))
                  (when (memq align '(right center))
                    (aset dashes (1- width) ?:)))
                (concat " " dashes " ")))
            (cl-mapcar #'cons widths aligns)
            "|")
           "|")))

(defun ecc-table--row (cells widths aligns header)
  "Return the lines that draw one row of a table.
CELLS is what the row holds, WIDTHS the width of each column and
ALIGNS how each is put.  HEADER non-nil gives the text of the cells
the face of a heading.  A cell too wide for its column is wrapped, and
the row is then as tall as its tallest cell."
  (let* ((count (length widths))
         (wrapped (cl-loop for index from 0 below count
                           collect (ecc-table--wrap (or (nth index cells) "")
                                                    (nth index widths))))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         (bar (ecc-table--border (if (eq ecc-table-style 'pipe) "|" "│"))))
    (cl-loop
     for line from 0 below height
     collect (concat
              bar
              (mapconcat
               (lambda (index)
                 (let ((cell (ecc-table--pad (or (nth line (nth index wrapped)) "")
                                             (nth index widths)
                                             (nth index aligns))))
                   (when header
                     (add-face-text-property 0 (length cell)
                                             'ecc-table-header-face t cell))
                   (concat " " cell " ")))
               (number-sequence 0 (1- count))
               bar)
              bar))))

(defun ecc-table-format (lines)
  "Return LINES, the lines of a Markdown table, laid out in columns.
The first line is the header and the second the row of dashes that says
how each column is put; what follows is the body.  A row with too few
cells is filled out with empty ones, and one with too many widens the
table."
  (let* ((rows (mapcar #'ecc-table--split-row lines))
         (header (car rows))
         (delimiter (cadr rows))
         (body (cddr rows))
         (count (apply #'max 1 (mapcar #'length (cons header body))))
         (aligns (append (mapcar #'ecc-table--align delimiter)
                         (make-list (max 0 (- count (length delimiter))) 'left)))
         (widths (ecc-table--columns (cons header body) count))
         (drawn nil))
    (if (eq ecc-table-style 'pipe)
        (progn
          (setq drawn (ecc-table--row header widths aligns t))
          (push (ecc-table--pipe-rule widths aligns) drawn)
          (setq drawn (nreverse drawn)))
      (setq drawn (list (ecc-table--rule "┌" "┬" "┐" widths)))
      (setq drawn (append drawn (ecc-table--row header widths aligns t)))
      (setq drawn (append drawn (list (ecc-table--rule "├" "┼" "┤" widths)))))
    (dolist (row body)
      (setq drawn (append drawn (ecc-table--row row widths aligns nil))))
    (unless (eq ecc-table-style 'pipe)
      (setq drawn (append drawn (list (ecc-table--rule "└" "┴" "┘" widths)))))
    (mapcar (lambda (line)
              (let ((copy (copy-sequence line)))
                (add-face-text-property 0 (length copy) 'ecc-table-face t copy)
                copy))
            drawn)))

(provide 'ecc-table)

;;; ecc-table.el ends here
