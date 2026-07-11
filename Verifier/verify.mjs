// IndieLicense reference verifier for JavaScript (Electron/Tauri Mac apps).
// Zero dependencies — Ed25519 via node:crypto. SPEC.md is normative.
//
// This verifier is PURE: it does no storage. Your app persists activatedAt
// (stamp it the first time a key validates, then always pass the same date)
// and passes the parsed denylist JSON if you bundle one.

import crypto from "node:crypto";

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const DAY = 86400_000;
const unixDay = (date) => Math.floor(date.getTime() / DAY);

function crockfordDecode(text) {
  let acc = 0, bits = 0; const out = [];
  for (let ch of text.toUpperCase()) {
    if (ch === "-") continue;
    ch = ch === "O" ? "0" : (ch === "I" || ch === "L") ? "1" : ch;
    const value = ALPHABET.indexOf(ch);
    if (value < 0) throw new Error("malformed");
    acc = (acc << 5) | value; bits += 5;
    if (bits >= 8) { bits -= 8; out.push((acc >> bits) & 0xff); }
  }
  if (acc & ((1 << bits) - 1)) throw new Error("malformed"); // padding must be zero
  return Buffer.from(out);
}

export function decodePayload(key) {
  const groups = key.trim().split("-");
  if (groups.length < 2) throw new Error("malformed");
  const raw = crockfordDecode(groups.slice(1).join(""));
  if (raw.length <= 64) throw new Error("malformed");
  const body = raw.subarray(0, raw.length - 64), signature = raw.subarray(-64);
  let at = 0;
  const version = body[at++];
  if (version !== 1) { const e = new Error("unsupported_version"); e.version = version; throw e; }
  const productLength = body[at++];
  const product = body.subarray(at, (at += productLength)).toString("utf8");
  if (!/^[a-z0-9]+$/.test(product)) throw new Error("malformed");
  const keyID = body.readUInt32BE(at); at += 4;
  const issuedDay = body.readUInt16BE(at); at += 2;
  const flags = body[at++];
  const expiresDays = flags & 1 ? body.readUInt16BE(at) : null; if (flags & 1) at += 2;
  const updatesDays = flags & 2 ? body.readUInt16BE(at) : null; if (flags & 2) at += 2;
  if (flags & ~3 || at !== body.length) throw new Error("malformed");
  return { version, product, keyID, issuedDay, expiresDays, updatesDays, body, signature };
}

export function validateLicense(key, { publicKey, product, activatedAt = null,
                                       buildDate = new Date(), now = new Date(), denylist = null }) {
  let p;
  try { p = decodePayload(key); }
  catch (e) { return { valid: false, reason: e.message === "unsupported_version" ? "unsupported_version" : "malformed" }; }

  // Ed25519 verify over the exact payload bytes (SPKI DER wrapper around the raw key).
  const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(publicKey, "base64")]);
  const keyObject = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
  if (!crypto.verify(null, p.body, keyObject, p.signature)) return { valid: false, reason: "bad_signature" };
  if (p.product !== product) return { valid: false, reason: "wrong_product", found: p.product };

  // Durations anchor to first activation; stamp+persist activatedAt yourself.
  const activated = (p.expiresDays ?? p.updatesDays) !== null ? (activatedAt ?? now) : null;
  const effectiveExpiresAt = p.expiresDays !== null ? new Date((unixDay(activated) + p.expiresDays) * DAY) : null;
  const effectiveUpdatesUntil = p.updatesDays !== null ? new Date((unixDay(activated) + p.updatesDays) * DAY) : null;
  if (effectiveExpiresAt && unixDay(now) > unixDay(effectiveExpiresAt))
    return { valid: false, reason: "expired", on: effectiveExpiresAt };
  if (effectiveUpdatesUntil && unixDay(buildDate) > unixDay(effectiveUpdatesUntil))
    return { valid: false, reason: "updates_expired", on: effectiveUpdatesUntil };

  if (denylist) { // must be signature-verified: message = header, product, ascending ids, "\n"-joined
    const ids = denylist.revoked.map((r) => r.key_id).sort((a, b) => a - b);
    const message = Buffer.from(["indielicense-denylist-v1", denylist.product, ...ids].join("\n"), "utf8");
    if (denylist.format !== "indielicense-denylist-v1" || denylist.product !== product ||
        !crypto.verify(null, message, keyObject, Buffer.from(denylist.signature, "base64")))
      return { valid: false, reason: "bad_denylist" };
    const hit = denylist.revoked.find((r) => r.key_id === p.keyID);
    if (hit) return { valid: false, reason: "revoked", note: hit.note ?? null };
  }

  return { valid: true, info: {
    product: p.product, keyID: p.keyID, issuedAt: new Date(p.issuedDay * DAY),
    expiresDurationDays: p.expiresDays, updatesDurationDays: p.updatesDays,
    isLifetime: p.expiresDays === null && p.updatesDays === null,
    activatedAt: activated, effectiveExpiresAt, effectiveUpdatesUntil,
  } };
}
