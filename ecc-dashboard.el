;;; ecc-dashboard.el --- Every Claude session in one list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; One `tabulated-list-mode' buffer showing the sessions this Emacs runs
;; (FR-DASH-1, 3, 4, 5).
;;
;; Only those.  A session another process runs cannot be answered or
;; steered from here, and a conversation that is only a recording is
;; not running at all; both are reached through `ecc-resume', which
;; offers every recording there is.  The list is therefore read from
;; the model alone and is always current: no registry, no scan of
;; ~/.claude/projects, and nothing to poll.
;;
;; The requests waiting for an answer come first, and a and d answer
;; them without leaving the list (FR-DASH-4).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-perm)
(require 'ecc-answer)
(require 'ecc-history)
(require 'ecc-usage)
(require 'ecc-window)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-session-ensure-buffer "ecc-session" (session))

(defconst ecc-dashboard-buffer-name "*ecc-dashboard*"
  "Name of the dashboard buffer.")

;;;; The rows

;; A row is an `ecc-dashboard-entry': what a column needs, worked out
;; once, so that drawing the list touches the session only here.

(cl-defstruct ecc-dashboard-entry
  "One line of the dashboard."
  key           ; the session id, which is what makes a row unique
  session       ; the `ecc-session' the row is about
  name state cwd model prompt time cost
  waiting)      ; how many requests of this session wait for an answer

(defun ecc-dashboard--session-entry (session)
  "Return the row of SESSION, which this Emacs runs."
  (let ((turn (car (last (ecc-session-turns session)))))
    (make-ecc-dashboard-entry
     :key (ecc-session-id session)
     :session session
     :name (ecc-session-name session)
     :state (format "%s" (ecc-session-state session))
     :cwd (or (ecc-session-cwd session) (ecc-session-project-root session))
     :model (ecc-render--model-name session)
     :prompt (or (and turn (ecc-turn-prompt turn)) "")
     :time (or (ecc-session-last-result-time session)
               (and turn (ecc-turn-start-time turn)))
     :cost (ecc-session-total-cost session)
     :waiting (length (ecc-session-pending session)))))

(defun ecc-dashboard-entries ()
  "Return the rows of the sessions this Emacs runs, waiting ones first.
A session read back from a recording is a reader, not a conversation
that can be answered, so it is left out."
  (ecc-dashboard--sort
   (mapcar #'ecc-dashboard--session-entry
           (seq-remove (lambda (session)
                         (eq (ecc-session-kind session) 'archived))
                       (ecc-model-sessions)))))

(defun ecc-dashboard--sort (rows)
  "Return ROWS with the ones waiting for an answer first, then by time.
`sort' is destructive and ROWS is freshly made here, but the sessions
it was built from are not, so the list is copied (docs/verified.md)."
  (seq-sort (lambda (a b)
              (let ((wa (ecc-dashboard-entry-waiting a))
                    (wb (ecc-dashboard-entry-waiting b)))
                (if (eq (> wa 0) (> wb 0))
                    (ecc-dashboard--newer-p a b)
                  (> wa 0))))
            rows))

(defun ecc-dashboard--newer-p (a b)
  "Return non-nil when row A was active more recently than row B."
  (let ((ta (ecc-dashboard-entry-time a))
        (tb (ecc-dashboard-entry-time b)))
    (cond ((and ta tb) (time-less-p tb ta))
          (ta t)
          (t nil))))

;;;; Drawing

(defun ecc-dashboard--project-cell (cwd)
  "Return the Project cell of a row whose working directory is CWD.
Only the last name of the path is shown, because that is what tells one
project from another; the whole path is in the tooltip."
  (let ((label (ecc--fit (ecc--project-label cwd) 20)))
    (if (null cwd)
        label
      (propertize label 'help-echo (abbreviate-file-name cwd)))))

(defun ecc-dashboard--row (entry)
  "Return the `tabulated-list-entries' row of ENTRY."
  (list entry
        (vector
         (ecc--truncate (or (ecc-dashboard-entry-name entry) "") 24)
         (let ((state (or (ecc-dashboard-entry-state entry) "")))
           (if (> (ecc-dashboard-entry-waiting entry) 0)
               (propertize state 'face 'ecc-pending-face)
             state))
         (ecc-dashboard--project-cell (ecc-dashboard-entry-cwd entry))
         (or (ecc-dashboard-entry-model entry) "")
         (ecc--truncate (or (ecc-dashboard-entry-prompt entry) "") 60)
         (ecc--session-time-label (ecc-dashboard-entry-time entry))
         (if (ecc-dashboard-entry-cost entry)
             (format "$%.2f" (ecc-dashboard-entry-cost entry))
           ""))))

(defun ecc-dashboard--collect ()
  "Fill `tabulated-list-entries' for the dashboard."
  (setq tabulated-list-entries (mapcar #'ecc-dashboard--row
                                       (ecc-dashboard-entries))))

;;;; Capabilities (FR-DASH-7)

;; What a session can do is spread over `system/init' (the names of the
;; skills, agents, commands, MCP servers and plugins) and the answer to
;; `initialize' (what each command is for).  Here the two are put back
;; together, sorted by what they are and where they come from, and each
;; one is given the file that defines it so RET can open it.
;;
;; The tree folds without magit-section, which only `ecc-render' is
;; allowed to require: a heading carries the key of its group, TAB adds
;; or removes that key from the set of folded groups and the buffer is
;; drawn again.  It is a page of a few hundred lines.

(defconst ecc-capabilities-buffer-name "*ecc-capabilities*"
  "Name of the Capabilities buffer.")

(defvar ecc-capabilities-directory "~/.claude/"
  "Directory holding the skills, agents and commands of every project.")

(cl-defstruct ecc-capability
  "One thing a session can do."
  kind          ; skill | agent | command | mcp | plugin
  name
  description
  scope         ; global | project | plugin | builtin
  origin        ; the plugin a plugin-scoped entry came from, or nil
  file          ; what RET opens, or nil
  detail)       ; the extra line an MCP server or a plugin carries

(defconst ecc-capabilities-kinds
  '((skill . "Skills") (agent . "Agents") (command . "Slash commands")
    (mcp . "MCP servers") (plugin . "Plugins"))
  "The five kinds of capability, in the order they are shown.")

(defconst ecc-capabilities-scopes
  '((project . "project") (global . "global") (plugin . "plugin")
    (builtin . "built in"))
  "The scopes a capability can come from, in the order they are shown.")

(defun ecc-capabilities--kind-directory (kind)
  "Return the subdirectory KIND is defined in, under a settings directory."
  (pcase kind ('skill "skills/") ('agent "agents/") ('command "commands/")))

(defun ecc-capabilities--file-in (directory kind name)
  "Return the file defining the KIND called NAME under DIRECTORY, or nil."
  (when-let* ((subdirectory (ecc-capabilities--kind-directory kind)))
    (let* ((base (expand-file-name subdirectory (expand-file-name directory)))
           (candidates (if (eq kind 'skill)
                           (list (expand-file-name (concat name "/SKILL.md") base))
                         (list (expand-file-name (concat name ".md") base)))))
      (seq-find #'file-readable-p candidates))))

(defun ecc-capabilities--locate (kind name session plugins)
  "Return (SCOPE ORIGIN . FILE) for the KIND called NAME.
The project of SESSION is looked in first, then the settings directory
of the user, then each of the PLUGINS.  A name that is defined nowhere
Emacs can see is `builtin'."
  (or (when-let* ((root (ecc-session-project-root session))
                  (file (ecc-capabilities--file-in
                         (expand-file-name ".claude/" root) kind name)))
        (cl-list* 'project nil file))
      (when-let* ((file (ecc-capabilities--file-in
                         ecc-capabilities-directory kind name)))
        (cl-list* 'global nil file))
      (seq-some (lambda (plugin)
                  (when-let* ((path (alist-get 'path plugin))
                              (file (ecc-capabilities--file-in path kind name)))
                    (cl-list* 'plugin (alist-get 'name plugin) file)))
                plugins)
      (list 'builtin nil)))

(defun ecc-capabilities--command-descriptions (session)
  "Return a hash of a command name to its description for SESSION.
The descriptions are what the CLI answered `initialize' with."
  (let ((table (make-hash-table :test #'equal)))
    (seq-doseq (command (or (ecc-session-commands session) []))
      (when-let* ((name (alist-get 'name command)))
        (puthash name (alist-get 'description command) table)))
    table))

(defun ecc-capabilities--mcp-tool-count (init name)
  "Return how many tools the MCP server NAME published, from INIT."
  (let ((prefix (format "mcp__%s__" name)))
    (seq-count (lambda (tool) (string-prefix-p prefix tool))
               (append (alist-get 'tools init) nil))))

(defun ecc-capabilities--mcp-file (session)
  "Return the file that configures the MCP servers of SESSION, or nil."
  (seq-find #'file-readable-p
            (delq nil
                  (list (when-let* ((root (ecc-session-project-root session)))
                          (expand-file-name ".mcp.json" root))
                        (expand-file-name "settings.json"
                                          (expand-file-name
                                           ecc-capabilities-directory))
                        (expand-file-name "~/.claude.json")))))

(defun ecc-capabilities (session)
  "Return everything SESSION can do, as a list of `ecc-capability'.
The names come from the last system/init and the descriptions from the
answer to initialize (FR-DASH-7)."
  (let* ((init (ecc-session-init session))
         (plugins (append (alist-get 'plugins init) nil))
         (descriptions (ecc-capabilities--command-descriptions session))
         (skills (append (alist-get 'skills init) nil))
         (entries nil))
    (dolist (name skills)
      (pcase-let ((`(,scope ,origin . ,file)
                   (ecc-capabilities--locate 'skill name session plugins)))
        (push (make-ecc-capability :kind 'skill :name name
                                   :description (gethash name descriptions)
                                   :scope scope :origin origin :file file)
              entries)))
    (seq-doseq (name (or (alist-get 'agents init) []))
      (pcase-let ((`(,scope ,origin . ,file)
                   (ecc-capabilities--locate 'agent name session plugins)))
        (push (make-ecc-capability :kind 'agent :name name
                                   :scope scope :origin origin :file file)
              entries)))
    (seq-doseq (name (or (alist-get 'slash_commands init) []))
      ;; A command a skill installs is defined by the skill; saying so
      ;; twice would only make the list longer.
      (unless (member name skills)
        (pcase-let ((`(,scope ,origin . ,file)
                     (ecc-capabilities--locate 'command name session plugins)))
          (push (make-ecc-capability :kind 'command :name name
                                     :description (gethash name descriptions)
                                     :scope scope :origin origin :file file)
                entries))))
    (seq-doseq (server (or (alist-get 'mcp_servers init) []))
      (let ((name (alist-get 'name server)))
        (push (make-ecc-capability
               :kind 'mcp :name name
               :scope 'global
               :file (ecc-capabilities--mcp-file session)
               :detail (format "%s, %d tools"
                               (or (alist-get 'status server) "unknown")
                               (ecc-capabilities--mcp-tool-count init name)))
              entries)))
    (dolist (plugin plugins)
      (push (make-ecc-capability
             :kind 'plugin :name (alist-get 'name plugin)
             :scope 'plugin :origin (alist-get 'source plugin)
             :file (alist-get 'path plugin)
             :detail (format "%s from %s"
                             (or (alist-get 'version plugin) "?")
                             (or (alist-get 'source plugin) "?")))
            entries))
    (nreverse entries)))

;;;; Drawing the Capabilities buffer

(defvar-local ecc-capabilities--session nil
  "The session the Capabilities buffer is about.")

(defvar-local ecc-capabilities--folded nil
  "Keys of the groups the user has folded shut.")

(defun ecc-capabilities--group-key (kind &optional scope)
  "Return the key of the group of KIND and SCOPE."
  (if scope (format "%s/%s" kind scope) (format "%s" kind)))

(defun ecc-capabilities--label (capability)
  "Return the line describing CAPABILITY, without its indentation."
  (concat (propertize (ecc-capability-name capability) 'face 'ecc-tool-face)
          (when-let* ((detail (ecc-capability-detail capability)))
            (propertize (format "  (%s)" detail) 'face 'ecc-dim-face))
          (when-let* ((description (ecc-capability-description capability)))
            (propertize (concat "  " (ecc--truncate description 100))
                        'face 'ecc-dim-face))))

(defun ecc-capabilities--insert-heading (key text)
  "Insert the heading TEXT of the group KEY, marked as foldable."
  (let ((folded (member key ecc-capabilities--folded)))
    (insert (propertize (concat (if folded "▸ " "▾ ") text)
                        'face 'ecc-heading-face
                        'ecc-capabilities-key key)
            "\n")
    (not folded)))

(defun ecc-capabilities-draw (session)
  "Draw everything SESSION can do into the current buffer (FR-DASH-7)."
  (let ((inhibit-read-only t)
        (entries (ecc-capabilities session)))
    (erase-buffer)
    (insert (propertize (format "Capabilities of %s\n\n"
                                (ecc-session-name session))
                        'face 'ecc-heading-face))
    (if (null entries)
        (insert (propertize
                 "Nothing yet: the CLI says what it can do in system/init,
which arrives with the first turn.\n"
                 'face 'ecc-dim-face))
      (pcase-dolist (`(,kind . ,title) ecc-capabilities-kinds)
        (let ((of-kind (seq-filter (lambda (entry)
                                     (eq (ecc-capability-kind entry) kind))
                                   entries)))
          (when of-kind
            (when (ecc-capabilities--insert-heading
                   (ecc-capabilities--group-key kind)
                   (format "%s (%d)" title (length of-kind)))
              (pcase-dolist (`(,scope . ,scope-name) ecc-capabilities-scopes)
                (let ((of-scope (seq-filter
                                 (lambda (entry)
                                   (eq (ecc-capability-scope entry) scope))
                                 of-kind)))
                  (when of-scope
                    (insert "  ")
                    (when (ecc-capabilities--insert-heading
                           (ecc-capabilities--group-key kind scope)
                           (format "%s (%d)" scope-name (length of-scope)))
                      (dolist (entry of-scope)
                        (insert "    "
                                (propertize (ecc-capabilities--label entry)
                                            'ecc-capability entry)
                                "\n"))))))
              (insert "\n"))))))
    (goto-char (point-min))))

(defvar ecc-capabilities-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-capabilities-visit)
    (define-key map (kbd "TAB") #'ecc-capabilities-toggle)
    (define-key map (kbd "g") #'ecc-capabilities-refresh)
    map)
  "Keymap of `ecc-capabilities-mode'.")

(define-derived-mode ecc-capabilities-mode special-mode "Claude-Capabilities"
  "Major mode listing the skills, agents, commands, servers and plugins.

\\{ecc-capabilities-mode-map}"
  :interactive nil
  (setq-local truncate-lines t))

;;;###autoload
(defun ecc-capabilities-show (session)
  "Show everything SESSION can do (FR-DASH-7)."
  (interactive (list (ecc-capabilities--read-session)))
  (let ((buffer (get-buffer-create ecc-capabilities-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-capabilities-mode)
        (ecc-capabilities-mode))
      (setq ecc-capabilities--session session)
      (ecc-capabilities-draw session))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-capabilities--read-session ()
  "Return the session the Capabilities buffer should be about."
  (or ecc-capabilities--session
      (ecc-dashboard-session-at-point)
      ecc-render--session
      (car (ecc-model-sessions))
      (user-error "No session to look at")))

(defun ecc-capabilities-refresh ()
  "Draw the Capabilities buffer again."
  (interactive)
  (ecc-capabilities-draw (or ecc-capabilities--session
                             (user-error "No session"))))

(defun ecc-capabilities-toggle ()
  "Fold or unfold the group at point."
  (interactive)
  (if-let* ((key (get-text-property (point) 'ecc-capabilities-key)))
      (let ((line (line-number-at-pos)))
        (setq ecc-capabilities--folded
              (if (member key ecc-capabilities--folded)
                  (delete key ecc-capabilities--folded)
                (cons key ecc-capabilities--folded)))
        (ecc-capabilities-refresh)
        (goto-char (point-min))
        (forward-line (1- line)))
    (user-error "Not on a group")))

(defun ecc-capabilities-visit ()
  "Open what defines the capability at point (FR-DASH-7)."
  (interactive)
  (let ((capability (get-text-property (point) 'ecc-capability)))
    (cond
     ((null capability) (ecc-capabilities-toggle))
     ((null (ecc-capability-file capability))
      (user-error "%s is built into the CLI; there is no file to open"
                  (ecc-capability-name capability)))
     ((file-directory-p (ecc-capability-file capability))
      (dired (ecc-capability-file capability)))
     (t (find-file (ecc-capability-file capability))))))

(defvar ecc-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecc-dashboard-visit)
    (define-key map (kbd "+") #'ecc-dashboard-new)
    (define-key map (kbd "k") #'ecc-dashboard-stop)
    (define-key map (kbd "D") #'ecc-dashboard-delete)
    (define-key map (kbd "r") #'ecc-dashboard-rename)
    (define-key map (kbd "R") #'ecc-dashboard-resume)
    (define-key map (kbd "a") #'ecc-dashboard-allow)
    (define-key map (kbd "d") #'ecc-dashboard-deny)
    (define-key map (kbd "g") #'ecc-dashboard-refresh)
    (define-key map (kbd "C") #'ecc-capabilities-show)
    (define-key map (kbd "U") #'ecc-usage)
    map)
  "Keymap of `ecc-dashboard-mode'.")

(define-derived-mode ecc-dashboard-mode tabulated-list-mode "Claude-Sessions"
  "Major mode listing every Claude session Emacs can see.

\\{ecc-dashboard-mode-map}"
  :interactive nil
  (setq tabulated-list-format [("Name" 24 t) ("State" 18 t)
                               ("Project" 20 t) ("Model" 8 t) ("Last prompt" 40 t)
                               ("Updated" 14 t) ("Cost" 8 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'ecc-dashboard--collect nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun ecc-dashboard ()
  "Show the sessions this Emacs runs (FR-DASH-1)."
  (interactive)
  (let ((buffer (get-buffer-create ecc-dashboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-dashboard-mode)
        (ecc-dashboard-mode))
      (ecc-dashboard--collect)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ecc-dashboard-redraw ()
  "Draw the dashboard again from what is already known."
  (when-let* ((buffer (get-buffer ecc-dashboard-buffer-name)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((point (point)))
          (ecc-dashboard--collect)
          (tabulated-list-print t)
          (goto-char (min point (point-max))))))))

(defun ecc-dashboard-refresh ()
  "Draw the dashboard again."
  (interactive)
  (ecc-dashboard-redraw))

;;;; Commands

(defun ecc-dashboard-entry-at-point ()
  "Return the row at point, or signal an error."
  (let ((entry (tabulated-list-get-id)))
    (unless (ecc-dashboard-entry-p entry)
      (user-error "No session on this line"))
    entry))

(defun ecc-dashboard-session-at-point ()
  "Return the session of the row at point."
  (ecc-dashboard-entry-session (ecc-dashboard-entry-at-point)))

(defun ecc-dashboard-visit ()
  "Show the transcript of the session at point (FR-DASH-3)."
  (interactive)
  (require 'ecc-window)
  (select-window (ecc-display-session (ecc-dashboard-session-at-point))))

(defun ecc-dashboard-new (directory)
  "Start a session in DIRECTORY (FR-DASH-5)."
  (interactive (list (read-directory-name "Directory: " (ecc-window-project-root))))
  (require 'ecc)
  (ecc-start directory)
  (ecc-dashboard-redraw))

(defun ecc-dashboard-stop ()
  "Stop the session at point (FR-DASH-5)."
  (interactive)
  (let ((session (ecc-dashboard-session-at-point)))
    (require 'ecc)
    (ecc-kill session)
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-delete ()
  "Delete the recording of the session at point, after asking (FR-DASH-5)."
  (interactive)
  (let* ((entry (ecc-dashboard-entry-at-point))
         (file (or (ecc-history-file (ecc-dashboard-entry-key entry))
                   (user-error "This session has no recording"))))
    (when (yes-or-no-p (format "Delete %s? " (abbreviate-file-name file)))
      (delete-file file)
      (ecc-dashboard-refresh))))

(defun ecc-dashboard-rename (name)
  "Rename the session at point to NAME (FR-DASH-5)."
  (interactive (list (read-string "New name: ")))
  (let ((session (ecc-dashboard-session-at-point)))
    (when (string-empty-p name)
      (user-error "The name may not be empty"))
    (setf (ecc-session-name session) (ecc-model-unique-name name))
    (when (buffer-live-p (ecc-session-buffer session))
      (with-current-buffer (ecc-session-buffer session)
        (rename-buffer (format "*ecc: %s*" (ecc-session-name session)) t)))
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-resume ()
  "Resume the session at point (FR-DASH-3, FR-HIST-3)."
  (interactive)
  ;; A session another process is running is refused by
  ;; `ecc-history-resume' unless the user insists (FR-TUI-5).
  (let ((session (ecc-dashboard-session-at-point)))
    (ecc-history-resume session current-prefix-arg)
    (require 'ecc-window)
    (select-window (ecc-display-session session))
    (ecc-dashboard-redraw)))

(defun ecc-dashboard--request-at-point ()
  "Return the oldest request of the session at point, or signal an error."
  (let ((session (ecc-dashboard-session-at-point)))
    (or (car (ecc-session-pending session))
        (user-error "%s is not waiting for an answer" (ecc-session-name session)))))

(defun ecc-dashboard-allow ()
  "Allow the oldest waiting request of the session at point (FR-DASH-4)."
  (interactive)
  (ecc-perm-allow-request (ecc-dashboard--request-at-point))
  (ecc-dashboard-redraw))

(defun ecc-dashboard-deny (reason)
  "Deny the oldest waiting request of the session at point with REASON."
  (interactive (list (read-string "Reason for denying (may be empty): ")))
  (ecc-perm-respond (ecc-dashboard--request-at-point) 'deny :message reason)
  (ecc-dashboard-redraw))

;;;; Wiring

(defun ecc-dashboard--on-change (&rest _)
  "Draw the dashboard again after something changed in the model."
  (ecc-dashboard-redraw))

(dolist (hook '(ecc-request-added-hook
                ecc-request-resolved-hook
                ecc-turn-finished-hook
                ecc-session-state-changed-hook))
  (add-hook hook #'ecc-dashboard--on-change))

(provide 'ecc-dashboard)

;;; ecc-dashboard.el ends here
