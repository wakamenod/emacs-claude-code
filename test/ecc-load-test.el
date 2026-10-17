;;; ecc-load-test.el --- Tests for what loading the package does  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loading ecc used to put nine of its functions on the hooks of Emacs:
;; every save, every window change, every killed buffer and every exit
;; ran ecc code in an Emacs that had never started a session.  Each now
;; goes on when what it serves first exists, and its own test says
;; where.  This one says the rest: after loading, nothing of ecc is on a
;; hook that is not ecc's own.  Wiring ecc to itself -- its functions
;; on `ecc-request-added-hook' and the like -- is what loading is for.
;;
;; The others are about the keymaps `ecc-chat' defines and the modules
;; above it give their keys to: whatever entry point is loaded, a chat
;; buffer comes up with them, a user's own binding wins over them
;; whatever loads first, and loading a module again changes nothing.
;;
;; Three are about advice: loading ecc advises no function of Emacs; the
;; NS input-method functions are advised by the first chat buffer; and
;; loading the ediff review leaves ediff alone.
;;
;; The last are about the modules that register with one above them:
;; the interceptors of the prompt region and the MCP tools of
;; `ecc-worktree' are in place once their own module is loaded, with
;; nothing waiting for another to load; `ecc-lifecycle' names a session
;; and takes its baseline without `ecc-worktree' or `ecc-review'; and
;; `ecc-proc' alone names the MCP server on the command line.
;;
;; The last four are about `ecc-window' and the Spaces above it:
;; `ecc-window' calls into no module that requires it beyond the buffer
;; of a session; and a recording opened under `spaces', a project focused
;; and a command that asks which project it is in all reach the Space,
;; which is a method there only once `ecc-space' has been loaded.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'ecc-test-helpers)

(defun ecc-load-test--probe (dir)
  "Return the form that loads every file of ecc in DIR and prints the hooks.
Every file, and not `ecc' alone: some are loaded only once a feature is
used, and their top level runs then all the same.  A hook is a variable
whose name ends in -hook or -functions and does not start with ecc-."
  `(let ((dir ,dir)
         (found nil))
     (add-to-list 'load-path dir)
     (dolist (file (directory-files dir nil "\\`ecc.*\\.el\\'"))
       (unless (equal file "ecc-autoloads.el")
         (require (intern (file-name-base file)))))
     (mapatoms
      (lambda (symbol)
        (when (and (boundp symbol)
                   (not (string-prefix-p "ecc-" (symbol-name symbol)))
                   (string-match-p "-\\(hook\\|functions\\)\\'" (symbol-name symbol)))
          (let ((value (default-value symbol)))
            (dolist (function (if (and (listp value) (not (functionp value)))
                                  value
                                (list value)))
              (when (and (symbolp function)
                         (string-prefix-p "ecc-" (symbol-name function)))
                (push (cons symbol function) found)))))))
     (princ "\necc-load-test: ")
     (prin1 found)
     (terpri)))

(ert-deftest ecc-load-test-loading-puts-nothing-on-emacs-hooks ()
  "Loading every file of ecc puts no ecc function on a hook of Emacs.
In an Emacs of its own: in this one the other tests have long since
opened the reviews, Spaces and sessions that put them there."
  (let ((dir (file-name-directory (locate-library "ecc.el" t))))
    (with-temp-buffer
      (should (zerop (call-process
                      (expand-file-name invocation-name invocation-directory)
                      nil t nil "-Q" "--batch"
                      "--eval" (prin1-to-string (ecc-load-test--probe dir)))))
      (goto-char (point-min))
      (should (search-forward "ecc-load-test: " nil t))
      (should (equal (read (current-buffer)) nil)))))

