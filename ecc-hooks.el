;;; ecc-hooks.el --- the hooks a session would run  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; What the CLI would run, and when: a buffer listing every hook that
;; applies to a project, gathered from the settings files and the
;; plugins that define them, grouped by the event that fires them.
;;
;; The CLI has a `/hooks' of its own and it is read-only -- "To add or
;; modify hooks, edit settings.json directly or ask Claude" (2.1.270).
;; This one edits: `a' adds a hook, `k' removes one, `t' switches one
;; off and on again.  What it will not do is guess.  A hook is a command
;; the CLI runs unsandboxed on every matching tool call, so nothing is
;; written without a confirmation that names the file and the command.
;;
;; A hook is addressed by the file it lives in, its event, and where it
;; sits among that event's matcher groups; `ecc-protocol' does the
;; reading and the writing, and nothing here touches JSON.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)

(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function ecc-prompt-command-name "ecc-prompt" (text))
(defvar ecc-prompt-immediate-commands)

;;;; What the CLI knows

;; The events, and what a matcher means for each of them.  Read out of
;; the CLI itself (2.1.270, 2026-09-13), where the list is a good deal
;; longer than the documented one; the value says what the matcher is
;; matched against, and nil says the event takes no matcher at all.
;; This is a table of the CLI's own vocabulary rather than anything the
;; user chooses, so it is a `defvar': a CLI that grows another event can
;; be caught up with a `setq' rather than a release.

(defvar ecc-hook-events
  '(("PreToolUse" . tool)
    ("PostToolUse" . tool)
    ("PostToolUseFailure" . tool)
    ("PostToolBatch" . nil)
    ("PermissionRequest" . tool)
    ("PermissionDenied" . tool)
    ("Notification" . nil)
    ("UserPromptSubmit" . nil)
    ("UserPromptExpansion" . command)
    ("SessionStart" . source)
    ("SessionEnd" . nil)
    ("Stop" . nil)
    ("StopFailure" . nil)
    ("SubagentStart" . nil)
    ("SubagentStop" . nil)
    ("PreCompact" . trigger)
    ("PostCompact" . trigger)
    ("PreModelSwitch" . model)
    ("PostModelSwitch" . model)
    ("Setup" . trigger)
    ("TeammateIdle" . nil)
    ("TaskCreated" . nil)
    ("TaskCompleted" . nil)
    ("Elicitation" . nil)
    ("ElicitationResult" . nil)
    ("ConfigChange" . nil)
    ("WorktreeCreate" . nil)
    ("WorktreeRemove" . nil)
    ("InstructionsLoaded" . nil)
    ("CwdChanged" . nil)
    ("FileChanged" . nil)
    ("DirectoryAdded" . nil)
    ("MessageDisplay" . nil))
  "The hook events of the CLI, and what each one matches on.
The cdr is what the matcher of that event is compared against: `tool'
a tool name, `command' the name of a slash command, `source' how the
session started, `trigger' why the event fired, `model' the model being
switched to, and nil an event that takes no matcher.")

(defvar ecc-hook-matcher-candidates
  '((tool . ("Bash" "Edit" "Write" "Read" "Glob" "Grep" "Task" "WebFetch"
             "WebSearch" "NotebookEdit" "TodoWrite" "AskUserQuestion"))
    (source . ("startup" "resume" "clear" "compact"))
    (trigger . ("manual" "auto")))
  "What to offer when a matcher is read for an event of each kind.
Only the common answers: a matcher is any of `|', `,' and a space
separated list, and the CLI checks it against
`^[a-zA-Z0-9_|, -]+$' (2.1.270).")

(defconst ecc-hooks-matcher-regexp "\\`[a-zA-Z0-9_|, -]+\\'"
  "What the CLI accepts as a matcher.
Checked here so that a matcher this package writes is one the CLI will
read back (2.1.270, 2026-09-13).")

;;;; Where the hooks of a project come from

;; Where the settings files are belongs to `ecc-protocol'
;; (`ecc-protocol-settings-files'); what is here is what only the hooks
;; need.  When the managed settings carry hooks, the CLI runs those and
;; nothing else: "Only hooks from managed settings can run" (2.1.270).

(defvar ecc-hooks-plugin-directory "~/.claude/plugins/"
  "Directory holding the installed plugins and the list of them.")

