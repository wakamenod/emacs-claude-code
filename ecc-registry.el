;;; ecc-registry.el --- The sessions Claude Code itself is running  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Every running Claude Code writes a small JSON file about itself under
;; ~/.claude/sessions, named after its process id, and deletes it when it
;; stops.  Reading that directory is how Emacs learns about the sessions
;; it did not start: the ones in a terminal, in another Emacs, or started
;; in the background (FR-DASH-2 b, FR-DASH-6).
;;
;; `claude agents --json' reports the same thing, but as a subprocess
;; that costs a fifth of a second and has to be polled.  The files cost
;; nothing, carry more (the socket path, the tmux pane, the name), and
;; can be watched, so this is the source and the command is not used.
;; See docs/verified.md, and decisions.md for why the requirement's
;; wording is not followed to the letter.
;;
;; A file whose process is gone is stale.  It normally does not happen —
;; the CLI removes its own file — but a session killed with SIGKILL
;; leaves one behind, so every entry is checked against the process
;; table before it is believed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'filenotify)
(require 'ecc-core)
(require 'ecc-protocol)

(defcustom ecc-registry-directory "~/.claude/sessions/"
  "Directory in which Claude Code records the sessions it is running.
One JSON file per process, named after its process id."
  :type 'directory
  :group 'ecc)

(defcustom ecc-registry-check-process t
  "Non-nil ignores a session whose process is not running any more.
The CLI deletes its own file, so an entry that outlives its process is
one that was killed; believing it would show a session that cannot be
reached.  Turning this off is only useful where `process-attributes'
says nothing useful."
  :type 'boolean
  :group 'ecc)

;;;; Reading

(defun ecc-registry-files ()
  "Return the session files of `ecc-registry-directory'."
  (let ((directory (expand-file-name ecc-registry-directory)))
    (when (file-directory-p directory)
      (directory-files directory t "\\.json\\'"))))

(defconst ecc-registry-proc-start-format "%a %b %e %H:%M:%S %Y"
  "How the CLI writes the start time of its process, in UTC.
The `procStart' field of a session file; checked against
`process-attributes' on this machine, see docs/verified.md.")

(defun ecc-registry--alive-p (entry)
  "Return non-nil when the process of ENTRY is still running.
The process id alone is not enough: a session killed outright leaves
its file behind, and its id is handed to something else soon after.
When the CLI recorded when it started, that has to match, and it is
only believed when the process table really says so — a process that
has just been killed is still in the table for a moment, but with
nothing in it to confirm."
  (or (not ecc-registry-check-process)
      (when-let* ((pid (alist-get 'pid entry))
                  ((integerp pid))
                  (attributes (process-attributes pid))
                  ((not (equal (alist-get 'state attributes) "Z"))))
        (let ((recorded (alist-get 'procStart entry))
              (start (alist-get 'start attributes)))
          (if (stringp recorded)
              (and start
                   (equal recorded
                          (format-time-string ecc-registry-proc-start-format
                                              start t)))
            ;; The file says nothing about when it started, so the id is
            ;; all there is to go on.
            t)))))

(defun ecc-registry-sessions ()
  "Return what Claude Code says about the sessions it is running.
Each is the alist of one session file: `pid', `sessionId', `cwd',
`name', `status', `kind', `entrypoint', `startedAt', `version' and,
where there is one, `tmux' and `messagingSocketPath'.  Newest first.
Entries whose process is gone, and files that do not parse, are left
out."
  (let ((entries (seq-keep (lambda (file)
                             (let ((entry (ecc-protocol-read-json-file file)))
                               (when (and entry
                                          (alist-get 'sessionId entry)
                                          (ecc-registry--alive-p entry))
                                 entry)))
                           (ecc-registry-files))))
    (seq-sort (lambda (a b) (> (or (alist-get 'startedAt a) 0)
                               (or (alist-get 'startedAt b) 0)))
              entries)))

(defun ecc-registry-session (session-id)
  "Return what Claude Code says about SESSION-ID, or nil when it is not running."
  (seq-find (lambda (entry) (equal (alist-get 'sessionId entry) session-id))
            (ecc-registry-sessions)))

(defun ecc-registry-live-p (session-id)
  "Return non-nil when SESSION-ID is running in some process right now."
  (and (ecc-registry-session session-id) t))

(defun ecc-registry-in-directory (root &optional entries)
  "Return the running sessions whose working directory is under ROOT.
ENTRIES defaults to `ecc-registry-sessions'.  Both paths have their
symbolic links resolved first: the CLI records the resolved one."
  (let ((root (file-name-as-directory (file-truename (expand-file-name root)))))
    (seq-filter (lambda (entry)
                  (when-let* ((cwd (alist-get 'cwd entry)))
                    (string-prefix-p root (file-name-as-directory
                                           (file-truename cwd)))))
                (or entries (ecc-registry-sessions)))))

(defun ecc-registry-describe (entry)
  "Return a one line description of the running session ENTRY."
  (format "%s  %s  %s"
          (or (alist-get 'name entry) (alist-get 'sessionId entry) "?")
          (or (alist-get 'status entry) (alist-get 'kind entry) "?")
          (abbreviate-file-name (or (alist-get 'cwd entry) ""))))

;;;; Watching (FR-DASH-6)

(defvar ecc-registry--watch nil
  "The file notification descriptor of the registry watch, or nil.")

(defvar ecc-registry-changed-hook nil
  "Functions run, with no arguments, when a session started or stopped.")

(defun ecc-registry--notify (_event)
  "Announce that the registry directory changed."
  (run-hooks 'ecc-registry-changed-hook))

(defun ecc-registry-watch ()
  "Watch the registry directory and announce every change.
Returns the descriptor, or nil when the directory cannot be watched;
a caller that needs to be current anyway should keep a slow timer as
well, because a file notification is a courtesy, not a promise."
  (unless (and ecc-registry--watch (file-notify-valid-p ecc-registry--watch))
    (let ((directory (expand-file-name ecc-registry-directory)))
      (setq ecc-registry--watch
            (when (file-directory-p directory)
              (ignore-errors
                (file-notify-add-watch directory '(change)
                                       #'ecc-registry--notify))))))
  ecc-registry--watch)

(defun ecc-registry-unwatch ()
  "Stop watching the registry directory."
  (when ecc-registry--watch
    (ignore-errors (file-notify-rm-watch ecc-registry--watch))
    (setq ecc-registry--watch nil)))

(provide 'ecc-registry)

;;; ecc-registry.el ends here
