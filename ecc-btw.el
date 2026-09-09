;;; ecc-btw.el --- Side questions asked beside a running turn  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The `/btw' of the terminal client (FR-BTW-1..4): a question asked on
;; the side, answered without interrupting whatever Claude is doing.
;;
;; It is not a slash command.  The CLI never names it in `commands' or
;; `slash_commands', because the terminal client catches the raw input
;; line with a regexp of its own and never sends it as a prompt.  What it
;; sends instead is a control request, `side_question', on the same
;; stream-json channel `ecc-proc' already speaks -- so ecc needs no
;; second process and no fork of the conversation (docs/verified.md,
;; 2026-09-09; the fork this was first designed around turned out to be
;; the terminal panel's `f' key, not the feature).
;;
;; The CLI does the hard half: the side question shares the messages of
;; the conversation, is answered by a separate lightweight instance with
;; every tool denied, is one-shot, and is left out of the transcript and
;; out of ~/.claude/projects.  What is left for Emacs is the way in
;; (`ecc-btw-intercept' on the prompt region), somewhere to put the
;; answer, and the follow-up context: the CLI threads nothing by itself,
;; so past exchanges go back with the next question in `history'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-markdown)
(require 'ecc-window)

(declare-function ecc-prompt-command-name "ecc-prompt" (text))
(declare-function ecc-prompt-command-argument "ecc-prompt" (text))
(declare-function posframe-workable-p "posframe" ())
(declare-function posframe-show "posframe" (buffer &rest args))
(declare-function posframe-hide "posframe" (buffer))
(declare-function posframe-poshandler-frame-center "posframe" (info))

;;;; Options

(defcustom ecc-btw-display 'window
  "Where the answer to a side question is shown (FR-BTW-3).
`window' puts the buffer in a window.  `posframe' floats it over the
frame instead, which needs the posframe package and a graphical frame;
without either, a window is used and the buffer is the same one."
  :type '(choice (const :tag "A window" window)
                 (const :tag "A frame floating over this one" posframe))
  :group 'ecc)

(defcustom ecc-btw-history-limit 10
  "How many past exchanges go back with the next side question.
The CLI threads nothing by itself, so this is the whole of the context
a follow-up has (FR-BTW-4).  Nil sends none."
  :type '(choice (const :tag "None" nil) integer)
  :group 'ecc)

(defcustom ecc-btw-timeout 120
  "Seconds to wait for the answer to a side question.
Longer than `ecc-control-timeout', which is meant for the control
requests that are answered at once."
  :type 'number
  :group 'ecc)

(defface ecc-btw-question-face
  '((t :inherit ecc-user-face))
  "Face of the question line of an exchange."
  :group 'ecc)

;;;; State, one set per session

(defvar ecc-btw--exchanges (make-hash-table :test #'eq)
  "Hash of a session to its past exchanges, oldest first.
An exchange is a plist of :question, :response, :synthetic, :notice and
:error.  This is the `btwHistory' of the terminal client, and like it
the list lives as long as the session and is not written anywhere.")

(defvar ecc-btw--inflight (make-hash-table :test #'eq)
  "Hash of a session to the side question it is waiting for, or nil.
A plist of :question, :request-id, :status and :timer.")

(defun ecc-btw-exchanges (session)
  "Return the past side questions of SESSION, oldest first."
  (gethash session ecc-btw--exchanges))

(defun ecc-btw-inflight (session)
  "Return the side question SESSION is answering, or nil."
  (gethash session ecc-btw--inflight))

(defun ecc-btw--forget-inflight (session)
  "Drop what SESSION was waiting for, cancelling its timer."
  (when-let* ((inflight (ecc-btw-inflight session)))
    (when-let* ((timer (plist-get inflight :timer)))
      (cancel-timer timer)))
  (remhash session ecc-btw--inflight))

(defun ecc-btw--add-exchange (session exchange)
  "Add EXCHANGE to what SESSION has asked on the side."
  (puthash session (append (gethash session ecc-btw--exchanges) (list exchange))
           ecc-btw--exchanges))

;;;; The buffer

(defvar-local ecc-btw--session nil
  "The session whose side questions this buffer shows.")

(defun ecc-btw-buffer-name (session)
  "Return the name of the buffer showing the side questions of SESSION."
  (format "*ecc-btw: %s*" (ecc-session-name session)))

(defun ecc-btw--session ()
  "Return the session the side questions of this buffer belong to."
  (or ecc-btw--session
      (ecc-window-buffer-session)
      (user-error "No session here to ask beside")))

(defvar ecc-btw-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'ecc-btw-ask-again)
    (define-key map (kbd "c") #'ecc-btw-copy)
    (define-key map (kbd "k") #'ecc-btw-cancel)
    (define-key map (kbd "x") #'ecc-btw-clear)
    (define-key map (kbd "g") #'ecc-btw-refresh)
    (define-key map (kbd "q") #'ecc-btw-hide)
    map)
  "Keymap of `ecc-btw-mode'.")

(define-derived-mode ecc-btw-mode special-mode "Claude-Btw"
  "Major mode showing the side questions of one session (FR-BTW-3).

\\{ecc-btw-mode-map}"
  :interactive nil
  (setq-local truncate-lines nil))

(defun ecc-btw--posframe-p ()
  "Return non-nil when a side answer can be floated over the frame."
  (and (eq ecc-btw-display 'posframe)
       (require 'posframe nil t)
       (posframe-workable-p)))

(defun ecc-btw--exchange-string (exchange)
  "Return EXCHANGE drawn as a question and its answer."
  (let ((error-message (plist-get exchange :error))
        (notice (plist-get exchange :notice)))
    (concat
     (propertize (concat "/btw " (plist-get exchange :question) "\n")
                 'face 'ecc-btw-question-face)
     (when notice
       (propertize (format "The model fell back to %s\n" notice)
                   'face 'ecc-warning-face))
     (if error-message
         (propertize (format "%s\n" error-message) 'face 'ecc-error-face)
       (concat (ecc-markdown-fontify (or (plist-get exchange :response) "")) "\n"))
     (when (plist-get exchange :synthetic)
       ;; The wording is the CLI's own, because it says exactly what
       ;; happened: a side question has no tools, so a model that wanted
       ;; one answered with nothing.
       (propertize
        (concat "(The model tried to call a tool instead of answering"
                " directly. Try rephrasing or ask in the main"
                " conversation.)\n")
        'face 'ecc-dim-face))
     "\n")))

(defun ecc-btw--waiting-string (inflight)
  "Return the line describing INFLIGHT, the question being answered."
  (let ((status (plist-get inflight :status)))
    (concat
     (propertize (concat "/btw " (plist-get inflight :question) "\n")
                 'face 'ecc-btw-question-face)
     (propertize (concat (or status "Answering…") "\n") 'face 'ecc-dim-face)
     "\n")))

(defun ecc-btw-render (session)
  "Return everything SESSION has asked on the side, drawn."
  (let ((exchanges (ecc-btw-exchanges session))
        (inflight (ecc-btw-inflight session)))
    (concat
     (propertize (format "Side questions — %s\n\n" (ecc-session-name session))
                 'face 'ecc-heading-face)
     (if (or exchanges inflight)
         (concat (mapconcat #'ecc-btw--exchange-string exchanges "")
                 (if inflight (ecc-btw--waiting-string inflight) ""))
       (propertize
        (concat "Nothing asked yet. Type /btw and a question in the prompt"
                " region;\nthe turn that is running is not interrupted.\n")
        'face 'ecc-dim-face)))))

(defun ecc-btw--draw (session)
  "Draw the side questions of SESSION, if their buffer is there."
  (when-let* ((buffer (get-buffer (ecc-btw-buffer-name session))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (eobp)))
        (erase-buffer)
        (insert (ecc-btw-render session))
        (when at-end (goto-char (point-max)))))
    (when (and (ecc-btw--posframe-p) (get-buffer-window buffer t))
      (ecc-btw--show-posframe buffer))
    buffer))

(defun ecc-btw--show-posframe (buffer)
  "Float BUFFER over the frame.
A child frame takes no focus of its own, so the keys of the side
question buffer are lent to the frame the user is really in until one
of them is done with."
  (posframe-show buffer
                 :poshandler #'posframe-poshandler-frame-center
                 :internal-border-width 1
                 :internal-border-color (face-foreground 'shadow nil t)
                 :accept-focus nil
                 :hidehandler nil)
  (set-transient-map
   ecc-btw-mode-map
   (lambda () (memq this-command '(ecc-btw-refresh ecc-btw-copy)))
   #'ecc-btw-hide))

(defun ecc-btw-buffer (session)
  "Return the buffer showing the side questions of SESSION, making it once."
  (let ((buffer (get-buffer-create (ecc-btw-buffer-name session))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecc-btw-mode)
        (ecc-btw-mode))
      (setq ecc-btw--session session))
    buffer))

;;;###autoload
(defun ecc-btw-show (&optional session)
  "Show what SESSION has asked on the side, where the settings say.
Called interactively it opens the side questions of the session this
buffer talks to (FR-WIN-4), without asking anything: the panel is worth
looking at on its own, to read an answer again or to ask the next one
with \\[ecc-btw-ask-again]."
  (interactive (list (ecc-window-resolve-session current-prefix-arg)))
  (let* ((session (or session (ecc-btw--session)))
         (buffer (ecc-btw-buffer session)))
    (ecc-btw--draw session)
    (if (ecc-btw--posframe-p)
        (ecc-btw--show-posframe buffer)
      (display-buffer buffer))
    buffer))

;;;; Asking (FR-BTW-1, 4)

(defun ecc-btw--history (session)
  "Return the past exchanges of SESSION as the CLI wants them.
A vector, because `json-serialize' writes a list as an object; the last
`ecc-btw-history-limit' of them, because the whole point of a side
question is that it is cheap.  An exchange that failed is left out: it
has no answer to thread."
  (let* ((answered (seq-filter (lambda (exchange)
                                 (and (null (plist-get exchange :error))
                                      (plist-get exchange :response)))
                               (ecc-btw-exchanges session)))
         (kept (if (and ecc-btw-history-limit
                        (> (length answered) ecc-btw-history-limit))
                   (last answered ecc-btw-history-limit)
                 (and ecc-btw-history-limit answered))))
    (vconcat
     (mapcar (lambda (exchange)
               (append
                (list (cons 'question (plist-get exchange :question))
                      (cons 'response (plist-get exchange :response)))
                (when-let* ((notice (plist-get exchange :notice)))
                  (list (cons 'fallback_notice notice)))))
             kept))))

(defun ecc-btw--fallback-notice (response)
  "Return what RESPONSE says about a model fallback, or nil."
  (when-let* ((fallback (alist-get 'refusal_fallback response)))
    (format "%s (from %s)"
            (or (alist-get 'fallback_model fallback) "another model")
            (or (alist-get 'original_model fallback) "the session model"))))

(defun ecc-btw--receive (session response)
  "Take RESPONSE, the answer SESSION gave to the side question it was asked."
  (let ((question (plist-get (ecc-btw-inflight session) :question)))
    (ecc-btw--forget-inflight session)
    (if-let* ((error-message (alist-get 'error response)))
        (progn
          (ecc-log (ecc-session-name session) "side question failed: %s"
                   error-message)
          (ecc-btw--add-exchange
           session (list :question question
                         :error (format "The side question failed: %s"
                                        (if (eq error-message t)
                                            "no reason given"
                                          error-message)))))
      (ecc-btw--add-exchange
       session (list :question question
                     :response (alist-get 'response response)
                     :synthetic (eq (alist-get 'synthetic response) t)
                     :notice (ecc-btw--fallback-notice response))))
    (ecc-btw--draw session)))

(defun ecc-btw--progress (session request-id message)
  "Note the progress MESSAGE about REQUEST-ID of SESSION."
  (let ((inflight (ecc-btw-inflight session)))
    (when (and inflight (equal request-id (plist-get inflight :request-id)))
      (plist-put inflight :status
                 (if (equal (alist-get 'status message) "api_retry")
                     (format "The API asked to wait — retrying (attempt %s/%s)"
                             (or (alist-get 'attempt message) "?")
                             (or (alist-get 'max_retries message) "?"))
                   "Answering…"))
      (ecc-btw--draw session))))

(add-hook 'ecc-control-progress-hook #'ecc-btw--progress)

(defun ecc-btw--time-out (session request-id)
  "Give up on REQUEST-ID of SESSION and say so.
`ecc-proc-control' only logs a timeout and forgets the callback, which
would leave the question saying \"Answering…\" for good."
  (let ((inflight (ecc-btw-inflight session)))
    (when (and inflight (equal request-id (plist-get inflight :request-id)))
      (ecc-log (ecc-session-name session) "side question %s timed out"
               request-id)
      (ecc-btw--forget-inflight session)
      (ecc-btw--add-exchange
       session (list :question (plist-get inflight :question)
                     :error (format "No answer after %s seconds."
                                    ecc-btw-timeout)))
      (ecc-btw--draw session))))

;;;###autoload
(defun ecc-btw-ask (session question)
  "Ask QUESTION of SESSION on the side, without interrupting it (FR-BTW-1).
The turn that is running is left alone: the CLI answers a side question
with a separate lightweight instance that shares the conversation but
has no tools, and neither the question nor the answer reaches the
transcript.  Returns the request id."
  (interactive (list (ecc-btw--session) (read-string "Side question: ")))
  (let ((question (string-trim (or question ""))))
    (when (string-empty-p question)
      (user-error "Usage: /btw <your question>"))
    (when (ecc-btw-inflight session)
      (user-error "A side question is already being answered; k cancels it"))
    (let* ((history (ecc-btw--history session))
           (request-id
            ;; The timeout of a control request is read when it is sent,
            ;; so binding it here is enough; the timer it starts only
            ;; logs, which is why there is one below as well.
            (let ((ecc-control-timeout ecc-btw-timeout))
              (apply #'ecc-proc-control session "side_question"
                     #'ecc-btw--receive
                     'question question
                     (unless (seq-empty-p history) (list 'history history))))))
      (puthash session
               (list :question question :request-id request-id
                     :status "Answering…"
                     :timer (run-at-time (+ ecc-btw-timeout 1) nil
                                         #'ecc-btw--time-out session
                                         request-id))
               ecc-btw--inflight)
      (ecc-btw-show session)
      request-id)))

;;;; Commands of the buffer

(defun ecc-btw-ask-again (question)
  "Ask QUESTION of the session this buffer belongs to."
  (interactive (list (read-string "Side question: ")))
  (ecc-btw-ask (ecc-btw--session) question))

(defun ecc-btw-cancel ()
  "Stop waiting for the side question that is being answered."
  (interactive)
  (let* ((session (ecc-btw--session))
         (inflight (or (ecc-btw-inflight session)
                       (user-error "No side question is being answered"))))
    (ecc-proc-cancel-control session (plist-get inflight :request-id))
    (ecc-btw--forget-inflight session)
    (ecc-btw--add-exchange session (list :question (plist-get inflight :question)
                                         :error "Cancelled."))
    (ecc-btw--draw session)))

(defun ecc-btw-copy ()
  "Copy the last answer to the kill ring."
  (interactive)
  (let* ((session (ecc-btw--session))
         (exchange (car (last (ecc-btw-exchanges session))))
         (response (and exchange (plist-get exchange :response))))
    (unless response
      (user-error "No answer to copy"))
    (kill-new (substring-no-properties response))
    (message "Copied the answer")))

(defun ecc-btw-clear ()
  "Forget the side questions of this session.
They are the whole context a follow-up has (FR-BTW-4), so this starts
the next one afresh."
  (interactive)
  (let ((session (ecc-btw--session)))
    (remhash session ecc-btw--exchanges)
    (ecc-btw--draw session)))

(defun ecc-btw-refresh ()
  "Draw the side questions again."
  (interactive)
  (ecc-btw--draw (ecc-btw--session)))

(defun ecc-btw-hide ()
  "Take the side questions off the screen."
  (interactive)
  (when-let* ((buffer (if (derived-mode-p 'ecc-btw-mode)
                          (current-buffer)
                        (get-buffer (ecc-btw-buffer-name (ecc-btw--session))))))
    (when (and (fboundp 'posframe-hide) (featurep 'posframe))
      (posframe-hide buffer))
    (when-let* ((window (get-buffer-window buffer)))
      (quit-window nil window))))

;;;; The way in: /btw in the prompt region (FR-BTW-1)

(defconst ecc-btw-command "/btw"
  "The word that turns a draft into a side question.")

(defun ecc-btw-intercept (session text)
  "Take TEXT for SESSION as a side question when it says /btw.
Returns non-nil when it did, which is what keeps the draft from being
sent as a prompt.  This is on `ecc-prompt-intercept-functions'."
  (when (equal (ecc-prompt-command-name text) ecc-btw-command)
    (let ((question (ecc-prompt-command-argument text)))
      (cond
       ((not (or (null question) (string-empty-p (string-trim question))))
        (ecc-btw-ask session question))
       ;; A bare /btw opens the panel on what has been asked already,
       ;; which is what the terminal client does with one: the question
       ;; being answered if there is one, else the last answer.  Only
       ;; with nothing to show at all is it a usage message.
       ((or (ecc-btw-inflight session) (ecc-btw-exchanges session))
        (ecc-btw-show session))
       (t (message "Usage: /btw <your question>")))
      t)))

(with-eval-after-load 'ecc-prompt
  (add-hook 'ecc-prompt-intercept-functions #'ecc-btw-intercept))

(provide 'ecc-btw)

;;; ecc-btw.el ends here
