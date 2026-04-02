import AppKit

// MARK: - Dictation HUD
// A floating translucent panel that displays live dictation text.
// Reads lines from stdin — each line replaces the displayed text.
// When stdin closes, the window fades out and the process exits.
// Position is saved to ~/.config/dispatch/hud_position and persisted across sessions.

let positionFile = NSString(string: "~/.config/dispatch/hud_position").expandingTildeInPath

// MARK: - Draggable visual effect view

class DraggableView: NSVisualEffectView {
    var onDragEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

// MARK: - Controller

class HUDWindowController: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    var textField: NSTextField!
    var containerView: DraggableView!
    var maxWidth: CGFloat = 560
    let horizontalPadding: CGFloat = 28
    let verticalPadding: CGFloat = 24
    var savedCenter: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Compute max width as 50% of screen
        if let screen = NSScreen.main {
            maxWidth = screen.frame.width * 0.4
        }

        let initialFrame = NSRect(x: 0, y: 0, width: 340, height: 80)
        window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false
        window.animationBehavior = .utilityWindow
        window.alphaValue = 0

        // Vibrancy container — dark translucent blur
        containerView = DraggableView(frame: initialFrame)
        containerView.material = .hudWindow
        containerView.state = .active
        containerView.blendingMode = .behindWindow
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 26
        containerView.layer?.cornerCurve = .continuous
        containerView.layer?.masksToBounds = true
        containerView.alphaValue = 0.9
        containerView.onDragEnd = { [weak self] in
            self?.savePosition()
        }
        window.contentView = containerView

        // Text label
        textField = NSTextField(wrappingLabelWithString: "Listening\u{2026}")
        textField.font = NSFont.systemFont(ofSize: 31, weight: .regular)
        textField.textColor = .init(white: 0, alpha: 0.4)
        textField.alignment = .center
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        containerView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: verticalPadding),
            textField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: horizontalPadding),
            textField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -horizontalPadding),
            textField.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -verticalPadding),
        ])

        // Load saved position or center on screen
        loadPosition()
        positionWindow()
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        // Read stdin on background thread
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async {
                    self?.updateText(line)
                }
            }
            DispatchQueue.main.async {
                self?.fadeOutAndExit()
            }
        }
    }

    func updateText(_ text: String) {
        if text.isEmpty {
            textField.stringValue = "Listening\u{2026}"
            textField.textColor = .init(white: 0, alpha: 0.4)
        } else {
            textField.stringValue = text
            textField.textColor = .black
        }
        resizeToFit()
    }

    func resizeToFit() {
        let textWidth = maxWidth - (horizontalPadding * 2)
        let textSize = textField.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))

        let totalHeight = verticalPadding + textSize.height + verticalPadding
        let totalWidth = min(maxWidth, textSize.width + horizontalPadding * 2 + 8)
        let finalWidth = max(200, totalWidth)

        let newSize = NSSize(width: finalWidth, height: totalHeight)
        var frame = window.frame
        let center = savedCenter ?? NSPoint(x: frame.midX, y: frame.midY)
        frame.size = newSize
        frame.origin.x = center.x - newSize.width / 2
        frame.origin.y = center.y - newSize.height / 2
        window.setFrame(frame, display: true, animate: false)
    }

    func positionWindow() {
        if let center = savedCenter {
            var frame = window.frame
            frame.origin.x = center.x - frame.width / 2
            frame.origin.y = center.y - frame.height / 2
            window.setFrame(frame, display: true)
        } else {
            guard let screen = NSScreen.main else { return }
            let screenFrame = screen.visibleFrame
            let windowSize = window.frame.size
            let x = screenFrame.midX - windowSize.width / 2
            let y = screenFrame.midY - windowSize.height / 2 + screenFrame.height * 0.1
            window.setFrameOrigin(NSPoint(x: x, y: y))
            savedCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        }
    }

    // MARK: - Position persistence

    func savePosition() {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        savedCenter = center
        let dir = (positionFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = "\(center.x),\(center.y)"
        try? data.write(toFile: positionFile, atomically: true, encoding: .utf8)
    }

    func loadPosition() {
        guard let data = try? String(contentsOfFile: positionFile, encoding: .utf8) else { return }
        let parts = data.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else { return }
        savedCenter = NSPoint(x: x, y: y)
    }

    func fadeOutAndExit() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            NSApplication.shared.terminate(nil)
        })
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = HUDWindowController()
app.delegate = controller
app.run()
