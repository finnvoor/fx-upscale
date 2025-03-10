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
    @Option(name: .shortAndLong, help: "Output codec: 'hevc', 'prores', or 'h264' (default: hevc)") var codec: String = "hevc"

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
        let outputCodec: AVVideoCodecType? = switch codec.lowercased() {
        case "prores": .proRes422
        case "h264": .h264
        default: .hevc
        }

        // Through anecdotal tests anything beyond 14.5K fails to encode for anything other than ProRes
        let convertToProRes = (outputSize.width * outputSize.height) > (14500 * 8156)

        if convertToProRes {
            CommandLine.info("Forced ProRes conversion due to output size being larger than 14.5K (will fail otherwise)")
        }

        let exportSession = UpscalingExportSession(
            asset: asset,
            outputCodec: convertToProRes ? .proRes422 : outputCodec,
            preferredOutputURL: url.renamed { "\($0) Upscaled" },
            outputSize: outputSize,
            creator: ProcessInfo.processInfo.processName
        )

        CommandLine.info([
            "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) ",
            "to \(Int(outputSize.width))x\(Int(outputSize.height)) ",
            "using codec: \(outputCodec?.rawValue ?? "hevc")"
        ].joined())
        ProgressBar.start(progress: exportSession.progress)
        try await exportSession.export()
        ProgressBar.stop()
        CommandLine.success("Video successfully upscaled!")
    }
}
