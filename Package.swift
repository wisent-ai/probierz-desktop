// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProbierzDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProbierzDesktop", targets: ["ProbierzDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/wisent-ai/wisent-desktop-auth.git", revision: "a8aed6d2f9e3e2ea22799ee0cfe8bae2358a70ad"),
        .package(url: "https://github.com/wisent-ai/wisent-desktop-update.git", exact: "0.2.0"),
        .package(url: "https://github.com/wisent-ai/echo.git", exact: "0.1.2"),
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
            ]
        ),
    ]
)
