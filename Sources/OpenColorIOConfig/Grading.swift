// SPDX-License-Identifier: BSD-3-Clause
// Native control preparation follows OpenColorIO GradingPrimary.cpp,
// GradingTone.cpp and GradingBSplineCurve.cpp. Generated analytical MSL below
// follows their corresponding GPU implementations, without a C++ runtime.
import Foundation

enum GradingUniformValue: Equatable {
    case scalar(Double), vector([Double]), boolean(Bool)
}

private struct GradingShaderTemplate {
    let names: [String]
    let lengths: [Int]
    let source: String
}

extension OCIONativeCompiler {
    mutating func grading(_ p: NativeParameters, type: String, inverse: Bool) throws -> String {
        let style = try gradingStyle(p)
        let kind = ["GradingPrimaryTransform": "primary", "GradingToneTransform": "tone",
                    "GradingRGBCurveTransform": "rgb", "GradingHueCurveTransform": "hue"][type]!
        let values = try gradingPreparedParameters(p, type: type, inverse: inverse)
        if values["localBypass"] == .boolean(true) { return "" }
        var key = "\(kind).\(style).\(inverse ? "inverse" : "forward")"
        let bypassLin = try p.bool("lintolog_bypass", defaultValue: false)
        let drawCurve = try p.bool("draw_curve_only", defaultValue: false)
        if kind == "rgb" && style == "lin" && bypassLin { key += ".bypass" }
        if kind == "hue" && drawCurve { key += ".draw" }
        guard let template = gradingShaderTemplate(key) else { throw p.error("missing grading shader template \(key)") }
        let name = "native_grading_\(helperFunctions.count)_"
        let shader = template.source.replacingOccurrences(of: "ocio_", with: name)
            .replacingOccurrences(of: "grading_transform", with: name + "transform")
        var args: [String] = []
        for (index, uniformName) in template.names.enumerated() {
            let field = uniformName.replacingOccurrences(of: "ocio_grading_\(kind == "rgb" ? "rgbcurve" : kind == "hue" ? "huecurve" : kind)_", with: "")
            guard let value = values[field] else { throw p.error("missing grading parameter \(field)") }
            switch value {
            case let .scalar(number): args.append(gradingNumber(number))
            case let .boolean(boolean): args.append(boolean ? "true" : "false")
            case let .vector(vector):
                if template.lengths[index] == 0 {
                    args.append("float3(" + vector.map(gradingNumber).joined(separator: ", ") + ")")
                } else {
                    let capacity = template.lengths[index]
                    guard vector.count <= capacity else { throw p.error("grading array exceeds upstream capacity \(capacity)") }
                    let symbol = name + "argument_\(index)"
                    let integer = field.hasSuffix("Offsets")
                    let padded = vector + Array(repeating: 0, count: capacity - vector.count)
                    let literal = integer ? padded.map { String(Int($0)) } : padded.map(gradingNumber)
                    helperFunctions.append("constant \(integer ? "int" : "float") \(symbol)[\(capacity)] = {\(literal.joined(separator: ", "))};")
                    args.append(symbol)
                    args.append(String(vector.count))
                }
            }
        }
        helperFunctions.append(shader)
        return "pixel = \(name)transform(\((args + ["pixel"]).joined(separator: ", ")));"
    }
}

func gradingPreparedParameters(_ p: NativeParameters, type: String, inverse: Bool) throws -> [String: GradingUniformValue] {
    let style = try gradingStyle(p)
    switch type {
    case "GradingPrimaryTransform": return try gradingPrimary(p, style: style, inverse: inverse)
    case "GradingToneTransform": return try gradingTone(p, style: style)
    case "GradingRGBCurveTransform": return try gradingCurves(p, style: style, hue: false)
    case "GradingHueCurveTransform": return try gradingCurves(p, style: style, hue: true)
    default: throw p.error("unknown grading transform")
    }
}

private func gradingStyle(_ p: NativeParameters) throws -> String {
    let source = try p.string("style", defaultValue: "log").lowercased()
    let style = source == "linear" ? "lin" : source
    guard ["log", "lin", "video"].contains(style) else { throw p.error("grading style must be log, lin or video") }
    return style
}

private func gradingNumber(_ value: Double) -> String {
    let number = Double(Float(value))
    if number.isNaN { return "NAN" }
    if number == .infinity { return "INFINITY" }
    if number == -.infinity { return "(-INFINITY)" }
    return mslNumber(number)
}

private func gradingNested(_ p: NativeParameters, _ key: String) throws -> NativeParameters {
    guard let value = p.values[key] else { return NativeParameters([:], owner: p.owner + "." + key) }
    guard let mapping = value.object else { throw p.error("\(key) must be a mapping") }
    return NativeParameters(mapping, owner: p.owner + "." + key)
}

private func gradingRGBM(_ p: NativeParameters, _ key: String, defaultValue: Double) throws -> [Double] {
    let nested = try gradingNested(p, key)
    let rgb = try nested.vector("rgb", count: 3, defaultValue: Array(repeating: defaultValue, count: 3))
    return rgb + [try nested.number("master", defaultValue: defaultValue)]
}

private func gradingPrimary(_ p: NativeParameters, style: String, inverse: Bool) throws -> [String: GradingUniformValue] {
    let brightness = try gradingRGBM(p, "brightness", defaultValue: 0)
    let contrast = try gradingRGBM(p, "contrast", defaultValue: 1)
    let gamma = try gradingRGBM(p, "gamma", defaultValue: 1)
    let offset = try gradingRGBM(p, "offset", defaultValue: 0)
    let exposure = try gradingRGBM(p, "exposure", defaultValue: 0)
    let lift = try gradingRGBM(p, "lift", defaultValue: 0)
    let gain = try gradingRGBM(p, "gain", defaultValue: 1)
    let pivot = try gradingNested(p, "pivot"), clamp = try gradingNested(p, "clamp")
    let black = try pivot.number("black", defaultValue: 0), white = try pivot.number("white", defaultValue: 1)
    let pivotValue = try pivot.number("contrast", defaultValue: style == "log" ? -0.2 : 0.18)
    let clampBlack = try clamp.number("black", defaultValue: -Double.greatestFiniteMagnitude)
    let clampWhite = try clamp.number("white", defaultValue: Double.greatestFiniteMagnitude)
    let saturation = try p.number("saturation", defaultValue: 1)
    guard white - black >= 0.009999, clampBlack <= clampWhite else { throw p.error("invalid primary pivot or clamp interval") }
    if style != "video" && contrast.contains(where: { $0 < 0.009999 }) { throw p.error("primary contrast must be at least 0.01") }
    var result: [String: GradingUniformValue] = ["pivotBlack": .scalar(black), "pivotWhite": .scalar(white),
        "clampBlack": .scalar(clampBlack), "clampWhite": .scalar(clampWhite), "saturation": .scalar(saturation)]
    var bypass = saturation == 1 && clampBlack == -Double.greatestFiniteMagnitude && clampWhite == Double.greatestFiniteMagnitude
    func rounded(_ values: [Double]) -> [Double] { values.map { Double(Float($0)) } }
    if style == "log" {
        let b = rounded((0..<3).map { (brightness[3] + brightness[$0]) * 6.25 / 1023 * (inverse ? -1 : 1) })
        let c = rounded((0..<3).map { i in let value = contrast[3] * contrast[i]; return inverse ? 1 / (value == 0 ? 1 : value) : value })
        let g = rounded((0..<3).map { inverse ? gamma[3] * gamma[$0] : 1 / (gamma[3] * gamma[$0]) })
        result["brightness"] = .vector(b); result["contrast"] = .vector(c); result["gamma"] = .vector(g)
        result["pivot"] = .scalar(0.5 + pivotValue * 0.5)
        bypass = bypass && b.allSatisfy { $0 == 0 } && c.allSatisfy { $0 == 1 } && g.allSatisfy { $0 == 1 }
    } else if style == "lin" {
        let o = rounded((0..<3).map { (offset[3] + offset[$0]) * (inverse ? -1 : 1) })
        let e = (0..<3).map { i -> Double in let value = pow(Float(2), Float(exposure[3] + exposure[i])); return Double(inverse ? 1 / value : value) }
        let c = rounded((0..<3).map { inverse ? 1 / (contrast[3] * contrast[$0]) : contrast[3] * contrast[$0] })
        result["offset"] = .vector(o); result["exposure"] = .vector(e); result["contrast"] = .vector(c)
        result["pivot"] = .scalar(0.18 * pow(2, pivotValue))
        bypass = bypass && o.allSatisfy { $0 == 0 } && e.allSatisfy { $0 == 1 } && c.allSatisfy { $0 == 1 }
    } else {
        let o = rounded((0..<3).map { (offset[3] + offset[$0] + lift[3] + lift[$0]) * (inverse ? -1 : 1) })
        let s = rounded((0..<3).map { i -> Double in
            let g = gain[3] * gain[i]
            let den = white / (g == 0 ? 1 : g) + lift[3] + lift[i] - black
            return inverse ? den / (white - black) : (white - black) / (den == 0 ? 1 : den)
        })
        let g = rounded((0..<3).map { inverse ? gamma[3] * gamma[$0] : 1 / (gamma[3] * gamma[$0]) })
        result["offset"] = .vector(o); result["slope"] = .vector(s); result["gamma"] = .vector(g)
        bypass = bypass && o.allSatisfy { $0 == 0 } && s.allSatisfy { $0 == 1 } && g.allSatisfy { $0 == 1 }
    }
    result["localBypass"] = .boolean(bypass)
    return result
}

private func gradingTone(_ p: NativeParameters, style: String) throws -> [String: GradingUniformValue] {
    let names = ["blacks", "shadows", "midtones", "highlights", "whites"]
    let defaults: [[Double]]
    if style == "lin" { defaults = [[0,4],[2,-7],[0,8],[-2,9],[0,8]] }
    else if style == "video" { defaults = [[0.4,0.4],[0.6,0],[0.4,0.7],[0.2,1],[0.5,0.5]] }
    else { defaults = [[0.4,0.4],[0.5,0],[0.4,0.6],[0.3,1],[0.4,0.5]] }
    var controls: [[Double]] = [], result: [String: GradingUniformValue] = [:]
    for (index, name) in names.enumerated() {
        let nested = try gradingNested(p, name)
        let rgbm = try gradingRGBM(p, name, defaultValue: 1)
        let start = try nested.number(index == 2 ? "center" : "start", defaultValue: defaults[index][0])
        let width = try nested.number(index == 1 || index == 3 ? "pivot" : "width", defaultValue: defaults[index][1])
        let shadowHighlight = index == 1 || index == 3
        let lower = shadowHighlight ? 0.199999 : 0.099999, upper = shadowHighlight ? 1.800001 : 1.900001
        guard rgbm.allSatisfy({ $0 >= lower && $0 <= upper }) else { throw p.error("tone \(name) controls outside upstream valid bounds") }
        if index == 1 { guard start >= width + 0.009999 else { throw p.error("shadow start overlaps pivot") } }
        else if index == 3 { guard start <= width - 0.009999 else { throw p.error("highlight start overlaps pivot") } }
        else { guard width >= 0.009999 else { throw p.error("tone width must be at least 0.01") } }
        controls.append(rgbm + [start, width])
        for (channel, suffix) in ["R", "G", "B", "M"].enumerated() { result[name + suffix] = .scalar(rgbm[channel]) }
        result[name + "Start"] = .scalar(start); result[name + "Width"] = .scalar(width)
    }
    let contrast = try p.number("s_contrast", defaultValue: 1)
    guard contrast >= 0.009999 && contrast <= 1.990001 else { throw p.error("tone s_contrast outside [0.01, 1.99]") }
    let bypass = contrast == 1 && controls.allSatisfy { $0.prefix(4).allSatisfy { $0 == 1 } }
    result["sContrast"] = .scalar(contrast); result["localBypass"] = .boolean(bypass)
    if bypass {
        for name in ["blacks", "shadows", "highlights", "whites"] {
            result[name + "Start"] = .scalar(0); result[name + "Width"] = .scalar(0)
        }
    } else {
        let highlights = controls[3], whites = controls[4], shadows = controls[1], blacks = controls[0]
        let hStart = min(highlights[4], highlights[5] - 0.01), hPivot = highlights[5]
        let wStart = gradingToneRange(whites[4], x0: hStart, x2: hPivot, value: highlights[3], highlight: true)
        let wEnd = gradingToneRange(whites[4] + whites[5], x0: hStart, x2: hPivot, value: highlights[3], highlight: true)
        let sStart = max(shadows[4], shadows[5] + 0.01), sPivot = shadows[5]
        let bStart = gradingToneRange(blacks[4], x0: sPivot, x2: sStart, value: shadows[3], highlight: false)
        let bEnd = gradingToneRange(blacks[4] - blacks[5], x0: sPivot, x2: sStart, value: shadows[3], highlight: false)
        result["highlightsStart"] = .scalar(hStart); result["highlightsWidth"] = .scalar(hPivot)
        result["whitesStart"] = .scalar(wStart); result["whitesWidth"] = .scalar(wEnd - wStart)
        result["shadowsStart"] = .scalar(sStart); result["shadowsWidth"] = .scalar(sPivot)
        result["blacksStart"] = .scalar(bStart); result["blacksWidth"] = .scalar(bStart - bEnd)
    }
    return result
}

private func gradingToneRange(_ t: Double, x0: Double, x2: Double, value: Double, highlight: Bool) -> Double {
    let val = highlight ? 2 - value : value
    let slope = max(0.01, val <= 1 ? val : 2 - val)
    let m0 = highlight ? 1 : slope, m2 = highlight ? slope : 1
    let x1 = x0 + (x2 - x0) * 0.5, y0 = x0, y2 = x2
    let y1 = (0.5 / ((x2 - x1) + (x1 - x0))) * ((2*y0 + m0*(x1-x0))*(x2-x1) + (2*y2-m2*(x2-x1))*(x1-x0))
    if val <= 1 {
        let l = (t-x0)/(x1-x0), r = (t-x1)/(x2-x1)
        let fL = y0*(1-l*l)+y1*l*l+m0*(1-l)*l*(x1-x0)
        let fR = y1*(1-r)*(1-r)+y2*(2-r)*r+m2*(r-1)*r*(x2-x1)
        if t < x0 { return y0+(t-x0)*m0 }
        if t > x2 { return y2+(t-x2)*m2 }
        return t < x1 ? fL : fR
    }
    let cL = y0-t, bL = m0*(x1-x0), aL = y1-y0-m0*(x1-x0)
    let cR = y1-t, bR = 2*y2-2*y1-m2*(x2-x1), aR = y1-y2+m2*(x2-x1)
    let outL = (2*cL)/(-sqrt(bL*bL-4*aL*cL)-bL)*(x1-x0)+x0
    let outR = (2*cR)/(-sqrt(bR*bR-4*aR*cR)-bR)*(x2-x1)+x1
    if t < y0 { return x0+(t-y0)/m0 }
    if t > y2 { return x2+(t-y2)/m2 }
    return t < y1 ? outL : outR
}

private enum GradingSplineType: Equatable { case rgb, diagonal, hueHue, periodicOne, periodicZero, horizontalOne }
private struct GradingPoint { var x: Float; var y: Float }
private struct GradingSpline { var knots: [Float]; var a: [Float]; var b: [Float]; var c: [Float] }

private func gradingCurves(_ p: NativeParameters, style: String, hue: Bool) throws -> [String: GradingUniformValue] {
    let names = hue ? ["hue_hue", "hue_sat", "hue_lum", "lum_sat", "sat_sat", "lum_lum", "sat_lum", "hue_fx"] : ["red", "green", "blue", "master"]
    let types: [GradingSplineType] = hue ? [.hueHue,.periodicOne,.periodicOne,.horizontalOne,.diagonal,.diagonal,.horizontalOne,.periodicZero] : Array(repeating: .rgb, count: 4)
    let draw = try p.bool("draw_curve_only", defaultValue: false) && hue
    var knots: [Float] = [], coefficients: [Float] = [], knotsOffsets: [Double] = [], coefficientsOffsets: [Double] = []
    for (index, name) in names.enumerated() {
        let type = types[index]
        let diagonal = type == .rgb || type == .diagonal || type == .hueHue
        let periodic = type == .hueHue || type == .periodicOne || type == .periodicZero
        var points: [GradingPoint]
        var slopes: [Float]
        if let value = p.values[name] {
            guard let mapping = value.object else { throw p.error("curve \(name) must be a mapping") }
            let nested = NativeParameters(mapping, owner: p.owner + "." + name)
            guard let array = mapping["control_points"]?.array, array.count >= 4, array.count % 2 == 0 else { throw p.error("curve needs at least 2 control points") }
            let coordinates = try nested.vector("control_points", count: array.count, defaultValue: []).map(Float.init)
            points = stride(from: 0, to: coordinates.count, by: 2).map { GradingPoint(x: coordinates[$0], y: coordinates[$0 + 1]) }
            slopes = try nested.vector("slopes", count: points.count, defaultValue: Array(repeating: 0, count: points.count)).map(Float.init)
        } else {
            let xs: [Float] = periodic ? (0..<6).map { Float($0)/6 } : ((style == "lin" && (!hue || name.hasPrefix("lum_"))) ? [-7,0,7] : [0,0.5,1])
            points = xs.map { GradingPoint(x: $0, y: diagonal ? $0 : type == .periodicZero ? 0 : 1) }
            slopes = Array(repeating: 0, count: points.count)
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), slopes.allSatisfy(\.isFinite) else { throw p.error("curve coordinates overflow float32") }
        for i in 1..<points.count {
            guard points[i].x >= points[i-1].x else { throw p.error("curve x coordinates must not decrease") }
            if diagonal { guard points[i].y >= points[i-1].y else { throw p.error("diagonal curve y coordinates must not decrease") } }
        }
        if type == .hueHue {
            guard points[0].x >= 0 && points.last!.x <= 1 && points[0].y >= points.last!.y - 1 else { throw p.error("hue-hue coordinates violate cyclic monotonicity") }
        }
        if periodic && points.count == 2 && abs(1 - (points[1].x - points[0].x)) < 0.001 { throw p.error("periodic control points wrap to the same value") }
        let defaultSlopes = slopes.allSatisfy { $0 == 0 }
        let identity = defaultSlopes && points.allSatisfy { diagonal ? $0.x == $0.y : $0.y == (type == .periodicZero ? 0 : 1) }
        if identity && !draw { knotsOffsets += [-1,0]; coefficientsOffsets += [-1,0]; continue }
        let spline: GradingSpline
        if identity && draw {
            spline = GradingSpline(knots: [0,1], a: [0], b: [diagonal ? 1 : 0], c: [type == .periodicOne || type == .horizontalOne ? 1 : 0])
        } else if !hue {
            if defaultSlopes { slopes = gradingEstimateSlopes(points, horizontal: false, periodic: false, hue: false) }
            var fitted = gradingFit(points, slopes: slopes, hue: false)
            if gradingAdjustRGB(points, slopes: &slopes, knots: fitted.knots) { fitted = gradingFit(points, slopes: slopes, hue: false) }
            spline = fitted
        } else {
            points = gradingPrepareHue(points, periodic: periodic, horizontal: !diagonal)
            if defaultSlopes { slopes = gradingEstimateSlopes(points, horizontal: type != .diagonal, periodic: periodic, hue: true) }
            else if periodic { let last = slopes.last!; slopes.insert(last, at: 0); slopes.append(slopes[0]) }
            spline = gradingFit(points, slopes: slopes, hue: true)
        }
        guard knots.count + spline.knots.count <= 120 && coefficients.count + spline.a.count * 3 <= 360 else { throw p.error("maximum upstream grading curve knots/coefficients reached") }
        knotsOffsets += [Double(knots.count), Double(spline.knots.count)]
        coefficientsOffsets += [Double(coefficients.count), Double(spline.a.count * 3)]
        knots += spline.knots; coefficients += spline.a + spline.b + spline.c
    }
    return ["knotsOffsets": .vector(knotsOffsets), "knots": .vector(knots.map(Double.init)),
            "coefsOffsets": .vector(coefficientsOffsets), "coefs": .vector(coefficients.map(Double.init)),
            "localBypass": .boolean(knots.isEmpty)]
}

private func gradingPrepareHue(_ original: [GradingPoint], periodic: Bool, horizontal: Bool) -> [GradingPoint] {
    var points = original.map { point -> GradingPoint in
        var p = point
        if periodic && p.x < 0 { p.x += 1; if !horizontal { p.y += 1 } }
        else if periodic && p.x >= 1 { p.x -= 1; if !horizontal { p.y -= 1 } }
        return p
    }
    // Selection sort matches upstream, including duplicate-coordinate ordering.
    for i in points.indices {
        var selected = i
        for j in (i + 1)..<points.count { if points[j].x < points[selected].x { selected = j } }
        points.swapAt(i, selected)
    }
    let xSpan = points.last!.x - points[0].x, ySpan = points.last!.y - points[0].y
    for i in 1..<points.count {
        if points[i].x - points[i-1].x < xSpan * 0.002 { points[i].x = points[i-1].x + xSpan * 0.002 }
        if !horizontal && points[i].y - points[i-1].y < ySpan * 0.002 { points[i].y = points[i-1].y + ySpan * 0.002 }
    }
    if periodic {
        var first = points.last!, last = points[0]
        first.x -= 1; last.x += 1
        if !horizontal { first.y -= 1; last.y += 1 }
        points.insert(first, at: 0); points.append(last)
    }
    return points
}

private func gradingEstimateSlopes(_ p: [GradingPoint], horizontal: Bool, periodic: Bool, hue: Bool) -> [Float] {
    let count = p.count
    var secants: [Float] = [], lengths: [Float] = []
    for i in 0..<(count-1) {
        let dx = p[i+1].x-p[i].x, dy = p[i+1].y-p[i].y
        secants.append(dy/dx); lengths.append(sqrt(dx*dx+dy*dy))
    }
    if count == 2 { return [secants[0], secants[0]] }
    var slopes: [Float] = [0]
    if horizontal && hue {
        for i in 1..<(count-1) {
            let den = secants[i]+secants[i-1]
            var slope = 2*secants[i]*secants[i-1] / (abs(den) < 0.001 ? (den < 0 ? -0.001 : 0.001) : den)
            if secants[i]*secants[i-1] <= 0 { slope = 0 }
            slopes.append(slope)
        }
        slopes.append(0.5*(3*secants[count-2]-slopes[count-2]))
        slopes[0] = 0.5*(3*secants[0]-slopes[1])
    } else {
        var i = 0
        while true {
            var j = i, length = lengths[i]
            while j < count-2 && abs(secants[j+1]-secants[j]) < 0.000001 { length += lengths[j+1]; j += 1 }
            for k in i...j { lengths[k] = length }
            if j >= count-3 { break }
            i = j+1
        }
        for k in 1..<(count-1) { slopes.append((lengths[k]*secants[k]+lengths[k-1]*secants[k-1])/(lengths[k]+lengths[k-1])) }
        slopes.append(max(0.01,0.5*(3*secants[count-2]-slopes[count-2])))
        slopes[0] = max(0.01,0.5*(3*secants[0]-slopes[1]))
    }
    if hue {
        for i in 0..<(count-1) {
            let k: Float = abs(slopes[i]) > abs(slopes[i+1]) ? 0.8 : 0.2
            let near = slopes[i]+k*(slopes[i+1]-slopes[i])
            let scale: Float = near == 0 ? 1 : 0.75*2*secants[i]/near
            if scale < 1 { slopes[i] *= scale; slopes[i+1] *= scale }
        }
        if periodic { slopes[0] = slopes[count-2]; slopes[count-1] = slopes[1] }
    }
    return slopes
}

