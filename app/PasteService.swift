// Paste-back: put an entry on the pasteboard, return focus to the app the user
// was using, and send a synthetic Command-V.
//
// Sending synthetic keyboard events requires Accessibility permission, which
// only the user can grant. When it is missing we do not fail silently: the
// entry stays on the clipboard (so a manual Command-V still works) and the UI
// shows an explicit notice with a link to the right System Settings pane.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum PasteOutcome: Equatable {
    /// The synthetic Command-V was posted to the target application.
    case pasted(targetName: String)
    /// The entry is on the clipboard but Accessibility is not granted.
    case copiedOnly
    /// The entry is on the clipboard and there was no target to activate.
    case copiedOnlyNoTarget
    /// The requested paste could not be completed.
    case failed(String)
}

/// Remembers which application was frontmost before our panel took focus.
///
/// Only ever touched from the main thread, including inside the `@Sendable`
/// NSWorkspace notification block, so the unchecked conformance is accurate.
final class FrontmostAppTracker: @unchecked Sendable {
    private(set) var lastExternalApp: NSRunningApplication?

    /// Refreshes the remembered app. Our own process is never recorded, so the
    /// value keeps pointing at the last real user application.
    func captureCurrent() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        lastExternalApp = frontmost
    }

    func remember(_ app: NSRunningApplication?) {
        guard let app else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        lastExternalApp = app
    }
}

private final class PasteRequestGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == value
    }
}

@MainActor
final class PasteService {
    private let tracker: FrontmostAppTracker
    private let watcher: ClipboardWatcher
    private let pasteboard: NSPasteboard
    /// Owns the per-launch Accessibility trust state. Shared with the model so
    /// a posted paste and the UI agree about whether trust is established.
    private let trust: PasteTrust
    private let requestTrust: @MainActor () -> Bool
    private let requests = PasteRequestGeneration()
    private let prepareQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.copyqmac.paste-prepare"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    #if COPYQMAC_TESTING
    private(set) var writeCount = 0
    #endif

    init(
        tracker: FrontmostAppTracker,
        watcher: ClipboardWatcher,
        pasteboard: NSPasteboard = .general,
        trust: PasteTrust? = nil,
        requestTrust: (@MainActor () -> Bool)? = nil
    ) {
        let trust = trust ?? PasteTrust()
        self.tracker = tracker
        self.watcher = watcher
        self.pasteboard = pasteboard
        self.trust = trust
        self.requestTrust = requestTrust ?? { trust.authorizePaste() }
    }

    /// Why a plain-text paste cannot run for an entry with no text. Shared with
    /// the model, which reports the same reason when menu validation (and the
    /// action) reject an entry.
    nonisolated static let noPlainTextMessage = "This entry has no text to paste as plain text."

    /// Why the global plain-text shortcut cannot run when the clipboard itself
    /// carries no text (for example after copying an image).
    nonisolated static let noClipboardTextMessage = "The clipboard has no text to paste as plain text."

    /// Why activation could not bring the previous app to the front.
    nonisolated static let focusFailedMessage = "Could not focus the previous app."

    /// Whether there is another app to paste into or bring to the front.
    ///
    /// The tracker never records this process, but an app can quit or be
    /// replaced while the window is open, so the remembered app is checked
    /// again before an activation relies on it.
    var hasPreviousTarget: Bool {
        guard let target = tracker.lastExternalApp else { return false }
        return !target.isTerminated
            && target.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    /// Brings the previous app back to the front without pasting anything.
    ///
    /// This is the activation step that only matters when pasting is off: a
    /// paste focuses the target as part of posting Command-V.
    @discardableResult
    func focusPreviousApp() -> Bool {
        guard let target = tracker.lastExternalApp, hasPreviousTarget else { return false }
        return target.activate(from: NSRunningApplication.current, options: [])
    }

    /// True when this app may post synthetic events. Passing `prompt: true`
    /// makes macOS show its own one-time "grant Accessibility" dialog, and is
    /// what registers the app in System Settings ▸ Privacy & Security ▸
    /// Accessibility in the first place.
    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane of System Settings.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Materialises flavours off the main thread by decompressing every payload,
    /// then delivers the uncompressed flavours back on the main actor.
    ///
    /// Only the newest request is applied: a newer paste or copy drops the
    /// completions of requests that were already in flight, and starts no work
    /// for an older request that is still waiting in the prepare queue.
    func prepareFlavours(for entry: ClipboardEntry, completion: @escaping @MainActor ([Flavour], Int) -> Void) {
        let requestGeneration = requests.next()
        let rawFlavours = entry.flavours
        prepareQueue.addOperation { [weak self] in
            guard let self, self.requests.isCurrent(requestGeneration) else { return }
            let materialised = rawFlavours.map {
                Flavour(itemIndex: $0.itemIndex, type: $0.type, data: $0.data)
            }
            guard self.requests.isCurrent(requestGeneration) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.requests.isCurrent(requestGeneration) else { return }
                completion(materialised, requestGeneration)
            }
        }
    }