(defvar ecc-hooks-disabled-file nil
  "File holding the hooks this package has switched off.
nil means ecc-disabled-hooks.json in `ecc-protocol-user-directory'.")

(defconst ecc-hooks-scopes
  '((managed . "managed") (user . "user") (project . "project")
    (local . "local") (plugin . "plugin") (disabled . "off"))
  "The scopes a hook can come from, in the order the CLI reads them.")

(cl-defstruct ecc-hook
  "One hook of one event, as it is defined somewhere on this machine."
  event         ; "PreToolUse"
  matcher       ; "Write|Edit", or nil for one that matches everything
  type          ; command | prompt | agent | mcp_tool | http
  summary       ; the one line that says what it does
  entry         ; the entry as it was parsed, which is what is written back
  source        ; the file that defines it
  origin        ; the plugin it came from, or nil
  scope         ; one of `ecc-hooks-scopes'
  writable      ; whether this package may edit that file
  group-index   ; its address within the file, from `ecc-protocol'
  hook-index)

(defun ecc-hooks-disabled-file ()
  "Return the file holding the hooks this package has switched off."
  (or ecc-hooks-disabled-file
      (expand-file-name "ecc-disabled-hooks.json" ecc-protocol-user-directory)))

(defun ecc-hooks--plugin-hook-files ()
  "Return the hooks file of every plugin whose hooks would run.
Each is (NAME . FILE).  A plugin is installed under
`ecc-hooks-plugin-directory' and switched on and off by enabledPlugins
in the user settings; only one turned off there is left out, because
that is the only thing observed to be written for one (2.1.270,
2026-09-13).

The files are read here rather than through `ecc-plugin', which asks
the CLI with `plugin list --json': that costs a subprocess and answers
later, and this buffer is drawn at once, from files, with no session
and no CLI in reach."
  (let* ((installed (alist-get
                     'plugins
                     (ecc-protocol-read-json-file
                      (expand-file-name "installed_plugins.json"
                                        ecc-hooks-plugin-directory))))
         (enabled (alist-get
                   'enabledPlugins
                   (ecc-protocol-read-json-file
                    (expand-file-name "settings.json"
                                      ecc-protocol-user-directory))))
         (files nil))
    (pcase-dolist (`(,id . ,installs) installed)
      (unless (eq (alist-get id enabled) :false)
        (seq-doseq (install installs)
          (when-let* ((path (alist-get 'installPath install))
                      (file (expand-file-name "hooks/hooks.json" path))
                      ((file-readable-p file)))
            (push (cons (symbol-name id) file) files)))))
    (nreverse files)))

(defun ecc-hooks--summary (entry)
  "Return the one line saying what the hook ENTRY does."
  (let ((type (alist-get 'type entry)))
    (or (pcase type
          ("command" (or (alist-get 'command entry)
                         (when-let* ((args (alist-get 'args entry)))
                           (string-join (append args nil) " "))))
          ("http" (alist-get 'url entry))
          ((or "prompt" "agent") (alist-get 'prompt entry))
          ("mcp_tool" (format "%s/%s" (or (alist-get 'server entry) "?")
                              (or (alist-get 'tool entry) "?")))
          (_ nil))
        (ecc-protocol-value-string entry))))

(defun ecc-hooks--from-file (file scope &optional origin)
  "Return the hooks FILE defines, as `ecc-hook' structures of SCOPE.
ORIGIN names the plugin, for a file that belongs to one.  A file that
does not parse is passed over rather than signalled: it is one of
several, and one bad file should not take the whole list with it."
  (let ((object (ignore-errors (ecc-protocol-read-settings-file file))))
    (mapcar (lambda (plist)
              (let ((entry (plist-get plist :entry)))
                (make-ecc-hook
                 :event (plist-get plist :event)
                 :matcher (plist-get plist :matcher)
                 :type (or (alist-get 'type entry) "command")
                 :summary (ecc-hooks--summary entry)
                 :entry entry
                 :source file
                 :origin origin
                 :scope scope
                 ;; A plugin's file belongs to the plugin and a managed
                 ;; one to whoever administers the machine.  Neither is
                 ;; this package's to edit.
                 :writable (memq scope '(user project local))
                 :group-index (plist-get plist :group-index)
                 :hook-index (plist-get plist :hook-index))))
            (ecc-protocol-settings-hook-entries object))))

(defun ecc-hooks--stashed ()
  "Return the hooks this package has switched off, as `ecc-hook' structures.
The address they carry is the one in the stash, not in a settings file:
they are not in one."
  (mapcar (lambda (plist)
            (let ((entry (plist-get plist :entry)))
              (make-ecc-hook
               :event (plist-get plist :event)
               :matcher (plist-get plist :matcher)
               :type (or (alist-get 'type entry) "command")
               :summary (ecc-hooks--summary entry)
               :entry entry
               :source (plist-get plist :settings-file)
               :scope 'disabled
               :writable t
               :group-index nil
               :hook-index (plist-get plist :index))))
          (ecc-protocol-stash-entries (ecc-hooks-disabled-file))))

(defun ecc-hooks-collect (root)
  "Return every hook that bears on ROOT, as `ecc-hook' structures.
The settings files first, in the order the CLI reads them, then the
plugins, then what this package has switched off."
  (append
   (seq-mapcat (lambda (source)
                 (ecc-hooks--from-file (cdr source) (car source)))
               (ecc-protocol-settings-files root))
   (seq-mapcat (lambda (plugin)
                 (ecc-hooks--from-file (cdr plugin) 'plugin (car plugin)))
               (ecc-hooks--plugin-hook-files))
   (seq-filter (lambda (hook)
                 (member (ecc-hook-source hook)
                         (mapcar #'cdr (ecc-protocol-settings-files root))))
               (ecc-hooks--stashed))))

(defun ecc-hooks-restrictions (root)
  "Return what stops the hooks of ROOT from running, as a list of strings.
Empty when nothing does."
  (let ((notes nil))
    (when-let* ((managed (seq-find #'file-readable-p ecc-protocol-managed-files)))
      (push (format "Managed settings are in force (%s): only their hooks run."
                    (abbreviate-file-name managed))
            notes))
    (pcase-dolist (`(,_scope . ,file) (ecc-protocol-settings-files root))
      (when (ecc--json-true-p
             (alist-get 'disableAllHooks
                        (ignore-errors (ecc-protocol-read-settings-file file))))
        (push (format "disableAllHooks is on in %s: no hook runs at all."
                      (abbreviate-file-name file))
              notes)))
    (nreverse notes)))

;;;; Drawing the Hooks buffer

(defconst ecc-hooks-buffer-name "*ecc-hooks*"
  "Name of the Hooks buffer.")

(defvar-local ecc-hooks--root nil
  "The project the Hooks buffer is about.")

(defvar-local ecc-hooks--folded nil
  "Events the user has folded shut.")

(defun ecc-hooks--scope-label (hook)
  "Return the short word saying where HOOK comes from."
  (let ((scope (alist-get (ecc-hook-scope hook) ecc-hooks-scopes)))
    (if-let* ((origin (ecc-hook-origin hook)))
        (format "%s: %s" scope origin)
      scope)))

(defun ecc-hooks--label (hook)
  "Return the line describing HOOK, without its indentation."
  (let ((off (eq (ecc-hook-scope hook) 'disabled)))
    (concat
     (propertize (format "%-14s" (or (ecc-hook-matcher hook) "*"))
                 'face (if off 'ecc-dim-face 'ecc-tool-face))
     (propertize (ecc--truncate (ecc-hook-summary hook) 80)
                 'face (if off 'ecc-dim-face 'default))
     (propertize (format "  [%s]" (ecc-hooks--scope-label hook))
                 'face 'ecc-dim-face)
     (unless (equal (ecc-hook-type hook) "command")
       (propertize (format " %s" (ecc-hook-type hook)) 'face 'ecc-dim-face)))))

(defun ecc-hooks--insert-heading (key text)
  "Insert the heading TEXT of the event KEY, and say whether it is open.
The whole line carries the event, newline and all, so that TAB folds it
from wherever point stands on it."
  (let ((folded (member key ecc-hooks--folded)))
    (insert (propertize (concat (if folded "▸ " "▾ ") text "\n")
                        'face 'ecc-heading-face
                        'ecc-hooks-key key))
    (not folded)))

(defun ecc-hooks--insert-keys ()
  "Insert the line saying what the Hooks buffer answers to."
  (insert (propertize
           (concat (mapconcat
                    (lambda (pair)
                      (format "%s %s" (car pair) (cdr pair)))
                    '(("RET" . "open the file") ("TAB" . "fold")
                      ("a" . "add") ("k" . "remove") ("t" . "off/on")
                      ("g" . "refresh") ("q" . "quit"))
                    "   ")
                   "\n")
           'face 'ecc-dim-face)))

(defun ecc-hooks--events (hooks)
  "Return the events of HOOKS, the ones the CLI knows first."
  (let ((known (mapcar #'car ecc-hook-events))
        (seen (delete-dups (mapcar #'ecc-hook-event hooks))))
    (append (seq-filter (lambda (event) (member event seen)) known)
            (sort (seq-remove (lambda (event) (member event known)) seen)
                  #'string<))))

(defun ecc-hooks-draw (root)
  "Draw the hooks that bear on ROOT into the current buffer."
  (let ((inhibit-read-only t)
        (hooks (ecc-hooks-collect root)))
    (erase-buffer)
    (insert (propertize (format "Hooks of %s\n"
                                (if root (abbreviate-file-name root)
                                  "this machine"))
                        'face 'ecc-heading-face))
    (ecc-hooks--insert-keys)
    (dolist (note (ecc-hooks-restrictions root))
      (insert (propertize (concat note "\n") 'face 'ecc-error-face)))
    (insert "\n")
    (if (null hooks)
        (insert (propertize
                 (concat "No hook is defined for this project.\n"
                         "Press `a' to add one.\n")
                 'face 'ecc-dim-face))
      (dolist (event (ecc-hooks--events hooks))
        (let ((of-event (seq-filter (lambda (hook)
                                      (equal (ecc-hook-event hook) event))
                                    hooks)))
          (when (ecc-hooks--insert-heading
                 event (format "%s (%d)" event (length of-event)))
            (dolist (hook of-event)
              ;; The whole line carries the hook, its indentation and
              ;; its newline included: `a', `k' and `t' are answers to
              ;; the line point is on, not to the character under it.
              (insert (propertize (concat "  " (ecc-hooks--label hook) "\n")
                                  'ecc-hook hook)))
            (insert "\n")))))
    (goto-char (point-min))))

(defvar ecc-hooks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-hooks-visit)
    (define-key map (kbd "TAB") #'ecc-hooks-toggle)
    (define-key map (kbd "g") #'ecc-hooks-refresh)
    (define-key map (kbd "a") #'ecc-hooks-add)
    (define-key map (kbd "k") #'ecc-hooks-remove)
    (define-key map (kbd "t") #'ecc-hooks-switch)
    map)
  "Keymap of `ecc-hooks-mode'.")

(define-derived-mode ecc-hooks-mode special-mode "Claude-Hooks"
  "Major mode listing the hooks a session would run.

\\{ecc-hooks-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

(defun ecc-hooks--project-directory ()
  "Return the root of the project of the current buffer, or nil."
  (require 'project)
  (when-let* ((project (project-current nil default-directory)))
    (file-name-as-directory (expand-file-name (project-root project)))))

(defun ecc-hooks--root ()
  "Return the project the Hooks buffer should be about.
The session this buffer came from, then any session there is, then
whatever project the buffer is visiting: the hooks of a project are
worth looking at whether or not a session is running in it."
  (or ecc-hooks--root
      (when-let* ((session (or (bound-and-true-p ecc-render--session)
                               (car (ecc-model-sessions)))))
        (ecc-session-project-root session))
      (ecc-hooks--project-directory)))

;;;###autoload
(defun ecc-hooks-show (&optional root)
  "Show the hooks that would run for ROOT, the project of the session at hand."
  (interactive)
  (let ((buffer (get-buffer-create ecc-hooks-buffer-name))
        (root (or root (ecc-hooks--root))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-hooks-mode)
        (ecc-hooks-mode))
      (setq ecc-hooks--root root)
      (ecc-hooks-draw root))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-hooks-refresh ()
  "Draw the Hooks buffer again."
  (interactive)
  (let ((line (line-number-at-pos)))
    (ecc-hooks-draw ecc-hooks--root)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun ecc-hooks-toggle ()
  "Fold or unfold the event at point."
  (interactive)
  (if-let* ((key (get-text-property (point) 'ecc-hooks-key)))
      (progn
        (setq ecc-hooks--folded
              (if (member key ecc-hooks--folded)
                  (delete key ecc-hooks--folded)
                (cons key ecc-hooks--folded)))
        (ecc-hooks-refresh))
    (user-error "Not on an event")))

(defun ecc-hooks-at-point ()
  "Return the hook at point, or signal."
  (or (get-text-property (point) 'ecc-hook)
      (user-error "Not on a hook")))

(defun ecc-hooks-visit ()
  "Open the file that defines the hook at point."
  (interactive)
  (if-let* ((hook (get-text-property (point) 'ecc-hook)))
      (find-file (ecc-hook-source hook))
    (ecc-hooks-toggle)))

;;;; Editing

;; What is written here is a command the CLI will run unsandboxed, on
;; every turn that matches, without asking again.  So nothing is written
;; without a confirmation that names the file, the event and the command
;; in full -- the same bargain `ecc-perm-add-pattern' makes before it
;; adds an allow pattern.
;;
;; And what is written does not take effect at once: the CLI watches
;; only the directories that held a settings file when the session
;; started, so a session already running keeps the hooks it started with
;; until it is started again, or until its user opens `/hooks' in the
;; terminal, which reloads them (confirmed against 2.1.270, 2026-09-13).
;; Every message below says so, because a hook that seems not to fire is
;; otherwise a long afternoon.

(defun ecc-hooks--written (file what)
  "Say that WHAT happened to FILE, and that a running session has not seen it."
  (message "%s: %s.  A session already running keeps the hooks it started \
with until it is started again" (abbreviate-file-name file) what))

(defun ecc-hooks--redraw ()
  "Draw the Hooks buffer again, if this is one."
  (when (derived-mode-p 'ecc-hooks-mode)
    (ecc-hooks-refresh)))

(defun ecc-hooks-writable-files (root)
  "Return the settings files of ROOT this package may write, as (LABEL . FILE).
The one that is not committed comes first: a hook is a command that
runs on this machine, and offering to put it in a file the whole team
shares should take a deliberate answer."
  (let ((files (ecc-protocol-settings-files root)))
    (delq nil
          (mapcar (lambda (scope)
                    (when-let* ((file (alist-get scope files)))
                      (cons (format "%s  (%s)"
                                    (alist-get scope ecc-hooks-scopes)
                                    (abbreviate-file-name file))
                            file)))
                  '(local project user)))))

(defun ecc-hooks--read-event ()
  "Read the event a new hook fires on."
  (completing-read "Event: " (mapcar #'car ecc-hook-events) nil nil nil nil
                   "PreToolUse"))

(defun ecc-hooks--read-matcher (event)
  "Read the matcher of a new hook of EVENT, or return nil.
An event that takes no matcher is not asked about, and an empty answer
means every one.  A matcher of the CLI is a `|' separated list, so they
are read one at a time until an empty answer ends the list, and joined
with `|' here: `Write' then `Edit' writes \"Write|Edit\"."
  (when-let* ((kind (alist-get event ecc-hook-events nil nil #'equal)))
    (let ((candidates (alist-get kind ecc-hook-matcher-candidates))
          (parts nil)
          (reading t))
      (while reading
        (let ((part (string-trim
                     (completing-read
                      (if parts
                          (format "Matcher (%s so far, empty to finish): "
                                  (string-join (reverse parts) "|"))
                        (format "Matcher (%s, empty for every one): " kind))
                      (seq-remove (lambda (one) (member one parts)) candidates)
                      nil nil))))
          (if (string-empty-p part)
              (setq reading nil)
            (push part parts))))
      (let ((matcher (string-join (nreverse parts) "|")))
        (cond ((string-empty-p matcher) nil)
              ((string-match-p ecc-hooks-matcher-regexp matcher) matcher)
              (t (user-error
                  "The CLI will not read %S as a matcher: only letters, digits, \
`_', `-', `|', `,' and spaces" matcher)))))))

(defun ecc-hooks--read-command (event)
  "Read the shell command a new hook of EVENT runs."
  (let ((command (string-trim
                  (read-string (format "Shell command to run on %s: " event)))))
    (if (string-empty-p command)
        (user-error "No command given")
      command)))

;;;###autoload
(defun ecc-hooks-add (file event matcher command)
  "Add a command hook running COMMAND on EVENT, under MATCHER, to FILE.
Interactively the event, the matcher, the command and the settings file
are read in that order, and the whole of it is named in a confirmation
before anything is written."
  (interactive
   (let* ((root (ecc-hooks--root))
          (event (ecc-hooks--read-event))
          (matcher (ecc-hooks--read-matcher event))
          (command (ecc-hooks--read-command event))
          (choices (or (ecc-hooks-writable-files root)
                       (user-error "No settings file to write to")))
          (file (cdr (assoc (completing-read "Write it to: " choices nil t nil nil
                                             (caar choices))
                            choices))))
     (unless (y-or-n-p (format "Run %s on every %s%s, from %s? "
                               command event
                               (if matcher (format " matching %s" matcher) "")
                               (abbreviate-file-name file)))
       (user-error "Nothing written"))
     (list file event matcher command)))
  (ecc-protocol-settings-add-hook file event matcher
                                  (list (cons 'type "command")
                                        (cons 'command command)))
  (ecc-hooks--written file (format "%s hook added" event))
  (ecc-hooks--redraw))

(defun ecc-hooks-remove ()
  "Remove the hook at point, for good.
A hook that is switched off is forgotten rather than put back."
  (interactive)
  (let* ((hook (ecc-hooks-at-point))
         (off (eq (ecc-hook-scope hook) 'disabled))
         (file (ecc-hook-source hook)))
    (unless (ecc-hook-writable hook)
      (user-error "%s is not this package's to edit: %s"
                  (abbreviate-file-name file)
                  (if (ecc-hook-origin hook)
                      "it belongs to a plugin"
                    "it is the administrator's")))
    (unless (y-or-n-p (format "%s %s from %s? "
                              (if off "Forget the switched-off" "Remove the")
                              (ecc-hook-event hook) (abbreviate-file-name file)))
      (user-error "Nothing written"))
    (if off
        (progn (ecc-protocol-stash-remove (ecc-hooks-disabled-file) file
                                          (ecc-hook-event hook)
                                          (ecc-hook-hook-index hook))
               (message "Forgot the switched-off %s hook of %s"
                        (ecc-hook-event hook) (abbreviate-file-name file)))
      (ecc-protocol-settings-remove-hook file (ecc-hook-event hook)
                                         (ecc-hook-group-index hook)
                                         (ecc-hook-hook-index hook))
      (ecc-hooks--written file (format "%s hook removed" (ecc-hook-event hook))))
    (ecc-hooks--redraw)))

(defun ecc-hooks-switch ()
  "Switch the hook at point off, or on again.
The CLI has no way of saying that a hook is there but switched off, so
switching one off takes it out of its settings file and into a file of
this package\\='s own; switching it on again puts it back where it was."
  (interactive)
  (let* ((hook (ecc-hooks-at-point))
         (file (ecc-hook-source hook))
         (event (ecc-hook-event hook)))
    (unless (ecc-hook-writable hook)
      (user-error "%s is not this package's to edit"
                  (abbreviate-file-name file)))
    (if (eq (ecc-hook-scope hook) 'disabled)
        (let ((entry (ecc-protocol-stash-remove
                      (ecc-hooks-disabled-file) file event
                      (ecc-hook-hook-index hook))))
          (ecc-protocol-settings-add-hook file event (ecc-hook-matcher hook) entry)
          (ecc-hooks--written file (format "%s hook switched back on" event)))
      (let ((entry (ecc-protocol-settings-remove-hook
                    file event (ecc-hook-group-index hook)
                    (ecc-hook-hook-index hook))))
        (ecc-protocol-stash-add (ecc-hooks-disabled-file) file event
                                (ecc-hook-matcher hook) entry)
        (ecc-hooks--written file (format "%s hook switched off" event))))
    (ecc-hooks--redraw)))

;;;; The way in: the prompt region

;; The CLI has a `/hooks' of its own, and a headless client is never
;; told about it: its definition carries `requires: {ink: true}', so it
;; is in neither `slash_commands' nor `terminal_slash_commands' of
;; system/init, and the terminal client catches it in its own input
;; layer (confirmed against 2.1.270, 2026-09-13).  Typed into the prompt
;; it would go to the model as a sentence, so Emacs answers it here --
;; the same way `/btw' and the three of `ecc-auth' are answered.

(defconst ecc-hooks-command "/hooks"
  "What to type in the prompt region to open the Hooks buffer.
The CLI's own command of that name is a terminal menu a headless client
cannot open, so this shadows nothing.")

(defun ecc-hooks-intercept (session text)
  "Answer TEXT here when it is `/hooks', for SESSION.
Returns non-nil when it did, which is what keeps the draft from being
sent as a prompt.  This is on `ecc-prompt-intercept-functions'."
  (when (equal (ecc-prompt-command-name text) ecc-hooks-command)
    (ecc-hooks-show (and session (ecc-session-project-root session)))
    t))

(with-eval-after-load 'ecc-prompt
  (add-hook 'ecc-prompt-intercept-functions #'ecc-hooks-intercept)
  ;; It takes no argument, so choosing it in the prompt region is
  ;; already the whole of it.
  (add-to-list 'ecc-prompt-immediate-commands ecc-hooks-command))

(provide 'ecc-hooks)

;;; ecc-hooks.el ends here
