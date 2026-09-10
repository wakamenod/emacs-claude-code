;;; ecc-inline-test.el --- Tests for ecc-inline  -*- lexical-binding: t; -*-

;;; Commentary:

;; The inline prompt and the rewrite.  No CLI is started: the inline
;; half is driven through a fake session, and the rewrite half through
;; the answer a `claude -p' would have written.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-inline)
(require 'ecc-session)

(defmacro ecc-inline-test-with-source (var &rest body)
  "Run BODY in a source buffer bound to VAR, with the overlay cleaned up."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (generate-new-buffer "*ecc-inline-source*")))
     (unwind-protect
         (with-current-buffer ,var
           (emacs-lisp-mode)
           (insert "(defun one () 1)\n(defun two () 2)\n")
           (goto-char (point-min))
           ,@body)
       (kill-buffer ,var))))

;;;; The overlay

(ert-deftest ecc-inline-test-window ()
  "The overlay shows a page of the answer and says how much is left."
  (let ((ecc-inline-max-lines 2)
        (text "one\ntwo\nthree\nfour"))
    (should (equal (ecc-inline-window text 0) '("one\ntwo" . 2)))
    (should (equal (ecc-inline-window text 2) '("three\nfour" . 0)))
    ;; An offset past the end shows the last line rather than nothing.
    (should (equal (ecc-inline-window text 99) '("four" . 0)))
    (should (equal (ecc-inline-window "" 0) '("" . 0)))))

(ert-deftest ecc-inline-test-show-and-scroll ()
  "The answer is shown, scrolls inside the overlay and goes away with q."
  (ecc-inline-test-with-source buffer
    (let ((ecc-inline-max-lines 2))
      (ecc-inline-show "one\ntwo\nthree\nfour" "Claude")
      (should (overlayp ecc-inline--overlay))
      (let ((shown (overlay-get ecc-inline--overlay 'before-string)))
        (should (string-search "one\ntwo" shown))
        (should-not (string-search "three" shown))
        ;; The header says there is more.
        (should (string-search "2 more below" shown)))
      (ecc-inline-scroll-down)
      (should (string-search "three\nfour"
                             (overlay-get ecc-inline--overlay 'before-string)))
      (ecc-inline-scroll-up)
      (should (string-search "one\ntwo"
                             (overlay-get ecc-inline--overlay 'before-string)))
      ;; The keys are in force over the line the overlay hangs from.
      (should (eq (lookup-key (overlay-get ecc-inline--overlay 'keymap) "q")
                  #'ecc-inline-quit))
      (should (eq (lookup-key (overlay-get ecc-inline--overlay 'keymap) "r")
                  #'ecc-inline-prompt))
      (ecc-inline-quit)
      (should-not ecc-inline--overlay)
      (should-not (seq-find (lambda (overlay) (overlay-get overlay 'ecc-inline))
                            (overlays-in (point-min) (point-max)))))))

(ert-deftest ecc-inline-test-question-carries-the-region ()
  "The question goes out with the code the user is looking at."
  (ecc-inline-test-with-source buffer
    (let ((question (ecc-inline-question "what is this?" buffer
                                         (cons (point-min)
                                               (line-end-position)))))
      (should (string-search "what is this?" question))
      (should (string-search "(defun one () 1)" question))
      (should (string-search "```elisp" question)))))

