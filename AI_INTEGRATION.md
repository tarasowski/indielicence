# AI agent integration playbook

This is the canonical handoff for Codex, Claude Code, Cursor, and other coding
agents asked to integrate IndieLicense into an existing application.

## Copy-paste prompt for the app repository

Open the coding agent in the application that needs licensing and give it this
prompt, replacing the three values:

```text
Integrate IndieLicense into this application:
https://github.com/tarasowski/indielicence

Read IndieLicense's AI_INTEGRATION.md, AGENTS.md, README.md, and SPEC.md before
changing code, then follow the integration playbook exactly.

Product id: PRODUCT_ID
License mode: lifetime | updates | trial
Public key: BASE64_PUBLIC_KEY_FROM_INDIELICENSE_INIT

Inspect this app to select the Swift or JavaScript verifier. Add a license-entry
flow, secure persistence, validation on every launch, an immutable release build
date, correct UI for every validation result, and tests. Do not add a licensing
server, network calls, telemetry, or analytics. Never access or modify .private
or .state files and never commit generated customer keys.
```

If the product has no keypair yet, omit `Public key` and tell the agent to stop
after giving the exact `indielicense init` command. Run that command once, back
up the two generated files, and then give the agent only the printed public key.

## Required agent procedure

### 1. Read and inspect before editing

1. Read this file, `AGENTS.md`, `README.md`, and `SPEC.md` from IndieLicense.
2. Inspect the target app's platform, targets, build system, existing purchase
   or settings UI, app startup path, persistence layer, and test framework.
3. Confirm the product id is lowercase `a-z0-9` and confirm exactly one license
   mode: `lifetime`, `updates`, or `trial`.
4. Determine whether a product keypair already exists. Never search for, open,
   read, print, copy, move, edit, or delete `*.private` or `*.state` files.

### 2. Establish the public key safely

Install the published CLI if needed:

```sh
brew install tarasowski/tap/indielicense
indielicense --version
```

For a new product, choose a directory outside every Git repository and run once:

```sh
indielicense init --product PRODUCT_ID --key-dir ~/Licensing/PRODUCT_ID
```

The human must back up both generated files in encrypted storage. The agent may
use the base64 public key printed by the CLI, but must never handle the contents
of the private key or state file. Never rerun or work around a refused `init`.

### 3. Add the verifier

Choose one supported path:

- Swift/macOS: copy the canonical `Verifier/LicenseVerifier.swift` into the app
  target. This is preferred because it is one auditable file using only Apple
  system frameworks. The SPM library product `IndieLicense` is the alternative.
- Electron/Tauri/Node: copy `Verifier/verify.mjs`. It is dependency-free and
  uses `node:crypto`.

Do not reimplement the wire format or cryptography. Do not weaken or reorder
validation. Do not introduce a network request, server activation, telemetry,
or analytics.

### 4. Wire the complete app flow

The integration is incomplete until all of these exist:

1. Configure the exact public key and product id.
2. Embed an immutable UTC release build date in source or generated build
   settings. Never use `Date()` as the build date, executable modification
   time, filesystem metadata, or another value that changes after signing.
3. Add a license-entry screen that accepts a pasted key and shows useful,
   non-technical errors.
4. On the first successful validation, persist the license and activation
   state securely. Swift integrations use the included Keychain-backed
   `LicenseStore`. JavaScript integrations must persist `activatedAt` and the
   greatest accepted `denylistSequence` and pass both back on later checks.
5. Revalidate the stored license on every app launch before unlocking paid
   features. Storage/configuration failures must fail closed and remain
   distinguishable from an unlicensed user.
6. Handle lifetime, trial expiry, wrong product, malformed key, bad signature,
   revocation, and update-window results. An updates key permanently licenses
   eligible older builds; a build released after its update window must offer
   renewal rather than pretending the customer's old license disappeared.
7. If the product uses revocation, bundle `PRODUCT_ID.denylist.json` as an app
   resource and preserve rollback protection across launches.
8. Treat all license and denylist text as untrusted display data. Never render
   denylist notes as HTML.

### 5. Test and hand off

Add target-app tests covering at least:

- a valid key for the configured product;
- malformed and signature-tampered keys;
- a key for the wrong product;
- trial expiry or update-window boundaries when that mode is used;
- a signed revoked key when a denylist is bundled;
- persistence followed by validation on a later launch;
- storage/configuration failure behavior.

Run the target app's formatter, build, and complete relevant test suite. Report
the files changed, the selected product/mode, how the build date is embedded,
where the license is stored, and any remaining human step. Do not generate a
sales CSV unless explicitly asked, and never revoke a key without an explicit
request naming that key id.

## After app integration

The developer mints sales inventory locally; this is not an app-build step:

```sh
# Choose exactly one mode.
indielicense generate --count 100 --mode lifetime \
  --key-dir ~/Licensing/PRODUCT_ID --out ~/Licensing/PRODUCT_ID/keys.csv

indielicense generate --count 100 --mode updates --updates-duration 365d \
  --key-dir ~/Licensing/PRODUCT_ID --out ~/Licensing/PRODUCT_ID/keys.csv

indielicense generate --count 100 --mode trial --expires 14d \
  --key-dir ~/Licensing/PRODUCT_ID --out ~/Licensing/PRODUCT_ID/keys.csv
```

Upload `keys.csv` to the payment platform so it sends one key per sale. Never
commit or publish the CSV. Customer validation remains fully offline.
