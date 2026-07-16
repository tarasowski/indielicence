# IndieLicense

**Offline license keys for indie Mac apps. No server, ever.**

Generate Ed25519-signed license keys on your own machine, sell them through
MakersDrop / Gumroad / Lemon Squeezy / Paddle / Stripe, and validate them in
your app fully offline — no server, no service, no account, no telemetry, no network calls.
If this repo disappears tomorrow, your keys and your app keep working.

> **Using a coding agent** (Claude Code, Codex, Cursor)? Give it this repository
> and the copy-paste prompt in [`AI_INTEGRATION.md`](AI_INTEGRATION.md). That
> playbook provides the complete app-integration workflow, including a
> licensing interview the agent runs with you (key mode, update window,
> keyless trial days, purchase URL, …) so nothing is guessed on your behalf.
> [`AGENTS.md`](AGENTS.md) contains the mandatory security and repository rules.

## The 5-step workflow

1. **`indielicense init --product pixelpro --key-dir ~/Licensing/pixelpro`** — creates your private
   key-minting key (back it up!) and prints the public key.
2. **Integrate** — generate transparent, app-owned Swift plumbing with one
   command (shown below), or copy [`Verifier/LicenseVerifier.swift`](Verifier/LicenseVerifier.swift)
   manually for a custom integration.
3. **`indielicense generate --count 500 --mode updates --updates-duration 365d --key-dir ~/Licensing/pixelpro`**
   — mints 500 keys into `keys.csv`.
4. **Upload the CSV** to your payment platform. It emails one key per sale —
   you do nothing per sale.
5. **Done.** Customers paste the key into your app; it validates offline,
   instantly, forever.

## How it works

- You hold an **Ed25519 private key** — a key-minting machine only you own.
  It never leaves your machine and is never required by the shipped app.
- Your app embeds the matching **public key** — a key-checking machine that
  can verify keys but never create them. Safe to ship, safe to
  reverse-engineer.
- A **license key** is a small signed payload in a human-pasteable string
  (see [SPEC.md](SPEC.md)). The app checks: signature ✓, product ✓, not
  expired ✓, not revoked ✓. All offline, instant.

## Fast Swift integration — generated source, not an SDK

Generate the standalone verifier, public configuration, Keychain-backed
manager, optional neutral SwiftUI key-entry view + status badge, and a short
handoff guide:

```sh
indielicense integrate swift \
  --product pixelpro \
  --key-dir ~/Licensing/pixelpro \
  --build-date 2026-07-11 \
  --output ./MyApp/License \
  --ui swiftui \
  --denylist bundled \
  --trial 7d \
  --purchase-url https://your.store/pixelpro
```

The generated `.swift` files belong to the app. There is no runtime SDK,
service, telemetry, or network call. Existing files are never overwritten,
and only the public key is embedded — private key material and key-id state
remain in the secure key directory.

Use `--ui none` when the app already has key-entry UI. Use `--denylist none`
when revocation is not being bundled yet. Use `--trial 7d` for a built-in
keyless trial and `--purchase-url` for a "Buy a license" button (both
optional; see below). An agent or CI environment that has only the safe
public key can use `--public-key BASE64 --product pixelpro` instead of
`--key-dir`.

The output contains:

- `LicenseVerifier.swift` — the canonical standalone verifier;
- `LicenseConfig.swift` — public key, product, release build date, denylist,
  optional keyless trial length, optional purchase URL;
- `LicenseManager.swift` — launch validation, secure persistence, app state,
  keyless-trial tracking;
- optional `LicenseActivationView.swift` — neutral key entry with an optional
  "Buy a license" link;
- optional `LicenseBadgeView.swift` — drop-in trial/unlock/renew status badge
  that opens the activation sheet;
- `LICENSE_INTEGRATION.md` — wiring and test checklist.

`LicenseManager` exposes `isLicensed`, `hasFullAccess` (licensed **or** in
keyless trial), and explicit unlicensed, trial, trial-expired, renewal,
invalid, and storage-failure states. The app still owns feature policy,
checkout, pricing, UI copy, and localization.

## Manual integration

```swift
let validator = LicenseValidator(
    publicKey: "PASTE_YOUR_BASE64_PUBLIC_KEY",
    product: "pixelpro",
    // Embed this release date in source/build settings. Never use executable
    // modification time: filesystem metadata is mutable after code signing.
    buildDate: Date(timeIntervalSince1970: 20645 * 86_400), // 2026-07-11 UTC
    denylist: Bundle.main.url(forResource: "pixelpro.denylist", withExtension: "json"))
switch validator.validate(pastedKey) {
case .valid(let info):   unlock(info)      // info.isLifetime, info.effectiveUpdatesUntil, …
case .invalid(.updatesExpired(let on)):    showRenewSheet(updatesEndedOn: on)
case .invalid(let reason):                 showError(reason)
}
```

Store the pasted key with `try LicenseStore.shared.save(key:)` and re-validate
it with `validator.validate((try LicenseStore.shared.load()) ?? "")` on every
launch. Handle thrown storage errors as an integration/storage failure; never
silently start a new activation window.
The **first successful validation stamps the customer's activation date**
(Keychain, survives reinstalls) — that's what starts trial/update windows,
never the day you generated the CSV.

