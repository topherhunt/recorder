import AVFoundation
import ScreenCaptureKit
import RecorderCore

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "HEVC" }
    var avType: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

struct VideoOptions {
    var output: PixelSize
    var sourceRect: CGRect?
    var fps: Int
    var codec: VideoCodec
    var mbps: Double
    var showsCursor: Bool
}

struct RecordingOptions {
    /// nil records audio only, to an .m4a.
    var video: VideoOptions?
    var systemAudio: Bool
    var mic: Bool
    var micDeviceID: String?

    var fileExtension: String { video == nil ? "m4a" : "mov" }
}

struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// One capture session: SCStream frames and audio go straight into hardware
/// encoders via AVAssetWriter, so only compressed data ever reaches disk.
/// `@unchecked Sendable`: mutable state is touched only on `queue`.
final class Recording: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    let options: RecordingOptions
    /// Called on the sample queue when capture dies on its own (system "Stop Sharing", display unplugged, writer error).
    var onUnexpectedStop: ((Error?) -> Void)?

    private let stream: SCStream
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let systemInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "recorder.samples", qos: .userInitiated)
    private let stopForwarder = StopForwarder()

    // Mutated only on `queue`.
    private var sessionStart: CMTime?
    private var finished = false
    private(set) var droppedFrames = 0

    init(filter: SCContentFilter, options: RecordingOptions, url: URL) throws {
        self.url = url
        self.options = options

        let config = SCStreamConfiguration()
        if let video = options.video {
            config.width = video.output.width
            config.height = video.output.height
            if let rect = video.sourceRect { config.sourceRect = rect }
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(video.fps))
            config.showsCursor = video.showsCursor
        } else {
            // SCStream always captures frames; audio-only discards them, so keep them tiny and rare.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.preservesAspectRatio = true
        config.queueDepth = 6
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.mic
        if let id = options.micDeviceID { config.microphoneCaptureDeviceID = id }

        writer = try AVAssetWriter(outputURL: url, fileType: options.video == nil ? .m4a : .mov)
        // Fragmented: a crash loses at most the last few seconds instead of the whole file.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        videoInput = options.video.map { video in
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: video.codec.avType,
                AVVideoWidthKey: video.output.width,
                AVVideoHeightKey: video.output.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(video.mbps * 1_000_000),
                    AVVideoExpectedSourceFrameRateKey: video.fps,
                    AVVideoMaxKeyFrameIntervalKey: video.fps * 2,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemInput = options.systemAudio ? audioInput() : nil
        micInput = options.mic ? audioInput() : nil
        for input in [videoInput, systemInput, micInput].compactMap({ $0 }) { writer.add(input) }

        stream = SCStream(filter: filter, configuration: config, delegate: stopForwarder)
        super.init()
        stopForwarder.onStop = { [weak self] error in self?.streamDidStop(error) }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if options.mic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? RecorderError("Could not open \(url.path) for writing.") }
        try await stream.startCapture()
    }

    /// Stops capture and finalizes the file. Safe to call after an unexpected stop.
    func stop() async throws {
        do { try await stream.stopCapture() } catch {
            // Already stopped (e.g. via the system's Stop Sharing control) -- finalize anyway.
            NSLog("stopCapture: \(error)")
        }
        try await finalize()
        if options.video == nil, options.systemAudio, options.mic { try await mixDown() }
    }

    /// Merges the computer audio and mic tracks into one: most players and transcription tools play only an audio file's first track.
    private func mixDown() async throws {
        let mixed = url.deletingPathExtension().appendingPathExtension("mixing.m4a")
        do {
            guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
                throw RecorderError("The M4A export preset is unavailable.")
            }
            try await export.export(to: mixed, as: .m4a)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: mixed)
        } catch {
            try? FileManager.default.removeItem(at: mixed)
            throw RecorderError("Mixing the computer audio and mic failed, so the file keeps them as two separate tracks. (\(error.localizedDescription))")
        }
    }

    private func finalize() async throws {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !finished else {
                    if writer.status == .failed { return cont.resume(throwing: writer.error ?? RecorderError("The video writer failed.")) }
                    return cont.resume()
                }
                finished = true
                guard sessionStart != nil else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    return cont.resume(throwing: RecorderError("No \(videoInput == nil ? "audio" : "video frames") arrived, so nothing was recorded."))
                }
                for input in [videoInput, systemInput, micInput].compactMap({ $0 }) { input.markAsFinished() }
                // Ending at the stop time (not the last frame) keeps a static final screen in the video.
                writer.endSession(atSourceTime: stopTime)
                writer.finishWriting { [self] in
                    if writer.status == .completed { cont.resume() } else {
                        cont.resume(throwing: writer.error ?? RecorderError("Finalizing the file failed (status \(writer.status.rawValue))."))
                    }
                }
            }
        }
    }

    // MARK: SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sample.isValid else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit also emits idle/blank status buffers with no image; only complete frames are video.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let videoInput else { return }
            startSessionIfNeeded(at: sample)
            append(sample, to: videoInput, countDrops: true)
        case .audio:
            guard let systemInput else { return }
            if videoInput == nil { startSessionIfNeeded(at: sample) }
            append(sample, to: systemInput, countDrops: false)
        case .microphone:
            guard let micInput else { return }
            if videoInput == nil { startSessionIfNeeded(at: sample) }
            append(sample, to: micInput, countDrops: false)
        @unknown default:
            return
        }
        if writer.status == .failed {
            finished = true
            onUnexpectedStop?(writer.error ?? RecorderError("The video writer failed."))
        }
    }

    /// The first video frame (or, for audio only, the first audio sample) sets time zero; anything earlier is dropped.
    private func startSessionIfNeeded(at sample: CMSampleBuffer) {
        guard sessionStart == nil else { return }
        sessionStart = sample.presentationTimeStamp
        writer.startSession(atSourceTime: sample.presentationTimeStamp)
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, countDrops: Bool) {
        guard let start = sessionStart, sample.presentationTimeStamp >= start else { return }
        if input.isReadyForMoreMediaData {
            input.append(sample)
        } else if countDrops {
            droppedFrames += 1
        }
    }

    private func streamDidStop(_ error: Error) {
        let userStopped = (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == SCStreamError.userStopped.rawValue
        onUnexpectedStop?(userStopped ? nil : error)
    }
}

/// SCStream takes its delegate only at init, before `Recording` has a `self` to pass.
private final class StopForwarder: NSObject, SCStreamDelegate {
    var onStop: ((Error) -> Void)?
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
