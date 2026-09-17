;;; ecc-review-ediff.el --- Reviewing what Claude changed side by side  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The other way `ecc-review' and `ecc-review-worktree' can show what
;; changed, chosen with `ecc-review-style': ediff rather than one
;; unified diff.  Everything after that is the review of `ecc-review.el'
;; -- c comments a difference, C-c C-c sends every comment as one
;; prompt -- because the two slots a review buffer fills in say how it
;; lists its comments and how it closes, and nothing else differs.
;;
;; Concatenation, not one session per file.  Every changed file goes
;; into buffer A as it was and into buffer B as it is, one after the
;; other under the same separator line, and the two buffers are given
;; to `ediff-buffers' once.  n and p then walk every difference of the
;; whole review, across file boundaries, which is what a review wants;
;; ediff's own session groups walk files instead, and reach for
;; internal functions, file names and a non-recursive directory scan to
;; do it.  The separator lines are identical on both sides, so they are
;; never a difference themselves; each one's line number is remembered
;; in `ecc-review-ediff--sections', which is how a difference is
;; traced back to a file and a line in it without searching the buffer
;; for text that the content itself could hold.  A blank line in front
;; of each separator (`ecc-review-ediff-file-spacing') keeps one file
;; from running into the next.
;;
;; They are read as code, not as text: each file is fontified by its own
;; major mode as it is inserted, and the differences are marked in the
;; colours the diff review uses, because ediff's own faces for the
;; differences it is not standing on are invisible under a good many
;; themes.
;;
;; Both buffers are read-only, and that is the whole of it: a review
;; reads, comments and sends, and writes nothing.  ediff's a and b say
;; `buffer-read-only' and change nothing, which is the behaviour
;; wanted -- the files on disk are Claude's to change, from the prompt
;; the comments are sent as.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ediff)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-diff)
(require 'ecc-window)
(require 'ecc-review)

;;;; The two trees a review compares

(defun ecc-review-ediff--tree (root spec)
  "Return the tree of the revision SPEC in ROOT, or nil."
  (pcase (ecc-review--git root "rev-parse" "--verify" "--quiet"
                          (concat spec "^{tree}"))
    (`(0 . ,output)
     (let ((tree (string-trim output)))
       (and (not (string-empty-p tree)) tree)))))

(defun ecc-review-ediff--merge-base (root left right)
  "Return the merge base of LEFT and RIGHT in ROOT, or nil."
  (pcase (ecc-review--git root "merge-base" left right)
    (`(0 . ,output)
     (let ((commit (string-trim output)))
       (and (not (string-empty-p commit)) commit)))))

(defun ecc-review-ediff--trees (root range)
  "Return (LEFT . RIGHT), the two trees RANGE names in ROOT.
RANGE is what `ecc-review-worktree\\=' is given: a revision like
\"HEAD\", a range like \"main...HEAD\" or \"a..b\", or the empty string
for what is not staged yet.  A revision is compared with the working
tree as it stands, so what git does not track is in the review as
well; a range is two trees of the history and nothing else.  Signals a
`user-error\\=' when git cannot resolve it."
  (let* ((fail (lambda ()
                 (user-error "Git cannot diff against %S in %s"
                             range (abbreviate-file-name root))))
         (side (lambda (spec)
                 (or (ecc-review-ediff--tree root spec) (funcall fail))))
         (now (lambda ()
                (or (ecc-review-snapshot root)
                    (user-error "Cannot read the working tree of %s"
                                (abbreviate-file-name root))))))
    (cond
     ;; What is not staged yet: the index against the working tree.
     ((or (null range) (string-empty-p range))
      (cons (or (ecc-review-snapshot root t) (funcall fail)) (funcall now)))
     ((string-match "\\`\\(.*?\\)\\.\\.\\.\\(.*\\)\\'" range)
      (let* ((left (or (match-string 1 range) ""))
             (right (or (match-string 2 range) ""))
             (left (if (string-empty-p left) "HEAD" left))
             (right (if (string-empty-p right) "HEAD" right))
             (base (or (ecc-review-ediff--merge-base root left right)
                       (funcall fail))))
        (cons (funcall side base) (funcall side right))))
     ((string-match "\\`\\(.*?\\)\\.\\.\\(.*\\)\\'" range)
      (let ((left (or (match-string 1 range) ""))
            (right (or (match-string 2 range) "")))
        (cons (funcall side (if (string-empty-p left) "HEAD" left))
              (funcall side (if (string-empty-p right) "HEAD" right)))))
     ;; A repository with no commit has no HEAD, and git calls that a
     ;; bad revision rather than an empty comparison.  The empty tree is
     ;; what HEAD would mean there, the way the diff review reads it.
     ((and (equal range "HEAD") (ecc-review--unborn-p root))
      (cons (or (ecc-review--empty-tree root) (funcall fail)) (funcall now)))
     (t (cons (funcall side range) (funcall now))))))

;;;; The pairs

(defun ecc-review-ediff--tree-file (root tree path)
  "Return what PATH holds in the tree TREE of ROOT, or nil.
Nil is a file the tree does not name: one side of a file that was
created, or of one that was deleted."
  (pcase (ecc-review--git root "show" (concat tree ":" path))
    (`(0 . ,output) output)))

(defun ecc-review-ediff-pairs (root left right &optional paths)
  "Return what differs between the trees LEFT and RIGHT of ROOT.
PATHS, relative to ROOT, restrict the comparison.  The result is a list
of (PATH BEFORE AFTER NOTE) in the order git reports, where BEFORE and
AFTER are what the two trees hold and NOTE, when non-nil, says why
neither is there: a file git calls binary, or one too large for
`ecc-review-max-bytes\\=', is named and not shown.  Both sides being
empty, such a file is no difference at all and only its separator line
is read, which is where the note is put."
  (let ((pairs nil))
    (pcase-dolist (`(,path . ,binary) (ecc-review--numstat root left right paths))
      (let* ((before (unless binary (ecc-review-ediff--tree-file root left path)))
             (after (unless binary (ecc-review-ediff--tree-file root right path)))
             (size (max (string-bytes (or before "")) (string-bytes (or after ""))))
             (note (cond (binary "binary, not shown")
                         ((> size ecc-review-max-bytes)
                          (format "%s, not shown"
                                  (file-size-human-readable size))))))
        (push (list path
                    (if note "" (or before ""))
                    (if note "" (or after ""))
                    note)
              pairs)))
    (nreverse pairs)))

;;;; The two buffers

(defvar-local ecc-review-ediff--sections nil
  "Where each file begins, as (PATH BASE-LINE NOW-LINE).
The lines are those of the separator line in the two buffers, in the
order the files were written out.  Buffer-local in the ediff control
buffer.")

(defvar-local ecc-review-ediff--comments nil
  "The comments of this review, as (DIFFERENCE TEXT OVERLAY).
DIFFERENCE is ediff's own number, counting from 0; OVERLAY shows TEXT
under the difference in the buffer of what the files hold now.")

(defvar-local ecc-review-ediff--buffers nil
  "The (BASE . NOW) buffers this control buffer compares.")

(defvar-local ecc-review-ediff--windows nil
  "The window configuration to put back when this review is quit.")

(defun ecc-review-ediff-buffer-name (session side)
  "Return the name of the SIDE buffer of the ediff review of SESSION.
SIDE is `base' for what the files held and `now' for what they hold."
  (format "*ecc-review-%s: %s*" side (ecc-session-name session)))

(defvar ecc-review-ediff-fontify t
  "Non-nil colours the code of a review the way its major mode would.
The two buffers hold many files at once and no one major mode fits
them, so each file is fontified on its own in a temporary buffer and
the faces are carried in as text properties.  That is how this package
works anyway: faces are put on at insertion time and no buffer of ours
runs font-lock.  Nil leaves the text plain, which is what it was.")

(defun ecc-review-ediff--fontify (text path)
  "Return TEXT with the faces the major mode of PATH would give it.
Mode hooks are not run: a file of the review is read, never edited, and
a hook that starts a language server or asks a question has no business
in a buffer that exists to be diffed.  Anything the mode raises leaves
the text as it came."
  (if (or (not ecc-review-ediff-fontify) (null text) (string-empty-p text))
      text
    (condition-case nil
        (with-temp-buffer
          (insert text)
          (let ((buffer-file-name (expand-file-name path))
                (enable-local-variables nil)
                (inhibit-message t))
            (delay-mode-hooks (set-auto-mode)))
          ;; `font-lock-ensure' does nothing where font-lock is off, and
          ;; a batch Emacs has it off.
          (font-lock-mode 1)
          (font-lock-ensure)
          (buffer-string))
      (error text))))

(defun ecc-review-ediff--separator (path note)
  "Return the line that opens PATH in both buffers, saying NOTE if any."
  (format "═══ %s ═══" (if note (format "%s (%s)" path note) path)))

(defvar ecc-review-ediff-split-window-function #'split-window-horizontally
  "How an ediff review splits the window between its two sides.
Left and right by default: a review is read line against line, and
ediff\='s own default of one above the other puts a screen of air
between the two halves of a change.  It is set in the control buffer of
the review alone, so the ediff of anything else keeps the layout
`ediff-split-window-function\=' asks for; nil here leaves the review
with that layout too.

Where the control panel goes is `ediff-window-setup-function\=', which
this package does not touch: a graphical Emacs gives it a small frame
of its own, a terminal a window of the same frame, and
`ediff-toggle-multiframe\=' switches between the two.")

(defvar ecc-review-ediff-file-spacing 1
  "Blank lines put in front of each file but the first of an ediff review.
The separator line alone runs the files together where one ends and the
next begins; a line of air says at a glance that this is another file.
The blank lines are the same on both sides, so they are no difference of
their own, and they belong to the file above -- a deletion at the end of
one still reads against that file and not the next.")

(defun ecc-review-ediff--insert (buffer separator text)
  "Append SEPARATOR and TEXT to BUFFER and return the line of SEPARATOR.
`ecc-review-ediff-file-spacing\=' blank lines go in front of it unless
BUFFER is still empty.  TEXT is given a closing newline when it lacks
one, so that what follows starts a line of its own."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (= (point-min) (point-max))
        (insert (make-string (max 0 ecc-review-ediff-file-spacing) ?\n)))
      (prog1 (line-number-at-pos (point))
        ;; No font-lock in a buffer of this package: the face goes on
        ;; the text as it is inserted.
        (insert (propertize separator 'face 'ecc-heading-face) "\n")
        (unless (string-empty-p text)
          (insert text)
          (unless (bolp) (insert "\n")))))))

(defvar ecc-review-ediff-diff-faces t
  "Non-nil marks every difference the way the diff review marks a hunk.
ediff paints the differences it is not standing on with
`ediff-odd-diff-A\=' and its relatives, which a good many themes leave
near enough invisible: the one this was found on gives them a shade of
the background and no foreground at all, so a review of six changes
showed one of them (2026-09-16).

Non-nil remaps those faces, in the two buffers of the review alone, to
`diff-removed\=' on the left and `diff-added\=' on the right -- the faces
the diff review already reads by, so the colours are the theme\='s own
and no other ediff is touched.  The difference ediff is standing on
keeps `ediff-current-diff-A\=' and `-B\='.")

(defun ecc-review-ediff--mark-differences (base now)
  "Give BASE and NOW the colours a diff is read by, if that is wanted."
  (when ecc-review-ediff-diff-faces
    (with-current-buffer base
      (face-remap-add-relative 'ediff-odd-diff-A 'diff-removed)
      (face-remap-add-relative 'ediff-even-diff-A 'diff-removed))
    (with-current-buffer now
      (face-remap-add-relative 'ediff-odd-diff-B 'diff-added)
      (face-remap-add-relative 'ediff-even-diff-B 'diff-added))))

(defun ecc-review-ediff--build (session pairs)
  "Fill the two buffers of SESSION with PAIRS and return (BASE NOW SECTIONS)."
  (let ((base (get-buffer-create (ecc-review-ediff-buffer-name session 'base)))
        (now (get-buffer-create (ecc-review-ediff-buffer-name session 'now)))
        (sections nil))
    (dolist (buffer (list base now))
      (with-current-buffer buffer
        (fundamental-mode)
        (let ((inhibit-read-only t))
          (erase-buffer))))
    (pcase-dolist (`(,path ,before ,after ,note) pairs)
      (let ((separator (ecc-review-ediff--separator path note)))
        (push (list path
                    (ecc-review-ediff--insert
                     base separator (ecc-review-ediff--fontify before path))
                    (ecc-review-ediff--insert
                     now separator (ecc-review-ediff--fontify after path)))
              sections)))
    (dolist (buffer (list base now))
      (with-current-buffer buffer
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (ecc-review-ediff--mark-differences base now)
    (list base now (nreverse sections))))

(defun ecc-review-ediff--section-at (sections line side)
  "Return the section of SECTIONS that LINE falls in on SIDE.
SIDE is 1 for the buffer of what the files held and 2 for the buffer of
what they hold now."
  (let ((found (car sections)))
    (dolist (section sections)
      (when (<= (nth side section) line)
        (setq found section)))
    found))

;;;; A difference as a comment plist

(defun ecc-review-ediff--difference (n control)
  "Return difference N of the review in CONTROL as a comment plist.
The plist is the one `ecc-review-format-message\\=' takes, minus its
:comment, so that the prompt an ediff review sends reads exactly like
the prompt the diff review sends.  :position is N."
  (with-current-buffer control
    (let* ((base (car ecc-review-ediff--buffers))
           (now (cdr ecc-review-ediff--buffers))
           (a-beg (ediff-get-diff-posn 'A 'beg n control))
           (a-end (ediff-get-diff-posn 'A 'end n control))
           (b-beg (ediff-get-diff-posn 'B 'beg n control))
           (b-end (ediff-get-diff-posn 'B 'end n control))
           (a-text (with-current-buffer base
                     (buffer-substring-no-properties a-beg a-end)))
           (b-text (with-current-buffer now
                     (buffer-substring-no-properties b-beg b-end)))
           (a-line (with-current-buffer base (line-number-at-pos a-beg)))
           (b-line (with-current-buffer now (line-number-at-pos b-beg)))
           ;; A side with no line sits at the beginning of the line after
           ;; the difference, which for a deletion at the end of a file is
           ;; the separator of the next one.  The side that has lines is
           ;; the one that says which file this is.
           (section (if (string-empty-p b-text)
                        (ecc-review-ediff--section-at
                         ecc-review-ediff--sections a-line 1)
                      (ecc-review-ediff--section-at
                       ecc-review-ediff--sections b-line 2)))
           (a-start (max 1 (- a-line (nth 1 section))))
           (b-start (max 1 (- b-line (nth 2 section))))
           (b-count (seq-count (lambda (c) (eq c ?\n)) b-text))
           (text (string-trim-right
                  (substring-no-properties
                   (ecc-diff-format-hunks
                    (ecc-diff-hunks (ecc-diff-lines a-text b-text)
                                    0 a-start b-start)))
                  "\n")))
      (list :path (car section)
            :start b-start
            :end (if (> b-count 0) (+ b-start b-count -1) b-start)
            :header (car (split-string text "\n"))
            :text text
            :position n))))

;;;; Comments

(defun ecc-review-ediff--entry (n)
  "Return the comment of difference N in this control buffer, or nil."
  (assq n ecc-review-ediff--comments))

(defun ecc-review-ediff--attach (n text)
  "Show TEXT under difference N and return its overlay."
  (let* ((control (current-buffer))
         (now (cdr ecc-review-ediff--buffers))
         (end (ediff-get-diff-posn 'B 'end n control)))
    (with-current-buffer now
      (let ((overlay (make-overlay end end nil t nil)))
        (overlay-put overlay 'after-string
                     (propertize (concat "  ▎ "
                                         (string-replace "\n" "\n  ▎ " text)
                                         "\n")
                                 'face 'ecc-review-comment-face))
        overlay))))

(defun ecc-review-ediff--detach (entry)
  "Remove the comment ENTRY from this control buffer."
  (when-let* ((overlay (nth 2 entry)))
    (delete-overlay overlay))
  (setq ecc-review-ediff--comments
        (delq entry ecc-review-ediff--comments)))

(defun ecc-review-ediff-comment (text)
  "Attach the comment TEXT to the difference ediff is on.
An earlier comment on the same difference is replaced; interactively it
is offered for editing."
  (interactive
   (progn
     (unless (and (boundp 'ediff-current-difference)
                  (>= ediff-current-difference 0))
       (user-error "Not on a difference"))
     (list (read-string "Comment on this difference: "
                        (cadr (ecc-review-ediff--entry ediff-current-difference))))))
  (unless (>= ediff-current-difference 0)
    (user-error "Not on a difference"))
  (when (string-empty-p (string-trim text))
    (user-error "Empty comment"))
  (let ((n ediff-current-difference)
        (text (string-trim text)))
    (when-let* ((old (ecc-review-ediff--entry n)))
      (ecc-review-ediff--detach old))
    (push (list n text (ecc-review-ediff--attach n text))
          ecc-review-ediff--comments)
    (message "Comment attached (%d in all)" (length ecc-review-ediff--comments))))

(defun ecc-review-ediff-remove-comment ()
  "Remove the comment of the difference ediff is on."
  (interactive)
  (ecc-review-ediff--detach
   (or (and (>= ediff-current-difference 0)
            (ecc-review-ediff--entry ediff-current-difference))
       (user-error "No comment on this difference")))
  (message "Comment removed (%d left)" (length ecc-review-ediff--comments)))

(defun ecc-review-ediff-comments ()
  "Return the comments of this review in the order of the differences.
This is what `ecc-review--comments-function\\=' is set to, so that the
prompt is built and sent by `ecc-review.el\\=' either way."
  (let ((control (current-buffer)))
    (mapcar (lambda (entry)
              (append (ecc-review-ediff--difference (car entry) control)
                      (list :comment (cadr entry))))
            (seq-sort-by #'car #'< ecc-review-ediff--comments))))

(defun ecc-review-ediff-list-comments ()
  "Pick one of the comments and move to its difference."
  (interactive)
  (let* ((comments (or (ecc-review-ediff-comments) (user-error "No comment yet")))
         (labels (mapcar #'ecc-review--comment-label comments))
         (choice (completing-read "Comment: " labels nil t))
         (comment (nth (seq-position labels choice) comments)))
    ;; ediff counts the differences from 1 where it is asked for one.
    (ediff-jump-to-difference (1+ (plist-get comment :position)))))

(defun ecc-review-ediff-copy-refused ()
  "Say why `a\\=' and `b\\=' do nothing in a review.
They are ediff\\='s copy commands, and both sides of a review are
read-only: a review reads, comments and sends, and what changes the
files is Claude, from the prompt the comments go out as.  Left to
ediff they signalled `buffer-read-only\\=' against a buffer the user had
not asked about."
  (interactive)
  (message
   "A review reads; C-c C-c sends the comments and Claude makes the changes"))

;;;; The help ? shows

;; ediff's own help is written for the ediff a two-way comparison
;; usually is: it offers a and b, rx, wx and wd and ~, none of which do
;; anything here -- both buffers are read-only and the two sides are
;; every file of the review at once -- and it says nothing of c, d, l,
;; C-c C-c and C-c C-k, or that q closes a review without asking.  The
;; layout below is ediff's, so that ? still looks like ediff's help,
;; with only the commands this review really has on it.

(defconst ecc-review-ediff-long-help-message
  "    Move around      |      Toggle features      |       Your comments
=====================|===========================|=============================
p,DEL -previous diff |     | -vert/horiz split   |      c -comment on this diff
    n,SPC -next diff |         h -highlighting   |       d -remove that comment
     j -jump to diff |      @ -auto-refinement   |         l -list the comments
       C-l -recenter |        * -refine region   |   C-c C-c -send the comments
   v/V -scroll up/dn |   ## -ignore whitespace   |     C-c C-k -drop the review
   </> -scroll lt/rt |         #c -ignore case   |          q -close the review
                     |         m -wide display   |
=====================|===========================|=============================
    i -status info   |     ? -help off           |
-------------------------------------------------------------------------------
Both buffers are read-only: a review reads, comments and sends, and writes
nothing.  Claude changes the files, from the prompt the comments are sent as."
  "What `?\\=' shows in the control panel of an ediff review.")

(defconst ecc-review-ediff-brief-help-message
  " c -comment   C-c C-c -send   q -quit   ? -help"
  "What the control panel of an ediff review says with the help off.")

(defun ecc-review-ediff--long-help-message ()
  "Return the long help of an ediff review.
This is what `ediff-long-help-message-function\\=' is set to."
  ecc-review-ediff-long-help-message)

(defun ecc-review-ediff--brief-help-message ()
  "Return the brief help of an ediff review.
This is what `ediff-brief-help-message-function\\=' is set to."
  ecc-review-ediff-brief-help-message)

;;;; Opening and closing

(defvar ecc-review-ediff-full-frame t
  "Non-nil gives the review the whole frame it opens in.
Two texts side by side want the width: sharing the frame with the
sidebar and a transcript or two leaves each side too narrow to read a
line of code in.  The windows that were there are put back when the
review is quit, the same way the rest of the arrangement is.

Nil opens the review among whatever is on the screen, which is what
`ediff-buffers\=' would do on its own.")

(defun ecc-review-ediff--take-the-frame ()
  "Leave one window in this frame, for the review to be laid out in.
Side windows are taken down too -- a sidebar beside a two-column diff
is the width that was wanted for the code -- and come back with the
rest when the review is quit.  A frame that will not give up its
windows is left as it is rather than made an error of."
  (when-let* ((window (seq-find (lambda (window)
                                  (not (window-parameter window 'window-side)))
                                (window-list nil 'no-minibuffer))))
    (select-window window)
    (condition-case nil
        (let ((ignore-window-parameters t))
          (delete-other-windows window))
      (error nil))))

(defun ecc-review-ediff--on-quit ()
  "Take the review down: ediff's own cleanup, the buffers, the windows.
Run from `ediff-quit-hook\\=' in the control buffer, which
`ediff-cleanup-mess\\=' then kills, so what is needed afterwards is read
first."
  (let ((buffers ecc-review-ediff--buffers)
        (windows ecc-review-ediff--windows))
    (ediff-cleanup-mess)
    (dolist (buffer (list (car buffers) (cdr buffers)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (when (window-configuration-p windows)
      (set-window-configuration windows))))

(defun ecc-review-ediff-quit (control)
  "Quit the ediff review in CONTROL, which closes it and its buffers.
This is what `ecc-review--close-function\\=' is set to: a review that
laid out its own windows puts them back rather than being killed."
  (when (buffer-live-p control)
    (with-current-buffer control
      (ediff-really-quit nil))))

(defun ecc-review-ediff-open (session base now sections &optional range)
  "Compare BASE and NOW as the review of SESSION and return the control buffer.
SECTIONS says where each file begins, and RANGE what a working tree
review is against.  `ecc-window-hide-on-review\\=' is honoured before
ediff lays out its windows; quitting puts back what was on the screen."
  (ecc-window-hide-for-review session)
  (let ((windows (current-window-configuration))
        (control nil))
    (when ecc-review-ediff-full-frame
      (ecc-review-ediff--take-the-frame))
    (ediff-buffers
     base now
     (list
      (lambda ()
        (setq control (current-buffer))
        (setq-local ecc-review--session session
                    ecc-render--session session
                    ecc-review--range range
                    ecc-review-ediff--sections sections
                    ecc-review-ediff--comments nil
                    ecc-review-ediff--buffers (cons base now)
                    ecc-review-ediff--windows windows
                    ecc-review--comments-function #'ecc-review-ediff-comments
                    ecc-review--close-function #'ecc-review-ediff-quit
                    ediff-quit-hook (list #'ecc-review-ediff--on-quit))
        ;; Both of these are read out of the control buffer of this
        ;; session as well (`ediff-defvar-local'), so no other ediff's ?
        ;; changes.
        (setq-local ediff-long-help-message-function
                    #'ecc-review-ediff--long-help-message
                    ediff-brief-help-message-function
                    #'ecc-review-ediff--brief-help-message)
        ;; ediff reads this one out of the control buffer of each session
        ;; (`ediff-wind.el'), which is why the review can be laid out its
        ;; own way without touching how the user's other ediffs look.
        (when ecc-review-ediff-split-window-function
          (setq-local ediff-split-window-function
                      ecc-review-ediff-split-window-function))
        ;; `ediff-setup' lays out the windows and writes the help into
        ;; the panel before it runs these hooks, so both are done again
        ;; here: the review would otherwise open in ediff's own layout,
        ;; under ediff's own help, and turn into this one at the first
        ;; command that recentres.  It is the call `ediff-toggle-split'
        ;; and `ediff-toggle-help' both make for the same reason.
        (ediff-recenter)
        ;; `ediff-mode-map' is local to this control buffer, so these
        ;; keys reach no other ediff session.  None of them is one a
        ;; two-way comparison already uses.
        (define-key ediff-mode-map (kbd "c") #'ecc-review-ediff-comment)
        (define-key ediff-mode-map (kbd "d") #'ecc-review-ediff-remove-comment)
        (define-key ediff-mode-map (kbd "l") #'ecc-review-ediff-list-comments)
        (define-key ediff-mode-map (kbd "C-c C-c") #'ecc-review-send)
        (define-key ediff-mode-map (kbd "C-c C-k") #'ecc-review-quit)
        ;; ediff's own q asks whether to quit this session, and the
        ;; question goes to a minibuffer the control frame does not have
        ;; -- on a graphical Emacs the panel is a frame of its own, small
        ;; enough to show nothing, so q read as a key that did nothing at
        ;; all (reported 2026-09-16).  A review is closed, not saved:
        ;; there is nothing to lose by the question and nothing to ask.
        (define-key ediff-mode-map (kbd "q") #'ecc-review-quit)
        ;; mouse-2 and RET over a line of the help look the command up
        ;; in the ediff manual, which knows nothing of c, d or l and
        ;; answers them with "Undocumented command!".  Silenced rather
        ;; than pointed somewhere else: what the ECC keys do is on the
        ;; help itself, and the manual has nothing to add about the
        ;; ediff ones that a review uses.
        (define-key ediff-mode-map [mouse-2] #'ignore)
        (define-key ediff-mode-map (kbd "RET") #'ignore)
        ;; ediff's own copy commands.  Both sides of a review are
        ;; read-only, so they could only fail, and they failed as
        ;; `ediff-copy-diff: buffer-read-only' -- an error about a
        ;; buffer the user never asked about, from a key the help does
        ;; not offer.  They say what a review is instead.
        (define-key ediff-mode-map (kbd "a") #'ecc-review-ediff-copy-refused)
        (define-key ediff-mode-map (kbd "b") #'ecc-review-ediff-copy-refused))))
    control))

(defun ecc-review-ediff-buffer (session &optional paths)
  "Open everything SESSION changed as one ediff and return the control buffer.
PATHS restricts it to those files.  This is `ecc-review-buffer\\=' laid
out side by side: the same baseline, the same working tree snapshot and
the same errors."
  (let* ((root (or (ecc-review-git-root (or (ecc-session-project-root session)
                                            default-directory))
                   (user-error "%s is not in a git repository"
                               (abbreviate-file-name
                                (or (ecc-session-project-root session)
                                    default-directory)))))
         (base (or (ecc-session-baseline session)
                   (ecc-review--head-tree root)
                   (user-error "Cannot read the history of %s"
                               (abbreviate-file-name root))))
         (now (or (ecc-review-snapshot root)
                  (user-error "Cannot read the working tree of %s"
                              (abbreviate-file-name root))))
         (pairs (ecc-review-ediff-pairs root base now paths)))
    (unless pairs
      (user-error "Nothing has changed in %s since this session started"
                  (abbreviate-file-name root)))
    (pcase-let ((`(,a ,b ,sections) (ecc-review-ediff--build session pairs)))
      (ecc-review-ediff-open session a b sections))))

(defun ecc-review-ediff-worktree-buffer (session &optional range root)
  "Open the working tree of ROOT as one ediff and return the control buffer.
The comments go to SESSION.  RANGE defaults to
`ecc-review-worktree-default-range\\='.  This is
`ecc-review-worktree-buffer\\=' laid out side by side."
  (let* ((range (or range ecc-review-worktree-default-range))
         (directory (or root (ecc-session-project-root session)))
         (root (or (ecc-review-git-root directory)
                   (user-error "%s is not in a git repository"
                               (abbreviate-file-name directory))))
         (trees (ecc-review-ediff--trees root range))
         (pairs (ecc-review-ediff-pairs root (car trees) (cdr trees))))
    (unless pairs
      (user-error "No change against %s in %s"
                  (if (string-empty-p range) "the index" range)
                  (abbreviate-file-name root)))
    (pcase-let ((`(,a ,b ,sections) (ecc-review-ediff--build session pairs)))
      (ecc-review-ediff-open session a b sections range))))

(provide 'ecc-review-ediff)

;;; ecc-review-ediff.el ends here
