import AppKit
import SwiftUI
import RecorderCore
import ScreenCaptureKit

struct SetupView: View {
    @ObservedObject var catalog: SourceCatalog
    let selectRegion: (CGDirectDisplayID, @escaping (CGRect?) -> Void) -> Void
    let onRecord: (CaptureTarget, RecordingOptions, URL) -> Void
    let onCancel: () -> Void

    @AppStorage("mode") private var mode: CaptureMode = .display
    @AppStorage("displayID") private var displayID = 0
    @AppStorage("region") private var regionString = ""
    @AppStorage("preset") private var preset: ResolutionPreset = .p1080
    @AppStorage("fps") private var fps = 30
    @AppStorage("codec") private var codec: VideoCodec = .h264
    @AppStorage("videoMbps") private var videoMbps = 6.0
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("mic") private var mic = false
    @AppStorage("micDeviceID") private var micDeviceID = ""  // "" = system default input
    @AppStorage("showsCursor") private var showsCursor = true
    @AppStorage("outputDir") private var outputDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].path
    @State private var windowID = 0

    private var region: CGRect? { regionString.isEmpty ? nil : NSRectFromString(regionString) }

    private var target: Result<CaptureTarget, Error> {
        Result { try catalog.target(mode: mode, displayID: CGDirectDisplayID(displayID), windowID: CGWindowID(windowID), region: region) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let error = catalog.loadError {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                captureSection
                videoSection
                audioSection
                Section("Save to") {
                    HStack {
                        Text((outputDir as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                summary.font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Record", action: record).keyboardShortcut(.defaultAction)
                    .disabled((try? target.get()) == nil)
            }
            .padding()
        }
        .frame(width: 480)
        .task { await reload() }
    }

    private var captureSection: some View {
        Section("Capture") {
            Picker("Source", selection: $mode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .window {
                HStack {
                    Picker("Window", selection: $windowID) {
                        ForEach(catalog.windows, id: \.windowID) { Text($0.menuLabel).tag(Int($0.windowID)) }
                    }
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the window list")
                }
            } else {
                Picker("Screen", selection: $displayID) {
                    ForEach(catalog.displays, id: \.displayID) { Text(displayName($0)).tag(Int($0.displayID)) }
                }
                .onChange(of: displayID) { regionString = "" }
            }

            if mode == .region {
                HStack {
                    Text(region.map { "\(Int($0.width)) × \(Int($0.height)) pt at (\(Int($0.minX)), \(Int($0.minY)))" } ?? "No region selected")
                        .foregroundStyle(region == nil ? .secondary : .primary)
                    Spacer()
                    Button("Select Region…") {
                        selectRegion(CGDirectDisplayID(displayID)) { rect in
                            if let rect { regionString = NSStringFromRect(rect) }
                        }
                    }
                }
            }
            Toggle("Show mouse cursor", isOn: $showsCursor)
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
            .pickerStyle(.segmented)
            Picker("Codec", selection: $codec) {
                ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Bitrate")
                Slider(value: $videoMbps, in: 1...30, step: 0.5)
                Text(String(format: "%.1f Mbps", videoMbps)).monospacedDigit().frame(width: 72, alignment: .trailing)
            }
        }
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
                Text("Computer audio and mic are saved as two separate audio tracks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        switch target {
        case .success(let t):
            let out = Sizing.outputSize(native: t.nativeSize, preset: preset)
            let mb = Sizing.megabytesPerMinute(videoMbps: videoMbps, audioTracks: (systemAudio ? 1 : 0) + (mic ? 1 : 0))
            Text("\(out.description) · ≈ \(Int(mb.rounded())) MB/min")
                .help("Captured at \(t.nativeSize.description) native pixels, scaled by the GPU before encoding.")
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
        let options = RecordingOptions(
            output: Sizing.outputSize(native: t.nativeSize, preset: preset),
            sourceRect: t.sourceRect,
            fps: fps,
            codec: codec,
            videoMbps: videoMbps,
            systemAudio: systemAudio,
            mic: mic,
            micDeviceID: micDeviceID.isEmpty ? nil : micDeviceID,
            showsCursor: showsCursor
        )
        onRecord(t, options, URL(fileURLWithPath: outputDir, isDirectory: true))
    }
}
