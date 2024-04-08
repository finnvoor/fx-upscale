import AVFoundation

public extension AVVideoCodecType {
    var isProRes: Bool {
        switch self {
        #if !os(visionOS)
        case .proRes422, .proRes4444, .proRes422HQ, .proRes422LT, .proRes422Proxy, AVVideoCodecType(rawValue: "ap4x"): true
        #endif
        default: false
        }
    }
}
