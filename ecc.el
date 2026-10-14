;;; ecc.el --- Client for the Claude Code CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5
;; Assisted-by: Claude Code:claude-opus-5-5
;; Assisted-by: Claude Code:claude-fable-5-1
;; Assisted-by: Claude Code:claude-haiku-4-5
;; Maintainer: Jun <wakamenod@gmail.com>
;; Version: 0.4.5
;; Package-Requires: ((emacs "29.1"))
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

;; An Emacs client for the Claude Code CLI: it runs `claude' headless
;; with the stream-json protocol and shows the conversation in one
;; buffer, the transcript above and the prompt below.
;;
;; `M-x ecc-start' starts a session in the project of the current
;; buffer and `M-x ecc-resume' opens a conversation again.  `M-x
;; ecc-menu' is every command in one menu, and `M-x ecc-dashboard'
;; lists the sessions of this Emacs with the recordings beside them.
;;
;; The CLI is not part of this package: install it separately, and name
;; it in `ecc-executable' if it is not found on `exec-path'.

;;; Code:

(require 'cl-lib)
(require 'lisp-mnt)
(require 'package)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-table)
(require 'ecc-markdown)
(require 'ecc-visual)
(require 'ecc-dispatch)
(require 'ecc-render)
(require 'ecc-chat)
(require 'ecc-session)
(require 'ecc-prompt)
(require 'ecc-queue)
(require 'ecc-perm)
(require 'ecc-hooks)
(require 'ecc-plan)
(require 'ecc-review)
(require 'ecc-review-ediff)
(require 'ecc-sync)
(require 'ecc-answer)
(require 'ecc-registry)
(require 'ecc-history)
(require 'ecc-restore)
(require 'ecc-search)
(require 'ecc-capability)
(require 'ecc-dashboard)
(require 'ecc-window)
(require 'ecc-lifecycle)
(require 'ecc-worktree)
(require 'ecc-space)
(require 'ecc-sidebar)
(require 'ecc-context)
(require 'ecc-notify)
(require 'ecc-hint)
(require 'ecc-usage)
(require 'ecc-mcp)
(require 'ecc-plugin)
(require 'ecc-inline)
(require 'ecc-btw)
(require 'ecc-skill)
(require 'ecc-auth)
(require 'ecc-tui)
(require 'ecc-transient)

;; The review tools register themselves with the MCP server when they
;; are loaded, and a tool registered after a session's CLI has listed the
;; tools is one that session never sees.  So they are loaded here, with
;; everything else, rather than with the first review opened.
(require 'ecc-review-agent)
(require 'ecc-review-menu)
(require 'ecc-review-talk)

;; The version is written once, in the Version header above, because that
;; is the one package.el and `package-vc-install' read.  Repeating it in a
;; constant here would mean a release that says two different things, so
;; it is read back instead: from the package descriptor when ecc was
;; installed, and from the header of ecc.el itself when it was only put on
;; `load-path'.
(defun ecc--header-version (file)
  "Return the Version header of FILE, or nil when FILE cannot be read.
A file can be readable and still fail to read, so the `file-error' is
caught as well as checked for.  A directory is asked about first: reading
one is not a `file-error' on every system."
  (condition-case nil
      (and (file-readable-p file)
           (not (file-directory-p file))
           (with-temp-buffer
             (insert-file-contents file nil 0 4096)
             (lm-header "version")))
    (file-error nil)))

(defconst ecc-version
  (or (condition-case nil (package-get-version) (file-error nil))
      (ecc--header-version
       (expand-file-name "ecc.el"
                         (file-name-directory (or load-file-name
                                                  buffer-file-name
                                                  default-directory))))
      "unknown")
  "The version of ecc that is loaded, as its Version header says.")

;;;###autoload
(defun ecc-version (&optional here)
  "Show which ecc, Emacs and Claude Code CLI are running.
With a prefix argument HERE, insert the line at point instead.  It is
what a bug report has to open with: nearly everything this package works
around belongs to one version of the CLI, and the CLI is the piece that
moves without anybody upgrading anything."
  (interactive "P")
  (let* ((cli (or (ecc--cli-version) "not found"))
         (line (format "ecc %s, Emacs %s, Claude Code CLI %s"
                       ecc-version emacs-version cli)))
    (if here (insert line) (message "%s" line))))

(defun ecc--cli-version ()
  "Return what `ecc-executable' says its version is, or nil.
The CLI prints something like \"2.1.268 (Claude Code)\"; only the number
is kept.  A missing or silent executable is a nil, not an error: the
point of `ecc-version' is to report on a machine that is already broken."
  (condition-case nil
      (with-temp-buffer
        (when (and (executable-find ecc-executable)
                   (eq 0 (call-process ecc-executable nil t nil "--version")))
          (goto-char (point-min))
          (when (re-search-forward "[0-9][^ \t\n]*" nil t)
            (match-string 0))))
    ;; Found on PATH and still not started: a broken link, a bad #! line.
    (file-error nil)))

(provide 'ecc)

;;; ecc.el ends here
