import Foundation
import XCTest
@testable import OpenColorIOMetal

final class ConfigurationTests: XCTestCase {
    private let graph = """
    ocio_profile_version: 2.5
    environment: {SPACE: Camera}
    roles: {scene_linear: Linear}
    default_view_transform: Bridge
    colorspaces:
      - !<ColorSpace> {name: Linear, aliases: [lin]}
      - !<ColorSpace>
        name: Camera
        to_scene_reference: !<LogAffineTransform> {base: 10, direction: inverse}
      - !<ColorSpace> {name: Raw, isdata: true}
      - !<ColorSpace> {name: Equal A, equalitygroup: identical}
      - !<ColorSpace> {name: Equal B, equalitygroup: identical}
    display_colorspaces:
      - !<ColorSpace>
        name: Display
        from_display_reference: !<ExponentTransform> {value: [0.4545, 0.4545, 0.4545, 1]}
    view_transforms:
      - !<ViewTransform>
        name: Bridge
        from_scene_reference: !<MatrixTransform> {offset: [0.1, 0, 0, 0]}
    shared_views:
      - !<View> {name: Standard, view_transform: Bridge, display_colorspace: Display}
    displays:
      Monitor:
        - !<Views> [Standard]
        - !<View> {name: Raw, colorspace: Raw}
    named_transforms:
      - !<NamedTransform>
        name: Double
        aliases: [twice]
        forward_transform: !<MatrixTransform> {offset: [1, 0, 0, 0]}
    """

    func testNamesRolesContextAndSharedViews() throws {
        let config = try OCIOConfigDocument(yaml: graph, environment: [:])
        XCTAssertEqual(try config.colorSpace(named: "SCENE_LINEAR").name, "Linear")
        XCTAssertEqual(try config.colorSpace(named: "LIN").name, "Linear")
        XCTAssertEqual(try config.colorSpace(named: "${SPACE}").name, "Camera")
        XCTAssertEqual(config.displays["Monitor"]?.map(\.name), ["Standard", "Raw"])
        XCTAssertThrowsError(try config.colorSpace(named: "Typo"))
    }

    func testReferenceBridgeAndEffectiveDirections() throws {
        let config = try OCIOConfigDocument(yaml: graph, environment: [:])
        let forward = try config.conversionPlan(from: "Camera", to: "Display")
        XCTAssertEqual(forward.map { $0.transform.type }, ["LogAffineTransform", "MatrixTransform", "ExponentTransform"])
        XCTAssertEqual(forward.map(\.direction), [.inverse, .forward, .forward])
        let reverse = try config.conversionPlan(from: "Display", to: "Camera")
        XCTAssertEqual(reverse.map { $0.transform.type }, ["ExponentTransform", "MatrixTransform", "LogAffineTransform"])
        XCTAssertEqual(reverse.map(\.direction), [.inverse, .inverse, .forward])
        XCTAssertEqual(try config.namedTransformPlan("twice", direction: .inverse).first?.direction, .inverse)
        XCTAssertTrue(try config.conversionPlan(from: "Camera", to: "Raw").isEmpty)
        XCTAssertFalse(try config.conversionPlan(from: "Camera", to: "Raw", dataBypass: false).isEmpty)
        XCTAssertTrue(try config.conversionPlan(from: "Equal A", to: "Equal B").isEmpty)
    }

    func testUnknownTransformsNeverBecomeIdentity() throws {
        let invalid = graph.replacingOccurrences(of: "LogAffineTransform", with: "TypoTransform")
        XCTAssertThrowsError(try OCIOConfigDocument(yaml: invalid)) { error in
            guard case OCIOConfigError.unknownTransform("TypoTransform") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExplicitReverseTransformWins() throws {
        let config = try OCIOConfigDocument(yaml: """
        ocio_profile_version: 1
        colorspaces:
          - !<ColorSpace> {name: Reference}
          - !<ColorSpace>
            name: Encoded
            to_reference: !<MatrixTransform> {offset: [1, 0, 0, 0]}
            from_reference: !<RangeTransform> {min_in_value: 0, min_out_value: 0}
        """)
        XCTAssertEqual(try config.conversionPlan(from: "Reference", to: "Encoded").first?.transform.type, "RangeTransform")
        XCTAssertEqual(try config.conversionPlan(from: "Encoded", to: "Reference").first?.transform.type, "MatrixTransform")
    }

    func testMissingBridgeAndDuplicateAliasesFail() {
        XCTAssertThrowsError(try OCIOConfigDocument(yaml: graph.replacingOccurrences(of: "aliases: [lin]", with: "aliases: [Camera]")))
        let missing = graph.replacingOccurrences(of: "default_view_transform: Bridge", with: "default_view_transform: Missing")
        XCTAssertThrowsError(try OCIOConfigDocument(yaml: missing).conversionPlan(from: "Camera", to: "Display"))
    }

    func testContextExpansionAndSearchOrder() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("luts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let lut = temp.appendingPathComponent("luts/test.cube")
        try "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".write(to: lut, atomically: true, encoding: .utf8)
        let context = OCIOContext(variables: ["ROOT": "luts", "SOURCE": "test", "NESTED": "${SOURCE}"], searchPaths: ["$ROOT"], workingDirectory: temp)
        XCTAssertEqual(try context.resolve("$SOURCE/${NESTED}/%SOURCE%"), "test/test/test")
        XCTAssertEqual(try context.resolveFile("${SOURCE}.cube"), lut)
        XCTAssertThrowsError(try context.resolve("$MISSING"))
        XCTAssertThrowsError(try OCIOContext(variables: ["A": "$B", "B": "$A"]).resolve("$A"))
        XCTAssertThrowsError(try context.resolveFile("missing.cube"))
    }

    /// All shipped configurations are parsed independently of precompiled shaders.
    /// The expected totals come from OCIO 2.6.0-dev's own Config API.
    func testEveryUpstreamBuiltinConfigurationAndEveryPairPlan() throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
        let fixtures = try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ocio" }
        XCTAssertEqual(fixtures.count, 8)
        for fixture in fixtures {
            let config = try OCIOConfigDocument(contentsOf: fixture, environment: [:])
            XCTAssertFalse(config.colorSpaces.isEmpty, fixture.lastPathComponent)
            XCTAssertFalse(config.displays.isEmpty, fixture.lastPathComponent)
            for source in config.colorSpaces {
                XCTAssertEqual(try config.colorSpace(named: source.name), source)
                for alias in source.aliases { XCTAssertEqual(try config.colorSpace(named: alias), source) }
                for destination in config.colorSpaces {
                    _ = try config.conversionPlan(from: source.name, to: destination.name)
                }
            }
            for (role, name) in config.roles { XCTAssertEqual(try config.colorSpace(named: role), try config.colorSpace(named: name)) }
            for named in config.namedTransforms {
                XCTAssertFalse(try config.namedTransformPlan(named.name).isEmpty)
                XCTAssertFalse(try config.namedTransformPlan(named.name, direction: .inverse).isEmpty)
            }
        }
    }
}
