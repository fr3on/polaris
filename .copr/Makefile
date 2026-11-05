# Used by COPR (Source type: SCM, "Build SRPM using: make srpm").
# COPR passes outdir and spec. The build environment has make, tar and rpmbuild but no git,
# so the source tarball is made with tar from the checked-out files.
VERSION := $(shell awk '/^Version:/{print $$2}' polaris.spec)

srpm:
	tar --exclude=.git --exclude=out --transform "s,^\.,polaris-$(VERSION)," -czf $(outdir)/polaris-$(VERSION).tar.gz .
	rpmbuild -bs --define "_sourcedir $(outdir)" --define "_srcrpmdir $(outdir)" --define "_builddir $(outdir)/build" polaris.spec
