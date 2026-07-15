// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProbierzDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProbierzDesktop", targets: ["ProbierzDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/wisent-ai/wisent-desktop-auth.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ProbierzDesktop",
            dependencies: [
                .product(name: "WisentAuth", package: "wisent-desktop-auth"),
            ]
        ),
    ]
)
