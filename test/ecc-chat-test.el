;;; ecc-chat-test.el --- Tests for ecc-chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; The single session buffer of phase 9b (docs/phase9-ui-redesign.md,
;; section 4): folding and movement over the headings the renderer
;; marks, the keys that differ between the transcript and the prompt
;; region, sending from the region, and the draft that no redraw may
;; touch (FR-OUT-3, FR-OUT-14, FR-INP-1, FR-UI-2).

;;; Code:

(require 'ert)
(require 'ecc-test-helpers)
(require 'ecc-chat)
(require 'ecc-session)
(require 'ecc-prompt)
(require 'ecc-perm)

(defun ecc-chat-test--replay (session name prompt)
  "Replay fixture NAME into SESSION under PROMPT, allowing every request."
  (ecc-session-ensure-buffer session)
  (ecc-model-begin-turn session prompt)
  (dolist (line (ecc-test-fixture-lines name))
    (let ((message (ecc-protocol-parse-line line)))
      (ecc-dispatch session message)
      (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
        (ecc-perm-respond (car (ecc-session-pending session)) 'allow))))
  (ecc-render-flush session)
  (ecc-session-buffer session))

(defun ecc-chat-test--line ()
  "Return the text of the line point is on."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defconst ecc-chat-test--write-tool "toolu_01Hcu5xtMTxBqGiZ6MfT3XyZ"
  "The Write call of the tool-use-write recording.")

;;;; Folding (FR-OUT-3)

(ert-deftest ecc-chat-test-toggle-folds-and-unfolds ()
  "TAB on a heading hides its body and shows it again; on the body it folds."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "tool-use-write"
                                               "hello.txt を作って")
      (let ((tool ecc-chat-test--write-tool))
        ;; A tool starts folded: its heading is there, its diff is not.
        (should (ecc-render-node-hidden-p tool))
        (goto-char (car (ecc-render-node-bounds tool)))
        (should (string-prefix-p "    ✓ Write" (ecc-chat-test--line)))
        (forward-line 1)
        (should (invisible-p (point)))
        (goto-char (car (ecc-render-node-bounds tool)))
        (ecc-chat-toggle)
        (should-not (ecc-render-node-hidden-p tool))
        (forward-line 2)
        (should-not (invisible-p (point)))
        (should (string-search "@@ -0,0 +1,1 @@" (ecc-chat-test--line)))
        ;; From a line of the body, TAB goes back up and folds.
        (ecc-chat-toggle)
        (should (ecc-render-node-hidden-p tool))
        (should (string-prefix-p "    ✓ Write" (ecc-chat-test--line)))
        ;; A line with nothing to fold says so.
        (goto-char (point-min))
        (should-error (ecc-chat-toggle) :type 'user-error)))))

(ert-deftest ecc-chat-test-fold-is-remembered-across-redraws ()
  "What the user folded stays folded when the region is drawn again."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "tool-use-write"
                                               "hello.txt を作って")
      (let ((tool ecc-chat-test--write-tool)
            (step (ecc-node-id (seq-find (lambda (node) (eq (ecc-node-type node) 'step))
                                         (ecc-turn-children
                                          (car (ecc-session-turns session)))))))
        (ecc-render-show-node tool)
        (ecc-render-hide-node step)
        ;; A full redraw and a live redraw both keep it.
        (ecc-render-refresh session)
        (should-not (ecc-render-node-hidden-p tool))
        (should (ecc-render-node-hidden-p step))
        (ecc-model-begin-turn session "again")
        (ecc-render-flush session)
        (should-not (ecc-render-node-hidden-p tool))
        (should (ecc-render-node-hidden-p step))
        ;; The turn heading is never folded by default, the tool is.
        (should-not (ecc-render-node-hidden-p "turn-1"))))))

(ert-deftest ecc-chat-test-show-level ()
  "The number keys unfold down to a depth and fold what is deeper."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "tool-use-write"
                                               "hello.txt を作って")
      (let ((tool ecc-chat-test--write-tool)
            (step (ecc-node-id (seq-find (lambda (node) (eq (ecc-node-type node) 'step))
                                         (ecc-turn-children
                                          (car (ecc-session-turns session)))))))
        (ecc-chat-show-level-1)
        (should (ecc-render-node-hidden-p "turn-1"))
        (ecc-chat-show-level-2)
        (should-not (ecc-render-node-hidden-p "turn-1"))
        (should (ecc-render-node-hidden-p step))
        (ecc-chat-show-level-3)
        (should-not (ecc-render-node-hidden-p step))
        (should (ecc-render-node-hidden-p tool))
        (ecc-chat-show-level-4)
        (should-not (ecc-render-node-hidden-p tool))))))

(ert-deftest ecc-chat-test-isearch-opens-a-fold ()
  "A fold carries the property that lets isearch open it."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "tool-use-write"
                                               "hello.txt を作って")
      (let* ((tool ecc-chat-test--write-tool)
             (overlay (ecc-render--fold-overlay tool)))
        (should overlay)
        (should (eq (overlay-get overlay 'invisible) 'ecc-fold))
        (funcall (overlay-get overlay 'isearch-open-invisible) overlay)
        (should-not (ecc-render-node-hidden-p tool))))))

;;;; Movement (FR-OUT-14)

(ert-deftest ecc-chat-test-heading-movement ()
  "n and p walk the headings that are in sight; folded ones are skipped."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "tool-use-write"
                                               "hello.txt を作って")
      (goto-char (point-min))
      (ecc-chat-next-heading)
      (should (string-prefix-p "Files (1)" (ecc-chat-test--line)))
      ;; The file row under it is folded away, so it is skipped.
      (ecc-chat-next-heading)
      (should (string-prefix-p "Turn 1" (ecc-chat-test--line)))
      (ecc-chat-next-heading)
      (should (string-prefix-p "▌ hello.txt" (ecc-chat-test--line)))
      (ecc-chat-next-heading)
      (should (equal (ecc-chat-test--line) "  Write ×1"))
      (ecc-chat-next-heading)
      (should (string-prefix-p "    ✓ Write" (ecc-chat-test--line)))
      (ecc-chat-next-heading)
      (should (string-prefix-p "  ✓ Permission: Write" (ecc-chat-test--line)))
      ;; p from the middle of a heading goes to its start, then back.
      (end-of-line)
      (ecc-chat-previous-heading)
      (should (bolp))
      (should (string-prefix-p "  ✓ Permission" (ecc-chat-test--line)))
      (ecc-chat-previous-heading)
      (should (string-prefix-p "    ✓ Write" (ecc-chat-test--line)))
      ;; Folding the step hides the tool heading from n.
      (ecc-chat-up-heading)
      (should (equal (ecc-chat-test--line) "  Write ×1"))
      (ecc-chat-toggle)
      (ecc-chat-next-heading)
      (should (string-prefix-p "  ✓ Permission" (ecc-chat-test--line)))
      ;; Siblings stay at the same depth.
      (ecc-chat-previous-sibling)
      (should (equal (ecc-chat-test--line) "  Write ×1"))
      (ecc-chat-previous-sibling)
      (should (string-prefix-p "▌ hello.txt" (ecc-chat-test--line)))
      (should-error (ecc-chat-previous-sibling) :type 'user-error)
      ;; Past the last heading there is nothing.
      (goto-char (point-max))
      (should-error (ecc-chat-next-heading) :type 'user-error))))

;;;; Keys (plan section 4.2 of the phase 9 revision)

(ert-deftest ecc-chat-test-keys-differ-by-region ()
  "A letter moves in the transcript and is a letter in the prompt region."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "basic-turn" "hello")
      (goto-char (point-min))
      (should (eq (key-binding (kbd "n")) #'ecc-chat-next-heading))
      (should (eq (key-binding (kbd "TAB")) #'ecc-chat-toggle))
      (should (eq (key-binding (kbd "RET")) #'ecc-session-visit))
      (should (eq (key-binding (kbd "C-c C-k")) #'ecc-session-interrupt))
      (ecc-chat-goto-prompt)
      (should (eq (key-binding (kbd "n")) #'self-insert-command))
      (should (eq (key-binding (kbd "TAB")) #'ecc-chat-tab))
      (should (eq (key-binding (kbd "RET")) #'ecc-chat-return))
      (should (eq (key-binding (kbd "C-c C-c")) #'ecc-prompt-send))
      (should (eq (key-binding (kbd "C-c C-k")) #'ecc-prompt-clear))
      ;; The transcript is read-only, from its very first character on;
      ;; the prompt region is not.
      (goto-char (point-min))
      (should-error (insert "x") :type 'text-read-only)
      (goto-char (+ (point-min) 5))
      (should-error (insert "x") :type 'text-read-only)
      (goto-char (1- (ecc-chat-prompt-start)))
      (should-error (insert "x") :type 'text-read-only)
      (ecc-chat-goto-prompt)
      (insert "typed")
      (should (equal (ecc-chat-draft) "typed"))
      ;; What was typed carries none of the transcript's properties.
      (should-not (get-text-property (ecc-chat-prompt-start) 'read-only))
      (should-not (get-text-property (ecc-chat-prompt-start) 'keymap))
      ;; A request line answers to its own keys on top of the transcript's.
      (ecc-model-begin-turn session "more")
      (ecc-test-add-request session "Bash")
      (ecc-render-flush session)
      (goto-char (point-max))
      (search-backward "Permission: Bash")
      (should (eq (key-binding (kbd "d")) #'ecc-perm-deny))
      (should (eq (key-binding (kbd "p")) #'ecc-perm-add-pattern))
      (should (eq (key-binding (kbd "n")) #'ecc-chat-next-heading)))))

(ert-deftest ecc-chat-test-return-sends-when-asked ()
  "RET is a newline by default and sends when `ecc-chat-return-sends' is on."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat-goto-prompt)
      (insert "one")
      (ecc-chat-return)
      (should (equal (ecc-chat-draft) "one\n"))
      (let ((ecc-chat-return-sends t))
        (ecc-chat-return))
      (should (equal (ecc-chat-draft) ""))
      (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "one")))))

;;;; Sending (FR-INP-1)

(ert-deftest ecc-chat-test-send-empties-the-region-and-opens-a-turn ()
  "Sending moves the text up into a turn and leaves the region empty."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat-goto-prompt)
      (insert "hello there")
      (ecc-prompt-send)
      (should (equal (ecc-chat-draft) ""))
      (ecc-render-flush session)
      (should (string-search "▌ hello there" (buffer-string)))
      (should (string-search "Turn 1  hello there" (buffer-string)))
      ;; Point is back at the start of the empty prompt region, in
      ;; front of the placeholder, ready for more.
      (should (ecc-chat-in-prompt-p))
      (should (= (point) (ecc-chat-prompt-start)))
      (should (ecc-chat-placeholder-shown)))))

;;;; The draft survives every redraw (FR-UI-2)

(ert-deftest ecc-chat-test-draft-survives-redraws ()
  "A draft and the point in it are kept through every kind of redraw."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat-goto-prompt)
      (insert "half written")
      (goto-char (- (point) 8))
      (let ((offset (- (point) (ecc-chat-prompt-start))))
        ;; A turn arrives and is drawn under the transcript.
        (ecc-model-begin-turn session "hello")
        (ecc-test-dispatch session "basic-turn")
        (ecc-render-flush session)
        (should (equal (ecc-chat-draft) "half written"))
        (should (= (- (point) (ecc-chat-prompt-start)) offset))
        (should (string-search "hello from emacs" (buffer-string)))
        ;; A full redraw, too.
        (ecc-render-refresh session)
        (should (equal (ecc-chat-draft) "half written"))
        (should (= (- (point) (ecc-chat-prompt-start)) offset))
        ;; Streamed text is appended above the region, not into it.
        (let ((ecc-stream-throttle 0))
          (ecc-model-begin-turn session "長いファイルを書いて")
          (dolist (line (ecc-test-fixture-lines "partial-messages"))
            (let ((message (ecc-protocol-parse-line line)))
              (ecc-dispatch session message)
              (when (equal (alist-get 'type (alist-get 'event message))
                           "content_block_start")
                (ecc-render-flush session))
              (when (eq (ecc-protocol-control-subtype message) 'can_use_tool)
                (ecc-perm-respond (car (ecc-session-pending session)) 'allow)))))
        (ecc-render-flush session)
        (should (equal (ecc-chat-draft) "half written"))
        (should (= (- (point) (ecc-chat-prompt-start)) offset))
        (should (string-search "Done. Created `long.py`" (buffer-string)))
        ;; Everything above the region is read-only, right up to it.
        (should (get-text-property (1- (ecc-chat-prompt-start)) 'read-only))
        (should-not (get-text-property (ecc-chat-prompt-start) 'read-only))))))

(ert-deftest ecc-chat-test-undo-survives-a-redraw ()
  "Undo in the draft still undoes the draft after the transcript grew."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (buffer-enable-undo)
      (ecc-chat-goto-prompt)
      (insert "keep ")
      (undo-boundary)
      (insert "drop")
      (undo-boundary)
      (should (equal (ecc-chat-draft) "keep drop"))
      ;; The transcript grows above the draft.
      (ecc-model-begin-turn session "hello")
      (ecc-test-dispatch session "basic-turn")
      (ecc-render-flush session)
      (should (string-search "hello from emacs" (buffer-string)))
      (let ((last-command nil)) (undo))
      (should (equal (ecc-chat-draft) "keep "))
      (should (string-search "hello from emacs" (buffer-string))))))

(ert-deftest ecc-chat-test-window-point-in-the-prompt-is-kept ()
  "A window whose point is in the prompt region keeps it there."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session))
          (window (split-window)))
      (unwind-protect
          (with-current-buffer buffer
            (set-window-buffer window buffer)
            (ecc-chat-goto-prompt)
            (insert "draft")
            (set-window-point window (- (point-max) 2))
            (ecc-model-begin-turn session "hello")
            (ecc-test-dispatch session "basic-turn")
            (ecc-render-flush session)
            (should (= (window-point window) (- (point-max) 2)))
            ;; A window reading the live region follows to the prompt.
            (set-window-point window (marker-position ecc-render--live-start))
            (ecc-model-begin-turn session "again")
            (ecc-render-flush session)
            (should (= (window-point window) (ecc-chat-prompt-start))))
        (when (window-live-p window) (delete-window window))))))

(ert-deftest ecc-chat-test-another-session-does-not-touch-the-draft ()
  "Drawing one session leaves the draft of another alone."
  (ecc-test-with-fake-session one
    (let ((two (ecc-model-create-session :name "other"
                                         :project-root temporary-file-directory)))
      (unwind-protect
          (progn
            (with-current-buffer (ecc-session-ensure-buffer one)
              (ecc-chat-goto-prompt)
              (insert "for one"))
            (ecc-session-ensure-buffer two)
            (ecc-model-begin-turn two "hello")
            (ecc-test-dispatch two "basic-turn")
            (ecc-render-flush two)
            (ecc-render-refresh two)
            (with-current-buffer (ecc-session-buffer one)
              (should (equal (ecc-chat-draft) "for one"))
              (should-not (string-search "hello from emacs" (buffer-string)))))
        (ecc-test-cleanup-session two)))))

;;;; The placeholder

(ert-deftest ecc-chat-test-placeholder ()
  "An empty prompt region shows a placeholder the cursor can walk over.
Anything written takes it away, wherever in it the cursor was."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (should (equal (ecc-chat-update-placeholder) ecc-chat-placeholder))
      (should (equal (ecc-chat-placeholder-shown) ecc-chat-placeholder))
      (should (equal (ecc-chat-draft) ""))
      ;; It is text, so point moves over it, and it cannot be deleted.
      (ecc-chat-goto-prompt)
      (should (= (point) (ecc-chat-prompt-start)))
      (forward-char 4)
      (should (= (point) (+ (ecc-chat-prompt-start) 4)))
      (should-error (delete-char 1) :type 'text-read-only)
      ;; Typing in the middle of it leaves only what was typed.
      (insert "x")
      (should (equal (ecc-chat-draft) "x"))
      (should-not (ecc-chat-placeholder-shown))
      (should (= (point) (1+ (ecc-chat-prompt-start))))
      (should (string-suffix-p " \nx" (buffer-string)))
      (should-not (ecc-chat-update-placeholder))
      ;; Emptied, it comes back; a redraw keeps it in place.
      (ecc-prompt-clear)
      (should (equal (ecc-chat-update-placeholder) ecc-chat-placeholder))
      (ecc-model-begin-turn session "hello")
      (ecc-test-dispatch session "basic-turn")
      (ecc-render-flush session)
      (should (equal (ecc-chat-placeholder-shown) ecc-chat-placeholder))
      (should (= (point) (ecc-chat-prompt-start)))
      (should (string-search "hello from emacs" (buffer-string)))
      ;; Typing at its end works too, and sending sees no placeholder.
      (goto-char (point-max))
      (insert "send me")
      (should (equal (ecc-chat-draft) "send me"))
      (ecc-prompt-send)
      (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "send me")))))

(ert-deftest ecc-chat-test-placeholder-stays-out-of-undo ()
  "Undo in the draft is not confused by the placeholder coming and going."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (ecc-chat-goto-prompt)
      (forward-char 3)
      (insert "abc")
      (undo-boundary)
      (should (equal (ecc-chat-draft) "abc"))
      (insert "def")
      (undo-boundary)
      (let ((last-command nil)) (undo))
      (undo-boundary)
      (should (equal (ecc-chat-draft) "abc"))
      ;; Emptying it brings the placeholder back; undo brings the text.
      ;; The command loop would run the pre-command hook, which takes
      ;; the placeholder out of the way of the replay.
      (ecc-prompt-clear)
      (undo-boundary)
      (ecc-chat-update-placeholder)
      (should (ecc-chat-placeholder-shown))
      (let ((last-command nil) (this-command 'undo))
        (ecc-chat--pre-command)
        (should-not (ecc-chat-placeholder-shown))
        (undo))
      (should (equal (ecc-chat-draft) "abc"))
      (should-not (ecc-chat-placeholder-shown)))))

;;;; An agent transcript has no prompt region

(ert-deftest ecc-chat-test-agent-buffer-is-all-transcript ()
  "The buffer of an agent folds and moves but has nowhere to type."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "subagent" "探して")
      (let ((agent (seq-find (lambda (node) (eq (ecc-node-type node) 'agent))
                             (hash-table-values (ecc-session-nodes session)))))
        (save-window-excursion
          (ecc-session-show-agent session agent)
          (let ((buffer (seq-find (lambda (b) (string-prefix-p "*ecc-agent: test"
                                                               (buffer-name b)))
                                  (buffer-list))))
            (unwind-protect
                (with-current-buffer buffer
                  (should (derived-mode-p 'ecc-chat-mode))
                  (should-not (ecc-chat-prompt-start))
                  (should-error (ecc-chat-goto-prompt) :type 'user-error)
                  (goto-char (point-max))
                  (should-error (insert "x") :type 'text-read-only)
                  (goto-char (point-min))
                  (ecc-chat-next-heading)
                  (should (string-prefix-p "▌ List all" (ecc-chat-test--line)))
                  (ecc-chat-next-block)
                  (should (string-prefix-p "  ✓ Bash" (ecc-chat-test--line))))
              (kill-buffer buffer))))))))

(provide 'ecc-chat-test)

;;; ecc-chat-test.el ends here
