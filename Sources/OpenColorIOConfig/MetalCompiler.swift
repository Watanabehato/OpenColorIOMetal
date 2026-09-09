// SPDX-License-Identifier: BSD-3-Clause
// Mathematical formulas follow OpenColorIO's BSD-3-Clause GPU implementations.
import Foundation

public struct OCIONativeTexture: Sendable {
    public let index: Int
    public let dimension: Int
    public let width: Int
    public let height: Int
    public let depth: Int
    public let channels: Int
    public let values: [Float]
}

public struct OCIONativeShader: Sendable {
    public let source: String
    public let kernel: String
    public let textures: [OCIONativeTexture]
}

public enum OCIONativeStage: Sendable {
    case shader(OCIONativeShader)
    case builtin(style: String, direction: OCIOConfigDirection)
}

extension OCIOConfigDocument {
    /// Creates native Metal stages; built-in transforms are resolved by the exact
    /// archived OCIO shader registry, without executing a C++ runtime.
    public func nativeStages(from source: String, to destination: String, dataBypass: Bool = true) throws -> [OCIONativeStage] {
        try nativeStages(steps: conversionPlan(from: source, to: destination, dataBypass: dataBypass))
    }
    public func nativeStages(steps: [OCIOConfigTransformStep]) throws -> [OCIONativeStage] {
        var compiler = OCIONativeCompiler(config: self)
        for step in steps { try compiler.append(step, depth: 0) }
        compiler.flush()
        return compiler.stages
    }
    public func metalShader(from source: String, to destination: String, dataBypass: Bool = true) throws -> OCIONativeShader {
        let stages = try nativeStages(from: source, to: destination, dataBypass: dataBypass)
        if stages.isEmpty { return OCIONativeCompiler.shader(body: "", textures: []) }
        guard stages.count == 1, case let .shader(shader) = stages[0] else {
            throw OCIOConfigError.unavailableTransform("this graph requires multiple Metal stages; use nativeStages or nativeProcessor")
        }
        return shader
    }
}

struct OCIONativeCompiler {
    let config: OCIOConfigDocument
    var stages: [OCIONativeStage] = []
    var body: [String] = []
    var textures: [OCIONativeTexture] = []
    var helperFunctions: [String] = []