private func gradingHueMiddle(_ p0: GradingPoint, _ p1: GradingPoint, m0 original0: Float, m1 original1: Float) -> Float {
    let dx = p1.x-p0.x, rawSecant = (p1.y-p0.y)/dx
    let m0 = rawSecant < 0 ? -original0 : original0, m1 = rawSecant < 0 ? -original1 : original1
    let secant = abs(rawSecant), midpoint = p0.x+0.5*dx
    let left = p0.x+dx*0.2, right = p1.x-dx*0.2
    var top = m0 > m1 ? right : left, bottom = m0 > m1 ? left : right
    let minimum = min(m0,m1), maximum = max(m0,m1), delta = maximum-minimum
    let high = minimum+0.9*delta, low = minimum+(1-Float(0.9))*delta
    let big = maximum*4, small = maximum*1.1
    let alpha = max(0,min((delta/max(0.01,maximum)-0.05)/(0.75-0.05),1))
    top = midpoint+alpha*(top-midpoint); bottom = midpoint+alpha*(bottom-midpoint)
    if secant >= big { return midpoint }
    if secant > small { return top+(secant-small)/(big-small)*(midpoint-top) }
    if secant >= high { return top }
    if secant > low && high != low { return bottom+(secant-low)/(high-low)*(top-bottom) }
    return bottom
}

private func gradingFit(_ p: [GradingPoint], slopes: [Float], hue: Bool) -> GradingSpline {
    var result = GradingSpline(knots: [p[0].x], a: [], b: [], c: [])
    for i in 0..<(p.count-1) {
        let x = p[i].x, nextX = p[i+1].x, y = p[i].y, dx = nextX-x
        let secant = (p[i+1].y-y)/dx
        let difference = abs(slopes[i]+slopes[i+1]-2*secant)
        if hue ? difference <= 0.00001 : difference < 0.000001 {
            result.c.append(y); result.b.append(slopes[i]); result.a.append(0.5*(slopes[i+1]-slopes[i])/dx)
        } else {
            let middle: Float
            if hue { middle = gradingHueMiddle(p[i],p[i+1],m0:slopes[i],m1:slopes[i+1]) }
            else {
                let aa = slopes[i]-secant, bb = slopes[i+1]-secant
                if aa*bb >= 0 { middle = (x+nextX)*0.5 }
                else if abs(aa) > abs(bb) { middle = nextX+aa*dx/(slopes[i+1]-slopes[i]) }
                else { middle = x+bb*dx/(slopes[i+1]-slopes[i]) }
            }
            let mean = (2*secant-slopes[i+1])+(slopes[i+1]-slopes[i])*(middle-x)/dx
            let eta = (mean-slopes[i])/(middle-x)
            result.c += [y, y+slopes[i]*(middle-x)+0.5*eta*(middle-x)*(middle-x)]
            result.b += [slopes[i],mean]
            result.a += [0.5*eta,0.5*(slopes[i+1]-mean)/(nextX-middle)]
            result.knots.append(middle)
        }
        result.knots.append(nextX)
    }
    return result
}

private func gradingAdjustRGB(_ p: [GradingPoint], slopes: inout [Float], knots: [Float]) -> Bool {
    var adjusted = false, i = 0
    for knot in knots {
        if p[i].x != knot {
            let x = p[i].x, nextX = p[i+1].x, y = p[i].y, nextY = p[i+1].y
            let mean = (2*(nextY-y)-(knot-x)*slopes[i]-(nextX-knot)*slopes[i+1])/(nextX-x)
            if mean < 0 {
                adjusted = true
                let secant = (nextY-y)/(nextX-x)
                let blend = ((knot-x)*slopes[i]+(nextX-knot)*slopes[i+1])/(nextX-x)
                let target = min(0.01*0.5*(slopes[i]+slopes[i+1]),secant)
                let factor = (2*secant-target)/blend
                slopes[i] *= factor; slopes[i+1] *= factor
            }
            i += 1
        }
    }
    return adjusted
}

extension CTFFile {
    static func gradingXML(_ node: NativeXMLNode) throws -> OCIOConfigTransform {
        let text = (node.attributes["style"] ?? "log").lowercased()
        let inverse = text.hasSuffix("rev")
        let basic = inverse ? String(text.dropLast(3)) : text
        let style = basic == "linear" ? "lin" : basic
        guard ["log", "lin", "video"].contains(style) else { throw error(node, "invalid grading style") }
        var fields: [String: YAMLValue] = ["style": .scalar(style)]
        if let bypass = node.attributes["bypassLinToLog"] { fields["lintolog_bypass"] = .scalar(bypass) }
        let curves = ["Red": "red", "Green": "green", "Blue": "blue", "Master": "master",
                      "HueHue": "hue_hue", "HueSat": "hue_sat", "HueLum": "hue_lum", "LumSat": "lum_sat",
                      "SatSat": "sat_sat", "LumLum": "lum_lum", "SatLum": "sat_lum", "HueFx": "hue_fx"]
        let controls = ["Brightness", "Contrast", "Gamma", "Offset", "Exposure", "Lift", "Gain",
                        "Blacks", "Shadows", "Midtones", "Highlights", "Whites", "Pivot", "Clamp"]
        for child in node.children {
            if ["Description", "DynamicParameter"].contains(child.name) { continue }
            if let key = curves[child.name] {
                var curve: [String: YAMLValue] = [:]
                for data in child.children {
                    let key: String
                    switch data.name {
                    case "ControlPoints": key = "control_points"
                    case "Slopes": key = "slopes"
                    default: throw error(data, "unknown grading curve element")
                    }
                    curve[key] = vector(try floats(data.text.replacingOccurrences(of: ",", with: " ")))
                }
                fields[key] = .mapping(curve)
            } else if controls.contains(child.name) {
                var control: [String: YAMLValue] = [:]
                for (key, value) in child.attributes {
                    if key == "rgb" { control[key] = vector(try floats(value.replacingOccurrences(of: ",", with: " "))) }
                    else { control[key] = .scalar(value) }
                }
                fields[child.name.lowercased()] = .mapping(control)
            } else if child.name == "Saturation" || child.name == "SContrast" {
                guard let master = child.attributes["master"] else { throw error(child, "missing master value") }
                fields[child.name == "Saturation" ? "saturation" : "s_contrast"] = .scalar(master)
            } else { throw error(child, "unknown grading element") }
        }
        return try transform(node.name + "Transform", fields: fields, inverse: inverse)
    }
}

