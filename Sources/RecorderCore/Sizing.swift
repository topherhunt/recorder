import Foundation

public struct PixelSize: Equatable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public var description: String { "\(width)×\(height)" }
}

public enum ResolutionPreset: String, CaseIterable, Identifiable {
    case native, p2160, p1440, p1080, p720, p480

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .native: "Native (Retina pixels)"
        case .p2160: "4K (3840×2160)"
        case .p1440: "1440p (2560×1440)"
        case .p1080: "1080p (1920×1080)"
        case .p720: "720p (1280×720)"
        case .p480: "480p (854×480)"
        }
    }

    /// Landscape bounding box; nil means no scaling.
    var box: PixelSize? {
        switch self {
        case .native: nil
        case .p2160: PixelSize(width: 3840, height: 2160)
        case .p1440: PixelSize(width: 2560, height: 1440)
        case .p1080: PixelSize(width: 1920, height: 1080)
        case .p720: PixelSize(width: 1280, height: 720)
        case .p480: PixelSize(width: 854, height: 480)
        }
    }
}

public enum Sizing {
    /// Scales `native` to fit inside the preset's box (rotated to match a portrait
    /// source), preserving aspect ratio and never upscaling. Both dimensions come
    /// out even: the 4:2:0 encoders reject odd sizes.
    public static func outputSize(native: PixelSize, preset: ResolutionPreset) -> PixelSize {
        precondition(native.width > 0 && native.height > 0, "empty capture area \(native)")
        var box = preset.box ?? native
        if native.height > native.width { box = PixelSize(width: box.height, height: box.width) }
        let scale = min(1.0, Double(box.width) / Double(native.width), Double(box.height) / Double(native.height))
        return PixelSize(width: even(Double(native.width) * scale), height: even(Double(native.height) * scale))
    }

    /// Video plus 128 kbps per AAC track, in megabytes per minute.
    public static func megabytesPerMinute(videoMbps: Double, audioTracks: Int) -> Double {
        (videoMbps + 0.128 * Double(audioTracks)) * 60 / 8
    }

    private static func even(_ x: Double) -> Int { max(2, Int(x.rounded()) & ~1) }
}

public enum FileNaming {
    public static func recordingName(at date: Date, ext: String = "mov") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(f.string(from: date)).\(ext)"
    }
}
