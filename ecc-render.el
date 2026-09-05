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
;; The buffer is laid out as a header, the turns that are finished, and a
;; live region holding the current turn and the state line.  Finished
;; turns are never touched again: a redraw deletes the live region and
;; builds it anew, which keeps the cost proportional to the current turn
;; rather than to the length of the conversation (plan section 5.2).
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

(defcustom ecc-render-follow t
  "Non-nil scrolls to the end of the buffer while it is at the end."
  :type 'boolean
  :group 'ecc)

;;;; Section classes

(defclass ecc-section-root (magit-section) ()
  :documentation "The whole session buffer.")
(defclass ecc-section-header (magit-section) ()
  :documentation "The session summary at the top of the buffer.")
(defclass ecc-section-turn (magit-section) ()
  :documentation "One prompt and everything that followed it.")
(defclass ecc-section-prompt (magit-section) ()
  :documentation "The prompt the user sent.")
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
    map)
  "Keymap of a section that is waiting for an answer.")

(defun ecc-render--class (type)
  "Return the section class that draws a node of TYPE."
  (pcase type
    ('text 'ecc-section-text)
    ('thinking 'ecc-section-thinking)
    ('step 'ecc-section-step)
    ('tool 'ecc-section-tool)
    ('agent 'ecc-section-agent)
    ((or 'permission 'question 'plan) 'ecc-section-request)
    ('result 'ecc-section-result)
    ((or 'system 'recap) 'ecc-section-system)
    (_ 'ecc-section-unknown)))

;;;; Buffer state

(defvar-local ecc-render--session nil
  "The session drawn in this buffer.")

(defvar-local ecc-render--header nil
  "The header section object of this buffer.")

(defvar-local ecc-render--live-start nil
  "Marker where the live region starts, after the last frozen turn.")

(defvar-local ecc-render--frozen 0
  "Number of turns that are finished and will not be drawn again.")

(defvar-local ecc-render--visibility-cache nil
  "Hash mapping a section value to whether the user left it collapsed.")

(defvar-local ecc-render--timer nil
  "Debounce timer of this buffer, or nil.")

;;;; Text helpers

(defun ecc-render--pad (depth)
  "Return the indentation string for DEPTH."
  (make-string (* 2 depth) ?\s))

(defun ecc-render--one-line (string)
  "Return STRING with newlines squeezed out, for use in a heading."
  (replace-regexp-in-string "[ \t\n\r]+" " " (or string "")))

(defun ecc-render--insert-lines (text prefix face)
  "Insert TEXT in FACE, putting PREFIX in front of every line."
  (let ((body (string-trim-right (or text "") "[\n]+")))
    (dolist (line (split-string body "\n"))
      (insert (propertize (concat prefix line) 'face face) "\n"))))

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
         (_ nil))
       (ecc--truncate (ecc-protocol-value-string (cdr (car input))) 60)
       "")))

;;;; The header

(defun ecc-render--header-string (session)
  "Return the header text of SESSION, ending in a newline."
  (concat
   (propertize (or (ecc-session-name session) "?") 'face 'ecc-heading-face)
   (propertize
    (format "  ·  %s  ·  %s  ·  %s  ·  $%.4f\n"
            (or (alist-get 'model (ecc-session-init session)) "?")
            (or (ecc-session-permission-mode session) "default")
            (ecc-session-state session)
            (or (ecc-session-total-cost session) 0))
    'face 'ecc-dim-face)
   "\n"))

(defun ecc-render--insert-header (session)
  "Insert the header section of SESSION and return it."
  (magit-insert-section (ecc-section-header "header")
    (insert (ecc-render--header-string session))))

(defun ecc-render--update-header (session)
  "Redraw the header of SESSION in place, keeping its section object.
Only the text of the header changes, so the sections below it keep
their markers and are not drawn again."
  (when-let* ((section ecc-render--header))
    (when (marker-buffer (oref section start))
      (let* ((start (marker-position (oref section start)))
             (end (marker-position (oref section end)))
             (text (ecc-render--header-string session))
             (delta (- (length text) (- end start)))
             (live (marker-position ecc-render--live-start)))
        (save-excursion
          (delete-region start end)
          (goto-char start)
          (insert text)
          ;; The start marker advances with text inserted at its
          ;; position, and the end marker collapsed with the deletion, so
          ;; both are put back by hand.
          (set-marker (oref section start) start)
          (set-marker (oref section end) (point))
          (set-marker ecc-render--live-start (+ live delta))
          (put-text-property start (point) 'magit-section section))))))

;;;; Nodes

(defun ecc-render--skip-p (node)
  "Return non-nil when NODE has nothing worth drawing.
An empty thinking block is all signature and no text."
  (and (eq (ecc-node-type node) 'thinking)
       (string-empty-p (string-trim (or (ecc-model-node-get node 'text) "")))))

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
    (let ((type (ecc-node-type node)))
      (magit-insert-section ((eval (ecc-render--class type))
                             (ecc-node-id node)
                             (and (memq type ecc-render-hidden-types) t))
        (pcase type
          ('text (ecc-render--insert-text node depth))
          ('thinking (ecc-render--insert-thinking node depth))
          ('step (ecc-render--insert-step session node depth))
          ((or 'tool 'agent) (ecc-render--insert-tool session node depth))
          ((or 'permission 'question 'plan) (ecc-render--insert-request node depth))
          ('result (ecc-render--insert-result node depth))
          ((or 'system 'recap) (ecc-render--insert-system node depth))
          (_ (ecc-render--insert-unknown node depth)))))))

(defun ecc-render--insert-text (node depth)
  "Insert the assistant text NODE at DEPTH."
  (ecc-render--insert-lines (ecc-model-node-get node 'text)
                            (ecc-render--pad depth)
                            (if (ecc-model-node-get node 'synthetic)
                                'ecc-synthetic-face
                              'ecc-assistant-face)))

(defun ecc-render--insert-thinking (node depth)
  "Insert the thinking NODE at DEPTH."
  (let ((pad (ecc-render--pad depth)))
    (magit-insert-heading (concat pad (propertize "Thinking" 'face 'ecc-thinking-face)))
    (ecc-render--insert-lines (ecc-model-node-get node 'text)
                              (concat pad "  ") 'ecc-thinking-face)))

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

(defun ecc-render--insert-tool (session node depth)
  "Insert the tool or agent NODE of SESSION at DEPTH."
  (let* ((pad (ecc-render--pad depth))
         (body (concat pad "  "))
         (name (or (ecc-model-node-get node 'name) "?"))
         (input (ecc-model-node-get node 'input))
         (error-p (eq (ecc-node-status node) 'error)))
    (magit-insert-heading
      (concat pad
              (propertize (ecc-render--status-mark (ecc-node-status node))
                          'face (if error-p 'ecc-error-face 'ecc-dim-face))
              " "
              (propertize name 'face (if error-p 'ecc-error-face 'ecc-tool-face))
              "  "
              (propertize (ecc-render-tool-summary name input) 'face 'ecc-dim-face)))
    (ecc-render--insert-input input body)
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
            (if error-p 'ecc-error-face 'ecc-dim-face)))))
    (dolist (child (ecc-node-children node))
      (ecc-render--insert-node session child (1+ depth)))))

(defun ecc-render--request-heading (node)
  "Return the heading of the request NODE."
  (let* ((request (ecc-model-node-get node 'request))
         (name (if request (ecc-request-tool-name request) "?"))
         (label (pcase (ecc-node-type node)
                  ('question "Question")
                  ('plan "Plan review")
                  (_ (format "Permission: %s" name)))))
    (pcase (ecc-node-status node)
      ('pending (concat (propertize (format "⚠ %s" label) 'face 'ecc-pending-face)
                        "  "
                        (propertize (ecc-render--one-line
                                     (and request
                                          (ecc-render-tool-summary
                                           name (ecc-request-input request))))
                                    'face 'ecc-dim-face)
                        (propertize "   a: allow  d: deny" 'face 'ecc-dim-face)))
      ('denied (concat (propertize (format "✗ %s" label) 'face 'ecc-error-face)
                       (propertize (format "  denied%s"
                                           (if-let* ((why (ecc-model-node-get
                                                          node 'outcome-message)))
                                               (concat ": " (ecc-render--one-line why))
                                             ""))
                                   'face 'ecc-dim-face)))
      (_ (concat (propertize (format "✓ %s" label) 'face 'ecc-dim-face)
                 (propertize "  allowed" 'face 'ecc-dim-face))))))

(defun ecc-render--insert-request (node depth)
  "Insert the permission, question or plan NODE at DEPTH."
  (let* ((pad (ecc-render--pad depth))
         (request (ecc-model-node-get node 'request)))
    (magit-insert-heading (concat pad (ecc-render--request-heading node)))
    (when request
      (if (eq (ecc-request-kind request) 'question)
          (ecc-render--insert-questions request (concat pad "  "))
        (ecc-render--insert-input (ecc-request-input request) (concat pad "  "))))))

(defun ecc-render--insert-questions (request prefix)
  "Insert the questions of REQUEST indented by PREFIX."
  (let ((questions (alist-get 'questions (ecc-request-input request)))
        (n 0))
    (seq-doseq (question (or questions []))
      (insert (propertize (concat prefix (ecc-render--one-line
                                          (alist-get 'question question)))
                          'face 'ecc-pending-face)
              "\n")
      (setq n 0)
      (seq-doseq (option (or (alist-get 'options question) []))
        (cl-incf n)
        (insert (propertize (format "%s  %d. %s" prefix n (alist-get 'label option))
                            'face 'ecc-dim-face)
                "\n")))))

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

(defun ecc-render--insert-system (node depth)
  "Insert the system NODE at DEPTH."
  (let* ((pad (ecc-render--pad depth))
         (kind (ecc-model-node-get node 'kind))
         (text (or (ecc-model-node-get node 'text)
                   (pcase kind
                     ('compact (format "compacted: %s%s"
                                       (or (ecc-model-node-get node 'result) "boundary")
                                       (if-let* ((e (ecc-model-node-get node 'error)))
                                           (concat " — " e) "")))
                     ('hook (format "hook %s"
                                    (alist-get 'hook_name
                                               (ecc-model-node-get node 'message))))
                     (_ (format "%s" kind))))))
    (magit-insert-heading
      (concat pad (propertize (format "system: %s" (ecc-render--one-line text))
                              'face 'ecc-dim-face)))
    (when-let* ((message (ecc-model-node-get node 'message)))
      (ecc-render--insert-lines (ecc--truncate (format "%S" message) 400)
                                (concat pad "  ") 'ecc-dim-face))))

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
         (propertize (format "  ·  %.1fs  ·  $%.4f"
                             (or duration 0) (or (ecc-turn-cost turn) 0))
                     'face 'ecc-dim-face)
       ""))))

(defun ecc-render--insert-turn (session turn)
  "Insert TURN of SESSION and return its section."
  (magit-insert-section (ecc-section-turn (ecc-turn-id turn))
    (magit-insert-heading (ecc-render--turn-heading session turn))
    (when-let* ((prompt (ecc-turn-prompt turn)))
      (magit-insert-section (ecc-section-prompt (concat (ecc-turn-id turn) "/prompt"))
        (ecc-render--insert-lines prompt "▌ " 'ecc-user-face)))
    (dolist (child (ecc-turn-children turn))
      (ecc-render--insert-node session child 1))))

(defun ecc-render--tail-string (session)
  "Return the state line of SESSION, or nil when there is nothing to say."
  (pcase (ecc-session-state session)
    ('idle nil)
    ('exited (propertize
              (format "終了（code %s）。R で resume"
                      (or (alist-get 'exit-status (ecc-session-progress session)) "?"))
              'face 'ecc-error-face))
    (state (propertize (format "● %s…" state) 'face 'ecc-pending-face))))

(defun ecc-render--insert-live (session)
  "Insert the turns of SESSION that are not frozen yet, and the state line."
  (dolist (turn (seq-drop (ecc-session-turns session) ecc-render--frozen))
    (ecc-render--insert-turn session turn))
  (when-let* ((tail (ecc-render--tail-string session)))
    (magit-insert-section (ecc-section-tail "tail")
      (insert tail "\n"))))

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

(defun ecc-render-refresh (session)
  "Draw the whole buffer of SESSION from scratch."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless ecc-render--visibility-cache
          (setq ecc-render--visibility-cache (make-hash-table :test #'equal)))
        (when (and magit-root-section (marker-buffer (oref magit-root-section start)))
          (ecc-render--remember-visibility magit-root-section))
        (with-silent-modifications
          (erase-buffer)
          (setq ecc-render--frozen 0)
          (unless ecc-render--live-start
            (setq ecc-render--live-start (make-marker)))
          (magit-insert-section (ecc-section-root "root")
            (setq ecc-render--header (ecc-render--insert-header session))
            (set-marker ecc-render--live-start (point))
            (ecc-render--insert-live session))
          (set-marker-insertion-type (oref magit-root-section end) t)
          (magit-section-show magit-root-section)
          (ecc-render--freeze session))
        (goto-char (point-max))))))

(defun ecc-render-update (session)
  "Redraw the header and the live region of SESSION."
  (when-let* ((buffer (ecc-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if (or (null magit-root-section)
                (null ecc-render--live-start)
                (null (marker-buffer ecc-render--live-start)))
            (ecc-render-refresh session)
          (let ((follow (and ecc-render-follow (ecc-render--windows-at-end)))
                (at-end (>= (point) (marker-position ecc-render--live-start))))
            (with-silent-modifications
              (ecc-render--update-header session)
              (dolist (section (ecc-render--live-sections))
                (ecc-render--remember-visibility section))
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
            (when at-end (goto-char (point-max)))
            (dolist (window follow)
              (set-window-point window (point-max)))))))))

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

(defun ecc-render-setup (session buffer)
  "Prepare BUFFER to show SESSION and draw it."
  (with-current-buffer buffer
    (setq ecc-render--session session
          ecc-render--visibility-cache (make-hash-table :test #'equal)
          ecc-render--frozen 0
          ecc-render--live-start (make-marker))
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
                ecc-compact-hook))
  (add-hook hook #'ecc-render--on-change))

(provide 'ecc-render)

;;; ecc-render.el ends here
