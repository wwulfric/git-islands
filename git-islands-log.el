;;; git-islands-log.el --- IntelliJ's Git Log tool window -*- lexical-binding: t; -*-

;; Copyright (C) 2026 haidao
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; The Git tool window along the frame's bottom: branches on the
;; left, the commit table with its graph in the middle and the selected
;; commit's changed files and message on the right.  The header holds
;; IntelliJ's filters: branch, user, date, path and text.
;;
;; Commits are read a page at a time with `git log --date-order' and drawn
;; as they arrive; scrolling near the end reads the next page.  Rows are
;; plain text with their graph image and the fitted subject added only
;; where they are shown, so long histories stay cheap.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'svg)
(require 'jit-lock)
(require 'magit-section)
(require 'git-islands-core)
(require 'git-islands-faces)
(require 'git-islands-tree)
(require 'git-islands-log-graph)
(require 'git-islands-branches)
(require 'git-islands-diff)

(declare-function magit-show-commit "magit-diff" (rev &optional args files module))
(declare-function magit-diff-range "magit-diff" (rev-or-range &optional args files))
(declare-function magit-rebase-interactive "magit-sequence" (commit args))
(declare-function magit-rebase-reword-commit "magit-sequence" (commit args))
(declare-function magit-commit-reword "magit-commit" (&optional args override-date))

;;;; Commits

(cl-defstruct (git-islands-commit (:constructor git-islands-commit-create))
  "A commit as the log lists it."
  hash parents author email time refs subject row)

(defconst git-islands-log-format "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"
  "Fields of a commit, separated by US, each commit ended by RS.")

(defun git-islands-log-parse-record (record)
  "Return the commit RECORD describes, or nil if it is blank."
  (let ((fields (split-string (string-trim-left record "\n") "\x1f")))
    (when (>= (length fields) 7)
      (pcase-let ((`(,hash ,parents ,author ,email ,time ,refs . ,subject) fields))
        (git-islands-commit-create
         :hash hash :parents (split-string parents " " t)
         :author author :email email :time (string-to-number time)
         :refs (unless (string-empty-p refs) (split-string refs ", " t))
         ;; A subject may itself hold a US character.
         :subject (string-join subject "\x1f"))))))

(defun git-islands-log-date (time)
  "Return TIME as IntelliJ's log shows it: Today, Yesterday or the date."
  (let* ((day (lambda (time) (format-time-string "%Y%m%d" time)))
         (now (current-time)))
    (cond ((equal (funcall day time) (funcall day now))
           (format-time-string "Today %H:%M" time))
          ((equal (funcall day time) (funcall day (time-subtract now 86400)))
           (format-time-string "Yesterday %H:%M" time))
          (t (format-time-string "%Y/%m/%d %H:%M" time)))))

;;;; Faces

