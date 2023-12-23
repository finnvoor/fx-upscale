import ArgumentParser
import AVFoundation
import Foundation
import MetalFX
import SwiftTUI

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

        guard width <= 7680, height <= 7680 else {
            throw ValidationError("Maximum supported width/height: 7680")
        }

        let outputSize = CGSize(width: width, height: height)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = UpscalingCompositor.self
        videoComposition.renderSize = CGSize(width: width, height: height)
        videoComposition.frameDuration = try await videoTrack.load(.minFrameDuration)
        let timeRange = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
        let instruction = UpscalingCompositor.Instruction(timeRange: timeRange)
        videoComposition.instructions = [instruction]

        let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC7680x4320)!
        exportSession.videoComposition = videoComposition
        (exportSession.customVideoCompositor as! UpscalingCompositor).inputSize = inputSize
        (exportSession.customVideoCompositor as! UpscalingCompositor).outputSize = outputSize
        exportSession.outputURL = outputURL

        switch url.pathExtension.lowercased() {
        case "mov": exportSession.outputFileType = .mov
        case "m4v": exportSession.outputFileType = .m4v
        case "mp4": exportSession.outputFileType = .mp4
        default:
            CommandLine.warn("Unsupported file type \"\(url.pathExtension)\", defaulting to mp4")
            exportSession.outputFileType = .mp4
        }

        let estimatedFileLength = try await ByteCountFormatter()
            .string(fromByteCount: exportSession.estimatedOutputFileLengthInBytes)
        CommandLine.info([
            "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) ",
            "to \(Int(outputSize.width))x\(Int(outputSize.height)) ",
            "(~\(estimatedFileLength))".faint
        ].joined())
        ActivityIndicator.start()
        await exportSession.export()
        ActivityIndicator.stop()
        if let error = exportSession.error { throw error }
        CommandLine.success("Video successfully upscaled!")
    }
}
