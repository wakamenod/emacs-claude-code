;;; ecc-review.el --- Reviewing what Claude changed, hunk by hunk  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The main way of working the requirements describe: let Claude change
;; things, then open every change of the session as one diff, walk the
;; hunks, attach a comment to the ones that need work and send all the
;; comments as a single prompt.
;;
;; The diff of a file git tracks is what `git diff' says; a file outside
;; a repository, or not yet added to one, is diffed against what it was
;; before the first change of the session (`ecc-file-entry-original').
;; The buffer is a read-only `diff-mode', so n, p and RET are the usual
;; ones.
;;
;; The same buffer reviews one proposal before it is applied: a comment
;; on the diff of a pending Edit or Write goes back as the message of
;; the deny, and `ecc-review-edit-proposal' changes the text of the
;; proposal and allows it with the new text.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'diff-mode)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-window)

(defvar ecc-review-git-executable "git"
  "The git program the review runs for `git diff'.")

(defvar ecc-review-header
  "Review comments on the changes below.  Please act on each of them."
  "First line of the prompt the review comments are sent as.")

(defvar ecc-review-proposal-header
  "Review comments on the proposal below.  Please act on each of them and propose it again."
  "First line of the deny message built from comments on a proposal.")

(defcustom ecc-review-context-lines 3
  "Lines of context around a change in a diff the review makes itself."
  :type 'integer
  :group 'ecc)

(defface ecc-review-comment-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face of a comment shown under the hunk it belongs to."
  :group 'ecc)

(defface ecc-review-commented-hunk-face
  '((t :inherit diff-hunk-header :weight bold))
  "Face of the header of a hunk that carries a comment."
  :group 'ecc)

;;;; Which files

(defun ecc-review-files (session &optional paths)
  "Return the file entries of SESSION that were edited or written.
When PATHS is given only those files are returned, in the order of
PATHS.  Entries only read are left out."
  (let ((changed (seq-filter (lambda (entry)
                               (> (+ (ecc-file-entry-edits entry)
                                     (ecc-file-entry-writes entry))
                                  0))
                             (ecc-model-files session))))
    (if paths
        (delq nil (mapcar (lambda (path)
                            (seq-find (lambda (entry)
                                        (equal (ecc-file-entry-path entry) path))
                                      changed))
                          paths))
      changed)))

;;;; Git

(defun ecc-review--git (directory &rest args)
  "Run git with ARGS in DIRECTORY and return (EXIT-CODE . OUTPUT).
Returns nil when git cannot be run at all."
  (when (executable-find ecc-review-git-executable)
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory)))
        (condition-case err
            (cons (apply #'call-process ecc-review-git-executable nil
                         (list t nil) nil args)
                  (buffer-string))
          (file-error (ecc-log "review" "git failed: %s" (error-message-string err))
                      nil))))))

(defun ecc-review-git-root (path)
  "Return the root of the git repository holding PATH, or nil."
  (let ((directory (file-name-directory (expand-file-name path))))
    (when (file-directory-p directory)
      (pcase (ecc-review--git directory "rev-parse" "--show-toplevel")
        (`(0 . ,output)
         (let ((root (string-trim output)))
           (and (not (string-empty-p root))
                (file-name-as-directory (expand-file-name root)))))))))

(defun ecc-review--relative (path root)
  "Return PATH relative to the repository ROOT, through symbolic links.
git reports its root with links resolved, so PATH is resolved too."
  (file-relative-name (file-truename path) root))

(defun ecc-review-git-tracked (root paths)
  "Return the members of PATHS that git tracks in the repository at ROOT.
PATHS are absolute; the result keeps their order."
  (pcase (apply #'ecc-review--git root "ls-files" "-z" "--"
                (mapcar (lambda (path) (ecc-review--relative path root)) paths))
    (`(0 . ,output)
     (let ((tracked (split-string output "\0" t)))
       (seq-filter (lambda (path)
                     (member (ecc-review--relative path root) tracked))
                   paths)))))

(defun ecc-review-git-diff (root paths)
  "Return the unified diff git reports for PATHS under ROOT, or nil.
The diff is against the index, the way `git diff' works, with a/ and
b/ prefixes on the file names relative to ROOT."
  (pcase (apply #'ecc-review--git root "diff" "--no-color" "--no-ext-diff" "--"
                (mapcar (lambda (path) (ecc-review--relative path root)) paths))
    (`(0 . ,output)
     (and (not (string-empty-p output)) output))
    (result
     (ecc-log "review" "git diff failed in %s: %S" root result)
     nil)))

