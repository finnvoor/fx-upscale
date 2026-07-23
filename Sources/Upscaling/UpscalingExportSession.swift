import AVFoundation
import VideoToolbox

// MARK: - UpscalingExportSession

public class UpscalingExportSession {
    // MARK: Lifecycle

    public init(
        asset: AVAsset,
        outputCodec: AVVideoCodecType? = nil,
        preferredOutputURL: URL,
        outputSize: CGSize,
        creator: String? = nil
    ) {
        self.asset = asset
        self.outputCodec = outputCodec
        if preferredOutputURL.pathExtension.lowercased() != "mov", outputCodec?.isProRes ?? false {
            outputURL = preferredOutputURL
                .deletingPathExtension()
                .appendingPathExtension("mov")
        } else {
            outputURL = preferredOutputURL
        }
        self.outputSize = outputSize
        self.creator = creator
        progress = Progress(parent: nil, userInfo: [
            .fileURLKey: outputURL
        ])
        progress.fileURL = outputURL
        progress.isCancellable = false
        #if os(macOS)
        progress.publish()
        #endif
    }

    // MARK: Public

    public static let maxOutputSize = 16384

    public let asset: AVAsset
    public let outputCodec: AVVideoCodecType?
    public let outputURL: URL
    public let outputSize: CGSize
    public let creator: String?

    public let progress: Progress

