;;; git-islands-annotate.el --- IntelliJ's Annotate with Git Blame -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Each line of the file gets, in the left margin, the date and author of
;; the commit that last changed it, newer commits in a stronger tint.
;; Hovering shows the commit's subject; clicking selects the commit in the
;; Git log.  The blame runs on the buffer's text, so unsaved edits line up
;; (as "Not Committed Yet"), and again after each save.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'git-islands-core)
(require 'git-islands-faces)

(autoload 'git-islands-log-select "git-islands-log")

(defface git-islands-annotate
  '((t (:inherit (shadow default) :height 0.9)))
  "Text of the annotation margin."
  :group 'git-islands)

(defvar git-islands-annotate-tints
  '((dark . ["#3B4A63" "#34404F" "#2E3640" "#2A2E34" "#27292D"])
    (light . ["#D6E4FA" "#E1EBFA" "#EBF1FA" "#F1F4F8" "#F6F7F9"]))
  "Margin backgrounds from the newest commits to the oldest.")

(defvar git-islands-annotate-width 24 "Columns of the annotation margin.")

(defvar-local git-islands-annotate-root nil)
(defvar-local git-islands-annotate-lines nil
  "Vector of the commit annotating each line, from line 1.")
(defvar-local git-islands-annotate-process nil)
(defvar-local git-islands-annotate-saved-margin nil)

(cl-defstruct (git-islands-blame (:constructor git-islands-blame-create))
  "The commit annotating a line."
  hash author time summary)

(defun git-islands-annotate-parse (output)
  "Return the commit of each line in OUTPUT of `git blame --porcelain'."
  (let ((commits (make-hash-table :test #'equal))
        (lines (make-hash-table))
        (count 0))
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      (while (re-search-forward "^\\([0-9a-f]\\{40\\}\\) [0-9]+ \\([0-9]+\\)" nil t)
        (let* ((hash (match-string 1))
               (line (string-to-number (match-string 2)))
               (commit (or (gethash hash commits)
                           (puthash hash (git-islands-blame-create :hash hash) commits))))
          (forward-line 1)
          ;; Fields follow until the line's content, which starts with a tab.
          (while (and (not (eobp)) (not (eq (char-after) ?\t)))
            (cond ((looking-at "author \\(.*\\)")
                   (setf (git-islands-blame-author commit) (match-string 1)))
                  ((looking-at "author-time \\([0-9]+\\)")
                   (setf (git-islands-blame-time commit) (string-to-number (match-string 1))))
                  ((looking-at "summary \\(.*\\)")
                   (setf (git-islands-blame-summary commit) (match-string 1))))
            (forward-line 1))
          (puthash line commit lines)
          (setq count (max count line)))))
    (let ((vector (make-vector count nil)))
      (maphash (lambda (line commit) (aset vector (1- line) commit)) lines)
      vector)))

(defun git-islands-annotate-uncommitted-p (commit)
  "Return non-nil if COMMIT stands for lines not committed yet."
  (string-match-p "\\`0+\\'" (git-islands-blame-hash commit)))

(defun git-islands-annotate-tint (commit times)
  "Return COMMIT's margin background, by its age among TIMES, sorted newest first."
  (let* ((tints (alist-get (frame-parameter nil 'background-mode) git-islands-annotate-tints
                           (alist-get 'light git-islands-annotate-tints)))
         (rank (or (cl-position (git-islands-blame-time commit) times) 0))
         (level (min (1- (length tints))
                     (floor (* (length tints) rank) (max 1 (length times))))))
    (aref tints level)))

(defun git-islands-annotate-text (commit)
  "Return the margin text of COMMIT."
  (if (git-islands-annotate-uncommitted-p commit)
      "Not Committed Yet"
    (concat (format-time-string "%Y/%m/%d" (git-islands-blame-time commit)) " "
            (truncate-string-to-width (or (git-islands-blame-author commit) "")
                                      (- git-islands-annotate-width 12) nil nil "…"))))

(defun git-islands-annotate-draw ()
  "Show the annotations in the left margin."
  (remove-overlays (point-min) (point-max) 'git-islands-annotate t)
  (let* ((lines git-islands-annotate-lines)
         (times (sort (delete-dups (delq nil (mapcar (lambda (commit)
                                                       (and commit (git-islands-blame-time commit)))
                                                     lines)))
                      #'>)))
    (save-excursion
      (goto-char (point-min))
      (dotimes (i (length lines))
        (when-let* ((commit (aref lines i)))
          (let ((overlay (make-overlay (point) (point)))
                (text (propertize (truncate-string-to-width
                                   (git-islands-annotate-text commit) git-islands-annotate-width
                                   nil ?\s)
                                  'face `(:inherit git-islands-annotate
                                                   :background ,(git-islands-annotate-tint commit times))
                                  'help-echo (format "%s %s\n%s"
                                                     (substring (git-islands-blame-hash commit) 0 8)
                                                     (or (git-islands-blame-author commit) "")
                                                     (or (git-islands-blame-summary commit) ""))
                                  'mouse-face 'highlight
                                  'git-islands-blame commit)))
            (overlay-put overlay 'git-islands-annotate t)
            (overlay-put overlay 'before-string
                         (propertize " " 'display `((margin left-margin) ,text)))))
        (forward-line 1)))))

(defvar git-islands-annotate-mode)

(defun git-islands-annotate-run ()
  "Blame the buffer's text in the background, then draw the margin."
  (when (process-live-p git-islands-annotate-process)
    (delete-process git-islands-annotate-process))
  (let* ((buffer (current-buffer))
         (default-directory git-islands-annotate-root)
         (output (generate-new-buffer " *git-blame*" t))
         (path (file-relative-name buffer-file-name git-islands-annotate-root))
         (process (make-process
                   :name "git-blame" :buffer output :noquery t
                   :connection-type 'pipe :coding 'utf-8-unix :file-handler t
                   :command (git-islands-command "blame" "--porcelain" "--contents" "-"
                                                 "--" path)
                   :sentinel
                   (lambda (process _event)
                     (when (memq (process-status process) '(exit signal))
                       (let ((text (with-current-buffer output (buffer-string))))
                         (kill-buffer output)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq git-islands-annotate-process nil)
                             (if (and (eq (process-status process) 'exit)
                                      (zerop (process-exit-status process)))
                                 (progn
                                   (setq git-islands-annotate-lines (git-islands-annotate-parse text))
                                   (when git-islands-annotate-mode (git-islands-annotate-draw)))
                               (message "Cannot annotate: %s"
                                        (car (split-string text "\n" t))))))))))))
    (setq git-islands-annotate-process process)
    (process-send-region process (point-min) (point-max))
    (process-send-eof process)))

(defun git-islands-annotate-set-margin (width)
  "Give every window showing this buffer a left margin WIDTH columns wide."
  (setq left-margin-width width)
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-buffer window (current-buffer))))

(defun git-islands-annotate-commit-at (event)
  "Return the commit annotating the line clicked at EVENT."
  (let* ((posn (event-start event))
         (string (posn-string posn)))
    (or (and string (get-text-property (cdr string) 'git-islands-blame (car string)))
        (with-current-buffer (window-buffer (posn-window posn))
          (save-excursion
            (goto-char (posn-point posn))
            (aref git-islands-annotate-lines (1- (line-number-at-pos))))))))

(defun git-islands-annotate-click (event)
  "Select the commit annotating the line clicked at EVENT in the Git log."
  (interactive "e")
  (when-let* ((commit (git-islands-annotate-commit-at event)))
    (if (git-islands-annotate-uncommitted-p commit)
        (message "Not committed yet")
      (git-islands-log-select git-islands-annotate-root (git-islands-blame-hash commit)))))

(defun git-islands-annotate-show-line ()
  "Select the commit annotating the line at point in the Git log."
  (interactive)
  (let ((commit (and git-islands-annotate-lines
                     (aref git-islands-annotate-lines (1- (min (line-number-at-pos)
                                                               (length git-islands-annotate-lines)))))))
    (cond ((null commit) (user-error "No annotation on this line"))
          ((git-islands-annotate-uncommitted-p commit) (message "Not committed yet"))
          (t (git-islands-log-select git-islands-annotate-root (git-islands-blame-hash commit))))))

(defvar git-islands-annotate-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [left-margin mouse-1] #'git-islands-annotate-click)
    (define-key map (kbd "C-c C-l") #'git-islands-annotate-show-line)
    map)
  "Keys of an annotated buffer.")

(define-minor-mode git-islands-annotate-mode
  "Show the commit last changing each line in the left margin."
  :keymap git-islands-annotate-mode-map
  (if git-islands-annotate-mode
      (progn
        (unless buffer-file-name
          (setq git-islands-annotate-mode nil)
          (user-error "Buffer has no file"))
        (setq git-islands-annotate-root (or (git-islands-root)
                                            (progn (setq git-islands-annotate-mode nil)
                                                   (user-error "Not inside a Git repository"))))
        (setq git-islands-annotate-saved-margin left-margin-width)
        (git-islands-annotate-set-margin git-islands-annotate-width)
        (add-hook 'after-save-hook #'git-islands-annotate-run nil t)
        (git-islands-annotate-run))
    (when (process-live-p git-islands-annotate-process)
      (delete-process git-islands-annotate-process))
    (remove-hook 'after-save-hook #'git-islands-annotate-run t)
    (remove-overlays (point-min) (point-max) 'git-islands-annotate t)
    (setq git-islands-annotate-lines nil)
    (git-islands-annotate-set-margin git-islands-annotate-saved-margin)))

;;;###autoload
(defun git-islands-annotate ()
  "Annotate the buffer with Git blame, or stop annotating it."
  (interactive)
  (git-islands-annotate-mode (if git-islands-annotate-mode -1 1)))

(provide 'git-islands-annotate)
;;; git-islands-annotate.el ends here