    static func shader(body: String, textures: [OCIONativeTexture], helperFunctions: [String] = []) -> OCIONativeShader {
        let declarations = textures.map { ", texture\($0.dimension)d<float, access::sample> lut\($0.index) [[texture(\($0.index))]]" }.joined()
        return OCIONativeShader(source: """
        #include <metal_stdlib>
        using namespace metal;
        \(helperFunctions.joined(separator: "\n"))
        kernel void ocio_kernel(device const float4* input [[buffer(0)]],
                                device float4* output [[buffer(1)]],
                                constant uint& count [[buffer(2)]],
                                uint index [[thread_position_in_grid]]\(declarations)) {
            if (index >= count) return;
            float4 pixel = input[index];
            \(body)
            output[index] = pixel;
        }
        """, kernel: "ocio_kernel", textures: textures)
    }
    mutating func flush() {
        guard !body.isEmpty else { return }
        stages.append(.shader(Self.shader(body: body.joined(separator: "\n"), textures: textures, helperFunctions: helperFunctions)))
        body.removeAll(); textures.removeAll(); helperFunctions.removeAll()
    }
    mutating func append(_ step: OCIOConfigTransformStep, depth: Int) throws {
        guard depth < 128 else { throw OCIOConfigError.invalid("recursive transform graph exceeds 128 levels") }
        let transform = step.transform
        let p = NativeParameters(transform.parameters, owner: transform.type)
        let inverse = step.direction == .inverse
        switch transform.type {
        case "GroupTransform":
            let children = inverse ? Array(transform.children.reversed()) : transform.children
            for child in children { try append(OCIOConfigTransformStep(transform: child, inverse: inverse, label: step.label), depth: depth + 1) }
        case "BuiltinTransform":
            let style = try config.context.resolve(p.string("style"))
            flush(); stages.append(.builtin(style: style, direction: step.direction))
        case "ColorSpaceTransform":
            let src = try p.string(inverse ? "dst" : "src")
            let dst = try p.string(inverse ? "src" : "dst")
            let bypass = try p.bool("data_bypass", defaultValue: true)
            for nested in try config.conversionPlan(from: src, to: dst, dataBypass: bypass) { try append(nested, depth: depth + 1) }
        case "LookTransform": try appendLook(p, inverse: inverse, depth: depth + 1)
        case "DisplayViewTransform":
            let steps = try config.displayViewPlan(source: p.string("src"), display: p.string("display"), view: p.string("view"),
                direction: step.direction, looksBypass: p.bool("looks_bypass", defaultValue: false), dataBypass: p.bool("data_bypass", defaultValue: true))
            for nested in steps { try append(nested, depth: depth + 1) }
        case "FileTransform": try appendFile(p, inverse: inverse, depth: depth + 1)
        case "MatrixTransform": body.append(try matrix(p, inverse: inverse))
        case "RangeTransform": body.append(try range(p, inverse: inverse))
        case "ExponentTransform": body.append(try exponent(p, inverse: inverse))
        case "ExponentWithLinearTransform": body.append(try exponentWithLinear(p, inverse: inverse))
        case "LogTransform", "LogAffineTransform", "LogCameraTransform": body.append(try logarithm(p, inverse: inverse, camera: transform.type == "LogCameraTransform"))
        case "CDLTransform": body.append(try cdl(p, inverse: inverse))
        case "ExposureContrastTransform": body.append(try exposureContrast(p, inverse: inverse))
        case "AllocationTransform": body.append(try allocation(p, inverse: inverse))
        case "FixedFunctionTransform":
            let code = try fixedFunction(p, inverse: inverse)
            body.append(code)
        case "GradingPrimaryTransform", "GradingRGBCurveTransform", "GradingHueCurveTransform", "GradingToneTransform":
            let code = try grading(p, type: transform.type, inverse: inverse)
            body.append(code)
        default: throw OCIOConfigError.unavailableTransform("native \(transform.type) execution is not implemented")
        }
    }

    mutating func appendLook(_ p: NativeParameters, inverse: Bool, depth: Int) throws {
        let source = try p.string(inverse ? "dst" : "src")
        let destination = try p.string(inverse ? "src" : "dst")
        let selected = try config.selectedLooks(p.string("looks"))
        let planned = try config.lookSteps(from: source, selected: selected, inverse: inverse)
        for step in planned.steps { try append(step, depth: depth + 1) }
        for step in try config.conversionPlan(from: planned.result, to: destination) { try append(step, depth: depth + 1) }
    }
    func matrix(_ p: NativeParameters, inverse: Bool) throws -> String {
        var matrix = try p.vector("matrix", count: 16, defaultValue: (0..<16).map { $0 % 5 == 0 ? 1 : 0 })
        var offset = try p.vector("offset", count: 4, defaultValue: [0, 0, 0, 0])
        if inverse {
            matrix = try invertMatrix(matrix)
            offset = (0..<4).map { row in -(0..<4).reduce(0.0) { $0 + matrix[row * 4 + $1] * offset[$1] } }
        }
        let rows = (0..<4).map { row in "dot(pixel, \(mslVector(Array(matrix[(row * 4)..<(row * 4 + 4)]))))" }
        return "pixel = float4(\(rows.joined(separator: ", "))) + \(mslVector(offset));"
    }

