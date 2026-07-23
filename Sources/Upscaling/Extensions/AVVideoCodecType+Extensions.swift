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

    var cmVideoCodecType: CMVideoCodecType? {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(CMVideoCodecType(0)) { ($0 << 8) | CMVideoCodecType($1) }
    }

    /// Whether this codec supports MV-HEVC (spatial video) encoding.
    var supportsMultiviewHEVC: Bool {
        self == .hevc
    }
}
