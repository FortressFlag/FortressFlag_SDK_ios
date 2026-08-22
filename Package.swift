// swift-tools-version: 6.0
//
// FortressFlag iOS client SDK.
//
// Zero dependencies, deliberately (Founding CLAUDE.md §8.1). Every dependency is a supply-chain
// risk in code that ships inside our customers' apps, and everything this package needs —
// Ed25519, SHA-256, CSPRNG, keychain, HTTP — is in the platform.

import PackageDescription

let package = Package(
    name: "FortressFlag",
    // iOS 17 is the floor. It buys native Swift concurrency, `Duration`, `OSAllocatedUnfairLock`
    // and the modern CryptoKit surface without back-deployment shims. macOS and visionOS are
    // supported so a multiplatform host app compiles for every destination it targets.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "FortressFlag", targets: ["FortressFlag"]),
        // Shipped as a product, not a test-only target, because customers need to drive the SDK
        // deterministically in *their* tests. If we do not give them a supported way to do that
        // they will reach into our internals and we will break them.
        .library(name: "FortressFlagTestKit", targets: ["FortressFlagTestKit"]),
        // The development flag-list screen. A separate product so an app that does not want a
        // debug surface never compiles it — the same one-package-many-products shape as TestKit.
        .library(name: "FortressFlagDebugUI", targets: ["FortressFlagDebugUI"]),
    ],
    targets: [
        .target(
            name: "FortressFlag",
            // Apple requires a privacy manifest for third-party SDKs. Copied verbatim rather than
            // processed: it must reach the consuming app's bundle unmodified.
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FortressFlagTestKit",
            dependencies: ["FortressFlag"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FortressFlagDebugUI",
            dependencies: ["FortressFlag"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FortressFlagTests",
            dependencies: ["FortressFlag", "FortressFlagTestKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FortressFlagDebugUITests",
            dependencies: ["FortressFlagDebugUI", "FortressFlag", "FortressFlagTestKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
