;;; ecc-plugin.el --- Browsing and managing the plugins  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The `/plugins' of the terminal client, drawn by Emacs.
;;
;; `/plugins' is not a slash command.  The CLI names it neither in
;; `slash_commands' nor in `terminal_slash_commands' -- that list is
;; `doctor', `color' and `reload-plugins' (measured against 2.1.270,
;; 2026-09-13).  It is a screen the terminal client draws for itself, so
;; there is nothing to send over stream-json and nothing to draw from
;; the answer.
;;
;; What the CLI does offer a program is subcommands (2.1.270):
;;
;;     claude plugin list [--available] --json
;;     claude plugin details <name>
;;     claude plugin install|uninstall|enable|disable|update <plugin> \
;;         [--json] [-s user|project|local] [-y]
;;     claude plugin prune [--dry-run] [-y]
;;     claude plugin marketplace list --json
;;     claude plugin marketplace add|remove|update <source>
;;
;; So this module reads through the CLI, draws the five tabs of the real
;; screen itself, and acts through the CLI again.  Two quirks of the
;; subcommands it has to live with: `-y' is required whenever stdout is
;; not a terminal, which is always the case here, and `details' is the
;; one subcommand without a `--json', so its text is shown as it comes.
;;
;; A change reaches a running session through `/reload-plugins', which
;; makes the CLI resend its command list; see
;; `ecc-plugin-tell-sessions'.
;;
;; The real screen has a Stats tab as well, a table of the skills a
;; session loaded with the tokens they were charged over a week.  It is
;; computed by scanning the local sessions and nothing exports it, so
;; there is no Stats tab here rather than a tab of something else
;; wearing its name.  What one plugin brings and costs is in its
;; description buffer, from `claude plugin details'.
;;
;; Nothing reports the plugin load errors the real Errors tab lists
;; either, so Errors holds what Emacs can see for itself: a subcommand
;; that failed, and an installed plugin whose directory is gone.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)

(declare-function ecc-window-project-root "ecc-window" (&optional directory))
(declare-function ecc-prompt-command-name "ecc-prompt" (text))
(declare-function ecc-prompt-command-argument "ecc-prompt" (text))

;;;; Options

(defvar ecc-plugin-reload-sessions 'ask
  "What running sessions are told after the plugins have changed.
The CLI reads its plugins when it starts and when it is asked to reload
them, so a session that was already running carries on with the ones it
started with.  `ask' offers to send `/reload-plugins\\=' to the running
sessions, nil leaves them alone without a word, and t sends it without
asking.  The command is queued behind a turn that is running, so nothing
is interrupted.

A `defvar' and not a `defcustom': asking before interrupting a session
is what this should do, and the other two values are for a test and for
somebody who has already decided.  `setq' reaches it all the same.")

(defvar ecc-plugin-buffer-name "*claude-plugins*"
  "Name of the buffer the plugins are browsed in.")

(defvar ecc-plugin-scopes '("user" "project" "local")
  "The scopes a plugin can be installed at, as the CLI spells them.
`user' is this machine, `project' is the repository and everyone who
works in it, and `local' is this repository for this user alone.")

;;;; Asking the CLI

(defvar ecc-plugin-log-name "plugin"
  "Name of the log buffer the plugin subprocesses are logged to.")

(defun ecc-plugin--call (args callback)
  "Run the CLI with ARGS and call CALLBACK with (EXIT OUTPUT).
The one place a subprocess is started from, so that a test can stand in
for it.  The call is asynchronous: reading the catalog goes out to the
marketplaces, and Emacs must not sit and wait for it."
  (let ((output "")
        (command (cons ecc-executable args)))
    (ecc-log ecc-plugin-log-name "%s"
             (mapconcat #'shell-quote-argument command " "))
    (make-process
     :name "ecc-plugin"
     :command command
     :connection-type 'pipe
     :coding 'utf-8-unix
     :noquery t
     :filter (lambda (_process chunk) (setq output (concat output chunk)))
     :sentinel (lambda (process _event)
                 (unless (process-live-p process)
                   (funcall callback (process-exit-status process) output))))))

(defun ecc-plugin--json (output)
  "Return the JSON of OUTPUT, or signal an error naming what came instead.
The answer is pretty-printed over many lines, so it cannot be read line
by line; it is read from the first bracket to the end instead, which
steps over a warning or a progress line printed before it."
  (let ((start (string-match-p "[][{]" output)))
    (or (and start (ignore-errors (ecc--json-read (substring output start))))
        (error "No JSON in the answer: %s" (ecc--truncate output 200)))))

;;;; What a plugin and a marketplace are here

(cl-defstruct (ecc-plugin-entry (:constructor ecc-plugin-entry-create)
                                (:copier nil))
  "One plugin, installed or merely offered by a marketplace."
  id            ; name@marketplace, the word every subcommand takes
  name          ; the half before the @
  marketplace   ; the half after it
  version
  description
  installs      ; how many machines have it, from the catalog
  scope         ; user | project | local, of an installed one
  enabled       ; nil for one turned off with `claude plugin disable'
  path          ; where it is unpacked, of an installed one
  source        ; where the marketplace fetches it from
  installed)    ; non-nil for one that is installed

(cl-defstruct (ecc-plugin-market (:constructor ecc-plugin-market-create)
                                 (:copier nil))
  "One marketplace."
  name
  source        ; github | url | path, as the CLI reports it
  repo          ; the repository or URL behind it
  location)     ; where it is checked out

(defun ecc-plugin--split-id (id)
  "Return (NAME . MARKETPLACE) of the plugin called ID.
An ID is `name@marketplace\\='; one without an @ is all name."
  (if (string-match "\\`\\(.*\\)@\\([^@]*\\)\\'" (or id ""))
      (cons (match-string 1 id) (match-string 2 id))
    (cons (or id "") nil)))

