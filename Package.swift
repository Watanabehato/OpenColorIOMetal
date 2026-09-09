// swift-tools-version: 6.0
import PackageDescription
import Foundation

let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources")
let nativeSources = ["OpenColorIOMetal", "OpenColorIOConfig"].flatMap { directory -> [String] in
    let root = sourceRoot.appendingPathComponent(directory)
    let files = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
    return files.filter { $0.hasSuffix(".swift") }.map { "\(directory)/\($0)" }
}.sorted()

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
                sources: nativeSources,
                resources: [.copy("OpenColorIOMetal/Resources/Catalogue")],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation")]),
        .executableTarget(name: "OCIOCLI", dependencies: ["OpenColorIOMetal"], path: "Sources/OCIOCLI"),
        .testTarget(name: "OpenColorIOMetalTests", dependencies: ["OpenColorIOMetal"]),
        .testTarget(name: "OpenColorIOConfigTests", dependencies: ["OpenColorIOMetal"], exclude: ["Fixtures"])
    ],
    swiftLanguageModes: [.v6]
)
