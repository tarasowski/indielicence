# IndieLicense key format specification

**Format version 1. This document is normative: where an implementation and
this spec disagree, the implementation has a bug.**

It is complete enough to write a verifier in any language without reading the
reference code. The shared test vectors in `Tests/vectors.json` define the
expected behavior (see [Test vectors](#test-vectors)).

## Overview

A license key is a small binary payload plus an Ed25519 signature, encoded in
Crockford base32 and rendered human-pasteable:

```
PIXELPRO-04470-TBRCN-P70WK-F0000-00AGM-M09R5-…-F9Q10
└prefix─┘ └──────── payload ‖ signature, base32 ───┘
```

Keys are verified fully offline with the product's embedded Ed25519 public
key. There is no server component and no online activation, by design.

## Human format

```
<PREFIX>-<GROUP>-<GROUP>-…
```

- `PREFIX` — the product id, uppercased. **Display only.** Decoders MUST
  ignore it: the authoritative product id is inside the signed payload.
  Concretely: split the string on `-`, discard the first component,
  concatenate the rest, and base32-decode.
- `GROUP` — the base32 data split into blocks of 5 characters for
  readability (the final block may be shorter). Typical keys are ~130–170
  characters; they are pasted, not typed.

### Crockford base32

Alphabet (value 0–31, in order): `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
(`I`, `L`, `O`, `U` are excluded as ambiguous).

Encoding: process input bytes most-significant-bit first, emitting one
alphabet character per 5 bits. If the total bit count is not a multiple of 5,
pad the final character's remaining low bits with zeros.

Decoding rules (all MUST):

- Case-insensitive. Map `O`/`o` → `0`, and `I`/`i`/`L`/`l` → `1`.
- Ignore `-` characters.
- Any other character outside the alphabet → **malformed**.
- After consuming all characters, leftover bits (fewer than 8) MUST all be
  zero; otherwise → **malformed**.

## Binary payload

All multi-byte integers are **big-endian, unsigned**. The decoded bytes are
`payload ‖ signature`, where the signature is always the final 64 bytes.
Everything before it is the payload — the exact byte range the signature
covers.

| offset | size | field |
|---|---|---|
| 0 | 1 | **format version** = `0x01` |
| 1 | 1 | **product id length** `P` (1–64) |
| 2 | `P` | **product id**, UTF-8. MUST consist only of lowercase `a-z0-9`; anything else → malformed. |
| 2+P | 4 | **key id**, uint32 |
| 6+P | 2 | **issued-at**, uint16, days since 1970-01-01 UTC. Informational only: never used in validation math. |
| 8+P | 1 | **flags**: bit 0 = expires-duration present, bit 1 = updates-duration present. Bits 2–7 MUST be zero (→ malformed if set). |
| 9+P | 0 or 2 | **expires-duration-days**, uint16, present iff flags bit 0. |
| — | 0 or 2 | **updates-duration-days**, uint16, present iff flags bit 1. Immediately follows the previous field. |

The payload ends exactly there: trailing bytes before the signature →
**malformed**. A decoded blob of 64 bytes or fewer → **malformed**.

**Signature:** Ed25519 (RFC 8032) over the exact payload bytes, appended
untruncated (64 bytes).

### Durations, not dates — and no mode byte

The format deliberately contains **no absolute expiry dates**: a calendar
date baked in at generation time would silently eat into the customer's
window while the key sits unsold ("shelf-time drift"). Both duration fields
are **relative to the customer's first activation** (below).

There is deliberately **no mode enum** on the wire. The three product modes
are derived labels, fully determined by field presence:

| expires-duration | updates-duration | mode |
|---|---|---|
| absent | absent | **lifetime** — unlocks every version, forever |
| absent | present | **updates** — unlocks forever; only versions released inside the window are covered |
| present | absent or present | **trial** — the app stops working after the window |

## Activation anchoring

The verifier stores a per-key **activatedAt** date locally (the reference
implementations use the macOS Keychain):

- On the **first successful validation** of a key that has at least one
  duration field, stamp `activatedAt` = current date from the plain system
  clock. On every later validation, reuse the stored date. Never re-stamp.
- `effectiveExpiresAt` = `activatedAt` + expires-duration-days.
- `effectiveUpdatesUntil` = `activatedAt` + updates-duration-days.

All date math is in **whole UTC days**: `unixDay(t) = floor(unixSeconds(t) / 86400)`.
A window is **inclusive of its final day**.

**No clock-rollback protection** — deliberately. Do not add monotonic
"latest date seen" stores or similar guards; a user resetting their clock to
stretch an indie-app update window is an accepted non-goal.

## Validation rules

A verifier MUST apply these steps in order and stop at the first failure:

1. **Decode** the key (prefix stripped, base32, payload layout). Failure → `malformed`.
2. **Format version** must be `1`. Else → `unsupported_version`. (Layout of
   later versions is unknown, so this is checked before the signature.)
3. **Verify the Ed25519 signature** over the exact payload bytes with the
   configured public key. Failure → `bad_signature`.
4. **Product id** in the payload must equal the verifier's configured
   product id (exact byte equality). Else → `wrong_product`.
5. If **expires-duration-days** is present: stamp/fetch `activatedAt`; if
   `unixDay(now) > unixDay(activatedAt) + expiresDurationDays` → `expired`.
6. If **updates-duration-days** is present: if
   `unixDay(buildDate) > unixDay(activatedAt) + updatesDurationDays` →
   `updates_expired`. `buildDate` is the **app build's release date**, never
   the wall clock — so an already-installed version keeps working forever,
   and this error deserves distinct UI ("renew for updates"), not
   "invalid key".
7. If a **denylist** is configured: verify it (below); an unverifiable
   denylist → `bad_denylist` (fail closed — it is a developer integration
   error, not a user state). If the key id is listed → `revoked`.

Success → valid, reporting: product, key id, issued-at,
both duration fields, `isLifetime` (true iff both durations absent),
`effectiveExpiresAt` and `effectiveUpdatesUntil` (null when the
corresponding duration is absent).

## Denylist

File `<product>.denylist.json`:

```json
{
  "format": "indielicense-denylist-v1",
  "product": "pixelpro",
  "revoked": [ { "key_id": 6, "note": "refunded" } ],
  "signature": "<base64 Ed25519 signature>"
}
```

**Canonical signed message** — UTF-8 bytes of the following lines joined by
`\n` (LF, no trailing newline):

```
indielicense-denylist-v1
<product>
<key_id 1>
<key_id 2>
…
```

with key ids in **ascending numeric order**, rendered as decimal integers
without padding. `note` fields are informational for the developer and are
**not signed**; adding/removing/altering a `key_id` without the private key
invalidates the signature. Verifiers MUST check `format`, that `product`
matches their own, and the signature, before honoring any entry.

## Test vectors

`Tests/vectors.json` contains a fixed keypair (the RFC 8032 "TEST 1" seed —
public knowledge, never use it for a real product), a signed denylist
revoking key id 6, and these cases. Expected results, validating with
`product = "pixelpro"`, `now = build date = 2026-07-11`, the vector denylist
loaded, and no prior activation state:

| case | expected result |
|---|---|
| `lifetime_valid` | valid; key id 1, `isLifetime = true` |
| `updates_365_valid` | valid; key id 2, updates-duration 365, `isLifetime = false` |
| `trial_14_valid` | valid; key id 3, expires-duration 14 |
| `tampered_key_id` | `bad_signature` (one bit of the key id flipped after signing) |
| `wrong_product` | `wrong_product` (a genuine key for product `otherapp`) |
| `revoked_key` | `revoked` (valid key id 6, listed in the vector denylist) |
| `garbage` | `malformed` |
| `unsupported_version` | `unsupported_version` (version byte 9, otherwise well-formed and signed) |

Regenerate with `node Tools/make-vectors.mjs > Tests/vectors.json` — the
generator is an independent JavaScript implementation, so the vectors
cross-check verifiers against this spec rather than against each other.

## Versioning

The single leading version byte governs the whole layout. Verifiers MUST
reject unknown versions. Any incompatible change (new fields, different
signature scheme) bumps it to `0x02`; version 1 keys remain valid forever —
shipped apps keep verifying them.
