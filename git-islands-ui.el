;;; git-islands-ui.el --- The drawing pieces the Git tool windows share -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The tool windows look as JetBrains' New UI does: rows of one height in
;; a proportional font, the selected row a rounded pill inset from the
;; window's edges, headers with icon buttons.  This file holds those
;; pieces, measured in pixels since proportional text and icons defeat
;; column counts.  Faces and sizes have plain defaults; a configuration
;; can tie them to its own.

;;; Code:

(require 'expui-icons)
(require 'git-islands-faces)

;;;; Faces

(defface git-islands-ui-font '((t (:inherit variable-pitch)))
  "Proportional font of the tool windows' text."
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
  '((((background dark)) :background "#2E436E") (t :background "#D5E1F5"))
  "The selected rows of the selected tool window."
  :group 'git-islands)

(defface git-islands-hl-line-inactive
  '((((background dark)) :background "#393B40") (t :background "#E8E9EB"))
  "The selected rows of a tool window that is not selected."
  :group 'git-islands)

(defface git-islands-toolbar-hover '((t (:inherit highlight)))
  "A header button under the mouse."
  :group 'git-islands)

;;;; Sizes

(defconst git-islands-indent 16 "Pixels each folder level indents its rows.")

(defconst git-islands-hl-margin 6
  "Pixels between a selected row's pill and the window's edges.")

(defconst git-islands-hl-radius 6 "Radius in pixels of a selected row's rounded ends.")

(defconst git-islands-row-inset (+ git-islands-hl-margin git-islands-hl-radius)
  "Pixels before every row, where a selected row's left end is drawn.")

(defconst git-islands-state-width 16 "Pixels a folder's chevron takes.")

(defconst git-islands-icon-gap 6 "Pixels between an icon and the name after it.")

(defconst git-islands-toolbar-padding 4 "Pixels on each side of a toolbar icon.")

(defconst git-islands-toolbar-margin 6 "Pixels between a toolbar and the window's right edge.")

(defcustom git-islands-row-height 1.65
  "Height of a row, in frame character units."
  :type 'number
  :group 'git-islands)

(defcustom git-islands-header-height 1.9
  "Height of a tool window's header, in font units."
  :type 'number
  :group 'git-islands)

(defcustom git-islands-header-ascent 68
  "Percentage of the header's height above its text's baseline."
  :type 'integer
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
  `(space :width ,width :height ,git-islands-header-height :ascent ,git-islands-header-ascent))

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
                 (git-islands-svg-color color)))))))

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
                                                   (if face git-islands-row-inset 1)))))))

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
                      (call-interactively action)
                    (funcall action event))))
    (define-key map [header-line mouse-1] #'ignore)
    (propertize (apply #'concat strings)
                'local-map map 'help-echo help 'pointer 'hand
                'mouse-face 'git-islands-toolbar-hover)))

(provide 'git-islands-ui)
;;; git-islands-ui.el ends here
