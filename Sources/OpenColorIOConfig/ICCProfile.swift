// SPDX-License-Identifier: BSD-3-Clause
import Foundation

/// The matrix/TRC ICC model supported by upstream OCIO. Forward maps XYZ D65
/// into device RGB; inverse maps device RGB into XYZ D65, matching FileTransform.
public enum ICCProfile {
    public static func read(_ data: Data) throws -> [OCIONativeFileOperation] {
        let reader = ICCBytes(bytes: Array(data))
        guard reader.bytes.count >= 132, try reader.signature(36) == "acsp" else { throw invalid("missing ICC header signature") }
        let declaredSize = try reader.u32(0)
        guard declaredSize >= 132 && declaredSize <= reader.bytes.count else { throw invalid("invalid ICC declared size") }
        guard try reader.signature(16) == "RGB ", try reader.signature(20) == "XYZ " else { throw invalid("only RGB matrix/TRC profiles with XYZ PCS are supported by OCIO") }
        let count = try reader.u32(128)
        guard count > 0 && count <= 100, 132 + count * 12 <= declaredSize else { throw invalid("invalid ICC tag table") }
        var tags: [String: Range<Int>] = [:]
        for index in 0..<count {
            let record = 132 + index * 12
            let name = try reader.signature(record)
            let offset = try reader.u32(record + 4), length = try reader.u32(record + 8)
            guard length >= 8, offset >= 128, offset <= declaredSize - length else { throw invalid("tag '\(name)' exceeds profile bounds") }
            guard tags[name] == nil else { throw invalid("duplicate ICC tag '\(name)'") }
            tags[name] = offset..<(offset + length)
        }
        func tag(_ name: String) throws -> ICCBytes {
            guard let range = tags[name] else { throw invalid("missing matrix/TRC tag '\(name)'") }
            return ICCBytes(bytes: Array(reader.bytes[range]))
        }
        var matrix = [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        for (column, name) in ["rXYZ", "gXYZ", "bXYZ"].enumerated() {
            let xyz = try tag(name)
            guard try xyz.signature(0) == "XYZ ", xyz.bytes.count >= 20 else { throw invalid("invalid XYZ colorant tag") }
            for row in 0..<3 { matrix[row * 4 + column] = try xyz.fixed(8 + row * 4) }
        }
        let curveTags = try ["rTRC", "gTRC", "bTRC"].map(tag)
        let types = try curveTags.map { try $0.signature(0) }
        guard Set(types).count == 1 else { throw invalid("all ICC curves must have the same type") }
        let transfer: OCIONativeFileOperation
        if types[0] == "curv" {
            let counts = try curveTags.map { try $0.u32(8) }
            guard Set(counts).count == 1, counts[0] > 0, counts[0] <= 1_048_576 else { throw invalid("ICC curves must have equal nonzero lengths") }
            let length = counts[0]
            for curve in curveTags { guard curve.bytes.count >= 12 + length * 2 else { throw invalid("truncated ICC curve") } }
            if length == 1 {
                let gammas = try curveTags.map { Double(try $0.u16(12)) / 256 } + [1]
                transfer = .transform(try CTFFile.transform("ExponentTransform", fields: ["value": CTFFile.vector(gammas), "style": .scalar("mirror")], inverse: true))
            } else {
                var values: [Float] = []
                values.reserveCapacity(length * 3)
                for index in 0..<length { for curve in curveTags { values.append(Float(try curve.u16(12 + index * 2)) / 65535) } }
                transfer = .configuredLUT(try OCIOLUTFile.lut(dimension: 1, size: length, values: values), interpolation: "linear", inverse: true)
            }
        } else if types[0] == "para" {
            let functionTypes = try curveTags.map { try $0.u16(8) }
            guard Set(functionTypes).count == 1, functionTypes[0] <= 4 else { throw invalid("ICC parametric curves must share function type 0...4") }
            let functionType = functionTypes[0]
            let parameterCount = [1, 3, 4, 5, 7][functionType]
            let parameters: [[Float]] = try curveTags.map { curve in
                let parameters = try (0..<parameterCount).map { Float(try curve.fixed(12 + $0 * 4)) }
                try validate(parameters, type: functionType)
                return parameters
            }
            if functionType == 0 {
                let gammas = parameters.map { Double($0[0]) } + [1]
                transfer = .transform(try CTFFile.transform("ExponentTransform", fields: ["value": CTFFile.vector(gammas), "style": .scalar("mirror")], inverse: true))
            } else {
                // OCIO samples types1...4 into1024 entries. Use the same table size
                // and Float32 arithmetic to match its interpolation and inverse.
                var values: [Float] = []
                values.reserveCapacity(1024 * 3)
                for index in 0..<1024 { for p in parameters { values.append(apply(Float(index) / 1023, parameters: p, type: functionType)) } }
                transfer = .configuredLUT(try OCIOLUTFile.lut(dimension: 1, size: 1024, values: values), interpolation: "linear", inverse: true)
            }
        } else { throw invalid("unsupported ICC TRC tag type '\(types[0])'") }
        let d50ToD65 = [
            0.955509474537, -0.023074829492, 0.063312392987, 0,
            -0.028327238868, 1.00994465504, 0.021055592145, 0,
            0.012329273379, -0.020536209966, 1.33072998567, 0,
            0, 0, 0, 1
        ]
        return [
            .transform(try CTFFile.transform("MatrixTransform", fields: ["matrix": CTFFile.vector(d50ToD65)], inverse: true)),
            .transform(try CTFFile.transform("MatrixTransform", fields: ["matrix": CTFFile.vector(matrix)], inverse: true)),
            transfer
        ]
    }
    static func invalid(_ text: String) -> OCIOConfigError { .invalid("ICC: \(text)") }
    static func validate(_ p: [Float], type: Int) throws {
        guard p[0] > 0 else { throw invalid("parametric gamma must be positive") }
        if type > 0 { guard p[1] > 0 else { throw invalid("parametric scale must be positive") } }
        if type >= 3 {
            guard p[3] >= 0, p[1] * p[4] + p[2] >= 0 else { throw invalid("parametric curve must be monotonic and real") }
            let linear = p[3] * p[4] + (type == 4 ? p[6] : 0)
            let power = powf(p[1] * p[4] + p[2], p[0]) + (type == 4 ? p[5] : 0)
            guard (linear * 65536).rounded() <= (power * 65536).rounded() else { throw invalid("parametric curve has a negative discontinuity") }
        }
    }
    static func apply(_ value: Float, parameters p: [Float], type: Int) -> Float {
        let x = min(max(value, 0), 1)
        let result: Float
        switch type {
        case 1: result = x >= -p[2] / p[1] ? powf(p[1] * x + p[2], p[0]) : 0
        case 2: result = x >= -p[2] / p[1] ? powf(p[1] * x + p[2], p[0]) + p[3] : p[3]
        case 3: result = x >= p[4] ? powf(p[1] * x + p[2], p[0]) : p[3] * x
        case 4: result = x >= p[4] ? powf(p[1] * x + p[2], p[0]) + p[5] : p[3] * x + p[6]
        default: result = powf(x, p[0])
        }
        return min(max(result, 0), 1)
    }
}

private struct ICCBytes {
    let bytes: [UInt8]
    func u16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ICCProfile.invalid("truncated 16-bit field") }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
    func u32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ICCProfile.invalid("truncated 32-bit field") }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }
    func fixed(_ offset: Int) throws -> Double { Double(Int32(bitPattern: UInt32(try u32(offset)))) / 65536 }
    func signature(_ offset: Int) throws -> String {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ICCProfile.invalid("truncated signature") }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }
}
