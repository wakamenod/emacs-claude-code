;;; ecc-load-test.el --- Tests for what loading the package does  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loading ecc used to put nine of its functions on the hooks of Emacs:
;; every save, every window change, every killed buffer and every exit
;; ran ecc code in an Emacs that had never started a session.  Each now
;; goes on when what it serves first exists, and its own test says
;; where.  The first says the rest: while ecc loads, it adds to and
;; takes from no hook that is not ecc's own, and advises nothing, adds
;; no function to a variable, watches no variable and starts no timer.
;; Wiring ecc to itself -- its functions on `ecc-request-added-hook' and
;; the like -- is what loading is for.  The tests after it load a small
;; file that does each of those things, to show the probe catches it.
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
;; The last are about `ecc-window', `ecc-display' and the Spaces:
;; `ecc-window' calls into no module that requires it, and
;; `ecc-display', which shows a session, into none but the sidebar; a
;; recording opened cold is shown in a Space with the sidebar, and a
;; command that asks which project it is in reads the Space of the tab.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'seq)
(require 'ecc-test-helpers)

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

;; What loading does to Emacs is seen by watching it happen: every call
;; that hangs a function on something, or leaves one to run later, is
;; recorded while a file of ecc is being loaded, along with who made it.
;; Looking at the variables afterwards, as this used to, sees only those
;; whose names look like hooks, only the functions that are symbols, and
;; no advice at all.
(defconst ecc-load-test--recorder
  '(progn
     (defvar ecc-load-test--calls nil
       "The calls recorded so far, the last first.")
     (defvar ecc-load-test--depth 0
       "How many recorded functions are running.
A recorded function another one calls on its way, as `advice-add' calls
`advice--add-function', is that one's doing and is not recorded again.")
     (defvar ecc-load-test--deferred nil
       "The features ecc has left code to run for, once each is loaded.")
     (defvar ecc-load-test--after-load nil
       "While code ecc left for a feature runs, the file of that feature.")
     (defun ecc-load-test--ecc-name-p (object)
       (and (symbolp object) (string-prefix-p "ecc-" (symbol-name object))))
     (defun ecc-load-test--recording-p ()
       "Non-nil while ecc's own code is loading: a file of ecc, or a body it left."
       (or (and load-file-name
                (string-match-p "\\`ecc.*\\.elc?\\'"
                                (file-name-nondirectory load-file-name)))
           (and ecc-load-test--after-load
                (equal (car ecc-load-test--after-load) load-file-name))))
     (defun ecc-load-test--caller (base)
       "Return who called BASE: a function, :anonymous or :top-level.
The frames between are seen through when they are the evaluator's own
-- a special form, `funcall', `byte-code' and the rest written in C --
or a macro.  Reaching the frame that loads the file is :top-level, a
form of the file itself; a closure is :anonymous, since a closure does
not say where it was written."
       (catch 'caller
         (let ((base-frame t))
           (mapbacktrace
            (lambda (_evald function _args _flags)
              (cond (base-frame (setq base-frame nil))
                    ((memq function '(load require load-with-code-conversion
                                           eval-buffer eval-region))
                     (throw 'caller :top-level))
                    ((not (symbolp function)) (throw 'caller :anonymous))
                    ((ecc-load-test--ecc-name-p function)
                     (throw 'caller function))
                    ((and (fboundp function)
                          (or (macrop function)
                              (subr-primitive-p (indirect-function function)))))
                    (t (throw 'caller function))))
            base))
         :top-level))
     (defun ecc-load-test--describe (object)
       (if (symbolp object) object (format "%S" object)))
     (defun ecc-load-test--record (name place function)
       (push (list name (ecc-load-test--describe place)
                   (ecc-load-test--describe function)
                   (ecc-load-test--caller name)
                   (file-name-nondirectory (or load-file-name "")))
             ecc-load-test--calls))
     (defun ecc-load-test--recorder (name place function)
       "Return the advice that records each call of NAME.
PLACE and FUNCTION are where in the arguments the place and the function
are, or nil."
       (lambda (original &rest args)
         (when (and (zerop ecc-load-test--depth) (ecc-load-test--recording-p))
           (ecc-load-test--record name (and place (nth place args))
                                  (nth function args)))
         (let ((ecc-load-test--depth (1+ ecc-load-test--depth)))
           (apply original args))))
     (dolist (spec '((add-hook 0 1) (remove-hook 0 1)
                     (advice-add 0 2) (advice-remove 0 1)
                     (advice--add-function 1 2)
                     (add-variable-watcher 0 1)
                     (run-at-time nil 2) (run-with-timer nil 2)
                     (run-with-idle-timer nil 2)))
       (advice-add (car spec) :around (apply #'ecc-load-test--recorder spec)))
     ;; What ecc leaves for a feature not loaded yet runs when that
     ;; feature is, outside any file of ecc: it is recorded as ecc's, and
     ;; the probe loads the feature to run it.
     (advice-add
      'eval-after-load :filter-args
      (lambda (args)
        (if (not (and (zerop ecc-load-test--depth) (ecc-load-test--recording-p)))
            args
          (ecc-load-test--record 'eval-after-load (car args) (cadr args))
          (push (car args) ecc-load-test--deferred)
          (let ((form (cadr args)))
            (list (car args)
                  (lambda ()
                    (let ((ecc-load-test--after-load (list load-file-name)))
                      (if (functionp form) (funcall form) (eval form t))))))))))
  "The form that records, in the Emacs it runs in, what loading ecc does.
Each call is (NAME PLACE FUNCTION CALLER FILE): NAME is the function
called, PLACE the hook, function or variable it changes, FUNCTION what
it puts there or takes away, CALLER who called it as
`ecc-load-test--caller' says, and FILE the file being loaded.  A
place or function that is not a symbol is recorded as its printed form.")

(defun ecc-load-test--probe (dir)
  "Return what loading every file of ecc in DIR does, as recorded.
Every file, and not `ecc' alone: some are loaded only once a feature is
used, and their top level runs then all the same.  The NS port's
stand-ins come first, so that what `ecc-chat' does there runs too.  The
value is a list of the calls `ecc-load-test--recorder' describes, in
the order they were made."
  (ecc-load-test--run
   `(progn
      ,ecc-load-test--ns-stand-ins
      ,ecc-load-test--recorder
      (add-to-list 'load-path ,dir)
      (dolist (file (directory-files ,dir nil "\\`ecc.*\\.el\\'"))
        (unless (equal file "ecc-autoloads.el")
          (require (intern (file-name-base file)))))
      (dolist (feature (reverse ecc-load-test--deferred))
        (if (symbolp feature) (require feature nil t) (load feature t t)))
      (reverse ecc-load-test--calls))))

(defun ecc-load-test--ecc-name-p (object)
  "Non-nil when OBJECT is a symbol named as ecc's."
  (and (symbolp object) (string-prefix-p "ecc-" (symbol-name object))))

(defun ecc-load-test--ecc-call-p (call)
  "Non-nil when CALL, as the probe records it, is ecc's doing.
It is when what it puts somewhere is an ecc function, or when ecc's code
made it: a function of ecc, a closure, or a form at the top level of a
file of ecc.  What is left is Emacs's own code doing its own work while
ecc loads -- `package-get-version' turning on `emacs-lisp-mode' in a
buffer of its own, which puts that mode's functions on its hooks."
  (pcase-let ((`(,_name ,_place ,function ,caller . ,_) call))
    (or (ecc-load-test--ecc-name-p function)
        (keywordp caller)
        (ecc-load-test--ecc-name-p caller))))

(defun ecc-load-test--offence-p (call)
  "Non-nil when CALL changes something that is not ecc's.
Adding to or taking from a hook of ecc is what loading is for, and
leaving code for a feature is not a change until that feature loads,
when what the code does is recorded in turn.  Anything else is not ecc's:
a hook of Emacs, advice, a variable watcher or a timer."
  (pcase-let ((`(,name ,place . ,_) call))
    (not (or (eq name 'eval-after-load)
             (and (memq name '(add-hook remove-hook))
                  (ecc-load-test--ecc-name-p place))))))

(defun ecc-load-test--offences (calls)
  "Return the calls among CALLS that are ecc's and change what is not ecc's."
  (seq-filter #'ecc-load-test--offence-p
              (seq-filter #'ecc-load-test--ecc-call-p calls)))

(ert-deftest ecc-load-test-loading-puts-nothing-on-emacs-hooks ()
  "Loading every file of ecc changes nothing of Emacs's: it only wires ecc to itself.
In an Emacs of its own, since in this one the other tests have long
since opened the reviews, Spaces and sessions that change things.  While
a file of ecc loads, every `add-hook', `remove-hook', `advice-add',
`advice-remove', `add-function' (`advice--add-function'),
`add-variable-watcher', `run-at-time', `run-with-timer' and
`run-with-idle-timer' is recorded, whatever the name of the hook or
variable, whether the function is a symbol or a closure, global or
buffer-local; a body left with `with-eval-after-load' is run by loading
its feature, and recorded the same.  Each one ecc made must add to or
take from a hook named ecc-, and nothing else may be there.  What
Emacs's own functions do on their own account during the load is not
ecc's, as `ecc-load-test--ecc-call-p' says; the tests on
`ecc-load-test--fixture' show that each kind of change is caught."
  (let* ((calls (ecc-load-test--probe
                 (file-name-directory (locate-library "ecc.el" t))))
         (ecc (seq-filter #'ecc-load-test--ecc-call-p calls)))
    ;; A recorder that saw nothing would pass the rest.
    (should (seq-find (lambda (call) (eq (car call) 'add-hook)) ecc))
    (should-not (ecc-load-test--offences calls))))

(defun ecc-load-test--fixture (source &optional compile)
  "Return what the probe records of a file of ecc whose body is SOURCE.
SOURCE is a string of forms.  The file, ecc-zz-probe-fixture.el, defines
`ecc-zz-f' and `zz-probe-later', a feature of its own to defer to,
before SOURCE.  It is byte-compiled first when COMPILE is non-nil, so
that the forms run as byte-code, as the package's own do."
  (let ((dir (make-temp-file "ecc-load-test-" t)))
    (unwind-protect
        (let ((file (expand-file-name "ecc-zz-probe-fixture.el" dir)))
          (with-temp-file (expand-file-name "zz-probe-later.el" dir)
            (insert ";;; -*- lexical-binding: t -*-\n(provide 'zz-probe-later)\n"))
          (with-temp-file file
            (insert ";;; ecc-zz-probe-fixture.el --- -*- lexical-binding: t -*-\n"
                    "(defun ecc-zz-f (&rest _) nil)\n"
                    "(defvar zz-probe-foo-function #'ignore)\n"
                    source
                    "\n(provide 'ecc-zz-probe-fixture)\n"))
          (when compile
            (let ((byte-compile-warnings nil)
                  (load-path (cons dir load-path)))
              (should (byte-compile-file file))))
          (ecc-load-test--probe dir))
      (delete-directory dir t))))

(defmacro ecc-load-test--should-catch (source name)
  "Check that a fixture whose body is SOURCE is caught for a call of NAME.
Both as source and as byte-code."
  `(dolist (compile '(nil t))
     (let ((offences (ecc-load-test--offences
                      (ecc-load-test--fixture ,source compile))))
       (should (equal (list compile (mapcar #'car offences))
                      (list compile '(,name)))))))

(ert-deftest ecc-load-test-probe-catches-a-function-on-an-emacs-hook ()
  "An ecc function put on a hook of Emacs is caught."
  (ecc-load-test--should-catch
   "(add-hook 'post-command-hook #'ecc-zz-f)" add-hook))

(ert-deftest ecc-load-test-probe-catches-a-closure-on-an-emacs-hook ()
  "A closure put on a hook of Emacs by a file of ecc is caught.
At the top level, from a loop over the hooks, and from inside a
function of Emacs that calls the closure, `mapc'."
  (ecc-load-test--should-catch
   "(add-hook 'post-command-hook (lambda () nil))" add-hook)
  (ecc-load-test--should-catch
   "(dolist (hook '(post-command-hook)) (add-hook hook (lambda () nil)))"
   add-hook)
  (ecc-load-test--should-catch
   "(mapc (lambda (hook) (add-hook hook #'ignore)) '(post-command-hook))"
   add-hook))

(ert-deftest ecc-load-test-probe-catches-any-hook-name ()
  "A hook whose name ends in -hooks, or in nothing like a hook, is caught."
  (ecc-load-test--should-catch
   "(defvar some-mode-hooks nil) (add-hook 'some-mode-hooks #'ecc-zz-f)"
   add-hook)
  (ecc-load-test--should-catch
   "(defvar zz-probe-listeners nil) (add-hook 'zz-probe-listeners #'ecc-zz-f)"
   add-hook)
  (ecc-load-test--should-catch
   "(remove-hook 'post-command-hook #'ecc-zz-f)" remove-hook))

(ert-deftest ecc-load-test-probe-catches-advice ()
  "Advice on a function of Emacs, and its removal, are caught."
  (ecc-load-test--should-catch
   "(advice-add 'message :around #'ecc-zz-f)" advice-add)
  (ecc-load-test--should-catch
   "(advice-add 'message :around (lambda (f &rest args) (apply f args)))"
   advice-add)
  (ecc-load-test--should-catch
   "(advice-remove 'message #'ecc-zz-f)" advice-remove))

(ert-deftest ecc-load-test-probe-catches-add-function ()
  "`add-function' on a variable, global or buffer-local, is caught."
  (ecc-load-test--should-catch
   "(add-function :before zz-probe-foo-function #'ecc-zz-f)"
   advice--add-function)
  (ecc-load-test--should-catch
   "(add-function :before (local 'zz-probe-foo-function) #'ecc-zz-f)"
   advice--add-function))

(ert-deftest ecc-load-test-probe-catches-timers-and-watchers ()
  "A timer or a variable watcher started by loading is caught."
  (ecc-load-test--should-catch "(run-at-time 60 nil #'ecc-zz-f)" run-at-time)
  (ecc-load-test--should-catch "(run-with-timer 60 nil #'ecc-zz-f)" run-with-timer)
  (ecc-load-test--should-catch
   "(run-with-idle-timer 60 nil (lambda () nil))" run-with-idle-timer)
  (ecc-load-test--should-catch
   "(add-variable-watcher 'fill-column #'ecc-zz-f)" add-variable-watcher))

(ert-deftest ecc-load-test-probe-catches-what-loading-calls ()
  "A function of ecc called at load time is ecc's, whatever it puts on a hook."
  (ecc-load-test--should-catch
   "(defun ecc-zz-install () (add-hook 'post-command-hook #'ignore))
(ecc-zz-install)"
   add-hook))

(ert-deftest ecc-load-test-probe-catches-what-is-left-for-later ()
  "What a file of ecc leaves for a feature to run is recorded when it runs.
The probe loads the feature, so a hook the body puts a function on is
caught, though no file of ecc is loading by then."
  (ecc-load-test--should-catch
   "(with-eval-after-load 'zz-probe-later
  (add-hook 'post-command-hook #'ecc-zz-f))"
   add-hook))

(ert-deftest ecc-load-test-probe-lets-ecc-wire-itself ()
  "Adding to and taking from ecc's own hooks is no offence, and is recorded.
Function or closure, at the top level or in a body left for a feature."
  (dolist (compile '(nil t))
    (let ((calls (ecc-load-test--fixture
                  "(defvar ecc-zz-thing-hook nil)
(defvar ecc-zz-thing-functions nil)
(add-hook 'ecc-zz-thing-hook #'ecc-zz-f)
(add-hook 'ecc-zz-thing-functions (lambda (&rest _) nil))
(remove-hook 'ecc-zz-thing-hook #'ecc-zz-f)
(with-eval-after-load 'zz-probe-later
  (add-hook 'ecc-zz-thing-hook #'ecc-zz-f))"
                  compile)))
      (should (equal (list compile
                           (mapcar #'car (seq-filter #'ecc-load-test--ecc-call-p
                                                     calls))
                           (ecc-load-test--offences calls))
                     (list compile
                           '(add-hook add-hook remove-hook eval-after-load
                                      add-hook)
                           nil))))))

(ert-deftest ecc-load-test-probe-leaves-emacs-to-itself ()
  "What a function of Emacs does on its own account while ecc loads is not ecc's.
`emacs-lisp-mode' in a buffer of its own puts the mode's functions on
its hooks, as `package-get-version' has it do when ecc asks for its
version.  The probe records those calls and finds them Emacs's: their
functions are not ecc's, and a function of Emacs made them."
  (let ((calls (ecc-load-test--fixture
                "(with-temp-buffer (emacs-lisp-mode))")))
    (should (seq-find (lambda (call) (eq (car call) 'add-hook)) calls))
    (should-not (seq-filter #'ecc-load-test--ecc-call-p calls))))

;; ecc does not register its prompt history with savehist: a user who
;; wants it kept adds it to `savehist-additional-variables' themselves.
(ert-deftest ecc-load-test-savehist-is-left-alone ()
  "Loading ecc adds nothing to `savehist-additional-variables'.
Neither with savehist loaded first nor with it loaded after."
  (dolist (savehist-first '(t nil))
    (should
     (equal
      (list savehist-first nil)
      (ecc-load-test--run
       `(let ((dir (file-name-directory (locate-library "ecc.el" t))))
          (when ,savehist-first (require 'savehist))
          (dolist (file (directory-files dir nil "\\`ecc.*\\.el\\'"))
            (unless (equal file "ecc-autoloads.el")
              (require (intern (file-name-base file)))))
          ;; Loading savehist is what the old registration waited for;
          ;; `savehist-mode' would read and write the user's history file.
          (require 'savehist)
          (list ,savehist-first
                (memq 'ecc-prompt-history savehist-additional-variables))))))))

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
`ecc-queue', `ecc-hint', `ecc-tui', `ecc-display', `ecc-btw' and
`ecc-transient' give them their keys; `ecc-session-ensure-buffer', in `ecc-chat' too, loads the whole
package before it makes the buffer.  Most of the ways to a buffer -- a
recording read back, the terminal, an answer from anywhere, a Space --
load `ecc-chat' and never `ecc-prompt' or `ecc-transient', so without
that a buffer would come up with no \\`C-c C-c' and no \\`?'.  FEATURE is
required as that entry point would be, and the buffer is made the way
every path makes one: `ecc-chat' required and
`ecc-session-ensure-buffer' called."
  (dolist (feature '(ecc-chat ecc-session ecc-window ecc-space ecc-history
                              ecc-restore ecc-tui ecc-answer ecc))
    (should (equal (cons feature
                         (ecc-load-test--run
                          `(progn
                             (require ',feature)
                             (require 'ecc-chat)
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
                                     (key-binding (kbd "C-c C-t"))
                                     (key-binding (kbd "C-c C-b"))
                                     (and (memq #'ecc-hint--setup-mode-line
                                                ecc-chat-mode-hook)
                                          t))))))
                   (list feature #'ecc-prompt-send #'ecc-session-visit
                         #'ecc-prompt-capf #'ecc-queue-show
                         #'ecc-hint-accept-suggestion #'ecc-menu
                         #'ecc-tui-open #'ecc-menu #'ecc-switch-session #'ecc-btw-show t)))))

;; The test above makes the buffer the way every path does; this one
;; takes the one path that loads no more than `ecc-chat' on its own,
;; from the autoload on.
(ert-deftest ecc-load-test-recording-opened-cold-has-module-keys ()
  "A recording opened in an Emacs that has loaded nothing of ecc has its keys.
`ecc-history-open' is autoloaded from `ecc-history', which loads
`ecc-chat' and none of the modules above it; the buffer it makes still
has \\`C-c C-c' and \\`?', since making it loads the package."
  (let ((file (ecc-test-history-fixture "session")))
    (should (equal (ecc-load-test--run
                    `(progn
                       (load "ecc-autoloads" nil t)
                       (let ((id (file-name-base ,file)))
                         ;; Where the recording is: the one thing a cold
                         ;; Emacs is not told by the autoload.
                         (require 'ecc-history)
                         (puthash id ,file ecc-history--files)
                         (list (featurep 'ecc-session)
                               (with-current-buffer
                                   (ecc-session-buffer (ecc-history-open id))
                                 (list (featurep 'ecc)
                                       (key-binding (kbd "C-c C-c"))
                                       (lookup-key ecc-chat-transcript-map
                                                   (kbd "?"))))))))
                   (list nil (list t #'ecc-prompt-send #'ecc-menu))))))

(ert-deftest ecc-load-test-chat-mode-loads-nothing ()
  "`ecc-chat-mode' loads nothing above `ecc-chat'; making a session buffer does.
The mode is the buffer's keymaps and its drawing, and the modules above
give it their keys from below; what loads them is
`ecc-session-ensure-buffer', which makes the buffer."
  (should (equal (ecc-load-test--run
                  '(progn
                     (require 'ecc-chat)
                     (with-temp-buffer (ecc-chat-mode))
                     (list (featurep 'ecc) (featurep 'ecc-session))))
                 '(nil nil))))

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
                       (define-key ecc-chat-transcript-map (kbd "?") #'ignore)
                       (define-key ecc-request-section-map (kbd "c") #'ignore)
                       (define-key ecc-request-section-map (kbd "a") #'ignore)
                       (define-key ecc-history-button-map (kbd "RET") #'ignore))
                     (require 'ecc)
                     (mapcar (lambda (entry)
                               (lookup-key (symbol-value (car entry))
                                           (kbd (cdr entry))))
                             '((ecc-chat-mode-map . "RET")
                               (ecc-chat-mode-map . "C-c C-c")
                               (ecc-chat-mode-map . "C-c ?")
                               (ecc-chat-transcript-map . "g")
                               (ecc-chat-transcript-map . "?")
                               (ecc-request-section-map . "c")
                               (ecc-request-section-map . "a")
                               (ecc-chat-mode-map . "C-c C-x")
                               (ecc-chat-mode-map . "C-c C-z")
                               (ecc-chat-transcript-map . "RET")
                               (ecc-chat-mode-map . "C-c C-q")
                               (ecc-chat-transcript-map . "t")
                               (ecc-request-section-map . "e")
                               (ecc-request-section-map . "d")
                               (ecc-chat-transcript-map . "a")
                               (ecc-chat-mode-map . "C-c C-a")
                               (ecc-history-button-map . "RET")
                               (ecc-history-button-map . "<mouse-2>")))))
                 (list #'ignore #'ignore #'ignore #'ignore #'ignore #'ignore #'ignore
                       #'ecc-prompt-toggle-context #'ecc-session-interrupt
                       #'ecc-session-visit #'ecc-queue-show #'ecc-tui-open
                       #'ecc-review-edit-proposal #'ecc-perm-deny
                       #'ecc-perm-allow #'ecc-perm-allow
                       #'ignore #'ecc-history-load-more))))

(ert-deftest ecc-load-test-request-keys-come-with-the-review ()
  "The comment and the edit on a request are the review's, not the chat's.
`ecc-chat' defines `ecc-request-section-map' and binds no command of a
module above it there, so with `ecc-chat' alone \\`c' and \\`e' are
not the review's; `ecc-review' hangs its keymap under the map, and with
the package loaded they are."
  (should (equal (ecc-load-test--run
                  '(let ((keys (lambda ()
                                 (list (lookup-key ecc-request-section-map (kbd "c"))
                                       (lookup-key ecc-request-section-map (kbd "e"))))))
                     (require 'ecc-chat)
                     (list (featurep 'ecc-review)
                           (funcall keys)
                           (progn (require 'ecc) (funcall keys)))))
                 (list nil (list nil nil)
                       (list #'ecc-review-comment-request
                             #'ecc-review-edit-proposal)))))

(ert-deftest ecc-load-test-review-keys-come-with-their-modules ()
  "The files pane, talking and a pull request keep their review keys.
`ecc-review' defines `ecc-review-mode-map' and binds no command of
`ecc-review-files', `ecc-review-talk' or `ecc-review-pr' in it, so with
`ecc-review' alone the three are not loaded and those keys are unbound
or `diff-mode''s; each hangs its keymap under the map, and with the
package loaded they are theirs."
  (should (equal (ecc-load-test--run
                  '(let ((keys (lambda ()
                                 (mapcar (lambda (key)
                                           (lookup-key ecc-review-mode-map (kbd key)))
                                         '("s" "/" "T" "t" "M" "]" "[" "C-c C-a")))))
                     (require 'ecc-review)
                     (list (seq-filter #'featurep
                                       '(ecc-review-files ecc-review-talk ecc-review-pr))
                           (funcall keys)
                           (progn (require 'ecc) (funcall keys)))))
                 (list nil
                       (list nil nil nil nil nil nil nil #'diff-apply-hunk)
                       (list #'ecc-review-files-toggle #'ecc-review-files-filter
                             #'ecc-review-talk-tour #'ecc-review-talk-next
                             #'ecc-review-talk-message
                             #'ecc-review-pr-next-commit #'ecc-review-pr-previous-commit
                             #'ecc-review-pr-send-all)))))

(ert-deftest ecc-load-test-review-keeps-the-keys-of-diff-mode ()
  "A review buffer has the keys of `diff-mode' under those of the modules.
`define-derived-mode' puts `diff-mode-map' under `ecc-review-mode-map'
only when that has no parent when the mode is first turned on, and by
then the modules above `ecc-review' have hung theirs: the map says its
parent itself, so \\`M-n' still moves to the next hunk."
  (should (equal (ecc-load-test--run
                  '(progn
                     (require 'ecc)
                     (with-temp-buffer
                       (ecc-review-mode)
                       (mapcar (lambda (key) (key-binding (kbd key)))
                               '("M-n" "M-p" "o" "s" "C-c C-a" "c" "k")))))
                 (list #'diff-hunk-next #'diff-hunk-prev #'diff-goto-source
                       #'ecc-review-files-toggle #'ecc-review-pr-send-all
                       #'ecc-review-comment #'ecc-review-read-only))))

(ert-deftest ecc-load-test-user-review-bindings-survive-the-modules ()
  "A key a user binds once `ecc-review' is loaded keeps its binding.
The keys of `ecc-review-files', `ecc-review-talk' and `ecc-review-pr'
are in parents of `ecc-review-mode-map', so loading them does not
overwrite what the user put in the map; the keys left alone still
resolve to the modules' commands."
  (should (equal (ecc-load-test--run
                  '(progn
                     (with-eval-after-load 'ecc-review
                       (define-key ecc-review-mode-map (kbd "s") #'ignore)
                       (define-key ecc-review-mode-map (kbd "t") #'ignore)
                       (define-key ecc-review-mode-map (kbd "C-c C-a") #'ignore))
                     (require 'ecc)
                     (mapcar (lambda (key) (lookup-key ecc-review-mode-map (kbd key)))
                             '("s" "t" "C-c C-a" "/" "T" "]"))))
                 (list #'ignore #'ignore #'ignore
                       #'ecc-review-files-filter #'ecc-review-talk-tour
                       #'ecc-review-pr-next-commit))))

(ert-deftest ecc-load-test-permission-keys-come-with-the-perm ()
  "The answers to a request are the keys of `ecc-perm', not of the chat.
`ecc-chat' defines the keymaps and binds no command of `ecc-perm' in
them, so with `ecc-chat' alone `ecc-perm' is not loaded and the keys are
unbound, \`d' on a request falling through to the transcript's; with
the package loaded they are the allow, the deny and the rest."
  (should (equal (ecc-load-test--run
                  '(let ((keys (lambda ()
                                 (mapcar (lambda (entry)
                                           (lookup-key (symbol-value (car entry))
                                                       (kbd (cdr entry))))
                                         '((ecc-chat-mode-map . "C-c C-a")
                                           (ecc-chat-mode-map . "C-c C-d")
                                           (ecc-chat-transcript-map . "a")
                                           (ecc-request-section-map . "a")
                                           (ecc-request-section-map . "d")
                                           (ecc-request-section-map . "A")
                                           (ecc-request-section-map . "u")
                                           (ecc-request-section-map . "r"))))))
                     (require 'ecc-chat)
                     (list (featurep 'ecc-perm)
                           (funcall keys)
                           (progn (require 'ecc) (funcall keys)))))
                 (list nil (list nil nil nil nil nil nil nil nil)
                       (list #'ecc-perm-allow #'ecc-perm-deny #'ecc-perm-allow
                             #'ecc-perm-allow #'ecc-perm-deny
                             #'ecc-perm-allow-always #'ecc-perm-approve-turn
                             #'ecc-perm-add-pattern)))))

(ert-deftest ecc-load-test-history-button-keys-come-with-the-history ()
  "The button above the first turn reads the older page once `ecc-history' is in.
`ecc-render' draws the button with `ecc-history-button-map' and names no
command of `ecc-history'; with `ecc-render' and `ecc-chat' alone its
keys are the transcript's button keys, and `ecc-history' is not loaded."
  (should (equal (ecc-load-test--run
                  '(let ((keys (lambda ()
                                 (list (lookup-key ecc-history-button-map (kbd "RET"))
                                       (lookup-key ecc-history-button-map [mouse-2])))))
                     (require 'ecc-render)
                     (require 'ecc-chat)
                     (list (featurep 'ecc-history)
                           (funcall keys)
                           (progn (require 'ecc) (funcall keys)))))
                 (list nil (list #'push-button #'push-button)
                       (list #'ecc-history-load-more #'ecc-history-load-more)))))

(ert-deftest ecc-load-test-reloading-a-module-keeps-the-keymaps ()
  "Loading a module that binds chat or review keys again leaves the keymaps be.
A module hangs its keymap under the chat maps, or the review's, once: a
second load finds it there and does not nest it again."
  (should (ecc-load-test--run
           '(let ((maps '(ecc-chat-mode-map ecc-chat-transcript-map
                          ecc-request-section-map ecc-file-section-map
                          ecc-chat-button-map ecc-history-button-map
                          ecc-review-mode-map)))
              (require 'ecc)
              (let ((before (mapcar (lambda (map)
                                      (copy-tree (symbol-value map)))
                                    maps)))
                (dolist (file '("ecc-prompt" "ecc-session" "ecc-queue"
                                "ecc-hint" "ecc-tui" "ecc-transient" "ecc-review"
                                "ecc-history" "ecc-perm" "ecc-review-files"
                                "ecc-review-talk" "ecc-review-pr"))
                  (load file nil t))
                (equal before (mapcar (lambda (map)
                                        (copy-tree (symbol-value map)))
                                      maps)))))))

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

;;;; What ecc-window and ecc-display reach up to

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
  "`ecc-window' calls into nothing above it.
The Spaces are built on top of the windows: what differs under them is a
generic function that `ecc-space' specialises, and no `declare-function'
or `require' of `ecc-window' names `ecc-space' or any other module that
requires it.  Showing a session, which needs the buffer `ecc-chat'
makes, is `ecc-display', above both."
  (should (equal (ecc-load-test--upward 'ecc-window) nil)))

(ert-deftest ecc-load-test-display-reaches-up-to-the-sidebar-alone ()
  "`ecc-display' calls into nothing above it but the sidebar.
Everything that shows a session requires it, so a `declare-function' or
a `require' inside a function of it that names one of those is a call
into what loads it.  The one kept is the sidebar, put in every new
Space tab and redrawn when a Space closes; a reference added here fails
this, and one taken away is struck off."
  (should (equal (ecc-load-test--upward 'ecc-display)
                 '((declare ecc-sidebar-redraw ecc-sidebar)
                   (declare ecc-sidebar-show ecc-sidebar)
                   (require ecc-sidebar ecc-sidebar)
                   (require ecc-sidebar ecc-sidebar)))))

(ert-deftest ecc-load-test-only-chat-loads-the-package ()
  "No module but `ecc-chat' loads `ecc' at run time.
`ecc' requires every module, so a module loading it is a call to the
top.  There is one, `ecc--require-package', beside the function that
makes a session buffer, and every command that wants the package calls
it."
  (let ((dir (file-name-directory (locate-library "ecc.el" t))))
    (should (equal (seq-filter
                    (lambda (file)
                      (member '(require ecc ecc)
                              (cdr (ecc-load-test--references
                                    (expand-file-name file dir)))))
                    (directory-files dir nil "\\`ecc.*\\.el\\'"))
                   '("ecc-chat.el")))))

(ert-deftest ecc-load-test-spaces-reached-from-a-recording ()
  "A recording opened cold is shown in a Space, in an Emacs of its own.
`ecc-history-open' is a way in that starts no CLI, and its autoload
loads `ecc-history' and nothing above it; it shows the session through
`ecc-display', which makes the Space.  Making the session buffer loads
the rest of the package, `ecc-space' with it."
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
                             (setq ecc-history-directory root)
                             (ecc-history-open id)
                             (list (featurep 'ecc-space)
                                   (and (frame-parameter nil 'ecc-space-tabs) t)))
                         (delete-directory root t))))
                   '(t t)))))

(ert-deftest ecc-load-test-the-first-space-has-the-sidebar ()
  "The first Space tab of an Emacs shows the sidebar, and so does the next.
A tab carries its own windows, so `ecc-display' puts the sidebar in
every Space tab it makes, from the first one on: not only once the
sidebar has been shown by hand, which is what a subscription of the
sidebar's own would give.  The way in is a recording opened cold, which
starts no CLI."
  (let ((fixture (ecc-test-history-fixture "session")))
    (should (equal (ecc-load-test--run
                    `(let* ((root (make-temp-file "ecc-load-history" t))
                            (project (expand-file-name "-tmp-project" root))
                            (other (file-name-as-directory
                                    (make-temp-file "ecc-load-other" t)))
                            (id "24a1aa86-d53f-4457-b09e-4f4caf450f03"))
                       (unwind-protect
                           (progn
                             (make-directory project t)
                             (copy-file ,fixture (expand-file-name
                                                  (concat id ".jsonl") project))
                             (require 'ecc-history)
                             (setq ecc-history-directory root)
                             (ecc-history-open id)
                             (let ((first (and (get-buffer-window "*ecc-sidebar*") t)))
                               (ecc-space--select-tab (ecc-space-of-root other))
                               (list first
                                     (and (get-buffer-window "*ecc-sidebar*") t)
                                     (length (tab-bar-tabs)))))
                         (delete-directory root t)
                         (delete-directory other t))))
                   '(t t 3)))))

(ert-deftest ecc-load-test-context-root-cold-reads-the-space ()
  "A command that asks which project it is in counts the Space showing, cold.
The tab showing is the second answer, after the buffer in front of the
user, and the Space of a tab is known to `ecc-display'.  A tab can be a
Space before anything of ecc is loaded -- `desktop-save-mode' puts back
the tabs of a frame and its parameters -- and the commands that start a
session, the worktree ones and the review of a range all reach
`ecc-display' through what they require.  Each reader runs in an Emacs
of its own: once one has loaded the package the others would have it
too."
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
                             ;; A Space tab as a restored desktop leaves it.
                             (let ((key (ecc-window-project-key root)))
                               (tab-bar-new-tab)
                               (tab-bar-rename-tab "restored")
                               (set-frame-parameter
                                nil 'ecc-space-tabs (list (cons key "restored")))
                               (list ',(car case)
                                     (equal ,(cadr case) key)
                                     (featurep 'ecc-display))))
                         (delete-directory root t))))
                   (list (car case) t t)))))

(ert-deftest ecc-load-test-review-cold-opens-the-style ()
  "A review opened in an Emacs that has loaded nothing of ecc is in its style.
`ecc-review' and `ecc-review-range' are autoloaded from `ecc-review',
which loads nothing of `ecc-review-ediff', and the `ediff' style is a
method of `ecc-review-ediff': without the package loaded first, the
review would silently be a diff.  What would open is stood in for --
an ediff wants a frame -- but the dispatch is the real one.  Each
command runs in an Emacs of its own: once one has loaded the package
the other would have it too."
  (skip-unless (executable-find "git"))
  (dolist (call '((ecc-review session)
                  (ecc-review-range session "HEAD" root)))
    (should (equal (ecc-load-test--run
                    `(let ((root (file-name-as-directory
                                  (make-temp-file "ecc-load-review" t))))
                       (unwind-protect
                           (let ((default-directory root))
                             (call-process "git" nil nil nil "init" "-q")
                             (load "ecc-autoloads" nil t)
                             (require 'ecc-model)
                             (setq ecc-review-style 'ediff)
                             (dolist (name '(ecc-review-ediff-buffer
                                             ecc-review-ediff-range-buffer))
                               (advice-add name :override (lambda (&rest _) 'ediff)))
                             (dolist (name '(ecc-review-buffer ecc-review-range-buffer))
                               (advice-add name :override #'ignore))
                             (advice-add 'ecc-review--display :override
                                         (lambda (&rest _) 'diff))
                             (let ((session (ecc-model-create-session
                                             :name "cold" :project-root root)))
                               (list (featurep 'ecc-review-ediff)
                                     ,call
                                     (featurep 'ecc-review-ediff))))
                         (delete-directory root t))))
                   '(nil ediff t)))))

(provide 'ecc-load-test)

;;; ecc-load-test.el ends here
