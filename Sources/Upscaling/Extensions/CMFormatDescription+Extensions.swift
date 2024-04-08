import AVFoundation

extension CMFormatDescription {
    public var videoCodecType: AVVideoCodecType? {
        switch mediaSubType {
        case .hevc: return .hevc
        case .h264: return .h264
        case .jpeg: return .jpeg
        #if !os(visionOS)
        case .proRes4444: return .proRes4444
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes4444XQ: return AVVideoCodecType(rawValue: "ap4x")
        #endif
        case .hevcWithAlpha: return .hevcWithAlpha
        default: return nil
        }
    }

    var colorPrimaries: String? {
        switch extensions[
            kCMFormatDescriptionExtension_ColorPrimaries
        ].map({ $0 as! CFString }) {
        case kCMFormatDescriptionColorPrimaries_ITU_R_709_2: AVVideoColorPrimaries_ITU_R_709_2
        #if os(macOS)
        case kCMFormatDescriptionColorPrimaries_EBU_3213: AVVideoColorPrimaries_EBU_3213
        #endif
        case kCMFormatDescriptionColorPrimaries_SMPTE_C: AVVideoColorPrimaries_SMPTE_C
        case kCMFormatDescriptionColorPrimaries_P3_D65: AVVideoColorPrimaries_P3_D65
        case kCMFormatDescriptionColorPrimaries_ITU_R_2020: AVVideoColorPrimaries_ITU_R_2020
        default: nil
        }
    }

    var colorTransferFunction: String? {
        switch extensions[
            kCMFormatDescriptionExtension_TransferFunction
        ].map({ $0 as! CFString }) {
        case kCMFormatDescriptionTransferFunction_ITU_R_709_2: AVVideoTransferFunction_ITU_R_709_2
        #if os(macOS)
        case kCMFormatDescriptionTransferFunction_SMPTE_240M_1995: AVVideoTransferFunction_SMPTE_240M_1995
        #endif
        case kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ: AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG: AVVideoTransferFunction_ITU_R_2100_HLG
        case kCMFormatDescriptionTransferFunction_Linear: AVVideoTransferFunction_Linear
        default: nil
        }
    }

    var colorYCbCrMatrix: String? {
        switch extensions[
            kCMFormatDescriptionExtension_YCbCrMatrix
        ].map({ $0 as! CFString }) {
        case kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2: AVVideoYCbCrMatrix_ITU_R_709_2
        case kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4: AVVideoYCbCrMatrix_ITU_R_601_4
        #if os(macOS)
        case kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995: AVVideoYCbCrMatrix_SMPTE_240M_1995
        #endif
        case kCMFormatDescriptionYCbCrMatrix_ITU_R_2020: AVVideoYCbCrMatrix_ITU_R_2020
        default: nil
        }
    }

    @available(macOS 14.0, iOS 17.0, *) var hasLeftAndRightEye: Bool {
        let hasLeftEye = (tagCollections ?? []).contains {
            $0.contains { $0 == .stereoView(.leftEye) }
        }
        let hasRightEye = (tagCollections ?? []).contains {
            $0.contains { $0 == .stereoView(.rightEye) }
        }
        return hasLeftEye && hasRightEye
    }
}
