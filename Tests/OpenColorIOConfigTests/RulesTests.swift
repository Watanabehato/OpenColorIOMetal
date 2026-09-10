import XCTest
@testable import OpenColorIOMetal

final class RulesTests: XCTestCase {
    private let yaml = """
    ocio_profile_version: 2.5
    roles: {default: Linear, scene_linear: Linear}
    colorspaces:
      - !<ColorSpace> {name: Linear, aliases: [lin], encoding: scene-linear}
      - !<ColorSpace> {name: Log, encoding: log}
      - !<ColorSpace> {name: Raw, isdata: true}
    file_rules:
      - !<Rule> {name: Camera, colorspace: Log, pattern: '*camera_[a-c]?', extension: exr}
      - !<Rule> {name: Data, colorspace: Raw, regex: '.*[.]data'}
      - !<Rule> {name: ColorSpaceNamePathSearch}
      - !<Rule> {name: Default, colorspace: scene_linear}
    viewing_rules:
      - !<Rule> {name: Scene, encodings: [scene-linear, log]}
      - !<Rule> {name: LinearOnly, colorspaces: [scene_linear]}
    active_views: [Raw, Film, Linear]
    displays:
      Monitor:
        - !<View> {name: Film, colorspace: Linear, rule: Scene}
        - !<View> {name: Linear, colorspace: Linear, rule: LinearOnly}
        - !<View> {name: Raw, colorspace: Raw}
    """

    func testFileRulePriorityExtensionsAndPathSearch() throws {
        let config = try OCIOConfigDocument(yaml: yaml, environment: [:])
        XCTAssertEqual(try config.fileRule(for: "/shot/camera_b7.EXR").target, "Log")
        XCTAssertEqual(try config.fileRule(for: "/shot/log/file.data").target, "Raw")
        XCTAssertEqual(try config.fileRule(for: "/shot/Linear/image_log.exr").target, "Log")
        XCTAssertEqual(config.colorSpaceName(in: "my_LINEAR.exr"), "Linear")
        XCTAssertEqual(try config.fileRule(for: "image.tif").target, "Linear")
        XCTAssertTrue(try config.fileRule(for: "image.tif").isDefault)
        XCTAssertEqual(try config.fileRule(for: "/shot/Camera_b7.EXR").ruleName, "Default")
    }

    func testViewingRuleEncodingsRolesAndActiveOrder() throws {
        let config = try OCIOConfigDocument(yaml: yaml, environment: [:])
        XCTAssertEqual(try config.views(display: "Monitor", source: "Linear").map(\.name), ["Raw", "Film", "Linear"])
        XCTAssertEqual(try config.views(display: "monitor", source: "Log").map(\.name), ["Raw", "Film"])
        XCTAssertEqual(try config.views(display: "Monitor", source: "Raw").map(\.name), ["Raw"])
    }
}
