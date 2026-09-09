import Foundation
import XCTest
@testable import OpenColorIOMetal
#if canImport(Metal)
import Metal
#endif

final class NativeCompilerTests: XCTestCase {
    struct ReferenceFile: Decodable {
        let schemaVersion: Int
        let oracleVersion: String
        let cases: [ReferenceCase]
    }
    struct ReferenceCase: Decodable {
        let name: String
        let yaml: String
        let source: String
        let destination: String
        let input: [[Float]]
        let expected: [[Float]]
    }
    private func references() throws -> ReferenceFile {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/native-reference.json")
        return try JSONDecoder().decode(ReferenceFile.self, from: Data(contentsOf: url))
    }

    func testEveryOracleCaseCompilesToNativeMetal() throws {
        let reference = try references()
        XCTAssertEqual(reference.schemaVersion, 1)
        XCTAssertGreaterThanOrEqual(reference.cases.count, 46)
        for entry in reference.cases {
            let config = try OCIOConfigDocument(yaml: entry.yaml, environment: [:])
            let shader = try config.metalShader(from: entry.source, to: entry.destination)
            XCTAssertTrue(shader.source.contains("kernel void ocio_kernel"), entry.name)
            XCTAssertTrue(shader.source.contains("output[index] = pixel"), entry.name)
        }
    }

    func testSingularMatricesAndInvalidParametersFail() throws {
        XCTAssertThrowsError(try invertMatrix(Array(repeating: 0.0, count: 16)))
        let inverted = try invertMatrix([2, 0, 0, 0, 0, 4, 0, 0, 0, 0, 5, 0, 0, 0, 0, 1])
        XCTAssertEqual(inverted[0], 0.5)
        XCTAssertEqual(inverted[5], 0.25)
        XCTAssertEqual(inverted[10], 0.2)
        let config = try OCIOConfigDocument(yaml: """
        ocio_profile_version: 2.5
        colorspaces:
          - !<ColorSpace> {name: Linear}
          - !<ColorSpace> {name: Bad, to_scene_reference: !<LogTransform> {base: 1}}
        """)
        XCTAssertThrowsError(try config.metalShader(from: "Bad", to: "Linear"))
    }

    func testLUTFormatsDomainsAndIndices() throws {
        let operations = try OCIOLUTFile.cube("""
        TITLE "test"
        LUT_1D_SIZE 2
        LUT_3D_SIZE 2
        LUT_1D_INPUT_RANGE -1 2
        0 0 0
        1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
        XCTAssertEqual(operations.count, 2)
        guard case let .lut(shaper) = operations[0], case let .lut(cube) = operations[1] else { return XCTFail("expected LUTs") }
        XCTAssertEqual(shaper.domainMinimum, [-1, -1, -1])
        XCTAssertEqual(shaper.domainMaximum, [2, 2, 2])
        XCTAssertEqual(cube.values.count, 24)
        XCTAssertEqual(cube.values[3], 1) // Metal x (red) varies fastest.
        let single = try OCIOLUTFile.spi1d("Version 1\nFrom -0.1 1.1\nLength 2\nComponents 1\n{\n0.2\n0.8\n}\n")
        XCTAssertEqual(single.values, [0.2, 0.2, 0.2, 0.8, 0.8, 0.8])
        XCTAssertThrowsError(try OCIOLUTFile.spi1d("Version 1\nLength 2\nComponents 3\n{\n0 0 0\n}\n"))
        XCTAssertThrowsError(try OCIOLUTFile.cube("LUT_3D_SIZE 2\n0 0 0\n"))
        let matrix = try OCIOLUTFile.spimtx("1 0 0 65535\n0 1 0 32767.5\n0 0 1 0")
        XCTAssertEqual(matrix.parameters["offset"]?.array?.compactMap(\.string), ["1.0", "0.5", "0.0", "0.0"])
    }

    func testCDLXMLSelectionAndMalformedInput() throws {
        let xml = """
        <ColorCorrectionCollection>
          <ColorCorrection id="a"><SOPNode><Slope>1 1 1</Slope><Offset>0 0 0</Offset><Power>1 1 1</Power></SOPNode></ColorCorrection>
          <ColorCorrection id="b"><SOPNode><Slope>2 2 2</Slope><Offset>0 0 0</Offset><Power>1 1 1</Power></SOPNode><SatNode><Saturation>0.5</Saturation></SatNode></ColorCorrection>
        </ColorCorrectionCollection>
        """
        let selected = try CDLXMLFile.read(xml, cccID: "b")
        guard case let .transform(transform) = selected[0] else { return XCTFail("expected CDL") }
        XCTAssertEqual(transform.parameters["sat"]?.string, "0.5")
        XCTAssertThrowsError(try CDLXMLFile.read(xml, cccID: "missing"))
        XCTAssertThrowsError(try CDLXMLFile.read("<ColorCorrection>", cccID: nil))
    }

    #if canImport(Metal)
    func testMetalMatchesOCIOOracleForCustomOperations() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal hardware unavailable; numerical native-shader verification did not run") }
        let engine = try MetalColorEngine(catalogue: OCIOCatalogue.bundled(), device: device)
        let reference = try references()
        for entry in reference.cases {
            let config = try OCIOConfigDocument(yaml: entry.yaml, environment: [:])
            let processor = try engine.nativeProcessor(configuration: config, source: entry.source, destination: entry.destination)
            let actual = try processor.processRGBA(entry.input.flatMap { $0 })
            let expected = entry.expected.flatMap { $0 }
            XCTAssertEqual(actual.count, expected.count)
            for index in actual.indices {
                let tolerance = 0.00003 + 0.0002 * abs(expected[index])
                XCTAssertEqual(actual[index], expected[index], accuracy: tolerance, "\(entry.name), channel \(index), OCIO \(reference.oracleVersion)")
            }
        }
    }
    #endif
}