(defun ecc-plugin--installed-entry (plugin)
  "Return the entry of the installed PLUGIN, an alist of the CLI."
  (let* ((id (alist-get 'id plugin))
         (split (ecc-plugin--split-id id)))
    (ecc-plugin-entry-create
     :id id :name (car split) :marketplace (cdr split)
     :version (alist-get 'version plugin)
     :scope (alist-get 'scope plugin)
     ;; `enabled' is a JSON boolean, and JSON false reads as `:false',
     ;; which is a symbol and therefore true to Emacs.
     :enabled (ecc--json-true-p (alist-get 'enabled plugin))
     :path (alist-get 'installPath plugin)
     :installed t)))

(defun ecc-plugin--catalog-entry (plugin installed)
  "Return the entry of the offered PLUGIN, an alist of the CLI.
INSTALLED is the list of installed entries, which says whether this one
is already in and at which version."
  (let* ((id (alist-get 'pluginId plugin))
         (split (ecc-plugin--split-id id))
         (mine (seq-find (lambda (entry)
                           (equal (ecc-plugin-entry-id entry) id))
                         installed)))
    (ecc-plugin-entry-create
     :id id
     :name (or (alist-get 'name plugin) (car split))
     :marketplace (or (alist-get 'marketplaceName plugin) (cdr split))
     :version (and mine (ecc-plugin-entry-version mine))
     :description (alist-get 'description plugin)
     :installs (alist-get 'installCount plugin)
     :scope (and mine (ecc-plugin-entry-scope mine))
     :enabled (and mine (ecc-plugin-entry-enabled mine))
     :path (and mine (ecc-plugin-entry-path mine))
     :source (alist-get 'source plugin)
     :installed (and mine t))))

(defun ecc-plugin-parse-installed (output)
  "Return the entries of OUTPUT, the answer of `plugin list --json\\='."
  (mapcar #'ecc-plugin--installed-entry (append (ecc-plugin--json output) nil)))

(defun ecc-plugin-parse-catalog (output)
  "Return the entries of OUTPUT, of `plugin list --available --json\\='.
The answer holds both lists; the installed one is read first so that an
offered plugin knows whether it is already in.  An installed plugin no
marketplace offers any more is kept, at the end: it is on the machine
and has to be manageable."
  (let* ((answer (ecc-plugin--json output))
         (installed (mapcar #'ecc-plugin--installed-entry
                            (append (alist-get 'installed answer) nil)))
         (offered (mapcar (lambda (plugin)
                            (ecc-plugin--catalog-entry plugin installed))
                          (append (alist-get 'available answer) nil)))
         (orphans (seq-remove
                   (lambda (entry)
                     (seq-find (lambda (other)
                                 (equal (ecc-plugin-entry-id other)
                                        (ecc-plugin-entry-id entry)))
                               offered))
                   installed)))
    (append offered orphans)))

(defun ecc-plugin-parse-marketplaces (output)
  "Return the marketplaces of OUTPUT, of `marketplace list --json\\='."
  (mapcar (lambda (market)
            (ecc-plugin-market-create
             :name (alist-get 'name market)
             :source (alist-get 'source market)
             :repo (or (alist-get 'repo market) (alist-get 'url market)
                       (alist-get 'path market))
             :location (alist-get 'installLocation market)))
          (append (ecc-plugin--json output) nil)))

;;;; Skills, and the overrides that turn them off

(defvar ecc-plugin-user-skills-directory "~/.claude/skills/"
  "Where the skills of this machine live, one directory each.")

(defvar ecc-plugin-user-settings-file "~/.claude/settings.json"
  "The settings file of this machine, which holds `skillOverrides'.")

(defvar ecc-plugin-project-settings-files
  '(".claude/settings.json" ".claude/settings.local.json")
  "The settings files of a project, relative to its root.")

(defvar ecc-plugin-skill-states '("on" "name-only" "user-invocable-only" "off")
  "What a skill can be set to, least restrictive first.
The values of `skillOverrides' in the settings (2.1.270): `name-only'
lists the skill without its description, `user-invocable-only' hides it
from the model but keeps `/name', and `off' hides it from both.  A skill
no override names is on.

The order is the one the CLI ranks them by.  An override is merged
across the settings scopes by taking the most restrictive of them, not
the nearest one, so a project that turns a skill off cannot be undone by
turning it on in the user settings.")

(cl-defstruct (ecc-plugin-skill (:constructor ecc-plugin-skill-create)
                                (:copier nil))
  "One skill the CLI would load."
  name
  scope         ; user | project | plugin | built-in
  origin        ; the plugin a plugin skill came from
  path          ; its directory, where there is one
  description
  state         ; one of `ecc-plugin-skill-states'
  from)         ; the settings file the state came from, or nil

(defun ecc-plugin--read-settings (file)
  "Return the JSON of FILE as an alist, or nil when there is none.
Read verbatim: a settings file is written back out again, and the
ordinary reader turns a JSON null into nil, which serializes back as an
empty object."
  (let ((file (expand-file-name file)))
    (when (file-readable-p file)
      (condition-case error
          (ecc--json-read-verbatim
           (with-temp-buffer
             (let ((coding-system-for-read 'utf-8))
               (insert-file-contents file))
             (buffer-string)))
        (error (ecc-log ecc-plugin-log-name "%s is not JSON: %s" file
                        (error-message-string error))
               nil)))))

(defun ecc-plugin-settings-files (&optional project)
  "Return the settings files that can hold an override, user file first.
PROJECT is the directory whose settings are read besides the user ones."
  (cons ecc-plugin-user-settings-file
        (when project
          (mapcar (lambda (name) (expand-file-name name project))
                  ecc-plugin-project-settings-files))))

(defun ecc-plugin--restrictiveness (state)
  "Return how restrictive STATE is, as a number."
  (or (seq-position ecc-plugin-skill-states state) 0))

(defun ecc-plugin-skill-overrides (&optional project)
  "Return the effective skill overrides as an alist of name and (STATE . FILE).
Every settings file of PROJECT and of the user is read, and the most
restrictive value of them wins, which is how the CLI merges them."
  (let ((merged nil))
    (dolist (file (ecc-plugin-settings-files project))
      (pcase-dolist (`(,name . ,state)
                     (alist-get 'skillOverrides (ecc-plugin--read-settings file)))
        (let* ((name (format "%s" name))
               (known (cdr (assoc name merged))))
          (when (and (stringp state)
                     (or (null known)
                         (> (ecc-plugin--restrictiveness state)
                            (ecc-plugin--restrictiveness (car known)))))
            (setf (alist-get name merged nil nil #'equal)
                  (cons state (expand-file-name file)))))))
    merged))

(defun ecc-plugin--skill-description (directory)
  "Return the description in the frontmatter of the SKILL.md in DIRECTORY."
  (let ((file (expand-file-name "SKILL.md" directory)))
    (when (file-readable-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          ;; The frontmatter is at the top; the body can be long.
          (insert-file-contents file nil 0 4096))
        (goto-char (point-min))
        (when (re-search-forward "^description:[ \t]*\\(.*\\)$" nil t)
          (string-trim (match-string 1)))))))

(defun ecc-plugin--skills-in (directory scope &optional origin)
  "Return the skills of DIRECTORY, each at SCOPE and from ORIGIN."
  (let ((directory (expand-file-name directory)))
    (when (file-directory-p directory)
      (seq-keep
       (lambda (child)
         (when (and (file-directory-p child)
                    (file-exists-p (expand-file-name "SKILL.md" child)))
           (ecc-plugin-skill-create
            :name (file-name-nondirectory (directory-file-name child))
            :scope scope :origin origin :path child
            :description (ecc-plugin--skill-description child))))
       (directory-files directory t directory-files-no-dot-files-regexp)))))

(defun ecc-plugin--session-skills ()
  "Return the names of the skills a running session says it loaded.
The bundled skills are not on the disk anywhere Emacs can see; the
`skills' of system/init is the only place they are named, and only a
session that has spoken has one."
  (seq-some (lambda (session)
              (let ((names (alist-get 'skills (ecc-session-init session))))
                (and names (> (length names) 0)
                     (seq-filter #'stringp (append names nil)))))
            (ecc-model-sessions)))

(defun ecc-plugin-skills (&optional project plugins)
  "Return every skill Emacs can see, with the state of each.
PROJECT is the directory whose own skills and settings are read, and
PLUGINS the installed plugins, whose skills are read from where they are
unpacked.  The bundled skills come from a running session."
  (let* ((overrides (ecc-plugin-skill-overrides project))
         (skills (append
                  (ecc-plugin--skills-in ecc-plugin-user-skills-directory 'user)
                  (when project
                    (ecc-plugin--skills-in
                     (expand-file-name ".claude/skills" project) 'project))
                  (seq-mapcat
                   (lambda (plugin)
                     (when-let* ((path (ecc-plugin-entry-path plugin)))
                       (ecc-plugin--skills-in (expand-file-name "skills" path)
                                              'plugin
                                              (ecc-plugin-entry-id plugin))))
                   plugins)))
         (named (mapcar #'ecc-plugin-skill-name skills)))
    (dolist (name (ecc-plugin--session-skills))
      (unless (member name named)
        (push (ecc-plugin-skill-create :name name :scope 'built-in) skills)))
    (dolist (skill skills)
      (let ((override (cdr (assoc (ecc-plugin-skill-name skill) overrides))))
        (setf (ecc-plugin-skill-state skill) (or (car override) "on"))
        (setf (ecc-plugin-skill-from skill) (cdr override))))
    (sort skills (lambda (a b) (string< (ecc-plugin-skill-name a)
                                        (ecc-plugin-skill-name b))))))

(defun ecc-plugin-skill-on-p (skill)
  "Return non-nil when SKILL is listed to the model in full."
  (equal (ecc-plugin-skill-state skill) "on"))

(defun ecc-plugin-set-skill-state (name state &optional file)
  "Write STATE for the skill NAME into FILE, the user settings by default.
STATE nil removes the override, which is what turns a skill back on.
The file is rewritten as JSON, so it comes back formatted rather than as
it was written by hand."
  (let* ((file (expand-file-name (or file ecc-plugin-user-settings-file)))
         (settings (ecc-plugin--read-settings file))
         (overrides (alist-get 'skillOverrides settings))
         (key (intern name)))
    (cond
     ((and state (assq key overrides)) (setf (alist-get key overrides) state))
     (state (setq overrides (append overrides (list (cons key state)))))
     (t (setq overrides (assq-delete-all key overrides))))
    ;; A key is put at the end and taken away when it empties: the file
    ;; belongs to the user and to the CLI, and comes back reordered or
    ;; carrying an empty object neither of them wrote otherwise.
    (cond
     ((and overrides (assq 'skillOverrides settings))
      (setf (alist-get 'skillOverrides settings) overrides))
     (overrides
      (setq settings (append settings (list (cons 'skillOverrides overrides)))))
     (t (setq settings (assq-delete-all 'skillOverrides settings))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((coding-system-for-write 'utf-8))
        (insert (ecc--json-write settings))
        (json-pretty-print-buffer)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))))
    (ecc-log ecc-plugin-log-name "skillOverrides %s = %s in %s"
             name (or state "on") file)
    file))

;;;; Reading

(defun ecc-plugin-read (args parse callback)
  "Run the CLI with ARGS, parse its answer with PARSE and hand it to CALLBACK.
CALLBACK is called with the parsed value, or with nil and a second
argument saying what went wrong.  A read is never believed on the exit
code alone: the CLI prints its answer and exits non-zero in cases that
are not failures, so the parse is what decides."
  (ecc-plugin--call
   args
   (lambda (exit output)
     (condition-case error
         (funcall callback (funcall parse output) nil)
       (error
        (funcall callback nil
                 (format "%s %s failed (%s): %s"
                         ecc-executable (string-join args " ") exit
                         (error-message-string error))))))))

(defun ecc-plugin-read-installed (callback)
  "Call CALLBACK with the installed plugins, or nil and a message."
  (ecc-plugin-read '("plugin" "list" "--json")
                   #'ecc-plugin-parse-installed callback))

(defun ecc-plugin-read-catalog (callback)
  "Call CALLBACK with every plugin the marketplaces offer."
  (ecc-plugin-read '("plugin" "list" "--available" "--json")
                   #'ecc-plugin-parse-catalog callback))

(defun ecc-plugin-read-marketplaces (callback)
  "Call CALLBACK with the marketplaces that are configured."
  (ecc-plugin-read '("plugin" "marketplace" "list" "--json")
                   #'ecc-plugin-parse-marketplaces callback))

(defun ecc-plugin-read-details (name callback)
  "Call CALLBACK with what `plugin details\\=' says about NAME.
The text is handed over as it came: `details' is the one subcommand
without a `--json' (2.1.270)."
  (ecc-plugin--call
   (list "plugin" "details" name)
   (lambda (exit output)
     (if (and (zerop exit) (not (string-empty-p (string-trim output))))
         (funcall callback (string-trim-right output) nil)
       (funcall callback nil (format "%s plugin details %s failed (%s): %s"
                                     ecc-executable name exit
                                     (ecc--truncate output 200)))))))

;;;; The buffer

(defvar ecc-plugin-tabs
  '((discover . "Discover")
    (installed . "Installed")
    (marketplaces . "Marketplaces")
    (errors . "Errors"))
  "The tabs of the plugin browser, in the order the real screen has them.")

(defvar-local ecc-plugin--tab 'discover
  "The tab the plugin browser is showing.")

(defvar-local ecc-plugin--filter nil
  "What the rows are filtered by, or nil for all of them.")

(defvar-local ecc-plugin--folded nil
  "Keys of the groups the user has folded shut.")

(defvar-local ecc-plugin--catalog nil
  "Every plugin the marketplaces offer, as entries.")

(defvar-local ecc-plugin--installed nil
  "The installed plugins, as entries.")

(defvar-local ecc-plugin--markets nil
  "The marketplaces that are configured.")

(defvar-local ecc-plugin--skills nil
  "The skills Emacs can see, as `ecc-plugin-skill' structs.")

(defvar-local ecc-plugin--project nil
  "The project whose own skills and settings are read, or nil.")

(defvar-local ecc-plugin--errors nil
  "What has gone wrong, newest last: a list of strings.")

(defvar-local ecc-plugin--loading nil
  "What is being read right now: a list of symbols.")

(defun ecc-plugin--installs (count)
  "Return COUNT as the short number the real screen shows."
  (cond ((not (numberp count)) nil)
        ((>= count 1000000) (format "%.1fM installs" (/ count 1000000.0)))
        ((>= count 1000) (format "%.1fK installs" (/ count 1000.0)))
        (t (format "%d installs" count))))

(defun ecc-plugin--source-label (source)
  "Return a line naming SOURCE, which the CLI writes as a string or an alist."
  (cond ((stringp source) source)
        ((consp source)
         (or (alist-get 'url source)
             (alist-get 'repo source)
             (alist-get 'path source)
             (alist-get 'source source)))))

(defun ecc-plugin-disabled-here-p (entry)
  "Return non-nil when ENTRY is one this Emacs turns off for its sessions.
`ecc-disabled-plugins' is passed to every session ecc starts and is a
different thing from `claude plugin disable\\=', which turns the plugin
off for the terminal as well."
  (and (member (ecc-plugin-entry-id entry) ecc-disabled-plugins) t))

(defun ecc-plugin--state-label (entry)
  "Return how ENTRY stands: installed, on or off, and off here."
  (cond
   ((not (ecc-plugin-entry-installed entry)) nil)
   ((not (ecc-plugin-entry-enabled entry))
    (propertize "off" 'face 'ecc-dim-face))
   ((ecc-plugin-disabled-here-p entry)
    (propertize "on, off in ecc" 'face 'ecc-warning-face))
   (t (propertize "on" 'face 'ecc-ok-face))))

(defun ecc-plugin--matches-p (text)
  "Return non-nil when TEXT answers to `ecc-plugin--filter'."
  (or (null ecc-plugin--filter)
      (string-empty-p ecc-plugin--filter)
      (let ((case-fold-search t))
        (string-match-p (regexp-quote ecc-plugin--filter) (or text "")))))

(defun ecc-plugin--filtered (entries)
  "Return the ENTRIES that answer to `ecc-plugin--filter'."
  (seq-filter (lambda (entry)
                (ecc-plugin--matches-p
                 (concat (ecc-plugin-entry-id entry) " "
                         (ecc-plugin-entry-description entry))))
              entries))

;;;; Drawing

(defun ecc-plugin--insert-tabs ()
  "Insert the tab bar, marking the tab that is showing."
  (pcase-dolist (`(,tab . ,title) ecc-plugin-tabs)
    (insert (if (eq tab ecc-plugin--tab)
                (propertize (concat " " title " ") 'face 'ecc-heading-face)
              (propertize (concat " " title " ") 'face 'ecc-dim-face))
            " "))
  (insert "\n"))

(defun ecc-plugin--insert-search ()
  "Insert the search line, saying what the rows are narrowed to.
The real screen puts a search box here and filters as you type, and the
box is the only thing that says searching is possible at all."
  (insert (propertize "⌕ " 'face 'ecc-dim-face)
          (if ecc-plugin--filter
              (propertize ecc-plugin--filter 'face 'ecc-tool-face)
            (propertize "Search with s" 'face 'ecc-dim-face))
          "\n\n"))

(defvar ecc-plugin-tab-hints
  '((discover . "s search · / jump · RET details · i install · SPC on/off · g reread")
    (installed
     . "s search · / jump · RET open · SPC on/off · E state · u update · d uninstall")
    (marketplaces . "a add · u update · d remove · g reread")
    (errors . "g reread"))
  "The keys named for each tab, drawn in the header line.
A buffer that says nothing about its keys is a buffer whose keys nobody
finds.  The header line and not the foot of the buffer: the foot of a
list of 297 plugins is nowhere near the screen.")

(defun ecc-plugin-header-line ()
  "Return the keys of the tab that is showing, for the header line.
A function, because `format-mode-line\=' answers an empty string in
batch and a test has to be able to ask for the text itself."
  (concat " " (alist-get ecc-plugin--tab ecc-plugin-tab-hints) " · q quit"))

(defun ecc-plugin--insert-heading (key text)
  "Insert the heading TEXT of the group KEY and return non-nil when open."
  (let ((folded (member key ecc-plugin--folded)))
    (insert (propertize (concat (if folded "▸ " "▾ ") text)
                        'face 'ecc-heading-face
                        'ecc-plugin-key key)
            "\n")
    (not folded)))

(defun ecc-plugin--insert-entry (entry)
  "Insert the two lines of ENTRY, carrying it as a text property."
  (let ((mark (if (ecc-plugin-entry-installed entry) "●" "◯"))
        (state (ecc-plugin--state-label entry))
        (installs (ecc-plugin--installs (ecc-plugin-entry-installs entry))))
    (insert (propertize
             (concat "  " mark " "
                     (propertize (ecc-plugin-entry-name entry)
                                 'face 'ecc-tool-face)
                     (propertize
                      (concat "  " (or (ecc-plugin-entry-marketplace entry) "?")
                              (when-let* ((version
                                           (ecc-plugin-entry-version entry)))
                                (concat " · " version))
                              (when installs (concat " · " installs)))
                      'face 'ecc-dim-face)
                     (when state (concat "  " state)))
             'ecc-plugin-entry entry)
            "\n")
    (when-let* ((description (ecc-plugin-entry-description entry)))
      (insert (propertize (concat "      " (ecc--fit description 72))
                          'face 'ecc-dim-face
                          'ecc-plugin-entry entry)
              "\n"))))

(defun ecc-plugin--insert-loading (what)
  "Insert a line saying WHAT is still being read."
  (insert (propertize (format "Reading %s…\n" what) 'face 'ecc-dim-face)))

(defun ecc-plugin--draw-discover ()
  "Draw the Discover tab."
  (let ((entries (ecc-plugin--filtered ecc-plugin--catalog)))
    (insert (propertize (format "Discover plugins (%d)" (length entries))
                        'face 'ecc-heading-face)
            "\n\n")
    (cond
     ((memq 'catalog ecc-plugin--loading) (ecc-plugin--insert-loading "the catalog"))
     ((null entries)
      (insert (propertize "Nothing to show.\n" 'face 'ecc-dim-face)))
     (t (mapc #'ecc-plugin--insert-entry entries)))))

(defvar ecc-plugin-skill-scopes
  '((user . "User") (project . "Project") (plugin . "Plugin")
    (built-in . "Built-in"))
  "The scopes a skill comes from, in the order the rows are grouped.")

(defun ecc-plugin--skill-line (skill)
  "Return the line of SKILL, without its indentation."
  (let* ((state (ecc-plugin-skill-state skill))
         (on (ecc-plugin-skill-on-p skill)))
    (concat (propertize (ecc-plugin-skill-name skill) 'face 'ecc-tool-face)
            (propertize
             (concat "  Skill · "
                     (or (ecc-plugin-skill-origin skill)
                         (format "%s" (ecc-plugin-skill-scope skill))))
             'face 'ecc-dim-face)
            "  "
            (propertize (if on "on" state)
                        'face (if on 'ecc-ok-face 'ecc-dim-face)))))

(defun ecc-plugin--insert-skill (skill)
  "Insert the row of SKILL, carrying it as a text property."
  (insert (propertize (concat "  " (if (ecc-plugin-skill-on-p skill) "●" "◯")
                              " " (ecc-plugin--skill-line skill))
                      'ecc-plugin-skill skill)
          "\n")
  (when-let* ((description (ecc-plugin-skill-description skill)))
    (insert (propertize (concat "      " (ecc--fit description 72))
                        'face 'ecc-dim-face 'ecc-plugin-skill skill)
            "\n")))

(defun ecc-plugin--plugin-row-line (entry)
  "Return the row of the installed plugin ENTRY, without its indentation."
  (concat (propertize (ecc-plugin-entry-name entry) 'face 'ecc-tool-face)
          (propertize (concat "  Plugin · "
                              (or (ecc-plugin-entry-marketplace entry) "?")
                              (when-let* ((version
                                           (ecc-plugin-entry-version entry)))
                                (concat " · " version))
                              (when-let* ((scope (ecc-plugin-entry-scope entry)))
                                (concat " · " scope)))
                      'face 'ecc-dim-face)
          "  "
          (or (ecc-plugin--state-label entry) "")))

(defun ecc-plugin--insert-installed-plugin (entry)
  "Insert the row of the installed plugin ENTRY."
  (insert (propertize (concat "  " (if (ecc-plugin-entry-enabled entry) "●" "◯")
                              " " (ecc-plugin--plugin-row-line entry))
                      'ecc-plugin-entry entry)
          "\n"))

(defun ecc-plugin--installed-rows ()
  "Return what the Installed tab lists: the plugins and the skills.
The real screen puts both in one list, because both are things the CLI
loads and both can be turned off."
  (append (ecc-plugin--filtered ecc-plugin--installed)
          (seq-filter (lambda (skill)
                        (ecc-plugin--matches-p
                         (concat (ecc-plugin-skill-name skill) " "
                                 (or (ecc-plugin-skill-origin skill) "") " "
                                 (ecc-plugin-skill-description skill))))
                      ecc-plugin--skills)))

(defun ecc-plugin--row-on-p (row)
  "Return non-nil when ROW, a plugin or a skill, is on."
  (if (ecc-plugin-skill-p row)
      (ecc-plugin-skill-on-p row)
    (ecc-plugin-entry-enabled row)))

(defun ecc-plugin--insert-row (row)
  "Insert ROW, whichever of the two kinds it is."
  (if (ecc-plugin-skill-p row)
      (ecc-plugin--insert-skill row)
    (ecc-plugin--insert-installed-plugin row)))

(defun ecc-plugin--insert-by-scope (rows key &optional indent)
  "Insert ROWS grouped by where they come from, under headings keyed by KEY.
INDENT is put before each heading, so that a group inside another reads
as being inside it."
  (dolist (scope (append (mapcar #'car ecc-plugin-skill-scopes)
                         ecc-plugin-scopes '(nil)))
    (let ((of-scope (seq-filter
                     (lambda (row)
                       (equal (if (ecc-plugin-skill-p row)
                                  (ecc-plugin-skill-scope row)
                                (ecc-plugin-entry-scope row))
                              scope))
                     rows)))
      (when of-scope
        (insert (or indent ""))
        (when (ecc-plugin--insert-heading
               (format "%s/%s" key scope)
               (format "%s (%d)"
                       (or (alist-get scope ecc-plugin-skill-scopes)
                           (and (stringp scope) (capitalize scope))
                           "No scope")
                       (length of-scope)))
          (mapc #'ecc-plugin--insert-row of-scope))
        (insert "\n")))))

(defun ecc-plugin--draw-installed ()
  "Draw the Installed tab: the plugins and the skills, the off ones folded.
The real screen lists both kinds together, grouped by where they come
from, and folds away what is turned off.  The two columns it also
carries -- what a skill costs in context and how often it was used --
are computed by scanning the local sessions and nothing exports them, so
they are not here."
  (let* ((rows (ecc-plugin--installed-rows))
         (on (seq-filter #'ecc-plugin--row-on-p rows))
         (off (seq-remove #'ecc-plugin--row-on-p rows)))
    (insert (propertize (format "Installed (%d)" (length rows))
                        'face 'ecc-heading-face)
            "\n\n")
    (cond
     ((memq 'installed ecc-plugin--loading)
      (ecc-plugin--insert-loading "the installed plugins"))
     ((null rows)
      (insert (propertize "Nothing is installed.\n" 'face 'ecc-dim-face)))
     (t
      (ecc-plugin--insert-by-scope on "on")
      (when off
        (when (ecc-plugin--insert-heading
               "off" (format "Show disabled (%d)" (length off)))
          (ecc-plugin--insert-by-scope off "off" "  ")))))))

(defun ecc-plugin--insert-market (market)
  "Insert the two lines of MARKET, carrying it as a text property."
  (insert (propertize
           (concat "  ● " (propertize (ecc-plugin-market-name market)
                                      'face 'ecc-tool-face))
           'ecc-plugin-market market)
          "\n"
          (propertize
           (concat "      "
                   (or (ecc-plugin-market-repo market) "?")
                   (when-let* ((source (ecc-plugin-market-source market)))
                     (format " (%s)" source)))
           'face 'ecc-dim-face
           'ecc-plugin-market market)
          "\n"))

(defun ecc-plugin--draw-marketplaces ()
  "Draw the Marketplaces tab."
  (insert (propertize (format "Marketplaces (%d)" (length ecc-plugin--markets))
                      'face 'ecc-heading-face)
          "\n\n")
  ;; A row of its own, the way the real screen has one: a key named at
  ;; the foot of the screen is still a key nobody presses.
  (insert (propertize "  + Add a marketplace" 'face 'ecc-tool-face
                      'ecc-plugin-action #'ecc-plugin-add-marketplace)
          "\n\n")
  (cond
   ((memq 'markets ecc-plugin--loading)
    (ecc-plugin--insert-loading "the marketplaces"))
   ((null ecc-plugin--markets)
    (insert (propertize "No marketplace is configured.\n" 'face 'ecc-dim-face)))
   (t (mapc #'ecc-plugin--insert-market ecc-plugin--markets))))

(defun ecc-plugin-gone (entries)
  "Return the ENTRIES whose directory is not on the disk any more."
  (seq-filter (lambda (entry)
                (let ((path (ecc-plugin-entry-path entry)))
                  (and path (not (file-directory-p path)))))
              entries))

(defun ecc-plugin--draw-errors ()
  "Draw the Errors tab.
Nothing exports the plugin load errors the real screen lists, so what is
here is what Emacs can see for itself: a subcommand that failed, and an
installed plugin whose directory is gone."
  (let ((gone (ecc-plugin-gone ecc-plugin--installed)))
    (insert (propertize "Errors" 'face 'ecc-heading-face) "\n\n")
    (if (and (null ecc-plugin--errors) (null gone))
        (insert (propertize "No plugin errors.\n" 'face 'ecc-dim-face))
      (dolist (message ecc-plugin--errors)
        (insert (propertize (concat "  " message) 'face 'ecc-error-face) "\n"))
      (dolist (entry gone)
        (insert (propertize
                 (concat "  " (ecc-plugin-entry-id entry)
                         " is installed, but " (ecc-plugin-entry-path entry)
                         " is gone")
                 'face 'ecc-error-face
                 'ecc-plugin-entry entry)
                "\n")))))

(defun ecc-plugin--draw ()
  "Draw the plugin browser into the current buffer, keeping point where it was."
  (let ((inhibit-read-only t)
        (id (ecc-plugin--id-at-point))
        (line (line-number-at-pos)))
    (erase-buffer)
    (ecc-plugin--insert-tabs)
    (unless (eq ecc-plugin--tab 'errors)
      (ecc-plugin--insert-search))
    (pcase ecc-plugin--tab
      ('discover (ecc-plugin--draw-discover))
      ('installed (ecc-plugin--draw-installed))
      ('marketplaces (ecc-plugin--draw-marketplaces))
      ('errors (ecc-plugin--draw-errors)))
    (goto-char (point-min))
    (if (and id (ecc-plugin--goto-id id))
        nil
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun ecc-plugin--id-at-point ()
  "Return the id of whatever is at point: a plugin, a skill or a marketplace."
  (or (when-let* ((entry (get-text-property (point) 'ecc-plugin-entry)))
        (ecc-plugin-entry-id entry))
      (when-let* ((skill (get-text-property (point) 'ecc-plugin-skill)))
        (ecc-plugin-skill-name skill))
      (when-let* ((market (get-text-property (point) 'ecc-plugin-market)))
        (ecc-plugin-market-name market))))

(defun ecc-plugin--goto-id (id)
  "Put point on the row of ID and return non-nil when it was found."
  (let ((found nil)
        (position (point-min)))
    (while (and (not found) (< position (point-max)))
      (goto-char position)
      (setq found (equal (ecc-plugin--id-at-point) id))
      (setq position (if found position (line-beginning-position 2))))
    found))

;;;; The mode

(defvar ecc-plugin-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'ecc-plugin-next-tab)
    (define-key map (kbd "<backtab>") #'ecc-plugin-previous-tab)
    (define-key map "1" #'ecc-plugin-show-discover)
    (define-key map "2" #'ecc-plugin-show-installed)
    (define-key map "3" #'ecc-plugin-show-marketplaces)
    (define-key map "4" #'ecc-plugin-show-errors)
    (define-key map (kbd "RET") #'ecc-plugin-open)
    (define-key map "s" #'ecc-plugin-filter)
    (define-key map "/" #'ecc-plugin-jump)
    (define-key map "g" #'ecc-plugin-refresh)
    (define-key map "i" #'ecc-plugin-install)
    (define-key map "e" #'ecc-plugin-toggle)
    ;; The real screen toggles with SPC, and a hand that has used it
    ;; reaches for SPC here too.
    (define-key map (kbd "SPC") #'ecc-plugin-toggle)
    (define-key map "E" #'ecc-plugin-set-state)
    (define-key map "u" #'ecc-plugin-do-update)
    (define-key map "d" #'ecc-plugin-do-remove)
    (define-key map "a" #'ecc-plugin-add-marketplace)
    (define-key map "p" #'ecc-plugin-prune)
    (define-key map "R" #'ecc-plugin-tell-sessions)
    map)
  "Keymap of `ecc-plugin-mode'.")

(define-derived-mode ecc-plugin-mode special-mode "Claude-Plugins"
  "Major mode of the plugin browser.

\\{ecc-plugin-mode-map}"
  :interactive nil
  (setq-local truncate-lines t)
  (setq-local header-line-format '(:eval (ecc-plugin-header-line))))

;;;###autoload
(defun ecc-plugin (&optional filter project)
  "Browse and manage the plugins and skills of the Claude Code CLI.
FILTER, when given, narrows the rows to what it is part of.  PROJECT is
the directory whose own skills and settings are read, and defaults to
the project of the buffer this was called from."
  (interactive)
  (let ((buffer (get-buffer-create ecc-plugin-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-plugin-mode)
        (ecc-plugin-mode))
      (setq ecc-plugin--project (or project (ecc-window-project-root)))
      (when (and filter (not (string-empty-p filter)))
        (setq ecc-plugin--filter filter))
      (if (or ecc-plugin--catalog ecc-plugin--installed)
          (ecc-plugin--draw)
        (ecc-plugin-refresh)))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-plugin--redraw (buffer)
  "Draw the browser again in BUFFER, if it is still alive."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (ecc-plugin--draw))))

(defun ecc-plugin--receive (buffer place value message)
  "Put VALUE in PLACE of BUFFER, or MESSAGE among the errors, and redraw.
PLACE is one of the symbols the reads are known by."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ecc-plugin--loading (delq place ecc-plugin--loading))
      (if message
          (setq ecc-plugin--errors
                (append ecc-plugin--errors (list message)))
        (pcase place
          ('catalog (setq ecc-plugin--catalog value))
          ('installed
           (setq ecc-plugin--installed value)
           (setq ecc-plugin--skills
                 (ecc-plugin-skills ecc-plugin--project value)))
          ('markets (setq ecc-plugin--markets value))))
      (ecc-plugin--draw))))

(defun ecc-plugin-refresh ()
  "Read the plugins, the catalog and the marketplaces again."
  (interactive)
  (let ((buffer (current-buffer)))
    (setq ecc-plugin--errors nil)
    (setq ecc-plugin--loading '(catalog installed markets))
    (ecc-plugin--draw)
    (ecc-plugin-read-installed
     (lambda (value message)
       (ecc-plugin--receive buffer 'installed value message)))
    (ecc-plugin-read-catalog
     (lambda (value message)
       (ecc-plugin--receive buffer 'catalog value message)))
    (ecc-plugin-read-marketplaces
     (lambda (value message)
       (ecc-plugin--receive buffer 'markets value message)))))

(defun ecc-plugin--show-tab (tab)
  "Show TAB of the browser."
  (setq ecc-plugin--tab tab)
  (ecc-plugin--draw))

(defun ecc-plugin-next-tab ()
  "Show the next tab."
  (interactive)
  (let* ((tabs (mapcar #'car ecc-plugin-tabs))
         (rest (cdr (memq ecc-plugin--tab tabs))))
    (ecc-plugin--show-tab (or (car rest) (car tabs)))))

(defun ecc-plugin-previous-tab ()
  "Show the previous tab."
  (interactive)
  (let* ((tabs (mapcar #'car ecc-plugin-tabs))
         (before (seq-take-while (lambda (tab) (not (eq tab ecc-plugin--tab)))
                                 tabs)))
    (ecc-plugin--show-tab (or (car (last before)) (car (last tabs))))))

(defun ecc-plugin-show-discover ()
  "Show the Discover tab."
  (interactive)
  (ecc-plugin--show-tab 'discover))

(defun ecc-plugin-show-installed ()
  "Show the Installed tab."
  (interactive)
  (ecc-plugin--show-tab 'installed))

(defun ecc-plugin-show-marketplaces ()
  "Show the Marketplaces tab."
  (interactive)
  (ecc-plugin--show-tab 'marketplaces))

(defun ecc-plugin-show-errors ()
  "Show the Errors tab."
  (interactive)
  (ecc-plugin--show-tab 'errors))

(defun ecc-plugin-set-filter (string)
  "Show only the rows STRING is part of.  An empty STRING shows them all."
  (setq ecc-plugin--filter (unless (string-empty-p (or string "")) string))
  (ecc-plugin--draw))

(defun ecc-plugin-filter ()
  "Narrow the rows to what is typed, as it is typed.
The rows are drawn again on every keystroke, the way the real screen
filters as you type; quitting puts back what was there before."
  (interactive)
  (let* ((buffer (current-buffer))
         (before ecc-plugin--filter)
         (update (lambda ()
                   (let ((typed (minibuffer-contents-no-properties)))
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (unless (equal typed (or ecc-plugin--filter ""))
                           (ecc-plugin-set-filter typed))))))))
    (condition-case nil
        (minibuffer-with-setup-hook
            (lambda () (add-hook 'post-command-hook update nil t))
          (read-from-minibuffer "Show the plugins matching: " before))
      (quit
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (ecc-plugin-set-filter before)))
       (signal 'quit nil)))))

(defun ecc-plugin--rows ()
  "Return the rows of the tab that is showing, unfiltered.
An alist of the line to choose from and the id to go to."
  (pcase ecc-plugin--tab
    ('marketplaces
     (mapcar (lambda (market)
               (cons (ecc-plugin-market-name market)
                     (ecc-plugin-market-name market)))
             ecc-plugin--markets))
    ('installed
     (append
      (mapcar (lambda (entry) (cons (ecc-plugin-entry-id entry)
                                    (ecc-plugin-entry-id entry)))
              ecc-plugin--installed)
      (mapcar (lambda (skill) (cons (ecc-plugin-skill-name skill)
                                    (ecc-plugin-skill-name skill)))
              ecc-plugin--skills)))
    (_
     (mapcar (lambda (entry) (cons (ecc-plugin-entry-id entry)
                                   (ecc-plugin-entry-id entry)))
             ecc-plugin--catalog))))

(defun ecc-plugin--annotation (id)
  "Return what is shown beside ID while it is being chosen."
  (when-let* ((entry (seq-find (lambda (entry)
                                 (equal (ecc-plugin-entry-id entry) id))
                               (append ecc-plugin--catalog
                                       ecc-plugin--installed))))
    (concat "  " (ecc--fit (or (ecc-plugin-entry-description entry)
                               (ecc-plugin--source-label
                                (ecc-plugin-entry-source entry))
                               "")
                           70))))

(defun ecc-plugin-jump (id)
  "Go to the row of ID, chosen by completion over the whole tab.
Completion is the search this buffer is worst at: 297 plugins are read
better through the completion of Emacs, with its own matching, than
through a line of them at a time.  A row the filter is hiding brings
the filter down with it."
  (interactive
   (list (let* ((rows (or (ecc-plugin--rows) (user-error "Nothing to jump to")))
                (completion-extra-properties
                 (list :annotation-function #'ecc-plugin--annotation)))
           (cdr (assoc (completing-read "Go to: " rows nil t) rows)))))
  (unless (ecc-plugin--goto-id id)
    (ecc-plugin-set-filter nil)
    (ecc-plugin--goto-id id)))

(defun ecc-plugin-toggle-fold ()
  "Fold or unfold the group at point."
  (interactive)
  (if-let* ((key (get-text-property (point) 'ecc-plugin-key)))
      (progn
        (setq ecc-plugin--folded
              (if (member key ecc-plugin--folded)
                  (delete key ecc-plugin--folded)
                (cons key ecc-plugin--folded)))
        (ecc-plugin--draw))
    (user-error "No group here")))

;;;; Acting

(defun ecc-plugin--outcome (exit output)
  "Return (OK . MESSAGE) of the action that exited EXIT printing OUTPUT.
An action answers with one JSON object naming the command, the outcome
and a message, and that outcome is what decides.  `marketplace add\\=',
`remove\\=' and `update\\=' have no `--json' at all (2.1.270): they
print their progress and their verdict as text, and there the exit code
is all there is to go on."
  (condition-case nil
      (let* ((answer (ecc-plugin--json output))
             (outcome (alist-get 'outcome answer)))
        (cons (not (equal outcome "failed"))
              (or (alist-get 'message answer) outcome)))
    (error (cons (zerop exit) (ecc-plugin--last-line output)))))

(defun ecc-plugin--last-line (output)
  "Return the last line of OUTPUT that says anything.
The text subcommands print their progress first and their verdict last."
  (car (last (seq-remove #'string-empty-p
                         (mapcar #'string-trim
                                 (split-string (or output "") "[\n\r]"))))))

(defun ecc-plugin--act (args &optional reload)
  "Run the CLI with ARGS, report what it said and read everything again.
Non-nil RELOAD offers the running sessions `/reload-plugins\\=' once the
action has gone through."
  (let ((buffer (current-buffer)))
    (message "%s %s…" ecc-executable (string-join args " "))
    (ecc-plugin--call
     args
     (lambda (exit output)
       (pcase-let ((`(,ok . ,text) (ecc-plugin--outcome exit output)))
         (if (not ok)
             (progn
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq ecc-plugin--errors
                         (append ecc-plugin--errors
                                 (list (format "%s: %s"
                                               (string-join args " ") text))))))
               (message "%s failed: %s" (string-join args " ") text))
           (message "%s" (if (string-empty-p (or text "")) "Done" text))
           (when reload (ecc-plugin-tell-sessions))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (ecc-plugin-refresh)))))))))

(defun ecc-plugin-tell-sessions ()
  "Tell the running sessions to pick the plugins up, as the option says.
The CLI reads its plugins when it starts, so a session that was already
running keeps the ones it started with until `/reload-plugins\\=' is
sent."
  (interactive)
  (let ((sessions (seq-filter (lambda (session)
                                (process-live-p (ecc-session-process session)))
                              (ecc-model-sessions))))
    (when (and sessions
               (or (eq ecc-plugin-reload-sessions t)
                   (and (eq ecc-plugin-reload-sessions 'ask)
                        (y-or-n-p (format "Reload the plugins of %d session(s)? "
                                          (length sessions))))))
      (dolist (session sessions)
        (ecc-proc-send-prompt session "/reload-plugins"))
      (message "Sent /reload-plugins to %d session(s)" (length sessions)))))

(defun ecc-plugin-entry-at-point ()
  "Return the plugin at point, or signal a `user-error\\='."
  (or (get-text-property (point) 'ecc-plugin-entry)
      (user-error "No plugin here")))

(defun ecc-plugin-skill-at-point ()
  "Return the skill at point, or signal a `user-error\='."
  (or (get-text-property (point) 'ecc-plugin-skill)
      (user-error "No skill here")))

(defun ecc-plugin-market-at-point ()
  "Return the marketplace at point, or signal a `user-error\\='."
  (or (get-text-property (point) 'ecc-plugin-market)
      (user-error "No marketplace here")))

(defun ecc-plugin--read-scope (prompt)
  "Read one of `ecc-plugin-scopes\\=', asking with PROMPT."
  (completing-read prompt ecc-plugin-scopes nil t nil nil
                   (car ecc-plugin-scopes)))

(defun ecc-plugin-install (entry scope)
  "Install ENTRY at SCOPE.
`-y' goes with it: the CLI insists on it whenever its output is not a
terminal, which is always the case here, and it answers for the command
a marketplace declares (2.1.270)."
  (interactive (list (ecc-plugin-entry-at-point)
                     (ecc-plugin--read-scope "Install for: ")))
  (ecc-plugin--act (list "plugin" "install" (ecc-plugin-entry-id entry)
                         "--json" "-y" "-s" scope)
                   t))

(defun ecc-plugin-uninstall (entry)
  "Uninstall ENTRY, from the scope it is installed at."
  (interactive (list (ecc-plugin-entry-at-point)))
  (unless (ecc-plugin-entry-installed entry)
    (user-error "%s is not installed" (ecc-plugin-entry-id entry)))
  (when (yes-or-no-p (format "Uninstall %s? " (ecc-plugin-entry-id entry)))
    (ecc-plugin--act (append (list "plugin" "uninstall"
                                   (ecc-plugin-entry-id entry) "--json" "-y")
                             (when-let* ((scope (ecc-plugin-entry-scope entry)))
                               (list "-s" scope)))
                     t)))

(defun ecc-plugin-toggle-plugin (entry)
  "Turn the plugin ENTRY off if it is on, and on if it is off."
  (interactive (list (ecc-plugin-entry-at-point)))
  (unless (ecc-plugin-entry-installed entry)
    (user-error "%s is not installed" (ecc-plugin-entry-id entry)))
  (ecc-plugin--act (list "plugin"
                         (if (ecc-plugin-entry-enabled entry) "disable" "enable")
                         (ecc-plugin-entry-id entry) "--json")
                   t))

(defun ecc-plugin-apply-skill-state (skill state)
  "Set SKILL to STATE, one of `ecc-plugin-skill-states\='.
There is no subcommand for this: a skill is listed, restricted or hidden
by an entry in `skillOverrides\=' of the settings, which is what is
written.  `on\=' is the absence of an entry, so it takes the entry out
of the user settings -- and a project settings file that restricts the
same skill still wins, because the CLI merges the scopes by taking the
most restrictive of them.  That is said rather than hidden."
  (let* ((name (ecc-plugin-skill-name skill))
         (on (equal state "on"))
         (user-file (expand-file-name ecc-plugin-user-settings-file)))
    (ecc-plugin-set-skill-state name (unless on state))
    (ecc-plugin-refresh)
    (let* ((now (seq-find (lambda (other)
                            (equal (ecc-plugin-skill-name other) name))
                          ecc-plugin--skills))
           (reached (if now (ecc-plugin-skill-state now) state))
           (from (and now (ecc-plugin-skill-from now))))
      (if (and (not (equal reached state)) from)
          (message "%s is %s in %s, but %s makes it %s"
                   name (or state "on") user-file from reached)
        (message "%s is %s%s" name reached
                 (if on "" (format " (skillOverrides in %s)" user-file)))))))

(defun ecc-plugin-toggle-skill (skill)
  "Turn the SKILL off if it is on, and on if it is off."
  (interactive (list (ecc-plugin-skill-at-point)))
  (let ((on (ecc-plugin-skill-on-p skill)))
    (when (and on (eq (ecc-plugin-skill-scope skill) 'plugin))
      (unless (yes-or-no-p
               (format "%s comes from the plugin %s; turn the skill off? "
                       (ecc-plugin-skill-name skill)
                       (ecc-plugin-skill-origin skill)))
        (user-error "Left alone")))
    (ecc-plugin-apply-skill-state skill (if on "off" "on"))))

(defun ecc-plugin-set-state ()
  "Set what is at point to a state chosen by name.
A plugin is on or off.  A skill has the four the CLI knows: `on\=',
`name-only\=' lists it without its description, `user-invocable-only\='
hides it from the model but keeps `/name\=', and `off\=' hides it from
both."
  (interactive)
  (if-let* ((skill (get-text-property (point) 'ecc-plugin-skill)))
      (ecc-plugin-apply-skill-state
       skill
       (completing-read (format "%s is %s; set to: "
                                (ecc-plugin-skill-name skill)
                                (ecc-plugin-skill-state skill))
                        ecc-plugin-skill-states nil t))
    (let* ((entry (ecc-plugin-entry-at-point))
           (was (if (ecc-plugin-entry-enabled entry) "on" "off"))
           (state (completing-read (format "%s is %s; set to: "
                                           (ecc-plugin-entry-name entry) was)
                                   '("on" "off") nil t)))
      (if (equal state was)
          (message "%s is %s already" (ecc-plugin-entry-name entry) was)
        (ecc-plugin-toggle-plugin entry)))))

(defun ecc-plugin-toggle ()
  "Turn whatever is at point off if it is on, and on if it is off."
  (interactive)
  (if (get-text-property (point) 'ecc-plugin-skill)
      (call-interactively #'ecc-plugin-toggle-skill)
    (call-interactively #'ecc-plugin-toggle-plugin)))

(defun ecc-plugin-update (entry)
  "Update ENTRY to the version its marketplace offers."
  (interactive (list (ecc-plugin-entry-at-point)))
  (unless (ecc-plugin-entry-installed entry)
    (user-error "%s is not installed" (ecc-plugin-entry-id entry)))
  (ecc-plugin--act (append (list "plugin" "update" (ecc-plugin-entry-id entry)
                                 "--json" "-y")
                           (when-let* ((scope (ecc-plugin-entry-scope entry)))
                             (list "-s" scope)))
                   t))

(defun ecc-plugin-prune ()
  "Remove the auto-installed plugins nothing wants any more.
What would go is listed first, and nothing is removed until that has
been agreed to."
  (interactive)
  (let ((buffer (current-buffer)))
    (ecc-plugin--call
     '("plugin" "prune" "--dry-run")
     (lambda (_exit output)
       (let ((text (string-trim output)))
         (if (or (string-empty-p text) (string-match-p "Nothing to prune" text))
             (message "%s" (if (string-empty-p text) "Nothing to prune" text))
           (when (yes-or-no-p (format "%s\nRemove them? " text))
             (with-current-buffer buffer
               (ecc-plugin--act '("plugin" "prune" "-y") t)))))))))

(defun ecc-plugin-add-marketplace (source scope)
  "Add the marketplace at SOURCE, declared at SCOPE.
SOURCE is a GitHub repository, a URL or a directory."
  (interactive (list (read-string "Marketplace (owner/repo, URL or path): ")
                     (ecc-plugin--read-scope "Declare it for: ")))
  (when (string-empty-p (string-trim source))
    (user-error "No marketplace named"))
  (ecc-plugin--act (list "plugin" "marketplace" "add" (string-trim source)
                         "--scope" scope)))

(defun ecc-plugin-update-marketplace (market)
  "Update MARKET from its source."
  (interactive (list (ecc-plugin-market-at-point)))
  (ecc-plugin--act (list "plugin" "marketplace" "update"
                         (ecc-plugin-market-name market))))

(defun ecc-plugin-remove-marketplace (market)
  "Remove MARKET, from every scope that declares it."
  (interactive (list (ecc-plugin-market-at-point)))
  (when (yes-or-no-p (format "Remove the marketplace %s? "
                             (ecc-plugin-market-name market)))
    (ecc-plugin--act (list "plugin" "marketplace" "remove"
                           (ecc-plugin-market-name market)))))

;;;; The keys that dispatch on the tab

(defun ecc-plugin-do-update ()
  "Update the plugin at point, or the marketplace at point."
  (interactive)
  (if (eq ecc-plugin--tab 'marketplaces)
      (call-interactively #'ecc-plugin-update-marketplace)
    (call-interactively #'ecc-plugin-update)))

(defun ecc-plugin-do-remove ()
  "Uninstall the plugin at point, or remove the marketplace at point."
  (interactive)
  (if (eq ecc-plugin--tab 'marketplaces)
      (call-interactively #'ecc-plugin-remove-marketplace)
    (call-interactively #'ecc-plugin-uninstall)))

(defun ecc-plugin-open ()
  "Fold the group at point, or show what is known about the plugin at point."
  (interactive)
  (cond
   ((get-text-property (point) 'ecc-plugin-action)
    (call-interactively (get-text-property (point) 'ecc-plugin-action)))
   ((get-text-property (point) 'ecc-plugin-key) (ecc-plugin-toggle-fold))
   ((get-text-property (point) 'ecc-plugin-skill)
    (let ((skill (ecc-plugin-skill-at-point)))
      (if-let* ((path (ecc-plugin-skill-path skill)))
          (find-file-other-window (expand-file-name "SKILL.md" path))
        (message "%s is bundled with the CLI: there is no file to open"
                 (ecc-plugin-skill-name skill)))))
   ((get-text-property (point) 'ecc-plugin-entry)
    (ecc-plugin-describe (ecc-plugin-entry-at-point)))
   (t (user-error "Nothing here"))))

;;;; What one plugin is

(defvar-local ecc-plugin--described nil
  "The plugin the description buffer is about.")

(defvar ecc-plugin-trust-warning
  "Make sure you trust a plugin before installing, updating, or using it.
Anthropic does not control what MCP servers, files, or other software
are included in plugins and cannot verify that they will work as
intended or that they will not change."
  "What the CLI says beside every install, said here too.")

(defvar ecc-plugin-describe-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "i" #'ecc-plugin-describe-install)
    (define-key map "g" #'ecc-plugin-describe-refresh)
    map)
  "Keymap of `ecc-plugin-describe-mode'.")

(define-derived-mode ecc-plugin-describe-mode special-mode "Claude-Plugin"
  "Major mode of the buffer describing one plugin.

\\{ecc-plugin-describe-mode-map}"
  :interactive nil)

(defun ecc-plugin-describe-buffer-name (entry)
  "Return the name of the buffer describing ENTRY."
  (format "*claude-plugin: %s*" (ecc-plugin-entry-name entry)))

(defun ecc-plugin-describe (entry)
  "Show what is known about ENTRY, and what it would bring."
  (interactive (list (ecc-plugin-entry-at-point)))
  (let ((buffer (get-buffer-create (ecc-plugin-describe-buffer-name entry))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-plugin-describe-mode)
        (ecc-plugin-describe-mode))
      (setq ecc-plugin--described entry)
      (ecc-plugin--describe-draw entry nil)
      (when (ecc-plugin-entry-installed entry)
        (ecc-plugin-read-details
         (ecc-plugin-entry-name entry)
         (lambda (text message)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (ecc-plugin--describe-draw entry (or text message))))))))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-plugin--describe-draw (entry details)
  "Draw ENTRY and its DETAILS, the text of `plugin details\\=' or nil."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (ecc-plugin-entry-name entry) 'face 'ecc-heading-face)
            (propertize (format "  from %s\n\n"
                                (or (ecc-plugin-entry-marketplace entry) "?"))
                        'face 'ecc-dim-face))
    (when-let* ((description (ecc-plugin-entry-description entry)))
      (insert description "\n\n"))
    (dolist (row (list
                  (cons "Id" (ecc-plugin-entry-id entry))
                  (cons "Version" (ecc-plugin-entry-version entry))
                  (cons "Scope" (ecc-plugin-entry-scope entry))
                  (cons "State" (cond ((not (ecc-plugin-entry-installed entry))
                                       "not installed")
                                      ((ecc-plugin-entry-enabled entry) "on")
                                      (t "off")))
                  (cons "Installs" (ecc-plugin--installs
                                    (ecc-plugin-entry-installs entry)))
                  (cons "Source" (ecc-plugin--source-label
                                  (ecc-plugin-entry-source entry)))
                  (cons "Path" (ecc-plugin-entry-path entry))))
      (when (cdr row)
        (insert (propertize (format "%-9s " (car row)) 'face 'ecc-dim-face)
                (cdr row) "\n")))
    (insert "\n")
    (when (ecc-plugin-disabled-here-p entry)
      (insert (propertize
               "This plugin is in `ecc-disabled-plugins', so the sessions ecc
starts are told to turn it off.  That is a thing apart from the state
above, which is the CLI's own.\n\n"
               'face 'ecc-warning-face)))
    (insert (propertize "What it brings\n" 'face 'ecc-heading-face))
    (insert (propertize (or details
                            (if (ecc-plugin-entry-installed entry)
                                "Reading…"
                              "Known once it is installed."))
                        'face 'ecc-dim-face)
            "\n\n")
    (insert (propertize ecc-plugin-trust-warning 'face 'ecc-warning-face) "\n")
    (goto-char (point-min))))

(defun ecc-plugin-describe-install (scope)
  "Install the plugin this buffer is about at SCOPE."
  (interactive (list (ecc-plugin--read-scope "Install for: ")))
  (ecc-plugin-install (or ecc-plugin--described (user-error "No plugin here"))
                      scope))

(defun ecc-plugin-describe-refresh ()
  "Read what the plugin of this buffer brings again."
  (interactive)
  (ecc-plugin-describe (or ecc-plugin--described (user-error "No plugin here"))))

;;;; The way in: the prompt region

(defvar ecc-plugin-commands '("/plugins" "/plugin")
  "The words that open the browser from the prompt region.
The terminal client answers `/plugins' in its input layer and offers
`/plugin' as the same thing, and neither is in `slash_commands' or in
`terminal_slash_commands' (2.1.270): a headless client is told nothing
about them, so a `/plugins' typed into a prompt would have gone to the
model as a sentence.  Emacs answers them here instead.")

(defun ecc-plugin-intercept (_session text)
  "Open the browser when TEXT is `/plugins\\=', and say it was answered.
What follows the command narrows the rows, so `/plugins mcp\\=' opens on
the plugins that mention MCP.  This is on
`ecc-prompt-intercept-functions\\='."
  (when (member (ecc-prompt-command-name text) ecc-plugin-commands)
    (ecc-plugin (ecc-prompt-command-argument text))
    t))

(with-eval-after-load 'ecc-prompt
  (add-hook 'ecc-prompt-intercept-functions #'ecc-plugin-intercept))

(provide 'ecc-plugin)

;;; ecc-plugin.el ends here