Manual integration paths use the same verifier:

- **Copy-paste:** drop [`Verifier/LicenseVerifier.swift`](Verifier/LicenseVerifier.swift)
  into your project. One auditable file, only Apple system frameworks, no
  dependency to trust or update.
- **SPM:** `.package(url: "https://github.com/tarasowski/indielicence", from: "1.0.0")`,
  library `IndieLicense`. It contains that exact same file (a test keeps the
  two byte-identical).

Electron/Tauri app? Use [`Verifier/verify.mjs`](Verifier/verify.mjs) — a
dependency-free `node:crypto` verifier that passes the same test vectors.
Pass an immutable embedded `buildDate`. Persist the first returned
`info.activatedAt` and greatest `info.denylistSequence`; pass them back on every
later call as `activatedAt` and `minimumDenylistSequence`:

```js
const result = validateLicense(pastedKey, {
  publicKey: "BASE64_PUBLIC_KEY",
  product: "pixelpro",
  buildDate: new Date("2026-07-11T00:00:00Z"), // embedded release constant
  activatedAt: loadActivationDate(),           // null only on genuine first use
  denylist: bundledDenylist,
  minimumDenylistSequence: loadHighestSequence() ?? 0,
});
if (result.valid) {
  if (result.info.activatedAt) persistActivationDate(result.info.activatedAt);
}
const acceptedSequence = result.valid
  ? result.info.denylistSequence
  : result.denylistSequence;
if (acceptedSequence) persistHighestSequence(acceptedSequence);
```

Treat returned note text as display data: use SwiftUI/AppKit text APIs or DOM
`textContent`, never HTML interpolation.

## The three key modes

| mode | flags | what the customer gets |
|---|---|---|
| **lifetime** | `--mode lifetime` | The app unlocks forever. No expiry, no update cutoff, ever. The "$9, yours forever" key. |
| **updates** | `--mode updates --updates-duration 365d` | Unlocks forever, but only versions **released** within 365 days of their activation are covered — after that they keep their current version or buy a renewal key. The Sketch/JetBrains-fallback model; the default choice for "buy once, 12 months of updates included". |
| **trial** | `--mode trial --expires 14d` | The app stops working entirely 14 days after activation. |

### When does the clock start? At activation — never at generation

A common worry with pre-generated keys: "if I mint 500 trial keys today, do
their 14 days start ticking today?" **No.** A key contains no dates at all,
only a duration. The timeline for a `--expires 14d` trial key:

```
you mint the key          customer buys it        customer pastes it        day 14 after
(--mode trial              (key sat unsold         into the app             activation
 --expires 14d)             for 6 months —         ──────────────►          ──────────►
      │                     costs them nothing)    first successful         trial ends
      │                            │               validation stamps        HERE, and
      ▼                            ▼               activatedAt = today      only here
  key stores just "14 days" ─────────────────────► countdown starts NOW
```

- The app stamps `activatedAt` in the Keychain on the **first successful
  validation** and never resets it — relaunching or reinstalling doesn't
  restart a trial (Keychain survives reinstalls).
- `--mode updates` works the same way: the 365-day update window counts from
  each customer's own activation, not from when you generated the batch.
- The `issued_at` column in the CSV is bookkeeping only — it is never used in
  any validation math.

The updates check compares against your app's **build date**, not the wall
clock, so a version a customer already has installed never stops working.

## Keyless trial — try before any key exists

Trial *keys* are for granting a specific person time (press, beta testers,
"extend my trial" support). For the everyday "download and try for 7 days"
flow you don't want keys at all — nobody should have to request one before
deciding they like your app. That's the **keyless trial**, an opt-in feature
of the generated Swift plumbing:

```sh
indielicense integrate swift --product <id> --build-date YYYY-MM-DD \
  --output App/License --trial 7d
```

With `--trial 7d`, an app with no stored license key stamps the trial start
day once in the Keychain on first launch (the same stamp-once anchoring used
for `activatedAt`) and reports `.trial(daysRemaining:expiresOn:)`, then
`.trialExpired(on:)` after the window — same inclusive day math as trial keys.
Activating a purchased key ends the trial. Gate paid features with
`license.hasFullAccess` (licensed **or** in trial) instead of
`license.isLicensed`.

This is purely app-side convenience — no wire-format change, no signature,
nothing minted. Like the rest of the trial machinery it is a conversion tool,
not a security boundary.

### The drop-in badge

With `--ui swiftui` the scaffold also includes `LicenseBadgeView`, a
ready-made status badge for a toolbar or status area:

```swift
.toolbar { LicenseBadgeView(license: license) }
```

It shows "7 days left in trial" (turning urgent in the final 3 days), "Trial
ended", "Unlock", "Renew license", or a failure state — and disappears once
the app is licensed. Clicking it opens the key-entry sheet, which includes a
"Buy a license" button when you pass `--purchase-url https://…` (your
MakersDrop/Gumroad/Paddle/Lemon Squeezy product page). The link is only ever
opened in the customer's browser; the app itself still makes no network calls.

