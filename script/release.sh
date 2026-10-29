#!/bin/sh
# Builds the universal app and zips it for a GitHub release: dist/lastdrop.zip.
# Usage: VERSION=0.1.0 ./script/release.sh
set -eu
cd "$(dirname "$0")/.."
UNIVERSAL=1 ./script/build_app.sh
rm -f dist/lastdrop.zip
ditto -c -k --keepParent dist/lastdrop.app dist/lastdrop.zip
echo "Zipped dist/lastdrop.zip"
