// HighlightAnything.swift — shift-drag, OCR, copy.
//
// Hold Shift, drag a rectangle over anything on screen. The region is captured
// via ScreenCaptureKit, run through Vision OCR, and the result lands on your
// clipboard. A toast confirms what was copied.
//
// Build:  ./build.sh
// Permissions: Accessibility (Shift key) + Screen Recording (capture).
// Requires macOS 14+.

import Cocoa
import Vision
import ScreenCaptureKit
import ApplicationServices

// MARK: - Permissions

func hasAccessibilityPermission(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

func hasScreenRecordingPermission() -> Bool {
    return CGPreflightScreenCaptureAccess()
}

func requestScreenRecordingPermission() {
    _ = CGRequestScreenCaptureAccess()
}

// MARK: - Toast HUD

final class ToastWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 64),
                   styleMask: .borderless, backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 14
        visual.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: visual.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -18)
        ])
        self.contentView = visual
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ message: String, duration: TimeInterval = 4.8) {
        label.stringValue = message
        guard let screen = NSScreen.main else { return }
        let f = self.frame
        let target = NSRect(x: screen.frame.midX - f.width / 2,
                            y: screen.frame.minY + 110,
                            width: f.width, height: f.height)
        self.setFrame(target, display: true)
        self.alphaValue = 0
        self.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1
        }
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            self.animator().alphaValue = 0
        }, completionHandler: { self.orderOut(nil) })
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        self.level = .screenSaver
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                   .fullScreenAuxiliary, .ignoresCycle]
        self.isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Capture view

protocol CaptureViewDelegate: AnyObject {
    func captureView(_ view: CaptureView, didSelectScreenRect rect: NSRect)
}

final class CaptureView: NSView {
    weak var delegate: CaptureViewDelegate?
    private var currentRect: NSRect?
    private var startPoint: NSPoint?
    var armed: Bool = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let r = currentRect {
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: r).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: r)
            outline.lineWidth = 1.5
            outline.setLineDash([6, 3], count: 2, phase: 0)
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentRect = NSRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let captured = currentRect
        currentRect = nil
        startPoint = nil
        needsDisplay = true

        guard let r = captured, r.width > 4, r.height > 4,
              let win = self.window else { return }
        let screenRect = win.convertToScreen(r)
        delegate?.captureView(self, didSelectScreenRect: screenRect)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

// MARK: - Screen capture (ScreenCaptureKit)

enum ScreenCapture {
    /// Capture a region of the screen in CG coordinates (origin = top-left of primary display).
    /// Excludes any windows whose CGWindowID is in `excludingWindowIDs`.
    static func capture(rect cgRect: CGRect,
                        excludingWindowIDs: Set<CGWindowID>) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        guard let display = content.displays.first(where: { $0.frame.intersects(cgRect) }) else {
            throw NSError(domain: "HighlightAnything", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No display contains the selected region"
            ])
        }

        let toExclude = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: toExclude)

        // Pixel-vs-point scale for this display (2 on Retina, 1 otherwise).
        let scale = display.frame.width > 0
            ? CGFloat(display.width) / display.frame.width
            : 2.0

        let config = SCStreamConfiguration()
        // sourceRect is in points, relative to the display's own origin.
        config.sourceRect = CGRect(
            x: cgRect.origin.x - display.frame.origin.x,
            y: cgRect.origin.y - display.frame.origin.y,
            width: cgRect.width,
            height: cgRect.height
        )
        config.width = max(1, Int(cgRect.width * scale))
        config.height = max(1, Int(cgRect.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }
}

// MARK: - OCR

