#if canImport(MetalFX)
import MetalFX

extension MTLFXSpatialScalerDescriptor {
    var inputSize: CGSize {
        get {
            CGSize(width: inputWidth, height: inputHeight)
        } set {
            inputWidth = Int(newValue.width)
            inputHeight = Int(newValue.height)
        }
    }

    var outputSize: CGSize {
        get {
            CGSize(width: outputWidth, height: outputHeight)
        } set {
            outputWidth = Int(newValue.width)
            outputHeight = Int(newValue.height)
        }
    }
}
#endif
