// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-foundation",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AgentPresentation", targets: ["AgentPresentation"]),
        .library(name: "AgentViews", targets: ["AgentViews"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/mattsp1290/ag-ui-swift.git",
            revision: "9412aab2549e06e165ada85fe6346b9b6e5a0f2b"
        ),
    ],
    targets: [
        .target(name: "AgentPresentation"),
        .target(
            name: "AgentViews",
            dependencies: [
                "AgentPresentation",
                .product(name: "AGUICore", package: "ag-ui-swift"),
            ]
        ),
        .testTarget(name: "AgentPresentationTests", dependencies: ["AgentPresentation"]),
        .testTarget(name: "AgentViewsTests", dependencies: ["AgentViews"]),
    ],
    swiftLanguageModes: [.v6]
)
