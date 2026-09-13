;;; ecc-plugin-test.el --- Tests for ecc-plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; The plugin browser.  No CLI is started: `ecc-plugin--call' is the one
;; place a subprocess comes from and is stood in for.  The answers are
;; what the real CLI printed on 2.1.270, in test/fixtures/plugin, with
;; the home directory of the machine they were taken on replaced.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-plugin)
(require 'ecc-prompt)

(defun ecc-plugin-test-fixture (name)
  "Return the contents of the plugin fixture called NAME."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents
       (expand-file-name (concat "fixtures/plugin/" name) ecc-test-directory)))
    (buffer-string)))

(defmacro ecc-plugin-test-with-cli (answers &rest body)
  "Run BODY with `ecc-plugin--call\\=' answering out of ANSWERS.
ANSWERS is an alist of the arguments, joined by a space, and the
\(EXIT . OUTPUT) to answer them with.  The calls that were made are left
in `calls\\=', newest last, and an unexpected one is an error rather
than a silence."
  (declare (indent 1) (debug (form body)))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'ecc-plugin--call)
                (lambda (args callback)
                  (setq calls (append calls (list args)))
                  (let ((answer (assoc (string-join args " ") ,answers)))
                    (unless answer
                      (error "The test did not expect %S" args))
                    (funcall callback (cadr answer) (cddr answer))))))
       ,@body)))

;;;; What the CLI says

(ert-deftest ecc-plugin-test-installed-is-parsed ()
  "`plugin list --json\\=' comes back as entries."
  (ecc-plugin-test-with-cli
      `(("plugin list --json" 0 . ,(ecc-plugin-test-fixture "list.json")))
    (let (entries error)
      (ecc-plugin-read-installed (lambda (value message)
                                   (setq entries value error message)))
      (should-not error)
      (should (equal calls '(("plugin" "list" "--json"))))
      (should (= (length entries) 2))
      (let ((bridge (car entries)))
        (should (equal (ecc-plugin-entry-name bridge) "emacs-bridge"))
        (should (equal (ecc-plugin-entry-marketplace bridge)
                       "emacs-gravity-marketplace"))
        (should (equal (ecc-plugin-entry-version bridge) "4.6.2"))
        (should (equal (ecc-plugin-entry-scope bridge) "user"))
        (should (ecc-plugin-entry-installed bridge))))))

(ert-deftest ecc-plugin-test-json-false-is-disabled ()
  "A JSON false `enabled\\=' is read as off, not as a symbol that is true."
  (let ((entries (ecc-plugin-parse-installed
                  (ecc-plugin-test-fixture "list.json"))))
    (should-not (ecc-plugin-entry-enabled (car entries)))
    (should (ecc-plugin-entry-enabled (cadr entries)))))

(ert-deftest ecc-plugin-test-catalog-is-parsed ()
  "`plugin list --available --json\\=' carries the descriptions and the counts."
  (let* ((entries (ecc-plugin-parse-catalog
                   (ecc-plugin-test-fixture "available.json")))
         (design (seq-find (lambda (entry)
                             (equal (ecc-plugin-entry-name entry)
                                    "frontend-design"))
                           entries)))
    (should (= (length entries) 4))
    (should (equal (ecc-plugin-entry-marketplace design)
                   "claude-plugins-official"))
    (should (= (ecc-plugin-entry-installs design) 1245390))
    (should (string-prefix-p "Create distinctive"
                             (ecc-plugin-entry-description design)))))

