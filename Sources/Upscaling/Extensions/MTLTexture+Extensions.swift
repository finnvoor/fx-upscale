import Metal

extension MTLTexture {
    var size: CGSize { .init(width: width, height: height) }
}
