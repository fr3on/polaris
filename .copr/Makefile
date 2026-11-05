# Used by COPR (Source type: SCM, "Build SRPM using: make srpm").
# COPR passes outdir and spec. Builds the source tarball from git and then the source RPM.
VERSION := $(shell awk '/^Version:/{print $$2}' polaris.spec)

srpm:
	git archive --format=tar.gz --prefix=polaris-$(VERSION)/ -o $(outdir)/polaris-$(VERSION).tar.gz HEAD
	rpmbuild -bs --define "_sourcedir $(outdir)" --define "_srcrpmdir $(outdir)" --define "_builddir $(outdir)/build" polaris.spec
