;;; ecc-jev.el --- What a finished turn meant, in the sidebar  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
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

;; The CLI says whether a session is running.  It never says what the
;; session meant by stopping: a turn that finished the job and a turn
;; that stopped to ask a question both arrive as `idle', and with four
;; sessions on the screen the one thing worth knowing is which of the
;; idle ones is waiting for you.
;;
;; Jev (https://docs.typesafe.ai/, the jev.el client) answers exactly
;; that kind of question: unstructured state in, a typed value and a
;; calibrated confidence out, in one round trip.  So when a turn
;; finishes, the last thing Claude said is sent with two questions --
;; what became of the turn, and whether it ends by asking the user
;; something -- and the answer becomes the mark that opens the
;; session's row in the sidebar.
;;
;; What it does not do is decide anything.  It annotates one column of
;; one row: no notification, no permission, no tab-line state.  A Jev
;; that is down, out of credit or slow is invisible -- the row keeps
;; the mark it has today and the failure goes to the session log.
;;
;; jev.el is not a dependency of this package.  It is required at run
;; time, by the one function that asks, and everything else here -- the
;; verdicts, the marks, the staleness rule -- is plain Lisp that works
;; and is tested without it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-notify)
(require 'ecc-sidebar)

(declare-function jev-ask "jev" (state questions &rest keys))
(declare-function jev-cancel "jev" (request))
(declare-function jev-choice "jev" (prompt options))
(declare-function jev-noul "jev" (prompt))
(declare-function jev-value "jev" (reply key))
(declare-function jev-confidence "jev" (reply key))
(declare-function jev-true-p "jev" (reply key &optional threshold))

;;;; Settings

(defcustom ecc-jev-enabled nil
  "Non-nil to have Jev say what each finished turn meant.
The mark that opens a session's row in the sidebar then says whether
an idle session is waiting on a decision, is blocked, or stopped part
way -- which is the one thing the CLI never reports.

It is off by default because turning it on has a price on both counts
a setting here is meant to weigh.  It sends the last assistant message
of every finished turn to TypeSafe AI (api.typesafe.ai, or the Vercel
gateway when jev.el is pointed at it), so whatever Claude just wrote
about your code leaves this machine for a second service; and every
turn is a request that is charged for.  It also needs jev.el, which
this package does not depend on."
  :type 'boolean
  :group 'ecc)

(defvar ecc-jev-confidence-threshold 0.6
  "Confidence a verdict must reach before it is allowed to draw a mark.
Below it the row keeps the mark it would have had.  The number is still
a guess, but no longer an uninformed one: the eight turns of
demo/scenes/jev-verdicts.el came back at 1.0, 1.0, 1.0, 0.89, 0.85,
0.47 and 0.43 (typesafe, 2026-09-19).  A verdict is either near
certain or near the middle, and what the middle means is real: the 0.47
was a turn that was blocked and ended by offering a way on, which is
half of each.  Lowering this would put a mark on exactly those.")

(defvar ecc-jev-marks
  '((needs-decision . "?")
    (blocked . "!")
    (partial . "…"))
  "The mark each verdict draws, keyed by verdict.
`done' is deliberately absent, and so is anything Jev sends that is not
in this table: a mark that appeared on every finished turn would say
nothing, and the row falls back to the ordinary one.")

(defvar ecc-jev-text-limit 4000
  "How many characters of the last assistant message are sent, at most.
Jev takes 32k tokens of state, and a last message is normally far
smaller, so this cuts nothing in the ordinary case.  What is kept is
the tail: a message that ends by asking something ends with the
question.")

(defvar ecc-jev-verdict-question
  '(("done" . "The work asked for is finished and nothing is wanted from the user")
    ("needs-decision" . "It stopped to ask the user something, or to have them choose")
    ("blocked" . "It could not go on: something failed, was missing or was refused")
    ("partial" . "It did some of the work and stopped short of the rest"))
  "The options of the choice Jev is asked about a finished turn.")

