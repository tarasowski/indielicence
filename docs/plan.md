# Build "IndieLicense" — offline license keys for indie Mac apps

> **Historical document.** This is the original build plan, kept for context.
> It is not maintained. Agents: follow `AGENTS.md` (operating rules),
> `AI_INTEGRATION.md` (integration playbook), `SPEC.md` (wire format), and
> `README.md` (current features) instead — they are canonical and current.

## What this is

Build a complete, production-quality, open-source licensing toolkit for indie macOS developers, to be published on GitHub under the MIT license. Product name: **IndieLicense**; CLI binary is lowercase `indielicense`. Tagline: "Offline license keys for indie Mac apps. No server, ever." (Keep "Mac" out of the product name itself per Apple's trademark guidelines — it's fine in the tagline/README/marketing copy, just not as part of the name.)

The core promise, which every design decision must serve: **no server, no service, no account — ever.** A developer generates license keys on their own machine, sells them through any payment platform, and their app validates keys fully offline. The tool must keep working even if this GitHub repo disappears.

## The mental model

- The developer holds an **Ed25519 private key** — a key-minting machine only they own. It never leaves their machine and is never required by the shipped app.
- Their app embeds the matching **public key** — a key-checking machine that can verify keys but never create them. Safe to ship, safe to reverse-engineer.
- A **license key** is a small signed payload encoded as a human-pasteable string. The app validates: signature OK + product matches + not expired + not on the denylist. All offline, instant.
- Payment platforms (Gumroad, Lemon Squeezy, Paddle, Stripe) all support "upload a CSV of keys, email one per sale" — so the payment platform does delivery and the developer does nothing per sale.

## Deliverables (one Swift Package repo)

1. **CLI binary** (`indielicense`) — Swift, using swift-argument-parser, CryptoKit for all crypto. macOS only by design; do not add Linux support.
2. **Verification library** (`IndieLicense` SPM library target) — verification only, zero secrets, zero dependencies beyond CryptoKit.
3. **Single-file verifier** (`Verifier/LicenseVerifier.swift`) — a self-contained ~100–150 line copy-paste Swift file that does full verification with only CryptoKit imports. This is the PRIMARY integration path (indie devs prefer auditable copy-paste over dependencies); the SPM library is convenience. Keep it in sync with the library (ideally the library includes this exact file).
4. **Format specification** (`SPEC.md`) — a precise, language-agnostic description of the key format, byte layouts, encodings, and validation rules, complete enough that someone can implement a verifier in any language without reading the Swift code.
5. **Reference JavaScript verifier** (`Verifier/verify.mjs`) — ~50 lines using a standard Ed25519 lib (e.g. @noble/ed25519 or node:crypto), for Electron/Tauri Mac apps. Must pass the shared test vectors.
6. **Test vectors** (`Tests/vectors.json`) — fixed keypair + a set of valid/invalid/expired/tampered keys, used by both Swift tests and the JS verifier test.
7. **Tests** — round-trip (generate → verify), tampered payload rejected, wrong product rejected, duration-based expiry: activatedAt stamped on first validation and NOT reset on subsequent validations, effective expiry/updates-until computed correctly from activatedAt + duration, denylisted key rejected, CSV output correctness (all fields incl. duration columns), sequence continuity across batches, `--mode lifetime` key never expires and reports `isLifetime == true` regardless of how much time passes, `generate` errors when a duration flag is passed with a `--mode` that doesn't use it.
8. **README.md** — the developer workflow front and center (see below), a 10-line integration example, and short guides for uploading the CSV to Gumroad / Lemon Squeezy / Paddle.
9. **GitHub Actions** — CI (build + test) and a release workflow that attaches a signed/notarization-ready universal binary (arm64 + x86_64) to GitHub Releases. Include a Homebrew formula file or tap instructions.

## CLI commands

