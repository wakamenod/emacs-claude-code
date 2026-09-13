;;; ecc-skill-test.el --- Tests for ecc-skill  -*- lexical-binding: t; -*-

;;; Commentary:

;; The skills of a session: what the list is made of, what `/skills' in
;; the prompt region does, and what turning a skill off writes.
;;
;; No CLI is started.  The names come from the system/init line of
;; test/fixtures/basic-turn.jsonl, the settings from an answer written
;; by hand in the shape `get_settings' really returns (2.1.270,
;; 2026-09-13), and the file a toggle writes is a temporary one.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-skill)
(require 'ecc-prompt)
(require 'ecc-chat)

(defmacro ecc-skill-test-with-session (var &rest body)
  "Run BODY with VAR bound to a fake session that has a CLI to ask.
The skill state is emptied for the test, and the Skills buffer is not
left behind."
  (declare (indent 1) (debug (symbolp body)))
  `(ecc-test-with-fake-session ,var
     (let ((ecc-skill--overrides (make-hash-table :test #'eq))
           (ecc-skill--locks (make-hash-table :test #'eq))
           (ecc-skill--settings-state (make-hash-table :test #'eq))
           (ecc-skill-settings-file nil)
           (ecc-skill-reload-after-toggle t))
       (cl-letf (((symbol-function #'ecc-skill--running-p) (lambda (_session) t)))
         (unwind-protect
             (progn ,@body)
           (when-let* ((buffer (get-buffer ecc-skill-buffer-name)))
             (kill-buffer buffer)))))))

(defun ecc-skill-test--init (session &rest skills)
  "Give SESSION an init message naming SKILLS."
  (setf (ecc-session-init session)
        `((type . "system") (subtype . "init")
          (skills . ,(vconcat skills))
          (slash_commands . ,(vconcat skills)))))

(defun ecc-skill-test--commands (session &rest pairs)
  "Give SESSION the commands PAIRS, an alist of name and description."
  (setf (ecc-session-commands session)
        (vconcat (mapcar (lambda (pair)
                           `((name . ,(car pair)) (description . ,(cdr pair))))
                         pairs))))

(defun ecc-skill-test--answer (session request-id response &optional error)
  "Hand SESSION the answer RESPONSE to REQUEST-ID, the way the CLI would.
With ERROR the answer is a refusal instead."
  (ecc-dispatch
   session
   (ecc-protocol-parse-line
    (ecc-protocol-serialize
     (if error
         `((type . "control_response")
           (response . ((subtype . "error")
                        (request_id . ,request-id)
                        (error . "no"))))
       `((type . "control_response")
         (response . ((subtype . "success")
                      (request_id . ,request-id)
                      (response . ,response)))))))))

(defun ecc-skill-test--sources (&rest pairs)
  "Return a get_settings sources vector; PAIRS is source and overrides."
  (vconcat (mapcar (lambda (pair)
                     `((source . ,(car pair))
                       (settings . ((skillOverrides . ,(cdr pair))))))
                   pairs)))

(defun ecc-skill-test--set-overrides (session overrides)
  "Pretend SESSION has read OVERRIDES, an alist of name and value."
  (puthash session overrides ecc-skill--overrides)
  (puthash session 'read ecc-skill--settings-state))

(defun ecc-skill-test--skill (session name)
  "Return the skill called NAME of SESSION."
  (seq-find (lambda (skill) (equal (ecc-skill-name skill) name))
            (ecc-skill-list session)))

;;;; The list

(ert-deftest ecc-skill-test-names-come-from-init ()
  "The skills of a session are the ones system/init named."
  (ecc-skill-test-with-session session
    (ecc-test-dispatch session "basic-turn" "hello")
    (should (member "dataviz" (ecc-skill-names session)))
    (should (member "code-review" (ecc-skill-names session)))
    ;; A slash command that is not a skill is not one here either.
    (should-not (member "model" (ecc-skill-names session)))))

(ert-deftest ecc-skill-test-a-skill-that-is-off-keeps-its-row ()
  "A skill the CLI no longer names is still listed, so it can come back.
The CLI leaves an `off' skill out of every list it sends, and a row
that is not drawn cannot be turned back on."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (ecc-skill-test--set-overrides session '(("simplify" . "off")))
    (should (equal (ecc-skill-names session) '("dataviz" "simplify")))
    (let ((skill (seq-find (lambda (skill)
                             (equal (ecc-skill-name skill) "simplify"))
                           (ecc-skill-list session))))
      (should (ecc-skill-off-p skill)))))

(ert-deftest ecc-skill-test-the-description-comes-from-initialize ()
  "What a skill is for is what the CLI answered initialize with."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (ecc-skill-test--commands session '("dataviz" . "Charts and graphs"))
    (let ((skill (car (ecc-skill-list session))))
      (should (equal (ecc-skill-description skill) "Charts and graphs"))
      ;; Nothing on this machine defines it, so it belongs to the CLI.
      (should (eq (ecc-skill-scope skill) 'builtin))
      (should-not (ecc-skill-file skill)))))

;;;; The settings

(ert-deftest ecc-skill-test-overrides-are-read-per-source ()
  "The more specific settings file wins, whatever order the answer is in.
The terminal client reads localSettings, then projectSettings, then
userSettings, and takes the first that names the skill."
  (should (equal (ecc-skill-sources-overrides
                  (ecc-skill-test--sources
                   '("localSettings" . ((dataviz . "name-only")))
                   '("userSettings" . ((dataviz . "off") (run . "off")))
                   '("projectSettings" . ((dataviz . "on")))))
                 '(("dataviz" . "name-only") ("run" . "off"))))
  ;; A source that says nothing about skills is not an answer.
  (should-not (ecc-skill-sources-overrides
               (vector '((source . "userSettings")
                         (settings . ((model . "opus"))))))))

(ert-deftest ecc-skill-test-a-policy-is-a-lock-not-an-override ()
  "What a policy or a flag says about a skill cannot be toggled away."
  (let ((sources (ecc-skill-test--sources
                  '("policySettings" . ((dataviz . "off")))
                  '("userSettings" . ((run . "off"))))))
    (should (equal (ecc-skill-sources-locks sources)
                   '(("dataviz" . "policySettings"))))
    ;; It is not merged into the ordinary overrides.
    (should (equal (ecc-skill-sources-overrides sources)
                   '(("run" . "off"))))))

(ert-deftest ecc-skill-test-the-override-goes-where-the-cli-puts-it ()
  "A toggle writes the settings file the terminal client saves to."
  (ecc-skill-test-with-session session
    (should (equal (ecc-skill-settings-file session)
                   (expand-file-name ".claude/settings.local.json"
                                     (ecc-session-project-root session))))))

(ert-deftest ecc-skill-test-reading-the-settings-asks-the-cli ()
  "The state of a skill comes from a get_settings control request."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (ecc-skill-read-settings session)
    (let ((request (alist-get 'request (car (ecc-test-sent-messages)))))
      (should (equal (alist-get 'subtype request) "get_settings")))
    (should (eq (ecc-skill-settings-state session) 'unread))
    (ecc-skill-test--answer
     session (alist-get 'request_id (car (ecc-test-sent-messages)))
     `((sources . ,(ecc-skill-test--sources
                    '("userSettings" . ((dataviz . "off")))))))
    (should (eq (ecc-skill-settings-state session) 'read))
    (should (equal (ecc-skill-override-for session "dataviz") "off"))))

(ert-deftest ecc-skill-test-a-refused-answer-is-not-taken-for-none ()
  "A get_settings the CLI refuses leaves the state at failed."
  (ecc-skill-test-with-session session
    (ecc-skill-read-settings session)
    (ecc-skill-test--answer
     session (alist-get 'request_id (car (ecc-test-sent-messages)))
     nil 'error)
    (should (eq (ecc-skill-settings-state session) 'failed))))

;;;; What is written

(ert-deftest ecc-skill-test-an-override-keeps-the-rest-of-the-file ()
  "Setting one skill leaves every other setting where it was."
  (let ((settings '((model . "opus")
                    (permissions . ((allow . ["Bash(ls *)"])))
                    (skillOverrides . ((run . "name-only"))))))
    (let ((written (ecc-skill-settings-with-override settings "dataviz" "off")))
      (should (equal (alist-get 'model written) "opus"))
      (should (equal (alist-get 'permissions written)
                     '((allow . ["Bash(ls *)"]))))
      (should (equal (alist-get 'skillOverrides written)
                     '((run . "name-only") (dataviz . "off")))))))

(ert-deftest ecc-skill-test-the-default-removes-the-entry ()
  "Putting a skill back to the default writes nothing about it."
  (let ((settings '((model . "opus") (skillOverrides . ((dataviz . "off"))))))
    (let ((written (ecc-skill-settings-with-override settings "dataviz" nil)))
      ;; The last entry takes the object with it: an empty skillOverrides
      ;; says no more than no skillOverrides at all.
      (should-not (assq 'skillOverrides written))
      (should (equal (alist-get 'model written) "opus")))))

(ert-deftest ecc-skill-test-the-file-is-read-back-as-it-was-written ()
  "What is written is JSON the CLI would read the same way."
  (let ((file (make-temp-file "ecc-skill-test" nil ".json")))
    (unwind-protect
        (progn
          (ecc-skill-write-settings-file file '((model . "opus")))
          (ecc-skill-set-override-in-file file "dataviz" "off")
          (let ((settings (ecc-skill-read-settings-file file)))
            (should (equal (alist-get 'model settings) "opus"))
            (should (equal (alist-get 'dataviz
                                      (alist-get 'skillOverrides settings))
                           "off")))
          (ecc-skill-set-override-in-file file "dataviz" nil)
          (should-not (assq 'skillOverrides
                            (ecc-skill-read-settings-file file))))
      (delete-file file))))

(ert-deftest ecc-skill-test-turning-one-off-reloads-the-session ()
  "A skill that has been turned off is written, then the CLI is told."
  (ecc-skill-test-with-session session
    (let ((ecc-skill-settings-file (make-temp-file "ecc-skill-test" nil ".json")))
      (unwind-protect
          (progn
            (ecc-skill-test--init session "dataviz")
            (ecc-skill-set-override session "dataviz" "off")
            (should (equal (alist-get 'dataviz
                                      (alist-get 'skillOverrides
                                                 (ecc-skill-read-settings-file
                                                  ecc-skill-settings-file)))
                           "off"))
            (let ((sent (ecc-test-sent-messages)))
              ;; The reload goes first, and the settings are read again
              ;; rather than assumed.
              (should (equal (alist-get 'content (alist-get 'message (nth 0 sent))) "/reload-skills"))
              (should (equal (alist-get 'subtype
                                        (alist-get 'request (nth 1 sent)))
                             "get_settings"))))
        (delete-file ecc-skill-settings-file)))))

(ert-deftest ecc-skill-test-no-reload-when-it-is-turned-off ()
  "Nothing is sent when the session is not meant to be told."
  (ecc-skill-test-with-session session
    (let ((ecc-skill-settings-file (make-temp-file "ecc-skill-test" nil ".json"))
          (ecc-skill-reload-after-toggle nil))
      (unwind-protect
          (progn
            (ecc-skill-set-override session "dataviz" "off")
            (should-not (seq-find (lambda (message)
                                    (equal (alist-get 'type message) "user"))
                                  (ecc-test-sent-messages))))
        (delete-file ecc-skill-settings-file)))))

;;;; Running one

(ert-deftest ecc-skill-test-the-skills-come-first-in-the-menu ()
  "A skill is marked as one and kept at the top of what `/' offers.
The terminal client puts the skills first; Emacs hands its candidates
to whatever completion the user runs, so the order is asked for in the
metadata and the group says which is which."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine")
    (ecc-skill-test--commands session
                              '("mine" . "Mine (user)")
                              '("context" . "Show context usage"))
    (let* ((metadata (ecc-prompt--completion-metadata session #'ignore))
           (group (alist-get 'group-function (cdr metadata))))
      (should (eq (alist-get 'display-sort-function (cdr metadata)) #'identity))
      (should (equal (funcall group "/mine" nil) "Skills"))
      (should (equal (funcall group "/context" nil) "Commands"))
      ;; With transform it is the candidate itself that comes back.
      (should (equal (funcall group "/mine" t) "/mine")))))

(ert-deftest ecc-skill-test-a-skill-is-offered-like-any-command ()
  "The skills of a session are among the commands `/' offers."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine")
    (ecc-skill-test--commands session '("mine" . "Mine (user)"))
    (should (assoc "/mine" (ecc-prompt-offered-commands session)))))

(ert-deftest ecc-skill-test-cycling-holds-the-change-until-it-is-saved ()
  "RET walks the four settings and nothing is written until q.
The terminal client works the same way: it saves when its dialog is
closed, so walking a skill from on to off leaves one change on disk
rather than three."
  (ecc-skill-test-with-session session
    (let ((ecc-skill-settings-file (make-temp-file "ecc-skill-test" nil ".json")))
      (unwind-protect
          (progn
            (ecc-skill-test--init session "mine")
            (ecc-skill-test--commands session '("mine" . "Mine (user)"))
            (with-current-buffer (get-buffer-create ecc-skill-buffer-name)
              (ecc-skill-mode)
              (setq ecc-skill--session session)
              (ecc-skill-draw session)
              (goto-char (point-min))
              (should (re-search-forward "mine" nil t))
              (ecc-skill-cycle)
              (ecc-skill-cycle)
              (ecc-skill-cycle)
              ;; Three presses, one pending change and nothing sent.
              (should (equal (ecc-skill--pending-changes) '(("mine" . "off"))))
              (should (string-match-p "1 change not written yet"
                                      (buffer-string)))
              (should-not (ecc-test-sent-messages))
              ;; It is marked as not written, so the buffer does not read
              ;; as though the settings already said it.
              (should (string-match-p "✘ off *\*" (buffer-string)))
              (should (= (ecc-skill-save) 1))
              (should (equal (alist-get 'mine
                                        (alist-get 'skillOverrides
                                                   (ecc-skill-read-settings-file
                                                    ecc-skill-settings-file)))
                             "off"))
              ;; One reload for the three presses.
              (should (equal (seq-filter
                              (lambda (message)
                                (equal (alist-get 'type message) "user"))
                              (ecc-test-sent-messages))
                             (list (car (ecc-test-sent-messages)))))
              (should-not ecc-skill--pending)))
        (delete-file ecc-skill-settings-file)))))

(ert-deftest ecc-skill-test-a-command-is-about-the-line-point-is-on ()
  "Anywhere on the row will do: the indentation, the end of the line.
Point had to be on the name itself before, which is not where it lands
after a redraw or after moving down a line."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine")
    (ecc-skill-test--commands session '("mine" . "Mine (user)"))
    (with-current-buffer (get-buffer-create ecc-skill-buffer-name)
      (ecc-skill-mode)
      (setq ecc-skill--session session)
      (ecc-skill-draw session)
      (goto-char (point-min))
      (should (re-search-forward "mine" nil t))
      (beginning-of-line)
      (ecc-skill-cycle)
      (end-of-line)
      (ecc-skill-cycle)
      (should (equal (ecc-skill--pending-changes)
                     '(("mine" . "user-invocable-only"))))
      ;; A heading folds from anywhere on its line too.
      (goto-char (point-min))
      (should (re-search-forward "▾ user" nil t))
      (end-of-line)
      (ecc-skill-cycle)
      (should (member "user" ecc-skill--folded)))))

(ert-deftest ecc-skill-test-cycling-all-the-way-round-writes-nothing ()
  "A skill brought back to what it already was is no change at all."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine")
    (ecc-skill-test--commands session '("mine" . "Mine (user)"))
    (with-current-buffer (get-buffer-create ecc-skill-buffer-name)
      (ecc-skill-mode)
      (setq ecc-skill--session session)
      (ecc-skill-draw session)
      (goto-char (point-min))
      (should (re-search-forward "mine" nil t))
      (dotimes (_ 4) (ecc-skill-cycle))
      (should-not (ecc-skill--pending-changes))
      (should (= (ecc-skill-save) 0)))))

(ert-deftest ecc-skill-test-running-one-sends-its-command ()
  "A skill is run by sending the slash command it installs."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (ecc-skill-invoke session "dataviz")
    (should (equal (ecc-test-sent-text 0)
                   "/dataviz"))))

;;;; /skills in the prompt region

(ert-deftest ecc-skill-test-the-command-is-answered-here ()
  "/skills opens the buffer and sends nothing to the CLI."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (should (ecc-skill-intercept session "/skills"))
    (should (get-buffer ecc-skill-buffer-name))
    ;; Only the get_settings the buffer asks for; no prompt.
    (should-not (seq-find (lambda (message)
                            (equal (alist-get 'type message) "user"))
                          (ecc-test-sent-messages)))))

(ert-deftest ecc-skill-test-the-command-runs-the-skill-it-names ()
  "/skills dataviz runs that skill."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (should (ecc-skill-intercept session "/skills dataviz"))
    (should (equal (ecc-test-sent-text 0)
                   "/dataviz"))
    (should-not (get-buffer ecc-skill-buffer-name))))

(ert-deftest ecc-skill-test-a-name-that-is-no-skill-is-refused ()
  "/skills with a name the session does not have sends nothing."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz")
    (should-error (ecc-skill-intercept session "/skills nonesuch")
                  :type 'user-error)
    (should-not (ecc-test-sent-messages))))

(ert-deftest ecc-skill-test-another-command-is-left-alone ()
  "A command that only starts the same way is not taken."
  (ecc-skill-test-with-session session
    (should-not (ecc-skill-intercept session "/skill-doctor"))
    (should-not (ecc-skill-intercept session "what about /skills"))))

(ert-deftest ecc-skill-test-the-command-is-offered-in-the-prompt ()
  "/skills is in the commands a session offers, though the CLI omits it.
The singular is answered but not offered: it would be a second row for
the same thing in every menu."
  (ecc-skill-test-with-session session
    (let ((commands (ecc-prompt-commands session)))
      (should (assoc "/skills" commands))
      (should-not (assoc "/skill" commands))))
  ;; Typed out by hand it still works.
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine")
    (should (ecc-skill-intercept session "/skill"))
    (should (get-buffer ecc-skill-buffer-name))))

;;;; The buffer

(ert-deftest ecc-skill-test-the-buffer-says-what-is-off ()
  "A skill that is off is drawn with what it is set to."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine" "other")
    (ecc-skill-test--commands session
                              '("mine" . "Charts and graphs (user)")
                              '("other" . "Something else (project)"))
    (ecc-skill-test--set-overrides session '(("other" . "off")))
    (with-temp-buffer
      (ecc-skill-draw session)
      (let ((text (buffer-string)))
        (should (string-match-p "Skills of test -- 2, 1 off" text))
        ;; The tag says where it came from; it is the group, not part of
        ;; what the skill is for.
        (should (string-match-p "▾ user (1)" text))
        ;; The mark and the word come before the name, as they do in the
        ;; terminal client.
        (should (string-match-p "✔ on +mine +Charts and graphs$" text))
        (should (string-match-p "✘ off +other" text))))))

(ert-deftest ecc-skill-test-the-skills-of-the-cli-are-not-listed ()
  "The skills the CLI came with are left out, as the terminal client leaves them.
What it ships carries no source tag and has no file on this machine,
and a dynamic workflow is no more a file than they are; those are not
the user\='s to manage, and listing them would bury the handful that
are."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "dataviz" "mine" "deep-research")
    (ecc-skill-test--commands session
                              '("dataviz" . "Charts and graphs")
                              '("deep-research" . "Research (dynamic workflow)")
                              '("mine" . "Mine (user)"))
    (should (equal (mapcar #'ecc-skill-name (ecc-skill-list session))
                   '("dataviz" "deep-research" "mine")))
    (with-temp-buffer
      (setq ecc-skill--session session)
      (ecc-skill-draw session)
      (let ((text (buffer-string)))
        (should (string-match-p "Skills of test -- 1" text))
        (should (string-match-p "2 of the CLI's own, hidden" text))
        (should-not (string-match-p "dataviz" text))
        (should-not (string-match-p "deep-research" text)))
      ;; a lists them, and then they can be run like any other.
      (ecc-skill-toggle-built-in)
      (let ((text (buffer-string)))
        (should (string-match-p "Skills of test -- 3" text))
        (should (string-match-p "▾ built-in (1)" text))
        (should (string-match-p "▾ dynamic workflow (1)" text))
        (should (string-match-p "dataviz" text))))))

(ert-deftest ecc-skill-test-the-source-tag-is-read-off-the-description ()
  "The CLI tags the description of every skill it did not bundle."
  (should (equal (ecc-skill-description-source "Charts and graphs (user)")
                 "user"))
  (should (equal (ecc-skill-description-source "Mine (project)") "project"))
  (should (equal (ecc-skill-description-source "Synced (claude.ai)")
                 "claude.ai"))
  ;; A skill of the CLI carries none, and so does a description that
  ;; happens to end in brackets of its own.
  (should-not (ecc-skill-description-source "Charts and graphs"))
  (should-not (ecc-skill-description-source "Use it (see the manual)"))
  (should (equal (ecc-skill-description-without-source "Mine (user)") "Mine")))

(ert-deftest ecc-skill-test-a-locked-skill-is-not-toggled ()
  "A policy has the last word, and a plugin manages its own."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "locked")
    (ecc-skill-test--commands session '("locked" . "Locked (user)"))
    (puthash session '(("locked" . "policySettings")) ecc-skill--locks)
    (with-temp-buffer
      (ecc-skill-mode)
      (setq ecc-skill--session session)
      (ecc-skill-draw session)
      (goto-char (point-min))
      (should (re-search-forward "locked" nil t))
      ;; The padlock says so before the reason does.
      (should (string-match-p "🔒 on +locked" (buffer-string)))
      (should (string-match-p "locked by policySettings" (buffer-string)))
      (should-error (ecc-skill-cycle) :type 'user-error)
      (should-not (ecc-test-sent-messages)))))

(ert-deftest ecc-skill-test-the-buffer-names-its-own-keys ()
  "The keys are written under the heading, as the CLI writes its own.
They fit in eighty columns, because the buffer does not wrap."
  (ecc-skill-test-with-session session
    (ecc-skill-test--init session "mine")
    (ecc-skill-test--commands session '("mine" . "Mine (user)"))
    (with-temp-buffer
      (ecc-skill-draw session)
      (let ((line (ecc-skill--key-line)))
        (should (string-match-p "RET cycle" line))
        (should (string-match-p "q save and close" line))
        (should (<= (length line) 80))
        (should (string-search line (buffer-string)))))))

(ert-deftest ecc-skill-test-the-buffer-says-when-there-is-nothing ()
  "A session with no skills of its own says so rather than sitting empty."
  (ecc-skill-test-with-session session
    (with-temp-buffer
      (ecc-skill-draw session)
      (should (string-match-p "None:" (buffer-string))))))

(ert-deftest ecc-skill-test-the-commands-name-the-skills-before-init ()
  "A session that has not spoken yet still lists the skills it has.
system/init comes with the first turn; the commands of the initialize
answer are there as soon as the CLI is up, and the terminal client\='s
own /skills works from those.  A command is only taken for a skill when
a SKILL.md is there too: a slash command of .claude/commands carries
the same tag and is no skill."
  (ecc-skill-test-with-session session
    (let* ((root (ecc-session-project-root session))
           (dir (expand-file-name ".claude/skills/mine/" root))
           (file (expand-file-name "SKILL.md" dir)))
      (unwind-protect
          (progn
            (make-directory dir t)
            (with-temp-file file (insert "---\nname: mine\n---\n"))
            (ecc-skill-test--commands session
                                      '("mine" . "Mine (project)")
                                      '("my-command" . "A command (project)")
                                      '("dataviz" . "Charts and graphs"))
            (should-not (ecc-session-init session))
            (should (equal (ecc-skill-names session) '("mine")))
            (should (equal (mapcar #'ecc-skill-name (ecc-skill-shown session))
                           '("mine"))))
        (delete-directory (expand-file-name ".claude" root) t)))))

(provide 'ecc-skill-test)

;;; ecc-skill-test.el ends here