    func range(_ p: NativeParameters, inverse: Bool) throws -> String {
        let minimumIn = try p.optionalNumber(inverse ? "min_out_value" : "min_in_value")
        let minimumOut = try p.optionalNumber(inverse ? "min_in_value" : "min_out_value")
        let maximumIn = try p.optionalNumber(inverse ? "max_out_value" : "max_in_value")
        let maximumOut = try p.optionalNumber(inverse ? "max_in_value" : "max_out_value")
        guard (minimumIn == nil) == (minimumOut == nil), (maximumIn == nil) == (maximumOut == nil) else { throw p.error("input/output bounds must be paired") }
        var scale = 1.0, offset = 0.0
        if let a = minimumIn, let b = maximumIn, let c = minimumOut, let d = maximumOut {
            guard b > a && d > c else { throw p.error("range bounds must increase") }
            scale = (d - c) / (b - a); offset = c - a * scale
        } else if let a = minimumIn, let b = minimumOut {
            guard a == b else { throw p.error("minimum-only input and output bounds must be equal") }
        } else if let a = maximumIn, let b = maximumOut {
            guard a == b else { throw p.error("maximum-only input and output bounds must be equal") }
        }
        let style = try p.string("style", defaultValue: "clamp").lowercased()
        guard ["clamp", "noclamp"].contains(style) else { throw p.error("unknown range style") }
        var code = "pixel.rgb = pixel.rgb * \(mslNumber(scale)) + \(mslNumber(offset));"
        if style == "clamp" {
            if let minimumOut { code += "\npixel.rgb = max(pixel.rgb, float3(\(mslNumber(minimumOut))));" }
            if let maximumOut { code += "\npixel.rgb = min(pixel.rgb, float3(\(mslNumber(maximumOut))));" }
        }
        return code
    }

    func exponent(_ p: NativeParameters, inverse: Bool) throws -> String {
        var gamma = try p.vector("value", count: 4, defaultValue: [1, 1, 1, 1], scalarAlpha: 1)
        guard gamma.allSatisfy({ $0 > 0 }) else { throw p.error("exponents must be positive") }
        if inverse { gamma = gamma.map { 1 / $0 } }
        let style = try p.string("style", defaultValue: "clamp").lowercased()
        switch style {
        case "clamp": return "pixel = pow(max(pixel, float4(0.0f)), \(mslVector(gamma)));"
        case "mirror": return "pixel = sign(pixel) * pow(abs(pixel), \(mslVector(gamma)));"
        case "passthru", "pass_thru": return "pixel = select(pixel, pow(max(pixel, float4(0.0f)), \(mslVector(gamma))), pixel > 0.0f);"
        default: throw p.error("unsupported exponent negative style '\(style)'")
        }
    }

    func exponentWithLinear(_ p: NativeParameters, inverse: Bool) throws -> String {
        let gammas = try p.vector("gamma", count: 4, scalarAlpha: 1)
        let offsets = try p.vector("offset", count: 4, scalarAlpha: 0)
        guard gammas.allSatisfy({ $0 >= 1 && $0 <= 10 }), offsets.allSatisfy({ $0 >= 0 && $0 <= 0.9 }) else { throw p.error("gamma or offset outside OCIO moncurve limits") }
        let style = try p.string("style", defaultValue: "linear").lowercased()
        guard ["linear", "mirror"].contains(style) else { throw p.error("moncurve style must be linear or mirror") }
        var code = "{\n"
        if style == "mirror" { code += "float4 signcol = sign(pixel); pixel = abs(pixel);\n" }
        for (index, channel) in ["r", "g", "b", "a"].enumerated() {
            if gammas[index] == 1 && offsets[index] == 0 { continue }
            let gamma = max(gammas[index], 1.000001), offset = max(offsets[index], 0.000001)
            let breakpoint = offset / (gamma - 1)
            let slope = (gamma - 1) / offset * pow(offset * gamma / ((gamma - 1) * (1 + offset)), gamma)
            let x = "pixel.\(channel)"
            if inverse {
                code += "\(x) = \(x) > \(mslNumber(breakpoint * slope)) ? pow(max(\(x), 0.0f), \(mslNumber(1 / gamma))) * \(mslNumber(1 + offset)) - \(mslNumber(offset)) : \(x) / \(mslNumber(slope));\n"
            } else {
                code += "\(x) = \(x) > \(mslNumber(breakpoint)) ? pow(max(\(x) * \(mslNumber(1 / (1 + offset))) + \(mslNumber(offset / (1 + offset))), 0.0f), \(mslNumber(gamma))) : \(x) * \(mslNumber(slope));\n"
            }
        }
        if style == "mirror" { code += "pixel *= signcol;\n" }
        return code + "}"
    }

