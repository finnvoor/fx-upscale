import CoreImage
import Foundation
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - UpscalingFilter

public class UpscalingFilter: CIFilter {
    // MARK: Public

    public var inputImage: CIImage?
    public var outputSize: CGSize?

    override public var outputImage: CIImage? {
        #if canImport(MetalFX)
        guard let device, let inputImage, let outputSize else { return nil }

        if spatialScaler?.inputSize != inputImage.extent.size || spatialScaler?.outputSize != outputSize {
            let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor()
            spatialScalerDescriptor.inputSize = inputImage.extent.size
            spatialScalerDescriptor.outputSize = outputSize
            spatialScalerDescriptor.colorTextureFormat = .bgra8Unorm
            spatialScalerDescriptor.outputTextureFormat = .bgra8Unorm
            spatialScalerDescriptor.colorProcessingMode = .perceptual
            spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device)
        }

        guard let spatialScaler else { return nil }

        return try? UpscalingImageProcessorKernel.apply(
            withExtent: CGRect(origin: .zero, size: spatialScaler.outputSize),
            inputs: [inputImage],
            arguments: ["spatialScaler": spatialScaler]
        )
        #else
        return inputImage
        #endif
    }

    // MARK: Private

    private let device = MTLCreateSystemDefaultDevice()

    #if canImport(MetalFX)
    private var spatialScaler: MTLFXSpatialScaler?
    #endif
}
