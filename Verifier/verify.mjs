// IndieLicense reference verifier for JavaScript (Electron/Tauri Mac apps).
// Pure, dependency-free, and offline. SPEC.md is normative.

import crypto from "node:crypto";

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const DAY = 86_400_000;
const MAX_KEY_BYTES = 512;
const MAX_DENYLIST_ENTRIES = 100_000;

const validDate = (value) => value instanceof Date && Number.isFinite(value.getTime());
const unixDay = (date) => Math.floor(date.getTime() / DAY);

function crockfordDecode(text) {
  let acc = 0, bits = 0;
  const out = [];
  for (const byte of Buffer.from(text, "utf8")) {
    if (byte > 0x7f) throw new Error("malformed");
    let ch = byte;
    if (ch >= 0x61 && ch <= 0x7a) ch -= 0x20;
    if (ch === 0x4f) ch = 0x30; // O -> 0
    if (ch === 0x49 || ch === 0x4c) ch = 0x31; // I/L -> 1
    const value = ALPHABET.indexOf(String.fromCharCode(ch));
    if (value < 0) throw new Error("malformed");
    acc = (acc << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >>> bits) & 0xff);
    }
  }
  const mask = bits === 0 ? 0 : (1 << bits) - 1;
  if ((acc & mask) !== 0) throw new Error("malformed");
  return Buffer.from(out);
}

export function decodePayload(key) {
  if (typeof key !== "string" || Buffer.byteLength(key, "utf8") > MAX_KEY_BYTES)
    throw new Error("malformed");
  const groups = key.trim().split("-");
  if (groups.length < 2 || groups[0].length === 0) throw new Error("malformed");
  const raw = crockfordDecode(groups.slice(1).join(""));
  if (raw.length <= 64) throw new Error("malformed");
  const body = raw.subarray(0, raw.length - 64);
  const signature = raw.subarray(raw.length - 64);
  let at = 0;
  const take = (count) => {
    if (!Number.isInteger(count) || count < 0 || at + count > body.length)
      throw new Error("malformed");
    const value = body.subarray(at, at + count);
    at += count;
    return value;
  };
  const version = take(1)[0];
  if (version !== 1) {
    const error = new Error("unsupported_version");
    error.version = version;
    throw error;
  }
  const productLength = take(1)[0];
  if (productLength < 1 || productLength > 64) throw new Error("malformed");
  const productBytes = take(productLength);
  if (![...productBytes].every((b) => (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39)))
    throw new Error("malformed");
  const product = productBytes.toString("ascii");
  const keyID = take(4).readUInt32BE(0);
  const issuedDay = take(2).readUInt16BE(0);
  const flags = take(1)[0];
  if ((flags & ~3) !== 0) throw new Error("malformed");
  const expiresDays = flags & 1 ? take(2).readUInt16BE(0) : null;
  const updatesDays = flags & 2 ? take(2).readUInt16BE(0) : null;
  if (at !== body.length) throw new Error("malformed");
  return { version, product, keyID, issuedDay, expiresDays, updatesDays, body, signature };
}

function strictBase64(value, expectedLength) {
  if (typeof value !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return null;
  const decoded = Buffer.from(value, "base64");
  if (decoded.length !== expectedLength || decoded.toString("base64") !== value) return null;
  return decoded;
}

function validProduct(product) {
  return typeof product === "string" && /^[a-z0-9]{1,64}$/.test(product);
}

function denylistMessage(product, sequence, entries) {
  const lines = ["indielicense-denylist-v1", product, String(sequence)];
  for (const entry of entries) {
    const note = entry.note == null
      ? "-"
      : "+" + Buffer.from(entry.note, "utf8").toString("base64");
    lines.push(`${entry.key_id}\t${note}`);
  }
  return Buffer.from(lines.join("\n"), "utf8");
}

function verifyDenylist(denylist, product, keyObject, minimumSequence) {
  if (!denylist || typeof denylist !== "object" || Array.isArray(denylist) ||
      denylist.format !== "indielicense-denylist-v1" || denylist.product !== product ||
      !Number.isSafeInteger(denylist.sequence) || denylist.sequence < 1 ||
      denylist.sequence > 0xffff_ffff || !Array.isArray(denylist.revoked) ||
      denylist.revoked.length > MAX_DENYLIST_ENTRIES)
    return { ok: false };

  const entries = [];
  const seen = new Set();
  for (const candidate of denylist.revoked) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate) ||
        !Number.isInteger(candidate.key_id) || candidate.key_id < 0 ||
        candidate.key_id > 0xffff_ffff ||
        !(candidate.note == null || typeof candidate.note === "string") ||
        (typeof candidate.note === "string" && Buffer.byteLength(candidate.note, "utf8") > 4096) ||
        seen.has(candidate.key_id)) return { ok: false };
    seen.add(candidate.key_id);
    entries.push({ key_id: candidate.key_id, note: candidate.note ?? null });
  }
  entries.sort((a, b) => a.key_id - b.key_id);
  const signature = strictBase64(denylist.signature, 64);
  if (!signature || !crypto.verify(
    null, denylistMessage(product, denylist.sequence, entries), keyObject, signature))
    return { ok: false };
  if (denylist.sequence < minimumSequence) return { ok: false, rollback: true };
  return { ok: true, entries, sequence: denylist.sequence };
}

