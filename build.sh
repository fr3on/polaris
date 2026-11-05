#!/bin/sh
# Builds the RPM on a Fedora machine with rpm-build installed. Output: ./out/*.rpm
set -e
cd "$(dirname "$0")"
V=$(awk '/^Version:/{print $2}' polaris.spec)
top=$(mktemp -d)
mkdir -p "$top"/SOURCES "$top"/SPECS "$top"/BUILD "$top"/RPMS "$top"/SRPMS out
tar --transform "s,^\.,polaris-$V," -czf "$top/SOURCES/polaris-$V.tar.gz" ./src ./LICENSE ./README.md ./docs
# the spec expects src/ inside the top folder
cp polaris.spec "$top/SPECS/"
rpmbuild --define "_topdir $top" -bb "$top/SPECS/polaris.spec"
cp "$top"/RPMS/*/*.rpm out/
rm -rf "$top"
ls -l out/
