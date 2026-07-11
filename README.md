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

1. **`indielicense init --product pixelpro`** — creates your private
   key-minting key (back it up!) and prints the public key.
2. **Integrate** — copy [`Verifier/LicenseVerifier.swift`](Verifier/LicenseVerifier.swift)
   into your app (or add the SPM library) and paste in the public key. Ten
   lines, shown below.
3. **`indielicense generate --count 500 --mode updates --updates-duration 365d`**
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
    buildDate: LicenseValidator.compiledDate,  // or hardcode your release date
    denylist: Bundle.main.url(forResource: "pixelpro.denylist", withExtension: "json"))
switch validator.validate(pastedKey) {
case .valid(let info):   unlock(info)      // info.isLifetime, info.effectiveUpdatesUntil, …
case .invalid(.updatesExpired(let on)):    showRenewSheet(updatesEndedOn: on)
case .invalid(let reason):                 showError(reason)
}
```

Store the pasted key with `LicenseStore.shared.save(key:)` and re-validate it
with `validator.validate(LicenseStore.shared.load() ?? "")` on every launch.
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

## The three key modes

| mode | flags | what the customer gets |
|---|---|---|
| **lifetime** | `--mode lifetime` | The app unlocks forever. No expiry, no update cutoff, ever. The "$9, yours forever" key. |
| **updates** | `--mode updates --updates-duration 365d` | Unlocks forever, but only versions **released** within 365 days of their activation are covered — after that they keep their current version or buy a renewal key. The Sketch/JetBrains-fallback model; the default choice for "buy once, 12 months of updates included". |
| **trial** | `--mode trial --expires 14d` | The app stops working entirely 14 days after activation. |

Durations always count from the **customer's first activation** — keys can
sit unsold in your CSV for years without losing a day of anyone's window.
The updates check compares against your app's **build date**, not the wall
clock, so an installed version never stops working.

## CLI reference

```
indielicense init --product <id>            create a keypair (refuses to overwrite)
indielicense generate --count <n> --mode <lifetime|updates|trial>
                      [--updates-duration 365d] [--expires 14d] [--out keys.csv]
                                            mint keys; ids continue across batches
indielicense verify <key>                   full validation, exit 0/1
indielicense inspect <key>                  decode a key, no key material needed
indielicense revoke <key_id> [--note "refunded"]
                                            add to the signed denylist
indielicense revoke --list                  show the denylist
```

All commands take `--key-dir` to point at your private key's directory and
have detailed `--help`. Revoking appends to `<product>.denylist.json`; bundle
that file into your next release and shipped builds will reject those keys.

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

`indielicense revoke <key_id> --note "refunded"` re-signs the denylist;
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

**Guard the private key.** Back it up (password manager / encrypted backup).
Lost = you can never mint keys for shipped versions again. Leaked = anyone
can. It never needs to leave your machine.

## License

MIT. See [LICENSE](LICENSE).
