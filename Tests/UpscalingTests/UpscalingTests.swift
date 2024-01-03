@testable import Upscaling
import XCTest

final class UpscalingTests: XCTestCase {
    func testBasicUpscale() {
        // basic upscale
    }

    /// https://github.com/finnvoor/fx-upscale/issues/8
    func testUpscaleTransformedVideo() {
        // make sure transform is applied to upscaled video
    }

    /// https://github.com/finnvoor/fx-upscale/commit/e6666afdb9a5ce1eda38437bec25b0743b740360
    func testUpscaleMissingColorInfo() {
        // make sure it doesn't crash
    }

    /// https://github.com/finnvoor/fx-upscale/commit/44463975e46ee7d418ad41017782c1e267205c82
    func testTranscodeToProRes() {
        // >4k converted to pro res
    }

    /// https://github.com/finnvoor/fx-upscale/issues/7
    func testAudioFormatMaintained() {
        // keep audio format
    }

    /// https://github.com/finnvoor/fx-upscale/issues/6
    func testMaintainMetadata() {
        // maintain metadata/captions
    }

    /// https://github.com/finnvoor/fx-upscale/issues/4
    func testExportProgress() {
        // ensure progress works
    }
}
