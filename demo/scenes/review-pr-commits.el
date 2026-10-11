;;; review-pr-commits.el --- A pull request read a commit at a time  -*- lexical-binding: t; -*-

;;; Commentary:

;; What a batch test cannot see of feat/review-pr-commits, on a real
;; frame with the user's own init:
;;
;; - `C-c c D' `p': after the pull request, the question of which
;;   commit, the whole of it first and its commits oldest first, the
;;   merge of main into the branch not among them; RET is the whole;
;; - in the diff review, ] and [ going through the commits in the same
;;   window, a comment on each of two, the header line saying which
;;   commit and how many comments the others hold, and [ finding the
;;   first commit's comment where it was left;
;; - the same in an ediff review (-e), opened on one commit straight
;;   from the question: ] quits it and opens the next, the right
;;   window's mode line saying which commit, and a comment held across
;;   ] and [;
;; - C-u C-c C-a: every commit's comments as one prompt, grouped by
;;   commit, shown to be edited, then sent, and the reviews closed.
;;
;; gh is a shell script answering `pr list' with one pull request whose
;; commits are all in the repository, so nothing is fetched and GitHub
;; is not asked.  The session is an archived one whose process is a
;; `cat', as in review-ediff-feedback.el: the prompt goes into the cat
;; and no model is asked anything.
;;
;; vertico-posframe shows the minibuffer in a child frame of its own,
;; which the recorder, taking the demo frame's window alone, does not
;; see; it is turned off here so that the questions are on camera.
;;
;; Every step reports what it found and the scene ends by saving the
;; reports to /tmp/ecc-demo-review-pr-commits-log.txt.
;;
;; Played by demo/scenes/review-pr-commits.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-review)
(require 'ecc-review-menu)
(require 'ecc-review-pr)
(require 'ecc-review-ediff)
(require 'ecc-review-direct)

(defvar demo-session nil "The session the comments go to.")

(defvar demo-gh "/tmp/ecc-demo-review-pr-commits-gh"
  "The gh of the scene, a script answering with `demo-gh-json'.")

;;;; The project

(defun demo-commit (subject &rest files)
  "Write FILES, (NAME CONTENT ...), and commit them as SUBJECT."
  (while files
    (demo-write (car files) (cadr files))
    (demo-git "add" (car files))
    (setq files (cddr files)))
  (demo-git "commit" "-q" "-m" subject))

(defun demo-rev (revision)
  "Return the full id of REVISION in the project."
  (let ((default-directory demo-root))
    (string-trim (shell-command-to-string (format "git rev-parse %s" revision)))))

(defun demo-write-gh ()
  "Write the gh of the scene: `pr list' is pull request #42, feature/cache into main."
  (with-temp-file demo-gh
    (insert "#!/bin/sh\ncase \"$1 $2\" in\n  'pr list') cat <<'EOF'\n"
            (json-serialize
             (vector (list :number 42 :title "Cache the files the app reads"
                           :state "OPEN" :headRefName "feature/cache" :baseRefName "main"
                           :headRefOid (demo-rev "feature/cache") :baseRefOid (demo-rev "main")
                           :author '(:login "someone") :isDraft :false
                           :isCrossRepository :false
                           :url "https://github.com/example/app/pull/42")))
            "\nEOF\n;;\n  *) echo \"unexpected: $*\" >&2; exit 2 ;;\nesac\n"))
  (set-file-modes demo-gh #o755))

(defun demo-scene-build ()
  "Build main and feature/cache, gh and the session.  Called by demo.el."
  (setq ecc-review-style 'diff
        ecc-review-files-shown nil
        ecc-review-talk-reply-height nil
        ecc-review-ediff-layout 'stacked
        ecc-review-gh-executable demo-gh)
  (when (bound-and-true-p vertico-posframe-mode)
    (vertico-posframe-mode -1))
  (demo-fresh-repository)
  (demo-git "symbolic-ref" "HEAD" "refs/heads/main")
  (demo-commit "first" "src/app.py"
               "import sys\n\n\ndef show(path):\n    with open(path) as f:\n        print(f.read())\n\n\nif __name__ == \"__main__\":\n    show(sys.argv[1])\n")
  (demo-git "checkout" "-q" "-b" "feature/cache")
  (demo-commit "feat(cache): add a cache of the files read" "src/cache.py"
               "import os\n\nCACHE_DIR = os.path.expanduser(\"~/.cache/app\")\n\n\ndef read(path, cache):\n    if path in cache:\n        return cache[path]\n    with open(path) as f:\n        text = f.read()\n    cache[path] = text\n    return text\n")
  (demo-git "checkout" "-q" "main")
  (demo-commit "docs: a README" "README.md" "# app\n\nShows a file.\n")
  (demo-git "checkout" "-q" "feature/cache")
  (demo-git "merge" "-q" "--no-edit" "main")
  (demo-commit "feat(app): read through the cache" "src/app.py"
               "import sys\n\nfrom cache import read\n\nCACHE = {}\n\n\ndef show(path):\n    print(read(path, CACHE).rstrip())\n\n\nif __name__ == \"__main__\":\n    show(sys.argv[1])\n")
  (demo-commit "fix(cache): key the cache by path and mtime" "src/cache.py"
               "import os\n\nCACHE_DIR = os.path.expanduser(\"~/.cache/app\")\n\n\ndef read(path, cache):\n    key = (path, os.stat(path).st_mtime)\n    if key in cache:\n        return cache[key]\n    with open(path) as f:\n        text = f.read()\n    cache[key] = text\n    return text\n")
  (demo-commit "test: cover the cache" "tests/test_cache.py"
               "from cache import read\n\n\ndef test_reads_once(tmp_path):\n    path = tmp_path / \"a.txt\"\n    path.write_text(\"a\")\n    cache = {}\n    assert read(str(path), cache) == \"a\"\n    assert len(cache) == 1\n")
  (demo-git "checkout" "-q" "main")
  (demo-write-gh)
  (setq demo-session (ecc-model-create-session
                      :id "demo-review-pr-commits"
                      :name "pr-demo"
                      :project-root demo-root
                      :kind 'archived))
  (setf (ecc-session-process demo-session)
        (make-process :name "demo-review-pr-commits-cat" :command '("cat")
                      :connection-type 'pipe :noquery t :filter #'ignore))
  (ecc-model-set-state demo-session 'idle)
  (advice-add 'completing-read :before #'demo-report-question)
  (demo-open-source)
  (demo-say (format "ecc %s from %s   vertico-posframe off   main checked out"
                    (ecc-version) (file-name-directory (locate-library "ecc-review-pr"))))
  (demo-say (format "feature/cache: %s"
                    (let ((default-directory demo-root))
                      (string-trim (shell-command-to-string
                                    "git log --oneline --reverse main~1..feature/cache")))))
  nil)

(defun demo-open-source ()
  "Show src/app.py alone: the menu is opened from a file of the project."
  (find-file (expand-file-name "src/app.py" demo-root))
  (delete-other-windows)
  nil)

;;;; Typing

(defun demo-type (&rest chunks)
  "Type CHUNKS 0.8 s apart: a string is a key description, a list a text.
They go on `unread-command-events', where transient and the minibuffer
read them the way they read typing."
  (let ((delay 0.3))
    (dolist (chunk chunks)
      (let ((events (if (consp chunk)
                        (string-to-list (car chunk))
                      (listify-key-sequence (kbd chunk)))))
        (run-at-time delay nil
                     (lambda ()
                       (setq unread-command-events
                             (append unread-command-events events)))))
      (setq delay (+ delay 0.8))))
  nil)

(defun demo-open-menu ()
  "Press C-c c D in src/app.py, the way the user's init binds it."
  (demo-open-source)
  (demo-run-key-in "app.py" "C-c c D")
  nil)

(defun demo-diff-review ()
  "Return the diff review on the screen."
  (seq-find (lambda (buffer)
              (and (get-buffer-window buffer)
                   (with-current-buffer buffer (derived-mode-p 'ecc-review-mode))))
            (buffer-list)))

(defun demo-diff-key (key &optional text)
  "Run KEY in the diff review on the screen, TEXT answering what it asks."
  (demo-run-key-in (buffer-name (demo-diff-review)) key text)
  nil)

(defun demo-control ()
  "Return the control buffer of the ediff review that is open."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'ediff-mode) ecc-review-ediff--buffers)))
            (buffer-list)))

(defun demo-ediff-key (keys &optional text)
  "Type KEYS in the right window of the ediff review, TEXT and RET after them."
  (run-at-time
   0.2 nil
   (lambda ()
     (let ((window (buffer-local-value 'ediff-window-B (demo-control))))
       (with-selected-frame (window-frame window)
         (select-window window)
         (execute-kbd-macro (vconcat (kbd keys)
                                     (and text (vconcat text (kbd "RET")))))))))
  nil)

(defun demo-message-key (key)
  "Run KEY in the buffer the prompt is confirmed in."
  (demo-run-key-in "*ecc-review-message: pr-demo*" key)
  nil)

;;;; Reports

(defun demo-report-question (prompt table &rest _)
  "Say what a question of `p' asks and offers: PROMPT and TABLE.
On `completing-read', as advice, for the questions of the review menu."
  (when (string-match-p "pull request\\|commit of" prompt)
    (demo-say (format "[question] %s\n  %s" prompt
                      (string-join (all-completions "" table) "\n  ")))))

(defun demo-report-diff (label)
  "Say, under LABEL, the header line and comments of the diff review shown."
  (let ((review (demo-diff-review)))
    (if (not review)
        (demo-say (format "[%s] no diff review on the screen" label))
      (with-current-buffer review
        (demo-say (format "[%s] %s  range %s\n  header: %s\n  comments: %S" label
                          (buffer-name) ecc-review--range
                          (substring-no-properties (ecc-review--header-line))
                          (mapcar #'ecc-review-note-text ecc-review--notes))))))
  nil)

(defun demo-report-ediff (label)
  "Say, under LABEL, the right mode line and the comments of the ediff review."
  (let ((control (demo-control)))
    (if (not control)
        (demo-say (format "[%s] no ediff review open" label))
      (with-current-buffer control
        (demo-say (format "[%s] ediff %s  range %s\n  right mode line: %s\n  comments: %S" label
                          (buffer-name) ecc-review--range
                          (substring-no-properties
                           (ecc-review-direct-mode-line-text ediff-buffer-B))
                          (mapcar #'ecc-review-note-text ecc-review--notes))))))
  nil)

(defun demo-report-reviews (label)
  "Say, under LABEL, every review buffer still open and its comments."
  (let ((reviews (seq-filter #'ecc-review-buffer-p (buffer-list))))
    (demo-say (format "[%s] reviews open: %s" label
                      (if reviews
                          (mapconcat (lambda (buffer)
                                       (format "%s %S" (buffer-name buffer)
                                               (mapcar #'ecc-review-note-text
                                                       (buffer-local-value 'ecc-review--notes
                                                                           buffer))))
                                     reviews "; ")
                        "none"))))
  nil)

(defun demo-report-message (label)
  "Say, under LABEL, the prompt in the buffer it is confirmed in."
  (let ((buffer (get-buffer "*ecc-review-message: pr-demo*")))
    (demo-say (format "[%s] %s" label
                      (if (buffer-live-p buffer)
                          (format "message buffer %s:\n%s"
                                  (if (get-buffer-window buffer t) "shown" "hidden")
                                  (with-current-buffer buffer
                                    (buffer-substring-no-properties (point-min) (point-max))))
                        "no message buffer"))))
  nil)

(defun demo-report-sent (label)
  "Say, under LABEL, the last prompt the session was given."
  (let ((turn (car (last (ecc-session-turns demo-session)))))
    (demo-say (format "[%s] session's last prompt starts: %S" label
                      (and turn (ecc--truncate (or (ecc-turn-prompt turn) "") 160)))))
  nil)

;;;; Closing

(defun demo-close ()
  "Close what is left: the menu, any review, the cat."
  (ignore-errors (transient-quit-all))
  (when-let* ((control (demo-control)))
    (ecc-review-ediff-quit control))
  (advice-remove 'completing-read #'demo-report-question)
  (when (process-live-p (ecc-session-process demo-session))
    (delete-process (ecc-session-process demo-session)))
  nil)

(provide 'review-pr-commits)
;;; review-pr-commits.el ends here
