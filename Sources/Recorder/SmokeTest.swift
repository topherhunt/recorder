import AVFoundation
import RecorderCore

/// `Recorder --smoke-test <seconds> <out.mov>`: records the main display at 720p
/// with computer audio through the real capture path, then checks the file.
@MainActor
enum SmokeTest {
    static func run(seconds: Double, out: URL) async -> Int32 {
        do {
            let catalog = SourceCatalog()
            await catalog.refresh()
            if let error = catalog.loadError { throw RecorderError(error) }
            let target = try catalog.target(mode: .display, displayID: CGMainDisplayID(), windowID: 0, region: nil)
            let expected = Sizing.outputSize(native: target.nativeSize, preset: .p720)
            let options = RecordingOptions(output: expected, sourceRect: nil, fps: 30, codec: .h264, videoMbps: 4,
                                           systemAudio: true, mic: false, micDeviceID: nil, showsCursor: true)
            try? FileManager.default.removeItem(at: out)
            let rec = try Recording(filter: target.filter, options: options, url: out)
            try await rec.start()
            try await Task.sleep(for: .seconds(seconds))
            try await rec.stop()

            let asset = AVURLAsset(url: out)
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let video = videoTracks.first else { throw RecorderError("no video track") }
            let size = try await video.load(.naturalSize)
            let bytes = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
            let budget = Int(Sizing.megabytesPerMinute(videoMbps: 4, audioTracks: 1) * 1_000_000 / 60 * seconds * 1.5)

            print("native \(target.nativeSize) -> output \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", duration))s, audio tracks \(audioTracks.count), \(bytes) bytes (budget \(budget)), dropped \(rec.droppedFrames)")
            var failures: [String] = []
            if Int(size.width) != expected.width || Int(size.height) != expected.height { failures.append("size is not \(expected)") }
            if abs(duration - seconds) > 0.5 { failures.append("duration off by more than 0.5s") }
            if audioTracks.count != 1 { failures.append("expected 1 audio track") }
            if bytes > budget { failures.append("file larger than 1.5x the bitrate budget") }
            if failures.isEmpty { print("PASS"); return 0 }
            print("FAIL: " + failures.joined(separator: "; "))
            return 1
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }
}
