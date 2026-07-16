// Generates transparent, app-owned integration source. No runtime SDK or network.

import ArgumentParser
import CryptoKit
import Darwin
import Foundation

enum IntegrationPlatform: String, ExpressibleByArgument, CaseIterable {
    case swift
}

enum IntegrationUI: String, ExpressibleByArgument, CaseIterable {
    case none, swiftui
}

enum IntegrationDenylist: String, ExpressibleByArgument, CaseIterable {
    case none, bundled
}

enum IntegrationTrialPolicy: String, ExpressibleByArgument, CaseIterable {
    case soft, hard
}

struct Integrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate app-owned licensing source files without adding an SDK.",
        discussion: """
        The generated files are ordinary source code: the standalone verifier,
        public configuration, persistence/validation plumbing, an optional
        neutral SwiftUI key-entry view, and a short integration checklist.

        Existing files are never overwritten. Private key material is never
        copied, printed, or written to the application.
        """)

    @Argument(help: "Target platform. Currently supported: swift.")
    var platform: IntegrationPlatform

    @Option(help: "Product id. Required with --public-key; otherwise inferred from --key-dir when unambiguous.")
    var product: String?

    @Option(name: .customLong("public-key"), help: "Base64 public key. When omitted, safely derive it from --key-dir.")
    var publicKeyBase64: String?

    @Option(name: .customLong("build-date"), help: "Immutable release day in YYYY-MM-DD UTC.")
    var buildDate: String

    @Option(help: "Directory that will receive the generated app-owned files.")
    var output: String

    @Option(help: "none or swiftui. The SwiftUI view is neutral and price-free.")
    var ui: IntegrationUI = .none

    @Option(help: "none or bundled. Bundled expects <product>.denylist.json in the app target.")
    var denylist: IntegrationDenylist = .none

    @Option(name: .customLong("trial"), help: """
    Optional keyless trial length like '7d'. The trial starts on the customer's \
    first launch and needs no license key; omit for no built-in trial.
    """)
    var trial: String?

    @Option(name: .customLong("trial-policy"), help: """
    soft or hard. Soft: the app keeps running without full access and decides \
    feature-level consequences itself. Hard: the generated LicenseGateView \
    replaces the app's content with a non-dismissible key-entry lock screen \
    whenever there is no valid key and no active keyless trial.
    """)
    var trialPolicy: IntegrationTrialPolicy = .soft

    @Option(name: .customLong("purchase-url"), help: """
    Optional https link where customers buy a license key. Shown as a 'Buy a \
    license' button in the generated UI; only ever opened in the browser.
    """)
    var purchaseURL: String?

    @OptionGroup var keyDirOption: KeyDirOption

    func run() throws {
        let resolvedProduct: String
        let publicKey: String
        if let supplied = publicKeyBase64 {
            guard let product else {
                throw CLIError.message("--product is required when using --public-key")
            }
            try validateProductID(product)
            try validatePublicKey(supplied)
            resolvedProduct = product
            publicKey = supplied
        } else {
            resolvedProduct = try keyDirOption.resolveProduct(product)
            publicKey = try keyDirOption.directory.loadPrivateKey(product: resolvedProduct)
                .publicKey.rawRepresentation.base64EncodedString()
        }

        let buildDay = try parseBuildDay(buildDate)
        let trialDays = try trial.map { try parseDurationDays($0, flag: "--trial") }
        let purchase = try purchaseURL.map(validatePurchaseURL)
        let outputURL = URL(
            fileURLWithPath: (output as NSString).expandingTildeInPath,
            isDirectory: true).standardizedFileURL

        var files: [(String, String)] = [
            ("LicenseVerifier.swift", EmbeddedTemplates.verifier),
            ("LicenseConfig.swift", try render(
                EmbeddedTemplates.licenseConfig,
                values: [
                    "PUBLIC_KEY": publicKey,
                    "PRODUCT": resolvedProduct,
                    "BUILD_DAY": String(buildDay),
                    "DENYLIST_URL": denylistExpression(product: resolvedProduct),
                    "TRIAL_DAYS": trialDays.map(String.init) ?? "nil",
                    "PURCHASE_URL": purchase.map { "URL(string: \"\($0)\")" } ?? "nil",
                    "HARD_GATE": trialPolicy == .hard ? "true" : "false",
                ])),
            ("LicenseManager.swift", EmbeddedTemplates.licenseManager),
        ]
        if ui == .swiftui {
            files.append(("LicenseActivationView.swift", EmbeddedTemplates.activationView))
            files.append(("LicenseBadgeView.swift", EmbeddedTemplates.badgeView))
            files.append(("LicenseGateView.swift", EmbeddedTemplates.gateView))
        }
        if trialPolicy == .hard && ui != .swiftui {
            throw CLIError.message(
                "--trial-policy hard requires --ui swiftui: the lock screen is enforced by the generated LicenseGateView")
        }
        files.append(("LICENSE_INTEGRATION.md", try render(
            EmbeddedTemplates.integrationGuide,
            values: [
                "PRODUCT": resolvedProduct,
                "BUILD_DATE": buildDate,
                "DENYLIST_DESCRIPTION": denylist == .bundled
                    ? "bundled signed `\(resolvedProduct).denylist.json`"
                    : "disabled",
                "TRIAL_DESCRIPTION": trialDays.map {
                    "\($0) day\($0 == 1 ? "" : "s"), starts on first launch"
                } ?? "disabled",
                "PURCHASE_DESCRIPTION": purchase.map { "`\($0)`" } ?? "not configured",
                "TRIAL_POLICY_DESCRIPTION": trialPolicy == .hard
                    ? "hard — LicenseGateView locks the app without full access"
                    : "soft — the app decides feature-level consequences",
                "UI_DESCRIPTION": ui == .swiftui ? "included" : "not generated",
            ])))

        try writeScaffold(files, to: outputURL)

        print("Generated Swift licensing plumbing for '\(resolvedProduct)' in \(outputURL.path)")
        print("Add the .swift files to the app target, then follow LICENSE_INTEGRATION.md.")
        if ui == .swiftui && purchase == nil {
            print("Tip: pass --purchase-url <https-link> to show a 'Buy a license' button,")
            print("or set LicenseConfig.purchaseURL later in the generated code.")
        }
        print("Only the public key was embedded; no private key or key-id state was copied.")
    }

    private func denylistExpression(product: String) -> String {
        switch denylist {
        case .none:
            return "nil"
        case .bundled:
            return "Bundle.main.url(forResource: \"\(product).denylist\", withExtension: \"json\")"
        }
    }
}

