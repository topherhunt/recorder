import Foundation
import Testing
@testable import RecorderCore

@Test func retinaDisplayScalesDownTo1080p() {
    let out = Sizing.outputSize(native: PixelSize(width: 3456, height: 2234), preset: .p1080)
    // Height-bound: 2234 -> 1080, width follows the 1.547 aspect.
    #expect(out == PixelSize(width: 1670, height: 1080))
}

@Test func nativePresetKeepsPixelsButForcesEven() {
    #expect(Sizing.outputSize(native: PixelSize(width: 1001, height: 777), preset: .native) == PixelSize(width: 1000, height: 776))
}

@Test func neverUpscalesSmallSources() {
    #expect(Sizing.outputSize(native: PixelSize(width: 800, height: 600), preset: .p2160) == PixelSize(width: 800, height: 600))
}

@Test func portraitSourceUsesRotatedBox() {
    let out = Sizing.outputSize(native: PixelSize(width: 2160, height: 3840), preset: .p1080)
    #expect(out == PixelSize(width: 1080, height: 1920))
}

@Test func wideSourceIsWidthBound() {
    let out = Sizing.outputSize(native: PixelSize(width: 5120, height: 1440), preset: .p720)
    #expect(out == PixelSize(width: 1280, height: 360))
}

@Test func sizeEstimateIncludesAudioTracks() {
    #expect(Sizing.megabytesPerMinute(videoMbps: 8, audioTracks: 0) == 60)
    #expect(abs(Sizing.megabytesPerMinute(videoMbps: 8, audioTracks: 2) - 61.92) < 0.001)
}

@Test func recordingNameIsSortableTimestamp() {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 9, 7, 5, 3)
    let date = Calendar.current.date(from: c)!
    #expect(FileNaming.recordingName(at: date) == "Recording 2026-10-09 at 07.05.03.mov")
}
