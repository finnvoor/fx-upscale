import AVFoundation
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - UpscalingCompositor

public final class UpscalingCompositor: NSObject, AVVideoCompositing {
    // MARK: Public

    public let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [CFString: Any]()
    ]

    public var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [CFString: Any]()
    ]

    public var inputSize = CGSize.zero
    public var outputSize = CGSize.zero

    public func renderContextChanged(_: AVVideoCompositionRenderContext) {}

    public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = asyncVideoCompositionRequest.sourceTrackIDs.first else {
            asyncVideoCompositionRequest.finishCancelledRequest()
            return
        }
        guard let sourceFrame = asyncVideoCompositionRequest.sourceFrame(
            byTrackID: CMPersistentTrackID(truncating: trackID)
        ) else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotGetSourceFrame)
            return
        }
        #if canImport(MetalFX)
        guard let destinationFrame = asyncVideoCompositionRequest.renderContext.newPixelBuffer() else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotCreateDestinationPixelBuffer)
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotMakeCommandBuffer)
            return
        }

        var colorTexture: CVMetalTexture!
        var status = CVMetalTextureCacheCreateTextureFromImage(
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
        guard status == kCVReturnSuccess else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotCreateMetalTextureFromSourceFrame(status))
            return
        }

        var outputTexture: CVMetalTexture!
        status = CVMetalTextureCacheCreateTextureFromImage(
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
        guard status == kCVReturnSuccess else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotCreateMetalTextureFromDestinationFrame(status))
            return
        }

        guard let intermediateOutputTexture = device.makeTexture(descriptor: intermediateOutputTextureDescriptor) else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotMakeIntermediateOutputTexture)
            return
        }
        spatialScaler.colorTexture = CVMetalTextureGetTexture(colorTexture)
        spatialScaler.outputTexture = intermediateOutputTexture

        spatialScaler.encode(commandBuffer: commandBuffer)
        guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else {
            asyncVideoCompositionRequest.finish(with: Error.couldNotMakeBlitCommandEncoder)
            return
        }
        blitCommandEncoder.copy(from: intermediateOutputTexture, to: CVMetalTextureGetTexture(outputTexture)!)
        blitCommandEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            asyncVideoCompositionRequest.finish(with: error)
            return
        }

        asyncVideoCompositionRequest.finish(withComposedVideoFrame: destinationFrame)
        #else
        asyncVideoCompositionRequest.finish(withComposedVideoFrame: sourceFrame)
        #endif
    }

    // MARK: Private

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commandQueue = device.makeCommandQueue()!
    private lazy var cvTextureCache: CVMetalTextureCache! = {
        var cvTextureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cvTextureCache)
        return cvTextureCache
    }()

    #if canImport(MetalFX)
    private lazy var spatialScaler: MTLFXSpatialScaler = {
        let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor()
        spatialScalerDescriptor.inputWidth = Int(inputSize.width)
        spatialScalerDescriptor.inputHeight = Int(inputSize.height)
        spatialScalerDescriptor.outputWidth = Int(outputSize.width)
        spatialScalerDescriptor.outputHeight = Int(outputSize.height)
        spatialScalerDescriptor.colorTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.outputTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.colorProcessingMode = .perceptual
        return spatialScalerDescriptor.makeSpatialScaler(device: device)!
    }()
    #endif

    private lazy var intermediateOutputTextureDescriptor: MTLTextureDescriptor = {
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.width = Int(outputSize.width)
        textureDescriptor.height = Int(outputSize.height)
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        return textureDescriptor
    }()
}

// MARK: UpscalingCompositor.Error

extension UpscalingCompositor {
    enum Error: Swift.Error {
        case couldNotGetSourceTrackID
        case couldNotGetSourceFrame
        case couldNotCreateDestinationPixelBuffer
        case couldNotMakeCommandBuffer
        case couldNotCreateMetalTextureFromSourceFrame(CVReturn)
        case couldNotCreateMetalTextureFromDestinationFrame(CVReturn)
        case couldNotMakeIntermediateOutputTexture
        case couldNotMakeBlitCommandEncoder
    }
}
