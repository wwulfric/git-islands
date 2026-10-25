;;; git-islands-commit-panel.el --- IntelliJ's Commit tool window -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The Commit tool window takes the frame's left side: changed
;; files above, grouped as Changes and Unversioned Files, and the commit
;; message below, with Amend and the commit buttons in its header.
;;
;; A file's checkbox is the index, as in IntelliJ with the staging area
;; enabled: checking a file stages it, unchecking unstages it, and a file
;; staged only in part shows a partial check.  So Magit, diff-hl and a
;; terminal all see what the panel shows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit)
(require 'git-islands-core)
(require 'git-islands-tree)
(require 'git-islands-diff)
(require 'git-islands-merge)
(require 'git-islands-changelists)
(require 'git-islands-branches)


(defvar git-islands-commit-group-by-directory t
  "Non-nil groups changed files by folder; nil lists them flat.")

;;;; Panel buffer

(defvar-local git-islands-commit-root nil "Repository root the panel shows.")

(defvar git-islands-commit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'git-islands-commit-toggle-section)
    (define-key map (kbd "<tab>") #'git-islands-commit-toggle-section)
    (define-key map (kbd "SPC") #'git-islands-commit-include)
    (define-key map (kbd "RET") #'git-islands-commit-show-diff)
    (define-key map (kbd "<double-mouse-1>") #'git-islands-commit-show-diff)
    (define-key map (kbd "o") #'git-islands-commit-visit)
    (define-key map (kbd "<f4>") #'git-islands-commit-visit)
    (define-key map (kbd "g") #'git-islands-commit-refresh)
    (define-key map (kbd "R") #'git-islands-commit-rollback)
    (define-key map (kbd "s-M-z") #'git-islands-commit-rollback)
    (define-key map (kbd "c") #'git-islands-message-focus)
    (define-key map (kbd "s-k") #'git-islands-message-focus)
    (define-key map (kbd "t") #'git-islands-commit-toggle-grouping)
    (define-key map (kbd "M") #'git-islands-commit-magit)
    (define-key map (kbd "m") #'git-islands-commit-move-to-changelist)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'git-islands-commit-hide)
    map)
  "Keys of the Commit tool window.")

(define-derived-mode git-islands-commit-mode magit-section-mode "Commit"
  "Changed files of a repository, with checkboxes that stage them."
  :interactive nil
  (setq-local magit-section-highlight-current nil
              magit-section-highlight-selection nil
              magit-section-visibility-indicators nil
              revert-buffer-function (lambda (&rest _) (git-islands-commit-refresh)))
  (git-islands-view-setup)
  (setq-local header-line-format '(:eval (git-islands-tool-header (git-islands-commit-header))))
  (git-islands-set-mode-line)
  (add-hook 'kill-buffer-hook (lambda () (git-islands-unwatch git-islands-commit-root)) nil t))

(defun git-islands-commit-buffer (root)
  "Return the Commit panel of ROOT, creating it if needed."
  (let ((name (format " *commit: %s*" (abbreviate-file-name root))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq default-directory root)
          (git-islands-commit-mode)
          (setq git-islands-commit-root root)
          (git-islands-watch root)
          (git-islands-commit-render)
          (current-buffer)))))

(defun git-islands-commit-buffers (&optional root)
  "Return the live Commit panels, of ROOT only if non-nil."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'git-islands-commit-mode)
                       (or (null root) (equal git-islands-commit-root root)))))
              (buffer-list)))

;;;; Rows

(defun git-islands-entry-checkbox-state (entry)
  "Return the checkbox state of ENTRY: `on', `off' or `partial'."
  (let ((staged (git-islands-entry-staged-p entry))
        (unstaged (git-islands-entry-unstaged-p entry)))
    (cond ((and staged unstaged) 'partial)
          (staged 'on)
          (t 'off))))

(defun git-islands-entries-checkbox-state (entries)
  "Return the checkbox state of ENTRIES taken together."
  (let ((states (delete-dups (mapcar #'git-islands-entry-checkbox-state entries))))
    (if (cdr states) 'partial (or (car states) 'off))))

(defun git-islands-commit-checkbox (entries)
  "Return a checkbox showing whether ENTRIES are staged, toggling them."
  (git-islands-checkbox (git-islands-entries-checkbox-state entries)
                        (lambda (event)
                          (interactive "e")
                          (mouse-set-point event)
                          (git-islands-commit-include))))

(defun git-islands-commit-entry-checkbox (entries)
  "Return the checkbox of a row listing ENTRIES, or nil for conflicts."
  (when (seq-every-p (lambda (entry) (memq (git-islands-entry-kind entry) '(changed untracked)))
                     entries)
    (git-islands-commit-checkbox entries)))

(defun git-islands-commit-insert-group (type title entries checkbox &optional empty)
  "Insert group TYPE named TITLE listing ENTRIES.
CHECKBOX non-nil gives rows checkboxes; EMPTY is shown when there are no
entries, and without it the group is left out."
  (when (or entries empty)
    (git-islands-tree-insert-group type title entries git-islands-commit-group-by-directory
                                   (and checkbox #'git-islands-commit-entry-checkbox) empty)))

(defun git-islands-commit-insert-changelists (entries)
  "Insert a group per changelist, listing its ENTRIES."
  (let ((active (git-islands-changelists-active (git-islands-changelists git-islands-commit-root))))
    (pcase-dolist (`(,name . ,members) (git-islands-changelists-group git-islands-commit-root entries))
      (git-islands-tree-insert-group
       (cons 'changelist name)
       (if (equal name active) name (propertize name 'face '(:inherit git-islands-group :weight normal)))
       members git-islands-commit-group-by-directory #'git-islands-commit-entry-checkbox
       (if (equal name git-islands-default-changelist) "no changed files" "no files")))))

(defun git-islands-commit-render ()
  "Draw the panel from its repository's latest snapshot."
  (let* ((status (git-islands-status git-islands-commit-root))
         (section (magit-current-section))
         (ident (and section (magit-section-ident section)))
         (line (line-number-at-pos))
         (inhibit-read-only t))
    (erase-buffer)
    (setq magit-root-section nil)
    (magit-insert-section (git-islands-root)
                          (if (not status)
                              (git-islands-tree-row 0 (propertize "Loading…" 'face 'git-islands-dim))
                            (let ((entries (git-islands-status-entries status)))
                              (when-let* ((state (git-islands-status-state status)))
                                (git-islands-tree-row 0 (git-islands-operation-banner git-islands-commit-root state)))
                              (git-islands-commit-insert-group
                               'conflicts "Merge Conflicts"
                               (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'unmerged)) entries)
                               nil)
                              (git-islands-commit-insert-changelists
                               (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'changed)) entries))
                              (git-islands-commit-insert-group
                               'untracked "Unversioned Files"
                               (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'untracked)) entries)
                               t))))
    (git-islands-tree-draw-chevrons)
    (if-let* ((section (and ident (magit-get-section ident))))
        (goto-char (oref section start))
      (goto-char (point-min))
      (forward-line (1- line)))
    (git-islands-fit-rows)
    (git-islands-highlight)))

(defun git-islands-commit-on-status (root)
  "Draw ROOT's panels again after its snapshot changed."
  (dolist (buffer (git-islands-commit-buffers root))
    (with-current-buffer buffer
      (let ((windows (get-buffer-window-list buffer nil t)))
        (git-islands-commit-render)
        ;; Keep each window's point on the row it was on.
        (dolist (window windows)
          (set-window-point window (point))))))
  (dolist (buffer (git-islands-message-buffers root))
    (with-current-buffer buffer
      (force-mode-line-update))))

(add-hook 'git-islands-status-functions #'git-islands-commit-on-status)

;;;; Commands on rows

(defun git-islands-commit-entries ()
  "Return the entries of the row at point, or nil."
  (get-text-property (pos-bol) 'git-islands-entries))

(defun git-islands-commit-entry ()
  "Return the file entry of the row at point, or signal an error."
  (or (get-text-property (pos-bol) 'git-islands-entry)
      (user-error "No file on this row")))

(defun git-islands-commit-toggle-section ()
  "Fold or unfold the group or folder at point."
  (interactive)
  (when-let* ((section (magit-current-section)))
    (when (oref section content)
      (magit-section-toggle section)
      (git-islands-tree-draw-chevron section))))

(defun git-islands-commit-include ()
  "Check or uncheck the row at point, staging or unstaging its files."
  (interactive)
  (let* ((entries (seq-filter (lambda (entry)
                                (memq (git-islands-entry-kind entry) '(changed untracked)))
                              (git-islands-commit-entries)))
         (root git-islands-commit-root))
    (unless entries (user-error "Nothing to include here"))
    (if (eq (git-islands-entries-checkbox-state entries) 'on)
        (progn
          (git-islands-unstage root (mapcan (lambda (entry)
                                              (delq nil (list (git-islands-entry-path entry)
                                                              (git-islands-entry-orig entry))))
                                            entries))
          (mapc #'git-islands-entry-assume-unstaged entries))
      (git-islands-stage root (mapcar #'git-islands-entry-path entries))
      (mapc #'git-islands-entry-assume-staged entries))
    ;; Show the new state now; the status read after Git is done confirms it.
    (git-islands-commit-on-status root)))

(defun git-islands-entry-assume-staged (entry)
  "Change ENTRY as staging all its changes will."
  (if (eq (git-islands-entry-kind entry) 'untracked)
      (setf (git-islands-entry-kind entry) 'changed
            (git-islands-entry-index entry) ?A)
    (when (eq (git-islands-entry-index entry) ?.)
      (setf (git-islands-entry-index entry) (git-islands-entry-worktree entry))))
  (setf (git-islands-entry-worktree entry) ?.))

(defun git-islands-entry-assume-unstaged (entry)
  "Change ENTRY as unstaging all its changes will."
  (if (eq (git-islands-entry-index entry) ?A)
      (setf (git-islands-entry-kind entry) 'untracked
            (git-islands-entry-worktree entry) ??)
    (when (eq (git-islands-entry-worktree entry) ?.)
      (setf (git-islands-entry-worktree entry) (git-islands-entry-index entry))))
  (setf (git-islands-entry-index entry) ?.))

(defun git-islands-commit-visit ()
  "Open the file at point in the editor."
  (interactive)
  (let ((file (expand-file-name (git-islands-entry-path (git-islands-commit-entry))
                                git-islands-commit-root)))
    (if (file-exists-p file)
        (git-islands-in-editor #'find-file file)
      (user-error "%s was deleted" (file-name-nondirectory file)))))

(defun git-islands-commit-show-diff ()
  "Show the file at point side by side with HEAD, or fold the row at point."
  (interactive)
  (if-let* ((entry (get-text-property (pos-bol) 'git-islands-entry)))
      (pcase (git-islands-entry-kind entry)
        ('untracked (git-islands-commit-visit))
        ('unmerged (git-islands-conflicts git-islands-commit-root))
        (_ (git-islands-diff-show git-islands-commit-root (git-islands-entry-path entry)
                                  :left-rev (and (git-islands-head git-islands-commit-root)
                                                 (not (eq (git-islands-entry-change entry) 'added))
                                                 "HEAD")
                                  :left-path (git-islands-entry-orig entry)
                                  :left-label "HEAD")))
    (git-islands-commit-toggle-section)))

(defun git-islands-commit-rollback ()
  "Discard the changes of the row at point, after confirmation."
  (interactive)
  (let ((entries (seq-remove (lambda (entry) (eq (git-islands-entry-kind entry) 'unmerged))
                             (git-islands-commit-entries))))
    (unless entries (user-error "Nothing to roll back here"))
    (when (yes-or-no-p (if (cdr entries)
                           (format "Roll back changes in %d files? " (length entries))
                         (format "Roll back changes in %s? "
                                 (git-islands-entry-path (car entries)))))
      (git-islands-rollback git-islands-commit-root entries))))

(defun git-islands-commit-changelist-here ()
  "Return the changelist of the group the row at point is in, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (car-safe (oref section value)) 'changelist)))
      (setq section (oref section parent)))
    (and section (cdr (oref section value)))))

(defun git-islands-commit-redraw ()
  "Draw the repository's panels again, after its changelists changed."
  (dolist (buffer (git-islands-commit-buffers git-islands-commit-root))
    (with-current-buffer buffer (git-islands-commit-render))))

(defun git-islands-commit-read-changelist (prompt &optional require)
  "Read a changelist name with PROMPT; with REQUIRE, an existing one."
  (let ((name (string-trim (completing-read
                            prompt (git-islands-changelists-names (git-islands-changelists git-islands-commit-root))
                            nil require))))
    (when (string-empty-p name) (user-error "Specify a changelist"))
    name))

(defun git-islands-commit-move-to-changelist ()
  "Move the changed files of the row at point to another changelist."
  (interactive)
  (let ((paths (mapcar #'git-islands-entry-path
                       (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'changed))
                                   (git-islands-commit-entries)))))
    (unless paths (user-error "No changed files here"))
    (git-islands-changelist-move git-islands-commit-root paths
                                 (git-islands-commit-read-changelist
                                  (format "Move %s to changelist: "
                                          (if (cdr paths) (format "%d files" (length paths))
                                            (car paths)))))
    (git-islands-commit-redraw)))

(defun git-islands-commit-new-changelist ()
  "Add an empty changelist."
  (interactive)
  (git-islands-changelist-add git-islands-commit-root (git-islands-commit-read-changelist "New changelist: "))
  (git-islands-commit-redraw))

(defun git-islands-commit-set-active-changelist ()
  "Make another changelist the one new changes land in."
  (interactive)
  (let ((status (git-islands-status git-islands-commit-root)))
    (git-islands-changelist-set-active
     git-islands-commit-root
     (git-islands-commit-read-changelist "Active changelist: " t)
     (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'changed))
                 (and status (git-islands-status-entries status)))))
  (git-islands-commit-redraw))

(defun git-islands-commit-rename-changelist ()
  "Rename the changelist at point."
  (interactive)
  (let ((old (or (git-islands-commit-changelist-here)
                 (git-islands-commit-read-changelist "Rename changelist: " t))))
    (git-islands-changelist-rename git-islands-commit-root old
                                   (git-islands-commit-read-changelist (format "Rename %s to: " old))))
  (git-islands-commit-redraw))

(defun git-islands-commit-delete-changelist ()
  "Delete the changelist at point; its files join the active one."
  (interactive)
  (let ((name (or (git-islands-commit-changelist-here)
                  (git-islands-commit-read-changelist "Delete changelist: " t))))
    (when (yes-or-no-p (format "Delete changelist %s? " name))
      (git-islands-changelist-delete git-islands-commit-root name)
      (git-islands-commit-redraw))))

(defun git-islands-commit-refresh ()
  "Read the repository's status again."
  (interactive)
  (git-islands-status-fetch git-islands-commit-root))

(defun git-islands-commit-toggle-grouping ()
  "Switch between files grouped by folder and a flat list."
  (interactive)
  (setq git-islands-commit-group-by-directory (not git-islands-commit-group-by-directory))
  (dolist (buffer (git-islands-commit-buffers))
    (with-current-buffer buffer (git-islands-commit-render))))

(defun git-islands-commit-expand-all ()
  "Unfold every group and folder."
  (interactive)
  (magit-section-show-children magit-root-section 99)
  (git-islands-tree-draw-chevrons))

(defun git-islands-commit-collapse-all ()
  "Fold every folder, leaving the groups open."
  (interactive)
  (dolist (group (oref magit-root-section children))
    (magit-section-hide-children group))
  (git-islands-tree-draw-chevrons))

(defun git-islands-commit-magit ()
  "Open the repository in Magit's status buffer."
  (interactive)
  (git-islands-in-editor #'git-islands-open-magit git-islands-commit-root))

;;;; Header

(defvar git-islands-commit-buttons
  '(("general/refresh" git-islands-commit-refresh "Refresh (g)")
    ("vcs/revert" git-islands-commit-rollback "Rollback (R)")
    ("general/showAsTree" git-islands-commit-toggle-grouping "Group by Directory (t)")
    ("general/moreVertical" git-islands-commit-options-menu "Options")
    ("general/hide" git-islands-commit-hide "Hide (q)"))
  "Commit tool window buttons as (ICON ACTION HELP).
ACTION is a command, or a function called with the click event.")

(defun git-islands-commit-options-menu (event)
  "Pop up the Commit tool window's other commands at EVENT."
  (popup-menu '("Commit"
                ["Expand All" git-islands-commit-expand-all]
                ["Collapse All" git-islands-commit-collapse-all]
                ["Group by Directory" git-islands-commit-toggle-grouping
                 :style toggle :selected git-islands-commit-group-by-directory]
                "---"
                ["Move to Another Changelist…" git-islands-commit-move-to-changelist]
                ["New Changelist…" git-islands-commit-new-changelist]
                ["Set Active Changelist…" git-islands-commit-set-active-changelist]
                ["Rename Changelist…" git-islands-commit-rename-changelist]
                ["Delete Changelist…" git-islands-commit-delete-changelist]
                "---"
                ["Open in Magit" git-islands-commit-magit])
              event))

(defun git-islands-commit-branch-label (status)
  "Return STATUS's branch with its distance from upstream, dimmed."
  (when status
    (propertize
     (concat "  "
             (or (git-islands-status-branch status)
                 (concat "detached " (substring (or (git-islands-status-head status) "") 0
                                                (min 7 (length (git-islands-status-head status))))))
             (git-islands-commit-distance "general/up" (git-islands-status-ahead status))
             (git-islands-commit-distance "general/down" (git-islands-status-behind status)))
     'face 'git-islands-dim)))

(defun git-islands-commit-distance (icon count)
  "Return COUNT commits after a small ICON arrow, or nothing for none."
  (when (> count 0)
    (concat (git-islands-space 4)
            (expui-icons-icon icon :face 'git-islands-dim :height 12)
            (number-to-string count))))

(defun git-islands-commit-header ()
  "Return the Commit tool window's title, and its toolbar while focused."
  (let* ((toolbar (when (mode-line-window-selected-p)
                    (git-islands-toolbar git-islands-commit-buttons)))
         (room (- (window-body-width nil t)
                  (if toolbar (string-pixel-width toolbar) 0)
                  8 (git-islands-line-end-inset)))
         (title (concat (propertize " Commit" 'face 'git-islands-title)
                        (git-islands-commit-branch-label (git-islands-status git-islands-commit-root)))))
    (concat (propertize " " 'face 'header-line 'display (git-islands-header-space 0))
            (truncate-string-pixelwise title room (current-buffer) "…")
            (when toolbar (git-islands-at-right toolbar (git-islands-line-end))))))

;;;; Commit message

(defvar git-islands-message-history nil "Messages of past commits, newest first.")
(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'git-islands-message-history))

(defvar-local git-islands-message-root nil "Repository root the message commits to.")
(defvar-local git-islands-message-amend nil "Non-nil amends the last commit.")
(defvar-local git-islands-message-draft nil "Message typed before Amend filled it.")
(defvar-local git-islands-message-history-index -1)
(defvar-local git-islands-message-placeholder nil)

(defvar git-islands-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'git-islands-message-commit)
    (define-key map (kbd "s-<return>") #'git-islands-message-commit)
    (define-key map (kbd "C-c C-p") #'git-islands-message-commit-and-push)
    (define-key map (kbd "s-M-k") #'git-islands-message-commit-and-push)
    (define-key map (kbd "C-c C-a") #'git-islands-message-toggle-amend)
    (define-key map (kbd "M-p") #'git-islands-message-previous)
    (define-key map (kbd "M-n") #'git-islands-message-next)
    (define-key map (kbd "s-0") #'git-islands-commit-toggle)
    map)
  "Keys of the commit message.")

(define-derived-mode git-islands-message-mode text-mode "Commit Message"
  "The message of the next commit, below the Commit panel."
  :interactive nil
  (setq-local tab-line-exclude t
              fill-column 72
              ;; Keep the text off the window's edge, as the rows above are.
              line-prefix (git-islands-space git-islands-row-inset)
              wrap-prefix (git-islands-space git-islands-row-inset)
              word-wrap t
              truncate-lines nil
              header-line-format '(:eval (git-islands-tool-header (git-islands-message-header))))
  (git-islands-set-mode-line)
  ;; The message is written in the interface font, as the rows above.
  (face-remap-add-relative 'default 'git-islands-file-name)
  (face-remap-add-relative 'header-line :inherit 'tab-line :height 1.0 :box nil)
  (setq-local line-spacing 0.25)
  (add-hook 'after-change-functions #'git-islands-message-update-placeholder nil t)
  ;; Air between the header's rule and the first line.
  (let ((top (make-overlay 1 1 nil nil t)))
    (overlay-put top 'before-string (propertize "\n" 'line-height 0.5)))
  (git-islands-message-update-placeholder))

(defun git-islands-message-buffer (root)
  "Return ROOT's commit message buffer, creating it if needed."
  (let ((name (format " *commit message: %s*" (abbreviate-file-name root))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq default-directory root)
          (git-islands-message-mode)
          (setq git-islands-message-root root)
          (current-buffer)))))

(defun git-islands-message-buffers (&optional root)
  "Return the live commit message buffers, of ROOT only if non-nil."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'git-islands-message-mode)
                       (or (null root) (equal git-islands-message-root root)))))
              (buffer-list)))

(defun git-islands-message-update-placeholder (&rest _)
  "Show \"Commit Message\" in the empty message, as IntelliJ does."
  (unless (overlayp git-islands-message-placeholder)
    (setq git-islands-message-placeholder (make-overlay 1 1 nil t nil)))
  (overlay-put git-islands-message-placeholder 'before-string
               (when (= (buffer-size) 0)
                 (propertize "Commit Message" 'face 'git-islands-dim 'cursor t))))

(defun git-islands-message-header ()
  "Return the message's header: Amend, then the commit buttons.
Commit and Push keeps its label while there is room, as in IntelliJ."
  (let* ((primary (git-islands-button "Commit" #'git-islands-message-commit "Commit (s-RET)" t))
         (push-label (git-islands-button "Commit and Push…" #'git-islands-message-commit-and-push
                                         "Commit and Push (s-M-k)"))
         (amend (git-islands-header-button #'git-islands-message-toggle-amend
                                           "Amend the last commit (C-c C-a)"
                                           (git-islands-checkbox (if git-islands-message-amend 'on 'off))
                                           (git-islands-space 6) "Amend"))
         (gap (git-islands-space 6))
         (room (- (window-body-width nil t) git-islands-row-inset
                  (string-pixel-width amend) (git-islands-line-end-inset) 24))
         (push (if (> room (+ (string-pixel-width primary) (string-pixel-width push-label) 6))
                   push-label
                 (git-islands-header-button #'git-islands-message-commit-and-push "Commit and Push (s-M-k)"
                                            (expui-icons-icon "vcs/push"
                                                              :face 'git-islands-neutral-icon))))
         (buttons (concat primary gap push (git-islands-space git-islands-toolbar-margin))))
    (concat (propertize " " 'face 'header-line 'display (git-islands-header-space 0))
            (git-islands-space (- git-islands-row-inset 2))
            amend
            (git-islands-at-right buttons (git-islands-line-end)))))

(defun git-islands-message-text ()
  "Return the message without surrounding blank lines."
  (string-trim (buffer-substring-no-properties (point-min) (point-max))))

(defun git-islands-message-set (text)
  "Replace the message with TEXT."
  (erase-buffer)
  (insert (or text ""))
  (goto-char (point-min)))

(defun git-islands-message-toggle-amend ()
  "Amend the last commit, or stop amending it.
Turning Amend on fills an empty message with the last commit's; turning
it off brings back what was typed before."
  (interactive)
  (setq git-islands-message-amend (not git-islands-message-amend))
  (if git-islands-message-amend
      (progn
        (setq git-islands-message-draft (git-islands-message-text))
        (when (string-empty-p git-islands-message-draft)
          (git-islands-message-set (string-trim (or (git-islands-head-message git-islands-message-root) "")))))
    (git-islands-message-set git-islands-message-draft))
  (force-mode-line-update))

(defun git-islands-message-history-step (step)
  "Replace the message with the one STEP places along the history."
  (let ((index (+ git-islands-message-history-index step)))
    (cond ((< index -1) (user-error "End of history"))
          ((>= index (length git-islands-message-history)) (user-error "Beginning of history"))
          (t (setq git-islands-message-history-index index)
             (git-islands-message-set (if (< index 0) "" (nth index git-islands-message-history)))))))

(defun git-islands-message-previous ()
  "Replace the message with an earlier commit's message."
  (interactive)
  (git-islands-message-history-step 1))

(defun git-islands-message-next ()
  "Replace the message with a later commit's message."
  (interactive)
  (git-islands-message-history-step -1))

(defun git-islands-message-commit (&optional push)
  "Commit the checked files with this message; then push if PUSH."
  (interactive)
  (let* ((buffer (current-buffer))
         (root git-islands-message-root)
         (text (git-islands-message-text))
         (amend git-islands-message-amend)
         (status (git-islands-status root)))
    (when (string-empty-p text)
      (user-error "Specify commit message"))
    (unless (or amend (seq-some #'git-islands-entry-staged-p (and status (git-islands-status-entries status))))
      (user-error "No changes selected for commit"))
    (message "Committing…")
    (git-islands-commit
     root text amend
     (lambda (code)
       (if (not (zerop code))
           (message "Commit failed; see %s" (buffer-name (magit-process-buffer t)))
         (setq git-islands-message-history
               (cons text (delete text git-islands-message-history)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq git-islands-message-amend nil
                   git-islands-message-draft nil
                   git-islands-message-history-index -1)
             (git-islands-message-set "")))
         (message "Committed: %s" (car (split-string text "\n")))
         ;; Sets the upstream on a branch's first push.
         (when push (git-islands-push-current root)))
       (git-islands-refresh root)))))

(defun git-islands-message-commit-and-push ()
  "Commit the checked files with this message, then push."
  (interactive)
  (git-islands-message-commit t))

;;;; Tool window

(defun git-islands-commit-window (&optional frame)
  "Return FRAME's window showing a Commit panel, or nil."
  (seq-find (lambda (window)
              (with-current-buffer (window-buffer window)
                (derived-mode-p 'git-islands-commit-mode)))
            (window-list frame 'no-minibuffer)))

(defun git-islands-message-window (&optional frame)
  "Return FRAME's window showing a commit message, or nil."
  (seq-find (lambda (window)
              (with-current-buffer (window-buffer window)
                (derived-mode-p 'git-islands-message-mode)))
            (window-list frame 'no-minibuffer)))

(defun git-islands-commit-show (root)
  "Show ROOT's Commit tool window on the frame's left; return its window."
  (let ((panel (git-islands-commit-buffer root))
        (message (git-islands-message-buffer root)))
    (run-hooks 'git-islands-side-window-hook)
    (let ((window (display-buffer-in-side-window
                   panel `((side . left) (slot . -1) (dedicated . t)
                           (window-width . ,(git-islands-side-width))
                           (window-parameters (no-other-window . t)
                                              (no-delete-other-windows . t))))))
      (display-buffer-in-side-window
       message `((side . left) (slot . 1) (dedicated . t) (window-height . 0.3)
                 (window-parameters (no-delete-other-windows . t))))
      ;; One card with the message: the line between them is the divider,
      ;; and the message's status line holds the card's bottom corners.
      (set-window-parameter window 'mode-line-format 'none)
      ;; The echo area growing and shrinking around a popup takes its
      ;; lines from the editor, not from the message.
      (when-let* ((message-window (get-buffer-window message)))
        (window-preserve-size message-window nil t))
      ;; As wide as asked, whatever the frame's width does later.
      (git-islands-pane-keep window (lambda () (* (git-islands-side-width) (frame-char-width))))
      (git-islands-refresh root)
      window)))

(defun git-islands-commit-hide (&optional frame)
  "Hide FRAME's Commit tool window."
  (interactive)
  (dolist (window (list (git-islands-message-window frame) (git-islands-commit-window frame)))
    (when (window-live-p window)
      (delete-window window))))

(defun git-islands-commit-sync (frame)
  "Close FRAME's commit message when another window took its panel's place."
  (when (and (git-islands-message-window frame) (not (git-islands-commit-window frame)))
    (delete-window (git-islands-message-window frame))))

;; Also when the panel's window is deleted, which changes no window's buffer.
(add-hook 'window-state-change-functions #'git-islands-commit-sync)

;;;###autoload
(defun git-islands-commit-toggle ()
  "Focus the Commit tool window; hide it when already focused."
  (interactive)
  (if-let* ((window (git-islands-commit-window)))
      (if (memq (selected-window) (list window (git-islands-message-window)))
          (git-islands-commit-hide)
        (select-window window))
    (select-window (git-islands-commit-show (git-islands-popup-root)))))

;;;###autoload
(defun git-islands-message-focus ()
  "Show the Commit tool window and put point in the commit message."
  (interactive)
  (unless (git-islands-message-window)
    (git-islands-commit-show (git-islands-popup-root)))
  (select-window (git-islands-message-window)))

(provide 'git-islands-commit-panel)
;;; git-islands-commit-panel.el ends here
