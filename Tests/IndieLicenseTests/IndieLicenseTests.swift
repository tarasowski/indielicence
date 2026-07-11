import CryptoKit
import Foundation
import XCTest

@testable import IndieLicense
@testable import IndieLicenseCLI

// MARK: - Test scaffolding

/// In-memory activation store with LicenseStore's stamp-once semantics,
/// so expiry tests can control "today" without touching the Keychain.
final class MemoryActivationStore: LicenseStateStore {
    var today: Date
    private(set) var stamped: [String: Date] = [:]
    private(set) var sequences: [String: UInt32] = [:]
    init(today: Date) { self.today = today }
    func activatedAt(for licenseIdentifier: String) throws -> Date {
        if let existing = stamped[licenseIdentifier] { return existing }
        stamped[licenseIdentifier] = today
        return today
    }
    func highestDenylistSequence(for productIdentifier: String) throws -> UInt32? {
        sequences[productIdentifier]
    }
    func recordDenylistSequence(_ sequence: UInt32, for productIdentifier: String) throws {
        sequences[productIdentifier] = max(sequence, sequences[productIdentifier] ?? 0)
    }
}

final class FailingStateStore: LicenseStateStore {
    enum Failure: Error { case unavailable }
    func activatedAt(for licenseIdentifier: String) throws -> Date { throw Failure.unavailable }
    func highestDenylistSequence(for productIdentifier: String) throws -> UInt32? { throw Failure.unavailable }
    func recordDenylistSequence(_ sequence: UInt32, for productIdentifier: String) throws { throw Failure.unavailable }
}

