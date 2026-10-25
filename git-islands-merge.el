;;; git-islands-merge.el --- IntelliJ's Conflicts dialog -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The files a merge, rebase or cherry-pick left in conflict, each with how
;; both sides changed it, and IntelliJ's three ways out: Accept Yours,
;; Accept Theirs, or Merge, which opens the three-pane merge (git-islands-merge3.el;
;; Magit's three-way Ediff is on `e').  Once none
;; is left, the dialog offers to continue the operation.  It opens by
;; itself when a command run from the tool windows stops with conflicts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit-section)
(require 'git-islands-core)
(require 'git-islands-faces)
(require 'git-islands-tree)

(declare-function magit-ediff-resolve-rest "magit-ediff" (file))
(declare-function git-islands-merge3 "git-islands-merge3" (root path))
(declare-function magit-rebase-continue "magit-sequence" (&optional noedit))
(declare-function magit-rebase-skip "magit-sequence" ())
(declare-function magit-rebase-abort "magit-sequence" ())
(declare-function magit-sequencer-continue "magit-sequence" ())
(declare-function magit-sequencer-skip "magit-sequence" ())
(declare-function magit-sequencer-abort "magit-sequence" ())
(declare-function magit-merge-abort "magit-merge" ())
(declare-function magit-run-git "magit-process" (&rest args))
(autoload 'git-islands-message-focus "git-islands-commit-panel")

;;;; Sides

(defun git-islands-conflict-sides (entry)
  "Return how ours and theirs changed ENTRY, as two words."
  (pcase (string (git-islands-entry-index entry) (git-islands-entry-worktree entry))
    ("DD" '("Deleted" "Deleted"))
    ("AU" '("Added" "Modified"))
    ("UD" '("Modified" "Deleted"))
    ("UA" '("Modified" "Added"))
    ("DU" '("Deleted" "Modified"))
    ("AA" '("Added" "Added"))
    (_ '("Modified" "Modified"))))

(defun git-islands-conflict-entries (root)
  "Return ROOT's files in conflict."
  (when-let* ((status (git-islands-status root)))
    (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'unmerged))
                (git-islands-status-entries status))))

(defun git-islands-accept (root entries side)
  "Resolve ENTRIES of ROOT by taking SIDE, `ours' or `theirs'."
  (git-islands-magit)
  (let ((default-directory root))
    (dolist (entry entries)
      (let* ((path (git-islands-entry-path entry))
             (sides (git-islands-conflict-sides entry))
             (taken (if (eq side 'ours) (car sides) (cadr sides))))
        (if (equal taken "Deleted")
            (magit-run-git "rm" "--quiet" "--" path)
          (magit-run-git "checkout" (if (eq side 'ours) "--ours" "--theirs") "--" path)
          (magit-run-git "add" "--" path))))
    (git-islands-refresh root)))

;;;; Continuing the operation

(defun git-islands-operation-label (state)
  "Return how the operation STATE is named."
  (pcase state
    ('rebase "Rebasing") ('merge "Merging")
    ('cherry-pick "Cherry-picking") ('revert "Reverting")))

(defun git-islands-continue (root)
  "Continue ROOT's rebase, cherry-pick or revert, or commit its merge."
  (git-islands-magit)
  (let ((default-directory root))
    (pcase (git-islands-state root)
      ('rebase (magit-rebase-continue))
      ((or 'cherry-pick 'revert) (magit-sequencer-continue))
      ('merge (git-islands-message-focus))
      (_ (user-error "No operation in progress")))))

(defun git-islands-skip (root)
  "Skip the commit ROOT's rebase or cherry-pick stopped at."
  (git-islands-magit)
  (let ((default-directory root))
    (pcase (git-islands-state root)
      ('rebase (magit-rebase-skip))
      ((or 'cherry-pick 'revert) (magit-sequencer-skip))
      (_ (user-error "Nothing to skip")))))

(defun git-islands-abort (root)
  "Abort ROOT's operation in progress, after confirmation."
  (git-islands-magit)
  (let ((default-directory root))
    (pcase (git-islands-state root)
      ('rebase (magit-rebase-abort))
      ('merge (magit-merge-abort))
      ((or 'cherry-pick 'revert) (magit-sequencer-abort))
      (_ (user-error "No operation in progress"))))
  (git-islands-refresh root))

(defun git-islands-operation-banner (root state)
  "Return a row naming ROOT's operation STATE with buttons to finish it."
  (let ((button (lambda (label action)
                  (git-islands-button label (lambda (&rest _) (interactive) (funcall action root))
                                      label (equal label "Continue")))))
    (concat (propertize (concat (git-islands-operation-label state) "…") 'face 'git-islands-conflict)
            "  "
            (funcall button (if (eq state 'merge) "Commit" "Continue") #'git-islands-continue)
            (unless (eq state 'merge)
              (concat " " (funcall button "Skip" #'git-islands-skip)))
            " "
            (funcall button "Abort" #'git-islands-abort))))

;;;; Dialog

(defvar-local git-islands-conflicts-root nil)

(defvar git-islands-conflicts-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") #'git-islands-conflicts-accept-yours)
    (define-key map (kbd "t") #'git-islands-conflicts-accept-theirs)
    (define-key map (kbd "m") #'git-islands-conflicts-merge)
    (define-key map (kbd "RET") #'git-islands-conflicts-merge)
    (define-key map (kbd "<double-mouse-1>") #'git-islands-conflicts-merge)
    (define-key map (kbd "e") #'git-islands-conflicts-ediff)
    (define-key map (kbd "o") #'git-islands-conflicts-visit)
    (define-key map (kbd "g") #'git-islands-conflicts-refresh)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keys of the Conflicts dialog.")

(define-derived-mode git-islands-conflicts-mode magit-section-mode "Conflicts"
  "Files in conflict, and the ways to resolve them."
  :interactive nil
  (setq-local magit-section-highlight-current nil
              magit-section-highlight-selection nil
              magit-section-visibility-indicators nil)
  (git-islands-view-setup)
  ;; An editor tab, unlike the tool windows.
  (setq-local tab-line-exclude nil
              header-line-format '(:eval (git-islands-conflicts-header))))

(defun git-islands-conflicts-buffer (root)
  "Return ROOT's Conflicts dialog, creating it if needed."
  (let ((name (format "*Conflicts: %s*" (file-name-nondirectory (directory-file-name root)))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq default-directory root)
          (git-islands-conflicts-mode)
          (setq git-islands-conflicts-root root)
          (current-buffer)))))

(defun git-islands-conflicts-render ()
  "List the files still in conflict."
  (let* ((root git-islands-conflicts-root)
         (entries (git-islands-conflict-entries root))
         (state (git-islands-state root))
         (line (line-number-at-pos))
         (inhibit-read-only t))
    (erase-buffer)
    (setq magit-root-section nil)
    (magit-insert-section (git-islands-conflicts)
                          (if (null entries)
                              (progn
                                (git-islands-tree-row 0 (propertize "All conflicts are resolved" 'face 'git-islands-added))
                                (when state
                                  (git-islands-tree-row 0 (git-islands-operation-banner root state))))
                            (git-islands-tree-row 0 (propertize (format "%s: %d %s in conflict"
                                                                        (or (git-islands-operation-label state) "Conflicts")
                                                                        (length entries)
                                                                        (if (cdr entries) "files" "file"))
                                                                'face 'git-islands-group))
                            (dolist (entry entries)
                              (pcase-let ((`(,ours ,theirs) (git-islands-conflict-sides entry)))
                                (git-islands-tree-row
                                 1 (propertize
                                    (concat (git-islands-file-icon entry) (git-islands-tree-gap)
                                            (propertize (git-islands-entry-path entry) 'face 'git-islands-conflict)
                                            (propertize (format "   Yours: %s   Theirs: %s" ours theirs)
                                                        'face 'git-islands-dim))
                                    'git-islands-entry entry))))))
    ;; Unlike the tool windows, the dialog is an ordinary buffer, where
    ;; Font Lock would strip plain faces.
    (let ((position (point-min)))
      (while (setq position (text-property-not-all position (point-max) 'face nil))
        (let ((end (next-single-property-change position 'face nil (point-max))))
          (put-text-property position end 'font-lock-face
                             (get-text-property position 'face))
          (setq position end))))
    (goto-char (point-min))
    (forward-line (1- line))
    (unless (get-text-property (point) 'git-islands-entry)
      (when-let* ((first (text-property-any (point-min) (point-max) 'git-islands-entry
                                            (car entries))))
        (goto-char first)))
    (git-islands-fit-rows)
    (git-islands-highlight)))

(defun git-islands-conflicts-header ()
  "Return the dialog's header: its three ways out."
  (let ((button (lambda (label action help)
                  (git-islands-button label action help (equal label "Merge…")))))
    (concat (propertize " " 'face 'header-line 'display (git-islands-header-space 0))
            (propertize " " 'display '(space :width (12)))
            (propertize "Conflicts   " 'face 'git-islands-title)
            (funcall button "Accept Yours" #'git-islands-conflicts-accept-yours "Accept Yours (y)")
            " "
            (funcall button "Accept Theirs" #'git-islands-conflicts-accept-theirs "Accept Theirs (t)")
            " "
            (funcall button "Merge…" #'git-islands-conflicts-merge "Merge in three panes (m)"))))

(defun git-islands-conflicts-entries-here ()
  "Return the conflicted entries the region or the row at point lists."
  (or (if (use-region-p)
          (let (entries)
            (save-excursion
              (goto-char (region-beginning))
              (while (< (point) (region-end))
                (when-let* ((entry (get-text-property (point) 'git-islands-entry)))
                  (push entry entries))
                (forward-line 1)))
            (nreverse entries))
        (when-let* ((entry (get-text-property (pos-bol) 'git-islands-entry)))
          (list entry)))
      (user-error "No file in conflict here")))

(defun git-islands-conflicts-accept-yours ()
  "Resolve the file at point, or those in the region, with your version."
  (interactive)
  (git-islands-accept git-islands-conflicts-root (git-islands-conflicts-entries-here) 'ours))

(defun git-islands-conflicts-accept-theirs ()
  "Resolve the file at point, or those in the region, with their version."
  (interactive)
  (git-islands-accept git-islands-conflicts-root (git-islands-conflicts-entries-here) 'theirs))

(defun git-islands-conflicts-merge ()
  "Merge the file at point in three panes: yours, the result and theirs."
  (interactive)
  (let ((entry (car (git-islands-conflicts-entries-here))))
    (if (member "Deleted" (git-islands-conflict-sides entry))
        (user-error "One side deleted this file: accept yours or theirs")
      (require 'git-islands-merge3)
      (git-islands-merge3 git-islands-conflicts-root (git-islands-entry-path entry)))))

(defun git-islands-conflicts-ediff ()
  "Merge the file at point in Magit's three-way Ediff."
  (interactive)
  (let ((entry (car (git-islands-conflicts-entries-here)))
        (default-directory git-islands-conflicts-root))
    (git-islands-magit)
    (magit-ediff-resolve-rest (git-islands-entry-path entry))))

(defun git-islands-conflicts-visit ()
  "Open the file at point, its conflicts marked by `smerge-mode'."
  (interactive)
  (let ((file (expand-file-name (git-islands-entry-path (car (git-islands-conflicts-entries-here)))
                                git-islands-conflicts-root)))
    (find-file file)
    (smerge-start-session)))

(defun git-islands-conflicts-refresh ()
  "Read the repository's status again."
  (interactive)
  (git-islands-status-fetch git-islands-conflicts-root))

(defun git-islands-conflicts-on-status (root)
  "Redraw ROOT's Conflicts dialog after its status changed."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'git-islands-conflicts-mode) (equal git-islands-conflicts-root root))
        (git-islands-conflicts-render)))))

(add-hook 'git-islands-status-functions #'git-islands-conflicts-on-status)

;;;###autoload
(defun git-islands-conflicts (&optional root)
  "Show the Conflicts dialog of ROOT, the current repository by default."
  (interactive)
  (let ((root (or root (git-islands-root) (user-error "Not inside a Git repository"))))
    (with-current-buffer (git-islands-conflicts-buffer root)
      (git-islands-conflicts-render)
      (git-islands-status-fetch root)
      (git-islands-in-editor #'switch-to-buffer (current-buffer)))))

(defun git-islands-conflicts-if-any (root)
  "Show ROOT's Conflicts dialog when its fresh status has conflicts."
  (git-islands-status-fetch root
                            (lambda (status)
                              (when (seq-some (lambda (entry) (eq (git-islands-entry-kind entry) 'unmerged))
                                              (git-islands-status-entries status))
                                (git-islands-conflicts root)))))

(provide 'git-islands-merge)
;;; git-islands-merge.el ends here
