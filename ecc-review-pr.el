;;; ecc-review-pr.el --- Review a GitHub pull request  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Maintainer: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; URL: https://github.com/wakamenod/emacs-claude-code
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `p' in `ecc-review-menu' reviews a pull request of GitHub.  The `gh'
;; CLI is asked which pull requests there are and what their two sides
;; are -- and only then, when `p' is pressed: the menu offers `p' when
;; gh is installed and asks nothing of it.  gh is no dependency, and
;; what it says when it fails -- not logged in, no GitHub remote -- is
;; what the user is told.
;;
;; The question offers the open pull requests, gh's first page, and
;; before them a choice that searches; words typed that are no line
;; and no number search as well, in GitHub's syntax, open, closed and
;; merged ones alike.  gh runs when the answer is given, not as it is
;; typed: `completing-read' has no way to change its candidates while
;; it waits, and `ecc-review-pr--complete', the one place the question
;; is put, is what a search as one types would take the place of.
;;
;; The diff is made by the local git, from the commits gh names: what a
;; review shows on the left and on the right are whole files, which a
;; patch from `gh pr diff' does not have.  A pull request of another
;; branch is BASE...HEAD by id, the files GitHub shows as changed, and
;; one whose head is the branch checked out here is that branch with
;; its working tree against where it parted from the base, as `b' of the
;; current branch is: Claude edits the files on disk, and the comments
;; have to be on their lines.  The commits are fetched only when this
;; repository does not have them, into FETCH_HEAD alone: no branch, no
;; ref, and the working tree and HEAD are not touched.

;;; Code:

