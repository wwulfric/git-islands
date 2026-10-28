;;; git-islands-env.el --- What the Git tool windows ask of the editor around them -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The Git tool windows draw themselves, but some things belong to the
;; editor they live in: the status line under each list, the corners
;; around its header, where a popup drops down from, which project a
;; command acts on outside any repository, and what makes room for the
;; Commit tool window.  Each is a variable here, set to plain defaults
;; that work in any Emacs; a configuration sets them to its own, and the
;; tool windows never call into it themselves.

;;; Code:

(require 'git-islands-faces)

(defcustom git-islands-mode-line-format 'default
  "Mode line of tool window lists and the commit message buffer.
`default' shows the mode name and repository basename when they fit.
Narrow windows omit the repository; hover for the full directory.
`none' hides the mode line.  Nil keeps the mode's inherited mode line,
for compatibility.  Any other value is an Emacs mode line format,
including existing (:eval ...) forms, and is installed unchanged.
This setting is applied when a buffer's mode starts.  To update an
existing buffer, call `git-islands-set-mode-line' there.  The Commit
file list's window always hides its mode line above the message pane."
  :type 'sexp
  :group 'git-islands)

(defcustom git-islands-header-function #'identity
  "Function given a tool window's header format, returning the one to show.
Called with one mode line format in the tool buffer during header
redisplay; return a mode line format.  The selected window need not be
that buffer's window.  Keep this function cheap and free of side effects.
The default is `identity'."
  :type 'function
  :group 'git-islands)

(defcustom git-islands-background-function nil
  "Function returning the color the tool windows are drawn on, or nil.
Called without arguments in the tool buffer while drawing or setting up
its header.  Return an Emacs color string.  Nil, or a function returning
nil, means the default face's background.  Existing header face remappings
are set at mode initialization; recreate buffers after changing this."
  :type '(choice (const nil) function)
  :group 'git-islands)

(defcustom git-islands-with-anchor-function
  (lambda (_anchor read) (funcall read))
  "Function calling READ, which reads in the minibuffer, below ANCHOR.
ANCHOR is a function returning the frame pixel position (X Y 0) that a
filter's popup should drop down from.  Call ANCHOR without arguments only
when positioning the popup; it may return nil if no log window exists.
Call READ without arguments synchronously,
in the invoking filter command's buffer/window context, and return its
result.  Preserve quit/errors.  The default simply calls READ."
  :type 'function
  :group 'git-islands)

(defcustom git-islands-fallback-directory-function nil
  "Function returning the directory to act on outside any repository, or nil.
Commands opening a tool window from a buffer that is not in a repository
try it, say for a project sidebar's directory.  Called without arguments
in the invoking command's buffer; return a directory string or nil."
  :type '(choice (const nil) function)
  :group 'git-islands)

(defcustom git-islands-side-window-width 40
  "Width in columns of a tool window on the frame's left.
Or a function called without arguments returning a positive column count.
It is called while opening and resizing panes; do not assume the current
buffer is a tool buffer.  Set it before opening the Commit tool window."
  :type '(choice integer function)
  :group 'git-islands)

(defcustom git-islands-message-window-height 8
  "Initial total height of the Commit message window.
An integer counts lines, including the header and mode line; a float
between zero and one is a fraction of the available window height.
The default leaves a compact writing area.  Use 0.3 for the previous
layout.  Applied only when displaying a new message window; existing
windows retain their size and can be resized manually."
  :type '(choice (integer :tag "Lines") (float :tag "Fraction"))
  :group 'git-islands)

(defcustom git-islands-side-window-hook nil
  "Hook run before a tool window takes the frame's left side.
Called without arguments in the invoking buffer, after tool buffers are
created but before their windows are displayed.  Return values are ignored.
A configuration can hide another sidebar here; preserve the current buffer
and selected window when doing unrelated work."
  :type 'hook
  :group 'git-islands)

(defun git-islands-side-width ()
  "Return the width of a tool window on the frame's left, in columns."
  (if (functionp git-islands-side-window-width)
      (funcall git-islands-side-window-width)
    git-islands-side-window-width))

(defun git-islands-default-mode-line ()
  "Return a compact label for the window whose mode line is being drawn.
During mode line evaluation Emacs selects the window being rendered.
Measure using the mode line face, since the tool buffer uses a different
font.  The full directory remains available in the tooltip."
  (let* ((window (selected-window))
         (graphic (display-graphic-p (window-frame window)))
         (face 'mode-line)
         (measure (lambda (text)
                    (if graphic
                        (string-pixel-width (propertize text 'face face))
                      (string-width text))))
         (available (max 0 (- (if graphic (window-pixel-width window)
                                (window-total-width window))
                              (funcall measure "  "))))
         (title (format " %s" mode-name))
         (full (concat title " · "
                       (file-name-nondirectory
                        (directory-file-name default-directory))))
         (label (if (<= (funcall measure full) available) full title)))
    (when (> (funcall measure label) available)
      (while (and (> (length label) 0)
                  (> (funcall measure (concat label "…")) available))
        (setq label (substring label 0 -1)))
      (setq label (if (<= (funcall measure "…") available)
                      (concat label "…") "")))
    (propertize label 'help-echo (abbreviate-file-name default-directory))))

(defun git-islands-set-mode-line ()
  "Apply `git-islands-mode-line-format' in the current tool buffer.
Nil leaves the current format unchanged, as in earlier versions."
  (pcase git-islands-mode-line-format
    ('nil nil)
    ('none (setq-local mode-line-format nil))
    ('default
     (setq-local mode-line-format
                 '(:eval (git-islands-default-mode-line))))
    (_ (setq-local mode-line-format git-islands-mode-line-format))))

(defun git-islands-fallback-directory ()
  "Return the directory `git-islands-fallback-directory-function' names, or nil."
  (and git-islands-fallback-directory-function
       (funcall git-islands-fallback-directory-function)))

(defun git-islands-in-editor (function &rest args)
  "Call FUNCTION with ARGS, or interactively, from the last editor window.
Tool windows are dedicated side windows, which cannot show other buffers."
  (when-let* ((window (get-mru-window nil nil t)))
    (select-window window))
  (if args (apply function args) (call-interactively function)))

(provide 'git-islands-env)
;;; git-islands-env.el ends here
