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
(require 'ecc-git)
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
(require 'ecc-capabilities)
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

;; The keymap for every buffer is here, above every module, because its
;; keys name commands of nearly all of them: this file requires each, so
;; the map needs nothing declared, and no module below has to know the
;; commands of the ones above it.  The first key pressed -- or the listing
;; of that key -- loads the whole package, which most of those commands
;; load on their own anyway.
;;
;; The symbol carries the keymap in its function cell as well as its value,
;; so that it is a prefix command and not only a variable.  A prefix command
;; is what `C-h', `which-key' and the rest read a prefix key through: bound to
;; the value, `C-c c' is a complete key sequence running a command, and
;; nothing offers to list what follows it.  The autoload form below is the
;; keymap kind, so the binding works before this file is loaded and loads it
;; when the key -- or the listing of that key -- asks for what is inside.
;;;###autoload (autoload 'ecc-global-map "ecc" nil t 'keymap)
(defvar ecc-global-map
  (let ((map (make-sparse-keymap)))
    ;; The session.
    (define-key map (kbd "c") #'ecc-start)
    ;; Resume itself rather than the menu in front of it: it is the
    ;; commonest thing done here, and `C-u' is the fork.  `ecc-menu'
    ;; keeps `ecc-resume-menu' under r, because the fork is worth one
    ;; form where it is seen before it is pressed.
    (define-key map (kbd "r") #'ecc-resume)
    (define-key map (kbd "R") #'ecc-rename-session)
    (define-key map (kbd "v") #'ecc-show-session)
    (define-key map (kbd "i") #'ecc-interrupt)
    (define-key map (kbd "t") #'ecc-tui-open)
    ;; The Spaces have the lower-case keys, being where the day is spent:
    ;; `j' goes to one, `b' is the sidebar that lists them, `z' is
    ;; herdr's zoom and `V' puts the tab back to the arrangement a new
    ;; Space gets.  `v' goes to the prompt of a session and `V' to the
    ;; windows around it, which is the pair worth having beside each
    ;; other.
    ;;
    ;; `B' is the dashboard: the capital beside the `b' that is pressed
    ;; all day, the two being the same list, one that stays on the screen
    ;; and one that does not.
    ;;
    ;; Nothing here makes or removes a worktree.  The three that do
    ;; belong together and are done in a week what these are done in an
    ;; hour: they are `ecc-worktree-menu', under `?' then `W'.
    (define-key map (kbd "j") #'ecc-space-goto)
    (define-key map (kbd "b") #'ecc-sidebar-focus)
    (define-key map (kbd "z") #'ecc-space-zoom)
    (define-key map (kbd "V") #'ecc-space-cycle-layout)
    ;; Answering what is waiting.
    (define-key map (kbd "a") #'ecc-answer-allow)
    (define-key map (kbd "d") #'ecc-answer-deny)
    (define-key map (kbd "n") #'ecc-next-attention)
    (define-key map (kbd "N") #'ecc-next-attention-in-project)
    (define-key map (kbd "1") #'ecc-answer-option-1)
    (define-key map (kbd "2") #'ecc-answer-option-2)
    (define-key map (kbd "3") #'ecc-answer-option-3)
    (define-key map (kbd "4") #'ecc-answer-option-4)
    ;; Looking around.
    (define-key map (kbd "B") #'ecc-dashboard)
    ;; `D' asks what to compare: `D' again is what changed since the
    ;; session started, `w' what changed since the last commit.
    (define-key map (kbd "D") #'ecc-review-menu)
    (define-key map (kbd "h") #'ecc-history-open)
    (define-key map (kbd "/") #'ecc-search)
    (define-key map (kbd "U") #'ecc-usage)
    (define-key map (kbd "?") #'ecc-menu)
    map)
  "Keymap of the commands that work from any buffer.
What is here is the handful worth a key of its own, not everything the
package can do: `C-c c\=' is the user\='s own key, and a map of forty
commands leaves no room beside it and no listing anyone can read.  The
rest is reached through `ecc-menu\='.

Bind the symbol, not the value, to a prefix key:

    (global-set-key (kbd \"C-c c\") \='ecc-global-map)

which makes `ecc-global-map\=' a prefix command, so that
`describe-prefix-bindings\=' and `which-key\=' can say what follows it.
With an autoload form of the keymap kind -- generated from this file, or
written by hand where nothing generates one -- the binding can be made
before ecc is loaded.

Every key here means in `ecc-menu' what it means here, so that one letter
carries one meaning wherever it is pressed; `?' opens that menu, which is
the only way to reach it from a buffer that is not a session.  `r' is the
one key whose command differs: here it resumes at once, with the fork in
the prefix argument, while in the menu it opens `ecc-resume-menu', where
the fork is a switch.  The meaning is the same; only the form differs.")

(defalias 'ecc-global-map ecc-global-map)

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
