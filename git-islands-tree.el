;;; git-islands-tree.el --- Changed-file trees of the Git tool windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Rows for the Git tool windows: a group ("Changes"), folders and files,
;; each with a disclosure chevron, an optional New UI checkbox, an icon and
;; a name colored by how the file changed.  Rows are Magit sections, so
;; they fold and keep their visibility across refreshes; a line prefix
;; gives them their height and indentation (see tool-islands.el).

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
(require 'tool-islands)

;;;; Faces

(defface git-islands-group '((t (:inherit tool-islands-title)))
  "Group rows such as Changes."
  :group 'git-islands)

;;;; Trees

(defun git-islands-tree-build (entries)
  "Return the folder tree of ENTRIES, as `tool-islands-tree-build' does."
  (tool-islands-tree-build entries #'git-islands-entry-path))

(defalias 'git-islands-tree-entries #'tool-islands-tree-items)

(defun git-islands-file-icon (entry)
  "Return the icon of ENTRY's file."
  (let ((path (git-islands-entry-path entry)))
    (tool-islands-icon (expui-icons-name-for-file (file-name-nondirectory path)))))

(defun git-islands-file-label (entry &optional directory)
  "Return ENTRY's name in its change face, and DIRECTORY dimmed after it."
  (let* ((path (git-islands-entry-path entry))
         (change (git-islands-entry-change entry))
         (name (propertize (file-name-nondirectory path)
                           'face (git-islands-change-face change))))
    (tool-islands-fit
     (concat name
             (when-let* ((orig (git-islands-entry-orig entry)))
               (propertize (concat "  ← " (file-name-nondirectory orig)) 'face 'tool-islands-dim))
             (when (and directory (file-name-directory path))
               (propertize (concat "  " (directory-file-name (file-name-directory path)))
                           'face 'tool-islands-dim))))))

;;;; Inserting trees

;; CHECKBOX, where taken, is nil or a function of a row's entries returning
;; its checkbox, or nil for a row without one.

(defun git-islands-tree-checkbox (checkbox entries)
  "Return CHECKBOX's checkbox for ENTRIES followed by a gap, or nothing."
  (when-let* ((box (and checkbox (funcall checkbox entries))))
    (concat box (tool-islands-space 6))))

(defun git-islands-tree-insert-file (entry depth flat checkbox)
  "Insert ENTRY's row DEPTH levels deep; FLAT shows its folder after it."
  (magit-insert-section (git-islands-file (git-islands-entry-path entry))
                        (tool-islands-row
                         depth
                         (propertize
                          (concat (git-islands-tree-checkbox checkbox (list entry))
                                  (git-islands-file-icon entry) (tool-islands-gap)
                                  (git-islands-file-label entry flat))
                          'git-islands-entries (list entry) 'git-islands-entry entry))))

(defun git-islands-tree-insert-node (node depth checkbox)
  "Insert folder NODE's row DEPTH levels deep, then what it holds."
  (let ((entries (git-islands-tree-entries node)))
    (magit-insert-section (git-islands-dir (car node))
                          (tool-islands-row
                           depth
                           (propertize
                            (concat (git-islands-tree-checkbox checkbox entries)
                                    (tool-islands-icon "nodes/folder") (tool-islands-gap)
                                    (tool-islands-fit (car node))
                                    (propertize (format "  %d" (length entries)) 'face 'tool-islands-dim))
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
                        (tool-islands-row
                         0
                         (propertize
                          (concat (if entries
                                      (git-islands-tree-checkbox checkbox entries)
                                    ;; Keep the title in line with the groups that have one.
                                    (and checkbox (tool-islands-space (+ tool-islands-checkbox-size 6))))
                                  (tool-islands-fit (if (get-text-property 0 'face title) title
                                                     (propertize title 'face 'git-islands-group)))
                                  ;; A bare count, as on folders.
                                  (propertize (if entries
                                                  (format "  %d" (length entries))
                                                (concat "  " (or empty "")))
                                              'face 'tool-islands-dim))
                          'git-islands-entries entries))
                        (magit-insert-heading)
                        (git-islands-tree-insert-entries entries 1 grouped checkbox)))

(provide 'git-islands-tree)
;;; git-islands-tree.el ends here
