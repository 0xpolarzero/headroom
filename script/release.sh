#!/bin/sh
# Builds the universal app for a GitHub release: dist/lastdrop.zip and dist/lastdrop.zip.sha256. The app's updater reads
# both, under these names. Refuses to make a release the updater wouldn't install: it needs a real version and the
# certificate from script/make_signing_cert.sh.
# Usage: VERSION=0.2.0 ./script/release.sh
set -eu
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION, like VERSION=0.2.0}"
export VERSION
export SIGN_IDENTITY="${SIGN_IDENTITY:-lastdrop Dev}"
UNIVERSAL=1 ./script/build_app.sh
if ! codesign -dr - dist/lastdrop.app 2>&1 | grep -q "certificate leaf"; then
  echo "dist/lastdrop.app isn't signed with $SIGN_IDENTITY" >&2
  exit 1
fi
rm -f dist/lastdrop.zip dist/lastdrop.zip.sha256
ditto -c -k --keepParent dist/lastdrop.app dist/lastdrop.zip
(cd dist && shasum -a 256 lastdrop.zip > lastdrop.zip.sha256)
echo "Zipped dist/lastdrop.zip"
