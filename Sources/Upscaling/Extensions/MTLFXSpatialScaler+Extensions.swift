#if canImport(MetalFX)
import MetalFX

extension MTLFXSpatialScaler {
    var inputSize: CGSize {
        CGSize(width: inputWidth, height: inputHeight)
    }

    var outputSize: CGSize {
        CGSize(width: outputWidth, height: outputHeight)
    }
}
#endif
