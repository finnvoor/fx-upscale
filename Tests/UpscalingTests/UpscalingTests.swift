import AVFoundation
import CoreImage
import CoreMedia
import MetalFX
import Testing
@testable import Upscaling

/// Each test runs a full export, whose reader/writer block real dispatch threads;
/// run serially so concurrent exports can't exhaust the thread pool.
@Suite(.serialized) struct UpscalingTests {
    // MARK: Pipeline

    @Test func basicUpscale() async throws {
        let source = try TestMedia.makeVideo(.init(frameCount: 24))
        defer { try? FileManager.default.removeItem(at: source) }

        let outputSize = CGSize(width: 320, height: 240)
        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: outputSize
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }

        try await session.export()

        #expect(FileManager.default.fileExists(atPath: session.outputURL.path))
        let output = AVAsset(url: session.outputURL)
        let dimensions = try await output.videoDimensions()
        #expect(dimensions == outputSize)
        // Every input frame must be preserved, exactly once.
        let sourceFrames = try await AVAsset(url: source).videoFrameCount()
        let outputFrames = try await output.videoFrameCount()
        #expect(sourceFrames == 24, "generator sanity")
        #expect(outputFrames == sourceFrames)
    }

    @Test func defaultCodecMatchesSource() async throws {
        let source = try TestMedia.makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Out" },
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }
        try await session.export()

        let track = try await AVAsset(url: session.outputURL).loadTracks(withMediaType: .video).first
        let format = try await track?.load(.formatDescriptions).first
        #expect(format?.mediaSubType == .h264)
    }

    /// https://github.com/finnvoor/fx-upscale/issues/8
    @Test func upscaleTransformedVideo() async throws {
        let transform = CGAffineTransform(rotationAngle: .pi / 2)
        let source = try TestMedia.makeVideo(.init(transform: transform))
        defer { try? FileManager.default.removeItem(at: source) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }
        try await session.export()

        let track = try await AVAsset(url: session.outputURL).loadTracks(withMediaType: .video).first
        let outputTransform = try #require(try await track?.load(.preferredTransform))
        #expect(abs(outputTransform.a - transform.a) < 0.0001)
        #expect(abs(outputTransform.b - transform.b) < 0.0001)
        #expect(abs(outputTransform.c - transform.c) < 0.0001)
        #expect(abs(outputTransform.d - transform.d) < 0.0001)
    }

    /// https://github.com/finnvoor/fx-upscale/commit/e6666afdb9a5ce1eda38437bec25b0743b740360
    @Test func upscaleMissingColorInfo() async throws {
        // The generated source carries no color primaries/transfer/matrix tags.
        let source = try TestMedia.makeVideo(.init(frameCount: 8))
        defer { try? FileManager.default.removeItem(at: source) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }
        try await session.export() // must not crash or throw
        #expect(FileManager.default.fileExists(atPath: session.outputURL.path))
    }

    /// https://github.com/finnvoor/fx-upscale/commit/44463975e46ee7d418ad41017782c1e267205c82
    @Test func transcodeToProRes() async throws {
        let source = try TestMedia.makeVideo(.init(frameCount: 8))
        defer { try? FileManager.default.removeItem(at: source) }

        // Prefer an .mp4 URL to prove ProRes forces a .mov container.
        let preferred = source.renamed { "\($0) Upscaled" }
            .deletingPathExtension()
            .appendingPathExtension("mp4")
        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            outputCodec: .proRes422,
            preferredOutputURL: preferred,
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }

        #expect(session.outputURL.pathExtension == "mov")
        try await session.export()

        let track = try await AVAsset(url: session.outputURL).loadTracks(withMediaType: .video).first
        let format = try await track?.load(.formatDescriptions).first
        #expect(format?.mediaSubType == .proRes422)
    }

    /// https://github.com/finnvoor/fx-upscale/issues/7
    @Test func audioFormatMaintained() async throws {
        let source = try TestMedia.makeVideo(.init(frameCount: 12, includeAudio: true))
        defer { try? FileManager.default.removeItem(at: source) }

        let sourceAudio = try await AVAsset(url: source).loadTracks(withMediaType: .audio).first
        let sourceFormat = try await sourceAudio?.load(.formatDescriptions).first
        #expect(sourceFormat?.mediaSubType == .linearPCM)

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }
        try await session.export()

        let output = AVAsset(url: session.outputURL)
        let outputAudio = try await output.loadTracks(withMediaType: .audio).first
        let outputFormat = try await outputAudio?.load(.formatDescriptions).first
        #expect(outputAudio != nil, "audio track should be preserved")
        #expect(outputFormat?.mediaSubType == .linearPCM, "audio should be passed through unchanged")
        // Video frames still all present alongside audio.
        let sourceFrames = try await AVAsset(url: source).videoFrameCount()
        let outputFrames = try await output.videoFrameCount()
        #expect(outputFrames == sourceFrames)
    }

    /// https://github.com/finnvoor/fx-upscale/issues/6
    @Test func maintainMetadata() async throws {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = "fx-upscale-title" as NSString
        item.extendedLanguageTag = "und"

        let source = try TestMedia.makeVideo(.init(frameCount: 6, metadata: [item]))
        defer { try? FileManager.default.removeItem(at: source) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }
        try await session.export()

        let metadata = try await AVAsset(url: session.outputURL).load(.metadata)
        let titles = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierTitle
        )
        #expect(titles.first?.stringValue == "fx-upscale-title")
    }

    /// https://github.com/finnvoor/fx-upscale/issues/4
    @Test func exportProgress() async throws {
        let source = try TestMedia.makeVideo(.init(frameCount: 60, fps: 30))
        defer { try? FileManager.default.removeItem(at: source) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: CGSize(width: 320, height: 240)
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }

        #expect(session.progress.fractionCompleted == 0)
        try await session.export()
        #expect(session.progress.fractionCompleted > 0, "progress should advance during export")
    }

    @Test func writesCreatorMetadata() async throws {
        let source = try TestMedia.makeVideo(.init(frameCount: 4))
        defer { try? FileManager.default.removeItem(at: source) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: source.renamed { "\($0) Upscaled" },
            outputSize: CGSize(width: 320, height: 240),
            creator: "UnitTest"
        )
        defer { try? FileManager.default.removeItem(at: session.outputURL) }
        try await session.export()

        let values = try session.outputURL.resourceValues(forKeys: [.nameKey])
        #expect(values.name != nil)
        #expect(FileManager.default.fileExists(atPath: session.outputURL.path))
    }

    @Test func throwsWhenOutputExists() async throws {
        let source = try TestMedia.makeVideo(.init(frameCount: 4))
        defer { try? FileManager.default.removeItem(at: source) }

        let outputURL = source.renamed { "\($0) Upscaled" }
        try Data().write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let session = UpscalingExportSession(
            asset: AVAsset(url: source),
            preferredOutputURL: outputURL,
            outputSize: CGSize(width: 320, height: 240)
        )

        await #expect {
            try await session.export()
        } throws: { error in
            guard case UpscalingExportSession.Error.outputURLAlreadyExists = error else { return false }
            return true
        }
    }

    // MARK: Filter

    @Test func filter() throws {
        let url = try #require(Bundle.module.url(forResource: "ladybird", withExtension: "jpg"))
        let inputImage = try #require(CIImage(contentsOf: url))
        let outputSize = CGSize(
            width: inputImage.extent.width * 8,
            height: inputImage.extent.height * 8
        )

        let filter = UpscalingFilter()
        filter.inputImage = inputImage
        filter.outputSize = outputSize
        let outputImage = try #require(filter.outputImage)
        // TODO: - diff images
        #expect(outputImage.extent.size == outputSize)
    }
}
