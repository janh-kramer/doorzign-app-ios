// swift-tools-version: 5.10
// DoorZignKit: generierter API-Client (DoorZignAPI) und plattformunabhängige Kernlogik (DoorZignCore).
// Der Vertrag wird per Symlink aus doorzign-app-coordination/contract/mobile-v1.yaml referenziert, nicht kopiert.
import PackageDescription

let package = Package(
    name: "DoorZignKit",
    defaultLocalization: "de",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DoorZignAPI", targets: ["DoorZignAPI"]),
        .library(name: "DoorZignCore", targets: ["DoorZignCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DoorZignAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .target(
            name: "DoorZignCore",
            dependencies: [
                "DoorZignAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "DoorZignCoreTests", dependencies: ["DoorZignCore"]),
    ]
)
