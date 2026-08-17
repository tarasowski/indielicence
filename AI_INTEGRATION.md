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
Distribution: paid | freemium   (freemium: the core app is free forever, a license key unlocks Pro features)
License mode: lifetime | updates | trial
Public key: BASE64_PUBLIC_KEY_FROM_INDIELICENSE_INIT
Keyless trial: none | 7d | 14d | ...   (built-in try-before-buy, no key needed; paid distribution only)
Trial policy: soft | hard   (soft: features degrade; hard: app locks until a key is entered; paid only)
Purchase URL: none | https://YOUR_CHECKOUT_PAGE   (shown as a "Buy a license" / "Upgrade to Pro" button)
Feedback: none | endpoint https://YOUR_POST_ENDPOINT | link https://YOUR_FEEDBACK_PAGE | you@example.com
   (endpoint: an in-app "Request a feature" sheet POSTs the user's message as JSON {mode, version, message, email} — sent exclusively when the user presses Send, never on its own; link: opens the browser pre-tagged with tier and version; email: opens the mail client. Nothing in the app ever calls home.)

Inspect this app to select the Swift or JavaScript verifier. Add a license-entry
flow, secure persistence, validation on every launch, an immutable release build
date, correct UI for every validation result, and tests. When a keyless trial is
requested, gate paid features with hasFullAccess and surface the generated
LicenseBadgeView (trial days remaining / unlock / renew). With freemium
distribution, never gate the core app: it stays fully usable forever with no
key; gate only Pro features, with license.isPro. Do not add a licensing
server, telemetry, analytics, or any network call — the only permitted network
code is the generated feedback sheet in endpoint mode, which sends exclusively
when the user presses Send. Never access or modify .private or .state files
and never commit generated customer keys.

Before generating or changing anything, ask me the licensing-interview
questions from AI_INTEGRATION.md for every value not already given above
(mode and durations, keyless trial days, purchase URL, payment platform,
UI, denylist, build date) and wait for my answers.
```

If the product has no keypair yet, omit `Public key` and tell the agent to stop
after giving the exact `indielicense init` command. Run that command once, back
up the two generated files, and then give the agent only the printed public key.

Any value the prompt leaves out is not the agent's to guess: the agent must run
the licensing interview below before generating anything.

## Required licensing interview — ask, never assume

Before running `indielicense integrate` or minting keys, the agent must have an
explicit answer from the user for every applicable question below. Ask them
conversationally (one short block, not an interrogation), present the
recommended default, and wait for answers. Do not silently pick a value; a
licensing model is a business decision, not a technical one.

| # | Question to ask the user | Maps to | Notes / recommended default |
|---|---|---|---|
| 1 | What is the product id? | `--product` | lowercase `a-z0-9`, 1–64 chars; suggest one derived from the app name |
| 1b | Which **distribution model**: **paid** (a license is required, optionally after a trial) or **freemium** (the core app is free forever with no key; a purchased key unlocks the Pro tier)? | `integrate --distribution` | `paid`; choose `freemium` for free-first apps that will monetize later — integrating it from the first release lets Pro arrive in an update with no migration |
| 2 | Which sales model for purchased keys: **lifetime** (pay once, everything forever), **updates** (pay once, keep forever, updates covered for a window — recommended), or **trial keys**? Freemium Pro keys are ordinary lifetime/updates keys. | `generate --mode` | `updates` is the common indie default |
| 3 | If **updates**: how long should the update window be? Months are fine — convert to days (12 months → `365d`, 6 months → `180d`). | `--updates-duration` | `365d` |
| 4 | If **trial keys**: how many days until the key expires after activation? | `--expires` | `14d`; remind the user these are for press/beta/manual grants |
| 5 | Should the app have a **built-in keyless trial** (everyone can try it on first launch, no key needed)? If yes, how many days? | `integrate --trial` | `7d` or `14d`; independent of question 2 and composes with any key mode |
| 5b | When full access ends (trial over, no key): **soft** (app keeps running, features degrade — e.g. a watermark) or **hard** (the whole app locks behind a non-dismissible key-entry screen)? | `integrate --trial-policy soft\|hard` | `soft`; `hard` requires `--ui swiftui` and wrapping the root view in `LicenseGateView` |
| 6 | Where do customers **buy** a license — what is the checkout page URL? | `integrate --purchase-url` | must be `https://…`; shown as a "Buy a license" button, only ever opened in the browser. "None yet" is acceptable — the button is simply hidden |
| 6b | How should users **request features**: an in-app form posting to an **endpoint** (e.g. the app's store feedback API — recommended), a feedback page **link**, or a plain **email** address? | `integrate --feedback-endpoint`, `--feedback-url`, or `--feedback-email` (choose exactly one, or none) | endpoint must be `https://…` and generates `LicenseFeedbackView` (requires `--ui swiftui`), which POSTs JSON {mode, version, message, email} exclusively when the user presses Send — the only networking code the scaffold can emit; link/URL carries tier + version query items in the browser; email becomes a mailto with those in the subject. Strongly recommended for freemium apps — the free phase is only worth it if it produces feedback. "None" generates no feedback code at all |
| 7 | Which **payment platform** delivers the keys (MakersDrop, Gumroad, Lemon Squeezy, Paddle, Stripe, other)? | CSV upload guidance only | affects the handoff instructions, not the code |
| 8 | Use the generated neutral **SwiftUI UI** (key-entry sheet + status badge), or does the app have its own? | `integrate --ui swiftui\|none` | `swiftui` when the app has no licensing UI yet |
| 9 | Will refunds/chargebacks need **revocation** (a signed denylist bundled with each release)? | `integrate --denylist bundled\|none`, later `revoke` | `none` to start is fine; can be added later |
| 10 | What is the **release build date** of the upcoming release (UTC, `YYYY-MM-DD`)? | `integrate --build-date` | usually today or the planned ship date; must be updated every release |
| 11 | When minting: **how many keys** for the first batch? | `generate --count` | match roughly expected sales; ids continue across batches, so small batches are fine |

Answer-mapping rules the agent must apply:

- All wire durations are **days**. Convert user answers given in weeks/months/
  years (1 month → 30d is fine unless the user says otherwise; 12 months →
  `365d`) and confirm the conversion back to the user.
- "How many months is the key valid?" usually means the **update window**
  (mode `updates`), not expiry — a purchased key itself never stops unlocking
  the builds it covers. Only trial keys expire. Clarify this with the user if
  their wording is ambiguous.
- Keyless trial (question 5) and key mode (question 2) are independent axes:
  `--trial 7d` + lifetime keys, `--trial 14d` + updates keys, etc. are all
  valid combinations.
- If the user declines the keyless trial, purchase URL, feedback URL, or
  denylist, generate without those flags — every one of them is optional.
- Freemium excludes the trial axes: `--distribution freemium` refuses `--trial`
  (the free tier never expires) and `--trial-policy hard` (the free core never
  locks). Questions 5 and 5b are skipped for freemium apps.
- In freemium apps, gate Pro features with `license.isPro` and gate nothing
  else. Features that shipped free must stay free in later releases; a new Pro
  tier may only ever lock features that did not exist before.

## Required agent procedure

### 1. Read and inspect before editing

1. Read this file, `AGENTS.md`, `README.md`, and `SPEC.md` from IndieLicense.
2. Inspect the target app's platform, targets, build system, existing purchase
   or settings UI, app startup path, persistence layer, and test framework.
3. Complete the licensing interview above: product id, key mode and its
   durations, keyless trial, purchase URL, payment platform, UI, denylist, and
   build date must all be explicit user answers before any generation step.
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

### 3. Generate the Swift plumbing or add the verifier manually

Choose one supported path:

- Standard Swift/macOS app: generate ordinary app-owned source files. This is
  scaffolding, not an SDK or runtime dependency:
  ```sh
  indielicense integrate swift --product PRODUCT_ID \
    --public-key BASE64_PUBLIC_KEY --build-date YYYY-MM-DD \
    --output PATH/TO/APP/License --ui none --denylist none
  ```
  Select `--ui swiftui` only when a neutral price-free key-entry view is useful,
  and `--denylist bundled` only when the signed denylist will be an app resource.
  Pass `--distribution freemium` for free-first apps: the generated
  `LicenseManager` reports the permanent `free` state when no key is stored,
  the app must gate only Pro features (with `license.isPro`), and the generated
  UI reads "Unlock Pro" / "Upgrade to Pro" instead of activation/buy copy.
  Freemium refuses `--trial` and `--trial-policy hard` by design.
  Choose at most one feedback mode:
  - `--feedback-endpoint https://...` (with `--ui swiftui`) generates
    `LicenseFeedbackView`, an in-app "Request a feature" sheet reachable from
    the activation sheet (present it from a Help-menu item too). It POSTs the
    user's message as JSON {mode, version, message, email} to the endpoint —
    exclusively when the user presses Send. That view is the only networking
    code in the generated files and must stay the app's only feedback call;
    never add background sends, retries-on-launch, telemetry, or analytics.
  - `--feedback-url https://...` adds a "Request a feature" browser link (and
    `license.feedbackLink()` for a Help-menu item) carrying tier and
    app-version query items — zero networking code in the app.
  - `--feedback-email you@example.com` opens the mail client with product,
    version, and tier pre-filled in the subject — zero networking code.
  Add `--trial 7d` only when the user wants a keyless first-launch trial: the
  generated `LicenseManager` then stamps a trial start day once in the license file store
  and reports `.trial`/`.trialExpired` states for customers with no stored key.
  Gate paid features with `hasFullAccess` in that case, not `isLicensed`.
  With `--ui swiftui`, ask the user for their checkout page and pass it as
  `--purchase-url https://...` so the generated `LicenseBadgeView` (trial days
  remaining / unlock / renew badge) and activation sheet can offer a "Buy a
  license" button. The URL is only opened in the browser — never fetched.
  Pass `--trial-policy hard` only when the user wants the app to truly stop
  working without full access: the generated `LicenseGateView` then replaces
  the app's content with a non-dismissible lock screen (key entry + purchase
  link). Wrap the app's root view in `LicenseGateView(license:)` with an
  app-level `LicenseManager` — a manager created inside a view behind the
  gate can never unlock it.
  The command refuses to overwrite existing files. Inspect and adapt the output,
  add its `.swift` files to the app target, and follow `LICENSE_INTEGRATION.md`.
  Every generated Swift integration includes a self-contained development
  harness: Debug builds start in a simulated preset (paid: a lifetime key so
  development is never blocked; freemium: the free preset real users see) and
  automatically add an **IndieLicense Testing** menu listing the presets that
  can actually occur for the app's model. It is guarded by `#if DEBUG`,
  never touches real persisted state while simulating, has no dependency on a
  particular build/launch tool, and is absent from Release builds. Do not add
  AppUnbound-specific bundle-id or channel checks to this generalized harness.
- Custom Swift/macOS integration: copy the canonical
  `Verifier/LicenseVerifier.swift` into the app target. The SPM library product
  `IndieLicense` remains an alternative.
- Electron/Tauri/Node: copy `Verifier/verify.mjs`. It is dependency-free and
  uses `node:crypto`.

Do not reimplement the wire format or cryptography. Do not weaken or reorder
validation. Do not introduce a network request, server activation, telemetry,
or analytics — the generated `LicenseFeedbackView` (endpoint mode only) is the
single exception, and its one request must remain user-initiated.

Generated Swift types and UI are starting points owned by the target app. Keep
product-specific feature policy, migrations, checkout, prices, copy, and
localization in that app; never add them to IndieLicense's generalized templates.

### 4. Wire the complete app flow

The integration is incomplete until all of these exist:

1. Configure the exact public key and product id.
2. Embed an immutable UTC release build date in source or generated build
   settings. Never use `Date()` as the build date, executable modification
   time, filesystem metadata, or another value that changes after signing.
3. Add a license-entry screen that accepts a pasted key and shows useful,
   non-technical errors.
4. On the first successful validation, persist the license and activation
   state securely. Swift integrations use the included file-backed
   `LicenseStore` (tamper-evident HMAC'd files under Application Support). JavaScript integrations must persist `activatedAt` and the
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
9. With freemium distribution: the core app runs fully with no key, forever —
   no nagging, no expiry, no lock screen. Gate exactly the Pro feature set with
   `license.isPro`. The no-key state is `free`, and the UI must present it as a
   valid tier, never as an error or an unlicensed condition. When a feedback
   URL is configured, surface the "Request a feature" link (activation sheet
   and/or a Help-menu item via `license.feedbackLink()`).
10. When a keyless trial is configured, gate paid features with
   `license.hasFullAccess` (true while licensed **or** in trial) instead of
   `isLicensed`, place `LicenseBadgeView(license:)` somewhere always visible
   (toolbar or status area), and make sure the `.trialExpired` state leads the
   customer to key entry and the purchase link rather than a dead end. The
   keyless trial exists only in the generated Swift scaffolding; JavaScript
   integrations that want one must implement the equivalent stamp-once logic
   in their own persistence layer.

### 5. Test and hand off

Add target-app tests covering at least:

- a valid key for the configured product;
- malformed and signature-tampered keys;
- a key for the wrong product;
- trial expiry or update-window boundaries when that mode is used;
- keyless-trial behavior when configured: full access inside the window,
  `trialExpired` after it, no restart on relaunch, and a real key ending the
  trial;
- freemium behavior when configured: no stored key reports `free`, every core
  feature works, nothing expires, and a valid key flips `isPro` immediately;
- feedback-link behavior when configured: the composed URL carries the correct
  tier and version query items and the app performs no network request;
- feedback-endpoint behavior when configured: the sheet submits only on an
  explicit Send, reports offline/server errors without retrying silently, and
  no other code path triggers the request;
- hard-policy behavior when configured: the lock screen replaces the app when
  access ends, cannot be dismissed, and a valid key restores the app
  immediately;
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
