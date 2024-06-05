import CoreImage
import Foundation
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - UpscalingImageProcessorKernel

public class UpscalingImageProcessorKernel: CIImageProcessorKernel {
    override public class var synchronizeInputs: Bool { false }
    override public class var outputFormat: CIFormat { .BGRA8 }

    override public class func formatForInput(at _: Int32) -> CIFormat { .BGRA8 }

    override public class func process(
        with inputs: [any CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: any CIImageProcessorOutput
    ) throws {
        #if canImport(MetalFX)
        guard let spatialScaler = arguments?["spatialScaler"] as? MTLFXSpatialScaler,
              let inputTexture = inputs?.first?.metalTexture,
              let outputTexture = output.metalTexture,
              let commandBuffer = output.metalCommandBuffer else {
            return
        }
        spatialScaler.colorTexture = inputTexture
        if outputTexture.storageMode == .private {
            spatialScaler.outputTexture = outputTexture
            spatialScaler.encode(commandBuffer: commandBuffer)
        } else {
            guard let intermediateOutputTexture = arguments?["intermediateOutputTexture"] as? MTLTexture else {
                return
            }
            spatialScaler.outputTexture = intermediateOutputTexture
            spatialScaler.encode(commandBuffer: commandBuffer)
            let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()
            blitCommandEncoder?.copy(from: intermediateOutputTexture, to: outputTexture)
            blitCommandEncoder?.endEncoding()
        }
        #endif
    }

    override public class func roi(
        forInput _: Int32,
        arguments: [String: Any]?,
        outputRect: CGRect
    ) -> CGRect {
        #if canImport(MetalFX)
        guard let spatialScaler = arguments?["spatialScaler"] as? MTLFXSpatialScaler else {
            return .null
        }
        return CGRect(origin: .zero, size: spatialScaler.inputSize)
        #else
        return outputRect
        #endif
    }
}
