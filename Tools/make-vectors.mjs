#!/usr/bin/env node
// Regenerates Tests/vectors.json from a FIXED Ed25519 keypair.
//
// Deliberately written in JavaScript with node:crypto — an implementation
// independent of the Swift code — so the vectors cross-check both verifiers
// against SPEC.md rather than against each other.
//
// Usage: node Tools/make-vectors.mjs > Tests/vectors.json

import crypto from "node:crypto";

// Fixed test seed — PUBLICLY KNOWN, never use for a real product.
const SEED = Buffer.from(
  "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "hex");

// node:crypto wants DER wrappers around raw Ed25519 key bytes.
const PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const privateKey = crypto.createPrivateKey({
  key: Buffer.concat([PKCS8_PREFIX, SEED]), format: "der", type: "pkcs8" });
const publicRaw = crypto.createPublicKey(privateKey)
  .export({ format: "der", type: "spki" }).subarray(-32);

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
function crockfordEncode(buffer) {
  let out = "", acc = 0, bits = 0;
  for (const byte of buffer) {
    acc = (acc << 8) | byte; bits += 8;
    while (bits >= 5) { bits -= 5; out += ALPHABET[(acc >> bits) & 31]; }
  }
  if (bits > 0) out += ALPHABET[(acc << (5 - bits)) & 31];
  return out;
}
const grouped = (s) => s.match(/.{1,5}/g).join("-");

// SPEC.md §Binary payload, format version 1.
function encodePayload({ product, keyID, issuedDay, expiresDays, updatesDays }) {
  const productBytes = Buffer.from(product, "utf8");
  const parts = [Buffer.from([1, productBytes.length]), productBytes];
  const fixed = Buffer.alloc(7);
  fixed.writeUInt32BE(keyID, 0);
  fixed.writeUInt16BE(issuedDay, 4);
  fixed.writeUInt8((expiresDays != null ? 1 : 0) | (updatesDays != null ? 2 : 0), 6);
  parts.push(fixed);
  for (const days of [expiresDays, updatesDays]) {
    if (days != null) { const b = Buffer.alloc(2); b.writeUInt16BE(days, 0); parts.push(b); }
  }
  return Buffer.concat(parts);
}

function mint(fields) {
  const payload = encodePayload(fields);
  const signature = crypto.sign(null, payload, privateKey);
  return fields.product.toUpperCase() + "-" +
    grouped(crockfordEncode(Buffer.concat([payload, signature])));
}

// A valid key whose payload we then corrupt: flip one bit inside the signed
// region (the key id) and re-encode, keeping the original signature.
function tamper(fields) {
  const payload = encodePayload(fields);
  const signature = crypto.sign(null, payload, privateKey);
  payload[2 + Buffer.byteLength(fields.product) + 3] ^= 0x01; // low byte of key id
  return fields.product.toUpperCase() + "-" +
    grouped(crockfordEncode(Buffer.concat([payload, signature])));
}

const ISSUED_DAY = 20645; // 2026-07-11
const base = { product: "pixelpro", issuedDay: ISSUED_DAY };

const vectors = {
  comment: "Shared test vectors for IndieLicense verifiers. Regenerate with Tools/make-vectors.mjs. The keypair is public test material only.",
  seed_hex: SEED.toString("hex"),
  public_key_base64: publicRaw.toString("base64"),
  product: "pixelpro",
  issued_day: ISSUED_DAY,
  issued_at: "2026-07-11",
  cases: [
    { name: "lifetime_valid", expect: "valid",
      key_id: 1, mode: "lifetime",
      key: mint({ ...base, keyID: 1 }) },
    { name: "updates_365_valid", expect: "valid",
      key_id: 2, mode: "updates", updates_duration_days: 365,
      key: mint({ ...base, keyID: 2, updatesDays: 365 }) },
    { name: "trial_14_valid", expect: "valid",
      key_id: 3, mode: "trial", expires_duration_days: 14,
      key: mint({ ...base, keyID: 3, expiresDays: 14 }) },
    { name: "tampered_key_id", expect: "bad_signature",
      key_id: 4,
      key: tamper({ ...base, keyID: 4 }) },
    { name: "wrong_product", expect: "wrong_product",
      key_id: 5, payload_product: "otherapp",
      key: mint({ product: "otherapp", issuedDay: ISSUED_DAY, keyID: 5 }) },
    { name: "revoked_key", expect: "revoked",
      key_id: 6, mode: "lifetime",
      key: mint({ ...base, keyID: 6 }) },
    { name: "garbage", expect: "malformed",
      key: "PIXELPRO-THIS0-IS0N0-TAKEY" },
    { name: "unsupported_version", expect: "unsupported_version",
      // version byte forced to 9, signed with the real key (decode must
      // reject BEFORE signature verification per SPEC validation order)
      key: (() => {
        const payload = encodePayload({ ...base, keyID: 7 });
        payload[0] = 9;
        const signature = crypto.sign(null, payload, privateKey);
        return "PIXELPRO-" + grouped(crockfordEncode(Buffer.concat([payload, signature])));
      })() },
  ],
};

// Signed denylist revoking key id 6 (message: SPEC.md §Denylist).
const denylistMessage = ["indielicense-denylist-v1", "pixelpro", "6"].join("\n");
vectors.denylist = {
  format: "indielicense-denylist-v1",
  product: "pixelpro",
  revoked: [{ key_id: 6, note: "test vector: refunded" }],
  signature: crypto.sign(null, Buffer.from(denylistMessage, "utf8"), privateKey)
    .toString("base64"),
};

console.log(JSON.stringify(vectors, null, 2));
