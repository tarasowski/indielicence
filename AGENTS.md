# AGENTS.md — instructions for coding agents

You are working with **IndieLicense**: offline Ed25519 license keys for indie
Mac apps. A developer mints keys locally with the `indielicense` CLI, sells
them through a payment platform (MakersDrop, Gumroad, Paddle, Lemon Squeezy),
and their app verifies keys fully offline. There is **no server component and
no network call anywhere** — never add one.

`SPEC.md` is the normative wire-format spec. `README.md` is the human guide.
`AI_INTEGRATION.md` is the canonical cross-agent playbook for integrating this
project into another app. This file tells you, the agent, how to operate safely
and get tasks done.

## Safety rules — hard constraints, no exceptions

1. **Never read, print, log, copy, move, or commit a `*.private` file.** It is
   the developer's signing key. If a task seems to require its *contents*,
   stop and ask the user — only the CLI should ever touch it. (Deriving the
   public key is done via `indielicense` commands, never by reading the file.)
2. **Never delete or edit `*.state` files.** They guarantee key ids are never
   reused. If one looks corrupt, report it — do not "fix" or regenerate it.
3. **Never overwrite an existing keypair.** `indielicense init` refuses by
   design; do not work around that refusal (no `rm`, no `--force` flags, no
   manual file writes). Losing a private key permanently ends key minting for
   shipped app versions.
4. **Never commit generated customer keys** (`keys.csv` or similar exports).
   The `.gitignore` covers the defaults; keep it that way.
5. **No destructive operations without explicit user confirmation in this
   session**: no `git push --force`, no `git reset --hard`, no deleting
   denylists, no `rm -rf` outside temp dirs you created yourself.
6. **Never run `indielicense revoke` unless the user explicitly asked** to
   revoke that specific key id — it changes what shipped apps will accept.
7. **Do not add networking, telemetry, or analytics code** to any target.
   CI greps for networking symbols and will fail.
8. **Do not weaken the crypto or validation order.** Any wire-format change
   requires bumping the version byte and updating `SPEC.md` + both verifiers +
   vectors together. When in doubt, ask.

Run keypairs and demo experiments in a **temp directory** (e.g. `mktemp -d`),
never in the repo working tree.

## Build, test, verify

```sh
swift build                        # debug build
swift Tools/embed-templates.swift  # after changing Verifier/ or Templates/Swift/
swift build -c release --product indielicense   # CLI at .build/release/indielicense
swift test                         # library, CLI, adversarial, concurrency, vectors, file-sync
node --test Tests/verify.test.mjs  # JS verifier plus adversarial regression tests
Examples/demo.sh                   # end-to-end: init → mint → verify → tamper → revoke (in a temp dir)
node Tools/make-vectors.mjs > Tests/vectors.json   # regenerate vectors (deterministic; commit the diff only if the spec changed)
```

Before declaring any change done: `swift test` **and** the node test must
pass, and if you touched `Verifier/LicenseVerifier.swift` you must copy it
byte-identically to `Sources/IndieLicense/LicenseVerifier.swift` (a test
enforces this):

```sh
cp Verifier/LicenseVerifier.swift Sources/IndieLicense/LicenseVerifier.swift
```

If you touched the verifier or any `Templates/Swift/` file, also regenerate
`Sources/CLI/EmbeddedTemplates.swift`; a sync test enforces this so the
standalone Homebrew binary always carries the canonical sources:

```sh
swift Tools/embed-templates.swift
```

## Published CLI distribution

A public, signed, and Apple-notarized universal macOS binary already exists.
Users install the current release from the protected Homebrew tap:

```sh
brew install tarasowski/tap/indielicense
```

Release archives and SHA-256 files are published at
`github.com/tarasowski/indielicence/releases`; the formula lives in
`github.com/tarasowski/homebrew-tap`. `Tools/release.sh <version>` is the only
maintainer release path: it runs tests, builds arm64 + x86_64, signs with the
local Developer ID key, submits to Apple notarization, publishes the GitHub
release, and updates the tap through a pull request. GitHub Actions is CI-only.

Apple credentials must never be added to the repository, `.env` files, or
GitHub secrets. The release script uses the `indielicense-notary` profile in
the maintainer's local macOS Keychain. Before a new release, bump the CLI
version in `Sources/CLI/Commands.swift`, merge to a clean `main`, and run the
script locally.

## Repo map