// BEGIN GENERATED GRADING MSL TEMPLATES
// Generated using OpenColorIO 2.5.2; regenerate with the pinned oracle.
private func gradingShaderTemplate(_ key: String) -> GradingShaderTemplate? {
    switch key {
    case "hue.lin.forward":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve forward processing
  
  {
    if (!ocio_grading_huecurve_localBypass)
    {
      {
          
          // Add FixedFunction 'RGB_TO_HSY_LIN' processing
          
          {
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float luma = dot(outColor.rgb, lumaWeights);
            float minRGB =  min( outColor.x, min( outColor.y, outColor.z ) );
            float maxRGB =  max( outColor.x, max( outColor.y, outColor.z ) );
            float3 RGBm = outColor.rgb - luma;
            float distRGB  = dot( abs(RGBm), ones );
            float sumRGB  = dot( outColor.rgb, ones );
            float sat_hi  = distRGB / max(0.07 * distRGB + 1e-6, 0.15 + sumRGB);
            float sat_lo  = distRGB * 5.;
            float alpha  = clamp( (luma - 0.001) / (0.01 - 0.001), 0., 1.);
            float sat = sat_lo + alpha * (sat_hi - sat_lo);
            sat *= 1.4;
            float hue = 0.0;
            if (minRGB != maxRGB) {
               float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
               if ( maxRGB == outColor.r ) hue = 1.0 + (outColor.g - outColor.b) * OneOverMaxMinusMin;
               else if ( maxRGB == outColor.g ) hue = 3.0 + (outColor.b - outColor.r) * OneOverMaxMinusMin;
               else hue = 5.0 + (outColor.r - outColor.g) * OneOverMaxMinusMin;
            }
            outColor.r = hue * 1./6.; outColor.g = sat; outColor.b = luma;
          }
      }
      // Convert from lin to log.
      {
        const float xbrk = 0.0041318374739483946;
        const float shift = -0.000157849851665374;
        const float m = 1. / (0.18 + shift);
        const float base2 = 1.4426950408889634;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 ylin = outColor.rgb * gain + offs;
        float3 ylog = base2 * log( ( outColor.rgb + shift ) * m );
        outColor.rgb.b = (outColor.rgb.b < xbrk) ? ylin.z : ylog.z;
      }
      
      
      float hueSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.));
      float hueLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(2, outColor.r, 1.));
      outColor.r = ocio_grading_huecurve_evalBSplineCurve(0, outColor.r, outColor.r);
      outColor.g = max(0., ocio_grading_huecurve_evalBSplineCurve(4, outColor.g, outColor.g));
      float lumSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(3, outColor.b, 1.));
      float satGain = lumSatGain * hueSatGain;
      outColor.g = satGain * outColor.g;
      float satLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(6, outColor.g, 1.));
      outColor.b = ocio_grading_huecurve_evalBSplineCurve(5, outColor.b, outColor.b);
      
      
      // Convert from log to lin.
      {
        const float ybrk = -5.5;
        const float shift = -0.000157849851665374;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 xlin = (outColor.rgb - offs) / gain;
        float3 xlog = pow( float3(2., 2., 2.), outColor.rgb ) * (0.18 + shift) - shift;
        outColor.rgb.b = (outColor.rgb.b < ybrk) ? xlin.z : xlog.z;
      }
      
      hueLumGain = 1. - (1. - hueLumGain) * min( 1., outColor.g );
      outColor.b = outColor.b * hueLumGain * satLumGain;
      
      outColor.r = outColor.r - floor( outColor.r );
      outColor.r = outColor.r + ocio_grading_huecurve_evalBSplineCurve(7, outColor.r, 0.);
      {
          
          // Add FixedFunction 'HSY_LIN_TO_RGB' processing
          
          {
            float luma = outColor.z;
            float Hue = outColor.x - 1./6.;
            Hue = (luma < 0.) ? Hue + 0.5 : Hue;
            Hue = ( Hue - floor( Hue ) ) * 6.0;
            float R = abs(Hue - 3.0) - 1.0;
            float G = 2.0 - abs(Hue - 2.0);
            float B = 2.0 - abs(Hue - 4.0);
            float3 RGB0 = float3(R, G, B);
            RGB0 = clamp( RGB0, 0., 1. );
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float currY = dot(RGB0, lumaWeights);
            RGB0 *= luma / currY;
            float sat = outColor.y;
            float distRGB = dot( abs(RGB0 - luma), ones );
            float sumRGB  = dot( RGB0, ones );
            float k = 0.15;
            float lo_gain = 5.;
            sat /= 1.4;
            float tmp = -sat * sumRGB + sat * 3. * luma + distRGB;
            tmp = max(1e-6, tmp);
            float s1 = sat * (k + 3. * luma) / tmp;
            s1 = min(s1, 50.);
            float s0 = sat / max(1e-10, distRGB * lo_gain);
            float alpha  = clamp( (luma - 0.001) / (0.01 - 0.001), 0., 1.);
            float a = distRGB * lo_gain * (1. - alpha) * (sumRGB - 3. * luma);
            float b = distRGB * lo_gain * (1. - alpha) * (k + 3. * luma) + distRGB * alpha - sat * (sumRGB - 3. * luma);
            float c = -sat * (k + 3. * luma);
            float discrim = sqrt( b * b - 4. * a * c );
            float denom = -discrim - b;
            float sm = (2. * c) / denom;
            sm = (sm >= 0.) ? sm : (2. * c) / (denom + discrim * 2.);
            float gainS = (alpha == 1.) ? s1 : (alpha == 0.) ? s0 : sm;
            outColor.rgb = luma + gainS * (RGB0 - luma);
          }
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.lin.forward.draw":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve forward processing
  
  {
    outColor.r = ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.);
    outColor.g = ocio_grading_huecurve_evalBSplineCurve(1, outColor.g, 1.);
    outColor.b = ocio_grading_huecurve_evalBSplineCurve(1, outColor.b, 1.);
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.lin.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

float ocio_grading_huecurve_evalBSplineCurveRev(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

float ocio_grading_huecurve_evalBSplineCurveRevHue(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
    knEndY = (curveIdx == 7) ? knEndY + knEnd : knEndY;
  }
  if (x < knStartY)
  {
    x = x + ceil(knStartY - x);
  }
  else if (x > knEndY)
  {
    x = x - ceil(x - knEndY);
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    float curve_x = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1];
    curve_x = (curveIdx == 7) ? curve_x + ocio_grading_huecurve_knots[knotsOffs + i + 1] : curve_x;
    if (x < curve_x)
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  if (curveIdx == 7)
  {
    C = C + kn;
    B = B + 1.;
  }
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve inverse processing
  
  {
    if (!ocio_grading_huecurve_localBypass)
    {
      {
          
          // Add FixedFunction 'RGB_TO_HSY_LIN' processing
          
          {
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float luma = dot(outColor.rgb, lumaWeights);
            float minRGB =  min( outColor.x, min( outColor.y, outColor.z ) );
            float maxRGB =  max( outColor.x, max( outColor.y, outColor.z ) );
            float3 RGBm = outColor.rgb - luma;
            float distRGB  = dot( abs(RGBm), ones );
            float sumRGB  = dot( outColor.rgb, ones );
            float sat_hi  = distRGB / max(0.07 * distRGB + 1e-6, 0.15 + sumRGB);
            float sat_lo  = distRGB * 5.;
            float alpha  = clamp( (luma - 0.001) / (0.01 - 0.001), 0., 1.);
            float sat = sat_lo + alpha * (sat_hi - sat_lo);
            sat *= 1.4;
            float hue = 0.0;
            if (minRGB != maxRGB) {
               float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
               if ( maxRGB == outColor.r ) hue = 1.0 + (outColor.g - outColor.b) * OneOverMaxMinusMin;
               else if ( maxRGB == outColor.g ) hue = 3.0 + (outColor.b - outColor.r) * OneOverMaxMinusMin;
               else hue = 5.0 + (outColor.r - outColor.g) * OneOverMaxMinusMin;
            }
            outColor.r = hue * 1./6.; outColor.g = sat; outColor.b = luma;
          }
      }
      outColor.r = ocio_grading_huecurve_evalBSplineCurveRevHue(7, outColor.r);
      outColor.r = ocio_grading_huecurve_evalBSplineCurveRevHue(0, outColor.r);
      
      outColor.r = outColor.r - floor( outColor.r );
      float hueSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.));
      float hueLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(2, outColor.r, 1.));
      outColor.g = max(0., outColor.g);
      float satLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(6, outColor.g, 1.));
      
      hueLumGain = 1. - (1. - hueLumGain) * min( 1., outColor.g );
      outColor.b = outColor.b / max(0.01, hueLumGain * satLumGain);
      
      // Convert from lin to log.
      {
        const float xbrk = 0.0041318374739483946;
        const float shift = -0.000157849851665374;
        const float m = 1. / (0.18 + shift);
        const float base2 = 1.4426950408889634;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 ylin = outColor.rgb * gain + offs;
        float3 ylog = base2 * log( ( outColor.rgb + shift ) * m );
        outColor.rgb.b = (outColor.rgb.b < xbrk) ? ylin.z : ylog.z;
      }
      
      outColor.b = ocio_grading_huecurve_evalBSplineCurveRev(5, outColor.b);
      
      float lumSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(3, outColor.b, 1.));
      
      // Convert from log to lin.
      {
        const float ybrk = -5.5;
        const float shift = -0.000157849851665374;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 xlin = (outColor.rgb - offs) / gain;
        float3 xlog = pow( float3(2., 2., 2.), outColor.rgb ) * (0.18 + shift) - shift;
        outColor.rgb.b = (outColor.rgb.b < ybrk) ? xlin.z : xlog.z;
      }
      float satGain = max(0.01, lumSatGain * hueSatGain);
      outColor.g = outColor.g / satGain;
      outColor.g = max(0., ocio_grading_huecurve_evalBSplineCurveRev(4, outColor.g));
      {
          
          // Add FixedFunction 'HSY_LIN_TO_RGB' processing
          
          {
            float luma = outColor.z;
            float Hue = outColor.x - 1./6.;
            Hue = (luma < 0.) ? Hue + 0.5 : Hue;
            Hue = ( Hue - floor( Hue ) ) * 6.0;
            float R = abs(Hue - 3.0) - 1.0;
            float G = 2.0 - abs(Hue - 2.0);
            float B = 2.0 - abs(Hue - 4.0);
            float3 RGB0 = float3(R, G, B);
            RGB0 = clamp( RGB0, 0., 1. );
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float currY = dot(RGB0, lumaWeights);
            RGB0 *= luma / currY;
            float sat = outColor.y;
            float distRGB = dot( abs(RGB0 - luma), ones );
            float sumRGB  = dot( RGB0, ones );
            float k = 0.15;
            float lo_gain = 5.;
            sat /= 1.4;
            float tmp = -sat * sumRGB + sat * 3. * luma + distRGB;
            tmp = max(1e-6, tmp);
            float s1 = sat * (k + 3. * luma) / tmp;
            s1 = min(s1, 50.);
            float s0 = sat / max(1e-10, distRGB * lo_gain);
            float alpha  = clamp( (luma - 0.001) / (0.01 - 0.001), 0., 1.);
            float a = distRGB * lo_gain * (1. - alpha) * (sumRGB - 3. * luma);
            float b = distRGB * lo_gain * (1. - alpha) * (k + 3. * luma) + distRGB * alpha - sat * (sumRGB - 3. * luma);
            float c = -sat * (k + 3. * luma);
            float discrim = sqrt( b * b - 4. * a * c );
            float denom = -discrim - b;
            float sm = (2. * c) / denom;
            sm = (sm >= 0.) ? sm : (2. * c) / (denom + discrim * 2.);
            float gainS = (alpha == 1.) ? s1 : (alpha == 0.) ? s0 : sm;
            outColor.rgb = luma + gainS * (RGB0 - luma);
          }
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.lin.inverse.draw":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

float ocio_grading_huecurve_evalBSplineCurveRev(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

float ocio_grading_huecurve_evalBSplineCurveRevHue(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
    knEndY = (curveIdx == 7) ? knEndY + knEnd : knEndY;
  }
  if (x < knStartY)
  {
    x = x + ceil(knStartY - x);
  }
  else if (x > knEndY)
  {
    x = x - ceil(x - knEndY);
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    float curve_x = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1];
    curve_x = (curveIdx == 7) ? curve_x + ocio_grading_huecurve_knots[knotsOffs + i + 1] : curve_x;
    if (x < curve_x)
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  if (curveIdx == 7)
  {
    C = C + kn;
    B = B + 1.;
  }
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve inverse processing
  
  {
    outColor.r = ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.);
    outColor.g = ocio_grading_huecurve_evalBSplineCurve(1, outColor.g, 1.);
    outColor.b = ocio_grading_huecurve_evalBSplineCurve(1, outColor.b, 1.);
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.log.forward":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve forward processing
  
  {
    if (!ocio_grading_huecurve_localBypass)
    {
      {
          
          // Add FixedFunction 'RGB_TO_HSY_LOG' processing
          
          {
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float luma = dot(outColor.rgb, lumaWeights);
            float minRGB =  min( outColor.x, min( outColor.y, outColor.z ) );
            float maxRGB =  max( outColor.x, max( outColor.y, outColor.z ) );
            float3 RGBm = outColor.rgb - luma;
            float distRGB  = dot( abs(RGBm), ones );
            float sat = distRGB * 4.;
            float hue = 0.0;
            if (minRGB != maxRGB) {
               float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
               if ( maxRGB == outColor.r ) hue = 1.0 + (outColor.g - outColor.b) * OneOverMaxMinusMin;
               else if ( maxRGB == outColor.g ) hue = 3.0 + (outColor.b - outColor.r) * OneOverMaxMinusMin;
               else hue = 5.0 + (outColor.r - outColor.g) * OneOverMaxMinusMin;
            }
            outColor.r = hue * 1./6.; outColor.g = sat; outColor.b = luma;
          }
      }
      
      float hueSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.));
      float hueLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(2, outColor.r, 1.));
      outColor.r = ocio_grading_huecurve_evalBSplineCurve(0, outColor.r, outColor.r);
      outColor.g = max(0., ocio_grading_huecurve_evalBSplineCurve(4, outColor.g, outColor.g));
      float lumSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(3, outColor.b, 1.));
      float satGain = lumSatGain * hueSatGain;
      outColor.g = satGain * outColor.g;
      float satLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(6, outColor.g, 1.));
      outColor.b = ocio_grading_huecurve_evalBSplineCurve(5, outColor.b, outColor.b);
      
      
      hueLumGain = 1. - (1. - hueLumGain) * min( 1., outColor.g );
      outColor.b = outColor.b + (hueLumGain + satLumGain - 2.) * 0.1;
      
      outColor.r = outColor.r - floor( outColor.r );
      outColor.r = outColor.r + ocio_grading_huecurve_evalBSplineCurve(7, outColor.r, 0.);
      {
          
          // Add FixedFunction 'HSY_LOG_TO_RGB' processing
          
          {
            float luma = outColor.z;
            float Hue = outColor.x - 1./6.;
            Hue = (luma < 0.) ? Hue + 0.5 : Hue;
            Hue = ( Hue - floor( Hue ) ) * 6.0;
            float R = abs(Hue - 3.0) - 1.0;
            float G = 2.0 - abs(Hue - 2.0);
            float B = 2.0 - abs(Hue - 4.0);
            float3 RGB0 = float3(R, G, B);
            RGB0 = clamp( RGB0, 0., 1. );
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float currY = dot(RGB0, lumaWeights);
            RGB0 *= luma / currY;
            float sat = outColor.y;
            float distRGB = dot( abs(RGB0 - luma), ones );
            float gainS = sat / max(1e-10, distRGB * 4.);
            outColor.rgb = luma + gainS * (RGB0 - luma);
          }
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.log.forward.draw":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve forward processing
  
  {
    outColor.r = ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.);
    outColor.g = ocio_grading_huecurve_evalBSplineCurve(1, outColor.g, 1.);
    outColor.b = ocio_grading_huecurve_evalBSplineCurve(1, outColor.b, 1.);
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.log.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

float ocio_grading_huecurve_evalBSplineCurveRev(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

float ocio_grading_huecurve_evalBSplineCurveRevHue(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
    knEndY = (curveIdx == 7) ? knEndY + knEnd : knEndY;
  }
  if (x < knStartY)
  {
    x = x + ceil(knStartY - x);
  }
  else if (x > knEndY)
  {
    x = x - ceil(x - knEndY);
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    float curve_x = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1];
    curve_x = (curveIdx == 7) ? curve_x + ocio_grading_huecurve_knots[knotsOffs + i + 1] : curve_x;
    if (x < curve_x)
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  if (curveIdx == 7)
  {
    C = C + kn;
    B = B + 1.;
  }
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve inverse processing
  
  {
    if (!ocio_grading_huecurve_localBypass)
    {
      {
          
          // Add FixedFunction 'RGB_TO_HSY_LOG' processing
          
          {
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float luma = dot(outColor.rgb, lumaWeights);
            float minRGB =  min( outColor.x, min( outColor.y, outColor.z ) );
            float maxRGB =  max( outColor.x, max( outColor.y, outColor.z ) );
            float3 RGBm = outColor.rgb - luma;
            float distRGB  = dot( abs(RGBm), ones );
            float sat = distRGB * 4.;
            float hue = 0.0;
            if (minRGB != maxRGB) {
               float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
               if ( maxRGB == outColor.r ) hue = 1.0 + (outColor.g - outColor.b) * OneOverMaxMinusMin;
               else if ( maxRGB == outColor.g ) hue = 3.0 + (outColor.b - outColor.r) * OneOverMaxMinusMin;
               else hue = 5.0 + (outColor.r - outColor.g) * OneOverMaxMinusMin;
            }
            outColor.r = hue * 1./6.; outColor.g = sat; outColor.b = luma;
          }
      }
      outColor.r = ocio_grading_huecurve_evalBSplineCurveRevHue(7, outColor.r);
      outColor.r = ocio_grading_huecurve_evalBSplineCurveRevHue(0, outColor.r);
      
      outColor.r = outColor.r - floor( outColor.r );
      float hueSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.));
      float hueLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(2, outColor.r, 1.));
      outColor.g = max(0., outColor.g);
      float satLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(6, outColor.g, 1.));
      
      hueLumGain = 1. - (1. - hueLumGain) * min( 1., outColor.g );
      outColor.b = outColor.b - (hueLumGain + satLumGain - 2.) * 0.1;
      
      outColor.b = ocio_grading_huecurve_evalBSplineCurveRev(5, outColor.b);
      
      float lumSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(3, outColor.b, 1.));
      float satGain = max(0.01, lumSatGain * hueSatGain);
      outColor.g = outColor.g / satGain;
      outColor.g = max(0., ocio_grading_huecurve_evalBSplineCurveRev(4, outColor.g));
      {
          
          // Add FixedFunction 'HSY_LOG_TO_RGB' processing
          
          {
            float luma = outColor.z;
            float Hue = outColor.x - 1./6.;
            Hue = (luma < 0.) ? Hue + 0.5 : Hue;
            Hue = ( Hue - floor( Hue ) ) * 6.0;
            float R = abs(Hue - 3.0) - 1.0;
            float G = 2.0 - abs(Hue - 2.0);
            float B = 2.0 - abs(Hue - 4.0);
            float3 RGB0 = float3(R, G, B);
            RGB0 = clamp( RGB0, 0., 1. );
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float currY = dot(RGB0, lumaWeights);
            RGB0 *= luma / currY;
            float sat = outColor.y;
            float distRGB = dot( abs(RGB0 - luma), ones );
            float gainS = sat / max(1e-10, distRGB * 4.);
            outColor.rgb = luma + gainS * (RGB0 - luma);
          }
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.log.inverse.draw":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

float ocio_grading_huecurve_evalBSplineCurveRev(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

float ocio_grading_huecurve_evalBSplineCurveRevHue(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
    knEndY = (curveIdx == 7) ? knEndY + knEnd : knEndY;
  }
  if (x < knStartY)
  {
    x = x + ceil(knStartY - x);
  }
  else if (x > knEndY)
  {
    x = x - ceil(x - knEndY);
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    float curve_x = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1];
    curve_x = (curveIdx == 7) ? curve_x + ocio_grading_huecurve_knots[knotsOffs + i + 1] : curve_x;
    if (x < curve_x)
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  if (curveIdx == 7)
  {
    C = C + kn;
    B = B + 1.;
  }
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve inverse processing
  
  {
    outColor.r = ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.);
    outColor.g = ocio_grading_huecurve_evalBSplineCurve(1, outColor.g, 1.);
    outColor.b = ocio_grading_huecurve_evalBSplineCurve(1, outColor.b, 1.);
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.video.forward":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve forward processing
  
  {
    if (!ocio_grading_huecurve_localBypass)
    {
      {
          
          // Add FixedFunction 'RGB_TO_HSY_VID' processing
          
          {
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float luma = dot(outColor.rgb, lumaWeights);
            float minRGB =  min( outColor.x, min( outColor.y, outColor.z ) );
            float maxRGB =  max( outColor.x, max( outColor.y, outColor.z ) );
            float3 RGBm = outColor.rgb - luma;
            float distRGB  = dot( abs(RGBm), ones );
            float sat = distRGB * 1.25;
            float hue = 0.0;
            if (minRGB != maxRGB) {
               float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
               if ( maxRGB == outColor.r ) hue = 1.0 + (outColor.g - outColor.b) * OneOverMaxMinusMin;
               else if ( maxRGB == outColor.g ) hue = 3.0 + (outColor.b - outColor.r) * OneOverMaxMinusMin;
               else hue = 5.0 + (outColor.r - outColor.g) * OneOverMaxMinusMin;
            }
            outColor.r = hue * 1./6.; outColor.g = sat; outColor.b = luma;
          }
      }
      
      float hueSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.));
      float hueLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(2, outColor.r, 1.));
      outColor.r = ocio_grading_huecurve_evalBSplineCurve(0, outColor.r, outColor.r);
      outColor.g = max(0., ocio_grading_huecurve_evalBSplineCurve(4, outColor.g, outColor.g));
      float lumSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(3, outColor.b, 1.));
      float satGain = lumSatGain * hueSatGain;
      outColor.g = satGain * outColor.g;
      float satLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(6, outColor.g, 1.));
      outColor.b = ocio_grading_huecurve_evalBSplineCurve(5, outColor.b, outColor.b);
      
      
      hueLumGain = 1. - (1. - hueLumGain) * min( 1., outColor.g );
      outColor.b = outColor.b * hueLumGain * satLumGain;
      
      outColor.r = outColor.r - floor( outColor.r );
      outColor.r = outColor.r + ocio_grading_huecurve_evalBSplineCurve(7, outColor.r, 0.);
      {
          
          // Add FixedFunction 'HSY_VID_TO_RGB' processing
          
          {
            float luma = outColor.z;
            float Hue = outColor.x - 1./6.;
            Hue = (luma < 0.) ? Hue + 0.5 : Hue;
            Hue = ( Hue - floor( Hue ) ) * 6.0;
            float R = abs(Hue - 3.0) - 1.0;
            float G = 2.0 - abs(Hue - 2.0);
            float B = 2.0 - abs(Hue - 4.0);
            float3 RGB0 = float3(R, G, B);
            RGB0 = clamp( RGB0, 0., 1. );
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float currY = dot(RGB0, lumaWeights);
            RGB0 *= luma / currY;
            float sat = outColor.y;
            float distRGB = dot( abs(RGB0 - luma), ones );
            float gainS = sat / max(1e-10, distRGB * 1.25);
            outColor.rgb = luma + gainS * (RGB0 - luma);
          }
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.video.forward.draw":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve forward processing
  
  {
    outColor.r = ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.);
    outColor.g = ocio_grading_huecurve_evalBSplineCurve(1, outColor.g, 1.);
    outColor.b = ocio_grading_huecurve_evalBSplineCurve(1, outColor.b, 1.);
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.video.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

float ocio_grading_huecurve_evalBSplineCurveRev(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

float ocio_grading_huecurve_evalBSplineCurveRevHue(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
    knEndY = (curveIdx == 7) ? knEndY + knEnd : knEndY;
  }
  if (x < knStartY)
  {
    x = x + ceil(knStartY - x);
  }
  else if (x > knEndY)
  {
    x = x - ceil(x - knEndY);
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    float curve_x = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1];
    curve_x = (curveIdx == 7) ? curve_x + ocio_grading_huecurve_knots[knotsOffs + i + 1] : curve_x;
    if (x < curve_x)
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  if (curveIdx == 7)
  {
    C = C + kn;
    B = B + 1.;
  }
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve inverse processing
  
  {
    if (!ocio_grading_huecurve_localBypass)
    {
      {
          
          // Add FixedFunction 'RGB_TO_HSY_VID' processing
          
          {
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float luma = dot(outColor.rgb, lumaWeights);
            float minRGB =  min( outColor.x, min( outColor.y, outColor.z ) );
            float maxRGB =  max( outColor.x, max( outColor.y, outColor.z ) );
            float3 RGBm = outColor.rgb - luma;
            float distRGB  = dot( abs(RGBm), ones );
            float sat = distRGB * 1.25;
            float hue = 0.0;
            if (minRGB != maxRGB) {
               float OneOverMaxMinusMin = 1.0 / (maxRGB - minRGB);
               if ( maxRGB == outColor.r ) hue = 1.0 + (outColor.g - outColor.b) * OneOverMaxMinusMin;
               else if ( maxRGB == outColor.g ) hue = 3.0 + (outColor.b - outColor.r) * OneOverMaxMinusMin;
               else hue = 5.0 + (outColor.r - outColor.g) * OneOverMaxMinusMin;
            }
            outColor.r = hue * 1./6.; outColor.g = sat; outColor.b = luma;
          }
      }
      outColor.r = ocio_grading_huecurve_evalBSplineCurveRevHue(7, outColor.r);
      outColor.r = ocio_grading_huecurve_evalBSplineCurveRevHue(0, outColor.r);
      
      outColor.r = outColor.r - floor( outColor.r );
      float hueSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.));
      float hueLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(2, outColor.r, 1.));
      outColor.g = max(0., outColor.g);
      float satLumGain = max(0., ocio_grading_huecurve_evalBSplineCurve(6, outColor.g, 1.));
      
      hueLumGain = 1. - (1. - hueLumGain) * min( 1., outColor.g );
      outColor.b = outColor.b / max(0.01, hueLumGain * satLumGain);
      
      outColor.b = ocio_grading_huecurve_evalBSplineCurveRev(5, outColor.b);
      
      float lumSatGain = max(0., ocio_grading_huecurve_evalBSplineCurve(3, outColor.b, 1.));
      float satGain = max(0.01, lumSatGain * hueSatGain);
      outColor.g = outColor.g / satGain;
      outColor.g = max(0., ocio_grading_huecurve_evalBSplineCurveRev(4, outColor.g));
      {
          
          // Add FixedFunction 'HSY_VID_TO_RGB' processing
          
          {
            float luma = outColor.z;
            float Hue = outColor.x - 1./6.;
            Hue = (luma < 0.) ? Hue + 0.5 : Hue;
            Hue = ( Hue - floor( Hue ) ) * 6.0;
            float R = abs(Hue - 3.0) - 1.0;
            float G = 2.0 - abs(Hue - 2.0);
            float B = 2.0 - abs(Hue - 4.0);
            float3 RGB0 = float3(R, G, B);
            RGB0 = clamp( RGB0, 0., 1. );
            float3 lumaWeights = float3(0.212599993, 0.715200007, 0.0722000003);
            float3 ones = float3(1., 1., 1.);
            float currY = dot(RGB0, lumaWeights);
            RGB0 *= luma / currY;
            float sat = outColor.y;
            float distRGB = dot( abs(RGB0 - luma), ones );
            float gainS = sat / max(1e-10, distRGB * 1.25);
            outColor.rgb = luma + gainS * (RGB0 - luma);
          }
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "hue.video.inverse.draw":
        return GradingShaderTemplate(names: ["ocio_grading_huecurve_knotsOffsets", "ocio_grading_huecurve_knots", "ocio_grading_huecurve_coefsOffsets", "ocio_grading_huecurve_coefs", "ocio_grading_huecurve_localBypass"], lengths: [16, 120, 16, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_huecurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = ocio_grading_huecurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_knotsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_knots_count; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = ocio_grading_huecurve_knots[i];
  }
  for(int i = ocio_grading_huecurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_huecurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = ocio_grading_huecurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_huecurve_coefsOffsets_count; i < 16; ++i)
  {
    this->ocio_grading_huecurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_huecurve_coefs_count; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = ocio_grading_huecurve_coefs[i];
  }
  for(int i = ocio_grading_huecurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_huecurve_coefs[i] = 0;
  }
  this->ocio_grading_huecurve_localBypass = ocio_grading_huecurve_localBypass;
}


// Declaration of all variables

int ocio_grading_huecurve_knotsOffsets[16];
float ocio_grading_huecurve_knots[120];
int ocio_grading_huecurve_coefsOffsets[16];
float ocio_grading_huecurve_coefs[360];
bool ocio_grading_huecurve_localBypass;


// Declaration of all helper methods


float ocio_grading_huecurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

float ocio_grading_huecurve_evalBSplineCurveRev(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

float ocio_grading_huecurve_evalBSplineCurveRevHue(int curveIdx, float x)
{
  int knotsOffs = ocio_grading_huecurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_huecurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_huecurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_huecurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_huecurve_knots[knotsOffs];
  float knEnd = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_huecurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_huecurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
    knEndY = (curveIdx == 7) ? knEndY + knEnd : knEndY;
  }
  if (x < knStartY)
  {
    x = x + ceil(knStartY - x);
  }
  else if (x > knEndY)
  {
    x = x - ceil(x - knEndY);
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    float curve_x = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i + 1];
    curve_x = (curveIdx == 7) ? curve_x + ocio_grading_huecurve_knots[knotsOffs + i + 1] : curve_x;
    if (x < curve_x)
    {
      break;
    }
  }
  float A = ocio_grading_huecurve_coefs[coefsOffs + i];
  float B = ocio_grading_huecurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_huecurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_huecurve_knots[knotsOffs + i];
  if (curveIdx == 7)
  {
    C = C + kn;
    B = B + 1.;
  }
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingHueCurve inverse processing
  
  {
    outColor.r = ocio_grading_huecurve_evalBSplineCurve(1, outColor.r, 1.);
    outColor.g = ocio_grading_huecurve_evalBSplineCurve(1, outColor.g, 1.);
    outColor.b = ocio_grading_huecurve_evalBSplineCurve(1, outColor.b, 1.);
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_huecurve_knotsOffsets[16]
  , int ocio_grading_huecurve_knotsOffsets_count
  , constant float ocio_grading_huecurve_knots[120]
  , int ocio_grading_huecurve_knots_count
  , constant int ocio_grading_huecurve_coefsOffsets[16]
  , int ocio_grading_huecurve_coefsOffsets_count
  , constant float ocio_grading_huecurve_coefs[360]
  , int ocio_grading_huecurve_coefs_count
  , bool ocio_grading_huecurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_huecurve_knotsOffsets
    , ocio_grading_huecurve_knotsOffsets_count
    , ocio_grading_huecurve_knots
    , ocio_grading_huecurve_knots_count
    , ocio_grading_huecurve_coefsOffsets
    , ocio_grading_huecurve_coefsOffsets_count
    , ocio_grading_huecurve_coefs
    , ocio_grading_huecurve_coefs_count
    , ocio_grading_huecurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "primary.lin.forward":
        return GradingShaderTemplate(names: ["ocio_grading_primary_offset", "ocio_grading_primary_exposure", "ocio_grading_primary_contrast", "ocio_grading_primary_pivot", "ocio_grading_primary_clampBlack", "ocio_grading_primary_clampWhite", "ocio_grading_primary_saturation", "ocio_grading_primary_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_exposure
  , float3 ocio_grading_primary_contrast
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
)
{
  this->ocio_grading_primary_offset = ocio_grading_primary_offset;
  this->ocio_grading_primary_exposure = ocio_grading_primary_exposure;
  this->ocio_grading_primary_contrast = ocio_grading_primary_contrast;
  this->ocio_grading_primary_pivot = ocio_grading_primary_pivot;
  this->ocio_grading_primary_clampBlack = ocio_grading_primary_clampBlack;
  this->ocio_grading_primary_clampWhite = ocio_grading_primary_clampWhite;
  this->ocio_grading_primary_saturation = ocio_grading_primary_saturation;
  this->ocio_grading_primary_localBypass = ocio_grading_primary_localBypass;
}


// Declaration of all variables

float3 ocio_grading_primary_offset;
float3 ocio_grading_primary_exposure;
float3 ocio_grading_primary_contrast;
float ocio_grading_primary_pivot;
float ocio_grading_primary_clampBlack;
float ocio_grading_primary_clampWhite;
float ocio_grading_primary_saturation;
bool ocio_grading_primary_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingPrimary 'linear' forward processing
  
  {
    if (!ocio_grading_primary_localBypass)
    {
      outColor.rgb += ocio_grading_primary_offset;
      outColor.rgb *= ocio_grading_primary_exposure;
      if ( any( ocio_grading_primary_contrast != float3(1., 1., 1.) ) )
      {
        outColor.rgb = pow( abs(outColor.rgb / ocio_grading_primary_pivot), ocio_grading_primary_contrast ) * sign(outColor.rgb) * ocio_grading_primary_pivot;
      }
      float3 lumaWgts = float3(0.212599993, 0.715200007, 0.0722000003);
      float luma = dot( outColor.rgb, lumaWgts );
      outColor.rgb = luma + ocio_grading_primary_saturation * (outColor.rgb - luma);
      outColor.rgb = clamp( outColor.rgb, ocio_grading_primary_clampBlack, ocio_grading_primary_clampWhite );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_exposure
  , float3 ocio_grading_primary_contrast
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_primary_offset
    , ocio_grading_primary_exposure
    , ocio_grading_primary_contrast
    , ocio_grading_primary_pivot
    , ocio_grading_primary_clampBlack
    , ocio_grading_primary_clampWhite
    , ocio_grading_primary_saturation
    , ocio_grading_primary_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "primary.lin.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_primary_offset", "ocio_grading_primary_exposure", "ocio_grading_primary_contrast", "ocio_grading_primary_pivot", "ocio_grading_primary_clampBlack", "ocio_grading_primary_clampWhite", "ocio_grading_primary_saturation", "ocio_grading_primary_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_exposure
  , float3 ocio_grading_primary_contrast
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
)
{
  this->ocio_grading_primary_offset = ocio_grading_primary_offset;
  this->ocio_grading_primary_exposure = ocio_grading_primary_exposure;
  this->ocio_grading_primary_contrast = ocio_grading_primary_contrast;
  this->ocio_grading_primary_pivot = ocio_grading_primary_pivot;
  this->ocio_grading_primary_clampBlack = ocio_grading_primary_clampBlack;
  this->ocio_grading_primary_clampWhite = ocio_grading_primary_clampWhite;
  this->ocio_grading_primary_saturation = ocio_grading_primary_saturation;
  this->ocio_grading_primary_localBypass = ocio_grading_primary_localBypass;
}


// Declaration of all variables

float3 ocio_grading_primary_offset;
float3 ocio_grading_primary_exposure;
float3 ocio_grading_primary_contrast;
float ocio_grading_primary_pivot;
float ocio_grading_primary_clampBlack;
float ocio_grading_primary_clampWhite;
float ocio_grading_primary_saturation;
bool ocio_grading_primary_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingPrimary 'linear' inverse processing
  
  {
    if (!ocio_grading_primary_localBypass)
    {
      outColor.rgb = clamp( outColor.rgb, ocio_grading_primary_clampBlack, ocio_grading_primary_clampWhite );
      if (ocio_grading_primary_saturation != 0. && ocio_grading_primary_saturation != 1.)
      {
        float3 lumaWgts = float3(0.212599993, 0.715200007, 0.0722000003);
        float luma = dot( outColor.rgb, lumaWgts );
        outColor.rgb = luma + (outColor.rgb - luma) / ocio_grading_primary_saturation;
      }
      if ( any( ocio_grading_primary_contrast != float3(1., 1., 1.) ) )
      {
        outColor.rgb = pow( abs(outColor.rgb / ocio_grading_primary_pivot), ocio_grading_primary_contrast ) * sign(outColor.rgb) * ocio_grading_primary_pivot;
      }
      outColor.rgb *= ocio_grading_primary_exposure;
      outColor.rgb += ocio_grading_primary_offset;
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_exposure
  , float3 ocio_grading_primary_contrast
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_primary_offset
    , ocio_grading_primary_exposure
    , ocio_grading_primary_contrast
    , ocio_grading_primary_pivot
    , ocio_grading_primary_clampBlack
    , ocio_grading_primary_clampWhite
    , ocio_grading_primary_saturation
    , ocio_grading_primary_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "primary.log.forward":
        return GradingShaderTemplate(names: ["ocio_grading_primary_brightness", "ocio_grading_primary_contrast", "ocio_grading_primary_gamma", "ocio_grading_primary_pivot", "ocio_grading_primary_pivotBlack", "ocio_grading_primary_pivotWhite", "ocio_grading_primary_clampBlack", "ocio_grading_primary_clampWhite", "ocio_grading_primary_saturation", "ocio_grading_primary_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float3 ocio_grading_primary_brightness
  , float3 ocio_grading_primary_contrast
  , float3 ocio_grading_primary_gamma
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
)
{
  this->ocio_grading_primary_brightness = ocio_grading_primary_brightness;
  this->ocio_grading_primary_contrast = ocio_grading_primary_contrast;
  this->ocio_grading_primary_gamma = ocio_grading_primary_gamma;
  this->ocio_grading_primary_pivot = ocio_grading_primary_pivot;
  this->ocio_grading_primary_pivotBlack = ocio_grading_primary_pivotBlack;
  this->ocio_grading_primary_pivotWhite = ocio_grading_primary_pivotWhite;
  this->ocio_grading_primary_clampBlack = ocio_grading_primary_clampBlack;
  this->ocio_grading_primary_clampWhite = ocio_grading_primary_clampWhite;
  this->ocio_grading_primary_saturation = ocio_grading_primary_saturation;
  this->ocio_grading_primary_localBypass = ocio_grading_primary_localBypass;
}


// Declaration of all variables

float3 ocio_grading_primary_brightness;
float3 ocio_grading_primary_contrast;
float3 ocio_grading_primary_gamma;
float ocio_grading_primary_pivot;
float ocio_grading_primary_pivotBlack;
float ocio_grading_primary_pivotWhite;
float ocio_grading_primary_clampBlack;
float ocio_grading_primary_clampWhite;
float ocio_grading_primary_saturation;
bool ocio_grading_primary_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingPrimary 'log' forward processing
  
  {
    if (!ocio_grading_primary_localBypass)
    {
      outColor.rgb += ocio_grading_primary_brightness;
      outColor.rgb = ( outColor.rgb - ocio_grading_primary_pivot ) * ocio_grading_primary_contrast + ocio_grading_primary_pivot;
      if ( any( ocio_grading_primary_gamma != float3(1., 1., 1.) ) )
      {
        float3 normalizedOut = abs(outColor.rgb - ocio_grading_primary_pivotBlack) / (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        float3 scale = sign(outColor.rgb - ocio_grading_primary_pivotBlack) * (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        outColor.rgb = pow( normalizedOut, ocio_grading_primary_gamma ) * scale + ocio_grading_primary_pivotBlack;
      }
      float3 lumaWgts = float3(0.212599993, 0.715200007, 0.0722000003);
      float luma = dot( outColor.rgb, lumaWgts );
      outColor.rgb = luma + ocio_grading_primary_saturation * (outColor.rgb - luma);
      outColor.rgb = clamp( outColor.rgb, ocio_grading_primary_clampBlack, ocio_grading_primary_clampWhite );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float3 ocio_grading_primary_brightness
  , float3 ocio_grading_primary_contrast
  , float3 ocio_grading_primary_gamma
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_primary_brightness
    , ocio_grading_primary_contrast
    , ocio_grading_primary_gamma
    , ocio_grading_primary_pivot
    , ocio_grading_primary_pivotBlack
    , ocio_grading_primary_pivotWhite
    , ocio_grading_primary_clampBlack
    , ocio_grading_primary_clampWhite
    , ocio_grading_primary_saturation
    , ocio_grading_primary_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "primary.log.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_primary_brightness", "ocio_grading_primary_contrast", "ocio_grading_primary_gamma", "ocio_grading_primary_pivot", "ocio_grading_primary_pivotBlack", "ocio_grading_primary_pivotWhite", "ocio_grading_primary_clampBlack", "ocio_grading_primary_clampWhite", "ocio_grading_primary_saturation", "ocio_grading_primary_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float3 ocio_grading_primary_brightness
  , float3 ocio_grading_primary_contrast
  , float3 ocio_grading_primary_gamma
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
)
{
  this->ocio_grading_primary_brightness = ocio_grading_primary_brightness;
  this->ocio_grading_primary_contrast = ocio_grading_primary_contrast;
  this->ocio_grading_primary_gamma = ocio_grading_primary_gamma;
  this->ocio_grading_primary_pivot = ocio_grading_primary_pivot;
  this->ocio_grading_primary_pivotBlack = ocio_grading_primary_pivotBlack;
  this->ocio_grading_primary_pivotWhite = ocio_grading_primary_pivotWhite;
  this->ocio_grading_primary_clampBlack = ocio_grading_primary_clampBlack;
  this->ocio_grading_primary_clampWhite = ocio_grading_primary_clampWhite;
  this->ocio_grading_primary_saturation = ocio_grading_primary_saturation;
  this->ocio_grading_primary_localBypass = ocio_grading_primary_localBypass;
}


// Declaration of all variables

float3 ocio_grading_primary_brightness;
float3 ocio_grading_primary_contrast;
float3 ocio_grading_primary_gamma;
float ocio_grading_primary_pivot;
float ocio_grading_primary_pivotBlack;
float ocio_grading_primary_pivotWhite;
float ocio_grading_primary_clampBlack;
float ocio_grading_primary_clampWhite;
float ocio_grading_primary_saturation;
bool ocio_grading_primary_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingPrimary 'log' inverse processing
  
  {
    if (!ocio_grading_primary_localBypass)
    {
      outColor.rgb = clamp( outColor.rgb, ocio_grading_primary_clampBlack, ocio_grading_primary_clampWhite );
      if (ocio_grading_primary_saturation != 0. && ocio_grading_primary_saturation != 1.)
      {
        float3 lumaWgts = float3(0.212599993, 0.715200007, 0.0722000003);
        float luma = dot( outColor.rgb, lumaWgts );
        outColor.rgb = luma + (outColor.rgb - luma) / ocio_grading_primary_saturation;
      }
      if ( any( ocio_grading_primary_gamma != float3(1., 1., 1.) ) )
      {
        float3 normalizedOut = abs(outColor.rgb - ocio_grading_primary_pivotBlack) / (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        float3 scale = sign(outColor.rgb - ocio_grading_primary_pivotBlack) * (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        outColor.rgb = pow( normalizedOut, ocio_grading_primary_gamma ) * scale + ocio_grading_primary_pivotBlack;
      }
      outColor.rgb = ( outColor.rgb - ocio_grading_primary_pivot ) * ocio_grading_primary_contrast + ocio_grading_primary_pivot;
      outColor.rgb += ocio_grading_primary_brightness;
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float3 ocio_grading_primary_brightness
  , float3 ocio_grading_primary_contrast
  , float3 ocio_grading_primary_gamma
  , float ocio_grading_primary_pivot
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_primary_brightness
    , ocio_grading_primary_contrast
    , ocio_grading_primary_gamma
    , ocio_grading_primary_pivot
    , ocio_grading_primary_pivotBlack
    , ocio_grading_primary_pivotWhite
    , ocio_grading_primary_clampBlack
    , ocio_grading_primary_clampWhite
    , ocio_grading_primary_saturation
    , ocio_grading_primary_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "primary.video.forward":
        return GradingShaderTemplate(names: ["ocio_grading_primary_gamma", "ocio_grading_primary_offset", "ocio_grading_primary_slope", "ocio_grading_primary_pivotBlack", "ocio_grading_primary_pivotWhite", "ocio_grading_primary_clampBlack", "ocio_grading_primary_clampWhite", "ocio_grading_primary_saturation", "ocio_grading_primary_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float3 ocio_grading_primary_gamma
  , float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_slope
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
)
{
  this->ocio_grading_primary_gamma = ocio_grading_primary_gamma;
  this->ocio_grading_primary_offset = ocio_grading_primary_offset;
  this->ocio_grading_primary_slope = ocio_grading_primary_slope;
  this->ocio_grading_primary_pivotBlack = ocio_grading_primary_pivotBlack;
  this->ocio_grading_primary_pivotWhite = ocio_grading_primary_pivotWhite;
  this->ocio_grading_primary_clampBlack = ocio_grading_primary_clampBlack;
  this->ocio_grading_primary_clampWhite = ocio_grading_primary_clampWhite;
  this->ocio_grading_primary_saturation = ocio_grading_primary_saturation;
  this->ocio_grading_primary_localBypass = ocio_grading_primary_localBypass;
}


// Declaration of all variables

float3 ocio_grading_primary_gamma;
float3 ocio_grading_primary_offset;
float3 ocio_grading_primary_slope;
float ocio_grading_primary_pivotBlack;
float ocio_grading_primary_pivotWhite;
float ocio_grading_primary_clampBlack;
float ocio_grading_primary_clampWhite;
float ocio_grading_primary_saturation;
bool ocio_grading_primary_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingPrimary 'video' forward processing
  
  {
    if (!ocio_grading_primary_localBypass)
    {
      outColor.rgb += ocio_grading_primary_offset;
      outColor.rgb = ( outColor.rgb - ocio_grading_primary_pivotBlack ) * ocio_grading_primary_slope + ocio_grading_primary_pivotBlack;
      if ( any( ocio_grading_primary_gamma != float3(1., 1., 1.) ) )
      {
        float3 normalizedOut = abs(outColor.rgb - ocio_grading_primary_pivotBlack) / (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        float3 scale = sign(outColor.rgb - ocio_grading_primary_pivotBlack) * (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
          outColor.rgb = pow( normalizedOut, ocio_grading_primary_gamma ) * scale + ocio_grading_primary_pivotBlack;
      }
      float3 lumaWgts = float3(0.212599993, 0.715200007, 0.0722000003);
      float luma = dot( outColor.rgb, lumaWgts );
      outColor.rgb = luma + ocio_grading_primary_saturation * (outColor.rgb - luma);
      outColor.rgb = clamp( outColor.rgb, ocio_grading_primary_clampBlack, ocio_grading_primary_clampWhite );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float3 ocio_grading_primary_gamma
  , float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_slope
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_primary_gamma
    , ocio_grading_primary_offset
    , ocio_grading_primary_slope
    , ocio_grading_primary_pivotBlack
    , ocio_grading_primary_pivotWhite
    , ocio_grading_primary_clampBlack
    , ocio_grading_primary_clampWhite
    , ocio_grading_primary_saturation
    , ocio_grading_primary_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "primary.video.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_primary_gamma", "ocio_grading_primary_offset", "ocio_grading_primary_slope", "ocio_grading_primary_pivotBlack", "ocio_grading_primary_pivotWhite", "ocio_grading_primary_clampBlack", "ocio_grading_primary_clampWhite", "ocio_grading_primary_saturation", "ocio_grading_primary_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float3 ocio_grading_primary_gamma
  , float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_slope
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
)
{
  this->ocio_grading_primary_gamma = ocio_grading_primary_gamma;
  this->ocio_grading_primary_offset = ocio_grading_primary_offset;
  this->ocio_grading_primary_slope = ocio_grading_primary_slope;
  this->ocio_grading_primary_pivotBlack = ocio_grading_primary_pivotBlack;
  this->ocio_grading_primary_pivotWhite = ocio_grading_primary_pivotWhite;
  this->ocio_grading_primary_clampBlack = ocio_grading_primary_clampBlack;
  this->ocio_grading_primary_clampWhite = ocio_grading_primary_clampWhite;
  this->ocio_grading_primary_saturation = ocio_grading_primary_saturation;
  this->ocio_grading_primary_localBypass = ocio_grading_primary_localBypass;
}


// Declaration of all variables

float3 ocio_grading_primary_gamma;
float3 ocio_grading_primary_offset;
float3 ocio_grading_primary_slope;
float ocio_grading_primary_pivotBlack;
float ocio_grading_primary_pivotWhite;
float ocio_grading_primary_clampBlack;
float ocio_grading_primary_clampWhite;
float ocio_grading_primary_saturation;
bool ocio_grading_primary_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingPrimary 'video' inverse processing
  
  {
    if (!ocio_grading_primary_localBypass)
    {
      outColor.rgb = clamp( outColor.rgb, ocio_grading_primary_clampBlack, ocio_grading_primary_clampWhite );
      if (ocio_grading_primary_saturation != 0. && ocio_grading_primary_saturation != 1.)
      {
        float3 lumaWgts = float3(0.212599993, 0.715200007, 0.0722000003);
        float luma = dot( outColor.rgb, lumaWgts );
        outColor.rgb = luma + (outColor.rgb - luma) / ocio_grading_primary_saturation;
      }
      if ( any( ocio_grading_primary_gamma != float3(1., 1., 1.) ) )
      {
        float3 normalizedOut = abs(outColor.rgb - ocio_grading_primary_pivotBlack) / (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        float3 scale = sign(outColor.rgb - ocio_grading_primary_pivotBlack) * (ocio_grading_primary_pivotWhite - ocio_grading_primary_pivotBlack);
        outColor.rgb = pow( normalizedOut, ocio_grading_primary_gamma ) * scale + ocio_grading_primary_pivotBlack;
      }
      outColor.rgb = ( outColor.rgb - ocio_grading_primary_pivotBlack ) * ocio_grading_primary_slope + ocio_grading_primary_pivotBlack;
      outColor.rgb += ocio_grading_primary_offset;
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float3 ocio_grading_primary_gamma
  , float3 ocio_grading_primary_offset
  , float3 ocio_grading_primary_slope
  , float ocio_grading_primary_pivotBlack
  , float ocio_grading_primary_pivotWhite
  , float ocio_grading_primary_clampBlack
  , float ocio_grading_primary_clampWhite
  , float ocio_grading_primary_saturation
  , bool ocio_grading_primary_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_primary_gamma
    , ocio_grading_primary_offset
    , ocio_grading_primary_slope
    , ocio_grading_primary_pivotBlack
    , ocio_grading_primary_pivotWhite
    , ocio_grading_primary_clampBlack
    , ocio_grading_primary_clampWhite
    , ocio_grading_primary_saturation
    , ocio_grading_primary_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.lin.forward":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'linear' forward processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      // Convert from lin to log.
      {
        const float xbrk = 0.0041318374739483946;
        const float shift = -0.000157849851665374;
        const float m = 1. / (0.18 + shift);
        const float base2 = 1.4426950408889634;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 ylin = outColor.rgb * gain + offs;
        float3 ylog = base2 * log( ( outColor.rgb + shift ) * m );
        outColor.rgb.r = (outColor.rgb.r < xbrk) ? ylin.x : ylog.x;
        outColor.rgb.g = (outColor.rgb.g < xbrk) ? ylin.y : ylog.y;
        outColor.rgb.b = (outColor.rgb.b < xbrk) ? ylin.z : ylog.z;
      }
      
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
      
      // Convert from log to lin.
      {
        const float ybrk = -5.5;
        const float shift = -0.000157849851665374;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 xlin = (outColor.rgb - offs) / gain;
        float3 xlog = pow( float3(2., 2., 2.), outColor.rgb ) * (0.18 + shift) - shift;
        outColor.rgb.r = (outColor.rgb.r < ybrk) ? xlin.x : xlog.x;
        outColor.rgb.g = (outColor.rgb.g < ybrk) ? xlin.y : xlog.y;
        outColor.rgb.b = (outColor.rgb.b < ybrk) ? xlin.z : xlog.z;
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.lin.forward.bypass":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'linear' forward processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.lin.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'linear' inverse processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      // Convert from lin to log.
      {
        const float xbrk = 0.0041318374739483946;
        const float shift = -0.000157849851665374;
        const float m = 1. / (0.18 + shift);
        const float base2 = 1.4426950408889634;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 ylin = outColor.rgb * gain + offs;
        float3 ylog = base2 * log( ( outColor.rgb + shift ) * m );
        outColor.rgb.r = (outColor.rgb.r < xbrk) ? ylin.x : ylog.x;
        outColor.rgb.g = (outColor.rgb.g < xbrk) ? ylin.y : ylog.y;
        outColor.rgb.b = (outColor.rgb.b < xbrk) ? ylin.z : ylog.z;
      }
      
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
      
      // Convert from log to lin.
      {
        const float ybrk = -5.5;
        const float shift = -0.000157849851665374;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 xlin = (outColor.rgb - offs) / gain;
        float3 xlog = pow( float3(2., 2., 2.), outColor.rgb ) * (0.18 + shift) - shift;
        outColor.rgb.r = (outColor.rgb.r < ybrk) ? xlin.x : xlog.x;
        outColor.rgb.g = (outColor.rgb.g < ybrk) ? xlin.y : xlog.y;
        outColor.rgb.b = (outColor.rgb.b < ybrk) ? xlin.z : xlog.z;
      }
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.lin.inverse.bypass":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'linear' inverse processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.log.forward":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'log' forward processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.log.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'log' inverse processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.video.forward":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return identity_x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  if (x <= knStart)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return (x - knStart) * B + C;
  }
  else if (x >= knEnd)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return (x - knEnd) * slope + offs;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_knots[knotsOffs + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float t = x - kn;
  return ( A * t + B ) * t + C;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'video' forward processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "rgb.video.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_rgbcurve_knotsOffsets", "ocio_grading_rgbcurve_knots", "ocio_grading_rgbcurve_coefsOffsets", "ocio_grading_rgbcurve_coefs", "ocio_grading_rgbcurve_localBypass"], lengths: [8, 120, 8, 360, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
)
{
  for(int i = 0; i < ocio_grading_rgbcurve_knotsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = ocio_grading_rgbcurve_knotsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_knotsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_knotsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_knots_count; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = ocio_grading_rgbcurve_knots[i];
  }
  for(int i = ocio_grading_rgbcurve_knots_count; i < 120; ++i)
  {
    this->ocio_grading_rgbcurve_knots[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefsOffsets_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = ocio_grading_rgbcurve_coefsOffsets[i];
  }
  for(int i = ocio_grading_rgbcurve_coefsOffsets_count; i < 8; ++i)
  {
    this->ocio_grading_rgbcurve_coefsOffsets[i] = 0;
  }
  for(int i = 0; i < ocio_grading_rgbcurve_coefs_count; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = ocio_grading_rgbcurve_coefs[i];
  }
  for(int i = ocio_grading_rgbcurve_coefs_count; i < 360; ++i)
  {
    this->ocio_grading_rgbcurve_coefs[i] = 0;
  }
  this->ocio_grading_rgbcurve_localBypass = ocio_grading_rgbcurve_localBypass;
}


// Declaration of all variables

int ocio_grading_rgbcurve_knotsOffsets[8];
float ocio_grading_rgbcurve_knots[120];
int ocio_grading_rgbcurve_coefsOffsets[8];
float ocio_grading_rgbcurve_coefs[360];
bool ocio_grading_rgbcurve_localBypass;


// Declaration of all helper methods


float ocio_grading_rgbcurve_evalBSplineCurve(int curveIdx, float x, float identity_x)
{
  int knotsOffs = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2];
  int knotsCnt = ocio_grading_rgbcurve_knotsOffsets[curveIdx * 2 + 1];
  int coefsOffs = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2];
  int coefsCnt = ocio_grading_rgbcurve_coefsOffsets[curveIdx * 2 + 1];
  int coefsSets = coefsCnt / 3;
  if (coefsSets == 0)
  {
    return x;
  }
  float knStart = ocio_grading_rgbcurve_knots[knotsOffs];
  float knEnd = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 1];
  float knStartY = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
  float knEndY;
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    knEndY = ( A * t + B ) * t + C;
  }
  if (x <= knStartY)
  {
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2];
    return abs(B) < 1e-5 ? knStart : (x - C) / B + knStart;
  }
  else if (x >= knEndY)
  {
    float A = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets - 1];
    float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 - 1];
    float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 3 - 1];
    float kn = ocio_grading_rgbcurve_knots[knotsOffs + knotsCnt - 2];
    float t = knEnd - kn;
    float slope = 2. * A * t + B;
    float offs = ( A * t + B ) * t + C;
    return abs(slope) < 1e-5 ? knEnd : (x - offs) / slope + knEnd;
  }
  int i = 0;
  for (i = 0; i < knotsCnt - 2; ++i)
  {
    if (x < ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i + 1])
    {
      break;
    }
  }
  float A = ocio_grading_rgbcurve_coefs[coefsOffs + i];
  float B = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets + i];
  float C = ocio_grading_rgbcurve_coefs[coefsOffs + coefsSets * 2 + i];
  float kn = ocio_grading_rgbcurve_knots[knotsOffs + i];
  float C0 = C - x;
  float discrim = sqrt(B * B - 4. * A * C0);
  float denom = discrim + B;
  if (abs(denom) < 1e-5)
  {
    return abs(B) < 1e-5 ? kn : kn + (-C0 / B);
  }
  return kn + (-2. * C0) / denom;
}

// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingRGBCurve 'video' inverse processing
  
  {
    if (!ocio_grading_rgbcurve_localBypass)
    {
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(3, outColor.rgb.b, outColor.rgb.b);
      outColor.rgb.r = ocio_grading_rgbcurve_evalBSplineCurve(0, outColor.rgb.r, outColor.rgb.r);
      outColor.rgb.g = ocio_grading_rgbcurve_evalBSplineCurve(1, outColor.rgb.g, outColor.rgb.g);
      outColor.rgb.b = ocio_grading_rgbcurve_evalBSplineCurve(2, outColor.rgb.b, outColor.rgb.b);
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  constant int ocio_grading_rgbcurve_knotsOffsets[8]
  , int ocio_grading_rgbcurve_knotsOffsets_count
  , constant float ocio_grading_rgbcurve_knots[120]
  , int ocio_grading_rgbcurve_knots_count
  , constant int ocio_grading_rgbcurve_coefsOffsets[8]
  , int ocio_grading_rgbcurve_coefsOffsets_count
  , constant float ocio_grading_rgbcurve_coefs[360]
  , int ocio_grading_rgbcurve_coefs_count
  , bool ocio_grading_rgbcurve_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_rgbcurve_knotsOffsets
    , ocio_grading_rgbcurve_knotsOffsets_count
    , ocio_grading_rgbcurve_knots
    , ocio_grading_rgbcurve_knots_count
    , ocio_grading_rgbcurve_coefsOffsets
    , ocio_grading_rgbcurve_coefsOffsets_count
    , ocio_grading_rgbcurve_coefs
    , ocio_grading_rgbcurve_coefs_count
    , ocio_grading_rgbcurve_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "tone.lin.forward":
        return GradingShaderTemplate(names: ["ocio_grading_tone_blacksR", "ocio_grading_tone_blacksG", "ocio_grading_tone_blacksB", "ocio_grading_tone_blacksM", "ocio_grading_tone_blacksStart", "ocio_grading_tone_blacksWidth", "ocio_grading_tone_shadowsR", "ocio_grading_tone_shadowsG", "ocio_grading_tone_shadowsB", "ocio_grading_tone_shadowsM", "ocio_grading_tone_shadowsStart", "ocio_grading_tone_shadowsWidth", "ocio_grading_tone_midtonesR", "ocio_grading_tone_midtonesG", "ocio_grading_tone_midtonesB", "ocio_grading_tone_midtonesM", "ocio_grading_tone_midtonesStart", "ocio_grading_tone_midtonesWidth", "ocio_grading_tone_highlightsR", "ocio_grading_tone_highlightsG", "ocio_grading_tone_highlightsB", "ocio_grading_tone_highlightsM", "ocio_grading_tone_highlightsStart", "ocio_grading_tone_highlightsWidth", "ocio_grading_tone_whitesR", "ocio_grading_tone_whitesG", "ocio_grading_tone_whitesB", "ocio_grading_tone_whitesM", "ocio_grading_tone_whitesStart", "ocio_grading_tone_whitesWidth", "ocio_grading_tone_sContrast", "ocio_grading_tone_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
)
{
  this->ocio_grading_tone_blacksR = ocio_grading_tone_blacksR;
  this->ocio_grading_tone_blacksG = ocio_grading_tone_blacksG;
  this->ocio_grading_tone_blacksB = ocio_grading_tone_blacksB;
  this->ocio_grading_tone_blacksM = ocio_grading_tone_blacksM;
  this->ocio_grading_tone_blacksStart = ocio_grading_tone_blacksStart;
  this->ocio_grading_tone_blacksWidth = ocio_grading_tone_blacksWidth;
  this->ocio_grading_tone_shadowsR = ocio_grading_tone_shadowsR;
  this->ocio_grading_tone_shadowsG = ocio_grading_tone_shadowsG;
  this->ocio_grading_tone_shadowsB = ocio_grading_tone_shadowsB;
  this->ocio_grading_tone_shadowsM = ocio_grading_tone_shadowsM;
  this->ocio_grading_tone_shadowsStart = ocio_grading_tone_shadowsStart;
  this->ocio_grading_tone_shadowsWidth = ocio_grading_tone_shadowsWidth;
  this->ocio_grading_tone_midtonesR = ocio_grading_tone_midtonesR;
  this->ocio_grading_tone_midtonesG = ocio_grading_tone_midtonesG;
  this->ocio_grading_tone_midtonesB = ocio_grading_tone_midtonesB;
  this->ocio_grading_tone_midtonesM = ocio_grading_tone_midtonesM;
  this->ocio_grading_tone_midtonesStart = ocio_grading_tone_midtonesStart;
  this->ocio_grading_tone_midtonesWidth = ocio_grading_tone_midtonesWidth;
  this->ocio_grading_tone_highlightsR = ocio_grading_tone_highlightsR;
  this->ocio_grading_tone_highlightsG = ocio_grading_tone_highlightsG;
  this->ocio_grading_tone_highlightsB = ocio_grading_tone_highlightsB;
  this->ocio_grading_tone_highlightsM = ocio_grading_tone_highlightsM;
  this->ocio_grading_tone_highlightsStart = ocio_grading_tone_highlightsStart;
  this->ocio_grading_tone_highlightsWidth = ocio_grading_tone_highlightsWidth;
  this->ocio_grading_tone_whitesR = ocio_grading_tone_whitesR;
  this->ocio_grading_tone_whitesG = ocio_grading_tone_whitesG;
  this->ocio_grading_tone_whitesB = ocio_grading_tone_whitesB;
  this->ocio_grading_tone_whitesM = ocio_grading_tone_whitesM;
  this->ocio_grading_tone_whitesStart = ocio_grading_tone_whitesStart;
  this->ocio_grading_tone_whitesWidth = ocio_grading_tone_whitesWidth;
  this->ocio_grading_tone_sContrast = ocio_grading_tone_sContrast;
  this->ocio_grading_tone_localBypass = ocio_grading_tone_localBypass;
}


// Declaration of all variables

float ocio_grading_tone_blacksR;
float ocio_grading_tone_blacksG;
float ocio_grading_tone_blacksB;
float ocio_grading_tone_blacksM;
float ocio_grading_tone_blacksStart;
float ocio_grading_tone_blacksWidth;
float ocio_grading_tone_shadowsR;
float ocio_grading_tone_shadowsG;
float ocio_grading_tone_shadowsB;
float ocio_grading_tone_shadowsM;
float ocio_grading_tone_shadowsStart;
float ocio_grading_tone_shadowsWidth;
float ocio_grading_tone_midtonesR;
float ocio_grading_tone_midtonesG;
float ocio_grading_tone_midtonesB;
float ocio_grading_tone_midtonesM;
float ocio_grading_tone_midtonesStart;
float ocio_grading_tone_midtonesWidth;
float ocio_grading_tone_highlightsR;
float ocio_grading_tone_highlightsG;
float ocio_grading_tone_highlightsB;
float ocio_grading_tone_highlightsM;
float ocio_grading_tone_highlightsStart;
float ocio_grading_tone_highlightsWidth;
float ocio_grading_tone_whitesR;
float ocio_grading_tone_whitesG;
float ocio_grading_tone_whitesB;
float ocio_grading_tone_whitesM;
float ocio_grading_tone_whitesStart;
float ocio_grading_tone_whitesWidth;
float ocio_grading_tone_sContrast;
bool ocio_grading_tone_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingTone 'linear' forward processing
  
  {
    if (!ocio_grading_tone_localBypass)
    {
      {
        const float xbrk = 0.0041318374739483946;
        const float shift = -0.000157849851665374;
        const float m = 1. / (0.18 + shift);
        const float base2 = 1.4426950408889634;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 ylin = outColor.rgb * gain + offs;
        float3 ylog = base2 * log( ( outColor.rgb + shift ) * m );
        outColor.rgb.r = (outColor.rgb.r < xbrk) ? ylin.x : ylog.x;
        outColor.rgb.g = (outColor.rgb.g < xbrk) ? ylin.y : ylog.y;
        outColor.rgb.b = (outColor.rgb.b < xbrk) ? ylin.z : ylog.z;
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesR, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.r;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.r = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesG, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.g;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.g = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesB, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.b;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.b = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesM, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float3 t = outColor.rgb;
          float3 res;
          float3 tL = (t - x0) / (x1 - x0);
          float3 tM = (t - x1) / (x2 - x1);
          float3 tR = (t - x2) / (x3 - x2);
          float3 tR2 = (t - x3) / (x4 - x3);
          float3 tR3 = (t - x4) / (x5 - x4);
          float3 fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float3 fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float3 fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float3 fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float3 fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          res.r = (t.r < x1) ? fL.r : fM.r;
          res.g = (t.g < x1) ? fL.g : fM.g;
          res.b = (t.b < x1) ? fL.b : fM.b;
          res.r = (t.r > x2) ? fR.r : res.r;
          res.g = (t.g > x2) ? fR.g : res.g;
          res.b = (t.b > x2) ? fR.b : res.b;
          res.r = (t.r > x3) ? fR2.r : res.r;
          res.g = (t.g > x3) ? fR2.g : res.g;
          res.b = (t.b > x3) ? fR2.b : res.b;
          res.r = (t.r > x4) ? fR3.r : res.r;
          res.g = (t.g > x4) ? fR3.g : res.g;
          res.b = (t.b > x4) ? fR3.b : res.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x5) ? y5 + (t.r - x5) * m5 : res.r;
          res.g = (t.g > x5) ? y5 + (t.g - x5) * m5 : res.g;
          res.b = (t.b > x5) ? y5 + (t.b - x5) * m5 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsR;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsG;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsB;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsM;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesR;
        float mtest = m1;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesG;
        float mtest = m1;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesB;
        float mtest = m1;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesM;
        float mtest = m1;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t.r > x1) res.r = (aa * t.r + bb) * t.r + cc;
          if (t.g > x1) res.g = (aa * t.g + bb) * t.g + cc;
          if (t.b > x1) res.b = (aa * t.b + bb) * t.b + cc;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsR;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsG;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsB;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsM;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksR;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.r = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksG;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.g = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksB;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.b = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksM;
        m0 = 2. - m0;
        float mtest = m0;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          res = (res - x1) / gain + x1;
          outColor.rgb = res;
        }
      }
      float contrast = ocio_grading_tone_sContrast;
      if (contrast != 1.)
      {
        contrast = (contrast > 1.) ? 1. / (1.8125 - 0.8125 * min( contrast, 1.99 )) : 0.28125 + 0.71875 * max( contrast, 0.01 );
        const float pivot = 0.000000;
        float3 t = outColor.rgb;
        {
          const float x3 = 6.500000;
          const float y3 = 6.500000;
          const float y0 = pivot + (y3 - pivot) * 0.25;
          float m0 = contrast;
          float x0 = pivot + (y0 - pivot) / m0;
          float min_width = (x3 - x0) * 0.3;
          float m3 = 1. / m0;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x1 = x0;
          float x2 = 2. * center - x1;
          if (x2 > x3)
          {
            x2 = x3;
            x1 = 2. * center - x2;
          }
          else if ((x2 - x1) < min_width)
          {
            x2 = x1 + min_width;
            float new_center = (x2 + x1) * 0.5;
            m3 = (y3 - y0 + m0*x0 - new_center * m0) / (x3 - new_center);
          }
          float y1 = y0;
          float y2 = y1 + (m0 + m3) * (x2 - x1) * 0.5;
          outColor.rgb = (t - pivot) * contrast + pivot;
          float3 tR = (t - x1) / (x2 - x1);
          float3 res = tR * (x2 - x1) * ( tR * 0.5 * (m3 - m0) + m0 ) + y1;
          outColor.rgb.r = (t.r > x1) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g > x1) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b > x1) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r > x2) ? y2 + (t.r - x2) * m3 : outColor.rgb.r;
          outColor.rgb.g = (t.g > x2) ? y2 + (t.g - x2) * m3 : outColor.rgb.g;
          outColor.rgb.b = (t.b > x2) ? y2 + (t.b - x2) * m3 : outColor.rgb.b;
        }
        {
          const float x0 = -5.500000;
          const float y0 = -5.500000;
          const float y3 = pivot - (pivot - y0) * 0.25;
          float m3 = contrast;
          float x3 = pivot - (pivot - y3) / m3;
          float min_width = (x3 - x0) * 0.3;
          float m0 = 1. / m3;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x2 = x3;
          float x1 = 2. * center - x2;
          if (x1 < x0)
          {
            x1 = x0;
            x2 = 2. * center - x1;
          }
          else if ((x2 - x1) < min_width)
          {
            x1 = x2 - min_width;
            float new_center = (x2 + x1) * 0.5;
            m0 = (y3 - y0 - m3*x3 + new_center * m3) / (new_center - x0);
          }
          float y2 = y3;
          float y1 = y2 - (m0 + m3) * (x2 - x1) * 0.5;
          float3 tR = (t - x1) / (x2 - x1);
          float3 res = tR * (x2 - x1) * ( tR * 0.5 * (m3 - m0) + m0 ) + y1;
          outColor.rgb.r = (t.r < x2) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g < x2) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b < x2) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r < x1) ? y1 + (t.r - x1) * m0 : outColor.rgb.r;
          outColor.rgb.g = (t.g < x1) ? y1 + (t.g - x1) * m0 : outColor.rgb.g;
          outColor.rgb.b = (t.b < x1) ? y1 + (t.b - x1) * m0 : outColor.rgb.b;
        }
      }
      {
        const float ybrk = -5.5;
        const float shift = -0.000157849851665374;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 xlin = (outColor.rgb - offs) / gain;
        float3 xlog = pow( float3(2., 2., 2.), outColor.rgb ) * (0.18 + shift) - shift;
        outColor.rgb.r = (outColor.rgb.r < ybrk) ? xlin.x : xlog.x;
        outColor.rgb.g = (outColor.rgb.g < ybrk) ? xlin.y : xlog.y;
        outColor.rgb.b = (outColor.rgb.b < ybrk) ? xlin.z : xlog.z;
      }
      outColor = min( outColor, 65504. );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_tone_blacksR
    , ocio_grading_tone_blacksG
    , ocio_grading_tone_blacksB
    , ocio_grading_tone_blacksM
    , ocio_grading_tone_blacksStart
    , ocio_grading_tone_blacksWidth
    , ocio_grading_tone_shadowsR
    , ocio_grading_tone_shadowsG
    , ocio_grading_tone_shadowsB
    , ocio_grading_tone_shadowsM
    , ocio_grading_tone_shadowsStart
    , ocio_grading_tone_shadowsWidth
    , ocio_grading_tone_midtonesR
    , ocio_grading_tone_midtonesG
    , ocio_grading_tone_midtonesB
    , ocio_grading_tone_midtonesM
    , ocio_grading_tone_midtonesStart
    , ocio_grading_tone_midtonesWidth
    , ocio_grading_tone_highlightsR
    , ocio_grading_tone_highlightsG
    , ocio_grading_tone_highlightsB
    , ocio_grading_tone_highlightsM
    , ocio_grading_tone_highlightsStart
    , ocio_grading_tone_highlightsWidth
    , ocio_grading_tone_whitesR
    , ocio_grading_tone_whitesG
    , ocio_grading_tone_whitesB
    , ocio_grading_tone_whitesM
    , ocio_grading_tone_whitesStart
    , ocio_grading_tone_whitesWidth
    , ocio_grading_tone_sContrast
    , ocio_grading_tone_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "tone.lin.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_tone_blacksR", "ocio_grading_tone_blacksG", "ocio_grading_tone_blacksB", "ocio_grading_tone_blacksM", "ocio_grading_tone_blacksStart", "ocio_grading_tone_blacksWidth", "ocio_grading_tone_shadowsR", "ocio_grading_tone_shadowsG", "ocio_grading_tone_shadowsB", "ocio_grading_tone_shadowsM", "ocio_grading_tone_shadowsStart", "ocio_grading_tone_shadowsWidth", "ocio_grading_tone_midtonesR", "ocio_grading_tone_midtonesG", "ocio_grading_tone_midtonesB", "ocio_grading_tone_midtonesM", "ocio_grading_tone_midtonesStart", "ocio_grading_tone_midtonesWidth", "ocio_grading_tone_highlightsR", "ocio_grading_tone_highlightsG", "ocio_grading_tone_highlightsB", "ocio_grading_tone_highlightsM", "ocio_grading_tone_highlightsStart", "ocio_grading_tone_highlightsWidth", "ocio_grading_tone_whitesR", "ocio_grading_tone_whitesG", "ocio_grading_tone_whitesB", "ocio_grading_tone_whitesM", "ocio_grading_tone_whitesStart", "ocio_grading_tone_whitesWidth", "ocio_grading_tone_sContrast", "ocio_grading_tone_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
)
{
  this->ocio_grading_tone_blacksR = ocio_grading_tone_blacksR;
  this->ocio_grading_tone_blacksG = ocio_grading_tone_blacksG;
  this->ocio_grading_tone_blacksB = ocio_grading_tone_blacksB;
  this->ocio_grading_tone_blacksM = ocio_grading_tone_blacksM;
  this->ocio_grading_tone_blacksStart = ocio_grading_tone_blacksStart;
  this->ocio_grading_tone_blacksWidth = ocio_grading_tone_blacksWidth;
  this->ocio_grading_tone_shadowsR = ocio_grading_tone_shadowsR;
  this->ocio_grading_tone_shadowsG = ocio_grading_tone_shadowsG;
  this->ocio_grading_tone_shadowsB = ocio_grading_tone_shadowsB;
  this->ocio_grading_tone_shadowsM = ocio_grading_tone_shadowsM;
  this->ocio_grading_tone_shadowsStart = ocio_grading_tone_shadowsStart;
  this->ocio_grading_tone_shadowsWidth = ocio_grading_tone_shadowsWidth;
  this->ocio_grading_tone_midtonesR = ocio_grading_tone_midtonesR;
  this->ocio_grading_tone_midtonesG = ocio_grading_tone_midtonesG;
  this->ocio_grading_tone_midtonesB = ocio_grading_tone_midtonesB;
  this->ocio_grading_tone_midtonesM = ocio_grading_tone_midtonesM;
  this->ocio_grading_tone_midtonesStart = ocio_grading_tone_midtonesStart;
  this->ocio_grading_tone_midtonesWidth = ocio_grading_tone_midtonesWidth;
  this->ocio_grading_tone_highlightsR = ocio_grading_tone_highlightsR;
  this->ocio_grading_tone_highlightsG = ocio_grading_tone_highlightsG;
  this->ocio_grading_tone_highlightsB = ocio_grading_tone_highlightsB;
  this->ocio_grading_tone_highlightsM = ocio_grading_tone_highlightsM;
  this->ocio_grading_tone_highlightsStart = ocio_grading_tone_highlightsStart;
  this->ocio_grading_tone_highlightsWidth = ocio_grading_tone_highlightsWidth;
  this->ocio_grading_tone_whitesR = ocio_grading_tone_whitesR;
  this->ocio_grading_tone_whitesG = ocio_grading_tone_whitesG;
  this->ocio_grading_tone_whitesB = ocio_grading_tone_whitesB;
  this->ocio_grading_tone_whitesM = ocio_grading_tone_whitesM;
  this->ocio_grading_tone_whitesStart = ocio_grading_tone_whitesStart;
  this->ocio_grading_tone_whitesWidth = ocio_grading_tone_whitesWidth;
  this->ocio_grading_tone_sContrast = ocio_grading_tone_sContrast;
  this->ocio_grading_tone_localBypass = ocio_grading_tone_localBypass;
}


// Declaration of all variables

float ocio_grading_tone_blacksR;
float ocio_grading_tone_blacksG;
float ocio_grading_tone_blacksB;
float ocio_grading_tone_blacksM;
float ocio_grading_tone_blacksStart;
float ocio_grading_tone_blacksWidth;
float ocio_grading_tone_shadowsR;
float ocio_grading_tone_shadowsG;
float ocio_grading_tone_shadowsB;
float ocio_grading_tone_shadowsM;
float ocio_grading_tone_shadowsStart;
float ocio_grading_tone_shadowsWidth;
float ocio_grading_tone_midtonesR;
float ocio_grading_tone_midtonesG;
float ocio_grading_tone_midtonesB;
float ocio_grading_tone_midtonesM;
float ocio_grading_tone_midtonesStart;
float ocio_grading_tone_midtonesWidth;
float ocio_grading_tone_highlightsR;
float ocio_grading_tone_highlightsG;
float ocio_grading_tone_highlightsB;
float ocio_grading_tone_highlightsM;
float ocio_grading_tone_highlightsStart;
float ocio_grading_tone_highlightsWidth;
float ocio_grading_tone_whitesR;
float ocio_grading_tone_whitesG;
float ocio_grading_tone_whitesB;
float ocio_grading_tone_whitesM;
float ocio_grading_tone_whitesStart;
float ocio_grading_tone_whitesWidth;
float ocio_grading_tone_sContrast;
bool ocio_grading_tone_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingTone 'linear' inverse processing
  
  {
    if (!ocio_grading_tone_localBypass)
    {
      {
        const float xbrk = 0.0041318374739483946;
        const float shift = -0.000157849851665374;
        const float m = 1. / (0.18 + shift);
        const float base2 = 1.4426950408889634;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 ylin = outColor.rgb * gain + offs;
        float3 ylog = base2 * log( ( outColor.rgb + shift ) * m );
        outColor.rgb.r = (outColor.rgb.r < xbrk) ? ylin.x : ylog.x;
        outColor.rgb.g = (outColor.rgb.g < xbrk) ? ylin.y : ylog.y;
        outColor.rgb.b = (outColor.rgb.b < xbrk) ? ylin.z : ylog.z;
      }
      float contrast = ocio_grading_tone_sContrast;
      if (contrast != 1.)
      {
        contrast = (contrast > 1.) ? 1. / (1.8125 - 0.8125 * min( contrast, 1.99 )) : 0.28125 + 0.71875 * max( contrast, 0.01 );
        const float pivot = 0.000000;
        float3 t = outColor.rgb;
        {
          const float x3 = 6.500000;
          const float y3 = 6.500000;
          const float y0 = pivot + (y3 - pivot) * 0.25;
          float m0 = contrast;
          float x0 = pivot + (y0 - pivot) / m0;
          float min_width = (x3 - x0) * 0.3;
          float m3 = 1. / m0;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x1 = x0;
          float x2 = 2. * center - x1;
          if (x2 > x3)
          {
            x2 = x3;
            x1 = 2. * center - x2;
          }
          else if ((x2 - x1) < min_width)
          {
            x2 = x1 + min_width;
            float new_center = (x2 + x1) * 0.5;
            m3 = (y3 - y0 + m0*x0 - new_center * m0) / (x3 - new_center);
          }
          float y1 = y0;
          float y2 = y1 + (m0 + m3) * (x2 - x1) * 0.5;
          outColor.rgb = (t - pivot) / contrast + pivot;
          float3 c = y1 - t;
          float b = m0 * (x2 - x1);
          float a = (m3 - m0) * 0.5 * (x2 - x1);
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 res = (x2 - x1) * (-2. * c) / ( discrim + b ) + x1;
          outColor.rgb.r = (t.r > y1) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g > y1) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b > y1) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r > y2) ? x2 + (t.r - y2) / m3 : outColor.rgb.r;
          outColor.rgb.g = (t.g > y2) ? x2 + (t.g - y2) / m3 : outColor.rgb.g;
          outColor.rgb.b = (t.b > y2) ? x2 + (t.b - y2) / m3 : outColor.rgb.b;
        }
        {
          const float x0 = -5.500000;
          const float y0 = -5.500000;
          const float y3 = pivot - (pivot - y0) * 0.25;
          float m3 = contrast;
          float x3 = pivot - (pivot - y3) / m3;
          float min_width = (x3 - x0) * 0.3;
          float m0 = 1. / m3;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x2 = x3;
          float x1 = 2. * center - x2;
          if (x1 < x0)
          {
            x1 = x0;
            x2 = 2. * center - x1;
          }
          else if ((x2 - x1) < min_width)
          {
            x1 = x2 - min_width;
            float new_center = (x2 + x1) * 0.5;
            m0 = (y3 - y0 - m3*x3 + new_center * m3) / (new_center - x0);
          }
          float y2 = y3;
          float y1 = y2 - (m0 + m3) * (x2 - x1) * 0.5;
          float3 c = y1 - t;
          float b = m0 * (x2 - x1);
          float a = (m3 - m0) * 0.5 * (x2 - x1);
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 res = (x2 - x1) * (-2. * c) / ( discrim + b ) + x1;
          outColor.rgb.r = (t.r > y2) ? outColor.rgb.r : res.r;
          outColor.rgb.g = (t.g > y2) ? outColor.rgb.g : res.g;
          outColor.rgb.b = (t.b > y2) ? outColor.rgb.b : res.b;
          outColor.rgb.r = (t.r > y1) ? outColor.rgb.r : x1 + (t.r - y1) / m0;
          outColor.rgb.g = (t.g > y1) ? outColor.rgb.g : x1 + (t.g - y1) / m0;
          outColor.rgb.b = (t.b > y1) ? outColor.rgb.b : x1 + (t.b - y1) / m0;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksM;
        m0 = 2. - m0;
        float mtest = m0;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          res = (res - x1) / gain + x1;
          outColor.rgb = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksR;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.r = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksG;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.g = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksB;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsM;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsR;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsG;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsB;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesM;
        float mtest = m1;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float3 c = cc - t;
          float3 discrim = sqrt( bb * bb - 4. * aa * c );
          float3 res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res.r = (t.r < brk) ? res.r : res1.r;
          res.g = (t.g < brk) ? res.g : res1.g;
          res.b = (t.b < brk) ? res.b : res1.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesR;
        float mtest = m1;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesG;
        float mtest = m1;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesB;
        float mtest = m1;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsM;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsR;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsG;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsB;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesM, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float3 t = outColor.rgb;
          float3 outL;
          float3 outM;
          float3 outR;
          float3 outR2;
          float3 outR3;
          {
            float3 c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR3 =  tmp * (x5 - x4) + x4;
          }
          {
            float3 c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR2 =  tmp * (x4 - x3) + x3;
          }
          {
            float3 c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR =  tmp * (x3 - x2) + x2;
          }
          {
            float3 c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outM =  tmp * (x2 - x1) + x1;
          }
          {
            float3 c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outL =  tmp * (x1 - x0) + x0;
          }
          float3 res;
          res.r = (t.r < y1) ? outL.r : outM.r;
          res.g = (t.g < y1) ? outL.g : outM.g;
          res.b = (t.b < y1) ? outL.b : outM.b;
          res.r = (t.r > y2) ? outR.r : res.r;
          res.g = (t.g > y2) ? outR.g : res.g;
          res.b = (t.b > y2) ? outR.b : res.b;
          res.r = (t.r > y3) ? outR2.r : res.r;
          res.g = (t.g > y3) ? outR2.g : res.g;
          res.b = (t.b > y3) ? outR2.b : res.b;
          res.r = (t.r > y4) ? outR3.r : res.r;
          res.g = (t.g > y4) ? outR3.g : res.g;
          res.b = (t.b > y4) ? outR3.b : res.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) * m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) * m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) * m0 : res.b;
          res.r = (t.r > y5) ? x5 + (t.r - y5) * m5 : res.r;
          res.g = (t.g > y5) ? x5 + (t.g - y5) * m5 : res.g;
          res.b = (t.b > y5) ? x5 + (t.b - y5) * m5 : res.b;
          outColor.rgb = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesR, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.r;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.r = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesG, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.g;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.g = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesB, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = -5.500000;
          const float x5 = 7.500000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.b;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.b = res;
        }
      }
      {
        const float ybrk = -5.5;
        const float shift = -0.000157849851665374;
        const float gain = 363.034608563;
        const float offs = -7.;
        float3 xlin = (outColor.rgb - offs) / gain;
        float3 xlog = pow( float3(2., 2., 2.), outColor.rgb ) * (0.18 + shift) - shift;
        outColor.rgb.r = (outColor.rgb.r < ybrk) ? xlin.x : xlog.x;
        outColor.rgb.g = (outColor.rgb.g < ybrk) ? xlin.y : xlog.y;
        outColor.rgb.b = (outColor.rgb.b < ybrk) ? xlin.z : xlog.z;
      }
      outColor = min( outColor, 65504. );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_tone_blacksR
    , ocio_grading_tone_blacksG
    , ocio_grading_tone_blacksB
    , ocio_grading_tone_blacksM
    , ocio_grading_tone_blacksStart
    , ocio_grading_tone_blacksWidth
    , ocio_grading_tone_shadowsR
    , ocio_grading_tone_shadowsG
    , ocio_grading_tone_shadowsB
    , ocio_grading_tone_shadowsM
    , ocio_grading_tone_shadowsStart
    , ocio_grading_tone_shadowsWidth
    , ocio_grading_tone_midtonesR
    , ocio_grading_tone_midtonesG
    , ocio_grading_tone_midtonesB
    , ocio_grading_tone_midtonesM
    , ocio_grading_tone_midtonesStart
    , ocio_grading_tone_midtonesWidth
    , ocio_grading_tone_highlightsR
    , ocio_grading_tone_highlightsG
    , ocio_grading_tone_highlightsB
    , ocio_grading_tone_highlightsM
    , ocio_grading_tone_highlightsStart
    , ocio_grading_tone_highlightsWidth
    , ocio_grading_tone_whitesR
    , ocio_grading_tone_whitesG
    , ocio_grading_tone_whitesB
    , ocio_grading_tone_whitesM
    , ocio_grading_tone_whitesStart
    , ocio_grading_tone_whitesWidth
    , ocio_grading_tone_sContrast
    , ocio_grading_tone_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "tone.log.forward":
        return GradingShaderTemplate(names: ["ocio_grading_tone_blacksR", "ocio_grading_tone_blacksG", "ocio_grading_tone_blacksB", "ocio_grading_tone_blacksM", "ocio_grading_tone_blacksStart", "ocio_grading_tone_blacksWidth", "ocio_grading_tone_shadowsR", "ocio_grading_tone_shadowsG", "ocio_grading_tone_shadowsB", "ocio_grading_tone_shadowsM", "ocio_grading_tone_shadowsStart", "ocio_grading_tone_shadowsWidth", "ocio_grading_tone_midtonesR", "ocio_grading_tone_midtonesG", "ocio_grading_tone_midtonesB", "ocio_grading_tone_midtonesM", "ocio_grading_tone_midtonesStart", "ocio_grading_tone_midtonesWidth", "ocio_grading_tone_highlightsR", "ocio_grading_tone_highlightsG", "ocio_grading_tone_highlightsB", "ocio_grading_tone_highlightsM", "ocio_grading_tone_highlightsStart", "ocio_grading_tone_highlightsWidth", "ocio_grading_tone_whitesR", "ocio_grading_tone_whitesG", "ocio_grading_tone_whitesB", "ocio_grading_tone_whitesM", "ocio_grading_tone_whitesStart", "ocio_grading_tone_whitesWidth", "ocio_grading_tone_sContrast", "ocio_grading_tone_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
)
{
  this->ocio_grading_tone_blacksR = ocio_grading_tone_blacksR;
  this->ocio_grading_tone_blacksG = ocio_grading_tone_blacksG;
  this->ocio_grading_tone_blacksB = ocio_grading_tone_blacksB;
  this->ocio_grading_tone_blacksM = ocio_grading_tone_blacksM;
  this->ocio_grading_tone_blacksStart = ocio_grading_tone_blacksStart;
  this->ocio_grading_tone_blacksWidth = ocio_grading_tone_blacksWidth;
  this->ocio_grading_tone_shadowsR = ocio_grading_tone_shadowsR;
  this->ocio_grading_tone_shadowsG = ocio_grading_tone_shadowsG;
  this->ocio_grading_tone_shadowsB = ocio_grading_tone_shadowsB;
  this->ocio_grading_tone_shadowsM = ocio_grading_tone_shadowsM;
  this->ocio_grading_tone_shadowsStart = ocio_grading_tone_shadowsStart;
  this->ocio_grading_tone_shadowsWidth = ocio_grading_tone_shadowsWidth;
  this->ocio_grading_tone_midtonesR = ocio_grading_tone_midtonesR;
  this->ocio_grading_tone_midtonesG = ocio_grading_tone_midtonesG;
  this->ocio_grading_tone_midtonesB = ocio_grading_tone_midtonesB;
  this->ocio_grading_tone_midtonesM = ocio_grading_tone_midtonesM;
  this->ocio_grading_tone_midtonesStart = ocio_grading_tone_midtonesStart;
  this->ocio_grading_tone_midtonesWidth = ocio_grading_tone_midtonesWidth;
  this->ocio_grading_tone_highlightsR = ocio_grading_tone_highlightsR;
  this->ocio_grading_tone_highlightsG = ocio_grading_tone_highlightsG;
  this->ocio_grading_tone_highlightsB = ocio_grading_tone_highlightsB;
  this->ocio_grading_tone_highlightsM = ocio_grading_tone_highlightsM;
  this->ocio_grading_tone_highlightsStart = ocio_grading_tone_highlightsStart;
  this->ocio_grading_tone_highlightsWidth = ocio_grading_tone_highlightsWidth;
  this->ocio_grading_tone_whitesR = ocio_grading_tone_whitesR;
  this->ocio_grading_tone_whitesG = ocio_grading_tone_whitesG;
  this->ocio_grading_tone_whitesB = ocio_grading_tone_whitesB;
  this->ocio_grading_tone_whitesM = ocio_grading_tone_whitesM;
  this->ocio_grading_tone_whitesStart = ocio_grading_tone_whitesStart;
  this->ocio_grading_tone_whitesWidth = ocio_grading_tone_whitesWidth;
  this->ocio_grading_tone_sContrast = ocio_grading_tone_sContrast;
  this->ocio_grading_tone_localBypass = ocio_grading_tone_localBypass;
}


// Declaration of all variables

float ocio_grading_tone_blacksR;
float ocio_grading_tone_blacksG;
float ocio_grading_tone_blacksB;
float ocio_grading_tone_blacksM;
float ocio_grading_tone_blacksStart;
float ocio_grading_tone_blacksWidth;
float ocio_grading_tone_shadowsR;
float ocio_grading_tone_shadowsG;
float ocio_grading_tone_shadowsB;
float ocio_grading_tone_shadowsM;
float ocio_grading_tone_shadowsStart;
float ocio_grading_tone_shadowsWidth;
float ocio_grading_tone_midtonesR;
float ocio_grading_tone_midtonesG;
float ocio_grading_tone_midtonesB;
float ocio_grading_tone_midtonesM;
float ocio_grading_tone_midtonesStart;
float ocio_grading_tone_midtonesWidth;
float ocio_grading_tone_highlightsR;
float ocio_grading_tone_highlightsG;
float ocio_grading_tone_highlightsB;
float ocio_grading_tone_highlightsM;
float ocio_grading_tone_highlightsStart;
float ocio_grading_tone_highlightsWidth;
float ocio_grading_tone_whitesR;
float ocio_grading_tone_whitesG;
float ocio_grading_tone_whitesB;
float ocio_grading_tone_whitesM;
float ocio_grading_tone_whitesStart;
float ocio_grading_tone_whitesWidth;
float ocio_grading_tone_sContrast;
bool ocio_grading_tone_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingTone 'log' forward processing
  
  {
    if (!ocio_grading_tone_localBypass)
    {
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesR, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.r;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.r = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesG, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.g;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.g = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesB, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.b;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.b = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesM, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float3 t = outColor.rgb;
          float3 res;
          float3 tL = (t - x0) / (x1 - x0);
          float3 tM = (t - x1) / (x2 - x1);
          float3 tR = (t - x2) / (x3 - x2);
          float3 tR2 = (t - x3) / (x4 - x3);
          float3 tR3 = (t - x4) / (x5 - x4);
          float3 fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float3 fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float3 fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float3 fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float3 fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          res.r = (t.r < x1) ? fL.r : fM.r;
          res.g = (t.g < x1) ? fL.g : fM.g;
          res.b = (t.b < x1) ? fL.b : fM.b;
          res.r = (t.r > x2) ? fR.r : res.r;
          res.g = (t.g > x2) ? fR.g : res.g;
          res.b = (t.b > x2) ? fR.b : res.b;
          res.r = (t.r > x3) ? fR2.r : res.r;
          res.g = (t.g > x3) ? fR2.g : res.g;
          res.b = (t.b > x3) ? fR2.b : res.b;
          res.r = (t.r > x4) ? fR3.r : res.r;
          res.g = (t.g > x4) ? fR3.g : res.g;
          res.b = (t.b > x4) ? fR3.b : res.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x5) ? y5 + (t.r - x5) * m5 : res.r;
          res.g = (t.g > x5) ? y5 + (t.g - x5) * m5 : res.g;
          res.b = (t.b > x5) ? y5 + (t.b - x5) * m5 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsR;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsG;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsB;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsM;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesR;
        float mtest = m1;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesG;
        float mtest = m1;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesB;
        float mtest = m1;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesM;
        float mtest = m1;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t.r > x1) res.r = (aa * t.r + bb) * t.r + cc;
          if (t.g > x1) res.g = (aa * t.g + bb) * t.g + cc;
          if (t.b > x1) res.b = (aa * t.b + bb) * t.b + cc;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsR;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsG;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsB;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsM;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksR;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.r = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksG;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.g = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksB;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.b = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksM;
        m0 = 2. - m0;
        float mtest = m0;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          res = (res - x1) / gain + x1;
          outColor.rgb = res;
        }
      }
      float contrast = ocio_grading_tone_sContrast;
      if (contrast != 1.)
      {
        contrast = (contrast > 1.) ? 1. / (1.8125 - 0.8125 * min( contrast, 1.99 )) : 0.28125 + 0.71875 * max( contrast, 0.01 );
        const float pivot = 0.400000;
        float3 t = outColor.rgb;
        {
          const float x3 = 1.000000;
          const float y3 = 1.000000;
          const float y0 = pivot + (y3 - pivot) * 0.25;
          float m0 = contrast;
          float x0 = pivot + (y0 - pivot) / m0;
          float min_width = (x3 - x0) * 0.3;
          float m3 = 1. / m0;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x1 = x0;
          float x2 = 2. * center - x1;
          if (x2 > x3)
          {
            x2 = x3;
            x1 = 2. * center - x2;
          }
          else if ((x2 - x1) < min_width)
          {
            x2 = x1 + min_width;
            float new_center = (x2 + x1) * 0.5;
            m3 = (y3 - y0 + m0*x0 - new_center * m0) / (x3 - new_center);
          }
          float y1 = y0;
          float y2 = y1 + (m0 + m3) * (x2 - x1) * 0.5;
          outColor.rgb = (t - pivot) * contrast + pivot;
          float3 tR = (t - x1) / (x2 - x1);
          float3 res = tR * (x2 - x1) * ( tR * 0.5 * (m3 - m0) + m0 ) + y1;
          outColor.rgb.r = (t.r > x1) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g > x1) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b > x1) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r > x2) ? y2 + (t.r - x2) * m3 : outColor.rgb.r;
          outColor.rgb.g = (t.g > x2) ? y2 + (t.g - x2) * m3 : outColor.rgb.g;
          outColor.rgb.b = (t.b > x2) ? y2 + (t.b - x2) * m3 : outColor.rgb.b;
        }
        {
          const float x0 = 0.000000;
          const float y0 = 0.000000;
          const float y3 = pivot - (pivot - y0) * 0.25;
          float m3 = contrast;
          float x3 = pivot - (pivot - y3) / m3;
          float min_width = (x3 - x0) * 0.3;
          float m0 = 1. / m3;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x2 = x3;
          float x1 = 2. * center - x2;
          if (x1 < x0)
          {
            x1 = x0;
            x2 = 2. * center - x1;
          }
          else if ((x2 - x1) < min_width)
          {
            x1 = x2 - min_width;
            float new_center = (x2 + x1) * 0.5;
            m0 = (y3 - y0 - m3*x3 + new_center * m3) / (new_center - x0);
          }
          float y2 = y3;
          float y1 = y2 - (m0 + m3) * (x2 - x1) * 0.5;
          float3 tR = (t - x1) / (x2 - x1);
          float3 res = tR * (x2 - x1) * ( tR * 0.5 * (m3 - m0) + m0 ) + y1;
          outColor.rgb.r = (t.r < x2) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g < x2) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b < x2) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r < x1) ? y1 + (t.r - x1) * m0 : outColor.rgb.r;
          outColor.rgb.g = (t.g < x1) ? y1 + (t.g - x1) * m0 : outColor.rgb.g;
          outColor.rgb.b = (t.b < x1) ? y1 + (t.b - x1) * m0 : outColor.rgb.b;
        }
      }
      outColor = min( outColor, 65504. );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_tone_blacksR
    , ocio_grading_tone_blacksG
    , ocio_grading_tone_blacksB
    , ocio_grading_tone_blacksM
    , ocio_grading_tone_blacksStart
    , ocio_grading_tone_blacksWidth
    , ocio_grading_tone_shadowsR
    , ocio_grading_tone_shadowsG
    , ocio_grading_tone_shadowsB
    , ocio_grading_tone_shadowsM
    , ocio_grading_tone_shadowsStart
    , ocio_grading_tone_shadowsWidth
    , ocio_grading_tone_midtonesR
    , ocio_grading_tone_midtonesG
    , ocio_grading_tone_midtonesB
    , ocio_grading_tone_midtonesM
    , ocio_grading_tone_midtonesStart
    , ocio_grading_tone_midtonesWidth
    , ocio_grading_tone_highlightsR
    , ocio_grading_tone_highlightsG
    , ocio_grading_tone_highlightsB
    , ocio_grading_tone_highlightsM
    , ocio_grading_tone_highlightsStart
    , ocio_grading_tone_highlightsWidth
    , ocio_grading_tone_whitesR
    , ocio_grading_tone_whitesG
    , ocio_grading_tone_whitesB
    , ocio_grading_tone_whitesM
    , ocio_grading_tone_whitesStart
    , ocio_grading_tone_whitesWidth
    , ocio_grading_tone_sContrast
    , ocio_grading_tone_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "tone.log.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_tone_blacksR", "ocio_grading_tone_blacksG", "ocio_grading_tone_blacksB", "ocio_grading_tone_blacksM", "ocio_grading_tone_blacksStart", "ocio_grading_tone_blacksWidth", "ocio_grading_tone_shadowsR", "ocio_grading_tone_shadowsG", "ocio_grading_tone_shadowsB", "ocio_grading_tone_shadowsM", "ocio_grading_tone_shadowsStart", "ocio_grading_tone_shadowsWidth", "ocio_grading_tone_midtonesR", "ocio_grading_tone_midtonesG", "ocio_grading_tone_midtonesB", "ocio_grading_tone_midtonesM", "ocio_grading_tone_midtonesStart", "ocio_grading_tone_midtonesWidth", "ocio_grading_tone_highlightsR", "ocio_grading_tone_highlightsG", "ocio_grading_tone_highlightsB", "ocio_grading_tone_highlightsM", "ocio_grading_tone_highlightsStart", "ocio_grading_tone_highlightsWidth", "ocio_grading_tone_whitesR", "ocio_grading_tone_whitesG", "ocio_grading_tone_whitesB", "ocio_grading_tone_whitesM", "ocio_grading_tone_whitesStart", "ocio_grading_tone_whitesWidth", "ocio_grading_tone_sContrast", "ocio_grading_tone_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
)
{
  this->ocio_grading_tone_blacksR = ocio_grading_tone_blacksR;
  this->ocio_grading_tone_blacksG = ocio_grading_tone_blacksG;
  this->ocio_grading_tone_blacksB = ocio_grading_tone_blacksB;
  this->ocio_grading_tone_blacksM = ocio_grading_tone_blacksM;
  this->ocio_grading_tone_blacksStart = ocio_grading_tone_blacksStart;
  this->ocio_grading_tone_blacksWidth = ocio_grading_tone_blacksWidth;
  this->ocio_grading_tone_shadowsR = ocio_grading_tone_shadowsR;
  this->ocio_grading_tone_shadowsG = ocio_grading_tone_shadowsG;
  this->ocio_grading_tone_shadowsB = ocio_grading_tone_shadowsB;
  this->ocio_grading_tone_shadowsM = ocio_grading_tone_shadowsM;
  this->ocio_grading_tone_shadowsStart = ocio_grading_tone_shadowsStart;
  this->ocio_grading_tone_shadowsWidth = ocio_grading_tone_shadowsWidth;
  this->ocio_grading_tone_midtonesR = ocio_grading_tone_midtonesR;
  this->ocio_grading_tone_midtonesG = ocio_grading_tone_midtonesG;
  this->ocio_grading_tone_midtonesB = ocio_grading_tone_midtonesB;
  this->ocio_grading_tone_midtonesM = ocio_grading_tone_midtonesM;
  this->ocio_grading_tone_midtonesStart = ocio_grading_tone_midtonesStart;
  this->ocio_grading_tone_midtonesWidth = ocio_grading_tone_midtonesWidth;
  this->ocio_grading_tone_highlightsR = ocio_grading_tone_highlightsR;
  this->ocio_grading_tone_highlightsG = ocio_grading_tone_highlightsG;
  this->ocio_grading_tone_highlightsB = ocio_grading_tone_highlightsB;
  this->ocio_grading_tone_highlightsM = ocio_grading_tone_highlightsM;
  this->ocio_grading_tone_highlightsStart = ocio_grading_tone_highlightsStart;
  this->ocio_grading_tone_highlightsWidth = ocio_grading_tone_highlightsWidth;
  this->ocio_grading_tone_whitesR = ocio_grading_tone_whitesR;
  this->ocio_grading_tone_whitesG = ocio_grading_tone_whitesG;
  this->ocio_grading_tone_whitesB = ocio_grading_tone_whitesB;
  this->ocio_grading_tone_whitesM = ocio_grading_tone_whitesM;
  this->ocio_grading_tone_whitesStart = ocio_grading_tone_whitesStart;
  this->ocio_grading_tone_whitesWidth = ocio_grading_tone_whitesWidth;
  this->ocio_grading_tone_sContrast = ocio_grading_tone_sContrast;
  this->ocio_grading_tone_localBypass = ocio_grading_tone_localBypass;
}


