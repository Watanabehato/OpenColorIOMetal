// SPDX-License-Identifier: BSD-3-Clause
// Format semantics and cineSpace interpolation follow OpenColorIO's fileformat readers.
import Foundation

extension OCIOLUTFile {
    static func readLegacy(_ source: String, extension ext: String, filename: String) throws -> [OCIONativeFileOperation] {
        switch ext.lowercased() {
        case "itx": return try cube(source)
        case "3dl": return try threeDL(source)
        case "mga", "m3d": return try pandora(source)
        case "cub": return try truelight(source)
        case "vf": return try nukeVF(source)
        case "csp": return try cineSpace(source)
        case "look": return try iridasLook(source)
        case "lut":
            if rows(source).first?.first?.lowercased() == "version" { return try houdini(source) }
            return try discreet(source, filename: filename)
        default: throw OCIOConfigError.unavailableTransform("native file format '.\(ext)' is not implemented")
        }
    }

    static func cubeEdge(_ count: Int) throws -> Int {
        guard count >= 8, count <= 129 * 129 * 129 else { throw OCIOConfigError.invalid("3D LUT entry count is outside the supported range") }
        let edge = Int(Double(count).cubeRoot().rounded())
        guard edge >= 2, edge <= 129, edge * edge * edge == count else {
            throw OCIOConfigError.invalid("3D LUT entry count must form a cube with edge 2...129")
        }
        return edge
    }
    static func redFast(_ blueFast: [Float], edge: Int) -> [Float] {
        var result = blueFast
        for r in 0..<edge { for g in 0..<edge { for b in 0..<edge {
            let from = 3 * (b + edge * (g + edge * r))
            let to = 3 * (r + edge * (g + edge * b))
            for channel in 0..<3 { result[to + channel] = blueFast[from + channel] }
        } } }
        return result
    }
    static func integerScale(_ maximum: Int) throws -> Float {
        guard maximum >= 128 else { throw OCIOConfigError.invalid("3dl maximum is implausibly small for integer code values") }
        for bits in [8, 10, 12, 14, 16] where maximum <= (1 << (bits + 1)) - 1 {
            return Float((1 << (bits == 14 ? 16 : bits)) - 1)
        }
        return 65535
    }
    public static func threeDL(_ source: String) throws -> [OCIONativeFileOperation] {
        var shaper: [Int] = [], data: [Int] = []
        for row in rows(source) {
            guard row[0].first != "<" else { throw OCIOConfigError.invalid("XML is not a 3dl file") }
            let ints = row.compactMap(Int.init)
            if ints.count != row.count { continue } // Upstream accepts undocumented textual headers.
            if ints.count > 3 {
                guard shaper.isEmpty else { throw OCIOConfigError.invalid("duplicate 3dl shaper") }
                shaper = ints
            } else if ints.count == 3 { data += ints }
            else { throw OCIOConfigError.invalid("3dl numeric row needs at least three values") }
        }
        guard !shaper.isEmpty || !data.isEmpty else { throw OCIOConfigError.invalid("empty 3dl file") }
        var operations: [OCIONativeFileOperation] = []
        if !shaper.isEmpty {
            let scale = try integerScale(shaper.max()!)
            let step = scale / Float(shaper.count - 1)
            let identity = shaper.enumerated().allSatisfy { abs(Float($0.offset) * step - Float($0.element)) < 2 }
            if !identity {
                let values = shaper.flatMap { value in Array(repeating: Float(value) / scale, count: 3) }
                operations.append(.lut(try lut(dimension: 1, size: shaper.count, values: values)))
            }
        }
        if !data.isEmpty {
            let edge = try cubeEdge(data.count / 3), scale = try integerScale(data.max()!)
            operations.append(.lut(try lut(dimension: 3, size: edge, values: redFast(data.map { Float($0) / scale }, edge: edge))))
        }
        return operations
    }
    public static func pandora(_ source: String) throws -> [OCIONativeFileOperation] {
        var edge: Int?, scale: Float?, reading = false, data: [Float] = []
        for row in rows(source) {
            switch row[0].lowercased() {
            case "channel": guard row.map({ $0.lowercased() }) == ["channel", "3d"] else { throw OCIOConfigError.invalid("Pandora requires channel 3d") }
            case "format": guard row.map({ $0.lowercased() }) == ["format", "lut"] else { throw OCIOConfigError.invalid("Pandora requires format lut") }
            case "in":
                guard row.count == 2, let count = Int(row[1]) else { throw OCIOConfigError.invalid("invalid Pandora in tag") }
                edge = try cubeEdge(count)
            case "out":
                guard row.count == 2, let count = Int(row[1]), count > 1 else { throw OCIOConfigError.invalid("invalid Pandora out tag") }
                scale = 1 / Float(count - 1)
            case "values":
                guard row.map({ $0.lowercased() }) == ["values", "red", "green", "blue"] else { throw OCIOConfigError.invalid("Pandora values must be red green blue") }
                reading = true
            default:
                if reading { data += try numbers(Array(row.dropFirst()), count: 3).map(Float.init) }
            }
        }
        guard let edge, let scale, data.count == edge * edge * edge * 3 else { throw OCIOConfigError.invalid("Pandora header or entry count invalid") }
        return [.lut(try lut(dimension: 3, size: edge, values: redFast(data.map { $0 * scale }, edge: edge)))]
    }
    public static func truelight(_ source: String) throws -> [OCIONativeFileOperation] {
        let lines = source.components(separatedBy: .newlines)
        guard lines.first?.lowercased().hasPrefix("# truelight cube") == true else { throw OCIOConfigError.invalid("missing Truelight cube header") }
        var size1D: Int?, size3D: Int?, mode = 0
        var one: [Float] = [], three: [Float] = []
        for line in lines.dropFirst() {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.isEmpty { continue }
            if parts[0].hasPrefix("#") {
                guard parts.count > 1 else { continue }
                switch parts[1].lowercased() {
                case "width":
                    guard parts.count == 5, parts[2] == parts[3], parts[2] == parts[4] else { throw OCIOConfigError.invalid("Truelight width must be a uniform cube") }
                    size3D = try size(parts[2], maximum: 129)
                case "lutlength": size1D = try size(parts.last, maximum: 1_048_576)
                case "inputlut": mode = 1
                case "cube": mode = 3
                case "end": mode = 0
                default: break
                }
            } else if mode == 1 { one += try numbers(parts, count: 3).map(Float.init) }
            else if mode == 3 { three += try numbers(parts, count: 3).map(Float.init) }
        }
        var operations: [OCIONativeFileOperation] = []
        if let size1D {
            let descale = size3D.map { 1 / Float($0 - 1) } ?? 1
            operations.append(.lut(try lut(dimension: 1, size: size1D, values: one.map { $0 * descale })))
        } else if !one.isEmpty { throw OCIOConfigError.invalid("Truelight input LUT has no size") }
        if let size3D { operations.append(.lut(try lut(dimension: 3, size: size3D, values: three))) }
        else if !three.isEmpty { throw OCIOConfigError.invalid("Truelight cube has no size") }
        guard !operations.isEmpty else { throw OCIOConfigError.invalid("empty Truelight LUT") }
        return operations
    }
    public static func nukeVF(_ source: String) throws -> [OCIONativeFileOperation] {
        guard source.lowercased().hasPrefix("#inventor") else { throw OCIOConfigError.invalid("missing Inventor header") }
        var edge: Int?, matrix: [Double]?, reading = false, data: [Float] = []
        for row in rows(source) {
            if reading {
                if row.count == 3, row.allSatisfy({ Double($0) != nil }) { data += try numbers(row, count: 3).map(Float.init) }
            } else {
                switch row[0].lowercased() {
                case "grid_size":
                    guard row.count == 4, row[1] == row[2], row[1] == row[3] else { throw OCIOConfigError.invalid("VF grid must be uniform") }
                    edge = try size(row[1], maximum: 129)
                case "global_transform": matrix = try numbers(Array(row.dropFirst()), count: 16)
                case "data": reading = true
                default: break
                }
            }
        }
        guard let edge, data.count == edge * edge * edge * 3 else { throw OCIOConfigError.invalid("VF entry count differs from grid") }
        var operations: [OCIONativeFileOperation] = []
        if var matrix {
            for row in 0..<4 { for column in 0..<3 { matrix[row * 4 + column] *= Double(edge) } }
            operations.append(.transform(try OCIOConfigTransform(yaml: .tagged("MatrixTransform", .mapping([
                "matrix": .sequence(matrix.map { .scalar(String($0)) })
            ])))))
        }
        operations.append(.lut(try lut(dimension: 3, size: edge, values: redFast(data, edge: edge))))
        return operations
    }

