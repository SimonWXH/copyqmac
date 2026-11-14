// A small AppKit field that records a global shortcut.
//
// SwiftUI has no shortcut recorder, and the Carbon virtual key code and
// modifier mask cannot be recovered from a SwiftUI key equivalent, so a focused
// NSView captures the raw NSEvent.

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    var language: AppLanguage = .english
    let onChange: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.shortcut = shortcut
        view.language = language
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        view.shortcut = shortcut
        view.language = language
        view.onChange = onChange
        view.needsDisplay = true
    }
}

final class RecorderNSView: NSView {
    var shortcut: HotKeyShortcut = .defaultShortcut { didSet { needsDisplay = true } }
    var language: AppLanguage = .english { didSet { needsDisplay = true } }
    var onChange: ((HotKeyShortcut) -> Void)?

    private var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 26) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels recording rather than assigning Escape as the shortcut.
        if Int(event.keyCode) == kVK_Escape {
            isRecording = false
            return
        }
        guard let recorded = HotKeyShortcut.from(event: event) else {
            NSSound.beep()
            return
        }
        isRecording = false
        onChange?(recorded)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.15)
            : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = window?.firstResponder === self ? 2 : 1
        path.stroke()

        let prompt = Localization.string(.settingsRecordPrompt, language: language)
        let text = isRecording ? prompt : Localization.hotKeyLabel(shortcut.label, language: language)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}
