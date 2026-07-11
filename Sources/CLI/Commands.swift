//
//  Commands.swift — the `indielicense` CLI.
//  No telemetry, no network calls, anywhere. Everything runs locally.
//

import ArgumentParser
import CryptoKit
import Foundation
import IndieLicense

@main
struct IndieLicenseCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "indielicense",
        abstract: "Offline license keys for indie Mac apps. No server, ever.",
        discussion: """
        Generate Ed25519-signed license keys on your own machine, sell them \
        through any payment platform, and validate them fully offline in your app.
        """,
        version: "1.0.0",
        subcommands: [Init.self, Generate.self, Verify.self, Inspect.self, Revoke.self]
    )
}

struct KeyDirOption: ParsableArguments {
    @Option(name: .customLong("key-dir"), help: "Directory holding the private key and its sidecar files.")
    var keyDir: String = "~/Licensing"

    var directory: KeyDirectory { KeyDirectory(path: keyDir) }

    /// Most devs have one product per key dir — infer it when unambiguous.
    func resolveProduct(_ explicit: String?) throws -> String {
        if let explicit { try validateProductID(explicit); return explicit }
        try directory.validateForSecretUse()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.path)) ?? []
        let products = names.filter { $0.hasSuffix(".private") }.map { String($0.dropLast(".private".count)) }
        switch products.count {
        case 1: try validateProductID(products[0]); return products[0]
        case 0: throw CLIError.message("no .private key file in \(directory.url.path) — run `indielicense init` first or pass --key-dir")
        default: throw CLIError.message("multiple products in \(directory.url.path) (\(products.sorted().joined(separator: ", "))) — pass --product")
        }
    }
}

// MARK: - init

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create an Ed25519 keypair for a product.")

    @Option(help: "Product id: 1–64 chars, lowercase a-z and 0-9. Becomes the key prefix, uppercased.")
    var product: String

    @OptionGroup var keyDirOption: KeyDirOption

    func run() throws {
        try validateProductID(product)
        let privateKey = Curve25519.Signing.PrivateKey()
        try keyDirOption.directory.initializeProduct(privateKey, product: product)
        let keyPath = keyDirOption.directory.privateKeyURL(product: product).path
        let statePath = keyDirOption.directory.stateURL(product: product).path
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        print("""
        Created keypair for '\(product)'.

        Private key: \(keyPath)  (permissions 0600)
        Key-id state: \(statePath)  (permissions 0600)

          ┌──────────────────────────────────────────────────────────────────┐
          │  ⚠  BACK UP BOTH FILES NOW using encrypted storage.              │
          │                                                                  │
          │  If it is LOST, you can never mint keys for shipped app          │
          │  versions again. If it LEAKS, anyone can mint valid keys.        │
          │  It never needs to leave this machine and must NEVER be          │
          │  bundled into your app.                                          │
          │  Keep state backups current; stale state can reuse customer ids.  │
          └──────────────────────────────────────────────────────────────────┘

        Public key (embed this in your app — safe to ship):

            \(publicKey)
        """)
    }
}

// MARK: - generate

enum LicenseMode: String, ExpressibleByArgument, CaseIterable {
    case lifetime, updates, trial
}

struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mint license keys and append them to a CSV.",
        discussion: """
        --mode lifetime   Unlocks forever — no expiry, no update cutoff, ever.
        --mode updates    Unlocks forever, but only versions released within
                          --updates-duration of the customer's activation are
                          covered. After that they keep their current version
                          or buy a renewal key.
        --mode trial      Stops working entirely --expires after activation.

        Durations are relative to each customer's FIRST activation, stamped by
        the app — never to when this command ran, so keys can sit unsold
        indefinitely without losing any of the customer's window.
        """)

    @Option(help: "How many keys to mint.")
    var count: Int

    @Option(help: "lifetime, updates, or trial. Recorded in the CSV so batches stay self-documenting.")
    var mode: LicenseMode

    @Option(name: .customLong("updates-duration"), help: "Update coverage window, e.g. '365d'. Required for --mode updates.")
    var updatesDuration: String?

    @Option(help: "Trial length, e.g. '14d'. Required for --mode trial.")
    var expires: String?

    @Option(help: "CSV file to create or append to.")
    var out: String = "keys.csv"

    @Option(help: "Product id. Inferred from the key dir when it holds a single product.")
    var product: String?

    @OptionGroup var keyDirOption: KeyDirOption

    func run() throws {
        guard (1...100_000).contains(count) else {
            throw CLIError.message("--count must be between 1 and 100,000")
        }

        var expiresDays: UInt16?
        var updatesDays: UInt16?
        switch mode {
        case .lifetime:
            guard expires == nil else { throw CLIError.message("--mode lifetime never expires; --expires contradicts it") }
            guard updatesDuration == nil else { throw CLIError.message("--mode lifetime covers all updates forever; --updates-duration contradicts it") }
        case .updates:
            guard expires == nil else { throw CLIError.message("--mode updates does not use --expires (did you mean --mode trial?)") }
            guard let updatesDuration else { throw CLIError.message("--mode updates requires --updates-duration, e.g. --updates-duration 365d") }
            updatesDays = try parseDurationDays(updatesDuration, flag: "--updates-duration")
        case .trial:
            guard updatesDuration == nil else { throw CLIError.message("--mode trial does not use --updates-duration") }
            guard let expires else { throw CLIError.message("--mode trial requires --expires, e.g. --expires 14d") }
            expiresDays = try parseDurationDays(expires, flag: "--expires")
        }

        let directory = keyDirOption.directory
        let resolvedProduct = try keyDirOption.resolveProduct(product)
        let privateKey = try directory.loadPrivateKey(product: resolvedProduct)
        let reservedIDs = try directory.reserveKeyIDs(count: count, product: resolvedProduct)

        let issuedDay = try todayUnixDay()
        var rows: [String] = []
        for reservedID in reservedIDs {
            let keyID = UInt32(reservedID)
            let key = try mintKey(
                privateKey: privateKey, product: resolvedProduct, keyID: keyID,
                issuedDay: issuedDay, expiresDurationDays: expiresDays, updatesDurationDays: updatesDays)
            rows.append([
                String(keyID), key, isoDate(unixDay: Int(issuedDay)), mode.rawValue,
                expiresDays.map(String.init) ?? "", updatesDays.map(String.init) ?? "",
            ].joined(separator: ","))
        }

        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        let body = rows.joined(separator: "\n") + "\n"
        try appendSecureCSV(Data(body.utf8), to: outURL)

        let firstID = reservedIDs.lowerBound
        let lastID = reservedIDs.upperBound - 1
        print("Minted \(count) \(mode.rawValue) key\(count == 1 ? "" : "s") for '\(resolvedProduct)' (ids \(firstID)–\(lastID)) → \(outURL.path)")
    }
}

// MARK: - verify

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fully validate a key: signature, product, denylist. Exit 0 valid / 1 invalid.")

    @Argument(help: "The license key to check.")
    var key: String

    @Option(name: .customLong("public-key"), help: "Base64 public key. Default: derived from the private key file in --key-dir.")
    var publicKeyBase64: String?

    @OptionGroup var keyDirOption: KeyDirOption

    func run() throws {
        let payload: LicensePayload
        do { payload = try LicensePayload.decode(key) } catch {
            print("INVALID: malformed key (\(error))")
            throw ExitCode(1)
        }

        let publicKey: Curve25519.Signing.PublicKey
        if let publicKeyBase64 {
            guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32,
                  raw.base64EncodedString() == publicKeyBase64,
                  let parsed = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
                throw CLIError.message("--public-key is not valid base64-encoded Ed25519 key material")
            }
            publicKey = parsed
        } else {
            publicKey = try keyDirOption.directory.loadPrivateKey(product: payload.product).publicKey
        }

        guard publicKey.isValidSignature(payload.signature, for: payload.signedBytes) else {
            print("INVALID: signature does not verify — the key was tampered with or minted with a different private key")
            throw ExitCode(1)
        }

        // Check the local denylist if one exists next to the key material.
        let denylistURL = keyDirOption.directory.denylistURL(product: payload.product)
        if FileManager.default.fileExists(atPath: denylistURL.path) {
            let denylist = try DenylistFile.load(
                from: denylistURL, product: payload.product, publicKey: publicKey)
            if let entry = denylist.revoked.first(where: { $0.keyID == payload.keyID }) {
                let note = entry.note.map { " (\(terminalSafe($0)))" } ?? ""
                print("INVALID: key id \(payload.keyID) is on the denylist\(note)")
                throw ExitCode(1)
            }
        }

        print("VALID: \(payload.product) key #\(payload.keyID), issued \(isoDate(unixDay: Int(payload.issuedDay)))")
        print("  " + describeMode(of: payload))
    }
}

