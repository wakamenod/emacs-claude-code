;;; ecc-capabilities.el --- What a session can do, in one buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Assisted-by: Claude Code:claude-opus-5-5
;; Assisted-by: Claude Code:claude-fable-5-1
;; Assisted-by: Claude Code:claude-haiku-4-5
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The Capabilities buffer: the skills, agents, commands, MCP servers
;; and plugins of one session, sorted by kind and scope, each with the
;; file that defines it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-render)
(require 'ecc-capability)
(require 'ecc-skill)

;;;; Capabilities

;; What a session can do is spread over `system/init' (the names of the
;; skills, agents, commands, MCP servers and plugins) and the answer to
;; `initialize' (what each command is for).  Here the two are put back
;; together, sorted by what they are and where they come from, and each
;; one is given the file that defines it so RET can open it.
;;
;; The tree folds without a section library: a heading carries the key
;; of its group, TAB adds or removes that key from the set of folded
;; groups and the buffer is drawn again.  It is a page of a few hundred
;; lines, so drawing it whole costs nothing.

(defconst ecc-capabilities-buffer-name "*ecc-capabilities*"
  "Name of the Capabilities buffer.")

(cl-defstruct ecc-capability
  "One thing a session can do."
  kind          ; skill | agent | command | mcp | plugin
  name
  description
  scope         ; global | project | plugin | builtin
  origin        ; the plugin a plugin-scoped entry came from, or nil
  file          ; what RET opens, or nil
  detail)       ; the extra line an MCP server or a plugin carries

(defconst ecc-capabilities-kinds
  '((skill . "Skills") (agent . "Agents") (command . "Slash commands")
    (mcp . "MCP servers") (plugin . "Plugins"))
  "The five kinds of capability, in the order they are shown.")

(defun ecc-capabilities--mcp-tool-count (init name)
  "Return how many tools the MCP server NAME published, from INIT."
  (let ((prefix (format "mcp__%s__" name)))
    (seq-count (lambda (tool) (string-prefix-p prefix tool))
               (append (alist-get 'tools init) nil))))

(defun ecc-capabilities--mcp-file (session)
  "Return the file that configures the MCP servers of SESSION, or nil."
  (seq-find #'file-readable-p
            (delq nil
                  (list (when-let* ((root (ecc-session-project-root session)))
                          (expand-file-name ".mcp.json" root))
                        (expand-file-name "settings.json"
                                          (expand-file-name
                                           ecc-capabilities-directory))
                        (ecc-config-json-file)))))

(defun ecc-capabilities (session)
  "Return everything SESSION can do, as a list of `ecc-capability'.
The names come from the last system/init and the descriptions from the
answer to initialize."
  (let* ((init (ecc-session-init session))
         (plugins (append (alist-get 'plugins init) nil))
         (descriptions (ecc-capabilities--command-descriptions session))
         (skills (append (alist-get 'skills init) nil))
         (entries nil))
    (dolist (name skills)
      (pcase-let ((`(,scope ,origin . ,file)
                   (ecc-capabilities--locate 'skill name session plugins)))
        (push (make-ecc-capability :kind 'skill :name name
                                   :description (gethash name descriptions)
                                   :scope scope :origin origin :file file)
              entries)))
    (seq-doseq (name (or (alist-get 'agents init) []))
      (pcase-let ((`(,scope ,origin . ,file)
                   (ecc-capabilities--locate 'agent name session plugins)))
        (push (make-ecc-capability :kind 'agent :name name
                                   :scope scope :origin origin :file file)
              entries)))
    (seq-doseq (name (or (alist-get 'slash_commands init) []))
      ;; A command a skill installs is defined by the skill; saying so
      ;; twice would only make the list longer.
      (unless (member name skills)
        (pcase-let ((`(,scope ,origin . ,file)
                     (ecc-capabilities--locate 'command name session plugins)))
          (push (make-ecc-capability :kind 'command :name name
                                     :description (gethash name descriptions)
                                     :scope scope :origin origin :file file)
                entries))))
    (seq-doseq (server (or (alist-get 'mcp_servers init) []))
      (let ((name (alist-get 'name server)))
        (push (make-ecc-capability
               :kind 'mcp :name name
               :scope 'global
               :file (ecc-capabilities--mcp-file session)
               :detail (format "%s, %d tools"
                               (or (alist-get 'status server) "unknown")
                               (ecc-capabilities--mcp-tool-count init name)))
              entries)))
    (dolist (plugin plugins)
      (push (make-ecc-capability
             :kind 'plugin :name (alist-get 'name plugin)
             :scope 'plugin :origin (alist-get 'source plugin)
             :file (alist-get 'path plugin)
             :detail (format "%s from %s"
                             (or (alist-get 'version plugin) "?")
                             (or (alist-get 'source plugin) "?")))
            entries))
    (nreverse entries)))

;;;; Drawing the Capabilities buffer

(defvar-local ecc-capabilities--session nil
  "The session the Capabilities buffer is about.")

(defvar-local ecc-capabilities--folded nil
  "Keys of the groups the user has folded shut.")

(defun ecc-capabilities--group-key (kind &optional scope)
  "Return the key of the group of KIND and SCOPE."
  (if scope (format "%s/%s" kind scope) (format "%s" kind)))

(defun ecc-capabilities--skill-override (capability)
  "Return what CAPABILITY is set to, when it is a skill that is not on.
`ecc-skill\=' owns the skill settings."
  (when (and (eq (ecc-capability-kind capability) 'skill)
             ecc-capabilities--session)
    (ecc-skill-override-for ecc-capabilities--session
                            (ecc-capability-name capability))))

(defun ecc-capabilities--label (capability)
  "Return the line describing CAPABILITY, without its indentation."
  (concat (propertize (ecc-capability-name capability) 'face 'ecc-tool-face)
          (when-let* ((override (ecc-capabilities--skill-override capability)))
            (propertize (format "  [%s]" override) 'face 'ecc-warning-face))
          (when-let* ((detail (ecc-capability-detail capability)))
            (propertize (format "  (%s)" detail) 'face 'ecc-dim-face))
          (when-let* ((description (ecc-capability-description capability)))
            (propertize (concat "  " (ecc--truncate description 100))
                        'face 'ecc-dim-face))))

(defun ecc-capabilities--insert-heading (key text)
  "Insert the heading TEXT of the group KEY, marked as foldable."
  (let ((folded (member key ecc-capabilities--folded)))
    (insert (propertize (concat (if folded "▸ " "▾ ") text)
                        'face 'ecc-heading-face
                        'ecc-capabilities-key key)
            "\n")
    (not folded)))

(defun ecc-capabilities-draw (session)
  "Draw everything SESSION can do into the current buffer."
  (let ((inhibit-read-only t)
        (entries (ecc-capabilities session)))
    (erase-buffer)
    (insert (propertize (format "Capabilities of %s\n\n"
                                (ecc-session-name session))
                        'face 'ecc-heading-face))
    (if (null entries)
        (insert (propertize
                 "Nothing yet: the CLI says what it can do in system/init,
which arrives with the first turn.\n"
                 'face 'ecc-dim-face))
      (pcase-dolist (`(,kind . ,title) ecc-capabilities-kinds)
        (let ((of-kind (seq-filter (lambda (entry)
                                     (eq (ecc-capability-kind entry) kind))
                                   entries)))
          (when of-kind
            (when (ecc-capabilities--insert-heading
                   (ecc-capabilities--group-key kind)
                   (format "%s (%d)" title (length of-kind)))
              (pcase-dolist (`(,scope . ,scope-name) ecc-capabilities-scopes)
                (let ((of-scope (seq-filter
                                 (lambda (entry)
                                   (eq (ecc-capability-scope entry) scope))
                                 of-kind)))
                  (when of-scope
                    (insert "  ")
                    (when (ecc-capabilities--insert-heading
                           (ecc-capabilities--group-key kind scope)
                           (format "%s (%d)" scope-name (length of-scope)))
                      (dolist (entry of-scope)
                        (insert "    "
                                (propertize (ecc-capabilities--label entry)
                                            'ecc-capability entry)
                                "\n"))))))
              (insert "\n"))))))
    (goto-char (point-min))))

(defvar ecc-capabilities-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-capabilities-visit)
    (define-key map (kbd "TAB") #'ecc-capabilities-toggle)
    (define-key map (kbd "g") #'ecc-capabilities-refresh)
    map)
  "Keymap of `ecc-capabilities-mode'.")

(define-derived-mode ecc-capabilities-mode special-mode "Claude-Capabilities"
  "Major mode listing the skills, agents, commands, servers and plugins.

\\{ecc-capabilities-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

;;;###autoload
(defun ecc-capabilities-show (session)
  "Show everything SESSION can do."
  (interactive (list (ecc-capabilities--read-session)))
  (let ((buffer (get-buffer-create ecc-capabilities-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-capabilities-mode)
        (ecc-capabilities-mode))
      (setq ecc-capabilities--session session)
      (ecc-capabilities-draw session))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-capabilities--read-session ()
  "Return the session the Capabilities buffer should be about."
  (or ecc-capabilities--session
      ecc-render--session
      (car (ecc-model-sessions))
      (user-error "No session to look at")))

(defun ecc-capabilities-refresh ()
  "Draw the Capabilities buffer again."
  (interactive)
  (ecc-capabilities-draw (or ecc-capabilities--session
                             (user-error "No session"))))

(defun ecc-capabilities-toggle ()
  "Fold or unfold the group at point."
  (interactive)
  (if-let* ((key (get-text-property (point) 'ecc-capabilities-key)))
      (let ((line (line-number-at-pos)))
        (setq ecc-capabilities--folded
              (if (member key ecc-capabilities--folded)
                  (delete key ecc-capabilities--folded)
                (cons key ecc-capabilities--folded)))
        (ecc-capabilities-refresh)
        (goto-char (point-min))
        (forward-line (1- line)))
    (user-error "Not on a group")))

(defun ecc-capabilities-visit ()
  "Open what defines the capability at point."
  (interactive)
  (let ((capability (get-text-property (point) 'ecc-capability)))
    (cond
     ((null capability) (ecc-capabilities-toggle))
     ((null (ecc-capability-file capability))
      (user-error "%s is built into the CLI; there is no file to open"
                  (ecc-capability-name capability)))
     ((file-directory-p (ecc-capability-file capability))
      (dired (ecc-capability-file capability)))
     (t (find-file (ecc-capability-file capability))))))

(provide 'ecc-capabilities)

;;; ecc-capabilities.el ends here