// Declaration of all variables

float ocio_grading_tone_blacksR;
float ocio_grading_tone_blacksG;
float ocio_grading_tone_blacksB;
float ocio_grading_tone_blacksM;
float ocio_grading_tone_blacksStart;
float ocio_grading_tone_blacksWidth;
float ocio_grading_tone_shadowsR;
float ocio_grading_tone_shadowsG;
float ocio_grading_tone_shadowsB;
float ocio_grading_tone_shadowsM;
float ocio_grading_tone_shadowsStart;
float ocio_grading_tone_shadowsWidth;
float ocio_grading_tone_midtonesR;
float ocio_grading_tone_midtonesG;
float ocio_grading_tone_midtonesB;
float ocio_grading_tone_midtonesM;
float ocio_grading_tone_midtonesStart;
float ocio_grading_tone_midtonesWidth;
float ocio_grading_tone_highlightsR;
float ocio_grading_tone_highlightsG;
float ocio_grading_tone_highlightsB;
float ocio_grading_tone_highlightsM;
float ocio_grading_tone_highlightsStart;
float ocio_grading_tone_highlightsWidth;
float ocio_grading_tone_whitesR;
float ocio_grading_tone_whitesG;
float ocio_grading_tone_whitesB;
float ocio_grading_tone_whitesM;
float ocio_grading_tone_whitesStart;
float ocio_grading_tone_whitesWidth;
float ocio_grading_tone_sContrast;
bool ocio_grading_tone_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingTone 'log' inverse processing
  
  {
    if (!ocio_grading_tone_localBypass)
    {
      float contrast = ocio_grading_tone_sContrast;
      if (contrast != 1.)
      {
        contrast = (contrast > 1.) ? 1. / (1.8125 - 0.8125 * min( contrast, 1.99 )) : 0.28125 + 0.71875 * max( contrast, 0.01 );
        const float pivot = 0.400000;
        float3 t = outColor.rgb;
        {
          const float x3 = 1.000000;
          const float y3 = 1.000000;
          const float y0 = pivot + (y3 - pivot) * 0.25;
          float m0 = contrast;
          float x0 = pivot + (y0 - pivot) / m0;
          float min_width = (x3 - x0) * 0.3;
          float m3 = 1. / m0;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x1 = x0;
          float x2 = 2. * center - x1;
          if (x2 > x3)
          {
            x2 = x3;
            x1 = 2. * center - x2;
          }
          else if ((x2 - x1) < min_width)
          {
            x2 = x1 + min_width;
            float new_center = (x2 + x1) * 0.5;
            m3 = (y3 - y0 + m0*x0 - new_center * m0) / (x3 - new_center);
          }
          float y1 = y0;
          float y2 = y1 + (m0 + m3) * (x2 - x1) * 0.5;
          outColor.rgb = (t - pivot) / contrast + pivot;
          float3 c = y1 - t;
          float b = m0 * (x2 - x1);
          float a = (m3 - m0) * 0.5 * (x2 - x1);
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 res = (x2 - x1) * (-2. * c) / ( discrim + b ) + x1;
          outColor.rgb.r = (t.r > y1) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g > y1) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b > y1) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r > y2) ? x2 + (t.r - y2) / m3 : outColor.rgb.r;
          outColor.rgb.g = (t.g > y2) ? x2 + (t.g - y2) / m3 : outColor.rgb.g;
          outColor.rgb.b = (t.b > y2) ? x2 + (t.b - y2) / m3 : outColor.rgb.b;
        }
        {
          const float x0 = 0.000000;
          const float y0 = 0.000000;
          const float y3 = pivot - (pivot - y0) * 0.25;
          float m3 = contrast;
          float x3 = pivot - (pivot - y3) / m3;
          float min_width = (x3 - x0) * 0.3;
          float m0 = 1. / m3;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x2 = x3;
          float x1 = 2. * center - x2;
          if (x1 < x0)
          {
            x1 = x0;
            x2 = 2. * center - x1;
          }
          else if ((x2 - x1) < min_width)
          {
            x1 = x2 - min_width;
            float new_center = (x2 + x1) * 0.5;
            m0 = (y3 - y0 - m3*x3 + new_center * m3) / (new_center - x0);
          }
          float y2 = y3;
          float y1 = y2 - (m0 + m3) * (x2 - x1) * 0.5;
          float3 c = y1 - t;
          float b = m0 * (x2 - x1);
          float a = (m3 - m0) * 0.5 * (x2 - x1);
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 res = (x2 - x1) * (-2. * c) / ( discrim + b ) + x1;
          outColor.rgb.r = (t.r > y2) ? outColor.rgb.r : res.r;
          outColor.rgb.g = (t.g > y2) ? outColor.rgb.g : res.g;
          outColor.rgb.b = (t.b > y2) ? outColor.rgb.b : res.b;
          outColor.rgb.r = (t.r > y1) ? outColor.rgb.r : x1 + (t.r - y1) / m0;
          outColor.rgb.g = (t.g > y1) ? outColor.rgb.g : x1 + (t.g - y1) / m0;
          outColor.rgb.b = (t.b > y1) ? outColor.rgb.b : x1 + (t.b - y1) / m0;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksM;
        m0 = 2. - m0;
        float mtest = m0;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          res = (res - x1) / gain + x1;
          outColor.rgb = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksR;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.r = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksG;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.g = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksB;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsM;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsR;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsG;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsB;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesM;
        float mtest = m1;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float3 c = cc - t;
          float3 discrim = sqrt( bb * bb - 4. * aa * c );
          float3 res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res.r = (t.r < brk) ? res.r : res1.r;
          res.g = (t.g < brk) ? res.g : res1.g;
          res.b = (t.b < brk) ? res.b : res1.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesR;
        float mtest = m1;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesG;
        float mtest = m1;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesB;
        float mtest = m1;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsM;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsR;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsG;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsB;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesM, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float3 t = outColor.rgb;
          float3 outL;
          float3 outM;
          float3 outR;
          float3 outR2;
          float3 outR3;
          {
            float3 c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR3 =  tmp * (x5 - x4) + x4;
          }
          {
            float3 c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR2 =  tmp * (x4 - x3) + x3;
          }
          {
            float3 c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR =  tmp * (x3 - x2) + x2;
          }
          {
            float3 c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outM =  tmp * (x2 - x1) + x1;
          }
          {
            float3 c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outL =  tmp * (x1 - x0) + x0;
          }
          float3 res;
          res.r = (t.r < y1) ? outL.r : outM.r;
          res.g = (t.g < y1) ? outL.g : outM.g;
          res.b = (t.b < y1) ? outL.b : outM.b;
          res.r = (t.r > y2) ? outR.r : res.r;
          res.g = (t.g > y2) ? outR.g : res.g;
          res.b = (t.b > y2) ? outR.b : res.b;
          res.r = (t.r > y3) ? outR2.r : res.r;
          res.g = (t.g > y3) ? outR2.g : res.g;
          res.b = (t.b > y3) ? outR2.b : res.b;
          res.r = (t.r > y4) ? outR3.r : res.r;
          res.g = (t.g > y4) ? outR3.g : res.g;
          res.b = (t.b > y4) ? outR3.b : res.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) * m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) * m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) * m0 : res.b;
          res.r = (t.r > y5) ? x5 + (t.r - y5) * m5 : res.r;
          res.g = (t.g > y5) ? x5 + (t.g - y5) * m5 : res.g;
          res.b = (t.b > y5) ? x5 + (t.b - y5) * m5 : res.b;
          outColor.rgb = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesR, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.r;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.r = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesG, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.g;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.g = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesB, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.b;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.b = res;
        }
      }
      outColor = min( outColor, 65504. );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_tone_blacksR
    , ocio_grading_tone_blacksG
    , ocio_grading_tone_blacksB
    , ocio_grading_tone_blacksM
    , ocio_grading_tone_blacksStart
    , ocio_grading_tone_blacksWidth
    , ocio_grading_tone_shadowsR
    , ocio_grading_tone_shadowsG
    , ocio_grading_tone_shadowsB
    , ocio_grading_tone_shadowsM
    , ocio_grading_tone_shadowsStart
    , ocio_grading_tone_shadowsWidth
    , ocio_grading_tone_midtonesR
    , ocio_grading_tone_midtonesG
    , ocio_grading_tone_midtonesB
    , ocio_grading_tone_midtonesM
    , ocio_grading_tone_midtonesStart
    , ocio_grading_tone_midtonesWidth
    , ocio_grading_tone_highlightsR
    , ocio_grading_tone_highlightsG
    , ocio_grading_tone_highlightsB
    , ocio_grading_tone_highlightsM
    , ocio_grading_tone_highlightsStart
    , ocio_grading_tone_highlightsWidth
    , ocio_grading_tone_whitesR
    , ocio_grading_tone_whitesG
    , ocio_grading_tone_whitesB
    , ocio_grading_tone_whitesM
    , ocio_grading_tone_whitesStart
    , ocio_grading_tone_whitesWidth
    , ocio_grading_tone_sContrast
    , ocio_grading_tone_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "tone.video.forward":
        return GradingShaderTemplate(names: ["ocio_grading_tone_blacksR", "ocio_grading_tone_blacksG", "ocio_grading_tone_blacksB", "ocio_grading_tone_blacksM", "ocio_grading_tone_blacksStart", "ocio_grading_tone_blacksWidth", "ocio_grading_tone_shadowsR", "ocio_grading_tone_shadowsG", "ocio_grading_tone_shadowsB", "ocio_grading_tone_shadowsM", "ocio_grading_tone_shadowsStart", "ocio_grading_tone_shadowsWidth", "ocio_grading_tone_midtonesR", "ocio_grading_tone_midtonesG", "ocio_grading_tone_midtonesB", "ocio_grading_tone_midtonesM", "ocio_grading_tone_midtonesStart", "ocio_grading_tone_midtonesWidth", "ocio_grading_tone_highlightsR", "ocio_grading_tone_highlightsG", "ocio_grading_tone_highlightsB", "ocio_grading_tone_highlightsM", "ocio_grading_tone_highlightsStart", "ocio_grading_tone_highlightsWidth", "ocio_grading_tone_whitesR", "ocio_grading_tone_whitesG", "ocio_grading_tone_whitesB", "ocio_grading_tone_whitesM", "ocio_grading_tone_whitesStart", "ocio_grading_tone_whitesWidth", "ocio_grading_tone_sContrast", "ocio_grading_tone_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
)
{
  this->ocio_grading_tone_blacksR = ocio_grading_tone_blacksR;
  this->ocio_grading_tone_blacksG = ocio_grading_tone_blacksG;
  this->ocio_grading_tone_blacksB = ocio_grading_tone_blacksB;
  this->ocio_grading_tone_blacksM = ocio_grading_tone_blacksM;
  this->ocio_grading_tone_blacksStart = ocio_grading_tone_blacksStart;
  this->ocio_grading_tone_blacksWidth = ocio_grading_tone_blacksWidth;
  this->ocio_grading_tone_shadowsR = ocio_grading_tone_shadowsR;
  this->ocio_grading_tone_shadowsG = ocio_grading_tone_shadowsG;
  this->ocio_grading_tone_shadowsB = ocio_grading_tone_shadowsB;
  this->ocio_grading_tone_shadowsM = ocio_grading_tone_shadowsM;
  this->ocio_grading_tone_shadowsStart = ocio_grading_tone_shadowsStart;
  this->ocio_grading_tone_shadowsWidth = ocio_grading_tone_shadowsWidth;
  this->ocio_grading_tone_midtonesR = ocio_grading_tone_midtonesR;
  this->ocio_grading_tone_midtonesG = ocio_grading_tone_midtonesG;
  this->ocio_grading_tone_midtonesB = ocio_grading_tone_midtonesB;
  this->ocio_grading_tone_midtonesM = ocio_grading_tone_midtonesM;
  this->ocio_grading_tone_midtonesStart = ocio_grading_tone_midtonesStart;
  this->ocio_grading_tone_midtonesWidth = ocio_grading_tone_midtonesWidth;
  this->ocio_grading_tone_highlightsR = ocio_grading_tone_highlightsR;
  this->ocio_grading_tone_highlightsG = ocio_grading_tone_highlightsG;
  this->ocio_grading_tone_highlightsB = ocio_grading_tone_highlightsB;
  this->ocio_grading_tone_highlightsM = ocio_grading_tone_highlightsM;
  this->ocio_grading_tone_highlightsStart = ocio_grading_tone_highlightsStart;
  this->ocio_grading_tone_highlightsWidth = ocio_grading_tone_highlightsWidth;
  this->ocio_grading_tone_whitesR = ocio_grading_tone_whitesR;
  this->ocio_grading_tone_whitesG = ocio_grading_tone_whitesG;
  this->ocio_grading_tone_whitesB = ocio_grading_tone_whitesB;
  this->ocio_grading_tone_whitesM = ocio_grading_tone_whitesM;
  this->ocio_grading_tone_whitesStart = ocio_grading_tone_whitesStart;
  this->ocio_grading_tone_whitesWidth = ocio_grading_tone_whitesWidth;
  this->ocio_grading_tone_sContrast = ocio_grading_tone_sContrast;
  this->ocio_grading_tone_localBypass = ocio_grading_tone_localBypass;
}


// Declaration of all variables

float ocio_grading_tone_blacksR;
float ocio_grading_tone_blacksG;
float ocio_grading_tone_blacksB;
float ocio_grading_tone_blacksM;
float ocio_grading_tone_blacksStart;
float ocio_grading_tone_blacksWidth;
float ocio_grading_tone_shadowsR;
float ocio_grading_tone_shadowsG;
float ocio_grading_tone_shadowsB;
float ocio_grading_tone_shadowsM;
float ocio_grading_tone_shadowsStart;
float ocio_grading_tone_shadowsWidth;
float ocio_grading_tone_midtonesR;
float ocio_grading_tone_midtonesG;
float ocio_grading_tone_midtonesB;
float ocio_grading_tone_midtonesM;
float ocio_grading_tone_midtonesStart;
float ocio_grading_tone_midtonesWidth;
float ocio_grading_tone_highlightsR;
float ocio_grading_tone_highlightsG;
float ocio_grading_tone_highlightsB;
float ocio_grading_tone_highlightsM;
float ocio_grading_tone_highlightsStart;
float ocio_grading_tone_highlightsWidth;
float ocio_grading_tone_whitesR;
float ocio_grading_tone_whitesG;
float ocio_grading_tone_whitesB;
float ocio_grading_tone_whitesM;
float ocio_grading_tone_whitesStart;
float ocio_grading_tone_whitesWidth;
float ocio_grading_tone_sContrast;
bool ocio_grading_tone_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingTone 'video' forward processing
  
  {
    if (!ocio_grading_tone_localBypass)
    {
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesR, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.r;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.r = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesG, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.g;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.g = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesB, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.b;
          float tL = (t - x0) / (x1 - x0);
          float tM = (t - x1) / (x2 - x1);
          float tR = (t - x2) / (x3 - x2);
          float tR2 = (t - x3) / (x4 - x3);
          float tR3 = (t - x4) / (x5 - x4);
          float fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          float res = (t < x1) ? fL : fM;
          if (t > x2) res = fR;
          if (t > x3) res = fR2;
          if (t > x4) res = fR3;
          if (t < x0) res = y0 + (t - x0) * m0;
          if (t > x5) res = y5 + (t - x5) * m5;
          outColor.rgb.b = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesM, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float3 t = outColor.rgb;
          float3 res;
          float3 tL = (t - x0) / (x1 - x0);
          float3 tM = (t - x1) / (x2 - x1);
          float3 tR = (t - x2) / (x3 - x2);
          float3 tR2 = (t - x3) / (x4 - x3);
          float3 tR3 = (t - x4) / (x5 - x4);
          float3 fL = tL * (x1 - x0) * ( tL * 0.5 * (m1 - m0) + m0 ) + y0;
          float3 fM = tM * (x2 - x1) * ( tM * 0.5 * (m2 - m1) + m1 ) + y1;
          float3 fR = tR * (x3 - x2) * ( tR * 0.5 * (m3 - m2) + m2 ) + y2;
          float3 fR2 = tR2 * (x4 - x3) * ( tR2 * 0.5 * (m4 - m3) + m3 ) + y3;
          float3 fR3 = tR3 * (x5 - x4) * ( tR3 * 0.5 * (m5 - m4) + m4 ) + y4;
          res.r = (t.r < x1) ? fL.r : fM.r;
          res.g = (t.g < x1) ? fL.g : fM.g;
          res.b = (t.b < x1) ? fL.b : fM.b;
          res.r = (t.r > x2) ? fR.r : res.r;
          res.g = (t.g > x2) ? fR.g : res.g;
          res.b = (t.b > x2) ? fR.b : res.b;
          res.r = (t.r > x3) ? fR2.r : res.r;
          res.g = (t.g > x3) ? fR2.g : res.g;
          res.b = (t.b > x3) ? fR2.b : res.b;
          res.r = (t.r > x4) ? fR3.r : res.r;
          res.g = (t.g > x4) ? fR3.g : res.g;
          res.b = (t.b > x4) ? fR3.b : res.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x5) ? y5 + (t.r - x5) * m5 : res.r;
          res.g = (t.g > x5) ? y5 + (t.g - x5) * m5 : res.g;
          res.b = (t.b > x5) ? y5 + (t.b - x5) * m5 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsR;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsG;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsB;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsM;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesR;
        float mtest = m1;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesG;
        float mtest = m1;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesB;
        float mtest = m1;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t > x1) res = (aa * t  + bb) * t + cc;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesM;
        float mtest = m1;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          if (t.r > x1) res.r = (aa * t.r + bb) * t.r + cc;
          if (t.g > x1) res.g = (aa * t.g + bb) * t.g + cc;
          if (t.b > x1) res.b = (aa * t.b + bb) * t.b + cc;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsR;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsG;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsB;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsM;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksR;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.r = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksG;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.g = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksB;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.b = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksM;
        m0 = 2. - m0;
        float mtest = m0;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          res = (res - x1) / gain + x1;
          outColor.rgb = res;
        }
      }
      float contrast = ocio_grading_tone_sContrast;
      if (contrast != 1.)
      {
        contrast = (contrast > 1.) ? 1. / (1.8125 - 0.8125 * min( contrast, 1.99 )) : 0.28125 + 0.71875 * max( contrast, 0.01 );
        const float pivot = 0.400000;
        float3 t = outColor.rgb;
        {
          const float x3 = 1.000000;
          const float y3 = 1.000000;
          const float y0 = pivot + (y3 - pivot) * 0.25;
          float m0 = contrast;
          float x0 = pivot + (y0 - pivot) / m0;
          float min_width = (x3 - x0) * 0.3;
          float m3 = 1. / m0;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x1 = x0;
          float x2 = 2. * center - x1;
          if (x2 > x3)
          {
            x2 = x3;
            x1 = 2. * center - x2;
          }
          else if ((x2 - x1) < min_width)
          {
            x2 = x1 + min_width;
            float new_center = (x2 + x1) * 0.5;
            m3 = (y3 - y0 + m0*x0 - new_center * m0) / (x3 - new_center);
          }
          float y1 = y0;
          float y2 = y1 + (m0 + m3) * (x2 - x1) * 0.5;
          outColor.rgb = (t - pivot) * contrast + pivot;
          float3 tR = (t - x1) / (x2 - x1);
          float3 res = tR * (x2 - x1) * ( tR * 0.5 * (m3 - m0) + m0 ) + y1;
          outColor.rgb.r = (t.r > x1) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g > x1) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b > x1) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r > x2) ? y2 + (t.r - x2) * m3 : outColor.rgb.r;
          outColor.rgb.g = (t.g > x2) ? y2 + (t.g - x2) * m3 : outColor.rgb.g;
          outColor.rgb.b = (t.b > x2) ? y2 + (t.b - x2) * m3 : outColor.rgb.b;
        }
        {
          const float x0 = 0.000000;
          const float y0 = 0.000000;
          const float y3 = pivot - (pivot - y0) * 0.25;
          float m3 = contrast;
          float x3 = pivot - (pivot - y3) / m3;
          float min_width = (x3 - x0) * 0.3;
          float m0 = 1. / m3;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x2 = x3;
          float x1 = 2. * center - x2;
          if (x1 < x0)
          {
            x1 = x0;
            x2 = 2. * center - x1;
          }
          else if ((x2 - x1) < min_width)
          {
            x1 = x2 - min_width;
            float new_center = (x2 + x1) * 0.5;
            m0 = (y3 - y0 - m3*x3 + new_center * m3) / (new_center - x0);
          }
          float y2 = y3;
          float y1 = y2 - (m0 + m3) * (x2 - x1) * 0.5;
          float3 tR = (t - x1) / (x2 - x1);
          float3 res = tR * (x2 - x1) * ( tR * 0.5 * (m3 - m0) + m0 ) + y1;
          outColor.rgb.r = (t.r < x2) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g < x2) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b < x2) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r < x1) ? y1 + (t.r - x1) * m0 : outColor.rgb.r;
          outColor.rgb.g = (t.g < x1) ? y1 + (t.g - x1) * m0 : outColor.rgb.g;
          outColor.rgb.b = (t.b < x1) ? y1 + (t.b - x1) * m0 : outColor.rgb.b;
        }
      }
      outColor = min( outColor, 65504. );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_tone_blacksR
    , ocio_grading_tone_blacksG
    , ocio_grading_tone_blacksB
    , ocio_grading_tone_blacksM
    , ocio_grading_tone_blacksStart
    , ocio_grading_tone_blacksWidth
    , ocio_grading_tone_shadowsR
    , ocio_grading_tone_shadowsG
    , ocio_grading_tone_shadowsB
    , ocio_grading_tone_shadowsM
    , ocio_grading_tone_shadowsStart
    , ocio_grading_tone_shadowsWidth
    , ocio_grading_tone_midtonesR
    , ocio_grading_tone_midtonesG
    , ocio_grading_tone_midtonesB
    , ocio_grading_tone_midtonesM
    , ocio_grading_tone_midtonesStart
    , ocio_grading_tone_midtonesWidth
    , ocio_grading_tone_highlightsR
    , ocio_grading_tone_highlightsG
    , ocio_grading_tone_highlightsB
    , ocio_grading_tone_highlightsM
    , ocio_grading_tone_highlightsStart
    , ocio_grading_tone_highlightsWidth
    , ocio_grading_tone_whitesR
    , ocio_grading_tone_whitesG
    , ocio_grading_tone_whitesB
    , ocio_grading_tone_whitesM
    , ocio_grading_tone_whitesStart
    , ocio_grading_tone_whitesWidth
    , ocio_grading_tone_sContrast
    , ocio_grading_tone_localBypass
  ).grading_transform(inPixel);
}
"""#)
    case "tone.video.inverse":
        return GradingShaderTemplate(names: ["ocio_grading_tone_blacksR", "ocio_grading_tone_blacksG", "ocio_grading_tone_blacksB", "ocio_grading_tone_blacksM", "ocio_grading_tone_blacksStart", "ocio_grading_tone_blacksWidth", "ocio_grading_tone_shadowsR", "ocio_grading_tone_shadowsG", "ocio_grading_tone_shadowsB", "ocio_grading_tone_shadowsM", "ocio_grading_tone_shadowsStart", "ocio_grading_tone_shadowsWidth", "ocio_grading_tone_midtonesR", "ocio_grading_tone_midtonesG", "ocio_grading_tone_midtonesB", "ocio_grading_tone_midtonesM", "ocio_grading_tone_midtonesStart", "ocio_grading_tone_midtonesWidth", "ocio_grading_tone_highlightsR", "ocio_grading_tone_highlightsG", "ocio_grading_tone_highlightsB", "ocio_grading_tone_highlightsM", "ocio_grading_tone_highlightsStart", "ocio_grading_tone_highlightsWidth", "ocio_grading_tone_whitesR", "ocio_grading_tone_whitesG", "ocio_grading_tone_whitesB", "ocio_grading_tone_whitesM", "ocio_grading_tone_whitesStart", "ocio_grading_tone_whitesWidth", "ocio_grading_tone_sContrast", "ocio_grading_tone_localBypass"], lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], source: #"""