    func logarithm(_ p: NativeParameters, inverse: Bool, camera: Bool) throws -> String {
        let base = try p.number("base", defaultValue: 2)
        guard base > 0 && base != 1 else { throw p.error("log base must be positive and different from one") }
        let linSlope = try p.vector("lin_side_slope", count: 3, defaultValue: [1, 1, 1])
        let linOffset = try p.vector("lin_side_offset", count: 3, defaultValue: [0, 0, 0])
        let logSlope = try p.vector("log_side_slope", count: 3, defaultValue: [1, 1, 1])
        let logOffset = try p.vector("log_side_offset", count: 3, defaultValue: [0, 0, 0])
        guard linSlope.allSatisfy({ $0 > 0 }), logSlope.allSatisfy({ $0 > 0 }) else { throw p.error("logarithm slopes must be positive") }
        let breaks = camera ? try p.vector("lin_side_break", count: 3) : []
        let specifiedLinear = try p.optionalVector("linear_slope", count: 3)
        var code = "{\n"
        for (i, channel) in ["r", "g", "b"].enumerated() {
            let x = "pixel.\(channel)"
            let logarithmic: String
            if inverse { logarithmic = "(pow(\(mslNumber(base)), (\(x) - \(mslNumber(logOffset[i]))) / \(mslNumber(logSlope[i]))) - \(mslNumber(linOffset[i]))) / \(mslNumber(linSlope[i]))" }
            else { logarithmic = "log(max(\(x) * \(mslNumber(linSlope[i])) + \(mslNumber(linOffset[i])), 1.1754943508222875e-38f)) * \(mslNumber(logSlope[i] / log(base))) + \(mslNumber(logOffset[i]))" }
            if camera {
                let argument = linSlope[i] * breaks[i] + linOffset[i]
                guard argument > 0 else { throw p.error("camera log break is outside logarithm domain") }
                let logBreak = logSlope[i] * log(argument) / log(base) + logOffset[i]
                let linearSlope = specifiedLinear?[i] ?? logSlope[i] * linSlope[i] / (argument * log(base))
                guard linearSlope != 0 else { throw p.error("camera linear slope cannot be zero") }
                let linearOffset = logBreak - linearSlope * breaks[i]
                let linear = inverse ? "(\(x) - \(mslNumber(linearOffset))) / \(mslNumber(linearSlope))" : "\(x) * \(mslNumber(linearSlope)) + \(mslNumber(linearOffset))"
                code += "\(x) = \(x) > \(mslNumber(inverse ? logBreak : breaks[i])) ? \(logarithmic) : \(linear);\n"
            } else { code += "\(x) = \(logarithmic);\n" }
        }
        return code + "}"
    }

