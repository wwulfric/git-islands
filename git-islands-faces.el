;;; git-islands-faces.el --- Colors of changed files -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; How IntelliJ colors a file by its change, shared by the project sidebar
;; and the Git tool windows.

;;; Code:

(defgroup git-islands nil
  "IntelliJ-style Git tool windows."
  :group 'tools)

(defface git-islands-modified
  '((((background dark)) :foreground "#6F9FFF")
    (t :foreground "#2F6BD8"))
  "Files modified since HEAD, as in IntelliJ's Changes view."
  :group 'git-islands)

(defface git-islands-added
  '((((background dark)) :foreground "#73BD79")
    (t :foreground "#1F7A35"))
  "Files new in the index."
  :group 'git-islands)

(defface git-islands-deleted
  '((((background dark)) :foreground "#868A91")
    (t :foreground "#6C707E"))
  "Files deleted since HEAD."
  :group 'git-islands)

(defface git-islands-untracked
  '((((background dark)) :foreground "#D5756C")
    (t :foreground "#B8423A"))
  "Files Git does not track."
  :group 'git-islands)

(defface git-islands-conflict
  '((((background dark)) :foreground "#F75464")
    (t :foreground "#D21A1A"))
  "Files with unresolved merge conflicts."
  :group 'git-islands)

(defface git-islands-dim '((t (:inherit shadow)))
  "Folders after a file name, counts and hints."
  :group 'git-islands)

(defun git-islands-change-face (change)
  "Return the face of a file that changed as CHANGE."
  (pcase change
    ('added 'git-islands-added)
    ('deleted 'git-islands-deleted)
    ('untracked 'git-islands-untracked)
    ('conflict 'git-islands-conflict)
    (_ 'git-islands-modified)))

(defface git-islands-button '((t (:inherit link :underline nil)))
  "Secondary buttons, such as Commit and Push."
  :group 'git-islands)

(defface git-islands-primary-button '((t (:inherit git-islands-button :weight bold)))
  "The default button, such as Commit."
  :group 'git-islands)

(provide 'git-islands-faces)
;;; git-islands-faces.el ends here
