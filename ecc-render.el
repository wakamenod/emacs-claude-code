;;; ecc-render.el --- Drawing the transcript of the ecc client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Draws the model of `ecc-model' into the session buffer.  Section 5 of
;; IMPLEMENTATION_PLAN.md as revised by docs/phase9-ui-redesign.md: the
;; transcript and the prompt share one buffer, so the tree is drawn with
;; text properties and overlays of its own rather than with magit-section
;; (phase 9b).
;;
;; The buffer is laid out as a top region (the header, the Files and the
;; Tasks summaries), a newline that anchors it, the turns that are
;; finished, a live region holding the current turn, the state line and
;; the separator, and after that the prompt region, which is the only
;; part of the buffer the user may edit.  Finished turns are never
;; touched again: a redraw deletes the live region and builds it anew,
;; and the top region is replaced in place, which keeps the cost
;; proportional to the current turn rather than to the length of the
;; conversation (plan section 5.2).  The prompt region lies after the
;; marker `ecc-render--prompt-start', and no redraw deletes past it, so a
;; draft survives whatever the session does meanwhile (FR-UI-2).
;;
;; Every node is drawn as a heading line and a body.  The heading carries
;; the text properties `ecc-node' (the id), `ecc-depth' and
;; `ecc-heading', the body only the first two; `ecc-render--nodes' maps
;; each id to the markers that bound it.  Folding is an overlay with the
;; `invisible' property over the body (FR-OUT-3), and the keys of the
;; transcript arrive through the `keymap' property, so that the major
;; mode keymap is free for typing in the prompt region.
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
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-markdown)
(require 'ecc-diff)
(require 'ecc-visual)

(declare-function ecc-history-load-more "ecc-history" (session &optional n-turns))

;; The keymaps belong to `ecc-chat', which sits above this module; they
;; are looked up by name when the text is drawn.
(defvar ecc-chat-transcript-map)
(defvar ecc-chat-button-map)
(defvar ecc-request-section-map)
(defvar ecc-file-section-map)

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

(defcustom ecc-render-show-result-line t
  "Non-nil closes every finished turn with what it cost and how long it took.
The line sits at the right edge under the answer; nil leaves a turn to
end with its last message."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-render-follow t
  "Non-nil scrolls to the end of the buffer while it is at the end.
The prompt region counts as the end: a window whose point is there,
or in the live region above it, keeps looking at what arrives."
  :type 'boolean
  :group 'ecc)

(defface ecc-separator-face
  '((t :inherit shadow :underline t))
  "Face of the line between the transcript and the prompt region."
  :group 'ecc)

(defconst ecc-render-user-mark "〉 "
  "What every line of a user prompt is prefixed with.
A turn read back from a recording is drawn with the same mark as one
this session sent, so that the two do not read as different things.")

(defconst ecc-render-block-types
  '(tool agent thinking permission question plan system unknown command)
  "Node types the block movement commands stop at (FR-OUT-14 b).
A file row of the Files section is a block too.")

(defvar ecc-render-after-draw-hook nil
  "Functions run in a session buffer after it was drawn or redrawn.
The prompt region is in place again by then; `ecc-chat' checks its
placeholder from here.")

;;;; Buffer state

(defvar-local ecc-render--session nil
  "The session drawn in this buffer.")

(defvar-local ecc-render--live-start nil
  "Marker where the live region starts, after the last frozen turn.")

(defvar-local ecc-render--top-end nil
  "Marker where the top region ends: the newline that anchors it.
The turns start after that newline, so that redrawing the top region
never inserts at the position of a marker the turns own.")

(defvar-local ecc-render--prompt-start nil
  "Marker where the prompt region starts, or nil in a buffer without one.
Everything before it is drawn by this module and is read-only; what
follows is the draft the user is writing (FR-UI-2).")

(defvar-local ecc-render--frozen 0
  "Number of turns that are finished and will not be drawn again.")

(defvar-local ecc-render--visibility-cache nil
  "Hash mapping a node id to whether the user left it collapsed.
Only the nodes the user folded or unfolded are in it; the others
follow `ecc-render-hidden-types' (plan section 9, item 6).")

(defvar-local ecc-render--timer nil
  "Debounce timer of this buffer, or nil.")

(defvar-local ecc-render--nodes nil
  "Hash mapping a node id to (START END DEPTH FOLDABLE BLOCK).
START and END are markers around the whole node, children included;
FOLDABLE says whether it has a heading line a body can fold under, and
BLOCK whether the block movement commands stop at it.  An entry is
dropped as soon as the region it lies in is redrawn.")

(defvar-local ecc-render--drawn nil
  "Ids of the nodes inserted since the region being drawn was begun.
Their fold state is applied once the drawing is over.")

(defvar-local ecc-render--flash-pending nil
  "Non-nil when the live region should flash after the next redraw.
Set when a turn finishes, so that the eye is drawn to the answer that
has just arrived (FR-OUT-11 e).")

(defvar-local ecc-render--effect-targets nil
  "Node ids noted for a visual effect while the live region was drawn.
Each entry is (KIND . ID); see `ecc-render--apply-effects'.")

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

;;;; Marking the text: nodes, headings and keys

(defun ecc-render--map (name)
  "Return the keymap called NAME when `ecc-chat' has defined it, else nil."
  (and (boundp name) (symbol-value name)))

(defun ecc-render--mark (start end id depth &optional keymap)
  "Give the text from START to END to the node ID at DEPTH.
KEYMAP is the keymap the text answers to, the transcript keymap by
default.  The children of a node are marked before the node is, and
never inside a call to this, so nothing is overwritten."
  (add-text-properties
   start end
   (list 'ecc-node id 'ecc-depth depth
         'keymap (or keymap (ecc-render--map 'ecc-chat-transcript-map)))))

(defun ecc-render--mark-heading (start id)
  "Mark the line starting at START as the heading of the node ID.
The property stops before the newline, so that two headings in a row
are two runs of it and the movement commands stop at each."
  (save-excursion
    (goto-char start)
    (let ((end (line-end-position)))
      (when (> end start)
        (put-text-property start end 'ecc-heading id)))))

(defun ecc-render--seal (start end)
  "Make the text from START to END read-only.
Nothing can be typed in front of the first character of the buffer
either: a property is not front-sticky unless it is made so."
  (when (> end start)
    (add-text-properties start end '(read-only t))
    (when (= start (point-min))
      (put-text-property start (1+ start) 'front-sticky t))))

(defun ecc-render--register (id start end depth &optional foldable block)
  "Record that the node ID spans START to END at DEPTH.
FOLDABLE and BLOCK are the flags of `ecc-render--nodes'.  START and
END may be positions; markers are made of them."
  (let ((old (gethash id ecc-render--nodes)))
    (when old
      (set-marker (nth 0 old) nil)
      (set-marker (nth 1 old) nil)))
  ;; A heading with nothing under it has nothing to fold.
  (when foldable
    (setq foldable (< (save-excursion (goto-char start) (line-end-position))
                      (1- end))))
  (puthash id (list (copy-marker start) (copy-marker end) depth
                    (and foldable t) (and block t))
           ecc-render--nodes)
  (push id ecc-render--drawn)
  id)

(defun ecc-render--drop-from (position)
  "Forget every node whose start lies at or after POSITION.
Their text is about to be deleted, so the markers are let go of."
  (let (dead)
    (maphash (lambda (id entry)
               (let ((start (marker-position (nth 0 entry))))
                 (when (or (null start) (>= start position))
                   (push id dead))))
             ecc-render--nodes)
    (dolist (id dead)
      (let ((entry (gethash id ecc-render--nodes)))
        (set-marker (nth 0 entry) nil)
        (set-marker (nth 1 entry) nil)
        (remhash id ecc-render--nodes)))))

(defun ecc-render--drop-before (position)
  "Forget every node whose start lies before POSITION."
  (let (dead)
    (maphash (lambda (id entry)
               (let ((start (marker-position (nth 0 entry))))
                 (when (or (null start) (< start position))
                   (push id dead))))
             ecc-render--nodes)
    (dolist (id dead)
      (let ((entry (gethash id ecc-render--nodes)))
        (set-marker (nth 0 entry) nil)
        (set-marker (nth 1 entry) nil)
        (remhash id ecc-render--nodes)))))

(defun ecc-render-node-entry (id)
  "Return the entry of `ecc-render--nodes' for ID, or nil."
  (and ecc-render--nodes
       (let ((entry (gethash id ecc-render--nodes)))
         (and entry (marker-position (nth 0 entry)) entry))))

(defun ecc-render-node-bounds (id)
  "Return (START . END) of the node ID in this buffer, or nil."
  (when-let* ((entry (ecc-render-node-entry id)))
    (cons (marker-position (nth 0 entry)) (marker-position (nth 1 entry)))))

(defun ecc-render-node-depth (id)
  "Return the depth the node ID was drawn at, or nil."
  (nth 2 (ecc-render-node-entry id)))

(defun ecc-render-node-foldable-p (id)
  "Return non-nil when the node ID has a body that can fold under its heading."
  (and (nth 3 (ecc-render-node-entry id)) t))

(defun ecc-render-node-ids (predicate)
  "Return the ids of the drawn nodes satisfying PREDICATE, in buffer order.
PREDICATE is called with the id and its entry."
  (let (found)
    (maphash (lambda (id entry)
               (when (and (marker-position (nth 0 entry))
                          (funcall predicate id entry))
                 (push (cons (marker-position (nth 0 entry)) id) found)))
             ecc-render--nodes)
    (mapcar #'cdr (sort found (lambda (a b) (< (car a) (car b)))))))

(defun ecc-render-block-ids ()
  "Return the ids of the blocks the movement commands stop at, in order."
  (ecc-render-node-ids (lambda (_id entry) (nth 4 entry))))

(defun ecc-render-turn-ids ()
  "Return the ids of the turns drawn in this buffer, in order."
  (let ((turns (and ecc-render--session
                    (mapcar #'ecc-turn-id (ecc-session-turns ecc-render--session)))))
    (ecc-render-node-ids (lambda (id _entry) (member id turns)))))

;;;; Folding (FR-OUT-3, plan section 9, item 6)

(defun ecc-render--fold-overlay (id)
  "Return the fold overlay of the node ID, or nil when it is unfolded."
  (when-let* ((bounds (ecc-render-node-bounds id)))
    (seq-find (lambda (overlay) (equal (overlay-get overlay 'ecc-fold) id))
              (overlays-in (car bounds) (cdr bounds)))))

(defun ecc-render-node-hidden-p (id)
  "Return non-nil when the body of the node ID is folded away."
  (and (ecc-render--fold-overlay id) t))

(defun ecc-render--isearch-open (overlay)
  "Unfold the node OVERLAY hides, for `isearch-open-invisible'."
  (ecc-render-show-node (overlay-get overlay 'ecc-fold)))

(defun ecc-render--hide (id)
  "Fold the body of the node ID away, without touching the memory of it.
The overlay starts at the end of the heading line and stops before the
last newline of the node, so that the heading keeps its own line and
shows the ellipsis of `buffer-invisibility-spec'.  It grows with text
appended at its end, which is where a streamed delta lands."
  (when-let* ((bounds (ecc-render-node-bounds id)))
    (unless (ecc-render--fold-overlay id)
      (let ((body-start (save-excursion (goto-char (car bounds)) (line-end-position)))
            (body-end (1- (cdr bounds))))
        (when (> body-end body-start)
          (let ((overlay (make-overlay body-start body-end nil t t)))
            (overlay-put overlay 'invisible 'ecc-fold)
            (overlay-put overlay 'ecc-fold id)
            (overlay-put overlay 'evaporate t)
            (overlay-put overlay 'isearch-open-invisible #'ecc-render--isearch-open)
            overlay))))))

(defun ecc-render--show (id)
  "Unfold the body of the node ID, without touching the memory of it."
  (when-let* ((overlay (ecc-render--fold-overlay id)))
    (delete-overlay overlay)
    t))

(defun ecc-render-hide-node (id)
  "Fold the node ID and remember that it was folded."
  (puthash id t ecc-render--visibility-cache)
  (ecc-render--hide id))

(defun ecc-render-show-node (id)
  "Unfold the node ID and remember that it was unfolded."
  (puthash id nil ecc-render--visibility-cache)
  (ecc-render--show id))

(defun ecc-render-toggle-node (id)
  "Fold or unfold the node ID.  Returns non-nil when it is folded now."
  (if (ecc-render-node-hidden-p id)
      (progn (ecc-render-show-node id) nil)
    (ecc-render-hide-node id)
    t))

(defun ecc-render--default-hidden-p (id)
  "Return non-nil when the node ID starts folded unless told otherwise."
  (cond
   ((equal id "files") t)
   ((string-prefix-p "file:" id) t)
   ((not ecc-render--session) nil)
   (t (let ((node (ecc-model-node ecc-render--session id)))
        (and node
             (memq (ecc-node-type node) ecc-render-hidden-types)
             (not (eq (ecc-model-node-get node 'kind) 'prompt))
             t)))))

(defun ecc-render--wanted-hidden-p (id)
  "Return non-nil when the node ID should be folded now.
What the user did to it wins over the default of its type."
  (let ((remembered (gethash id ecc-render--visibility-cache 'unset)))
    (if (eq remembered 'unset)
        (ecc-render--default-hidden-p id)
      remembered)))

(defun ecc-render--apply-visibility ()
  "Fold the nodes drawn since `ecc-render--drawn' was emptied, as wanted.
The folds are overlays of their own, so their order does not matter."
  (dolist (id ecc-render--drawn)
    (when (and (ecc-render-node-foldable-p id)
               (ecc-render--wanted-hidden-p id))
      (ecc-render--hide id)))
  (setq ecc-render--drawn nil))

;;;; The top region: header, Files, Tasks

(defun ecc-render--header-string (session)
  "Return the header line of SESSION, ending in a newline."
  (concat
   (propertize (or (ecc-session-name session) "?") 'face 'ecc-heading-face)
   (propertize
    (format "  ·  %s  ·  %s  ·  %s  ·  $%.4f\n"
            ;; init only comes with the first turn, so there is
            ;; nothing to say about the model before it.
            (or (alist-get 'model (ecc-session-init session)) "—")
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

(defun ecc-render--insert-file (entry)
  "Insert the row of the file ENTRY and the merged diff of its changes."
  (let ((id (concat "file:" (ecc-file-entry-path entry)))
        (start (point))
        (map (ecc-render--map 'ecc-file-section-map)))
    (insert (ecc-render--file-heading entry) "\n")
    (ecc-render--mark start (point) id 1 map)
    (ecc-render--mark-heading start id)
    (when (ecc-file-entry-hunks entry)
      (let ((body (point)))
        (ecc-render--insert-lines (ecc-render--file-diff entry) "    " 'ecc-dim-face)
        (ecc-render--mark body (point) id 2 map)))
    (ecc-render--register id start (point) 1
                          (and (ecc-file-entry-hunks entry) t) t)))

(defun ecc-render--insert-files (session)
  "Insert the Files section of SESSION, unless there is nothing to list."
  (let ((entries (ecc-model-files session)))
    (when entries
      (let ((start (point)))
        (insert (propertize (format "Files (%d)" (length entries))
                            'face 'ecc-heading-face)
                "\n")
        (ecc-render--mark start (point) "files" 0)
        (ecc-render--mark-heading start "files")
        (dolist (entry entries)
          (ecc-render--insert-file entry))
        (ecc-render--register "files" start (point) 0 t)))))

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
      (let ((start (point)))
        (insert (propertize (format "Tasks (%d/%d)"
                                    (seq-count (lambda (task)
                                                 (equal (ecc-task-status task) "completed"))
                                               tasks)
                                    (length tasks))
                            'face 'ecc-heading-face)
                "\n")
        (ecc-render--mark start (point) "tasks" 0)
        (ecc-render--mark-heading start "tasks")
        (dolist (task tasks)
          (let ((id (concat "task:" (ecc-task-id task)))
                (row (point)))
            (insert (propertize
                     (format "  %s %s" (ecc-render--task-mark (ecc-task-status task))
                             (or (ecc-task-subject task) ""))
                     'face (pcase (ecc-task-status task)
                             ("completed" 'ecc-dim-face)
                             ("in_progress" 'ecc-pending-face)
                             (_ 'default)))
                    "\n")
            (ecc-render--mark row (point) id 1)
            (ecc-render--register id row (point) 1)))
        (ecc-render--register "tasks" start (point) 0 t)))))

(defun ecc-render--insert-history-button (session)
  "Insert the button that reads the page before the first turn of SESSION.
Nothing is inserted when the whole recording has been read, or when
there is none (FR-HIST-1)."
  (when (ecc-render--history-more-p session)
    (let ((start (point)))
      (insert-text-button
       "Load older messages"
       'action (lambda (_button)
                 (require 'ecc-history)
                 (ecc-history-load-more session))
       'follow-link t
       'help-echo "Load the previous 50 turns")
      (insert "\n")
      ;; The button's own keys, RET and mouse-2, sit on top of the keys
      ;; of the transcript.
      (ecc-render--mark start (point) "history" 0
                        (or (ecc-render--map 'ecc-chat-button-map)
                            (ecc-render--map 'ecc-chat-transcript-map)))
      (ecc-render--mark-heading start "history")
      (ecc-render--register "history" start (point) 0))))

(defun ecc-render--history-more-p (session)
  "Return non-nil when SESSION has an older page of its recording left.
The paging position is a slot of the session, so this asks no module
above the renderer (plan section 1.3)."
  (let ((offset (ecc-session-history-offset session)))
    (and offset (> offset 0))))

(defun ecc-render--insert-top (session)
  "Insert the header, Files and Tasks of SESSION."
  (let ((start (point)))
    (insert (ecc-render--header-string session))
    (ecc-render--mark start (point) "header" 0)
    (ecc-render--register "header" start (point) 0))
  (ecc-render--insert-files session)
  (ecc-render--insert-tasks session)
  (ecc-render--insert-history-button session))

(defun ecc-render--update-top (session)
  "Redraw the top region of SESSION in place.
The turns below keep their markers and are not drawn again: the
anchoring newline at `ecc-render--top-end' is never deleted, so no
marker of theirs lies in the region that is."
  (let ((start (point-min))
        (end (marker-position ecc-render--top-end)))
    (ecc-render--drop-before end)
    (save-excursion
      (delete-region start end)
      (goto-char start)
      (ecc-render--insert-top session)
      (ecc-render--seal start (point))
      ;; The marker collapsed with the deletion and does not advance
      ;; with text inserted at it, so it is put back by hand.
      (set-marker ecc-render--top-end (point)))
    (ecc-render--apply-visibility)))

;;;; Nodes

(defun ecc-render--skip-p (node)
  "Return non-nil when NODE has nothing worth drawing.
An empty thinking block is all signature and no text."
  (or
   ;; The result message closes the turn, and the turn draws it itself
   ;; as the line that ends it (`ecc-render--insert-turn-end-line'): a
   ;; node of its own here would say the same cost a second time.
   (eq (ecc-node-type node) 'result)
   (and (eq (ecc-node-type node) 'thinking)
        (not (ecc-node-streaming node))
        (string-empty-p (string-trim (or (ecc-model-node-get node 'text) ""))))))

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

(defun ecc-render--node-map (node)
  "Return the keymap the text of NODE answers to."
  (pcase (ecc-node-type node)
    ((or 'permission 'question 'plan)
     (ecc-render--map 'ecc-request-section-map))
    (_ nil)))

(defun ecc-render--insert-owned (node depth thunk)
  "Insert what THUNK inserts and give it to NODE at DEPTH.
The children of NODE are inserted outside any call to this, so that
their own marks stay."
  (let ((start (point)))
    (funcall thunk)
    (ecc-render--mark start (point) (ecc-node-id node) depth
                      (ecc-render--node-map node))
    start))

(defun ecc-render--insert-node (session node depth)
  "Insert NODE of SESSION at DEPTH."
  (unless (ecc-render--skip-p node)
    (let* ((type (ecc-node-type node))
           (id (ecc-node-id node))
           (start (point))
           ;; A quoted prompt is text, not a heading with a body.
           (prompt-p (and (memq type '(system recap))
                          (eq (ecc-model-node-get node 'kind) 'prompt)))
           (foldable (not (or prompt-p (memq type '(text result)))))
           (block (and (not prompt-p) (memq type ecc-render-block-types))))
      (pcase type
        ('text (ecc-render--insert-text node depth))
        ('thinking (ecc-render--insert-thinking node depth))
        ('step (ecc-render--insert-step session node depth))
        ('tool (ecc-render--insert-tool session node depth))
        ('agent (ecc-render--insert-agent session node depth))
        ((or 'permission 'question 'plan) (ecc-render--insert-request node depth))
        ('command (ecc-render--insert-command node depth))
        ((or 'system 'recap) (ecc-render--insert-system node depth))
        (_ (ecc-render--insert-unknown node depth)))
      ;; A node that put nothing in the buffer has no line to mark: the
      ;; line at point would be the draft's.
      (when (> (point) start)
        (ecc-render--mark-heading start id)
        (ecc-render--register id start (point) depth foldable block)
        (ecc-render--note-effect node))
      id)))

(defun ecc-render--note-effect (node)
  "Remember that the heading of NODE deserves a visual effect (FR-OUT-11).
The effects themselves are put on once the redraw is over: an overlay
made now would be deleted with the region it sits in."
  (pcase (ecc-node-type node)
    ((or 'tool 'agent)
     (when (eq (ecc-node-status node) 'running)
       (push (cons 'pulse (ecc-node-id node)) ecc-render--effect-targets)))
    ((or 'permission 'question 'plan)
     (when (eq (ecc-node-status node) 'pending)
       (push (cons 'blink (ecc-node-id node)) ecc-render--effect-targets)))))

(defun ecc-render--apply-effects ()
  "Animate the lines noted while the live region was drawn (FR-OUT-11).
The newest line comes first, so that the limit of
`ecc-visual-max-effects' keeps what is happening now."
  (ecc-visual-clear-effects (current-buffer))
  (dolist (target (nreverse ecc-render--effect-targets))
    (pcase-let ((`(,kind . ,id) target))
      (when-let* ((bounds (ecc-render-node-bounds id)))
        (let* ((start (car bounds))
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
    (ecc-render--insert-owned
     node depth
     (lambda ()
       (if (ecc-node-streaming node)
           (ecc-render--insert-stream-text node (ecc-node-streaming-text node) pad face)
         (ecc-render--insert-lines (ecc-markdown-fontify (ecc-model-node-get node 'text))
                                   pad face))))))

(defun ecc-render--insert-thinking (node depth)
  "Insert the thinking NODE at DEPTH."
  (let ((pad (ecc-render--pad depth)))
    (ecc-render--insert-owned
     node depth
     (lambda ()
       (insert (concat pad (propertize (if (ecc-node-streaming node) "Thinking…" "Thinking")
                                       'face 'ecc-thinking-face))
               "\n")))
    (ecc-render--insert-owned
     node (1+ depth)
     (lambda ()
       (if (ecc-node-streaming node)
           (ecc-render--insert-stream-text node (ecc-node-streaming-text node)
                                           (concat pad "  ") 'ecc-thinking-face)
         (ecc-render--insert-lines (ecc-model-node-get node 'text)
                                   (concat pad "  ") 'ecc-thinking-face))))))

(defun ecc-render--insert-step (session node depth)
  "Insert the step NODE of SESSION at DEPTH."
  (let ((pad (ecc-render--pad depth)))
    (ecc-render--insert-owned
     node depth
     (lambda ()
       (insert (concat pad
                       (propertize
                        (mapconcat (lambda (pair) (format "%s ×%d" (car pair) (cdr pair)))
                                   (ecc-model-tool-counts node) ", ")
                        'face 'ecc-tool-face))
               "\n")))
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
  (ecc-render--insert-owned
   node depth
   (lambda () (insert (ecc-render--tool-heading node depth) "\n")))
  (ecc-render--insert-owned
   node (1+ depth)
   (lambda () (ecc-render--insert-tool-body node (concat (ecc-render--pad depth) "  "))))
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
    (ecc-render--insert-owned
     node depth
     (lambda () (insert (ecc-render--agent-heading node depth) "\n")))
    (dolist (child (ecc-node-children node))
      (ecc-render--insert-node session child (1+ depth)))
    (ecc-render--insert-owned
     node (1+ depth)
     (lambda ()
       (pcase (ecc-node-status node)
         ('running (insert (propertize (concat body "…") 'face 'ecc-dim-face) "\n"))
         (_ (when (ecc-model-node-get node 'result)
              (ecc-render--insert-lines
               (ecc-render--clip (ecc-render--result-text
                                  (ecc-model-node-get node 'result))
                                 ecc-render-result-max-lines)
               (concat body "→ ")
               (if (eq (ecc-node-status node) 'error) 'ecc-error-face 'ecc-dim-face)))))))))

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
    (ecc-render--insert-owned
     node depth
     (lambda () (insert (concat pad (ecc-render--request-heading node)) "\n")))
    (ecc-render--insert-owned
     node (1+ depth)
     (lambda ()
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
        (t (ecc-render--insert-input (ecc-request-input request) body)))))))

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

(defun ecc-render--insert-command (node depth)
  "Insert the local command NODE at DEPTH (FR-HIST-2).
The command is drawn the way the user typed it, and what it printed
follows in the dim face of something the CLI said rather than the
model."
  (let ((pad (ecc-render--pad depth))
        (name (or (ecc-model-node-get node 'name) "?"))
        (args (ecc-model-node-get node 'args))
        (output (ecc-model-node-get node 'output)))
    (ecc-render--insert-owned
     node depth
     (lambda ()
       (insert (concat pad (propertize (concat ecc-render-user-mark name
                                               (if args (concat " " args) ""))
                                       'face 'ecc-user-face))
               "\n")))
    (when (and (stringp output) (not (string-empty-p (string-trim output))))
      (ecc-render--insert-owned
       node (1+ depth)
       (lambda () (ecc-render--insert-lines output (concat pad "  ") 'ecc-dim-face))))))

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
        (ecc-render--insert-owned
         node depth
         (lambda ()
           (ecc-render--insert-lines (ecc-model-node-get node 'text)
                                     (concat pad ecc-render-user-mark)
                                     'ecc-user-face)))
      (ecc-render--insert-owned
       node depth
       (lambda ()
         (insert (concat pad (propertize (ecc-render--one-line
                                          (ecc-render--system-heading node))
                                         'face 'ecc-dim-face))
                 "\n")))
      (when-let* ((message (ecc-model-node-get node 'message)))
        (ecc-render--insert-owned
         node (1+ depth)
         (lambda ()
           (ecc-render--insert-lines (ecc--truncate (format "%S" message) 400)
                                     (concat pad "  ") 'ecc-dim-face)))))))

(defun ecc-render--insert-unknown (node depth)
  "Insert the unknown NODE at DEPTH (FR-OUT-1)."
  (let* ((pad (ecc-render--pad depth))
         (message (or (ecc-model-node-get node 'message)
                      (ecc-model-node-get node 'block)))
         (reason (ecc-model-node-get node 'reason)))
    (ecc-render--insert-owned
     node depth
     (lambda ()
       (insert (concat pad (propertize (format "unknown: %s%s"
                                               (or (alist-get 'type message) "?")
                                               (if reason (format " (%s)" reason) ""))
                                       'face 'ecc-error-face))
               "\n")))
    (ecc-render--insert-owned
     node (1+ depth)
     (lambda ()
       (ecc-render--insert-lines (ecc--truncate (format "%S" message) 2000)
                                 (concat pad "  ") 'ecc-dim-face)))))

;;;; Turns

(defun ecc-render--turn-end-mark (turn)
  "Return how TURN ended when it did not end normally, else nil."
  (when-let* ((result (ecc-turn-result turn))
              (subtype (alist-get 'subtype result)))
    (unless (equal subtype "success")
      (propertize (format "✗ %s" subtype) 'face 'ecc-error-face))))

(defun ecc-render--insert-turn-end-line (turn)
  "Close TURN with what it cost and how long it took.
The figures are held at the right edge by a stretched space; the
property that stretches it sits on that space alone, because a display
property over the figures themselves would show a blank in their
place.  An end that was not a plain one is named on the left.  Nothing
is drawn while the turn is still running."
  (when (and ecc-render-show-result-line (ecc-turn-end-time turn))
    (let* ((duration (ecc-model-turn-duration turn))
           (cost (ecc-turn-cost turn))
           (left (ecc-render--turn-end-mark turn))
           ;; A turn read back from a recording has no result message,
           ;; so what it cost is not known (FR-HIST-1).
           (right (cond ((and duration cost)
                         (format "%.1fs · $%.4f" duration cost))
                        (cost (format "$%.4f" cost))
                        (duration (format "%.1fs" duration)))))
      (when (or left right)
        (when left (insert left))
        (when right
          (insert (propertize
                   " " 'display
                   (list 'space :align-to
                         (list '- 'right (1+ (string-width right)))))
                  (propertize right 'face 'ecc-dim-face)))
        (insert "\n")))))

(defun ecc-render--insert-turn (session turn)
  "Insert TURN of SESSION.
No heading line of its own is drawn any more (FR-OUT-2 as revised by
the phase 9 redesign): the band the prompt is drawn in is what parts
one turn from the next, and it carries the heading of the turn, so
that the movement commands stop once per turn rather than twice."
  (let ((id (ecc-turn-id turn))
        (start (point)))
    (let ((prompt (ecc-turn-prompt turn)))
      (if prompt
          (progn
            ;; The prompt carries fenced blocks of its own: the quoted
            ;; region and the context Emacs attached (FR-CTX-1,
            ;; FR-INP-8), which are worth the same colouring as the
            ;; reply (FR-OUT-15).
            (ecc-render--insert-lines (ecc-markdown-fontify prompt)
                                      ecc-render-user-mark 'ecc-user-face)
            ;; The band stands at the depth of the turn, not of the
            ;; turn's children: it is the heading of the turn, and the
            ;; movement commands lean on that to tell a turn's children
            ;; from what lies outside it.
            (let ((prompt-id (concat id "/prompt")))
              (ecc-render--mark start (point) prompt-id 0)
              (ecc-render--register prompt-id start (point) 0)))
        ;; A turn resumed from a recording has no prompt of its own, but
        ;; it still needs the band that parts it from the turn before.
        (insert (propertize (concat ecc-render-user-mark "(resumed)")
                            'face 'ecc-dim-face)
                "\n")
        (ecc-render--mark start (point) id 0))
      (ecc-render--mark-heading start id))
    (dolist (child (ecc-turn-children turn))
      (ecc-render--insert-node session child 1))
    (ecc-render--insert-turn-end-line turn)
    ;; The turn spans all of that, but none of it is marked again: the
    ;; children carry their own `ecc-node' and `keymap', and marking
    ;; over them would take both away (see `ecc-render--mark').
    (ecc-render--register id start (point) 0 t)))

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

(defun ecc-render--insert-separator ()
  "Insert the line that parts the transcript from the prompt region.
One stretched space carries the rule, so that it spans whatever width
the window has."
  (let ((start (point)))
    (insert (propertize " " 'display '(space :align-to right)
                        'face 'ecc-separator-face)
            "\n")
    (ecc-render--mark start (point) "separator" 0)
    ;; A character typed right after the newline, which is where the
    ;; prompt region begins, must inherit neither the read-only property
    ;; nor the keymap of the transcript.
    (put-text-property (1- (point)) (point) 'rear-nonsticky t)))

(defun ecc-render--insert-live (session)
  "Insert the turns of SESSION that are not frozen yet, then the end.
The end is the state line, whatever `ecc-render-tail-functions' add,
and the separator before the prompt region."
  (dolist (turn (seq-drop (ecc-session-turns session) ecc-render--frozen))
    (ecc-render--insert-turn session turn))
  (when-let* ((lines (ecc-render--tail-lines session)))
    (let ((start (point)))
      (dolist (line lines)
        (insert line "\n"))
      (ecc-render--mark start (point) "tail" 0)
      (ecc-render--register "tail" start (point) 0)))
  (ecc-render--insert-separator))

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

;;;; The prompt region and the windows watching the end

(defun ecc-render-prompt-start ()
  "Return the position where the prompt region of this buffer starts, or nil."
  (and ecc-render--prompt-start
       (marker-buffer ecc-render--prompt-start)
       (marker-position ecc-render--prompt-start)))

(defun ecc-render--draw-limit ()
  "Return the position the drawn part of this buffer ends at."
  (or (ecc-render-prompt-start) (point-max)))

(defun ecc-render--following-p (position)
  "Return non-nil when POSITION is watching the end of the transcript.
That is anywhere from the start of the live region on, the prompt
region included."
  (and ecc-render--live-start
       (marker-position ecc-render--live-start)
       (>= position (marker-position ecc-render--live-start))))

(defun ecc-render--prompt-offset (position)
  "Return how far into the prompt region POSITION lies, or nil outside it."
  (when-let* ((start (ecc-render-prompt-start)))
    (and (>= position start) (- position start))))

(defun ecc-render--note-points ()
  "Return where point, the window points and the prompt region stand.
The value is what `ecc-render--restore-points' takes.
Before anything has been drawn there is no live region yet, and a
buffer that has just been made is at its end, so every window counts
as following."
  (let ((fresh (not (and ecc-render--live-start
                         (marker-buffer ecc-render--live-start)))))
    (list :prompt (ecc-render-prompt-start)
          :point (list (ecc-render--prompt-offset (point))
                       (or fresh (ecc-render--following-p (point))))
          :windows (mapcar (lambda (window)
                             (let ((position (window-point window)))
                               (list window
                                     (ecc-render--prompt-offset position)
                                     (or fresh (ecc-render--following-p position)))))
                           (get-buffer-window-list (current-buffer) nil t)))))

(defun ecc-render--restore-points (noted)
  "Put point and the window points back where NOTED says they were.
A point that was in the prompt region goes back to the same place in
it; one that was watching the end is put at the start of the prompt
region when `ecc-render-follow' is on, and left alone otherwise.  The
undo history of the draft is moved along with it."
  (let ((start (ecc-render--draw-limit))
        (before (plist-get noted :prompt)))
    (when (and before (ecc-render-prompt-start))
      (ecc-render--shift-undo (- (ecc-render-prompt-start) before)))
    (pcase-let ((`(,offset ,following) (plist-get noted :point)))
      (cond (offset (goto-char (min (point-max) (+ start offset))))
            ((and following ecc-render-follow) (goto-char start))))
    (dolist (entry (plist-get noted :windows))
      (pcase-let ((`(,window ,offset ,following) entry))
        (when (window-live-p window)
          (cond (offset (set-window-point window (min (point-max) (+ start offset))))
                ((and following ecc-render-follow) (set-window-point window start))))))))

(defun ecc-render--shift-undo (delta &optional from)
  "Move the positions in the undo history of this buffer by DELTA.
Only positions at or after FROM move; FROM defaults to the start of
the buffer.  Everything the user can undo lies in the prompt region,
and what the renderer does is kept out of the history; so when the
transcript above the region grows or shrinks, the positions the
history remembers are stale by exactly DELTA (FR-UI-2).  `ecc-chat'
uses the same for the placeholder it puts in and takes out silently."
  (when (and (consp buffer-undo-list) (/= delta 0))
    (let ((from (or from (point-min))))
      (setq buffer-undo-list
            (mapcar (lambda (entry) (ecc-render--shift-undo-entry entry delta from))
                    buffer-undo-list)))))

(defun ecc-render--shift-undo-entry (entry delta from)
  "Return the undo ENTRY with its positions at or after FROM moved by DELTA."
  (let ((shift (lambda (x) (if (>= x from) (+ x delta) x))))
    (pcase entry
      ((pred integerp) (funcall shift entry))
      (`(,(and beg (pred integerp)) . ,(and end (pred integerp)))
       (cons (funcall shift beg) (funcall shift end)))
      (`(,(and text (pred stringp)) . ,(and position (pred integerp)))
       ;; A negative position says point was at the end of the text.
       (cons text (if (< position 0)
                      (- (funcall shift (- position)))
                    (funcall shift position))))
      (`(nil ,property ,value ,(and beg (pred integerp)) . ,(and end (pred integerp)))
       `(nil ,property ,value ,(funcall shift beg) . ,(funcall shift end)))
      (_ entry))))

;;;; Drawing

(defun ecc-render--freeze (session)
  "Move the live region past every turn of SESSION that is finished."
  (let ((turns (seq-drop (ecc-session-turns session) ecc-render--frozen))
        (done t))
    (while (and turns done)
      (let* ((turn (car turns))
             (bounds (and (ecc-turn-end-time turn)
                          (ecc-render-node-bounds (ecc-turn-id turn)))))
        (if (null bounds)
            (setq done nil)
          (set-marker ecc-render--live-start (cdr bounds))
          (cl-incf ecc-render--frozen)
          (setq turns (cdr turns)))))))

(defun ecc-render-goto-id (id)
  "Move point to the heading of the node ID in this buffer and unfold it.
The nodes above it are unfolded too, so that it is in sight.  Returns
the position, or nil when the node is not drawn."
  (when-let* ((bounds (ecc-render-node-bounds id)))
    (let ((depth (ecc-render-node-depth id)))
      (goto-char (car bounds))
      (ecc-render-show-node id)
      ;; Each heading before this one with a smaller depth encloses it.
      (save-excursion
        (let ((pos (car bounds)))
          (while (and (> depth 0)
                      (setq pos (ecc-render--previous-heading pos)))
            (let ((above (get-text-property pos 'ecc-depth)))
              (when (and above (< above depth))
                (setq depth above)
                (ecc-render-show-node (get-text-property pos 'ecc-heading)))))))
      (car bounds))))

(defun ecc-render--previous-heading (position)
  "Return the start of the heading line before POSITION, or nil.
Folded headings count too: this walks the structure, not the screen."
  (let ((pos position) found)
    (while (and (null found) pos (> pos (point-min)))
      (setq pos (previous-single-property-change pos 'ecc-heading nil (point-min)))
      (when (and pos (get-text-property pos 'ecc-heading))
        (setq found pos))
      (when (and pos (<= pos (point-min)))
        (setq pos nil)))
    found))

(defun ecc-render-goto-node (session node)
  "Move point in the buffer of SESSION to NODE and unfold it.
The buffer is drawn first when a redraw is waiting.  Returns the
position, or nil when the node is not drawn."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (ecc-render-flush session)
      (with-current-buffer buffer
        (ecc-render-goto-id (ecc-node-id node))))))

(defun ecc-render--reset-deltas ()
  "Forget the streamed text waiting to be drawn; a redraw drew it."
  (setq ecc-render--pending-deltas nil
        ecc-render--delta-count 0)
  (when ecc-render--delta-timer
    (cancel-timer ecc-render--delta-timer)
    (setq ecc-render--delta-timer nil)))

(defun ecc-render--ensure-state ()
  "Make the hash tables and markers of this buffer, if they are missing."
  (unless ecc-render--visibility-cache
    (setq ecc-render--visibility-cache (make-hash-table :test #'equal)))
  (unless ecc-render--nodes
    (setq ecc-render--nodes (make-hash-table :test #'equal)))
  (unless ecc-render--live-start
    (setq ecc-render--live-start (make-marker)))
  (unless ecc-render--top-end
    (setq ecc-render--top-end (make-marker))))

(defun ecc-render--finish-draw (session)
  "Do what every draw of SESSION ends with: effects, the spinner, the hook."
  (ecc-render--apply-effects)
  (ecc-render--update-spinner session)
  (run-hooks 'ecc-render-after-draw-hook)
  (force-mode-line-update))

(defun ecc-render-refresh (session)
  "Draw the whole buffer of SESSION from scratch.
The prompt region is kept: only the text before it is drawn again,
and a point that was in it stays in it (FR-UI-2)."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ecc-render--ensure-state)
        (let ((noted (ecc-render--note-points)))
          (with-silent-modifications
            (let ((limit (ecc-render--draw-limit)))
              (delete-region (point-min) limit)
              (ecc-render--drop-from (point-min))
              (clrhash ecc-render--nodes)
              (ecc-render--reset-deltas)
              (setq ecc-render--frozen 0
                    ecc-render--drawn nil)
              (goto-char (point-min))
              (ecc-render--insert-top session)
              (set-marker ecc-render--top-end (point))
              (insert "\n")
              (set-marker ecc-render--live-start (point))
              (ecc-render--insert-live session)
              (ecc-render--seal (point-min) (point))
              (if (ecc-render-prompt-start)
                  (set-marker ecc-render--prompt-start (point))
                (setq ecc-render--prompt-start (copy-marker (point))))
              (ecc-render--apply-visibility)
              (ecc-render--freeze session)))
          (ecc-render--restore-points noted)
          (ecc-render--finish-draw session))))))

(defun ecc-render-update (session)
  "Redraw the top and the live region of SESSION."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (or (null ecc-render--nodes)
                (null ecc-render--live-start)
                (null ecc-render--top-end)
                (null (marker-buffer ecc-render--live-start))
                (null (ecc-render-prompt-start)))
            (ecc-render-refresh session)
          (let ((noted (ecc-render--note-points)))
            (with-silent-modifications
              (setq ecc-render--drawn nil)
              (ecc-render--update-top session)
              (ecc-render--reset-deltas)
              (let ((pos (marker-position ecc-render--live-start))
                    (limit (ecc-render--draw-limit)))
                (ecc-render--drop-from pos)
                (delete-region pos limit)
                (goto-char pos)
                (ecc-render--insert-live session)
                (ecc-render--seal pos (point))
                ;; Both markers collapsed onto the deletion and stayed
                ;; put in front of what was inserted.
                (set-marker ecc-render--prompt-start (point))
                (set-marker ecc-render--live-start pos))
              (ecc-render--apply-visibility)
              (ecc-render--freeze session))
            (ecc-render--restore-points noted)
            (when ecc-render--flash-pending
              (setq ecc-render--flash-pending nil)
              (ecc-visual-flash-region (marker-position ecc-render--live-start)
                                       (ecc-render--draw-limit)))
            (ecc-render--finish-draw session)))))))

(defun ecc-render--update-spinner (session)
  "Turn the spinner of the current buffer while SESSION has work to do."
  ;; `starting' does not turn the spinner: a session waits in it only
  ;; when its process never came up (FR-UI-1).
  (if (memq (ecc-session-state session) '(running compacting))
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

(defun ecc-render--replace-heading (node depth string)
  "Replace the heading line of NODE at DEPTH with STRING, keeping its markers.
The start marker does not advance with text inserted at it, so it is
where it was, and the fold overlay under the heading advances past
the new text on its own."
  (when-let* ((bounds (ecc-render-node-bounds (ecc-node-id node))))
    (let* ((start (car bounds))
           (end (save-excursion (goto-char start) (line-end-position))))
      (when (> end start)
        (save-excursion
          (goto-char start)
          (delete-region start end)
          (insert string)
          (ecc-render--mark start (point) (ecc-node-id node) depth
                            (ecc-render--node-map node))
          (ecc-render--mark-heading start (ecc-node-id node))
          (ecc-render--seal start (point)))))))

(defun ecc-render--append-delta (node text)
  "Append the streamed TEXT to NODE in the current buffer.
Text nodes grow at their end marker; a tool node only updates its
heading, because its body starts collapsed anyway."
  (when-let* ((entry (ecc-render-node-entry (ecc-node-id node))))
    (let ((depth (nth 2 entry)))
      (pcase (ecc-node-type node)
        ((or 'text 'thinking)
         (let ((marker (ecc-node-marker-end node))
               (thinking (eq (ecc-node-type node) 'thinking)))
           (when (and (markerp marker) (eq (marker-buffer marker) (current-buffer)))
             (save-excursion
               (goto-char marker)
               (insert (propertize
                        (ecc-render--stream-string
                         text (ecc-render--pad (if thinking (1+ depth) depth)))
                        'face (if thinking 'ecc-thinking-face 'ecc-assistant-face)
                        'ecc-node (ecc-node-id node)
                        'ecc-depth (if thinking (1+ depth) depth)
                        'keymap (ecc-render--map 'ecc-chat-transcript-map)
                        'read-only t))
               (set-marker marker (point))))))
        ((or 'tool 'agent)
         (ecc-render--replace-heading node depth (ecc-render--tool-heading node depth)))))))

(defun ecc-render--flush-deltas ()
  "Draw the streamed text that is waiting in the current buffer."
  (when ecc-render--delta-timer
    (cancel-timer ecc-render--delta-timer)
    (setq ecc-render--delta-timer nil))
  (let ((pending (nreverse ecc-render--pending-deltas))
        (noted (ecc-render--note-points)))
    (setq ecc-render--pending-deltas nil
          ecc-render--delta-count 0)
    (with-silent-modifications
      (dolist (pair pending)
        (ecc-render--append-delta (car pair) (cdr pair))))
    (ecc-render--restore-points noted)
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
Used for the transcript of an agent (FR-OUT-9).  BUFFER is meant to be
in `ecc-chat-mode'; it gets no prompt region, so the whole of it is
read-only."
  (with-current-buffer buffer
    (setq ecc-render--session session
          ecc-render--prompt-start nil)
    (ecc-render--ensure-state)
    (with-silent-modifications
      (erase-buffer)
      (clrhash ecc-render--nodes)
      (setq ecc-render--drawn nil)
      (let ((start (point)))
        (insert (propertize heading 'face 'ecc-heading-face) "\n\n")
        (ecc-render--mark start (point) "header" 0))
      (set-marker ecc-render--top-end (point))
      (set-marker ecc-render--live-start (point))
      (dolist (node nodes)
        (ecc-render--insert-node session node 0))
      (ecc-render--seal (point-min) (point))
      (ecc-render--apply-visibility))
    (goto-char (point-min))))

;;;; Setup

(defun ecc-render-setup (session buffer)
  "Prepare BUFFER to show SESSION and draw it."
  (with-current-buffer buffer
    (setq ecc-render--session session
          ecc-render--visibility-cache (make-hash-table :test #'equal)
          ecc-render--nodes (make-hash-table :test #'equal)
          ecc-render--frozen 0
          ecc-render--top-end (make-marker)
          ecc-render--live-start (make-marker)
          ecc-render--prompt-start nil)
    (setq header-line-format '(:eval (ecc-render-header-line)))
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
