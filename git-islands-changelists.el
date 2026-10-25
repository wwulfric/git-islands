;;; git-islands-changelists.el --- IntelliJ's changelists -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Named groups of changed files, kept per repository in the Git directory
;; (emacs-changelists.eld), so they survive restarts but never reach a
;; commit.  A changed file belongs to the list it was moved to, or else to
;; the active list; once it no longer differs from HEAD it is forgotten,
;; and when it changes again it lands in the active list, as in IntelliJ.
;; Lists only group files: staging still decides what a commit takes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'git-islands-core)

(defconst git-islands-default-changelist "Changes" "The list that always exists.")

(cl-defstruct (git-islands-changelists (:constructor git-islands-changelists-create))
  "A repository's changelists."
  (names (list git-islands-default-changelist))  ; in display order
  (active git-islands-default-changelist)
  (files nil))                              ; alist of path to list name

(defvar git-islands-changelists-cache (make-hash-table :test #'equal)
  "Repository root to its changelists.")

(defun git-islands-changelists-file (root)
  "Return the file keeping ROOT's changelists."
  (expand-file-name "emacs-changelists.eld" (git-islands-gitdir root)))

(defun git-islands-changelists (root)
  "Return ROOT's changelists, reading them the first time."
  (or (gethash root git-islands-changelists-cache)
      (puthash root
               (let ((file (git-islands-changelists-file root)))
                 (or (ignore-errors
                       (when (file-exists-p file)
                         (with-temp-buffer
                           (insert-file-contents file)
                           (let ((data (read (current-buffer))))
                             (git-islands-changelists-create
                              :names (or (plist-get data :names)
                                         (list git-islands-default-changelist))
                              :active (or (plist-get data :active) git-islands-default-changelist)
                              :files (plist-get data :files))))))
                     (git-islands-changelists-create)))
               git-islands-changelists-cache)))

(defun git-islands-changelists-save (root)
  "Write ROOT's changelists to its Git directory."
  (let ((lists (git-islands-changelists root))
        (print-length nil)
        (print-level nil))
    (with-temp-file (git-islands-changelists-file root)
      (prin1 (list :names (git-islands-changelists-names lists)
                   :active (git-islands-changelists-active lists)
                   :files (git-islands-changelists-files lists))
             (current-buffer))
      (insert "\n"))))

(defun git-islands-changelist-of (root path)
  "Return the changelist PATH of ROOT belongs to."
  (let ((lists (git-islands-changelists root)))
    (or (cdr (assoc path (git-islands-changelists-files lists)))
        (git-islands-changelists-active lists))))

(defun git-islands-changelists-group (root entries)
  "Return ENTRIES of ROOT grouped as ((NAME . ENTRIES) ...) in list order.
Paths no longer among ENTRIES are forgotten."
  (let* ((lists (git-islands-changelists root))
         (paths (mapcar #'git-islands-entry-path entries))
         (kept (seq-filter (lambda (cell) (member (car cell) paths))
                           (git-islands-changelists-files lists))))
    (unless (= (length kept) (length (git-islands-changelists-files lists)))
      (setf (git-islands-changelists-files lists) kept)
      (git-islands-changelists-save root))
    (mapcar (lambda (name)
              (cons name (seq-filter (lambda (entry)
                                       (equal (git-islands-changelist-of root (git-islands-entry-path entry))
                                              name))
                                     entries)))
            (git-islands-changelists-names lists))))

(defun git-islands-changelist-move (root paths name)
  "Move PATHS of ROOT to changelist NAME, creating it if needed."
  (let ((lists (git-islands-changelists root)))
    (unless (member name (git-islands-changelists-names lists))
      (setf (git-islands-changelists-names lists)
            (append (git-islands-changelists-names lists) (list name))))
    (setf (git-islands-changelists-files lists)
          (append (seq-remove (lambda (cell) (member (car cell) paths))
                              (git-islands-changelists-files lists))
                  ;; Files of the active list need no entry.
                  (unless (equal name (git-islands-changelists-active lists))
                    (mapcar (lambda (path) (cons path name)) paths))))
    (git-islands-changelists-save root)))

(defun git-islands-changelist-add (root name)
  "Add an empty changelist NAME to ROOT."
  (let ((lists (git-islands-changelists root)))
    (when (member name (git-islands-changelists-names lists))
      (user-error "Changelist %s already exists" name))
    (setf (git-islands-changelists-names lists)
          (append (git-islands-changelists-names lists) (list name)))
    (git-islands-changelists-save root)))

(defun git-islands-changelist-set-active (root name entries)
  "Make NAME ROOT's active changelist, keeping ENTRIES where they are."
  (let* ((lists (git-islands-changelists root))
         ;; Files following the old active list stay in it.
         (pinned (mapcar (lambda (entry)
                           (cons (git-islands-entry-path entry)
                                 (git-islands-changelist-of root (git-islands-entry-path entry))))
                         entries)))
    (setf (git-islands-changelists-active lists) name
          (git-islands-changelists-files lists)
          (seq-remove (lambda (cell) (equal (cdr cell) name)) pinned))
    (git-islands-changelists-save root)))

(defun git-islands-changelist-rename (root old new)
  "Rename ROOT's changelist OLD to NEW."
  (let ((lists (git-islands-changelists root)))
    (when (member new (git-islands-changelists-names lists))
      (user-error "Changelist %s already exists" new))
    (setf (git-islands-changelists-names lists)
          (mapcar (lambda (name) (if (equal name old) new name))
                  (git-islands-changelists-names lists))
          (git-islands-changelists-files lists)
          (mapcar (lambda (cell) (if (equal (cdr cell) old) (cons (car cell) new) cell))
                  (git-islands-changelists-files lists)))
    (when (equal (git-islands-changelists-active lists) old)
      (setf (git-islands-changelists-active lists) new))
    (git-islands-changelists-save root)))

(defun git-islands-changelist-delete (root name)
  "Delete ROOT's changelist NAME; its files join the active list."
  (let ((lists (git-islands-changelists root)))
    (when (equal name (git-islands-changelists-active lists))
      (user-error "Make another changelist active before deleting this one"))
    (setf (git-islands-changelists-names lists) (delete name (git-islands-changelists-names lists))
          (git-islands-changelists-files lists)
          (seq-remove (lambda (cell) (equal (cdr cell) name))
                      (git-islands-changelists-files lists)))
    (git-islands-changelists-save root)))

(provide 'git-islands-changelists)
;;; git-islands-changelists.el ends here
