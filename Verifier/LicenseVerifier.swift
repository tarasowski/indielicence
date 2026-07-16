//
//  LicenseVerifier.swift — IndieLicense single-file verifier
//
//  Drop this file into an app to validate IndieLicense keys fully offline.
//  It contains no secrets and makes no network calls.
//

import CryptoKit
import Foundation
import Security

// MARK: - Public API

public struct LicenseInfo: Equatable {
    public let product: String
    public let keyID: UInt32
    public let issuedAt: Date
    public let expiresDurationDays: UInt16?
    public let updatesDurationDays: UInt16?
    public let isLifetime: Bool
    public let effectiveExpiresAt: Date?
    public let effectiveUpdatesUntil: Date?
    /// The authenticated denylist sequence accepted during validation, if any.
    public let denylistSequence: UInt32?
}

public enum LicenseInvalidReason: Equatable {
    case malformed(String)
    case unsupportedVersion(UInt8)
    case badSignature
    case wrongProduct(found: String)
    case expired(on: Date)
    case updatesExpired(on: Date)
    case revoked(note: String?)
    case badDenylist(String)
    case invalidConfiguration(String)
    case storageFailure(String)
}

public enum LicenseValidationResult: Equatable {
    case valid(LicenseInfo)
    case invalid(LicenseInvalidReason)
}

/// Persistent security state used for activation anchoring and denylist
/// rollback detection. Implementations must be atomic and must never silently
/// replace corrupt or unreadable state.
public protocol LicenseStateStore {
    func activatedAt(for licenseIdentifier: String) throws -> Date
    func highestDenylistSequence(for productIdentifier: String) throws -> UInt32?
    func recordDenylistSequence(_ sequence: UInt32, for productIdentifier: String) throws
}

public struct LicenseValidator {
    public let publicKey: String
    public let product: String
    public let buildDate: Date
    private let denylist: Result<Denylist, LicenseInvalidReason>?
    private let stateStore: LicenseStateStore

    /// `buildDate` must be a constant embedded in the signed app binary. Never
    /// derive it from file modification metadata or the current wall clock.
    public init(
        publicKey: String,
        product: String,
        buildDate: Date,
        denylist: URL? = nil,
        stateStore: LicenseStateStore = LicenseStore.shared
    ) {
        self.publicKey = publicKey
        self.product = product
        self.buildDate = buildDate
        self.stateStore = stateStore
        self.denylist = denylist.map {
            Denylist.load(from: $0, product: product, publicKeyBase64: publicKey)
        }
    }

    public func validate(_ key: String, now: Date = Date()) -> LicenseValidationResult {
        let payload: LicensePayload
        do { payload = try LicensePayload.decode(key) }
        catch let reason as LicenseInvalidReason { return .invalid(reason) }
        catch { return .invalid(.malformed("undecodable")) }

        guard isFiniteDate(now), isFiniteDate(buildDate) else {
            return .invalid(.invalidConfiguration("now and buildDate must be finite dates"))
        }
        guard isValidProductID(product) else {
            return .invalid(.invalidConfiguration("configured product must be 1-64 lowercase a-z0-9 characters"))
        }
        guard let keyData = strictBase64(publicKey, expectedBytes: 32),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return .invalid(.invalidConfiguration("public key is not canonical base64 Ed25519 material")) }

        guard verifier.isValidSignature(payload.signature, for: payload.signedBytes)
        else { return .invalid(.badSignature) }
        guard payload.product == product else {
            return .invalid(.wrongProduct(found: payload.product))
        }

        let licenseIdentifier = stableIdentifier(
            fields: [Data(product.utf8), keyData, payload.signedBytes])
        var effectiveExpiresAt: Date?
        var effectiveUpdatesUntil: Date?
        if payload.expiresDurationDays != nil || payload.updatesDurationDays != nil {
            let activatedAt: Date
            do { activatedAt = try stateStore.activatedAt(for: licenseIdentifier) }
            catch { return .invalid(.storageFailure("activation date: \(error)")) }
            guard isFiniteDate(activatedAt) else {
                return .invalid(.storageFailure("stored activation date is invalid"))
            }
            let activatedDay = unixDay(of: activatedAt)
            if let days = payload.expiresDurationDays {
                effectiveExpiresAt = date(ofUnixDay: activatedDay + Int(days))
            }
            if let days = payload.updatesDurationDays {
                effectiveUpdatesUntil = date(ofUnixDay: activatedDay + Int(days))
            }
        }

