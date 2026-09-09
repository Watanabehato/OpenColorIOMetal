// SPDX-License-Identifier: BSD-3-Clause
import Foundation

/// Native CLF/CTF XML operation decoding. Unsupported nodes are explicit errors.
public enum CTFFile {
    public static func read(_ source: String, relativeTo directory: URL) throws -> [OCIONativeFileOperation] {
        let root = try NativeXMLReader.parse(source)
        guard root.name == "ProcessList" else { throw OCIOConfigError.invalid("CLF/CTF root must be ProcessList") }
        var operations: [OCIONativeFileOperation] = []
        var previousDepth: String?
        for node in root.children {
            if ["Description", "Info", "InputDescriptor", "OutputDescriptor", "Id"].contains(node.name) { continue }
            if let previousDepth, let input = node.attributes["inBitDepth"], previousDepth != input { throw error(node, "adjacent operation bit depths do not match") }
            let inputScale = try bitDepth(node.attributes["inBitDepth"], node: node)
            let outputScale = try bitDepth(node.attributes["outBitDepth"], node: node)
            previousDepth = node.attributes["outBitDepth"]
            switch node.name {
            case "Matrix": operations.append(.transform(try matrix(node, inputScale: inputScale, outputScale: outputScale)))
            case "Range": operations.append(.transform(try range(node, inputScale: inputScale, outputScale: outputScale)))
            case "Gamma", "Exponent": operations.append(.transform(try gamma(node)))
            case "Log": operations.append(.transform(try logarithm(node)))
            case "ASC_CDL": operations.append(.transform(try cdl(node)))
            case "ExposureContrast": operations.append(.transform(try exposureContrast(node)))
            case "FixedFunction": operations.append(.transform(try fixedFunction(node)))
            case "GradingPrimary", "GradingRGBCurve", "GradingHueCurve", "GradingTone":
                operations.append(.transform(try gradingXML(node)))
            case "LUT1D", "LUT3D", "InvLUT1D", "InvLUT3D":
                let reversed = node.name.hasPrefix("Inv")
                let lut = try lookup(node, outputScale: reversed ? inputScale : outputScale)
                operations.append(.configuredLUT(lut, interpolation: node.attributes["interpolation"] ?? "linear", inverse: reversed))
            case "Reference":
                guard node.attributes["alias"] == nil else { throw OCIOConfigError.unavailableTransform("CTF Reference aliases require an alias resolver") }
                guard let path = node.attributes["path"], !path.isEmpty else { throw error(node, "Reference path is missing") }
                let absolute = (path as NSString).isAbsolutePath ? path : directory.appendingPathComponent(path).path
                let inverse = node.attributes["inverted"]?.lowercased() == "true"
                operations.append(.transform(try transform("FileTransform", fields: ["src": .scalar(absolute)], inverse: inverse)))
            default: throw OCIOConfigError.unavailableTransform("CLF/CTF operation '\(node.name)' is not implemented")
            }
        }
        return operations
    }
    static func error(_ node: NativeXMLNode, _ message: String) -> OCIOConfigError { .invalid("\(node.name): \(message)") }
    static func bitDepth(_ text: String?, node: NativeXMLNode) throws -> Double {
        // Reference nodes do not require bit-depth attributes in CTF.
        if node.name == "Reference", text == nil { return 1 }
        let maxima: [String: Double] = ["8i": 255, "10i": 1023, "12i": 4095, "14i": 16383, "16i": 65535, "16f": 1, "32f": 1]
        guard let text, let maximum = maxima[text] else { throw error(node, "missing or invalid bit depth") }
        return maximum
    }
    static func transform(_ type: String, fields: [String: YAMLValue], inverse: Bool = false) throws -> OCIOConfigTransform {
        var fields = fields
        if inverse { fields["direction"] = .scalar("inverse") }
        return try OCIOConfigTransform(yaml: .tagged(type, .mapping(fields)))
    }
    static func vector(_ values: [Double]) -> YAMLValue { .sequence(values.map { .scalar(String($0)) }) }
    static func floats(_ text: String) throws -> [Double] { try OCIOLUTFile.numbers(text.split(whereSeparator: \.isWhitespace).map(String.init)) }
    static func array(_ node: NativeXMLNode) throws -> (dimensions: [Int], values: [Double]) {
        let arrays = node.children.filter { $0.name == "Array" }
        guard arrays.count == 1, let text = arrays[0].attributes["dim"] else { throw error(node, "exactly one Array with dimensions is required") }
        let dimensions = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard !dimensions.isEmpty, dimensions.count == text.split(whereSeparator: \.isWhitespace).count,
              dimensions.allSatisfy({ $0 > 0 && $0 <= 1_048_576 }) else { throw error(node, "invalid Array dimensions") }
        return (dimensions, try floats(arrays[0].text))
    }
    static func matrix(_ node: NativeXMLNode, inputScale: Double, outputScale: Double) throws -> OCIOConfigTransform {
        let array = try array(node)
        guard (2...3).contains(array.dimensions.count) else { throw error(node, "Matrix Array dimensions are invalid") }
        let rows = array.dimensions[0], cols = array.dimensions[1]
        guard [3, 4].contains(rows), cols == rows || cols == rows + 1, array.values.count == rows * cols else { throw error(node, "Matrix must be 3x3, 3x4, 4x4 or 4x5") }
        var matrix = [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        var offset = [0.0, 0, 0, 0]
        for row in 0..<rows {
            for col in 0..<rows { matrix[row * 4 + col] = array.values[row * cols + col] * inputScale / outputScale }
            if cols > rows { offset[row] = array.values[row * cols + rows] / outputScale }
        }
        return try transform("MatrixTransform", fields: ["matrix": vector(matrix), "offset": vector(offset)])
    }
    static func range(_ node: NativeXMLNode, inputScale: Double, outputScale: Double) throws -> OCIOConfigTransform {
        var fields: [String: YAMLValue] = [:]
        let keys = ["minInValue": "min_in_value", "maxInValue": "max_in_value", "minOutValue": "min_out_value", "maxOutValue": "max_out_value"]
        for child in node.children {
            if child.name == "Description" { continue }
            guard let key = keys[child.name], fields[key] == nil else { throw error(node, "unknown or duplicate range bound '\(child.name)'") }
            let values = try floats(child.text)
            guard values.count == 1 else { throw error(node, "range bound must be scalar") }
            fields[key] = .scalar(String(values[0] / (child.name.contains("In") ? inputScale : outputScale)))
        }
        fields["style"] = .scalar(node.attributes["style"] ?? "clamp")
        return try transform("RangeTransform", fields: fields)
    }
    static func gamma(_ node: NativeXMLNode) throws -> OCIOConfigTransform {
        let style = (node.attributes["style"] ?? "basicFwd").lowercased()
        let inverse = style.contains("rev")
        let moncurve = style.hasPrefix("moncurve")
        guard style.hasPrefix("basic") || moncurve else { throw error(node, "unknown gamma style '\(style)'") }
        var gamma = [1.0, 1, 1, 1], offset = [0.0, 0, 0, 0]
        var found = false
        for parameters in node.children where ["GammaParams", "ExponentParams"].contains(parameters.name) {
            let channels: [Int]
            if let channel = parameters.attributes["channel"] {
                guard let index = ["R", "G", "B", "A"].firstIndex(of: channel.uppercased()) else { throw error(node, "invalid gamma channel") }
                channels = [index]
            } else { channels = [0, 1, 2] }
            guard let text = parameters.attributes["gamma"] ?? parameters.attributes["exponent"], let value = Double(text), value.isFinite else { throw error(node, "missing gamma value") }
            let offsetValue = Double(parameters.attributes["offset"] ?? "0")
            guard let offsetValue, offsetValue.isFinite else { throw error(node, "invalid gamma offset") }
            for channel in channels { gamma[channel] = value; offset[channel] = offsetValue }
            found = true
        }
        guard found else { throw error(node, "GammaParams are missing") }
        let negative = style.contains("mirror") ? "mirror" : (style.contains("passthru") ? "pass_thru" : (moncurve ? "linear" : "clamp"))
        var fields: [String: YAMLValue] = [moncurve ? "gamma" : "value": vector(gamma), "style": .scalar(negative)]
        if moncurve { fields["offset"] = vector(offset) }
        return try transform(moncurve ? "ExponentWithLinearTransform" : "ExponentTransform", fields: fields, inverse: inverse)
    }
    static func logarithm(_ node: NativeXMLNode) throws -> OCIOConfigTransform {
        let style = (node.attributes["style"] ?? "").lowercased()
        if ["log2", "log10", "antilog2", "antilog10"].contains(style) {
            return try transform("LogTransform", fields: ["base": .scalar(style.hasSuffix("10") ? "10" : "2")], inverse: style.hasPrefix("anti"))
        }
        guard ["lintolog", "logtolin", "cameralintolog", "cameralogtolin"].contains(style) else { throw error(node, "unknown log style") }
        let keys = ["linSideSlope": "lin_side_slope", "linSideOffset": "lin_side_offset", "logSideSlope": "log_side_slope", "logSideOffset": "log_side_offset", "linSideBreak": "lin_side_break", "linearSlope": "linear_slope"]
        var values: [String: [Double]] = ["lin_side_slope": [1, 1, 1], "lin_side_offset": [0, 0, 0], "log_side_slope": [1, 1, 1], "log_side_offset": [0, 0, 0]]
        var base = 2.0
        for parameters in node.children where parameters.name == "LogParams" {
            let channels: [Int]
            if let channel = parameters.attributes["channel"] {
                guard let index = ["R", "G", "B"].firstIndex(of: channel.uppercased()) else { throw error(node, "invalid log channel") }
                channels = [index]
            } else { channels = [0, 1, 2] }
            if let text = parameters.attributes["base"] {
                guard let value = Double(text), value.isFinite else { throw error(node, "invalid log base") }
                base = value
            }
            if parameters.attributes["gamma"] != nil {
                func legacy(_ key: String) throws -> Double {
                    guard let text = parameters.attributes[key], let number = Double(text), number.isFinite else { throw error(node, "legacy LogParams missing '\(key)'") }
                    return number
                }
                base = 10
                let gamma = try legacy("gamma"), white = try legacy("refWhite") / 1023, black = try legacy("refBlack") / 1023
                let highlight = try legacy("highlight"), shadow = try legacy("shadow")
                guard gamma > 0.01, white > black, highlight > shadow else { throw error(node, "invalid legacy log parameters") }
                let multiplier = 0.002 * 1023 / gamma
                let gain = (highlight - shadow) / (1 - pow(10, min((black - white) * multiplier, -0.0001)))
                let offset = gain - (highlight - shadow)
                for channel in channels {
                    values["log_side_slope"]![channel] = 1 / multiplier
                    values["lin_side_slope"]![channel] = 1 / gain
                    values["lin_side_offset"]![channel] = (offset - shadow) / gain
                    values["log_side_offset"]![channel] = white
                }
            } else {
                for (key, target) in keys {
                    guard let text = parameters.attributes[key] else { continue }
                    guard let number = Double(text), number.isFinite else { throw error(node, "invalid log parameter '\(key)'") }
                    if values[target] == nil { values[target] = [number, number, number] }
                    for channel in channels { values[target]![channel] = number }
                }
            }
        }
        var fields = values.mapValues(vector)
        fields["base"] = .scalar(String(base))
        return try transform(style.hasPrefix("camera") ? "LogCameraTransform" : "LogAffineTransform", fields: fields, inverse: style.hasSuffix("logtolin"))
    }
    static func cdl(_ node: NativeXMLNode) throws -> OCIOConfigTransform {
        let style = (node.attributes["style"] ?? "Fwd").lowercased()
        guard ["fwd", "rev", "v1.2_fwd", "v1.2_rev", "fwdnoclamp", "revnoclamp", "noclampfwd", "noclamprev"].contains(style) else { throw error(node, "unknown ASC_CDL style") }
        var fields: [String: YAMLValue] = ["style": .scalar(style.contains("noclamp") ? "noClamp" : "asc")]
        for (name, key, count) in [("Slope", "slope", 3), ("Offset", "offset", 3), ("Power", "power", 3), ("Saturation", "sat", 1)] {
            let children = node.descendants(named: name)
            guard children.count <= 1 else { throw error(node, "duplicate CDL parameter") }
            if let child = children.first {
                let values = try floats(child.text)
                guard values.count == count else { throw error(node, "invalid '\(name)' value count") }
                fields[key] = count == 1 ? .scalar(String(values[0])) : vector(values)
            }
        }
        return try transform("CDLTransform", fields: fields, inverse: style.contains("rev"))
    }
    static func exposureContrast(_ node: NativeXMLNode) throws -> OCIOConfigTransform {
        let style = (node.attributes["style"] ?? "linear").lowercased()
        let inverse = style.hasSuffix("rev")
        var fields: [String: YAMLValue] = ["style": .scalar(inverse ? String(style.dropLast(3)) : style)]
        guard let params = node.children.first(where: { $0.name == "ECParams" }) else { throw error(node, "ECParams missing") }
        for (key, value) in params.attributes { fields[key] = .scalar(value) }
        return try transform("ExposureContrastTransform", fields: fields, inverse: inverse)
    }
    static func fixedFunction(_ node: NativeXMLNode) throws -> OCIOConfigTransform {
        guard let style = node.attributes["style"] else { throw error(node, "fixed function style missing") }
        let aliases: [String: (String, Bool)] = [
            "redmod03fwd": ("ACES_RedMod03", false), "redmod03rev": ("ACES_RedMod03", true),
            "redmod10fwd": ("ACES_RedMod10", false), "redmod10rev": ("ACES_RedMod10", true),
            "glow03fwd": ("ACES_Glow03", false), "glow03rev": ("ACES_Glow03", true),
            "glow10fwd": ("ACES_Glow10", false), "glow10rev": ("ACES_Glow10", true),
            "darktodim10": ("ACES_DarkToDim10", false), "dimtodark10": ("ACES_DarkToDim10", true),
            "gamutcomp13fwd": ("ACES_GamutComp13", false), "gamutcomp13rev": ("ACES_GamutComp13", true),
            "surround": ("REC2100_Surround", false), "rec2100surroundfwd": ("REC2100_Surround", false), "rec2100surroundrev": ("REC2100_Surround", true),
            "acesoutputtransform20fwd": ("ACES_OutputTransform20", false), "acesoutputtransform20inv": ("ACES_OutputTransform20", true),
            "rgb_to_jmh_20": ("ACES_RGB_TO_JMh_20", false), "jmh_to_rgb_20": ("ACES_RGB_TO_JMh_20", true),
            "tonescalecompress20fwd": ("ACES_TONESCALE_COMPRESS_20", false), "tonescalecompress20inv": ("ACES_TONESCALE_COMPRESS_20", true),
            "gamutcompress20fwd": ("ACES_GAMUT_COMPRESS_20", false), "gamutcompress20inv": ("ACES_GAMUT_COMPRESS_20", true),
            "gammalog_to_lin": ("Lin_TO_GammaLog", true), "doublelog_to_lin": ("Lin_TO_DoubleLog", true)
        ]
        let selected = aliases[style.lowercased()] ?? (style, false)
        var fields: [String: YAMLValue] = ["style": .scalar(selected.0)]
        if let parameters = node.attributes["params"] { fields["params"] = vector(try floats(parameters)) }
        return try transform("FixedFunctionTransform", fields: fields, inverse: selected.1)
    }
    static func lookup(_ node: NativeXMLNode, outputScale: Double) throws -> OCIONativeLUT {
        guard !node.children.contains(where: { $0.name == "IndexMap" }) else { throw OCIOConfigError.unavailableTransform("native CLF IndexMap execution is pending") }
        guard node.attributes["halfDomain"]?.lowercased() != "true", node.attributes["rawHalfs"]?.lowercased() != "true", node.attributes["hueAdjust"] == nil else {
            throw OCIOConfigError.unavailableTransform("native half-domain/raw-half/hue-adjusted CLF LUT execution is pending")
        }
        let array = try array(node)
        let dimension = node.name.hasSuffix("1D") ? 1 : 3
        let size = array.dimensions[0]
        guard size >= 2, size <= (dimension == 1 ? 1_048_576 : 129) else { throw error(node, "LUT size out of bounds") }
        let components = array.dimensions.last!
        if dimension == 1 {
            guard array.dimensions.count == 2, [1, 3].contains(components), array.values.count == size * components else { throw error(node, "invalid 1D Array shape") }
            let values = array.values.flatMap { components == 1 ? [$0, $0, $0] : [$0] }.map { Float($0 / outputScale) }
            return try OCIOLUTFile.lut(dimension: 1, size: size, values: values)
        }
        guard array.dimensions == [size, size, size, 3], array.values.count == size * size * size * 3 else { throw error(node, "invalid 3D Array shape") }
        // CLF Array is blue-fast; Metal x coordinates address red.
        var values = Array(repeating: Float(0), count: array.values.count)
        for red in 0..<size { for green in 0..<size { for blue in 0..<size {
            let source = (blue + size * (green + size * red)) * 3
            let destination = (red + size * (green + size * blue)) * 3
            for component in 0..<3 { values[destination + component] = Float(array.values[source + component] / outputScale) }
        } } }
        return try OCIOLUTFile.lut(dimension: 3, size: size, values: values)
    }
}
