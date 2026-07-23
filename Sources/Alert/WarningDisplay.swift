import AppKit

@MainActor
final class WarningDisplay {
    private let window: NSWindow
    private var keyMonitor: Any?

    init(text: String, windowLevel: String, opacity: Double, killSwitchKeyCodes: Set<UInt16>, stopSignal: StopSignal) {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentFrame = NSRect(origin: .zero, size: frame.size)
        let window = AlertWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = Self.windowLevel(for: windowLevel)
        window.alphaValue = opacity
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces]

        let container = NSView(frame: contentFrame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .systemRed
        label.font = .boldSystemFont(ofSize: Self.fittedFontSize(for: text, in: contentFrame))
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40)
        ])

        window.contentView = container
        self.window = window

        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), killSwitchKeyCodes.contains(12) {
                stopSignal.set()
                print("stop requested")
                return nil
            }

            if killSwitchKeyCodes.contains(event.keyCode) {
                stopSignal.set()
                print("stop requested")
                return nil
            }

            return event
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func windowLevel(for value: String) -> NSWindow.Level {
        switch value {
        case "screenSaver":
            .screenSaver
        case "floating":
            .floating
        default:
            .normal
        }
    }

    private static func fittedFontSize(for text: String, in frame: NSRect) -> CGFloat {
        let maxWidth = frame.width * 0.9
        let maxHeight = frame.height * 0.45
        var size = min(frame.width * 0.103, frame.height * 0.20, 153)

        while size > 48 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: size)
            ]
            let measured = (text as NSString).size(withAttributes: attributes)

            if measured.width <= maxWidth && measured.height <= maxHeight {
                return size
            }

            size -= 4
        }

        return 48
    }
}

private final class AlertWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