        if let expiresAt = effectiveExpiresAt, unixDay(of: now) > unixDay(of: expiresAt) {
            return .invalid(.expired(on: expiresAt))
        }
        if let updatesUntil = effectiveUpdatesUntil,
           unixDay(of: buildDate) > unixDay(of: updatesUntil) {
            return .invalid(.updatesExpired(on: updatesUntil))
        }

        var acceptedDenylistSequence: UInt32?
        if let denylist {
            switch denylist {
            case .failure(let reason): return .invalid(reason)
            case .success(let list):
                let productIdentifier = stableIdentifier(fields: [Data(product.utf8), keyData])
                do {
                    let highest = try stateStore.highestDenylistSequence(for: productIdentifier)
                    if let highest, list.sequence < highest {
                        return .invalid(.badDenylist(
                            "rollback detected: sequence \(list.sequence) is older than \(highest)"))
                    }
                    if highest == nil || list.sequence > highest! {
                        try stateStore.recordDenylistSequence(list.sequence, for: productIdentifier)
                    }
                } catch {
                    return .invalid(.storageFailure("denylist sequence: \(error)"))
                }
                acceptedDenylistSequence = list.sequence
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
            effectiveUpdatesUntil: effectiveUpdatesUntil,
            denylistSequence: acceptedDenylistSequence
        ))
    }
}

// MARK: - Wire format

public struct LicensePayload {
    public let version: UInt8
    public let product: String
    public let keyID: UInt32
    public let issuedDay: UInt16
    public let expiresDurationDays: UInt16?
    public let updatesDurationDays: UInt16?
    public let signedBytes: Data
    public let signature: Data

    public static func decode(_ key: String) throws -> LicensePayload {
        guard key.utf8.count <= 512 else {
            throw LicenseInvalidReason.malformed("key is too long")
        }
        let groups = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count >= 2, !groups[0].isEmpty else {
            throw LicenseInvalidReason.malformed("expected PREFIX-XXXXX-...")
        }
        let raw = try crockfordDecode(groups.dropFirst().joined())
        guard raw.count > 64 else { throw LicenseInvalidReason.malformed("too short") }
        let signature = raw.suffix(64)
        let body = raw.prefix(raw.count - 64)

        var cursor = body.startIndex
        func take(_ n: Int) throws -> Data {
            guard n >= 0, body.distance(from: cursor, to: body.endIndex) >= n else {
                throw LicenseInvalidReason.malformed("truncated payload")
            }
            let end = body.index(cursor, offsetBy: n)
            defer { cursor = end }
            return Data(body[cursor..<end])
        }

        let version = try take(1)[0]
        guard version == 1 else { throw LicenseInvalidReason.unsupportedVersion(version) }
        let productLength = Int(try take(1)[0])
        guard (1...64).contains(productLength) else {
            throw LicenseInvalidReason.malformed("bad product length")
        }
        let productData = try take(productLength)
        guard productData.allSatisfy({ asciiProductByte($0) }),
              let product = String(data: productData, encoding: .ascii) else {
            throw LicenseInvalidReason.malformed("product id must be lowercase a-z0-9")
        }
        let keyID = try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let issuedDay = try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
        let flags = try take(1)[0]
        guard flags & ~0b11 == 0 else {
            throw LicenseInvalidReason.malformed("unknown flag bits")
        }
        let expires: UInt16? = flags & 0b01 != 0
            ? try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) } : nil
        let updates: UInt16? = flags & 0b10 != 0
            ? try take(2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) } : nil
        guard cursor == body.endIndex else {
            throw LicenseInvalidReason.malformed("trailing bytes")
        }
        return LicensePayload(
            version: version, product: product, keyID: keyID, issuedDay: issuedDay,
            expiresDurationDays: expires, updatesDurationDays: updates,
            signedBytes: Data(body), signature: Data(signature))
    }
}

