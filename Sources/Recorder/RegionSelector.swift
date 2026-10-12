import AppKit

/// Full-screen overlays on one display. Rects are in display-local points with a
/// top-left origin (ScreenCaptureKit's sourceRect space).
/// - `select`: drag a rectangle, Esc cancels.
/// - `preview`: click-through outline of a chosen region, kept just above normal
///   windows so the (floating) setup window stays on top of it.
@MainActor
final class RegionSelector {
    private var selectWindow: NSWindow?
    private var previewWindow: NSWindow?

    func select(on displayID: CGDirectDisplayID, completion: @escaping (CGRect?) -> Void) {
        guard let screen = screen(for: displayID) else {
            showAlert("That screen is no longer connected.")
            return completion(nil)
        }
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), region: nil)
        view.onDone = { [weak self] rect in
            self?.selectWindow?.orderOut(nil)
            self?.selectWindow = nil
            completion(rect)
        }
        let window = overlay(on: screen, view: view, level: .screenSaver)
        selectWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Pass nil to hide.
    func preview(_ region: CGRect?, on displayID: CGDirectDisplayID) {
        previewWindow?.orderOut(nil)
        previewWindow = nil
        guard let region, let screen = screen(for: displayID) else { return }
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), region: region)
        let window = overlay(on: screen, view: view, level: NSWindow.Level(NSWindow.Level.normal.rawValue + 1))
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        previewWindow = window
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func overlay(on screen: NSScreen, view: NSView, level: NSWindow.Level) -> NSWindow {
        let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var anchor: NSPoint?
    private var selection: NSRect?  // view coordinates (bottom-left origin)

    init(frame: NSRect, region: CGRect?) {
        super.init(frame: frame)
        selection = region.map { NSRect(x: $0.minX, y: frame.height - $0.maxY, width: $0.width, height: $0.height) }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.windingRule = .evenOdd  // the selection rect becomes a hole
        if let selection { dim.appendRect(selection) }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard let selection else {
            label("Drag to select a region. Esc cancels.", at: NSPoint(x: bounds.midX - 140, y: bounds.midY))
            return
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()
        label("\(Int(selection.width)) × \(Int(selection.height)) pt", at: NSPoint(x: selection.minX, y: selection.maxY + 6))
    }

    private func label(_ text: String, at point: NSPoint) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            .integral.intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 16, selection.height >= 16 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onDone?(CGRect(x: selection.minX, y: bounds.height - selection.maxY, width: selection.width, height: selection.height))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }  // 53 = Esc
    }
}

@MainActor
func showAlert(_ message: String, info: String? = nil) {
    let alert = NSAlert()
    alert.messageText = message
    if let info { alert.informativeText = info }
    NSApp.activate()
    alert.runModal()
}
