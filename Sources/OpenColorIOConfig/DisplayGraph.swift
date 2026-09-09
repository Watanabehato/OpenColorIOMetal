import Foundation

extension OCIOConfigDocument {
    public func displayViewPlan(source: String, display requestedDisplay: String, view requestedView: String,
                                direction: OCIOConfigDirection = .forward, looksBypass: Bool = false,
                                dataBypass: Bool = true) throws -> [OCIOConfigTransformStep] {
        let displayName = try context.resolve(requestedDisplay)
        let viewName = try context.resolve(requestedView)
        guard let display = displays.first(where: { $0.key.caseInsensitiveCompare(displayName) == .orderedSame }),
              let view = display.value.first(where: { $0.name.caseInsensitiveCompare(viewName) == .orderedSame }) else {
            throw OCIOConfigError.unavailableTransform("display/view '\(displayName)/\(viewName)' not found")
        }
        let src = try colorSpace(named: source)
        let destination = view.colorSpace == "<USE_DISPLAY_NAME>" ? display.key : view.colorSpace
        let target = try? colorSpace(named: destination)
        if dataBypass && (src.isData || target?.isData == true) { return [] }
        let lookList = try selectedLooks(looksBypass ? "" : (view.looks ?? ""))
        var steps: [OCIOConfigTransformStep] = []
        let inverse = direction == .inverse
        let current: OCIOConfigColorSpace
        if inverse {
            current = try lookList.last.map { try colorSpace(named: $0.0.processSpace) } ?? src
        } else {
            let planned = try lookSteps(from: src.name, selected: lookList, inverse: false, dataBypass: dataBypass)
            steps = planned.steps
            current = try colorSpace(named: planned.result)
        }
        if let viewName = view.viewTransform, !viewName.isEmpty {
            guard let target, target.referenceSpace == .display else { throw OCIOConfigError.invalid("view '\(view.name)' requires a display-referred color space") }
            if let vt = viewTransforms.first(where: { $0.name.caseInsensitiveCompare(viewName) == .orderedSame }) {
                if inverse {
                    steps += displayReferenceStep(toReference: true, to: target.toReference, from: target.fromReference, label: target.name)
                    steps += displayReferenceStep(toReference: true, to: vt.toReference, from: vt.fromReference, label: vt.name)
                    steps += try referenceConversionPlan(from: vt.referenceSpace, to: current.referenceSpace)
                    steps += displayReferenceStep(toReference: false, to: current.toReference, from: current.fromReference, label: current.name)
                } else {
                    steps += displayReferenceStep(toReference: true, to: current.toReference, from: current.fromReference, label: current.name)
                    steps += try referenceConversionPlan(from: current.referenceSpace, to: vt.referenceSpace)
                    steps += displayReferenceStep(toReference: false, to: vt.toReference, from: vt.fromReference, label: vt.name)
                    steps += displayReferenceStep(toReference: false, to: target.toReference, from: target.fromReference, label: target.name)
                }
            } else {
                if inverse {
                    steps += displayReferenceStep(toReference: true, to: target.toReference, from: target.fromReference, label: target.name)
                    steps += try namedTransformPlan(viewName, direction: .inverse)
                } else {
                    steps += try namedTransformPlan(viewName)
                    steps += displayReferenceStep(toReference: false, to: target.toReference, from: target.fromReference, label: target.name)
                }
            }
        } else if let target {
            steps += try conversionPlan(from: inverse ? target.name : current.name, to: inverse ? current.name : target.name, dataBypass: dataBypass)
        } else { steps += try namedTransformPlan(destination, direction: direction) }
        if inverse && !lookList.isEmpty {
            let planned = try lookSteps(from: current.name, selected: lookList, inverse: true, dataBypass: dataBypass)
            steps += planned.steps
            steps += try conversionPlan(from: planned.result, to: src.name, dataBypass: dataBypass)
        }
        return steps
    }

    public func nativeDisplayStages(source: String, display: String, view: String,
                                    direction: OCIOConfigDirection = .forward,
                                    looksBypass: Bool = false, dataBypass: Bool = true) throws -> [OCIONativeStage] {
        try nativeStages(steps: displayViewPlan(source: source, display: display, view: view,
            direction: direction, looksBypass: looksBypass, dataBypass: dataBypass))
    }

    func referenceConversionPlan(from source: OCIOReferenceSpace, to destination: OCIOReferenceSpace) throws -> [OCIOConfigTransformStep] {
        if source == destination { return [] }
        let bridge: OCIOViewTransform?
        if let name = defaultViewTransform { bridge = viewTransforms.first(where: { $0.name == name && $0.referenceSpace == .scene }) }
        else { bridge = viewTransforms.first(where: { $0.referenceSpace == .scene }) }
        guard let bridge else { throw OCIOConfigError.unavailableTransform("a scene/display reference bridge is required") }
        return displayReferenceStep(toReference: source == .display, to: bridge.toReference, from: bridge.fromReference, label: bridge.name)
    }

    func selectedLooks(_ specification: String) throws -> [(OCIOConfigLook, Bool)] {
        for alternative in specification.split(separator: "|", omittingEmptySubsequences: false) {
            var selected: [(OCIOConfigLook, Bool)] = []
            var valid = true
            for component in alternative.split(separator: ",") {
                let text = component.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                let inverse = text.hasPrefix("-")
                let name = inverse || text.hasPrefix("+") ? String(text.dropFirst()) : text
                guard let look = looks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { valid = false; break }
                selected.append((look, inverse))
            }
            if valid { return selected }
        }
        throw OCIOConfigError.unavailableTransform("none of the look alternatives exists: \(specification)")
    }

    func lookSteps(from source: String, selected: [(OCIOConfigLook, Bool)], inverse: Bool, dataBypass: Bool = true) throws -> (steps: [OCIOConfigTransformStep], result: String) {
        let selected = inverse ? selected.reversed().map { ($0.0, !$0.1) } : selected
        var steps: [OCIOConfigTransformStep] = []
        var current = source
        for (look, reversed) in selected {
            steps += try conversionPlan(from: current, to: look.processSpace, dataBypass: dataBypass)
            steps += displayReferenceStep(toReference: reversed, to: look.inverse, from: look.forward, label: look.name)
            current = look.processSpace
        }
        return (steps, current)
    }
}

private func displayReferenceStep(toReference: Bool, to: OCIOConfigTransform?, from: OCIOConfigTransform?, label: String) -> [OCIOConfigTransformStep] {
    if let preferred = toReference ? to : from { return [OCIOConfigTransformStep(transform: preferred, label: label)] }
    if let fallback = toReference ? from : to { return [OCIOConfigTransformStep(transform: fallback, inverse: true, label: label)] }
    return []
}