```
indielicense init --product <id>
    Creates a keypair. Writes private key to ./<product>.private (0600 perms),
    prints the public key (base64) for embedding in the app.
    LOUD warning: back up the private key; if lost, no more keys can be minted
    for shipped app versions; if leaked, anyone can mint keys.
    Refuses to overwrite an existing private key file.

indielicense generate --count <n> --mode <lifetime|updates|trial> [--updates-duration <e.g. 365d>] [--expires <e.g. 14d>] [--out keys.csv]
    Mints n keys, appends/writes CSV: key_id,license_key,issued_at,mode,expires_duration_days,updates_duration_days
    --mode is required and makes intent explicit and self-documenting (in the
    CSV, in logs, in `inspect` output) rather than relying on which flags were
    or weren't passed:
      --mode lifetime   Sets neither duration field. The app unlocks forever,
                         full stop — no expiry, no update cutoff, ever. This is
                         the flagship "$9, yours forever" product key.
      --mode updates     Requires --updates-duration. The app also unlocks
                         forever, but only versions released within that many
                         days of the customer's activation are covered — after
                         that they keep using their current version or renew.
                         The Sketch/JetBrains-fallback model; default choice
                         for "buy once, 12 months of updates included".
      --mode trial       Requires --expires. The app stops working entirely
                         once the trial window (from activation) has passed.
    Errors if --expires or --updates-duration is passed with a --mode that
    doesn't use it (e.g. --mode lifetime --expires 14d is a contradiction).
    Key IDs are sequential and continue across batches (state kept in a sidecar
    file next to the private key, e.g. <product>.state). Never reuse a key ID.

indielicense verify <key>
    Full validation against the public key (derived from the private key file
    or passed via --public-key). Exit code 0/1 + human-readable reason.

indielicense inspect <key>
    Decodes and prints the payload (product, key ID, dates) WITHOUT needing any
    key material; notes whether the signature was checked or not.

indielicense revoke <key_id> [--note "refunded"]
    Appends to a signed denylist file (<product>.denylist.json), re-signing it
    with the private key. The dev bundles this file into their next app release.

indielicense revoke --list
    Prints current denylist with notes.
```

All commands: `--key-dir` to point at the private key location, sensible defaults, good `--help` text, clear error messages. No telemetry, no network calls anywhere in the entire codebase.

## Key format (put the final version in SPEC.md)

- Human format: `<PREFIX>-XXXXX-XXXXX-...` where PREFIX is the uppercased product id (configurable), and the rest is the payload+signature encoded in Crockford base32 (no ambiguous chars), grouped in blocks of 5 for readability. Keys will be ~110–140 chars — that's acceptable; they are pasted, not typed.
- Binary payload (design the exact layout, keep it compact and versioned):
  - format version (1 byte, start at 1)
  - product id (length-prefixed UTF-8, lowercase)
  - key id (uint32)
  - issued-at (unix days, uint16 or uint32 — your call, document it) — when the key was generated, informational only, not used in validation math
  - expires-duration-days (optional; absent by default) — a RELATIVE duration in days (e.g. 14 for a trial). See "activation-anchored fields" below.
  - updates-duration-days (optional; absent by default; e.g. 365) — a RELATIVE duration in days. This is the field the default "buy once, 12 months of free updates included, keep using it after, optional renewal" model uses.
- Signature: Ed25519 over the exact payload bytes, appended. No truncation.
- No fixed/absolute expiry dates in the format at all — deliberately cut. A calendar date baked in at CSV-generation time silently eats into the customer's window depending on how long the key sits unsold before purchase (shelf-time drift), and there's no common real-world case (checked: even bundle-deal promos are better served by "the sale window closes on X" as an operational decision — stop running `generate` — with the license itself still starting from activation like any other key) that justifies carrying both a fixed and a relative variant of the same field. Durations only.
- No separate "mode" byte in the wire format — don't add it. The three modes (lifetime / updates / trial) are fully determined by which of the two duration fields is present, so a mode enum would just be redundant state that could drift out of sync with the fields it's supposed to describe. `--mode` at the CLI layer and `isLifetime`/`mode` in the validator API (below) are both *derived labels* for display and ergonomics, computed from field presence, not new data on the wire:
  - neither field set → lifetime
  - updates-duration-days set (expires-duration-days absent) → updates
  - expires-duration-days set → trial (regardless of updates-duration-days, though generate's --mode trial won't set that combination by default)

### Activation-anchored fields (expires-duration-days / updates-duration-days)

A key never carries a date — only a duration. The app stamps the real start date locally the first time the key is actually used, so the countdown always starts from the customer's activation, never from when the batch was generated.

