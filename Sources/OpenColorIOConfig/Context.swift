import Foundation

public struct OCIOContext: Sendable, Equatable {
    public var variables: [String: String]
    public var searchPaths: [String]
    public var workingDirectory: URL

    public init(variables: [String: String] = [:], searchPaths: [String] = [], workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.variables = variables; self.searchPaths = searchPaths; self.workingDirectory = workingDirectory
    }
    /// Supports $NAME, ${NAME}, and %NAME%, recursively resolving nested values.
    /// Unknown names fail so a typo cannot accidentally select a different transform.
    public func resolve(_ text: String) throws -> String { try resolve(text, stack: []) }
    private func resolve(_ text: String, stack: Set<String>) throws -> String {
        let chars = Array(text)
        var result = ""
        var index = 0
        while index < chars.count {
            let c = chars[index]
            var name: String?
            var end = index + 1
            if c == "$" && end < chars.count && chars[end] == "{" {
                let start = end + 1; end = start
                while end < chars.count && chars[end] != "}" { end += 1 }
                guard end < chars.count else { throw OCIOConfigError.unresolvedVariable(String(chars[index...])) }
                name = String(chars[start..<end]); end += 1
            } else if c == "$" {
                let start = end
                while end < chars.count && (chars[end].isLetter || chars[end].isNumber || chars[end] == "_") { end += 1 }
                if end > start { name = String(chars[start..<end]) }
            } else if c == "%" {
                let start = end
                while end < chars.count && chars[end] != "%" { end += 1 }
                if end < chars.count { name = String(chars[start..<end]); end += 1 }
            }
            if let name {
                guard let value = variables[name], !stack.contains(name), stack.count < 100 else { throw OCIOConfigError.unresolvedVariable(name) }
                var next = stack; next.insert(name)
                result += try resolve(value, stack: next)
                index = end
            } else { result.append(c); index += 1 }
        }
        return result
    }

    public func resolveFile(_ source: String) throws -> URL {
        let path = try resolve(source)
        if (path as NSString).isAbsolutePath {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            if fileExists(candidate) { return candidate }
            throw OCIOConfigError.missingFile(path)
        }
        for root in searchPaths + [""] {
            let expanded = try resolve(root)
            let base = expanded.isEmpty ? workingDirectory : URL(fileURLWithPath: expanded, relativeTo: workingDirectory)
            let candidate = base.appendingPathComponent(path).standardizedFileURL
            if fileExists(candidate) { return candidate }
        }
        throw OCIOConfigError.missingFile(path)
    }
    private func fileExists(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
}
