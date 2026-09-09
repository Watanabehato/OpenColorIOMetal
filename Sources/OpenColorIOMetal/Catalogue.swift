import Foundation

/// Errors are explicit: an unknown or unavailable transform never becomes an identity.
public enum OCIOError: Error, Sendable, CustomStringConvertible {
    case invalidArchive(String)
    case missingResource(String)
    case unknownConfiguration(String)
    case unknownColorSpace(String)
    case unknownTransform(String)
    case unsupportedConversion(String)
    case invalidInput(String)
    case metalUnavailable
    case metalFailure(String)

    public var description: String {
        switch self {
        case .invalidArchive(let message): "Invalid OCIO Metal archive: \(message)"
        case .missingResource(let path): "Missing OCIO Metal resource: \(path)"
        case .unknownConfiguration(let name): "Unknown configuration: \(name)"
        case .unknownColorSpace(let name): "Unknown color space or role: \(name)"
        case .unknownTransform(let name): "Unknown transform: \(name)"
        case .unsupportedConversion(let message): "Unsupported conversion: \(message)"
        case .invalidInput(let message): "Invalid input: \(message)"
        case .metalUnavailable: "A macOS Metal device is required. No CPU fallback is used."
        case .metalFailure(let message): "Metal failure: \(message)"
        }
    }
}

public enum TransformDirection: String, Codable, Sendable { case forward, inverse }

public struct OCIOUpstream: Codable, Sendable {
    public let repository: String
    public let commit: String
    public let version: String
}

public struct OCIOColorSpace: Codable, Sendable {
    public let name: String
    public let aliases: [String]
    public let family: String
    public let description: String
    public let isData: Bool
    public let isActive: Bool
    public let referenceSpace: String
    public let equalityGroup: String
}

public struct OCIOConversion: Codable, Sendable {
    public let source: String
    public let destination: String
    public let pipeline: [String]
}

public struct OCIODisplayView: Codable, Sendable {
    public let source: String
    public let display: String
    public let view: String
    public let direction: TransformDirection
    public let pipeline: [String]
}

public struct OCIOConfiguration: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let isRecommended: Bool
    public let roleAliases: [String: String]
    public let colorSpaces: [OCIOColorSpace]
    public let conversions: [OCIOConversion]
    public let displayViews: [OCIODisplayView]

    /// Resolves names, aliases and roles using OpenColorIO's case-insensitive matching.
    public func colorSpace(named name: String) throws -> OCIOColorSpace {
        let query = name.lowercased()
        if let space = colorSpaces.first(where: {
            $0.name.lowercased() == query || $0.aliases.contains { $0.lowercased() == query }
        }) { return space }
        if let role = roleAliases.first(where: { $0.key.lowercased() == query }),
           let space = colorSpaces.first(where: { $0.name.caseInsensitiveCompare(role.value) == .orderedSame }) {
            return space
        }
        throw OCIOError.unknownColorSpace(name)
    }

    public func conversion(source: String, destination: String) throws -> OCIOConversion {
        let sourceSpace = try colorSpace(named: source)
        let destinationSpace = try colorSpace(named: destination)
        if let conversion = conversions.first(where: {
            $0.source == sourceSpace.name && $0.destination == destinationSpace.name
        }) { return conversion }
        throw OCIOError.unsupportedConversion("\(id): \(sourceSpace.name) → \(destinationSpace.name)")
    }
}

public struct OCIOBuiltin: Codable, Sendable {
    public let name: String
    public let description: String
    public let forward: [String]
    public let inverse: [String]
}

public struct OCIOTexture: Codable, Sendable {
    public let name: String
    public let samplerName: String
    public let dimension: Int
    public let width: Int
    public let height: Int
    public let depth: Int
    public let channels: Int
    public let interpolation: String
    public let bindingIndex: Int
    /// Little-endian IEEE 754 Float32, x fastest, followed by y and z.
    public let data: String
}

public struct OCIOTransform: Codable, Sendable {
    public let id: String
    public let shader: String
    public let kernel: String
    public let textures: [OCIOTexture]
}

private struct ArchiveManifest: Decodable {
    let schemaVersion: Int
    let upstream: OCIOUpstream
    let defaultConfiguration: String
    let configurations: [OCIOConfiguration]
    let builtins: [OCIOBuiltin]
    let transforms: [OCIOTransform]
}

/// A self-contained native shader archive. Loading metadata does not require a GPU.
public struct OCIOCatalogue: Sendable {
    public let rootURL: URL
    public let schemaVersion: Int
    public let upstream: OCIOUpstream
    public let defaultConfiguration: String
    public let configurations: [OCIOConfiguration]
    public let builtins: [OCIOBuiltin]
    public let transforms: [OCIOTransform]
    private let transformIndex: [String: OCIOTransform]

