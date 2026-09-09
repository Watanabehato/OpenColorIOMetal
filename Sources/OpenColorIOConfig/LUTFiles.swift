// SPDX-License-Identifier: BSD-3-Clause
import Foundation

public struct OCIONativeLUT: Sendable {
    public let dimension: Int
    public let size: Int
    /// RGB triples; red is the fastest varying axis for 3D Metal upload.
    public let values: [Float]
    public let domainMinimum: [Double]
    public let domainMaximum: [Double]
}

public enum OCIONativeFileOperation: Sendable {
    case lut(OCIONativeLUT)
    case configuredLUT(OCIONativeLUT, interpolation: String, inverse: Bool)
    case transform(OCIOConfigTransform)
}

public enum OCIOLUTFile {
    public static func read(_ url: URL, cccID: String? = nil) throws -> [OCIONativeFileOperation] {
        if ["icc", "icm", "pf"].contains(url.pathExtension.lowercased()) { return try ICCProfile.read(Data(contentsOf: url)) }
        let source = try String(contentsOf: url, encoding: .utf8)
        switch url.pathExtension.lowercased() {
        case "cube": return try cube(source)
        case "spi1d": return [.lut(try spi1d(source))]
        case "spi3d": return [.lut(try spi3d(source))]
        case "spimtx": return [.transform(try spimtx(source))]
        case "cc", "ccc", "cdl": return try CDLXMLFile.read(source, cccID: cccID)
        case "ctf", "clf": return try CTFFile.read(source, relativeTo: url.deletingLastPathComponent())
        default: return try readLegacy(source, extension: url.pathExtension, filename: url.lastPathComponent)
        }
    }
    static func rows(_ source: String) -> [[String]] {
        source.components(separatedBy: .newlines).compactMap { line in
            let text = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let row = text.split(whereSeparator: \.isWhitespace).map(String.init)
            return row.isEmpty ? nil : row
        }
    }
    static func numbers(_ row: [String], count: Int? = nil) throws -> [Double] {
        if let count, row.count != count { throw OCIOConfigError.invalid("LUT row requires \(count) values, found \(row.count)") }
        return try row.map {
            guard let value = Double($0), value.isFinite, Float(value).isFinite else { throw OCIOConfigError.invalid("invalid LUT float '\($0)'") }
            return value
        }
    }
    static func size(_ text: String?, maximum: Int) throws -> Int {
        guard let text, let value = Int(text), value >= 2 && value <= maximum else { throw OCIOConfigError.invalid("LUT size must be 2...\(maximum)") }
        return value
    }
    static func lut(dimension: Int, size: Int, values: [Float], minimum: [Double] = [0, 0, 0], maximum: [Double] = [1, 1, 1]) throws -> OCIONativeLUT {
        let count = dimension == 1 ? size : size * size * size
        guard values.count == count * 3, zip(minimum, maximum).allSatisfy({ $1 > $0 }) else { throw OCIOConfigError.invalid("LUT value count or input domain is invalid") }
        return OCIONativeLUT(dimension: dimension, size: size, values: values, domainMinimum: minimum, domainMaximum: maximum)
    }
    public static func cube(_ source: String) throws -> [OCIONativeFileOperation] {
        var size1D: Int?, size3D: Int?
        var minimum = [0.0, 0, 0], maximum = [1.0, 1, 1]
        var range1D: [Double]?, range3D: [Double]?
        var values: [Float] = []
        for row in rows(source) {
            switch row[0].uppercased() {
            case "TITLE": continue
            case "LUT_1D_SIZE":
                guard size1D == nil, row.count == 2 else { throw OCIOConfigError.invalid("duplicate or invalid LUT_1D_SIZE") }
                size1D = try size(row.last, maximum: 1_048_576)
            case "LUT_3D_SIZE":
                guard size3D == nil, row.count == 2 else { throw OCIOConfigError.invalid("duplicate or invalid LUT_3D_SIZE") }
                size3D = try size(row.last, maximum: 129)
            case "DOMAIN_MIN": minimum = try numbers(Array(row.dropFirst()), count: 3)
            case "DOMAIN_MAX": maximum = try numbers(Array(row.dropFirst()), count: 3)
            case "LUT_1D_INPUT_RANGE": range1D = try numbers(Array(row.dropFirst()), count: 2)
            case "LUT_3D_INPUT_RANGE": range3D = try numbers(Array(row.dropFirst()), count: 2)
            default: values += try numbers(row, count: 3).map(Float.init)
            }
        }
        guard size1D != nil || size3D != nil else { throw OCIOConfigError.invalid("cube contains no LUT size") }
        var operations: [OCIONativeFileOperation] = []
        var consumed = 0
        if let size1D {
            let count = size1D * 3
            guard values.count >= count else { throw OCIOConfigError.invalid("truncated 1D cube") }
            let lower = range1D.map { Array(repeating: $0[0], count: 3) } ?? minimum
            let upper = range1D.map { Array(repeating: $0[1], count: 3) } ?? maximum
            operations.append(.lut(try lut(dimension: 1, size: size1D, values: Array(values[..<count]), minimum: lower, maximum: upper)))
            consumed = count
        }
        if let size3D {
            let lower: [Double] = range3D.map { Array(repeating: $0[0], count: 3) } ?? (size1D == nil ? minimum : [0.0, 0.0, 0.0])
            let upper: [Double] = range3D.map { Array(repeating: $0[1], count: 3) } ?? (size1D == nil ? maximum : [1.0, 1.0, 1.0])
            operations.append(.lut(try lut(dimension: 3, size: size3D, values: Array(values[consumed...]), minimum: lower, maximum: upper)))
        } else if consumed != values.count { throw OCIOConfigError.invalid("extra cube entries") }
        return operations
    }
    public static func spi1d(_ source: String) throws -> OCIONativeLUT {
        var length: Int?, components: Int?, version: Int?
        var minimum = 0.0, maximum = 1.0
        var reading = false, finished = false
        var values: [Float] = []
        for row in rows(source) {
            if row[0] == "{" { guard !reading else { throw OCIOConfigError.invalid("nested spi1d data") }; reading = true; continue }
            if row[0] == "}" { finished = true; reading = false; continue }
            if finished { throw OCIOConfigError.invalid("text after spi1d data") }
            if reading {
                guard let components, (1...3).contains(components) else { throw OCIOConfigError.invalid("spi1d components must be declared before data") }
                let entry = try numbers(row, count: components).map(Float.init)
                values += components == 1 ? [entry[0], entry[0], entry[0]] : (components == 2 ? [entry[0], entry[1], 0] : entry)
                continue
            }
            switch row[0].lowercased() {
            case "version": version = row.count == 2 ? Int(row[1]) : nil
            case "length": length = try size(row.last, maximum: 1_048_576)
            case "components": components = row.count == 2 ? Int(row[1]) : nil
            case "from": let range = try numbers(Array(row.dropFirst()), count: 2); minimum = range[0]; maximum = range[1]
            default: throw OCIOConfigError.invalid("unknown spi1d header '\(row[0])'")
            }
        }
        guard version == 1, let length, finished else { throw OCIOConfigError.invalid("invalid spi1d header or missing closing brace") }
        return try lut(dimension: 1, size: length, values: values, minimum: Array(repeating: minimum, count: 3), maximum: Array(repeating: maximum, count: 3))
    }
    public static func spi3d(_ source: String) throws -> OCIONativeLUT {
        let rows = rows(source)
        guard rows.count >= 3, rows[0].first?.uppercased() == "SPILUT", rows[1] == ["3", "3"], rows[2].count == 3 else { throw OCIOConfigError.invalid("invalid spi3d header") }
        let length = try size(rows[2][0], maximum: 129)
        guard rows[2].allSatisfy({ Int($0) == length }) else { throw OCIOConfigError.invalid("spi3d must be a uniform cube") }
        var values = Array(repeating: Float(0), count: length * length * length * 3)
        var written = Set<Int>()
        for row in rows.dropFirst(3) {
            guard row.count == 6, let r = Int(row[0]), let g = Int(row[1]), let b = Int(row[2]), [r, g, b].allSatisfy({ (0..<length).contains($0) }) else { throw OCIOConfigError.invalid("invalid spi3d index") }
            let index = (r + length * (g + length * b)) * 3
            guard written.insert(index).inserted else { throw OCIOConfigError.invalid("duplicate spi3d index") }
            let entry = try numbers(Array(row.suffix(3)), count: 3).map(Float.init)
            values.replaceSubrange(index..<(index + 3), with: entry)
        }
        guard written.count == length * length * length else { throw OCIOConfigError.invalid("missing spi3d entries") }
        return try lut(dimension: 3, size: length, values: values)
    }
    public static func spimtx(_ source: String) throws -> OCIOConfigTransform {
        let values = try numbers(rows(source).flatMap { $0 }, count: 12)
        let matrix = [values[0], values[1], values[2], 0, values[4], values[5], values[6], 0, values[8], values[9], values[10], 0, 0, 0, 0, 1]
        let offset = [values[3] / 65535, values[7] / 65535, values[11] / 65535, 0]
        return try OCIOConfigTransform(yaml: .tagged("MatrixTransform", .mapping([
            "matrix": .sequence(matrix.map { .scalar(String($0)) }),
            "offset": .sequence(offset.map { .scalar(String($0)) })
        ])))
    }
}

