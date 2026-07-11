// Security-sensitive CLI support. All secret handling remains local.

import CryptoKit
import Darwin
import Foundation
import IndieLicense

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): return text } }
}

// MARK: - Crockford base32 and payload encoding

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
    if bits > 0 { out.append(crockfordAlphabet[Int(accumulator << UInt32(5 - bits)) & 31]) }
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

func encodePayload(
    product: String, keyID: UInt32, issuedDay: UInt16,
    expiresDurationDays: UInt16?, updatesDurationDays: UInt16?
) -> Data {
    var payload = Data([1, UInt8(product.utf8.count)])
    payload.append(Data(product.utf8))
    withUnsafeBytes(of: keyID.bigEndian) { payload.append(contentsOf: $0) }
    withUnsafeBytes(of: issuedDay.bigEndian) { payload.append(contentsOf: $0) }
    var flags: UInt8 = 0
    if expiresDurationDays != nil { flags |= 0b01 }
    if updatesDurationDays != nil { flags |= 0b10 }
    payload.append(flags)
    if let days = expiresDurationDays {
        withUnsafeBytes(of: days.bigEndian) { payload.append(contentsOf: $0) }
    }
    if let days = updatesDurationDays {
        withUnsafeBytes(of: days.bigEndian) { payload.append(contentsOf: $0) }
    }
    return payload
}

func mintKey(
    privateKey: Curve25519.Signing.PrivateKey, product: String, keyID: UInt32,
    issuedDay: UInt16, expiresDurationDays: UInt16?, updatesDurationDays: UInt16?
) throws -> String {
    let payload = encodePayload(
        product: product, keyID: keyID, issuedDay: issuedDay,
        expiresDurationDays: expiresDurationDays,
        updatesDurationDays: updatesDurationDays)
    let signature = try privateKey.signature(for: payload)
    return product.uppercased() + "-" + grouped(crockfordEncode(payload + signature))
}

// MARK: - Secure filesystem primitives

private func systemError(_ operation: String, path: String) -> CLIError {
    CLIError.message("\(operation) '\(path)' failed: \(String(cString: strerror(errno)))")
}

private func writeAll(fd: Int32, data: Data, path: String) throws {
    try data.withUnsafeBytes { raw in
        guard var cursor = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let written = Darwin.write(fd, cursor, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                throw systemError("write", path: path)
            }
            guard written > 0 else { throw CLIError.message("write '\(path)' made no progress") }
            remaining -= written
            cursor = cursor.advanced(by: written)
        }
    }
}

private func secureExclusiveWrite(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
    guard fd >= 0 else { throw systemError("create", path: url.path) }
    var succeeded = false
    defer {
        Darwin.close(fd)
        if !succeeded { try? FileManager.default.removeItem(at: url) }
    }
    try writeAll(fd: fd, data: data, path: url.path)
    guard fsync(fd) == 0 else { throw systemError("fsync", path: url.path) }
    succeeded = true
}

private func atomicSecureWrite(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
    try secureExclusiveWrite(data, to: temporary)
    guard rename(temporary.path, url.path) == 0 else {
        let error = systemError("replace", path: url.path)
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
    let directoryFD = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
    if directoryFD >= 0 { _ = fsync(directoryFD); Darwin.close(directoryFD) }
}

private func readSecureFile(
    _ url: URL, maxBytes: Int, missingAllowed: Bool, requireMode0600: Bool = false
) throws -> Data? {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    if fd < 0 {
        if missingAllowed && errno == ENOENT { return nil }
        throw systemError("open", path: url.path)
    }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw systemError("stat", path: url.path) }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw CLIError.message("'\(url.path)' must be a regular file (symlinks are refused)")
    }
    guard info.st_uid == getuid() else {
        throw CLIError.message("'\(url.path)' is not owned by the current user")
    }
    if requireMode0600 && info.st_mode & 0o077 != 0 {
        throw CLIError.message("'\(url.path)' permissions are too broad; expected 0600")
    }
    guard info.st_size >= 0, info.st_size <= maxBytes else {
        throw CLIError.message("'\(url.path)' exceeds the \(maxBytes)-byte safety limit")
    }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw systemError("read", path: url.path)
        }
        if count == 0 { break }
        guard data.count + count <= maxBytes else {
            throw CLIError.message("'\(url.path)' grew beyond the safety limit while reading")
        }
        data.append(buffer, count: count)
    }
    return data
}