(defface git-islands-ref-label '((t :inherit git-islands-dim :height 0.9))
  "Names of the branches and tags at a commit: quiet, a size below the subject."
  :group 'git-islands)

(defface git-islands-ref-head
  '((((background dark)) :foreground "#E5A33F") (t :foreground "#B87A00"))
  "Icon of the checked-out branch."
  :group 'git-islands)

(defface git-islands-ref-local
  '((((background dark)) :foreground "#73BD79") (t :foreground "#1F7A35"))
  "Icon of local branches."
  :group 'git-islands)

(defface git-islands-ref-remote
  '((((background dark)) :foreground "#B08FDB") (t :foreground "#7A4FB8"))
  "Icon of remote branches."
  :group 'git-islands)

(defface git-islands-ref-tag
  '((((background dark)) :foreground "#868A91") (t :foreground "#6C707E"))
  "Icon of tags."
  :group 'git-islands)

(defconst git-islands-log-ref-gap 16
  "Pixels between a row's labels and the author's column.")

(defvar git-islands-log-ref-limit 3
  "Most branch labels a row shows; the rest are counted, as +N.")

(defvar git-islands-log-ref-width 32
  "Most characters of a row's branch label; a longer one ends in an ellipsis.")

(defun git-islands-log-refs-parse (refs)
  "Return REFS, full names as `git log --decorate=full' lists them, as labels.
Each label is (KIND TEXT FACES).  KIND is `head', `local', `remote' or
`tag'.  As in IntelliJ, a local branch takes in the remote branches of
its name at the same commit, as \"origin & main\", and FACES color its
icon, the remotes' first; every tag is in one label; remotes' HEAD is
left out."
  (let (head detached locals remotes tags)
    (dolist (ref refs)
      (cond ((string-prefix-p "HEAD -> refs/heads/" ref)
             (setq head (substring ref 19)))
            ((equal ref "HEAD") (setq detached t))
            ((string-prefix-p "tag: refs/tags/" ref) (push (substring ref 15) tags))
            ((string-prefix-p "refs/heads/" ref) (push (substring ref 11) locals))
            ((string-match "\\`refs/remotes/\\([^/]+\\)/\\(.+\\)\\'" ref)
             (unless (equal (match-string 2 ref) "HEAD")
               (push (cons (match-string 2 ref) (match-string 1 ref)) remotes)))))
    (setq remotes (nreverse remotes))
    (append
     (when detached (list (list 'head "HEAD" '(git-islands-ref-head))))
     (mapcar (lambda (local)
               (let ((own (seq-filter (lambda (remote) (equal (car remote) local)) remotes)))
                 (setq remotes (seq-difference remotes own))
                 (list (if (equal local head) 'head 'local)
                       (mapconcat #'identity (append (mapcar #'cdr own) (list local)) " & ")
                       (append (make-list (length own) 'git-islands-ref-remote)
                               (list (if (equal local head) 'git-islands-ref-head
                                       'git-islands-ref-local))))))
             (append (and head (list head)) (nreverse locals)))
     (mapcar (lambda (remote)
               (list 'remote (concat (cdr remote) "/" (car remote)) '(git-islands-ref-remote)))
             remotes)
     (when tags
       (list (list 'tag (string-join (nreverse tags) ", ") '(git-islands-ref-tag)))))))

(defvar git-islands-log-ref-icons (make-hash-table :test #'equal)
  "Label icons by their colors, kind and height.")

(defun git-islands-log-ref-icon (faces tag)
  "Return the label icon in FACES' colors, the last one in front.
TAG punches a hole in it, as in a price tag.
Several colors draw as many labels, each behind the next, as IntelliJ
draws a branch with its remote."
  (let* ((colors (mapcar (lambda (face) (git-islands-face-color face :foreground "#6C707E"))
                         faces))
         (height (min 16 (frame-char-height)))
         (key (list colors tag height)))
    (or (gethash key git-islands-log-ref-icons)
        (puthash
         key
         (let* ((step 4)
                (width (+ 12 (* step (1- (length colors)))))
                (svg (svg-create width height))
                (top (/ (- height 10) 2.0)))
           ;; The back label first, at the right; the front one ends at the left.
           (seq-do-indexed
            (lambda (color index)
              (let ((x (* step (- (length colors) 1 index))))
                (svg-polygon svg (list (cons (+ x 1) (+ top 5)) (cons (+ x 4.5) top)
                                       (cons (+ x 11) top) (cons (+ x 11) (+ top 10))
                                       (cons (+ x 4.5) (+ top 10)))
                             :fill "none" :stroke color :stroke-width 1.2
                             :stroke-linejoin "round")
                (when tag
                  (svg-circle svg (+ x 5.6) (+ top 5) 1 :fill color))))
            colors)
           (svg-image svg :ascent 'center))
         git-islands-log-ref-icons))))

(defun git-islands-log-ref-labels (refs &optional full)
  "Return REFS, as `git log --decorate=full' lists them, as labels to show.
In a row, tags show their icon alone and long or many branches are cut
short; with FULL every name shows in full, as the details pane does."
  (let* ((labels (git-islands-log-refs-parse refs))
         (branches (seq-remove (lambda (label) (eq (car label) 'tag)) labels))
         (tags (seq-filter (lambda (label) (eq (car label) 'tag)) labels))
         (shown (if full branches (seq-take branches git-islands-log-ref-limit)))
         (hidden (- (length branches) (length shown)))
         (gap (git-islands-space 10)))
    (mapconcat
     #'identity
     (append
      (mapcar (pcase-lambda (`(,_ ,text ,faces))
                (propertize
                 (concat (propertize " " 'display (git-islands-log-ref-icon faces nil))
                         (git-islands-space 4)
                         (propertize (if full text
                                       (truncate-string-to-width text git-islands-log-ref-width
                                                                 nil nil "…"))
                                     'face 'git-islands-ref-label))
                 'help-echo text))
              shown)
      (when (> hidden 0)
        (list (propertize (format "+%d" hidden) 'face 'git-islands-ref-label
                          'help-echo (mapconcat #'cadr (nthcdr (length shown) branches) "\n"))))
      (mapcar (pcase-lambda (`(,_ ,text ,faces))
                (concat (propertize " " 'display (git-islands-log-ref-icon faces t)
                                    'help-echo text)
                        (when full
                          (concat (git-islands-space 4)
                                  (propertize text 'face 'git-islands-ref-label)))))
              tags))
     gap)))

;;;; Table buffer

(defvar git-islands-log-page 1000 "Commits read at a time.")
(defvar git-islands-log-author-width 150 "Pixel width of the author column.")
(defvar git-islands-log-date-width 130 "Pixel width of the date column.")

(defvar-local git-islands-log-root nil "Repository the log lists.")
(defvar-local git-islands-log-filters nil
  "The log's filters, a plist of :branch, :user, :since, :path and :text.")
(defvar-local git-islands-log-graph nil "Lanes after the commits listed so far.")
(defvar-local git-islands-log-count 0 "Commits listed so far.")
(defvar-local git-islands-log-columns 1 "Lanes the graph column is wide.")
(defvar-local git-islands-log-process nil
  "Process reading the next page, until its sentinel has run, or nil.
A process can exit before Emacs has read all its output, so whether it
is live does not tell whether the page is in.")
(defvar-local git-islands-log-partial "" "Output of the last record not read whole.")
(defvar-local git-islands-log-done nil "Non-nil once every commit is listed.")
(defvar-local git-islands-log-head nil "The checked-out commit.")
(defvar-local git-islands-log-select nil "Commit to select once it is listed.")
(defvar-local git-islands-log-shown nil
  "Commit the details pane shows, or the list of commits when several.")
(defvar-local git-islands-log-marked nil
  "Hashes of the selected commits when several are, or nil.
Nil selects the commit at point alone.")
(defvar-local git-islands-log-anchor nil "Hash a range selection extends from.")
(defvar-local git-islands-log-row nil "Start of the row at point after the last command.")
(defvar-local git-islands-log-details-timer nil "Pending update of the details pane.")
(defvar-local git-islands-log-generation 0
  "Bumped by every reload, so output of an older process is ignored.")

(defvar git-islands-log-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'git-islands-log-show-commit)
    (define-key map (kbd "<double-mouse-1>") #'git-islands-log-show-commit)
    (define-key map (kbd "<mouse-3>") #'git-islands-log-actions-menu)
    (define-key map (kbd "S-<down>") #'git-islands-log-extend-down)
    (define-key map (kbd "S-<up>") #'git-islands-log-extend-up)
    ;; Not the default font menu or region: the release selects.
    (define-key map (kbd "s-<down-mouse-1>") #'ignore)
    (define-key map (kbd "S-<down-mouse-1>") #'ignore)
    (define-key map (kbd "s-<mouse-1>") #'git-islands-log-mouse-toggle)
    (define-key map (kbd "S-<mouse-1>") #'git-islands-log-mouse-extend)
    (define-key map (kbd "x") #'git-islands-log-actions)
    (define-key map (kbd "w") #'git-islands-log-copy-hash)
    (define-key map (kbd "b") #'git-islands-log-filter-branch)
    (define-key map (kbd "u") #'git-islands-log-filter-user)
    (define-key map (kbd "d") #'git-islands-log-filter-date)
    (define-key map (kbd "P") #'git-islands-log-filter-path)
    (define-key map (kbd "/") #'git-islands-log-filter-text)
    (define-key map (kbd "C") #'git-islands-log-clear-filters)
    (define-key map (kbd "g") #'git-islands-log-reload)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "TAB") #'git-islands-log-focus-details)
    (define-key map (kbd "q") #'git-islands-log-hide)
    map)
  "Keys of the commit table.")

(define-derived-mode git-islands-log-mode special-mode "Git Log"
  "The commits of a repository, with their graph."
  :interactive nil
  (git-islands-view-setup)
  (setq-local buffer-undo-list t
              line-prefix (git-islands-row-prefix 0)
              header-line-format '(:eval (git-islands-tool-header (git-islands-log-header)))
              git-islands-selected-rows-function #'git-islands-log-selected-rows)
  (git-islands-set-mode-line)
  ;; Rows fit their subjects themselves, where they are shown.
  (remove-hook 'window-size-change-functions #'git-islands-fit-rows t)
  (remove-hook 'window-buffer-change-functions #'git-islands-fit-rows t)
  (jit-lock-register #'git-islands-log-fontify)
  (add-hook 'window-size-change-functions #'git-islands-log-resized nil t)
  (add-hook 'window-scroll-functions #'git-islands-log-scrolled nil t)
  (add-hook 'post-command-hook #'git-islands-log-after-command nil t)
  (add-hook 'kill-buffer-hook #'git-islands-log-stop nil t))

(defun git-islands-log-buffer (root)
  "Return the log of ROOT, creating it if needed."
  (let ((name (format " *git log: %s*" (abbreviate-file-name root))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq default-directory root)
          (git-islands-log-mode)
          (setq git-islands-log-root root)
          (git-islands-log-reload)
          (current-buffer)))))

(defun git-islands-log-graph-p ()
  "Return non-nil if the log draws its graph.
Filtering by user or text leaves gaps the graph cannot join."
  (not (or (plist-get git-islands-log-filters :user) (plist-get git-islands-log-filters :text))))

(defun git-islands-log-args (skip)
  "Return the arguments of `git log' reading a page after SKIP commits."
  (let ((filters git-islands-log-filters))
    (append
     ;; By date, as IntelliJ's log, so branches made lately show near the
     ;; top; children still come before their parents.  Full ref names
     ;; tell local branches from remote ones.
     (list "log" "--date-order" "--decorate=full" (concat "--format=" git-islands-log-format)
           "-n" (number-to-string git-islands-log-page) "--skip" (number-to-string skip))
     (when-let* ((user (plist-get filters :user))) (list (concat "--author=" user)))
     (when-let* ((text (plist-get filters :text)))
       (list "--regexp-ignore-case" "--fixed-strings" (concat "--grep=" text)))
     (when-let* ((since (plist-get filters :since))) (list (concat "--since=" since)))
     ;; Rewrite parents through the commits a path leaves out.
     (when (plist-get filters :path) (list "--parents"))
     (if-let* ((branch (plist-get filters :branch)))
         (list branch)
       (list "--branches" "--remotes" "--tags" "HEAD"))
     (when-let* ((path (plist-get filters :path))) (list "--" path)))))

(defun git-islands-log-stop ()
  "Stop reading commits."
  (when (process-live-p git-islands-log-process)
    (set-process-sentinel git-islands-log-process #'ignore)
    (delete-process git-islands-log-process))
  (setq git-islands-log-process nil))

(defun git-islands-log-reload ()
  "Read the commits again from the start, as after a filter changed."
  (interactive)
  (git-islands-log-stop)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (cl-incf git-islands-log-generation)
  (setq git-islands-log-graph (git-islands-graph-create)
        git-islands-log-count 0
        git-islands-log-columns 1
        git-islands-log-partial ""
        git-islands-log-done nil
        git-islands-log-shown nil
        git-islands-log-marked nil
        git-islands-log-anchor nil
        git-islands-log-head (git-islands-head git-islands-log-root))
  (git-islands-log-more))

(defun git-islands-log-more ()
  "Read the next page of commits in the background."
  (unless (or git-islands-log-done git-islands-log-process)
    (let* ((buffer (current-buffer))
           (generation git-islands-log-generation)
           (default-directory git-islands-log-root)
           (start git-islands-log-count))
      (setq git-islands-log-process
            (make-process
             :name "git-islands-log" :noquery t :connection-type 'pipe
             :coding 'utf-8-unix :file-handler t
             :command (apply #'git-islands-command (git-islands-log-args start))
             :filter (lambda (_process output)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (when (= generation git-islands-log-generation)
                             (git-islands-log-receive output)))))
             :sentinel (lambda (process _event)
                         (when (and (memq (process-status process) '(exit signal))
                                    (buffer-live-p buffer))
                           (with-current-buffer buffer
                             (when (= generation git-islands-log-generation)
                               (setq git-islands-log-process nil)
                               (when (< (- git-islands-log-count start) git-islands-log-page)
                                 (setq git-islands-log-done t))
                               (when (zerop git-islands-log-count)
                                 (git-islands-log-insert-empty))
                               (git-islands-log-after-batch))))))))))

(defun git-islands-log-receive (output)
  "List the commits in OUTPUT, keeping a last partial record for later."
  (let* ((records (split-string (concat git-islands-log-partial output) "\x1e"))
         (graph (git-islands-log-graph-p))
         (inhibit-read-only t))
    (setq git-islands-log-partial (car (last records)))
    (save-excursion
      (goto-char (point-max))
      (dolist (record (butlast records))
        (when-let* ((commit (git-islands-log-parse-record record)))
          (when graph
            (let ((row (git-islands-graph-step git-islands-log-graph (git-islands-commit-hash commit)
                                               (git-islands-commit-parents commit))))
              (setf (git-islands-commit-row commit) row)
              (when (> (git-islands-graph-row-width row) git-islands-log-columns)
                (setq git-islands-log-columns (git-islands-graph-row-width row))
                ;; Rows already drawn get the wider column.
                (jit-lock-refontify))))
          (git-islands-log-insert-row commit)
          (cl-incf git-islands-log-count))))
    (git-islands-log-after-batch)))

(defun git-islands-log-insert-row (commit)
  "Insert COMMIT's row at point."
  (let ((start (point)))
    (insert (if (git-islands-commit-row commit) (propertize " " 'git-islands-graph t) "")
            (propertize (git-islands-commit-subject commit) 'git-islands-subject t)
            ;; Branches and tags at the subject column's end, as in IntelliJ:
            ;; a space placed where they start, then the labels.
            (if-let* ((refs (git-islands-commit-refs commit)))
                (concat (propertize " " 'git-islands-refs-align t)
                        (propertize (git-islands-log-ref-labels refs) 'git-islands-refs t))
              "")
            (git-islands-log-column
             'author (+ git-islands-log-author-width git-islands-log-date-width)
             (truncate-string-to-width (git-islands-commit-author commit) 18 nil nil "…"))
            (git-islands-log-column 'date git-islands-log-date-width
                                    (git-islands-log-date (git-islands-commit-time commit)))
            "\n")
    (put-text-property start (point) 'git-islands-commit commit)))

(defun git-islands-log-column (column from-right text)
  "Return TEXT as COLUMN of a row, starting FROM-RIGHT pixels from its end.
A window too narrow for the column hides it; see
`git-islands-log-columns-shown'."
  (let ((align `(space :align-to (- right (,from-right)))))
    (concat (propertize " " 'display align 'git-islands-align align 'git-islands-column column)
            (propertize text 'face 'git-islands-dim 'git-islands-column column))))

(defun git-islands-log-columns-shown (width)
  "Return the columns a table WIDTH pixels wide has room for."
  (cond ((>= width 720) '(author date))
        ((>= width 460) '(date))))

(defun git-islands-log-insert-empty ()
  "Say that no commit matches the filters."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert (propertize "No commits matching filters" 'face 'git-islands-dim) "\n"))))

(defun git-islands-log-after-batch ()
  "Select a commit that has just been listed, and keep the selection drawn."
  (when git-islands-log-select
    (if-let* ((position (git-islands-log-position git-islands-log-select)))
        (progn
          (setq git-islands-log-select nil)
          (goto-char position)
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (set-window-point window position)
            (with-selected-window window (recenter)))
          (git-islands-log-after-command))
      (if git-islands-log-done
          (progn (message "Commit %s is not in the log" git-islands-log-select)
                 (setq git-islands-log-select nil))
        (git-islands-log-more))))
  (unless git-islands-log-shown
    (git-islands-log-after-command)))

(defun git-islands-log-position (hash)
  "Return the position of the row listing the commit HASH starts with."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (not (eobp))
        (let ((commit (get-text-property (point) 'git-islands-commit)))
          (when (and commit (string-prefix-p hash (git-islands-commit-hash commit)))
            (throw 'found (point))))
        (forward-line 1)))))

;;;; Drawing rows where they are shown

(defun git-islands-log-fontify (start end)
  "Add graph images and fit subjects on the rows between START and END."
  (let ((window (get-buffer-window (current-buffer)))
        (height (git-islands-row-pixels))
        (background (git-islands-face-color 'default :background "#FFFFFF"))
        (inhibit-read-only t))
    (with-silent-modifications
      (save-excursion
        (goto-char start)
        (beginning-of-line)
        (while (< (point) end)
          (when-let* ((commit (get-text-property (point) 'git-islands-commit)))
            (let ((line-end (pos-eol)))
              (when-let* ((row (git-islands-commit-row commit)))
                (put-text-property (point) (1+ (point)) 'display
                                   (if (display-images-p)
                                       (git-islands-graph-image
                                        row height git-islands-log-columns background
                                        (equal (git-islands-commit-hash commit) git-islands-log-head))
                                     "•")))
              (when window
                (git-islands-log-fit-subject (point) line-end window))))
          (forward-line 1))))))

(defun git-islands-log-fit-subject (start end window)
  "Show the columns WINDOW has room for on the row from START to END,
and shorten its subject to fit before them."
  (let* ((width (window-body-width window t))
         (shown (git-islands-log-columns-shown width))
         (position start))
    ;; Hide or show the author and date.
    (while (setq position (text-property-not-all position end 'git-islands-column nil))
      (let* ((column (get-text-property position 'git-islands-column))
             (stop (or (next-single-property-change position 'git-islands-column nil end) end)))
        (put-text-property position stop 'invisible (not (memq column shown)))
        (setq position stop)))
    (when-let* ((subject-start (text-property-any start end 'git-islands-subject t)))
      (let* ((subject-end (or (text-property-not-all subject-start end 'git-islands-subject t) end))
             (subject (buffer-substring-no-properties subject-start subject-end))
             (graphp (get-text-property start 'git-islands-graph))
             (graph (if graphp (* git-islands-log-columns git-islands-graph-lane-width) 0))
             (columns (cond ((memq 'author shown) (+ git-islands-log-author-width git-islands-log-date-width))
                            ((memq 'date shown) git-islands-log-date-width)
                            (t 0)))
             (align (text-property-any subject-end end 'git-islands-refs-align t))
             (refs-end (and align (or (next-single-property-change (1+ align) 'git-islands-refs nil end)
                                      end)))
             ;; The labels, measured with their icons and faces, end a gap
             ;; before the author's column, and the subject a gap before them.
             (labels (if align (string-pixel-width (buffer-substring (1+ align) refs-end)
                                                   (current-buffer))
                       0))
             (refs (if align (+ labels git-islands-log-ref-gap) 0))
             (room (- width git-islands-row-inset graph columns refs 16)))
        (when align
          (put-text-property align (1+ align) 'display
                             `(space :align-to (- right (,(+ columns refs))))))
        (remove-text-properties subject-start subject-end '(display nil))
        (when (> (string-pixel-width subject (current-buffer)) room)
          (put-text-property subject-start subject-end 'display
                             (truncate-string-pixelwise subject (max 0 room)
                                                        (current-buffer) "…")))))))

(defun git-islands-log-resized (_window)
  "Fit the subjects again after the window's width changed."
  (jit-lock-refontify))

(defun git-islands-log-scrolled (window _start)
  "Read more commits when WINDOW nears the end of those listed."
  (with-current-buffer (window-buffer window)
    (git-islands-log-maybe-more window)))

(defun git-islands-log-maybe-more (window)
  "Read the next page if WINDOW shows the last few hundred rows."
  (when (and (not git-islands-log-done) (not git-islands-log-process)
             (> (+ (line-number-at-pos (window-end window)) 200) git-islands-log-count))
    (git-islands-log-more)))

;;;; Selection

(defun git-islands-log-commit ()
  "Return the commit on the row at point, or signal an error."
  (or (get-text-property (pos-bol) 'git-islands-commit)
      (user-error "No commit on this row")))

(defvar git-islands-log-selecting-commands
  '(git-islands-log-extend-down git-islands-log-extend-up
                                git-islands-log-mouse-toggle git-islands-log-mouse-extend git-islands-log-actions-menu)
  "Commands that move point without dropping the other selected commits.")

(defun git-islands-log-hash ()
  "Return the hash of the commit on the row at point, or nil."
  (when-let* ((commit (get-text-property (pos-bol) 'git-islands-commit)))
    (git-islands-commit-hash commit)))

(defun git-islands-log-selected-rows ()
  "Return the starts of the selected rows, in order."
  (if (not git-islands-log-marked)
      (list (pos-bol))
    (let ((marked (make-hash-table :test #'equal))
          rows)
      (dolist (hash git-islands-log-marked) (puthash hash t marked))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((commit (get-text-property (point) 'git-islands-commit)))
            (when (and commit (gethash (git-islands-commit-hash commit) marked))
              (push (point) rows)))
          (forward-line 1)))
      (nreverse rows))))

(defun git-islands-log-selected ()
  "Return the selected commits, newest first, or signal an error."
  (or (delq nil (mapcar (lambda (row) (get-text-property row 'git-islands-commit))
                        (git-islands-log-selected-rows)))
      (user-error "No commit on this row")))

(defun git-islands-log-select-range (from)
  "Select the rows from the one listing FROM to the row at point."
  (let ((start (or (git-islands-log-position from) (pos-bol)))
        (end (pos-bol))
        hashes)
    (save-excursion
      (goto-char (min start end))
      (while (<= (point) (max start end))
        (when-let* ((hash (git-islands-log-hash))) (push hash hashes))
        (forward-line 1)))
    (setq git-islands-log-marked (nreverse hashes))))

(defun git-islands-log-extend (lines)
  "Move LINES rows, extending the selection from its anchor."
  (unless git-islands-log-marked
    (setq git-islands-log-anchor (git-islands-log-hash)))
  (forward-line lines)
  (unless (get-text-property (pos-bol) 'git-islands-commit)
    (forward-line (- (cl-signum lines))))
  (when git-islands-log-anchor
    (git-islands-log-select-range git-islands-log-anchor)))

(defun git-islands-log-extend-down ()
  "Add the next row to the selection."
  (interactive)
  (git-islands-log-extend 1))

(defun git-islands-log-extend-up ()
  "Add the previous row to the selection."
  (interactive)
  (git-islands-log-extend -1))

(defun git-islands-log-toggle-mark ()
  "Add the row at point to the selection, or take it out."
  (when-let* ((hash (git-islands-log-hash)))
    (let ((marked (or git-islands-log-marked
                      ;; The row selected so far stays selected.
                      (and git-islands-log-row
                           (when-let* ((commit (get-text-property git-islands-log-row
                                                                  'git-islands-commit)))
                             (list (git-islands-commit-hash commit)))))))
      (setq git-islands-log-marked (if (member hash marked)
                                       (remove hash marked)
                                     (append marked (list hash)))
            git-islands-log-anchor hash)
      ;; Taking out the last row selects the row at point again.
      (unless git-islands-log-marked
        (setq git-islands-log-anchor nil)))))

(defun git-islands-log-mouse-toggle (event)
  "Add the row clicked at EVENT to the selection, or take it out."
  (interactive "e")
  (mouse-set-point event)
  (git-islands-log-toggle-mark))

(defun git-islands-log-mouse-extend (event)
  "Select the rows from the anchor to the one clicked at EVENT."
  (interactive "e")
  (let ((anchor (or (and git-islands-log-marked git-islands-log-anchor)
                    (and git-islands-log-row
                         (when-let* ((commit (get-text-property git-islands-log-row 'git-islands-commit)))
                           (git-islands-commit-hash commit))))))
    (mouse-set-point event)
    (when anchor
      (setq git-islands-log-anchor anchor)
      (git-islands-log-select-range anchor))))

(defun git-islands-log-show-key (shown)
  "Return what tells SHOWN, a commit or a list of them, apart."
  (if (listp shown) (mapcar #'git-islands-commit-hash shown) shown))

(defun git-islands-log-after-command ()
  "Highlight the selected rows and show their commits in the details pane."
  ;; A move to another row selects that row alone, as a click does.
  (unless (or (eql (pos-bol) git-islands-log-row)
              (memq this-command git-islands-log-selecting-commands))
    (setq git-islands-log-marked nil
          git-islands-log-anchor nil))
  (setq git-islands-log-row (pos-bol))
  (git-islands-highlight)
  (when-let* ((window (get-buffer-window (current-buffer))))
    (git-islands-log-maybe-more window))
  (let* ((commits (delq nil (mapcar (lambda (row) (get-text-property row 'git-islands-commit))
                                    (git-islands-log-selected-rows))))
         (shown (if (cdr commits) commits (car commits))))
    (unless (equal (git-islands-log-show-key shown) (git-islands-log-show-key git-islands-log-shown))
      (setq git-islands-log-shown shown)
      ;; Moving quickly through the rows reads only the commit stopped at.
      (when (timerp git-islands-log-details-timer)
        (cancel-timer git-islands-log-details-timer))
      (let ((root git-islands-log-root))
        (setq git-islands-log-details-timer
              (run-with-idle-timer
               0.05 nil
               (lambda ()
                 (when-let* ((details (get-buffer (git-islands-log-details-name root))))
                   (with-current-buffer details
                     (git-islands-details-render shown))))))))))

(defun git-islands-log-on-status (root)
  "Read ROOT's log again once its HEAD moved, keeping the selected commit."
  (when-let* ((status (git-islands-status root)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'git-islands-log-mode) (equal git-islands-log-root root)
                   (not (equal (git-islands-status-head status) git-islands-log-head)))
          (when-let* ((commit (get-text-property (pos-bol) 'git-islands-commit)))
            (setq git-islands-log-select (git-islands-commit-hash commit)))
          (git-islands-log-reload))))))

(add-hook 'git-islands-status-functions #'git-islands-log-on-status)

;;;; Filters


(defvar git-islands-log-filter-open nil
  "Filter whose popup is open, as its chip's label, or nil.")

(defun git-islands-log-chip-anchor (label)
  "Return the frame pixel position under the chip LABEL of the log's header."
  (when-let* ((window (seq-find (lambda (window)
                                  (with-current-buffer (window-buffer window)
                                    (derived-mode-p 'git-islands-log-mode)))
                                (window-list))))
    (let* ((header (with-selected-window window
                     (format-mode-line header-line-format nil window (window-buffer window))))
           (start (or (string-match (concat " " (regexp-quote label) "\\(?:: \\| ▾\\)") header)
                      0))
           (x (with-current-buffer (window-buffer window)
                (string-pixel-width (substring header 0 start) (current-buffer))))
           (edges (window-pixel-edges window)))
      (list (+ (nth 0 edges) x)
            (+ (nth 1 edges) (window-tab-line-height window) (window-header-line-height window))
            0))))

(defmacro git-islands-log-with-chip (label command &rest body)
  "Run BODY, which reads a filter, in a panel dropped down from chip LABEL.
COMMAND is the filter's command.  A filter's popup replaces one already
open, and the open filter's own chip closes it, so popups never stack."
  (declare (indent 2))
  `(let ((command ,command))
     (when (> (minibuffer-depth) 0)
       (let ((same (equal git-islands-log-filter-open ,label))
             (window (selected-window)))
         (unless same
           (run-at-time 0 nil (lambda ()
                                (when (window-live-p window)
                                  (with-selected-window window
                                    (call-interactively command))))))
         (abort-recursive-edit)))
     (let ((git-islands-log-filter-open ,label))
       (funcall git-islands-with-anchor-function
                ;; Asked when the popup shows: the windows move as it opens.
                (lambda () (git-islands-log-chip-anchor ,label))
                (lambda () ,@body)))))

(defun git-islands-log-set-filter (key value)
  "Set filter KEY to VALUE, nil for all, and read the commits again."
  (setq git-islands-log-filters (plist-put git-islands-log-filters key
                                           (unless (and (stringp value) (string-empty-p value))
                                             value)))
  (git-islands-log-reload)
  (force-mode-line-update))

(defun git-islands-log-filter-branch (&optional branch)
  "Show the commits of BRANCH only, or of all branches."
  (interactive)
  (let ((branch (or branch
                    (git-islands-log-with-chip "Branch" #'git-islands-log-filter-branch
                                               (completing-read "Branch (empty for all): "
                                                                (cons "HEAD" (mapcar #'git-islands-branch-name
                                                                                     (git-islands-branches git-islands-log-root)))
                                                                nil nil)))))
    (git-islands-log-set-filter :branch branch)))

(defun git-islands-log-filter-user ()
  "Show the commits of one author only."
  (interactive)
  (let* ((authors (mapcar (lambda (line) (string-trim (replace-regexp-in-string
                                                       "\\`\\s-*[0-9]+\\s-+" "" line)))
                          (git-islands-lines git-islands-log-root "shortlog" "-sne" "--all")))
         (user (git-islands-log-with-chip "User" #'git-islands-log-filter-user
                                          (completing-read "User (empty for all): "
                                                           (cons (string-trim (car (git-islands-lines git-islands-log-root
                                                                                                      "config" "user.name")))
                                                                 authors)))))
    ;; An author is matched by name; shortlog lists "Name <email>".
    (git-islands-log-set-filter :user (replace-regexp-in-string " <.*>\\'" "" user))))

(defun git-islands-log-filter-date ()
  "Show the commits made since a date only."
  (interactive)
  (let ((since (git-islands-log-with-chip "Date" #'git-islands-log-filter-date
                                          (completing-read "Since (empty for all, or a date such as 2026-01-31): "
                                                           '("1 day ago" "1 week ago" "1 month ago" "1 year ago")))))
    (git-islands-log-set-filter :since since)))

(defun git-islands-log-filter-path ()
  "Show the commits changing a file or folder only."
  (interactive)
  (let* ((default-directory git-islands-log-root)
         (path (git-islands-log-with-chip "Paths" #'git-islands-log-filter-path
                                          (read-file-name "Path (empty for all): " git-islands-log-root "" nil))))
    (git-islands-log-set-filter :path (unless (string-empty-p path)
                                        (file-relative-name path git-islands-log-root)))))

(defun git-islands-log-filter-text ()
  "Show the commits whose message contains a text only."
  (interactive)
  (git-islands-log-set-filter :text (git-islands-log-with-chip "Text" #'git-islands-log-filter-text
                                                               (read-string "Text (empty for all): "
                                                                            (plist-get git-islands-log-filters :text)))))

(defun git-islands-log-clear-filters ()
  "Show every commit of every branch again."
  (interactive)
  (setq git-islands-log-filters nil)
  (git-islands-log-reload)
  (force-mode-line-update))

(defun git-islands-log-chip (label value action)
  "Return a filter chip LABEL showing VALUE, running ACTION when clicked.
As in IntelliJ, a chip names its value only once one is set."
  (apply #'git-islands-header-button action (format "Filter by %s" (downcase label))
         (append (if value
                     (list (propertize (concat " " label ": ") 'face 'git-islands-dim)
                           (propertize value 'face 'git-islands-modified))
                   (list (propertize (concat " " label) 'face 'default)))
                 (list (propertize " ▾ " 'face 'git-islands-dim)))))

(defun git-islands-log-header ()
  "Return the table's header: its filters."
  (let ((filters git-islands-log-filters))
    (concat (propertize " " 'face 'header-line 'display (git-islands-header-space 0))
            (propertize " Log " 'face 'git-islands-title)
            (git-islands-log-chip "Branch" (plist-get filters :branch) #'git-islands-log-filter-branch)
            (git-islands-log-chip "User" (plist-get filters :user) #'git-islands-log-filter-user)
            (git-islands-log-chip "Date" (plist-get filters :since) #'git-islands-log-filter-date)
            (git-islands-log-chip "Paths" (plist-get filters :path) #'git-islands-log-filter-path)
            (git-islands-log-chip "Text" (plist-get filters :text) #'git-islands-log-filter-text)
            (when (mode-line-window-selected-p)
              (git-islands-at-right
               (git-islands-toolbar '(("general/refresh" git-islands-log-reload "Refresh (g)")
                                      ("general/close" git-islands-log-clear-filters "Clear Filters (C)")
                                      ("general/hide" git-islands-log-hide "Hide (q)")))
               (git-islands-line-end))))))

;;;; Commands on commits

(defun git-islands-log-show-commit ()
  "Show the selected commits' changes in the editor."
  (interactive)
  (let ((commits (git-islands-log-selected)))
    (if (cdr commits)
        (git-islands-log-show-range git-islands-log-root commits)
      (let ((default-directory git-islands-log-root))
        (git-islands-magit)
        (git-islands-in-editor #'magit-show-commit (git-islands-commit-hash (car commits)))))))

(defun git-islands-log-show-range (root commits)
  "Show the changes of COMMITS of ROOT, newest first, as one diff."
  (let* ((oldest (car (last commits)))
         (newest (git-islands-commit-hash (car commits)))
         (default-directory root))
    (git-islands-magit)
    (git-islands-in-editor #'magit-diff-range
                           (if (git-islands-commit-parents oldest)
                               (concat (git-islands-commit-hash oldest) "^.." newest)
                             ;; From the empty tree, before a root commit.
                             (concat (car (git-islands-lines root "hash-object" "-t" "tree" "/dev/null"))
                                     ".." newest)))))

(defun git-islands-log-copy-hashes (commits)
  "Copy the hashes of COMMITS, newest first."
  (let ((hashes (mapconcat #'git-islands-commit-hash commits " ")))
    (kill-new hashes)
    (message "Copied %s" hashes)))

(defun git-islands-log-copy-hash ()
  "Copy the selected commits' hashes."
  (interactive)
  (git-islands-log-copy-hashes (git-islands-log-selected)))

(defun git-islands-log-run (root args &optional success)
  "Run Git with ARGS in ROOT, then call SUCCESS and read the log again."
  (git-islands-run-then-refresh root args
                                (lambda ()
                                  (when success (funcall success))
                                  (dolist (buffer (buffer-list))
                                    (with-current-buffer buffer
                                      (when (and (derived-mode-p 'git-islands-log-mode)
                                                 (equal git-islands-log-root root))
                                        (git-islands-log-reload)))))))

(defun git-islands-log-commits-actions (root commits)
  "Return what can be done with COMMITS of ROOT, newest first.
Each is (LABEL . FUNCTION); one commit has more, as IntelliJ's log."
  (if (not (cdr commits))
      (git-islands-log-commit-actions root (car commits))
    (let ((hashes (mapcar #'git-islands-commit-hash commits)))
      (delq nil
            `(("Copy Revision Numbers" . ,(lambda () (git-islands-log-copy-hashes commits)))
              ("Show Diff" . ,(lambda () (git-islands-log-show-range root commits)))
              ,(when (= (length commits) 2)
                 `("Compare Versions"
                   . ,(lambda () (let ((default-directory root))
                                   (git-islands-magit)
                                   (git-islands-in-editor
                                    #'magit-diff-range
                                    (concat (cadr hashes) ".." (car hashes)))))))
              ;; The oldest first, so each applies on the one before.
              ("Cherry-Pick" . ,(lambda ()
                                  (git-islands-log-run root (cons "cherry-pick" (reverse hashes)))))
              ("Revert Commits" . ,(lambda ()
                                     (git-islands-log-run root (append '("revert" "--no-edit")
                                                                       hashes))))
              ("Interactively Rebase from Here…"
               . ,(lambda () (let ((default-directory root))
                               (git-islands-magit)
                               (magit-rebase-interactive (concat (car (last hashes)) "^")
                                                         nil)))))))))

(defun git-islands-log-commit-actions (root commit)
  "Return what can be done with COMMIT of ROOT, as (LABEL . FUNCTION)."
  (let* ((hash (git-islands-commit-hash commit))
         (short (substring hash 0 8))
         (head (equal hash (git-islands-head root))))
    (delq nil
          `(("Copy Revision Number" . ,(lambda () (kill-new hash) (message "Copied %s" hash)))
            ("Checkout Revision" . ,(lambda () (git-islands-log-run root (list "checkout" "--detach" hash))))
            ("Show Diff" . ,(lambda () (let ((default-directory root))
                                         (git-islands-magit)
                                         (git-islands-in-editor #'magit-show-commit hash))))
            ("Compare with Local" . ,(lambda () (let ((default-directory root))
                                                  (git-islands-magit)
                                                  (git-islands-in-editor #'magit-diff-range hash))))
            ("Cherry-Pick" . ,(lambda () (git-islands-log-run root (list "cherry-pick" hash))))
            ("Revert Commit" . ,(lambda () (git-islands-log-run root (list "revert" "--no-edit" hash))))
            ,(when head
               `("Undo Commit" . ,(lambda ()
                                    (git-islands-log-run root '("reset" "--soft" "HEAD~1")))))
            ("Reset Current Branch to Here…" . ,(lambda () (git-islands-log-reset root hash)))
            ("Edit Commit Message…" . ,(lambda ()
                                         (let ((default-directory root))
                                           (git-islands-magit)
                                           (if head (magit-commit-reword)
                                             (magit-rebase-reword-commit hash nil)))))
            ("Interactively Rebase from Here…"
             . ,(lambda () (let ((default-directory root))
                             (git-islands-magit)
                             (magit-rebase-interactive (concat hash "^") nil))))
            ("New Branch…" . ,(lambda ()
                                (let ((name (git-islands-read-new-branch
                                             (format "New branch at %s: " short))))
                                  (git-islands-log-run root (list "checkout" "-b" name hash)))))
            ("New Tag…" . ,(lambda ()
                             (let ((name (git-islands-read-new-branch
                                          (format "New tag at %s: " short))))
                               (git-islands-log-run root (list "tag" name hash)))))))))

(defun git-islands-log-reset (root hash)
  "Reset the current branch of ROOT to HASH, asking how."
  (let* ((modes '(("Soft: keep changes staged" . "--soft")
                  ("Mixed: keep changes unstaged" . "--mixed")
                  ("Hard: discard changes" . "--hard")
                  ("Keep: keep local changes" . "--keep")))
         (mode (cdr (assoc (completing-read "Reset mode: " modes nil t nil nil
                                            (caar (cdr modes)))
                           modes))))
    (when (or (not (equal mode "--hard"))
              (yes-or-no-p "Discard every uncommitted change? "))
      (git-islands-log-run root (list "reset" mode hash)))))

(defun git-islands-log-actions ()
  "Choose what to do with the selected commits."
  (interactive)
  (let* ((root git-islands-log-root)
         (commits (git-islands-log-selected))
         (actions (git-islands-log-commits-actions root commits))
         (choice (git-islands-read-candidate
                  (if (cdr commits) (format "%d commits: " (length commits)) "Commit: ")
                  (mapcar (lambda (action)
                            (propertize (car action) 'git-islands-value (cdr action)))
                          actions))))
    (funcall (get-text-property 0 'git-islands-value choice))))

(defun git-islands-log-actions-menu (event)
  "Pop up what can be done with the commits selected, or clicked at EVENT."
  (interactive "e")
  (mouse-set-point event)
  ;; A click outside the selection selects its row alone.
  (unless (member (git-islands-log-hash) git-islands-log-marked)
    (setq git-islands-log-marked nil
          git-islands-log-anchor nil))
  (git-islands-log-after-command)
  (let* ((commits (git-islands-log-selected))
         (actions (git-islands-log-commits-actions git-islands-log-root commits))
         (choice (x-popup-menu event
                               (list (if (cdr commits) "Commits" "Commit")
                                     (cons "" (mapcar (lambda (action)
                                                        (cons (car action) (cdr action)))
                                                      actions))))))
    (when choice (funcall choice))))

;;;; Details pane

(defun git-islands-log-details-name (root)
  "Return the name of ROOT's details pane."
  (format " *git commit details: %s*" (abbreviate-file-name root)))

(defvar-local git-islands-details-root nil)
(defvar-local git-islands-details-commit nil
  "Commit the pane shows, or the list of commits, newest first, when several.")
(defvar-local git-islands-details-width nil "Pane width the message was broken for.")

(defvar git-islands-details-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'git-islands-details-show-file)
    (define-key map (kbd "<double-mouse-1>") #'git-islands-details-show-file)
    (define-key map (kbd "TAB") #'git-islands-details-toggle)
    (define-key map (kbd "o") #'git-islands-details-visit)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'git-islands-log-hide)
    map)
  "Keys of the commit details pane.")

(define-derived-mode git-islands-details-mode magit-section-mode "Commit Details"
  "The changed files and message of the commit selected in the log."
  :interactive nil
  (setq-local magit-section-highlight-current nil
              magit-section-highlight-selection nil
              magit-section-visibility-indicators nil)
  ;; File rows fit; the message is broken into rows as wide as the pane.
  (git-islands-view-setup)
  (add-hook 'window-size-change-functions #'git-islands-details-resized nil t)
  (setq-local header-line-format '(:eval (git-islands-tool-header (git-islands-details-header))))
  (git-islands-set-mode-line))

(defun git-islands-details-buffer (root)
  "Return ROOT's details pane, creating it if needed."
  (let ((name (git-islands-log-details-name root)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq default-directory root)
          (git-islands-details-mode)
          (setq git-islands-details-root root)
          (current-buffer)))))

(defun git-islands-commit-files (root hash)
  "Return the files COMMIT HASH of ROOT changed, as entries.
A merge shows what it changed against its first parent."
  (let ((items (split-string
                (with-temp-buffer
                  (let ((default-directory root)
                        (command (git-islands-command "diff-tree" "--no-commit-id" "-r" "-z" "-M"
                                                      "--name-status" "--root" "-m" "--first-parent"
                                                      hash)))
                    (apply #'process-file (car command) nil t nil (cdr command))
                    (buffer-string)))
                "\0" t))
        entries)
    (while items
      (let* ((status (pop items))
             (letter (aref status 0)))
        (if (memq letter '(?R ?C))
            (let ((orig (pop items)) (path (pop items)))
              (push (git-islands-entry-create :path path :orig orig :index letter
                                              :worktree ?. :kind 'changed)
                    entries))
          (push (git-islands-entry-create :path (pop items) :index letter
                                          :worktree ?. :kind 'changed)
                entries))))
    (nreverse entries)))

(defun git-islands-commits-files (root commits)
  "Return the files COMMITS of ROOT, newest first, changed, as entries.
A file keeps the status its first change gave it, unless it is gone."
  (let ((files (make-hash-table :test #'equal))
        order)
    (dolist (commit (reverse commits))
      (dolist (entry (git-islands-commit-files root (git-islands-commit-hash commit)))
        (let* ((path (git-islands-entry-path entry))
               (first (gethash path files)))
          (unless first (push path order))
          (puthash path
                   (if (and first (not (eq (git-islands-entry-index entry) ?D)))
                       first
                     entry)
                   files))))
    (mapcar (lambda (path) (gethash path files)) (nreverse order))))

(defun git-islands-details-message (commit)
  "Return COMMIT's message, its subject in the titles' weight."
  (let* ((message (string-trim-right
                   (or (git-islands-string git-islands-details-root "log" "-1" "--format=%B"
                                           (git-islands-commit-hash commit))
                       "")))
         ;; The subject is the first paragraph, as Git takes it.
         (end (or (string-search "\n\n" message) (length message))))
    (concat (propertize (substring message 0 end) 'face 'git-islands-group)
            (substring message end))))

(defun git-islands-details-render-several (commits)
  "Show the files COMMITS, newest first, changed, and their subjects."
  (let ((entries (git-islands-commits-files git-islands-details-root commits)))
    (if entries
        (git-islands-tree-insert-entries entries 0 t nil)
      (git-islands-tree-row 0 (propertize "No changed files" 'face 'git-islands-dim))))
  (git-islands-tree-row 0 "")
  (git-islands-tree-row 0 (propertize (format "%d commits" (length commits)) 'face 'git-islands-dim))
  (dolist (commit commits)
    (git-islands-tree-row 0 (propertize (substring (git-islands-commit-hash commit) 0 8)
                                        'face 'git-islands-dim)
                          "  " (git-islands-commit-subject commit))))

(defun git-islands-details-render (commit)
  "Show COMMIT's changed files and message.
COMMIT can be a list of commits, newest first, when several are selected."
  (let ((inhibit-read-only t))
    (setq git-islands-details-commit commit)
    (erase-buffer)
    (setq magit-root-section nil)
    (magit-insert-section (git-islands-details)
                          (cond
                           ((not commit)
                            (git-islands-tree-row 0 (propertize "Select a commit" 'face 'git-islands-dim)))
                           ((consp commit)
                            (git-islands-details-render-several commit))
                           (t
                            ;; The files first, as IntelliJ's details pane; the subject is below.
                            (let ((entries (git-islands-commit-files git-islands-details-root (git-islands-commit-hash commit))))
                              (if entries
                                  (git-islands-tree-insert-entries entries 0 t nil)
                                (git-islands-tree-row 0 (propertize "No changed files" 'face 'git-islands-dim))))
                            (git-islands-tree-row 0 "")
                            (let ((window (get-buffer-window (current-buffer))))
                              (setq git-islands-details-width (and window (window-body-width window t)))
                              (dolist (line (git-islands-wrap (git-islands-details-message commit)
                                                              (- (or git-islands-details-width 320)
                                                                 git-islands-row-inset git-islands-fit-margin)))
                                (git-islands-tree-row 0 line)))
                            (git-islands-tree-row 0 "")
                            ;; One fact a row, so a narrow pane wraps none of them.
                            (git-islands-tree-row 0 (propertize (git-islands-commit-author commit) 'face 'git-islands-dim)
                                                  (propertize (concat "  <" (git-islands-commit-email commit) ">")
                                                              'face 'git-islands-dim))
                            (git-islands-tree-row 0 (propertize (format-time-string "%Y/%m/%d %H:%M"
                                                                                    (git-islands-commit-time commit))
                                                                'face 'git-islands-dim)
                                                  "  "
                                                  (propertize (substring (git-islands-commit-hash commit) 0 8)
                                                              'face 'git-islands-dim))
                            (when (git-islands-commit-refs commit)
                              (git-islands-tree-row 0 (git-islands-log-ref-labels (git-islands-commit-refs commit) t))))))
    (git-islands-tree-draw-chevrons)
    (goto-char (point-min))
    (git-islands-fit-rows)
    (git-islands-highlight)))

(defun git-islands-details-resized (window)
  "Break the message again when WINDOW, showing the pane, changed width."
  (with-current-buffer (window-buffer window)
    (unless (eql (window-body-width window t) git-islands-details-width)
      (git-islands-details-render git-islands-details-commit))))

(defun git-islands-details-header ()
  "Return the details pane's header."
  (concat (propertize " " 'face 'header-line 'display (git-islands-header-space 0))
          (propertize " Changes" 'face 'git-islands-title)
          (when-let* ((commit git-islands-details-commit))
            (propertize (concat "  " (if (consp commit)
                                         (format "%d commits" (length commit))
                                       (substring (git-islands-commit-hash commit) 0 8)))
                        'face 'git-islands-dim))))

(defun git-islands-details-toggle ()
  "Fold or unfold the folder at point."
  (interactive)
  (when-let* ((section (magit-current-section)))
    (when (oref section content)
      (magit-section-toggle section)
      (git-islands-tree-draw-chevron section))))

(defun git-islands-details-show-file ()
  "Show the file at point side by side, before and after the commit."
  (interactive)
  (if-let* ((entry (get-text-property (pos-bol) 'git-islands-entry)))
      (let* ((commits (ensure-list git-islands-details-commit))
             ;; Several commits show their changes together.
             (hash (git-islands-commit-hash (car commits)))
             (parent (car (git-islands-commit-parents (car (last commits))))))
        (git-islands-diff-show git-islands-details-root (git-islands-entry-path entry)
                               :left-rev (and parent
                                              (not (eq (git-islands-entry-change entry) 'added))
                                              parent)
                               :left-path (git-islands-entry-orig entry)
                               :left-label (if parent (substring parent 0 8) "New file")
                               :right-rev (unless (eq (git-islands-entry-change entry) 'deleted) hash)
                               :right-empty (eq (git-islands-entry-change entry) 'deleted)
                               :right-label (if (eq (git-islands-entry-change entry) 'deleted)
                                                "Deleted" (substring hash 0 8))))
    (git-islands-details-toggle)))

(defun git-islands-details-visit ()
  "Open the file at point as it is now."
  (interactive)
  (when-let* ((entry (get-text-property (pos-bol) 'git-islands-entry)))
    (let ((file (expand-file-name (git-islands-entry-path entry) git-islands-details-root)))
      (if (file-exists-p file)
          (git-islands-in-editor #'find-file file)
        (user-error "%s no longer exists" (git-islands-entry-path entry))))))

;;;; Branches pane

(defvar-local git-islands-refs-root nil)

(defvar git-islands-refs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'git-islands-refs-filter)
    (define-key map (kbd "<mouse-1>") #'git-islands-refs-click)
    (define-key map (kbd "TAB") #'git-islands-details-toggle)
    (define-key map (kbd "g") #'git-islands-refs-render)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'git-islands-log-hide)
    map)
  "Keys of the branches pane.")

(define-derived-mode git-islands-refs-mode magit-section-mode "Branches"
  "The branches the log can be filtered to."
  :interactive nil
  (setq-local magit-section-highlight-current nil
              magit-section-highlight-selection nil
              magit-section-visibility-indicators nil)
  (git-islands-view-setup)
  (setq-local header-line-format
              '(:eval (git-islands-tool-header
                       (concat (propertize " " 'face 'header-line
                                           'display (git-islands-header-space 0))
                               (propertize " Branches" 'face 'git-islands-title)))))
  (git-islands-set-mode-line))

(defun git-islands-refs-buffer (root)
  "Return ROOT's branches pane, creating it if needed."
  (let ((name (format " *git branches: %s*" (abbreviate-file-name root))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (setq default-directory root)
          (git-islands-refs-mode)
          (setq git-islands-refs-root root)
          (git-islands-refs-render)
          (current-buffer)))))

(defun git-islands-refs-row (depth label value &optional face icon)
  "Insert a branch row DEPTH deep showing LABEL, filtering the log to VALUE."
  (git-islands-tree-row depth
                        (propertize (concat (when icon (concat (git-islands-icon icon) (git-islands-tree-gap)))
                                            (git-islands-fit (propertize label 'face face)))
                                    'git-islands-ref (or value 'all))))

(defun git-islands-refs-render ()
  "List the repository's branches."
  (interactive)
  (let ((inhibit-read-only t)
        (branches (git-islands-branches git-islands-refs-root)))
    (erase-buffer)
    (setq magit-root-section nil)
    (magit-insert-section (git-islands-refs)
                          (git-islands-refs-row 0 "All branches" nil 'default)
                          (git-islands-refs-row 0 "HEAD (Current Branch)" "HEAD" 'default)
                          (dolist (group `(("Local" . ,(seq-remove #'git-islands-branch-remote branches))
                                           ("Remote" . ,(seq-filter #'git-islands-branch-remote branches))))
                            (when (cdr group)
                              (magit-insert-section (git-islands-group (car group))
                                                    (git-islands-tree-row 0 (propertize (car group) 'face 'git-islands-group))
                                                    (magit-insert-heading)
                                                    (dolist (branch (cdr group))
                                                      (magit-insert-section (git-islands-ref (git-islands-branch-name branch))
                                                                            (git-islands-refs-row 1 (git-islands-branch-name branch) (git-islands-branch-name branch)
                                                                                                  (if (git-islands-branch-current branch) 'git-islands-ref-head 'default))))))))
    (git-islands-tree-draw-chevrons)
    (goto-char (point-min))
    (git-islands-fit-rows)
    (git-islands-highlight)))

(defun git-islands-refs-filter ()
  "Filter the log to the branch at point."
  (interactive)
  (let ((ref (get-text-property (pos-bol) 'git-islands-ref))
        (root git-islands-refs-root))
    (if (not ref)
        (git-islands-details-toggle)
      (with-current-buffer (git-islands-log-buffer root)
        (git-islands-log-set-filter :branch (unless (eq ref 'all) ref))))))

(defun git-islands-refs-click (event)
  "Filter the log to the branch clicked at EVENT."
  (interactive "e")
  (mouse-set-point event)
  (git-islands-highlight)
  (git-islands-refs-filter))

;;;; Tool window

(defun git-islands-log-windows (&optional frame)
  "Return FRAME's windows showing the Git tool window's buffers."
  (seq-filter (lambda (window)
                (with-current-buffer (window-buffer window)
                  (derived-mode-p 'git-islands-log-mode 'git-islands-details-mode 'git-islands-refs-mode)))
              (window-list frame 'no-minibuffer)))

(defun git-islands-log-window (&optional frame)
  "Return FRAME's window showing a commit table, or nil."
  (seq-find (lambda (window)
              (with-current-buffer (window-buffer window) (derived-mode-p 'git-islands-log-mode)))
            (window-list frame 'no-minibuffer)))

(defun git-islands-log-show (root)
  "Show ROOT's Git tool window along the frame's bottom; return the table's window."
  (let* ((log (git-islands-log-buffer root))
         (window (display-buffer-in-side-window
                  log '((side . bottom) (slot . 0) (window-height . 0.38) (dedicated . t)
                        (window-parameters (no-delete-other-windows . t))))))
    (display-buffer-in-side-window
     (git-islands-refs-buffer root)
     `((side . bottom) (slot . -1) (dedicated . t)
       (window-width . ,(max 20 (round 240 (frame-char-width))))
       (window-parameters (no-other-window . t) (no-delete-other-windows . t))))
    (display-buffer-in-side-window
     (git-islands-details-buffer root)
     `((side . bottom) (slot . 1) (dedicated . t)
       (window-width . ,(max 30 (round 320 (frame-char-width))))
       (window-parameters (no-delete-other-windows . t))))
    ;; A pixel of right fringe: without one
    ;; a selected row, which fills the window, would count as cut.
    (dolist (pane (git-islands-log-windows))
      (set-window-fringes pane 0 1))
    (with-current-buffer log
      (setq git-islands-log-shown nil)
      (git-islands-log-after-command))
    window))

(defun git-islands-log-hide (&optional frame)
  "Hide FRAME's Git tool window."
  (interactive)
  (mapc #'delete-window (git-islands-log-windows frame)))

(defun git-islands-log-sync (frame)
  "Close FRAME's branches and details panes once its table is gone."
  (unless (git-islands-log-window frame)
    (mapc #'delete-window (git-islands-log-windows frame))))

;; Also when the table's window is deleted, which changes no window's buffer.
(add-hook 'window-state-change-functions #'git-islands-log-sync)

;;;###autoload
(defun git-islands-log-toggle ()
  "Focus the Git tool window; hide it when already focused."
  (interactive)
  (if-let* ((window (git-islands-log-window)))
      (if (memq (selected-window) (git-islands-log-windows))
          (git-islands-log-hide)
        (select-window window))
    (select-window (git-islands-log-show (git-islands-popup-root)))))

(defun git-islands-log-focus-details ()
  "Move to the details pane."
  (interactive)
  (when-let* ((window (seq-find (lambda (window)
                                  (with-current-buffer (window-buffer window)
                                    (derived-mode-p 'git-islands-details-mode)))
                                (window-list))))
    (select-window window)))

;;;###autoload
(defun git-islands-log-select (root hash)
  "Show ROOT's log with the commit HASH selected."
  (let ((window (git-islands-log-show root)))
    (select-window window)
    (with-current-buffer (window-buffer window)
      (if-let* ((position (git-islands-log-position hash)))
          (progn (goto-char position) (recenter) (git-islands-log-after-command))
        (setq git-islands-log-select hash)
        (when git-islands-log-done
          ;; It may be filtered out: look in every branch.
          (setq git-islands-log-filters nil)
          (git-islands-log-reload))))))

;;;###autoload
(defun git-islands-log-file (&optional file)
  "Show the history of FILE, the current buffer's file by default."
  (interactive)
  (let* ((file (or file buffer-file-name (user-error "Buffer has no file")))
         (root (or (git-islands-root (file-name-directory file))
                   (user-error "Not inside a Git repository")))
         (window (git-islands-log-show root)))
    (select-window window)
    (with-current-buffer (window-buffer window)
      (setq git-islands-log-filters (list :path (file-relative-name file root)))
      (git-islands-log-reload))))

(provide 'git-islands-log)
;;; git-islands-log.el ends here
