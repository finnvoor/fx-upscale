import ArgumentParser
import AVFoundation
import Foundation
import MetalFX

// MARK: - MetalFXUpscale

@main struct MetalFXUpscale: AsyncParsableCommand {
    @Argument(help: "The video file to upscale", transform: URL.init(fileURLWithPath:)) var file: URL

    @Option(help: "The output file width") var width: Int
    @Option(help: "The output file height") var height: Int

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ValidationError("File does not exist at \(file.path)")
        }
        print("Upscaling...")
        let asset = AVAsset(url: file)
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]

        let composition = AVMutableComposition()
        for sourceTrack in try await asset.load(.tracks) {
            let destinationTrack = composition.addMutableTrack(
                withMediaType: sourceTrack.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!
            let sourceTimeRange = try await sourceTrack.load(.timeRange)
            try destinationTrack.insertTimeRange(sourceTimeRange, of: sourceTrack, at: sourceTimeRange.start)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = Compositor.self
        videoComposition.renderSize = CGSize(width: width, height: height)
        videoComposition.frameDuration = try await videoTrack.load(.minFrameDuration)
        let instruction = try await Compositor.Instruction(timeRange: videoTrack.load(.timeRange))
        videoComposition.instructions = [instruction]

        let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQualityWithAlpha)!
        exportSession.videoComposition = videoComposition
        let naturalSize = try await videoTrack.load(.naturalSize)
        (exportSession.customVideoCompositor as! Compositor).inputWidth = Int(naturalSize.width)
        (exportSession.customVideoCompositor as! Compositor).inputHeight = Int(naturalSize.height)
        (exportSession.customVideoCompositor as! Compositor).outputWidth = width
        (exportSession.customVideoCompositor as! Compositor).outputHeight = height
        let pathExtension = file.pathExtension
        exportSession.outputURL = URL(fileURLWithPath: file.deletingPathExtension().path.appending("_upscaled"))
            .appendingPathExtension(pathExtension)
        switch file.pathExtension.lowercased() {
        case "mov": exportSession.outputFileType = .mov
        case "m4v": exportSession.outputFileType = .m4v
        default: exportSession.outputFileType = .mp4
        }
        await exportSession.export()
        if let error = exportSession.error { throw error }
        print("Done!")
    }
}

// MARK: - Compositor

class Compositor: NSObject, AVVideoCompositing {
    // MARK: Internal

    final class Instruction: NSObject, AVVideoCompositionInstructionProtocol {
        // MARK: Lifecycle

        init(timeRange: CMTimeRange) {
            self.timeRange = timeRange
        }

        // MARK: Internal

        var timeRange: CMTimeRange
        let enablePostProcessing = true
        let containsTweening = true
        var requiredSourceTrackIDs: [NSValue]? = nil
        let passthroughTrackID = kCMPersistentTrackID_Invalid
    }

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [CFString: Any]()
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [CFString: Any]()
    ]

    var inputWidth: Int = 0
    var inputHeight: Int = 0

    var outputWidth: Int = 0
    var outputHeight: Int = 0

    func renderContextChanged(_: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let sourceFrame = asyncVideoCompositionRequest.sourceFrame(
            byTrackID: CMPersistentTrackID(truncating: asyncVideoCompositionRequest.sourceTrackIDs[0])
        )!
        let destinationFrame = asyncVideoCompositionRequest.renderContext.newPixelBuffer()!

        let commandBuffer = commandQueue.makeCommandBuffer()!

        var colorTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cvTextureCache,
            sourceFrame,
            [:] as CFDictionary,
            .bgra8Unorm,
            CVPixelBufferGetWidth(sourceFrame),
            CVPixelBufferGetHeight(sourceFrame),
            0,
            &colorTexture
        )

        var outputTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cvTextureCache,
            destinationFrame,
            [:] as CFDictionary,
            .bgra8Unorm,
            CVPixelBufferGetWidth(destinationFrame),
            CVPixelBufferGetHeight(destinationFrame),
            0,
            &outputTexture
        )

        let intermediateOutputTexture = device.makeTexture(descriptor: intermediateOutputTextureDescriptor)!
        spatialScaler.colorTexture = CVMetalTextureGetTexture(colorTexture!)
        spatialScaler.outputTexture = intermediateOutputTexture

        spatialScaler.encode(commandBuffer: commandBuffer)
        let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitCommandEncoder.copy(from: intermediateOutputTexture, to: CVMetalTextureGetTexture(outputTexture!)!)
        blitCommandEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        asyncVideoCompositionRequest.finish(withComposedVideoFrame: destinationFrame)
    }

    // MARK: Private

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commandQueue = device.makeCommandQueue()!
    private lazy var cvTextureCache: CVMetalTextureCache! = {
        var cvTextureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cvTextureCache)
        return cvTextureCache
    }()

    private lazy var spatialScaler: MTLFXSpatialScaler = {
        let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor()
        spatialScalerDescriptor.inputWidth = inputWidth
        spatialScalerDescriptor.inputHeight = inputHeight
        spatialScalerDescriptor.outputWidth = outputWidth
        spatialScalerDescriptor.outputHeight = outputHeight
        spatialScalerDescriptor.colorTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.outputTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.colorProcessingMode = .perceptual
        return spatialScalerDescriptor.makeSpatialScaler(device: device)!
    }()

    private lazy var intermediateOutputTextureDescriptor: MTLTextureDescriptor = {
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.width = outputWidth
        textureDescriptor.height = outputHeight
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        return textureDescriptor
    }()
}
