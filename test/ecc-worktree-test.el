;;; ecc-worktree-test.el --- Tests for ecc-worktree  -*- lexical-binding: t; -*-

;;; Commentary:

;; The porcelain parser, the slug and the path as pure functions, and
;; the create/list/remove round trip against a throwaway repository.
;; git is not a dependency of this package, so every case that runs one
;; is skipped where there is none.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecc-test-helpers)
(require 'ecc-dispatch)
(require 'ecc-worktree)
;; Loaded here rather than by the command under test: `ecc-start' is
;; replaced with `cl-letf', and a `require' inside the command would put
;; the real one back on top of the replacement.
(require 'ecc)
(require 'ecc-review-pr)

;;;; Helpers

(defmacro ecc-worktree-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards.
The cache is fresh as well: a test must not see what an earlier one
asked git."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-worktree" t)))
         (ecc-worktree--cache (make-hash-table :test #'equal))
         (ecc-worktree--offers-pending nil))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun ecc-worktree-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, failing the test when it fails."
  (let ((result (apply #'ecc-worktree--git directory
                       (append '("-c" "user.name=t" "-c" "user.email=t@example.com"
                                 "-c" "init.defaultBranch=main"
                                 "-c" "protocol.file.allow=always")
                               args))))
    (unless (and result (= (car result) 0))
      (ert-fail (format "git %s failed: %S" args result)))
    (cdr result)))

(defun ecc-worktree-test--repository (directory)
  "Make DIRECTORY a git repository with one commit in it."
  (ecc-worktree-test--git directory "init" "-q" ".")
  (with-temp-file (expand-file-name "a.txt" directory) (insert "one\n"))
  (ecc-worktree-test--git directory "add" "a.txt")
  (ecc-worktree-test--git directory "commit" "-q" "-m" "init"))

;;;; The porcelain

(defconst ecc-worktree-test--porcelain
  "worktree /repo
HEAD ec667d1aa8b60eedc6a3ba1d1a262840557c4990
branch refs/heads/release/0.2.0

worktree /repo/.claude/worktrees/feat+plugins
HEAD 006f20b778576e792d506211403321fa06310243
branch refs/heads/fix/plugin-review
locked claude session feat/plugins

worktree /repo/.claude/worktrees/loose
HEAD 8b3f9adef95086802cc9c5279082163492fe7a63
detached

worktree /repo/.claude/worktrees/gone
HEAD 077314722c14c2f0a166cde3a878571e696e1793
branch refs/heads/old
prunable gitdir file points to non-existent location
"
  "What `git worktree list --porcelain' looks like, with every attribute.")

(ert-deftest ecc-worktree-test-parse ()
  "Every record of the porcelain becomes an entry, the main one first."
  (let ((entries (ecc-worktree-parse ecc-worktree-test--porcelain)))
    (should (= 4 (length entries)))
    (should (equal (mapcar #'ecc-worktree-entry-path entries)
                   '("/repo/" "/repo/.claude/worktrees/feat+plugins/"
                     "/repo/.claude/worktrees/loose/"
                     "/repo/.claude/worktrees/gone/")))
    (should (equal (mapcar #'ecc-worktree-entry-branch entries)
                   '("release/0.2.0" "fix/plugin-review" nil "old")))
    (should (equal (mapcar (lambda (entry)
                             (and (ecc-worktree-entry-main-p entry) t))
                           entries)
                   '(t nil nil nil)))
    (should (ecc-worktree-entry-detached-p (nth 2 entries)))
    (should-not (ecc-worktree-entry-detached-p (nth 1 entries)))
    (should (equal (ecc-worktree-entry-prunable-p (nth 3 entries))
                   "gitdir file points to non-existent location"))
    (should-not (ecc-worktree-entry-prunable-p (car entries)))))

(ert-deftest ecc-worktree-test-parse-empty ()
  "Nothing to parse is no worktrees rather than an error."
  (should-not (ecc-worktree-parse ""))
  (should-not (ecc-worktree-parse nil)))

;;;; The slug and the path

(ert-deftest ecc-worktree-test-slug ()
  "A branch becomes a directory name the way herdr makes one."
  (should (equal (ecc-worktree-slug "feat/x y") "feat-x-y"))
  (should (equal (ecc-worktree-slug "worktree/brave-river-0a1f")
                 "worktree-brave-river-0a1f"))
  (should (equal (ecc-worktree-slug "Feat/UPPER") "feat-upper"))
  (should (equal (ecc-worktree-slug "--") "worktree"))
  (should (equal (ecc-worktree-slug "") "worktree"))
  (should (equal (ecc-worktree-slug "/lead/and/trail/") "lead-and-trail")))

(ert-deftest ecc-worktree-test-path ()
  "A relative directory hangs off the repository, an absolute one is shared."
  (let ((ecc-worktree-directory ".claude/worktrees"))
    (should (equal (ecc-worktree-path "/repo/" "feat/x")
                   "/repo/.claude/worktrees/feat-x/")))
  (let ((ecc-worktree-directory "~/.ecc/worktrees"))
    (should (equal (ecc-worktree-path "/repo/" "feat/x")
                   (expand-file-name "~/.ecc/worktrees/repo/feat-x/"))))
  (let ((ecc-worktree-directory "/var/tmp/wt"))
    (should (equal (ecc-worktree-path "/some/repo/" "main")
                   "/var/tmp/wt/repo/main/"))))

;;;; Against a real repository

(ert-deftest ecc-worktree-test-create-list-remove ()
  "A worktree is added, listed under its parent, and taken away again."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (path (ecc-worktree-create directory "feat/x")))
      (should (file-directory-p path))
      (should (equal path (ecc-worktree-path directory "feat/x")))
      (let ((entries (ecc-worktree-list directory)))
        (should (= 2 (length entries)))
        (should (ecc-worktree-entry-main-p (car entries)))
        (should (equal (ecc-worktree-entry-branch (nth 1 entries)) "feat/x")))
      ;; The point of the whole file: a linked worktree knows its parent
      ;; and the main worktree has none.
      (should (equal (file-truename (ecc-worktree-main path))
                     (file-truename directory)))
      (should-not (ecc-worktree-main directory))
      (should (equal (ecc-worktree-branch path) "feat/x"))
      (should (equal (ecc-worktree-branch directory) "main"))
      (should (member "feat/x" (ecc-worktree-branches directory)))
      (ecc-worktree-remove path)
      (should-not (file-directory-p path))
      (should (= 1 (length (ecc-worktree-list directory))))
      ;; The branch outlives the worktree.
      (should (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-create-refuses-twice ()
  "A directory that is there already is not written over."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let ((ecc-worktree-directory ".claude/worktrees"))
      (ecc-worktree-create directory "feat/x")
      (should-error (ecc-worktree-create directory "feat/x") :type 'user-error)
      ;; And a branch git will not make is git's refusal, not silence.
      (should-error (ecc-worktree-create directory "feat/x/deeper")
                    :type 'user-error))))

(ert-deftest ecc-worktree-test-nothing-outside-a-repository ()
  "A directory that is not in a repository answers nil to everything."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (should-not (ecc-worktree-list directory))
    (should-not (ecc-worktree-main directory))
    (should-not (ecc-worktree-branch directory))
    (should-not (ecc-worktree-ahead-behind directory))))

(ert-deftest ecc-worktree-test-ahead-behind ()
  "The counts are ahead first, and a branch with no upstream has none.
This is what pins down which side of `rev-list --left-right' is which."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (let ((upstream (expand-file-name "up" directory))
          (clone (file-name-as-directory (expand-file-name "down" directory))))
      (make-directory upstream)
      (ecc-worktree-test--repository upstream)
      (ecc-worktree-test--git directory "clone" "-q" upstream "down")
      ;; Two commits on the upstream, one here: behind 2, ahead 1.
      (ecc-worktree-test--git upstream "commit" "-q" "--allow-empty" "-m" "u1")
      (ecc-worktree-test--git upstream "commit" "-q" "--allow-empty" "-m" "u2")
      (ecc-worktree-test--git clone "fetch" "-q")
      (ecc-worktree-test--git clone "commit" "-q" "--allow-empty" "-m" "d1")
      (should (equal (ecc-worktree-ahead-behind clone) '(1 . 2)))
      ;; A branch nobody has pushed has no upstream to count against.
      (ecc-worktree-test--git clone "checkout" "-q" "-b" "local-only")
      (clrhash ecc-worktree--cache)
      (should-not (ecc-worktree-ahead-behind clone)))))

(ert-deftest ecc-worktree-test-cache ()
  "An answer is reused until it is forgotten."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (should (equal (ecc-worktree-branch directory) "main"))
    (ecc-worktree-test--git directory "checkout" "-q" "-b" "other")
    (should (equal (ecc-worktree-branch directory) "main"))
    (ecc-worktree-forget)
    (should (equal (ecc-worktree-branch directory) "other"))
    ;; And the clock lets go of it on its own.
    (let ((ecc-worktree--cache-ttl -1))
      (ecc-worktree-test--git directory "checkout" "-q" "-b" "third")
      (should (equal (ecc-worktree-branch directory) "third")))))

;;;; The commands

(ert-deftest ecc-worktree-test-start-worktree ()
  "`ecc-start-worktree' starts the session in the worktree it made."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      (let ((ecc-worktree-directory ".claude/worktrees")
            (started nil))
        (cl-letf (((symbol-function #'ecc-start)
                   (lambda (&optional path &rest _)
                     (setq started path)
                     session))
                  ((symbol-function #'ecc-window-context-project-root)
                   (lambda () directory)))
          (ecc-start-worktree "feat/x")
          (should (equal started (ecc-worktree-path directory "feat/x")))
          (should (file-directory-p started)))))))

(ert-deftest ecc-worktree-test-start-worktree-goes-to-the-branch-it-finds ()
  "A branch that is checked out already is gone to rather than refused.
git allows one branch in one worktree at a time, and the worktree that
has it need not be named the way this package would have named it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      ;; Checked out under a name of somebody else's choosing, the way
      ;; Claude Code's own worktrees are.
      (let ((elsewhere (expand-file-name "elsewhere" directory)))
        (ecc-worktree-test--git directory "worktree" "add" "-b" "feat/x"
                                elsewhere)
        (clrhash ecc-worktree--cache)
        (let ((ecc-worktree-directory ".claude/worktrees")
              (started nil))
          (cl-letf (((symbol-function #'ecc-start)
                     (lambda (&optional path &rest _) (setq started path) session))
                    ((symbol-function #'ecc-window-context-project-root)
                     (lambda () directory))
                    ((symbol-function #'yes-or-no-p) (lambda (&rest _) t)))
            (ecc-start-worktree "feat/x")
            (should (equal (file-truename started)
                           (file-truename (file-name-as-directory elsewhere))))
            ;; Nothing was made where this package would have put one.
            (should-not (file-exists-p (ecc-worktree-path directory "feat/x")))
            ;; And saying no leaves everything alone.
            (cl-letf (((symbol-function #'yes-or-no-p) (lambda (&rest _) nil)))
              (should-error (ecc-start-worktree "feat/x") :type 'user-error))
            ;; The branch of the repository itself is not a worktree to go to.
            (should-error (ecc-start-worktree (ecc-worktree-branch directory))
                          :type 'user-error)))))))

(ert-deftest ecc-worktree-test-delegate ()
  "`ecc-worktree-delegate' makes the worktree, starts a session and briefs it."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      (let ((ecc-worktree-directory ".claude/worktrees")
            (started nil)
            (sent nil))
        (cl-letf (((symbol-function #'ecc-start)
                   (lambda (&optional path &rest _) (setq started path) session))
                  ((symbol-function #'ecc-proc-send-prompt)
                   (lambda (_session text) (setq sent text) 'sent)))
          (should (eq session (ecc-worktree-delegate
                               directory "feat/x" "Make the tests pass")))
          (should (equal started (ecc-worktree-path directory "feat/x")))
          (should (file-directory-p started))
          ;; The brief is what the new session is told, and it is told
          ;; where it is: the transcript it came from is not there to read.
          (should (string-match-p "Make the tests pass" sent))
          (should (string-match-p "feat/x" sent))
          (should (string-match-p (regexp-quote (abbreviate-file-name started))
                                  sent))
          ;; Nothing to hand over is not a session to start.
          (should-error (ecc-worktree-delegate directory "feat/y" "  ")
                        :type 'user-error)
          (should-not (file-exists-p (ecc-worktree-path directory "feat/y")))
          ;; And a branch another worktree holds is refused rather than
          ;; gone to: two sessions in one tree is not handing work over.
          (clrhash ecc-worktree--cache)
          (should-error (ecc-worktree-delegate directory "feat/x" "again")
                        :type 'user-error))))))

(ert-deftest ecc-worktree-test-delegate-from-a-worktree-and-a-base ()
  "The worktree is made beside the main one, from the base given."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      (ecc-worktree-test--git directory "branch" "base-here")
      (let* ((ecc-worktree-directory ".claude/worktrees")
             (inside (ecc-worktree-create directory "feat/inside"))
             (started nil))
        (cl-letf (((symbol-function #'ecc-start)
                   (lambda (&optional path &rest _) (setq started path) session))
                  ((symbol-function #'ecc-proc-send-prompt)
                   (lambda (&rest _) 'sent)))
          ;; Asked from inside a worktree: a worktree of a worktree is
          ;; not a thing, so it hangs off the repository.
          (ecc-worktree-delegate inside "feat/x" "work" "base-here")
          ;; Through `file-truename': git resolves the symbolic links of
          ;; the path it is given and the temporary directory is one.
          (should (equal (file-truename started)
                         (file-truename (ecc-worktree-path directory "feat/x"))))
          (should (equal (ecc-worktree-branch started) "feat/x")))))))

(ert-deftest ecc-worktree-test-mcp-tool ()
  "The tool is published, and it works in the project of the session calling."
  (skip-unless (executable-find "git"))
  (require 'ecc-mcp)
  (ecc-worktree-register-mcp-tool)
  (should (ecc-mcp-tool "start_worktree_session"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      (setf (ecc-session-project-root session) directory
            (ecc-session-cwd session) directory)
      (let ((ecc-worktree-directory ".claude/worktrees")
            (ecc-mcp--session-id (ecc-session-id session))
            (started nil)
            (sent nil))
        (cl-letf (((symbol-function #'ecc-start)
                   (lambda (&optional path &rest _) (setq started path) session))
                  ((symbol-function #'ecc-proc-send-prompt)
                   (lambda (_session text) (setq sent text) 'sent)))
          (let ((answer (ecc-worktree-mcp-delegate "feat/x" "Write the docs")))
            (should (equal started (ecc-worktree-path directory "feat/x")))
            (should (string-match-p "Write the docs" sent))
            ;; The session that asked is named to the one that gets it.
            (should (string-match-p (regexp-quote (ecc-session-name session))
                                    sent))
            (should (string-match-p "feat/x" answer))
            (should (string-match-p (regexp-quote (ecc-session-name session))
                                    answer))))))))

(ert-deftest ecc-worktree-test-handoff-facts ()
  "The brief carries what Emacs watched the conversation do."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      (setf (ecc-session-project-root session) directory
            (ecc-session-cwd session) directory)
      ;; What the conversation touched, where its plan went, and a file
      ;; that was never committed.
      (ecc-model-note-file session (expand-file-name "a.txt" directory) 'edit)
      (ecc-model-note-file session (expand-file-name "a.txt" directory) 'edit)
      (ecc-model-note-file session
                           (expand-file-name "test/b.txt" directory) 'read)
      (ecc-model-note-plan-file session "/tmp/plans/ecc-plan.md")
      (with-temp-file (expand-file-name "loose.txt" directory) (insert "x\n"))
      (let ((ecc-worktree-directory ".claude/worktrees")
            (ecc-mcp--session-id (ecc-session-id session))
            (sent nil))
        (cl-letf (((symbol-function #'ecc-start)
                   (lambda (&optional path &rest _)
                     (ignore path)
                     session))
                  ((symbol-function #'ecc-proc-send-prompt)
                   (lambda (_session text) (setq sent text) 'sent))
                  ((symbol-function #'ecc-history-file)
                   (lambda (_id) "/tmp/history/session.jsonl")))
          (ecc-worktree-mcp-delegate "feat/x" "Finish the parser")
          ;; The brief the model wrote comes first, and the facts follow.
          (should (string-match-p "Finish the parser" sent))
          ;; Paths are the ones the new worktree has, not absolute ones.
          (should (string-match-p "^- a\\.txt (2 edits)$" sent))
          (should (string-match-p "^- test/b\\.txt (1 reads)$" sent))
          ;; The header names the repository; the file list does not.
          (should-not (string-match-p (concat "- " (regexp-quote directory))
                                      sent))
          (should (string-match-p "/tmp/plans/ecc-plan\\.md" sent))
          (should (string-match-p "/tmp/history/session\\.jsonl" sent))
          ;; And what the worktree will not have, because HEAD does not.
          (should (string-match-p "Not in this worktree" sent))
          (should (string-match-p "loose\\.txt" sent)))))))

(ert-deftest ecc-worktree-test-handoff-facts-says-nothing-of-nothing ()
  "A session that touched nothing, in a clean tree, adds no section."
  (skip-unless (executable-find "git"))
  (ecc-test-with-fake-session session
    (ecc-worktree-test--with-directory directory
      (ecc-worktree-test--repository directory)
      (setf (ecc-session-project-root session) directory)
      (cl-letf (((symbol-function #'ecc-history-file) (lambda (_id) nil)))
        (should (equal "" (ecc-worktree-handoff-facts session directory)))))))

(defun ecc-worktree-test--request (tool input)
  "Return a can_use_tool control_request for TOOL with INPUT."
  `((type . "control_request")
    (request_id . ,(format "req-%s" (random 100000)))
    (request . ((subtype . "can_use_tool")
                (tool_name . ,tool)
                (display_name . ,tool)
                (input . ,input)
                (tool_use_id . "toolu_x")))))

(defun ecc-worktree-test--denials ()
  "Return the messages of the denies sent so far."
  (delq nil
        (mapcar (lambda (message)
                  (let ((response (alist-get 'response
                                             (alist-get 'response message))))
                    (and (equal (alist-get 'behavior response) "deny")
                         (alist-get 'message response))))
                (ecc-test-sent-messages))))

(ert-deftest ecc-worktree-test-refuses-the-other-two-ways ()
  "EnterWorktree and `git worktree add' are turned toward the tool."
  (require 'ecc-mcp)
  (ecc-worktree-register-mcp-tool)
  (ecc-test-with-fake-session session
    (let ((ecc-mcp-enabled t)
          (ecc-mcp-excluded-tools nil))
      (ecc-dispatch session (ecc-worktree-test--request "EnterWorktree"
                                                        '((branch . "feat/x"))))
      (ecc-dispatch session (ecc-worktree-test--request
                             "Bash" '((command . "cd /tmp && git worktree add ../x -b feat/x"))))
      (should (= 2 (length (ecc-worktree-test--denials))))
      (should (string-match-p "start_worktree_session"
                              (car (ecc-worktree-test--denials))))
      ;; Nobody was asked about either of them.
      (should-not (ecc-session-pending session))
      ;; Another git command is none of this hook's business, and
      ;; `ExitWorktree' undoes nothing Emacs made.
      (ecc-dispatch session (ecc-worktree-test--request
                             "Bash" '((command . "git worktree list"))))
      (ecc-dispatch session (ecc-worktree-test--request "ExitWorktree" nil))
      (should (= 2 (length (ecc-session-pending session))))
      (should (= 2 (length (ecc-worktree-test--denials)))))))

(ert-deftest ecc-worktree-test-refuses-nothing-without-the-tool ()
  "A refusal pointing at a tool the session has not got is obstruction."
  (require 'ecc-mcp)
  (ecc-worktree-register-mcp-tool)
  (ecc-test-with-fake-session session
    ;; The server is off for this session.
    (let ((ecc-mcp-enabled nil))
      (ecc-dispatch session (ecc-worktree-test--request "EnterWorktree" nil))
      (should-not (ecc-worktree-test--denials))
      (should (= 1 (length (ecc-session-pending session)))))
    ;; On, but the tool was taken out of the published list.
    (let ((ecc-mcp-enabled t)
          (ecc-mcp-excluded-tools '("start_worktree_session")))
      (ecc-dispatch session (ecc-worktree-test--request
                             "Bash" '((command . "git worktree add ../x"))))
      (should-not (ecc-worktree-test--denials))
      (should (= 2 (length (ecc-session-pending session)))))))

(ert-deftest ecc-worktree-test-a-session-in-a-worktree-goes-by-its-branch ()
  "The name of a session started in a worktree is the branch, not the slug.
The Space above it is called after the branch, and the directory is a
slug of that branch: one screen calling the same thing `feat/one\=' and
`feat-one\=' is one name too many (2026-09-17)."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let ((ecc-worktree-directory ".claude/worktrees"))
      (let ((path (ecc-worktree-create directory "feat/one")))
        (clrhash ecc-worktree--cache)
        (should (equal (ecc-worktree-session-name path) "feat/one"))
        ;; The main worktree keeps the name of its directory, and so
        ;; does a directory that is in no repository at all.
        (should-not (ecc-worktree-session-name directory))
        (should-not (ecc-worktree-session-name temporary-file-directory))
        ;; herdr\='s prefix is dropped, as the Space drops it.
        (let ((generated (ecc-worktree-create directory "worktree/two")))
          (clrhash ecc-worktree--cache)
          (should (equal (ecc-worktree-session-name generated) "two")))))))

(ert-deftest ecc-worktree-test-prompt-hint ()
  "A draft that speaks of a worktree is sent with a line about the tool."
  (require 'ecc-mcp)
  (require 'ecc-prompt)
  (ecc-worktree-register-mcp-tool)
  (ecc-test-with-fake-session session
    (let ((ecc-mcp-enabled t)
          (ecc-mcp-excluded-tools nil))
      (should (string-match-p
               "start_worktree_session"
               (ecc-prompt-prepare-text session "worktree を切ってやって")))
      (should (string-match-p
               "start_worktree_session"
               (ecc-prompt-prepare-text session "do it in a worktree")))
      ;; The user's own words are still the first thing in it.
      (should (string-prefix-p "do it in a worktree"
                               (ecc-prompt-prepare-text
                                session "do it in a worktree")))
      ;; A draft about anything else costs nothing.
      (should (equal "make the tests pass"
                     (ecc-prompt-prepare-text session "make the tests pass")))
      ;; And neither does one in a session with no such tool.
      (let ((ecc-mcp-enabled nil))
        (should (equal "worktree を切ってやって"
                       (ecc-prompt-prepare-text session
                                                "worktree を切ってやって")))))))

(ert-deftest ecc-worktree-test-prompt-hint-on-every-send ()
  "The line is added wherever a prompt is sent from, not only the region.
`ecc-send\=' and its neighbours, and `ecc-inline-prompt\=', go straight to
the process; in an `auto\=' permission mode this line is the whole
backstop, and one that is only on the prompts typed in the prompt
region is no backstop at all (2026-09-17)."
  (require 'ecc-mcp)
  (require 'ecc-context)
  (ecc-worktree-register-mcp-tool)
  (ecc-test-with-fake-session session
    (let ((ecc-mcp-enabled t)
          (ecc-mcp-excluded-tools nil)
          (sent nil))
      (cl-letf (((symbol-function #'ecc-proc-send-prompt)
                 (lambda (_session text) (setq sent text) 'sent)))
        (ecc-send "worktree で直して" session)
        (should (string-match-p "start_worktree_session" sent))
        (should (string-prefix-p "worktree で直して" sent))
        ;; What Emacs added is marked, so the transcript can part it
        ;; from what the user wrote.
        (should (text-property-any 0 (length sent) 'ecc-aside t sent))
        ;; Anything else costs nothing.
        (ecc-send "テストを通して" session)
        (should (equal sent "テストを通して"))))))

;;;; Offering to undo a worktree

(defmacro ecc-worktree-test--with-answer (answer &rest body)
  "Run BODY with every `yes-or-no-p' answered ANSWER, recording the questions.
ANSWER may be a function, which is called with the question: a command
that asks two of them is answered one way about the worktree and
another about git's refusal.  The questions land in `asked', which BODY
may read, newest first."
  (declare (indent 1))
  `(let ((asked nil)
         (answer ,answer))
     (cl-letf (((symbol-function #'yes-or-no-p)
                (lambda (prompt)
                  (push prompt asked)
                  (if (functionp answer) (funcall answer prompt) answer))))
       (ignore asked)
       ,@body)))

(defmacro ecc-worktree-test--with-timers (&rest body)
  "Run BODY with `run-at-time' calling its function at once.
The offer to remove a worktree is scheduled rather than made where the
session leaves the model; a batch test has no idle moment to wait for."
  (declare (indent 0))
  `(cl-letf (((symbol-function #'run-at-time)
              (lambda (_time _repeat function &rest arguments)
                (apply function arguments))))
     ,@body))

(ert-deftest ecc-worktree-test-offer-removal ()
  "The offer is made for a worktree with nothing left running in it."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x")))
      ;; The main worktree is not a worktree to undo.
      (ecc-worktree-test--with-answer t
        (should-not (ecc-worktree-offer-removal directory))
        (should-not asked))
      ;; Nor is one that still has a session in it.
      (let ((session (ecc-model-create-session :name "in-there"
                                               :project-root path)))
        (unwind-protect
            (ecc-worktree-test--with-answer t
              (should-not (ecc-worktree-offer-removal path))
              (should-not asked))
          (ecc-model-remove-session session)
          (ecc-test-cleanup-session session)))
      ;; Answering no leaves it standing.
      (ecc-worktree-test--with-answer nil
        (should-not (ecc-worktree-offer-removal path))
        (should (= 1 (length asked)))
        (should (string-match-p "Remove the worktree" (car asked))))
      (should (file-directory-p path))
      ;; And yes undoes it, in one question: the branch is never asked
      ;; about, and it outlives the directory it was checked out in.
      (clrhash ecc-worktree--cache)
      (ecc-worktree-test--with-answer t
        (should (ecc-worktree-offer-removal path))
        (should (= 1 (length asked))))
      (should-not (file-directory-p path))
      (should (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-every-removal-says-so ()
  "Every way a worktree goes runs `ecc-worktree-removed-hook' with it.
What draws a worktree redraws from that hook.  Only `ecc-remove-worktree'
told anybody before, so a worktree an offer removed -- the last session
of one leaving, or a group closed together -- left its row on the screen
pointing at a directory that was gone."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (told nil)
           (ecc-worktree-removed-hook
            (list (lambda (path) (push path told)))))
      ;; The offer one session leaving makes.
      (let ((path (ecc-worktree-create directory "feat/x")))
        (ecc-worktree-test--with-answer t
          (should (ecc-worktree-offer-removal path)))
        (should (equal (mapcar #'file-truename told)
                       (list (file-truename path)))))
      ;; The one question a group is asked.
      (setq told nil)
      (clrhash ecc-worktree--cache)
      (let ((one (ecc-worktree-create directory "feat/y"))
            (two (ecc-worktree-create directory "feat/z")))
        (ecc-worktree-test--with-answer t
          (should (ecc-worktree-offer-group-removal (list one two))))
        (should (equal (sort (mapcar #'file-truename told) #'string<)
                       (sort (mapcar #'file-truename (list one two)) #'string<))))
      ;; And the command.
      (setq told nil)
      (clrhash ecc-worktree--cache)
      (let ((path (ecc-worktree-create directory "feat/w")))
        (ecc-worktree-remove path)
        (should (equal (mapcar #'file-truename told)
                       (list (file-truename path))))))))

(ert-deftest ecc-worktree-test-remove-worktree-leaves-the-branch ()
  "`ecc-remove-worktree' asks once, and the branch outlives the directory."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x")))
      (ecc-worktree-test--with-answer t
        (ecc-remove-worktree path)
        (should (= 1 (length asked)))
        (should (string-match-p "Remove the worktree" (car asked))))
      (should-not (file-directory-p path))
      (should (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-remove-worktree-stops-a-nested-session ()
  "A session in a project of its own inside the worktree is stopped too.
`project-current\=' answers such a directory with itself, so the session
is in none of the worktree\='s -- and used to be left in the model with
its directory deleted under it."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x"))
           (nested (expand-file-name "vendor/lib" path)))
      (make-directory nested t)
      (call-process "git" nil nil nil "-C" nested "init")
      (cl-letf (((symbol-function #'ecc-proc-stop) #'ignore))
        (ecc-model-create-session :name "outer" :project-root path)
        (ecc-model-create-session :name "nested" :project-root nested)
        ;; The project of the worktree is one of the two; both work in it.
        (should (= 1 (length (ecc-window-project-sessions path))))
        (should (= 2 (length (ecc-worktree-sessions path))))
        (ecc-worktree-test--with-answer t
          (ecc-remove-worktree path)
          (should (string-match-p "Stop 2 sessions" (car (last asked)))))
        (should-not (ecc-model-sessions))
        (should-not (file-directory-p path)))
      ;; A session of another project is left alone.
      (let ((ecc-window--project-root-cache (make-hash-table :test #'equal))
            (path (ecc-worktree-create directory "feat/y")))
        (cl-letf (((symbol-function #'ecc-proc-stop) #'ignore))
          (ecc-model-create-session :name "elsewhere" :project-root directory)
          (ecc-worktree-test--with-answer t
            (ecc-remove-worktree path))
          (should (equal '("elsewhere")
                         (mapcar #'ecc-session-name (ecc-model-sessions)))))))))

(ert-deftest ecc-worktree-test-remove-worktree-forgets-the-space ()
  "The Space of the worktree is closed, while the directory is still there.
Its key is `ecc-window-project-key\=' of a directory that exists; asked
after the removal it could answer something else, and the tab would be
left open on a Space with nowhere to go."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc-use-spaces t)
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x"))
           (forgotten nil))
      (cl-letf (((symbol-function 'ecc-space-forget)
                 (lambda (root)
                   (push (cons root (file-directory-p root)) forgotten))))
        (ecc-worktree-test--with-answer t
          (ecc-remove-worktree path))
        (should (equal forgotten (list (cons path t)))))
      (should-not (file-directory-p path))
      ;; Under `classic\=' there is no Space and `ecc-space\=' is not loaded.
      (let ((ecc-use-spaces nil)
            (path (ecc-worktree-create directory "feat/y")))
        (cl-letf (((symbol-function 'ecc-space-forget)
                   (lambda (_root) (error "No Space under classic"))))
          (ecc-worktree-test--with-answer t
            (ecc-remove-worktree path)))
        (should-not (file-directory-p path))))))

(ert-deftest ecc-worktree-test-offer-counts-the-open-buffers ()
  "A buffer visiting the worktree is counted in the question, not killed."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x"))
           (buffer (find-file-noselect (expand-file-name "a.txt" path))))
      (unwind-protect
          (ecc-worktree-test--with-answer nil
            (ecc-worktree-offer-removal path)
            (should (string-match-p "1 open buffer will be left" (car asked))))
        (kill-buffer buffer)))))

(ert-deftest ecc-worktree-test-a-session-leaving-offers-the-worktree ()
  "The last session of a worktree leaving the model asks about the directory.
However it left: `ecc-kill\=' from Lisp is the case a command could not
cover, and it is the one that used to leave the directory behind."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x")))
      (cl-letf (((symbol-function #'ecc-proc-stop) #'ignore))
        ;; One of two sessions going is no reason to take the tree from
        ;; the other.
        (let ((one (ecc-model-create-session :name "one" :project-root path))
              (two (ecc-model-create-session :name "two" :project-root path)))
          (ecc-worktree-test--with-timers
            (ecc-worktree-test--with-answer nil
              (ecc-kill one)
              (should-not asked)
              ;; And the last one asks, once, and no leaves it standing.
              (ecc-kill two)
              (should (= 1 (length asked)))
              (should (string-match-p "Remove the worktree" (car asked)))))
          (should (file-directory-p path)))
        ;; A session that belongs to nobody says nothing about the tree.
        (let ((probe (ecc-model-create-session
                      :name "probe" :project-root path
                      :options '(:usage-probe t))))
          (ecc-worktree-test--with-timers
            (ecc-worktree-test--with-answer t
              (ecc-kill probe)
              (should-not asked))))
        ;; A command stopping a group of its own answers for itself.
        (let ((session (ecc-model-create-session :name "three"
                                                 :project-root path)))
          (ecc-worktree-test--with-timers
            (ecc-worktree-test--with-answer t
              (let ((ecc-space--closing t))
                (ecc-kill session))
              (should-not asked)))
          (should (file-directory-p path)))
        ;; And yes takes the directory, leaving the branch.
        (let ((session (ecc-model-create-session :name "four"
                                                 :project-root path)))
          (ecc-worktree-test--with-timers
            (ecc-worktree-test--with-answer t
              (ecc-kill session)
              (should (= 1 (length asked)))))
          (should-not (file-directory-p path))
          (should (member "feat/x" (ecc-worktree-branches directory))))))))

(ert-deftest ecc-worktree-test-two-sessions-leaving-together-ask-once ()
  "Two sessions of one worktree stopped in a row are one question.
The offer is scheduled where a session leaves and made from a timer, so
without this the second would queue a question about a directory the
first has already taken away."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x"))
           (scheduled nil))
      (cl-letf (((symbol-function #'ecc-proc-stop) #'ignore)
                ((symbol-function #'run-at-time)
                 (lambda (_time _repeat function &rest arguments)
                   (push (cons function arguments) scheduled))))
        (let ((one (ecc-model-create-session :name "one" :project-root path))
              (two (ecc-model-create-session :name "two" :project-root path)))
          (ecc-kill one)
          (ecc-kill two))
        (should (= 1 (length scheduled)))
        ;; The one that was scheduled still asks everything again.
        (ecc-worktree-test--with-answer t
          (apply (caar scheduled) (cdar scheduled))
          (should (= 1 (length asked))))
        (should-not (file-directory-p path))))))

(ert-deftest ecc-worktree-test-group-removal-asks-once ()
  "`ecc-worktree-offer-group-removal\=' names the worktrees in one question."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (one (ecc-worktree-create directory "feat/x"))
           (two (ecc-worktree-create directory "feat/y")))
      ;; A directory that is gone, and the repository itself, are left
      ;; out of the question rather than asked about.
      (ecc-worktree-test--with-answer nil
        (should-not (ecc-worktree-offer-group-removal
                     (list directory (expand-file-name "nowhere" directory))))
        (should-not asked))
      ;; No leaves both where they are.
      (ecc-worktree-test--with-answer nil
        (should-not (ecc-worktree-offer-group-removal (list one two)))
        (should (= 1 (length asked)))
        (should (string-match-p "Remove the worktrees feat/x, feat/y as well"
                                (car asked))))
      (should (file-directory-p one))
      ;; Yes takes both, and both branches stay.
      (ecc-worktree-test--with-answer t
        (should (equal (list one two)
                       (ecc-worktree-offer-group-removal (list one two))))
        (should (= 1 (length asked))))
      (should-not (file-directory-p one))
      (should-not (file-directory-p two))
      (should (member "feat/x" (ecc-worktree-branches directory)))
      (should (member "feat/y" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-context-root-climbs-to-the-parent ()
  "A command run in a linked worktree acts on the repository it came from."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (path (ecc-worktree-create directory "feat/x")))
      (cl-letf (((symbol-function #'ecc-window-context-project-root)
                 (lambda () path)))
        (should (equal (file-truename (ecc-worktree-context-root))
                       (file-truename directory))))
      (cl-letf (((symbol-function #'ecc-window-context-project-root)
                 (lambda () directory)))
        (should (equal (ecc-worktree-context-root) directory))))))

;;;; Removing the finished ones from inside a session

(defmacro ecc-worktree-test--with-repository (var &rest body)
  "Run BODY with VAR a repository with an origin, its develop at the first commit.
No session registry, project cache or Space is inherited, nothing may
ask a question -- `remove_worktree' never asks -- and gh is one that is
not installed unless BODY says otherwise."
  (declare (indent 1))
  `(ecc-worktree-test--with-directory ,var
     (ecc-worktree-test--repository ,var)
     (ecc-worktree-test--git ,var "remote" "add" "origin"
                             (expand-file-name "no-such-origin.git" ,var))
     (ecc-worktree-test--git ,var "update-ref" "refs/remotes/origin/develop"
                             "HEAD")
     (let ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (ecc-use-spaces nil)
           ;; Without a calling session the repository is where Emacs is.
           (default-directory ,var)
           (ecc-review-gh-executable "ecc-worktree-test-no-such-gh")
           (inhibit-interaction t))
       (cl-letf (((symbol-function #'yes-or-no-p)
                  (lambda (prompt) (error "Asked: %s" prompt)))
                 ((symbol-function #'ecc-proc-stop) #'ignore))
         ,@body))))

(defun ecc-worktree-test--idle-session (&rest arguments)
  "Return a session made with ARGUMENTS, its process up and nothing to do."
  (let ((session (apply #'ecc-model-create-session arguments)))
    (setf (ecc-session-state session) 'idle)
    session))

(defun ecc-worktree-test--commit (directory file)
  "Commit a new FILE in DIRECTORY and return the commit."
  (with-temp-file (expand-file-name file directory) (insert file "\n"))
  (ecc-worktree-test--git directory "add" file)
  (ecc-worktree-test--git directory "commit" "-q" "-m" file)
  (string-trim (ecc-worktree-test--git directory "rev-parse" "HEAD")))

(defun ecc-worktree-test--finished (directory branch)
  "Make a worktree of DIRECTORY on BRANCH whose work has landed, and return it.
A commit is made on BRANCH, merged into main, and main is what
origin/develop holds."
  (let ((path (ecc-worktree-create directory branch)))
    (ecc-worktree-test--commit path (concat (ecc-worktree-slug branch) ".txt"))
    (ecc-worktree-test--git directory "merge" "-q" "--no-edit" branch)
    (ecc-worktree-test--git directory "update-ref" "refs/remotes/origin/develop"
                            "HEAD")
    (ecc-worktree-forget)
    path))

(defmacro ecc-worktree-test--with-gh (answer &rest body)
  "Run BODY with a fake gh that prints ANSWER, a JSON string.
ANSWER may be (:fail TEXT), and gh then fails saying TEXT, or (:sleep
SECONDS), and gh says nothing for that long.  The calls land in
`gh-calls', one string of arguments each."
  (declare (indent 1))
  `(let* ((gh-dir (make-temp-file "ecc-worktree-gh" t))
          (script (expand-file-name "gh" gh-dir))
          (answer ,answer))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "answer" gh-dir)
             (insert (if (stringp answer) answer (format "%s" (cadr answer)))))
           (with-temp-file script
             (insert (format "#!/bin/sh\necho \"$*\" >> '%s/log'\n%s\n"
                             gh-dir
                             (pcase answer
                               ((pred stringp) (format "cat '%s/answer'" gh-dir))
                               (`(:sleep ,seconds) (format "sleep %s" seconds))
                               (_ (format "cat '%s/answer' >&2; exit 1" gh-dir))))))
           (set-file-modes script #o755)
           (let ((ecc-review-gh-executable script))
             (cl-flet ((gh-calls ()
                         (let ((log (expand-file-name "log" gh-dir)))
                           (and (file-exists-p log)
                                (split-string (with-temp-buffer
                                                (insert-file-contents log)
                                                (buffer-string))
                                              "\n" t)))))
               ,@body)))
       (delete-directory gh-dir t))))

(defun ecc-worktree-test--merged-json (number head &optional base)
  "Return gh's JSON for one merged pull request NUMBER whose head is HEAD.
Its base is BASE, develop by default."
  (json-serialize
   (vector `((number . ,number) (title . "x") (state . "MERGED")
             (headRefName . "feat/x") (baseRefName . ,(or base "develop"))
             (headRefOid . ,head) (baseRefOid . "0")
             (author . ((login . "u"))) (isDraft . :false)
             (isCrossRepository . :false) (url . "https://example.com")))))

(defun ecc-worktree-test--remove (&rest paths)
  "Call `remove_worktree' with PATHS and return its lines."
  (split-string (ecc-worktree-mcp-remove (vconcat paths)) "\n"))

(ert-deftest ecc-worktree-test-parse-locked ()
  "A locked worktree keeps git's reason, and t when git gave none."
  (let ((entries (ecc-worktree-parse ecc-worktree-test--porcelain)))
    (should (equal (ecc-worktree-entry-locked-p (nth 1 entries))
                   "claude session feat/plugins"))
    (should-not (ecc-worktree-entry-locked-p (nth 2 entries))))
  (should (eq t (ecc-worktree-entry-locked-p
                 (cadr (ecc-worktree-parse
                        "worktree /r\nHEAD 1\n\nworktree /r/w\nHEAD 2\nlocked\n"))))))

(ert-deftest ecc-worktree-test-mcp-remove-a-merged-worktree ()
  "A clean worktree whose commit is in origin/develop goes, its branch stays."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((path (ecc-worktree-test--finished directory "feat/x"))
           (caller (ecc-worktree-test--idle-session :name "caller"
                                                    :project-root directory))
           (ecc-mcp--session-id (ecc-session-id caller))
           (removed nil)
           (ecc-worktree-removed-hook (list (lambda (p) (push p removed))))
           ;; A path relative to the main worktree names it as well.
           (lines (ecc-worktree-test--remove ".claude/worktrees/feat-x")))
      (should (= 1 (length lines)))
      (should (string-match-p "\\`removed .*feat-x/ (branch feat/x kept; merged: its tip is in origin/develop)\\'"
                              (car lines)))
      (should-not (file-directory-p path))
      (should (member "feat/x" (ecc-worktree-branches directory)))
      (should (= 1 (length removed)))
      ;; The calling session is in the repository, not the worktree.
      (should (equal '("caller") (mapcar #'ecc-session-name
                                         (ecc-model-sessions)))))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-a-fresh-worktree ()
  "A branch nobody committed on is work not started, not work merged.
Its tip is the commit it was made from, which origin/develop holds as
well; what tells the two apart is that the reflog of the branch records
no commit."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let ((path (ecc-worktree-create directory "feat/x")))
      (ecc-worktree-test--idle-session :name "reader" :project-root path)
      (should (string-match-p
               ": not merged: its tip is in origin/develop, but no commit was made on feat/x, and gh is not installed"
               (car (ecc-worktree-test--remove path))))
      ;; Nor is a branch that only took in work made elsewhere.
      (let ((other (ecc-worktree-test--finished directory "feat/other")))
        (ignore other)
        (ecc-worktree-test--git path "merge" "-q" "--ff-only" "main")
        (should (string-match-p ": not merged: .*no commit was made on feat/x"
                                (car (ecc-worktree-test--remove path)))))
      (should (file-directory-p path))
      (should (= 1 (length (ecc-model-sessions)))))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-dirty ()
  "Uncommitted and untracked files are counted, and the worktree stays.
However git is configured to show them: under
status.showUntrackedFiles=no a plain `git status' hides an untracked
file that `git worktree remove' would then delete."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let ((path (ecc-worktree-test--finished directory "feat/x")))
      (ecc-worktree-test--git directory "config" "status.showUntrackedFiles" "no")
      (with-temp-file (expand-file-name "new/deep.txt" path)
        (make-directory (expand-file-name "new" path) t)
        (insert "x"))
      (should (string-match-p "refused .*: dirty: 1 file uncommitted or untracked\\'"
                              (car (ecc-worktree-test--remove path))))
      (with-temp-file (expand-file-name "a.txt" path) (insert "changed"))
      (should (string-match-p ": dirty: 2 files uncommitted or untracked\\'"
                              (car (ecc-worktree-test--remove path))))
      (should (file-exists-p (expand-file-name "new/deep.txt" path))))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-unsaved-work ()
  "A buffer with unsaved changes or a prompt with a draft keeps the worktree.
A buffer with nothing unsaved is left open and counted."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((path (ecc-worktree-test--finished directory "feat/x"))
           (buffer (find-file-noselect (expand-file-name "a.txt" path)))
           (session (ecc-worktree-test--idle-session :name "drafting"
                                                     :project-root path)))
      (unwind-protect
          (progn
            (with-current-buffer buffer (insert "unsaved "))
            (should (string-match-p ": unsaved changes in a.txt\\'"
                                    (car (ecc-worktree-test--remove path))))
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (cl-letf (((symbol-function 'ecc-chat-draft)
                       (lambda () "half a sentence")))
              (setf (ecc-session-buffer session)
                    (get-buffer-create " *ecc-worktree-test session*"))
              (should (string-match-p
                       ": session drafting has an unsent draft in its prompt\\'"
                       (car (ecc-worktree-test--remove path)))))
            (should (file-directory-p path))
            (cl-letf (((symbol-function 'ecc-chat-draft) (lambda () "  \n")))
              (should (string-match-p
                       "\\`removed .*; stopped drafting; 1 open buffer left visiting deleted files)\\'"
                       (car (ecc-worktree-test--remove path)))))
            (should (buffer-live-p buffer)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-unmerged ()
  "A branch with commits of its own needs a merged pull request, and gh."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let ((path (ecc-worktree-create directory "feat/x")))
      (ecc-worktree-test--commit path "b.txt")
      ;; No gh: ancestry did not settle it, so nothing is guessed.
      (should (string-match-p
               ": not merged: not in origin/develop, and gh is not installed"
               (car (ecc-worktree-test--remove path))))
      ;; gh knows no merged pull request of the branch.
      (ecc-worktree-test--with-gh "[]"
        (should (string-match-p
                 ": not merged: not in origin/develop, and gh knows no merged pull request of feat/x\\'"
                 (car (ecc-worktree-test--remove path))))
        (should (equal (car (gh-calls))
                       (concat "pr list --head feat/x --state merged --json "
                               ecc-review-pr-fields))))
      ;; gh failing is said, not taken for an answer.
      (ecc-worktree-test--with-gh '(:fail "not logged in")
        (should (string-match-p ": not merged: .*gh failed: .*not logged in"
                                (car (ecc-worktree-test--remove path)))))
      ;; Nor is a gh that gives no answer waited for.
      (ecc-worktree-test--with-gh '(:sleep 5)
        (let ((ecc-review-pr-merged-timeout 0.3)
              (start (float-time)))
          (should (string-match-p ": not merged: .*gh failed: gh gave no answer in 0.3 seconds"
                                  (car (ecc-worktree-test--remove path))))
          (should (< (- (float-time) start) 3))))
      ;; gh is not asked about a worktree refused for another reason.
      (with-temp-file (expand-file-name "new.txt" path) (insert "x"))
      (ecc-worktree-test--with-gh "[]"
        (should (string-match-p ": dirty: " (car (ecc-worktree-test--remove path))))
        (should (string-match-p "gh was not asked" (ecc-worktree-mcp-list)))
        (should-not (gh-calls)))
      (should (file-directory-p path)))))

(ert-deftest ecc-worktree-test-mcp-remove-a-squashed-branch ()
  "A pull request into an integration branch merged with the tip is merged.
Squashed, the commits are no ancestors of the base; with commits after
the merge, the branch has work the pull request did not take; and a
pull request merged into another feature branch has not landed."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((path (ecc-worktree-create directory "feat/x"))
           (merged (ecc-worktree-test--commit path "b.txt")))
      (ecc-worktree-test--commit path "c.txt")
      (ecc-worktree-test--with-gh (ecc-worktree-test--merged-json 101 merged)
        (should (string-match-p
                 ": not merged: pull request #101 was merged into develop, but the branch has commits after it\\'"
                 (car (ecc-worktree-test--remove path)))))
      (should (file-directory-p path))
      (ecc-worktree-test--git path "reset" "-q" "--hard" merged)
      (ecc-worktree-test--with-gh (ecc-worktree-test--merged-json
                                   102 merged "feat/base")
        (should (string-match-p
                 ": not merged: not in origin/develop; pull request #102 was merged into feat/base, which is no integration branch\\'"
                 (car (ecc-worktree-test--remove path)))))
      (should (file-directory-p path))
      (ecc-worktree-test--with-gh (ecc-worktree-test--merged-json 101 merged)
        (should (string-match-p
                 "\\`removed .*merged: pull request #101 into develop was merged with its tip)\\'"
                 (car (ecc-worktree-test--remove path)))))
      (should-not (file-directory-p path))
      (should (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-without-a-remote ()
  "With no remote there is nothing to be merged into, and no guess."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let ((path (ecc-worktree-test--finished directory "feat/x")))
      (ecc-worktree-test--git directory "remote" "remove" "origin")
      (should (string-match-p ": not merged: the repository has no remote"
                              (car (ecc-worktree-test--remove path))))
      (should (file-directory-p path)))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-what-is-no-linked-worktree ()
  "The main worktree, a directory of no worktree and a locked one stay."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let ((path (ecc-worktree-test--finished directory "feat/x"))
          (elsewhere (make-temp-file "ecc-worktree-elsewhere" t)))
      (unwind-protect
          (progn
            (should (string-match-p ": it is the main worktree\\'"
                                    (car (ecc-worktree-test--remove directory))))
            (should (string-match-p ": not a worktree of this repository\\'"
                                    (car (ecc-worktree-test--remove elsewhere))))
            ;; A directory inside a worktree is not the worktree.
            (should (string-match-p ": not a worktree of this repository\\'"
                                    (car (ecc-worktree-test--remove
                                          (expand-file-name "sub" path)))))
            (ecc-worktree-test--git directory "worktree" "lock" "--reason"
                                    "in use" path)
            (should (string-match-p ": it is locked (in use)\\'"
                                    (car (ecc-worktree-test--remove path))))
            (should (file-directory-p path))
            (should (file-directory-p directory)))
        (delete-directory elsewhere t)))))

(ert-deftest ecc-worktree-test-mcp-remove-stops-idle-sessions ()
  "Idle, exited and restored sessions are stopped, and the worktree goes."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((path (ecc-worktree-test--finished directory "feat/x"))
           (one (ecc-worktree-test--idle-session :name "one" :project-root path))
           (two (ecc-worktree-test--idle-session :name "two" :project-root path))
           (three (ecc-worktree-test--idle-session :name "three" :project-root path
                                                   :options '(:restored t))))
      (ignore one)
      (setf (ecc-session-state two) 'exited
            (ecc-session-state three) 'exited)
      (let ((line (car (ecc-worktree-test--remove path))))
        (should (string-match-p "\\`removed " line))
        (should (string-match-p "; stopped three, two, one)\\'" line)))
      (should-not (ecc-model-sessions))
      (should-not (file-directory-p path)))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-a-busy-session ()
  "A session running, waiting on an answer or running a task keeps the worktree.
Nothing is stopped: the idle session beside the busy one is still there."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((path (ecc-worktree-test--finished directory "feat/x"))
           (idle (ecc-worktree-test--idle-session :name "idle" :project-root path))
           (busy (ecc-worktree-test--idle-session :name "busy" :project-root path)))
      (ignore idle)
      (dolist (state '(running starting compacting))
        (setf (ecc-session-state busy) state)
        (should (string-match-p ": session busy is running\\'"
                                (car (ecc-worktree-test--remove path)))))
      (setf (ecc-session-state busy) 'idle
            (ecc-session-pending busy) (list 'request))
      (should (string-match-p ": session busy is waiting on a request\\'"
                              (car (ecc-worktree-test--remove path))))
      ;; The turn is over, but an agent it started in the background is not.
      (setf (ecc-session-pending busy) nil)
      (let ((agent (ecc-model-add-node busy :id "toolu_a" :type 'agent
                                       :status 'done
                                       :data '((task . ((task_id . "a")))))))
        (setf (ecc-session-state busy) 'idle)
        (should (string-match-p
                 ": session busy is idle with 1 background task still running\\'"
                 (car (ecc-worktree-test--remove path))))
        (ecc-model-node-put agent 'task-status "completed"))
      ;; The session calling the tool from inside the worktree is said to be.
      (setf (ecc-session-state busy) 'running)
      (let ((ecc-mcp--session-id (ecc-session-id busy)))
        (should (string-match-p ": session busy (the one calling this tool) is running\\'"
                                (car (ecc-worktree-test--remove path)))))
      (should (= 2 (length (ecc-model-sessions))))
      (should (file-directory-p path)))))

(ert-deftest ecc-worktree-test-mcp-remove-refuses-a-session-standing-in-it ()
  "A session of another project whose cwd is in the worktree keeps it.
The CLI follows a Bash `cd' into the worktree; the session is not one of
the worktree's to stop, and would be left in a directory that is gone."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((path (ecc-worktree-test--finished directory "feat/x"))
           (caller (ecc-worktree-test--idle-session :name "caller"
                                                    :project-root directory))
           (ecc-mcp--session-id (ecc-session-id caller)))
      (setf (ecc-session-cwd caller) (expand-file-name "sub" path))
      (should (string-match-p ": session caller (the one calling this tool), of another project, has its working directory in it\\'"
                              (car (ecc-worktree-test--remove path))))
      ;; A stopped one is standing nowhere.
      (setf (ecc-session-state caller) 'exited)
      (should (string-match-p "\\`removed " (car (ecc-worktree-test--remove path))))
      (should (equal '("caller") (mapcar #'ecc-session-name (ecc-model-sessions)))))))

(ert-deftest ecc-worktree-test-mcp-remove-two-in-one-call ()
  "Two worktrees in one call: the finished one goes, the other is refused.
Each with a session of its own; only the removed one's is stopped."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((done (ecc-worktree-test--finished directory "feat/done"))
           (open (ecc-worktree-create directory "feat/open")))
      (ecc-worktree-test--idle-session :name "done-session" :project-root done)
      (ecc-worktree-test--idle-session :name "open-session" :project-root open)
      (ecc-worktree-test--commit open "b.txt")
      (let ((lines (ecc-worktree-test--remove done open)))
        (should (= 2 (length lines)))
        (should (string-match-p "\\`removed .*feat-done/ .*stopped done-session)\\'"
                                (nth 0 lines)))
        (should (string-match-p "\\`refused .*feat-open/?: not merged" (nth 1 lines))))
      (should-not (file-directory-p done))
      (should (file-directory-p open))
      (should (equal '("open-session")
                     (mapcar #'ecc-session-name (ecc-model-sessions)))))))

(ert-deftest ecc-worktree-test-mcp-remove-an-error-is-one-path ()
  "An error removing one worktree is that path's line; the others go on.
The model is told what was removed before it, and the error is logged."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((one (ecc-worktree-test--finished directory "feat/one"))
           (two (ecc-worktree-test--finished directory "feat/two"))
           (three (ecc-worktree-test--finished directory "feat/three"))
           (logged nil))
      (ecc-worktree-test--idle-session :name "two-session" :project-root two)
      (cl-letf* ((kill (symbol-function #'ecc-kill))
                 ((symbol-function #'ecc-kill)
                  (lambda (session)
                    (if (equal (ecc-session-name session) "two-session")
                        (error "Cannot kill %s" (ecc-session-name session))
                      (funcall kill session))))
                 ((symbol-function #'ecc-log)
                  (lambda (_name format &rest args)
                    (push (apply #'format format args) logged))))
        (let ((lines (ecc-worktree-test--remove one two three)))
          (should (string-match-p "\\`removed .*feat-one/" (nth 0 lines)))
          (should (string-match-p "\\`failed .*feat-two/?: Cannot kill two-session; the worktree is still there\\'"
                                  (nth 1 lines)))
          (should (string-match-p "\\`removed .*feat-three/" (nth 2 lines)))
          (should (seq-find (lambda (line) (string-match-p "Cannot kill" line))
                            logged))
          ;; A worktree that cannot be described says so, and the rest
          ;; are described.
          (cl-letf* ((changes (symbol-function #'ecc-worktree--changes))
                     ((symbol-function #'ecc-worktree--changes)
                      (lambda (root)
                        (if (string-match-p "feat-two" root)
                            (error "Broken")
                          (funcall changes root)))))
            (should (string-match-p "feat-two/ (branch feat/two)\n  error: Broken"
                                    (ecc-worktree-mcp-list)))))))))

(ert-deftest ecc-worktree-test-mcp-remove-closes-the-space ()
  "Under Spaces the Space is closed while the directory is still there.
Under `classic' nothing reaches `ecc-space'."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let ((path (ecc-worktree-test--finished directory "feat/x"))
          (forgotten nil))
      (let ((ecc-use-spaces t))
        (cl-letf (((symbol-function 'ecc-space-at-p) (lambda (_root) t))
                  ((symbol-function 'ecc-space-forget)
                   (lambda (root)
                     (push (cons root (file-directory-p root)) forgotten))))
          (should (string-match-p "; closed its Space)\\'"
                                  (car (ecc-worktree-test--remove path))))))
      (should (equal (mapcar #'cdr forgotten) '(t)))
      (should (equal (file-truename (caar forgotten)) (file-truename path)))
      (should-not (file-directory-p path))
      (let ((path (ecc-worktree-test--finished directory "feat/y")))
        (cl-letf (((symbol-function 'ecc-space-at-p)
                   (lambda (_root) (error "No Space under classic")))
                  ((symbol-function 'ecc-space-forget)
                   (lambda (_root) (error "No Space under classic"))))
          (let ((line (car (ecc-worktree-test--remove path))))
            (should (string-match-p "\\`removed " line))
            (should-not (string-match-p "Space" line))))))))

(ert-deftest ecc-worktree-test-mcp-list ()
  "Every linked worktree is described with what decides its removal."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-repository directory
    (let* ((done (ecc-worktree-test--finished directory "feat/done"))
           (dirty (ecc-worktree-create directory "feat/dirty"))
           (caller (ecc-worktree-test--idle-session :name "caller"
                                                    :project-root done))
           (ecc-mcp--session-id (ecc-session-id caller)))
      (with-temp-file (expand-file-name "new.txt" dirty) (insert "x"))
      (let ((text (ecc-worktree-mcp-list)))
        (should (string-match-p "\\`Repository: .* (the main worktree, never removed)"
                                text))
        (should (string-match-p "feat-done/ (branch feat/done)
  changes: none
  merged: yes -- its tip is in origin/develop
  sessions: caller (idle)
  removable: yes" text))
        (should (string-match-p "feat-dirty/ (branch feat/dirty)
  changes: 1 file uncommitted or untracked
  merged: no -- its tip is in origin/develop, but no commit was made on feat/dirty; gh was not asked, the worktree being refused for another reason
  sessions: none
  removable: no -- dirty: 1 file uncommitted or untracked" text))
        ;; The Space line is there only when there are Spaces.
        (should-not (string-match-p "Space:" text)))
      (let ((ecc-use-spaces t))
        (cl-letf (((symbol-function 'ecc-space-at-p)
                   (lambda (root) (string-match-p "feat-done" root))))
          (let ((text (ecc-worktree-mcp-list)))
            (should (string-match-p "sessions: caller (idle)\n  Space: yes" text))
            (should (string-match-p "sessions: none\n  Space: no" text))))))))

(ert-deftest ecc-worktree-test-mcp-removal-tools-published ()
  "The two tools are published with the paragraph about them."
  (require 'ecc-mcp)
  (ecc-worktree-register-removal-tools)
  (let ((ecc-mcp-excluded-tools nil))
    (should (ecc-mcp-tool "list_worktrees"))
    (should (string-match-p "ignores"
                            (ecc-mcp-tool-description
                             (ecc-mcp-tool "remove_worktree"))))
    (should (string-match-p "call list_worktrees first"
                            (ecc-mcp-instructions))))
  (let ((ecc-mcp-excluded-tools '("list_worktrees" "remove_worktree")))
    (should-not (string-match-p "list_worktrees"
                                (or (ecc-mcp-instructions) "")))))

(ert-deftest ecc-worktree-test-mcp-removal-tools-allowed ()
  "list_worktrees is always allowed; remove_worktree while the setting says."
  (require 'ecc-mcp)
  (ecc-test-with-fake-session session
    (let ((ecc-mcp-server-name "emacs")
          (ecc-worktree-auto-allow-removal t))
      (ecc-dispatch session (ecc-worktree-test--request
                             "mcp__emacs__list_worktrees" nil))
      (ecc-dispatch session (ecc-worktree-test--request
                             "mcp__emacs__remove_worktree"
                             '((paths . ["/x"]))))
      (should-not (ecc-session-pending session))
      (let ((ecc-worktree-auto-allow-removal nil))
        (ecc-dispatch session (ecc-worktree-test--request
                               "mcp__emacs__remove_worktree"
                               '((paths . ["/x"]))))
        (ecc-dispatch session (ecc-worktree-test--request
                               "mcp__emacs__list_worktrees" nil)))
      (should (= 1 (length (ecc-session-pending session))))
      ;; Another server's tool of the same name is asked about.
      (ecc-dispatch session (ecc-worktree-test--request
                             "mcp__other__remove_worktree" nil))
      (should (= 2 (length (ecc-session-pending session)))))))

(provide 'ecc-worktree-test)

;;; ecc-worktree-test.el ends here