private func validateSecureDirectory(_ url: URL, createIfMissing: Bool) throws {
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard createIfMissing else { throw CLIError.message("key directory does not exist: \(url.path)") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } else if !isDirectory.boolValue {
        throw CLIError.message("key directory is not a directory: \(url.path)")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
        throw CLIError.message("key directory is not owned by the current user: \(url.path)")
    }
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
    guard permissions & 0o077 == 0 else {
        throw CLIError.message("key directory permissions must be 0700 or stricter: \(url.path)")
    }
}

private func entryExists(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    if errno == ENOENT { return false }
    throw systemError("inspect", path: url.path)
}

// MARK: - Key directory and ID reservation

struct KeyDirectory {
    let url: URL

    init(path: String) {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    func privateKeyURL(product: String) -> URL { url.appendingPathComponent("\(product).private") }
    func stateURL(product: String) -> URL { url.appendingPathComponent("\(product).state") }
    func lockURL(product: String) -> URL { url.appendingPathComponent("\(product).state.lock") }
    func denylistLockURL(product: String) -> URL { url.appendingPathComponent("\(product).denylist.lock") }
    func denylistURL(product: String) -> URL { url.appendingPathComponent("\(product).denylist.json") }

    func prepareForInitialization() throws { try validateSecureDirectory(url, createIfMissing: true) }
    func validateForSecretUse() throws { try validateSecureDirectory(url, createIfMissing: false) }

    func loadPrivateKey(product: String) throws -> Curve25519.Signing.PrivateKey {
        try validateForSecretUse()
        let fileURL = privateKeyURL(product: product)
        guard let data = try readSecureFile(
            fileURL, maxBytes: 256, missingAllowed: false, requireMode0600: true),
              let text = String(data: data, encoding: .utf8) else {
            throw CLIError.message("no readable private key at \(fileURL.path)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed), raw.count == 32,
              raw.base64EncodedString() == trimmed,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw CLIError.message("\(fileURL.path) is not a valid IndieLicense private key file")
        }
        return key
    }

    func writePrivateKey(_ key: Curve25519.Signing.PrivateKey, product: String) throws {
        try prepareForInitialization()
        let data = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        do { try secureExclusiveWrite(data, to: privateKeyURL(product: product)) }
        catch { throw CLIError.message("refusing to overwrite or insecurely create private key: \(error)") }
    }

    func withDenylistLock<T>(product: String, body: () throws -> T) throws -> T {
        try validateForSecretUse()
        let lockPath = denylistLockURL(product: product).path
        let fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw systemError("open lock", path: lockPath) }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CLIError.message("denylist lock must be a current-user regular file with 0600 permissions")
        }
        guard flock(fd, LOCK_EX) == 0 else { throw systemError("lock", path: lockPath) }
        return try body()
    }

    private struct StateDocument: Codable {
        let format: String
        let product: String
        let nextKeyID: UInt64
        enum CodingKeys: String, CodingKey {
            case format, product
            case nextKeyID = "next_key_id"
        }
    }