(require 'seq)
(require 'ecc-core)
(require 'ecc-review)

(defvar ecc-review-gh-executable "gh"
  "The gh program `p' in `ecc-review-menu' asks for pull requests.")

(defvar ecc-review-pr-fields
  "number,title,state,headRefName,baseRefName,headRefOid,baseRefOid,author,isDraft,isCrossRepository,url"
  "The fields of a pull request asked of gh, as its --json takes them.")

(defvar ecc-review-pr-search-label "Search pull requests…"
  "The choice of `p' in `ecc-review-menu' that asks for words to search with.")

(defvar ecc-review-pr--history nil
  "Pull requests typed at the question of `p'.")

(defvar ecc-review-pr--search-history nil
  "Searches typed at the question of `p'.")

(defun ecc-review-pr-available-p ()
  "Return non-nil when gh is installed, so that `p' is offered."
  (executable-find ecc-review-gh-executable))

;;;; Running gh and git

(defun ecc-review-pr--run (program directory &rest args)
  "Run PROGRAM with ARGS in DIRECTORY and return what it prints.
A failure is a `user-error' carrying what PROGRAM said on stderr.
Neither program may ask anything: there is no terminal to answer on."
  (let ((stderr (make-temp-file "ecc-review-pr"))
        (process-environment (append '("GH_PROMPT_DISABLED=1" "GH_NO_UPDATE_NOTIFIER=1"
                                       "NO_COLOR=1" "GIT_TERMINAL_PROMPT=0")
                                     process-environment))
        (default-directory (file-name-as-directory directory))
        ;; gh prints its JSON in UTF-8 whatever the locale says, and a
        ;; GUI Emacs started without LANG would read a Japanese title
        ;; through another coding system.
        (coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8))
    (unwind-protect
        (with-temp-buffer
          (let ((code (condition-case err
                          (apply #'call-process program nil (list t stderr) nil args)
                        (file-error
                         (user-error "Cannot run %s: %s" program (error-message-string err))))))
            (unless (eq code 0)
              (user-error "%s %s failed: %s" (file-name-nondirectory program)
                          (string-join args " ")
                          (let ((said (string-trim (with-temp-buffer
                                                     (insert-file-contents stderr)
                                                     (buffer-string)))))
                            (if (string-empty-p said) (format "exit %s" code) said))))
            (buffer-string)))
      (delete-file stderr))))

(defun ecc-review-pr--gh (root &rest args)
  "Run gh with ARGS in ROOT and return what it prints."
  (apply #'ecc-review-pr--run ecc-review-gh-executable root args))

;;;; What gh says

(defun ecc-review-pr--parse-one (object)
  "Return the pull request OBJECT of gh's JSON as a plist.
:number, :title, :state (`open', `closed' or `merged'), :head and
:base (the branch names), :head-oid and :base-oid, :author (a login),
:draft, :cross (the head is in another repository) and :url."
  (let ((get (lambda (key) (plist-get object key))))
    (list :number (funcall get :number)
          :title (or (funcall get :title) "")
          :state (when-let* ((state (funcall get :state)))
                   (intern (downcase state)))
          :head (funcall get :headRefName)
          :base (funcall get :baseRefName)
          :head-oid (funcall get :headRefOid)
          :base-oid (funcall get :baseRefOid)
          :author (plist-get (funcall get :author) :login)
          :draft (eq (funcall get :isDraft) t)
          :cross (eq (funcall get :isCrossRepository) t)
          :url (funcall get :url))))

(defun ecc-review-pr-parse (json)
  "Return the pull requests JSON, what gh prints, names: a list of plists.
JSON is an array of them or one; see `ecc-review-pr--parse-one'."
  (let ((value (json-parse-string json :object-type 'plist :array-type 'list
                                  :null-object nil :false-object :false)))
    (mapcar #'ecc-review-pr--parse-one
            (if (and (consp value) (keywordp (car value))) (list value) value))))

(defun ecc-review-pr-list (root)
  "Return the open pull requests of the repository of ROOT, as gh orders them."
  (ecc-review-pr-parse (ecc-review-pr--gh root "pr" "list" "--json" ecc-review-pr-fields)))

(defun ecc-review-pr-search (root query)
  "Return the pull requests of the repository of ROOT that QUERY finds.
QUERY is in GitHub's search syntax, and open, closed and merged ones
alike are found, as gh orders them."
  (ecc-review-pr-parse (ecc-review-pr--gh root "pr" "list" "--search" query
                                          "--state" "all" "--json" ecc-review-pr-fields)))

(defun ecc-review-pr-view (root number)
  "Return the pull request NUMBER of the repository of ROOT, open or not."
  (car (ecc-review-pr-parse (ecc-review-pr--gh root "pr" "view" (number-to-string number)
                                               "--json" ecc-review-pr-fields))))

;;;; Asking which

(defun ecc-review-pr-line (pr)
  "Return PR as a line to choose: number, state, title, branches and author.
The state is said when the pull request is closed or merged.  The title
is put on one line: a tab or a newline in it would break the list."
  (format "#%d  %s%s%s  %s → %s  @%s"
          (plist-get pr :number)
          (pcase (plist-get pr :state)
            ('merged "[merged] ")
            ('closed "[closed] ")
            (_ ""))
          (if (plist-get pr :draft) "[draft] " "")
          (ecc--truncate (string-trim (replace-regexp-in-string
                                       "[ \t\n\r]+" " " (plist-get pr :title)))
                         72)
          (plist-get pr :head) (plist-get pr :base)
          (or (plist-get pr :author) "?")))

(defun ecc-review-pr-own-p (pr branch)
  "Return non-nil when PR is of BRANCH, the branch checked out here.
Its head has that name and is in this repository, not in a fork: the
main of a fork is not the main checked out here.  A closed or merged
pull request is what it was, BASE...HEAD, whatever is checked out now:
a branch of that name may be newer work, or the next pull request."
  (and branch
       (equal (plist-get pr :head) branch)
       (not (plist-get pr :cross))
       (memq (plist-get pr :state) '(nil open))))

(defun ecc-review-pr-default (prs branch)
  "Return the one of PRS that is of BRANCH (`ecc-review-pr-own-p'), or nil."
  (seq-find (lambda (pr) (ecc-review-pr-own-p pr branch)) prs))

(defun ecc-review-pr-choose (root answer prs)
  "Return the pull request ANSWER names in ROOT, PRS being those offered.
A line of PRS is that one; a number, with or without #, is the one of
PRS of that number, or asked of gh -- a closed or merged one need not
be listed.  `ecc-review-pr-search-label' is (search), and other words
are (search . WORDS), to be searched for."
  (save-match-data
    (let ((answer (string-trim answer)))
      (cond ((string-empty-p answer)
             (user-error "Choose a pull request, type its number or words to search"))
            ((equal answer ecc-review-pr-search-label) (list 'search))
            ((seq-find (lambda (pr) (equal (ecc-review-pr-line pr) answer)) prs))
            ((string-match "\\`#?\\([0-9]+\\)\\'" answer)
             (let ((number (string-to-number (match-string 1 answer))))
               (or (seq-find (lambda (pr) (eql (plist-get pr :number) number)) prs)
                   (ecc-review-pr-view root number))))
            (t (cons 'search answer))))))

(defun ecc-review-pr--complete (prompt prs default table-function)
  "Ask with PROMPT for one of PRS and return the answer, a string.
DEFAULT, a line, is taken on an empty answer, and
`ecc-review-pr-search-label' comes first; TABLE-FUNCTION makes the
completion table of the lines, in their order.  This is the one place
the question is put, for one that searches as the words are typed to
take."
  (let ((lines (cons ecc-review-pr-search-label (mapcar #'ecc-review-pr-line prs))))
    (completing-read prompt (if table-function (funcall table-function lines) lines)
                     nil nil nil 'ecc-review-pr--history default)))

(defun ecc-review-pr--read-query ()
  "Ask for the words to search pull requests with."
  (read-string "Search pull requests (GitHub search: is:merged, author:NAME, label:NAME…): "
               nil 'ecc-review-pr--search-history))

(defun ecc-review-pr-read (root branch &optional table-function)
  "Ask for a pull request of the repository of ROOT and return it.
The open ones are offered as gh lists them, the one of BRANCH, the
branch checked out, by default, after `ecc-review-pr-search-label'.
That, or words that are no line and no number, search open, closed and
merged ones alike (`ecc-review-pr-search'), and what is found is
offered the same way; a search that finds nothing says so and the
question is put again.  gh runs only on an answer, never on a key.
TABLE-FUNCTION makes the completion table of the lines, in their
order."
  (let ((prs (ecc-review-pr-list root))
        (query nil)
        (missed nil)
        (chosen nil))
    (while (not chosen)
      (let* ((default (when-let* ((pr (ecc-review-pr-default prs branch)))
                        (ecc-review-pr-line pr)))
             (prompt (cond (missed
                            (format-prompt "No pull request matches \"%s\"; search again or choose"
                                           default missed))
                           (query
                            (format-prompt "Pull requests matching \"%s\"" default query))
                           (prs
                            (format-prompt "Review the pull request (or its number, or words)"
                                           default))
                           (t "No open pull request; type a number or words to search: ")))
             (answer (ecc-review-pr-choose
                      root (ecc-review-pr--complete prompt prs default table-function) prs)))
        (setq missed nil)
        (if (not (eq (car-safe answer) 'search))
            (setq chosen answer)
          (let ((words (string-trim (or (cdr answer) (ecc-review-pr--read-query)))))
            (unless (string-empty-p words)
              (let ((found (ecc-review-pr-search root words)))
                (if found
                    (setq prs found query words)
                  (setq missed words))))))))
    chosen))

;;;; Having the commits

(defun ecc-review-pr--has-commit-p (root oid)
  "Return non-nil when the repository of ROOT has the commit OID."
  (eq 0 (car (ecc-review--git root "cat-file" "-e" (concat oid "^{commit}")))))

(defun ecc-review-pr--repo-of-url (url)
  "Return (HOST . OWNER/REPO) of URL, a remote or a pull request, lowercased.
git@host:o/r.git, ssh://git@host/o/r, https://host/o/r(.git) and
https://host/o/r/pull/N all come out the same; a path names no host,
and its last two directories are OWNER/REPO.  Nil when there are not
two."
  (save-match-data
    (let* ((url (downcase (string-trim url)))
           (host (cond ((string-match "\\`[a-z][a-z0-9+.-]*://\\(?:[^@/]*@\\)?\\([^/:]+\\)" url)
                        (match-string 1 url))
                       ((string-match "\\`\\(?:[^@/]*@\\)?\\([^/:]+\\):" url)
                        (match-string 1 url))))
           (path (replace-regexp-in-string "/pull/[0-9]+.*\\'" "" url))
           (parts (last (split-string (string-remove-suffix
                                       ".git" (string-remove-suffix "/" path))
                                      "[/:]" t)
                        2)))
      (when (= (length parts) 2)
        (cons host (string-join parts "/"))))))

(defun ecc-review-pr-remote (root url)
  "Return the remote of ROOT that is the repository of the pull request URL.
The one whose URL names the same owner and repository on the same host,
else the same owner and repository, else URL's repository itself, to be
fetched from by its address."
  (let* ((want (or (ecc-review-pr--repo-of-url url)
                   (user-error "Cannot tell the repository of %s" url)))
         (remotes (pcase (ecc-review--git root "config" "--get-regexp"
                                          "^remote\\..*\\.url$")
                    (`(0 . ,output)
                     (mapcar (lambda (line)
                               (let ((pair (split-string line " ")))
                                 (cons (replace-regexp-in-string
                                        "\\`remote\\.\\|\\.url\\'" "" (car pair))
                                       (ecc-review-pr--repo-of-url
                                        (string-join (cdr pair) " ")))))
                             (split-string output "\n" t)))))
         (same (seq-filter (lambda (remote) (equal (cddr remote) (cdr want))) remotes)))
    (or (car (seq-find (lambda (remote) (equal (cadr remote) (car want))) same))
        (car (car same))
        (format "https://%s/%s.git" (car want) (cdr want)))))

(defun ecc-review-pr-fetch (root pr oids)
  "Make sure the repository of ROOT has OIDS, the commits of PR it needs.
Only what is missing is fetched, from its repository
\(`ecc-review-pr-remote') into FETCH_HEAD alone: refs/pull/N/head for
the head -- there for a pull request from a fork as well -- and then,
when the base is still missing, the base branch, whose commit is often
one the head brought along.  The base branch of a merged pull request
may have been deleted since; that fetch failing is an error only when
the base is still missing after it, and the error says what git said.
--refmap= keeps git from moving the remote-tracking branch of the base
on the way.  Return non-nil when something was fetched."
  (when (seq-remove (lambda (oid) (ecc-review-pr--has-commit-p root oid)) oids)
    (let* ((number (plist-get pr :number))
           (remote (ecc-review-pr-remote root (plist-get pr :url)))
           (missing (lambda (key)
                      (let ((oid (plist-get pr key)))
                        (and (member oid oids) (not (ecc-review-pr--has-commit-p root oid))))))
           (fetch (lambda (refspec)
                    (ecc-review-pr--run ecc-review-git-executable root
                                        "fetch" "--quiet" "--no-tags" "--recurse-submodules=no"
                                        "--refmap=" remote refspec)))
           (failed nil))
      (message "Fetching pull request #%d from %s..." number remote)
      (when (funcall missing :head-oid)
        (funcall fetch (format "pull/%d/head" number)))
      (when (funcall missing :base-oid)
        (condition-case err
            (funcall fetch (plist-get pr :base))
          (user-error (setq failed (error-message-string err)))))
      (dolist (oid oids)
        (unless (ecc-review-pr--has-commit-p root oid)
          (user-error "Pull request #%d: %s is not in %s even after fetching it%s"
                      number oid remote (if failed (concat "; " failed) ""))))
      t)))

;;;; What a pull request compares

(defun ecc-review-pr-range (root pr branch)
  "Return (RANGE . LABEL), what a review of PR in ROOT compares and is called.
BRANCH is the branch checked out.  PR of BRANCH (`ecc-review-pr-own-p')
is the working tree against where HEAD parted from the base of PR, as
`b' of the current branch reviews it: what is pushed and what is not,
on the lines of the files Claude edits.  Any other PR is BASE...HEAD by
their ids, what GitHub shows as its files changed; its right side is
not on disk, and the review says so (`ecc-review-elsewhere').  The
commits are fetched first if need be (`ecc-review-pr-fetch')."
  (let ((number (plist-get pr :number))
        (base-oid (plist-get pr :base-oid))
        (head-oid (plist-get pr :head-oid)))
    (unless (and (stringp base-oid) (stringp head-oid))
      (user-error "gh named no commits for pull request #%s" number))
    (if (ecc-review-pr-own-p pr branch)
        (progn
          (ecc-review-pr-fetch root pr (list base-oid))
          ;; Called as `b' calls the same commit, not after the pull
          ;; request: the review is named by what it compares, and `b'
          ;; and `p' of one fork are one review in one buffer, whichever
          ;; opened it first.
          (cons (or (ecc-review--merge-base root base-oid "HEAD")
                    (user-error "Pull request #%d: %s and HEAD have no commit in common"
                                number (plist-get pr :base)))
                (format "%s + working tree" (plist-get pr :base))))
      (ecc-review-pr-fetch root pr (list base-oid head-oid))
      (ecc-review-name-side root head-oid (plist-get pr :head))
      (cons (format "%s...%s" base-oid head-oid)
            (format "PR #%d %s" number
                    (ecc--truncate (string-trim (replace-regexp-in-string
                                                 "[ \t\n\r]+" " " (plist-get pr :title)))
                                   48))))))

(provide 'ecc-review-pr)

;;; ecc-review-pr.el ends here