(ert-deftest ecc-inline-test-answer-flows-into-the-overlay ()
  "What the session says arrives in the overlay of the buffer that asked."
  (ecc-test-with-fake-session session
    (ecc-inline-test-with-source buffer
      (let ((ecc-inline-max-lines 20))
        (puthash session buffer ecc-inline--targets)
        (ecc-inline-show "…" "Claude")
        (ecc-test-dispatch session "basic-turn" "hello")
        (let ((shown (overlay-get ecc-inline--overlay 'before-string)))
          ;; The recorded answer to "hello" is what the overlay holds.
          (should (> (length shown) 10))
          (should (equal (substring-no-properties ecc-inline--text)
                         (ecc-inline--answer-text session))))
        (ecc-inline-quit))
      (remhash session ecc-inline--targets))))

(ert-deftest ecc-inline-test-binding-is-remembered ()
  "Which session a buffer asks is decided once and kept."
  (ecc-test-with-fake-session session
    (ecc-inline-test-with-source buffer
      (let ((ecc-inline-binding 'light)
            (started 0))
        (cl-letf (((symbol-function #'ecc-proc-start)
                   (lambda (&rest _) (cl-incf started) nil)))
          (let ((first (ecc-inline-session buffer)))
            (should (= started 1))
            (should (eq first ecc-inline--session))
            ;; The second question goes to the same session.
            (should (eq (ecc-inline-session buffer) first))
            (should (= started 1))
            ;; A light session runs with no tools.
            (should (equal (ecc-model-option first :extra-args nil)
                           ecc-inline-light-args))
            (ecc-model-remove-session first)))))))

(ert-deftest ecc-inline-test-fork-leaves-the-parent-alone ()
  "A forked inline session branches off without taking the parent's id."
  (ecc-test-with-fake-session session
    (ecc-inline-test-with-source buffer
      (let ((ecc-inline-binding 'fork)
            (arguments nil))
        (cl-letf (((symbol-function #'ecc-proc-start)
                   (lambda (session &optional resume fork)
                     (setq arguments (list resume fork))
                     ;; The command line is what proves the branch.
                     (setq arguments
                           (append arguments
                                   (list (ecc-proc-build-command
                                          session resume fork))))
                     nil))
                  ((symbol-function #'ecc-inline--parent)
                   (lambda (_buffer) session)))
          (let ((inline (ecc-inline-session buffer)))
            (should (equal (seq-take arguments 2) '(t t)))
            (should (member "--fork-session" (nth 2 arguments)))
            ;; It resumes the parent, but is not the parent.
            (should (member (ecc-session-id session) (nth 2 arguments)))
            (should-not (equal (ecc-session-id inline) (ecc-session-id session)))
            (should (eq (ecc-model-session (ecc-session-id session)) session))
            (ecc-model-remove-session inline)))))))

;;;; Rewrite

(ert-deftest ecc-inline-test-rewrite-command ()
  "The rewrite is one shot, with no tools and a schema."
  (let ((ecc-rewrite-model "haiku")
        (ecc-disabled-plugins nil))
    (let ((command (ecc-rewrite-command)))
      (should (member "-p" command))
      (should (equal (cadr (member "--output-format" command)) "json"))
      (should (equal (cadr (member "--json-schema" command)) ecc-rewrite-schema))
      (should (equal (cadr (member "--tools" command)) ""))
      (should (equal (cadr (member "--model" command)) "haiku"))
      ;; No Edit tool is asked for, so nothing can be written behind us.
      (should-not (member "--permission-prompt-tool" command)))))

(ert-deftest ecc-inline-test-rewrite-prompt ()
  "The instruction and the code go out together, fenced by language."
  (let ((prompt (ecc-rewrite-prompt "(+ 1 2)" "make it 3" "elisp")))
    (should (string-search "make it 3" prompt))
    (should (string-search "```elisp\n(+ 1 2)\n```" prompt))
    (should (string-search "code" prompt))))

(ert-deftest ecc-inline-test-rewrite-extract ()
  "The code is taken out of whichever shape the CLI answered in."
  ;; The result as the text of the object the schema describes.
  (should (equal (ecc-rewrite-extract
                  "{\"type\":\"result\",\"result\":\"{\\\"code\\\":\\\"(+ 1 2)\\\"}\"}")
                 "(+ 1 2)"))
  ;; The result as the object itself.
  (should (equal (ecc-rewrite-extract
                  "{\"type\":\"result\",\"result\":{\"code\":\"(+ 1 2)\"}}")
                 "(+ 1 2)"))
  ;; A model that ignored the schema still said something usable.
  (should (equal (ecc-rewrite-extract "{\"result\":\"(+ 1 2)\"}") "(+ 1 2)"))
  ;; A failure is a failure, not an empty rewrite.
  (should-error (ecc-rewrite-extract
                 "{\"is_error\":true,\"result\":\"over budget\"}"))
  (should-error (ecc-rewrite-extract "{\"type\":\"result\"}")))

(defun ecc-inline-test--offer (buffer code)
  "Offer CODE as the rewrite of the whole of BUFFER."
  (with-current-buffer buffer
    (setq ecc-rewrite--region (cons (copy-marker (point-min))
                                    (copy-marker (point-max) t)))
    (ecc-rewrite--finish
     buffer (ecc--json-write `((type . "result") (result . ((code . ,code))))))))

(ert-deftest ecc-inline-test-rewrite-offers-before-writing ()
  "The rewrite is shown and the buffer is left alone until it is accepted."
  (ecc-inline-test-with-source buffer
    (let ((before (buffer-string)))
      (ecc-inline-test--offer buffer "(defun one () 11)\n")
      (should (equal (buffer-string) before))
      (should (string-search "(defun one () 11)"
                             (overlay-get ecc-inline--overlay 'before-string)))
      (should (eq (lookup-key (overlay-get ecc-inline--overlay 'keymap) (kbd "RET"))
                  #'ecc-rewrite-accept))
      (ecc-rewrite-accept)
      (should (equal (buffer-string) "(defun one () 11)\n"))
      (should-not ecc-inline--overlay))))

(ert-deftest ecc-inline-test-rewrite-cancel-changes-nothing ()
  "Cancelling leaves the buffer as it was."
  (ecc-inline-test-with-source buffer
    (let ((before (buffer-string)))
      (ecc-inline-test--offer buffer "nonsense")
      (ecc-rewrite-cancel)
      (should (equal (buffer-string) before))
      (should-not ecc-rewrite--code)
      (should-error (ecc-rewrite-accept)))))

(ert-deftest ecc-inline-test-rewrite-accepts-at-once-when-asked ()
  "`ecc-rewrite-finished-action' accept writes without waiting."
  (ecc-inline-test-with-source buffer
    (let ((ecc-rewrite-finished-action 'accept))
      (ecc-inline-test--offer buffer "done\n")
      (should (equal (buffer-string) "done\n")))))

(ert-deftest ecc-inline-test-rewrite-merge ()
  "The merge action leaves a conflict for smerge to resolve."
  (ecc-inline-test-with-source buffer
    (let ((ecc-rewrite-finished-action 'merge))
      (ecc-inline-test--offer buffer "(defun one () 11)")
      (let ((text (buffer-string)))
        (should (string-search "<<<<<<< current" text))
        (should (string-search "(defun one () 1)" text))
        (should (string-search "=======" text))
        (should (string-search "(defun one () 11)" text))
        (should (string-search ">>>>>>> claude" text))))))

(ert-deftest ecc-inline-test-rewrite-diff ()
  "The diff action shows what would change without changing it."
  (ecc-inline-test-with-source buffer
    (let ((before (buffer-string)))
      (ecc-inline-test--offer buffer "(defun one () 11)\n(defun two () 2)\n")
      (let ((diff (ecc-rewrite-diff)))
        (unwind-protect
            (progn
              (should (equal (buffer-string) before))
              (let ((text (ecc-test-buffer-string diff)))
                (should (string-search "-(defun one () 1)" text))
                (should (string-search "+(defun one () 11)" text))))
          (kill-buffer diff))))))

(ert-deftest ecc-inline-test-rewrite-failure-is-shown ()
  "A CLI that answered with an error says so in the overlay, and writes nothing."
  (ecc-inline-test-with-source buffer
    (let ((before (buffer-string)))
      (setq ecc-rewrite--region (cons (copy-marker (point-min))
                                      (copy-marker (point-max) t)))
      (ecc-rewrite--finish buffer "{\"is_error\":true,\"result\":\"over budget\"}")
      (should (equal (buffer-string) before))
      (should-not ecc-rewrite--code)
      (should (string-search "over budget"
                             (overlay-get ecc-inline--overlay 'before-string)))
      (ecc-inline-quit))))

(provide 'ecc-inline-test)

;;; ecc-inline-test.el ends here
