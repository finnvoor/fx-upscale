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

        var mediaTracks: [MediaTrackTask] = []
        let tracks = try await asset.load(.tracks)
        for track in tracks {
            guard [.audio, .video].contains(track.mediaType) else { continue }
            let formatDescription = try await track.load(.formatDescriptions).first
            let pixelFormat = Self.workingPixelFormat(for: formatDescription)

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
                mediaTracks.append(MediaTrackTask(pendingUnitCount: 1) { progress in
                    try await Self.copyAudioSamples(from: assetReaderOutput, to: assetWriterInput, progress: progress)
                })
            } else if track.mediaType == .video {
                progress.totalUnitCount += 10
                let inputSize = try await track.load(.naturalSize)
                let outputSize = outputSize
                let sourcePixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferWidthKey as String: outputSize.width,
                    kCVPixelBufferHeightKey as String: outputSize.height
                ]
                if #available(macOS 14.0, iOS 17.0, *),
                   Self.shouldExportSpatialVideo(
                       formatDescription: formatDescription,
                       outputCodec: outputCodec
                   ) {
                    let adaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
                        assetWriterInput: assetWriterInput,
                        sourcePixelBufferAttributes: sourcePixelBufferAttributes
                    )
                    mediaTracks.append(MediaTrackTask(pendingUnitCount: 10) { progress in
                        try await Self.processVideoSamples(
                            from: assetReaderOutput,
                            to: assetWriterInput,
                            inputSize: inputSize,
                            outputSize: outputSize,
                            pixelFormat: pixelFormat,
                            progress: progress,
                            label: "\(String(describing: Self.self)).spatialvideo",
                            decode: { sampleBuffer -> (left: CVPixelBuffer, right: CVPixelBuffer) in
                                try Self.stereoscopicPixelBuffers(from: sampleBuffer)
                            },
                            submitUpscale: { upscaler, frame, completion in
                                let group = DispatchGroup()
                                var left: CVPixelBuffer?
                                var right: CVPixelBuffer?
                                group.enter()
                                upscaler.upscale(frame.left, pixelBufferPool: adaptor.pixelBufferPool) {
                                    left = $0
                                    group.leave()
                                }
                                group.enter()
                                upscaler.upscale(frame.right, pixelBufferPool: adaptor.pixelBufferPool) {
                                    right = $0
                                    group.leave()
                                }
                                group.notify(queue: .global(qos: .userInitiated)) {
                                    completion((left: left!, right: right!))
                                }
                            },
                            append: { frame, time in
                                adaptor.appendTaggedBuffers([
                                    CMTaggedBuffer(
                                        tags: [.stereoView(.leftEye), .videoLayerID(0)],
                                        pixelBuffer: frame.left
                                    ),
                                    CMTaggedBuffer(
                                        tags: [.stereoView(.rightEye), .videoLayerID(1)],
                                        pixelBuffer: frame.right
                                    )
                                ], withPresentationTime: time)
                            }
                        )
                    })
                } else {
                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                        assetWriterInput: assetWriterInput,
                        sourcePixelBufferAttributes: sourcePixelBufferAttributes
                    )
                    mediaTracks.append(MediaTrackTask(pendingUnitCount: 10) { progress in
                        try await Self.processVideoSamples(
                            from: assetReaderOutput,
                            to: assetWriterInput,
                            inputSize: inputSize,
                            outputSize: outputSize,
                            pixelFormat: pixelFormat,
                            progress: progress,
                            label: "\(String(describing: Self.self)).video",
                            decode: { sampleBuffer -> CVPixelBuffer in
                                guard let imageBuffer = sampleBuffer.imageBuffer else {
                                    throw Error.missingImageBuffer
                                }
                                return imageBuffer
                            },
                            submitUpscale: { upscaler, frame, completion in
                                upscaler.upscale(
                                    frame,
                                    pixelBufferPool: adaptor.pixelBufferPool,
                                    completionHandler: completion
                                )
                            },
                            append: { frame, time in
                                adaptor.append(frame, withPresentationTime: time)
                            }
                        )
                    })
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
                        let progress = Progress(totalUnitCount: Int64(duration.seconds))
                        self.progress.addChild(progress, withPendingUnitCount: mediaTrack.pendingUnitCount)
                        try await mediaTrack.process(progress)
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

    /// A single track's export work, ready to run against a child `Progress`.
    /// Storing a prebuilt closure (rather than the reader/writer/adaptor) keeps
    /// availability-gated types (e.g. the spatial adaptor) out of this type and
    /// lets the task group treat every track uniformly.
    private struct MediaTrackTask {
        let pendingUnitCount: Int64
        let process: (_ progress: Progress) async throws -> Void
    }

    private static let maxFramesInFlight = 3

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
    @available(macOS 14.0, iOS 17.0, *) private static func shouldExportSpatialVideo(
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
                kCVPixelBufferPixelFormatTypeKey as String: Self.workingPixelFormat(for: formatDescription)
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

    private static func workingPixelFormat(for formatDescription: CMFormatDescription?) -> OSType {
        (formatDescription?.isHDR ?? false)
            ? kCVPixelFormatType_64RGBAHalf
            : kCVPixelFormatType_32BGRA
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
            if formatDescription?.isHDR ?? false {
                if codec == .hevc {
                    compressionProperties[kVTCompressionPropertyKey_ProfileLevel] =
                        kVTProfileLevel_HEVC_Main10_AutoLevel
                }
                for (key, value) in formatDescription?.hdrMetadata ?? [:] {
                    compressionProperties[key] = value
                }
            }
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

    private static func copyAudioSamples(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        progress: Progress
    ) async throws {
        try await input.appendSamples(label: "\(String(describing: Self.self)).audio") {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { return false }
            if sampleBuffer.presentationTimeStamp.isNumeric {
                let timestamp = Int64(sampleBuffer.presentationTimeStamp.seconds)
                DispatchQueue.main.async { progress.completedUnitCount = timestamp }
            }
            return input.append(sampleBuffer)
        }
    }

    /// Reads frames from `output`, upscales them off the reader thread with at
    /// most `maxFramesInFlight` outstanding, and appends the results to `input`
    /// in presentation order. The small differences between plain and spatial
    /// video live in the injected closures:
    ///
    /// - `decode` extracts the input pixel buffer(s) for one frame.
    /// - `submitUpscale` submits GPU work (synchronously, in order, on the
    ///   reader thread) and calls its completion with the upscaled frame.
    /// - `append` writes one upscaled frame, returning `false` if the writer
    ///   rejected it.
    private static func processVideoSamples<Frame>(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        inputSize: CGSize,
        outputSize: CGSize,
        pixelFormat: OSType,
        progress: Progress,
        label: String,
        decode: @escaping (CMSampleBuffer) throws -> Frame,
        submitUpscale: @escaping (Upscaler, Frame, @escaping (Frame) -> Void) -> Void,
        append: @escaping (Frame, CMTime) -> Bool
    ) async throws {
        guard let upscaler = Upscaler(
            inputSize: inputSize,
            outputSize: outputSize,
            pixelFormat: pixelFormat
        ) else {
            throw Error.failedToCreateUpscaler
        }

        let channel = FrameChannel<Frame>(capacity: maxFramesInFlight)

        // Decode and submit GPU work in presentation order on a dedicated thread.
        // `enqueue` blocks once `maxFramesInFlight` frames are outstanding, which
        // bounds memory and keeps decode, upscaling, and encoding overlapping.
        DispatchQueue(label: "\(label).read", qos: .userInitiated).async {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                do {
                    let inputFrame = try decode(sampleBuffer)
                    let frame = FrameChannel<Frame>.PendingFrame(time: sampleBuffer.presentationTimeStamp)
                    guard channel.enqueue(frame) else { return }
                    submitUpscale(upscaler, inputFrame) { frame.fulfill($0) }
                } catch {
                    channel.finish(throwing: error)
                    return
                }
            }
            channel.finish()
        }

        // Append upscaled frames in order, waiting on each frame's GPU completion.
        try await input.appendSamples(label: "\(label).write") {
            guard let frame = channel.dequeue() else {
                if let error = channel.terminationError {
                    throw error
                }
                return false
            }
            let upscaledFrame = frame.wait()
            if frame.time.isNumeric {
                let timestamp = Int64(frame.time.seconds)
                DispatchQueue.main.async { progress.completedUnitCount = timestamp }
            }
            guard append(upscaledFrame, frame.time) else {
                channel.abort()
                return false
            }
            return true
        }
    }

    /// Extracts the left- and right-eye pixel buffers from a stereoscopic
    /// (MV-HEVC) sample buffer.
    @available(macOS 14.0, iOS 17.0, *) private static func stereoscopicPixelBuffers(
        from sampleBuffer: CMSampleBuffer
    ) throws -> (left: CVPixelBuffer, right: CVPixelBuffer) {
        guard let taggedBuffers = sampleBuffer.taggedBuffers else {
            throw Error.missingTaggedBuffers
        }
        let leftBuffer = taggedBuffers.first {
            $0.tags.first(matchingCategory: .stereoView) == .stereoView(.leftEye)
        }?.buffer
        let rightBuffer = taggedBuffers.first {
            $0.tags.first(matchingCategory: .stereoView) == .stereoView(.rightEye)
        }?.buffer
        guard let leftBuffer, let rightBuffer,
              case let .pixelBuffer(leftPixelBuffer) = leftBuffer,
              case let .pixelBuffer(rightPixelBuffer) = rightBuffer else {
            throw Error.invalidTaggedBuffers
        }
        return (leftPixelBuffer, rightPixelBuffer)
    }
}

// MARK: - AVAssetWriterInput + async sample appending

private extension AVAssetWriterInput {
    /// Bridges the pull-based `requestMediaDataWhenReady(on:)` callback to
    /// async/await.
    ///
    /// `appendNextSample` is invoked repeatedly on a private serial queue while
    /// the input is ready for more data. It should append the next sample and
    /// return `true`, or return `false` once the source is exhausted or the
    /// writer stops accepting samples. Throwing propagates out of `await`. In
    /// every terminating case the input is marked as finished.
    func appendSamples(
        label: String,
        _ appendNextSample: @escaping () throws -> Bool
    ) async throws {
        let queue = DispatchQueue(label: label, qos: .userInitiated)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            requestMediaDataWhenReady(on: queue) {
                do {
                    while self.isReadyForMoreMediaData {
                        guard try appendNextSample() else {
                            self.markAsFinished()
                            continuation.resume()
                            return
                        }
                    }
                } catch {
                    self.markAsFinished()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - UpscalingExportSession.Error

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
