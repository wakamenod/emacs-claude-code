;;; ecc-render.el --- magit-section rendering for the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))

;;; Commentary:

;; Draws the model of `ecc-model' into the session buffer.  Section 5 of
;; IMPLEMENTATION_PLAN.md.  This is the only module that knows about
;; magit-section (NFR-9).
;;
;; The buffer is laid out as a top region (the header, the Files and the
;; Tasks summaries), the turns that are finished, and a live region
;; holding the current turn and the state line.  Finished turns are never
;; touched again: a redraw deletes the live region and builds it anew,
;; and the top region is replaced in place, which keeps the cost
;; proportional to the current turn rather than to the length of the
;; conversation (plan section 5.2).
;;
;; Streamed text is not redrawn at all: each delta is appended at the
;; marker kept at the end of its node, thinned out by
;; `ecc-stream-throttle' (FR-OUT-4, FR-OUT-10).
;;
;; Font lock is off in the session buffer, so faces are applied here as
;; the text is inserted (plan section 9, item 7).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'eieio)
(require 'magit-section)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-markdown)
(require 'ecc-diff)
(require 'ecc-visual)

(declare-function ecc-history-load-more "ecc-history" (session &optional n-turns))

(defcustom ecc-render-debounce 0.1
  "Seconds to gather changes before redrawing the live region (FR-OUT-10)."
  :type 'number
  :group 'ecc)

(defcustom ecc-render-hidden-types '(thinking tool system unknown)
  "Node types whose body starts collapsed (FR-OUT-3)."
  :type '(repeat symbol)
  :group 'ecc)

(defcustom ecc-render-result-max-lines 12
  "Lines of a tool result shown in the transcript.
The whole result is always available with RET."
  :type 'integer
  :group 'ecc)

(defcustom ecc-render-diff-max-lines 40
  "Lines of a diff shown inside a tool or permission section.
The whole diff is always available with RET (FR-OUT-7)."
  :type 'integer
  :group 'ecc)

(defcustom ecc-render-follow t
  "Non-nil scrolls to the end of the buffer while it is at the end."
  :type 'boolean
  :group 'ecc)

;;;; Section classes

(defclass ecc-section-root (magit-section) ()
  :documentation "The whole session buffer.")
(defclass ecc-section-header (magit-section) ()
  :documentation "The session summary at the top of the buffer.")
(defclass ecc-section-files (magit-section) ()
  :documentation "The files Claude touched (FR-OUT-12).")
(defclass ecc-section-file (magit-section)
  ((keymap :initform 'ecc-file-section-map))
  :documentation "One file and the merged diff of its changes.")
(defclass ecc-section-tasks (magit-section) ()
  :documentation "The task list Claude keeps (FR-OUT-13).")
(defclass ecc-section-task (magit-section) ()
  :documentation "One task.")
(defclass ecc-section-turn (magit-section) ()
  :documentation "One prompt and everything that followed it.")
(defclass ecc-section-prompt (magit-section) ()
  :documentation "The prompt the user, or a parent agent, sent.")
(defclass ecc-section-text (magit-section) ()
  :documentation "Assistant text.")
(defclass ecc-section-thinking (magit-section) ()
  :documentation "A thinking block.")
(defclass ecc-section-step (magit-section) ()
  :documentation "A run of tool calls between two assistant texts.")
(defclass ecc-section-tool (magit-section)
  ((keymap :initform 'ecc-tool-section-map))
  :documentation "One tool call and its result.")
(defclass ecc-section-agent (magit-section)
  ((keymap :initform 'ecc-tool-section-map))
  :documentation "A subagent and the messages it produced.")
(defclass ecc-section-request (magit-section)
  ((keymap :initform 'ecc-request-section-map))
  :documentation "A permission request, a question or a plan review.")
(defclass ecc-section-result (magit-section) ()
  :documentation "The result line that closes a turn.")
(defclass ecc-section-system (magit-section) ()
  :documentation "A note the CLI made about the session itself.")
(defclass ecc-section-unknown (magit-section) ()
  :documentation "A message this version does not understand.")
(defclass ecc-section-tail (magit-section) ()
  :documentation "The state line at the end of the buffer.")
(defclass ecc-section-history (magit-section) ()
  :documentation "The button that reads the page before the first turn.")

(defvar ecc-tool-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'ecc-session-visit)
    map)
  "Keymap of a tool section in a session buffer.")

(defvar ecc-request-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'ecc-session-visit)
    (define-key map (kbd "a") 'ecc-perm-allow)
    (define-key map (kbd "d") 'ecc-perm-deny)
    (define-key map (kbd "A") 'ecc-perm-allow-always)
    (define-key map (kbd "t") 'ecc-perm-approve-turn)
    (define-key map (kbd "p") 'ecc-perm-add-pattern)
    (define-key map (kbd "c") 'ecc-review-comment-request)
    (define-key map (kbd "e") 'ecc-review-edit-proposal)
    map)
  "Keymap of a section that is waiting for an answer (plan section 6.3).")

(defvar ecc-file-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'ecc-session-visit)
    (define-key map (kbd "SPC") 'magit-section-toggle)
    (define-key map (kbd "d") 'ecc-session-review-file)
    map)
  "Keymap of a file row in the Files section.")

(defconst ecc-render-expandable-classes
  '(ecc-section-tool ecc-section-agent ecc-section-thinking ecc-section-file
    ecc-section-request ecc-section-system ecc-section-unknown)
  "Section classes the block movement commands stop at (FR-OUT-14).")

(defun ecc-render--class (node)
  "Return the section class that draws NODE."
  (pcase (ecc-node-type node)
    ('text 'ecc-section-text)
    ('thinking 'ecc-section-thinking)
    ('step 'ecc-section-step)
    ('tool 'ecc-section-tool)
    ('agent 'ecc-section-agent)
    ((or 'permission 'question 'plan) 'ecc-section-request)
    ('result 'ecc-section-result)
    ('system (if (eq (ecc-model-node-get node 'kind) 'prompt)
                 'ecc-section-prompt
               'ecc-section-system))
    ('recap 'ecc-section-system)
    (_ 'ecc-section-unknown)))

(defun ecc-render--hide-p (node)
  "Return non-nil when the body of NODE starts collapsed (FR-OUT-3)."
  (and (memq (ecc-node-type node) ecc-render-hidden-types)
       (not (eq (ecc-model-node-get node 'kind) 'prompt))
       t))

;;;; Buffer state

(defvar-local ecc-render--session nil
  "The session drawn in this buffer.")

(defvar-local ecc-render--live-start nil
  "Marker where the live region starts, after the last frozen turn.")

(defvar-local ecc-render--top-end nil
  "Marker where the top region ends and the first turn begins.")

(defvar-local ecc-render--frozen 0
  "Number of turns that are finished and will not be drawn again.")

(defvar-local ecc-render--visibility-cache nil
  "Hash mapping a section value to whether the user left it collapsed.")

(defvar-local ecc-render--timer nil
  "Debounce timer of this buffer, or nil.")

(defvar-local ecc-render--node-sections nil
  "Hash mapping a node id to (SECTION . DEPTH) for the nodes drawn live.
Emptied by every redraw of the live region, so it can never point at a
section that was deleted.")

(defvar-local ecc-render--flash-pending nil
  "Non-nil when the live region should flash after the next redraw.
Set when a turn finishes, so that the eye is drawn to the answer that
has just arrived (FR-OUT-11 e).")

(defvar-local ecc-render--effect-targets nil
  "Sections noted for a visual effect while the live region was drawn.
Each entry is (KIND . SECTION); see `ecc-render--apply-effects'.")

(defvar-local ecc-render--pending-deltas nil
  "Alist of node to the streamed text not drawn yet, newest node first.")

(defvar-local ecc-render--delta-timer nil
  "Timer that will draw the pending deltas, or nil.")

(defvar-local ecc-render--delta-count 0
  "Deltas received since the pending ones were last drawn.")

;;;; Text helpers

(defun ecc-render--pad (depth)
  "Return the indentation string for DEPTH."
  (make-string (* 2 depth) ?\s))

(defun ecc-render--one-line (string)
  "Return STRING with newlines squeezed out, for use in a heading."
  (replace-regexp-in-string "[ \t\n\r]+" " " (or string "")))

(defun ecc-render--insert-lines (text prefix face)
  "Insert TEXT in FACE, putting PREFIX in front of every line.
Faces TEXT already carries win over FACE, which is how Markdown and
diff colouring survive."
  (let ((body (string-trim-right (or text "") "[\n]+")))
    (dolist (line (split-string body "\n"))
      (let ((string (concat prefix line)))
        (add-face-text-property 0 (length string) face t string)
        (insert string "\n")))))

(defun ecc-render--stream-string (text prefix)
  "Return TEXT with PREFIX after every newline, ready to be appended."
  (string-replace "\n" (concat "\n" prefix) (or text "")))

(defun ecc-render--insert-input (input prefix)
  "Insert the tool INPUT as one line per key, indented by PREFIX."
  (dolist (pair input)
    (let ((key (symbol-name (car pair)))
          (value (ecc-protocol-value-string (cdr pair))))
      (if (string-search "\n" value)
          (progn
            (insert (propertize (format "%s%s:" prefix key) 'face 'ecc-dim-face) "\n")
            (ecc-render--insert-lines value (concat prefix "  ") 'ecc-dim-face))
        (insert (propertize (format "%s%s: %s" prefix key value)
                            'face 'ecc-dim-face)
                "\n")))))

(defun ecc-render--result-text (result)
  "Return the text of a tool RESULT, whatever shape it arrived in."
  (cond ((stringp result) result)
        ((vectorp result)
         (mapconcat (lambda (block)
                      (or (alist-get 'text block)
                          (ecc-protocol-value-string block)))
                    result "\n"))
        ((null result) "")
        (t (ecc-protocol-value-string result))))

(defun ecc-render--clip (text limit)
  "Return the first LIMIT lines of TEXT and a note when more was cut."
  (let ((lines (split-string (string-trim-right (or text "") "[\n]+") "\n")))
    (if (<= (length lines) limit)
        (string-join lines "\n")
      (concat (string-join (seq-take lines limit) "\n")
              (format "\n… %d more lines (RET)" (- (length lines) limit))))))

(defun ecc-render--count-string (n)
  "Return N as a short string, in thousands above 999."
  (cond ((null n) "?")
        ((>= n 1000) (format "%.1fk" (/ n 1000.0)))
        (t (format "%d" n))))

(defun ecc-render-tool-summary (name input)
  "Return the one line summary of the call to NAME with INPUT."
  (ecc-render--one-line
   (or (pcase name
         ((or "Read" "Write" "Edit" "MultiEdit" "NotebookEdit")
          (when-let* ((path (alist-get 'file_path input)))
            (abbreviate-file-name path)))
         ("Bash" (ecc--truncate (alist-get 'command input) 60))
         ((or "Glob" "Grep") (alist-get 'pattern input))
         ((or "Task" "Agent") (alist-get 'description input))
         ("TodoWrite" "todos")
         ("TaskCreate" (alist-get 'subject input))
         ("TaskUpdate" (format "#%s%s" (or (alist-get 'taskId input) "?")
                               (if-let* ((status (alist-get 'status input)))
                                   (concat " → " status)
                                 "")))
         (_ nil))
       (and (consp input)
            (ecc--truncate (ecc-protocol-value-string (cdr (car input))) 60))
       "")))

;;;; The top region: header, Files, Tasks

(defun ecc-render--header-string (session)
  "Return the header line of SESSION, ending in a newline."
  (concat
   (propertize (or (ecc-session-name session) "?") 'face 'ecc-heading-face)
   (propertize
    (format "  ·  %s  ·  %s  ·  %s  ·  $%.4f\n"
            (or (alist-get 'model (ecc-session-init session)) "?")
            (or (ecc-session-permission-mode session) "default")
            (ecc-session-state session)
            (or (ecc-session-total-cost session) 0))
    'face 'ecc-dim-face)))

(defun ecc-render--file-counts (entry)
  "Return (ADDED . REMOVED) over every change of the file ENTRY."
  (let ((added 0) (removed 0)
        (patches (ecc-file-entry-patches entry)))
    (dolist (hunk (ecc-file-entry-hunks entry))
      (let ((counts (if (and (car patches) (> (length (car patches)) 0))
                        (ecc-diff-patch-counts (car patches))
                      (ecc-diff-counts (ecc-diff-lines (car hunk) (cdr hunk))))))
        (cl-incf added (car counts))
        (cl-incf removed (cdr counts)))
      (setq patches (cdr patches)))
    (cons added removed)))

(defun ecc-render--file-diff (entry)
  "Return the merged diff text of every change of the file ENTRY."
  (let ((patches (ecc-file-entry-patches entry))
        (parts nil))
    (dolist (hunk (ecc-file-entry-hunks entry))
      (push (cond ((and (car patches) (> (length (car patches)) 0))
                   (ecc-diff-from-patch (car patches)))
                  ((null (car hunk)) (ecc-diff-for-write (cdr hunk) nil))
                  (t (or (ecc-diff-render (car hunk) (cdr hunk))
                         (propertize "(no change)\n" 'face 'diff-context))))
            parts)
      (setq patches (cdr patches)))
    (string-join (nreverse parts) "")))

(defun ecc-render--file-heading (entry)
  "Return the heading of the file ENTRY."
  (let ((counts (ecc-render--file-counts entry))
        (ops (string-join
              (delq nil (list (and (> (ecc-file-entry-reads entry) 0)
                                   (format "R×%d" (ecc-file-entry-reads entry)))
                              (and (> (ecc-file-entry-edits entry) 0)
                                   (format "E×%d" (ecc-file-entry-edits entry)))
                              (and (> (ecc-file-entry-writes entry) 0)
                                   (format "W×%d" (ecc-file-entry-writes entry)))))
              " ")))
    (concat "  "
            (propertize (abbreviate-file-name (ecc-file-entry-path entry))
                        'face 'ecc-tool-face)
            (propertize (concat "  " ops) 'face 'ecc-dim-face)
            (if (ecc-file-entry-hunks entry)
                (concat "  "
                        (propertize (format "+%d" (car counts)) 'face 'diff-added)
                        " "
                        (propertize (format "−%d" (cdr counts)) 'face 'diff-removed))
              ""))))

(defun ecc-render--insert-files (session)
  "Insert the Files section of SESSION, unless there is nothing to list."
  (let ((entries (ecc-model-files session)))
    (when entries
      (magit-insert-section (ecc-section-files "files" t)
        (magit-insert-heading
          (propertize (format "Files (%d)" (length entries)) 'face 'ecc-heading-face))
        (dolist (entry entries)
          (magit-insert-section (ecc-section-file
                                 (concat "file:" (ecc-file-entry-path entry)) t)
            (magit-insert-heading (ecc-render--file-heading entry))
            (when (ecc-file-entry-hunks entry)
              (ecc-render--insert-lines (ecc-render--file-diff entry) "    "
                                        'ecc-dim-face))))))))

(defun ecc-render--task-mark (status)
  "Return the checkbox for a task with STATUS."
  (pcase status
    ("completed" "[x]")
    ("in_progress" "[/]")
    (_ "[ ]")))

(defun ecc-render--insert-tasks (session)
  "Insert the Tasks section of SESSION, unless there are no tasks."
  (let ((tasks (ecc-model-tasks session)))
    (when tasks
      (magit-insert-section (ecc-section-tasks "tasks")
        (magit-insert-heading
          (propertize (format "Tasks (%d/%d)"
                              (seq-count (lambda (task)
                                           (equal (ecc-task-status task) "completed"))
                                         tasks)
                              (length tasks))
                      'face 'ecc-heading-face))
        (dolist (task tasks)
          (magit-insert-section (ecc-section-task (concat "task:" (ecc-task-id task)))
            (insert (propertize
                     (format "  %s %s" (ecc-render--task-mark (ecc-task-status task))
                             (or (ecc-task-subject task) ""))
                     'face (pcase (ecc-task-status task)
                             ("completed" 'ecc-dim-face)
                             ("in_progress" 'ecc-pending-face)
                             (_ 'default)))
                    "\n")))))))

(defun ecc-render--insert-history-button (session)
  "Insert the button that reads the page before the first turn of SESSION.
Nothing is inserted when the whole recording has been read, or when
there is none (FR-HIST-1)."
  (when (ecc-render--history-more-p session)
    (magit-insert-section (ecc-section-history "history")
      (insert-text-button
       "Load older messages"
       'action (lambda (_button)
                 (require 'ecc-history)
                 (ecc-history-load-more session))
       'follow-link t
       'help-echo "Load the previous 50 turns")
      (insert "\n"))))

(defun ecc-render--history-more-p (session)
  "Return non-nil when SESSION has an older page of its recording left.
The paging position is a slot of the session, so this asks no module
above the renderer (plan section 1.3)."
  (let ((offset (ecc-session-history-offset session)))
    (and offset (> offset 0))))

(defun ecc-render--insert-top (session)
  "Insert the header, Files and Tasks of SESSION and the blank line after."
  (magit-insert-section (ecc-section-header "header")
    (insert (ecc-render--header-string session)))
  (ecc-render--insert-files session)
  (ecc-render--insert-tasks session)
  (ecc-render--insert-history-button session)
  (insert "\n"))

(defun ecc-render--top-sections ()
  "Return the sections of the top region, in order."
  (let ((pos (marker-position ecc-render--top-end)))
    (seq-filter (lambda (section) (< (marker-position (oref section start)) pos))
                (oref magit-root-section children))))

(defun ecc-render--update-top (session)
  "Redraw the top region of SESSION in place.
The turns below keep their markers and are not drawn again."
  (let* ((old (ecc-render--top-sections))
         (root magit-root-section)
         (start (marker-position (oref root start)))
         (end (marker-position ecc-render--top-end))
         (live (marker-position ecc-render--live-start)))
    (mapc #'ecc-render--remember-visibility old)
    (setf (oref root children)
          (seq-remove (lambda (section) (memq section old)) (oref root children)))
    (save-excursion
      (delete-region start end)
      (goto-char start)
      (let ((magit-insert-section--parent root))
        (ecc-render--insert-top session))
      ;; The root start marker advances with text inserted at it, and the
      ;; end markers collapsed with the deletion, so all are put back by
      ;; hand.  The first turn starts where the top region ends, and its
      ;; own start marker advanced with the insertion.
      (set-marker (oref root start) start)
      (set-marker ecc-render--top-end (point))
      (set-marker ecc-render--live-start (+ live (- (point) end)))
      (let ((new (seq-filter (lambda (section)
                               (>= (marker-position (oref section start)) start))
                             (ecc-render--top-sections))))
        (setf (oref root children)
              (append new (seq-remove (lambda (section) (memq section new))
                                      (oref root children))))
        (mapc #'ecc-render--apply-visibility new)))))

;;;; Nodes

(defun ecc-render--skip-p (node)
  "Return non-nil when NODE has nothing worth drawing.
An empty thinking block is all signature and no text."
  (and (eq (ecc-node-type node) 'thinking)
       (not (ecc-node-streaming node))
       (string-empty-p (string-trim (or (ecc-model-node-get node 'text) "")))))

(defun ecc-render--icon (tool-name)
  "Return the icon of TOOL-NAME with the space that follows it, or nothing."
  (let ((icon (ecc-visual-icon tool-name)))
    (if (string-empty-p icon) "" (concat icon " "))))

(defun ecc-render--status-mark (status)
  "Return the one character mark for STATUS."
  (pcase status
    ('running "…")
    ('error "✗")
    ('denied "✗")
    ('pending "⚠")
    (_ "✓")))

(defun ecc-render--insert-node (session node depth)
  "Insert NODE of SESSION at DEPTH."
  (unless (ecc-render--skip-p node)
    (let ((type (ecc-node-type node))
          (section nil))
      (setq section
            (magit-insert-section ((eval (ecc-render--class node))
                                   (ecc-node-id node)
                                   (ecc-render--hide-p node))
              (pcase type
                ('text (ecc-render--insert-text node depth))
                ('thinking (ecc-render--insert-thinking node depth))
                ('step (ecc-render--insert-step session node depth))
                ('tool (ecc-render--insert-tool session node depth))
                ('agent (ecc-render--insert-agent session node depth))
                ((or 'permission 'question 'plan) (ecc-render--insert-request node depth))
                ('result (ecc-render--insert-result node depth))
                ((or 'system 'recap) (ecc-render--insert-system node depth))
                (_ (ecc-render--insert-unknown node depth)))))
      (when ecc-render--node-sections
        (puthash (ecc-node-id node) (cons section depth) ecc-render--node-sections))
      (ecc-render--note-effect node section)
      section)))

(defun ecc-render--note-effect (node section)
  "Remember that SECTION of NODE deserves a visual effect (FR-OUT-11).
The effects themselves are put on once the redraw is over: an overlay
made now would be deleted with the region it sits in."
  (pcase (ecc-node-type node)
    ((or 'tool 'agent)
     (when (eq (ecc-node-status node) 'running)
       (push (cons 'pulse section) ecc-render--effect-targets)))
    ((or 'permission 'question 'plan)
     (when (eq (ecc-node-status node) 'pending)
       (push (cons 'blink section) ecc-render--effect-targets)))))

(defun ecc-render--apply-effects ()
  "Animate the lines noted while the live region was drawn (FR-OUT-11).
The newest line comes first, so that the limit of
`ecc-visual-max-effects' keeps what is happening now."
  (ecc-visual-clear-effects (current-buffer))
  (dolist (target (nreverse ecc-render--effect-targets))
    (pcase-let ((`(,kind . ,section) target))
      (when (and (markerp (oref section start))
                 (marker-position (oref section start)))
        (let* ((start (oref section start))
               (end (save-excursion (goto-char start) (line-end-position)))
               (overlay (make-overlay start end (current-buffer))))
          (overlay-put overlay 'evaporate t)
          (pcase kind
            ('pulse (ecc-visual-pulse-overlay overlay))
            ('blink (ecc-visual-blink-overlay overlay)))))))
  (setq ecc-render--effect-targets nil))

(defun ecc-render--insert-stream-text (node text prefix face)
  "Insert the streamed TEXT of NODE with PREFIX after each newline.
A marker at the end of the text, kept on NODE, is where the next delta
is appended (plan section 5.2, item 4)."
  (insert (propertize (concat prefix (ecc-render--stream-string text prefix))
                      'face face))
  ;; The marker must stay put while the rest of the buffer is inserted
  ;; after it, so it does not advance on insertion; a delta moves it by
  ;; hand instead.
  (let ((marker (or (ecc-node-marker-end node) (make-marker))))
    (set-marker marker (point))
    (set-marker-insertion-type marker nil)
    (setf (ecc-node-marker-end node) marker))
  (insert "\n"))

(defun ecc-render--insert-text (node depth)
  "Insert the assistant text NODE at DEPTH."
  (let ((pad (ecc-render--pad depth))
        (face (if (ecc-model-node-get node 'synthetic)
                  'ecc-synthetic-face
                'ecc-assistant-face)))
    (if (ecc-node-streaming node)
        (ecc-render--insert-stream-text node (ecc-node-streaming-text node) pad face)
      (ecc-render--insert-lines (ecc-markdown-fontify (ecc-model-node-get node 'text))
                                pad face))))

(defun ecc-render--insert-thinking (node depth)
  "Insert the thinking NODE at DEPTH."
  (let ((pad (ecc-render--pad depth)))
    (magit-insert-heading
      (concat pad (propertize (if (ecc-node-streaming node) "Thinking…" "Thinking")
                              'face 'ecc-thinking-face)))
    (if (ecc-node-streaming node)
        (ecc-render--insert-stream-text node (ecc-node-streaming-text node)
                                        (concat pad "  ") 'ecc-thinking-face)
      (ecc-render--insert-lines (ecc-model-node-get node 'text)
                                (concat pad "  ") 'ecc-thinking-face))))

(defun ecc-render--insert-step (session node depth)
  "Insert the step NODE of SESSION at DEPTH."
  (let ((pad (ecc-render--pad depth)))
    (magit-insert-heading
      (concat pad
              (propertize
               (mapconcat (lambda (pair) (format "%s ×%d" (car pair) (cdr pair)))
                          (ecc-model-tool-counts node) ", ")
               'face 'ecc-tool-face)))
    (dolist (child (ecc-node-children node))
      (ecc-render--insert-node session child (1+ depth)))))

(defun ecc-render--tool-heading (node depth)
  "Return the heading line of the tool NODE at DEPTH, without newline."
  (let* ((name (or (ecc-model-node-get node 'name) "?"))
         (error-p (eq (ecc-node-status node) 'error))
         (summary (if (ecc-node-streaming node)
                      (format "streaming %s chars…"
                              (ecc-render--count-string
                               (length (ecc-node-streaming-text node))))
                    (ecc-render-tool-summary name (ecc-model-node-get node 'input)))))
    (concat (ecc-render--pad depth)
            (propertize (ecc-render--status-mark (ecc-node-status node))
                        'face (if error-p 'ecc-error-face 'ecc-dim-face))
            " "
            (ecc-render--icon name)
            (propertize name 'face (if error-p 'ecc-error-face 'ecc-tool-face))
            "  "
            (propertize summary 'face 'ecc-dim-face))))

(defun ecc-render--insert-tool-body (node body)
  "Insert the input and the result of the tool NODE, indented by BODY.
An Edit or a Write shows its input as a diff (FR-OUT-7)."
  (let* ((name (ecc-model-node-get node 'name))
         (input (ecc-model-node-get node 'input))
         (error-p (eq (ecc-node-status node) 'error))
         (diff (and input (ecc-diff-for-tool name input
                                             (ecc-model-node-get node 'before)))))
    (cond
     ((ecc-node-streaming node)
      (ecc-render--insert-lines (ecc-render--clip (ecc-node-streaming-text node)
                                                  ecc-render-result-max-lines)
                                body 'ecc-dim-face))
     (diff
      (when-let* ((path (alist-get 'file_path input)))
        (insert (propertize (concat body (abbreviate-file-name path)) 'face 'ecc-dim-face)
                "\n"))
      (ecc-render--insert-lines (ecc-render--clip diff ecc-render-diff-max-lines)
                                body 'ecc-dim-face))
     (t (ecc-render--insert-input input body)))
    (when-let* ((status (ecc-model-node-get node 'task-status)))
      (insert (propertize (format "%stask: %s" body status) 'face 'ecc-dim-face) "\n"))
    (pcase (ecc-node-status node)
      ('running (insert (propertize (concat body "…") 'face 'ecc-dim-face) "\n"))
      ('denied (insert (propertize (concat body "denied") 'face 'ecc-error-face) "\n"))
      (_ (when (ecc-model-node-get node 'result)
           (ecc-render--insert-lines
            (ecc-render--clip (ecc-render--result-text
                               (ecc-model-node-get node 'result))
                              ecc-render-result-max-lines)
            (concat body "→ ")
            (if error-p 'ecc-error-face 'ecc-dim-face)))))))

(defun ecc-render--insert-tool (session node depth)
  "Insert the tool NODE of SESSION at DEPTH."
  (magit-insert-heading (ecc-render--tool-heading node depth))
  (ecc-render--insert-tool-body node (concat (ecc-render--pad depth) "  "))
  (dolist (child (ecc-node-children node))
    (ecc-render--insert-node session child (1+ depth))))

(defun ecc-render--agent-heading (node depth)
  "Return the heading line of the agent NODE at DEPTH."
  (let* ((input (ecc-model-node-get node 'input))
         (agent-type (or (ecc-model-node-get node 'agent-type)
                         (alist-get 'subagent_type input)
                         "Agent"))
         (description (or (alist-get 'description input)
                          (ecc-model-node-get node 'agent-description)
                          ""))
         (usage (ecc-model-node-get node 'agent-usage))
         (tools (let ((n 0))
                  (dolist (child (ecc-node-children node))
                    (if (eq (ecc-node-type child) 'step)
                        (cl-incf n (length (ecc-node-children child)))
                      (when (memq (ecc-node-type child) '(tool agent))
                        (cl-incf n))))
                  (or (alist-get 'tool_uses usage) n)))
         (duration (or (alist-get 'duration_ms usage)
                       (when-let* ((started (ecc-model-node-get node 'started))
                                   (finished (ecc-model-node-get node 'finished)))
                         (round (* 1000 (float-time (time-subtract finished started)))))))
         (error-p (eq (ecc-node-status node) 'error)))
    (concat (ecc-render--pad depth)
            (propertize (ecc-render--status-mark (ecc-node-status node))
                        'face (if error-p 'ecc-error-face 'ecc-dim-face))
            " "
            (ecc-render--icon "Agent")
            (propertize (format "Agent %s" agent-type)
                        'face (if error-p 'ecc-error-face 'ecc-tool-face))
            "  "
            (propertize (ecc-render--one-line description) 'face 'ecc-dim-face)
            (propertize (format "  ·  %d tools%s" tools
                                (if duration (format "  ·  %.1fs" (/ duration 1000.0)) ""))
                        'face 'ecc-dim-face))))

(defun ecc-render--insert-agent (session node depth)
  "Insert the agent NODE of SESSION at DEPTH, its messages nested (FR-OUT-9)."
  (let ((body (concat (ecc-render--pad depth) "  ")))
    (magit-insert-heading (ecc-render--agent-heading node depth))
    (dolist (child (ecc-node-children node))
      (ecc-render--insert-node session child (1+ depth)))
    (pcase (ecc-node-status node)
      ('running (insert (propertize (concat body "…") 'face 'ecc-dim-face) "\n"))
      (_ (when (ecc-model-node-get node 'result)
           (ecc-render--insert-lines
            (ecc-render--clip (ecc-render--result-text
                               (ecc-model-node-get node 'result))
                              ecc-render-result-max-lines)
            (concat body "→ ")
            (if (eq (ecc-node-status node) 'error) 'ecc-error-face 'ecc-dim-face)))))))

(defun ecc-render--unsaved-p (path)
  "Return non-nil when a buffer visiting PATH has unsaved changes (FR-SYNC-2)."
  (when-let* ((buffer (and (stringp path) (find-buffer-visiting path))))
    (buffer-modified-p buffer)))

(defun ecc-render--request-hints (kind)
  "Return the key hints shown on a pending request of KIND."
  (pcase kind
    ('question "   RET: answer  d: deny")
    ('plan "   RET: review  a: approve  d: deny")
    (_ "   a: allow  d: deny  A: always  t: turn  p: pattern  c: comment  e: edit")))

(defun ecc-render--request-heading (node)
  "Return the heading of the request NODE.
A pending one carries its key hints and, for a file that is open with
unsaved changes, a warning (FR-SYNC-2); an answered one keeps what was
answered."
  (let* ((request (ecc-model-node-get node 'request))
         (name (if request (ecc-request-tool-name request) "?"))
         (kind (ecc-node-type node))
         (label (pcase kind
                  ('question "Question")
                  ('plan "Plan review")
                  (_ (format "Permission: %s" name))))
         (outcome (ecc-model-node-get node 'outcome-message)))
    (pcase (ecc-node-status node)
      ('pending (concat (propertize (format "⚠ %s" label) 'face 'ecc-pending-face)
                        "  "
                        (propertize (ecc-render--one-line
                                     (and request
                                          (ecc-render-tool-summary
                                           name (ecc-request-input request))))
                                    'face 'ecc-dim-face)
                        (if (and request
                                 (ecc-render--unsaved-p
                                  (alist-get 'file_path (ecc-request-input request))))
                            (propertize "  ⚠ unsaved changes" 'face 'ecc-error-face)
                          "")
                        (propertize (ecc-render--request-hints kind)
                                    'face 'ecc-dim-face)))
      ('denied (concat (propertize (format "✗ %s" label) 'face 'ecc-error-face)
                       (propertize (format "  denied%s"
                                           (if outcome
                                               (concat ": " (ecc-render--one-line outcome))
                                             ""))
                                   'face 'ecc-dim-face)))
      (_ (concat (propertize (format "✓ %s" label) 'face 'ecc-dim-face)
                 (propertize (concat "  " (if outcome
                                              (ecc-render--one-line outcome)
                                            "allowed"))
                             'face 'ecc-dim-face))))))

(defun ecc-render--insert-request (node depth)
  "Insert the permission, question or plan NODE at DEPTH.
An Edit or a Write is shown as the diff it would make, with the lines
of the file around it (FR-DIFF-1)."
  (let* ((pad (ecc-render--pad depth))
         (body (concat pad "  "))
         (request (ecc-model-node-get node 'request))
         (diff (and request
                    (ecc-diff-for-tool (ecc-request-tool-name request)
                                       (ecc-request-input request)
                                       (ecc-model-node-get node 'before)))))
    (magit-insert-heading (concat pad (ecc-render--request-heading node)))
    (cond
     ((null request) nil)
     ((eq (ecc-request-kind request) 'question)
      (ecc-render--insert-questions request body
                                    (ecc-model-node-get node 'answers)))
     ((eq (ecc-request-kind request) 'plan)
      (ecc-render--insert-lines
       (ecc-render--clip (ecc-markdown-fontify
                          (or (alist-get 'plan (ecc-request-input request)) ""))
                         ecc-render-diff-max-lines)
       body 'ecc-assistant-face))
     (diff
      (when-let* ((path (alist-get 'file_path (ecc-request-input request))))
        (insert (propertize (concat body (abbreviate-file-name path)) 'face 'ecc-dim-face)
                "\n"))
      (ecc-render--insert-lines (ecc-render--clip diff ecc-render-diff-max-lines)
                                body 'ecc-dim-face))
     (t (ecc-render--insert-input (ecc-request-input request) body)))))

(defun ecc-render--insert-questions (request prefix &optional answers)
  "Insert the questions of REQUEST indented by PREFIX.
ANSWERS is an alist of question text to the answer given, drawn under
each question once the request was answered."
  (let ((questions (alist-get 'questions (ecc-request-input request)))
        (n 0))
    (seq-doseq (question (or questions []))
      (let* ((text (alist-get 'question question))
             (answer (cdr (assoc text answers))))
        (insert (propertize (concat prefix (ecc-render--one-line text))
                            'face (if answer 'ecc-dim-face 'ecc-pending-face))
                "\n")
        (setq n 0)
        (seq-doseq (option (or (alist-get 'options question) []))
          (cl-incf n)
          (insert (propertize (format "%s  %d. %s" prefix n (alist-get 'label option))
                              'face 'ecc-dim-face)
                  "\n"))
        (when answer
          (insert (propertize (format "%s  → %s" prefix (ecc-render--one-line answer))
                              'face 'ecc-user-face)
                  "\n"))))))

(defun ecc-render--insert-result (node depth)
  "Insert the result NODE at DEPTH."
  (let ((result (ecc-model-node-get node 'result)))
    (insert
     (propertize
      (format "%s● %s · %s turns · $%.4f · %.1fs"
              (ecc-render--pad depth)
              (or (alist-get 'stop_reason result) (alist-get 'subtype result) "?")
              (or (alist-get 'num_turns result) 0)
              (or (alist-get 'total_cost_usd result) 0)
              (/ (or (alist-get 'duration_ms result) 0) 1000.0))
      'face 'ecc-dim-face)
     "\n")))

(defun ecc-render--system-heading (node)
  "Return the heading text of the system NODE."
  (let ((kind (ecc-model-node-get node 'kind))
        (message (ecc-model-node-get node 'message)))
    (pcase kind
      ('compact
       (let ((result (ecc-model-node-get node 'result))
             (metadata (ecc-model-node-get node 'metadata)))
         (format "⟲ compact %s%s%s"
                 (cond ((null result) "boundary")
                       ((equal result "success") "done, context reset")
                       (t result))
                 ;; What the compaction did to the context, which is
                 ;; what the indicator of FR-HINT-3 goes back to.
                 (if-let* ((post (alist-get 'post_tokens metadata)))
                     (format " · %s → %s tokens"
                             (ecc-render--count-string
                              (or (alist-get 'pre_tokens metadata) 0))
                             (ecc-render--count-string post))
                   "")
                 (if-let* ((e (ecc-model-node-get node 'error)))
                     (concat " — " e) ""))))
      ('hook (format "hook %s%s"
                     (alist-get 'hook_name message)
                     (pcase (alist-get 'subtype message)
                       ("hook_started" " started")
                       ("hook_response" (format " → %s" (or (alist-get 'outcome message)
                                                            "?")))
                       (_ ""))))
      (_ (or (ecc-model-node-get node 'text) (format "%s" kind))))))

(defun ecc-render--insert-system (node depth)
  "Insert the system NODE at DEPTH."
  (let ((pad (ecc-render--pad depth))
        (kind (ecc-model-node-get node 'kind)))
    (if (eq kind 'prompt)
        (ecc-render--insert-lines (ecc-model-node-get node 'text)
                                  (concat pad "▌ ") 'ecc-user-face)
      (magit-insert-heading
        (concat pad (propertize (ecc-render--one-line
                                 (ecc-render--system-heading node))
                                'face 'ecc-dim-face)))
      (when-let* ((message (ecc-model-node-get node 'message)))
        (ecc-render--insert-lines (ecc--truncate (format "%S" message) 400)
                                  (concat pad "  ") 'ecc-dim-face)))))

(defun ecc-render--insert-unknown (node depth)
  "Insert the unknown NODE at DEPTH (FR-OUT-1)."
  (let* ((pad (ecc-render--pad depth))
         (message (or (ecc-model-node-get node 'message)
                      (ecc-model-node-get node 'block)))
         (reason (ecc-model-node-get node 'reason)))
    (magit-insert-heading
      (concat pad (propertize (format "unknown: %s%s"
                                      (or (alist-get 'type message) "?")
                                      (if reason (format " (%s)" reason) ""))
                              'face 'ecc-error-face)))
    (ecc-render--insert-lines (ecc--truncate (format "%S" message) 2000)
                              (concat pad "  ") 'ecc-dim-face)))

;;;; Turns

(defun ecc-render--turn-heading (session turn)
  "Return the heading of TURN of SESSION."
  (let ((duration (ecc-model-turn-duration turn))
        (index (1+ (seq-position (ecc-session-turns session) turn #'eq))))
    (concat
     (propertize (format "Turn %d" index) 'face 'ecc-heading-face)
     "  "
     (propertize (ecc--truncate (or (ecc-turn-prompt turn) "(resumed)") 60)
                 'face 'ecc-user-face)
     (if (ecc-turn-end-time turn)
         (propertize (if (ecc-turn-cost turn)
                         (format "  ·  %.1fs  ·  $%.4f"
                                 (or duration 0) (ecc-turn-cost turn))
                       ;; A turn read back from a recording has no result
                       ;; message, so its cost is not known (FR-HIST-1).
                       (format "  ·  %.1fs" (or duration 0)))
                     'face 'ecc-dim-face)
       ""))))

(defun ecc-render--insert-turn (session turn)
  "Insert TURN of SESSION and return its section."
  (magit-insert-section (ecc-section-turn (ecc-turn-id turn))
    (magit-insert-heading (ecc-render--turn-heading session turn))
    (when-let* ((prompt (ecc-turn-prompt turn)))
      (magit-insert-section (ecc-section-prompt (concat (ecc-turn-id turn) "/prompt"))
        ;; The prompt carries fenced blocks of its own: the quoted region
        ;; and the context Emacs attached (FR-CTX-1, FR-INP-8), which are
        ;; worth the same colouring as the reply (FR-OUT-15).
        (ecc-render--insert-lines (ecc-markdown-fontify prompt) "▌ " 'ecc-user-face)))
    (dolist (child (ecc-turn-children turn))
      (ecc-render--insert-node session child 1))))

(defvar ecc-render-tail-functions nil
  "Functions adding a line under the state line at the end of a transcript.
Each is called with the session and returns a string without a final
newline, or nil.  The modules above the renderer put what belongs at
the end of the conversation here rather than in the turns: the recap
of FR-HINT-1 is one such line (plan section 5.2).")

(defvar ecc-render-header-functions nil
  "Functions adding to the header line of a session buffer.
Each is called with the session and returns a string or nil; what
comes back is appended to the state line of FR-OUT-6.  The context
left of FR-HINT-3 arrives this way.")

(defun ecc-render--tail-string (session)
  "Return the state line of SESSION, or nil when there is nothing to say."
  (if (eq (ecc-session-kind session) 'handoff)
      ;; The process is gone on purpose: the conversation is being had in
      ;; a terminal and the buffer follows the recording (FR-TUI-3).
      (propertize "⇄ open in the terminal; it comes back when the terminal is left"
                  'face 'ecc-pending-face)
    (pcase (ecc-session-state session)
      ('idle nil)
      ('exited (propertize
                (format "Exited with code %s; R resumes it"
                        (or (alist-get 'exit-status (ecc-session-progress session))
                            "?"))
                'face 'ecc-error-face))
      (state (propertize (format "%s %s…" (ecc-render--running-mark) state)
                         'face 'ecc-pending-face)))))

(defun ecc-render--running-mark ()
  "Return the mark that stands for work in progress (FR-OUT-11 a)."
  (if ecc-visual-enable-spinner (ecc-visual-spinner-frame) "●"))

(defun ecc-render--tail-lines (session)
  "Return the lines drawn at the end of the transcript of SESSION."
  (delq nil (cons (ecc-render--tail-string session)
                  (mapcar (lambda (function)
                            (condition-case err (funcall function session)
                              (error (ecc-log (ecc-session-name session)
                                              "tail function %s: %s" function
                                              (error-message-string err))
                                     nil)))
                          ecc-render-tail-functions))))

(defun ecc-render--insert-live (session)
  "Insert the turns of SESSION that are not frozen yet, and the state line."
  (dolist (turn (seq-drop (ecc-session-turns session) ecc-render--frozen))
    (ecc-render--insert-turn session turn))
  (when-let* ((lines (ecc-render--tail-lines session)))
    (magit-insert-section (ecc-section-tail "tail")
      (dolist (line lines)
        (insert line "\n")))))

;;;; The state line (FR-OUT-6)

(defun ecc-render-status-line (session)
  "Return the one line summary of what SESSION is doing right now."
  (let* ((progress (ecc-session-progress session))
         (tool (ecc-model-running-tool session))
         (thinking (alist-get 'thinking-tokens progress))
         (streaming (alist-get 'streaming progress))
         (status (alist-get 'status progress))
         (request (car (ecc-session-pending session))))
    (pcase (if (eq (ecc-session-kind session) 'handoff) 'handoff
             (ecc-session-state session))
      ('handoff (propertize "⇄ handed over to the terminal" 'face 'ecc-pending-face))
      ('idle (propertize "○ idle" 'face 'ecc-dim-face))
      ('starting (propertize "○ starting…" 'face 'ecc-dim-face))
      ('exited (propertize (format "✗ exited (code %s)"
                                   (or (alist-get 'exit-status progress) "?"))
                           'face 'ecc-error-face))
      ('compacting (propertize "⟲ compacting…" 'face 'ecc-pending-face))
      ((or 'waiting-permission 'waiting-question 'waiting-plan)
       (propertize
        (format "⚠ %s: %s"
                (pcase (and request (ecc-request-kind request))
                  ('question "question")
                  ('plan "plan review")
                  (_ "permission"))
                (if request
                    (ecc-render--one-line
                     (concat (ecc-request-tool-name request) " "
                             (ecc-render-tool-summary (ecc-request-tool-name request)
                                                      (ecc-request-input request))))
                  ""))
        'face 'ecc-pending-face))
      (_
       (concat
        (propertize "● running" 'face 'ecc-pending-face)
        (propertize
         (concat
          (when status (format "  ·  %s" status))
          (when tool
            (format "  ·  %s %s"
                    (ecc-model-node-get tool 'name)
                    (if (ecc-node-streaming tool)
                        (format "(%s chars…)"
                                (ecc-render--count-string
                                 (length (ecc-node-streaming-text tool))))
                      (ecc-render-tool-summary (ecc-model-node-get tool 'name)
                                               (ecc-model-node-get tool 'input)))))
          (when thinking (format "  ·  thinking %s tokens"
                                 (ecc-render--count-string thinking)))
          (when (and streaming (memq (car streaming) '(text thinking)))
            (format "  ·  %s %s chars" (car streaming)
                    (ecc-render--count-string (cdr streaming)))))
         'face 'ecc-dim-face))))))

(defun ecc-render-header-line ()
  "Return the header line of the session buffer, for `header-line-format'.
What `ecc-render-header-functions' returns follows the state line,
separated by the same middle dot the state line uses."
  (when ecc-render--session
    (let ((session ecc-render--session))
      (ecc--mode-line-escape
       (concat " "
               (if (ecc-visual-spinner-running-p (current-buffer))
                   (concat (ecc-visual-spinner-string) " ")
                 "")
               (ecc-render-status-line session)
              (mapconcat (lambda (function)
                           (if-let* ((text (condition-case err (funcall function session)
                                             (error (ecc-log (ecc-session-name session)
                                                             "header function %s: %s"
                                                             function
                                                             (error-message-string err))
                                                    nil))))
                               (concat "  ·  " text)
                             ""))
                         ecc-render-header-functions ""))))))

(defun ecc-render-mode-line-state (session)
  "Return the short state of SESSION for a mode line, or nil when idle.
A request waiting for an answer is what the mode line exists to show
\(FR-PERM-4), so it is spelled out with its kind."
  (pcase (if (eq (ecc-session-kind session) 'handoff) 'handoff
           (ecc-session-state session))
    ((or 'idle 'starting) nil)
    ('handoff (propertize "⇄ terminal" 'face 'ecc-pending-face))
    ('exited (propertize "✗ exited" 'face 'ecc-error-face))
    ('compacting (propertize "⟲ compacting" 'face 'ecc-pending-face))
    ((or 'waiting-permission 'waiting-question 'waiting-plan)
     (let ((n (length (ecc-session-pending session))))
       (propertize (format "⚠ %s%s"
                           (pcase (ecc-session-state session)
                             ('waiting-question "question")
                             ('waiting-plan "plan")
                             (_ "permission"))
                           (if (> n 1) (format " ×%d" n) ""))
                   'face 'ecc-pending-face)))
    (_ (propertize "● running" 'face 'ecc-pending-face))))

(defun ecc-render-mode-line-process ()
  "Return the `mode-line-process' text of the session buffer."
  (when-let* ((session ecc-render--session)
              (state (ecc-render-mode-line-state session)))
    (concat " [" state "]")))

(defun ecc-render--on-progress (session &rest _)
  "Refresh the state line of SESSION."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (force-mode-line-update)))))

;;;; Visibility (plan section 9, item 6)

(defun ecc-render--visibility-of (section)
  "Return how SECTION was left folded, for `magit-section-set-visibility-hook'."
  (let ((remembered (and ecc-render--visibility-cache
                         (gethash (oref section value)
                                  ecc-render--visibility-cache 'unset))))
    (pcase remembered
      ('unset nil)
      ('nil 'show)
      (_ 'hide))))

(defun ecc-render--remember-visibility (section)
  "Record how SECTION and its children are folded."
  (when section
    (when-let* ((value (oref section value)))
      (puthash value (oref section hidden) ecc-render--visibility-cache))
    (dolist (child (oref section children))
      (ecc-render--remember-visibility child))))

(defun ecc-render--apply-visibility (section)
  "Fold or unfold SECTION and its children as their slots say."
  (if (oref section hidden)
      (magit-section-hide section)
    (magit-section-show section)))

;;;; Drawing

(defun ecc-render--live-sections ()
  "Return the top level sections that live inside the live region."
  (let ((pos (marker-position ecc-render--live-start)))
    (seq-filter (lambda (section) (>= (marker-position (oref section start)) pos))
                (oref magit-root-section children))))

(defun ecc-render--windows-at-end ()
  "Return the windows of this buffer whose point is inside the live region."
  (let ((pos (marker-position ecc-render--live-start)))
    (seq-filter (lambda (window) (>= (window-point window) pos))
                (get-buffer-window-list (current-buffer) nil t))))

(defun ecc-render--freeze (session)
  "Move the live region past every turn of SESSION that is finished."
  (let ((turns (seq-drop (ecc-session-turns session) ecc-render--frozen))
        (done t))
    (while (and turns done)
      (let* ((turn (car turns))
             (section (and (ecc-turn-end-time turn)
                           (ecc-render--turn-section (ecc-turn-id turn)))))
        (if (null section)
            (setq done nil)
          (set-marker ecc-render--live-start (marker-position (oref section end)))
          (cl-incf ecc-render--frozen)
          (setq turns (cdr turns)))))))

(defun ecc-render--turn-section (id)
  "Return the section of the turn called ID, or nil."
  (seq-find (lambda (section)
              (and (cl-typep section 'ecc-section-turn)
                   (equal (oref section value) id)))
            (oref magit-root-section children)))

(defun ecc-render-turn-sections ()
  "Return the turn sections of this buffer, in order."
  (seq-filter (lambda (section) (cl-typep section 'ecc-section-turn))
              (oref magit-root-section children)))

(defun ecc-render-node-section (id)
  "Return the section of this buffer drawn for the node ID, or nil."
  (let (found)
    (magit-map-sections (lambda (section)
                          (when (and (null found) (equal (oref section value) id))
                            (setq found section))))
    found))

(defun ecc-render-goto-node (session node)
  "Move point in the buffer of SESSION to NODE and unfold it.
The buffer is drawn first when a redraw is waiting.  Returns the
section, or nil when the node is not drawn."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (ecc-render-flush session)
      (with-current-buffer buffer
        (when-let* ((section (ecc-render-node-section (ecc-node-id node))))
          (magit-section-goto section)
          (magit-section-show section)
          section)))))

(defun ecc-render--reset-deltas ()
  "Forget the streamed text waiting to be drawn; a redraw drew it."
  (setq ecc-render--pending-deltas nil
        ecc-render--delta-count 0)
  (when ecc-render--delta-timer
    (cancel-timer ecc-render--delta-timer)
    (setq ecc-render--delta-timer nil)))

(defun ecc-render--windows-following ()
  "Return the windows of this buffer that are watching the end.
Before anything has been drawn there is no live region yet, and a
buffer that has just been made is at its end, so every window counts."
  (if (and ecc-render--live-start (marker-buffer ecc-render--live-start))
      (ecc-render--windows-at-end)
    (get-buffer-window-list (current-buffer) nil t)))

(defun ecc-render-refresh (session)
  "Draw the whole buffer of SESSION from scratch."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        ;; Erasing the buffer drags every window point back to the top,
        ;; and a window that is no longer at the end stops being followed
        ;; (`ecc-render-update'), so a session drawn again after a
        ;; resume or a history page would never scroll to a new turn
        ;; again.  Which windows were watching the end is therefore
        ;; remembered before the buffer is touched.
        (let ((following (and ecc-render-follow (ecc-render--windows-following))))
          (unless ecc-render--visibility-cache
            (setq ecc-render--visibility-cache (make-hash-table :test #'equal)))
          (unless ecc-render--node-sections
            (setq ecc-render--node-sections (make-hash-table :test #'equal)))
          (when (and magit-root-section (marker-buffer (oref magit-root-section start)))
            (ecc-render--remember-visibility magit-root-section))
          (with-silent-modifications
            (erase-buffer)
            (clrhash ecc-render--node-sections)
            (ecc-render--reset-deltas)
            (setq ecc-render--frozen 0)
            (unless ecc-render--live-start
              (setq ecc-render--live-start (make-marker)))
            (unless ecc-render--top-end
              (setq ecc-render--top-end (make-marker)))
            (magit-insert-section (ecc-section-root "root")
              (ecc-render--insert-top session)
              (set-marker ecc-render--top-end (point))
              (set-marker ecc-render--live-start (point))
              (ecc-render--insert-live session))
            (set-marker-insertion-type (oref magit-root-section end) t)
            (magit-section-show magit-root-section)
            (ecc-render--freeze session))
          (ecc-render--apply-effects)
          (ecc-render--update-spinner session)
          (goto-char (point-max))
          (dolist (window following)
            (when (window-live-p window)
              (set-window-point window (point-max)))))))))

(defun ecc-render-update (session)
  "Redraw the top and the live region of SESSION."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (or (null magit-root-section)
                (null ecc-render--live-start)
                (null ecc-render--top-end)
                (null (marker-buffer ecc-render--live-start)))
            (ecc-render-refresh session)
          (let ((follow (and ecc-render-follow (ecc-render--windows-at-end)))
                (at-end (>= (point) (marker-position ecc-render--live-start))))
            (with-silent-modifications
              (ecc-render--update-top session)
              (dolist (section (ecc-render--live-sections))
                (ecc-render--remember-visibility section))
              (clrhash ecc-render--node-sections)
              (ecc-render--reset-deltas)
              (let ((pos (marker-position ecc-render--live-start)))
                (setf (oref magit-root-section children)
                      (seq-remove (lambda (section)
                                    (>= (marker-position (oref section start)) pos))
                                  (oref magit-root-section children)))
                (delete-region pos (point-max))
                (goto-char (point-max))
                (let ((magit-insert-section--parent magit-root-section))
                  (ecc-render--insert-live session))
                (set-marker ecc-render--live-start pos))
              (set-marker (oref magit-root-section end) (point-max))
              (mapc #'ecc-render--apply-visibility (ecc-render--live-sections))
              (ecc-render--freeze session))
            (ecc-render--apply-effects)
            (ecc-render--update-spinner session)
            (when at-end (goto-char (point-max)))
            (dolist (window follow)
              (set-window-point window (point-max)))
            (when ecc-render--flash-pending
              (setq ecc-render--flash-pending nil)
              (ecc-visual-flash-region (marker-position ecc-render--live-start)
                                       (point-max)))
            (force-mode-line-update)))))))

(defun ecc-render--update-spinner (session)
  "Turn the spinner of the current buffer while SESSION has work to do."
  (if (memq (ecc-session-state session) '(starting running compacting))
      (ecc-visual-spinner-start (current-buffer))
    (ecc-visual-spinner-stop (current-buffer))))

(defun ecc-render-schedule (session)
  "Ask for a redraw of SESSION, gathering changes for a moment first."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless ecc-render--timer
          (setq ecc-render--timer
                (run-at-time ecc-render-debounce nil
                             #'ecc-render--timer-fired buffer session)))))))

(defun ecc-render--timer-fired (buffer session)
  "Redraw SESSION in BUFFER now."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ecc-render--timer nil))
    (ecc-render-update session)))

(defun ecc-render-flush (session)
  "Redraw SESSION at once, cancelling any pending debounce.
Tests and interactive commands use this instead of waiting."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when ecc-render--timer
          (cancel-timer ecc-render--timer)
          (setq ecc-render--timer nil)))
      (ecc-render-update session))))

;;;; Streaming (FR-OUT-4, plan section 5.2, item 4)

(defun ecc-render--replace-heading (section string)
  "Replace the heading line of SECTION with STRING, keeping its markers."
  (let* ((start (marker-position (oref section start)))
         (content (oref section content))
         (end (and content (1- (marker-position content)))))
    (when (and end (> end start))
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert (propertize string 'magit-section section))
        (set-marker (oref section start) start)))))

(defun ecc-render--append-delta (node text)
  "Append the streamed TEXT to NODE in the current buffer.
Text nodes grow at their end marker; a tool node only updates its
heading, because its body starts collapsed anyway."
  (when-let* ((entry (gethash (ecc-node-id node) ecc-render--node-sections)))
    (let ((section (car entry))
          (depth (cdr entry)))
      (pcase (ecc-node-type node)
        ((or 'text 'thinking)
         (let ((marker (ecc-node-marker-end node)))
           (when (and (markerp marker) (eq (marker-buffer marker) (current-buffer)))
             (save-excursion
               (goto-char marker)
               (insert (propertize
                        (ecc-render--stream-string
                         text (ecc-render--pad (if (eq (ecc-node-type node) 'thinking)
                                                   (1+ depth)
                                                 depth)))
                        'face (if (eq (ecc-node-type node) 'thinking)
                                  'ecc-thinking-face
                                'ecc-assistant-face)
                        'magit-section section))
               (set-marker marker (point))))))
        ((or 'tool 'agent)
         (ecc-render--replace-heading section (ecc-render--tool-heading node depth)))))))

(defun ecc-render--flush-deltas ()
  "Draw the streamed text that is waiting in the current buffer."
  (when ecc-render--delta-timer
    (cancel-timer ecc-render--delta-timer)
    (setq ecc-render--delta-timer nil))
  (let ((pending (nreverse ecc-render--pending-deltas))
        (follow (and ecc-render-follow (ecc-render--windows-at-end)))
        (at-end (>= (point) (marker-position ecc-render--live-start))))
    (setq ecc-render--pending-deltas nil
          ecc-render--delta-count 0)
    (with-silent-modifications
      (dolist (pair pending)
        (ecc-render--append-delta (car pair) (cdr pair))))
    (when at-end (goto-char (point-max)))
    (dolist (window follow)
      (set-window-point window (point-max)))
    (force-mode-line-update)))

(defun ecc-render--delta-timer-fired (buffer)
  "Draw the pending deltas of BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ecc-render--flush-deltas))))

(defun ecc-render--on-delta (session node text)
  "Queue the streamed TEXT of NODE of SESSION for drawing (FR-OUT-10)."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((cell (assq node ecc-render--pending-deltas)))
          (if cell
              (setcdr cell (concat (cdr cell) text))
            (push (cons node text) ecc-render--pending-deltas)))
        (cl-incf ecc-render--delta-count)
        (pcase ecc-stream-throttle-method
          ('count
           (when (>= ecc-render--delta-count (max 1 ecc-stream-throttle-count))
             (ecc-render--flush-deltas)))
          (_
           (if (<= ecc-stream-throttle 0)
               (ecc-render--flush-deltas)
             (unless ecc-render--delta-timer
               (setq ecc-render--delta-timer
                     (run-at-time ecc-stream-throttle nil
                                  #'ecc-render--delta-timer-fired buffer))))))))))

(defun ecc-render-flush-deltas (session)
  "Draw the streamed text of SESSION that is waiting, at once."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ecc-render--flush-deltas)))))

;;;; Other buffers

(defun ecc-render-draw-nodes (session buffer heading nodes)
  "Draw NODES of SESSION into BUFFER under HEADING as a fresh tree.
Used for the transcript of an agent (FR-OUT-9).  BUFFER must be in
`ecc-session-mode' or a mode derived from `magit-section-mode'."
  (with-current-buffer buffer
    (setq ecc-render--session session)
    (unless ecc-render--node-sections
      (setq ecc-render--node-sections (make-hash-table :test #'equal)))
    (unless ecc-render--visibility-cache
      (setq ecc-render--visibility-cache (make-hash-table :test #'equal)))
    (unless ecc-render--live-start
      (setq ecc-render--live-start (make-marker)))
    (with-silent-modifications
      (erase-buffer)
      (clrhash ecc-render--node-sections)
      (magit-insert-section (ecc-section-root "root")
        (insert (propertize heading 'face 'ecc-heading-face) "\n\n")
        (set-marker ecc-render--live-start (point))
        (dolist (node nodes)
          (ecc-render--insert-node session node 0)))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;;; Setup

(defun ecc-render-setup (session buffer)
  "Prepare BUFFER to show SESSION and draw it."
  (with-current-buffer buffer
    (setq ecc-render--session session
          ecc-render--visibility-cache (make-hash-table :test #'equal)
          ecc-render--node-sections (make-hash-table :test #'equal)
          ecc-render--frozen 0
          ecc-render--top-end (make-marker)
          ecc-render--live-start (make-marker))
    (setq header-line-format '(:eval (ecc-render-header-line)))
    (add-hook 'magit-section-set-visibility-hook #'ecc-render--visibility-of nil t)
    (ecc-render-refresh session)))

;;;; Wiring (the model announces, the renderer listens)

(defun ecc-render--on-change (session &rest _)
  "Schedule a redraw of SESSION."
  (ecc-render-schedule session))

(dolist (hook '(ecc-node-added-hook
                ecc-node-updated-hook
                ecc-request-added-hook
                ecc-request-resolved-hook
                ecc-turn-started-hook
                ecc-turn-finished-hook
                ecc-session-state-changed-hook
                ecc-session-init-hook
                ecc-status-hook
                ecc-usage-hook
                ecc-compact-hook
                ecc-files-updated-hook
                ecc-tasks-updated-hook))
  (add-hook hook #'ecc-render--on-change))

(defun ecc-render--on-turn-finished (session &rest _)
  "Ask for a flash of the live region of SESSION after the next redraw."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq ecc-render--flash-pending t)))))

(add-hook 'ecc-turn-finished-hook #'ecc-render--on-turn-finished)
(add-hook 'ecc-stream-delta-hook #'ecc-render--on-delta)
(add-hook 'ecc-progress-hook #'ecc-render--on-progress)

(provide 'ecc-render)

;;; ecc-render.el ends here