enum OCR {
    static func recognize(in cgImage: CGImage,
                          completion: @escaping (Result<String, Error>) -> Void) {
        let request = VNRecognizeTextRequest { req, err in
            if let err = err { completion(.failure(err)); return }
            let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            completion(.success(lines.joined(separator: "\n")))
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, CaptureViewDelegate {
    private var overlays: [(window: OverlayWindow, view: CaptureView)] = []
    private let toast = ToastWindow()
    private var statusItem: NSStatusItem!
    private var shiftHeld = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        rebuildOverlays()
        setupShiftMonitor()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        flashStartup()
        DispatchQueue.main.async { [weak self] in self?.checkPermissions() }
    }

    private func checkPermissions() {
        var missing: [String] = []
        if !hasAccessibilityPermission(prompt: false) {
            missing.append("Accessibility (detect the Shift key)")
        }
        if !hasScreenRecordingPermission() {
            missing.append("Screen Recording (capture pixels for OCR)")
            requestScreenRecordingPermission()
        }
        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Highlight Anything needs two permissions"
        alert.informativeText = """
        • \(missing.joined(separator: "\n• "))

        Click Open Settings, enable Highlight Anything in BOTH panes (Accessibility AND Screen Recording), then quit Highlight Anything from the 📋 menu and relaunch.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Screen Recording")
        alert.addButton(withTitle: "Continue Anyway")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  openAccessibilityPane()
        case .alertSecondButtonReturn: openScreenRecordingPane()
        default: break
        }
    }

    @objc private func screensChanged() {
        rebuildOverlays()
        for o in overlays {
            o.window.ignoresMouseEvents = !shiftHeld
            o.view.armed = shiftHeld
        }
    }

    private func rebuildOverlays() {
        for o in overlays { o.window.orderOut(nil) }
        overlays.removeAll()
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen)
            let v = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.autoresizingMask = [.width, .height]
            v.delegate = self
            win.contentView = v
            win.orderFrontRegardless()
            overlays.append((win, v))
        }
    }

    private func flashStartup() {
        for o in overlays { o.view.armed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            for o in self.overlays { o.view.armed = self.shiftHeld }
        }
        toast.show("Hold Shift and drag to copy text from anything on screen")
    }

    // MARK: Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📋"
        statusItem.button?.toolTip = "Hold Shift and drag to OCR-copy text from anywhere"

        let menu = NSMenu()
        addItem(menu, "Open Accessibility Settings", #selector(openAccessibilityMenu))
        addItem(menu, "Open Screen Recording Settings", #selector(openScreenRecordingMenu))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Highlight Anything",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openAccessibilityMenu()    { openAccessibilityPane() }
    @objc private func openScreenRecordingMenu()  { openScreenRecordingPane() }

    private func openAccessibilityPane() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    private func openScreenRecordingPane() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Shift tracking

    private func setupShiftMonitor() {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.updateShift(e.modifierFlags.contains(.shift))
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.updateShift(e.modifierFlags.contains(.shift))
            return e
        }
    }

    private func updateShift(_ held: Bool) {
        guard held != shiftHeld else { return }
        shiftHeld = held
        for o in overlays {
            o.window.ignoresMouseEvents = !held
            o.view.armed = held
        }
        statusItem.button?.title = held ? "✂️" : "📋"
    }

    // MARK: CaptureViewDelegate

    func captureView(_ view: CaptureView, didSelectScreenRect rect: NSRect) {
        // Cocoa screen coords (y=0 at bottom of primary)
        // → CG coords (y=0 at top of primary).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgRect = CGRect(x: rect.origin.x,
                            y: primaryHeight - rect.maxY,
                            width: rect.width, height: rect.height)

        // Exclude all our overlay windows from the capture.
        let myIDs: Set<CGWindowID> = Set(overlays.map { CGWindowID($0.window.windowNumber) })

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let image = try await ScreenCapture.capture(
                    rect: cgRect, excludingWindowIDs: myIDs
                )
                OCR.recognize(in: image) { result in
                    DispatchQueue.main.async { self.handleOCRResult(result) }
                }
            } catch {
                await MainActor.run {
                    self.toast.show("Capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleOCRResult(_ result: Result<String, Error>) {
        switch result {
        case .failure(let err):
            toast.show("OCR failed: \(err.localizedDescription)")
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                toast.show("No text found in selection")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            let preview = oneLine.count > 70
                ? String(oneLine.prefix(70)) + "…"
                : oneLine
            toast.show("✓ Copied: \(preview)")
        }
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
