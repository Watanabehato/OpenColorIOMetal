import Foundation

public enum OCIOConfigError: Error, Sendable, CustomStringConvertible {
    case invalid(String)
    case unknownColorSpace(String)
    case unknownTransform(String)
    case unavailableTransform(String)
    case unresolvedVariable(String)
    case missingFile(String)

    public var description: String {
        switch self {
        case let .invalid(message): return "Invalid OCIO configuration: \(message)"
        case let .unknownColorSpace(name): return "Unknown color space or role: \(name)"
        case let .unknownTransform(name): return "Unknown OCIO transform type: \(name)"
        case let .unavailableTransform(message): return "Unavailable transform: \(message)"
        case let .unresolvedVariable(name): return "Unresolved or recursive OCIO context variable: \(name)"
        case let .missingFile(path): return "OCIO file not found in context search paths: \(path)"
        }
    }
}

public enum OCIOConfigDirection: String, Sendable, Codable {
    case forward, inverse
    public var inverted: Self { self == .forward ? .inverse : .forward }
}

/// A validated OCIO transform node, retaining every YAML parameter for compilation.
/// Recognition of a type does not claim that its native execution is implemented.
public struct OCIOConfigTransform: Sendable, Equatable {
    public static let recognizedTypes: Set<String> = [
        "AllocationTransform", "BuiltinTransform", "CDLTransform", "ColorSpaceTransform",
        "DisplayViewTransform", "ExponentTransform", "ExponentWithLinearTransform",
        "ExposureContrastTransform", "FileTransform", "FixedFunctionTransform",
        "GradingPrimaryTransform", "GradingHueCurveTransform", "GradingRGBCurveTransform",
        "GradingToneTransform", "GroupTransform", "LogAffineTransform", "LogCameraTransform",
        "LogTransform", "LookTransform", "Lut1DTransform", "Lut3DTransform",
        "MatrixTransform", "RangeTransform"
    ]
    public let type: String
    public let parameters: [String: YAMLValue]
    public let direction: OCIOConfigDirection
    public let children: [OCIOConfigTransform]

    public init(yaml: YAMLValue) throws {
        guard let type = yaml.tag else { throw OCIOConfigError.invalid("transform requires an explicit YAML type tag") }
        guard Self.recognizedTypes.contains(type) else { throw OCIOConfigError.unknownTransform(type) }
        guard let parameters = yaml.object else { throw OCIOConfigError.invalid("\(type) must contain a mapping") }
        let directionText = parameters["direction"]?.string ?? "forward"
        guard let direction = OCIOConfigDirection(rawValue: directionText) else {
            throw OCIOConfigError.invalid("\(type) direction '\(directionText)' is invalid")
        }
        self.type = type; self.parameters = parameters; self.direction = direction
        if type == "GroupTransform" {
            guard parameters["children"] == nil || parameters["children"]?.array != nil else {
                throw OCIOConfigError.invalid("GroupTransform children must be a sequence")
            }
            children = try (parameters["children"]?.array ?? []).map { try OCIOConfigTransform(yaml: $0) }
        } else { children = [] }
    }
}

public enum OCIOReferenceSpace: String, Sendable, Codable { case scene, display }

public struct OCIOConfigColorSpace: Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    public let referenceSpace: OCIOReferenceSpace
    public let isData: Bool
    public let equalityGroup: String
    public let toReference: OCIOConfigTransform?
    public let fromReference: OCIOConfigTransform?
    public let metadata: [String: YAMLValue]

    init(yaml: YAMLValue, reference: OCIOReferenceSpace) throws {
        let fields = try requireTaggedMapping(yaml, tag: "ColorSpace")
        name = try requireString(fields, "name", owner: "ColorSpace")
        aliases = try stringList(fields["aliases"], field: "aliases")
        referenceSpace = reference
        isData = try boolean(fields["isdata"], defaultValue: false, field: "isdata")
        equalityGroup = fields["equalitygroup"]?.string ?? ""
        let toKey = reference == .scene ? "to_scene_reference" : "to_display_reference"
        let fromKey = reference == .scene ? "from_scene_reference" : "from_display_reference"
        toReference = try optionalTransform(fields[toKey] ?? fields["to_reference"])
        fromReference = try optionalTransform(fields[fromKey] ?? fields["from_reference"])
        metadata = fields
    }
}

