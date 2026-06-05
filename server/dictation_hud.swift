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
    var maxHeight: CGFloat = 600  // capped to ~50% of the target screen on each anchor
    let horizontalPadding: CGFloat = 28
    let verticalPadding: CGFloat = 24
    var savedCenter: NSPoint?
    // Full transcript text we've been told about. We display only the
    // tail that fits within maxHeight, so older text scrolls up and out
    // when the user keeps talking past the visible cap.
    var fullText: String = ""

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
                    if line.hasPrefix("__POS__:") {
                        // Reposition command: x,y,w,h in screen coords (Cocoa,
                        // origin bottom-left). Anchor the HUD just above this
                        // rect, horizontally centered.
                        let payload = String(line.dropFirst("__POS__:".count))
                        let parts = payload.split(separator: ",").compactMap { Double($0) }
                        if parts.count == 4 {
                            self?.anchorAbove(rect: NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
                        }
                    } else {
                        self?.updateText(line)
                    }
                }
            }
            DispatchQueue.main.async {
                self?.fadeOutAndExit()
            }
        }
    }

    // Center the HUD on the given screen rect. Used to follow the active
    // iTerm window. Clamps to the visible screen so nothing falls off.
    // Also updates the HUD's max width/height caps so the HUD never
    // overhangs the target window or grows past 50% of its screen.
    func anchorAbove(rect: NSRect) {
        guard rect.width > 50 && rect.height > 50 else { return }

        // Cap the HUD width to the target window's width (with a small inset
        // so the rounded corners don't kiss the window edges).
        let widthCap = max(200, min(rect.width - 24, 1000))
        // Cap height to 50% of the screen the window lives on.
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
        let screenH = screen?.visibleFrame.height ?? 600
        let heightCap = screenH * 0.5

        let widthChanged = abs(widthCap - maxWidth) > 1 || abs(heightCap - maxHeight) > 1
        maxWidth = widthCap
        maxHeight = heightCap
        if widthChanged {
            // Re-resize so the new caps take effect immediately.
            applyDisplayedText()
            resizeToFit()
        }

        let frame = window.frame
        var newOrigin = NSPoint(
            x: rect.midX - frame.width / 2,
            y: rect.midY - frame.height / 2
        )

        if let screen = screen {
            let visible = screen.visibleFrame
            if newOrigin.x < visible.minX { newOrigin.x = visible.minX + 8 }
            if newOrigin.x + frame.width > visible.maxX { newOrigin.x = visible.maxX - frame.width - 8 }
            if newOrigin.y < visible.minY { newOrigin.y = visible.minY + 8 }
            if newOrigin.y + frame.height > visible.maxY { newOrigin.y = visible.maxY - frame.height - 8 }
        }
        window.setFrameOrigin(newOrigin)
        savedCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
    }

    func updateText(_ text: String) {
        fullText = text
        applyDisplayedText()
        resizeToFit()
    }

    // Compute what to show from `fullText` given the current maxWidth and
    // maxHeight caps. If the text would exceed maxHeight, drop characters
    // from the START until it fits, prefixed with `…` so the user knows
    // there's more above.
    func applyDisplayedText() {
        if fullText.isEmpty {
            textField.stringValue = "Listening\u{2026}"
            textField.textColor = .init(white: 0, alpha: 0.4)
            return
        }
        textField.textColor = .black

        let textWidth = maxWidth - (horizontalPadding * 2)
        let cappedHeight = maxHeight - (verticalPadding * 2)

        // Fast path: full text fits without truncation.
        textField.stringValue = fullText
        var size = textField.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        if size.height <= cappedHeight { return }

        // Binary-search the largest tail that fits inside cappedHeight.
        // We trim by character count for simplicity. Prepend "…" to indicate
        // truncation.
        let chars = Array(fullText)
        var lo = 0
        var hi = chars.count
        var bestStart = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = "\u{2026} " + String(chars[mid...])
            textField.stringValue = candidate
            size = textField.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
            if size.height <= cappedHeight {
                bestStart = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        textField.stringValue = "\u{2026} " + String(chars[bestStart...])
    }

    func resizeToFit() {
        let textWidth = maxWidth - (horizontalPadding * 2)
        let textSize = textField.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))

        let totalHeight = min(maxHeight, verticalPadding + textSize.height + verticalPadding)
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
