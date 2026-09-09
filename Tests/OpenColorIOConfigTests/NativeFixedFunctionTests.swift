import Foundation
import XCTest
@testable import OpenColorIOMetal
#if canImport(Metal)
import Metal
#endif

final class NativeFixedFunctionTests: XCTestCase {
    private struct References: Decodable {
        let schemaVersion: Int
        let oracleVersion: String
        let supportedStyleCount: Int
        let cases: [Reference]
    }
    private struct Reference: Decodable {
        let name: String
        let style: String
        let yaml: String
        let source: String
        let destination: String
        let input: [[Float]]
        let expected: [[Float]]
        let textures: [Texture]
        let absoluteTolerance: Float
        let relativeTolerance: Float
    }
    private struct Texture: Decodable {
        let channels: Int
        let width: Int
        let height: Int
        let values: [Float]
    }

    private func references() throws -> References {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fixed-reference.json")
        return try JSONDecoder().decode(References.self, from: Data(contentsOf: path))
    }

    func testAllFixedFunctionStylesCompileAndMatchOracleTables() throws {
        let reference = try references()
        XCTAssertEqual(reference.schemaVersion, 1)
        XCTAssertEqual(reference.supportedStyleCount, 21)
        XCTAssertEqual(Set(reference.cases.map(\.style)).count, 21)
        XCTAssertGreaterThanOrEqual(reference.cases.count, 64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocio-fixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for entry in reference.cases {
            let configuration = try OCIOConfigDocument(yaml: entry.yaml, environment: [:])
            let shader = try configuration.metalShader(from: entry.source, to: entry.destination)
            XCTAssertTrue(shader.source.contains("kernel void ocio_kernel"), entry.name)
            // The output transform shares its reach table upstream; native composition retains two copies.
            // Compare every native table with its upstream channel layout before involving a GPU.
            for texture in shader.textures {
                let channels = texture.channels == 4 ? 3 : texture.channels
                let expected = try XCTUnwrap(entry.textures.first(where: {
                    $0.channels == channels && $0.width == texture.width && $0.height == texture.height
                }), "missing oracle table for \(entry.name)")
                var maximumRatio: Float = 0
                var worstIndex = 0
                for texel in 0..<(texture.width * texture.height * texture.depth) {
                    for channel in 0..<channels {
                        let actual = texture.values[texel * texture.channels + channel]
                        let wanted = expected.values[texel * channels + channel]
                        let ratio = abs(actual - wanted) / (0.001 + abs(wanted) * 0.0001)
                        if !ratio.isFinite || ratio > maximumRatio {
                            maximumRatio = ratio
                            worstIndex = texel * channels + channel
                        }
                    }
                }
                XCTAssertLessThanOrEqual(maximumRatio, 1,
                    "\(entry.name) LUT scalar \(worstIndex), OCIO \(reference.oracleVersion), error/tolerance \(maximumRatio)")
            }
            #if os(macOS)
            let source = directory.appendingPathComponent(entry.name + ".metal")
            let output = directory.appendingPathComponent(entry.name + ".air")
            try shader.source.write(to: source, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["-sdk", "macosx", "metal", "-std=macos-metal2.0", "-fno-fast-math", "-c", source.path, "-o", output.path]
            let log = Pipe()
            process.standardOutput = log
            process.standardError = log
            try process.run()
            let messages = log.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(entry.name): \(String(decoding: messages, as: UTF8.self))")
            #endif
        }
    }

    func testInvalidFixedFunctionParametersAreRejected() throws {
        let invalid = [
            "{style: REC2100_Surround, params: [0]}",
            "{style: ACES_GamutComp13, params: [1, 1.2, 1.3, 0.8, 0.8, 0.8, 1.2]}",
            "{style: ACES2_TonescaleCompress, params: [100.5]}",
            "{style: ACES2_OutputTransform, params: [0, 0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329]}",
            "{style: RGB_TO_HSV, params: [1]}",
            "{style: nonexistent}"
        ]
        for transform in invalid {
            let configuration = try OCIOConfigDocument(yaml: """
            ocio_profile_version: 2.5
            colorspaces:
              - !<ColorSpace> {name: Linear}
              - !<ColorSpace> {name: Input, to_scene_reference: !<FixedFunctionTransform> \(transform)}
            """)
            XCTAssertThrowsError(try configuration.metalShader(from: "Input", to: "Linear"), transform)
        }
    }

    #if canImport(Metal)
    func testFixedFunctionsMatchCPUOracleOnMetal() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal hardware is unavailable; fixed-function numerical parity remains unverified")
        }
        let engine = try MetalColorEngine(device: device)
        let reference = try references()
        for entry in reference.cases {
            let configuration = try OCIOConfigDocument(yaml: entry.yaml, environment: [:])
            let processor = try engine.nativeProcessor(configuration: configuration, source: entry.source, destination: entry.destination)
            let actual = try processor.processRGBA(entry.input.flatMap { $0 })
            let expected = entry.expected.flatMap { $0 }
            XCTAssertEqual(actual.count, expected.count, entry.name)
            for scalar in expected.indices {
                XCTAssertEqual(actual[scalar], expected[scalar],
                    accuracy: entry.absoluteTolerance + entry.relativeTolerance * abs(expected[scalar]),
                    "\(entry.name) channel \(scalar), OCIO \(reference.oracleVersion)")
            }
        }
    }
    #endif
}
