// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScudoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // Tiny module shared with the content blocker extensions: only file
        // locations and identifiers, no heavy dependencies (the extensions run
        // under a ~24 MB memory limit).
        .library(name: "ScudoShared", targets: ["ScudoShared"]),
        // Everything the app needs: filter catalog, downloads, conversion.
        .library(name: "ScudoKit", targets: ["ScudoKit"]),
    ],
    dependencies: [
        // AdGuard's converter from AdBlock/AdGuard syntax to Safari content
        // blocking JSON (GPL-3.0).
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.1"),
    ],
    targets: [
        .target(name: "ScudoShared"),
        .target(
            name: "ScudoKit",
            dependencies: [
                "ScudoShared",
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
            ]
        ),
        .testTarget(
            name: "ScudoKitTests",
            dependencies: ["ScudoKit", "ScudoShared"]
        ),
    ]
)
