;;; ecc-hooks-test.el --- Tests for ecc-hooks  -*- lexical-binding: t; -*-

;;; Commentary:

;; The hooks a session would run: gathering them from the four settings
;; files and the plugins that define them, and editing the ones this
;; package is allowed to edit.
;;
;; Everything happens in a temporary directory that stands in for the
;; machine: `ecc-protocol-user-directory', `ecc-hooks-plugin-directory',
;; `ecc-protocol-managed-files' and `ecc-hooks-disabled-file' are all
;; variables so that a test can put them there, and nothing here reads
;; or writes the settings of the person running it.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-prompt)
(require 'ecc-hooks)

(defvar ecc-hooks-test-home nil
  "The directory standing in for the machine, while a test runs.")

(defvar ecc-hooks-test-root nil
  "The project directory, while a test runs.")

(defun ecc-hooks-test--write (file text)
  "Write TEXT to FILE, making the directories above it."
  (make-directory (file-name-directory file) t)
  (with-temp-buffer
    (insert text)
    (write-region (point-min) (point-max) file nil 'silent))
  file)

(defun ecc-hooks-test--hooks-json (&rest events)
  "Return a settings file body holding EVENTS.
Each of EVENTS is (EVENT MATCHER COMMAND...): one matcher group of
command hooks.  MATCHER nil writes no matcher at all."
  (concat "{\"hooks\": {"
          (string-join
           (mapcar (lambda (event)
                     (format "\"%s\": [{%s\"hooks\": [%s]}]"
                             (nth 0 event)
                             (if (nth 1 event)
                                 (format "\"matcher\": \"%s\", " (nth 1 event))
                               "")
                             (string-join
                              (mapcar (lambda (command)
                                        (format
                                         "{\"type\": \"command\", \"command\": \"%s\"}"
                                         command))
                                      (cddr event))
                              ", ")))
                   events)
           ", ")
          "}}"))

(defmacro ecc-hooks-test--with-machine (&rest body)
  "Run BODY with a temporary machine and project in place.
`ecc-hooks-test-home' is the settings directory of the user and
`ecc-hooks-test-root' the project; both are gone afterwards."
  (declare (indent 0))
  `(let* ((ecc-hooks-test-home (file-name-as-directory
                                (make-temp-file "ecc-hooks-home" t)))
          (ecc-hooks-test-root (file-name-as-directory
                                (make-temp-file "ecc-hooks-root" t)))
          (ecc-protocol-user-directory ecc-hooks-test-home)
          (ecc-hooks-plugin-directory (expand-file-name "plugins/"
                                                        ecc-hooks-test-home))
          ;; No administrator on a test machine, unless the test says so.
          (ecc-protocol-managed-files nil)
          (ecc-hooks-disabled-file (expand-file-name "ecc-disabled-hooks.json"
                                                     ecc-hooks-test-home)))
     (unwind-protect (progn ,@body)
       (delete-directory ecc-hooks-test-home t)
       (delete-directory ecc-hooks-test-root t))))

(defun ecc-hooks-test--user-file ()
  "Return the user settings file of the test machine."
  (expand-file-name "settings.json" ecc-hooks-test-home))

(defun ecc-hooks-test--project-file ()
  "Return the committed project settings file of the test project."
  (expand-file-name ".claude/settings.json" ecc-hooks-test-root))

(defun ecc-hooks-test--local-file ()
  "Return the uncommitted project settings file of the test project."
  (expand-file-name ".claude/settings.local.json" ecc-hooks-test-root))

(defun ecc-hooks-test--summaries (hooks)
  "Return (EVENT MATCHER SUMMARY SCOPE WRITABLE) of each of HOOKS."
  (mapcar (lambda (hook)
            (list (ecc-hook-event hook)
                  (ecc-hook-matcher hook)
                  (ecc-hook-summary hook)
                  (ecc-hook-scope hook)
                  (and (ecc-hook-writable hook) t)))
          hooks))

;;;; Gathering

(ert-deftest ecc-hooks-test-collects-every-scope-in-order ()
  "The four settings files are read in the order the CLI reads them."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--user-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "user")))
    (ecc-hooks-test--write (ecc-hooks-test--project-file)
                           (ecc-hooks-test--hooks-json
                            '("PreToolUse" "Write" "project")))
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "local")))
    (should (equal (ecc-hooks-test--summaries
                    (ecc-hooks-collect ecc-hooks-test-root))
                   '(("Stop" nil "user" user t)
                     ("PreToolUse" "Write" "project" project t)
                     ("Stop" nil "local" local t))))
    ;; With no project, only what the user settings say applies.
    (should (equal (ecc-hooks-test--summaries (ecc-hooks-collect nil))
                   '(("Stop" nil "user" user t))))))

(ert-deftest ecc-hooks-test-managed-settings-are-listed-but-not-editable ()
  "A hook an administrator put there is shown, and refused to the writers."
  (ecc-hooks-test--with-machine
    (let ((managed (expand-file-name "managed-settings.json" ecc-hooks-test-home)))
      (ecc-hooks-test--write managed (ecc-hooks-test--hooks-json
                                      '("PreToolUse" "Bash" "policy")))
      (let ((ecc-protocol-managed-files (list managed)))
        (should (equal (ecc-hooks-test--summaries
                        (ecc-hooks-collect ecc-hooks-test-root))
                       '(("PreToolUse" "Bash" "policy" managed nil))))
        ;; And the buffer says why nothing else would run.
        (should (equal (length (ecc-hooks-restrictions ecc-hooks-test-root)) 1))
        (should (string-search "Managed settings"
                               (car (ecc-hooks-restrictions
                                     ecc-hooks-test-root))))))))

(ert-deftest ecc-hooks-test-a-plugin-that-is-switched-off-defines-nothing ()
  "A plugin's hooks are listed only while enabledPlugins leaves it on."
  (ecc-hooks-test--with-machine
    (let* ((plugins (expand-file-name "plugins/" ecc-hooks-test-home))
           (install (expand-file-name "cache/m/bridge/1.0.0" plugins)))
      (ecc-hooks-test--write
       (expand-file-name "hooks/hooks.json" install)
       (ecc-hooks-test--hooks-json '("SessionStart" nil "from-the-plugin")))
      (ecc-hooks-test--write
       (expand-file-name "installed_plugins.json" plugins)
       (format "{\"version\": 2, \"plugins\": {\"bridge@m\": [{\"installPath\": \"%s\"}]}}"
               install))
      (should (equal (ecc-hooks-test--summaries
                      (ecc-hooks-collect ecc-hooks-test-root))
                     '(("SessionStart" nil "from-the-plugin" plugin nil))))
      (should (equal (ecc-hook-origin
                      (car (ecc-hooks-collect ecc-hooks-test-root)))
                     "bridge@m"))
      ;; This is the state of the machine this was written on: installed
      ;; and switched off, so none of its twelve hooks runs.
      (ecc-hooks-test--write (ecc-hooks-test--user-file)
                             "{\"enabledPlugins\": {\"bridge@m\": false}}")
      (should-not (ecc-hooks-collect ecc-hooks-test-root)))))

(ert-deftest ecc-hooks-test-a-broken-file-does-not-hide-the-others ()
  "One settings file that does not parse costs only its own hooks."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--user-file) "{not json")
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "local")))
    (should (equal (ecc-hooks-test--summaries
                    (ecc-hooks-collect ecc-hooks-test-root))
                   '(("Stop" nil "local" local t))))))

(ert-deftest ecc-hooks-test-disable-all-hooks-is-reported ()
  "A settings file that turns every hook off says so at the top."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           "{\"disableAllHooks\": true}")
    (should (string-search "disableAllHooks"
                           (car (ecc-hooks-restrictions ecc-hooks-test-root))))
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           "{\"disableAllHooks\": false}")
    (should-not (ecc-hooks-restrictions ecc-hooks-test-root))))

(ert-deftest ecc-hooks-test-summarises-every-kind-of-entry ()
  "The five kinds of hook entry each say what they do in one line."
  (should (equal (ecc-hooks--summary '((type . "command") (command . "make test")))
                 "make test"))
  (should (equal (ecc-hooks--summary '((type . "command") (args . ["ls" "-l"])))
                 "ls -l"))
  (should (equal (ecc-hooks--summary '((type . "http") (url . "https://x/y")))
                 "https://x/y"))
  (should (equal (ecc-hooks--summary '((type . "prompt") (prompt . "Is this safe?")))
                 "Is this safe?"))
  (should (equal (ecc-hooks--summary '((type . "agent") (prompt . "Verify")))
                 "Verify"))
  (should (equal (ecc-hooks--summary '((type . "mcp_tool") (server . "s") (tool . "t")))
                 "s/t"))
  ;; A kind this version has never seen still says something.
  (should (string-search "later" (ecc-hooks--summary '((type . "later"))))))

;;;; The buffer

(ert-deftest ecc-hooks-test-draws-the-events-it-knows-first ()
  "Hooks are grouped by event, the CLI's own order first and the rest sorted."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json
                            '("Stop" nil "b")
                            '("Zzz" nil "d")
                            '("PreToolUse" "Write" "a")
                            '("Aaa" nil "c")))
    (with-temp-buffer
      (ecc-hooks-draw ecc-hooks-test-root)
      (let ((text (buffer-string)))
        (should (string-search "PreToolUse (1)" text))
        (should (string-search "Stop (1)" text))
        ;; PreToolUse before Stop because the CLI lists it first, and
        ;; the two it does not know after both, in name order.
        (should (< (string-search "PreToolUse (1)" text)
                   (string-search "Stop (1)" text)
                   (string-search "Aaa (1)" text)
                   (string-search "Zzz (1)" text)))
        (should (string-search "Write" text))
        ;; A hook that matches everything says so rather than nothing.
        (should (string-search "*" text))))))

(ert-deftest ecc-hooks-test-an-empty-machine-says-so ()
  "A project with no hooks anywhere says how to make one."
  (ecc-hooks-test--with-machine
    (with-temp-buffer
      (ecc-hooks-draw ecc-hooks-test-root)
      (should (string-search "No hook is defined" (buffer-string))))))

(ert-deftest ecc-hooks-test-a-line-carries-its-hook ()
  "Every hook line carries the structure, so that the commands can find it."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "a")))
    (with-temp-buffer
      (ecc-hooks-draw ecc-hooks-test-root)
      (goto-char (point-min))
      (should (re-search-forward "^  " nil t))
      (let ((hook (get-text-property (point) 'ecc-hook)))
        (should (ecc-hook-p hook))
        (should (equal (ecc-hook-summary hook) "a"))
        (should (equal (ecc-hook-source hook) (ecc-hooks-test--local-file)))))))

(ert-deftest ecc-hooks-test-folding-hides-the-hooks-of-an-event ()
  "TAB on an event folds it away and back."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "the-command")))
    (with-temp-buffer
      (ecc-hooks-mode)
      (setq ecc-hooks--root ecc-hooks-test-root)
      (ecc-hooks-draw ecc-hooks-test-root)
      (goto-char (point-min))
      (should (re-search-forward "Stop (1)" nil t))
      (goto-char (match-beginning 0))
      (ecc-hooks-toggle)
      (should-not (string-search "the-command" (buffer-string)))
      (goto-char (point-min))
      (should (re-search-forward "Stop (1)" nil t))
      (goto-char (match-beginning 0))
      (ecc-hooks-toggle)
      (should (string-search "the-command" (buffer-string))))))

;;;; Editing

(defun ecc-hooks-test--goto (summary)
  "Put point at the start of the line of the hook whose summary is SUMMARY.
The start of the line, because the whole line answers to `a\=', `k\=' and
`t\=', not only the characters of the label.  The line is found by the
hook it carries rather than by searching for the text, which would as
happily land in the heading or in the line of keys at the top."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (let ((hook (get-text-property (point) 'ecc-hook)))
        (if (and hook (equal (ecc-hook-summary hook) summary))
            (setq found t)
          (forward-line 1))))
    (unless found
      (error "No hook %S in the buffer" summary))))

(defmacro ecc-hooks-test--in-buffer (&rest body)
  "Run BODY in a drawn Hooks buffer for the test project."
  (declare (indent 0))
  `(with-temp-buffer
     (ecc-hooks-mode)
     (setq ecc-hooks--root ecc-hooks-test-root)
     (ecc-hooks-draw ecc-hooks-test-root)
     ,@body))

(ert-deftest ecc-hooks-test-the-whole-line-is-the-hook ()
  "A hook is found from anywhere on its line, and the keys are said at the top."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "a")))
    (ecc-hooks-test--in-buffer
      (goto-char (point-min))
      (should (re-search-forward "a add" (line-end-position 3) t))
      (ecc-hooks-test--goto "a")
      (should (ecc-hooks-at-point))
      (end-of-line)
      (should (ecc-hooks-at-point))
      ;; And an event folds from anywhere on its heading.
      (goto-char (point-min))
      (re-search-forward "^▾ Stop")
      (goto-char (line-beginning-position))
      (ecc-hooks-toggle)
      (should (member "Stop" ecc-hooks--folded)))))

