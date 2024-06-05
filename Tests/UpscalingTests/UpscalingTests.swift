import CoreImage
import MetalFX
@testable import Upscaling
import XCTest

final class UpscalingTests: XCTestCase {
    func testBasicUpscale() async throws {
        // basic upscale
        throw XCTSkip("unimplemented")
    }

    /// https://github.com/finnvoor/fx-upscale/issues/8
    func testUpscaleTransformedVideo() async throws {
        // make sure transform is applied to upscaled video
        throw XCTSkip("unimplemented")
    }

    /// https://github.com/finnvoor/fx-upscale/commit/e6666afdb9a5ce1eda38437bec25b0743b740360
    func testUpscaleMissingColorInfo() async throws {
        // make sure it doesn't crash
        throw XCTSkip("unimplemented")
    }

    /// https://github.com/finnvoor/fx-upscale/commit/44463975e46ee7d418ad41017782c1e267205c82
    func testTranscodeToProRes() async throws {
        // >4k converted to pro res
        throw XCTSkip("unimplemented")
    }

    /// https://github.com/finnvoor/fx-upscale/issues/7
    func testAudioFormatMaintained() async throws {
        // keep audio format
        throw XCTSkip("unimplemented")
    }

    /// https://github.com/finnvoor/fx-upscale/issues/6
    func testMaintainMetadata() async throws {
        // maintain metadata/captions
        throw XCTSkip("unimplemented")
    }

    /// https://github.com/finnvoor/fx-upscale/issues/4
    func testExportProgress() async throws {
        // ensure progress works
        throw XCTSkip("unimplemented")
    }

    func testFilter() async throws {
        let inputImage = CIImage(
            contentsOf: Bundle.module.url(forResource: "ladybird", withExtension: "jpg")!
        )!
        let outputSize = CGSize(
            width: inputImage.extent.width * 8,
            height: inputImage.extent.height * 8
        )

        let filter = UpscalingFilter()
        filter.inputImage = inputImage
        filter.outputSize = outputSize
        let outputImage = filter.outputImage!
        // TODO: - diff images
        XCTAssertEqual(outputImage.extent.size, outputSize)
    }
}
