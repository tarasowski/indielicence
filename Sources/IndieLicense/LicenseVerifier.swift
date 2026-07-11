//
//  LicenseVerifier.swift — IndieLicense single-file verifier
//
//  Drop this one file into your app to validate IndieLicense keys fully
//  offline. It contains no secrets: only your Ed25519 PUBLIC key is embedded,
//  which can verify keys but never create them.
//
//  This file is intentionally readable top-to-bottom — it is a trust
//  artifact. It imports only Apple system frameworks: CryptoKit (Ed25519),
//  Foundation, and Security (Keychain persistence). It makes no network
//  calls and collects no data.
//
//  Format: see SPEC.md in https://github.com/… (the spec is normative).
//  License: MIT.
//

import CryptoKit
import Foundation
import Security

// MARK: - Public API

/// Everything an app wants to show about a valid license.
public struct LicenseInfo: Equatable {
    public let product: String
    public let keyID: UInt32
    /// When the key was minted. Informational only — never used in validation math.
    public let issuedAt: Date
    /// Days from activation until the app stops working (trial keys). nil = no hard expiry.
    public let expiresDurationDays: UInt16?
    /// Days from activation during which released app versions are covered. nil = all versions, forever.
    public let updatesDurationDays: UInt16?
    /// True when neither duration is set: the key unlocks every version, forever.
    public let isLifetime: Bool
    /// activatedAt + expiresDurationDays. nil unless this is a trial key.
    public let effectiveExpiresAt: Date?
    /// activatedAt + updatesDurationDays. nil when the key has no update cutoff.
    public let effectiveUpdatesUntil: Date?
}

public enum LicenseInvalidReason: Equatable {
    case malformed(String)         // not decodable as a license key
    case unsupportedVersion(UInt8) // format version this verifier doesn't know
    case badSignature              // payload does not verify against the public key
    case wrongProduct(found: String)
    case expired(on: Date)         // trial window has passed — the app should lock
    case updatesExpired(on: Date)  // this BUILD is newer than the update window —
                                   // show "renew for updates", not "invalid key"
    case revoked(note: String?)
    case badDenylist(String)       // bundled denylist is unreadable or badly signed
}

public enum LicenseValidationResult: Equatable {
    case valid(LicenseInfo)
    case invalid(LicenseInvalidReason)
}

/// Stores the first-activation date per key. `LicenseStore` (Keychain) is the
/// default; tests or unusual setups can substitute their own.
public protocol LicenseActivationDateStore {
    /// Returns the stored first-activation date for a key, stamping it with
    /// the current date on first call. Must return the same date afterwards.
    func activatedAt(for keyID: UInt32) -> Date
}

public struct LicenseValidator {
    public let publicKey: String
    public let product: String
    public let buildDate: Date
    private let denylist: Result<Denylist, LicenseInvalidReason>?
    private let activationDates: LicenseActivationDateStore

    /// - Parameters:
    ///   - publicKey: base64 of the raw 32-byte Ed25519 public key (printed by `indielicense init`).
    ///   - product: your product id — keys minted for anything else are rejected.
    ///   - buildDate: when THIS build was released; compared against the update
    ///     window. Use `LicenseValidator.compiledDate` or hardcode a date per release.
    ///   - denylist: optional URL of a bundled, signed `<product>.denylist.json`.
    ///   - activationDates: where first-activation dates live. Default: Keychain.
    public init(
        publicKey: String,
        product: String,
        buildDate: Date = LicenseValidator.compiledDate,
        denylist: URL? = nil,
        activationDates: LicenseActivationDateStore = LicenseStore.shared
    ) {
        self.publicKey = publicKey
        self.product = product
        self.buildDate = buildDate
        self.activationDates = activationDates
        self.denylist = denylist.map { Denylist.load(from: $0, product: product, publicKeyBase64: publicKey) }
    }

    /// The modification date of the running executable — stamped when the app
    /// was built/signed, so it tracks the release date with zero setup. If it
    /// can't be read, falls back to the distant past, which always PASSES the
    /// update-window check (fail open, never lock out a paying user).
    public static var compiledDate: Date {
        if let path = Bundle.main.executablePath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attributes[.modificationDate] as? Date {
            return date
        }
        return .distantPast
    }

    /// Validate a pasted key. Call this on every launch with the stored key.
    /// `now` exists for tests; leave it defaulted in real apps.
    public func validate(_ key: String, now: Date = Date()) -> LicenseValidationResult {
        // 1. Decode + 2. check format version.
        let payload: LicensePayload
        do { payload = try LicensePayload.decode(key) } catch let reason as LicenseInvalidReason {
            return .invalid(reason)
        } catch { return .invalid(.malformed("undecodable")) }

        // 3. Verify the Ed25519 signature over the exact payload bytes.
        guard let keyData = Data(base64Encoded: publicKey),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return .invalid(.malformed("public key is not valid base64/Ed25519")) }
        guard verifier.isValidSignature(payload.signature, for: payload.signedBytes)
        else { return .invalid(.badSignature) }

