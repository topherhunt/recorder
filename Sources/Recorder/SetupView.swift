import AppKit
import SwiftUI
import RecorderCore
import ScreenCaptureKit

struct SetupView: View {
    @ObservedObject var catalog: SourceCatalog
    let selectRegion: (CGDirectDisplayID, @escaping (CGRect?) -> Void) -> Void
    /// Reports the region to outline on screen; nil when no region applies.
    let previewRegion: (CGDirectDisplayID, CGRect?) -> Void
    let onRecord: (CaptureTarget, RecordingOptions, URL) -> Void
    let onCancel: () -> Void

    @AppStorage("mode") private var mode: CaptureMode = .display
    @AppStorage("displayID") private var displayID = 0
    @AppStorage("region") private var regionString = ""
    @AppStorage("preset") private var preset: ResolutionPreset = .p1080
    @AppStorage("fps") private var fps = 30
    @AppStorage("codec") private var codec: VideoCodec = .h264
    @AppStorage("quality") private var quality: Quality = .balanced
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("mic") private var mic = false
    @AppStorage("micDeviceID") private var micDeviceID = ""  // "" = system default input
    @AppStorage("showsCursor") private var showsCursor = true
    @AppStorage("outputDir") private var outputDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].path
    @State private var windowID = 0

    private var region: CGRect? { regionString.isEmpty ? nil : NSRectFromString(regionString) }

    private var target: Result<CaptureTarget, Error> {
        Result {
            if mode == .audio && !systemAudio && !mic { throw RecorderError("Turn on computer audio or the microphone.") }
            return try catalog.target(mode: mode, displayID: CGDirectDisplayID(displayID), windowID: CGWindowID(windowID), region: region)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = catalog.loadError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding([.horizontal, .top])
            }
            HStack(alignment: .top, spacing: 0) {
                Form {
                    captureSection
                    videoSection
                }
                Form {
                    audioSection
                    Section("Save to") {
                        HStack {
                            Text((outputDir as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // A grouped Form is a scroll view with no natural height; without this the window collapses to the button row.
            .frame(minHeight: 300)

            HStack {
                summary.font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Record", action: record).keyboardShortcut(.defaultAction)
                    .disabled((try? target.get()) == nil)
            }
            .padding()
        }
        .frame(minWidth: 760)
        .task { await reload() }
        .onChange(of: "\(mode.rawValue)|\(displayID)|\(regionString)", initial: true) {
            previewRegion(CGDirectDisplayID(displayID), mode == .region ? region : nil)
        }
    }

    private var captureSection: some View {
        Section("Capture") {
            Picker("Source", selection: $mode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .window:
                HStack {
                    Picker("Window", selection: $windowID) {
                        ForEach(catalog.windows, id: \.windowID) { Text($0.menuLabel).tag(Int($0.windowID)) }
                    }
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the window list")
                }
            case .display, .region:
                Picker("Screen", selection: $displayID) {
                    ForEach(catalog.displays, id: \.displayID) { Text(displayName($0)).tag(Int($0.displayID)) }
                }
                .onChange(of: displayID) { regionString = "" }
            case .audio:
                Text("Records sound only, to an .m4a file.").foregroundStyle(.secondary)
            }

            if mode == .region {
                HStack {
                    Text(region.map { "\(Int($0.width)) × \(Int($0.height)) pt" } ?? "No region selected")
                        .foregroundStyle(region == nil ? .secondary : .primary)
                    Spacer()
                    Button(region == nil ? "Select Region…" : "Reselect…") {
                        selectRegion(CGDirectDisplayID(displayID)) { rect in
                            if let rect { regionString = NSStringFromRect(rect) }
                        }
                    }
                }
            }
            if mode != .audio {
                Toggle("Show mouse cursor", isOn: $showsCursor)
            }
        }
    }

    private var videoSection: some View {
        Section("Video") {
            Picker("Resolution", selection: $preset) {
                ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
            }
            Picker("Frame rate", selection: $fps) {
                ForEach([10, 15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("Codec", selection: $codec) {
                ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
            }
            Picker("Quality", selection: $quality) {
                ForEach(Quality.allCases) { Text($0.label).tag($0) }
            }
            .help("Trades file size for sharpness. Balanced keeps text crisp; Small is fine for talking over slides.")
        }
        .disabled(mode == .audio)
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Record computer audio", isOn: $systemAudio)
            Toggle("Record microphone", isOn: $mic)
            if mic {
                Picker("Microphone", selection: $micDeviceID) {
                    Text("System default").tag("")
                    ForEach(catalog.micDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            if systemAudio && mic {
                Text(mode == .audio ? "Computer audio and mic are mixed into one track." : "Computer audio and mic are saved as two separate audio tracks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        switch target {
        case .success where mode == .audio:
            Text("Audio only · ≈ \(Int(Sizing.megabytesPerMinute(videoMbps: 0, audioTracks: 1).rounded())) MB/min")
        case .success(let t):
            let out = Sizing.outputSize(native: t.nativeSize, preset: preset)
            let mbps = Sizing.videoMbps(size: out, fps: fps, quality: quality)
            let mb = Sizing.megabytesPerMinute(videoMbps: mbps, audioTracks: (systemAudio ? 1 : 0) + (mic ? 1 : 0))
            Text("\(out.description) · ≈ \(Int(mb.rounded())) MB/min")
                .help("Captured at \(t.nativeSize.description) native pixels, scaled by the GPU, encoded at \(String(format: "%.1f", mbps)) Mbps.")
        case .failure(let error):
            Text(error.localizedDescription)
        }
    }

    private func displayName(_ display: SCDisplay) -> String {
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.localizedName ?? "Display \(display.displayID)"
        return "\(name) (\(display.width)×\(display.height) pt)"
    }

    private func reload() async {
        await catalog.refresh()
        if !catalog.displays.contains(where: { Int($0.displayID) == displayID }) {
            displayID = Int(CGMainDisplayID())
        }
        if !catalog.windows.contains(where: { Int($0.windowID) == windowID }), let first = catalog.windows.first {
            windowID = Int(first.windowID)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputDir)
        if panel.runModal() == .OK, let url = panel.url { outputDir = url.path }
    }

    private func record() {
        let t: CaptureTarget
        do { t = try target.get() } catch { return showAlert(error.localizedDescription) }
        let output = Sizing.outputSize(native: t.nativeSize, preset: preset)
        let options = RecordingOptions(
            video: mode == .audio ? nil : VideoOptions(
                output: output,
                sourceRect: t.sourceRect,
                fps: fps,
                codec: codec,
                mbps: Sizing.videoMbps(size: output, fps: fps, quality: quality),
                showsCursor: showsCursor
            ),
            systemAudio: systemAudio,
            mic: mic,
            micDeviceID: micDeviceID.isEmpty ? nil : micDeviceID
        )
        onRecord(t, options, URL(fileURLWithPath: outputDir, isDirectory: true))
    }
}
