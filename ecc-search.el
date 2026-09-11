;;; ecc-search.el --- Find a past session by what was said in it  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; `ecc-history-open' offers the recordings by name, which is only any
;; use when the name is remembered.  This searches what was actually
;; said: every recording of the project is read for a string, and the
;; sessions that said it are listed with the lines they said it in.
;;
;; Two things make that cheap enough to do from a keystroke.  The
;; recordings of one project run to a hundred files and a hundred
;; megabytes, so `grep' (or `rg') is asked first which files hold the
;; string at all, and only those are opened -- and inside one, only the
;; lines the string is really on are parsed as JSON, because a line of
;; a recording is a whole message and there are tens of thousands of
;; them.
;;
;; What is searched is the conversation, not the file: the prose of a
;; prompt and the prose of an answer.  A tool result, the JSON of a
;; tool call, a file the model read -- none of that is text a person
;; said, and searching it turns every query into a list of every
;; session that happened to read the file.  `ecc-search-roles' says
;; which halves are read.
;;
;; Abandoned branches are searched with the rest.  Working out which
;; uuids hang off the current line means parsing every line of the
;; file, which is the one thing this is built not to do; a hit in an
;; edited-away branch opens the session all the same.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-history)
(require 'ecc-window)

(defconst ecc-search-buffer-name "*ecc-search*"
  "Name of the buffer the hits are listed in.")

(defvar ecc-search-programs
  '(("rg" "--fixed-strings" "--ignore-case" "--files-with-matches" "--no-messages")
    ("grep" "-F" "-i" "-l"))
  "The programs asked which recordings hold the string, best first.
Each entry is a program and the flags that make it print the names of
the files a fixed string occurs in, ignoring case.  The query and the
file names are added after them.  When none of these is on PATH every
recording is opened instead, which is slower but answers the same.")

(defvar ecc-search-batch 200
  "Number of file names passed to `ecc-search-programs' at a time.
A project with thousands of recordings would otherwise make a command
line too long for the system to take.")