// Declaration of class wrapper

struct ocio_grading_transform
{
ocio_grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
)
{
  this->ocio_grading_tone_blacksR = ocio_grading_tone_blacksR;
  this->ocio_grading_tone_blacksG = ocio_grading_tone_blacksG;
  this->ocio_grading_tone_blacksB = ocio_grading_tone_blacksB;
  this->ocio_grading_tone_blacksM = ocio_grading_tone_blacksM;
  this->ocio_grading_tone_blacksStart = ocio_grading_tone_blacksStart;
  this->ocio_grading_tone_blacksWidth = ocio_grading_tone_blacksWidth;
  this->ocio_grading_tone_shadowsR = ocio_grading_tone_shadowsR;
  this->ocio_grading_tone_shadowsG = ocio_grading_tone_shadowsG;
  this->ocio_grading_tone_shadowsB = ocio_grading_tone_shadowsB;
  this->ocio_grading_tone_shadowsM = ocio_grading_tone_shadowsM;
  this->ocio_grading_tone_shadowsStart = ocio_grading_tone_shadowsStart;
  this->ocio_grading_tone_shadowsWidth = ocio_grading_tone_shadowsWidth;
  this->ocio_grading_tone_midtonesR = ocio_grading_tone_midtonesR;
  this->ocio_grading_tone_midtonesG = ocio_grading_tone_midtonesG;
  this->ocio_grading_tone_midtonesB = ocio_grading_tone_midtonesB;
  this->ocio_grading_tone_midtonesM = ocio_grading_tone_midtonesM;
  this->ocio_grading_tone_midtonesStart = ocio_grading_tone_midtonesStart;
  this->ocio_grading_tone_midtonesWidth = ocio_grading_tone_midtonesWidth;
  this->ocio_grading_tone_highlightsR = ocio_grading_tone_highlightsR;
  this->ocio_grading_tone_highlightsG = ocio_grading_tone_highlightsG;
  this->ocio_grading_tone_highlightsB = ocio_grading_tone_highlightsB;
  this->ocio_grading_tone_highlightsM = ocio_grading_tone_highlightsM;
  this->ocio_grading_tone_highlightsStart = ocio_grading_tone_highlightsStart;
  this->ocio_grading_tone_highlightsWidth = ocio_grading_tone_highlightsWidth;
  this->ocio_grading_tone_whitesR = ocio_grading_tone_whitesR;
  this->ocio_grading_tone_whitesG = ocio_grading_tone_whitesG;
  this->ocio_grading_tone_whitesB = ocio_grading_tone_whitesB;
  this->ocio_grading_tone_whitesM = ocio_grading_tone_whitesM;
  this->ocio_grading_tone_whitesStart = ocio_grading_tone_whitesStart;
  this->ocio_grading_tone_whitesWidth = ocio_grading_tone_whitesWidth;
  this->ocio_grading_tone_sContrast = ocio_grading_tone_sContrast;
  this->ocio_grading_tone_localBypass = ocio_grading_tone_localBypass;
}