private func validatePurchaseURL(_ value: String) throws -> String {
    // The value is interpolated into a generated Swift string literal, so the
    // character set is restricted to printable ASCII without quotes/backslashes.
    let allowed = value.utf8.allSatisfy { (0x21...0x7e).contains($0) && $0 != 0x22 && $0 != 0x5c }
    guard allowed, value.utf8.count <= 2048,
          let url = URL(string: value), url.absoluteString == value,
          url.scheme == "https", let host = url.host, !host.isEmpty else {
        throw CLIError.message("--purchase-url must be a plain absolute https URL")
    }
    return value
}

private func validatePublicKey(_ value: String) throws {
    guard let raw = Data(base64Encoded: value), raw.count == 32,
          raw.base64EncodedString() == value,
          (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else {
        throw CLIError.message("--public-key is not canonical base64 Ed25519 public key material")
    }
}

private func parseBuildDay(_ value: String) throws -> Int {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard value.utf8.count == 10, let date = formatter.date(from: value),
          formatter.string(from: date) == value else {
        throw CLIError.message("--build-date must be a real UTC date in YYYY-MM-DD form")
    }
    return Int(floor(date.timeIntervalSince1970 / 86_400))
}

private func render(_ template: String, values: [String: String]) throws -> String {
    var rendered = template
    for (name, value) in values {
        rendered = rendered.replacingOccurrences(of: "{{\(name)}}", with: value)
    }
    guard !rendered.contains("{{") else {
        throw CLIError.message("internal integration template contains an unresolved placeholder")
    }
    return rendered
}

private func writeScaffold(_ files: [(String, String)], to directory: URL) throws {
    var info = stat()
    let existed: Bool
    if lstat(directory.path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CLIError.message("integration output must be a real directory (symlinks are refused): \(directory.path)")
        }
        guard info.st_uid == getuid() else {
            throw CLIError.message("integration output is not owned by the current user: \(directory.path)")
        }
        existed = true
    } else if errno == ENOENT {
        existed = false
    } else {
        throw CLIError.message("cannot inspect integration output: \(directory.path)")
    }

    for (name, _) in files {
        let target = directory.appendingPathComponent(name)
        if lstat(target.path, &info) == 0 {
            throw CLIError.message("refusing to overwrite existing integration file: \(target.path)")
        }
        guard errno == ENOENT else {
            throw CLIError.message("cannot inspect integration target: \(target.path)")
        }
    }

    if !existed {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
    }

    var created: [URL] = []
    do {
        for (name, contents) in files {
            let target = directory.appendingPathComponent(name)
            try secureExclusiveWrite(Data(contents.utf8), to: target, mode: 0o644)
            created.append(target)
        }
    } catch {
        for target in created { try? FileManager.default.removeItem(at: target) }
        if !existed { try? FileManager.default.removeItem(at: directory) }
        throw error
    }
}
