;;; git-islands-tests.el --- Tests of the Git tool windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Run with `make test'.  Each test makes a throwaway repository.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'git-islands-test-helpers)
(require 'git-islands-core)
(require 'git-islands-tree)
(require 'git-islands-commit-panel)
(require 'git-islands-branches)
(require 'git-islands-log)
(require 'git-islands-diff)
(require 'git-islands-annotate)
(require 'git-islands-merge)
(require 'git-islands-merge3)
(require 'git-islands-changelists)

(ert-deftest git-islands-button-renderer-preserves-interaction ()
  (let* ((git-islands-button-render-function
          (lambda (label primary)
            (should primary)
            (concat "custom " label)))
         (button (git-islands-button "Apply" #'ignore "Apply changes" t))
         (map (get-text-property 0 'local-map button)))
    (should (equal (substring-no-properties button) "custom Apply"))
    (should (equal (get-text-property 0 'help-echo button) "Apply changes"))
    (should (commandp (lookup-key map [header-line down-mouse-1])))
    (should (eq (get-text-property 0 'mouse-face button) 'git-islands-toolbar-hover))))

(ert-deftest git-islands-plain-and-rounded-button-fallback ()
  (let ((git-islands-button-render-function #'git-islands-button-text))
    (cl-letf (((symbol-function 'git-islands-button-image)
               (lambda (&rest _) (ert-fail "Plain buttons must not render SVG"))))
      (should-not (get-text-property 0 'display (git-islands-button "Commit" #'ignore "Commit" t)))))
  (cl-letf (((symbol-function 'expui-icons-svg-p) (lambda () nil)))
    (should (equal (git-islands-button-rounded "Commit" t)
                   (git-islands-button-text "Commit" t)))))

(ert-deftest git-islands-selection-spacing-follows-options ()
  (let ((git-islands-hl-radius 0) (git-islands-hl-margin 0))
    (should (= (git-islands-fit-margin) 4))
    (should (eq (car (get-text-property 0 'display
                                      (git-islands-ui-pill-end 'left 0 20 "red")))
                'space)))
  (let ((git-islands-hl-radius 6) (git-islands-hl-margin 6))
    (should (= (git-islands-fit-margin) 16))))

(ert-deftest git-islands-headers-share-style-and-restore-remapping ()
  (dolist (mode '(git-islands-commit-mode git-islands-message-mode
                  git-islands-log-mode git-islands-details-mode git-islands-refs-mode))
    (with-temp-buffer
      (funcall mode)
      (should (member 'git-islands-header (cdr (assq 'header-line face-remapping-alist))))))
  (with-temp-buffer
    (face-remap-add-relative 'header-line 'bold)
    (let ((before (copy-tree face-remapping-alist))
          (git-islands-background-function (lambda () "#123456")))
      (git-islands-header-style t)
      (let ((once (copy-tree face-remapping-alist)))
        (git-islands-header-style t)
        (should (equal once face-remapping-alist))
        (should (member '(:inherit git-islands-header :background "#123456")
                        (cdr (assq 'header-line face-remapping-alist)))))
      (git-islands-header-style nil)
      (should (equal before face-remapping-alist)))))

(ert-deftest git-islands-header-centers-font-and-keeps-explicit-ascent ()
  (let ((git-islands-header-height 1.5)
        (git-islands-header-padding 4)
        (git-islands-header-ascent nil)
        (git-islands-button-render-function #'git-islands-button-text))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'face-font) (lambda (&rest _) "test-font"))
              ((symbol-function 'font-info)
               (lambda (&rest _) [nil nil 20 20 0 0 0 10 15 5])))
      (let ((spec (cdr (git-islands-header-space 0))))
        (should (equal (plist-get spec :height) '(30)))
        (should (= (plist-get spec :ascent) 67)))
      (let ((git-islands-header-ascent 68))
        (should (= (plist-get (cdr (git-islands-header-space 0)) :ascent) 68)))
      (let ((git-islands-button-render-function #'git-islands-button-rounded))
        (cl-letf (((symbol-function 'frame-char-height) (lambda (&rest _) 30)))
          (should (equal (plist-get (cdr (git-islands-header-space 0)) :height) '(50))))))))

(ert-deftest git-islands-header-delegates-exact-editor-metrics ()
  (let ((git-islands-header-space-function
         (lambda (width) `(space :width ,width :height 1.9 :ascent 68))))
    (dolist (width '(0 (12)))
      (should (equal (git-islands-header-space width)
                     `(space :width ,width :height 1.9 :ascent 68))))))

;;;; Editor integration

(ert-deftest git-islands-mode-lines-default-and-overrides ()
  ;; Cover every consumer, including the writable commit message mode.
  (dolist (mode '(git-islands-commit-mode git-islands-message-mode
                  git-islands-log-mode git-islands-details-mode
                  git-islands-refs-mode))
    (dolist (setting '(default none nil (" custom ")
                      (:eval (concat "personal" " status"))))
      (with-temp-buffer
        (let ((git-islands-mode-line-format setting)
              (inherited (default-value 'mode-line-format)))
          (funcall mode)
          (pcase setting
            ('default
             (setq default-directory "/tmp/parent/project/")
             (should (equal mode-line-format
                            '(:eval (git-islands-default-mode-line))))
             (should (string-match-p "project" (git-islands-default-mode-line))))
            ('none (should-not mode-line-format))
            ('nil (should (equal mode-line-format inherited)))
            (_ (should (equal mode-line-format setting)))))))))

(ert-deftest git-islands-mode-lines-update-existing-buffer ()
  (with-temp-buffer
    (let ((git-islands-mode-line-format 'none))
      (git-islands-log-mode)
      (should-not mode-line-format)
      (setq git-islands-mode-line-format '(:eval (concat "personal" " status")))
      (git-islands-set-mode-line)
      (should (equal mode-line-format git-islands-mode-line-format))
      (setq git-islands-mode-line-format nil)
      (git-islands-set-mode-line)
      (should (equal mode-line-format '(:eval (concat "personal" " status"))))
      (setq git-islands-mode-line-format 'default)
      (git-islands-set-mode-line)
      (should (equal mode-line-format '(:eval (git-islands-default-mode-line)))))))

(ert-deftest git-islands-mode-line-fits-each-window ()
  (save-window-excursion
    (delete-other-windows)
    (let ((buffer (generate-new-buffer " *mode-line-test*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) buffer)
            (with-current-buffer buffer
              (special-mode)
              (setq mode-name "Git Log"
                    default-directory "/tmp/parent/repository-name/"))
            (let ((narrow (split-window-right 24)))
              (set-window-buffer narrow buffer)
              (with-current-buffer buffer
                (let ((small (git-islands-default-mode-line)))
                  (should (equal small " Git Log"))
                  (should (equal (get-text-property 0 'help-echo small)
                                 default-directory)))
                (with-selected-window narrow
                  (should (string-match-p "repository-name"
                                          (git-islands-default-mode-line)))))))
        (kill-buffer buffer)))))

(ert-deftest git-islands-message-initial-height-and-manual-resize ()
  (git-islands-test-with-repo
    (save-window-excursion
      (delete-other-windows)
      (let ((git-islands-message-window-height 8))
        (git-islands-commit-show root)
        (let ((message-window (git-islands-message-window)))
          (should (= (window-total-height message-window) 8))
          (window-resize message-window 2)
          (let ((height (window-total-height message-window)))
            (git-islands-commit-show root)
            (should (= (window-total-height message-window) height))))))))

(ert-deftest git-islands-message-minimum-body-survives-layout ()
  (git-islands-test-with-repo
    (save-window-excursion
      (delete-other-windows)
      (git-islands-commit-show root)
      (let ((window (git-islands-message-window))
            (git-islands-message-min-body-lines 4))
        (window-preserve-size window nil nil)
        (window-resize window (- 3 (window-total-height window)) nil t)
        (git-islands-message-ensure-height)
        (should (>= (window-body-height window t) (* 4 (frame-char-height))))))))

(ert-deftest git-islands-diff-restores-soft-wrapping ()
  (dolist (local '(nil t))
    (with-temp-buffer
      (let ((truncate-lines nil) (truncate-partial-width-windows nil))
        (when local
          (setq-local truncate-lines nil truncate-partial-width-windows nil))
        (git-islands-diff-mode 1)
        (git-islands-diff-mode 1)
        (should truncate-lines)
        (should truncate-partial-width-windows)
        (git-islands-diff-mode -1)
        (should-not truncate-lines)
        (should-not truncate-partial-width-windows)
        (should (eq (local-variable-p 'truncate-lines) local))
        (should (eq (local-variable-p 'truncate-partial-width-windows) local))))))

(ert-deftest git-islands-diff-header-fit-keeps-tooltip ()
  (cl-letf (((symbol-function 'string-pixel-width) #'string-width))
    (let ((text (git-islands-diff-header-fit "HEAD very/long/path.el" 10)))
      (should (<= (string-width text) 10))
      (should (string-suffix-p "…" text))
      (should (equal (get-text-property 0 'help-echo text) "HEAD very/long/path.el")))))

(ert-deftest git-islands-diff-overlays-keep-personal-line-metrics ()
  (with-temp-buffer
    (insert "a\nb\n")
    (let ((default-text-properties '(line-height 1.2 line-spacing 0.2)))
      (git-islands-diff-mark (point-min) (point-max) 'git-islands-diff-modified)
      (git-islands-diff-fill 2 2)
      (git-islands-diff-preserve-spacing (current-buffer))
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (should (= (overlay-get overlay 'line-height) 1.2))
        (should (= (overlay-get overlay 'line-spacing) 0.2))
        (when-let* ((string (overlay-get overlay 'before-string)))
          (should (= (get-text-property 0 'line-height string) 1.2))
          (should (= (get-text-property 0 'line-spacing string) 0.2)))))))

;;;; Parsing

(ert-deftest git-islands-status-parse-porcelain-v2 ()
  (let* ((output (concat "# branch.oid 1234567890abcdef\0"
                         "# branch.head main\0"
                         "# branch.upstream origin/main\0"
                         "# branch.ab +2 -1\0"
                         "1 .M N... 100644 100644 100644 aaa aaa lisp/a b.el\0"
                         "1 A. N... 000000 100644 100644 000 bbb new.el\0"
                         "2 R. N... 100644 100644 100644 ccc ccc R100 to.el\0from.el\0"
                         "u UU N... 100644 100644 100644 100644 d e f both.el\0"
                         "? notes/todo.txt\0"))
         (status (git-islands-status-parse output))
         (entries (git-islands-status-entries status)))
    (should (equal (git-islands-status-branch status) "main"))
    (should (equal (git-islands-status-upstream status) "origin/main"))
    (should (= (git-islands-status-ahead status) 2))
    (should (= (git-islands-status-behind status) 1))
    (should (equal (mapcar #'git-islands-entry-path entries)
                   '("lisp/a b.el" "new.el" "to.el" "both.el" "notes/todo.txt")))
    (should (equal (mapcar #'git-islands-entry-change entries)
                   '(modified added renamed conflict untracked)))
    (should (equal (git-islands-entry-orig (nth 2 entries)) "from.el"))
    (should (equal (mapcar #'git-islands-entry-checkbox-state entries)
                   '(off on on off off)))))

(ert-deftest git-islands-status-parse-initial-and-detached ()
  (let ((status (git-islands-status-parse "# branch.oid (initial)\0# branch.head (detached)\0")))
    (should-not (git-islands-status-head status))
    (should-not (git-islands-status-branch status))
    (should-not (git-islands-status-entries status))))

(ert-deftest git-islands-tree-compacts-single-folders ()
  (let* ((entries (mapcar (lambda (path) (git-islands-entry-create :path path :index ?M
                                                              :worktree ?. :kind 'changed))
                          '("src/a/b/x.el" "src/a/b/y.el" "src/c.el" "top.el")))
         (tree (git-islands-tree-build entries)))
    (should (equal (mapcar #'car (nth 1 tree)) '("src")))
    (should (equal (mapcar #'car (nth 1 (car (nth 1 tree)))) '("a/b")))
    (should (equal (mapcar #'git-islands-entry-path (nth 2 tree)) '("top.el")))
    (should (= (length (git-islands-tree-entries tree)) 4))))

;;;; Against a repository

(ert-deftest git-islands-status-reads-repository ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "hello again\n")
    (git-islands-test-write "new/file.txt" "new\n")
    (git-islands-test-git "add" "README")
    (git-islands-test-write "README" "hello once more\n")
    (let ((status (git-islands-test-fetch root)))
      (should (equal (git-islands-status-branch status) "main"))
      (should (eq (git-islands-entry-checkbox-state (git-islands-test-entry status "README")) 'partial))
      (should (eq (git-islands-entry-change (git-islands-test-entry status "new/file.txt")) 'untracked)))))

(ert-deftest git-islands-commit-panel-stages-and-commits ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "changed\n")
    (git-islands-test-write "src/a/b/deep.el" "changed too\n")
    (git-islands-test-write "extra.txt" "untracked\n")
    (git-islands-test-fetch root)
    (let ((panel (git-islands-commit-buffer root)))
      (with-current-buffer panel
        (git-islands-commit-render)
        (let ((text (buffer-string)))
          (should (string-match-p "Changes" text))
          (should (string-match-p "Unversioned Files" text))
          (should (string-match-p "src/a/b" text))
          (should (string-match-p "README" text)))
        ;; Check the README row: it is staged.
        (goto-char (point-min))
        (search-forward "README")
        (git-islands-commit-include)
        (git-islands-test-fetch root)
        (should (eq (git-islands-entry-checkbox-state
                     (git-islands-test-entry (git-islands-status root) "README"))
                    'on))
        ;; The panel was drawn again from the new snapshot, point kept on README.
        (should (equal (git-islands-entry-path (git-islands-commit-entry)) "README"))
        ;; Unchecking unstages it again.
        (git-islands-commit-include)
        (git-islands-test-fetch root)
        (should (eq (git-islands-entry-checkbox-state
                     (git-islands-test-entry (git-islands-status root) "README"))
                    'off))
        ;; The Changes group checks every changed file.
        (goto-char (point-min))
        (search-forward "Changes")
        (git-islands-commit-include)
        (git-islands-test-fetch root)
        (should (eq (git-islands-entries-checkbox-state
                     (seq-filter (lambda (entry) (eq (git-islands-entry-kind entry) 'changed))
                                 (git-islands-status-entries (git-islands-status root))))
                    'on)))
      (with-current-buffer (git-islands-message-buffer root)
        (should-error (git-islands-message-commit) :type 'user-error)
        (insert "Change two files\n\nWith a body.")
        (let ((done nil))
          (cl-letf* ((original (symbol-function 'git-islands-commit))
                     ((symbol-function 'git-islands-commit)
                      (lambda (root text amend then)
                        (funcall original root text amend
                                 (lambda (code) (funcall then code) (setq done t))))))
            (git-islands-message-commit))
          (with-timeout (15 (error "Commit timed out"))
            (while (not done) (accept-process-output nil 0.05))))
        (should (string-empty-p (buffer-string)))
        (should (equal (car git-islands-message-history) "Change two files\n\nWith a body.")))
      (should (equal (git-islands-test-git "log" "-1" "--format=%s") "Change two files"))
      (should (equal (git-islands-test-git "status" "--porcelain") "?? extra.txt")))))

(ert-deftest git-islands-commit-amend-fills-last-message ()
  (git-islands-test-with-repo
    (with-current-buffer (git-islands-message-buffer root)
      (insert "draft")
      (git-islands-message-toggle-amend)
      (should (equal (buffer-string) "draft"))
      (git-islands-message-toggle-amend)
      (erase-buffer)
      (git-islands-message-toggle-amend)
      (should (equal (buffer-string) "Initial"))
      (git-islands-message-toggle-amend)
      (should (equal (buffer-string) "")))))

(ert-deftest git-islands-commit-tool-window-replaces-sidebar ()
  (git-islands-test-with-repo
    (delete-other-windows)
    (let ((window (git-islands-commit-show root)))
      (should (eq (git-islands-commit-window) window))
      (should (window-parameter window 'window-side))
      (should (git-islands-message-window))
      ;; Both headers draw; batch frames do not format header lines.
      (with-selected-window window
        (should (string-match-p "Commit" (git-islands-commit-header))))
      (with-selected-window (git-islands-message-window)
        (should (string-match-p "Amend" (git-islands-message-header))))
      ;; The sidebar taking the slot back closes the message too.
      (display-buffer-in-side-window (get-buffer-create "*other*")
                                     '((side . left) (slot . -1)))
      (git-islands-commit-sync (selected-frame))
      (should-not (git-islands-commit-window))
      (should-not (git-islands-message-window))
      (kill-buffer "*other*"))
    (git-islands-commit-show root)
    (git-islands-commit-hide)
    (should-not (git-islands-commit-window))))

(ert-deftest git-islands-rollback-restores-files ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "changed\n")
    (git-islands-test-write "added.el" "new\n")
    (git-islands-test-git "add" "added.el")
    (let* ((status (git-islands-test-fetch root))
           (delete-by-moving-to-trash nil))
      (git-islands-rollback root (git-islands-status-entries status))
      (should (equal (git-islands-test-git "status" "--porcelain") "?? added.el"))
      (should (file-exists-p (expand-file-name "added.el" root)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "README" root))
        (should (equal (buffer-string) "hello\n"))))))

;;;; Branches

(defun git-islands-test-wait-process (process)
  "Wait for PROCESS, a Git command started through Magit, to finish."
  (with-timeout (15 (error "Git timed out"))
    (while (process-live-p process) (accept-process-output nil 0.05)))
  ;; Let the sentinel and its callbacks run.
  (accept-process-output nil 0.1))

(ert-deftest git-islands-branches-read-and-recent ()
  (git-islands-test-with-repo
    (git-islands-test-git "branch" "feature")
    (git-islands-test-git "branch" "old")
    (git-islands-test-git "checkout" "-q" "old")
    (git-islands-test-git "checkout" "-q" "feature")
    (git-islands-test-write "f.txt" "f\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Feature work")
    (git-islands-test-git "branch" "--set-upstream-to=main" "feature")
    (git-islands-test-git "checkout" "-q" "main")
    (let* ((branches (git-islands-branches root))
           (feature (seq-find (lambda (b) (equal (git-islands-branch-name b) "feature")) branches))
           (main (seq-find (lambda (b) (equal (git-islands-branch-name b) "main")) branches)))
      (should (equal (mapcar #'git-islands-branch-name branches) '("feature" "main" "old")))
      (should (git-islands-branch-current main))
      (should (equal (git-islands-branch-upstream feature) "main"))
      (should (= (git-islands-branch-ahead feature) 1))
      (should (= (git-islands-branch-behind feature) 0))
      (should (equal (mapcar #'git-islands-branch-name (git-islands-recent-branches root branches))
                     '("feature" "old")))
      (should (string-match-p "↑1" (git-islands-branch-annotation feature)))
      (let ((candidates (git-islands-popup-candidates root)))
        (should (equal (delete-dups (mapcar (lambda (c) (get-text-property 0 'git-islands-group c))
                                            candidates))
                       '("Actions" "Recent" "Local")))
        ;; A recent branch is not listed again among the local ones.
        (should (= 1 (seq-count (lambda (c) (equal c "feature")) candidates)))))))

(ert-deftest git-islands-branch-actions-change-repository ()
  (git-islands-test-with-repo
    (let ((branch (lambda (name) (seq-find (lambda (b) (equal (git-islands-branch-name b) name))
                                           (git-islands-branches root)))))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "topic")))
        (git-islands-test-wait-process (git-islands-branch-new-from root (funcall branch "main"))))
      (should (equal (git-islands-test-git "symbolic-ref" "--short" "HEAD") "topic"))
      (git-islands-test-wait-process (git-islands-branch-checkout root (funcall branch "main")))
      (should (equal (git-islands-test-git "symbolic-ref" "--short" "HEAD") "main"))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "renamed")))
        (git-islands-test-wait-process (git-islands-branch-rename root (funcall branch "topic"))))
      (should (equal (git-islands-test-git "branch" "--format=%(refname:short)") "main\nrenamed"))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (git-islands-test-wait-process (git-islands-branch-delete root (funcall branch "renamed"))))
      (should (equal (git-islands-test-git "branch" "--format=%(refname:short)") "main"))
      (should (equal (mapcar #'car (git-islands-branch-actions (funcall branch "main") "main"))
                     '("New Branch from 'main'…" "Update" "Push…" "Rename…"))))))

(ert-deftest git-islands-widget-shows-branch ()
  (git-islands-test-with-repo
    (with-temp-buffer
      (setq default-directory root)
      (should-not (git-islands-widget-current))
      (git-islands-test-fetch root)
      (let ((current (git-islands-widget-current)))
        (should (equal (car current) root))
        (should (equal (git-islands-widget-label (cdr current)) "⎇ main"))))))

;;;; Log

(defun git-islands-test-graph (commits)
  "Return the rows COMMITS, a list of (HASH . PARENTS), get in a graph."
  (let ((graph (git-islands-graph-create)))
    (mapcar (lambda (commit) (git-islands-graph-step graph (car commit) (cdr commit))) commits)))

(ert-deftest git-islands-graph-linear-history ()
  (let ((rows (git-islands-test-graph '(("c" "b") ("b" "a") ("a")))))
    (should (equal (mapcar #'git-islands-graph-row-node rows) '(0 0 0)))
    (should (equal (mapcar #'git-islands-graph-row-width rows) '(1 1 1)))
    ;; Only the root has no line below its dot.
    (should (equal (git-islands-graph-row-segments (nth 2 rows)) '((0 0 0 1 0))))))

(ert-deftest git-islands-graph-branch-and-merge ()
  (let* ((rows (git-islands-test-graph '(("m" "a" "b") ("b" "c") ("a" "c") ("c"))))
         (merge (nth 0 rows)) (side (nth 1 rows)) (main (nth 2 rows)) (base (nth 3 rows)))
    (should (equal (mapcar #'git-islands-graph-row-node rows) '(0 1 0 1)))
    ;; The merge opens a second lane for its second parent.
    (should (member '(0 1 1 2) (mapcar #'butlast (git-islands-graph-row-segments merge))))
    (should (= (git-islands-graph-row-width merge) 2))
    ;; The side branch passes lane 0 and continues its own.
    (should (member '(0 0 0 2) (mapcar #'butlast (git-islands-graph-row-segments side))))
    ;; The first parent's lane joins the lane already waiting for c.
    (should (member '(0 1 1 2) (mapcar #'butlast (git-islands-graph-row-segments main))))
    (should (= (git-islands-graph-row-width base) 2))
    ;; Lanes keep their colors: c's dot has b's lane's color.
    (should (= (git-islands-graph-row-color base) (git-islands-graph-row-color side)))))

(ert-deftest git-islands-log-parse-and-format ()
  (let ((commit (git-islands-log-parse-record
                 (concat "\nabc\x1f\ p1 p2\x1f\ Ada\x1f\ ada@example.invalid\x1f\ 1700000000\x1f\ "
                         "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1"
                         "\x1f\ Fix a\x1f\ b"))))
    (should (equal (git-islands-commit-hash commit) "abc"))
    (should (equal (git-islands-commit-parents commit) '("p1" "p2")))
    (should (equal (git-islands-commit-refs commit)
                   '("HEAD -> refs/heads/main" "refs/remotes/origin/main" "tag: refs/tags/v1")))
    (should (equal (git-islands-commit-subject commit) "Fix a\x1f\ b")))
  ;; A branch takes in its remote at the same commit; tags share one label;
  ;; a local branch with a slash stays local; remotes' HEAD is left out.
  (should (equal (git-islands-log-refs-parse
                  '("HEAD -> refs/heads/main" "refs/remotes/origin/main" "refs/remotes/origin/HEAD"
                    "refs/heads/feature/x" "refs/remotes/upstream/dev" "tag: refs/tags/v1"
                    "tag: refs/tags/v2"))
                 '((head "origin & main" (git-islands-ref-remote git-islands-ref-head))
                   (local "feature/x" (git-islands-ref-local))
                   (remote "upstream/dev" (git-islands-ref-remote))
                   (tag "v1, v2" (git-islands-ref-tag)))))
  (should (equal (git-islands-log-refs-parse '("HEAD" "refs/heads/main"))
                 '((head "HEAD" (git-islands-ref-head)) (local "main" (git-islands-ref-local)))))
  ;; In a row, tags show only their icon; in full their names too.
  (let ((row (git-islands-log-ref-labels '("refs/heads/main" "tag: refs/tags/v1")))
        (full (git-islands-log-ref-labels '("refs/heads/main" "tag: refs/tags/v1") t)))
    (should (string-match-p "main" row))
    (should-not (string-match-p "v1" (substring-no-properties row)))
    (should (string-match-p "v1" (substring-no-properties full))))
  ;; Past the limit, branches are counted.
  (let ((git-islands-log-ref-limit 1))
    (should (string-match-p "+1" (git-islands-log-ref-labels '("refs/heads/a" "refs/heads/b")))))
  (should (string-prefix-p "Today " (git-islands-log-date (float-time))))
  (should (string-prefix-p "Yesterday " (git-islands-log-date (- (float-time) 86400))))
  (should (equal (git-islands-log-date 0) (format-time-string "%Y/%m/%d %H:%M" 0))))

(ert-deftest git-islands-log-args-follow-filters ()
  (with-temp-buffer
    (setq git-islands-log-filters '(:branch "dev" :user "Ada" :path "src"))
    (let ((args (git-islands-log-args 1000)))
      (should (member "--author=Ada" args))
      (should (equal (last args 3) '("dev" "--" "src")))
      (should (member "--parents" args))
      (should (equal (cadr (member "--skip" args)) "1000")))
    (should-not (git-islands-log-graph-p))
    (setq git-islands-log-filters nil)
    (should (equal (last (git-islands-log-args 0) 4) '("--branches" "--remotes" "--tags" "HEAD")))
    (should (git-islands-log-graph-p))))

(defun git-islands-test-log-wait ()
  "Wait for the current log buffer to finish reading."
  (with-timeout (15 (error "Log timed out"))
    (while git-islands-log-process (accept-process-output nil 0.05))))

(ert-deftest git-islands-log-lists-and-filters-commits ()
  (git-islands-test-with-repo
    (git-islands-test-git "checkout" "-q" "-b" "side")
    (git-islands-test-write "side.txt" "s\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Side work")
    (git-islands-test-git "checkout" "-q" "main")
    (git-islands-test-write "README" "main change\n")
    (git-islands-test-git "commit" "-q" "-am" "Main work")
    (git-islands-test-git "merge" "-q" "--no-edit" "--no-ff" "side")
    ;; The test's environment sets the author, so name another explicitly.
    (git-islands-test-git "commit" "-q" "--allow-empty" "-m" "By someone else"
                     "--author=Other Person <other@example.invalid>")
    (with-current-buffer (git-islands-log-buffer root)
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 5))
      (should git-islands-log-done)
      (should (= git-islands-log-columns 2))
      (goto-char (point-min))
      (should (equal (git-islands-commit-subject (git-islands-log-commit)) "By someone else"))
      (should (string-match-p "main" (buffer-substring (pos-bol) (pos-eol))))
      ;; Rows are drawn where they are shown.
      (git-islands-log-fontify (point-min) (point-max))
      ;; An image, or a dot in a frame without images, as in batch runs.
      (should (get-text-property (point-min) 'display))
      ;; The details pane follows the selection.
      (let ((details (git-islands-details-buffer root)))
        (forward-line 4)
        (git-islands-log-after-command)
        (should (equal (git-islands-commit-subject git-islands-log-shown) "Initial"))
        ;; The pane updates once moving stops: run that idle timer now.
        (timer-event-handler git-islands-log-details-timer)
        (with-current-buffer details
          (should (string-match-p "README" (buffer-string)))
          (should (string-match-p "deep.el" (buffer-string)))
          (should (string-match-p "src/a/b" (buffer-string)))))
      ;; Filters.
      (git-islands-log-set-filter :user "Other Person")
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 1))
      (git-islands-log-set-filter :user nil)
      (git-islands-log-set-filter :path "side.txt")
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 1))
      (git-islands-log-clear-filters)
      (git-islands-log-set-filter :text "nothing matches this")
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 0))
      (should (string-match-p "No commits" (buffer-string)))
      (git-islands-log-clear-filters)
      (git-islands-test-log-wait)
      ;; Selecting a commit by hash.
      (let ((hash (git-islands-test-git "rev-parse" "HEAD~1")))
        (goto-char (git-islands-log-position (substring hash 0 7)))
        (should (equal (git-islands-commit-hash (git-islands-log-commit)) hash))))))

(ert-deftest git-islands-log-reads-pages ()
  (git-islands-test-with-repo
    (dotimes (i 7)
      (git-islands-test-git "commit" "-q" "--allow-empty" "-m" (format "Commit %d" i)))
    (with-current-buffer (git-islands-log-buffer root)
      (let ((git-islands-log-page 3))
        (git-islands-log-reload)
        (git-islands-test-log-wait)
        (should (= git-islands-log-count 3))
        (should-not git-islands-log-done)
        (git-islands-log-more)
        (git-islands-test-log-wait)
        (git-islands-log-more)
        (git-islands-test-log-wait)
        (should (= git-islands-log-count 8))
        (should git-islands-log-done)
        ;; One connected line through every page.
        (goto-char (point-max))
        (forward-line -1)
        (should (equal (git-islands-commit-subject (git-islands-log-commit)) "Initial"))
        (should (= (git-islands-graph-row-node (git-islands-commit-row (git-islands-log-commit))) 0))))))

(ert-deftest git-islands-log-selects-several-commits ()
  (git-islands-test-with-repo
    (git-islands-test-write "one.txt" "1\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Add one")
    (git-islands-test-write "two.txt" "2\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Add two")
    (with-current-buffer (git-islands-log-buffer root)
      (git-islands-test-log-wait)
      (goto-char (point-min))
      (setq this-command 'next-line)
      (git-islands-log-after-command)
      ;; Shift-down extends the selection from the row it started on.
      (setq this-command 'git-islands-log-extend-down)
      (git-islands-log-extend-down)
      (git-islands-log-after-command)
      (should (equal (mapcar #'git-islands-commit-subject (git-islands-log-selected))
                     '("Add two" "Add one")))
      (should (= (length git-islands-hl) 2))
      (should (equal (mapcar #'git-islands-commit-subject git-islands-log-shown)
                     '("Add two" "Add one")))
      (with-current-buffer (git-islands-details-buffer root)
        (git-islands-details-render (with-current-buffer (git-islands-log-buffer root) git-islands-log-shown))
        (should (string-match-p "one.txt" (buffer-string)))
        (should (string-match-p "two.txt" (buffer-string)))
        (should (string-match-p "2 commits" (buffer-string))))
      (should (assoc "Compare Versions"
                     (git-islands-log-commits-actions root (git-islands-log-selected))))
      ;; A plain move selects one row again.
      (setq this-command 'next-line)
      (forward-line 1)
      (git-islands-log-after-command)
      (should-not git-islands-log-marked)
      (should (equal (mapcar #'git-islands-commit-subject (git-islands-log-selected)) '("Initial"))))))

(ert-deftest git-islands-commit-files-reads-renames ()
  (git-islands-test-with-repo
    (git-islands-test-git "mv" "README" "README.md")
    (git-islands-test-write "new.el" "n\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Rename")
    (let ((entries (git-islands-commit-files root "HEAD")))
      (should (equal (mapcar #'git-islands-entry-path entries) '("README.md" "new.el")))
      (should (equal (git-islands-entry-orig (car entries)) "README"))
      (should (equal (mapcar #'git-islands-entry-change entries) '(renamed added))))))

(ert-deftest git-islands-log-default-layout-leaves-room-for-author ()
  ;; Include the documented 180-column GUI demo and a smaller frame.
  ;; Reserve room for native scroll bars, fringes and divider rounding.
  (dolist (pixels '(1200 1297 1600 1920))
    (cl-letf (((symbol-function 'frame-pixel-width) (lambda (&optional _) pixels)))
      (let ((table (- pixels 32
                      (git-islands-log-pane-pixels git-islands-log-refs-width)
                      (git-islands-log-pane-pixels git-islands-log-details-width))))
        (should (memq 'author (git-islands-log-columns-shown table))))))
  ;; Existing user widths still take priority, even if they hide the author.
  (let ((git-islands-log-refs-width '(0.15 180 . 400))
        (git-islands-log-details-width '(0.28 280 . 720)))
    (cl-letf (((symbol-function 'frame-pixel-width) (lambda (&optional _) 1297)))
      (should (= (git-islands-log-pane-pixels git-islands-log-refs-width) 195))
      (should (= (git-islands-log-pane-pixels git-islands-log-details-width) 363))))
  (should (equal (git-islands-log-columns-shown 600) '(date)))
  (should-not (git-islands-log-columns-shown 400)))

(ert-deftest git-islands-log-tool-window-layout ()
  (git-islands-test-with-repo
    (delete-other-windows)
    (let ((window (git-islands-log-show root)))
      (should (eq (window-parameter window 'window-side) 'bottom))
      (should (= (length (git-islands-log-windows)) 3))
      (with-current-buffer (git-islands-refs-buffer root)
        (should (string-match-p "All branches" (buffer-string)))
        (goto-char (point-min))
        (search-forward "HEAD (Current")
        (git-islands-refs-filter))
      (with-current-buffer (git-islands-log-buffer root)
        (should (equal (plist-get git-islands-log-filters :branch) "HEAD"))
        (should (string-match-p "Branch: HEAD" (substring-no-properties (git-islands-log-header)))))
      (git-islands-log-hide)
      (should-not (git-islands-log-windows)))))

;;;; Side-by-side diff

(ert-deftest git-islands-diff-line-numbers-restore-settings ()
  (dolist (enabled '(t nil))
    (dolist (value '(nil t relative visual))
      (dolist (local '(nil t))
        (with-temp-buffer
          (let ((git-islands-diff-line-numbers enabled)
                (display-line-numbers value))
            (when local (setq-local display-line-numbers value))
            (let ((was-local (local-variable-p 'display-line-numbers)))
              (git-islands-diff-mode 1)
              (should (eq display-line-numbers (if enabled (or value t) value)))
              ;; Repeated activation must not overwrite the saved state.
              (git-islands-diff-mode 1)
              (git-islands-diff-mode -1)
              (should (eq display-line-numbers value))
              (should (eq (local-variable-p 'display-line-numbers) was-local)))))))))

(ert-deftest git-islands-diff-parses-and-maps-lines ()
  (let ((hunks (git-islands-diff-parse (concat "@@ -2 +2 @@\n-b\n+B\n"
                                          "@@ -4,0 +5,2 @@\n+x\n+y\n"
                                          "@@ -7,2 +8,0 @@\n-g\n-h\n"))))
    (should (equal (mapcar #'git-islands-hunk-kind hunks) '(modified added deleted)))
    (should (equal (mapcar #'git-islands-hunk-right-count hunks) '(1 2 0)))
    ;; Left line 1 is before every change; line 5 is after the insertion.
    (should (= (git-islands-diff-map-line hunks 1 t) 1))
    (should (= (git-islands-diff-map-line hunks 2 t) 2))
    (should (= (git-islands-diff-map-line hunks 5 t) 7))
    (should (= (git-islands-diff-map-line hunks 9 t) 9))
    ;; The right side's inserted lines face the line after the insertion point.
    (should (= (git-islands-diff-map-line hunks 6 nil) 5))
    (should (= (git-islands-diff-map-line hunks 7 nil) 5))))

(ert-deftest git-islands-diff-compares-buffers ()
  (with-temp-buffer
    (insert "a\nb\nc\nd\n")
    (let ((left (current-buffer)))
      (with-temp-buffer
        (insert "a\nB\nc\nd\ne\n")
        (let ((hunks (git-islands-diff-texts left (current-buffer))))
          (should (= (length hunks) 2))
          (should (equal (mapcar #'git-islands-hunk-kind hunks) '(modified added))))))))

(ert-deftest git-islands-diff-shows-reverts-and-stages ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "hello\n")
    (git-islands-test-write "code.el" "one\ntwo\nthree\nfour\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Code")
    (git-islands-test-write "code.el" "one\nTWO\nthree\nfour\nfive\nsix\n")
    (delete-other-windows)
    (let* ((before (length (window-list)))
           (session (git-islands-diff-show root "code.el" :left-rev "HEAD" :left-label "HEAD"))
           (left (git-islands-diff-session-left session))
           (right (git-islands-diff-session-right session)))
      (should (= (length (window-list)) (1+ before)))
      ;; Scrolling one side scrolls the other to the facing line.  Batch
      ;; frames do not redisplay, so call the scroll hook directly.
      (let ((left-window (car (git-islands-diff-session-windows session)))
            (right-window (cadr (git-islands-diff-session-windows session))))
        (with-current-buffer right
          (git-islands-diff-scrolled right-window (git-islands-diff-line-position 6)))
        (with-current-buffer left
          (should (= (line-number-at-pos (window-start left-window)) 5)))
        (with-current-buffer right
          (git-islands-diff-scrolled right-window (git-islands-diff-line-position 2)))
        (with-current-buffer left
          (should (= (line-number-at-pos (window-start left-window)) 2))))
      (should (equal (buffer-file-name right) (expand-file-name "code.el" root)))
      (should (= (length (git-islands-diff-session-hunks session)) 2))
      (with-current-buffer left
        (should display-line-numbers)
        (should buffer-read-only)
        (should (equal (buffer-string) "one\ntwo\nthree\nfour\n"))
        ;; Two filler lines face the right side's two new lines.
        (should (seq-some (lambda (overlay)
                            (equal (substring-no-properties
                                    (or (overlay-get overlay 'before-string) ""))
                                   "\n\n"))
                          (overlays-in (point-min) (point-max))))
        (should (eq (key-binding (kbd "q")) #'git-islands-diff-quit)))
      (with-current-buffer right
        (should display-line-numbers)
        (should (seq-some (lambda (overlay) (eq (overlay-get overlay 'face) 'git-islands-diff-modified))
                          (overlays-in (point-min) (point-max))))
        ;; Changed words are marked inside the modified line.
        (should (seq-some (lambda (overlay) (eq (overlay-get overlay 'face) 'git-islands-diff-word))
                          (overlays-in (point-min) (point-max))))
        ;; Stage the added lines, then revert the modified one.
        (goto-char (git-islands-diff-line-position 5))
        (git-islands-diff-stage-hunk)
        (should (equal (git-islands-test-git "diff" "--cached" "--numstat") "2\t0\tcode.el"))
        (goto-char (git-islands-diff-line-position 2))
        (git-islands-diff-revert-hunk)
        (should (equal (buffer-string) "one\ntwo\nthree\nfour\nfive\nsix\n"))
        (should (= (length (git-islands-diff-session-hunks session)) 1))
        (git-islands-diff-quit)
        (should-not (overlays-in (point-min) (point-max)))
        (should-not git-islands-diff-mode)
        (should-not display-line-numbers))
      (should-not (buffer-live-p left))
      (should (= (length (window-list)) before))
      (kill-buffer right))))

(ert-deftest git-islands-diff-new-and-deleted-files ()
  (git-islands-test-with-repo
    (delete-file (expand-file-name "README" root))
    (let ((session (git-islands-diff-show root "README" :left-rev "HEAD")))
      (should (git-islands-diff-session-owns-right session))
      (should (equal (git-islands-diff-session-right-label session) "Deleted"))
      (should (equal (mapcar #'git-islands-hunk-kind (git-islands-diff-session-hunks session)) '(deleted)))
      (with-current-buffer (git-islands-diff-session-left session) (git-islands-diff-quit)))
    (let ((session (git-islands-diff-show root "src/a/b/deep.el" :left-rev nil)))
      (should (equal (git-islands-diff-session-left-label session) "New file"))
      (should (equal (mapcar #'git-islands-hunk-kind (git-islands-diff-session-hunks session)) '(added)))
      (with-current-buffer (git-islands-diff-session-left session) (git-islands-diff-quit)))))

;;;; Annotate

(ert-deftest git-islands-annotate-parses-porcelain ()
  (let* ((a (make-string 40 ?a)) (z (make-string 40 ?0))
         (lines (git-islands-annotate-parse
                 (concat a " 1 1 2\nauthor Ada\nauthor-time 1700000000\nsummary First\n"
                         "filename f\n\tone\n"
                         a " 2 2\n\ttwo\n"
                         z " 3 3 1\nauthor Not Committed Yet\nauthor-time 1800000000\n"
                         "summary Version of f from f\nfilename f\n\tthree\n"))))
    (should (= (length lines) 3))
    (should (eq (aref lines 0) (aref lines 1)))
    (should (equal (git-islands-blame-author (aref lines 0)) "Ada"))
    (should (equal (git-islands-blame-summary (aref lines 1)) "First"))
    (should (git-islands-annotate-uncommitted-p (aref lines 2)))
    (should (equal (git-islands-annotate-text (aref lines 2)) "Not Committed Yet"))
    (should (string-prefix-p (format-time-string "%Y/%m/%d " 1700000000)
                             (git-islands-annotate-text (aref lines 0))))))

(ert-deftest git-islands-annotate-margins-buffer ()
  (git-islands-test-with-repo
    (git-islands-test-write "code.el" "one\ntwo\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Code")
    (with-current-buffer (find-file-noselect (expand-file-name "code.el" root))
      (goto-char (point-max))
      (insert "three\n")
      (git-islands-annotate)
      (with-timeout (10 (error "Blame timed out"))
        (while (process-live-p git-islands-annotate-process) (accept-process-output nil 0.05)))
      (accept-process-output nil 0.05)
      (should (= left-margin-width git-islands-annotate-width))
      (should (= (length git-islands-annotate-lines) 3))
      (should (equal (git-islands-blame-summary (aref git-islands-annotate-lines 0)) "Code"))
      ;; The unsaved line is annotated as not committed.
      (should (git-islands-annotate-uncommitted-p (aref git-islands-annotate-lines 2)))
      (should (= (length (seq-filter (lambda (o) (overlay-get o 'git-islands-annotate))
                                     (overlays-in (point-min) (point-max))))
                 3))
      (git-islands-annotate)
      (should-not git-islands-annotate-mode)
      (should-not (seq-filter (lambda (o) (overlay-get o 'git-islands-annotate))
                              (overlays-in (point-min) (point-max))))
      (should (eql left-margin-width 0))
      (set-buffer-modified-p nil)
      (kill-buffer))))

;;;; Conflicts

(defun git-islands-test-conflict ()
  "Make the current repository stop in a merge with conflicts."
  (git-islands-test-git "checkout" "-q" "-b" "theirs")
  (git-islands-test-write "README" "theirs\n")
  (git-islands-test-write "gone.txt" "theirs edit\n")
  (git-islands-test-git "add" ".")
  (git-islands-test-git "commit" "-q" "-m" "Theirs")
  (git-islands-test-git "checkout" "-q" "main")
  (git-islands-test-write "README" "ours\n")
  (git-islands-test-git "add" ".")
  (git-islands-test-git "commit" "-q" "-m" "Ours")
  (with-temp-buffer
    (call-process "git" nil t nil "merge" "theirs")))

(ert-deftest git-islands-conflicts-resolve-merge ()
  (git-islands-test-with-repo
    (git-islands-test-conflict)
    (let ((status (git-islands-test-fetch root)))
      (should (eq (git-islands-status-state status) 'merge))
      (should (equal (mapcar #'git-islands-entry-path (git-islands-conflict-entries root)) '("README"))))
    (with-current-buffer (git-islands-conflicts-buffer root)
      (git-islands-conflicts-render)
      (should (string-match-p "Merging: 1 file in conflict" (buffer-string)))
      (should (string-match-p "Yours: Modified   Theirs: Modified" (buffer-string)))
      (should (string-match-p "Accept Theirs" (substring-no-properties (git-islands-conflicts-header))))
      (goto-char (point-min))
      (search-forward "README")
      (git-islands-conflicts-accept-theirs)
      (git-islands-test-fetch root)
      (should (string-match-p "All conflicts are resolved" (buffer-string)))
      (should (string-match-p "Commit" (buffer-string))))
    (with-temp-buffer
      (insert-file-contents (expand-file-name "README" root))
      (should (equal (buffer-string) "theirs\n")))
    (should (equal (git-islands-test-git "diff" "--cached" "--name-only") "README\ngone.txt"))))

(ert-deftest git-islands-conflicts-open-after-failed-merge ()
  (git-islands-test-with-repo
    (git-islands-test-git "checkout" "-q" "-b" "theirs")
    (git-islands-test-write "README" "theirs\n")
    (git-islands-test-git "commit" "-q" "-am" "Theirs")
    (git-islands-test-git "checkout" "-q" "main")
    (git-islands-test-write "README" "ours\n")
    (git-islands-test-git "commit" "-q" "-am" "Ours")
    (let ((branch (seq-find (lambda (b) (equal (git-islands-branch-name b) "theirs"))
                            (git-islands-branches root)))
          shown)
      (cl-letf (((symbol-function 'git-islands-in-editor)
                 (lambda (_function buffer) (setq shown buffer))))
        (git-islands-test-wait-process (git-islands-branch-merge root branch))
        (with-timeout (10 (error "No dialog"))
          (while (not shown) (accept-process-output nil 0.05))))
      (should (with-current-buffer shown (derived-mode-p 'git-islands-conflicts-mode)))
      ;; The Commit panel names the merge and offers to finish it.
      (with-current-buffer (git-islands-commit-buffer root)
        (git-islands-commit-render)
        (should (string-match-p "Merging…" (buffer-string)))
        (should (string-match-p "Abort" (buffer-string)))
        (should (string-match-p "Merge Conflicts" (buffer-string)))))))

;;;; Changelists

(ert-deftest git-islands-changelists-group-move-and-persist ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "changed\n")
    (git-islands-test-write "src/a/b/deep.el" "changed\n")
    (let* ((entries (git-islands-status-entries (git-islands-test-fetch root)))
           (names (lambda () (mapcar (lambda (group) (cons (car group)
                                                           (mapcar #'git-islands-entry-path (cdr group))))
                                     (git-islands-changelists-group root entries)))))
      (should (equal (funcall names) '(("Changes" "README" "src/a/b/deep.el"))))
      (git-islands-changelist-move root '("README") "Docs")
      (should (equal (funcall names) '(("Changes" "src/a/b/deep.el") ("Docs" "README"))))
      ;; Kept in the Git directory across sessions.
      (clrhash git-islands-changelists-cache)
      (should (equal (funcall names) '(("Changes" "src/a/b/deep.el") ("Docs" "README"))))
      ;; New changes land in the active list.
      (git-islands-changelist-set-active root "Docs" entries)
      (git-islands-test-write "new.el" "n\n")
      (git-islands-test-git "add" "new.el")
      (let ((entries (git-islands-status-entries (git-islands-test-fetch root))))
        (should (equal (cdr (assoc "Docs" (mapcar (lambda (group)
                                                     (cons (car group)
                                                           (mapcar #'git-islands-entry-path (cdr group))))
                                                   (git-islands-changelists-group root entries))))
                       '("README" "new.el"))))
      (git-islands-changelist-rename root "Docs" "Documentation")
      (should (equal (git-islands-changelists-active (git-islands-changelists root)) "Documentation"))
      (should-error (git-islands-changelist-delete root "Documentation") :type 'user-error)
      (git-islands-changelist-set-active root "Changes" entries)
      (git-islands-changelist-delete root "Documentation")
      (should (equal (git-islands-changelists-names (git-islands-changelists root)) '("Changes")))
      ;; A file committed since is forgotten.
      (git-islands-changelist-move root '("src/a/b/deep.el") "Later")
      (git-islands-test-git "commit" "-q" "-am" "Commit all")
      (git-islands-changelists-group root (git-islands-status-entries (git-islands-test-fetch root)))
      (should-not (git-islands-changelists-files (git-islands-changelists root))))))

(ert-deftest git-islands-commit-panel-shows-changelists ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "changed\n")
    (git-islands-test-write "src/a/b/deep.el" "changed\n")
    (git-islands-test-fetch root)
    (with-current-buffer (git-islands-commit-buffer root)
      (git-islands-commit-render)
      (goto-char (point-min))
      (search-forward "README")
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Docs")))
        (git-islands-commit-move-to-changelist))
      (should (string-match-p "Docs" (buffer-string)))
      (goto-char (point-min))
      (search-forward "README")
      (should (equal (git-islands-commit-changelist-here) "Docs"))
      ;; A changelist's checkbox stages only its files.
      (goto-char (point-min))
      (search-forward "Docs")
      (git-islands-commit-include)
      (git-islands-test-fetch root)
      (should (equal (git-islands-test-git "diff" "--cached" "--name-only") "README")))))

;;;; Three-pane merge

(ert-deftest git-islands-merge3-resolves-conflicts ()
  (git-islands-test-with-repo
    ;; Git joins conflicts a few lines apart, so keep these far enough.
    (git-islands-test-write "code.el" "one\ntwo\n3\n4\n5\n6\n7\n8\nnine\n")
    (git-islands-test-git "add" ".")
    (git-islands-test-git "commit" "-q" "-m" "Code")
    (git-islands-test-git "checkout" "-q" "-b" "theirs")
    (git-islands-test-write "code.el" "one\nTWO theirs\n3\n4\n5\n6\n7\n8\nNINE theirs\n")
    (git-islands-test-git "commit" "-q" "-am" "Theirs")
    (git-islands-test-git "checkout" "-q" "main")
    (git-islands-test-write "code.el" "one\nTWO ours\n3\n4\n5\n6\n7\n8\nNINE ours\n")
    (git-islands-test-git "commit" "-q" "-am" "Ours")
    (with-temp-buffer (call-process "git" nil t nil "merge" "theirs"))
    (git-islands-test-fetch root)
    (delete-other-windows)
    (let* ((merge (git-islands-merge3 root "code.el"))
           (result (git-islands-merge-result merge)))
      (should (= (length (git-islands-merge-windows merge)) 3))
      (with-current-buffer (git-islands-merge-ours merge)
        (should (equal (buffer-string) "one\nTWO ours\n3\n4\n5\n6\n7\n8\nNINE ours\n"))
        (should (= 2 (seq-count (lambda (o) (overlay-get o 'git-islands-merge))
                                (overlays-in (point-min) (point-max))))))
      (with-current-buffer result
        (should (= (length (git-islands-merge-conflicts)) 2))
        (should (string-match-p "2 conflicts left" (substring-no-properties
                                                    (git-islands-merge-header 'result))))
        (goto-char (point-min))
        (git-islands-merge-accept-left)
        (should (= (length (git-islands-merge-conflicts)) 1))
        (goto-char (point-max))
        (git-islands-merge-accept-both)
        (should-not (git-islands-merge-conflicts))
        (should (equal (buffer-string)
                       "one\nTWO ours\n3\n4\n5\n6\n7\n8\nNINE ours\nNINE theirs\n"))
        (git-islands-merge-apply))
      (should-not (buffer-live-p (git-islands-merge-ours merge)))
      (should (= (length (window-list)) 1))
      (should (equal (git-islands-test-git "diff" "--cached" "--name-only") "code.el"))
      (should (equal (git-islands-test-git "status" "--porcelain") "M  code.el"))
      (kill-buffer result))))

;;;; Review fixes

(ert-deftest git-islands-log-reads-each-page-once ()
  (git-islands-test-with-repo
    (dotimes (i 3) (git-islands-test-git "commit" "-q" "--allow-empty" "-m" (format "C%d" i)))
    (with-current-buffer (git-islands-log-buffer root)
      ;; Asking for more while a page is still coming in reads nothing twice.
      (dotimes (_ 20)
        (git-islands-log-more)
        (accept-process-output nil 0.01))
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 4))
      (should (= (count-lines (point-min) (point-max)) 4)))))

(ert-deftest git-islands-rollback-moves-renamed-files-back ()
  (git-islands-test-with-repo
    (git-islands-test-git "mv" "README" "README.md")
    (let ((status (git-islands-test-fetch root))
          (delete-by-moving-to-trash nil))
      (should (eq (git-islands-entry-change (car (git-islands-status-entries status))) 'renamed))
      (git-islands-rollback root (git-islands-status-entries status))
      (should (equal (git-islands-test-git "status" "--porcelain") ""))
      (should (file-exists-p (expand-file-name "README" root)))
      (should-not (file-exists-p (expand-file-name "README.md" root))))))

(ert-deftest git-islands-commit-keeps-hash-lines-and-paragraphs ()
  (git-islands-test-with-repo
    (git-islands-test-write "README" "changed\n")
    (git-islands-test-git "add" ".")
    (let ((done nil))
      (git-islands-commit root "Fix crash\n\n#123 was reported twice.\n\nSecond paragraph." nil
                     (lambda (_) (setq done t)))
      (with-timeout (15 (error "Commit timed out"))
        (while (not done) (accept-process-output nil 0.05))))
    (should (equal (string-trim (git-islands-head-message root))
                   "Fix crash\n\n#123 was reported twice.\n\nSecond paragraph."))))

(ert-deftest git-islands-log-reloads-when-head-moves ()
  (git-islands-test-with-repo
    (with-current-buffer (git-islands-log-buffer root)
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 1))
      (git-islands-test-git "commit" "-q" "--allow-empty" "-m" "Later")
      (git-islands-test-fetch root)
      (git-islands-test-log-wait)
      (should (= git-islands-log-count 2))
      ;; The commit selected before stays selected.
      (should (equal (git-islands-commit-subject (git-islands-log-commit)) "Initial")))))


(ert-deftest git-islands-pane-fit-reaches-sub-character-target ()
  "A pixel target must not be rounded away and retried on every size hook."
  (let* ((window (selected-window))
         (frame (selected-frame))
         (old-width (window-parameter window 'git-islands-pane-width))
         (actual 256) (resizes 0)
         (git-islands-refit-function #'ignore))
    (unwind-protect
        (progn
          (set-window-parameter window 'git-islands-pane-width (lambda () 259))
          (cl-letf (((symbol-function 'window-list) (lambda (&rest _) (list window)))
                    ((symbol-function 'window-pixel-width) (lambda (_) actual))
                    ((symbol-function 'window-resize)
                     (lambda (_ delta &rest _args)
                       (cl-incf resizes)
                       ;; Match Emacs' rounding with an eight-pixel cell.
                       (cl-incf actual (if window-resize-pixelwise delta
                                         (* 8 (round delta 8)))))))
            (git-islands-pane-fit frame)
            (should (= actual 259))
            (git-islands-pane-follow frame)
            (should (= resizes 1))))
      (set-window-parameter window 'git-islands-pane-width old-width))))

(ert-deftest git-islands-pane-fit-skips-zero-delta-resize ()
  "Opening another pane must not resize a pane already at its target."
  (let* ((window (selected-window))
         (old-width (window-parameter window 'git-islands-pane-width))
         (width (window-pixel-width window))
         (resizes 0)
         (git-islands-refit-function #'ignore))
    (unwind-protect
        (progn
          (set-window-parameter window 'git-islands-pane-width (lambda () width))
          (cl-letf (((symbol-function 'window-list) (lambda (&rest _) (list window)))
                    ((symbol-function 'window-resize)
                     (lambda (&rest _) (cl-incf resizes))))
            (git-islands-pane-fit (selected-frame))
            (should (= resizes 0))))
      (set-window-parameter window 'git-islands-pane-width old-width))))

;;; git-islands-tests.el ends here