// Declaration of all variables

float ocio_grading_tone_blacksR;
float ocio_grading_tone_blacksG;
float ocio_grading_tone_blacksB;
float ocio_grading_tone_blacksM;
float ocio_grading_tone_blacksStart;
float ocio_grading_tone_blacksWidth;
float ocio_grading_tone_shadowsR;
float ocio_grading_tone_shadowsG;
float ocio_grading_tone_shadowsB;
float ocio_grading_tone_shadowsM;
float ocio_grading_tone_shadowsStart;
float ocio_grading_tone_shadowsWidth;
float ocio_grading_tone_midtonesR;
float ocio_grading_tone_midtonesG;
float ocio_grading_tone_midtonesB;
float ocio_grading_tone_midtonesM;
float ocio_grading_tone_midtonesStart;
float ocio_grading_tone_midtonesWidth;
float ocio_grading_tone_highlightsR;
float ocio_grading_tone_highlightsG;
float ocio_grading_tone_highlightsB;
float ocio_grading_tone_highlightsM;
float ocio_grading_tone_highlightsStart;
float ocio_grading_tone_highlightsWidth;
float ocio_grading_tone_whitesR;
float ocio_grading_tone_whitesG;
float ocio_grading_tone_whitesB;
float ocio_grading_tone_whitesM;
float ocio_grading_tone_whitesStart;
float ocio_grading_tone_whitesWidth;
float ocio_grading_tone_sContrast;
bool ocio_grading_tone_localBypass;


