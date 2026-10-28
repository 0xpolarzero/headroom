#!/bin/sh
# Builds the universal app and zips it for a GitHub release: dist/Headroom.zip.
# Usage: VERSION=0.1.0 ./script/release.sh
set -eu
cd "$(dirname "$0")/.."
UNIVERSAL=1 ./script/build_app.sh
rm -f dist/Headroom.zip
ditto -c -k --keepParent dist/Headroom.app dist/Headroom.zip
echo "Zipped dist/Headroom.zip"
