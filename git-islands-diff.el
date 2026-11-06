;;; git-islands-diff.el --- IntelliJ's side-by-side diff viewer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Two versions of a file next to each other in the editor area: the older
;; one read-only on the left, the newer one on the right, which is the
;; file's own buffer when it is the working tree, so it stays editable.
;; Blank filler lines keep both sides aligned, changed lines are colored as
;; in IntelliJ (blue modified, green added, gray deleted) with the changed
;; words marked, and the windows scroll together.  The unified viewer
;; shows the same differences in one window, old lines above new ones.
;;
;; Differences are computed by `git diff --no-index' on both buffers'
;; text, again shortly after the right side is edited.  The right side's
;; hunk at point can be reverted to the left side, with the arrow in the
;; gutter between the sides, or staged with the checkbox beside it when
;; the left side is HEAD or the index.  Opened from a list of changes, a
;; diff steps to the list's next or previous file.  `q' (or C-c C-k)
;; restores the windows.

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
(declare-function expui-icons-image "expui-icons" (name &rest props))

(defcustom git-islands-diff-line-numbers t
  "Whether Diff supplies absolute line numbers when a buffer has none.
Only the two diff buffers are affected.  Existing line number styles,
including relative and visual numbering, are preserved.  Nil leaves all
line number settings alone.  Changes apply when entering Diff.
On exit, buffers whose settings Diff changed regain their previous value
and buffer-local status.  This does not enable a global line number mode."
  :type 'boolean
  :group 'git-islands)

(defcustom git-islands-diff-viewer 'side-by-side
  "How a diff shows its two versions: `side-by-side' or `unified'.
Switching a diff's viewer sets this for the diffs after it, as IntelliJ
remembers the viewer last chosen."
  :type '(choice (const :tag "Side by side" side-by-side)
                 (const :tag "Unified" unified))
  :group 'git-islands)

(defvar-local git-islands-diff--saved-line-numbers nil
  "Saved (LOCAL VALUE) for line numbers temporarily enabled by Diff.")

(defvar-local git-islands-diff--saved-wrapping nil
  "Previous localness and values of settings Diff changes while active.")

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
  "Blank lines standing for lines the other side no longer has."
  :group 'git-islands)

;; Fillers take a paler tint of their change's color, as IntelliJ's aligned
;; viewer paints the gap, so that a gap reads as the other side's lines.
(defface git-islands-diff-filler-added
  '((((background dark)) :background "#242E27" :extend t)
    (t :background "#F0F8F1" :extend t))
  "Blank lines standing for the other side's added lines."
  :group 'git-islands)

(defface git-islands-diff-filler-modified
  '((((background dark)) :background "#242A36" :extend t)
    (t :background "#F1F5FD" :extend t))
  "Blank lines standing for the other side's extra changed lines."
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
  "A diff shown side by side, or unified."
  root path left right left-label right-label
  stage                 ; non-nil when the right side's hunks can be staged
  staged                ; the hunks the index already has
  owns-right            ; non-nil when the right buffer was made for the diff
  hunks windows configuration timer
  unified               ; the unified viewer's buffer, while it is shown
  step                  ; function showing the next file's diff, or nil
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
    (define-key map (kbd "C-c C-u") #'git-islands-diff-toggle-viewer)
    (define-key map (kbd "C-c C-f") #'git-islands-diff-next-file)
    (define-key map (kbd "C-c C-b") #'git-islands-diff-previous-file)
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

(defun git-islands-diff-tabs ()
  "Return the tabs of a diff's window: its own buffer only.
A diff is one editor tab, as in IntelliJ, not the editor's whole strip."
  (list (current-buffer)))

(define-minor-mode git-islands-diff-mode
  "A buffer shown as one side of a side-by-side diff, or as a unified one."
  :keymap git-islands-diff-mode-map
  (if git-islands-diff-mode
      (progn
        (unless git-islands-diff--saved-wrapping
          (setq git-islands-diff--saved-wrapping
                (mapcar (lambda (symbol)
                          (list symbol (local-variable-p symbol)
                                ;; tab-line may not be loaded.
                                (and (boundp symbol) (symbol-value symbol))))
                        '(truncate-lines truncate-partial-width-windows
                          left-margin-width right-margin-width tab-line-tabs-function)))
          ;; Alignment fillers count logical lines, so never soft-wrap either side.
          (setq-local truncate-lines t
                      truncate-partial-width-windows t
                      tab-line-tabs-function #'git-islands-diff-tabs))
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
        (tool-islands-header-style t)
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
    (tool-islands-header-style nil)
    (kill-local-variable 'minor-mode-overriding-map-alist)))

(defun git-islands-diff-killed ()
  "Close the diff when one of its sides is killed."
  (when git-islands-diff-current
    (git-islands-diff-quit)))

(defun git-islands-diff-blob (root rev path)
  "Return PATH's text at REV in ROOT, \"\" for the index, or \"\" if absent."
  (or (and rev path (git-islands-string root "show" (concat rev ":" path))) ""))

(defun git-islands-diff-blob-buffer (label root path text)
  "Return a read-only buffer named after LABEL holding TEXT, PATH's version.
PATH is relative to ROOT."
  (let ((buffer (generate-new-buffer (format "%s (%s)" (file-name-nondirectory path) label))))
    (with-current-buffer buffer
      (insert text)
      ;; Choose the major mode as for the file itself, but run its hooks
      ;; only once the buffer no longer seems to visit the file: a hook
      ;; could save it there, as lsp-bridge does when the file is missing.
      (let ((buffer-file-name (expand-file-name path root)))
        (delay-mode-hooks (ignore-errors (set-auto-mode))))
      (ignore-errors (run-mode-hooks))
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

(defun git-islands-diff-fill (line count &optional face filler)
  "Show COUNT blank lines before LINE of the current buffer.
FACE is the one the line before LINE is colored with, if any.  FILLER
is the blank lines' face, `git-islands-diff-filler' by default."
  (let* ((position (git-islands-diff-line-position line))
         (newline (and (> line 1) (eq (char-before position) ?\n)))
         ;; Text typed at the end of the previous line stays out of it.
         (overlay (if newline (make-overlay (1- position) position nil t nil)
                    (make-overlay position position)))
         (rows (propertize (make-string count ?\n)
                           'face (or filler 'git-islands-diff-filler))))
    (cond
     ;; The rows come after the previous line rather than before LINE: a
     ;; line number goes on a line's first row, which would be filler.
     ;; They replace that line's newline; a newline in FACE still ends its
     ;; row.  A newline has no glyph to hold the cursor at the line's end,
     ;; so a space before it does.
     (newline
      (overlay-put overlay 'display (concat (propertize " " 'face face 'cursor t)
                                            (propertize "\n" 'face face) rows)))
     ((= line 1) (overlay-put overlay 'before-string rows))
     ;; Past a last line with no newline.
     (t (overlay-put overlay 'after-string (concat "\n" rows))))
    (overlay-put overlay 'git-islands-diff t)))

(defun git-islands-diff-filler-face (kind)
  "Return the face of blank lines standing for a hunk of KIND."
  (pcase kind
    ('added 'git-islands-diff-filler-added)
    ('modified 'git-islands-diff-filler-modified)
    (_ 'git-islands-diff-filler)))

(defun git-islands-diff-whole-lines (start end face extra)
  "Color up to EXTRA lines from START to END that changed as a whole with FACE.
Within a modified hunk, the side with EXTRA lines more than the other
has lines with no counterpart: one all of whose words changed is new, or
gone, as a whole, and IntelliJ colors it as added or deleted rather than
marking every word.  New lines tend to follow the changed ones they
come with, so lines are taken from the end.  Marks of whitespace alone
are dropped."
  (let (lines)
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (push (point) lines)
        (forward-line 1))
      ;; The last line first.
      (dolist (bol lines)
        (goto-char bol)
        (let* ((eol (line-end-position))
               (words (seq-filter (lambda (overlay)
                                    (eq (overlay-get overlay 'face) 'git-islands-diff-word))
                                  (overlays-in bol eol))))
          (dolist (overlay words)
            (when (string-blank-p (buffer-substring-no-properties
                                   (overlay-start overlay) (overlay-end overlay)))
              (delete-overlay overlay)
              (setq words (delq overlay words))))
          (when (and words (> extra 0)
                     (save-excursion
                       (catch 'unchanged
                         (while (re-search-forward "[^ \t]" eol t)
                           (let ((char (match-beginning 0)))
                             (unless (seq-some (lambda (overlay)
                                                 (and (<= (overlay-start overlay) char)
                                                      (< char (overlay-end overlay))))
                                               words)
                               (throw 'unchanged nil))))
                         t)))
            ;; A run of changed words can span lines; keep its other lines.
            (dolist (overlay words)
              (when (< (overlay-start overlay) bol)
                (move-overlay (copy-overlay overlay) (overlay-start overlay) bol))
              (when (> (overlay-end overlay) (1+ eol))
                (move-overlay (copy-overlay overlay) (1+ eol) (overlay-end overlay)))
              (delete-overlay overlay))
            (overlay-put (git-islands-diff-mark bol (min (point-max) (1+ eol)) face)
                         'priority -8)
            (setq extra (1- extra))))))))

(defun git-islands-diff-gutter-icon (margin icon help action)
  "Return a string showing ICON in MARGIN, with tooltip HELP.
MARGIN is `left-margin' or `right-margin'.  Clicking the icon calls
ACTION with no arguments, in the clicked window.  The image is the
margin spec's own value: a display property nested in a margin's
string would not be drawn."
  (let ((map (make-sparse-keymap)))
    (define-key map (vector margin 'mouse-1)
                (lambda (event)
                  (interactive "e")
                  (select-window (posn-window (event-start event)))
                  (funcall action)))
    (propertize " " 'display `((margin ,margin)
                               ,(or (expui-icons-image icon :ascent 'center) "•"))
                'face 'tool-islands-neutral-icon
                'local-map map 'help-echo help 'pointer 'hand)))

(defun git-islands-diff-gutter (line margin icon help action)
  "Show ICON in MARGIN beside LINE of the current buffer.
HELP and ACTION are as for `git-islands-diff-gutter-icon'."
  (let ((overlay (make-overlay (git-islands-diff-line-position line)
                               (git-islands-diff-line-position line))))
    (overlay-put overlay 'before-string
                 (git-islands-diff-gutter-icon margin icon help action))
    (overlay-put overlay 'git-islands-diff t)
    overlay))

(defun git-islands-diff-actions (session hunk)
  "Put HUNK's actions of SESSION in the gutter between the sides.
As in IntelliJ: an arrow on the left side replaces the right side's
lines with the left's, and a checkbox on the right side stages them, or
unstages them when the index already has them."
  (let ((line (lambda (left)
                (let ((start (if left (git-islands-hunk-left-start hunk)
                               (git-islands-hunk-right-start hunk))))
                  ;; An empty side's hunk sits after its start line.
                  (max 1 start)))))
    (unless (with-current-buffer (git-islands-diff-session-right session) buffer-read-only)
      (with-current-buffer (git-islands-diff-session-left session)
        (git-islands-diff-gutter (funcall line t) 'right-margin "diff/arrowRight@14x14"
                                 "Revert (C-c C-r)"
                                 (lambda () (git-islands-diff-revert-hunk hunk)))))
    (when (git-islands-diff-session-stage session)
      (let ((staged (memq hunk (git-islands-diff-session-staged session))))
        (with-current-buffer (git-islands-diff-session-right session)
          (git-islands-diff-gutter (funcall line nil) 'left-margin
                                   (if staged "diff/gutterCheckBoxSelected@14x14"
                                     "diff/gutterCheckBox@14x14")
                                   (if staged "Unstage (C-c C-s)" "Stage (C-c C-s)")
                                   (lambda () (git-islands-diff-stage-hunk hunk))))))))

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
             (filler (git-islands-diff-filler-face kind))
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
              (git-islands-diff-fill (if (> lc 0) (+ ls lc) (1+ ls)) (- rc lc)
                                     (and (> lc 0) face) filler))))
        (with-current-buffer right
          (save-restriction
            (widen)
            (when (> rc 0)
              (setq right-region (cons (git-islands-diff-line-position rs)
                                       (git-islands-diff-line-position (+ rs rc))))
              (git-islands-diff-mark (car right-region) (cdr right-region) face))
            (when (> lc rc)
              (git-islands-diff-fill (if (> rc 0) (+ rs rc) (1+ rs)) (- lc rc)
                                     (and (> rc 0) face) filler))))
        ;; Mark the changed words of a modified hunk that is not too long.
        (when (and (eq kind 'modified) (< (+ lc rc) 400))
          (ignore-errors
            (smerge-refine-regions
             (with-current-buffer left (copy-marker (car left-region)))
             (with-current-buffer left (copy-marker (cdr left-region)))
             (with-current-buffer right (copy-marker (car right-region)))
             (with-current-buffer right (copy-marker (cdr right-region)))
             '((face . git-islands-diff-word) (git-islands-diff . t) (priority . -5))))
          (with-current-buffer left
            (save-restriction
              (widen)
              (git-islands-diff-whole-lines (car left-region) (cdr left-region)
                                            'git-islands-diff-deleted (- lc rc))))
          (with-current-buffer right
            (save-restriction
              (widen)
              (git-islands-diff-whole-lines (car right-region) (cdr right-region)
                                            'git-islands-diff-added (- rc lc)))))
        (git-islands-diff-actions session hunk)))))

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
            (dolist (side '(before-string after-string display))
              (when-let* ((string (overlay-get overlay side)))
                (put-text-property 0 (length string) property value string)))))))))

(defun git-islands-diff-refresh (session)
  "Compute SESSION's differences again and mark them."
  (when (and (buffer-live-p (git-islands-diff-session-left session))
             (buffer-live-p (git-islands-diff-session-right session)))
    (setf (git-islands-diff-session-hunks session)
          (git-islands-diff-texts (git-islands-diff-session-left session)
                                  (git-islands-diff-session-right session)))
    (setf (git-islands-diff-session-staged session) (git-islands-diff-staged session))
    (git-islands-diff-decorate session)
    (git-islands-diff-preserve-spacing (git-islands-diff-session-left session))
    (git-islands-diff-preserve-spacing (git-islands-diff-session-right session))
    (when (buffer-live-p (git-islands-diff-session-unified session))
      (git-islands-diff-unified-render session))
    (force-mode-line-update t)))

(defun git-islands-diff-staged (session)
  "Return those of SESSION's hunks against HEAD that the index has.
A hunk is staged when no difference between the index and the right
side touches its lines."
  (when (equal (git-islands-diff-session-stage session) "HEAD")
    (let ((index (git-islands-diff-blob (git-islands-diff-session-root session) ""
                                        (git-islands-diff-session-path session)))
          (overlap (lambda (a b)
                     (let ((a (git-islands-diff-side-lines a nil))
                           (b (git-islands-diff-side-lines b nil)))
                       (and (<= (car a) (cdr b)) (<= (car b) (cdr a)))))))
      (with-temp-buffer
        (insert index)
        (let ((unstaged (git-islands-diff-texts (current-buffer)
                                                (git-islands-diff-session-right session))))
          (seq-remove (lambda (hunk)
                        (seq-some (lambda (other) (funcall overlap hunk other)) unstaged))
                      (git-islands-diff-session-hunks session)))))))

(defun git-islands-diff-changed (&rest _)
  "Compute the differences again once editing of the right side pauses.
The unified viewer's own rendering is no edit."
  (when-let* ((session git-islands-diff-current)
              ((eq (current-buffer) (git-islands-diff-session-right session))))
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

(defun git-islands-diff-hunk-at (&optional session)
  "Return the hunk of SESSION at point, or nil.
SESSION defaults to the current buffer's."
  (let ((session (or session git-islands-diff-current)))
    (if (eq (current-buffer) (git-islands-diff-session-unified session))
        (get-text-property (pos-bol) 'git-islands-diff-hunk)
      (let ((line (line-number-at-pos))
            (left (eq (current-buffer) (git-islands-diff-session-left session))))
        (seq-find (lambda (hunk)
                    (let ((lines (git-islands-diff-side-lines hunk left)))
                      (<= (car lines) line (cdr lines))))
                  (git-islands-diff-session-hunks session))))))

(defun git-islands-diff-hunk-at-point ()
  "Return the hunk at point, or signal an error."
  (or (git-islands-diff-hunk-at) (user-error "No difference at point")))

(defvar-local git-islands-diff--unified-starts nil
  "The first lines of the unified viewer's hunks, in order.")

(defun git-islands-diff-starts ()
  "Return the first lines of the hunks in the current buffer, in order."
  (if (eq (current-buffer) (git-islands-diff-session-unified git-islands-diff-current))
      git-islands-diff--unified-starts
    (let ((left (git-islands-diff-left-p)))
      (mapcar (lambda (hunk) (car (git-islands-diff-side-lines hunk left)))
              (git-islands-diff-session-hunks git-islands-diff-current)))))

(defvar git-islands-diff--step-offered nil
  "The command that last offered to go on to another file.")

(defun git-islands-diff-goto (forward)
  "Move to the next difference, or the previous unless FORWARD.
Past the last one, as in IntelliJ, the same key pressed again goes on to
the next file of the list the diff was opened from."
  (let* ((line (line-number-at-pos))
         (starts (git-islands-diff-starts))
         (target (if forward
                     (seq-find (lambda (start) (> start line)) starts)
                   (seq-find (lambda (start) (< start line)) (reverse starts)))))
    (cond
     (target
      (setq git-islands-diff--step-offered nil)
      (goto-char (git-islands-diff-line-position target))
      (recenter))
     ((not (git-islands-diff-session-step git-islands-diff-current))
      (user-error (if forward "No next difference" "No previous difference")))
     ((and (eq last-command this-command) (eq git-islands-diff--step-offered this-command))
      (setq git-islands-diff--step-offered nil)
      (git-islands-diff-step forward (not forward)))
     (t
      (setq git-islands-diff--step-offered this-command)
      (message "Press %s again to go to the %s file"
               (substitute-command-keys (format "\\[%s]" this-command))
               (if forward "next" "previous"))))))

(defun git-islands-diff-next ()
  "Move to the next difference."
  (interactive)
  (git-islands-diff-goto t))

(defun git-islands-diff-previous ()
  "Move to the previous difference."
  (interactive)
  (git-islands-diff-goto nil))

(defun git-islands-diff-step (forward &optional last)
  "Show the diff of the next file of the list, or the previous unless FORWARD.
Point goes to the new diff's last difference if LAST, else its first."
  (let ((step (git-islands-diff-session-step git-islands-diff-current)))
    (unless (and step (funcall step forward))
      (user-error (if forward "No next file" "No previous file")))
    ;; The new diff is in the selected window; this buffer may be gone.
    (set-buffer (window-buffer))
    (when-let* ((last)
                (session (frame-parameter nil 'git-islands-diff))
                ((eq git-islands-diff-current session))
                (start (car (last (git-islands-diff-starts)))))
      (goto-char (git-islands-diff-line-position start))
      (recenter))))

(defun git-islands-diff-next-file ()
  "Show the diff of the next file of the list the diff was opened from."
  (interactive)
  (git-islands-diff-step t))

(defun git-islands-diff-previous-file ()
  "Show the diff of the previous file of the list the diff was opened from."
  (interactive)
  (git-islands-diff-step nil))

(defun git-islands-diff-sibling (buffer path forward show &optional skip)
  "In list BUFFER, call SHOW on the file row after PATH's.
The row before it, unless FORWARD.  Rows are those with a
`git-islands-entry' property; SKIP, if non-nil, is a predicate on
entries to pass over.  Point moves to the row, in BUFFER's window too.
Return non-nil if there was such a row."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let (rows)
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (when-let* ((entry (get-text-property (point) 'git-islands-entry)))
              (unless (and skip (funcall skip entry))
                (push (cons (point) entry) rows)))
            (forward-line 1)))
        (setq rows (nreverse rows))
        (unless forward (setq rows (reverse rows)))
        (when-let* ((row (cadr (seq-drop-while
                                (lambda (row) (not (equal (git-islands-entry-path (cdr row)) path)))
                                rows))))
          (goto-char (car row))
          (when-let* ((window (get-buffer-window buffer t)))
            (set-window-point window (car row)))
          (funcall show)
          t)))))

(defun git-islands-diff-hunk-text (buffer start count)
  "Return COUNT lines of BUFFER from line START."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (if (zerop count) ""
        (buffer-substring-no-properties (git-islands-diff-line-position start)
                                        (git-islands-diff-line-position (+ start count)))))))

(defun git-islands-diff-revert-hunk (&optional hunk)
  "Replace the right side's lines of HUNK with the left's.
HUNK defaults to the difference at point."
  (interactive)
  (let* ((session git-islands-diff-current)
         (hunk (or hunk (git-islands-diff-hunk-at-point)))
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

(defun git-islands-diff-stage-hunk (&optional hunk)
  "Stage HUNK, or unstage it when the index already has it.
HUNK defaults to the difference at point."
  (interactive)
  (let* ((session git-islands-diff-current)
         (hunk (or hunk (git-islands-diff-hunk-at-point)))
         (staged (memq hunk (git-islands-diff-session-staged session))))
    (unless (git-islands-diff-session-stage session)
      (user-error "Only changes of the working tree against HEAD or the index can be staged"))
    (git-islands-magit)
    (let ((patch (git-islands-diff-patch session hunk))
          (default-directory (git-islands-diff-session-root session)))
      (if (zerop (with-temp-buffer
                   (insert patch)
                   (apply #'magit-run-git-with-input "apply" "--cached" "--unidiff-zero"
                          (append (and staged '("--reverse")) '("-")))))
          (message "%s the change at line %d" (if staged "Unstaged" "Staged")
                   (git-islands-hunk-right-start hunk))
        (message (if staged "Could not unstage this change; the index differs from the right side"
                   "Could not stage this change; the index differs from the left side"))))
    (git-islands-refresh (git-islands-diff-session-root session))
    (git-islands-diff-refresh session)))

(defun git-islands-diff-magit ()
  "Show the same file's changes in Magit's unified diff, to stage by line."
  (interactive)
  (let ((session git-islands-diff-current))
    (git-islands-diff-quit)
    (git-islands-magit)
    (let ((default-directory (git-islands-diff-session-root session)))
      (magit-diff-range "HEAD" nil (list (git-islands-diff-session-path session))))))

(define-obsolete-function-alias 'git-islands-diff-unified #'git-islands-diff-magit "0.1.0")

;;;; Unified viewer

(defun git-islands-diff-unified-render (session)
  "Fill SESSION's unified viewer: the right side with the left's old lines.
Each hunk shows its old lines, then its new ones, colored as on the two
sides; the margin numbers lines on both sides, as IntelliJ's gutter does."
  (let* ((buffer (git-islands-diff-session-unified session))
         (left (git-islands-diff-session-left session))
         (right (git-islands-diff-session-right session))
         (total (max (with-current-buffer left (line-number-at-pos (point-max) t))
                     (with-current-buffer right (line-number-at-pos (point-max) t))))
         (digits (length (number-to-string total)))
         (window (get-buffer-window buffer))
         (stage (git-islands-diff-session-stage session))
         (revert (not (with-current-buffer right buffer-read-only)))
         ;; The actions follow the numbers, in columns as wide as the icons.
         (icon-columns (ceiling (* (+ (if revert 1 0) (if stage 1 0)) 18)
                         (float (frame-char-width))))
         (old 1) (new 1) starts)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (line (line-number-at-pos))
            (top (and window (line-number-at-pos (window-start window)))))
        (git-islands-diff-clear buffer)
        (erase-buffer)
        (cl-flet* ((number (n) (if n (format (format "%%%dd" digits) n) (make-string digits ?\s)))
                   (insert-lines (source start count old-step new-step face hunk)
                     ;; COUNT lines of SOURCE from START, numbered on the
                     ;; sides that have them.
                     (let ((text (git-islands-diff-hunk-text source start count))
                           (from (point)))
                       (unless (or (string-empty-p text) (string-suffix-p "\n" text))
                         (setq text (concat text "\n")))
                       (insert text)
                       (save-excursion
                         (goto-char from)
                         (while (< (point) (point-max))
                           (let ((overlay (make-overlay (point) (point))))
                             (overlay-put overlay 'before-string
                                          (propertize " " 'display
                                                      `((margin left-margin)
                                                        ,(propertize
                                                          (concat " " (number (and old-step old)) " "
                                                                  (number (and new-step new)) " ")
                                                          'face 'line-number))))
                             (overlay-put overlay 'git-islands-diff t))
                           (when old-step (setq old (1+ old)))
                           (when new-step (setq new (1+ new)))
                           (forward-line 1)))
                       (when (> (point-max) from)
                         (when face (git-islands-diff-mark from (point-max) face))
                         (when hunk
                           (put-text-property from (point-max) 'git-islands-diff-hunk hunk)))
                       (cons from (point-max)))))
          (dolist (hunk (git-islands-diff-session-hunks session))
            (let* ((kind (git-islands-hunk-kind hunk))
                   (lc (git-islands-hunk-left-count hunk))
                   (rs (git-islands-hunk-right-start hunk))
                   (rc (git-islands-hunk-right-count hunk))
                   (first (if (zerop rc) (1+ rs) rs)))
              (insert-lines right new (- first new) t t nil nil)
              (push (line-number-at-pos) starts)
              (let* ((hunk-start (point))
                     (removed (insert-lines left old lc t nil 'git-islands-diff-deleted hunk))
                     (added (insert-lines right new rc nil t
                                          (if (eq kind 'added) 'git-islands-diff-added
                                            'git-islands-diff-modified)
                                          hunk)))
                (when (and (eq kind 'modified) (< (+ lc rc) 400))
                  (ignore-errors
                    (smerge-refine-regions (copy-marker (car removed)) (copy-marker (cdr removed))
                                           (copy-marker (car added)) (copy-marker (cdr added))
                                           '((face . git-islands-diff-word) (git-islands-diff . t)
                                             (priority . -5))))
                  (git-islands-diff-whole-lines (car removed) (cdr removed)
                                                'git-islands-diff-deleted (- lc rc))
                  (git-islands-diff-whole-lines (car added) (cdr added)
                                                'git-islands-diff-added (- rc lc)))
                ;; The hunk's actions take the actions' column of its first line.
                (let ((icons (concat
                              (when revert
                                (git-islands-diff-gutter-icon
                                 'left-margin "diff/revert@14x14" "Revert (C-c C-r)"
                                 (lambda () (git-islands-diff-revert-hunk hunk))))
                              (when stage
                                (let ((staged (memq hunk (git-islands-diff-session-staged session))))
                                  (git-islands-diff-gutter-icon
                                   'left-margin
                                   (if staged "diff/gutterCheckBoxSelected@14x14"
                                     "diff/gutterCheckBox@14x14")
                                   (if staged "Unstage (C-c C-s)" "Stage (C-c C-s)")
                                   (lambda () (git-islands-diff-stage-hunk hunk))))))))
                  (when-let* ((overlay (seq-find (lambda (overlay) (overlay-get overlay 'before-string))
                                                 (overlays-in hunk-start hunk-start))))
                    (overlay-put overlay 'before-string
                                 (concat (overlay-get overlay 'before-string) icons)))))))
          (insert-lines right new (- (with-current-buffer right (line-number-at-pos (point-max) t))
                                     new -1)
                        t t nil nil))
        (setq git-islands-diff--unified-starts (nreverse starts))
        (setq left-margin-width (+ 3 (* 2 digits) icon-columns))
        (when window
          (set-window-margins window left-margin-width right-margin-width)
          (goto-char (git-islands-diff-line-position line))
          (when top
            (set-window-start window (git-islands-diff-line-position top) t))
          (set-window-point window (point)))
        (set-buffer-modified-p nil)))
    (git-islands-diff-preserve-spacing buffer)))

(defun git-islands-diff-unified-buffer (session)
  "Return a new unified viewer for SESSION, in the file's major mode."
  (let ((buffer (git-islands-diff-blob-buffer "Unified" (git-islands-diff-session-root session)
                                              (git-islands-diff-session-path session) "")))
    (with-current-buffer buffer
      (setq git-islands-diff-current session)
      ;; The margin numbers both sides' lines, so turn off the buffer's
      ;; own numbers, even those a mode hook such as `prog-mode-hook' set.
      (setq-local display-line-numbers nil)
      (let ((git-islands-diff-line-numbers nil))
        (git-islands-diff-mode 1))
      (setq-local header-line-format '(:eval (git-islands-diff-header 'unified))))
    buffer))

(defun git-islands-diff-kill-unified (session)
  "Kill SESSION's unified viewer, if any, without closing the diff."
  (when-let* ((buffer (git-islands-diff-session-unified session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (git-islands-diff-mode -1)
        (setq git-islands-diff-current nil))
      (kill-buffer buffer))
    (setf (git-islands-diff-session-unified session) nil)))

(defun git-islands-diff-layout (session viewer &optional hunk)
  "Show SESSION in VIEWER, `side-by-side' or `unified', in the selected window.
Point goes to HUNK, or to the first difference."
  (let ((left (git-islands-diff-session-left session))
        (right (git-islands-diff-session-right session)))
    (delete-other-windows)
    (if (eq viewer 'unified)
        (let ((buffer (or (and (buffer-live-p (git-islands-diff-session-unified session))
                               (git-islands-diff-session-unified session))
                          (setf (git-islands-diff-session-unified session)
                                (git-islands-diff-unified-buffer session)))))
          (set-window-buffer (selected-window) buffer)
          (set-buffer buffer)
          (setf (git-islands-diff-session-windows session) (list (selected-window)))
          (git-islands-diff-unified-render session)
          (let ((line (or (and hunk (with-current-buffer buffer
                                      (when-let* ((match (save-excursion
                                                           (goto-char (point-min))
                                                           (text-property-search-forward
                                                            'git-islands-diff-hunk hunk #'eq))))
                                        (line-number-at-pos (prop-match-beginning match)))))
                          (car (with-current-buffer buffer git-islands-diff--unified-starts)))))
            (when line
              (goto-char (git-islands-diff-line-position line))
              (recenter))))
      (git-islands-diff-kill-unified session)
      (let ((left-window (selected-window))
            (right-window (split-window-right)))
        (set-window-buffer left-window left)
        (set-window-buffer right-window right)
        (setf (git-islands-diff-session-windows session) (list left-window right-window))
        (dolist (window (list left-window right-window))
          (with-current-buffer (window-buffer window)
            (set-window-margins window left-margin-width right-margin-width)))
        (select-window right-window)
        (when-let* ((hunk (or hunk (car (git-islands-diff-session-hunks session)))))
          (goto-char (git-islands-diff-line-position (car (git-islands-diff-side-lines hunk nil))))
          (recenter))))))

(defun git-islands-diff-toggle-viewer ()
  "Switch the diff between the side-by-side and the unified viewer."
  (interactive)
  (let* ((session git-islands-diff-current)
         (hunk (git-islands-diff-hunk-at session)))
    (setq git-islands-diff-viewer
          (if (buffer-live-p (git-islands-diff-session-unified session)) 'side-by-side 'unified))
    (git-islands-diff-layout session git-islands-diff-viewer hunk)))

(defun git-islands-diff-quit ()
  "Close the diff and restore the windows as they were."
  (interactive)
  (when-let* ((session git-islands-diff-current))
    (when (timerp (git-islands-diff-session-timer session))
      (cancel-timer (git-islands-diff-session-timer session)))
    (git-islands-diff-kill-unified session)
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

(defun git-islands-diff-position (session)
  "Return where SESSION's differences stand, as its header says it.
That is \"2 of 8\" when point, in the window last selected, is in a
difference, else how many differences there are."
  (let* ((count (length (git-islands-diff-session-hunks session)))
         (window (old-selected-window))
         (hunk (and (window-live-p window)
                    (with-current-buffer (window-buffer window)
                      (and (eq git-islands-diff-current session)
                           (save-excursion
                             (goto-char (window-point window))
                             (git-islands-diff-hunk-at session))))))
         (index (and hunk (seq-position (git-islands-diff-session-hunks session) hunk #'eq))))
    (cond (index (format "%d of %d" (1+ index) count))
          ((zerop count) "No differences")
          ((= count 1) "1 difference")
          (t (format "%d differences" count)))))

(defun git-islands-diff-buttons (buttons)
  "Return header BUTTONS, each (ICON COMMAND HELP), with gaps between them."
  (mapconcat (pcase-lambda (`(,icon ,action ,help))
               (tool-islands-header-button action help
                                          (expui-icons-icon icon :face 'tool-islands-neutral-icon)))
             buttons (tool-islands-space 6)))

(defun git-islands-diff-header (side)
  "Return a width-aware header for SIDE of the diff.
SIDE is `unified', or non-nil for the left side, nil for the right.
Together the headers make IntelliJ's diff toolbar: the left side moves
between differences, the right side switches the viewer, the file and
closes; the unified viewer's header has all of these."
  (let* ((session git-islands-diff-current)
         (width (max 0 (- (window-body-width nil t) 24
                          (tool-islands-line-end-inset))))
         (unified (eq side 'unified))
         (left (and side (not unified)))
         (label (cond (unified (concat (git-islands-diff-session-left-label session) " → "
                                       (git-islands-diff-session-right-label session)))
                      (left (git-islands-diff-session-left-label session))
                      (t (git-islands-diff-session-right-label session))))
         (title (concat (propertize label 'face 'tool-islands-title)
                        (tool-islands-ui-text (concat "  " (git-islands-diff-session-path session))
                                        'tool-islands-dim)
                        ;; Read-only sides carry IntelliJ's lock.
                        (when (and (not unified) buffer-read-only (>= width 160))
                          (concat (tool-islands-space 6)
                                  (expui-icons-icon "general/locked" :face 'tool-islands-neutral-icon)))))
         (moves (when (or left unified)
                  (concat
                   (when (>= width 100)
                     (git-islands-diff-buttons
                      '(("general/up" git-islands-diff-previous "Previous Difference (S-F7)")
                        ("general/down" git-islands-diff-next "Next Difference (F7)"))))
                   (when (>= width 260)
                     (concat (tool-islands-space 10)
                             (tool-islands-ui-text (git-islands-diff-position session) 'tool-islands-dim))))))
         (others (when (or unified (not left))
                   (git-islands-diff-buttons
                    (append
                     (when (>= width 160)
                       (if unified
                           '(("diff/sideBySide" git-islands-diff-toggle-viewer
                              "Side-by-side Viewer (C-c C-u)"))
                         '(("diff/unified" git-islands-diff-toggle-viewer
                            "Unified Viewer (C-c C-u)"))))
                     (when (and (git-islands-diff-session-step session) (>= width 200))
                       '(("general/left" git-islands-diff-previous-file
                          "Compare Previous File (C-c C-b)")
                         ("general/right" git-islands-diff-next-file
                          "Compare Next File (C-c C-f)")))
                     '(("general/close" git-islands-diff-quit "Close (C-c C-k)"))))))
         (actions (concat moves (and moves others (tool-islands-space 16)) others))
         (room (max 0 (- width (string-pixel-width actions) 12))))
    (concat (propertize " " 'display (tool-islands-header-space '(12)))
            (git-islands-diff-header-fit title room)
            (tool-islands-at-right actions (tool-islands-line-end)))))

;;;; Entry point

(cl-defun git-islands-diff-show (root path &key left-rev left-path right-rev right-empty
                                      left-label right-label step)
  "Show PATH of ROOT side by side: LEFT-REV's version against the newer one.
LEFT-REV is a revision, \"\" for the index, or nil when the file is new.
LEFT-PATH is PATH's name at LEFT-REV, if it was renamed.  The right side
is RIGHT-REV's version, or the working tree's when RIGHT-REV is nil;
RIGHT-EMPTY shows the file as deleted instead.  STEP, if non-nil, is a
function of one argument, FORWARD, showing the diff of the next file of
the list this one comes from, or the previous unless FORWARD; it returns
nil when there is none.  `git-islands-diff-viewer' chooses the viewer."
  ;; One diff per frame: close the one shown before.
  (when-let* ((old (frame-parameter nil 'git-islands-diff)))
    (when (buffer-live-p (git-islands-diff-session-left old))
      (with-current-buffer (git-islands-diff-session-left old) (git-islands-diff-quit))))
  (let* ((file (expand-file-name path root))
         (left (git-islands-diff-blob-buffer (or left-label left-rev "empty") root path
                                             (git-islands-diff-blob root left-rev (or left-path path))))
         (owns-right (or right-rev right-empty (not (file-exists-p file))))
         (right (if owns-right
                    (git-islands-diff-blob-buffer (or right-label right-rev "deleted") root path
                                                  (if right-empty ""
                                                    (git-islands-diff-blob root right-rev path)))
                  (find-file-noselect file)))
         (session (git-islands-diff-session-create
                   :root root :path path :left left :right right :step step
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
                   ;; The left side's revision, when the right side's hunks can be staged.
                   :stage (and (not owns-right) (car (member left-rev '("HEAD" ""))))
                   :owns-right owns-right
                   :saved-header (with-current-buffer right
                                   (cons (local-variable-p 'header-line-format)
                                         header-line-format)))))
    (git-islands-in-editor
     (lambda ()
       (interactive)
       (setf (git-islands-diff-session-configuration session) (current-window-configuration))
       (dolist (buffer (list left right))
         (with-current-buffer buffer
           (setq git-islands-diff-current session)
           (git-islands-diff-mode 1)
           (setq-local header-line-format
                       `(:eval (git-islands-diff-header ,(eq buffer left))))))
       ;; The gutter between the sides holds the hunks' actions.
       (unless owns-right
         (with-current-buffer left (setq-local right-margin-width 2)))
       (when (git-islands-diff-session-stage session)
         (with-current-buffer right (setq-local left-margin-width 2)))
       (git-islands-diff-refresh session)
       (git-islands-diff-layout session git-islands-diff-viewer)))
    (set-frame-parameter nil 'git-islands-diff session)
    session))

(provide 'git-islands-diff)
;;; git-islands-diff.el ends here