    /// Writes `entry` to the pasteboard without pasting, and records the write
    /// so the watcher does not capture it as a new entry.
    func copy(_ entry: ClipboardEntry) {
        prepareFlavours(for: entry) { [weak self] prepared, requestGeneration in
            guard let self, self.requests.isCurrent(requestGeneration) else { return }
            let changeCount = PasteboardBridge.write(prepared, to: self.pasteboard)
            #if COPYQMAC_TESTING
            self.writeCount &+= 1
            #endif
            self.watcher.ignore(changeCount: changeCount)
        }
    }

    /// Materialises the text-only representation off the main thread.
    ///
    /// RTF and HTML stripping can be expensive for a rich paste, so it happens
    /// on the same serialised prepare queue as paste-back and honours the same
    /// newest-request-wins rule. The stored entry is never modified.
    func preparePlainText(for entry: ClipboardEntry, completion: @escaping @MainActor (String?, Int) -> Void) {
        let requestGeneration = requests.next()
        let rawFlavours = entry.flavours
        prepareQueue.addOperation { [weak self] in
            guard let self, self.requests.isCurrent(requestGeneration) else { return }
            let text = FlavourDecoder.plainTextRepresentation(from: rawFlavours)
            guard self.requests.isCurrent(requestGeneration) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.requests.isCurrent(requestGeneration) else { return }
                completion(text, requestGeneration)
            }
        }
    }

    /// Writes `entry` to the pasteboard and, when permitted, pastes it into the
    /// most recent external application.
    func paste(_ entry: ClipboardEntry, completion: @escaping @MainActor (PasteOutcome) -> Void) {
        prepareFlavours(for: entry) { [weak self] prepared, requestGeneration in
            guard let self, self.requests.isCurrent(requestGeneration) else { return }
            self.writeAndPaste(prepared, requestGeneration: requestGeneration, completion: completion)
        }
    }

    /// Pastes only the entry's text, with every rich flavour dropped.
    ///
    /// The text is derived from the stored flavours and written as a single
    /// `public.utf8-plain-text` item, then the normal paste path takes over:
    /// activation, the synthetic Command-V, and the Accessibility fallback are
    /// exactly the same as for a regular paste.
    func pastePlainText(_ entry: ClipboardEntry, completion: @escaping @MainActor (PasteOutcome) -> Void) {
        preparePlainText(for: entry) { [weak self] text, requestGeneration in
            guard let self, self.requests.isCurrent(requestGeneration) else { return }
            guard let text else {
                completion(.failed(Self.noPlainTextMessage))
                return
            }
            let flavours = [Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data(text.utf8))]
            self.writeAndPaste(
                flavours,
                requestGeneration: requestGeneration,
                completion: completion
            )
        }
    }

    /// Pastes the live clipboard's text, with every rich flavour dropped.
    ///
    /// The global plain-text shortcut uses this when CopyQmac is only in the
    /// menu bar: the user just copied something in another app, so the
    /// selected history entry can be stale while the pasteboard is current.
    /// The text is read on the main thread (NSPasteboard is not thread-safe),
    /// stripped off the main thread, and written back as one plain-text item.
    func pasteCurrentClipboardAsPlainText(
        target: NSRunningApplication?,
        activateTarget: Bool,
        completion: @escaping @MainActor (PasteOutcome) -> Void
    ) {
        let requestGeneration = requests.next()
        let rawFlavours = PasteboardBridge.snapshot(of: pasteboard)
        prepareQueue.addOperation { [weak self] in
            guard let self, self.requests.isCurrent(requestGeneration) else { return }
            let text = FlavourDecoder.plainTextRepresentation(from: rawFlavours)
            Task { @MainActor [weak self] in
                guard let self, self.requests.isCurrent(requestGeneration) else { return }
                guard let text, !text.isEmpty else {
                    completion(.failed(Self.noClipboardTextMessage))
                    return
                }
                let flavours = [Flavour(
                    itemIndex: 0,
                    type: PasteboardTypes.utf8Text,
                    data: Data(text.utf8)
                )]
                self.writeAndPaste(
                    flavours,
                    requestGeneration: requestGeneration,
                    target: target,
                    activateTarget: activateTarget,
                    completion: completion
                )
            }
        }
    }

    /// Shared tail of both paste paths: write the flavours, record the write so
    /// the watcher ignores it, then activate the target and send Command-V.
    ///
    /// `target` overrides the remembered previous app (the global shortcut
    /// passes the app that is already in front), and `activateTarget` is false
    /// when that app must keep focus.
    private func writeAndPaste(
        _ flavours: [Flavour],
        requestGeneration: Int,
        target explicitTarget: NSRunningApplication? = nil,
        activateTarget: Bool = true,
        completion: @escaping @MainActor (PasteOutcome) -> Void
    ) {
        guard requests.isCurrent(requestGeneration) else { return }
        let changeCount = PasteboardBridge.write(flavours, to: pasteboard)
        #if COPYQMAC_TESTING
        writeCount &+= 1
        #endif
        watcher.ignore(changeCount: changeCount)

        // Ask before anything else can fail, so the system dialog is the first
        // thing an untrusted user sees rather than our own fallback notice.
        guard requests.isCurrent(requestGeneration) else { return }
        guard requestTrust() else {
            guard requests.isCurrent(requestGeneration) else { return }
            completion(.copiedOnly)
            return
        }

        guard requests.isCurrent(requestGeneration) else { return }
        guard let target = explicitTarget ?? tracker.lastExternalApp, !target.isTerminated else {
            completion(.copiedOnlyNoTarget)
            return
        }

        // Never post Command-V into our own window: that would paste into the
        // history list instead of the app the user came from.
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(.copiedOnlyNoTarget)
            return
        }

        if activateTarget {
            guard requests.isCurrent(requestGeneration) else { return }
            guard target.activate(from: NSRunningApplication.current, options: []) else {
                completion(.failed("Could not activate the previous app."))
                return
            }
        }

        guard requests.isCurrent(requestGeneration) else { return }
        let targetName = target.localizedName ?? target.bundleIdentifier ?? "the previous app"
        postPasteCommand(to: target, requestGeneration: requestGeneration) { commandSent in
            guard self.requests.isCurrent(requestGeneration) else { return }
            if commandSent {
                // A posted paste is the evidence that this build can paste even
                // when the process-level trust check stays stale after a
                // re-grant, so the session treats trust as established.
                self.trust.notePasteSucceeded()
                completion(.pasted(targetName: targetName))
            } else {
                completion(.failed("Could not activate the previous app or send the paste command."))
            }
        }
    }

    private func postPasteCommand(
        to target: NSRunningApplication,
        requestGeneration: Int,
        attempt: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        guard requests.isCurrent(requestGeneration) else { return }
        guard !target.isTerminated else {
            completion(false)
            return
        }
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        guard isFrontmost else {
            guard attempt < 12 else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.requests.isCurrent(requestGeneration) else { return }
                self.postPasteCommand(
                    to: target,
                    requestGeneration: requestGeneration,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
            return
        }
        completion(Self.sendCommandV(to: target.processIdentifier))
    }

    /// Sends Command-V to a specific process so the keystroke lands in the
    /// intended app rather than wherever focus happens to be.
    static func sendCommandV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}
