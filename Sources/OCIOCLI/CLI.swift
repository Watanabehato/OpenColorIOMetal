import Foundation
import OpenColorIOMetal
import Darwin

private struct Arguments {
    let command: String
    var values: [String: String] = [:]
    var flags = Set<String>()
    init(_ arguments: [String]) throws {
        command = arguments.first ?? "help"
        var index = 1
        let switches: Set<String> = ["--inverse", "--binary", "--gpu", "--help"]
        let valued: Set<String> = ["--archive", "--config", "--ocio", "--src", "--dst", "--rgba", "--style", "--name", "--display", "--view", "--input", "--output", "--suite"]
        while index < arguments.count {
            let name = arguments[index]
            if switches.contains(name) { flags.insert(name); index += 1; continue }
            guard valued.contains(name), index + 1 < arguments.count, values[name] == nil else {
                throw OCIOError.invalidInput("Unknown, duplicated or incomplete option: \(name)")
            }
            values[name] = arguments[index + 1]
            index += 2
        }
    }
    func required(_ name: String) throws -> String {
        guard let value = values[name] else { throw OCIOError.invalidInput("Missing \(name)") }
        return value
    }
}

@main
struct OCIOCLI {
    static func main() {
        do { try run(Arguments(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            FileHandle.standardError.write(Data("ocio-metal: \(error)\n".utf8))
            if case OCIOError.metalUnavailable = error { exit(3) }
            exit(1)
        }
    }

    private static func run(_ args: Arguments) throws {
        if args.command == "help" || args.command == "--help" || args.flags.contains("--help") {
            print("""
            ocio-metal — Swift 6 / Metal color management debug CLI

            info                 Show upstream revision and archive counts
            configs              List all built-in configurations
            spaces               List all spaces, including inactive and data spaces
            builtins             List all registered built-in transforms
            named                Apply --name NAME [--inverse] from a configuration
            look                 Apply --name NAME [--inverse] in its process space
            views                List display/view names and their source spaces
            convert              Convert RGBA pixels (--src SPACE --dst SPACE)
            builtin              Apply --style NAME [--inverse]
            display              Apply --src SPACE --display NAME --view NAME [--inverse]
            validate             Validate the complete archive and pair coverage

            Common: --archive DIRECTORY --config ID
            Custom config: convert/display --ocio FILE (native Swift parsing and compilation)
            Pixels: --rgba '0.18,0.18,0.18,1' (multiple RGBA tuples allowed)
                    --input FILE --output FILE --binary (little-endian Float32 RGBA)
                    With --binary, omitted input/output use stdin/stdout.
            """)
            return
        }
        if let path = args.values["--ocio"], ["convert", "display", "named", "look"].contains(args.command) {
            try runNative(args, path: path)
            return
        }
        let catalogue = try args.values["--archive"].map {
            try OCIOCatalogue(contentsOf: URL(fileURLWithPath: $0, isDirectory: true))
        } ?? OCIOCatalogue.bundled()
        switch args.command {
        case "info":
            try printJSON(["upstream": catalogue.upstream.commit, "version": catalogue.upstream.version,
                           "configurations": String(catalogue.configurations.count),
                           "builtins": String(catalogue.builtins.count),
                           "uniqueShaders": String(catalogue.transforms.count),
                           "defaultConfiguration": catalogue.defaultConfiguration])
        case "configs": try printJSON(catalogue.configurations.map { ["id": $0.id, "name": $0.name] })
        case "spaces": try printJSON(catalogue.configuration(args.values["--config"]).colorSpaces)
        case "builtins": try printJSON(catalogue.builtins)
        case "views": try printJSON(catalogue.configuration(args.values["--config"]).displayViews)
        case "validate":
            try catalogue.validateResources()
            for config in catalogue.configurations {
                let expected = config.colorSpaces.count * config.colorSpaces.count
                guard config.conversions.count == expected else {
                    throw OCIOError.invalidArchive("\(config.id): \(config.conversions.count)/\(expected) pairs")
                }
            }
            if args.flags.contains("--gpu") {
                do {
                    let engine = try MetalColorEngine(catalogue: catalogue)
                    let validator = try ReferenceValidator(catalogue: catalogue,
                        validationURL: args.values["--suite"].map { URL(fileURLWithPath: $0) })
                    let report = try validator.validate(using: engine) { completed, total in
                        if completed.isMultiple(of: 100) || completed == total {
                            FileHandle.standardError.write(Data("GPU reference cases: \(completed)/\(total)\n".utf8))
                        }
                    }
                    if let path = args.values["--output"] {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                    try printJSON(report)
                    guard report.passed else { throw OCIOError.metalFailure("CPU/Metal numerical comparison failed") }
                } catch OCIOError.metalUnavailable {
                    if let path = args.values["--output"] {
                        let report = ["status": "unverified", "reason": "No Metal device on this runner", "gpuExecution": "false"]
                        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                    throw OCIOError.metalUnavailable
                }
            } else {
                print("Archive resources and every configured color-space pair are present.")
            }
        case "convert", "builtin", "display", "named", "look":
            let engine = try MetalColorEngine(catalogue: catalogue)
            let processor: ColorProcessor
            let direction: TransformDirection = args.flags.contains("--inverse") ? .inverse : .forward
            let document = try args.values["--ocio"].map { try OCIOConfigDocument(contentsOf: URL(fileURLWithPath: $0)) }
            switch args.command {
            case "builtin": processor = try engine.builtinProcessor(args.required("--style"), direction: direction)
            case "named":
                if let document {
                    let steps = try document.namedTransformPlan(args.required("--name"), direction: direction == .forward ? .forward : .inverse)
                    processor = try engine.nativeProcessor(stages: document.nativeStages(steps: steps))
                } else { processor = try engine.namedTransformProcessor(configuration: args.values["--config"], name: args.required("--name"), direction: direction) }
            case "look":
                guard document == nil else { throw OCIOError.invalidInput("Use a LookTransform in --ocio or a configured display view for a custom look") }
                processor = try engine.lookProcessor(configuration: args.values["--config"], name: args.required("--name"), direction: direction)
            case "display":
                if let document { processor = try engine.nativeDisplayProcessor(configuration: document,
                    source: args.required("--src"), display: args.required("--display"), view: args.required("--view"), direction: direction) }
                else { processor = try engine.displayProcessor(configuration: args.values["--config"],
                    source: args.required("--src"), display: args.required("--display"), view: args.required("--view"), direction: direction) }
            default:
                if let document { processor = try engine.nativeProcessor(configuration: document,
                    source: args.required("--src"), destination: args.required("--dst")) }
                else { processor = try engine.processor(configuration: args.values["--config"],
                    source: args.required("--src"), destination: args.required("--dst")) }
            }
            let input = try pixels(args)
            let result = try processor.processRGBA(input)
            try writePixels(result, arguments: args)
        default: throw OCIOError.invalidInput("Unknown command: \(args.command). Use help.")
        }
    }

    private static func runNative(_ args: Arguments, path: String) throws {
        let configuration = try OCIOConfigDocument(contentsOf: URL(fileURLWithPath: path))
        let engine: MetalColorEngine
        if let archive = args.values["--archive"] {
            engine = try MetalColorEngine(catalogue: OCIOCatalogue(contentsOf: URL(fileURLWithPath: archive)))
        } else {
            do { engine = try MetalColorEngine(catalogue: OCIOCatalogue.bundled()) }
            catch OCIOError.missingResource { engine = try MetalColorEngine() }
        }
        let inverse = args.flags.contains("--inverse")
        let processor: ColorProcessor
        switch args.command {
        case "named":
            let steps = try configuration.namedTransformPlan(args.required("--name"), direction: inverse ? .inverse : .forward)
            processor = try engine.nativeProcessor(stages: configuration.nativeStages(steps: steps))
        case "look":
            processor = try engine.nativeLookProcessor(configuration: configuration,
                name: args.required("--name"), direction: inverse ? .inverse : .forward)
        case "display":
            processor = try engine.nativeDisplayProcessor(configuration: configuration, source: args.required("--src"),
                display: args.required("--display"), view: args.required("--view"), direction: inverse ? .inverse : .forward)
        default:
            processor = try engine.nativeProcessor(configuration: configuration, source: args.required("--src"), destination: args.required("--dst"))
        }
        try writePixels(processor.processRGBA(pixels(args)), arguments: args)
    }

    private static func writePixels(_ result: [Float], arguments args: Arguments) throws {
        if args.flags.contains("--binary") {
            var data = Data(capacity: result.count * 4)
            for value in result {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            if let path = args.values["--output"] { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            else { FileHandle.standardOutput.write(data) }
        } else { try printJSON(result) }
    }

    private static func pixels(_ args: Arguments) throws -> [Float] {
        if args.flags.contains("--binary") {
            let data: Data
            if let path = args.values["--input"] { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
            else { data = FileHandle.standardInput.readDataToEndOfFile() }
            guard data.count.isMultiple(of: 16) else { throw OCIOError.invalidInput("Binary input must contain whole Float32 RGBA pixels") }
            return data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
        }
        let text = try args.required("--rgba")
        let parts = text.split { $0 == "," || $0 == ";" || $0.isWhitespace }
        let values = try parts.map { part -> Float in
            guard let value = Float(part) else { throw OCIOError.invalidInput("Invalid Float32 value: \(part)") }
            return value
        }
        guard values.count.isMultiple(of: 4), !values.isEmpty else { throw OCIOError.invalidInput("--rgba requires groups of four floats") }
        return values
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([10]))
    }
}