    public func export() async throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw Error.outputURLAlreadyExists
        }

        let outputFileType: AVFileType = switch outputURL.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }

        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
        assetWriter.metadata = try await asset.load(.metadata)

        let assetReader = try AVAssetReader(asset: asset)

        let duration = try await asset.load(.duration)

        var mediaTracks: [MediaTrack] = []
        let tracks = try await asset.load(.tracks)
        for track in tracks {
            guard [.audio, .video].contains(track.mediaType) else { continue }
            let formatDescription = try await track.load(.formatDescriptions).first

            if #available(macOS 14.0, iOS 17.0, *),
               track.mediaType == .video,
               formatDescription?.hasLeftAndRightEye ?? false {
                let effectiveCodec = outputCodec ?? formatDescription?.videoCodecType ?? .hevc
                guard effectiveCodec.supportsMultiviewHEVC else {
                    throw Error.codecDoesNotSupportSpatialVideo(effectiveCodec)
                }
            }

            guard let assetReaderOutput = Self.assetReaderOutput(
                for: track,
                formatDescription: formatDescription,
                outputCodec: outputCodec
            ),
                let assetWriterInput = try await Self.assetWriterInput(
                    for: track,
                    formatDescription: formatDescription,
                    outputSize: outputSize,
                    outputCodec: outputCodec
                ) else { continue }

            if assetReader.canAdd(assetReaderOutput) {
                assetReader.add(assetReaderOutput)
            } else {
                throw Error.couldNotAddAssetReaderOutput(track.mediaType)
            }

            if assetWriter.canAdd(assetWriterInput) {
                assetWriter.add(assetWriterInput)
            } else {
                throw Error.couldNotAddAssetWriterInput(track.mediaType)
            }

            if track.mediaType == .audio {
                progress.totalUnitCount += 1
                mediaTracks.append(.audio(assetReaderOutput, assetWriterInput))
            } else if track.mediaType == .video {
                progress.totalUnitCount += 10
                if #available(macOS 14.0, iOS 17.0, *),
                   Self.shouldExportSpatialVideo(
                       formatDescription: formatDescription,
                       outputCodec: outputCodec
                   ) {
                    try await mediaTracks.append(.spatialVideo(
                        assetReaderOutput,
                        assetWriterInput,
                        track.load(.naturalSize),
                        AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
                            assetWriterInput: assetWriterInput,
                            sourcePixelBufferAttributes: [
                                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true,
                                kCVPixelBufferWidthKey as String: outputSize.width,
                                kCVPixelBufferHeightKey as String: outputSize.height
                            ]
                        )
                    ))
                } else {
                    try await mediaTracks.append(.video(
                        assetReaderOutput,
                        assetWriterInput,
                        track.load(.naturalSize),
                        AVAssetWriterInputPixelBufferAdaptor(
                            assetWriterInput: assetWriterInput,
                            sourcePixelBufferAttributes: [
                                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true,
                                kCVPixelBufferWidthKey as String: outputSize.width,
                                kCVPixelBufferHeightKey as String: outputSize.height
                            ]
                        )
                    ))
                }
            }
        }

        assert(assetWriter.inputs.count == assetReader.outputs.count)

        assetWriter.startWriting()
        assetReader.startReading()
        assetWriter.startSession(atSourceTime: .zero)

        do {
            try await withThrowingTaskGroup(of: Void.self) { [weak self] group in
                for mediaTrack in mediaTracks {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        switch mediaTrack {
                        case let .audio(output, input):
                            let progress = Progress(totalUnitCount: Int64(duration.seconds))
                            self.progress.addChild(progress, withPendingUnitCount: 1)
                            try await Self.processAudioSamples(from: output, to: input, progress: progress)
                        case let .video(output, input, inputSize, adaptor):
                            let progress = Progress(totalUnitCount: Int64(duration.seconds))
                            self.progress.addChild(progress, withPendingUnitCount: 10)
                            try await Self.processVideoSamples(
                                from: output,
                                to: input,
                                adaptor: adaptor,
                                inputSize: inputSize,
                                outputSize: outputSize,
                                progress: progress
                            )
                        case let .spatialVideo(output, input, inputSize, adaptor):
                            if #available(macOS 14.0, iOS 17.0, *) {
                                let progress = Progress(totalUnitCount: Int64(duration.seconds))
                                self.progress.addChild(progress, withPendingUnitCount: 10)
                                try await Self.processSpatialVideoSamples(
                                    from: output,
                                    to: input,
                                    adaptor: adaptor as! AVAssetWriterInputTaggedPixelBufferGroupAdaptor,
                                    inputSize: inputSize,
                                    outputSize: outputSize,
                                    progress: progress
                                )
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        if let error = assetWriter.error {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        if let error = assetReader.error {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        if assetWriter.status == .cancelled || assetReader.status == .cancelled {
            try? FileManager.default.removeItem(at: outputURL)
            return
        }

        await assetWriter.finishWriting()

        if let creator {
            let value = try PropertyListSerialization.data(
                fromPropertyList: creator,
                format: .binary,
                options: 0
            )
            _ = outputURL.withUnsafeFileSystemRepresentation { fileSystemPath in
                value.withUnsafeBytes {
                    setxattr(
                        fileSystemPath,
                        "com.apple.metadata:kMDItemCreator",
                        $0.baseAddress,
                        value.count,
                        0,
                        0
                    )
                }
            }
        }
    }

    // MARK: Private

    private enum MediaTrack {
        case audio(
            _ output: AVAssetReaderOutput,
            _ input: AVAssetWriterInput
        )
        case video(
            _ output: AVAssetReaderOutput,
            _ input: AVAssetWriterInput,
            _ inputSize: CGSize,
            _ adaptor: AVAssetWriterInputPixelBufferAdaptor
        )
        case spatialVideo(
            _ output: AVAssetReaderOutput,
            _ input: AVAssetWriterInput,
            _ inputSize: CGSize,
            _ adaptor: NSObject
        )
    }

    private static func encoder(
        _ codec: AVVideoCodecType,
        supportsProperty property: CFString,
        outputSize: CGSize
    ) -> Bool {
        guard let codecType = codec.cmVideoCodecType else { return false }
        var supportedProperties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(outputSize.width),
            height: Int32(outputSize.height),
            codecType: codecType,
            encoderSpecification: nil,
            encoderIDOut: nil,
            supportedPropertiesOut: &supportedProperties
        )
        guard status == noErr,
              let supportedProperties = supportedProperties as? [String: Any] else { return false }
        return supportedProperties[property as String] != nil
    }

    /// Whether the export should produce an MV-HEVC (spatial) video: the source
    /// must contain left and right eye layers and the output codec must support MV-HEVC.
    @available(macOS 14.0, iOS 17.0, *)
    private static func shouldExportSpatialVideo(
        formatDescription: CMFormatDescription?,
        outputCodec: AVVideoCodecType?
    ) -> Bool {
        guard formatDescription?.hasLeftAndRightEye ?? false else { return false }
        let effectiveCodec = outputCodec ?? formatDescription?.videoCodecType ?? .hevc
        return effectiveCodec.supportsMultiviewHEVC
    }

    private static func assetReaderOutput(
        for track: AVAssetTrack,
        formatDescription: CMFormatDescription?,
        outputCodec: AVVideoCodecType?
    ) -> AVAssetReaderOutput? {
        switch track.mediaType {
        case .video:
            var outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            if #available(macOS 14.0, iOS 17.0, *),
               shouldExportSpatialVideo(
                   formatDescription: formatDescription,
                   outputCodec: outputCodec
               ) {
                outputSettings[AVVideoDecompressionPropertiesKey] = [
                    kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs: [0, 1]
                ]
            }
            let assetReaderOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: outputSettings
            )
            assetReaderOutput.alwaysCopiesSampleData = false
            return assetReaderOutput
        case .audio:
            let assetReaderOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            assetReaderOutput.alwaysCopiesSampleData = false
            return assetReaderOutput
        default: return nil
        }
    }

    private static func assetWriterInput(
        for track: AVAssetTrack,
        formatDescription: CMFormatDescription?,
        outputSize: CGSize,
        outputCodec: AVVideoCodecType?
    ) async throws -> AVAssetWriterInput? {
        switch track.mediaType {
        case .video:
            let codec = outputCodec ?? formatDescription?.videoCodecType ?? .hevc
            var outputSettings: [String: Any] = [
                AVVideoWidthKey: outputSize.width,
                AVVideoHeightKey: outputSize.height,
                AVVideoCodecKey: codec
            ]
            if let colorPrimaries = formatDescription?.colorPrimaries,
               let colorTransferFunction = formatDescription?.colorTransferFunction,
               let colorYCbCrMatrix = formatDescription?.colorYCbCrMatrix {
                outputSettings[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: colorPrimaries,
                    AVVideoTransferFunctionKey: colorTransferFunction,
                    AVVideoYCbCrMatrixKey: colorYCbCrMatrix
                ]
            }
            var compressionProperties: [CFString: Any] = [:]
            // Speed up the encoder where supported; querying at runtime avoids
            // setting it where it would throw (ProRes, H.264 above ~4K, etc).
            if Self.encoder(
                codec,
                supportsProperty: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                outputSize: outputSize
            ) {
                compressionProperties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] = true
            }
            if #available(macOS 14.0, iOS 17.0, *),
               shouldExportSpatialVideo(
                   formatDescription: formatDescription,
                   outputCodec: outputCodec
               ) {
                compressionProperties[kVTCompressionPropertyKey_MVHEVCVideoLayerIDs] = [0, 1]
                if let extensions = formatDescription?.extensions {
                    for key in [
                        kVTCompressionPropertyKey_HeroEye,
                        kVTCompressionPropertyKey_StereoCameraBaseline,
                        kVTCompressionPropertyKey_HorizontalDisparityAdjustment,
                        kCMFormatDescriptionExtension_HorizontalFieldOfView
                    ] {
                        if let value = extensions.first(
                            where: { $0.key == key }
                        )?.value {
                            compressionProperties[key] = value
                        }
                    }
                }
            }
            if !compressionProperties.isEmpty {
                outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties
            }
            let assetWriterInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: outputSettings
            )
            assetWriterInput.transform = try await track.load(.preferredTransform)
            assetWriterInput.expectsMediaDataInRealTime = false
            return assetWriterInput
        case .audio:
            let assetWriterInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            assetWriterInput.expectsMediaDataInRealTime = false
            return assetWriterInput
        default: return nil
        }
    }

    private static func processAudioSamples(
        from assetReaderOutput: AVAssetReaderOutput,
        to assetWriterInput: AVAssetWriterInput,
        progress: Progress
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(
                label: "\(String(describing: Self.self)).audio.\(UUID().uuidString)",
                qos: .userInitiated
            )
            assetWriterInput.requestMediaDataWhenReady(on: queue) {
                while assetWriterInput.isReadyForMoreMediaData {
                    if let nextSampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
                        if nextSampleBuffer.presentationTimeStamp.isNumeric {
                            let timestamp = Int64(nextSampleBuffer.presentationTimeStamp.seconds)
                            DispatchQueue.main.async {
                                progress.completedUnitCount = timestamp
                            }
                        }
                        guard assetWriterInput.append(nextSampleBuffer) else {
                            assetWriterInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                    } else {
                        assetWriterInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        } as Void
    }

    private static let maxFramesInFlight = 3

    private static func processVideoSamples(
        from assetReaderOutput: AVAssetReaderOutput,
        to assetWriterInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        inputSize: CGSize,
        outputSize: CGSize,
        progress: Progress
    ) async throws {
        guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
            throw Error.failedToCreateUpscaler
        }

        let channel = FrameChannel<CVPixelBuffer>(capacity: maxFramesInFlight)

        DispatchQueue(
            label: "\(String(describing: Self.self)).video.read.\(UUID().uuidString)",
            qos: .userInitiated
        ).async {
            while let sampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
                guard let imageBuffer = sampleBuffer.imageBuffer else {
                    channel.finish(throwing: Error.missingImageBuffer)
                    return
                }
                let frame = FrameChannel<CVPixelBuffer>.PendingFrame(
                    time: sampleBuffer.presentationTimeStamp
                )
                guard channel.enqueue(frame) else { return }
                upscaler.upscale(imageBuffer, pixelBufferPool: adaptor.pixelBufferPool) { upscaled in
                    frame.fulfill(upscaled)
                }
            }
            channel.finish()
        }

        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(
                label: "\(String(describing: Self.self)).video.write.\(UUID().uuidString)",
                qos: .userInitiated
            )
            assetWriterInput.requestMediaDataWhenReady(on: queue) {
                while assetWriterInput.isReadyForMoreMediaData {
                    guard let frame = channel.dequeue() else {
                        assetWriterInput.markAsFinished()
                        if let error = channel.terminationError {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                        return
                    }
                    let upscaledImageBuffer = frame.wait()
                    if frame.time.isNumeric {
                        let timestamp = Int64(frame.time.seconds)
                        DispatchQueue.main.async { progress.completedUnitCount = timestamp }
                    }
                    guard adaptor.append(
                        upscaledImageBuffer,
                        withPresentationTime: frame.time
                    ) else {
                        assetWriterInput.markAsFinished()
                        channel.abort()
                        continuation.resume()
                        return
                    }
                }
            }
        } as Void
    }

    @available(macOS 14.0, iOS 17.0, *) private static func processSpatialVideoSamples(
        from assetReaderOutput: AVAssetReaderOutput,
        to assetWriterInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputTaggedPixelBufferGroupAdaptor,
        inputSize: CGSize,
        outputSize: CGSize,
        progress: Progress
    ) async throws {
        guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
            throw Error.failedToCreateUpscaler
        }

        let channel = FrameChannel<(CVPixelBuffer, CVPixelBuffer)>(capacity: maxFramesInFlight)

        let readerQueue = DispatchQueue(
            label: "\(String(describing: Self.self)).spatialvideo.read.\(UUID().uuidString)",
            qos: .userInitiated
        )
        readerQueue.async {
            while let sampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
                guard let taggedBuffers = sampleBuffer.taggedBuffers else {
                    channel.finish(throwing: Error.missingTaggedBuffers)
                    return
                }
                let leftEyeBuffer = taggedBuffers.first(where: {
                    $0.tags.first(matchingCategory: .stereoView) == .stereoView(.leftEye)
                })?.buffer
                let rightEyeBuffer = taggedBuffers.first(where: {
                    $0.tags.first(matchingCategory: .stereoView) == .stereoView(.rightEye)
                })?.buffer
                guard let leftEyeBuffer,
                      let rightEyeBuffer,
                      case let .pixelBuffer(leftEyePixelBuffer) = leftEyeBuffer,
                      case let .pixelBuffer(rightEyePixelBuffer) = rightEyeBuffer else {
                    channel.finish(throwing: Error.invalidTaggedBuffers)
                    return
                }
                let frame = FrameChannel<(CVPixelBuffer, CVPixelBuffer)>.PendingFrame(
                    time: sampleBuffer.presentationTimeStamp
                )
                guard channel.enqueue(frame) else { return }
                let group = DispatchGroup()
                var upscaledLeft: CVPixelBuffer?
                var upscaledRight: CVPixelBuffer?
                group.enter()
                upscaler.upscale(leftEyePixelBuffer, pixelBufferPool: adaptor.pixelBufferPool) {
                    upscaledLeft = $0
                    group.leave()
                }
                group.enter()
                upscaler.upscale(rightEyePixelBuffer, pixelBufferPool: adaptor.pixelBufferPool) {
                    upscaledRight = $0
                    group.leave()
                }
                group.notify(queue: readerQueue) {
                    frame.fulfill((upscaledLeft!, upscaledRight!))
                }
            }
            channel.finish()
        }

        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(
                label: "\(String(describing: Self.self)).spatialvideo.write.\(UUID().uuidString)",
                qos: .userInitiated
            )
            assetWriterInput.requestMediaDataWhenReady(on: queue) {
                while assetWriterInput.isReadyForMoreMediaData {
                    guard let frame = channel.dequeue() else {
                        assetWriterInput.markAsFinished()
                        if let error = channel.terminationError {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                        return
                    }
                    let (upscaledLeftEyePixelBuffer, upscaledRightEyePixelBuffer) = frame.wait()
                    if frame.time.isNumeric {
                        let timestamp = Int64(frame.time.seconds)
                        DispatchQueue.main.async { progress.completedUnitCount = timestamp }
                    }
                    let leftEyeTaggedBuffer = CMTaggedBuffer(
                        tags: [.stereoView(.leftEye), .videoLayerID(0)],
                        pixelBuffer: upscaledLeftEyePixelBuffer
                    )
                    let rightEyeTaggedBuffer = CMTaggedBuffer(
                        tags: [.stereoView(.rightEye), .videoLayerID(1)],
                        pixelBuffer: upscaledRightEyePixelBuffer
                    )
                    guard adaptor.appendTaggedBuffers(
                        [leftEyeTaggedBuffer, rightEyeTaggedBuffer],
                        withPresentationTime: frame.time
                    ) else {
                        assetWriterInput.markAsFinished()
                        channel.abort()
                        continuation.resume()
                        return
                    }
                }
            }
        } as Void
    }
}

// MARK: UpscalingExportSession.Error

public extension UpscalingExportSession {
    enum Error: Swift.Error {
        case outputURLAlreadyExists
        case couldNotAddAssetReaderOutput(AVMediaType)
        case couldNotAddAssetWriterInput(AVMediaType)
        case missingImageBuffer
        case missingTaggedBuffers
        case invalidTaggedBuffers
        case failedToCreateUpscaler
        case codecDoesNotSupportSpatialVideo(AVVideoCodecType)
    }
}

// MARK: - UpscalingExportSession.Error + LocalizedError

extension UpscalingExportSession.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .codecDoesNotSupportSpatialVideo(codec):
            "The \(codec.rawValue) codec does not support spatial (MV-HEVC) video. " +
                "Use the HEVC codec to preserve spatial video."
        default:
            "\(self)"
        }
    }
}