/**
 * Validate a license without network or storage.
 *
 * Persist `info.activatedAt` after first success and pass it back unchanged.
 * Persist the greatest `info.denylistSequence` and pass it as
 * `minimumDenylistSequence` to detect signed-denylist rollback.
 */
export function validateLicense(key, options = {}) {
  let p;
  try { p = decodePayload(key); }
  catch (error) {
    return { valid: false, reason: error.message === "unsupported_version"
      ? "unsupported_version" : "malformed" };
  }

  try {
    const {
      publicKey, product, activatedAt = null, buildDate = null,
      now = new Date(), denylist = null, minimumDenylistSequence = null,
    } = options;
    if (!validProduct(product) || !validDate(now) ||
        (denylist !== null && (!Number.isSafeInteger(minimumDenylistSequence) ||
          minimumDenylistSequence < 0 || minimumDenylistSequence > 0xffff_ffff)))
      return { valid: false, reason: "invalid_configuration" };

    const publicRaw = strictBase64(publicKey, 32);
    if (!publicRaw) return { valid: false, reason: "invalid_configuration" };
    const spki = Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"), publicRaw,
    ]);
    const keyObject = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
    if (!crypto.verify(null, p.body, keyObject, p.signature))
      return { valid: false, reason: "bad_signature" };
    if (p.product !== product)
      return { valid: false, reason: "wrong_product", found: p.product };

    let activated = null;
    if (p.expiresDays !== null || p.updatesDays !== null) {
      if (activatedAt !== null && !validDate(activatedAt))
        return { valid: false, reason: "storage_failure" };
      activated = activatedAt ?? now;
    }
    if (p.updatesDays !== null && !validDate(buildDate))
      return { valid: false, reason: "invalid_configuration" };

    const effectiveExpiresAt = p.expiresDays !== null
      ? new Date((unixDay(activated) + p.expiresDays) * DAY) : null;
    const effectiveUpdatesUntil = p.updatesDays !== null
      ? new Date((unixDay(activated) + p.updatesDays) * DAY) : null;
    if (effectiveExpiresAt && unixDay(now) > unixDay(effectiveExpiresAt))
      return { valid: false, reason: "expired", on: effectiveExpiresAt };
    if (effectiveUpdatesUntil && unixDay(buildDate) > unixDay(effectiveUpdatesUntil))
      return { valid: false, reason: "updates_expired", on: effectiveUpdatesUntil };

    let acceptedDenylist = null;
    if (denylist !== null) {
      acceptedDenylist = verifyDenylist(denylist, product, keyObject, minimumDenylistSequence);
      if (!acceptedDenylist.ok)
        return { valid: false, reason: "bad_denylist" };
      const hit = acceptedDenylist.entries.find((entry) => entry.key_id === p.keyID);
      if (hit) return {
        valid: false, reason: "revoked", note: hit.note,
        denylistSequence: acceptedDenylist.sequence,
      };
    }

    return { valid: true, info: {
      product: p.product,
      keyID: p.keyID,
      issuedAt: new Date(p.issuedDay * DAY),
      expiresDurationDays: p.expiresDays,
      updatesDurationDays: p.updatesDays,
      isLifetime: p.expiresDays === null && p.updatesDays === null,
      activatedAt: activated,
      effectiveExpiresAt,
      effectiveUpdatesUntil,
      denylistSequence: acceptedDenylist?.sequence ?? null,
    } };
  } catch {
    return { valid: false, reason: "invalid_configuration" };
  }
}