    func cdl(_ p: NativeParameters, inverse: Bool) throws -> String {
        let slope = try p.vector("slope", count: 3, defaultValue: [1, 1, 1])
        let offset = try p.vector("offset", count: 3, defaultValue: [0, 0, 0])
        let power = try p.vector("power", count: 3, defaultValue: [1, 1, 1])
        let saturation = try p.number(p.values["sat"] == nil ? "saturation" : "sat", defaultValue: 1)
        guard slope.allSatisfy({ $0 >= 0 }), power.allSatisfy({ $0 > 0 }), saturation >= 0 else { throw p.error("invalid CDL parameters") }
        let style = try p.string("style", defaultValue: "noClamp").lowercased()
        guard ["default", "asc", "noclamp"].contains(style) else { throw p.error("unknown CDL style '\(style)'") }
        let clamp = style == "asc"
        if inverse && (saturation == 0 || slope.contains(0)) { throw p.error("CDL inverse is singular") }
        var code = "{\n"
        if inverse {
            if clamp { code += "pixel.rgb = clamp(pixel.rgb, 0.0f, 1.0f);\n" }
            code += "float luma = dot(pixel.rgb, float3(0.2126f, 0.7152f, 0.0722f));\npixel.rgb = luma + \(mslNumber(1 / saturation)) * (pixel.rgb - luma);\n"
        } else { code += "pixel.rgb = pixel.rgb * \(mslVector(slope)) + \(mslVector(offset));\n" }
        let exponents = inverse ? power.map { 1 / $0 } : power
        if clamp { code += "pixel.rgb = pow(clamp(pixel.rgb, 0.0f, 1.0f), \(mslVector(exponents)));\n" }
        else { code += "pixel.rgb = select(pixel.rgb, pow(abs(pixel.rgb), \(mslVector(exponents))), pixel.rgb >= 0.0f);\n" }
        if inverse { code += "pixel.rgb = (pixel.rgb - \(mslVector(offset))) / \(mslVector(slope));\n" }
        else { code += "float luma = dot(pixel.rgb, float3(0.2126f, 0.7152f, 0.0722f));\npixel.rgb = luma + \(mslNumber(saturation)) * (pixel.rgb - luma);\n" }
        if clamp { code += "pixel.rgb = clamp(pixel.rgb, 0.0f, 1.0f);\n" }
        return code + "}"
    }

    func exposureContrast(_ p: NativeParameters, inverse: Bool) throws -> String {
        let exposure = try p.number("exposure", defaultValue: 0)
        let contrast = max(0.001, try p.number("contrast", defaultValue: 1) * p.number("gamma", defaultValue: 1))
        var pivot = max(0.001, try p.number("pivot", defaultValue: 0.18))
        let style = try p.string("style", defaultValue: "linear").lowercased()
        if style == "log" || style == "logarithmic" {
            let step = try p.number("log_exposure_step", defaultValue: 0.088)
            let midpoint = try p.number("log_midway_gray", defaultValue: 0.435)
            let logPivot = max(0, log2(pivot / 0.18) * step + midpoint)
            let scale = inverse ? 1 / contrast : contrast
            let offset = inverse ? logPivot - logPivot / contrast - exposure * step : (exposure * step - logPivot) * contrast + logPivot
            return "pixel.rgb = pixel.rgb * \(mslNumber(scale)) + \(mslNumber(offset));"
        }
        guard ["linear", "video"].contains(style) else { throw p.error("unknown exposure contrast style") }
        var multiplier = pow(2, exposure)
        if style == "video" { pivot = pow(pivot, 1 / 1.83); multiplier = pow(multiplier, 1 / 1.83) }
        let power = inverse ? 1 / contrast : contrast
        var code = inverse ? "" : "pixel.rgb *= \(mslNumber(multiplier));\n"
        if power != 1 { code += "pixel.rgb = pow(max(pixel.rgb / \(mslNumber(pivot)), float3(0.0f)), float3(\(mslNumber(power)))) * \(mslNumber(pivot));\n" }
        if inverse { code += "pixel.rgb /= \(mslNumber(multiplier));" }
        return code
    }