(ert-deftest ecc-hooks-test-add-names-everything-before-writing ()
  "The command, the event and the file are all in the confirmation."
  (ecc-hooks-test--with-machine
    (let ((asked nil))
      (cl-letf* ((matchers (list "Write" ""))   ; the empty one ends the list
                 ((symbol-function 'completing-read)
                  (lambda (prompt collection &rest _)
                    (cond ((string-prefix-p "Event" prompt) "PreToolUse")
                          ((string-prefix-p "Matcher" prompt) (pop matchers))
                          (t (caar collection)))))
                ((symbol-function 'read-string) (lambda (&rest _) "make test"))
                ((symbol-function 'y-or-n-p)
                 (lambda (prompt) (push prompt asked) t)))
        (let ((ecc-hooks--root ecc-hooks-test-root))
          (call-interactively #'ecc-hooks-add)))
      (should (equal (length asked) 1))
      (dolist (part '("make test" "PreToolUse" "Write" "settings.local.json"))
        (should (string-search part (car asked))))
      ;; The default is the file that is not committed.
      (should (equal (ecc-hooks-test--summaries
                      (ecc-hooks-collect ecc-hooks-test-root))
                     '(("PreToolUse" "Write" "make test" local t)))))))

(ert-deftest ecc-hooks-test-add-refused-writes-nothing ()
  "Saying no at the confirmation leaves the settings file absent."
  (ecc-hooks-test--with-machine
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection &rest _)
                 (cond ((string-prefix-p "Event" prompt) "Stop")
                       (t (caar collection)))))
              ((symbol-function 'read-string) (lambda (&rest _) "make test"))
              ((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (let ((ecc-hooks--root ecc-hooks-test-root))
        (should-error (call-interactively #'ecc-hooks-add) :type 'user-error)))
    (should-not (file-exists-p (ecc-hooks-test--local-file)))))

(ert-deftest ecc-hooks-test-add-refuses-a-matcher-the-cli-cannot-read ()
  "A matcher outside what the CLI accepts is refused before it is written."
  (ecc-hooks-test--with-machine
    (let ((answers (list "Write(*)" "")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _)
                   (if (string-prefix-p "Event" prompt) "PreToolUse"
                     (pop answers)))))
        (should-error (ecc-hooks--read-matcher "PreToolUse") :type 'user-error)))
    ;; An event that takes no matcher is never asked about.
    (should-not (ecc-hooks--read-matcher "Stop"))))

(ert-deftest ecc-hooks-test-add-reads-one-matcher-after-another ()
  "Matchers are read until an empty answer, and joined as the CLI\='s `|' list."
  (ecc-hooks-test--with-machine
    (let ((answers (list "Write" "Edit" "")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (pop answers))))
        (should (equal (ecc-hooks--read-matcher "PreToolUse") "Write|Edit"))))
    ;; What has been answered already is not offered again.
    (let ((answers (list "Write" "Edit" ""))
          (offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (push collection offered)
                   (pop answers))))
        (ecc-hooks--read-matcher "PreToolUse"))
      (should (member "Write" (car (last offered))))
      (should-not (member "Write" (car offered))))
    ;; The first answer empty is every matcher, which is no matcher at all.
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should-not (ecc-hooks--read-matcher "PreToolUse")))))

(ert-deftest ecc-hooks-test-remove-takes-the-hook-out-of-its-file ()
  "k removes the hook at point once its file has been named."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "a" "b")))
    (ecc-hooks-test--in-buffer
      (ecc-hooks-test--goto "a")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (should-error (ecc-hooks-remove) :type 'user-error))
      (should (equal (length (ecc-hooks-collect ecc-hooks-test-root)) 2))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (ecc-hooks-remove))
      (should (equal (ecc-hooks-test--summaries
                      (ecc-hooks-collect ecc-hooks-test-root))
                     '(("Stop" nil "b" local t)))))))

(ert-deftest ecc-hooks-test-what-is-not-ours-is-refused ()
  "A plugin's hook and an administrator's are read-only."
  (ecc-hooks-test--with-machine
    (let* ((managed (expand-file-name "managed-settings.json" ecc-hooks-test-home))
           (ecc-protocol-managed-files (list managed)))
      (ecc-hooks-test--write managed (ecc-hooks-test--hooks-json
                                      '("Stop" nil "policy")))
      (ecc-hooks-test--in-buffer
        (ecc-hooks-test--goto "policy")
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
          (should-error (ecc-hooks-remove) :type 'user-error)
          (should-error (ecc-hooks-switch) :type 'user-error))
        (should (equal (length (ecc-hooks-collect ecc-hooks-test-root)) 1))))))

(ert-deftest ecc-hooks-test-switching-off-and-on-again-is-a-round-trip ()
  "A hook switched off leaves its file, and comes back the same when switched on."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write
     (ecc-hooks-test--local-file)
     "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Write\", \"hooks\": [
        {\"type\": \"command\", \"command\": \"a\", \"timeout\": 60}]}]},
       \"permissions\": {\"allow\": [\"Bash(ls)\"]}}")
    (ecc-hooks-test--in-buffer
        (ecc-hooks-test--goto "a")
        (ecc-hooks-switch)
        ;; Out of the settings file, and into the stash, where the
        ;; buffer still shows it -- switched off, and not editable by
        ;; the CLI any more.
        (should-not (ecc-protocol-settings-hook-entries
                     (ecc-protocol-read-settings-file (ecc-hooks-test--local-file))))
        (should (equal (ecc-hooks-test--summaries
                        (ecc-hooks-collect ecc-hooks-test-root))
                       '(("PreToolUse" "Write" "a" disabled t))))
        ;; Nothing of this package's is written into the settings file.
        (should-not (string-search
                     "ecc"
                     (with-temp-buffer
                       (insert-file-contents (ecc-hooks-test--local-file))
                       (buffer-string))))
        (ecc-hooks-refresh)
        (ecc-hooks-test--goto "a")
        (ecc-hooks-switch)
        (should (equal (ecc-hooks-test--summaries
                        (ecc-hooks-collect ecc-hooks-test-root))
                       '(("PreToolUse" "Write" "a" local t))))
        ;; The entry came back whole, timeout and all, and so did
        ;; everything else the file held.
        (let ((entry (plist-get (car (ecc-protocol-settings-hook-entries
                                      (ecc-protocol-read-settings-file
                                       (ecc-hooks-test--local-file))))
                                :entry)))
          (should (equal (alist-get 'timeout entry) 60)))
        ;; The file is rewritten, so its layout is the writer's and the
        ;; hooks block is last -- but nothing in it is lost.
        (should (equal (ecc-protocol-settings-allow-list
                        (ecc-protocol-read-settings-file
                         (ecc-hooks-test--local-file)))
                       '("Bash(ls)"))))))

(ert-deftest ecc-hooks-test-a-switched-off-hook-of-another-project-is-not-shown ()
  "The stash is one file for the machine, but each project sees only its own."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "mine")))
    (ecc-hooks-test--in-buffer
      (ecc-hooks-test--goto "mine")
      (ecc-hooks-switch))
    (ecc-protocol-stash-add (ecc-hooks-disabled-file)
                            "/somewhere/else/.claude/settings.local.json"
                            "Stop" nil '((type . "command") (command . "theirs")))
    (should (equal (ecc-hooks-test--summaries
                    (ecc-hooks-collect ecc-hooks-test-root))
                   '(("Stop" nil "mine" disabled t))))))

(ert-deftest ecc-hooks-test-forgetting-a-switched-off-hook-leaves-no-trace ()
  "k on a hook that is switched off drops it from the stash for good."
  (ecc-hooks-test--with-machine
    (ecc-hooks-test--write (ecc-hooks-test--local-file)
                           (ecc-hooks-test--hooks-json '("Stop" nil "a")))
    (ecc-hooks-test--in-buffer
      (ecc-hooks-test--goto "a")
      (ecc-hooks-switch)
      (ecc-hooks-refresh)
      (ecc-hooks-test--goto "a")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt)
                   (should (string-search "switched-off" prompt))
                   t)))
        (ecc-hooks-remove))
      (should-not (ecc-hooks-collect ecc-hooks-test-root))
      (should-not (ecc-protocol-stash-entries (ecc-hooks-disabled-file))))))

;;;; The prompt region

(ert-deftest ecc-hooks-test-the-prompt-answers-slash-hooks ()
  "`/hooks' opens the buffer here and nothing of it reaches the CLI.
The CLI's own command of that name is declared ink-only, so it is in
neither list system/init sends and a draft holding it would otherwise
go to the model as a sentence."
  (ecc-test-with-fake-session session
    (let (roots)
      (cl-letf (((symbol-function 'ecc-hooks-show)
                 (lambda (&optional root) (push root roots))))
        (should (ecc-hooks-intercept session "/hooks"))
        (should (equal roots (list (ecc-session-project-root session)))))
      ;; A command the CLI answers, and a plain sentence, are left alone.
      (should-not (ecc-hooks-intercept session "/model opus"))
      (should-not (ecc-hooks-intercept session "which hooks are there")))))

(ert-deftest ecc-hooks-test-slash-hooks-is-offered ()
  "It is in the command list of a session, and no menu hides it."
  (ecc-test-with-fake-session session
    (should (assoc "/hooks" (ecc-prompt-commands session)))
    (should (member "/hooks" (mapcar #'car (ecc-prompt-offered-commands session))))
    ;; And it is on the hook that the prompt region consults.
    (should (memq #'ecc-hooks-intercept ecc-prompt-intercept-functions))))

(provide 'ecc-hooks-test)

;;; ecc-hooks-test.el ends here
