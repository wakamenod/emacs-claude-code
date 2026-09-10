;;; ecc-chat-test.el --- Tests for ecc-chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; The single session buffer of phase 9b (docs/phase9-ui-redesign.md,
;; section 4): folding and movement over the headings the renderer
;; marks, the keys that differ between the transcript and the prompt
;; region, sending from the region, and the draft that no redraw may
;; touch (FR-OUT-3, FR-OUT-14, FR-INP-1, FR-UI-2).

;;; Code:

(require 'cl-lib)
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

(defun ecc-chat-test--step-and-tool (session)
  "Return (STEP . TOOL) ids of a step SESSION drew over several tools.
A step over a single tool is not drawn at all, so a recording with two
calls in one step is what the depth ladder needs."
  (let ((step (seq-find (lambda (node)
                          (and (eq (ecc-node-type node) 'step)
                               (> (length (ecc-node-children node)) 1)))
                        (hash-table-values (ecc-session-nodes session)))))
    (should step)
    (cons (ecc-node-id step) (ecc-node-id (car (ecc-node-children step))))))

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
        (should (string-prefix-p "  ✓ Write" (ecc-chat-test--line)))
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
        (should (string-prefix-p "  ✓ Write" (ecc-chat-test--line)))
        ;; The line that parts the top region from the turns is under
        ;; no heading, so there is nothing to fold there.
        (goto-char ecc-render--top-end)
        (should-error (ecc-chat-toggle) :type 'user-error)))))

(ert-deftest ecc-chat-test-fold-is-remembered-across-redraws ()
  "What the user folded stays folded when the region is drawn again."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "plan-mode"
                                               "utils.py の計画を立てて")
      (pcase-let ((`(,step . ,tool) (ecc-chat-test--step-and-tool session)))
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
    (with-current-buffer (ecc-chat-test--replay session "plan-mode"
                                               "utils.py の計画を立てて")
      (pcase-let ((`(,step . ,tool) (ecc-chat-test--step-and-tool session)))
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

(ert-deftest ecc-chat-test-fold-mark-follows-the-fold ()
  "A heading that folds says which way it is, over its own status mark."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-chat-test--replay session "tool-use-write"
                                               "hello.txt を作って")
      (let* ((tool ecc-chat-test--write-tool)
             (pos (ecc-render--indicator-position tool)))
        (should pos)
        ;; A tool starts folded, so the mark points at what is hidden.
        (should (ecc-render-node-hidden-p tool))
        (should (equal (get-text-property pos 'display)
                       ecc-render-fold-closed-mark))
        ;; The character underneath is untouched, so a copy of the line
        ;; still says how the call went (FR-OUT-3).
        (should (equal (char-to-string (char-after pos)) "✓"))
        (goto-char pos)
        (ecc-chat-toggle)
        (should (equal (get-text-property pos 'display)
                       ecc-render-fold-open-mark))
        (ecc-chat-toggle)
        (should (equal (get-text-property pos 'display)
                       ecc-render-fold-closed-mark))))))

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
      ;; The Files summary stands below the turns now, so the band of
      ;; the prompt is the first heading of the buffer.
      (goto-char (point-min))
      (ecc-chat-next-heading)
      (should (string-prefix-p "〉 hello.txt" (ecc-chat-test--line)))
      ;; A step over one tool is not drawn, so the tool follows the band.
      (ecc-chat-next-heading)
      (should (string-prefix-p "  ✓ Write" (ecc-chat-test--line)))
      (ecc-chat-next-heading)
      (should (string-prefix-p "  ✓ Permission: Write" (ecc-chat-test--line)))
      ;; p from the middle of a heading goes to its start, then back.
      (end-of-line)
      (ecc-chat-previous-heading)
      (should (bolp))
      (should (string-prefix-p "  ✓ Permission" (ecc-chat-test--line)))
      (ecc-chat-previous-heading)
      (should (string-prefix-p "  ✓ Write" (ecc-chat-test--line)))
      ;; Siblings stay at the same depth.
      (ecc-chat-next-sibling)
      (should (string-prefix-p "  ✓ Permission" (ecc-chat-test--line)))
      (ecc-chat-previous-sibling)
      (should (string-prefix-p "  ✓ Write" (ecc-chat-test--line)))
      ;; The band above is the turn itself, a level up, so the walk
      ;; along this depth stops rather than leaving the turn.
      (should-error (ecc-chat-previous-sibling) :type 'user-error)
      (ecc-chat-up-heading)
      (should (string-prefix-p "〉 hello.txt" (ecc-chat-test--line)))
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
      ;; A slash is the one punctuation mark with a command of its own:
      ;; it inserts itself and offers the slash commands (FR-INP-3).
      (should (eq (key-binding (kbd "/")) #'ecc-chat-slash))
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

(ert-deftest ecc-chat-test-answering-from-the-prompt-region ()
  "C-c C-a and C-c C-d answer the oldest request without leaving the prompt."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-model-begin-turn session "hello")
      (let ((first (ecc-test-add-request session "Write"))
            (second (ecc-test-add-request session "Edit")))
        (ecc-render-flush session)
        (ecc-chat-goto-prompt)
        (should (eq (key-binding (kbd "C-c C-a")) #'ecc-perm-allow))
        (should (eq (key-binding (kbd "C-c C-d")) #'ecc-perm-deny))
        ;; The point is nowhere near the request, so the oldest one wins.
        (should-not (ecc-perm-request-at-point))
        (ecc-perm-allow)
        (should (equal (ecc-session-pending session) (list second)))
        (should (eq (ecc-node-status (ecc-request-node first)) 'done))
        (ecc-perm-deny "not this one")
        (should-not (ecc-session-pending session))
        (should (eq (ecc-node-status (ecc-request-node second)) 'denied))))))

(ert-deftest ecc-chat-test-deny-asks-for-nothing-when-nothing-waits ()
  "C-c C-d with no request waiting says so instead of asking for a reason."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat-goto-prompt)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (error "The reason was asked for"))))
        (should-error (call-interactively #'ecc-perm-deny) :type 'user-error)))))

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
      (should (string-search "〉 hello there" (buffer-string)))
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
  "A window whose point is in the prompt region keeps it there.
A window reading the transcript keeps its place there instead."
  (ecc-test-with-fake-session session
    (let ((buffer (ecc-session-ensure-buffer session))
          (window (split-window)))
      (unwind-protect
          (with-current-buffer buffer
            (set-window-buffer window buffer)
            (ecc-chat-goto-prompt)
            (insert "draft")
            ;; Three characters into the draft, which the footer under
            ;; it must not be confused with.
            (set-window-point window (- (point) 2))
            (ecc-model-begin-turn session "hello")
            (ecc-test-dispatch session "basic-turn")
            (ecc-render-flush session)
            (should (= (window-point window) (+ (ecc-chat-prompt-start) 3)))
            ;; A window reading a turn that is still growing stays on the
            ;; line it was reading.  The live region is drawn again from
            ;; scratch on every change, and it used to drag every point in
            ;; it down to the prompt, so that a window could not be moved
            ;; into a running turn at all.
            (ecc-model-begin-turn session "again")
            (ecc-model-add-node session :type 'text
                                :data '((text . "first paragraph of the answer")))
            (ecc-render-flush session)
            (let* ((position (+ 2 (marker-position ecc-render--live-start)))
                   (line (lambda ()
                           (save-excursion
                             (goto-char (window-point window))
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position))))))
              (set-window-point window position)
              (let ((before (funcall line)))
                (ecc-model-add-node session :type 'text
                                    :data '((text . "second paragraph")))
                (ecc-render-flush session)
                (should-not (= (window-point window) (ecc-chat-prompt-start)))
                (should (equal (funcall line) before)))))
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
  "An empty prompt region shows a placeholder as ghost text.
It is the `after-string' of an overlay, so it is not buffer text and
the cursor cannot walk into it; anything written takes it away."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (should (equal (ecc-chat-update-placeholder) ecc-chat-placeholder))
      (should (equal (ecc-chat-placeholder-shown) ecc-chat-placeholder))
      (should (equal (ecc-chat-draft) ""))
      ;; It is shown and nothing more: no text, and the cursor draws on
      ;; its first character rather than behind the whole of it.
      (let ((overlay ecc-chat--placeholder-overlay))
        (should (= (overlay-start overlay) (ecc-chat-prompt-start)))
        (should (= (overlay-start overlay) (overlay-end overlay)))
        (should (equal (substring-no-properties
                        (overlay-get overlay 'after-string))
                       ecc-chat-placeholder))
        (should (get-text-property 0 'cursor (overlay-get overlay 'after-string))))
      (should-not (string-search ecc-chat-placeholder (buffer-string)))
      ;; The prompt region is empty, so point has nowhere to walk to:
      ;; what follows it is the footer, which cannot be written in.
      (ecc-chat-goto-prompt)
      (should (= (point) (ecc-chat-prompt-start)))
      (should (= (point) (ecc-chat-prompt-end)))
      (should (get-text-property (point) 'ecc-footer))
      (save-excursion
        (forward-char 1)
        (should-error (insert "x") :type 'text-read-only))
      ;; Typing takes it away and leaves only what was typed.
      (insert "x")
      (should (equal (ecc-chat-draft) "x"))
      (should-not (ecc-chat-placeholder-shown))
      (should (= (point) (1+ (ecc-chat-prompt-start))))
      (should (string-search " \nx" (buffer-string)))
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
      (ecc-chat-goto-prompt)
      (insert "send me")
      (should (equal (ecc-chat-draft) "send me"))
      (ecc-prompt-send)
      (should (equal (ecc-turn-prompt (ecc-session-current-turn session)) "send me")))))

(ert-deftest ecc-chat-test-placeholder-stays-out-of-undo ()
  "Undo in the draft never sees the placeholder: it is not buffer text."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (ecc-chat-update-placeholder)
      (should (ecc-chat-placeholder-shown))
      ;; Showing it changed neither the buffer nor its history.
      (should-not (buffer-modified-p))
      (should (null buffer-undo-list))
      (ecc-chat-goto-prompt)
      (insert "abc")
      (undo-boundary)
      (should (equal (ecc-chat-draft) "abc"))
      (insert "def")
      (undo-boundary)
      (let ((last-command nil)) (undo))
      (undo-boundary)
      (should (equal (ecc-chat-draft) "abc"))
      ;; Emptying it brings the placeholder back; undo brings the text
      ;; back with nothing in the way of the replay.
      (ecc-prompt-clear)
      (undo-boundary)
      (ecc-chat-update-placeholder)
      (should (ecc-chat-placeholder-shown))
      (let ((last-command nil)) (undo))
      (should (equal (ecc-chat-draft) "abc"))
      (should-not (ecc-chat-update-placeholder)))))

(ert-deftest ecc-chat-test-kill-line-stays-in-the-prompt ()
  "C-k kills within the draft and leaves the footer under it alone.
The newline that ends the last line of the draft belongs to the
footer, which is read-only, so `kill-line' has to be kept inside the
prompt region."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat--update-ghosts)
      (should (eq (key-binding (kbd "C-k")) #'ecc-chat-kill-line))
      (ecc-chat-set-draft "one\ntwo")
      ;; From the middle of the first line: the rest of the line goes,
      ;; then the newline, and the second line comes up.
      (goto-char (+ (ecc-chat-prompt-start) 1))
      (ecc-chat-kill-line)
      (should (equal (ecc-chat-draft) "o\ntwo"))
      (ecc-chat-kill-line)
      (should (equal (ecc-chat-draft) "otwo"))
      ;; At the end of the draft there is nothing left to kill: the
      ;; footer is not the draft's last line.
      (ecc-chat-goto-prompt)
      (should-error (ecc-chat-kill-line) :type 'end-of-buffer)
      (should (equal (ecc-chat-draft) "otwo"))
      (should (get-text-property (ecc-chat-prompt-end) 'ecc-footer))
      ;; From its start the whole draft goes, and the footer stays.
      (goto-char (ecc-chat-prompt-start))
      (ecc-chat-kill-line)
      (should (equal (ecc-chat-draft) ""))
      (should (equal (ecc-chat-test--footer-mode)
                     "⏵ manual mode (S-TAB to cycle)")))))

;;;; The footer: the permission mode under the prompt (FR-SES-6)

(defun ecc-chat-test--footer-line ()
  "Return the last line of the footer of this buffer, without properties."
  (when-let* ((text (ecc-chat-footer-shown)))
    (substring-no-properties (car (last (split-string text "\n"))))))

(defun ecc-chat-test--footer-mode ()
  "Return what the footer of this buffer calls the permission mode.
The model stands on the right of the same line, held apart by a
stretched space; what is asked for here is the left of it."
  (when-let* ((line (ecc-chat-test--footer-line)))
    (let ((tail (concat " " (ecc-render--model-name ecc-render--session))))
      (if (string-suffix-p tail line)
          (substring line 0 (- (length line) (length tail)))
        line))))

(ert-deftest ecc-chat-test-footer ()
  "The permission mode is shown under the prompt as read-only text.
The prompt region ends where it begins, so the draft never sees it,
and the draft is written in front of it and survives a redraw
\(FR-UI-2)."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-test--footer-mode)
                     "⏵ manual mode (S-TAB to cycle)"))
      ;; A session that knows its model names it on the right of the
      ;; same line, where the header line used to.
      (should (equal (ecc-chat-test--footer-line)
                     "⏵ manual mode (S-TAB to cycle)"))
      (setf (ecc-session-init session) '((model . "claude-haiku-4-5-20251001")))
      (ecc-chat-update-footer)
      (should (equal (ecc-chat-test--footer-line)
                     "⏵ manual mode (S-TAB to cycle) haiku"))
      ;; It is text of its own, past the end of the prompt region.
      (should (string-search "S-TAB" (buffer-string)))
      (should (equal (ecc-chat-draft) ""))
      (should (= (ecc-chat-prompt-end) (ecc-chat-prompt-start)))
      (should (< (ecc-chat-prompt-end) (point-max)))
      (should (get-text-property (ecc-chat-prompt-end) 'ecc-footer))
      (should (get-text-property (ecc-chat-prompt-end) 'read-only))
      ;; Its rule spans the window as the separator above does.
      (should (equal (get-text-property (+ (ecc-chat-prompt-end) 1) 'display)
                     '(space :align-to right)))
      ;; A letter typed where the draft begins is a letter: the keys of
      ;; the transcript start after the newline that ends the region.
      (ecc-chat-goto-prompt)
      (should (eq (key-binding (kbd "n")) #'self-insert-command))
      (should (eq (key-binding (kbd "<backtab>"))
                  #'ecc-chat-cycle-permission-mode))
      (save-excursion
        (forward-char 2)
        (should (eq (key-binding (kbd "n")) #'ecc-chat-next-heading)))
      ;; The draft grows in front of the footer rather than into it.
      (insert "hello")
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-draft) "hello"))
      (should (= (point) (ecc-chat-prompt-end)))
      (should (get-text-property (ecc-chat-prompt-end) 'ecc-footer))
      ;; A redraw of the transcript above leaves both alone.
      (ecc-model-begin-turn session "hello")
      (ecc-test-dispatch session "basic-turn")
      (ecc-render-flush session)
      (should (equal (ecc-chat-draft) "hello"))
      (should (get-text-property (ecc-chat-prompt-end) 'ecc-footer))
      (should (equal (ecc-chat-test--footer-mode)
                     "⏵ manual mode (S-TAB to cycle)"))
      ;; It says what the session runs, and warns about the modes that
      ;; answer requests on their own.  `auto' is one of those and is
      ;; not another name for `acceptEdits' (claude 2.1.263).
      (setf (ecc-session-permission-mode session) "acceptEdits")
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-test--footer-mode)
                     "⏵⏵ accept edits on (S-TAB to cycle)"))
      (save-excursion
        (goto-char (point-max))
        (should (eq (get-text-property (line-beginning-position) 'face)
                    'ecc-accept-edits-face)))
      (setf (ecc-session-permission-mode session) "plan")
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-test--footer-mode)
                     "⏸ plan mode on (S-TAB to cycle)"))
      (setf (ecc-session-permission-mode session) "auto")
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-test--footer-mode)
                     "⏵⏵ auto mode on (S-TAB to cycle)"))
      (save-excursion
        (goto-char (point-max))
        (should (eq (get-text-property (line-beginning-position) 'face)
                    'ecc-auto-mode-face)))
      (setf (ecc-session-permission-mode session) "bypassPermissions")
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-test--footer-mode)
                     "⏵⏵ bypass permissions on (S-TAB to cycle)"))
      (save-excursion
        (goto-char (point-max))
        (should (eq (get-text-property (line-beginning-position) 'face)
                    'ecc-error-face)))
      ;; A mode nobody listed is shown under its own name.
      (setf (ecc-session-permission-mode session) "somethingElse")
      (ecc-chat--update-ghosts)
      (should (equal (ecc-chat-test--footer-mode)
                     "somethingElse (S-TAB to cycle)")))))

(ert-deftest ecc-chat-test-footer-can-be-turned-off ()
  "`ecc-chat-show-footer' nil leaves nothing under the prompt."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (ecc-chat--update-ghosts)
      (should (ecc-chat-footer-shown))
      (let ((ecc-chat-show-footer nil))
        (should-not (ecc-chat-update-footer))
        (should-not (ecc-chat-footer-shown))
        ;; The placeholder is a thing of its own and stays.
        (should (ecc-chat-placeholder-shown)))
      (should (ecc-chat-update-footer)))))

(ert-deftest ecc-chat-test-cycle-permission-mode ()
  "S-TAB walks through the modes and asks the CLI to switch (FR-SES-6)."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (should (eq (lookup-key ecc-chat-mode-map (kbd "<backtab>"))
                  #'ecc-chat-cycle-permission-mode))
      (should (eq (lookup-key ecc-chat-transcript-map (kbd "<backtab>"))
                  #'ecc-chat-cycle-permission-mode))
      ;; Nothing is set yet, which is the default mode; the cycle goes
      ;; on from there and around.
      (should (equal (ecc-chat-cycle-permission-mode) "acceptEdits"))
      (setf (ecc-session-permission-mode session) "acceptEdits")
      (should (equal (ecc-chat-cycle-permission-mode) "plan"))
      (setf (ecc-session-permission-mode session) "plan")
      (should (equal (ecc-chat-cycle-permission-mode) "auto"))
      (setf (ecc-session-permission-mode session) "auto")
      (should (equal (ecc-chat-cycle-permission-mode) "default"))
      ;; A mode outside the cycle -- bypassPermissions is never entered
      ;; by S-TAB -- goes to its first.
      (setf (ecc-session-permission-mode session) "bypassPermissions")
      (should (equal (ecc-chat-cycle-permission-mode) "default"))
      ;; Each of them went out as a control request, and the answer is
      ;; what makes the footer say the new mode.
      (let ((sent (ecc-test-sent-messages)))
        (should (= (length sent) 5))
        (should (equal (mapcar (lambda (message)
                                 (alist-get 'mode (alist-get 'request message)))
                               sent)
                       '("acceptEdits" "plan" "auto" "default" "default")))
        (should (equal (alist-get 'subtype (alist-get 'request (car sent)))
                       "set_permission_mode"))
        (let* ((message (car sent))
               (callback (ecc-proc-take-control-callback
                          session (alist-get 'request_id message))))
          (funcall callback session '((mode . "acceptEdits")))
          (should (equal (ecc-session-permission-mode session) "acceptEdits"))
          (should (equal (ecc-chat-test--footer-mode)
                         "⏵⏵ accept edits on (S-TAB to cycle)")))))))

(ert-deftest ecc-chat-test-cycle-steps-over-a-refused-mode ()
  "A mode the CLI refuses is struck off the cycle and the next asked for.
\"auto\" is only for a model that supports it (claude 2.1.263), and the
refusal comes back as an error control response, long after the key was
pressed."
  (ecc-test-with-fake-session session
    (with-current-buffer (ecc-session-ensure-buffer session)
      (setf (ecc-session-permission-mode session) "plan")
      (should (equal (ecc-chat-cycle-permission-mode) "auto"))
      (let* ((message (car (ecc-test-sent-messages)))
             (callback (ecc-proc-take-control-callback
                        session (alist-get 'request_id message))))
        ;; The CLI refuses, which is an error response and carries no
        ;; mode: the session stays where it was, and the mode after the
        ;; refused one is asked for instead.
        (funcall callback session
                 '((error . "auto mode unavailable for this model")))
        (should (equal (ecc-session-permission-mode session) "plan"))
        (should (member "auto" ecc-chat--refused-modes))
        (should (equal (mapcar (lambda (sent)
                                 (alist-get 'mode (alist-get 'request sent)))
                               (ecc-test-sent-messages))
                       '("auto" "default")))
        ;; From then on the cycle steps over it without asking again.
        (setf (ecc-session-permission-mode session) "plan")
        (should (equal (ecc-chat-cycle-permission-mode) "default"))))))

(ert-deftest ecc-chat-test-control-error-reaches-the-callback ()
  "An error control response tells the callback what went wrong."
  (ecc-test-with-fake-session session
    (let ((seen nil))
      (ecc-proc-set-permission-mode session "auto"
                                    (lambda (_session reason) (setq seen reason)))
      (let ((request-id (alist-get 'request_id (car (ecc-test-sent-messages)))))
        (ecc-dispatch
         session
         `((type . "control_response")
           (response . ((subtype . "error")
                        (request_id . ,request-id)
                        (error . "auto mode unavailable for this model")))))
        (should (equal seen "auto mode unavailable for this model"))
        (should-not (ecc-session-permission-mode session))))))

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
                  ;; With nowhere to type there is no footer either.
                  (should-not (ecc-chat-update-footer))
                  (goto-char (point-max))
                  (should-error (insert "x") :type 'text-read-only)
                  (goto-char (point-min))
                  (ecc-chat-next-heading)
                  (should (string-prefix-p "〉 List all" (ecc-chat-test--line)))
                  (ecc-chat-next-block)
                  (should (string-prefix-p "✓ Bash" (ecc-chat-test--line))))
              (kill-buffer buffer))))))))

(provide 'ecc-chat-test)

;;; ecc-chat-test.el ends here
