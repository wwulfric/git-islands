;;; git-islands-merge3.el --- IntelliJ's three-pane merge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; A file in conflict in three panes: your version on the left, the file
;; itself as the result in the middle and their version on the right, as
;; IntelliJ's Merge Revisions dialog shows it.  Git has already applied
;; the changes that do not conflict; each conflict is still marked in the
;; result, and highlighted with the text each side gave it.  Accept Left,
;; Accept Right or both replace the conflict at point; the result stays
;; editable throughout.  Apply saves the file and marks it resolved.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'smerge-mode)
(require 'git-islands-core)
(require 'git-islands-faces)
(require 'git-islands-env)
(require 'git-islands-ui)

(declare-function git-islands-diff-blob "git-islands-diff" (root rev path))
(declare-function git-islands-diff-blob-buffer "git-islands-diff" (label path text))
(declare-function git-islands-button "git-islands-tree" (label action help &optional primary))
(declare-function git-islands-ui "git-islands-tree" (text &optional face))
(declare-function git-islands-header-style "git-islands-tree" (enable))
(declare-function magit-run-git "magit-process" (&rest args))

(defface git-islands-merge-conflict
  '((((background dark)) :background "#4A2F31" :extend t)
    (t :background "#FBE3E4" :extend t))
  "Conflicting lines in each pane."
  :group 'git-islands)

(cl-defstruct (git-islands-merge (:constructor git-islands-merge-create))
  "A file being merged in three panes."
  root path ours result theirs windows configuration)

(defvar-local git-islands-merge-current nil "The merge this buffer is a pane of.")
(defvar git-islands-merge-timer nil "Pending highlighting of the conflicts.")

;;;; Conflicts

(defun git-islands-merge-conflicts ()
  "Return the conflicts in the current buffer, as (WHOLE OURS THEIRS) ranges.
Each range is (START . END); the ranges are those of the conflict markers'
match data, so they are valid until the buffer changes."
  (let (conflicts)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (ignore-errors (smerge-find-conflict))
          (push (list (cons (match-beginning 0) (match-end 0))
                      (cons (match-beginning 1) (match-end 1))
                      (cons (match-beginning 3) (match-end 3)))
                conflicts)
          (goto-char (match-end 0)))))
    (nreverse conflicts)))

(defun git-islands-merge-mark (start end)
  "Highlight START to END as conflicting."
  (let ((overlay (make-overlay start end nil t nil)))
    (overlay-put overlay 'face 'git-islands-merge-conflict)
    (overlay-put overlay 'git-islands-merge t)
    (overlay-put overlay 'priority -10)))

(defun git-islands-merge-locate (buffer text from)
  "Return where TEXT appears in BUFFER at or after FROM, as (START . END)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char from)
      (unless (string-empty-p text)
        (when (search-forward text nil t)
          (cons (match-beginning 0) (match-end 0)))))))

(defun git-islands-merge-decorate (merge)
  "Highlight MERGE's conflicts in all three panes."
  (let ((result (git-islands-merge-result merge))
        (ours (git-islands-merge-ours merge))
        (theirs (git-islands-merge-theirs merge))
        (ours-from 1) (theirs-from 1))
    (dolist (buffer (list result ours theirs))
      (with-current-buffer buffer
        (remove-overlays (point-min) (point-max) 'git-islands-merge t)))
    (with-current-buffer result
      (dolist (conflict (git-islands-merge-conflicts))
        (pcase-let ((`(,whole ,mine ,other) conflict))
          (git-islands-merge-mark (car whole) (cdr whole))
          ;; The same text in each side's own version.
          (when-let* ((found (git-islands-merge-locate
                              ours (buffer-substring-no-properties (car mine) (cdr mine))
                              ours-from)))
            (with-current-buffer ours (git-islands-merge-mark (car found) (cdr found)))
            (setq ours-from (cdr found)))
          (when-let* ((found (git-islands-merge-locate
                              theirs (buffer-substring-no-properties (car other) (cdr other))
                              theirs-from)))
            (with-current-buffer theirs (git-islands-merge-mark (car found) (cdr found)))
            (setq theirs-from (cdr found))))))
    (force-mode-line-update t)))

(defun git-islands-merge-after-change (&rest _)
  "Highlight the conflicts again after the result was edited."
  (when-let* ((merge git-islands-merge-current))
    (when (timerp git-islands-merge-timer) (cancel-timer git-islands-merge-timer))
    (setq git-islands-merge-timer
          (run-with-idle-timer 0.3 nil
                               (lambda ()
                                 (when (seq-every-p #'buffer-live-p
                                                    (list (git-islands-merge-ours merge)
                                                          (git-islands-merge-result merge)
                                                          (git-islands-merge-theirs merge)))
                                   (git-islands-merge-decorate merge)))))))

;;;; Commands

(defun git-islands-merge-conflict-at-point ()
  "Return the result's conflict at or after point, or signal an error."
  (with-current-buffer (git-islands-merge-result git-islands-merge-current)
    (let ((point (if (eq (current-buffer) (window-buffer (selected-window)))
                     (point)
                   (window-point (cadr (git-islands-merge-windows git-islands-merge-current))))))
      (or (seq-find (lambda (conflict) (> (cdr (car conflict)) point))
                    (git-islands-merge-conflicts))
          (car (last (git-islands-merge-conflicts)))
          (user-error "No conflicts left")))))

(defun git-islands-merge-accept (side)
  "Replace the conflict at point with SIDE: `ours', `theirs' or `both'."
  (let* ((merge git-islands-merge-current)
         (conflict (git-islands-merge-conflict-at-point)))
    (with-current-buffer (git-islands-merge-result merge)
      (pcase-let* ((`(,whole ,mine ,other) conflict)
                   (text (pcase side
                           ('ours (buffer-substring-no-properties (car mine) (cdr mine)))
                           ('theirs (buffer-substring-no-properties (car other) (cdr other)))
                           (_ (concat (buffer-substring-no-properties (car mine) (cdr mine))
                                      (buffer-substring-no-properties (car other) (cdr other)))))))
        (save-excursion
          (goto-char (car whole))
          (delete-region (car whole) (cdr whole))
          (insert text))
        (goto-char (car whole))))
    (git-islands-merge-decorate merge)
    (when (cdr (git-islands-merge-windows merge))
      (set-window-point (cadr (git-islands-merge-windows merge))
                        (with-current-buffer (git-islands-merge-result merge) (point))))))

(defun git-islands-merge-accept-left ()
  "Resolve the conflict at point with your version."
  (interactive)
  (git-islands-merge-accept 'ours))

(defun git-islands-merge-accept-right ()
  "Resolve the conflict at point with their version."
  (interactive)
  (git-islands-merge-accept 'theirs))

(defun git-islands-merge-accept-both ()
  "Resolve the conflict at point with your version, then theirs."
  (interactive)
  (git-islands-merge-accept 'both))

(defun git-islands-merge-goto (forward)
  "Move every pane to the next conflict, or the previous unless FORWARD."
  (let* ((merge git-islands-merge-current)
         (result (git-islands-merge-result merge))
         (window (cadr (git-islands-merge-windows merge)))
         (point (window-point window))
         (starts (with-current-buffer result
                   (mapcar (lambda (conflict) (car (car conflict))) (git-islands-merge-conflicts))))
         (target (if forward
                     (seq-find (lambda (start) (> start point)) starts)
                   (seq-find (lambda (start) (< start point)) (reverse starts)))))
    (unless target (user-error (if forward "No next conflict" "No previous conflict")))
    (set-window-point window target)
    (with-selected-window window (goto-char target) (recenter))
    ;; Bring each side's highlighted text for this conflict into view.
    (let ((index (cl-position target starts)))
      (cl-loop for buffer in (list (git-islands-merge-ours merge) (git-islands-merge-theirs merge))
               for side-window in (list (car (git-islands-merge-windows merge))
                                        (caddr (git-islands-merge-windows merge)))
               when (window-live-p side-window)
               do (let ((marks (with-current-buffer buffer
                                 (sort (mapcar #'overlay-start
                                               (seq-filter (lambda (o) (overlay-get o 'git-islands-merge))
                                                           (overlays-in (point-min) (point-max))))
                                       #'<))))
                    (when-let* ((position (nth index marks)))
                      (with-selected-window side-window
                        (goto-char position)
                        (recenter))))))))

(defun git-islands-merge-next ()
  "Move to the next conflict."
  (interactive)
  (git-islands-merge-goto t))

(defun git-islands-merge-previous ()
  "Move to the previous conflict."
  (interactive)
  (git-islands-merge-goto nil))

(defun git-islands-merge-close (merge)
  "Close MERGE's panes and restore the windows."
  (when (timerp git-islands-merge-timer) (cancel-timer git-islands-merge-timer))
  (let ((result (git-islands-merge-result merge)))
    (dolist (buffer (list (git-islands-merge-ours merge) (git-islands-merge-theirs merge)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (when (buffer-live-p result)
      (with-current-buffer result
        (remove-overlays (point-min) (point-max) 'git-islands-merge t)
        (git-islands-merge-pane-mode -1)
        (setq git-islands-merge-current nil)
        (kill-local-variable 'header-line-format)))
    (when (window-configuration-p (git-islands-merge-configuration merge))
      (set-window-configuration (git-islands-merge-configuration merge)))
    (set-frame-parameter nil 'git-islands-merge nil)))

(defun git-islands-merge-apply ()
  "Save the result, mark the file resolved and close the merge."
  (interactive)
  (let* ((merge git-islands-merge-current)
         (left (with-current-buffer (git-islands-merge-result merge)
                 (length (git-islands-merge-conflicts)))))
    (when (or (zerop left)
              (yes-or-no-p (format "%d %s left.  Save and mark resolved anyway? "
                                   left (if (= left 1) "conflict is" "conflicts are"))))
      (with-current-buffer (git-islands-merge-result merge) (save-buffer))
      (git-islands-magit)
      (let ((default-directory (git-islands-merge-root merge)))
        (magit-run-git "add" "--" (git-islands-merge-path merge)))
      (git-islands-merge-close merge)
      (git-islands-refresh (git-islands-merge-root merge))
      (message "Resolved %s" (git-islands-merge-path merge)))))

(defun git-islands-merge-cancel ()
  "Close the merge, keeping the result's edits unsaved and the file unresolved."
  (interactive)
  (git-islands-merge-close git-islands-merge-current))

;;;; Panes

(defvar git-islands-merge-pane-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<f7>") #'git-islands-merge-next)
    (define-key map (kbd "S-<f7>") #'git-islands-merge-previous)
    (define-key map (kbd "C-c C-n") #'git-islands-merge-next)
    (define-key map (kbd "C-c C-p") #'git-islands-merge-previous)
    (define-key map (kbd "C-c C-l") #'git-islands-merge-accept-left)
    (define-key map (kbd "C-c C-r") #'git-islands-merge-accept-right)
    (define-key map (kbd "C-c C-b") #'git-islands-merge-accept-both)
    (define-key map (kbd "C-c C-c") #'git-islands-merge-apply)
    (define-key map (kbd "C-c C-k") #'git-islands-merge-cancel)
    map)
  "Keys of the three merge panes.")

(define-minor-mode git-islands-merge-pane-mode
  "A buffer shown as a pane of a three-pane merge."
  :keymap git-islands-merge-pane-mode-map
  (if git-islands-merge-pane-mode
      (progn (add-hook 'after-change-functions #'git-islands-merge-after-change nil t)
             (git-islands-header-style t))
    (remove-hook 'after-change-functions #'git-islands-merge-after-change t)
    (git-islands-header-style nil)))

(defun git-islands-merge-button (label action help)
  "Return a header button LABEL running ACTION, with tooltip HELP.
Apply, which finishes the merge, is the default button."
  (require 'git-islands-tree)
  (git-islands-button label action help (equal label "Apply")))

(defun git-islands-merge-header (pane)
  "Return the header of the merge's PANE: `ours', `result' or `theirs'."
  (let* ((merge git-islands-merge-current)
         (left (with-current-buffer (git-islands-merge-result merge)
                 (length (git-islands-merge-conflicts)))))
    (concat
     (propertize " " 'display (git-islands-header-space '(12)))
     (pcase pane
       ('ours (concat (propertize "Yours" 'face 'git-islands-title)
                      (git-islands-at-right (concat (git-islands-merge-button "Accept Left »"
                                                                              #'git-islands-merge-accept-left
                                                                              "Accept Left (C-c C-l)")
                                                    (git-islands-space 8)))))
       ('theirs (concat (git-islands-merge-button "« Accept Right" #'git-islands-merge-accept-right
                                                  "Accept Right (C-c C-r)")
                        (git-islands-ui "  ") (propertize "Theirs" 'face 'git-islands-title)))
       (_ (concat (propertize "Result" 'face 'git-islands-title)
                  (git-islands-ui (format "  %s" (if (zerop left) "all conflicts resolved"
                                                   (format "%d %s left" left
                                                           (if (= left 1) "conflict" "conflicts"))))
                                  (if (zerop left) 'git-islands-added 'git-islands-conflict))
                  (git-islands-at-right
                   (concat (git-islands-merge-button "Both" #'git-islands-merge-accept-both
                                                     "Accept Both (C-c C-b)")
                           " "
                           (git-islands-merge-button "Apply" #'git-islands-merge-apply
                                                     "Save and Mark Resolved (C-c C-c)")
                           " "
                           (git-islands-merge-button "Cancel" #'git-islands-merge-cancel "Cancel (C-c C-k)")
                           (git-islands-space 8)))))))))

;;;###autoload
(defun git-islands-merge3 (root path)
  "Merge PATH of ROOT, a file in conflict, in three panes."
  (require 'git-islands-diff)
  (when-let* ((old (frame-parameter nil 'git-islands-merge)))
    (git-islands-merge-close old))
  (let* ((ours (git-islands-diff-blob-buffer "Yours" path (git-islands-diff-blob root ":2" path)))
         (theirs (git-islands-diff-blob-buffer "Theirs" path (git-islands-diff-blob root ":3" path)))
         (result (find-file-noselect (expand-file-name path root)))
         (merge (git-islands-merge-create :root root :path path
                                          :ours ours :result result :theirs theirs)))
    (git-islands-in-editor
     (lambda ()
       (interactive)
       (setf (git-islands-merge-configuration merge) (current-window-configuration))
       (delete-other-windows)
       (let* ((left (selected-window))
              (middle (split-window-right))
              (right (with-selected-window middle (split-window-right))))
         (balance-windows (window-parent left))
         (set-window-buffer left ours)
         (set-window-buffer middle result)
         (set-window-buffer right theirs)
         (setf (git-islands-merge-windows merge) (list left middle right))
         (cl-loop for buffer in (list ours result theirs)
                  for pane in '(ours result theirs)
                  do (with-current-buffer buffer
                       (setq git-islands-merge-current merge)
                       (git-islands-merge-pane-mode 1)
                       (setq-local header-line-format `(:eval (git-islands-merge-header ',pane)))))
         (git-islands-merge-decorate merge)
         (select-window middle)
         (goto-char (point-min))
         (ignore-errors (git-islands-merge-next)))))
    (set-frame-parameter nil 'git-islands-merge merge)
    merge))

(provide 'git-islands-merge3)
;;; git-islands-merge3.el ends here
