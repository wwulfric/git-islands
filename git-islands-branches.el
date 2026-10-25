;;; git-islands-branches.el --- IntelliJ's Git branches popup -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The branches popup, listing actions, recent branches, local and remote
;; ones, each local branch with its distance from upstream.
;; Choosing a branch offers what IntelliJ's branch submenu does.  Commands
;; run through Magit's process buffer, so credential prompts work.
;; `git-islands-widget-current' gives a status bar what to show for the
;; current buffer's branch.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'git-islands-core)
(require 'git-islands-faces)
(require 'git-islands-env)

(declare-function magit-diff-range "magit-diff" (rev-or-range &optional args files))
(autoload 'git-islands-message-focus "git-islands-commit-panel")
(autoload 'git-islands-conflicts-if-any "git-islands-merge")

;;;; Reading branches

(cl-defstruct (git-islands-branch (:constructor git-islands-branch-create))
  "A branch as the popup lists it."
  name        ; short ref name: main, or origin/main for a remote branch
  remote      ; non-nil for a remote-tracking branch
  upstream    ; the local branch's upstream, or nil
  ahead behind
  current)    ; non-nil for the checked-out branch

(defun git-islands-branch-track (track)
  "Return (AHEAD . BEHIND) from TRACK, as `%(upstream:track,nobracket)'."
  (cons (if (string-match "ahead \\([0-9]+\\)" track)
            (string-to-number (match-string 1 track)) 0)
        (if (string-match "behind \\([0-9]+\\)" track)
            (string-to-number (match-string 1 track)) 0)))