    public static func cineSpace(_ source: String) throws -> [OCIONativeFileOperation] {
        let lines = rows(source)
        guard lines.count > 2, lines[0] == ["CSPLUTV100"], ["1D", "3D"].contains(lines[1][0]) else { throw OCIOConfigError.invalid("invalid cineSpace header") }
        var cursor = 2
        func next() throws -> [String] {
            guard cursor < lines.count else { throw OCIOConfigError.invalid("truncated cineSpace file") }
            defer { cursor += 1 }
            return lines[cursor]
        }
        if lines[cursor] == ["BEGIN", "METADATA"] {
            while cursor < lines.count, lines[cursor] != ["END", "METADATA"] { cursor += 1 }
            guard cursor < lines.count else { throw OCIOConfigError.invalid("unterminated cineSpace metadata") }
            cursor += 1
        }
        var abscissae: [[Float]] = [], ordinates: [[Float]] = [], needsPrelut = false
        for _ in 0..<3 {
            let row = try next()
            guard row.count == 1, let count = Int(row[0]), count >= 0, count <= 1_048_576 else { throw OCIOConfigError.invalid("invalid cineSpace prelut size") }
            if count < 2 { abscissae.append([0, 1]); ordinates.append([0, 1]); continue }
            let x = try numbers(next(), count: count).map(Float.init)
            let y = try numbers(next(), count: count).map(Float.init)
            guard zip(x, x.dropFirst()).allSatisfy({ $1 > $0 }) else { throw OCIOConfigError.invalid("cineSpace input knots must increase") }
            if zip(x, y).contains(where: { abs($0 - $1) > 1e-6 * max(abs($0), abs($1)) }) { needsPrelut = true }
            abscissae.append(x); ordinates.append(y)
        }
        var operations: [OCIONativeFileOperation] = []
        if needsPrelut {
            // Match upstream's cubic resampling onto 65,536 uniform Float32 entries.
            var values = Array(repeating: Float(0), count: 65536 * 3)
            for channel in 0..<3 {
                let x = abscissae[channel], y = ordinates[channel]
                let coefficients = cineCoefficients(x: x, y: y)
                var segment = 0
                for index in 0..<65536 {
                    let fraction = Float(index) / 65535
                    let input = x[0] * (1 - fraction) + x.last! * fraction
                    while segment + 2 < x.count, input >= x[segment + 1] { segment += 1 }
                    let z = (input - x[segment]) / (x[segment + 1] - x[segment])
                    let p = coefficients[segment]
                    values[index * 3 + channel] = p[0] + z * (p[1] + z * (p[2] + z * p[3]))
                }
            }
            let pre = try lut(dimension: 1, size: 65536, values: values,
                              minimum: abscissae.map { Double($0.first!) }, maximum: abscissae.map { Double($0.last!) })
            operations.append(.configuredLUT(pre, interpolation: "linear", inverse: false))
        }
        let dimensions = try next()
        let dimension = lines[1][0] == "1D" ? 1 : 3
        guard dimensions.count == dimension else { throw OCIOConfigError.invalid("invalid cineSpace LUT dimensions") }
        let edge = try size(dimensions[0], maximum: dimension == 1 ? 1_048_576 : 129)
        guard dimensions.allSatisfy({ Int($0) == edge }) else { throw OCIOConfigError.invalid("cineSpace cube must be uniform") }
        let count = dimension == 1 ? edge : edge * edge * edge
        var data: [Float] = []
        for _ in 0..<count { data += try numbers(next(), count: 3).map(Float.init) }
        operations.append(.lut(try lut(dimension: dimension, size: edge, values: data)))
        return operations
    }