func day(_ iso: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: iso)!
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct Vectors: Decodable {
    struct Case: Decodable {
        let name: String
        let expect: String
        let key: String
        let key_id: UInt32?
        let mode: String?
    }
    struct DenylistEntry: Codable { let key_id: UInt32; let note: String? }
    struct Denylist: Codable {
        let format: String
        let product: String
        let sequence: UInt32
        let revoked: [DenylistEntry]
        let signature: String
    }
    let seed_hex: String
    let public_key_base64: String
    let product: String
    let issued_day: Int
    let cases: [Case]
    let denylist: Denylist

    static let shared: Vectors = {
        let url = repoRoot.appendingPathComponent("Tests/vectors.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

class FixedKeyTestCase: XCTestCase {
    let vectors = Vectors.shared
    var tempDir: URL!

    /// The fixed test private key from vectors.json.
    var privateKey: Curve25519.Signing.PrivateKey {
        let seed = stride(from: 0, to: vectors.seed_hex.count, by: 2).map { offset -> UInt8 in
            let start = vectors.seed_hex.index(vectors.seed_hex.startIndex, offsetBy: offset)
            return UInt8(vectors.seed_hex[start...vectors.seed_hex.index(start, offsetBy: 1)], radix: 16)!
        }
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
    }

    var publicKeyBase64: String { vectors.public_key_base64 }

    func makeValidator(
        buildDate: Date = day("2026-07-11"), denylist: URL? = nil,
        store: LicenseStateStore = MemoryActivationStore(today: day("2026-07-11"))
    ) -> LicenseValidator {
        LicenseValidator(
            publicKey: publicKeyBase64, product: "pixelpro",
            buildDate: buildDate, denylist: denylist, stateStore: store)
    }

    func mint(keyID: UInt32, product: String = "pixelpro", expires: UInt16? = nil, updates: UInt16? = nil) -> String {
        try! mintKey(
            privateKey: privateKey, product: product, keyID: keyID,
            issuedDay: UInt16(vectors.issued_day), expiresDurationDays: expires, updatesDurationDays: updates)
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("indielicense-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func writeVectorDenylist() throws -> URL {
        let url = tempDir.appendingPathComponent("pixelpro.denylist.json")
        try JSONEncoder().encode(vectors.denylist).write(to: url)
        return url
    }
}

// MARK: - Shared test vectors (must match the JS verifier's results)

final class VectorTests: FixedKeyTestCase {
    func testAllVectors() throws {
        let denylistURL = try writeVectorDenylist()
        let validator = makeValidator(denylist: denylistURL)
        for vector in vectors.cases {
            let result = validator.validate(vector.key, now: day("2026-07-11"))
            switch (vector.expect, result) {
            case ("valid", .valid(let info)):
                XCTAssertEqual(info.keyID, vector.key_id, vector.name)
                XCTAssertEqual(info.isLifetime, vector.mode == "lifetime", vector.name)
            case ("bad_signature", .invalid(.badSignature)),
                 ("wrong_product", .invalid(.wrongProduct)),
                 ("revoked", .invalid(.revoked)),
                 ("malformed", .invalid(.malformed)),
                 ("unsupported_version", .invalid(.unsupportedVersion)):
                break
            default:
                XCTFail("\(vector.name): expected \(vector.expect), got \(result)")
            }
        }
    }
}

// MARK: - Validator behavior

final class ValidatorTests: FixedKeyTestCase {
    func testRoundTripGenerateThenVerify() throws {
        let key = mint(keyID: 42)
        guard case .valid(let info) = makeValidator().validate(key) else {
            return XCTFail("freshly minted key should validate")
        }
        XCTAssertEqual(info.keyID, 42)
        XCTAssertEqual(info.product, "pixelpro")
        XCTAssertEqual(info.issuedAt, day("2026-07-11"))
        XCTAssertTrue(info.isLifetime)
        XCTAssertNil(info.effectiveExpiresAt)
        XCTAssertNil(info.effectiveUpdatesUntil)
    }

    func testTamperedPayloadRejected() throws {
        let key = mint(keyID: 7)
        // Flip one bit inside the signed region and re-encode with the original signature.
        let payload = try LicensePayload.decode(key)
        var body = payload.signedBytes
        body[2 + "pixelpro".utf8.count + 3] ^= 0x01  // low byte of the key id
        let tampered = "PIXELPRO-" + grouped(crockfordEncode(body + payload.signature))
        XCTAssertEqual(makeValidator().validate(tampered), .invalid(.badSignature))
    }

    func testWrongProductRejected() throws {
        let key = mint(keyID: 1, product: "otherapp")
        XCTAssertEqual(makeValidator().validate(key), .invalid(.wrongProduct(found: "otherapp")))
    }

    func testActivationStampedOnceAndEffectiveDatesComputed() throws {
        let key = mint(keyID: 9, expires: 14, updates: 365)
        let store = MemoryActivationStore(today: day("2026-08-01"))
        let validator = makeValidator(store: store)

        guard case .valid(let first) = validator.validate(key, now: day("2026-08-01")) else {
            return XCTFail("should be valid on activation day")
        }
        XCTAssertEqual(first.effectiveExpiresAt, day("2026-08-15"), "activation + 14 days")
        XCTAssertEqual(first.effectiveUpdatesUntil, day("2027-08-01"), "activation + 365 days")

        // A later validation must reuse the ORIGINAL activation date, even
        // though the store would stamp a different "today" now.
        store.today = day("2026-08-10")
        guard case .valid(let second) = validator.validate(key, now: day("2026-08-10")) else {
            return XCTFail("still inside the trial window")
        }
        XCTAssertEqual(second.effectiveExpiresAt, first.effectiveExpiresAt, "activatedAt must not reset")
        XCTAssertEqual(store.stamped.count, 1, "only one stamp for the key")
    }

    func testTrialExpiryBoundary() throws {
        let key = mint(keyID: 10, expires: 14)
        let store = MemoryActivationStore(today: day("2026-08-01"))
        let validator = makeValidator(store: store)
        guard case .valid = validator.validate(key, now: day("2026-08-15")) else {
            return XCTFail("the last day of the window is still covered")
        }
        XCTAssertEqual(
            validator.validate(key, now: day("2026-08-16")),
            .invalid(.expired(on: day("2026-08-15"))))
    }

    func testUpdatesWindowComparesBuildDateNotWallClock() throws {
        let key = mint(keyID: 11, updates: 365)
        let store = MemoryActivationStore(today: day("2026-07-11"))

        // Old build, wall clock decades later: still valid — updates keys unlock forever.
        let oldBuild = makeValidator(buildDate: day("2026-09-01"), store: store)
        guard case .valid(let info) = oldBuild.validate(key, now: day("2050-01-01")) else {
            return XCTFail("an old build must never stop working")
        }
        XCTAssertEqual(info.effectiveUpdatesUntil, day("2027-07-11"))
        XCTAssertFalse(info.isLifetime)

        // Build released after the window: distinct "renew" error, not "invalid key".
        let newBuild = makeValidator(buildDate: day("2027-08-01"), store: store)
        XCTAssertEqual(
            newBuild.validate(key, now: day("2027-08-01")),
            .invalid(.updatesExpired(on: day("2027-07-11"))))
    }

    func testLifetimeKeyNeverExpires() throws {
        let key = mint(keyID: 12)
        let validator = makeValidator(buildDate: day("2126-01-01"))
        guard case .valid(let info) = validator.validate(key, now: day("2126-01-01")) else {
            return XCTFail("lifetime key must validate a century from now")
        }
        XCTAssertTrue(info.isLifetime)
        XCTAssertNil(info.effectiveExpiresAt)
        XCTAssertNil(info.effectiveUpdatesUntil)
    }

    func testDenylistedKeyRejectedAndForgedDenylistRefused() throws {
        let denylistURL = try writeVectorDenylist()
        let validator = makeValidator(denylist: denylistURL)
        let revoked = mint(keyID: 6)
        XCTAssertEqual(validator.validate(revoked), .invalid(.revoked(note: "test vector: refunded")))
        let notRevoked = mint(keyID: 600)
        guard case .valid = validator.validate(notRevoked) else {
            return XCTFail("keys not on the denylist stay valid")
        }

        // Adding an entry without re-signing must invalidate the whole file.
        var forged = vectors.denylist
        forged = Vectors.Denylist(
            format: forged.format, product: forged.product,
            sequence: forged.sequence,
            revoked: forged.revoked + [Vectors.DenylistEntry(key_id: 600, note: nil)],
            signature: forged.signature)
        let forgedURL = tempDir.appendingPathComponent("forged.denylist.json")
        try JSONEncoder().encode(forged).write(to: forgedURL)
        guard case .invalid(.badDenylist) = makeValidator(denylist: forgedURL).validate(notRevoked) else {
            return XCTFail("forged denylist must be rejected outright")
        }
    }

    func testNonASCIICrockfordCharactersAreRejected() throws {
        let original = vectors.cases.first(where: { $0.name == "lifetime_valid" })!.key
        guard let position = original.firstIndex(of: "S") else {
            return XCTFail("vector must contain S for the Unicode-malleability regression")
        }
        var altered = original
        altered.replaceSubrange(position...position, with: "ſ")
        guard case .invalid(.malformed) = makeValidator().validate(altered) else {
            return XCTFail("non-ASCII characters must never case-fold into the Crockford alphabet")
        }
    }

    func testOversizedKeyRejectedBeforeDecode() throws {
        let oversized = "PIXELPRO-" + String(repeating: "0", count: 600)
        guard case .invalid(.malformed) = makeValidator().validate(oversized) else {
            return XCTFail("oversized keys must be rejected")
        }
    }

    func testDeterministicMalformedCorpusNeverCrashes() throws {
        var state: UInt64 = 0x4d595df4d0f33173
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ-!@#$%^&*()")
        let validator = makeValidator()
        for _ in 0..<2_000 {
            let length = Int(next() % 512)
            let body = String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            _ = validator.validate("FUZZ-" + body)
        }
    }

    func testStorageFailureFailsClosed() throws {
        let trial = mint(keyID: 77, expires: 14)
        let validator = makeValidator(store: FailingStateStore())
        guard case .invalid(.storageFailure) = validator.validate(trial) else {
            return XCTFail("activation persistence failure must fail closed")
        }
    }

    func testActivationIdentityIncludesSignedPayload() throws {
        let store = MemoryActivationStore(today: day("2026-07-11"))
        let first = mint(keyID: 88, expires: 14)
        let second = mint(keyID: 88, expires: 30)
        _ = makeValidator(store: store).validate(first)
        _ = makeValidator(store: store).validate(second)
        XCTAssertEqual(store.stamped.count, 2, "same numeric id with different signed payloads must not share activation")
    }

    func testDenylistSequenceRollbackFailsClosed() throws {
        let url = tempDir.appendingPathComponent("rollback.denylist.json")
        let store = MemoryActivationStore(today: day("2026-07-11"))
        let license = mint(keyID: 900)
        let newer = DenylistFile(product: "pixelpro", sequence: 2, revoked: [])
        try newer.write(to: url, privateKey: privateKey)
        guard case .valid = makeValidator(denylist: url, store: store).validate(license) else {
            return XCTFail("newer denylist should validate")
        }
        let older = DenylistFile(product: "pixelpro", sequence: 1, revoked: [])
        try older.write(to: url, privateKey: privateKey)
        guard case .invalid(.badDenylist) = makeValidator(denylist: url, store: store).validate(license) else {
            return XCTFail("older signed denylist must be rejected after a newer sequence was seen")
        }
    }
}

// MARK: - CLI end-to-end (runs the actual subcommands in a temp key dir)

final class CLITests: FixedKeyTestCase {
    func writeFixedPrivateKey(product: String = "pixelpro") throws {
        let url = tempDir.appendingPathComponent("\(product).private")
        try (privateKey.rawRepresentation.base64EncodedString() + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try KeyDirectory(path: tempDir.path).initializeState(product: product)
    }

    func runGenerate(_ extra: [String], out: String = "keys.csv") throws {
        let arguments = ["--key-dir", tempDir.path, "--out", tempDir.appendingPathComponent(out).path] + extra
        let command = try Generate.parse(arguments)
        try command.run()
    }

    func csvLines(_ name: String = "keys.csv") throws -> [String] {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func runIntegrate(
        output: URL, ui: String = "none", denylist: String = "none",
        publicKey: String? = nil
    ) throws {
        var arguments = [
            "swift", "--product", "pixelpro", "--build-date", "2026-07-11",
            "--output", output.path, "--ui", ui, "--denylist", denylist,
        ]
        if let publicKey {
            arguments += ["--public-key", publicKey]
        } else {
            arguments += ["--key-dir", tempDir.path]
        }
        try Integrate.parse(arguments).run()
    }

    func testCSVOutputAllFields() throws {
        try writeFixedPrivateKey()
        try runGenerate(["--count", "2", "--mode", "trial", "--expires", "14d"])
        try runGenerate(["--count", "1", "--mode", "updates", "--updates-duration", "365d"])
        try runGenerate(["--count", "1", "--mode", "lifetime"])

        let lines = try csvLines()
        XCTAssertEqual(lines[0], "key_id,license_key,issued_at,mode,expires_duration_days,updates_duration_days")
        XCTAssertEqual(lines.count, 5, "header + 4 keys")

        let today = isoDate(unixDay: Int(try todayUnixDay()))
        let fields = lines.dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(fields.map { $0[0] }, ["1", "2", "3", "4"], "sequential ids across batches")
        XCTAssertEqual(fields.map { $0[3] }, ["trial", "trial", "updates", "lifetime"])
        XCTAssertEqual(fields.map { $0[4] }, ["14", "14", "", ""], "expires_duration_days column")
        XCTAssertEqual(fields.map { $0[5] }, ["", "", "365", ""], "updates_duration_days column")
        XCTAssertTrue(fields.allSatisfy { $0[2] == today })

        // Every minted key must actually validate, with matching durations.
        let validator = makeValidator()
        for row in fields {
            guard case .valid(let info) = validator.validate(row[1]) else {
                return XCTFail("CSV key \(row[0]) should validate")
            }
            XCTAssertEqual(String(info.keyID), row[0])
            XCTAssertEqual(info.expiresDurationDays.map(String.init) ?? "", row[4])
            XCTAssertEqual(info.updatesDurationDays.map(String.init) ?? "", row[5])
        }
    }

    func testSequenceContinuesAcrossBatchesAndNeverReuses() throws {
        try writeFixedPrivateKey()
        try runGenerate(["--count", "3", "--mode", "lifetime"], out: "a.csv")
        try runGenerate(["--count", "2", "--mode", "lifetime"], out: "b.csv")
        let ids = try (csvLines("a.csv").dropFirst() + csvLines("b.csv").dropFirst())
            .map { String($0.split(separator: ",")[0]) }
        XCTAssertEqual(ids, ["1", "2", "3", "4", "5"])
    }

    func testGenerateRejectsContradictoryFlags() throws {
        try writeFixedPrivateKey()
        let contradictions: [[String]] = [
            ["--count", "1", "--mode", "lifetime", "--expires", "14d"],
            ["--count", "1", "--mode", "lifetime", "--updates-duration", "365d"],
            ["--count", "1", "--mode", "updates", "--expires", "14d", "--updates-duration", "365d"],
            ["--count", "1", "--mode", "trial", "--updates-duration", "365d", "--expires", "14d"],
            ["--count", "1", "--mode", "updates"],  // missing its required duration
            ["--count", "1", "--mode", "trial"],
        ]
        for arguments in contradictions {
            XCTAssertThrowsError(try runGenerate(arguments), arguments.joined(separator: " "))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("keys.csv").path),
            "no CSV may be written when flags contradict")
    }

    func testInitRefusesToOverwrite() throws {
        let initCommand = try Init.parse(["--product", "demoapp", "--key-dir", tempDir.path])
        try initCommand.run()
        XCTAssertThrowsError(try initCommand.run(), "second init must refuse to overwrite the private key")
    }

    func testIntegrateGeneratesGeneralizedAppOwnedSwiftFiles() throws {
        try writeFixedPrivateKey()
        let output = tempDir.appendingPathComponent("GeneratedLicense")
        try runIntegrate(output: output, ui: "swiftui", denylist: "bundled")

        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        XCTAssertEqual(names, [
            "LICENSE_INTEGRATION.md", "LicenseActivationView.swift",
            "LicenseConfig.swift", "LicenseManager.swift", "LicenseVerifier.swift",
        ])

        let config = try String(
            contentsOf: output.appendingPathComponent("LicenseConfig.swift"), encoding: .utf8)
        XCTAssertTrue(config.contains("static let product = \"pixelpro\""))
        XCTAssertTrue(config.contains(publicKeyBase64))
        XCTAssertTrue(config.contains("TimeInterval(20645)"))
        XCTAssertTrue(config.contains("pixelpro.denylist"))

        let manager = try String(
            contentsOf: output.appendingPathComponent("LicenseManager.swift"), encoding: .utf8)
        XCTAssertTrue(manager.contains("func activate(key: String) -> Bool"))
        XCTAssertTrue(manager.contains("case renewalRequired(until: Date)"))

        let allGenerated = try names.map {
            try String(contentsOf: output.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertFalse(allGenerated.contains("{{"), "all template placeholders must be resolved")
        XCTAssertFalse(allGenerated.contains(".private"), "generated app files must never name private material")
        XCTAssertFalse(allGenerated.contains(tempDir.path), "generated files must not leak local paths")

        let verifier = try Data(contentsOf: output.appendingPathComponent("LicenseVerifier.swift"))
        XCTAssertEqual(verifier, Data(EmbeddedTemplates.verifier.utf8))
    }

    func testIntegrateAcceptsPublicKeyWithoutKeyDirectoryAndOmitsOptionalUI() throws {
        let output = tempDir.appendingPathComponent("PublicOnly")
        try runIntegrate(output: output, publicKey: publicKeyBase64)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("LicenseManager.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("LicenseActivationView.swift").path))
    }

    func testIntegrateRefusesOverwriteBeforeWritingAnything() throws {
        let output = tempDir.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("LicenseConfig.swift")
        try "keep me\n".write(to: existing, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try runIntegrate(output: output, publicKey: publicKeyBase64))
        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8), "keep me\n")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: output.path),
            ["LicenseConfig.swift"])
    }

    func testIntegrateRejectsInvalidConfigurationWithoutCreatingOutput() throws {
        let output = tempDir.appendingPathComponent("Invalid")
        XCTAssertThrowsError(try Integrate.parse([
            "swift", "--product", "pixelpro", "--public-key", publicKeyBase64,
            "--build-date", "2026-02-30", "--output", output.path,
        ]).run())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testConcurrentInitCreatesExactlyOneKeypair() throws {
        let executable = repoRoot.appendingPathComponent(".build/debug/indielicense")
        let processes: [Process] = try (0..<8).map { _ in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "init", "--product", "initrace", "--key-dir", tempDir.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertEqual(processes.filter { $0.terminationStatus == 0 }.count, 1)
    }

    func testRevokeSignsAndVerifierRejects() throws {
        try writeFixedPrivateKey()
        let revoke = try Revoke.parse(["3", "--note", "refunded", "--key-dir", tempDir.path])
        try revoke.run()

        let validator = makeValidator(denylist: tempDir.appendingPathComponent("pixelpro.denylist.json"))
        XCTAssertEqual(validator.validate(mint(keyID: 3)), .invalid(.revoked(note: "refunded")))
        guard case .valid = validator.validate(mint(keyID: 4)) else {
            return XCTFail("other keys unaffected by the denylist")
        }
    }

    func testConcurrentGeneratorsReserveUniqueIDs() throws {
        try writeFixedPrivateKey(product: "racecheck")
        let executable = repoRoot.appendingPathComponent(".build/debug/indielicense")
        let processes: [Process] = try (0..<12).map { index in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "generate", "--count", "1", "--mode", "lifetime",
                "--product", "racecheck", "--key-dir", tempDir.path,
                "--out", tempDir.appendingPathComponent("race-\(index).csv").path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
        let ids = try (0..<12).map { index -> Int in
            let lines = try csvLines("race-\(index).csv")
            return Int(lines[1].split(separator: ",")[0])!
        }
        XCTAssertEqual(ids.sorted(), Array(1...12))
    }

    func testConcurrentRevocationsDoNotLoseEntries() throws {
        try writeFixedPrivateKey(product: "racecheck")
        let executable = repoRoot.appendingPathComponent(".build/debug/indielicense")
        let processes: [Process] = try (1...12).map { keyID in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "revoke", String(keyID), "--note", "concurrent",
                "--product", "racecheck", "--key-dir", tempDir.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        processes.forEach { $0.waitUntilExit() }
        XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
        let loaded = try DenylistFile.load(
            from: tempDir.appendingPathComponent("racecheck.denylist.json"),
            product: "racecheck", publicKey: privateKey.publicKey)
        XCTAssertEqual(loaded.sequence, 12)
        XCTAssertEqual(loaded.revoked.map(\.keyID).sorted(), (1...12).map(UInt32.init))
    }

}

// MARK: - The single-file verifier is the library, byte for byte

final class SingleFileSyncTests: XCTestCase {
    func testCopyPasteVerifierMatchesLibrary() throws {
        let canonical = try Data(contentsOf: repoRoot.appendingPathComponent("Verifier/LicenseVerifier.swift"))
        let library = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/IndieLicense/LicenseVerifier.swift"))
        XCTAssertEqual(canonical, library,
            "Verifier/LicenseVerifier.swift and Sources/IndieLicense/LicenseVerifier.swift must stay byte-identical — copy one over the other")
    }

    func testEmbeddedScaffoldMatchesCanonicalSources() throws {
        let pairs: [(String, String)] = [
            (EmbeddedTemplates.verifier, "Verifier/LicenseVerifier.swift"),
            (EmbeddedTemplates.licenseConfig, "Templates/Swift/LicenseConfig.swift.template"),
            (EmbeddedTemplates.licenseManager, "Templates/Swift/LicenseManager.swift.template"),
            (EmbeddedTemplates.activationView, "Templates/Swift/LicenseActivationView.swift.template"),
            (EmbeddedTemplates.integrationGuide, "Templates/Swift/LICENSE_INTEGRATION.md.template"),
        ]
        for (embedded, path) in pairs {
            XCTAssertEqual(
                Data(embedded.utf8),
                try Data(contentsOf: repoRoot.appendingPathComponent(path)),
                "run `swift Tools/embed-templates.swift` after changing \(path)")
        }
    }
}