(defvar ecc-search-roles '("user" "assistant")
  "The halves of the conversation searched, as the types of a line.
Both by default.  With just \"user\" a query finds what was asked,
which is usually how a session is remembered.")

(defvar ecc-search-excerpt-width 96
  "Characters of an excerpt shown around a hit.")

(defvar ecc-search-hits-per-session 4
  "Hits listed under one session before the rest are only counted.")

(defvar ecc-search--query-history nil
  "Minibuffer history of the strings searched for.")

(defface ecc-search-match-face
  '((t :inherit match))
  "Face of the searched string inside an excerpt."
  :group 'ecc)

;;;; A hit

(cl-defstruct ecc-search-hit
  "One message of one recording that holds the searched string."
  session-id    ; the id --resume takes, which is the file name
  file
  role          ; "user" or "assistant"
  time          ; when the message was written, or nil
  text)         ; the prose of the message, whole

;;;; Which files to look in

(defun ecc-search--project-files (root)
  "Return the recordings that could belong to the project at ROOT.
The CLI names a directory after the working directory with every
character that is not a letter, a digit or a dash turned into a dash,
so a session started below ROOT lands in a directory whose name starts
with the one of ROOT.  The name is a prefix test and can take in a
sibling as well (-a-b also starts -a-bc), which `ecc-search--group'
sorts out later against the working directory the file itself names."
  (let ((prefix (ecc-history-project-directory root))
        (directory (expand-file-name ecc-history-directory)))
    (when (file-directory-p directory)
      (seq-mapcat
       (lambda (sub) (directory-files sub t "\\.jsonl\\'"))
       (seq-filter (lambda (sub)
                     (and (file-directory-p sub)
                          (string-prefix-p prefix (file-name-nondirectory sub))))
                   (directory-files directory t directory-files-no-dot-files-regexp))))))

(defun ecc-search--program ()
  "Return the first of `ecc-search-programs' that is on PATH, or nil."
  (seq-find (lambda (entry) (executable-find (car entry))) ecc-search-programs))

(defun ecc-search--candidates (query files)
  "Return the members of FILES that hold QUERY somewhere, by grep.
The answer is about the bytes of a file, not about the conversation in
it: a file named here still has to be read to see whether what matched
was something said.  Without a grep on PATH, or when one fails, FILES
is returned as it is and every file is read."
  (if-let* ((program (ecc-search--program)))
      (let ((found '())
            (failed nil))
        (dolist (batch (seq-partition files ecc-search-batch))
          (with-temp-buffer
            (let ((status (apply #'process-file (car program) nil t nil
                                 (append (cdr program) (list "-e" query "--") batch))))
              ;; 0 is a match, 1 is none, anything else went wrong --
              ;; and a grep that went wrong must not quietly shrink the
              ;; search to nothing.
              (if (memq status '(0 1))
                  (setq found (append found (split-string (buffer-string) "\n" t)))
                (setq failed t)))))
        (if failed files found))
    files))

;;;; Reading the files that matched

(defun ecc-search--message-text (object)
  "Return the prose of the recorded message OBJECT, or nil.
A user line gives up its text only when it is a prompt: the output of
a slash command and the caveat before it were written by the CLI, not
said by anyone.  An assistant line gives up the text blocks of its
answer, unless the CLI answered for the model itself."
  (pcase (alist-get 'type object)
    ("user" (ecc-protocol-history-prompt object))
    ("assistant" (unless (or (ecc-protocol-synthetic-p object)
                             (and (not ecc-history-include-sidechain)
                                  (ecc-protocol-history-sidechain-p object)))
                   (ecc-protocol-history-text object)))))

(defun ecc-search--line-hit (file line query)
  "Return the hit QUERY makes in LINE of FILE, or nil.
LINE holds QUERY somewhere; this says whether it holds it in something
that was said.  A line that will not parse is no hit, the way the rest
of the history reader treats one."
  (condition-case nil
      (let ((object (ecc--json-read line)))
        (when (and (consp object)
                   (member (alist-get 'type object) ecc-search-roles))
          (let ((text (ecc-search--message-text object))
                (case-fold-search t))
            (when (and text (string-match-p (regexp-quote query) text))
              (make-ecc-search-hit
               :session-id (file-name-base file)
               :file file
               :role (alist-get 'type object)
               :time (ecc-protocol-history-timestamp object)
               :text text)))))
    (error nil)))

(defun ecc-search--scan-file (file query)
  "Return the hits QUERY makes in FILE, oldest first.
Only the lines QUERY is on are parsed.  A recording holds tens of
thousands of lines and JSON is the expensive part, so the buffer is
searched for the raw string first and a line that matched more than
once is still read once."
  (let ((hits '()))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (let ((case-fold-search t))
        (goto-char (point-min))
        (while (search-forward query nil t)
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (when-let* ((hit (ecc-search--line-hit file line query)))
              (push hit hits)))
          (forward-line 1))))
    (nreverse hits)))

;;;; The sessions the hits belong to

(defun ecc-search--under-p (info root)
  "Return non-nil when the recording INFO ran under ROOT.
A recording that names no working directory is kept: it is a file of
the project's own directory, or the search was not scoped at all."
  (or (null root)
      (if-let* ((cwd (alist-get 'cwd info)))
          (string-prefix-p (file-name-as-directory (file-truename root))
                           (file-name-as-directory (file-truename cwd)))
        t)))

(defun ecc-search--group (file hits root)
  "Return the group HITS of FILE make, or nil when FILE is not under ROOT.
A group is (INFO . HITS), INFO being what `ecc-history-scan-file' says
about the recording: its title, when it was last written and where it
ran.  Only a file that matched is described, which is why the scan is
here and not in front of the search."
  (let ((info (ecc-history-scan-file file)))
    (when (ecc-search--under-p info root)
      (cons info hits))))

(defun ecc-search--newer-p (a b)
  "Return non-nil when group A was written more recently than group B."
  (let ((ta (or (alist-get 'time (car a)) (alist-get 'mtime (car a))))
        (tb (or (alist-get 'time (car b)) (alist-get 'mtime (car b)))))
    (cond ((and ta tb) (time-less-p tb ta))
          (ta t)
          (t nil))))

(defun ecc-search-groups (query &optional root)
  "Return the sessions that said QUERY, most recently used first.
ROOT limits the search to the recordings made under it; nil searches
every project.  Each group is (INFO . HITS): the alist of
`ecc-history-scan-file' and the `ecc-search-hit's of that recording."
  (let* ((files (if root (ecc-search--project-files root) (ecc-history-files)))
         (candidates (ecc-search--candidates query files))
         (groups '()))
    (dolist (file candidates)
      (when-let* ((hits (ecc-search--scan-file file query))
                  (group (ecc-search--group file hits root)))
        (push group groups)))
    (seq-sort #'ecc-search--newer-p (nreverse groups))))

;;;; Drawing them

(defun ecc-search--excerpt (text query)
  "Return the part of TEXT around the first QUERY in it, QUERY marked.
The text of a message is a paragraph or twenty; what is wanted here is
the one line that shows why the session came up, so the whitespace is
flattened and a window `ecc-search-excerpt-width' wide is cut around
the hit."
  (let* ((flat (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
         (case-fold-search t)
         (at (or (string-match (regexp-quote query) flat) 0))
         (start (max 0 (- at (/ ecc-search-excerpt-width 3))))
         (end (min (length flat) (+ start ecc-search-excerpt-width)))
         (excerpt (concat (if (> start 0) "…" "")
                          (substring flat start end)
                          (if (< end (length flat)) "…" ""))))
    (when (string-match (regexp-quote query) excerpt)
      (add-face-text-property (match-beginning 0) (match-end 0)
                              'ecc-search-match-face nil excerpt))
    excerpt))

(defconst ecc-search-role-marks
  '(("user" . ("›" . ecc-user-face))
    ("assistant" . ("‹" . ecc-assistant-face)))
  "The mark and face a hit is drawn with, by the type of its line.")

(defun ecc-search--hit-string (hit query)
  "Return the line HIT is listed as, QUERY marked in its excerpt."
  (let ((mark (alist-get (ecc-search-hit-role hit) ecc-search-role-marks
                         '("·" . ecc-dim-face) nil #'equal)))
    (concat "    "
            (propertize (car mark) 'face (cdr mark))
            " "
            (ecc-search--excerpt (ecc-search-hit-text hit) query)
            "\n")))

(defun ecc-search--group-string (group query)
  "Return GROUP drawn as a heading and the lines of its hits.
QUERY is marked in each of them."
  (let* ((info (car group))
         (hits (cdr group))
         (id (alist-get 'session-id info))
         (time (or (alist-get 'time info) (alist-get 'mtime info)))
         (shown (seq-take hits ecc-search-hits-per-session))
         (rest (- (length hits) (length shown))))
    (concat
     (propertize (or (alist-get 'title info) (file-name-base id))
                 'face 'ecc-heading-face)
     (propertize (format "  %s  %s  %d hit%s\n"
                         (if time (format-time-string "%Y-%m-%d %H:%M" time) "")
                         (substring id 0 (min 8 (length id)))
                         (length hits)
                         (if (= 1 (length hits)) "" "s"))
                 'face 'ecc-dim-face)
     (mapconcat (lambda (hit) (ecc-search--hit-string hit query)) shown "")
     (if (> rest 0)
         (propertize (format "    and %d more\n" rest) 'face 'ecc-dim-face)
       "")
     "\n")))

(defun ecc-search--insert-group (group query)
  "Insert GROUP into the current buffer, QUERY marked, its session on it.
The session id is a text property of the whole block, so that RET says
the same thing wherever in the block it is pressed."
  (let ((start (point)))
    (insert (ecc-search--group-string group query))
    (put-text-property start (point) 'ecc-search-session
                       (alist-get 'session-id (car group)))))

;;;; The buffer

(defvar-local ecc-search--query nil
  "The string this buffer lists the hits of.")

(defvar-local ecc-search--root nil
  "The project the hits in this buffer were searched under, or nil.")

(defun ecc-search-session-at-point ()
  "Return the session id of the block point is in, or nil."
  (get-text-property (point) 'ecc-search-session))

(defun ecc-search-visit ()
  "Open the recorded conversation point is in."
  (interactive)
  (let ((id (or (ecc-search-session-at-point)
                (user-error "No session here"))))
    (ecc-history-open id)))

(defun ecc-search-next ()
  "Move to the next session in the list."
  (interactive)
  (let ((here (ecc-search-session-at-point)))
    (while (and (not (eobp))
                (equal (ecc-search-session-at-point) here))
      (forward-line 1))))

(defun ecc-search-previous ()
  "Move to the previous session in the list."
  (interactive)
  (let ((here (ecc-search-session-at-point)))
    (while (and (not (bobp))
                (equal (ecc-search-session-at-point) here))
      (forward-line -1))
    (let ((there (ecc-search-session-at-point)))
      (while (and (not (bobp))
                  (equal (save-excursion (forward-line -1)
                                         (ecc-search-session-at-point))
                         there))
        (forward-line -1)))))

(defun ecc-search-refresh ()
  "Search again for what this buffer lists."
  (interactive)
  (unless ecc-search--query
    (user-error "This buffer searched for nothing"))
  (ecc-search ecc-search--query (null ecc-search--root)))

(defvar ecc-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-search-visit)
    (define-key map (kbd "o") #'ecc-search-visit)
    (define-key map (kbd "n") #'ecc-search-next)
    (define-key map (kbd "p") #'ecc-search-previous)
    (define-key map (kbd "g") #'ecc-search-refresh)
    map)
  "Keymap of `ecc-search-mode'.")

(define-derived-mode ecc-search-mode special-mode "Claude-Search"
  "Major mode listing the past sessions that said something.

\\{ecc-search-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

(defun ecc-search--draw (groups query root)
  "Show GROUPS, the sessions that said QUERY under ROOT, in a buffer."
  (let ((buffer (get-buffer-create ecc-search-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ecc-search-mode)
        (setq ecc-search--query query
              ecc-search--root root)
        (insert (propertize
                 (format "%d session%s said %s%s\n\n"
                         (length groups)
                         (if (= 1 (length groups)) "" "s")
                         (propertize query 'face 'ecc-search-match-face)
                         (if root
                             (format " in %s" (abbreviate-file-name root))
                           " in any project"))
                 'face 'ecc-heading-face))
        (if (null groups)
            (insert (propertize "Nothing was said about it.\n" 'face 'ecc-dim-face))
          (dolist (group groups)
            (ecc-search--insert-group group query)))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun ecc-search (query &optional everywhere)
  "List the past sessions of this project that said QUERY.
QUERY is a plain string, matched without regard to case; it is looked
for in the prompts and the answers of every recording, and the
sessions that hold it are listed with the lines they hold it in.  RET
opens the one point is in.

With a prefix argument, or EVERYWHERE non-nil, every project is
searched rather than the one of `default-directory'."
  (interactive
   (list (read-string "Sessions that said: " nil 'ecc-search--query-history)
         current-prefix-arg))
  (setq query (string-trim query))
  (when (string-empty-p query)
    (user-error "Nothing to search for"))
  (let ((root (unless everywhere
                (ecc-window-project-root))))
    (ecc-search--draw (ecc-search-groups query root) query root)))

(provide 'ecc-search)

;;; ecc-search.el ends here
