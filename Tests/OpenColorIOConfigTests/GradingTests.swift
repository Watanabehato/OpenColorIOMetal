import Foundation
import XCTest
@testable import OpenColorIOMetal
#if canImport(Metal)
import Metal
#endif

final class GradingTests: XCTestCase {
    struct Reference: Decodable { let schemaVersion: Int; let oracleVersion: String; let cases: [Case] }
    struct Uniform: Decodable { let kind: String; let values: [Double] }
    struct Case: Decodable {
        let name: String
        let type: String
        let inverse: Bool
        let parameters: String
        let uniforms: [String: Uniform]
        let yaml: String
        let input: [Float]
        let expected: [String]
    }
    private func references() throws -> Reference {
        let fallback = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/grading-reference.json")
        let url = ProcessInfo.processInfo.environment["OCIO_GRADING_REFERENCE_JSON"].map { URL(fileURLWithPath: $0) } ?? fallback
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testArbitraryGradingControlsMatchUpstreamPreparedUniforms() throws {
        let reference = try references()
        XCTAssertEqual(reference.schemaVersion, 1)
        XCTAssertEqual(reference.cases.count, 144)
        for entry in reference.cases {
            let yaml = try YAMLParser().parse(entry.parameters)
            let parameters = NativeParameters(try XCTUnwrap(yaml.object), owner: entry.type)
            let prepared = try gradingPreparedParameters(parameters, type: entry.type, inverse: entry.inverse)
            for (name, expected) in entry.uniforms {
                let actual = try XCTUnwrap(prepared[name], "\(entry.name).\(name)")
                let numbers: [Double]
                switch actual {
                case let .boolean(value): numbers = [value ? 1 : 0]; XCTAssertEqual(expected.kind, "boolean")
                case let .scalar(value): numbers = [value]; XCTAssertEqual(expected.kind, "scalar")
                case let .vector(value): numbers = value; XCTAssertEqual(expected.kind, "vector")
                }
                XCTAssertEqual(numbers.count, expected.values.count, "\(entry.name).\(name)")
                for (index, pair) in zip(numbers, expected.values).enumerated() {
                    XCTAssertEqual(pair.0, pair.1, accuracy: 0.000001 + 0.00001 * abs(pair.1),
                                   "\(entry.name).\(name)[\(index)], OCIO \(reference.oracleVersion)")
                }
            }
        }
    }

    func testAllGradingCasesEmitAnalyticalMetal() throws {
        let directory = ProcessInfo.processInfo.environment["OCIO_GRADING_SHADER_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for (index, entry) in try references().cases.enumerated() {
            let config = try OCIOConfigDocument(yaml: entry.yaml, environment: [:])
            let shader = try config.metalShader(from: "Input", to: "Linear")
            XCTAssertTrue(shader.textures.isEmpty, "\(entry.name) must remain analytical")
            XCTAssertTrue(shader.source.contains("kernel void ocio_kernel"))
            if let directory { try shader.source.write(to: directory.appendingPathComponent("grading-\(index).metal"), atomically: true, encoding: .utf8) }
        }
    }

    func testIdentityAndInvalidGradingControls() throws {
        for type in ["GradingPrimaryTransform", "GradingToneTransform", "GradingRGBCurveTransform", "GradingHueCurveTransform"] {
            for style in ["log", "linear", "video"] {
                let p = NativeParameters(["style": .scalar(style)], owner: type)
                XCTAssertEqual(try gradingPreparedParameters(p, type: type, inverse: false)["localBypass"], .boolean(true))
            }
        }
        let badContrast = NativeParameters(["contrast": .mapping(["rgb": .sequence([.scalar("-1"),.scalar("1"),.scalar("1")])])], owner: "primary")
        XCTAssertThrowsError(try gradingPreparedParameters(badContrast, type: "GradingPrimaryTransform", inverse: false))
        let badCurve = NativeParameters(["red": .mapping(["control_points": .sequence([.scalar("1"),.scalar("0"),.scalar("0"),.scalar("1")])])], owner: "curve")
        XCTAssertThrowsError(try gradingPreparedParameters(badCurve, type: "GradingRGBCurveTransform", inverse: false))
    }

    func testGradingCTFControlsAndInverseStyle() throws {
        let xml = """
        <ProcessList version="2.5" id="native-grading">
          <GradingPrimary inBitDepth="32f" outBitDepth="32f" style="linearRev">
            <Exposure rgb="0.1 0.2 0.3" master="0.5"/>
            <Pivot contrast="0.18"/>
            <DynamicParameter param="GRADING_PRIMARY"/>
          </GradingPrimary>
          <GradingHueCurve inBitDepth="32f" outBitDepth="32f" style="log">
            <HueSat><ControlPoints>0, 1.2, 0.3, 0.8, 0.7, 1.3</ControlPoints></HueSat>
          </GradingHueCurve>
        </ProcessList>
        """
        let operations = try CTFFile.read(xml, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertEqual(operations.count, 2)
        guard case let .transform(primary) = operations[0], case let .transform(hue) = operations[1] else { return XCTFail("grading XML must produce transforms") }
        XCTAssertEqual(primary.parameters["style"]?.string, "lin")
        XCTAssertEqual(primary.direction, .inverse)
        XCTAssertEqual(hue.parameters["hue_sat"]?["control_points"]?.array?.count, 6)
    }

    #if canImport(Metal)
    func testGradingMetalNumericsMatchAllCPUReferences() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable: grading numerical equivalence not verified")
        }
        for entry in try references().cases {
            let config = try OCIOConfigDocument(yaml: entry.yaml, environment: [:])
            let shader = try config.metalShader(from: "Input", to: "Linear")
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try device.makeLibrary(source: shader.source, options: options)
            let function = try XCTUnwrap(library.makeFunction(name: shader.kernel))
            let pipeline = try device.makeComputePipelineState(function: function)
            let input = entry.input
            let byteCount = input.count * MemoryLayout<Float>.stride
            let source = try XCTUnwrap(input.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: byteCount, options: .storageModeShared) })
            let destination = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            var count = UInt32(input.count / 4)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(64,pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error, entry.name)
            let actual = destination.contents().bindMemory(to: Float.self, capacity: input.count)
            for index in input.indices {
                let expected = try XCTUnwrap(Float(entry.expected[index]))
                if expected.isNaN { XCTAssertTrue(actual[index].isNaN, "\(entry.name)[\(index)]") }
                else if expected.isInfinite { XCTAssertEqual(actual[index], expected, "\(entry.name)[\(index)]") }
                else { XCTAssertEqual(actual[index], expected, accuracy: 0.00005 + 0.0003 * abs(expected), "\(entry.name)[\(index)]") }
            }
        }
    }
    #endif
}