public struct OCIOConfigNamedTransform: Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    public let forward: OCIOConfigTransform?
    public let inverse: OCIOConfigTransform?
    public let metadata: [String: YAMLValue]
    init(yaml: YAMLValue) throws {
        let fields = try requireTaggedMapping(yaml, tag: "NamedTransform")
        name = try requireString(fields, "name", owner: "NamedTransform")
        aliases = try stringList(fields["aliases"], field: "aliases")
        forward = try optionalTransform(fields["transform"] ?? fields["forward_transform"])
        inverse = try optionalTransform(fields["inverse_transform"])
        metadata = fields
        guard forward != nil || inverse != nil else { throw OCIOConfigError.invalid("NamedTransform '\(name)' has no transform") }
    }
}

public struct OCIOConfigLook: Sendable, Equatable {
    public let name: String
    public let processSpace: String
    public let forward: OCIOConfigTransform?
    public let inverse: OCIOConfigTransform?
    public let metadata: [String: YAMLValue]
    init(yaml: YAMLValue) throws {
        let fields = try requireTaggedMapping(yaml, tag: "Look")
        name = try requireString(fields, "name", owner: "Look")
        processSpace = try requireString(fields, "process_space", owner: "Look '\(name)'")
        forward = try optionalTransform(fields["transform"])
        inverse = try optionalTransform(fields["inverse_transform"])
        metadata = fields
    }
}

public struct OCIOViewTransform: Sendable, Equatable {
    public let name: String
    public let referenceSpace: OCIOReferenceSpace
    public let toReference: OCIOConfigTransform?
    public let fromReference: OCIOConfigTransform?
    public let metadata: [String: YAMLValue]
    init(yaml: YAMLValue) throws {
        let fields = try requireTaggedMapping(yaml, tag: "ViewTransform")
        name = try requireString(fields, "name", owner: "ViewTransform")
        let scene = fields["to_scene_reference"] != nil || fields["from_scene_reference"] != nil
        let display = fields["to_display_reference"] != nil || fields["from_display_reference"] != nil
        guard scene != display else { throw OCIOConfigError.invalid("ViewTransform '\(name)' must reference exactly one of scene or display") }
        referenceSpace = scene ? .scene : .display
        toReference = try optionalTransform(fields[scene ? "to_scene_reference" : "to_display_reference"])
        fromReference = try optionalTransform(fields[scene ? "from_scene_reference" : "from_display_reference"])
        metadata = fields
    }
}

public struct OCIOView: Sendable, Equatable {
    public let name: String
    public let colorSpace: String
    public let viewTransform: String?
    public let looks: String?
    public let rule: String?
    public let metadata: [String: YAMLValue]
    init(yaml: YAMLValue) throws {
        let fields = try requireTaggedMapping(yaml, tag: "View")
        name = try requireString(fields, "name", owner: "View")
        colorSpace = try requireString(fields, fields["display_colorspace"] != nil ? "display_colorspace" : "colorspace", owner: "View '\(name)'")
        viewTransform = fields["view_transform"]?.string
        looks = fields["looks"]?.string
        rule = fields["rule"]?.string
        metadata = fields
    }
}

public struct OCIOConfigTransformStep: Sendable, Equatable {
    public let transform: OCIOConfigTransform
    /// Effective direction, including the node's own direction and graph inversion.
    public let direction: OCIOConfigDirection
    public let label: String
    public init(transform: OCIOConfigTransform, inverse: Bool = false, label: String) {
        self.transform = transform
        direction = inverse ? transform.direction.inverted : transform.direction
        self.label = label
    }
}

/// Configuration metadata and reference-space graph. Parsing and graph planning
/// never approximate or execute an unsupported transform as identity.
public struct OCIOConfigDocument: Sendable {
    public let profileVersion: String
    public let name: String
    public let colorSpaces: [OCIOConfigColorSpace]
    public let roles: [String: String]
    public let namedTransforms: [OCIOConfigNamedTransform]
    public let looks: [OCIOConfigLook]
    public let viewTransforms: [OCIOViewTransform]
    public let displays: [String: [OCIOView]]
    public let sharedViews: [OCIOView]
    public let activeDisplays: [String]
    public let activeViews: [String]
    public let inactiveColorSpaces: [String]
    public let defaultViewTransform: String?
    public let context: OCIOContext
    /// Includes file/viewing rules, virtual display, interop metadata, and future keys.
    public let document: [String: YAMLValue]

