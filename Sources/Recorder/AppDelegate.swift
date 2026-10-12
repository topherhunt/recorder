import AppKit
import AVFoundation
import SwiftUI
import RecorderCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let catalog = SourceCatalog()
    private let regionSelector = RegionSelector()
    private var setupWindow: NSWindow?
    private var regionPreview: (display: CGDirectDisplayID, rect: CGRect)?
    private var recording: Recording?
    private var stopping = false
    private var startedAt = Date()
    private var ticker: Timer?
    private var lastRecording: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button!.target = self
        statusItem.button!.action = #selector(statusItemClicked)
        showIdle()
        showSetup()
    }

    // MARK: Status item

    private func showIdle() {
        let button = statusItem.button!
        button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recorder")
        button.contentTintColor = nil
        button.title = ""
        button.toolTip = "Recorder"

        let menu = NSMenu()
        menu.addItem(withTitle: "New Recording…", action: #selector(showSetup), keyEquivalent: "n").target = self
        if lastRecording != nil {
            menu.addItem(withTitle: "Show Last Recording in Finder", action: #selector(revealLast), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func showRecording() {
        statusItem.menu = nil  // a plain click now stops instead of opening a menu
        let button = statusItem.button!
        button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        button.contentTintColor = .systemRed
        button.imagePosition = .imageLeading
        button.toolTip = "Click to stop recording"
        updateTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTicker() }
        }
    }

    /// Elapsed time and bytes on disk, so you can see the file stays small while recording.
    private func updateTicker() {
        guard let recording else { return }
        let secs = Int(Date().timeIntervalSince(startedAt))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: recording.url.path)[.size] as? Int) ?? 0
        let time = secs >= 3600
            ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
            : String(format: "%d:%02d", secs / 60, secs % 60)
        statusItem.button!.title = " \(time) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    @objc private func statusItemClicked() {
        if recording != nil { Task { await stop(reason: nil) } }
    }

    @objc private func revealLast() {
        if let lastRecording { NSWorkspace.shared.activateFileViewerSelecting([lastRecording]) }
    }

    // MARK: Setup window

    @objc func showSetup() {
        if setupWindow == nil {
            let view = SetupView(
                catalog: catalog,
                selectRegion: { [weak self] id, done in self?.selectRegion(on: id, done) },
                previewRegion: { [weak self] id, rect in self?.setRegionPreview(rect.map { (id, $0) }) },
                onRecord: { [weak self] target, options, dir in Task { await self?.start(target: target, options: options, dir: dir) } },
                onCancel: { [weak self] in self?.hideSetup() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "New Recording"
            window.styleMask = [.titled, .closable, .resizable]
            window.level = .floating  // stays above the region preview overlay
            window.setContentSize(NSSize(width: 820, height: 490))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            setupWindow = window
        } else {
            Task { await catalog.refresh() }
        }
        NSApp.activate()
        setupWindow!.makeKeyAndOrderFront(nil)
        if let regionPreview { regionSelector.preview(regionPreview.rect, on: regionPreview.display) }
    }

    private func setRegionPreview(_ preview: (display: CGDirectDisplayID, rect: CGRect)?) {
        regionPreview = preview
        guard setupWindow?.isVisible == true else { return }
        regionSelector.preview(preview?.rect, on: preview?.display ?? 0)
    }

    private func hideSetup() {
        setupWindow?.orderOut(nil)
        regionSelector.preview(nil, on: 0)
    }

    func windowWillClose(_ notification: Notification) {
        regionSelector.preview(nil, on: 0)
    }

    private func selectRegion(on displayID: CGDirectDisplayID, _ done: @escaping (CGRect?) -> Void) {
        hideSetup()
        regionSelector.select(on: displayID) { [weak self] rect in
            done(rect)
            self?.showSetup()
        }
    }

    // MARK: Recording lifecycle

    private func start(target: CaptureTarget, options: RecordingOptions, dir: URL) async {
        guard recording == nil else { return }
        if options.mic {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                return showAlert("Microphone access is off.", info: "Turn it on in System Settings › Privacy & Security › Microphone, or untick “Record microphone”.")
            }
        }
        let url = dir.appendingPathComponent(FileNaming.recordingName(at: Date()))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rec = try Recording(filter: target.filter, options: options, url: url)
            rec.onUnexpectedStop = { [weak self] error in
                Task { @MainActor in await self?.stop(reason: error) }
            }
            hideSetup()
            try await rec.start()
            recording = rec
            startedAt = Date()
            showRecording()
        } catch {
            try? FileManager.default.removeItem(at: url)
            showAlert("Couldn't start recording.", info: error.localizedDescription)
            showSetup()
        }
    }

    /// `reason` is the error that ended capture on its own; nil for a normal stop.
    private func stop(reason: Error?) async {
        guard let rec = recording, !stopping else { return }
        stopping = true
        ticker?.invalidate()
        statusItem.button!.title = " Saving…"
        defer {
            recording = nil
            stopping = false
            showIdle()
        }
        do {
            try await rec.stop()
            lastRecording = rec.url
            if let reason { showAlert("Recording stopped early, but the file was saved.", info: reason.localizedDescription) }
            if rec.droppedFrames > 0 {
                showAlert("\(rec.droppedFrames) frames were dropped.", info: "The encoder couldn't keep up. Try a lower resolution, frame rate, or bitrate.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([rec.url])
        } catch {
            showAlert("The recording couldn't be saved.", info: [reason, error].compactMap { $0?.localizedDescription }.joined(separator: "\n\n"))
        }
    }
}