    func initializeProduct(_ key: Curve25519.Signing.PrivateKey, product: String) throws {
        try prepareForInitialization()
        let initLock = url.appendingPathComponent("\(product).init.lock")
        let fd = Darwin.open(initLock.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw systemError("open lock", path: initLock.path) }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX) == 0 else {
            throw CLIError.message("initialization lock is insecure or unavailable")
        }
        guard try !entryExists(privateKeyURL(product: product)) else {
            throw CLIError.message("refusing to overwrite existing private key for '\(product)'")
        }
        guard try !entryExists(stateURL(product: product)) else {
            throw CLIError.message("state already exists; refusing to create a replacement signing key")
        }
        try initializeState(product: product)
        try writePrivateKey(key, product: product)
    }

    func initializeState(product: String) throws {
        let initial = StateDocument(
            format: "indielicense-state-v1", product: product, nextKeyID: 1)
        do { try secureExclusiveWrite(try JSONEncoder.sorted.encode(initial), to: stateURL(product: product)) }
        catch { throw CLIError.message("refusing to overwrite or insecurely create state: \(error)") }
    }

    /// Atomically reserves a non-overlapping range across concurrent processes.
    func reserveKeyIDs(count: Int, product: String) throws -> Range<UInt64> {
        guard (1...100_000).contains(count) else {
            throw CLIError.message("--count must be between 1 and 100,000")
        }
        try validateForSecretUse()
        let lockFD = Darwin.open(lockURL(product: product).path,
                                 O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw systemError("open lock", path: lockURL(product: product).path) }
        defer { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_mode & 0o077 == 0 else {
            throw CLIError.message("state lock must be a current-user regular file with 0600 permissions")
        }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw systemError("lock", path: lockURL(product: product).path)
        }

        let stateData = try readSecureFile(
            stateURL(product: product), maxBytes: 4_096, missingAllowed: true,
            requireMode0600: true)
        guard let stateData else {
            throw CLIError.message("state file is missing; refusing to risk key-id reuse (restore the correct backup)")
        }
        let state: StateDocument
        do { state = try JSONDecoder().decode(StateDocument.self, from: stateData) }
        catch { throw CLIError.message("state file is corrupt; refusing to risk key-id reuse") }
        guard state.format == "indielicense-state-v1",
              state.product == product,
              (1...(UInt64(UInt32.max) + 1)).contains(state.nextKeyID) else {
            throw CLIError.message("state file product/counter is invalid; refusing to risk key-id reuse")
        }
        let first = state.nextKeyID
        let end = first + UInt64(count)
        guard first <= UInt64(UInt32.max), end <= UInt64(UInt32.max) + 1 else {
            throw CLIError.message("key id space exhausted")
        }
        let next = StateDocument(format: "indielicense-state-v1", product: product, nextKeyID: end)
        let encoded = try JSONEncoder.sorted.encode(next)
        try atomicSecureWrite(encoded, to: stateURL(product: product))
        return first..<end
    }
}

// MARK: - Signed denylist v1

struct DenylistFile {
    struct Entry: Codable, Equatable {
        let keyID: UInt32
        let note: String?
        enum CodingKeys: String, CodingKey { case keyID = "key_id", note }
    }
    var product: String
    var sequence: UInt32
    var revoked: [Entry]

    private struct Document: Codable {
        let format: String
        let product: String
        let sequence: UInt32
        let revoked: [Entry]
        let signature: String
    }

    static func load(
        from url: URL, product: String,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> DenylistFile {
        guard let data = try readSecureFile(
            url, maxBytes: 2_000_000, missingAllowed: true, requireMode0600: true) else {
            return DenylistFile(product: product, sequence: 0, revoked: [])
        }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw CLIError.message("\(url.path) is not a valid denylist: \(error)") }
        guard document.format == "indielicense-denylist-v1",
              document.product == product, document.sequence >= 1,
              document.revoked.count <= 100_000,
              document.revoked.allSatisfy({ ($0.note?.utf8.count ?? 0) <= 4_096 }) else {
            throw CLIError.message("\(url.path) has an invalid format, product, sequence, or size")
        }
        let sorted = document.revoked.sorted { $0.keyID < $1.keyID }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.keyID != $1.keyID }) else {
            throw CLIError.message("\(url.path) contains duplicate key ids")
        }
        guard let signature = Data(base64Encoded: document.signature), signature.count == 64,
              signature.base64EncodedString() == document.signature,
              publicKey.isValidSignature(
                signature,
                for: denylistMessage(product: product, sequence: document.sequence, entries: sorted)) else {
            throw CLIError.message("\(url.path) signature does not verify; refusing to trust or re-sign it")
        }
        return DenylistFile(product: product, sequence: document.sequence, revoked: sorted)
    }

    mutating func appendRevocation(keyID: UInt32, note: String?) throws {
        guard !revoked.contains(where: { $0.keyID == keyID }) else {
            throw CLIError.message("key id \(keyID) is already on the denylist")
        }
        guard note == nil || note!.utf8.count <= 4_096 else {
            throw CLIError.message("--note must be no longer than 4096 UTF-8 bytes")
        }
        guard sequence < UInt32.max else { throw CLIError.message("denylist sequence exhausted") }
        sequence += 1
        revoked.append(Entry(keyID: keyID, note: note))
    }

    func write(to url: URL, privateKey: Curve25519.Signing.PrivateKey) throws {
        guard sequence >= 1 else { throw CLIError.message("denylist sequence must be positive") }
        let sorted = revoked.sorted { $0.keyID < $1.keyID }
        let signature = try privateKey.signature(
            for: denylistMessage(product: product, sequence: sequence, entries: sorted))
        let document = Document(
            format: "indielicense-denylist-v1", product: product,
            sequence: sequence, revoked: sorted,
            signature: signature.base64EncodedString())
        try atomicSecureWrite(try JSONEncoder.pretty.encode(document), to: url)
    }
}

