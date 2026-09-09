;;; ecc-dashboard.el --- Every Claude session in one list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.7 of IMPLEMENTATION_PLAN.md: one `tabulated-list-mode'
;; buffer showing the sessions this package runs, the ones another
;; process runs, and the ones that only exist as a recording
;; (FR-DASH-1 to 6).
;;
;; The three sources are read differently.  The sessions of this Emacs
;; are in the model and are always current.  The sessions of another
;; process come from `ecc-registry', which reads the files Claude Code
;; keeps about itself: no subprocess, and the directory can be watched,
;; so the list is current without polling for it.  The recordings are
;; scanned on the first draw and on g, reading the two ends of each file
;; rather than all of it.
;;
;; A session that appears in more than one source is shown once: a live
;; session knows more about itself than its recording does.

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
(require 'ecc-registry)
(require 'ecc-usage)
(require 'ecc-window)

(declare-function ecc-start "ecc" (&optional directory name))
(declare-function ecc-kill "ecc" (session))
(declare-function ecc-session-ensure-buffer "ecc-session" (session))

(defcustom ecc-dashboard-poll-interval 30
  "Seconds between two rereads of the session registry (FR-DASH-2).
The registry is watched, so this only catches what a file notification
missed, and it only runs while the dashboard is on screen."
  :type 'number
  :group 'ecc)

(defcustom ecc-dashboard-recordings t
  "Non-nil lists the recorded conversations as well (FR-DASH-2 c).
Scanning them reads a few lines of every file under
`ecc-history-directory'."
  :type 'boolean
  :group 'ecc)

(defconst ecc-dashboard-buffer-name "*ecc-dashboard*"
  "Name of the dashboard buffer.")

;;;; The rows

;; A row is an `ecc-dashboard-entry'.  It is what the three sources have
;; in common, and it carries whatever the source could say; a column
;; shows an empty string for what it could not.

(cl-defstruct ecc-dashboard-entry
  "One line of the dashboard."
  key           ; the session id, which is what makes a row unique
  kind          ; own | external | archived
  session       ; the `ecc-session', for an own or opened session
  agent         ; the `claude agents --json' object, for an external one
  file          ; the recording, for an archived one
  name state cwd model prompt time cost
  waiting)      ; how many requests of this session wait for an answer

(defun ecc-dashboard--session-entry (session)
  "Return the row of SESSION, which this Emacs runs."
  (let ((turn (car (last (ecc-session-turns session)))))
    (make-ecc-dashboard-entry
     :key (ecc-session-id session)
     :kind (if (eq (ecc-session-kind session) 'archived) 'archived 'own)
     :session session
     :name (ecc-session-name session)
     :state (format "%s" (ecc-session-state session))
     :cwd (or (ecc-session-cwd session) (ecc-session-project-root session))
     :model (or (alist-get 'model (ecc-session-init session))
                (ecc-model-option session :model nil))
     :prompt (or (and turn (ecc-turn-prompt turn)) "")
     :time (or (ecc-session-last-result-time session)
               (and turn (ecc-turn-start-time turn)))
     :cost (ecc-session-total-cost session)
     :waiting (length (ecc-session-pending session)))))

(defun ecc-dashboard--agent-entry (agent)
  "Return the row of AGENT, a session another process runs (FR-DASH-6).
The CLI records its state itself; `waitingFor' says what it is waiting
for when it is not simply busy or idle."
  (let ((waiting-for (alist-get 'waitingFor agent))
        (status (alist-get 'status agent)))
    (make-ecc-dashboard-entry
     :key (alist-get 'sessionId agent)
     :kind 'external
     :agent agent
     :name (or (alist-get 'name agent) "?")
     :state (if (and waiting-for (stringp waiting-for))
                (format "waiting: %s" waiting-for)
              (or (ecc-registry-display-status status) "?"))
     :cwd (alist-get 'cwd agent)
     :model (or (alist-get 'version agent) "")
     :prompt (or (alist-get 'kind agent) "")
     :time (when-let* ((updated (or (alist-get 'updatedAt agent)
                                    (alist-get 'startedAt agent))))
             (time-convert (/ updated 1000.0) 'list))
     :cost nil
     :waiting (if (and waiting-for (stringp waiting-for)) 1 0))))

(defun ecc-dashboard--file-entry (info)
  "Return the row of the recording described by INFO (FR-DASH-2 c)."
  (make-ecc-dashboard-entry
   :key (alist-get 'session-id info)
   :kind 'archived
   :file (alist-get 'file info)
   :name (or (alist-get 'title info) (alist-get 'session-id info))
   :state "archived"
   :cwd (alist-get 'cwd info)
   :model ""
   :prompt (or (alist-get 'prompt info) "")
   :time (or (alist-get 'time info) (alist-get 'mtime info))
   :cost (alist-get 'cost info)
   :waiting 0))

;;;; The sources

(defvar ecc-dashboard--agents nil
  "The sessions Claude Code is running, as `ecc-registry' last read them.")

(defvar ecc-dashboard--recordings nil
  "The scan of `ecc-history-directory', as a list of alists.")

(defvar ecc-dashboard--timer nil
  "Timer that polls the sessions of other processes, or nil.")

(defun ecc-dashboard-refresh-agents (&optional callback)
  "Reread the sessions Claude Code is running (FR-DASH-2 b).
CALLBACK, when given, is called once they are in.  Reading the registry
costs a few small files, so unlike `claude agents --json' this needs no
process and can be done as often as the list is drawn."
  (setq ecc-dashboard--agents (ecc-registry-sessions))
  (when callback (funcall callback))
  ecc-dashboard--agents)

(defun ecc-dashboard-refresh-recordings ()
  "Scan `ecc-history-directory' and remember what it holds (FR-DASH-2 c)."
  (setq ecc-dashboard--recordings
        (when ecc-dashboard-recordings
          (mapcar #'ecc-history-scan-file (ecc-history-files)))))

(defun ecc-dashboard-entries ()
  "Return the rows of every session, the ones needing an answer first.
A session known from several sources is shown once, with the row of
the source that knows most about it (FR-DASH-4)."
  (let ((seen (make-hash-table :test #'equal))
        rows)
    (dolist (make (list
                   (mapcar #'ecc-dashboard--session-entry (ecc-model-sessions))
                   (mapcar #'ecc-dashboard--agent-entry ecc-dashboard--agents)
                   (mapcar #'ecc-dashboard--file-entry ecc-dashboard--recordings)))
      (dolist (entry make)
        (let ((key (ecc-dashboard-entry-key entry)))
          (unless (and key (gethash key seen))
            (when key (puthash key t seen))
            (push entry rows)))))
    (ecc-dashboard--sort (nreverse rows))))

(defun ecc-dashboard--sort (rows)
  "Return ROWS with the ones waiting for an answer first, then by time.
`sort' is destructive and ROWS is freshly made here, but the sessions
it was built from are not, so the list is copied (docs/verified.md)."
  (seq-sort (lambda (a b)
              (let ((wa (ecc-dashboard-entry-waiting a))
                    (wb (ecc-dashboard-entry-waiting b)))
                (cond ((not (eq (> wa 0) (> wb 0))) (> wa 0))
                      ((not (eq (ecc-dashboard-entry-kind a)
                                (ecc-dashboard-entry-kind b)))
                       (< (ecc-dashboard--kind-rank a)
                          (ecc-dashboard--kind-rank b)))
                      (t (ecc-dashboard--newer-p a b)))))
            rows))

(defun ecc-dashboard--kind-rank (entry)
  "Return the sort rank of the kind of ENTRY."
  (pcase (ecc-dashboard-entry-kind entry) ('own 0) ('external 1) (_ 2)))

(defun ecc-dashboard--newer-p (a b)
  "Return non-nil when row A was active more recently than row B."
  (let ((ta (ecc-dashboard-entry-time a))
        (tb (ecc-dashboard-entry-time b)))
    (cond ((and ta tb) (time-less-p tb ta))
          (ta t)
          (t nil))))

;;;; Drawing

(defun ecc-dashboard--kind-label (entry)
  "Return the kind of ENTRY as a short label."
  (pcase (ecc-dashboard-entry-kind entry)
    ('own "own") ('external "ext") (_ "arch")))

(defun ecc-dashboard--time-label (time)
  "Return TIME as a short label, or an empty string when it is nil."
  (if (null time)
      ""
    (let ((age (float-time (time-subtract (current-time) time))))
      (if (< age 86400)
          (format-time-string "%H:%M" time)
        (format-time-string "%m/%d" time)))))

(defun ecc-dashboard--row (entry)
  "Return the `tabulated-list-entries' row of ENTRY."
  (list entry
        (vector
         (ecc-dashboard--kind-label entry)
         (ecc--truncate (or (ecc-dashboard-entry-name entry) "") 24)
         (let ((state (or (ecc-dashboard-entry-state entry) "")))
           (if (> (ecc-dashboard-entry-waiting entry) 0)
               (propertize state 'face 'ecc-pending-face)
             state))
         (abbreviate-file-name (or (ecc-dashboard-entry-cwd entry) ""))
         (ecc--truncate (or (ecc-dashboard-entry-model entry) "") 20)
         (ecc--truncate (or (ecc-dashboard-entry-prompt entry) "") 60)
         (ecc-dashboard--time-label (ecc-dashboard-entry-time entry))
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
;; allowed to require (plan section 0): a heading carries the key of its
;; group, TAB adds or removes that key from the set of folded groups and
;; the buffer is drawn again.  It is a page of a few hundred lines.

(defconst ecc-capabilities-buffer-name "*ecc-capabilities*"
  "Name of the Capabilities buffer.")

(defcustom ecc-capabilities-directory "~/.claude/"
  "Directory holding the skills, agents and commands of every project."
  :type 'directory
  :group 'ecc)

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
  (setq tabulated-list-format [("Kind" 5 t) ("Name" 24 t) ("State" 18 t)
                               ("cwd" 30 t) ("Model" 20 t) ("Last prompt" 40 t)
                               ("Updated" 7 t) ("Cost" 8 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'ecc-dashboard--collect nil t)
  (add-hook 'kill-buffer-hook #'ecc-dashboard--stop-timer nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun ecc-dashboard ()
  "Show every Claude session Emacs can see (FR-DASH-1)."
  (interactive)
  (let ((buffer (get-buffer-create ecc-dashboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-dashboard-mode)
        (ecc-dashboard-mode))
      (ecc-dashboard-refresh-recordings)
      (ecc-dashboard-refresh-agents)
      (ecc-dashboard--collect)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    (ecc-dashboard--start-watch)
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
  "Read every source again and draw the dashboard (FR-DASH-2)."
  (interactive)
  (ecc-dashboard-refresh-recordings)
  (ecc-dashboard-refresh-agents)
  (ecc-dashboard-redraw))

;;;; Keeping up with the registry (FR-DASH-6)

;; The registry directory is watched, which is what makes a session
;; started in a terminal appear here at once.  A file notification is a
;; courtesy rather than a promise, so a slow timer reads it again while
;; the dashboard is on screen (plan section 9, item 15).

(defun ecc-dashboard--start-watch ()
  "Watch the session registry and poll it slowly while the list is shown."
  (add-hook 'ecc-registry-changed-hook #'ecc-dashboard--registry-changed)
  (ecc-registry-watch)
  (unless ecc-dashboard--timer
    (setq ecc-dashboard--timer
          (run-at-time ecc-dashboard-poll-interval ecc-dashboard-poll-interval
                       #'ecc-dashboard--poll))))

(defun ecc-dashboard--stop-timer ()
  "Stop watching and polling the session registry."
  (remove-hook 'ecc-registry-changed-hook #'ecc-dashboard--registry-changed)
  (ecc-registry-unwatch)
  (when ecc-dashboard--timer
    (cancel-timer ecc-dashboard--timer)
    (setq ecc-dashboard--timer nil)))

(defun ecc-dashboard--registry-changed ()
  "Draw the dashboard again after a session started or stopped."
  (when (get-buffer ecc-dashboard-buffer-name)
    (ecc-dashboard-refresh-agents)
    (ecc-dashboard-redraw)))

(defun ecc-dashboard--poll ()
  "Read the registry again, or stop when the dashboard is gone.
Nothing is read while the dashboard is not shown anywhere."
  (let ((buffer (get-buffer ecc-dashboard-buffer-name)))
    (cond
     ((not (buffer-live-p buffer)) (ecc-dashboard--stop-timer))
     ((null (get-buffer-window buffer t)) nil)
     (t (ecc-dashboard-refresh-agents)
        (ecc-dashboard-redraw)))))

;;;; Commands

(defun ecc-dashboard-entry-at-point ()
  "Return the row at point, or signal an error."
  (let ((entry (tabulated-list-get-id)))
    (unless (ecc-dashboard-entry-p entry)
      (user-error "No session on this line"))
    entry))

(defun ecc-dashboard-session-at-point (&optional open)
  "Return the session of the row at point.
With OPEN, a row that is only a recording is read into a session
first (FR-DASH-3); without it, such a row returns nil."
  (let ((entry (ecc-dashboard-entry-at-point)))
    (or (ecc-dashboard-entry-session entry)
        (ecc-model-session (ecc-dashboard-entry-key entry))
        (when open
          (ecc-history-session (ecc-dashboard-entry-key entry)
                               (ecc-dashboard-entry-file entry))))))

(defun ecc-dashboard-visit ()
  "Open the session at point (FR-DASH-3).
A session of this Emacs shows its buffer.  A recording is read back
into one, at most `ecc-history-page-turns' turns of it.  A session
another process runs has no transcript here, so its recording is shown
read only and R offers to resume it."
  (interactive)
  (let* ((entry (ecc-dashboard-entry-at-point))
         (key (ecc-dashboard-entry-key entry)))
    (pcase (ecc-dashboard-entry-kind entry)
      ('own (let ((session (ecc-dashboard-entry-session entry)))
              (require 'ecc-window)
              (select-window (ecc-display-session session))))
      (_ (if (ecc-history-file key)
             (progn (ecc-history-open key)
                    (when (eq (ecc-dashboard-entry-kind entry) 'external)
                      (message
                       "Session of another process; R stops it and resumes here")))
           (user-error "%s has no recording" key))))))

(defun ecc-dashboard-new (directory)
  "Start a session in DIRECTORY (FR-DASH-5)."
  (interactive (list (read-directory-name "Directory: " (ecc-window-project-root))))
  (require 'ecc)
  (ecc-start directory)
  (ecc-dashboard-redraw))

(defun ecc-dashboard-stop ()
  "Stop the session at point (FR-DASH-5)."
  (interactive)
  (let ((session (or (ecc-dashboard-session-at-point)
                     (user-error "This session does not run in this Emacs"))))
    (require 'ecc)
    (ecc-kill session)
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-delete ()
  "Delete the recording of the session at point, after asking (FR-DASH-5)."
  (interactive)
  (let* ((entry (ecc-dashboard-entry-at-point))
         (file (or (ecc-dashboard-entry-file entry)
                   (ecc-history-file (ecc-dashboard-entry-key entry))
                   (user-error "This session has no recording"))))
    (when (yes-or-no-p (format "Delete %s? " (abbreviate-file-name file)))
      (delete-file file)
      (when-let* ((session (ecc-model-session (ecc-dashboard-entry-key entry))))
        (when (eq (ecc-session-kind session) 'archived)
          (ecc-model-remove-session session)))
      (ecc-dashboard-refresh))))

(defun ecc-dashboard-rename (name)
  "Rename the session at point to NAME (FR-DASH-5)."
  (interactive (list (read-string "New name: ")))
  (let ((session (or (ecc-dashboard-session-at-point)
                     (user-error "This session does not run in this Emacs"))))
    (when (string-empty-p name)
      (user-error "The name may not be empty"))
    (setf (ecc-session-name session) (ecc-model-unique-name name))
    (when (buffer-live-p (ecc-session-buffer session))
      (with-current-buffer (ecc-session-buffer session)
        (rename-buffer (format "*ecc: %s*" (ecc-session-name session)) t)))
    (ecc-dashboard-redraw)))

(defun ecc-dashboard-resume ()
  "Resume the session at point (FR-DASH-3, FR-HIST-3).
A session another process runs has to be stopped there first: two CLIs
on one recording would each write their own version of it, which is
the exclusion of FR-TUI-5."
  (interactive)
  (let ((fork current-prefix-arg))
    ;; A session another process is running is refused by
    ;; `ecc-history-resume' unless the user insists (FR-TUI-5).
    (let ((session (or (ecc-dashboard-session-at-point t)
                       (user-error "This session has no recording"))))
      (ecc-history-resume session fork)
      (require 'ecc-window)
      (select-window (ecc-display-session session))
      (ecc-dashboard-redraw))))

(defun ecc-dashboard--request-at-point ()
  "Return the oldest request of the session at point, or signal an error."
  (let ((session (or (ecc-dashboard-session-at-point)
                     (user-error "This session does not run in this Emacs"))))
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
