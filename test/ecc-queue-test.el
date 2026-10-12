;;; ecc-queue-test.el --- Tests for ecc-queue  -*- lexical-binding: t; -*-

;;; Commentary:

;; The queued prompts at the end of the transcript, and the list that
;; takes one back, drops it or moves it.

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-queue)
(require 'ecc-prompt)
(require 'ecc-session)
(require 'ecc-dispatch)

(defmacro ecc-queue-test--in-buffer (session &rest body)
  "Run BODY in the buffer of SESSION, with point in the prompt region."
  (declare (indent 1))
  `(with-current-buffer (ecc-session-ensure-buffer ,session)
     (ecc-chat-goto-prompt)
     ,@body))

(defun ecc-queue-test--type (session text)
  "Send TEXT from the prompt region of SESSION, the way RET does."
  (ecc-queue-test--in-buffer session
    (insert text)
    (ecc-prompt-send)))

(defun ecc-queue-test--transcript (session)
  "Return the transcript of SESSION, up to the prompt region."
  (with-current-buffer (ecc-session-buffer session)
    (buffer-substring-no-properties (point-min) (ecc-render-prompt-start))))

(defun ecc-queue-test--list (session)
  "Return the lines of the list of SESSION's queue that name an entry."
  (with-current-buffer (ecc-queue-buffer session)
    (seq-filter (lambda (line) (string-match-p "\\` *[0-9]+\\. " line))
                (split-string (buffer-substring-no-properties (point-min) (point-max))
                              "\n"))))

(defun ecc-queue-test--goto (session text)
  "Put point of the list of SESSION on the entry whose line holds TEXT."
  (set-buffer (ecc-queue-buffer session))
  (goto-char (point-min))
  (search-forward text)
  (beginning-of-line))

(defmacro ecc-queue-test--with-buffers (&rest body)
  "Run BODY and kill the queue lists it made."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (dolist (buffer (buffer-list))
       (when (buffer-local-value 'ecc-queue--session buffer)
         (kill-buffer buffer)))))

;;;; At the end of the transcript

(ert-deftest ecc-queue-test-tail-follows-the-queue ()
  "The queued prompts are drawn above the separator while there are any."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "first")
    (ecc-render-flush session)
    (should-not (string-search "Queued" (ecc-queue-test--transcript session)))
    (ecc-queue-test--type session "テストも追加して")
    ;; Queueing asks for a redraw itself: no event from the CLI is
    ;; needed for the lines to show.
    (should (buffer-local-value 'ecc-render--timer (ecc-session-buffer session)))
    (ecc-render-flush session)
    (ecc-queue-test--type session "CHANGELOG を更新して")
    (ecc-render-flush session)
    (let ((transcript (ecc-queue-test--transcript session)))
      (should (string-match-p
               "⏸ Queued (2)\n  1\\. テストも追加して\n  2\\. CHANGELOG を更新して\n[^\n]*\n\\'"
               transcript)))
    (with-current-buffer (ecc-session-buffer session)
      (goto-char (point-min))
      (search-forward "1. テスト")
      (should (eq (get-text-property (point) 'face) 'ecc-dim-face))
      (should (get-text-property (point) 'read-only)))
    ;; The turn ends, the first goes out, and the list loses it.
    (ecc-dispatch session '((type . "result") (subtype . "success")))
    (ecc-render-flush session)
    (should (string-search "⏸ Queued (1)\n  1. CHANGELOG"
                           (ecc-queue-test--transcript session)))
    (ecc-dispatch session '((type . "result") (subtype . "success")))
    (ecc-render-flush session)
    (should-not (string-search "Queued" (ecc-queue-test--transcript session)))))

(ert-deftest ecc-queue-test-tail-is-cut-to-the-window ()
  "A long prompt takes one line, not several."
  (ecc-test-with-fake-session session
    (ecc-session-ensure-buffer session)
    (ecc-model-begin-turn session "first")
    (ecc-model-queue-input session (make-string 300 ?x) (make-string 300 ?x))
    (ecc-model-queue-input session "line one\nline two" "line one\nline two")
    (ecc-render-flush session)
    (let ((lines (split-string (ecc-queue-test--transcript session) "\n")))
      (should (seq-every-p (lambda (line) (<= (string-width line) 80)) lines))
      (should (member "  2. line one line two" lines))
      (should (seq-find (lambda (line) (string-match-p "\\`  1\\. x+…\\'" line))
                        lines)))))

(ert-deftest ecc-queue-test-tail-opens-the-list ()
  "RET or a click on a queued line opens the list, on that prompt."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      (ecc-queue-test--type session "one")
      (ecc-queue-test--type session "two")
      (ecc-render-flush session)
      (with-current-buffer (ecc-session-buffer session)
        (goto-char (point-min))
        (search-forward "2. tw")
        ;; The keys of the line: RET runs the queue command, and a click
        ;; is a link the way the transcript's links are.
        (should (eq (key-binding (kbd "RET")) #'ecc-queue-show-at-point))
        (should (eq (lookup-key (get-text-property (point) 'keymap) [mouse-2])
                    #'ecc-queue-show-at-click))
        (should (mouse-on-link-p (point)))
        ;; The rest of the transcript's keys are still there.
        (should (eq (key-binding (kbd "n")) #'ecc-chat-next-heading))
        (call-interactively (key-binding (kbd "RET"))))
      (let ((buffer (ecc-queue-buffer session)))
        (should (get-buffer-window buffer))
        (with-current-buffer buffer
          (should (eq ecc-queue--session session))
          (should (equal (ecc-queued-draft (get-text-property (point) 'ecc-queued))
                         "two")))))))

;;;; The list

(ert-deftest ecc-queue-test-show-replaces-the-echo-area ()
  "\\`C-c C-q' lists the queue in a buffer; an empty queue is a message."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (with-current-buffer (ecc-session-ensure-buffer session)
        (should (eq (key-binding (kbd "C-c C-q")) #'ecc-queue-show))
        (let (said)
          (cl-letf (((symbol-function #'message)
                     (lambda (format &rest args) (setq said (apply #'format format args)))))
            (should-not (call-interactively #'ecc-queue-show)))
          (should (equal said "The queue of test is empty")))
        (ecc-model-begin-turn session "first")
        (ecc-queue-test--type session "one")
        (call-interactively #'ecc-queue-show))
      (should (equal (ecc-queue-test--list session) '(" 1. one"))))))

(ert-deftest ecc-queue-test-take-back-into-an-empty-prompt ()
  "RET puts the draft as it was typed back in the prompt, not what was prepared."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      ;; What goes out carries more than was typed.
      (let ((ecc-prepare-prompt-functions
             (list (lambda (_session text) (concat text "\n\n(added by a module)")))))
        (ecc-queue-test--type session "テストも追加して"))
      (should (equal (ecc-model-queued-texts session)
                     '("テストも追加して\n\n(added by a module)")))
      (ecc-queue-show session)
      (ecc-queue-test--goto session "テスト")
      (ecc-queue-take-back)
      (should-not (ecc-session-input-queue session))
      (with-current-buffer (ecc-session-buffer session)
        (should (equal (ecc-chat-draft) "テストも追加して"))
        (should (= (point) (ecc-chat-prompt-end))))
      (should (eq (current-buffer) (ecc-session-buffer session)))
      ;; The list followed, and the transcript lost its lines.
      (should-not (ecc-queue-test--list session))
      (with-current-buffer (ecc-queue-buffer session)
        (should (string-search "The queue is empty." (buffer-string))))
      (ecc-render-flush session)
      (should-not (string-search "Queued" (ecc-queue-test--transcript session))))))

(ert-deftest ecc-queue-test-take-back-keeps-the-draft ()
  "A draft already in the prompt stays, after the prompt taken back."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      (ecc-queue-test--type session "queued one")
      (ecc-queue-test--in-buffer session
        (insert "half written\nsecond line"))
      (ecc-queue-show session)
      (ecc-queue-test--goto session "queued one")
      (ecc-queue-take-back)
      (with-current-buffer (ecc-session-buffer session)
        (should (equal (ecc-chat-draft) "queued one\n\nhalf written\nsecond line"))
        (should (equal (buffer-substring-no-properties (ecc-chat-prompt-start) (point))
                       "queued one"))
        ;; The transcript ends where it did: nothing went before the region.
        (should (string-suffix-p "\n" (ecc-queue-test--transcript session)))))))

(ert-deftest ecc-queue-test-drop ()
  "d drops the entry at point, and only that one."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      (dolist (text '("one" "two" "three"))
        (ecc-queue-test--type session text))
      (ecc-queue-show session)
      (ecc-queue-test--goto session "two")
      (ecc-queue-drop)
      (should (equal (ecc-model-queued-texts session) '("one" "three")))
      (should (equal (ecc-queue-test--list session) '(" 1. one" " 2. three")))
      ;; The point is on the one that took its place.
      (with-current-buffer (ecc-queue-buffer session)
        (should (equal (ecc-queued-draft (get-text-property (point) 'ecc-queued))
                       "three"))
        (should (eq (key-binding (kbd "k")) #'ecc-queue-drop))))))

(ert-deftest ecc-queue-test-reorder ()
  "M-<up> and M-<down> move the entry, and the point goes with it."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      (dolist (text '("one" "two" "three"))
        (ecc-queue-test--type session text))
      (ecc-queue-show session)
      (ecc-queue-test--goto session "three")
      (should (eq (key-binding (kbd "M-<up>")) #'ecc-queue-move-up))
      (ecc-queue-move-up)
      (ecc-queue-move-up)
      (ecc-queue-move-up)
      (should (equal (ecc-model-queued-texts session) '("three" "one" "two")))
      (should (equal (ecc-queue-test--list session) '(" 1. three" " 2. one" " 3. two")))
      (with-current-buffer (ecc-queue-buffer session)
        (should (string-prefix-p " 1. three" (buffer-substring (point) (line-end-position)))))
      (ecc-queue-move-down)
      (should (equal (ecc-model-queued-texts session) '("one" "three" "two")))
      ;; The next to go out is the one at the head.
      (ecc-dispatch session '((type . "result") (subtype . "success")))
      (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "one")))))

(ert-deftest ecc-queue-test-an-entry-sent-meanwhile ()
  "An entry that drained while the list was open is said to be gone."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      (dolist (text '("one" "two"))
        (ecc-queue-test--type session text))
      (ecc-queue-show session)
      (ecc-queue-test--goto session "one")
      ;; The turn ends and `one' goes out under the list, which is drawn
      ;; again with it gone.
      (ecc-dispatch session '((type . "result") (subtype . "success")))
      (should (equal (ecc-queue-test--list session) '(" 1. two")))
      (with-current-buffer (ecc-queue-buffer session)
        (dolist (command '(ecc-queue-drop ecc-queue-take-back ecc-queue-move-down))
          ;; A list drawn before that -- as if the hook had missed it --
          ;; still holds `one' on the line point is on.
          (let ((inhibit-read-only t)
                (one (ecc-queued--make :text "one" :draft "one")))
            (erase-buffer)
            (insert (propertize " 1. one\n" 'ecc-queued one)
                    (propertize " 2. two\n" 'ecc-queued
                                (car (ecc-session-input-queue session)))))
          (goto-char (point-min))
          (should (equal (cadr (should-error (funcall command) :type 'user-error))
                         "That prompt has been sent already"))
          (should (equal (ecc-model-queued-texts session) '("two")))
          ;; And the list is drawn again as it stands.
          (should (equal (ecc-queue-test--list session) '(" 1. two"))))))))

(ert-deftest ecc-queue-test-an-entry-from-emacs ()
  "A prompt queued without a draft is listed by its text and can be dropped."
  (ecc-test-with-fake-session session
    (ecc-queue-test--with-buffers
      (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "first")
      ;; The way `ecc-context' and the others queue: no draft.
      (ecc-proc-send-prompt session "fix the error at point")
      (ecc-proc-send-prompt session [((type . "text") (text . "blocks"))])
      (ecc-queue-show session)
      (should (equal (ecc-queue-test--list session)
                     '(" 1. fix the error at point  (queued by Emacs)"
                       " 2. (content blocks)  (queued by Emacs)")))
      (ecc-queue-test--goto session "(content blocks)")
      (should-error (ecc-queue-take-back) :type 'user-error)
      (should (= (length (ecc-session-input-queue session)) 2))
      (ecc-queue-drop)
      (ecc-queue-test--goto session "fix the error")
      (ecc-queue-take-back)
      (should-not (ecc-session-input-queue session))
      (with-current-buffer (ecc-session-buffer session)
        (should (equal (ecc-chat-draft) "fix the error at point"))))))

(ert-deftest ecc-queue-test-each-session-its-own-list ()
  "The list of one session never shows nor touches the queue of another."
  (ecc-test-with-fake-session one
    (ecc-queue-test--with-buffers
      (let ((two (ecc-model-create-session :name "other"
                                           :project-root temporary-file-directory)))
        (unwind-protect
            (progn
              (dolist (session (list one two))
                (ecc-session-ensure-buffer session)
                (ecc-model-begin-turn session "first"))
              (ecc-queue-test--type one "for one")
              (ecc-queue-test--type two "for two, first")
              (ecc-queue-test--type two "for two, second")
              (ecc-queue-show one)
              (ecc-queue-show two)
              (should-not (eq (ecc-queue-buffer one) (ecc-queue-buffer two)))
              (should (equal (ecc-queue-test--list one) '(" 1. for one")))
              (should (equal (ecc-queue-test--list two)
                             '(" 1. for two, first" " 2. for two, second")))
              (ecc-queue-test--goto one "for one")
              (ecc-queue-drop)
              (should-not (ecc-session-input-queue one))
              (should (= 2 (length (ecc-session-input-queue two))))
              ;; The other session draining leaves this list alone.
              (ecc-dispatch two '((type . "result") (subtype . "success")))
              (should (equal (ecc-queue-test--list two) '(" 1. for two, second")))
              (with-current-buffer (ecc-queue-buffer one)
                (should (string-search "The queue is empty." (buffer-string))))
              ;; And each transcript draws its own.
              (ecc-render-flush one)
              (ecc-render-flush two)
              (should-not (string-search "Queued" (ecc-queue-test--transcript one)))
              (should (string-search "⏸ Queued (1)\n  1. for two, second"
                                     (ecc-queue-test--transcript two))))
          (ecc-test-cleanup-session two))))))

(provide 'ecc-queue-test)

;;; ecc-queue-test.el ends here