        // 4. The key must be for THIS product.
        guard payload.product == product else { return .invalid(.wrongProduct(found: payload.product)) }

        // First successful validation of a duration-based key stamps the
        // activation date (plain wall clock, once — see SPEC.md). All
        // effective dates derive from it.
        var effectiveExpiresAt: Date?
        var effectiveUpdatesUntil: Date?
        if payload.expiresDurationDays != nil || payload.updatesDurationDays != nil {
            let activatedDay = unixDay(of: activationDates.activatedAt(for: payload.keyID))
            if let days = payload.expiresDurationDays {
                effectiveExpiresAt = date(ofUnixDay: activatedDay + Int(days))
            }
            if let days = payload.updatesDurationDays {
                effectiveUpdatesUntil = date(ofUnixDay: activatedDay + Int(days))
            }
        }

        // 5. Trial keys: hard-expire when the wall clock passes the window.
        if let expiresAt = effectiveExpiresAt, unixDay(of: now) > unixDay(of: expiresAt) {
            return .invalid(.expired(on: expiresAt))
        }

        // 6. Update window: compared against the BUILD date, not the clock —
        //    an outdated build keeps working forever; only newer builds ask to renew.
        if let updatesUntil = effectiveUpdatesUntil, unixDay(of: buildDate) > unixDay(of: updatesUntil) {
            return .invalid(.updatesExpired(on: updatesUntil))
        }

        // 7. The signed denylist, if one is bundled.
        if let denylist {
            switch denylist {
            case .failure(let reason): return .invalid(reason)
            case .success(let list):
                if let entry = list.revoked.first(where: { $0.keyID == payload.keyID }) {
                    return .invalid(.revoked(note: entry.note))
                }
            }
        }

        return .valid(LicenseInfo(
            product: payload.product,
            keyID: payload.keyID,
            issuedAt: date(ofUnixDay: Int(payload.issuedDay)),
            expiresDurationDays: payload.expiresDurationDays,
            updatesDurationDays: payload.updatesDurationDays,
            isLifetime: payload.expiresDurationDays == nil && payload.updatesDurationDays == nil,
            effectiveExpiresAt: effectiveExpiresAt,
            effectiveUpdatesUntil: effectiveUpdatesUntil
        ))
    }
}

// MARK: - Wire format (SPEC.md §Payload is normative)

/// The decoded binary payload of a license key.
public struct LicensePayload {
    public let version: UInt8
    public let product: String
    public let keyID: UInt32
    public let issuedDay: UInt16       // unix days since 1970-01-01 UTC
    public let expiresDurationDays: UInt16?
    public let updatesDurationDays: UInt16?
    public let signedBytes: Data       // the exact bytes the signature covers
    public let signature: Data         // 64-byte Ed25519 signature

    /// Decodes a human-format key. Performs NO signature check — pair with
    /// `LicenseValidator` for that. Throws `LicenseInvalidReason`.
    public static func decode(_ key: String) throws -> LicensePayload {
        // Everything before the first "-" is the display prefix; the product
        // id that counts is the one inside the signed payload.
        let groups = key.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
        guard groups.count >= 2 else { throw LicenseInvalidReason.malformed("expected PREFIX-XXXXX-…") }
        let raw = try crockfordDecode(groups.dropFirst().joined())

        guard raw.count > 64 else { throw LicenseInvalidReason.malformed("too short") }
        let signature = raw.suffix(64)
        let body = raw.prefix(raw.count - 64)

        var cursor = body.startIndex
        func take(_ n: Int) throws -> Data {
            guard body.distance(from: cursor, to: body.endIndex) >= n
            else { throw LicenseInvalidReason.malformed("truncated payload") }
            defer { cursor = body.index(cursor, offsetBy: n) }
            return Data(body[cursor..<body.index(cursor, offsetBy: n)])  // rebased copy — slices keep parent indices
        }

        let version = try take(1)[0]
        guard version == 1 else { throw LicenseInvalidReason.unsupportedVersion(version) }
        let productLength = Int(try take(1)[0])
        guard (1...64).contains(productLength) else { throw LicenseInvalidReason.malformed("bad product length") }
        guard let product = String(data: try take(productLength), encoding: .utf8),
              product.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        else { throw LicenseInvalidReason.malformed("product id must be lowercase a-z0-9") }
        let keyID = try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let issuedDay = try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
        let flags = try take(1)[0]
        guard flags & ~0b11 == 0 else { throw LicenseInvalidReason.malformed("unknown flag bits") }
        let expires: UInt16? = flags & 0b01 != 0 ? try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) } : nil
        let updates: UInt16? = flags & 0b10 != 0 ? try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) } : nil
        guard cursor == body.endIndex else { throw LicenseInvalidReason.malformed("trailing bytes") }

        return LicensePayload(
            version: version, product: product, keyID: keyID, issuedDay: issuedDay,
            expiresDurationDays: expires, updatesDurationDays: updates,
            signedBytes: Data(body), signature: Data(signature)
        )
    }
}