extension OCIONativeCompiler {
    mutating func appendFile(_ p: NativeParameters, inverse: Bool, depth: Int) throws {
        let file = try config.context.resolveFile(p.string("src"))
        let operations = try OCIOLUTFile.read(file, cccID: p.values["cccid"]?.string)
        for operation in inverse ? Array(operations.reversed()) : operations {
            switch operation {
            case let .transform(transform): try append(OCIOConfigTransformStep(transform: transform, inverse: inverse, label: file.lastPathComponent), depth: depth + 1)
            case let .lut(lut): try appendLUT(lut, interpolation: p.string("interpolation", defaultValue: "default"), inverse: inverse)
            case let .configuredLUT(lut, interpolation, reversed):
                let selected = try p.string("interpolation", defaultValue: interpolation)
                try appendLUT(lut, interpolation: selected == "default" ? interpolation : selected, inverse: reversed != inverse)
            }
        }
    }
    mutating func appendLUT(_ lut: OCIONativeLUT, interpolation: String, inverse: Bool) throws {
        let interpolation = interpolation.lowercased()
        guard ["default", "best", "linear", "nearest", "tetrahedral"].contains(interpolation) else { throw OCIOConfigError.invalid("unknown LUT interpolation '\(interpolation)'") }
        if inverse && lut.dimension == 3 { throw OCIOConfigError.unavailableTransform("native inverse 3D LUT solving is not yet implemented") }
        let id = textures.count
        // Metal 1D textures are limited to 16384 texels on supported Macs. Packing
        // into rows supports OCIO's larger 1D/half-domain tables without resampling.
        let width = lut.dimension == 1 ? min(lut.size, 4096) : lut.size
        let height = lut.dimension == 1 ? (lut.size + width - 1) / width : lut.size
        var textureValues = lut.values
        if lut.dimension == 1 { textureValues += Array(repeating: 0, count: width * height * 3 - textureValues.count) }
        textures.append(OCIONativeTexture(index: id, dimension: lut.dimension == 1 ? 2 : 3, width: width, height: height, depth: lut.dimension == 3 ? lut.size : 1, channels: 3, values: textureValues))
        let texture = "lut\(id)", size = Double(lut.size), last = Double(lut.size - 1)
        func read(_ index: String) -> String { "\(texture).read(uint2((\(index)) % \(width)u, (\(index)) / \(width)u))" }
        let ranges = zip(lut.domainMinimum, lut.domainMaximum).map { $1 - $0 }
        var code = "{\n"
        if !inverse { code += "float3 normalized = (pixel.rgb - \(mslVector(lut.domainMinimum))) / \(mslVector(ranges));\n" }
        if lut.dimension == 1 {
            for (channel, component) in ["r", "g", "b"].enumerated() {
                if inverse {
                    let channelValues = stride(from: channel, to: lut.values.count, by: 3).map { lut.values[$0] }
                    let increasing = channelValues.last! > channelValues.first!
                    guard zip(channelValues, channelValues.dropFirst()).allSatisfy({ increasing ? $1 >= $0 : $1 <= $0 }), channelValues.first != channelValues.last else { throw OCIOConfigError.unavailableTransform("inverse 1D LUT requires a monotonic, nonconstant channel") }
                    code += """
                    {
                        float target = pixel.\(component);
                        uint low = 0u, high = \(lut.size - 1)u;
                        while (high - low > 1u) {
                            uint mid = (low + high) / 2u;
                            if (\(read("mid")).\(component) \(increasing ? "<" : ">") target) low = mid; else high = mid;
                        }
                        float a = \(read("low")).\(component), b = \(read("high")).\(component);
                        float fraction = a == b ? 0.0f : clamp((target - a) / (b - a), 0.0f, 1.0f);
                        pixel.\(component) = ((float(low) + fraction) / \(mslNumber(last))) * \(mslNumber(ranges[channel])) + \(mslNumber(lut.domainMinimum[channel]));
                    }
                    """
                } else {
                    code += "{ float position = clamp(normalized.\(component), 0.0f, 1.0f) * \(mslNumber(last));\n"
                    if interpolation == "nearest" {
                        code += "uint nearest = uint(floor(position + 0.5f)); pixel.\(component) = \(read("nearest")).\(component); }\n"
                    } else {
                        code += "uint low = uint(floor(position)); uint high = min(low + 1u, \(lut.size - 1)u);\n"
                        code += "pixel.\(component) = mix(\(read("low")).\(component), \(read("high")).\(component), position - float(low)); }\n"
                    }
                }
            }
        } else if interpolation == "tetrahedral" || interpolation == "best" {
            code += """
            float3 position = clamp(normalized, 0.0f, 1.0f) * \(mslNumber(last));
            uint3 lower = uint3(floor(position));
            uint3 upper = min(lower + 1u, uint3(\(lut.size - 1)u));
            float3 fraction = position - float3(lower);
            float3 c000 = \(texture).read(lower).rgb;
            float3 c111 = \(texture).read(upper).rgb;
            float3 a, b; float x, y, z;
            if (fraction.r >= fraction.g) {
                if (fraction.g >= fraction.b) {
                    a = \(texture).read(uint3(upper.r, lower.g, lower.b)).rgb;
                    b = \(texture).read(uint3(upper.r, upper.g, lower.b)).rgb;
                    x = fraction.r; y = fraction.g; z = fraction.b;
                } else if (fraction.r >= fraction.b) {
                    a = \(texture).read(uint3(upper.r, lower.g, lower.b)).rgb;
                    b = \(texture).read(uint3(upper.r, lower.g, upper.b)).rgb;
                    x = fraction.r; y = fraction.b; z = fraction.g;
                } else {
                    a = \(texture).read(uint3(lower.r, lower.g, upper.b)).rgb;
                    b = \(texture).read(uint3(upper.r, lower.g, upper.b)).rgb;
                    x = fraction.b; y = fraction.r; z = fraction.g;
                }
            } else {
                if (fraction.b >= fraction.g) {
                    a = \(texture).read(uint3(lower.r, lower.g, upper.b)).rgb;
                    b = \(texture).read(uint3(lower.r, upper.g, upper.b)).rgb;
                    x = fraction.b; y = fraction.g; z = fraction.r;
                } else if (fraction.b >= fraction.r) {
                    a = \(texture).read(uint3(lower.r, upper.g, lower.b)).rgb;
                    b = \(texture).read(uint3(lower.r, upper.g, upper.b)).rgb;
                    x = fraction.g; y = fraction.b; z = fraction.r;
                } else {
                    a = \(texture).read(uint3(lower.r, upper.g, lower.b)).rgb;
                    b = \(texture).read(uint3(upper.r, upper.g, lower.b)).rgb;
                    x = fraction.g; y = fraction.r; z = fraction.b;
                }
            }
            pixel.rgb = c000 + x * (a - c000) + y * (b - a) + z * (c111 - b);
            """
        } else {
            let filtering = interpolation == "nearest" ? "nearest" : "linear"
            code += "constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::\(filtering));\npixel.rgb = \(texture).sample(sampling, (normalized * \(mslNumber(last)) + 0.5f) / \(mslNumber(size))).rgb;\n"
        }
        body.append(code + "\n}")
    }
}
