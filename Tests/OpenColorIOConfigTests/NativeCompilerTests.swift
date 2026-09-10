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
    private var fixturesDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true) }

    func testEveryOracleCaseCompilesToNativeMetal() throws {
        let reference = try references()
        XCTAssertEqual(reference.schemaVersion, 1)
        XCTAssertGreaterThanOrEqual(reference.cases.count, 46)
        for entry in reference.cases {
            do {
                let config = try OCIOConfigDocument(yaml: entry.yaml, workingDirectory: fixturesDirectory, environment: [:])
                let shader = try config.metalShader(from: entry.source, to: entry.destination)
                XCTAssertTrue(shader.source.contains("kernel void ocio_kernel"), entry.name)
                XCTAssertTrue(shader.source.contains("output[index] = pixel"), entry.name)
            } catch { XCTFail("\(entry.name): \(error)") }
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

    func testCLFIntegerNormalizationAndRawHalfDecode() throws {
        let matrix = try CTFFile.read("""
        <ProcessList><Matrix inBitDepth="10i" outBitDepth="12i"><Array dim="3 4">
        4 0 0 409.5 0 4 0 0 0 0 4 0
        </Array></Matrix></ProcessList>
        """, relativeTo: fixturesDirectory)
        guard case let .transform(transform) = matrix[0] else { return XCTFail("expected matrix") }
        let p = NativeParameters(transform.parameters, owner: "matrix")
        XCTAssertEqual(try p.vector("matrix", count: 16)[0], 4092.0 / 4095.0, accuracy: 1e-12)
        XCTAssertEqual(try p.vector("offset", count: 4)[0], 0.1, accuracy: 1e-12)
        let raw = try CTFFile.read("""
        <ProcessList><LUT1D inBitDepth="32f" outBitDepth="32f" rawHalfs="true"><Array dim="2 1">0 15360</Array></LUT1D></ProcessList>
        """, relativeTo: fixturesDirectory)
        guard case let .configuredLUT(lut, _, _) = raw[0] else { return XCTFail("expected raw-half LUT") }
        XCTAssertEqual(lut.values, [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(CTFFile.decodeHalfBits(1), Float(1.0 / 16777216.0))
        XCTAssertEqual(CTFFile.decodeHalfBits(0x0400), Float(1.0 / 16384.0))
        XCTAssertEqual(CTFFile.decodeHalfBits(0xfbff), -65504)
        XCTAssertEqual(CTFFile.decodeHalfBits(0x8000).bitPattern, 0x80000000)
        XCTAssertTrue(CTFFile.decodeHalfBits(0x7c00).isInfinite)
        XCTAssertTrue(CTFFile.decodeHalfBits(0x7e00).isNaN)
        XCTAssertThrowsError(try ICCProfile.read(Data(repeating: 0, count: 127)))
        XCTAssertThrowsError(try CTFFile.read("""
        <ProcessList><LUT1D inBitDepth="32f" outBitDepth="32f" halfDomain="true"><Array dim="2 1">0 1</Array></LUT1D></ProcessList>
        """, relativeTo: fixturesDirectory))
    }

    func testProgrammaticLUTTexturePackingAndInverseCompilation() throws {
        let config = try OCIOConfigDocument(yaml: "ocio_profile_version: 2.5\ncolorspaces: []")
        let values = (0...8192).flatMap { index -> [Float] in let x = Float(index) / 8192; return [x, x, x] }
        let lut = try OCIOLUTFile.lut(dimension: 1, size: 8193, values: values)
        let stages = try config.nativeStages(steps: [OCIOConfigTransformStep(transform: OCIOConfigTransform(lut: lut), label: "memory")])
        guard case let .shader(shader) = stages[0] else { return XCTFail("expected shader") }
        XCTAssertEqual(shader.textures[0].width, 4096)
        XCTAssertEqual(shader.textures[0].height, 3)
        XCTAssertEqual(shader.textures[0].values[8192 * 3], 1)
        let inverse = try config.nativeStages(steps: [OCIOConfigTransformStep(transform: OCIOConfigTransform(lut: lut, direction: .inverse), label: "inverse")])
        guard case let .shader(inverseShader) = inverse[0] else { return XCTFail("expected inverse shader") }
        XCTAssertTrue(inverseShader.source.contains("while (high - low > 1u)"))
        XCTAssertThrowsError(try OCIOLUTFile.lut(dimension: 2, size: 2, values: [0, 0, 0, 1, 1, 1]))
    }

    #if canImport(Metal)
    func testMetalMatchesOCIOOracleForCustomOperations() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal hardware unavailable; numerical native-shader verification did not run") }
        let engine = try MetalColorEngine(device: device)
        let reference = try references()
        for entry in reference.cases {
            do {
                let config = try OCIOConfigDocument(yaml: entry.yaml, workingDirectory: fixturesDirectory, environment: [:])
                let processor = try engine.nativeProcessor(configuration: config, source: entry.source, destination: entry.destination)
                let actual = try processor.processRGBA(entry.input.flatMap { $0 })
                let expected = entry.expected.flatMap { $0 }
                XCTAssertEqual(actual.count, expected.count)
                for index in actual.indices {
                    let tolerance = 0.00003 + 0.0002 * abs(expected[index])
                    XCTAssertEqual(actual[index], expected[index], accuracy: tolerance, "\(entry.name), channel \(index), OCIO \(reference.oracleVersion)")
                }
            } catch { XCTFail("\(entry.name): \(error)") }
        }
    }
    #endif
}