// MARK: - Signed denylist

struct Denylist {
    struct Entry { let keyID: UInt32; let note: String? }
    let revoked: [Entry]

    /// Loads and verifies `<product>.denylist.json`. The signature covers
    /// "indielicense-denylist-v1", the product, and the ascending key ids,
    /// joined by "\n" (notes are informational and unsigned — see SPEC.md).
    static func load(from url: URL, product: String, publicKeyBase64: String) -> Result<Denylist, LicenseInvalidReason> {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == "indielicense-denylist-v1",
              let listProduct = json["product"] as? String,
              let entries = json["revoked"] as? [[String: Any]],
              let signatureBase64 = json["signature"] as? String,
              let signature = Data(base64Encoded: signatureBase64)
        else { return .failure(.badDenylist("unreadable or wrong shape")) }
        guard listProduct == product else { return .failure(.badDenylist("denylist is for '\(listProduct)'")) }

        var revoked: [Entry] = []
        for entry in entries {
            guard let id = entry["key_id"] as? Int, id >= 0, id <= UInt32.max
            else { return .failure(.badDenylist("bad key_id")) }
            revoked.append(Entry(keyID: UInt32(id), note: entry["note"] as? String))
        }
        revoked.sort { $0.keyID < $1.keyID }

        let message = (["indielicense-denylist-v1", product] + revoked.map { String($0.keyID) })
            .joined(separator: "\n")
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              verifier.isValidSignature(signature, for: Data(message.utf8))
        else { return .failure(.badDenylist("signature does not verify")) }
        return .success(Denylist(revoked: revoked))
    }
}

// MARK: - Keychain persistence

/// Persists the pasted license key and per-key activation dates in the user's
/// Keychain, so both survive reinstalls. No clock-rollback guards, by design.
public final class LicenseStore: LicenseActivationDateStore {
    public static let shared = LicenseStore()
    private let service: String

    public init(service: String? = nil) {
        self.service = service ?? "IndieLicense:" + (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    /// Persist the key the customer pasted, so you can re-validate on launch.
    public func save(key: String) { write(account: "license-key", value: key) }
    public func load() -> String? { read(account: "license-key") }

    /// First call stamps today's date (plain `Date()`); every later call
    /// returns that same stored date. This anchors trial/update windows to
    /// the customer's activation, not to when the key batch was generated.
    public func activatedAt(for keyID: UInt32) -> Date {
        let account = "activated:\(keyID)"
        if let stored = read(account: account), let day = Int(stored) {
            return date(ofUnixDay: day)
        }
        let today = unixDay(of: Date())
        write(account: account, value: String(today))
        return date(ofUnixDay: today)
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func read(account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func write(account: String, value: String) {
        SecItemDelete(query(account: account) as CFDictionary)
        var q = query(account: account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Small shared helpers

/// All date math is whole UTC days: unixDay = floor(secondsSinceEpoch / 86400).
/// A window is inclusive of its last day (expired only when now is PAST it).
func unixDay(of date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86400)) }
func date(ofUnixDay day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86400) }

/// Crockford base32 (no I, L, O, U): case-insensitive, O→0, I/L→1, dashes ignored.
func crockfordDecode(_ text: String) throws -> Data {
    let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    var values: [Character: UInt32] = ["O": 0, "I": 1, "L": 1]
    for (i, c) in alphabet.enumerated() { values[c] = UInt32(i) }

    var accumulator: UInt32 = 0, bits = 0
    var out = Data()
    for character in text.uppercased() where character != "-" {
        guard let value = values[character]
        else { throw LicenseInvalidReason.malformed("invalid character '\(character)'") }
        accumulator = accumulator << 5 | value
        bits += 5
        if bits >= 8 {
            bits -= 8
            out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
        }
    }
    // Trailing padding bits must be zero, or the string was corrupted.
    guard accumulator & ((1 << bits) - 1) == 0 else { throw LicenseInvalidReason.malformed("bad trailing bits") }
    return out
}

extension LicenseInvalidReason: Error {}
