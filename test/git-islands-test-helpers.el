;;; git-islands-test-helpers.el --- Fixtures for testing the Git tool windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Throwaway repositories and status reads for the package's tests, and
;; for a configuration's tests of what it builds on the package.

;;; Code:

(require 'cl-lib)
(require 'git-islands-core)


(defun git-islands-test-git (&rest args)
  "Run Git with ARGS in the current directory and return its output."
  (with-temp-buffer
    (let ((code (apply #'call-process "git" nil t nil
                       "-c" "user.name=Emacs Test"
                       "-c" "user.email=test@example.invalid"
                       "-c" "commit.gpgsign=false"
                       "-c" "core.hooksPath=/dev/null" args)))
      (unless (zerop code) (error "git %S failed: %s" args (buffer-string))))
    (string-trim (buffer-string))))

(defun git-islands-test-write (file text)
  "Write TEXT to FILE, making its folders."
  (make-directory (file-name-directory (expand-file-name file)) t)
  (with-temp-file file (insert text)))

(defmacro git-islands-test-with-repo (&rest body)
  "Run BODY in a fresh repository with one commit, bound as `root'."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "git-tests-" t)))
          (default-directory root)
          (process-environment (append '("GIT_AUTHOR_NAME=Emacs Test"
                                         "GIT_AUTHOR_EMAIL=test@example.invalid"
                                         "GIT_COMMITTER_NAME=Emacs Test"
                                         "GIT_COMMITTER_EMAIL=test@example.invalid"
                                         "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (progn
           (git-islands-test-git "init" "-q" "-b" "main")
           (git-islands-test-git "config" "commit.gpgsign" "false")
           (git-islands-test-write "README" "hello\n")
           (git-islands-test-write "src/a/b/deep.el" "deep\n")
           (git-islands-test-git "add" ".")
           (git-islands-test-git "commit" "-q" "-m" "Initial")
           ,@body)
       (dolist (buffer (buffer-list))
         (when (string-match-p (regexp-quote (abbreviate-file-name root))
                               (buffer-name buffer))
           (kill-buffer buffer)))
       (clrhash git-islands-status-cache)
       (clrhash git-islands-status-callbacks)
       (maphash (lambda (_ timer) (cancel-timer timer)) git-islands-refresh-timers)
       (clrhash git-islands-refresh-timers)
       (delete-directory root t))))

(defun git-islands-test-fetch (root)
  "Read ROOT's status and wait for it, after the index changes running."
  (with-timeout (10 (error "Index changes timed out"))
    (while (git-islands-index-busy-p root) (accept-process-output nil 0.05)))
  (let ((done nil))
    (git-islands-status-fetch root (lambda (_) (setq done t)))
    (with-timeout (10 (error "Status timed out"))
      (while (not done) (accept-process-output nil 0.05)))
    (git-islands-status root)))

(defun git-islands-test-entry (status path)
  "Return STATUS's entry for PATH."
  (seq-find (lambda (entry) (equal (git-islands-entry-path entry) path))
            (git-islands-status-entries status)))

(provide 'git-islands-test-helpers)
;;; git-islands-test-helpers.el ends here
