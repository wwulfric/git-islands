# git-islands

English | [简体中文](README.zh-CN.md)

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

## Requirements

- Emacs 29.1 or later, with SVG support for the graph, checkboxes and pills
- Magit 4.7 or later
- [expui-icons](https://github.com/wwulfric/expui-icons) 0.2 or later

## Install

With `package-vc` (Emacs 29), once the repository is published at that address:

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

The tool windows never call into your configuration. They ask for what
belongs to the editor through these variables, whose defaults work in a
bare Emacs:

| Variable | What it decides |
|---|---|
| `git-islands-mode-line-format` | The mode line under each list |
| `git-islands-header-function` | Wraps each header, say in rounded corners |
| `git-islands-background-function` | The color the tool windows are drawn on |
| `git-islands-with-anchor-function` | Where a filter's minibuffer popup drops down from |
| `git-islands-fallback-directory-function` | The project to act on outside any repository |
| `git-islands-side-window-width` | The Commit tool window's width |
| `git-islands-side-window-hook` | Runs before the Commit tool window takes the left side |

They draw with the faces `git-islands-ui-font`, `git-islands-title`,
`git-islands-hl-line` and the others in `git-islands-ui.el`, and the
change colors in `git-islands-faces.el`. Set a face's spec, or make it
inherit one of your own:

```elisp
(face-spec-set 'git-islands-hl-line '((t :inherit my-selection))
               'face-defface-spec)
```

`git-islands-status-functions` runs with a repository's root whenever
its status changes. `git-islands-status` returns the latest snapshot, so
a file tree or a status bar can color files or show the branch from it.

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
