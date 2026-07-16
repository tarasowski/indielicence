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
        // 1.7.2 is the newest release compatible with this package's Swift 5.9 floor.
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        // Verification-only library. Zero secrets, zero dependencies beyond
        // CryptoKit (plus Security for LicenseStore's legacy Keychain migration).
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
