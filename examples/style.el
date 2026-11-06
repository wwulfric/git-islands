;;; style.el --- Optional Git Islands styling -*- lexical-binding: t; -*-

;; Load after your theme.  This example needs only Git Islands and its
;; dependencies; it does not change the global font, theme or mode line.
;; For existing tool buffers, kill and reopen them after loading this file
;; (save any commit message first).  Merely hiding a pane keeps its buffer.

(require 'git-islands)

(setq git-islands-side-window-width 44
      git-islands-mode-line-format 'default)

(with-eval-after-load 'tool-islands
  (setq tool-islands-row-height 1.5
        tool-islands-header-height 1.8
        tool-islands-hl-radius 6
        tool-islands-hl-margin 6)
  (custom-set-faces
   '(tool-islands-font ((t (:family "sans-serif"))))
   '(tool-islands-hl-line
     ((((background dark)) (:background "#30476A"))
      (t (:background "#DCE8FA"))))
   '(tool-islands-hl-line-inactive
     ((((background dark)) (:background "#383B40"))
      (t (:background "#ECEEF2"))))))

(with-eval-after-load 'tool-islands
  (setq tool-islands-button-render-function #'tool-islands-button-rounded
        tool-islands-button-radius 6
        tool-islands-button-padding 12)
  (custom-set-faces
   '(tool-islands-button
     ((((background dark)) (:background "#393B40" :foreground "#DFE1E5"))
      (t (:background "#ECEDEF" :foreground "#333333"))))
   '(tool-islands-primary-button
     ((((background dark)) (:background "#3574F0" :foreground "#FFFFFF"))
      (t (:background "#245FA5" :foreground "#FFFFFF"))))))

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
