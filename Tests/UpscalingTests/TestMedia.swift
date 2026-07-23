import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - TestMedia

/// Synthesizes small `.mov` files on disk so the export pipeline can be tested
/// end to end without checking in binary fixtures.
enum TestMedia {
    // MARK: Internal

    struct Options {
        var size = CGSize(width: 160, height: 120)
        var frameCount = 24
        var fps: Int32 = 24
        var transform: CGAffineTransform = .identity
        var includeAudio = false
        var metadata: [AVMetadataItem] = []
    }

    enum Failure: Error {
        case cannotAddInput
        case writeFailed
        case pixelBufferFailed
        case videoSampleFailed
        case audioSetup
        case audioSampleFailed
    }

    /// Writes a video (optionally with a silent LPCM audio track) to a unique
    /// temporary URL and returns it.
    static func makeVideo(_ options: Options = Options()) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-upscale-test-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if !options.metadata.isEmpty {
            writer.metadata = options.metadata
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(options.size.width),
            AVVideoHeightKey: Int(options.size.height)
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = options.transform
        guard writer.canAdd(videoInput) else { throw Failure.cannotAddInput }
        writer.add(videoInput)

        let sampleRate = 44100.0
        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if options.includeAudio {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &audioFormat
            ) == noErr, let audioFormat else { throw Failure.audioSetup }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.cannotAddInput }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? Failure.writeFailed }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<options.frameCount {
            let time = CMTime(value: CMTimeValue(index), timescale: options.fps)
            let pixelBuffer = try makePixelBuffer(size: options.size, frameIndex: index)
            while !videoInput.isReadyForMoreMediaData {
                usleep(500)
            }
            guard let sampleBuffer = makeVideoSampleBuffer(pixelBuffer, at: time, fps: options.fps) else {
                throw Failure.videoSampleFailed
            }
            guard videoInput.append(sampleBuffer) else { throw writer.error ?? Failure.writeFailed }
        }
        videoInput.markAsFinished()

        if let audioInput, let audioFormat {
            let framesPerChunk = Int(sampleRate) / Int(options.fps)
            for index in 0..<options.frameCount {
                let time = CMTime(value: CMTimeValue(index * framesPerChunk), timescale: CMTimeScale(sampleRate))
                guard let sampleBuffer = makeSilentAudioBuffer(
                    at: time,
                    sampleRate: sampleRate,
                    frameCount: framesPerChunk,
                    format: audioFormat
                ) else { throw Failure.audioSampleFailed }
                while !audioInput.isReadyForMoreMediaData {
                    usleep(500)
                }
                guard audioInput.append(sampleBuffer) else { throw writer.error ?? Failure.writeFailed }
            }
            audioInput.markAsFinished()
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw writer.error ?? Failure.writeFailed
        }
        return url
    }

    // MARK: Private

    private static func makePixelBuffer(size: CGSize, frameIndex: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { throw Failure.pixelBufferFailed }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            // A moving diagonal stripe so frames differ and upscaling has detail.
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let on = ((x + y + frameIndex) / 8) % 2 == 0
                    pixels[offset + 0] = on ? 220 : 30 // B
                    pixels[offset + 1] = UInt8((x * 255) / max(width, 1)) // G
                    pixels[offset + 2] = UInt8((y * 255) / max(height, 1)) // R
                    pixels[offset + 3] = 255 // A
                }
            }
        }
        return pixelBuffer
    }

    private static func makeVideoSampleBuffer(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime,
        fps: Int32
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: fps),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private static func makeSilentAudioBuffer(
        at time: CMTime,
        sampleRate: Double,
        frameCount: Int,
        format: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let bytesPerFrame = 2
        let dataLength = frameCount * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataLength)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - Inspection helpers

extension AVAsset {
    func videoDimensions() async throws -> CGSize? {
        guard let track = try await loadTracks(withMediaType: .video).first,
              let formatDescription = try await track.load(.formatDescriptions).first else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }

    /// Counts decoded frames. Decoding (rather than reading compressed samples)
    /// yields exactly one buffer per presentation frame.
    func videoFrameCount() async throws -> Int {
        guard let track = try await loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: self)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        var count = 0
        while output.copyNextSampleBuffer() != nil {
            count += 1
        }
        return count
    }
}
