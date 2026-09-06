;;; ecc-transient-test.el --- Tests for ecc-transient  -*- lexical-binding: t; -*-

;;; Commentary:

;; The menu itself cannot be driven in batch, but what it is built from
;; can: the slash command submenu comes from the initialize answer of the
;; session at hand (NFR-10).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-transient)

(ert-deftest ecc-transient-test-menu-is-a-command ()
  "Every menu is reachable with \\[execute-extended-command] (NFR-10)."
  (should (commandp 'ecc-menu))
  (should (commandp 'ecc-slash-menu))
  (should (commandp 'ecc-slash-command))
  (should (commandp 'ecc-customize)))

(ert-deftest ecc-transient-test-slash-suffixes ()
  "The submenu is built from the commands of the session (NFR-10)."
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
      (should (= (length suffixes) 2))
      ;; A key is handed out once.
      (should (equal keys (seq-uniq keys)))
      (should (string-search "/context" (nth 0 descriptions)))
      (should (string-search "Show context usage" (nth 0 descriptions)))
      ;; What the terminal client alone can run is marked (FR-INP-4).
      (should (string-search "[端末UI]" (nth 1 descriptions)))
      (should-not (string-search "端末UI" (nth 0 descriptions)))
      (dolist (suffix suffixes)
        (should (commandp (nth 2 suffix)))))))

(ert-deftest ecc-transient-test-slash-command-sends ()
  "Picking a slash command sends it to the session at hand (NFR-10)."
  (ecc-test-with-fake-session session
    (with-temp-buffer
      (funcall (ecc-transient-slash-command "/context"))
      (should (equal (ecc-test-sent-text 0) "/context"))
      (should (eq session (car (ecc-model-sessions))))
      ;; The same command comes back, so the menu keeps its suffix.
      (should (eq (ecc-transient-slash-command "/context")
                  (ecc-transient-slash-command "/context"))))))

(ert-deftest ecc-transient-test-interactive-slash-command-asks ()
  "A command that opens a menu in the terminal is asked about (FR-INP-5)."
  (ecc-test-with-fake-session _session
    (with-temp-buffer
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "opus")))
        (funcall (ecc-transient-slash-command "/model")))
      (should (equal (ecc-test-sent-text 0) "/model opus")))))

(ert-deftest ecc-transient-test-set-model ()
  "Changing the model is a slash command, not a restart (FR-INP-5)."
  (ecc-test-with-fake-session _session
    (with-temp-buffer
      (ecc-set-model "haiku")
      (should (equal (ecc-test-sent-text 0) "/model haiku")))))

(provide 'ecc-transient-test)

;;; ecc-transient-test.el ends here
