import Foundation

/// Lossless scalar text and tagged structure used by OCIO configuration files.
/// Numbers are deliberately not converted through Double during parsing.
public indirect enum YAMLValue: Sendable, Equatable {
    case null
    case scalar(String)
    case sequence([YAMLValue])
    case mapping([String: YAMLValue])
    case tagged(String, YAMLValue)

    public var untagged: YAMLValue {
        if case let .tagged(_, value) = self { return value.untagged }
        return self
    }
    public var tag: String? {
        if case let .tagged(tag, _) = self { return tag }
        return nil
    }
    public var string: String? {
        if case let .scalar(value) = untagged { return value }
        return nil
    }
    public var array: [YAMLValue]? {
        if case let .sequence(value) = untagged { return value }
        return nil
    }
    public var object: [String: YAMLValue]? {
        if case let .mapping(value) = untagged { return value }
        return nil
    }
    public subscript(key: String) -> YAMLValue? { object?[key] }
}

public struct YAMLParseError: Error, Sendable, CustomStringConvertible {
    public let line: Int
    public let reason: String
    public var description: String { "YAML line \(line): \(reason)" }
}

/// A self-contained parser for the YAML representation used by .ocio files.
/// Supports block/flow collections, OCIO tags, quotes, block strings, anchors,
/// aliases, and merge keys. Unsupported syntax is rejected explicitly.
public struct YAMLParser: Sendable {
    public init() {}
    public func parse(_ source: String) throws -> YAMLValue {
        var parser = YAMLDocumentParser(source)
        return try parser.parse()
    }
}

private struct YAMLLine {
    var text: String
    let number: Int
    var indent: Int { text.prefix { $0 == " " }.count }
    var content: String { String(text.dropFirst(indent)) }
    var significant: String { stripYAMLComment(content).trimmingCharacters(in: .whitespaces) }
}

private func stripYAMLComment(_ text: String) -> String {
    let chars = Array(text)
    var quote: Character?
    var escaped = false
    var index = 0
    while index < chars.count {
        let c = chars[index]
        if quote == "\"" {
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { quote = nil }
        } else if quote == "'" {
            if c == "'" {
                if index + 1 < chars.count && chars[index + 1] == "'" { index += 1 }
                else { quote = nil }
            }
        } else if c == "\"" || c == "'" { quote = c }
        else if c == "#" && (index == 0 || chars[index - 1].isWhitespace) {
            return String(chars[..<index])
        }
        index += 1
    }
    return text
}

private func mappingColon(_ text: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    var depth = 0
    var index = text.startIndex
    while index < text.endIndex {
        let c = text[index]
        let next = text.index(after: index)
        if let current = quote {
            if escaped { escaped = false }
            else if current == "\"" && c == "\\" { escaped = true }
            else if c == current {
                if current == "'" && next < text.endIndex && text[next] == "'" {
                    index = next
                } else { quote = nil }
            }
        } else if c == "\"" || c == "'" { quote = c }
        else if c == "[" || c == "{" { depth += 1 }
        else if c == "]" || c == "}" { depth -= 1 }
        else if c == ":" && depth == 0 && (next == text.endIndex || text[next].isWhitespace) { return index }
        index = text.index(after: index)
    }
    return nil
}

private struct YAMLDocumentParser {
    var lines: [YAMLLine]
    var index = 0
    var anchors: [String: YAMLValue] = [:]

