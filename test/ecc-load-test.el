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
;; The last are about the modules that register with one above them:
;; the interceptors of the prompt region and the MCP tools of
;; `ecc-worktree' are in place once their own module is loaded, with
;; nothing waiting for another to load.

;;; Code:

(require 'ert)

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
  "A chat buffer has the prompt's and the session's keys, whatever made it.
The keymaps are defined in `ecc-chat', and `ecc-prompt' and
`ecc-session' give them their keys; `ecc-chat-mode' loads both.  Most of
the ways to a buffer -- a recording read back, the terminal, an answer
from anywhere, a Space -- load `ecc-session' and never `ecc-prompt', so
without that a buffer would come up with no \\`C-c C-c'.  FEATURE is
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
                                     (car completion-at-point-functions))))))
                   (list feature #'ecc-prompt-send #'ecc-session-visit
                         #'ecc-prompt-capf)))))

(ert-deftest ecc-load-test-user-bindings-survive-the-modules ()
  "A key a user binds once `ecc-chat' is loaded keeps its binding.
`ecc-chat' defines the keymaps, so `with-eval-after-load' of it is where
a user changes them; `ecc-prompt' and `ecc-session' load after it, and
their keys are in parents of those maps rather than in the maps, so they
do not overwrite what the user put there.  The keys the user left alone
still resolve to the modules' commands."
  (should (equal (ecc-load-test--run
                  '(progn
                     (with-eval-after-load 'ecc-chat
                       (define-key ecc-chat-mode-map (kbd "RET") #'ignore)
                       (define-key ecc-chat-mode-map (kbd "C-c C-c") #'ignore)
                       (define-key ecc-chat-transcript-map (kbd "g") #'ignore))
                     (require 'ecc)
                     (mapcar (lambda (entry)
                               (lookup-key (symbol-value (car entry))
                                           (kbd (cdr entry))))
                             '((ecc-chat-mode-map . "RET")
                               (ecc-chat-mode-map . "C-c C-c")
                               (ecc-chat-transcript-map . "g")
                               (ecc-chat-mode-map . "C-c C-x")
                               (ecc-chat-mode-map . "C-c C-z")
                               (ecc-chat-transcript-map . "RET")))))
                 (list #'ignore #'ignore #'ignore #'ecc-prompt-toggle-context
                       #'ecc-session-interrupt #'ecc-session-visit))))

(ert-deftest ecc-load-test-reloading-a-module-keeps-the-keymaps ()
  "Loading `ecc-prompt' or `ecc-session' again leaves the keymaps as they were.
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
                (load "ecc-prompt" nil t)
                (load "ecc-session" nil t)
                (equal before (mapcar (lambda (map)
                                        (copy-tree (symbol-value map)))
                                      maps)))))))

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

(provide 'ecc-load-test)

;;; ecc-load-test.el ends here
