# IndieLicense

**Offline license keys for indie Mac apps. No server, ever.**

Generate Ed25519-signed license keys on your own machine, sell them through
MakersDrop / Gumroad / Lemon Squeezy / Paddle / Stripe, and validate them in
your app fully offline — no server, no service, no account, no telemetry, no network calls.
If this repo disappears tomorrow, your keys and your app keep working.

> **Using a coding agent** (Claude Code, Codex, Cursor)? Point it at this
> repo — [`AGENTS.md`](AGENTS.md) tells it how to set up licensing, integrate
> the verifier into your app, and which operations it must never perform
> (touching private keys, revoking, anything destructive).

## The 5-step workflow

1. **`indielicense init --product pixelpro --key-dir ~/Licensing/pixelpro`** — creates your private
   key-minting key (back it up!) and prints the public key.
2. **Integrate** — copy [`Verifier/LicenseVerifier.swift`](Verifier/LicenseVerifier.swift)
   into your app (or add the SPM library) and paste in the public key. Ten
   lines, shown below.
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

## Integration (10 lines)

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

Two integration paths, same code:

- **Copy-paste (recommended):** drop [`Verifier/LicenseVerifier.swift`](Verifier/LicenseVerifier.swift)
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

## Building from source

```sh
swift build -c release            # binary at .build/release/indielicense
swift test                        # Swift test suite (includes shared vectors)
node --test Tests/verify.test.mjs # JS verifier against the same vectors
Examples/demo.sh                  # end-to-end walkthrough in a temp dir
```

Or install via Homebrew once you've pushed a release (see
[`Formula/indielicense.rb`](Formula/indielicense.rb) for a tap-ready formula).

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
