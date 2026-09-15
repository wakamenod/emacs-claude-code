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
;; for text that the content itself could hold.
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

(defun ecc-review-ediff--separator (path note)
  "Return the line that opens PATH in both buffers, saying NOTE if any."
  (format "═══ %s ═══" (if note (format "%s (%s)" path note) path)))

(defun ecc-review-ediff--insert (buffer separator text)
  "Append SEPARATOR and TEXT to BUFFER and return the line of SEPARATOR.
TEXT is given a closing newline when it lacks one, so that the next
separator starts a line of its own."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (prog1 (line-number-at-pos (point))
        ;; No font-lock in a buffer of this package: the face goes on
        ;; the text as it is inserted.
        (insert (propertize separator 'face 'ecc-heading-face) "\n")
        (unless (string-empty-p text)
          (insert text)
          (unless (bolp) (insert "\n")))))))

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
                    (ecc-review-ediff--insert base separator before)
                    (ecc-review-ediff--insert now separator after))
              sections)))
    (dolist (buffer (list base now))
      (with-current-buffer buffer
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
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

;;;; Opening and closing

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
        ;; `ediff-mode-map' is local to this control buffer, so these
        ;; keys reach no other ediff session.  None of them is one a
        ;; two-way comparison already uses.
        (define-key ediff-mode-map (kbd "c") #'ecc-review-ediff-comment)
        (define-key ediff-mode-map (kbd "d") #'ecc-review-ediff-remove-comment)
        (define-key ediff-mode-map (kbd "l") #'ecc-review-ediff-list-comments)
        (define-key ediff-mode-map (kbd "C-c C-c") #'ecc-review-send)
        (define-key ediff-mode-map (kbd "C-c C-k") #'ecc-review-quit))))
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
