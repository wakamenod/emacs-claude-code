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
(require 'ecc-worktree)
;; Loaded here rather than by the command under test: `ecc-start' is
;; replaced with `cl-letf', and a `require' inside the command would put
;; the real one back on top of the replacement.
(require 'ecc)

;;;; Helpers

(defmacro ecc-worktree-test--with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, deleted afterwards.
The cache is fresh as well: a test must not see what an earlier one
asked git."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "ecc-worktree" t)))
         (ecc-worktree--cache (make-hash-table :test #'equal)))
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
      ;; The branch outlives the checkout.
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
  "`ecc-start-worktree' starts the session in the checkout it made."
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
git allows one branch in one worktree at a time, and the checkout that
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
  "`ecc-worktree-delegate' makes the checkout, starts a session and briefs it."
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
          ;; And a branch another checkout holds is refused rather than
          ;; gone to: two sessions in one tree is not handing work over.
          (clrhash ecc-worktree--cache)
          (should-error (ecc-worktree-delegate directory "feat/x" "again")
                        :type 'user-error))))))

(ert-deftest ecc-worktree-test-delegate-from-a-worktree-and-a-base ()
  "The checkout is made beside the main worktree, from the base given."
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

;;;; Offering to undo a checkout

(defmacro ecc-worktree-test--with-answer (answer &rest body)
  "Run BODY with every `yes-or-no-p' answered ANSWER, recording the questions.
ANSWER may be a function, which is called with the question: a command
that asks two of them is answered one way about the checkout and
another about the branch.  The questions land in `asked', which BODY
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
      ;; The main worktree is not a checkout to undo.
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
        (should (string-match-p "Remove the checkout" (car asked))))
      (should (file-directory-p path))
      ;; And yes undoes it.  The branch is a question of its own, and
      ;; saying no to that one leaves it standing.
      (clrhash ecc-worktree--cache)
      (ecc-worktree-test--with-answer
          (lambda (prompt) (not (string-match-p "Delete the branch" prompt)))
        (should (ecc-worktree-offer-removal path))
        (should (= 2 (length asked)))
        (should (string-match-p "Delete the branch feat/x" (car asked))))
      (should-not (file-directory-p path))
      (should (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-branch-offered-once-the-checkout-is-gone ()
  "The branch is offered after the removal, and never taken unasked."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (path (ecc-worktree-create directory "feat/x")))
      ;; A branch a worktree still holds is not offered: git would refuse
      ;; it, and the question would be a dead end in front of that.
      (ecc-worktree-test--with-answer t
        (should-not (ecc-worktree-offer-branch-removal directory "feat/x"))
        (should-not asked))
      ;; Nor is a detached checkout's branch, there being none.
      (ecc-worktree-test--with-answer t
        (should-not (ecc-worktree-offer-branch-removal directory nil))
        (should-not asked))
      (ecc-worktree-remove path)
      ;; No is no.
      (ecc-worktree-test--with-answer nil
        (should-not (ecc-worktree-offer-branch-removal directory "feat/x"))
        (should (= 1 (length asked))))
      (should (member "feat/x" (ecc-worktree-branches directory)))
      ;; Yes deletes it.
      (ecc-worktree-test--with-answer t
        (should (equal "feat/x"
                       (ecc-worktree-offer-branch-removal directory "feat/x"))))
      (should-not (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-delete-branch-insists-only-when-told-to ()
  "A branch with work on it takes a second yes, and git\='s refusals stand."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (path (ecc-worktree-create directory "feat/x")))
      (with-temp-file (expand-file-name "b.txt" path) (insert "two\n"))
      (ecc-worktree-test--git path "add" "b.txt")
      (ecc-worktree-test--git path "commit" "-q" "-m" "work")
      (ecc-worktree-remove path)
      ;; git refuses a branch whose commits are nowhere else, and that
      ;; refusal is the user's to answer.
      (ecc-worktree-test--with-answer nil
        (should-not (ecc-worktree-delete-branch directory "feat/x"))
        (should (= 1 (length asked)))
        (should (string-match-p "not merged anywhere else" (car asked))))
      (should (member "feat/x" (ecc-worktree-branches directory)))
      ;; FORCE is that answer given in advance.
      (ecc-worktree-test--with-answer nil
        (should (equal "feat/x"
                       (ecc-worktree-delete-branch directory "feat/x" t)))
        (should-not asked))
      (should-not (member "feat/x" (ecc-worktree-branches directory)))
      ;; A name no branch has is git's refusal, not silence.
      (should-error (ecc-worktree-delete-branch directory "feat/x")
                    :type 'user-error))))

(ert-deftest ecc-worktree-test-remove-worktree-offers-the-branch ()
  "`ecc-remove-worktree' asks about the checkout, then about the branch."
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
        (should (= 2 (length asked)))
        (should (string-match-p "Remove the worktree" (nth 1 asked)))
        (should (string-match-p "Delete the branch feat/x" (car asked))))
      (should-not (file-directory-p path))
      (should-not (member "feat/x" (ecc-worktree-branches directory))))))

(ert-deftest ecc-worktree-test-offer-counts-the-open-buffers ()
  "A buffer visiting the checkout is counted in the question, not killed."
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

(ert-deftest ecc-worktree-test-kill-session-offers-and-a-loop-does-not ()
  "Stopping the last session by hand asks; `ecc-kill' in a loop does not."
  (skip-unless (executable-find "git"))
  (ecc-worktree-test--with-directory directory
    (ecc-worktree-test--repository directory)
    (let* ((ecc-worktree-directory ".claude/worktrees")
           (ecc--sessions (make-hash-table :test #'equal))
           (ecc--session-order nil)
           (ecc-window--project-root-cache (make-hash-table :test #'equal))
           (path (ecc-worktree-create directory "feat/x")))
      (cl-letf (((symbol-function #'ecc-proc-stop) #'ignore))
        ;; `ecc-worktree-kill-session' is what the sidebar, the dashboard
        ;; and the tab use: the session goes, and the offer follows.
        (let ((session (ecc-model-create-session :name "one"
                                                 :project-root path)))
          (ecc-worktree-test--with-answer nil
            (ecc-worktree-kill-session session)
            (should (= 1 (length asked))))
          (should-not (ecc-model-session (ecc-session-id session))))
        ;; `ecc-kill' from Lisp asks nothing: `ecc-space-close' and
        ;; `ecc-remove-worktree' stop several sessions in a row.
        (let ((session (ecc-model-create-session :name "two"
                                                 :project-root path)))
          (ecc-worktree-test--with-answer t
            (ecc-kill session)
            (should-not asked))
          (should (file-directory-p path)))))))

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

(provide 'ecc-worktree-test)

;;; ecc-worktree-test.el ends here
