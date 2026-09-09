import Foundation
#if canImport(Metal)
@preconcurrency import Metal

fileprivate final class CompiledTransform: @unchecked Sendable {
    let pipeline: any MTLComputePipelineState
    let textures: [(Int, any MTLTexture)]

    init(pipeline: any MTLComputePipelineState, textures: [(Int, any MTLTexture)]) {
        self.pipeline = pipeline
        self.textures = textures
    }
}

/// Native Float32 LUT data. The source kernel defines interpolation and binds this texture at `index`.
public struct MetalTextureBinding: Sendable {
    public let index: Int
    public let dimension: Int
    public let width: Int
    public let height: Int
    public let depth: Int
    public let channels: Int
    public let values: [Float]

    public init(index: Int, dimension: Int, width: Int, height: Int = 1, depth: Int = 1,
                channels: Int = 3, values: [Float]) {
        self.index = index
        self.dimension = dimension
        self.width = width
        self.height = height
        self.depth = depth
        self.channels = channels
        self.values = values
    }
}

/// Thread-safe compiler/cache for immutable color processors. Metal performs every color operation.
public final class MetalColorEngine: @unchecked Sendable {
    public let catalogue: OCIOCatalogue
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let cacheLock = NSLock()
    private var cache: [String: CompiledTransform] = [:]
    private var cacheOrder: [String] = []
    private let cacheCapacity: Int

    public init(catalogue: OCIOCatalogue, device: (any MTLDevice)? = nil, cacheCapacity: Int = 128) throws {
        guard let selectedDevice = device ?? MTLCreateSystemDefaultDevice() else { throw OCIOError.metalUnavailable }
        guard let queue = selectedDevice.makeCommandQueue() else { throw OCIOError.metalFailure("cannot allocate command queue") }
        self.catalogue = catalogue
        self.device = selectedDevice
        self.queue = queue
        self.cacheCapacity = max(0, cacheCapacity)
    }

    public func processor(configuration: String? = nil, source: String, destination: String) throws -> ColorProcessor {
        let config = try catalogue.configuration(configuration)
        let conversion = try config.conversion(source: source, destination: destination)
        return try processor(transformIDs: conversion.pipeline)
    }

    public func displayProcessor(configuration: String? = nil, source: String, display: String,
                                 view: String, direction: TransformDirection = .forward) throws -> ColorProcessor {
        let config = try catalogue.configuration(configuration)
        let space = try config.colorSpace(named: source)
        guard let transform = config.displayViews.first(where: {
            $0.source == space.name && $0.display.caseInsensitiveCompare(display) == .orderedSame &&
            $0.view.caseInsensitiveCompare(view) == .orderedSame && $0.direction == direction
        }) else {
            throw OCIOError.unsupportedConversion("\(config.id): \(source), display \(display), view \(view), \(direction.rawValue)")
        }
        return try processor(transformIDs: transform.pipeline)
    }

    public func builtinProcessor(_ name: String, direction: TransformDirection = .forward) throws -> ColorProcessor {
        guard let builtin = catalogue.builtins.first(where: { $0.name == name }) else {
            throw OCIOError.unknownTransform(name)
        }
        return try processor(transformIDs: direction == .forward ? builtin.forward : builtin.inverse)
    }

    public func processor(transformIDs: [String]) throws -> ColorProcessor {
        let stages = try transformIDs.map { try compiledTransform($0) }
        return ColorProcessor(device: device, queue: queue, stages: stages, transformIDs: transformIDs)
    }

    /// Composes archive and native processors in order without a CPU round trip or MSL symbol rewriting.
    public func concatenate(_ processors: [ColorProcessor]) throws -> ColorProcessor {
        guard processors.allSatisfy({ $0.device.registryID == device.registryID }) else {
            throw OCIOError.invalidInput("all composed processors must belong to this Metal device")
        }
        return ColorProcessor(device: device, queue: queue, stages: processors.flatMap(\.stages),
                              transformIDs: processors.flatMap(\.transformIDs))
    }

    /// Compiles a native custom kernel using the archive ABI: float4 buffers 0/1, uint count at 2.
    public func processor(metalSource: String, kernel: String = "ocio_kernel",
                          textures: [MetalTextureBinding] = []) throws -> ColorProcessor {
        guard Set(textures.map(\.index)).count == textures.count else {
            throw OCIOError.invalidInput("custom shader contains duplicate texture bindings")
        }
        let resources = try textures.map { binding in
            (binding.index, try makeTexture(index: binding.index, dimension: binding.dimension,
                width: binding.width, height: binding.height, depth: binding.depth,
                channels: binding.channels, values: binding.values, label: "custom LUT \(binding.index)"))
        }
        let compiled = try compile(source: metalSource, kernel: kernel, textures: resources)
        return ColorProcessor(device: device, queue: queue, stages: [compiled], transformIDs: ["custom:\(kernel)"])
    }

