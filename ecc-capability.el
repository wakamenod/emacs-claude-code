;;; ecc-capability.el --- What a session can do, and where it is defined  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes

;;; Commentary:

;; What a session can do is spread over `system/init' (the names of the
;; skills, agents, commands, MCP servers and plugins) and the answer to
;; `initialize' (what each command is for).  Neither says where a thing
;; is defined; that is found on disk, under `.claude/' of the project,
;; of the user, or of a plugin.
;;
;; Two modules need that lookup -- the Capabilities buffer of
;; `ecc-dashboard' and the Skills buffer of `ecc-skill' -- and a third
;; would have had to require the first to get at it.  It lives here
;; instead, on its own, requiring nothing but the session.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)

(defvar ecc-capabilities-directory "~/.claude/"
  "Directory holding the skills, agents and commands of every project.")

(defconst ecc-capabilities-scopes
  '((project . "project") (global . "global") (plugin . "plugin")
    (builtin . "built in"))
  "The scopes a capability can come from, in the order they are shown.")

(defun ecc-capabilities--kind-directory (kind)
  "Return the subdirectory KIND is defined in, under a settings directory."
  (pcase kind ('skill "skills/") ('agent "agents/") ('command "commands/")))

(defun ecc-capabilities--file-in (directory kind name)
  "Return the file defining the KIND called NAME under DIRECTORY, or nil."
  (when-let* ((subdirectory (ecc-capabilities--kind-directory kind)))
    (let* ((base (expand-file-name subdirectory (expand-file-name directory)))
           (candidates (if (eq kind 'skill)
                           (list (expand-file-name (concat name "/SKILL.md") base))
                         (list (expand-file-name (concat name ".md") base)))))
      (seq-find #'file-readable-p candidates))))

(defun ecc-capabilities--locate (kind name session plugins)
  "Return (SCOPE ORIGIN . FILE) for the KIND called NAME.
The project of SESSION is looked in first, then the settings directory
of the user, then each of the PLUGINS.  A name that is defined nowhere
Emacs can see is `builtin'."
  (or (when-let* ((root (ecc-session-project-root session))
                  (file (ecc-capabilities--file-in
                         (expand-file-name ".claude/" root) kind name)))
        (cl-list* 'project nil file))
      (when-let* ((file (ecc-capabilities--file-in
                         ecc-capabilities-directory kind name)))
        (cl-list* 'global nil file))
      (seq-some (lambda (plugin)
                  (when-let* ((path (alist-get 'path plugin))
                              (file (ecc-capabilities--file-in path kind name)))
                    (cl-list* 'plugin (alist-get 'name plugin) file)))
                plugins)
      (list 'builtin nil)))

(defun ecc-capabilities--command-descriptions (session)
  "Return a hash of a command name to its description for SESSION.
The descriptions are what the CLI answered `initialize' with."
  (let ((table (make-hash-table :test #'equal)))
    (seq-doseq (command (or (ecc-session-commands session) []))
      (when-let* ((name (alist-get 'name command)))
        (puthash name (alist-get 'description command) table)))
    table))

(provide 'ecc-capability)

;;; ecc-capability.el ends here
