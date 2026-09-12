;;; ecc-auth.el --- Signing in and out, from the prompt region  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The `/login', `/logout' and `/status' of the terminal client.
;;
;; They are not slash commands.  The CLI names neither `login' nor
;; `logout' in `commands' or in `slash_commands', and does not name them
;; in `terminal_slash_commands' either -- that list is `doctor', `color'
;; and `reload-plugins' (measured against 2.1.268, 2026-09-12).  Like
;; `/btw', the terminal client catches them in its own input layer, so a
;; headless client is told nothing about them and `/login' typed into a
;; prompt would go to the model as a sentence.
;;
;; What the CLI does offer a program is subcommands (2.1.268):
;;
;;     claude auth login [--claudeai | --console] [--sso] [--email <e>]
;;     claude auth logout
;;     claude auth status --json
;;
;; So Emacs answers the three itself, through
;; `ecc-prompt-intercept-functions'.  Signing out and asking who is
;; signed in are one subprocess each and are done here.  Signing in is
;; an OAuth handshake with screens of its own, and Emacs does not try to
;; reproduce it: `ecc-auth-login' hands the flow to a terminal and lets
;; the CLI draw it, the choice of account included.
;;
;; Credentials are read when the CLI starts, so a session that was
;; already running keeps the ones it started with.  The sentinel on the
;; terminal offers to restart them once the sign-in is over.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)

(declare-function ecc-prompt-command-name "ecc-prompt" (text))
(declare-function ecc-prompt-command-argument "ecc-prompt" (text))
(declare-function ecc-resume "ecc" (session &optional fork))
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function make-term "term" (name program &optional startfile &rest switches))

;;;; Options