- On first successful validation of a key, the app records `activatedAt = <today, plain system clock, no guard logic>` in Keychain (via the `LicenseStore` helper described below), alongside the key itself.
- From then on: `effectiveExpiresAt = activatedAt + expires-duration-days` (if that field was set) and/or `effectiveUpdatesUntil = activatedAt + updates-duration-days` (if that field was set), both computed once and persisted, not recomputed from "now" against the original key payload.
- `effectiveExpiresAt` is compared against the wall clock (hard expiry). `effectiveUpdatesUntil` is compared against the app's build date — so day-to-day "is this app version covered" checks still never trust the wall clock; the wall clock is read exactly once, at first activation.
- Do NOT add clock-rollback protection, a monotonic "latest date ever seen" store, or any similar guard — deliberately out of scope. A user who resets their system clock to game a few extra months of free updates on an indie app is an acceptable, uninteresting edge case; do not add complexity to chase it.
- A dev picks per batch whether to set either duration field, both, or neither (plain perpetual key, no expiry, no update window).

- Validation rules (spell out in SPEC.md, implement in both verifiers):
  1. decode, check format version is known
  2. verify signature with embedded public key
  3. product id must match the app's configured product id
  4. if expires-duration-days present: reject when current wall-clock date is past `activatedAt + duration` (activatedAt from LicenseStore, stamped on first validation if not already set)
  5. if updates-duration-days present: reject when the app's build date is past `activatedAt + duration`, with a distinct error so apps can show "renew for updates" instead of "invalid key"
  6. if a denylist is provided: verify the denylist's own signature, then reject listed key IDs
- Denylist file: JSON { product, revoked: [{key_id, note?}], signature } — signature by the same private key over a canonical serialization (define it precisely in SPEC.md).

## Verifier API (library + single file)

Aim for this integration experience:

```swift
let validator = LicenseValidator(
    publicKey: "BASE64_PUBLIC_KEY",
    product: "pixelpro",
    buildDate: embeddedReleaseDate,              // immutable constant in the signed build
    denylist: Bundle.main.url(forResource: "denylist", withExtension: "json") // optional
)
switch validator.validate(userPastedKey) {
case .valid(let info):
    // info.keyID, info.issuedAt
    // info.isLifetime: Bool — true when neither duration field was set; apps
    //   can show "Lifetime license" directly without computing this themselves
    // info.effectiveUpdatesUntil: Date? — nil when isLifetime or updates has
    //   no cutoff; else activatedAt + updates-duration-days
    // info.effectiveExpiresAt: Date? — nil unless this is a trial key
case .invalid(let reason):    // wrongProduct, badSignature, expired, revoked, updatesExpired, malformed
}
```

Provide a `LicenseStore` Keychain helper with this responsibility split:
- `LicenseStore.save(key)` / `LicenseStore.load()` — persist the pasted key itself across reinstalls (as today).
- `LicenseStore.activatedAt(for: keyID)` — returns the stored first-activation date for a key, stamping it with the current wall-clock date on first call if none exists yet, then returning that same date on every subsequent call. `LicenseValidator.validate` calls this internally whenever the decoded payload has `expires-duration-days` or `updates-duration-days` set, to compute the effective date before comparing. No clock-rollback guard, no monotonic tracking — plain `Date()`, by design (see the activation-anchored fields section above for why).

README should note: re-validate the stored key on every launch (as today), and that the very first launch after a customer pastes their key is what starts their update/trial window for duration-based keys — so `activatedAt` should be stamped at first successful validation, not at CSV generation.

## Explicitly out of scope — do not build

Online activation, device limits, phone-home checks, accounts, analytics, a hosted service of any kind, Windows/Linux app support, subscription billing logic. If a feature needs a server, it doesn't belong here.

## Quality bar

- Idiomatic modern Swift, no force-unwraps in library code, errors are typed and descriptive.
- The single-file verifier must be genuinely readable top-to-bottom — it is a trust artifact, comment it for a human auditor.
- SPEC.md is normative: where code and spec disagree, that's a bug. Include the test vectors' expected results in the spec.
- README opens with the 5-step developer workflow (init → integrate → generate → upload CSV → done) in plain language before any reference material.
- Everything works end-to-end on a clean machine: `swift build`, `swift test`, then a scripted demo (`Examples/demo.sh`) that creates a keypair, mints 5 keys, verifies one, tampers one and shows it fail, revokes one and shows the denylist reject it.

Build the whole thing, run the tests and the demo script, and show me the demo output plus a generated example key.
