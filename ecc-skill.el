;;; ecc-skill.el --- The skills of a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The `/skills' of the terminal client: what this session's skills are,
;; running one, and turning one on and off.
;;
;; The CLI keeps the command to itself.  It is defined as
;; `{name:"skills", description:"List available skills", immediate:true,
;; thinClientDispatch:"control-request"}' -- a command whose interface
;; belongs to the client rather than to the CLI -- and the answer to
;; `initialize' does not name it at all: 57 commands, `reload-skills' and
;; `skill-doctor' among them, and no `skills' (confirmed against Claude
;; Code 2.1.270, 2026-09-13).  So a headless client is told nothing and
;; is expected to draw the list itself, the way `ecc-btw' answers `/btw'.
;;
;; Where the three pieces come from:
;;
;; - the names, from the `skills' array of system/init, which arrives
;;   with the first turn;
;; - the descriptions, from the answer to `initialize', where a skill is
;;   listed among the commands, because a skill installs a command of
;;   its own name -- which is also how one is run: sending `/<name>';
;; - whether a skill is on, from the `skillOverrides' of the Claude Code
;;   settings, read with the `get_settings' control request.
;;
;; Turning one off writes that setting, and writes it to the file: the
;; `update_settings' request takes the localSettings source alone, and in
;; it the key `outputStyle' alone ("update_settings keys not allowed:
;; skillOverrides", 2026-09-13).  The terminal client edits the file for
;; its own `/skills' too.  The session picks the change up when it is
;; sent `/reload-skills', which answers with a system/commands_changed
;; that no longer names the skill (measured 2026-09-13).
;;
;; A skill that is off is named nowhere the CLI reports, so the list is
;; the names of system/init together with the names `skillOverrides'
;; mentions.  Without that union a skill could be turned off and never
;; turned back on.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'json)
(require 'ecc-window)
(require 'ecc-capability)

;; Declared rather than required: `ecc-render' is above this file, and
;; the session of the current buffer is all that is wanted of it.  The
;; same form `ecc-notify' uses, and what lets this file compile on its
;; own (confirmed 2026-09-17).
(defvar ecc-render--session)

(declare-function ecc-prompt-command-name "ecc-prompt" (text))
(defvar ecc-prompt-immediate-commands)
(declare-function ecc-dashboard-session-at-point "ecc-dashboard" ())
(declare-function ecc-prompt-command-argument "ecc-prompt" (text))

;;;; Options

(defconst ecc-skill-buffer-name "*ecc-skills*"
  "Name of the Skills buffer.")

(defvar ecc-skill-commands '("/skills" "/skill")
  "The words that open the skills of a session, the offered one first.
The CLI names neither: `/skills' is its own command but is kept from a
headless client, and there is no `/skill' at all.  Both are answered
here, because the singular is what a hand reaches for, but only the
first is offered in the prompt region (`ecc-prompt-local-commands'):
the same thing under two names would be two rows in every menu.")

(defvar ecc-skill-override-values
  '(("on" . "listed and ready to be used")
    ("name-only" . "the name is in the prompt, the body only when it is used")
    ("user-invocable-only" . "only when the user asks for it")
    ("off" . "not listed at all"))
  "What a skill can be set to, and what each setting means.
This is the CLI's own table -- the `skillOverrides' setting takes these
four words -- rather than anything chosen here.")

(defvar ecc-skill-override-marks
  '(("on"                  "\u2714" "on"        ecc-ok-face)
    ("name-only"           "\u25cf" "name-only" ecc-tool-face)
    ("user-invocable-only" "\u25ef" "user-only" ecc-warning-face)
    ("off"                 "\u2718" "off"       ecc-error-face))
  "How each setting is drawn: the mark, the word, and the face.
The marks and the words are the terminal client\='s own -- a tick for
on, a filled circle for name-only, a hollow one for user-only and a
cross for off, with the same green, amber and red -- so that a glance
at either says the same thing (read out of 2.1.270, 2026-09-13).")

(defvar ecc-skill-lock-mark "\U0001F512"
  "What marks a skill whose setting is not the user\='s to change.
The padlock the terminal client draws for one settled by a policy, a
flag or a plugin.")

(defvar ecc-skill-settings-key 'skillOverrides
  "The key the skill settings live under in a Claude Code settings file.")

(defvar ecc-skill-settings-file nil
  "The settings file a skill is turned on and off in.
Nil means the one the terminal client writes: `.claude/settings.local.json'
of the project, which is that client\='s localSettings and the source its
own /skills saves to (read out of 2.1.270, 2026-09-13).  Writing
somewhere else would leave the two disagreeing about a skill they both
show.  A prefix argument to \\[ecc-skill-save] offers the user and
project files instead, and what it chooses is remembered for the rest
of the Emacs session.")

(defvar ecc-skill-settings-sources
  '("userSettings" "projectSettings" "localSettings")
  "The settings files an override is read from, least specific first.
The terminal client reads the same three for a skill: localSettings
first, then projectSettings, then userSettings, and the first that
names the skill wins.  policySettings and flagSettings are not here
because they do not override a skill; they lock it
\(`ecc-skill-lock-sources\=').")

(defvar ecc-skill-lock-sources '("policySettings" "flagSettings")
  "The settings files whose word about a skill is final.
An administrator\='s policy and a flag are not a preference to be
toggled: the terminal client draws such a skill with a lock and will
not cycle it, and neither does this.")

(defvar ecc-skill-show-built-in nil
  "Non-nil lists the skills built into the CLI along with the rest.
The terminal client leaves them out of its own /skills: the list it
draws is the skills that came from a file -- the project, the user, a
plugin, claude.ai -- because those are the ones there is anything to
manage.  \[ecc-skill-toggle-built-in] shows them for a buffer that is
open; this is what a new one starts as.")

(defvar ecc-skill-source-tags
  '("user" "project" "local" "plugin" "claude.ai" "dynamic workflow" "org")
  "The words the CLI puts after the description to say where a skill is from.
A skill built into the CLI carries none, which is how the two are told
apart: the CLI adds the tag for everything except its own bundled
skills, its MCP prompts and its memory store (`eee\=' of 2.1.270,
2026-09-13).  A plugin is named in front of the description instead,
and is recognised by the file it was found in rather than by this.")

(defvar ecc-skill-managed-tags
  '("user" "project" "local" "plugin" "claude.ai" "org")
  "The sources of the skills that are the user\='s own to manage.
The terminal client lists exactly these in its /skills: a skill loaded
from a folder -- the project, the user, a plugin, claude.ai -- and
nothing else.  What is left out is what came with the CLI and the
dynamic workflows, which are not files anybody here put there.")

(defvar ecc-skill-reload-after-toggle t
  "Non-nil sends /reload-skills after a skill has been turned on or off.
The CLI reads the settings when it scans for skills, so a running
session goes on listing a skill that has just been turned off until it
is asked to scan again.")

;;;; What a skill is

(cl-defstruct ecc-skill
  "One skill of a session."
  name
  description
  source        ; the tag the CLI put after the description, or nil
  scope         ; project | global | plugin | builtin, as for a capability
  origin        ; the plugin it came from, or nil
  file          ; its SKILL.md, or nil
  override      ; one of `ecc-skill-override-values', or nil for the default
  lock)         ; the settings file whose word is final, or nil

(defvar ecc-skill--overrides (make-hash-table :test #'eq)
  "The skillOverrides last read for a session, as an alist of name and value.")

(defvar ecc-skill--locks (make-hash-table :test #'eq)
  "The skills a policy or a flag settles for a session, keyed by session.")

(defvar ecc-skill--settings-state (make-hash-table :test #'eq)
  "How the settings of a session stand: `unread', `failed' or `read'.")

(defun ecc-skill-overrides (session)
  "Return the skillOverrides of SESSION as an alist of name and value."
  (gethash session ecc-skill--overrides))

(defun ecc-skill-settings-state (session)
  "Return `unread', `failed' or `read' for the settings of SESSION."
  (or (gethash session ecc-skill--settings-state) 'unread))

(defun ecc-skill-override-for (session name)
  "Return what SESSION has the skill NAME set to, or nil for the default."
  (cdr (assoc name (ecc-skill-overrides session))))

(defun ecc-skill--source-overrides (sources name)
  "Return the skillOverrides the settings file NAME holds in SOURCES."
  (seq-some (lambda (source)
              (and (equal (alist-get 'source source) name)
                   (alist-get ecc-skill-settings-key
                              (alist-get 'settings source))))
            (or sources [])))

(defun ecc-skill--overrides-alist (object)
  "Return the skillOverrides OBJECT as an alist of name and value."
  (let ((overrides nil))
    (pcase-dolist (`(,skill . ,value) object)
      (when (stringp value)
        (push (cons (symbol-name skill) value) overrides)))
    (nreverse overrides)))

(defun ecc-skill-answer-overrides (answer)
  "Return the skillOverrides of ANSWER as an alist of name and value.
ANSWER is what `ecc-proc-get-settings\=' hands back, and what is read
out of it is `effective\=', the CLI\='s own resolved view.  That is what
the CLI reads a skill\='s setting out of itself -- the per-source
objects are merged into it, and it carries what a flag or a policy
added as well -- so there is nothing here to merge and nothing to get
wrong (`w_e\=' of 2.1.270, 2026-09-13)."
  (ecc-skill--overrides-alist
   (alist-get ecc-skill-settings-key (alist-get 'effective answer))))

(defun ecc-skill-file-overrides (files)
  "Return the skillOverrides of FILES as an alist of name and (VALUE . FILE).
For a caller with no session to ask: the files are read in the order
they are given, least specific first, and the last that names a skill
has it -- which is how the CLI merges the sources into the `effective\='
view `ecc-skill-answer-overrides\=' reads when there is a session.  The
file is carried along so that a caller can say where a value came from."
  (let ((overrides nil))
    (dolist (file files)
      (let ((file (expand-file-name file)))
        (pcase-dolist (`(,name . ,value)
                       (ecc-skill--overrides-alist
                        (alist-get ecc-skill-settings-key
                                   (ecc-skill-read-settings-file file))))
          (setf (alist-get name overrides nil nil #'equal)
                (cons value file)))))
    (nreverse overrides)))

(defun ecc-skill-sources-locks (sources)
  "Return the skills SOURCES settles for good, as an alist of name and file.
A policy or a flag is not a preference: the skill it names cannot be
toggled, here or in the terminal client."
  (let ((locks nil))
    (dolist (name ecc-skill-lock-sources)
      (pcase-dolist (`(,skill . ,value)
                     (ecc-skill--source-overrides sources name))
        (when (stringp value)
          (setf (alist-get (symbol-name skill) locks nil nil #'equal) name))))
    (nreverse locks)))

(defun ecc-skill--tag-regexp ()
  "Return what a source tag at the end of a description looks like."
  (concat " (" (regexp-opt ecc-skill-source-tags t) ")\\'"))

(defun ecc-skill-description-source (description)
  "Return the source DESCRIPTION was tagged with, or nil.
The CLI writes the description of every skill it did not bundle with a
tag of where it came from -- \"... (user)\", \"... (claude.ai)\" -- and
leaves its own alone, which is the only thing in the initialize answer
that tells the two apart: `loadedFrom\=' is not sent to a headless
client (confirmed against 2.1.270, 2026-09-13)."
  (when (and description (string-match (ecc-skill--tag-regexp) description))
    (match-string 1 description)))

(defun ecc-skill-description-without-source (description)
  "Return DESCRIPTION with the source tag taken off the end."
  (if (and description (string-match (ecc-skill--tag-regexp) description))
      (substring description 0 (match-beginning 0))
    description))

(defun ecc-skill--tagged-names (session plugins)
  "Return the skills of SESSION its commands name, with PLUGINS to look in.
The commands of the initialize answer arrive as soon as the CLI is up,
where the `skills\=' of system/init only come with the first turn, so a
session that has not spoken yet has nothing else to go on -- and the
terminal client\='s own /skills works from that same list.

A command is taken for a skill when its description is tagged with a
source that is somebody\='s folder and a SKILL.md for it is there to be
found.  The tag alone is not enough: a slash command written in
.claude/commands carries one too, and is no skill.  Something defined
where Emacs cannot see it -- a plugin, before init has said where the
plugins are -- waits for init."
  (let ((names nil))
    (seq-doseq (command (or (ecc-session-commands session) []))
      (when-let* ((name (alist-get 'name command))
                  ((member (ecc-skill-description-source
                            (alist-get 'description command))
                           ecc-skill-managed-tags))
                  ((cddr (ecc-capabilities--locate 'skill name session
                                                   plugins))))
        (push name names)))
    (nreverse names)))

(defun ecc-skill-names (session)
  "Return the names of the skills of SESSION.
The `skills\=' of system/init, the ones its commands give away before
init has arrived, and every name the settings mention: a skill that is
off is left out of everything the CLI reports, and a row that is not
there cannot be turned back on."
  (let ((names (append (alist-get 'skills (ecc-session-init session)) nil))
        (plugins (append (alist-get 'plugins (ecc-session-init session)) nil)))
    (dolist (name (append (ecc-skill--tagged-names session plugins)
                          (mapcar #'car (ecc-skill-overrides session))))
      (unless (member name names)
        (setq names (append names (list name)))))
    (seq-filter #'stringp names)))

(defun ecc-skill-list (session)
  "Return the skills of SESSION as a list of `ecc-skill'."
  (let* ((init (ecc-session-init session))
         (plugins (append (alist-get 'plugins init) nil))
         (descriptions (ecc-capabilities--command-descriptions session))
         (locks (gethash session ecc-skill--locks))
         (skills nil))
    (dolist (name (ecc-skill-names session))
      (pcase-let ((`(,scope ,origin . ,file)
                   (ecc-capabilities--locate 'skill name session plugins))
                  (description (gethash name descriptions)))
        (push (make-ecc-skill
               :name name
               :description (ecc-skill-description-without-source description)
               :source (ecc-skill-description-source description)
               :scope scope :origin origin :file file
               :override (ecc-skill-override-for session name)
               :lock (cdr (assoc name locks)))
              skills)))
    (sort (nreverse skills)
          (lambda (a b) (string< (ecc-skill-name a) (ecc-skill-name b))))))

(defun ecc-skill-built-in-p (skill)
  "Return non-nil when SKILL came with the CLI rather than from a folder.
Two things say it did not: a tag on the description naming a source
that is somebody\='s folder (`ecc-skill-managed-tags\='), and a file on
this machine that defines it.  The terminal client lists only the
latter in its own /skills -- its bundled skills and its dynamic
workflows are not yours to manage, and there are twenty of them to one
of yours."
  (and (not (member (ecc-skill-source skill) ecc-skill-managed-tags))
       (null (ecc-skill-file skill))))

(defun ecc-skill-source-name (skill)
  "Return where SKILL came from, in the words the CLI uses."
  (or (ecc-skill-source skill)
      (pcase (ecc-skill-scope skill)
        ('project "project")
        ('global "user")
        ('plugin (or (ecc-skill-origin skill) "plugin"))
        (_ "built-in"))))

(defun ecc-skill-off-p (skill)
  "Return non-nil when SKILL is turned off altogether."
  (equal (ecc-skill-override skill) "off"))

;;;; Reading the settings

(defun ecc-skill--running-p (session)
  "Return non-nil when SESSION has a CLI to ask."
  (process-live-p (ecc-session-process session)))

(defun ecc-skill-read-settings (session &optional callback)
  "Ask SESSION for its settings and remember the skillOverrides.
CALLBACK, when given, is called with the session once the answer is in.
A session with no CLI running is left as it is: there is nobody to ask,
and what was read last is better than nothing."
  (if (not (ecc-skill--running-p session))
      (when callback (funcall callback session))
    (ecc-proc-get-settings
     session
     (lambda (session answer)
       (if (null answer)
           (puthash session 'failed ecc-skill--settings-state)
         (puthash session (ecc-skill-answer-overrides answer)
                  ecc-skill--overrides)
         (puthash session (ecc-skill-sources-locks (alist-get 'sources answer))
                  ecc-skill--locks)
         (puthash session 'read ecc-skill--settings-state))
       (ecc-skill--redraw session)
       (when callback (funcall callback session))))))

;;;; Writing the settings

(defun ecc-skill-settings-file-in (&optional root)
  "Return the file a skill of the project at ROOT is turned on and off in.
`.claude/settings.local.json' of that project unless
`ecc-skill-settings-file' names another, because that is where the
terminal client saves: all three of its own write sites -- the two of
the plugin screen and the one of /skills -- write the localSettings
source (read out of 2.1.270, 2026-09-13).  With no project to write
into, the settings of the user."
  (or ecc-skill-settings-file
      (when root (expand-file-name ".claude/settings.local.json" root))
      (expand-file-name "settings.json"
                        (expand-file-name ecc-capabilities-directory))))

(defun ecc-skill-settings-file (&optional session)
  "Return the file a skill of SESSION is turned on and off in."
  (ecc-skill-settings-file-in (and session
                                   (ecc-session-project-root session))))

(defun ecc-skill-settings-files-in (&optional root)
  "Return the settings files a skill of the project at ROOT can be set in.
Least specific first, which is the order they are read in
\(`ecc-skill-file-overrides\=')."
  (delq nil
        (list (expand-file-name "settings.json"
                                (expand-file-name ecc-capabilities-directory))
              (when root (expand-file-name ".claude/settings.json" root))
              (when root (expand-file-name ".claude/settings.local.json" root)))))

(defun ecc-skill-settings-files (session)
  "Return the settings files SESSION could be given an override in.
The one the CLI reads last comes first, since that is the one to offer."
  (reverse (ecc-skill-settings-files-in
            (ecc-session-project-root session))))

(defun ecc-skill-read-settings-file (file &optional strict)
  "Return the settings in FILE as an alist, or nil when there are none.
Null is kept as `:null' so that a value this package does not touch
goes back as it was: `ecc--json-read' would turn it into nil, which
writes as an empty object.

A file that is not JSON -- a settings file edited by hand and left
half-written -- is logged and read as nothing, so that one typo does
not take the list of skills with it.  With STRICT the error is raised
instead, which is what a caller about to write the file wants: writing
over a file that could not be read would take the rest of its settings
away."
  (when (file-readable-p file)
    (let ((text (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8))
                    (insert-file-contents file))
                  (string-trim (buffer-string)))))
      (unless (string-empty-p text)
        (condition-case error
            (ecc--json-read-verbatim text)
          (error
           (when strict (signal (car error) (cdr error)))
           (ecc-log "settings" "%s is not JSON: %s" file
                    (error-message-string error))
           nil))))))

(defun ecc-skill-settings-with-override (settings name value)
  "Return SETTINGS with the skill NAME set to VALUE.
VALUE nil removes the entry, and the last entry takes the whole
`skillOverrides' object with it, so that nothing is left behind saying
what the default already says."
  (let* ((settings (copy-alist settings))
         (overrides (copy-alist (alist-get ecc-skill-settings-key settings)))
         (key (intern name)))
    (setq overrides (assq-delete-all key overrides))
    (when value
      (setq overrides (append overrides (list (cons key value)))))
    (setq settings (assq-delete-all ecc-skill-settings-key settings))
    (when overrides
      (setq settings (append settings (list (cons ecc-skill-settings-key
                                                  overrides)))))
    settings))

(defun ecc-skill-write-settings-file (file settings)
  "Write SETTINGS into FILE as indented JSON, and return FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (let ((coding-system-for-write 'utf-8))
      (insert (ecc--json-write settings))
      (json-pretty-print-buffer)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))))
  file)

(defun ecc-skill-set-override-in-file (file name value)
  "Set the skill NAME to VALUE in the settings FILE, and return FILE.
The file is read again here rather than taken from what was read for
the buffer: the terminal client edits the same file, and so does the
user."
  (ecc-skill-write-settings-file
   file
   (ecc-skill-settings-with-override (ecc-skill-read-settings-file file)
                                     name value)))

(defun ecc-skill-set-overrides-in-file (file changes)
  "Apply CHANGES to the settings FILE, and return FILE.
CHANGES is an alist of skill name and value, a nil value putting the
skill back to the default.  The file is read once here rather than
taken from what was read for the buffer -- the terminal client edits
the same file, and so does the user -- and written once, so that a
handful of skills settled in one go leave one change on disk."
  (let ((settings (ecc-skill-read-settings-file file 'strict)))
    (pcase-dolist (`(,name . ,value) changes)
      (setq settings (ecc-skill-settings-with-override settings name value)))
    (ecc-skill-write-settings-file file settings)))

(defun ecc-skill-save-overrides (session changes &optional file)
  "Write CHANGES for SESSION and tell it to scan its skills again.
CHANGES is an alist of skill name and value, nil meaning the default.
Returns the number of skills settled.  The session is sent
/reload-skills once, whatever the number, unless
`ecc-skill-reload-after-toggle\=' says not to, and the settings are read
again, so that what is shown is what the CLI has rather than what Emacs
meant to write."
  (if (null changes)
      0
    (let ((file (or file (ecc-skill-settings-file session))))
      (ecc-skill-set-overrides-in-file file changes)
      (pcase-dolist (`(,name . ,value) changes)
        (ecc-log (ecc-session-name session) "skill %s set to %s in %s"
                 name (or value "the default") (abbreviate-file-name file)))
      (let ((reloaded (and ecc-skill-reload-after-toggle
                           (ecc-skill-reload session))))
        (ecc-skill-read-settings session)
        (message "Updated %d skill override%s in %s%s"
                 (length changes) (if (= (length changes) 1) "" "s")
                 (abbreviate-file-name file)
                 (pcase reloaded
                   ('nil "")
                   ('sent "; the session is reloading its skills")
                   (_ "; /reload-skills is queued behind the running turn"))))
      (length changes))))

(defun ecc-skill-set-override (session name value &optional file)
  "Set the skill NAME of SESSION to VALUE, and say so.
VALUE nil puts the skill back to the default.  FILE is the settings
file to write; `ecc-skill-settings-file' decides when it is not given.
The session is sent /reload-skills afterwards unless
`ecc-skill-reload-after-toggle' says not to, and the settings are read
again, so that what is shown is what the CLI has rather than what Emacs
meant to write."
  (let ((file (or file (ecc-skill-settings-file session))))
    (ecc-skill-save-overrides session (list (cons name value)) file)
    file))

(defun ecc-skill-reload (session)
  "Ask SESSION to scan its skills again.
Returns what `ecc-proc-send-prompt' returned, or nil when there is no
CLI to ask."
  (when (ecc-skill--running-p session)
    (ecc-proc-send-prompt session "/reload-skills")))

;;;; Running one

(defun ecc-skill-invoke (session name)
  "Run the skill NAME in SESSION by sending the command it installs.
A skill is a slash command of its own name; there is nothing else to
send."
  (let ((outcome (ecc-proc-send-prompt session (concat "/" name))))
    (ecc-display-session session)
    (message "%s" (if (eq outcome 'sent)
                      (format "Sent /%s" name)
                    (format "/%s is queued at position %s" name outcome)))
    outcome))

;;;###autoload
(defun ecc-skill-run (session name)
  "Run the skill NAME in SESSION.
The skills of the session are offered with what each is for."
  (interactive
   (let* ((session (ecc-skill--read-session))
          (skills (ecc-skill-list session)))
     (when (null skills)
       (user-error "%s has named no skills yet" (ecc-session-name session)))
     (list session (ecc-skill--read-name session skills))))
  (ecc-skill-invoke session name))

(defun ecc-skill--read-name (session skills)
  "Read one of SKILLS of SESSION, and return its name."
  (let ((table (mapcar (lambda (skill)
                         (cons (ecc-skill-name skill) skill))
                       skills)))
    (completing-read
     (format "Skill of %s: " (ecc-session-name session))
     (lambda (string predicate action)
       (if (eq action 'metadata)
           `(metadata
             (category . ecc-skill)
             (annotation-function
              . ,(lambda (name)
                   (when-let* ((skill (cdr (assoc name table))))
                     (concat "  " (ecc-skill--annotation skill))))))
         (complete-with-action action table string predicate)))
     nil t)))

(defun ecc-skill--annotation (skill)
  "Return the line shown beside SKILL when it is offered."
  (string-trim
   (format "%s %s"
           (if (ecc-skill-override skill)
               (format "[%s]" (ecc-skill-override skill))
             "")
           (ecc--truncate (or (ecc-skill-description skill) "") 70))))

;;;; The buffer

(defvar-local ecc-skill--session nil
  "The session the Skills buffer is about.")

(defvar-local ecc-skill--folded nil
  "Keys of the groups the user has folded shut.")

(defvar-local ecc-skill--built-in nil
  "Non-nil when this buffer lists the skills built into the CLI too.")

(defvar-local ecc-skill--pending nil
  "Settings changed in this buffer and not written yet.
An alist of skill name and the value it is to be given, `default'
standing for the entry being taken out again.  The terminal client
works the same way: what is cycled is held until the dialog is closed
and then written in one go, so that walking a skill from on to off
leaves one change on disk rather than three.")

(defun ecc-skill-pending-value (name)
  "Return the value NAME is waiting to be given in this buffer.
A cons of the name and the value when there is one, so that a pending
`default' can be told from nothing pending."
  (assoc name ecc-skill--pending))

(defun ecc-skill-effective (skill)
  "Return what SKILL is set to, counting what has not been written yet."
  (if-let* ((pending (ecc-skill-pending-value (ecc-skill-name skill))))
      (unless (eq (cdr pending) 'default) (cdr pending))
    (ecc-skill-override skill)))

(defun ecc-skill--pending-changes ()
  "Return the pending settings of this buffer.
They come as an alist of skill name and value, which is what
`ecc-skill-save-overrides\=' takes."
  (mapcar (lambda (pending)
            (cons (car pending)
                  (unless (eq (cdr pending) 'default) (cdr pending))))
          (reverse ecc-skill--pending)))

(defun ecc-skill--set-pending (skill value)
  "Hold VALUE for SKILL until this buffer is done with.
VALUE `default\=' takes the entry out again.  A value that is what the
settings already say is not held at all, so that cycling all the way
round leaves nothing to write."
  (let* ((name (ecc-skill-name skill))
         (written (ecc-skill-override skill))
         (wanted (unless (eq value 'default) value)))
    (setq ecc-skill--pending (assoc-delete-all name ecc-skill--pending))
    (unless (equal written wanted)
      (push (cons name value) ecc-skill--pending))))

(defun ecc-skill-shown (session)
  "Return the skills of SESSION this buffer lists.
The ones built into the CLI are left out unless they were asked for,
which is what the terminal client\='s own /skills does."
  (let ((skills (ecc-skill-list session)))
    (if ecc-skill--built-in
        skills
      (seq-remove #'ecc-skill-built-in-p skills))))

(defun ecc-skill--state (skill)
  "Return the mark, the word and the face SKILL is drawn with."
  (or (assoc (or (ecc-skill-effective skill) "on") ecc-skill-override-marks)
      (assoc "on" ecc-skill-override-marks)))

(defun ecc-skill--state-column (skill)
  "Return what SKILL is set to, drawn the way the terminal client draws it.
The mark and the word come first, before the name, and a skill that is
locked carries a padlock in place of the mark."
  (pcase-let ((`(,_value ,mark ,word ,face) (ecc-skill--state skill)))
    (cond ((ecc-skill-locked-p skill)
           (propertize (concat ecc-skill-lock-mark " " (string-pad word 9))
                       'face 'ecc-dim-face))
          ;; A change that is not written yet is marked as such: the
          ;; buffer must not read as though the settings already said it.
          ((ecc-skill-pending-value (ecc-skill-name skill))
           (concat (propertize (concat mark " " (string-pad word 8)) 'face face)
                   (propertize "*" 'face 'ecc-warning-face)))
          (t (propertize (concat mark " " (string-pad word 9)) 'face face)))))

(defun ecc-skill--label (skill width)
  "Return the line describing SKILL, its name padded to WIDTH."
  (concat (ecc-skill--state-column skill)
          "  "
          (propertize (string-pad (ecc-skill-name skill) width)
                      'face (if (ecc-skill-off-p skill)
                                'ecc-dim-face
                              'ecc-tool-face))
          (propertize
           (concat (when (ecc-skill-lock skill)
                     (format " · locked by %s" (ecc-skill-lock skill)))
                   " " (ecc--truncate (or (ecc-skill-description skill) "") 100))
           'face 'ecc-dim-face)))

(defun ecc-skill--header (session skills)
  "Return the first lines of the Skills buffer of SESSION, about SKILLS."
  (let ((off (seq-count #'ecc-skill-off-p skills))
        (hidden (unless ecc-skill--built-in
                  (seq-count #'ecc-skill-built-in-p
                             (ecc-skill-list session)))))
    (concat
     (propertize (format "Skills of %s -- %d%s\n"
                         (ecc-session-name session) (length skills)
                         (if (> off 0) (format ", %d off" off) ""))
                 'face 'ecc-heading-face)
     (propertize
      (concat
       (pcase (ecc-skill-settings-state session)
         ('read (format "Turning one on and off writes %s."
                        (abbreviate-file-name
                         (ecc-skill-settings-file session))))
         ('failed "The CLI would not say what the settings are; g asks again.")
         (_ "The settings have not been read yet; g asks for them."))
       (when ecc-skill--pending
         (format "  %d change%s not written yet; q writes them."
                 (length ecc-skill--pending)
                 (if (= (length ecc-skill--pending) 1) "" "s")))
       (when (and hidden (> hidden 0))
         (format "  %d of the CLI's own, hidden; a shows them." hidden))
       "\n")
      'face 'ecc-dim-face)
     (propertize (concat (ecc-skill--key-line) "\n\n") 'face 'ecc-dim-face))))

(defvar ecc-skill-key-hints
  '(("RET" . "cycle") ("o" . "open") ("a" . "built-in") ("g" . "refresh")
    ("r" . "reload") ("q" . "save and close"))
  "The keys named under the heading, and what each does.
The terminal client says the same under the title of its own dialog --
\"enter/space to cycle, / to search, t to sort, esc to close\" -- because
a handful of keys nobody presses daily is not a thing to remember.

The line is kept inside eighty columns, since the buffer does not wrap:
what is left out is what the line itself makes plain (SPC does what RET
does) or what any Emacs buffer does anyway (TAB folds, C-c C-k forgets
the changes); the mode help has all of it.")

(defun ecc-skill--key-line ()
  "Return the line naming the keys of this buffer."
  (mapconcat (lambda (hint) (format "%s %s" (car hint) (cdr hint)))
             ecc-skill-key-hints " · "))

(defvar ecc-skill-source-order
  '("project" "user" "local" "claude.ai" "dynamic workflow" "plugin" "built-in")
  "The order the groups of the Skills buffer are shown in.
A source that is not named here -- a plugin goes by its own name --
comes after these, in alphabetical order.")

(defun ecc-skill--sources-of (skills)
  "Return the sources of SKILLS, in the order they are shown."
  (let ((sources (seq-uniq (mapcar #'ecc-skill-source-name skills))))
    (append (seq-filter (lambda (source) (member source sources))
                        ecc-skill-source-order)
            (sort (seq-remove (lambda (source)
                                (member source ecc-skill-source-order))
                              sources)
                  #'string<))))

(defun ecc-skill--insert-heading (key text)
  "Insert the heading TEXT of the group KEY, and say whether it is open."
  (let ((folded (member key ecc-skill--folded))
        (start (point)))
    (insert (propertize (concat (if folded "▸ " "▾ ") text)
                        'face 'ecc-heading-face)
            "\n")
    (put-text-property start (point) 'ecc-skill-key key)
    (not folded)))

(defun ecc-skill-draw (session)
  "Draw the skills of SESSION into the current buffer."
  (let* ((inhibit-read-only t)
         (skills (ecc-skill-shown session))
         (width (max 12 (apply #'max 1 (mapcar (lambda (skill)
                                                 (1+ (length (ecc-skill-name skill))))
                                               skills)))))
    (erase-buffer)
    (insert (ecc-skill--header session skills))
    (if (null skills)
        (insert (propertize
                 (if (ecc-skill-list session)
                     "None of your own: every skill here came with the CLI.
a lists those too.\n"
                   "None: nothing in this project, in ~/.claude/skills or in a
plugin.  The skills the CLI came with are named in system/init, which
arrives with the first turn.\n")
                 'face 'ecc-dim-face))
      (dolist (source (ecc-skill--sources-of skills))
        (let ((of-source (seq-filter (lambda (skill)
                                       (equal (ecc-skill-source-name skill)
                                              source))
                                     skills)))
          (when (ecc-skill--insert-heading
                 source (format "%s (%d)" source (length of-source)))
            (dolist (skill of-source)
              ;; The whole line carries the skill, its indentation and
              ;; its newline with it: a command of this buffer is about
              ;; the row point is on, not about the column.
              (let ((start (point)))
                (insert "  " (ecc-skill--label skill width) "\n")
                (put-text-property start (point) 'ecc-skill skill))))
          (insert "\n"))))
    (goto-char (point-min))))

(defun ecc-skill--buffer (&optional session)
  "Return the Skills buffer, if there is one, for SESSION."
  (when-let* ((buffer (get-buffer ecc-skill-buffer-name)))
    (when (or (null session)
              (eq session (buffer-local-value 'ecc-skill--session buffer)))
      buffer)))

(defun ecc-skill--redraw (session)
  "Draw the Skills buffer again if it is about SESSION."
  (when-let* ((buffer (ecc-skill--buffer session)))
    (with-current-buffer buffer
      (save-excursion (ecc-skill-draw session)))
    buffer))

(defun ecc-skill--property-here (property)
  "Return PROPERTY of the line point is on, or nil.
The line is asked rather than the character, so that a command works
from anywhere on the row -- the indentation, the end of the line, the
column the description happens to reach."
  (or (get-text-property (point) property)
      (get-text-property (line-beginning-position) property)))

(defun ecc-skill--at-point ()
  "Return the skill of the line point is on, or signal an error."
  (or (ecc-skill--property-here 'ecc-skill)
      (user-error "This line is not a skill")))

(defun ecc-skill--session-here ()
  "Return the session the Skills buffer is about, or signal an error."
  (or ecc-skill--session (user-error "This buffer is about no session")))

(defun ecc-skill--read-session ()
  "Return the session the skills should be shown of."
  (or ecc-skill--session
      (and (fboundp 'ecc-dashboard-session-at-point)
           (ecc-dashboard-session-at-point))
      ecc-render--session
      (car (ecc-model-sessions))
      (user-error "No session to look at")))

;;;###autoload
(defun ecc-skill-show (&optional session)
  "Show the skills of SESSION, and what each of them is set to."
  (interactive)
  (let ((session (or session (ecc-skill--read-session)))
        (buffer (get-buffer-create ecc-skill-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-skill-mode)
        (ecc-skill-mode))
      (setq ecc-skill--session session)
      (ecc-skill-draw session))
    (ecc-skill-read-settings session)
    (pop-to-buffer buffer)
    buffer))

(defun ecc-skill-refresh ()
  "Read the settings again and draw the Skills buffer.
What has been changed here and not written is kept: it is drawn over
whatever comes back, so that an answer arriving in the middle of a
change does not undo it."
  (interactive)
  (let ((session (ecc-skill--session-here)))
    (ecc-skill-draw session)
    (ecc-skill-read-settings session)))

(defun ecc-skill-toggle-fold ()
  "Fold or unfold the group at point."
  (interactive)
  (if-let* ((key (ecc-skill--property-here 'ecc-skill-key)))
      (let ((line (line-number-at-pos)))
        (setq ecc-skill--folded
              (if (member key ecc-skill--folded)
                  (delete key ecc-skill--folded)
                (cons key ecc-skill--folded)))
        (ecc-skill-draw (ecc-skill--session-here))
        (goto-char (point-min))
        (forward-line (1- line)))
    (user-error "Point is not on a group")))

(defun ecc-skill--redraw-here ()
  "Draw this buffer again, leaving point on the line it was on."
  (let ((line (line-number-at-pos))
        (column (current-column)))
    (ecc-skill-draw (ecc-skill--session-here))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)))

(defun ecc-skill-cycle ()
  "Give the skill at point the next of the four settings the CLI takes.
On → name-only → user-invocable-only → off → on, the way RET and SPC
cycle one in the terminal client.  Nothing is written until the buffer
is done with (\[ecc-skill-save]); on a group heading this folds
instead."
  (interactive)
  (if (ecc-skill--property-here 'ecc-skill-key)
      (ecc-skill-toggle-fold)
    (let* ((skill (ecc-skill--at-point))
           (values (mapcar #'car ecc-skill-override-values))
           (current (or (ecc-skill-effective skill) "on"))
           (next (nth (% (1+ (or (seq-position values current) 0))
                         (length values))
                      values)))
      (ecc-skill--check-settable skill)
      (ecc-skill--set-pending skill (if (equal next "on") 'default next))
      (ecc-skill--redraw-here))))

(defun ecc-skill-visit ()
  "Open the SKILL.md of the skill at point."
  (interactive)
  (let ((skill (ecc-skill--at-point)))
    (cond ((null (ecc-skill-file skill))
           (user-error "%s is built into the CLI; there is no file to open"
                       (ecc-skill-name skill)))
          ((file-directory-p (ecc-skill-file skill))
           (dired (ecc-skill-file skill)))
          (t (find-file (ecc-skill-file skill))))))

(defun ecc-skill-locked-p (skill)
  "Return non-nil when the setting of SKILL is not the user\='s to change."
  (or (ecc-skill-lock skill) (eq (ecc-skill-scope skill) 'plugin)))

(defun ecc-skill--check-settable (skill)
  "Signal unless SKILL is one whose setting is the user\='s to change.
A policy or a flag has the last word on a skill, and a skill a plugin
brought is the plugin\='s; the terminal client draws both with a lock
and will not cycle them."
  (when-let* ((lock (ecc-skill-lock skill)))
    (user-error "%s is settled by %s" (ecc-skill-name skill) lock))
  (when (eq (ecc-skill-scope skill) 'plugin)
    (user-error "%s comes from a plugin; those are managed with /plugin"
                (ecc-skill-name skill))))

(defun ecc-skill-toggle-built-in ()
  "Show the skills built into the CLI in this buffer, or hide them again.
They are hidden to begin with, the way the terminal client hides its
own: a skill that came with the CLI is not one of yours to manage.
Shown, they can be run from here like any other."
  (interactive)
  (setq ecc-skill--built-in (not ecc-skill--built-in))
  (ecc-skill-draw (ecc-skill--session-here))
  (message (if ecc-skill--built-in
               "Listing the skills of the CLI as well"
             "Listing your own skills only")))

(defun ecc-skill-save (&optional ask-file)
  "Write what has been changed in this buffer, and tell the session.
The settings of every skill go out in one change, and the session is
asked to scan its skills once, the way the terminal client saves when
its dialog is closed.

With ASK-FILE, a prefix argument, the settings file they are written to
is asked for first and remembered in `ecc-skill-settings-file\=' for the
rest of the Emacs session.  The terminal client always writes the one
of the project; this is the only way to write another."
  (interactive "P")
  (let ((session (ecc-skill--session-here))
        (changes (ecc-skill--pending-changes)))
    (when (and ask-file changes)
      (setq ecc-skill-settings-file
            (completing-read "Write them to: "
                             (ecc-skill-settings-files session) nil t)))
    (if (null changes)
        (progn (message "No changes") 0)
      (ecc-skill-save-overrides session changes)
      (setq ecc-skill--pending nil)
      (length changes))))

(defun ecc-skill-quit (&optional ask-file)
  "Write what has been changed in this buffer, and bury it.
ASK-FILE is passed to `ecc-skill-save\='."
  (interactive "P")
  (ecc-skill-save ask-file)
  (quit-window))

(defun ecc-skill-revert ()
  "Forget what has been changed in this buffer without writing it."
  (interactive)
  (if (null ecc-skill--pending)
      (message "No changes")
    (let ((n (length ecc-skill--pending)))
      (setq ecc-skill--pending nil)
      (ecc-skill--redraw-here)
      (message "Forgot %d change%s" n (if (= n 1) "" "s")))))

(defun ecc-skill-reload-here ()
  "Ask the session of this buffer to scan its skills again."
  (interactive)
  (let ((session (ecc-skill--session-here)))
    (if (ecc-skill-reload session)
        (message "The session is reading its skills again")
      (user-error "%s is not running" (ecc-session-name session)))))

(defvar ecc-skill-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-skill-cycle)
    (define-key map (kbd "SPC") #'ecc-skill-cycle)
    (define-key map (kbd "TAB") #'ecc-skill-toggle-fold)
    (define-key map (kbd "o") #'ecc-skill-visit)
    (define-key map (kbd "a") #'ecc-skill-toggle-built-in)
    (define-key map (kbd "g") #'ecc-skill-refresh)
    (define-key map (kbd "r") #'ecc-skill-reload-here)
    (define-key map (kbd "C-c C-c") #'ecc-skill-save)
    (define-key map (kbd "C-c C-k") #'ecc-skill-revert)
    (define-key map (kbd "q") #'ecc-skill-quit)
    map)
  "Keymap of `ecc-skill-mode'.")

(define-derived-mode ecc-skill-mode special-mode "Claude-Skills"
  "Major mode listing the skills of a session.

RET and SPC cycle what the skill at point is set to, as they do in the
terminal client, and nothing is written until the buffer is done with:
q saves and buries it, \\[ecc-skill-save] saves without leaving and
\\[ecc-skill-revert] forgets.  A setting that has not been written yet
is marked with a star.  A prefix argument to either of the two that
save asks which settings file to write.

Running a skill is not done from here, because it is not done from the
terminal client\='s /skills either: send /<name> from the prompt.

The skills built into the CLI are not listed until a asks for them,
which is what the terminal client does with its own /skills.

\\{ecc-skill-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

;;;; The way in: /skills in the prompt region

(defun ecc-skill-intercept (session text)
  "Answer TEXT for SESSION when it is the local /skills command.
A bare /skills opens the buffer; /skills followed by a name runs that
skill.  Returns non-nil when it did, which is what keeps the draft from
being sent.  This is on `ecc-prompt-intercept-functions'."
  (when (member (ecc-prompt-command-name text) ecc-skill-commands)
    (let ((name (ecc-prompt-command-argument text)))
      (if (or (null name) (string-empty-p name))
          (ecc-skill-show session)
        (let ((name (string-remove-prefix "/" name)))
          (unless (member name (ecc-skill-names session))
            (user-error "%s has no skill called %s" (ecc-session-name session)
                        name))
          (ecc-skill-invoke session name))))
    t))

;;;; Wiring

(defun ecc-skill--on-session-change (session &rest _)
  "Draw the Skills buffer again when SESSION says something new."
  (ecc-skill--redraw session))

(with-eval-after-load 'ecc-prompt
  (add-hook 'ecc-prompt-intercept-functions #'ecc-skill-intercept)
  ;; A bare /skills opens the buffer, and the buffer is where a skill
  ;; is run from, so choosing it in the prompt region is the whole of
  ;; it.  A skill by name is still typed out and sent.
  (add-to-list 'ecc-prompt-immediate-commands (car ecc-skill-commands)))

(add-hook 'ecc-session-init-hook #'ecc-skill--on-session-change)
(add-hook 'ecc-commands-updated-hook #'ecc-skill--on-session-change)

(provide 'ecc-skill)

;;; ecc-skill.el ends here
