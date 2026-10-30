# Releasing

Push a tag. The `Release` workflow runs the tests, builds a universal, signed app, and publishes `lastdrop.zip` and
`lastdrop.zip.sha256` as a GitHub release. Installed copies find it within the hour.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The tag is the version: `script/build_app.sh` stamps it into the app and into the bundled Claude Code plugin. Claude Code
keeps its own copy of the plugin by version, so the app updates the plugin the first time a new version runs.

## Signing certificate

Run `script/make_signing_cert.sh` once. It makes a self-signed `lastdrop Dev` certificate, imports it into your login
keychain, keeps its `.p12` in `~/.lastdrop-signing`, and sets the repository secrets `SIGNING_CERT_P12` and
`SIGNING_CERT_PASSWORD`.

Back the `.p12` up. The updater installs a release only if it's signed by the same certificate as the running copy, so
with another certificate everyone would have to update by hand once. The workflow fails rather than publish a release
without the certificate.

Local builds use the certificate when it's in your keychain, and ad hoc otherwise. Without `VERSION` a build is
`0.0.0-dev`, which never updates itself.

## Trying an update

```sh
dist/lastdrop.app/Contents/MacOS/lastdrop --update 0.1.0
```

Run it from a signed bundle: it pretends to be 0.1.0, then checks for, downloads and verifies the latest release.
`--install` also swaps it in and opens it. `LASTDROP_UPDATE_FEED` reads a release from a `file://` JSON file shaped like
GitHub's instead; what it points at must still be signed like the running app.
