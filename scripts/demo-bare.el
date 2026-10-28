;;; demo-bare.el --- Git Islands in an unconfigured Emacs -*- lexical-binding: t; -*-

;; Run in a graphical Emacs with -Q, loading only Git Islands and its
;; dependencies (see docs/screenshots.md).  All Git changes are made in a
;; fresh temporary repository.  No theme, font, face or UI option is set.

(require 'git-islands)
(require 'git-islands-commit-panel)
(require 'git-islands-diff)
(require 'git-islands-log)

(defvar git-islands-demo-root (file-name-as-directory
                             (make-temp-file "git-islands-demo-" t)))

(defun git-islands-demo-write (path text)
  "Write TEXT to PATH in the demo repository."
  (let ((file (expand-file-name path git-islands-demo-root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defun git-islands-demo-git (&rest args)
  "Run Git ARGS in the demo repository, failing on errors."
  (let ((default-directory git-islands-demo-root))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "Demo Git failed: %s" (buffer-string))))))

(defun git-islands-demo-commit (message)
  "Commit the demo changes with MESSAGE."
  (git-islands-demo-git "add" ".")
  (git-islands-demo-git "commit" "-m" message))

;; Keep the fixture independent of the user's Git configuration and hooks.
(let ((process-environment (copy-sequence process-environment)))
  (setenv "GIT_CONFIG_GLOBAL" "/dev/null")
  (setenv "GIT_CONFIG_NOSYSTEM" "1")
  (setenv "GIT_AUTHOR_DATE" "2026-10-20T10:00:00+0000")
  (setenv "GIT_COMMITTER_DATE" "2026-10-20T10:00:00+0000")
  (git-islands-demo-git "init" "-b" "main")
  (git-islands-demo-git "config" "user.name" "Alex Chen")
  (git-islands-demo-git "config" "user.email" "alex@example.com")
  (git-islands-demo-git "config" "commit.gpgSign" "false")
  (git-islands-demo-write "README.md" "# Atlas\n\nA small search engine.\n")
  (git-islands-demo-commit "Create the Atlas project")
  (git-islands-demo-write
   "src/search.el"
   ";;; search.el --- Search an index -*- lexical-binding: t; -*-\n\n(require 'cl-lib)\n\n(defun atlas-search (index terms)\n  \"Find documents matching TERMS in INDEX.\"\n  (let (hits)\n    (dolist (term terms)\n      (setq hits (append (gethash term index) hits)))\n    (delete-dups hits)))\n\n(provide 'search)\n")
  (git-islands-demo-commit "Add document search")
  (git-islands-demo-git "checkout" "-b" "feature/ranking")
  (git-islands-demo-write "docs/ranking.md" "# Ranking\n\nRank documents by the number of matched terms.\n")
  (git-islands-demo-commit "Describe relevance ranking")
  (git-islands-demo-git "checkout" "main")
  (git-islands-demo-write "LICENSE" "Demo fixture for Git Islands screenshots.\n")
  (git-islands-demo-commit "Document the demo fixture")
  (git-islands-demo-git "merge" "--no-ff" "feature/ranking" "-m" "Merge relevance ranking design")
  (git-islands-demo-git "tag" "v0.1.0")
  (git-islands-demo-write "docs/usage.md" "# Usage\n\nSearch the index with a list of terms.\n")
  (git-islands-demo-commit "Add a search usage guide")
  (git-islands-demo-write "README.md" "# Atlas\n\nA small search engine with relevance ranking.\n")
  (git-islands-demo-git "add" "README.md")
  (git-islands-demo-write
   "src/search.el"
   ";;; search.el --- Search an index -*- lexical-binding: t; -*-\n\n(require 'cl-lib)\n\n(defun atlas-search (index terms)\n  \"Rank documents matching TERMS in INDEX.\"\n  (let ((scores (make-hash-table)))\n    (dolist (term terms)\n      (dolist (doc (gethash term index))\n        (cl-incf (gethash doc scores 0))))\n    (sort (hash-table-keys scores)\n          (lambda (a b)\n            (> (gethash a scores)\n               (gethash b scores))))))\n\n(provide 'search)\n")
  (git-islands-demo-write "test/search-tests.el" ";;; Search ranking tests\n(require 'ert)\n"))

(setq default-directory git-islands-demo-root)
(find-file (expand-file-name "src/search.el" git-islands-demo-root))
(git-islands-diff-show git-islands-demo-root "src/search.el" :left-rev "HEAD")
(git-islands-commit-show git-islands-demo-root)
(with-current-buffer (git-islands-message-buffer git-islands-demo-root)
  (insert "Rank search results by matched terms"))
(git-islands-log-show git-islands-demo-root)
(message "Demo repository: %s" git-islands-demo-root)

;;; demo-bare.el ends here