    public init(contentsOf url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(yaml: String(contentsOf: url, encoding: .utf8), workingDirectory: url.deletingLastPathComponent(), environment: environment)
    }
    public init(yaml: String, workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath), environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let fields = try YAMLParser().parse(yaml).object else { throw OCIOConfigError.invalid("document must be a mapping") }
        document = fields
        profileVersion = try requireString(fields, "ocio_profile_version", owner: "configuration")
        let versions = profileVersion.split(separator: ".")
        guard let major = versions.first.flatMap({ Int($0) }), (1...2).contains(major), versions.count <= 2,
              versions.dropFirst().allSatisfy({ Int($0) != nil }) else {
            throw OCIOConfigError.invalid("unsupported profile version '\(profileVersion)'")
        }
        name = fields["name"]?.string ?? ""
        roles = try stringMapping(fields["roles"], field: "roles")
        colorSpaces = try sequenceField(fields, "colorspaces").map { try OCIOConfigColorSpace(yaml: $0, reference: .scene) }
            + sequenceField(fields, "display_colorspaces").map { try OCIOConfigColorSpace(yaml: $0, reference: .display) }
        namedTransforms = try sequenceField(fields, "named_transforms").map { try OCIOConfigNamedTransform(yaml: $0) }
        looks = try sequenceField(fields, "looks").map { try OCIOConfigLook(yaml: $0) }
        viewTransforms = try sequenceField(fields, "view_transforms").map { try OCIOViewTransform(yaml: $0) }
        sharedViews = try sequenceField(fields, "shared_views").map { try OCIOView(yaml: $0) }
        activeDisplays = try stringList(fields["active_displays"], field: "active_displays")
        activeViews = try stringList(fields["active_views"], field: "active_views")
        inactiveColorSpaces = try stringList(fields["inactive_colorspaces"], field: "inactive_colorspaces")
        defaultViewTransform = fields["default_view_transform"]?.string
        var parsedDisplays: [String: [OCIOView]] = [:]
        if let yamlDisplays = fields["displays"] {
            guard let displayMap = yamlDisplays.object else { throw OCIOConfigError.invalid("displays must be a mapping") }
            for (display, value) in displayMap {
                guard let entries = value.array else { throw OCIOConfigError.invalid("display '\(display)' must contain a sequence") }
                var views: [OCIOView] = []
                for entry in entries {
                    if entry.tag == "Views" {
                        for name in try stringList(entry, field: "Views") {
                            guard let shared = sharedViews.first(where: { $0.name == name }) else { throw OCIOConfigError.invalid("unknown shared view '\(name)'") }
                            views.append(shared)
                        }
                    } else { views.append(try OCIOView(yaml: entry)) }
                }
                parsedDisplays[display] = views
            }
        }
        displays = parsedDisplays
        let defaults = try stringMapping(fields["environment"], field: "environment")
        var variables = defaults
        // A declared environment limits which process variables are imported.
        if fields["environment"] == nil { variables = environment }
        else { for key in defaults.keys { if let value = environment[key] { variables[key] = value } } }
        let paths: [String]
        if let scalar = fields["search_path"]?.string { paths = scalar.split(separator: ":", omittingEmptySubsequences: true).map(String.init) }
        else { paths = try stringList(fields["search_path"], field: "search_path") }
        context = OCIOContext(variables: variables, searchPaths: paths, workingDirectory: workingDirectory)
        try validateNames()
    }

    private func validateNames() throws {
        var names = Set<String>()
        for space in colorSpaces {
            for name in [space.name] + space.aliases {
                guard names.insert(name.lowercased()).inserted else { throw OCIOConfigError.invalid("duplicate color space name or alias '\(name)'") }
            }
        }
        for named in namedTransforms {
            for name in [named.name] + named.aliases {
                guard names.insert(name.lowercased()).inserted else { throw OCIOConfigError.invalid("duplicate transform name or alias '\(name)'") }
            }
        }
        for (role, target) in roles {
            guard !names.contains(role.lowercased()) else { throw OCIOConfigError.invalid("role '\(role)' conflicts with a name or alias") }
            guard colorSpaces.contains(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) }) else {
                throw OCIOConfigError.invalid("role '\(role)' refers to unknown color space '\(target)'")
            }
        }
    }

    public func colorSpace(named requestedName: String) throws -> OCIOConfigColorSpace {
        let resolved = try context.resolve(requestedName)
        let roleTarget = roles.first(where: { $0.key.caseInsensitiveCompare(resolved) == .orderedSame })?.value ?? resolved
        guard let result = colorSpaces.first(where: { $0.name.caseInsensitiveCompare(roleTarget) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(roleTarget) == .orderedSame }) }) else {
            throw OCIOConfigError.unknownColorSpace(requestedName)
        }
        return result
    }

    /// Builds source -> reference -> destination, selecting an explicitly authored
    /// reverse transform before asking a compiler to invert the forward transform.
    public func conversionPlan(from source: String, to destination: String, dataBypass: Bool = true) throws -> [OCIOConfigTransformStep] {
        let src = try colorSpace(named: source)
        let dst = try colorSpace(named: destination)
        if src.name == dst.name || (dataBypass && (src.isData || dst.isData)) { return [] }
        if !src.equalityGroup.isEmpty && src.equalityGroup == dst.equalityGroup && src.referenceSpace == dst.referenceSpace { return [] }
        var steps = referenceSteps(toReference: true, to: src.toReference, from: src.fromReference, label: "\(src.name) -> \(src.referenceSpace.rawValue) reference")
        if src.referenceSpace != dst.referenceSpace {
            let bridge: OCIOViewTransform?
            if let preferred = defaultViewTransform {
                bridge = viewTransforms.first(where: { $0.name == preferred && $0.referenceSpace == .scene })
            } else { bridge = viewTransforms.first(where: { $0.referenceSpace == .scene }) }
            guard let bridge else { throw OCIOConfigError.unavailableTransform("a scene/display reference bridge is required") }
            // A scene-referred view transform's FROM reference maps scene -> display.
            steps += referenceSteps(toReference: src.referenceSpace == .display, to: bridge.toReference, from: bridge.fromReference, label: "view transform \(bridge.name)")
        }
        steps += referenceSteps(toReference: false, to: dst.toReference, from: dst.fromReference, label: "\(dst.referenceSpace.rawValue) reference -> \(dst.name)")
        return steps
    }

    public func namedTransformPlan(_ requestedName: String, direction: OCIOConfigDirection = .forward) throws -> [OCIOConfigTransformStep] {
        let resolved = try context.resolve(requestedName)
        guard let named = namedTransforms.first(where: { $0.name.caseInsensitiveCompare(resolved) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(resolved) == .orderedSame }) }) else {
            throw OCIOConfigError.unavailableTransform("unknown named transform '\(requestedName)'")
        }
        return referenceSteps(toReference: direction == .inverse, to: named.inverse, from: named.forward, label: named.name)
    }
}

