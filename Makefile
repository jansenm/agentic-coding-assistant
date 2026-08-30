# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
# SPDX-License-Identifier: MPL-2.0

THIS_MAKEFILE := $(lastword $(MAKEFILE_LIST))

INSTALL         ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 0755
INSTALL_DATA    ?= $(INSTALL) -m 0644

ifndef DEBUG
.SILENT:
endif

-include Makefile.local


##
## STANDARD TARGETS
## ----------------

## all                 » default target: build the crate
.PHONY: all all-do
all: all-start all-do build all-end
all-do:

## build               » build the crate (debug, includes LSP)
.PHONY: build build-do
build: build-start $(MANPAGES) build-do build-end
build-do:
	@echo "todo"

## test                » run the tests
.PHONY: test test-do
test: test-start build test-do test-end
test-do:
	@echo "todo"

## check               » run the tests (GNU standard alias)
.PHONY: check
check: test

## doc                 » generate API documentation
.PHONY: doc doc-do
doc: doc-start doc-do doc-end
doc-do:
	@cd docs && $(MAKE) -F Makefile build

##
## INSTALLATION
## ------------

## install             » install binaries and man pages
.PHONY: install install-do
install: install-start install-do install-end
install-do:
	@echo "todo"

## uninstall           » remove installed files
.PHONY: uninstall uninstall-do
uninstall: uninstall-start uninstall-do uninstall-end
uninstall-do:
	@echo "todo"

##
## HELPER
## ------

##
## CODE QUALITY
## ------------

## commit              » execute commit checks
.PHONY: commit commit-do
commit: commit-start commit-do commit-end
commit-do:
	@echo "todo"

## format              » format the sources
.PHONY: format format-do
format: format-start format-do format-end
format-do:
	@echo "todo"

## reuse               » run reuse
.PHONY: reuse reuse-do
reuse: reuse-start reuse-do reuse-end
reuse-do:
	reuse lint

##
## CLEANUP
## -------

## clean               » remove build and profile artifacts
.PHONY: clean clean-do
clean: clean-start mostlyclean clean-do clean-end
clean-do:
	@cd docs && $(MAKE) -F Makefile clean

## mostlyclean         » remove build artifacts
.PHONY: mostlyclean mostlyclean-do
mostlyclean: mostlyclean-start mostlyclean-do mostlyclean-end
mostlyclean-do:
	@echo "todo"

## distclean           » remove everything not part of the release
.PHONY: distclean distclean-do
distclean: distclean-start clean distclean-do distclean-end
distclean-do:

## maintainer-clean    » remove everything that can be generated
.PHONY: maintainer-clean maintainer-clean-do
maintainer-clean: maintainer-clean-start distclean  maintainer-clean-do maintainer-clean-end
maintainer-clean-do:

#
# START/DO/END ANNOUNCEMENTS
# --------------------------

.PHONY: %-start
%-start:
	$(info >>>>>> making $*)

.PHONY: %-end
%-end:
	$(info <<<<<< finished $*)

##
## MISCELLANEOUS
## -------------

## help                » show this help message
.PHONY: help
help:
	@sed -n -e "s/^## \?\(.*\)/\1/p" "$(THIS_MAKEFILE)"
	@echo ""
	@echo "VARIABLE VALUE"
	@echo "--------------"
	@echo "INSTALL          = $(INSTALL)"
	@echo "INSTALL_PROGRAM  = $(INSTALL_PROGRAM)"
	@echo "INSTALL_DATA     = $(INSTALL_DATA)"
	@echo "VERSION          = $(VERSION)"

##
## VARIABLES
## ---------

## INSTALL             » install command
## INSTALL_PROGRAM     » install command for executables
## INSTALL_DATA        » install command for data files
## VERSION             » package version (from spec file)
##
## VERBOSE             » print execute commands
