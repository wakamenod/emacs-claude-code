;;; ecc-auth-test.el --- Tests for ecc-auth  -*- lexical-binding: t; -*-

;;; Commentary:

;; Signing in and out.  No CLI is started: `ecc-auth--run' is the only
;; place a subprocess comes from and is stood in for, and the terminal a
;; sign-in would open is stood in for too.  The JSON is what
;; `claude auth status --json' answered on 2.1.268.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-auth)
(require 'ecc-prompt)

(defconst ecc-auth-test--logged-in
  "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\
\"analyticsDisabled\":false,\"projectsDirectory\":\"/home/u/.claude/projects\",\
\"configDirectory\":\"/home/u/.claude\",\"email\":\"someone@example.com\",\
\"orgId\":\"3554dae6-db43-4b0d-8321-414c15c089ba\",\
\"orgName\":\"someone@example.com's Organization\",\"subscriptionType\":\"pro\"}\n"
  "What the CLI answers for an account that is signed in.")

(defconst ecc-auth-test--logged-out
  "{\"loggedIn\":false,\"authMethod\":\"none\",\"apiProvider\":\"firstParty\",\
\"analyticsDisabled\":false,\"projectsDirectory\":\"/home/u/.claude/projects\",\
\"configDirectory\":\"/home/u/.claude\"}\n"
  "What the CLI answers for an account that is not.
It exits 1 while printing this, which is why every stub here pairs it
with a 1.")

(defmacro ecc-auth-test-with-cli (answers &rest body)
  "Run BODY with `ecc-auth--run\\=' answering out of ANSWERS.
ANSWERS is an alist of the arguments, joined by a space, and the
\(EXIT . OUTPUT) to answer them with.  The calls that were made are left
in `calls\\=', newest last."
  (declare (indent 1) (debug (form body)))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'ecc-auth--run)
                (lambda (&rest args)
                  (setq calls (append calls (list args)))
                  (or (cdr (assoc (string-join args " ") ,answers))
                      (error "The test did not expect %S" args)))))
       ,@body)))

;;;; What the CLI says

(ert-deftest ecc-auth-test-status-is-parsed ()
  "The JSON of `auth status\\=' comes back as an alist."
  (ecc-auth-test-with-cli `(("auth status --json" . (0 . ,ecc-auth-test--logged-in)))
    (let ((status (ecc-auth-status)))
      (should (ecc-auth-logged-in-p status))
      (should (equal (alist-get 'email status) "someone@example.com"))
      (should (equal (alist-get 'subscriptionType status) "pro"))
      (should (equal calls '(("auth" "status" "--json")))))))

(ert-deftest ecc-auth-test-logged-out-is-parsed ()
  "A false `loggedIn\\=' is read as false and not as a symbol."
  (ecc-auth-test-with-cli `(("auth status --json" . (1 . ,ecc-auth-test--logged-out)))
    (let ((status (ecc-auth-status)))
      (should-not (ecc-auth-logged-in-p status))
      (should (equal (ecc-auth-status-string status) "not logged in")))))

(ert-deftest ecc-auth-test-a-nonzero-exit-is-not-an-error-by-itself ()
  "`auth status\\=' exits 1 when nobody is signed in, and says so in JSON.
Reading the exit code first made being signed out an error, which is the
one state the question is most often asked in."
  (ecc-auth-test-with-cli `(("auth status --json" . (1 . ,ecc-auth-test--logged-out)))
    (should-not (ecc-auth-logged-in-p (ecc-auth-status)))))

(ert-deftest ecc-auth-test-an-answer-that-is-no-json-is-an-error ()
  "A CLI that answers with something else is an error.
Nil would read as being signed out, which is a different thing and the
wrong thing to tell somebody.  So is JSON that answers another question."
  (ecc-auth-test-with-cli '(("auth status --json" . (0 . "command not found\n")))
    (should-error (ecc-auth-status)))
  (ecc-auth-test-with-cli '(("auth status --json" . (0 . "{\"error\":\"nope\"}\n")))
    (should-error (ecc-auth-status))))

(ert-deftest ecc-auth-test-status-string-names-the-account ()
  "The line says who is signed in and how."
  (ecc-auth-test-with-cli `(("auth status --json" . (0 . ,ecc-auth-test--logged-in)))
    (should (equal (ecc-auth-status-string)
                   "someone@example.com — claude.ai, pro"))))

;;;; Signing out

(ert-deftest ecc-auth-test-logout-asks-first ()
  "A no leaves the account alone, and the CLI is not run."
  (ecc-auth-test-with-cli `(("auth status --json" . (0 . ,ecc-auth-test--logged-in)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-error (ecc-auth-logout) :type 'user-error))
    (should (equal calls '(("auth" "status" "--json"))))))

(ert-deftest ecc-auth-test-logout-runs-the-subcommand ()
  "A yes runs `auth logout\\=' and then reports being signed out.
The second status is the one the CLI answers with a 1, which used to
turn a logout that had worked into an error."
  (let ((calls nil))
    (cl-letf (((symbol-function 'ecc-auth--run)
               (lambda (&rest args)
                 (setq calls (append calls (list args)))
                 (cond
                  ((equal args '("auth" "logout")) (cons 0 ""))
                  ;; Signed in until the logout, and not afterwards.
                  ((member '("auth" "logout") calls)
                   (cons 1 ecc-auth-test--logged-out))
                  (t (cons 0 ecc-auth-test--logged-in)))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (equal (ecc-auth-logout) "not logged in")))
    (should (equal calls '(("auth" "status" "--json")
                           ("auth" "logout")
                           ("auth" "status" "--json"))))))

(ert-deftest ecc-auth-test-logout-refuses-when-signed-out ()
  "Nothing to sign out of is a user error, not a subcommand."
  (ecc-auth-test-with-cli `(("auth status --json" . (1 . ,ecc-auth-test--logged-out)))
    (should-error (ecc-auth-logout) :type 'user-error)
    (should (equal calls '(("auth" "status" "--json"))))))

;;;; Signing in

(ert-deftest ecc-auth-test-login-arguments ()
  "An account becomes one flag, and no account becomes none."
  (should (equal (cdr (ecc-auth-login-arguments)) '("auth" "login")))
  (should (equal (cdr (ecc-auth-login-arguments "console"))
                 '("auth" "login" "--console")))
  (should (equal (cdr (ecc-auth-login-arguments "sso"))
                 '("auth" "login" "--sso")))
  (should (equal (car (ecc-auth-login-arguments)) ecc-executable))
  (should-error (ecc-auth-login-arguments "nonesuch") :type 'user-error))

(ert-deftest ecc-auth-test-login-starts-a-terminal ()
  "The sign-in is handed to a terminal, with the argv of the account."
  (let (started)
    (cl-letf (((symbol-function 'ecc-auth--start-terminal)
               (lambda (_buffer arguments)
                 (setq started arguments)
                 (start-process "ecc-auth-test" nil "sleep" "30")))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (unwind-protect
          (let ((process (ecc-auth-login "console")))
            (should (equal (cdr started) '("auth" "login" "--console")))
            (should (process-live-p process))
            (delete-process process))
        (when-let* ((buffer (get-buffer ecc-auth-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest ecc-auth-test-login-refuses-a-running-sign-in ()
  "A terminal that is still signing in is not taken away."
  (let ((buffer (get-buffer-create ecc-auth-buffer-name)))
    (unwind-protect
        (let ((process (start-process "ecc-auth-test" buffer "sleep" "30")))
          (unwind-protect
              (should-error (ecc-auth-login) :type 'user-error)
            (delete-process process)))
      (kill-buffer buffer))))

;;;; The running sessions afterwards

(ert-deftest ecc-auth-test-running-sessions-are-restarted ()
  "Every session still running on the old credentials is offered the new ones.
Two of them, because one would not say whether the list is walked."
  (ecc-test-with-fake-session first
    (let* ((second (ecc-model-create-session
                    :name "second" :project-root temporary-file-directory))
           (processes (list (start-process "ecc-auth-test-1" nil "sleep" "30")
                            (start-process "ecc-auth-test-2" nil "sleep" "30")))
           (restarted nil))
      (unwind-protect
          (progn
            (setf (ecc-session-process first) (nth 0 processes))
            (setf (ecc-session-process second) (nth 1 processes))
            (should (= 2 (length (ecc-auth-running-sessions))))
            (ecc-auth-test-with-cli
                `(("auth status --json" . (0 . ,ecc-auth-test--logged-in)))
              (cl-letf (((symbol-function 'ecc-auth-restart-session)
                         (lambda (session) (push session restarted)))
                        ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                (let ((ecc-auth-restart-sessions 'ask))
                  (ecc-auth--after-login))))
            (should (= 2 (length restarted)))
            (should (memq first restarted))
            (should (memq second restarted)))
        (mapc #'delete-process processes)))))

(ert-deftest ecc-auth-test-nil-leaves-the-sessions-alone ()
  "`ecc-auth-restart-sessions\\=' nil asks nothing and restarts nothing."
  (ecc-test-with-fake-session session
    (let ((process (start-process "ecc-auth-test" nil "sleep" "30"))
          (restarted nil))
      (unwind-protect
          (progn
            (setf (ecc-session-process session) process)
            (ecc-auth-test-with-cli
                `(("auth status --json" . (0 . ,ecc-auth-test--logged-in)))
              (cl-letf (((symbol-function 'ecc-auth-restart-session)
                         (lambda (s) (push s restarted)))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) (error "Should not have asked"))))
                (let ((ecc-auth-restart-sessions nil))
                  (ecc-auth--after-login))))
            (should-not restarted))
        (delete-process process)))))

(ert-deftest ecc-auth-test-a-failed-sign-in-restarts-nothing ()
  "Nothing is restarted when the sign-in left the CLI signed out."
  (ecc-test-with-fake-session session
    (let ((process (start-process "ecc-auth-test" nil "sleep" "30"))
          (restarted nil))
      (unwind-protect
          (progn
            (setf (ecc-session-process session) process)
            (ecc-auth-test-with-cli
                `(("auth status --json" . (1 . ,ecc-auth-test--logged-out)))
              (cl-letf (((symbol-function 'ecc-auth-restart-session)
                         (lambda (s) (push s restarted)))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) (error "Should not have asked"))))
                (let ((ecc-auth-restart-sessions t))
                  (ecc-auth--after-login))))
            (should-not restarted))
        (delete-process process)))))

;;;; The way in

(ert-deftest ecc-auth-test-intercept-takes-the-three ()
  "The three are answered here and nothing of them reaches the CLI."
  (ecc-test-with-fake-session session
    (let (calls)
      (cl-letf (((symbol-function 'ecc-auth-login)
                 (lambda (&optional account) (push (cons 'login account) calls)))
                ((symbol-function 'ecc-auth-logout)
                 (lambda () (push '(logout) calls)))
                ((symbol-function 'ecc-auth-show-status)
                 (lambda (&optional _full) (push '(status) calls))))
        (should (ecc-auth-intercept session "/login"))
        (should (ecc-auth-intercept session "/login console"))
        (should (ecc-auth-intercept session "/logout"))
        (should (ecc-auth-intercept session "/auth-status"))
        (should (equal (reverse calls)
                       '((login . nil) (login . "console") (logout) (status)))))
      ;; A command the CLI answers, and a plain sentence, are left alone.
      (should-not (ecc-auth-intercept session "/model opus"))
      (should-not (ecc-auth-intercept session "log me in")))))

(ert-deftest ecc-auth-test-the-three-are-offered ()
  "They are in the command list of a session, and no menu hides them."
  (ecc-test-with-fake-session session
    (let ((commands (ecc-prompt-commands session))
          (offered (mapcar #'car (ecc-prompt-offered-commands session))))
      (dolist (name '("/login" "/logout" "/auth-status"))
        (should (assoc name commands))
        (should (member name offered))))))

(provide 'ecc-auth-test)

;;; ecc-auth-test.el ends here