private func denylistMessage(
    product: String, sequence: UInt32, entries: [DenylistFile.Entry]
) -> Data {
    let lines = ["indielicense-denylist-v1", product, String(sequence)] + entries.map {
        let note = $0.note.map { "+" + Data($0.utf8).base64EncodedString() } ?? "-"
        return "\($0.keyID)\t\(note)"
    }
    return Data(lines.joined(separator: "\n").utf8)
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - CSV output

let csvHeader = "key_id,license_key,issued_at,mode,expires_duration_days,updates_duration_days"

func appendSecureCSV(_ body: Data, to url: URL) throws {
    let name = url.lastPathComponent.lowercased()
    guard !name.hasSuffix(".private"), !name.hasSuffix(".state"),
          !name.hasSuffix(".denylist.json"), !name.hasSuffix(".lock") else {
        throw CLIError.message("refusing to use a sensitive key-directory filename as CSV output")
    }
    if let existing = try readSecureFile(
        url, maxBytes: 50_000_000, missingAllowed: true, requireMode0600: true) {
        guard existing.starts(with: Data((csvHeader + "\n").utf8)), existing.last == 0x0a else {
            throw CLIError.message("existing output is not an intact IndieLicense CSV ending in a newline")
        }
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError("open output", path: url.path) }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw systemError("lock output", path: url.path) }
        try writeAll(fd: fd, data: body, path: url.path)
        guard fsync(fd) == 0 else { throw systemError("fsync output", path: url.path) }
    } else {
        try secureExclusiveWrite(Data((csvHeader + "\n").utf8) + body, to: url)
    }
}

// MARK: - Parsing and formatting

func parseDurationDays(_ text: String, flag: String) throws -> UInt16 {
    var digits = Substring(text)
    if digits.hasSuffix("d") { digits = digits.dropLast() }
    guard let days = UInt16(digits), days > 0 else {
        throw CLIError.message("\(flag) expects a positive number of days like '365d', got '\(text)'")
    }
    return days
}

func validateProductID(_ product: String) throws {
    let bytes = Array(product.utf8)
    guard (1...64).contains(bytes.count), bytes.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0)
    }) else {
        throw CLIError.message("product id must be 1-64 ASCII chars of lowercase a-z and 0-9")
    }
}

func todayUnixDay() throws -> UInt16 {
    let day = Int(floor(Date().timeIntervalSince1970 / 86_400))
    guard let value = UInt16(exactly: day) else {
        throw CLIError.message("current UTC day cannot be represented by license format v1")
    }
    return value
}

func isoDate(unixDay: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date(timeIntervalSince1970: Double(unixDay) * 86_400))
}

func terminalSafe(_ text: String) -> String {
    String(text.unicodeScalars.map { scalar in
        CharacterSet.controlCharacters.contains(scalar) ? "�" : Character(scalar)
    })
}
