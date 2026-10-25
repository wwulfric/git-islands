;;; git-islands-core.el --- Repository state shared by the Git tool windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The one place the Git tool windows talk to Magit.  Views read a cached
;; snapshot of `git status' and subscribe to `git-islands-status-functions';
;; they change the repository only through the commands below, so a Magit
;; upgrade that renames an internal function is fixed here alone.
;;
;; A snapshot is refreshed asynchronously, at most once per debounce
;; interval, when Magit refreshes, when a file in the repository is saved,
;; or when the Git directory changes on disk (a commit made in a terminal).
;; Status runs with --no-optional-locks, so reading it never rewrites the
;; index and wakes the watch again.
;;
;; Reading needs only Git, so a file tree or a status bar can use it from
;; startup; Magit loads when a command first changes the repository.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)

(declare-function magit-run-git-async "magit-process" (&rest args))
(declare-function magit-run-git "magit-process" (&rest args))
(declare-function magit-stage-files "magit-apply" (files &optional force))
(declare-function magit-unstage-files "magit-apply" (files))
(declare-function magit-status-setup-buffer "magit-status" (&optional directory))
(declare-function magit-git-executable "magit-git" ())

(defun git-islands-magit ()
  "Load Magit, which every command changing a repository goes through."
  (require 'magit))

;;;; Snapshot

(cl-defstruct (git-islands-entry (:constructor git-islands-entry-create))
  "One path in a status snapshot."
  path        ; relative to the repository root
  orig        ; the path it was renamed or copied from, or nil
  index       ; status letter in the index: ?. ?M ?A ?D ?R ?C ?T ?U
  worktree    ; status letter in the working tree
  kind)       ; `changed', `untracked' or `unmerged'

(cl-defstruct (git-islands-status (:constructor git-islands-status-create))
  "A repository's state, read with one `git status --porcelain=v2'."
  root head branch upstream (ahead 0) (behind 0) entries
  state       ; nil, or `merge', `rebase', `cherry-pick' or `revert'
  time)       ; when it was read, as a float time

(defun git-islands-status-parse (output)
  "Parse OUTPUT of `git status --porcelain=v2 -z --branch' into a snapshot.
The snapshot has no root or state; `git-islands-status-fetch' adds them."
  (let ((items (split-string output "\0" t))
        (status (git-islands-status-create))
        entries)
    (while items
      (let ((item (pop items)))
        (pcase (aref item 0)
          (?#
           (pcase (split-string item " ")
             (`(,_ "branch.oid" ,oid)
              (setf (git-islands-status-head status) (unless (equal oid "(initial)") oid)))
             (`(,_ "branch.head" ,head)
              (setf (git-islands-status-branch status) (unless (equal head "(detached)") head)))
             (`(,_ "branch.upstream" ,upstream)
              (setf (git-islands-status-upstream status) upstream))
             (`(,_ "branch.ab" ,ahead ,behind)
              (setf (git-islands-status-ahead status) (abs (string-to-number ahead))
                    (git-islands-status-behind status) (abs (string-to-number behind))))))
          ;; Ordinary change: 1 XY sub mH mI mW hH hI path
          (?1 (let ((fields (split-string item " " nil)))
                (push (git-islands-entry-create
                       :path (string-join (nthcdr 8 fields) " ")
                       :index (aref (nth 1 fields) 0)
                       :worktree (aref (nth 1 fields) 1)
                       :kind 'changed)
                      entries)))
          ;; Rename or copy: 2 XY sub mH mI mW hH hI Xscore path, then origPath.
          (?2 (let ((fields (split-string item " " nil)))
                (push (git-islands-entry-create
                       :path (string-join (nthcdr 9 fields) " ")
                       :orig (pop items)
                       :index (aref (nth 1 fields) 0)
                       :worktree (aref (nth 1 fields) 1)
                       :kind 'changed)
                      entries)))
          ;; Unmerged: u XY sub m1 m2 m3 mW h1 h2 h3 path
          (?u (let ((fields (split-string item " " nil)))
                (push (git-islands-entry-create
                       :path (string-join (nthcdr 10 fields) " ")
                       :index (aref (nth 1 fields) 0)
                       :worktree (aref (nth 1 fields) 1)
                       :kind 'unmerged)
                      entries)))
          (?? (push (git-islands-entry-create :path (substring item 2)
                                              :index ?. :worktree ?? :kind 'untracked)
                    entries)))))
    (setf (git-islands-status-entries status) (nreverse entries))
    status))

(defun git-islands-entry-staged-p (entry)
  "Return non-nil if ENTRY has changes in the index."
  (and (eq (git-islands-entry-kind entry) 'changed)
       (not (eq (git-islands-entry-index entry) ?.))))

(defun git-islands-entry-unstaged-p (entry)
  "Return non-nil if ENTRY has changes the index does not have."
  (pcase (git-islands-entry-kind entry)
    ('changed (not (eq (git-islands-entry-worktree entry) ?.)))
    (_ t)))

(defun git-islands-entry-change (entry)
  "Return how ENTRY changed, as one of `modified', `added', `deleted',
`renamed', `untracked' or `conflict'.  The index wins over the tree, as in
IntelliJ's Changes view: a staged new file is added even when edited since."
  (pcase (git-islands-entry-kind entry)
    ('untracked 'untracked)
    ('unmerged 'conflict)
    (_ (let ((letter (if (eq (git-islands-entry-index entry) ?.)
                         (git-islands-entry-worktree entry)
                       (git-islands-entry-index entry))))
         (pcase letter
           (?A 'added) (?D 'deleted) ((or ?R ?C) 'renamed) (_ 'modified))))))

;;;; Repositories

(defun git-islands-root (&optional directory)
  "Return the root of the repository containing DIRECTORY, or nil.
DIRECTORY defaults to `default-directory'.  A worktree or submodule has a
.git file instead of a folder; both count."
  (when-let* ((root (locate-dominating-file (or directory default-directory) ".git")))
    (file-name-as-directory (expand-file-name root))))

(defun git-islands-gitdir (root &optional common)
  "Return ROOT's Git directory, or with COMMON the one its worktrees share."
  (let* ((dot (expand-file-name ".git" root))
         (gitdir (if (file-directory-p dot)
                     dot
                   (with-temp-buffer
                     (insert-file-contents dot)
                     (when (re-search-forward "^gitdir: *\\(.+\\)$" nil t)
                       (expand-file-name (match-string 1) root))))))
    (file-name-as-directory
     (or (and common gitdir
              (let ((file (expand-file-name "commondir" gitdir)))
                (when (file-exists-p file)
                  (with-temp-buffer
                    (insert-file-contents file)
                    (expand-file-name (string-trim (buffer-string)) gitdir)))))
         gitdir))))

(defun git-islands-state (root)
  "Return the operation in progress in ROOT, or nil."
  (let ((gitdir (git-islands-gitdir root)))
    (cl-flet ((has (name) (file-exists-p (expand-file-name name gitdir))))
      (cond ((or (has "rebase-merge") (has "rebase-apply")) 'rebase)
            ((has "MERGE_HEAD") 'merge)
            ((has "CHERRY_PICK_HEAD") 'cherry-pick)
            ((has "REVERT_HEAD") 'revert)))))

(defun git-islands-executable ()
  "Return the Git program, as Magit runs it once Magit is loaded."
  (if (fboundp 'magit-git-executable) (magit-git-executable) "git"))

(defun git-islands-command (&rest args)
  "Return the command line running Git with ARGS."
  (append (list (git-islands-executable) "--no-pager" "-c" "color.ui=false")
          (flatten-tree args)))

(defun git-islands-string (root &rest args)
  "Run Git with ARGS in ROOT and return its whole output, or nil on failure."
  (let ((default-directory root)
        (command (apply #'git-islands-command args)))
    (with-temp-buffer
      (when (zerop (apply #'process-file (car command) nil t nil (cdr command)))
        (buffer-string)))))

(defun git-islands-lines (root &rest args)
  "Run Git with ARGS in ROOT and return its output lines, or nil on failure."
  (let ((default-directory root)
        (command (apply #'git-islands-command args)))
    (with-temp-buffer
      (when (zerop (apply #'process-file (car command) nil t nil (cdr command)))
        (split-string (buffer-string) "\n" t)))))

;;;; Reading the status

(defvar git-islands-status-cache (make-hash-table :test #'equal)
  "Repository root to its latest `git-islands-status'.")

(defvar git-islands-status-processes (make-hash-table :test #'equal)
  "Repository root to its running status process.")

(defvar git-islands-status-stale (make-hash-table :test #'equal)
  "Repository roots asked to refresh while their status was being read.")

(defvar git-islands-status-callbacks (make-hash-table :test #'equal)
  "Repository root to the callbacks waiting for its next snapshot.")

(defvar git-islands-status-functions nil
  "Functions called with a repository root after its snapshot changed.")

(defun git-islands-status (root)
  "Return ROOT's cached snapshot, or nil if it has not been read yet."
  (gethash root git-islands-status-cache))

(defun git-islands-status-fetch (root &optional callback)
  "Read ROOT's status in the background and cache the snapshot.
Then run `git-islands-status-functions', and CALLBACK with the snapshot.  A
request made while the status is being read reads it again afterwards,
and its CALLBACK waits for that newer snapshot."
  (when callback
    (puthash root (append (gethash root git-islands-status-callbacks) (list callback))
             git-islands-status-callbacks))
  (if (gethash root git-islands-status-processes)
      (puthash root t git-islands-status-stale)
    (let ((default-directory root)
          (buffer (generate-new-buffer " *git-status*" t)))
      (puthash
       root
       (make-process
        :name "git-status" :buffer buffer :noquery t
        :connection-type 'pipe :coding 'utf-8-unix :file-handler t
        :command (git-islands-command "--no-optional-locks" "status" "--porcelain=v2"
                                      "-z" "--branch" "--untracked-files=all")
        :sentinel
        (lambda (process _event)
          (when (memq (process-status process) '(exit signal))
            (remhash root git-islands-status-processes)
            (let ((status (and (eq (process-status process) 'exit)
                               (zerop (process-exit-status process))
                               (with-current-buffer buffer
                                 (git-islands-status-parse (buffer-string))))))
              (kill-buffer buffer)
              (when status
                (setf (git-islands-status-root status) root
                      (git-islands-status-state status) (git-islands-state root)
                      (git-islands-status-time status) (float-time))
                (puthash root status git-islands-status-cache)
                (run-hook-with-args 'git-islands-status-functions root))
              (if (gethash root git-islands-status-stale)
                  (progn (remhash root git-islands-status-stale)
                         (git-islands-status-fetch root))
                (let ((callbacks (gethash root git-islands-status-callbacks)))
                  (remhash root git-islands-status-callbacks)
                  (when status
                    (dolist (callback callbacks)
                      (funcall callback status)))))))))
       git-islands-status-processes))))

;;;; Refreshing

(defvar git-islands-refresh-delay 0.3
  "Seconds to wait for more changes before reading the status again.")

(defvar git-islands-refresh-timers (make-hash-table :test #'equal)
  "Repository root to its pending refresh timer.")

(defun git-islands-refresh (&optional root)
  "Read ROOT's status again soon; ROOT defaults to the current repository.
Requests within `git-islands-refresh-delay' of each other read it once."
  (when-let* ((root (or root (git-islands-root))))
    (unless (gethash root git-islands-refresh-timers)
      (puthash root
               (run-with-timer git-islands-refresh-delay nil
                               (lambda ()
                                 (remhash root git-islands-refresh-timers)
                                 ;; The repository may be gone by now.
                                 (when (file-directory-p root)
                                   (git-islands-status-fetch root))))
               git-islands-refresh-timers))))

(defvar git-islands-watched (make-hash-table :test #'equal)
  "Repository root to (USERS . WATCH-DESCRIPTORS).")

(defun git-islands-watch (root)
  "Keep ROOT's snapshot current while a view shows it.
Call `git-islands-unwatch' once the view is gone."
  (if-let* ((watched (gethash root git-islands-watched)))
      (cl-incf (car watched))
    (let* ((gitdir (git-islands-gitdir root))
           (common (git-islands-gitdir root t))
           ;; HEAD and the index live in the worktree's own Git directory;
           ;; branches in the common one.
           (directories (delete-dups
                         (seq-filter #'file-directory-p
                                     (list gitdir (expand-file-name "refs/heads" common)))))
           (callback (lambda (event)
                       (unless (string-suffix-p ".lock" (or (nth 2 event) ""))
                         (git-islands-refresh root)))))
      (puthash root
               (cons 1 (unless (file-remote-p root)
                         (delq nil (mapcar (lambda (directory)
                                             (ignore-errors
                                               (file-notify-add-watch
                                                directory '(change) callback)))
                                           directories))))
               git-islands-watched)))
  (unless (git-islands-status root)
    (git-islands-status-fetch root)))

(defun git-islands-unwatch (root)
  "Undo one `git-islands-watch' of ROOT."
  (when-let* ((watched (gethash root git-islands-watched)))
    (when (<= (cl-decf (car watched)) 0)
      (mapc #'file-notify-rm-watch (cdr watched))
      (remhash root git-islands-watched))))

(defun git-islands-refresh-after-save ()
  "Refresh the saved file's repository if a view shows it."
  (when-let* ((root (and buffer-file-name (git-islands-root))))
    (when (gethash root git-islands-watched)
      (git-islands-refresh root))))

(defun git-islands-refresh-after-magit ()
  "Refresh the repository Magit has just refreshed."
  (when-let* ((root (git-islands-root)))
    (git-islands-refresh root)))

(add-hook 'after-save-hook #'git-islands-refresh-after-save)
;; Magit refreshes only the current buffer and its status buffer.
(add-hook 'magit-post-refresh-hook #'git-islands-refresh-after-magit)

;;;; Changing the repository

(defun git-islands-run-async (root args &optional then)
  "Run Git with ARGS in ROOT through Magit's process buffer.
Prompts for passphrases and credentials are answered as in Magit.  When
Git exits, call THEN with its exit status."
  (git-islands-magit)
  (let* ((default-directory root)
         (process (magit-run-git-async args)))
    (when then
      (add-function :after (process-sentinel process)
                    (lambda (process _event)
                      (when (memq (process-status process) '(exit signal))
                        (funcall then (process-exit-status process))))))
    process))

(defvar git-islands-index-queue (make-hash-table :test #'equal)
  "Repository root to the Git commands changing its index, running first.")

(defun git-islands-index-run (root args)
  "Run Git with ARGS in ROOT once its earlier index changes are done.
Commands run one at a time, so none finds the index locked; after the
last, ROOT's status is read again at once, not after the refresh delay."
  (let ((queue (gethash root git-islands-index-queue)))
    (puthash root (append queue (list args)) git-islands-index-queue)
    (unless queue
      (git-islands-index-next root))))

(defun git-islands-index-next (root)
  "Run the first command of ROOT's index queue."
  (let* ((default-directory root)
         (buffer (generate-new-buffer " *git-index*" t))
         (args (car (gethash root git-islands-index-queue))))
    (make-process
     :name "git-index" :buffer buffer :noquery t
     :connection-type 'pipe :coding 'utf-8-unix :file-handler t
     :command (apply #'git-islands-command args)
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (unless (and (eq (process-status process) 'exit)
                      (zerop (process-exit-status process)))
           (message "git %s: %s" (car args)
                    (string-trim (with-current-buffer buffer (buffer-string)))))
         (kill-buffer buffer)
         (let ((rest (cdr (gethash root git-islands-index-queue))))
           (if rest
               (progn (puthash root rest git-islands-index-queue)
                      (git-islands-index-next root))
             (remhash root git-islands-index-queue)
             (git-islands-status-fetch root))))))))

(defun git-islands-index-busy-p (root)
  "Return non-nil while Git commands are changing ROOT's index."
  (gethash root git-islands-index-queue))

(defun git-islands-stage (root files)
  "Stage all changes to FILES, relative to ROOT, in the background."
  (git-islands-index-run root (append '("add" "-A" "--") files)))

(defun git-islands-unstage (root files)
  "Unstage all changes to FILES, relative to ROOT, in the background."
  (git-islands-index-run root (append (if (git-islands-status-head (git-islands-status root))
                                          '("reset" "-q" "--")
                                        ;; Before the first commit there is no HEAD to reset to.
                                        '("rm" "--cached" "-r" "-q" "--"))
                                      files)))

(defun git-islands-rollback (root entries)
  "Discard the changes of ENTRIES in ROOT, as IntelliJ's Rollback does.
Tracked files return to HEAD in the index and the tree; files added in the
index are removed from it and kept on disk; untracked files go to the
trash."
  (git-islands-magit)
  (let ((default-directory root)
        tracked added untracked)
    (dolist (entry entries)
      (pcase (git-islands-entry-change entry)
        ;; A conflict is resolved in the Conflicts dialog, never rolled back.
        ('conflict nil)
        ('untracked (push (git-islands-entry-path entry) untracked))
        ('added (push (git-islands-entry-path entry) added))
        ('renamed
         ;; Move the file back: drop the new name, restore the old one.
         (push (git-islands-entry-path entry) added)
         (push (git-islands-entry-path entry) untracked)
         (push (git-islands-entry-orig entry) tracked))
        (_ (push (git-islands-entry-path entry) tracked))))
    (when added
      (magit-run-git "rm" "--cached" "--quiet" "--" added))
    (when tracked
      (if (not (git-islands-head root))
          (magit-run-git "rm" "--cached" "--quiet" "--" tracked)
        (magit-run-git "checkout" "HEAD" "--" tracked)))
    (dolist (file untracked)
      (when (file-exists-p (expand-file-name file root))
        (move-file-to-trash (expand-file-name file root))))
    (git-islands-refresh root)))

(defun git-islands-head (root)
  "Return ROOT's HEAD commit, or nil before the first commit."
  (car (git-islands-lines root "rev-parse" "--verify" "--quiet" "HEAD")))

(defun git-islands-head-message (root)
  "Return the message of ROOT's last commit, or nil before the first."
  (when (git-islands-head root)
    (git-islands-string root "log" "-1" "--format=%B")))

(defun git-islands-commit (root message &optional amend then)
  "Commit the index of ROOT with MESSAGE, amending HEAD if AMEND.
Commit hooks and signing run as with Magit; THEN is called with Git's exit
status."
  (let ((file (let ((coding-system-for-write 'utf-8-unix))
                (make-temp-file "emacs-commit-msg-" nil nil message))))
    ;; Lines starting with # are part of the message, as in IntelliJ.
    (git-islands-run-async root
                           (list "commit" "--cleanup=whitespace" "--file" file
                                 (and amend "--amend"))
                           (lambda (status)
                             (delete-file file)
                             (when then (funcall then status))))))

(defun git-islands-open-magit (root)
  "Show ROOT in Magit's own status buffer."
  (git-islands-magit)
  (magit-status-setup-buffer root))

(provide 'git-islands-core)
;;; git-islands-core.el ends here