    public init(contentsOf directoryURL: URL) throws {
        let root = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let manifest: ArchiveManifest
        do {
            manifest = try JSONDecoder().decode(ArchiveManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        } catch { throw OCIOError.invalidArchive(String(describing: error)) }
        guard manifest.schemaVersion == 1 else {
            throw OCIOError.invalidArchive("unsupported schema version \(manifest.schemaVersion)")
        }
        rootURL = root
        schemaVersion = manifest.schemaVersion
        upstream = manifest.upstream
        defaultConfiguration = manifest.defaultConfiguration
        configurations = manifest.configurations
        builtins = manifest.builtins
        transforms = manifest.transforms
        var index: [String: OCIOTransform] = [:]
        for transform in transforms {
            guard !transform.id.isEmpty, index[transform.id] == nil else {
                throw OCIOError.invalidArchive("empty or duplicate transform ID: \(transform.id)")
            }
            index[transform.id] = transform
        }
        transformIndex = index
        try validateStructure()
    }

    /// Frameworks may place Catalogue under Resources or next to the executable for static linking.
    public static func bundled() throws -> OCIOCatalogue {
        #if SWIFT_PACKAGE
        if let root = Bundle.module.url(forResource: "Catalogue", withExtension: nil) {
            return try OCIOCatalogue(contentsOf: root)
        }
        #endif
        let bundles = [Bundle(for: BundleToken.self), Bundle.main] + Bundle.allFrameworks + Bundle.allBundles
        for bundle in bundles {
            if let root = bundle.url(forResource: "Catalogue", withExtension: nil),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
                return try OCIOCatalogue(contentsOf: root)
            }
            if let resources = bundle.resourceURL {
                let root = resources.appendingPathComponent("OpenColorIOMetal_Catalogue.bundle/Catalogue")
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
                    return try OCIOCatalogue(contentsOf: root)
                }
            }
        }
        throw OCIOError.missingResource("Catalogue/manifest.json; pass an explicit archive URL or copy the resource bundle into your app")
    }

    public func configuration(_ id: String? = nil) throws -> OCIOConfiguration {
        let query = id ?? defaultConfiguration
        guard let configuration = configurations.first(where: { $0.id == query || $0.name == query }) else {
            throw OCIOError.unknownConfiguration(query)
        }
        return configuration
    }

    public func transform(_ id: String) throws -> OCIOTransform {
        guard let transform = transformIndex[id] else { throw OCIOError.unknownTransform(id) }
        return transform
    }

    /// Verifies the full manifest graph and, optionally, all referenced source and LUT files.
    public func validateResources() throws {
        for transform in transforms {
            _ = try resourceURL(transform.shader)
            for texture in transform.textures {
                let url = try resourceURL(texture.data)
                let values = try Self.checkedProduct([texture.width, texture.height, texture.depth, texture.channels, 4])
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue == values else {
                    throw OCIOError.invalidArchive("LUT byte count differs from dimensions: \(texture.data)")
                }
            }
        }
    }

    public func resourceURL(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains(":"),
              !relativePath.split(separator: "/").contains("..") else {
            throw OCIOError.invalidArchive("invalid relative resource path: \(relativePath)")
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(rootURL.path + "/") else {
            throw OCIOError.invalidArchive("resource escapes archive: \(relativePath)")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw OCIOError.missingResource(relativePath)
        }
        return url
    }

    static func checkedProduct(_ values: [Int]) throws -> Int {
        var result = 1
        for value in values {
            guard value > 0 else { throw OCIOError.invalidArchive("non-positive resource dimension") }
            let next = result.multipliedReportingOverflow(by: value)
            guard !next.overflow else { throw OCIOError.invalidArchive("resource dimensions overflow") }
            result = next.partialValue
        }
        return result
    }

    private func validateStructure() throws {
        guard configurations.contains(where: { $0.id == defaultConfiguration }) else {
            throw OCIOError.invalidArchive("default configuration is missing")
        }
        guard Set(configurations.map(\.id)).count == configurations.count,
              Set(builtins.map(\.name)).count == builtins.count else {
            throw OCIOError.invalidArchive("duplicate configuration or builtin")
        }
        func checkPipeline(_ pipeline: [String]) throws {
            for id in pipeline where transformIndex[id] == nil {
                throw OCIOError.invalidArchive("pipeline references missing transform \(id)")
            }
        }
        for configuration in configurations {
            let spaces = Set(configuration.colorSpaces.map(\.name))
            guard spaces.count == configuration.colorSpaces.count else {
                throw OCIOError.invalidArchive("duplicate color space in \(configuration.id)")
            }
            var pairs = Set<[String]>()
            for conversion in configuration.conversions {
                guard spaces.contains(conversion.source), spaces.contains(conversion.destination),
                      pairs.insert([conversion.source, conversion.destination]).inserted else {
                    throw OCIOError.invalidArchive("invalid or duplicate conversion in \(configuration.id)")
                }
                try checkPipeline(conversion.pipeline)
            }
            for value in configuration.roleAliases.values where !spaces.contains(value) {
                throw OCIOError.invalidArchive("role references missing color space \(value)")
            }
            for view in configuration.displayViews {
                guard spaces.contains(view.source) else {
                    throw OCIOError.invalidArchive("view references missing color space \(view.source)")
                }
                try checkPipeline(view.pipeline)
            }
        }
        for builtin in builtins {
            try checkPipeline(builtin.forward)
            try checkPipeline(builtin.inverse)
        }
        for transform in transforms {
            guard !transform.shader.isEmpty, !transform.kernel.isEmpty else {
                throw OCIOError.invalidArchive("empty shader or kernel: \(transform.id)")
            }
            var bindings = Set<Int>()
            for texture in transform.textures {
                guard (1...3).contains(texture.dimension), [1, 3, 4].contains(texture.channels),
                      texture.width > 0, texture.height > 0, texture.depth > 0,
                      texture.bindingIndex >= 0, texture.bindingIndex < 128,
                      bindings.insert(texture.bindingIndex).inserted,
                      ["nearest", "linear"].contains(texture.interpolation),
                      texture.dimension != 1 || (texture.height == 1 && texture.depth == 1),
                      texture.dimension != 2 || texture.depth == 1 else {
                    throw OCIOError.invalidArchive("invalid LUT descriptor: \(texture.name)")
                }
                _ = try Self.checkedProduct([texture.width, texture.height, texture.depth, texture.channels, 4])
            }
        }
    }
}

private final class BundleToken: NSObject {}