// Declaration of the OCIO shader function

float4 grading_transform(float4 inPixel)
{
  float4 outColor = inPixel;
  
  // Add GradingTone 'video' inverse processing
  
  {
    if (!ocio_grading_tone_localBypass)
    {
      float contrast = ocio_grading_tone_sContrast;
      if (contrast != 1.)
      {
        contrast = (contrast > 1.) ? 1. / (1.8125 - 0.8125 * min( contrast, 1.99 )) : 0.28125 + 0.71875 * max( contrast, 0.01 );
        const float pivot = 0.400000;
        float3 t = outColor.rgb;
        {
          const float x3 = 1.000000;
          const float y3 = 1.000000;
          const float y0 = pivot + (y3 - pivot) * 0.25;
          float m0 = contrast;
          float x0 = pivot + (y0 - pivot) / m0;
          float min_width = (x3 - x0) * 0.3;
          float m3 = 1. / m0;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x1 = x0;
          float x2 = 2. * center - x1;
          if (x2 > x3)
          {
            x2 = x3;
            x1 = 2. * center - x2;
          }
          else if ((x2 - x1) < min_width)
          {
            x2 = x1 + min_width;
            float new_center = (x2 + x1) * 0.5;
            m3 = (y3 - y0 + m0*x0 - new_center * m0) / (x3 - new_center);
          }
          float y1 = y0;
          float y2 = y1 + (m0 + m3) * (x2 - x1) * 0.5;
          outColor.rgb = (t - pivot) / contrast + pivot;
          float3 c = y1 - t;
          float b = m0 * (x2 - x1);
          float a = (m3 - m0) * 0.5 * (x2 - x1);
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 res = (x2 - x1) * (-2. * c) / ( discrim + b ) + x1;
          outColor.rgb.r = (t.r > y1) ? res.r : outColor.rgb.r;
          outColor.rgb.g = (t.g > y1) ? res.g : outColor.rgb.g;
          outColor.rgb.b = (t.b > y1) ? res.b : outColor.rgb.b;
          outColor.rgb.r = (t.r > y2) ? x2 + (t.r - y2) / m3 : outColor.rgb.r;
          outColor.rgb.g = (t.g > y2) ? x2 + (t.g - y2) / m3 : outColor.rgb.g;
          outColor.rgb.b = (t.b > y2) ? x2 + (t.b - y2) / m3 : outColor.rgb.b;
        }
        {
          const float x0 = 0.000000;
          const float y0 = 0.000000;
          const float y3 = pivot - (pivot - y0) * 0.25;
          float m3 = contrast;
          float x3 = pivot - (pivot - y3) / m3;
          float min_width = (x3 - x0) * 0.3;
          float m0 = 1. / m3;
          float center = (y3 - y0 - m3*x3 + m0*x0) / (m0 - m3);
          float x2 = x3;
          float x1 = 2. * center - x2;
          if (x1 < x0)
          {
            x1 = x0;
            x2 = 2. * center - x1;
          }
          else if ((x2 - x1) < min_width)
          {
            x1 = x2 - min_width;
            float new_center = (x2 + x1) * 0.5;
            m0 = (y3 - y0 - m3*x3 + new_center * m3) / (new_center - x0);
          }
          float y2 = y3;
          float y1 = y2 - (m0 + m3) * (x2 - x1) * 0.5;
          float3 c = y1 - t;
          float b = m0 * (x2 - x1);
          float a = (m3 - m0) * 0.5 * (x2 - x1);
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 res = (x2 - x1) * (-2. * c) / ( discrim + b ) + x1;
          outColor.rgb.r = (t.r > y2) ? outColor.rgb.r : res.r;
          outColor.rgb.g = (t.g > y2) ? outColor.rgb.g : res.g;
          outColor.rgb.b = (t.b > y2) ? outColor.rgb.b : res.b;
          outColor.rgb.r = (t.r > y1) ? outColor.rgb.r : x1 + (t.r - y1) / m0;
          outColor.rgb.g = (t.g > y1) ? outColor.rgb.g : x1 + (t.g - y1) / m0;
          outColor.rgb.b = (t.b > y1) ? outColor.rgb.b : x1 + (t.b - y1) / m0;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksM;
        m0 = 2. - m0;
        float mtest = m0;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x1) ? y1 + (t.r - x1) * m1 : res.r;
          res.g = (t.g > x1) ? y1 + (t.g - x1) * m1 : res.g;
          res.b = (t.b > x1) ? y1 + (t.b - x1) * m1 : res.b;
          res = (res - x1) / gain + x1;
          outColor.rgb = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksR;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.r = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksG;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.g = res;
        }
      }
      {
        float x1 = ocio_grading_tone_blacksStart;
        float x0 = x1 - ocio_grading_tone_blacksWidth;
        const float m1 = 1.;
        float y1 = x1;
        float m0 = ocio_grading_tone_blacksB;
        m0 = 2. - m0;
        float mtest = m0;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m0 = 2. - m0;
          m0 = max( 0.01, m0 );
          float y0 = y1 - (m0 + m1) * (x1 - x0) * 0.5;
          float gain = (m0 + m1) * 0.5;
          t = (t - x1) * gain + x1;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x1) ? y1 + (t - x1) * m1 : res;
          res = (res - x1) / gain + x1;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsM;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsR;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsG;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_shadowsWidth;
        float x2 = ocio_grading_tone_shadowsStart;
        float m2 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_shadowsB;
        if (val < 1.)
        {
          float m0 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m0 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesM;
        float mtest = m1;
        float3 t = outColor.rgb;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float3 c = y0 - t;
          float3 discrim = sqrt( b * b - 4. * a * c );
          float3 tmp = ( -2. * c ) / ( discrim + b );
          float3 res = tmp * (x1 - x0) + x0;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y1) ? x1 + (t.r - y1) / m1 : res.r;
          res.g = (t.g > y1) ? x1 + (t.g - y1) / m1 : res.g;
          res.b = (t.b > y1) ? x1 + (t.b - y1) / m1 : res.b;
          outColor.rgb = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float3 tlocal = (t - x0) / (x1 - x0);
          float3 res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float3 c = cc - t;
          float3 discrim = sqrt( bb * bb - 4. * aa * c );
          float3 res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res.r = (t.r < brk) ? res.r : res1.r;
          res.g = (t.g < brk) ? res.g : res1.g;
          res.b = (t.b < brk) ? res.b : res1.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesR;
        float mtest = m1;
        float t = outColor.rgb.r;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.r = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesG;
        float mtest = m1;
        float t = outColor.rgb.g;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.g = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_whitesStart;
        float x1 = x0 + ocio_grading_tone_whitesWidth;
        const float m0 = 1.;
        float y0 = x0;
        float m1 = ocio_grading_tone_whitesB;
        float mtest = m1;
        float t = outColor.rgb.b;
        if (mtest < 1.)
        {
          m1 = max( 0.01, m1 );
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float a = 0.5 * (m1 - m0) * (x1 - x0);
          float b = m0 * (x1 - x0);
          float c = y0 - t;
          float discrim = sqrt( b * b - 4. * a * c );
          float tmp = ( -2. * c ) / ( discrim + b );
          float res = tmp * (x1 - x0) + x0;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y1) ? x1 + (t - y1) / m1 : res;
          outColor.rgb.b = res;
        }
        else if (mtest > 1.)
        {
          m1 = 2. - m1;
          m1 = max( 0.01, m1 );
          float gain = (m0 + m1) * 0.5;
          t = (t - x0) * gain + x0;
          float tlocal = (t - x0) / (x1 - x0);
          float res = tlocal * (x1 - x0) * ( tlocal * 0.5 * (m1 - m0) + m0 ) + y0;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (res - x0) / gain + x0;
          float new_y1 = (x1 - x0) / gain + x0;
          float xd = x0 + (x1 - x0) * 0.99;
          float md = m0 + (xd - x0) * (m1 - m0) / (x1 - x0);
          md = 1. / md;
          float aa = 0.5 * (1. / m1 - md) / (x1 - xd);
          float bb = 1. / m1 - 2. * aa * x1;
          float cc = new_y1 - bb * x1 - aa * x1 * x1;
          t = (t - x0) / gain + x0;
          float c = cc - t;
          float discrim = sqrt( bb * bb - 4. * aa * c );
          float res1 = ( -2. * c ) / ( discrim + bb );
          float brk = (aa * x1 + bb) * x1 + cc;
          res = (t < brk) ? res : res1;
          outColor.rgb.b = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsM;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 cL;
          float3 cR;
          float3 discrimL;
          float3 discrimR;
          float3 outL;
          float3 outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res.r = (t.r < y1) ? outL.r : outR.r;
          res.g = (t.g < y1) ? outL.g : outR.g;
          res.b = (t.b < y1) ? outL.b : outR.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) / m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) / m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) / m0 : res.b;
          res.r = (t.r > y2) ? x2 + (t.r - y2) / m2 : res.r;
          res.g = (t.g > y2) ? x2 + (t.g - y2) / m2 : res.g;
          res.b = (t.b > y2) ? x2 + (t.b - y2) / m2 : res.b;
          outColor.rgb = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float3 t = outColor.rgb;
          float3 res;
          float3 tL;
          float3 tR;
          float3 fL;
          float3 fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res.r = (t.r < x1) ? fL.r : fR.r;
          res.g = (t.g < x1) ? fL.g : fR.g;
          res.b = (t.b < x1) ? fL.b : fR.b;
          res.r = (t.r < x0) ? y0 + (t.r - x0) * m0 : res.r;
          res.g = (t.g < x0) ? y0 + (t.g - x0) * m0 : res.g;
          res.b = (t.b < x0) ? y0 + (t.b - x0) * m0 : res.b;
          res.r = (t.r > x2) ? y2 + (t.r - x2) * m2 : res.r;
          res.g = (t.g > x2) ? y2 + (t.g - x2) * m2 : res.g;
          res.b = (t.b > x2) ? y2 + (t.b - x2) * m2 : res.b;
          outColor.rgb = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsR;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.r = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.r;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.r = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsG;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.g = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.g;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.g = res;
        }
      }
      {
        float x0 = ocio_grading_tone_highlightsStart;
        float x2 = ocio_grading_tone_highlightsWidth;
        float m0 = 1.;
        float y0 = x0;
        float y2 = x2;
        float x1 = x0 + (x2 - x0) * 0.5;
        float val = ocio_grading_tone_highlightsB;
        val = 2. - val;
        if (val < 1.)
        {
          float m2 = max( 0.01, val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, cL, cR, discrimL, discrimR, outL, outR;
          cL = y0 - t;
          float bL = m0 * (x1 - x0);
          float aL = y1 - y0 - m0 * (x1 - x0);
          discrimL = sqrt( bL * bL - 4. * aL * cL );
          outL = (-2. * cL) / ( discrimL + bL ) * (x1 - x0) + x0;
          cR = y1 - t;
          float bR = 2.*y2 - 2.*y1 - m2 * (x2 - x1);
          float aR = y1 - y2 + m2 * (x2 - x1);
          discrimR = sqrt( bR * bR - 4. * aR * cR );
          outR = (-2. * cR) / ( discrimR + bR ) * (x2 - x1) + x1;
          res = (t < y1) ? outL : outR;
          res = (t < y0) ? x0 + (t - y0) / m0 : res;
          res = (t > y2) ? x2 + (t - y2) / m2 : res;
          outColor.rgb.b = res;
        }
        else if (val > 1.)
        {
          float m2 = max( 0.01, 2. - val );
          float y1 = ( 0.5 / (x2 - x0) ) * ( (2.*y0 + m0 * (x1 - x0)) * (x2 - x1) + (2.*y2 - m2 * (x2 - x1)) * (x1 - x0) );
          float t = outColor.rgb.b;
          float res, tL, tR, fL, fR;
          tL = (t - x0) / (x1 - x0);
          tR = (t - x1) / (x2 - x1);
          fL = y0 * (1. - tL*tL) + y1 * tL*tL + m0 * (1. - tL) * tL * (x1 - x0);
          fR = y1 * (1. - tR)*(1. - tR) + y2 * (2. - tR)*tR + m2 * (tR - 1.)*tR * (x2 - x1);
          res = (t < x1) ? fL : fR;
          res = (t < x0) ? y0 + (t - x0) * m0 : res;
          res = (t > x2) ? y2 + (t - x2) * m2 : res;
          outColor.rgb.b = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesM, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float3 t = outColor.rgb;
          float3 outL;
          float3 outM;
          float3 outR;
          float3 outR2;
          float3 outR3;
          {
            float3 c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR3 =  tmp * (x5 - x4) + x4;
          }
          {
            float3 c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR2 =  tmp * (x4 - x3) + x3;
          }
          {
            float3 c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outR =  tmp * (x3 - x2) + x2;
          }
          {
            float3 c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outM =  tmp * (x2 - x1) + x1;
          }
          {
            float3 c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float3 discrim = sqrt(b * b - 4. * a * c);
            float3 tmp = (-2. * c) / (discrim + b);
            outL =  tmp * (x1 - x0) + x0;
          }
          float3 res;
          res.r = (t.r < y1) ? outL.r : outM.r;
          res.g = (t.g < y1) ? outL.g : outM.g;
          res.b = (t.b < y1) ? outL.b : outM.b;
          res.r = (t.r > y2) ? outR.r : res.r;
          res.g = (t.g > y2) ? outR.g : res.g;
          res.b = (t.b > y2) ? outR.b : res.b;
          res.r = (t.r > y3) ? outR2.r : res.r;
          res.g = (t.g > y3) ? outR2.g : res.g;
          res.b = (t.b > y3) ? outR2.b : res.b;
          res.r = (t.r > y4) ? outR3.r : res.r;
          res.g = (t.g > y4) ? outR3.g : res.g;
          res.b = (t.b > y4) ? outR3.b : res.b;
          res.r = (t.r < y0) ? x0 + (t.r - y0) * m0 : res.r;
          res.g = (t.g < y0) ? x0 + (t.g - y0) * m0 : res.g;
          res.b = (t.b < y0) ? x0 + (t.b - y0) * m0 : res.b;
          res.r = (t.r > y5) ? x5 + (t.r - y5) * m5 : res.r;
          res.g = (t.g > y5) ? x5 + (t.g - y5) * m5 : res.g;
          res.b = (t.b > y5) ? x5 + (t.b - y5) * m5 : res.b;
          outColor.rgb = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesR, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.r;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.r = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesG, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.g;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.g = res;
        }
      }
      {
        const float halo = 0.4;
        float mid_adj = clamp(ocio_grading_tone_midtonesB, 0.01, 1.99);
        if (mid_adj != 1.)
        {
          const float x0 = 0.000000;
          const float x5 = 1.000000;
          const float max_width = (x5 - x0) * 0.95;
          float width = clamp(ocio_grading_tone_midtonesWidth, 0.01, max_width);
          float min_cent = x0 + width * 0.51;
          float max_cent = x5 - width * 0.51;
          float center = clamp(ocio_grading_tone_midtonesStart, min_cent, max_cent);
          float x1 = center - width * 0.5;
          float x4 = x1 + width;
          float x2 = x1 + (x4 - x1) * 0.25;
          float x3 = x1 + (x4 - x1) * 0.75;
          float y0 = x0;
          const float m0 = 1.;
          const float m5 = 1.;
          const float min_slope = 0.1;
          mid_adj = mid_adj - 1.;
          mid_adj = mid_adj * (1. - min_slope);
          float m2 = 1. + mid_adj;
          float m3 = 1. - mid_adj;
          float m1 = 1. + mid_adj * halo;
          float m4 = 1. - mid_adj * halo;
          if (center <= (x5 + x0) * 0.5)
          {
            float area = (x1 - x0) * (m1 - m0) * 0.5 + 
                (x2 - x1) * ((m1 - m0) + (m2 - m1)*0.5) + (center - x2) * (m2 - m0) * 0.5;
            m4 = ( -0.5*(x5 - x4)*m5 + (x4 - x3) * (0.5*m3 - m5) + 
                (x3 - center) * (m3 - m5) * 0.5 + area ) / ( -0.5*(x5 - x3) );
          }
          else
          {
            float area = (x5 - x4) * (m4 - m5) * 0.5 + 
                (x4 - x3) * ((m4 - m5) + (m3 - m4) * 0.5) + (x3 - center) * (m3 - m5) * 0.5;
            m1 = ( -0.5*(x1 - x0)*m0 + (x2 - x1) * (0.5*m2 - m0) + 
                (center - x2) * (m2 - m0) * 0.5 + area ) / ( -0.5*(x2 - x0) );
          }
          float y1 = y0 + (m0 + m1) * (x1 - x0) * 0.5;
          float y2 = y1 + (m1 + m2) * (x2 - x1) * 0.5;
          float y3 = y2 + (m2 + m3) * (x3 - x2) * 0.5;
          float y4 = y3 + (m3 + m4) * (x4 - x3) * 0.5;
          float y5 = y4 + (m4 + m5) * (x5 - x4) * 0.5;
          float t = outColor.rgb.b;
          float res;
          if (t >= y5)
          {
            res = x5 + (t - y5) / m5;
          }
          else if (t >= y4)
          {
            float c = y4 - t;
            float b = m4 * (x5 - x4);
            float a = 0.5 * (m5 - m4) * (x5 - x4);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x5 - x4) + x4;
          }
          else if (t >= y3)
          {
            float c = y3 - t;
            float b = m3 * (x4 - x3);
            float a = 0.5 * (m4 - m3) * (x4 - x3);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x4 - x3) + x3;
          }
          else if (t >= y2)
          {
            float c = y2 - t;
            float b = m2 * (x3 - x2);
            float a = 0.5 * (m3 - m2) * (x3 - x2);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x3 - x2) + x2;
          }
          else if (t >= y1)
          {
            float c = y1 - t;
            float b = m1 * (x2 - x1);
            float a = 0.5 * (m2 - m1) * (x2 - x1);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x2 - x1) + x1;
          }
          else if (t >= y0)
          {
            float c = y0 - t;
            float b = m0 * (x1 - x0);
            float a = 0.5 * (m1 - m0) * (x1 - x0);
            float discrim = sqrt(b * b - 4. * a * c);
            float tmp = (-2. * c) / (discrim + b);
            res =  tmp * (x1 - x0) + x0;
          }
          else
          {
            res = x0 + (t - y0) / m0;
          }
          outColor.rgb.b = res;
        }
      }
      outColor = min( outColor, 65504. );
    }
  }

  return outColor;
}

