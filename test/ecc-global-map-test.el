;;; ecc-global-map-test.el --- Tests for the keymap of every buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecc-global-map' is the prefix map a user binds to a key of their own,
;; `C-c c' in the documentation.  It is defined in ecc.el, the one file
;; that requires every module, because its keys name commands of nearly
;; all of them.  These tests say what is on it, that it binds as a prefix
;; command, and that an init with nothing but the autoloads can bind it,
;; reach every command on it and add a key to it.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc)

(ert-deftest ecc-global-map-test-keys ()
  "The global keymap carries the answer-from-anywhere commands."
  ;; And the entry points used often enough to be worth a key of their
  ;; own, spelled as `ecc-menu\=' spells them.
  (should (eq (lookup-key ecc-global-map (kbd "c")) #'ecc-start))
  ;; With the one exception `ecc-menu' keeps a menu for: r resumes.
  (should (eq (lookup-key ecc-global-map (kbd "r")) #'ecc-resume))
  (should (eq (lookup-key ecc-global-map (kbd "R")) #'ecc-rename-session))
  (should (eq (lookup-key ecc-global-map (kbd "v")) #'ecc-show-session))
  (should (eq (lookup-key ecc-global-map (kbd "i")) #'ecc-interrupt))
  (should (eq (lookup-key ecc-global-map (kbd "t")) #'ecc-tui-open))
  (should (eq (lookup-key ecc-global-map (kbd "U")) #'ecc-usage))
  (should (eq (lookup-key ecc-global-map (kbd "a")) #'ecc-answer-allow))
  (should (eq (lookup-key ecc-global-map (kbd "d")) #'ecc-answer-deny))
  (should (eq (lookup-key ecc-global-map (kbd "n")) #'ecc-next-attention))
  (should (eq (lookup-key ecc-global-map (kbd "4")) #'ecc-answer-option-4))
  ;; The Spaces have the lower-case keys, being where the day is spent.
  (should (eq (lookup-key ecc-global-map (kbd "j")) #'ecc-space-goto))
  (should (eq (lookup-key ecc-global-map (kbd "b")) #'ecc-sidebar-focus))
  (should (eq (lookup-key ecc-global-map (kbd "z")) #'ecc-space-zoom))
  (should (eq (lookup-key ecc-global-map (kbd "V")) #'ecc-space-cycle-layout))
  ;; `B' was the dashboard until 0.5.0; the sidebar is the one list.
  (should-not (lookup-key ecc-global-map (kbd "B")))
  ;; Making and removing a worktree is `ecc-worktree-menu', not a key
  ;; here: three commands that belong together, done in a week what the
  ;; keys above are done in an hour.
  (should-not (lookup-key ecc-global-map (kbd "C")))
  ;; The only way to the menu from a buffer that is not a session.
  (should (eq (lookup-key ecc-global-map (kbd "?")) #'ecc-menu)))

(ert-deftest ecc-global-map-test-is-a-prefix-command ()
  "The symbol carries the keymap too, so it can be bound as a prefix.
Bound to the value, `C-c c\=' is a complete key sequence running a
command: `C-h\=' and `which-key\=' have no prefix to list, so neither
offers what follows it.  Bound to the symbol, it is a prefix key."
  (should (keymapp (symbol-function 'ecc-global-map)))
  (should (eq (symbol-function 'ecc-global-map) ecc-global-map))
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c c") 'ecc-global-map)
    (should (keymapp (lookup-key map (kbd "C-c c"))))
    (should (eq (lookup-key map (kbd "C-c c a")) #'ecc-answer-allow))))

(ert-deftest ecc-global-map-test-is-autoloaded ()
  "`make autoloads' writes out the keymap autoload an init binds the map with.
A checkout used straight from `load-path\=' has nobody to turn the
`;;;###autoload\=' cookies into autoloads, so an init that points at one
loads ecc-autoloads.el instead of naming every command by hand.  What it
must find there is the keymap autoload -- the kind that makes the symbol
a prefix command before the package is loaded -- naming ecc.el, which
requires every module.  The commands on the map need no cookie of their
own for it: `ecc-global-map-test-first-key-loads-every-command\=' is
what the key reaches."
  (require 'loaddefs-gen)
  (let* ((dir (file-name-directory (locate-library "ecc.el" t)))
         ;; Into a directory of its own: `loaddefs-generate' scrapes only
         ;; what is newer than the output file, so writing over one that
         ;; already exists would scrape nothing and assert nothing.
         (tmp (make-temp-file "ecc-autoloads" t))
         (out (expand-file-name "ecc-autoloads.el" tmp)))
    (unwind-protect
        (progn
          (let ((inhibit-message t))
            (loaddefs-generate dir out))
          (with-temp-buffer
            (insert-file-contents out)
            (should (search-forward
                     "(autoload 'ecc-global-map \"ecc\" nil t 'keymap)"
                     nil t))))
      (delete-directory tmp t))))

(ert-deftest ecc-global-map-test-first-key-loads-every-command ()
  "In an Emacs with only the autoloads, a key of the map reaches its command.
The first key under the prefix loads ecc.el, and with it every module,
so every command the map binds is defined then -- those with no
autoload of their own, like `ecc-answer-option-1\=', included.  This
binds the map as the documentation does, looks up a key through it, and
prints every command on the map that is still not defined."
  (let* ((dir (file-name-directory (locate-library "ecc.el" t)))
         (autoloads (expand-file-name "ecc-autoloads.el" dir)))
    (skip-unless (file-exists-p autoloads))
    (with-temp-buffer
      (should (zerop (call-process
                      (expand-file-name invocation-name invocation-directory)
                      nil t nil "-Q" "--batch" "-L" dir "-l" autoloads
                      "--eval" "(global-set-key (kbd \"C-c c\") 'ecc-global-map)"
                      "--eval" "(princ (featurep 'ecc))"
                      "--eval" "(princ (key-binding (kbd \"C-c c 1\")))"
                      "--eval" "(map-keymap
                                  (lambda (_event command)
                                    (unless (and (commandp command)
                                                 (not (autoloadp (symbol-function command))))
                                      (princ (format \" undefined:%s\" command))))
                                  ecc-global-map)")))
      (should (equal (buffer-string) "nilecc-answer-option-1")))))

(ert-deftest ecc-global-map-test-bind-a-key-from-init ()
  "A key added to the map in an init is there once the map is.
`ecc-global-map\=' is autoloaded as a keymap: its function cell is
there before the package is loaded, its value is not, so a plain
`define-key\=' on it in an init signals void-variable.  The map is
defined in ecc.el, so the form waits for `ecc\=' -- not for
`ecc-answer\=', which loads before the map is defined.  This runs the
form in an Emacs that has loaded only the autoloads."
  (let* ((dir (file-name-directory (locate-library "ecc.el" t)))
         (autoloads (expand-file-name "ecc-autoloads.el" dir)))
    (skip-unless (file-exists-p autoloads))
    (with-temp-buffer
      (should (zerop (call-process
                      (expand-file-name invocation-name invocation-directory)
                      nil t nil "-Q" "--batch" "-L" dir "-l" autoloads
                      "--eval" "(with-eval-after-load 'ecc
                                  (define-key ecc-global-map \"G\" #'ecc-review-range))"
                      "--eval" "(require 'ecc)"
                      "--eval" "(princ (lookup-key ecc-global-map \"G\"))")))
      (should (string-suffix-p "ecc-review-range" (buffer-string))))))

(provide 'ecc-global-map-test)
;;; ecc-global-map-test.el ends here
