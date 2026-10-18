;;; ecc-peer.el --- The other Claude sessions a session can talk to  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Assisted-by: Claude Code:claude-opus-5-5
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

;; Claude sessions talk to each other on their own: the model of one
;; calls the CLI's built-in SendMessage, and the CLI of the other
;; queues what arrives and starts a turn with it (see "Messages from
;; another session" in `ecc-protocol').  Emacs relays nothing.  What it
;; adds is the part a model cannot see for itself: which of the
;; sessions running on this machine is which, by the name the user
;; knows it under.
;;
;; The address a message goes to is the socket of one process,
;; `uds:/tmp/cc-socks/PID.sock' (CLI 2.1.296, 2026-10-17), so a session
;; that is restarted or resumed has a new one.  It is therefore read from
;; the registry at the moment it is handed to a model, and never kept.
;;
;; The name a session has in Emacs is not the one the CLI gives it: the
;; CLI derives its own (`emacs-claude-code-4b') and hears of Emacs's only
;; when the user renames the session (`ecc-session-rename').  The user
;; names a session by what Emacs shows, so that is what is offered, and
;; what the name stands for is found by session id whenever a session of
;; this Emacs is behind it.  The CLI's name goes along to the model as
;; well: it is the one `ListAgents' lists.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-registry)

(defconst ecc-peer-reference-prefix "session:"
  "What follows the @ of a reference that names another session.")

(defun ecc-peer-address (entry)
  "Return the address SendMessage reaches the registry ENTRY at, or nil.
Nil for a session whose CLI does not take messages, which is one that
names no socket in its session file."
  (let ((socket (alist-get 'messagingSocketPath entry)))
    (and (stringp socket) (not (string-empty-p socket))
         (concat "uds:" socket))))

(defun ecc-peer--entry-at (address name)
  "Return the registry entry of the running session reached at ADDRESS, or nil.
NAME, when given, is what the CLI called that session, and has to be
its name still: a message read back from a recording names a process
that may be long gone, and its id handed to another session since."
  (and (stringp address)
       (seq-find (lambda (entry)
                   (and (equal (ecc-peer-address entry) address)
                        (or (not (stringp name))
                            (equal (alist-get 'name entry) name))))
                 (ecc-registry-sessions))))

(defun ecc-peer-sender (peer)
  "Return PEER, a message from `ecc-protocol-peer-message\=', as a turn\='s sender.
That is its `from', `name' and `mode', and `session', the name the
session it came from has in this Emacs: found by session id through the
registry while its process still runs, and nil for one Emacs does not
run, or no longer can tell."
  (let* ((entry (ecc-peer--entry-at (alist-get 'from peer)
                                    (alist-get 'name peer)))
         (session (and entry (ecc-model-session (alist-get 'sessionId entry)))))
    (list (cons 'from (alist-get 'from peer))
          (cons 'name (alist-get 'name peer))
          (cons 'mode (alist-get 'mode peer))
          (cons 'session (and session (ecc-session-name session))))))

;;;; Who can be talked to

(defun ecc-peer--excluded-p (session)
  "Return non-nil when SESSION, of this Emacs, is nobody to talk to.
The usage probe and an inline question run a CLI of their own, and it
is in the registry like any other, but nobody is working in it."
  (or (ecc-model-option session :usage-probe nil)
      (ecc-model-option session :inline nil)))

(defun ecc-peer-candidates (&optional self)
  "Return the sessions a message can go to, as alists, for the session SELF.
They are the running sessions of the registry that take messages,
other than SELF, the usage probe and an inline question.  That leaves
out a session that has exited or is only being read from its recording
-- neither has a process -- and keeps one in a terminal or another
Emacs.

Each is an alist of `name', what the user calls it; `entry', what the
registry says; `session', the session of this Emacs behind it or nil;
and `address'.  The sessions of this Emacs come first, by their own
name, and the rest by the name the CLI gives them.  A name already
taken has the process id put after it, NAME<PID>, so that every name
stands for one session."
  (let ((self-id (and self (ecc-session-id self)))
        (taken (make-hash-table :test #'equal))
        own other)
    (dolist (entry (ecc-registry-sessions))
      (let* ((id (alist-get 'sessionId entry))
             (address (ecc-peer-address entry))
             (session (ecc-model-session id)))
        (when (and address
                   (not (equal id self-id))
                   (not (and session (ecc-peer--excluded-p session))))
          (let ((candidate (list (cons 'name (if session
                                                  (ecc-session-name session)
                                                (or (alist-get 'name entry) id)))
                                 (cons 'entry entry)
                                 (cons 'session session)
                                 (cons 'address address))))
            (if session (push candidate own) (push candidate other))))))
    (mapcar (lambda (candidate)
              (let ((name (alist-get 'name candidate)))
                (when (gethash name taken)
                  (setf (alist-get 'name candidate)
                        (format "%s<%s>" name
                                (alist-get 'pid (alist-get 'entry candidate)))))
                (puthash (alist-get 'name candidate) t taken)
                candidate))
            (append (nreverse own) (nreverse other)))))

(defun ecc-peer-resolve (name &optional self)
  "Return the candidate called NAME for the session SELF, or nil.
See `ecc-peer-candidates'; the address is the one its process has now."
  (seq-find (lambda (candidate) (equal (alist-get 'name candidate) name))
            (ecc-peer-candidates self)))

(defun ecc-peer-annotation (candidate)
  "Return what tells CANDIDATE apart from the others, for completion.
Where it works, what it is doing and whether it runs in this Emacs."
  (let* ((entry (alist-get 'entry candidate))
         (session (alist-get 'session candidate))
         (where (or (and session (ecc-session-project-root session))
                    (alist-get 'cwd entry))))
    (string-join
     (delq nil
           (list (and where (abbreviate-file-name (directory-file-name where)))
                 (ecc-registry-display-status (alist-get 'status entry))
                 (cond (session "here")
                       ((equal (alist-get 'entrypoint entry) "cli") "terminal")
                       (t "elsewhere"))))
     "  ")))

(defun ecc-peer--cli-name (candidate)
  "Return the name `ListAgents' gives CANDIDATE when it is not its own name."
  (let ((cli (alist-get 'name (alist-get 'entry candidate))))
    (and (stringp cli) (not (equal cli (alist-get 'name candidate)))
         cli)))

(defun ecc-peer-label (candidate)
  "Return the words a prompt names CANDIDATE with, for the model to act on."
  (let ((cli (ecc-peer--cli-name candidate)))
    (format "the Claude session `%s` (reach it with SendMessage to `%s`%s)"
            (alist-get 'name candidate)
            (alist-get 'address candidate)
            (if cli (format "; ListAgents lists it as `%s`" cli) ""))))

;;;; A session handed work by another

(defun ecc-peer-parent-paragraph (parent)
  "Return what a session started by PARENT is told about reaching it, or nil.
Nil when the registry has no socket for PARENT: a brief that names no
address is better than one that names a wrong one."
  (when-let* ((parent)
              (entry (ecc-registry-session (ecc-session-id parent)))
              (address (ecc-peer-address entry)))
    (let ((cli (alist-get 'name entry)))
      (concat
       (format "To report back to the session that handed this over, `%s`, \
use SendMessage to `%s`." (ecc-session-name parent) address)
       (when (stringp cli)
         (format "  That address belongs to the process it runs in \
now; if it stops working, find the session with ListAgents, which \
listed it as `%s` when you started." cli))))))

(provide 'ecc-peer)

;;; ecc-peer.el ends here
