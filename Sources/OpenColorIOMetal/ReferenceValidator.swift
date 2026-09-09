import Foundation

public struct ReferenceValidationCase: Codable, Sendable {
    public let name: String
    public let pipeline: [String]
    public let expected: String
    public let absoluteTolerance: Float
    public let relativeTolerance: Float
}

public struct ValidationFailure: Codable, Sendable {
    public let name: String
    public let scalarIndex: Int
    public let expected: String
    public let actual: String
    public let detail: String
}

public struct ValidationReport: Codable, Sendable {
    public let casesChecked: Int
    public let pipelinesExecuted: Int
    public let pixelsPerCase: Int
    public let scalarsCompared: Int
    public let failedCases: Int
    public let maxAbsoluteError: Double
    public let maxRelativeError: Double
    /// At most 100 representative failures; `failedCases` includes every failed case.
    public let failures: [ValidationFailure]
    public let deviceName: String
    public let passed: Bool
}

private struct ValidationManifest: Decodable {
    let schemaVersion: Int
    let input: [Float]
    let cases: [ReferenceValidationCase]
}

/// Compares every archived conversion with independent Float32 CPU results exported from upstream OpenColorIO.
/// Nonfinite outputs are stored in binary files and compared by NaN class / infinity sign.
public struct ReferenceValidator: Sendable {
    public let catalogue: OCIOCatalogue
    public let input: [Float]
    public let cases: [ReferenceValidationCase]

    public init(catalogue: OCIOCatalogue, validationURL: URL? = nil) throws {
        self.catalogue = catalogue
        let url = try validationURL ?? catalogue.resourceURL("validation.json")
        let manifest: ValidationManifest
        do { manifest = try JSONDecoder().decode(ValidationManifest.self, from: Data(contentsOf: url)) }
        catch { throw OCIOError.invalidArchive("validation manifest: \(error)") }
        guard manifest.schemaVersion == 1, !manifest.input.isEmpty, manifest.input.count % 4 == 0,
              !manifest.cases.isEmpty, manifest.input.allSatisfy(\.isFinite) else {
            throw OCIOError.invalidArchive("validation requires schema 1, finite nonempty RGBA inputs, and cases")
        }
        input = manifest.input
        cases = manifest.cases
        for reference in cases {
            guard reference.absoluteTolerance.isFinite, reference.relativeTolerance.isFinite,
                  reference.absoluteTolerance >= 0, reference.relativeTolerance >= 0 else {
                throw OCIOError.invalidArchive("invalid tolerances in \(reference.name)")
            }
            for id in reference.pipeline { _ = try catalogue.transform(id) }
        }
    }

    public func expectedValues(for reference: ReferenceValidationCase) throws -> [Float] {
        let data = try Data(contentsOf: catalogue.resourceURL(reference.expected), options: .mappedIfSafe)
        guard data.count == input.count * 4 else {
            throw OCIOError.invalidArchive("reference output length differs from input: \(reference.expected)")
        }
        return data.withUnsafeBytes { bytes in
            (0..<input.count).map { index in
                let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    #if canImport(Metal)
    /// Executes each distinct pipeline once, then checks all cases against their independently exported CPU outputs.
    /// A missing GPU or compilation/execution error throws; numerical mismatches return a failing report.
    public func validate(using engine: MetalColorEngine,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ValidationReport {
        guard engine.catalogue.rootURL == catalogue.rootURL else {
            throw OCIOError.invalidInput("validator and engine must use the same archive")
        }
        var computed: [[String]: [Float]] = [:]
        var expectations: [String: [Float]] = [:]
        var failedCases = 0
        var scalarCount = 0
        var maxAbsolute = 0.0
        var maxRelative = 0.0
        var failures: [ValidationFailure] = []
        for (index, reference) in cases.enumerated() {
            let actual: [Float]
            if let existing = computed[reference.pipeline] { actual = existing }
            else {
                actual = try engine.processor(transformIDs: reference.pipeline).processRGBA(input)
                computed[reference.pipeline] = actual
            }
            let expected: [Float]
            if let existing = expectations[reference.expected] { expected = existing }
            else {
                expected = try expectedValues(for: reference)
                expectations[reference.expected] = expected
            }
            var firstFailure: ValidationFailure?
            for scalar in input.indices {
                let observed = actual[scalar]
                let target = expected[scalar]
                scalarCount += 1
                let matches: Bool
                var detail: String
                if target.isNaN {
                    matches = observed.isNaN
                    detail = "expected NaN"
                } else if target.isInfinite {
                    matches = observed == target
                    detail = "infinity class/sign differs"
                } else if !observed.isFinite {
                    matches = false
                    detail = "nonfinite GPU result for finite CPU reference"
                } else {
                    let absolute = abs(Double(observed) - Double(target))
                    let relative = absolute / max(abs(Double(target)), Double.leastNormalMagnitude)
                    maxAbsolute = max(maxAbsolute, absolute)
                    if relative.isFinite { maxRelative = max(maxRelative, relative) }
                    let allowed = Double(reference.absoluteTolerance) + Double(reference.relativeTolerance) * abs(Double(target))
                    matches = absolute <= allowed
                    detail = "absolute error \(absolute) exceeds \(allowed)"
                }
                if !matches && firstFailure == nil {
                    firstFailure = ValidationFailure(name: reference.name, scalarIndex: scalar,
                        expected: String(target), actual: String(observed), detail: detail)
                }
            }
            if let firstFailure {
                failedCases += 1
                if failures.count < 100 { failures.append(firstFailure) }
            }
            progress?(index + 1, cases.count)
        }
        return ValidationReport(casesChecked: cases.count, pipelinesExecuted: computed.count,
            pixelsPerCase: input.count / 4, scalarsCompared: scalarCount, failedCases: failedCases,
            maxAbsoluteError: maxAbsolute, maxRelativeError: maxRelative, failures: failures,
            deviceName: engine.device.name, passed: failedCases == 0)
    }
    #endif
}