| path | what it is |
|---|---|
| `Sources/CLI/` | the `indielicense` CLI (only code that touches private keys) |
| `Templates/Swift/` | generalized app-owned Swift scaffolding templates |
| `Tools/embed-templates.swift` | embeds verifier/templates in the standalone CLI binary |
| `Verifier/LicenseVerifier.swift` | **canonical** single-file Swift verifier — the primary integration path |
| `Sources/IndieLicense/LicenseVerifier.swift` | byte-identical copy = the SPM library |
| `Verifier/verify.mjs` | dependency-free JS verifier (Electron/Tauri) |
| `SPEC.md` | normative wire format + validation rules |
| `Tests/vectors.json` | shared test vectors (public test keypair — never reuse it) |
| `Tools/make-vectors.mjs` | independent JS generator for the vectors |

## Task: set up licensing for the user's product

1. Pick a key directory **outside any git repo** (e.g. `~/Licensing/<product>/`).
2. `indielicense init --product <id> --key-dir <dir>` — product id is lowercase
   `a-z0-9`. Relay the backup warning to the user prominently; the printed
   base64 public key is what goes in their app.
3. Mint keys, choosing exactly one mode:
   - `--mode lifetime` — unlocks forever, no windows.
   - `--mode updates --updates-duration 365d` — unlocks forever; only versions
     released within 365 days of the customer's activation are covered.
   - `--mode trial --expires 14d` — app stops working 14 days after activation.
   ```sh
   indielicense generate --count 100 --mode updates --updates-duration 365d \
       --key-dir <dir> --out <dir>/keys.csv
   ```
4. The user uploads `keys.csv` to their payment platform (one key emailed per
   sale). Do not commit or publish the CSV.

## Task: integrate verification into the user's Swift app

1. For a standard Swift app, prefer generating transparent app-owned source:
   ```sh
   indielicense integrate swift --product <id> --public-key <base64> \
       --build-date YYYY-MM-DD --output <app>/License --ui none --denylist none
   ```
   Use `--ui swiftui` only when its neutral UI fits. Inspect the output, add its
   `.swift` files to the app target, and follow its `LICENSE_INTEGRATION.md`.
   The command never overwrites files and requires no runtime SDK. For a custom
   integration, copy `Verifier/LicenseVerifier.swift`; alternatively add the
   package library `IndieLicense`.
2. Wire it up (replace the public key and product id):

```swift
let validator = LicenseValidator(
    publicKey: "BASE64_PUBLIC_KEY_FROM_INIT",
    product: "theirproductid",
    buildDate: Date(timeIntervalSince1970: RELEASE_UNIX_DAY * 86_400),
    denylist: Bundle.main.url(forResource: "theirproductid.denylist", withExtension: "json"))

switch validator.validate(pastedKey) {
case .valid(let info):
    try LicenseStore.shared.save(key: pastedKey) // Keychain, survives reinstalls
    // info.isLifetime, info.effectiveUpdatesUntil, info.effectiveExpiresAt
case .invalid(.updatesExpired(let on)):
    // still licensed for THIS build — show "renew for updates until \(on)", not an error
case .invalid(let reason):
    // .badSignature, .wrongProduct, .expired, .revoked, .malformed…
}
```

3. On every launch, re-validate: `validator.validate((try LicenseStore.shared.load()) ?? "")`.
   The first successful validation stamps the customer's activation date —
   that's what starts trial/update windows.
4. If the user has a denylist, bundle `<product>.denylist.json` as an app
   resource; ship updates to it with each release.

For Electron/Tauri apps use `Verifier/verify.mjs` — it's pure (no storage):
persist `activatedAt` yourself on first valid check and pass the same date on
every later call, along with the parsed denylist JSON if bundled. Also persist
the greatest returned `denylistSequence` and pass it back as
`minimumDenylistSequence`. Embed an immutable release `buildDate`; never use
wall clock or executable modification time.

## Task: handle a refund

Only on explicit user request (rule 6): find the key id (in their sales CSV,
or `indielicense inspect <key>`), then
`indielicense revoke <key_id> --note "refunded" --key-dir <dir>`, and remind
the user to bundle the updated `<product>.denylist.json` into their next
release. `indielicense revoke --list --key-dir <dir>` shows current entries.
## Debugging keys

- `indielicense inspect <key>` — decode a key with no key material (signature NOT checked).
- `indielicense verify <key> --public-key <base64>` — full check, exit 0/1.
- Keys embed durations, never dates: expiry math anchors to the app-side
  activation date, so `verify` on the dev machine can't tell you whether a
  specific customer's window has ended — only the app can.