(defvar ecc-auth-restart-sessions 'ask
  "What becomes of the running sessions once a sign-in is over.
The CLI reads its credentials when it starts, so a session that was
already running carries on with the ones it started with, whoever has
signed in since.  `ask' offers to restart them, nil leaves them alone
without a word, and t restarts them without asking.  A restart is
`ecc-proc-stop' and then `ecc-resume', so the conversation is read back
out of its recording and nothing of the transcript is lost.")

(defvar ecc-auth-accounts
  '(("claudeai" . "--claudeai")
    ("console" . "--console")
    ("sso" . "--sso"))
  "The accounts `/login' takes as an argument, and the flag each passes.
Without an argument no flag is passed at all and the CLI asks, which is
the ordinary way in.  `--claudeai' is the CLI\\='s own default.")

(defconst ecc-auth-login-command "/login"
  "The word that starts a sign-in.")

(defconst ecc-auth-logout-command "/logout"
  "The word that signs out.")

(defconst ecc-auth-status-command "/auth-status"
  "The word that asks who is signed in.
The terminal client calls this `/status\\=', but that name is taken
here: the CLI names a `/status\\=' of its own in `slash_commands', and
shadowing a command the CLI answers would cost one.")

(defconst ecc-auth-buffer-name "*ecc auth login*"
  "The terminal buffer a sign-in runs in.")

;;;; Asking the CLI

(defun ecc-auth--run (&rest args)
  "Run the CLI with ARGS and return (EXIT . OUTPUT).
The one place a subprocess is started from, so that a test can stand in
for it."
  (with-temp-buffer
    (let ((exit (apply #'call-process ecc-executable nil t nil args)))
      (cons exit (buffer-string)))))

(defun ecc-auth-status ()
  "Return what the CLI says about the account, as an alist.
The keys are those of `claude auth status --json\\=': `loggedIn\\=',
`authMethod\\=', `email\\=', `subscriptionType\\=' and the rest.

The answer is taken from the JSON and not from the exit code: `auth
status\\=' exits 1 when nobody is signed in, and prints the same JSON
saying so (confirmed against 2.1.268, 2026-09-12).  Reading the exit
code first made being signed out an error, which is the one state the
question is most often asked in.  A CLI that answers with something
other than JSON is still an error rather than a nil, which would read
as being signed out and is a different thing."
  (pcase-let ((`(,exit . ,output) (ecc-auth--run "auth" "status" "--json")))
    (condition-case error
        (let ((status (ecc--json-read output)))
          (unless (assq 'loggedIn status)
            (signal 'error (list "no loggedIn in the answer")))
          status)
      (error
       (error "%s auth status failed (%s): %s (%s)" ecc-executable exit
              (string-trim output) (error-message-string error))))))

(defun ecc-auth-logged-in-p (&optional status)
  "Return non-nil when STATUS, or the CLI, says somebody is signed in."
  (ecc--json-true-p (alist-get 'loggedIn (or status (ecc-auth-status)))))

(defun ecc-auth-status-string (&optional status)
  "Return a line saying who STATUS, or the CLI, is signed in as."
  (let ((status (or status (ecc-auth-status))))
    (if (not (ecc-auth-logged-in-p status))
        "not logged in"
      (let ((email (alist-get 'email status))
            (method (alist-get 'authMethod status))
            (plan (alist-get 'subscriptionType status))
            (org (alist-get 'orgName status)))
        (string-join
         (delq nil (list (or email org "logged in")
                         (string-join (delq nil (list method plan)) ", ")))
         " — ")))))

;;;###autoload
(defun ecc-auth-show-status (&optional full)
  "Say who the CLI is signed in as.
With FULL, or a prefix argument, show everything it answered in a
buffer instead of the line in the echo area."
  (interactive "P")
  (let ((status (ecc-auth-status)))
    (if (not full)
        (message "%s" (ecc-auth-status-string status))
      (let ((buffer (get-buffer-create "*ecc auth*")))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (ecc-auth-status-string status) "\n\n")
            (pcase-dolist (`(,key . ,value) status)
              (insert (format "%-20s %s\n" key
                              (if (stringp value) value (format "%S" value))))))
          (goto-char (point-min))
          (special-mode))
        (pop-to-buffer buffer)))
    status))

;;;###autoload
(defun ecc-auth-logout ()
  "Sign the CLI out, after asking.
Every session started afterwards would have nothing to authenticate
with, so the account being left is named in the question."
  (interactive)
  (let ((status (ecc-auth-status)))
    (unless (ecc-auth-logged-in-p status)
      (user-error "Not logged in"))
    (unless (yes-or-no-p (format "Log out of %s? " (ecc-auth-status-string status)))
      (user-error "Left signed in"))
    (pcase-let ((`(,exit . ,output) (ecc-auth--run "auth" "logout")))
      (unless (eq exit 0)
        (error "%s auth logout failed (%s): %s" ecc-executable exit
               (string-trim output))))
    (message "%s" (ecc-auth-status-string))))

;;;; Signing in, in a terminal

(defun ecc-auth-login-arguments (&optional account)
  "Return the argv of a sign-in as ACCOUNT.
ACCOUNT is a key of `ecc-auth-accounts\\=', or nil for no flag at all,
which leaves the CLI to ask."
  (append (list ecc-executable "auth" "login")
          (when account
            (list (or (cdr (assoc account ecc-auth-accounts))
                      (user-error "No such account as %s; try %s" account
                                  (string-join (mapcar #'car ecc-auth-accounts)
                                               ", ")))))))

(defun ecc-auth--start-terminal (buffer arguments)
  "Run ARGUMENTS in BUFFER as a terminal and return the process.
ghostel draws the CLI\\='s screens with the engine Ghostty uses and is
what `ecc-tui\\=' hands a session to, so it is preferred here too; a
machine without it falls back to the `term\\=' that comes with Emacs,
which is enough for a sign-in."
  (if (and (require 'ghostel nil t) (fboundp 'ghostel-exec))
      (ghostel-exec buffer (car arguments) (cdr arguments))
    (require 'term)
    ;; `make-term' takes the name without the stars and gets the buffer
    ;; of that name, which is the one already made here.
    (get-buffer-process
     (apply #'make-term (string-trim (buffer-name buffer) "\\*" "\\*")
            (car arguments) nil (cdr arguments)))))

;;;###autoload
(defun ecc-auth-login (&optional account)
  "Sign in to the CLI, in a terminal of its own.
ACCOUNT is a key of `ecc-auth-accounts\\=' -- \"claudeai\", \"console\"
or \"sso\" -- and with none the CLI asks, which is the ordinary way in.

The handshake is the CLI\\='s: it opens a browser and reads what comes
back, and the terminal is where it draws that.  Emacs only starts it,
and asks afterwards about the sessions that are still running on the
credentials they started with (`ecc-auth-restart-sessions\\=')."
  (interactive
   (list (when current-prefix-arg
           (completing-read "Account: " (mapcar #'car ecc-auth-accounts)
                            nil t))))
  (let* ((arguments (ecc-auth-login-arguments account))
         (stale (get-buffer ecc-auth-buffer-name)))
    ;; The same three rules `ecc-tui--open-ghostel' goes by: a buffer
    ;; left over from a sign-in that is over is reused, one that still
    ;; runs something is not touched, and the buffer is shown before the
    ;; CLI starts so that the terminal is sized to the window.
    (when (buffer-live-p stale)
      (when (process-live-p (get-buffer-process stale))
        (user-error "A sign-in is already running in %s" ecc-auth-buffer-name))
      (kill-buffer stale))
    (let ((buffer (get-buffer-create ecc-auth-buffer-name)))
      (with-current-buffer buffer
        (setq default-directory (expand-file-name "~/")))
      (pop-to-buffer buffer)
      (let ((process (ecc-auth--start-terminal buffer arguments)))
        (unless process
          (error "No terminal started for %s"
                 (mapconcat #'shell-quote-argument arguments " ")))
        (ecc-auth--watch process)
        process))))

(defun ecc-auth--watch (process)
  "Have `ecc-auth--after-login\\=' run once PROCESS is gone."
  (let ((previous (process-sentinel process)))
    (set-process-sentinel
     process
     (lambda (process event)
       (when previous (funcall previous process event))
       (unless (process-live-p process)
         (ecc-auth--after-login))))))

(defun ecc-auth-running-sessions ()
  "Return the sessions whose CLI is running."
  (seq-filter (lambda (session) (process-live-p (ecc-session-process session)))
              (ecc-model-sessions)))

(defun ecc-auth-restart-session (session)
  "Stop the CLI of SESSION and start it again on the current credentials.
`ecc-resume\\=' reads the recording back, so the transcript survives."
  (ecc-proc-stop session)
  (require 'ecc)
  (ecc-resume session))

(defun ecc-auth--after-login ()
  "Report the account, and offer the running sessions the new credentials."
  (let ((status (ignore-errors (ecc-auth-status))))
    (message "%s" (if status (ecc-auth-status-string status) "sign-in ended"))
    (when (and status (ecc-auth-logged-in-p status) ecc-auth-restart-sessions)
      (let ((running (ecc-auth-running-sessions)))
        (when (and running
                   (or (eq ecc-auth-restart-sessions t)
                       (yes-or-no-p
                        (format "%d session%s running on the old credentials; restart? "
                                (length running)
                                (if (= 1 (length running)) " is" "s are")))))
          (dolist (session running)
            (ecc-auth-restart-session session))
          (message "Restarted %d session%s" (length running)
                   (if (= 1 (length running)) "" "s")))))))

;;;; The way in: the prompt region

(defun ecc-auth-intercept (_session text)
  "Answer TEXT here when it is one of the commands the CLI does not name.
Returns non-nil when it did, which is what keeps the draft from being
sent as a prompt.  This is on `ecc-prompt-intercept-functions\\='."
  (let ((command (ecc-prompt-command-name text)))
    (cond
     ((equal command ecc-auth-login-command)
      (let ((argument (ecc-prompt-command-argument text)))
        (ecc-auth-login (unless (or (null argument) (string-empty-p argument))
                          argument)))
      t)
     ((equal command ecc-auth-logout-command)
      (ecc-auth-logout)
      t)
     ((equal command ecc-auth-status-command)
      (ecc-auth-show-status)
      t))))

(with-eval-after-load 'ecc-prompt
  (add-hook 'ecc-prompt-intercept-functions #'ecc-auth-intercept))

(provide 'ecc-auth)

;;; ecc-auth.el ends here