    init(_ source: String) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        lines = normalized.components(separatedBy: "\n").enumerated().map {
            YAMLLine(text: $0.element, number: $0.offset + 1)
        }
        // A terminal newline terminates the last line; it does not add a blank line.
        if normalized.hasSuffix("\n") { lines.removeLast() }
    }
    func error(_ reason: String, at line: Int? = nil) -> YAMLParseError {
        YAMLParseError(line: line ?? (index < lines.count ? lines[index].number : max(1, lines.count)), reason: reason)
    }
    mutating func skipEmpty() { while index < lines.count && lines[index].significant.isEmpty { index += 1 } }
    mutating func parse() throws -> YAMLValue {
        if !lines.isEmpty && lines[0].text.hasPrefix("\u{FEFF}") { lines[0].text.removeFirst() }
        skipEmpty()
        if index < lines.count && lines[index].significant.hasPrefix("%YAML ") { index += 1; skipEmpty() }
        if index < lines.count && lines[index].significant == "---" { index += 1; skipEmpty() }
        guard index < lines.count else { return .null }
        let result = try block(indent: lines[index].indent)
        skipEmpty()
        if index < lines.count && lines[index].significant == "..." { index += 1; skipEmpty() }
        guard index == lines.count else { throw error("unexpected content or multiple YAML documents") }
        return result
    }
    func isSequence(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }
    mutating func block(indent: Int) throws -> YAMLValue {
        skipEmpty()
        guard index < lines.count else { return .null }
        if lines[index].content.hasPrefix("\t") { throw error("tabs cannot indent YAML") }
        let text = lines[index].significant
        if isSequence(text) { return try sequence(indent: indent) }
        if mappingColon(text) != nil { return try mapping(indent: indent) }
        let line = lines[index].number
        index += 1
        return try value(text, parentIndent: indent, line: line)
    }
    mutating func sequence(indent: Int) throws -> YAMLValue {
        var result: [YAMLValue] = []
        while true {
            skipEmpty()
            guard index < lines.count && lines[index].indent == indent && isSequence(lines[index].significant) else { break }
            let line = lines[index].number
            let text = String(lines[index].significant.dropFirst()).trimmingCharacters(in: .whitespaces)
            index += 1
            if mappingColon(text) != nil && !text.hasPrefix("!") && !text.hasPrefix("&") {
                result.append(try mapping(indent: indent + 2, first: (text, line)))
            } else {
                result.append(try value(text, parentIndent: indent, line: line))
            }
        }
        return .sequence(result)
    }
    mutating func mapping(indent: Int, first: (String, Int)? = nil) throws -> YAMLValue {
        var result: [String: YAMLValue] = [:]
        var explicitKeys = Set<String>()
        var pending = first
        while true {
            let text: String
            let line: Int
            if let item = pending { text = item.0; line = item.1; pending = nil }
            else {
                skipEmpty()
                guard index < lines.count && lines[index].indent == indent else { break }
                guard !isSequence(lines[index].significant) else { break }
                text = lines[index].significant
                line = lines[index].number
                index += 1
            }
            guard let colon = mappingColon(text) else { throw error("expected a mapping key followed by ':'", at: line) }
            let keyText = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            var keyParser = YAMLFlowParser(keyText, line: line, anchors: anchors)
            guard let key = try keyParser.parse().string, !key.isEmpty else { throw error("mapping keys must be nonempty strings", at: line) }
            let rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let item = try value(rest, parentIndent: indent, line: line, allowIndentlessSequence: true)
            if key == "<<" {
                let maps = item.array ?? [item]
                for map in maps {
                    guard let values = map.object else { throw error("merge value must be a mapping or sequence of mappings", at: line) }
                    for (name, value) in values where result[name] == nil { result[name] = value }
                }
            } else {
                guard explicitKeys.insert(key).inserted else { throw error("duplicate mapping key '\(key)'", at: line) }
                result[key] = item
            }
        }
        return .mapping(result)
    }
    mutating func value(_ raw: String, parentIndent: Int, line: Int, allowIndentlessSequence: Bool = false) throws -> YAMLValue {
        var text = raw
        var tag: String?
        var anchor: String?
        while text.hasPrefix("!") || text.hasPrefix("&") {
            if text.hasPrefix("!<") {
                guard let end = text.firstIndex(of: ">") else { throw error("unterminated tag", at: line) }
                tag = String(text[text.index(text.startIndex, offsetBy: 2)..<end])
                text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            } else {
                let end = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
                let property = String(text[..<end])
                if property.hasPrefix("&") { anchor = String(property.dropFirst()) }
                else { tag = String(property.dropFirst()) }
                text = String(text[end...]).trimmingCharacters(in: .whitespaces)
            }
        }
        var result: YAMLValue
        if text.isEmpty {
            skipEmpty()
            if index < lines.count && (lines[index].indent > parentIndent || (allowIndentlessSequence && lines[index].indent == parentIndent && isSequence(lines[index].significant))) {
                result = try block(indent: lines[index].indent)
            } else { result = .null }
        } else if text.hasPrefix("|") || text.hasPrefix(">") {
            result = .scalar(try blockScalar(header: text, parentIndent: parentIndent, line: line))
        } else {
            let startsFlowOrQuote = ["[", "{", "\"", "'"].contains(String(text.prefix(1)))
            while startsFlowOrQuote && !flowComplete(text) {
                guard index < lines.count else { throw error("unterminated flow collection or quoted scalar", at: line) }
                text += "\n" + lines[index].significant
                index += 1
            }
            // YAML folds continued plain scalars; collection/scalar syntax stays distinct.
            if !["[", "{", "\"", "'", "*"].contains(String(text.prefix(1))) {
                while index < lines.count && lines[index].indent > parentIndent && !lines[index].significant.isEmpty {
                    let continuation = lines[index].significant
                    guard mappingColon(continuation) == nil && !isSequence(continuation) else {
                        throw error("unexpected nested content after a plain scalar")
                    }
                    text += " " + continuation
                    index += 1
                }
            }
            var parser = YAMLFlowParser(text, line: line, anchors: anchors)
            result = try parser.parse()
            anchors = parser.anchors
        }
        if let tag { result = .tagged(tag, result) }
        if let anchor {
            guard !anchor.isEmpty else { throw error("empty anchor", at: line) }
            anchors[anchor] = result
        }
        return result
    }
    mutating func blockScalar(header: String, parentIndent: Int, line: Int) throws -> String {
        let properties = String(header.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard properties.allSatisfy({ $0 == "+" || $0 == "-" || ("1"..."9").contains(String($0)) }), properties.count <= 2 else {
            throw error("invalid block scalar indicator", at: line)
        }
        let explicitIndent = properties.compactMap { Int(String($0)) }.first
        var contentIndent = explicitIndent.map { parentIndent + $0 }
        var content: [String] = []
        while index < lines.count {
            let current = lines[index]
            let empty = current.text.trimmingCharacters(in: .whitespaces).isEmpty
            if !empty && current.indent <= parentIndent { break }
            if !empty && contentIndent == nil { contentIndent = current.indent }
            if !empty && current.indent < (contentIndent ?? 0) { break }
            content.append(empty ? "" : String(current.text.dropFirst(contentIndent ?? current.indent)))
            index += 1
        }
        var output = ""
        for offset in content.indices {
            output += content[offset]
            let next = offset + 1
            if header.hasPrefix(">") && next < content.count && !content[offset].isEmpty && !content[next].isEmpty && !content[offset].hasPrefix(" ") && !content[next].hasPrefix(" ") {
                output += " "
            } else { output += "\n" }
        }
        if properties.contains("-") { while output.hasSuffix("\n") { output.removeLast() } }
        else if !properties.contains("+") {
            while output.hasSuffix("\n\n") { output.removeLast() }
        }
        return output
    }
}