    static func cineCoefficients(x: [Float], y: [Float]) -> [[Float]] {
        if x.count == 2 { return [[y[0], y[1] - y[0], 0, 0]] }
        return (0..<(x.count - 1)).map { i in
            let f0 = y[i], f1 = y[i + 1], delta = x[i + 1] - x[i]
            if i == 0 {
                let derivative = (y[i + 2] - f0) / (1 + (x[i + 2] - x[i + 1]) / delta)
                return [f0, -2 * f0 + 2 * f1 - derivative, f0 - f1 + derivative, 0]
            }
            let derivative0 = (f1 - y[i - 1]) / (1 + (x[i] - x[i - 1]) / delta)
            if i == x.count - 2 { return [f0, derivative0, -f0 + f1 - derivative0, 0] }
            let derivative1 = (y[i + 2] - f0) / (1 + (x[i + 2] - x[i + 1]) / delta)
            return [f0, derivative0, -3 * f0 - 2 * derivative0 + 3 * f1 - derivative1,
                    2 * f0 + derivative0 - 2 * f1 + derivative1]
        }
    }

    public static func iridasLook(_ source: String) throws -> [OCIONativeFileOperation] {
        let root = try NativeXMLReader.parse(source)
        guard root.name.lowercased() == "look",
              let node = root.children.first(where: { $0.name.lowercased() == "lut" }),
              let sizeNode = node.children.first(where: { $0.name.lowercased() == "size" }),
              let dataNode = node.children.first(where: { $0.name.lowercased() == "data" }) else {
            throw OCIOConfigError.invalid("Iridas Look needs Look/LUT/Size and Data")
        }
        let edge = try size(sizeNode.text.filter { !$0.isWhitespace && $0 != "\"" }, maximum: 129)
        let hex = Array(dataNode.text.filter { !$0.isWhitespace && $0 != "\"" }.utf8)
        guard hex.count == edge * edge * edge * 3 * 8 else { throw OCIOConfigError.invalid("Iridas Look hexadecimal LUT length differs from size") }
        func nibble(_ byte: UInt8) throws -> UInt32 {
            switch byte {
            case 48...57: return UInt32(byte - 48)
            case 65...70: return UInt32(byte - 55)
            case 97...102: return UInt32(byte - 87)
            default: throw OCIOConfigError.invalid("invalid Iridas Look hexadecimal character")
            }
        }
        var values: [Float] = []
        values.reserveCapacity(hex.count / 8)
        for offset in stride(from: 0, to: hex.count, by: 8) {
            var bits: UInt32 = 0
            for byte in 0..<4 {
                let hi = try nibble(hex[offset + byte * 2]), lo = try nibble(hex[offset + byte * 2 + 1])
                bits |= (hi * 16 + lo) << (byte * 8)
            }
            values.append(Float(bitPattern: bits))
        }
        return [.lut(try lut(dimension: 3, size: edge, values: values))]
    }

