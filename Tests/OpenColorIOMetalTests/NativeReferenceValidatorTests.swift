import Foundation
import XCTest
@testable import OpenColorIOMetal

final class NativeReferenceValidatorTests: XCTestCase {
    func testDefaultSuiteCannotOmitOrMislabelArchiveOperations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocio-coverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairs: [[String: Any]] = ["A", "B"].flatMap { source in
            ["A", "B"].map { destination in
                ["source": source, "destination": destination, "pipeline": [String]()] as [String: Any]
            }
        }
        let spaces: [[String: Any]] = ["A", "B"].map {
            ["name": $0, "aliases": [String](), "family": "", "description": "", "isData": false,
             "isActive": true, "referenceSpace": "scene", "equalityGroup": ""]
        }
        let configuration: [String: Any] = [
            "id": "test", "name": "test", "description": "", "isRecommended": true,
            "roleAliases": [String: String](), "colorSpaces": spaces, "conversions": pairs,
            "displayViews": [[String: Any]](), "namedTransforms": [[String: Any]](), "looks": [[String: Any]]()
        ]
        let manifest: [String: Any] = [
            "schemaVersion": 1, "upstream": ["repository": "test", "commit": "test", "version": "test"],
            "defaultConfiguration": "test", "configurations": [configuration], "builtins": [[String: Any]](),
            "transforms": [["id": "other", "shader": "other.metal", "kernel": "other", "textures": [[String: Any]]()]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        let catalogue = try OCIOCatalogue(contentsOf: directory)
        let references: [[String: Any]] = pairs.map {
            ["name": "pair|test|\($0["source"]!)|\($0["destination"]!)", "pipeline": [String](),
             "expected": "values.f32", "absoluteTolerance": 0.0001, "relativeTolerance": 0.0001]
        }
        let validationURL = directory.appendingPathComponent("validation.json")
        func write(_ cases: [[String: Any]]) throws {
            let value: [String: Any] = ["schemaVersion": 1, "input": [0, 0, 0, 1], "cases": cases]
            try JSONSerialization.data(withJSONObject: value).write(to: validationURL)
        }
        try write(references)
        XCTAssertNoThrow(try ReferenceValidator(catalogue: catalogue))

        try write(Array(references.dropLast()))
        XCTAssertThrowsError(try ReferenceValidator(catalogue: catalogue), "Missing direct reference must not count as full validation")
        XCTAssertNoThrow(try ReferenceValidator(catalogue: catalogue, validationURL: validationURL),
                         "An explicitly selected regression subset remains supported")

        var duplicate = references
        duplicate[3] = duplicate[0]
        try write(duplicate)
        XCTAssertThrowsError(try ReferenceValidator(catalogue: catalogue))
        XCTAssertThrowsError(try ReferenceValidator(catalogue: catalogue, validationURL: validationURL))

        var mislabeled = references
        mislabeled[0]["name"] = "pair|test|A|C"
        try write(mislabeled)
        XCTAssertThrowsError(try ReferenceValidator(catalogue: catalogue))

        var wrongPipeline = references
        wrongPipeline[0]["pipeline"] = ["other"]
        try write(wrongPipeline)
        XCTAssertThrowsError(try ReferenceValidator(catalogue: catalogue), "Reference must evaluate the archive's actual operation")
    }
}