// MARK: - Signed denylist v1

private struct DenylistDocument: Decodable {
    struct Entry: Decodable {
        let keyID: UInt32
        let note: String?
        enum CodingKeys: String, CodingKey { case keyID = "key_id", note }
    }
    let format: String
    let product: String
    let sequence: UInt32
    let revoked: [Entry]
    let signature: String
}

private struct Denylist {
    struct Entry { let keyID: UInt32; let note: String? }
    let sequence: UInt32
    let revoked: [Entry]

    static func load(
        from url: URL, product: String, publicKeyBase64: String
    ) -> Result<Denylist, LicenseInvalidReason> {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 2_000_000 else {
                return .failure(.badDenylist("file must be a regular file no larger than 2 MB"))
            }
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(DenylistDocument.self, from: data)
            guard document.format == "indielicense-denylist-v1" else {
                return .failure(.badDenylist("unsupported denylist format"))
            }
            guard document.product == product else {
                return .failure(.badDenylist("denylist is for '\(document.product)'"))
            }
            guard document.sequence >= 1, document.revoked.count <= 100_000 else {
                return .failure(.badDenylist("invalid sequence or too many entries"))
            }
            guard document.revoked.allSatisfy({ ($0.note?.utf8.count ?? 0) <= 4_096 }) else {
                return .failure(.badDenylist("note exceeds 4096 UTF-8 bytes"))
            }
            let sorted = document.revoked.sorted { $0.keyID < $1.keyID }
            guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.keyID != $1.keyID }) else {
                return .failure(.badDenylist("duplicate key_id"))
            }
            let signature = strictBase64(document.signature, expectedBytes: 64)
            let keyData = strictBase64(publicKeyBase64, expectedBytes: 32)
            guard let signature, let keyData,
                  let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  verifier.isValidSignature(
                    signature,
                    for: denylistMessage(
                        product: product, sequence: document.sequence, entries: sorted)) else {
                return .failure(.badDenylist("signature does not verify"))
            }
            return .success(Denylist(
                sequence: document.sequence,
                revoked: sorted.map { Entry(keyID: $0.keyID, note: $0.note) }))
        } catch {
            return .failure(.badDenylist("unreadable or wrong shape: \(error)"))
        }
    }
}

private func denylistMessage(
    product: String, sequence: UInt32, entries: [DenylistDocument.Entry]
) -> Data {
    let lines = ["indielicense-denylist-v1", product, String(sequence)] + entries.map {
        let encodedNote = $0.note.map { "+" + Data($0.utf8).base64EncodedString() } ?? "-"
        return "\($0.keyID)\t\(encodedNote)"
    }
    return Data(lines.joined(separator: "\n").utf8)
}

// MARK: - File persistence

/// Stores license state as tamper-evident files under
/// ~/Library/Application Support/IndieLicense/<service>/. Files are readable
/// by every binary the customer runs — unlike the Keychain, whose per-item
/// code-signature ACL raises a password dialog whenever a rebuilt, re-signed,
/// or sibling executable (a bundled helper) touches the item.
/// Existing Keychain items from older versions are migrated silently once,
/// then deleted so the dialog can never appear again.
public final class LicenseStore: LicenseStateStore {
    public static let shared = LicenseStore()
    private static let operationLock = NSLock()
    private let service: String
    private let directory: URL
    private let macKey: SymmetricKey
    private var migrationChecked = false