    /// Releases only cached entries. Already-created processors retain their pipelines and LUT resources.
    public func clearCompilationCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func compiledTransform(_ id: String) throws -> CompiledTransform {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[id] {
            cacheOrder.removeAll { $0 == id }
            cacheOrder.append(id)
            return existing
        }
        let transform = try catalogue.transform(id)
        let source = try String(contentsOf: catalogue.resourceURL(transform.shader), encoding: .utf8)
        let textures = try transform.textures.map { ($0.bindingIndex, try makeTexture($0)) }
        let compiled = try compile(source: source, kernel: transform.kernel, textures: textures)
        if cacheCapacity > 0 {
            cache[id] = compiled
            cacheOrder.append(id)
            if cacheOrder.count > cacheCapacity { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        return compiled
    }

    private func compile(source: String, kernel: String,
                         textures: [(Int, any MTLTexture)]) throws -> CompiledTransform {
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        options.languageVersion = .version2_0
        do {
            let library = try device.makeLibrary(source: source, options: options)
            guard let function = library.makeFunction(name: kernel) else {
                throw OCIOError.metalFailure("kernel \(kernel) is absent from source")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            return CompiledTransform(pipeline: pipeline, textures: textures)
        } catch { throw OCIOError.metalFailure("compiling \(kernel): \(error)") }
    }

    private func makeTexture(_ spec: OCIOTexture) throws -> any MTLTexture {
        let source = try Data(contentsOf: catalogue.resourceURL(spec.data), options: .mappedIfSafe)
        let texelCount = try OCIOCatalogue.checkedProduct([spec.width, spec.height, spec.depth])
        let inputByteCount = try OCIOCatalogue.checkedProduct([texelCount, spec.channels, 4])
        guard source.count == inputByteCount else { throw OCIOError.invalidArchive("LUT size mismatch: \(spec.data)") }
        var values = [Float](repeating: 0, count: inputByteCount / 4)
        source.withUnsafeBytes { bytes in
            for index in values.indices {
                let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                values[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return try makeTexture(index: spec.bindingIndex, dimension: spec.dimension, width: spec.width,
            height: spec.height, depth: spec.depth, channels: spec.channels, values: values, label: spec.name)
    }

    private func makeTexture(index: Int, dimension: Int, width: Int, height: Int, depth: Int,
                             channels: Int, values: [Float], label: String) throws -> any MTLTexture {
        guard (0..<128).contains(index), (1...3).contains(dimension), [1, 3, 4].contains(channels),
              width > 0, height > 0, depth > 0,
              dimension != 1 || (height == 1 && depth == 1), dimension != 2 || depth == 1 else {
            throw OCIOError.invalidInput("invalid texture dimensions, channel count or binding for \(label)")
        }
        let count = try OCIOCatalogue.checkedProduct([width, height, depth, channels])
        guard values.count == count else { throw OCIOError.invalidInput("LUT value count differs from dimensions: \(label)") }
        let outputChannels = channels == 1 ? 1 : 4
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = dimension == 3 ? .type3D : (dimension == 2 ? .type2D : .type1D)
        descriptor.pixelFormat = channels == 1 ? .r32Float : .rgba32Float
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.mipmapLevelCount = 1
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OCIOError.metalFailure("cannot allocate LUT \(label), \(width)×\(height)×\(depth)")
        }
        texture.label = label
        var expanded: [Float]
        if channels == 3 {
            expanded = [Float](repeating: 1, count: try OCIOCatalogue.checkedProduct([width, height, depth, 4]))
            for texel in 0..<(count / 3) {
                for channel in 0..<3 { expanded[texel * 4 + channel] = values[texel * 3 + channel] }
            }
        } else { expanded = values }
        expanded.withUnsafeBytes { bytes in
            let region = MTLRegionMake3D(0, 0, 0, width, height, depth)
            if dimension == 3 {
                texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                                bytesPerRow: width * outputChannels * 4, bytesPerImage: width * height * outputChannels * 4)
            } else {
                texture.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!,
                                bytesPerRow: width * outputChannels * 4)
            }
        }
        return texture
    }
}

/// Immutable and reusable across threads. Each invocation creates independent command buffers and scratch resources.
public final class ColorProcessor: @unchecked Sendable {
    public let device: any MTLDevice
    public let transformIDs: [String]
    public var isIdentity: Bool { stages.isEmpty }
    private let queue: any MTLCommandQueue
    fileprivate let stages: [CompiledTransform]
    private let transferLock = NSLock()
    private var transfers: (any MTLComputePipelineState, any MTLComputePipelineState)?

    fileprivate init(device: any MTLDevice, queue: any MTLCommandQueue,
                     stages: [CompiledTransform], transformIDs: [String]) {
        self.device = device
        self.queue = queue
        self.stages = stages
        self.transformIDs = transformIDs
    }

    /// Interleaved RGBA Float32. No gamut clamp, quantization, alpha normalization or premultiplication is applied.
    public func processRGBA(_ rgba: [Float]) throws -> [Float] {
        guard rgba.count % 4 == 0 else { throw OCIOError.invalidInput("RGBA array length must be divisible by four") }
        guard !rgba.isEmpty, !isIdentity else { return rgba }
        let pixelCount = rgba.count / 4
        let length = try checkedByteCount(pixelCount)
        let input = try rgba.withUnsafeBytes { bytes -> any MTLBuffer in
            guard let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: length, options: .storageModeShared) else {
                throw OCIOError.metalFailure("cannot allocate input buffer")
            }
            return buffer
        }
        let output = try makeBuffer(length: length)
        let command = try makeCommandBuffer()
        try encode(commandBuffer: command, input: input, output: output, pixelCount: pixelCount)
        try commitAndWait(command)
        let pointer = output.contents().bindMemory(to: Float.self, capacity: rgba.count)
        return Array(UnsafeBufferPointer(start: pointer, count: rgba.count))
    }

    public func apply(_ pixels: [SIMD4<Float>]) throws -> [SIMD4<Float>] {
        guard !pixels.isEmpty, !isIdentity else { return pixels }
        let length = try checkedByteCount(pixels.count)
        let input = try pixels.withUnsafeBytes { bytes -> any MTLBuffer in
            guard let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: length, options: .storageModeShared) else {
                throw OCIOError.metalFailure("cannot allocate input buffer")
            }
            return buffer
        }
        let output = try makeBuffer(length: length)
        let command = try makeCommandBuffer()
        try encode(commandBuffer: command, input: input, output: output, pixelCount: pixels.count)
        try commitAndWait(command)
        let pointer = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels.count)
        return Array(UnsafeBufferPointer(start: pointer, count: pixels.count))
    }

