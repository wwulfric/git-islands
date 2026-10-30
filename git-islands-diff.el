;;; git-islands-diff.el --- IntelliJ's side-by-side diff viewer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Two versions of a file next to each other in the editor area: the older
;; one read-only on the left, the newer one on the right, which is the
;; file's own buffer when it is the working tree, so it stays editable.
;; Blank filler lines keep both sides aligned, changed lines are colored as
;; in IntelliJ (blue modified, green added, gray deleted) with the changed
;; words marked, and the windows scroll together.
;;
;; Differences are computed by `git diff --no-index' on both buffers'
;; text, again shortly after the right side is edited.  The right side's
;; hunk at point can be reverted to the left side, or staged when the left
;; side is HEAD or the index.  `q' (or C-c C-k) restores the windows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'smerge-mode)
(require 'git-islands-core)
(require 'git-islands-faces)
(require 'git-islands-tree)

(declare-function magit-run-git-with-input "magit-process" (&rest args))
(declare-function magit-diff-range "magit-diff" (rev-or-range &optional args files))
(declare-function expui-icons-icon "expui-icons" (name &rest props))

(defcustom git-islands-diff-line-numbers t
  "Whether Diff supplies absolute line numbers when a buffer has none.
Only the two diff buffers are affected.  Existing line number styles,
including relative and visual numbering, are preserved.  Nil leaves all
line number settings alone.  Changes apply when entering Diff.
On exit, buffers whose settings Diff changed regain their previous value
and buffer-local status.  This does not enable a global line number mode."
  :type 'boolean
  :group 'git-islands)

(defvar-local git-islands-diff--saved-line-numbers nil
  "Saved (LOCAL VALUE) for line numbers temporarily enabled by Diff.")

(defvar-local git-islands-diff--saved-wrapping nil
  "Previous localness and values of wrapping settings while Diff is active.")

;;;; Faces

(defface git-islands-diff-modified
  '((((background dark)) :background "#29344A" :extend t)
    (t :background "#E3ECFC" :extend t))
  "Lines changed between the two sides."
  :group 'git-islands)

(defface git-islands-diff-added
  '((((background dark)) :background "#2B3D2E" :extend t)
    (t :background "#E1F2E3" :extend t))
  "Lines only the right side has."
  :group 'git-islands)

(defface git-islands-diff-deleted
  '((((background dark)) :background "#3A3B3E" :extend t)
    (t :background "#EBECF0" :extend t))
  "Lines only the left side has."
  :group 'git-islands)

(defface git-islands-diff-word
  '((((background dark)) :background "#3D5A8C")
    (t :background "#BFD3F7"))
  "Words changed within a modified line."
  :group 'git-islands)

(defface git-islands-diff-filler
  '((((background dark)) :background "#26282B" :extend t)
    (t :background "#F5F6F8" :extend t))
  "Blank lines standing for the other side's added lines."
  :group 'git-islands)

;;;; Hunks

(cl-defstruct (git-islands-hunk (:constructor git-islands-hunk-create))
  "A difference: LEFT-COUNT lines from LEFT-START became RIGHT-COUNT lines.
A count of zero means the lines were inserted after, or deleted after,
the start line on that side."
  left-start left-count right-start right-count)

(defun git-islands-hunk-kind (hunk)
  "Return whether HUNK `added', `deleted' or `modified' lines."
  (cond ((zerop (git-islands-hunk-left-count hunk)) 'added)
        ((zerop (git-islands-hunk-right-count hunk)) 'deleted)
        (t 'modified)))

(defun git-islands-diff-parse (output)
  "Return the hunks of OUTPUT, a unified diff with no context."
  (let (hunks)
    (with-temp-buffer
      (insert output)
      (goto-char (point-min))
      (while (re-search-forward
              "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
              nil t)
        (push (git-islands-hunk-create
               :left-start (string-to-number (match-string 1))
               :left-count (if (match-string 2) (string-to-number (match-string 2)) 1)
               :right-start (string-to-number (match-string 3))
               :right-count (if (match-string 4) (string-to-number (match-string 4)) 1))
              hunks)))
    (nreverse hunks)))

(defun git-islands-diff-texts (left right)
  "Return the hunks turning buffer LEFT's text into buffer RIGHT's."
  (let* ((directory (make-temp-file "emacs-diff-" t))
         (a (expand-file-name "a" directory))
         (b (expand-file-name "b" directory)))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (with-current-buffer left
            (write-region nil nil a nil 'silent))
          (with-current-buffer right
            (write-region nil nil b nil 'silent))
          (let ((default-directory directory)
                (command (git-islands-command "diff" "--no-index" "--no-ext-diff" "--no-color"
                                              "--minimal" "-U0" "a" "b")))
            (with-temp-buffer
              (apply #'call-process (car command) nil t nil (cdr command))
              (git-islands-diff-parse (buffer-string)))))
      (delete-directory directory t))))

(defun git-islands-diff-map-line (hunks line from-left)
  "Return the line on the other side facing LINE.
LINE is on the left side if FROM-LEFT, else on the right side."
  (let ((offset 0) result)
    (catch 'done
      (dolist (hunk hunks)
        (let* ((start (if from-left (git-islands-hunk-left-start hunk) (git-islands-hunk-right-start hunk)))
               (count (if from-left (git-islands-hunk-left-count hunk) (git-islands-hunk-right-count hunk)))
               (other-start (if from-left (git-islands-hunk-right-start hunk) (git-islands-hunk-left-start hunk)))
               (other-count (if from-left (git-islands-hunk-right-count hunk) (git-islands-hunk-left-count hunk)))
               ;; An empty side's start is the line before the change.
               (first (if (zerop count) (1+ start) start))
               (other-first (if (zerop other-count) (1+ other-start) other-start)))
          (cond ((< line first) (throw 'done nil))
                ((< line (+ first count))
                 (setq result (+ other-first (min (- line first) (max 0 (1- other-count)))))
                 (throw 'done nil))
                (t (setq offset (- (+ other-first other-count) (+ first count))))))))
    (max 1 (or result (+ line offset)))))

;;;; Sessions

(cl-defstruct (git-islands-diff-session (:constructor git-islands-diff-session-create))
  "A diff shown side by side."
  root path left right left-label right-label
  stage                 ; non-nil when the right side's hunks can be staged
  owns-right            ; non-nil when the right buffer was made for the diff
  hunks windows configuration timer
  saved-header)         ; (LOCAL . VALUE) of the right buffer's header line

(defvar-local git-islands-diff-current nil "The diff session this buffer belongs to.")
(defvar git-islands-diff-syncing nil "Non-nil while one side scrolls the other.")

(defvar git-islands-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<f7>") #'git-islands-diff-next)
    (define-key map (kbd "S-<f7>") #'git-islands-diff-previous)
    (define-key map (kbd "C-c C-n") #'git-islands-diff-next)
    (define-key map (kbd "C-c C-p") #'git-islands-diff-previous)
    (define-key map (kbd "C-c C-r") #'git-islands-diff-revert-hunk)
    (define-key map (kbd "C-c C-s") #'git-islands-diff-stage-hunk)
    (define-key map (kbd "C-c C-u") #'git-islands-diff-unified)
    (define-key map (kbd "C-c C-k") #'git-islands-diff-quit)
    map)
  "Keys of both sides of a diff.")

(defvar git-islands-diff-read-only-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map git-islands-diff-mode-map)
    (define-key map (kbd "q") #'git-islands-diff-quit)
    (define-key map (kbd "n") #'git-islands-diff-next)
    (define-key map (kbd "p") #'git-islands-diff-previous)
    map)
  "Keys of a read-only side of a diff.")

(define-minor-mode git-islands-diff-mode
  "A buffer shown as one side of a side-by-side diff."
  :keymap git-islands-diff-mode-map
  (if git-islands-diff-mode
      (progn
        (unless git-islands-diff--saved-wrapping
          (setq git-islands-diff--saved-wrapping
                (mapcar (lambda (symbol)
                          (list symbol (local-variable-p symbol) (symbol-value symbol)))
                        '(truncate-lines truncate-partial-width-windows)))
          ;; Alignment fillers count logical lines, so never soft-wrap either side.
          (setq-local truncate-lines t
                      truncate-partial-width-windows t))
        (when (and git-islands-diff-line-numbers
                   (null display-line-numbers)
                   (null git-islands-diff--saved-line-numbers))
          (setq git-islands-diff--saved-line-numbers
                (list (local-variable-p 'display-line-numbers)
                      display-line-numbers))
          (setq-local display-line-numbers t))
        (add-hook 'window-scroll-functions #'git-islands-diff-scrolled nil t)
        (add-hook 'after-change-functions #'git-islands-diff-changed nil t)
        (add-hook 'kill-buffer-hook #'git-islands-diff-killed nil t)
        (git-islands-header-style t)
        (when buffer-read-only
          (setq-local minor-mode-overriding-map-alist
                      (list (cons 'git-islands-diff-mode git-islands-diff-read-only-map)))))
    (when git-islands-diff--saved-wrapping
      (dolist (setting git-islands-diff--saved-wrapping)
        (pcase-let ((`(,symbol ,local ,value) setting))
          (if local (set (make-local-variable symbol) value)
            (kill-local-variable symbol))))
      (setq git-islands-diff--saved-wrapping nil))
    (when git-islands-diff--saved-line-numbers
      (pcase-let ((`(,local ,value) git-islands-diff--saved-line-numbers))
        (if local
            (setq-local display-line-numbers value)
          (kill-local-variable 'display-line-numbers)))
      (setq git-islands-diff--saved-line-numbers nil))
    (remove-hook 'window-scroll-functions #'git-islands-diff-scrolled t)
    (remove-hook 'after-change-functions #'git-islands-diff-changed t)
    (remove-hook 'kill-buffer-hook #'git-islands-diff-killed t)
    (git-islands-header-style nil)
    (kill-local-variable 'minor-mode-overriding-map-alist)))

(defun git-islands-diff-killed ()
  "Close the diff when one of its sides is killed."
  (when git-islands-diff-current
    (git-islands-diff-quit)))

(defun git-islands-diff-blob (root rev path)
  "Return PATH's text at REV in ROOT, \"\" for the index, or \"\" if absent."
  (or (and rev path (git-islands-string root "show" (concat rev ":" path))) ""))

(defun git-islands-diff-blob-buffer (label path text)
  "Return a read-only buffer named after LABEL holding TEXT, PATH's version."
  (let ((buffer (generate-new-buffer (format "%s (%s)" (file-name-nondirectory path) label))))
    (with-current-buffer buffer
      (insert text)
      ;; Choose the major mode as for the file itself.
      (let ((buffer-file-name (expand-file-name path)))
        (ignore-errors (set-auto-mode)))
      (setq buffer-read-only t)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    buffer))

(defun git-islands-diff-line-position (line)
  "Return the start of LINE in the current buffer, or its end past the last."
  (save-excursion
    (goto-char (point-min))
    (if (zerop (forward-line (1- line))) (point) (point-max))))

(defun git-islands-diff-clear (buffer)
  "Remove the diff's marks from BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (remove-overlays (point-min) (point-max) 'git-islands-diff t)))))

(defun git-islands-diff-mark (start end face)
  "Color lines START to END with FACE."
  (let ((overlay (make-overlay start end nil t nil)))
    (overlay-put overlay 'face face)
    (overlay-put overlay 'git-islands-diff t)
    (overlay-put overlay 'priority -10)
    overlay))

(defun git-islands-diff-fill (line count)
  "Show COUNT blank lines before LINE of the current buffer."
  (let* ((position (git-islands-diff-line-position line))
         (overlay (make-overlay position position))
         (gap (and (= position (point-max)) (> position (point-min))
                   (not (eq (char-before position) ?\n)))))
    (overlay-put overlay 'before-string
                 (propertize (concat (when gap "\n") (make-string count ?\n))
                             'face 'git-islands-diff-filler))
    (overlay-put overlay 'git-islands-diff t)))

(defun git-islands-diff-decorate (session)
  "Mark SESSION's differences on both sides and align them."
  (let ((left (git-islands-diff-session-left session))
        (right (git-islands-diff-session-right session)))
    (git-islands-diff-clear left)
    (git-islands-diff-clear right)
    (dolist (hunk (git-islands-diff-session-hunks session))
      (let* ((kind (git-islands-hunk-kind hunk))
             (face (pcase kind ('added 'git-islands-diff-added) ('deleted 'git-islands-diff-deleted)
                          (_ 'git-islands-diff-modified)))
             (ls (git-islands-hunk-left-start hunk)) (lc (git-islands-hunk-left-count hunk))
             (rs (git-islands-hunk-right-start hunk)) (rc (git-islands-hunk-right-count hunk))
             left-region right-region)
        (with-current-buffer left
          (save-restriction
            (widen)
            (when (> lc 0)
              (setq left-region (cons (git-islands-diff-line-position ls)
                                      (git-islands-diff-line-position (+ ls lc))))
              (git-islands-diff-mark (car left-region) (cdr left-region) face))
            (when (> rc lc)
              (git-islands-diff-fill (if (> lc 0) (+ ls lc) (1+ ls)) (- rc lc)))))
        (with-current-buffer right
          (save-restriction
            (widen)
            (when (> rc 0)
              (setq right-region (cons (git-islands-diff-line-position rs)
                                       (git-islands-diff-line-position (+ rs rc))))
              (git-islands-diff-mark (car right-region) (cdr right-region) face))
            (when (> lc rc)
              (git-islands-diff-fill (if (> rc 0) (+ rs rc) (1+ rs)) (- lc rc)))))
        ;; Mark the changed words of a modified hunk that is not too long.
        (when (and (eq kind 'modified) (< (+ lc rc) 400))
          (ignore-errors
            (smerge-refine-regions
             (with-current-buffer left (copy-marker (car left-region)))
             (with-current-buffer left (copy-marker (cdr left-region)))
             (with-current-buffer right (copy-marker (car right-region)))
             (with-current-buffer right (copy-marker (cdr right-region)))
             '((face . git-islands-diff-word) (git-islands-diff . t) (priority . -5)))))))))

(defun git-islands-diff-preserve-spacing (buffer)
  "Keep BUFFER's default line metrics on diff overlays and filler strings.
An overlay face can otherwise suppress default text properties, making
highlighted lines shorter than surrounding code in personal configurations."
  (with-current-buffer buffer
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (overlay-get overlay 'git-islands-diff)
        (dolist (property '(line-height line-spacing))
          (let ((value (plist-get default-text-properties property)))
            (overlay-put overlay property value)
            (when-let* ((string (overlay-get overlay 'before-string)))
              (put-text-property 0 (length string) property value string))))))))

(defun git-islands-diff-refresh (session)
  "Compute SESSION's differences again and mark them."
  (when (and (buffer-live-p (git-islands-diff-session-left session))
             (buffer-live-p (git-islands-diff-session-right session)))
    (setf (git-islands-diff-session-hunks session)
          (git-islands-diff-texts (git-islands-diff-session-left session)
                                  (git-islands-diff-session-right session)))
    (git-islands-diff-decorate session)
    (git-islands-diff-preserve-spacing (git-islands-diff-session-left session))
    (git-islands-diff-preserve-spacing (git-islands-diff-session-right session))
    (force-mode-line-update t)))

(defun git-islands-diff-changed (&rest _)
  "Compute the differences again once editing pauses."
  (when-let* ((session git-islands-diff-current))
    (when (timerp (git-islands-diff-session-timer session))
      (cancel-timer (git-islands-diff-session-timer session)))
    (setf (git-islands-diff-session-timer session)
          (run-with-idle-timer 0.4 nil #'git-islands-diff-refresh session))))

;;;; Scrolling together

(defun git-islands-diff-scrolled (window start)
  "Scroll the other side of WINDOW's diff to face START."
  (when-let* ((session git-islands-diff-current))
    (unless git-islands-diff-syncing
      (let* ((from-left (eq (current-buffer) (git-islands-diff-session-left session)))
             (other (seq-find (lambda (other)
                                (and (window-live-p other) (not (eq other window))))
                              (git-islands-diff-session-windows session))))
        (when other
          (let* ((line (line-number-at-pos start t))
                 (target (git-islands-diff-map-line (git-islands-diff-session-hunks session)
                                                    line from-left))
                 (git-islands-diff-syncing t))
            (with-current-buffer (window-buffer other)
              (let ((position (git-islands-diff-line-position target)))
                (set-window-start other position t)
                ;; Redisplay would scroll back to show the window's point.
                (set-window-point other position)))))))))

;;;; Navigation and actions

(defun git-islands-diff-side-lines (hunk left)
  "Return HUNK's (FIRST . LAST) lines on the LEFT side or the right."
  (let ((start (if left (git-islands-hunk-left-start hunk) (git-islands-hunk-right-start hunk)))
        (count (if left (git-islands-hunk-left-count hunk) (git-islands-hunk-right-count hunk))))
    (if (zerop count)
        (cons (1+ start) (1+ start))
      (cons start (+ start count -1)))))

(defun git-islands-diff-left-p ()
  "Return non-nil if the current buffer is its diff's left side."
  (eq (current-buffer) (git-islands-diff-session-left git-islands-diff-current)))

(defun git-islands-diff-hunk-at-point ()
  "Return the hunk at point, or signal an error."
  (let ((line (line-number-at-pos))
        (left (git-islands-diff-left-p)))
    (or (seq-find (lambda (hunk)
                    (let ((lines (git-islands-diff-side-lines hunk left)))
                      (<= (car lines) line (cdr lines))))
                  (git-islands-diff-session-hunks git-islands-diff-current))
        (user-error "No difference at point"))))

(defun git-islands-diff-goto (forward)
  "Move to the next difference, or the previous unless FORWARD."
  (let* ((line (line-number-at-pos))
         (left (git-islands-diff-left-p))
         (starts (mapcar (lambda (hunk) (car (git-islands-diff-side-lines hunk left)))
                         (git-islands-diff-session-hunks git-islands-diff-current)))
         (target (if forward
                     (seq-find (lambda (start) (> start line)) starts)
                   (seq-find (lambda (start) (< start line)) (reverse starts)))))
    (unless target
      (user-error (if forward "No next difference" "No previous difference")))
    (goto-char (git-islands-diff-line-position target))
    (recenter)))

(defun git-islands-diff-next ()
  "Move to the next difference."
  (interactive)
  (git-islands-diff-goto t))

(defun git-islands-diff-previous ()
  "Move to the previous difference."
  (interactive)
  (git-islands-diff-goto nil))

(defun git-islands-diff-hunk-text (buffer start count)
  "Return COUNT lines of BUFFER from line START."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (if (zerop count) ""
        (buffer-substring-no-properties (git-islands-diff-line-position start)
                                        (git-islands-diff-line-position (+ start count)))))))

(defun git-islands-diff-revert-hunk ()
  "Replace the right side's lines of the difference at point with the left's."
  (interactive)
  (let* ((session git-islands-diff-current)
         (hunk (git-islands-diff-hunk-at-point))
         (right (git-islands-diff-session-right session)))
    (with-current-buffer right
      (when buffer-read-only (user-error "The right side cannot be edited")))
    (let ((text (git-islands-diff-hunk-text (git-islands-diff-session-left session)
                                            (git-islands-hunk-left-start hunk)
                                            (git-islands-hunk-left-count hunk))))
      (with-current-buffer right
        (save-restriction
          (widen)
          (let* ((rs (git-islands-hunk-right-start hunk))
                 (rc (git-islands-hunk-right-count hunk))
                 (start (git-islands-diff-line-position (if (zerop rc) (1+ rs) rs)))
                 (end (if (zerop rc) start (git-islands-diff-line-position (+ rs rc)))))
            (save-excursion
              (delete-region start end)
              (goto-char start)
              (insert text))))))
    (git-islands-diff-refresh session)))

(defun git-islands-diff-patch (session hunk)
  "Return a patch applying HUNK of SESSION to its left side's text."
  (let* ((path (git-islands-diff-session-path session))
         (lines (lambda (buffer start count prefix)
                  (mapconcat (lambda (line) (concat prefix line "\n"))
                             (split-string (git-islands-diff-hunk-text buffer start count) "\n")
                             "")))
         (ls (git-islands-hunk-left-start hunk)) (lc (git-islands-hunk-left-count hunk))
         (rs (git-islands-hunk-right-start hunk)) (rc (git-islands-hunk-right-count hunk)))
    (concat (format "--- a/%s\n+++ b/%s\n@@ -%d,%d +%d,%d @@\n" path path ls lc rs rc)
            ;; Each text ends in a newline, so the last split piece is empty.
            (if (zerop lc) ""
              (string-remove-suffix "-\n" (funcall lines (git-islands-diff-session-left session)
                                                   ls lc "-")))
            (if (zerop rc) ""
              (string-remove-suffix "+\n" (funcall lines (git-islands-diff-session-right session)
                                                   rs rc "+"))))))

(defun git-islands-diff-stage-hunk ()
  "Stage the difference at point."
  (interactive)
  (let* ((session git-islands-diff-current)
         (hunk (git-islands-diff-hunk-at-point)))
    (unless (git-islands-diff-session-stage session)
      (user-error "Only changes of the working tree against HEAD or the index can be staged"))
    (git-islands-magit)
    (let ((patch (git-islands-diff-patch session hunk))
          (default-directory (git-islands-diff-session-root session)))
      (if (zerop (with-temp-buffer
                   (insert patch)
                   (magit-run-git-with-input "apply" "--cached" "--unidiff-zero" "-")))
          (message "Staged the change at line %d" (git-islands-hunk-right-start hunk))
        (message "Could not stage this change; the index differs from the left side")))
    (git-islands-refresh (git-islands-diff-session-root session))))

(defun git-islands-diff-unified ()
  "Show the same file's changes in Magit's unified diff, to stage by line."
  (interactive)
  (let ((session git-islands-diff-current))
    (git-islands-diff-quit)
    (git-islands-magit)
    (let ((default-directory (git-islands-diff-session-root session)))
      (magit-diff-range "HEAD" nil (list (git-islands-diff-session-path session))))))

(defun git-islands-diff-quit ()
  "Close the diff and restore the windows as they were."
  (interactive)
  (when-let* ((session git-islands-diff-current))
    (when (timerp (git-islands-diff-session-timer session))
      (cancel-timer (git-islands-diff-session-timer session)))
    (let ((left (git-islands-diff-session-left session))
          (right (git-islands-diff-session-right session)))
      (git-islands-diff-clear left)
      (git-islands-diff-clear right)
      (dolist (buffer (list left right))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (git-islands-diff-mode -1)
            (setq git-islands-diff-current nil))))
      (when (buffer-live-p right)
        (with-current-buffer right
          (pcase-let ((`(,local . ,value) (git-islands-diff-session-saved-header session)))
            (if local
                (setq header-line-format value)
              (kill-local-variable 'header-line-format))))
        (when (git-islands-diff-session-owns-right session)
          (kill-buffer right)))
      (when (buffer-live-p left) (kill-buffer left))
      (when (window-configuration-p (git-islands-diff-session-configuration session))
        (set-window-configuration (git-islands-diff-session-configuration session)))
      (set-frame-parameter nil 'git-islands-diff nil))))

;;;; Headers

(defun git-islands-diff-header-fit (text pixels)
  "Fit TEXT into PIXELS, keeping properties and the full text as a tooltip."
  (let ((result text))
    (when (> (string-pixel-width result) pixels)
      (let ((length (length text)))
        (while (and (> length 0)
                    (> (string-pixel-width
                        (concat (substring text 0 length) "…")) pixels))
          (setq length (1- length)))
        (setq result (if (> pixels (string-pixel-width "…"))
                         (concat (substring text 0 length) "…") ""))))
    (propertize result 'help-echo (substring-no-properties text))))

(defun git-islands-diff-header (left)
  "Return a width-aware header for the diff's LEFT or right side."
  (let* ((session git-islands-diff-current)
         (count (length (git-islands-diff-session-hunks session)))
         (width (max 0 (- (window-body-width nil t) 24
                          (git-islands-line-end-inset))))
         (label (if left (git-islands-diff-session-left-label session)
                  (git-islands-diff-session-right-label session)))
         (title (concat (propertize label 'face 'git-islands-title)
                        (git-islands-ui (concat "  " (git-islands-diff-session-path session))
                                        'git-islands-dim)))
         (actions
          (unless left
            (mapconcat
             (pcase-lambda (`(,icon ,action ,help))
               (git-islands-header-button action help
                                         (expui-icons-icon icon :face 'git-islands-neutral-icon)))
             (append
              (when (>= width 100)
                '(("general/up" git-islands-diff-previous "Previous Difference (S-F7)")
                  ("general/down" git-islands-diff-next "Next Difference (F7)")))
              (when (>= width 220)
                '(("vcs/diff" git-islands-diff-unified "Unified Diff in Magit (C-c C-u)")))
              '(("general/close" git-islands-diff-quit "Close (C-c C-k)")))
             (git-islands-space 6))))
         (summary (git-islands-ui (format "%d differences  " count) 'git-islands-dim))
         (right (concat (when (and actions
                                   (> width (+ (string-pixel-width actions)
                                               (string-pixel-width summary) 180)))
                          summary)
                        actions))
         (room (max 0 (- width (string-pixel-width right) (if actions 12 0)))))
    (concat (propertize " " 'display (git-islands-header-space '(12)))
            (git-islands-diff-header-fit title room)
            (when actions (git-islands-at-right right (git-islands-line-end))))))

;;;; Entry point

(cl-defun git-islands-diff-show (root path &key left-rev left-path right-rev right-empty
                                      left-label right-label)
  "Show PATH of ROOT side by side: LEFT-REV's version against the newer one.
LEFT-REV is a revision, \"\" for the index, or nil when the file is new.
LEFT-PATH is PATH's name at LEFT-REV, if it was renamed.  The right side
is RIGHT-REV's version, or the working tree's when RIGHT-REV is nil;
RIGHT-EMPTY shows the file as deleted instead."
  ;; One diff per frame: close the one shown before.
  (when-let* ((old (frame-parameter nil 'git-islands-diff)))
    (when (buffer-live-p (git-islands-diff-session-left old))
      (with-current-buffer (git-islands-diff-session-left old) (git-islands-diff-quit))))
  (let* ((file (expand-file-name path root))
         (left (git-islands-diff-blob-buffer (or left-label left-rev "empty") path
                                             (git-islands-diff-blob root left-rev (or left-path path))))
         (owns-right (or right-rev right-empty (not (file-exists-p file))))
         (right (if owns-right
                    (git-islands-diff-blob-buffer (or right-label right-rev "deleted") path
                                                  (if right-empty ""
                                                    (git-islands-diff-blob root right-rev path)))
                  (find-file-noselect file)))
         (session (git-islands-diff-session-create
                   :root root :path path :left left :right right
                   :left-label (or left-label
                                   (pcase left-rev ('nil "New file") ("" "Index")
                                          (_ (if (> (length left-rev) 12)
                                                 (substring left-rev 0 8)
                                               left-rev))))
                   :right-label (or right-label
                                    (cond (right-rev (if (> (length right-rev) 12)
                                                         (substring right-rev 0 8)
                                                       right-rev))
                                          (owns-right "Deleted")
                                          (t "Your version")))
                   :stage (and (not owns-right) (member left-rev '("HEAD" "")))
                   :owns-right owns-right
                   :saved-header (with-current-buffer right
                                   (cons (local-variable-p 'header-line-format)
                                         header-line-format)))))
    (git-islands-in-editor
     (lambda ()
       (interactive)
       (setf (git-islands-diff-session-configuration session) (current-window-configuration))
       (delete-other-windows)
       (let ((left-window (selected-window))
             (right-window (split-window-right)))
         (set-window-buffer left-window left)
         (set-window-buffer right-window right)
         (setf (git-islands-diff-session-windows session) (list left-window right-window))
         (dolist (buffer (list left right))
           (with-current-buffer buffer
             (setq git-islands-diff-current session)
             (git-islands-diff-mode 1)
             (setq-local header-line-format
                         `(:eval (git-islands-diff-header ,(eq buffer left))))))
         (git-islands-diff-refresh session)
         (select-window right-window)
         (when-let* ((hunk (car (git-islands-diff-session-hunks session))))
           (goto-char (git-islands-diff-line-position (car (git-islands-diff-side-lines hunk nil))))
           (recenter)))))
    (set-frame-parameter nil 'git-islands-diff session)
    session))

(provide 'git-islands-diff)
;;; git-islands-diff.el ends here
