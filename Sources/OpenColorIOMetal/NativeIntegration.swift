#if canImport(Metal)
extension MetalColorEngine {
    /// Loads a parsed user configuration into native Float32 Metal stages, including archived builtin transforms.
    public func nativeProcessor(configuration: OCIOConfigDocument, source: String, destination: String,
                                dataBypass: Bool = true) throws -> ColorProcessor {
        try nativeProcessor(stages: configuration.nativeStages(from: source, to: destination, dataBypass: dataBypass))
    }

    public func nativeDisplayProcessor(configuration: OCIOConfigDocument, source: String, display: String,
                                       view: String, direction: TransformDirection = .forward,
                                       looksBypass: Bool = false, dataBypass: Bool = true) throws -> ColorProcessor {
        try nativeProcessor(stages: configuration.nativeDisplayStages(source: source, display: display, view: view,
            direction: direction == .forward ? .forward : .inverse, looksBypass: looksBypass, dataBypass: dataBypass))
    }

    public func nativeProcessor(stages: [OCIONativeStage]) throws -> ColorProcessor {
        let processors = try stages.map { stage in
            switch stage {
            case .shader(let shader):
                let textures = shader.textures.map {
                    MetalTextureBinding(index: $0.index, dimension: $0.dimension, width: $0.width,
                        height: $0.height, depth: $0.depth, channels: $0.channels, values: $0.values)
                }
                return try processor(metalSource: shader.source, kernel: shader.kernel, textures: textures)
            case .builtin(let style, let direction):
                return try builtinProcessor(style, direction: direction == .forward ? .forward : .inverse)
            }
        }
        return try concatenate(processors)
    }
}
#endif
