-include Makefile.local

PYTHON		    ?= python3

SPHINXOPTS      ?=
SPHINXPYTHON    ?= $(VIRTUALENV)/bin/python3
SPHINXBUILD     ?= $(VIRTUALENV)/bin/sphinx-build
SPHINXAUTOBUILD ?= $(VIRTUALENV)/bin/sphinx-autobuild

VIRTUALENV      ?= .venv

SOURCEDIR       := source
BUILDDIR        := build

# Put it first so that "make" without argument is like "make help".
help:
	@$(SPHINXBUILD) -M help "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)

Makefile.local:
	cp Makefile.local.template Makefile.local


$(SPHINXPYTHON):
	@echo "$(VIRTUALENV): setting up the virtual environment"
	$(PYTHON) -m venv $(VIRTUALENV)

$(SPHINXBUILD)::
	@echo "$(VIRTUALENV): installing dependencies"
	$(SPHINXPYTHON) -m pip install -r requirements.txt

.PHONY: help Makefile livehtml

# Live-reload devserver: rebuild and refresh the browser on changes.
livehtml:
	@$(SPHINXAUTOBUILD) "$(SOURCEDIR)" "$(BUILDDIR)/html" $(SPHINXOPTS) $(O)

# Catch-all target: route all unknown targets to Sphinx using the new
# "make mode" option.  $(O) is meant as a shortcut for $(SPHINXOPTS).
%: $(SPHINXBUILD) Makefile
	@$(SPHINXBUILD) -M $@ "$(SOURCEDIR)" "$(BUILDDIR)" $(SPHINXOPTS) $(O)
