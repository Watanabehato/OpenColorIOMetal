// SPDX-License-Identifier: BSD-3-Clause
import Foundation

public struct OCIOFileRuleMatch: Sendable, Equatable {
    public let ruleName: String
    public let ruleIndex: Int
    /// Canonical color-space or named-transform name selected by the rule.
    public let target: String
    public var isDefault: Bool { ruleName.caseInsensitiveCompare("Default") == .orderedSame }
}

extension OCIOConfigDocument {
    /// Evaluates file rules in authored priority order. Glob patterns match the
    /// entire path; a literal extension is case insensitive, as in upstream OCIO.
    public func fileRule(for path: String) throws -> OCIOFileRuleMatch {
        let rules = try ruleSequence(document, "file_rules")
        for (index, value) in rules.enumerated() {
            let fields = try ruleTaggedMapping(value, tag: "Rule")
            let name = try ruleString(fields, "name", owner: "file rule")
            if name.caseInsensitiveCompare("ColorSpaceNamePathSearch") == .orderedSame {
                if let selected = colorSpaceName(in: path) { return OCIOFileRuleMatch(ruleName: name, ruleIndex: index, target: selected) }
                continue
            }
            let target = try ruleString(fields, "colorspace", owner: "file rule '\(name)'")
            let matched: Bool
            if name.caseInsensitiveCompare("Default") == .orderedSame { matched = true }
            else if let expression = fields["regex"]?.string { matched = try nativeRuleMatch(expression, path) }
            else {
                let pattern = fields["pattern"]?.string ?? "*"
                let ext = fields["extension"]?.string ?? "*"
                let insensitive = !ext.contains(where: { "[*?".contains($0) })
                let extensionExpression = try nativeGlob(ext.isEmpty ? "*" : ext)
                let expression = try nativeGlob(pattern.isEmpty ? "*" : pattern) + "\\." + (insensitive ? "(?i:\(extensionExpression))" : extensionExpression)
                matched = try nativeRuleMatch(expression, path)
            }
            if matched { return OCIOFileRuleMatch(ruleName: name, ruleIndex: index, target: try ruleTarget(target)) }
        }
        if rules.isEmpty {
            if profileVersion.hasPrefix("1"), let selected = colorSpaceName(in: path) {
                return OCIOFileRuleMatch(ruleName: "ColorSpaceNamePathSearch", ruleIndex: 0, target: selected)
            }
            return OCIOFileRuleMatch(ruleName: "Default", ruleIndex: profileVersion.hasPrefix("1") ? 1 : 0, target: try ruleTarget("default"))
        }
        throw OCIOConfigError.invalid("file rules require a final Default rule")
    }

    /// Finds the rightmost color-space name/alias, breaking ties in favor of the
    /// longest match. Roles are not filename tokens in the upstream path rule.
    public func colorSpaceName(in path: String) -> String? {
        let string = path.lowercased() as NSString
        var bestEnd = -1, bestLength = -1
        var selected: String?
        for space in colorSpaces {
            for name in [space.name] + space.aliases where !name.isEmpty {
                let range = string.range(of: name.lowercased(), options: .backwards)
                guard range.location != NSNotFound else { continue }
                let end = range.location + range.length
                if end > bestEnd || (end == bestEnd && range.length > bestLength) {
                    bestEnd = end; bestLength = range.length; selected = space.name
                }
            }
        }
        return selected
    }

    /// Returns active views that accept the source's color space or encoding.
    /// Views without a viewing rule are always included.
    public func views(display name: String, source: String) throws -> [OCIOView] {
        guard let display = displays.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw OCIOConfigError.invalid("display '\(name)' not found")
        }
        let space = try colorSpace(named: source)
        let encoding = space.metadata["encoding"]?.string?.lowercased() ?? ""
        let ordered: [OCIOView]
        if activeViews.isEmpty { ordered = display.value }
        else { ordered = activeViews.compactMap { name in display.value.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) } }
        let rules = try ruleSequence(document, "viewing_rules").map { try ruleTaggedMapping($0, tag: "Rule") }
        return try ordered.filter { view in
            guard let name = view.rule, !name.isEmpty else { return true }
            guard let rule = rules.first(where: { $0["name"]?.string?.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw OCIOConfigError.invalid("view '\(view.name)' refers to missing rule '\(name)'")
            }
            let names = try ruleStringList(rule["colorspaces"], field: "viewing rule colorspaces")
            let encodings = try ruleStringList(rule["encodings"], field: "viewing rule encodings")
            guard names.isEmpty != encodings.isEmpty else { throw OCIOConfigError.invalid("viewing rule '\(name)' must contain either colorspaces or encodings") }
            if !names.isEmpty {
                return try names.contains { try colorSpace(named: $0).name.caseInsensitiveCompare(space.name) == .orderedSame }
            }
            return !encoding.isEmpty && encodings.contains { $0.lowercased() == encoding }
        }
    }

    private func ruleTarget(_ name: String) throws -> String {
        if let space = try? colorSpace(named: name) { return space.name }
        if let named = namedTransforms.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }) { return named.name }
        throw OCIOConfigError.unknownColorSpace(name)
    }
}

private func nativeRuleMatch(_ expression: String, _ text: String) throws -> Bool {
    do {
        let regular = try NSRegularExpression(pattern: "^(?:\(expression))$")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regular.firstMatch(in: text, range: range)?.range == range
    } catch { throw OCIOConfigError.invalid("file-rule regular expression: \(error)") }
}

private func nativeGlob(_ text: String) throws -> String {
    let characters = Array(text)
    var result = "", index = 0
    while index < characters.count {
        let character = characters[index]
        switch character {
        case "*": result += ".*"
        case "?": result += "."
        case "[":
            var end = index + 1
            while end < characters.count && characters[end] != "]" { end += 1 }
            guard end < characters.count, end > index + 1 else { throw OCIOConfigError.invalid("malformed file-rule glob character class") }
            var contents = String(characters[(index + 1)..<end])
            if contents.hasPrefix("!") { contents = "^" + contents.dropFirst() }
            guard contents != "^", !contents.contains("[") else { throw OCIOConfigError.invalid("malformed file-rule glob character class") }
            result += "[" + contents + "]"
            index = end
        case "]": throw OCIOConfigError.invalid("unmatched ']' in file-rule glob")
        default: result += NSRegularExpression.escapedPattern(for: String(character))
        }
        index += 1
    }
    return result
}

private func ruleSequence(_ fields: [String: YAMLValue], _ key: String) throws -> [YAMLValue] {
    guard let value = fields[key] else { return [] }
    guard let values = value.array else { throw OCIOConfigError.invalid("\(key) must be a sequence") }
    return values
}
private func ruleTaggedMapping(_ value: YAMLValue, tag: String) throws -> [String: YAMLValue] {
    guard value.tag == tag, let fields = value.object else { throw OCIOConfigError.invalid("expected !<\(tag)> mapping") }
    return fields
}
private func ruleString(_ fields: [String: YAMLValue], _ key: String, owner: String) throws -> String {
    guard let value = fields[key]?.string, !value.isEmpty else { throw OCIOConfigError.invalid("\(owner) requires '\(key)'") }
    return value
}
private func ruleStringList(_ value: YAMLValue?, field: String) throws -> [String] {
    guard let value else { return [] }
    if let scalar = value.string { return [scalar] }
    guard let values = value.array else { throw OCIOConfigError.invalid("\(field) requires strings") }
    return try values.map {
        guard let string = $0.string else { throw OCIOConfigError.invalid("\(field) contains a non-string") }
        return string
    }
}