    public static func houdini(_ source: String) throws -> [OCIONativeFileOperation] {
        let lines = rows(source)
        guard let marker = lines.firstIndex(where: { $0[0].lowercased() == "lut:" }) else { throw OCIOConfigError.invalid("Houdini LUT: marker missing") }
        var headers: [String: [String]] = [:]
        for row in lines[..<marker] { headers[row[0].lowercased()] = Array(row.dropFirst()) }
        func header(_ name: String, count: Int) throws -> [String] {
            guard let value = headers[name], value.count == count else { throw OCIOConfigError.invalid("invalid Houdini \(name) header") }
            return value
        }
        _ = try header("version", count: 1)
        _ = try header("format", count: 1)
        let type = try header("type", count: 1)[0].lowercased()
        guard ["c", "3d", "3d+1d"].contains(type) else { throw OCIOConfigError.invalid("unsupported Houdini type \(type)") }
        let from = try numbers(header("from", count: 2), count: 2)
        _ = try numbers(header("to", count: 2), count: 2)
        _ = try numbers(header("black", count: 1), count: 1)
        _ = try numbers(header("white", count: 1), count: 1)
        let sizes = try header("length", count: type == "3d+1d" ? 2 : 1)
        let edge = try size(sizes[0], maximum: type == "c" ? 1_048_576 : 129)
        let tokens = lines.dropFirst(marker + 1).joined().joined(separator: " ")
            .replacingOccurrences(of: "{", with: " { ").replacingOccurrences(of: "}", with: " } ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var blocks: [String: [Float]] = [:], cursor = 0
        while cursor < tokens.count {
            let name: String
            if tokens[cursor] == "{" { name = "3d"; cursor += 1 }
            else {
                name = tokens[cursor].lowercased(); cursor += 1
                guard cursor < tokens.count, tokens[cursor] == "{" else { throw OCIOConfigError.invalid("Houdini block missing opening brace") }
                cursor += 1
            }
            guard blocks[name] == nil else { throw OCIOConfigError.invalid("duplicate Houdini LUT block") }
            var data: [Float] = []
            while cursor < tokens.count, tokens[cursor] != "}" {
                data.append(Float(try numbers([tokens[cursor]], count: 1)[0])); cursor += 1
            }
            guard cursor < tokens.count else { throw OCIOConfigError.invalid("Houdini block missing closing brace") }
            cursor += 1; blocks[name] = data
        }
        var operations: [OCIONativeFileOperation] = []
        if type == "c" || type == "3d+1d" {
            let key = type == "c" ? "rgb" : "pre"
            let count = type == "c" ? edge : try size(sizes[1], maximum: 1_048_576)
            guard let values = blocks[key], values.count == count else { throw OCIOConfigError.invalid("Houdini \(key) block entry count mismatch") }
            operations.append(.lut(try lut(dimension: 1, size: count,
                values: values.flatMap { [$0, $0, $0] },
                minimum: Array(repeating: from[0], count: 3), maximum: Array(repeating: from[1], count: 3))))
        }
        if type != "c" {
            guard let values = blocks["3d"] else { throw OCIOConfigError.invalid("Houdini 3D block missing") }
            // Upstream ignores From/To for a standalone 3D Houdini LUT.
            operations.append(.lut(try lut(dimension: 3, size: edge, values: values)))
        }
        return operations
    }

    public static func discreet(_ source: String, filename: String) throws -> [OCIONativeFileOperation] {
        let lines = rows(source)
        guard let first = lines.first else { throw OCIOConfigError.invalid("empty Discreet LUT") }
        var count = 256, tables = 1, start = 0, outputCount: Int?, outputHalf = false
        if first[0].lowercased() == "lut:" {
            guard (3...4).contains(first.count), let n = Int(first[1]), [1, 3, 4].contains(n),
                  let length = Int(first[2]), length >= 2, length <= 65536 else { throw OCIOConfigError.invalid("invalid Discreet LUT header") }
            count = length; tables = n; start = 1
            if first.count == 4 {
                outputHalf = first[3].lowercased().hasSuffix("f")
                let text = outputHalf ? String(first[3].dropLast()) : first[3]
                guard let value = Int(text), [256, 1024, 4096, 65536].contains(value) else { throw OCIOConfigError.invalid("invalid Discreet output depth") }
                outputCount = value
            }
        } else if first.count != 1 || Int(first[0]) == nil { throw OCIOConfigError.invalid("not a Discreet LUT file") }
        if outputCount == nil, let range = filename.lowercased().range(of: "to") {
            let suffix = filename.lowercased()[range.upperBound...]
            if suffix.hasPrefix("16f") { outputCount = 65536; outputHalf = true }
            else {
                for (label, value) in [("8", 256), ("10", 1024), ("12", 4096), ("16", 65536)] where suffix.hasPrefix(label) { outputCount = value; break }
            }
        }
        let scale = Float((outputCount ?? ([256, 1024, 4096, 65536].contains(count) ? count : 2)) - 1)
        let tokens = lines.dropFirst(start).flatMap { $0 }
        guard tokens.count == count * tables else { throw OCIOConfigError.invalid("Discreet LUT entry count mismatch") }
        let raw = try tokens.map { text -> UInt16 in
            guard let value = Int(text) else { throw OCIOConfigError.invalid("Discreet LUT requires integer words") }
            return UInt16(truncatingIfNeeded: value)
        }
        var values: [Float] = []
        values.reserveCapacity(count * 3)
        for index in 0..<count { for channel in 0..<3 {
            let word = raw[(tables == 1 ? 0 : channel) * count + index]
            values.append(outputHalf ? halfValue(word) : Float(word) / scale)
        } }
        return [.lut(try lut(dimension: 1, size: count, values: values, halfDomain: count == 65536))]
    }

    static func halfValue(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 31), fraction = UInt32(bits & 1023)
        if exponent == 31 { return Float(bitPattern: sign | 0x7f800000 | fraction << 13) }
        if exponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            var mantissa = fraction, power: UInt32 = 113
            while mantissa & 1024 == 0 { mantissa <<= 1; power -= 1 }
            return Float(bitPattern: sign | power << 23 | (mantissa & 1023) << 13)
        }
        return Float(bitPattern: sign | (exponent + 112) << 23 | fraction << 13)
    }
}

private extension Double {
    func cubeRoot() -> Double { Foundation.pow(self, 1.0 / 3.0) }
}