// Close class wrapper


};
float4 grading_transform(
  float ocio_grading_tone_blacksR
  , float ocio_grading_tone_blacksG
  , float ocio_grading_tone_blacksB
  , float ocio_grading_tone_blacksM
  , float ocio_grading_tone_blacksStart
  , float ocio_grading_tone_blacksWidth
  , float ocio_grading_tone_shadowsR
  , float ocio_grading_tone_shadowsG
  , float ocio_grading_tone_shadowsB
  , float ocio_grading_tone_shadowsM
  , float ocio_grading_tone_shadowsStart
  , float ocio_grading_tone_shadowsWidth
  , float ocio_grading_tone_midtonesR
  , float ocio_grading_tone_midtonesG
  , float ocio_grading_tone_midtonesB
  , float ocio_grading_tone_midtonesM
  , float ocio_grading_tone_midtonesStart
  , float ocio_grading_tone_midtonesWidth
  , float ocio_grading_tone_highlightsR
  , float ocio_grading_tone_highlightsG
  , float ocio_grading_tone_highlightsB
  , float ocio_grading_tone_highlightsM
  , float ocio_grading_tone_highlightsStart
  , float ocio_grading_tone_highlightsWidth
  , float ocio_grading_tone_whitesR
  , float ocio_grading_tone_whitesG
  , float ocio_grading_tone_whitesB
  , float ocio_grading_tone_whitesM
  , float ocio_grading_tone_whitesStart
  , float ocio_grading_tone_whitesWidth
  , float ocio_grading_tone_sContrast
  , bool ocio_grading_tone_localBypass
  , float4 inPixel)
{
  return ocio_grading_transform(
    ocio_grading_tone_blacksR
    , ocio_grading_tone_blacksG
    , ocio_grading_tone_blacksB
    , ocio_grading_tone_blacksM
    , ocio_grading_tone_blacksStart
    , ocio_grading_tone_blacksWidth
    , ocio_grading_tone_shadowsR
    , ocio_grading_tone_shadowsG
    , ocio_grading_tone_shadowsB
    , ocio_grading_tone_shadowsM
    , ocio_grading_tone_shadowsStart
    , ocio_grading_tone_shadowsWidth
    , ocio_grading_tone_midtonesR
    , ocio_grading_tone_midtonesG
    , ocio_grading_tone_midtonesB
    , ocio_grading_tone_midtonesM
    , ocio_grading_tone_midtonesStart
    , ocio_grading_tone_midtonesWidth
    , ocio_grading_tone_highlightsR
    , ocio_grading_tone_highlightsG
    , ocio_grading_tone_highlightsB
    , ocio_grading_tone_highlightsM
    , ocio_grading_tone_highlightsStart
    , ocio_grading_tone_highlightsWidth
    , ocio_grading_tone_whitesR
    , ocio_grading_tone_whitesG
    , ocio_grading_tone_whitesB
    , ocio_grading_tone_whitesM
    , ocio_grading_tone_whitesStart
    , ocio_grading_tone_whitesWidth
    , ocio_grading_tone_sContrast
    , ocio_grading_tone_localBypass
  ).grading_transform(inPixel);
}
"""#)
    default: return nil
    }
}
