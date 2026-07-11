# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability involving key
forgery, private-key exposure, identifier reuse, verifier bypass, or release
supply-chain compromise. Use GitHub's private security-advisory reporting for
this repository. Include a minimal reproduction, affected commit/version, and
impact. Never attach a real `.private` file or customer key export.

## Security boundary

IndieLicense protects license authenticity with Ed25519 and performs all
validation offline. It does not attempt to prevent binary patching, key
sharing, deletion of local state by the device owner, or deliberate system
clock rollback. Static denylists affect only app releases that bundle them.

The private signing key and key-id state are the highest-value assets. Keep
their directory outside source repositories, owned by the signing user, with
0700 permissions. Files created by the CLI use 0600 permissions. Back up the
private key and state together using encrypted storage; never inspect or edit
either file manually.

## Release requirements

Release tags must be protected and reviewed. The release workflow requires:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

It performs the complete test suite, verifies deterministic vectors, signs
with Developer ID, submits the binary for Apple notarization, creates a SHA-256
checksum, and publishes GitHub build provenance. GitHub Actions are pinned to
full commit hashes. Repository administrators must enable protected release
tags and immutable releases in GitHub settings; those controls cannot be
declared from repository source.

Consumers should verify the published checksum and provenance before running
the CLI. App developers should prefer the single-file verifier, review it, and
embed an immutable UTC release day in the signed application binary.
