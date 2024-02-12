import ArgumentParser
import AVFoundation
import Foundation
import SwiftTUI
import Upscaling

// MARK: - MetalFXUpscale

@main struct FXUpscale: AsyncParsableCommand {
    @Argument(help: "The video file to upscale", transform: URL.init(fileURLWithPath:)) var url: URL

    @Option(name: .shortAndLong, help: "The output file width") var width: Int?
    @Option(name: .shortAndLong, help: "The output file height") var height: Int?

    mutating func run() async throws {
        guard ["mov", "m4v", "mp4"].contains(url.pathExtension.lowercased()) else {
            throw ValidationError("Unsupported file type. Supported types: mov, m4v, mp4")
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File does not exist at \(url.path(percentEncoded: false))")
        }

        let asset = AVAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ValidationError("Failed to get video track from input file")
        }

        let formatDescription = try await videoTrack.load(.formatDescriptions).first
        let dimensions = formatDescription.map {
            CMVideoFormatDescriptionGetDimensions($0)
        }.map {
            CGSize(width: Int($0.width), height: Int($0.height))
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let inputSize = dimensions ?? naturalSize

        // 1. Use passed in width/height
        // 2. Use proportional width/height if only one is specified
        // 3. Default to 2x upscale

        let width = width ??
            height.map { Int(inputSize.width * (CGFloat($0) / inputSize.height)) } ??
            Int(inputSize.width) * 2
        let height = height ??
            Int(inputSize.height * (CGFloat(width) / inputSize.width))

        guard width <= UpscalingExportSession.maxOutputSize,
              height <= UpscalingExportSession.maxOutputSize else {
            throw ValidationError("Maximum supported width/height: 16384")
        }

        let outputSize = CGSize(width: width, height: height)

        let convertToProRes = (outputSize.width * outputSize.height) > (3840 * 2160) &&
            !(formatDescription?.videoCodecType?.isProRes ?? false)

        let exportSession = UpscalingExportSession(
            asset: asset,
            outputCodec: convertToProRes ? .proRes422 : nil,
            preferredOutputURL: url.renamed { "\($0) Upscaled" },
            outputSize: outputSize,
            creator: ProcessInfo.processInfo.processName
        )

        CommandLine.info([
            "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) ",
            "to \(Int(outputSize.width))x\(Int(outputSize.height)) "
        ].joined())
        ActivityIndicator.start()
        try await exportSession.export()
        ActivityIndicator.stop()
        CommandLine.success("Video successfully upscaled!")
    }
}
