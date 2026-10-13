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
;; The other test is about the keymaps `ecc-chat' defines and the
;; modules above it bind into: whatever entry point is loaded, a chat
;; buffer comes up with their keys.

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

(defun ecc-load-test--chat-keys-probe (dir feature)
  "Return the form that loads FEATURE from DIR and prints a chat buffer's keys.
FEATURE is required as an entry point would be, and the buffer is made
the way every path makes one: `ecc-session' required at run time and
`ecc-session-ensure-buffer' called.  What is printed is one key of the
prompt, one of the transcript and the first completion function."
  `(progn
     (add-to-list 'load-path ,dir)
     (require ',feature)
     (require 'ecc-session)
     (with-current-buffer (ecc-session-ensure-buffer
                           (ecc-model-create-session
                            :name "probe" :project-root temporary-file-directory))
       (princ "\necc-load-test: ")
       (prin1 (list (key-binding (kbd "C-c C-c"))
                    (lookup-key ecc-chat-transcript-map (kbd "RET"))
                    (car completion-at-point-functions)))
       (terpri))))

(ert-deftest ecc-load-test-chat-buffer-has-module-keys ()
  "A chat buffer has the prompt's and the session's keys, whatever made it.
The keymaps are defined in `ecc-chat', and `ecc-prompt' and
`ecc-session' bind into them; `ecc-chat-mode' loads both.  Most of the
ways to a buffer -- a recording read back, the terminal, an answer from
anywhere, a Space -- load `ecc-session' and never `ecc-prompt', so
without that a buffer would come up with no \\`C-c C-c'.  Each in an Emacs of
its own, which has loaded nothing else."
  (let ((dir (file-name-directory (locate-library "ecc.el" t))))
    (dolist (feature '(ecc-chat ecc-session ecc-window ecc-space ecc-history
                                ecc-restore ecc-tui ecc-answer ecc))
      (with-temp-buffer
        (should (zerop (call-process
                        (expand-file-name invocation-name invocation-directory)
                        nil t nil "-Q" "--batch"
                        "--eval" (prin1-to-string
                                  (ecc-load-test--chat-keys-probe dir feature)))))
        (goto-char (point-min))
        (should (search-forward "ecc-load-test: " nil t))
        (should (equal (cons feature (read (current-buffer)))
                       (list feature #'ecc-prompt-send #'ecc-session-visit
                             #'ecc-prompt-capf)))))))

(provide 'ecc-load-test)

;;; ecc-load-test.el ends here
