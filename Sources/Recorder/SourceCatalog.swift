import AVFoundation
import ScreenCaptureKit
import RecorderCore

enum CaptureMode: String, CaseIterable, Identifiable {
    case display, window, region, audio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: "Screen"
        case .window: "Window"
        case .region: "Region"
        case .audio: "Audio only"
        }
    }
}

struct CaptureTarget {
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let nativeSize: PixelSize
}

@MainActor
final class SourceCatalog: ObservableObject {
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var micDevices: [AVCaptureDevice] = []
    @Published private(set) var loadError: String?
    private var ownApp: SCRunningApplication?

    func refresh() async {
        micDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            ownApp = content.applications.first { $0.processID == pid }
            displays = content.displays
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.owningApplication?.processID != pid && $0.frame.width > 40 && $0.frame.height > 40 }
                .sorted { ($0.owningApplication?.applicationName ?? "", $0.title ?? "") < ($1.owningApplication?.applicationName ?? "", $1.title ?? "") }
            loadError = nil
        } catch {
            loadError = "Screen Recording permission is needed. Grant it in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Recorder. (\(error.localizedDescription))"
        }
    }

    /// `region` is in display-local points with a top-left origin, as ScreenCaptureKit's sourceRect expects.
    /// `.audio` still needs a display filter: ScreenCaptureKit captures audio only as part of a stream.
    func target(mode: CaptureMode, displayID: CGDirectDisplayID, windowID: CGWindowID, region: CGRect?) throws -> CaptureTarget {
        switch mode {
        case .display, .region, .audio:
            guard let display = displays.first(where: { $0.displayID == displayID }) else { throw RecorderError("Pick a screen.") }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp.map { [$0] } ?? [], exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            if mode != .region {
                return CaptureTarget(filter: filter, sourceRect: nil, nativeSize: pixels(filter.contentRect.size, scale))
            }
            guard let region, region.width >= 2, region.height >= 2 else { throw RecorderError("Select a region first.") }
            return CaptureTarget(filter: filter, sourceRect: region, nativeSize: pixels(region.size, scale))
        case .window:
            guard let window = windows.first(where: { $0.windowID == windowID }) else { throw RecorderError("Pick a window.") }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return CaptureTarget(filter: filter, sourceRect: nil, nativeSize: pixels(filter.contentRect.size, CGFloat(filter.pointPixelScale)))
        }
    }

    private func pixels(_ size: CGSize, _ scale: CGFloat) -> PixelSize {
        PixelSize(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
    }
}

extension SCWindow {
    var menuLabel: String {
        let app = owningApplication?.applicationName ?? "?"
        guard let title, !title.isEmpty else { return app }
        return "\(app) -- \(title)"
    }
}