    public init(service: String? = nil) {
        let service = service ?? "IndieLicense:" +
            (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        self.service = service
        self.directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IndieLicense", isDirectory: true)
            .appendingPathComponent(Self.sanitized(service), isDirectory: true)
        // Obfuscation, not secrecy: makes casual editing of the files fail
        // closed as .corrupt instead of silently changing license state.
        self.macKey = SymmetricKey(
            data: SHA256.hash(data: Data(("indielicense-store-v1\n" + service).utf8)))
    }

    public func save(key: String) throws {
        try Self.operationLock.withLock {
            migrateFromKeychainIfNeeded()
            try upsert(account: "license-key", value: key)
        }
    }

    public func load() throws -> String? {
        try Self.operationLock.withLock {
            migrateFromKeychainIfNeeded()
            return try read(account: "license-key")
        }
    }

    public func activatedAt(for licenseIdentifier: String) throws -> Date {
        try Self.operationLock.withLock {
            migrateFromKeychainIfNeeded()
            let account = "activated:\(licenseIdentifier)"
            if let stored = try read(account: account) {
                guard let day = Int(stored) else { throw StoreError.corrupt(account) }
                return date(ofUnixDay: day)
            }
            let today = unixDay(of: Date())
            let inserted = try insertIfAbsent(account: account, value: String(today))
            if inserted { return date(ofUnixDay: today) }
            guard let stored = try read(account: account), let day = Int(stored) else {
                throw StoreError.corrupt(account)
            }
            return date(ofUnixDay: day)
        }
    }

    public func highestDenylistSequence(for productIdentifier: String) throws -> UInt32? {
        try Self.operationLock.withLock {
            migrateFromKeychainIfNeeded()
            guard let stored = try read(account: "denylist:\(productIdentifier)") else { return nil }
            guard let sequence = UInt32(stored), sequence >= 1 else {
                throw StoreError.corrupt("denylist:\(productIdentifier)")
            }
            return sequence
        }
    }

    public func recordDenylistSequence(_ sequence: UInt32, for productIdentifier: String) throws {
        guard sequence >= 1 else { throw StoreError.corrupt("denylist sequence") }
        try Self.operationLock.withLock {
            migrateFromKeychainIfNeeded()
            let account = "denylist:\(productIdentifier)"
            if let stored = try read(account: account) {
                guard let current = UInt32(stored) else { throw StoreError.corrupt(account) }
                guard sequence >= current else { throw StoreError.rollback }
                if sequence == current { return }
            }
            try upsert(account: account, value: String(sequence))
        }
    }

    // MARK: File primitives

    private static func sanitized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
    }

    private func fileURL(account: String) -> URL {
        directory.appendingPathComponent(Self.sanitized(account), isDirectory: false)
    }

    /// One line per file: "v1<TAB>base64(value)<TAB>hex-HMAC". The MAC binds
    /// service and the unsanitized account name so files cannot be renamed or
    /// copied between accounts to alter state.
    private func encode(account: String, value: String) -> Data {
        let payload = Data(value.utf8).base64EncodedString()
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(service)\n\(account)\n\(payload)".utf8), using: macKey)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return Data("v1\t\(payload)\t\(hex)\n".utf8)
    }

    private func read(account: String) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(account: account))
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw StoreError.status("read", errSecIO)
        }
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let decoded = Data(base64Encoded: String(parts[1])),
              let value = String(data: decoded, encoding: .utf8),
              encode(account: account, value: value) == Data(line.utf8) + Data("\n".utf8) else {
            throw StoreError.corrupt(account)
        }
        return value
    }

    /// Cross-process exclusive create: write to a unique temp file, then
    /// hard-link it into place — link(2) fails atomically if the name exists.
    private func insertIfAbsent(account: String, value: String) throws -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let temp = directory.appendingPathComponent(
                ".tmp-" + ProcessInfo.processInfo.globallyUniqueString)
            try encode(account: account, value: value).write(to: temp)
            defer { try? fm.removeItem(at: temp) }
            do {
                try fm.linkItem(at: temp, to: fileURL(account: account))
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                return false
            }
            return true
        } catch {
            throw StoreError.status("insert", errSecIO)
        }
    }

    private func upsert(account: String, value: String) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encode(account: account, value: value)
                .write(to: fileURL(account: account), options: .atomic)
        } catch {
            throw StoreError.status("update", errSecIO)
        }
    }

    // MARK: Legacy Keychain migration

    /// Copies items this binary can read without a password dialog into the
    /// file store, then deletes every Keychain item under this service so the
    /// signature-ACL prompt is gone for good. Items the ACL refuses to release
    /// silently are dropped: a keyless trial re-anchors on its own and a paid
    /// key can be pasted again, whereas keeping the item would keep the dialog.
    private func migrateFromKeychainIfNeeded() {
        guard !migrationChecked else { return }
        migrationChecked = true

        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true]
        var listResult: AnyObject?
        guard SecItemCopyMatching(listQuery as CFDictionary, &listResult) == errSecSuccess,
              let items = listResult as? [[String: Any]], !items.isEmpty else { return }

        // Reads that would raise the keychain password dialog must fail with
        // errSecInteractionNotAllowed instead — migration is silent or not at all.
        _ = indielicense_SecKeychainSetUserInteractionAllowed(false)
        defer { _ = indielicense_SecKeychainSetUserInteractionAllowed(true) }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account]
            var readQuery = query
            readQuery[kSecReturnData as String] = true
            readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var data: AnyObject?
            if SecItemCopyMatching(readQuery as CFDictionary, &data) == errSecSuccess,
               let data = data as? Data, let value = String(data: data, encoding: .utf8) {
                _ = try? insertIfAbsent(account: account, value: value)
            }
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// `SecKeychainSetUserInteractionAllowed` is deprecated (macOS 10.10) yet still
/// the only call that suppresses the legacy login-keychain ACL dialog during
/// migration; its per-item replacements do not cover file-based keychains.
/// Binding the symbol directly keeps builds with -warnings-as-errors clean.
@_silgen_name("SecKeychainSetUserInteractionAllowed")
private func indielicense_SecKeychainSetUserInteractionAllowed(_ state: DarwinBoolean) -> OSStatus

