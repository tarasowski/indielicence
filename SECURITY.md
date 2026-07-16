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
clock rollback. The keyless trial in the generated app scaffolding is a
conversion convenience with the same properties — a device owner who deletes
the license store files can restart it. Static denylists affect only app releases
that bundle them.

The private signing key and key-id state are the highest-value assets. Keep
their directory outside source repositories, owned by the signing user, with
0700 permissions. Files created by the CLI use 0600 permissions. Back up the
private key and state together using encrypted storage; never inspect or edit
either file manually.

## Release requirements

Releases are produced only from a clean local `main` that exactly matches
`origin/main`, using `Tools/release.sh`. The maintainer's Developer ID private
key remains in the local macOS Keychain and is never exported to GitHub.

The release script runs the complete test suite, verifies deterministic
vectors, builds a universal binary, signs it with Developer ID, submits it to
Apple notarization using a local `notarytool` Keychain profile, creates a
SHA-256 checksum, publishes the GitHub release, and updates the protected
Homebrew tap through a pull request. GitHub Actions performs CI only.

Consumers should verify the published checksum and Apple signature before
running the CLI. App developers should prefer the single-file verifier, review
it, and embed an immutable UTC release day in the signed application binary.
