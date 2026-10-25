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

(defcustom git-islands-mode-line-format nil
  "Mode line of the tool windows' lists, or nil for their modes' own."
  :type 'sexp
  :group 'git-islands)

(defcustom git-islands-header-function #'identity
  "Function given a tool window's header format, returning the one to show.
A configuration can wrap the header, say in rounded corners."
  :type 'function
  :group 'git-islands)

(defcustom git-islands-background-function nil
  "Function returning the color the tool windows are drawn on, or nil.
Nil, or a function returning nil, means the default face's background."
  :type '(choice (const nil) function)
  :group 'git-islands)

(defcustom git-islands-with-anchor-function
  (lambda (_anchor read) (funcall read))
  "Function calling READ, which reads in the minibuffer, below ANCHOR.
ANCHOR is a function returning the frame pixel position (X Y 0) that a
filter's popup should drop down from.  The default ignores it."
  :type 'function
  :group 'git-islands)

(defcustom git-islands-fallback-directory-function nil
  "Function returning the directory to act on outside any repository, or nil.
Commands opening a tool window from a buffer that is not in a repository
try it, say for a project sidebar's directory."
  :type '(choice (const nil) function)
  :group 'git-islands)

(defcustom git-islands-side-window-width 40
  "Width in columns of a tool window on the frame's left.
Or a function returning it."
  :type '(choice integer function)
  :group 'git-islands)

(defcustom git-islands-side-window-hook nil
  "Hook run before a tool window takes the frame's left side.
A configuration can hide what else shows there."
  :type 'hook
  :group 'git-islands)

(defun git-islands-side-width ()
  "Return the width of a tool window on the frame's left, in columns."
  (if (functionp git-islands-side-window-width)
      (funcall git-islands-side-window-width)
    git-islands-side-window-width))

(defun git-islands-set-mode-line ()
  "Give the current tool window list `git-islands-mode-line-format', if set."
  (when git-islands-mode-line-format
    (setq-local mode-line-format git-islands-mode-line-format)))

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
