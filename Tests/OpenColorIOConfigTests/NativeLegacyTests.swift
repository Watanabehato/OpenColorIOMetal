import Foundation
import Metal
import XCTest
@testable import OpenColorIOMetal

final class NativeLegacyTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }
    private struct Reference: Decodable {
        struct Case: Decodable {
            let file: String
            let direction: String
            let input: [Float]
            let expected: [String]
        }
        let oracleVersion: String
        let cases: [Case]
    }
    func testLegacyReadersAndMetalMatchUpstreamBothDirections() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal hardware required for legacy LUT numerical conformance") }
        let references = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtures.appendingPathComponent("legacy-reference.json")))
        XCTAssertEqual(references.cases.count, 22)
        let engine = try MetalColorEngine()
        for reference in references.cases {
            let yaml = """
            ocio_profile_version: 2.5
            colorspaces:
              - !<ColorSpace> {name: Linear}
              - !<ColorSpace>
                name: Encoded
                to_scene_reference: !<FileTransform> {src: \(reference.file), interpolation: linear, direction: \(reference.direction)}
            """
            let document = try OCIOConfigDocument(yaml: yaml, workingDirectory: fixtures.appendingPathComponent("Legacy"), environment: [:])
            let processor = try engine.nativeProcessor(configuration: document, source: "Encoded", destination: "Linear")
            let actual = try processor.processRGBA(reference.input)
            XCTAssertEqual(actual.count, reference.expected.count)
            for (index, text) in reference.expected.enumerated() {
                let expected = try XCTUnwrap(Float(text))
                if expected.isNaN { XCTAssertTrue(actual[index].isNaN, "\(reference.file) \(reference.direction) \(index)") }
                else if expected.isInfinite { XCTAssertEqual(actual[index], expected) }
                else { XCTAssertEqual(actual[index], expected, accuracy: 0.00005 + abs(expected) * 0.0002,
                                      "\(reference.file) \(reference.direction) \(index)") }
            }
        }
    }
    func testMalformedLegacyFilesFail() throws {
        XCTAssertThrowsError(try OCIOLUTFile.pandora("channel 3d\nin -8\nout 4096\nvalues red green blue"))
        XCTAssertThrowsError(try OCIOLUTFile.threeDL("<xml>"))
        XCTAssertThrowsError(try OCIOLUTFile.truelight("# Truelight Cube v2.0\n# width 2 2 3\n# cube\n0 0 0"))
        XCTAssertThrowsError(try OCIOLUTFile.iridasLook("<look><LUT><size>2</size><data>xx</data></LUT></look>"))
    }
}