(defun ecc-load-test--run (form)
  "Evaluate FORM in an Emacs of its own and return what it returns.
That Emacs has ecc on its `load-path' and has loaded nothing of it, so
FORM decides what is loaded and in what order.  What FORM returns is
printed and read back, so it must have a printed representation."
  (let ((dir (file-name-directory (locate-library "ecc.el" t))))
    (with-temp-buffer
      (should (zerop (call-process
                      (expand-file-name invocation-name invocation-directory)
                      nil t nil "-Q" "--batch"
                      "--eval"
                      (prin1-to-string
                       `(progn
                          (add-to-list 'load-path ,dir)
                          (let ((value ,form))
                            (princ "\necc-load-test: ")
                            (prin1 value)
                            (terpri)))))))
      (goto-char (point-min))
      (should (search-forward "ecc-load-test: " nil t))
      (read (current-buffer)))))

(ert-deftest ecc-load-test-chat-buffer-has-module-keys ()
  "A chat buffer has the keys of the modules above `ecc-chat', whatever made it.
The keymaps are defined in `ecc-chat', and `ecc-prompt', `ecc-session',
`ecc-queue', `ecc-hint', `ecc-tui' and `ecc-transient' give them their
keys; `ecc-session-ensure-buffer' loads the whole package before it
makes the buffer.  Most of the ways to a buffer -- a recording read
back, the terminal, an answer from anywhere, a Space -- load
`ecc-session' and never `ecc-prompt' or `ecc-transient', so without that
a buffer would come up with no \\`C-c C-c' and no \\`?'.  FEATURE is
required as that entry point would be, and the buffer is made the way
every path makes one: `ecc-session' required at run time and
`ecc-session-ensure-buffer' called."
  (dolist (feature '(ecc-chat ecc-session ecc-window ecc-space ecc-history
                              ecc-restore ecc-tui ecc-answer ecc))
    (should (equal (cons feature
                         (ecc-load-test--run
                          `(progn
                             (require ',feature)
                             (require 'ecc-session)
                             (with-current-buffer
                                 (ecc-session-ensure-buffer
                                  (ecc-model-create-session
                                   :name "probe"
                                   :project-root temporary-file-directory))
                               (list (key-binding (kbd "C-c C-c"))
                                     (lookup-key ecc-chat-transcript-map (kbd "RET"))
                                     (car completion-at-point-functions)
                                     (key-binding (kbd "C-c C-q"))
                                     (key-binding (kbd "C-c C-s"))
                                     (key-binding (kbd "C-c ?"))
                                     (lookup-key ecc-chat-transcript-map (kbd "t"))
                                     (lookup-key ecc-chat-transcript-map (kbd "?"))
                                     (and (memq #'ecc-hint--setup-mode-line
                                                ecc-chat-mode-hook)
                                          t))))))
                   (list feature #'ecc-prompt-send #'ecc-session-visit
                         #'ecc-prompt-capf #'ecc-queue-show
                         #'ecc-hint-accept-suggestion #'ecc-menu
                         #'ecc-tui-open #'ecc-menu t)))))

;; The test above makes the buffer the way every path does; this one
;; takes the one path that loads no more than `ecc-session' on its own,
;; from the autoload on.
(ert-deftest ecc-load-test-recording-opened-cold-has-module-keys ()
  "A recording opened in an Emacs that has loaded nothing of ecc has its keys.
`ecc-history-open' is autoloaded from `ecc-history', which loads
`ecc-session' and none of the modules above `ecc-chat'; the buffer it
makes still has \\`C-c C-c' and \\`?', since making it loads the package."
  (let ((file (ecc-test-history-fixture "session")))
    (should (equal (ecc-load-test--run
                    `(progn
                       (load "ecc-autoloads" nil t)
                       (let ((id (file-name-base ,file)))
                         ;; Where the recording is: the one thing a cold
                         ;; Emacs is not told by the autoload.
                         (require 'ecc-history)
                         (puthash id ,file ecc-history--files)
                         (with-current-buffer
                             (ecc-session-buffer (ecc-history-open id))
                           (list (featurep 'ecc)
                                 (key-binding (kbd "C-c C-c"))
                                 (lookup-key ecc-chat-transcript-map (kbd "?")))))))
                   (list t #'ecc-prompt-send #'ecc-menu)))))

(ert-deftest ecc-load-test-user-bindings-survive-the-modules ()
  "A key a user binds once `ecc-chat' is loaded keeps its binding.
`ecc-chat' defines the keymaps, so `with-eval-after-load' of it is where
a user changes them; the modules above it load after it, and
their keys are in parents of those maps rather than in the maps, so they
do not overwrite what the user put there.  The keys the user left alone
still resolve to the modules' commands."
  (should (equal (ecc-load-test--run
                  '(progn
                     (with-eval-after-load 'ecc-chat
                       (define-key ecc-chat-mode-map (kbd "RET") #'ignore)
                       (define-key ecc-chat-mode-map (kbd "C-c C-c") #'ignore)
                       (define-key ecc-chat-mode-map (kbd "C-c ?") #'ignore)
                       (define-key ecc-chat-transcript-map (kbd "g") #'ignore)
                       (define-key ecc-chat-transcript-map (kbd "?") #'ignore))
                     (require 'ecc)
                     (mapcar (lambda (entry)
                               (lookup-key (symbol-value (car entry))
                                           (kbd (cdr entry))))
                             '((ecc-chat-mode-map . "RET")
                               (ecc-chat-mode-map . "C-c C-c")
                               (ecc-chat-mode-map . "C-c ?")
                               (ecc-chat-transcript-map . "g")
                               (ecc-chat-transcript-map . "?")
                               (ecc-chat-mode-map . "C-c C-x")
                               (ecc-chat-mode-map . "C-c C-z")
                               (ecc-chat-transcript-map . "RET")
                               (ecc-chat-mode-map . "C-c C-q")
                               (ecc-chat-transcript-map . "t")))))
                 (list #'ignore #'ignore #'ignore #'ignore #'ignore
                       #'ecc-prompt-toggle-context #'ecc-session-interrupt
                       #'ecc-session-visit #'ecc-queue-show #'ecc-tui-open))))

(ert-deftest ecc-load-test-reloading-a-module-keeps-the-keymaps ()
  "Loading a module that binds chat keys again leaves the keymaps as they were.
A module hangs its keymap under the chat maps once: a second load finds
it there and does not nest it again."
  (should (ecc-load-test--run
           '(let ((maps '(ecc-chat-mode-map ecc-chat-transcript-map
                          ecc-request-section-map ecc-file-section-map
                          ecc-chat-button-map)))
              (require 'ecc)
              (let ((before (mapcar (lambda (map)
                                      (copy-tree (symbol-value map)))
                                    maps)))
                (dolist (file '("ecc-prompt" "ecc-session" "ecc-queue"
                                "ecc-hint" "ecc-tui" "ecc-transient"))
                  (load file nil t))
                (equal before (mapcar (lambda (map)
                                        (copy-tree (symbol-value map)))
                                      maps)))))))

;; The NS port's input-method functions, which `ecc-chat' advises so the
;; placeholder makes way for working text.  Batch has no NS port, so the
;; tests below define stand-ins under the same names and provide
;; `ns-win', as the NS port has done by the time ecc loads.
(defconst ecc-load-test--ns-stand-ins
  '(progn
     (dolist (function '(ns-insert-working-text
                         ns-insert-marked-text
                         ns-delete-working-text))
       (defalias function #'ignore))
     (provide 'ns-win))
  "The form that makes this Emacs look like the NS port to `ecc-chat'.")

(defun ecc-load-test--advice-form ()
  "Return the form that lists every ecc function advising one not ecc's.
Each element is (ADVISED . ADVICE)."
  '(let ((found nil))
     (mapatoms
      (lambda (symbol)
        (when (and (fboundp symbol)
                   (not (string-prefix-p "ecc-" (symbol-name symbol))))
          (advice-mapc
           (lambda (advice _props)
             (when (and (symbolp advice)
                        (string-prefix-p "ecc-" (symbol-name advice)))
               (push (cons symbol advice) found)))
           symbol))))
     found))

(ert-deftest ecc-load-test-loading-advises-nothing-of-emacs ()
  "Loading every file of ecc puts no ecc advice on a function of Emacs.
On the NS port `ecc-chat' advised three input-method functions as soon
as it was loaded; the stand-ins and `ns-win' are in place first, so this
would see it."
  (let ((dir (file-name-directory (locate-library "ecc.el" t))))
    (should (equal (ecc-load-test--run
                    `(progn
                       ,ecc-load-test--ns-stand-ins
                       (dolist (file (directory-files ,dir nil "\\`ecc.*\\.el\\'"))
                         (unless (equal file "ecc-autoloads.el")
                           (require (intern (file-name-base file)))))
                       ,(ecc-load-test--advice-form)))
                   nil))))

(defconst ecc-load-test--ns-functions
  '(ns-insert-working-text ns-insert-marked-text ns-delete-working-text)
  "The NS input-method functions `ecc-chat' advises.")

(defun ecc-load-test--ns-advice-form ()
  "Return the form that says how often each NS function carries ecc's advice."
  `(mapcar (lambda (function)
             (let ((count 0))
               (advice-mapc (lambda (advice _props)
                              (when (eq advice 'ecc-chat--after-working-text)
                                (setq count (1+ count))))
                            function)
               (cons function count)))
           ',ecc-load-test--ns-functions))

(ert-deftest ecc-load-test-chat-buffer-advises-working-text ()
  "The first chat buffer advises the NS input-method functions, once.
A second buffer leaves them as the first did, and outside a chat buffer
the advice does nothing.  In an Emacs of its own, with the stand-ins of
the NS port; none of them is advised before the buffer is made."
  (should (equal
           (ecc-load-test--run
            `(progn
               ,ecc-load-test--ns-stand-ins
               (require 'ecc)
               (let ((before ,(ecc-load-test--ns-advice-form)))
                 (dolist (name '("one" "two"))
                   (ecc-session-ensure-buffer
                    (ecc-model-create-session
                     :name name :project-root temporary-file-directory)))
                 (with-temp-buffer
                   (ns-insert-working-text)
                   (ns-delete-working-text))
                 (list before ,(ecc-load-test--ns-advice-form)))))
           (list (mapcar (lambda (function) (cons function 0))
                         ecc-load-test--ns-functions)
                 (mapcar (lambda (function) (cons function 1))
                         ecc-load-test--ns-functions)))))

(ert-deftest ecc-load-test-review-ediff-alone-advises-nothing ()
  "Loading `ecc-review-ediff' leaves `ediff-recenter-one-window' as it is.
Before Emacs 31 the review puts its advice there, and used to as the
file was loaded; now an ediff review opening does it."
  (should-not (ecc-load-test--run
               '(progn
                  (require 'ecc-review-ediff)
                  (require 'ediff)
                  (advice-member-p #'ecc-review-ediff--recenter-one-window
                                   'ediff-recenter-one-window)))))

(defconst ecc-load-test--interceptors
  '((ecc-auth ecc-auth-intercept nil)
    (ecc-btw ecc-btw-intercept nil)
    (ecc-history ecc-history-resume-intercept ecc-history-resume-command)
    (ecc-hooks ecc-hooks-intercept ecc-hooks-command)
    (ecc-plugin ecc-plugin-intercept (car ecc-plugin-commands))
    (ecc-skill ecc-skill-intercept (car ecc-skill-commands)))
  "Each module that answers a command in the prompt region.
Its feature, its interceptor, and the form giving the command it puts
on `ecc-prompt-immediate-commands\=', or nil when it puts none there.")

(defun ecc-load-test--interceptors-form (&optional features)
  "Return the form that says, per module, whether it is registered.
Each element is (FEATURE ON-THE-HOOK IMMEDIATE), the last t for a
module that puts no command among the immediate ones.  FEATURES, when
given, are the modules asked about; the others may not be loaded."
  `(mapcar (lambda (entry)
             (list (nth 0 entry)
                   (and (memq (nth 1 entry) ecc-prompt-intercept-functions) t)
                   (or (null (nth 2 entry))
                       (and (member (eval (nth 2 entry) t)
                                    ecc-prompt-immediate-commands)
                            t))))
           ',(if features
                 (mapcar (lambda (feature)
                           (assq feature ecc-load-test--interceptors))
                         features)
               ecc-load-test--interceptors)))

(ert-deftest ecc-load-test-interceptors-register-with-the-package ()
  "Loading the package puts every interceptor on the prompt's hook.
The tests of each module bind the hook themselves, so they would pass
with nothing ever registered."
  (should (equal (ecc-load-test--run
                  `(progn (require 'ecc)
                          ,(ecc-load-test--interceptors-form)))
                 (mapcar (lambda (entry) (list (car entry) t t))
                         ecc-load-test--interceptors))))

(ert-deftest ecc-load-test-interceptors-register-on-their-own ()
  "Each interceptor is on the hook once its own module alone is loaded.
The hook and the immediate commands are defined in `ecc-model', which
every one of them requires, and not in `ecc-prompt' above them; so no
module waits for the prompt region to load before it registers."
  (dolist (entry ecc-load-test--interceptors)
    (let ((feature (car entry)))
      (should (equal (ecc-load-test--run
                      `(progn
                         (require ',feature)
                         ,(ecc-load-test--interceptors-form (list feature))))
                     (list (list feature t t)))))))

(ert-deftest ecc-load-test-worktree-tools-register-on-their-own ()
  "Loading `ecc-worktree' alone registers its MCP tools.
It requires `ecc-mcp' and registers them at its top level, rather than
waiting for that module to be loaded by somebody else."
  (should (equal (ecc-load-test--run
                  '(progn
                     (require 'ecc-worktree)
                     (list (and (ecc-mcp-tool "start_worktree_session") t)
                           (and (ecc-mcp-tool "list_worktrees") t)
                           (and (ecc-mcp-tool "remove_worktree") t)
                           (and (assoc "worktree-removal" ecc-mcp--instructions)
                                t))))
                 '(t t t t))))

(ert-deftest ecc-load-test-lifecycle-names-a-session-without-worktree ()
  "`ecc-lifecycle' alone names a session in a worktree and takes its baseline.
Both are `ecc-git', which it requires: neither `ecc-worktree' nor
`ecc-review' is loaded to answer, as a session started with the Spaces
off reaches neither."
  (skip-unless (executable-find "git"))
  (should (equal (ecc-load-test--run
                  '(progn
                     (require 'ecc-lifecycle)
                     (let* ((default-directory
                             (file-name-as-directory (make-temp-file "ecc-load" t)))
                            (tree (expand-file-name "tree" default-directory)))
                       (unwind-protect
                           (progn
                             (dolist (args `(("init" "-q" ".")
                                             ("commit" "-q" "--allow-empty" "-m" "init")
                                             ("worktree" "add" "-b" "feat/one" ,tree)))
                               (apply #'call-process "git" nil nil nil
                                      "-c" "user.name=t" "-c" "user.email=t@example.com"
                                      args))
                             (list (ecc-git-session-name tree)
                                   (and (stringp (ecc-git-ensure-baseline
                                                  (ecc-model-create-session
                                                   :name "probe" :project-root tree)))
                                        t)
                                   (featurep 'ecc-worktree)
                                   (featurep 'ecc-review)))
                         (delete-directory default-directory t)))))
                 '("feat/one" t nil nil))))

(ert-deftest ecc-load-test-proc-alone-registers-the-mcp-server ()
  "With `ecc-proc' alone loaded, the command line carries --mcp-config.
`ecc-proc' requires `ecc-mcp' and asks it by name, so nothing has to
load it first; with MCP off the argument is not there and no server is
started."
  (should (equal (ecc-load-test--run
                  '(progn
                     (require 'ecc-proc)
                     (let ((session (ecc-model-create-session
                                     :name "probe"
                                     :project-root temporary-file-directory))
                           (ecc-mcp-port 0))
                       (unwind-protect
                           (list (featurep 'ecc-dispatch)
                                 (let ((ecc-mcp-enabled nil))
                                   (and (member "--mcp-config"
                                                (ecc-proc-build-command session))
                                        t))
                                 (and (ecc-mcp-running-p) t)
                                 (let ((ecc-mcp-enabled t))
                                   (and (member "--mcp-config"
                                                (ecc-proc-build-command session))
                                        t)))
                         (ecc-mcp-stop)))))
                 '(nil nil nil t))))

;;;; What ecc-window reaches up to

(defun ecc-load-test--references (file)
  "Return (TOP . INNER) for the forms of FILE.
TOP is the features of ecc FILE requires at top level.  INNER is every
other reference to a module of ecc in it: (require FEATURE FEATURE) for
a `require' inside a form, and (declare FUNCTION FEATURE) for a
`declare-function'."
  (let ((top nil)
        (inner nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (cl-labels ((ecc-feature (form)
                    (and (eq (car-safe form) 'quote)
                         (symbolp (cadr form))
                         (string-prefix-p "ecc" (symbol-name (cadr form)))
                         (cadr form)))
                  (walk (form)
                    (when (consp form)
                      (pcase form
                        (`(require ,feature . ,_)
                         (when-let* ((feature (ecc-feature feature)))
                           (push (list 'require feature feature) inner)))
                        (`(declare-function ,function ,(and (pred stringp) file) . ,_)
                         (when (string-prefix-p "ecc" file)
                           (push (list 'declare function (intern file)) inner))))
                      (while (consp form)
                        (walk (car form))
                        (setq form (cdr form))))))
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (if-let* (((eq (car-safe form) 'require))
                          (feature (ecc-feature (cadr form))))
                    (push feature top)
                  (walk form))))
          (end-of-file nil))))
    (cons top inner)))

(defun ecc-load-test--upward (feature)
  "Return the references of FEATURE to a module that requires it.
A module that requires FEATURE, however indirectly, is above it, and a
`declare-function' or a `require' inside a function that names one is
a call into what loads FEATURE: the two files call each other."
  (let* ((dir (file-name-directory (locate-library "ecc.el" t)))
         (modules (mapcar (lambda (file)
                            (cons (intern (file-name-base file))
                                  (ecc-load-test--references
                                   (expand-file-name file dir))))
                          (seq-remove (lambda (file)
                                        (equal file "ecc-autoloads.el"))
                                      (directory-files dir nil "\\`ecc.*\\.el\\'"))))
         (above (lambda (target)
                  ;; Whether TARGET requires FEATURE, however indirectly.
                  (let ((seen nil)
                        (queue (list target)))
                    (while queue
                      (let ((module (pop queue)))
                        (unless (memq module seen)
                          (push module seen)
                          (setq queue (append (car (alist-get module modules))
                                              queue)))))
                    (and (memq feature (delq target seen)) t)))))
    (sort (seq-filter (lambda (reference) (funcall above (nth 2 reference)))
                      (cdr (alist-get feature modules)))
          (lambda (a b) (string< (prin1-to-string a) (prin1-to-string b))))))

(ert-deftest ecc-load-test-window-reaches-up-to-no-space ()
  "`ecc-window' calls into nothing above it but the buffer of a session.
The Spaces are built on top of the windows: what differs under them is a
generic function of `ecc-window' that `ecc-space' specialises, and no
`declare-function' or `require' of `ecc-window' names `ecc-space' or any
other module that requires it.  What is left is the buffer a session is
shown in and its prompt, which `ecc-session' and `ecc-chat' make; a
reference added here fails this, and one taken away is struck off."
  (should (equal (ecc-load-test--upward 'ecc-window)
                 '((declare ecc-chat-goto-prompt ecc-chat)
                   (declare ecc-session-ensure-buffer ecc-session)
                   (require ecc-session ecc-session)
                   (require ecc-session ecc-session)
                   (require ecc-session ecc-session)))))

(ert-deftest ecc-load-test-spaces-reached-from-a-recording ()
  "A recording opened under `spaces' is shown in a Space, in an Emacs of its own.
`ecc-window' loads nothing of `ecc-space': the Space is a method that is
there once `ecc-space' is loaded, and before that the `classic' answer
is the one given.  So whatever shows a session has to have loaded it,
or a session under `spaces' lands in a window role with no word said.
`ecc-history-open' is a way in that starts no CLI, and its autoload
loads `ecc-history' and nothing above it."
  (let ((fixture (ecc-test-history-fixture "session")))
    (should (equal (ecc-load-test--run
                    `(let* ((root (make-temp-file "ecc-load-history" t))
                            (project (expand-file-name "-tmp-project" root))
                            (id "24a1aa86-d53f-4457-b09e-4f4caf450f03"))
                       (unwind-protect
                           (progn
                             (make-directory project t)
                             (copy-file ,fixture (expand-file-name
                                                  (concat id ".jsonl") project))
                             (require 'ecc-history)
                             (setq ecc-history-directory root
                                   ecc-use-spaces t)
                             (ecc-history-open id)
                             (list (featurep 'ecc-space)
                                   (and (frame-parameter nil 'ecc-space-tabs) t)))
                         (delete-directory root t))))
                   '(t t)))))

(ert-deftest ecc-load-test-focus-project-cold-reaches-the-space ()
  "A project focused in an Emacs that has loaded nothing of ecc gets its Space.
`ecc-focus-project' is defined in `ecc-window', which loads nothing of
`ecc-space', and under `spaces' the answer is a method of `ecc-space':
an autoload that loaded `ecc-window' alone gave the `classic' one, which
refuses a project with no session.  Its autoload loads the package."
  (should (equal (ecc-load-test--run
                  `(let ((root (file-name-as-directory
                                (make-temp-file "ecc-load-focus" t))))
                     (unwind-protect
                         (progn
                           (load "ecc-autoloads" nil t)
                           ;; A Space with nothing running starts a CLI.
                           (setq ecc-use-spaces t
                                 ecc-space-always-session nil)
                           (list (condition-case error
                                     (progn (ecc-focus-project root) 'ok)
                                   (error error))
                                 (featurep 'ecc-space)
                                 (length (tab-bar-tabs))))
                       (delete-directory root t))))
                 '(ok t 2))))

(ert-deftest ecc-load-test-context-root-cold-reads-the-space ()
  "A command that asks which project it is in counts the Space showing, cold.
Under `spaces' the tab showing is the second answer, after the buffer in
front of the user, and the Space of a tab is known to `ecc-space' alone.
A tab can be a Space before `ecc-space' is loaded -- `desktop-save-mode'
puts back the tabs of a frame and its parameters -- so the commands that
start a session, the worktree ones and the review of a range load the
package before they ask.  Each reader runs in an Emacs of its own: once
one has loaded the package the others would have it too."
  (dolist (case '((ecc-lifecycle (car (ecc-start--read-arguments)))
                  (ecc-worktree (ecc-worktree-context-root))
                  (ecc-review (cdr (ecc-review-context)))))
    (should (equal (ecc-load-test--run
                    `(let ((root (file-name-as-directory
                                  (make-temp-file "ecc-load-context" t))))
                       (unwind-protect
                           (progn
                             (load "ecc-autoloads" nil t)
                             (require ',(car case))
                             (setq ecc-use-spaces t)
                             ;; A Space tab as a restored desktop leaves it.
                             (let ((key (ecc-window-project-key root)))
                               (tab-bar-new-tab)
                               (tab-bar-rename-tab "restored")
                               (set-frame-parameter
                                nil 'ecc-space-tabs (list (cons key "restored")))
                               (list ',(car case)
                                     (equal ,(cadr case) key)
                                     (featurep 'ecc-space))))
                         (delete-directory root t))))
                   (list (car case) t t)))))

(provide 'ecc-load-test)

;;; ecc-load-test.el ends here
