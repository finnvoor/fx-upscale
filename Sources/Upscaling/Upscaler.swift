import AVFoundation
import CoreImage
import CoreVideo
import Foundation
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - Upscaler

public final class Upscaler {
    // MARK: Lifecycle

    public init?(inputSize: CGSize, outputSize: CGSize) {
        #if canImport(MetalFX)
        let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor()
        spatialScalerDescriptor.inputSize = inputSize
        spatialScalerDescriptor.outputSize = outputSize
        spatialScalerDescriptor.colorTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.outputTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.colorProcessingMode = .perceptual
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.width = Int(outputSize.width)
        textureDescriptor.height = Int(outputSize.height)
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device),
              let intermediateOutputTexture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        self.commandQueue = commandQueue
        self.spatialScaler = spatialScaler
        self.intermediateOutputTexture = intermediateOutputTexture
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let textureCache else { return nil }
        self.textureCache = textureCache
        var pixelBufferPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey: outputSize.width,
            kCVPixelBufferHeightKey: outputSize.height
        ] as CFDictionary, &pixelBufferPool)
        guard let pixelBufferPool else { return nil }
        self.pixelBufferPool = pixelBufferPool
        #endif
    }

    // MARK: Public

    @discardableResult public func upscale(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) async -> CVPixelBuffer {
        #if canImport(MetalFX)
        do {
            let (commandBuffer, outputPixelBuffer) = try upscaleCommandBuffer(
                pixelBuffer,
                pixelBufferPool: pixelBufferPool,
                outputPixelBuffer: outputPixelBuffer
            )
            try await withCheckedThrowingContinuation { continuation in
                commandBuffer.addCompletedHandler { commandBuffer in
                    if let error = commandBuffer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                commandBuffer.commit()
            } as Void
            return outputPixelBuffer
        } catch {
            return pixelBuffer
        }
        #else
        return pixelBuffer
        #endif
    }

    @discardableResult public func upscale(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) -> CVPixelBuffer {
        #if canImport(MetalFX)
        do {
            let (commandBuffer, outputPixelBuffer) = try upscaleCommandBuffer(
                pixelBuffer,
                pixelBufferPool: pixelBufferPool,
                outputPixelBuffer: outputPixelBuffer
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.error != nil { return pixelBuffer }
            return outputPixelBuffer
        } catch {
            return pixelBuffer
        }
        #else
        return pixelBuffer
        #endif
    }

    public func upscale(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil,
        completionHandler: @escaping (CVPixelBuffer) -> Void
    ) {
        #if canImport(MetalFX)
        do {
            let (commandBuffer, outputPixelBuffer) = try upscaleCommandBuffer(
                pixelBuffer,
                pixelBufferPool: pixelBufferPool,
                outputPixelBuffer: outputPixelBuffer
            )
            commandBuffer.addCompletedHandler { commandBuffer in
                if commandBuffer.error != nil {
                    completionHandler(pixelBuffer)
                } else {
                    completionHandler(outputPixelBuffer)
                }
            }
            commandBuffer.commit()
        } catch {
            completionHandler(pixelBuffer)
        }
        #else
        completionHandler(pixelBuffer)
        #endif
    }

    // MARK: Private

    #if canImport(MetalFX)
    private let commandQueue: MTLCommandQueue
    private let spatialScaler: MTLFXSpatialScaler
    private let intermediateOutputTexture: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let pixelBufferPool: CVPixelBufferPool

    private func upscaleCommandBuffer(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) throws -> (MTLCommandBuffer, CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw Error.unsupportedPixelFormat
        }

        guard let outputPixelBuffer = outputPixelBuffer ?? {
            var outputPixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool ?? self.pixelBufferPool, &outputPixelBuffer)
            return outputPixelBuffer
        }() else { throw Error.couldNotCreatePixelBuffer }

        var colorTexture: CVMetalTexture!
        var status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            [:] as CFDictionary,
            .bgra8Unorm,
            pixelBuffer.width,
            pixelBuffer.height,
            0,
            &colorTexture
        )
        guard status == kCVReturnSuccess,
              let colorTexture = CVMetalTextureGetTexture(colorTexture) else {
            throw Error.couldNotCreateMetalTexture
        }

        var upscaledTexture: CVMetalTexture!
        status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            outputPixelBuffer,
            [:] as CFDictionary,
            .bgra8Unorm,
            outputPixelBuffer.width,
            outputPixelBuffer.height,
            0,
            &upscaledTexture
        )
        guard status == kCVReturnSuccess,
              let upscaledTexture = CVMetalTextureGetTexture(upscaledTexture) else {
            throw Error.couldNotCreateMetalTexture
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw Error.couldNotMakeCommandBuffer }

        spatialScaler.colorTexture = colorTexture
        spatialScaler.outputTexture = intermediateOutputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)

        let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()
        blitCommandEncoder?.copy(from: intermediateOutputTexture, to: upscaledTexture)
        blitCommandEncoder?.endEncoding()

        return (commandBuffer, outputPixelBuffer)
    }
    #endif
}

// MARK: Upscaler.Error

extension Upscaler {
    enum Error: Swift.Error {
        case unsupportedPixelFormat
        case couldNotCreatePixelBuffer
        case couldNotCreateMetalTexture
        case couldNotMakeCommandBuffer
    }
}
