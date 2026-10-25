# Dependencies are looked for under DEPS, one directory each: by default
# beside this checkout, as a configuration keeping its packages as
# submodules has them.  With package.el, point DEPS at its elpa directory.
EMACS ?= emacs
DEPS ?= ..
LOAD_PATH = -L . -L test \
	$(foreach dep,magit/lisp transient/lisp with-editor/lisp compat cond-let dash llama expui-icons, \
	  -L $(DEPS)/$(dep))

.PHONY: all test compile clean

all: compile test

test:
	$(EMACS) -Q --batch $(LOAD_PATH) -l test/git-islands-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile git-islands*.el

clean:
	rm -f *.elc test/*.elc