private enum StoreError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case corrupt(String)
    case rollback
    var description: String {
        switch self {
        case .status(let operation, let status): return "License store \(operation) failed (OSStatus \(status))"
        case .corrupt(let account): return "License store value '\(account)' is corrupt"
        case .rollback: return "denylist sequence rollback"
        }
    }
}

// MARK: - Helpers

private func isFiniteDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
private func unixDay(of date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }
private func date(ofUnixDay day: Int) -> Date {
    Date(timeIntervalSince1970: Double(day) * 86_400)
}
private func asciiProductByte(_ byte: UInt8) -> Bool {
    (97...122).contains(byte) || (48...57).contains(byte)
}
private func isValidProductID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (1...64).contains(bytes.count) && bytes.allSatisfy(asciiProductByte)
}
private func strictBase64(_ text: String, expectedBytes: Int) -> Data? {
    guard let data = Data(base64Encoded: text), data.count == expectedBytes,
          data.base64EncodedString() == text else { return nil }
    return data
}
private func stableIdentifier(fields: [Data]) -> String {
    var input = Data()
    for field in fields {
        var length = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
        input.append(field)
    }
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

private func crockfordDecode(_ text: String) throws -> Data {
    var accumulator: UInt32 = 0
    var bits = 0
    var out = Data()
    for byte in text.utf8 {
        let upper: UInt8
        switch byte {
        case 97...122: upper = byte - 32
        default: upper = byte
        }
        let value: UInt32
        switch upper {
        case 48...57: value = UInt32(upper - 48)
        case 65: value = 10
        case 66: value = 11
        case 67: value = 12
        case 68: value = 13
        case 69: value = 14
        case 70: value = 15
        case 71: value = 16
        case 72: value = 17
        case 74: value = 18
        case 75: value = 19
        case 77: value = 20
        case 78: value = 21
        case 80: value = 22
        case 81: value = 23
        case 82: value = 24
        case 83: value = 25
        case 84: value = 26
        case 86: value = 27
        case 87: value = 28
        case 88: value = 29
        case 89: value = 30
        case 90: value = 31
        case 79: value = 0
        case 73, 76: value = 1
        default: throw LicenseInvalidReason.malformed("invalid non-Crockford character")
        }
        accumulator = accumulator << 5 | value
        bits += 5
        if bits >= 8 {
            bits -= 8
            out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
        }
    }
    let mask: UInt32 = bits == 0 ? 0 : (UInt32(1) << UInt32(bits)) - 1
    guard accumulator & mask == 0 else {
        throw LicenseInvalidReason.malformed("bad trailing bits")
    }
    return out
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

extension LicenseInvalidReason: Error {}