(ert-deftest ecc-plugin-test-catalog-knows-what-is-installed ()
  "An offered plugin that is already in carries its version and scope."
  (let* ((entries (ecc-plugin-parse-catalog
                   (ecc-plugin-test-fixture "available.json")))
         (design (seq-find #'ecc-plugin-entry-installed entries))
         (fresh (seq-find (lambda (entry)
                            (equal (ecc-plugin-entry-name entry) "superpowers"))
                          entries)))
    (should (equal (ecc-plugin-entry-name design) "frontend-design"))
    (should (equal (ecc-plugin-entry-version design) "1.2.0"))
    (should (equal (ecc-plugin-entry-scope design) "project"))
    (should-not (ecc-plugin-entry-installed fresh))
    (should-not (ecc-plugin-entry-version fresh))))

(ert-deftest ecc-plugin-test-catalog-keeps-an-orphan ()
  "An installed plugin no marketplace offers any more is still listed.
It is on the machine, so it has to be manageable; it comes last."
  (let* ((entries (ecc-plugin-parse-catalog
                   (ecc-plugin-test-fixture "available.json")))
         (last (car (last entries))))
    (should (equal (ecc-plugin-entry-name last) "emacs-bridge"))
    (should (ecc-plugin-entry-installed last))))

(ert-deftest ecc-plugin-test-marketplaces-are-parsed ()
  "`marketplace list --json\\=' comes back as marketplaces."
  (let ((markets (ecc-plugin-parse-marketplaces
                  (ecc-plugin-test-fixture "marketplaces.json"))))
    (should (= (length markets) 2))
    (should (equal (ecc-plugin-market-name (car markets))
                   "claude-plugins-official"))
    (should (equal (ecc-plugin-market-repo (car markets))
                   "anthropics/claude-plugins-official"))
    (should (equal (ecc-plugin-market-source (car markets)) "github"))))

(ert-deftest ecc-plugin-test-details-come-back-as-text ()
  "`plugin details\\=' has no --json, so its text is kept as it is."
  (ecc-plugin-test-with-cli
      `(("plugin details emacs-bridge" 0
         . ,(ecc-plugin-test-fixture "details.txt")))
    (let (text error)
      (ecc-plugin-read-details "emacs-bridge"
                               (lambda (value message)
                                 (setq text value error message)))
      (should-not error)
      (should (string-prefix-p "emacs-bridge 4.6.2" text))
      (should (string-match-p "Projected token cost" text)))))

;;;; When it goes wrong

(ert-deftest ecc-plugin-test-a-failed-read-is-reported ()
  "Output that is not JSON is an error with the command in it, not a nil."
  (ecc-plugin-test-with-cli
      '(("plugin list --json" 1 . "claude: command not found\n"))
    (let (entries error)
      (ecc-plugin-read-installed (lambda (value message)
                                   (setq entries value error message)))
      (should-not entries)
      (should (string-match-p "plugin list --json failed (1)" error))
      (should (string-match-p "command not found" error)))))

(ert-deftest ecc-plugin-test-a-warning-before-the-json-is-skipped ()
  "A line the CLI prints before its answer does not hide the answer."
  (let ((entries (ecc-plugin-parse-installed
                  (concat "Warning: something\n"
                          (ecc-plugin-test-fixture "list.json")))))
    (should (= (length entries) 2))))

;;;; The buffer

(defmacro ecc-plugin-test-in-buffer (&rest body)
  "Run BODY in a plugin browser filled from the fixtures.
The CLI is never asked: the reads are put in place by hand, which is
also what keeps the drawing tests away from the plugins of the machine
the tests run on."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ecc-plugin--call)
              (lambda (args _callback)
                (error "The test did not expect a subprocess: %S" args))))
     (with-temp-buffer
       (ecc-plugin-mode)
       (setq ecc-plugin--installed
             (ecc-plugin-parse-installed (ecc-plugin-test-fixture "list.json")))
       (setq ecc-plugin--catalog
             (ecc-plugin-parse-catalog
              (ecc-plugin-test-fixture "available.json")))
       (setq ecc-plugin--markets
             (ecc-plugin-parse-marketplaces
              (ecc-plugin-test-fixture "marketplaces.json")))
       ,@body)))

(defun ecc-plugin-test-text ()
  "Return the drawn buffer, without its faces."
  (buffer-substring-no-properties (point-min) (point-max)))

(ert-deftest ecc-plugin-test-discover-is-drawn ()
  "The Discover tab lists what the marketplaces offer."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'discover)
    (should (ecc-test-snapshot "plugin-discover" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-installed-is-drawn ()
  "The Installed tab groups by scope and says what is on and what is off."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'installed)
    (should (ecc-test-snapshot "plugin-installed" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-marketplaces-are-drawn ()
  "The Marketplaces tab lists what each one is."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'marketplaces)
    (should (ecc-test-snapshot "plugin-marketplaces" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-a-plugin-off-in-ecc-is-marked-apart ()
  "A plugin `ecc-disabled-plugins' turns off is not one the CLI disabled."
  (ecc-plugin-test-in-buffer
    (let ((ecc-disabled-plugins '("frontend-design@claude-plugins-official")))
      (ecc-plugin--show-tab 'installed)
      (should (string-match-p "on, off in ecc" (ecc-plugin-test-text)))
      ;; The one the CLI has disabled says nothing of the sort.
      (should (string-match-p "emacs-bridge.*\n?" (ecc-plugin-test-text)))
      (should (= 1 (cl-count-if
                    (lambda (line) (string-match-p "off in ecc" line))
                    (split-string (ecc-plugin-test-text) "\n")))))))

(ert-deftest ecc-plugin-test-the-filter-narrows-the-rows ()
  "The filter keeps the rows its string is part of."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'discover)
    (ecc-plugin-set-filter "superpowers")
    (let ((text (ecc-plugin-test-text)))
      (should (string-match-p "Discover plugins (1)" text))
      (should (string-match-p "superpowers" text))
      (should-not (string-match-p "context7" text)))
    (ecc-plugin-set-filter "")
    (should (string-match-p "Discover plugins (4)" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-the-filter-reads-the-descriptions ()
  "A word of the description finds the plugin as well as its name does."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'discover)
    (ecc-plugin-set-filter "documentation lookup")
    (should (string-match-p "context7" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-tabs-go-round ()
  "TAB walks the tabs and comes back to the first."
  (ecc-plugin-test-in-buffer
    (should (eq ecc-plugin--tab 'discover))
    (ecc-plugin-next-tab)
    (should (eq ecc-plugin--tab 'installed))
    (ecc-plugin-previous-tab)
    (should (eq ecc-plugin--tab 'discover))
    (ecc-plugin-previous-tab)
    (should (eq ecc-plugin--tab 'errors))
    (ecc-plugin-next-tab)
    (should (eq ecc-plugin--tab 'discover))))

(ert-deftest ecc-plugin-test-the-search-and-the-keys-are-on-screen ()
  "The buffer says that it can be searched and what its keys are.
Both were there before and neither was written down, so neither was
found."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'discover)
    (should (string-match-p "⌕ Search with s" (ecc-plugin-test-text)))
    (ecc-plugin-set-filter "superpowers")
    (should (string-match-p "⌕ superpowers" (ecc-plugin-test-text)))
    (ecc-plugin--show-tab 'marketplaces)
    (should (string-match-p "\\+ Add a marketplace" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-the-keys-are-in-the-header-line ()
  "The keys are in the header line, where a long list cannot scroll them off.
`format-mode-line' answers an empty string in batch, so the function
behind the header line is asked for its text."
  (ecc-plugin-test-in-buffer
    (should (equal header-line-format '(:eval (ecc-plugin-header-line))))
    (ecc-plugin--show-tab 'discover)
    (let ((line (ecc-plugin-header-line)))
      (should (string-match-p "s search · / jump" line))
      (should (string-match-p "SPC on/off" line))
      (should (string-match-p "q quit" line)))
    (ecc-plugin--show-tab 'installed)
    (should (string-match-p "E state" (ecc-plugin-header-line)))
    (ecc-plugin--show-tab 'marketplaces)
    (should (string-match-p "a add · u update · d remove"
                            (ecc-plugin-header-line)))
    ;; And they are not in the buffer any more, where they sat below 297
    ;; plugins and were never on the screen.
    (should-not (string-match-p "q quit" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-space-toggles-like-the-real-screen ()
  "SPC and e both toggle, and E sets a state by name."
  (should (eq (lookup-key ecc-plugin-mode-map (kbd "SPC")) #'ecc-plugin-toggle))
  (should (eq (lookup-key ecc-plugin-mode-map "e") #'ecc-plugin-toggle))
  (should (eq (lookup-key ecc-plugin-mode-map "E") #'ecc-plugin-set-state)))

(ert-deftest ecc-plugin-test-the-add-row-adds ()
  "RET on the add row runs the command, without having to know the key."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'marketplaces)
    (goto-char (point-min))
    (should (search-forward "Add a marketplace" nil t))
    (goto-char (match-beginning 0))
    (let (ran)
      (cl-letf (((symbol-function 'ecc-plugin-add-marketplace)
                 (lambda (&rest _) (interactive) (setq ran t))))
        (ecc-plugin-open)
        (should ran)))))

(ert-deftest ecc-plugin-test-jump-goes-to-the-row-it-is-given ()
  "Completion jumps to a row, and a filter hiding it is dropped."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'discover)
    (ecc-plugin-set-filter "context7")
    (should-not (string-match-p "superpowers" (ecc-plugin-test-text)))
    (ecc-plugin-jump "superpowers@claude-plugins-official")
    (should-not ecc-plugin--filter)
    (should (equal (ecc-plugin--id-at-point)
                   "superpowers@claude-plugins-official"))))

(ert-deftest ecc-plugin-test-jump-offers-every-row-of-the-tab ()
  "The candidates are the whole tab, not what the filter left."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'discover)
    (ecc-plugin-set-filter "context7")
    (should (= (length (ecc-plugin--rows)) 4))
    (should (assoc "superpowers@claude-plugins-official" (ecc-plugin--rows)))
    (should (string-match-p "Superpowers teaches"
                            (ecc-plugin--annotation
                             "superpowers@claude-plugins-official")))
    (ecc-plugin--show-tab 'marketplaces)
    (should (= (length (ecc-plugin--rows)) 2))))

(ert-deftest ecc-plugin-test-a-group-folds ()
  "A heading folds its group away and unfolds it again."
  (ecc-plugin-test-in-buffer
    (ecc-plugin--show-tab 'installed)
    (goto-char (point-min))
    (should (search-forward "user (1)" nil t))
    (goto-char (match-beginning 0))
    (ecc-plugin-toggle-fold)
    (should-not (string-match-p "emacs-bridge" (ecc-plugin-test-text)))
    (goto-char (point-min))
    (search-forward "user (1)")
    (goto-char (match-beginning 0))
    (ecc-plugin-toggle-fold)
    (should (string-match-p "emacs-bridge" (ecc-plugin-test-text)))))

(ert-deftest ecc-plugin-test-errors-name-what-went-wrong ()
  "The Errors tab holds the failed reads and the plugins that are gone."
  (ecc-plugin-test-in-buffer
    ;; The second one is where the tests are, so it is there; the first
    ;; one points into the home directory of another machine.
    (setf (ecc-plugin-entry-path (cadr ecc-plugin--installed)) ecc-test-directory)
    (setq ecc-plugin--errors '("claude plugin list --json failed (1): boom"))
    (ecc-plugin--show-tab 'errors)
    (let ((text (ecc-plugin-test-text)))
      (should (string-match-p "failed (1): boom" text))
      (should (string-match-p "emacs-bridge@emacs-gravity-marketplace is installed"
                              text))
      (should-not (string-match-p "frontend-design.* is installed, but" text)))))

(ert-deftest ecc-plugin-test-errors-are-empty-when-all-is-well ()
  "With nothing wrong the tab says so, like the real one."
  (ecc-plugin-test-in-buffer
    (setq ecc-plugin--installed nil)
    (ecc-plugin--show-tab 'errors)
    (should (string-match-p "No plugin errors" (ecc-plugin-test-text)))))

;;;; Skills

(defmacro ecc-plugin-test-with-skills (&rest body)
  "Run BODY with a skills directory and a settings file of its own.
Nothing of the machine the tests run on is read: the directories and the
settings file are variables, and they are bound to a temporary tree with
one user skill in it."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "ecc-plugin" t))
          (skills (expand-file-name "skills" root))
          (ecc-plugin-user-skills-directory skills)
          (ecc-plugin-user-settings-file
           (expand-file-name "settings.json" root))
          (project (expand-file-name "project" root)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "explain-diff-html" skills) t)
           (with-temp-file (expand-file-name "explain-diff-html/SKILL.md" skills)
             (insert "---\nname: explain-diff-html\n"
                     "description: Use when the user asks for a rich explanation.\n"
                     "---\n\n# Explain Diff\n"))
           (make-directory (expand-file-name ".claude/skills/local-notes" project) t)
           (with-temp-file (expand-file-name ".claude/skills/local-notes/SKILL.md"
                                             project)
             (insert "---\nname: local-notes\ndescription: Notes of this repo.\n---\n"))
           ,@body)
       (delete-directory root t))))

(defun ecc-plugin-test-skill (skills name)
  "Return the skill called NAME among SKILLS."
  (or (seq-find (lambda (skill) (equal (ecc-plugin-skill-name skill) name))
                skills)
      (error "No skill %s" name)))

(ert-deftest ecc-plugin-test-skills-are-found-on-the-disk ()
  "A skill is its directory, and its description is its frontmatter."
  (ecc-plugin-test-with-skills
    (let* ((skills (ecc-plugin-skills project))
           (mine (ecc-plugin-test-skill skills "explain-diff-html"))
           (theirs (ecc-plugin-test-skill skills "local-notes")))
      (should (eq (ecc-plugin-skill-scope mine) 'user))
      (should (string-match-p "rich explanation"
                              (ecc-plugin-skill-description mine)))
      (should (eq (ecc-plugin-skill-scope theirs) 'project))
      (should (ecc-plugin-skill-on-p mine)))))

(ert-deftest ecc-plugin-test-a-plugin-brings-its-skills ()
  "The skills of an installed plugin are listed, and say where they came from."
  (ecc-plugin-test-with-skills
    (let* ((installed (expand-file-name "cache/emacs-bridge" root))
           (plugin (ecc-plugin-entry-create
                    :id "emacs-bridge@emacs-gravity-marketplace"
                    :name "emacs-bridge" :installed t :path installed)))
      (make-directory (expand-file-name "skills/bridge-helper" installed) t)
      (with-temp-file (expand-file-name "skills/bridge-helper/SKILL.md" installed)
        (insert "---\nname: bridge-helper\ndescription: Helps.\n---\n"))
      (let ((skill (ecc-plugin-test-skill (ecc-plugin-skills project (list plugin))
                                          "bridge-helper")))
        (should (eq (ecc-plugin-skill-scope skill) 'plugin))
        (should (equal (ecc-plugin-skill-origin skill)
                       "emacs-bridge@emacs-gravity-marketplace"))))))

(ert-deftest ecc-plugin-test-an-override-turns-a-skill-off ()
  "`skillOverrides' in the settings is what says a skill is off."
  (ecc-plugin-test-with-skills
    (with-temp-file ecc-plugin-user-settings-file
      (insert "{\"skillOverrides\":{\"explain-diff-html\":\"off\"},\"model\":null}"))
    (let ((skill (ecc-plugin-test-skill (ecc-plugin-skills project)
                                        "explain-diff-html")))
      (should (equal (ecc-plugin-skill-state skill) "off"))
      (should-not (ecc-plugin-skill-on-p skill)))))

(ert-deftest ecc-plugin-test-the-most-restrictive-scope-wins ()
  "A project that turns a skill off is not undone by the user settings.
The CLI merges the scopes by taking the most restrictive of them, not
the nearest one (2.1.270)."
  (ecc-plugin-test-with-skills
    (with-temp-file ecc-plugin-user-settings-file
      (insert "{\"skillOverrides\":{\"local-notes\":\"name-only\"}}"))
    (with-temp-file (expand-file-name ".claude/settings.json" project)
      (insert "{\"skillOverrides\":{\"local-notes\":\"off\"}}"))
    (let ((skill (ecc-plugin-test-skill (ecc-plugin-skills project)
                                        "local-notes")))
      (should (equal (ecc-plugin-skill-state skill) "off"))
      (should (equal (ecc-plugin-skill-from skill)
                     (expand-file-name ".claude/settings.json" project))))))

(ert-deftest ecc-plugin-test-writing-an-override-keeps-the-rest ()
  "Turning a skill off leaves the other settings as they were.
A JSON null must come back as null: the ordinary reader turns it into
nil, which serializes back as an empty object and would rewrite the
model setting into one."
  (ecc-plugin-test-with-skills
    (with-temp-file ecc-plugin-user-settings-file
      (insert "{\"model\":\"opus\",\"env\":{},\"cleanupPeriodDays\":null,"
              "\"permissions\":{\"allow\":[\"Bash(ls:*)\"]}}"))
    (ecc-plugin-set-skill-state "explain-diff-html" "off")
    (let ((settings (ecc-plugin--read-settings ecc-plugin-user-settings-file)))
      (should (equal (alist-get 'model settings) "opus"))
      (should (eq (alist-get 'cleanupPeriodDays settings) :null))
      (should (equal (alist-get 'allow (alist-get 'permissions settings))
                     ["Bash(ls:*)"]))
      (should (equal (alist-get 'explain-diff-html
                                (alist-get 'skillOverrides settings))
                     "off")))
    ;; And turning it back on takes the entry away again.
    (ecc-plugin-set-skill-state "explain-diff-html" nil)
    (let ((settings (ecc-plugin--read-settings ecc-plugin-user-settings-file)))
      (should-not (alist-get 'explain-diff-html
                             (alist-get 'skillOverrides settings)))
      (should (equal (alist-get 'model settings) "opus")))))

(ert-deftest ecc-plugin-test-the-settings-file-is-left-tidy ()
  "The key is added at the end and taken away when it empties.
The file belongs to the user and to the CLI; it should not come back
reordered, nor carrying an empty object neither of them wrote."
  (ecc-plugin-test-with-skills
    (with-temp-file ecc-plugin-user-settings-file
      (insert "{\"model\":\"opus\",\"theme\":\"dark\"}"))
    (ecc-plugin-set-skill-state "explain-diff-html" "name-only")
    (should (equal (mapcar #'car (ecc-plugin--read-settings
                                  ecc-plugin-user-settings-file))
                   '(model theme skillOverrides)))
    (ecc-plugin-set-skill-state "explain-diff-html" nil)
    (should (equal (mapcar #'car (ecc-plugin--read-settings
                                  ecc-plugin-user-settings-file))
                   '(model theme)))))

(ert-deftest ecc-plugin-test-every-state-can-be-set ()
  "A skill takes the four states the CLI knows, not just on and off."
  (ecc-plugin-test-with-skills
    (dolist (state '("name-only" "user-invocable-only" "off"))
      (ecc-plugin-set-skill-state "explain-diff-html" state)
      (should (equal state
                     (ecc-plugin-skill-state
                      (ecc-plugin-test-skill (ecc-plugin-skills project)
                                             "explain-diff-html")))))
    (ecc-plugin-set-skill-state "explain-diff-html" nil)
    (should (ecc-plugin-skill-on-p
             (ecc-plugin-test-skill (ecc-plugin-skills project)
                                    "explain-diff-html")))))

(ert-deftest ecc-plugin-test-setting-a-state-says-when-a-project-wins ()
  "Setting a skill on while a project file turns it off says so."
  (ecc-plugin-test-with-skills
    (with-temp-file (expand-file-name ".claude/settings.json" project)
      (insert "{\"skillOverrides\":{\"explain-diff-html\":\"off\"}}"))
    (ecc-plugin-test-in-buffer
      (setq ecc-plugin--project project)
      (setq ecc-plugin--skills (ecc-plugin-skills project))
      (let ((said nil))
        (cl-letf (((symbol-function 'ecc-plugin-refresh)
                   (lambda () (setq ecc-plugin--skills
                                    (ecc-plugin-skills ecc-plugin--project))))
                  ((symbol-function 'message)
                   (lambda (format &rest args)
                     (setq said (apply #'format format args)))))
          (ecc-plugin-apply-skill-state
           (ecc-plugin-test-skill ecc-plugin--skills "explain-diff-html") "on")
          (should (string-match-p "makes it off" said)))))))

(ert-deftest ecc-plugin-test-a-settings-file-that-is-not-json-is-not-fatal ()
  "A settings file Emacs cannot read leaves the skills on."
  (ecc-plugin-test-with-skills
    (with-temp-file ecc-plugin-user-settings-file (insert "{ oops"))
    (should (ecc-plugin-skill-on-p
             (ecc-plugin-test-skill (ecc-plugin-skills project)
                                    "explain-diff-html")))))

(ert-deftest ecc-plugin-test-the-bundled-skills-come-from-a-session ()
  "A skill that is on no disk is named by system/init, and nowhere else."
  (ecc-plugin-test-with-skills
    (ecc-test-with-fake-session session
      (setf (ecc-session-init session)
            '((skills . ["explain-diff-html" "code-review" "dataviz"])))
      (let ((skills (ecc-plugin-skills project)))
        (should (eq (ecc-plugin-skill-scope
                     (ecc-plugin-test-skill skills "code-review"))
                    'built-in))
        ;; The one that is on the disk keeps the scope it was found at.
        (should (eq (ecc-plugin-skill-scope
                     (ecc-plugin-test-skill skills "explain-diff-html"))
                    'user))))))

(ert-deftest ecc-plugin-test-skills-and-plugins-share-the-installed-tab ()
  "Both kinds are drawn in one list, and the off ones are folded away."
  (ecc-plugin-test-with-skills
    (ecc-plugin-test-in-buffer
      (setq ecc-plugin--skills (ecc-plugin-skills project))
      (ecc-plugin--show-tab 'installed)
      (let ((text (ecc-plugin-test-text)))
        (should (string-match-p "explain-diff-html  Skill · user" text))
        (should (string-match-p "local-notes  Skill · project" text))
        (should (string-match-p "frontend-design  Plugin" text))
        (should (string-match-p "Show disabled (1)" text))
        (should (string-match-p "Installed (4)" text))))))

(ert-deftest ecc-plugin-test-the-filter-reaches-the-skills ()
  "The search narrows the skills of the Installed tab as well."
  (ecc-plugin-test-with-skills
    (ecc-plugin-test-in-buffer
      (setq ecc-plugin--skills (ecc-plugin-skills project))
      (ecc-plugin--show-tab 'installed)
      (ecc-plugin-set-filter "notes")
      (let ((text (ecc-plugin-test-text)))
        (should (string-match-p "local-notes" text))
        (should-not (string-match-p "frontend-design" text))))))

(ert-deftest ecc-plugin-test-toggling-a-skill-writes-the-override ()
  "`e' on a skill writes the override and reads everything again."
  (ecc-plugin-test-with-skills
    (ecc-plugin-test-in-buffer
      (setq ecc-plugin--project project)
      (setq ecc-plugin--skills (ecc-plugin-skills project))
      (ecc-plugin--show-tab 'installed)
      (cl-letf (((symbol-function 'ecc-plugin-refresh) #'ignore)
                ((symbol-function 'message) (lambda (&rest _) nil)))
        (ecc-plugin-toggle-skill
         (ecc-plugin-test-skill ecc-plugin--skills "explain-diff-html")))
      (should (equal "off"
                     (ecc-plugin-skill-state
                      (ecc-plugin-test-skill (ecc-plugin-skills project)
                                             "explain-diff-html")))))))

;;;; Acting

(defconst ecc-plugin-test--done
  "{\"command\":\"enable\",\"outcome\":\"success\",\
\"plugin\":\"emacs-bridge@emacs-gravity-marketplace\",\
\"message\":\"Enabled plugin \\\"emacs-bridge@emacs-gravity-marketplace\\\"\"}\n"
  "What an action answers when it went through.")

(defconst ecc-plugin-test--failed
  "{\"command\":\"install\",\"outcome\":\"failed\",\"plugin\":\"no-such\",\
\"scope\":\"user\",\"message\":\"Plugin \\\"no-such\\\" not found in marketplace\",\
\"failureCode\":\"not_found\"}\n"
  "What an action answers when it did not.
The CLI exits 1 while printing it (2.1.270).")

(defmacro ecc-plugin-test-acting (answers &rest body)
  "Run BODY in a filled browser, with the CLI answering out of ANSWERS.
The reads that follow an action answer out of the fixtures, so that only
the action itself has to be spelled out."
  (declare (indent 1) (debug (form body)))
  `(let ((calls nil)
         (messages nil))
     (cl-letf (((symbol-function 'ecc-plugin--call)
                (lambda (args callback)
                  (setq calls (append calls (list args)))
                  (let ((answer (or (assoc (string-join args " ") ,answers)
                                    (pcase (string-join args " ")
                                      ("plugin list --json"
                                       (cons nil (cons 0 (ecc-plugin-test-fixture
                                                          "list.json"))))
                                      ("plugin list --available --json"
                                       (cons nil (cons 0 (ecc-plugin-test-fixture
                                                          "available.json"))))
                                      ("plugin marketplace list --json"
                                       (cons nil (cons 0 (ecc-plugin-test-fixture
                                                          "marketplaces.json"))))))))
                    (unless answer
                      (error "The test did not expect %S" args))
                    (funcall callback (cadr answer) (cddr answer)))))
               ((symbol-function 'message)
                (lambda (format &rest args)
                  (push (apply #'format format args) messages)
                  nil))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
       (with-temp-buffer
         (ecc-plugin-mode)
         (setq ecc-plugin--installed
               (ecc-plugin-parse-installed (ecc-plugin-test-fixture "list.json")))
         (setq ecc-plugin--catalog
               (ecc-plugin-parse-catalog
                (ecc-plugin-test-fixture "available.json")))
         ,@body))))

(defun ecc-plugin-test-entry (name)
  "Return the entry called NAME of the catalog in this buffer."
  (or (seq-find (lambda (entry) (equal (ecc-plugin-entry-name entry) name))
                ecc-plugin--catalog)
      (error "No %s in the catalog" name)))

(ert-deftest ecc-plugin-test-install-passes-the-scope-and-yes ()
  "An install names the scope, and answers for the CLI, which has no TTY."
  (ecc-plugin-test-acting
      `(("plugin install superpowers@claude-plugins-official --json -y -s project"
         0 . ,ecc-plugin-test--done))
    (ecc-plugin-install (ecc-plugin-test-entry "superpowers") "project")
    (should (equal (car calls)
                   '("plugin" "install" "superpowers@claude-plugins-official"
                     "--json" "-y" "-s" "project")))))

(ert-deftest ecc-plugin-test-toggle-turns-it-the-other-way ()
  "A plugin that is off is enabled, and one that is on is disabled."
  (ecc-plugin-test-acting
      `(("plugin enable emacs-bridge@emacs-gravity-marketplace --json"
         0 . ,ecc-plugin-test--done)
        ("plugin disable frontend-design@claude-plugins-official --json"
         0 . ,ecc-plugin-test--done))
    (ecc-plugin-toggle-plugin (car ecc-plugin--installed))
    (should (equal (car calls)
                   '("plugin" "enable" "emacs-bridge@emacs-gravity-marketplace"
                     "--json")))
    (setq calls nil)
    (ecc-plugin-toggle-plugin (cadr ecc-plugin--installed))
    (should (equal (car calls)
                   '("plugin" "disable" "frontend-design@claude-plugins-official"
                     "--json")))))

(ert-deftest ecc-plugin-test-uninstall-keeps-to-the-scope-it-is-in ()
  "An uninstall names the scope the plugin was installed at."
  (ecc-plugin-test-acting
      `(("plugin uninstall frontend-design@claude-plugins-official --json -y -s project"
         0 . ,ecc-plugin-test--done))
    (ecc-plugin-uninstall (cadr ecc-plugin--installed))
    (should (equal (car calls)
                   '("plugin" "uninstall" "frontend-design@claude-plugins-official"
                     "--json" "-y" "-s" "project")))))

(ert-deftest ecc-plugin-test-a-plugin-that-is-not-in-cannot-be-toggled ()
  "Enabling something that is not installed is a `user-error', not a call."
  (ecc-plugin-test-acting nil
    (should-error (ecc-plugin-toggle-plugin (ecc-plugin-test-entry "superpowers"))
                  :type 'user-error)
    (should-not calls)))

(ert-deftest ecc-plugin-test-a-failed-action-is-kept-and-shown ()
  "A failure is reported and left in the Errors tab, not swallowed."
  (ecc-plugin-test-acting
      `(("plugin install superpowers@claude-plugins-official --json -y -s user"
         1 . ,ecc-plugin-test--failed))
    (ecc-plugin-install (ecc-plugin-test-entry "superpowers") "user")
    (should (seq-find (lambda (line) (string-match-p "not found in marketplace" line))
                      messages))
    (should (= (length ecc-plugin--errors) 1))
    (ecc-plugin--show-tab 'errors)
    (should (string-match-p "not found in marketplace" (ecc-plugin-test-text)))
    ;; Nothing was read again: the plugins did not change.
    (should (equal calls '(("plugin" "install"
                            "superpowers@claude-plugins-official"
                            "--json" "-y" "-s" "user"))))))

(ert-deftest ecc-plugin-test-a-marketplace-is-added-and-removed ()
  "The marketplace subcommands have no --json, so their text is the answer."
  (ecc-plugin-test-acting
      '(("plugin marketplace add owner/repo --scope user"
         0 . "Adding marketplace…\nAdded marketplace: owner/repo\n")
        ("plugin marketplace remove owner-repo" 0 . "Removed\n"))
    (ecc-plugin-add-marketplace "owner/repo" "user")
    (should (equal (car calls)
                   '("plugin" "marketplace" "add" "owner/repo" "--scope" "user")))
    (should (seq-find (lambda (line) (string-match-p "Added marketplace" line))
                      messages))
    (ecc-plugin-remove-marketplace
     (ecc-plugin-market-create :name "owner-repo"))
    (should (member '("plugin" "marketplace" "remove" "owner-repo") calls))))

(ert-deftest ecc-plugin-test-text-without-json-goes-by-the-exit-code ()
  "A subcommand with no --json is believed when it exits 0.
`marketplace update' prints its progress and its verdict as text and has
no JSON to read; taking the missing JSON for a failure called a
marketplace that had just been updated an error (2.1.270)."
  (ecc-plugin-test-acting
      '(("plugin marketplace update emacs-gravity-marketplace"
         0 . "Updating marketplace: emacs-gravity-marketplace...\n\
✔ Successfully updated marketplace: emacs-gravity-marketplace\n"))
    (ecc-plugin-update-marketplace
     (ecc-plugin-market-create :name "emacs-gravity-marketplace"))
    (should-not ecc-plugin--errors)
    (should (seq-find (lambda (line)
                        (string-match-p "Successfully updated" line))
                      messages))))

(ert-deftest ecc-plugin-test-the-sessions-are-told-to-reload ()
  "Every running session is sent /reload-plugins, not just the first."
  (ecc-test-with-fake-session a
    (let ((b (ecc-model-create-session :name "other"
                                       :project-root temporary-file-directory))
          (ecc-plugin-reload-sessions t))
      (unwind-protect
          (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
            (ecc-plugin-tell-sessions)
            (should (equal (ecc-test-sent-text 0) "/reload-plugins"))
            (should (equal (ecc-test-sent-text 1) "/reload-plugins"))
            (should (= (length (ecc-test-sent-messages)) 2)))
        (ecc-test-cleanup-session b)))))

(ert-deftest ecc-plugin-test-the-sessions-are-left-alone-when-told-to ()
  "Nil means nothing is sent and nothing is asked."
  (ecc-test-with-fake-session a
    (let ((ecc-plugin-reload-sessions nil))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "It should not have asked"))))
        (ecc-plugin-tell-sessions)
        (should-not (ecc-test-sent-messages))))))

;;;; One plugin

(ert-deftest ecc-plugin-test-a-plugin-describes-itself ()
  "The description carries what it is, what it brings and the warning."
  (ecc-plugin-test-acting
      `(("plugin details emacs-bridge" 0 . ,(ecc-plugin-test-fixture
                                             "details.txt")))
    (let ((buffer (ecc-plugin-describe (car ecc-plugin--installed))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "emacs-bridge" text))
              (should (string-match-p "emacs-gravity-marketplace" text))
              (should (string-match-p "Component inventory" text))
              (should (string-match-p "Make sure you trust a plugin" text))))
        (kill-buffer buffer)))))

;;;; The way in: the prompt region

(ert-deftest ecc-plugin-test-slash-plugins-is-answered-here ()
  "`/plugins' opens the browser and is not sent to the model.
The CLI names it in neither `slash_commands' nor
`terminal_slash_commands', so a draft that was sent would reach the
model as a sentence."
  (ecc-test-with-fake-session session
    (let (opened)
      (cl-letf (((symbol-function 'ecc-plugin)
                 (lambda (&optional filter) (setq opened (list filter)))))
        (dolist (text '("/plugins" "/plugin" "  /plugins  "))
          (setq opened nil)
          (should (ecc-plugin-intercept session text))
          (should opened))
        (should-not (ecc-plugin-intercept session "/plug"))
        (should-not (ecc-plugin-intercept session "what plugins are there?"))))
    (should-not (ecc-test-sent-messages))))

(ert-deftest ecc-plugin-test-slash-plugins-passes-its-argument-as-the-filter ()
  "What follows the command narrows the rows."
  (ecc-test-with-fake-session session
    (let (filter)
      (cl-letf (((symbol-function 'ecc-plugin)
                 (lambda (&optional argument) (setq filter argument))))
        (ecc-plugin-intercept session "/plugins mcp")
        (should (equal filter "mcp"))))))

(ert-deftest ecc-plugin-test-slash-plugins-is-offered-in-the-prompt ()
  "The command is in the list the prompt completes and the menu shows."
  (should (assoc "/plugins" ecc-prompt-local-commands))
  (ecc-test-with-fake-session session
    (should (assoc "/plugins" (ecc-prompt-commands session)))))

(ert-deftest ecc-plugin-test-the-intercept-is-installed ()
  "Loading the module puts the intercept on the hook."
  (should (memq #'ecc-plugin-intercept ecc-prompt-intercept-functions)))

(ert-deftest ecc-plugin-test-a-draft-is-not-sent-when-it-is-answered ()
  "`ecc-prompt-send' stops at the intercept: nothing reaches the CLI."
  (ecc-test-with-fake-session session
    (cl-letf (((symbol-function 'ecc-plugin) (lambda (&optional _) nil)))
      (should (eq (run-hook-with-args-until-success
                   'ecc-prompt-intercept-functions session "/plugins")
                  t))
      (should-not (ecc-test-sent-messages)))))

(provide 'ecc-plugin-test)

;;; ecc-plugin-test.el ends here
