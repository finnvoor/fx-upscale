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
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File does not exist at \(url.path(percentEncoded: false))")
        }
        let pathExtension = url.pathExtension
        let outputURL = URL(filePath: url
            .deletingPathExtension()
            .path(percentEncoded: false)
            .appending("_upscaled"))
            .appendingPathExtension(pathExtension)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ValidationError("File already exists at \(outputURL.path(percentEncoded: false))")
        }

        let asset = AVAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ValidationError("Failed to get video track from input file")
        }

        let inputSize = try await videoTrack.load(.naturalSize)

        // 1. Use passed in width/height
        // 2. Use proportional width/height if only one is specified
        // 3. Default to 2x upscale

        let width = width ??
            height.map { Int(inputSize.width * (CGFloat($0) / inputSize.height)) } ??
            Int(inputSize.width) * 2
        let height = height ??
            Int(inputSize.height * (CGFloat(width) / inputSize.width))

        guard width <= UpscalingExportSession.maxSize,
              height <= UpscalingExportSession.maxSize else {
            throw ValidationError("Maximum supported width/height: 16384")
        }

        let outputSize = CGSize(width: width, height: height)

        let outputFileType: AVFileType = {
            switch url.pathExtension.lowercased() {
            case "mov": return .mov
            case "m4v": return .m4v
            case "mp4": return .mp4
            default:
                CommandLine.warn("Unsupported file type \"\(url.pathExtension)\", defaulting to mp4")
                return .mp4
            }
        }()

        let exportSession = UpscalingExportSession(
            asset: asset,
            outputURL: outputURL,
            outputFileType: outputFileType,
            outputSize: outputSize
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
