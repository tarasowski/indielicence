// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IndieLicense",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "indielicense", targets: ["IndieLicenseCLI"]),
        .library(name: "IndieLicense", targets: ["IndieLicense"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Verification-only library. Zero secrets, zero dependencies beyond
        // CryptoKit (plus Security for the Keychain-backed LicenseStore).
        .target(
            name: "IndieLicense",
            path: "Sources/IndieLicense"
        ),
        // The CLI. This is the only place private keys are ever handled.
        .executableTarget(
            name: "IndieLicenseCLI",
            dependencies: [
                "IndieLicense",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "IndieLicenseTests",
            dependencies: ["IndieLicense", "IndieLicenseCLI"],
            path: "Tests/IndieLicenseTests"
        ),
    ]
)