// MARK: - inspect

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a key's payload without any key material.")

    @Argument(help: "The license key to decode.")
    var key: String

    func run() throws {
        let payload = try LicensePayload.decode(key)
        print("""
        product:  \(payload.product)
        key id:   \(payload.keyID)
        issued:   \(isoDate(unixDay: Int(payload.issuedDay)))
        mode:     \(describeMode(of: payload))
        format:   v\(payload.version)

        NOTE: signature NOT checked — inspect only decodes. Use `indielicense verify`.
        """)
    }
}

func describeMode(of payload: LicensePayload) -> String {
    switch (payload.expiresDurationDays, payload.updatesDurationDays) {
    case (nil, nil):
        return "lifetime — unlocks every version, forever"
    case (nil, .some(let updates)):
        return "updates — unlocks forever; covers versions released within \(updates) days of activation"
    case (.some(let expires), _):
        return "trial — stops working \(expires) days after activation"
    }
}

// MARK: - revoke

struct Revoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a key id to the signed denylist (or --list current entries).",
        discussion: "Bundle the updated <product>.denylist.json into your next app release.")

    @Argument(help: "The key id to revoke (from the CSV / `inspect`). Omit with --list.")
    var keyID: UInt32?

    @Option(help: "Why it was revoked, e.g. \"refunded\". Stored alongside the id.")
    var note: String?

    @Flag(help: "Print the current denylist instead of revoking.")
    var list = false

    @Option(help: "Product id. Inferred from the key dir when it holds a single product.")
    var product: String?

    @OptionGroup var keyDirOption: KeyDirOption

    func run() throws {
        let directory = keyDirOption.directory
        let resolvedProduct = try keyDirOption.resolveProduct(product)
        let denylistURL = directory.denylistURL(product: resolvedProduct)
        let privateKey = try directory.loadPrivateKey(product: resolvedProduct)
        try directory.withDenylistLock(product: resolvedProduct) {
            var denylist = try DenylistFile.load(
                from: denylistURL, product: resolvedProduct, publicKey: privateKey.publicKey)

            if list {
                guard !denylist.revoked.isEmpty else {
                    print("Denylist for '\(resolvedProduct)' is empty.")
                    return
                }
                print("Denylist for '\(resolvedProduct)' sequence \(denylist.sequence) (\(denylist.revoked.count) entr\(denylist.revoked.count == 1 ? "y" : "ies")):")
                for entry in denylist.revoked.sorted(by: { $0.keyID < $1.keyID }) {
                    print("  #\(entry.keyID)\(entry.note.map { "  — \(terminalSafe($0))" } ?? "")")
                }
                return
            }

            guard let keyID else {
                throw CLIError.message("pass a key id to revoke, or --list to view the denylist")
            }
            try denylist.appendRevocation(keyID: keyID, note: note)
            try denylist.write(to: denylistURL, privateKey: privateKey)
            print("Revoked key id \(keyID)\(note.map { " (\(terminalSafe($0)))" } ?? "") → \(denylistURL.path)")
            print("Bundle this file into your next app release to enforce it.")
        }
    }
}
