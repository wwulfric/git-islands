# git-islands

English | [简体中文](README.zh-CN.md)

![The Commit tool window, a side-by-side diff and the Git log with its graph, branches and details panes](docs/hero.png)

IntelliJ-style Git tool windows for Emacs, drawn in Emacs and driven by
[Magit](https://magit.vc).

- **Commit tool window**: changed files grouped by changelist and folder.
  A file's checkbox is the index, so checking a file stages it. The
  commit message sits below, with Amend and Commit and Push.
- **Git log**: commits with their graph, filters by branch, user, date,
  path and text, a branches pane and a details pane. Select several
  commits with Shift and Cmd-click to cherry-pick, revert or compare them.
- **Branches popup**: checkout, new branch, update, push, merge and rebase.
- **Diffs and merges**: side-by-side diffs with stage and revert per
  change, and a three-pane merge for conflicts.
- **Annotate**: blame in the margin, linked to the log.

Magit loads only when a tool window first opens or a command changes a
repository.

## Without an Emacs configuration

The title image above uses a personal Emacs configuration. Here is Git Islands
in `emacs -Q`, loading only the package and its dependencies, with default
fonts, faces and toolbar. [Reproduce this demo](docs/screenshots.md).

![Git Islands in emacs -Q: Commit panel, side-by-side diff and Git log](docs/emacs-q.png)

## Requirements

- Emacs 29.1 or later, with SVG support for the graph, checkboxes and pills
- Magit 4.7 or later
- [expui-icons](https://github.com/wwulfric/expui-icons) 0.2 or later

## Install

With `package-vc` (Emacs 29):

```elisp
(package-vc-install "https://github.com/wwulfric/git-islands")
```

Or from a checkout:

```elisp
(add-to-list 'load-path "/path/to/git-islands")
(require 'git-islands)
```

Nothing is bound by default. Bind the commands you want, or the whole
map under a prefix:

```elisp
(keymap-global-set "C-c g" git-islands-command-map)
;; Or as in IntelliJ:
(keymap-global-set "s-0" #'git-islands-commit-toggle)
(keymap-global-set "s-9" #'git-islands-log-toggle)
(keymap-global-set "C-~" #'git-islands-branches-popup)
```

| Key in the map | Command |
|---|---|
| `c` | `git-islands-commit-toggle`: the Commit tool window |
| `k` | `git-islands-message-focus`: write the commit message |
| `l` | `git-islands-log-toggle`: the Git log |
| `f` | `git-islands-log-file`: the history of the current file |
| `b` | `git-islands-branches-popup`: the branches popup |
| `a` | `git-islands-annotate`: annotate the current file |
| `m` | `git-islands-conflicts`: resolve merge conflicts |

## Fitting it into a configuration

The package supplies usable defaults. Git operations do not require a personal
configuration: editor integration goes through the variables below, and styling
uses package faces. Nothing changes the global theme, font or mode line.

### Start with the defaults

After installing the dependencies, a checkout can be used with:

```elisp
(add-to-list 'load-path "/path/to/git-islands")
(require 'git-islands)
(keymap-global-set "C-c g" git-islands-command-map)
```

Visit a file in a Git repository, then use `C-c g c` for Commit or `C-c g l`
for Log. Under `emacs -Q`, installed packages are not activated automatically:
run `(require 'package)` and `(package-initialize)` first, or supply the
explicit dependency load paths in [the bare demo](docs/screenshots.md).

### Width, row height and fonts

Put settings after `(require 'git-islands)`. UI and diff modules load lazily,
so defer their settings until those modules have defined their faces:

```elisp
(setq git-islands-side-window-width 44
      git-islands-message-window-height 8)
(with-eval-after-load 'git-islands-ui
  (setq git-islands-row-height 1.5
        git-islands-header-height 1.8)
  ;; Use the editor's default font in tool panes only.
  (custom-set-faces '(git-islands-ui-font ((t (:inherit default))))))
```

The message pane starts at 8 total lines (including header and mode line),
and can be resized manually. Reopening an already visible pane preserves its
height. Set `git-islands-message-window-height` to `0.3` for the previous
fractional height; new windows use the setting.

Width is in columns; row height is in frame character units and header height
is in font units. The default UI font inherits `variable-pitch`. Use
`git-islands-title` for headings and `git-islands-file-name` for list text.

### Log pane widths

The default branches pane uses 15% of the frame width (180–400 pixels),
and details use 22% (240–600 pixels), leaving more room for commit subjects
and authors. The table shows author and date at 720 pixels or wider, date
only at 460–719 pixels, and neither below that. Narrow frames may still hide
the author; details wrap their text to the available width.

You can drag pane dividers or set explicit widths before opening Log. Each
value is `(FRACTION MIN . MAX)`, in frame-relative fraction and pixels.
Existing custom values keep their meaning and take precedence over the new
defaults. For example, to restore the previous allocation:

```elisp
(with-eval-after-load 'git-islands-log
  (setq git-islands-log-refs-width '(0.15 180 . 400)
        git-islands-log-details-width '(0.28 280 . 720)))
```

### Mode lines

New tool buffers show a short label such as `Git Log · project`, without internal
buffer names or paths. Narrow windows omit the repository name; extremely
narrow windows shorten the title with an ellipsis. Hover over the label for
the full repository directory. This affects only the `default` format. The Commit file list always hides its mode line to join
the message pane; the message pane uses this setting. Diff source buffers keep
their own mode lines.

```elisp
(setq git-islands-mode-line-format 'default) ; Short package default.
;; Alternatives; choose one:
;; (setq git-islands-mode-line-format 'none) ; Hide it.
;; (setq git-islands-mode-line-format nil)   ; Keep the inherited mode line.
;; (setq git-islands-mode-line-format '(" " mode-name)) ; Your own format.
```

Existing custom formats, including `(:eval ...)`, are used unchanged. `nil`
retains its previous meaning. After changing the option, run
`M-: (git-islands-set-mode-line)` in each existing tool buffer, or recreate the
buffers. `nil` leaves the current format untouched; recreate the buffer to
restore its mode's inherited format.

### Diff line numbers

Both diff buffers show absolute source line numbers by default. Alignment
filler rows do not change the source line numbers or file contents. Existing
line number styles (including relative or visual) are preserved; closing Diff
restores settings it changed on the working file buffer. This is buffer-local,
so another window showing the same file also sees the temporary numbers.
Global line number settings, fonts and faces are unchanged.

To keep the previous behavior and use only your own line number settings:

```elisp
(with-eval-after-load 'git-islands-diff
  (setq git-islands-diff-line-numbers nil))
```

Set this before opening Diff. The standard `line-number` and
`line-number-current-line` faces control the appearance.

### Selection and diff colors

Load your theme before these snippets. `custom-set-faces` records user face
specs, which take precedence over theme faces. Use both light and dark clauses
if you switch themes. These examples require no personal faces or functions:

```elisp
(with-eval-after-load 'git-islands-ui
  (custom-set-faces
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
```

File status colors (`git-islands-modified`, `git-islands-added`,
`git-islands-deleted`, `git-islands-untracked`, `git-islands-conflict`) live in
`git-islands-faces.el`. Diff colors live separately in `git-islands-diff.el`,
including `git-islands-diff-modified`, `git-islands-diff-word` and
`git-islands-diff-filler`.

[examples/style.el](examples/style.el) combines these settings into an optional,
standalone file. Load it after your theme with
`(load "/path/to/git-islands/examples/style.el")`. It illustrates package styling;
the title image also uses editor-wide personal styling.

Apply styling before opening panes. Existing text faces can update immediately,
but SVG images, header remappings and row geometry may need rebuilding. Save
any commit message, kill the affected tool buffers and reopen the panes to apply
all changes; toggling visibility alone reuses buffers. This release does not
promise live restyling of every open pane.

### Editor integration callbacks

| Variable | Contract and default |
|---|---|
| `git-islands-header-function` | Receives a header mode line format; returns a mode line format. Defaults to `identity`. Runs in the tool buffer during redisplay; the selected window may differ. Keep it cheap and free of side effects. |
| `git-islands-background-function` | No arguments; returns an Emacs color string or `nil`. Runs in the tool buffer during drawing/setup. Default `nil` uses the default face background. Recreate buffers to update header remappings. |
| `git-islands-with-anchor-function` | Receives `ANCHOR` and `READ`, both zero-argument functions. `ANCHOR` returns frame pixel position `(X Y 0)`, or `nil` if no log window exists; evaluate it when positioning. Call `READ` synchronously in the invoking filter's context, return its result and preserve quit/errors. Default just calls `READ`. |
| `git-islands-fallback-directory-function` | No arguments; returns a directory string or `nil`, in the invoking command's buffer when no repository was found. Default `nil` supplies no fallback. |
| `git-islands-side-window-width` | Positive column count, or a zero-argument function returning one. Default 40. Called during opening/resizing; do not assume a tool buffer is current. Set before opening the pane. |
| `git-islands-side-window-hook` | Zero-argument hook, before displaying Commit windows, after creating their buffers. Runs in the invoking buffer; return values are ignored. Default empty. Can make room by hiding another sidebar. |
| `git-islands-line-end-inset` | Pixels reserved at the right of headers, or a zero-argument function returning them while drawing. Default 0; useful when your editor draws rounded corners. |

Callbacks are optional. For example, these complete implementations preserve
ordinary headers and minibuffer behavior:

```elisp
(setq git-islands-header-function (lambda (format) format)
      git-islands-background-function (lambda () nil)
      git-islands-with-anchor-function
      (lambda (_anchor read) (funcall read)))
```

Header wrappers must preserve the supplied format and its button properties.
Popup adapters should preserve the invoking buffer/window context. These
callbacks are consulted on subsequent calls; they do not rebuild existing
rendered content automatically. See each variable's docstring for details.

`git-islands-status-functions` is a separate functional integration hook, called
with a repository root when its status changes. `git-islands-status` returns the
latest snapshot for a file tree or status bar. Styling does not require this hook.

## Development

```sh
make compile   # byte-compile, warnings as errors
make test      # run the ERT suite
```

The Makefile looks for dependencies under `DEPS`, one directory each:
by default beside this checkout, as when it is a submodule next to
Magit and expui-icons.  Point it elsewhere with, say,
`make test DEPS=~/.emacs.d/elpa`.

## License

Apache License 2.0; see [LICENSE](LICENSE).