private func referenceSteps(toReference: Bool, to: OCIOConfigTransform?, from: OCIOConfigTransform?, label: String) -> [OCIOConfigTransformStep] {
    let preferred = toReference ? to : from
    let fallback = toReference ? from : to
    if let preferred { return [OCIOConfigTransformStep(transform: preferred, label: label)] }
    if let fallback { return [OCIOConfigTransformStep(transform: fallback, inverse: true, label: label)] }
    // OCIO defines a color space without transforms as the reference space.
    return []
}

private func requireTaggedMapping(_ yaml: YAMLValue, tag: String) throws -> [String: YAMLValue] {
    guard yaml.tag == tag, let fields = yaml.object else { throw OCIOConfigError.invalid("expected !<\(tag)> mapping") }
    return fields
}
private func requireString(_ fields: [String: YAMLValue], _ key: String, owner: String) throws -> String {
    guard let result = fields[key]?.string, !result.isEmpty else { throw OCIOConfigError.invalid("\(owner) requires nonempty '\(key)'") }
    return result
}
private func optionalTransform(_ value: YAMLValue?) throws -> OCIOConfigTransform? {
    guard let value else { return nil }
    return try OCIOConfigTransform(yaml: value)
}
private func sequenceField(_ fields: [String: YAMLValue], _ name: String) throws -> [YAMLValue] {
    guard let value = fields[name] else { return [] }
    guard let result = value.array else { throw OCIOConfigError.invalid("\(name) must be a sequence") }
    return result
}
private func stringList(_ value: YAMLValue?, field: String) throws -> [String] {
    guard let value else { return [] }
    guard let array = value.array else { throw OCIOConfigError.invalid("\(field) must be a sequence of strings") }
    return try array.map {
        guard let text = $0.string else { throw OCIOConfigError.invalid("\(field) contains a non-string entry") }
        return text
    }
}
private func stringMapping(_ value: YAMLValue?, field: String) throws -> [String: String] {
    guard let value else { return [:] }
    guard let map = value.object else { throw OCIOConfigError.invalid("\(field) must be a mapping") }
    return try map.mapValues {
        guard let text = $0.string else { throw OCIOConfigError.invalid("\(field) contains a non-string value") }
        return text
    }
}
private func boolean(_ value: YAMLValue?, defaultValue: Bool, field: String) throws -> Bool {
    guard let value else { return defaultValue }
    guard let string = value.string?.lowercased() else { throw OCIOConfigError.invalid("\(field) must be boolean") }
    if ["true", "yes", "on"].contains(string) { return true }
    if ["false", "no", "off"].contains(string) { return false }
    throw OCIOConfigError.invalid("\(field) must be boolean")
}
