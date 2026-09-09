import XCTest
@testable import OpenColorIOMetal

final class YAMLTests: XCTestCase {
    func testBlockTagsFlowCollectionsAndComments() throws {
        let value = try YAMLParser().parse("""
        version: 2.5
        nodes:
          - !<GroupTransform>
            children:
              - !<MatrixTransform> {matrix: [1, 0, 0, 0,
                  0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], offset: [0, 0, 0, 0]}
              - !<FileTransform> {src: "path # literal.cube"} # trailing
        """)
        let node = try XCTUnwrap(value["nodes"]?.array?.first)
        XCTAssertEqual(node.tag, "GroupTransform")
        let children = try XCTUnwrap(node["children"]?.array)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0]["matrix"]?.array?.count, 16)
        XCTAssertEqual(children[1]["src"]?.string, "path # literal.cube")
    }

    func testAnchorsMergesAndOverrides() throws {
        let value = try YAMLParser().parse("""
        defaults: &defaults {bitdepth: 32f, isdata: false}
        extra: &extra {family: Input, bitdepth: 16f}
        space: !<ColorSpace>
          <<: [*defaults, *extra]
          name: Camera
          bitdepth: 10ui
        copied: *defaults
        """)
        XCTAssertEqual(value["space"]?.tag, "ColorSpace")
        XCTAssertEqual(value["space"]?["family"]?.string, "Input")
        XCTAssertEqual(value["space"]?["bitdepth"]?.string, "10ui")
        XCTAssertEqual(value["copied"]?["bitdepth"]?.string, "32f")
    }

    func testStringsAndExactNumericText() throws {
        let value = try YAMLParser().parse(#"""
        literal: |-
          alpha
          beta # retained
        folded: >-
          one
          two
        quoted: "\u4E2D\u6587 \U0001F308\nend"
        single: 'it''s literal \n'
        null_value: null
        quoted_null: "null"
        number: 0.12345678901234567890123456789
        """#)
        XCTAssertEqual(value["literal"]?.string, "alpha\nbeta # retained")
        XCTAssertEqual(value["folded"]?.string, "one two")
        XCTAssertEqual(value["quoted"]?.string, "中文 🌈\nend")
        XCTAssertEqual(value["single"]?.string, "it's literal \\n")
        XCTAssertEqual(value["null_value"], .null)
        XCTAssertEqual(value["quoted_null"]?.string, "null")
        XCTAssertEqual(value["number"]?.string, "0.12345678901234567890123456789")
    }

    func testIndentlessSequenceAndCompactMapping() throws {
        let value = try YAMLParser().parse("""
        root:
        - name: first
          values: [a, b]
        - name: second
          values: []
        trailing: yes
        """)
        XCTAssertEqual(value["root"]?.array?.count, 2)
        XCTAssertEqual(value["root"]?.array?[1]["name"]?.string, "second")
        XCTAssertEqual(value["trailing"]?.string, "yes")
    }

    func testMalformedDocumentsFail() {
        for yaml in ["a: 1\na: 2", "a: *missing", "a: [1, 2", "a: {x: 1, x: 2}", "a: \"\\q\"", "a: &self {child: *self}", "a: 1\n---\nb: 2"] {
            XCTAssertThrowsError(try YAMLParser().parse(yaml), yaml)
        }
    }
}