## CLI reference

```
indielicense init --product <id> --key-dir <secure-directory>
                                            create a keypair (refuses to overwrite)
indielicense generate --count <n> --mode <lifetime|updates|trial>
                      [--updates-duration 365d] [--expires 14d] [--out keys.csv]
                      --key-dir <secure-directory>
                                            mint keys; ids continue across batches
indielicense verify <key>                   full validation, exit 0/1
indielicense inspect <key>                  decode a key, no key material needed
indielicense integrate swift --product <id> --build-date YYYY-MM-DD
                     --output <app-source-directory> [--ui none|swiftui]
                     [--denylist none|bundled] [--trial 7d]
                     [--purchase-url <https-link>] [--public-key <base64>]
                                            generate app-owned Swift plumbing
indielicense revoke <key_id> [--note "refunded"] --key-dir <secure-directory>
                                            add to the signed denylist
indielicense revoke --list --key-dir <secure-directory>
                                            show the denylist
```

All commands take `--key-dir`; the fallback is `~/Licensing`, never the current
source directory. The directory must be owned by you with permissions 0700 or
stricter. Private keys, state, denylists, and generated CSVs are created with
0600 permissions. Revoking authenticates the existing denylist before writing
signed denylist v1 with an incremented rollback-protection sequence.

## Uploading the CSV

The `license_key` column is what customers need; every platform below can
deliver one row per sale automatically.

- **MakersDrop** — upload `keys.csv` as your product's license key pool;
  MakersDrop emails one key per sale.
- **Gumroad** — Product → Content → check *"Generate a unique license key per
  sale"* is **off** (you bring your own keys): use Checkout → *Custom
  delivery*, or simply attach keys via Gumroad's "external keys" CSV import
  (Product → Advanced → Import license keys). One key is emailed per sale.
- **Lemon Squeezy** — Store → Products → your product → *License keys* →
  enable, then *Import license keys* and upload the `license_key` column.
  Lemon Squeezy hands one out per order.
- **Paddle** — Catalog → your product → *Fulfillment* → *License codes* →
  upload the CSV (one code per line). Paddle emails a code per checkout.
- **Stripe** — no built-in key delivery; pair with Zapier/Make ("row from
  Google Sheet per successful checkout") or any fulfillment tool that pops
  one row per sale from your CSV.

Platform UIs move around; the constant is: *"give the platform a pool of
one-per-sale codes"* — which is exactly what `keys.csv` is.

## Refunds

`indielicense revoke <key_id> --note "refunded"` verifies and re-signs the denylist;
bundle the updated JSON in your next release. Old builds the customer already
has will still accept the key — that's inherent to offline licensing and
usually fine: refund abuse at indie scale is rare, and the denylist stops it
from compounding.

## Install the CLI

The signed and Apple-notarized universal macOS binary is published through the
[`tarasowski/tap`](https://github.com/tarasowski/homebrew-tap) Homebrew tap:

```sh
brew install tarasowski/tap/indielicense
indielicense --version
```

Prebuilt archives and SHA-256 checksums are also available on the
[GitHub Releases page](https://github.com/tarasowski/indielicence/releases).

## Building from source

```sh
swift build -c release            # binary at .build/release/indielicense
swift test                        # Swift test suite (includes shared vectors)
node --test Tests/verify.test.mjs # JS verifier against the same vectors
Examples/demo.sh                  # end-to-end walkthrough in a temp dir
```

Maintainer releases are built, Developer-ID-signed, and Apple-notarized on the
local Mac so the private signing key never leaves Keychain. After storing a
`notarytool` profile named `indielicense-notary`, publish from a clean `main`:

```sh
xcrun notarytool store-credentials "indielicense-notary" \
  --apple-id "YOUR_APPLE_ID" --team-id "4UPMHT6AFG"
Tools/release.sh 1.0.2 # example: choose the next unused version
```

The script runs all tests, builds the universal CLI, signs and notarizes it,
creates the GitHub release and checksum, and updates the protected Homebrew tap
through a pull request. GitHub Actions is CI-only.

## Security model, honestly

Ed25519 signatures mean nobody can mint keys without your private key —
cracking one key gives no ability to create others. What this (and every
licensing scheme, server-checked or not) can't prevent: someone patching your
binary, or sharing one key with a friend. IndieLicense deliberately doesn't
chase clock-rollback tricks either. The goal is keeping honest customers
honest with zero infrastructure — not DRM.

**Guard the private key and state together.** Keep current encrypted backups.
The state prevents customer key ids from ever being reused; restoring a stale
state backup can revoke multiple customers at once. Back up the key in a
password manager / encrypted backup.
Lost = you can never mint keys for shipped versions again. Leaked = anyone
can. It never needs to leave your machine.

Report suspected vulnerabilities privately as described in
[`SECURITY.md`](SECURITY.md); never attach real signing material or customer
exports to a report.

## License

MIT. See [LICENSE](LICENSE).
