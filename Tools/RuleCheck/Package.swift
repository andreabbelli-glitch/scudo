// swift-tools-version: 6.0
import PackageDescription

// Command-line companion that runs the app's filtering pipeline on a Mac:
// downloads the real lists, converts them with ScudoKit, compiles the result
// with WebKit (the same engine Safari uses) and runs an end-to-end blocking
// test in a WKWebView. No iPhone or Xcode needed.
let package = Package(
    name: "RuleCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/ScudoKit"),
    ],
    targets: [
        .executableTarget(
            name: "rulecheck",
            dependencies: [
                .product(name: "ScudoKit", package: "ScudoKit"),
                .product(name: "ScudoShared", package: "ScudoKit"),
            ]
        ),
    ]
)
