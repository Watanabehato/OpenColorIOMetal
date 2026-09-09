// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenColorIOMetal",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OpenColorIOMetal", type: .static, targets: ["OpenColorIOMetal"]),
        .executable(name: "ocio-metal", targets: ["OCIOCLI"])
    ],
    targets: [
        .target(name: "OpenColorIOMetal", path: "Sources",
                exclude: ["OCIOCLI"],
                sources: ["OpenColorIOMetal", "OpenColorIOConfig"],
                resources: [.copy("OpenColorIOMetal/Resources/Catalogue")],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation")]),
        .executableTarget(name: "OCIOCLI", dependencies: ["OpenColorIOMetal"], path: "Sources/OCIOCLI"),
        .testTarget(name: "OpenColorIOMetalTests", dependencies: ["OpenColorIOMetal"]),
        .testTarget(name: "OpenColorIOConfigTests", dependencies: ["OpenColorIOMetal"], exclude: ["Fixtures"])
    ],
    swiftLanguageModes: [.v6]
)
