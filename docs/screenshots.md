# Screenshots

`hero.png` shows Git Islands inside a personal Emacs configuration.
`emacs-q.png` is a real window capture of graphical Emacs 31.1 on macOS,
started with `-Q`: no init file, theme, font changes or Git Islands UI
customization. Only the package and its dependencies are loaded. The
window size is chosen for the screenshot; fonts and native window chrome
can differ between Emacs builds and operating systems.

## Reproduce the bare Emacs demo

From this checkout, with dependencies in sibling directories as in the
Makefile, run:

```sh
emacs -Q -g 180x55 \
  -L . -L ../magit/lisp -L ../transient/lisp -L ../with-editor/lisp \
  -L ../compat -L ../cond-let -L ../dash -L ../llama -L ../expui-icons \
  -l scripts/demo-bare.el
```

Adjust the dependency paths for your installation. On macOS, if launching
the app binary directly does not open a usable window, use
`open -n /Applications/Emacs.app --args` instead of `emacs`, with absolute
paths for each `-L` and `-l` argument.

The script creates a fresh temporary repository with fictional commits,
a merge, staged and unstaged changes, and an untracked file. It opens the
Commit panel, a side-by-side diff and the Git log using the package's
defaults. It does not change this checkout or your Emacs configuration.
The temporary repository path is available in `git-islands-demo-root` and
in `*Messages*`; it can be removed after closing the demo Emacs.

Wait for the log to populate, then capture the Emacs window. The committed
PNG includes the native title bar and toolbar, without the desktop or a
window shadow. No UI elements are redrawn or composited.
