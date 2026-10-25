;;; git-islands-tree.el --- Changed-file trees of the Git tool windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Rows for the Git tool windows: a group ("Changes"), folders and files,
;; each with a disclosure chevron, an optional New UI checkbox, an icon and
;; a name colored by how the file changed.  Rows are Magit sections, so
;; they fold and keep their visibility across refreshes; a line prefix
;; gives them their height and indentation (see git-islands-ui.el).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'face-remap)
(require 'svg)
(require 'magit-section)
(require 'expui-icons)
(require 'git-islands-core)
(require 'git-islands-faces)
(require 'git-islands-env)
(require 'git-islands-ui)

;;;; Faces

(defface git-islands-group '((t (:inherit git-islands-title)))
  "Group rows such as Changes."
  :group 'git-islands)

;;;; Checkboxes

(defconst git-islands-checkbox-size 14 "Pixel size of a checkbox.")

(defvar git-islands-checkbox-cache (make-hash-table :test #'equal))

(defun git-islands-face-color (face attribute fallback)
  "Return FACE's ATTRIBUTE color as #RRGGBB, or FALLBACK if it has none.
SVG images take the color too, and know no Emacs names such as grey50."
  (let ((color (face-attribute face attribute nil t)))
    (if (or (null color) (eq color 'unspecified)
            (string-prefix-p "unspecified" color)
            (null (color-values color)))
        fallback
      (git-islands-svg-color color))))

(defun git-islands-checkbox-image (state)
  "Return a New UI checkbox image in STATE: `on', `off' or `partial'."
  (let* ((accent (git-islands-face-color 'git-islands-source-icon :foreground "#3574F0"))
         (border (git-islands-face-color 'git-islands-neutral-icon :foreground "#818594"))
         (background (git-islands-face-color 'default :background "#FFFFFF"))
         (key (list state accent border background (frame-char-height))))
    (or (gethash key git-islands-checkbox-cache)
        (puthash
         key
         (let* ((size git-islands-checkbox-size)
                (svg (svg-create size size)))
           (if (eq state 'off)
               (svg-rectangle svg 0.5 0.5 (- size 1) (- size 1) :rx 3
                              :fill background :stroke border :stroke-width 1)
             (svg-rectangle svg 0 0 size size :rx 3 :fill accent))
           (pcase state
             ('on (svg-polyline svg '((3.5 . 7.2) (6 . 9.7) (10.5 . 4.5))
                                :fill "none" :stroke "#FFFFFF" :stroke-width 1.6
                                :stroke-linecap "round" :stroke-linejoin "round"))
             ('partial (svg-line svg 4 7 10 7 :stroke "#FFFFFF" :stroke-width 1.6
                                 :stroke-linecap "round")))
           (svg-image svg :ascent 'center))
         git-islands-checkbox-cache))))

(defun git-islands-checkbox (state &optional action)
  "Return a checkbox in STATE that runs ACTION when clicked."
  (let ((map (make-sparse-keymap)))
    (when action
      (define-key map [mouse-1] action)
      (define-key map [down-mouse-1] #'ignore))
    (propertize " " 'display (if (expui-icons-svg-p)
                                 (git-islands-checkbox-image state)
                               (pcase state ('on "[x]") ('partial "[-]") (_ "[ ]")))
                'keymap map 'pointer 'hand 'help-echo "Include in commit")))

;;;; Rows

(defun git-islands-chevron (section)
  "Return SECTION's disclosure chevron, or blank room for a leaf."
  (let ((state (cond ((or (not (oref section content))
                          ;; A group listing nothing has nothing to unfold.
                          (and (null (oref section children))
                               (>= (oref section content) (oref section end))))
                      nil)
                     ((oref section hidden) 'collapsed)
                     (t 'expanded))))
    (if (display-images-p)
        (propertize " " 'face 'git-islands-neutral-icon
                    'display (pcase state
                               ('expanded (expui-icons-image "general/chevronDown"))
                               ('collapsed (expui-icons-image "general/chevronRight"))
                               (_ `(space :width (,git-islands-state-width)))))
      (pcase state ('expanded "▾") ('collapsed "▸") (_ " ")))))

(defun git-islands-chevron-put (overlay string)
  "Make STRING the chevron OVERLAY draws, in the selection's color if selected."
  (overlay-put overlay 'git-islands-plain string)
  (overlay-put overlay 'before-string
               (if-let* ((face (overlay-get overlay 'git-islands-selected)))
                   (git-islands-under-face (copy-sequence string) face)
                 string)))

(defun git-islands-tree-draw-chevron (section)
  "Draw SECTION's chevron again, after it was folded or unfolded."
  (when-let* ((overlay (seq-find (lambda (overlay) (overlay-get overlay 'git-islands-chevron))
                                 (overlays-at (oref section start)))))
    (git-islands-chevron-put overlay (git-islands-chevron section))))

(defun git-islands-tree-draw-chevrons (&optional section)
  "Draw the chevrons of SECTION, the root by default, and its descendants."
  (let ((section (or section magit-root-section)))
    (when section
      (unless (eq section magit-root-section)
        (git-islands-tree-draw-chevron section))
      (mapc #'git-islands-tree-draw-chevrons (oref section children)))))

(defun git-islands-tree-row (depth &rest strings)
  "Insert a row DEPTH levels deep made of STRINGS.
The chevron is drawn at its start; see `git-islands-tree-draw-chevron'."
  (let ((start (point)))
    (insert (apply #'concat strings) "\n")
    (add-text-properties start (point) `(line-prefix ,(git-islands-row-prefix depth)
                                                     git-islands-depth ,depth))
    (let ((overlay (make-overlay start (1+ start))))
      (overlay-put overlay 'git-islands-chevron t)
      (overlay-put overlay 'evaporate t))))

(defun git-islands-tree-gap ()
  "Return the gap between an icon and its name."
  (git-islands-space git-islands-icon-gap))

;;;; Tool window headers

(defun git-islands-tool-header (format)
  "Return header FORMAT as `git-islands-header-function' shows it."
  (funcall git-islands-header-function format))

(defun git-islands-toolbar (buttons)
  "Return a toolbar of BUTTONS, as in `git-islands-commit-buttons'."
  (let ((pad (git-islands-space git-islands-toolbar-padding)))
    (concat (mapconcat (pcase-lambda (`(,icon ,action ,help))
                         (git-islands-header-button
                          action help pad
                          (expui-icons-icon icon :face 'git-islands-neutral-icon) pad))
                       buttons "")
            (git-islands-space git-islands-toolbar-margin))))

;;;; Lists

;; Every Git tool window's list shares one look: rows of the
;; same height in the interface font, the selected row a rounded pill in
;; the selection color (fainter while another window is selected), and
;; names too wide for the window shortened at their end.

(defvar-local git-islands-view nil "Non-nil in a Git tool window's list.")
(defvar-local git-islands-hl nil "Overlays drawing the selected rows.")
(defvar-local git-islands-hl-chevron nil "Chevron overlays drawn as selected.")
(defvar-local git-islands-selected-rows-function nil
  "Function returning the starts of the selected rows, as a list.
Nil selects the row at point alone; the Git log selects several.")

(defvar git-islands-view-mouse-map
  (let ((map (make-sparse-keymap)))
    ;; A press selects its row; no drag selects a region of text.
    (define-key map [down-mouse-1] #'git-islands-mouse-select)
    (define-key map [drag-mouse-1] #'ignore)
    (define-key map [mouse-1] #'ignore)
    map)
  "Mouse keys every Git list shares, under its own.")

(defun git-islands-mouse-select (event)
  "Move point to the row clicked at EVENT, selecting it."
  (interactive "e")
  (mouse-set-point event)
  (deactivate-mark))

(defun git-islands-card-color ()
  "Return the background the tool windows are drawn on."
  (or (and git-islands-background-function (funcall git-islands-background-function))
      (git-islands-face-color 'default :background "#FFFFFF")))

(defun git-islands-view-setup (&optional wrap)
  "Set up the current buffer as a Git tool window's list.
WRAP non-nil wraps long lines at word boundaries instead of fitting them."
  (setq-local git-islands-view t
              cursor-type nil
              tab-line-exclude t
              truncate-lines (not wrap)
              ;; Narrow side windows would otherwise truncate regardless.
              truncate-partial-width-windows (not wrap)
              word-wrap wrap
              ;; The selected row reaches the edge; that is no truncation.
              fringe-indicator-alist (cons '(truncation nil nil) fringe-indicator-alist)
              wrap-prefix (and wrap (git-islands-space git-islands-row-inset))
              ;; A cut line ends in a plain ellipsis, never a boxed glyph.
              buffer-display-table
              (let ((table (make-display-table)))
                (set-display-table-slot table 'truncation (make-glyph-code ?… 'git-islands-dim))
                table))
  ;; A selected row's end lies past the window's edge: never scroll to it.
  (setq-local auto-hscroll-mode nil)
  (use-local-map (make-composed-keymap (current-local-map) git-islands-view-mouse-map))
  (face-remap-add-relative 'default 'git-islands-file-name)
  ;; Not inherited from the tab line, which a bottom card's gap row shrinks.
  (face-remap-add-relative 'header-line :inherit 'git-islands-ui-font :height 1.0 :box nil
                           :weight 'normal :background (git-islands-card-color))
  (add-hook 'post-command-hook #'git-islands-highlight nil t)
  (add-hook 'window-selection-change-functions #'git-islands-highlight nil t)
  (add-hook 'window-size-change-functions #'git-islands-fit-rows nil t)
  (add-hook 'window-buffer-change-functions #'git-islands-fit-rows nil t))

(defun git-islands-highlight (&rest _)
  "Draw the selected rows as pills, as JetBrains' New UI does.
Pills fade while another window is selected; a blank row has none.
Window change hooks may run it in another buffer the window now shows."
  (when git-islands-view (git-islands-highlight-1)))

(defun git-islands-highlight-1 ()
  "Draw the selected rows; see `git-islands-highlight'."
  (let* ((window (get-buffer-window (current-buffer)))
         (face (if (and window (eq window (selected-window)))
                   'git-islands-hl-line 'git-islands-hl-line-inactive))
         (rows (if git-islands-selected-rows-function
                   (funcall git-islands-selected-rows-function)
                 (list (pos-bol)))))
    (dolist (chevron git-islands-hl-chevron)
      (when (overlay-buffer chevron)
        (overlay-put chevron 'git-islands-selected nil)
        (git-islands-chevron-put chevron (overlay-get chevron 'git-islands-plain))))
    (setq git-islands-hl-chevron nil)
    (mapc #'delete-overlay git-islands-hl)
    (setq git-islands-hl nil)
    (dolist (start rows)
      (let ((end (save-excursion (goto-char start) (pos-eol))))
        (unless (= start end)
          (let ((overlay (make-overlay start end nil t)))
            (overlay-put overlay 'priority 100)
            (overlay-put overlay 'face face)
            (overlay-put overlay 'line-prefix
                         (git-islands-row-prefix (or (get-text-property start 'git-islands-depth) 0)
                                                 face))
            (overlay-put overlay 'after-string
                         (git-islands-pill-end (face-background face nil t)
                                               (git-islands-row-end-inset window)))
            (push overlay git-islands-hl))
          ;; Overlay strings take no background from the pill: draw it in.
          (when-let* ((chevron (seq-find (lambda (overlay) (overlay-get overlay 'git-islands-chevron))
                                         (overlays-at start))))
            (overlay-put chevron 'git-islands-selected face)
            (git-islands-chevron-put chevron (or (overlay-get chevron 'git-islands-plain)
                                                 (overlay-get chevron 'before-string)))
            (push chevron git-islands-hl-chevron)))))))

(defun git-islands-row-end-inset (window)
  "Return the pixels a selected row stops short of WINDOW's edge.
Without a right fringe a row filling the window would count as cut, with
an ellipsis at its end, so it leaves a column free there."
  (if (and (window-live-p window) (> (or (cadr (window-fringes window)) 0) 0))
      0
    (frame-char-width (window-frame window))))

(defun git-islands-pill-end (color inset)
  "Return the selected row's right end in COLOR, INSET pixels from the edge.
The clear margin around the rounded end is drawn in the card's color: an
overlay string would show the canvas there."
  (let ((radius git-islands-hl-radius)
        (margin git-islands-hl-margin))
    (concat (propertize " " 'face `(:background ,color)
                        'display `(space :align-to (- right (,(+ radius margin inset)))))
            (git-islands-ui-pill-end 'right radius (git-islands-row-pixels) color margin
                                     (git-islands-card-color)))))

(defun git-islands-row-width (start end)
  "Return the pixel width of the row from START to END, unwrapped.
It counts the row's indentation and disclosure chevron, which are not text."
  (+ git-islands-row-inset
     (* git-islands-indent (or (get-text-property start 'git-islands-depth) 0))
     (if (seq-some (lambda (overlay) (overlay-get overlay 'git-islands-chevron))
                   (overlays-at start))
         git-islands-state-width 0)
     (string-pixel-width (buffer-substring start end) (current-buffer))))

(defconst git-islands-fit-margin (+ git-islands-hl-margin git-islands-hl-radius 4)
  "Pixels kept clear at a row's end, for the selected row's rounded end.")

(defun git-islands-fit-rows (&optional window)
  "Shorten the names that WINDOW is too narrow for, at their end.
Names are the spans marked `git-islands-fit'; WINDOW defaults to one showing
the current buffer."
  (let ((window (if (windowp window) window (get-buffer-window (current-buffer)))))
    (when (and (window-live-p window) (display-graphic-p (window-frame window)))
      (with-current-buffer (window-buffer window)
        (when git-islands-view
          (let ((room (- (window-body-width window t) git-islands-fit-margin
                         (git-islands-row-end-inset window)))
                (inhibit-read-only t))
            ;; The selected row's rounded end reaches the window's edge: measure
            ;; rows without it.
            (mapc #'delete-overlay git-islands-hl)
            (setq git-islands-hl nil)
            (with-silent-modifications
              (save-excursion
                (goto-char (point-min))
                (while (not (eobp))
                  (let* ((line-end (pos-eol))
                         (span (text-property-any (point) line-end 'git-islands-fit t)))
                    (when span
                      (let ((span-end (or (text-property-not-all span line-end 'git-islands-fit t)
                                          line-end)))
                        (remove-text-properties span span-end '(display nil))
                        (let ((over (- (git-islands-row-width (point) line-end) room)))
                          (when (> over 0)
                            (let* ((text (buffer-substring span span-end))
                                   (width (- (string-pixel-width text (current-buffer)) over
                                             (string-pixel-width "…" (current-buffer)))))
                              (put-text-property
                               span span-end 'display
                               (concat (truncate-string-pixelwise text (max 0 width)
                                                                  (current-buffer))
                                       (propertize "…" 'face 'git-islands-dim)))))))))
                  (forward-line 1))))
            (git-islands-highlight)))))))

(defvar-local git-islands-refit-function #'git-islands-fit-rows
  "Function fitting this buffer's rows to its window, given the window.
A side pane resized by `git-islands-pane-fit' calls it.")

;;;; Side panes

;; A tool window's panes keep their width as a share of the frame's, within
;; limits: splitting side windows loses the widths asked for, and a frame
;; maximized after a pane opens would otherwise give it a share of its own.

(defvar git-islands-pane--fitting nil "Non-nil while side panes are resized.")

(defun git-islands-pane-keep (window width)
  "Keep side pane WINDOW as wide as WIDTH, a function returning pixels."
  (when (window-live-p window)
    (set-window-parameter window 'git-islands-pane-width width)
    (git-islands-pane-fit (window-frame window))))

(defun git-islands-pane-fit (frame)
  "Give FRAME's side panes their widths, and fit their rows to them.
A resize made here, inside a size change, runs no size hooks again, so
each pane's rows are fitted here too."
  (let ((git-islands-pane--fitting t)
        panes)
    (dolist (window (window-list frame 'no-minibuffer))
      (when-let* ((width (window-parameter window 'git-islands-pane-width)))
        (push window panes)
        (ignore-errors
          (window-resize window (- (funcall width) (window-pixel-width window)) t t t))))
    (dolist (window panes)
      (with-current-buffer (window-buffer window)
        (funcall git-islands-refit-function window)))
    (set-frame-parameter frame 'git-islands-pane-frame-width (frame-pixel-width frame))))

(defun git-islands-pane-follow (frame)
  "Size FRAME's side panes again after its windows changed size.
A pane its divider was dragged for keeps its new share of the frame;
after any other change, such as the frame's width or another window
showing, each pane takes its own width again."
  (unless git-islands-pane--fitting
    (let ((panes (seq-filter (lambda (window) (window-parameter window 'git-islands-pane-width))
                             (window-list frame 'no-minibuffer))))
      (if (memq this-command '(mouse-drag-vertical-line mouse-drag-mode-line
                               mouse-drag-header-line))
          (dolist (window panes)
            (let ((share (/ (float (window-pixel-width window)) (frame-pixel-width frame))))
              (set-window-parameter window 'git-islands-pane-width
                                    (lambda () (round (* share (frame-pixel-width frame)))))))
        (when (seq-some (lambda (window)
                          (/= (window-pixel-width window)
                              (funcall (window-parameter window 'git-islands-pane-width))))
                        panes)
          (git-islands-pane-fit frame))))))

(add-hook 'window-size-change-functions #'git-islands-pane-follow)

(defun git-islands-wrap (text width)
  "Return TEXT's lines broken at spaces to fit WIDTH pixels, in this buffer's font."
  (mapcan
   (lambda (line)
     (let ((words (split-string line " "))
           (rows nil)
           (row nil))
       (dolist (word words)
         (let ((candidate (if row (concat row " " word) word)))
           (if (and row (> (string-pixel-width candidate (current-buffer)) width))
               (progn (push row rows) (setq row word))
             (setq row candidate))))
       (nreverse (cons (or row "") rows))))
   (split-string text "\n")))

(defvar-local git-islands-header-cookie nil
  "Remapping giving an editor buffer the tool windows' header, while shown so.")

(defun git-islands-header-style (enable)
  "Give the current buffer's header the tool windows' look if ENABLE, else undo it.
For editor buffers a diff or merge borrows, until it closes."
  (if enable
      (unless git-islands-header-cookie
        (setq git-islands-header-cookie
              (face-remap-add-relative 'header-line :inherit 'tab-line :height 1.0 :box nil)))
    (when git-islands-header-cookie
      (face-remap-remove-relative git-islands-header-cookie)
      (setq git-islands-header-cookie nil))))

(defun git-islands-ui (text &optional face)
  "Return TEXT in the interface font, with FACE's colors.
Headers of editor windows otherwise take the buffer's own font."
  (propertize text 'face (if face (list face 'git-islands-file-name) 'git-islands-file-name)))

(defun git-islands-fit (string)
  "Mark STRING as a name `git-islands-fit-rows' may shorten."
  (propertize string 'git-islands-fit t))

;;;; Buttons

(defun git-islands-button-height ()
  "Return the pixel height of a header button, with air above and below."
  (round (* 1.4 (frame-char-height))))

(defvar git-islands-button-cache (make-hash-table :test #'equal))

(defun git-islands-button-image (label primary)
  "Return a pill image showing LABEL, in the accent color if PRIMARY.
It is one image: a text's background would fill the header's height."
  (let* ((face (if primary 'git-islands-primary-button 'git-islands-button))
         (background (git-islands-face-color face :background (if primary "#245FA5" "#ECEDEF")))
         (foreground (git-islands-face-color face :foreground (if primary "#FFFFFF" "#333333")))
         (font (face-font 'git-islands-file-name))
         (size (if font (aref (font-info font) 2) 13))
         (family (let ((family (face-attribute 'git-islands-ui-font :family nil t)))
                   (if (stringp family) family "sans-serif")))
         (height (git-islands-button-height))
         (key (list label background foreground family size height)))
    (or (gethash key git-islands-button-cache)
        (puthash key
                 (let* ((width (+ (string-pixel-width
                                   (propertize label 'face 'git-islands-file-name))
                                  24))
                        (svg (svg-create width height)))
                   (svg-rectangle svg 0 0 width height :rx (/ height 2.0) :fill background)
                   (svg-text svg label :x (/ width 2.0) :y (/ height 2.0)
                             :text-anchor "middle" :dominant-baseline "central"
                             :font-family family :font-size size :fill foreground)
                   (svg-image svg :ascent 'center))
                 git-islands-button-cache))))

(defun git-islands-button (label action help &optional primary)
  "Return a pill-shaped header button LABEL running ACTION, tooltip HELP.
PRIMARY draws it in the accent color, as IntelliJ's default button."
  (git-islands-header-button action help
                             (if (display-images-p)
                                 (propertize label 'display (git-islands-button-image label primary))
                               (propertize (concat " " label " ")
                                           'face (if primary 'git-islands-primary-button 'git-islands-button)))))

(add-hook 'enable-theme-functions (lambda (&rest _) (clrhash git-islands-button-cache)))

;;;; Trees

;; A node is (NAME DIRS FILES): DIRS an alist of name to node, FILES the
;; entries directly inside.  A folder holding only one folder is drawn as
;; one row, "a/b", as IntelliJ does.

(defun git-islands-tree-build (entries)
  "Return the folder tree of ENTRIES."
  (let ((root (list "" nil nil)))
    (dolist (entry entries)
      (let ((node root)
            (parts (split-string (git-islands-entry-path entry) "/")))
        (dolist (part (butlast parts))
          (let ((child (assoc part (nth 1 node))))
            (unless child
              (setq child (list part nil nil))
              (setf (nth 1 node) (append (nth 1 node) (list child))))
            (setq node child)))
        (setf (nth 2 node) (append (nth 2 node) (list entry)))))
    (git-islands-tree-compact root)))

(defun git-islands-tree-compact (node)
  "Merge NODE's folders that hold a single folder and nothing else."
  (setf (nth 1 node)
        (mapcar (lambda (child)
                  (while (and (null (nth 2 child)) (= (length (nth 1 child)) 1))
                    (let ((only (car (nth 1 child))))
                      (setq child (list (concat (car child) "/" (car only))
                                        (nth 1 only) (nth 2 only)))))
                  (git-islands-tree-compact child))
                (sort (nth 1 node) (lambda (a b) (string< (car a) (car b))))))
  (setf (nth 2 node)
        (sort (nth 2 node)
              (lambda (a b) (string< (file-name-nondirectory (git-islands-entry-path a))
                                     (file-name-nondirectory (git-islands-entry-path b))))))
  node)

(defun git-islands-tree-entries (node)
  "Return every entry in NODE and below."
  (append (nth 2 node) (mapcan #'git-islands-tree-entries (nth 1 node))))

(defun git-islands-file-icon (entry)
  "Return the icon of ENTRY's file."
  (let ((path (git-islands-entry-path entry)))
    (git-islands-icon (expui-icons-name-for-file (file-name-nondirectory path)))))

(defun git-islands-file-label (entry &optional directory)
  "Return ENTRY's name in its change face, and DIRECTORY dimmed after it."
  (let* ((path (git-islands-entry-path entry))
         (change (git-islands-entry-change entry))
         (name (propertize (file-name-nondirectory path)
                           'face (git-islands-change-face change))))
    (git-islands-fit
     (concat name
             (when-let* ((orig (git-islands-entry-orig entry)))
               (propertize (concat "  ← " (file-name-nondirectory orig)) 'face 'git-islands-dim))
             (when (and directory (file-name-directory path))
               (propertize (concat "  " (directory-file-name (file-name-directory path)))
                           'face 'git-islands-dim))))))

;;;; Inserting trees

;; CHECKBOX, where taken, is nil or a function of a row's entries returning
;; its checkbox, or nil for a row without one.

(defun git-islands-tree-checkbox (checkbox entries)
  "Return CHECKBOX's checkbox for ENTRIES followed by a gap, or nothing."
  (when-let* ((box (and checkbox (funcall checkbox entries))))
    (concat box (git-islands-space 6))))

(defun git-islands-tree-insert-file (entry depth flat checkbox)
  "Insert ENTRY's row DEPTH levels deep; FLAT shows its folder after it."
  (magit-insert-section (git-islands-file (git-islands-entry-path entry))
                        (git-islands-tree-row
                         depth
                         (propertize
                          (concat (git-islands-tree-checkbox checkbox (list entry))
                                  (git-islands-file-icon entry) (git-islands-tree-gap)
                                  (git-islands-file-label entry flat))
                          'git-islands-entries (list entry) 'git-islands-entry entry))))

(defun git-islands-tree-insert-node (node depth checkbox)
  "Insert folder NODE's row DEPTH levels deep, then what it holds."
  (let ((entries (git-islands-tree-entries node)))
    (magit-insert-section (git-islands-dir (car node))
                          (git-islands-tree-row
                           depth
                           (propertize
                            (concat (git-islands-tree-checkbox checkbox entries)
                                    (git-islands-icon "nodes/folder") (git-islands-tree-gap)
                                    (git-islands-fit (car node))
                                    (propertize (format "  %d" (length entries)) 'face 'git-islands-dim))
                            'git-islands-entries entries))
                          (magit-insert-heading)
                          (git-islands-tree-insert-children node (1+ depth) checkbox))))

(defun git-islands-tree-insert-children (node depth checkbox)
  "Insert the folders and files of NODE, DEPTH levels deep."
  (dolist (child (nth 1 node))
    (git-islands-tree-insert-node child depth checkbox))
  (dolist (entry (nth 2 node))
    (git-islands-tree-insert-file entry depth nil checkbox)))

(defun git-islands-tree-insert-entries (entries depth grouped checkbox)
  "Insert ENTRIES DEPTH levels deep, by folder if GROUPED, else flat."
  (if grouped
      (git-islands-tree-insert-children (git-islands-tree-build entries) depth checkbox)
    (dolist (entry (sort (copy-sequence entries)
                         (lambda (a b) (string< (git-islands-entry-path a)
                                                (git-islands-entry-path b)))))
      (git-islands-tree-insert-file entry depth t checkbox))))

(defun git-islands-tree-insert-group (type title entries grouped checkbox &optional empty)
  "Insert group TYPE named TITLE, then ENTRIES by folder if GROUPED.
EMPTY is shown after the title when there are no entries."
  (magit-insert-section (git-islands-group type)
                        (git-islands-tree-row
                         0
                         (propertize
                          (concat (if entries
                                      (git-islands-tree-checkbox checkbox entries)
                                    ;; Keep the title in line with the groups that have one.
                                    (and checkbox (git-islands-space (+ git-islands-checkbox-size 6))))
                                  (git-islands-fit (if (get-text-property 0 'face title) title
                                                     (propertize title 'face 'git-islands-group)))
                                  ;; A bare count, as on folders.
                                  (propertize (if entries
                                                  (format "  %d" (length entries))
                                                (concat "  " (or empty "")))
                                              'face 'git-islands-dim))
                          'git-islands-entries entries))
                        (magit-insert-heading)
                        (git-islands-tree-insert-entries entries 1 grouped checkbox)))

(provide 'git-islands-tree)
;;; git-islands-tree.el ends here
