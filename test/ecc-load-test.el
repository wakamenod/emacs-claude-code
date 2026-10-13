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

(provide 'ecc-load-test)

;;; ecc-load-test.el ends here