;;;; A diff made from what the session recorded

(defun ecc-review--current-content (entry)
  "Return what the file of ENTRY holds now: the file, else the last snapshot."
  (or (ecc-diff-file-content (ecc-file-entry-path entry))
      (ecc-file-entry-snapshot entry)))

(defun ecc-review--file-header (path &optional new-file)
  "Return the ---/+++ lines naming PATH, from /dev/null when NEW-FILE."
  (format "--- %s\n+++ %s\n" (if new-file "/dev/null" path) path))

(defun ecc-review-fallback-diff (entry)
  "Return the diff of the file of ENTRY over the session, or nil.
The whole file before the first change is compared with the file now;
when the start is not known, the changes are shown one after the other
from what the CLI reported for each (files git does not track)."
  (let* ((path (ecc-file-entry-path entry))
         (original (ecc-file-entry-original entry))
         (current (ecc-review--current-content entry))
         (body
          (cond
           ((and (eq original 'unknown) (null (ecc-file-entry-hunks entry))) nil)
           ((eq original 'unknown)
            (let ((patches (ecc-file-entry-patches entry))
                  (parts nil))
              (dolist (hunk (ecc-file-entry-hunks entry))
                (push (cond ((and (car patches) (> (length (car patches)) 0))
                             (ecc-diff-from-patch (car patches)))
                            ((null (car hunk)) (ecc-diff-for-write (cdr hunk) nil))
                            (t (ecc-diff-render (car hunk) (cdr hunk)
                                                ecc-review-context-lines)))
                      parts)
                (setq patches (cdr patches)))
              (let ((text (string-join (delq nil (nreverse parts)) "")))
                (and (not (string-empty-p text)) text))))
           ((null current) nil)
           ((null original) (ecc-diff-for-write current nil))
           (t (ecc-diff-render original current ecc-review-context-lines)))))
    (when body
      (concat (ecc-review--file-header path (null original))
              (substring-no-properties body)))))

(defun ecc-review-diff-text (entries)
  "Return the diff of the files of ENTRIES as one unified diff, or nil.
Files git tracks are diffed by git, one call per repository; the rest
are diffed from what the session recorded.  Returns (TEXT . ROOT)
where ROOT is the repository the git part is relative to, when there
is one."
  (let ((groups nil)                    ; (root . paths), in order of appearance
        (roots (make-hash-table :test #'equal))
        (parts nil)
        (git-root nil))
    (dolist (entry entries)
      (let* ((path (expand-file-name (ecc-file-entry-path entry)))
             (root (or (gethash (file-name-directory path) roots)
                       (puthash (file-name-directory path)
                                (or (ecc-review-git-root path) 'none)
                                roots))))
        (if (eq root 'none)
            (push (cons entry nil) parts)
          (let ((group (assoc root groups)))
            (if group
                (setcdr group (append (cdr group) (list entry)))
              (setq groups (append groups (list (list root entry)))))))))
    (let ((texts nil))
      (dolist (group groups)
        (let* ((root (car group))
               (tracked (ecc-review-git-tracked
                         root (mapcar (lambda (e) (expand-file-name (ecc-file-entry-path e)))
                                      (cdr group)))))
          (when tracked
            (unless git-root (setq git-root root))
            (when-let* ((diff (ecc-review-git-diff root tracked)))
              (push diff texts)))
          (dolist (entry (cdr group))
            (unless (member (expand-file-name (ecc-file-entry-path entry)) tracked)
              (push (cons entry nil) parts)))))
      (dolist (part (nreverse parts))
        (when-let* ((diff (ecc-review-fallback-diff (car part))))
          (push diff texts)))
      (let ((text (string-join (nreverse texts) "")))
        (and (not (string-empty-p text))
             (cons text git-root))))))

;;;; The buffer

(defvar-local ecc-review--session nil
  "The session this review buffer belongs to.")

(defvar-local ecc-review--request nil
  "The pending request this buffer reviews, or nil for a review of files.")

(defvar-local ecc-review--paths nil
  "The files this review was restricted to, or nil for every changed file.")

(defvar-local ecc-review--comments nil
  "Overlays of the hunk comments, in no particular order.")

(defvar ecc-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'ecc-review-comment)
    (define-key map (kbd "l") #'ecc-review-list-comments)
    (define-key map (kbd "d") #'ecc-review-remove-comment)
    (define-key map (kbd "C-c C-c") #'ecc-review-send)
    (define-key map (kbd "C-c C-k") #'ecc-review-quit)
    (define-key map (kbd "e") #'ecc-review-edit-proposal)
    (define-key map (kbd "g") #'ecc-review-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap of `ecc-review-mode\='.
The buffer is read-only, so a letter is free to be a command, and these
come before `diff-mode-shared-map\=' -- which uses only k, K, n, N, o,
p and P.  Nothing here takes a \\`C-c <letter>\=' key: the Emacs Lisp
manual reserves those for users.  \\`C-c C-c\=' and \\`C-c C-k\=' shadow
`diff-mode\=', deliberately: finishing and aborting are what those two
mean everywhere in Emacs.")

(define-derived-mode ecc-review-mode diff-mode "Claude-Review"
  "Major mode of the buffer the changes of a session are reviewed in.

\\{ecc-review-mode-map}"
  :interactive nil
  (setq buffer-read-only t)
  ;; While the buffer is read-only the review keys come first, then the
  ;; keys `diff-mode' gives a read-only buffer (n, p, RET, ...), which
  ;; not every Emacs installs by itself.
  (setq-local minor-mode-overriding-map-alist
              (append (list (cons 'buffer-read-only ecc-review-mode-map)
                            (cons 'buffer-read-only diff-mode-shared-map))
                      (seq-remove (lambda (entry)
                                    (memq (cdr entry)
                                          (list ecc-review-mode-map diff-mode-shared-map)))
                                  minor-mode-overriding-map-alist)))
  (setq header-line-format '(:eval (ecc-review--header-line))))

(defun ecc-review-buffer-name (session &optional request)
  "Return the name of the review buffer of SESSION.
With REQUEST it is the buffer reviewing that one proposal."
  (if request
      (format "*ecc-review: %s (proposal)*" (ecc-session-name session))
    (format "*ecc-review: %s*" (ecc-session-name session))))

(defun ecc-review--header-line ()
  "Return the header line of the review buffer."
  (ecc--mode-line-escape
   (concat
   (propertize (format " %s: %s"
                       (if ecc-review--request "Proposal review" "Review")
                       (if ecc-review--session
                           (ecc-session-name ecc-review--session)
                         "?"))
               'face 'ecc-heading-face)
   (propertize (format "  ·  comments: %d" (length (ecc-review-comment-overlays)))
               'face 'ecc-dim-face)
   (propertize (if ecc-review--request
                   "  ·  c comment  e edit and apply  C-c C-c send as deny  n/p hunk  RET source"
                 "  ·  c comment  C-c l list  C-c d delete  C-c C-c send  n/p hunk  RET source")
               'face 'ecc-dim-face))))

(defun ecc-review--fill (buffer session text root &optional request paths)
  "Put the diff TEXT into BUFFER for SESSION, keeping the comments that fit.
ROOT is the directory the file names of TEXT are relative to; REQUEST
and PATHS are remembered as what the buffer reviews."
  (with-current-buffer buffer
    (let ((keys (and (derived-mode-p 'ecc-review-mode)
                     (mapcar (lambda (overlay)
                               (cons (overlay-get overlay 'ecc-review-key)
                                     (overlay-get overlay 'ecc-review-comment)))
                             (ecc-review-comment-overlays)))))
      (unless (derived-mode-p 'ecc-review-mode)
        (ecc-review-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (unless (bolp) (insert "\n")))
      (setq default-directory (or root (ecc-session-project-root session)
                                  default-directory)
            ecc-review--session session
            ecc-render--session session
            ecc-review--request request
            ecc-review--paths paths
            ecc-review--comments nil)
      (set-buffer-modified-p nil)
      (goto-char (point-min))
      (let ((lost 0))
        (dolist (key keys)
          (if-let* ((position (ecc-review--find-hunk (car key))))
              (save-excursion
                (goto-char position)
                (ecc-review--attach (cdr key)))
            (cl-incf lost)))
        (when (> lost 0)
          (message "Dropped %d comments whose hunk is gone" lost)))
      (force-mode-line-update)
      buffer)))

;;;; Hunks

(defconst ecc-review--hunk-regexp
  "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
  "Matches a unified hunk header.
The groups are old start, old count, new start and new count.")

(defun ecc-review-hunk-range (header)
  "Return (START . END) of the new side of the hunk HEADER line.
A hunk that only removes lines is one line wide at its position."
  (when (string-match ecc-review--hunk-regexp header)
    (let ((start (string-to-number (match-string 3 header)))
          (count (if (match-string 4 header)
                     (string-to-number (match-string 4 header))
                   1)))
      (cons start (+ start (max count 1) -1)))))

(defun ecc-review--hunk-bounds ()
  "Return (BEG . END) of the hunk the point is in, or nil.
END is after the newline of the last line.  Nil is returned on a file
header or before the first hunk."
  (save-excursion
    (let ((here (point)))
      (condition-case nil
          (let ((beg (progn (diff-beginning-of-hunk) (point))))
            ;; Point was in front of the hunk found backwards if a file
            ;; header lies between the two.
            (unless (save-excursion
                      (goto-char beg)
                      (re-search-forward "^\\(?:\\+\\+\\+\\|diff \\)" (max here (1+ beg)) t))
              (cons beg (progn (diff-end-of-hunk) (point)))))
        (error nil)))))

(defun ecc-review--hunk-path (beg)
  "Return the file name of the hunk starting at BEG, without a/ or b/."
  (save-excursion
    (goto-char beg)
    (let* ((names (ignore-errors (diff-hunk-file-names)))
           (new (car names))
           (old (cadr names))
           (name (if (or (null new) (equal new "/dev/null")) old new)))
      (when name
        (replace-regexp-in-string "\\`[ab]/" "" name)))))

(defun ecc-review-hunk-at (beg end)
  "Return the hunk between BEG and END as a plist.
The plist has :path, :start and :end of the new side, :header, :text
being the whole hunk, and :position."
  (save-excursion
    (goto-char beg)
    (let* ((header (buffer-substring-no-properties (point) (line-end-position)))
           (range (ecc-review-hunk-range header)))
      (list :path (ecc-review--hunk-path beg)
            :start (car range)
            :end (cdr range)
            :header header
            :text (string-trim-right (buffer-substring-no-properties beg end) "\n")
            :position beg))))

(defun ecc-review--hunk-key (hunk)
  "Return what identifies HUNK across a redraw: its file and its header."
  (cons (plist-get hunk :path) (plist-get hunk :header)))

(defun ecc-review--find-hunk (key)
  "Return the position of the hunk with KEY in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not found)
                  (re-search-forward ecc-review--hunk-regexp nil t))
        (let ((beg (line-beginning-position)))
          (when (and (equal (buffer-substring-no-properties beg (line-end-position))
                            (cdr key))
                     (equal (ecc-review--hunk-path beg) (car key)))
            (setq found beg))))
      found)))

(defun ecc-review-hunks ()
  "Return every hunk of the current buffer as `ecc-review-hunk-at' plists."
  (save-excursion
    (goto-char (point-min))
    (let ((hunks nil))
      (while (re-search-forward ecc-review--hunk-regexp nil t)
        (when-let* ((bounds (ecc-review--hunk-bounds)))
          (push (ecc-review-hunk-at (car bounds) (cdr bounds)) hunks)
          (goto-char (max (point) (1- (cdr bounds))))))
      (nreverse hunks))))

;;;; Comments

(defun ecc-review-comment-overlays ()
  "Return the live comment overlays of this buffer."
  (setq ecc-review--comments (seq-filter #'overlay-buffer ecc-review--comments)))

(defun ecc-review-comment-at-point ()
  "Return the comment overlay of the hunk at point, or nil."
  (when-let* ((bounds (ecc-review--hunk-bounds)))
    (seq-find (lambda (overlay)
                (and (overlay-get overlay 'ecc-review-comment)
                     (= (overlay-start overlay) (car bounds))))
              (overlays-in (car bounds) (cdr bounds)))))

(defun ecc-review--attach (text)
  "Attach the comment TEXT to the hunk at point and return its overlay."
  (let* ((bounds (or (ecc-review--hunk-bounds) (user-error "Not on a hunk")))
         (hunk (ecc-review-hunk-at (car bounds) (cdr bounds)))
         (overlay (make-overlay (car bounds) (cdr bounds) nil t nil))
         (header (make-overlay (car bounds)
                               (save-excursion (goto-char (car bounds))
                                               (line-end-position)))))
    (overlay-put overlay 'ecc-review-comment text)
    (overlay-put overlay 'ecc-review-key (ecc-review--hunk-key hunk))
    (overlay-put overlay 'ecc-review-header header)
    (overlay-put overlay 'after-string
                 (propertize (concat "  ▎ " (string-replace "\n" "\n  ▎ " text) "\n")
                             'face 'ecc-review-comment-face))
    (overlay-put header 'face 'ecc-review-commented-hunk-face)
    (push overlay ecc-review--comments)
    (force-mode-line-update)
    overlay))

(defun ecc-review--detach (overlay)
  "Remove the comment OVERLAY."
  (when-let* ((header (overlay-get overlay 'ecc-review-header)))
    (delete-overlay header))
  (setq ecc-review--comments (delq overlay ecc-review--comments))
  (delete-overlay overlay)
  (force-mode-line-update))

(defun ecc-review-comment (text)
  "Attach the comment TEXT to the hunk at point, replacing an earlier one.
Interactively the earlier comment is offered for editing."
  (interactive
   (progn
     (unless (ecc-review--hunk-bounds)
       (user-error "Not on a hunk"))
     (list (read-string "Comment on this hunk: "
                        (when-let* ((overlay (ecc-review-comment-at-point)))
                          (overlay-get overlay 'ecc-review-comment))))))
  (when (string-empty-p (string-trim text))
    (user-error "Empty comment"))
  (when-let* ((old (ecc-review-comment-at-point)))
    (ecc-review--detach old))
  (prog1 (ecc-review--attach (string-trim text))
    (message "Comment attached (%d in all)" (length (ecc-review-comment-overlays)))))

(defun ecc-review-remove-comment ()
  "Remove the comment of the hunk at point."
  (interactive)
  (ecc-review--detach (or (ecc-review-comment-at-point)
                          (user-error "No comment on this hunk")))
  (message "Comment removed (%d left)" (length (ecc-review-comment-overlays))))

(defun ecc-review-comments ()
  "Return the comments of this buffer in file and hunk order.
Each is the plist of `ecc-review-hunk-at' with :comment added."
  (mapcar (lambda (overlay)
            (append (ecc-review-hunk-at (overlay-start overlay) (overlay-end overlay))
                    (list :comment (overlay-get overlay 'ecc-review-comment))))
          ;; `sort' is destructive and the list is the buffer's own.
          (seq-sort (lambda (a b) (< (overlay-start a) (overlay-start b)))
                    (ecc-review-comment-overlays))))

(defun ecc-review--comment-label (comment)
  "Return the one line label of COMMENT used in the list."
  (format "%s  L%s-L%s: %s"
          (or (plist-get comment :path) "?")
          (plist-get comment :start) (plist-get comment :end)
          (ecc--truncate (plist-get comment :comment) 60)))

(defun ecc-review-list-comments ()
  "Pick one of the comments and move to its hunk."
  (interactive)
  (let* ((comments (or (ecc-review-comments) (user-error "No comment yet")))
         (labels (mapcar #'ecc-review--comment-label comments))
         (choice (completing-read "Comment: " labels nil t))
         (comment (nth (seq-position labels choice) comments)))
    (goto-char (plist-get comment :position))))

;;;; The message

(defun ecc-review--fence (text)
  "Return a fence line that TEXT cannot close early."
  (let ((fence "```"))
    (while (string-search fence text)
      (setq fence (concat fence "`")))
    fence))

(defun ecc-review-format-message (comments &optional header)
  "Return the prompt carrying COMMENTS as one block each.
COMMENTS are the plists of `ecc-review-comments'; HEADER replaces
`ecc-review-header'."
  (concat
   (or header ecc-review-header) "\n\n"
   (mapconcat (lambda (comment)
                (let ((fence (ecc-review--fence (plist-get comment :text))))
                  (format "## %s  L%d-L%d\n%sdiff\n%s\n%s\nComment: %s"
                          (or (plist-get comment :path) "?")
                          (plist-get comment :start) (plist-get comment :end)
                          fence (plist-get comment :text) fence
                          (plist-get comment :comment))))
              comments "\n\n")))

(defun ecc-review-buffer-message ()
  "Return the prompt for the comments of the current review buffer, or nil."
  (when-let* ((comments (ecc-review-comments)))
    (ecc-review-format-message comments
                               (and ecc-review--request ecc-review-proposal-header))))

;;;;; Confirming before sending

(defvar-local ecc-review-message--review nil
  "The review buffer whose comments this message carries.")

(defvar ecc-review-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-review-message-send)
    (define-key map (kbd "C-c C-k") #'ecc-review-message-cancel)
    map)
  "Keymap of `ecc-review-message-mode'.")

(defalias 'ecc-review-message--parent-mode
  (if (require 'markdown-mode nil t) 'markdown-mode 'text-mode)
  "The mode `ecc-review-message-mode' is derived from.")

(define-derived-mode ecc-review-message-mode ecc-review-message--parent-mode
  "Claude-Review-Message"
  "Major mode of the buffer the review prompt is confirmed in.

\\{ecc-review-message-mode-map}"
  :interactive nil
  (setq header-line-format
        (propertize " C-c C-c sends, C-c C-k goes back; the text may be edited" 'face 'ecc-dim-face)))

(defun ecc-review-message-buffer-name (session)
  "Return the name of the confirmation buffer of SESSION."
  (format "*ecc-review-message: %s*" (ecc-session-name session)))

(defun ecc-review-send ()
  "Open the comments as one prompt to confirm and send.
In the review of a proposal the prompt is sent as the message of the
deny instead."
  (interactive)
  (let* ((session (or ecc-review--session (user-error "Not a review buffer")))
         (text (or (ecc-review-buffer-message)
                   (user-error "No comment to send; put one on a hunk with c")))
         (review (current-buffer))
         (buffer (get-buffer-create (ecc-review-message-buffer-name session))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ecc-review-message-mode)
        (insert text)
        (setq ecc-render--session session
              ecc-review-message--review review)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun ecc-review-message-send ()
  "Send the text of this buffer and close the review it came from."
  (interactive)
  (let* ((review ecc-review-message--review)
         (session (or ecc-render--session (user-error "Not a review message")))
         (text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (request (and (buffer-live-p review)
                       (buffer-local-value 'ecc-review--request review)))
         (message-buffer (current-buffer)))
    (when (string-empty-p text)
      (user-error "The message is empty"))
    (cond
     (request
      (unless (memq request (ecc-session-pending session))
        (user-error "This proposal was answered already"))
      (ecc-perm-respond request 'deny :message text)
      (message "Denied with comments: %s" (ecc-request-tool-name request)))
     (t
      (let ((outcome (ecc-proc-send-prompt session text)))
        (if (eq outcome 'sent)
            (message "Review comments sent")
          (message "A turn is running; queued at position %d" outcome)))))
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer message-buffer)
    (when (buffer-live-p review)
      (ecc-perm-close-buffer review))
    text))

(defun ecc-review-message-cancel ()
  "Drop this message and go back to the review buffer."
  (interactive)
  (let ((review ecc-review-message--review))
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer (current-buffer))
    (when (buffer-live-p review)
      (pop-to-buffer review))))

;;;; Opening a review

(defun ecc-review-session ()
  "Return the session a review command is about, or signal an error."
  (or ecc-review--session ecc-render--session
      (car (ecc-model-sessions))
      (user-error "No session is running")))

(defun ecc-review-buffer (session &optional paths)
  "Return the buffer reviewing the changes of SESSION, filled and current.
PATHS restricts the review to those files.  Signals an error when no
file has a change to show."
  (let* ((entries (ecc-review-files session paths))
         (diff (and entries (ecc-review-diff-text entries))))
    (unless entries
      (user-error "No file was edited or written in this session"))
    (unless diff
      (user-error "The files of this session show no change"))
    (ecc-review--fill (get-buffer-create (ecc-review-buffer-name session))
                      session (car diff) (cdr diff) nil paths)))

;;;###autoload
(defun ecc-review (&optional session paths)
  "Open every change of SESSION as one diff to review.
SESSION defaults to the session of the current buffer.  PATHS, given
interactively with a prefix argument, restricts the review to those
files."
  (interactive
   (let ((session (ecc-review-session)))
     (list session
           (and current-prefix-arg
                (completing-read-multiple
                 "Files: "
                 (mapcar #'ecc-file-entry-path (ecc-review-files session))
                 nil t)))))
  (let ((session (or session (ecc-review-session))))
    (ecc-window-display-review (ecc-review-buffer session paths) session)))

(defun ecc-review-refresh ()
  "Read the diff again, keeping the comments whose hunks still exist."
  (interactive)
  (let ((session (or ecc-review--session (user-error "Not a review buffer"))))
    (if ecc-review--request
        (ecc-review-request ecc-review--request)
      (ecc-review-buffer session ecc-review--paths))
    (message "Refreshed")))

(defun ecc-review-quit ()
  "Close the review buffer, dropping its comments."
  (interactive)
  (ecc-perm-close-buffer (current-buffer)))

;;;; Reviewing one proposal

(defun ecc-review-request-diff (request &optional before)
  "Return the diff of the Edit or Write REQUEST as unified diff text.
BEFORE is the file as it is before the call, when known.  A hunk
header is always present so that the text is a hunk for `diff-mode'."
  (let* ((name (ecc-request-tool-name request))
         (input (ecc-request-input request))
         (path (alist-get 'file_path input))
         (body (pcase name
                 ((or "Edit" "MultiEdit")
                  (let ((old (or (alist-get 'old_string input) ""))
                        (new (or (alist-get 'new_string input) "")))
                    (if (and before (string-search old before))
                        (ecc-diff-for-edit old new before ecc-review-context-lines)
                      (ecc-diff-format-hunks
                       (ecc-diff-hunks (ecc-diff-lines old new)
                                       ecc-review-context-lines)))))
                 ("Write"
                  (ecc-diff-for-write (or (alist-get 'content input) "") before
                                      ecc-review-context-lines))
                 (_ nil))))
    (when (and body (not (string-empty-p body)))
      (concat (ecc-review--file-header (or path "?") (null before))
              (substring-no-properties body)))))

(defun ecc-review-request (&optional request)
  "Open the diff of the pending Edit or Write REQUEST to comment on it.
REQUEST defaults to the one at point.  Returns the buffer."
  (interactive)
  (let* ((request (or request (ecc-perm-permission-request)))
         (session (ecc-request-session request))
         (node (ecc-request-node request))
         (before (or (and node (ecc-model-node-get node 'before))
                     (ecc-diff-file-content
                      (alist-get 'file_path (ecc-request-input request)))))
         (diff (or (ecc-review-request-diff request before)
                   (user-error "%s is not a change to a file that can be reviewed"
                               (ecc-request-tool-name request)))))
    (unless (memq request (ecc-session-pending session))
      (user-error "This request was answered already"))
    (let ((buffer (ecc-review--fill
                   (get-buffer-create (ecc-review-buffer-name session request))
                   session diff nil request)))
      (when (called-interactively-p 'any)
        (ecc-window-display-review buffer session))
      buffer)))

(defun ecc-review-comment-request (text)
  "Open the review of the request at point and put the comment TEXT on it.
The way a comment is left from the transcript."
  (interactive (list nil))
  (let ((buffer (ecc-review-request)))
    (pop-to-buffer buffer)
    (unless (ecc-review--hunk-bounds)
      (diff-hunk-next))
    (if text
        (ecc-review-comment text)
      (call-interactively #'ecc-review-comment))))

(defun ecc-review--request-buffer (request)
  "Return the live buffer reviewing REQUEST, or nil."
  (let ((buffer (get-buffer (ecc-review-buffer-name (ecc-request-session request)
                                                    request))))
    (and (buffer-live-p buffer)
         (eq (buffer-local-value 'ecc-review--request buffer) request)
         buffer)))

(defun ecc-review--on-request-resolved (session request)
  "Close the buffers reviewing REQUEST of SESSION, answered somewhere else."
  (when-let* ((buffer (ecc-review--request-buffer request)))
    (unless (eq buffer (current-buffer))
      (let ((message-buffer (get-buffer (ecc-review-message-buffer-name session))))
        (when (and message-buffer
                   (eq (buffer-local-value 'ecc-review-message--review message-buffer)
                       buffer))
          (ecc-perm-close-buffer message-buffer)))
      (ecc-perm-close-buffer buffer)))
  (when-let* ((buffer (ecc-review-proposal--buffer request)))
    (unless (eq buffer (current-buffer))
      (ecc-perm-close-buffer buffer))))

(add-hook 'ecc-request-resolved-hook #'ecc-review--on-request-resolved)

;;;; Editing a proposal before allowing it

(defvar ecc-review-edited-note
  "The user changed the earlier %s (%s) as follows before applying it.  Work from this from now on:"
  "Format of the note queued after a proposal was changed and applied.
The two arguments are the tool name and the file; the diff between
the proposal and what was applied follows.")

(defvar-local ecc-review-proposal--request nil
  "The request whose text this buffer edits.")

(defvar-local ecc-review-proposal--original nil
  "The text of the proposal as Claude sent it.")

(defvar ecc-review-proposal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ecc-review-proposal-apply)
    (define-key map (kbd "C-c C-k") #'ecc-review-proposal-cancel)
    map)
  "Keymap of `ecc-review-proposal-mode'.")

(define-minor-mode ecc-review-proposal-mode
  "Minor mode of the buffer the text of a proposal is edited in."
  :lighter " Claude-Proposal"
  :keymap ecc-review-proposal-mode-map
  (setq header-line-format
        (and ecc-review-proposal-mode
             (propertize " Editing the proposal; C-c C-c allows it as it stands, C-c C-k goes back"
                         'face 'ecc-dim-face))))

(defun ecc-review-proposal-key (request)
  "Return the input key that holds the text REQUEST proposes, or nil."
  (pcase (ecc-request-tool-name request)
    ((or "Edit" "MultiEdit") 'new_string)
    ("Write" 'content)
    (_ nil)))

(defun ecc-review-proposal-buffer-name (session)
  "Return the name of the buffer a proposal of SESSION is edited in."
  (format "*ecc-edit-proposal: %s*" (ecc-session-name session)))

(defun ecc-review-proposal--buffer (request)
  "Return the live buffer editing REQUEST, or nil."
  (let ((buffer (get-buffer (ecc-review-proposal-buffer-name
                             (ecc-request-session request)))))
    (and (buffer-live-p buffer)
         (eq (buffer-local-value 'ecc-review-proposal--request buffer) request)
         buffer)))

(defun ecc-review-edit-proposal (&optional request)
  "Edit the text the pending REQUEST proposes, to apply it changed.
REQUEST defaults to the one this buffer reviews, then to the one at
point.  Returns the buffer."
  (interactive)
  (let* ((request (or request ecc-review--request (ecc-perm-permission-request)))
         (session (ecc-request-session request))
         (key (or (ecc-review-proposal-key request)
                  (user-error "%s has no text to edit" (ecc-request-tool-name request))))
         (path (alist-get 'file_path (ecc-request-input request)))
         (text (or (alist-get key (ecc-request-input request)) ""))
         (buffer (get-buffer-create (ecc-review-proposal-buffer-name session))))
    (unless (memq request (ecc-session-pending session))
      (user-error "This request was answered already"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        ;; The mode of the file, so that the text is edited the way the
        ;; file would be.
        (let ((buffer-file-name path))
          (condition-case nil (set-auto-mode) (error (fundamental-mode))))
        (setq buffer-read-only nil)
        (setq ecc-render--session session
              ecc-review-proposal--request request
              ecc-review-proposal--original text)
        (ecc-review-proposal-mode 1)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (when (called-interactively-p 'any)
      (pop-to-buffer buffer))
    buffer))

(defun ecc-review-proposal-note (request original edited)
  "Return the note telling Claude that REQUEST was applied as EDITED, not ORIGINAL."
  (concat (format ecc-review-edited-note
                  (ecc-request-tool-name request)
                  (or (alist-get 'file_path (ecc-request-input request)) "?"))
          "\n```diff\n"
          (string-trim-right
           (substring-no-properties (or (ecc-diff-render original edited) ""))
           "\n")
          "\n```"))

(defun ecc-review-proposal-apply ()
  "Allow the proposal with the text of this buffer in place of Claude's.
When the text was changed, a note saying so is put in front of the
prompt queue so that the next message tells Claude what was applied."
  (interactive)
  (let* ((request (or ecc-review-proposal--request (user-error "Not a proposal buffer")))
         (session (ecc-request-session request))
         (key (ecc-review-proposal-key request))
         (edited (buffer-substring-no-properties (point-min) (point-max)))
         (changed (not (equal edited ecc-review-proposal--original)))
         (buffer (current-buffer)))
    (unless (memq request (ecc-session-pending session))
      (user-error "This request was answered already"))
    (if (not changed)
        (progn
          (ecc-perm-allow-request request)
          (message "Allowed as it stands: %s" (ecc-request-tool-name request)))
      (let ((input (copy-alist (ecc-request-input request))))
        (setf (alist-get key input) edited)
        (ecc-perm-respond request 'allow :updated-input input
                          :message "edited by the user and applied")
        (push (ecc-review-proposal-note request ecc-review-proposal--original edited)
              (ecc-session-input-queue session))
        (message "Allowed with your changes: %s (the next message carries what you changed)"
                 (ecc-request-tool-name request))))
    (set-buffer-modified-p nil)
    (ecc-perm-close-buffer buffer)
    (when-let* ((review (ecc-review--request-buffer request)))
      (ecc-perm-close-buffer review))
    changed))

(defun ecc-review-proposal-cancel ()
  "Drop the edit and leave the request waiting."
  (interactive)
  (set-buffer-modified-p nil)
  (ecc-perm-close-buffer (current-buffer)))

(provide 'ecc-review)

;;; ecc-review.el ends here
