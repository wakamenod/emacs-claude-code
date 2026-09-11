;;; ecc-transient-test.el --- Tests for ecc-transient  -*- lexical-binding: t; -*-

;;; Commentary:

;; The menu itself cannot be driven in batch, but what it is built from
;; can: the slash command submenu comes from the initialize answer of
;; the session at hand.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-transient)
(require 'ecc-answer)

(ert-deftest ecc-transient-test-menu-is-a-command ()
  "Every menu is reachable with \\[execute-extended-command]."
  (should (commandp 'ecc-menu))
  (should (commandp 'ecc-slash-menu))
  (should (commandp 'ecc-slash-command))
  (should (commandp 'ecc-customize)))

(defun ecc-transient-test--menu-keys ()
  "Return an alist of the key and command of every suffix of `ecc-menu'."
  (let (out)
    (letrec ((walk
              (lambda (node)
                (cond ((vectorp node) (mapc walk (append node nil)))
                      ((and (consp node) (plist-member (cdr node) :key))
                       (push (cons (plist-get (cdr node) :key)
                                   (plist-get (cdr node) :command))
                             out))
                      ((consp node)
                       (mapc (lambda (x)
                               (when (or (vectorp x) (consp x)) (funcall walk x)))
                             node))))))
      (funcall walk (get 'ecc-menu 'transient--layout)))
    (nreverse out)))

(ert-deftest ecc-transient-test-menu-keys-are-unique ()
  "A key opens one command in the menu."
  (let ((keys (mapcar #'car (ecc-transient-test--menu-keys))))
    (should (equal keys (seq-uniq keys)))))

(ert-deftest ecc-transient-test-menu-mirrors-the-global-map ()
  "Every key of `ecc-global-map' runs the same command in `ecc-menu'.
One letter carries one meaning wherever it is pressed, so a command
reachable both ways is reachable by the same key both ways.  `?' is the
exception: it opens the menu, so the menu cannot hold it."
  (let ((menu (ecc-transient-test--menu-keys)))
    (map-keymap
     (lambda (event command)
       (let ((key (key-description (vector event))))
         (unless (eq command 'ecc-menu)
           (should (eq command (cdr (assoc key menu)))))))
     ecc-global-map)))

(ert-deftest ecc-transient-test-slash-suffixes ()
  "The submenu is built from the commands of the session."
  (ecc-test-with-fake-session session
    (setf (ecc-session-commands session)
          [((name . "context") (description . "Show context usage") (argumentHint . ""))
           ((name . "doctor") (description . "Check the installation") (argumentHint . ""))])
    (setf (ecc-session-init session)
          '((slash_commands . ["context" "doctor"])
            (terminal_slash_commands . ["doctor"])))
    (let* ((suffixes (ecc-transient-slash-suffixes session))
           (keys (mapcar #'car suffixes))
           (descriptions (mapcar #'cadr suffixes)))
      ;; The two of the session, and the /btw Emacs answers itself: it
      ;; is in no list the CLI sends.
      (should (= (length suffixes) 3))
      (should (string-search "/btw" (nth 2 descriptions)))
      ;; A key is handed out once.
      (should (equal keys (seq-uniq keys)))
      (should (string-search "/context" (nth 0 descriptions)))
      (should (string-search "Show context usage" (nth 0 descriptions)))
      ;; What the terminal client alone can run is marked.
      (should (string-search "[terminal UI]" (nth 1 descriptions)))
      (should-not (string-search "terminal UI" (nth 0 descriptions)))
      (dolist (suffix suffixes)
        (should (commandp (nth 2 suffix)))))
    ;; Hidden unless kept: the menu shows what the completion shows.
    (let* ((ecc-prompt-kept-terminal-commands nil)
           (descriptions (mapcar #'cadr (ecc-transient-slash-suffixes session))))
      (should-not (seq-some (lambda (d) (string-search "/doctor" d)) descriptions))
      (should (seq-some (lambda (d) (string-search "/context" d)) descriptions)))))

(ert-deftest ecc-transient-test-slash-command-sends ()
  "Picking a slash command sends it to the session at hand."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      (funcall (ecc-transient-slash-command "/context"))
      (should (equal (ecc-test-sent-text 0) "/context"))
      (should (eq session (car (ecc-model-sessions))))
      ;; The same command comes back, so the menu keeps its suffix.
      (should (eq (ecc-transient-slash-command "/context")
                  (ecc-transient-slash-command "/context"))))))

(ert-deftest ecc-transient-test-interactive-slash-command-asks ()
  "A command that opens a menu in the terminal is asked about."
  (ecc-test-with-fake-session _session
    (with-temp-buffer
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "opus")))
        (funcall (ecc-transient-slash-command "/model")))
      (should (equal (ecc-test-sent-text 0) "/model opus")))))

(ert-deftest ecc-transient-test-set-model ()
  "Changing the model is a slash command, not a restart."
  (ecc-test-with-fake-session _session
    (with-temp-buffer
      (ecc-set-model "haiku")
      (should (equal (ecc-test-sent-text 0) "/model haiku")))))

(ert-deftest ecc-transient-test-remote-control-toggle ()
  "Turning the bridge on by hand asks, and says why when it cannot.
The temporary directory of the fake session stands in for a workspace
Remote Control was never trusted with."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      ;; The CLI has not said it can offer it.
      (should-error (ecc-remote-control-toggle) :type 'user-error)
      (ecc-model-set-remote-control session 'available t)
      ;; It can, but not for this workspace.
      (should-error (ecc-remote-control-toggle) :type 'user-error)
      (setf (ecc-session-project-root session) ecc-test-directory)
      (ecc-remote-control-toggle)
      (let ((request (alist-get 'request (car (ecc-test-sent-messages)))))
        (should (equal (alist-get 'subtype request) "remote_control"))
        (should (eq (alist-get 'enabled request) t)))
      ;; A second call turns it off again.
      (ecc-model-set-remote-control session 'enabled t)
      (ecc-remote-control-toggle)
      (should (eq :false (alist-get 'enabled
                                    (alist-get 'request
                                               (car (last (ecc-test-sent-messages))))))))))

(ert-deftest ecc-transient-test-remote-control-url ()
  "The URL of a session on the bridge can be opened and copied."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      (should-error (ecc-remote-control-copy-url) :type 'user-error)
      (ecc-model-set-remote-control
       session 'enabled t 'session-url "https://claude.ai/code/session_01")
      (let (visited)
        (cl-letf (((symbol-function 'browse-url) (lambda (url) (setq visited url))))
          (ecc-remote-control-open))
        (should (equal visited "https://claude.ai/code/session_01")))
      (ecc-remote-control-copy-url)
      (should (equal (current-kill 0) "https://claude.ai/code/session_01")))))

(provide 'ecc-transient-test)

;;; ecc-transient-test.el ends here
