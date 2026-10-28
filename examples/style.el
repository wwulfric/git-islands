;;; style.el --- Optional Git Islands styling -*- lexical-binding: t; -*-

;; Load after your theme.  This example needs only Git Islands and its
;; dependencies; it does not change the global font, theme or mode line.
;; For existing tool buffers, kill and reopen them after loading this file
;; (save any commit message first).  Merely hiding a pane keeps its buffer.

(require 'git-islands)

(setq git-islands-side-window-width 44
      git-islands-mode-line-format 'default)

(with-eval-after-load 'git-islands-ui
  (setq git-islands-row-height 1.5
        git-islands-header-height 1.8)
  (custom-set-faces
   '(git-islands-ui-font ((t (:inherit default))))
   '(git-islands-hl-line
     ((((background dark)) (:background "#30476A"))
      (t (:background "#DCE8FA"))))
   '(git-islands-hl-line-inactive
     ((((background dark)) (:background "#383B40"))
      (t (:background "#ECEEF2"))))))

(with-eval-after-load 'git-islands-diff
  (custom-set-faces
   '(git-islands-diff-added
     ((((background dark)) (:background "#243D2B" :extend t))
      (t (:background "#E3F3E6" :extend t))))
   '(git-islands-diff-deleted
     ((((background dark)) (:background "#492D32" :extend t))
      (t (:background "#F8E4E7" :extend t))))))

(provide 'git-islands-example-style)
;;; style.el ends here