(defun git-islands-branches (root)
  "Return ROOT's local branches, then its remote ones."
  (let ((current (car (git-islands-lines root "symbolic-ref" "--quiet" "--short" "HEAD"))))
    (append
     (mapcar (lambda (line)
               (pcase-let* ((`(,name ,upstream ,track) (split-string line "\0"))
                            (`(,ahead . ,behind) (git-islands-branch-track (or track ""))))
                 (git-islands-branch-create :name name
                                            :upstream (unless (string-empty-p upstream) upstream)
                                            :ahead ahead :behind behind
                                            :current (equal name current))))
             (git-islands-lines root "for-each-ref" "--sort=refname"
                                "--format=%(refname:short)%00%(upstream:short)%00%(upstream:track,nobracket)"
                                "refs/heads"))
     (delq nil
           (mapcar (lambda (line)
                     (pcase-let ((`(,name ,symref) (split-string line "\0")))
                       ;; origin/HEAD only points at another remote branch.
                       (when (string-empty-p symref)
                         (git-islands-branch-create :name name :remote t))))
                   (git-islands-lines root "for-each-ref" "--sort=refname"
                                      "--format=%(refname:short)%00%(symref)"
                                      "refs/remotes"))))))

(defun git-islands-recent-branches (root branches &optional limit)
  "Return the local BRANCHES of ROOT checked out most recently, newest first.
The current branch is left out; at most LIMIT, 5 by default, are returned."
  (let ((locals (mapcar #'git-islands-branch-name
                        (seq-remove (lambda (branch)
                                      (or (git-islands-branch-remote branch)
                                          (git-islands-branch-current branch)))
                                    branches)))
        recent)
    (catch 'done
      (dolist (line (git-islands-lines root "reflog" "-n" "500" "--format=%gs"))
        (when (string-match "\\`checkout: moving from \\(.+\\) to " line)
          (let ((name (match-string 1 line)))
            (when (and (member name locals) (not (member name recent)))
              (push name recent)
              (when (>= (length recent) (or limit 5))
                (throw 'done nil)))))))
    (mapcar (lambda (name)
              (seq-find (lambda (branch) (equal (git-islands-branch-name branch) name)) branches))
            (nreverse recent))))

;;;; Popup

(defun git-islands-branch-annotation (branch)
  "Return BRANCH's distance from upstream, dimmed, for the popup."
  (let ((parts (delq nil
                     (list (and (git-islands-branch-current branch) "current")
                           (and (git-islands-branch-ahead branch)
                                (> (git-islands-branch-ahead branch) 0)
                                (format "↑%d" (git-islands-branch-ahead branch)))
                           (and (git-islands-branch-behind branch)
                                (> (git-islands-branch-behind branch) 0)
                                (format "↓%d" (git-islands-branch-behind branch)))
                           (git-islands-branch-upstream branch)))))
    (when parts
      (propertize (concat "  " (string-join parts "  ")) 'face 'git-islands-dim))))

(defconst git-islands-popup-actions
  '(("Update Project…" . git-islands-update-project)
    ("Commit…" . git-islands-popup-commit)
    ("Push…" . git-islands-push-current)
    ("Fetch" . git-islands-fetch)
    ("New Branch…" . git-islands-new-branch)
    ("Checkout Tag or Revision…" . git-islands-checkout-revision))
  "The popup's actions, as (LABEL . FUNCTION called with the root).")

(defun git-islands-popup-candidates (root)
  "Return the popup's candidates for ROOT: strings carrying what they choose."
  (let* ((branches (git-islands-branches root))
         (recent (git-islands-recent-branches root branches))
         (candidates nil))
    (cl-flet ((add (label group value &optional annotation)
                (push (propertize label 'git-islands-group group 'git-islands-value value
                                  'git-islands-annotation annotation)
                      candidates)))
      (dolist (action git-islands-popup-actions)
        (add (car action) "Actions" (cdr action)))
      (dolist (branch recent)
        (add (git-islands-branch-name branch) "Recent" branch
             (git-islands-branch-annotation branch)))
      (dolist (branch (seq-remove (lambda (branch)
                                    (or (git-islands-branch-remote branch) (memq branch recent)))
                                  branches))
        (add (git-islands-branch-name branch) "Local" branch (git-islands-branch-annotation branch)))
      (dolist (branch (seq-filter #'git-islands-branch-remote branches))
        (add (git-islands-branch-name branch) "Remote" branch)))
    (nreverse candidates)))

(defun git-islands-read-candidate (prompt candidates)
  "Read one of CANDIDATES with PROMPT, keeping their order and groups."
  (let* ((table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (display-sort-function . identity)
                        (cycle-sort-function . identity)
                        (group-function
                         . ,(lambda (candidate transform)
                              (if transform candidate
                                (get-text-property 0 'git-islands-group candidate))))
                        (annotation-function
                         . ,(lambda (candidate)
                              (get-text-property 0 'git-islands-annotation candidate))))
                    (complete-with-action action candidates string predicate))))
         (choice (completing-read prompt table nil t)))
    (or (car (member choice candidates))
        (user-error "Nothing chosen"))))

(defun git-islands-popup-root ()
  "Return the repository the popup acts on, or signal an error."
  (or (git-islands-root)
      (when-let* ((directory (git-islands-fallback-directory)))
        (git-islands-root directory))
      (user-error "Not inside a Git repository")))

;;;###autoload
(defun git-islands-branches-popup (&optional root)
  "Show the Git branches popup for ROOT, the current repository by default."
  (interactive)
  (let* ((root (or root (git-islands-popup-root)))
         (status (git-islands-status root))
         (current (or (and status (git-islands-status-branch status))
                      (car (git-islands-lines root "symbolic-ref" "--quiet" "--short" "HEAD"))
                      "detached HEAD"))
         (choice (git-islands-read-candidate (format "Git Branches (on %s): " current)
                                             (git-islands-popup-candidates root)))
         (value (get-text-property 0 'git-islands-value choice)))
    (if (git-islands-branch-p value)
        (git-islands-branch-menu root value current)
      (funcall value root))))

;;;; Branch actions

(defun git-islands-branch-actions (branch current)
  "Return what can be done with BRANCH while CURRENT is checked out.
Each action is (LABEL . FUNCTION called with the root and the branch)."
  (let ((name (git-islands-branch-name branch)))
    (cond
     ((git-islands-branch-current branch)
      `((,(format "New Branch from '%s'…" name) . git-islands-branch-new-from)
        ("Update" . ,(lambda (root _) (git-islands-update-project root)))
        ("Push…" . ,(lambda (root _) (git-islands-push-current root)))
        ("Rename…" . git-islands-branch-rename)))
     ((git-islands-branch-remote branch)
      `(("Checkout" . git-islands-branch-checkout)
        (,(format "New Branch from '%s'…" name) . git-islands-branch-new-from)
        ("Show Diff with Working Tree" . git-islands-branch-diff)
        (,(format "Rebase '%s' onto '%s'" current name) . git-islands-branch-rebase-current)
        (,(format "Merge '%s' into '%s'" name current) . git-islands-branch-merge)
        ("Delete" . git-islands-branch-delete)))
     (t
      `(("Checkout" . git-islands-branch-checkout)
        (,(format "New Branch from '%s'…" name) . git-islands-branch-new-from)
        (,(format "Checkout and Rebase onto '%s'" current) . git-islands-branch-checkout-rebase)
        ("Show Diff with Working Tree" . git-islands-branch-diff)
        (,(format "Rebase '%s' onto '%s'" current name) . git-islands-branch-rebase-current)
        (,(format "Merge '%s' into '%s'" name current) . git-islands-branch-merge)
        ("Rename…" . git-islands-branch-rename)
        ("Delete" . git-islands-branch-delete))))))

(defun git-islands-branch-menu (root branch current)
  "Offer what can be done with BRANCH of ROOT while CURRENT is checked out."
  (let* ((actions (git-islands-branch-actions branch current))
         (choice (git-islands-read-candidate
                  (format "Branch '%s': " (git-islands-branch-name branch))
                  (mapcar (lambda (action)
                            (propertize (car action) 'git-islands-value (cdr action)))
                          actions))))
    (funcall (get-text-property 0 'git-islands-value choice) root branch)))

(defun git-islands-run-then-refresh (root args &optional success)
  "Run Git with ARGS in ROOT; on success call SUCCESS, then refresh ROOT."
  (git-islands-run-async root args
                         (lambda (code)
                           (if (zerop code)
                               (when success (funcall success))
                             (message "git %s failed; see the Git process buffer" (car args))
                             ;; A merge, rebase or cherry-pick may have stopped at conflicts.
                             (git-islands-conflicts-if-any root))
                           (git-islands-refresh root))))

(defun git-islands-branch-checkout (root branch)
  "Check out BRANCH; a remote branch gets a local branch tracking it."
  (let ((name (git-islands-branch-name branch)))
    (if (not (git-islands-branch-remote branch))
        (git-islands-run-then-refresh root (list "checkout" name))
      (let ((local (replace-regexp-in-string "\\`[^/]+/" "" name)))
        (if (member local (git-islands-lines root "for-each-ref" "--format=%(refname:short)"
                                             "refs/heads"))
            (git-islands-run-then-refresh root (list "checkout" local))
          (git-islands-run-then-refresh root (list "checkout" "--track" name)))))))

(defun git-islands-read-new-branch (prompt)
  "Read the name of a branch to create, with PROMPT."
  (let ((name (string-trim (read-string prompt))))
    (when (string-empty-p name) (user-error "Specify a branch name"))
    name))

(defun git-islands-branch-new-from (root branch)
  "Create a branch from BRANCH and check it out."
  (let ((name (git-islands-read-new-branch
               (format "New branch from '%s': " (git-islands-branch-name branch)))))
    (git-islands-run-then-refresh root (list "checkout" "-b" name (git-islands-branch-name branch)))))

(defun git-islands-branch-checkout-rebase (root branch)
  "Check out BRANCH and rebase it onto the current branch."
  (let ((current (car (git-islands-lines root "symbolic-ref" "--quiet" "--short" "HEAD"))))
    (git-islands-run-then-refresh root (list "rebase" current (git-islands-branch-name branch)))))

(defun git-islands-branch-rebase-current (root branch)
  "Rebase the current branch onto BRANCH."
  (git-islands-run-then-refresh root (list "rebase" (git-islands-branch-name branch))))

(defun git-islands-branch-merge (root branch)
  "Merge BRANCH into the current branch."
  (git-islands-run-then-refresh root (list "merge" "--no-edit" (git-islands-branch-name branch))))

(defun git-islands-branch-diff (root branch)
  "Show how the working tree differs from BRANCH."
  (git-islands-magit)
  (let ((default-directory root))
    (git-islands-in-editor #'magit-diff-range (git-islands-branch-name branch))))

(defun git-islands-branch-rename (root branch)
  "Rename the local BRANCH."
  (let* ((old (git-islands-branch-name branch))
         (new (git-islands-read-new-branch (format "Rename '%s' to: " old))))
    (git-islands-run-then-refresh root (list "branch" "-m" old new))))

(defun git-islands-branch-delete (root branch)
  "Delete BRANCH after confirmation; a remote one is deleted on its remote."
  (let ((name (git-islands-branch-name branch)))
    (if (git-islands-branch-remote branch)
        (when (yes-or-no-p (format "Delete remote branch %s? " name))
          (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" name)
          (git-islands-run-then-refresh root (list "push" (match-string 1 name)
                                                   "--delete" (match-string 2 name))))
      (when (yes-or-no-p (format "Delete branch %s? " name))
        (git-islands-run-async
         root (list "branch" "-d" name)
         (lambda (code)
           (when (and (not (zerop code))
                      (yes-or-no-p (format "%s is not fully merged.  Delete it anyway? "
                                           name)))
             (git-islands-run-then-refresh root (list "branch" "-D" name)))
           (git-islands-refresh root)))))))

;;;; Popup actions

(defun git-islands-update-project (root)
  "Pull ROOT's current branch from its upstream, as IntelliJ's Update does."
  (git-islands-run-then-refresh root '("pull") (lambda () (message "Project updated"))))

(defun git-islands-popup-commit (_root)
  "Open the Commit tool window's message."
  (git-islands-message-focus))

(defun git-islands-push-current (root)
  "Push the current branch, setting its upstream on the first push."
  (let* ((status (git-islands-status root))
         (branch (or (and status (git-islands-status-branch status))
                     (car (git-islands-lines root "symbolic-ref" "--quiet" "--short" "HEAD"))
                     (user-error "Cannot push a detached HEAD")))
         (upstream (car (git-islands-lines root "rev-parse" "--abbrev-ref" "--symbolic-full-name"
                                           (concat branch "@{upstream}")))))
    (if upstream
        (git-islands-run-then-refresh root '("push" "-v") (lambda () (message "Pushed %s" branch)))
      (let* ((remotes (or (git-islands-lines root "remote") (user-error "No remote to push to")))
             (remote (if (cdr remotes)
                         (completing-read (format "Push %s to remote: " branch) remotes nil t
                                          nil nil (car (member "origin" remotes)))
                       (car remotes))))
        (git-islands-run-then-refresh root (list "push" "-v" "--set-upstream" remote branch)
                                      (lambda () (message "Pushed %s to %s" branch remote)))))))

(defun git-islands-fetch (root)
  "Fetch every remote of ROOT, pruning deleted branches."
  (git-islands-run-then-refresh root '("fetch" "--all" "--prune") (lambda () (message "Fetched"))))

(defun git-islands-new-branch (root)
  "Create a branch from HEAD and check it out."
  (let ((name (git-islands-read-new-branch "New branch: ")))
    (git-islands-run-then-refresh root (list "checkout" "-b" name))))

(defun git-islands-checkout-revision (root)
  "Check out a tag or revision, detaching HEAD."
  (let* ((tags (git-islands-lines root "tag" "--sort=-creatordate"))
         (revision (completing-read "Checkout tag or revision: " tags)))
    (when (string-empty-p revision) (user-error "Specify a revision"))
    (git-islands-run-then-refresh root (list "checkout" "--detach" revision))))

;;;; Status bar widget

(defvar-local git-islands-widget-root 'unknown
  "The buffer's repository root, nil outside one; `unknown' until looked up.")

(defvar git-islands-widget-stale 5
  "Seconds after which the widget reads an unwatched repository's status again.")

(defvar git-islands-widget-requested (make-hash-table :test #'equal)
  "Repository root to when the widget last asked for its status.")

(defun git-islands-widget-label (status)
  "Return the widget text for snapshot STATUS."
  (concat "⎇ "
          (or (git-islands-status-branch status)
              (let ((head (or (git-islands-status-head status) "")))
                (substring head 0 (min 7 (length head)))))
          (if (> (git-islands-status-ahead status) 0) (format " ↑%d" (git-islands-status-ahead status)) "")
          (if (> (git-islands-status-behind status) 0) (format " ↓%d" (git-islands-status-behind status)) "")))

(defun git-islands-widget-request (root)
  "Read ROOT's status soon, outside redisplay.
At most once per `git-islands-widget-stale' seconds, so a repository whose
status cannot be read is not asked again at every redisplay."
  (let ((last (gethash root git-islands-widget-requested)))
    (unless (and last (< (- (float-time) last) git-islands-widget-stale))
      (puthash root (float-time) git-islands-widget-requested)
      (run-at-time 0 nil (lambda ()
                           (git-islands-status-fetch root (lambda (_) (force-mode-line-update t))))))))

(defun git-islands-widget-current ()
  "Return (ROOT . STATUS) for a status bar's branch widget here, or nil.
STATUS is ROOT's snapshot, read again when it may be stale; nil until
it is first read."
  (when (eq git-islands-widget-root 'unknown)
    (setq git-islands-widget-root (unless (file-remote-p default-directory) (git-islands-root))))
  (when-let* ((root git-islands-widget-root))
    (let ((status (git-islands-status root)))
      (when (or (null status)
                (and (not (gethash root git-islands-watched))
                     (> (- (float-time) (or (git-islands-status-time status) 0))
                        git-islands-widget-stale)))
        (git-islands-widget-request root))
      (when status (cons root status)))))

(defun git-islands-widget-on-status (_root)
  "Redraw the status bar after a snapshot changed."
  (force-mode-line-update t))

(add-hook 'git-islands-status-functions #'git-islands-widget-on-status)

(provide 'git-islands-branches)
;;; git-islands-branches.el ends here
