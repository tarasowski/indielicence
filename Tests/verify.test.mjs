// Runs the JS reference verifier against the shared test vectors.
// Usage: node --test Tests/verify.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validateLicense } from "../Verifier/verify.mjs";

const vectors = JSON.parse(readFileSync(new URL("./vectors.json", import.meta.url)));
const base = {
  publicKey: vectors.public_key_base64,
  product: vectors.product,
  denylist: vectors.denylist,
  buildDate: new Date("2026-07-11T12:00:00Z"),
  now: new Date("2026-07-11T12:00:00Z"),
};

for (const c of vectors.cases) {
  test(`vector: ${c.name}`, () => {
    const result = validateLicense(c.key, base);
    if (c.expect === "valid") {
      assert.equal(result.valid, true, JSON.stringify(result));
      assert.equal(result.info.keyID, c.key_id);
      assert.equal(result.info.isLifetime, c.mode === "lifetime");
    } else {
      assert.equal(result.valid, false);
      assert.equal(result.reason, c.expect);
    }
  });
}

test("trial key expires after its window, counted from activation", () => {
  const trial = vectors.cases.find((c) => c.name === "trial_14_valid");
  const activatedAt = new Date("2026-08-01T00:00:00Z"); // sat unsold for weeks — irrelevant
  const inside = validateLicense(trial.key, { ...base, activatedAt, now: new Date("2026-08-15T23:00:00Z") });
  assert.equal(inside.valid, true, "day 14 is still inside the window");
  const outside = validateLicense(trial.key, { ...base, activatedAt, now: new Date("2026-08-16T01:00:00Z") });
  assert.deepEqual([outside.valid, outside.reason], [false, "expired"]);
});

test("updates key rejects newer builds but never old ones", () => {
  const updates = vectors.cases.find((c) => c.name === "updates_365_valid");
  const activatedAt = new Date("2026-07-11T00:00:00Z");
  const newerBuild = validateLicense(updates.key, { ...base, activatedAt,
    buildDate: new Date("2027-08-01T00:00:00Z"), now: new Date("2027-08-01T00:00:00Z") });
  assert.deepEqual([newerBuild.valid, newerBuild.reason], [false, "updates_expired"]);
  const oldBuild = validateLicense(updates.key, { ...base, activatedAt,
    buildDate: new Date("2026-08-01T00:00:00Z"), now: new Date("2030-01-01T00:00:00Z") });
  assert.equal(oldBuild.valid, true, "old builds keep working forever");
});

test("lifetime key never expires no matter the clock or build", () => {
  const lifetime = vectors.cases.find((c) => c.name === "lifetime_valid");
  const result = validateLicense(lifetime.key, { ...base,
    buildDate: new Date("2126-01-01T00:00:00Z"), now: new Date("2126-01-01T00:00:00Z") });
  assert.equal(result.valid, true);
  assert.equal(result.info.isLifetime, true);
});

test("tampered denylist signature is rejected", () => {
  const lifetime = vectors.cases.find((c) => c.name === "lifetime_valid");
  const forged = { ...vectors.denylist, revoked: [{ key_id: 1 }] }; // try to revoke key 1 without the private key
  const result = validateLicense(lifetime.key, { ...base, denylist: forged });
  assert.deepEqual([result.valid, result.reason], [false, "bad_denylist"]);
});