    func allocation(_ p: NativeParameters, inverse: Bool) throws -> String {
        let style = try p.string("allocation", defaultValue: "uniform")
        guard ["uniform", "lg2"].contains(style) else { throw p.error("unknown allocation") }
        let values = try p.optionalVector("vars", count: nil) ?? (style == "lg2" ? [-10, 6] : [0, 1])
        guard values.count == 2 || (style == "lg2" && values.count == 3), values[1] > values[0] else { throw p.error("invalid allocation vars") }
        let offset = values.count == 3 ? values[2] : 0
        let scale = values[1] - values[0]
        if inverse {
            var code = "pixel.rgb = pixel.rgb * \(mslNumber(scale)) + \(mslNumber(values[0]));"
            if style == "lg2" { code += "\npixel.rgb = exp2(pixel.rgb) - \(mslNumber(offset));" }
            return code
        }
        var code = style == "lg2" ? "pixel.rgb = log2(max(pixel.rgb + \(mslNumber(offset)), float3(1.1754943508222875e-38f)));\n" : ""
        code += "pixel.rgb = (pixel.rgb - \(mslNumber(values[0]))) / \(mslNumber(scale));"
        return code
    }
}

struct NativeParameters {
    let values: [String: YAMLValue]
    let owner: String
    init(_ values: [String: YAMLValue], owner: String) { self.values = values; self.owner = owner }
    func error(_ message: String) -> OCIOConfigError { .invalid("\(owner): \(message)") }
    func string(_ key: String, defaultValue: String? = nil) throws -> String {
        if let text = values[key]?.string { return text }
        if values[key] == nil, let defaultValue { return defaultValue }
        throw error("\(key) must be a string")
    }
    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard let text = value.string, let result = Double(text), result.isFinite, Float(result).isFinite else { throw error("\(key) must be a finite float") }
        return result
    }
    func number(_ key: String, defaultValue: Double) throws -> Double { try optionalNumber(key) ?? defaultValue }
    func optionalVector(_ key: String, count: Int?) throws -> [Double]? {
        guard let value = values[key] else { return nil }
        let array = value.array ?? [value]
        let result = try array.map { value -> Double in
            guard let text = value.string, let number = Double(text), number.isFinite, Float(number).isFinite else { throw error("\(key) must contain finite floats") }
            return number
        }
        if let count, result.count == 1 { return Array(repeating: result[0], count: count) }
        if let count, result.count != count { throw error("\(key) needs \(count) values") }
        return result
    }
    func vector(_ key: String, count: Int, defaultValue: [Double]? = nil, scalarAlpha: Double? = nil) throws -> [Double] {
        if var result = try optionalVector(key, count: count) {
            if values[key]?.string != nil, count == 4, let scalarAlpha { result[3] = scalarAlpha }
            return result
        }
        if let defaultValue { return defaultValue }
        throw error("missing \(key)")
    }
    func bool(_ key: String, defaultValue: Bool) throws -> Bool {
        guard let value = values[key] else { return defaultValue }
        guard let text = value.string?.lowercased(), ["true", "false"].contains(text) else { throw error("\(key) must be boolean") }
        return text == "true"
    }
}

func mslNumber(_ value: Double) -> String {
    let value = Float(value)
    var text = String(value)
    if !text.contains(".") && !text.lowercased().contains("e") { text += ".0" }
    return text + "f"
}
func mslVector(_ values: [Double]) -> String { "float\(values.count)(\(values.map(mslNumber).joined(separator: ", ")))" }

func invertMatrix(_ values: [Double]) throws -> [Double] {
    var rows = (0..<4).map { row in Array(values[(row * 4)..<(row * 4 + 4)]) + (0..<4).map { $0 == row ? 1.0 : 0.0 } }
    for col in 0..<4 {
        guard let pivot = (col..<4).max(by: { abs(rows[$0][col]) < abs(rows[$1][col]) }), rows[pivot][col] != 0 else { throw OCIOConfigError.invalid("MatrixTransform inverse is singular") }
        rows.swapAt(col, pivot)
        let divisor = rows[col][col]
        for x in 0..<8 { rows[col][x] /= divisor }
        for row in 0..<4 where row != col {
            let scale = rows[row][col]
            for x in 0..<8 { rows[row][x] -= scale * rows[col][x] }
        }
    }
    let result = rows.flatMap { Array($0[4..<8]) }
    guard result.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw OCIOConfigError.invalid("MatrixTransform inverse overflows float") }
    return result
}