private func flowComplete(_ text: String) -> Bool {
    var quote: Character?
    var escaped = false
    var depth = 0
    let chars = Array(text)
    var index = 0
    while index < chars.count {
        let c = chars[index]
        if let current = quote {
            if escaped { escaped = false }
            else if current == "\"" && c == "\\" { escaped = true }
            else if c == current {
                if current == "'" && index + 1 < chars.count && chars[index + 1] == "'" { index += 1 }
                else { quote = nil }
            }
        } else if c == "'" || c == "\"" { quote = c }
        else if c == "[" || c == "{" { depth += 1 }
        else if c == "]" || c == "}" { depth -= 1 }
        index += 1
    }
    return quote == nil && depth <= 0
}

private struct YAMLFlowParser {
    let chars: [Character]
    let line: Int
    var anchors: [String: YAMLValue]
    var index = 0
    init(_ text: String, line: Int, anchors: [String: YAMLValue]) {
        chars = Array(text); self.line = line; self.anchors = anchors
    }
    func error(_ reason: String) -> YAMLParseError { YAMLParseError(line: line, reason: reason) }
    mutating func whitespace() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
    mutating func parse() throws -> YAMLValue {
        let result = try value(flow: false)
        whitespace()
        guard index == chars.count else { throw error("unexpected text after a value") }
        return result
    }
    mutating func value(flow: Bool) throws -> YAMLValue {
        whitespace()
        guard index < chars.count else { return .null }
        switch chars[index] {
        case "[":
            index += 1; whitespace()
            var values: [YAMLValue] = []
            while index < chars.count && chars[index] != "]" {
                values.append(try value(flow: true)); whitespace()
                guard index < chars.count else { throw error("unterminated sequence") }
                if chars[index] == "]" { break }
                guard chars[index] == "," else { throw error("expected ',' between sequence items") }
                index += 1; whitespace()
            }
            guard index < chars.count && chars[index] == "]" else { throw error("unterminated sequence") }
            index += 1
            return .sequence(values)
        case "{":
            index += 1; whitespace()
            var values: [String: YAMLValue] = [:]
            var explicitKeys = Set<String>()
            while index < chars.count && chars[index] != "}" {
                let key: String
                if chars[index] == "\"" || chars[index] == "'" { key = try quoted() }
                else {
                    let start = index
                    while index < chars.count && chars[index] != ":" { index += 1 }
                    key = String(chars[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                whitespace()
                guard !key.isEmpty && index < chars.count && chars[index] == ":" else { throw error("invalid flow mapping key") }
                index += 1
                let item = try value(flow: true)
                if key == "<<" {
                    for map in item.array ?? [item] {
                        guard let source = map.object else { throw error("merge value must be a mapping") }
                        for (name, val) in source where values[name] == nil { values[name] = val }
                    }
                } else {
                    guard explicitKeys.insert(key).inserted else { throw error("duplicate mapping key '\(key)'") }
                    values[key] = item
                }
                whitespace()
                guard index < chars.count else { throw error("unterminated mapping") }
                if chars[index] == "}" { break }
                guard chars[index] == "," else { throw error("expected ',' between mapping entries") }
                index += 1; whitespace()
            }
            guard index < chars.count && chars[index] == "}" else { throw error("unterminated mapping") }
            index += 1
            return .mapping(values)
        case "\"", "'": return .scalar(try quoted())
        case "*":
            index += 1
            let name = token()
            guard let result = anchors[name] else { throw error("undefined or recursive alias '*\(name)'") }
            return result
        case "&":
            index += 1
            let name = token()
            guard !name.isEmpty else { throw error("empty anchor") }
            let result = try value(flow: flow)
            anchors[name] = result
            return result
        case "!":
            index += 1
            let tag: String
            if index < chars.count && chars[index] == "<" {
                index += 1; let start = index
                while index < chars.count && chars[index] != ">" { index += 1 }
                guard index < chars.count else { throw error("unterminated tag") }
                tag = String(chars[start..<index]); index += 1
            } else { tag = token() }
            return .tagged(tag, try value(flow: flow))
        default:
            let start = index
            while index < chars.count {
                if flow && [",", "]", "}"].contains(chars[index]) { break }
                index += 1
            }
            let text = String(chars[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == "~" || text.lowercased() == "null" { return .null }
            return .scalar(text)
        }
    }
    mutating func token() -> String {
        let start = index
        while index < chars.count && !chars[index].isWhitespace && ![",", "[", "]", "{", "}"].contains(chars[index]) { index += 1 }
        return String(chars[start..<index])
    }
    mutating func quoted() throws -> String {
        let quote = chars[index]; index += 1
        var result = ""
        while index < chars.count {
            let c = chars[index]; index += 1
            if c == quote {
                if quote == "'" && index < chars.count && chars[index] == "'" { result += "'"; index += 1; continue }
                return result
            }
            if quote == "\"" && c == "\\" {
                guard index < chars.count else { throw error("unterminated escape") }
                let escape = chars[index]; index += 1
                switch escape {
                case "0": result += "\0"
                case "a": result += "\u{7}"
                case "b": result += "\u{8}"
                case "t", "\t": result += "\t"
                case "n": result += "\n"
                case "v": result += "\u{B}"
                case "f": result += "\u{C}"
                case "r": result += "\r"
                case "e": result += "\u{1B}"
                case " ", "\"", "/", "\\": result.append(escape)
                case "N": result += "\u{85}"
                case "_": result += "\u{A0}"
                case "L": result += "\u{2028}"
                case "P": result += "\u{2029}"
                case "\n": while index < chars.count && chars[index].isWhitespace { index += 1 }
                case "x", "u", "U":
                    let length = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
                    guard index + length <= chars.count,
                          let value = UInt32(String(chars[index..<(index + length)]), radix: 16),
                          let scalar = UnicodeScalar(value) else { throw error("invalid Unicode escape") }
                    result.unicodeScalars.append(scalar); index += length
                default: throw error("unknown quoted escape '\\\(escape)'")
                }
            } else if c == "\n" {
                // YAML folds physical newlines in quoted scalars, but keeps blank lines.
                var newlines = 1
                while index < chars.count && chars[index].isWhitespace {
                    if chars[index] == "\n" { newlines += 1 }
                    index += 1
                }
                result += newlines == 1 ? " " : String(repeating: "\n", count: newlines - 1)
            } else { result.append(c) }
        }
        throw error("unterminated quoted scalar")
    }
}
