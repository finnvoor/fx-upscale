import AVFoundation

// MARK: - UpscalingExportSession

public class UpscalingExportSession {
    // MARK: Lifecycle

    public init(
        asset: AVAsset,
        outputURL: URL,
        outputSize: CGSize
    ) {
        self.asset = asset
        self.outputURL = outputURL
        self.outputSize = outputSize
    }

    // MARK: Public

    public static let maxSize = 16384

    public let asset: AVAsset
    public private(set) var outputURL: URL
    public let outputSize: CGSize

    public func export() async throws {
        if outputURL.pathExtension.lowercased() != "mov",
           (outputSize.width * outputSize.height) > Self.maxNonProResPixelCount {
            outputURL = outputURL
                .deletingPathExtension()
                .appendingPathExtension("mov")
        }

        guard !FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw Error.outputURLAlreadyExists
        }

        let outputFileType: AVFileType = {
            switch outputURL.pathExtension.lowercased() {
            case "mov": return .mov
            case "m4v": return .m4v
            default: return .mp4
            }
        }()

        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
        assetWriter.metadata = try await asset.load(.metadata)

        let assetReader = try AVAssetReader(asset: asset)

        let assetDuration = try await asset.load(.duration)

        for track in try await asset.load(.tracks) {
            let formatDescription = try await track.load(.formatDescriptions).first
            switch track.mediaType {
            case .video:
                let dimensions = formatDescription.map {
                    CMVideoFormatDescriptionGetDimensions($0)
                }.map {
                    CGSize(width: Int($0.width), height: Int($0.height))
                }
                let naturalSize = try await track.load(.naturalSize)
                let inputSize = dimensions ?? naturalSize
                let nominalFrameRate = try await track.load(.nominalFrameRate)

                let videoOutput = AVAssetReaderVideoCompositionOutput(
                    videoTracks: [track],
                    videoSettings: nil
                )

                videoOutput.alwaysCopiesSampleData = false
                videoOutput.videoComposition = {
                    let videoComposition = AVMutableVideoComposition()
                    videoComposition.customVideoCompositorClass = UpscalingCompositor.self
                    videoComposition.colorPrimaries = formatDescription?.colorPrimaries
                    videoComposition.colorTransferFunction = formatDescription?.colorTransferFunction
                    videoComposition.colorYCbCrMatrix = formatDescription?.colorYCbCrMatrix
                    videoComposition.frameDuration = CMTime(
                        value: 1,
                        timescale: nominalFrameRate > 0 ? CMTimeScale(nominalFrameRate) : 30
                    )
                    videoComposition.renderSize = outputSize
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
                    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    instruction.layerInstructions = [layerInstruction]
                    videoComposition.instructions = [instruction]
                    return videoComposition
                }()
                (videoOutput.customVideoCompositor as! UpscalingCompositor).inputSize = inputSize
                (videoOutput.customVideoCompositor as! UpscalingCompositor).outputSize = outputSize

                if assetReader.canAdd(videoOutput) {
                    assetReader.add(videoOutput)
                } else {
                    throw Error.couldNotAddAssetReaderVideoOutput
                }

                var videoCodec = formatDescription?.videoCodecType ?? .hevc
                if !videoCodec.isProRes,
                   (outputSize.width * outputSize.height) > Self.maxNonProResPixelCount {
                    videoCodec = .proRes422
                }

                var colorProperties: [String: Any] = [:]
                if let colorPrimaries = formatDescription?.colorPrimaries {
                    colorProperties[AVVideoColorPrimariesKey] = colorPrimaries
                }
                if let colorTransferFunction = formatDescription?.colorTransferFunction {
                    colorProperties[AVVideoTransferFunctionKey] = colorTransferFunction
                }
                if let colorYCbCrMatrix = formatDescription?.colorYCbCrMatrix {
                    colorProperties[AVVideoYCbCrMatrixKey] = colorYCbCrMatrix
                }

                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoWidthKey: outputSize.width,
                    AVVideoHeightKey: outputSize.height,
                    AVVideoCodecKey: videoCodec,
                    AVVideoColorPropertiesKey: colorProperties
                ])
                videoInput.expectsMediaDataInRealTime = false
                if assetWriter.canAdd(videoInput) {
                    assetWriter.add(videoInput)
                } else {
                    throw Error.couldNotAddAssetWriterVideoInput
                }
            case .audio:
                let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: nil)
                audioOutput.alwaysCopiesSampleData = false
                if assetReader.canAdd(audioOutput) {
                    assetReader.add(audioOutput)
                } else {
                    throw Error.couldNotAddAssetReaderAudioOutput
                }

                let audioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: formatDescription
                )
                audioInput.expectsMediaDataInRealTime = false
                if assetWriter.canAdd(audioInput) {
                    assetWriter.add(audioInput)
                } else {
                    throw Error.couldNotAddAssetWriterAudioInput
                }
            default: continue
            }
        }

        assert(assetWriter.inputs.count == assetReader.outputs.count)

        assetWriter.startWriting()
        assetReader.startReading()
        assetWriter.startSession(atSourceTime: .zero)

        await withCheckedContinuation { continuation in
            // - Returns: Whether or not the input has read all available media data
            @Sendable func copyReadySamples(from output: AVAssetReaderOutput, to input: AVAssetWriterInput) -> Bool {
                while input.isReadyForMoreMediaData {
                    if let sampleBuffer = output.copyNextSampleBuffer() {
                        if !input.append(sampleBuffer) {
                            return true
                        }
                    } else {
                        input.markAsFinished()
                        return true
                    }
                }
                return false
            }

            @Sendable func finish() {
                if assetWriter.status == .failed {
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume()
                } else if assetReader.status == .failed {
                    assetWriter.cancelWriting()
                    if [.cancelled, .failed].contains(assetWriter.status) {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                    continuation.resume()
                } else {
                    assetWriter.finishWriting {
                        if [.cancelled, .failed].contains(assetWriter.status) {
                            try? FileManager.default.removeItem(at: self.outputURL)
                        }
                        continuation.resume()
                    }
                }
            }

            actor FinishCount {
                var isFinished: Bool { count >= finishCount }
                private var count = 0
                private let finishCount: Int
                func increment() { count += 1 }
                init(finishCount: Int) { self.finishCount = finishCount }
            }
            let finishCount = FinishCount(finishCount: assetWriter.inputs.count)

            let queue = DispatchQueue(label: String(describing: Self.self))
            for (input, output) in zip(assetWriter.inputs, assetReader.outputs) {
                input.requestMediaDataWhenReady(on: queue) {
                    let finishedReading = copyReadySamples(from: output, to: input)
                    if finishedReading {
                        Task {
                            await finishCount.increment()
                            if await finishCount.isFinished { finish() }
                        }
                    }
                }
            }
        } as Void
    }

    // MARK: Private

    private static let maxNonProResPixelCount: CGFloat = 3840 * 2160
}

// MARK: UpscalingExportSession.Error

extension UpscalingExportSession {
    enum Error: Swift.Error {
        case outputURLAlreadyExists
        case couldNotAddAssetReaderVideoOutput
        case couldNotAddAssetWriterVideoInput
        case couldNotAddAssetReaderAudioOutput
        case couldNotAddAssetWriterAudioInput
    }
}