    /// Encodes into an uncommitted command buffer; the caller commits and observes completion/errors.
    /// The command buffer must retain references (the default). Buffer offsets are bytes and must align to float4.
    public func encode(commandBuffer: any MTLCommandBuffer, input: any MTLBuffer, inputOffset: Int = 0,
                       output: any MTLBuffer, outputOffset: Int = 0, pixelCount: Int) throws {
        try validate(commandBuffer: commandBuffer)
        guard input.device.registryID == device.registryID, output.device.registryID == device.registryID else {
            throw OCIOError.invalidInput("buffers belong to a different Metal device")
        }
        guard inputOffset >= 0, outputOffset >= 0, inputOffset % 16 == 0, outputOffset % 16 == 0 else {
            throw OCIOError.invalidInput("buffer offsets must be nonnegative multiples of 16")
        }
        let byteCount = try checkedByteCount(pixelCount)
        guard inputOffset <= input.length, outputOffset <= output.length,
              byteCount <= input.length - inputOffset, byteCount <= output.length - outputOffset else {
            throw OCIOError.invalidInput("buffer range exceeds allocation")
        }
        guard pixelCount > 0 else { return }
        if input === output, inputOffset != outputOffset,
           inputOffset < outputOffset + byteCount, outputOffset < inputOffset + byteCount {
            throw OCIOError.invalidInput("partially overlapping input/output buffer ranges")
        }
        if isIdentity {
            if input === output && inputOffset == outputOffset { return }
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw OCIOError.metalFailure("cannot create blit encoder") }
            blit.copy(from: input, sourceOffset: inputOffset, to: output, destinationOffset: outputOffset, size: byteCount)
            blit.endEncoding()
            return
        }
        var currentInput: any MTLBuffer = input
        var currentOffset = inputOffset
        // Alternate two scratch buffers. They are retained by the command buffer until completion.
        let scratch = try (0..<min(2, stages.count - 1)).map { _ in try makeBuffer(length: byteCount) }
        for (index, stage) in stages.enumerated() {
            let isLast = index == stages.count - 1
            let target: any MTLBuffer = isLast ? output : scratch[index % scratch.count]
            let targetOffset = isLast ? outputOffset : 0
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw OCIOError.metalFailure("cannot create compute encoder") }
            encoder.label = "OCIO \(transformIDs[index])"
            encoder.setComputePipelineState(stage.pipeline)
            encoder.setBuffer(currentInput, offset: currentOffset, index: 0)
            encoder.setBuffer(target, offset: targetOffset, index: 1)
            var count = UInt32(pixelCount)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            for (binding, texture) in stage.textures { encoder.setTexture(texture, index: binding) }
            let groupWidth = min(stage.pipeline.threadExecutionWidth, stage.pipeline.maxTotalThreadsPerThreadgroup)
            encoder.dispatchThreads(MTLSize(width: pixelCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1))
            encoder.endEncoding()
            currentInput = target
            currentOffset = targetOffset
        }
    }

    /// Converts a complete 2D texture without resizing. Input and output must allow shader read/write respectively.
    /// Use rgba32Float to retain extended range and precision; normalized/sRGB formats apply Metal's format conversion.
    public func encode(commandBuffer: any MTLCommandBuffer, input: any MTLTexture, output: any MTLTexture) throws {
        try validate(commandBuffer: commandBuffer)
        guard input.device.registryID == device.registryID, output.device.registryID == device.registryID,
              input.textureType == .type2D, output.textureType == .type2D,
              input.width == output.width, input.height == output.height,
              input.sampleCount == 1, output.sampleCount == 1,
              input.usage.contains(.shaderRead), output.usage.contains(.shaderWrite) else {
            throw OCIOError.invalidInput("textures must be matching non-multisampled 2D textures on this device with shaderRead/shaderWrite usage")
        }
        let size = input.width.multipliedReportingOverflow(by: input.height)
        guard !size.overflow else { throw OCIOError.invalidInput("texture dimensions overflow") }
        let length = try checkedByteCount(size.partialValue)
        let unpacked = try makeBuffer(length: length)
        let converted = isIdentity ? unpacked : try makeBuffer(length: length)
        let (unpack, pack) = try textureTransferPipelines()
        try encodeTransfer(commandBuffer, pipeline: unpack, texture: input, buffer: unpacked)
        if !isIdentity {
            try encode(commandBuffer: commandBuffer, input: unpacked, output: converted, pixelCount: size.partialValue)
        }
        try encodeTransfer(commandBuffer, pipeline: pack, texture: output, buffer: converted)
    }

    private func validate(commandBuffer: any MTLCommandBuffer) throws {
        guard commandBuffer.device.registryID == device.registryID,
              commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued,
              commandBuffer.retainedReferences else {
            throw OCIOError.invalidInput("command buffer must be uncommitted, retain references, and belong to this Metal device")
        }
    }

    private func checkedByteCount(_ pixelCount: Int) throws -> Int {
        guard pixelCount >= 0, pixelCount <= Int(UInt32.max) else {
            throw OCIOError.invalidInput("pixel count must fit an unsigned 32-bit integer")
        }
        let result = pixelCount.multipliedReportingOverflow(by: MemoryLayout<SIMD4<Float>>.stride)
        guard !result.overflow, result.partialValue <= device.maxBufferLength else {
            throw OCIOError.invalidInput("pixel buffer exceeds this Metal device's maximum allocation")
        }
        return result.partialValue
    }

    private func makeBuffer(length: Int) throws -> any MTLBuffer {
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw OCIOError.metalFailure("cannot allocate \(length)-byte buffer")
        }
        return buffer
    }

    private func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let buffer = queue.makeCommandBuffer() else { throw OCIOError.metalFailure("cannot allocate command buffer") }
        buffer.label = "OpenColorIOMetal conversion"
        return buffer
    }

    private func commitAndWait(_ command: any MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw OCIOError.metalFailure(command.error?.localizedDescription ?? "command ended with status \(command.status.rawValue)")
        }
    }

    private func textureTransferPipelines() throws -> (any MTLComputePipelineState, any MTLComputePipelineState) {
        transferLock.lock()
        defer { transferLock.unlock() }
        if let transfers { return transfers }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void ocio_unpack(texture2d<float, access::read> image [[texture(0)]],
                                device float4* pixels [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
            if (xy.x < image.get_width() && xy.y < image.get_height())
                pixels[xy.y * image.get_width() + xy.x] = image.read(xy);
        }
        kernel void ocio_pack(texture2d<float, access::write> image [[texture(0)]],
                              device const float4* pixels [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
            if (xy.x < image.get_width() && xy.y < image.get_height())
                image.write(pixels[xy.y * image.get_width() + xy.x], xy);
        }
        """
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try device.makeLibrary(source: source, options: options)
            guard let unpack = library.makeFunction(name: "ocio_unpack"), let pack = library.makeFunction(name: "ocio_pack") else {
                throw OCIOError.metalFailure("texture transfer kernels missing")
            }
            let value = (try device.makeComputePipelineState(function: unpack), try device.makeComputePipelineState(function: pack))
            transfers = value
            return value
        } catch { throw OCIOError.metalFailure("compiling texture transfer kernels: \(error)") }
    }

    private func encodeTransfer(_ command: any MTLCommandBuffer, pipeline: any MTLComputePipelineState,
                                texture: any MTLTexture, buffer: any MTLBuffer) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw OCIOError.metalFailure("cannot create texture transfer encoder") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        let width = min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup)
        let height = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width))
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }
}
#endif