(defvar ecc-jev-loud-errors
  '(jev-configuration-error jev-auth-error jev-billing-error)
  "Failures said once in the echo area as well as logged.
These are the ones nobody can fix from here and nothing will fix by
itself: no API key, a key that is refused, an account out of credit.
Everything else -- a rate limit, a timeout, a provider having a bad
minute -- passes and belongs in the log alone.")

;;;; What is known, per session

(defvar ecc-jev--verdicts (make-hash-table :test #'equal)
  "Verdicts by session id, each (VERDICT . CONFIDENCE) for its last turn.")

(defvar ecc-jev--requests (make-hash-table :test #'equal)
  "The Jev request in flight for a session id, by session id.")

(defvar ecc-jev--reported nil
  "Non-nil once a failure worth saying out loud has been said.
It is said once rather than after every turn, and the next answer that
arrives clears it: a key put right must not leave a warning that
cannot come back.")

(defun ecc-jev--forget (session)
  "Drop what is known about SESSION, and stop anything asked about it."
  (let ((id (ecc-session-id session)))
    (when-let* ((request (gethash id ecc-jev--requests)))
      (remhash id ecc-jev--requests)
      (when (fboundp 'jev-cancel)
        (jev-cancel request)))
    (remhash id ecc-jev--verdicts)))

(defun ecc-jev-verdict (session)
  "Return the verdict recorded for SESSION as (VERDICT . CONFIDENCE), or nil."
  (gethash (ecc-session-id session) ecc-jev--verdicts))

(defun ecc-jev--verdict-of (choice confidence asking)
  "Return (VERDICT . CONFIDENCE) for CHOICE at CONFIDENCE, given ASKING.
CHOICE is what Jev picked, as a symbol or a string; ASKING is the
probability the noul came back with, which for a noul is the answer
itself.  A turn that calls itself done and still ends in a question is
waiting on the user, and the question is the more reliable of the two:
it is about the text, not about the work.

The confidence returned belongs to whichever question decided it.  A
`done\=' believed at 0.95 and overturned by an `asking\=' of 0.51 is a
0.51 verdict, and drawing it under the confidence of the answer that
lost would put a mark on the row that nothing supports."
  (let ((choice (if (stringp choice) (intern choice) choice))
        (asking (if (numberp asking) asking (if asking 1.0 0.0))))
    (if (and (> asking 0.5) (memq choice '(done partial)))
        (cons 'needs-decision asking)
      (cons choice confidence))))

(defun ecc-jev-mark-of (verdict confidence)
  "Return the mark VERDICT draws at CONFIDENCE, or nil for the ordinary one.
Nil is returned for a verdict below `ecc-jev-confidence-threshold\\=',
for `done\\=', and for anything `ecc-jev-marks\\=' does not name."
  (and verdict
       (numberp confidence)
       (>= confidence ecc-jev-confidence-threshold)
       (alist-get verdict ecc-jev-marks)))

(defun ecc-jev-note-verdict (session turn verdict confidence)
  "Record that TURN of SESSION meant VERDICT, believed at CONFIDENCE.
The answer is dropped unless it is still about the session in front of
the user: Jev takes a few hundred milliseconds, and in that time the
session can have been forgotten, started another turn or gone back to
running.  Returns non-nil when the verdict was kept."
  (when (ecc-jev--current-p session turn)
    (puthash (ecc-session-id session) (cons verdict confidence) ecc-jev--verdicts)
    t))

(defun ecc-jev--current-p (session turn)
  "Return non-nil when TURN is still what SESSION last did, and it is idle."
  (and (ecc-model-session (ecc-session-id session))
       (eq (ecc-tab-state session) 'idle)
       (eq turn (car (last (ecc-session-turns session))))))

;;;; The mark

(defun ecc-jev-sidebar-mark (session mark)
  "Return the mark SESSION opens its sidebar row with, given MARK.
Only a session that has stopped is spoken about, so the spinner of a
running one is handed back untouched."
  (or (and ecc-jev-enabled
           (eq (ecc-tab-state session) 'idle)
           (let ((verdict (ecc-jev-verdict session)))
             (ecc-jev-mark-of (car verdict) (cdr verdict))))
      mark))

;;;; Asking

(defun ecc-jev--said-p (node)
  "Return non-nil when NODE is something the model said in its own words.
A slash command the CLI answers itself -- `/cost\=', `/status\=' -- comes
back as an assistant message like any other, marked `synthetic\=' by
`ecc-dispatch\=' from the model name \"<synthetic>\" the CLI puts on it.
Sending a table of token counts to Jev costs money to be told nothing,
and a healthy session would wear the mark of whatever it made of it
\(2026-09-19)."
  (and (eq (ecc-node-type node) 'text)
       (not (ecc-model-node-get node 'synthetic))))

(defun ecc-jev--turn-text (turn)
  "Return the last thing said in TURN, cut to `ecc-jev-text-limit\\=', or nil.
The tail is what is kept: the end of a message is where it says what
it wants."
  (when-let* ((node (seq-find #'ecc-jev--said-p
                              (reverse (ecc-model-node-children turn))))
              (text (ecc-model-node-get node 'text))
              (text (string-trim text)))
    ;; A binding of `_' in `when-let*' is an error on Emacs 29, where
    ;; the byte compiler reads the underscore as a promise that the
    ;; variable is unused (CI, 2026-09-19), so the last condition is a
    ;; body of its own.
    (unless (string-empty-p text)
      (if (> (length text) ecc-jev-text-limit)
          (substring text (- (length text) ecc-jev-text-limit))
        text))))

(defun ecc-jev--questions ()
  "Return the questions asked about a finished turn.
Built by hand rather than with `jev-questions\\=', which is a macro and
so would want jev.el at compile time -- and this file compiles on a
machine that has never heard of it (2026-09-19)."
  (list (cons 'verdict
              (jev-choice "What became of this turn of work?"
                          ecc-jev-verdict-question))
        (cons 'asking
              (jev-noul "Does the message end by asking the user something?"))))

(defun ecc-jev--answered ()
  "Note that Jev answered, so that a later failure is said out loud again."
  (setq ecc-jev--reported nil))

(defun ecc-jev--succeeded (reply session turn)
  "Take REPLY apart into the verdict of TURN in SESSION, and draw it.
`jev-value\=' and its neighbours signal `jev-response-error\=' for an
answer that is missing or of the wrong type, and a provider that leaves
a question out is not checked for anywhere else.  jev.el does not wrap
the success callback -- an error raised there is the caller\='s own and
travels on -- and in the asynchronous path that is url.el\='s callback,
where nobody is listening and this module\='s own logging is never
reached.  So the reply is read inside a handler (jev.el read
2026-09-19)."
  (ecc-jev--answered)
  (condition-case caught
      (let ((verdict (ecc-jev--verdict-of (jev-value reply 'verdict)
                                          (jev-confidence reply 'verdict)
                                          (jev-value reply 'asking))))
        (when (ecc-jev-note-verdict session turn (car verdict) (cdr verdict))
          (ecc-sidebar-redraw)))
    (error (ecc-jev--failed caught session))))

(defun ecc-jev--loud-p (error)
  "Return non-nil when ERROR is one `ecc-jev-loud-errors\=' names.
A jev.el error object is an ordinary condition, (SYMBOL MESSAGE . PROPS).
The symbol itself is matched first and its family second: the family
lives in the `error-conditions\=' that jev.el puts on the symbol with
`define-error\=', so it is there only once the package is loaded, and the
symbol alone has to be enough without it (2026-09-19)."
  (and (consp error)
       (symbolp (car error))
       (or (memq (car error) ecc-jev-loud-errors)
           (seq-intersection (get (car error) 'error-conditions)
                             ecc-jev-loud-errors)
           nil)))

(defun ecc-jev--error-text (error)
  "Return what ERROR says.
A jev.el error object is an ordinary condition, (SYMBOL MESSAGE . PROPS),
and this reads the message out of one without `jev-error-message\=' --
which would need the package loaded, and a failure is exactly where it
may not be (2026-09-19)."
  (cond ((and (consp error) (stringp (cadr error))) (cadr error))
        ((stringp error) error)
        (t (format "%s" error))))

(defun ecc-jev--report (session text)
  "Log TEXT against SESSION, and say it once where a person will see it."
  (ecc-log (ecc-session-name session) "jev: %s" text)
  (unless ecc-jev--reported
    (setq ecc-jev--reported t)
    (message "ecc-jev: %s.  The sidebar marks stay as they are" text)))

(defun ecc-jev--failed (error session)
  "Log ERROR against SESSION and leave the sidebar alone.
A Jev that is down, rate-limited or out of credit must cost a session
nothing: the row keeps the mark it already has, and the failure is
here to be found.

The exception is a failure nobody can fix from here and nothing will
fix by itself -- no API key above all, which is where a first run ends
up -- and that one is also said once in the echo area, because a
setting switched on and answering with silence is worse than the
setting being off."
  (let ((text (ecc-jev--error-text error)))
    (if (ecc-jev--loud-p error)
        (ecc-jev--report session text)
      (ecc-log (ecc-session-name session) "jev: %s" text))))

(defun ecc-jev--ask (session turn)
  "Send the last thing said in TURN of SESSION to Jev."
  (ecc-jev--forget session)
  (when-let* ((text (ecc-jev--turn-text turn)))
    (if (not (require 'jev nil t))
        (ecc-jev--report session
                         "`ecc-jev-enabled' is on but jev.el is not installed")
      (let* ((id (ecc-session-id session))
             (settled nil)
             (done (lambda ()
                     (setq settled t)
                     (remhash id ecc-jev--requests)))
             (request
              ;; The tag carries the session and the turn across the
              ;; round trip, which is jev.el's own advice for an
              ;; answer that lands in a world that has moved on.
              (jev-ask text (ecc-jev--questions)
                       :tag (cons id (ecc-turn-id turn))
                       :success (lambda (reply _tag)
                                  (funcall done)
                                  (ecc-jev--succeeded reply session turn))
                       :error (lambda (error _tag)
                                (funcall done)
                                (ecc-jev--failed error session)))))
        ;; A transport that answers inside the call above has run the
        ;; callback already, and the handle it hands back is of a
        ;; request that is over: storing it would leave a finished
        ;; request to be cancelled by the next turn, and this session
        ;; holding a handle for ever (2026-09-19).
        (unless settled
          (puthash id request ecc-jev--requests))))))

(defun ecc-jev-turn-finished (session turn)
  "Ask Jev what TURN of SESSION meant, when that is switched on.
Nothing that goes wrong here may reach the rest of
`ecc-turn-finished-hook\=': `add-hook\=' puts this first, and the
notification, the end of the transcript and the two redraws come after
it.  `require\=' with NOERROR is no cover either -- it stops a missing
file, not an error raised while one loads.  The failure is logged
rather than dropped."
  (when (and ecc-jev-enabled (not (ecc-turn-transient turn)))
    (condition-case caught
        (ecc-jev--ask session turn)
      (error (ecc-jev--failed caught session)))))

(defun ecc-jev-turn-started (session _turn)
  "Forget what SESSION last meant: it is saying something else now."
  (ecc-jev--forget session))

(defun ecc-jev-session-removed (session)
  "Forget SESSION, which is gone."
  (ecc-jev--forget session))

(add-hook 'ecc-turn-finished-hook #'ecc-jev-turn-finished)
(add-hook 'ecc-turn-started-hook #'ecc-jev-turn-started)
(add-hook 'ecc-session-removed-hook #'ecc-jev-session-removed)
(add-hook 'ecc-sidebar-mark-functions #'ecc-jev-sidebar-mark)

(provide 'ecc-jev)

;;; ecc-jev.el ends here
