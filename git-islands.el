;;; git-islands.el --- IntelliJ-style Git tool windows on top of Magit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;; Author: haidao
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit "4.7") (expui-icons "0.2"))
;; Keywords: vc, tools
;; URL: https://github.com/wwulfric/git-islands

;;; Commentary:
;; Git tool windows modeled on JetBrains' New UI, drawn in Emacs and
;; driven by Magit:
;;
;; - the Commit tool window, whose checkboxes are the index;
;; - the Git log, with its graph, branch filters and a details pane;
;; - the branches popup, side-by-side diffs, a three-pane merge, and
;;   annotations in the margin.
;;
;; Magit loads only when a tool window first opens or a command changes
;; a repository.  Nothing is bound by default; bind the commands, or
;; `git-islands-command-map':
;;
;;   (keymap-global-set "C-c g" git-islands-command-map)
;;
;; The tool windows ask the editor around them through the variables in
;; git-islands-env.el (status line, header corners, where popups drop
;; down from, what makes room for the Commit tool window) and draw with
;; the faces and sizes in git-islands-ui.el.  Their defaults work in a
;; bare Emacs; a configuration can tie them to its own look.

;;; Code:

(require 'git-islands-env)

(autoload 'git-islands-commit-toggle "git-islands-commit-panel" nil t)
(autoload 'git-islands-message-focus "git-islands-commit-panel" nil t)
(autoload 'git-islands-log-toggle "git-islands-log" nil t)
(autoload 'git-islands-log-file "git-islands-log" nil t)
(autoload 'git-islands-branches-popup "git-islands-branches" nil t)
(autoload 'git-islands-annotate "git-islands-annotate" nil t)
(autoload 'git-islands-conflicts "git-islands-merge" nil t)

;;;###autoload
(defvar git-islands-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "c" #'git-islands-commit-toggle)
    (define-key map "k" #'git-islands-message-focus)
    (define-key map "l" #'git-islands-log-toggle)
    (define-key map "f" #'git-islands-log-file)
    (define-key map "b" #'git-islands-branches-popup)
    (define-key map "a" #'git-islands-annotate)
    (define-key map "m" #'git-islands-conflicts)
    map)
  "Keys for the Git tool windows, for binding under a prefix.")

(provide 'git-islands)
;;; git-islands.el ends here
