//
//  Support.swift — key minting, file handling, and encoding for the CLI.
//  Everything secret-touching lives in the CLI; the shipped library and the
//  single-file verifier can only verify.
//

import CryptoKit
import Foundation
import IndieLicense

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

// MARK: - Crockford base32 (encoder; the verifier only ever needs the decoder)

let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

func crockfordEncode(_ data: Data) -> String {
    var out = ""
    var accumulator: UInt32 = 0, bits = 0
    for byte in data {
        accumulator = accumulator << 8 | UInt32(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            out.append(crockfordAlphabet[Int(accumulator >> UInt32(bits)) & 31])
        }
    }
    if bits > 0 {  // pad the final partial group with zero bits
        out.append(crockfordAlphabet[Int(accumulator << UInt32(5 - bits)) & 31])
    }
    return out
}

func grouped(_ text: String, every stride: Int = 5) -> String {
    var groups: [String] = []
    var remaining = Substring(text)
    while !remaining.isEmpty {
        groups.append(String(remaining.prefix(stride)))
        remaining = remaining.dropFirst(stride)
    }
    return groups.joined(separator: "-")
}

// MARK: - Payload encoding (mirror of LicensePayload.decode; SPEC.md is normative)

func encodePayload(
    product: String, keyID: UInt32, issuedDay: UInt16,
    expiresDurationDays: UInt16?, updatesDurationDays: UInt16?
) -> Data {
    var payload = Data()
    payload.append(1)  // format version
    let productBytes = Data(product.utf8)
    payload.append(UInt8(productBytes.count))
    payload.append(productBytes)
    withUnsafeBytes(of: keyID.bigEndian) { payload.append(contentsOf: $0) }
    withUnsafeBytes(of: issuedDay.bigEndian) { payload.append(contentsOf: $0) }
    var flags: UInt8 = 0
    if expiresDurationDays != nil { flags |= 0b01 }
    if updatesDurationDays != nil { flags |= 0b10 }
    payload.append(flags)
    if let days = expiresDurationDays { withUnsafeBytes(of: days.bigEndian) { payload.append(contentsOf: $0) } }
    if let days = updatesDurationDays { withUnsafeBytes(of: days.bigEndian) { payload.append(contentsOf: $0) } }
    return payload
}

func mintKey(
    privateKey: Curve25519.Signing.PrivateKey, product: String, keyID: UInt32,
    issuedDay: UInt16, expiresDurationDays: UInt16?, updatesDurationDays: UInt16?
) throws -> String {
    let payload = encodePayload(
        product: product, keyID: keyID, issuedDay: issuedDay,
        expiresDurationDays: expiresDurationDays, updatesDurationDays: updatesDurationDays)
    let signature = try privateKey.signature(for: payload)
    return product.uppercased() + "-" + grouped(crockfordEncode(payload + signature))
}

// MARK: - Key directory files

struct KeyDirectory {
    let url: URL

    init(path: String) {
        self.url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    func privateKeyURL(product: String) -> URL { url.appendingPathComponent("\(product).private") }
    func stateURL(product: String) -> URL { url.appendingPathComponent("\(product).state") }
    func denylistURL(product: String) -> URL { url.appendingPathComponent("\(product).denylist.json") }

    /// The private key file is a single base64 line of the raw 32-byte Ed25519 seed.
    func loadPrivateKey(product: String) throws -> Curve25519.Signing.PrivateKey {
        let fileURL = privateKeyURL(product: product)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw CLIError.message("no private key at \(fileURL.path) — run `indielicense init --product \(product)` or pass --key-dir")
        }
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw CLIError.message("\(fileURL.path) is not a valid IndieLicense private key file")
        }
        return key
    }

    func writePrivateKey(_ key: Curve25519.Signing.PrivateKey, product: String) throws {
        let fileURL = privateKeyURL(product: product)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.message("refusing to overwrite existing private key at \(fileURL.path)")
        }
        try (key.rawRepresentation.base64EncodedString() + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Sequential key ids continue across batches; state is a tiny JSON sidecar.
    func nextKeyID(product: String) throws -> UInt32 {
        guard let data = try? Data(contentsOf: stateURL(product: product)) else { return 1 }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let next = json["next_key_id"] as? Int, next >= 1, next <= UInt32.max else {
            throw CLIError.message("state file \(stateURL(product: product).path) is corrupt — refusing to risk reusing key ids")
        }
        return UInt32(next)
    }

    func saveNextKeyID(_ next: UInt32, product: String) throws {
        let json: [String: Any] = ["product": product, "next_key_id": Int(next)]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: stateURL(product: product), options: .atomic)
    }
}

// MARK: - Denylist (write side; the verifier holds the read side)

struct DenylistFile {
    var product: String
    var revoked: [(keyID: UInt32, note: String?)]

    static func load(from url: URL, product: String) throws -> DenylistFile {
        guard let data = try? Data(contentsOf: url) else {
            return DenylistFile(product: product, revoked: [])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == "indielicense-denylist-v1",
              json["product"] as? String == product,
              let entries = json["revoked"] as? [[String: Any]] else {
            throw CLIError.message("\(url.path) is not a valid denylist for '\(product)'")
        }
        let revoked = try entries.map { entry -> (UInt32, String?) in
            guard let id = entry["key_id"] as? Int, id >= 0, id <= UInt32.max else {
                throw CLIError.message("\(url.path) contains an invalid key_id")
            }
            return (UInt32(id), entry["note"] as? String)
        }
        return DenylistFile(product: product, revoked: revoked)
    }

    /// Signature covers "indielicense-denylist-v1", product, and ascending
    /// key ids joined by "\n". Notes are informational and unsigned.
    func write(to url: URL, privateKey: Curve25519.Signing.PrivateKey) throws {
        let sorted = revoked.sorted { $0.keyID < $1.keyID }
        let message = (["indielicense-denylist-v1", product] + sorted.map { String($0.keyID) })
            .joined(separator: "\n")
        let signature = try privateKey.signature(for: Data(message.utf8))
        let json: [String: Any] = [
            "format": "indielicense-denylist-v1",
            "product": product,
            "revoked": sorted.map { entry -> [String: Any] in
                var item: [String: Any] = ["key_id": Int(entry.keyID)]
                if let note = entry.note { item["note"] = note }
                return item
            },
            "signature": signature.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Small parsing/formatting helpers

/// Durations are given as "365d" (days). A bare number also means days.
func parseDurationDays(_ text: String, flag: String) throws -> UInt16 {
    var digits = Substring(text)
    if digits.hasSuffix("d") { digits = digits.dropLast() }
    guard let days = UInt16(digits), days > 0 else {
        throw CLIError.message("\(flag) expects a positive number of days like '365d', got '\(text)'")
    }
    return days
}

func validateProductID(_ product: String) throws {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
    guard (1...64).contains(product.count), product.allSatisfy({ allowed.contains($0) }) else {
        throw CLIError.message("product id must be 1–64 chars of lowercase a-z and 0-9 (got '\(product)')")
    }
}

func todayUnixDay() -> UInt16 { UInt16(clamping: Int(Date().timeIntervalSince1970 / 86400)) }

func isoDate(unixDay: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date(timeIntervalSince1970: Double(unixDay) * 86400))
}
