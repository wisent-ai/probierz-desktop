// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProbierzDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProbierzDesktop", targets: ["ProbierzDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/wisent-ai/wisent-desktop-auth.git", exact: "0.3.3"),
        .package(url: "https://github.com/wisent-ai/wisent-desktop-update.git", exact: "0.2.0"),
        // 0.3.0 is the tag that ships `JourneyResource`, the loader that reads
        // the bundled journey definition out of a packaged app.
        .package(url: "https://github.com/wisent-ai/echo.git", exact: "0.3.0"),
        .package(url: "https://github.com/wisent-ai/wisent-components.git", exact: "0.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "ProbierzDesktop",
            dependencies: [
                .product(name: "WisentAuth", package: "wisent-desktop-auth"),
                .product(name: "WisentDesktopUpdate", package: "wisent-desktop-update"),
                .product(name: "WisentOnboarding", package: "echo"),
                .product(name: "WisentDesignSystem", package: "wisent-components"),
            ],
            path: "Sources/ProbierzDesktop",
            // `probierz-desktop-first-use.json` is the offline journey
            // definition and the identity a published definition is checked
            // against.
            resources: [.process("Resources")]
        ),
    ]
)
