;;; git-islands-ui.el --- The drawing pieces the Git tool windows share -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The tool windows use theme faces and plain selections by default.
;; Configurations can opt into rounded selections and other styling.
;; These pieces use pixel measurements to support proportional text and icons.  Faces and sizes have plain defaults; a configuration
;; can tie them to its own.

;;; Code:

(require 'expui-icons)
(require 'git-islands-faces)

;;;; Faces

(defface git-islands-ui-font '((t ()))
  "Typography of the tool windows' text.
Leave colors unspecified so text keeps its surrounding background."
  :group 'git-islands)

(defface git-islands-header
  '((((background dark))
     (:inherit (git-islands-ui-font default) :height 1.0 :weight normal
      :box (:line-width -1 :color "#484848")))
    (t (:inherit (git-islands-ui-font default) :height 1.0 :weight normal
        :box (:line-width -1 :color "#D8D8D8"))))
  "Common header face for lists, commit messages, diffs and merges.
The inset one-pixel box follows the actual header edges.  Customize
its color, or set `:box' to nil to hide the border."
  :group 'git-islands)

(defface git-islands-file-name '((t (:inherit git-islands-ui-font :height 1.0)))
  "Default text of the tool windows' lists."
  :group 'git-islands)

(defface git-islands-title '((t (:inherit git-islands-ui-font :weight medium)))
  "Tool window titles and group rows."
  :group 'git-islands)

(defface git-islands-neutral-icon '((t (:inherit shadow)))
  "Icons in the tool windows' rows and toolbars."
  :group 'git-islands)

(defface git-islands-source-icon '((t (:inherit link :underline nil)))
  "Icons of source files, drawn in the accent color."
  :group 'git-islands)

(defface git-islands-hl-line
  '((t (:inherit highlight)))
  "The selected rows of the selected tool window."
  :group 'git-islands)

(defface git-islands-hl-line-inactive
  '((t (:inherit highlight)))
  "The selected rows of a tool window that is not selected."
  :group 'git-islands)

(defface git-islands-toolbar-hover '((t (:inherit highlight)))
  "A header button under the mouse."
  :group 'git-islands)

;;;; Sizes

(defconst git-islands-indent 16 "Pixels each folder level indents its rows.")

(defcustom git-islands-hl-margin 0
  "Pixels between a selected row and the window's edges."
  :type 'natnum
  :group 'git-islands)

(defcustom git-islands-hl-radius 0
  "Radius in pixels of selected rows; zero gives square corners."
  :type 'natnum
  :group 'git-islands)

(defcustom git-islands-row-inset 12
  "Pixels before row contents, including the selection's left end.
Keep this at least as large as the selection margin plus radius."
  :type 'natnum
  :group 'git-islands)

(defconst git-islands-state-width 16 "Pixels a folder's chevron takes.")

(defconst git-islands-icon-gap 6 "Pixels between an icon and the name after it.")

(defconst git-islands-toolbar-padding 4 "Pixels on each side of a toolbar icon.")

(defconst git-islands-toolbar-margin 6 "Pixels between a toolbar and the window's right edge.")

(defcustom git-islands-row-height 1.3
  "Height of a row, in frame character units."
  :type 'number
  :group 'git-islands)

(defcustom git-islands-header-height 1.5
  "Height of a tool window's header, in font units."
  :type 'number
  :group 'git-islands)

(defcustom git-islands-header-padding 4
  "Minimum vertical padding in pixels on each side of header content."
  :type 'natnum
  :group 'git-islands)

(defcustom git-islands-header-ascent nil
  "Percentage of the header above the baseline, or nil to center its font.
An explicit number preserves the alignment of existing configurations."
  :type '(choice (const :tag "Automatic" nil) integer)
  :group 'git-islands)

(defcustom git-islands-line-end-inset 0
  "Pixels kept free at the right end of headers.
A number, or a function returning one for the window being drawn; a
configuration drawing rounded window corners there can set it."
  :type '(choice integer function)
  :group 'git-islands)

(defvar git-islands-source-icons
  '("xml" "c" "h" "cpp" "Csharp" "java" "kotlin" "kotlinScript" "groovy"
    "language/scala" "language/php" "python" "perl" "javaScript" "typeScript"
    "swiftLang" "nodes/sourceRoot" "nodes/testRoot" "nodes/class"
    "nodes/classAbstract" "nodes/interface" "nodes/enum" "nodes/record"
    "nodes/annotation" "nodes/exception" "nodes/abstractException")
  "Icons drawn in `git-islands-source-icon' rather than `git-islands-neutral-icon'.")

;;;; Spaces

(defun git-islands-space (pixels)
  "Return a space PIXELS wide."
  (propertize " " 'display `(space :width (,(max 0 pixels)))))

(defun git-islands-header-space (width)
  "Return a display spec WIDTH wide that gives a header its height."
  (let* ((font (and (display-graphic-p) (face-font 'git-islands-header)))
         (info (and font (font-info font)))
         (font-height (if info (aref info 3) (frame-char-height)))
         (font-ascent (if info (aref info 8) (* font-height 0.75)))
         (content-height
          (max font-height 16
               (if (eq (bound-and-true-p git-islands-button-render-function)
                       'git-islands-button-rounded)
                   (round (* 1.4 (frame-char-height)))
                 0)))
         (height (max (ceiling (* font-height git-islands-header-height))
                      (+ content-height (* 2 git-islands-header-padding))))
         (ascent (or git-islands-header-ascent
                     (round (* 100.0 (/ (+ font-ascent (/ (- height font-height) 2.0))
                                        height))))))
    `(space :width ,width :height (,height) :ascent ,ascent)))

(defun git-islands-line-end-inset ()
  "Return the pixels kept free at the right end of this window's header."
  (if (functionp git-islands-line-end-inset)
      (funcall git-islands-line-end-inset)
    git-islands-line-end-inset))

(defun git-islands-line-end ()
  "Return the `:align-to' position where header text ends."
  `(- (+ right right-fringe right-margin) (,(git-islands-line-end-inset))))

(defun git-islands-at-right (text &optional edge buffer)
  "Return TEXT preceded by the space that aligns its end to EDGE.
EDGE is an `:align-to' position, `right' by default.  TEXT is measured
with BUFFER's face remapping, as `string-pixel-width' does."
  (concat (propertize " " 'display
                      `(space :align-to (- ,(or edge 'right)
                                           (,(string-pixel-width text buffer)))))
          text))

;;;; Pills

(defvar git-islands-pill-cache (make-hash-table :test #'equal)
  "Strut and pill end strings by their arguments.")

(defun git-islands-svg-color (color)
  "Return COLOR, which may be an Emacs color name, as #RRGGBB."
  (if-let* ((values (and color (color-values color))))
      (apply #'format "#%02x%02x%02x" (mapcar (lambda (v) (/ v 257)) values))
    "none"))

(defun git-islands-image-string (svg)
  "Return a string displaying SVG, centered on its row's text as icons are.
The image is loaded at once: a window fitted to its rows before then
would measure them as tall as their text."
  (let ((image (create-image svg 'svg t :ascent 'center :scale 1)))
    (when (display-images-p)
      (image-size image t))
    (propertize " " 'display image)))

(defun git-islands-strut (height)
  "Return a one-pixel-wide string that makes its row HEIGHT pixels high."
  (with-memoization (gethash (list nil height) git-islands-pill-cache)
    (git-islands-image-string
     (format "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='%d'/>"
             height))))

(defun git-islands-ui-pill-end (side radius height color &optional margin outside)
  "Return a string showing the SIDE end of a pill, RADIUS pixels round.
SIDE is `left' or `right'.  The end fills a row HEIGHT pixels high in
COLOR, and also sets the row's height as `git-islands-strut' does.  MARGIN
pixels, 0 by default, stay clear outside it, showing OUTSIDE or else the
background of the face the string is drawn in."
  (let ((margin (or margin 0)))
    (if (zerop radius)
        (propertize " " 'face (and outside `(:background ,outside))
                    'display `(space :width (,margin) :height (,height)))
      (with-memoization (gethash (list side radius height color margin outside)
				 git-islands-pill-cache)
	(let ((width (+ margin radius)))
          (git-islands-image-string
           (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'>\
%s<path d='%s' fill='%s'/></svg>"
                   width height
                   (if outside
                       (format "<rect width='%d' height='%d' fill='%s'/>"
                               width height (git-islands-svg-color outside))
                     "")
                   (if (eq side 'left)
                       (format "M%d,0 A%d,%d 0 0 0 %d,%d V%d A%d,%d 0 0 0 %d,%d Z"
                               width radius radius margin radius
                               (- height radius) radius radius width height)
                     (format "M0,0 A%d,%d 0 0 1 %d,%d V%d A%d,%d 0 0 1 0,%d Z"
                             radius radius radius radius
                             (- height radius) radius radius height))
                   (git-islands-svg-color color))))))))

(defun git-islands-forget-pills (&rest _)
  "Draw pills again after the theme or font changed."
  (clrhash git-islands-pill-cache))

(add-hook 'enable-theme-functions #'git-islands-forget-pills)
(add-hook 'after-setting-font-hook #'git-islands-forget-pills)

;;;; Rows

(defun git-islands-row-pixels ()
  "Return the height of a row in pixels."
  (ceiling (* (frame-char-height) git-islands-row-height)))

(defun git-islands-row-prefix (depth &optional face)
  "Return the line prefix of a row DEPTH folders deep, which sets its height.
FACE, a selection face, highlights the row from a rounded left end."
  (concat (if face
              (git-islands-ui-pill-end 'left git-islands-hl-radius (git-islands-row-pixels)
                                       (face-background face nil t) git-islands-hl-margin)
            (git-islands-strut (git-islands-row-pixels)))
          (propertize " " 'face face
                      'display `(space :width (,(- (+ git-islands-row-inset
                                                      (* depth git-islands-indent))
                                                   (if face (+ git-islands-hl-margin git-islands-hl-radius) 1)))))))

(defun git-islands-under-face (string face)
  "Return STRING with FACE, a selection face or nil, beneath its own faces.
Overlay strings do not take the background of the selection overlay."
  (when face
    (add-face-text-property 0 (length string) face t string))
  string)

(defun git-islands-icon (icon)
  "Return ICON, an icon name, in the face its kind is drawn in."
  (expui-icons-icon icon :face (if (member icon git-islands-source-icons)
                                   'git-islands-source-icon
                                 'git-islands-neutral-icon)))

;;;; Header buttons

(defun git-islands-header-button (action help &rest strings)
  "Return STRINGS as a header button running ACTION, with tooltip HELP.
ACTION is a command, or a function called with the click event; it runs
in the clicked window."
  (let ((map (make-sparse-keymap)))
    ;; Act on press; this also keeps the press from resizing the window.
    (define-key map [header-line down-mouse-1]
                (lambda (event)
                  (interactive "e")
                  (select-window (posn-window (event-start event)))
                  (if (commandp action)
                      ;; The command clicked, not this lambda, is what ran.
                      (call-interactively (setq this-command action))
                    (funcall action event))))
    (define-key map [header-line mouse-1] #'ignore)
    (propertize (apply #'concat strings)
                'local-map map 'help-echo help 'pointer 'hand
                'mouse-face 'git-islands-toolbar-hover)))

(provide 'git-islands-ui)
;;; git-islands-ui.el ends here
